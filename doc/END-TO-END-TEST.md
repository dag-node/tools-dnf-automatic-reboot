# End-to-end test on a live host

This test checks, on a real EL8 or EL9 host, that a reboot requested by this
package respects shutdown inhibitors, can be cancelled while it waits, and goes
ahead once the inhibitor is released. Containers and the test suite cannot
show this: it needs real systemd, logind and SELinux.

The test reboots the host once, at the end. It installs any updates that are
available, as a nightly run would. Everything else it changes is undone by the
steps below.

## Requirements

- Root on the host, with `dnf-automatic-reboot` installed and both timers enabled.
- No reboot pending: `ls /run/dnf-automatic-reboot.*` lists only `.lock` files.
- A window in which the host may reboot, away from the nightly run at 03:00.
- No `dnf` transaction of your own while the test runs.
- Three terminals on the host.
- `tools/verify-reboot-protocol.sh` from this repository, copied to the host.

## 1. Check the platform

```bash
sudo bash verify-reboot-protocol.sh > "$(hostname -s)-reboot-protocol.txt" 2>&1; tail -1 "$(hostname -s)-reboot-protocol.txt"
```

It must end with `0 FAIL`. The probe starts short-lived
`dnf-automatic-reboot-probe-*` units that run `/bin/true` or `sleep`, and never
reboots. Two lines matter most here: `systemctl accepts
--check-inhibitors=yes`, without which no reboot of this package happens, and
`chronyc waitsync reports the clock synchronised`, without which no update run
starts.

## 2. Prepare

Terminal 1 adds test settings to the end of the package's config. The last
occurrence of a key wins, so this also works on a config that predates a key:

```bash
printf '\n# exercise-begin\nreboot_delay_sec = 60\nalways_reboot = yes\nreboot_inhibited_wait_sec = 120\n# exercise-end\n' >> /etc/dnf/automatic-reboot.conf
```

`always_reboot = yes` makes the run request a reboot with no update pending,
`reboot_delay_sec = 60` shortens the delay to one minute, and
`reboot_inhibited_wait_sec = 120` gives up on an inhibited reboot after two
minutes.

Terminal 2 follows the run and the reboot unit for the whole test:

```bash
journalctl -f -u dnf-automatic-reboot.service -u dnf-automatic-reboot-scheduled-reboot.service
```

Terminal 3 holds the inhibitor in each scenario. It stands in for a package
transaction started by hand:

```bash
systemd-inhibit --what=shutdown --mode=block --who=exercise --why=test sleep 900
```

## 3. Cancel while the reboot is inhibited

No reboot.

1. Terminal 3: start the inhibitor.
2. Terminal 1: `systemctl start --no-block dnf-automatic-reboot.service`
3. Terminal 2 shows `always_reboot=yes in config - scheduling reboot regardless`,
   then `Reboot dispatch confirmed: … fires at <T>`. From `<T>` on, every
   30 seconds:
   `the reboot was refused, most likely by a shutdown inhibitor (… exercise … block) - retrying in 30s`.
4. After the first refusal, terminal 1:

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
3. Terminal 2 shows refusals at `<T>`, `<T>`+30 s, … `<T>`+120 s, then
   `the reboot was refused for 120s while the host stayed up … update runs stay held`.
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
3. As soon as terminal 2 shows `Reboot dispatch confirmed`, terminal 1 removes
   the test settings. The waiting reboot already holds its own; removing them
   now keeps the next nightly run from rebooting again:

   ```bash
   sed -i '/^# exercise-begin$/,/^# exercise-end$/d' /etc/dnf/automatic-reboot.conf; grep -c exercise /etc/dnf/automatic-reboot.conf
   ```

   Expected: `0`.
4. After the first `refused … retrying in 30s`, terminal 3: Ctrl-C.
5. Within 30 seconds terminal 2 shows `reboot-if-pending: Orderly reboot requested`,
   and the host reboots.
6. After the reboot:

   ```bash
   journalctl -b -1 --no-pager -u dnf-automatic-reboot-scheduled-reboot.service | tail -6; ls /run/dnf-automatic-reboot.*
   ```

   Expected: one or more refusals, then `Orderly reboot requested`; and only
   `.lock` files, since `/run` starts empty.

## Stopping early

```bash
sed -i '/^# exercise-begin$/,/^# exercise-end$/d' /etc/dnf/automatic-reboot.conf; /usr/libexec/dnf-automatic-reboot/cancel-reboot.sh; echo "exit: $?"
```

Then Ctrl-C in terminal 3. Check that `grep -c exercise /etc/dnf/automatic-reboot.conf`
prints `0`, and that `ls /run/dnf-automatic-reboot.*` lists only `.lock` files.
If `cancel-reboot.sh` exits 1 because the reboot command already ran, the
host is rebooting.

## Recording the result

Keep the probe output, and terminal 2's output from each scenario. A result
names the distribution and version, `systemctl --version | head -1`, and which
expected lines did not appear.
