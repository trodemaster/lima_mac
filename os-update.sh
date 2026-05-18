#!/usr/bin/env bash
set -euo pipefail

# Check for macOS software updates in a Lima VM and install them via SSH.
# Uses expect (guest-side) to handle any password prompts from softwareupdate.
# Waits for the VM to return if a restart-requiring update is installed.
#
# Usage: os-update.sh <instance> [limactl]
# Set SKIP_OS_UPDATE=1 to skip entirely (speeds up test builds).

INSTANCE="${1:?Usage: $0 INSTANCE_NAME [LIMACTL_PATH]}"
LIMACTL="${2:-limactl}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_info() { echo "[os-update] [INFO]  $*"; }
log_warn() { echo "[os-update] [WARN]  $*"; }
log_error() { echo "[os-update] [ERROR] $*" >&2; }

if [[ "${SKIP_OS_UPDATE:-0}" == "1" ]]; then
    log_info "SKIP_OS_UPDATE=1 — skipping for ${INSTANCE}"
    exit 0
fi

# ── Quick update check via SSH ─────────────────────────────────────────────────
# Avoids running softwareupdate install if there is nothing to do.
# Also determines whether a restart will be required so we know to wait for reboot.
log_info "Checking for available OS updates..."
update_output=$("$LIMACTL" shell "$INSTANCE" -- sudo softwareupdate -l 2>&1 || true)

if echo "$update_output" | grep -q "No new software available"; then
    log_info "No OS updates available"
    exit 0
fi

log_info "OS updates found:"
echo "$update_output"

needs_restart=0
if echo "$update_output" | grep -qi "restart"; then
    needs_restart=1
    log_info "Restart-requiring updates present — will wait for reboot after install"
fi

# ── SCP the guest update script into the VM ───────────────────────────────────
LIMA_SSH_CONFIG="$HOME/.lima/${INSTANCE}/ssh.config"
GUEST_SCRIPT="/tmp/os-update-guest.sh"

log_info "Copying os-update-guest.sh → ${INSTANCE}:${GUEST_SCRIPT}"
scp -F "$LIMA_SSH_CONFIG" -q \
    "$SCRIPT_DIR/os-update-guest.sh" \
    "lima-${INSTANCE}:${GUEST_SCRIPT}"
"$LIMACTL" shell "$INSTANCE" -- chmod +x "$GUEST_SCRIPT"

# ── Run guest script via SSH (foreground) ─────────────────────────────────────
# Blocks while softwareupdate downloads and installs. If a restart is triggered
# the SSH connection will drop; || true prevents that from failing the build.
log_info "Running softwareupdate on ${INSTANCE} (this may take a while)..."
"$LIMACTL" shell "$INSTANCE" -- "$GUEST_SCRIPT" || true

# ── If no restart required, we are done ───────────────────────────────────────
if [[ "$needs_restart" == "0" ]]; then
    log_info "No restart required — update complete"
    exit 0
fi

# ── Sleep to allow bootout and --restart reboot to fully take effect ──────────
# The guest script boots out sshd after softwareupdate exits. Sleeping here
# gives the VM time to go offline before we start polling for it to return.
log_info "Waiting 2 minutes for ${INSTANCE} to reboot..."
sleep 120

# ── Wait for VM to come back after reboot ─────────────────────────────────────
log_info "Waiting for ${INSTANCE} to come back online (up to 15m)..."
for i in $(seq 1 60); do
    if "$LIMACTL" shell "$INSTANCE" -- true 2>/dev/null; then
        log_info "${INSTANCE} is back online"
        break
    fi
    log_warn "  ...waiting (${i}/60)"
    sleep 15
    if [[ $i -eq 60 ]]; then
        log_error "Timed out waiting for ${INSTANCE} after OS update reboot"
        exit 1
    fi
done

# ── Mark that autologin must be re-applied before the build completes ─────────
# The OS update clears auto-login; scripts/autologin-reboot.sh checks this file
# and does a final reboot to bring the VM up in a logged-in state.
log_info "Marking autologin reboot needed for ${INSTANCE}..."
"$LIMACTL" shell "$INSTANCE" -- bash -c 'touch ~/.needs-autologin-reboot'
