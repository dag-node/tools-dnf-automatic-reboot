# SPDX-License-Identifier: MIT
Name:           dnf-automatic-reboot
Version:        1.5.0
# Plain "1" for a release; CI passes --define "rpm_release 0.<run>.git<sha>"
# for a snapshot build.  The leading "0." makes rpm rank the release above
# every snapshot that preceded it, so a trial build upgrades to it in place.
Release:        %{!?rpm_release:1}%{?rpm_release}%{?dist}
Summary:        Unattended update and conditional reboot for EL8 and EL9

License:        GPL-2.0-or-later
URL:            https://github.com/dag-node/tools-dnf-automatic-reboot
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch

# dnf-automatic provides the /usr/bin/dnf-automatic binary we call
Requires:       dnf-automatic
# %%pre reads /etc/dnf/automatic.conf, which dnf-automatic installs.
Requires(pre):  dnf-automatic
# needs-restarting is provided by yum-utils on EL8 and EL9 (confirmed via
# `rpm -qf` against the live binary; dnf-plugins-core does not own it)
Requires:       yum-utils
# systemd-inhibit, systemd-run, wall are all in systemd or util-linux.
# 239 is EL8's.  The watchdog signals the whole service cgroup with
# `systemctl kill --kill-who=all` there and `--kill-whom=all` from 252, the
# release that renamed the option; watchdog.sh picks the spelling at runtime.
Requires:       systemd >= 239
Requires:       util-linux
# eu-readelf for systemd build-id comparison (false-positive detection)
Requires:       elfutils
# grubby reads the GRUB BLS default: needs-reboot.sh verifies it before a
# kernel reboot, and %%pre refuses a host where it does not answer - hence
# also Requires(pre).
Requires:       grubby
Requires(pre):  grubby
# logrotate consumes the drop-in in %%{_sysconfdir}/logrotate.d; without it
# /var/log/dnf-automatic-reboot.log grows without bound
Requires:       logrotate
# run.sh installs nothing until `chronyc waitsync` confirms the clock
# (require_clock_sync = yes by default).  Installed is not running: the
# runtime check stays.
Requires:       chrony

# We install systemd unit files
BuildRequires:  systemd-rpm-macros
# %%check runs `make check`, which needs make, awk and flock
BuildRequires:  make
BuildRequires:  gawk
BuildRequires:  util-linux

%description
Companion service to dnf-automatic that:

  - Holds a systemd shutdown inhibitor during updates to prevent
    corruption from an accidental reboot mid-update.
  - Filters false-positive reboot triggers with positive evidence:
    kernel version comparison against the running kernel, and ELF
    build-id comparison for daemons whose package was reinstalled.
  - Detects genuine update-triggered reboot requirements and schedules
    a timed reboot, refusing to reboot into a kernel the GRUB default
    would not select.
  - Restarts services still mapping pre-update files, which
    needs-restarting -r does not report.
  - Provides an independent watchdog with configurable soft and hard
    timeouts to recover from hung updates without operator intervention.
  - Warns logged-in users via wall(1) at all key events.

All behaviour is controlled by /etc/dnf/automatic-reboot.conf.

%prep
%autosetup

%build
# Nothing to compile - shell scripts only

%check
# Syntax, lint and the test suite.  The suite stubs every external command, so
# it neither touches the build host nor needs root; tests that must exec a stub
# skip themselves where the build root is mounted noexec.
make check

# Package-private script directory.  /usr/libexec is the FHS location for
# programs a package runs but users do not; /usr/local is reserved for the
# local administrator and must not be written by an RPM.  It also carries
# bin_t from the base SELinux policy, which /usr/local/lib does not.
%global pkglibexecdir %{_libexecdir}/%{name}

%install
# Scripts
install -d -m 0755 %{buildroot}%{pkglibexecdir}
install -m 0750 scripts/run.sh            %{buildroot}%{pkglibexecdir}/run.sh
install -m 0750 scripts/watchdog.sh       %{buildroot}%{pkglibexecdir}/watchdog.sh
install -m 0750 scripts/needs-reboot.sh   %{buildroot}%{pkglibexecdir}/needs-reboot.sh
install -m 0750 scripts/notify-failure.sh %{buildroot}%{pkglibexecdir}/notify-failure.sh
install -m 0750 scripts/cancel-reboot.sh  %{buildroot}%{pkglibexecdir}/cancel-reboot.sh
install -m 0750 scripts/reboot-if-pending.sh %{buildroot}%{pkglibexecdir}/reboot-if-pending.sh
install -m 0640 scripts/reboot-request.sh %{buildroot}%{pkglibexecdir}/reboot-request.sh
install -m 0640 scripts/run-state.sh      %{buildroot}%{pkglibexecdir}/run-state.sh

# systemd units
install -d -m 0755 %{buildroot}%{_unitdir}
install -m 0644 units/dnf-automatic-reboot.service          %{buildroot}%{_unitdir}/
install -m 0644 units/dnf-automatic-reboot.timer            %{buildroot}%{_unitdir}/
install -m 0644 units/dnf-automatic-watchdog.service        %{buildroot}%{_unitdir}/
install -m 0644 units/dnf-automatic-watchdog.timer          %{buildroot}%{_unitdir}/
install -m 0644 units/dnf-automatic-reboot-notify@.service %{buildroot}%{_unitdir}/

# Config file - noreplace preserves local edits on upgrade
install -d -m 0755 %{buildroot}%{_sysconfdir}/dnf
install -m 0640 conf/automatic-reboot.conf \
    %{buildroot}%{_sysconfdir}/dnf/automatic-reboot.conf

