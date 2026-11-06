#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# watchdog.sh
# ---------------------------------------------------------------------------
# Independent watchdog for dnf-automatic-reboot.
# Runs every 5 minutes via dnf-automatic-watchdog.timer, completely
# independent of the main run.sh service unit.
#
# It judges a run by progress alone, never by its age: a run whose processes
# keep reading or writing is left to finish, however long it takes.  It never
# reboots; the next run makes every reboot decision.
#
#  1. No state file     - Nothing is running; exit immediately.
#
#  2. Dead PID          - run.sh crashed uncleanly.  State is unknown.
#                         Clean up lock files, emit a wall warning.
#
#  3. Stalled run       - The run's processes have read and written nothing
#                         for the window of the phase it is in, so its
#                         service cgroup is killed:
#                           PRE_TRANSACTION_STALL_TIMEOUT_MINUTES while it
#                             updates and dnf.log shows rpm's transaction not
#                             yet started: nothing was installed
#                           TRANSACTION_STALL_TIMEOUT_MINUTES while it updates
#                             otherwise: packages may be half-installed, and
#                             the alert names the commands that show what to
#                             repair
#                           REBOOT_CHECK_STALL_TIMEOUT_MINUTES in its reboot
#                             check or service restarts: the updates are in
#                             place, and the next run decides the reboot
#
#  4. Progressing run   - Left alone.
#
# The watchdog reads no settings, so it supervises a run whatever
# /etc/dnf/automatic-reboot.conf holds.  Killing always targets the whole
# service cgroup, never the run.sh PID alone: dnf-automatic runs behind
# systemd-inhibit, so signalling direct children leaves the rpm transaction
# running.
#
# Log: /var/log/dnf-automatic-reboot.log
# ---------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

export LC_ALL=C

# Path prefix, empty in production.  tests/run-tests.sh points it at a
# temporary tree so every path and helper binary below resolves inside it.
readonly TEST_ROOT="${DNF_AUTOMATIC_REBOOT_TEST_ROOT:-}"

# shellcheck disable=SC2034  # read by run-state.sh
readonly STATE_FILE="${TEST_ROOT}/run/dnf-automatic-reboot.state"
readonly LOCK_FILE="${TEST_ROOT}/run/dnf-automatic-reboot.lock"
# Present while the watchdog kills a run; the main unit does not start then.
readonly RECOVERY_FILE="${TEST_ROOT}/run/dnf-automatic-reboot.recovery"
readonly UPTIME_FILE="${TEST_ROOT}/proc/uptime"
readonly LOG_FILE="${TEST_ROOT}/var/log/dnf-automatic-reboot.log"
readonly SYSTEMCTL_BIN="${TEST_ROOT}/usr/bin/systemctl"
readonly MAIN_SERVICE_UNIT=dnf-automatic-reboot.service
readonly SCRIPT_NAME=watchdog
# Where the run's processes and their I/O counters are read.
readonly CGROUP_ROOT="${TEST_ROOT}/sys/fs/cgroup"
readonly PROC_DIRECTORY="${TEST_ROOT}/proc"
readonly DNF_LOG_FILE="${TEST_ROOT}/var/log/dnf.log"
# dnf renames dnf.log to this at log_size (1 MB by default).
readonly DNF_ROTATED_LOG_FILE="${DNF_LOG_FILE}.1"
# The last dnf progress seen for the supervised run; written by the watchdog
# only, replaced when a different run is supervised, emptied by a reboot.
readonly PROGRESS_FILE="${TEST_ROOT}/run/dnf-automatic-reboot.progress"
# What an operator runs after a kill that may have cut an rpm transaction
# short: the interrupted transaction, and the duplicate or broken packages it
# left.
readonly INTERRUPTED_TRANSACTION_CHECK="Check: dnf history info last; dnf check"

# REBOOT_PENDING_FILE, read_scheduled_reboot_status and CANCEL_REBOOT_COMMAND.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/reboot-request.sh"
# read_run_state, run_state_field and remove_run_state_if_unchanged.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/run-state.sh"

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

# send_wall_message TEXT... - broadcasts to logged-in users.
send_wall_message() {
    wall "$*" 2>/dev/null || true
}

