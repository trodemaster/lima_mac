# TCC Database — Learnings and Approaches

> **See also:** `MACOS_SECURITY.md` — consolidated reference for all macOS guest security/privacy constraints, ruling-out rationale, and csreq blob details. `tcc-capture/capture.sh` — script for offline TCC state collection from a stopped VM.

macOS Transparency, Consent, and Control (TCC) controls which processes can send Apple Events to other apps, access the camera, microphone, Contacts, etc. For Lima VMs, the critical permission is allowing the SSH daemon to control Finder via AppleScript, which enables headless wallpaper setting.

## Current Focus: Suppress the AppleEvents Dialog at Build Time

**Problem:** `configure.sh wallpaper` runs `osascript` via `sudo launchctl asuser 501`. macOS sees the requesting process as `/usr/libexec/sshd-keygen-wrapper` and shows a dialog:

> "sshd-keygen-wrapper" wants access to control "Finder". Allowing control will provide access to documents and data in "Finder", and to perform actions within that app.

Without a pre-existing TCC entry, the script either blocks on the dialog or times out:
```
33:48: execution error: Finder got an error: AppleEvent timed out. (-1712)
```

**Solution:** Inject the entry into the **system TCC.db** during Lima's disk patching step (`limactl create`), before the VM is ever booted.

### Which database: system vs user

| Database | Path on mounted Data volume | Use for patching? |
|---|---|---|
| System | `Library/Application Support/com.apple.TCC/TCC.db` | **Yes** — exists before first boot, applies to all users, no username needed |
| User | `Users/<username>/Library/Application Support/com.apple.TCC/TCC.db` | No — doesn't exist until user first logs in |

System TCC entries suppress the consent dialog for all users (same mechanism used by MDM/Jamf Privacy Preferences Policy Control profiles). `auth_reason=4` (system policy) is correct for system-level grants.

### Exact entry to inject into the system TCC.db

**Target path on mounted Data volume:**
```
Library/Application Support/com.apple.TCC/TCC.db
```

**Schema (create table if it does not exist):**
```sql
CREATE TABLE IF NOT EXISTS access (
  service                        TEXT NOT NULL,
  client                         TEXT NOT NULL,
  client_type                    INTEGER NOT NULL,
  auth_value                     INTEGER NOT NULL,
  auth_reason                    INTEGER NOT NULL,
  auth_version                   INTEGER NOT NULL,
  csreq                          BLOB,
  policy_id                      INTEGER,
  indirect_object_identifier_type INTEGER,
  indirect_object_identifier     TEXT NOT NULL DEFAULT 'UNUSED',
  indirect_object_code_identity  BLOB,
  flags                          INTEGER,
  last_modified                  INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
  pid                            INTEGER,
  pid_version                    INTEGER,
  boot_uuid                      TEXT NOT NULL DEFAULT 'UNUSED',
  last_reminded                  INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
  PRIMARY KEY (service, client, client_type, indirect_object_identifier)
);
```

**Row to insert — exact values read from macos-15 user TCC.db after manual dialog approval:**
```sql
INSERT OR REPLACE INTO access
  (service, client, client_type, auth_value, auth_reason, auth_version,
   csreq, indirect_object_identifier_type, indirect_object_identifier,
   flags, last_modified, boot_uuid, last_reminded)
VALUES
  ('kTCCServiceAppleEvents',
   '/usr/libexec/sshd-keygen-wrapper', 1, 2, 4, 1,
   X'FADE0C000000003C0000000100000006000000020000001D636F6D2E6170706C652E737368642D6B657967656E2D7772617070657200000000000003',
   0, 'com.apple.finder',
   NULL, CAST(strftime('%s','now') AS INTEGER), 'UNUSED',
   CAST(strftime('%s','now') AS INTEGER));
```

Notes:
- `policy_id` and `flags` were both **NULL** in the actual row macOS wrote.
- `indirect_object_code_identity` is **NON-NULL** in genuine consent rows — it encodes the Finder code signing requirement (see dev.9 post-mortem below). The INSERT above omits it, matching the dev.9 attempt which failed.
- `auth_reason=4` (system policy) is used here for the system TCC.db. The original user-consent row had `auth_reason=3`.