# tmpfiles.d - owns the mode and label of the log and state paths
install -d -m 0755 %{buildroot}%{_tmpfilesdir}
install -m 0644 tmpfiles/%{name}.conf %{buildroot}%{_tmpfilesdir}/%{name}.conf

# logrotate.d
install -d -m 0755 %{buildroot}%{_sysconfdir}/logrotate.d
install -m 0644 logrotate/%{name} %{buildroot}%{_sysconfdir}/logrotate.d/%{name}

# Documentation
install -d -m 0755 %{buildroot}%{_docdir}/%{name}
install -m 0644 doc/README %{buildroot}%{_docdir}/%{name}/README

# Log file placeholder so RPM owns the path and its SELinux label
install -d -m 0755 %{buildroot}%{_localstatedir}/log
touch %{buildroot}%{_localstatedir}/log/%{name}.log

# State directory for the false-positive learning tracker
install -d -m 0750 %{buildroot}%{_localstatedir}/lib/%{name}

%pre -p /bin/bash
# Pre-install gate.  Every check reports and sets FAIL; the install is refused
# once, at the end, with every problem listed, before any file is touched.
# The host must be one this package can reboot safely and decide for: EL9,
# booted by systemd, GRUB2 in BLS mode with a default grubby can read.
#
# %%{?preflight_root} is empty in every built RPM.  tests/run-tests.sh expands
# this scriptlet with `rpmspec --define` to point the file checks at a fixture
# tree, so the gate is tested without any runtime switch that could bypass it.
FAIL=0
readonly PREFLIGHT_ROOT="%{?preflight_root}"

# Versions before 1.4.0 were only ever installed from locally built RPMs, and
# no upgrade path from them is maintained: their paths, state files and
# scriptlets differ, and this package does not migrate them.  An upgrade over one is
# refused before any file is touched, naming the removal instead.  $1 is the
# number of instances after this transaction, so 2 or more is an upgrade.
readonly MINIMUM_UPGRADABLE_VERSION=1.4.0
if [[ "$1" -gt 1 ]]; then
    for installed_version in $(rpm -q --qf '%%{VERSION}\n' %{name} 2>/dev/null); do
        oldest_version=$(printf '%s\n%s\n' "${installed_version}" "${MINIMUM_UPGRADABLE_VERSION}" \
                         | sort -V | head -1)
        if [[ "${installed_version}" != "${MINIMUM_UPGRADABLE_VERSION}" \
              && "${oldest_version}" == "${installed_version}" ]]; then
            echo "ERROR: %{name} ${installed_version} is installed; upgrading from a version" >&2
            echo "       before ${MINIMUM_UPGRADABLE_VERSION} is not supported." >&2
            echo "       Remove it first:  dnf remove %{name}" >&2
            echo "       then install this package and re-enable its timers." >&2
            FAIL=1
        fi
    done
fi

# EL8 and EL9.  Every rebuild of them (RHEL, Oracle Linux, Rocky, Alma) sets
# PLATFORM_ID=platform:el8 or platform:el9.  EL10 is untested and refused
# rather than half-working.
platform_id=$(sed -n 's/^PLATFORM_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' \
              "${PREFLIGHT_ROOT}/etc/os-release" 2>/dev/null) || true
if [[ "${platform_id}" != "platform:el8" && "${platform_id}" != "platform:el9" ]]; then
    echo "ERROR: this host is '${platform_id:-unknown}', not platform:el8 or platform:el9." >&2
    echo "       %{name} %{version} supports EL8 and EL9 only." >&2
    FAIL=1
fi

# systemd must be the running init: the package is timers, an inhibitor lock
# and a transient reboot timer.  Absent in a container, chroot or image build.
if [[ ! -d "${PREFLIGHT_ROOT}/run/systemd/system" ]]; then
    echo "ERROR: systemd is not the running init (no /run/systemd/system)." >&2
    echo "       Install on a booted host, not in a container, chroot or image build." >&2
    FAIL=1
fi

# The packages every decision depends on.  Requires: covers a normal install;
# this catches `rpm -i --nodeps`, which would otherwise leave the build-id or
# GRUB check silently disabled at runtime.
for required_package in dnf-automatic yum-utils elfutils grubby chrony; do
    if ! rpm -q "${required_package}" >/dev/null 2>&1; then
        echo "ERROR: ${required_package} is not installed." >&2
        echo "       Install it first:  dnf install ${required_package}" >&2
        FAIL=1
    fi
done

# GRUB2 with Boot Loader Specification entries.  The kernel reboot decision
# compares `grubby --default-kernel` against the newest installed kernel, and
# %%post repairs that default on UEK; neither means anything under another
# bootloader, where a kernel reboot could return to the old kernel on every run.
if ! grep -Eq '^GRUB_ENABLE_BLSCFG="?true"?[[:space:]]*$' "${PREFLIGHT_ROOT}/etc/default/grub" 2>/dev/null; then
    echo "ERROR: GRUB_ENABLE_BLSCFG=true is not set in /etc/default/grub." >&2
    echo "       %{name} requires GRUB2 with Boot Loader Specification entries." >&2
    FAIL=1
fi
if ! compgen -G "${PREFLIGHT_ROOT}/boot/loader/entries/*.conf" >/dev/null; then
    echo "ERROR: /boot/loader/entries holds no BLS entry." >&2
    echo "       %{name} requires GRUB2 with Boot Loader Specification entries." >&2
    FAIL=1