# Minutes without progress after which a run is killed, by phase.  Fixed, not
# settings: every wait inside a run that reads and writes nothing, a dnf query
# or a service restart with its kill grace, ends within 20 minutes, after
# which the run starts its next process, which counts as progress.
#   Before rpm's transaction, nothing is installed; the next run finds the
#   downloads in the cache.
readonly PRE_TRANSACTION_STALL_TIMEOUT_MINUTES=60
#   A scriptlet rebuilding SELinux policy, or an initramfs on an SD card, can
#   be quiet for a long time.
readonly TRANSACTION_STALL_TIMEOUT_MINUTES=180
#   The reboot check and the service restarts after it.
readonly REBOOT_CHECK_STALL_TIMEOUT_MINUTES=60

# Seconds the watchdog waits, after killing a stuck run, for systemd to report
# the unit inactive or failed; well inside the unit's TimeoutStartSec.
# Not readonly: tests/run-tests.sh shortens it.
KILL_CONFIRMATION_TIMEOUT_SECONDS=300

# ---------------------------------------------------------------------------
# dnf progress.  A run is stopped only once its own processes have stopped
# reading and writing.  Every other dnf command, dnf-makecache.timer's
# included, writes to dnf's cache and logs too, so neither is a signal of
# this run's progress: the processes in the unit's cgroup are.  librepo writes
# each downloaded chunk to its file as it arrives, and rpm and its scriptlets
# read and write files, so both show in the counters.
# ---------------------------------------------------------------------------

# read_unit_control_group -> the service unit's ControlGroup, empty when systemctl
# does not answer.
read_unit_control_group() {
    "${SYSTEMCTL_BIN}" show --property=ControlGroup --value "${MAIN_SERVICE_UNIT}" 2>/dev/null || true
}

# unit_cgroup_directory -> the unit's cgroup directory in the hierarchy that
# lists its processes: the unified one (cgroup v2), else systemd's named
# hierarchy (cgroup v1), else the unified one of a hybrid mount.  Returns 1
# when none of them has a readable cgroup.procs.
unit_cgroup_directory() {
    local control_group cgroup_directory
    control_group=$(read_unit_control_group)
    [[ "${control_group}" == /?* ]] || return 1
    for cgroup_directory in "${CGROUP_ROOT}${control_group}" "${CGROUP_ROOT}/systemd${control_group}" \
                            "${CGROUP_ROOT}/unified${control_group}"; do
        if [[ -r "${cgroup_directory}/cgroup.procs" ]]; then
            printf '%s' "${cgroup_directory}"
            return 0
        fi
    done
    return 1
}

# read_dnf_progress_signature -> "processes=N read=BYTES written=BYTES": the
# processes in the unit's cgroup and its child cgroups, and the sum of their
# rchar and wchar from /proc/PID/io.  Any difference between two cycles is
# progress, a process starting or exiting included.  A process that exits
# between the listing and the read is left out.  Returns 1 when the cgroup
# cannot be read or lists no process whose counters can be read.
read_dnf_progress_signature() {
    local cgroup_directory process_ids process_id io_counters
    local process_count=0 read_total=0 written_total=0
    cgroup_directory=$(unit_cgroup_directory) || return 1
    process_ids=$(find "${cgroup_directory}" -name cgroup.procs -exec cat {} + 2>/dev/null) || return 1
    while IFS= read -r process_id; do
        [[ "${process_id}" =~ ^[0-9]+$ ]] || continue
        io_counters=$(cat "${PROC_DIRECTORY}/${process_id}/io" 2>/dev/null) || continue
        [[ "${io_counters}" =~ (^|$'\n')rchar:\ ([0-9]+) ]] || continue
        read_total=$(( read_total + BASH_REMATCH[2] ))
        [[ "${io_counters}" =~ (^|$'\n')wchar:\ ([0-9]+) ]] || continue
        written_total=$(( written_total + BASH_REMATCH[2] ))
        process_count=$(( process_count + 1 ))
    done <<< "${process_ids}"
    (( process_count > 0 )) || return 1
    printf 'processes=%d read=%d written=%d' "${process_count}" "${read_total}" "${written_total}"
}

# write_dnf_progress_record RUN_IDENTITY SIGNATURE CHANGED_UPTIME_SECONDS
# Publishes PROGRESS_FILE by rename, so a reader never sees half of it.
write_dnf_progress_record() {
    local temporary_record
    temporary_record=$(mktemp "${PROGRESS_FILE}.XXXXXX" 2>/dev/null) || return 1
    if ! printf 'run=%s\nsignature=%s\nchanged_uptime=%s\n' "$1" "$2" "$3" \
            > "${temporary_record}" 2>/dev/null \
       || ! mv -f -T "${temporary_record}" "${PROGRESS_FILE}" 2>/dev/null; then
        rm -f "${temporary_record}"
        return 1
    fi
}

