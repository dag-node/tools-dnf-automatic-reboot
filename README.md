# dnf-automatic-reboot

Installs system updates every night and restarts the computer only when an
update needs a restart to take effect.

## Who this is for

On most Enterprise Linux 9 systems, `dnf-automatic` restarts after updates
by itself: set `reboot = when-needed` in `/etc/dnf/automatic.conf` and
enable `dnf-automatic-install.timer`. Use that there, not this package.

This package is for systems where that built-in restart does not work
reliably. The problem is seen on Oracle Linux 9 on `aarch64` boards that boot
through U-Boot, such as the Raspberry Pi 4 and the Compute Module 5:

- They have no clock battery, so the update tools misjudge which updates came
  after the last restart and ask for a restart on every run.
- A newly installed kernel is not chosen at the next boot, so a restart
  brings back the old kernel and asks for another restart.

On Red Hat Enterprise Linux 8, `dnf-automatic` does not restart after
updates at all.

This package filters out the false restart requests and restarts only when
the restart applies an update. Before a kernel restart it checks that the new
kernel is the one that will boot; if not, it does not restart and
logs why.

It installs on Enterprise Linux 8 and 9 (Red Hat Enterprise Linux, Oracle
Linux, Rocky Linux, AlmaLinux) with the standard GRUB boot menu.

## Quick start

```bash
sudo dnf install dnf-automatic
sudoedit /etc/dnf/automatic.conf
sudo dnf install ./dnf-automatic-reboot-1.5.0-*.el9.noarch.rpm
sudo systemctl enable --now dnf-automatic-reboot.timer dnf-automatic-watchdog.timer
```

