# macOS 26 (Tahoe): SIGTRAP crash when starting macOS guest VM with GUI display

## Summary

On macOS 26 (Tahoe), starting a macOS guest VM with `video: display: "default"` causes an
immediate `SIGTRAP` crash inside `startVirtualMachineWindow`. The process creating a
`VZVirtualMachineView` must run inside a registered `.app` bundle on macOS 26. The bare
`limactl hostagent` CLI binary no longer satisfies the Window Server connection requirements
introduced in macOS 26.

## Environment

| | |
|-|-|
| **Host OS** | macOS 26.x (Tahoe), Apple Silicon (arm64); confirmed on 26.4 (25E246) |
| **Lima** | v2.1.0 |
| **vmType** | `vz` |
| **os** | `Darwin` |
| **video** | `display: "default"` |

## Crash

```
[hostagent] SIGTRAP: trace trap
[hostagent] PC=0x18c5224fc m=8 sigcode=0
[hostagent] signal arrived during cgo execution

[hostagent] goroutine 1 [syscall, locked to thread]:
[hostagent] runtime.cgocall(...)
[hostagent]   github.com/Code-Hex/vz/v3._Cfunc_startVirtualMachineWindow(...)
[hostagent]   github.com/Code-Hex/vz/v3.(*VirtualMachine).StartGraphicApplication(...)
[hostagent]   github.com/lima-vm/lima/v2/pkg/driver/vz.(*LimaVzDriver).RunGUI(...)
[hostagent]   github.com/lima-vm/lima/v2/pkg/hostagent.(*HostAgent).Run(...)
```

The crash address (`0x18c5224fc`) is a `brk #0` instruction (arm64 software breakpoint)
inside a private Apple framework. It is triggered when the Window Server rejects the
connection from the non-bundled process.

## Root cause

[`NSApplication.shared`](https://developer.apple.com/documentation/appkit/nsapplication/shared)
"initializes the display environment and connects your program to the window server and the
display server." On macOS 26, that connection requires the calling process to be a registered
`.app` bundle — one with a valid `Info.plist` containing a `CFBundleIdentifier`, launched via
LaunchServices (`open -a` or `NSWorkspace`).

Apple's own reference implementation for macOS VMs,
[Running macOS in a virtual machine on Apple silicon](https://developer.apple.com/documentation/virtualization/running-macos-in-a-virtual-machine-on-apple-silicon),
has always structured the display side as a Mac app (`macOSVirtualMachineSampleApp`) — not a
CLI binary. macOS 26 enforces this as a hard requirement.

A bare CLI binary (`limactl hostagent`) satisfies neither condition. This worked on macOS 15
(Sequoia) and earlier. Apple has not explicitly documented this change in any macOS 26 release
notes; similar `EXC_BREAKPOINT`/`SIGTRAP` crashes in Cocoa/AppKit initialization have been
reported by the community since macOS 26.0/26.1 in other frameworks
([tauri-apps/tao#1171](https://github.com/tauri-apps/tao/issues/1171),
[electron/electron#49522](https://github.com/electron/electron/issues/49522)), indicating the
enforcement was present from the initial Tahoe release.

## Fix

The hostagent must be launched inside a proper `.app` bundle via `open -a` on macOS 26+. A
working proof-of-concept is available on a fork:
https://github.com/trodemaster/lima/tree/feat/macos-vz-gui-appbundle

The approach:

1. **Build `Lima.app`** — a minimal bundle containing a copy of `limactl` with an
   `Info.plist` (`LSUIElement=true`, `CFBundleIdentifier=io.lima-vm.lima`) codesigned ad-hoc
   with the `com.apple.security.virtualization` entitlement. See
   [`LSUIElement`](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement)
   for the agent app pattern.

2. **Detect bundle context at runtime** in `canRunGUI()` — return `true` only when the
   running executable path contains `.app/Contents/MacOS/`.

3. **Re-launch the hostagent inside the bundle** from `start.go` when `WantsGUI &&
   !CanRunGUI`, using `open -n -a Lima.app --stdout <path> --stderr <path> --args hostagent
   ...`. The `open` command exits immediately for `LSUIElement` apps; the hostagent process
   is then monitored via its PID file as normal.

4. **Pin the main goroutine to thread 0** by calling `runtime.LockOSThread()` from an
   `init()` function before `main()`. macOS requires all Cocoa and
   `Virtualization.framework` GUI calls to happen on the process's main OS thread. Without
   this, Go's scheduler migrates the main goroutine to a worker thread before cobra dispatches
   the `hostagent` subcommand, causing a second SIGTRAP even inside the bundle.

