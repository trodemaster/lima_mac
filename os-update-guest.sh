#!/usr/bin/env bash
set -uo pipefail

log() { printf '%s [os-update] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

log "=== OS update started ==="
log "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"

# Check if any available updates require a restart
needs_restart=0
if sudo softwareupdate -l 2>&1 | grep -qi "restart"; then
    needs_restart=1
    log "Restart-requiring updates found"
else
    log "No restart-requiring updates"
fi

log "Running softwareupdate --install --all --restart..."
expect - <<'EXPECT'
set timeout 7200
set pw [exec cat "$env(HOME)/password"]
spawn sudo softwareupdate --install --all --restart
expect {
    -re {[Pp]assword} { send "$pw\r"; exp_continue }
    eof
}
EXPECT

log "=== softwareupdate exited ==="

if [[ "$needs_restart" == "1" ]]; then
    log "Removing SSH service from bootstrap to force wait-for-online cycle..."
    sudo launchctl bootout system/com.openssh.sshd
fi
