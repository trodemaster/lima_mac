# macOS VM Customization Boot Sequence

Empirical reference for the order of operations Lima uses to customize a macOS guest VM.
Captures observed timing, daemon behavior, and macOS-version constraints discovered
through instrumented builds and serialv.log analysis.

---

## The Three Phases

```
limactl create
  └─ Phase 0: Disk patch (host, pre-boot)
       ├─ B1: write setup markers, SA plist, SoftwareUpdate prefs
       └─ B2: write per-user TCC.db

limactl start  [Boot 1]
  └─ Phase 1: First boot (no GUI)
       ├─ fakecloudinit LaunchDaemon
       │    ├─ createUser (sysadminctl)
       │    ├─ suppressFirstLoginScreens
       │    └─ launch boot.sh
       └─ provision.user scripts (configure.sh)

limactl stop + start  [Boot 2]
  └─ Phase 2: First GUI session (autologin)
       ├─ opendirectoryd
       ├─ cfprefsd agent (user domain init)
       ├─ UAU / ISRootMigrator  [macOS 27+]
       ├─ mini-buddy (SetupAssistant)
       └─ provision.user scripts (configure.sh again)
```

---

## Phase 0: Disk Patching (pre-boot, host-side)

Runs inside `limactl create` via the `Patch()` function. Mounts the APFS Data volume
directly on the host and writes files with raw filesystem I/O — cfprefsd, launchd,
and opendirectoryd are **not running**.

### B1 patch writes (system-wide, owned root:wheel)

| Path | Purpose |
|------|---------|
| `/private/var/db/.AppleSetupDone` | Prevents macOS Setup Assistant from running at first boot |
| `/private/var/db/.skipbuddy` | Secondary SA skip marker |
| `/Library/Preferences/com.apple.SetupAssistant.managed.plist` | Managed SA policy; sets `SkipExpressSettingsUpdating=true` |
| `/Library/Preferences/com.apple.SoftwareUpdate.plist` | Pre-configures update policy |
| `/Library/LaunchDaemons/com.lima.fakecloudinit.plist` | Installs the fakecloudinit LaunchDaemon |
| `/Library/LaunchDaemons/com.lima.sa-preseed.plist` | Installs the sa-preseed LaunchDaemon |

**Constraint**: These writes bypass cfprefsd. macOS reads `/Library/Preferences/` files
directly for managed domains, so they survive the first boot intact.

### B2 patch writes (system TCC.db only)

| Path | Purpose |
|------|---------|
| `/Library/Application Support/com.apple.TCC/TCC.db` | Pre-seeds system-level TCC permissions (sshd full disk access, guestagent full disk access, Terminal accessibility) |

**Constraint**: Only the system TCC.db is written. Writing to the user TCC.db
(`~/Library/Application Support/com.apple.TCC/TCC.db`) via B2 disk patching is
**non-viable** — tccd recreates or overwrites the user TCC.db during the first GUI session,
discarding any pre-written entries. User-level TCC permissions must be granted via other
means (e.g., prompted and approved during provisioning, or via MDM profiles).

The user home directory tree does not exist at disk-patch time (the user account in
directory services does not yet exist — B2 only touches the filesystem).

### What disk patching cannot do

- Create user accounts in OpenDirectory (opendirectoryd not running)
- Write to the System volume (sealed, read-only)
- Interact with cfprefsd, launchd, or any running daemon

---

## Phase 1: Boot 1 (first boot, no GUI)

The VM boots, macOS initializes, and system LaunchDaemons start. No autologin is
configured yet — this boot is headless.

### Observed timeline (from serialv.log)

```
T+0s    kernel + launchd
T+~3s   opendirectoryd, cfprefsd daemon, sshd
T+~5s   com.lima.fakecloudinit LaunchDaemon starts
         → INFO: Executing command: [launchctl load -w /System/Library/LaunchDaemons/ssh.plist]
         → INFO: Executing command: [scutil --set LocalHostName ...]
         → INFO: Executing command: [systemsetup -settimezone ...]
         → INFO: Executing command: [/var/lib/cloud/scripts/per-boot/00-lima.boot.sh]
         → (boot.sh runs → calls provision.user scripts as the configured user)
T+~21s  configure.sh begins (provision.user/00000001)
```

### fakecloudinit key operations

