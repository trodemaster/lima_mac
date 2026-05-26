---
name: lima-mac
description: Techniques for managing, debugging, and inspecting Lima macOS VMs in this repo. Use when working with lima.yaml templates, VM builds, TCC databases, disk inspection, configure.sh provisioning, or any lima_mac VM lifecycle task.
---

# Lima macOS VM Management

## Overview

This repo manages Lima macOS guest VMs (`macos-26`, `macos-26-beta`, `macos-15`) used as GitHub Actions runners for blakeports CI. Key knowledge for debugging and maintaining these VMs.

---

## Disk Inspection Technique

When a VM is failing provisioning steps, inspect the disk image directly without starting the VM. The disk format is `asif` (Apple sparse copy-on-write), which **cannot** be attached with `hdiutil attach` — use `diskutil image attach` instead.

**Requires `dangerouslyDisableSandbox: true`** — the DiskArbitration framework is blocked by sandbox.

```bash
# 1. Stop the VM first (CI runners may be using it — check with limactl list)
limactl stop macos-26

# 2. Attach the disk image (requires dangerouslyDisableSandbox)
diskutil image attach ~/.lima/macos-26/disk

# 3. Mount the Data volume (noowners bypasses macOS ownership checks)
sudo mkdir -p /Volumes/Data
sudo mount -t apfs -o noowners /dev/diskXsY /Volumes/Data   # find diskXsY from diskutil output

# 4. Inspect contents
# ...see TCC DB, plist, and setup marker sections below...

# 5. Detach when done
sudo hdiutil detach /Volumes/Data
diskutil image detach ~/.lima/macos-26/disk
```

`diskutil image attach` output lists all partitions. Look for the `Apple_APFS` container, then use `diskutil apfs list` to find the Data volume device node.

---

## TCC Database Inspection

TCC (Transparency, Consent, Control) controls macOS privacy permissions. Lima pre-seeds entries via B2 disk patching before first boot.

### Database locations on mounted disk

```bash
# System TCC DB (root-owned services like sshd, guest-agent)
/Volumes/Data/Library/Application\ Support/com.apple.TCC/TCC.db

# User TCC DB (user-specific permissions)
/Volumes/Data/Users/<username>.guest/Library/Application\ Support/com.apple.TCC/TCC.db
```

### Query the DB

```bash
sqlite3 /Volumes/Data/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, client_type, auth_value, auth_reason FROM access ORDER BY service, client;"
```

### Schema interpretation

| Column | Meaning |
|--------|---------|
| `service` | TCC service, e.g. `kTCCServiceSystemPolicyAllFiles`, `kTCCServiceAccessibility`, `kTCCServiceAppleEvents` |
| `client` | Bundle ID (if `client_type=0`) or absolute path (if `client_type=1`) |
| `client_type` | 0 = bundle ID, 1 = absolute path |
| `auth_value` | 0 = deny, 2 = allow |
| `auth_reason` | 3 = user-set, 4 = admin/system, 9 = denied by policy |

### Expected system TCC entries (B2 disk patching)

```
kTCCServiceSystemPolicyAllFiles | com.openssh.sshd           | bundle | allow | 4
kTCCServiceSystemPolicyAllFiles | com.apple.lima.guest-agent | bundle | allow | 4
kTCCServiceAccessibility        | com.apple.Terminal         | bundle | allow | 4
kTCCServiceAccessibility        | /opt/local/bin/cliclick    | path   | allow | 4
```

**Important**: the `cliclick-accessibility` TCC preset was removed from B2 code. Templates must specify it via custom entry:
```yaml
- service: kTCCServiceAccessibility
  client: /opt/local/bin/cliclick
  clientType: path
  authValue: allow
```

### Checking for bad entries

User TCC DB DENY entries for `kTCCServiceAppleEvents` with `auth_reason=9` indicate macOS wrote them during a failed provisioning run. These appear when:
- The "Update Mac Automatically" dialog blocked Finder/Terminal at first boot
- `sshd-keygen-wrapper` tried to send Apple Events without permission

If you see these, the root cause is usually `suppressFirstLoginSetup` not being configured (see below).

---

## Plist Inspection

```bash
# SetupAssistant plist — controls whether macOS shows express settings dialog
plutil -p /Volumes/Data/Library/Preferences/com.apple.SetupAssistant.managed.plist
# or per-user:
plutil -p /Volumes/Data/Users/<user>.guest/Library/Preferences/com.apple.SetupAssistant.plist

# Expected post-B1 state:
# "MiniBuddyLaunchReason" => 0   (NOT 13 — 13 triggers the "Update Mac Automatically" dialog)
# "SkipExpressSettingsUpdating" => 1

# SoftwareUpdate prefs
plutil -p /Volumes/Data/Library/Preferences/com.apple.SoftwareUpdate.plist
# Expected: "ConfigDataInstall" => 0 (suppresses automatic config data installs)
```

