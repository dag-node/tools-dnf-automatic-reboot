# SPDX-License-Identifier: MIT
Name:           dnf-automatic-reboot
Version:        1.3
Release:        1%{?dist}
Summary:        Unattended update and conditional reboot for OL9/RHEL9 aarch64

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
# grubby reads and sets the GRUB BLS default: needs-reboot.sh verifies it
# before a kernel reboot, %%post repairs it on UEK, and %%pre refuses a host
# where it does not answer - hence also Requires(pre).
Requires:       grubby
Requires(pre):  grubby
# logrotate consumes the drop-in in %%{_sysconfdir}/logrotate.d; without it
# /var/log/dnf-automatic-reboot.log grows without bound
Requires:       logrotate

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
for required_package in dnf-automatic yum-utils elfutils grubby; do
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
* Fri Jul 31 2026 DagNode <packages@dagnode.com> - 1.3-1
New:
- Restart services still mapping pre-update files via needs-restarting -s,
  which -r never reports; new [services] section with restart_services and
  restart_services_exclude
- Report enabled repositories with gpgcheck=0, and security advisories that
  apply to the host but that dnf will not install; a repository priority= or
  excludepkgs= leaves an advisory visible to updateinfo but invisible to the
  depsolver while every run reports success; new [security] section
- Verify grubby --default-kernel already points at the newest installed kernel
  before scheduling a kernel reboot, and cap consecutive attempts per target
  version, so a saved_entry that never advances cannot loop; new
  verify_grub_default and kernel_reboot_attempt_limit
- Enable chrony-wait.service at install time so Requires=time-sync.target is a
  real gate on UEK R8, where systemd-time-wait-sync.service does not exist
- Report failed runs to wall(1) and the log through OnFailure=
- Ship tmpfiles.d and logrotate.d drop-ins so the log is created 0640 and
  rotated weekly; it was created 0644 by the first script to write to it and
  grew without bound
- Ship a test suite; make check runs lint and tests, and %%check runs it during
  the build

Fixed, most severe first:
- Parse needs-restarting output with an allowlist under LC_ALL=C and keep its
  stderr out of the parsed stream; a translated locale or a plugin warning line
  was read as a package name and rebooted the host on every run
- Treat every unverifiable state as a genuine reboot requirement: missing
  elfutils no longer aborts a kernel decision it cannot affect, and a package
  with no verifiable running process is no longer dropped
- Kill the whole service cgroup at watchdog timeout; signalling the recorded
  PID and its direct children left dnf-automatic running behind timeout(1)
- Do not force-reboot at hard timeout while phase=updating, where an rpm
  transaction may be half-applied; opt back in with
  force_reboot_on_hard_timeout
- Fail the run instead of reporting success when the reboot state cannot be
  established
- Compare build-ids across every running process a package owns; stopping at
  the first match cleared systemd on PID 1 while journald ran the old image
- Prefer an orderly systemctl reboot over --force
- Replace the fixed 30s needs-restarting timeout, which expired into a
  fail-open "no reboot" on slow links, with a configurable
  needs_restarting_timeout_sec defaulting to 120s and a cache-first attempt
- Validate numeric config values instead of failing inside an arithmetic test,
  and keep the warning off stdout where it was captured into the value returned

Upgrade notes:
- Scripts move from /usr/local/lib to /usr/libexec; update anything that calls
  them by path
- Requires systemd >= 252 for systemctl kill --kill-whom
* Fri Jul 03 2026 DagNode <packages@dagnode.com> - 1.2-1
- Learn non-kernel false positives (e.g. glibc) by observing whether a
  package is still flagged by needs-restarting after a real reboot, keyed
  on exact EVR and proven via kernel boot ID rather than timestamps
- New learn_false_positives config key and
  /var/lib/dnf-automatic-reboot/restart-state tracking file
- Fix watchdog timer OnCalendar: was firing every 5 seconds instead of
  every 5 minutes (step was on the wrong field)
- run.sh and watchdog.sh now check systemd-run's exit code when dispatching
  the scheduled reboot and log dispatch success/failure explicitly, instead
  of assuming a fire-and-forget systemd-run call always succeeds
* Mon Jun 22 2026 DagNode <packages@dagnode.com> - 1.1-1
- Fix UEK kernel not booted after update: provision GRUB BLS saved_entry
  handling at install time (DEFAULTKERNEL + GRUB_UPDATE_DEFAULT_KERNEL) so
  kernel-install advances the default on every future kernel update
- Repair existing saved_entry backlog with grubby --set-default at install
- Add grub-boot-success.service to clear GRUB's indeterminate-boot fallback;
  enabled on UEK hosts only, inert elsewhere (ConditionKernelVersion=*uek*)
- New [kernel] config section: manage_kernel_default, kernel_default_package
- Provisioning is UEK-gated and idempotent; non-UEK kernels are never touched
- Requires: grubby, grub2-tools-minimal

* Sat May 23 2026 DagNode <packages@dagnode.com> - 1.0-1
- Initial release
- Inhibitor lock prevents reboot during updates
- UEK aarch64 false-positive filtering with version cross-verification
- systemd false-positive detection via eu-readelf build-id comparison
- Independent watchdog with configurable soft/hard timeouts
- filter_packages defaults include kernel-uek,kernel-uek-core,systemd
- Requires=time-sync.target; note systemd-time-wait-sync absent on UEK R8
- All settings in /etc/dnf/automatic-reboot.conf
