#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MDM_DIR="$(dirname "$SCRIPT_DIR")"
source "$MDM_DIR/.envrc"
exec "$(go env GOPATH)/bin/nanomdm" \
    -storage     file \
    -storage-dsn "$MDM_DIR/data/nanomdm" \
    -ca          "$MDM_DIR/data/scep/ca.pem" \
    -api-key     "$MDM_API_KEY" \
    -listen      "127.0.0.1:${MDM_HTTP_PORT}" \
    -debug
