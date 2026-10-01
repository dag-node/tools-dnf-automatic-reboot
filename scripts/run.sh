#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# run.sh
# ---------------------------------------------------------------------------
# Main orchestration script for dnf-automatic-reboot.
#
# Sequence:
#   1. Detect concurrent dnf processes and warn via wall(1).
#   2. Write a state file consumed by watchdog.sh.
#   3. Run dnf-automatic under a hard wall-clock timeout, as the child of a
#      systemd inhibitor lock that blocks shutdown and reboot until it exits.
#   4. Call needs-reboot.sh to decide whether a reboot is required,
#      filtering known false positives.
#   5. Schedule a reboot if needed; otherwise restart the services whose
#      running processes still map pre-update files.
#
# State file /run/dnf-automatic-reboot.state
#   phase=         updating | checking
#   start=         unix timestamp, for operators
#   start_uptime=  seconds since boot; the watchdog times the run from this
#                  because a host with no RTC steps its wall clock mid-run
#   pid=           PID of this script
#
# Sourcing this file defines its functions without running the update, so
# tests/run-tests.sh can exercise them directly.
#
# Configuration: /etc/dnf/automatic-reboot.conf
# Log:           /var/log/dnf-automatic-reboot.log
# ---------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

export LC_ALL=C

# Path prefix, empty in production.  tests/run-tests.sh points it at a
# temporary tree so every path and helper binary below resolves inside it.
readonly TEST_ROOT="${DNF_AUTOMATIC_REBOOT_TEST_ROOT:-}"

readonly CONFIG_FILE="${TEST_ROOT}/etc/dnf/automatic-reboot.conf"
readonly AUTOMATIC_CONFIG_FILE="${TEST_ROOT}/etc/dnf/automatic.conf"
readonly DNF_CONFIG_FILE="${TEST_ROOT}/etc/dnf/dnf.conf"
readonly REPOSITORY_CONFIG_DIRECTORY="${TEST_ROOT}/etc/yum.repos.d"
readonly STATE_FILE="${TEST_ROOT}/run/dnf-automatic-reboot.state"
readonly LOCK_FILE="${TEST_ROOT}/run/dnf-automatic-reboot.lock"
# Present from a reboot request until the reboot; the unit does not start then.
# watchdog.sh uses the same file.
readonly REBOOT_PENDING_FILE="${TEST_ROOT}/run/dnf-automatic-reboot.reboot-pending"
readonly CANCEL_REBOOT_COMMAND=/usr/libexec/dnf-automatic-reboot/cancel-reboot.sh
readonly UPTIME_FILE="${TEST_ROOT}/proc/uptime"
readonly LOG_FILE="${TEST_ROOT}/var/log/dnf-automatic-reboot.log"
readonly LIBRARY_DIRECTORY="${TEST_ROOT}/usr/libexec/dnf-automatic-reboot"
readonly DNF_BIN="${TEST_ROOT}/usr/bin/dnf"
readonly DNF_AUTOMATIC_BIN="${TEST_ROOT}/usr/bin/dnf-automatic"
readonly SYSTEMD_RUN_BIN="${TEST_ROOT}/usr/bin/systemd-run"
readonly SYSTEMCTL_BIN="${TEST_ROOT}/usr/bin/systemctl"
readonly SCRIPT_NAME=run
# Transient unit that carries a scheduled reboot; the watchdog uses the same.
readonly SCHEDULED_REBOOT_UNIT=dnf-automatic-reboot-scheduled-reboot
SERVICE_PID=$$

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    printf '<6>%s: %s\n' "${SCRIPT_NAME}" "$*"
    printf '%s %s: %s\n' "$(date -Iseconds)" "${SCRIPT_NAME}" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}
log_warning() {
    printf '<4>%s: %s\n' "${SCRIPT_NAME}" "$*"
    printf '%s %s: WARNING: %s\n' "$(date -Iseconds)" "${SCRIPT_NAME}" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}
log_error() {
    printf '<3>%s: %s\n' "${SCRIPT_NAME}" "$*"
    printf '%s %s: ERROR: %s\n' "$(date -Iseconds)" "${SCRIPT_NAME}" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}

