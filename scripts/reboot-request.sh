# shellcheck shell=bash
# SPDX-License-Identifier: GPL-2.0-or-later
# reboot-request.sh
# ---------------------------------------------------------------------------
# Reboot request and cancellation protocol, sourced by run.sh, watchdog.sh
# and cancel-reboot.sh so all three follow one implementation.
#
# REBOOT_PENDING_FILE holds every update run from before a reboot is
# requested until the reboot; dnf-automatic-reboot.service carries
# ConditionPathExists=! on it.  A request and a cancellation each run under
# REBOOT_REQUEST_LOCK_FILE, so a cancellation never sees a marker whose
# request has not yet reached systemd.  The lock file is never removed.
#
# Every outcome is accepted, rejected or unknown.  Only rejected, read from
# systemd state that says no reboot exists, releases a marker the request
# created; unknown keeps it.  A cancellation succeeds only on positive
# evidence that the reboot will not happen.
#
# The sourcing script defines TEST_ROOT, SYSTEMCTL_BIN, log, log_warning and
# log_error; a script that schedules reboots also defines SYSTEMD_RUN_BIN.
# ---------------------------------------------------------------------------

readonly REBOOT_PENDING_FILE="${TEST_ROOT}/run/dnf-automatic-reboot.reboot-pending"
readonly REBOOT_REQUEST_LOCK_FILE="${TEST_ROOT}/run/dnf-automatic-reboot.reboot-request.lock"
readonly BUSCTL_BIN="${TEST_ROOT}/usr/bin/busctl"
# Transient timer and service that carry a scheduled reboot.
readonly SCHEDULED_REBOOT_UNIT=dnf-automatic-reboot-scheduled-reboot
readonly CANCEL_REBOOT_COMMAND=/usr/libexec/dnf-automatic-reboot/cancel-reboot.sh

# 1 from the moment REBOOT_PENDING_FILE may have been created until the
# request's outcome is known; the sourcing script's EXIT trap reads it.
REBOOT_REQUEST_IN_PROGRESS=0
REBOOT_REQUEST_LOCK_DESCRIPTOR=""

# ---------------------------------------------------------------------------
# Observations.  Each prints what systemd reports and returns non-zero when
# systemd did not answer; callers treat that, and any value they do not
# recognise, as unknown.
# ---------------------------------------------------------------------------

# get_unit_property UNIT PROPERTY -> the property's value.  An unknown unit
# reports LoadState=not-found, ActiveState=inactive, SubState=dead and an
# empty Job.
get_unit_property() {
    "${SYSTEMCTL_BIN}" show --property="$2" --value "$1" 2>/dev/null
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
#   none         no timer waiting, no reboot service queued, running or done
#   waiting      the timer is waiting to fire
#   in_progress  the timer fired, or the reboot service has a job or runs
#   dispatched   the reboot service succeeded (RemainAfterExit=yes keeps it
#                active): systemd accepted the reboot
#   failed       the reboot service failed: the reboot was refused
#   unknown      systemd did not answer, or answered with an unknown state
read_scheduled_reboot_status() {
    local timer_load_state timer_sub_state service_load_state service_active_state service_job
    if ! timer_load_state=$(get_unit_property "${SCHEDULED_REBOOT_UNIT}.timer" LoadState) \
       || ! timer_sub_state=$(get_unit_property "${SCHEDULED_REBOOT_UNIT}.timer" SubState) \
       || ! service_load_state=$(get_unit_property "${SCHEDULED_REBOOT_UNIT}.service" LoadState) \
       || ! service_active_state=$(get_unit_property "${SCHEDULED_REBOOT_UNIT}.service" ActiveState) \
       || ! service_job=$(get_unit_property "${SCHEDULED_REBOOT_UNIT}.service" Job); then
        printf 'unknown'
        return 0
    fi
    if [[ ! "${timer_load_state}" =~ ^(loaded|not-found)$ \
          || ! "${service_load_state}" =~ ^(loaded|not-found)$ \
          || ! "${service_job}" =~ ^[0-9]*$ ]]; then
        printf 'unknown'
        return 0
    fi
    if [[ -n "${service_job}" && "${service_job}" != "0" ]]; then
        printf 'in_progress'
        return 0
    fi
    case "${service_active_state}" in
        activating|deactivating|reloading) printf 'in_progress'; return 0 ;;
        active)                            printf 'dispatched';  return 0 ;;
        failed)                            printf 'failed';      return 0 ;;
        inactive)                          ;;
        *)                                 printf 'unknown';     return 0 ;;
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

# start_transient_reboot_timer DELAY_SECONDS DESCRIPTION -> systemd-run's exit
# code.  RemainAfterExit=yes keeps a reboot service that succeeded active, the
# evidence cancel-reboot.sh reads; OnFailure= reports one that systemctl could
# not start, such as one blocked by an inhibitor.
start_transient_reboot_timer() {
    "${SYSTEMD_RUN_BIN}" \
        --unit="${SCHEDULED_REBOOT_UNIT}" \
        --on-active="$1" \
        --timer-property=AccuracySec=1s \
        --property=RemainAfterExit=yes \
        --property="OnFailure=dnf-automatic-reboot-notify@${SCHEDULED_REBOOT_UNIT}.service.service" \
        --description="$2" \
        "${SYSTEMCTL_BIN}" reboot
}

