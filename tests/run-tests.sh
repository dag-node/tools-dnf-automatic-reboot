#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# run-tests.sh
# ---------------------------------------------------------------------------
# Test suite for dnf-automatic-reboot.  No external test framework: bash and
# coreutils only, so it runs anywhere the package itself runs.
#
#   make test
#   tests/run-tests.sh                  # all suites
#   tests/run-tests.sh kernel state     # only suites whose name matches
#
# Every test runs in its own subshell against a temporary tree pointed at by
# DNF_AUTOMATIC_REBOOT_TEST_ROOT, with stub uname/rpm/grubby/eu-readelf/
# systemctl binaries prepended to PATH.  The scripts under test are the real
# ones - needs-reboot.sh and run.sh are sourced for their functions, and
# watchdog.sh is executed end to end.
#
# Coverage is deliberately weighted towards decisions that are dangerous to
# get wrong: parsing that could invent a package name, verification that could
# skip a needed reboot, and the watchdog paths that could reboot a host with a
# half-applied rpm transaction.
# ---------------------------------------------------------------------------
IFS=$' \t\n'

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT
readonly SPEC_FILE="${REPO_ROOT}/dnf-automatic-reboot.spec"

TESTS_RUN=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILED_TEST_NAMES=()
SKIPPED_TEST_NAMES=()
SUITE_FILTERS=("$@")

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------
# run_test NAME FUNCTION [needs-exec]
#
# "needs-exec" marks a test that must run a stub as a real program.  Those are
# skipped where the temporary tree is mounted noexec, which is common in build
# sandboxes; everything else stubs commands as shell functions and runs
# anywhere.
run_test() {
    local test_name="$1" test_function="$2" requirement="${3:-}"
    local test_output test_exit_code=0 suite_filter matched=0

    if [[ "${#SUITE_FILTERS[@]}" -gt 0 ]]; then
        for suite_filter in "${SUITE_FILTERS[@]}"; do
            [[ "${test_name}" == *"${suite_filter}"* ]] && matched=1
        done
        [[ "${matched}" -eq 1 ]] || return 0
    fi

    # The tree is created in the parent so cleanup can find it, but PATH is
    # only extended inside the subshell so stubs cannot leak between tests.
    make_test_root

    local skip_reason=""
    if [[ "${requirement}" == "needs-exec" && "${TEST_ROOT_IS_EXECUTABLE}" != "yes" ]]; then
        skip_reason="temporary tree is noexec"
    elif [[ "${requirement}" == "needs-rpmspec" ]] \
         && ! { command -v rpmspec >/dev/null 2>&1 && [[ -f "${SPEC_FILE}" ]]; }; then
        skip_reason="rpmspec or the spec file is unavailable"
    fi
    if [[ -n "${skip_reason}" ]]; then
        TESTS_SKIPPED=$(( TESTS_SKIPPED + 1 ))
        SKIPPED_TEST_NAMES+=("${test_name} (${skip_reason})")
        printf '  skip %s (%s)\n' "${test_name}" "${skip_reason}"
        rm -rf "${TEST_ROOT_DIR:?}" 2>/dev/null
        return 0
    fi

    TESTS_RUN=$(( TESTS_RUN + 1 ))
    # wall is stubbed and exported before the test starts, so a script the test
    # runs as a child bash process inherits the stub too.  Unexported, the stub
    # stays in this shell and the child broadcasts to every terminal on the host.
    test_output=$(
        set +e
        PATH="${TEST_ROOT_DIR}/stubbin:${PATH}"
        export PATH
        wall() { printf 'wall %s\n' "$*" >> "${STUB_LOG}"; }
        export -f wall
        "${test_function}" 2>&1
    ) || test_exit_code=$?

    if [[ "${test_exit_code}" -eq 0 ]]; then
        printf '  ok   %s\n' "${test_name}"
    else
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        FAILED_TEST_NAMES+=("${test_name}")
        printf '  FAIL %s\n' "${test_name}"
        printf '%s\n' "${test_output}" | sed 's/^/         /'
    fi
    rm -rf "${TEST_ROOT_DIR:?}" 2>/dev/null
}

fail() {
    printf 'assertion failed: %s\n' "$*" >&2
    exit 1
}

assert_equals() {
    local expected="$1" actual="$2" description="${3:-}"
    [[ "${expected}" == "${actual}" ]] \
        || fail "${description} expected [${expected}] got [${actual}]"
}

assert_exit_code() {
    local expected="$1" actual="$2" description="${3:-}"
    [[ "${expected}" == "${actual}" ]] \
        || fail "${description} expected exit ${expected} got ${actual}"
}

assert_contains() {
    local haystack="$1" needle="$2" description="${3:-}"
    [[ "${haystack}" == *"${needle}"* ]] \
        || fail "${description} expected to find [${needle}] in [${haystack}]"
}

assert_not_contains() {
    local haystack="$1" needle="$2" description="${3:-}"
    [[ "${haystack}" != *"${needle}"* ]] \
        || fail "${description} did not expect [${needle}] in [${haystack}]"
}

# ---------------------------------------------------------------------------
# Temporary root with stub binaries
# ---------------------------------------------------------------------------
make_test_root() {
    TEST_ROOT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dnf-automatic-reboot-test.XXXXXX")
    export TEST_ROOT_DIR
    export DNF_AUTOMATIC_REBOOT_TEST_ROOT="${TEST_ROOT_DIR}"
    export STUB_LOG="${TEST_ROOT_DIR}/stub.log"

    mkdir -p "${TEST_ROOT_DIR}"/{etc/dnf,var/log,var/lib/dnf-automatic-reboot,run,usr/bin,usr/libexec/dnf-automatic-reboot,stubbin,proc/sys/kernel/random}
    : > "${STUB_LOG}"

    cp "${REPO_ROOT}/conf/automatic-reboot.conf" "${TEST_ROOT_DIR}/etc/dnf/automatic-reboot.conf"
    printf 'reboot = never\napply_updates = yes\n' > "${TEST_ROOT_DIR}/etc/dnf/automatic.conf"
    printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n' \
        > "${TEST_ROOT_DIR}/proc/sys/kernel/random/boot_id"

    write_stub_programs
    detect_test_root_exec_support
}

# Programs the scripts invoke by absolute path cannot be replaced by a shell
# function, so they are written as real files.  Tests that depend on them are
# marked needs-exec.
write_stub_programs() {
    # Recorded so tests can assert exactly which privileged action was taken.
    cat > "${TEST_ROOT_DIR}/usr/bin/systemctl" <<'STUB'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    printf 'systemd %s (stub)\n' "${STUB_SYSTEMD_VERSION:-252}"
    exit 0
fi
# show --property=P --value UNIT.  The scheduled-reboot timer reports
# STUB_REBOOT_TIMER_LOAD_STATE and STUB_REBOOT_TIMER_SUB_STATE, not-found and
# dead by default; its service is not-found, inactive, with no job.  The main
# unit's ActiveState is STUB_ACTIVE_STATE, failed by default, as after a kill;
# MainPID is STUB_MAIN_PID.
if [[ "$1" == "show" ]]; then
    case "${*: -1}:${2#--property=}" in
        *scheduled-reboot.timer:LoadState,*)
            printf 'LoadState=%s\nActiveState=inactive\nSubState=%s\n' \
                "${STUB_REBOOT_TIMER_LOAD_STATE:-not-found}" "${STUB_REBOOT_TIMER_SUB_STATE:-dead}" ;;
        *scheduled-reboot.service:LoadState,*)
            printf 'LoadState=not-found\nActiveState=inactive\nSubState=dead\n' ;;
        *:ActiveState) printf '%s\n' "${STUB_ACTIVE_STATE:-failed}" ;;
        *)             printf '%s\n' "${STUB_MAIN_PID:-}" ;;
    esac
    exit 0
fi
if [[ "$1" == "is-system-running" ]]; then
    printf 'running\n'
    exit 0
fi
printf 'systemctl %s\n' "$*" >> "${STUB_LOG}"
[[ "${STUB_SYSTEMCTL_FAIL:-}" == "yes" ]] && exit 1
exit 0
STUB

    cat > "${TEST_ROOT_DIR}/usr/bin/busctl" <<'STUB'
#!/bin/bash
printf 'b false\n'
STUB

    cat > "${TEST_ROOT_DIR}/usr/bin/systemd-run" <<'STUB'
#!/bin/bash
printf 'systemd-run %s\n' "$*" >> "${STUB_LOG}"
exit 0
STUB

    # dnf ... needs-restarting -r prints STUB_NEEDS_RESTARTING_OUTPUT and exits
    # STUB_NEEDS_RESTARTING_RC; -s prints STUB_STALE_SERVICES.
    # updateinfo prints STUB_SECURITY_ADVISORIES; check-update exits
    # STUB_CHECK_UPDATE_RC (100 = upgrades available, 0 = none).
    cat > "${TEST_ROOT_DIR}/usr/bin/dnf" <<'STUB'
#!/bin/bash
printf 'dnf %s\n' "$*" >> "${STUB_LOG}"
for argument in "$@"; do
    if [[ "${argument}" == "updateinfo" ]]; then
        printf '%s\n' "${STUB_SECURITY_ADVISORIES:-}"
        exit 0
    fi
    if [[ "${argument}" == "check-update" ]]; then
        exit "${STUB_CHECK_UPDATE_RC:-0}"
    fi
    if [[ "${argument}" == "-s" ]]; then
        printf '%s\n' "${STUB_STALE_SERVICES:-}"
        exit 0
    fi
