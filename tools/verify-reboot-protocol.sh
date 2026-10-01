#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# verify-reboot-protocol.sh
# ---------------------------------------------------------------------------
# Host check, run as root, of the systemd behaviour the reboot request and
# cancellation protocol (scripts/reboot-request.sh) relies on.  It runs the
# package's own readers against real systemd, so EL8 and EL9 outputs can be
# compared line by line.
#
# Each line is PASS, FAIL or INFO and is tagged with the protocol part that
# depends on it:
#   PASS  the protocol as written holds on this host
#   FAIL  the protocol as written breaks on this host
#   INFO  a value to compare between hosts, or a case this probe cannot reach
#
# It never reboots and never touches the package's markers or lock.  It
# starts transient units named dnf-automatic-reboot-probe-*, which run
# /bin/true or sleep, and stops and resets them on exit.  The one fact it
# cannot reach without a shutdown, logind's PreparingForShutdown under a
# delay inhibitor, is reported as INFO.
#
#   `sudo bash verify-reboot-protocol.sh > "$(hostname -s)-reboot-protocol.txt" 2>&1`
# ---------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

export LC_ALL=C

readonly PROBE_PREFIX=dnf-automatic-reboot-probe
readonly PROBE_BLOCKER_UNIT="${PROBE_PREFIX}-blocker"
readonly PROBE_TIMER_UNIT="${PROBE_PREFIX}-timer"
readonly PROBE_QUEUED_UNIT="${PROBE_PREFIX}-queued"
readonly PROBE_LATE_UNIT="${PROBE_PREFIX}-late"
readonly PROBE_NOW_UNIT="${PROBE_PREFIX}-now"
readonly PROBE_ELAPSED_UNIT="${PROBE_PREFIX}-elapsed"
readonly PROBE_MISSING_UNIT="${PROBE_PREFIX}-does-not-exist.service"
readonly INSTALLED_LIBRARY=/usr/libexec/dnf-automatic-reboot/reboot-request.sh
readonly LOCK_FILE=/run/dnf-automatic-reboot.reboot-request.lock
readonly MAIN_UNIT=dnf-automatic-reboot.service

FAILURE_COUNT=0

report_pass() { printf 'PASS  [%s] %s\n' "$1" "$2"; }
report_info() { printf 'INFO  [%s] %s\n' "$1" "$2"; }
report_fail() { printf 'FAIL  [%s] %s\n' "$1" "$2"; FAILURE_COUNT=$(( FAILURE_COUNT + 1 )); }

# The library's readers resolve these; it is sourced, never executed.
# shellcheck disable=SC2034  # read by reboot-request.sh
readonly TEST_ROOT=""
# shellcheck disable=SC2034  # read by reboot-request.sh
readonly SYSTEMCTL_BIN=/usr/bin/systemctl
# shellcheck disable=SC2034  # read by reboot-request.sh
readonly SYSTEMD_RUN_BIN=/usr/bin/systemd-run
log()         { report_info library "$*"; }
log_warning() { report_info library "WARNING: $*"; }
log_error()   { report_info library "ERROR: $*"; }

# probe_units -> every unit of this probe, timers and services.
probe_units() {
    printf '%s\n' "${PROBE_TIMER_UNIT}.timer" "${PROBE_LATE_UNIT}.timer" \
        "${PROBE_TIMER_UNIT}.service" "${PROBE_LATE_UNIT}.service" "${PROBE_QUEUED_UNIT}.service" \
        "${PROBE_BLOCKER_UNIT}.service" "${PROBE_NOW_UNIT}.service" \
        "${PROBE_ELAPSED_UNIT}.timer" "${PROBE_ELAPSED_UNIT}.service"
}

remove_probe_units() {
    local probe_unit
    while IFS= read -r probe_unit; do
        systemctl stop "${probe_unit}" >/dev/null 2>&1 || true
        systemctl reset-failed "${probe_unit}" >/dev/null 2>&1 || true
    done < <(probe_units)
}

# snapshot UNIT -> read_unit_snapshot's "LOAD ACTIVE SUB JOB", or "unreadable".
snapshot() {
    read_unit_snapshot "$1" || printf 'unreadable'
}

