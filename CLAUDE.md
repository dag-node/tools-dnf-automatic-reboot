# CLAUDE.md

## Project

`dnf-automatic-reboot` - unattended update + conditional reboot for EL8 and EL9;
developed on Oracle Linux 9 `aarch64` (UEK R8, RPi4, CM5) and RHEL 8 `x86_64`. Shell
scripts packaged as a noarch RPM.

Scope: EL8 and EL9 hosts on which `dnf-automatic` does not reboot when an update needs it.
On EL8 it cannot: RHEL 8.10's `dnf-automatic` has no reboot handling (see
[`dnf-automatic` on EL8](#dnf-automatic-on-el8)). On EL9 it has `reboot = when-needed`,
which fails on Oracle Linux 9 aarch64 booting through U-Boot (RPi4, CM5: no RTC, UEK
`saved_entry` not advancing). The failures observed on both ran with `apply_updates = yes`,
under both `upgrade_type = security` and `default`; the `apply_updates` check comes from
dnf-automatic's defaults, not from an observed failure. The `automatic.conf` on both surveyed
hosts carries `reboot` and `reboot_command`; with this package installed `reboot = never` is
required, so `reboot_command` is not used. The `%pre` gate accepts `PLATFORM_ID`
`platform:el8` and `platform:el9` and refuses any other. User-facing docs do not recommend
the package for an EL9 host where the built-in reboot works; they point there instead.

`tools/verify-el-prerequisites.sh` surveys every platform fact the package relies on.
The EL8/EL9 differences recorded in this file come from its runs on RHEL 8.10 (systemd 239, dnf 4.7)
and Oracle Linux 9.8 (systemd 252, dnf 4.14); re-run it before relying on a new
platform.

## Platform constraints (always apply)

- **OS:** EL8 and EL9 (RHEL, Oracle Linux, Rocky, Alma) — `dnf`, `rpm`, `systemctl`.
  Never `yum`, never `apt`. Code must run on EL8 and EL9, so on bash 4.4, gawk 4.2, systemd 239,
  rpm 4.14 on EL8.
- **Kernel:** UEK R8 (6.12.x), aarch64 on the RPi hosts; stock `kernel-core` on RHEL.
  `systemd-time-wait-sync.service` is absent on UEK R8.
- **Init:** systemd. SELinux enforcing. Never `setenforce 0`.
- **Container runtime:** Podman (not Docker) if containers ever needed.
- **Shell:** bash with `set -euo pipefail` + `IFS=$'\n\t'` in every script.
- **Encoding:** ASCII only in scripts and config files. Unicode is fine in Markdown.
- **No RTC.** The RPi4 has no real-time clock. This is the root cause of the
  needs-restarting false positives — see [Root cause](#root-cause-of-every-false-positive-a-wrong-clock-at-boot).

## Repository layout

```
README.md                       User install and usage guide
CLAUDE.md                       This file
dnf-automatic-reboot.spec       RPM spec
Makefile                        check / install / dist / clean targets
conf/automatic-reboot.conf      Runtime config installed to /etc/dnf/
scripts/run.sh                  Main orchestration (inhibitor + dnf + reboot)
scripts/watchdog.sh             Independent watchdog (soft/hard timeout)
scripts/needs-reboot.sh         Reboot decision + false-positive filtering
scripts/notify-failure.sh       OnFailure= notifier (wall + log)
scripts/cancel-reboot.sh        Cancels a pending reboot and allows update runs again
scripts/reboot-if-pending.sh    The scheduled reboot's command: reboots only while one is pending
scripts/reboot-request.sh       Reboot request/cancel protocol, sourced by the scripts that request, run or cancel reboots
scripts/run-state.sh            State file protocol (atomic publish, snapshot, checked removal), sourced by run and watchdog
units/dnf-automatic-reboot.service    Oneshot service wrapping run.sh
units/dnf-automatic-reboot.timer      Daily 03:00, RandomizedDelaySec=10min, Persistent
units/dnf-automatic-watchdog.service  Oneshot service wrapping watchdog.sh
units/dnf-automatic-watchdog.timer    Every 5 minutes
units/dnf-automatic-reboot-notify@.service  Failure notifier, instantiated by OnFailure=
tests/run-tests.sh              Test suite (bash only, run by make check and %check)
tmpfiles/dnf-automatic-reboot.conf   Log + state path modes and labels
logrotate/dnf-automatic-reboot       Log rotation drop-in
doc/README                      Operational reference (installed to /usr/share/doc/)
LICENSE, LICENSES/, REUSE.toml  GPL-2.0-or-later; the spec alone is MIT
tools/verify-grub-boot-flags.sh Read-only host check: can grubenv flags pick the boot entry?
tools/verify-el-prerequisites.sh Read-only host survey of every platform fact the package relies on
tools/verify-reboot-protocol.sh Host check of the systemd behaviour the reboot protocol relies on (probe units only, never reboots)
```

**Licensing.** Every script, test and the Makefile carries
`# SPDX-License-Identifier: GPL-2.0-or-later` on the line after the shebang; the spec
carries `# SPDX-License-Identifier: MIT`, as in every DagNode project. The copyright
holder lives only in `REUSE.toml`, so no header needs it and shipped files stay ASCII.
Files installed verbatim onto hosts (config, units, drop-ins) take no header; the
`REUSE.toml` catch-all covers them.

## Installed paths (on target)

```
/usr/libexec/dnf-automatic-reboot/     scripts/
/etc/dnf/automatic-reboot.conf         config (%config noreplace)
/usr/lib/systemd/system/               unit files
/usr/lib/tmpfiles.d/dnf-automatic-reboot.conf   log + state path creation
/etc/logrotate.d/dnf-automatic-reboot  log rotation (%config noreplace)
/usr/share/doc/dnf-automatic-reboot/   doc/README
/var/log/dnf-automatic-reboot.log      runtime log (%ghost in RPM)
/var/lib/dnf-automatic-reboot/restart-state            learning state (%ghost)
/var/lib/dnf-automatic-reboot/kernel-reboot-attempts   loop guard (%ghost)
```

`/usr/libexec`, not `/usr/local/lib`: `/usr/local` is reserved for the local
administrator and must never be written by an RPM, and it does not carry `bin_t`
in the base SELinux policy.

## Coding conventions

### Shell scripts

```bash
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

export LC_ALL=C   # parsers below match C strings

readonly CONFIG_FILE=/etc/dnf/automatic-reboot.conf
readonly LOG_FILE=/var/log/dnf-automatic-reboot.log
readonly SCRIPT_NAME=script-name   # used in log prefix

log()         { printf '<6>%s: %s\n' "${SCRIPT_NAME}" "$*"; printf '%s %s: %s\n'          "$(date -Iseconds)" "${SCRIPT_NAME}" "$*" >> "${LOG_FILE}" 2>/dev/null || true; }
log_warning() { printf '<4>%s: %s\n' "${SCRIPT_NAME}" "$*"; printf '%s %s: WARNING: %s\n' "$(date -Iseconds)" "${SCRIPT_NAME}" "$*" >> "${LOG_FILE}" 2>/dev/null || true; }
log_error()   { printf '<3>%s: %s\n' "${SCRIPT_NAME}" "$*"; printf '%s %s: ERROR: %s\n'   "$(date -Iseconds)" "${SCRIPT_NAME}" "$*" >> "${LOG_FILE}" 2>/dev/null || true; }

# Config reader: get_config_value KEY DEFAULT_VALUE
get_config_value() {
    local config_key="$1" default_value="$2" config_value
    config_value=$(grep -E "^\s*${config_key}\s*=" "${CONFIG_FILE}" 2>/dev/null \
                   | tail -1 | sed 's/^[^=]*=\s*//' | sed 's/\s*#.*//') || true
    printf '%s' "${config_value:-${default_value}}"
}
```

**Naming.** Identifiers are long and descriptive — full words, no abbreviations
beyond established domain terms (`evr`, `pid`, `uid`, `id`). `needs_restarting_exit_code`,
not `nr_exit`. `running_build_id`, not `run_bid`. `flagged_package_names`, not `flagged`.
Script-scope constants and globals are `UPPER_SNAKE_CASE`; function locals are
`lower_snake_case`. Function names are verb-first and equally explicit:
`newest_installed_kernel_version`, `grub_default_is_newest_kernel`.

- `readonly` for all constants; `local` for all function variables
- `[[ ]]` not `[ ]`
- Quote all variables: `"${VAR}"` not `$VAR`
- Save/restore `IFS` around comma-split loops: `PREVIOUS_IFS="${IFS}"; IFS=','; ...; IFS="${PREVIOUS_IFS}"`
- `|| true` on commands that are allowed to fail
- Never `return` at top level; use `exit`
- `get_config_integer` for any value that reaches an arithmetic test — a typo in the
  config must not abort the run inside `[[ ... -gt ... ]]`
- A function whose value is captured with `$(...)` must not log to stdout. Log
  helpers write to stdout for the journal, so inside a value-returning function
  they need `>&2` or the message ends up inside the returned value.
- A `[[ cond ]] && cmd` as the **last** statement of a function or `{ }` group
  sets its exit status. Under `set -e`, or with a `|| fallback` attached to the
  group, a false condition then reads as failure. Use an explicit `if`.

## Tests

`make check` is the gate for every change: `make lint` (bash -n, shellcheck,
ASCII-only) then `make test`. `%check` in the spec runs it during `rpmbuild`.

```bash
make check                     # lint + all suites
bash tests/run-tests.sh        # suites only
bash tests/run-tests.sh kernel state    # only matching test names
```

`tests/run-tests.sh` is bash and coreutils only — no test framework to install.
Each test runs in its own subshell against a temporary tree pointed at by
`DNF_AUTOMATIC_REBOOT_TEST_ROOT`. Every script resolves its paths and helper
binaries through that prefix, which is empty in production, so the production
paths are byte-identical and the tests exercise the real code:

```bash
readonly TEST_ROOT="${DNF_AUTOMATIC_REBOOT_TEST_ROOT:-}"
readonly CONFIG_FILE="${TEST_ROOT}/etc/dnf/automatic-reboot.conf"
```

`needs-reboot.sh` and `run.sh` end with a source guard, so sourcing them defines
their functions without running the decision. Because sourcing happens inside a
function, script-global arrays must be `declare -gA` or they become locals of
the sourcing function.

External commands invoked by bare name (`uname`, `rpm`, `grubby`, `eu-readelf`)
are stubbed as shell functions, which shadow the PATH lookup and need no exec
permission. Commands invoked by absolute path (`${SYSTEMCTL_BIN}`, `${DNF_BIN}`)
must be real files; tests needing them are marked `needs-exec` and skip
themselves where the temporary tree is mounted `noexec`.
`TMPDIR=<exec-capable dir> make test` runs them. The suite does not need root
and writes only inside its temporary tree.

`.github/workflows/ci.yml` runs `make lint` with a pinned ShellCheck on the runner,
then `make container-rpm` for `EL=8` and `EL=9`, which runs
`.github/scripts/build-in-container.sh` in `rockylinux:$EL`: `make rpm` (the suite,
including the `needs-exec` tests, then `rpmbuild -ba`) with a `0.<run>.git<sha>`
snapshot Release, a normal install that the `%pre` gate must refuse,
and a scriptlet-free install that must resolve every dependency and pass `rpm -V`. It
uploads the RPMs as artifacts; it does not sign or publish anything.

New tests belong on decisions that are dangerous to get wrong — parsing that
could invent a package name, verification that could skip a needed reboot, a
watchdog path that could reboot a host mid-transaction — not on line coverage.

### Config file parsing

All tunables live in `conf/automatic-reboot.conf`. Scripts never have hardcoded
policy values — always `get_config_value key default`. This keeps scripts testable without
installing the config. `get_config_value` is section-blind: it matches `^\s*KEY\s*=` anywhere
in the file, so every key name must be unique across all sections.

### Parsing external tool output

**Allowlist, never blocklist.** `needs-restarting` output is parsed by extracting
only lines of the exact shape `  * <name>`:

```bash
mapfile -t FLAGGED_PACKAGE_NAMES < <(printf '%s\n' "${needs_restarting_output}" \
    | sed -n 's/^[[:space:]]*\*[[:space:]]\+\([^[:space:]]\+\)[[:space:]]*$/\1/p')
```

Every string the plugin prints passes through gettext, and it writes warnings to
stderr for entries in `/etc/dnf/plugins/needs-restarting.d/` that name uninstalled
packages. Under a blocklist parse, a translated header or a stray stderr line reads
as a package name and reboots the host on every run. Hence: `LC_ALL=C`, stderr
captured to a separate file and logged rather than parsed, and the allowlist above.

### Fail-closed verification

A package is dropped from the reboot decision **only on positive evidence** that
its flag is spurious. Every "cannot tell" outcome keeps the package:

| Outcome | Decision |
|---------|----------|
| Build-ids match on all owned processes | False positive, drop |
| Build-id mismatch on any owned process | Genuine, keep |
| No owned running process, or unreadable build-id on any running process | Keep |
| Owned process gone from `/proc`, a zombie, or running another binary when its build-id could not be read | Ignore that process |
| Owned process still in `/proc` with an unreadable executable link | Keep |
| `eu-readelf` missing | Keep affected packages; kernel and learning paths still run |
| Running kernel == newest installed | False positive, drop |
| Anything else about the kernel | Keep |

An unverifiable state costs one reboot. The inverse — skipping a needed reboot —
leaves a host running known-vulnerable code, so it is never the default.

### Exit codes (needs-reboot.sh)

| Code | Meaning |
|------|---------|
| 0 | No reboot needed |
| 1 | Reboot needed |
| 2 | Undecidable: tool error, or a genuine kernel update that rebooting would not apply |

`needs-restarting -r` exits 1 both for "reboot required" and for any error dnf
handles, such as a missing cache. Only exit 1 with at least one `  * <name>` line is a
reboot requirement; exit 1 without one is retried once with a metadata refresh, then
reported as code 2.

Code 2 does not reboot, to avoid a loop. `run.sh` and `watchdog.sh` escalate it to a
non-zero exit so `OnFailure=` fires and the fail-open is never silent. Any status other
than 0, 1 and 2, such as 127 from a missing helper, is handled as code 2: only 0 means
"no reboot needed".

### State file `/run/dnf-automatic-reboot.state`

Written by `run.sh`, consumed by `watchdog.sh`. It exists from before `dnf-automatic`
starts until `run.sh` exits; `checking` covers the reboot decision and the service
restarts after it.

`scripts/run-state.sh`, sourced by both, holds the protocol. `run.sh` publishes the file by
writing a temporary file beside it and renaming it over the old one, so a reader never sees it
empty or half-written; a write that fails before the update aborts the run, since the
watchdog could not supervise it. Every write and removal holds
`/run/dnf-automatic-reboot.state.lock` (`flock`, `0600` like the request lock). The watchdog
reads the file once per cycle and decides from that snapshot; the identity re-check before a
kill compares the whole file with it. It removes the state and lock files only under the lock
and only while the state file still holds that snapshot, so a run that started in the
meantime keeps both. `run.sh` removes the file only while it holds the content it last
published.

```
phase=updating|checking
start=<unix timestamp>
start_uptime=<whole seconds of /proc/uptime>
pid=<PID of run.sh>
```

The watchdog measures elapsed time from `start_uptime` (`CLOCK_BOOTTIME`);
`watchdog.sh` does not read `start`. With no RTC, a run that starts before chrony synchronises sees the wall
clock step forward by however long the host was off; timed by wall clock, that
could trip the hard timeout and stop an rpm transaction minutes after it began. `/run`
does not survive a reboot, so a recorded uptime always belongs to the current boot.
A state file without a numeric `start_uptime` is malformed and removed; `start` is
for operators and is never used for timing. No pre-1.4 `run.sh` can write one
while this watchdog is installed: `%pre` refuses to install over any version
before 1.4.0 and names `dnf remove` instead. There is no migration code from
earlier versions, and none is to be added.

There is no `failed` phase: when `dnf-automatic` fails, `run.sh` exits at once and
its exit trap removes the state file, and `OnFailure=` reports the failure.

The watchdog treats the recorded `pid` as the run only while it is alive and equals
the unit's `MainPID` (`systemctl show --property=MainPID`; `run.sh` is the unit's
`ExecStart`). A live PID that differs was reused after the run died, and is handled
as a dead run: the state file is removed, and the watchdog does not kill any process
or reboot. A live PID with no numeric `MainPID` from `systemctl` is of unknown
identity: the watchdog does not act on it, and past the soft timeout it fails its unit.

Right before any kill, `kill_service_cgroup` re-reads the state file and `MainPID`.
The independent check takes minutes, in which the stuck run can end and the next run
start updating; a kill on the old decision would stop that run mid-transaction and
reboot. A changed `phase`, `start_uptime` or `pid`, or a `pid` that is no longer
`MainPID`, abandons the recovery and leaves the state file alone (exit 0); a live `pid`
with no numeric `MainPID` abandons it with exit 1.

`systemctl kill` names the unit, not one invocation of it, so the re-check alone would
leave a moment in which a new run could start and be killed, have its state file
removed, and be rebooted under. The watchdog therefore creates
`/run/dnf-automatic-reboot.recovery` before the re-check, and
`dnf-automatic-reboot.service` carries
`ConditionPathExists=!/run/dnf-automatic-reboot.recovery`: no run starts while the file
exists, and a run that started before it shows in the re-check. The file covers the
kill, the state-file removal and the reboot decision, and never outlives the watchdog:
the EXIT trap removes it on every exit, and the watchdog unit's `ExecStopPost=` removes it
unconditionally, covering a watchdog stopped by `TimeoutStartSec=`. A timer start
skipped by the condition waits for the next `OnCalendar=`.

A pending reboot has its own marker, so each file has one lifetime and one set of
removers:

| Marker | Lifetime | Removed by |
|--------|----------|------------|
| `/run/dnf-automatic-reboot.recovery` | identity re-check, kill, state cleanup, reboot decision | the watchdog's EXIT trap; `ExecStopPost=` |
| `/run/dnf-automatic-reboot.reboot-pending` | from before a reboot request until the reboot | the reboot (emptying `/run`); `cancel-reboot.sh`; a request that submitted nothing, for the file it created |

`dnf-automatic-reboot.service` carries `ConditionPathExists=!` for both. No timeout or
further condition is to be added to either marker.

### Reboot requests (`scripts/reboot-request.sh`)

`run.sh`, `watchdog.sh`, `cancel-reboot.sh` and `reboot-if-pending.sh` source one library for
the request and cancellation protocol; it is installed 0640 and never executed.

**The invariant.** No script calls `systemctl reboot` directly. Every reboot is the transient
`dnf-automatic-reboot-scheduled-reboot.service` running `reboot-if-pending.sh`, after
`reboot_delay_sec` through its timer, or at once for the watchdog's hard timeout. Holding the
request lock, `reboot-if-pending.sh` reboots only while `.reboot-pending` exists, and writes
`/run/dnf-automatic-reboot.reboot-dispatched` before it calls `systemctl reboot`. Holding the
same lock, `cancel-reboot.sh` refuses when the dispatched file exists, and otherwise removes
`.reboot-pending`. After a cancellation succeeds, no request of this package can reboot the
host: a timer that still fires, a job the timer queued before it stopped, or a submission
systemd processes late all find no marker and exit 0. Cancellation therefore does not depend
on reading every systemd state exactly.

**Lock.** `/run/dnf-automatic-reboot.reboot-request.lock` (`flock`). `request_reboot` holds it
from before it creates `.reboot-pending` until the dispatch's outcome is known, waiting up to
`reboot_request_lock_wait_sec`; `reboot-if-pending.sh` holds it from its marker check until
`systemctl reboot` returns, waiting the same time (passed on its command line).
`cancel-reboot.sh` takes it without waiting and refuses when it is held. `flock(2)` grants an
exclusive lock through a read-only descriptor, so any user who can open the file can block
every request: tmpfiles.d creates it `0600 root`, and `acquire_reboot_request_lock` creates
it under `umask 077` and `chmod 0600`s it before every use, in place, so holders and waiters
keep the same inode. The file is never removed.

**Request outcomes.** `submit_reboot` returns accepted (0), rejected (1) or unknown (2).
Rejected only when nothing was submitted: the scheduled reboot's state could not be read
before `systemd-run`. A failed `systemd-run` is accepted when the unit is visible afterwards,
and unknown otherwise, because a request may still be on its way to systemd. Accepted and
unknown keep `.reboot-pending`; rejected removes the one this request created. Unknown, and a
process stopped mid-request (its EXIT trap), log the check and recovery commands and fail the
unit; a late reboot still happens, because the marker is there. A run killed by SIGKILL
mid-request has no trap: when the watchdog then decides no reboot is needed, it fails its
unit if `.reboot-pending` exists with no reboot waiting or under way.

**Reboot outcomes.** `reboot-if-pending.sh` calls `systemctl reboot --check-inhibitors=yes`.
Run from a service, outside a terminal, `systemctl` otherwise skips the inhibitor check and
reboots under a package transaction that holds a block inhibitor. A `systemctl` that rejects
the option makes the script fail without rebooting. It exits 0 when the reboot is accepted,
and when no reboot is pending. When the call fails it reads the shutdown state first: `yes`
(logind accepted, perhaps delaying for an inhibitor) is success and is never requested again;
`unknown` fails with the dispatched file kept. Only `no` counts as a refusal, most likely by a
block inhibitor: the script removes the dispatched file, releases the lock, and tries again
every 30 seconds until `reboot_inhibited_wait_sec` (default 1800) has passed, then fails,
naming the block inhibitors logind lists. Between attempts the reboot can be cancelled. Nothing
in the package uses `--force`: the watchdog's kill ends the stuck run's own inhibitor, and any
other inhibitor belongs to somebody else. Its `OnFailure=` notice says whether update runs are
still held, and names `cancel-reboot.sh` unless the dispatched file makes cancellation refuse.

**Reading systemd.** `read_unit_snapshot` reads `LoadState`, `ActiveState`, `SubState` and
`Job` of one unit from one `systemctl show`, so the values describe one moment; a missing
`Job` line is no job. `read_scheduled_reboot_status` reads the timer, then the service, and
returns `dispatched` (the dispatched file exists), `in_progress` (service queued or running,
or timer `running`), `failed`, `waiting` (timer `SubState=waiting`; an `elapsed` timer is
not), `none`, or `unknown` for a failed read or any unlisted value. `read_host_shutdown_state`
is `yes` when `systemctl is-system-running` prints `stopping` or logind's
`PreparingForShutdown` is true, `no` only when both were read and the state is one of
`initializing`, `starting`, `running`, `degraded` or `maintenance`, and `unknown` otherwise.

**Cancellation.** `cancel-reboot.sh` refuses (exit 1, marker kept) while the lock is held,
when the dispatched file exists, when the scheduled reboot's state is `unknown`, and when the
shutdown state is `yes` or `unknown`. Otherwise it removes `.reboot-pending`, then stops a
waiting or running timer (a failure only warns: the timer's command finds no marker) and
resets a failed service.

**No update before a pending reboot.** `run.sh` exits 0 without updating while the scheduled
reboot is `waiting`, `in_progress` or `dispatched`, and 1 when it is `unknown`. The marker's
`ConditionPathExists=!` normally keeps the unit from starting then; this also covers a timer
with no marker, such as one a 1.4.0 watchdog scheduled during an upgrade to this version,
whose `ExecStopPost=` removes the 1.4.0 hold. Nothing migrates from 1.4.0.

`tools/verify-reboot-protocol.sh` checks these facts against real systemd, through the
library's own readers, with transient probe units that run `/bin/true` or `sleep`. On OL 9.8
(systemd 252) and RHEL 8.10 (systemd 239, util-linux 2.32.1) it observed the same:

- An unknown unit shows `Job=` with an empty value, and a queued start shows `Job=<id>` while
  the unit is still `inactive`.
- A transient `--on-active` timer is `SubState=waiting` until it fires, with
  `RemainAfterElapse=no`; once it has fired or been stopped, it and its service are
  `not-found`.
- Stopping a timer that has fired leaves its service's queued start job in place. Only
  `reboot-if-pending.sh`'s own marker check stops that job from rebooting.
- `systemd-run` without `--on-active` runs the command at once.
- A running host can report `degraded`, which reads as not shutting down.
- tmpfiles.d creates the lock `0600 root:root` with label `var_run_t`, and user `nobody` cannot
  open it.

- On both hosts `flock -n` and `flock -w` behave as the library expects, free and held, and
  bash expands an empty array under `set -u`.

`PreparingForShutdown` under a delay inhibitor needs a real shutdown, and is read from the
systemd 239 and 252 sources only.

After the kill, the watchdog waits up to `watchdog_kill_confirm_sec` for systemd to report
the unit `inactive` or `failed`. A failed `systemctl kill`, or a unit still active then,
is a failed recovery: the state file stays, the watchdog does not reboot, and it fails its
unit. `kill_recorded_run` signals the cgroup only, not the recorded PID: by then that
number may belong to another process.

Watchdog decisions by phase:

| Phase | Soft timeout + dnf idle | Hard timeout |
|-------|------------------------|--------------|
| `updating` | Leave for hard timeout (unknown completion) | Kill cgroup + alert; reboot only if `force_reboot_on_hard_timeout=yes` |
| `checking` | Run independent needs-reboot check, kill cgroup | Kill cgroup + reboot (dnf already returned cleanly) |

The independent check can hang like the one it replaces, so it runs under `timeout`
at three times `needs_restarting_timeout_sec` and counts as undecidable (code 2) when
it does not finish. `dnf-automatic-watchdog.service` sets `TimeoutStartSec=15min`: a
oneshot has no start timeout by default, and a watchdog that does not exit keeps the
timer from starting the next cycle.

Killing always targets the whole service cgroup via `systemctl kill --kill-whom=all`
(`--kill-who=all` on systemd older than 252, the release that renamed it; systemd 239
accepts only the old spelling, 252 accepts either; `systemctl_kill_target_option` picks
it from
`systemctl --version`). On RHEL 8.10 (systemd 239), `--kill-who=all --signal=SIGKILL`
on a transient unit killed an orphaned grandchild left in its cgroup, which is the case
this kill exists for. `dnf-automatic` runs behind `systemd-inhibit` and
`timeout(1)`, so signalling the recorded PID and its direct children leaves the rpm
transaction running while the caller proceeds to reboot.

At hard timeout in `phase=updating` an rpm transaction may be half-applied. That is
the same uncertainty for which the dead-PID path already refuses to reboot, so the
default is to kill and alert. The reboot never uses `--force`, which remounts filesystems
read-only under running processes, risks the rootfs on a flash-backed host, and overrides
other users' inhibitors.

### State files under `/var/lib/dnf-automatic-reboot/`

Both are tab-delimited with the package name in field 1, rewritten whole under an
`flock` on `.state.lock`, and manipulated with `awk -F'\t' '$1 == name'` — exact
field comparison, never a substring or regex match, so `libglibc` is not caught by
a rule about `glibc`.

`restart-state` — written and read by `needs-reboot.sh` only; survives reboots by
design. One row per tracked package; a new EVR supersedes the old row:

```
<name>\t<evr>\t<boot_id>\t<first_seen_epoch>\t<pending|confirmed>
```

`kernel-reboot-attempts` — consecutive reboots scheduled for a kernel version that
has not become the running one. Cleared by the first check that finds the target running,
whatever `needs-restarting` reports: with a correct clock it no longer flags the kernel then. `boot_id` names the boot
that counted the last attempt: every check in that boot belongs to the same attempt,
so a check run by hand, the watchdog's check or a repeated run does not use up the
limit; only a boot that comes up on the old kernel counts the next one. With an
unreadable `boot_id` every check counts:

```
<name>\t<target_version>\t<attempt_count>\t<boot_id>
```

## Root cause of every false positive: a wrong clock at boot

`needs-restarting -r` performs exactly one test per package, in
`needs_restarting.py`:

```python
for pkg in installed.filter(name=NEED_REBOOT):
    if pkg.installtime > process_start.boot_time:
        need_reboot.add(pkg.name)
```

`NEED_REBOOT` is a fixed list — `kernel`, `kernel-core`, `kernel-rt`, `glibc`,
`linux-firmware`, `systemd`, `dbus`, `dbus-broker`, `dbus-daemon`, `microcode_ctl` —
extended by `*.conf` drop-ins in `/etc/dnf/plugins/needs-restarting.d/` (this is how
`kernel-uek` enters the list on OL9). **There is no version comparison anywhere in
the plugin.**

The code quoted in this section is the EL9 plugin (dnf-plugins-core 4.3). The EL8
plugin (4.0.21) has the same per-package test and `NEED_REBOOT` list, but does not read
`UnitsLoadStartTimestamp` or `btime`; its boot-time source is not established.

`get_boot_time()` prefers systemd's `UnitsLoadStartTimestamp` over D-Bus, falling
back to `max(mtime of /proc/1, btime in /proc/stat)`. On a host with no RTC that
timestamp is captured before chrony steps the clock, so the recorded boot time sits
permanently in the past and every package on the list stays flagged forever. The
plugin's own docstring concedes `btime` is the source that "works for machines
without RTC"; it is simply not the one it uses.

Consequences for this repo:

- Fitting an RTC (DS3231 on i2c) removes the cause outright and makes
  `filter_packages` and restart-state learning dead weight. Everything below is a
  workaround for a host that has none.
- `chrony-wait.service` narrows but does not close the window: it gates
  `time-sync.target`, not the earlier moment at which systemd records
  `UnitsLoadStartTimestamp`.

## Known false positives (needs-reboot.sh handles automatically)

### Kernel packages (aarch64 and x86_64)

`uname -r` and rpm's `%{VERSION}-%{RELEASE}.%{ARCH}` are the same string on both UEK
and stock EL kernels, so the cross-check is an equality test, not a substring
search. The arch-stripped form is accepted as well, for kernels whose release string
carries no arch suffix. Equal = the running kernel already is the newest installed
one = false positive. Different = genuine. Covers `kernel-uek`/`kernel-uek-core`
(aarch64 UEK) and `kernel`/`kernel-core` (x86_64 RHEL 8/9) with the same code path.
Packages not installed on the running system are treated as genuine, not skipped.

Before a genuine kernel reboot is scheduled, `grubby --default-kernel` must already
point at `/boot/vmlinuz-<newest installed>`. If it does not, rebooting would return
to the same kernel and be requested again on the next run — an unbounded reboot loop
on a host whose `saved_entry` never advances. The reboot is withheld and logged at
error level. `kernel_reboot_attempt_limit` is the backstop for every other cause of
a kernel that never becomes the running one.

### systemd (all)

Cross-verification: walk `/proc/*/exe`, find **every** process whose binary is owned
by the package (`rpm -qf`), compare ELF build-ids of each running process against the
on-disk binary via `eu-readelf`. All matching = false positive; any mismatch =
genuine. Checking only the first match is wrong: PID 1 re-execs itself during a
systemd upgrade and so always matches, while journald, udevd and logind can still be
running the old image. The same holds within one binary: PID 1 and every
`systemd --user` manager run `/usr/lib/systemd/systemd`, and only PID 1 re-execs, so
every PID of a binary is checked, not one sample. Only the rpm query is deduplicated,
to one `rpm -qf` per distinct binary.
Requires `elfutils` (hard RPM dependency).

### Any non-kernel package (self-learning)

Packages outside `filter_packages` (e.g. `glibc`) have no build-id-verifiable owned
daemon binary, so `verify_build_id`'s `/proc/*/exe`-ownership check does not apply to
them. `needs-reboot.sh` instead learns their restart-state by observation, recorded in
[`restart-state`](#state-files-under-varlibdnf-automatic-reboot): a package/EVR pair
reaches `confirmed` (skipped, no reboot) only once it is still flagged by
`needs-restarting` at that exact EVR after a reboot has genuinely occurred, proven by
a change in `/proc/sys/kernel/random/boot_id` rather than any timestamp comparison.
The first observation of a given package/EVR pair always triggers one reboot — that
reboot is what proves the flag spurious or genuine. A new EVR on an
already-`confirmed` package starts a fresh, unverified cycle, so a real future update
is never masked by an old confirmation. `kernel*` packages are exempt; the
version-string check above remains their sole authority. Packages in `filter_packages` are
exempt too: a build-id mismatch, or a build-id that cannot be verified, keeps the package, and
no recorded `confirmed` row can overrule it. Only packages that reach the learning branch of
`classify_flagged_packages` (`LEARNABLE_PACKAGE_NAMES`) are learned. Controlled by
`learn_false_positives` in `automatic-reboot.conf`.

## What `needs-restarting -r` does not cover

`-r` inspects the fixed package list above and nothing else — it never looks at
running processes. A security update to sshd, nginx, bind, or anything linking a
refreshed library patches the on-disk file and leaves the vulnerable image resident,
with no reboot flag raised.

`run.sh` closes this with a `needs-restarting -s` pass, which walks `/proc/*/smaps`
and names the affected systemd units. Units are restarted with `systemctl try-restart`
so a unit that is not running is left alone, each under `restart_service_timeout_sec`,
and the pass is skipped entirely when a reboot is already scheduled. `restart_services_exclude` holds the units that must
never be restarted from underneath a running system — `dbus`/`dbus-broker` break every
client holding a bus connection, `systemd-logind` drops session tracking, and the two
units of this package would kill the run. Extend that list, never shorten it.

A restart that fails, one still unfinished at `restart_service_timeout_sec`, and a
`needs-restarting -s` that cannot list the units each leave pre-update code running, so
each fails the run. An excluded unit does not: it is left running by design. The run
ends with one line naming the update, reboot and restart outcome, for example
`Updates installed; no reboot needed; restart still pending for sshd.service. Check:
systemctl status sshd.service`, logged and sent through `wall`.

## `dnf-automatic` on EL8

RHEL 8.10's `dnf-automatic` (dnf 4.7) installs updates and never reboots.
`/usr/lib/python3.6/site-packages/dnf/automatic/main.py` does not contain the word `reboot`,
and a run that installed a newer kernel logged no reboot attempt. A `reboot` or
`reboot_command` key in `automatic.conf` is accepted and never read, so on EL8 every kernel
update waits for a manual reboot unless this package performs it. On Oracle Linux 9.8,
`/usr/lib/python3.9/site-packages/dnf/automatic/main.py` defines both options and reboots
when `reboot` is `when-changed`, or `when-needed` and `base.reboot_needed()` is true; it runs
`reboot_command` through `os.system` and raises an error on a non-zero exit code. `%pre` and `check_conflicts`
still require `reboot = never` on EL8: the key is inert there and is honoured on EL9, and one
rule for both keeps the file's meaning the same across platforms.

With a correct clock, `needs-restarting -r` flagging a kernel means a kernel package was
installed during this boot, which under unattended updates is a newer kernel awaiting a
reboot: genuine. A kernel is never applied without one. The only cause of a false kernel flag
is a boot time recorded before the clock was set (see
[Root cause](#root-cause-of-every-false-positive-a-wrong-clock-at-boot)); the version
comparison in `needs-reboot.sh` exists for that case.

### kpatch

kpatch loads live patches (`kpatch-patch-<kernel version>` packages) into the running kernel.
They cover selected CVEs of that kernel, not the whole content of a later kernel erratum, and
they install no kernel package. `needs-restarting -r` does not consider them, and neither does
`needs-reboot.sh`: a newer installed kernel is a genuine reboot whether or not live patches are
loaded. `kpatch.service` in `active (exited)` only says it ran at boot; `kpatch list` shows
what is loaded.

The package has no kpatch exemption, by design. That a loaded live patch covers every fix in
the installed kernel cannot be established from package data, and that is the "cannot tell"
case [fail-closed verification](#fail-closed-verification) keeps. On a kpatch host the lever is
when the reboot happens: an `OnCalendar=` override of `dnf-automatic-reboot.timer` for a
maintenance window. Deferring kernel reboots on such hosts would be a separate design decision.

## Unsigned repositories

`run.sh` reports every enabled repository with an explicit `gpgcheck=0` at the
start of each run, before any package is installed. Unattended installation from
an unsigned repository is a code path nobody is watching, so it must at least be
loud.

The check reads `/etc/yum.repos.d/*.repo` and `/etc/dnf/dnf.conf` and reports
only an explicit `gpgcheck=0` in a section that is not explicitly disabled. dnf's
own default is deliberately not modelled: a check that reports repositories which
are in fact fine becomes a check operators learn to ignore. It reports and
continues rather than aborting — a local unsigned repository is somebody's
deliberate choice, and refusing to patch the host is the worse outcome.

`awk` is fatal on a missing file and never runs its `END` rule, so the file list
is filtered to existing paths first. Passing an unexpanded glob would have the
same effect.

## Advisories dnf will not apply

`run.sh` reports, after each update, any security advisory that applies to this
host but that dnf refuses to install.

`dnf updateinfo` reads the whole package sack; the depsolver does not. A
repository `priority=`, an `excludepkgs=`, a disabled channel or a versionlock
can leave an advisory permanently visible-but-unappliable, and the update run
reports success either way. The host simply never receives the fix, and nothing
says so — the same class of silent failure this package exists to prevent, one
layer further down.

The check compares what dnf itself reports as applicable
(`updateinfo list --updates --security`) against whether a security transaction
resolves to anything (`check-update --security`, exit 100 = yes, 0 = none). That
catches any cause without enumerating causes. It runs *after* `dnf-automatic`,
where anything still outstanding is genuinely stuck rather than merely pending.
Advisory IDs are matched by shape (`PREFIX-YEAR-NUMBER` as Oracle's `ELSA-2026-26533`,
`PREFIX-YEAR:NUMBER` as Red Hat's `RHSA-2020:3011`, either with an optional `-REVISION`
as Oracle's `ELSA-2026-60226-0`; EPEL's `FEDORA-EPEL-2024-bf31852fe0` has a dash-joined
prefix and a hexadecimal number), so a line of any other shape in
the output is not reported as an advisory. Known gap: `check-update --security`
exits 100 when any security update is installable, so a stuck advisory next to an
installable one is logged as outstanding at warning level, not at error level.

**Repository priority is the trap to know.** `dnf.conf(5)`: *"If there is more
than one candidate package for a particular operation, the one from a repo with
the lowest priority value is picked, possibly despite being a lower version."* A
`priority=` on a distribution channel therefore pins every package that channel
ships and masks errata from every other channel, permanently and silently.
Priorities exist to protect a distribution from third-party repositories; between
a distribution's own channels they do nothing but create this hole. `kernel-uek*`
and `kernel*` are distinct package names and never compete, so UEK needs no
priority.

```bash
# Does anything apply that dnf will not install?
dnf updateinfo list --updates --security      # what dnf says applies
dnf check-update --security; echo "rc=$?"     # 100 = actionable, 0 = nothing
dnf --assumeno --setopt='*.priority=99' update --security   # levels priorities
```

## UEK GRUB BLS default (kernel not booted after update)

On OL9 UEK hosts a newly installed `kernel-uek-core` is not selected at the next
boot. On EL9 `/usr/lib/kernel/install.d/20-grub.install` only advances the GRUB
`saved_entry` when `DEFAULTKERNEL` (`/etc/sysconfig/kernel`) names the installed
package AND `GRUB_UPDATE_DEFAULT_KERNEL=true` (`/etc/default/grub`); neither is set
by default on UEK, so `kernel-install` silently never advances `saved_entry`. The EL8
`20-grub.install` gates on `GRUB_UPDATE_DEFAULT_KERNEL=true` alone and does not read
`DEFAULTKERNEL`.

The `%pre` gate requires the settings instead of writing them, on every host (UEK,
RHCK, RHEL): `GRUB_UPDATE_DEFAULT_KERNEL=true`, `DEFAULTKERNEL=<running kernel package>`
on EL9, and a GRUB default already on the newest installed kernel of that package. It
names each missing line and the `grubby --set-default` command. It does not edit
`/etc/default/grub` or `/etc/sysconfig/kernel`, which belong to the operator, and does
not change the default: `grubby --set-default` at install would change which kernel the
next boot runs, possibly one an operator left behind on purpose.

Nothing needs to mark a boot successful. In RHEL's GRUB scripts `boot_success` and
`boot_indeterminate` only decide whether the menu is hidden (`10_reset_boot_success`);
the one snippet that changes the booted entry, `08_fallback_counting`, acts only
while `boot_counter` is set, which only greenboot's rpm-ostree integration does.
Setting `boot_success=1` at every boot would disarm that rollback, so this package
never touches `grubenv` flags.

The running kernel's package is the one `rpm -qf /lib/modules/$(uname -r)/vmlinuz`
names. `verify_grub_default` in `needs-reboot.sh` is the runtime check that the
default still advances — see [Kernel packages](#kernel-packages-aarch64-and-x86_64).

## Time synchronisation gate

The service unit carries `After=`/`Requires=time-sync.target` so rpm `INSTALLTIME`
stamps and the boot-time comparison inside `needs-restarting` both see a correct
clock. On UEK R8 `systemd-time-wait-sync.service` does not exist and nothing else is
ordered `Before=time-sync.target`, so that dependency is satisfied trivially and
means nothing on its own.

`chrony` ships `chrony-wait.service` — `chronyc waitsync`, ordered
`Before=time-sync.target` — disabled by default. `%post` enables it when
`[time] enable_chrony_wait = yes`. It is never disabled on erase: a synchronised
clock is not this package's to take away. `%post` does not start it for the current boot.

The unit ordering does not require a successful synchronisation: `time-sync.target` is
reached even when `chrony-wait.service` fails (systemd issue 4880). `run.sh` therefore
checks the clock itself before installing anything: `wait_for_clock_sync` runs
`chronyc waitsync` (every 10 s, remaining correction below 0.1 s) for at most
`clock_sync_wait_sec` (default 600), and a run whose clock chronyd has not confirmed by then
installs nothing and fails. A missing `chronyc` fails it too. `require_clock_sync = no`
turns the check off for a host without chrony. The check asks chronyd, not the kernel's
synchronised flag (`timedatectl`'s `NTPSynchronized`), which chrony is understood to set only
with `rtcsync`; hosts without an RTC do not use it. That is not yet confirmed on a host. `tools/verify-reboot-protocol.sh` reports whether
`chronyc waitsync` confirms the clock on a host.

`/etc/chrony.conf` needs `makestep 1 -1` so the clock is stepped rather than slewed
at boot. `rtcsync` is pointless on a host with no RTC and is not required.

`chrony-wait.service` gates the update run, not the boot time `needs-restarting`
reads, which only an RTC corrects. The build-id comparison in `needs-reboot.sh`
compares ELF notes and does not read the clock, so skew does not affect it.

## SELinux rules

- Scripts at `/usr/libexec/dnf-automatic-reboot/` inherit `bin_t` from the base
  policy via `restorecon` called in `%post`.
- Config at `/etc/dnf/` inherits `etc_t`.
- Log at `/var/log/` inherits `var_log_t`; the tmpfiles.d entry creates it with that
  label and mode 0640 before any script writes to it.
- State directory at `/var/lib/dnf-automatic-reboot/` inherits `var_lib_t`
  from base policy; no custom `fcontext` needed.
- Never use `chcon` in scripts — use `restorecon` or `semanage fcontext`.
- If a new AVC denial appears: `ausearch -m avc -ts recent | audit2why` first.

## RPM packaging rules

- `%config(noreplace)` on the config file and the logrotate drop-in — local edits
  survive upgrades.
- `%ghost` on the log file and both state files — RPM owns the path and SELinux label
  without owning content. `systemd-tmpfiles --create` in `%post` materialises them.
- `%dir` on `/var/lib/dnf-automatic-reboot/` and on `%{_libexecdir}/%{name}` — both are
  package-exclusive (unlike `/var/log`, which the `filesystem` package owns), so they
  need explicit `%dir` entries to be tracked, labeled, and removed on erase.
- `%systemd_post` / `%systemd_preun` / `%systemd_postun_with_restart` macros — never
  call `systemctl` to change unit state in scriptlets. **One deliberate exception**:
  `chrony-wait.service` belongs to the `chrony` package, so no preset of ours can
  reach it. `%post` enables it directly, guarded on `systemctl cat` finding the
  unit. It is never disabled on erase. (`%pre` only reads state with
  `systemctl is-enabled`.)
- `%pre` is the install gate: it refuses, before any file is touched, a host that is
  not `platform:el8` or `platform:el9`, not booted by systemd, missing a dependency
  (`--nodeps`), not GRUB2 in BLS mode with a default `grubby` can read, not booting
  `saved_entry` (`GRUB_DEFAULT=saved`, and every full `grub.cfg` — on EL8 EFI that is
  the ESP copy, on EL9 EFI the ESP copy is a `configfile` stub), unable to advance
  the default on a kernel update (`GRUB_UPDATE_DEFAULT_KERNEL`, plus `DEFAULTKERNEL`
  on EL9, and the default already on the newest installed kernel), running a pre-1.4
  version, or with `/etc/dnf/automatic.conf` not set
  to `reboot = never` and `apply_updates = yes` (dnf-automatic defaults a missing
  `apply_updates` to false and then exits 0 after only downloading).
  `Requires(pre): dnf-automatic` puts that file in place before `%pre` reads it, and
  `run.sh` `check_conflicts` repeats the `automatic.conf` and stock-timer checks at
  every start, failing the run through `OnFailure=`. `GRUB_SAVEDEFAULT=true` only
  warns. It reports every failure, then exits once. File paths go through `%{?preflight_root}`, empty in every built RPM, so
  the test suite runs the real scriptlet via `rpmspec -P --define` against a
  fixture tree without any runtime switch that could bypass the gate. There is no
  migration from pre-1.4 versions and none is to be added.
- `BuildArch: noarch` — shell scripts only, no compiled artifacts.
- `Requires: elfutils` — `eu-readelf` is required for the build-id check.
- `Requires: logrotate` — the drop-in in `/etc/logrotate.d` needs a consumer.
- `Requires: systemd >= 239` — EL8's systemd. Every unit directive and systemctl
  option the package uses exists there; the one renamed option is chosen at runtime
  (see the state file section).
- `Requires(pre): grubby` — the `%pre` gate runs `grubby --default-kernel`.
- `BuildRequires: make gawk util-linux` — `%check` runs `make check`, which needs
  `make`, `awk` and `flock`. The spec ships in the `make dist` tarball so the gate
  tests run under `%check` too (`rpmspec` comes with `rpm-build`).
- Cleanup of paths owned by a *previous* version belongs in `%posttrans`: in
  `%post` the old package's files are still present.
- Version bump: update both `Makefile` (`VERSION`) and `dnf-automatic-reboot.spec`
  (`Version:` + `%changelog`). Versions are `X.Y.Z`, matching the org's `vX.Y.Z` tags.
- `%changelog` follows the org format: one `- TAG: sentence.` item per change,
  continuation lines indented two spaces, tags in the order `CHANGE`, `SECURITY`, `NEW`,
  `FIX`, `DOCS` (`LICENSE` for a licence change), and a blank line between entries.

## Known limitations

`newest_installed_kernel_version` sorts with `sort -V` over
`%{VERSION}-%{RELEASE}.%{ARCH}`, which is not rpm's comparison algorithm and
ignores epoch. It orders real UEK and EL release strings correctly (`4.10` above
`4.4` above `4.3.1`, covered by a test) and kernel packages do not carry an
epoch, so this is accurate in practice. Anything that gives kernels an epoch, or
a release string using rpm's `~`/`^` operators, needs `rpmdev-vercmp` instead.

## Open issues

1. **No RTC on the RPi4.** See [Root cause](#root-cause-of-every-false-positive-a-wrong-clock-at-boot).
   Fitting a DS3231 (or DS1307) on i2c removes the entire false-positive problem
   class and makes `filter_packages` and restart-state learning unnecessary. The
   overlay goes in `/boot/efi/config.txt` (`dtoverlay=i2c-rtc,ds3231`); run
   `hwclock --systohc` after the first NTP sync, and disable any fake-hwclock
   service that conflicts.

2. **NTS TLS failures under FUTURE crypto policy** — two configured NTS sources
   (`paris.time.system76.com`, `sth2.nts.netnod.se`) fail certificate verification
   under OL9 FUTURE policy; both are currently commented out in `/etc/chrony.conf`.
   chronyd logs `TLS handshake failed: certificate uses insecure algorithm`.
   Workaround: `update-crypto-policies --set DEFAULT`, then restart chronyd. Proper
   fix: use sources whose chains are FUTURE-compatible, or `time.cloudflare.com` NTS
   which works under DEFAULT.

## Useful commands

```bash
# Syntax + lint before building
make check && shellcheck -S info scripts/*.sh

# Build RPM the way CI does, in rockylinux:$EL (podman);
# lands in ./rpmbuild/dnf-automatic-reboot/el$EL, one folder per EL major
make container-rpm EL=9
# Build RPM on an EL host (dnf install rpm-build systemd-rpm-macros); lands in
# ./rpmbuild/dnf-automatic-reboot/el9 (local without DIST), emptied first
make rpm DIST=.el9

# Full update cycle now: applies updates and reboots if needed
systemctl start dnf-automatic-reboot.service

# Test reboot logic without running dnf.  Writes state as a scheduled run
# does: restart-state rows, and one kernel reboot attempt for this boot.
/usr/libexec/dnf-automatic-reboot/needs-reboot.sh; echo "exit: $?"

# Watchdog by hand: exits at once when no run is in progress (no state file);
# during a run it acts as its timer would, kill and reboot included
/usr/libexec/dnf-automatic-reboot/watchdog.sh

# A scheduled reboot, and how to cancel it (also allows update runs again)
systemctl list-timers dnf-automatic-reboot-scheduled-reboot.timer
/usr/libexec/dnf-automatic-reboot/cancel-reboot.sh

# What -r decides, and the boot time it decides against
LC_ALL=C dnf -q -C needs-restarting -r
busctl get-property org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager UnitsLoadStartTimestamp \
  | awk '{print "unitsload", strftime("%F %T", $2/1000000)}'
awk '/^btime/{print "btime    ", strftime("%F %T", $2)}' /proc/stat
rpm -q --qf '%{INSTALLTIME:date}\n' glibc systemd

# Services still running pre-update code (what -r never reports)
LC_ALL=C dnf -q -C needs-restarting -s

# Check inhibitor lock is held during a run
systemd-inhibit --list

# Check what satisfied time-sync.target
systemctl list-dependencies time-sync.target --reverse
systemctl is-enabled chrony-wait.service

# Kernel default must match the newest installed kernel
grubby --default-kernel
rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-uek-core | sort -V | tail -1

# Learned state
column -t /var/lib/dnf-automatic-reboot/restart-state
column -t /var/lib/dnf-automatic-reboot/kernel-reboot-attempts

# Compare build-ids for systemd false-positive diagnosis
eu-readelf -n /proc/1/exe              | grep 'Build ID'
eu-readelf -n /usr/lib/systemd/systemd | grep 'Build ID'

# Watch a live run
journalctl -u dnf-automatic-reboot.service -f
tail -f /var/log/dnf-automatic-reboot.log
```

## What not to do

- Do not add `setenforce 0` or `permissive` as a workaround for any SELinux denial.
- Do not hardcode policy (timeouts, package names) in scripts — use `get_config_value`.
- Do not parse tool output with a blocklist of known-uninteresting lines, and do not
  fold stderr into a parsed stream. Match the shape you want and discard the rest.
- Do not treat an unverifiable state as a false positive. "Cannot tell" keeps the
  package and costs a reboot; the inverse leaves a host running vulnerable code.
- Do not call `systemctl` directly in RPM scriptlets — use the `%systemd_*` macros,
  except the two documented enablement cases.
- Do not downgrade `Requires: elfutils` to `Recommends` — `eu-readelf` is required for
  the build-id path.
- Do not filter a package in `filter_packages` without confirming the false positive
  with the build-id or version cross-check first.
- Do not key restart-state entries on package name alone — always name + EVR, so a
  genuine future update is never masked by an old confirmation.
- Do not match state-file rows with `grep` — use `awk -F'\t' '$1 == name'`, or
  `libglibc` matches a rule about `glibc`.
- Do not extend restart-state learning to `kernel*` packages — the version-string
  check is their sole, more authoritative, source of truth.
- Do not kill the run by PID — `systemctl kill` the whole unit, or
  `dnf-automatic` survives behind `timeout(1)`.
- Do not use `systemctl reboot --force`, and do not call `systemctl reboot` without
  `--check-inhibitors=yes`; reboot only through `reboot-if-pending.sh`.
- Do not install anything under `/usr/local` from the RPM.
- Do not edit `/etc/dnf/automatic.conf` from a scriptlet, a script or the docs'
  commands. It belongs to the operator and may predate this package: check it and
  name the line to change.
- Do not use `return` at script top level — use `exit`.
- Do not use Unicode characters in scripts or config files.
- Do not abbreviate identifiers — see [Naming](#shell-scripts).