done
[[ -n "${STUB_NEEDS_RESTARTING_STDERR:-}" ]] && printf '%s\n' "${STUB_NEEDS_RESTARTING_STDERR}" >&2
printf '%s\n' "${STUB_NEEDS_RESTARTING_OUTPUT:-}"
exit "${STUB_NEEDS_RESTARTING_RC:-0}"
STUB

    chmod +x "${TEST_ROOT_DIR}"/usr/bin/* 2>/dev/null
}

detect_test_root_exec_support() {
    printf '#!/bin/bash\nexit 0\n' > "${TEST_ROOT_DIR}/stubbin/exec-probe"
    chmod +x "${TEST_ROOT_DIR}/stubbin/exec-probe" 2>/dev/null
    if "${TEST_ROOT_DIR}/stubbin/exec-probe" 2>/dev/null; then
        TEST_ROOT_IS_EXECUTABLE=yes
    else
        TEST_ROOT_IS_EXECUTABLE=no
    fi
    rm -f "${TEST_ROOT_DIR}/stubbin/exec-probe"
}

# ---------------------------------------------------------------------------
# Command stubs as shell functions.
#
# A bash function shadows a PATH lookup for a bare command name, so these need
# no exec permission and work on a noexec temporary tree.  Defined after the
# library is sourced; the library resolves these names at call time.
# ---------------------------------------------------------------------------
install_command_stubs() {
    uname() {
        case "$1" in
            -r) printf '%s\n' "${STUB_UNAME_R:-6.12.0-204.92.4.3.1.el9uek.aarch64}" ;;
            -m) printf '%s\n' "${STUB_UNAME_M:-aarch64}" ;;
            *)  printf 'Linux\n' ;;
        esac
    }

    # rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' PKG -> STUB_RPM_KERNEL_VERSIONS
    # rpm -q --qf '%{EVR}' PKG                          -> STUB_RPM_EVR
    # rpm -qf PATH --qf '%{NAME}'                       -> STUB_RPM_OWNER
    rpm() {
        local argument
        if [[ "$1" == "-qf" ]]; then
            printf '%s' "${STUB_RPM_OWNER:-}"
            [[ -n "${STUB_RPM_OWNER:-}" ]] || return 1
            return 0
        fi
        for argument in "$@"; do
            if [[ "${argument}" == *'%{EVR}'* ]]; then
                printf '%s' "${STUB_RPM_EVR:-}"
                [[ -n "${STUB_RPM_EVR:-}" ]] || return 1
                return 0
            fi
        done
        [[ -n "${STUB_RPM_KERNEL_VERSIONS:-}" ]] || return 1
        printf '%s\n' "${STUB_RPM_KERNEL_VERSIONS}"
    }

    grubby() {
        [[ -n "${STUB_GRUBBY_DEFAULT:-}" ]] || return 1
        printf '%s\n' "${STUB_GRUBBY_DEFAULT}"
    }

    # STUB_BUILD_IDS holds "path<TAB>buildid" lines; an absent path prints
    # nothing, which the caller must treat as unreadable.
    eu-readelf() {
        local target_path="${2:-}" mapped_path mapped_build_id
        while IFS=$'\t' read -r mapped_path mapped_build_id; do
            [[ "${mapped_path}" == "${target_path}" ]] || continue
            printf '    Build ID: %s\n' "${mapped_build_id}"
            return 0
        done <<< "${STUB_BUILD_IDS:-}"
        return 0
    }

}

# Source the real needs-reboot.sh for its functions, then relax the shell
# options it sets so assertions can inspect non-zero returns.
load_needs_reboot_library() {
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/scripts/needs-reboot.sh"
    set +e
    IFS=$' \t\n'
    install_command_stubs
}

load_watchdog_library() {
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/scripts/watchdog.sh"
    set +e
    IFS=$' \t\n'
}

load_run_library() {
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/scripts/run.sh"
    set +e
    IFS=$' \t\n'
    install_command_stubs
}

# ---------------------------------------------------------------------------
# parser: only "  * <name>" lines may become package names
# ---------------------------------------------------------------------------
test_parser_extracts_package_names() {
    load_needs_reboot_library
    local parsed
    parsed=$(printf '%s\n' \
        'Core libraries or services have been updated since boot-up:' \
        '  * glibc' \
        '  * kernel-uek' \
        '  * systemd' \
        '' \
        'Reboot is required to fully utilize these updates.' \
        'More information: https://access.redhat.com/solutions/27943' \
        | parse_flagged_package_names | paste -sd, -)
    assert_equals "glibc,kernel-uek,systemd" "${parsed}" "canonical output"
}

test_parser_ignores_plugin_warning_line() {
    load_needs_reboot_library
    local parsed
    # The plugin emits this for drop-ins naming uninstalled packages.  Folded
    # into the parsed stream it used to read as a package and reboot the host.
    parsed=$(printf '%s\n' \
        '  * glibc' \
        'No installed package found for package name "kernel-rt" specified in needs-restarting file "uek.conf".' \
        | parse_flagged_package_names | paste -sd, -)
    assert_equals "glibc" "${parsed}" "warning line must not become a package"
}

test_parser_ignores_translated_headers() {
    load_needs_reboot_library
    local parsed
    # Every header string passes through gettext; a blocklist of the English
    # ones lets translated headers through as package names.
    parsed=$(printf '%s\n' \
        'Zakladni knihovny nebo sluzby byly aktualizovany od spusteni systemu:' \
        '  * systemd' \
        'Pro plne vyuziti techto aktualizaci je nutny restart.' \
        | parse_flagged_package_names | paste -sd, -)
    assert_equals "systemd" "${parsed}" "translated headers must not become packages"
}

test_parser_rejects_multi_word_bullet() {
    load_needs_reboot_library
    local parsed
    parsed=$(printf '%s\n' '  * two words here' '  * glibc' \
             | parse_flagged_package_names | paste -sd, -)
    assert_equals "glibc" "${parsed}" "multi-word bullet is not a package name"
}

test_parser_yields_nothing_without_bullets() {
    load_needs_reboot_library
    local parsed
    parsed=$(printf '%s\n' 'No core libraries or services have been updated since boot-up.' \
             | parse_flagged_package_names)
    assert_equals "" "${parsed}" "no bullets"
}

# ---------------------------------------------------------------------------
# config: get_config_value is section-blind, so key names must not collide
# ---------------------------------------------------------------------------
test_config_every_key_resolves() {
    load_needs_reboot_library
    local config_key resolved_value
    for config_key in filter_packages verify_kernel_version learn_false_positives \
                      verify_grub_default kernel_reboot_attempt_limit \
                      needs_restarting_timeout_sec reboot_delay_sec always_reboot \
                      dnf_timeout_min kill_grace_sec restart_services \
                      restart_services_exclude watchdog_soft_timeout_min \
                      watchdog_hard_timeout_min force_reboot_on_hard_timeout \
                      enable_chrony_wait wall_messages reboot_request_lock_wait_sec \
                      watchdog_kill_confirm_sec restart_service_timeout_sec; do
        resolved_value=$(get_config_value "${config_key}" "MISSING")
        if [[ "${resolved_value}" == "MISSING" ]]; then
            fail "shipped config does not define ${config_key}"
        fi
    done
    return 0
}

test_config_prefix_keys_do_not_collide() {
    load_needs_reboot_library
    # restart_services must not pick up restart_services_exclude's value.
    assert_equals "yes" "$(get_config_value restart_services MISSING)" "restart_services"
    assert_contains "$(get_config_value restart_services_exclude MISSING)" "dbus.service" \
        "restart_services_exclude"
}

test_config_int_rejects_non_numeric() {
    load_needs_reboot_library
    printf '[timeouts]\nneeds_restarting_timeout_sec = abc\n' \
        > "${TEST_ROOT_DIR}/etc/dnf/automatic-reboot.conf"
    # The warning must not land on stdout: the caller assigns this to a
    # variable that then goes straight into `timeout <value>s`.
    assert_equals "120" "$(get_config_integer needs_restarting_timeout_sec 120 2>/dev/null)" \
        "non-numeric falls back to a clean default"
}

test_config_int_reads_leading_zeros_as_decimal() {
    load_run_library
    printf '[reboot]\nreboot_delay_sec = 08\n' > "${TEST_ROOT_DIR}/etc/dnf/automatic-reboot.conf"
    assert_equals "8" "$(get_config_integer reboot_delay_sec 300 1 86400 2>/dev/null)" \
        "08 is eight seconds, not an invalid octal number"
}

test_config_int_enforces_bounds() {
    load_run_library
    printf '[reboot]\nreboot_delay_sec = 0\n' > "${TEST_ROOT_DIR}/etc/dnf/automatic-reboot.conf"
    assert_equals "300" "$(get_config_integer reboot_delay_sec 300 1 86400 2>/dev/null)" \
        "a zero delay would reboot at once"
    printf '[reboot]\nreboot_delay_sec = 99999999999999999999\n' > "${TEST_ROOT_DIR}/etc/dnf/automatic-reboot.conf"
    assert_equals "300" "$(get_config_integer reboot_delay_sec 300 1 86400 2>/dev/null)" \
        "a number bash arithmetic would wrap"
}

test_request_malformed_delay_submits_nothing() {
    load_request_library
    local exit_code=0
    submit_reboot 08x 60 0 "test" >/dev/null 2>&1 || exit_code=$?
    assert_exit_code 1 "${exit_code}" "rejected"
    submit_reboot 08 60 0 "test" >/dev/null 2>&1
    assert_contains "$(cat "${STUB_LOG}")" "systemd-run 8 " "08 is submitted as an eight-second delay"
    assert_not_contains "$(cat "${STUB_LOG}")" "systemd-run 08x" "the malformed one never reached systemd-run"
}

test_config_int_rejects_negative() {
    load_needs_reboot_library
    printf '[kernel]\nkernel_reboot_attempt_limit = -1\n' \
        > "${TEST_ROOT_DIR}/etc/dnf/automatic-reboot.conf"
    assert_equals "3" "$(get_config_integer kernel_reboot_attempt_limit 3 2>/dev/null)" \
        "negative falls back to a clean default"
}

# ---------------------------------------------------------------------------
# kernel: equality against the running kernel, failing closed
# ---------------------------------------------------------------------------
test_kernel_running_is_newest_is_false_positive() {
    load_needs_reboot_library
    export STUB_UNAME_R="6.12.0-204.92.4.3.1.el9uek.aarch64"
    export STUB_RPM_KERNEL_VERSIONS="6.12.0-204.92.4.3.1.el9uek.aarch64"
    running_kernel_is_newest kernel-uek
    assert_exit_code 0 "$?" "running kernel is newest"
}

test_kernel_newer_installed_is_genuine() {
    load_needs_reboot_library
    export STUB_UNAME_R="6.12.0-204.92.4.3.1.el9uek.aarch64"
    export STUB_RPM_KERNEL_VERSIONS="6.12.0-204.92.4.3.1.el9uek.aarch64
6.12.0-204.92.4.4.el9uek.aarch64"
    running_kernel_is_newest kernel-uek
    assert_exit_code 1 "$?" "newer kernel installed"
}

test_kernel_not_installed_is_genuine() {
    load_needs_reboot_library
    export STUB_UNAME_R="6.12.0-204.92.4.3.1.el9uek.aarch64"
    export STUB_RPM_KERNEL_VERSIONS=""
    running_kernel_is_newest kernel-uek >/dev/null 2>&1
    assert_exit_code 1 "$?" "uninstalled package must fail closed, not be dropped"
}

test_kernel_arch_stripped_form_matches() {
    load_needs_reboot_library
    export STUB_UNAME_R="5.14.0-427.el9"
    export STUB_UNAME_M="x86_64"
    export STUB_RPM_KERNEL_VERSIONS="5.14.0-427.el9.x86_64"
    running_kernel_is_newest kernel
    assert_exit_code 0 "$?" "release string without arch suffix"
}

test_kernel_version_sort_is_numeric() {
    load_needs_reboot_library
    export STUB_RPM_KERNEL_VERSIONS="6.12.0-204.92.4.3.1.el9uek.aarch64
6.12.0-204.92.4.4.el9uek.aarch64
6.12.0-204.92.4.10.el9uek.aarch64"
    assert_equals "6.12.0-204.92.4.10.el9uek.aarch64" \
        "$(newest_installed_kernel_version kernel-uek)" "4.10 outranks 4.4 and 4.3.1"
}

# ---------------------------------------------------------------------------
# grub: never reboot into a kernel the bootloader would not select
# ---------------------------------------------------------------------------
test_grub_default_matches_newest() {
    load_needs_reboot_library
    export STUB_RPM_KERNEL_VERSIONS="6.12.0-204.92.4.4.el9uek.aarch64"
    export STUB_GRUBBY_DEFAULT="/boot/vmlinuz-6.12.0-204.92.4.4.el9uek.aarch64"
    grub_default_is_newest_kernel kernel-uek-core
    assert_exit_code 0 "$?" "default points at newest"
}

test_grub_default_is_stale() {
    load_needs_reboot_library
    export STUB_RPM_KERNEL_VERSIONS="6.12.0-204.92.4.4.el9uek.aarch64"
    export STUB_GRUBBY_DEFAULT="/boot/vmlinuz-6.12.0-204.92.4.3.1.el9uek.aarch64"
    grub_default_is_newest_kernel kernel-uek-core
    assert_exit_code 1 "$?" "stale default must be detected"
}

test_grub_unreadable_grubenv_is_undetermined() {
    load_needs_reboot_library
    export STUB_RPM_KERNEL_VERSIONS="6.12.0-204.92.4.4.el9uek.aarch64"
    # What grubby printed, with exit 0, when grubenv was unreadable.
    export STUB_GRUBBY_DEFAULT="/boot"
    grub_default_is_newest_kernel kernel-uek-core
    assert_exit_code 2 "$?" "no kernel path is undetermined, not a stale default"
}

test_grub_unavailable_is_undetermined() {
    load_needs_reboot_library
    unset -f grubby
    PATH=/nonexistent
    export STUB_RPM_KERNEL_VERSIONS="6.12.0-204.92.4.4.el9uek.aarch64"
    grub_default_is_newest_kernel kernel-uek-core
    assert_exit_code 2 "$?" "missing grubby is undetermined, not a mismatch"
}

# ---------------------------------------------------------------------------
# build-id: every owned process is checked, not just the first
# ---------------------------------------------------------------------------
test_build_id_all_processes_match() {
    load_needs_reboot_library
    PROCESS_MAP_BUILT=1
    PROCESS_BINARY_TO_PIDS=( ["/usr/lib/systemd/systemd"]=$'1\n' )
    PROCESS_BINARY_TO_PACKAGE=( ["/usr/lib/systemd/systemd"]="systemd" )
    export STUB_BUILD_IDS="/usr/lib/systemd/systemd	aaaa
${TEST_ROOT_DIR}/proc/1/exe	aaaa"
    verify_build_id systemd >/dev/null 2>&1
    assert_exit_code 0 "$?" "matching build-ids are a false positive"
}

test_build_id_mismatch_on_later_process_wins() {
    load_needs_reboot_library
    PROCESS_MAP_BUILT=1
    # PID 1 re-execs itself on upgrade and always matches; journald does not.
    # Stopping at the first match would call this a false positive.
    PROCESS_BINARY_TO_PIDS=( ["/usr/lib/systemd/systemd"]=$'1\n' ["/usr/lib/systemd/systemd-journald"]=$'742\n' )
    PROCESS_BINARY_TO_PACKAGE=( ["/usr/lib/systemd/systemd"]="systemd" ["/usr/lib/systemd/systemd-journald"]="systemd" )
    export STUB_BUILD_IDS="/usr/lib/systemd/systemd	aaaa
${TEST_ROOT_DIR}/proc/1/exe	aaaa
/usr/lib/systemd/systemd-journald	bbbb
${TEST_ROOT_DIR}/proc/742/exe	cccc"
    verify_build_id systemd >/dev/null 2>&1
    assert_exit_code 2 "$?" "a stale journald must make the package genuine"
}

test_build_id_stale_process_sharing_a_binary_is_found() {
    load_needs_reboot_library
    export STUB_RPM_OWNER="systemd"
    # Built from a fake /proc rather than injected, so the map itself is under
    # test.  PID 1 re-exec'd onto the new systemd; the `systemd --user` manager
    # at PID 2345 runs the same path, still on the replaced image.  Keeping one
    # PID per binary saw only PID 1 and called the package a false positive.
    local systemd_binary="${TEST_ROOT_DIR}/usr/lib/systemd/systemd"
    mkdir -p "${TEST_ROOT_DIR}/usr/lib/systemd" "${TEST_ROOT_DIR}/proc/1" "${TEST_ROOT_DIR}/proc/2345"
    : > "${systemd_binary}"
    ln -s "${systemd_binary}" "${TEST_ROOT_DIR}/proc/1/exe"
    ln -s "${systemd_binary} (deleted)" "${TEST_ROOT_DIR}/proc/2345/exe"
    export STUB_BUILD_IDS="${systemd_binary}	aaaa
${TEST_ROOT_DIR}/proc/1/exe	aaaa
${TEST_ROOT_DIR}/proc/2345/exe	bbbb"
    verify_build_id systemd >/dev/null 2>&1
    assert_exit_code 2 "$?" "a stale user manager must make systemd genuine"
}

test_build_id_unreadable_process_keeps_the_package() {
    load_needs_reboot_library
    PROCESS_MAP_BUILT=1
    # PID 1 matches; journald is still running but eu-readelf does not print
    # its build-id.  One match must not vouch for a process nobody could check.
    PROCESS_BINARY_TO_PIDS=( ["/usr/lib/systemd/systemd"]=$'1\n' ["/usr/lib/systemd/systemd-journald"]=$'742\n' )
    PROCESS_BINARY_TO_PACKAGE=( ["/usr/lib/systemd/systemd"]="systemd" ["/usr/lib/systemd/systemd-journald"]="systemd" )
    mkdir -p "${TEST_ROOT_DIR}/proc/742"
    ln -s /usr/lib/systemd/systemd-journald "${TEST_ROOT_DIR}/proc/742/exe"
    export STUB_BUILD_IDS="/usr/lib/systemd/systemd	aaaa
${TEST_ROOT_DIR}/proc/1/exe	aaaa
/usr/lib/systemd/systemd-journald	bbbb"
    verify_build_id systemd >/dev/null 2>&1
    assert_exit_code 1 "$?" "an unreadable running process is unverifiable, not a false positive"
}

test_build_id_exited_process_is_not_unreadable() {
    load_needs_reboot_library
    PROCESS_MAP_BUILT=1
    # PID 742 exited between the /proc walk and the build-id read: it does not
    # run any code, so it neither confirms nor blocks the verdict on PID 1.
    PROCESS_BINARY_TO_PIDS=( ["/usr/lib/systemd/systemd"]=$'1\n' ["/usr/lib/systemd/systemd-userwork"]=$'742\n' )
    PROCESS_BINARY_TO_PACKAGE=( ["/usr/lib/systemd/systemd"]="systemd" ["/usr/lib/systemd/systemd-userwork"]="systemd" )
    export STUB_BUILD_IDS="/usr/lib/systemd/systemd	aaaa
${TEST_ROOT_DIR}/proc/1/exe	aaaa
/usr/lib/systemd/systemd-userwork	bbbb"
    verify_build_id systemd >/dev/null 2>&1
    assert_exit_code 0 "$?" "a process that has exited is not running stale code"
}

test_build_id_unreadable_link_of_live_process_keeps_the_package() {
    load_needs_reboot_library
    PROCESS_MAP_BUILT=1
    # PID 742 is still in /proc, but neither its build-id nor its executable
    # link can be read.  That is no evidence it exited.
    PROCESS_BINARY_TO_PIDS=( ["/usr/lib/systemd/systemd"]=$'1\n' ["/usr/lib/systemd/systemd-journald"]=$'742\n' )
    PROCESS_BINARY_TO_PACKAGE=( ["/usr/lib/systemd/systemd"]="systemd" ["/usr/lib/systemd/systemd-journald"]="systemd" )
    mkdir -p "${TEST_ROOT_DIR}/proc/742"
    printf '742 (systemd-journal) S 1 742 742 0 -1\n' > "${TEST_ROOT_DIR}/proc/742/stat"
    export STUB_BUILD_IDS="/usr/lib/systemd/systemd	aaaa
${TEST_ROOT_DIR}/proc/1/exe	aaaa
/usr/lib/systemd/systemd-journald	bbbb"
    verify_build_id systemd >/dev/null 2>&1
    assert_exit_code 1 "$?" "an unreadable link on a live process is unverifiable"
}

test_build_id_zombie_process_is_exited() {
    load_needs_reboot_library
    PROCESS_MAP_BUILT=1
    # A zombie keeps its /proc entry but does not run any code; its exe link
    # is gone.
    PROCESS_BINARY_TO_PIDS=( ["/usr/lib/systemd/systemd"]=$'1\n' ["/usr/lib/systemd/systemd-userwork"]=$'742\n' )
    PROCESS_BINARY_TO_PACKAGE=( ["/usr/lib/systemd/systemd"]="systemd" ["/usr/lib/systemd/systemd-userwork"]="systemd" )
    mkdir -p "${TEST_ROOT_DIR}/proc/742"
    printf '742 (systemd-userwor) Z 1 742 742 0 -1\n' > "${TEST_ROOT_DIR}/proc/742/stat"
    export STUB_BUILD_IDS="/usr/lib/systemd/systemd	aaaa
${TEST_ROOT_DIR}/proc/1/exe	aaaa"
    verify_build_id systemd >/dev/null 2>&1
    assert_exit_code 0 "$?" "a zombie is not running stale code"
}

test_build_id_no_owned_process_is_unverifiable() {
    load_needs_reboot_library
    PROCESS_MAP_BUILT=1
    PROCESS_BINARY_TO_PIDS=()
    PROCESS_BINARY_TO_PACKAGE=()
    verify_build_id systemd >/dev/null 2>&1
    assert_exit_code 1 "$?" "no owned process is unverifiable, not a false positive"
}

# ---------------------------------------------------------------------------
# state: exact field matching, never substring
# ---------------------------------------------------------------------------
test_state_round_trip() {
    load_needs_reboot_library
    write_restart_state glibc "2.34-274" "boot-a" pending
    assert_contains "$(read_restart_state glibc)" "pending" "round trip"
}

test_state_replacement_is_exact_field() {
    load_needs_reboot_library
    write_restart_state libglibc "1.0" "boot-a" confirmed
    write_restart_state glibc "2.34-274" "boot-a" pending
    write_restart_state glibc "2.34-999" "boot-b" confirmed
    assert_contains "$(read_restart_state libglibc)" "confirmed" "libglibc row survives"
    assert_equals "1" "$(read_restart_state glibc | wc -l)" "exactly one glibc row"
    assert_contains "$(read_restart_state glibc)" "2.34-999" "newest evr wins"
}

test_state_kernel_attempts_keyed_on_target() {
    load_needs_reboot_library
    write_kernel_reboot_attempts kernel-uek "6.12.0-1.aarch64" 2
    assert_equals "2" "$(read_kernel_reboot_attempts kernel-uek '6.12.0-1.aarch64')" "same target"
    assert_equals "0" "$(read_kernel_reboot_attempts kernel-uek '6.12.0-2.aarch64')" \
        "a new target starts a fresh budget"
}

test_state_attempts_cleared_when_target_runs_unflagged() {
    load_needs_reboot_library
    # A host with a correct clock: after the reboot into the target kernel,
    # needs-restarting flags nothing, and the row must still go.
    export STUB_UNAME_R="4.18.0-553.170.1.el8_10.x86_64" STUB_UNAME_M=x86_64
    write_kernel_reboot_attempts kernel "4.18.0-553.170.1.el8_10.x86_64" 1 old-boot
    write_kernel_reboot_attempts kernel-uek "6.12.0-9.el9uek.aarch64" 2 old-boot
    run_needs_restarting() { return 0; }
    ( main ) >/dev/null 2>&1
    assert_equals "0" "$(read_kernel_reboot_attempts kernel '4.18.0-553.170.1.el8_10.x86_64')" \
        "the reboot reached its target"
    assert_equals "2" "$(read_kernel_reboot_attempts kernel-uek '6.12.0-9.el9uek.aarch64')" \
        "a target that is not running keeps its count"
}

test_state_attempts_cleared_for_arch_stripped_release() {
    load_needs_reboot_library
    export STUB_UNAME_R="6.12.0-9.el9uek" STUB_UNAME_M=aarch64
    write_kernel_reboot_attempts kernel-uek "6.12.0-9.el9uek.aarch64" 1 old-boot
    clear_kernel_reboot_attempts_for_running_kernel >/dev/null
    assert_equals "0" "$(read_kernel_reboot_attempts kernel-uek '6.12.0-9.el9uek.aarch64')" \
        "uname -r without the arch suffix matches"
}

test_state_attempts_kept_while_old_kernel_runs() {
    load_needs_reboot_library
    export STUB_UNAME_R="4.18.0-553.169.1.el8_10.x86_64" STUB_UNAME_M=x86_64
    write_kernel_reboot_attempts kernel "4.18.0-553.170.1.el8_10.x86_64" 1 old-boot
    clear_kernel_reboot_attempts_for_running_kernel >/dev/null
    assert_equals "1" "$(read_kernel_reboot_attempts kernel '4.18.0-553.170.1.el8_10.x86_64')" \
        "a boot that came back on the old kernel keeps the count"
}

test_state_kernel_attempts_cleared() {
    load_needs_reboot_library
    write_kernel_reboot_attempts kernel-uek "6.12.0-1.aarch64" 2
    write_kernel_reboot_attempts kernel-uek "-" 0
    assert_equals "0" "$(read_kernel_reboot_attempts kernel-uek '6.12.0-1.aarch64')" "cleared"
}

# ---------------------------------------------------------------------------
# learning: a confirmation must never outlive the EVR it was made for
# ---------------------------------------------------------------------------
test_learning_never_overrules_a_build_id_mismatch() {
    load_needs_reboot_library
    # systemd is in filter_packages; its build-id check finds journald stale.
    # A restart-state row from an earlier boot says "confirmed" for this EVR.
    export STUB_RPM_EVR="252-67.0.2.el9_8.6"
    write_restart_state systemd "252-67.0.2.el9_8.6" "boot-old" confirmed
    verify_build_id() { return 2; }
    FLAGGED_PACKAGE_NAMES=(systemd)
    classify_flagged_packages >/dev/null 2>&1
    apply_restart_state_learning >/dev/null 2>&1
    assert_equals "systemd" "${REBOOT_TRIGGER_PACKAGES[*]:-}" "a proven stale binary reboots"
    assert_equals "boot-old" "$(read_restart_state systemd | cut -f3)" "and learning leaves its row untouched"
}

test_learning_does_not_confirm_an_unverifiable_package() {
    load_needs_reboot_library
    export STUB_RPM_EVR="252-67.0.2.el9_8.6"
    write_restart_state systemd "252-67.0.2.el9_8.6" "boot-old" pending
    verify_build_id() { return 1; }
    FLAGGED_PACKAGE_NAMES=(systemd)
    classify_flagged_packages >/dev/null 2>&1
    apply_restart_state_learning >/dev/null 2>&1
    assert_equals "systemd" "${REBOOT_TRIGGER_PACKAGES[*]:-}" "cannot tell keeps the package"
    assert_equals "pending" "$(read_restart_state systemd | cut -f5)" "and is never promoted to confirmed"
}

test_learning_confirmed_same_evr_is_skipped() {
    load_needs_reboot_library
    export STUB_RPM_EVR="2.34-274"
    write_restart_state glibc "2.34-274" "boot-old" confirmed
    REBOOT_TRIGGER_PACKAGES=(glibc)
    LEARNABLE_PACKAGE_NAMES=( ["glibc"]=1 )
    apply_restart_state_learning >/dev/null 2>&1
    assert_equals "0" "${#REBOOT_TRIGGER_PACKAGES[@]}" "confirmed false positive is dropped"
}

test_learning_pending_after_reboot_is_confirmed() {
    load_needs_reboot_library
    export STUB_RPM_EVR="2.34-274"
    # Recorded under a different boot_id: a reboot has genuinely happened and
    # the package is still flagged, which proves the flag spurious.
    write_restart_state glibc "2.34-274" "boot-old" pending
    REBOOT_TRIGGER_PACKAGES=(glibc)
    LEARNABLE_PACKAGE_NAMES=( ["glibc"]=1 )
    apply_restart_state_learning >/dev/null 2>&1
    assert_equals "0" "${#REBOOT_TRIGGER_PACKAGES[@]}" "dropped after confirmation"
    assert_contains "$(read_restart_state glibc)" "confirmed" "state promoted"
}

test_learning_pending_same_boot_still_reboots() {
    load_needs_reboot_library
    export STUB_RPM_EVR="2.34-274"
    write_restart_state glibc "2.34-274" "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" pending
    REBOOT_TRIGGER_PACKAGES=(glibc)
    LEARNABLE_PACKAGE_NAMES=( ["glibc"]=1 )
    apply_restart_state_learning >/dev/null 2>&1
    assert_equals "1" "${#REBOOT_TRIGGER_PACKAGES[@]}" \
        "no reboot yet, so the flag is unproven and must still trigger one"
}

test_learning_new_evr_restarts_cycle() {
    load_needs_reboot_library
    export STUB_RPM_EVR="2.34-999"
    # An old confirmation must never mask a genuine later update.
    write_restart_state glibc "2.34-274" "boot-old" confirmed
    REBOOT_TRIGGER_PACKAGES=(glibc)
    LEARNABLE_PACKAGE_NAMES=( ["glibc"]=1 )
    apply_restart_state_learning >/dev/null 2>&1
    assert_equals "1" "${#REBOOT_TRIGGER_PACKAGES[@]}" "new evr must trigger a reboot"
    assert_contains "$(read_restart_state glibc)" "pending" "fresh unverified cycle"
}

# ---------------------------------------------------------------------------
# classify: the whole decision, end to end
# ---------------------------------------------------------------------------
test_classify_withholds_on_stale_grub_default() {
    load_needs_reboot_library
    export STUB_UNAME_R="6.12.0-204.92.4.3.1.el9uek.aarch64"
    export STUB_RPM_KERNEL_VERSIONS="6.12.0-204.92.4.4.el9uek.aarch64"
    export STUB_GRUBBY_DEFAULT="/boot/vmlinuz-6.12.0-204.92.4.3.1.el9uek.aarch64"
    FLAGGED_PACKAGE_NAMES=(kernel-uek)
    classify_flagged_packages >/dev/null 2>&1
    assert_equals "0" "${#REBOOT_TRIGGER_PACKAGES[@]}" "no reboot into a kernel GRUB will not select"
    assert_equals "1" "${REBOOT_WITHHELD}" "condition is recorded as withheld"
}

test_classify_withholds_at_attempt_limit() {
    load_needs_reboot_library
    export STUB_UNAME_R="6.12.0-204.92.4.3.1.el9uek.aarch64"
    export STUB_RPM_KERNEL_VERSIONS="6.12.0-204.92.4.4.el9uek.aarch64"
    export STUB_GRUBBY_DEFAULT="/boot/vmlinuz-6.12.0-204.92.4.4.el9uek.aarch64"
    write_kernel_reboot_attempts kernel-uek "6.12.0-204.92.4.4.el9uek.aarch64" 3
    FLAGGED_PACKAGE_NAMES=(kernel-uek)
    classify_flagged_packages >/dev/null 2>&1
    assert_equals "0" "${#REBOOT_TRIGGER_PACKAGES[@]}" "loop guard stops further reboots"
    assert_equals "1" "${REBOOT_WITHHELD}" "condition is recorded as withheld"
}

test_classify_unrecorded_attempt_withholds_the_reboot() {
    load_needs_reboot_library
    export STUB_UNAME_R="6.12.0-204.92.4.3.1.el9uek.aarch64"
    export STUB_RPM_KERNEL_VERSIONS="6.12.0-204.92.4.4.el9uek.aarch64"
    export STUB_GRUBBY_DEFAULT="/boot/vmlinuz-6.12.0-204.92.4.4.el9uek.aarch64"
    # A directory where the state lock belongs: every attempt write fails.
    rm -f "${STATE_LOCK_FILE}"
    mkdir -p "${STATE_LOCK_FILE}"
    local boot_number
    for boot_number in 1 2 3 4 5; do
        printf 'boot-%s\n' "${boot_number}" > "${TEST_ROOT_DIR}/proc/sys/kernel/random/boot_id"
        FLAGGED_PACKAGE_NAMES=(kernel-uek)
        classify_flagged_packages >/dev/null 2>&1
        assert_equals "0" "${#REBOOT_TRIGGER_PACKAGES[@]}" "boot ${boot_number}: no reboot without a recorded attempt"
        assert_equals "1" "${REBOOT_WITHHELD}" "boot ${boot_number}: withheld, so the run fails and reports it"
    done
}

test_classify_schedules_genuine_kernel_reboot() {
    load_needs_reboot_library
    export STUB_UNAME_R="6.12.0-204.92.4.3.1.el9uek.aarch64"
    export STUB_RPM_KERNEL_VERSIONS="6.12.0-204.92.4.4.el9uek.aarch64"
    export STUB_GRUBBY_DEFAULT="/boot/vmlinuz-6.12.0-204.92.4.4.el9uek.aarch64"
    FLAGGED_PACKAGE_NAMES=(kernel-uek)
    classify_flagged_packages >/dev/null 2>&1
    assert_equals "1" "${#REBOOT_TRIGGER_PACKAGES[@]}" "genuine kernel update reboots"
    assert_equals "1" "$(read_kernel_reboot_attempts kernel-uek '6.12.0-204.92.4.4.el9uek.aarch64')" \
        "attempt recorded"
}

test_classify_repeated_checks_in_one_boot_count_once() {
    load_needs_reboot_library
    export STUB_UNAME_R="6.12.0-204.92.4.3.1.el9uek.aarch64"
    export STUB_RPM_KERNEL_VERSIONS="6.12.0-204.92.4.4.el9uek.aarch64"
    export STUB_GRUBBY_DEFAULT="/boot/vmlinuz-6.12.0-204.92.4.4.el9uek.aarch64"
    FLAGGED_PACKAGE_NAMES=(kernel-uek)
    # The helper run by hand, the watchdog's check and the timer run all
    # classify without a reboot in between.  Only reboots may use the budget.
    local check_number
    for check_number in 1 2 3 4; do
        classify_flagged_packages >/dev/null 2>&1
    done
    assert_equals "1" "${#REBOOT_TRIGGER_PACKAGES[@]}" "the fourth check in one boot still reboots"
    assert_equals "1" "$(read_kernel_reboot_attempts kernel-uek '6.12.0-204.92.4.4.el9uek.aarch64')" \
        "one boot counts one attempt"
    printf 'ffffffff-0000-1111-2222-333333333333\n' > "${BOOT_ID_FILE}"
    classify_flagged_packages >/dev/null 2>&1
    assert_equals "2" "$(read_kernel_reboot_attempts kernel-uek '6.12.0-204.92.4.4.el9uek.aarch64')" \
        "a boot still on the old kernel counts the next attempt"
}

test_classify_keeps_package_when_verifier_missing() {
    load_needs_reboot_library
    # Removing elfutils must not silently drop systemd from the decision.
    unset -f eu-readelf
    PATH=/nonexistent
    FLAGGED_PACKAGE_NAMES=(systemd)
    classify_flagged_packages >/dev/null 2>&1
    assert_equals "1" "${#REBOOT_TRIGGER_PACKAGES[@]}" \
        "unverifiable systemd must be treated as genuine"
}

# ---------------------------------------------------------------------------
# decision: only a recognisable plugin result may reboot the host
# ---------------------------------------------------------------------------
# DNF output with a cache-only failure, as dnf prints it and exits 1.
readonly CACHE_ONLY_ERROR="Error: Cache-only enabled but no cache for 'ol9_baseos_latest'"

# stub_needs_restarting CACHE_ONLY_RESULT REFRESHED_RESULT
# Stubs timeout(1), through which the script runs dnf, so no exec is needed.
# Each result is "EXIT_CODE:STDOUT"; calls are recorded in the stub log.
stub_needs_restarting() {
    export STUB_CACHE_ONLY_RESULT="$1" STUB_REFRESHED_RESULT="$2"
    timeout() {
        local result="${STUB_REFRESHED_RESULT}" argument
        shift
        printf 'dnf %s\n' "${*:2}" >> "${STUB_LOG}"
        for argument in "$@"; do
            [[ "${argument}" == "-C" ]] && result="${STUB_CACHE_ONLY_RESULT}"
        done
        printf '%s\n' "${result#*:}"
        return "${result%%:*}"
    }
}

test_decision_dnf_error_does_not_reboot() {
    load_needs_reboot_library
    # dnf exits 1 for errors it handles, the same code the plugin uses for
    # "reboot required".  Without a package line it is no reboot decision.
    stub_needs_restarting "1:${CACHE_ONLY_ERROR}" "1:${CACHE_ONLY_ERROR}"
    local exit_code=0
    ( main ) >/dev/null 2>&1 || exit_code=$?
    assert_exit_code 2 "${exit_code}" "a dnf error is undecidable, never a reboot"
}

test_decision_cache_miss_retries_with_refresh() {
    load_needs_reboot_library
    stub_needs_restarting "1:${CACHE_ONLY_ERROR}" "1:Core libraries or services have been updated since boot-up:
  * glibc"
    local exit_code=0
    run_needs_restarting >/dev/null 2>&1 || exit_code=$?
    assert_exit_code 1 "${exit_code}" "the refreshed run's result is used"
    assert_equals "2" "$(grep -c 'needs-restarting' "${STUB_LOG}")" "retried after the cache-only error"
    assert_contains "${NEEDS_RESTARTING_OUTPUT}" "* glibc" "refreshed output kept"
}

test_decision_temporary_file_failure_removes_nothing() {
    load_needs_reboot_library
    stub_needs_restarting "0:" "0:"
    mktemp() { return 1; }
    rm() { printf 'rm %s\n' "$*" >> "${STUB_LOG}"; }
    local exit_code=0
    run_needs_restarting >/dev/null 2>&1 || exit_code=$?
    assert_not_contains "$(cat "${STUB_LOG}")" "/dev/null" "never removes a path mktemp did not create"
    [[ "${exit_code}" -gt 1 ]] || fail "expected a tool-error exit, got ${exit_code}"
}

# ---------------------------------------------------------------------------
# run: no update without the inhibitor lock
# ---------------------------------------------------------------------------
# stub_run_main: stubs every step of run.sh's main that would reach the host.
# systemd-inhibit runs its command unless STUB_INHIBITOR_REFUSED=yes; timeout,
# through which dnf-automatic runs, exits STUB_DNF_AUTOMATIC_RC.
stub_run_main() {
    check_conflicts() { :; }
    warn_on_unapplied_security_advisories() { :; }
    pgrep() { return 1; }
    systemd-inhibit() {
        printf 'systemd-inhibit %s\n' "$*" >> "${STUB_LOG}"
        [[ "${STUB_INHIBITOR_REFUSED:-}" == "yes" ]] && return 1
        while [[ "$1" == --* ]]; do shift; done
        "$@"
    }
    timeout() {
        printf 'timeout %s\n' "$*" >> "${STUB_LOG}"
        return "${STUB_DNF_AUTOMATIC_RC:-0}"
    }
    run_reboot_check() { return "${STUB_NEEDS_REBOOT_RC:-0}"; }
    read_scheduled_reboot_status() { printf '%s' "${STUB_SCHEDULED_REBOOT_STATUS:-none}"; }
    schedule_reboot() {
        printf 'schedule_reboot reboot_pending_file=%s\n' "$(file_presence "${REBOOT_PENDING_FILE}")" >> "${STUB_LOG}"
        [[ "${STUB_SCHEDULE_FAILS:-}" == "yes" ]] && return 1
        [[ "${STUB_SCHEDULE_UNKNOWN:-}" == "yes" ]] && return 2
        [[ "${STUB_SCHEDULE_INTERRUPTED:-}" == "yes" ]] && kill -TERM "${BASHPID}"
        return 0
    }
}

# stub_service_restarts: timeout(1) runs dnf-automatic successfully, lists
# STUB_STALE_SERVICES for needs-restarting -s, and exits with the
# STUB_RESTART_RC_<unit stem> of each try-restart, 0 when unset.
stub_service_restarts() {
    timeout() {
        local unit_name rc_variable
        printf 'timeout %s\n' "$*" >> "${STUB_LOG}"
        if [[ "$*" == *needs-restarting* ]]; then
            printf '%s\n' "${STUB_STALE_SERVICES:-}"
            return 0
        fi
        if [[ "$*" == *try-restart* ]]; then
            unit_name="${*: -1}"
            rc_variable="STUB_RESTART_RC_${unit_name%.service}"
            return "${!rc_variable:-0}"
        fi
        return 0
    }
}

test_run_pending_restart_fails_the_run() {
    load_run_library
    stub_run_main
    stub_service_restarts
    export STUB_STALE_SERVICES="sshd.service"
    export STUB_RESTART_RC_sshd=124
    local exit_code=0 output
    output=$( main 2>&1 ) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "a restart that did not finish fails the run"
    assert_contains "${output}" "Updates installed; no reboot needed; restart still pending for sshd.service. Check: systemctl status sshd.service" \
        "one summary names the pending restart and the command to check it"
    assert_not_contains "${output}" "No stale services needed restarting" "never reported as nothing to do"
}

test_run_failed_restart_fails_the_run() {
    load_run_library
    stub_run_main
    stub_service_restarts
    export STUB_STALE_SERVICES="sshd.service
nginx.service"
    export STUB_RESTART_RC_nginx=1
    local exit_code=0 output
    output=$( main 2>&1 ) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "a failed restart fails the run"
    assert_contains "${output}" "restarted sshd.service; restart FAILED for nginx.service" "both outcomes named"
}

test_run_completion_summary_names_every_outcome() {
    load_run_library
    stub_run_main
    stub_service_restarts
    export STUB_STALE_SERVICES="sshd.service
dbus.service"
    local exit_code=0 output
    output=$( main 2>&1 ) || exit_code=$?
    assert_exit_code 0 "${exit_code}" "an excluded unit is by design, not a failure"
    assert_contains "${output}" "Updates installed; no reboot needed; restarted sshd.service; excluded from restart, still on pre-update code: dbus.service" \
        "one line for the whole run"
}

test_run_service_restarts_stay_supervised() {
    load_run_library
    stub_run_main
    # A try-restart can block; the watchdog only sees a run whose state file
    # exists, so the file must outlive the restarts.
    restart_stale_services() {
        printf 'restarting with state: %s\n' \
            "$(grep '^phase=' "${STATE_FILE}" 2>/dev/null || printf 'none')" >> "${STUB_LOG}"
    }
    ( main ) >/dev/null 2>&1
    assert_contains "$(cat "${STUB_LOG}")" "restarting with state: phase=checking" \
        "the watchdog still supervises the restarts"
    [[ -f "${STATE_FILE}" ]] && fail "the state file must be removed when the run exits"
    return 0
}

test_services_restart_is_bounded() {
    load_run_library
    timeout() {
        printf 'timeout %s\n' "$*" >> "${STUB_LOG}"
        if [[ "$*" == *needs-restarting* ]]; then
            printf 'sshd.service\n'
            return 0
        fi
        return 124
    }
    local output
    output=$(restart_stale_services 2>&1)
    assert_contains "$(cat "${STUB_LOG}")" "timeout 300s ${TEST_ROOT_DIR}/usr/bin/systemctl try-restart sshd.service" \
        "each restart runs under the configured bound"
    assert_contains "${output}" "did not finish within 300s" "an expired restart is reported"
}

test_reboot_is_scheduled_on_a_named_unit() {
    load_run_library
    schedule_reboot >/dev/null 2>&1
    assert_exit_code 0 "$?" "dispatch succeeds"
    local dispatch_call
    dispatch_call=$(grep '^systemd-run' "${STUB_LOG}")
    assert_contains "${dispatch_call}" "--unit=dnf-automatic-reboot-scheduled-reboot" "an operator can find the reboot"
    assert_contains "${dispatch_call}" "OnFailure=dnf-automatic-reboot-notify@dnf-automatic-reboot-scheduled-reboot.service.service" \
        "a reboot that fails to start is reported"
    assert_contains "${dispatch_call}" "--on-active=300" "after the configured delay"
    assert_contains "${dispatch_call}" "reboot-if-pending.sh no 60" \
        "through the pending check, never --force, waiting the configured lock time"
    assert_contains "${SCHEDULED_REBOOT_SUMMARY}" "cancel with: /usr/libexec/dnf-automatic-reboot/cancel-reboot.sh" \
        "the summary says how to cancel it"
}

test_reboot_already_scheduled_is_not_scheduled_twice() {
    load_run_library
    export STUB_REBOOT_TIMER_LOAD_STATE=loaded STUB_REBOOT_TIMER_SUB_STATE=waiting
    schedule_reboot >/dev/null 2>&1
    assert_exit_code 0 "$?" "an active reboot timer is success"
    assert_not_contains "$(cat "${STUB_LOG}")" "systemd-run" "no second transient unit"
}

test_run_scheduled_reboot_holds_update_runs() {
    load_run_library
    stub_run_main
    export STUB_NEEDS_REBOOT_RC=1
    local exit_code=0
    ( main ) >/dev/null 2>&1 || exit_code=$?
    assert_exit_code 0 "${exit_code}" "the reboot is scheduled"
    assert_contains "$(cat "${STUB_LOG}")" "schedule_reboot reboot_pending_file=present" \
        "marked pending before the request"
    [[ -f "${REBOOT_PENDING_FILE}" ]] || fail "no update may start before the scheduled reboot"
    return 0
}

test_run_failed_schedule_removes_its_marker() {
    load_run_library
    stub_run_main
    export STUB_NEEDS_REBOOT_RC=1 STUB_SCHEDULE_FAILS=yes
    local exit_code=0
    ( main ) >/dev/null 2>&1 || exit_code=$?
    assert_exit_code 1 "${exit_code}" "a failed dispatch fails the run"
    [[ -f "${REBOOT_PENDING_FILE}" ]] && fail "no reboot is pending, so runs must be allowed again"
    return 0
}

test_run_interrupted_request_keeps_its_marker() {
    load_run_library
    stub_run_main
    export STUB_NEEDS_REBOOT_RC=1 STUB_SCHEDULE_INTERRUPTED=yes
    local exit_code=0 output
    output=$( ( main ) 2>&1 ) || exit_code=$?
    [[ "${exit_code}" -ne 0 ]] || fail "a stopped run is not a success"
    [[ -f "${REBOOT_PENDING_FILE}" ]] || fail "an interrupted request keeps update runs blocked"
    assert_contains "${output}" "reached systemd is unknown" "the unknown outcome is reported"
}

test_run_helper_failure_fails_the_run() {
    load_run_library
    stub_run_main
    # A missing or broken helper exits 126 or 127; that is no verdict.
    export STUB_NEEDS_REBOOT_RC=127
    local exit_code=0 output
    output=$( main 2>&1 ) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "an unexpected helper status fails the run"
    assert_not_contains "${output}" "No reboot required" "not reported as a clean result"
    assert_not_contains "$(cat "${STUB_LOG}")" "schedule_reboot" "and does not reboot"
}

test_run_refused_inhibitor_stops_the_update() {
    load_run_library
    stub_run_main
    export STUB_INHIBITOR_REFUSED=yes
    local exit_code=0
    ( main ) >/dev/null 2>&1 || exit_code=$?
    assert_exit_code 1 "${exit_code}" "the run fails"
    assert_equals "0" "$(grep -c "^timeout" "${STUB_LOG}")" "dnf-automatic never starts without the lock"
}

test_run_update_runs_inside_the_inhibitor() {
    load_run_library
    stub_run_main
    run_dnf_automatic_under_inhibitor >/dev/null 2>&1
    local inhibitor_call
    inhibitor_call=$(grep '^systemd-inhibit' "${STUB_LOG}")
    assert_contains "${inhibitor_call}" "--mode=block" "a blocking lock"
    assert_contains "${inhibitor_call}" "timeout --kill-after=" "the update is the lock's own command"
    assert_contains "${inhibitor_call}" "/usr/bin/dnf-automatic" "dnf-automatic runs under it"
}

# ---------------------------------------------------------------------------
# services: restarting the wrong unit takes the host down
# ---------------------------------------------------------------------------
test_conflicts_refuse_apply_updates_off() {
    load_run_library
    systemctl() { return 1; }
    # Changed after install: every run would download and install nothing.
    printf 'reboot = never\napply_updates = no\n' > "${TEST_ROOT_DIR}/etc/dnf/automatic.conf"
    local output exit_code=0
    output=$( check_conflicts 2>&1 ) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "run refused"
    assert_contains "${output}" "apply_updates = no" "names the setting"
}

test_conflicts_pass_on_prepared_host() {
    load_run_library
    systemctl() { return 1; }
    local exit_code=0
    ( check_conflicts ) >/dev/null 2>&1 || exit_code=$?
    assert_exit_code 0 "${exit_code}" "reboot = never and apply_updates = yes pass"
}

test_services_excluded_units_are_not_restarted() {
    load_run_library
    export STUB_STALE_SERVICES="sshd.service
dbus.service
nginx.service"
    restart_stale_services >/dev/null 2>&1
    local recorded_calls
    recorded_calls=$(cat "${STUB_LOG}")
    assert_contains "${recorded_calls}" "try-restart sshd.service" "sshd restarted"
    assert_contains "${recorded_calls}" "try-restart nginx.service" "nginx restarted"
    assert_not_contains "${recorded_calls}" "try-restart dbus.service" \
        "dbus must never be restarted from under a running system"
}

# ---------------------------------------------------------------------------
# repositories: unattended installs from an unsigned repo must be visible
# ---------------------------------------------------------------------------
test_repositories_unsigned_enabled_is_reported() {
    load_run_library
    mkdir -p "${TEST_ROOT_DIR}/etc/yum.repos.d"
    printf '[ol9_baseos]\nenabled=1\ngpgcheck=1\n\n[local_unsigned]\nenabled=1\ngpgcheck=0\n' \
        > "${TEST_ROOT_DIR}/etc/yum.repos.d/test.repo"
    local reported
    reported=$(warn_on_unsigned_repositories 2>&1)
    assert_contains "${reported}" "local_unsigned" "unsigned enabled repo is named"
    assert_not_contains "${reported}" "ol9_baseos" "signed repo is not named"
}

test_repositories_unsigned_but_disabled_is_ignored() {
    load_run_library
    mkdir -p "${TEST_ROOT_DIR}/etc/yum.repos.d"
    # A disabled repo installs nothing, so reporting it would be noise that
    # operators learn to ignore.
    printf '[local_unsigned]\nenabled=0\ngpgcheck=0\n' \
        > "${TEST_ROOT_DIR}/etc/yum.repos.d/test.repo"
    assert_not_contains "$(warn_on_unsigned_repositories 2>&1)" "local_unsigned" \
        "disabled repo is not reported"
}

test_repositories_all_signed_is_silent() {
    load_run_library
    mkdir -p "${TEST_ROOT_DIR}/etc/yum.repos.d"
    printf '[ol9_baseos]\nenabled=1\ngpgcheck=1\n[ol9_UEKR8]\ngpgcheck=1\n' \
        > "${TEST_ROOT_DIR}/etc/yum.repos.d/test.repo"
    assert_equals "" "$(warn_on_unsigned_repositories 2>&1)" "no report when everything is signed"
}

# ---------------------------------------------------------------------------
# advisories: an advisory dnf refuses to install must never pass as success
# ---------------------------------------------------------------------------
test_advisories_unappliable_is_an_error() {
    load_run_library
    # What gw looked like: updateinfo names two advisories, the depsolver
    # resolves to nothing because a repository priority= masks the newer build.
    export STUB_SECURITY_ADVISORIES="ELSA-2026-26533 Important/Sec. dracut-057-115.git20260527.0.1.el9_8.aarch64
ELSA-2025-15874 Moderate/Sec.  python3-cryptography-36.0.1-5.el9_6.aarch64"
    export STUB_CHECK_UPDATE_RC=0
    local reported
    reported=$(warn_on_unapplied_security_advisories 2>&1)
    # sort -u, so the order is deterministic rather than dnf's output order.
    assert_contains "${reported}" "ELSA-2025-15874,ELSA-2026-26533" "both advisory ids named"
    assert_contains "${reported}" "will not install" "reported at error level"
}

test_advisories_red_hat_colon_ids_are_matched() {
    load_run_library
    # Red Hat's id shape, as listed on a RHEL 8 host.  A dash-only pattern
    # matched none of these, so the warning never fired on RHEL.
    export STUB_SECURITY_ADVISORIES="RHSA-2020:3011              Moderate/Sec.  NetworkManager-1:1.22.8-5.el8_2.x86_64"
    export STUB_CHECK_UPDATE_RC=0
    assert_contains "$(warn_on_unapplied_security_advisories 2>&1)" "RHSA-2020:3011" \
        "a colon-separated advisory id is reported"
}

test_advisories_oracle_revision_suffix_is_matched() {
    load_run_library
    # Oracle's id with a revision suffix, as listed on an OL9 host.
    export STUB_SECURITY_ADVISORIES="ELSA-2026-60226-0 Moderate/Sec.  attr-2.6.0-1.el9_8.aarch64"
    export STUB_CHECK_UPDATE_RC=0
    assert_contains "$(warn_on_unapplied_security_advisories 2>&1)" "ELSA-2026-60226-0" \
        "an advisory id with a revision suffix is reported"
}

test_advisories_epel_ids_are_matched() {
    load_run_library
    # EPEL's id form: dash-joined prefix, hexadecimal number; listed with the
    # leading spaces an updateinfo line for a pending advisory carries.
    export STUB_SECURITY_ADVISORIES="  FEDORA-EPEL-2024-bf31852fe0 Moderate/Sec.  w3m-0.5.3-63.git20230121.el8.x86_64"
    export STUB_CHECK_UPDATE_RC=0
    assert_contains "$(warn_on_unapplied_security_advisories 2>&1)" "FEDORA-EPEL-2024-bf31852fe0" \
        "an EPEL advisory id is reported"
}

test_advisories_still_pending_is_only_a_warning() {
    load_run_library
    export STUB_SECURITY_ADVISORIES="ELSA-2026-26533 Important/Sec. dracut-057-115.el9_8.aarch64"
    export STUB_CHECK_UPDATE_RC=100
    # 100 means dnf can still install them, so this is not the stuck case.
    assert_not_contains "$(warn_on_unapplied_security_advisories 2>&1)" "will not install" \
        "appliable advisories are not an error"
}

test_advisories_none_is_silent() {
    load_run_library
    export STUB_SECURITY_ADVISORIES=""
    export STUB_CHECK_UPDATE_RC=0
    assert_equals "" "$(warn_on_unapplied_security_advisories 2>&1)" "nothing to report"
}

test_advisories_ignores_non_advisory_lines() {
    load_run_library
    # Only PREFIX-YEAR-NUMBER shaped first fields count, so a stray metadata or
    # warning line cannot be reported as an advisory id.
    export STUB_SECURITY_ADVISORIES="Last metadata expiration check: 0:00:02 ago on Fri 31 Jul 2026.
ELSA-2026-26533 Important/Sec. dracut-057-115.el9_8.aarch64"
    export STUB_CHECK_UPDATE_RC=0
    local reported
    reported=$(warn_on_unapplied_security_advisories 2>&1)
    assert_contains "${reported}" "ELSA-2026-26533" "real advisory reported"
    assert_not_contains "${reported}" "metadata" "header line is not an advisory"
}

test_advisories_disabled_by_config() {
    load_run_library
    WARN_UNAPPLIED_ADVISORIES=no
    export STUB_SECURITY_ADVISORIES="ELSA-2026-26533 Important/Sec. dracut-057-115.el9_8.aarch64"
    export STUB_CHECK_UPDATE_RC=0
    assert_equals "" "$(warn_on_unapplied_security_advisories 2>&1)" "silent when disabled"
}

test_services_template_units_are_excluded_by_glob() {
    load_run_library
    # Restarting these ends a user's services and sessions, or logs out a
    # console; needs-restarting -s reports them like any other unit.
    local unit_name
    for unit_name in user@1000.service getty@tty1.service serial-getty@ttyS0.service \
                     autovt@tty2.service dbus-broker.service dnf-automatic-reboot.service; do
        is_excluded_unit "${unit_name}" || fail "${unit_name} must be excluded by the default list"
    done
    for unit_name in sshd.service nginx.service user-runtime-dir@1000.service; do
        is_excluded_unit "${unit_name}" && fail "${unit_name} must not be excluded"
    done
    return 0
}

test_wall_messages_trailing_comment_is_not_part_of_the_value() {
    load_run_library
    printf 'wall_messages = no  # quiet\n' > "${TEST_ROOT_DIR}/etc/dnf/automatic-reboot.conf"
    wall_msg "dnf-automatic-reboot: test message"
    assert_not_contains "$(cat "${STUB_LOG}")" "wall " "wall_messages = no with a comment disables wall"
}

test_services_disabled_by_config() {
    load_run_library
    RESTART_SERVICES=no
    export STUB_STALE_SERVICES="sshd.service"
    restart_stale_services >/dev/null 2>&1
    assert_not_contains "$(cat "${STUB_LOG}")" "try-restart" "nothing restarted when disabled"
}

# ---------------------------------------------------------------------------
# watchdog: never reboot a host whose rpm transaction may be half-applied
# ---------------------------------------------------------------------------
# Uptime of the fake host, in seconds; the watchdog reads it from proc/uptime.
readonly TEST_UPTIME_SECONDS=100000

# write_watchdog_state PHASE AGE_MINUTES PID [WALL_CLOCK_AGE_MINUTES]
# The run is AGE_MINUTES old on the boot clock.  WALL_CLOCK_AGE_MINUTES, which
# defaults to the same, is how old it looks by the wall clock.
# The stub systemctl reports the recorded pid as MainPID unless a test has
# set STUB_MAIN_PID.
write_watchdog_state() {
    local run_phase="$1" age_minutes="$2" recorded_pid="$3"
    local wall_clock_age_minutes="${4:-$2}"
    export STUB_MAIN_PID="${STUB_MAIN_PID-${recorded_pid}}"
    printf '%s.42 0.00\n' "${TEST_UPTIME_SECONDS}" > "${TEST_ROOT_DIR}/proc/uptime"
    printf 'phase=%s\nstart=%s\nstart_uptime=%s\npid=%s\n' \
        "${run_phase}" "$(( $(date +%s) - wall_clock_age_minutes * 60 ))" \
        "$(( TEST_UPTIME_SECONDS - age_minutes * 60 ))" "${recorded_pid}" \
        > "${TEST_ROOT_DIR}/run/dnf-automatic-reboot.state"
}

test_watchdog_ignores_wall_clock_step() {
    sleep 60 &
    local background_pid=$! watchdog_output
    # No RTC: the run started before chrony stepped the clock forward three
    # days.  By the wall clock it is far past the hard timeout; it is actually
    # two minutes old and its rpm transaction must be left alone.
    write_watchdog_state updating 2 "${background_pid}" $(( 3 * 24 * 60 ))
    watchdog_output=$(bash "${REPO_ROOT}/scripts/watchdog.sh" 2>&1)
    kill "${background_pid}" 2>/dev/null
    assert_contains "${watchdog_output}" "elapsed=2min" "elapsed time comes from the boot clock"
    assert_not_contains "$(cat "${STUB_LOG}")" "systemctl kill" "a young run is never killed"
}

test_watchdog_state_without_uptime_is_malformed() {
    sleep 60 &
    local background_pid=$!
    # Only a pre-1.4 run.sh wrote this shape, and %pre refuses to install over
    # one.  Nothing may be timed from the wall clock.
    printf 'phase=updating\nstart=%s\npid=%s\n' \
        "$(( $(date +%s) - 200 * 60 ))" "${background_pid}" \
        > "${TEST_ROOT_DIR}/run/dnf-automatic-reboot.state"
    bash "${REPO_ROOT}/scripts/watchdog.sh" >/dev/null 2>&1
    kill "${background_pid}" 2>/dev/null
    assert_not_contains "$(cat "${STUB_LOG}")" "systemctl kill" "a wall-clock age never kills a run"
    [[ -f "${TEST_ROOT_DIR}/run/dnf-automatic-reboot.state" ]] \
        && fail "a state file without start_uptime should have been removed"
    return 0
}

test_watchdog_no_state_file_is_a_noop() {
    local exit_code=0
    bash "${REPO_ROOT}/scripts/watchdog.sh" >/dev/null 2>&1 || exit_code=$?
    assert_exit_code 0 "${exit_code}" "no state file"
    assert_equals "" "$(cat "${STUB_LOG}")" "no privileged action taken"
}

test_watchdog_dead_pid_does_not_reboot() {
    # PID 2 belongs to the kernel and is never our run.sh, but it is alive, so
    # use a pid that cannot exist instead.
    write_watchdog_state updating 200 4194304
    bash "${REPO_ROOT}/scripts/watchdog.sh" >/dev/null 2>&1
    assert_not_contains "$(cat "${STUB_LOG}")" "systemctl reboot" "a crashed run must not reboot"
    assert_not_contains "$(cat "${STUB_LOG}")" "systemd-run" "a crashed run must not schedule a reboot"
    [[ -f "${TEST_ROOT_DIR}/run/dnf-automatic-reboot.state" ]] \
        && fail "stale state file should have been removed"
    return 0
}

test_watchdog_warning_reaches_the_stub_not_the_host() {
    # The watchdog runs as a child process; its wall warning for a dead run
    # must land in the stub log, which proves it never reached the real wall.
    write_watchdog_state updating 200 4194304
    bash "${REPO_ROOT}/scripts/watchdog.sh" >/dev/null 2>&1
    assert_contains "$(cat "${STUB_LOG}")" "wall dnf-automatic-reboot: WARNING" \
        "the child process used the exported wall stub"
}

test_watchdog_hard_timeout_while_updating_does_not_reboot() {
    sleep 60 &
    local background_pid=$!
    write_watchdog_state updating 200 "${background_pid}"
    bash "${REPO_ROOT}/scripts/watchdog.sh" >/dev/null 2>&1
    kill "${background_pid}" 2>/dev/null
    local recorded_calls
    recorded_calls=$(cat "${STUB_LOG}")
    assert_contains "${recorded_calls}" "kill --kill-whom=all" "whole cgroup is killed"
    assert_not_contains "${recorded_calls}" "systemd-run" \
        "a half-applied rpm transaction must not be rebooted into"
}

test_watchdog_hard_timeout_while_updating_can_be_forced() {
    sed -i 's/^force_reboot_on_hard_timeout = no/force_reboot_on_hard_timeout = yes/' \
        "${TEST_ROOT_DIR}/etc/dnf/automatic-reboot.conf"
    sleep 60 &
    local background_pid=$!
    write_watchdog_state updating 200 "${background_pid}"
    bash "${REPO_ROOT}/scripts/watchdog.sh" >/dev/null 2>&1
    kill "${background_pid}" 2>/dev/null
    assert_contains "$(cat "${STUB_LOG}")" "reboot-if-pending.sh yes" "opt-in override still works"
}

test_watchdog_hard_timeout_while_checking_reboots() {
    sleep 60 &
    local background_pid=$!
    # phase=checking means dnf-automatic already returned cleanly.
    write_watchdog_state checking 200 "${background_pid}"
    bash "${REPO_ROOT}/scripts/watchdog.sh" >/dev/null 2>&1
    kill "${background_pid}" 2>/dev/null
    local recorded_calls
    recorded_calls=$(cat "${STUB_LOG}")
    assert_contains "${recorded_calls}" "kill --kill-whom=all" "whole cgroup is killed"
    assert_contains "${recorded_calls}" "reboot-if-pending.sh yes" "safe to reboot after a clean dnf"
}

test_watchdog_kill_option_follows_systemd_version() {
    load_watchdog_library
    # Surveyed: systemd 239 (EL8) accepts only --kill-who, 252 (EL9) both.
    assert_equals "--kill-who=all"  "$(systemctl_kill_target_option 239)" "EL8 systemd"
    assert_equals "--kill-whom=all" "$(systemctl_kill_target_option 252)" "EL9 systemd"
    assert_equals "--kill-who=all"  "$(systemctl_kill_target_option '')" \
        "an unreadable version takes the spelling every surveyed version accepts"
}

test_watchdog_hard_timeout_on_systemd_239_kills_with_kill_who() {
    export STUB_SYSTEMD_VERSION=239
    sleep 60 &
    local background_pid=$!
    write_watchdog_state updating 200 "${background_pid}"
    bash "${REPO_ROOT}/scripts/watchdog.sh" >/dev/null 2>&1
    kill "${background_pid}" 2>/dev/null
    assert_contains "$(cat "${STUB_LOG}")" "kill --kill-who=all" "EL8 spelling used on systemd 239"
}

test_watchdog_reused_pid_is_not_the_run() {
    sleep 60 &
    local background_pid=$!
    # The run died and its PID now belongs to an unrelated process; systemd
    # reports the unit inactive (MainPID 0).  Past the hard timeout the
    # watchdog must not kill that process or reboot.
    export STUB_MAIN_PID=0
    write_watchdog_state checking 200 "${background_pid}"
    bash "${REPO_ROOT}/scripts/watchdog.sh" >/dev/null 2>&1
    local process_survived=no
    kill -0 "${background_pid}" 2>/dev/null && process_survived=yes
    kill "${background_pid}" 2>/dev/null
    assert_equals "yes" "${process_survived}" "the unrelated process is left running"
    assert_not_contains "$(cat "${STUB_LOG}")" "systemctl reboot" "no reboot for a run that is gone"
    assert_not_contains "$(cat "${STUB_LOG}")" "systemd-run" "no scheduled reboot for a run that is gone"
    assert_not_contains "$(cat "${STUB_LOG}")" "systemctl kill" "no cgroup kill for a run that is gone"
}

test_watchdog_hung_reboot_check_is_undecidable() {
    load_watchdog_library
    # The check the watchdog runs when the main run is stuck in phase=checking
    # can hang the same way; it must end, or no later cycle reaches the hard
    # timeout.
    timeout() { printf 'timeout %s\n' "$*" >> "${STUB_LOG}"; return 124; }
    run_independent_reboot_check >/dev/null 2>&1
    assert_exit_code 2 "$?" "a check that did not finish is undecidable, never a reboot"
    assert_contains "$(cat "${STUB_LOG}")" "360s ${TEST_ROOT_DIR}/usr/libexec/dnf-automatic-reboot/needs-reboot.sh" \
        "bounded at three needs-restarting timeouts"
}

# stub_watchdog_host: stubs what the sourced watchdog would reach on the host.
# MainPID comes from STUB_MAIN_PID, which write_watchdog_state sets.
stub_watchdog_host() {
    pgrep() { return 1; }
    ss() { :; }
    unit_main_pid() { printf '%s' "${STUB_MAIN_PID:-}"; }
    kill_service_cgroup() { printf 'kill_service_cgroup\n' >> "${STUB_LOG}"; }
    schedule_reboot() { printf 'schedule_reboot\n' >> "${STUB_LOG}"; }
}

# stub_watchdog_kill_path: like stub_watchdog_host, but keeps the real
# kill_service_cgroup.  The cgroup kill succeeds unless STUB_KILL_FAILS=yes,
# and records whether the recovery file existed; systemd reports the unit
# STUB_ACTIVE_STATE, failed by default.
stub_watchdog_kill_path() {
    pgrep() { return 1; }
    ss() { :; }
    unit_main_pid() { printf '%s' "${STUB_MAIN_PID:-}"; }
    unit_active_state() { printf '%s' "${STUB_ACTIVE_STATE:-failed}"; }
    signal_unit_processes() {
        printf 'signal_unit_processes recovery_file=%s\n' \
            "$([[ -f "${RECOVERY_FILE}" ]] && printf present || printf absent)" >> "${STUB_LOG}"
        [[ "${STUB_KILL_FAILS:-}" == "yes" ]] && return 1
        return 0
    }
    submit_reboot() {
        printf 'submit_reboot delay=%s force=%s recovery_file=%s state_file=%s reboot_pending_file=%s\n' \
            "$1" "$2" "$(file_presence "${RECOVERY_FILE}")" "$(file_presence "${STATE_FILE}")" \
            "$(file_presence "${REBOOT_PENDING_FILE}")" >> "${STUB_LOG}"
    }
    schedule_reboot() {
        printf 'schedule_reboot recovery_file=%s reboot_pending_file=%s\n' \
            "$(file_presence "${RECOVERY_FILE}")" "$(file_presence "${REBOOT_PENDING_FILE}")" >> "${STUB_LOG}"
        [[ "${STUB_SCHEDULE_FAILS:-}" == "yes" ]] && return 1
        [[ "${STUB_SCHEDULE_UNKNOWN:-}" == "yes" ]] && return 2
        [[ "${STUB_SCHEDULE_INTERRUPTED:-}" == "yes" ]] && kill -TERM "${BASHPID}"
        return 0
    }
    read_scheduled_reboot_status() { printf '%s' "${STUB_SCHEDULED_REBOOT_STATUS:-none}"; }
}

# file_presence PATH -> present or absent
file_presence() {
    if [[ -e "$1" ]]; then printf present; else printf absent; fi
}

test_watchdog_failed_kill_keeps_supervision() {
    sleep 60 &
    local background_pid=$! exit_code=0
    load_watchdog_library
    write_watchdog_state checking 200 "${background_pid}"
    stub_watchdog_kill_path
    export STUB_KILL_FAILS=yes
    ( main ) >/dev/null 2>&1 || exit_code=$?
    kill "${background_pid}" 2>/dev/null
    assert_exit_code 1 "${exit_code}" "a failed kill fails the watchdog"
    assert_not_contains "$(cat "${STUB_LOG}")" "submit_reboot" "no reboot over a run that may still be updating"
    [[ -f "${STATE_FILE}" ]] || fail "the state file must survive a failed kill"
    [[ -f "${RECOVERY_FILE}" ]] && fail "the recovery file must be removed"
    return 0
}

test_watchdog_unconfirmed_kill_signals_no_pid() {
    sleep 60 &
    local background_pid=$! exit_code=0
    load_watchdog_library
    write_watchdog_state checking 200 "${background_pid}"
    stub_watchdog_kill_path
    export STUB_ACTIVE_STATE=activating
    KILL_CONFIRM_SEC=1
    # The unit is still active after the kill.  Its recorded PID number may
    # belong to another process by now, so it is never signalled on its own.
    ( main ) >/dev/null 2>&1 || exit_code=$?
    local process_survived=no
    kill -0 "${background_pid}" 2>/dev/null && process_survived=yes
    kill "${background_pid}" 2>/dev/null
    assert_exit_code 1 "${exit_code}" "an unconfirmed kill fails the watchdog"
    assert_equals "yes" "${process_survived}" "the PID is not signalled directly"
    assert_not_contains "$(cat "${STUB_LOG}")" "submit_reboot" "and nothing is rebooted"
    [[ -f "${STATE_FILE}" ]] || fail "the state file must survive an unconfirmed kill"
    return 0
}

test_watchdog_no_run_starts_during_the_kill() {
    sleep 60 &
    local background_pid=$! exit_code=0
    load_watchdog_library
    write_watchdog_state checking 200 "${background_pid}"
    stub_watchdog_kill_path
    ( main ) >/dev/null 2>&1 || exit_code=$?
    kill "${background_pid}" 2>/dev/null
    assert_exit_code 0 "${exit_code}" "a confirmed kill at the hard timeout succeeds"
    assert_contains "$(cat "${STUB_LOG}")" "signal_unit_processes recovery_file=present" \
        "the main unit is blocked from starting while its run is killed"
    # A run starting after the kill would have its state file removed and
    # be rebooted under; the marker must outlast the reboot request.
    assert_contains "$(cat "${STUB_LOG}")" "submit_reboot delay=0 force=yes recovery_file=present state_file=absent reboot_pending_file=present" \
        "no run can start between the state cleanup and the reboot"
    [[ -f "${REBOOT_PENDING_FILE}" ]] || fail "the reboot-pending marker must stay until the reboot"
    [[ -f "${RECOVERY_FILE}" ]] && fail "the recovery marker ends with recovery"
    return 0
}

test_watchdog_scheduled_reboot_keeps_runs_blocked() {
    sleep 60 &
    local background_pid=$! exit_code=0
    load_watchdog_library
    write_watchdog_state checking 70 "${background_pid}"
    stub_watchdog_kill_path
    run_independent_reboot_check() { return 1; }
    ( main ) >/dev/null 2>&1 || exit_code=$?
    kill "${background_pid}" 2>/dev/null
    assert_exit_code 0 "${exit_code}" "the reboot is scheduled"
    assert_contains "$(cat "${STUB_LOG}")" "schedule_reboot recovery_file=present reboot_pending_file=present" \
        "blocked through the decision, and marked pending before the request"
    [[ -f "${REBOOT_PENDING_FILE}" ]] || fail "no update may start before the scheduled reboot"
    [[ -f "${RECOVERY_FILE}" ]] && fail "the recovery marker ends with recovery"
    return 0
}

test_watchdog_recovery_without_reboot_allows_runs_again() {
    sleep 60 &
    local background_pid=$! exit_code=0
    load_watchdog_library
    # phase=updating at the hard timeout: killed, not rebooted.
    write_watchdog_state updating 200 "${background_pid}"
    stub_watchdog_kill_path
    ( main ) >/dev/null 2>&1 || exit_code=$?
    kill "${background_pid}" 2>/dev/null
    assert_exit_code 0 "${exit_code}" "recovery completes"
    assert_not_contains "$(cat "${STUB_LOG}")" "submit_reboot" "no reboot while updating"
    [[ -f "${RECOVERY_FILE}" ]] && fail "with no reboot pending the next run must be allowed"
    return 0
}

test_watchdog_failed_schedule_allows_runs_again() {
    sleep 60 &
    local background_pid=$! exit_code=0
    load_watchdog_library
    write_watchdog_state checking 70 "${background_pid}"
    stub_watchdog_kill_path
    export STUB_SCHEDULE_FAILS=yes
    run_independent_reboot_check() { return 1; }
    ( main ) >/dev/null 2>&1 || exit_code=$?
    kill "${background_pid}" 2>/dev/null
    assert_exit_code 1 "${exit_code}" "the failed dispatch fails the watchdog"
    [[ -f "${RECOVERY_FILE}" ]] && fail "no reboot is pending, so runs must be allowed again"
    [[ -f "${REBOOT_PENDING_FILE}" ]] && fail "a request that definitely failed removes its own marker"
    return 0
}

test_watchdog_markers_block_the_main_unit() {
    grep -qx 'ConditionPathExists=!/run/dnf-automatic-reboot.recovery' \
        "${REPO_ROOT}/units/dnf-automatic-reboot.service" \
        || fail "dnf-automatic-reboot.service must not start while the watchdog kills a run"
    grep -qx 'ConditionPathExists=!/run/dnf-automatic-reboot.reboot-pending' \
        "${REPO_ROOT}/units/dnf-automatic-reboot.service" \
        || fail "dnf-automatic-reboot.service must not start while a reboot is pending"
    grep -qx 'ExecStopPost=/usr/bin/rm -f /run/dnf-automatic-reboot.recovery' \
        "${REPO_ROOT}/units/dnf-automatic-watchdog.service" \
        || fail "the recovery file must never outlive the watchdog"
    grep '^ExecStopPost' "${REPO_ROOT}/units/dnf-automatic-watchdog.service" | grep -q 'reboot-pending' \
        && fail "the watchdog unit must never remove the reboot-pending marker"
    return 0
}

test_watchdog_later_failure_keeps_a_pending_reboot() {
    sleep 60 &
    local background_pid=$! exit_code=0
    load_watchdog_library
    # A reboot requested earlier is still pending when a later watchdog cycle
    # fails for an unrelated reason.
    : > "${REBOOT_PENDING_FILE}"
    write_watchdog_state checking 200 "${background_pid}"
    stub_watchdog_kill_path
    export STUB_KILL_FAILS=yes
    ( main ) >/dev/null 2>&1 || exit_code=$?
    kill "${background_pid}" 2>/dev/null
    assert_exit_code 1 "${exit_code}" "the later watchdog fails"
    [[ -f "${REBOOT_PENDING_FILE}" ]] || fail "the pending reboot must keep update runs blocked"
    [[ -f "${RECOVERY_FILE}" ]] && fail "the failed recovery's own marker is removed"
    return 0
}

test_watchdog_interrupted_request_keeps_a_marker() {
    sleep 60 &
    local background_pid=$! exit_code=0 output
    load_watchdog_library
    write_watchdog_state checking 70 "${background_pid}"
    stub_watchdog_kill_path
    run_independent_reboot_check() { return 1; }
    # Stopped at TimeoutStartSec= while systemd-run is submitting the reboot:
    # whether the timer exists is unknown.
    export STUB_SCHEDULE_INTERRUPTED=yes
    output=$( ( main ) 2>&1 ) || exit_code=$?
    kill "${background_pid}" 2>/dev/null
    assert_exit_code 143 "${exit_code}" "the watchdog was terminated"
    [[ -f "${REBOOT_PENDING_FILE}" ]] || fail "an interrupted request must never leave both markers absent"
    assert_contains "${output}" "reached systemd is unknown" "the unknown outcome is reported"
    assert_contains "${output}" "cancel-reboot.sh" "with the recovery command"
}

test_watchdog_failed_request_keeps_an_earlier_marker() {
    sleep 60 &
    local background_pid=$! exit_code=0
    load_watchdog_library
    : > "${REBOOT_PENDING_FILE}"
    write_watchdog_state checking 70 "${background_pid}"
    stub_watchdog_kill_path
    export STUB_SCHEDULE_FAILS=yes
    run_independent_reboot_check() { return 1; }
    ( main ) >/dev/null 2>&1 || exit_code=$?
    kill "${background_pid}" 2>/dev/null
    assert_exit_code 1 "${exit_code}" "the failed dispatch fails the watchdog"
    [[ -f "${REBOOT_PENDING_FILE}" ]] || fail "a failed request removes only the marker it created"
    return 0
}

test_watchdog_reports_a_marker_left_by_the_killed_run() {
    sleep 60 &
    local background_pid=$! exit_code=0 output
    load_watchdog_library
    # The stuck run was killed while it requested a reboot; no timer exists.
    : > "${REBOOT_PENDING_FILE}"
    write_watchdog_state checking 70 "${background_pid}"
    stub_watchdog_kill_path
    run_independent_reboot_check() { return 0; }
    output=$( ( main ) 2>&1 ) || exit_code=$?
    kill "${background_pid}" 2>/dev/null
    assert_exit_code 1 "${exit_code}" "blocked update runs reach OnFailure="
    assert_contains "${output}" "no reboot is scheduled" "the leftover marker is named"
    [[ -f "${REBOOT_PENDING_FILE}" ]] || fail "the watchdog does not decide the outcome for the operator"
    return 0
}

test_watchdog_replaced_run_is_not_killed() {
    sleep 60 &
    local original_pid=$! replacement_pid exit_code=0 output
    sleep 60 &
    replacement_pid=$!
    export REPLACEMENT_PID="${replacement_pid}"
    load_watchdog_library
    write_watchdog_state checking 70 "${original_pid}"
    pgrep() { return 1; }
    ss() { :; }
    unit_main_pid() { cat "${TEST_ROOT_DIR}/main-pid"; }
    printf '%s' "${original_pid}" > "${TEST_ROOT_DIR}/main-pid"
    schedule_reboot() { printf 'schedule_reboot\n' >> "${STUB_LOG}"; }
    # While the watchdog checks, the stuck run ends and the next run starts
    # updating.  The old verdict must not kill it or reboot the host.
    run_independent_reboot_check() {
        printf 'phase=updating\nstart=0\nstart_uptime=%s\npid=%s\n' \
            "$(( TEST_UPTIME_SECONDS - 60 ))" "${REPLACEMENT_PID}" > "${STATE_FILE}"
        printf '%s' "${REPLACEMENT_PID}" > "${TEST_ROOT_DIR}/main-pid"
        return 1
    }
    output=$( main 2>&1 ) || exit_code=$?
    local replacement_survived=no
    kill -0 "${replacement_pid}" 2>/dev/null && replacement_survived=yes
    kill "${original_pid}" "${replacement_pid}" 2>/dev/null
    assert_exit_code 0 "${exit_code}" "a run that ended normally is no failure"
    assert_equals "yes" "${replacement_survived}" "the replacement run is left running"
    assert_not_contains "${output}" "systemctl kill" "no cgroup kill"
    assert_not_contains "$(cat "${STUB_LOG}")" "schedule_reboot" "no reboot on the old verdict"
    assert_contains "$(cat "${STATE_FILE}")" "phase=updating" "the replacement's state file is kept"
}

test_watchdog_unknown_identity_is_not_acted_on() {
    sleep 60 &
    local background_pid=$! exit_code=0 output
    load_watchdog_library
    export STUB_MAIN_PID=""
    write_watchdog_state checking 200 "${background_pid}"
    stub_watchdog_host
    submit_reboot() { printf 'submit_reboot\n' >> "${STUB_LOG}"; }
    # Past the hard timeout, but systemctl reports no MainPID: the live PID
    # may not be the run.
    output=$( main 2>&1 ) || exit_code=$?
    kill "${background_pid}" 2>/dev/null
    assert_exit_code 1 "${exit_code}" "an unestablished identity fails the watchdog"
    assert_not_contains "$(cat "${STUB_LOG}")" "kill_service_cgroup" "nothing is killed"
    assert_not_contains "$(cat "${STUB_LOG}")" "submit_reboot" "and nothing is rebooted"
}

test_watchdog_dispatch_failure_fails_the_watchdog() {
    sleep 60 &
    local background_pid=$! exit_code=0
    load_watchdog_library
    write_watchdog_state checking 70 "${background_pid}"
    stub_watchdog_host
    kill_service_cgroup() { return 0; }
    schedule_reboot() { return 1; }
    run_independent_reboot_check() { return 1; }
    ( main ) >/dev/null 2>&1 || exit_code=$?
    kill "${background_pid}" 2>/dev/null
    assert_exit_code 1 "${exit_code}" "a reboot that could not be scheduled reaches OnFailure="
}

test_watchdog_helper_failure_is_not_no_reboot() {
    sleep 60 &
    local background_pid=$! exit_code=0 output
    load_watchdog_library
    # Past the soft timeout in phase=checking with dnf idle: the watchdog runs
    # its own check.  Everything that reaches the host is stubbed.
    write_watchdog_state checking 70 "${background_pid}"
    stub_watchdog_host
    run_independent_reboot_check() { return 127; }
    output=$( main 2>&1 ) || exit_code=$?
    kill "${background_pid}" 2>/dev/null
    assert_exit_code 1 "${exit_code}" "an unexpected helper status fails the watchdog"
    assert_not_contains "${output}" "no reboot needed" "not reported as a clean result"
    assert_not_contains "$(cat "${STUB_LOG}")" "schedule_reboot" "and does not reboot"
}

test_watchdog_unit_has_a_start_timeout() {
    # A oneshot's start timeout is disabled by default; a hung watchdog would
    # not exit, and the timer would not start the next cycle.
    local start_timeout
    start_timeout=$(sed -n 's/^TimeoutStartSec=//p' "${REPO_ROOT}/units/dnf-automatic-watchdog.service")
    [[ -n "${start_timeout}" && "${start_timeout}" != "infinity" ]] \
        || fail "dnf-automatic-watchdog.service needs a finite TimeoutStartSec, has [${start_timeout}]"
}

test_watchdog_reboots_through_the_pending_check() {
    sleep 60 &
    local background_pid=$!
    write_watchdog_state checking 200 "${background_pid}"
    bash "${REPO_ROOT}/scripts/watchdog.sh" >/dev/null 2>&1
    kill "${background_pid}" 2>/dev/null
    assert_not_contains "$(cat "${STUB_LOG}")" "systemctl reboot" \
        "the watchdog never reboots directly, only through reboot-if-pending.sh"
    assert_contains "$(cat "${STUB_LOG}")" "--unit=dnf-automatic-reboot-scheduled-reboot" "on the named unit"
    assert_not_contains "$(cat "${STUB_LOG}")" "--on-active" "at once"
}

# ---------------------------------------------------------------------------
# cancel: a reboot is cancelled only while it is known not to happen
# ---------------------------------------------------------------------------
# stub_reboot_unit_state: stubs every systemd observation and action of
# reboot-request.sh.  The scheduled-reboot timer reports
# STUB_TIMER_LOAD_STATE (loaded) and STUB_TIMER_SUB_STATE (waiting); its
# service STUB_SERVICE_LOAD_STATE (not-found), STUB_SERVICE_ACTIVE_STATE
# (inactive) and STUB_SERVICE_JOB (no Job line).  STUB_PROPERTY_READ_FAILS=yes
# makes every read fail.  The host reports STUB_SYSTEM_STATE (running) and
# logind STUB_PREPARING_FOR_SHUTDOWN ("b false").  systemd-run exits
# STUB_SYSTEMD_RUN_RC (0) and, with STUB_TIMER_SUB_STATE_AFTER_SUBMIT, leaves
# the timer loaded in that state.  systemctl reboot exits STUB_REBOOT_RC (0),
# --force STUB_FORCE_REBOOT_RC (0).  State changes go through files, since
# each read runs in a command substitution.
stub_reboot_unit_state() {
    stub_property() {
        local override_file="${TEST_ROOT_DIR}/stub-$1-$2"
        if [[ -f "${override_file}" ]]; then
            cat "${override_file}"
        else
            printf '%s' "$3"
        fi
    }
    get_unit_properties() {
        [[ "${STUB_PROPERTY_READ_FAILS:-}" == "yes" ]] && return 1
        case "$1" in
            *.timer)
                printf 'LoadState=%s\nActiveState=inactive\nSubState=%s\n' \
                    "$(stub_property timer LoadState "${STUB_TIMER_LOAD_STATE-loaded}")" \
                    "$(stub_property timer SubState "${STUB_TIMER_SUB_STATE-waiting}")"
                ;;
            *.service)
                printf 'LoadState=%s\nActiveState=%s\nSubState=dead\n' \
                    "${STUB_SERVICE_LOAD_STATE-not-found}" "${STUB_SERVICE_ACTIVE_STATE-inactive}"
                [[ -n "${STUB_SERVICE_JOB:-}" ]] && printf 'Job=%s\n' "${STUB_SERVICE_JOB}"
                ;;
        esac
        return 0
    }
    get_system_state() { printf '%s' "${STUB_SYSTEM_STATE-running}"; }
    get_logind_preparing_for_shutdown() {
        [[ "${STUB_LOGIND_READ_FAILS:-}" == "yes" ]] && return 1
        printf '%s' "${STUB_PREPARING_FOR_SHUTDOWN-b false}"
    }
    stop_unit() {
        printf 'stop %s\n' "$1" >> "${STUB_LOG}"
        [[ "${STUB_STOP_FAILS:-}" == "yes" ]] && return 1
        return 0
    }
    reset_failed_units() { printf 'reset-failed %s\n' "$*" >> "${STUB_LOG}"; }
    start_reboot_unit() {
        printf 'systemd-run %s\n' "$*" >> "${STUB_LOG}"
        if [[ -n "${STUB_TIMER_SUB_STATE_AFTER_SUBMIT:-}" ]]; then
            printf 'loaded' > "${TEST_ROOT_DIR}/stub-timer-LoadState"
            printf '%s' "${STUB_TIMER_SUB_STATE_AFTER_SUBMIT}" > "${TEST_ROOT_DIR}/stub-timer-SubState"
        fi
        if [[ "${STUB_STATE_UNREADABLE_AFTER_SUBMIT:-}" == "yes" ]]; then
            printf 'error' > "${TEST_ROOT_DIR}/stub-timer-LoadState"
        fi
        return "${STUB_SYSTEMD_RUN_RC:-0}"
    }
    reboot_host() {
        printf 'reboot %s\n' "$*" >> "${STUB_LOG}"
        if [[ "${1:-}" == "--force" ]]; then
            return "${STUB_FORCE_REBOOT_RC:-0}"
        fi
        return "${STUB_REBOOT_RC:-0}"
    }
}

# load_cancel_reboot_library: sources cancel-reboot.sh with every systemd
# observation stubbed, and a pending marker in place.
load_cancel_reboot_library() {
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/scripts/cancel-reboot.sh"
    set +e
    IFS=$' \t\n'
    stub_reboot_unit_state
    : > "${REBOOT_PENDING_FILE}"
}

# run_cancel -> cancel-reboot.sh's exit code; its output goes to
# ${TEST_ROOT_DIR}/cancel.out.
run_cancel() {
    local exit_code=0
    ( main ) > "${TEST_ROOT_DIR}/cancel.out" 2>&1 || exit_code=$?
    return "${exit_code}"
}

# assert_cancel_refused DESCRIPTION - cancel-reboot.sh exits 1 and keeps the
# marker.
assert_cancel_refused() {
    local exit_code=0
    run_cancel || exit_code=$?
    assert_exit_code 1 "${exit_code}" "$1"
    assert_contains "$(cat "${TEST_ROOT_DIR}/cancel.out")" "NOT cancelled" "the operator is told"
    [[ -f "${REBOOT_PENDING_FILE}" ]] || fail "$1: the marker must stay"
}

# assert_cancel_succeeds DESCRIPTION - cancel-reboot.sh exits 0 and removes
# the marker.
assert_cancel_succeeds() {
    local exit_code=0
    run_cancel || exit_code=$?
    assert_exit_code 0 "${exit_code}" "$1: $(cat "${TEST_ROOT_DIR}/cancel.out")"
    [[ -f "${REBOOT_PENDING_FILE}" ]] && fail "$1: update runs must be allowed again"
    return 0
}

# load_reboot_if_pending_library: sources reboot-if-pending.sh with every
# systemd observation and action stubbed.
load_reboot_if_pending_library() {
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/scripts/reboot-if-pending.sh"
    set +e
    IFS=$' \t\n'
    stub_reboot_unit_state
}

# run_reboot_if_pending FORCE_ALLOWED -> its exit code; output goes to
# ${TEST_ROOT_DIR}/reboot.out.
run_reboot_if_pending() {
    local exit_code=0
    ( main "$1" 1 ) > "${TEST_ROOT_DIR}/reboot.out" 2>&1 || exit_code=$?
    return "${exit_code}"
}

test_cancel_stops_the_timer_and_allows_runs() {
    load_cancel_reboot_library
    assert_cancel_succeeds "a waiting reboot is cancelled"
    assert_contains "$(cat "${STUB_LOG}")" "stop dnf-automatic-reboot-scheduled-reboot.timer" "the timer is stopped"
}

test_cancel_then_a_late_firing_does_not_reboot() {
    # The reported interleavings: the timer stopped after it had queued the
    # service, or a submission systemd processes only after the cancellation.
    # Either way reboot-if-pending.sh runs after the cancellation.
    (
        load_cancel_reboot_library
        export STUB_SERVICE_LOAD_STATE=loaded STUB_SERVICE_JOB=4711
        assert_cancel_succeeds "a queued job that has not reached systemctl reboot"
    ) || fail "cancellation"
    load_reboot_if_pending_library
    local exit_code=0
    run_reboot_if_pending no || exit_code=$?
    assert_exit_code 0 "${exit_code}" "a cancelled reboot is no failure"
    assert_not_contains "$(cat "${STUB_LOG}")" "reboot " "and does not reboot"
    [[ -f "${REBOOT_DISPATCHED_FILE}" ]] && fail "nothing was dispatched"
    return 0
}

test_cancel_refuses_after_the_reboot_command_ran() {
    load_cancel_reboot_library
    : > "${REBOOT_DISPATCHED_FILE}"
    export STUB_TIMER_LOAD_STATE=not-found STUB_TIMER_SUB_STATE=dead
    assert_cancel_refused "a dispatched reboot is never reported as cancelled"
}

test_cancel_refuses_while_shutting_down() {
    load_cancel_reboot_library
    export STUB_TIMER_LOAD_STATE=not-found STUB_TIMER_SUB_STATE=dead STUB_SYSTEM_STATE=stopping
    assert_cancel_refused "a reboot in progress is never reported as cancelled"
}

test_cancel_refuses_a_shutdown_logind_delays() {
    load_cancel_reboot_library
    # logind accepted a reboot and holds it for a delay inhibitor; PID 1
    # still reports running.
    export STUB_TIMER_LOAD_STATE=not-found STUB_TIMER_SUB_STATE=dead \
           STUB_PREPARING_FOR_SHUTDOWN="b true"
    assert_cancel_refused "a delayed shutdown is never reported as cancelled"
}

test_cancel_refuses_unreadable_systemd_state() {
    load_cancel_reboot_library
    export STUB_PROPERTY_READ_FAILS=yes
    assert_cancel_refused "unreadable unit state"
}

test_cancel_refuses_unrecognised_states() {
    local property_setting
    for property_setting in STUB_TIMER_LOAD_STATE= STUB_TIMER_SUB_STATE= \
                            STUB_SERVICE_LOAD_STATE=masked STUB_SERVICE_ACTIVE_STATE= \
                            STUB_SERVICE_JOB=garbage STUB_SYSTEM_STATE= STUB_SYSTEM_STATE=offline \
                            STUB_PREPARING_FOR_SHUTDOWN= STUB_LOGIND_READ_FAILS=yes; do
        (
            load_cancel_reboot_library
            export "${property_setting?}"
            assert_cancel_refused "${property_setting}"
        ) || fail "${property_setting} must refuse the cancellation"
    done
    return 0
}

test_cancel_accepts_a_degraded_host() {
    load_cancel_reboot_library
    # is-system-running exits non-zero for degraded; the state is still known.
    export STUB_SYSTEM_STATE=degraded
    assert_cancel_succeeds "degraded is not stopping"
}

test_cancel_refuses_while_a_request_holds_the_lock() {
    load_cancel_reboot_library
    # A request created the marker and has not yet reached systemd.
    export STUB_TIMER_LOAD_STATE=not-found STUB_TIMER_SUB_STATE=dead
    exec {held_lock_descriptor}>>"${REBOOT_REQUEST_LOCK_FILE}"
    flock "${held_lock_descriptor}"
    assert_cancel_refused "a request in progress"
    assert_contains "$(cat "${TEST_ROOT_DIR}/cancel.out")" "is in progress" "named as such"
}

test_cancel_after_a_failed_reboot_allows_runs() {
    load_cancel_reboot_library
    export STUB_TIMER_LOAD_STATE=not-found STUB_TIMER_SUB_STATE=dead \
           STUB_SERVICE_LOAD_STATE=loaded STUB_SERVICE_ACTIVE_STATE=failed
    assert_cancel_succeeds "a reboot that was refused"
}

test_cancel_with_nothing_pending_is_a_noop() {
    load_cancel_reboot_library
    rm -f "${REBOOT_PENDING_FILE}"
    export STUB_TIMER_LOAD_STATE=not-found STUB_TIMER_SUB_STATE=dead
    local exit_code=0
    run_cancel || exit_code=$?
    assert_exit_code 0 "${exit_code}" "nothing to cancel"
    assert_not_contains "$(cat "${STUB_LOG}")" "stop " "nothing is stopped"
}

# ---------------------------------------------------------------------------
# reboot: reboot-if-pending.sh reboots only while the reboot is pending
# ---------------------------------------------------------------------------
test_reboot_pending_reboots_and_records_it() {
    load_reboot_if_pending_library
    : > "${REBOOT_PENDING_FILE}"
    local exit_code=0
    run_reboot_if_pending no || exit_code=$?
    assert_exit_code 0 "${exit_code}" "the reboot is submitted"
    assert_contains "$(cat "${STUB_LOG}")" "reboot " "systemctl reboot is called"
    [[ -f "${REBOOT_DISPATCHED_FILE}" ]] || fail "the dispatch is recorded for cancel-reboot.sh"
    return 0
}

test_reboot_accepted_by_logind_is_not_forced() {
    load_reboot_if_pending_library
    : > "${REBOOT_PENDING_FILE}"
    # The client failed, but logind accepted the shutdown and delays it.
    export STUB_REBOOT_RC=1 STUB_PREPARING_FOR_SHUTDOWN="b true"
    local exit_code=0
    run_reboot_if_pending yes || exit_code=$?
    assert_exit_code 0 "${exit_code}" "an accepted shutdown is success"
    assert_not_contains "$(cat "${STUB_LOG}")" "reboot --force" "an orderly shutdown under way is never forced"
}

test_reboot_unknown_shutdown_state_is_not_forced() {
    load_reboot_if_pending_library
    : > "${REBOOT_PENDING_FILE}"
    export STUB_REBOOT_RC=1 STUB_LOGIND_READ_FAILS=yes
    local exit_code=0
    run_reboot_if_pending yes || exit_code=$?
    assert_exit_code 1 "${exit_code}" "an unknown outcome fails the unit"
    assert_not_contains "$(cat "${STUB_LOG}")" "reboot --force" "unknown is not a refusal"
    [[ -f "${REBOOT_DISPATCHED_FILE}" ]] || fail "an unknown outcome keeps cancellation refused"
    return 0
}

test_reboot_refused_on_a_running_host_is_forced_when_allowed() {
    load_reboot_if_pending_library
    : > "${REBOOT_PENDING_FILE}"
    export STUB_REBOOT_RC=1
    local exit_code=0
    run_reboot_if_pending yes || exit_code=$?
    assert_exit_code 0 "${exit_code}" "the forced reboot is submitted"
    assert_contains "$(cat "${STUB_LOG}")" "reboot --force" "a leaked inhibitor lock is overridden"
}

test_reboot_refused_without_force_releases_the_dispatch() {
    load_reboot_if_pending_library
    : > "${REBOOT_PENDING_FILE}"
    export STUB_REBOOT_RC=1
    local exit_code=0
    run_reboot_if_pending no || exit_code=$?
    assert_exit_code 1 "${exit_code}" "a refused reboot fails the unit, so OnFailure= reports it"
    assert_not_contains "$(cat "${STUB_LOG}")" "reboot --force" "never forced unless allowed"
    [[ -f "${REBOOT_DISPATCHED_FILE}" ]] && fail "a refused reboot can be cancelled"
    [[ -f "${REBOOT_PENDING_FILE}" ]] || fail "update runs stay held until a reboot or cancellation"
    return 0
}

test_reboot_waits_for_a_cancellation_in_progress() {
    load_reboot_if_pending_library
    : > "${REBOOT_PENDING_FILE}"
    exec {held_lock_descriptor}>>"${REBOOT_REQUEST_LOCK_FILE}"
    flock "${held_lock_descriptor}"
    local exit_code=0
    run_reboot_if_pending no || exit_code=$?
    assert_exit_code 1 "${exit_code}" "no lock, no reboot"
    assert_not_contains "$(cat "${STUB_LOG}")" "reboot " "nothing is rebooted"
}

# ---------------------------------------------------------------------------
# lock: only root can open, and so hold, the reboot request lock
# ---------------------------------------------------------------------------
test_lock_is_created_owner_only() {
    load_request_library
    umask 022
    acquire_reboot_request_lock 1 || fail "the lock is free"
    assert_equals "600" "$(stat -c '%a' "${REBOOT_REQUEST_LOCK_FILE}")" "created 0600 under umask 022"
}

test_lock_permissions_are_corrected_in_place() {
    load_request_library
    ( umask 022 && : > "${REBOOT_REQUEST_LOCK_FILE}" )
    chmod 0644 "${REBOOT_REQUEST_LOCK_FILE}"
    local inode_before
    inode_before=$(stat -c '%i' "${REBOOT_REQUEST_LOCK_FILE}")
    acquire_reboot_request_lock 1 || fail "the lock is free"
    assert_equals "600" "$(stat -c '%a' "${REBOOT_REQUEST_LOCK_FILE}")" "a readable lock is closed"
    assert_equals "${inode_before}" "$(stat -c '%i' "${REBOOT_REQUEST_LOCK_FILE}")" \
        "the inode a holder or waiter uses is kept"
}

test_lock_is_shipped_owner_only() {
    grep -qx 'f /run/dnf-automatic-reboot.reboot-request.lock 0600 root root -' \
        "${REPO_ROOT}/tmpfiles/dnf-automatic-reboot.conf" \
        || fail "tmpfiles.d must create the lock 0600 root"
}

# ---------------------------------------------------------------------------
# request: accepted, rejected or unknown, under the lock
# ---------------------------------------------------------------------------
# load_request_library: sources run.sh, whose reboot-request.sh is the one
# watchdog.sh, cancel-reboot.sh and reboot-if-pending.sh use, with systemd
# stubbed and no reboot scheduled yet.
load_request_library() {
    load_run_library
    stub_reboot_unit_state
    export STUB_TIMER_LOAD_STATE=not-found STUB_TIMER_SUB_STATE=dead
}

test_request_cancel_during_dispatch_cannot_drop_the_marker() {
    load_request_library
    # The marker exists, the timer does not yet, and cancel-reboot.sh runs.
    start_reboot_unit() {
        local cancel_exit_code=0
        bash "${REPO_ROOT}/scripts/cancel-reboot.sh" >> "${STUB_LOG}" 2>&1 || cancel_exit_code=$?
        printf 'cancel during dispatch exited %s\n' "${cancel_exit_code}" >> "${STUB_LOG}"
        return 0
    }
    local exit_code=0
    request_reboot 1 schedule_reboot >/dev/null 2>&1 || exit_code=$?
    assert_exit_code 0 "${exit_code}" "the reboot is scheduled"
    assert_contains "$(cat "${STUB_LOG}")" "cancel during dispatch exited 1" "the cancellation is refused"
    assert_contains "$(cat "${STUB_LOG}")" "is in progress" "because the request holds the lock"
    [[ -f "${REBOOT_PENDING_FILE}" ]] || fail "a scheduled reboot must keep update runs held"
    return 0
}

test_request_waits_for_the_lock_then_gives_up() {
    load_request_library
    exec {held_lock_descriptor}>>"${REBOOT_REQUEST_LOCK_FILE}"
    flock "${held_lock_descriptor}"
    local exit_code=0
    request_reboot 1 schedule_reboot >/dev/null 2>&1 || exit_code=$?
    assert_exit_code 1 "${exit_code}" "no lock, no request"
    assert_not_contains "$(cat "${STUB_LOG}")" "systemd-run" "nothing dispatched"
    [[ -f "${REBOOT_PENDING_FILE}" ]] && fail "nothing was requested, so nothing is held"
    return 0
}

test_request_failed_client_with_timer_present_is_accepted() {
    load_request_library
    # systemd-run was killed after systemd created the timer.
    export STUB_SYSTEMD_RUN_RC=1 STUB_TIMER_SUB_STATE_AFTER_SUBMIT=waiting
    local exit_code=0
    request_reboot 1 schedule_reboot >/dev/null 2>&1 || exit_code=$?
    assert_exit_code 0 "${exit_code}" "the timer exists, so the reboot was submitted"
    [[ -f "${REBOOT_PENDING_FILE}" ]] || fail "a submitted reboot must keep update runs held"
    return 0
}

test_request_failed_client_without_timer_is_unknown() {
    load_request_library
    # No unit yet does not prove rejection: the request may still be on its
    # way to systemd.
    export STUB_SYSTEMD_RUN_RC=1
    local exit_code=0 output
    output=$(request_reboot 1 schedule_reboot 2>&1) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "an unknown outcome fails the caller"
    assert_contains "${output}" "reached systemd is unknown" "and is reported"
    [[ -f "${REBOOT_PENDING_FILE}" ]] || fail "an unknown outcome keeps update runs held"
    return 0
}

test_request_failed_client_with_unreadable_state_keeps_the_marker() {
    load_request_library
    export STUB_SYSTEMD_RUN_RC=1 STUB_STATE_UNREADABLE_AFTER_SUBMIT=yes
    local exit_code=0
    request_reboot 1 schedule_reboot >/dev/null 2>&1 || exit_code=$?
    assert_exit_code 1 "${exit_code}" "an unknown outcome fails the caller"
    [[ -f "${REBOOT_PENDING_FILE}" ]] || fail "an unknown outcome keeps update runs held"
    return 0
}

test_request_unreadable_state_before_submission_is_rejected() {
    load_request_library
    export STUB_PROPERTY_READ_FAILS=yes
    local exit_code=0
    request_reboot 1 schedule_reboot >/dev/null 2>&1 || exit_code=$?
    assert_exit_code 1 "${exit_code}" "nothing submitted"
    assert_not_contains "$(cat "${STUB_LOG}")" "systemd-run" "systemd-run never ran"
    [[ -f "${REBOOT_PENDING_FILE}" ]] && fail "a request never submitted releases its marker"
    return 0
}

test_request_elapsed_timer_is_not_a_scheduled_reboot() {
    load_request_library
    # An elapsed timer whose reboot failed is still loaded; it is no reboot
    # to come, so a new one is scheduled.
    export STUB_TIMER_LOAD_STATE=loaded STUB_TIMER_SUB_STATE=elapsed \
           STUB_SERVICE_LOAD_STATE=loaded STUB_SERVICE_ACTIVE_STATE=inactive
    local exit_code=0
    request_reboot 1 schedule_reboot >/dev/null 2>&1 || exit_code=$?
    assert_exit_code 0 "${exit_code}" "scheduled"
    assert_contains "$(cat "${STUB_LOG}")" "systemd-run" "a new timer is created"
}

test_request_waiting_timer_is_not_scheduled_twice() {
    load_request_library
    export STUB_TIMER_LOAD_STATE=loaded STUB_TIMER_SUB_STATE=waiting
    request_reboot 1 schedule_reboot >/dev/null 2>&1
    assert_exit_code 0 "$?" "an existing reboot is success"
    assert_not_contains "$(cat "${STUB_LOG}")" "systemd-run" "no second transient unit"
}

test_request_coherent_snapshot_sees_a_running_service() {
    load_request_library
    # One systemctl show per unit: a service that started its job reads as
    # running, never as inactive with its job already gone.
    export STUB_SERVICE_LOAD_STATE=loaded STUB_SERVICE_ACTIVE_STATE=activating
    assert_equals "in_progress" "$(read_scheduled_reboot_status)" "a running reboot service"
    export STUB_SERVICE_ACTIVE_STATE=inactive STUB_SERVICE_JOB=4711
    assert_equals "in_progress" "$(read_scheduled_reboot_status)" "a queued reboot service"
}

# ---------------------------------------------------------------------------
# run: no update while a reboot is pending
# ---------------------------------------------------------------------------
test_run_does_not_update_before_a_pending_reboot() {
    load_run_library
    stub_run_main
    # A timer an earlier version's watchdog scheduled during an upgrade has
    # no reboot-pending marker; the unit started anyway.
    export STUB_SCHEDULED_REBOOT_STATUS=waiting
    local exit_code=0
    ( main ) >/dev/null 2>&1 || exit_code=$?
    assert_exit_code 0 "${exit_code}" "a pending reboot is no failure"
    assert_not_contains "$(cat "${STUB_LOG}")" "systemd-inhibit" "nothing is updated"
}

test_run_unknown_reboot_state_does_not_update() {
    load_run_library
    stub_run_main
    export STUB_SCHEDULED_REBOOT_STATUS=unknown
    local exit_code=0
    ( main ) >/dev/null 2>&1 || exit_code=$?
    assert_exit_code 1 "${exit_code}" "an unreadable reboot state fails the run"
    assert_not_contains "$(cat "${STUB_LOG}")" "systemd-inhibit" "nothing is updated"
}

# ---------------------------------------------------------------------------
# invariant: the properties the reboot protocol rests on, checked in the
# source so a later change cannot drop one silently
# ---------------------------------------------------------------------------
# script_lines PATTERN -> "file:line: text" for every non-comment line of the
# shipped scripts that matches the extended regex PATTERN.
script_lines() {
    grep -nE "$1" "${REPO_ROOT}"/scripts/*.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true
}

test_invariant_only_reboot_if_pending_reboots() {
    local reboot_calls caller_lines
    reboot_calls=$(script_lines '"\$\{SYSTEMCTL_BIN\}" reboot')
    assert_equals "${REPO_ROOT}/scripts/reboot-request.sh" "$(printf '%s\n' "${reboot_calls}" | cut -d: -f1 | sort -u)" \
        "systemctl reboot is called from reboot_host only"
    caller_lines=$(script_lines '(^|[^_[:alnum:]])reboot_host( |$)' | grep -v 'reboot_host() {' || true)
    assert_equals "${REPO_ROOT}/scripts/reboot-if-pending.sh" "$(printf '%s\n' "${caller_lines}" | cut -d: -f1 | sort -u)" \
        "reboot_host is called from reboot-if-pending.sh only"
}

test_invariant_marker_removers_are_known() {
    local remover_files
    remover_files=$(script_lines 'rm -f "\$\{REBOOT_PENDING_FILE\}"' | cut -d: -f1 | sort -u | xargs -n1 basename | paste -sd' ' -)
    assert_equals "cancel-reboot.sh reboot-request.sh" "${remover_files}" \
        "only request_reboot (its own rejected request) and cancel-reboot.sh remove the marker"
    grep -rq 'reboot-pending' "${REPO_ROOT}"/units/ "${REPO_ROOT}"/tmpfiles/ \
        && grep -r 'reboot-pending' "${REPO_ROOT}"/units/ "${REPO_ROOT}"/tmpfiles/ | grep -vq 'ConditionPathExists=!\|^[^:]*:#' \
        && fail "no unit or tmpfiles entry may create or remove the marker"
    return 0
}

test_invariant_dispatched_file_is_removed_only_on_refusal() {
    local remover_files
    remover_files=$(script_lines 'rm -f "\$\{REBOOT_DISPATCHED_FILE\}"' | cut -d: -f1 | xargs -n1 basename | paste -sd' ' -)
    assert_equals "reboot-if-pending.sh" "${remover_files}" "once, in reboot-if-pending.sh's refusal path"
}

test_invariant_lock_file_is_never_removed() {
    script_lines 'rm .*REBOOT_REQUEST_LOCK_FILE|mv .*REBOOT_REQUEST_LOCK_FILE' | grep -q . \
        && fail "a removed or replaced lock file splits holders across two inodes"
    grep -E '^[rRD] .*reboot-request.lock' "${REPO_ROOT}/tmpfiles/dnf-automatic-reboot.conf" \
        && fail "tmpfiles.d must not remove the lock"
    return 0
}

test_invariant_flock_uses_documented_short_options() {
    # util-linux documents -w as --timeout; --wait is an undocumented alias.
    script_lines 'flock --' | grep -q . && fail "flock long options in a shipped script"
    return 0
}

test_invariant_every_script_is_shipped() {
    local script_path script_name
    for script_path in "${REPO_ROOT}"/scripts/*.sh; do
        script_name=$(basename "${script_path}")
        grep -q "scripts/${script_name}" "${REPO_ROOT}/Makefile" \
            || fail "${script_name} is not in the Makefile's SCRIPTS or LIBRARIES"
        grep -q "^install -m 07[0-9]0 scripts/${script_name}" "${SPEC_FILE}" \
            || grep -q "^install -m 0640 scripts/${script_name}" "${SPEC_FILE}" \
            || fail "${script_name} is not installed by %install"
        grep -q "%{pkglibexecdir}/${script_name}$" "${SPEC_FILE}" \
            || fail "${script_name} is not listed in %files"
    done
    return 0
}

test_invariant_versions_agree() {
    local makefile_version spec_version changelog_version
    makefile_version=$(sed -n 's/^VERSION = //p' "${REPO_ROOT}/Makefile")
    spec_version=$(sed -n 's/^Version:[[:space:]]*//p' "${SPEC_FILE}")
    changelog_version=$(sed -n '/^%changelog/{n;s/.* - \([0-9.]*\)-[0-9]*$/\1/p;q}' "${SPEC_FILE}")
    assert_equals "${makefile_version}" "${spec_version}" "Makefile VERSION and spec Version"
    assert_equals "${spec_version}" "${changelog_version}" "spec Version and the newest %changelog entry"
}

