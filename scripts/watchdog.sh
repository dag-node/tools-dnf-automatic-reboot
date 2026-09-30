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
# alone: dnf-automatic runs as a grandchild behind timeout(1), so signalling
# direct children leaves the rpm transaction running.
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
    wall_messages_enabled=$(grep -E "^\s*wall_messages\s*=" "${CONFIG_FILE}" 2>/dev/null \
                            | tail -1 | sed 's/^[^=]*=\s*//' | tr -d ' ') || true
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

# ---------------------------------------------------------------------------
# Kill the entire service cgroup.
#
# systemd owns the cgroup, so `systemctl kill --kill-whom=all` reaches
# dnf-automatic, the timeout(1) wrapper and the inhibitor helper together.
# Signalling only the recorded PID (or only its direct children) leaves the
# rpm transaction alive while the caller proceeds to reboot.
# ---------------------------------------------------------------------------
kill_service_cgroup() {
    local recorded_pid="$1"
    "${SYSTEMCTL_BIN}" kill --kill-whom=all --signal=SIGKILL "${MAIN_SERVICE_UNIT}" 2>/dev/null || true
    sleep 2
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
# Schedule a delayed reboot through a transient systemd timer.
# ---------------------------------------------------------------------------
schedule_reboot() {
    local systemd_run_exit_code=0
    log "Watchdog scheduling reboot in ${REBOOT_DELAY_SEC}s"
    wall_msg "dnf-automatic-reboot: Watchdog detected stuck check." \
             "Scheduling reboot in ${REBOOT_DELAY_SEC} seconds."
    "${SYSTEMD_RUN_BIN}" \
        --on-active="${REBOOT_DELAY_SEC}" \
        --timer-property=AccuracySec=1s \
        --description="dnf-automatic-reboot watchdog reboot" \
        "${SYSTEMCTL_BIN}" reboot || systemd_run_exit_code=$?
    if [[ "${systemd_run_exit_code}" -eq 0 ]]; then
        log "Reboot dispatch confirmed: systemd-run accepted the transient timer"
        return 0
    fi
    log_err "Reboot dispatch FAILED: systemd-run exited ${systemd_run_exit_code} - system will NOT reboot"
    wall_msg "dnf-automatic-reboot: ERROR - watchdog failed to schedule reboot (systemd-run exited ${systemd_run_exit_code})." \
             "Manual reboot required."
    return 1
}

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
if ! kill -0 "${service_pid}" 2>/dev/null; then
    log_warn "service PID ${service_pid} is dead but state file exists - updates may be incomplete, NOT rebooting"
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
    kill_service_cgroup "${service_pid}"
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
        "${LIBRARY_DIRECTORY}/needs-reboot.sh" || needs_reboot_exit_code=$?

        # Kill the stuck run so it cannot hold the inhibitor lock past the reboot
        kill_service_cgroup "${service_pid}"
        rm -f "${STATE_FILE}" "${LOCK_FILE}"

        case "${needs_reboot_exit_code}" in
            1)
                schedule_reboot || true
                ;;
            2)
                log_err "Watchdog: reboot state could not be established - killed the stuck run, not rebooting"
                wall_msg "dnf-automatic-reboot: Watchdog killed a stuck check but could not" \
                         "determine whether a reboot is needed. Manual inspection required."
                ;;
            *)
                log "Watchdog: no reboot needed - stuck run killed"
                ;;
        esac

    elif [[ "${run_phase}" == "failed" ]]; then
        log "Phase=failed at soft timeout - leaving for operator; hard timeout will kill the run"

    else
        # phase=updating but dnf is idle: dnf finished but the script is hung
        # between dnf-automatic and needs-reboot.  Leave for hard timeout;
        # we do not know if updates completed cleanly.
        log "Phase=${run_phase} with idle dnf at soft timeout - leaving for hard timeout"
    fi
fi

# Not yet at soft timeout - nothing to do
exit 0
