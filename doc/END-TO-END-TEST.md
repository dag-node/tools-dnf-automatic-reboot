# End-to-end test on a live host

This test checks, on a real EL8 or EL9 host, that a reboot requested by this
package respects shutdown inhibitors, can be cancelled while it waits, and goes
ahead once the inhibitor is released. Containers and the test suite cannot
show this: it needs real systemd, logind and SELinux.

The test reboots the host once, at the end. It reinstalls glibc at the version
already installed, so that a reboot is genuinely due, and installs any updates
that are available, as a nightly run would. It does not change the package's
settings. Each run waits the fixed 5 minutes before its reboot, and section 4
waits out the 30 minutes a blocked reboot is retried, so the test takes about
an hour.

## Requirements

- Root on the host, with `dnf-automatic-reboot` installed and both timers enabled.
- No reboot pending: `ls /run/dnf-automatic-reboot.*` lists only `.lock` files.
- A window in which the host may reboot, away from the nightly run at 03:00 UTC.
- No `dnf` transaction of your own while the test runs.
- The installed glibc version available from an enabled repository, for
  `dnf reinstall`.
- Three terminals on the host, logged in as a user other than root who becomes
  root with `sudo`. Section 5 then also shows that a logged-in user does not
  hold the reboot.
- `tools/verify-reboot-protocol.sh` from this repository, copied to the host.

## 1. Check the platform

```bash
sudo bash verify-reboot-protocol.sh > "$(hostname -s)-reboot-protocol.txt" 2>&1; tail -1 "$(hostname -s)-reboot-protocol.txt"
```

It must end with `0 FAIL`. The probe starts short-lived
`dnf-automatic-reboot-probe-*` units that run `/bin/true` or `sleep`, one of
them under a shutdown inhibitor, and never reboots. Two lines matter most here:
`a held block-mode shutdown inhibitor reads as blocked`, without which the
package cannot tell that a transaction holds the reboot off, and `chronyc
waitsync reports the clock synchronised`, without which no update run starts.

## 2. Prepare

Terminal 1 makes glibc need a reboot, and removes what the package learned
about glibc, so that a glibc flag it had confirmed as false on a host without
a battery-backed clock is acted on again:

```bash
dnf -y reinstall glibc && sed -i '/^glibc\t/d' /var/lib/dnf-automatic-reboot/restart-state; LC_ALL=C dnf -q -C needs-restarting -r | grep -x '  \* glibc'
```

Expected: `  * glibc`.

Terminal 2 follows the run and the reboot unit for the whole test:

```bash
journalctl -f -u dnf-automatic-reboot.service -u dnf-automatic-reboot-scheduled-reboot.service
```

Terminal 3 holds the inhibitor in each scenario. It stands in for a package
transaction started by hand:

```bash
systemd-inhibit --what=shutdown --mode=block --who=exercise --why=test sleep 2700
```

## 3. Cancel while the reboot is inhibited

No reboot.

1. Terminal 3: start the inhibitor.
2. Terminal 1: `systemctl start --no-block dnf-automatic-reboot.service`
3. Terminal 2 shows `Reboot needed: glibc`, then
   `Reboot dispatch confirmed: … fires at <T>`. From `<T>` on, every
   30 seconds:
   `the reboot did not start: a shutdown inhibitor blocks it (… exercise … block) - retrying in 30s`.
4. After the first such line, terminal 1:

   ```bash
   /usr/libexec/dnf-automatic-reboot/cancel-reboot.sh; echo "exit: $?"; ls /run/dnf-automatic-reboot.*
   ```

   Expected: `reboot cancelled; update runs are allowed again`, `exit: 0`, and
   only the two `.lock` files. `a reboot request or the reboot command is in
   progress` means the command met an attempt; run it again.
5. Within 30 seconds terminal 2 shows `the reboot was cancelled - not rebooting`,
   and the reboot unit ends without an error.
6. Terminal 3: Ctrl-C.

## 4. Inhibitor outlasts the wait

No reboot.

1. Terminal 3: start the inhibitor.
2. Terminal 1: `systemctl start --no-block dnf-automatic-reboot.service`
3. Terminal 2 shows `did not start` at `<T>`, `<T>`+30 s, … `<T>`+1800 s, then
   `the reboot did not start within 1800s: a shutdown inhibitor blocks it … update runs stay held`.
   The reboot unit fails, and logged-in terminals receive
   `The scheduled reboot did not happen. Update runs stay blocked until the host reboots`.
4. Terminal 1 checks that update runs are held:

   ```bash
   systemctl is-failed dnf-automatic-reboot-scheduled-reboot.service; ls /run/dnf-automatic-reboot.*; systemctl start dnf-automatic-reboot.service; systemctl status dnf-automatic-reboot.service --no-pager | head -5
   ```

   Expected: `failed`, `/run/dnf-automatic-reboot.reboot-pending` present, and
   the start skipped on its `ConditionPathExists=!` condition.
5. Terminal 3: Ctrl-C. Terminal 1 releases the hold:

   ```bash
   /usr/libexec/dnf-automatic-reboot/cancel-reboot.sh; echo "exit: $?"; ls /run/dnf-automatic-reboot.*
   ```

   Expected: `the requested reboot had failed`, `exit: 0`, and only the two
   `.lock` files.

## 5. Inhibitor released, reboot goes ahead

Reboots the host.

1. Terminal 3: start the inhibitor.
2. Terminal 1: `systemctl start --no-block dnf-automatic-reboot.service`
3. After the first `did not start … retrying in 30s`, terminal 3: Ctrl-C.
4. Within 30 seconds terminal 2 shows `reboot-if-pending: Orderly reboot requested`,
   and the host reboots, although your user is still logged in.
5. After the reboot:

   ```bash
   journalctl -b -1 --no-pager -u dnf-automatic-reboot-scheduled-reboot.service | tail -6; ls /run/dnf-automatic-reboot.*
   ```

   Expected: one or more `did not start` lines, then `Orderly reboot requested`; and only
   `.lock` files, since `/run` starts empty.

## Stopping early

```bash
/usr/libexec/dnf-automatic-reboot/cancel-reboot.sh; echo "exit: $?"
```

Then Ctrl-C in terminal 3. Check that `ls /run/dnf-automatic-reboot.*` lists
only `.lock` files.
If `cancel-reboot.sh` exits 1 because the reboot command already ran, the
host is rebooting. glibc stays flagged until the host reboots, so the next
run schedules that reboot.

## Recording the result

Keep the probe output, and terminal 2's output from each scenario. A result
names the distribution and version, `systemctl --version | head -1`, and which
expected lines did not appear.
