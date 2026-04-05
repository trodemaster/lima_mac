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
    # Use set +e/set -e to continue even if .envrc has unset variables
    set +e
    source /Volumes/lima_mac/.envrc
    set -e
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
    log_info "Starting macOS 26 VM configuration..."
    
    # Verify we're in a macOS guest VM
    if ! [[ "$OSTYPE" == "darwin"* ]]; then
        log_error "This script is designed for macOS guests only"
        exit 1
    fi
    
    # Run configuration steps
    configure_password
    configure_autologin
    configure_setup_assistant
    configure_ssh_keys
    configure_chezmoi
    
    log_info "Configuration complete!"
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

        sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "$current_user"
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

# ── Execution ──────────────────────────────────────────────────────────────────

main "$@"