The package is installed from its RPM file, run from the directory that
holds it: the `.el9` file on Enterprise Linux 9, the `.el8` file on
Enterprise Linux 8. The file comes from a CI run of this repository or from
[Building from source](#building-from-source).

The first two commands install `dnf-automatic` and open its settings file,
in which two lines must read:

```ini
apply_updates = yes
reboot = never
```

`apply_updates = yes` makes `dnf-automatic` install updates, not only
download them; `reboot = never` leaves the restart decision to this package.
If `dnf-automatic` is already set up, keep your other settings as they are.
This package reads the file and does not change it.

The third command installs this package. It first checks that the system
is one it can restart safely; if not, it stops before installing any files
and prints what to fix, as explained under
[If the installer refuses](#if-the-installer-refuses).
The last command turns on the nightly run and the watchdog that looks after it.

## What happens every night

Between 03:00 and 03:10 the package:

1. Blocks shutdown and restart, so an update is never cut off halfway.
2. Installs the available updates with `dnf-automatic`.
3. Checks whether any update needs a restart: a new kernel, or a core
   component such as `glibc` or `systemd`.
4. If one does, warns everyone logged in with the restart time and restarts
   one minute later. No further update runs until then. To call the restart
   off during that minute and allow updates again:
   `sudo /usr/libexec/dnf-automatic-reboot/cancel-reboot.sh`.
   If none does, restarts only the background services whose programs were
   updated, and the system keeps running.
5. Ends with one line in the log and on logged-in terminals: updates
   installed, whether a restart is scheduled, and which services were
   restarted, failed to restart, or are left on the old program. A failed
   service restart counts as a failed run.

Updates that `dnf` knows about but refuses to install, and repositories that
install packages without checking their signatures, are reported in the log.

A separate watchdog checks every five minutes. If an update run is still going
after three hours, the watchdog stops it and alerts you; it does not restart
while packages may be half-installed.

When something goes wrong, logged-in users get a message on their terminal and
the details go to `/var/log/dnf-automatic-reboot.log`.

## Check that it works

```bash
systemctl list-timers dnf-automatic-reboot.timer dnf-automatic-watchdog.timer
```

This lists when each timer runs next. After the first night, read what
happened:

```bash
sudo tail -n 30 /var/log/dnf-automatic-reboot.log
```

To run an update now, which installs updates and restarts if one needs it:

```bash
sudo systemctl start dnf-automatic-reboot.service
```

To only ask whether a restart is needed right now, without updating or
restarting: `sudo /usr/libexec/dnf-automatic-reboot/needs-reboot.sh; echo $?`.
It prints `0` for no, `1` for yes, and `2` when it cannot tell. It records
what it sees, as the nightly run does: a package flagged for the first time
is remembered, and one still flagged after a restart is marked as a false
alarm from then on. For a pending kernel it counts this boot as one restart
attempt, which later checks in the same boot do not repeat.

## If the installer refuses

The installer lists every problem it finds, then stops before installing any
files. Fix each one and run `sudo dnf install dnf-automatic-reboot` again.

| The message says | What to do |
|---|---|
| `... not platform:el8 or platform:el9` | This system runs a Linux version the package does not support. |
| `systemd is not the running init` | Install on the host itself, not inside a container. |
| `<package> is not installed` | `sudo dnf install <package>` |
| `GRUB_ENABLE_BLSCFG=true is not set` or `holds no BLS entry` | The system does not use the standard GRUB boot menu, which this package needs. |
| `grubby --default-kernel gave ...` | `sudo grubby --set-default /boot/vmlinuz-$(uname -r)` |
| `does not boot saved_entry` or `GRUB_DEFAULT=saved is not set` | Set `GRUB_DEFAULT=saved` in `/etc/default/grub`, then run the `grub2-mkconfig` command the message shows, with `sudo` |
| `kernel updates will not advance the GRUB default` | Add each line the message shows to the file it names. On Oracle Linux 9 with UEK these are `GRUB_UPDATE_DEFAULT_KERNEL=true` in `/etc/default/grub` and `DEFAULTKERNEL=kernel-uek-core` in `/etc/sysconfig/kernel`. |
| `the GRUB default is ..., not the newest installed` | If the newest kernel should run, run the `grubby --set-default` command the message shows, with `sudo`. The installer does not change the default itself, since that changes which kernel the next boot runs. |
| `upgrading from a version before 1.4.0` | See [Upgrading from an earlier version](#upgrading-from-an-earlier-version). |
| `dnf-automatic.timer is still enabled` | `sudo systemctl disable --now dnf-automatic.timer dnf-automatic-install.timer` |
| `/etc/dnf/automatic.conf has 'reboot = ...'` | Set `reboot = never` in `/etc/dnf/automatic.conf`; this package decides when to restart. |
| `/etc/dnf/automatic.conf has 'apply_updates = ...'` | Set `apply_updates = yes` in `/etc/dnf/automatic.conf`. |

The nightly run checks the `reboot` and `apply_updates` lines again each
time it starts. When either one no longer reads as in
[Quick start](#quick-start), the run stops, logged-in users get a message,
and the log names the line to fix.

A `WARNING` about `GRUB_SAVEDEFAULT=true` does not stop the install. It means
that choosing an older kernel from the boot menu once makes it the default;
after that, restarts for new kernels are held back, and the log says so, until
`sudo grubby --set-default` points at the newest kernel again.

## Changing the settings

Settings are in `/etc/dnf/automatic-reboot.conf`; each one is explained in the
file. The ones people change most:

| Setting | Default | Meaning |
|---|---|---|
| `reboot_delay_sec` | `60` | Seconds between the warning and the restart |
| `always_reboot` | `no` | `yes` restarts after every update, needed or not |
| `restart_services` | `yes` | `no` leaves updated background services running the old program |
| `wall_messages` | `yes` | `no` stops the messages to logged-in users |

To run at another time, override the timer:

```bash
sudo systemctl edit dnf-automatic-reboot.timer
```

and enter, for example for 01:30:

```ini
[Timer]
OnCalendar=
OnCalendar=*-*-* 01:30:00
```

The empty `OnCalendar=` line clears the 03:00 default, so the new time
replaces it.

## Computers without a clock battery

A Raspberry Pi has no clock that keeps time while it is off, so it starts with
the wrong time until it reaches a time server. That makes the update tools
believe some updates are newer than the last restart even after a restart,
and this package filters out those false alarms.

The installer makes updates wait until the clock is set, by turning on
`chrony-wait.service`. Two changes make the clock correct sooner. First, let
chrony jump the clock at start instead of adjusting it slowly:

```bash
echo 'makestep 1 -1' | sudo tee -a /etc/chrony.conf && sudo systemctl restart chronyd
```

Second, and better, fit a real-time clock module such as a DS3231: with the
correct time at boot, those false alarms do not occur.

## Upgrading from an earlier version

Versions before 1.4.0 cannot be upgraded in place. Remove the old version,
then install as in [Quick start](#quick-start):

```bash
sudo dnf remove dnf-automatic-reboot
```

Your settings file is kept as `/etc/dnf/automatic-reboot.conf.rpmsave`; copy
any changes you made back into the new `/etc/dnf/automatic-reboot.conf`. The
log and what the old version had learned about false alarms are deleted, so
the first night after the upgrade may restart once more than needed.

## Uninstalling

```bash
sudo dnf remove dnf-automatic-reboot
```

This stops and removes the timers, the program, its log and its learned
state. A settings file you changed is kept as
`/etc/dnf/automatic-reboot.conf.rpmsave`. Rotated logs and the lock file in
`/var/lib/dnf-automatic-reboot` are not the package's and stay; the
[operational reference](doc/README) lists them, and covers removing a
`make install` copy.

## More information

- [doc/README](doc/README), installed as
  `/usr/share/doc/dnf-automatic-reboot/README`: every setting, the log, and
  how restart decisions are made.
- Source and issues: <https://github.com/dag-node/tools-dnf-automatic-reboot>

## Building from source

```bash
make container-rpm EL=9
```

This builds the package the way CI does, inside a `rockylinux:9` container
started with `podman`, and leaves it in
`./rpmbuild/dnf-automatic-reboot/el9/RPMS/noarch/`. `EL=8` builds for
Enterprise Linux 8 into the `el8` folder beside it; each build replaces only
its own folder. Building in the container gives the file the
right `.el8` or `.el9` tag whatever the build host runs, and keeps the
test suite off that host. The file carries a local snapshot version,
`1.5.0-0.local.git<commit>`, which a released `1.5.0-1` replaces as an
ordinary upgrade. Copy it to the system it is for and install it as in
[Quick start](#quick-start).

`make check` runs the syntax checks, `shellcheck` and the test suite on any
system with `bash`; the suite does not need root and stubs every system
command. Tests that execute a stub skip themselves where the temporary
directory is mounted `noexec`; the container build runs them. On an EL8 or
EL9 system with `rpm-build` installed, `make rpm` builds directly into
`./rpmbuild/dnf-automatic-reboot/local`. [CLAUDE.md](CLAUDE.md) describes the
design and the conventions for changes.

Licensed under GPL-2.0-or-later; the RPM spec file is MIT. See
[REUSE.toml](REUSE.toml).