fi
grub_default_kernel=$(grubby --default-kernel 2>/dev/null) || true
if [[ "${grub_default_kernel}" != /boot/vmlinuz-* \
      || ! -e "${PREFLIGHT_ROOT}${grub_default_kernel}" ]]; then
    echo "ERROR: grubby --default-kernel gave '${grub_default_kernel}', not an existing /boot/vmlinuz-*." >&2
    echo "       Repair the default first:  grubby --set-default /boot/vmlinuz-\$(uname -r)" >&2
    FAIL=1
fi

# GRUB must boot the entry grubby reads and sets.  grubby works on
# saved_entry; grub2-mkconfig emits 'set default="${saved_entry}"' only when
# built with GRUB_DEFAULT=saved, and a fixed default otherwise.  The generated
# grub.cfg is what GRUB runs today; /etc/default/grub is what the next
# grub2-mkconfig will produce; the gate reads grub.cfg and /etc/default/grub.
# Which grub.cfg GRUB runs differs: on EL9 EFI the ESP copy is a stub that
# loads /boot/grub2/grub.cfg (it holds `configfile`), on EL8 EFI the ESP copy
# is the full config.  Every full config found must boot saved_entry.  The
# repair runs `grub2-mkconfig -o <that file>` without `--update-bls-cmdline`:
# the default is set in grub.cfg, and that flag rewrites the options line of
# every BLS entry from GRUB_CMDLINE_LINUX.
full_grub_config_count=0
for grub_config_file in "${PREFLIGHT_ROOT}/boot/grub2/grub.cfg" "${PREFLIGHT_ROOT}"/boot/efi/EFI/*/grub.cfg; do
    [[ -f "${grub_config_file}" ]] || continue
    grep -q '^[[:space:]]*configfile' "${grub_config_file}" 2>/dev/null && continue
    full_grub_config_count=$(( full_grub_config_count + 1 ))
    if ! grep -qF 'set default="${saved_entry}"' "${grub_config_file}" 2>/dev/null; then
        grub_config_path="${grub_config_file#"${PREFLIGHT_ROOT}"}"
        echo "ERROR: ${grub_config_path} does not boot saved_entry, so the default grubby reads" >&2
        echo "       and sets is not the one GRUB boots." >&2
        echo "       Set GRUB_DEFAULT=saved in /etc/default/grub, then:  grub2-mkconfig -o ${grub_config_path}" >&2
        FAIL=1
    fi
done
if [[ "${full_grub_config_count}" -eq 0 ]]; then
    echo "ERROR: no grub.cfg found in /boot/grub2 or /boot/efi/EFI/*." >&2
    echo "       %{name} requires GRUB2 with Boot Loader Specification entries." >&2
    FAIL=1
fi
if ! grep -Eq '^GRUB_DEFAULT="?saved"?[[:space:]]*$' "${PREFLIGHT_ROOT}/etc/default/grub" 2>/dev/null; then
    echo "ERROR: GRUB_DEFAULT=saved is not set in /etc/default/grub; the next grub2-mkconfig" >&2
    echo "       would stop GRUB booting saved_entry." >&2
    echo "       Set it:  GRUB_DEFAULT=saved" >&2
    FAIL=1
fi

# A kernel update must advance saved_entry, or every kernel reboot returns to
# the old kernel and is withheld at runtime.  kernel-install's 20-grub.install
# moves saved_entry only when /etc/default/grub has
# GRUB_UPDATE_DEFAULT_KERNEL=true; the EL9 version also requires
# /etc/sysconfig/kernel to name the kernel's package in DEFAULTKERNEL, the EL8
# version does not read DEFAULTKERNEL.  Both files belong to the operator, so
# a host without the settings is refused with the lines to add; neither file
# is edited here.
running_kernel_package=$(rpm -qf "/lib/modules/$(uname -r)/vmlinuz" --qf '%%{NAME}\n' 2>/dev/null | head -1) || true
if [[ -z "${running_kernel_package}" ]]; then
    echo "ERROR: no package owns /lib/modules/$(uname -r)/vmlinuz; cannot tell which kernel" >&2
    echo "       package kernel updates must make the default." >&2
    FAIL=1
else
    if ! grep -Eq '^GRUB_UPDATE_DEFAULT_KERNEL="?true"?[[:space:]]*$' "${PREFLIGHT_ROOT}/etc/default/grub" 2>/dev/null; then
        echo "ERROR: kernel updates will not advance the GRUB default. kernel-install moves" >&2
        echo "       saved_entry only with, in /etc/default/grub:  GRUB_UPDATE_DEFAULT_KERNEL=true" >&2
        FAIL=1
    fi
    configured_default_kernel=$(sed -n 's/^DEFAULTKERNEL=//p' "${PREFLIGHT_ROOT}/etc/sysconfig/kernel" 2>/dev/null | tail -1) || true
    if [[ "${platform_id}" == "platform:el9" && "${configured_default_kernel}" != "${running_kernel_package}" ]]; then
        echo "ERROR: kernel updates will not advance the GRUB default. On EL9 kernel-install" >&2
        echo "       moves saved_entry only for the package named in /etc/sysconfig/kernel:" >&2
        echo "         DEFAULTKERNEL=${running_kernel_package}  (found: '${configured_default_kernel}')" >&2
        FAIL=1
    fi

    # The default must already be the newest installed kernel of that package,
    # or every kernel reboot is withheld at runtime.  It is not set here:
    # setting it changes which kernel the next boot runs, which may be one an
    # operator left behind on purpose.
    newest_kernel_version=$(rpm -q --qf '%%{VERSION}-%%{RELEASE}.%%{ARCH}\n' "${running_kernel_package}" 2>/dev/null \
                            | sort -V | tail -1) || true
    if [[ -n "${newest_kernel_version}" && "${grub_default_kernel}" == /boot/vmlinuz-* \
          && "${grub_default_kernel}" != "/boot/vmlinuz-${newest_kernel_version}" ]]; then
        echo "ERROR: the GRUB default is ${grub_default_kernel}, not the newest installed" >&2
        echo "       ${running_kernel_package} ${newest_kernel_version}, so kernel reboots would be withheld." >&2
        echo "       If that kernel should run:  grubby --set-default /boot/vmlinuz-${newest_kernel_version}" >&2
        FAIL=1
    fi
fi

# Not a prerequisite, but it changes what the runtime check reports.  With
# GRUB_SAVEDEFAULT=true the entry booted is saved as the default, so picking an
# older kernel from the menu once makes it the default; a kernel reboot is
# then withheld with an error until the default is set back.
if grep -Eq '^GRUB_SAVEDEFAULT="?true"?[[:space:]]*$' "${PREFLIGHT_ROOT}/etc/default/grub" 2>/dev/null; then
    echo "WARNING: GRUB_SAVEDEFAULT=true: booting an older kernel from the GRUB menu makes it the" >&2
    echo "         default, and kernel reboots are withheld until:  grubby --set-default <newest>" >&2
fi

# Conflicting timers must be disabled; dnf-automatic-reboot owns the schedule.
for timer in dnf-automatic.timer dnf-automatic-install.timer; do
    if systemctl is-enabled --quiet "${timer}" 2>/dev/null; then
        echo "ERROR: ${timer} is still enabled." >&2
        echo "       dnf-automatic-reboot replaces its scheduling and reboot handling." >&2
        echo "       Disable it first:  systemctl disable --now ${timer}" >&2
        FAIL=1
    fi
done

# /etc/dnf/automatic.conf must not trigger reboots itself; this package does that.
ACONF="${PREFLIGHT_ROOT}/etc/dnf/automatic.conf"
if [[ -f "${ACONF}" ]]; then
    reboot_val=$(grep -E '^\s*reboot\s*=' "${ACONF}" 2>/dev/null \
                 | tail -1 | sed 's/^[^=]*=\s*//' | sed 's/\s*#.*//' \
                 | tr -d '[:space:]') || true
    if [[ -n "${reboot_val}" && "${reboot_val}" != "never" ]]; then
        echo "ERROR: /etc/dnf/automatic.conf has 'reboot = ${reboot_val}'." >&2
        echo "       dnf-automatic must not reboot independently of this package." >&2
        echo "       Set it to 'never' in /etc/dnf/automatic.conf:  reboot = never" >&2
        FAIL=1
    fi