# expect_snapshot AREA UNIT PATTERN DESCRIPTION - PASS when the snapshot
# matches the extended regex PATTERN (tabs written as \t).
expect_snapshot() {
    local area="$1" unit="$2" pattern="$3" description="$4" unit_snapshot
    unit_snapshot=$(snapshot "${unit}")
    if [[ "${unit_snapshot}" =~ ${pattern} ]]; then
        report_pass "${area}" "${description}: ${unit_snapshot//$'\t'/ }"
    else
        report_fail "${area}" "${description}: got '${unit_snapshot//$'\t'/ }'"
        report_info "${area}" "raw: $(systemctl show --property=LoadState,ActiveState,SubState,Job "${unit}" 2>&1 | paste -sd' ' -)"
    fi
}

if [[ "${EUID}" -ne 0 ]]; then
    printf 'ERROR: run as root; the probe starts transient units.\n' >&2
    exit 2
fi

library_file="$(dirname "${BASH_SOURCE[0]}")/../scripts/reboot-request.sh"
[[ -f "${library_file}" ]] || library_file="${INSTALLED_LIBRARY}"
if [[ ! -f "${library_file}" ]]; then
    printf 'ERROR: reboot-request.sh found neither beside this tool nor at %s\n' "${INSTALLED_LIBRARY}" >&2
    exit 2
fi
# shellcheck source=/dev/null
source "${library_file}"

trap remove_probe_units EXIT
remove_probe_units

# ---------------------------------------------------------------------------
printf '== platform\n'
# ---------------------------------------------------------------------------
report_info platform "os: $(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release)"
report_info platform "$(systemctl --version | head -n 1)"
report_info platform "library: ${library_file}"
if bash -c 'set -u; empty_options=(); printf "%s" "${empty_options[@]}"' >/dev/null 2>&1; then
    report_pass start_reboot_unit "bash ${BASH_VERSION} expands an empty array under set -u (delay 0 has no timer options)"
else
    report_fail start_reboot_unit "bash ${BASH_VERSION} fails on an empty array under set -u"
fi
report_info lock "$(flock --version 2>&1 | head -n 1)"
# The invocations acquire_reboot_request_lock uses, on a scratch file: -n and
# -w on a free lock succeed; held by another process, -n fails at once and
# -w 1 gives up after about a second.
scratch_lock_file=$(mktemp)
exec {scratch_lock_descriptor}>>"${scratch_lock_file}"
if flock -n "${scratch_lock_descriptor}" && flock -u "${scratch_lock_descriptor}" \
   && flock -w 1 "${scratch_lock_descriptor}" && flock -u "${scratch_lock_descriptor}"; then
    report_pass lock "flock -n and flock -w acquire a free lock"
else
    report_fail lock "flock -n or flock -w failed on a free lock"
fi
flock "${scratch_lock_descriptor}"
if flock -n "${scratch_lock_file}" true 2>/dev/null; then
    report_fail lock "flock -n acquired a lock another process holds"
else
    report_pass lock "flock -n refuses a held lock"
fi
wait_started_seconds=${SECONDS}
if flock -w 1 "${scratch_lock_file}" true 2>/dev/null; then
    report_fail lock "flock -w 1 acquired a lock another process holds"
else
    report_pass lock "flock -w 1 gives up on a held lock after $(( SECONDS - wait_started_seconds ))s"
fi
exec {scratch_lock_descriptor}>&-
rm -f "${scratch_lock_file}"

# ---------------------------------------------------------------------------
printf '== systemctl show format\n'
# ---------------------------------------------------------------------------
report_info read_unit_snapshot "raw, unknown unit: $(systemctl show --property=LoadState,ActiveState,SubState,Job "${PROBE_MISSING_UNIT}" 2>&1 | paste -sd' ' -)"
expect_snapshot read_unit_snapshot "${PROBE_MISSING_UNIT}" $'^not-found\tinactive\tdead\t0$' \
    "an unknown unit is not-found, inactive, no job"

