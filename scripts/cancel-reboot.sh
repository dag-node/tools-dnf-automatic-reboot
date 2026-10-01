#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# cancel-reboot.sh
# ---------------------------------------------------------------------------
# Cancels a reboot that run.sh or the watchdog requested, and allows update
# runs again.
#
# Under the reboot request lock, stops dnf-automatic-reboot-scheduled-reboot
# .timer, then removes /run/dnf-automatic-reboot.reboot-pending.  It reports
# success only on positive evidence that the reboot will not happen:
#
#   - the timer was stopped before it fired, and the reboot service has no
#     queued job
#   - the reboot service ran and failed
#   - no reboot was scheduled, PID 1 is not stopping and logind is not
#     preparing a shutdown
#
# It exits 1 and changes nothing while a reboot request holds the lock, once
# the reboot service is queued, running or has succeeded, while the host is
# shutting down, and whenever systemd's state cannot be read.
#
# Exit: 0 = cancelled, or nothing was pending; 1 = not cancelled.
#
# Log: /var/log/dnf-automatic-reboot.log
# ---------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

export LC_ALL=C

# Path prefix, empty in production.  tests/run-tests.sh points it at a
# temporary tree so every path and helper binary below resolves inside it.
readonly TEST_ROOT="${DNF_AUTOMATIC_REBOOT_TEST_ROOT:-}"

readonly LOG_FILE="${TEST_ROOT}/var/log/dnf-automatic-reboot.log"
# shellcheck disable=SC2034  # read by reboot-request.sh
readonly SYSTEMCTL_BIN="${TEST_ROOT}/usr/bin/systemctl"
readonly SCRIPT_NAME=cancel-reboot

# REBOOT_PENDING_FILE, the request lock, and the systemd state readers.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/reboot-request.sh"

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

# refuse_cancellation REASON - logs why and exits 1; the marker stays.
refuse_cancellation() {
    log_error "$1 - reboot NOT cancelled; ${REBOOT_PENDING_FILE} kept"
    exit 1
}

main() {
    local scheduled_reboot_status shutdown_state
    # A request holds the lock from before it creates the marker until its
    # outcome is known; a marker seen without the lock may not have reached
    # systemd yet.
    acquire_reboot_request_lock 0 \
        || refuse_cancellation "a reboot request is in progress; retry in a minute"

    scheduled_reboot_status=$(read_scheduled_reboot_status)
    case "${scheduled_reboot_status}" in
        in_progress) refuse_cancellation "the reboot service is queued or running" ;;
        dispatched)  refuse_cancellation "systemd already accepted the reboot" ;;
        unknown)     refuse_cancellation "the state of ${SCHEDULED_REBOOT_UNIT} cannot be read" ;;
    esac
    if [[ ! -e "${REBOOT_PENDING_FILE}" && "${scheduled_reboot_status}" == "none" ]]; then
        log "no reboot is pending"
        exit 0
    fi

    if [[ "${scheduled_reboot_status}" == "waiting" ]]; then
        stop_unit "${SCHEDULED_REBOOT_UNIT}.timer" \
            || refuse_cancellation "cannot stop ${SCHEDULED_REBOOT_UNIT}.timer"
        # The timer may have queued the reboot service just before it stopped;
        # stopping a timer does not cancel a job it queued.
        scheduled_reboot_status=$(read_scheduled_reboot_status)
        case "${scheduled_reboot_status}" in
            none|failed) ;;
            *) refuse_cancellation "after stopping the timer, ${SCHEDULED_REBOOT_UNIT} is ${scheduled_reboot_status}" ;;
        esac
    fi
    if [[ "${scheduled_reboot_status}" == "failed" ]]; then
        log "the scheduled reboot had already failed: systemctl status ${SCHEDULED_REBOOT_UNIT}.service"
        reset_failed_units "${SCHEDULED_REBOOT_UNIT}.service"
    fi

    # An immediate reboot, or one logind accepted and delays for an inhibitor,
    # leaves no unit to inspect.
    shutdown_state=$(read_host_shutdown_state)
    case "${shutdown_state}" in
        yes)     refuse_cancellation "the host is already shutting down" ;;
        unknown) refuse_cancellation "whether the host is shutting down cannot be read" ;;
    esac

    rm -f "${REBOOT_PENDING_FILE}" \
        || refuse_cancellation "cannot remove ${REBOOT_PENDING_FILE}; no reboot is scheduled, but update runs stay blocked"
    log "reboot cancelled; update runs are allowed again"
    exit 0
}

# Sourcing defines the functions above without cancelling anything.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
