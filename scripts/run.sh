#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# run.sh
# ---------------------------------------------------------------------------
# Main orchestration script for dnf-automatic-reboot.
#
# Sequence:
#   0. Refuse to run while /etc/dnf/automatic-reboot.conf has an error, or
#      dnf-automatic's own configuration conflicts with this package.
#   1. Detect concurrent dnf processes and warn via wall(1).
#   2. Fetch current repository metadata, so dnf-automatic sees the
#      advisories published since dnf last refreshed its cache.
#   3. Write a state file consumed by watchdog.sh.
#   4. Run dnf-automatic as the child of a systemd inhibitor lock that
#      blocks shutdown and reboot until it exits.
#   5. Call needs-reboot.sh to decide whether a reboot is required,
#      filtering known false positives.
#   6. Schedule a reboot if needed; otherwise restart the services whose
#      running processes still map pre-update files.
#
# State file /run/dnf-automatic-reboot.state
#   phase=         updating | checking
#   start=         unix timestamp, for operators
#   start_uptime=  seconds since boot; the watchdog times the run from this
#                  because a host with no RTC steps its wall clock mid-run
#   pid=           PID of this script
#   dnf_log_inode= dnf.log's inode and size before dnf-automatic started,
#   dnf_log_offset= or "none" and 0; the watchdog reads the run's dnf phase
#                  from the lines after them
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
readonly PROC_DIRECTORY="${TEST_ROOT}/proc"
readonly UPTIME_FILE="${PROC_DIRECTORY}/uptime"
readonly LOG_FILE="${TEST_ROOT}/var/log/dnf-automatic-reboot.log"
readonly LIBRARY_DIRECTORY="${TEST_ROOT}/usr/libexec/dnf-automatic-reboot"
readonly DNF_BIN="${TEST_ROOT}/usr/bin/dnf"
readonly DNF_AUTOMATIC_BIN="${TEST_ROOT}/usr/bin/dnf-automatic"
readonly PLATFORM_PYTHON_BIN="${TEST_ROOT}/usr/libexec/platform-python"
# Its position before dnf-automatic starts goes into the state file: the
# watchdog reads the run's transaction phase from the lines after it.
readonly DNF_LOG_FILE="${TEST_ROOT}/var/log/dnf.log"
readonly CHECK_CONFIG_COMMAND=/usr/libexec/dnf-automatic-reboot/check-config.sh
# shellcheck disable=SC2034  # read by reboot-request.sh
readonly SYSTEMD_RUN_BIN="${TEST_ROOT}/usr/bin/systemd-run"
readonly SYSTEMCTL_BIN="${TEST_ROOT}/usr/bin/systemctl"
readonly SCRIPT_NAME=run

# load_config and config_value.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
# REBOOT_PENDING_FILE, the request lock, and request_reboot.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/reboot-request.sh"
# write_run_state and remove_run_state_if_unchanged.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/run-state.sh"
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

