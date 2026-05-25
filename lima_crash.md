# Lima macOS 26 Guest — SIGTRAP Crash Investigation

**Date**: 2026-03-28
**Host**: macOS 26.4 (Apple Silicon, arm64, Darwin 25.4.0)
**Lima version**: v2.1.0-30-g17afd7a8 (dev build from `~/Developer/lima`)
**Binary**: `~/Developer/lima/_output/bin/limactl`
**VM config**: `~/Developer/lima_mac/macos-26.yaml`

---

## Current Status

**App bundle implemented — GUI window working on macOS 26+.**
The fork (`trodemaster/lima`, branch `feat/macos-vz-gui-appbundle`) builds `Lima.app`, a minimal
macOS app bundle wrapping the `limactl` binary. On macOS 26+, the hostagent is automatically
re-launched inside `Lima.app` via `open -a` when starting a VM with `video.display = "default"`.
The Window Server accepts the connection; the `VZVirtualMachineView` window appears normally.

The `lima-devl` MacPorts port (blakeports) installs this fork with `Lima.app` to
`/Applications/MacPorts/Lima.app`.

```bash
# Start VM — Lima.app bundle used automatically on macOS 26+
limactl start macos-26

# Access
limactl shell macos-26
```

The headless workaround (`canRunGUI()` OS version check) was an interim measure and is no longer
used. See [Actual Implementation](#actual-implementation) below.

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

## Actual Implementation

The implemented approach is simpler than the original XPC plan. Instead of a separate display
process, `Lima.app` is a minimal bundle whose executable **is** `limactl` itself. The hostagent
re-launches itself inside the bundle via `open -a` when GUI is needed.

### Architecture

```
limactl start (CLI)
    │
    └── detects: WantsGUI && !runningInsideBundle
            │
            └── open -n -a Lima.app --stdout <log> --stderr <log> --args hostagent ...
                    │
                    └── limactl hostagent (re-launched inside Lima.app bundle context)
                            ├── Window Server connection succeeds
                            ├── Owns VZVirtualMachine instance
                            ├── Calls StartGraphicApplication → VZVirtualMachineView window appears
                            └── Monitored via PID file as normal
```

`open` exits immediately for `LSUIElement` apps. The hostagent process runs normally; `limactl start`
monitors it via PID file as it always did.

### Lima.app bundle structure

```
Lima.app/
└── Contents/
    ├── Info.plist          ← CFBundleIdentifier, LSUIElement=true, CFBundleExecutable=limactl
    └── MacOS/
        └── limactl         ← copy of the limactl binary
```

### Info.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>io.lima-vm.lima</string>
    <key>CFBundleName</key>
    <string>Lima</string>
    <key>CFBundleExecutable</key>
    <string>limactl</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
</dict>
</plist>
```

`LSUIElement=true` makes Lima an agent app — no Dock icon, no menu bar. The bundle is codesigned
ad-hoc with the `com.apple.security.virtualization` entitlement already required by the VZ driver.

### Key source files in the fork

| File | Role |
|------|------|
| `pkg/driver/vz/Info.plist` | Plist template for Lima.app |
| `pkg/driver/vz/vz_driver_darwin.go` | `canRunGUI()` — detects `.app/Contents/MacOS/` in exec path |
| `pkg/instance/start_appbundle_darwin.go` | `launchHostAgentInAppBundle()` — calls `open -n -a Lima.app ...` |
| `pkg/instance/start.go` | Decides whether to re-launch in bundle |
| `cmd/limactl/main_darwin_gui.go` | `init()` — pins main goroutine to OS thread 0 |
| `Makefile` | `Lima.app` build target, `APP_BUNDLE_DIR` variable |

### Thread pinning requirement

A second SIGTRAP occurs inside the bundle if the main goroutine is not on thread 0. Go's scheduler
migrates it to a worker thread before cobra dispatches `hostagent`. Fixed by:

```go
// cmd/limactl/main_darwin_gui.go — runs before main()
func init() {
    runtime.LockOSThread()
}
```

### Upstream status

The fix is implemented in `trodemaster/lima` (`feat/macos-vz-gui-appbundle`). Upstream PRs are
tracked in `lima-devl/UPSTREAM_PRS.md`. The issue is documented and a comment with root cause
and fix details has been posted at https://github.com/lima-vm/lima/issues/4743.

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
