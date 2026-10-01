#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# cancel-reboot.sh
# ---------------------------------------------------------------------------
# Cancels a reboot that run.sh or the watchdog requested, and allows update
# runs again.
#
# Holding the reboot request lock, it removes
# /run/dnf-automatic-reboot.reboot-pending and stops
# dnf-automatic-reboot-scheduled-reboot.timer.  Every reboot this package
# requests runs reboot-if-pending.sh, which reboots only while that file
# exists and only under the same lock, so once the file is gone a timer that
# still fires, or a request systemd processes late, does not reboot the host.
#
# It exits 1 and changes nothing while a reboot request or the reboot command
# holds the lock, once reboot-if-pending.sh has called systemctl reboot
# (/run/dnf-automatic-reboot.reboot-dispatched exists), while the host is
# shutting down or its shutdown state cannot be read, and when the scheduled
# reboot's state cannot be read.
#
# Exit: 0 = cancelled, or nothing was pending; 1 = not cancelled.
#
# Log: /var/log/dnf-automatic-reboot.log
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
    # outcome is known, and reboot-if-pending.sh from its marker check until
    # systemctl reboot returns.
    acquire_reboot_request_lock 0 \
        || refuse_cancellation "a reboot request or the reboot command is in progress; retry in a minute"

    if [[ -e "${REBOOT_DISPATCHED_FILE}" ]]; then
        refuse_cancellation "the reboot command already ran in this boot"
    fi
    scheduled_reboot_status=$(read_scheduled_reboot_status)
    if [[ "${scheduled_reboot_status}" == "unknown" ]]; then
        refuse_cancellation "the state of ${SCHEDULED_REBOOT_UNIT} cannot be read"
    fi
    if [[ ! -e "${REBOOT_PENDING_FILE}" && "${scheduled_reboot_status}" == "none" ]]; then
        log "no reboot is pending"
        exit 0
    fi
    # An immediate reboot from elsewhere, or one logind accepted and delays
    # for an inhibitor, leaves no unit of this package to inspect.
    shutdown_state=$(read_host_shutdown_state)
    case "${shutdown_state}" in
        yes)     refuse_cancellation "the host is already shutting down" ;;
        unknown) refuse_cancellation "whether the host is shutting down cannot be read" ;;
    esac

    # From here no reboot of this package can start: reboot-if-pending.sh
    # needs the lock this process holds, and finds no marker after it.
    rm -f "${REBOOT_PENDING_FILE}" \
        || refuse_cancellation "cannot remove ${REBOOT_PENDING_FILE}"
    case "${scheduled_reboot_status}" in
        waiting|in_progress)
            if ! stop_unit "${SCHEDULED_REBOOT_UNIT}.timer"; then
                log_warning "cannot stop ${SCHEDULED_REBOOT_UNIT}.timer; when it fires, reboot-if-pending.sh finds no pending reboot and does not reboot"
            fi
            ;;
        failed)
            log "the requested reboot had failed: systemctl status ${SCHEDULED_REBOOT_UNIT}.service"
            reset_failed_units "${SCHEDULED_REBOOT_UNIT}.service"
            ;;
    esac
    log "reboot cancelled; update runs are allowed again"
    exit 0
}

# Sourcing defines the functions above without cancelling anything.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
