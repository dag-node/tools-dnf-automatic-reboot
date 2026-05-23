Name:           dnf-automatic-reboot
Version:        1.0
Release:        1%{?dist}
Summary:        Unattended update and conditional reboot for OL9/RHEL9 aarch64

License:        MIT
URL:            https://github.com/example/dnf-automatic-reboot
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch

# dnf-automatic provides the /usr/bin/dnf-automatic binary we call
Requires:       dnf-automatic
# needs-restarting is in the dnf-plugins-core package
Requires:       dnf-plugins-core
# systemd-inhibit, systemd-run, wall are all in systemd or util-linux
Requires:       systemd
Requires:       util-linux
# eu-readelf for systemd build-id comparison (false-positive detection)
# Soft dependency: needs-reboot.sh degrades gracefully without it
Recommends:     elfutils

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

All behaviour is controlled by /etc/dnf/dnf-automatic-reboot.conf.

%prep
%autosetup

%build
# Nothing to compile - shell scripts only

%global _localibdir /usr/local/lib/%{name}

%install
# Scripts
install -d -m 0755 %{buildroot}%{_localibdir}
install -m 0755 scripts/run.sh          %{buildroot}%{_localibdir}/run.sh
install -m 0755 scripts/watchdog.sh     %{buildroot}%{_localibdir}/watchdog.sh
install -m 0755 scripts/needs-reboot.sh %{buildroot}%{_localibdir}/needs-reboot.sh

# systemd units
install -d -m 0755 %{buildroot}%{_unitdir}
install -m 0644 units/dnf-automatic-reboot.service   %{buildroot}%{_unitdir}/
install -m 0644 units/dnf-automatic-reboot.timer     %{buildroot}%{_unitdir}/
install -m 0644 units/dnf-automatic-watchdog.service %{buildroot}%{_unitdir}/
install -m 0644 units/dnf-automatic-watchdog.timer   %{buildroot}%{_unitdir}/

# Config file - noreplace preserves local edits on upgrade
install -d -m 0755 %{buildroot}%{_sysconfdir}/dnf
install -m 0640 conf/dnf-automatic-reboot.conf \
    %{buildroot}%{_sysconfdir}/dnf/dnf-automatic-reboot.conf

# Documentation
install -d -m 0755 %{buildroot}%{_docdir}/%{name}
install -m 0644 doc/README %{buildroot}%{_docdir}/%{name}/README

# Log file placeholder so RPM owns it and applies the SELinux label
install -d -m 0755 %{buildroot}%{_localstatedir}/log
touch %{buildroot}%{_localstatedir}/log/%{name}.log

%pre
# Nothing needed before install

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
                   %{_sysconfdir}/dnf/dnf-automatic-reboot.conf \
                   %{_localstatedir}/log/%{name}.log \
                   2>/dev/null || true
fi

echo ""
echo "dnf-automatic-reboot installed."
echo ""
echo "Next steps:"
echo "  1. Ensure /etc/dnf/automatic.conf has apply_updates = yes"
echo "  2. Review /etc/dnf/dnf-automatic-reboot.conf"
echo "  3. Disable stock timers if not already done:"
echo "       systemctl disable --now dnf-automatic.timer dnf-automatic-install.timer"
echo "  4. Enable this package:"
echo "       systemctl enable --now dnf-automatic-reboot.timer dnf-automatic-watchdog.timer"

%preun
%systemd_preun dnf-automatic-reboot.service
%systemd_preun dnf-automatic-reboot.timer
%systemd_preun dnf-automatic-watchdog.service
%systemd_preun dnf-automatic-watchdog.timer

%postun
%systemd_postun_with_restart dnf-automatic-reboot.timer
%systemd_postun_with_restart dnf-automatic-watchdog.timer

# Re-apply SELinux contexts after uninstall (removes custom labels)
if [ $1 -eq 0 ] && [ -x /sbin/restorecon ]; then
    restorecon -Rv /usr/local/lib/ 2>/dev/null || true
fi

%files
%license doc/README
%doc     %{_docdir}/%{name}/README

# Scripts - shell_exec_t so systemd can exec them directly
%attr(0755, root, root) %{_localibdir}/run.sh
%attr(0755, root, root) %{_localibdir}/watchdog.sh
%attr(0755, root, root) %{_localibdir}/needs-reboot.sh

# systemd units
%{_unitdir}/dnf-automatic-reboot.service
%{_unitdir}/dnf-automatic-reboot.timer
%{_unitdir}/dnf-automatic-watchdog.service
%{_unitdir}/dnf-automatic-watchdog.timer

# Config - preserved across upgrades; root:root 640 (no world read for safety)
%config(noreplace) %attr(0640, root, root) %{_sysconfdir}/dnf/dnf-automatic-reboot.conf

# Log file - var_log_t context applied by restorecon in %%post
%ghost %attr(0640, root, root) %{_localstatedir}/log/%{name}.log

%changelog
* Sat May 23 2026 Packager <packager@example.com> - 1.0-1
- Initial release
- Inhibitor lock prevents reboot during updates
- UEK aarch64 false-positive filtering with version cross-verification
- systemd false-positive detection via eu-readelf build-id comparison
- Independent watchdog with configurable soft/hard timeouts
- filter_packages defaults include kernel-uek,kernel-uek-core,systemd
- Requires=time-sync.target; note systemd-time-wait-sync absent on UEK R8
- All settings in /etc/dnf/dnf-automatic-reboot.conf
