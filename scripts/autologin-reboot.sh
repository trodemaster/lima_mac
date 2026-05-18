#!/usr/bin/env bash
set -euo pipefail

# Re-applies auto-login and reboots if a prior OS update cleared it.
# Checks for ~/.needs-autologin-reboot on the guest (written by os-update.sh).
# No-ops if the marker is absent (no OS update occurred).
#
# Usage: autologin-reboot.sh <instance> [limactl]

INSTANCE="${1:?Usage: $0 INSTANCE_NAME [LIMACTL_PATH]}"
LIMACTL="${2:-limactl}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_info() { echo "[autologin-reboot] [INFO]  $*"; }
log_warn() { echo "[autologin-reboot] [WARN]  $*"; }
log_error() { echo "[autologin-reboot] [ERROR] $*" >&2; }

if ! "$LIMACTL" shell "$INSTANCE" -- bash -c 'test -f ~/.needs-autologin-reboot' 2>/dev/null; then
    log_info "No post-update reboot needed for ${INSTANCE}"
    exit 0
fi

log_info "OS update cleared auto-login — re-applying and rebooting ${INSTANCE}..."
"$LIMACTL" shell "$INSTANCE" -- bash -c 'rm -f ~/.needs-autologin-reboot'
"$LIMACTL" shell "$INSTANCE" -- /Volumes/lima_mac/configure.sh autologin
"$LIMACTL" shell "$INSTANCE" -- sudo reboot || true

log_info "Waiting for ${INSTANCE} to come back online (up to 15m)..."
for i in $(seq 1 60); do
    if "$LIMACTL" shell "$INSTANCE" -- true 2>/dev/null; then
        log_info "${INSTANCE} is back online and auto-logged in"
        break
    fi
    log_warn "  ...waiting (${i}/60)"
    sleep 15
    if [[ $i -eq 60 ]]; then
        log_error "Timed out waiting for ${INSTANCE} after autologin reboot"
        exit 1
    fi
done

exit 0