**Proposed dev.10 INSERT — includes `indirect_object_code_identity`:**
```sql
INSERT OR REPLACE INTO access
  (service, client, client_type, auth_value, auth_reason, auth_version,
   csreq, indirect_object_identifier_type, indirect_object_identifier,
   indirect_object_code_identity,
   flags, last_modified, boot_uuid, last_reminded)
VALUES
  ('kTCCServiceAppleEvents',
   '/usr/libexec/sshd-keygen-wrapper', 1, 2, 4, 1,
   X'FADE0C000000003C0000000100000006000000020000001D636F6D2E6170706C652E737368642D6B657967656E2D7772617070657200000000000003',
   0, 'com.apple.finder',
   X'FADE0C000000002C00000001000000060000000200000010636F6D2E6170706C652E66696E64657200000003',
   NULL, CAST(strftime('%s','now') AS INTEGER), 'UNUSED',
   CAST(strftime('%s','now') AS INTEGER));
```

**Raw output from offline sqlite3 read (ground truth — macos-15, macOS 15.7.7, after manual Allow click):**
```
service:                         kTCCServiceAppleEvents
client:                          /usr/libexec/sshd-keygen-wrapper
client_type:                     1
auth_value:                      2
auth_reason:                     3   ← user consent (dialog approval); use 4 for system TCC.db
auth_version:                    1
csreq (hex):                     FADE0C000000003C0000000100000006000000020000001D636F6D2E6170706C652E737368642D6B657967656E2D7772617070657200000000000003
policy_id:                       NULL
indirect_object_identifier_type: 0
indirect_object_identifier:      com.apple.finder
indirect_object_code_identity:   FADE0C000000002C00000001000000060000000200000010636F6D2E6170706C652E66696E64657200000003
                                 (encodes: identifier "com.apple.finder" and anchor apple)
                                 opcode 0x03 = opAppleAnchor = "anchor apple" (not "anchor apple generic" which is 0x0F)
flags:                           NULL
last_modified:                   1779036847
boot_uuid:                       UNUSED
last_reminded:                   1779036847
```

**File permissions after writing:**
```
owner: root:wheel
mode:  0644   (matches existing system TCC.db permissions on a stock macOS install)
```

**csreq blob is stable across macOS versions** — it encodes `identifier "com.apple.sshd-keygen-wrapper" and anchor apple` (opcode `0x03`, not `0x0F`), not a binary hash. The value from macOS 15.7.7 is valid for macOS 26.

---

## Iteration History and Test Results

### dev.6 — Initial implementation (user DB, auth_reason=4)
Both `terminal-apple-events` and `sshd-apple-events-finder` presets wrote to the **per-user** TCC DB (`Users/blake.guest/Library/Application Support/com.apple.TCC/TCC.db`) with `auth_reason=4`. tccd revoked both entries at first login: `auth_value` was overwritten to `0` and `auth_reason` to `9` (revoked). TCC consent dialog appeared.

### dev.7–dev.8 — Switched to auth_reason=3 (user DB still)
Changed both AppleEvents presets to `auth_reason=3` ("user-set", mimicking dialog approval) while keeping them in the per-user DB. tccd **still revoked** both entries at first login. TCC consent dialog appeared (confirmed by screenshot: "Terminal wants access to control System Events"). Conclusion: tccd revokes any externally-written per-user AppleEvents entries regardless of auth_reason.

### dev.9 — Moved to system DB, auth_reason=4, NULL receiver csreq (FAILED — definitive)

**What changed:**
- Both `terminal-apple-events` (Terminal→System Events) and `sshd-apple-events-finder` (sshd→Finder) moved to the **system** TCC DB with `auth_reason=4` (system policy) and NULL receiver csreq, matching actual user-approved entry structure.
- Rationale: MDM/Jamf PPPC profiles grant AppleEvents via the system DB with auth_reason=4.

**Results (macOS 15, macos-15 VM config, tested 2026-05-16):**

Offline check after first boot:
- **System TCC.db**: `kTCCServiceAppleEvents` entries **absent**. `kTCCServiceDeveloperTool` and `kTCCServiceSystemPolicyAllFiles` entries present with auth_value=2.
- **User TCC.db**: `auth_value=0, auth_reason=9` for AppleEvents — a deny record tccd created when it processed the AppleEvents grant.

Wallpaper step result: `execution error: Finder got an error: AppleEvent timed out. (-1712)` — unchanged.

**Correct analysis:**

The Lima code IS writing to the system DB correctly. The proof: `kTCCServiceSystemPolicyAllFiles` (from the `sshd-full-disk-access` preset) survived in the same system DB, confirming all five presets were written. tccd specifically **deleted** `kTCCServiceAppleEvents` entries from the system DB while leaving all other services intact. This is not a code routing bug — it is tccd's intentional, service-specific treatment of AppleEvents.

