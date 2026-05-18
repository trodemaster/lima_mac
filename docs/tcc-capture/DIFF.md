# TCC Genuine-vs-Lima Field Diff

Compares a genuine user-consent `kTCCServiceAppleEvents` TCC entry (sshd-keygen-wrapper → Finder, user clicked Allow) against Lima's disk-patched entry (written during `limactl create`, pre-boot). Captures taken from macos-15 (macOS 15.7.7).

**Genuine capture:** `genuine/` — macos-15-genuine after first boot + manual Allow click  
**Lima capture:** `lima/` — macos-15-lima after `limactl create` only, never booted

---

## AppleEvents Row — Field-by-Field Diff

| Column | Genuine (user consent) | Lima (disk-patched) | Candidate discriminator? |
|---|---|---|---|
| **service** | `kTCCServiceAppleEvents` | `kTCCServiceAppleEvents` | — irrelevant |
| **client** | `/usr/libexec/sshd-keygen-wrapper` | `/usr/libexec/sshd-keygen-wrapper` | — irrelevant |
| **client_type** | `1` (path) | `1` (path) | — irrelevant |
| **auth_value** | `2` (allowed) | `2` (allowed) | — irrelevant |
| **auth_reason** | `3` (user consent) | `4` (system policy) | **POSSIBLE** — dev.7/dev.8 tried auth_reason=3 in user DB and it still got revoked, so this alone is not sufficient |
| **auth_version** | `1` | `1` | — irrelevant |
| **csreq** | `FADE0C…sshd-keygen-wrapper` blob | `FADE0C…sshd-keygen-wrapper` blob | — irrelevant (same binary) |
| **policy_id** | NULL | NULL | — irrelevant |
| **indirect_object_identifier_type** | `0` | `0` | — irrelevant |
| **indirect_object_identifier** | `com.apple.finder` | `com.apple.finder` | — irrelevant |
| **indirect_object_code_identity** | **NON-NULL blob** (Finder csreq) | **NULL** | **STRONGEST CANDIDATE** |
| **flags** | NULL | NULL | — irrelevant |
| **last_modified** | `1779036847` | `1779037139` | — irrelevant (timestamp) |
| **pid** | NULL | NULL | — irrelevant |
| **pid_version** | NULL | NULL | — irrelevant |
| **boot_uuid** | `UNUSED` | `UNUSED` | — irrelevant |
| **last_reminded** | `1779036847` | `1779037139` | — irrelevant (timestamp) |

---

## Database Location Difference

| | Genuine | Lima |
|---|---|---|
| **Which DB** | User DB (`Users/blake.guest/Library/Application Support/com.apple.TCC/TCC.db`) | System DB (`Library/Application Support/com.apple.TCC/TCC.db`) |

Note: dev.7–dev.8 already established that auth_reason=3 in the user DB also gets revoked. Location alone is not the discriminator — tccd rejects externally-written AppleEvents entries from both DBs. The `indirect_object_code_identity` field is the strongest remaining candidate.

---

## `indirect_object_code_identity` — The Key Difference

Genuine entry has a non-NULL blob in `indirect_object_code_identity`. This encodes the Finder code signing requirement: `identifier "com.apple.finder" and anchor apple generic`.

**Blob hex (Finder csreq, standard FADE0C encoding):**
```
FADE0C000000002C00000001000000060000000200000010636F6D2E6170706C652E66696E64657200000003
```

Lima's INSERT statement does not include `indirect_object_code_identity` in the column list, so it defaults to NULL. When tccd processes the system DB at first boot and evaluates AppleEvents entries, it may require this field to be populated to treat the entry as authentic — an entry without the receiver's code identity may be rejected as incomplete or externally-fabricated.

**Proposed fix for dev.10**: Include `X'FADE0C000000002C00000001000000060000000200000010636F6D2E6170706C652E66696E64657200000003'` as `indirect_object_code_identity` in the Lima INSERT, alongside the correct `auth_reason` (3 or 4).

Note: whether this actually causes the entry to survive is unknown — tccd's AppleEvents validation may be more complex (e.g., checking whether the entry came from a genuine user interaction via a separate trust mechanism). But this is the only byte-level difference between a genuine entry and Lima's entry (beyond the DB location, which was already ruled out).

---

## Sidecar File Differences

| File | Genuine system TCC dir | Lima system TCC dir (pre-boot) |
|---|---|---|
| `TCC.db` | Present, 57344 bytes, `com.apple.provenance` xattr | Present, 57344 bytes, `com.apple.provenance` xattr |
| `REG.db` | **Present** (20480 bytes) | **Absent** |
| `TCC.db-shm` | Absent | Absent |
| `TCC.db-wal` | Absent | Absent |

**REG.db**: Present in the genuine system TCC directory after first boot. Schema has two tables: `admin` (key-value store, contains `version`) and `registry` (abs_path, first_seen, last_seen, trusted). This is likely written by tccd when it first runs and may track trusted client executables. Absent in Lima pre-boot because tccd has never run. This is probably a consequence of boot, not a prerequisite for entry survival.

**User TCC dir (genuine)**: `TCC.db` only (57344 bytes, `com.apple.provenance` xattr). No REG.db in the user TCC directory.

**User TCC dir (Lima)**: Does not exist pre-boot (expected).

---

## MDMOverrides.plist

Not present in either capture. Eliminates MDM-side policy as a factor.

---

## `admin` Table (TCC Version)

All three DBs report `version = 30`. Identical — irrelevant.

---

## Other Tables

`policies`, `active_policy`, `access_overrides`, `expired` — all empty in both genuine and Lima captures. No differences.

---

## Summary

### Confirmed irrelevant
- `auth_version`, `policy_id`, `flags`, `pid`, `pid_version`, `boot_uuid`, `last_reminded` — all match
- `csreq` (client code signing requirement) — same blob in both
- `MDMOverrides.plist` — absent in both
- `admin` table — identical version=30
- `policies`, `active_policy`, `access_overrides`, `expired` — all empty in both

### Candidate discriminators (in priority order)

1. **`indirect_object_code_identity` = NULL in Lima, NON-NULL in genuine** — strongest byte-level difference within the row. Lima's INSERT omits this field entirely. The genuine entry has the Finder code signing requirement blob. This is the only row-level field that differs.

2. **Database location (user vs. system DB)** — ruled out as sole discriminator by dev.7/dev.8 (auth_reason=3 in user DB also revoked). Still possible that combination of user DB + non-NULL `indirect_object_code_identity` + auth_reason=3 would work, but this has not been tested.

3. **`auth_reason` = 3 vs. 4** — ruled out as sole discriminator; dev.7/dev.8 tried auth_reason=3 and still got revoked.

4. **REG.db absence** — likely a consequence of boot (tccd writes it on first start), not a prerequisite. Writing a synthetic REG.db pre-boot is possible but probably irrelevant.

### Most likely explanation

tccd validates AppleEvents entries by checking `indirect_object_code_identity` against the running receiver process. An entry with a NULL receiver csreq may be treated as incomplete or unauthenticated and deleted. Alternatively, tccd may compare the entry against a live process signature, which only works if the entry was written by tccd itself during a genuine consent event.

**If the discriminator is `indirect_object_code_identity`**: Adding the Finder csreq blob to the Lima INSERT would be a targeted fix. This would require a one-line change to Lima's TCC preset code.

**If tccd has a separate non-DB trust channel for AppleEvents**: No disk-patch fix is possible. Option A (AX auto-approve) or Option C (desktoppicture.db workaround) are the only viable paths.
