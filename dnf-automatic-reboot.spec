Name:           dnf-automatic-reboot
Version:        1.2
Release:        1%{?dist}
Summary:        Unattended update and conditional reboot for OL9/RHEL9 aarch64

License:        MIT
URL:            https://github.com/dag-node/tools-dnf-automatic-reboot
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch

# dnf-automatic provides the /usr/bin/dnf-automatic binary we call
Requires:       dnf-automatic
# needs-restarting is provided by yum-utils on EL9 (confirmed via
# rpm -qf against the live binary; dnf-plugins-core does not own it)
Requires:       yum-utils
# systemd-inhibit, systemd-run, wall are all in systemd or util-linux
Requires:       systemd
Requires:       util-linux
# eu-readelf for systemd build-id comparison (false-positive detection)
Requires:       elfutils
# grubby + grub2-set-bootflag for the UEK GRUB BLS default fix (UEK hosts only;
# the %%post logic degrades gracefully if either is somehow absent)
Requires:       grubby
Requires:       grub2-tools-minimal

# We install systemd unit files
BuildRequires:  systemd-rpm-macros

%description
Companion service to dnf-automatic that:

  - Holds a systemd shutdown inhibitor during updates to prevent
    corruption from an accidental reboot mid-update.
  - Filters known false-positive reboot triggers on Oracle Linux 9
    aarch64: UEK kernel version-string mismatches and systemd
    PrivateTmp build-id masking.
  - Detects genuine update-triggered reboot requirements and schedules
    a timed reboot.
  - Provides an independent watchdog with configurable soft and hard
    timeouts to recover from hung updates without operator intervention.
  - Warns logged-in users via wall(1) at all key events.

All behaviour is controlled by /etc/dnf/automatic-reboot.conf.

%prep
%autosetup

%build
# Nothing to compile - shell scripts only

%global _localibdir /usr/local/lib/%{name}

%install
# Scripts
install -d -m 0755 %{buildroot}%{_localibdir}
install -m 0750 scripts/run.sh          %{buildroot}%{_localibdir}/run.sh
install -m 0750 scripts/watchdog.sh     %{buildroot}%{_localibdir}/watchdog.sh
install -m 0750 scripts/needs-reboot.sh %{buildroot}%{_localibdir}/needs-reboot.sh

# systemd units
install -d -m 0755 %{buildroot}%{_unitdir}
install -m 0644 units/dnf-automatic-reboot.service   %{buildroot}%{_unitdir}/
install -m 0644 units/dnf-automatic-reboot.timer     %{buildroot}%{_unitdir}/
install -m 0644 units/dnf-automatic-watchdog.service %{buildroot}%{_unitdir}/
install -m 0644 units/dnf-automatic-watchdog.timer   %{buildroot}%{_unitdir}/
install -m 0644 units/grub-boot-success.service      %{buildroot}%{_unitdir}/

# Config file - noreplace preserves local edits on upgrade
install -d -m 0755 %{buildroot}%{_sysconfdir}/dnf
install -m 0640 conf/automatic-reboot.conf \
    %{buildroot}%{_sysconfdir}/dnf/automatic-reboot.conf

# Documentation
install -d -m 0755 %{buildroot}%{_docdir}/%{name}
install -m 0644 doc/README %{buildroot}%{_docdir}/%{name}/README

# Log file placeholder so RPM owns it and applies the SELinux label
install -d -m 0755 %{buildroot}%{_localstatedir}/log
touch %{buildroot}%{_localstatedir}/log/%{name}.log

# Restart-state directory for the false-positive learning tracker
install -d -m 0750 %{buildroot}%{_localstatedir}/lib/%{name}

%pre -p /bin/bash
FAIL=0

# dnf-automatic must be installed (Requires: covers normal installs; this
# catches --nodeps bypasses).
if ! rpm -q dnf-automatic > /dev/null 2>&1; then
    echo "ERROR: dnf-automatic is not installed." >&2
    echo "       Install it first:  dnf install dnf-automatic" >&2
    FAIL=1
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
ACONF=/etc/dnf/automatic.conf
if [[ -f "${ACONF}" ]]; then
    reboot_val=$(grep -E '^\s*reboot\s*=' "${ACONF}" 2>/dev/null \
                 | tail -1 | sed 's/^[^=]*=\s*//' | sed 's/\s*#.*//' \
                 | tr -d '[:space:]') || true
    if [[ -n "${reboot_val}" && "${reboot_val}" != "never" ]]; then
        echo "ERROR: /etc/dnf/automatic.conf has 'reboot = ${reboot_val}'." >&2
        echo "       dnf-automatic must not reboot independently of this package." >&2
        echo "       Set it to 'never' in ${ACONF}:  reboot = never" >&2
        FAIL=1
    fi
