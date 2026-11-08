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
scripts/watchdog.sh             Independent watchdog: stops a stalled run, never reboots
scripts/needs-reboot.sh         Reboot decision + false-positive filtering
scripts/notify-failure.sh       OnFailure= notifier (wall + log)
scripts/cancel-reboot.sh        Cancels a pending reboot and allows update runs again
scripts/reboot-if-pending.sh    The scheduled reboot's command: reboots only while one is pending
scripts/check-config.sh         Validates /etc/dnf/automatic-reboot.conf and names how it differs from the shipped one; never edits it
scripts/config.sh               The one config parser and its schema, sourced by every script that reads the config
scripts/reboot-request.sh       Reboot request/cancel protocol, sourced by the scripts that request, run or cancel reboots
scripts/run-state.sh            State file protocol (atomic publish, snapshot, checked removal), sourced by run and watchdog
units/dnf-automatic-reboot.service    Oneshot service wrapping run.sh
units/dnf-automatic-reboot.timer      Daily 03:00 UTC, RandomizedDelaySec=600, Persistent
units/dnf-automatic-watchdog.service  Oneshot service wrapping watchdog.sh
units/dnf-automatic-watchdog.timer    Every 5 minutes
units/dnf-automatic-reboot-notify@.service  Failure notifier, instantiated by OnFailure=
tests/run-tests.sh              Test suite (bash only, run by make check and %check)
tmpfiles/dnf-automatic-reboot.conf   Log + state path modes and labels
logrotate/dnf-automatic-reboot       Log rotation drop-in
doc/README                      Operational reference (installed to /usr/share/doc/)
doc/END-TO-END-TEST.md          Live-host test of inhibitors, cancellation and the reboot (repository only)
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
/usr/share/dnf-automatic-reboot/automatic-reboot.conf   the config as shipped, for check-config.sh
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

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
load_config "${CONFIG_FILE}" || true        # main refuses to act while CONFIG_ERRORS is set
RESTART_SERVICES=$(config_value restart_services)
```

**Naming.** Identifiers are long and descriptive — full words, no abbreviations
beyond established domain terms (`evr`, `pid`, `uid`, `id`). `needs_restarting_exit_code`,
not `nr_exit`. `running_build_id`, not `run_bid`. `flagged_package_names`, not `flagged`.
Script-scope constants and globals are `UPPER_SNAKE_CASE`; function locals are
`lower_snake_case`. Function names are verb-first and equally explicit:
`read_unit_snapshot`, `classify_running_kernel_family`, `publish_run_phase`.
A function that reads state into its output starts with `read_`; one that
succeeds or fails on a condition may read as the condition
(`grub_default_is_kernel_release`). Time values carry their unit in full:
`_seconds`, `_minutes`.

- `readonly` for all constants; `local` for all function variables
- `[[ ]]` not `[ ]`
- Quote all variables: `"${VAR}"` not `$VAR`
- Save/restore `IFS` around comma-split loops: `PREVIOUS_IFS="${IFS}"; IFS=','; ...; IFS="${PREVIOUS_IFS}"`
- `|| true` on commands that are allowed to fail
- Never `return` at top level; use `exit`
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

`scripts/config.sh` is the only reader of `/etc/dnf/automatic-reboot.conf`: `run.sh`,
`needs-reboot.sh` and `check-config.sh` source it. `CONFIG_SCHEMA` there is the registry of every key, its
type, default and range; the file header states the grammar. A test checks that the
shipped file sets every key to its schema default, and another that every key a script
reads is in the schema and every schema key is read.

`load_config` parses the whole file once per process and never exits. Every doubt about
the file is an error, collected in `CONFIG_ERRORS`, and no doubt resolves to a default: a
line of another shape, a key this version does not read, a key set twice, an empty
value, a boolean outside `yes true on 1` / `no false off 0`, an integer outside its
range, a file that cannot be read. A key left out takes its default. `CONFIG_VALUES` holds well-formed
values either way, so a sourced script works; a caller must not act on them:

| Caller | With `CONFIG_ERRORS` set |
|---|---|
| `run.sh` | first in `main`: logs each error, walls, exits 1 before refreshing, installing or rebooting |
| `needs-reboot.sh` | exits 2 |
| `check-config.sh` | prints the errors and the commands that replace the file from `.rpmnew` or the shipped copy, keeping a backup; exit 2 |
| `watchdog.sh`, `notify-failure.sh`, `cancel-reboot.sh`, `reboot-if-pending.sh` | do not read the config: supervising a run, a failure notice, a cancellation and an accepted reboot do not depend on it |

There are no aliases for keys of earlier versions and none are to be added: an edited
copy of an earlier file is invalid, and every run fails until an operator replaces it.

A setting exists only where an operator has a reason to change it — services restarted
by hand, a slow link, a deliberate unsigned repository or versionlock, a clock not kept by
chronyd — and its range keeps every value safe. Every other limit is a constant, because a
value outside it breaks a guard: the reboot delay (`REBOOT_DELAY_SECONDS`, 300) and the
blocked-reboot retry window (`REBOOT_RETRY_TIMEOUT_SECONDS`, 1800) in `run.sh`;
`KERNEL_REBOOT_ATTEMPT_LIMIT` (3) in `needs-reboot.sh`; the watchdog's stall windows and
`KILL_CONFIRMATION_TIMEOUT_SECONDS` (300) in `watchdog.sh`; the request lock wait
(`REBOOT_REQUEST_LOCK_TIMEOUT_SECONDS`, 300) in `reboot-request.sh`; the SIGTERM-to-SIGKILL
grace of every `timeout(1)` (`KILL_GRACE_SECONDS`, 300) in `config.sh`. The metadata refresh,
restart-state learning and `chrony-wait.service` are always on. So are the safety sets an
operator may add to but not shorten: `BUILT_IN_EXCLUDED_UNIT_PATTERNS` (`run.sh`) and
`BUILD_ID_VERIFIED_PACKAGES` (`needs-reboot.sh`). The ranges need no rule between keys:
`dnf_query_timeout_seconds` and `service_restart_timeout_seconds` stop at 900, so a query or
a restart, with its kill grace, ends within the watchdog's shortest stall window.
`doc/README` lists the constants for operators.

### Parsing external tool output

**Allowlist, never blocklist.** `needs-restarting` output is parsed by extracting
only lines of the exact shape `  * <name>`:

```bash
mapfile -t FLAGGED_PACKAGE_NAMES < <(printf '%s\n' "${needs_restarting_output}" \
    | sed -n 's/^[[:space:]]*\*[[:space:]]\+\([^[:space:]]\+\)[[:space:]]*$/\1/p')
