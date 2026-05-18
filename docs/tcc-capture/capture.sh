#!/bin/bash
# Capture TCC state from an offline-mounted macOS VM disk.
#
# Usage:
#   ./capture.sh <mount-point> <output-dir> <guest-username>
#
# Example (Lima macos-15 disk attached at /Volumes/Data):
#   ./capture.sh /Volumes/Data ./genuine blake.guest
#
# Run AFTER: hdiutil attach -readonly ~/.lima/macos-15/disk
# Run BEFORE: hdiutil detach /dev/disk<N>   (top-level container device)
set -euo pipefail

MNT="${1:?Usage: $0 <mount-point> <output-dir> <guest-username>}"
OUT="${2:?Usage: $0 <mount-point> <output-dir> <guest-username>}"
GUEST="${3:?Usage: $0 <mount-point> <output-dir> <guest-username>}"

SYSTEM_TCC="$MNT/Library/Application Support/com.apple.TCC/TCC.db"
USER_TCC="$MNT/Users/$GUEST/Library/Application Support/com.apple.TCC/TCC.db"

mkdir -p "$OUT"

dump_table() {
    local db="$1" table="$2" out="$3"
    if [[ -f "$db" ]]; then
        sqlite3 -header -line "$db" "SELECT * FROM $table;" > "$out" 2>&1 || echo "(table $table not found)" > "$out"
    else
        echo "(database not found: $db)" > "$out"
    fi
}

echo "=== Capturing from $MNT into $OUT ==="

# System TCC DB
echo "--- System TCC DB tables ---"
for table in access admin policies active_policy access_overrides expired; do
    dump_table "$SYSTEM_TCC" "$table" "$OUT/system_${table}.txt"
    echo "  $table -> $OUT/system_${table}.txt"
done

# User TCC DB
echo "--- User TCC DB tables ($GUEST) ---"
for table in access admin policies active_policy access_overrides expired; do
    dump_table "$USER_TCC" "$table" "$OUT/user_${table}.txt"
    echo "  $table -> $OUT/user_${table}.txt"
done

# Sidecar files in TCC directories
echo "--- Sidecar files ---"
ls -la@ "$MNT/Library/Application Support/com.apple.TCC/" > "$OUT/system_sidecars.ls" 2>&1
ls -la@ "$MNT/Users/$GUEST/Library/Application Support/com.apple.TCC/" > "$OUT/user_sidecars.ls" 2>&1

# Extended attributes
echo "--- Extended attributes ---"
xattr -lr "$MNT/Library/Application Support/com.apple.TCC" > "$OUT/system_xattr.txt" 2>&1 || true
xattr -lr "$MNT/Users/$GUEST/Library/Application Support/com.apple.TCC" > "$OUT/user_xattr.txt" 2>&1 || true

# MDMOverrides.plist
MDM_PLIST="$MNT/Library/Application Support/com.apple.TCC/MDMOverrides.plist"
if [[ -f "$MDM_PLIST" ]]; then
    plutil -p "$MDM_PLIST" > "$OUT/mdm_overrides.txt" 2>&1
else
    echo "(not present)" > "$OUT/mdm_overrides.txt"
fi

# REG.db search
echo "--- Searching for REG.db ---"
find "$MNT" -name 'REG.db' 2>/dev/null > "$OUT/reg_db_locations.txt" || true
while IFS= read -r rdb; do
    if [[ -f "$rdb" ]]; then
        {
            echo "=== $rdb ==="
            sqlite3 -header -line "$rdb" ".tables" 2>&1 || true
            sqlite3 -header -line "$rdb" "SELECT * FROM sqlite_master WHERE type='table';" 2>&1 || true
        } >> "$OUT/reg_db.txt"
    fi
done < "$OUT/reg_db_locations.txt"
[[ -s "$OUT/reg_db.txt" ]] || echo "(no REG.db found)" > "$OUT/reg_db.txt"

# /var/db listing for TCC-related dirs
echo "--- /var/db TCC scan ---"
ls -la "$MNT/private/var/db/" 2>/dev/null | grep -i tcc > "$OUT/tcc_var_db.ls" || echo "(nothing tcc-related in /var/db)" > "$OUT/tcc_var_db.ls"
find "$MNT/private/var/db" -maxdepth 2 -iname '*tcc*' 2>/dev/null >> "$OUT/tcc_var_db.ls" || true

# Raw boot_uuid and last_reminded from AppleEvents rows
echo "--- boot_uuid / last_reminded for AppleEvents rows ---"
{
    echo "=== System DB ==="
    sqlite3 -header -line "$SYSTEM_TCC" \
        "SELECT service, client, auth_value, auth_reason, pid, pid_version, boot_uuid, last_modified, last_reminded, flags, indirect_object_code_identity FROM access WHERE service='kTCCServiceAppleEvents';" 2>&1 || echo "(system DB: no AppleEvents rows or DB missing)"
    echo ""
    echo "=== User DB ==="
    sqlite3 -header -line "$USER_TCC" \
        "SELECT service, client, auth_value, auth_reason, pid, pid_version, boot_uuid, last_modified, last_reminded, flags, indirect_object_code_identity FROM access WHERE service='kTCCServiceAppleEvents';" 2>&1 || echo "(user DB: no AppleEvents rows or DB missing)"
} > "$OUT/boot_uuid.txt"

echo ""
echo "=== Capture complete -> $OUT ==="
ls -la "$OUT/"