# update_dnf_progress_record RUN_IDENTITY CURRENT_UPTIME_SECONDS
# Compares the run's progress signature with PROGRESS_FILE and sets
#   DNF_PROGRESS_SIGNATURE  the signature now
#   DNF_STALLED_MINUTES     whole minutes since it last changed
#   DNF_PROGRESS_FAILURE    why the record was not updated, on return 1
# RUN_IDENTITY, "PID START_UPTIME", ties the record to one run: the first
# cycle that sees a run, and every change of signature, counts as progress
# now.  Returns 1 when the signature cannot be read or the record cannot be
# written, since a stall then cannot be told from progress.
update_dnf_progress_record() {
    local run_identity="$1" current_uptime_seconds="$2" record_line
    local recorded_identity="" recorded_signature="" changed_uptime_seconds=""
    if ! DNF_PROGRESS_SIGNATURE=$(read_dnf_progress_signature); then
        DNF_PROGRESS_FAILURE="the I/O counters of ${MAIN_SERVICE_UNIT}'s processes cannot be read"
        return 1
    fi
    if [[ -f "${PROGRESS_FILE}" ]]; then
        while IFS= read -r record_line; do
            case "${record_line}" in
                run=*)            recorded_identity="${record_line#run=}" ;;
                signature=*)      recorded_signature="${record_line#signature=}" ;;
                changed_uptime=*) changed_uptime_seconds="${record_line#changed_uptime=}" ;;
            esac
        done < "${PROGRESS_FILE}"
    fi
    if [[ "${recorded_identity}" != "${run_identity}" || "${recorded_signature}" != "${DNF_PROGRESS_SIGNATURE}" \
          || ! "${changed_uptime_seconds}" =~ ^[0-9]+$ ]]; then
        changed_uptime_seconds="${current_uptime_seconds}"
        if ! write_dnf_progress_record "${run_identity}" "${DNF_PROGRESS_SIGNATURE}" \
                "${changed_uptime_seconds}"; then
            DNF_PROGRESS_FAILURE="${PROGRESS_FILE} cannot be written"
            return 1
        fi
    fi
    DNF_STALLED_MINUTES=$(( (current_uptime_seconds - changed_uptime_seconds) / 60 ))
}

# ---------------------------------------------------------------------------
# dnf's phase within the run, read from dnf.log.  dnf 4's logging setup
# writes "--- logging initialized ---" when dnf-automatic starts; base.py
# writes "Running transaction check", "Transaction check succeeded.",
# "Running transaction test" and "Transaction test succeeded." while rpm only
# checks, and "Running transaction" right before rpm starts changing the
# system.  Each is one line "<timestamp> INFO <message>".  Only those whole
# messages count; every other line is ignored.
#
# run.sh records dnf.log's inode and size before dnf-automatic starts, so
# lines from earlier dnf commands do not count.  Other dnf commands during the
# run add lines too, but rpm's lock keeps their transactions out of the run's,
# and a "Running transaction" of theirs only makes the phase more cautious.
# ---------------------------------------------------------------------------

