# CLAUDE.md

## Project

`dnf-automatic-reboot` - unattended update + conditional reboot for Oracle Linux 9 /
RHEL 9, aarch64, UEK R8, RPi4. Shell scripts packaged as a noarch RPM.

## Platform constraints (always apply)

- **OS:** Oracle Linux 9 / RHEL 9 — `dnf`, `rpm`, `systemctl`. Never `yum`, never `apt`.
- **Kernel:** UEK R8 (6.12.x), aarch64. `systemd-time-wait-sync.service` is absent.
- **Init:** systemd. SELinux enforcing. Never `setenforce 0`.
- **Container runtime:** Podman (not Docker) if containers ever needed.
- **Shell:** bash with `set -euo pipefail` + `IFS=$'\n\t'` in every script.
- **Encoding:** ASCII only in scripts and config files. Unicode is fine in Markdown.
- **No RTC.** The RPi4 has no real-time clock. This is the root cause of the
  needs-restarting false positives — see [Root cause](#root-cause-of-every-false-positive-a-wrong-clock-at-boot).

## Repository layout

```
README.md                       Build + install guide (this repo)
CLAUDE.md                       This file
dnf-automatic-reboot.spec       RPM spec
Makefile                        check / install / dist / clean targets
conf/automatic-reboot.conf      Runtime config installed to /etc/dnf/
scripts/run.sh                  Main orchestration (inhibitor + dnf + reboot)
scripts/watchdog.sh             Independent watchdog (soft/hard timeout)
scripts/needs-reboot.sh         Reboot decision + false-positive filtering
scripts/notify-failure.sh       OnFailure= notifier (wall + log)
units/*.service *.timer         systemd unit files
tmpfiles/dnf-automatic-reboot.conf   Log + state path modes and labels
logrotate/dnf-automatic-reboot       Log rotation drop-in
doc/README                      Operational reference (installed to /usr/share/doc/)
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
/usr/lib/systemd/system/               unit files (incl. grub-boot-success.service)
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

log()      { printf '<6>%s: %s\n' "${SCRIPT_NAME}" "$*"; printf '%s %s: %s\n'          "$(date -Iseconds)" "${SCRIPT_NAME}" "$*" >> "${LOG_FILE}" 2>/dev/null || true; }
log_warn() { printf '<4>%s: %s\n' "${SCRIPT_NAME}" "$*"; printf '%s %s: WARNING: %s\n' "$(date -Iseconds)" "${SCRIPT_NAME}" "$*" >> "${LOG_FILE}" 2>/dev/null || true; }
log_err()  { printf '<3>%s: %s\n' "${SCRIPT_NAME}" "$*"; printf '%s %s: ERROR: %s\n'   "$(date -Iseconds)" "${SCRIPT_NAME}" "$*" >> "${LOG_FILE}" 2>/dev/null || true; }

# Config reader: conf_get KEY DEFAULT_VALUE
conf_get() {
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
- `conf_get_int` for any value that reaches an arithmetic test — a typo in the
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

New tests belong on decisions that are dangerous to get wrong — parsing that
could invent a package name, verification that could skip a needed reboot, a
watchdog path that could reboot a host mid-transaction — not on line coverage.

### Config file parsing

All tunables live in `conf/automatic-reboot.conf`. Scripts never have hardcoded
policy values — always `conf_get key default`. This keeps scripts testable without
installing the config. `conf_get` is section-blind: it matches `^\s*KEY\s*=` anywhere
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
| No owned running process, or unreadable build-id | Keep |
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

Code 2 does not reboot, to avoid a loop. `run.sh` escalates it to a non-zero exit so
`OnFailure=` fires and the fail-open is never silent.

### State file `/run/dnf-automatic-reboot.state`

Written by `run.sh`, consumed by `watchdog.sh`.

```
phase=updating|checking|failed
start=<unix timestamp>
pid=<PID of run.sh>
```

Watchdog decisions by phase:

| Phase | Soft timeout + dnf idle | Hard timeout |
|-------|------------------------|--------------|
| `updating` | Leave for hard timeout (unknown completion) | Kill cgroup + alert; reboot only if `force_reboot_on_hard_timeout=yes` |
| `checking` | Run independent needs-reboot check, kill cgroup | Kill cgroup + reboot (dnf already returned cleanly) |
| `failed` | Leave for operator | Kill cgroup + alert |

Killing always targets the whole service cgroup via
`systemctl kill --kill-whom=all`. `dnf-automatic` runs as a grandchild behind
`timeout(1)`, so signalling the recorded PID and its direct children leaves the rpm
transaction running while the caller proceeds to reboot.

At hard timeout in `phase=updating` an rpm transaction may be half-applied. That is
the same uncertainty for which the dead-PID path already refuses to reboot, so the
default is to kill and alert. `systemctl reboot` is preferred over `--force`, which
remounts filesystems read-only under running processes and risks the rootfs on a
flash-backed host.

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
has not become the running one. Cleared as soon as it does:

```
<name>\t<target_version>\t<attempt_count>
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
running the old image. `/proc/*/exe` targets are deduplicated before querying rpm, so
this costs one `rpm -qf` per distinct binary rather than one per process.
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
version-string check above remains their sole authority. Controlled by
`learn_false_positives` in `automatic-reboot.conf`.

## What `needs-restarting -r` does not cover

`-r` inspects the fixed package list above and nothing else — it never looks at
running processes. A security update to sshd, nginx, bind, or anything linking a
refreshed library patches the on-disk file and leaves the vulnerable image resident,
with no reboot flag raised.

`run.sh` closes this with a `needs-restarting -s` pass, which walks `/proc/*/smaps`
and names the affected systemd units. Units are restarted with `systemctl try-restart`
so a unit that is not running is left alone, and the pass is skipped entirely when a
reboot is already scheduled. `restart_services_exclude` holds the units that must
never be restarted from underneath a running system — `dbus`/`dbus-broker` break every
client holding a bus connection, `systemd-logind` drops session tracking, and the two
units of this package would kill the run. Extend that list, never shorten it.

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
Advisory IDs are matched by shape (`PREFIX-YEAR-NUMBER`), so nothing unexpected
in the output can be reported as an advisory.

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
boot. `/usr/lib/kernel/install.d/20-grub.install` only advances the GRUB
`saved_entry` when `DEFAULTKERNEL` (`/etc/sysconfig/kernel`) names the installed
package AND `GRUB_UPDATE_DEFAULT_KERNEL=true` (`/etc/default/grub`); neither is set
by default on UEK, so `kernel-install` silently never advances `saved_entry`.

Fixed at install time by the RPM `%post` scriptlet (not a per-update script, not
installed on the client):

- Sets `DEFAULTKERNEL=kernel-uek-core` and `GRUB_UPDATE_DEFAULT_KERNEL="true"` so
  every future kernel update advances `saved_entry` automatically.
- Repairs the current backlog with `grubby --set-default` pointing at the newest
  installed kernel.
- Enables `grub-boot-success.service`, which runs `grub2-set-bootflag boot_success`
  each boot so GRUB's indeterminate-boot fallback cannot revert `saved_entry`.

Scope is UEK-only and idempotent. `%post` acts only when the package owning the
running kernel (`rpm -qf /lib/modules/$(uname -r)/vmlinuz`) matches
`kernel_default_package`; on any other host it is a no-op and non-UEK kernels are
never touched. Behaviour is controlled by the `[kernel]` section of
`automatic-reboot.conf` (`manage_kernel_default`, `kernel_default_package`), which
`%post` reads with the same `conf_get` grep used by the scripts.
`grub-boot-success.service` ships on all hosts (noarch payload) but carries
`ConditionKernelVersion=*uek*` so it stays inert if ever present off UEK.

`verify_grub_default` in `needs-reboot.sh` is the runtime check that this
provisioning is still holding — see [Kernel packages](#kernel-packages-aarch64-and-x86_64).

## Time synchronisation gate

The service unit carries `After=`/`Requires=time-sync.target` so rpm `INSTALLTIME`
stamps and the boot-time comparison inside `needs-restarting` both see a correct
clock. On UEK R8 `systemd-time-wait-sync.service` does not exist and nothing else is
ordered `Before=time-sync.target`, so that dependency is satisfied trivially and
means nothing on its own.

`chrony` ships `chrony-wait.service` — `chronyc waitsync`, ordered
`Before=time-sync.target` — disabled by default. `%post` enables it when
`[time] enable_chrony_wait = yes`. It is never disabled on erase: a synchronised
clock is not this package's to take away.

`/etc/chrony.conf` needs `makestep 1 -1` so the clock is stepped rather than slewed
at boot. `rtcsync` is pointless on a host with no RTC and is not required.

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
  call `systemctl` directly in scriptlets. **Two deliberate exceptions**, both because
  per-host conditional enablement cannot be expressed via systemd presets:
  1. `grub-boot-success.service` must be enabled on UEK hosts only. `%post`/`%preun`
     `systemctl enable`/`disable` it directly inside the UEK guard. Do not "fix" this
     to a preset + macro — that would enable it on x86_64 too. The unit's
     `ConditionKernelVersion=*uek*` is the inert-everywhere-else backstop.
  2. `chrony-wait.service` belongs to the `chrony` package, so no preset of ours can
     reach it. `%post` enables it directly, guarded on `systemctl cat` finding the
     unit. It is never disabled on erase.
- `BuildArch: noarch` — shell scripts only, no compiled artifacts.
- `Requires: elfutils` — `eu-readelf` is required for the build-id check.
- `Requires: logrotate` — the drop-in in `/etc/logrotate.d` needs a consumer.
- `Requires: systemd >= 252` — `systemctl kill --kill-whom` is spelled
  `--kill-who` before that, and the watchdog depends on reaching the whole cgroup.
- `BuildRequires: make gawk util-linux` — `%check` runs `make check`, which needs
  `make`, `awk` and `flock`.
- Cleanup of paths owned by a *previous* version belongs in `%posttrans`. In
  `%post` the old package's files are still present, so the `rmdir` of the
  pre-1.3 `/usr/local/lib` directory always fails.
- Version bump: update both `Makefile` (`VERSION`) and `dnf-automatic-reboot.spec`
  (`Version:` + `%changelog`).

## Known limitations

`newest_installed_kernel_version` sorts with `sort -V` over
`%{VERSION}-%{RELEASE}.%{ARCH}`, which is not rpm's comparison algorithm and
ignores epoch. It orders real UEK and EL release strings correctly (`4.10` above
`4.4` above `4.3.1`, covered by a test) and kernel packages do not carry an
epoch, so this is accurate in practice. Anything that gives kernels an epoch, or
a release string using rpm's `~`/`^` operators, needs `rpmdev-vercmp` instead.

## Open issues

1. **No RTC on the RPi4.** See [Root cause](#root-cause-of-every-false-positive-a-wrong-clock-at-boot).
   Fitting a DS3231 removes the entire false-positive problem class and makes
   `filter_packages` and restart-state learning unnecessary.

2. **NTS TLS failures under FUTURE crypto policy** — two configured NTS sources
   (`paris.time.system76.com`, `sth2.nts.netnod.se`) fail certificate verification
   under OL9 FUTURE policy; both are currently commented out in `/etc/chrony.conf`.
   Workaround: `update-crypto-policies --set DEFAULT`. Proper fix: use sources whose
   chains are FUTURE-compatible, or `time.cloudflare.com` NTS which works under
   DEFAULT.

## Useful commands

```bash
# Syntax + lint before building
make check && shellcheck -S info scripts/*.sh

# Build RPM
make dist
rpmbuild -ba dnf-automatic-reboot.spec \
  --define "_sourcedir $(pwd)" \
  --define "_specdir $(pwd)"

# Test reboot logic without running dnf
/usr/libexec/dnf-automatic-reboot/needs-reboot.sh; echo "exit: $?"

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
- Do not hardcode policy (timeouts, package names) in scripts — use `conf_get`.
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
- Do not kill the run by PID — `systemctl kill --kill-whom=all` the unit, or
  `dnf-automatic` survives behind `timeout(1)`.
- Do not reach for `systemctl reboot --force` as the first option; it remounts
  filesystems read-only under running processes.
- Do not install anything under `/usr/local` from the RPM.
- Do not use `return` at script top level — use `exit`.
- Do not use Unicode characters in scripts or config files.
- Do not abbreviate identifiers — see [Naming](#shell-scripts).
