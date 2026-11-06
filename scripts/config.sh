# shellcheck shell=bash
# SPDX-License-Identifier: GPL-2.0-or-later
# config.sh
# ---------------------------------------------------------------------------
# The one reader of /etc/dnf/automatic-reboot.conf.  Sourced by run.sh,
# watchdog.sh, needs-reboot.sh and check-config.sh; never executed.
#
# Grammar.  Each line is blank, a comment (first non-blank character `#`), a
# `[section]` header, or `key = value`.  Sections are accepted and ignored:
# every key is unique across the file.  A value is trimmed of surrounding
# blanks; a `#` at its start or after a blank begins a comment, and a `#`
# inside a word stays.  There is no quoting.
#
# Every one of these is an error: a line of any other shape, a key this
# version does not read, a key set twice, an empty value (except for a list),
# a value its type does not accept, an integer outside its range, and a file
# that cannot be read.  A key that is absent takes its default.
#
# Types:
#   boolean       yes true on 1 / no false off 0, in any case; read as yes/no
#   integer       1 to 9 digits, leading zeros allowed, inside MINIMUM..MAXIMUM
#   pattern_list  comma-separated unit name globs ending in .service; empty is
#                 the empty list
#
# load_config FILE fills CONFIG_VALUES (every key, its default where the file
# does not set it or sets it wrongly) and CONFIG_ERRORS (one line per error).
# It never exits; each caller decides what an error stops.
# ---------------------------------------------------------------------------

# KEY|TYPE|DEFAULT|MINIMUM|MAXIMUM, in the order of the shipped file.  The
# shipped file sets every key to its default; tests/run-tests.sh checks it.
CONFIG_SCHEMA=(
    "restart_services|boolean|yes||"
    "restart_services_excluded_patterns|pattern_list|||"
    "service_restart_timeout_seconds|integer|300|10|900"
    "metadata_refresh_timeout_seconds|integer|1800|60|7200"
    "dnf_query_timeout_seconds|integer|120|30|900"
    "warn_unsigned_repositories|boolean|yes||"
    "warn_unapplied_advisories|boolean|yes||"
    "require_clock_sync|boolean|yes||"
    "clock_sync_timeout_seconds|integer|600|60|3600"
)

# Fixed limits, not settings.  Seconds between SIGTERM and SIGKILL for every
# command run.sh, needs-reboot.sh and watchdog.sh run under timeout(1): a
# client that ignores SIGTERM is killed this long after its deadline.
# shellcheck disable=SC2034  # read by run.sh, needs-reboot.sh and watchdog.sh
KILL_GRACE_SECONDS=300

# One element of a pattern_list: a bash glob over unit names.  No blanks, no
# quotes, no backslash; an escaped unit name is matched with ? or *.
CONFIG_UNIT_PATTERN_SHAPE='^[A-Za-z0-9@._:*?-]+\.service$'
# Longest value a diagnostic repeats.
CONFIG_DIAGNOSTIC_VALUE_LENGTH=80

# -g: the arrays stay script-global when this file is sourced inside a
# function, as tests/run-tests.sh does.
declare -gA CONFIG_VALUES=()
declare -gA CONFIG_KEY_LINES=()
declare -gA CONFIG_KEY_TYPES=()
declare -gA CONFIG_KEY_DEFAULTS=()
declare -gA CONFIG_KEY_MINIMUMS=()
declare -gA CONFIG_KEY_MAXIMUMS=()
CONFIG_KEYS=()
CONFIG_ERRORS=()

# load_config_schema - fills the CONFIG_KEY_* maps from CONFIG_SCHEMA.
load_config_schema() {
    local schema_row config_key config_type default_value minimum_value maximum_value
    CONFIG_KEYS=()
    for schema_row in "${CONFIG_SCHEMA[@]}"; do
        IFS='|' read -r config_key config_type default_value minimum_value maximum_value <<< "${schema_row}"
        CONFIG_KEYS+=("${config_key}")
        CONFIG_KEY_TYPES["${config_key}"]="${config_type}"
        CONFIG_KEY_DEFAULTS["${config_key}"]="${default_value}"
        CONFIG_KEY_MINIMUMS["${config_key}"]="${minimum_value}"
        CONFIG_KEY_MAXIMUMS["${config_key}"]="${maximum_value}"
    done
}
load_config_schema

