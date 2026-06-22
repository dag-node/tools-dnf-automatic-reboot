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

## Repository layout

```
README.md                       Build + install guide (this repo)
CLAUDE.md                       This file
dnf-automatic-reboot.spec       RPM spec
Makefile                        build / install / dist / clean targets
conf/automatic-reboot.conf  Runtime config installed to /etc/dnf/
scripts/run.sh                  Main orchestration (inhibitor + dnf + reboot)
scripts/watchdog.sh             Independent watchdog (soft/hard timeout)
scripts/needs-reboot.sh         Reboot decision + false-positive filtering
units/*.service *.timer         systemd unit files
doc/README                      Operational reference (installed to /usr/share/doc/)
```

## Installed paths (on target)

```
/usr/local/lib/dnf-automatic-reboot/   scripts/
/etc/dnf/automatic-reboot.conf     config (%config noreplace)
/usr/lib/systemd/system/               unit files (incl. grub-boot-success.service)
/usr/share/doc/dnf-automatic-reboot/   doc/README
/var/log/dnf-automatic-reboot.log      runtime log (%ghost in RPM)
```

## Coding conventions

### Shell scripts

```bash
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

readonly CONF=/etc/dnf/automatic-reboot.conf
readonly LOG=/var/log/dnf-automatic-reboot.log
readonly SELF=script-name   # used in log prefix

log()      { printf '<6>%s: %s\n' "${SELF}" "$*"; printf '%s %s: %s\n'          "$(date -Iseconds)" "${SELF}" "$*" >> "${LOG}" 2>/dev/null || true; }
log_warn() { printf '<4>%s: %s\n' "${SELF}" "$*"; printf '%s %s: WARNING: %s\n' "$(date -Iseconds)" "${SELF}" "$*" >> "${LOG}" 2>/dev/null || true; }
log_err()  { printf '<3>%s: %s\n' "${SELF}" "$*"; printf '%s %s: ERROR: %s\n'   "$(date -Iseconds)" "${SELF}" "$*" >> "${LOG}" 2>/dev/null || true; }

# Config reader: conf_get KEY DEFAULT
conf_get() {
    local key="$1" default="$2" val
    val=$(grep -E "^\s*${key}\s*=" "${CONF}" 2>/dev/null \
          | tail -1 | sed 's/^[^=]*=\s*//' | sed 's/\s*#.*//') || true
    printf '%s' "${val:-${default}}"
}
```

- `readonly` for all constants; `local` for all function variables
- `[[ ]]` not `[ ]`
- Quote all variables: `"${VAR}"` not `$VAR`
- Save/restore `IFS` around comma-split loops: `OLD_IFS="${IFS}"; IFS=','; ...; IFS="${OLD_IFS}"`
- `|| true` on commands that are allowed to fail
- Never `return` at top level; use `exit`

### Config file parsing

All tunables live in `conf/automatic-reboot.conf`. Scripts never have hardcoded
policy values — always `conf_get key default`. This keeps scripts testable without
installing the config.

### Exit codes (needs-reboot.sh)

| Code | Meaning |
|------|---------|
| 0 | No reboot needed |
| 1 | Reboot needed |
| 2 | Tool error — treated as "no reboot" to avoid loops |

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
| `updating` | Leave for hard timeout (unknown completion) | Kill + force reboot |
| `checking` | Run independent needs-reboot check, kill PID | Kill + force reboot |
| `failed` | Leave for operator | Kill + force reboot |

## Known false positives (needs-reboot.sh handles automatically)

### Kernel packages (aarch64 and x86_64)

`needs-restarting` compares RPM EVR string against `uname -r` without normalising
the trailing `.<arch>` suffix. Cross-verification: strip `.$(uname -m)` from the
highest installed RPM EVR and `grep -F` against `uname -r`. Match = false positive.
Mismatch = genuine. Covers `kernel-uek`/`kernel-uek-core` (aarch64 UEK) and
`kernel`/`kernel-core` (x86_64 RHEL 8/9) with the same code path. Packages not
installed on the running system are skipped automatically.