# ---------------------------------------------------------------------------
# readers: every systemd answer maps to one status, unknown when unlisted
# ---------------------------------------------------------------------------
test_reader_unit_snapshot_job_forms() {
    load_request_library
    get_unit_properties() { printf '%b' "${STUB_RAW_PROPERTIES}"; }
    export STUB_RAW_PROPERTIES='LoadState=loaded\nActiveState=inactive\nSubState=dead\n'
    assert_equals $'loaded\tinactive\tdead\t0' "$(read_unit_snapshot x.service)" "no Job line is no job"
    export STUB_RAW_PROPERTIES='LoadState=loaded\nActiveState=inactive\nSubState=dead\nJob=\n'
    assert_equals $'loaded\tinactive\tdead\t0' "$(read_unit_snapshot x.service)" "an empty Job is no job"
    export STUB_RAW_PROPERTIES='Job=12\nLoadState=loaded\nActiveState=inactive\nSubState=dead\n'
    assert_equals $'loaded\tinactive\tdead\t12' "$(read_unit_snapshot x.service)" "a job id, in any line order"
    export STUB_RAW_PROPERTIES='LoadState=loaded\nActiveState=inactive\nJob=12 start\n'
    read_unit_snapshot x.service >/dev/null && fail "a Job that is not a number is unreadable"
    export STUB_RAW_PROPERTIES='ActiveState=inactive\n'
    read_unit_snapshot x.service >/dev/null && fail "a missing LoadState is unreadable"
    return 0
}

