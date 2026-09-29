# macOS 27 Beta Workarounds

Temporary workarounds for running macOS 27 beta guests on a macOS 26 host.
The goal is resilience — workarounds are non-fatal where possible so that
individual beta regressions don't block the whole provisioning flow.

**Remove when:** Apple ships a stable macOS 27 release (or fixes the underlying bug in a beta).

---

## 1. Lima: DFU install via MobileDevice.framework — REMOVED 2026-07-25

**Where:** `lima-devl` branch `upstream-pr/b3-dfu-beta27`
(`pkg/driver/vz/macos27_dfu_install_darwin_arm64.{go,m,h}`)

**Bug:** `VZMacOSInstaller` (Virtualization.framework high-level API) fails when the
guest IPSW version > host OS. Attempting a normal `limactl create` / `limactl start`
on a macOS 27 IPSW from a macOS 26 host fails with `VZErrorDomain Code=10007` /
`AMRestorePerformRestoreModeRestoreWithError failed with error: 11` before install
completes (confirmed error text as of 2026-07-23; earlier notes described this more
vaguely before the exact error was captured).

**Workaround:** When the guest OS version exceeds the host, skip `VZMacOSInstaller`
and instead:
1. Boot the VM into DFU mode using the private `_forceDFU` property on
   `VZMacOSVirtualMachineStartOptions` (setter: `_setForceDFU:`)
2. Wait for the VM to appear as a DFU device via `AMRestorableDeviceRegisterForNotifications`
3. Drive the restore with `AMRestorableDeviceRestore` (async, void-returning) using
   `MobileDevice.framework` private SPI, matching the options used by Finder/Apple
   Configurator for physical Mac restores
4. Wait for "Successful" terminal status via the progress callback before continuing

**Removed:** host reached stable **macOS 26.6** (25G70) on 2026-07-25. Re-tested against
the same beta-4 IPSW with a throwaway instance: `VZErrorDomain Code=10007` is gone — the
standard `VZMacOSInstaller` path now runs past the point that used to fail, confirming the
bug this workaround existed for is fixed on the host side. `patch-08-b3-dfu-beta27.diff` is
disabled in the Portfile; branch/code removal cleanup is tracked separately. Full test log:
see [dfu-install.md § 2026-07-25 Removal Confirmed](dfu-install.md#2026-07-25-removal-confirmed).

---

## 2. macports.sh: PKG name lookup must not abort on no-match grep

**Where:** `lima_mac/macports.sh` — `install_macports()`, PKG asset lookup pipeline

**Bug:** Under `set -euo pipefail`, a `grep` that matches nothing exits 1. When no
MacPorts binary PKG exists for macOS 27, the grep filtering for
`MacPorts-*-27-*.pkg` found nothing, exiting 1 and aborting the script before
reaching the build-from-source fallback.

**Workaround:** `|| true` appended to the pipeline so an empty result is valid and
falls through to the build-from-source branch.

**Remove when:** MacPorts publishes an official binary PKG for macOS 27
(or when macOS 27 is no longer beta and is added to the MacPorts release matrix).

---

## 3. macports.sh: CLT idempotency check must test xcode-select, not directory

**Where:** `lima_mac/macports.sh` — `install_clt()` guard

**Bug:** On macOS 27 beta, the DFU install process leaves
`/Library/Developer/CommandLineTools` as a stub directory containing only a `.beta`
marker file. The old `[[ -d /Library/Developer/CommandLineTools ]]` check saw the
directory and skipped CLT installation. With no real tools present, `xcode-select -p`
returned an error and clang could not compile — causing MacPorts `./configure` to
fail with "C compiler cannot create executables."

**Workaround:** Changed the guard to `xcode-select -p &>/dev/null`, which exits 0
only when a real active developer directory is configured.

**Remove when:** The stub directory issue no longer occurs after DFU install (Apple
may fix this in a later beta), or if the stub is never created in the first place on
stable macOS 27.

---

## 4. macports.sh: cliclick install is non-fatal

**Where:** `lima_mac/macports.sh` — `main()`, `port install cliclick` step

**Bug:** The `cliclick` MacPorts port uses the `xcode` PortGroup, which requires
a full Xcode installation (`xcodebuild`). On macOS 27 beta with CLT only,
MacPorts reports `Xcode none` and refuses to install the port.

**Workaround:** The `port install cliclick` step is wrapped with `|| log_warn …` so
a failure is logged but does not abort provisioning. GUI automation steps in
`configure.sh` that depend on `cliclick` may not function until this is resolved.

**Remove when:** Either MacPorts updates the `cliclick` port to build with CLT only,
or a full Xcode app is available for macOS 27 beta, or an alternative GUI automation
tool replaces `cliclick` for runner setup.
