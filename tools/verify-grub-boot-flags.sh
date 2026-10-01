#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# verify-grub-boot-flags.sh
# ---------------------------------------------------------------------------
# Read-only check, run as root on a live host: does anything on this host make
# GRUB choose the boot entry from boot_success or boot_indeterminate?
#
# dnf-automatic-reboot does not set boot_success: in RHEL's GRUB scripts the
# flag only decides whether the menu is hidden, and the one snippet that picks
# an entry from it acts only while boot_counter is set.  Releases before 1.4.0
# shipped grub-boot-success.service, which set boot_success=1 at every boot.
# This script checks the claim against the files and binaries this host runs,
# not against upstream:
#
#   1. every /etc/grub.d snippet and the package that owns it
#   2. every section of the generated grub.cfg, and the EFI stub configs,
#      that both reads a boot flag and selects an entry
#   3. the GRUB EFI images and modules, for the flag names compiled in
#   4. grubenv, for the variables that would arm a flag-driven branch
#   5. kernel-install's 20-grub.install, which is what advances saved_entry
#
# Each check prints PASS, FAIL or INFO.  Exit 0 = no FAIL: the checks found no
# config section, binary or grubenv setting that selects the boot entry from a
# boot flag.  Exit 1 = at least one FAIL: a boot flag may select the entry on
# this host; read the FAIL lines.  Exit 2 = not run as root.
#
#   sudo bash tools/verify-grub-boot-flags.sh
# ---------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

export LC_ALL=C

# Path prefix, empty on a live host; a fixture tree when testing the script.
readonly VERIFY_ROOT="${VERIFY_ROOT:-}"

readonly GRUB_SNIPPET_DIRECTORY="${VERIFY_ROOT}/etc/grub.d"
readonly GRUB_CONFIG_FILE="${VERIFY_ROOT}/boot/grub2/grub.cfg"
readonly GRUB_ENVIRONMENT_FILE="${VERIFY_ROOT}/boot/grub2/grubenv"
readonly EFI_DIRECTORY="${VERIFY_ROOT}/boot/efi/EFI"
readonly GRUB_MODULE_DIRECTORY="${VERIFY_ROOT}/usr/lib/grub"
readonly KERNEL_INSTALL_GRUB_PLUGIN="${VERIFY_ROOT}/usr/lib/kernel/install.d/20-grub.install"
readonly OS_RELEASE_FILE="${VERIFY_ROOT}/etc/os-release"

# The grubenv variables GRUB scripts can branch on to pick an entry.
readonly BOOT_FLAG_PATTERN='boot_success|boot_indeterminate|boot_counter|menu_hide_ok|menu_auto_hide'
# Statements that choose or persist the entry GRUB boots.
readonly ENTRY_SELECTION_PATTERN='set[[:space:]]+default=|save_env[[:space:]].*saved_entry|set[[:space:]]+saved_entry=|set[[:space:]]+next_entry='
# The one snippet expected to do both, and the guard it must sit behind.
readonly FALLBACK_COUNTING_SNIPPET=08_fallback_counting
# shellcheck disable=SC2016  # GRUB's own ${...} text, matched literally
readonly FALLBACK_COUNTING_GUARD='if [ -n "${boot_counter}" -a "${boot_success}" = "0" ]; then'

FAILURE_COUNT=0

# has_execute_bit FILE - grub2-mkconfig runs as root, and for root `test -x`
# holds when any execute bit is set.  Reading the mode bits gives the same
# answer independent of the mount the file is read from.
has_execute_bit() {
    local file_mode
    file_mode=$(stat -c '%A' "$1" 2>/dev/null) || return 1
    [[ "${file_mode}" == *x* ]]
}

report_pass() { printf 'PASS  %s\n' "$*"; }
report_info() { printf 'INFO  %s\n' "$*"; }
report_fail() { printf 'FAIL  %s\n' "$*"; FAILURE_COUNT=$(( FAILURE_COUNT + 1 )); }

if [[ -z "${VERIFY_ROOT}" && "${EUID}" -ne 0 ]]; then
    printf 'Run as root: grub.cfg and grubenv are not readable otherwise.\n' >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# 0. Context
# ---------------------------------------------------------------------------
printf '== context\n'
report_info "os: $(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${OS_RELEASE_FILE}" 2>/dev/null)"
report_info "platform: $(sed -n 's/^PLATFORM_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${OS_RELEASE_FILE}" 2>/dev/null)"
report_info "kernel: $(uname -r) ($(uname -m))"
if [[ -d "${VERIFY_ROOT}/sys/firmware/efi" ]]; then
    report_info "firmware: EFI"
else
    report_info "firmware: not EFI"
fi
for grub_package in $(rpm -qa 'grub2*' 2>/dev/null | sort); do
    report_info "package: ${grub_package}"
done