# read_run_dnf_log INODE OFFSET -> what the dnf.log with INODE gained after
# OFFSET, followed across one rotation.  Returns 1 when that cannot be read:
# no recorded position, the file gone (a second rotation, or log_compress),
# or shorter than OFFSET.
read_run_dnf_log() {
    local recorded_inode="$1" recorded_offset="$2" inode_and_size
    [[ "${recorded_inode}" =~ ^[0-9]+$ && "${recorded_offset}" =~ ^[0-9]+$ ]] || return 1
    inode_and_size=$(stat -c '%i %s' "${DNF_LOG_FILE}" 2>/dev/null) || return 1
    if [[ "${inode_and_size%% *}" == "${recorded_inode}" ]]; then
        (( ${inode_and_size##* } >= recorded_offset )) || return 1
        tail -c "+$(( recorded_offset + 1 ))" "${DNF_LOG_FILE}"
        return
    fi
    inode_and_size=$(stat -c '%i %s' "${DNF_ROTATED_LOG_FILE}" 2>/dev/null) || return 1
    [[ "${inode_and_size%% *}" == "${recorded_inode}" ]] || return 1
    (( ${inode_and_size##* } >= recorded_offset )) || return 1
    tail -c "+$(( recorded_offset + 1 ))" "${DNF_ROTATED_LOG_FILE}"
    cat "${DNF_LOG_FILE}"
}

# read_dnf_run_phase INODE OFFSET -> one of
#   download     dnf-automatic started, no transaction check yet
#   checked      rpm checked the transaction, has not started it
#   transaction  rpm's transaction has started
#   unknown      the log cannot be read, or shows no start of dnf-automatic
#                in a format this parser knows
# Only download and checked prove nothing has been installed; unknown is
# handled as transaction.
read_dnf_run_phase() {
    local run_phase_found=""
    run_phase_found=$(read_run_dnf_log "$1" "$2" | awk '
        {
            message = $0
            if (sub(/^[^ ]+ INFO /, "", message) == 0) next
            if (message == "--- logging initialized ---") started = 1
            else if (message == "Running transaction") transaction = 1
            else if (message == "Running transaction check" || message == "Transaction check succeeded." \
                     || message == "Running transaction test" || message == "Transaction test succeeded.") checked = 1
        }
        END {
            if (transaction) print "transaction"
            else if (!started) print "unknown"
            else if (checked) print "checked"
            else print "download"
        }') || run_phase_found="unknown"
    printf '%s' "${run_phase_found:-unknown}"
}

# dnf_phase_is_before_transaction PHASE - 0 when PHASE proves rpm has not
# started changing the system.
dnf_phase_is_before_transaction() {
    [[ "$1" == "download" || "$1" == "checked" ]]
}

# ---------------------------------------------------------------------------
# Kill the entire service cgroup.
#
# systemd owns the cgroup, so `systemctl kill --kill-whom=all` reaches
# dnf-automatic, the inhibitor helper and every process they started.
# Signalling only the recorded PID (or only its direct children) leaves the
# rpm transaction alive.
# ---------------------------------------------------------------------------

# systemctl_kill_target_option SYSTEMD_VERSION -> the option that makes
# `systemctl kill` signal every process of the unit.  systemd 252 renamed
# `--kill-who` to `--kill-whom`: on the surveyed hosts systemd 239 (EL8)
# accepts only `--kill-who`, and 252 (EL9) accepts either.  A version that
# does not parse gets `--kill-who`, which 239 and 252 accept.
systemctl_kill_target_option() {
    local systemd_version="$1"
    if [[ "${systemd_version}" =~ ^[0-9]+$ && "${systemd_version}" -ge 252 ]]; then
        printf '%s' '--kill-whom=all'
    else
        printf '%s' '--kill-who=all'
    fi
}

# unit_main_pid -> the service unit's MainPID as systemctl reports it, empty
# when systemctl does not answer.
unit_main_pid() {
    "${SYSTEMCTL_BIN}" show --property=MainPID --value "${MAIN_SERVICE_UNIT}" 2>/dev/null || true
}

# check_recorded_pid_identity PID
# Returns: 0 = PID is alive and is the unit's MainPID: the run
#          1 = PID is dead, or MainPID is another process: not the run
#          2 = PID is alive but systemctl show does not print a numeric
#              MainPID: unknown
# run.sh is the unit's ExecStart, so its PID is MainPID while it runs; a live
# PID that differs was reused by an unrelated process after the run died.
check_recorded_pid_identity() {
    local recorded_pid="$1" main_pid
    kill -0 "${recorded_pid}" 2>/dev/null || return 1
    main_pid=$(unit_main_pid)
    [[ "${main_pid}" =~ ^[0-9]+$ ]] || return 2
    [[ "${main_pid}" == "${recorded_pid}" ]] || return 1
    return 0
}

# recorded_run_is_unchanged SNAPSHOT PID
# Returns: 0 = the state file still holds SNAPSHOT and PID is still the unit's
#              MainPID
#          1 = the run ended, or another run replaced it
#          2 = PID is alive but its identity cannot be established
# The run can end, and another start, while the watchdog runs its own check;
# acting on the old decision would kill the new run, possibly mid-transaction.
recorded_run_is_unchanged() {
    local expected_snapshot="$1" expected_pid="$2" current_snapshot
    current_snapshot=$(read_run_state) || return 1
    [[ "${current_snapshot}" == "${expected_snapshot}" ]] || return 1
    check_recorded_pid_identity "${expected_pid}"
}

# remove_inspected_run_state SNAPSHOT - removes the state and lock files of
# the run in SNAPSHOT, only while the state file still holds it.  A run that
# started since keeps both.
remove_inspected_run_state() {
    local removal_result=0
    remove_run_state_if_unchanged "$1" "${LOCK_FILE}" || removal_result=$?
    case "${removal_result}" in
        1) log "the state file changed since it was read - a new run started; its state is kept" ;;
        2) log_error "the state file could not be locked - left alone this cycle" ;;
    esac
    return 0
}

# unit_active_state -> the service unit's ActiveState, empty when systemctl
# does not answer.
unit_active_state() {
    "${SYSTEMCTL_BIN}" show --property=ActiveState --value "${MAIN_SERVICE_UNIT}" 2>/dev/null || true
}

# signal_unit_processes KILL_TARGET_OPTION - SIGKILL to every process of the
# unit's cgroup.
signal_unit_processes() {
    "${SYSTEMCTL_BIN}" kill "$1" --signal=SIGKILL "${MAIN_SERVICE_UNIT}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Recovery marker.
#
# The main unit's ConditionPathExists=! refuses to start while it exists.
# RECOVERY_FILE exists from before the identity re-check until recovery ends:
# no new run can start between the re-check and the kill, while the state file
# is removed; a run started before the file existed shows in the re-check.
# The EXIT trap removes it on every exit, and the unit's ExecStopPost=
# removes it when the watchdog is killed.
# ---------------------------------------------------------------------------
# begin_recovery - creates RECOVERY_FILE, or exits 1 when it cannot.
begin_recovery() {
    if ! : > "${RECOVERY_FILE}" 2>/dev/null; then
        log_error "cannot create ${RECOVERY_FILE} - a new run could start during recovery, recovery abandoned"
        exit 1
    fi
    trap end_recovery EXIT
}

# end_recovery - the EXIT trap: removes RECOVERY_FILE.
end_recovery() {
    rm -f "${RECOVERY_FILE}"
}

# report_reboot_pending_without_reboot
# Returns 0 when no reboot is pending, or when a scheduled reboot is waiting or
# under way; 1 after logging an error when REBOOT_PENDING_FILE exists without
# one.  Called after killing a run in its reboot check: a run killed while it
# requested a reboot leaves the file, and nothing else reports it.
report_reboot_pending_without_reboot() {
    local scheduled_reboot_status
    [[ -e "${REBOOT_PENDING_FILE}" ]] || return 0
    scheduled_reboot_status=$(read_scheduled_reboot_status)
    case "${scheduled_reboot_status}" in
        waiting|in_progress|dispatched)
            log "a reboot is already scheduled or under way: systemctl list-timers ${SCHEDULED_REBOOT_UNIT}.timer"
            return 0
            ;;
    esac
    log_error "${REBOOT_PENDING_FILE} exists but no reboot is scheduled (${scheduled_reboot_status}) - the killed run was requesting one. No update run starts until the host reboots; allow updates again with: ${CANCEL_REBOOT_COMMAND}"
    return 1
}

# kill_service_cgroup SNAPSHOT PID
# Returns: 0 = the recorded run was killed and systemd reports the unit
#              inactive or failed
#          1 = the run ended or was replaced; no process signalled
#          2 = the run's identity cannot be established; no process signalled
#          3 = the kill failed, or the unit was still active
#              KILL_CONFIRMATION_TIMEOUT_SECONDS seconds after it: recovery failed
# Called between begin_recovery and the end of recovery.  The kill targets the
# unit's cgroup only; the recorded PID is never signalled on its own, since by
# then its number may belong to another process.
kill_service_cgroup() {
    local recorded_snapshot="$1" recorded_pid="$2"
    local systemd_version kill_target_option run_check_result=0 active_state="" waited_seconds=0
    recorded_run_is_unchanged "${recorded_snapshot}" "${recorded_pid}" \
        || run_check_result=$?
    if [[ "${run_check_result}" -eq 1 ]]; then
        log "the run in the state file ended or was replaced - killing nothing, recovery abandoned"
        return 1
    elif [[ "${run_check_result}" -ne 0 ]]; then
        log_error "the identity of PID ${recorded_pid} cannot be established - killing nothing, recovery abandoned"
        return 2
    fi
    systemd_version=$("${SYSTEMCTL_BIN}" --version 2>/dev/null \
                      | sed -n '1s/^systemd \([0-9]\+\).*/\1/p') || true
    kill_target_option=$(systemctl_kill_target_option "${systemd_version}")
    if ! signal_unit_processes "${kill_target_option}"; then
        log_error "systemctl kill ${kill_target_option} ${MAIN_SERVICE_UNIT} failed - the run may still be running, recovery failed"
        return 3
    fi
    # A oneshot is activating while its processes run; inactive or failed
    # means systemd saw the main process die and stopped the rest.
    while true; do
        active_state=$(unit_active_state)
        [[ "${active_state}" == "inactive" || "${active_state}" == "failed" ]] && break
        if [[ "${waited_seconds}" -ge "${KILL_CONFIRMATION_TIMEOUT_SECONDS}" ]]; then
            log_error "${MAIN_SERVICE_UNIT} is still '${active_state:-unknown}' ${KILL_CONFIRMATION_TIMEOUT_SECONDS}s after SIGKILL - recovery failed"
            return 3
        fi
        sleep 1
        waited_seconds=$(( waited_seconds + 1 ))
    done
    "${SYSTEMCTL_BIN}" reset-failed "${MAIN_SERVICE_UNIT}" 2>/dev/null || true
    return 0
}

# stall_window_minutes RUN_PHASE DNF_PHASE -> the minutes without progress
# after which a run in that phase is killed.  An unknown phase gets the
# longest window.
stall_window_minutes() {
    if [[ "$1" == "checking" ]]; then
        printf '%s' "${REBOOT_CHECK_STALL_TIMEOUT_MINUTES}"
    elif [[ "$1" == "updating" ]] && dnf_phase_is_before_transaction "$2"; then
        printf '%s' "${PRE_TRANSACTION_STALL_TIMEOUT_MINUTES}"
    else
        printf '%s' "${TRANSACTION_STALL_TIMEOUT_MINUTES}"
    fi
}

# report_stopped_run RUN_PHASE DNF_PHASE - logs and broadcasts what a killed
# run leaves behind.  Returns 1 when a reboot request it left needs an
# operator.
report_stopped_run() {
    local run_phase="$1" dnf_phase="$2"
    if [[ "${run_phase}" == "updating" ]] && dnf_phase_is_before_transaction "${dnf_phase}"; then
        log_error "stopped a run that made no progress for ${DNF_STALLED_MINUTES}min before installing anything (dnf phase: ${dnf_phase}); the next run tries again"
        send_wall_message "dnf-automatic-reboot: the update made no progress for ${DNF_STALLED_MINUTES}min before installing anything and was stopped." \
                          "Nothing was installed; the next run tries again."
        return 0
    fi
    if [[ "${run_phase}" == "checking" ]]; then
        log_error "stopped a run whose reboot check or service restarts made no progress for ${DNF_STALLED_MINUTES}min; its updates are installed, and the next run decides whether to reboot"
        send_wall_message "dnf-automatic-reboot: the reboot check made no progress for ${DNF_STALLED_MINUTES}min and was stopped." \
                          "Updates are installed; the next run decides whether to reboot."
        report_reboot_pending_without_reboot
        return
    fi
    log_error "stopped a run that made no progress for ${DNF_STALLED_MINUTES}min in phase=${run_phase} (dnf phase: ${dnf_phase}) - an rpm transaction may be incomplete, not rebooting. ${INTERRUPTED_TRANSACTION_CHECK}"
    send_wall_message "dnf-automatic-reboot: the update made no progress for ${DNF_STALLED_MINUTES}min and was stopped." \
                      "Updates may be incomplete; before rebooting:" \
                      "${INTERRUPTED_TRANSACTION_CHECK}"
    return 0
}

# Sourcing defines this file's functions without running the checks, so
# tests/run-tests.sh can exercise them directly.
main() {
    local state_snapshot="" run_phase start_uptime_seconds service_pid current_uptime_seconds
    local elapsed_minutes recorded_pid_identity_result=0 dnf_phase="" window_minutes kill_result=0

    # ---------------------------------------------------------------------------
    # Scenario 1: no state file
    # ---------------------------------------------------------------------------
    # One read: every decision below is about this snapshot, and every
    # removal checks that the file still holds it.
    if ! state_snapshot=$(read_run_state); then
        exit 0
    fi

    run_phase=$(run_state_field "${state_snapshot}" phase)
    start_uptime_seconds=$(run_state_field "${state_snapshot}" start_uptime)
    service_pid=$(run_state_field "${state_snapshot}" pid)

    if [[ ! "${start_uptime_seconds}" =~ ^[0-9]+$ || ! "${service_pid}" =~ ^[0-9]+$ ]]; then
        log "Malformed state file - removing"
        remove_inspected_run_state "${state_snapshot}"
        exit 0
    fi

    # Time is measured on CLOCK_BOOTTIME.  With no RTC, the wall clock steps
    # forward by however long the host was off once chrony synchronises; read
    # as wall-clock time, that step would look like an hour-long stall.  /run
    # does not survive a reboot, so a recorded uptime belongs to this boot.
    current_uptime_seconds=""
    read -r current_uptime_seconds _ < "${UPTIME_FILE}" 2>/dev/null || true
    current_uptime_seconds="${current_uptime_seconds%%.*}"
    if [[ ! "${current_uptime_seconds}" =~ ^[0-9]+$ ]]; then
        log_error "cannot read ${UPTIME_FILE} - run not supervised this cycle"
        exit 1
    fi
    elapsed_minutes=$(( (current_uptime_seconds - start_uptime_seconds) / 60 ))
    log "phase=${run_phase} elapsed=${elapsed_minutes}min pid=${service_pid}"

    # ---------------------------------------------------------------------------
    # Scenario 2: dead PID with state file present
    # ---------------------------------------------------------------------------
    check_recorded_pid_identity "${service_pid}" || recorded_pid_identity_result=$?
    if [[ "${recorded_pid_identity_result}" -eq 1 ]]; then
        log_warning "service PID ${service_pid} is dead or not the unit's main process but state file exists - updates may be incomplete, NOT rebooting"
        send_wall_message "dnf-automatic-reboot: WARNING - update process (PID ${service_pid})" \
                          "died unexpectedly in phase=${run_phase}." \
                          "Manual inspection required before rebooting."
        remove_inspected_run_state "${state_snapshot}"
        exit 0
    fi

    # ---------------------------------------------------------------------------
    # Progress.  Every cycle records the run's progress signature, so the
    # history is there when a stall comes.  A stall that cannot be confirmed
    # kills nothing and fails the unit.
    # ---------------------------------------------------------------------------
    if [[ "${run_phase}" == "updating" ]]; then
        dnf_phase=$(read_dnf_run_phase "$(run_state_field "${state_snapshot}" dnf_log_inode)" \
                                       "$(run_state_field "${state_snapshot}" dnf_log_offset)")
    fi
    if ! update_dnf_progress_record "${service_pid} ${start_uptime_seconds}" "${current_uptime_seconds}"; then
        log_error "${DNF_PROGRESS_FAILURE} - a stall cannot be told from progress, not acting this cycle"
        exit 1
    fi
    window_minutes=$(stall_window_minutes "${run_phase}" "${dnf_phase}")
    log "progress: ${DNF_PROGRESS_SIGNATURE} (unchanged for ${DNF_STALLED_MINUTES}min of ${window_minutes}min)${dnf_phase:+, dnf phase: ${dnf_phase}}"

    # ---------------------------------------------------------------------------
    # Scenario 4: progressing run - left alone, whatever its age
    # ---------------------------------------------------------------------------
    if [[ "${DNF_STALLED_MINUTES}" -lt "${window_minutes}" ]]; then
        if [[ "${recorded_pid_identity_result}" -eq 2 ]]; then
            log_warning "systemctl reports no MainPID for ${MAIN_SERVICE_UNIT} - PID ${service_pid} not verified this cycle"
        fi
        exit 0
    fi

    # ---------------------------------------------------------------------------
    # Scenario 3: stalled run - kill the service cgroup
    # ---------------------------------------------------------------------------
    if [[ "${recorded_pid_identity_result}" -eq 2 ]]; then
        log_error "the run stalled for ${DNF_STALLED_MINUTES}min, but PID ${service_pid} is alive and systemctl reports no MainPID for ${MAIN_SERVICE_UNIT} - cannot tell whether it is the run, not acting this cycle"
        exit 1
    fi
    begin_recovery
    kill_service_cgroup "${state_snapshot}" "${service_pid}" || kill_result=$?
    [[ "${kill_result}" -eq 1 ]] && exit 0
    [[ "${kill_result}" -eq 0 ]] || exit 1
    remove_inspected_run_state "${state_snapshot}"
    report_stopped_run "${run_phase}" "${dnf_phase}" || exit 1
    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