wall_msg() {
    local wall_messages_enabled
    wall_messages_enabled=$(get_config_value wall_messages yes)
    wall_messages_enabled="${wall_messages_enabled//[[:space:]]/}"
    [[ "${wall_messages_enabled:-yes}" == "no" ]] && return 0
    wall "$*" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------
get_config_value() {
    local config_key="$1" default_value="$2" config_value
    config_value=$(grep -E "^\s*${config_key}\s*=" "${CONFIG_FILE}" 2>/dev/null \
                   | tail -1 | sed 's/^[^=]*=\s*//' | sed 's/\s*#.*//') || true
    printf '%s' "${config_value:-${default_value}}"
}

get_config_integer() {
    local config_key="$1" default_value="$2" config_value
    config_value=$(get_config_value "${config_key}" "${default_value}")
    config_value="${config_value//[[:space:]]/}"
    if [[ ! "${config_value}" =~ ^[0-9]+$ ]]; then
        log_warning "${config_key}='${config_value}' is not a non-negative integer - using default ${default_value}" >&2
        config_value="${default_value}"
    fi
    printf '%s' "${config_value}"
}

# ---------------------------------------------------------------------------
# Pre-flight: report enabled repositories that disable signature checking.
#
# This service installs packages unattended, so a repository with gpgcheck=0
# is an unsigned-code path that nobody is watching.  Only an explicit
# `gpgcheck=0` in a section that is not explicitly disabled is reported: dnf's
# own default is not modelled, so there are no false alarms to learn to
# ignore.  Reported, not fatal - a local unsigned repository is somebody's
# deliberate choice, and refusing to patch the host is the worse outcome.
# ---------------------------------------------------------------------------
warn_on_unsigned_repositories() {
    local unsigned_repository_ids candidate_file repository_config_files=()

    [[ "${WARN_UNSIGNED_REPOSITORIES}" == "yes" ]] || return 0

    # awk is fatal on a missing file and never reaches its END rule, which is
    # where the last section is flushed, so only existing files are passed.
    for candidate_file in "${REPOSITORY_CONFIG_DIRECTORY}"/*.repo "${DNF_CONFIG_FILE}"; do
        [[ -f "${candidate_file}" ]] && repository_config_files+=("${candidate_file}")
    done
    [[ "${#repository_config_files[@]}" -gt 0 ]] || return 0

    unsigned_repository_ids=$(awk '
        function section_is_unsigned() {
            if (section_name == "") return 0
            if (section_enabled == "0" || section_enabled == "False" \
                || section_enabled == "false" || section_enabled == "no") return 0
            return section_gpgcheck == "0"
        }
        function read_value(line,   value) {
            value = line
            sub(/^[^=]*=[[:space:]]*/, "", value)
            gsub(/[[:space:]]/, "", value)
            return value
        }
        /^[[:space:]]*\[.*\]/ {
            if (section_is_unsigned()) print section_name
            section_name = $0
            sub(/^[[:space:]]*\[/, "", section_name)
            sub(/\][[:space:]]*$/, "", section_name)
            section_enabled = "1"
            section_gpgcheck = ""
            next
        }
        /^[[:space:]]*enabled[[:space:]]*=/  { section_enabled  = read_value($0) }
        /^[[:space:]]*gpgcheck[[:space:]]*=/ { section_gpgcheck = read_value($0) }
        END { if (section_is_unsigned()) print section_name }
    ' "${repository_config_files[@]}" 2>/dev/null | sort -u | paste -sd, -) || true

    if [[ -n "${unsigned_repository_ids}" ]]; then
        log_error "repositories with gpgcheck=0 are enabled: ${unsigned_repository_ids} - unattended updates from them install unsigned packages"
        wall_msg "dnf-automatic-reboot: WARNING - unsigned repositories enabled (${unsigned_repository_ids})." \
                 "Unattended updates from them are not signature-checked."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Pre-flight: abort if conflicting services would cause double-reboots, or if