# ---------------------------------------------------------------------------
printf '== transient timer\n'
# ---------------------------------------------------------------------------
if systemd-run --quiet --unit="${PROBE_TIMER_UNIT}" --on-active=600 --timer-property=AccuracySec=1s \
       /bin/true >/dev/null 2>&1; then
    expect_snapshot read_scheduled_reboot_status "${PROBE_TIMER_UNIT}.timer" $'^loaded\tactive\twaiting\t0$' \
        "a timer that has not fired is SubState=waiting"
    expect_snapshot read_scheduled_reboot_status "${PROBE_TIMER_UNIT}.service" $'^(loaded|not-found)\tinactive\tdead\t0$' \
        "its service is inactive with no job"
    report_info read_scheduled_reboot_status "timer RemainAfterElapse=$(systemctl show --property=RemainAfterElapse --value "${PROBE_TIMER_UNIT}.timer" 2>&1)"
    if stop_unit "${PROBE_TIMER_UNIT}.timer"; then
        expect_snapshot cancel-reboot.sh "${PROBE_TIMER_UNIT}.timer" $'^(not-found\tinactive\tdead|loaded\tinactive\tdead)\t0$' \
            "a stopped timer is gone or dead"
    else
        report_fail cancel-reboot.sh "systemctl stop ${PROBE_TIMER_UNIT}.timer failed"
    fi
else
    report_fail start_reboot_unit "systemd-run --on-active=600 failed"
fi

# ---------------------------------------------------------------------------
printf '== elapsed timer\n'
# ---------------------------------------------------------------------------
if systemd-run --quiet --unit="${PROBE_ELAPSED_UNIT}" --on-active=1 --timer-property=AccuracySec=1s \
       /bin/true >/dev/null 2>&1; then
    sleep 4
    report_info read_scheduled_reboot_status "after firing, timer: $(snapshot "${PROBE_ELAPSED_UNIT}.timer" | tr '\t' ' '), service: $(snapshot "${PROBE_ELAPSED_UNIT}.service" | tr '\t' ' ')"
    expect_snapshot read_scheduled_reboot_status "${PROBE_ELAPSED_UNIT}.timer" $'^(not-found\tinactive\tdead|loaded\t[a-z]+\t(elapsed|dead))\t0$' \
        "a fired timer is gone, elapsed or dead, never waiting"
    stop_unit "${PROBE_ELAPSED_UNIT}.timer" || true
    systemctl reset-failed "${PROBE_ELAPSED_UNIT}.timer" "${PROBE_ELAPSED_UNIT}.service" >/dev/null 2>&1 || true
else
    report_fail start_reboot_unit "systemd-run --on-active=1 failed"
fi

# ---------------------------------------------------------------------------
printf '== immediate unit (delay 0)\n'
# ---------------------------------------------------------------------------
if systemd-run --quiet --unit="${PROBE_NOW_UNIT}" /bin/true >/dev/null 2>&1; then
    sleep 2
    expect_snapshot start_reboot_unit "${PROBE_NOW_UNIT}.service" $'^(not-found|loaded)\tinactive\tdead\t0$' \
        "systemd-run without --on-active ran the command at once and the unit is done"
else
    report_fail start_reboot_unit "systemd-run without --on-active failed"
fi

# ---------------------------------------------------------------------------
printf '== queued job\n'
# ---------------------------------------------------------------------------
# A service ordered after a running oneshot waits with a start job queued:
# the state a timer leaves when it fires behind an ordering dependency.
if systemd-run --quiet --no-block --unit="${PROBE_BLOCKER_UNIT}" --property=Type=oneshot \
       /bin/sleep 30 >/dev/null 2>&1; then
    sleep 1
    if systemd-run --quiet --no-block --unit="${PROBE_QUEUED_UNIT}" \
           --property="After=${PROBE_BLOCKER_UNIT}.service" /bin/true >/dev/null 2>&1; then
        sleep 1
        report_info read_unit_snapshot "raw, queued: $(systemctl show --property=LoadState,ActiveState,SubState,Job "${PROBE_QUEUED_UNIT}.service" 2>&1 | paste -sd' ' -)"
        expect_snapshot read_scheduled_reboot_status "${PROBE_QUEUED_UNIT}.service" $'^loaded\tinactive\tdead\t[1-9][0-9]*$' \
            "a queued start shows a numeric Job while the unit is still inactive"
    else
        report_info read_scheduled_reboot_status "systemd-run --property=After= is not accepted here; queued-job case not reached"
    fi
    # The timer variant: it fires, queues its service behind the blocker,
    # and is stopped before the job runs.
    if systemd-run --quiet --unit="${PROBE_LATE_UNIT}" --on-active=1 --timer-property=AccuracySec=1s \
           --property="After=${PROBE_BLOCKER_UNIT}.service" /bin/true >/dev/null 2>&1; then
        sleep 3
        stop_unit "${PROBE_LATE_UNIT}.timer" || true
        expect_snapshot cancel-reboot.sh "${PROBE_LATE_UNIT}.service" $'^loaded\tinactive\tdead\t[1-9][0-9]*$' \
            "stopping a fired timer leaves its queued job; reboot-if-pending.sh must re-check the marker"
    else
        report_info cancel-reboot.sh "timer with --property=After= not accepted here; fired-timer case not reached"
    fi
