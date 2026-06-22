#!/usr/bin/env bash
# Generate enrollment .mobileconfig from template.
# Substitutes all %%VAR%% placeholders with values from .envrc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MDM_DIR="$(dirname "$SCRIPT_DIR")"
source "$MDM_DIR/.envrc"

if [[ -z "${MDM_PUSH_TOPIC:-}" ]]; then
    echo "ERROR: MDM_PUSH_TOPIC is not set in .envrc" >&2
    echo "Upload your APNS push cert first: make push-cert APNS_CERT=... APNS_KEY=..." >&2
    exit 1
fi

SCEP_UUID=$(uuidgen)
MDM_UUID=$(uuidgen)
ENROLL_UUID=$(uuidgen)

sed \
    -e "s|%%MDM_HOST_IP%%|${MDM_HOST_IP}|g" \
    -e "s|%%MDM_SCEP_PORT%%|${MDM_SCEP_PORT}|g" \
    -e "s|%%MDM_HTTPS_PORT%%|${MDM_HTTPS_PORT}|g" \
    -e "s|%%MDM_SCEP_CHALLENGE%%|${MDM_SCEP_CHALLENGE}|g" \
    -e "s|%%MDM_PUSH_TOPIC%%|${MDM_PUSH_TOPIC}|g" \
    -e "s|%%SCEP_PAYLOAD_UUID%%|${SCEP_UUID}|g" \
    -e "s|%%MDM_PAYLOAD_UUID%%|${MDM_UUID}|g" \
    -e "s|%%ENROLLMENT_UUID%%|${ENROLL_UUID}|g" \
    "$MDM_DIR/profiles/enroll.mobileconfig.template" \
    > "$MDM_DIR/data/enroll.mobileconfig"

echo "[gen-profile] Written: $MDM_DIR/data/enroll.mobileconfig"
