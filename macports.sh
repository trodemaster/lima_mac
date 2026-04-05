#!/bin/bash
# MacPorts Installation and Configuration Script for Lima macOS VMs
#
# Installs Xcode Command Line Tools and MacPorts, then configures MacPorts
# for use as a GitHub Actions runner with the blakeports overlay.
#
# Run this script once after VM creation, before registering the runner:
#   make run-26
#   make macports-26   ← calls: limactl shell macos-26 /Volumes/lima_mac/macports.sh
#   make register-26
#
# This script is idempotent — safe to re-run.
# It is shared into the VM via the lima_mac virtiofs mount at /Volumes/lima_mac/.
#
# Techniques adapted from:
#   https://github.com/trodemaster/dotfiles/blob/main/run_onchange_darwin.sh.tmpl

set -euo pipefail

# ── Helpers ────────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ── Step 1: Xcode Command Line Tools ──────────────────────────────────────────
#
# xcode-select --install opens a GUI dialog and cannot be used over SSH.
# The softwareupdate approach below is the standard headless method on macOS 15+.
# (Confirmed from xcode-select(1) manpage: --install "Opens a user interface dialog".)

install_clt() {
    if [[ -d /Library/Developer/CommandLineTools ]]; then
        log_info "Xcode Command Line Tools already installed — skipping"
        return 0
    fi

    log_info "Installing Xcode Command Line Tools..."
    touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    CMDLINE_TOOLS=$(softwareupdate -l | grep "\*.*Command Line" | tail -n 1 | sed 's/^[^C]* //')
    if [[ -z "$CMDLINE_TOOLS" ]]; then
        rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
        log_error "Could not find Command Line Tools in softwareupdate list."
        log_error "Check network connectivity, then re-run this script."
        exit 1
    fi
    log_info "Installing: $CMDLINE_TOOLS"
    softwareupdate -i "$CMDLINE_TOOLS" --verbose
    rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    log_info "Xcode Command Line Tools installed"
}

# ── Step 2: MacPorts ───────────────────────────────────────────────────────────
#
# macOS 15 (Sequoia) and earlier: use the official binary PKG installer.
# macOS 16+ (e.g. macOS 26 Tahoe): no official PKG exists yet; build from source.
# The latest release version is fetched from the GitHub API at install time.

install_macports() {
    if command -v /opt/local/bin/port &>/dev/null; then
        log_info "MacPorts already installed ($(port version 2>/dev/null || echo unknown)) — skipping"
        return 0
    fi

    log_info "Fetching latest MacPorts release version..."
    PORT_LATEST_RELEASE=$(curl -fsSL https://api.github.com/repos/macports/macports-base/releases/latest \
        | grep tag_name | cut -d '"' -f 4)
    PORT_LATEST_RELEASE_NUMBER="${PORT_LATEST_RELEASE#v}"
    log_info "Latest MacPorts release: ${PORT_LATEST_RELEASE_NUMBER}"

    MACOS_VERSION=$(sw_vers -productVersion | cut -d. -f1)
    MACOS_VERSION_NAME=$(awk '/SOFTWARE LICENSE AGREEMENT FOR macOS/' \
        '/System/Library/CoreServices/Setup Assistant.app/Contents/Resources/en.lproj/OSXSoftwareLicense.rtf' \
        | awk -F 'macOS ' '{print $NF}' | awk '{print substr($0, 0, length($0)-1)}')

    log_info "macOS version: ${MACOS_VERSION} (${MACOS_VERSION_NAME})"

    if [[ $MACOS_VERSION -ge 16 ]]; then
        log_info "macOS ${MACOS_VERSION} — no binary PKG available yet; building MacPorts from source..."
        cd "$HOME"
        curl -fsSL -O "https://distfiles.macports.org/MacPorts/MacPorts-${PORT_LATEST_RELEASE_NUMBER}.tar.bz2"
        tar xf "MacPorts-${PORT_LATEST_RELEASE_NUMBER}.tar.bz2"
        cd "MacPorts-${PORT_LATEST_RELEASE_NUMBER}/"
        ./configure
        make
        sudo make install
        cd "$HOME"
        rm -rf "MacPorts-${PORT_LATEST_RELEASE_NUMBER}" "MacPorts-${PORT_LATEST_RELEASE_NUMBER}.tar.bz2"
    else
        MACPORTS_PKG="https://github.com/macports/macports-base/releases/download/${PORT_LATEST_RELEASE}/MacPorts-${PORT_LATEST_RELEASE_NUMBER}-${MACOS_VERSION}-${MACOS_VERSION_NAME}.pkg"
        log_info "Downloading MacPorts binary PKG: ${MACPORTS_PKG}"
        curl -fsSL -o /tmp/macports.pkg "$MACPORTS_PKG"
        sudo installer -pkg /tmp/macports.pkg -target /
        rm -f /tmp/macports.pkg
    fi

    log_info "MacPorts installed"
}

# ── Step 3: MacPorts configuration ────────────────────────────────────────────
#
# sources.conf is intentionally left alone here — it is configured at workflow
# run time by blakeports/scripts/installmacports, which points it to the
# GitHub Actions runner workspace checkout of blakeports.

configure_macports() {
    export PATH="/opt/local/bin:/opt/local/sbin:$PATH"

    # archive_sites.conf — prefer fcix and MIT mirrors
    if ! grep -q "fcix" /opt/local/etc/macports/archive_sites.conf 2>/dev/null; then
        log_info "Configuring archive_sites.conf..."
        sudo tee /opt/local/etc/macports/archive_sites.conf <<'EOF'
# MacPorts binary archive sources

name                    macports_archives

name                    fcix
urls                    https://mirror.fcix.net/macports/packages/

name                    mit
urls                    http://bos.us.packages.macports.org/
EOF
    else
        log_info "archive_sites.conf already configured — skipping"
    fi

    # macports.conf — set preferred mirror and applications_dir
    if ! grep -q "fcix" /opt/local/etc/macports/macports.conf 2>/dev/null; then
        log_info "Configuring macports.conf..."
        sudo tee -a /opt/local/etc/macports/macports.conf <<'EOF'

# Lima runner configuration
applications_dir        /Applications/MacPorts
frameworks_dir          /opt/local/Library/Frameworks
host_blacklist          packages.macports.org distfiles.macports.org rsync.macports.org
preferred_hosts         mirror.fcix.net
EOF
    else
        log_info "macports.conf already configured — skipping"
    fi
}

# ── Step 4: selfupdate ─────────────────────────────────────────────────────────

selfupdate_macports() {
    log_info "Running port selfupdate..."
    sudo /opt/local/bin/port selfupdate
    log_info "MacPorts selfupdate complete"
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
    log_info "Starting MacPorts setup for Lima runner..."
    log_info "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) — $(uname -m)"

    install_clt
    install_macports
    configure_macports
    selfupdate_macports

    log_info "MacPorts setup complete!"
    log_info "Next step: make register-<instance>"
}

main "$@"