fi

# dnf-automatic must install what it downloads.  apply_updates defaults to
# false in dnf-automatic, which then exits 0 after downloading, so every run
# would report success without installing an update.  The file is the
# operator's: this scriptlet reads it and does not write it.  True values are those libdnf's
# OptionBool accepts.
apply_updates_value=$(grep -E '^\s*apply_updates\s*=' "${ACONF}" 2>/dev/null \
                      | tail -1 | sed 's/^[^=]*=\s*//' | sed 's/\s*#.*//' \
                      | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]') || true
case "${apply_updates_value}" in
    yes|true|1|on) ;;
    *)
        echo "ERROR: /etc/dnf/automatic.conf has 'apply_updates = ${apply_updates_value:-<unset>}'." >&2
        echo "       dnf-automatic would download updates without installing them." >&2
        echo "       Set it in /etc/dnf/automatic.conf:  apply_updates = yes" >&2
        FAIL=1
        ;;
esac

if [[ "${FAIL}" -ne 0 ]]; then
    echo "" >&2
    echo "Installation aborted. Resolve the issues above and retry." >&2
    exit 1
fi

%post
# Reload systemd unit files
%systemd_post dnf-automatic-reboot.service
%systemd_post dnf-automatic-reboot.timer
%systemd_post dnf-automatic-watchdog.service
%systemd_post dnf-automatic-watchdog.timer

# Create the log file and state directory with the packaged mode and label
# before any script writes to them.
systemd-tmpfiles --create %{_tmpfilesdir}/%{name}.conf >/dev/null 2>&1 || true

# Scripts live under %{_libexecdir}, which the base SELinux policy labels
# bin_t; restorecon reapplies that after install.
if [ -x /sbin/restorecon ]; then
    restorecon -Rv %{pkglibexecdir}/ \
                   %{_sysconfdir}/dnf/automatic-reboot.conf \
                   %{_localstatedir}/log/%{name}.log \
                   %{_localstatedir}/lib/%{name} \
                   2>/dev/null || true
fi

ARC_CONF=/etc/dnf/automatic-reboot.conf
arc_conf_get() {
    _val=$(grep -E "^[[:space:]]*$1[[:space:]]*=" "${ARC_CONF}" 2>/dev/null \
           | tail -1 | sed 's/^[^=]*=[[:space:]]*//' | sed 's/[[:space:]]*#.*//') || true
    if [ -n "${_val}" ]; then printf '%s' "${_val}"; else printf '%s' "$2"; fi
}

# ---------------------------------------------------------------------------
# Real time-sync.target gate.
#
# The service unit orders itself After=/Requires=time-sync.target so rpm
# INSTALLTIME stamps and the boot-time comparison inside needs-restarting see
# a correct clock.  On UEK R8 systemd-time-wait-sync.service does not exist
# and nothing else is ordered Before=time-sync.target, so that dependency is
# satisfied trivially.  chrony ships chrony-wait.service - `chronyc waitsync`,
# ordered Before=time-sync.target - disabled by default; enabling it is what
# makes the ordering mean anything.
#
# Enabling another package's unit cannot be expressed as a preset of ours, so
# this is the one deliberate exception to the macro-only scriptlet rule.  Never
# disabled on erase: a synchronised clock is not this package's to take away.
# ---------------------------------------------------------------------------
ARC_CHRONY_WAIT=$(arc_conf_get enable_chrony_wait yes)
if [ "${ARC_CHRONY_WAIT}" = "yes" ] \
   && systemctl cat chrony-wait.service >/dev/null 2>&1 \
   && ! systemctl is-enabled --quiet chrony-wait.service 2>/dev/null; then
    if systemctl --no-reload enable chrony-wait.service >/dev/null 2>&1; then
        echo "dnf-automatic-reboot: enabled chrony-wait.service - time-sync.target now waits for real clock sync"
    fi
