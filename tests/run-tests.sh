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

    if [[ "${requirement}" == "needs-exec" && "${TEST_ROOT_IS_EXECUTABLE}" != "yes" ]]; then
        TESTS_SKIPPED=$(( TESTS_SKIPPED + 1 ))
        SKIPPED_TEST_NAMES+=("${test_name}")
        printf '  skip %s (temporary tree is noexec)\n' "${test_name}"
        rm -rf "${TEST_ROOT_DIR:?}" 2>/dev/null
        return 0
    fi

    TESTS_RUN=$(( TESTS_RUN + 1 ))
    test_output=$(
        set +e
        PATH="${TEST_ROOT_DIR}/stubbin:${PATH}"
        export PATH
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
    printf 'reboot = never\n' > "${TEST_ROOT_DIR}/etc/dnf/automatic.conf"
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
printf 'systemctl %s\n' "$*" >> "${STUB_LOG}"
[[ "${STUB_SYSTEMCTL_FAIL:-}" == "yes" ]] && exit 1
exit 0
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

    wall() { printf 'wall %s\n' "$*" >> "${STUB_LOG}"; }
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
# config: conf_get is section-blind, so key names must not collide
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
                      manage_kernel_default kernel_default_package \
                      enable_chrony_wait wall_messages; do
        resolved_value=$(conf_get "${config_key}" "MISSING")
        if [[ "${resolved_value}" == "MISSING" ]]; then
            fail "shipped config does not define ${config_key}"
        fi
    done
    return 0
}

test_config_prefix_keys_do_not_collide() {
    load_needs_reboot_library
    # restart_services must not pick up restart_services_exclude's value.
    assert_equals "yes" "$(conf_get restart_services MISSING)" "restart_services"
    assert_contains "$(conf_get restart_services_exclude MISSING)" "dbus.service" \
        "restart_services_exclude"
}

test_config_int_rejects_non_numeric() {
    load_needs_reboot_library
    printf '[timeouts]\nneeds_restarting_timeout_sec = abc\n' \
        > "${TEST_ROOT_DIR}/etc/dnf/automatic-reboot.conf"
    # The warning must not land on stdout: the caller assigns this to a
    # variable that then goes straight into `timeout <value>s`.
    assert_equals "120" "$(conf_get_int needs_restarting_timeout_sec 120 2>/dev/null)" \
        "non-numeric falls back to a clean default"
}