# dnf-automatic would not install anything.
#
# Repeats the %pre checks on /etc/dnf/automatic.conf at every start, so an
# edit made after install fails the run through OnFailure= instead of
# producing silent successes.  The file is the operator's and is only read.
# ---------------------------------------------------------------------------
check_conflicts() {
    local conflict_found=0 conflicting_timer automatic_reboot_value apply_updates_value

    for conflicting_timer in dnf-automatic.timer dnf-automatic-install.timer; do
        if systemctl is-enabled --quiet "${conflicting_timer}" 2>/dev/null || \
           systemctl is-active  --quiet "${conflicting_timer}" 2>/dev/null; then
            log_error "${conflicting_timer} is enabled/active - conflicts with this service; disable with: systemctl disable --now ${conflicting_timer}"
            conflict_found=1
        fi
    done

    if [[ -f "${AUTOMATIC_CONFIG_FILE}" ]]; then
        automatic_reboot_value=$(grep -E '^\s*reboot\s*=' "${AUTOMATIC_CONFIG_FILE}" 2>/dev/null \
                                 | tail -1 | sed 's/^[^=]*=\s*//' | sed 's/\s*#.*//' \
                                 | tr -d '[:space:]') || true
        if [[ -n "${automatic_reboot_value}" && "${automatic_reboot_value}" != "never" ]]; then
            log_error "/etc/dnf/automatic.conf has reboot = ${automatic_reboot_value}; set 'reboot = never' to avoid double-reboot conflicts"
            conflict_found=1
        fi
    fi

    # dnf-automatic defaults apply_updates to false and then exits 0 after
    # downloading.  True values are those libdnf's OptionBool accepts.
    apply_updates_value=$(grep -E '^\s*apply_updates\s*=' "${AUTOMATIC_CONFIG_FILE}" 2>/dev/null \
                          | tail -1 | sed 's/^[^=]*=\s*//' | sed 's/\s*#.*//' \
                          | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]') || true
    case "${apply_updates_value}" in
        yes|true|1|on) ;;
        *)
            log_error "/etc/dnf/automatic.conf has apply_updates = ${apply_updates_value:-<unset>}; dnf-automatic would download updates without installing them; set 'apply_updates = yes'"
            conflict_found=1
            ;;
    esac

    if [[ "${conflict_found}" -ne 0 ]]; then
        log_error "Aborting: resolve the conflicts above, then restart the service"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Read config
# ---------------------------------------------------------------------------
REBOOT_DELAY_SEC=$(get_config_integer reboot_delay_sec 60)
ALWAYS_REBOOT=$(get_config_value always_reboot no)
DNF_TIMEOUT_MIN=$(get_config_integer dnf_timeout_min 60)
KILL_GRACE_SEC=$(get_config_integer kill_grace_sec 30)
WARN_UNSIGNED_REPOSITORIES=$(get_config_value warn_unsigned_repositories yes)
WARN_UNAPPLIED_ADVISORIES=$(get_config_value warn_unapplied_advisories yes)
RESTART_SERVICES=$(get_config_value restart_services yes)
RESTART_SERVICES_EXCLUDE=$(get_config_value restart_services_exclude \
    "dbus.service,dbus-broker.service,systemd-logind.service,user@*.service,getty@*.service,serial-getty@*.service,autovt@*.service,dnf-automatic-reboot.service,dnf-automatic-watchdog.service")
NEEDS_RESTARTING_TIMEOUT_SEC=$(get_config_integer needs_restarting_timeout_sec 120)
RESTART_SERVICE_TIMEOUT_SEC=$(get_config_integer restart_service_timeout_sec 300)

# Outcome of restart_stale_services, read by report_completion.
RESTARTED_SERVICE_NAMES=()
FAILED_SERVICE_NAMES=()
PENDING_SERVICE_NAMES=()
EXCLUDED_SERVICE_NAMES=()
SERVICE_RESTART_SUMMARY="stale services not checked"
SCHEDULED_REBOOT_SUMMARY=""
# 1 from before REBOOT_PENDING_FILE is created until the request's outcome is
# known.
REBOOT_REQUEST_IN_PROGRESS=0