1. **`createUser`** — checks OpenDirectory (`dscl . -read /Users/<name> RecordName`):
   - If user NOT found: creates via `sysadminctl -addUser`, then calls `suppressFirstLoginScreens`
   - If user FOUND (macOS 27+: may be pre-created by early-boot processes): calls `suppressFirstLoginScreens` anyway and returns

2. **`suppressFirstLoginScreens`** (runs as root, before any GUI session):
   - Creates `~/Library/Preferences/` dir, chowned to user UID
   - Writes `com.apple.SetupAssistant.plist` with all `DidSee*=true`, `MiniBuddyLaunchReason=0`
   - Runs `defaults write /Library/Preferences/.GlobalPreferences AppleLanguagesSchemaVersion -int 5400` (macOS 27+ only — see §cfprefsd below)
   - Runs `defaults write /Library/Preferences/com.apple.SoftwareUpdate` for each update key

3. **`boot.sh`** — runs provision.user scripts:
   - `configure.sh` (no args): sets password, autologin kcpassword, screensaver, SSH authorized_keys,
     and installs the suppress-setup-assistant LaunchAgent

### What works on Boot 1

- **Writing system preference files** via `defaults write /Library/Preferences/...` (root, goes to cfprefsd daemon — persists across boots)
- **Writing user home directory files** directly (`os.WriteFile`) when cfprefsd agent has never run for this user — **EXCEPT for plist files under `~/Library/Preferences/`** (see §cfprefsd)
- **sysadminctl user creation** — fully functional, opendirectoryd is running
- **launchctl** — fully functional

### What does NOT work on Boot 1

- **Direct writes to `~/Library/Preferences/*.plist`** for user-domain preferences (cfprefsd agent is not running, but on first GUI login cfprefsd agent rebuilds the user domain from its backing store, discarding any pre-written files)
- **`launchctl asuser <uid> ...`** — user bootstrap domain not established until first login
- **`sudo -u <user> defaults write NSGlobalDomain ...`** — without a user bootstrap, falls back to direct file write (same problem as above)

---

## Phase 2: Boot 2 (first GUI session, autologin)

After `configure.sh` on Boot 1 writes the autologin kcpassword, `limactl stop` then
`limactl start` triggers the first GUI session.

### Observed timeline (from serialv.log + plist birth times)

```
T+0s    kernel + launchd
T+~2s   opendirectoryd, cfprefsd DAEMON (system domain)
T+~5s   fakecloudinit LaunchDaemon starts
          → finds user already exists → calls suppressFirstLoginScreens
          → writes AppleLanguagesSchemaVersion=5400 to /Library/Preferences/.GlobalPreferences
T+~10s  autologin triggers GUI session for user blake
T+~11s  cfprefsd AGENT starts for blake
          → initializes user domain from daemon backing store (not from plist files)
          → com.apple.SetupAssistant plist: reads our written file (pre-existing on disk)
T+~12s  UAU (UserAccountUpdater) starts
          → runs ISRootMigrator plugin (macOS 27+)
          → reads AppleLanguagesSchemaVersion via NSUserDefaults
             • user domain: empty (fresh backing store)
             • system domain (/Library/Preferences/.GlobalPreferences): 5400  ← our write
          → 5400 ≥ threshold → skip Apple Account dialog
T+~13s  mini-buddy checks com.apple.SetupAssistant.plist
          → MiniBuddyLaunchReason=0 → no dialog
T+19s   fakecloudinit boot.sh → provision.user scripts (configure.sh runs again)
T+21s   configure.sh begins
T+7m    configure.sh writes AppleLanguagesSchemaVersion=5400 to user plist (redundant at this point)
```

### macOS 27 Boot 2 daemons (in order)

| Process | Role | Notes |
|---------|------|-------|
| `cfprefsd` (daemon) | System preference store | Starts before GUI; persists across boots |
| `fakecloudinit` | Lima setup LaunchDaemon | Writes AppleLanguagesSchemaVersion to system domain |
| `cfprefsd` (agent) | Per-user preference cache | Starts at user session; rebuilds from daemon store |
| `opendirectoryd` | Directory services | Running since before Boot 1 |
| `UserAccountUpdater` | Runs UAU plugins (incl. ISRootMigrator) | Reads prefs via cfprefsd agent |
| `ISRootMigrator` | UAU plugin (macOS 27+) | Reads AppleLanguagesSchemaVersion; triggers SA reason 13 if < 5400 |
| `mini-buddy` (SA) | Setup Assistant | Shows dialogs if MiniBuddyLaunchReason ≠ 0 |

