# macOS 27 Beta: DFU Install Workaround

**Status**: IMPLEMENTED — `lima-devl` branch `upstream-pr/b3-dfu-beta27`
(`pkg/driver/vz/macos27_dfu_install_darwin_arm64.{go,m,h}`)

**Remove when**: the host is running **macOS 26.6 or later** (beta or GA — see "2026-07-23
Removal Test" below for why 26.6 specifically, and "Future Removal Procedure" for exact
steps). Confirmed still required as of 2026-07-23 with host on stable macOS 26.5.2.

---

## The Bug

`VZMacOSInstaller` (Apple's Virtualization.framework high-level installer API) fails when
the guest IPSW is macOS 27 beta and the host is running macOS < 27. This is a beta-specific
regression; the standard install path (`vz.NewMacOSInstaller → installer.Install`) breaks
before completing.

Lima's affected code path:
```
pkg/driver/vz/vm_darwin_arm64.go  installMacOS()
  vz.NewMacOSInstaller(vm, ipsw)
  installer.Install(ctx)
```

---

## How It Works (VirtualBuddy approach, now in Lima)

Instead of `VZMacOSInstaller`, Lima boots the VM into DFU mode and drives the
restore using `MobileDevice.framework` private SPI — the same mechanism used by Finder/
Apple Configurator to restore physical Macs via DFU.

### Step-by-step flow

1. **Boot VM in DFU mode**

   ```objc
   VZMacOSVirtualMachineStartOptions *opts = ...;
   // Try _setForceDFU: selector first (macOS 26+), fall back to KVC set_ForceDFU:
   [opts _setForceDFU:YES];
   [vm startWithOptions:opts completionHandler:…];
   ```

   The VM boots but does not continue to macOS recovery — it waits as a DFU device.

   **Selector note**: The actual private setter is `_setForceDFU:` (leading underscore, macOS 26).
   Lima tries this selector first via `performSelector:withObject:`, and falls back to
   `setValue:@YES forKey:@"_forceDFU"` (KVC) if the selector is absent. The `_-prefixed`
   *property* name on the Objective-C object is `_forceDFU` but the setter method is
   `_setForceDFU:` — KVC uses `set_ForceDFU:` (different capitalization) which works as
   an alternative accessor.

2. **Extract the VM's ECID**

   The `VZMacMachineIdentifier` serializes to a property list containing an `ECID` key (UInt64).
   Lima reads this from the `vz-identifier` file already on disk at `~/.lima/<name>/vz-identifier`:
   ```go
   func ecidFromIdentifierFile(path string) (uint64, error) {
       data, _ := os.ReadFile(path)
       var plist map[string]any
       // decode binary plist → extract "ECID" as uint64
   }
   ```

3. **Wait for the DFU device to appear**

   Poll `MobileDevice.framework` via `AMRestorableDeviceRegisterForNotifications` until a device
   with the matching ECID appears in `kAMRestorableDeviceStateDFU` state (typically < 5 seconds).

4. **Drive the restore with `AMRestorableDeviceRestore`**

   Call `AMRestorableDeviceRestore(device, options, progressCallback, refCon)` with a specific
   options dictionary:
   ```
   AuthInstallVariant:      "Customer Erase Install (IPSW)"
   AuthInstallSigningServerURL: "https://gs.apple.com:443"
   BootImageType:           "User"
   CreateFilesystemPartitions: true
   DFUFileType:             "RELEASE"
   EncryptDataPartition:    true
   FlashNOR:                true
   PostRestoreAction:       "Shutdown"
   ReadOnlyRootFilesystem:  true
   RestoreBundlePath:       <path to .ipsw>
   PersonalizedRestoreBundlePath: <scratch dir for personalization artifacts>
   RestoreBootArgs:         "debug=0x14e serial=3 rd=md0 nand-enable-reformat=1 -progress -restore"
   … (plus ~15 other restore options)
   ```
   The `AuthInstallSigningServerURL` call to `gs.apple.com` personalizes the IPSW to the specific
   virtual hardware ECID — this requires outbound HTTPS.

   `AMRestorableDeviceRestore` is **void-returning and async** — it fires the progress callback
   with status strings and a terminal "Successful" status. Lima waits on a channel for the
   terminal status before continuing.

5. **VM reboots and installs**

   After the restore call completes, the VM shuts itself down (`PostRestoreAction: Shutdown`).
   Subsequent boot uses the normal `VZMacOSBootLoader` path, exactly as before.

---

## Version Gate (when to use DFU path)

```go
// In installMacOS() / its caller:
ipswImage, _ := vz.LoadMacOSRestoreImageFromPath(ipsw)
guestMajor := ipswImage.OperatingSystemVersion().MajorVersion
hostMajor  := hostOSMajorVersion()  // sw_vers -productVersion
if guestMajor > hostMajor {
    return dfuInstallMacOS(ctx, inst, ipsw)
}
// existing VZMacOSInstaller path:
installer, err := vz.NewMacOSInstaller(vm, ipsw)
```

Guest OS version is read from `ipswImage.OperatingSystemVersion()` (available on the
`VZMacOSRestoreImage` object Lima already loads). See [ipsw-build-manifest.md](ipsw-build-manifest.md)
for alternative extraction via `BuildManifest.plist`.

---

## Entitlements Finding

**Result**: A developer-signed `limactl` binary can call `AMRestorableDeviceRegisterForNotifications`
and `AMRestorableDeviceRestore` **without** any special provisioning profile or private entitlement.
The calls succeed when the binary is ad-hoc signed or signed with a standard Developer ID.

This was the main unknown before implementation — confirmed by the working `upstream-pr/b3-dfu-beta27`
implementation running without entitlement additions.

---

## Post-DFU Side Effect: "Software Update Complete" Chain

After an IPSW DFU restore, macOS retains state that triggers a "Software Update Complete"
setup assistant sequence on every subsequent boot until Continue is clicked. This is an
additional challenge introduced by the DFU path — not present with `VZMacOSInstaller`.

See [macos-vm-boot-sequence.md § Post-DFU Restore Setup Chain](macos-vm-boot-sequence.md#post-dfu-chain)
for the full analysis and the `com.lima.kill-sa-chain` daemon solution implemented in `configure.sh`.

---

## Known Remaining Issues

- **`_setForceDFU:` stability**: Private API. If Apple renames it in a later macOS 27 beta,
  the KVC fallback (`set_ForceDFU:`) may or may not work depending on whether the property
  itself is renamed. Lima tries the selector first, so a rename would surface as a runtime
  panic/exception rather than a compile-time error.

- **Personalization server**: `gs.apple.com` must be reachable during install. Air-gapped
  environments cannot use this path. No known workaround.

- **VirtualBuddy reference**: VirtualBuddy PR #688 — "Implement custom virtual machine
  restore mechanism" — is the upstream reference for the options dictionary and overall
  architecture. Lima's implementation follows the same flow with Go/CGo instead of Swift/XPC.

---

## 2026-07-23 Removal Test

Attempted to drop the DFU workaround and use the standard `VZMacOSInstaller` path directly
against the macOS 27 beta 4 IPSW (`UniversalMac_27.0_26A5388g_Restore.ipsw`), on the theory
that a newer beta iteration plus updated Xcode device-support files might have resolved the
underlying Apple bug. Host was stable **macOS 26.5.2** (Build 25F84) at the time.

**Result: still fails**, with the standard installer path now producing a *different*,
more specific error than the original vague "installer fails" description above:

```
level=fatal msg="failed to install macOS: Error Domain=VZErrorDomain Code=10007
Description=\"An error occurred during installation. Installation failed.\"
UserInfo={
  NSLocalizedFailure = \"An error occurred during installation.\";
  NSLocalizedFailureReason = \"Installation failed.\";
  NSUnderlyingError = \"Error Domain=com.apple.MobileDevice.MobileRestore Code=-1
    \\\"AMRestorePerformRestoreModeRestoreWithError failed with error: 11\\\"
    UserInfo={NSLocalizedDescription=AMRestorePerformRestoreModeRestoreWithError failed
    with error: 11, NSLocalizedFailureReason=An unknown error occurred during
    installation.}\";
}"
```

The installer ran for ~3 minutes before failing (not an instant rejection), so this looks
like Apple's restore personalization/signing pipeline genuinely rejecting the cross-version
install, not a Lima-side bug.

### Root cause, per VirtualBuddy's own bug reports

[VirtualBuddy PR #706](https://github.com/insidegui/VirtualBuddy/pull/706) ("macos 27.0
beta 3") has a comment thread from user `DesWurstes` hitting the **identical error 10007**:

> "Waiting for xcode 27 beta 3 / edit: doesn't work even with that, error 10007"
>
> "installed xcode 27 beta 3 and its mobile support pkg on 26.5.2 host, didn't work,
> upgraded to **26.6b3**, redid it, successfully installed"

So the fix isn't just installing Xcode's device-support package for the guest OS — the
**host OS itself** needs to be on a beta that's version-adjacent to the guest (26.6 beta,
not stable 26.5.2). This matches [VirtualBuddy PR #555](https://github.com/insidegui/VirtualBuddy/pull/555),
which added an explicit `deviceSupportVersions` catalog entry and turned the mobile-device
min-version check into a hard `.unsupported` state (previously just a warning) — VirtualBuddy's
own maintainers treat "host too many versions behind guest" as a real, named failure mode,
not a fluke.

**Decision (2026-07-23):** wait for macOS 26.6 to reach GA (stable release) before revisiting
DFU removal. Enrolling the primary/daily-driver host in a beta channel just to drop this
workaround isn't worth it — 26.6 GA should arrive well before macOS 27 does anyway.

### Future Removal Procedure

Once the host is on macOS 26.6 (GA preferred; a 26.6 beta would also work per the
VirtualBuddy report above, if testing earlier is ever worth it):

1. Confirm host version: `sw_vers -productVersion` should read `26.6` or higher.
2. In `blakeports/sysutils/lima-devl/Portfile`, comment out `patch-08-b3-dfu-beta27.diff`
   from `patchfiles` (see the block already structured for this — O1/B4 are commented out
   the same way).
3. `sudo port uninstall lima-devl @<currently-active-version>` then
   `sudo port clean lima-devl && sudo port -v install lima-devl` — a plain `port install`
   without first uninstalling will often no-op if the version/revision string didn't change;
   see `sysutils/lima-devl/TODO.md` in blakeports for the MacPorts quirk.
4. Verify: `strings /opt/local/bin/limactl | grep -c "DFU install:"` should print `0`.
5. Test with a **throwaway instance name** first (`limactl create --tty=false
   --name=dfu-removal-test macos-27-beta.yaml && limactl start dfu-removal-test`), not the
   production `macos-27-beta` instance — if the standard installer still fails, you don't
   want to have already destroyed the working VM. Clean up with `limactl remove -f
   dfu-removal-test` regardless of outcome.
6. Only after the throwaway test succeeds: run the real `make rebuild-27-beta` to recreate
   the production instance, then delete `upstream-pr/b3-dfu-beta27` (branch + patch file)
   for real, following the lima-devl skill's branch-removal workflow (same pattern as the
   already-merged G1/G3/G4 patches).
7. **Before starting a throwaway test VM**: check `limactl list` and make sure no other
   32GB-class macOS guest is already running. A concurrent fresh macOS boot attempt under
   heavy memory pressure (observed 2026-07-23: 3 VMs running, ~74MB free out of 128GB) can
   crash the DFU install path with `SIGTRAP`/`SIGSEGV` — a red herring unrelated to whether
   DFU itself is still needed. Stop other VMs first if memory is tight.