fi

echo ""
echo "dnf-automatic-reboot installed."
echo ""
echo "Next steps:"
echo "  1. Review /etc/dnf/automatic-reboot.conf"
echo "  2. Enable this package:"
echo "       systemctl enable --now dnf-automatic-reboot.timer dnf-automatic-watchdog.timer"

%preun
%systemd_preun dnf-automatic-reboot.service
%systemd_preun dnf-automatic-reboot.timer
%systemd_preun dnf-automatic-watchdog.service
%systemd_preun dnf-automatic-watchdog.timer
# chrony-wait.service is deliberately left enabled: it belongs to chrony and a
# synchronised clock is not this package's to remove.

%postun
%systemd_postun_with_restart dnf-automatic-reboot.timer
%systemd_postun_with_restart dnf-automatic-watchdog.timer

%files
%license LICENSE
%doc     %{_docdir}/%{name}/README

# Scripts - bin_t so systemd can exec them directly.
# 0750 root:root: executed by systemd as root; no world read/exec needed
# (mirrors the 0640 config hardening).
%dir %attr(0755, root, root) %{pkglibexecdir}
%attr(0750, root, root) %{pkglibexecdir}/run.sh
%attr(0750, root, root) %{pkglibexecdir}/watchdog.sh
%attr(0750, root, root) %{pkglibexecdir}/needs-reboot.sh
%attr(0750, root, root) %{pkglibexecdir}/notify-failure.sh
%attr(0750, root, root) %{pkglibexecdir}/cancel-reboot.sh
%attr(0750, root, root) %{pkglibexecdir}/reboot-if-pending.sh
# Sourced by run.sh, watchdog.sh, cancel-reboot.sh and reboot-if-pending.sh;
# never executed.
%attr(0640, root, root) %{pkglibexecdir}/reboot-request.sh
# Sourced by run.sh and watchdog.sh; never executed.
%attr(0640, root, root) %{pkglibexecdir}/run-state.sh

# systemd units
%{_unitdir}/dnf-automatic-reboot.service
%{_unitdir}/dnf-automatic-reboot.timer
%{_unitdir}/dnf-automatic-watchdog.service
%{_unitdir}/dnf-automatic-watchdog.timer
# Failure notifier, instantiated by OnFailure= with the failed unit name
%{_unitdir}/dnf-automatic-reboot-notify@.service

# Config - preserved across upgrades; root:root 640 (no world read for safety)
%config(noreplace) %attr(0640, root, root) %{_sysconfdir}/dnf/automatic-reboot.conf

# tmpfiles.d - creates the log and state paths with the modes declared below
%{_tmpfilesdir}/%{name}.conf

# logrotate.d - admin-editable, so noreplace
%config(noreplace) %{_sysconfdir}/logrotate.d/%{name}

# Log file - created by systemd-tmpfiles, %%ghost so RPM owns the path and its
# SELinux label without owning the content
%ghost %attr(0640, root, root) %{_localstatedir}/log/%{name}.log

# State directory - package-exclusive, unlike /var/log which the filesystem
# package owns, so it needs an explicit %%dir entry to be tracked, labeled and
# removed on erase.  %%ghost on the files: same pattern as the log above.
%dir %attr(0750, root, root) %{_localstatedir}/lib/%{name}
%ghost %attr(0640, root, root) %{_localstatedir}/lib/%{name}/restart-state
%ghost %attr(0640, root, root) %{_localstatedir}/lib/%{name}/kernel-reboot-attempts

%changelog
* Thu Oct 01 2026 DagNode <packages@dagnode.com> - 1.5.0-1
- CHANGE: A pending reboot holds update runs through its own marker,
  /run/dnf-automatic-reboot.reboot-pending, created before the reboot is requested and removed
  by the reboot or by cancelling it. It covers the reboots run.sh schedules as well as the
  watchdog's, so no update run starts in reboot_delay_sec before either.
  /run/dnf-automatic-reboot.recovery now covers only the watchdog's recovery and is always
  removed when the watchdog ends.
- CHANGE: Every reboot, the watchdog's immediate one included, runs
  /usr/libexec/dnf-automatic-reboot/reboot-if-pending.sh in the transient
  dnf-automatic-reboot-scheduled-reboot.service, which reboots only while the reboot is still
  pending.
- CHANGE: run.sh does not update while a scheduled reboot is waiting or under way. This also
  holds when upgrading from 1.4.0 while its watchdog has a reboot scheduled.
- CHANGE: reboot_delay_sec defaults to 300, giving five minutes between the warning and the
  reboot to cancel it. An edited automatic-reboot.conf keeps its own value.
- NEW: /usr/libexec/dnf-automatic-reboot/cancel-reboot.sh cancels a pending reboot and allows
  update runs again; a timer that fires afterwards does not reboot. It exits 1 without
  changing anything while a reboot is being requested or carried out, once systemctl reboot
  has been called, while the host shuts down (including a shutdown logind delays for an
  inhibitor), and when systemd's state cannot be read. It replaces stopping the timer and
  removing the recovery file by hand.
