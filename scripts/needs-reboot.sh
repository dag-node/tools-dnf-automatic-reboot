#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# needs-reboot.sh
# ---------------------------------------------------------------------------
# Determines whether a reboot is required after package updates.
#
# Wraps needs-restarting(1) and filters known false positives before
# making the final decision.  Designed to be called from run.sh and
# watchdog.sh so the logic lives in exactly one place.
#
# Exit codes:
#   0  No reboot needed
#   1  Reboot is needed
#   2  Tool error, or a genuine reboot requirement that rebooting would not
#      satisfy.  Treated as "no reboot" to avoid a reboot loop; run.sh
#      escalates it to a unit failure so the outcome is never silent.
#
# Parsing contract: needs-restarting output is read with an allowlist - only
# lines of the exact form "  * <name>" are taken as package names, and the
# command runs under LC_ALL=C with stderr kept out of the parsed stream.
# Every string the plugin prints goes through gettext, so a translated locale
# or a stderr warning line reaching the parser would otherwise be mistaken for
# a package name and reboot the host.
#
# Verification contract: a package is dropped only on positive evidence that
# it is spurious.  Every "cannot tell" outcome keeps the package, so an
# unverifiable state costs a reboot rather than skipping a needed one.
#
# Sourcing this file defines its functions without running the decision, so
# tests/run-tests.sh can exercise them directly.
#
# Configuration is read from /etc/dnf/automatic-reboot.conf.
# ---------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

# needs-restarting output is translated; the parsers below match C strings.
export LC_ALL=C

# Path prefix, empty in production.  tests/run-tests.sh points it at a
# temporary tree so every path and helper binary below resolves inside it.
readonly TEST_ROOT="${DNF_AUTOMATIC_REBOOT_TEST_ROOT:-}"

readonly CONFIG_FILE="${TEST_ROOT}/etc/dnf/automatic-reboot.conf"
readonly LOG_FILE="${TEST_ROOT}/var/log/dnf-automatic-reboot.log"
readonly SCRIPT_NAME=needs-reboot
readonly STATE_DIRECTORY="${TEST_ROOT}/var/lib/dnf-automatic-reboot"
readonly RESTART_STATE_FILE="${STATE_DIRECTORY}/restart-state"
readonly KERNEL_REBOOT_ATTEMPT_FILE="${STATE_DIRECTORY}/kernel-reboot-attempts"
readonly STATE_LOCK_FILE="${STATE_DIRECTORY}/.state.lock"
readonly PROC_DIRECTORY="${TEST_ROOT}/proc"
readonly BOOT_ID_FILE="${PROC_DIRECTORY}/sys/kernel/random/boot_id"
readonly DNF_BIN="${TEST_ROOT}/usr/bin/dnf"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------
# get_config_value KEY DEFAULT_VALUE
# Reads a key from any section; returns DEFAULT_VALUE when the key is absent.
get_config_value() {
    local config_key="$1" default_value="$2" config_value
    config_value=$(grep -E "^\s*${config_key}\s*=" "${CONFIG_FILE}" 2>/dev/null \
                   | tail -1 | sed 's/^[^=]*=\s*//' | sed 's/\s*#.*//') || true
    printf '%s' "${config_value:-${default_value}}"
}

# get_config_integer KEY DEFAULT_VALUE
# As get_config_value, but falls back to DEFAULT_VALUE when the configured value is
# not a plain non-negative integer.  Keeps a typo in the config from aborting
# the run inside an arithmetic comparison.
get_config_integer() {
    local config_key="$1" default_value="$2" config_value
    config_value=$(get_config_value "${config_key}" "${default_value}")
    config_value="${config_value//[[:space:]]/}"
    if [[ ! "${config_value}" =~ ^[0-9]+$ ]]; then
        log_warning "${config_key}='${config_value}' is not a non-negative integer - using default ${default_value}" >&2
        config_value="${default_value}"
    fi
    printf '%s' "${config_value}"
}

# ---------------------------------------------------------------------------
# Persistent state
#
# Both state files are tab-delimited with the package name in field 1 and are
# rewritten whole under an flock, so a watchdog-triggered run racing the main
# service cannot interleave a partial write.  Rows are matched by exact awk
# field comparison, never by grep: "libglibc" must not match a rule about
# "glibc".  Every failure path is silent and non-fatal - a lost update means
# the package is re-evaluated fresh next run.
# ---------------------------------------------------------------------------