# ---------------------------------------------------------------------------
# 1. /etc/grub.d snippets: who owns them, which grub2-mkconfig runs, which
#    read a boot flag
#
# grub2-mkconfig runs every executable file here except *.rpmsave, *.rpmnew,
# *~ and README*.  A leftover *.rpmorig is therefore run too.  Ownership alone
# is not a failure; a snippet from outside grub2 that reads a boot flag is.
# ---------------------------------------------------------------------------
printf '== 1. /etc/grub.d snippets\n'
for snippet_file in "${GRUB_SNIPPET_DIRECTORY}"/*; do
    [[ -f "${snippet_file}" ]] || continue
    snippet_name="${snippet_file##*/}"
    owning_package=$(rpm -qf "${snippet_file#"${VERIFY_ROOT}"}" --qf '%{NAME}' 2>/dev/null) || owning_package=""
    case "${snippet_name}" in
        *.rpmsave|*.rpmnew|*~|README*) mkconfig_runs_it=no ;;
        *) if has_execute_bit "${snippet_file}"; then mkconfig_runs_it=yes; else mkconfig_runs_it=no; fi ;;
    esac
    snippet_reads_flag=no
    grep -Eq "${BOOT_FLAG_PATTERN}" "${snippet_file}" && snippet_reads_flag=yes
    if [[ "${owning_package}" != grub2* ]]; then
        if [[ "${snippet_reads_flag}" == "yes" && "${mkconfig_runs_it}" == "yes" ]]; then
            report_fail "${snippet_name}: not from grub2 (${owning_package:-no package}), run by grub2-mkconfig, reads a boot flag - read it"
        else
            report_info "${snippet_name}: not from grub2 (${owning_package:-no package}); run by grub2-mkconfig: ${mkconfig_runs_it}; reads a boot flag: ${snippet_reads_flag}"
        fi
    fi
    if [[ "${snippet_reads_flag}" == "yes" ]]; then
        report_info "${snippet_name} (${owning_package:-unowned}) reads: $(grep -Eo "${BOOT_FLAG_PATTERN}" "${snippet_file}" | sort -u | paste -sd, -)"
    fi
done

# ---------------------------------------------------------------------------
# 2. Generated config: any section that reads a flag AND selects an entry
#
# grub2-mkconfig wraps each snippet's output in "### BEGIN /etc/grub.d/NAME"
# markers, so every statement is attributed to the snippet that produced it.
# ---------------------------------------------------------------------------
printf '== 2. generated grub.cfg\n'
# check_grub_config FILE -> one "section<TAB>reads_flag<TAB>selects_entry" row
# per section; text before the first marker is section "(top)".
check_grub_config() {
    awk -v flag_pattern="${BOOT_FLAG_PATTERN}" -v selection_pattern="${ENTRY_SELECTION_PATTERN}" '
        BEGIN { section = "(top)"; order[++count] = section }
        /^### BEGIN / {
            section = $3; sub(/.*\//, "", section)
            if (!(section in seen)) { seen[section] = 1; order[++count] = section }
            next
        }
        /^### END / { section = "(top)"; next }
        /^[[:space:]]*#/ { next }
        $0 ~ flag_pattern      { reads_flag[section] = 1 }
        $0 ~ selection_pattern { selects_entry[section] = 1 }
        END {
            for (i = 1; i <= count; i++) {
                s = order[i]
                printf "%s\t%d\t%d\n", s, reads_flag[s] + 0, selects_entry[s] + 0
            }
        }
    ' "$1"
}

# Which snippets the generated config was built from.  A snippet with no
# section in grub.cfg was added after the last grub2-mkconfig, or does not
# produce any output; either way GRUB is not running it today.
if [[ -r "${GRUB_CONFIG_FILE}" ]]; then
    for snippet_file in "${GRUB_SNIPPET_DIRECTORY}"/*; do
        [[ -f "${snippet_file}" ]] || continue
        has_execute_bit "${snippet_file}" || continue
        snippet_name="${snippet_file##*/}"
        if grep -qF "### BEGIN /etc/grub.d/${snippet_name} ###" "${GRUB_CONFIG_FILE}"; then
            report_info "grub.cfg has a section from ${snippet_name}"
        else
            report_info "grub.cfg has no section from ${snippet_name} - not in effect until grub2-mkconfig runs"
        fi
    done
fi