**Post-mortem (2026-05-17):**

Offline diff between a genuine user-consent entry and the Lima-written entry revealed **one byte-level difference**: `indirect_object_code_identity` was NULL in Lima's row but carried the Finder csreq blob (`FADE0C…com.apple.finder…00000003`) in the genuine entry. All other columns (pid, pid_version, flags, policy_id, boot_uuid) matched. No REG.db in the pre-boot Lima capture; REG.db appeared in the genuine capture only after first boot (likely written by tccd during init, not a prerequisite). See `tcc-capture/DIFF.md` for the full annotated diff.

**dev.10 fix:** Added `csreqFinder` and `csreqSystemEvents` blobs to `tcc_darwin.go` and wired them into both AppleEvents presets via `indirectObjectCodeIdentity`. Commit `f0ad4f8d`, version `2.1.0-dev.10`.

### dev.10 — System DB, auth_reason=4, with receiver csreq (FAILED — 2026-05-17)

**What changed:**
- Both AppleEvents presets now populate `indirect_object_code_identity` with the receiver's code-signing requirement (Finder and System Events respectively).
- All other fields unchanged from dev.9.

**Blobs added:**
```
csreqFinder        = fade0c000000002c...com.apple.finder...00000003
csreqSystemEvents  = fade0c000000003400...com.apple.systemevents...00000003
```

**Result:** TCC consent dialog still appeared at first login ("sshd-keygen-wrapper" wants access to control "Finder" — confirmed by screenshot). `indirect_object_code_identity` is **not** the discriminator tccd uses to reject externally-written AppleEvents entries.

**Conclusion:** All byte-level fields that differ between a genuine consent entry and Lima's pre-seeded entry have now been tested exhaustively (user DB vs system DB, auth_reason=3 vs 4, NULL vs non-NULL `indirect_object_code_identity`). None survive. tccd's rejection of pre-seeded `kTCCServiceAppleEvents` entries is unconditional — it uses a trust channel completely separate from the TCC.db row contents. **Disk-patching this service is definitively impossible on macOS 14+.**

Remaining options: Option A (AX auto-approve via Accessibility API) or Option C (desktoppicture.db, wallpaper-only workaround).

### dev.11 — cliclick auto-approver with Accessibility (PARTIALLY FAILED — root cause found, 2026-05-17)

**What changed:**
- Added `cliclick-accessibility` Lima preset (`kTCCServiceAccessibility` for `/opt/local/bin/cliclick`, NULL csreq, system DB)
- macports.sh installs cliclick via `sudo port install cliclick`
- `configure.sh wallpaper` launches a background watcher via `sudo launchctl asuser 501` that presses Return via cliclick when `UserNotificationCenter` is detected

**Offline pre-boot check:** cliclick-accessibility entry confirmed written correctly in system DB (auth_value=2, auth_reason=4). Accessibility entries survive — same as Terminal's entry.

**Result:** Wallpaper step still failed with `AppleEvent timed out. (-1712)`. No TCC dialog appeared.

**Root cause found — the pre-seeded AppleEvents entries are the problem:**

Offline inspection of user DB after first boot:
```
service: kTCCServiceAppleEvents
client:  /usr/libexec/sshd-keygen-wrapper
auth_value: 0    ← DENY
auth_reason: 9   ← revoked by tccd at first boot
```

tccd writes this deny record when it processes the pre-seeded system DB AppleEvents entry at first boot (on macOS 26, it keeps the system DB entry but overrides it with a user DB deny; on macOS 15, it deletes the system DB entry and writes the deny). The user DB deny takes precedence — tccd silently denies all subsequent AppleEvents requests from sshd-keygen-wrapper **without showing any dialog**. cliclick never gets a dialog to approve.

**Fix:** Remove `terminal-apple-events` and `sshd-apple-events-finder` from YAML `tccPermissions`. Without a pre-seeded entry, tccd writes no deny at first boot. The first time `configure.sh wallpaper` runs osascript, tccd has no cached decision → shows dialog → cliclick auto-approves → tccd writes a genuine `auth_reason=3` allow entry that persists.

YAML files updated: `terminal-apple-events` and `sshd-apple-events-finder` presets removed from all three YAML files. Testing pending with fresh `make rebuild-26`.

### dev.9 Post-mortem — Genuine vs Lima Field Diff (2026-05-17)

