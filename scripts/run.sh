#!/bin/bash
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
#      a reboot is required, filtering UEK and systemd false positives.
#   6. Release the inhibitor lock.
#   7. Schedule a reboot via systemd-run if needed.
#
# State file /run/dnf-automatic-reboot.state
#   phase=  updating | checking | failed
#   start=  unix timestamp
#   pid=    PID of this script
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
readonly SELF=run
INHIBIT_PID=0
SELF_PID=$$

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    printf '<6>%s: %s\n' "${SELF}" "$*"
    printf '%s %s: %s\n' "$(date -Iseconds)" "${SELF}" "$*" >> "${LOG}" 2>/dev/null || true
}
log_warn() {
    printf '<4>%s: %s\n' "${SELF}" "$*"
    printf '%s %s: WARNING: %s\n' "$(date -Iseconds)" "${SELF}" "$*" >> "${LOG}" 2>/dev/null || true
}
log_err() {
    printf '<3>%s: %s\n' "${SELF}" "$*"
    printf '%s %s: ERROR: %s\n' "$(date -Iseconds)" "${SELF}" "$*" >> "${LOG}" 2>/dev/null || true
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

# ---------------------------------------------------------------------------
# Pre-flight: abort if conflicting services would cause double-reboots
# ---------------------------------------------------------------------------
check_conflicts() {
    local fail=0

    for timer in dnf-automatic.timer dnf-automatic-install.timer; do
        if systemctl is-enabled --quiet "${timer}" 2>/dev/null || \
           systemctl is-active  --quiet "${timer}" 2>/dev/null; then
            log_err "${timer} is enabled/active - conflicts with this service; disable with: systemctl disable --now ${timer}"
            fail=1
        fi
    done

    local aconf=/etc/dnf/automatic.conf
    if [[ -f "${aconf}" ]]; then
        local reboot_val
        reboot_val=$(grep -E '^\s*reboot\s*=' "${aconf}" 2>/dev/null \
                     | tail -1 | sed 's/^[^=]*=\s*//' | sed 's/\s*#.*//' \
                     | tr -d '[:space:]') || true
        if [[ -n "${reboot_val}" && "${reboot_val}" != "never" ]]; then
            log_err "/etc/dnf/automatic.conf has reboot = ${reboot_val}; set 'reboot = never' to avoid double-reboot conflicts"
            fail=1
        fi
    fi

    if [[ "${fail}" -ne 0 ]]; then
        log_err "Aborting: resolve the conflicts above, then restart the service"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Read config
# ---------------------------------------------------------------------------
REBOOT_DELAY=$(conf_get reboot_delay_sec 60)
ALWAYS_REBOOT=$(conf_get always_reboot no)
DNF_TIMEOUT=$(conf_get dnf_timeout_min 60)
KILL_GRACE=$(conf_get kill_grace_sec 30)

# ---------------------------------------------------------------------------
# Cleanup handler - always runs on exit
# Releases inhibitor lock and removes state/lock files.
# ---------------------------------------------------------------------------
cleanup() {
    local rc=$?
    if [[ "${INHIBIT_PID}" -gt 0 ]]; then
        kill "${INHIBIT_PID}" 2>/dev/null || true
        wait "${INHIBIT_PID}" 2>/dev/null || true
    fi
    rm -f "${STATE_FILE}" "${LOCK_FILE}"
    log "Exiting rc=${rc}"
    exit "${rc}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# State file writer
# ---------------------------------------------------------------------------
write_state() {
    local phase="$1"
    printf 'phase=%s\nstart=%s\npid=%s\n' "${phase}" "${START_TS}" "${SELF_PID}" \
        > "${STATE_FILE}"
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
START_TS=$(date +%s)
log "Starting (pid=${SELF_PID})"
check_conflicts

# ---------------------------------------------------------------------------
# Detect concurrent dnf - warn but do not abort; dnf serialises via its own
# lock so this is safe.  The warning gives admins a chance to hold off.
# ---------------------------------------------------------------------------
if pgrep -x dnf > /dev/null 2>&1 || pgrep -x dnf-automatic > /dev/null 2>&1; then
    log_warn "dnf process already running - will contend on dnf lock"
    wall_msg "dnf-automatic-reboot: WARNING - manual dnf detected. Automatic update" \
             "will wait for the dnf lock. Do not reboot manually until this completes."
fi

write_state "updating"

# ---------------------------------------------------------------------------
# Acquire systemd inhibitor lock via background sleep.
# The lock prevents systemctl reboot/poweroff until we release it.
# An admin can still force-reboot with: systemctl reboot --force
# ---------------------------------------------------------------------------
systemd-inhibit \
    --what="shutdown:sleep" \
    --who="dnf-automatic-reboot" \
    --why="dnf-automatic update in progress - do not reboot" \
    --mode="block" \
    /usr/bin/sleep infinity &
INHIBIT_PID=$!
log "Inhibitor lock acquired PID=${INHIBIT_PID}"
wall_msg "dnf-automatic-reboot: Starting automatic updates. Reboot is inhibited until complete."

# ---------------------------------------------------------------------------
# Run dnf-automatic under a hard wall-clock timeout.
# timeout sends SIGTERM at DNF_TIMEOUT minutes, then SIGKILL after KILL_GRACE
# seconds.  Exit code 124 = timed out.
# ---------------------------------------------------------------------------
log "Running dnf-automatic (timeout=${DNF_TIMEOUT}m kill_grace=${KILL_GRACE}s)"
dnf_exit=0
timeout --kill-after="${KILL_GRACE}s" "${DNF_TIMEOUT}m" /usr/bin/dnf-automatic \
    || dnf_exit=$?

if [[ "${dnf_exit}" -ne 0 ]]; then
    log_err "dnf-automatic exited ${dnf_exit}"
    write_state "failed"
    wall_msg "dnf-automatic-reboot: Update FAILED (exit ${dnf_exit})." \
             "Manual inspection required."
    exit 1
fi

log "dnf-automatic completed successfully"
write_state "checking"

# ---------------------------------------------------------------------------
# Decide whether a reboot is required.
# needs-reboot.sh filters UEK and systemd false positives.
# Exit 0 = no reboot, 1 = reboot needed, 2 = tool error (treated as no reboot).
# ---------------------------------------------------------------------------
reboot_needed=0
"${LIBDIR}/needs-reboot.sh" || reboot_needed=$?

if [[ "${ALWAYS_REBOOT}" == "yes" && "${reboot_needed}" -eq 0 ]]; then
    log "always_reboot=yes in config - scheduling reboot regardless"
    reboot_needed=1
fi

# ---------------------------------------------------------------------------
# Release inhibitor lock BEFORE scheduling the reboot.
# A block-mode inhibitor would prevent our own reboot call if still held.
# ---------------------------------------------------------------------------
kill "${INHIBIT_PID}" 2>/dev/null || true
wait "${INHIBIT_PID}" 2>/dev/null || true
INHIBIT_PID=0

rm -f "${STATE_FILE}" "${LOCK_FILE}"
trap - EXIT   # prevent double-cleanup after this point

# ---------------------------------------------------------------------------
# Schedule reboot if needed
# ---------------------------------------------------------------------------
if [[ "${reboot_needed}" -eq 1 ]]; then
    log "Scheduling reboot in ${REBOOT_DELAY}s"
    wall_msg "dnf-automatic-reboot: Updates complete. System will reboot in ${REBOOT_DELAY} seconds."
    schedule_rc=0
    /usr/bin/systemd-run \
        --on-active="${REBOOT_DELAY}" \
        --timer-property=AccuracySec=1s \
        --description="dnf-automatic-reboot scheduled reboot" \
        /usr/bin/systemctl reboot || schedule_rc=$?
    if [[ "${schedule_rc}" -eq 0 ]]; then
        log "Reboot dispatch confirmed: systemd-run accepted the transient timer"
    else
        log_err "Reboot dispatch FAILED: systemd-run exited ${schedule_rc} - system will NOT reboot"
        wall_msg "dnf-automatic-reboot: ERROR - failed to schedule reboot (systemd-run exited ${schedule_rc})." \
                 "Manual reboot required."
        exit 1
    fi
else
    log "No reboot required"
    wall_msg "dnf-automatic-reboot: Updates complete. No reboot required."
fi
