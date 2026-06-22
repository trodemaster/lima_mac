#!/usr/bin/env bash
# Generate SCEP intermediate CA.
# The private key is generated locally; only the CSR is sent to Vault.
# Vault signs the CSR as an intermediate CA and returns the cert.
# Also fetches the Vault issuer cert for distribution to VMs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MDM_DIR="$(dirname "$SCRIPT_DIR")"
source "$MDM_DIR/.envrc"

DEPOT="$MDM_DIR/data/scep"
TLS_DIR="$MDM_DIR/data/tls"
mkdir -p "$DEPOT" "$TLS_DIR"

if [[ -f "$DEPOT/ca.key" && -f "$DEPOT/ca.pem" ]]; then
    echo "[setup-ca] SCEP CA already exists at $DEPOT — skipping generation"
    echo "[setup-ca] Delete $DEPOT/ca.key and $DEPOT/ca.pem to regenerate"
else
    echo "[setup-ca] Generating SCEP CA private key..."
    openssl genrsa -out "$DEPOT/ca.key" 2048
    chmod 600 "$DEPOT/ca.key"

    echo "[setup-ca] Generating SCEP CA CSR..."
    openssl req -new \
        -key "$DEPOT/ca.key" \
        -subj "/O=lima-mac/CN=lima-mac SCEP CA" \
        -out "$DEPOT/ca.csr"

    echo "[setup-ca] Signing SCEP CA CSR with Vault (${VAULT_PKI_MOUNT}/sign-intermediate)..."
    vault write -format=json "${VAULT_PKI_MOUNT}/sign-intermediate" \
        csr="@$DEPOT/ca.csr" \
        common_name="lima-mac SCEP CA" \
        ttl="87600h" \
        use_csr_values=true | \
        jq -r '.data.certificate' > "$DEPOT/ca.pem"

    echo "[setup-ca] SCEP CA ready:"
    openssl x509 -in "$DEPOT/ca.pem" -noout -subject -dates
fi

echo "[setup-ca] Fetching Vault issuer cert for VM trust distribution..."
vault read -field=certificate "${VAULT_PKI_MOUNT}/issuer/${VAULT_ISSUER_REF}" \
    > "$TLS_DIR/vault-issuer-ca.pem"
echo "[setup-ca] Vault issuer cert written to $TLS_DIR/vault-issuer-ca.pem"
echo "[setup-ca] Install this on VMs with:"
echo "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain vault-issuer-ca.pem"
