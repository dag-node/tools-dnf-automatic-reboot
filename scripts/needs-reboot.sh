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
# systemd perpetual-flag detection
# Check whether the systemd flag is caused by PrivateTmp namespace masking
# or a debuginfo build-id mismatch rather than a real update.
# Method: compare the ELF build-id of the running PID 1 binary against
# the build-id embedded in the installed package's binary on disk.
# ---------------------------------------------------------------------------
if echo "${filtered}" | grep -qE "^\s*(\*\s*)?systemd\s*$"; then
    running_buildid=""
    disk_buildid=""

    # eu-readelf is in elfutils; file(1) cannot extract build-ids reliably
    if command -v eu-readelf &>/dev/null; then
        running_buildid=$(eu-readelf -n /proc/1/exe 2>/dev/null \
            | grep 'Build ID' | awk '{print $NF}') || true
        disk_buildid=$(eu-readelf -n /usr/lib/systemd/systemd 2>/dev/null \
            | grep 'Build ID' | awk '{print $NF}') || true
    fi

    if [[ -n "${running_buildid}" && -n "${disk_buildid}" ]]; then
        if [[ "${running_buildid}" == "${disk_buildid}" ]]; then
            log "Skipping systemd, latest version already installed and running"
            filtered=$(echo "${filtered}" | grep -v -E "^\s*(\*\s*)?systemd\s*$") || true
        else
            log "New version of systemd found (running=${running_buildid} disk=${disk_buildid})"
        fi
    else
        log "eu-readelf unavailable - elfutils is required"
        exit 2
    fi
fi

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