### B1 setup markers on the disk

These files are written by Lima's `Patch()` function during `limactl create` (not at first boot):

```bash
ls /Volumes/Data/private/var/db/.AppleSetupDone     # should exist
ls /Volumes/Data/private/var/db/.skipbuddy           # should exist
ls /Volumes/Data/Library/LaunchDaemons/com.apple.Lima.SetupAssistant.plist  # launch daemon
plutil -p /Volumes/Data/Library/LaunchDaemons/com.apple.Lima.SetupAssistant.plist
```

The `disk.patched` sentinel on the **host** confirms B1+B2 ran:
```bash
cat ~/.lima/macos-26/disk.patched   # exists after successful limactl create
```

---

## suppressFirstLoginSetup — Critical Template Requirement

**All lima.yaml templates MUST have `suppressFirstLoginSetup: {}`** in `vmOpts.vz`. Without it:
1. macOS writes `MiniBuddyLaunchReason: 13` to SetupAssistant plist on first GUI login
2. "Update Mac Automatically" express settings dialog appears at first boot
3. Dialog blocks Finder/Terminal from responding to Apple Events
4. `configure.sh wallpaper` AppleEvent calls time out with `-1712`
5. macOS writes DENY entries to user TCC for `kTCCServiceAppleEvents`

Correct placement in `vmOpts.vz`:
```yaml
vmOpts:
  vz:
    diskImageFormat: "asif"
    rosetta:
      enabled: false
      binfmt: false
    suppressFirstLoginSetup: {}   # <-- REQUIRED, must not be omitted
    guestPatch:
        tccPermissions:
         - preset: sshd-full-disk-access
         - preset: lima-guestagent-full-disk-access
         - preset: terminal-accessibility
         - service: kTCCServiceAccessibility
           client: /opt/local/bin/cliclick
           clientType: path
           authValue: allow
```

This activates B1 fakecloudinit: cidata.go emits `suppress_first_login_setup: true` into user-data; fakecloudinit reads it and calls `suppressFirstLoginScreens()` from `createUser()` on first boot, writing the SetupAssistant plist with `MiniBuddyLaunchReason: 0`.

---

## Template vs Instance File Sync

There are two copies of each VM config:
- **Template** (source of truth): `/Users/blake/Developer/lima_mac/macos-26.yaml`
- **Instance copy** (live): `~/.lima/macos-26/lima.yaml`

When modifying templates, **also update the instance copy** or the running/next-start VM won't pick up the change. Lima reads from the instance copy.

Active instances: `macos-26`, `macos-15`, `macos-26-upstream`, `macos-26-beta`.

---

## Serial Log

```bash
# Last boot output — overwritten on each start
cat ~/.lima/macos-26/serialv.log

# Look for:
# - "suppressFirstLoginScreens" (B1 fakecloudinit ran)
# - "createUser: " (guest user creation)
# - Lima provision script output
# - "fakecloudinit" prefixed lines
```

---

## Build Flow (Makefile)

```
limactl create   → installs macOS IPSW + runs B1/B2 disk patch
limactl start    → first boot: fakecloudinit runs, Lima provision scripts run (configure.sh)
limactl stop
limactl start    → second boot (autologin now active)
os-update.sh     → applies macOS updates, reboots if needed
macports.sh      → installs Xcode CLT + MacPorts
autologin-reboot.sh → re-applies autologin if OS update cleared it
wait_mount       → waits for /Volumes/lima_mac virtiofs mount
configure.sh wallpaper  → sets wallpaper; requires Finder + Terminal Apple Events
configure.sh runner     → registers GitHub Actions runner
```

Key make targets: `build-26`, `clean-26`, `rebuild-26` (same pattern for `-26-beta` and `-15`).

---

## configure.sh Subcommands

| Invocation | What it does |
|-----------|-------------|
| `./configure.sh` (no arg) | Full first-boot: password, autologin, setup_assistant, screensaver, SSH keys, chezmoi |
| `./configure.sh wallpaper` | Desktop wallpaper (Finder AppleEvents), Terminal AppleEvents pre-approval |
| `./configure.sh runner` | GitHub Actions runner registration (needs `RUNNER_TOKEN`, `RUNNER_LABEL`) |
| `./configure.sh autologin` | Re-applies kcpassword + screensaver after OS upgrade clears autologin |

`configure.sh wallpaper` uses cliclick to click through TCC approval dialogs. It only works in a logged-in GUI session — don't call it over bare SSH without auto-login active and Dock running.

---

## Common Regressions from Patch Refactoring

When refactoring B1/B2 patches in `lima-devl`:

