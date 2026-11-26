# Forge — D21: fix the dumchar_probe NULL-deref (the real boot panic)

The fork kernel panics (NULL pointer dereference at 0x0) in `dumchar_probe`, NOT the display
path. Captured from the F1 boot's `last_kmsg` (ram-console survived a boot-only control flash):
- backtrace: `dumchar_probe` (c04dd1e4) ← `platform_drv_probe` ← `really_probe` ← `__device_attach`
  ← `bus_for_each_drv` ← `device_attach` ← `bus_probe_device` ← `device_add` ←
  `platform_device_add` ← `platform_device_register`.
- The panic happens right after `init eMMC success`, and a nested panic in ipanic/mrdump froze
  the device (which is why it looked like a hang, not a reset-loop).

## Root cause (verified in source)
`drivers/misc/mediatek/dum-char/mt6582/dumchar.c:908` calls `init_pmt()` and **ignores the return
value**. `init_pmt()` (in `drivers/misc/mediatek/pmt/mt6582/pmt.c:536`) has exactly one failure
path that leaves `PART_NUM > 0` while nulling the names: the MBR check at `pmt.c:610`:
`if (mbr_start_address != MBR_START_ADDRESS_BYTE)` → `mbr_invalid:` frees `PartInfo[i].name` (sets
NULL) and returns error, WITHOUT resetting `PART_NUM`. Then `dumchar_probe`'s loop at `dumchar.c:932`
dereferences the NULL `PartInfo[i].name` → panic.

The a106 kernel hardcodes `MBR_START_ADDRESS_BYTE (0x660000)` in
`drivers/misc/mediatek/mmc-host/mt6582/sd.c:231` (and `partition_define.h:10` declares it extern) —
Micromax Unite 2's eMMC layout, which does not match the Q5.

## Tasks

### 1. Decode the Q5's real MBR address from the Lithium blob
The pinned Lithium kernel blob (`5217dd41…`, decomp `d284ba16…` at
`~/.hermes/cache/scratch/opencode/bob-m1/lithium/kernel.decomp`, ELF/syms at
`~/.hermes/cache/scratch/opencode/forge-d17/lithium.{elf,syms}`, base `0xc0008000`). Find the
`MBR_START_ADDRESS_BYTE` constant the Lithium kernel uses — it appears as a 64-bit immediate in the
`init_pmt()` MBR comparison (a `movw`/`movt` pair or a literal-pool `ldr` for a u64 constant; the
value is the MBR linear address in bytes, e.g. 0x660000-class). Re-verify the value by cross-checking
the Q5's scatter/geometry if available (`.hermes/q5-recovery/spft/live-geometry/`).

### 2. Port the MBR constant + add the guard
- `drivers/misc/mediatek/mmc-host/mt6582/sd.c:231`: change `MBR_START_ADDRESS_BYTE` to the decoded
  Q5 value. Cite the blob anchor in the patch prologue.
- `drivers/misc/mediatek/dum-char/mt6582/dumchar.c:908`: capture `init_pmt()`'s return; if non-zero,
  `printk` a loud marker and `goto` a clean-fail (return `-ENODEV` from the probe) instead of
  proceeding into the `PartInfo[i]` loop. This is the defensive guard so ANY future PMT failure is
  diagnosable, not fatal.

### 3. Rebuild + repack + gates
- New stage or extend `62_kernel_delta_board.sh` → apply D1…D20 + D21 into the O dir
  `build-beta-touch-lcm-board` (or a new `-board2` dir; document which). Re-run the §3.3 parity
  asserts. Add a new assert that the compiled `pmt.o`/`dumchar.o` contains the NEW MBR constant
  (proves the port took).
- `55_repack_boot.sh` → new tag (e.g. `beta-touch-lcm-board2` or `-mbrfix`). Emit
  `out/boot-*.img` + sha256 sidecar.

## Output — `.specs/forge-d21-report.md`
Decoded Q5 MBR value (+ blob VA trail), the two patches, build/gate results, final image sha256 +
path. End "Implementation complete" or "blocked on X".

## Note
Do NOT flash anything — Hera flashes and watches the boot. Build + verify only.