test_reader_scheduled_reboot_status_table() {
    load_request_library
    local case_line expected settings setting
    while IFS='|' read -r expected settings; do
        [[ -n "${expected}" ]] || continue
        (
            for setting in ${settings}; do export "${setting?}"; done
            assert_equals "${expected}" "$(read_scheduled_reboot_status)" "[${settings}]"
        ) || fail "status table row ${expected}|${settings}"
    done <<'TABLE'
none|STUB_TIMER_LOAD_STATE=not-found STUB_TIMER_SUB_STATE=dead
waiting|STUB_TIMER_LOAD_STATE=loaded STUB_TIMER_SUB_STATE=waiting
in_progress|STUB_TIMER_LOAD_STATE=loaded STUB_TIMER_SUB_STATE=running
none|STUB_TIMER_LOAD_STATE=loaded STUB_TIMER_SUB_STATE=elapsed
none|STUB_TIMER_LOAD_STATE=loaded STUB_TIMER_SUB_STATE=dead
unknown|STUB_TIMER_LOAD_STATE=loaded STUB_TIMER_SUB_STATE=bogus
in_progress|STUB_SERVICE_LOAD_STATE=loaded STUB_SERVICE_ACTIVE_STATE=activating
in_progress|STUB_SERVICE_LOAD_STATE=loaded STUB_SERVICE_ACTIVE_STATE=active
in_progress|STUB_SERVICE_LOAD_STATE=loaded STUB_SERVICE_ACTIVE_STATE=deactivating
in_progress|STUB_SERVICE_LOAD_STATE=loaded STUB_SERVICE_JOB=7
failed|STUB_SERVICE_LOAD_STATE=loaded STUB_SERVICE_ACTIVE_STATE=failed
in_progress|STUB_SERVICE_LOAD_STATE=loaded STUB_SERVICE_ACTIVE_STATE=failed STUB_SERVICE_JOB=7
unknown|STUB_SERVICE_LOAD_STATE=loaded STUB_SERVICE_ACTIVE_STATE=maintenance
unknown|STUB_TIMER_LOAD_STATE=masked
unknown|STUB_SERVICE_LOAD_STATE=bad-setting
unknown|STUB_PROPERTY_READ_FAILS=yes
TABLE
    : > "${REBOOT_DISPATCHED_FILE}"
    export STUB_PROPERTY_READ_FAILS=yes
    assert_equals "dispatched" "$(read_scheduled_reboot_status)" \
        "the dispatched file wins over everything systemd says, even an unreadable state"
}

