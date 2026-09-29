# vTPM (swtpm) crashes on aarch64 host with QEMU/HVF acceleration

Notes on a QEMU/HVF bug blocking vTPM-backed measured boot for aarch64 Lima
guests, surfaced while working on `botlockbox` (a hardened-sandbox Lima/QEMU
config, Phase 2 of which calls for vTPM via swtpm). Captured here because the
fix options touch Lima itself, not just that one project.

Status: root-caused, not fixed. Currently working around by leaving `tpm:
true` off in `botlockbox/lima.yaml`.

---

## Environment

- Host: Apple Silicon Mac, macOS 26.6.2 (25G83)
- `limactl version 2.3.0-dev.20260910` (MacPorts `lima-devl`; also reproduced
  on `2.2.0-dev.20260730` and `2.1.2-dev.20260613` — no change across
  versions)
- `qemu-system-aarch64` 11.1.0 (MacPorts `qemu @11.1.0_2` — newest available
  in the MacPorts tree; checked `qemu`, `qemu-mac99-smp`, `qemu-devel*`, no
  newer build exists)
- `swtpm` 0.10.1 (MacPorts)

## Repro

`~/Developer/botlockbox/lima.yaml`: `vmType: "qemu"`, aarch64 guest (Ubuntu
resolute cloud image), plus:

```yaml
tpm: true
```

`limactl start` (or `make rebuild` in that repo) fails every time, immediately
on boot:

```
qemu-system-aarch64: -device tpm-tis-device,tpmdev=tpm0: Error: ret = HV_BAD_ARGUMENT (0xfae94003, at ../qemu-11.1.0/accel/hvf/hvf-all.c:132)
```
followed by `Driver stopped due to error: signal: abort trap`.

Full generated QEMU command line (from `~/.lima/botlockbox/ha.stderr.log`,
2026-09-14 ~15:16 local):

```
/opt/local/bin/qemu-system-aarch64 -m 16384 -cpu max -machine virt,accel=hvf -smp 8,sockets=1,cores=8,threads=1 \
  -drive if=pflash,format=raw,readonly=on,file=/opt/local/share/qemu/edk2-aarch64-code.fd \
  -device qemu-xhci,id=usb-bus \
  -drive file=/Users/blake/.lima/botlockbox/disk,if=none,discard=on,id=boot-disk -device virtio-blk-pci,drive=boot-disk,bootindex=1 \
  -boot order=c,splash-time=0,menu=on \
  -drive id=cdrom0,if=none,format=raw,readonly=on,file=/Users/blake/.lima/botlockbox/cidata.iso -device virtio-scsi,id=scsi0 -device scsi-cd,bus=scsi0.0,drive=cdrom0 \
  -chardev socket,id=chrtpm,path=/Users/blake/.lima/botlockbox/swtpm.sock -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis-device,tpmdev=tpm0 \
  -netdev user,id=net0,net=192.168.5.0/24,dhcpstart=192.168.5.15,hostfwd=tcp:127.0.0.1:6667-:22 -device virtio-net-pci,netdev=net0,mac=52:55:55:6f:d1:3e \
  -device virtio-rng-pci -audiodev none,id=snd0 -display none -vga none -parallel none \
  -chardev socket,id=char-serial,... -serial chardev:char-serial \
  -chardev socket,id=char-serial-pci,... -device pci-serial,chardev=char-serial-pci \
  -chardev socket,id=char-serial-virtio,... -device virtio-serial-pci,id=virtio-serial0,max_ports=1 -device virtconsole,chardev=char-serial-virtio,id=console0 \
  -chardev socket,id=char-qmp,... -qmp chardev:char-qmp -name lima-botlockbox -pidfile /Users/blake/.lima/botlockbox/qemu.pid
```
(serial/qmp socket paths elided for length; full command is in the log file
above)

---

## Root cause

Confirmed via web search (GitLab issue + qemu-devel patch series), not yet
independently verified against qemu source directly:

- QEMU's `tpm-tis-device` (the sysbus TPM model used on the ARM `virt`
  machine — x86 uses a different model, `tpm-crb`) registers a PPI (Physical
  Presence Interface) MMIO region that is not 16K-page-aligned.
- Apple's Hypervisor.framework (`accel=hvf`, used by QEMU to accelerate
  same-arch aarch64-on-aarch64 guests) requires 16K-aligned memory regions
  for `hv_vm_unmap`, and aborts with `HV_BAD_ARGUMENT` when it isn't.
- Only bites aarch64 guests under HVF acceleration. Doesn't affect x86_64
  guests (different TPM device model, `tpm-crb`) or a TCG-emulated
  (non-HVF) aarch64 guest, since TCG has no such alignment requirement.