# write_restart_state PACKAGE_NAME PACKAGE_EVR BOOT_ID STATE
# Replaces the package's row - one row per package, a new EVR supersedes the
# old row rather than accumulating history.
write_restart_state() {
    local package_name="$1" package_evr="$2" boot_id="$3" learned_state="$4"
    mkdir -p "${STATE_DIRECTORY}" 2>/dev/null || true
    (
        flock -w 10 9 || exit 0
        local temporary_file
        temporary_file=$(mktemp "${RESTART_STATE_FILE}.XXXXXX") || exit 0
        { awk -F'\t' -v name="${package_name}" '$1 != name' "${RESTART_STATE_FILE}" 2>/dev/null || true
          printf '%s\t%s\t%s\t%s\t%s\n' \
              "${package_name}" "${package_evr}" "${boot_id}" "$(date +%s)" "${learned_state}"
        } > "${temporary_file}" 2>/dev/null || { rm -f "${temporary_file}"; exit 0; }
        chmod 0640 "${temporary_file}" 2>/dev/null || true
        mv -f "${temporary_file}" "${RESTART_STATE_FILE}" 2>/dev/null || rm -f "${temporary_file}"
    ) 9>>"${STATE_LOCK_FILE}" 2>/dev/null || true
}

# read_restart_state PACKAGE_NAME -> prints the row, empty when absent
read_restart_state() {
    awk -F'\t' -v name="$1" '$1 == name' "${RESTART_STATE_FILE}" 2>/dev/null | tail -1 || true
}

# read_kernel_reboot_attempts PACKAGE_NAME TARGET_VERSION
# Prints the recorded consecutive attempt count for this exact target
# version, or 0 when nothing is recorded for it.
read_kernel_reboot_attempts() {
    local package_name="$1" target_version="$2"
    awk -F'\t' -v name="${package_name}" -v target="${target_version}" \
        '$1 == name && $2 == target { attempts = $3 } END { print attempts + 0 }' \
        "${KERNEL_REBOOT_ATTEMPT_FILE}" 2>/dev/null || printf '0'
}

# read_kernel_reboot_attempt_boot_id PACKAGE_NAME TARGET_VERSION
# Prints the boot_id of the boot that counted the last attempt, empty when
# none is recorded.
read_kernel_reboot_attempt_boot_id() {
    local package_name="$1" target_version="$2"
    awk -F'\t' -v name="${package_name}" -v target="${target_version}" \
        '$1 == name && $2 == target { boot_id = $4 } END { print boot_id }' \
        "${KERNEL_REBOOT_ATTEMPT_FILE}" 2>/dev/null || true
}

# write_kernel_reboot_attempts PACKAGE_NAME TARGET_VERSION ATTEMPT_COUNT [BOOT_ID]
# An ATTEMPT_COUNT of 0 clears the package's row.
write_kernel_reboot_attempts() {
    local package_name="$1" target_version="$2" attempt_count="$3" boot_id="${4:-}"
    mkdir -p "${STATE_DIRECTORY}" 2>/dev/null || true
    (
        flock -w 10 9 || exit 0
        local temporary_file
        temporary_file=$(mktemp "${KERNEL_REBOOT_ATTEMPT_FILE}.XXXXXX") || exit 0
        # The `if` must not be the last command of the group: as a bare
        # `[[ ]] && printf`, a zero count made the group exit non-zero and the
        # rewritten file was discarded instead of clearing the row.
        {
            awk -F'\t' -v name="${package_name}" '$1 != name' "${KERNEL_REBOOT_ATTEMPT_FILE}" 2>/dev/null || true
            if [[ "${attempt_count}" -gt 0 ]]; then
                printf '%s\t%s\t%s\t%s\n' "${package_name}" "${target_version}" "${attempt_count}" "${boot_id}"
            fi
        } > "${temporary_file}" 2>/dev/null || { rm -f "${temporary_file}"; exit 0; }
        chmod 0640 "${temporary_file}" 2>/dev/null || true
        mv -f "${temporary_file}" "${KERNEL_REBOOT_ATTEMPT_FILE}" 2>/dev/null || rm -f "${temporary_file}"
    ) 9>>"${STATE_LOCK_FILE}" 2>/dev/null || true
}

