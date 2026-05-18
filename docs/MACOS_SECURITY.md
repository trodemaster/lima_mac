# macOS Guest Security & Privacy — Technical Reference

Technical reference for macOS security mechanisms that affect Lima VM provisioning. Documents confirmed behaviour, constraints, and ruled-out approaches based on empirical evidence from the `macos-15` and `macos-26` VM builds.

Related: `TCC_DB.md` (detailed TCC iteration log), `CLAUDE.md` (quick-reference caveats).

---

## 1. TCC — Transparency, Consent, and Control

### 1.1 Database Locations

| Database | Path on the Data volume (offline) | Runtime path inside VM |
|---|---|---|
| System | `Library/Application Support/com.apple.TCC/TCC.db` | `/Library/Application Support/com.apple.TCC/TCC.db` |
| User | `Users/<username>/Library/Application Support/com.apple.TCC/TCC.db` | `~/Library/Application Support/com.apple.TCC/TCC.db` |

**System DB**: Covered by SIP when the VM is running; no process (including root) can open it for write without `com.apple.private.tcc.manager` entitlement. Lima patches this during `limactl create` before first boot — the APFS noowners mount is not under SIP enforcement at that point.

**User DB**: Not SIP-protected, but the kernel's `SQLITE_AUTH` callback blocks all direct writes from any process (including root) when the system is booted. Same offline-only rule applies.

### 1.2 `access` Table Schema

```sql
CREATE TABLE access (
    service                            TEXT    NOT NULL,
    client                             TEXT    NOT NULL,
    client_type                        INTEGER NOT NULL,
    auth_value                         INTEGER NOT NULL,
    auth_reason                        INTEGER NOT NULL,
    auth_version                       INTEGER NOT NULL,
    csreq                              BLOB,
    policy_id                          INTEGER,
    indirect_object_identifier_type    INTEGER,
    indirect_object_identifier         TEXT    NOT NULL DEFAULT 'UNUSED',
    indirect_object_code_identity      BLOB,
    flags                              INTEGER,
    last_modified                      INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
    pid                                INTEGER,
    pid_version                        INTEGER,
    boot_uuid                          TEXT    NOT NULL DEFAULT 'UNUSED',
    last_reminded                      INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
    PRIMARY KEY (service, client, client_type, indirect_object_identifier),
    FOREIGN KEY (policy_id) REFERENCES policies(id) ON DELETE CASCADE ON UPDATE CASCADE
);
```

Verified from live macOS 15.6.1 VM (`admin` table version = 30).

### 1.3 Column Meanings

| Column | Values | Notes |
|---|---|---|
| `service` | `kTCCServiceAppleEvents`, `kTCCServiceSystemPolicyAllFiles`, `kTCCServiceAccessibility`, `kTCCServicePostEvent`, … | Service identifier string |
| `client` | Bundle ID or absolute path | Requesting process |
| `client_type` | 0 = bundle ID, 1 = absolute path | |
| `auth_value` | 0 = denied, 1 = unknown, 2 = allowed, 3 = limited | |
| `auth_reason` | See §1.4 | Most important discriminator |
| `auth_version` | 1 for most services; `kTCCServicePostEvent` uses 2 | |
| `csreq` | Binary blob encoding code-signing requirement | `FADE0C00` magic; `identifier "…" and anchor apple` is stable for Apple-signed binaries. NULL bypasses code-signing check for path-based entries. |
| `indirect_object_identifier` | Target app bundle ID (AppleEvents); `UNUSED` for other services | Primary key component |
| `indirect_object_identifier_type` | 0 = bundle, 1 = path | |
| `indirect_object_code_identity` | csreq blob for the receiver app | **Non-NULL in genuine consent entries** — carries the receiver app's `identifier "…" and anchor apple` requirement. Lima wrote NULL through dev.9; dev.10 adds the correct blob. |
| `flags` | NULL in all observed entries | |
| `pid`, `pid_version` | NULL in Lima-written entries | May be written by tccd at the moment of consent |
| `boot_uuid` | `UNUSED` in Lima-written entries; may differ in live-VM rows | Unclear if tccd validates this on subsequent boots |
| `last_modified`, `last_reminded` | Unix timestamps | |

### 1.4 `auth_reason` Values