fi

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

# Apply correct SELinux file contexts after install.
# Scripts in /usr/local/lib need bin_t or shell_exec_t to be executed
# by systemd.  restorecon applies the context matching the fcontext
# database entry we ship in the %%files section via semanage.
if [ -x /sbin/restorecon ]; then
    restorecon -Rv %{_localibdir}/ \
                   %{_sysconfdir}/dnf/automatic-reboot.conf \
                   %{_localstatedir}/log/%{name}.log \
                   %{_localstatedir}/lib/%{name} \
                   2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# UEK GRUB BLS default provisioning (one-time, idempotent; no-op off UEK).
# On OL9 UEK hosts kernel-install does not advance the GRUB saved_entry by
# default, so a newly installed kernel-uek-core is not booted after reboot.
# Configure DEFAULTKERNEL + GRUB_UPDATE_DEFAULT_KERNEL so every future kernel
# update advances saved_entry automatically, repair the current backlog with
# grubby, and enable the boot-success safeguard.  Gated on the running kernel
# package so non-UEK kernels are never touched.  Behaviour is controlled by
# the [kernel] section of /etc/dnf/automatic-reboot.conf (read below).
# ---------------------------------------------------------------------------
ARC_CONF=/etc/dnf/automatic-reboot.conf
arc_conf_get() {
    _val=$(grep -E "^[[:space:]]*$1[[:space:]]*=" "${ARC_CONF}" 2>/dev/null \
           | tail -1 | sed 's/^[^=]*=[[:space:]]*//' | sed 's/[[:space:]]*#.*//') || true
    if [ -n "${_val}" ]; then printf '%s' "${_val}"; else printf '%s' "$2"; fi
}
ARC_MANAGE=$(arc_conf_get manage_kernel_default yes)
ARC_KPKG=$(arc_conf_get kernel_default_package kernel-uek-core)

ARC_RUNPKG=""
ARC_VMLINUZ="/lib/modules/$(uname -r)/vmlinuz"
if [ -e "${ARC_VMLINUZ}" ]; then
    ARC_RUNPKG=$(rpm -qf "${ARC_VMLINUZ}" --qf '%%{NAME}\n' 2>/dev/null | head -1) || true
fi

if [ "${ARC_MANAGE}" = "yes" ] && [ "${ARC_RUNPKG}" = "${ARC_KPKG}" ]; then
    echo "dnf-automatic-reboot: configuring GRUB BLS default for ${ARC_KPKG}"

    # 1. DEFAULTKERNEL in /etc/sysconfig/kernel
    SK=/etc/sysconfig/kernel
    if [ -f "${SK}" ] && grep -qE "^DEFAULTKERNEL=${ARC_KPKG}\$" "${SK}"; then
        :
    elif [ -f "${SK}" ] && grep -qE '^DEFAULTKERNEL=' "${SK}"; then
        sed -i "s/^DEFAULTKERNEL=.*/DEFAULTKERNEL=${ARC_KPKG}/" "${SK}"
    elif [ -f "${SK}" ]; then
        printf 'DEFAULTKERNEL=%s\n' "${ARC_KPKG}" >> "${SK}"
    else
        printf 'DEFAULTKERNEL=%s\n' "${ARC_KPKG}" > "${SK}"
        chmod 0644 "${SK}"
    fi

    # 2. GRUB_UPDATE_DEFAULT_KERNEL in /etc/default/grub
    DG=/etc/default/grub
    if [ -f "${DG}" ] && grep -qE '^GRUB_UPDATE_DEFAULT_KERNEL=' "${DG}"; then
        if ! grep -qE '^GRUB_UPDATE_DEFAULT_KERNEL="?true"?[[:space:]]*$' "${DG}"; then
            sed -i 's/^GRUB_UPDATE_DEFAULT_KERNEL=.*/GRUB_UPDATE_DEFAULT_KERNEL="true"/' "${DG}"
        fi
    else
        printf 'GRUB_UPDATE_DEFAULT_KERNEL="true"\n' >> "${DG}"
    fi

    # 3. Backlog repair: point the default at the newest installed kernel
    if command -v grubby >/dev/null 2>&1; then
        ARC_EVR=$(rpm -q "${ARC_KPKG}" --qf '%%{VERSION}-%%{RELEASE}.%%{ARCH}\n' 2>/dev/null \
                  | sort -V | tail -1) || true
        if [ -n "${ARC_EVR}" ] && [ -e "/boot/vmlinuz-${ARC_EVR}" ]; then
            ARC_CUR=$(grubby --default-kernel 2>/dev/null) || true
            if [ "${ARC_CUR}" != "/boot/vmlinuz-${ARC_EVR}" ]; then
                if grubby --set-default "/boot/vmlinuz-${ARC_EVR}" >/dev/null 2>&1; then
                    echo "dnf-automatic-reboot: GRUB default set to /boot/vmlinuz-${ARC_EVR}"
                fi
            fi
        fi
    fi

    # /etc/sysconfig/kernel may have been created; restore its SELinux label
    if [ -x /sbin/restorecon ]; then
        restorecon "${SK}" >/dev/null 2>&1 || true
    fi

    # 4. Enable the boot-success safeguard on UEK only.  Conditional (per-host)
    #    enablement cannot be expressed via systemd presets, so this is a
    #    deliberate, narrow exception to the macro-only scriptlet rule.  The
    #    unit also carries ConditionKernelVersion=*uek* so it stays inert even
    #    if it is ever enabled on a non-UEK host.
    systemctl --no-reload enable grub-boot-success.service >/dev/null 2>&1 || true
    systemctl start grub-boot-success.service >/dev/null 2>&1 || true