```

Every string the plugin prints passes through gettext, and it writes warnings to
stderr for entries in `/etc/dnf/plugins/needs-restarting.d/*.conf` that name
uninstalled packages. Under a blocklist parse, a translated header or a stray stderr line reads
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
| Running kernel == newest installed of its family | False positive, drop |
| Newer kernel of the family, GRUB default on it or unreadable, attempt limit not reached | Keep |
| GRUB default on another kernel, attempt limit reached, no owner of the running `vmlinuz`, no readable release, or a flagged kernel package of another family | Withhold every reboot: exit 2 |

An unverifiable state costs one reboot. The inverse — skipping a needed reboot —
leaves a host running known-vulnerable code, so it is never the default. A kernel the
reboot would not boot is the exception: that reboot comes back on the same kernel and
repeats on every run, so it is withheld, with every other reboot, until an operator acts.

### Exit codes (needs-reboot.sh)

| Code | Meaning |
|------|---------|
| 0 | No reboot needed |
| 1 | Reboot needed |
| 2 | Undecidable: an invalid config, a tool error, or a kernel withheld as in [Fail-closed verification](#fail-closed-verification), including a kernel reboot attempt that could not be recorded. A kernel case vetoes the reboot even when another package needs one |

`needs-restarting -r` exits 1 both for "reboot required" and for any error dnf
handles, such as a missing cache. Only exit 1 with at least one `  * <name>` line is a
reboot requirement; exit 1 without one is retried once with a metadata refresh, then
reported as code 2.

Code 2 does not reboot, to avoid a loop. `run.sh` escalates it to a non-zero exit so `OnFailure=` fires and the fail-open is never silent. Any status other
than 0, 1 and 2, such as 127 from a missing helper, is handled as code 2: only 0 means
"no reboot needed". Nothing promotes a 0 to a reboot: the host reboots only when a
flagged package needs it.

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
dnf_log_inode=<inode of /var/log/dnf.log before dnf-automatic, or none>
dnf_log_offset=<its size then, or 0>
```

The watchdog measures time on `CLOCK_BOOTTIME` (`/proc/uptime`, recorded in
`start_uptime` and in its progress record); `watchdog.sh` does not read `start`. With no
RTC, a run that starts before chrony synchronises sees the wall clock step forward by
however long the host was off; timed by wall clock, that step would read as a long
stall. `/run` does not survive a reboot, so a recorded uptime always belongs to the
current boot.
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
identity: the watchdog does not act on it, and once the run has stalled it fails its unit.

Right before any kill, `kill_service_cgroup` re-reads the state file and `MainPID`.
Between the stall verdict and the kill the stuck run can end and the next run start
updating; a kill on the old verdict would stop that run mid-transaction. A changed `phase`, `start_uptime` or `pid`, or a `pid` that is no longer
`MainPID`, abandons the recovery and leaves the state file alone (exit 0); a live `pid`
with no numeric `MainPID` abandons it with exit 1.

`systemctl kill` names the unit, not one invocation of it, so the re-check alone would
leave a moment in which a new run could start and be killed and have its state file
removed. The watchdog therefore creates
`/run/dnf-automatic-reboot.recovery` before the re-check, and
`dnf-automatic-reboot.service` carries
`ConditionPathExists=!/run/dnf-automatic-reboot.recovery`: no run starts while the file
exists, and a run that started before it shows in the re-check. The file covers the
kill and the state-file removal, and never outlives the watchdog:
the EXIT trap removes it on every exit, and the watchdog unit's `ExecStopPost=` removes it
unconditionally, covering a watchdog stopped by `TimeoutStartSec=`. A timer start
skipped by the condition waits for the next `OnCalendar=`.

A pending reboot has its own marker, so each file has one lifetime and one set of
removers:

| Marker | Lifetime | Removed by |
|--------|----------|------------|
| `/run/dnf-automatic-reboot.recovery` | identity re-check, kill, state cleanup | the watchdog's EXIT trap; `ExecStopPost=` |
| `/run/dnf-automatic-reboot.reboot-pending` | from before a reboot request until the reboot | the reboot (emptying `/run`); `cancel-reboot.sh`; a request that submitted nothing, for the file it created |

`dnf-automatic-reboot.service` carries `ConditionPathExists=!` for both. No timeout or
further condition is to be added to either marker.

### Reboot requests (`scripts/reboot-request.sh`)

`run.sh`, `cancel-reboot.sh` and `reboot-if-pending.sh` source one library for the request
and cancellation protocol, and `watchdog.sh` sources it for its readers; it is installed
0640 and never executed.

**The invariant.** No script calls `systemctl reboot` directly, and only `run.sh` requests a
reboot. Every reboot is the transient `dnf-automatic-reboot-scheduled-reboot.service` running
`reboot-if-pending.sh`, `REBOOT_DELAY_SECONDS` after the decision through its timer. Holding the
request lock, `reboot-if-pending.sh` reboots only while `.reboot-pending` exists, and writes
`/run/dnf-automatic-reboot.reboot-dispatched` before it calls `systemctl reboot`. Holding the
same lock, `cancel-reboot.sh` refuses when the dispatched file exists, and otherwise removes
`.reboot-pending`. After a cancellation succeeds, no request of this package can reboot the
host: a timer that still fires, a job the timer queued before it stopped, or a submission
systemd processes late all find no marker and exit 0. Cancellation therefore does not depend
on reading every systemd state exactly.

**Lock.** `/run/dnf-automatic-reboot.reboot-request.lock` (`flock`). `request_reboot` holds it
from before it creates `.reboot-pending` until the dispatch's outcome is known, waiting up to
`REBOOT_REQUEST_LOCK_TIMEOUT_SECONDS` (300); `reboot-if-pending.sh` holds it from its marker
check until `systemctl reboot` returns, waiting the same time (passed on its command line, so
a timer submitted by an earlier run keeps its arguments).
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
mid-request has no trap: when the watchdog has stopped a run in its reboot check, it fails its
unit if `.reboot-pending` exists with no reboot waiting or under way.

**Reboot outcomes.** Holding the lock, `reboot-if-pending.sh` reads logind's `BlockInhibited`
before each attempt (`read_shutdown_block_state`): `blocked` while a block-mode inhibitor names
`shutdown`, as a package transaction's does, `unknown` for any answer not shaped `s "a:b"`.
Only `free` reaches plain `systemctl reboot`. The check is the package's own: logind lets root
override a block inhibitor, and `systemctl` run by root outside a terminal checks none.
`--check-inhibitors=yes` would check too, but it also refuses while any other user has a
session, so one open SSH login would hold every reboot and, through the marker, every update
run. An inhibitor taken between the read and the call is not honoured, as with `systemctl`'s
own check. The script exits 0 when the reboot is accepted, and when no reboot is pending. When
the call fails it reads the shutdown state first: `yes` (logind accepted, perhaps delaying for
an inhibitor) is success and is never requested again; `unknown` fails with the dispatched
file kept; `no` removes it. Blocked, unreadable and `no` release the lock and try again every
30 seconds until `REBOOT_RETRY_TIMEOUT_SECONDS` (1800) has passed, then fail, naming the
reason and the block inhibitors logind lists. Between attempts the reboot can be cancelled.
Nothing in the package uses `--force`: the watchdog's kill ends the stuck run's own inhibitor,
and any other inhibitor belongs to somebody else. Its `OnFailure=` notice says whether update
runs are still held, and names `cancel-reboot.sh` unless the dispatched file makes
cancellation refuse. The notifier is passed the failed unit as `%i`; `%I` would turn every
`-` in the name into `/`. It quotes the failed run by the unit's `InvocationID`, which a failed
unit keeps until its next start (`_SYSTEMD_INVOCATION_ID` for the run's output,
`INVOCATION_ID` for systemd's messages about it), and falls back to the unit's last lines when
that selects nothing.

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
- `chronyc waitsync` confirms the clock on both, with `rtcsync` set on one and not the other.

`PreparingForShutdown` under a delay inhibitor needs a real shutdown, and is read from the
systemd 239 and 252 sources only. So are logind letting root override a block inhibitor and
`systemctl reboot` by root outside a terminal checking neither inhibitors nor sessions. The
probe holds a block-mode shutdown inhibitor and checks that `read_shutdown_block_state` reports
it.

After the kill, the watchdog waits up to `KILL_CONFIRMATION_TIMEOUT_SECONDS` (300) for systemd to report
the unit `inactive` or `failed`. A failed `systemctl kill`, or a unit still active then,
is a failed recovery: the state file stays, and the watchdog fails its unit. `kill_service_cgroup` signals the cgroup only, not the recorded PID: by then that
number may belong to another process.

The watchdog judges a run by progress alone, never by its age, and never reboots: the next
run makes every reboot decision, with its delay and the kernel veto. `stall_window_minutes`
picks the window from the recorded phase:

| Phase | dnf phase | Killed after this long without progress | Then |
|-------|-----------|------------------------------------------|------|
| `updating` | `download`, `checked` | `PRE_TRANSACTION_STALL_TIMEOUT_MINUTES` (60) | alert: nothing installed, the next run retries |
| `updating` | `transaction`, `unknown` | `TRANSACTION_STALL_TIMEOUT_MINUTES` (180) | alert naming `dnf history info last; dnf check` |
| `checking` | not read | `REBOOT_CHECK_STALL_TIMEOUT_MINUTES` (60) | alert: the next run decides the reboot; a `.reboot-pending` left without a reboot fails the unit |

A run of any other phase gets the longest window. `dnf-automatic-watchdog.service` sets
`TimeoutStartSec=15min`: a oneshot has no start timeout by default, and a watchdog that does
not exit keeps the timer from starting the next cycle. Its slowest path is the kill and up to
`KILL_CONFIRMATION_TIMEOUT_SECONDS` to confirm it.

Killing always targets the whole service cgroup via `systemctl kill --kill-whom=all`
(`--kill-who=all` on systemd older than 252, the release that renamed it; systemd 239
accepts only the old spelling, 252 accepts either; `systemctl_kill_target_option` picks
it from
`systemctl --version`). On RHEL 8.10 (systemd 239), `--kill-who=all --signal=SIGKILL`
on a transient unit killed an orphaned grandchild left in its cgroup, which is the case
this kill exists for. `dnf-automatic` runs behind `systemd-inhibit`, so signalling the
recorded PID and its direct children leaves the rpm transaction running.

A run is never stopped while it works: a download over a slow link can take days, and an
upgrade to the next minor EL release on a Raspberry Pi takes hours. dnf-automatic runs with no
deadline; there is no setting for one, since a deadline stops dnf mid-transaction as readily
as mid-download. Every watchdog cycle of a run, in either phase, records its progress
signature in `/run/dnf-automatic-reboot.progress`: the
processes in the unit's cgroup (`ControlGroup`, read from `cgroup.procs` under
`/sys/fs/cgroup`, the systemd v1 hierarchy, or `unified`) and the sum of their `rchar` and
`wchar` from `/proc/PID/io`. librepo writes each downloaded chunk to its file as it arrives,
and rpm and its scriptlets read and write files, so both show; any change counts, a process
starting or exiting included. dnf's cache and logs are not read for progress: every dnf command,
`dnf-makecache.timer`'s included (every one to two hours on the surveyed hosts), writes its
start line to `dnf.log` and `dnf.rpm.log`, so counting them would keep a hung run's window open
indefinitely. The
record carries the run's `pid` and `start_uptime`; a cycle that finds another run's record, or
none, counts as progress now. Counters that cannot be read, or a record that cannot be written,
kill nothing and fail the watchdog. dnf's own `minrate`, `timeout` and `retries` are left
alone.

How long a stall is tolerated depends on whether rpm has started changing the system, which
`read_dnf_run_phase` reads from the run's part of `dnf.log`. dnf 4 writes each line as
`<timestamp> <LEVEL> <message>`; its logging setup writes `--- logging initialized ---` at
start, and `base.py` writes, at `INFO`, `Running transaction check`, `Transaction check
succeeded.`, `Running transaction test`, `Transaction test succeeded.` and, right before rpm's
transaction, `Running transaction`. Only those whole messages count (allowlist). `run.sh` records
the log's inode and size in the state file before dnf-automatic starts; the watchdog reads from
there, through one rotation to `dnf.log.1`. A run whose start line the parser has not
recognised is `unknown`, as is a log it cannot follow (no position, a second rotation,
`log_compress`): a log format other than the expected one never reads as "before the
transaction". Another dnf command during the run can only add a `Running transaction`, which
is the cautious direction.

- `download` or `checked`: nothing installed; the next run finds the downloads in the cache.
- `transaction` or `unknown`: a scriptlet rebuilding SELinux policy or an initramfs can run
  long without a log line, hence the longer window.

The windows are constants, and no setting turns them off: a window of 0 would kill a run
whatever it does, mid-transaction included. `tools/verify-el-prerequisites.sh` checks the
messages, the line format and the log settings. On the surveyed OL 9.8 (dnf 4.14) and RHEL
8.10 (dnf 4.7) hosts it found all six messages in the source and in `dnf.log` as
`<timestamp> INFO <message>`, in this order for every transaction, with `log_size` 1 MB,
`log_rotate` 4 and `log_compress` off.

A run's length does not depend on the timer: a timer elapse during a run requests a start of
an activating oneshot, which joins the running start job, so that elapse is skipped, never
overlapped. This is systemd's job model; the probe checks it.

A run stopped in `phase=updating` may leave an rpm transaction half-applied. That is the same
uncertainty for which the dead-PID path already refuses to reboot, so the watchdog alerts,
naming `dnf history info last; dnf check`. No reboot in this package uses `--force`, which
remounts filesystems read-only under running processes, risks the rootfs on a flash-backed
host, and overrides other users' inhibitors.

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
extended by `*.conf` files in `/etc/dnf/plugins/needs-restarting.d/`. Oracle's OL9 build
(`python3-dnf-plugins-core-4.3.0-*.0.1.el9`) adds `kernel-uek` and `kernel-uek-core` to the
list itself; the surveyed OL 9.8 host has no `needs-restarting.d` directory.
**There is no version comparison anywhere in the plugin.**

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

- Fitting an RTC (DS3231 on i2c) removes the cause outright and makes the build-id
  check and restart-state learning dead weight. Everything below is a
  workaround for a host that has none.
- `chrony-wait.service` narrows but does not close the window: it gates
  `time-sync.target`, not the earlier moment at which systemd records
  `UnitsLoadStartTimestamp`.

## Known false positives (needs-reboot.sh handles automatically)

### Kernel packages: the running family

`needs-reboot.sh` decides once for the family of the running kernel: the package that
owns `/lib/modules/$(uname -r)/vmlinuz` (`kernel-uek-core`, `kernel-core`) and its meta
package, the same name without `-core` (`kernel-uek`, `kernel`), which owns no files on
either surveyed host. Every flagged name of the family gets the same verdict, and the
attempt is counted once, under the `-core` package's name.

The family's installed releases are the `/lib/modules/<release>/vmlinuz` paths
`rpm -ql` lists for the `-core` package. A module directory name is what `uname -r`
prints for that kernel, `+rt` and `+64k` suffixes included, which rpm's
`%{VERSION}-%{RELEASE}.%{ARCH}` does not carry; so the check is an equality test
whatever the release string holds. Running == newest = false positive. Different =
genuine.

Before a genuine kernel reboot is scheduled, `grubby --default-kernel` must already
point at `/boot/vmlinuz-<newest release>`. If it does not, rebooting would return to the
same kernel and be requested again on the next run — an unbounded reboot loop on a host
whose `saved_entry` never advances. `KERNEL_REBOOT_ATTEMPT_LIMIT` (3) is the backstop for
every other cause of a kernel that never becomes the running one; a `grubby` answer that
is not a kernel path is not read as stale, and the limit still counts that reboot.

A stale default, the attempt limit reached, a running `vmlinuz` no package owns, a
family with no readable release, and a flagged `kernel*` package of another family
(RHCK updated on a UEK host) each set `REBOOT_WITHHELD`, and `main` exits 2 whatever else
is flagged: a glibc or systemd reboot does not carry the host onto the kernel it
already runs. The error names the repair (`grubby --set-default`, the
`GRUB_UPDATE_DEFAULT_KERNEL` and `DEFAULTKERNEL` lines, or the attempt file to remove).
The kernel check is always on; there is no setting that turns it or the GRUB check off.

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

Packages other than the kernel family and `BUILD_ID_VERIFIED_PACKAGES` (`systemd`), such
as `glibc`, have no build-id-verifiable owned daemon binary, so `verify_build_id`'s `/proc/*/exe`-ownership check does not apply to
them. `needs-reboot.sh` instead learns their restart-state by observation, recorded in
[`restart-state`](#state-files-under-varlibdnf-automatic-reboot): a package/EVR pair
reaches `confirmed` (skipped, no reboot) only once it is still flagged by
`needs-restarting` at that exact EVR after a reboot has genuinely occurred, proven by
a change in `/proc/sys/kernel/random/boot_id` rather than any timestamp comparison.
The first observation of a given package/EVR pair always triggers one reboot — that
reboot is what proves the flag spurious or genuine. A new EVR on an
already-`confirmed` package starts a fresh, unverified cycle, so a real future update
is never masked by an old confirmation. `kernel*` packages are exempt; the
version-string check above remains their sole authority. `BUILD_ID_VERIFIED_PACKAGES` are
exempt too: a build-id mismatch, or a build-id that cannot be verified, keeps the package, and
no recorded `confirmed` row can overrule it. Only packages that reach the learning branch of
`classify_flagged_packages` (`LEARNABLE_PACKAGE_NAMES`) are learned. Learning is always on:
without it, a host with no RTC reboots for glibc at every run.

## What `needs-restarting -r` does not cover

`-r` inspects the fixed package list above and nothing else — it never looks at
running processes. A security update to sshd, nginx, bind, or anything linking a
refreshed library patches the on-disk file and leaves the vulnerable image resident,
with no reboot flag raised.

`run.sh` closes this with a `needs-restarting -s` pass, which walks `/proc/*/smaps`
and names the affected systemd units. Units are restarted with `systemctl try-restart`
so a unit that is not running is left alone, each under `service_restart_timeout_seconds`,
and the pass is skipped entirely when a reboot is already scheduled.
`BUILT_IN_EXCLUDED_UNIT_PATTERNS` in `run.sh` holds the units that must never be restarted
from underneath a running system — `dbus`/`dbus-broker` break every client holding a bus
connection, `systemd-logind` drops session tracking, `user@`, `getty@` and `autovt@` end
sessions, and this package's units would kill the run.
`restart_services_excluded_patterns` adds to it and cannot remove from it. Extend that
list, never shorten it.

A restart that fails, one still unfinished at `service_restart_timeout_seconds`, and a
`needs-restarting -s` that cannot list the units each leave pre-update code running, so
each fails the run. An excluded unit does not: it is left running by design. The run
ends with one line naming the update, reboot and restart outcome, for example
`Updates installed (packages: 3); no reboot needed; restart still pending for sshd.service. Check:
systemctl status sshd.service`, logged and sent through `wall`.

## `dnf-automatic` on EL8

RHEL 8.10's `dnf-automatic` (dnf 4.7) installs updates and never reboots.
`/usr/lib/python3.6/site-packages/dnf/automatic/main.py` does not contain the word `reboot`,
and a run that installed a newer kernel logged no reboot attempt. A `reboot` or
`reboot_command` key in `automatic.conf` is accepted and never read, so on EL8 every kernel
update waits for a manual reboot unless this package performs it. On Oracle Linux 9.8,
`/usr/lib/python3.9/site-packages/dnf/automatic/main.py` defines both options and reboots
when `reboot` is `when-changed`, or `when-needed` and `base.reboot_needed()` is true; it runs
`reboot_command` through `os.system` and raises an error on a non-zero exit code. `%pre` and
`check_conflicts` judge the file by what dnf-automatic's loader reads, and EL8's has no
`reboot` option, so on EL8 the key is not checked. After an upgrade to EL9 the key takes
effect, and `check_conflicts` refuses the first run if it is not `never`.

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
only an explicit `gpgcheck=0` in a section that is not explicitly disabled, `enabled=`
taking libdnf's false values (`0`, `no`, `false`, `off`, in any case). dnf's
own default is deliberately not modelled: a check that reports repositories which
are in fact fine becomes a check operators learn to ignore. It reports and
continues rather than aborting — a local unsigned repository is somebody's
deliberate choice, and refusing to patch the host is the worse outcome.

`awk` is fatal on a missing file and never runs its `END` rule, so the file list
is filtered to existing paths first. Passing an unexpanded glob would have the
same effect.

## Advisories an update did not install

`run.sh` reports, after each update, every security advisory that applies to this
host but that the update did not install.

A repository `priority=`, an `excludepkgs=`, a versionlock or a dependency dnf cannot
satisfy can keep an advisory's update off the host for good, and the update run
reports success either way. The host simply never receives the fix, and nothing
says so — the same class of silent failure this package exists to prevent, one
layer further down.

The check runs only after `dnf-automatic` has exited 0, set by the gate to download and
install every update of its `upgrade_type`. That run is the transaction check: an
advisory still listed by `--disableexcludes=all updateinfo list --updates --security`
afterwards is one dnf did not install, whatever kept it out, so no cause is
enumerated and no second transaction is resolved. `check-update` would not do: it
lists updates without resolving a transaction, and its exit 100 means any one is
listed. `--updates` lists only packages the sack offers, and `excludepkgs=` takes
packages out of the sack, hence `--disableexcludes=all`; versionlock filters only
while dnf resolves a transaction, which `updateinfo` does not. Every package row is
reported, as `ID (PACKAGE, PACKAGE)`: one advisory can cover several packages and only
some be kept out. It is one query under `dnf_query_timeout_seconds`; a listing that
fails is logged as an incomplete report, not read as "nothing outstanding".
Advisory IDs are matched by shape (`PREFIX-YEAR-NUMBER` as Oracle's `ELSA-2026-26533`,
`PREFIX-YEAR:NUMBER` as Red Hat's `RHSA-2020:3011`, either with an optional `-REVISION`
as Oracle's `ELSA-2026-60226-0`; EPEL's `FEDORA-EPEL-2024-bf31852fe0` has a dash-joined
prefix and a hexadecimal number), so a line of any other shape in the output is not
reported as an advisory; a package field of another shape reports the advisory with `?`.

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
# What applies that the last run did not install, and what keeps it out
dnf --disableexcludes=all updateinfo list --updates --security
dnf --assumeno --disableexcludes=all --setopt='*.priority=99' update --security
```

## Repository metadata is refreshed before every update

`dnf-automatic` installs from the metadata dnf has cached and fetches only what is older
than `metadata_expire` (48 hours by dnf's default). `dnf-makecache.timer`, where enabled,
refreshes it about every `metadata_timer_sync` (3 hours). An advisory published after the
last refresh waits for the next run, however often the run timer fires. `/var/log/dnf.log`
records which a run had, one line per repository: `using cache for` or `has expired and
will be refreshed`.

`run.sh` runs `dnf -q makecache --refresh` after the clock check and before the state file,
under `timeout` at `metadata_refresh_timeout_seconds` (default 1800, for a slow link). A refresh that fails or
runs out of time warns, the run continues from the cache as `dnf-automatic` alone would, and
the completion line adds `(metadata refresh failed, cached metadata used)`: "No updates
installed" then describes the cache, not the repositories. The step is always on.

`dnf-makecache.timer` is dnf's, enabled by the distribution preset, and the package neither
requires, checks nor disables it. After a run's refresh, `dnf makecache --timer`
(`update_cache` in `dnf/base.py`) fetches nothing still valid for `metadata_timer_sync`,
rebuilds the sack from the cache, and logs `will expire after N seconds`; `--refresh` does
not touch `last_makecache`, so the timer keeps its own cadence. It still serves every other
reader of the cache: interactive `dnf`, anything running `dnf -C`, and `needs-reboot.sh`
outside `run.sh`.

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
names. `grub_default_is_kernel_release` in `needs-reboot.sh` is the runtime check that
the default still advances — see [Kernel packages](#kernel-packages-the-running-family).

## Time synchronisation gate

The service unit carries `After=`/`Requires=time-sync.target` so rpm `INSTALLTIME`
stamps and the boot-time comparison inside `needs-restarting` both see a correct
clock. On UEK R8 `systemd-time-wait-sync.service` does not exist and nothing else is
ordered `Before=time-sync.target`, so that dependency is satisfied trivially and
means nothing on its own.

`chrony` ships `chrony-wait.service` — `chronyc waitsync`, ordered
`Before=time-sync.target` — disabled by default. `%post` enables it whenever the unit
exists. It is never disabled on erase: a synchronised
clock is not this package's to take away. `%post` does not start it for the current boot.

The unit ordering does not require a successful synchronisation: `time-sync.target` is
reached even when `chrony-wait.service` fails (systemd issue 4880). `run.sh` therefore
checks the clock itself before installing anything: `wait_for_clock_sync` runs
`chronyc waitsync` (every 10 s, remaining correction below 0.1 s) for at most
`clock_sync_timeout_seconds` (default 600) under `timeout`, since each request adds its own time to
the polling interval and the run is not yet supervised by the watchdog; a run whose clock
chronyd has not confirmed by then installs nothing and fails. The waiting query's output is
discarded, since a client stopped by `timeout` can lose what it buffered; the error carries the
last line of one more `chronyc waitsync`, bounded at 10 s, which says whether chronyd answered
at all and with which reference. A missing `chronyc` fails it too. `require_clock_sync = no`
turns the check off for a host without chrony. The check asks chronyd, not the kernel's
synchronised flag (`timedatectl`'s `NTPSynchronized`). On Linux chrony clears `STA_UNSYNC`
only with `rtcsync` (`sys_timex.c`, chrony 4.3), and the surveyed OL 9.8 aarch64 host, which
has no RTC, has `rtcsync` commented out; the surveyed RHEL 8.10 host sets it. The kernel flag
therefore does not tell whether chrony is synchronised; chronyd itself does. `tools/verify-reboot-protocol.sh` reports whether
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
  survive upgrades. rpm replaces an unedited config and keeps an edited one, writing the new
  file beside it as `.rpmnew`. An edited copy with a key this version does not read is
  invalid: every run fails, naming the line, until an operator replaces it, and
  `OnFailure=` reports it, since an unattended upgrade shows `%posttrans` output to nobody.
  `%posttrans` runs `check-config.sh`, which validates the file, names every error and the
  commands that keep a backup and install `.rpmnew` or the shipped copy in
  `/usr/share/dnf-automatic-reboot/` (not `%doc`, which `--excludedocs` drops), or lists
  the values that differ. Neither edits
  the file.
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
  version, or with an `/etc/dnf/automatic.conf` from which dnf-automatic would not
  download and install every update and leave the reboot to this package. The file is
  not parsed here: `AUTOMATIC_CONFIG_QUERY` in `run.sh` asks dnf-automatic's own
  loader (`dnf.automatic.main.AutomaticConfig`, run by `/usr/libexec/platform-python -I`)
  what it reads. The interpreter needs no `Requires`: EL8's `platform-python` runs dnf
  itself, and on OL 9.8 `python3` owns it, the package behind `/usr/bin/python3`, under
  which dnf-automatic runs. The gate requires `apply_updates` and `download_updates` true (with
  either off, dnf-automatic exits 0 having installed nothing), `upgrade_type` `default` or
  `security`, and `reboot` `never`, or absent from the loader, as on EL8. A file the loader
  cannot parse, or an answer of another shape, is refused. A comment after a value, a key
  outside `[commands]` or a later `[commands]` section, indented or not, therefore counts
  exactly as dnf-automatic counts it: `apply_updates = yes # comment` read as `False` on
  RHEL 8.10 (dnf 4.7) and OL 9.8 (dnf 4.14). The refusal names the four lines to set.
  `%pre` carries a copy of the query and of its answer's shape, and a test keeps them
  identical.
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
- `Requires: chrony` — `run.sh` runs `chronyc waitsync` before every update; `%pre` checks
  it too, for `--nodeps`. Installed does not mean running or synchronised, so the runtime
  check stays.
- `Requires: rpm-plugin-systemd-inhibit` — rpm's plugin holds a block-mode shutdown inhibitor
  for every transaction, one started by hand included, and `reboot-if-pending.sh` waits while
  one is held. dnf 4 takes none of its own. `%pre` checks it for `--nodeps`. On both surveyed
  hosts it is installed and loaded (`%{__transaction_systemd_inhibit}`), from AppStream on
  OL 9.8 and BaseOS on RHEL 8.10.
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

`newest_installed_kernel_release` sorts the module directory names with `sort -V`,
which is not rpm's comparison algorithm and ignores epoch. It orders real UEK and EL
release strings correctly (`4.10` above
`4.4` above `4.3.1`, covered by a test) and kernel packages do not carry an
epoch, so this is accurate in practice. Anything that gives kernels an epoch, or
a release string using rpm's `~`/`^` operators, needs `rpmdev-vercmp` instead.

## Open issues

1. **No RTC on the RPi4.** See [Root cause](#root-cause-of-every-false-positive-a-wrong-clock-at-boot).
   Fitting a DS3231 (or DS1307) on i2c removes the entire false-positive problem
   class and makes the build-id check and restart-state learning unnecessary. The
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

# Kernel default must match the newest installed kernel of the running family
grubby --default-kernel
rpm -ql "$(rpm -qf "/lib/modules/$(uname -r)/vmlinuz" --qf '%{NAME}\n')" \
  | sed -n 's#^/lib/modules/\([^/]*\)/vmlinuz$#\1#p' | sort -V | tail -1

# Validate the config; list what differs from the shipped one
/usr/libexec/dnf-automatic-reboot/check-config.sh

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
- Do not hardcode policy (timeouts, package names) in scripts — add the key to
  `CONFIG_SCHEMA` and the shipped config, and read it with `config_value`. Do not parse
  the config anywhere else, and do not let a doubtful value fall back to a default.
- Do not parse tool output with a blocklist of known-uninteresting lines, and do not
  fold stderr into a parsed stream. Match the shape you want and discard the rest.
- Do not treat an unverifiable state as a false positive. "Cannot tell" keeps the
  package and costs a reboot; the inverse leaves a host running vulnerable code.
- Do not call `systemctl` directly in RPM scriptlets — use the `%systemd_*` macros,
  except the two documented enablement cases.
- Do not downgrade `Requires: elfutils` to `Recommends` — `eu-readelf` is required for
  the build-id path.
- Do not add a package to `BUILD_ID_VERIFIED_PACKAGES` unless all of its code runs in
  binaries it owns: a library such as glibc runs inside other packages' processes, which
  the build-id check does not cover.
- Do not add a setting that turns off the kernel version check, the GRUB default check
  or a stall window, or accept compatibility aliases for keys of earlier versions. A new
  setting needs a reason an operator would change it and a range in which every value
  is safe; otherwise it is a constant.
- Do not let the watchdog reboot, or stop a run for its age: it stops a run that has
  stalled, and the next run decides the reboot.
- Do not key restart-state entries on package name alone — always name + EVR, so a
  genuine future update is never masked by an old confirmation.
- Do not match state-file rows with `grep` — use `awk -F'\t' '$1 == name'`, or
  `libglibc` matches a rule about `glibc`.
- Do not extend restart-state learning to `kernel*` packages — the version-string
  check is their sole, more authoritative, source of truth.
- Do not kill the run by PID — `systemctl kill` the whole unit, or
  `dnf-automatic` survives behind `systemd-inhibit`.
- Do not use `systemctl reboot --force`, nor `--check-inhibitors=yes`, which also refuses
  while another user is logged in. Reboot only through `reboot-if-pending.sh`, after
  `read_shutdown_block_state` reports `free`.
- Do not install anything under `/usr/local` from the RPM.
- Do not edit `/etc/dnf/automatic.conf` from a scriptlet, a script or the docs'
  commands. It belongs to the operator and may predate this package: check it and
  name the line to change.
- Do not use `return` at script top level — use `exit`.
- Do not use Unicode characters in scripts or config files.
- Do not abbreviate identifiers — see [Naming](#shell-scripts).