# ---------------------------------------------------------------------------
# Cleanup handler - run by the EXIT trap
# Removes state/lock files, and reports a reboot request cut short.
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    if [[ "${REBOOT_REQUEST_IN_PROGRESS}" -eq 1 ]]; then
        log_error "stopped while requesting a reboot - whether it was submitted is unknown. ${REBOOT_PENDING_FILE} stays, so no update run starts. Check: systemctl list-timers ${SCHEDULED_REBOOT_UNIT}.timer; then reboot, or allow updates again with: ${CANCEL_REBOOT_COMMAND}"
    fi
    rm -f "${STATE_FILE}" "${LOCK_FILE}"
    log "Exiting rc=${exit_code}"
    exit "${exit_code}"
}

# ---------------------------------------------------------------------------
# State file writer
# ---------------------------------------------------------------------------
write_state() {
    local run_phase="$1"
    printf 'phase=%s\nstart=%s\nstart_uptime=%s\npid=%s\n' \
        "${run_phase}" "${START_TIMESTAMP}" "${START_UPTIME_SECONDS}" "${SERVICE_PID}" \
        > "${STATE_FILE}"
}

# uptime_seconds -> whole seconds since boot, empty when unreadable.
# CLOCK_BOOTTIME, which chrony stepping the wall clock does not move.
uptime_seconds() {
    local uptime_value=""
    read -r uptime_value _ < "${UPTIME_FILE}" 2>/dev/null || true
    printf '%s' "${uptime_value%%.*}"
}

# ---------------------------------------------------------------------------
# Restart services still mapping pre-update files.
#
# `needs-restarting -r` only ever inspects a fixed list of ten package names,
# so a security update to any daemon outside that list patches the on-disk
# binary and leaves the vulnerable image resident with no reboot flag raised.
# `needs-restarting -s` walks /proc/*/smaps instead and names the systemd
# units affected, which is the gap this closes.
#
# Only reached when no reboot is scheduled - a reboot supersedes it.
# ---------------------------------------------------------------------------
# is_excluded_unit UNIT_NAME - succeeds when UNIT_NAME matches an entry of
# restart_services_exclude.  An entry is a unit name or a bash glob such as
# user@*.service, which covers every instance of a template unit.
is_excluded_unit() {
    local unit_name="$1" excluded_unit_pattern previous_ifs
    local excluded_unit_patterns=()
    previous_ifs="${IFS}"
    IFS=',' read -ra excluded_unit_patterns <<< "${RESTART_SERVICES_EXCLUDE}"
    IFS="${previous_ifs}"
    for excluded_unit_pattern in "${excluded_unit_patterns[@]:-}"; do
        excluded_unit_pattern="${excluded_unit_pattern//[[:space:]]/}"
        [[ -n "${excluded_unit_pattern}" ]] || continue
        # shellcheck disable=SC2053  # the entry is a glob by design
        if [[ "${unit_name}" == ${excluded_unit_pattern} ]]; then
            return 0
        fi
    done
    return 1
}

