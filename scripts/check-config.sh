#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# check-config.sh
# ---------------------------------------------------------------------------
# Validates /etc/dnf/automatic-reboot.conf with the parser every script uses
# (config.sh), and names the settings that differ from the configuration this
# version ships, /usr/share/dnf-automatic-reboot/automatic-reboot.conf.
# Nothing here edits either file.
#
#   check-config.sh   every error, or every difference; %posttrans runs it
#
# Exit codes:
#   0  valid, every value as shipped
#   1  valid, with values that differ from the shipped ones
#   2  invalid or unreadable, or a usage error; the errors go to stdout
# ---------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

export LC_ALL=C

# Path prefix, empty in production.  tests/run-tests.sh points it at a
# temporary tree.
readonly TEST_ROOT="${DNF_AUTOMATIC_REBOOT_TEST_ROOT:-}"

readonly CONFIG_FILE="${TEST_ROOT}/etc/dnf/automatic-reboot.conf"
readonly SHIPPED_CONFIG_FILE="${TEST_ROOT}/usr/share/dnf-automatic-reboot/automatic-reboot.conf"
# Where rpm puts the shipped file when the one in /etc was edited.
readonly NEW_CONFIG_FILE="${CONFIG_FILE}.rpmnew"
readonly CHECK_CONFIG_COMMAND=/usr/libexec/dnf-automatic-reboot/check-config.sh

# load_config and config_value.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# operator_path PATH -> PATH without the test suite's prefix.
operator_path() {
    printf '%s' "${1#"${TEST_ROOT}"}"
}

# print_invalid_config_report - the errors, and how to start from the file
# this version ships without losing the operator's copy.
print_invalid_config_report() {
    local config_error replacement_command
    printf 'dnf-automatic-reboot: %s is not valid for this version:\n' "$(operator_path "${CONFIG_FILE}")"
    for config_error in "${CONFIG_ERRORS[@]}"; do
        printf '  %s\n' "${config_error}"
    done
    printf 'Update runs stop, and no reboot is requested, until it is valid.\n'
    if [[ -f "${NEW_CONFIG_FILE}" ]]; then
        replacement_command="mv $(operator_path "${NEW_CONFIG_FILE}") $(operator_path "${CONFIG_FILE}")"
        printf 'The configuration this version ships is %s.  Keep a copy of yours, compare, replace:\n' \
            "$(operator_path "${NEW_CONFIG_FILE}")"
        printf '  cp -p %s %s.bak\n' "$(operator_path "${CONFIG_FILE}")" "$(operator_path "${CONFIG_FILE}")"
        printf '  diff -u %s.bak %s\n' "$(operator_path "${CONFIG_FILE}")" "$(operator_path "${NEW_CONFIG_FILE}")"
    else
        replacement_command="cp $(operator_path "${SHIPPED_CONFIG_FILE}") $(operator_path "${CONFIG_FILE}")"
        printf 'The configuration this version ships is %s.  Keep a copy of yours, compare, replace:\n' \
            "$(operator_path "${SHIPPED_CONFIG_FILE}")"
        printf '  cp -p %s %s.bak\n' "$(operator_path "${CONFIG_FILE}")" "$(operator_path "${CONFIG_FILE}")"
        printf '  diff -u %s.bak %s\n' "$(operator_path "${CONFIG_FILE}")" "$(operator_path "${SHIPPED_CONFIG_FILE}")"
    fi
    printf '  %s\n' "${replacement_command}"
    printf 'then carry your changes over and run %s again.\n' "${CHECK_CONFIG_COMMAND}"
}

# report_config_differences - validates both files; exit 0, 1 or 2 as above.
report_config_differences() {
    local config_key differences=()
    declare -A shipped_values=()
    if ! load_config "${SHIPPED_CONFIG_FILE}"; then
        printf 'cannot read %s as this version ships it:\n' "$(operator_path "${SHIPPED_CONFIG_FILE}")"
        printf '  %s\n' "${CONFIG_ERRORS[@]}"
        exit 2
    fi
    for config_key in "${CONFIG_KEYS[@]}"; do
        shipped_values["${config_key}"]="${CONFIG_VALUES[${config_key}]}"
    done
    if ! load_config "${CONFIG_FILE}"; then
        print_invalid_config_report
        exit 2
    fi
    for config_key in "${CONFIG_KEYS[@]}"; do
        if [[ "${CONFIG_VALUES[${config_key}]}" != "${shipped_values[${config_key}]}" ]]; then
            differences+=("  ${config_key} = ${CONFIG_VALUES[${config_key}]} (shipped: ${shipped_values[${config_key}]:-empty})")
        fi
    done
    [[ "${#differences[@]}" -gt 0 ]] || exit 0
    printf 'dnf-automatic-reboot: %s is valid; these settings differ from the ones this version ships:\n' \
        "$(operator_path "${CONFIG_FILE}")"
    printf '%s\n' "${differences[@]}"
    printf 'Compare: diff -u %s %s\n' "$(operator_path "${SHIPPED_CONFIG_FILE}")" "$(operator_path "${CONFIG_FILE}")"
    exit 1
}

main() {
    if [[ "$#" -gt 0 ]]; then
        printf 'usage: %s\n' "${0##*/}" >&2
        exit 2
    fi
    report_config_differences
}

# Sourcing defines the functions without running the check.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
