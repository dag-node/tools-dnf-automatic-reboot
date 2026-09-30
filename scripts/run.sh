#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# run.sh
# ---------------------------------------------------------------------------
# Main orchestration script for dnf-automatic-reboot.
#
# Sequence:
#   1. Detect concurrent dnf processes and warn via wall(1).
#   2. Acquire a systemd inhibitor lock so shutdown/reboot is blocked
#      for the duration of the update.
#   3. Write a state file consumed by watchdog.sh.
#   4. Run dnf-automatic under a hard wall-clock timeout.
#   5. On completion (or timeout), call needs-reboot.sh to decide whether
#      a reboot is required, filtering known false positives.
#   6. Release the inhibitor lock.
#   7. Schedule a reboot if needed; otherwise restart the services whose
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
readonly UPTIME_FILE="${TEST_ROOT}/proc/uptime"
readonly LOG_FILE="${TEST_ROOT}/var/log/dnf-automatic-reboot.log"
readonly LIBRARY_DIRECTORY="${TEST_ROOT}/usr/libexec/dnf-automatic-reboot"
readonly DNF_BIN="${TEST_ROOT}/usr/bin/dnf"
readonly DNF_AUTOMATIC_BIN="${TEST_ROOT}/usr/bin/dnf-automatic"
readonly SYSTEMD_RUN_BIN="${TEST_ROOT}/usr/bin/systemd-run"
readonly SYSTEMCTL_BIN="${TEST_ROOT}/usr/bin/systemctl"
readonly SLEEP_BIN="${TEST_ROOT}/usr/bin/sleep"
readonly SCRIPT_NAME=run
INHIBITOR_PID=0
SERVICE_PID=$$

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    printf '<6>%s: %s\n' "${SCRIPT_NAME}" "$*"
    printf '%s %s: %s\n' "$(date -Iseconds)" "${SCRIPT_NAME}" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}
log_warn() {
    printf '<4>%s: %s\n' "${SCRIPT_NAME}" "$*"
    printf '%s %s: WARNING: %s\n' "$(date -Iseconds)" "${SCRIPT_NAME}" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}
log_err() {
    printf '<3>%s: %s\n' "${SCRIPT_NAME}" "$*"
    printf '%s %s: ERROR: %s\n' "$(date -Iseconds)" "${SCRIPT_NAME}" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}