- NEW: reboot_request_lock_wait_sec (default 60) bounds how long a reboot request waits for a
  cancellation or another request to finish.
- FIX: A watchdog that failed or timed out while a reboot it had scheduled was pending removed
  the file that held update runs, so an update could start before that reboot.
- FIX: A reboot request whose outcome cannot be established keeps update runs held and fails
  the run or watchdog, naming the commands to check and recover; a reboot that reaches systemd
  late still happens. This covers an interrupted request and a failed systemd-run.
- FIX: When the orderly reboot reports failure, the watchdog's reboot checks whether the host
  is already shutting down before it falls back to systemctl reboot --force, and does not force
  when it cannot tell.
- FIX: A timer that has elapsed is no longer taken for a reboot still to come, so a reboot that
  failed earlier no longer stops a new one from being scheduled.
- FIX: The kernel reboot attempt count is cleared once the target kernel runs, also on a host
  with a correct clock. There needs-restarting stops flagging the kernel after the reboot, and
  the count stayed until the next kernel update replaced it.
- FIX: An update run installs nothing until chronyd confirms the clock synchronised, waiting at
  most clock_sync_wait_sec (new, default 600, enforced with timeout); otherwise it fails. The
  package now requires chrony. The unit's ordering after
  time-sync.target did not require synchronisation to succeed, so a failed chrony-wait.service
  let updates run with a wrong clock. require_clock_sync = no (new) turns the check off.
- FIX: The reboot respects shutdown inhibitors. From a service, systemctl reboot skipped the
  inhibitor check, so a package transaction started by hand during reboot_delay_sec could be cut
  off. A refused reboot is retried every 30 seconds for reboot_inhibited_wait_sec (new, default
  1800) and can be cancelled meanwhile. The watchdog no longer falls back to
  systemctl reboot --force.
- FIX: The watchdog no longer removes the state file of a run it did not inspect. run.sh wrote the
  file in place, and a watchdog reading it at that moment found it empty and deleted it as
  malformed; cleanup after a dead run could delete the state of the run that started next. Either
  left that run unsupervised. The file is now published by rename and removed, under a lock,
  only while it holds what the watchdog read.
- FIX: Restart-state learning no longer drops a package that the build-id check found running
  stale code, or could not verify. A systemd flag with a stale daemon could be recorded as a
  confirmed false positive and the reboot skipped.
- FIX: No reboot is requested, and the run fails, when a kernel reboot attempt cannot be recorded
  in /var/lib/dnf-automatic-reboot/kernel-reboot-attempts, even when another package needs one. A failed write was ignored, so
  kernel_reboot_attempt_limit stopped counting and a kernel that never boots could be rebooted
  for without end.
- FIX: A number in automatic-reboot.conf with a leading zero, such as reboot_delay_sec = 08, is
  read as decimal. Bash read it as an invalid octal number, and a reboot could be submitted with
  no delay. reboot_delay_sec must lie between 1 and 86400 and reboot_request_lock_wait_sec
  between 1 and 600; a value outside is logged and the default used.
- FIX: The completion line says "No updates installed" when dnf-automatic installed nothing, and
  otherwise counts the packages it installed; it said "Updates installed" either way. The reboot
  warning no longer claims updates were installed.
- FIX: A failed scheduled reboot's notice says whether update runs are still held and how to
  release them.
- FIX: Every run fetches current repository metadata (dnf makecache --refresh) before
  dnf-automatic starts, within metadata_refresh_timeout_sec (new, default 900).
  dnf-automatic installed from the cache dnf-makecache.timer or metadata_expire had left, so
  an advisory published since waited for the next run. A refresh that fails or runs out of
  time is logged, the run continues from the cache, and the completion line says so.
  refresh_metadata = no (new) turns the step off.

* Wed Sep 30 2026 DagNode <packages@dagnode.com> - 1.4.0-1
- LICENSE: The project license is now GPL-2.0-or-later. Releases through 1.3 were licensed MIT,
  and anyone who received them keeps those terms on those versions. The spec file stays MIT;
  REUSE.toml declares the copyright of every file and the license of every file without its own
  header. The source archive carries REUSE.toml and both license texts.
- CHANGE: Versions follow vX.Y.Z.
- CHANGE: Installation no longer edits /etc/sysconfig/kernel or /etc/default/grub, and no
  longer runs grubby --set-default, on UEK hosts. The installer refuses a host without
  DEFAULTKERNEL, GRUB_UPDATE_DEFAULT_KERNEL=true or a default on the newest kernel, and names
  each setting or command. Changing the default at install would change which kernel the next
  boot runs. The [kernel] settings manage_kernel_default and kernel_default_package are
  removed.
- CHANGE: Installing over any version before 1.4.0 is refused before a file is touched. Remove the
  earlier version first with 'dnf remove dnf-automatic-reboot', then install 1.4.0 and re-enable
  the timers with 'systemctl enable --now dnf-automatic-reboot.timer dnf-automatic-watchdog.timer'.
  Removal keeps an edited /etc/dnf/automatic-reboot.conf as automatic-reboot.conf.rpmsave and
  deletes the log and the learned restart-state, so each package it had confirmed as a false
  positive costs one reboot to learn again. Nothing migrates from the earlier versions: an
  in-place upgrade from them would run that night's reboot decision through a script the upgrade
  had just removed.