test_reader_host_shutdown_state_table() {
    load_request_library
    local expected system_state preparing logind_fails
    while IFS='|' read -r expected system_state preparing logind_fails; do
        [[ -n "${expected}" ]] || continue
        (
            export STUB_SYSTEM_STATE="${system_state}" STUB_PREPARING_FOR_SHUTDOWN="${preparing}" \
                   STUB_LOGIND_READ_FAILS="${logind_fails}"
            assert_equals "${expected}" "$(read_host_shutdown_state)" "[${system_state}|${preparing}|${logind_fails}]"
        ) || fail "shutdown table row ${expected}|${system_state}|${preparing}|${logind_fails}"
    done <<'TABLE'
no|running|b false|
no|degraded|b false|
no|starting|b false|
no|maintenance|b false|
yes|stopping|b false|
yes|running|b true|
yes|stopping||yes
unknown|running||yes
unknown|running|garbage|
unknown|offline|b false|
unknown|unknown|b false|
unknown||b false|
TABLE
}

# ---------------------------------------------------------------------------
# remaining branches
# ---------------------------------------------------------------------------
test_reboot_without_dispatched_record_does_not_reboot() {
    load_reboot_if_pending_library
    : > "${REBOOT_PENDING_FILE}"
    # A directory in its place makes the record impossible to write.
    mkdir "${REBOOT_DISPATCHED_FILE}"
    local exit_code=0
    run_reboot_if_pending no || exit_code=$?
    assert_exit_code 1 "${exit_code}" "an unrecorded reboot is refused"
    assert_not_contains "$(cat "${STUB_LOG}")" "reboot " "cancellation could not see it, so no reboot"
}

