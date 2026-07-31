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
    automatic-reboot.conf       Runtime configuration (installed to /etc/dnf/)
  scripts/
    run.sh                          Main orchestration: inhibitor + dnf + reboot decision
    watchdog.sh                     Independent watchdog: soft/hard timeout + stuck detection
    needs-reboot.sh                 Reboot decision + false-positive filtering
    notify-failure.sh               OnFailure= notifier (wall + log)
  units/
    dnf-automatic-reboot.service    Oneshot service wrapping run.sh
    dnf-automatic-reboot.timer      Daily timer (03:00 +/- 10 min)
    dnf-automatic-watchdog.service  Oneshot watchdog service
    dnf-automatic-watchdog.timer    5-minute polling timer
    dnf-automatic-reboot-failure@.service   Failure notifier, instantiated by OnFailure=
    grub-boot-success.service       UEK-only boot_success marker (BLS fallback guard)
  tmpfiles/
    dnf-automatic-reboot.conf       Log and state path modes and SELinux labels
  logrotate/
    dnf-automatic-reboot            Log rotation drop-in
  tests/
    run-tests.sh                    Test suite (bash only, run by make check)
  doc/
    README                          Operational reference (installed to /usr/share/doc/)
```

## Tests

```bash
make check      # bash -n, shellcheck, ASCII check, then the suite
make test       # suite only
```

`rpmbuild` runs `make check` from `%check`. The suite stubs every external
command, needs no root, and touches nothing outside a temporary directory. A
handful of tests must execute a stub as a real program and skip themselves when
that directory is mounted `noexec`; run them from an exec-capable path with
`TMPDIR=/some/exec/path make test`.

## UEK kernel default (kernel not booted after update)

On OL9 UEK hosts a freshly installed `kernel-uek-core` is not selected at the next
boot, because `kernel-install` does not advance the GRUB `saved_entry` unless
`DEFAULTKERNEL` and `GRUB_UPDATE_DEFAULT_KERNEL=true` are set. The RPM `%post`
scriptlet fixes this once at install time (UEK hosts only; non-UEK kernels are
never touched): it sets both keys, repairs the current default with `grubby`, and
enables `grub-boot-success.service` so GRUB's indeterminate-boot fallback cannot
revert to an old kernel. Tunable via the `[kernel]` section of
`automatic-reboot.conf`. See [doc/README](doc/README).

## Prerequisites

### Build host

```bash
dnf install rpm-build systemd-rpm-macros
```

### Target system

```bash
dnf install dnf-automatic yum-utils elfutils grubby grub2-tools-minimal
```

`yum-utils` provides `needs-restarting`, which drives every reboot decision.
`elfutils` provides `eu-readelf`, required for systemd build-id comparison.
`grubby` and `grub2-tools-minimal` provide `grubby`/`grub2-set-bootflag`, used by
the UEK GRUB-default fix (these are normally already present on OL9).

## Before installing

The RPM `%pre` scriptlet validates these two conditions and aborts with a diagnostic
message if either is not met. Complete them before running `dnf install`.

### 1. Set `reboot = never` in `/etc/dnf/automatic.conf`

`dnf-automatic-reboot` owns all reboot decisions. `dnf-automatic` must not reboot
independently:

```ini
reboot = never
apply_updates = yes
```

### 2. Disable the stock dnf-automatic timers

This package provides its own schedule. Running both would apply updates twice:

```bash
systemctl disable --now dnf-automatic.timer dnf-automatic-install.timer 2>/dev/null || true
```

## Building the RPM

```bash
mkdir -p ~/rpmbuild/{BUILD,RPMS,SRPMS,SOURCES,SPECS}   # once

make dist
rpmbuild -ba dnf-automatic-reboot.spec \
  --define "_sourcedir $(pwd)" \
  --define "_specdir $(pwd)"
