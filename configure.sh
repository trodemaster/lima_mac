#!/bin/bash
# Lima macOS 26 VM Configuration Script
#
# This script configures the macOS 26 guest VM with essential tools and settings.
# It is designed to be idempotent — safe to run multiple times.
#
# Environment Variables:
#   MACOS_PASSWORD      - Set password for the current user (optional, skipped if unset)
#   SKIP_CHEZMOI        - Skip chezmoi dotfiles provisioning (set to 1 to skip)
#   SSH_PUBLIC_KEY      - Literal public key content to write as the sole authorized_keys entry.
#                         Overrides Lima's default multi-key injection. Leave unset to keep
#                         Lima's default behavior (all ~/.ssh/*.pub keys from the host).
#   AUTO_LOGIN         - Enable automatic login for current user so the GUI session
#                         starts on boot and LaunchAgent runner services auto-start.
#                         Defaults to 1 (on). Set to 0 to show the login screen.
#                         WARNING: bypasses the login screen — only use in trusted envs.
#   GITHUB_TOKEN       - Personal access token with repo/actions scope for runner setup.
#                         Required for configure_runner; skipped if unset.
#   RUNNER_LABEL       - GitHub Actions runner name (e.g. macOS_26). Required for runner setup.
#   GITHUB_OWNER       - GitHub owner for runner registration (default: trodemaster).
#   GITHUB_REPO        - GitHub repo for runner registration (default: blakeports).
#
# Usage:
#   ./configure.sh                                # Run all configuration steps
#   MACOS_PASSWORD="mypass" ./configure.sh        # Set password during config
#   SKIP_CHEZMOI=1 ./configure.sh                 # Skip chezmoi provisioning
#   MACOS_PASSWORD="mypass" SKIP_CHEZMOI=1 ./configure.sh  # Password only, no dotfiles

set -eux -o pipefail

# ── Environment Setup ──────────────────────────────────────────────────────────

# Load environment variables from .envrc if it exists
# This allows passing secrets and custom configuration to the script
if [[ -f /Volumes/lima_mac/.envrc ]]; then
    set +ex
    source /Volumes/lima_mac/.envrc
    set -ex
fi

# Color output for readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $@"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $@"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $@"
}

# ── Main Configuration Steps ───────────────────────────────────────────────────

main() {
    case "${1:-}" in
        runner)
            # Called by Makefile after macports.sh with RUNNER_LABEL and RUNNER_TOKEN set.
            configure_runner
            ;;
        autologin)
            # Re-apply auto-login after OS upgrades clear the setting.
            configure_password
            configure_autologin
            configure_screensaver
            ;;
        wallpaper)
            # Set login window and user desktop wallpaper.
            configure_wallpaper
            ;;
        "")
            # Default: full provisioning run triggered by Lima at first boot.
            if ! [[ "$OSTYPE" == "darwin"* ]]; then
                log_error "This script is designed for macOS guests only"
                exit 1
            fi
            log_info "Starting macOS VM configuration..."
            configure_password
            configure_autologin
            configure_setup_assistant
            configure_screensaver
            configure_ssh_keys
            configure_chezmoi
            log_info "Configuration complete!"
            ;;
        *)
            log_error "Unknown subcommand: $1"
            exit 1
            ;;
    esac
}

# ── Screensaver and Sleep ─────────────────────────────────────────────────────