test_reboot_failed_force_on_a_running_host_releases_the_dispatch() {
    load_reboot_if_pending_library
    : > "${REBOOT_PENDING_FILE}"
    export STUB_REBOOT_RC=1 STUB_FORCE_REBOOT_RC=1
    local exit_code=0
    run_reboot_if_pending yes || exit_code=$?
    assert_exit_code 1 "${exit_code}" "neither reboot was accepted"
    [[ -f "${REBOOT_DISPATCHED_FILE}" ]] && fail "a host still up after both refusals can be cancelled"
    [[ -f "${REBOOT_PENDING_FILE}" ]] || fail "update runs stay held"
    return 0
}

test_reboot_failed_force_with_unknown_state_keeps_the_dispatch() {
    load_reboot_if_pending_library
    : > "${REBOOT_PENDING_FILE}"
    export STUB_REBOOT_RC=1 STUB_FORCE_REBOOT_RC=1
    # Up when --force is considered, unreadable after it failed.
    get_logind_preparing_for_shutdown() {
        if [[ -f "${TEST_ROOT_DIR}/forced" ]]; then return 1; fi
        printf 'b false'
    }
    reboot_host() {
        printf 'reboot %s\n' "$*" >> "${STUB_LOG}"
        [[ "${1:-}" == "--force" ]] && : > "${TEST_ROOT_DIR}/forced"
        return 1
    }
    local exit_code=0
    run_reboot_if_pending yes || exit_code=$?
    assert_exit_code 1 "${exit_code}" "an unknown outcome fails the unit"
    [[ -f "${REBOOT_DISPATCHED_FILE}" ]] || fail "a forced reboot that may be under way keeps cancellation refused"
    return 0
}

