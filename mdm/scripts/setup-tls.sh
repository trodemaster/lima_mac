#!/usr/bin/env bash
# Issue a TLS cert from Vault for the NanoMDM/Caddy server.
# Also generates the Caddyfile in data/ with absolute paths.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MDM_DIR="$(dirname "$SCRIPT_DIR")"
source "$MDM_DIR/.envrc"

TLS_DIR="$MDM_DIR/data/tls"
mkdir -p "$TLS_DIR"

echo "[setup-tls] Issuing TLS cert from Vault for MDM server (IP: ${MDM_HOST_IP})..."
vault write -format=json "${VAULT_PKI_MOUNT}/issue/${VAULT_TLS_ROLE}" \
    common_name="mdm.lima-mac.local" \
    ip_sans="${MDM_HOST_IP}" \
    ttl="8760h" > "$TLS_DIR/cert.json"

jq -r '.data.certificate' "$TLS_DIR/cert.json" > "$TLS_DIR/server.pem"
jq -r '.data.issuing_ca'  "$TLS_DIR/cert.json" >> "$TLS_DIR/server.pem"
jq -r '.data.private_key' "$TLS_DIR/cert.json" > "$TLS_DIR/server.key"
chmod 600 "$TLS_DIR/server.key" "$TLS_DIR/cert.json"

EXPIRY=$(jq -r '.data.expiration' "$TLS_DIR/cert.json")
echo "[setup-tls] TLS cert written; expires $(date -r "$EXPIRY" '+%Y-%m-%d')"

echo "[setup-tls] Generating Caddyfile..."
cat > "$MDM_DIR/data/Caddyfile" <<EOF
{
    auto_https off
    admin off
}

:${MDM_HTTPS_PORT} {
    tls ${TLS_DIR}/server.pem ${TLS_DIR}/server.key
    reverse_proxy 127.0.0.1:${MDM_HTTP_PORT}
}
EOF

echo "[setup-tls] Caddyfile written to $MDM_DIR/data/Caddyfile"