1. **`suppressFirstLoginSetup` not in templates** — most impactful regression; causes "Update Mac Automatically" dialog. Check all three template YAMLs and all instance copies.

2. **`cliclick-accessibility` preset removed** — Lima removed this preset from B2. Templates must use the custom entry form (path-based, not bundle-based). Verify with TCC DB inspection that `kTCCServiceAccessibility | /opt/local/bin/cliclick | type=1 | allow` is present.

3. **Instance copies out of sync** — after editing templates, instance copies in `~/.lima/*/lima.yaml` must be updated manually. The Makefile `rebuild-*` targets do a fresh `limactl create` from the template, but existing instances need manual updates.

4. **B2 TCC entries missing** — if `guestPatch.tccPermissions` section is malformed YAML or missing a required preset, Lima silently skips patching. Inspect system TCC DB after disk attach to confirm all 4 expected entries are present.

5. **`disk.patched` sentinel not created** — if `limactl create` exits with an error mid-way, the sentinel may not exist. The disk may be in a partially patched state. Best fix: `limactl remove -f macos-26` and rebuild.

---

## macports.sh — Known Gotchas

### `set -euo pipefail` + grep exit codes

`grep` returns exit code 1 when it finds no matches. Under `set -euo pipefail`, this kills the script immediately — even inside a variable assignment. The CLT retry loop looks like:

```bash
CMDLINE_TOOLS=$(softwareupdate -l 2>&1 | grep "\*.*Command Line" | ...) || true
```

The `|| true` is **required**. Without it, when softwareupdate hasn't listed CLT yet (returns no matching line), grep exits 1, the script dies, and the retry loop never runs. This was a regression introduced when retries were added without accounting for pipefail.

**Rule**: Any pipeline using `grep` (or `awk`, `sed`, etc.) that may produce no output needs `|| true` when assigned in pipefail scripts.

### softwareupdate timing after macOS installs

After a fresh macOS install or after `softwareupdate --install --all --restart` completes, the softwareupdate daemon can be locked by a post-install daemon for several minutes. During this window, `softwareupdate -l` prints an error like:

```
Scan finished with error: Error Domain=SUMacControllerError Code=7507 
"[SUMacControllerErrorAccessRequestDenied=7507] Access request was denied"
```

**This error is benign** — the download and install still proceed normally. The error is from the listing/scan phase being blocked by a concurrent process, but the actual install request goes through.

The retry loop in `macports.sh` uses 12 attempts × 60s (11 min total) to handle this window. If CLT isn't listed yet on the first attempt, it retries. If CLT is listed but the scan also emits the error, the install still works — `softwareupdate -i "$CMDLINE_TOOLS"` doesn't go through the blocked scan path.

### macOS OS update timing

A typical macOS minor update (e.g., 15.6.1 → 15.7.7) takes roughly 8 minutes to download + install + reboot. `os-update.sh` handles the full cycle:
1. Detects available updates via `softwareupdate -l`
2. Runs `softwareupdate --install --all --restart` (via expect for password)
3. Removes SSH service from bootstrap to force Lima to wait for VM to come back online
4. Waits 2 min then polls for SSH return (up to 15 min)
5. Marks autologin reboot needed

After the OS update, **autologin is cleared by macOS** — `autologin-reboot.sh` re-applies it via kcpassword + screensaver settings and reboots.

---

## Checking Build Progress

```bash
# Monitor a running background build
tail -f /tmp/rebuild-26.log   # or rebuild-15.log

# Screenshot the VM display to see GUI state
limactl screenshot macos-26 /tmp/vm-26.png && open /tmp/vm-26.png

# Check if specific provisioning markers exist in a running VM
limactl shell macos-26 -- ls /var/db/.AppleSetupDone /var/db/.skipbuddy 2>&1
limactl shell macos-26 -- defaults read /Library/Preferences/com.apple.SetupAssistant.managed 2>&1

# Check TCC entries in a running VM (requires Full Disk Access)
limactl shell macos-26 -- sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT service, client, client_type, auth_value FROM access ORDER BY service, client;"
```

---

## Wallpaper / AppleEvents Known Limitation

`configure.sh wallpaper` sets the user desktop wallpaper via `osascript → Finder set desktop picture`. This requires sshd to have `kTCCServiceAppleEvents → Finder` permission. Pre-seeding this in TCC.db via disk patching has been tried; tccd revokes it on first login regardless of `auth_reason`.

**Current behavior**: login window wallpaper succeeds (via `defaults`); user desktop wallpaper is attempted but may be skipped with WARN if AppleEvents times out. This is non-fatal — CI runs are not affected.

The cliclick-based approval in `configure.sh wallpaper` works when auto-login is active and Dock is running (i.e., after a complete build, at the wallpaper Makefile step).