---

## Post-DFU Restore Setup Chain (macOS 27+) {#post-dfu-chain}

After an IPSW restore via DFU (required for macOS 27 guest on macOS 26 host —
see [dfu-install.md](dfu-install.md)), macOS retains state indicating a software update
was installed. On every subsequent boot, this triggers a six-process chain ending
in Setup Assistant showing a "Software Update Complete" modal:

```
bootinstalld (root)
  → com.apple.MobileSoftwareUpdate.CleanupPreparePathService (root)
    → mbsystemadministration (root)
      → mbusertrampoline (root)
        → mbuseragent (blake, UID 501)
          → Setup Assistant -MiniBuddyYes (blake, UID 501)
```

### Why the chain cannot be stopped via launchctl

`launchctl disable system/com.apple.bootinstalld` writes to `disabled.plist` and
`launchctl print-disabled system` shows the service as disabled — but these are
**on-demand Mach/XPC services**. They still start when triggered via Mach IPC
regardless of the disabled flag. `launchctl bootout system/SERVICE` is blocked by
SIP (error 150).

### Why osascript cannot click Setup Assistant in this state

SA's "Software Update Complete" screen is a **blocking modal** that suspends the
process's Apple Events port. Any attempt to send Apple Events (including System Events
keystroke delivery) returns `-1712` (AppleEvent timed out) from any caller, regardless
of TCC permissions. The modal must be dismissed by something other than Apple Events.

### Managed plist approach (SkipSetupItems — preferred, no process killing)

macOS 15+ reads `SkipSetupItems` (string array) from
`/Library/Preferences/com.apple.SetupAssistant.managed.plist` before showing any
SA screen. This is the authoritative format; older per-screen boolean keys
(`SkipiCloudSetup`, etc.) are no longer sufficient on their own.

**What works (confirmed macOS 27 beta 26A5353q)**:

| SkipSetupItems value | Effect |
|---------------------|--------|
| `AppleID`           | Suppresses Apple Account sign-in as the *starting* SA screen |
| `Diagnostics`       | Suppresses analytics/diagnostics consent |
| `FileVault`         | Suppresses FileVault enable prompt |
| `Intelligence`      | Suppresses Apple Intelligence opt-in |
| `SoftwareUpdate`    | Suppresses software update check prompt |
| `Welcome`           | Suppresses initial welcome screen |

**What does NOT work (as of macOS 27 beta 26A5353q)**:

| Attempted value    | Expected effect | Actual result |
|-------------------|-----------------|---------------|
| `UpdateCompleted`  | Suppress "Software Update Complete" pane | No effect — pane still shows |

**Observed two-screen post-DFU SA flow**:

When the managed plist has `SkipSetupItems = [AppleID, ...]` but lacks a working
`UpdateCompleted` suppressor, the chain shows exactly two screens in sequence:

1. **"Software Update Complete"** — "Your Mac has been updated to macOS 27 Beta."
   Continue button. Not suppressible via known SkipSetupItems values.
2. **"Sign in to Your Apple Account"** — shown after user clicks Continue on screen 1.
   Not suppressed by `AppleID` when navigating forward from screen 1 (only suppressed
   as a starting screen).

**Confirmed one-time event**: The chain fires exactly once per DFU install.
After the user manually dismisses both screens, SA writes `LastSeenBuddyBuildVersion`
and sets `MiniBuddyShouldLaunchToResumeSetup = 0` in the user plist. On all
subsequent boots the chain is inert — `bootinstalld` remains registered as a
MachService but does not trigger SA again. Verified: stop/start after manual dismissal
produces a clean desktop with no SA dialogs.

**Workflow**: After a DFU install, on the first GUI login, manually click through
"Software Update Complete" → Continue → "Sign in to Your Apple Account" → skip.
All subsequent boots are clean. This is the accepted workaround for macOS 27 beta.

**Why `UpdateCompleted` via `defaults write` does not work**: Apple requires this
key to be delivered via a signed MDM configuration profile
(`com.apple.ManagedClient.preferences` payload with `Forced`/`mcx_preference_settings`
wrapper). A plain `defaults write` to the managed plist is insufficient for this
specific key. Without an MDM system, the "Software Update Complete" screen cannot
be suppressed programmatically.