configure_screensaver() {
    log_info "Disabling screensaver and screen lock..."

    # Disable screensaver idle timer
    defaults -currentHost write com.apple.screensaver idleTime 0
    defaults write com.apple.screensaver idleTime 0
    sudo defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime 0

    # Disable "require password after screensaver/display-off" — macOS 15 defaults this
    # to Immediately, which causes a lock screen on every display wake (including when
    # Lima.app connects to show the virtual display after reboot).
    defaults write com.apple.screensaver askForPassword -int 0
    defaults write com.apple.screensaver askForPasswordDelay -int 0
    defaults -currentHost write com.apple.screensaver askForPassword -int 0
    defaults -currentHost write com.apple.screensaver askForPasswordDelay -int 0

    # Disable sleep and energy saver features (not appropriate for a CI VM)
    sudo pmset -a sleep 0
    sudo pmset -a displaysleep 0
    sudo pmset -a disksleep 0
    sudo pmset -a standby 0
    sudo pmset -a powernap 0
    sudo pmset -a womp 0

    # Disable App Nap (process throttling when app is not frontmost)
    defaults write NSGlobalDomain NSAppSleepDisabled -bool YES

    # Enable Full Keyboard Access so Tab navigates all controls (including dialog buttons).
    # Required for cliclick to deterministically reach the Allow button in TCC dialogs.
    defaults write NSGlobalDomain AppleKeyboardUIMode -int 3

    log_info "Screensaver, screen lock, and energy saver settings disabled"
}

# ── GUI Session Helper ────────────────────────────────────────────────────────

# Run a command inside the current user's Aqua GUI session.
# Combines launchctl asuser (gui bootstrap namespace) with sudo -u (correct UID).
# Required for anything that needs window server access: CGEventPost, osascript/Finder.
# Ref: https://scriptingosx.com/2020/08/running-a-command-as-another-user/
run_in_gui_session() {
    sudo launchctl asuser "$(id -u)" sudo -u "$(whoami)" "$@"
}

# ── Wallpaper ─────────────────────────────────────────────────────────────────

configure_wallpaper() {
    local wallpaper="/System/Library/Desktop Pictures/Solid Colors/Space Gray.png"
    log_info "Setting wallpaper to Space Gray..."

    # Login window wallpaper (no GUI session needed)
    sudo defaults write /Library/Preferences/com.apple.loginwindow DesktopPicture "$wallpaper"

    # User desktop wallpaper requires an active GUI session (Finder running).
    # cliclick auto-approves the TCC dialog that appears when sshd-keygen-wrapper first
    # contacts Finder via AppleEvents — it presses Return (the Allow button default) when
    # UserNotificationCenter appears. Runs in gui/501 so CGEvents target the GUI session.
    if pgrep -x Dock >/dev/null 2>&1; then
        # Wait until the current user owns the console login session before triggering the
        # TCC dialog. stat -f %Su /dev/console returns whoever holds the console session;
        # once it matches our user the GUI session is established and ready to route key events.
        local _console_user="" _waited=0 _current_user
        _current_user=$(whoami)
        while [[ "$_console_user" != "$_current_user" && $_waited -lt 120 ]]; do
            _console_user=$(stat -f %Su /dev/console 2>/dev/null || true)
            [[ "$_console_user" == "$_current_user" ]] && break
            sleep 5; _waited=$((_waited + 5))
        done
        log_info "Console login session ready after ${_waited}s (console user: ${_console_user})"

        # cliclick needs kTCCServicePostEvent to send key events. tccd attributes the request
        # to the responsible process ancestor — from SSH that is sshd-keygen-wrapper, a platform
        # binary that gets auto-denied with no prompt. A LaunchAgent plist bootstrapped into
        # gui/501 is spawned directly by launchd, breaking the sshd ancestry chain and allowing
        # the pre-seeded kTCCServiceAccessibility grant to take effect.
        local _click_script=/tmp/lima-cliclick-allow.sh
        local _click_plist=/tmp/com.lima.cliclick-allow.plist
        cat > "$_click_script" << 'CLICKSCRIPT'
#!/bin/bash
sleep 10 && /opt/local/bin/cliclick kp:tab kp:return
CLICKSCRIPT
        chmod +x "$_click_script"
        local _uid
        _uid=$(id -u)
        cat > "$_click_plist" << CLICKPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.lima.cliclick-allow</string>
    <key>ProgramArguments</key>
    <array><string>/bin/bash</string><string>$_click_script</string></array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
CLICKPLIST
        sudo launchctl bootstrap gui/"$_uid" "$_click_plist" 2>/dev/null || true

        if run_in_gui_session osascript -e \
            "tell application \"Finder\" to set desktop picture to POSIX file \"${wallpaper}\""; then
            log_info "User desktop wallpaper configured"
        else
            log_warn "User desktop wallpaper skipped — Finder not responding (non-fatal)"
        fi

        launchctl bootout gui/"$_uid"/com.lima.cliclick-allow 2>/dev/null || true
        rm -f "$_click_script" "$_click_plist"
    else
        log_warn "No GUI session — user desktop wallpaper skipped (login window wallpaper set)"
    fi

    log_info "Wallpaper configured"
}

