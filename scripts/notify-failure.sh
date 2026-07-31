#!/bin/bash
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
# templated dnf-automatic-reboot-failure@.service.
#
# Configuration: /etc/dnf/automatic-reboot.conf
# Log:           /var/log/dnf-automatic-reboot.log
# ---------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

export LC_ALL=C

readonly CONFIG_FILE=/etc/dnf/automatic-reboot.conf
readonly LOG_FILE=/var/log/dnf-automatic-reboot.log
readonly SCRIPT_NAME=notify-failure
readonly JOURNAL_EXCERPT_LINES=15

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

failed_unit_name="${1:-dnf-automatic-reboot.service}"

log_err "${failed_unit_name} FAILED - the host may be running unpatched or unrebooted"

journal_excerpt=""
journal_excerpt=$(journalctl -u "${failed_unit_name}" -n "${JOURNAL_EXCERPT_LINES}" \
                  --no-pager --output=cat 2>/dev/null) || true
if [[ -n "${journal_excerpt}" ]]; then
    while IFS= read -r journal_line; do
        [[ -n "${journal_line}" ]] && log_err "${failed_unit_name}: ${journal_line}"
    done <<< "${journal_excerpt}"
fi

wall_msg "dnf-automatic-reboot: ${failed_unit_name} FAILED." \
         "Automatic updates or the reboot decision did not complete." \
         "Inspect: journalctl -u ${failed_unit_name} -e"

exit 0
