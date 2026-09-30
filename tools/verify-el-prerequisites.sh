#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# verify-el-prerequisites.sh
# ---------------------------------------------------------------------------
# Read-only survey, run as root on a live host, of every platform fact this
# package relies on.  It establishes what running on Enterprise Linux 8 needs
# changed, and runs the same way on EL9, so the outputs of an EL8 and an EL9
# host can be compared line by line.
#
# Each line is PASS, FAIL or INFO and is tagged with the part of the package
# that depends on it:
#   PASS  the package as written works with this fact
#   FAIL  the package as written breaks on this host
#   INFO  a value to design against, or to compare between hosts
#
# The script does not change any file.  dnf runs only with `-C` (cache only)
# and only read-only subcommands.  The systemctl kill option probe names a unit that
# does not exist, so no process is signalled.
#
#   `sudo bash verify-el-prerequisites.sh > "$(hostname -s)-prerequisites.txt" 2>&1`
# ---------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

export LC_ALL=C

readonly COMMAND_TIMEOUT_SEC=120
readonly PROBE_UNIT=dnf-automatic-reboot-prerequisite-probe.service
# The advisory-id shape run.sh matches in warn_on_unapplied_security_advisories.
readonly ADVISORY_ID_PATTERN='^[A-Za-z]+(-[A-Za-z]+)*-[0-9]+[-:][0-9A-Za-z]+(-[0-9]+)?$'
# The line shape needs-reboot.sh parse_flagged_package_names accepts.
# What grub2-mkconfig's 00_header emits for GRUB_DEFAULT=saved; the %pre gate
# looks for it.  GRUB's own ${...} text, matched literally.
# shellcheck disable=SC2016
readonly SAVED_ENTRY_DEFAULT_LINE='set default="${saved_entry}"'
readonly FLAGGED_PACKAGE_SED='s/^[[:space:]]*\*[[:space:]]\+\([^[:space:]]\+\)[[:space:]]*$/\1/p'

FAILURE_COUNT=0

report_pass() { printf 'PASS  [%s] %s\n' "$1" "$2"; }
report_info() { printf 'INFO  [%s] %s\n' "$1" "$2"; }
report_fail() { printf 'FAIL  [%s] %s\n' "$1" "$2"; FAILURE_COUNT=$(( FAILURE_COUNT + 1 )); }

# report_lines AREA LABEL - INFO line per stdin line, prefixed with LABEL.
report_lines() {
    local area="$1" label="$2" input_line
    while IFS= read -r input_line; do
        [[ -n "${input_line}" ]] && report_info "${area}" "${label}: ${input_line}"
    done
    return 0
}

# first_file PATTERN... - prints the first existing file among the globs.
first_file() {
    local candidate_file
    for candidate_file in "$@"; do
        [[ -f "${candidate_file}" ]] && { printf '%s' "${candidate_file}"; return 0; }
    done
    return 0
}

if [[ "${EUID}" -ne 0 ]]; then
    printf 'WARNING: not root - grub.cfg, grubenv and /proc/1 reads will FAIL.\n' >&2
fi

