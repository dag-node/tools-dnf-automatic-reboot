#!/bin/bash
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
#   2  Tool error (needs-restarting failed unexpectedly); treated as
#      "no reboot" to avoid a reboot loop on tool failure.
#
# Configuration is read from /etc/dnf/automatic-reboot.conf.
# ---------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

readonly CONF=/etc/dnf/automatic-reboot.conf
readonly LOG=/var/log/dnf-automatic-reboot.log
readonly SELF=needs-reboot
readonly HISTORY_FILE=/var/lib/dnf-automatic-reboot/restart-state

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    printf '<6>%s: %s\n' "${SELF}" "$*"
    printf '%s %s: %s\n' "$(date -Iseconds)" "${SELF}" "$*" >> "${LOG}" 2>/dev/null || true
}
log_warn() {
    printf '<4>%s: %s\n' "${SELF}" "$*"
    printf '%s %s: WARNING: %s\n' "$(date -Iseconds)" "${SELF}" "$*" >> "${LOG}" 2>/dev/null || true
}
log_err() {
    printf '<3>%s: %s\n' "${SELF}" "$*"
    printf '%s %s: ERROR: %s\n' "$(date -Iseconds)" "${SELF}" "$*" >> "${LOG}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------
# conf_get KEY DEFAULT
# Reads a key from the [false_positives] or any section; returns DEFAULT
# when the key is absent.
conf_get() {
    local key="$1" default="$2" val
    val=$(grep -E "^\s*${key}\s*=" "${CONF}" 2>/dev/null \
          | tail -1 | sed 's/^[^=]*=\s*//' | sed 's/\s*#.*//') || true
    printf '%s' "${val:-${default}}"
}

# write_state_entry PKG EVR BOOT_ID STATE
# Replaces PKG's row in HISTORY_FILE (one row per package - a new EVR
# supersedes the old row rather than accumulating history) via atomic
# temp-file rename, safe against a concurrent watchdog-triggered run.
# Failure is silent and non-fatal: the package is re-evaluated fresh next run.
write_state_entry() {
    local pkg="$1" evr="$2" boot="$3" state="$4" tmp
    mkdir -p "$(dirname "${HISTORY_FILE}")" 2>/dev/null || true
    tmp=$(mktemp "${HISTORY_FILE}.XXXXXX" 2>/dev/null) || return 0
    { grep -vE "^${pkg}"$'\t' "${HISTORY_FILE}" 2>/dev/null || true
      printf '%s\t%s\t%s\t%s\t%s\n' "${pkg}" "${evr}" "${boot}" "$(date +%s)" "${state}"
    } > "${tmp}" 2>/dev/null || { rm -f "${tmp}"; return 0; }
    mv -f "${tmp}" "${HISTORY_FILE}" 2>/dev/null || rm -f "${tmp}"
}

# ---------------------------------------------------------------------------
# Read config
# ---------------------------------------------------------------------------
FILTER_PACKAGES=$(conf_get filter_packages "kernel-uek,kernel-uek-core")
VERIFY_KERNEL=$(conf_get verify_kernel_version "yes")
WALL_MESSAGES=$(conf_get wall_messages "yes")
LEARN_FALSE_POSITIVES=$(conf_get learn_false_positives "yes")

# ---------------------------------------------------------------------------
# Run needs-restarting with a hard timeout
# ---------------------------------------------------------------------------
raw=""
nr_exit=0
raw=$(timeout 30s needs-restarting -r 2>&1) || nr_exit=$?

if [[ "${nr_exit}" -eq 0 ]]; then
    log "needs-restarting: no reboot needed"
    exit 0
fi

if [[ "${nr_exit}" -gt 1 ]]; then
    # Anything above 1 is a tool-level failure (missing binary, timeout, etc.)
    log_warn "needs-restarting exited ${nr_exit} - treating as no reboot needed"
    exit 2
fi

# nr_exit == 1: reboot flagged; now filter false positives
flagged=$(echo "${raw}" | grep -E "^\s*\*\s*" | sed 's/^\s*\*\s*//' | paste -sd ',' -) || true
log "Packages flagged by needs-restarting: ${flagged}"

# ---------------------------------------------------------------------------
# Build the filtered output by removing known false-positive package lines.
# needs-restarting -r prints one package name per line in the section
# "Core libraries or services have been updated since boot-up:".
# ---------------------------------------------------------------------------
filtered="${raw}"

# Save and restore IFS around the comma-split so the global \n\t setting
# is not silently clobbered for the rest of the script.
OLD_IFS="${IFS}"
IFS=',' read -ra FP_LIST <<< "${FILTER_PACKAGES}"
IFS="${OLD_IFS}"
for pkg in "${FP_LIST[@]}"; do
    pkg=$(echo "${pkg}" | tr -d ' ')
    [[ -z "${pkg}" ]] && continue
    filtered=$(echo "${filtered}" | grep -v -E "^\s*(\*\s*)?${pkg}\s*$") || true
done

# ---------------------------------------------------------------------------
# Kernel cross-verification (aarch64 and x86_64)
# For every kernel* package in filter_packages that was flagged, confirm it
# is a genuine false positive by comparing uname -r against the highest
# installed RPM EVR.  The trailing .<arch> suffix is stripped using the live
# value of uname -m, so the same logic covers kernel-uek/kernel-uek-core on
# aarch64 and kernel/kernel-core on x86_64.  Packages not installed on this
# system are skipped automatically.
# ---------------------------------------------------------------------------
if [[ "${VERIFY_KERNEL}" == "yes" ]]; then
    running=$(uname -r)
    arch=$(uname -m)
    for pkg in "${FP_LIST[@]}"; do
        pkg=$(echo "${pkg}" | tr -d ' ')
        [[ -z "${pkg}" ]] && continue
        [[ "${pkg}" == kernel* ]] || continue
        # Only cross-verify packages that were actually flagged
        echo "${raw}" | grep -qE "^\s*(\*\s*)?${pkg}\s*$" || continue
        highest=""
        highest=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' "${pkg}" 2>/dev/null \
                  | sort -V | tail -1) || true
        [[ -z "${highest}" ]] && continue
        # Strip the trailing .<arch> suffix so the RPM EVR matches uname -r format
        highest_norm="${highest%.${arch}}"
        if echo "${running}" | grep -qF "${highest_norm}"; then
            log "${pkg} false positive: running kernel matches installed RPM (${running})"
        else
            log "${pkg} genuine: running=${running} installed=${highest}"
            pkg_lines=$(echo "${raw}" | grep -E "^\s*(\*\s*)?${pkg}\s*$") || true
            [[ -n "${pkg_lines}" ]] && filtered="${filtered}"$'\n'"${pkg_lines}"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Build-id cross-verification for filtered non-kernel packages.
# For each package removed from the trigger list, confirm it is a genuine
# false positive by comparing the ELF build-id of its running process
# against the installed binary on disk.  If build-ids differ the package
# is a genuine update and is re-added to filtered.
# ---------------------------------------------------------------------------

# verify_buildid PKG
# Walks /proc/*/exe to find a running process whose binary is owned by PKG,
# then compares ELF build-ids between that process and the on-disk binary.
# Returns: 0=false positive confirmed  1=cannot verify  2=genuine update
verify_buildid() {
    local pkg="$1"
    local link target owner proc_exe="" disk_bin=""
    local running_buildid="" disk_buildid=""

    for link in /proc/[0-9]*/exe; do
        target=$(readlink "${link}" 2>/dev/null) || continue
        target="${target% (deleted)}"
        [[ -f "${target}" ]] || continue
        owner=$(rpm -qf "${target}" --qf '%{NAME}' 2>/dev/null) || continue
        if [[ "${owner}" == "${pkg}" ]]; then
            proc_exe="${link}"
            disk_bin="${target}"
            break
        fi
    done

    if [[ -z "${proc_exe}" ]]; then
        log_warn "${pkg}: no running process found, skipping build-id check"
        return 1
    fi

    running_buildid=$(eu-readelf -n "${proc_exe}" 2>/dev/null \
        | grep 'Build ID' | awk '{print $NF}') || true
    disk_buildid=$(eu-readelf -n "${disk_bin}" 2>/dev/null \
        | grep 'Build ID' | awk '{print $NF}') || true

    if [[ -z "${running_buildid}" || -z "${disk_buildid}" ]]; then
        log_warn "${pkg}: could not read build-ids"
        return 1
    fi

    if [[ "${running_buildid}" == "${disk_buildid}" ]]; then
        log "${pkg} false positive: build-id matches running process"
        return 0
    else
        log "${pkg} genuine: build-id mismatch"
        return 2
    fi
}

if ! command -v eu-readelf &>/dev/null; then
    log_err "eu-readelf unavailable - elfutils is required"
    exit 2
fi

for pkg in "${FP_LIST[@]}"; do
    pkg=$(echo "${pkg}" | tr -d ' ')
    [[ -z "${pkg}" ]] && continue
    # Kernel packages use version-string cross-check above, not build-id
    [[ "${pkg}" == kernel* ]] && continue
    # Only process packages that were actually flagged by needs-restarting
    echo "${raw}" | grep -qE "^\s*(\*\s*)?${pkg}\s*$" || continue
    buildid_result=0
    verify_buildid "${pkg}" || buildid_result=$?
    if [[ "${buildid_result}" -eq 2 ]]; then
        pkg_lines=$(echo "${raw}" | grep -E "^\s*(\*\s*)?${pkg}\s*$") || true
        [[ -n "${pkg_lines}" ]] && filtered="${filtered}"$'\n'"${pkg_lines}"
    fi
done

real=$(echo "${filtered}" \
       | grep -E "^\s*(\*\s*)?\S" \
       | grep -v 'Core libraries\|updated since boot\|Reboot is required\|More information') || true

# ---------------------------------------------------------------------------
# Restart-state learning (any package still in `real`, excluding kernel*,
# which keeps the version-string check above as sole authority).
#
# A package's restart-state is keyed on its exact installed EVR and reaches
# "confirmed" only after surviving a real reboot still flagged at that same
# EVR: /proc/sys/kernel/random/boot_id tells "a reboot happened since this
# package was first flagged" apart from "no reboot yet" without wall-clock
# timestamps, so this check is immune to the boot-time skew that produces
# the underlying false positive. A new EVR always starts a fresh, unverified
# cycle, so a genuine future update is never masked by an old confirmation.
# Confirmed packages are skipped without a reboot; everything else - first
# observation of a package/EVR pair included - stays in `real`, since one
# reboot is the minimum needed to prove a flag spurious.
# ---------------------------------------------------------------------------
if [[ "${LEARN_FALSE_POSITIVES}" == "yes" && -n "${real}" ]]; then
    boot_id=""
    boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) || true
    if [[ -n "${boot_id}" ]]; then
        learned=""
        while IFS= read -r line; do
            [[ -z "${line}" ]] && continue
            pkg=$(echo "${line}" | sed 's/^\s*\*\s*//' | tr -d ' \t')
            [[ -z "${pkg}" ]] && continue

            if [[ "${pkg}" == kernel* ]]; then
                learned="${learned}"$'\n'"${line}"
                continue
            fi

            evr=""
            evr=$(rpm -q --qf '%{EVR}' "${pkg}" 2>/dev/null) || true
            if [[ -z "${evr}" ]]; then
                learned="${learned}"$'\n'"${line}"
                continue
            fi

            entry=""
            entry=$(grep -E "^${pkg}"$'\t' "${HISTORY_FILE}" 2>/dev/null | tail -1) || true

            if [[ -n "${entry}" ]]; then
                h_evr=$(echo "${entry}" | cut -f2)
                h_boot=$(echo "${entry}" | cut -f3)
                h_state=$(echo "${entry}" | cut -f5)

                if [[ "${h_evr}" == "${evr}" && "${h_state}" == "confirmed" ]]; then
                    log "${pkg} restart-state confirmed false positive (evr=${evr}) - skipping"
                    continue
                fi

                if [[ "${h_evr}" == "${evr}" && "${h_state}" == "pending" && "${h_boot}" != "${boot_id}" ]]; then
                    log "${pkg} still flagged at evr=${evr} after a reboot - confirming false positive"
                    write_state_entry "${pkg}" "${evr}" "${boot_id}" confirmed
                    continue
                fi

                if [[ "${h_evr}" != "${evr}" ]]; then
                    log "${pkg}: evr ${evr} supersedes tracked ${h_evr} - treating as a fresh restart requirement"
                fi
            fi

            write_state_entry "${pkg}" "${evr}" "${boot_id}" pending
            learned="${learned}"$'\n'"${line}"
        done <<< "${real}"
        real="${learned#$'\n'}"
    fi
fi

# ---------------------------------------------------------------------------
# Final decision
# ---------------------------------------------------------------------------
if [[ -z "${real}" ]]; then
    log "All triggers filtered as false positives - no reboot needed"
    exit 0
fi

real_list=$(echo "${real}" | sed 's/^\s*\*\s*//' | paste -sd ',' -) || true
log "Reboot needed: ${real_list}"
exit 1
