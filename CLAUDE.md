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
conf/dnf-automatic-reboot.conf  Runtime config installed to /etc/dnf/
scripts/run.sh                  Main orchestration (inhibitor + dnf + reboot)
scripts/watchdog.sh             Independent watchdog (soft/hard timeout)
scripts/needs-reboot.sh         Reboot decision + false-positive filtering
units/*.service *.timer         systemd unit files
doc/README                      Operational reference (installed to /usr/share/doc/)
```

## Installed paths (on target)

```
/usr/local/lib/dnf-automatic-reboot/   scripts/
/etc/dnf/dnf-automatic-reboot.conf     config (%config noreplace)
/usr/lib/systemd/system/               unit files
/usr/share/doc/dnf-automatic-reboot/   doc/README
/var/log/dnf-automatic-reboot.log      runtime log (%ghost in RPM)
```

## Coding conventions

### Shell scripts

```bash
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

readonly CONF=/etc/dnf/dnf-automatic-reboot.conf
readonly LOG=/var/log/dnf-automatic-reboot.log
readonly SELF=script-name   # used in log prefix

log() { echo "$(date -Iseconds) ${SELF}: $*" | tee -a "${LOG}"; }

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

All tunables live in `conf/dnf-automatic-reboot.conf`. Scripts never have hardcoded
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

### kernel-uek / kernel-uek-core (aarch64)

`needs-restarting` compares RPM EVR string against `uname -r` without normalising
the trailing `.aarch64` arch suffix. Cross-verification: strip `.aarch64` from RPM
output and `grep -F` against `uname -r`. Match = false positive. Mismatch = genuine.

### systemd (all)

`needs-restarting` uses `INSTALLTIME > boot_ts` for systemd. If systemd was updated
during a previous boot cycle, INSTALLTIME stays newer than all subsequent boot
timestamps permanently. Cross-verification: `eu-readelf -n /proc/1/exe` vs
`eu-readelf -n /usr/lib/systemd/systemd` — matching build-ids = false positive.
Requires `elfutils` (hard RPM dependency).

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
  call `systemctl` directly in scriptlets.
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
