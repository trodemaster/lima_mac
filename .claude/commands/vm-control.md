# VM Control Skill

Tools and techniques for inspecting and manipulating Lima macOS guest VMs from the host.

## Core primitives

### SSH shell
```bash
limactl shell <instance> -- bash -c '<command>'
```
Runs a command inside the VM as the guest user (e.g. `blake`, UID 501). The shell is an
SSH session — it is in a separate security session from the Aqua GUI and cannot post
CGEvents or use AppleEvents directly (see constraints below).

### Screenshot
```bash
limactl screenshot <instance> --output /tmp/shot.png
```
Captures the Lima.app window. The image includes a ~52px title bar at the top; VM screen
coordinates start 52px below the screenshot top edge. Display is 1920×1200 at scale 1.0
(not HiDPI). File size is a useful signal: the Tahoe lake default wallpaper is ~2.3 MB;
Space Gray solid color is ~167 KB.

### Check running instances
```bash
limactl list
```

---

## GUI automation via cliclick

`cliclick` (`/opt/local/bin/cliclick`) is installed via MacPorts in all VM builds. It
sends keyboard and mouse events through the CGEvent system. It has `kTCCServiceAccessibility`
pre-granted in the system TCC DB.

### Key constraint: LaunchAgent required for CGEventPost

SSH sessions trace their ancestry to `sshd-keygen-wrapper` (a platform binary). tccd
auto-denies `kTCCServicePostEvent` for any process in that ancestry chain with no prompt.
**Direct `cliclick` calls from SSH do not deliver key events to the GUI session.**

The working pattern is a temporary LaunchAgent bootstrapped into `gui/<uid>`:

```bash
limactl shell <instance> -- bash -c '
cat > /tmp/lima-click.sh << "SCRIPT"
#!/bin/bash
sleep 5 && /opt/local/bin/cliclick kp:tab kp:return
SCRIPT
chmod +x /tmp/lima-click.sh
cat > /tmp/com.lima.click.plist << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.lima.click</string>
    <key>ProgramArguments</key>
    <array><string>/bin/bash</string><string>/tmp/lima-click.sh</string></array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
sudo launchctl bootstrap gui/$(id -u) /tmp/com.lima.click.plist
'
```

The LaunchAgent is spawned by launchd with no sshd ancestor — CGEvents reach the GUI
session. Clean up after use:

```bash
limactl shell <instance> -- bash -c '
launchctl bootout gui/$(id -u)/com.lima.click 2>/dev/null || true
rm -f /tmp/lima-click.sh /tmp/com.lima.click.plist
'
```

### cliclick key names
`kp:<key>` sends a keypress. Common keys: `return`, `tab`, `space`, `escape`,
`arrow-left`, `arrow-right`, `arrow-up`, `arrow-down`, `f1`–`f15`.

### Full Keyboard Access
Full Keyboard Access (FKA) is enabled on all VM builds (`AppleKeyboardUIMode=3`). With
FKA on, `kp:tab` cycles through **all** controls in a dialog including buttons — no mouse
required. This makes dialog navigation reliable and position-independent.

---

## Opening a privileged Terminal shell

Opening Terminal and typing commands gives a highly privileged interactive shell on the
system that bypasses many SSH-context restrictions:

```bash
# 1. Open Terminal via osascript (requires AppleEvents TCC — triggers consent dialog
#    on first run; cliclick LaunchAgent above handles the approval automatically)
limactl shell <instance> -- bash -c '
sudo launchctl asuser $(id -u) sudo -u $(whoami) osascript -e "tell application \"Terminal\" to do script \"\""
'

# 2. Use cliclick LaunchAgent to type a command into the Terminal window
#    (bootstrap plist as above, with desired command in the script)
```

Once a Terminal window is open and focused, cliclick can type arbitrary text and press
Return to execute commands as the logged-in GUI user — outside the SSH security session,
with access to the full Aqua environment.

---

## osascript from SSH

For AppleEvents operations (setting wallpaper, controlling Finder, etc.) use the
`run_in_gui_session` pattern to get the correct bootstrap namespace and UID:

```bash
limactl shell <instance> -- bash -c '
sudo launchctl asuser $(id -u) sudo -u $(whoami) osascript -e \
  "tell application \"Finder\" to set desktop picture to POSIX file \"/path/to/image\""
'
```

This works because AppleEvents requests do show a consent dialog (which cliclick can
approve), unlike `kTCCServicePostEvent` which is silently auto-denied from SSH ancestry.

---

## Navigating security dialogs

With FKA enabled, the standard TCC consent dialog layout is:
- Default focus: **"Don't Allow"** (left button)
- `kp:tab` → moves focus to **"Allow"** (right button)
- `kp:return` → activates the focused button

For System Settings panels and other dialogs, use `kp:tab` to cycle through controls and
`kp:space` or `kp:return` to activate them. Take a screenshot before and after to confirm.

---

## Working around macOS security restrictions

The combination of these tools can configure many settings that are normally blocked from
headless SSH contexts:

| Restriction | Technique |
|---|---|
| TCC consent dialogs | cliclick LaunchAgent sends `kp:tab kp:return` to approve |
| Screen lock / screensaver | `defaults write` via SSH (no GUI session needed) |
| Auto-login (`sysadminctl` fails from SSH) | Write `/etc/kcpassword` directly via `configure.sh` |
| Energy saver / App Nap | `pmset` + `defaults write` via SSH |
| System Settings toggles | osascript or cliclick Tab/Space via LaunchAgent |
| Analytics/diagnostics consent | Write `DiagnosticMessagesHistory.plist` via SSH |

---

## Timing and session readiness

Before triggering GUI operations, confirm the Aqua session is active:

```bash
limactl shell <instance> -- bash -c '
until [[ "$(stat -f %Su /dev/console)" == "$(whoami)" ]]; do sleep 5; done
echo "GUI session ready"
'
```

`stat -f %Su /dev/console` returns the user who owns the console login session. Once it
matches the current user, the desktop is up and cliclick events will be delivered.

---

## Debugging

```bash
# Check if Dock is running (confirms GUI session)
limactl shell <instance> -- bash -c 'pgrep -x Dock && echo "GUI up"'

# Check console session owner
limactl shell <instance> -- bash -c 'stat -f %Su /dev/console'

# Check TCC grants for a service
limactl shell <instance> -- bash -c '
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT service,client,auth_value,auth_reason FROM access WHERE service=\"kTCCServiceAppleEvents\";"
'

# View cliclick/tccd events in system log
limactl shell <instance> -- bash -c '
log show --last 2m --predicate "process == \"cliclick\" OR process == \"tccd\"" --style syslog 2>/dev/null | tail -30
'
```
