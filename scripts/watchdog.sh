#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# watchdog.sh
# ---------------------------------------------------------------------------
# Independent watchdog for dnf-automatic-reboot.
# Runs every 5 minutes via dnf-automatic-watchdog.timer, completely
# independent of the main run.sh service unit.
#
# Handles four scenarios:
#
#  1. No state file     - Nothing is running; exit immediately.
#
#  2. Dead PID          - run.sh crashed uncleanly.  State is unknown.
#                         Clean up lock files, emit a wall warning.
#                         Do NOT reboot: updates may be partial.
#
#  3. PID alive, hard   - run.sh has been running longer than
#     timeout exceeded    watchdog_hard_timeout_min.  Kill the service
#                         cgroup.  Reboot only when the recorded phase
#                         proves dnf already returned cleanly, or when
#                         force_reboot_on_hard_timeout says otherwise.
#
#  4. PID alive, soft   - Past watchdog_soft_timeout_min.  If dnf is no
#     timeout exceeded    longer active AND phase=checking, run an
#                         independent needs-reboot check and act on it.
#                         If dnf is still active, leave it to the hard
#                         timeout.
#
# Killing always targets the whole service cgroup, never the run.sh PID
# alone: dnf-automatic runs behind systemd-inhibit and timeout(1), so
# signalling direct children leaves the rpm transaction running.
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
readonly STATE_FILE="${TEST_ROOT}/run/dnf-automatic-reboot.state"
readonly LOCK_FILE="${TEST_ROOT}/run/dnf-automatic-reboot.lock"
readonly UPTIME_FILE="${TEST_ROOT}/proc/uptime"
readonly LOG_FILE="${TEST_ROOT}/var/log/dnf-automatic-reboot.log"
readonly LIBRARY_DIRECTORY="${TEST_ROOT}/usr/libexec/dnf-automatic-reboot"
readonly SYSTEMD_RUN_BIN="${TEST_ROOT}/usr/bin/systemd-run"
readonly SYSTEMCTL_BIN="${TEST_ROOT}/usr/bin/systemctl"
readonly MAIN_SERVICE_UNIT=dnf-automatic-reboot.service
# Transient unit that carries a scheduled reboot; run.sh uses the same.
readonly SCHEDULED_REBOOT_UNIT=dnf-automatic-reboot-scheduled-reboot
readonly SCRIPT_NAME=watchdog

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

SOFT_TIMEOUT_MIN=$(conf_get_int watchdog_soft_timeout_min 60)
HARD_TIMEOUT_MIN=$(conf_get_int watchdog_hard_timeout_min 180)
REBOOT_DELAY_SEC=$(conf_get_int reboot_delay_sec 60)
FORCE_REBOOT_ON_HARD_TIMEOUT=$(conf_get force_reboot_on_hard_timeout no)
NEEDS_RESTARTING_TIMEOUT_SEC=$(conf_get_int needs_restarting_timeout_sec 120)

# ---------------------------------------------------------------------------
# Independent reboot check, bounded.
#
# needs-reboot.sh runs needs-restarting at most twice, each run bounded by
# needs_restarting_timeout_sec; a third share of the budget covers its rpm and
# build-id queries.  A check that hangs anyway is killed at the bound and
# reported as undecidable, so the watchdog exits and a later cycle still
# reaches the hard timeout.  A timeout of 0, which leaves needs-restarting
# unbounded, gives the check the default budget.
#
# Returns needs-reboot.sh's exit code, or 2 when it did not finish in time.
# ---------------------------------------------------------------------------
run_independent_reboot_check() {
    local check_timeout_seconds=$(( 3 * NEEDS_RESTARTING_TIMEOUT_SEC )) exit_code=0
    [[ "${check_timeout_seconds}" -gt 0 ]] || check_timeout_seconds=360
    timeout --kill-after=10s "${check_timeout_seconds}s" "${LIBRARY_DIRECTORY}/needs-reboot.sh" \
        || exit_code=$?
    # 124: timed out; 137: still running at the timeout and killed after it.
    if [[ "${exit_code}" -eq 124 || "${exit_code}" -eq 137 ]]; then
        log_err "independent reboot check did not finish within ${check_timeout_seconds}s - treating the reboot state as undecidable"
        return 2
    fi
    return "${exit_code}"
}