# ── Setup Assistant Suppression ───────────────────────────────────────────────

configure_setup_assistant() {
    log_info "Suppressing macOS Setup Assistant and first-run screens..."

    # Prevents the initial Setup Assistant wizard from running (system-level flag).
    # Lima also touches this during disk patching, but re-touching is harmless.
    sudo touch /var/db/.AppleSetupDone

    # NOTE: SkipSetupItems (OSShowcase, Welcome, etc.) requires an MDM profile.
    # Apple blocked 'profiles install' via CLI since Big Sur (2020), and writing
    # directly to the managed preferences domain does not work for this key.
    #
    # Per-user DidSee* preferences are now written by Lima's fake-cloud-init
    # (suppressFirstLoginScreens in fakecloudinit_darwin.go) as a root LaunchDaemon
    # before the first GUI session — that is the correct timing to prevent macOS
    # from resetting them during first-login initialization.

    # Suppress analytics/diagnostics consent dialogs (Analytics screen appears on
    # first login in macOS 26+, even with .AppleSetupDone present).
    sudo /usr/bin/defaults write \
        "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist" \
        AutoSubmit -bool false
    sudo /usr/bin/defaults write \
        "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist" \
        ThirdPartyDataSubmit -bool false
    sudo /usr/bin/defaults write \
        "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist" \
        AutoSubmitVersion -int 4
    sudo /usr/bin/defaults write \
        "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist" \
        SeedAutoSubmit -bool false

    log_info "Setup Assistant suppression complete"
}

# ── Auto-Login Configuration ──────────────────────────────────────────────────