```

`make dist` runs `make check` first, then packages `SCRIPTS`, `UNITS`, `CONF`,
`TMPFILES`, `LOGROTATE`, `TESTS` and `DOC` from the Makefile into
`dnf-automatic-reboot-$(VERSION).tar.gz`. `rpmbuild -ba` builds directly from the spec
and tarball in the working tree via `_sourcedir`/`_specdir` — no copying into
`~/rpmbuild/SOURCES` needed. The finished package lands at
`~/rpmbuild/RPMS/noarch/dnf-automatic-reboot-$(VERSION)-1.*.noarch.rpm`.

## Installing

```bash
dnf install ~/rpmbuild/RPMS/noarch/dnf-automatic-reboot-*.noarch.rpm
```

The `%pre` scriptlet checks that `dnf-automatic` is installed, both stock timers are
disabled, and `automatic.conf` has `reboot = never`. It aborts with a clear message
and leaves no files installed if any check fails.

## Post-install setup

### 1. Configure chrony for reliable clock at boot

Critical on hosts with no battery-backed RTC. `needs-restarting -r` decides purely
on `rpm INSTALLTIME > boot time`, and takes that boot time from systemd's
`UnitsLoadStartTimestamp`, which is recorded before chrony corrects the clock. On
an RTC-less host that value stays permanently in the past, so every package it
watches is flagged forever. This is the single root cause of all the false
positives this package works around.

```bash
grep -q 'makestep 1 -1' /etc/chrony.conf || echo 'makestep 1 -1' >> /etc/chrony.conf
systemctl restart chronyd
systemctl enable --now chrony-wait.service   # makes time-sync.target a real gate
```

`rtcsync` is only meaningful with an RTC present; leave it commented out otherwise.

> **Fitting an RTC removes the problem class.** With a DS3231/DS1307 on i2c the
> boot clock is correct, nothing is spuriously flagged, and `filter_packages` plus
> restart-state learning become unnecessary. Configure the overlay in
> `/boot/efi/config.txt` (`dtoverlay=i2c-rtc,ds3231`), run `hwclock --systohc`
> after the first NTP sync, and disable any fake-hwclock service that conflicts.

### 2. Fix NTS certificate failures (FUTURE crypto policy)

Skip unless chronyd logs `TLS handshake failed: certificate uses insecure algorithm`:

```bash
update-crypto-policies --set DEFAULT
systemctl restart chronyd
```

### 3. Enable this package

```bash
systemctl enable --now dnf-automatic-reboot.timer
systemctl enable --now dnf-automatic-watchdog.timer
```

### 4. Verify

```bash
systemctl list-timers dnf-automatic-reboot.timer dnf-automatic-watchdog.timer
systemd-inhibit --list
```

## Testing without waiting for the timer

```bash
# Run a full update cycle immediately — will apply updates and reboot if needed
systemctl start dnf-automatic-reboot.service
journalctl -u dnf-automatic-reboot.service -f

# Test reboot detection in isolation (no update, no reboot)
/usr/libexec/dnf-automatic-reboot/needs-reboot.sh; echo "exit: $?"

# Test watchdog (exits immediately when no state file is present)
/usr/libexec/dnf-automatic-reboot/watchdog.sh
```

If the service fails at startup, the journal will report the specific conflict — a
re-enabled timer or a changed `reboot` setting in `automatic.conf`:

```bash
journalctl -u dnf-automatic-reboot.service -e
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
| Repository with `gpgcheck=0` enabled | All | Reported by `run.sh` at the start of every run (reported, not fatal) |
| Repository `priority=` masks security errata from other channels | All | Reported by `run.sh` after every update; remove `priority=` from distribution repos, keep it only on third-party ones |
| `needs-restarting` always flags `kernel-uek` / `kernel-uek-core` | OL9 aarch64 UEK | Filtered by `needs-reboot.sh` via version cross-check |
| `needs-restarting` flags `systemd` after update even post-reboot | All | Filtered by `needs-reboot.sh` via `eu-readelf` build-id comparison |
| `needs-restarting` flags other core libraries (e.g. `glibc`) even with no live process using a stale version | All | Learned automatically by `needs-reboot.sh`: confirmed only after surviving a real reboot still flagged at the same version, proven via kernel boot ID; see [doc/README](doc/README) |
| `systemd-time-wait-sync.service` absent on UEK R8 | OL9 UEK R8 | Fixed — `%post` enables `chrony-wait.service`; see [below](#time-sync-on-uek-r8) |
| NTS sources fail under FUTURE crypto policy | OL9 FUTURE policy | Fix: `update-crypto-policies --set DEFAULT` |

### time-sync on UEK R8

`systemd-time-wait-sync.service` is not shipped on UEK R8, and nothing else is
ordered `Before=time-sync.target`, so the service unit's `Requires=time-sync.target`
was satisfied trivially and gated nothing.

`chrony` already ships `chrony-wait.service` — `chronyc waitsync`, ordered
`Before=time-sync.target` — disabled by default. The RPM `%post` enables it when
`[time] enable_chrony_wait = yes`, which makes the ordering real. No custom unit
is needed.

Note this gates the update run, not the boot-time value `needs-restarting` reads;
only an RTC fixes that. The `eu-readelf` build-id path in `needs-reboot.sh` is
immune to clock skew regardless.

## Bumping the version

```bash
# Edit Makefile: VERSION = x.y
# Edit dnf-automatic-reboot.spec: Version: x.y, add %changelog entry
make dist
# Then follow Building the RPM above
```