wall_msg() {
    local wall_messages_enabled
    wall_messages_enabled=$(conf_get wall_messages yes)
    wall_messages_enabled="${wall_messages_enabled//[[:space:]]/}"
    [[ "${wall_messages_enabled:-yes}" == "no" ]] && return 0
    wall "$*" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------
conf_get() {
    local config_key="$1" default_value="$2" config_value
    config_value=$(grep -E "^\s*${config_key}\s*=" "${CONFIG_FILE}" 2>/dev/null \
                   | tail -1 | sed 's/^[^=]*=\s*//' | sed 's/\s*#.*//') || true
    printf '%s' "${config_value:-${default_value}}"
}

conf_get_int() {
    local config_key="$1" default_value="$2" config_value
    config_value=$(conf_get "${config_key}" "${default_value}")
    config_value="${config_value//[[:space:]]/}"
    if [[ ! "${config_value}" =~ ^[0-9]+$ ]]; then
        log_warn "${config_key}='${config_value}' is not a non-negative integer - using default ${default_value}" >&2
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
        log_err "repositories with gpgcheck=0 are enabled: ${unsigned_repository_ids} - unattended updates from them install unsigned packages"
        wall_msg "dnf-automatic-reboot: WARNING - unsigned repositories enabled (${unsigned_repository_ids})." \
                 "Unattended updates from them are not signature-checked."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Pre-flight: abort if conflicting services would cause double-reboots
# ---------------------------------------------------------------------------
check_conflicts() {
    local conflict_found=0 conflicting_timer automatic_reboot_value

    for conflicting_timer in dnf-automatic.timer dnf-automatic-install.timer; do
        if systemctl is-enabled --quiet "${conflicting_timer}" 2>/dev/null || \
           systemctl is-active  --quiet "${conflicting_timer}" 2>/dev/null; then
            log_err "${conflicting_timer} is enabled/active - conflicts with this service; disable with: systemctl disable --now ${conflicting_timer}"
            conflict_found=1
        fi
    done

    if [[ -f "${AUTOMATIC_CONFIG_FILE}" ]]; then
        automatic_reboot_value=$(grep -E '^\s*reboot\s*=' "${AUTOMATIC_CONFIG_FILE}" 2>/dev/null \
                                 | tail -1 | sed 's/^[^=]*=\s*//' | sed 's/\s*#.*//' \
                                 | tr -d '[:space:]') || true
        if [[ -n "${automatic_reboot_value}" && "${automatic_reboot_value}" != "never" ]]; then
            log_err "/etc/dnf/automatic.conf has reboot = ${automatic_reboot_value}; set 'reboot = never' to avoid double-reboot conflicts"
            conflict_found=1
        fi
    fi

    if [[ "${conflict_found}" -ne 0 ]]; then
        log_err "Aborting: resolve the conflicts above, then restart the service"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Read config
# ---------------------------------------------------------------------------
REBOOT_DELAY_SEC=$(conf_get_int reboot_delay_sec 60)
ALWAYS_REBOOT=$(conf_get always_reboot no)
DNF_TIMEOUT_MIN=$(conf_get_int dnf_timeout_min 60)
KILL_GRACE_SEC=$(conf_get_int kill_grace_sec 30)
WARN_UNSIGNED_REPOSITORIES=$(conf_get warn_unsigned_repositories yes)
WARN_UNAPPLIED_ADVISORIES=$(conf_get warn_unapplied_advisories yes)
RESTART_SERVICES=$(conf_get restart_services yes)
RESTART_SERVICES_EXCLUDE=$(conf_get restart_services_exclude \
    "dbus.service,dbus-broker.service,systemd-logind.service,user@*.service,getty@*.service,serial-getty@*.service,autovt@*.service,dnf-automatic-reboot.service,dnf-automatic-watchdog.service")
NEEDS_RESTARTING_TIMEOUT_SEC=$(conf_get_int needs_restarting_timeout_sec 120)

# ---------------------------------------------------------------------------
# Cleanup handler - always runs on exit
# Releases inhibitor lock and removes state/lock files.
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    if [[ "${INHIBITOR_PID}" -gt 0 ]]; then
        kill "${INHIBITOR_PID}" 2>/dev/null || true
        wait "${INHIBITOR_PID}" 2>/dev/null || true
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

restart_stale_services() {
    local stale_service_output stale_service_name
    local restarted_service_names=() skipped_service_names=()

    if [[ "${RESTART_SERVICES}" != "yes" ]]; then
        log "restart_services=no - not restarting stale services"
        return 0
    fi

    stale_service_output=""
    if ! stale_service_output=$(timeout "${NEEDS_RESTARTING_TIMEOUT_SEC}s" \
            "${DNF_BIN}" -q -C needs-restarting -s 2>/dev/null); then
        log_warn "needs-restarting -s failed - stale services not restarted this run"
        return 0
    fi

    while IFS= read -r stale_service_name; do
        stale_service_name="${stale_service_name//[[:space:]]/}"
        [[ -n "${stale_service_name}" ]] || continue
        [[ "${stale_service_name}" == *.service ]] || continue

        if is_excluded_unit "${stale_service_name}"; then
            skipped_service_names+=("${stale_service_name}")
            continue
        fi

        if "${SYSTEMCTL_BIN}" try-restart "${stale_service_name}" 2>/dev/null; then
            restarted_service_names+=("${stale_service_name}")
        else
            log_warn "failed to restart ${stale_service_name} - it is still running pre-update code"
        fi
    done <<< "${stale_service_output}"

    if [[ "${#restarted_service_names[@]}" -gt 0 ]]; then
        log "Restarted stale services: $(printf '%s,' "${restarted_service_names[@]}" | sed 's/,$//')"
        wall_msg "dnf-automatic-reboot: restarted updated services:" \
                 "$(printf '%s ' "${restarted_service_names[@]}")"
    else
        log "No stale services needed restarting"
    fi

    if [[ "${#skipped_service_names[@]}" -gt 0 ]]; then
        log_warn "Excluded from automatic restart, still running pre-update code: $(printf '%s,' "${skipped_service_names[@]}" | sed 's/,$//')"
    fi
    return 0
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
        log_warn "security advisories still outstanding after this run: ${pending_advisory_ids}"
        return 0
    fi

    if [[ "${check_update_exit_code}" -ne 0 ]]; then
        log_warn "could not confirm whether ${pending_advisory_ids} are appliable (dnf check-update exited ${check_update_exit_code})"
        return 0
    fi

    log_err "security advisories apply to this host but dnf will not install them: ${pending_advisory_ids} - the host stays unpatched and every run will report success; check repository priority=, excludepkgs=, disabled repositories and versionlock"
    wall_msg "dnf-automatic-reboot: WARNING - security advisories (${pending_advisory_ids})" \
             "apply to this host but dnf refuses to install them. Updates are NOT complete." \
             "Diagnose: dnf --assumeno --setopt='*.priority=99' update --security"
    return 0
}

# ---------------------------------------------------------------------------
# Schedule a reboot through a transient systemd timer.
# ---------------------------------------------------------------------------
schedule_reboot() {
    local systemd_run_exit_code=0
    log "Scheduling reboot in ${REBOOT_DELAY_SEC}s"
    wall_msg "dnf-automatic-reboot: Updates complete. System will reboot in ${REBOOT_DELAY_SEC} seconds."
    "${SYSTEMD_RUN_BIN}" \
        --on-active="${REBOOT_DELAY_SEC}" \
        --timer-property=AccuracySec=1s \
        --description="dnf-automatic-reboot scheduled reboot" \
        "${SYSTEMCTL_BIN}" reboot || systemd_run_exit_code=$?
    if [[ "${systemd_run_exit_code}" -eq 0 ]]; then
        log "Reboot dispatch confirmed: systemd-run accepted the transient timer"
        return 0
    fi
    log_err "Reboot dispatch FAILED: systemd-run exited ${systemd_run_exit_code} - system will NOT reboot"
    wall_msg "dnf-automatic-reboot: ERROR - failed to schedule reboot (systemd-run exited ${systemd_run_exit_code})." \
             "Manual reboot required."
    return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local dnf_automatic_exit_code=0 needs_reboot_exit_code=0

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
        log_warn "dnf process already running - will contend on dnf lock"
        wall_msg "dnf-automatic-reboot: WARNING - manual dnf detected. Automatic update" \
                 "will wait for the dnf lock. Do not reboot manually until this completes."
    fi

    write_state "updating"

    # Acquire systemd inhibitor lock via background sleep.  The lock prevents
    # systemctl reboot/poweroff until we release it.  An admin can still
    # force-reboot with: systemctl reboot --force
    systemd-inhibit \
        --what="shutdown:sleep" \
        --who="dnf-automatic-reboot" \
        --why="dnf-automatic update in progress - do not reboot" \
        --mode="block" \
        "${SLEEP_BIN}" infinity &
    INHIBITOR_PID=$!
    log "Inhibitor lock acquired PID=${INHIBITOR_PID}"
    wall_msg "dnf-automatic-reboot: Starting automatic updates. Reboot is inhibited until complete."

    # Run dnf-automatic under a hard wall-clock timeout.  timeout sends
    # SIGTERM at DNF_TIMEOUT_MIN minutes, then SIGKILL after KILL_GRACE_SEC
    # seconds.  Exit code 124 = timed out.
    log "Running dnf-automatic (timeout=${DNF_TIMEOUT_MIN}m kill_grace=${KILL_GRACE_SEC}s)"
    timeout --kill-after="${KILL_GRACE_SEC}s" "${DNF_TIMEOUT_MIN}m" "${DNF_AUTOMATIC_BIN}" \
        || dnf_automatic_exit_code=$?

    if [[ "${dnf_automatic_exit_code}" -ne 0 ]]; then
        log_err "dnf-automatic exited ${dnf_automatic_exit_code}"
        wall_msg "dnf-automatic-reboot: Update FAILED (exit ${dnf_automatic_exit_code})." \
                 "Manual inspection required."
        exit 1
    fi

    log "dnf-automatic completed successfully"
    warn_on_unapplied_security_advisories
    write_state "checking"

    # Decide whether a reboot is required.  Exit 0 = no reboot, 1 = reboot
    # needed, 2 = undecidable (no reboot, but the run is failed so the
    # condition is surfaced rather than silently ignored).
    "${LIBRARY_DIRECTORY}/needs-reboot.sh" || needs_reboot_exit_code=$?

    if [[ "${ALWAYS_REBOOT}" == "yes" && "${needs_reboot_exit_code}" -eq 0 ]]; then
        log "always_reboot=yes in config - scheduling reboot regardless"
        needs_reboot_exit_code=1
    fi

    # Release the inhibitor lock BEFORE scheduling the reboot: a block-mode
    # inhibitor would prevent our own reboot call if still held.
    kill "${INHIBITOR_PID}" 2>/dev/null || true
    wait "${INHIBITOR_PID}" 2>/dev/null || true
    INHIBITOR_PID=0

    rm -f "${STATE_FILE}" "${LOCK_FILE}"
    trap - EXIT   # prevent double-cleanup after this point

    case "${needs_reboot_exit_code}" in
        1)
            schedule_reboot || exit 1
            ;;
        2)
            log_err "Reboot state could not be established - not rebooting. Updates were applied; the host may still need a manual reboot."
            wall_msg "dnf-automatic-reboot: ERROR - updates applied but the reboot decision could not be made." \
                     "Manual inspection required."
            restart_stale_services
            exit 1
            ;;
        *)
            log "No reboot required"
            restart_stale_services
            wall_msg "dnf-automatic-reboot: Updates complete. No reboot required."
            ;;
    esac
}

# Sourcing defines the functions above without running the update.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
