# shellcheck shell=bash
# SPDX-License-Identifier: GPL-2.0-or-later
# reboot-request.sh
# ---------------------------------------------------------------------------
# Reboot request and cancellation protocol, sourced by run.sh, watchdog.sh,
# cancel-reboot.sh and reboot-if-pending.sh so all four follow one
# implementation.
#
# REBOOT_PENDING_FILE holds every update run from before a reboot is
# requested until the reboot; dnf-automatic-reboot.service carries
# ConditionPathExists=! on it.  It is also the authority for the reboot
# itself: every reboot this package requests runs reboot-if-pending.sh in the
# transient unit, which, holding REBOOT_REQUEST_LOCK_FILE, reboots only while
# REBOOT_PENDING_FILE exists, and writes REBOOT_DISPATCHED_FILE before it
# calls systemctl reboot.  cancel-reboot.sh, holding the same lock, refuses
# when REBOOT_DISPATCHED_FILE exists and otherwise removes
# REBOOT_PENDING_FILE.  After a cancellation succeeds, no request of this
# package can reboot the host, however late systemd processes it.
#
# A request returns accepted, rejected or unknown.  Rejected means nothing
# was submitted, and only then is the REBOOT_PENDING_FILE the request created
# removed; accepted and unknown keep it.
#
# The sourcing script defines TEST_ROOT, SYSTEMCTL_BIN, log, log_warning and
# log_error; a script that requests reboots also defines SYSTEMD_RUN_BIN.
# ---------------------------------------------------------------------------

readonly REBOOT_PENDING_FILE="${TEST_ROOT}/run/dnf-automatic-reboot.reboot-pending"
readonly REBOOT_DISPATCHED_FILE="${TEST_ROOT}/run/dnf-automatic-reboot.reboot-dispatched"
readonly REBOOT_REQUEST_LOCK_FILE="${TEST_ROOT}/run/dnf-automatic-reboot.reboot-request.lock"
readonly REBOOT_IF_PENDING_COMMAND="${TEST_ROOT}/usr/libexec/dnf-automatic-reboot/reboot-if-pending.sh"
readonly BUSCTL_BIN="${TEST_ROOT}/usr/bin/busctl"
# Transient timer and service that carry a requested reboot.
readonly SCHEDULED_REBOOT_UNIT=dnf-automatic-reboot-scheduled-reboot
readonly CANCEL_REBOOT_COMMAND=/usr/libexec/dnf-automatic-reboot/cancel-reboot.sh

# 1 from the moment REBOOT_PENDING_FILE may have been created until the
# request's outcome is known; the sourcing script's EXIT trap reads it.
REBOOT_REQUEST_IN_PROGRESS=0
REBOOT_REQUEST_LOCK_DESCRIPTOR=""

# ---------------------------------------------------------------------------
# Observations.  Each returns non-zero when systemd did not answer; callers
# treat that, and any value they do not recognise, as unknown.
# ---------------------------------------------------------------------------

# get_unit_properties UNIT -> LoadState, ActiveState, SubState and Job as
# KEY=VALUE lines from one systemctl show, so the values describe one moment.
# An unknown unit reports LoadState=not-found and ActiveState=inactive.
get_unit_properties() {
    "${SYSTEMCTL_BIN}" show --property=LoadState,ActiveState,SubState,Job "$1" 2>/dev/null
}

