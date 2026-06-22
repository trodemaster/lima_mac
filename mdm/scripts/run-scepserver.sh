#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MDM_DIR="$(dirname "$SCRIPT_DIR")"
source "$MDM_DIR/.envrc"
exec "$(go env GOPATH)/bin/scepserver" \
    -depot  "$MDM_DIR/data/scep" \
    -port   "${MDM_SCEP_PORT}" \
    -challenge "${MDM_SCEP_CHALLENGE}"