test_config_int_rejects_negative() {
    load_needs_reboot_library
    printf '[kernel]\nkernel_reboot_attempt_limit = -1\n' \
        > "${TEST_ROOT_DIR}/etc/dnf/automatic-reboot.conf"
    assert_equals "3" "$(conf_get_int kernel_reboot_attempt_limit 3 2>/dev/null)" \
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

test_state_kernel_attempts_cleared() {
    load_needs_reboot_library
    write_kernel_reboot_attempts kernel-uek "6.12.0-1.aarch64" 2
    write_kernel_reboot_attempts kernel-uek "-" 0
    assert_equals "0" "$(read_kernel_reboot_attempts kernel-uek '6.12.0-1.aarch64')" "cleared"
}

# ---------------------------------------------------------------------------
# learning: a confirmation must never outlive the EVR it was made for
# ---------------------------------------------------------------------------
test_learning_confirmed_same_evr_is_skipped() {
    load_needs_reboot_library
    export STUB_RPM_EVR="2.34-274"
    write_restart_state glibc "2.34-274" "boot-old" confirmed
    REBOOT_TRIGGER_PACKAGES=(glibc)
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
    apply_restart_state_learning >/dev/null 2>&1
    assert_equals "0" "${#REBOOT_TRIGGER_PACKAGES[@]}" "dropped after confirmation"
    assert_contains "$(read_restart_state glibc)" "confirmed" "state promoted"
}

test_learning_pending_same_boot_still_reboots() {
    load_needs_reboot_library
    export STUB_RPM_EVR="2.34-274"
    write_restart_state glibc "2.34-274" "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" pending
    REBOOT_TRIGGER_PACKAGES=(glibc)
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
# services: restarting the wrong unit takes the host down
# ---------------------------------------------------------------------------
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
write_watchdog_state() {
    local run_phase="$1" age_minutes="$2" recorded_pid="$3"
    local wall_clock_age_minutes="${4:-$2}"
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
    assert_not_contains "$(cat "${STUB_LOG}")" "kill" "a young run is never killed"
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
    assert_not_contains "$(cat "${STUB_LOG}")" "kill" "a wall-clock age never kills a run"
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
    assert_not_contains "$(cat "${STUB_LOG}")" "reboot" "a crashed run must not reboot"
    [[ -f "${TEST_ROOT_DIR}/run/dnf-automatic-reboot.state" ]] \
        && fail "stale state file should have been removed"
    return 0
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
    assert_not_contains "${recorded_calls}" "systemctl reboot" \
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
    assert_contains "$(cat "${STUB_LOG}")" "systemctl reboot" "opt-in override still works"
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
    assert_contains "${recorded_calls}" "systemctl reboot" "safe to reboot after a clean dnf"
}

test_watchdog_prefers_orderly_reboot() {
    sleep 60 &
    local background_pid=$!
    write_watchdog_state checking 200 "${background_pid}"
    bash "${REPO_ROOT}/scripts/watchdog.sh" >/dev/null 2>&1
    kill "${background_pid}" 2>/dev/null
    assert_not_contains "$(cat "${STUB_LOG}")" "reboot --force" \
        "--force is the fallback, never the first attempt"
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

printf 'state\n'
run_test "state: round trip"                         test_state_round_trip
run_test "state: replacement is exact field"         test_state_replacement_is_exact_field
run_test "state: kernel attempts keyed on target"    test_state_kernel_attempts_keyed_on_target
run_test "state: kernel attempts cleared"            test_state_kernel_attempts_cleared

printf 'learning\n'
run_test "learning: confirmed same evr is skipped"   test_learning_confirmed_same_evr_is_skipped
run_test "learning: pending after reboot confirms"   test_learning_pending_after_reboot_is_confirmed
run_test "learning: pending same boot still reboots" test_learning_pending_same_boot_still_reboots
run_test "learning: new evr restarts the cycle"      test_learning_new_evr_restarts_cycle

printf 'classify\n'
run_test "classify: withholds on stale grub default" test_classify_withholds_on_stale_grub_default
run_test "classify: withholds at attempt limit"      test_classify_withholds_at_attempt_limit
run_test "classify: schedules genuine kernel reboot" test_classify_schedules_genuine_kernel_reboot
run_test "classify: keeps package when verifier missing" test_classify_keeps_package_when_verifier_missing

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

printf 'services\n'
run_test "services: excluded units are not restarted" test_services_excluded_units_are_not_restarted needs-exec
run_test "services: disabled by config"              test_services_disabled_by_config

printf 'watchdog\n'
run_test "watchdog: no state file is a noop"         test_watchdog_no_state_file_is_a_noop
run_test "watchdog: dead pid does not reboot"        test_watchdog_dead_pid_does_not_reboot
run_test "watchdog: ignores wall clock step"         test_watchdog_ignores_wall_clock_step
run_test "watchdog: state without uptime is malformed" test_watchdog_state_without_uptime_is_malformed
run_test "watchdog: hard timeout while updating does not reboot" test_watchdog_hard_timeout_while_updating_does_not_reboot needs-exec
run_test "watchdog: hard timeout while updating can be forced"   test_watchdog_hard_timeout_while_updating_can_be_forced   needs-exec
run_test "watchdog: hard timeout while checking reboots"         test_watchdog_hard_timeout_while_checking_reboots         needs-exec
run_test "watchdog: prefers orderly reboot"          test_watchdog_prefers_orderly_reboot          needs-exec

printf '\n'
if [[ "${TESTS_SKIPPED}" -gt 0 ]]; then
    printf '%s skipped (temporary tree is noexec - run where /tmp allows exec):\n' "${TESTS_SKIPPED}"
    printf '  %s\n' "${SKIPPED_TEST_NAMES[@]}"
fi
if [[ "${TESTS_FAILED}" -eq 0 ]]; then
    printf '%s tests, all passed\n' "${TESTS_RUN}"
    exit 0
fi
printf '%s tests, %s FAILED:\n' "${TESTS_RUN}" "${TESTS_FAILED}"
printf '  %s\n' "${FAILED_TEST_NAMES[@]}"
exit 1
