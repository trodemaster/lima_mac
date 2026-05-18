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
Space Gray solid color is ~167 KB. Always take a screenshot before and after GUI operations
to confirm the result.

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

The working pattern is a temporary LaunchAgent bootstrapped into `gui/<uid>`. launchd
spawns it with no sshd ancestor, so CGEvents reach the GUI session:

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

Bootstrap the LaunchAgent **before** triggering the action that will show the dialog. The
`sleep N` in the script gives the dialog time to appear; then cliclick fires into it.

Clean up after use:

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

`osascript` can open Terminal and pass a command string directly via `do script`. This is
the cleanest way to run arbitrary commands in the GUI session — no need to type via
cliclick. The command runs as the logged-in GUI user with full Aqua context.

### Step 1 — handle the TCC consent dialog (first run only)

The first time osascript controls Terminal, macOS shows a consent dialog:
"sshd-keygen-wrapper wants access to control Terminal". Bootstrap a cliclick LaunchAgent
to approve it, then immediately call osascript:

```bash
# Bootstrap cliclick to approve the upcoming dialog
limactl shell <instance> -- bash -c '
cat > /tmp/lima-click.sh << "SCRIPT"
#!/bin/bash
sleep 3 && /opt/local/bin/cliclick kp:tab kp:return
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

# Trigger the osascript — dialog appears, cliclick approves it after 3s
limactl shell <instance> -- bash -c '
sudo launchctl asuser $(id -u) sudo -u $(whoami) osascript \
  -e "tell application \"Terminal\" to do script \"sudo -i; whoami\""
'

# Clean up
limactl shell <instance> -- bash -c '
launchctl bootout gui/$(id -u)/com.lima.click 2>/dev/null || true
rm -f /tmp/lima-click.sh /tmp/com.lima.click.plist
'
```

**Important:** if the dialog appears and osascript is still waiting, the command will
succeed after cliclick approves — do not cancel. The TCC grant persists permanently
(`auth_reason=3`) so the dialog only appears once per client/target pair.

### Step 2 — subsequent runs (TCC already approved)

Once Terminal's AppleEvents permission is granted, call osascript directly:

```bash
limactl shell <instance> -- bash -c '
sudo launchctl asuser $(id -u) sudo -u $(whoami) osascript \
  -e "tell application \"Terminal\" to do script \"<your command here>\""
'
```

### Step 3 — bring Terminal to front

After `do script`, Terminal may not be visible. Activate it:

```bash
limactl shell <instance> -- bash -c '
sudo launchctl asuser $(id -u) sudo -u $(whoami) osascript \
  -e "tell application \"Terminal\" to activate"
'
```

Then take a screenshot to read the output.

### Privileged shell via sudo -i

`tell application "Terminal" to do script "sudo -i; whoami"` opens a root shell directly.
Since sudo is passwordless in these VMs (`/etc/sudoers.d/admin`), no password prompt
appears. The Terminal window will show `root#` prompt and `root` as the whoami output.

---

## osascript for other GUI operations

For AppleEvents operations (Finder, System Settings, etc.) use the same `run_in_gui_session`
pattern — `sudo launchctl asuser` for the gui bootstrap namespace, `sudo -u` for the
correct UID:

```bash
limactl shell <instance> -- bash -c '
sudo launchctl asuser $(id -u) sudo -u $(whoami) osascript -e \
  "tell application \"Finder\" to set desktop picture to POSIX file \"/path/to/image\""
'
```

AppleEvents requests show a consent dialog on first use (cliclick can approve it);
subsequent calls succeed silently.

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
| TCC consent dialogs | cliclick LaunchAgent `kp:tab kp:return` to approve |
| Privileged shell | `osascript do script "sudo -i"` in Terminal (passwordless sudo) |
| Screen lock / screensaver | `defaults write` via SSH (no GUI session needed) |
| Auto-login (`sysadminctl` fails from SSH) | Write `/etc/kcpassword` directly |
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

# Check TCC grants for AppleEvents
limactl shell <instance> -- bash -c '
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT service,client,indirect_object_identifier,auth_value,auth_reason FROM access WHERE service=\"kTCCServiceAppleEvents\";"
'

# View cliclick/tccd events in system log (run after a cliclick operation)
limactl shell <instance> -- bash -c '
log show --last 2m --predicate "process == \"cliclick\" OR process == \"tccd\"" --style syslog 2>/dev/null | tail -30
'
```
