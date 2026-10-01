#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# reboot-if-pending.sh
# ---------------------------------------------------------------------------
# The command of dnf-automatic-reboot-scheduled-reboot.service: reboots the
# host if, and only if, the reboot is still pending.
#
#   reboot-if-pending.sh FORCE_ALLOWED LOCK_WAIT_SECONDS
#
# Holding the reboot request lock, it reboots only while
# /run/dnf-automatic-reboot.reboot-pending exists, and writes
# /run/dnf-automatic-reboot.reboot-dispatched before it calls systemctl
# reboot.  cancel-reboot.sh holds the same lock, so a cancellation either
# completes before this runs, and the reboot does not happen, or sees the
# dispatched file and refuses.
#
# A failed orderly reboot is checked against the host's shutdown state before
# anything else: logind may have accepted it.  With FORCE_ALLOWED=yes, and
# only when the host is definitely not shutting down, it falls back to
# systemctl reboot --force, which remounts filesystems read-only under running
# processes and is used for a leaked inhibitor lock only.
#
# Exit: 0 = reboot submitted, or nothing pending; 1 = the reboot did not
# happen or its outcome is unknown (OnFailure= reports it).  The dispatched
# file is removed only when the reboot was refused and the host is not
# shutting down.
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
readonly SCRIPT_NAME=reboot-if-pending

# REBOOT_PENDING_FILE, REBOOT_DISPATCHED_FILE, the lock and the readers.
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

# reboot_after_refusal_check FORCE_ALLOWED -> 0 when the reboot was submitted
# or the host is shutting down; 1 when it was refused (dispatched file
# removed) or the outcome is unknown (dispatched file kept).
reboot_after_refusal_check() {
    local force_allowed="$1" shutdown_state
    shutdown_state=$(read_host_shutdown_state)
    case "${shutdown_state}" in
        yes)
            log_warning "systemctl reboot failed, but the host is shutting down"
            return 0
            ;;
        unknown)
            log_error "systemctl reboot failed and the shutdown state cannot be read - the outcome is unknown; reboot the host"
            return 1
            ;;
    esac
    if [[ "${force_allowed}" == "yes" ]]; then
        log_warning "Orderly reboot refused - falling back to systemctl reboot --force"
        if reboot_host --force; then
            log "Forced reboot requested"
            return 0
        fi
        if [[ "$(read_host_shutdown_state)" != "no" ]]; then
            log_error "systemctl reboot --force failed and the host may be shutting down - the outcome is unknown; reboot the host"
            return 1
        fi
    fi
    rm -f "${REBOOT_DISPATCHED_FILE}"
    log_error "the reboot was refused and the host is not shutting down - update runs stay held; reboot the host, or allow updates again with: ${CANCEL_REBOOT_COMMAND}"
    return 1
}

main() {
    local force_allowed="${1:-no}" lock_wait_seconds="${2:-60}"
    [[ "${lock_wait_seconds}" =~ ^[0-9]+$ ]] || lock_wait_seconds=60
    if ! acquire_reboot_request_lock "${lock_wait_seconds}"; then
        log_error "${REBOOT_REQUEST_LOCK_FILE} not acquired within ${lock_wait_seconds}s - not rebooting; update runs stay held"
        exit 1
    fi
    if [[ ! -e "${REBOOT_PENDING_FILE}" ]]; then
        log "the reboot was cancelled - not rebooting"
        exit 0
    fi
    if ! : > "${REBOOT_DISPATCHED_FILE}" 2>/dev/null; then
        log_error "cannot create ${REBOOT_DISPATCHED_FILE} - not rebooting; update runs stay held"
        exit 1
    fi
    if reboot_host; then
        log "Orderly reboot requested"
        exit 0
    fi
    reboot_after_refusal_check "${force_allowed}" || exit 1
    exit 0
}

# Sourcing defines the functions above without rebooting.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
