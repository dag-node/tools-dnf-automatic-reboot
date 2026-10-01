# shellcheck shell=bash
# SPDX-License-Identifier: GPL-2.0-or-later
# run-state.sh
# ---------------------------------------------------------------------------
# Run state file protocol, sourced by run.sh and watchdog.sh.
#
# run.sh publishes STATE_FILE by writing a temporary file beside it and
# renaming it over the old one, so a reader sees a whole old or a whole new
# file, never an empty or half-written one.  Every write and every removal
# holds STATE_FILE_LOCK (flock).  The watchdog decides from one snapshot of the
# file and removes it only while it still holds that snapshot, under the lock:
# a run that started in the meantime, and wrote its own state, keeps it.
#
# The sourcing script defines TEST_ROOT, STATE_FILE and log_error.
# ---------------------------------------------------------------------------

readonly STATE_FILE_LOCK="${TEST_ROOT}/run/dnf-automatic-reboot.state.lock"
# Writers and removers hold the lock for one rename or one comparison.
readonly STATE_FILE_LOCK_WAIT_SEC=10

# prepare_state_file_lock - creates STATE_FILE_LOCK 0600 and sets it to 0600
# in place: flock(2) locks through a read-only descriptor, so a user able to
# open the file could stall every write.  Returns 1 on failure.
prepare_state_file_lock() {
    if ! ( umask 077 && : >> "${STATE_FILE_LOCK}" ) 2>/dev/null \
       || ! chmod 0600 "${STATE_FILE_LOCK}" 2>/dev/null; then
        log_error "cannot create ${STATE_FILE_LOCK} with mode 0600"
        return 1
    fi
}

# write_run_state CONTENT - publishes CONTENT as STATE_FILE by rename, under
# the lock.  Returns 1, leaving the previous file in place, on any failure.
write_run_state() {
    local state_content="$1" lock_descriptor temporary_file write_result=0
    prepare_state_file_lock || return 1
    exec {lock_descriptor}>>"${STATE_FILE_LOCK}" || return 1
    if ! flock -w "${STATE_FILE_LOCK_WAIT_SEC}" "${lock_descriptor}"; then
        exec {lock_descriptor}>&-
        log_error "${STATE_FILE_LOCK} not acquired within ${STATE_FILE_LOCK_WAIT_SEC}s"
        return 1
    fi
    if temporary_file=$(mktemp "${STATE_FILE}.XXXXXX" 2>/dev/null); then
        if ! printf '%s' "${state_content}" > "${temporary_file}" 2>/dev/null \
           || ! mv -f "${temporary_file}" "${STATE_FILE}" 2>/dev/null; then
            rm -f "${temporary_file}"
            write_result=1
        fi
    else
        write_result=1
    fi
    exec {lock_descriptor}>&-
    return "${write_result}"
}

# read_run_state -> STATE_FILE's content in one read; returns 1 when there is
# no state file.
read_run_state() {
    cat "${STATE_FILE}" 2>/dev/null
}

# run_state_field SNAPSHOT KEY -> the value of KEY= in SNAPSHOT, empty when
# absent.
run_state_field() {
    local state_line
    while IFS= read -r state_line; do
        if [[ "${state_line}" == "$2="* ]]; then
            printf '%s' "${state_line#"$2="}"
            return 0
        fi
    done <<< "$1"
    return 0
}

# remove_run_state_if_unchanged SNAPSHOT [FILE...]
# Under the lock, removes STATE_FILE, and each FILE, only when STATE_FILE still
# holds SNAPSHOT.
# Returns: 0 = removed
#          1 = STATE_FILE changed or is gone: nothing removed
#          2 = the lock was not acquired: nothing removed
remove_run_state_if_unchanged() {
    local expected_snapshot="$1" lock_descriptor current_snapshot="" removal_result=0
    shift
    prepare_state_file_lock || return 2
    exec {lock_descriptor}>>"${STATE_FILE_LOCK}" || return 2
    if ! flock -w "${STATE_FILE_LOCK_WAIT_SEC}" "${lock_descriptor}"; then
        exec {lock_descriptor}>&-
        log_error "${STATE_FILE_LOCK} not acquired within ${STATE_FILE_LOCK_WAIT_SEC}s - state file left alone"
        return 2
    fi
    if current_snapshot=$(read_run_state) && [[ "${current_snapshot}" == "${expected_snapshot}" ]]; then
        rm -f "${STATE_FILE}" "$@"
    else
        removal_result=1
    fi
    exec {lock_descriptor}>&-
    return "${removal_result}"
}