| Value | Meaning | Observed behaviour |
|---|---|---|
| 1 | User set via System Preferences (older) | — |
| 2 | System binary, auto-approved | — |
| 3 | User consent (dialog click) | Written by tccd itself; externally-written user DB entries with this value are **revoked** by tccd at first login |
| 4 | Admin / system policy | Written by Lima into system DB; **revoked** by tccd for `kTCCServiceAppleEvents`, survives for all other confirmed services |
| 5 | System policy (inherited) | — |
| 6 | MDM PPPC policy | Requires `profilesd` trust channel; direct DB write is not equivalent |
| 7 | Override | — |
| 8 | ? | — |
| 9 | **Revoked** | Written by tccd when it overrides an externally-injected AppleEvents entry; auth_value set to 0 simultaneously |
| 10–12 | Unobserved | — |

Source: hacktricks research + direct observation from dev.6–dev.9 Lima test iterations.

### 1.5 Sister Tables

Lima currently writes only `admin` (version=30) and `access`. The full schema also includes:

- **`policies`** — named policy bundles; `id`, `bundle_id`, `uuid`, `display`.
- **`active_policy`** — maps `(client, client_type)` → `policy_id`; references `policies(id)`.
- **`access_overrides`** — per-service override flags.
- **`expired`** — tombstone table for expired entries.

Confirmed empty in both genuine post-consent and pre-boot Lima captures (2026-05-17). Lima correctly writes nothing to these tables — genuine consent entries do not reference them either.

### 1.6 Companion Files (Status)

Files that may exist alongside `TCC.db` and influence tccd's validation:

| File | Expected location | Status |
|---|---|---|
| `TCC.db-shm`, `TCC.db-wal` | Same dir as `TCC.db` | WAL/shared-memory sidecar — standard SQLite; present when DB was last written in WAL mode. Not independently load-bearing. |
| `REG.db` | System TCC dir (`Library/Application Support/com.apple.TCC/`) | Present after first boot (tccd writes it during init). Schema: `admin` key-value + `registry` (abs_path, first_seen, last_seen, trusted). **Absent in Lima pre-boot snapshot; absent before first boot in genuine capture.** Not a prerequisite — tccd writes it on startup, not as a gate for accepting DB entries. |
| `MDMOverrides.plist` | `Library/Application Support/com.apple.TCC/` | MDM-injected permission override cache. Absent on non-MDM systems. |
| `/var/db/locationd/clients.plist` | Data volume | Analogous allowlist for Location Services; separate from TCC.db. |

Extended attributes on both TCC directories: only `com.apple.provenance` is present on `TCC.db` itself (same in both genuine and Lima captures — not a discriminator). No other xattrs observed. The `com.apple.macl` attribute is a parallel consent mechanism for drag-and-drop file access — not relevant to service-based TCC grants.

---

## 2. What Externally-Written TCC Rows Survive (Confirmed)

All of the following were written by Lima's `patchTCC` into the **system DB** with `auth_reason=4` during `limactl create`. They survived tccd's first-login validation and remained `auth_value=2` after boot. Confirmed on macOS 15.6.1 and macOS 26.

| Service | Client | Client Type | auth_version | csreq |
|---|---|---|---|---|
| `kTCCServiceSystemPolicyAllFiles` | `/usr/libexec/sshd-keygen-wrapper` | path | 1 | NULL |
| `kTCCServiceSystemPolicyAllFiles` | `/Volumes/cidata/lima-guestagent` | path | 1 | NULL |
| `kTCCServiceAccessibility` | `com.apple.Terminal` | bundle | 1 | Apple-signed blob |
| `kTCCServicePostEvent` | `com.apple.Terminal` | bundle | 2 | Apple-signed blob |
| `kTCCServiceAccessibility` | `/opt/local/bin/cliclick` | path | 1 | NULL |
| `kTCCServiceDeveloperTool` | (Lima built-in preset) | — | — | — |

`cliclick` uses a NULL csreq because it is not Apple-signed and the binary changes on port updates. Path-based entries with NULL csreq skip code-signing validation (same pattern as `lima-guestagent`). Confirmed surviving first boot in dev.11 (2026-05-17).

