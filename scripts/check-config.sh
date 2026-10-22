#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# check-config.sh
# ---------------------------------------------------------------------------
# Compares /etc/dnf/automatic-reboot.conf with the configuration this version
# ships, /usr/share/dnf-automatic-reboot/automatic-reboot.conf, and names the
# lines to change by hand.  The file in /etc is %config(noreplace): it keeps
# its keys and values across upgrades, and every shipped key is set
# explicitly, so an edited copy also keeps the defaults it was edited with.
# Nothing here edits it.
#
#   check-config.sh           every difference; %posttrans runs it
#   check-config.sh --unread  only the keys this version does not read, one
#                             name per line; run.sh logs them at every start
#
# Both files are read as get_config_value reads them: the last KEY = VALUE
# line of a key counts, without leading blanks or a trailing comment.
#
# Exit codes: 0 = no difference, 1 = differences printed, 2 = a file cannot be
# read or the option is unknown.
# ---------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

export LC_ALL=C

# Path prefix, empty in production.  tests/run-tests.sh points it at a
# temporary tree.
readonly TEST_ROOT="${DNF_AUTOMATIC_REBOOT_TEST_ROOT:-}"

readonly CONFIG_FILE="${TEST_ROOT}/etc/dnf/automatic-reboot.conf"
readonly SHIPPED_CONFIG_FILE="${TEST_ROOT}/usr/share/dnf-automatic-reboot/automatic-reboot.conf"

# config_settings FILE -> "KEY<TAB>VALUE" per key, in the order keys first
# appear.  Comment and section lines are skipped.
config_settings() {
    awk '
        /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ {
            key = $0
            sub(/^[[:space:]]*/, "", key)
            sub(/[[:space:]]*=.*$/, "", key)
            value = $0
            sub(/^[^=]*=[[:space:]]*/, "", value)
            sub(/[[:space:]]*#.*$/, "", value)
            sub(/[[:space:]]+$/, "", value)
            if (!(key in values)) key_order[++key_count] = key
            values[key] = value
        }
        END { for (key_index = 1; key_index <= key_count; key_index++) printf "%s\t%s\n", key_order[key_index], values[key_order[key_index]] }
    ' "$1"
}

# compare_config_settings MODE SHIPPED_SETTINGS INSTALLED_SETTINGS -> one line
# per difference; in mode "unread" only the names of keys not shipped.
compare_config_settings() {
    awk -F'\t' -v report_mode="$1" '
        FNR == NR {
            if ($1 != "") { shipped[$1] = $2; shipped_order[++shipped_count] = $1 }
            next
        }
        $1 != "" { installed[$1] = $2; installed_order[++installed_count] = $1 }
        END {
            for (key_index = 1; key_index <= installed_count; key_index++) {
                key = installed_order[key_index]
                if (key in shipped) continue
                if (report_mode == "unread") print key
                else printf "  not read by this version, remove the line:  %s = %s\n", key, installed[key]
            }
            if (report_mode == "unread") exit
            for (key_index = 1; key_index <= shipped_count; key_index++) {
                key = shipped_order[key_index]
                if (!(key in installed)) printf "  not set, the built-in default applies:  %s = %s (shipped)\n", key, shipped[key]
            }
            for (key_index = 1; key_index <= installed_count; key_index++) {
                key = installed_order[key_index]
                if ((key in shipped) && installed[key] != shipped[key])
                    printf "  differs from the shipped value:  %s = %s (shipped: %s)\n", key, installed[key], shipped[key]
            }
        }
    ' <(printf '%s\n' "$2") <(printf '%s\n' "$3")
}

main() {
    local report_mode=all installed_settings shipped_settings differences
    case "${1:-}" in
        "")       ;;
        --unread) report_mode=unread ;;
        *)
            printf 'usage: %s [--unread]\n' "${0##*/}" >&2
            exit 2
            ;;
    esac
    if ! shipped_settings=$(config_settings "${SHIPPED_CONFIG_FILE}" 2>/dev/null); then
        printf 'cannot read %s\n' "${SHIPPED_CONFIG_FILE#"${TEST_ROOT}"}" >&2
        exit 2
    fi
    if ! installed_settings=$(config_settings "${CONFIG_FILE}" 2>/dev/null); then
        printf 'cannot read %s\n' "${CONFIG_FILE#"${TEST_ROOT}"}" >&2
        exit 2
    fi
    differences=$(compare_config_settings "${report_mode}" "${shipped_settings}" "${installed_settings}")
    [[ -n "${differences}" ]] || exit 0
    if [[ "${report_mode}" == "unread" ]]; then
        printf '%s\n' "${differences}"
        exit 1
    fi
    printf 'dnf-automatic-reboot: %s differs from the configuration this version ships.\n' "${CONFIG_FILE#"${TEST_ROOT}"}"
    printf 'The package does not edit it; change by hand what should change:\n'
    printf '%s\n' "${differences}"
    printf 'Compare: diff -u %s %s\n' "${SHIPPED_CONFIG_FILE#"${TEST_ROOT}"}" "${CONFIG_FILE#"${TEST_ROOT}"}"
    exit 1
}

# Sourcing defines the functions without running the comparison.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