test_cancel_with_unstoppable_timer_still_cancels() {
    load_cancel_reboot_library
    export STUB_STOP_FAILS=yes
    assert_cancel_succeeds "the timer's command finds no marker when it fires"
    assert_contains "$(cat "${TEST_ROOT_DIR}/cancel.out")" "does not reboot" "the warning says why that is safe"
}

test_cancel_with_running_reboot_service_before_dispatch_cancels() {
    load_cancel_reboot_library
    # reboot-if-pending.sh started but waits for the lock this cancel holds.
    export STUB_TIMER_LOAD_STATE=loaded STUB_TIMER_SUB_STATE=running \
           STUB_SERVICE_LOAD_STATE=loaded STUB_SERVICE_ACTIVE_STATE=activating
    assert_cancel_succeeds "nothing has been dispatched yet"
}

test_request_dispatched_reboot_is_not_requested_again() {
    load_request_library
    : > "${REBOOT_DISPATCHED_FILE}"
    local exit_code=0
    request_reboot 1 schedule_reboot >/dev/null 2>&1 || exit_code=$?
    assert_exit_code 0 "${exit_code}" "a reboot under way is success"
    assert_not_contains "$(cat "${STUB_LOG}")" "systemd-run" "no second reboot unit"
    [[ -f "${REBOOT_PENDING_FILE}" ]] || fail "update runs are held until that reboot"
    return 0
}

test_run_pending_reboot_states_table() {
    local scheduled_reboot_status expected_exit_code expected_update
    while IFS='|' read -r scheduled_reboot_status expected_exit_code expected_update; do
        [[ -n "${scheduled_reboot_status}" ]] || continue
        (
            : > "${STUB_LOG}"
            load_run_library
            stub_run_main
            export STUB_SCHEDULED_REBOOT_STATUS="${scheduled_reboot_status}"
            local exit_code=0
            ( main ) >/dev/null 2>&1 || exit_code=$?
            assert_exit_code "${expected_exit_code}" "${exit_code}" "status ${scheduled_reboot_status}"
            if [[ "${expected_update}" == "yes" ]]; then
                assert_contains "$(cat "${STUB_LOG}")" "systemd-inhibit" "status ${scheduled_reboot_status} updates"
            else
                assert_not_contains "$(cat "${STUB_LOG}")" "systemd-inhibit" "status ${scheduled_reboot_status} does not update"
            fi
        ) || fail "run guard row ${scheduled_reboot_status}"
    done <<'TABLE'
none|0|yes
failed|0|yes
waiting|0|no
in_progress|0|no
dispatched|0|no
unknown|1|no
TABLE
}

test_watchdog_unknown_schedule_keeps_the_marker() {
    sleep 60 &
    local background_pid=$! exit_code=0
    load_watchdog_library
    write_watchdog_state checking 70 "${background_pid}"
    stub_watchdog_kill_path
    run_independent_reboot_check() { return 1; }
    export STUB_SCHEDULE_UNKNOWN=yes
    ( main ) >/dev/null 2>&1 || exit_code=$?
    kill "${background_pid}" 2>/dev/null
    assert_exit_code 1 "${exit_code}" "an unknown outcome reaches OnFailure="
    [[ -f "${REBOOT_PENDING_FILE}" ]] || fail "a reboot that may arrive late keeps update runs held"
    [[ -f "${RECOVERY_FILE}" ]] && fail "the recovery marker still ends with the watchdog"
    return 0
}

test_watchdog_unknown_immediate_reboot_keeps_the_marker() {
    sleep 60 &
    local background_pid=$! exit_code=0
    load_watchdog_library
    write_watchdog_state checking 200 "${background_pid}"
    stub_watchdog_kill_path
    submit_reboot() { return 2; }
    ( main ) >/dev/null 2>&1 || exit_code=$?
    kill "${background_pid}" 2>/dev/null
    assert_exit_code 1 "${exit_code}" "an unknown outcome reaches OnFailure="
    [[ -f "${REBOOT_PENDING_FILE}" ]] || fail "a reboot that may arrive late keeps update runs held"
    return 0
}

test_watchdog_scheduled_reboot_is_not_reported_as_leftover() {
    sleep 60 &
    local background_pid=$! exit_code=0
    load_watchdog_library
    : > "${REBOOT_PENDING_FILE}"
    write_watchdog_state checking 70 "${background_pid}"
    stub_watchdog_kill_path
    run_independent_reboot_check() { return 0; }
    export STUB_SCHEDULED_REBOOT_STATUS=waiting
    ( main ) >/dev/null 2>&1 || exit_code=$?
    kill "${background_pid}" 2>/dev/null
    assert_exit_code 0 "${exit_code}" "a marker with its reboot waiting is in order"
}

# notify: a failed deferred reboot says whether updates stay blocked
load_notify_library() {
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/scripts/notify-failure.sh"
    set +e
    IFS=$' \t\n'
    journalctl() { :; }
}

test_notify_failed_reboot_names_blocked_updates() {
    load_notify_library
    : > "${REBOOT_PENDING_FILE}"
    ( main dnf-automatic-reboot-scheduled-reboot.service ) >/dev/null 2>&1
    assert_contains "$(cat "${STUB_LOG}")" "Update runs stay blocked until the host reboots" \
        "the operator learns updates are held"
    assert_contains "$(cat "${STUB_LOG}")" "cancel-reboot.sh" "and how to release them"
    [[ -f "${REBOOT_PENDING_FILE}" ]] || fail "the notifier leaves the marker to the operator"
    return 0
}

test_notify_failed_dispatched_reboot_says_reboot() {
    load_notify_library
    : > "${REBOOT_PENDING_FILE}"
    : > "${REBOOT_DISPATCHED_FILE}"
    ( main dnf-automatic-reboot-scheduled-reboot.service ) >/dev/null 2>&1
    assert_contains "$(cat "${STUB_LOG}")" "whether systemd accepted it is unknown" \
        "a reboot command with an unknown outcome is named"
    assert_not_contains "$(cat "${STUB_LOG}")" "cancel-reboot.sh" "cancellation would be refused"
}

test_notify_failed_reboot_without_marker_is_not_blocked() {
    load_notify_library
    ( main dnf-automatic-reboot-scheduled-reboot.service ) >/dev/null 2>&1
    assert_contains "$(cat "${STUB_LOG}")" "Update runs are not blocked" "no false hold reported"
}

# ---------------------------------------------------------------------------
# preflight: %pre refuses any host the package cannot reboot safely
#
# The real scriptlet, as rpm expands it, with %{?preflight_root} pointed at
# the fixture tree.  Built RPMs expand that macro to nothing.
# ---------------------------------------------------------------------------
readonly FIXTURE_KERNEL=/boot/vmlinuz-6.12.0-206.104.4.4.el9uek.aarch64

# make_preflight_host: a fixture that passes every check.
make_preflight_host() {
    printf 'NAME="Oracle Linux Server"\nPLATFORM_ID="platform:el9"\n' > "${TEST_ROOT_DIR}/etc/os-release"
    mkdir -p "${TEST_ROOT_DIR}/run/systemd/system" "${TEST_ROOT_DIR}/boot/loader/entries" \
             "${TEST_ROOT_DIR}/boot/grub2" "${TEST_ROOT_DIR}/etc/default" "${TEST_ROOT_DIR}/etc/sysconfig"
    printf 'GRUB_ENABLE_BLSCFG=true\nGRUB_DEFAULT=saved\nGRUB_UPDATE_DEFAULT_KERNEL=true\n' \
        > "${TEST_ROOT_DIR}/etc/default/grub"
    printf 'DEFAULTKERNEL=kernel-uek-core\n' > "${TEST_ROOT_DIR}/etc/sysconfig/kernel"
    # What grub2-mkconfig's 00_header emits for GRUB_DEFAULT=saved.
    printf '%s\n' 'if [ "${next_entry}" ] ; then' '   set default="${next_entry}"' 'else' \
                  '   set default="${saved_entry}"' 'fi' > "${TEST_ROOT_DIR}/boot/grub2/grub.cfg"
    : > "${TEST_ROOT_DIR}/boot/loader/entries/b7c51e4d-6.12.0-206.104.4.4.el9uek.aarch64.conf"
    : > "${TEST_ROOT_DIR}${FIXTURE_KERNEL}"
    export STUB_GRUBBY_DEFAULT="${FIXTURE_KERNEL}"
    export STUB_INSTALLED_VERSION=""
    export STUB_MISSING_PACKAGES=""
    export STUB_RUNNING_KERNEL_PACKAGE="kernel-uek-core"
    # Installed versions of the running kernel's package; the newest is the default.
    export STUB_KERNEL_VERSIONS="6.12.0-206.104.4.4.el9uek.aarch64"
}

# make_stock_kernel_host: a RHEL-style host running kernel-core.
make_stock_kernel_host() {
    make_preflight_host
    export STUB_RUNNING_KERNEL_PACKAGE="kernel-core"
    printf 'DEFAULTKERNEL=kernel-core\n' > "${TEST_ROOT_DIR}/etc/sysconfig/kernel"
    printf 'GRUB_UPDATE_DEFAULT_KERNEL=true\n' >> "${TEST_ROOT_DIR}/etc/default/grub"
}

# run_preflight INSTANCE_COUNT -> scriptlet output on stdout, its exit code returned.
# INSTANCE_COUNT is rpm's $1: 1 for a fresh install, 2 for an upgrade.
run_preflight() {
    local scriptlet_file="${TEST_ROOT_DIR}/prein.sh"
    rpmspec -P --define "preflight_root ${TEST_ROOT_DIR}" "${SPEC_FILE}" 2>/dev/null \
        | awk '/^%pre -p/ { in_pre = 1; next } /^%post$/ { in_pre = 0 } in_pre' \
        > "${scriptlet_file}"
    [[ -s "${scriptlet_file}" ]] || fail "could not extract %pre from the spec"
    # Functions shadow the commands inside the child bash, as elsewhere.
    rpm() {
        if [[ "$1" == "-qf" ]]; then
            [[ -n "${STUB_RUNNING_KERNEL_PACKAGE}" ]] || return 1
            printf '%s\n' "${STUB_RUNNING_KERNEL_PACKAGE}"
            return 0
        fi
        if [[ "$*" == *VERSION* && "${!#}" == "dnf-automatic-reboot" ]]; then
            [[ -n "${STUB_INSTALLED_VERSION}" ]] || return 1
            printf '%s\n' "${STUB_INSTALLED_VERSION}"
            return 0
        fi
        if [[ "$*" == *VERSION* ]]; then
            printf '%s\n' "${STUB_KERNEL_VERSIONS}"
            return 0
        fi
        [[ " ${STUB_MISSING_PACKAGES} " != *" ${!#} "* ]]
    }
    grubby() { printf '%s\n' "${STUB_GRUBBY_DEFAULT}"; }
    systemctl() { return 1; }
    export -f rpm grubby systemctl
    bash "${scriptlet_file}" "$1" 2>&1
}

test_preflight_prepared_host_passes() {
    make_preflight_host
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 0 "${exit_code}" "prepared EL9 BLS host: ${output}"
}

test_preflight_refuses_el10() {
    make_preflight_host
    printf 'PLATFORM_ID="platform:el10"\n' > "${TEST_ROOT_DIR}/etc/os-release"
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "untested EL10 refused"
    assert_contains "${output}" "platform:el10" "names the platform found"
}

# make_el8_host: shaped like the surveyed RHEL 8.10 EFI host.  The ESP holds
# the full grub.cfg, and 20-grub.install does not read DEFAULTKERNEL.
make_el8_host() {
    make_preflight_host
    printf 'PLATFORM_ID="platform:el8"\n' > "${TEST_ROOT_DIR}/etc/os-release"
    export STUB_RUNNING_KERNEL_PACKAGE="kernel-core"
    printf 'GRUB_ENABLE_BLSCFG=true\nGRUB_DEFAULT=saved\nGRUB_UPDATE_DEFAULT_KERNEL=true\n' \
        > "${TEST_ROOT_DIR}/etc/default/grub"
    mkdir -p "${TEST_ROOT_DIR}/boot/efi/EFI/redhat"
    cp "${TEST_ROOT_DIR}/boot/grub2/grub.cfg" "${TEST_ROOT_DIR}/boot/efi/EFI/redhat/grub.cfg"
}

test_preflight_el8_host_passes() {
    make_el8_host
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 0 "${exit_code}" "EL8 without DEFAULTKERNEL: ${output}"
}

test_preflight_el8_checks_the_esp_grub_cfg() {
    make_el8_host
    # The ESP config is the one GRUB runs on EL8 EFI; /boot/grub2 still passes.
    printf '%s\n' '   set default="0"' > "${TEST_ROOT_DIR}/boot/efi/EFI/redhat/grub.cfg"
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "fixed default in the ESP config refused"
    assert_contains "${output}" "grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg" "names the file to regenerate"
}

test_preflight_el9_esp_stub_is_not_a_config() {
    make_preflight_host
    # EL9 EFI: the ESP file only loads /boot/grub2/grub.cfg.
    mkdir -p "${TEST_ROOT_DIR}/boot/efi/EFI/redhat"
    printf '%s\n' 'search --no-floppy --fs-uuid --set=dev 1234' 'set prefix=($dev)/grub2' \
        'configfile $prefix/grub.cfg' > "${TEST_ROOT_DIR}/boot/efi/EFI/redhat/grub.cfg"
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 0 "${exit_code}" "stub is not checked for saved_entry: ${output}"
}

test_preflight_refuses_without_grub_cfg() {
    make_preflight_host
    rm -f "${TEST_ROOT_DIR}/boot/grub2/grub.cfg"
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "no grub.cfg refused"
    assert_contains "${output}" "no grub.cfg found" "says why"
}

test_preflight_refuses_without_systemd() {
    make_preflight_host
    rmdir "${TEST_ROOT_DIR}/run/systemd/system"
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "container or chroot refused"
    assert_contains "${output}" "not the running init" "says why"
}