The managed plist must be written **before the GUI session starts**. The
`com.lima.sa-preseed` root LaunchDaemon writes it on every boot to ensure it is
present before loginwindow autologins. `suppress_setup_assistant()` in `configure.sh`
also writes it on Boot 1 for Defense-in-depth.

```xml
<!-- /Library/Preferences/com.apple.SetupAssistant.managed.plist -->
<key>SkipSetupItems</key>
<array>
  <string>AppleID</string>
  <string>Diagnostics</string>
  <string>FileVault</string>
  <string>Intelligence</string>
  <string>SoftwareUpdate</string>
  <string>UpdateCompleted</string>
  <string>Welcome</string>
</array>
<key>MiniBuddyLaunchReason</key>
<integer>0</integer>
<key>SkipExpressSettingsUpdating</key>
<true/>
```

### Rejected approach: com.lima.kill-sa-chain root LaunchDaemon

A process-killing daemon (killed all six chain members every 0.2s) was implemented
and worked, but caused `WallpaperAgent` `EXC_BREAKPOINT` crashes via `lastLoginPanic`,
which then blocked autologin on subsequent boots. Removed in favor of the managed
plist approach.

---

## cfprefsd Behavior (Critical for macOS 27)

### Architecture

- **cfprefsd daemon** (root): manages the backing store for all preference domains. Starts early in boot and runs continuously. Writes are persisted to disk. `defaults write /Library/Preferences/<domain>` communicates with the daemon.
- **cfprefsd agent** (per-user): manages each user's preference cache. Starts when a user GUI session starts. Reads from the daemon backing store; writes go to daemon first, then to disk as `.plist` files.

### First-login user domain initialization (macOS 27)

When cfprefsd agent starts for a user that has never had a GUI session:
1. Checks daemon backing store for the user's preferences → initially empty
2. Does **NOT** read from `~/Library/Preferences/*.plist` as initial state
3. User domain starts empty; any plist files written directly by fakecloudinit are ignored

**Consequence**: `os.WriteFile` to `~/Library/Preferences/.GlobalPreferences.plist` on Boot 1
is silently discarded at Boot 2 session start. cfprefsd rebuilds from its own store.

### Why system domain works

`NSUserDefaults` (which ISRootMigrator uses) searches in order:
1. User domain (`~/Library/Preferences/`)
2. ByHost domain (`~/Library/Preferences/ByHost/`)
3. **System domain** (`/Library/Preferences/`) ← our write
4. Registration domain (in-memory defaults)

If the user domain is empty (first login), the system domain lookup succeeds. Our
`defaults write /Library/Preferences/.GlobalPreferences AppleLanguagesSchemaVersion -int 5400`
writes to the system domain via cfprefsd daemon — no user session required.

### Why Boot 3 would also work

After Boot 2, ISRootMigrator writes `AppleLanguagesSchemaVersion=5400` back to the user's
cfprefsd domain (via NSUserDefaults write). cfprefsd flushes to `~/Library/Preferences/.GlobalPreferences.plist`.
On Boot 3, cfprefsd agent starts and finds the value in its daemon backing store (persisted from Boot 2).

---

## BTM (Background Task Management) — macOS 27

BTM controls when third-party background tasks start. On macOS 27, BTM delays third-party
LaunchDaemons relative to system daemons.

**Observed**: `sa-preseed` LaunchDaemon runs ~1.5 seconds **after** ISRootMigrator.
Any LaunchDaemon intended to pre-seed preferences before ISRootMigrator reads them
cannot rely on the sa-preseed launch timing on macOS 27.