# printable_config_text TEXT -> TEXT with every character outside printable
# ASCII replaced by `?`, cut at CONFIG_DIAGNOSTIC_VALUE_LENGTH.
printable_config_text() {
    local text="$1"
    text="${text//[^[:print:]]/?}"
    if (( ${#text} > CONFIG_DIAGNOSTIC_VALUE_LENGTH )); then
        text="${text:0:${CONFIG_DIAGNOSTIC_VALUE_LENGTH}}..."
    fi
    printf '%s' "${text}"
}

# trim_config_blanks TEXT -> TEXT without leading and trailing blanks.
trim_config_blanks() {
    local text="$1"
    text="${text#"${text%%[![:space:]]*}"}"
    printf '%s' "${text%"${text##*[![:space:]]}"}"
}

# strip_config_comment TEXT -> TEXT up to a `#` that starts it or follows a
# blank.  A `#` inside a word is part of the value.
strip_config_comment() {
    local rest="$1" kept="" head
    while [[ "${rest}" == *'#'* ]]; do
        head="${rest%%#*}"
        if [[ -z "${kept}${head}" || "${head}" == *[[:space:]] ]]; then
            printf '%s' "${kept}${head}"
            return 0
        fi
        kept+="${head}#"
        rest="${rest#*#}"
    done
    printf '%s' "${kept}${rest}"
}

# normalise_config_value KEY VALUE -> VALUE in its canonical form: yes/no for
# a boolean, decimal without leading zeros for an integer, items joined by
# `,` for a list.  Returns 1 after printing the reason when the type does
# not accept VALUE.
normalise_config_value() {
    local config_key="$1" config_value="$2" config_type minimum_value maximum_value
    local list_item normalised_items="" list_items=()
    config_type="${CONFIG_KEY_TYPES[${config_key}]}"
    case "${config_type}" in
        boolean)
            case "${config_value,,}" in
                yes|true|on|1)  printf 'yes' ;;
                no|false|off|0) printf 'no' ;;
                *) printf 'is not a yes value (yes, true, on, 1) or a no value (no, false, off, 0)'; return 1 ;;
            esac
            ;;
        integer)
            minimum_value="${CONFIG_KEY_MINIMUMS[${config_key}]}"
            maximum_value="${CONFIG_KEY_MAXIMUMS[${config_key}]}"
            if [[ ! "${config_value}" =~ ^[0-9]{1,9}$ ]]; then
                printf 'is not a whole number from %s to %s' "${minimum_value}" "${maximum_value}"
                return 1
            fi
            config_value=$(( 10#${config_value} ))
            if (( config_value < minimum_value || config_value > maximum_value )); then
                printf 'is outside %s to %s' "${minimum_value}" "${maximum_value}"
                return 1
            fi
            printf '%s' "${config_value}"
            ;;
        pattern_list)
            [[ -n "${config_value}" ]] || return 0
            IFS=',' read -r -a list_items <<< "${config_value},"
            for list_item in "${list_items[@]}"; do
                list_item=$(trim_config_blanks "${list_item}")
                if [[ -z "${list_item}" ]]; then
                    printf 'has an empty item'
                    return 1
                fi
                if [[ ! "${list_item}" =~ ${CONFIG_UNIT_PATTERN_SHAPE} ]]; then
                    printf 'item "%s" is not a unit name or glob ending in .service' "$(printable_config_text "${list_item}")"
                    return 1
                fi
                normalised_items+="${normalised_items:+,}${list_item}"
            done
            printf '%s' "${normalised_items}"
            ;;
    esac
}

# add_config_error MESSAGE
add_config_error() {
    CONFIG_ERRORS+=("$1")
}

