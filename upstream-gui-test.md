# Upstream Lima GUI Test

Testing whether upstream lima (no app bundle) can display a macOS VZ GUI window
on macOS 26 (Tahoe). Goal: confirm whether Lima.app bundle is required, or whether
upstream 2.1.1 works without one (which would simplify upstreaming G2).

## Environment

| | |
|-|-|
| **Host OS** | macOS 26 (Tahoe) Apple Silicon |
| **Lima binary** | 2.1.1 upstream — `/opt/local/bin/limactl` (no Lima.app bundle) |
| **Instance** | `macos-26` — already exists, created with fork dev.13 |
| **Instance OS** | Darwin (`os: "Darwin"`, `vmType: "vz"`, `video: display: "default"`) |
| **Instance state** | Stopped |

Verify before testing:

```sh
limactl --version
# expect: limactl version 2.1.1

ls /Applications/MacPorts/Lima.app 2>/dev/null || ls /Applications/Lima.app 2>/dev/null || echo "confirmed — no Lima.app bundle"
```

## Known behavioral difference: nerdctl download

When starting the `macos-26` instance with upstream 2.1.1, lima downloads a Linux
nerdctl archive (`nerdctl-full-*-linux-arm64.tar.gz`) for a Darwin guest. The fork
skips this for `os: Darwin` instances. This is a separate issue from the GUI test —
let the download complete and continue watching for the GUI behavior.

## The GUI test

The `macos-26` instance was provisioned with the fork and has `video: display: "default"`.
On start, lima will attempt to open a `VZVirtualMachineView` GUI window. This is where
the SIGTRAP occurs (or doesn't) depending on whether a bundle context is required.

```sh
limactl start macos-26
```

Watch the output. Two outcomes:

**Outcome A — SIGTRAP crash (app bundle IS required)**
```
[hostagent] SIGTRAP: trace trap
[hostagent] runtime.cgocall(...)
[hostagent]   github.com/Code-Hex/vz/v3._Cfunc_startVirtualMachineWindow(...)
```
→ Confirms G2 is necessary. macOS 26 still enforces the bundle requirement.

**Outcome B — GUI window appears (app bundle NOT required)**  
→ Re-evaluate G2. Possibly Apple relaxed the requirement, or upstream found a
workaround. Check upstream release notes and the issue tracker for any relevant
changes between dev.13 and 2.1.1.

**Outcome C — Starts headless / no window**  
→ Check if upstream silently fell back to headless mode instead of crashing. Look
for a log line like "falling back to headless" or check if `video.display` was
honoured.

## If the instance has state issues

The existing `macos-26` was created with fork dev.13. If upstream 2.1.1 rejects it
due to format incompatibility, create a clean test instance:

```sh
# Create a fresh instance from the repo yaml (just for GUI test — skip full build)
limactl create --tty=false --name=macos-26-gui-test ~/Developer/lima_mac/macos-26.yaml

# Start and observe
limactl start macos-26-gui-test

# Cleanup when done
limactl stop -f macos-26-gui-test
limactl remove -f macos-26-gui-test
```

Note: a fresh instance requires downloading the macOS IPSW (~14 GB) and running
the initial provisioning before the GUI attempt. This takes time but is the cleanest test.

## Full Makefile build flow (for reference)

The `Makefile` drives a full VM build as follows. This is NOT needed for the GUI test —
only for rebuilding a CI runner from scratch.

```
make build-26
```

Which expands to:
1. `limactl create --tty=false --name=macos-26 macos-26.yaml`
2. `limactl start macos-26`          ← first boot / fakecloudinit runs
3. `limactl stop macos-26`
4. `limactl start macos-26`          ← second start (clean boot)
5. `os-update.sh macos-26`           ← macOS software update in guest
6. `limactl shell macos-26 /Volumes/lima_mac/macports.sh`  ← install MacPorts
7. `scripts/autologin-reboot.sh macos-26`  ← enable autologin, reboot
8. wait for virtiofs mount
9. `limactl shell macos-26 /Volumes/lima_mac/configure.sh wallpaper`
10. `configure.sh runner`             ← register GitHub Actions runner

Override the lima binary path for testing against a different build:
```sh
make build-26 LIMACTL=/path/to/custom/limactl
```

## Results

**Date:** 2026-05-24  
**Lima version:** 2.1.1 (upstream, no Lima.app bundle)  
**Outcome: A — SIGTRAP crash (app bundle IS required)**

```
[hostagent] SIGTRAP: trace trap
[hostagent] PC=0x185c584fc m=11 sigcode=0
[hostagent] signal arrived during cgo execution
[hostagent] goroutine 1 [syscall, locked to thread]:
[hostagent] runtime.cgocall(...)
[hostagent] github.com/Code-Hex/vz/v3._Cfunc_startVirtualMachineWindow(...)
[hostagent] github.com/Code-Hex/vz/v3.(*VirtualMachine).StartGraphicApplication(...)
[hostagent] github.com/lima-vm/lima/v2/pkg/driver/vz.(*LimaVzDriver).RunGUI(...)
[hostagent] github.com/lima-vm/lima/v2/pkg/hostagent.(*HostAgent).Run(...)
```

Crash occurs within ~1 second of start, immediately on `startVirtualMachineWindow`.
The VM itself boots (VZ state changes to `running`) but the hostagent dies before
SSH is even attempted.

## Conclusion

**G2 (macOS app bundle) is confirmed necessary on macOS 26 (Tahoe).**

Upstream lima 2.1.1 crashes with SIGTRAP on `startVirtualMachineWindow` without a
bundle context. macOS 26 Window Server enforcement is real and present in the current
upstream release. The upstream user seen running a macOS VM in a window was almost
certainly on macOS 15 (Sequoia), where no bundle is required.

G2 remains a required upstream contribution. Proceed with G1 (thread pin) → G2 (app bundle) as planned.