### systemd (all)

`needs-restarting` uses `INSTALLTIME > boot_ts` for systemd. If systemd was updated
during a previous boot cycle, INSTALLTIME stays newer than all subsequent boot
timestamps permanently. Cross-verification: walk `/proc/*/exe`, find a process whose binary is owned
by the package (`rpm -qf`), compare ELF build-ids of the running process against
the on-disk binary via `eu-readelf` — matching build-ids = false positive.
Applies generically to any non-kernel package in `filter_packages`.
Requires `elfutils` (hard RPM dependency).

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

## SELinux rules

- Scripts at `/usr/local/lib/dnf-automatic-reboot/` inherit `bin_t` / `shell_exec_t`
  via `restorecon` called in `%post`.
- Config at `/etc/dnf/` inherits `etc_t`.
- Log at `/var/log/` inherits `var_log_t` via `%ghost` ownership.
- Never use `chcon` in scripts — use `restorecon` or `semanage fcontext`.
- If a new AVC denial appears: `ausearch -m avc -ts recent | audit2why` first.

## RPM packaging rules

- `%config(noreplace)` on the config file — local edits survive upgrades.
- `%ghost` on the log file — RPM owns the path and SELinux label without owning content.
- `%systemd_post` / `%systemd_preun` / `%systemd_postun_with_restart` macros — never
  call `systemctl` directly in scriptlets. **One deliberate exception:**
  `grub-boot-success.service` must be enabled on UEK hosts only, and per-host
  conditional enablement cannot be expressed via systemd presets. `%post`/`%preun`
  therefore `systemctl enable`/`disable` it directly inside the UEK guard. Do not
  "fix" this to a preset + macro — that would enable it on x86_64 too. The unit's
  `ConditionKernelVersion=*uek*` is the inert-everywhere-else backstop.
- `BuildArch: noarch` — shell scripts only, no compiled artifacts.
- `Requires: elfutils` — `eu-readelf` is required for the systemd build-id check.
- Version bump: update both `Makefile` (`VERSION`) and `dnf-automatic-reboot.spec`
  (`Version:` + `%changelog`).

## Open issues

1. **time-sync gate on UEK R8** — `systemd-time-wait-sync.service` is absent. Current
   `Requires=time-sync.target` is satisfied by `chronyd.service` start, not sync
   completion. A lightweight replacement one-shot unit that polls `chronyc tracking`
   is the intended fix.

2. **NTS TLS failures under FUTURE crypto policy** — two configured NTS sources
   (`paris.time.system76.com`, `sth2.nts.netnod.se`) fail certificate verification
   under OL9 FUTURE policy. Workaround: `update-crypto-policies --set DEFAULT`.
   Proper fix: replace those sources with ones whose chains are FUTURE-compatible,
   or use `time.cloudflare.com` NTS which works under DEFAULT.

## Useful commands

```bash
# Build RPM
make dist
rpmbuild -ba dnf-automatic-reboot.spec \
  --define "_sourcedir $(pwd)" \
  --define "_specdir $(pwd)"

# Test reboot logic without running dnf
/usr/local/lib/dnf-automatic-reboot/needs-reboot.sh; echo "exit: $?"

# Check inhibitor lock is held during a run
systemd-inhibit --list

# Check what satisfied time-sync.target
systemctl list-dependencies time-sync.target --reverse

# Decode RPM timestamps
date -d @$(rpm -q --qf '%{INSTALLTIME}' systemd)

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
- Do not call `systemctl` directly in RPM scriptlets — use the `%systemd_*` macros.
- Do not downgrade `Requires: elfutils` to `Recommends` — `eu-readelf` is required and absence exits with code 2.
- Do not filter a package in `filter_packages` without confirming the false positive
  with the build-id or version cross-check first.
- Do not use `return` at script top level — use `exit`.
- Do not use Unicode characters in scripts or config files.
