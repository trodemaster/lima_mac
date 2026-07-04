# IPSW BuildManifest.plist

## File Format

An IPSW file is a standard ZIP archive. `BuildManifest.plist` is located at the root of the archive and can be extracted without downloading the full file.

## Top-Level Keys

| Key | Type | Example |
|-----|------|---------|
| `ManifestVersion` | Integer | `1` |
| `ProductVersion` | String | `27.0` |
| `ProductBuildVersion` | String | `26A5353q` |
| `SupportedProductTypes` | Array of Strings | `["Mac14,8", "VirtualMac2,1", ...]` |
| `BuildIdentities` | Array of Dicts | _(see below)_ |

`ProductVersion` and `ProductBuildVersion` at the top level are the canonical source for the macOS version of the image.

## BuildIdentity Structure

Each entry in `BuildIdentities` represents a specific hardware target. A Universal IPSW contains identities for every supported Mac model plus VM targets.

### Top-Level Identity Keys

| Key | Example |
|-----|---------|
| `Ap,ProductMarketingVersion` | `27.0` |
| `Ap,ProductType` | `VirtualMac2,1` |
| `Ap,Target` | `VMA2MACOSAP` |
| `Ap,TargetType` | `vma2macos` |
| `Ap,SDKPlatform` | `macosx` |
| `ApBoardID` | `0x20` |
| `ApChipID` | `0xFE00` |
| `ApSecurityDomain` | `0x01` |

### Info Sub-Dictionary Keys

| Key | Example |
|-----|---------|
| `BuildNumber` | `26A5353q` |
| `BuildTrain` | `FizzSeed` |
| `DeviceClass` | `vma2macosap` |
| `Variant` | `Customer Erase Install (IPSW)` |
| `RestoreBehavior` | `Erase` |
| `ImageName` | `UniversalMacRestoreIPSW` |
| `MacOSVariant` | `macOS Customer` |
| `MobileDeviceMinVersion` | `1827.100.14` |
| `VirtualMachineMinHostOS` | `13.0.0` |
| `VirtualMachineMinCPUCount` | `2` |
| `VirtualMachineMinMemorySizeMB` | `4096` |
| `OSDiskImageSize` | `12434` |
| `MinimumSystemPartition` | `11944` |
| `ContentEncoding` | `aea` |
| `FDRSupport` | `false` |

## VM Build Identities

VM-specific identities are identifiable by `DeviceClass = vma2macosap`. They share the same hardware descriptor regardless of macOS version:

| Field | Value |
|-------|-------|
| `Ap,ProductType` | `VirtualMac2,1` |
| `Ap,Target` | `VMA2MACOSAP` |
| `ApChipID` | `0xFE00` |
| `ApBoardID` | `0x20` |

A Universal IPSW contains **three** VM build identities, one per install variant:

| Variant | RestoreBehavior |
|---------|----------------|
| `Customer Erase Install (IPSW)` | `Erase` |
| `Customer Upgrade Install (IPSW)` | _(upgrade)_ |
| `macOS Customer` | _(OTA/generic)_ |

All three share identical VM hardware requirements.

## Extracting Version Info (Shell)

```bash
# macOS version
unzip -p file.ipsw BuildManifest.plist | plutil -extract ProductVersion raw -

# Build number
unzip -p file.ipsw BuildManifest.plist | plutil -extract ProductBuildVersion raw -
```

## Lima-Idiomatic Pattern for Guest OS Version

### VZMacOSRestoreImage API (preferred)

`github.com/Code-Hex/vz/v3` (v3.7.1+) already exposes version metadata from the object
lima loads during VM creation:

```go
ipswImage, err := vz.LoadMacOSRestoreImageFromPath(ipsw)

ipswImage.BuildVersion()            // "26A5353q"
ipswImage.OperatingSystemVersion()  // OperatingSystemVersion{MajorVersion: 27, MinorVersion: 0, PatchVersion: 0}
```

Lima already calls `vz.LoadMacOSRestoreImageFromPath()` in
`pkg/driver/vz/vm_darwin_arm64.go` to read the hardware model. The version
properties are available on the same object but currently unused outside the DFU
install path.

**Version gate usage**: The DFU installer reads `OperatingSystemVersion().MajorVersion`
and compares it to `hostOSMajorVersion()` to decide whether to use the DFU path.
See [dfu-install.md](dfu-install.md).

### Alternative: BuildManifest.plist extraction

For code paths that don't go through the VZ driver (or for host-side utilities),
the IPSW is a standard ZIP and `BuildManifest.plist` at the root contains
`ProductVersion` and `ProductBuildVersion`. Extractable with pure Go
`archive/zip` + `howett.net/plist` (already a lima dependency), no
Virtualization.framework entitlement required.

### Propagating version into the guest environment

Lima's idiomatic pattern for persisting create-time derived data is the
**instance-dir sentinel file** — the same mechanism used for the hardware model
(`pkg/limatype/filenames/filenames.go: VzHwModel = "vz-hwmodel"`).

To expose guest OS version through the full stack:

1. **Extract and persist during `Create()`** in `pkg/driver/vz/vz_driver_darwin.go`:
   read `BuildVersion()` and `OperatingSystemVersion()` from the already-loaded
   restore image; write to a new sentinel file (e.g. `vz-guest-os-version`).
   Must happen in `Create()`, not lazily in `newMacPlatformConfiguration()`,
   so the data is available before `GenerateISO9660` runs on Boot 1.

2. **Add fields to `TemplateArgs`** in `pkg/cidata/template.go`:
   ```go
   GuestOSVersion    string // "27.0", empty for non-macOS
   GuestBuildVersion string // "26A5353q"
   ```

3. **Populate in `templateArgs()`** in `pkg/cidata/cidata.go` by reading the
   sentinel file.

4. **Expose in `lima.env`** template (`pkg/cidata/cidata.TEMPLATE.d/lima.env`):
   ```
   LIMA_CIDATA_GUEST_OS_VERSION={{ .GuestOSVersion }}
   LIMA_CIDATA_GUEST_BUILD_VERSION={{ .GuestBuildVersion }}
   ```

This makes the guest OS version available to all boot and provision scripts
without calling `sw_vers` inside the guest. It also enables version-gated
decisions (e.g. write `AppleLanguagesSchemaVersion` for macOS ≥27) to be made
at cidata generation time rather than at first-boot runtime.

### Timing constraint

`GenerateISO9660` is called by the hostagent at `Start()` time.
`newMacPlatformConfiguration()` (where the IPSW is currently loaded) is also
called during `Start()`, but *after* ISO generation. Therefore version data
needed in the ISO must be written to the sentinel file during `Create()`, not
lazily on first start.

## Observed Values — macOS 27.0 Beta (26A5353q)

| Field | Value |
|-------|-------|
| `ProductVersion` | `27.0` |
| `ProductBuildVersion` | `26A5353q` |
| `BuildTrain` | `FizzSeed` |
| `VirtualMachineMinHostOS` | `13.0.0` |
| `VirtualMachineMinCPUCount` | `2` |
| `VirtualMachineMinMemorySizeMB` | `4096` |
| `MobileDeviceMinVersion` | `1827.100.14` |