# Encode a password into /etc/kcpassword format and write it as root.
# Uses only bash built-ins + xxd (/usr/bin/xxd ships with macOS, no CLT needed).
# Compatible with bash 3.2 (macOS system shell at /bin/bash).
# Algorithm: XOR each password byte with the 11-byte cipher key, then pad to the
# next multiple of 12 (always ≥1 byte) so macOS finds a null terminator on decode.
# Ref: https://github.com/brunerd/macAdminTools/blob/main/Scripts/setAutoLogin.sh
_write_kcpassword() {
    local pw="$1"
    local cipher_hex=(7D 89 52 23 D2 BC DD EA A3 B9 1F)

    # Convert password string to an array of uppercase hex byte values.
    local pw_hex_array
    pw_hex_array=( $( printf '%s' "$pw" | xxd -p -u | sed 's/../& /g' ) )

    local pw_len=${#pw_hex_array[@]}

    # Pad to next multiple of 12, always at least 1 extra byte.
    local padding
    if [ "$pw_len" -lt 12 ]; then
        padding=$(( 12 - pw_len ))
    elif [ $(( pw_len % 12 )) -ne 0 ]; then
        padding=$(( 12 - pw_len % 12 ))
    else
        padding=12
    fi

    local total=$(( pw_len + padding ))
    local out_hex="" i ch_hex ci_hex xor_byte

    for (( i=0; i<total; i++ )); do
        ch_hex="${pw_hex_array[$i]:-00}"
        ci_hex="${cipher_hex[$(( i % 11 ))]}"
        xor_byte=$( printf "%02X" "$(( 0x${ci_hex} ^ 0x${ch_hex} ))" )
        out_hex="${out_hex}${xor_byte}"
    done

    # Write binary via sudo tee — avoids shell-redirect permission issues.
    printf '%s' "$out_hex" | xxd -r -p | sudo tee /etc/kcpassword > /dev/null
    sudo chmod 0600 /etc/kcpassword
    sudo chown root:wheel /etc/kcpassword
}

configure_autologin() {
    if [[ "${AUTO_LOGIN:-1}" == "0" ]]; then
        log_info "AUTO_LOGIN=0; skipping auto-login configuration"
        return 0
    fi

    local current_user password_file password_val
    current_user=$(whoami)

    # configure_password runs first so ~/password always reflects the current password.
    password_file="$HOME/password"
    if [[ ! -f "$password_file" ]]; then
        log_warn "~/password not found; skipping auto-login (Lima password file missing)"
        return 0
    fi

    log_info "Enabling automatic login for $current_user"

    set +x
    password_val=$(cat "$password_file")

    # Attempt 1: sysadminctl -autologin set (available since macOS Ventura).
    # Handles both autoLoginUser preference and /etc/kcpassword in one call.
    # KNOWN LIMITATION: SACSetAutoLoginPassword internally calls the Security Agent,
    # which requires an active GUI/login-window context. When run from SSH or any
    # headless root context (no Security Agent), it fails silently with error:22
    # (EINVAL) and exits 0 without creating kcpassword. This affects macOS 15+.
    # Reference: https://derflounder.wordpress.com/2023/03/04/setting-a-user-account-to-automatically-log-in-using-sysadminctl-on-macos-ventura/
    sudo sysadminctl \
        -autologin set \
        -userName "$current_user" \
        -password "$password_val" \
        >/dev/null 2>&1

    # Always write autoLoginUser — sysadminctl may create kcpassword but silently
    # fail to write the loginwindow preference when called from SSH without a
    # Security Agent context (macOS 15+, error:22 / EINVAL).
    sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "$current_user"

    if [[ -f /etc/kcpassword ]]; then
        log_info "Auto-login enabled via sysadminctl"
    else
        # Attempt 2: manual fallback using bash + xxd.
        # Required on macOS 15+ where sysadminctl error:22 prevents kcpassword creation
        # (SACSetAutoLoginPassword requires a GUI/Security Agent context unavailable via SSH).
        log_info "sysadminctl did not write kcpassword; using bash+xxd fallback"

        # Validate the password is correct before writing kcpassword.
        if ! /usr/bin/dscl /Search -authonly "$current_user" "$password_val" &>/dev/null; then
            log_warn "Password in ~/password does not authenticate — kcpassword not written"
            log_warn "Auto-login will not work; re-run configure.sh after correcting the password"
            set -x
            return 0
        fi

        _write_kcpassword "$password_val"
    fi

    set -x
    log_info "Auto-login enabled — VM will log in as '$current_user' on next boot"
    log_warn "Login screen is bypassed; only use this in a trusted/private environment"
}

# ── SSH Key Configuration ──────────────────────────────────────────────────────

configure_ssh_keys() {
    if [[ -z "${SSH_PUBLIC_KEY:-}" ]]; then
        log_info "SSH_PUBLIC_KEY not set; using Lima's default key injection (all ~/.ssh/*.pub)"
        return 0
    fi

    log_info "SSH_PUBLIC_KEY set; replacing user keys in authorized_keys with specified key"
    log_info "(Lima's own operational key is preserved for limactl SSH access)"

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    # Preserve Lima's own key (comment "lima") — required for limactl shell / file sharing.
    # Replace all other entries with only the specified key.
    local lima_key=""
    if [[ -f "$HOME/.ssh/authorized_keys" ]]; then
        lima_key=$(grep ' lima$' "$HOME/.ssh/authorized_keys" || true)
    fi

    set +x
    {
        echo "$SSH_PUBLIC_KEY"
        [[ -n "$lima_key" ]] && echo "$lima_key"
    } > "$HOME/.ssh/authorized_keys"
    set -x
    chmod 600 "$HOME/.ssh/authorized_keys"

    log_info "authorized_keys set: specified key + Lima operational key"
}

# ── Password Configuration ─────────────────────────────────────────────────────

configure_password() {
    log_info "Configuring macOS user password..."
    
    if [[ -z "${MACOS_PASSWORD:-}" ]]; then
        log_warn "MACOS_PASSWORD not set; keeping Lima-generated password (see ~/password)"
        return 0
    fi
    
    local current_user
    current_user=$(whoami)
    local password_file="$HOME/password"
    
    if [[ ! -f "$password_file" ]]; then
        log_warn "Lima password file ($password_file) not found; skipping password change"
        return 0
    fi
    
    local old_password
    old_password=$(cat "$password_file")
    
    log_info "Setting password for user: $current_user"
    # Use sysadminctl -resetPasswordFor which works with Secure Token accounts.
    # The Lima-generated old password is used as the admin credential since the
    # guest user is the only admin. Note: this does not update the login keychain.
    # Disable errexit and trace to avoid leaking secrets in logs.
    set +ex
    sudo sysadminctl \
        -adminUser "$current_user" \
        -adminPassword "$old_password" \
        -resetPasswordFor "$current_user" \
        -newPassword "$MACOS_PASSWORD" \
        >/dev/null 2>&1
    local rc=$?
    set -ex

    if [[ $rc -eq 0 ]]; then
        set +x
        chmod u+w "$password_file"
        echo "$MACOS_PASSWORD" > "$password_file"
        chmod 400 "$password_file"
        set -x
        log_info "Password configured successfully (keychain unchanged — update manually if needed)"
    else
        log_warn "Password change failed (rc=$rc)"
        log_warn "Change it manually via: passwd  OR  System Settings > Users & Groups"
        log_warn "Current generated password: cat ~/password"
    fi
}

# ── Chezmoi Dotfiles ──────────────────────────────────────────────────────────

configure_chezmoi() {
    log_info "Configuring dotfiles via chezmoi..."

    # Skip if explicitly requested (useful for debugging or fast VM rebuilds)
    if [[ "${SKIP_CHEZMOI:-0}" == "1" ]]; then
        log_warn "Skipping chezmoi configuration (SKIP_CHEZMOI=1)"
        return 0
    fi

    local install_script="/tmp/lima-chezmoi-install.sh"
    local log_file="/tmp/lima-chezmoi.log"

    # Download the chezmoi installer to a file.
    # Using -o rather than command substitution so we can detect failures
    # and avoid passing an empty string to sh -c.
    if ! curl -fsLS get.chezmoi.io -o "$install_script"; then
        log_warn "Failed to download chezmoi installer (network not yet ready?)"
        log_warn "Re-run configure.sh manually after boot: SKIP_CHEZMOI=0 /Volumes/lima_mac/configure.sh"
        return 0
    fi
    chmod +x "$install_script"

    # Run chezmoi in the background so this script returns quickly — Lima's boot.sh
    # writes lima-boot-done after this script exits, and limactl start waits for
    # that marker within a 600-second timeout. A full chezmoi bootstrap (MacPorts
    # + dotfiles) takes 15-20 minutes.
    #
    # Use a subshell with stdin/stdout/stderr fully redirected so the process
    # survives after configure.sh exits (no terminal, no SIGHUP from parent).
    # Progress: limactl shell macos-26 tail -f $log_file
    (
        exec < /dev/null
        exec >> "$log_file" 2>&1
        "$install_script" init --apply trodemaster --use-builtin-git true
    ) &
    local bg_pid=$!
    disown "$bg_pid"

    log_info "Chezmoi running in background (pid $bg_pid)"
    log_info "Monitor progress: limactl shell macos-26 tail -f $log_file"
}

# ── GitHub Actions Runner ─────────────────────────────────────────────────────
#
# Downloads, extracts, configures, and installs the GitHub Actions runner service.
# Called by the Makefile after macports.sh — not during Lima provisioning.
#
# The registration token is generated on the host via `gh api` and passed in;
# no GitHub authentication is needed inside the VM.
#
# Required env vars (set by Makefile, not secrets):
#   RUNNER_LABEL   — runner name/label (e.g. macOS_26)
#   RUNNER_TOKEN   — one-time registration token from GitHub API (expires in 1h)
#
# Optional env vars:
#   GITHUB_OWNER   — defaults to trodemaster
#   GITHUB_REPO    — defaults to blakeports

configure_runner() {
    log_info "Configuring GitHub Actions runner..."

    if [[ -z "${RUNNER_LABEL:-}" ]]; then
        log_warn "RUNNER_LABEL not set; skipping runner configuration"
        return 0
    fi

    if [[ -z "${RUNNER_TOKEN:-}" ]]; then
        log_warn "RUNNER_TOKEN not set; skipping runner configuration"
        return 0
    fi

    local owner="${GITHUB_OWNER:-trodemaster}"
    local repo="${GITHUB_REPO:-blakeports}"
    local runner_labels="self-hosted,macOS,ARM64,${RUNNER_LABEL}"

    # Skip if already configured on disk (idempotent guard)
    if [[ -f /opt/actions-runner/.runner ]]; then
        log_info "Runner already configured at /opt/actions-runner — skipping"
        return 0
    fi

    # Determine latest stable runner version
    local runner_version
    runner_version=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
        | jq -r '.tag_name | ltrimstr("v")' 2>/dev/null)

    if [[ -z "$runner_version" ]]; then
        log_warn "Failed to determine runner version; skipping runner setup"
        return 0
    fi
    log_info "Runner version: ${runner_version}"

    local arch
    arch=$(uname -m)
    local runner_package
    case "$arch" in
        "arm64")  runner_package="actions-runner-osx-arm64-${runner_version}.tar.gz" ;;
        "x86_64") runner_package="actions-runner-osx-x64-${runner_version}.tar.gz" ;;
        *)
            log_warn "Unsupported arch $arch; skipping runner setup"
            return 0
            ;;
    esac

    local runner_url="https://github.com/actions/runner/releases/download/v${runner_version}/${runner_package}"
    log_info "Downloading runner: ${runner_package}"
    if ! curl -fsSL -o /tmp/actions-runner.tar.gz "$runner_url"; then
        log_warn "Failed to download runner package; skipping"
        return 0
    fi

    # Extract and take ownership
    sudo mkdir -p /opt/actions-runner
    sudo tar -xzf /tmp/actions-runner.tar.gz -C /opt/actions-runner
    sudo chown -R "$(whoami):$(id -gn)" /opt/actions-runner
    rm -f /tmp/actions-runner.tar.gz

    # Configure the runner using the pre-generated registration token
    log_info "Configuring runner '${RUNNER_LABEL}' with labels: ${runner_labels}"
    set +x
    cd /opt/actions-runner
    ./config.sh \
        --url "https://github.com/${owner}/${repo}" \
        --token "${RUNNER_TOKEN}" \
        --name "${RUNNER_LABEL}" \
        --labels "${runner_labels}" \
        --unattended --replace
    local rc=$?
    set -x

    if [[ $rc -ne 0 ]]; then
        log_warn "Runner configuration failed (rc=$rc)"
        return 0
    fi

    # Install the LaunchAgent service
    log_info "Installing runner LaunchAgent service..."
    ./svc.sh install

    # Attempt to start the service. LaunchAgents require the gui/<uid> launchd domain,
    # which only exists after the user logs into the macOS desktop. If auto-login is
    # enabled (configure_autologin), the domain will be present on next boot and the
    # agent will start automatically. We attempt bootstrap here in case a GUI session
    # already exists (e.g. re-runs of configure.sh), and silently continue if not.
    local plist
    plist=$(ls "$HOME"/Library/LaunchAgents/actions.runner.*.plist 2>/dev/null | head -1 || true)
    if [[ -n "$plist" ]]; then
        local uid
        uid=$(id -u)
        if launchctl bootstrap "gui/${uid}" "$plist" 2>/dev/null; then
            log_info "Runner service started (gui/${uid})"
        else
            log_warn "Runner service installed but not started (no active GUI session)"
            log_warn "The service will start automatically on the next GUI login"
        fi
    fi

    log_info "Runner '${RUNNER_LABEL}' configured and service installed"
}

# ── Execution ──────────────────────────────────────────────────────────────────

main "$@"