# ---------------------------------------------------------------------------
# Kill the entire service cgroup.
#
# systemd owns the cgroup, so `systemctl kill --kill-whom=all` reaches
# dnf-automatic, the timeout(1) wrapper and the inhibitor helper together.
# Signalling only the recorded PID (or only its direct children) leaves the
# rpm transaction alive while the caller proceeds to reboot.
# ---------------------------------------------------------------------------

# systemctl_kill_target_option SYSTEMD_VERSION -> the option that makes
# `systemctl kill` signal every process of the unit.  systemd 252 renamed
# `--kill-who` to `--kill-whom`: on the surveyed hosts systemd 239 (EL8)
# accepts only `--kill-who`, and 252 (EL9) accepts either.  A version that
# does not parse gets `--kill-who`, which 239 and 252 accept.
systemctl_kill_target_option() {
    local systemd_version="$1"
    if [[ "${systemd_version}" =~ ^[0-9]+$ && "${systemd_version}" -ge 252 ]]; then
        printf '%s' '--kill-whom=all'
    else
        printf '%s' '--kill-who=all'
    fi
}

# unit_main_pid -> the service unit's MainPID as systemctl reports it, empty
# when systemctl does not answer.
unit_main_pid() {
    "${SYSTEMCTL_BIN}" show --property=MainPID --value "${MAIN_SERVICE_UNIT}" 2>/dev/null || true
}

# recorded_pid_identity PID
# Returns: 0 = PID is alive and is the unit's MainPID: the run
#          1 = PID is dead, or MainPID is another process: not the run
#          2 = PID is alive but systemctl show does not print a numeric
#              MainPID: unknown
# run.sh is the unit's ExecStart, so its PID is MainPID while it runs; a live
# PID that differs was reused by an unrelated process after the run died.
recorded_pid_identity() {
    local recorded_pid="$1" main_pid
    kill -0 "${recorded_pid}" 2>/dev/null || return 1
    main_pid=$(unit_main_pid)
    [[ "${main_pid}" =~ ^[0-9]+$ ]] || return 2
    [[ "${main_pid}" == "${recorded_pid}" ]] || return 1
    return 0
}

# recorded_run_is_unchanged PHASE START_UPTIME PID
# Returns: 0 = the state file still describes this run and PID is still the
#              unit's MainPID
#          1 = the run ended, or another run replaced it
#          2 = PID is alive but its identity cannot be established
# The run can end, and another start, while the watchdog runs its own check;
# acting on the old decision would kill the new run, possibly mid-transaction.
recorded_run_is_unchanged() {
    local expected_phase="$1" expected_start_uptime="$2" expected_pid="$3"
    local current_phase current_start_uptime current_pid
    current_phase=$(grep '^phase=' "${STATE_FILE}" 2>/dev/null | cut -d= -f2) || return 1
    current_start_uptime=$(grep '^start_uptime=' "${STATE_FILE}" 2>/dev/null | cut -d= -f2) || return 1
    current_pid=$(grep '^pid=' "${STATE_FILE}" 2>/dev/null | cut -d= -f2) || return 1
    [[ "${current_phase}" == "${expected_phase}" \
       && "${current_start_uptime}" == "${expected_start_uptime}" \
       && "${current_pid}" == "${expected_pid}" ]] || return 1
    recorded_pid_identity "${expected_pid}"
}