**fakecloudinit is not affected** because it is installed as a system LaunchDaemon in
`/Library/LaunchDaemons/` at disk-patch time (not registered through BTM's third-party path).

---

## ISRootMigrator (macOS 27+)

**Binary**: `/System/Library/UserAccountUpdater/ISRootMigrator.bundle`
**Plugin host**: `UserAccountUpdater`
**Trigger**: Runs at every first GUI session start for a user

**Behavior**:
```
read AppleLanguagesSchemaVersion from NSUserDefaults (NSGlobalDomain)
if value < 5400:
    set MiniBuddyLaunchReason = 13 in com.apple.SetupAssistant domain
    → Setup Assistant shows Apple Account / iCloud sign-in dialog
else:
    no-op
```

`5400` encodes the macOS 27.0 languages schema version. Any value ≥ 5400 skips the dialog.

**Key observation**: ISRootMigrator runs BEFORE `configure.sh` (which runs via provision.user,
delayed by BTM). Any fix via configure.sh is inherently too late on Boot 2.

---

## Preference Write Strategy by Phase

| Phase | Method | Works for user NSGlobalDomain? | Notes |
|-------|--------|-------------------------------|-------|
| Phase 0 (disk patch) | `os.WriteFile` to `~/Library/Preferences/` | No | cfprefsd agent rebuilds from daemon store on first login |
| Phase 1 Boot 1 | `os.WriteFile` to `~/Library/Preferences/` | No | Same — daemon store takes precedence |
| Phase 1 Boot 1 | `defaults write /Library/Preferences/<domain>` (root) | Yes (system domain) | Writes to cfprefsd daemon; NSUserDefaults falls through to system domain |
| Phase 1 Boot 1 | `defaults write NSGlobalDomain` (as user, no session) | No | Falls back to file write when no user bootstrap |
| Phase 2 Boot 2 | `defaults write NSGlobalDomain` (as user, during session) | Yes | User bootstrap active; goes through cfprefsd agent |
| Phase 2 Boot 2 | `configure.sh` / PlistBuddy | Yes (too late) | Runs after ISRootMigrator; fine for non-ISRootMigrator prefs |

---

## Setup Assistant (mini-buddy) Suppression

### Required files/keys

| Key | Location | Value | Purpose |
|-----|----------|-------|---------|
| `.AppleSetupDone` | `/private/var/db/` | file exists | Prevents SA from running at boot |
| `.skipbuddy` | `/private/var/db/` | file exists | Secondary SA skip |
| `SkipExpressSettingsUpdating` | `com.apple.SetupAssistant.managed` | `true` | Suppresses express settings pane |
| `MiniBuddyLaunchReason` | `com.apple.SetupAssistant` (per-user) | `0` | Must stay 0; ISRootMigrator sets it to 13 if it runs |
| `AppleLanguagesSchemaVersion` | `NSGlobalDomain` (system domain) | `5400` | Prevents ISRootMigrator from setting reason=13 (macOS 27+) |
| `SkipiCloudSetup` | `com.apple.SetupAssistant` (per-user) | `true` | Explicit skip for Apple Account/iCloud sign-in pane (macOS 27+). `DidSeeCloudSetup=true` alone is insufficient. |
| `SkipiCloudStorageSetup` | `com.apple.SetupAssistant` (per-user) | `true` | Explicit skip for iCloud Storage Services pane (macOS 27+) |
| `LastSeenGlassTintUpsellProductVersion` | `com.apple.SetupAssistant` (per-user) | productVersion | Glass Tint visual feature pane (macOS 27+) |
| `LastSeenIntelligenceProductVersion` | `com.apple.SetupAssistant` (per-user) | productVersion | Apple Intelligence pane — if absent, mini-buddy shows Apple Account sign-in as prerequisite (macOS 27+) |
| `LastSeenNewFeaturesProductVersion` | `com.apple.SetupAssistant` (per-user) | productVersion | What's New pane (macOS 27+) |
| `LastSeenSiriProductVersion` | `com.apple.SetupAssistant` (per-user) | productVersion | Siri updates pane (macOS 27+) |
| `LastSeenStorageServicesProductVersion` | `com.apple.SetupAssistant` (per-user) | productVersion | Storage Services pane (macOS 27+) |
| `LastSeeniCloudStorageServicesProductVersion` | `com.apple.SetupAssistant` (per-user) | productVersion | iCloud Storage Services pane — distinct from `LastSeenCloudProductVersion` (macOS 27+) |

### SA plist: managed vs per-user

`/Library/Preferences/com.apple.SetupAssistant.managed.plist` (system-wide, B1 writes this):
- Read by mini-buddy as a managed policy overlay
- Unaffected by per-user cfprefsd initialization
- Good for stable keys like `SkipExpressSettingsUpdating`

`~/Library/Preferences/com.apple.SetupAssistant.plist` (per-user, fakecloudinit writes this):
- Managed by cfprefsd agent
- On macOS 26: direct file write by fakecloudinit on Boot 1 is read correctly at Boot 2
- On macOS 27: must verify whether cfprefsd still reads this file or rebuilds from daemon store
- ISRootMigrator **overwrites** `MiniBuddyLaunchReason` to 13 in this domain if `AppleLanguagesSchemaVersion < 5400`

---

## TCC Notes (macOS 27+)

User TCC.db pre-seeding via B2 disk patching is **non-viable** on macOS 27 — tccd
overwrites the user database during the first GUI session. Any path-based custom TCC entries
(e.g., `kTCCServiceAccessibility` for `/opt/local/bin/cliclick`, `kTCCServiceAppleEvents`
for `/bin/sh`) written at disk-patch time will not survive to the first login.

The viable B2 TCC entries are preset-based writes to the **system** TCC.db:

| Preset / Entry | DB | Purpose |
|---|---|---|
| `sshd-full-disk-access` | system | sshd can read any file |
| `lima-guestagent-full-disk-access` | system | guest agent can read any file |
| `terminal-accessibility` | system | Terminal can control accessibility (for configure.sh wallpaper step) |

---

## macOS Version Differences

| Feature | macOS 15 | macOS 26 | macOS 27 |
|---------|-----------|----------|----------|
| ISRootMigrator | No | No | Yes |
| BTM delays LaunchDaemons | No | No | Yes (observed for sa-preseed) |
| cfprefsd rebuilds user domain from daemon store on first login | Unknown | No (file write works) | Yes |
| `AppleLanguagesSchemaVersion` needed in system domain | No | No | Yes (5400) |
| `SkipiCloudSetup` / `SkipiCloudStorageSetup` needed | No | No | Yes — `DidSeeCloudSetup=true` alone insufficient |
| New `LastSeen*ProductVersion` panes (Intelligence, NewFeatures, GlassTint, Siri, StorageServices) | No | No | Yes — absence triggers Apple Account dialog as Intelligence prerequisite |
| DFU install required (host < guest) | No | No | Yes (VZMacOSInstaller broken) |
| Post-DFU bootinstalld chain → SA "Software Update Complete" | No | No | Yes — observed; mitigation TBD |
| `_setForceDFU:` / `set_ForceDFU:` API | N/A | N/A | Required; try `_setForceDFU:` first, fall back to KVC `set_ForceDFU:` |
| User TCC.db B2 pre-seeding viable | Unknown | Yes | No — tccd overwrites on first GUI session |

---

## Empirical Evidence Used to Build This Document

All observations from macOS 27 Beta (`26A5353q`) on Apple Silicon VM:

- `serialv.log` timestamps (fakecloudinit runs at T+5s, provision.user at T+19s)
- APFS birth times via `GetFileInfo` or `stat -f %SB`:
  - `/etc/kcpassword` born `13:00:04` → Boot 1 configure.sh ran at T+21s from boot start
  - `com.apple.SetupAssistant.plist` born `13:00:48` → SA ran (not fakecloudinit) — confirms `suppressFirstLoginScreens` was not called or files were overwritten
  - `.GlobalPreferences.plist` born `13:07:22` → configure.sh PlistBuddy "Add" created the file; cfprefsd had not written it yet
- `dscl . -read /Users/blake RecordName` → exit 0 on Boot 2 → user exists in directory services after Boot 1
- Absence of `Executing command: /usr/sbin/sysadminctl -addUser` in Boot 2 serialv.log → `createUser` skipped on Boot 2
- `com.apple.UserAccountUpdater.plist` born `13:00:22` → UAU started at ~T+12s of Boot 2 session
- Post-DFU chain observed on Boot 2/3: bootinstalld, CleanupPreparePathService, mbsystemadministration (root), mbuseragent, Setup Assistant (blake) all visible in `ps aux`
- `launchctl print-disabled system | grep bootinstalld` → shows `disabled` yet process still runs (on-demand Mach IPC activation bypasses disabled flag)
- SA `-1712` AppleEvent timeout: confirmed from both osascript output and lima runner logs; SA's modal "Software Update Complete" state suspends the Apple Events port
- kill-sa-chain v2 verified clean on Boot 4 and Boot 5 from a fresh `make rebuild-27-beta`