test_preflight_refuses_without_bls() {
    make_preflight_host
    printf 'GRUB_ENABLE_BLSCFG=false\n' > "${TEST_ROOT_DIR}/etc/default/grub"
    rm -f "${TEST_ROOT_DIR}"/boot/loader/entries/*.conf
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "legacy grub.cfg refused"
    assert_contains "${output}" "GRUB_ENABLE_BLSCFG" "names the setting"
    assert_contains "${output}" "no BLS entry" "names the missing entries"
}

test_preflight_refuses_unreadable_grub_default() {
    make_preflight_host
    # What grubby printed, with exit 0, when grubenv was unreadable.
    export STUB_GRUBBY_DEFAULT="/boot"
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "no usable default refused"
    assert_contains "${output}" "grubby --set-default" "names the repair"
}

test_preflight_refuses_grub_cfg_not_booting_saved_entry() {
    make_preflight_host
    # grub2-mkconfig output for GRUB_DEFAULT=0: grubby's default is ignored.
    printf '%s\n' '   set default="0"' > "${TEST_ROOT_DIR}/boot/grub2/grub.cfg"
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "fixed default refused"
    assert_contains "${output}" "does not boot saved_entry" "says why"
}

test_preflight_refuses_grub_default_not_saved() {
    make_preflight_host
    # grub.cfg still boots saved_entry, but the next grub2-mkconfig would not.
    printf 'GRUB_ENABLE_BLSCFG=true\nGRUB_DEFAULT=0\n' > "${TEST_ROOT_DIR}/etc/default/grub"
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "GRUB_DEFAULT=0 refused"
    assert_contains "${output}" "GRUB_DEFAULT=saved is not set" "names the setting"
}

test_preflight_stock_kernel_with_default_settings_passes() {
    make_stock_kernel_host
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 0 "${exit_code}" "kernel-core with both settings: ${output}"
}

test_preflight_refuses_stock_kernel_without_update_default() {
    make_stock_kernel_host
    # %post only provisions UEK; here saved_entry would never advance.
    printf 'GRUB_ENABLE_BLSCFG=true\nGRUB_DEFAULT=saved\n' > "${TEST_ROOT_DIR}/etc/default/grub"
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "no GRUB_UPDATE_DEFAULT_KERNEL refused"
    assert_contains "${output}" "GRUB_UPDATE_DEFAULT_KERNEL=true" "names the setting"
}

test_preflight_refuses_stock_kernel_with_wrong_default_kernel() {
    make_stock_kernel_host
    printf 'DEFAULTKERNEL=kernel\n' > "${TEST_ROOT_DIR}/etc/sysconfig/kernel"
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "DEFAULTKERNEL naming another package refused"
    assert_contains "${output}" "DEFAULTKERNEL=kernel-core  (found: 'kernel')" "names both values"
}

test_preflight_refuses_uek_without_kernel_default_settings() {
    make_preflight_host
    # A fresh OL9 UEK host: neither setting is present, and the installer
    # refuses, naming them, rather than editing either file.
    printf 'GRUB_ENABLE_BLSCFG=true\nGRUB_DEFAULT=saved\n' > "${TEST_ROOT_DIR}/etc/default/grub"
    rm -f "${TEST_ROOT_DIR}/etc/sysconfig/kernel"
    local grub_defaults_before output exit_code=0
    grub_defaults_before=$(cat "${TEST_ROOT_DIR}/etc/default/grub")
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "UEK without the settings refused"
    assert_contains "${output}" "GRUB_UPDATE_DEFAULT_KERNEL=true" "names the grub setting"
    assert_contains "${output}" "DEFAULTKERNEL=kernel-uek-core" "names the kernel setting"
    assert_equals "${grub_defaults_before}" "$(cat "${TEST_ROOT_DIR}/etc/default/grub")" \
        "/etc/default/grub is not edited"
    [[ -e "${TEST_ROOT_DIR}/etc/sysconfig/kernel" ]] && fail "/etc/sysconfig/kernel must not be created"
    return 0
}

test_preflight_refuses_default_older_than_newest_kernel() {
    make_preflight_host
    # A newer kernel is installed, but the default was left on the old one.
    export STUB_KERNEL_VERSIONS="6.12.0-206.104.4.4.el9uek.aarch64
6.12.0-206.104.4.10.el9uek.aarch64"
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "stale default refused, not repaired"
    assert_contains "${output}" "grubby --set-default /boot/vmlinuz-6.12.0-206.104.4.10.el9uek.aarch64" \
        "names the command, with the newest kernel"
}

test_preflight_refuses_unowned_running_kernel() {
    make_preflight_host
    export STUB_RUNNING_KERNEL_PACKAGE=""
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "hand-built kernel refused"
    assert_contains "${output}" "no package owns" "says why"
}

test_preflight_savedefault_only_warns() {
    make_preflight_host
    printf 'GRUB_SAVEDEFAULT=true\n' >> "${TEST_ROOT_DIR}/etc/default/grub"
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 0 "${exit_code}" "an operator preference is not refused"
    assert_contains "${output}" "WARNING: GRUB_SAVEDEFAULT=true" "but it is reported"
}

test_preflight_refuses_apply_updates_off() {
    make_preflight_host
    # The stock dnf-automatic value: downloads, installs nothing, exits 0.
    printf 'reboot = never\napply_updates = no\n' > "${TEST_ROOT_DIR}/etc/dnf/automatic.conf"
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "apply_updates = no refused"
    assert_contains "${output}" "apply_updates = yes" "names the setting to change"
}

test_preflight_refuses_apply_updates_unset() {
    make_preflight_host
    # dnf-automatic defaults a missing apply_updates to false.
    printf 'reboot = never\n' > "${TEST_ROOT_DIR}/etc/dnf/automatic.conf"
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "missing apply_updates refused"
    assert_contains "${output}" "apply_updates = <unset>" "says it is unset"
}

test_preflight_accepts_operator_automatic_conf() {
    make_preflight_host
    # An existing, hand-configured file as found on an OL9 host: checked as is.
    printf '%s\n' '[commands]' 'upgrade_type = security' 'random_sleep = 0' \
        'network_online_timeout = 60' 'download_updates = yes' 'apply_updates = True  # on' \
        'reboot = never' > "${TEST_ROOT_DIR}/etc/dnf/automatic.conf"
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 0 "${exit_code}" "hand-configured automatic.conf passes: ${output}"
}

test_preflight_refuses_missing_dependencies() {
    make_preflight_host
    # --nodeps without elfutils would disable the build-id check at runtime.
    export STUB_MISSING_PACKAGES="dnf-automatic elfutils"
    local output exit_code=0
    output=$(run_preflight 1) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "--nodeps install refused"
    assert_contains "${output}" "dnf install dnf-automatic" "names each missing package"
    assert_contains "${output}" "dnf install elfutils" "names each missing package"
    assert_not_contains "${output}" "dnf install grubby" "installed packages not reported"
}

test_preflight_refuses_upgrade_from_pre_1_4() {
    make_preflight_host
    export STUB_INSTALLED_VERSION="1.2"
    local output exit_code=0
    output=$(run_preflight 2) || exit_code=$?
    assert_exit_code 1 "${exit_code}" "1.2 upgrade refused"
    assert_contains "${output}" "dnf remove dnf-automatic-reboot" "names the removal"
}

test_preflight_allows_upgrade_from_1_4() {
    make_preflight_host
    export STUB_INSTALLED_VERSION="1.4.0"
    local output exit_code=0
    output=$(run_preflight 2) || exit_code=$?
    assert_exit_code 0 "${exit_code}" "1.4.0 upgrade allowed: ${output}"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
printf 'dnf-automatic-reboot test suite\n\n'

printf 'parser\n'
run_test "parser: extracts package names"            test_parser_extracts_package_names
run_test "parser: ignores plugin warning line"       test_parser_ignores_plugin_warning_line
run_test "parser: ignores translated headers"        test_parser_ignores_translated_headers
run_test "parser: rejects multi-word bullet"         test_parser_rejects_multi_word_bullet
run_test "parser: yields nothing without bullets"    test_parser_yields_nothing_without_bullets

printf 'config\n'
run_test "config: every documented key resolves"     test_config_every_key_resolves
run_test "config: prefix keys do not collide"        test_config_prefix_keys_do_not_collide
run_test "config: int rejects non-numeric"           test_config_int_rejects_non_numeric
run_test "config: int rejects negative"              test_config_int_rejects_negative
run_test "config: int reads leading zeros as decimal" test_config_int_reads_leading_zeros_as_decimal
run_test "config: int enforces bounds"               test_config_int_enforces_bounds
run_test "request: malformed delay submits nothing"  test_request_malformed_delay_submits_nothing

printf 'kernel\n'
run_test "kernel: running is newest is a false positive" test_kernel_running_is_newest_is_false_positive
run_test "kernel: newer installed is genuine"        test_kernel_newer_installed_is_genuine
run_test "kernel: not installed fails closed"        test_kernel_not_installed_is_genuine
run_test "kernel: arch-stripped form matches"        test_kernel_arch_stripped_form_matches
run_test "kernel: version sort is numeric"           test_kernel_version_sort_is_numeric

printf 'grub\n'
run_test "grub: default matches newest"              test_grub_default_matches_newest
run_test "grub: stale default is detected"           test_grub_default_is_stale
run_test "grub: missing grubby is undetermined"      test_grub_unavailable_is_undetermined
run_test "grub: unreadable grubenv is undetermined"  test_grub_unreadable_grubenv_is_undetermined

printf 'buildid\n'
run_test "buildid: all processes match"              test_build_id_all_processes_match
run_test "buildid: mismatch on later process wins"   test_build_id_mismatch_on_later_process_wins
run_test "buildid: stale process sharing a binary is found" test_build_id_stale_process_sharing_a_binary_is_found
run_test "buildid: no owned process is unverifiable" test_build_id_no_owned_process_is_unverifiable
run_test "buildid: unreadable process keeps the package" test_build_id_unreadable_process_keeps_the_package
run_test "buildid: exited process is not unreadable"  test_build_id_exited_process_is_not_unreadable
run_test "buildid: unreadable link of live process keeps the package" test_build_id_unreadable_link_of_live_process_keeps_the_package
run_test "buildid: zombie process is exited"          test_build_id_zombie_process_is_exited

printf 'state\n'
run_test "state: round trip"                         test_state_round_trip
run_test "state: replacement is exact field"         test_state_replacement_is_exact_field
run_test "state: kernel attempts keyed on target"    test_state_kernel_attempts_keyed_on_target
run_test "state: kernel attempts cleared"            test_state_kernel_attempts_cleared
run_test "state: attempts cleared when target runs unflagged" test_state_attempts_cleared_when_target_runs_unflagged
run_test "state: attempts cleared for arch-stripped release" test_state_attempts_cleared_for_arch_stripped_release
run_test "state: attempts kept while old kernel runs" test_state_attempts_kept_while_old_kernel_runs

printf 'learning\n'
run_test "learning: never overrules a build-id mismatch" test_learning_never_overrules_a_build_id_mismatch
run_test "learning: does not confirm an unverifiable package" test_learning_does_not_confirm_an_unverifiable_package
run_test "learning: confirmed same evr is skipped"   test_learning_confirmed_same_evr_is_skipped
run_test "learning: pending after reboot confirms"   test_learning_pending_after_reboot_is_confirmed
run_test "learning: pending same boot still reboots" test_learning_pending_same_boot_still_reboots
run_test "learning: new evr restarts the cycle"      test_learning_new_evr_restarts_cycle

printf 'classify\n'
run_test "classify: withholds on stale grub default" test_classify_withholds_on_stale_grub_default
run_test "classify: withholds at attempt limit"      test_classify_withholds_at_attempt_limit
run_test "classify: unrecorded attempt withholds the reboot" test_classify_unrecorded_attempt_withholds_the_reboot
run_test "classify: schedules genuine kernel reboot" test_classify_schedules_genuine_kernel_reboot
run_test "classify: repeated checks in one boot count once" test_classify_repeated_checks_in_one_boot_count_once
run_test "classify: keeps package when verifier missing" test_classify_keeps_package_when_verifier_missing

printf 'decision\n'
run_test "decision: dnf error does not reboot"       test_decision_dnf_error_does_not_reboot
run_test "decision: cache miss retries with refresh" test_decision_cache_miss_retries_with_refresh
run_test "decision: temporary file failure removes nothing" test_decision_temporary_file_failure_removes_nothing

printf 'run\n'
run_test "run: refused inhibitor stops the update"   test_run_refused_inhibitor_stops_the_update
run_test "run: update runs inside the inhibitor"     test_run_update_runs_inside_the_inhibitor
run_test "run: helper failure fails the run"        test_run_helper_failure_fails_the_run
run_test "run: scheduled reboot holds update runs"   test_run_scheduled_reboot_holds_update_runs
run_test "run: failed schedule removes its marker"   test_run_failed_schedule_removes_its_marker
run_test "run: interrupted request keeps its marker" test_run_interrupted_request_keeps_its_marker
run_test "run: pending restart fails the run"       test_run_pending_restart_fails_the_run
run_test "run: failed restart fails the run"        test_run_failed_restart_fails_the_run
run_test "run: completion summary names every outcome" test_run_completion_summary_names_every_outcome
run_test "run: reboot is scheduled on a named unit"  test_reboot_is_scheduled_on_a_named_unit needs-exec
run_test "run: reboot already scheduled is kept"     test_reboot_already_scheduled_is_not_scheduled_twice needs-exec
run_test "run: service restarts stay supervised"    test_run_service_restarts_stay_supervised

printf 'repositories\n'
run_test "repositories: unsigned enabled repo is reported"  test_repositories_unsigned_enabled_is_reported
run_test "repositories: unsigned but disabled is ignored"   test_repositories_unsigned_but_disabled_is_ignored
run_test "repositories: all signed is silent"               test_repositories_all_signed_is_silent

printf 'advisories\n'
run_test "advisories: unappliable advisory is an error"   test_advisories_unappliable_is_an_error        needs-exec
run_test "advisories: red hat colon ids are matched"      test_advisories_red_hat_colon_ids_are_matched  needs-exec
run_test "advisories: oracle revision suffix is matched" test_advisories_oracle_revision_suffix_is_matched needs-exec
run_test "advisories: epel ids are matched"               test_advisories_epel_ids_are_matched          needs-exec
run_test "advisories: still pending is only a warning"    test_advisories_still_pending_is_only_a_warning needs-exec
run_test "advisories: none is silent"                     test_advisories_none_is_silent                 needs-exec
run_test "advisories: ignores non-advisory lines"         test_advisories_ignores_non_advisory_lines     needs-exec
run_test "advisories: disabled by config"                 test_advisories_disabled_by_config

printf 'conflicts\n'
run_test "conflicts: refuse apply_updates off"      test_conflicts_refuse_apply_updates_off
run_test "conflicts: pass on prepared host"         test_conflicts_pass_on_prepared_host

printf 'services\n'
run_test "services: excluded units are not restarted" test_services_excluded_units_are_not_restarted needs-exec
run_test "services: disabled by config"              test_services_disabled_by_config
run_test "services: restart is bounded"              test_services_restart_is_bounded
run_test "services: template units excluded by glob" test_services_template_units_are_excluded_by_glob
run_test "services: wall_messages comment is ignored" test_wall_messages_trailing_comment_is_not_part_of_the_value

printf 'watchdog\n'
run_test "watchdog: no state file is a noop"         test_watchdog_no_state_file_is_a_noop
run_test "watchdog: dead pid does not reboot"        test_watchdog_dead_pid_does_not_reboot
run_test "watchdog: warning reaches the stub, not the host" test_watchdog_warning_reaches_the_stub_not_the_host
run_test "watchdog: ignores wall clock step"         test_watchdog_ignores_wall_clock_step
run_test "watchdog: state without uptime is malformed" test_watchdog_state_without_uptime_is_malformed
run_test "watchdog: hard timeout while updating does not reboot" test_watchdog_hard_timeout_while_updating_does_not_reboot needs-exec
run_test "watchdog: hard timeout while updating can be forced"   test_watchdog_hard_timeout_while_updating_can_be_forced   needs-exec
run_test "watchdog: hard timeout while checking reboots"         test_watchdog_hard_timeout_while_checking_reboots         needs-exec
run_test "watchdog: reboots through the pending check" test_watchdog_reboots_through_the_pending_check needs-exec
run_test "watchdog: kill option follows systemd version" test_watchdog_kill_option_follows_systemd_version
run_test "watchdog: hung reboot check is undecidable" test_watchdog_hung_reboot_check_is_undecidable
run_test "watchdog: helper failure is not no-reboot" test_watchdog_helper_failure_is_not_no_reboot
run_test "watchdog: replaced run is not killed"      test_watchdog_replaced_run_is_not_killed
run_test "watchdog: failed kill keeps supervision"   test_watchdog_failed_kill_keeps_supervision
run_test "watchdog: unconfirmed kill signals no pid" test_watchdog_unconfirmed_kill_signals_no_pid
run_test "watchdog: no run starts during the kill"   test_watchdog_no_run_starts_during_the_kill
run_test "watchdog: scheduled reboot keeps runs blocked" test_watchdog_scheduled_reboot_keeps_runs_blocked
run_test "watchdog: recovery without reboot allows runs" test_watchdog_recovery_without_reboot_allows_runs_again
run_test "watchdog: failed schedule allows runs again" test_watchdog_failed_schedule_allows_runs_again
run_test "watchdog: markers block the main unit"     test_watchdog_markers_block_the_main_unit
run_test "watchdog: later failure keeps a pending reboot" test_watchdog_later_failure_keeps_a_pending_reboot
run_test "watchdog: interrupted request keeps a marker" test_watchdog_interrupted_request_keeps_a_marker
run_test "watchdog: failed request keeps an earlier marker" test_watchdog_failed_request_keeps_an_earlier_marker
run_test "watchdog: reports a marker left by the killed run" test_watchdog_reports_a_marker_left_by_the_killed_run
run_test "cancel: stops the timer and allows runs"   test_cancel_stops_the_timer_and_allows_runs
run_test "cancel: then a late firing does not reboot" test_cancel_then_a_late_firing_does_not_reboot
run_test "cancel: refuses after the reboot command ran" test_cancel_refuses_after_the_reboot_command_ran
run_test "cancel: refuses while shutting down"       test_cancel_refuses_while_shutting_down
run_test "cancel: refuses a shutdown logind delays"  test_cancel_refuses_a_shutdown_logind_delays
run_test "cancel: refuses unreadable systemd state"  test_cancel_refuses_unreadable_systemd_state
run_test "cancel: refuses unrecognised states"       test_cancel_refuses_unrecognised_states
run_test "cancel: accepts a degraded host"           test_cancel_accepts_a_degraded_host
run_test "cancel: refuses while a request holds the lock" test_cancel_refuses_while_a_request_holds_the_lock
run_test "cancel: after a failed reboot allows runs" test_cancel_after_a_failed_reboot_allows_runs
run_test "cancel: nothing pending is a noop"         test_cancel_with_nothing_pending_is_a_noop
run_test "reboot: pending reboots and records it"   test_reboot_pending_reboots_and_records_it
run_test "reboot: accepted by logind is not forced"  test_reboot_accepted_by_logind_is_not_forced
run_test "reboot: unknown shutdown state is not forced" test_reboot_unknown_shutdown_state_is_not_forced
run_test "reboot: refused on a running host is forced when allowed" test_reboot_refused_on_a_running_host_is_forced_when_allowed
run_test "reboot: refused without force releases the dispatch" test_reboot_refused_without_force_releases_the_dispatch
run_test "reboot: waits for a cancellation in progress" test_reboot_waits_for_a_cancellation_in_progress
run_test "lock: created owner-only"                  test_lock_is_created_owner_only
run_test "lock: permissions corrected in place"      test_lock_permissions_are_corrected_in_place
run_test "lock: shipped owner-only"                  test_lock_is_shipped_owner_only
run_test "request: cancel during dispatch cannot drop the marker" test_request_cancel_during_dispatch_cannot_drop_the_marker
run_test "request: waits for the lock, then gives up" test_request_waits_for_the_lock_then_gives_up
run_test "request: failed client with timer present is accepted" test_request_failed_client_with_timer_present_is_accepted
run_test "request: failed client without timer is unknown" test_request_failed_client_without_timer_is_unknown
run_test "request: failed client, unreadable state keeps the marker" test_request_failed_client_with_unreadable_state_keeps_the_marker
run_test "request: unreadable state before submission is rejected" test_request_unreadable_state_before_submission_is_rejected
run_test "request: elapsed timer is not a scheduled reboot" test_request_elapsed_timer_is_not_a_scheduled_reboot
run_test "request: waiting timer is not scheduled twice" test_request_waiting_timer_is_not_scheduled_twice
run_test "request: coherent snapshot sees a running service" test_request_coherent_snapshot_sees_a_running_service
run_test "run: does not update before a pending reboot" test_run_does_not_update_before_a_pending_reboot
run_test "run: unknown reboot state does not update" test_run_unknown_reboot_state_does_not_update
run_test "invariant: only reboot-if-pending reboots" test_invariant_only_reboot_if_pending_reboots
run_test "invariant: marker removers are known"     test_invariant_marker_removers_are_known
run_test "invariant: dispatched file removed only on refusal" test_invariant_dispatched_file_is_removed_only_on_refusal
run_test "invariant: lock file is never removed"    test_invariant_lock_file_is_never_removed
run_test "invariant: flock uses documented short options" test_invariant_flock_uses_documented_short_options
run_test "invariant: every script is shipped"       test_invariant_every_script_is_shipped
run_test "invariant: versions agree"                test_invariant_versions_agree
run_test "reader: unit snapshot job forms"          test_reader_unit_snapshot_job_forms
run_test "reader: scheduled reboot status table"    test_reader_scheduled_reboot_status_table
run_test "reader: host shutdown state table"        test_reader_host_shutdown_state_table
run_test "reboot: no dispatched record, no reboot"  test_reboot_without_dispatched_record_does_not_reboot
run_test "reboot: failed force on a running host releases the dispatch" test_reboot_failed_force_on_a_running_host_releases_the_dispatch
run_test "reboot: failed force with unknown state keeps the dispatch" test_reboot_failed_force_with_unknown_state_keeps_the_dispatch
run_test "cancel: unstoppable timer still cancels"  test_cancel_with_unstoppable_timer_still_cancels
run_test "cancel: running service before dispatch cancels" test_cancel_with_running_reboot_service_before_dispatch_cancels
run_test "request: dispatched reboot is not requested again" test_request_dispatched_reboot_is_not_requested_again
run_test "run: pending reboot states table"         test_run_pending_reboot_states_table
run_test "watchdog: unknown schedule keeps the marker" test_watchdog_unknown_schedule_keeps_the_marker
run_test "watchdog: unknown immediate reboot keeps the marker" test_watchdog_unknown_immediate_reboot_keeps_the_marker
run_test "watchdog: scheduled reboot is not reported as leftover" test_watchdog_scheduled_reboot_is_not_reported_as_leftover
run_test "notify: failed reboot names blocked updates" test_notify_failed_reboot_names_blocked_updates
run_test "notify: failed dispatched reboot says reboot" test_notify_failed_dispatched_reboot_says_reboot
run_test "notify: failed reboot without marker is not blocked" test_notify_failed_reboot_without_marker_is_not_blocked
run_test "watchdog: unknown identity is not acted on" test_watchdog_unknown_identity_is_not_acted_on
run_test "watchdog: dispatch failure fails the watchdog" test_watchdog_dispatch_failure_fails_the_watchdog
run_test "watchdog: unit has a start timeout"        test_watchdog_unit_has_a_start_timeout
run_test "watchdog: reused pid is not the run"        test_watchdog_reused_pid_is_not_the_run       needs-exec
run_test "watchdog: systemd 239 kills with --kill-who" test_watchdog_hard_timeout_on_systemd_239_kills_with_kill_who needs-exec

printf 'preflight\n'
run_test "preflight: prepared host passes"           test_preflight_prepared_host_passes           needs-rpmspec
run_test "preflight: refuses EL10"                   test_preflight_refuses_el10                   needs-rpmspec
run_test "preflight: EL8 host passes"                test_preflight_el8_host_passes                needs-rpmspec
run_test "preflight: EL8 checks the ESP grub.cfg"    test_preflight_el8_checks_the_esp_grub_cfg    needs-rpmspec
run_test "preflight: EL9 ESP stub is not a config"   test_preflight_el9_esp_stub_is_not_a_config   needs-rpmspec
run_test "preflight: refuses without grub.cfg"       test_preflight_refuses_without_grub_cfg       needs-rpmspec
run_test "preflight: refuses without systemd"        test_preflight_refuses_without_systemd        needs-rpmspec
run_test "preflight: refuses without BLS"            test_preflight_refuses_without_bls            needs-rpmspec
run_test "preflight: refuses unreadable grub default" test_preflight_refuses_unreadable_grub_default needs-rpmspec
run_test "preflight: refuses missing dependencies"   test_preflight_refuses_missing_dependencies   needs-rpmspec
run_test "preflight: refuses grub.cfg not booting saved_entry" test_preflight_refuses_grub_cfg_not_booting_saved_entry needs-rpmspec
run_test "preflight: refuses GRUB_DEFAULT not saved" test_preflight_refuses_grub_default_not_saved needs-rpmspec
run_test "preflight: stock kernel with default settings passes" test_preflight_stock_kernel_with_default_settings_passes needs-rpmspec
run_test "preflight: refuses stock kernel without update default" test_preflight_refuses_stock_kernel_without_update_default needs-rpmspec
run_test "preflight: refuses stock kernel with wrong DEFAULTKERNEL" test_preflight_refuses_stock_kernel_with_wrong_default_kernel needs-rpmspec
run_test "preflight: refuses UEK without kernel default settings" test_preflight_refuses_uek_without_kernel_default_settings needs-rpmspec
run_test "preflight: refuses default older than newest kernel" test_preflight_refuses_default_older_than_newest_kernel needs-rpmspec
run_test "preflight: refuses unowned running kernel" test_preflight_refuses_unowned_running_kernel needs-rpmspec
run_test "preflight: refuses apply_updates off"      test_preflight_refuses_apply_updates_off      needs-rpmspec
run_test "preflight: refuses apply_updates unset"    test_preflight_refuses_apply_updates_unset    needs-rpmspec
run_test "preflight: accepts operator automatic.conf" test_preflight_accepts_operator_automatic_conf needs-rpmspec
run_test "preflight: GRUB_SAVEDEFAULT only warns"    test_preflight_savedefault_only_warns         needs-rpmspec
run_test "preflight: refuses upgrade from pre-1.4"   test_preflight_refuses_upgrade_from_pre_1_4   needs-rpmspec
run_test "preflight: allows upgrade from 1.4"        test_preflight_allows_upgrade_from_1_4        needs-rpmspec

printf '\n'
if [[ "${TESTS_SKIPPED}" -gt 0 ]]; then
    printf '%s skipped:\n' "${TESTS_SKIPPED}"
    printf '  %s\n' "${SKIPPED_TEST_NAMES[@]}"
fi
if [[ "${TESTS_FAILED}" -eq 0 ]]; then
    printf '%s tests, all passed\n' "${TESTS_RUN}"
    exit 0
fi
printf '%s tests, %s FAILED:\n' "${TESTS_RUN}" "${TESTS_FAILED}"
printf '  %s\n' "${FAILED_TEST_NAMES[@]}"
exit 1