# restart_stale_services
# Sets SERVICE_RESTART_SUMMARY to one clause naming every outcome, and the
# RESTARTED_, FAILED_, PENDING_ and EXCLUDED_SERVICE_NAMES arrays.  Returns 1
# when a restart failed or had not finished within restart_service_timeout_sec,
# or when `dnf needs-restarting -s` failed to list the services: each leaves
# pre-update code running that the run was meant to replace.  Excluded units
# are left running by design and do not fail the run.
restart_stale_services() {
    local stale_service_output stale_service_name restart_exit_code
    local summary_clauses=()
    RESTARTED_SERVICE_NAMES=()
    FAILED_SERVICE_NAMES=()
    PENDING_SERVICE_NAMES=()
    EXCLUDED_SERVICE_NAMES=()
    SERVICE_RESTART_SUMMARY=""

    if [[ "${RESTART_SERVICES}" != "yes" ]]; then
        log "restart_services=no - not restarting stale services"
        SERVICE_RESTART_SUMMARY="stale services not checked (restart_services = no)"
        return 0
    fi

    stale_service_output=""
    if ! stale_service_output=$(timeout "${NEEDS_RESTARTING_TIMEOUT_SEC}s" \
            "${DNF_BIN}" -q -C needs-restarting -s 2>/dev/null); then
        log_error "needs-restarting -s failed - stale services not restarted this run"
        SERVICE_RESTART_SUMMARY="stale services could not be listed (needs-restarting -s failed)"
        return 1
    fi

    while IFS= read -r stale_service_name; do
        stale_service_name="${stale_service_name//[[:space:]]/}"
        [[ -n "${stale_service_name}" ]] || continue
        [[ "${stale_service_name}" == *.service ]] || continue

        if is_excluded_unit "${stale_service_name}"; then
            EXCLUDED_SERVICE_NAMES+=("${stale_service_name}")
            continue
        fi

        # Bounded: a unit that hangs in stop or start must not hold the run.
        # Stopping the systemctl client leaves the restart job to systemd.
        restart_exit_code=0
        timeout "${RESTART_SERVICE_TIMEOUT_SEC}s" \
            "${SYSTEMCTL_BIN}" try-restart "${stale_service_name}" 2>/dev/null \
            || restart_exit_code=$?
        if [[ "${restart_exit_code}" -eq 0 ]]; then
            RESTARTED_SERVICE_NAMES+=("${stale_service_name}")
        elif [[ "${restart_exit_code}" -eq 124 ]]; then
            PENDING_SERVICE_NAMES+=("${stale_service_name}")
            log_warning "restart of ${stale_service_name} did not finish within ${RESTART_SERVICE_TIMEOUT_SEC}s - the job continues in systemd"
        else
            FAILED_SERVICE_NAMES+=("${stale_service_name}")
            log_warning "failed to restart ${stale_service_name} - it is still running pre-update code"
        fi
    done <<< "${stale_service_output}"

    if [[ "${#RESTARTED_SERVICE_NAMES[@]}" -gt 0 ]]; then
        summary_clauses+=("restarted $(join_with ', ' "${RESTARTED_SERVICE_NAMES[@]}")")
    fi
    if [[ "${#FAILED_SERVICE_NAMES[@]}" -gt 0 ]]; then
        summary_clauses+=("restart FAILED for $(join_with ', ' "${FAILED_SERVICE_NAMES[@]}")")
    fi
    if [[ "${#PENDING_SERVICE_NAMES[@]}" -gt 0 ]]; then
        summary_clauses+=("restart still pending for $(join_with ', ' "${PENDING_SERVICE_NAMES[@]}")")
    fi
    if [[ "${#EXCLUDED_SERVICE_NAMES[@]}" -gt 0 ]]; then
        summary_clauses+=("excluded from restart, still on pre-update code: $(join_with ', ' "${EXCLUDED_SERVICE_NAMES[@]}")")
    fi
    if [[ "${#summary_clauses[@]}" -eq 0 ]]; then
        summary_clauses=("no service needed a restart")
    fi
    SERVICE_RESTART_SUMMARY=$(join_with '; ' "${summary_clauses[@]}")

    if [[ "${#FAILED_SERVICE_NAMES[@]}" -gt 0 || "${#PENDING_SERVICE_NAMES[@]}" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# join_with SEPARATOR ITEM... -> the items joined with SEPARATOR
join_with() {
    local separator="$1" joined_items="" item
    shift
    for item in "$@"; do
        joined_items+="${joined_items:+${separator}}${item}"
    done
    printf '%s' "${joined_items}"
}

# ---------------------------------------------------------------------------
# Post-update: report security advisories dnf will not apply.
#
# `dnf updateinfo` reads the whole package sack; the depsolver does not.  A
# repository priority=, an excludepkgs=, a disabled channel or a versionlock
# can leave an advisory permanently visible-but-unappliable.  The update run
# reports success either way, so the host quietly never receives the fix - the
# exact failure this whole package exists to prevent, one layer further down.
#
# Run after dnf-automatic, where anything still outstanding is genuinely stuck
# rather than merely pending.  The comparison is between what dnf itself says
# applies to this host and whether a security transaction resolves to anything,
# so any cause is caught without having to enumerate them.
# ---------------------------------------------------------------------------
warn_on_unapplied_security_advisories() {
    local pending_advisory_ids check_update_exit_code=0

    [[ "${WARN_UNAPPLIED_ADVISORIES}" == "yes" ]] || return 0

    # Advisory IDs are matched by shape, PREFIX-YEAR-NUMBER or PREFIX-YEAR:NUMBER
    # with an optional `-REVISION`, the prefix one or more dash-joined words and
    # the number alphanumeric (Oracle ELSA-2026-26533 and ELSA-2026-60226-0,
    # Red Hat RHSA-2020:3011, EPEL FEDORA-EPEL-2024-bf31852fe0), not by excluding
    # header text, so a line of any other shape is not reported as an advisory.
    pending_advisory_ids=$(timeout "${NEEDS_RESTARTING_TIMEOUT_SEC}s" \
        "${DNF_BIN}" -q -C updateinfo list --updates --security 2>/dev/null \
        | awk 'NF >= 3 && $1 ~ /^[A-Za-z]+(-[A-Za-z]+)*-[0-9]+[-:][0-9A-Za-z]+(-[0-9]+)?$/ { print $1 }' \
        | sort -u | paste -sd, -) || true

    [[ -n "${pending_advisory_ids}" ]] || return 0

    # check-update: 100 = upgrades available, 0 = none, anything else = failure.
    timeout "${NEEDS_RESTARTING_TIMEOUT_SEC}s" \
        "${DNF_BIN}" -q -C check-update --security >/dev/null 2>&1 \
        || check_update_exit_code=$?

    if [[ "${check_update_exit_code}" -eq 100 ]]; then
        log_warning "security advisories still outstanding after this run: ${pending_advisory_ids}"
        return 0
    fi

    if [[ "${check_update_exit_code}" -ne 0 ]]; then
        log_warning "could not confirm whether ${pending_advisory_ids} are appliable (dnf check-update exited ${check_update_exit_code})"
        return 0
    fi

    log_error "security advisories apply to this host but dnf will not install them: ${pending_advisory_ids} - the host stays unpatched and every run will report success; check repository priority=, excludepkgs=, disabled repositories and versionlock"
    wall_msg "dnf-automatic-reboot: WARNING - security advisories (${pending_advisory_ids})" \
             "apply to this host but dnf refuses to install them. Updates are NOT complete." \
             "Diagnose: dnf --assumeno --setopt='*.priority=99' update --security"
    return 0
}

# ---------------------------------------------------------------------------
# Run dnf-automatic under the inhibitor lock and a hard timeout.
#
# systemd-inhibit takes a block-mode shutdown:sleep lock from logind before it
# starts its command, holds it for exactly as long as that command runs, and
# exits non-zero without starting the command when the lock is refused.  No
# update runs unprotected, and the lock is gone before any reboot is
# scheduled.  An admin can still force-reboot with: systemctl reboot --force
#
# timeout sends SIGTERM at DNF_TIMEOUT_MIN minutes, then SIGKILL after
# KILL_GRACE_SEC seconds; 124 = timed out.  Returns dnf-automatic's exit code,
# or systemd-inhibit's when the lock was refused.
# ---------------------------------------------------------------------------
run_dnf_automatic_under_inhibitor() {
    systemd-inhibit \
        --what="shutdown:sleep" \
        --who="dnf-automatic-reboot" \
        --why="dnf-automatic update in progress - do not reboot" \
        --mode="block" \
        timeout --kill-after="${KILL_GRACE_SEC}s" "${DNF_TIMEOUT_MIN}m" "${DNF_AUTOMATIC_BIN}"
}

# run_reboot_check -> needs-reboot.sh's exit code.
run_reboot_check() {
    "${LIBRARY_DIRECTORY}/needs-reboot.sh"
}

# ---------------------------------------------------------------------------
# Schedule a reboot through a transient systemd timer.
#
# Sets SCHEDULED_REBOOT_SUMMARY to the reboot time and the command that
# cancels it.  An active timer of the same name is an already scheduled
# reboot, from the watchdog or an earlier run, and is left as it is.
# ---------------------------------------------------------------------------
schedule_reboot() {
    local systemd_run_exit_code=0 reboot_time
    reboot_time=$(date -d "@$(( $(date +%s) + REBOOT_DELAY_SEC ))" '+%F %T %Z')
    SCHEDULED_REBOOT_SUMMARY="reboot scheduled for ${reboot_time}; update runs held until then; cancel with: ${CANCEL_REBOOT_COMMAND}"
    if "${SYSTEMCTL_BIN}" is-active --quiet "${SCHEDULED_REBOOT_UNIT}.timer" 2>/dev/null; then
        SCHEDULED_REBOOT_SUMMARY="reboot already scheduled; update runs held until then; cancel with: ${CANCEL_REBOOT_COMMAND}"
        log "${SCHEDULED_REBOOT_UNIT}.timer is already active - not scheduling a second reboot"
        return 0
    fi
    # A transient unit left failed by an earlier attempt in this boot keeps
    # its name taken until reset.
    "${SYSTEMCTL_BIN}" reset-failed "${SCHEDULED_REBOOT_UNIT}.service" "${SCHEDULED_REBOOT_UNIT}.timer" 2>/dev/null || true
    log "scheduling reboot in ${REBOOT_DELAY_SEC}s"
    wall_msg "dnf-automatic-reboot: Updates installed. System will reboot at ${reboot_time}." \
             "Cancel with: ${CANCEL_REBOOT_COMMAND}"
    # A named unit an operator can find and stop; OnFailure= reports a reboot
    # that systemctl could not start, such as one blocked by an inhibitor.
    "${SYSTEMD_RUN_BIN}" \
        --unit="${SCHEDULED_REBOOT_UNIT}" \
        --on-active="${REBOOT_DELAY_SEC}" \
        --timer-property=AccuracySec=1s \
        --property="OnFailure=dnf-automatic-reboot-notify@${SCHEDULED_REBOOT_UNIT}.service.service" \
        --description="dnf-automatic-reboot scheduled reboot" \
        "${SYSTEMCTL_BIN}" reboot || systemd_run_exit_code=$?
    if [[ "${systemd_run_exit_code}" -eq 0 ]]; then
        log "Reboot dispatch confirmed: ${SCHEDULED_REBOOT_UNIT}.timer fires at ${reboot_time}; cancel with: ${CANCEL_REBOOT_COMMAND}"
        return 0
    fi
    log_error "Reboot dispatch FAILED: systemd-run exited ${systemd_run_exit_code} - system will NOT reboot"
    wall_msg "dnf-automatic-reboot: ERROR - failed to schedule reboot (systemd-run exited ${systemd_run_exit_code})." \
             "Manual reboot required."
    return 1
}

# request_reboot
# Creates REBOOT_PENDING_FILE, which keeps this unit from starting until the
# reboot, then calls schedule_reboot.  Returns 0 when the reboot was
# scheduled; 1 when it was not, having removed the REBOOT_PENDING_FILE this
# call created.  A file that existed before belongs to an earlier request and
# is left alone.  When the run is stopped during the request, the file stays
# and cleanup reports it.
request_reboot() {
    local pending_file_created=0
    REBOOT_REQUEST_IN_PROGRESS=1
    if [[ ! -e "${REBOOT_PENDING_FILE}" ]]; then
        if ! : > "${REBOOT_PENDING_FILE}" 2>/dev/null; then
            REBOOT_REQUEST_IN_PROGRESS=0
            log_error "cannot create ${REBOOT_PENDING_FILE} - an update run could start before the reboot, reboot not requested"
            return 1
        fi
        pending_file_created=1
    fi
    if schedule_reboot; then
        REBOOT_REQUEST_IN_PROGRESS=0
        return 0
    fi
    if [[ "${pending_file_created}" -eq 1 ]]; then
        rm -f "${REBOOT_PENDING_FILE}"
    fi
    REBOOT_REQUEST_IN_PROGRESS=0
    return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local dnf_automatic_exit_code=0 needs_reboot_exit_code=0 service_restart_exit_code=0

    trap cleanup EXIT

    START_TIMESTAMP=$(date +%s)
    START_UPTIME_SECONDS=$(uptime_seconds)
    log "Starting (pid=${SERVICE_PID})"
    check_conflicts
    warn_on_unsigned_repositories

    # Detect concurrent dnf - warn but do not abort; dnf serialises via its
    # own lock so this is safe.  The warning gives admins a chance to hold off.
    if pgrep -x dnf > /dev/null 2>&1 || pgrep -x dnf-3 > /dev/null 2>&1 \
       || pgrep -x dnf-automatic > /dev/null 2>&1; then
        log_warning "dnf process already running - will contend on dnf lock"
        wall_msg "dnf-automatic-reboot: WARNING - manual dnf detected. Automatic update" \
                 "will wait for the dnf lock. Do not reboot manually until this completes."
    fi

    write_state "updating"

    wall_msg "dnf-automatic-reboot: Starting automatic updates. Reboot is inhibited until they complete."
    log "Running dnf-automatic under the inhibitor lock (timeout=${DNF_TIMEOUT_MIN}m kill_grace=${KILL_GRACE_SEC}s)"
    run_dnf_automatic_under_inhibitor || dnf_automatic_exit_code=$?

    if [[ "${dnf_automatic_exit_code}" -ne 0 ]]; then
        log_error "dnf-automatic, or the inhibitor lock taken before it, exited ${dnf_automatic_exit_code}"
        wall_msg "dnf-automatic-reboot: Update FAILED (exit ${dnf_automatic_exit_code})." \
                 "Manual inspection required."
        exit 1
    fi

    log "dnf-automatic completed successfully"
    warn_on_unapplied_security_advisories
    write_state "checking"

    # Decide whether a reboot is required.  Exit 0 = no reboot, 1 = reboot
    # needed; 2 = undecidable, and any other status is a helper failure.
    # Neither reboots, and both fail the run so the condition is surfaced
    # rather than silently ignored.
    run_reboot_check || needs_reboot_exit_code=$?

    if [[ "${ALWAYS_REBOOT}" == "yes" && "${needs_reboot_exit_code}" -eq 0 ]]; then
        log "always_reboot=yes in config - scheduling reboot regardless"
        needs_reboot_exit_code=1
    fi

    # The state file stays until cleanup at exit: restart_stale_services can
    # block, and the watchdog supervises the run only while the file exists.
    case "${needs_reboot_exit_code}" in
        0)
            log "No reboot required"
            restart_stale_services || service_restart_exit_code=$?
            report_completion "no reboot needed" "${service_restart_exit_code}"
            ;;
        1)
            request_reboot || exit 1
            SERVICE_RESTART_SUMMARY="service restarts skipped, the reboot replaces them"
            report_completion "${SCHEDULED_REBOOT_SUMMARY}" 0
            ;;
        *)
            log_error "needs-reboot.sh exited ${needs_reboot_exit_code}: reboot state could not be established - not rebooting. Updates were applied; the host may still need a manual reboot."
            restart_stale_services || true
            report_completion "reboot state UNDECIDABLE (needs-reboot.sh exited ${needs_reboot_exit_code}), not rebooting" 1
            ;;
    esac
}