- A 3-patch fix (`hw/tpm: fix tpm-tis-device...`) was posted to qemu-devel in
  June 2026 and merged into qemu.git 2026-07-10. It adds a `ppi` boolean
  device property (default `true`) to `tpm-tis-device`, gating the PPI MMIO
  region behind it — but only *defaults* `ppi=off` for machine types
  `<= virt-11.0` via `hw_compat_11_0[]`. Lima always requests the unversioned
  `virt` alias (latest), which would still default `ppi=on` and still crash
  even on a qemu build with the fix. An explicit
  `-device tpm-tis-device,tpmdev=tpm0,ppi=off` would be required.
- Sources: [qemu-project/qemu GitLab issue #2895](https://gitlab.com/qemu-project/qemu/-/issues/2895),
  qemu-devel patch series ("[PATCH v1-v3] hw/tpm: fix tpm-tis-device...",
  June 2026), "[PULL v1 0/3] Merge tpm 2026/07/10 v1".

## What's already been ruled out

- Upgrading `lima-devl` across three versions (2.1.2-dev → 2.2.0-dev →
  2.3.0-dev.20260910): no change, identical crash, identical generated QEMU
  command line. Lima itself doesn't add `ppi=off` or expose any way to.
- Checked `lima.yaml`'s full field set and `limactl`'s recognized env vars:
  no field for extra QEMU device args, no way to pin an older
  `-machine virt-11.0`, no `tpm.ppi` or similar option. Only
  `QEMU_SYSTEM_<ARCH>` exists, and it only overrides which QEMU binary gets
  invoked.
- MacPorts has no qemu version newer than 11.1.0_2, and no indication the fix
  landed by 11.1.0 anyway given the July 2026 merge date.

---

## Options

1. **Leave `tpm: true` off for now** (lowest effort, current state). Revert
   botlockbox's `lima.yaml`; track upstream qemu/MacPorts for a
   fixed-qemu + versioned-machine-type combo that ships `ppi=off` by
   default for whatever `virt` alias Lima ends up requesting.

2. **Build a private patched `qemu-system-aarch64`.** Apply the 3 upstream
   patches (or pull current qemu.git master) to a local source build, then
   either (a) pass `ppi=off` explicitly if Lima gains a way to add extra
   QEMU device args, or (b) pin the generated machine type to `virt-11.0` —
   needs a Lima change, or a wrapper script masquerading as
   `qemu-system-aarch64` that rewrites `-machine virt,accel=hvf` →
   `-machine virt-11.0,accel=hvf` before exec'ing the real binary. Point
   Lima at it via `QEMU_SYSTEM_AARCH64=/path/to/patched/qemu-system-aarch64`,
   leaving the MacPorts `qemu` package untouched.
   Real maintenance burden (private build to track), and doesn't help
   anyone else hitting this — **not recommended** over option 3.

3. **Contribute a Lima fix upstream.** Lima has no mechanism today for extra
   QEMU device args or machine-type pinning; adding one (e.g. a
   `qemu.extraArgs` or `qemu.machineType` field) is the generalizable fix,
   and arguably in-scope already since Lima special-cases `tpm: true`
   behavior per-arch. Needs an upstream issue first per Lima's "talk first,
   code later" contribution rule. **Recommended medium-term path** — fixes
   this generally instead of just for botlockbox, and is a legitimate,
   scoped ask (narrow field, clear motivating bug, cites the upstream qemu
   issue).

4. **Force TCG instead of HVF** for this instance — sidesteps the bug
   entirely (no HVF, no alignment requirement) at the cost of
   software-emulated CPU performance. No `lima.yaml` field forces this when
   host/guest arch match; Lima auto-selects HVF whenever `kern.hv_support`
   is true and arches match, so this also needs a Lima code change. Real
   perf hit for a same-arch aarch64 guest — **not recommended** just to keep
   vTPM working when option 1 is free.

## Recommendation

Do **1 now** (already in effect) and pursue **3** as the actual fix: open an
upstream Lima issue proposing a generic `qemu.extraArgs` (or narrower
`qemu.machineType`) field, citing this repro and the upstream qemu GitLab
issue as motivation. Skip 2 and 4 — both are dead-end workarounds with real
ongoing cost that a generalizable Lima field would make unnecessary.

## Reference

- Repo: `~/Developer/botlockbox` (design doc: `botlockbox/botlockbox.md` in
  that project's own vault/notes)
- Repo state as of writing: `botlockbox/lima.yaml` still has `tpm: true` set;
  the `botlockbox` Lima instance is `Stopped` (factory-reset, last start
  attempt crashed as described above) — reproducible as-is via
  `cd ~/Developer/botlockbox && make rebuild`.
