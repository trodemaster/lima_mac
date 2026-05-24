# Upstream Lima GUI Test

Testing whether upstream lima (no app bundle) can display a macOS VZ GUI window
on macOS 26 (Tahoe). Goal: confirm whether Lima.app bundle is required, or whether
it works without one (which would simplify upstreaming G2).

## Test environment

| | |
|-|-|
| **Host OS** | macOS 26 (Tahoe) |
| **Host arch** | aarch64 (Apple Silicon) |
| **Lima version** | 2.1.1 (upstream, from MacPorts blakeports) |
| **Lima install** | `/opt/local/bin/limactl` (no app bundle) |
| **VM config** | `macos-26.yaml` (VZ, Darwin guest, `video: display: "default"`) |
| **VM instance** | `macos-26` |

## Background

`lima-macos26-gui-issue.md` documents a SIGTRAP crash when starting a macOS VZ GUI
VM with a bare CLI binary on macOS 26. The hypothesis was that macOS 26 requires
the process creating a `VZVirtualMachineView` to be inside a registered `.app` bundle.

A lima GitHub issue showed a user running a macOS VM in a window with upstream lima.
This test determines whether that was on macOS 15 (where the bundle is not required)
or whether the requirement has changed/relaxed in recent upstream.

## Test procedure

```sh
# Confirm upstream lima (no app bundle)
limactl --version
ls /Applications/Lima.app 2>/dev/null || echo "No Lima.app — confirmed bare binary"

# Start the VM and observe
limactl start macos-26
```

Watch for:
- SIGTRAP / `startVirtualMachineWindow` crash → app bundle IS required
- GUI window appears → app bundle NOT required (re-evaluate G2)
- Different error → investigate separately

## Results

<!-- fill in after test -->

**Date:**
**Outcome:**
**Relevant log output:**

## Conclusion

<!-- fill in after test -->