# kill_service_cgroup PHASE START_UPTIME PID
# Kills the unit only after recorded_run_is_unchanged confirms it still runs
# the recorded run.  Otherwise it returns that function's 1 or 2 without
# signalling any process.  The unit is signalled a moment after the check; no systemctl
# option ties the kill to one invocation of the unit.
kill_service_cgroup() {
    local recorded_phase="$1" recorded_start_uptime="$2" recorded_pid="$3"
    local systemd_version kill_target_option run_check_result=0
    recorded_run_is_unchanged "${recorded_phase}" "${recorded_start_uptime}" "${recorded_pid}" \
        || run_check_result=$?
    if [[ "${run_check_result}" -eq 1 ]]; then
        log "the run in the state file ended or was replaced - killing nothing, recovery abandoned"
        return 1
    elif [[ "${run_check_result}" -ne 0 ]]; then
        log_err "the identity of PID ${recorded_pid} cannot be established - killing nothing, recovery abandoned"
        return 2
    fi
    systemd_version=$("${SYSTEMCTL_BIN}" --version 2>/dev/null \
                      | sed -n '1s/^systemd \([0-9]\+\).*/\1/p') || true
    kill_target_option=$(systemctl_kill_target_option "${systemd_version}")
    if ! "${SYSTEMCTL_BIN}" kill "${kill_target_option}" --signal=SIGKILL "${MAIN_SERVICE_UNIT}" 2>/dev/null; then
        log_err "systemctl kill ${kill_target_option} ${MAIN_SERVICE_UNIT} failed - processes of the run may survive"
    fi
    sleep 2
    # The PID was confirmed as the run before the cgroup kill, so a survivor
    # with that number is the run, not a reused PID.
    if kill -0 "${recorded_pid}" 2>/dev/null; then
        log_warn "PID ${recorded_pid} survived the cgroup kill - signalling it directly"
        kill -KILL "${recorded_pid}" 2>/dev/null || true
        sleep 1
    fi
    "${SYSTEMCTL_BIN}" reset-failed "${MAIN_SERVICE_UNIT}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Reboot now, preferring an orderly shutdown.
#
# --force skips unit shutdown and remounts filesystems read-only under running
# processes, which risks the rootfs on flash-backed hosts.  It is the fallback
# only, for when logind refuses the orderly path (a leaked inhibitor lock).
# ---------------------------------------------------------------------------
reboot_now() {
    if "${SYSTEMCTL_BIN}" reboot 2>/dev/null; then
        log "Orderly reboot requested"
        return 0
    fi
    log_warn "Orderly reboot refused - falling back to systemctl reboot --force"
    "${SYSTEMCTL_BIN}" reboot --force
}

# ---------------------------------------------------------------------------
# Schedule a delayed reboot through a transient systemd timer, named as in
# run.sh; an active timer of that name is a reboot already scheduled.
# ---------------------------------------------------------------------------
schedule_reboot() {
    local systemd_run_exit_code=0 reboot_time
    reboot_time=$(date -d "@$(( $(date +%s) + REBOOT_DELAY_SEC ))" '+%F %T %Z')
    SCHEDULED_REBOOT_SUMMARY="reboot scheduled for ${reboot_time}; cancel with: systemctl stop ${SCHEDULED_REBOOT_UNIT}.timer"
    if "${SYSTEMCTL_BIN}" is-active --quiet "${SCHEDULED_REBOOT_UNIT}.timer" 2>/dev/null; then
        SCHEDULED_REBOOT_SUMMARY="reboot already scheduled; cancel with: systemctl stop ${SCHEDULED_REBOOT_UNIT}.timer"
        log "${SCHEDULED_REBOOT_UNIT}.timer is already active - not scheduling a second reboot"
        return 0
    fi
    # A transient unit left failed by an earlier attempt in this boot keeps
    # its name taken until reset.
    "${SYSTEMCTL_BIN}" reset-failed "${SCHEDULED_REBOOT_UNIT}.service" "${SCHEDULED_REBOOT_UNIT}.timer" 2>/dev/null || true
    log "Watchdog scheduling reboot in ${REBOOT_DELAY_SEC}s"
    wall_msg "dnf-automatic-reboot: Watchdog detected stuck check. System will reboot at ${reboot_time}." \
             "Cancel with: systemctl stop ${SCHEDULED_REBOOT_UNIT}.timer"
    # A named unit an operator can find and stop; OnFailure= reports a reboot
    # that systemctl could not start, such as one blocked by an inhibitor.
    "${SYSTEMD_RUN_BIN}" \
        --unit="${SCHEDULED_REBOOT_UNIT}" \
        --on-active="${REBOOT_DELAY_SEC}" \
        --timer-property=AccuracySec=1s \
        --property="OnFailure=dnf-automatic-reboot-notify@${SCHEDULED_REBOOT_UNIT}.service.service" \
        --description="dnf-automatic-reboot watchdog reboot" \
        "${SYSTEMCTL_BIN}" reboot || systemd_run_exit_code=$?
    if [[ "${systemd_run_exit_code}" -eq 0 ]]; then
        log "Reboot dispatch confirmed: ${SCHEDULED_REBOOT_UNIT}.timer fires at ${reboot_time}; cancel with: systemctl stop ${SCHEDULED_REBOOT_UNIT}.timer"
        return 0
    fi
    log_err "Reboot dispatch FAILED: systemd-run exited ${systemd_run_exit_code} - system will NOT reboot"
    wall_msg "dnf-automatic-reboot: ERROR - watchdog failed to schedule reboot (systemd-run exited ${systemd_run_exit_code})." \
             "Manual reboot required."
    return 1
}

# Sourcing defines this file's functions without running the checks, so
# tests/run-tests.sh can exercise them directly.
main() {
    # ---------------------------------------------------------------------------
    # Scenario 1: no state file
    # ---------------------------------------------------------------------------
    if [[ ! -f "${STATE_FILE}" ]]; then
        exit 0
    fi

    # ---------------------------------------------------------------------------
    # Parse state file
    # ---------------------------------------------------------------------------
    run_phase=""
    start_uptime_seconds=""
    service_pid=0

    run_phase=$(grep            '^phase=' "${STATE_FILE}" | cut -d= -f2) || true
    start_uptime_seconds=$(grep '^start_uptime=' "${STATE_FILE}" | cut -d= -f2) || true
    service_pid=$(grep            '^pid=' "${STATE_FILE}" | cut -d= -f2) || true

    if [[ ! "${start_uptime_seconds}" =~ ^[0-9]+$ || ! "${service_pid}" =~ ^[0-9]+$ ]]; then
        log "Malformed state file - removing"
        rm -f "${STATE_FILE}" "${LOCK_FILE}"
        exit 0
    fi

    # Elapsed time is measured on CLOCK_BOOTTIME.  With no RTC, a run started
    # before chrony synchronises sees the wall clock step forward by however long
    # the host was off, which read as wall-clock time would trip the hard timeout
    # and kill an rpm transaction minutes after it began.  /run does not survive
    # a reboot, so a recorded uptime always belongs to the current boot.
    current_uptime_seconds=""
    read -r current_uptime_seconds _ < "${UPTIME_FILE}" 2>/dev/null || true
    current_uptime_seconds="${current_uptime_seconds%%.*}"
    if [[ ! "${current_uptime_seconds}" =~ ^[0-9]+$ ]]; then
        log_err "cannot read ${UPTIME_FILE} - run not supervised this cycle"
        exit 1
    fi
    elapsed_min=$(( (current_uptime_seconds - start_uptime_seconds) / 60 ))

    log "phase=${run_phase} elapsed=${elapsed_min}min pid=${service_pid}"

    # ---------------------------------------------------------------------------
    # Scenario 2: dead PID with state file present
    # ---------------------------------------------------------------------------
    recorded_pid_identity_result=0
    recorded_pid_identity "${service_pid}" || recorded_pid_identity_result=$?
    # Unknown identity blocks every action.  Before the soft timeout there is
    # no action to take, so it is only a warning there.
    if [[ "${recorded_pid_identity_result}" -eq 2 ]]; then
        if [[ "${elapsed_min}" -lt "${SOFT_TIMEOUT_MIN}" ]]; then
            log_warn "systemctl reports no MainPID for ${MAIN_SERVICE_UNIT} - PID ${service_pid} not verified this cycle"
            exit 0
        fi
        log_err "PID ${service_pid} is alive but systemctl reports no MainPID for ${MAIN_SERVICE_UNIT} - cannot tell whether it is the run, not acting this cycle"
        exit 1
    fi
    if [[ "${recorded_pid_identity_result}" -eq 1 ]]; then
        log_warn "service PID ${service_pid} is dead or not the unit's main process but state file exists - updates may be incomplete, NOT rebooting"
        wall_msg "dnf-automatic-reboot: WARNING - update process (PID ${service_pid})" \
                 "died unexpectedly in phase=${run_phase}." \
                 "Manual inspection required before rebooting."
        rm -f "${STATE_FILE}" "${LOCK_FILE}"
        exit 0
    fi

    # ---------------------------------------------------------------------------
    # Scenario 3: hard timeout - PID still alive after HARD_TIMEOUT_MIN
    #
    # phase=checking means dnf-automatic already returned cleanly, so the rpm
    # transaction is complete and rebooting is safe.  phase=updating means it did
    # not, so an rpm transaction may be half-applied - the same uncertainty for
    # which scenario 2 already refuses to reboot.  Rebooting there is opt-in.
    # ---------------------------------------------------------------------------
    if [[ "${elapsed_min}" -ge "${HARD_TIMEOUT_MIN}" ]]; then
        log_err "hard timeout ${HARD_TIMEOUT_MIN}min exceeded - PID ${service_pid} still alive in phase=${run_phase}"
        kill_result=0
        kill_service_cgroup "${run_phase}" "${start_uptime_seconds}" "${service_pid}" || kill_result=$?
        [[ "${kill_result}" -eq 1 ]] && exit 0
        [[ "${kill_result}" -eq 0 ]] || exit 1
        rm -f "${STATE_FILE}" "${LOCK_FILE}"

        if [[ "${run_phase}" == "checking" || "${FORCE_REBOOT_ON_HARD_TIMEOUT}" == "yes" ]]; then
            wall_msg "dnf-automatic-reboot: HARD TIMEOUT ${HARD_TIMEOUT_MIN}min exceeded." \
                     "Killed the stuck run and rebooting now."
            reboot_now
        else
            log_err "phase=${run_phase} at hard timeout - an rpm transaction may be incomplete, NOT rebooting; set force_reboot_on_hard_timeout=yes to override"
            wall_msg "dnf-automatic-reboot: HARD TIMEOUT ${HARD_TIMEOUT_MIN}min exceeded in phase=${run_phase}." \
                     "Killed the stuck run. Updates may be incomplete - inspect with 'dnf history' before rebooting."
        fi
        exit 0
    fi

    # ---------------------------------------------------------------------------
    # Scenario 4: soft timeout - PID alive, past SOFT_TIMEOUT_MIN
    # ---------------------------------------------------------------------------
    if [[ "${elapsed_min}" -ge "${SOFT_TIMEOUT_MIN}" ]]; then

        # Is dnf still doing anything?
        dnf_active=0
        pgrep -x dnf           > /dev/null 2>&1 && dnf_active=1
        pgrep -x dnf-3         > /dev/null 2>&1 && dnf_active=1
        pgrep -x dnf-automatic > /dev/null 2>&1 && dnf_active=1
        # Active network connection owned by any dnf process
        ss -tp 2>/dev/null | grep -qE '\bdnf\b'  && dnf_active=1

        if [[ "${dnf_active}" -eq 1 ]]; then
            log "Soft timeout reached but dnf still active - waiting for hard timeout"
            exit 0
        fi

        log "Soft timeout reached and dnf idle (phase=${run_phase})"

        if [[ "${run_phase}" == "checking" ]]; then
            # needs-reboot.sh appears to be hung - run independently
            log "Phase=checking with idle dnf - running independent reboot check"
            needs_reboot_exit_code=0
            run_independent_reboot_check || needs_reboot_exit_code=$?

            # Kill the stuck run so it cannot hold the inhibitor lock past the
            # reboot.  The check took time: when the run it was made for has
            # ended, or another run has started, its decision is not acted on.
            kill_result=0
            kill_service_cgroup "${run_phase}" "${start_uptime_seconds}" "${service_pid}" || kill_result=$?
            [[ "${kill_result}" -eq 1 ]] && exit 0
            [[ "${kill_result}" -eq 0 ]] || exit 1
            rm -f "${STATE_FILE}" "${LOCK_FILE}"

            case "${needs_reboot_exit_code}" in
                0)
                    log "Watchdog: no reboot needed - stuck run killed"
                    ;;
                1)
                    schedule_reboot || exit 1
                    log "Watchdog: stuck run killed; ${SCHEDULED_REBOOT_SUMMARY}"
                    ;;
                *)
                    log_err "Watchdog: needs-reboot.sh exited ${needs_reboot_exit_code}: reboot state could not be established - killed the stuck run, not rebooting"
                    wall_msg "dnf-automatic-reboot: Watchdog killed a stuck check but could not" \
                             "determine whether a reboot is needed. Manual inspection required."
                    exit 1
                    ;;
            esac

        else
            # phase=updating but dnf is idle: dnf finished but the script is hung
            # between dnf-automatic and needs-reboot.  Leave for hard timeout;
            # we do not know if updates completed cleanly.
            log "Phase=${run_phase} with idle dnf at soft timeout - leaving for hard timeout"
        fi
    fi

    # Not yet at soft timeout - nothing to do
    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
