#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# notify-failure.sh
# ---------------------------------------------------------------------------
# Failure notifier, started by OnFailure= from the service units.
#
# Without it a failed run is visible only to somebody who thinks to read the
# journal: a stale /run lock makes the main unit report "skipped" rather than
# "failed", and a needs-reboot.sh tool error leaves the host unrebooted with
# no operator-facing signal at all.
#
# Argument 1 is the name of the unit that failed, passed as %I from the
# templated dnf-automatic-reboot-notify@.service.  For the scheduled reboot's
# transient service, the message says whether update runs stay blocked and
# how to recover.
#
# Configuration: /etc/dnf/automatic-reboot.conf
# Log:           /var/log/dnf-automatic-reboot.log
# ---------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

export LC_ALL=C

# Path prefix, empty in production.  tests/run-tests.sh points it at a
# temporary tree so every path below resolves inside it.
readonly TEST_ROOT="${DNF_AUTOMATIC_REBOOT_TEST_ROOT:-}"

readonly CONFIG_FILE="${TEST_ROOT}/etc/dnf/automatic-reboot.conf"
readonly LOG_FILE="${TEST_ROOT}/var/log/dnf-automatic-reboot.log"
readonly REBOOT_PENDING_FILE="${TEST_ROOT}/run/dnf-automatic-reboot.reboot-pending"
readonly SCHEDULED_REBOOT_SERVICE=dnf-automatic-reboot-scheduled-reboot.service
readonly CANCEL_REBOOT_COMMAND=/usr/libexec/dnf-automatic-reboot/cancel-reboot.sh
readonly SCRIPT_NAME=notify-failure
readonly JOURNAL_EXCERPT_LINES=15

log_error() {
    printf '<3>%s: %s\n' "${SCRIPT_NAME}" "$*"
    printf '%s %s: ERROR: %s\n' "$(date -Iseconds)" "${SCRIPT_NAME}" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}

wall_msg() {
    local wall_messages_enabled
    # A trailing comment is not part of the value: `wall_messages = no  # quiet`.
    wall_messages_enabled=$(grep -E "^\s*wall_messages\s*=" "${CONFIG_FILE}" 2>/dev/null \
                            | tail -1 | sed 's/^[^=]*=\s*//' | sed 's/\s*#.*//' | tr -d ' ') || true
    [[ "${wall_messages_enabled:-yes}" == "no" ]] && return 0
    wall "$*" 2>/dev/null || true
}

# failed_reboot_recovery_hint -> what a failed scheduled reboot leaves behind
# and how to recover from it.
failed_reboot_recovery_hint() {
    if [[ -e "${REBOOT_PENDING_FILE}" ]]; then
        printf '%s' "The scheduled reboot did not happen. Update runs stay blocked until the host reboots: reboot it, or allow updates again with ${CANCEL_REBOOT_COMMAND}"
    else
        printf '%s' "The scheduled reboot did not happen. Update runs are not blocked; reboot the host to apply the updates."
    fi
}

main() {
    local failed_unit_name="${1:-dnf-automatic-reboot.service}" journal_excerpt="" journal_line
    local outcome_summary="Automatic updates or the reboot decision did not complete."

    log_error "${failed_unit_name} FAILED - the host may be running unpatched or unrebooted"

    journal_excerpt=$(journalctl -u "${failed_unit_name}" -n "${JOURNAL_EXCERPT_LINES}" \
                      --no-pager --output=cat 2>/dev/null) || true
    if [[ -n "${journal_excerpt}" ]]; then
        while IFS= read -r journal_line; do
            if [[ -n "${journal_line}" ]]; then
                log_error "${failed_unit_name}: ${journal_line}"
            fi
        done <<< "${journal_excerpt}"
    fi

    if [[ "${failed_unit_name}" == "${SCHEDULED_REBOOT_SERVICE}" ]]; then
        outcome_summary=$(failed_reboot_recovery_hint)
        log_error "${outcome_summary}"
    fi

    wall_msg "dnf-automatic-reboot: ${failed_unit_name} FAILED." \
             "${outcome_summary}" \
             "Inspect: journalctl -u ${failed_unit_name} -e"
    exit 0
}

# Sourcing defines the functions above without notifying.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
