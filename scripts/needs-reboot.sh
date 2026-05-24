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

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    echo "$(date -Iseconds) ${SELF}: $*" | tee -a "${LOG}"
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

# ---------------------------------------------------------------------------
# Read config
# ---------------------------------------------------------------------------
FILTER_PACKAGES=$(conf_get filter_packages "kernel-uek,kernel-uek-core")
VERIFY_KERNEL=$(conf_get verify_kernel_version "yes")
WALL_MESSAGES=$(conf_get wall_messages "yes")

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
    log "needs-restarting exited ${nr_exit} - tool error, treating as no reboot needed"
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
# Kernel cross-verification for aarch64
# Confirm filtered kernel-uek entries are genuinely spurious by comparing
# uname -r against the highest installed RPM EVR.
# ---------------------------------------------------------------------------
if [[ "${VERIFY_KERNEL}" == "yes" && "$(uname -m)" == "aarch64" ]]; then
    running=$(uname -r)
    highest_uek=""
    highest_uek=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-uek 2>/dev/null \
                  | sort -V | tail -1) || true

    if [[ -n "${highest_uek}" ]]; then
        # Normalise: the RPM release tag ends in .aarch64; uname -r may not
        # Include it.  Strip the trailing arch suffix for comparison.
        highest_norm="${highest_uek%.aarch64}"
        if echo "${running}" | grep -qF "${highest_norm}"; then
            log "Running kernel matches installed RPM (${running})"
            # Already removed from filtered above; nothing more to do.
        else
            log "New kernel found, running=${running} installed=${highest_uek}"
            # Re-add kernel-uek lines to filtered so they trigger the reboot.
            kern_lines=$(echo "${raw}" | grep -E "^\s*(\*\s*)?kernel-uek") || true
            if [[ -n "${kern_lines}" ]]; then
                filtered="${filtered}"$'\n'"${kern_lines}"
            fi
        fi
    fi
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
        log "${pkg}: no running process found, skipping build-id check"
        return 1
    fi

    running_buildid=$(eu-readelf -n "${proc_exe}" 2>/dev/null \
        | grep 'Build ID' | awk '{print $NF}') || true
    disk_buildid=$(eu-readelf -n "${disk_bin}" 2>/dev/null \
        | grep 'Build ID' | awk '{print $NF}') || true

    if [[ -z "${running_buildid}" || -z "${disk_buildid}" ]]; then
        log "${pkg}: could not read build-ids"
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
    log "eu-readelf unavailable - elfutils is required"
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

# ---------------------------------------------------------------------------
# Final decision
# ---------------------------------------------------------------------------
real=$(echo "${filtered}" \
       | grep -E "^\s*(\*\s*)?\S" \
       | grep -v 'Core libraries\|updated since boot\|Reboot is required\|More information') || true

if [[ -z "${real}" ]]; then
    log "All triggers filtered as false positives - no reboot needed"
    exit 0
fi

real_list=$(echo "${real}" | sed 's/^\s*\*\s*//' | paste -sd ',' -) || true
log "Reboot needed: ${real_list}"
exit 1