# read_unit_snapshot UNIT -> "LOAD ACTIVE SUB JOB", tab-separated, with JOB 0
# when none is queued.  Returns 1 when systemd did not answer, when LoadState
# or ActiveState is missing, or when Job is not a number.
read_unit_snapshot() {
    local unit_properties property_line load_state="" active_state="" sub_state="" job_id="0"
    unit_properties=$(get_unit_properties "$1") || return 1
    while IFS= read -r property_line; do
        case "${property_line}" in
            LoadState=*)   load_state="${property_line#LoadState=}" ;;
            ActiveState=*) active_state="${property_line#ActiveState=}" ;;
            SubState=*)    sub_state="${property_line#SubState=}" ;;
            Job=*)         job_id="${property_line#Job=}" ;;
        esac
    done <<< "${unit_properties}"
    [[ -n "${load_state}" && -n "${active_state}" ]] || return 1
    job_id="${job_id:-0}"
    [[ "${job_id}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\t%s\t%s\t%s' "${load_state}" "${active_state}" "${sub_state}" "${job_id}"
}

# get_system_state -> systemctl is-system-running's output.  The command exits
# non-zero for every state but running, so only the output is read.
get_system_state() {
    "${SYSTEMCTL_BIN}" is-system-running 2>/dev/null || true
}

# get_logind_preparing_for_shutdown -> busctl's "b true" or "b false".  logind
# sets PreparingForShutdown when it accepts a shutdown it delays for an
# inhibitor, before PID 1 reports stopping.
get_logind_preparing_for_shutdown() {
    "${BUSCTL_BIN}" get-property org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager PreparingForShutdown 2>/dev/null
}

# read_scheduled_reboot_status -> one of
#   none         nothing waiting, queued or running, and no reboot dispatched
#   waiting      the timer is waiting to fire
#   in_progress  the timer fired, or the reboot service has a job or runs
#   dispatched   reboot-if-pending.sh called systemctl reboot in this boot
#   failed       the reboot service failed
#   unknown      systemd did not answer, or answered with an unknown state
# The timer is read before the service: a timer that fires between the two
# reads shows as a queued or running service.
read_scheduled_reboot_status() {
    local timer_snapshot service_snapshot
    local timer_load_state timer_sub_state service_load_state service_active_state service_job_id
    if [[ -e "${REBOOT_DISPATCHED_FILE}" ]]; then
        printf 'dispatched'
        return 0
    fi
    if ! timer_snapshot=$(read_unit_snapshot "${SCHEDULED_REBOOT_UNIT}.timer") \
       || ! service_snapshot=$(read_unit_snapshot "${SCHEDULED_REBOOT_UNIT}.service"); then
        printf 'unknown'
        return 0
    fi
    IFS=$'\t' read -r timer_load_state _ timer_sub_state _ <<< "${timer_snapshot}"
    IFS=$'\t' read -r service_load_state service_active_state _ service_job_id <<< "${service_snapshot}"
    if [[ ! "${timer_load_state}" =~ ^(loaded|not-found)$ \
          || ! "${service_load_state}" =~ ^(loaded|not-found)$ ]]; then
        printf 'unknown'
        return 0
    fi
    if [[ "${service_job_id}" != "0" ]]; then
        printf 'in_progress'
        return 0
    fi
    case "${service_active_state}" in
        activating|active|deactivating|reloading) printf 'in_progress'; return 0 ;;
        failed)                                   printf 'failed';      return 0 ;;
        inactive)                                 ;;
        *)                                        printf 'unknown';     return 0 ;;
    esac
    if [[ "${timer_load_state}" == "loaded" ]]; then
        case "${timer_sub_state}" in
            waiting)             printf 'waiting';     return 0 ;;
            running)             printf 'in_progress'; return 0 ;;
            dead|elapsed|failed) ;;
            *)                   printf 'unknown';     return 0 ;;
        esac
    fi
    printf 'none'
}

# read_host_shutdown_state -> yes, no or unknown.  yes when PID 1 reports
# stopping or logind is preparing a delayed shutdown; no only when both were
# read and neither holds.
read_host_shutdown_state() {
    local system_state preparing_for_shutdown=""
    system_state=$(get_system_state)
    preparing_for_shutdown=$(get_logind_preparing_for_shutdown) || preparing_for_shutdown=""
    if [[ "${system_state}" == "stopping" || "${preparing_for_shutdown}" == "b true" ]]; then
        printf 'yes'
    elif [[ "${system_state}" =~ ^(initializing|starting|running|degraded|maintenance)$ \
            && "${preparing_for_shutdown}" == "b false" ]]; then
        printf 'no'
    else
        printf 'unknown'
    fi
}

# ---------------------------------------------------------------------------
# Actions.
# ---------------------------------------------------------------------------

# stop_unit UNIT -> systemctl stop's exit code.
stop_unit() {
    "${SYSTEMCTL_BIN}" stop "$1" 2>/dev/null
}

# reset_failed_units UNIT... - clears a failed state that keeps a transient
# unit's name taken.  A unit that is not failed is left as it is.
reset_failed_units() {
    "${SYSTEMCTL_BIN}" reset-failed "$@" 2>/dev/null || true
}

# start_reboot_unit DELAY_SECONDS LOCK_WAIT_SECONDS INHIBITED_WAIT_SECONDS DESCRIPTION
# -> systemd-run's exit code.  The transient service runs reboot-if-pending.sh
# after DELAY_SECONDS through a timer, or at once with DELAY_SECONDS 0.
# OnFailure= reports a reboot that did not happen.
start_reboot_unit() {
    local delay_seconds="$1" lock_wait_seconds="$2" inhibited_wait_seconds="$3" description="$4"
    local timer_options=()
    if [[ "${delay_seconds}" -gt 0 ]]; then
        timer_options=(--on-active="${delay_seconds}" --timer-property=AccuracySec=1s)
    fi
    "${SYSTEMD_RUN_BIN}" \
        --unit="${SCHEDULED_REBOOT_UNIT}" \
        "${timer_options[@]}" \
        --property="OnFailure=dnf-automatic-reboot-notify@${SCHEDULED_REBOOT_UNIT}.service.service" \
        --description="${description}" \
        "${REBOOT_IF_PENDING_COMMAND}" "${lock_wait_seconds}" "${inhibited_wait_seconds}"
}