**Conditions for survival (non-AppleEvents services):** system DB, `auth_reason=4`, correct `csreq` blob (or NULL for path-based unsigned binaries). NULL `pid`/`pid_version`/`flags` is fine. `indirect_object_code_identity` is irrelevant for non-AppleEvents services (they don't use the receiver field at all).

---

## 3. What Externally-Written TCC Rows Do NOT Survive

### 3.1 `kTCCServiceAppleEvents` — All Methods Failed (Definitive)

Summary of dev.6–dev.10 iterations (details in `TCC_DB.md`):

| Iteration | DB | auth_reason | `indirect_object_code_identity` | Outcome |
|---|---|---|---|---|
| dev.6 | User | 4 | NULL | tccd revoked at first login; `auth_value=0`, `auth_reason=9` |
| dev.7–dev.8 | User | 3 | NULL | tccd revoked at first login; same result |
| dev.9 | System | 4 | NULL | tccd **deleted** the rows from system DB; created deny record in user DB |
| dev.10 | System | 4 | **Non-NULL** (receiver csreq) | TCC dialog still appeared — unconditional rejection confirmed |

**Conclusion (dev.10, 2026-05-17):** All byte-level row discriminators exhausted. tccd rejects pre-seeded `kTCCServiceAppleEvents` entries unconditionally — the rejection is not based on any TCC.db field value but on a trust channel entirely outside the database. `kTCCServiceSystemPolicyAllFiles` survived in the same system DB at the same time, confirming this is AppleEvents-specific enforcement, not a patching bug.

**Disk-patching `kTCCServiceAppleEvents` is definitively impossible on macOS 14+.** The only remaining approach is runtime UI automation (§9.2).

**Critical side-effect discovered (dev.11):** When tccd processes a pre-seeded AppleEvents entry at first boot (even to delete it), it writes a **deny record** (`auth_value=0, auth_reason=9`) into the user DB. This deny record silently blocks all future AppleEvents requests for that client/receiver pair — no consent dialog is ever shown again. Consequence: YAML configs must not reference any AppleEvents presets. Without a pre-seeded entry, tccd has nothing to process at first boot and writes no deny record; the first live AppleEvents request triggers the consent dialog normally.

### 3.2 Per-User DB — All Services

tccd revokes any externally-written entry in the per-user DB for `kTCCServiceAppleEvents` regardless of `auth_reason`. Other services in the user DB (e.g. `kTCCServiceAccessibility`) have not been tested; Lima routes those to the system DB as standard practice.

---

## 4. Fundamental Constraint: TCC.db Cannot Be Modified from a Running VM

macOS enforces a kernel-level `SQLITE_AUTH` callback on all TCC databases. This fires regardless of process privileges (root, SIP entitlements, stopping `tccd`). **No process inside a running macOS VM can open TCC.db for write.** Confirmed by repeated attempts from SSH with and without `sudo`, with and without stopping `tccd`.

**Valid TCC modification windows:**
1. **Lima disk patching** — `patchTCC` runs on the host during `limactl create`, before any boot. The Data volume is mounted with `noowners` via `hdiutil`; the kernel's TCC auth hook is not active. This is the primary approach.
2. **Offline (VM stopped)** — stop VM, mount disk from host with `hdiutil attach -readonly`, read/write via host `sqlite3`, detach, restart.

---

## 5. SIP and the Data Volume

**Why offline patching works:** During `limactl create`, Lima attaches the raw APFS container image with `noowners` as a host-side mount. The guest's SIP is not enforced by the host kernel — SIP is a guest-side runtime policy. The Data volume slice contains `Library/Application Support/com.apple.TCC/`, which Lima can create and write freely.

**Why the system DB is SIP-protected at runtime:** Once the guest boots, `tccd` runs with `com.apple.private.tcc.manager` entitlement and the kernel sandbox enforces SIP on the system DB path. No guest process (including root SSH sessions) can bypass this.

**APFS volume roles:** The disk image contains multiple APFS volumes in one container. The relevant slices:
- `Apple_APFS_Volume / Macintosh HD` — sealed system volume; read-only; Lima does not write here.
- `Apple_APFS_Volume / Data` — user data; writable offline; TCC databases live here.

Offline inspect commands:
```bash
hdiutil attach -readonly ~/.lima/<name>/disk
# Data volume appears as e.g. /dev/disk20s5, mounted at /Volumes/Data
sqlite3 "/Volumes/Data/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT service, client, auth_value, auth_reason FROM access;"
hdiutil detach /dev/disk20   # top-level container device
```

---

## 6. csreq Blobs

csreq blobs encode a code-signing requirement expression in Apple's binary format. The `FADE0C00` magic prefix identifies the format. Lima uses `identifier "…" and anchor apple` requirements, which check that the binary is signed by Apple and has the expected bundle identifier.

**These blobs are stable across macOS versions** because they encode the identifier string and the Apple anchor, not a binary hash. The blob from macOS 15.7.7 is valid for macOS 26.

**How to regenerate:**
```bash
echo 'identifier "com.apple.Terminal" and anchor apple' \
  | csreq -b /tmp/out.csreq -r - && xxd -p /tmp/out.csreq
```

**Known blobs used by Lima** (all use `identifier "…" and anchor apple`; opcode `0x03` = opAppleAnchor):
```
# com.apple.Terminal  (client csreq)
FADE0C000000003000000001000000060000000200000012
636F6D2E6170706C652E5465726D696E616C000000000003

# com.apple.sshd-keygen-wrapper  (client csreq for /usr/libexec/sshd-keygen-wrapper)
FADE0C000000003C0000000100000006000000020000001D
636F6D2E6170706C652E737368642D6B657967656E2D7772617070657200000000000003

# com.apple.finder  (receiver csreq for sshd-apple-events-finder preset)
# verified byte-for-byte against genuine macOS 15.7.7 user-consent entry
FADE0C000000002C00000001000000060000000200000010
636F6D2E6170706C652E66696E64657200000003

# com.apple.systemevents  (receiver csreq for terminal-apple-events preset)
# generated with: echo 'identifier "com.apple.systemevents" and anchor apple' | csreq -b /tmp/out.csreq -r -
FADE0C000000003400000001000000060000000200000016
636F6D2E6170706C652E73797374656D6576656E7473000000000003
```

NULL csreq (written as SQL `NULL`) bypasses code-signing validation entirely — appropriate for path-based entries where the binary is rebuilt per-release (e.g. `lima-guestagent`).

**Note on `anchor apple` vs `anchor apple generic`:** opcode `0x03` = `opAppleAnchor` = `anchor apple` (Apple's own first-party anchor). opcode `0x0F` = `opAppleGenericAnchor` = `anchor apple generic` (includes third-party certs signed by Apple). All Lima csreq blobs use `anchor apple` (`0x03`). The two are not interchangeable.

---

## 7. Other macOS Guest Hardening Surfaces

### 7.1 Auto-Login

`sysadminctl -autologin set` **silently fails** when run from SSH (no Security Agent context). Lima detects this and falls back to writing `/etc/kcpassword` directly using the macOS XOR cipher (key: `0x7D895223D2BCDDEAA3B91F`). macOS reads `kcpassword` at boot to perform auto-login before a user session starts.

Auto-login is **cleared by OS point-release upgrades**. `configure.sh autologin` must be re-run after any OS update and before the next reboot. `scripts/autologin-reboot.sh` handles this via the `.needs-autologin-reboot` marker.

### 7.2 Screen Lock

macOS 15 defaults "Require password after screen saver begins or display is turned off" to Immediately. Even with `idleTime=0`, the display lock fires when Lima.app attaches to show the virtual display after a reboot. Fix:
```bash
defaults write com.apple.screensaver askForPassword -int 0
defaults -currentHost write com.apple.screensaver askForPassword -int 0
```
Both domains must be written. `configure_screensaver` in `configure.sh` handles this.

### 7.3 Analytics Consent Dialog

On macOS 26+, a "Share Mac Analytics with Apple" dialog appears at first login even with `.AppleSetupDone` present. Suppressed by:
```bash
/usr/libexec/PlistBuddy -c "Add :LastVersionActedOn integer 1" \
  "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist"
/usr/libexec/PlistBuddy -c "Add :SeedConfigurationIsActedOn integer 1" \
  "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist"
```
`configure_setup_assistant` in `configure.sh` handles this.

### 7.4 Setup Assistant Suppression

Writing `/private/var/db/.AppleSetupDone` (empty file, root:wheel, 0644) prevents the Setup Assistant from running at first boot. Lima writes this during disk patching (`patchWriteGuestFiles`). The file must be owned by `root:wheel` — Lima's `patchFixOwnership` uses `apfs.Chown` to correct the UID/GID after the noowners mount sets them to 99.

---

## 8. Approaches Ruled Out

| Approach | Reason |
|---|---|
| MDM PPPC `.mobileconfig` profile injection | Requires MDM enrollment or manual user action on macOS 14+; off the table by user requirement |
| `profiles install` during first-boot LaunchDaemon window | Unsigned profiles still require user interaction post-macOS 13; untested but very likely dead end |
| `sqlite3` direct write to `desktoppicture.db` (Dock wallpaper workaround) | Off the table by user requirement |
| Pre-seeding `kTCCServiceAppleEvents` in the user DB | tccd revokes all external entries at first login regardless of `auth_reason` (dev.6–dev.8) |
| Pre-seeding `kTCCServiceAppleEvents` via TCC.db (any DB, any auth_reason, any field values) | tccd rejects all externally-written AppleEvents entries unconditionally via a trust channel outside the DB; exhaustively tested dev.6–dev.10 |
| In-VM TCC.db modification | Kernel SQLITE_AUTH hook blocks all writes; no process can bypass it |
| Direct `cliclick` from SSH session (even as user 501) | SSH processes are in a separate security session from the Aqua GUI session; `CGEventPost` events do not cross this boundary regardless of UID |
| `sudo launchctl asuser <uid> sudo -u <user> cliclick` | `launchctl asuser` switches the bootstrap namespace but not the security session; additionally, tccd's `kTCCServicePostEvent` check attributes the request to the responsible ancestor process (`sshd-keygen-wrapper` — a platform binary), which is auto-denied with `authReason=5` and no prompt. Confirmed via `log show` (dev.11, 2026-05-17) |

---

## 9. Approaches Still Viable

### 9.1 ~~Field-Level Emulation of Genuine Consent Rows~~ — CLOSED

Exhaustively tested dev.6–dev.10. tccd's rejection is unconditional and independent of row field values. This path is closed. See `tcc-capture/DIFF.md` for the full evidence record.

### 9.2 cliclick LaunchAgent Dialog Auto-Approve — IMPLEMENTED (dev.11)

**Status: Working.** Validated on macOS 26 and macOS 15 via `make rebuild-26` (2026-05-17). Build log shows `[INFO] User desktop wallpaper configured`; user TCC DB contains `kTCCServiceAppleEvents` with `auth_value=2, auth_reason=3`.

**Mechanism:**
1. `kTCCServiceAccessibility` is pre-seeded for `/opt/local/bin/cliclick` in the system DB (survives first boot — §2).
2. No AppleEvents presets are referenced in YAML configs — ensures no deny record is written at first boot (§3.1).
3. Full Keyboard Access is enabled via `defaults write NSGlobalDomain AppleKeyboardUIMode -int 3` so Tab navigates all dialog controls including buttons.
4. A temporary LaunchAgent plist is written to `/tmp/com.lima.cliclick-allow.plist` and bootstrapped into `gui/<uid>` via `sudo launchctl bootstrap`. This breaks the `sshd-keygen-wrapper` ancestry chain — launchd spawns the job fresh, with no SSH parent, so tccd's `kTCCServicePostEvent` check sees a non-platform-binary responsible process and allows the event.
5. `osascript` triggers the Finder AppleEvents request (via `run_in_gui_session` — `sudo launchctl asuser <uid> sudo -u <user>`), causing tccd to show the consent dialog.
6. The LaunchAgent script sleeps 10s then sends `kp:tab kp:return`: Tab moves focus from the default-focused "Don't Allow" button to "Allow"; Return presses it.
7. tccd records a genuine `auth_reason=3` user-consent entry that persists permanently.
8. The LaunchAgent is booted out and the temp files are deleted.

**Key constraint: LaunchAgent plist is required.** CGEventPost cannot be posted from any process that traces its ancestry to `sshd-keygen-wrapper`. The LaunchAgent spawned by launchd has no such ancestor and is the only SSH-initiated mechanism that works. See §8 for the two ruled-out shortcuts.

**Session readiness:** `configure_wallpaper` polls `stat -f %Su /dev/console` and waits until it matches the current user before proceeding, confirming the Aqua GUI session is active.

**Lima source change required:** The `cliclick-accessibility` preset must be added to `pkg/guestpatch/macos/tcc_darwin.go` in the Lima fork (`github.com/trodemaster/lima`). See `docs/LIMA_AGENT_dev11.md`.

---

## 10. Reference Links

- Lima macOS guest docs: https://lima-vm.io/docs/usage/guests/macos/
- TCC technical overview (hacktricks): https://angelica.gitbook.io/hacktricks/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-tcc
- Lima TCC iteration log: `docs/TCC_DB.md`
- Lima guest-patch source: `pkg/guestpatch/macos/tcc_darwin.go` (in the Lima fork at `github.com/trodemaster/lima`)