A byte-level comparison was performed between a genuine user-consent entry (user clicked Allow on sshd-keygen-wrapper → Finder dialog, macos-15-genuine) and Lima's disk-patched entry (macos-15-lima, pre-boot snapshot). See `docs/tcc-capture/DIFF.md` for the full annotated diff.

**Key finding: `indirect_object_code_identity` is NULL in Lima's entry but NON-NULL in the genuine entry.**

All other row-level fields match (csreq blob, auth_version, policy_id, flags, pid, pid_version, boot_uuid) or are irrelevant (timestamps). The only byte-level difference inside the row is:

| Field | Genuine | Lima |
|---|---|---|
| `indirect_object_code_identity` | **Non-NULL blob** — Finder csreq: `identifier "com.apple.finder" and anchor apple generic` | **NULL** |
| `auth_reason` | `3` (user consent) | `4` (system policy) |
| Which DB | User DB | System DB |

**Finder csreq blob (hex):**
```
FADE0C000000002C00000001000000060000000200000010636F6D2E6170706C652E66696E64657200000003
```

**Sidecar difference:** `REG.db` exists in the genuine system TCC directory after first boot (schema: `admin` key-value + `registry` abs_path trust table). Lima pre-boot has no `REG.db`. This is likely written by tccd on first start and is a consequence of boot, not a prerequisite.

**Working hypothesis for dev.10:** tccd rejects externally-written AppleEvents entries that have a NULL `indirect_object_code_identity`. Adding the Finder csreq blob to the Lima INSERT may allow the entry to survive. If tccd validates the receiver's code identity against the live Finder process, this fix would work — but if tccd uses a completely separate trust channel (not the DB) to validate AppleEvents grants, no disk-patch fix is possible regardless.

## Approaches Still to Investigate

### Option A — Accessibility-bootstrap auto-approval (most promising, no MDM)

**Insight**: Terminal already has `kTCCServiceAccessibility` pre-granted (system DB, survives — confirmed in dev.9). Accessibility access allows an app to drive any UI element via the AX API, including clicking buttons in system dialogs. The TCC consent dialog is a standard Cocoa window.

**Mechanism**: Write a small Swift CLI (`lima-tcc-approve`) compiled into Lima that:
1. Uses `AXUIElementCreateApplication` + `AXUIElementCopyAttributeValue` to locate the TCC consent dialog (in the `UserNotificationCenter` or `tccd` process)
2. Uses `AXUIElementPerformAction(AXPress)` to click the "Allow" button

The tool runs using Terminal's Accessibility permission — it does NOT need AppleEvents. This is raw AX API access, completely separate from `kTCCServiceAppleEvents`.

**First-boot flow:**
1. Lima disk patching writes `terminal-accessibility` preset (system DB, confirmed to survive)
2. At first login, a LaunchAgent (user-level) starts `lima-tcc-approve` in the background
3. `lima-tcc-approve` polls for a TCC consent dialog window using AX APIs
4. Another process (e.g., a `.command` file or the LaunchAgent itself) triggers `osascript -e 'tell application "System Events"...'` to force the TCC dialog to appear
5. `lima-tcc-approve` clicks Allow — tccd records a **genuine** user-consent entry (auth_reason=3, written by tccd itself)
6. The entry persists because tccd wrote it, not Lima
7. `lima-tcc-approve` and the LaunchAgent exit; they are never needed again

**Why AX doesn't need System Events**: `kTCCServiceAccessibility` is for the raw AX API (process inspection, button clicks via AXUIElement). `kTCCServiceAppleEvents → System Events` is for sending Apple Events to the System Events process. These are orthogonal — Terminal has the former, which is sufficient to click a dialog button directly.

**Implementation cost**: One Swift file (~60 lines), compiled as part of the Lima guest agent build. Bundled into the cidata volume like `lima-guestagent`. A new LaunchAgent plist triggers it at first user login; the plist is written during disk patching alongside the existing LaunchDaemon.

### Option B — PPPC `.mobileconfig` profile injection

MDM PPPC profiles work through a **separate trust channel** from TCC.db — `profilesd` translates them into policy entries that tccd trusts because they came from MDM, not from direct DB writes. Lima VMs are not MDM-enrolled, so unsigned profiles require user interaction on macOS 14+. However, during the LaunchDaemon first-boot window (pre-user-session, root context), `profiles install -path <file>` behavior may differ from the normal user-session case — this is untested.