fi

echo ""
echo "dnf-automatic-reboot installed."
echo ""
echo "Next steps:"
echo "  1. Ensure /etc/dnf/automatic.conf has apply_updates = yes"
echo "  2. Review /etc/dnf/automatic-reboot.conf"
echo "  3. Disable stock timers if not already done:"
echo "       systemctl disable --now dnf-automatic.timer dnf-automatic-install.timer"
echo "  4. Enable this package:"
echo "       systemctl enable --now dnf-automatic-reboot.timer dnf-automatic-watchdog.timer"

%preun
%systemd_preun dnf-automatic-reboot.service
%systemd_preun dnf-automatic-reboot.timer
%systemd_preun dnf-automatic-watchdog.service
%systemd_preun dnf-automatic-watchdog.timer

# grub-boot-success.service is enabled directly (not via preset) on UEK hosts,
# so disable it directly on final uninstall.  No-op if it was never enabled.
if [ $1 -eq 0 ]; then
    systemctl --no-reload disable grub-boot-success.service >/dev/null 2>&1 || true
    systemctl stop grub-boot-success.service >/dev/null 2>&1 || true
fi

%postun
%systemd_postun_with_restart dnf-automatic-reboot.timer
%systemd_postun_with_restart dnf-automatic-watchdog.timer

# Re-apply SELinux contexts after uninstall (removes custom labels)
if [ $1 -eq 0 ] && [ -x /sbin/restorecon ]; then
    restorecon -Rv /usr/local/lib/ 2>/dev/null || true
fi

%files
%license LICENSE
%doc     %{_docdir}/%{name}/README

# Scripts - shell_exec_t so systemd can exec them directly.
# 0750 root:root: executed by systemd as root; no world read/exec needed
# (mirrors the 0640 config hardening).
%attr(0750, root, root) %{_localibdir}/run.sh
%attr(0750, root, root) %{_localibdir}/watchdog.sh
%attr(0750, root, root) %{_localibdir}/needs-reboot.sh

# systemd units
%{_unitdir}/dnf-automatic-reboot.service
%{_unitdir}/dnf-automatic-reboot.timer
%{_unitdir}/dnf-automatic-watchdog.service
%{_unitdir}/dnf-automatic-watchdog.timer
# Boot-success safeguard - shipped on all hosts (noarch) but only enabled on
# UEK by %%post; ConditionKernelVersion=*uek* keeps it inert elsewhere.
%{_unitdir}/grub-boot-success.service

# Config - preserved across upgrades; root:root 640 (no world read for safety)
%config(noreplace) %attr(0640, root, root) %{_sysconfdir}/dnf/automatic-reboot.conf

# Log file - var_log_t context applied by restorecon in %%post
%ghost %attr(0640, root, root) %{_localstatedir}/log/%{name}.log

# Restart-state directory - var_lib_t context applied by restorecon in
# %%post.  %%ghost on the file itself: RPM owns the path and SELinux label
# without owning content, same pattern as the log file above.
%dir %attr(0750, root, root) %{_localstatedir}/lib/%{name}
%ghost %attr(0640, root, root) %{_localstatedir}/lib/%{name}/restart-state

%changelog
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