# reboot_host [--force] -> systemctl reboot's exit code.
reboot_host() {
    "${SYSTEMCTL_BIN}" reboot "$@"
}

# submit_scheduled_reboot DELAY_SECONDS DESCRIPTION
# Returns: 0 = accepted: the timer is waiting, or a reboot is already on its
#              way; SCHEDULED_REBOOT_ALREADY_PRESENT=1 when it was not this
#              call's
#          1 = rejected: nothing was scheduled
#          2 = unknown: systemd-run failed and systemd's state does not say
#              whether the timer exists
# shellcheck disable=SC2034  # read by the sourcing script
SCHEDULED_REBOOT_ALREADY_PRESENT=0
submit_scheduled_reboot() {
    local delay_seconds="$1" description="$2" status systemd_run_exit_code=0
    # shellcheck disable=SC2034
    SCHEDULED_REBOOT_ALREADY_PRESENT=0
    status=$(read_scheduled_reboot_status)
    case "${status}" in
        waiting|in_progress|dispatched)
            # shellcheck disable=SC2034
            SCHEDULED_REBOOT_ALREADY_PRESENT=1
            log "a reboot is already scheduled or under way (${status}) - not scheduling a second one"
            return 0
            ;;
        unknown)
            log_error "cannot read the state of ${SCHEDULED_REBOOT_UNIT} - reboot not scheduled"
            return 1
            ;;
    esac
    # An elapsed timer, or a reboot service that failed earlier in this boot,
    # keeps the unit name taken until it is stopped and reset.
    stop_unit "${SCHEDULED_REBOOT_UNIT}.timer" || true
    reset_failed_units "${SCHEDULED_REBOOT_UNIT}.service" "${SCHEDULED_REBOOT_UNIT}.timer"
    start_transient_reboot_timer "${delay_seconds}" "${description}" || systemd_run_exit_code=$?
    [[ "${systemd_run_exit_code}" -eq 0 ]] && return 0
    # systemd-run can fail after systemd accepted the unit: killed while it
    # waited for the reply, or failing while processing it.
    status=$(read_scheduled_reboot_status)
    case "${status}" in
        waiting|in_progress|dispatched|failed)
            log_warning "systemd-run exited ${systemd_run_exit_code}, but ${SCHEDULED_REBOOT_UNIT} exists (${status}) - the reboot was submitted"
            return 0
            ;;
        none)
            log_error "systemd-run exited ${systemd_run_exit_code} and no ${SCHEDULED_REBOOT_UNIT} exists - reboot not scheduled"
            return 1
            ;;
    esac
    log_error "systemd-run exited ${systemd_run_exit_code} and the state of ${SCHEDULED_REBOOT_UNIT} cannot be read - whether the reboot was scheduled is unknown"
    return 2
}

# submit_immediate_reboot
# Prefers an orderly reboot.  --force skips unit shutdown and remounts
# filesystems read-only under running processes, which risks the rootfs on
# flash-backed hosts; it is the fallback only, for when logind refuses the
# orderly path (a leaked inhibitor lock).
# Returns: 0 = accepted, 1 = rejected: the host is not shutting down,
#          2 = unknown.
submit_immediate_reboot() {
    local shutdown_state
    if reboot_host; then
        log "Orderly reboot requested"
        return 0
    fi
    log_warning "Orderly reboot refused - falling back to systemctl reboot --force"
    if reboot_host --force; then
        log "Forced reboot requested"
        return 0
    fi
    shutdown_state=$(read_host_shutdown_state)
    case "${shutdown_state}" in
        yes) log_warning "systemctl reboot failed, but the host is shutting down"; return 0 ;;
        no)  return 1 ;;
    esac
    log_error "systemctl reboot failed and the shutdown state cannot be read - whether the reboot was submitted is unknown"
    return 2
}

# ---------------------------------------------------------------------------
# Lock.
# ---------------------------------------------------------------------------

# acquire_reboot_request_lock WAIT_SECONDS - 0 when the lock is held; with
# WAIT_SECONDS 0 it does not wait.  A process that exits releases it.
acquire_reboot_request_lock() {
    local wait_seconds="$1"
    exec {REBOOT_REQUEST_LOCK_DESCRIPTOR}>>"${REBOOT_REQUEST_LOCK_FILE}" || return 1
    if [[ "${wait_seconds}" -eq 0 ]]; then
        flock --nonblock "${REBOOT_REQUEST_LOCK_DESCRIPTOR}" && return 0
    else
        flock --wait "${wait_seconds}" "${REBOOT_REQUEST_LOCK_DESCRIPTOR}" && return 0
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
        log_error "${REBOOT_REQUEST_LOCK_FILE} still held after ${lock_wait_seconds}s - reboot not requested"
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
    printf '%s' "whether the reboot request reached systemd is unknown. ${REBOOT_PENDING_FILE} stays, so no update run starts. Check: systemctl list-timers ${SCHEDULED_REBOOT_UNIT}.timer; then reboot, or allow updates again with: ${CANCEL_REBOOT_COMMAND}"
}

# report_interrupted_reboot_request - for the sourcing script's EXIT trap.
report_interrupted_reboot_request() {
    if [[ "${REBOOT_REQUEST_IN_PROGRESS}" -eq 1 ]]; then
        log_error "stopped while requesting a reboot - $(reboot_request_outcome_unknown_message)"
    fi
    return 0
}
