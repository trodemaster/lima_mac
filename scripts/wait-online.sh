#!/usr/bin/env bash
set -euo pipefail

# Wait for a Lima VM to come back online after reboot.
# Usage: wait-online.sh <instance> [limactl]

INSTANCE="${1:?Usage: $0 INSTANCE_NAME [LIMACTL_PATH]}"
LIMACTL="${2:-limactl}"

log_info() { echo "[wait-online] [INFO]  $*"; }
log_warn() { echo "[wait-online] [WARN]  $*"; }
log_error() { echo "[wait-online] [ERROR] $*" >&2; }

log_info "Waiting for ${INSTANCE} to come back online (up to 15m)..."
for i in $(seq 1 60); do
    if "$LIMACTL" shell "$INSTANCE" -- true 2>/dev/null; then
        log_info "${INSTANCE} is back online"
        exit 0
    fi
    log_warn "  ...waiting (${i}/60)"
    sleep 15
done

log_error "Timed out waiting for ${INSTANCE} to come back online"
exit 1