grub_config_files=("${GRUB_CONFIG_FILE}")
for efi_config_file in "${EFI_DIRECTORY}"/*/grub.cfg; do
    [[ -f "${efi_config_file}" ]] && grub_config_files+=("${efi_config_file}")
done

for grub_config_file in "${grub_config_files[@]}"; do
    if [[ ! -r "${grub_config_file}" ]]; then
        [[ "${grub_config_file}" == "${GRUB_CONFIG_FILE}" ]] \
            && report_fail "${grub_config_file#"${VERIFY_ROOT}"}: missing or unreadable"
        continue
    fi
    display_name="${grub_config_file#"${VERIFY_ROOT}"}"
    while IFS=$'\t' read -r section_name reads_flag selects_entry; do
        if [[ "${reads_flag}" -eq 1 && "${selects_entry}" -eq 1 ]]; then
            if [[ "${section_name}" == "${FALLBACK_COUNTING_SNIPPET}" ]] \
               && grep -qF "${FALLBACK_COUNTING_GUARD}" "${grub_config_file}"; then
                report_info "${display_name} [${section_name}]: selects an entry only while boot_counter is set (checked in 4)"
            else
                report_fail "${display_name} [${section_name}]: reads a boot flag and selects an entry"
            fi
        elif [[ "${reads_flag}" -eq 1 ]]; then
            report_info "${display_name} [${section_name}]: reads a boot flag, selects no entry"
        fi
    done < <(check_grub_config "${grub_config_file}")
    report_pass "${display_name}: scanned"
done

# ---------------------------------------------------------------------------
# 3. Compiled code: GRUB EFI images and modules
#
# A config snippet is not the only way to read grubenv; a distribution patch
# to GRUB itself could.  Neither flag name should appear in any GRUB binary.
# ---------------------------------------------------------------------------
printf '== 3. GRUB binaries\n'
binary_found=0
for grub_binary in "${EFI_DIRECTORY}"/*/*.efi "${GRUB_MODULE_DIRECTORY}"/*/*.mod "${GRUB_MODULE_DIRECTORY}"/*/*.efi; do
    [[ -f "${grub_binary}" ]] || continue
    binary_found=1
    if grep -aqE 'boot_success|boot_indeterminate' "${grub_binary}"; then
        report_fail "${grub_binary#"${VERIFY_ROOT}"}: contains a boot flag name - GRUB code may act on it"
    fi
done
if [[ "${binary_found}" -eq 1 ]]; then
    report_pass "GRUB EFI images and modules scanned"
else
    report_fail "no GRUB EFI image or module found under /boot/efi/EFI or /usr/lib/grub"
fi

# ---------------------------------------------------------------------------
# 4. grubenv: what would arm a flag-driven branch
# ---------------------------------------------------------------------------
printf '== 4. grubenv\n'
if [[ -r "${GRUB_ENVIRONMENT_FILE}" ]]; then
    report_info "grubenv: $(grep -E '^[a-z_]+=' "${GRUB_ENVIRONMENT_FILE}" | paste -sd' ' -)"
    if grep -q '^boot_counter=' "${GRUB_ENVIRONMENT_FILE}"; then
        report_fail "boot_counter is set: fallback counting is armed, and setting boot_success would disarm it"
    else
        report_pass "boot_counter unset: 08_fallback_counting never selects an entry"
    fi
    if grep -q '^menu_auto_hide=' "${GRUB_ENVIRONMENT_FILE}"; then
        report_info "menu_auto_hide is set: boot_success only decides whether the menu is hidden"
    fi
else
    report_fail "${GRUB_ENVIRONMENT_FILE#"${VERIFY_ROOT}"}: missing or unreadable"
fi

# ---------------------------------------------------------------------------
# 5. What advances saved_entry on a kernel update
# ---------------------------------------------------------------------------
printf '== 5. kernel-install\n'
if [[ -r "${KERNEL_INSTALL_GRUB_PLUGIN}" ]]; then
    # EL9's version also compares DEFAULTKERNEL with the installed package;
    # EL8's gates on GRUB_UPDATE_DEFAULT_KERNEL alone.
    if grep -q 'GRUB_UPDATE_DEFAULT_KERNEL' "${KERNEL_INSTALL_GRUB_PLUGIN}"; then
        report_pass "20-grub.install advances the default on GRUB_UPDATE_DEFAULT_KERNEL"
    else
        report_fail "20-grub.install does not read GRUB_UPDATE_DEFAULT_KERNEL - read it"
    fi
    if grep -q 'DEFAULTKERNEL' "${KERNEL_INSTALL_GRUB_PLUGIN}"; then
        report_info "20-grub.install also reads DEFAULTKERNEL"
    else
        report_info "20-grub.install does not read DEFAULTKERNEL"
    fi
    if grep -Eq 'boot_success|boot_indeterminate' "${KERNEL_INSTALL_GRUB_PLUGIN}"; then
        report_fail "20-grub.install reads a boot flag - read it"
    fi
else
    report_fail "${KERNEL_INSTALL_GRUB_PLUGIN#"${VERIFY_ROOT}"}: missing"
fi
report_info "DEFAULTKERNEL: $(grep -E '^DEFAULTKERNEL=' "${VERIFY_ROOT}/etc/sysconfig/kernel" 2>/dev/null || printf 'unset')"
report_info "GRUB_UPDATE_DEFAULT_KERNEL: $(grep -E '^GRUB_UPDATE_DEFAULT_KERNEL=' "${VERIFY_ROOT}/etc/default/grub" 2>/dev/null || printf 'unset')"
report_info "grubby default: $(grubby --default-kernel 2>/dev/null || printf 'unreadable')"

printf '\n'
if [[ "${FAILURE_COUNT}" -eq 0 ]]; then
    printf 'VERDICT: no FAIL - boot_success/boot_indeterminate do not select the boot entry on this host.\n'
    exit 0
fi
printf 'VERDICT: %s FAIL - a boot flag may select the boot entry on this host; read each FAIL line.\n' "${FAILURE_COUNT}"
exit 1
