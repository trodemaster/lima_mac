#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MDM_DIR="$(dirname "$SCRIPT_DIR")"
source "$MDM_DIR/.envrc"

if [[ ! -f "$MDM_DIR/data/Caddyfile" ]]; then
    echo "ERROR: $MDM_DIR/data/Caddyfile not found — run: make setup-tls" >&2
    exit 1
fi

exec /opt/local/bin/caddy run \
    --config "$MDM_DIR/data/Caddyfile" \
    --adapter caddyfile
