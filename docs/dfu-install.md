# macOS 27 Beta: DFU Install Workaround

**Status**: IMPLEMENTED — `lima-devl` branch `upstream-pr/b3-dfu-beta27`
(`pkg/driver/vz/macos27_dfu_install_darwin_arm64.{go,m,h}`)

**Remove when**: Apple fixes `VZMacOSInstaller` for cross-version installs (expected when
macOS 27 ships stable or Apple patches the framework in a later beta).

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