# send_wall_message TEXT... - broadcasts to logged-in users.  Always on: it
# carries the reboot warning with its cancel command.  Only for what a
# logged-in user has to know or act on: a reboot, a warning, a failure.  A
# run that starts and ends without one is logged, not broadcast.
send_wall_message() {
    wall "$*" 2>/dev/null || true
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
            # The false values of the libdnf OptionBool, in any case.
            if (tolower(section_enabled) ~ /^(0|no|false|off)$/) return 0
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
        send_wall_message "dnf-automatic-reboot: WARNING - unsigned repositories enabled (${unsigned_repository_ids})." \
                          "Unattended updates from them are not signature-checked."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# read_process_control_group PID -> the cgroup of PID in systemd's hierarchy:
# the name=systemd line of cgroup v1 (EL8), else the 0:: line of the unified
# hierarchy (EL9).  Returns 1 when the file cannot be read or names neither.
# ---------------------------------------------------------------------------
read_process_control_group() {
    local process_id="$1"
    awk '
        { control_group = $0; sub(/^[^:]*:[^:]*:/, "", control_group) }
        $0 ~ /^[0-9]+:name=systemd:/ { named_hierarchy = control_group }
        $0 ~ /^0::/                  { unified_hierarchy = control_group }
        END {
            if (named_hierarchy != "") print named_hierarchy
            else if (unified_hierarchy != "") print unified_hierarchy
            else exit 1
        }
    ' "${PROC_DIRECTORY}/${process_id}/cgroup" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Pre-flight: name every other dnf process already running.
#
# Warned, not fatal: dnf serialises on its own lock, so this run waits for it,
# and the warning gives a logged-in admin the chance to hold off.  Every dnf
# command shares the process name, so only its cgroup tells the
# distribution's dnf-makecache.service apart; its processes are left out.  A
# process is named by its PID, process name and cgroup, which says who started
# it; never by its arguments, which can carry a credential such as
# --setopt=proxy_password=, and the warning goes to every logged-in user.  A
# process whose cgroup cannot be read is no longer running.
# ---------------------------------------------------------------------------
warn_on_concurrent_dnf() {
    local process_id process_name process_control_group concurrent_dnf_processes=()

    while IFS=' ' read -r process_id process_name; do
        [[ "${process_id}" =~ ^[0-9]+$ ]] || continue
        process_control_group=$(read_process_control_group "${process_id}") || continue
        [[ "${process_control_group}" == */dnf-makecache.service ]] && continue
        concurrent_dnf_processes+=("pid ${process_id} ${process_name} in ${process_control_group//[^[:print:]]/?}")
    done < <(pgrep -l -x 'dnf|dnf-3|dnf-automatic' 2>/dev/null || true)

    [[ "${#concurrent_dnf_processes[@]}" -gt 0 ]] || return 0
    local concurrent_dnf_summary
    concurrent_dnf_summary=$(join_with "; " "${concurrent_dnf_processes[@]}")
    log_warning "another dnf command is running (${concurrent_dnf_summary}) - this run waits for the dnf lock"
    send_wall_message "dnf-automatic-reboot: WARNING - dnf is already running (${concurrent_dnf_summary})." \
                      "Automatic update will wait for the dnf lock. Do not reboot manually until this completes."
    return 0
}

# ---------------------------------------------------------------------------
# What dnf-automatic itself reads from /etc/dnf/automatic.conf, asked of its
# own config loader rather than parsed here, so a comment after a value, a key
# outside [commands] or a later [commands] section counts exactly as
# dnf-automatic counts it.  The query prints one line of AUTOMATIC_CONFIG_SHAPE;
# reboot is `unread` where dnf-automatic has no such option (EL8).  It fails
# when the loader cannot parse the file, as dnf-automatic would.  %pre in the
# spec runs a copy, which a test keeps identical.
# ---------------------------------------------------------------------------
readonly AUTOMATIC_CONFIG_QUERY='import sys
from dnf.automatic.main import AutomaticConfig
commands = AutomaticConfig(sys.argv[1]).commands
print("apply_updates=" + str(commands.apply_updates)
      + " download_updates=" + str(commands.download_updates)
      + " upgrade_type=" + str(commands.upgrade_type)
      + " reboot=" + str(getattr(commands, "reboot", "unread")))'
readonly AUTOMATIC_CONFIG_SHAPE='^apply_updates=(True|False) download_updates=(True|False) upgrade_type=([a-z]+) reboot=([a-z-]+)$'
readonly AUTOMATIC_CONFIG_REQUIRED_LINES="these lines under [commands], each on a line of its own with no comment after the value: upgrade_type = default (or security), download_updates = yes, apply_updates = yes, reboot = never"

# ---------------------------------------------------------------------------
# Pre-flight: abort if conflicting services would cause double-reboots, or if
# dnf-automatic would not install anything.
#
# Repeats the %pre checks on /etc/dnf/automatic.conf at every start, so an
# edit made after install fails the run through OnFailure= instead of
# producing silent successes.  The file is the operator's and is only read.
# ---------------------------------------------------------------------------
check_conflicts() {
    local conflict_found=0 conflicting_timer automatic_settings=""
    local apply_updates_value download_updates_value upgrade_type_value automatic_reboot_value

    for conflicting_timer in dnf-automatic.timer dnf-automatic-install.timer; do
        if systemctl is-enabled --quiet "${conflicting_timer}" 2>/dev/null || \
           systemctl is-active  --quiet "${conflicting_timer}" 2>/dev/null; then
            log_error "${conflicting_timer} is enabled/active - conflicts with this service; disable with: systemctl disable --now ${conflicting_timer}"
            conflict_found=1
        fi
    done

    # dnf-automatic exits 0 having installed nothing while download_updates or
    # apply_updates is off, and on EL9 reboots on its own unless reboot = never.
    automatic_settings=$(timeout --kill-after="${KILL_GRACE_SECONDS}s" "${DNF_QUERY_TIMEOUT_SECONDS}s" \
        "${PLATFORM_PYTHON_BIN}" -I -c "${AUTOMATIC_CONFIG_QUERY}" "${AUTOMATIC_CONFIG_FILE}" 2>/dev/null) \
        || automatic_settings=""
    if [[ ! "${automatic_settings}" =~ ${AUTOMATIC_CONFIG_SHAPE} ]]; then
        log_error "dnf-automatic cannot load /etc/dnf/automatic.conf, so it would fail with it; the file needs ${AUTOMATIC_CONFIG_REQUIRED_LINES}"
        conflict_found=1
    else
        apply_updates_value="${BASH_REMATCH[1]}"
        download_updates_value="${BASH_REMATCH[2]}"
        upgrade_type_value="${BASH_REMATCH[3]}"
        automatic_reboot_value="${BASH_REMATCH[4]}"
        if [[ "${apply_updates_value}" != "True" || "${download_updates_value}" != "True" ]]; then
            log_error "dnf-automatic reads download_updates = ${download_updates_value} and apply_updates = ${apply_updates_value} from /etc/dnf/automatic.conf, so it would install nothing and report success; the file needs ${AUTOMATIC_CONFIG_REQUIRED_LINES}"
            conflict_found=1
        fi
        if [[ "${upgrade_type_value}" != "default" && "${upgrade_type_value}" != "security" ]]; then
            log_error "dnf-automatic reads upgrade_type = ${upgrade_type_value} from /etc/dnf/automatic.conf; this version knows default and security; the file needs ${AUTOMATIC_CONFIG_REQUIRED_LINES}"
            conflict_found=1
        fi
        if [[ "${automatic_reboot_value}" != "never" && "${automatic_reboot_value}" != "unread" ]]; then
            log_error "dnf-automatic reads reboot = ${automatic_reboot_value} from /etc/dnf/automatic.conf and would reboot on its own; the file needs ${AUTOMATIC_CONFIG_REQUIRED_LINES}"
            conflict_found=1
        fi
    fi

    if [[ "${conflict_found}" -ne 0 ]]; then
        log_error "Aborting: resolve the conflicts above, then restart the service"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Read config.  An invalid file still yields well-formed values, so sourcing
# this script works; main refuses to run on it (exit_if_config_invalid).
# ---------------------------------------------------------------------------
load_config "${CONFIG_FILE}" || true
REQUIRE_CLOCK_SYNC=$(config_value require_clock_sync)
CLOCK_SYNC_TIMEOUT_SECONDS=$(config_value clock_sync_timeout_seconds)
METADATA_REFRESH_TIMEOUT_SECONDS=$(config_value metadata_refresh_timeout_seconds)
WARN_UNSIGNED_REPOSITORIES=$(config_value warn_unsigned_repositories)
WARN_UNAPPLIED_ADVISORIES=$(config_value warn_unapplied_advisories)
RESTART_SERVICES=$(config_value restart_services)
RESTART_SERVICES_EXCLUDED_PATTERNS=$(config_value restart_services_excluded_patterns)
DNF_QUERY_TIMEOUT_SECONDS=$(config_value dnf_query_timeout_seconds)
SERVICE_RESTART_TIMEOUT_SECONDS=$(config_value service_restart_timeout_seconds)

# Seconds between the reboot decision and the reboot: logged-in users get the
# time and the cancel command in a wall message.
readonly REBOOT_DELAY_SECONDS=300
# Seconds a due reboot keeps being retried while a shutdown inhibitor, such as
# a package transaction started by hand, blocks it; every 30 seconds, and
# cancellable in between.
readonly REBOOT_RETRY_TIMEOUT_SECONDS=1800

# Units never restarted, whatever the configuration adds: dbus and dbus-broker
# break every client holding a bus connection, systemd-logind drops session
# tracking, user@ ends that user's services and sessions, the getty and
# autovt instances log out their console, systemd refuses to restart auditd
# (RefuseManualStop=yes), and this package's own units would stop the run.
readonly BUILT_IN_EXCLUDED_UNIT_PATTERNS="dbus.service,dbus-broker.service,systemd-logind.service,auditd.service,user@*.service,getty@*.service,serial-getty@*.service,autovt@*.service,dnf-automatic-reboot.service,dnf-automatic-watchdog.service"
# The never-restart units whose pre-update code only a reboot replaces: system
# daemons with no session to wait for.  A getty or a user manager is replaced
# when its session ends, an operator's own exclusion by the operator, and this
# package's units end with the run.
readonly REBOOT_REQUIRING_UNIT_NAMES="dbus.service,dbus-broker.service,systemd-logind.service,auditd.service"

# exit_if_config_invalid - exits 1, before anything is refreshed, installed or
# rebooted, when the configuration has errors; logs each one and broadcasts
# that the run stopped.
exit_if_config_invalid() {
    local config_error
    [[ "${#CONFIG_ERRORS[@]}" -eq 0 ]] && return 0
    for config_error in "${CONFIG_ERRORS[@]}"; do
        log_error "configuration: ${config_error}"
    done
    log_error "not updating and not rebooting until ${CONFIG_FILE#"${TEST_ROOT}"} is valid - check it with: ${CHECK_CONFIG_COMMAND}"
    send_wall_message "dnf-automatic-reboot: Updates NOT started - ${CONFIG_FILE#"${TEST_ROOT}"} is invalid." \
                      "Check it with: ${CHECK_CONFIG_COMMAND}"
    exit 1
}

# Outcome of restart_stale_services, read by report_completion.
RESTARTED_SERVICE_NAMES=()
FAILED_SERVICE_NAMES=()
PENDING_SERVICE_NAMES=()
EXCLUDED_SERVICE_NAMES=()
CURRENT_SERVICE_NAMES=()
REBOOT_REQUIRING_SERVICE_NAMES=()
SERVICE_RESTART_SUMMARY="stale services not checked"
SCHEDULED_REBOOT_SUMMARY=""
# The state file content this run last published; empty before the first.
PUBLISHED_RUN_STATE=""
# dnf.log's inode and size before dnf-automatic started; "none" and 0 when it
# did not exist.  Set by record_dnf_log_position.
DNF_LOG_INODE="none"
DNF_LOG_OFFSET=0
# What dnf-automatic installed, for the completion line; set once it returns.
UPDATE_SUMMARY="update result unknown"
# Empty after a successful or disabled metadata refresh; otherwise the
# qualification the completion line carries, since "No updates installed" may
# then describe a stale cache.
METADATA_REFRESH_FAILURE_SUMMARY=""

# ---------------------------------------------------------------------------
# Cleanup handler - run by the EXIT trap
# Removes this run's state file and the lock file, and reports a reboot
# request cut short.  A state file another run has written since is kept.
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    report_interrupted_reboot_request
    if [[ -n "${PUBLISHED_RUN_STATE}" ]]; then
        remove_run_state_if_unchanged "${PUBLISHED_RUN_STATE}" || true
    fi
    rm -f "${LOCK_FILE}"
    log "Exiting rc=${exit_code}"
    exit "${exit_code}"
}

# ---------------------------------------------------------------------------
# State file writer
# ---------------------------------------------------------------------------
# publish_run_phase PHASE - publishes the state file through write_run_state.
# Returns 1 when it could not, and the previous file stays.
publish_run_phase() {
    local run_phase="$1" state_content
    state_content=$(printf 'phase=%s\nstart=%s\nstart_uptime=%s\npid=%s\ndnf_log_inode=%s\ndnf_log_offset=%s\n' \
        "${run_phase}" "${START_TIMESTAMP}" "${START_UPTIME_SECONDS}" "${SERVICE_PID}" \
        "${DNF_LOG_INODE}" "${DNF_LOG_OFFSET}")
    write_run_state "${state_content}" || return 1
    PUBLISHED_RUN_STATE="${state_content}"
}

# record_dnf_log_position - sets DNF_LOG_INODE and DNF_LOG_OFFSET from
# dnf.log as it is now, so the watchdog reads only what this run's
# dnf-automatic writes.  A log that does not exist yet is "none" at 0, which
# the watchdog reads as an unknown phase.
record_dnf_log_position() {
    local inode_and_size=""
    inode_and_size=$(stat -c '%i %s' "${DNF_LOG_FILE}" 2>/dev/null) || inode_and_size=""
    if [[ "${inode_and_size}" =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
        DNF_LOG_INODE="${BASH_REMATCH[1]}"
        DNF_LOG_OFFSET="${BASH_REMATCH[2]}"
    else
        DNF_LOG_INODE="none"
        DNF_LOG_OFFSET=0
    fi
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
# unit_matches_patterns UNIT_NAME PATTERN_LIST - succeeds when UNIT_NAME
# matches an entry of the comma-separated PATTERN_LIST.  An entry is a unit
# name or a bash glob such as user@*.service, which covers every instance of a
# template unit.
unit_matches_patterns() {
    local unit_name="$1" unit_pattern previous_ifs
    local unit_patterns=()
    previous_ifs="${IFS}"
    IFS=',' read -ra unit_patterns <<< "$2"
    IFS="${previous_ifs}"
    for unit_pattern in "${unit_patterns[@]}"; do
        [[ -n "${unit_pattern}" ]] || continue
        # shellcheck disable=SC2053  # the entry is a glob by design
        if [[ "${unit_name}" == ${unit_pattern} ]]; then
            return 0
        fi
    done
    return 1
}

# is_excluded_unit UNIT_NAME - succeeds when UNIT_NAME matches a built-in
# exclusion or an entry of restart_services_excluded_patterns.
is_excluded_unit() {
    unit_matches_patterns "$1" \
        "${BUILT_IN_EXCLUDED_UNIT_PATTERNS}${RESTART_SERVICES_EXCLUDED_PATTERNS:+,${RESTART_SERVICES_EXCLUDED_PATTERNS}}"
}

# ---------------------------------------------------------------------------
# What a flagged unit really runs.
#
# needs-restarting flags a unit when one of its processes maps a file of a
# package installed after the start it computes for that process.  It takes
# the start from /proc/PID/stat split on spaces, so a process name holding a
# space, such as spamd's "spamd child", shifts the fields: the start reads as
# 0, the process as old as the boot, and its unit is flagged at every run once
# it maps a file installed since boot.
#
# This package reads its own evidence from /proc for every flagged unit:
#   stale    a process maps a deleted file of a package installed after that
#            process started: an update replaced the file under it
#   current  no process maps a deleted file a package owns, and every process
#            started after the newest package install, so none can hold
#            replaced code read at start or inherited from an older parent
#   unknown  everything else: a deleted package file with no later install
#            (an application rewriting its own data), an older process, an
#            unreadable /proc entry or an rpm query that failed
# A unit is left running only when it is current.  A reboot is requested only
# for a stale unit of REBOOT_REQUIRING_UNIT_NAMES, and those are judged
# whether or not needs-restarting listed them.  After that reboot no process
# maps a file replaced since it started until another update replaces one, so
# the request cannot repeat.
# ---------------------------------------------------------------------------
# Set by read_process_evidence, once per restart pass.
PROCESS_CONTROL_GROUPS=""        # one "PID CGROUP" line per process
PROCESS_START_EVIDENCE="unread"  # read | unavailable
NEWEST_PACKAGE_INSTALL_EPOCH=""
BOOT_EPOCH=""
CLOCK_TICKS_PER_SECOND=""
# Deleted mapped path -> the INSTALLTIME of the package owning it, "unowned"
# or "unknown", so rpm is asked once per path.
declare -gA DELETED_FILE_INSTALL_EPOCHS=()
# Set by read_unit_code_state: current | stale | unknown.
UNIT_CODE_STATE="unknown"

# read_newest_package_install_epoch -> the latest rpm INSTALLTIME on the host.
# Returns 1 when rpm gives no number.
read_newest_package_install_epoch() {
    local newest_install_epoch
    newest_install_epoch=$(rpm -qa --qf '%{INSTALLTIME}\n' 2>/dev/null | sort -n | tail -n 1) || return 1
    [[ "${newest_install_epoch}" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "${newest_install_epoch}"
}

# read_boot_epoch -> btime of /proc/stat, the second the kernel booted.
# Returns 1 when the file has no such line.
read_boot_epoch() {
    local stat_key stat_value
    while IFS=' ' read -r stat_key stat_value _; do
        if [[ "${stat_key}" == "btime" && "${stat_value}" =~ ^[0-9]+$ ]]; then
            printf '%s' "${stat_value}"
            return 0
        fi
    done < <(cat "${PROC_DIRECTORY}/stat" 2>/dev/null)
    return 1
}

# read_process_start_epoch PID -> the second the process started.  Its name
# can hold spaces and parentheses, so the fields are counted from the last
# ")": the start time, in clock ticks since boot, is the 20th after it.
# Returns 1 when the file cannot be read or is of another shape.
read_process_start_epoch() {
    local process_id="$1" stat_line fields_after_name=()
    stat_line=$(cat "${PROC_DIRECTORY}/${process_id}/stat" 2>/dev/null) || return 1
    [[ "${stat_line}" == *") "* ]] || return 1
    IFS=' ' read -r -a fields_after_name <<< "${stat_line##*) }"
    [[ "${fields_after_name[19]:-}" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$(( BOOT_EPOCH + fields_after_name[19] / CLOCK_TICKS_PER_SECOND ))"
}

# read_process_evidence - sets PROCESS_CONTROL_GROUPS, and
# PROCESS_START_EVIDENCE to "read" with NEWEST_PACKAGE_INSTALL_EPOCH,
# BOOT_EPOCH and CLOCK_TICKS_PER_SECOND, or to "unavailable" when one of the
# three cannot be read; no unit is then taken for current.
read_process_evidence() {
    local process_directory process_id control_group
    PROCESS_CONTROL_GROUPS=""
    DELETED_FILE_INSTALL_EPOCHS=()
    for process_directory in "${PROC_DIRECTORY}"/[0-9]*; do
        process_id="${process_directory##*/}"
        control_group=$(read_process_control_group "${process_id}") || continue
        PROCESS_CONTROL_GROUPS+="${process_id} ${control_group}"$'\n'
    done
    PROCESS_START_EVIDENCE="unavailable"
    NEWEST_PACKAGE_INSTALL_EPOCH=$(read_newest_package_install_epoch) || return 0
    BOOT_EPOCH=$(read_boot_epoch) || return 0
    CLOCK_TICKS_PER_SECOND=$(getconf CLK_TCK 2>/dev/null) || return 0
    [[ "${CLOCK_TICKS_PER_SECOND}" =~ ^[1-9][0-9]*$ ]] || return 0
    PROCESS_START_EVIDENCE="read"
}

# read_deleted_file_install_epoch PATH - sets
# DELETED_FILE_INSTALL_EPOCHS[PATH] to the latest INSTALLTIME among the
# packages owning PATH, to "unowned" when rpm says no package owns it or it
# does not exist, and to "unknown" for any other answer.
read_deleted_file_install_epoch() {
    local file_path="$1" query_output install_epoch newest_install_epoch=""
    if query_output=$(rpm -qf --qf '%{INSTALLTIME}\n' "${file_path}" 2>&1); then
        while IFS= read -r install_epoch; do
            [[ "${install_epoch}" =~ ^[0-9]+$ ]] || continue
            if [[ -z "${newest_install_epoch}" || "${install_epoch}" -gt "${newest_install_epoch}" ]]; then
                newest_install_epoch="${install_epoch}"
            fi
        done <<< "${query_output}"
        DELETED_FILE_INSTALL_EPOCHS["${file_path}"]="${newest_install_epoch:-unknown}"
    elif [[ "${query_output}" == *"is not owned by any package"* \
            || "${query_output}" == *"No such file or directory"* ]]; then
        DELETED_FILE_INSTALL_EPOCHS["${file_path}"]="unowned"
    else
        DELETED_FILE_INSTALL_EPOCHS["${file_path}"]="unknown"
    fi
}

# judge_process_mappings PID START_EPOCH
# Returns: 0 = the process maps a deleted file of a package installed after
#              START_EPOCH: an update replaced it
#          1 = it maps no deleted file a package owns
#          2 = it maps a deleted package file with no later install, START_EPOCH
#              is empty, or its maps or the file's owner cannot be read
# rpm renames a file it replaces to "<name>;<hex>" before removing it on the
# kernels that show the mapping under that name, so the suffix is dropped.  A
# deleted mapping no package owns, such as a memfd or a temporary file, is
# not evidence.
judge_process_mappings() {
    local process_id="$1" process_start_epoch="$2"
    local maps_content maps_line mapped_path file_install_epoch judgement=1
    maps_content=$(cat "${PROC_DIRECTORY}/${process_id}/maps" 2>/dev/null) || return 2
    while IFS= read -r maps_line; do
        [[ "${maps_line}" == *" /"*" (deleted)" ]] || continue
        mapped_path="/${maps_line#* /}"
        mapped_path="${mapped_path% (deleted)}"
        if [[ "${mapped_path}" =~ ^(.+)\;[0-9A-Fa-f]{8,}$ ]]; then
            mapped_path="${BASH_REMATCH[1]}"
        fi
        if [[ -z "${DELETED_FILE_INSTALL_EPOCHS[${mapped_path}]:-}" ]]; then
            read_deleted_file_install_epoch "${mapped_path}"
        fi
        file_install_epoch="${DELETED_FILE_INSTALL_EPOCHS[${mapped_path}]}"
        [[ "${file_install_epoch}" != "unowned" ]] || continue
        if [[ "${file_install_epoch}" != "unknown" && -n "${process_start_epoch}" ]] \
           && (( file_install_epoch > process_start_epoch )); then
            return 0
        fi
        judgement=2
    done <<< "${maps_content}"
    return "${judgement}"
}

# read_unit_code_state UNIT_NAME - sets UNIT_CODE_STATE to stale, current or
# unknown from the processes in the unit's cgroup and the cgroups below it.
# A process that has exited since the listing is left out.  Not to be called
# in a command substitution: DELETED_FILE_INSTALL_EPOCHS would not be kept.
read_unit_code_state() {
    local unit_name="$1" process_id control_group process_start_epoch mappings_judgement
    local unit_process_count=0 freshness_unproven=0
    UNIT_CODE_STATE="unknown"
    while IFS=' ' read -r process_id control_group; do
        [[ "${control_group}" == */"${unit_name}" || "${control_group}" == */"${unit_name}"/* ]] || continue
        [[ -d "${PROC_DIRECTORY}/${process_id}" ]] || continue
        unit_process_count=$(( unit_process_count + 1 ))
        process_start_epoch=""
        if [[ "${PROCESS_START_EVIDENCE}" == "read" ]]; then
            process_start_epoch=$(read_process_start_epoch "${process_id}") || process_start_epoch=""
        fi
        mappings_judgement=0
        judge_process_mappings "${process_id}" "${process_start_epoch}" || mappings_judgement=$?
        if [[ "${mappings_judgement}" -eq 0 ]]; then
            UNIT_CODE_STATE="stale"
            return 0
        fi
        if [[ "${mappings_judgement}" -ne 1 || -z "${process_start_epoch}" ]] \
           || (( process_start_epoch <= NEWEST_PACKAGE_INSTALL_EPOCH )); then
            freshness_unproven=1
        fi
    done <<< "${PROCESS_CONTROL_GROUPS}"
    if (( unit_process_count > 0 && freshness_unproven == 0 )); then
        UNIT_CODE_STATE="current"
    fi
    return 0
}

# restart_stale_services [reboot-allowed]
# Sets SERVICE_RESTART_SUMMARY to one clause naming every outcome, and the
# RESTARTED_, FAILED_, PENDING_, EXCLUDED_, CURRENT_ and
# REBOOT_REQUIRING_SERVICE_NAMES arrays.  Returns 1 when a restart failed or
# had not finished within service_restart_timeout_seconds, or when
# `dnf needs-restarting -s` failed to list the services: each leaves
# pre-update code running that the run was meant to replace.  Excluded units
# are left running by design, and a current unit runs no pre-update code;
# neither fails the run.
#
# With reboot-allowed, a stale unit of REBOOT_REQUIRING_UNIT_NAMES is named in
# REBOOT_REQUIRING_SERVICE_NAMES, listed by needs-restarting or not, and
# nothing is restarted: the caller requests the reboot, which replaces every
# restart.  Without it such a unit is reported with the other excluded units
# when needs-restarting listed it.  restart_services = no turns off the whole
# pass, this reboot included.
restart_stale_services() {
    local reboot_allowed="${1:-}"
    local stale_service_output stale_service_name restart_exit_code restart_error_output previous_ifs
    local restartable_service_names=() reboot_requiring_unit_names=() summary_clauses=()
    local -A judged_service_names=()
    RESTARTED_SERVICE_NAMES=()
    FAILED_SERVICE_NAMES=()
    PENDING_SERVICE_NAMES=()
    EXCLUDED_SERVICE_NAMES=()
    CURRENT_SERVICE_NAMES=()
    REBOOT_REQUIRING_SERVICE_NAMES=()
    SERVICE_RESTART_SUMMARY=""

    if [[ "${RESTART_SERVICES}" != "yes" ]]; then
        log "restart_services=no - not restarting stale services"
        SERVICE_RESTART_SUMMARY="stale services not checked (restart_services = no)"
        return 0
    fi

    stale_service_output=""
    if ! stale_service_output=$(timeout --kill-after="${KILL_GRACE_SECONDS}s" "${DNF_QUERY_TIMEOUT_SECONDS}s" \
            "${DNF_BIN}" -q -C needs-restarting -s 2>/dev/null); then
        log_error "needs-restarting -s failed - stale services not restarted this run"
        SERVICE_RESTART_SUMMARY="stale services could not be listed (needs-restarting -s failed)"
        return 1
    fi

    # Every flagged unit is judged before any is restarted: one that needs a
    # reboot replaces every restart.
    PROCESS_START_EVIDENCE="unread"
    while IFS= read -r stale_service_name; do
        stale_service_name="${stale_service_name//[[:space:]]/}"
        [[ -n "${stale_service_name}" ]] || continue
        [[ "${stale_service_name}" == *.service ]] || continue

        if [[ "${PROCESS_START_EVIDENCE}" == "unread" ]]; then
            read_process_evidence
        fi
        judged_service_names["${stale_service_name}"]=1
        read_unit_code_state "${stale_service_name}"
        if [[ "${UNIT_CODE_STATE}" == "current" ]]; then
            CURRENT_SERVICE_NAMES+=("${stale_service_name}")
        elif ! is_excluded_unit "${stale_service_name}"; then
            restartable_service_names+=("${stale_service_name}")
        elif [[ "${UNIT_CODE_STATE}" == "stale" && "${reboot_allowed}" == "reboot-allowed" ]] \
             && unit_matches_patterns "${stale_service_name}" "${REBOOT_REQUIRING_UNIT_NAMES}"; then
            REBOOT_REQUIRING_SERVICE_NAMES+=("${stale_service_name}")
        else
            EXCLUDED_SERVICE_NAMES+=("${stale_service_name}")
        fi
    done <<< "${stale_service_output}"

    # The daemons a reboot is requested for do not depend on the listing.
    if [[ "${reboot_allowed}" == "reboot-allowed" ]]; then
        previous_ifs="${IFS}"
        IFS=',' read -ra reboot_requiring_unit_names <<< "${REBOOT_REQUIRING_UNIT_NAMES}"
        IFS="${previous_ifs}"
        for stale_service_name in "${reboot_requiring_unit_names[@]}"; do
            [[ -z "${judged_service_names[${stale_service_name}]:-}" ]] || continue
            if [[ "${PROCESS_START_EVIDENCE}" == "unread" ]]; then
                read_process_evidence
            fi
            read_unit_code_state "${stale_service_name}"
            if [[ "${UNIT_CODE_STATE}" == "stale" ]]; then
                REBOOT_REQUIRING_SERVICE_NAMES+=("${stale_service_name}")
            fi
        done
    fi

    if [[ "${#REBOOT_REQUIRING_SERVICE_NAMES[@]}" -gt 0 ]]; then
        SERVICE_RESTART_SUMMARY="reboot needed for $(join_with ', ' "${REBOOT_REQUIRING_SERVICE_NAMES[@]}"), on pre-update code and not restartable; service restarts skipped, the reboot replaces them"
        return 0
    fi

    for stale_service_name in "${restartable_service_names[@]}"; do
        # Bounded: a unit that hangs in stop or start must not hold the run.
        # Stopping the systemctl client leaves the restart job to systemd.
        # systemctl's stderr is kept for the log: it names why a restart failed.
        restart_exit_code=0
        restart_error_output=$(timeout --kill-after="${KILL_GRACE_SECONDS}s" "${SERVICE_RESTART_TIMEOUT_SECONDS}s" \
            "${SYSTEMCTL_BIN}" try-restart "${stale_service_name}" 2>&1 >/dev/null) \
            || restart_exit_code=$?
        # 124: still waiting at the deadline; 137: killed after the grace.
        if [[ "${restart_exit_code}" -eq 0 ]]; then
            RESTARTED_SERVICE_NAMES+=("${stale_service_name}")
        elif [[ "${restart_exit_code}" -eq 124 || "${restart_exit_code}" -eq 137 ]]; then
            PENDING_SERVICE_NAMES+=("${stale_service_name}")
            log_warning "restart of ${stale_service_name} did not finish within ${SERVICE_RESTART_TIMEOUT_SECONDS}s - the job continues in systemd"
        else
            FAILED_SERVICE_NAMES+=("${stale_service_name}")
            restart_error_output=${restart_error_output%%$'\n'*}
            log_warning "failed to restart ${stale_service_name} - it is still running pre-update code${restart_error_output:+ (systemctl: ${restart_error_output})}"
        fi
    done

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
    if [[ "${#CURRENT_SERVICE_NAMES[@]}" -gt 0 ]]; then
        summary_clauses+=("flagged but on current code, not restarted: $(join_with ', ' "${CURRENT_SERVICE_NAMES[@]}")")
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
# Post-update: report security advisories this run did not install.
#
# A repository priority=, an excludepkgs=, a versionlock or a dependency dnf
# cannot satisfy can keep an advisory's update off the host for good, and the
# update run reports success either way, so the host quietly never receives the
# fix - the failure this package exists to prevent, one layer further down.
#
# Called only after dnf-automatic exited 0, set (check_conflicts) to download
# and install every update of its upgrade_type.  That run is the transaction
# check: a security advisory still listed for an installed package afterwards
# is one dnf did not install, whatever kept it out, so no cause is enumerated
# and no second transaction is resolved.  `--updates` lists only packages the
# sack offers, and excludepkgs= removes packages from the sack, so the listing
# runs with --disableexcludes=all; versionlock filters only while dnf resolves
# a transaction, which updateinfo does not.  Every package row is reported, as
# one advisory can cover several packages and only some be kept out.  One
# query, under one timeout; a listing that fails is reported as incomplete.
# ---------------------------------------------------------------------------
warn_on_unapplied_security_advisories() {
    local advisory_listing listing_exit_code=0 unapplied_advisories unapplied_advisory_ids

    [[ "${WARN_UNAPPLIED_ADVISORIES}" == "yes" ]] || return 0

    advisory_listing=$(timeout --kill-after="${KILL_GRACE_SECONDS}s" "${DNF_QUERY_TIMEOUT_SECONDS}s" \
        "${DNF_BIN}" -q -C --disableexcludes=all updateinfo list --updates --security 2>/dev/null) \
        || listing_exit_code=$?
    if [[ "${listing_exit_code}" -ne 0 ]]; then
        log_warning "could not list the security advisories that apply to this host (dnf updateinfo exited ${listing_exit_code}); this run's report of uninstalled advisories is incomplete"
        return 0
    fi

    # Rows are matched by shape, not by excluding header text, so a line of any
    # other shape is not reported.  An advisory ID is PREFIX-YEAR-NUMBER or
    # PREFIX-YEAR:NUMBER with an optional `-REVISION`, the prefix one or more
    # dash-joined words and the number alphanumeric (Oracle ELSA-2026-26533 and
    # ELSA-2026-60226-0, Red Hat RHSA-2020:3011, EPEL
    # FEDORA-EPEL-2024-bf31852fe0); the package is the row's last field, an
    # NEVRA of rpm's characters, or `?` when it is of another shape, so the
    # advisory is still reported.  Prints `ID (PACKAGE, PACKAGE)` per advisory.
    unapplied_advisories=$(printf '%s\n' "${advisory_listing}" | awk '
        NF >= 3 && $1 ~ /^[A-Za-z]+(-[A-Za-z]+)*-[0-9]+[-:][0-9A-Za-z]+(-[0-9]+)?$/ {
            print $1 "\t" ($NF ~ /^[A-Za-z0-9._+~^:-]+$/ ? $NF : "?")
        }
    ' | sort -u | awk -F'\t' '
        $1 != advisory_id { if (advisory_id != "") print advisory_id " (" packages ")"; advisory_id = $1; packages = $2; next }
        { packages = packages ", " $2 }
        END { if (advisory_id != "") print advisory_id " (" packages ")" }
    ')
    [[ -n "${unapplied_advisories}" ]] || return 0

    unapplied_advisory_ids=$(printf '%s\n' "${unapplied_advisories}" | awk '{ print $1 }' | paste -sd, -)
    log_error "security advisories apply to this host but this run did not install them: $(printf '%s\n' "${unapplied_advisories}" | paste -sd';' - | sed 's/;/; /g') - the host stays unpatched while every run reports success; check excludepkgs=, repository priority=, versionlock and dnf's dependency errors"
    send_wall_message "dnf-automatic-reboot: WARNING - security advisories (${unapplied_advisory_ids})" \
                      "apply to this host but were not installed. Updates are NOT complete." \
                      "Diagnose: dnf --assumeno --disableexcludes=all --setopt='*.priority=99' update --security"
    return 0
}

# ---------------------------------------------------------------------------
# Run dnf-automatic under the inhibitor lock.
#
# systemd-inhibit takes a block-mode shutdown:sleep lock from logind before it
# starts its command, holds it for exactly as long as that command runs, and
# exits non-zero without starting the command when the lock is refused.  No
# update runs unprotected, and the lock is gone before any reboot is
# scheduled.  An admin can still force-reboot with: systemctl reboot --force
#
# There is no deadline: a deadline stops dnf whatever it is doing, an rpm
# transaction included.  The watchdog stops the run once dnf stalls.
# Returns dnf-automatic's exit code, or systemd-inhibit's when the lock was
# refused.
# ---------------------------------------------------------------------------
run_dnf_automatic_under_inhibitor() {
    systemd-inhibit \
        --what="shutdown:sleep" \
        --who="dnf-automatic-reboot" \
        --why="dnf-automatic update in progress - do not reboot" \
        --mode="block" \
        "${DNF_AUTOMATIC_BIN}"
}

# run_reboot_check -> needs-reboot.sh's exit code.
run_reboot_check() {
    "${LIBRARY_DIRECTORY}/needs-reboot.sh"
}

# ---------------------------------------------------------------------------
# schedule_reboot - the run's delayed reboot, a dispatch function for
# request_reboot.  Returns 0 accepted, 1 rejected, 2 unknown, and sets
# SCHEDULED_REBOOT_SUMMARY to the reboot time and the command that cancels
# it.  A reboot already waiting, from an earlier run, is left as it is.
# ---------------------------------------------------------------------------
schedule_reboot() {
    local reboot_time submit_result=0
    reboot_time=$(date -d "@$(( $(date +%s) + REBOOT_DELAY_SECONDS ))" '+%F %T %Z')
    log "scheduling reboot in ${REBOOT_DELAY_SECONDS}s"
    submit_reboot "${REBOOT_DELAY_SECONDS}" "${REBOOT_REQUEST_LOCK_TIMEOUT_SECONDS}" "${REBOOT_RETRY_TIMEOUT_SECONDS}" \
        "dnf-automatic-reboot scheduled reboot" \
        || submit_result=$?
    case "${submit_result}" in
        0)
            if [[ "${SCHEDULED_REBOOT_ALREADY_PRESENT}" -eq 1 ]]; then
                SCHEDULED_REBOOT_SUMMARY="reboot already scheduled; update runs held until then; cancel with: ${CANCEL_REBOOT_COMMAND}"
                return 0
            fi
            SCHEDULED_REBOOT_SUMMARY="reboot scheduled for ${reboot_time}; update runs held until then; cancel with: ${CANCEL_REBOOT_COMMAND}"
            log "Reboot dispatch confirmed: ${SCHEDULED_REBOOT_UNIT}.timer fires at ${reboot_time}"
            send_wall_message "dnf-automatic-reboot: System will reboot at ${reboot_time}." \
                              "Cancel with: ${CANCEL_REBOOT_COMMAND}"
            return 0
            ;;
        1)
            log_error "Reboot dispatch FAILED - system will NOT reboot"
            send_wall_message "dnf-automatic-reboot: ERROR - failed to schedule reboot." \
                              "Manual reboot required."
            return 1
            ;;
    esac
    send_wall_message "dnf-automatic-reboot: ERROR - cannot tell whether the reboot was scheduled." \
                      "Update runs stay held. Check: systemctl list-timers ${SCHEDULED_REBOOT_UNIT}.timer"
    return 2
}

# chronyc_available - 0 when chronyc can be run.
chronyc_available() {
    command -v chronyc >/dev/null 2>&1
}

# Bound on the one chronyc query a failed clock check makes for its message.
readonly CHRONYC_REPLY_TIMEOUT_SECONDS=10

# chronyc_sync_reply -> the last line chronyc prints for one synchronisation
# query, its "try:" line or its error, as printable ASCII, or a note that none
# came.  It goes into the log only; nothing parses it.
chronyc_sync_reply() {
    local chronyc_reply
    chronyc_reply=$(timeout --kill-after="${KILL_GRACE_SECONDS}s" "${CHRONYC_REPLY_TIMEOUT_SECONDS}s" \
                        chronyc waitsync 1 0.1 0 1 2>&1 \
                    | tail -n 1 | tr -cd '[:print:]' | cut -c1-200) || true
    printf '%s' "${chronyc_reply:-no reply within ${CHRONYC_REPLY_TIMEOUT_SECONDS}s}"
}

# wait_for_clock_sync - 0 once chronyd reports the clock synchronised, within
# CLOCK_SYNC_TIMEOUT_SECONDS; 1 when it does not, or cannot be asked.
# The unit's ordering on time-sync.target does not require a successful
# synchronisation: the target is reached after chrony-wait.service fails,
# and is reached at once when nothing is ordered before it.  rpm INSTALLTIME
# stamps written with a wrong clock skew every later reboot decision, so the
# run checks the clock itself.  chronyc waitsync asks chronyd every 10 s and
# succeeds once its remaining correction is below 0.1 s.  Each request takes
# time of its own on top of the interval, and the run is not yet supervised
# by the watchdog, so timeout(1) enforces the deadline: SIGTERM at
# CLOCK_SYNC_TIMEOUT_SECONDS, SIGKILL KILL_GRACE_SECONDS later.
wait_for_clock_sync() {
    local waitsync_tries waitsync_exit_code=0
    if [[ "${REQUIRE_CLOCK_SYNC}" == "no" ]]; then
        return 0
    fi
    if ! chronyc_available; then
        log_error "chronyc not found - cannot confirm the clock is synchronised; install chrony, or set require_clock_sync = no"
        return 1
    fi
    waitsync_tries=$(( (CLOCK_SYNC_TIMEOUT_SECONDS + 9) / 10 ))
    timeout --kill-after="${KILL_GRACE_SECONDS}s" "${CLOCK_SYNC_TIMEOUT_SECONDS}s" \
        chronyc waitsync "${waitsync_tries}" 0.1 0 10 >/dev/null 2>&1 || waitsync_exit_code=$?
    if [[ "${waitsync_exit_code}" -eq 0 ]]; then
        log "clock synchronised (chronyc waitsync)"
        return 0
    fi
    # The waiting query's output is discarded: a client stopped by timeout(1)
    # can lose what it buffered.  One more query states why for the log.
    # 124: still waiting at the deadline; 137: killed after the grace.
    if [[ "${waitsync_exit_code}" -eq 124 || "${waitsync_exit_code}" -eq 137 ]]; then
        log_error "chronyc waitsync was still running at ${CLOCK_SYNC_TIMEOUT_SECONDS}s and was stopped (chronyc: $(chronyc_sync_reply)) - check: systemctl status chronyd; chronyc tracking"
    else
        log_error "chronyd did not report a synchronised clock within ${CLOCK_SYNC_TIMEOUT_SECONDS}s (chronyc: $(chronyc_sync_reply)) - check: systemctl status chronyd; chronyc tracking"
    fi
    return 1
}

# refresh_repository_metadata - 0 once dnf has fetched current metadata for
# every enabled repository; 1 when the fetch
# fails or is still running at METADATA_REFRESH_TIMEOUT_SECONDS.  dnf-automatic
# installs from the cache and fetches only what is older than
# metadata_expire, so without this step an advisory published since the last
# refresh waits for the next run.  timeout(1) bounds the fetch: the watchdog
# does not supervise the run yet.  The caller continues on failure:
# dnf-automatic then uses the cache as it did before, and the completion
# line says so.
refresh_repository_metadata() {
    local refresh_exit_code=0 refresh_output refresh_failure_detail=""
    refresh_output=$(timeout --kill-after="${KILL_GRACE_SECONDS}s" "${METADATA_REFRESH_TIMEOUT_SECONDS}s" \
        "${DNF_BIN}" -q makecache --refresh 2>&1) || refresh_exit_code=$?
    if [[ "${refresh_exit_code}" -eq 0 ]]; then
        log "repository metadata refreshed (dnf makecache --refresh)"
        return 0
    fi
    # 124: still fetching at the deadline; 137: killed after the grace.
    if [[ "${refresh_exit_code}" -eq 124 || "${refresh_exit_code}" -eq 137 ]]; then
        log_warning "dnf makecache --refresh was still running at ${METADATA_REFRESH_TIMEOUT_SECONDS}s and was stopped - updating from the metadata dnf has cached"
    else
        if [[ -n "${refresh_output}" ]]; then
            refresh_failure_detail=": $(printf '%s\n' "${refresh_output}" | tail -1)"
        fi
        log_warning "dnf makecache --refresh exited ${refresh_exit_code}${refresh_failure_detail} - updating from the metadata dnf has cached"
    fi
    return 1
}

# describe_installed_updates EPOCH -> the update part of the completion line,
# from the packages whose rpm INSTALLTIME is at or after EPOCH, taken just
# before dnf-automatic started.  dnf-automatic exits 0 whether or not it
# installed anything.  Only wording depends on this; no decision does.
describe_installed_updates() {
    local installed_package_count
    installed_package_count=$(rpm -qa --qf '%{INSTALLTIME}\n' 2>/dev/null \
        | awk -v since="$1" '$1 >= since { count++ } END { print count + 0 }') || installed_package_count=""
    case "${installed_package_count}" in
        "") printf '%s' "Updates applied" ;;
        0)  printf '%s' "No updates installed" ;;
        *)  printf '%s' "Updates installed (packages: ${installed_package_count})" ;;
    esac
}

# exit_if_reboot_pending - exits 0 without updating while a scheduled reboot
# is waiting, queued, running or dispatched, and exits 1 when that cannot be
# read.  ConditionPathExists=! on REBOOT_PENDING_FILE normally keeps this unit
# from starting then; this also covers a reboot timer with no marker, such as
# one an earlier package version's watchdog scheduled during an upgrade.
exit_if_reboot_pending() {
    local scheduled_reboot_status
    scheduled_reboot_status=$(read_scheduled_reboot_status)
    case "${scheduled_reboot_status}" in
        none|failed)
            return 0
            ;;
        unknown)
            log_error "cannot read the state of ${SCHEDULED_REBOOT_UNIT} - not updating, a reboot may be pending"
            exit 1
            ;;
    esac
    log "a reboot is pending (${scheduled_reboot_status}) - not updating before it; cancel it with: ${CANCEL_REBOOT_COMMAND}"
    exit 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local dnf_automatic_exit_code=0 needs_reboot_exit_code=0 service_restart_exit_code=0 update_started_epoch

    trap cleanup EXIT

    START_TIMESTAMP=$(date +%s)
    START_UPTIME_SECONDS=$(uptime_seconds)
    log "Starting (pid=${SERVICE_PID})"
    exit_if_config_invalid
    check_conflicts
    exit_if_reboot_pending
    if ! wait_for_clock_sync; then
        send_wall_message "dnf-automatic-reboot: Updates NOT started - the clock is not confirmed synchronised."
        exit 1
    fi
    warn_on_unsigned_repositories

    warn_on_concurrent_dnf

    refresh_repository_metadata \
        || METADATA_REFRESH_FAILURE_SUMMARY=" (metadata refresh failed, cached metadata used)"

    record_dnf_log_position
    if ! publish_run_phase "updating"; then
        log_error "cannot publish ${STATE_FILE} - the watchdog could not supervise this run, not updating"
        exit 1
    fi

    log "Running dnf-automatic under the inhibitor lock (no deadline; the watchdog stops it only once dnf stalls)"
    update_started_epoch=$(date +%s)
    run_dnf_automatic_under_inhibitor || dnf_automatic_exit_code=$?

    if [[ "${dnf_automatic_exit_code}" -ne 0 ]]; then
        log_error "dnf-automatic, or the inhibitor lock taken before it, exited ${dnf_automatic_exit_code}"
        send_wall_message "dnf-automatic-reboot: Update FAILED (exit ${dnf_automatic_exit_code})." \
                          "Manual inspection required."
        exit 1
    fi

    log "dnf-automatic completed successfully"
    UPDATE_SUMMARY="$(describe_installed_updates "${update_started_epoch}")${METADATA_REFRESH_FAILURE_SUMMARY}"
    warn_on_unapplied_security_advisories
    # Still supervised when this fails: the file keeps phase=updating, which
    # the watchdog treats the more cautiously of the two.
    publish_run_phase "checking" || log_warning "cannot publish phase=checking to ${STATE_FILE}; it still reads phase=updating"

    # Decide whether a reboot is required.  Exit 0 = no reboot, 1 = reboot
    # needed; 2 = undecidable, and any other status is a helper failure.
    # Neither reboots, and both fail the run so the condition is surfaced
    # rather than silently ignored.
    run_reboot_check || needs_reboot_exit_code=$?

    # The state file stays until cleanup at exit: restart_stale_services can
    # block, and the watchdog supervises the run only while the file exists.
    case "${needs_reboot_exit_code}" in
        0)
            log "No flagged package needs a reboot"
            restart_stale_services reboot-allowed || service_restart_exit_code=$?
            if [[ "${#REBOOT_REQUIRING_SERVICE_NAMES[@]}" -gt 0 ]]; then
                log "Reboot needed: $(join_with ', ' "${REBOOT_REQUIRING_SERVICE_NAMES[@]}") map files an update replaced and cannot be restarted"
                request_reboot "${REBOOT_REQUEST_LOCK_TIMEOUT_SECONDS}" schedule_reboot || exit 1
                report_completion "${SCHEDULED_REBOOT_SUMMARY}" 0
            else
                report_completion "no reboot needed" "${service_restart_exit_code}"
            fi
            ;;
        1)
            request_reboot "${REBOOT_REQUEST_LOCK_TIMEOUT_SECONDS}" schedule_reboot || exit 1
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
# Logs one line naming the update, reboot and service-restart outcome of the
# run, with the command to inspect what is incomplete.  A non-zero FAILED logs
# it at error level, broadcasts it and exits 1, so OnFailure= reports it.
report_completion() {
    local reboot_outcome="$1" run_failed="$2" completion_summary inspected_unit_names=()
    completion_summary="${UPDATE_SUMMARY}; ${reboot_outcome}; ${SERVICE_RESTART_SUMMARY}"
    if [[ "${run_failed}" -eq 0 ]]; then
        log "${completion_summary}"
        return 0
    fi
    inspected_unit_names=("${FAILED_SERVICE_NAMES[@]}" "${PENDING_SERVICE_NAMES[@]}")
    if [[ "${#inspected_unit_names[@]}" -gt 0 ]]; then
        completion_summary+=". Check: systemctl status $(join_with ' ' "${inspected_unit_names[@]}")"
    else
        completion_summary+=". Check: journalctl -u dnf-automatic-reboot.service -e"
    fi
    log_error "${completion_summary}"
    send_wall_message "dnf-automatic-reboot: ${completion_summary}"
    exit 1
}

# Sourcing defines the functions above without running the update.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