# report_completion REBOOT_OUTCOME FAILED
# Logs and broadcasts one line naming the update, reboot and service-restart
# outcome of the run, with the command to inspect what is incomplete.  A
# non-zero FAILED logs it at error level and exits 1, so OnFailure= reports
# it.
report_completion() {
    local reboot_outcome="$1" run_failed="$2" completion_summary inspected_unit_names=()
    completion_summary="Updates installed; ${reboot_outcome}; ${SERVICE_RESTART_SUMMARY}"
    if [[ "${run_failed}" -eq 0 ]]; then
        log "${completion_summary}"
        wall_msg "dnf-automatic-reboot: ${completion_summary}."
        return 0
    fi
    inspected_unit_names=("${FAILED_SERVICE_NAMES[@]}" "${PENDING_SERVICE_NAMES[@]}")
    if [[ "${#inspected_unit_names[@]}" -gt 0 ]]; then
        completion_summary+=". Check: systemctl status $(join_with ' ' "${inspected_unit_names[@]}")"
    else
        completion_summary+=". Check: journalctl -u dnf-automatic-reboot.service -e"
    fi
    log_error "${completion_summary}"
    wall_msg "dnf-automatic-reboot: ${completion_summary}"
    exit 1
}

# Sourcing defines the functions above without running the update.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