- CHANGE: Installation is refused, before a file is touched, on a host this package cannot reboot
  safely: one that is not EL8 or EL9 (PLATFORM_ID), not booted by systemd, missing
  dnf-automatic, yum-utils, elfutils or grubby, not GRUB2 in BLS mode with a default kernel
  grubby can read, not booting saved_entry (GRUB_DEFAULT=saved), or unable to make an updated
  kernel the default (GRUB_UPDATE_DEFAULT_KERNEL=true, DEFAULTKERNEL on EL9, and the default
  already on the newest installed kernel). GRUB_SAVEDEFAULT=true is reported, not refused. The
  refusal lists every problem with its fix.
- CHANGE: /etc/dnf/automatic.conf must have 'apply_updates = yes' as well as 'reboot = never'.
  dnf-automatic defaults apply_updates to off, and then only downloads updates and exits 0.
  Installation is refused and each run fails until it is set. The file is checked, never
  edited, so an existing dnf-automatic setup is kept as it is.
- CHANGE: grub-boot-success.service is removed, and grub2-tools-minimal is no longer required. It
  set boot_success at every boot on UEK hosts, which in RHEL's GRUB scripts only decides whether
  the menu is hidden; saved_entry never depended on it. It would also have disarmed greenboot's
  boot_counter rollback. Removing an earlier version disables it.
- CHANGE: The failure notifier unit is renamed dnf-automatic-reboot-notify@.service.
- SECURITY: Compare build-ids for every process running a binary, not one per binary. PID 1
  re-execs onto the new systemd while each systemd --user manager keeps the old image; checking
  PID 1 alone could call a genuine systemd update a false positive and skip the reboot.
- SECURITY: A process still running a systemd binary whose build-id cannot be read keeps the
  reboot, even when every other process matches. One matching process could call the update a
  false positive for a process nobody had checked. A process counts as gone only when it has
  left /proc, is a zombie, or runs another binary.
- NEW: Enterprise Linux 8 support (RHEL 8, Oracle Linux 8, Rocky Linux 8, AlmaLinux 8). The
  package requires systemd 239 instead of 252, and the watchdog stops a stuck run with the
  systemctl kill option each systemd version accepts. On EL8 EFI hosts the install checks the
  grub.cfg on the EFI partition, which is the one GRUB runs there.
- NEW: restart_service_timeout_sec (default 300) bounds each restart of a stale service. A
  restart that does not finish in time is left to systemd, and the run goes on.
- NEW: Each run that installs updates ends with one line, logged and sent to logged-in users,
  naming the reboot outcome and every service restarted, failed, still pending or excluded, and
  the command to check what is incomplete.
- NEW: A reboot is scheduled as dnf-automatic-reboot-scheduled-reboot.timer. The message gives
  its time and 'systemctl stop dnf-automatic-reboot-scheduled-reboot.timer' to cancel it, and a
  reboot that fails to start is reported through the failure notifier.
- FIX: Security advisories that dnf will not install are reported on Red Hat Enterprise Linux,
  Rocky Linux and AlmaLinux, whose advisory ids have the form RHSA-2020:3011, for EPEL
  advisories such as FEDORA-EPEL-2024-bf31852fe0, and for Oracle Linux advisories with a
  revision suffix such as ELSA-2026-60226-0. Only the form ELSA-2026-26533 was recognized, so
  the warning never appeared for the others.
- FIX: Stale-service restarts leave user@*.service, getty@*.service, serial-getty@*.service
  and autovt@*.service alone; restarting them would end a user's session or log out a console.
  restart_services_exclude entries accept globs.
- FIX: The watchdog acts on a recorded PID only while it is the unit's main process. After a
  crash, a reused PID belonging to another process could have been signalled.
- FIX: 'wall_messages = no' followed by a comment on the same line disables wall messages.
- FIX: make install writes the config as /etc/dnf/automatic-reboot.conf, the name the scripts
  read.
- FIX: The watchdog times a run from the boot clock (/proc/uptime) instead of the wall clock. On a
  host with no RTC, a run started before chrony synchronised could read as days old once the
  clock stepped, and the hard timeout could then stop it mid-transaction.
- FIX: An unreadable GRUB default does not withhold a kernel reboot. grubby prints '/boot' and
  exits 0 when it cannot read grubenv, which the check would have taken for a stale default.
  Anything other than a /boot/vmlinuz-* path now counts as undetermined, and
  kernel_reboot_attempt_limit remains the backstop.
- FIX: A dnf error during the reboot check no longer reboots the host. dnf exits 1 for errors
  such as a missing cache, the same code needs-restarting uses for "reboot required"; only an
  exit 1 that names a package is a reboot requirement now. Anything else is retried with a
  metadata refresh, then fails the run without rebooting.
- FIX: Updates start only once logind has granted the shutdown inhibitor lock. dnf-automatic
  runs under systemd-inhibit, and a refused lock fails the run before anything is installed.
- FIX: A reboot check that exits with any status other than 0 or 1, such as a missing helper,
  fails the run instead of reporting "No reboot required". The watchdog fails its unit the same
  way, so OnFailure= reports it.
- FIX: The watchdog's own reboot check is killed after three times needs_restarting_timeout_sec,
  and the watchdog unit after 15 minutes. A hung check could keep the watchdog running, so the
  hard timeout was never reached.
- FIX: The watchdog supervises a run until it exits, stale-service restarts included. A hung
  restart could hold the run open and block every later update run.
- FIX: kernel_reboot_attempt_limit counts at most one attempt per boot. Every check counted
  before, so running the reboot check by hand, or the watchdog's check, used up the limit and
  withheld the next genuine kernel reboot.
- FIX: The reboot check no longer removes /dev/null when it cannot create a temporary file; it
  fails without rebooting.
