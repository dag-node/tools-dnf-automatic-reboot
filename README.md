# dnf-automatic-reboot

Unattended update and conditional reboot for Oracle Linux 9 / RHEL 9 on aarch64 (RPi4, UEK R8).

For operational reference (configuration, diagnostics, false-positive handling) see
[doc/README](doc/README).

## Project structure

```
dnf-automatic-reboot/
  Makefile                          Build, install, uninstall, dist targets
  dnf-automatic-reboot.spec         RPM spec file
  conf/
    dnf-automatic-reboot.conf       Runtime configuration (installed to /etc/dnf/)
  scripts/
    run.sh                          Main orchestration: inhibitor + dnf + reboot decision
    watchdog.sh                     Independent watchdog: soft/hard timeout + stuck detection
    needs-reboot.sh                 Reboot decision + false-positive filtering (UEK, systemd)
  units/
    dnf-automatic-reboot.service    Oneshot service wrapping run.sh
    dnf-automatic-reboot.timer      Daily timer (03:00 +/- 10 min)
    dnf-automatic-watchdog.service  Oneshot watchdog service
    dnf-automatic-watchdog.timer    5-minute polling timer
  doc/
    README                          Operational reference (installed to /usr/share/doc/)
```

## Prerequisites

### Build host

```bash
dnf install rpm-build systemd-rpm-macros
```

### Target system

```bash
dnf install dnf-automatic dnf-plugins-core elfutils
```

`elfutils` provides `eu-readelf` for systemd build-id comparison. The package degrades
gracefully without it but false-positive detection for systemd will fall back to the
`filter_packages` list only.

## Building the RPM

After editing any source file, rebuild with:

```bash
# 1. Create the source tarball from the working tree
make dist

# 2. Build the RPM in-place (no ~/rpmbuild copying needed)
rpmbuild -ba dnf-automatic-reboot.spec \
  --define "_sourcedir $(pwd)" \
  --define "_specdir $(pwd)"

# Resulting RPM:
ls ~/rpmbuild/RPMS/noarch/dnf-automatic-reboot-*.noarch.rpm
```

`make dist` packages the files listed in the Makefile (`SCRIPTS`, `UNITS`, `CONF`,
`DOC`) into `dnf-automatic-reboot-$(VERSION).tar.gz`. The spec file is passed directly
to `rpmbuild` and is not included in the tarball.

`rpmbuild` still writes build artefacts under `~/rpmbuild/`; create the tree once if
it does not exist:

```bash
mkdir -p ~/rpmbuild/{BUILD,RPMS,SRPMS}
```

## Installing

```bash
dnf install ~/rpmbuild/RPMS/noarch/dnf-automatic-reboot-1.0-1.*.noarch.rpm
```

## Post-install setup

### 1. Configure dnf-automatic

```bash
vi /etc/dnf/automatic.conf
# Ensure:
#   apply_updates = yes
#   download_updates = yes
```

### 2. Configure chrony for reliable clock at boot

Critical on systems with no battery-backed RTC (RPi without DS1307) or unreliable RTC.
`needs-restarting` reads `systemd UserspaceTimestamp` which is set before chrony syncs;
if the clock is wrong at that point, package INSTALLTIME comparisons are poisoned.

```bash
# Allow immediate clock step on any sync (not just first 3)
grep -q 'makestep 1 -1' /etc/chrony.conf || echo 'makestep 1 -1' >> /etc/chrony.conf

# Signal kernel + systemd when sync is achieved (required for time-sync.target)
grep -q '^rtcsync' /etc/chrony.conf || echo 'rtcsync' >> /etc/chrony.conf

systemctl restart chronyd
```

> **RPi4 with DS1307 RTC:** ensure the overlay is configured in `/boot/efi/config.txt`
> (`dtoverlay=i2c-rtc,ds1307`) and run `hwclock --systohc` after first NTP sync.
> Disable any soft-hwclock / fake-hwclock service that may conflict.

### 3. Fix NTS certificate failures (FUTURE crypto policy)

```bash
# If chronyd logs "TLS handshake failed: certificate uses insecure algorithm"
update-crypto-policies --set DEFAULT
systemctl restart chronyd
```

### 4. Disable the stock dnf-automatic timers

```bash
systemctl disable --now dnf-automatic.timer dnf-automatic-install.timer 2>/dev/null || true
```

### 5. Enable this package

```bash
systemctl enable --now dnf-automatic-reboot.timer
systemctl enable --now dnf-automatic-watchdog.timer
```

### 6. Verify

```bash
systemctl list-timers dnf-automatic-reboot.timer dnf-automatic-watchdog.timer
systemd-inhibit --list
```

## Testing without waiting for the timer

```bash
# Run the full update + reboot decision cycle now
systemctl start dnf-automatic-reboot.service
journalctl -u dnf-automatic-reboot.service -f

# Test reboot detection in isolation
/usr/local/lib/dnf-automatic-reboot/needs-reboot.sh; echo "exit: $?"

# Test watchdog (exits immediately with no state file present)
/usr/local/lib/dnf-automatic-reboot/watchdog.sh
```

## Uninstalling

```bash
systemctl disable --now dnf-automatic-reboot.timer dnf-automatic-watchdog.timer
dnf remove dnf-automatic-reboot

# Log file is intentionally preserved; remove manually if not needed:
rm -f /var/log/dnf-automatic-reboot.log
```

## Known issues and platform notes

| Issue | Platform | Status |
|---|---|---|
| `needs-restarting` always flags `kernel-uek` / `kernel-uek-core` | OL9 aarch64 UEK | Filtered by `needs-reboot.sh` via version cross-check |
| `needs-restarting` flags `systemd` after update even post-reboot | All | Filtered by `needs-reboot.sh` via `eu-readelf` build-id comparison |
| `systemd-time-wait-sync.service` absent on UEK R8 | OL9 UEK R8 | Open — `time-sync.target` used as best available gate; see [#time-sync](#time-sync-on-uek-r8) |
| NTS sources fail under FUTURE crypto policy | OL9 FUTURE policy | Fix: `update-crypto-policies --set DEFAULT` |

### time-sync on UEK R8

`systemd-time-wait-sync.service` is not shipped on UEK R8. The service unit declares
`Requires=time-sync.target` which on this kernel is satisfied by `chronyd.service`
completing startup — not by chrony achieving sync. This means there is a window
(typically 30-90 seconds) where dnf could run before the clock is fully corrected
if the RTC is stale.

Mitigation: with `makestep 1 -1` and a correctly synced DS1307 RTC, the clock offset
at boot is small enough (< 1 second typical drift) that INSTALLTIME stamps are
effectively correct. The `eu-readelf` build-id path in `needs-reboot.sh` is fully
immune to timestamp issues regardless.

A custom `time-wait-sync` replacement unit is a candidate for a future release.

## Bumping the version

```bash
# Edit Makefile: VERSION = 1.1
# Edit dnf-automatic-reboot.spec: Version: 1.1, add %changelog entry
make dist
# Then follow Building the RPM above
```
