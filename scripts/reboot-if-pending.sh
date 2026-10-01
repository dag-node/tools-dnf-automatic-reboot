#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# reboot-if-pending.sh
# ---------------------------------------------------------------------------
# The command of dnf-automatic-reboot-scheduled-reboot.service: reboots the
# host if, and only if, the reboot is still pending.
#
#   reboot-if-pending.sh LOCK_WAIT_SECONDS INHIBITED_WAIT_SECONDS
#
# Each attempt holds the reboot request lock, reboots only while
# /run/dnf-automatic-reboot.reboot-pending exists, and writes
# /run/dnf-automatic-reboot.reboot-dispatched before it calls systemctl
# reboot.  cancel-reboot.sh holds the same lock, so a cancellation either
# completes before an attempt, and the reboot does not happen, or sees the
# dispatched file and refuses.
#
# systemctl reboot runs with --check-inhibitors=yes: from a service it would
# otherwise ignore shutdown inhibitors, such as one a package transaction
# holds.  A reboot it refuses while the host stays up is retried every
# REBOOT_RETRY_INTERVAL_SEC until INHIBITED_WAIT_SECONDS have passed; between
# attempts the dispatched file is removed and the lock released, so the
# reboot can still be cancelled.  It never uses --force.  A refusal is checked
# against the host's shutdown state first: logind may have accepted it.
#
# Exit: 0 = reboot submitted, or nothing pending; 1 = the reboot did not
# happen or its outcome is unknown (OnFailure= reports it).  The dispatched
# file stays only when the outcome is unknown.
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

# Interval between attempts while a shutdown inhibitor refuses the reboot.
readonly REBOOT_RETRY_INTERVAL_SEC=30

# blocking_inhibitors -> the block-mode shutdown inhibitors logind lists, one
# per "; ", or "none listed".
blocking_inhibitors() {
    local inhibitor_lines
    inhibitor_lines=$(systemd-inhibit --list --mode=block --no-pager --no-legend 2>/dev/null \
                      | sed 's/[[:space:]]\{2,\}/ /g' | paste -sd';' -) || inhibitor_lines=""
    printf '%s' "${inhibitor_lines:-none listed}"
}

# attempt_reboot LOCK_WAIT_SECONDS
# Returns: 0 = the reboot was submitted (the lock stays held until exit), or
#              no reboot is pending
#          1 = the reboot did not happen, or its outcome is unknown; logged
#          2 = refused while the host stays up: dispatched file removed, lock
#              released, worth another attempt
attempt_reboot() {
    local lock_wait_seconds="$1" shutdown_state
    if ! acquire_reboot_request_lock "${lock_wait_seconds}"; then
        log_error "${REBOOT_REQUEST_LOCK_FILE} not acquired within ${lock_wait_seconds}s - not rebooting; update runs stay held"
        return 1
    fi
    if [[ ! -e "${REBOOT_PENDING_FILE}" ]]; then
        log "the reboot was cancelled - not rebooting"
        return 0
    fi
    if ! : > "${REBOOT_DISPATCHED_FILE}" 2>/dev/null; then
        log_error "cannot create ${REBOOT_DISPATCHED_FILE} - not rebooting; update runs stay held"
        return 1
    fi
    if reboot_host; then
        log "Orderly reboot requested"
        return 0
    fi
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
    rm -f "${REBOOT_DISPATCHED_FILE}"
    release_reboot_request_lock
    return 2
}

main() {
    local lock_wait_seconds="${1:-60}" inhibited_wait_seconds="${2:-0}" retry_deadline attempt_result
    [[ "${lock_wait_seconds}" =~ ^[0-9]{1,9}$ ]] || lock_wait_seconds=60
    [[ "${inhibited_wait_seconds}" =~ ^[0-9]{1,9}$ ]] || inhibited_wait_seconds=0
    lock_wait_seconds=$(( 10#${lock_wait_seconds} ))
    inhibited_wait_seconds=$(( 10#${inhibited_wait_seconds} ))
    if ! systemctl_checks_inhibitors; then
        log_error "systemctl does not accept --check-inhibitors=yes, so a reboot would override shutdown inhibitors - not rebooting; update runs stay held"
        exit 1
    fi
    retry_deadline=$(( SECONDS + inhibited_wait_seconds ))
    while true; do
        attempt_result=0
        attempt_reboot "${lock_wait_seconds}" || attempt_result=$?
        case "${attempt_result}" in
            0) exit 0 ;;
            1) exit 1 ;;
        esac
        if (( SECONDS >= retry_deadline )); then
            log_error "the reboot was refused for ${inhibited_wait_seconds}s while the host stayed up, most likely by a shutdown inhibitor ($(blocking_inhibitors)) - update runs stay held; reboot the host, or allow updates again with: ${CANCEL_REBOOT_COMMAND}"
            exit 1
        fi
        log_warning "the reboot was refused, most likely by a shutdown inhibitor ($(blocking_inhibitors)) - retrying in ${REBOOT_RETRY_INTERVAL_SEC}s"
        sleep "${REBOOT_RETRY_INTERVAL_SEC}"
    done
}

# Sourcing defines the functions above without rebooting.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