- FIX: The watchdog re-checks the run right before stopping it, and no new run starts until its
  recovery ends, or, when it reboots, until that reboot. A run that ended during the watchdog's own reboot check, and the next run that
  started meanwhile, could otherwise be killed mid-update and the host rebooted. A process whose
  identity systemd cannot confirm is left alone.
- FIX: The watchdog counts a stuck run as stopped only once systemd reports it inactive or
  failed within watchdog_kill_confirm_sec (default 30). A failed or unconfirmed kill keeps the
  run supervised, does not reboot, and fails the watchdog. The recorded PID is no longer
  signalled on its own, since its number may belong to another process by then.
- FIX: A stale-service restart that fails or does not finish fails the run. The run reported
  "No stale services needed restarting" and success instead.
- FIX: The watchdog fails its unit when it cannot schedule a reboot, so OnFailure= reports it.

* Fri Jul 31 2026 DagNode <packages@dagnode.com> - 1.3-1
- CHANGE: Scripts move from /usr/local/lib to /usr/libexec; update anything that calls them by
  path.
- CHANGE: Requires systemd >= 252 for systemctl kill --kill-whom.
- SECURITY: Treat every unverifiable state as a genuine reboot requirement: missing elfutils no
  longer aborts a kernel decision it cannot affect, and a package with no verifiable running
  process is no longer dropped.
- SECURITY: Compare build-ids across every running process a package owns; stopping at the first
  match cleared systemd on PID 1 while journald ran the old image.
- SECURITY: Replace the fixed 30s needs-restarting timeout, which expired into a fail-open "no
  reboot" on slow links, with a configurable needs_restarting_timeout_sec defaulting to 120s and a
  cache-first attempt.
- SECURITY: Restart services still mapping pre-update files via needs-restarting -s, which -r
  never reports; new [services] section with restart_services and restart_services_exclude.
- SECURITY: Report enabled repositories with gpgcheck=0, and security advisories that apply to the
  host but that dnf will not install; a repository priority= or excludepkgs= leaves an advisory
  visible to updateinfo but invisible to the depsolver while every run reports success; new
  [security] section.
- NEW: Verify grubby --default-kernel already points at the newest installed kernel before
  scheduling a kernel reboot, and cap consecutive attempts per target version, so a saved_entry
  that never advances cannot loop; new verify_grub_default and kernel_reboot_attempt_limit.
- NEW: Enable chrony-wait.service at install time so Requires=time-sync.target is a real gate on
  UEK R8, where systemd-time-wait-sync.service does not exist.
- NEW: Report failed runs to wall(1) and the log through OnFailure=.
- NEW: Ship a test suite; make check runs lint and tests, and %%check runs it during the build.
- FIX: Parse needs-restarting output with an allowlist under LC_ALL=C and keep its stderr out of
  the parsed stream; a translated locale or a plugin warning line was read as a package name and
  rebooted the host on every run.
- FIX: Kill the whole service cgroup at watchdog timeout; signalling the recorded PID and its
  direct children left dnf-automatic running behind timeout(1).
- FIX: Do not force-reboot at hard timeout while phase=updating, where an rpm transaction may be
  half-applied; opt back in with force_reboot_on_hard_timeout.
- FIX: Fail the run instead of reporting success when the reboot state cannot be established.
- FIX: Prefer an orderly systemctl reboot over --force.
- FIX: Validate numeric config values instead of failing inside an arithmetic test, and keep the
  warning off stdout where it was captured into the value returned.
- FIX: Ship tmpfiles.d and logrotate.d drop-ins so the log is created 0640 and rotated weekly; it
  was created 0644 by the first script to write to it and grew without bound.

* Fri Jul 03 2026 DagNode <packages@dagnode.com> - 1.2-1
- NEW: Learn non-kernel false positives (e.g. glibc) by observing whether a package is still
  flagged by needs-restarting after a real reboot, keyed on exact EVR and proven via kernel boot
  ID rather than timestamps.
- NEW: New learn_false_positives config key and /var/lib/dnf-automatic-reboot/restart-state
  tracking file.
- FIX: Fix watchdog timer OnCalendar: was firing every 5 seconds instead of every 5 minutes (step
  was on the wrong field).
- FIX: run.sh and watchdog.sh now check systemd-run's exit code when dispatching the scheduled
  reboot and log dispatch success/failure explicitly, instead of assuming a fire-and-forget
  systemd-run call always succeeds.

* Mon Jun 22 2026 DagNode <packages@dagnode.com> - 1.1-1
- CHANGE: Requires: grubby, grub2-tools-minimal.
- NEW: Add grub-boot-success.service to clear GRUB's indeterminate-boot fallback; enabled on UEK
  hosts only, inert elsewhere (ConditionKernelVersion=*uek*).
- NEW: New [kernel] config section: manage_kernel_default, kernel_default_package.
- NEW: Provisioning is UEK-gated and idempotent; non-UEK kernels are never touched.
- FIX: Fix UEK kernel not booted after update: provision GRUB BLS saved_entry handling at install
  time (DEFAULTKERNEL + GRUB_UPDATE_DEFAULT_KERNEL) so kernel-install advances the default on
  every future kernel update.
- FIX: Repair existing saved_entry backlog with grubby --set-default at install.

* Sat May 23 2026 DagNode <packages@dagnode.com> - 1.0-1
- Initial release: inhibitor lock prevents reboot during updates; UEK aarch64 false-positive
  filtering with version cross-verification; systemd false-positive detection via eu-readelf
  build-id comparison; independent watchdog with configurable soft/hard timeouts; filter_packages
  defaults include kernel-uek,kernel-uek-core,systemd; Requires=time-sync.target (note
  systemd-time-wait-sync absent on UEK R8); all settings in /etc/dnf/automatic-reboot.conf.
