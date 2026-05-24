#!/bin/bash
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
#     timeout exceeded    watchdog_hard_timeout_min.  Kill the process
#                         tree and force reboot.  This is the stuck
#                         protection.
#
#  4. PID alive, soft   - Past watchdog_soft_timeout_min.  If dnf is no
#     timeout exceeded    longer active AND phase=checking, run an
#                         independent needs-reboot check and act on it.
#                         If dnf is still active, leave it to the hard
#                         timeout.
#
# Configuration: /etc/dnf/automatic-reboot.conf
# Log:           /var/log/dnf-automatic-reboot.log
# ---------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

readonly CONF=/etc/dnf/automatic-reboot.conf
readonly STATE_FILE=/run/dnf-automatic-reboot.state
readonly LOCK_FILE=/run/dnf-automatic-reboot.lock
readonly LOG=/var/log/dnf-automatic-reboot.log
readonly LIBDIR=/usr/local/lib/dnf-automatic-reboot
readonly SELF=watchdog

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    echo "$(date -Iseconds) ${SELF}: $*" | tee -a "${LOG}"
}

wall_msg() {
    local enabled
    enabled=$(grep -E "^\s*wall_messages\s*=" "${CONF}" 2>/dev/null \
              | tail -1 | sed 's/^[^=]*=\s*//' | tr -d ' ') || true
    [[ "${enabled:-yes}" == "no" ]] && return 0
    wall "$*" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------
conf_get() {
    local key="$1" default="$2" val
    val=$(grep -E "^\s*${key}\s*=" "${CONF}" 2>/dev/null \
          | tail -1 | sed 's/^[^=]*=\s*//' | sed 's/\s*#.*//') || true
    printf '%s' "${val:-${default}}"
}

SOFT_MIN=$(conf_get watchdog_soft_timeout_min 60)
HARD_MIN=$(conf_get watchdog_hard_timeout_min 180)
REBOOT_DELAY=$(conf_get reboot_delay_sec 60)

# ---------------------------------------------------------------------------
# Scenario 1: no state file
# ---------------------------------------------------------------------------
if [[ ! -f "${STATE_FILE}" ]]; then
    exit 0
fi

# ---------------------------------------------------------------------------
# Parse state file
# ---------------------------------------------------------------------------
phase=""
start=0
service_pid=0

phase=$(grep    '^phase=' "${STATE_FILE}" | cut -d= -f2) || true
start=$(grep    '^start=' "${STATE_FILE}" | cut -d= -f2) || true
service_pid=$(grep '^pid=' "${STATE_FILE}" | cut -d= -f2) || true

if [[ -z "${start}" || -z "${service_pid}" ]]; then
    log "Malformed state file - removing"
    rm -f "${STATE_FILE}" "${LOCK_FILE}"
    exit 0
fi

now=$(date +%s)
elapsed_min=$(( (now - start) / 60 ))

log "phase=${phase} elapsed=${elapsed_min}min pid=${service_pid}"

# ---------------------------------------------------------------------------
# Scenario 2: dead PID with state file present
# ---------------------------------------------------------------------------
if ! kill -0 "${service_pid}" 2>/dev/null; then
    log "WARNING: service PID ${service_pid} is dead but state file exists"
    log "Updates may be incomplete. NOT rebooting - manual inspection required."
    wall_msg "dnf-automatic-reboot: WARNING - update process (PID ${service_pid})" \
             "died unexpectedly in phase=${phase}." \
             "Manual inspection required before rebooting."
    rm -f "${STATE_FILE}" "${LOCK_FILE}"
    exit 0
fi

# ---------------------------------------------------------------------------
# Scenario 3: hard timeout - PID still alive after HARD_MIN
# ---------------------------------------------------------------------------
if [[ "${elapsed_min}" -ge "${HARD_MIN}" ]]; then
    log "HARD TIMEOUT ${HARD_MIN}min exceeded - PID ${service_pid} still alive - force rebooting"
    wall_msg "dnf-automatic-reboot: HARD TIMEOUT ${HARD_MIN}min exceeded." \
             "Killing stuck process and force rebooting now."
    # Kill children first, then the script itself, to release dnf lock files
    pkill -KILL -P "${service_pid}" 2>/dev/null || true
    kill  -KILL    "${service_pid}" 2>/dev/null || true
    sleep 2
    rm -f "${STATE_FILE}" "${LOCK_FILE}"
    /usr/bin/systemctl reboot --force
    exit 0
fi

# ---------------------------------------------------------------------------
# Scenario 4: soft timeout - PID alive, past SOFT_MIN
# ---------------------------------------------------------------------------
if [[ "${elapsed_min}" -ge "${SOFT_MIN}" ]]; then

    # Is dnf still doing anything?
    dnf_active=0
    pgrep -x dnf-automatic > /dev/null 2>&1 && dnf_active=1
    pgrep -x dnf           > /dev/null 2>&1 && dnf_active=1
    # Active network connection owned by any dnf process
    ss -tp 2>/dev/null | grep -qE '\bdnf\b'  && dnf_active=1

    if [[ "${dnf_active}" -eq 1 ]]; then
        log "Soft timeout reached but dnf still active - waiting for hard timeout"
        exit 0
    fi

    log "Soft timeout reached and dnf idle (phase=${phase})"

    if [[ "${phase}" == "checking" ]]; then
        # needs-reboot.sh appears to be hung - run independently
        log "Phase=checking with idle dnf - running independent reboot check"
        reboot_needed=0
        "${LIBDIR}/needs-reboot.sh" || reboot_needed=$?

        # Kill the stuck checking phase so it does not block inhibitor release
        kill "${service_pid}" 2>/dev/null || true

        if [[ "${reboot_needed}" -eq 1 ]]; then
            log "Watchdog scheduling reboot in ${REBOOT_DELAY}s"
            wall_msg "dnf-automatic-reboot: Watchdog detected stuck check." \
                     "Scheduling reboot in ${REBOOT_DELAY} seconds."
            /usr/bin/systemd-run \
                --on-active="${REBOOT_DELAY}" \
                --timer-property=AccuracySec=1s \
                --description="dnf-automatic-reboot watchdog reboot" \
                /usr/bin/systemctl reboot
        else
            log "Watchdog: no reboot needed - killing stuck service"
        fi

    elif [[ "${phase}" == "failed" ]]; then
        log "Phase=failed at soft timeout - leaving for operator; hard timeout will force reboot"

    else
        # phase=updating but dnf is idle: dnf finished but script is hung
        # between dnf_automatic and needs-reboot.  Leave for hard timeout;
        # we do not know if updates completed cleanly.
        log "Phase=${phase} with idle dnf at soft timeout - leaving for hard timeout"
    fi
fi

# Not yet at soft timeout - nothing to do
exit 0
