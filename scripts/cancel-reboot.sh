#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# cancel-reboot.sh
# ---------------------------------------------------------------------------
# Cancels a reboot that run.sh or the watchdog requested, and allows update
# runs again.
#
# Stops dnf-automatic-reboot-scheduled-reboot.timer, then removes
# /run/dnf-automatic-reboot.reboot-pending.  It reports success only when the
# reboot is known not to happen:
#
#   - the timer was stopped before it started the reboot command
#   - the reboot command ran and failed
#   - no reboot was scheduled and the host is not shutting down: a request cut
#     short before its outcome was known, or a reboot systemd did not carry out
#
# Once the reboot command is running, or the host is shutting down, the
# marker stays and the helper exits 1.
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

readonly REBOOT_PENDING_FILE="${TEST_ROOT}/run/dnf-automatic-reboot.reboot-pending"
readonly LOG_FILE="${TEST_ROOT}/var/log/dnf-automatic-reboot.log"
readonly SYSTEMCTL_BIN="${TEST_ROOT}/usr/bin/systemctl"
readonly SCHEDULED_REBOOT_UNIT=dnf-automatic-reboot-scheduled-reboot
readonly SCRIPT_NAME=cancel-reboot

log() {
    printf '<6>%s: %s\n' "${SCRIPT_NAME}" "$*"
    printf '%s %s: %s\n' "$(date -Iseconds)" "${SCRIPT_NAME}" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}
log_err() {
    printf '<3>%s: %s\n' "${SCRIPT_NAME}" "$*"
    printf '%s %s: ERROR: %s\n' "$(date -Iseconds)" "${SCRIPT_NAME}" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}

# unit_property UNIT PROPERTY -> the property's value, empty when systemctl
# does not answer.  An unknown unit reports LoadState=not-found and
# ActiveState=inactive.
unit_property() {
    "${SYSTEMCTL_BIN}" show --property="$2" --value "$1" 2>/dev/null || true
}

# system_state -> systemctl is-system-running's output; "stopping" once a
# shutdown or reboot has begun.  The command exits non-zero for every state
# but running, so only the output is read.
system_state() {
    "${SYSTEMCTL_BIN}" is-system-running 2>/dev/null || true
}

# stop_scheduled_reboot_timer -> systemctl stop's exit code.
stop_scheduled_reboot_timer() {
    "${SYSTEMCTL_BIN}" stop "${SCHEDULED_REBOOT_UNIT}.timer" 2>/dev/null
}

main() {
    local timer_active_state reboot_service_state
    timer_active_state=$(unit_property "${SCHEDULED_REBOOT_UNIT}.timer" ActiveState)
    if [[ ! -e "${REBOOT_PENDING_FILE}" && "${timer_active_state}" != "active" ]]; then
        log "no reboot is pending"
        exit 0
    fi

    # Once stopped, the timer cannot start the reboot, so the state of the
    # reboot service read after this is final.
    if [[ "$(unit_property "${SCHEDULED_REBOOT_UNIT}.timer" LoadState)" == "loaded" ]] \
       && ! stop_scheduled_reboot_timer; then
        log_err "cannot stop ${SCHEDULED_REBOOT_UNIT}.timer - reboot NOT cancelled"
        exit 1
    fi

    reboot_service_state=$(unit_property "${SCHEDULED_REBOOT_UNIT}.service" ActiveState)
    case "${reboot_service_state}" in
        activating|active|deactivating|reloading)
            log_err "the reboot command is already running - reboot NOT cancelled"
            exit 1
            ;;
        failed)
            log "the scheduled reboot had already failed: systemctl status ${SCHEDULED_REBOOT_UNIT}.service"
            "${SYSTEMCTL_BIN}" reset-failed "${SCHEDULED_REBOOT_UNIT}.service" 2>/dev/null || true
            ;;
    esac

    if [[ "$(system_state)" == "stopping" ]]; then
        log_err "the host is already shutting down - reboot NOT cancelled"
        exit 1
    fi

    if ! rm -f "${REBOOT_PENDING_FILE}"; then
        log_err "cannot remove ${REBOOT_PENDING_FILE} - no reboot is scheduled, but update runs stay blocked"
        exit 1
    fi
    log "reboot cancelled; update runs are allowed again"
    exit 0
}

# Sourcing defines the functions above without cancelling anything.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