# reboot_host -> systemctl reboot's exit code.  Run from a service, outside a
# terminal, systemctl does not check shutdown inhibitors unless asked to, and
# would reboot under a package transaction that holds one.
reboot_host() {
    "${SYSTEMCTL_BIN}" reboot --check-inhibitors=yes
}

# systemctl_checks_inhibitors - 0 when systemctl accepts --check-inhibitors.
# systemctl parses every option before it acts on --version.
systemctl_checks_inhibitors() {
    "${SYSTEMCTL_BIN}" --check-inhibitors=yes --version >/dev/null 2>&1
}

# submit_reboot DELAY_SECONDS LOCK_WAIT_SECONDS INHIBITED_WAIT_SECONDS DESCRIPTION
# A dispatch function for request_reboot.  INHIBITED_WAIT_SECONDS is how long
# reboot-if-pending.sh retries a reboot a shutdown inhibitor refuses.
# Returns: 0 = accepted: the unit exists, or a reboot was already waiting,
#              queued, running or dispatched (SCHEDULED_REBOOT_ALREADY_PRESENT=1)
#          1 = rejected: nothing was submitted
#          2 = unknown: systemd-run failed and its unit is not visible; the
#              request may still be on its way to systemd
# shellcheck disable=SC2034  # read by the sourcing script
SCHEDULED_REBOOT_ALREADY_PRESENT=0
submit_reboot() {
    local delay_seconds="$1" lock_wait_seconds="$2" inhibited_wait_seconds="$3" description="$4"
    local status systemd_run_exit_code=0 numeric_argument
    # shellcheck disable=SC2034
    SCHEDULED_REBOOT_ALREADY_PRESENT=0
    for numeric_argument in "${delay_seconds}" "${lock_wait_seconds}" "${inhibited_wait_seconds}"; do
        if [[ ! "${numeric_argument}" =~ ^[0-9]{1,9}$ ]]; then
            log_error "reboot request with a non-numeric delay or wait '${numeric_argument}' - reboot not requested"
            return 1
        fi
    done
    delay_seconds=$(( 10#${delay_seconds} ))
    lock_wait_seconds=$(( 10#${lock_wait_seconds} ))
    inhibited_wait_seconds=$(( 10#${inhibited_wait_seconds} ))
    status=$(read_scheduled_reboot_status)
    case "${status}" in
        waiting|in_progress|dispatched)
            # shellcheck disable=SC2034
            SCHEDULED_REBOOT_ALREADY_PRESENT=1
            log "a reboot is already scheduled or under way (${status}) - not requesting a second one"
            return 0
            ;;
        unknown)
            log_error "cannot read the state of ${SCHEDULED_REBOOT_UNIT} - reboot not requested"
            return 1
            ;;
    esac
    # An elapsed timer, or a reboot service that failed earlier in this boot,
    # keeps the unit name taken until it is stopped and reset.
    stop_unit "${SCHEDULED_REBOOT_UNIT}.timer" || true
    reset_failed_units "${SCHEDULED_REBOOT_UNIT}.service" "${SCHEDULED_REBOOT_UNIT}.timer"
    start_reboot_unit "${delay_seconds}" "${lock_wait_seconds}" "${inhibited_wait_seconds}" "${description}" \
        || systemd_run_exit_code=$?
    [[ "${systemd_run_exit_code}" -eq 0 ]] && return 0
    # systemd-run can fail after systemd accepted the unit, and a request it
    # sent may not have been processed yet; an absent unit proves nothing.
    status=$(read_scheduled_reboot_status)
    case "${status}" in
        waiting|in_progress|dispatched|failed)
            log_warning "systemd-run exited ${systemd_run_exit_code}, but ${SCHEDULED_REBOOT_UNIT} exists (${status}) - the reboot was submitted"
            return 0
            ;;
    esac
    log_error "systemd-run exited ${systemd_run_exit_code} and ${SCHEDULED_REBOOT_UNIT} is ${status}"
    return 2
}

# ---------------------------------------------------------------------------
# Lock.
# ---------------------------------------------------------------------------

# acquire_reboot_request_lock WAIT_SECONDS - 0 when the lock is held; with
# WAIT_SECONDS 0 it does not wait.  A process that exits releases it.
# Short options only: util-linux documents -w as --timeout, and --wait is an
# undocumented alias.
# flock(2) grants an exclusive lock through a read-only descriptor, so any
# user able to open the file could hold it: it is created 0600 and set to
# 0600 before every use, in place, so a holder keeps its inode.
acquire_reboot_request_lock() {
    local wait_seconds="$1"
    if ! ( umask 077 && : >> "${REBOOT_REQUEST_LOCK_FILE}" ) 2>/dev/null \
       || ! chmod 0600 "${REBOOT_REQUEST_LOCK_FILE}" 2>/dev/null; then
        log_error "cannot create ${REBOOT_REQUEST_LOCK_FILE} with mode 0600"
        return 1
    fi
    exec {REBOOT_REQUEST_LOCK_DESCRIPTOR}>>"${REBOOT_REQUEST_LOCK_FILE}" || return 1
    if [[ "${wait_seconds}" -eq 0 ]]; then
        flock -n "${REBOOT_REQUEST_LOCK_DESCRIPTOR}" && return 0
    else
        flock -w "${wait_seconds}" "${REBOOT_REQUEST_LOCK_DESCRIPTOR}" && return 0
    fi
    release_reboot_request_lock
    return 1
}

release_reboot_request_lock() {
    [[ -n "${REBOOT_REQUEST_LOCK_DESCRIPTOR}" ]] || return 0
    exec {REBOOT_REQUEST_LOCK_DESCRIPTOR}>&-
    REBOOT_REQUEST_LOCK_DESCRIPTOR=""
}

# ---------------------------------------------------------------------------
# Request.
# ---------------------------------------------------------------------------

# request_reboot LOCK_WAIT_SECONDS DISPATCH_FUNCTION [ARGUMENT...]
# Under the lock, creates REBOOT_PENDING_FILE, then calls DISPATCH_FUNCTION,
# which returns 0 accepted, 1 rejected or 2 unknown.
# Returns 0 when the reboot was accepted; 1 otherwise.  A rejected request
# removes the REBOOT_PENDING_FILE it created; a file that existed before
# belongs to an earlier request and stays.  An unknown outcome keeps the file.
request_reboot() {
    local lock_wait_seconds="$1" dispatch_function="$2" pending_file_created=0 dispatch_result=0
    shift 2
    if ! acquire_reboot_request_lock "${lock_wait_seconds}"; then
        log_error "${REBOOT_REQUEST_LOCK_FILE} not acquired within ${lock_wait_seconds}s - reboot not requested"
        return 1
    fi
    REBOOT_REQUEST_IN_PROGRESS=1
    if [[ ! -e "${REBOOT_PENDING_FILE}" ]]; then
        if ! : > "${REBOOT_PENDING_FILE}" 2>/dev/null; then
            REBOOT_REQUEST_IN_PROGRESS=0
            release_reboot_request_lock
            log_error "cannot create ${REBOOT_PENDING_FILE} - an update run could start before the reboot, reboot not requested"
            return 1
        fi
        pending_file_created=1
    fi
    "${dispatch_function}" "$@" || dispatch_result=$?
    case "${dispatch_result}" in
        0)
            ;;
        1)
            if [[ "${pending_file_created}" -eq 1 ]]; then
                rm -f "${REBOOT_PENDING_FILE}"
            fi
            ;;
        *)
            log_error "$(reboot_request_outcome_unknown_message)"
            ;;
    esac
    REBOOT_REQUEST_IN_PROGRESS=0
    release_reboot_request_lock
    if [[ "${dispatch_result}" -eq 0 ]]; then
        return 0
    fi
    return 1
}

# reboot_request_outcome_unknown_message -> the error for a request whose
# outcome is unknown, with the recovery commands.
reboot_request_outcome_unknown_message() {
    printf '%s' "whether the reboot request reached systemd is unknown. ${REBOOT_PENDING_FILE} stays, so no update run starts, and a reboot that arrives late still happens. Check: systemctl list-timers ${SCHEDULED_REBOOT_UNIT}.timer; then reboot, or allow updates again with: ${CANCEL_REBOOT_COMMAND}"
}

# report_interrupted_reboot_request - for the sourcing script's EXIT trap.
report_interrupted_reboot_request() {
    if [[ "${REBOOT_REQUEST_IN_PROGRESS}" -eq 1 ]]; then
        log_error "stopped while requesting a reboot - $(reboot_request_outcome_unknown_message)"
    fi
    return 0
}
