#!/bin/bash
# Developer Tools Installation Script for Lima macOS VMs
#
# Installs Xcode Command Line Tools (always) and Xcode (in addition, when an
# archive is available). Run this before macports.sh — MacPorts source builds
# need CLT, and certain MacPorts ports need full Xcode.
#
# xcode-select always points at the CLT, never at Xcode: ports build with the
# CLT, and the ones that need Xcode find it in /Applications alongside.
#
# Environment variables:
#   XCODE_XIP   - filename of the Xcode .xip archive inside /Volumes/lima_mac/xcode/
#                 e.g. XCODE_XIP=Xcode_27.xip
#                 If unset or the file is not found, Xcode install is skipped with
#                 a warning (non-fatal). CLT install is always attempted and required.
#
# This script is idempotent — safe to re-run.

set -euo pipefail

# ── Helpers ────────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

XCODE_XIP="${XCODE_XIP:-}"
XCODE_DIR="/Volumes/lima_mac/xcode"
CLT_DIR="/Library/Developer/CommandLineTools"
XCODEBUILD="/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"

# ── Step 1: Xcode Command Line Tools (required) ────────────────────────────────
#
# CLT is always required — MacPorts needs a working C compiler — even when Xcode
# is installed too. Installed means the CLTools_Executables package receipt: a
# stub /Library/Developer/CommandLineTools directory (left by DFU install on
# macOS 27 beta) has none and is treated as "not installed".

install_clt() {
    if pkgutil --pkg-info=com.apple.pkg.CLTools_Executables &>/dev/null; then
        log_info "Command Line Tools already installed ($(pkgutil --pkg-info=com.apple.pkg.CLTools_Executables | awk '/^version:/ {print $2}')) — skipping"
        return 0
    fi

    log_info "Installing Xcode Command Line Tools..."
    # softwareupdate can be locked by a post-OS-update daemon for several minutes.
    # Retry the listing step up to 12 times (11 min total).
    local CMDLINE_TOOLS=""
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
        touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
        CMDLINE_TOOLS=$(softwareupdate -l 2>&1 | grep "\*.*Command Line" | tail -n 1 | sed 's/^[^C]* //') || true
        if [[ -n "$CMDLINE_TOOLS" ]]; then
            break
        fi
        rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
        if [[ $attempt -lt 12 ]]; then
            log_warn "softwareupdate busy or CLT not listed yet (attempt $attempt/12), retrying in 60s..."
            sleep 60
        fi
    done
    if [[ -z "$CMDLINE_TOOLS" ]]; then
        log_error "Could not find Command Line Tools in softwareupdate list after 12 attempts."
        log_error "Check network connectivity and macOS version, then re-run this script."
        exit 1
    fi
    log_info "Installing: $CMDLINE_TOOLS"
    sudo softwareupdate -i "$CMDLINE_TOOLS" --verbose
    rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    log_info "Xcode Command Line Tools installed"
}

# ── Step 2: Xcode (optional, in addition to CLT) ───────────────────────────────
#
# Xcode is needed for ports that use the xcode PortGroup.
# It is installed from a .xip archive placed in the xcode/ directory of this repo.
# Drop-in: copy an Xcode .xip into lima_mac/xcode/ and set XCODE_XIP to its filename.
#
# If XCODE_XIP is unset or the file is missing, installation is skipped — CLT
# alone is enough for most ports. Xcode is not selected with xcode-select (see
# select_clt); its own xcodebuild accepts the license and runs first launch.

install_xcode() {
    if [[ -d /Applications/Xcode.app ]]; then
        log_info "Xcode already installed ($("$XCODEBUILD" -version 2>/dev/null | head -1)) — skipping"
        return 0
    fi

    if [[ -z "${XCODE_XIP}" ]]; then
        log_warn "XCODE_XIP not set — skipping Xcode install"
        return 0
    fi

    local xip_path="${XCODE_DIR}/${XCODE_XIP}"
    if [[ ! -f "${xip_path}" ]]; then
        log_warn "Xcode archive not found: ${xip_path} — skipping Xcode install"
        return 0
    fi

    log_info "Expanding Xcode from ${xip_path} (this takes several minutes)..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    cd "${tmp_dir}"
    xip --expand "${xip_path}"
    local xcode_app
    xcode_app=$(ls -d "${tmp_dir}"/Xcode*.app 2>/dev/null | head -1)
    if [[ -z "${xcode_app}" ]]; then
        log_warn "No Xcode.app found after expanding ${XCODE_XIP} — skipping"
        cd /; rm -rf "${tmp_dir}"
        return 0
    fi
    log_info "Installing $(basename "${xcode_app}") → /Applications/Xcode.app..."
    sudo mv "${xcode_app}" /Applications/Xcode.app
    sudo "$XCODEBUILD" -license accept
    sudo "$XCODEBUILD" -runFirstLaunch
    cd /; rm -rf "${tmp_dir}"
    log_info "Xcode installed: $("$XCODEBUILD" -version 2>/dev/null | head -1)"
}

# ── Step 3: Point xcode-select at the CLT ─────────────────────────────────────
#
# Runs every time, so it also moves a VM that was left pointing at Xcode.

select_clt() {
    if [[ "$(xcode-select -p 2>/dev/null)" != "${CLT_DIR}" ]]; then
        sudo xcode-select -s "${CLT_DIR}"
    fi
    log_info "xcode-select: $(xcode-select -p)"
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
    log_info "Starting developer tools setup..."
    log_info "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) — $(uname -m)"

    install_clt
    install_xcode
    select_clt

    log_info "Developer tools setup complete"
}

main "$@"