# parse_config_line FILE_NAME LINE_NUMBER LINE - validates one line and
# records its key and value, or an error naming FILE_NAME and LINE_NUMBER.
parse_config_line() {
    local config_file="$1" line_number="$2" config_line="$3"
    local config_key config_value normalised_value=""
    config_line=$(trim_config_blanks "${config_line}")
    [[ -z "${config_line}" || "${config_line}" == '#'* ]] && return 0
    if [[ "${config_line}" == '['* ]]; then
        config_line=$(trim_config_blanks "$(strip_config_comment "${config_line}")")
        if [[ ! "${config_line}" =~ ^\[[a-z_]+\]$ ]]; then
            add_config_error "${config_file}:${line_number}: not a section header: $(printable_config_text "${config_line}")"
        fi
        return 0
    fi
    if [[ "${config_line}" != *=* ]]; then
        add_config_error "${config_file}:${line_number}: not a 'key = value' line: $(printable_config_text "${config_line}")"
        return 0
    fi
    config_key=$(trim_config_blanks "${config_line%%=*}")
    config_value=$(trim_config_blanks "$(strip_config_comment "${config_line#*=}")")
    if [[ -z "${config_key}" ]]; then
        add_config_error "${config_file}:${line_number}: no key before '='"
        return 0
    fi
    if [[ ! "${config_key}" =~ ^[a-z][a-z0-9_]*$ || -z "${CONFIG_KEY_TYPES[${config_key}]+set}" ]]; then
        add_config_error "${config_file}:${line_number}: $(printable_config_text "${config_key}") is not a setting of this version"
        return 0
    fi
    if [[ -n "${CONFIG_KEY_LINES[${config_key}]+set}" ]]; then
        add_config_error "${config_file}:${line_number}: ${config_key} is already set on line ${CONFIG_KEY_LINES[${config_key}]}"
        return 0
    fi
    CONFIG_KEY_LINES["${config_key}"]="${line_number}"
    if [[ -z "${config_value}" && "${CONFIG_KEY_TYPES[${config_key}]}" != "pattern_list" ]]; then
        add_config_error "${config_file}:${line_number}: ${config_key} has no value"
        return 0
    fi
    if ! normalised_value=$(normalise_config_value "${config_key}" "${config_value}"); then
        add_config_error "${config_file}:${line_number}: ${config_key} = $(printable_config_text "${config_value}") ${normalised_value}"
        return 0
    fi
    CONFIG_VALUES["${config_key}"]="${normalised_value}"
}

# load_config FILE
# Returns 0 when FILE is valid, 1 when CONFIG_ERRORS lists why it is not.
# CONFIG_VALUES holds every key either way: the file's value where it is
# valid, the default otherwise, so a caller that sources a script with an
# invalid file still gets well-formed values; it must not act on them.
load_config() {
    local config_file="$1" config_file_name config_content config_line line_number=0 config_key
    # The path as an operator knows it, without the test suite's prefix.
    config_file_name="${config_file#"${TEST_ROOT:-}"}"
    CONFIG_VALUES=()
    CONFIG_KEY_LINES=()
    CONFIG_ERRORS=()
    for config_key in "${CONFIG_KEYS[@]}"; do
        CONFIG_VALUES["${config_key}"]="${CONFIG_KEY_DEFAULTS[${config_key}]}"
    done
    # Read whole through cat: its status reports an open or read failure,
    # where the read builtin reports end of input.
    if [[ ! -f "${config_file}" ]] || ! config_content=$(cat -- "${config_file}" 2>/dev/null); then
        add_config_error "${config_file_name}: cannot be read"
        return 1
    fi
    while IFS= read -r config_line || [[ -n "${config_line}" ]]; do
        line_number=$(( line_number + 1 ))
        parse_config_line "${config_file_name}" "${line_number}" "${config_line}"
    done <<< "${config_content}"
    [[ "${#CONFIG_ERRORS[@]}" -eq 0 ]]
}

# config_value KEY -> the value load_config settled on.  An unknown KEY is a
# programming error: it prints to stderr and returns 1, which under set -e
# stops the caller.
config_value() {
    if [[ -z "${CONFIG_VALUES[$1]+set}" ]]; then
        printf 'config_value: unknown key %s\n' "$1" >&2
        return 1
    fi
    printf '%s' "${CONFIG_VALUES[$1]}"
}