# ---------------------------------------------------------------------------
printf '== platform\n'
# ---------------------------------------------------------------------------
report_info platform "os: $(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release)"
platform_id=$(sed -n 's/^PLATFORM_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release)
if [[ "${platform_id}" == "platform:el8" || "${platform_id}" == "platform:el9" ]]; then
    report_pass "%pre gate" "PLATFORM_ID=${platform_id}"
else
    report_fail "%pre gate" "PLATFORM_ID=${platform_id:-unset}; the gate accepts platform:el8 and platform:el9"
fi
report_info platform "arch: $(uname -m), kernel: $(uname -r)"
if [[ "${BASH_VERSINFO[0]}" -gt 4 || ( "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -ge 2 ) ]]; then
    report_pass scripts "bash ${BASH_VERSION} supports declare -gA"
else
    report_fail scripts "bash ${BASH_VERSION} is older than 4.2; needs-reboot.sh uses declare -gA"
fi

# ---------------------------------------------------------------------------
printf '== systemd\n'
# ---------------------------------------------------------------------------
systemd_version=$(systemctl --version 2>/dev/null | sed -n '1s/^systemd \([0-9]\+\).*/\1/p') || true
if [[ "${systemd_version}" =~ ^[0-9]+$ && "${systemd_version}" -ge 239 ]]; then
    report_pass spec "systemd ${systemd_version} meets Requires: systemd >= 239"
else
    report_fail spec "systemd ${systemd_version:-unknown} is below Requires: systemd >= 239"
fi

# watchdog.sh systemctl_kill_target_option: `--kill-whom` from systemd 252,
# `--kill-who` on older versions.  An unknown option fails in argument parsing, before systemctl looks
# up the unit; a known one reaches the lookup and fails on the missing unit.
if [[ "${systemd_version}" =~ ^[0-9]+$ && "${systemd_version}" -ge 252 ]]; then
    watchdog_kill_option=kill-whom
else
    watchdog_kill_option=kill-who
fi
for kill_option in kill-whom kill-who; do
    probe_output=$(systemctl kill "--${kill_option}=all" "${PROBE_UNIT}" 2>&1) || true
    if grep -qiE 'unrecognized option|unknown option|invalid option' <<< "${probe_output}"; then
        if [[ "${kill_option}" == "${watchdog_kill_option}" ]]; then
            report_fail watchdog.sh "systemctl kill --${kill_option}= is not accepted; kill_service_cgroup uses it on systemd ${systemd_version:-unknown}"
        else
            report_info watchdog.sh "systemctl kill --${kill_option}= is not accepted (not used on this systemd)"
        fi
    elif [[ "${kill_option}" == "${watchdog_kill_option}" ]]; then
        report_pass watchdog.sh "systemctl kill --${kill_option}= is accepted and used here (${probe_output%%$'\n'*})"
    else
        report_info watchdog.sh "systemctl kill --${kill_option}= is accepted (not used on this systemd)"
    fi
done

systemd_run_help=$(systemd-run --help 2>&1) || true
for systemd_run_option in --on-active --timer-property --description; do
    if grep -q -- "${systemd_run_option}" <<< "${systemd_run_help}"; then
        report_pass run.sh "systemd-run ${systemd_run_option}"
    else
        report_fail run.sh "systemd-run has no ${systemd_run_option}; schedule_reboot uses it"
    fi
done
if systemctl cat chrony-wait.service >/dev/null 2>&1; then
    report_info "%post" "chrony-wait.service exists, enabled: $(systemctl is-enabled chrony-wait.service 2>&1)"
else
    report_info "%post" "chrony-wait.service does not exist"
fi

# watchdog.sh recorded_pid_is_the_run reads MainPID this way; journald always runs.
main_pid_probe=$(systemctl show --property=MainPID --value systemd-journald.service 2>/dev/null) || true
if [[ "${main_pid_probe}" =~ ^[0-9]+$ ]]; then
    report_pass watchdog.sh "systemctl show --property=MainPID --value reports a PID (${main_pid_probe})"
else
    report_fail watchdog.sh "systemctl show --property=MainPID --value gave '${main_pid_probe}'; the PID check falls back to kill -0"
fi
# watchdog.sh times a run from /proc/uptime.
uptime_probe=""
read -r uptime_probe _ < /proc/uptime 2>/dev/null || true
if [[ "${uptime_probe%%.*}" =~ ^[0-9]+$ ]]; then
    report_pass watchdog.sh "/proc/uptime reads ${uptime_probe%%.*} seconds"
else
    report_fail watchdog.sh "/proc/uptime unreadable; the watchdog cannot time a run"
fi

# ---------------------------------------------------------------------------
printf '== dnf-automatic\n'
# ---------------------------------------------------------------------------
for dnf_package in dnf dnf-automatic python3-dnf-plugins-core yum-utils elfutils grubby; do
    report_info packages "$(rpm -q "${dnf_package}" 2>&1)"
done
automatic_main_file=$(first_file /usr/lib/python3*/site-packages/dnf/automatic/main.py)
if [[ -n "${automatic_main_file}" ]]; then
    report_info dnf-automatic "source: ${automatic_main_file}"
    grep -nE "add_option\('(apply_updates|download_updates|reboot|random_sleep|upgrade_type)'|if self.apply_updates|self.download_updates = True|opts.timer" \
        "${automatic_main_file}" | report_lines dnf-automatic "main.py" || true
else
    report_info dnf-automatic "dnf/automatic/main.py not found"
fi
if [[ -f /etc/dnf/automatic.conf ]]; then
    grep -E '^\s*(upgrade_type|random_sleep|download_updates|apply_updates|reboot)\s*=' /etc/dnf/automatic.conf \
        | report_lines "%pre gate" "automatic.conf" || true
else
    report_info "%pre gate" "/etc/dnf/automatic.conf does not exist"
fi
systemctl list-unit-files 'dnf-automatic*' --no-legend 2>/dev/null | report_lines run.sh "unit" || true

# automatic_conf_value KEY - the value as %pre and run.sh read it.
automatic_conf_value() {
    grep -E "^\s*$1\s*=" /etc/dnf/automatic.conf 2>/dev/null | tail -n 1 \
        | sed 's/^[^=]*=\s*//' | sed 's/\s*#.*//' | tr -d '[:space:]' || true
}
automatic_reboot_value=$(automatic_conf_value reboot)
if [[ -z "${automatic_reboot_value}" || "${automatic_reboot_value}" == "never" ]]; then
    report_pass "%pre gate" "automatic.conf reboot = ${automatic_reboot_value:-<unset>}"
else
    report_fail "%pre gate" "automatic.conf reboot = ${automatic_reboot_value}; the gate requires never"
fi
automatic_apply_updates_value=$(automatic_conf_value apply_updates | tr '[:upper:]' '[:lower:]')
case "${automatic_apply_updates_value}" in
    yes|true|1|on) report_pass "%pre gate" "automatic.conf apply_updates = ${automatic_apply_updates_value}" ;;
    *) report_fail "%pre gate" "automatic.conf apply_updates = ${automatic_apply_updates_value:-<unset>}; the gate requires yes" ;;
esac
for stock_timer in dnf-automatic.timer dnf-automatic-install.timer; do
    if systemctl is-enabled --quiet "${stock_timer}" 2>/dev/null; then
        report_fail "%pre gate" "${stock_timer} is enabled; the gate requires it disabled"
    else
        report_pass "%pre gate" "${stock_timer} is not enabled"
    fi
done

# ---------------------------------------------------------------------------
printf '== needs-restarting\n'
# ---------------------------------------------------------------------------
needs_restarting_plugin_file=$(first_file /usr/lib/python3*/site-packages/dnf-plugins/needs_restarting.py)
if [[ -n "${needs_restarting_plugin_file}" ]]; then
    report_info needs-reboot.sh "plugin: ${needs_restarting_plugin_file}"
    grep -nE "'  \* %s'|\"  \* %s\"|NEED_REBOOT = |needs-restarting.d|UnitsLoadStartTimestamp|btime|raise dnf.exceptions.Error|--services|--reboothint" \
        "${needs_restarting_plugin_file}" | report_lines needs-reboot.sh "plugin" || true
    if grep -qE "'  \* %s'|\"  \* %s\"" "${needs_restarting_plugin_file}"; then
        report_pass needs-reboot.sh "-r prints flagged packages as '  * <name>'"
    else
        report_fail needs-reboot.sh "no '  * %s' line format in the plugin; the allowlist parser would read nothing"
    fi
else
    report_fail needs-reboot.sh "needs_restarting.py not found"
fi

needs_restarting_help=$(timeout "${COMMAND_TIMEOUT_SEC}" dnf -q -C needs-restarting --help 2>&1) || true
for needs_restarting_option in -r -s; do
    if grep -qE -- "(^|[[:space:],])${needs_restarting_option}([[:space:],]|$)" <<< "${needs_restarting_help}"; then
        report_pass needs-reboot.sh "needs-restarting ${needs_restarting_option}"
    else
        report_fail needs-reboot.sh "needs-restarting has no ${needs_restarting_option}"
    fi
done

needs_restarting_stderr_file=$(mktemp)
needs_restarting_exit_code=0
needs_restarting_output=$(timeout "${COMMAND_TIMEOUT_SEC}" dnf -q -C needs-restarting -r \
                          2>"${needs_restarting_stderr_file}") || needs_restarting_exit_code=$?
report_info needs-reboot.sh "dnf -q -C needs-restarting -r exited ${needs_restarting_exit_code}"
printf '%s\n' "${needs_restarting_output}" | report_lines needs-reboot.sh "-r stdout" || true
report_lines needs-reboot.sh "-r stderr" < "${needs_restarting_stderr_file}" || true
report_info needs-reboot.sh "-r parsed names: $(printf '%s\n' "${needs_restarting_output}" | sed -n "${FLAGGED_PACKAGE_SED}" | paste -sd, -)"
# needs-reboot.sh reads exit 1 as "reboot needed"; a cache failure must not exit 1.
if [[ "${needs_restarting_exit_code}" -eq 1 && ! -s "${needs_restarting_stderr_file}" ]]; then
    report_pass needs-reboot.sh "exit 1 came with a package list, not an error"
elif [[ "${needs_restarting_exit_code}" -eq 1 ]]; then
    report_info needs-reboot.sh "exit 1 with stderr output: check whether that is a cache error read as 'reboot needed'"
fi
rm -f "${needs_restarting_stderr_file}"

stale_services_exit_code=0
stale_services_output=$(timeout "${COMMAND_TIMEOUT_SEC}" dnf -q -C needs-restarting -s 2>&1) || stale_services_exit_code=$?
report_info run.sh "dnf -q -C needs-restarting -s exited ${stale_services_exit_code}"
printf '%s\n' "${stale_services_output}" | head -n 15 | report_lines run.sh "-s" || true

# ---------------------------------------------------------------------------
printf '== security advisories\n'
# ---------------------------------------------------------------------------
updateinfo_help=$(timeout "${COMMAND_TIMEOUT_SEC}" dnf -q -C updateinfo --help 2>&1) || true
for updateinfo_option in --updates --security; do
    if grep -q -- "${updateinfo_option}" <<< "${updateinfo_help}"; then
        report_pass run.sh "dnf updateinfo ${updateinfo_option}"
    else
        report_fail run.sh "dnf updateinfo has no ${updateinfo_option}"
    fi
done
advisory_output=$(timeout "${COMMAND_TIMEOUT_SEC}" dnf -q -C updateinfo list --updates --security 2>&1) || true
printf '%s\n' "${advisory_output}" | head -n 5 | report_lines run.sh "updateinfo" || true
advisory_line_count=$(awk 'NF >= 3' <<< "${advisory_output}" | wc -l)
matching_advisory_count=$(awk -v pattern="${ADVISORY_ID_PATTERN}" 'NF >= 3 && $1 ~ pattern' <<< "${advisory_output}" | wc -l)
if [[ "${advisory_line_count}" -eq 0 ]]; then
    report_info run.sh "no pending security advisories to test the id pattern against"
elif [[ "${matching_advisory_count}" -eq 0 ]]; then
    report_fail run.sh "${advisory_line_count} advisory lines, none match ${ADVISORY_ID_PATTERN}; the unapplied-advisory warning never fires"
else
    report_pass run.sh "${matching_advisory_count} of ${advisory_line_count} advisory lines match ${ADVISORY_ID_PATTERN}"
fi
check_update_exit_code=0
timeout "${COMMAND_TIMEOUT_SEC}" dnf -q -C check-update --security >/dev/null 2>&1 || check_update_exit_code=$?
report_info run.sh "dnf -q -C check-update --security exited ${check_update_exit_code} (0 none, 100 available)"

# ---------------------------------------------------------------------------
printf '== boot loader\n'
# ---------------------------------------------------------------------------
if [[ -d /sys/firmware/efi ]]; then
    report_info "%pre gate" "firmware: EFI"
else
    report_info "%pre gate" "firmware: BIOS"
fi
grep -E '^GRUB_(ENABLE_BLSCFG|DEFAULT|SAVEDEFAULT|UPDATE_DEFAULT_KERNEL)=' /etc/default/grub 2>/dev/null \
    | report_lines "%pre gate" "/etc/default/grub" || true
report_info "%pre gate" "BLS entries: $(compgen -G '/boot/loader/entries/*.conf' | wc -l)"

# On EL9 EFI the ESP grub.cfg is a stub that loads /boot/grub2/grub.cfg; on
# EL8 EFI the ESP copy is the full config GRUB runs.
for grub_config_file in /boot/grub2/grub.cfg /boot/efi/EFI/*/grub.cfg; do
    [[ -e "${grub_config_file}" ]] || continue
    if grep -q '^[[:space:]]*configfile' "${grub_config_file}" 2>/dev/null; then
        grub_config_kind="stub (configfile)"
    else
        grub_config_kind="full config"
    fi
    if grep -qF "${SAVED_ENTRY_DEFAULT_LINE}" "${grub_config_file}" 2>/dev/null; then
        report_info "%pre gate" "${grub_config_file}: ${grub_config_kind}, boots saved_entry"
    else
        report_info "%pre gate" "${grub_config_file}: ${grub_config_kind}, no 'set default=\"\${saved_entry}\"'"
    fi
done
# The gate's rule: every full config (not a configfile stub) boots saved_entry.
full_grub_config_count=0
for grub_config_file in /boot/grub2/grub.cfg /boot/efi/EFI/*/grub.cfg; do
    [[ -f "${grub_config_file}" ]] || continue
    grep -q '^[[:space:]]*configfile' "${grub_config_file}" 2>/dev/null && continue
    full_grub_config_count=$(( full_grub_config_count + 1 ))
    if grep -qF "${SAVED_ENTRY_DEFAULT_LINE}" "${grub_config_file}" 2>/dev/null; then
        report_pass "%pre gate" "${grub_config_file} boots saved_entry"
    else
        report_fail "%pre gate" "${grub_config_file} is a full config that does not boot saved_entry"
    fi
done
if [[ "${full_grub_config_count}" -eq 0 ]]; then
    report_fail "%pre gate" "no full grub.cfg found in /boot/grub2 or /boot/efi/EFI/*"
fi

for grub_environment_file in /boot/grub2/grubenv /boot/efi/EFI/*/grubenv; do
    [[ -e "${grub_environment_file}" ]] || continue
    report_info needs-reboot.sh "${grub_environment_file} -> $(readlink -f "${grub_environment_file}")"
    grep -E '^(saved_entry|boot_counter|boot_success|kernelopts)=' "${grub_environment_file}" 2>/dev/null \
        | sed 's/^\(kernelopts=\).*/\1<set>/' | report_lines needs-reboot.sh "grubenv" || true
done

grub_default_kernel=$(grubby --default-kernel 2>/dev/null) || true
if [[ "${grub_default_kernel}" == /boot/vmlinuz-* && -e "${grub_default_kernel}" ]]; then
    report_pass needs-reboot.sh "grubby --default-kernel: ${grub_default_kernel}"
else
    report_fail needs-reboot.sh "grubby --default-kernel gave '${grub_default_kernel}'"
fi

if [[ -f /usr/lib/kernel/install.d/20-grub.install ]]; then
    grep -nE 'GRUB_UPDATE_DEFAULT_KERNEL|DEFAULTKERNEL|UPDATEDEFAULT|set-default|saved_entry|grub2-editenv' \
        /usr/lib/kernel/install.d/20-grub.install | report_lines "%pre gate" "20-grub.install" || true
else
    report_info "%pre gate" "/usr/lib/kernel/install.d/20-grub.install does not exist"
fi
if [[ -f /etc/sysconfig/kernel ]]; then
    grep -vE '^\s*(#|$)' /etc/sysconfig/kernel | report_lines "%pre gate" "/etc/sysconfig/kernel" || true
else
    report_info "%pre gate" "/etc/sysconfig/kernel does not exist"
fi

running_kernel_package=$(rpm -qf "/lib/modules/$(uname -r)/vmlinuz" --qf '%{NAME}\n' 2>/dev/null | head -n 1) || true
running_kernel_package_version=$(rpm -qf "/lib/modules/$(uname -r)/vmlinuz" --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | head -n 1) || true
report_info "%pre gate" "running kernel package: ${running_kernel_package:-none}"
if [[ "$(uname -r)" == "${running_kernel_package_version}" || "$(uname -r)" == "${running_kernel_package_version%".$(uname -m)"}" ]]; then
    report_pass needs-reboot.sh "uname -r equals the running kernel package's VERSION-RELEASE.ARCH"
else
    report_fail needs-reboot.sh "uname -r '$(uname -r)' differs from '${running_kernel_package_version}'; running_kernel_is_newest compares them"
fi
if grep -Eq '^GRUB_DEFAULT="?saved"?[[:space:]]*$' /etc/default/grub 2>/dev/null; then
    report_pass "%pre gate" "GRUB_DEFAULT=saved"
else
    report_fail "%pre gate" "GRUB_DEFAULT=saved is not set in /etc/default/grub"
fi
if grep -Eq '^GRUB_UPDATE_DEFAULT_KERNEL="?true"?[[:space:]]*$' /etc/default/grub 2>/dev/null; then
    report_pass "%pre gate" "GRUB_UPDATE_DEFAULT_KERNEL=true"
else
    report_fail "%pre gate" "GRUB_UPDATE_DEFAULT_KERNEL=true is not set in /etc/default/grub"
fi
configured_default_kernel=$(sed -n 's/^DEFAULTKERNEL=//p' /etc/sysconfig/kernel 2>/dev/null | tail -n 1) || true
if [[ "${platform_id}" != "platform:el9" ]]; then
    report_info "%pre gate" "DEFAULTKERNEL=${configured_default_kernel:-<unset>} (not checked: 20-grub.install reads it on EL9 only)"
elif [[ -n "${running_kernel_package}" && "${configured_default_kernel}" == "${running_kernel_package}" ]]; then
    report_pass "%pre gate" "DEFAULTKERNEL=${configured_default_kernel} names the running kernel package"
else
    report_fail "%pre gate" "DEFAULTKERNEL='${configured_default_kernel}', the running kernel package is '${running_kernel_package}'"
fi
if [[ -n "${running_kernel_package}" ]]; then
    newest_kernel_version=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' "${running_kernel_package}" | sort -V | tail -n 1) || true
    report_info needs-reboot.sh "newest installed ${running_kernel_package}: ${newest_kernel_version}"
    if [[ "${grub_default_kernel}" == "/boot/vmlinuz-${newest_kernel_version}" ]]; then
        report_pass "%pre gate" "the GRUB default is the newest installed ${running_kernel_package}"
    else
        report_fail "%pre gate" "the GRUB default '${grub_default_kernel}' is not /boot/vmlinuz-${newest_kernel_version}"
    fi
fi

# ---------------------------------------------------------------------------
printf '== build-id\n'
# ---------------------------------------------------------------------------
running_build_id=$(eu-readelf -n /proc/1/exe 2>/dev/null | awk '/Build ID/ {print $NF}') || true
on_disk_build_id=$(eu-readelf -n /usr/lib/systemd/systemd 2>/dev/null | awk '/Build ID/ {print $NF}') || true
if [[ -n "${running_build_id}" && -n "${on_disk_build_id}" ]]; then
    report_pass needs-reboot.sh "eu-readelf reads build-ids (PID 1 ${running_build_id}, on disk ${on_disk_build_id})"
else
    report_fail needs-reboot.sh "eu-readelf gave no build-id for /proc/1/exe or /usr/lib/systemd/systemd"
fi
report_info needs-reboot.sh "owner of /usr/lib/systemd/systemd: $(rpm -qf /usr/lib/systemd/systemd --qf '%{NAME}' 2>&1)"

# ---------------------------------------------------------------------------
printf '== commands\n'
# ---------------------------------------------------------------------------
for required_command in timeout flock pgrep ss wall awk stat logrotate systemd-tmpfiles \
                        systemd-inhibit systemd-run grubby eu-readelf restorecon rpmspec; do
    if command -v "${required_command}" >/dev/null 2>&1; then
        report_pass scripts "${required_command}"
    elif [[ "${required_command}" == "rpmspec" ]]; then
        report_info tests "rpmspec absent (rpm-build); needed only to run the %pre tests"
    else
        report_fail scripts "${required_command} not found"
    fi
done
if timeout --kill-after=1s 1s true 2>/dev/null; then
    report_pass run.sh "timeout --kill-after"
else
    report_fail run.sh "timeout has no --kill-after"
fi
report_info scripts "awk: $(awk --version 2>&1 | head -n 1)"

# ---------------------------------------------------------------------------
printf '== packaging\n'
# ---------------------------------------------------------------------------
report_info spec "$(rpm --version)"
report_info spec "_unitdir=$(rpm --eval '%{_unitdir}') _tmpfilesdir=$(rpm --eval '%{_tmpfilesdir}') _libexecdir=$(rpm --eval '%{_libexecdir}')"
report_info spec "systemd_post macro: $(rpm --eval '%{?systemd_post:defined}%{!?systemd_post:undefined}')"
report_info spec "systemd-rpm-macros provided by: $(rpm -q --whatprovides systemd-rpm-macros 2>&1)"

# ---------------------------------------------------------------------------
printf '== SELinux\n'
# ---------------------------------------------------------------------------
report_info selinux "mode: $(getenforce 2>&1)"
for labelled_path in /usr/libexec/dnf-automatic-reboot/run.sh /var/lib/dnf-automatic-reboot \
                     /var/log/dnf-automatic-reboot.log /etc/dnf/automatic-reboot.conf; do
    report_info selinux "$(matchpathcon "${labelled_path}" 2>&1)"
done

printf '\n'
if [[ "${FAILURE_COUNT}" -eq 0 ]]; then
    printf 'RESULT: no FAIL - the package as written has what it needs on this host.\n'
    exit 0
fi
printf 'RESULT: %s FAIL - each FAIL line names the part of the package to change.\n' "${FAILURE_COUNT}"
exit 1