else
    report_fail read_scheduled_reboot_status "could not start the blocking oneshot"
fi
remove_probe_units

# ---------------------------------------------------------------------------
printf '== host shutdown state\n'
# ---------------------------------------------------------------------------
report_info read_host_shutdown_state "is-system-running: $(get_system_state)"
report_info read_host_shutdown_state "PreparingForShutdown: $(get_logind_preparing_for_shutdown 2>&1 || printf 'unreadable')"
shutdown_state=$(read_host_shutdown_state)
if [[ "${shutdown_state}" == "no" ]]; then
    report_pass read_host_shutdown_state "a running host reads as not shutting down"
else
    report_fail read_host_shutdown_state "a running host reads as '${shutdown_state}'; cancel-reboot.sh would refuse every cancellation"
fi
report_info read_host_shutdown_state "not probed: PreparingForShutdown=true under a delay inhibitor needs a real shutdown"
report_info read_host_shutdown_state "delay inhibitors now: $(systemd-inhibit --list --no-pager 2>/dev/null | awk '$NF == "delay"' | wc -l)"

# ---------------------------------------------------------------------------
printf '== lock\n'
# ---------------------------------------------------------------------------
if [[ -e "${LOCK_FILE}" ]]; then
    lock_attributes=$(stat -c '%a %U:%G' "${LOCK_FILE}")
    if [[ "${lock_attributes}" == "600 root:root" ]]; then
        report_pass lock "${LOCK_FILE} is ${lock_attributes}"
    else
        report_fail lock "${LOCK_FILE} is ${lock_attributes}; a user who can open it can block every reboot request"
    fi
    report_info lock "label: $(stat -c '%C' "${LOCK_FILE}" 2>&1)"
    if runuser -u nobody -- flock -n "${LOCK_FILE}" true >/dev/null 2>&1; then
        report_fail lock "user nobody could open and lock ${LOCK_FILE}"
    else
        report_pass lock "user nobody cannot open ${LOCK_FILE}"
    fi
else
    report_info lock "${LOCK_FILE} absent; systemd-tmpfiles creates it at boot and in %post"
fi

# ---------------------------------------------------------------------------
printf '== installed package\n'
# ---------------------------------------------------------------------------
if [[ -f "${INSTALLED_LIBRARY}" ]]; then
    for installed_file in /usr/libexec/dnf-automatic-reboot/*; do
        report_info package "$(stat -c '%a %U:%G %C %n' "${installed_file}" 2>&1)"
    done
    relabel_lines=$(restorecon -n -v -R /usr/libexec/dnf-automatic-reboot/ 2>&1 || true)
    if [[ -z "${relabel_lines}" ]]; then
        report_pass package "every installed script carries its policy label"
    else
        report_fail package "restorecon would relabel: ${relabel_lines}"
    fi
    for marker_path in /run/dnf-automatic-reboot.recovery /run/dnf-automatic-reboot.reboot-pending; do
        if systemctl cat "${MAIN_UNIT}" 2>/dev/null | grep -qx "ConditionPathExists=!${marker_path}"; then
            report_pass package "${MAIN_UNIT} does not start while ${marker_path} exists"
        else
            report_fail package "${MAIN_UNIT} lacks ConditionPathExists=!${marker_path}"
        fi
    done
    for runtime_file in /run/dnf-automatic-reboot.reboot-pending /run/dnf-automatic-reboot.reboot-dispatched \
                        /run/dnf-automatic-reboot.recovery; do
        if [[ -e "${runtime_file}" ]]; then
            report_info package "present now: ${runtime_file}"
        fi
    done
    report_info package "scheduled reboot status now: $(read_scheduled_reboot_status)"
else
    report_info package "dnf-automatic-reboot is not installed; package checks skipped"
fi

printf '\n%s FAIL\n' "${FAILURE_COUNT}"
[[ "${FAILURE_COUNT}" -eq 0 ]]