**To test**: During disk patching, write a signed (or unsigned) PPPC `.mobileconfig` to `/Library/Application Support/lima-vm.mobileconfig`. In `lima-macos-init.sh`, run `profiles install -path /Library/Application\ Support/lima-vm.mobileconfig`. Check if the profile installs silently.

PPPC payload key for Terminal → System Events:
```xml
<key>com.apple.TCC.configuration-profile-policy</key>
<dict>
    <key>Services</key>
    <dict>
        <key>AppleEvents</key>
        <array>
            <dict>
                <key>Allowed</key><true/>
                <key>Identifier</key><string>com.apple.Terminal</string>
                <key>IdentifierType</key><string>bundleID</string>
                <key>CodeRequirement</key>
                <string>identifier "com.apple.Terminal" and anchor apple</string>
                <key>AEReceiverIdentifier</key><string>com.apple.systemevents</string>
                <key>AEReceiverIdentifierType</key><string>bundleID</string>
                <key>AEReceiverCodeRequirement</key>
                <string>identifier "com.apple.systemevents" and anchor apple</string>
            </dict>
        </array>
    </dict>
</dict>
```

Unsigned profiles almost certainly require user interaction in System Settings on macOS 14+. Likely dead end without MDM enrollment.

### Option C — Wallpaper without AppleEvents (quick workaround for specific case)

The wallpaper use case can bypass TCC entirely using sqlite3:

```bash
DB="$HOME/Library/Application Support/Dock/desktoppicture.db"
WALLPAPER="/System/Library/Desktop Pictures/Solid Colors/Space Gray Pro.png"
sqlite3 "$DB" "UPDATE data SET value = '$WALLPAPER';"
killall Dock
```

This works from SSH without any TCC permission. It does not address the broader need for SSH-based UI automation via osascript.

---

## Fundamental Constraint: TCC.db Cannot Be Modified from a Running VM

**macOS blocks all direct access to TCC databases from any process — including root — when the system is booted.** The kernel enforces this via a SQLite authorization callback (`SQLITE_AUTH`) regardless of process privileges or whether `tccd` is stopped. Confirmed by repeated attempts from SSH with and without `sudo`, with and without stopping `tccd`.

**Do not attempt to modify TCC.db from inside a running macOS VM.** The only valid approaches are:

1. **Lima disk patching** — inject during `limactl create` before the VM ever boots (preferred, described above)
2. **Offline** — stop the VM, mount the disk from the host, read/write, unmount, restart (described below)

---

## Offline Inspection (VM Stopped)

The host's `sqlite3` is not subject to the guest's TCC authorization hook when the VM is not running.

```bash
# 1. Stop the VM
limactl stop macos-15

# 2. Attach the disk image
hdiutil attach -readonly ~/.lima/macos-15/disk
# Look for:
#   /dev/diskNs5   Apple_APFS_Volume   /Volumes/Data          ← user data lives here
#   /dev/diskNs1   Apple_APFS_Volume   /Volumes/Macintosh HD  ← sealed system volume

# 3. Read system TCC
sqlite3 "/Volumes/Data/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT service, client, client_type, auth_value, auth_reason, indirect_object_identifier FROM access;"

# 4. Read user TCC (substitute actual guest username)
sqlite3 "/Volumes/Data/Users/blake.guest/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT service, client, client_type, auth_value, auth_reason, indirect_object_identifier FROM access;"

# 5. Get schema
sqlite3 "/Volumes/Data/Library/Application Support/com.apple.TCC/TCC.db" ".schema access"

# 6. Detach when done — use hdiutil detach, NOT diskutil image detach
hdiutil detach /dev/diskN   # top-level disk device (e.g. disk20)

# 7. Restart the VM
limactl start macos-15
```

---

## Key Fields in `access` Table

| Column | Meaning |
|---|---|
| `service` | TCC service (e.g. `kTCCServiceAppleEvents`, `kTCCServiceCamera`) |
| `client` | Bundle ID (type 0) or path (type 1) of the requesting process |
| `client_type` | 0 = bundle ID, 1 = absolute path |
| `auth_value` | 0 = denied, 1 = unknown, 2 = allowed, 3 = limited |
| `auth_reason` | 3 = user consent, 4 = system policy, 7 = override |
| `csreq` | Code signing requirement blob for the client process |
| `indirect_object_identifier` | Target app bundle ID (for AppleEvents) |
| `indirect_object_code_identity` | Code signing blob for the target app |
