# Lima macOS 26 Guest — SIGTRAP Crash Investigation

**Date**: 2026-03-28
**Host**: macOS 26.4 (Apple Silicon, arm64, Darwin 25.4.0)
**Lima version**: v2.1.0-30-g17afd7a8 (dev build from `~/Developer/lima`)
**Binary**: `~/Developer/lima/_output/bin/limactl`
**VM config**: `~/Developer/lima_mac/macos-26.yaml`

---

## Current Status

**VM is working headlessly.** The fix skips the GUI window on macOS 26+ hosts. The VM boots, SSH works, and the guest macOS 26 runs normally. A GUI window does not appear.

```bash
# Start (from Terminal.app)
~/Developer/lima/_output/bin/limactl start --foreground macos-26

# Access (from any terminal)
~/Developer/lima/_output/bin/limactl shell macos-26
```

**Remaining work**: Build a proper `.app` bundle wrapper to restore the GUI window. See [App Bundle Plan](#app-bundle-plan-for-restoring-gui) below.

---

## Applied Fix (headless workaround)

**File**: `~/Developer/lima/pkg/driver/vz/vz_driver_darwin.go`
**Function**: `canRunGUI()`

```go
func (l *LimaVzDriver) canRunGUI() bool {
    switch *l.Instance.Config.Video.Display {
    case "vz", "default":
        // On macOS 26+, the Virtualization.framework's GUI window
        // triggers a SIGTRAP when called from a non-bundled CLI binary.
        ver, err := osutil.ProductVersion()
        if err == nil && ver.Major >= 26 {
            logrus.Debug("Skipping GUI on macOS 26+ (CLI process cannot create windows; use SSH)")
            return false
        }
        return true
    default:
        return false
    }
}
```

When `canRunGUI()` returns `false`, `hostagent.go:478-487` calls `startRoutinesAndWait()` on the main goroutine instead of `RunGUI()`. The `VZMacGraphicsDeviceConfiguration` hardware is still present (configured in `attachDisplay` — macOS requires it to boot), but no Cocoa window or `[NSApp run]` is invoked.

**Vendor-vz changes**: Reverted to upstream Code-Hex/vz state. The `go.mod` `replace` directive (`github.com/Code-Hex/vz/v3 => ./vendor-vz`) is still in place but the ObjC source is unmodified. The `vendor-vz/` directory can be removed and the replace directive deleted once the fix is upstreamed or if you stop needing a local fork.

### How to rebuild

```bash
cd ~/Developer/lima
CGO_ENABLED=1 go build -o _output/bin/limactl ./cmd/limactl
codesign --sign - --entitlements vz.entitlements --force _output/bin/limactl
```

(`make` also works but prints an xcodebuild SDK warning that can be ignored — the Go build still succeeds.)

---

## Root Cause (fully traced)

### The crash is NOT in `[NSApp run]`

Earlier analysis blamed `[NSApp run]` → `[self finishLaunching]`. Detailed tracing proved this was wrong. The actual crash points are **inside the `AppDelegate initWithVirtualMachine:` method** in `virtualization_view.m`, specifically:

1. **`view.capturesSystemKeys = YES`** — Tries to register a global event tap with the Window Server. On macOS 26, non-bundled CLI processes lack the entitlements/permissions for this. SIGTRAP fires immediately.

2. **`view.virtualMachine = _virtualMachine`** — Connects the `VZVirtualMachineView` to the VM framebuffer, triggering Metal/Core Animation layer creation that requires a Window Server display context. SIGTRAP fires asynchronously.

3. **`[self finishLaunching]`** (in `VZApplication run`) — Also SIGTRAPs independently if reached, but was a secondary crash point.

### Why it's non-deterministic

The SIGTRAP at address `0x18d9ee4fc` is a `brk #0` instruction (arm64 software breakpoint) inside an Apple framework. It fires **asynchronously** — the Window Server connection triggers a Mach message callback that hits the assertion at whatever point the main thread happens to be executing. This is why:

- The crash always has the same PC (`0x18d9ee4fc`)
- But it hits different lines of our code each run
- Adding debug logging (NSLog/fprintf) changes timing and can make it "work" sometimes

### Why macOS 26 is different

macOS 26 (Tahoe) tightened Window Server requirements for non-bundled processes. On macOS 15 and earlier, a CLI binary could call `[NSApp run]`, create `NSWindow`, and interact with the Window Server without issue. On macOS 26:

- `TransformProcessType` (deprecated PSN API) — **does not fix it**
- `[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]` — **does not fix it**
- `[NSApp activateIgnoringOtherApps:YES]` — **does not fix it**
- Deferring GUI creation to `dispatch_async(dispatch_get_main_queue(), ...)` inside the event loop — **does not fix it**
- Skipping `[self finishLaunching]` — avoids one crash point but others remain

The only approaches that can work are:
1. **Don't create GUI objects at all** (current fix)
2. **Use a proper `.app` bundle** (see below)

### Crash evidence

```
SIGTRAP: trace trap
PC=0x18d9ee4fc m=9 sigcode=0
signal arrived during cgo execution

goroutine 1 gp=... m=9 [syscall, locked to thread]:
  runtime.cgocall(...)
  github.com/Code-Hex/vz/v3._Cfunc_startVirtualMachineWindow(...)
  github.com/Code-Hex/vz/v3.(*VirtualMachine).StartGraphicApplication(...)
  github.com/lima-vm/lima/v2/pkg/driver/vz.(*LimaVzDriver).RunGUI(...)
  github.com/lima-vm/lima/v2/pkg/hostagent.(*HostAgent).Run(...)
```

The `limactl` binary entitlements (from `vz.entitlements`):
```
com.apple.security.network.client = true
com.apple.security.network.server = true
com.apple.security.virtualization = true
```

Missing: no GUI/AppKit entitlements, no `Info.plist`, no bundle structure, no LaunchServices registration.

---

## Attempted Fixes (chronological)

| # | Approach | Result |
|---|----------|--------|
| 1 | Skip GUI — `canRunGUI()` returns `false` | VM boots headless, SSH works. No window. |
| 2 | `TransformProcessType` before `sharedApplication` | Still SIGTRAPs |
| 3 | `setActivationPolicy:NSApplicationActivationPolicyRegular` | Still SIGTRAPs |
| 4 | `activateIgnoringOtherApps:YES` | Still SIGTRAPs |
| 5 | Skip `[self finishLaunching]` on macOS 26 | Avoids one trap, but `capturesSystemKeys` and `view.virtualMachine=` still trap |
| 6 | Skip `capturesSystemKeys` on macOS 26 | Avoids that trap, but `view.virtualMachine=` and other AppKit calls still trap non-deterministically |
| 7 | Defer all GUI creation to `dispatch_async(main queue)` | Still SIGTRAPs — the event loop running doesn't help |
| 8 | `usleep(200ms)` delay after activation | Still SIGTRAPs |
| 9 | `[[NSRunLoop currentRunLoop] runUntilDate:]` delay | Still SIGTRAPs |
| 10 | **Skip GUI entirely** (`canRunGUI()` version check) | **Working fix.** VM runs headless reliably. |

---

## App Bundle Plan for Restoring GUI

To show a VM window on macOS 26, the process creating `VZVirtualMachineView` and calling `[NSApp run]` **must** be a proper `.app` bundle registered with LaunchServices. The `limactl` hostagent should remain a CLI process.

### Architecture

```
limactl hostagent (CLI process)
    │
    ├── Manages VM lifecycle (start, stop, SSH, networking)
    ├── Owns the VZVirtualMachine instance
    │
    └── Spawns: LimaDisplay.app (GUI process)
            │
            ├── Proper .app bundle with Info.plist
            ├── Receives VM handle from hostagent
            ├── Creates VZVirtualMachineView + NSWindow
            └── Runs [NSApp run] event loop
```

### Communication mechanism: XPC or Mach ports

The `VZVirtualMachine` object lives in the hostagent process. The display app needs to render its framebuffer. Two options:

**Option A — IOSurface sharing (recommended)**
Virtualization.framework internally uses IOSurface for the framebuffer. The hostagent can extract the IOSurface ID from the `VZMacGraphicsDeviceConfiguration` and pass it to the display app via XPC. The display app renders the IOSurface in a CALayer. This is how UTM works.

**Option B — VZVirtualMachine in the GUI process**
Move the `VZVirtualMachine` creation into the display app entirely. The hostagent spawns the display app, which creates and owns the VM. The hostagent communicates with the display app via XPC for lifecycle management (stop, pause, resume). This is simpler but means the VM dies if the window is closed.

### Minimal `.app` bundle structure

```
LimaDisplay.app/
├── Contents/
│   ├── Info.plist
│   ├── MacOS/
│   │   └── LimaDisplay          ← native binary (Swift or ObjC)
│   └── Resources/
│       └── MainMenu.nib         ← optional, can be created programmatically
```

### Info.plist (minimum required)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>io.lima-vm.display</string>
    <key>CFBundleName</key>
    <string>Lima Display</string>
    <key>CFBundleExecutable</key>
    <string>LimaDisplay</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
</dict>
</plist>
```

### Entitlements for the display app

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.virtualization</key>
    <true/>
</dict>
</plist>
```

### Skeleton Swift implementation

```swift
// LimaDisplay/main.swift
import Cocoa
import Virtualization

@main
class LimaDisplayApp: NSApplication {
    // Entry point. The app is launched by the hostagent via:
    //   open -a LimaDisplay.app --args --xpc-service-name <name>
    // or by NSWorkspace.shared.openApplication(...)
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var vmView: VZVirtualMachineView!

    // Option A: receive IOSurface ID via XPC from hostagent
    // Option B: receive VM configuration via XPC, create VM here

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Connect to hostagent's XPC service
        let connection = NSXPCConnection(serviceName: "io.lima-vm.hostagent")
        // ... negotiate VM handle or IOSurface ...

        // Create the view and window
        vmView = VZVirtualMachineView()
        vmView.capturesSystemKeys = true
        // vmView.virtualMachine = <received VM>

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1920, height: 1200),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = vmView
        window.title = "Lima: macos-26"
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}
```

### Build integration

The display app would be built as part of Lima's `make` target and installed to `_output/share/lima/LimaDisplay.app`. The hostagent would locate it at runtime:

```go
// In RunGUI(), instead of calling StartGraphicApplication directly:
displayApp := filepath.Join(usrShareDir, "LimaDisplay.app")
cmd := exec.Command("open", "-a", displayApp, "--args",
    "--xpc-service", xpcServiceName,
    "--vm-id", vmID,
)
cmd.Run()
```

### Reference implementations

- **UTM** (`utmapp/UTM`) — Uses a separate `UTMQemuSystem` process for the hypervisor and an `NSApp`-based frontend for display. Communicates via `QEMULauncher` (XPC). The display renders the VM framebuffer via `MTKView` with IOSurface.
- **macOS Virtualization.framework sample** (`apple/swift-evolution`) — Apple's sample code creates the `VZVirtualMachine` and `VZVirtualMachineView` in the same `.app` bundle process.
- **tart** (`cirruslabs/tart`) — Another CLI tool that uses VZ. On macOS 15 it calls `[NSApp run]` from the CLI binary. May also break on macOS 26.

---

## Relevant Source Files

| File | Notes |
|------|-------|
| `~/Developer/lima/pkg/driver/vz/vz_driver_darwin.go` | `canRunGUI()` **(patched — macOS 26 version check)**, `RunGUI()`, `attachDisplay()` |
| `~/Developer/lima/pkg/driver/vz/vm_darwin.go` | `startVM()`, `virtualMachineWrapper`, `createVM()` |
| `~/Developer/lima/pkg/hostagent/hostagent.go` | `Run()` — decides whether to call `RunGUI()` or `startRoutinesAndWait()` |
| `~/Developer/lima/pkg/instance/start_unix.go` | `execHostAgentForeground()` — uses `syscall.Exec` for `--foreground` |
| `~/Developer/lima/pkg/instance/start.go` | `haCmd = exec.CommandContext(...)` — normal (background) launch path |
| `~/Developer/lima/vendor-vz/virtualization_12.m` | ObjC `startVirtualMachineWindow` — where `[NSApp run]` is called |
| `~/Developer/lima/vendor-vz/virtualization_view.m` | `VZApplication` (NSApp subclass), `AppDelegate`, `VZVirtualMachineView` setup |
| `~/Developer/lima_mac/macos-26.yaml` | VM configuration |

---

## Past Chat Transcripts

- [macOS 26 VM setup & crash](6ab6b466-c8f2-45e2-b984-71bd47e50a0e) — Full session covering initial setup, chezmoi integration, IPSW selection, crash diagnosis, and the `--foreground` discovery
- 2026-03-28 session — Detailed tracing of crash points, tested 10 approaches, applied headless fix, documented app bundle plan