# clear_kernel_reboot_attempts_for_running_kernel
# Removes every kernel-reboot-attempts row whose target is the running kernel:
# that reboot worked.  Runs at every check, whatever needs-restarting reports:
# on a host with a correct clock it no longer flags the kernel once the new one
# runs, so the false-positive branch that also clears the row is not reached.
clear_kernel_reboot_attempts_for_running_kernel() {
    local running_kernel_version machine_architecture
    [[ -s "${KERNEL_REBOOT_ATTEMPT_FILE}" ]] || return 0
    running_kernel_version=$(uname -r)
    machine_architecture=$(uname -m)
    awk -F'\t' -v running="${running_kernel_version}" -v arch="${machine_architecture}" \
        '$2 == running || $2 == running "." arch { found = 1 } END { exit !found }' \
        "${KERNEL_REBOOT_ATTEMPT_FILE}" 2>/dev/null || return 0
    (
        flock -w 10 9 || exit 0
        local temporary_file
        temporary_file=$(mktemp "${KERNEL_REBOOT_ATTEMPT_FILE}.XXXXXX") || exit 0
        awk -F'\t' -v running="${running_kernel_version}" -v arch="${machine_architecture}" \
            '!($2 == running || $2 == running "." arch)' "${KERNEL_REBOOT_ATTEMPT_FILE}" \
            > "${temporary_file}" 2>/dev/null || { rm -f "${temporary_file}"; exit 0; }
        chmod 0640 "${temporary_file}" 2>/dev/null || true
        mv -f "${temporary_file}" "${KERNEL_REBOOT_ATTEMPT_FILE}" 2>/dev/null || rm -f "${temporary_file}"
        log "kernel ${running_kernel_version} is running - its reboot attempts are cleared"
    ) 9>>"${STATE_LOCK_FILE}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Read config
# ---------------------------------------------------------------------------
FILTER_PACKAGE_LIST=$(get_config_value filter_packages "kernel-uek,kernel-uek-core,kernel,kernel-core,systemd")
VERIFY_KERNEL_VERSION=$(get_config_value verify_kernel_version yes)
LEARN_FALSE_POSITIVES=$(get_config_value learn_false_positives yes)
VERIFY_GRUB_DEFAULT=$(get_config_value verify_grub_default yes)
KERNEL_REBOOT_ATTEMPT_LIMIT=$(get_config_integer kernel_reboot_attempt_limit 3)
NEEDS_RESTARTING_TIMEOUT_SEC=$(get_config_integer needs_restarting_timeout_sec 120)

# Save and restore IFS around the comma-split so the global \n\t setting
# is not silently clobbered for the rest of the script.
PREVIOUS_IFS="${IFS}"
IFS=',' read -ra FILTER_PACKAGE_FIELDS <<< "${FILTER_PACKAGE_LIST}"
IFS="${PREVIOUS_IFS}"
FILTER_PACKAGE_NAMES=()
for filter_package_field in "${FILTER_PACKAGE_FIELDS[@]:-}"; do
    filter_package_field="${filter_package_field//[[:space:]]/}"
    [[ -n "${filter_package_field}" ]] && FILTER_PACKAGE_NAMES+=("${filter_package_field}")
done

# is_filtered_package PACKAGE_NAME
is_filtered_package() {
    local package_name="$1" filter_package_name
    for filter_package_name in "${FILTER_PACKAGE_NAMES[@]:-}"; do
        [[ "${filter_package_name}" == "${package_name}" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Allowlist parse: reads needs-restarting output on stdin, prints one package
# name per line.  Only "  * <name>" lines qualify; headers, blank lines, and
# anything that leaked in from stderr are discarded by construction rather
# than by a list of known-uninteresting strings.
# ---------------------------------------------------------------------------
parse_flagged_package_names() {
    sed -n 's/^[[:space:]]*\*[[:space:]]\+\([^[:space:]]\+\)[[:space:]]*$/\1/p'
}

# ---------------------------------------------------------------------------
# Process/binary ownership map, built once and only when needed.
#
# Every PID is kept per binary: one binary can run as several processes on
# different images - PID 1 re-execs onto the new systemd while each
# `systemd --user` manager keeps the old one - so a single sample per binary
# can clear a package that still has stale code resident.  Only the rpm
# query is deduplicated, to one `rpm -qf` per distinct binary.
# ---------------------------------------------------------------------------
# -g so the arrays stay script-global even when this file is sourced from
# inside a function, as tests/run-tests.sh does.
# PROCESS_BINARY_TO_PIDS values are newline-separated PID lists.
declare -gA PROCESS_BINARY_TO_PIDS=()
declare -gA PROCESS_BINARY_TO_PACKAGE=()
PROCESS_MAP_BUILT=0

build_process_binary_map() {
    [[ "${PROCESS_MAP_BUILT}" -eq 1 ]] && return 0
    local process_exe_link process_id binary_path owning_package_name
    for process_exe_link in "${PROC_DIRECTORY}"/[0-9]*/exe; do
        process_id="${process_exe_link#"${PROC_DIRECTORY}/"}"
        process_id="${process_id%/exe}"
        binary_path=$(readlink "${process_exe_link}" 2>/dev/null) || continue
        binary_path="${binary_path% (deleted)}"
        [[ -f "${binary_path}" ]] || continue
        PROCESS_BINARY_TO_PIDS["${binary_path}"]+="${process_id}"$'\n'
    done
    for binary_path in "${!PROCESS_BINARY_TO_PIDS[@]}"; do
        owning_package_name=$(rpm -qf "${binary_path}" --qf '%{NAME}' 2>/dev/null) || owning_package_name=""
        PROCESS_BINARY_TO_PACKAGE["${binary_path}"]="${owning_package_name}"
    done
    PROCESS_MAP_BUILT=1
    return 0
}

# ---------------------------------------------------------------------------
# Build-id cross-verification for non-kernel filtered packages.
#
# Every running process whose binary the package owns is checked, not just the
# first: PID 1 re-execs itself during a systemd upgrade and would always match,
# while journald, udevd and logind can still be running the old image.
#
# Returns: 0 = false positive confirmed  1 = cannot verify  2 = genuine update
# A process whose build-id cannot be read while it still runs the binary is
# "cannot verify", whatever the other processes show.
# ---------------------------------------------------------------------------

# process_runs_binary PID BINARY_PATH
# Returns: 0 = PID still runs BINARY_PATH, the replaced image included
#          1 = PID has exited, is a zombie, or now runs another binary
#          2 = PID exists but readlink fails on its executable link
process_runs_binary() {
    local process_id="$1" binary_path="$2" current_binary_path process_status=""
    if current_binary_path=$(readlink "${PROC_DIRECTORY}/${process_id}/exe" 2>/dev/null); then
        [[ "${current_binary_path% (deleted)}" == "${binary_path}" ]] || return 1
        return 0
    fi
    [[ -d "${PROC_DIRECTORY}/${process_id}" ]] || return 1
    # Field 3 of /proc/PID/stat, after the parenthesised command name.
    process_status=$(cat "${PROC_DIRECTORY}/${process_id}/stat" 2>/dev/null) || return 2
    process_status="${process_status##*) }"
    [[ "${process_status%% *}" == "Z" ]] && return 1
    return 2
}

verify_build_id() {
    local package_name="$1"
    local binary_path process_id running_build_id on_disk_build_id process_runs_binary_result
    local verified_process_count=0 unreadable_build_id=0

    build_process_binary_map

    for binary_path in "${!PROCESS_BINARY_TO_PACKAGE[@]}"; do
        [[ "${PROCESS_BINARY_TO_PACKAGE[${binary_path}]}" == "${package_name}" ]] || continue
        on_disk_build_id=$(eu-readelf -n "${binary_path}" 2>/dev/null \
                           | awk '/Build ID/ {print $NF}') || true
        while IFS= read -r process_id; do
            [[ -n "${process_id}" ]] || continue
            running_build_id=$(eu-readelf -n "${PROC_DIRECTORY}/${process_id}/exe" 2>/dev/null \
                               | awk '/Build ID/ {print $NF}') || true
            if [[ -z "${running_build_id}" || -z "${on_disk_build_id}" ]]; then
                # A process that exited after the /proc walk does not run any code.
                # One still running on this binary blocks the verdict, even
                # when every other process matches.
                process_runs_binary_result=0
                process_runs_binary "${process_id}" "${binary_path}" || process_runs_binary_result=$?
                if [[ "${process_runs_binary_result}" -eq 1 ]]; then
                    log "${package_name}: pid ${process_id} of ${binary_path} exited before its build-id was read"
                    continue
                fi
                log_warning "${package_name}: could not read build-ids for ${binary_path} (pid ${process_id})"
                unreadable_build_id=1
                continue
            fi
            verified_process_count=$(( verified_process_count + 1 ))
            if [[ "${running_build_id}" != "${on_disk_build_id}" ]]; then
                log "${package_name} genuine: build-id mismatch on ${binary_path} (pid ${process_id})"
                return 2
            fi
        done <<< "${PROCESS_BINARY_TO_PIDS[${binary_path}]:-}"
    done

    if [[ "${unreadable_build_id}" -eq 1 ]]; then
        log_warning "${package_name}: a running process could not be verified - keeping the package"
        return 1
    fi
    if [[ "${verified_process_count}" -eq 0 ]]; then
        log_warning "${package_name}: no running process owned by this package"
        return 1
    fi

    log "${package_name} false positive: build-id matches all ${verified_process_count} running process(es)"
    return 0
}

# ---------------------------------------------------------------------------
# Kernel cross-verification (aarch64 and x86_64).
#
# uname -r and rpm's VERSION-RELEASE.ARCH are the same string on both UEK and
# stock EL kernels, so this is an equality test, not a substring search.  The
# arch-stripped form is accepted as well, for kernels whose release string
# carries no arch suffix.
# ---------------------------------------------------------------------------

# newest_installed_kernel_version PACKAGE_NAME
# Prints the highest installed VERSION-RELEASE.ARCH, empty when not installed.
newest_installed_kernel_version() {
    rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' "$1" 2>/dev/null | sort -V | tail -1 || true
}

# running_kernel_is_newest PACKAGE_NAME
# Returns: 0 = the running kernel is the newest installed one (false positive)
#          1 = a newer kernel is installed, or the state cannot be established
running_kernel_is_newest() {
    local package_name="$1" running_kernel_version machine_architecture
    local newest_kernel_version newest_kernel_version_without_arch
    running_kernel_version=$(uname -r)
    machine_architecture=$(uname -m)
    newest_kernel_version=$(newest_installed_kernel_version "${package_name}")
    if [[ -z "${newest_kernel_version}" ]]; then
        # Flagged but not installed, or rpm failed: no evidence of spuriousness.
        log_warning "${package_name}: no installed version found, treating as genuine"
        return 1
    fi
    newest_kernel_version_without_arch="${newest_kernel_version%".${machine_architecture}"}"
    [[ "${running_kernel_version}" == "${newest_kernel_version}" \
       || "${running_kernel_version}" == "${newest_kernel_version_without_arch}" ]]
}

# grub_default_is_newest_kernel PACKAGE_NAME
# Returns: 0 = the GRUB default already points at the newest installed kernel
#          1 = it does not - a reboot would come back on the same kernel
#          2 = cannot determine
grub_default_is_newest_kernel() {
    local package_name="$1" newest_kernel_version grub_default_kernel_path
    command -v grubby >/dev/null 2>&1 || return 2
    newest_kernel_version=$(newest_installed_kernel_version "${package_name}")
    [[ -n "${newest_kernel_version}" ]] || return 2
    grub_default_kernel_path=$(grubby --default-kernel 2>/dev/null) || return 2
    # grubby prints "/boot" and exits 0 when it cannot read grubenv.  Anything
    # that is not a kernel image path is no reading at all, not a stale default.
    [[ "${grub_default_kernel_path}" == /boot/vmlinuz-* ]] || return 2
    [[ "${grub_default_kernel_path}" == "/boot/vmlinuz-${newest_kernel_version}" ]]
}

# ---------------------------------------------------------------------------
# Run needs-restarting.
#
# Invoked through dnf so -C (cache only) can be passed: needs-restarting asks
# for filelists metadata it does not use in -r mode, and dnf-automatic has
# just populated the cache.  A cache-only run without a plugin result falls
# back to a refreshing run rather than being reported as a tool error.
#
# Sets NEEDS_RESTARTING_OUTPUT and returns needs-restarting's exit code, or 2
# when no temporary file for its stderr can be created.
# ---------------------------------------------------------------------------

# needs_restarting_gave_result EXIT_CODE - succeeds when EXIT_CODE and
# NEEDS_RESTARTING_OUTPUT form a plugin result: 0, or 1 with at least one
# package line.  dnf also exits 1 for errors it handles, such as a missing
# cache, so exit 1 alone is no reboot requirement.
needs_restarting_gave_result() {
    local exit_code="$1"
    [[ "${exit_code}" -eq 0 ]] && return 0
    [[ "${exit_code}" -eq 1 ]] || return 1
    [[ -n "$(printf '%s\n' "${NEEDS_RESTARTING_OUTPUT}" | parse_flagged_package_names)" ]]
}

run_needs_restarting() {
    local stderr_capture_file stderr_line exit_code=0

    # No fallback path: this function removes the file when needs-restarting
    # returns, and a fixed path such as /dev/null would be removed with it.
    if ! stderr_capture_file=$(mktemp); then
        log_error "cannot create a temporary file for needs-restarting stderr"
        return 2
    fi

    NEEDS_RESTARTING_OUTPUT=$(timeout "${NEEDS_RESTARTING_TIMEOUT_SEC}s" \
        "${DNF_BIN}" -q -C needs-restarting -r 2>"${stderr_capture_file}") || exit_code=$?

    if ! needs_restarting_gave_result "${exit_code}"; then
        log_warning "cache-only needs-restarting exited ${exit_code} without a result - retrying with a metadata refresh"
        exit_code=0
        NEEDS_RESTARTING_OUTPUT=$(timeout "${NEEDS_RESTARTING_TIMEOUT_SEC}s" \
            "${DNF_BIN}" -q needs-restarting -r 2>"${stderr_capture_file}") || exit_code=$?
    fi

    # Stderr is logged, never parsed.  The plugin emits warnings here for
    # entries in /etc/dnf/plugins/needs-restarting.d/ naming packages that are
    # not installed; folded into stdout those lines would each read as a
    # package name.
    if [[ -s "${stderr_capture_file}" ]]; then
        while IFS= read -r stderr_line; do
            [[ -n "${stderr_line}" ]] && log_warning "needs-restarting: ${stderr_line}"
        done < "${stderr_capture_file}"
    fi

    rm -f "${stderr_capture_file}"
    return "${exit_code}"
}

# ---------------------------------------------------------------------------
# Classify every flagged package into REBOOT_TRIGGER_PACKAGES.
# Sets REBOOT_WITHHELD when a genuine requirement exists that rebooting would
# not satisfy.
# ---------------------------------------------------------------------------
classify_flagged_packages() {
    local flagged_package_name target_kernel_version
    local grub_default_check_result build_id_check_result kernel_reboot_attempts
    local attempt_boot_id current_boot_id
    local build_id_verifier_available=1

    current_boot_id=$(cat "${BOOT_ID_FILE}" 2>/dev/null) || current_boot_id=""

    if ! command -v eu-readelf >/dev/null 2>&1; then
        # elfutils is a hard dependency; if it is gone the build-id path cannot
        # run, but the kernel and learning paths still can.  Losing one verifier
        # must not suppress the reboot decision the others are able to make.
        build_id_verifier_available=0
        log_error "eu-readelf unavailable - elfutils is required; build-id verification disabled, affected packages treated as genuine"
    fi

    REBOOT_TRIGGER_PACKAGES=()
    REBOOT_WITHHELD=0

    for flagged_package_name in "${FLAGGED_PACKAGE_NAMES[@]}"; do

        # -- kernel packages: version-string check is the sole authority ----
        if [[ "${flagged_package_name}" == kernel* ]]; then
            if [[ "${VERIFY_KERNEL_VERSION}" != "yes" ]] || ! is_filtered_package "${flagged_package_name}"; then
                REBOOT_TRIGGER_PACKAGES+=("${flagged_package_name}")
                continue
            fi

            if running_kernel_is_newest "${flagged_package_name}"; then
                log "${flagged_package_name} false positive: running kernel is the newest installed ($(uname -r))"
                write_kernel_reboot_attempts "${flagged_package_name}" "-" 0
                continue
            fi

            target_kernel_version=$(newest_installed_kernel_version "${flagged_package_name}")
            log "${flagged_package_name} genuine: running=$(uname -r) installed=${target_kernel_version}"

            if [[ "${VERIFY_GRUB_DEFAULT}" == "yes" ]]; then
                grub_default_check_result=0
                grub_default_is_newest_kernel "${flagged_package_name}" || grub_default_check_result=$?
                if [[ "${grub_default_check_result}" -eq 1 ]]; then
                    log_error "${flagged_package_name}: GRUB default is $(grubby --default-kernel 2>/dev/null) but the newest installed kernel is ${target_kernel_version} - a reboot would return to the same kernel; withholding reboot, repair the BLS default"
                    REBOOT_WITHHELD=1
                    continue
                elif [[ "${grub_default_check_result}" -eq 2 ]]; then
                    log_warning "${flagged_package_name}: could not read the GRUB default; proceeding with the reboot decision"
                fi
            fi

            # One attempt per boot: every check in a boot that still runs the
            # old kernel - by hand, from the watchdog, or a repeated run -
            # belongs to the same attempt, so only reboots use the budget.
            if [[ "${KERNEL_REBOOT_ATTEMPT_LIMIT}" -gt 0 ]]; then
                kernel_reboot_attempts=$(read_kernel_reboot_attempts \
                    "${flagged_package_name}" "${target_kernel_version}")
                attempt_boot_id=$(read_kernel_reboot_attempt_boot_id \
                    "${flagged_package_name}" "${target_kernel_version}")
                if [[ -n "${current_boot_id}" && "${attempt_boot_id}" == "${current_boot_id}" ]]; then
                    log "${flagged_package_name}: attempt ${kernel_reboot_attempts} of ${KERNEL_REBOOT_ATTEMPT_LIMIT} for ${target_kernel_version} is already counted in this boot"
                else
                    if [[ "${kernel_reboot_attempts}" -ge "${KERNEL_REBOOT_ATTEMPT_LIMIT}" ]]; then
                        log_error "${flagged_package_name}: ${kernel_reboot_attempts} consecutive reboots for ${target_kernel_version} did not make it the running kernel - giving up, manual intervention required"
                        REBOOT_WITHHELD=1
                        continue
                    fi
                    if [[ -z "${current_boot_id}" ]]; then
                        log_warning "could not read boot_id - counting this check as a reboot attempt"
                    fi
                    write_kernel_reboot_attempts "${flagged_package_name}" \
                        "${target_kernel_version}" $(( kernel_reboot_attempts + 1 )) "${current_boot_id}"
                fi
            fi

            REBOOT_TRIGGER_PACKAGES+=("${flagged_package_name}")
            continue
        fi

        # -- non-kernel packages in filter_packages: build-id check ---------
        if is_filtered_package "${flagged_package_name}"; then
            if [[ "${build_id_verifier_available}" -eq 0 ]]; then
                REBOOT_TRIGGER_PACKAGES+=("${flagged_package_name}")
                continue
            fi
            build_id_check_result=0
            verify_build_id "${flagged_package_name}" || build_id_check_result=$?
            # 0 = confirmed spurious, drop it.  1 (cannot verify) and 2
            # (genuine) both keep it: an unverifiable state costs a reboot.
            [[ "${build_id_check_result}" -eq 0 ]] || REBOOT_TRIGGER_PACKAGES+=("${flagged_package_name}")
            continue
        fi

        # -- everything else: restart-state learning -----------------------
        REBOOT_TRIGGER_PACKAGES+=("${flagged_package_name}")
    done
    return 0
}

# ---------------------------------------------------------------------------
# Restart-state learning (non-kernel triggers only; kernel packages keep the
# version-string check as their sole, more authoritative source of truth).
#
# A package's restart-state is keyed on its exact installed EVR and reaches
# "confirmed" only after surviving a real reboot still flagged at that same
# EVR: /proc/sys/kernel/random/boot_id tells "a reboot happened since this
# package was first flagged" apart from "no reboot yet" without wall-clock
# timestamps, so this check is immune to the boot-time skew that produces the
# underlying false positive.  A new EVR always starts a fresh, unverified
# cycle, so a genuine future update is never masked by an old confirmation.
# Confirmed packages are skipped without a reboot; everything else - first
# observation of a package/EVR pair included - stays a trigger, since one
# reboot is the minimum needed to prove a flag spurious.
# ---------------------------------------------------------------------------
apply_restart_state_learning() {
    local current_boot_id trigger_package_name installed_package_evr restart_state_row
    local recorded_package_evr recorded_boot_id recorded_learned_state
    local learned_trigger_packages=()

    [[ "${LEARN_FALSE_POSITIVES}" == "yes" ]] || return 0
    [[ "${#REBOOT_TRIGGER_PACKAGES[@]}" -gt 0 ]] || return 0

    current_boot_id=$(cat "${BOOT_ID_FILE}" 2>/dev/null) || true
    if [[ -z "${current_boot_id}" ]]; then
        log_warning "could not read boot_id - restart-state learning skipped this run"
        return 0
    fi

    for trigger_package_name in "${REBOOT_TRIGGER_PACKAGES[@]}"; do
        if [[ "${trigger_package_name}" == kernel* ]]; then
            learned_trigger_packages+=("${trigger_package_name}")
            continue
        fi

        installed_package_evr=$(rpm -q --qf '%{EVR}' "${trigger_package_name}" 2>/dev/null) || true
        if [[ -z "${installed_package_evr}" ]]; then
            log_warning "${trigger_package_name}: not installed or rpm query failed, cannot track restart-state"
            learned_trigger_packages+=("${trigger_package_name}")
            continue
        fi

        restart_state_row=$(read_restart_state "${trigger_package_name}")
        if [[ -n "${restart_state_row}" ]]; then
            recorded_package_evr=$(printf '%s' "${restart_state_row}" | cut -f2)
            recorded_boot_id=$(printf '%s' "${restart_state_row}" | cut -f3)
            recorded_learned_state=$(printf '%s' "${restart_state_row}" | cut -f5)

            if [[ "${recorded_package_evr}" == "${installed_package_evr}" \
                  && "${recorded_learned_state}" == "confirmed" ]]; then
                log "${trigger_package_name} restart-state confirmed false positive (evr=${installed_package_evr}) - skipping"
                continue
            fi

            if [[ "${recorded_package_evr}" == "${installed_package_evr}" \
                  && "${recorded_learned_state}" == "pending" \
                  && "${recorded_boot_id}" != "${current_boot_id}" ]]; then
                log "${trigger_package_name} still flagged at evr=${installed_package_evr} after a reboot - confirming false positive"
                write_restart_state "${trigger_package_name}" "${installed_package_evr}" \
                    "${current_boot_id}" confirmed
                continue
            fi

            if [[ "${recorded_package_evr}" != "${installed_package_evr}" ]]; then
                log "${trigger_package_name}: evr ${installed_package_evr} supersedes tracked ${recorded_package_evr} - treating as a fresh restart requirement"
            fi
        fi

        write_restart_state "${trigger_package_name}" "${installed_package_evr}" \
            "${current_boot_id}" pending
        learned_trigger_packages+=("${trigger_package_name}")
    done

    REBOOT_TRIGGER_PACKAGES=("${learned_trigger_packages[@]:-}")
    [[ -z "${REBOOT_TRIGGER_PACKAGES[0]:-}" ]] && REBOOT_TRIGGER_PACKAGES=()
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local needs_restarting_exit_code=0

    clear_kernel_reboot_attempts_for_running_kernel

    NEEDS_RESTARTING_OUTPUT=""
    run_needs_restarting || needs_restarting_exit_code=$?

    if [[ "${needs_restarting_exit_code}" -eq 0 ]]; then
        log "needs-restarting: no reboot needed"
        exit 0
    fi

    # Exit 1 without a package line is a dnf error, not the plugin's answer.
    if ! needs_restarting_gave_result "${needs_restarting_exit_code}"; then
        log_error "needs-restarting exited ${needs_restarting_exit_code} without naming a package - cannot determine reboot state, not rebooting"
        exit 2
    fi

    FLAGGED_PACKAGE_NAMES=()
    mapfile -t FLAGGED_PACKAGE_NAMES < <(printf '%s\n' "${NEEDS_RESTARTING_OUTPUT}" \
        | parse_flagged_package_names)

    log "Packages flagged by needs-restarting: $(printf '%s,' "${FLAGGED_PACKAGE_NAMES[@]}" | sed 's/,$//')"

    classify_flagged_packages
    apply_restart_state_learning

    if [[ "${#REBOOT_TRIGGER_PACKAGES[@]}" -eq 0 ]]; then
        if [[ "${REBOOT_WITHHELD}" -eq 1 ]]; then
            log_error "Reboot withheld: a genuine kernel update is pending but rebooting would not boot it - see errors above"
            exit 2
        fi
        log "All triggers filtered as false positives - no reboot needed"
        exit 0
    fi

    log "Reboot needed: $(printf '%s,' "${REBOOT_TRIGGER_PACKAGES[@]}" | sed 's/,$//')"
    exit 1
}

# Sourcing defines the functions above without running the decision.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
