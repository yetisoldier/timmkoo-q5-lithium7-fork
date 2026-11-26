# Forge — D21 report: the dumchar_probe NULL-deref fix (Q5 MBR constant + init_pmt() guard)

**Task:** `.specs/forge-d21-task.md` · **Delta:** `patches/kernel/D21.patch`
**Method:** the root cause was re-verified line-by-line in the fork source, and every
claimed constant was re-decoded this session from the pinned Lithium kernel
(`kernel.img` 5217dd41…, decomp d284ba16… at `~/.hermes/cache/scratch/opencode/bob-m2/
lithium-kernel.decomp` = the same bytes as the task's `bob-m1/lithium/kernel.decomp`,
symbol ELF + kallsyms at `forge-d17/lithium.{elf,syms}`, in-tree `arm-eabi-4.8` objdump,
image base `0xc0008000`) and cross-checked against the Q5's live scatter geometry.
One task row was **corrected by the re-decode** (the sd.c:231 define is dead comment
text — §2c/§4). **Status: all deliverables landed and verified. Build + verify only —
nothing was flashed.**

---

## 1. Root cause — confirmed in source, exactly as the task stated

- `drivers/misc/mediatek/dum-char/mt6582/dumchar.c:908` — `init_pmt();` return ignored
  (`extern int init_pmt(void);` already declared at dumchar.c:43).
- `drivers/misc/mediatek/pmt/mt6582/pmt.c`: loop fills `PartInfo[i]`
  (`.type = EMMC`, `.region = USER/BOOT_1`, `.name = kzalloc`), sets `PART_NUM = i`,
  **THEN** the preset check at `pmt.c:610`
  `if (mbr_start_address != MBR_START_ADDRESS_BYTE)` → `mbr_invalid:` (pmt.c:628)
  `kfree(PartInfo[i].name); PartInfo[i].name = NULL;` for **all** `PART_NUM` —
  returning the error **without resetting `PART_NUM`**. So the one poisoned state is:
  `PART_NUM > 0` with every name freed to NULL.
- `dumchar_probe` then continues: `kzalloc(PART_NUM * sizeof(struct dumchar_dev))`,
  `alloc_chrdev_region(…, PART_NUM, …)`, and in the loop (dumchar.c:932+) each device
  gets `.dumname = PartInfo[i].name` (a store — survives), then for the EMMC branch
  (all entries are EMMC after a successful scan) the first true dereference is
  `!strcmp(PartInfo[i].name,"fat")` / the `printk("[Dumchar] %s start address=…",
  dumchar_devices[i].dumname, …)` — **NULL deref at 0x0 inside dumchar_probe**,
  matching the F1 last_kmsg backtrace (`dumchar_probe` c04dd1e4 ← … ←
  `platform_device_register`) and the "right after `init eMMC success`" timing.

## 2. The decoded Q5 MBR value — **0x1400000** (20 MB)

**2a. Blob VA trail** (Lithium `init_pmt` = `c050faa8`, from `lithium.elf` symtab;
kallsyms `lithium.syms` covers functions only, so the data global is followed through
the disassembly):

| VA | insn | meaning |
|---|---|---|
| `c050fe94` | `add r7, r7, r7, lsl #2; add r9, r9, r7, lsl #3` | found-"mbr" branch: `&PartInfo[idx]` (stride 40) |
| `c050fe9c` | `ldrd r8, [r9, #16]` | `mbr_start_address = PartInfo[i].start_address` (u64) |
| `c050fdfc` | `ldr ip, [fp, #-84]` → `ip = c0b5fc80` (stored at `c050fb70`: `movw lr,#0xfc80 / movt lr,#0xc0b5`) | `&MBR_START_ADDRESS_BYTE` |
| `c050fe08` | `ldrd r2, [ip]` | load the preset u64 |
| `c050fe0c` | `cmp r9, r3 ; cmpeq r8, r2` | 64-bit compare |
| `c050fe14` | `bne c050ff4c` | mismatch → error path |
| `c050ff4c-` | printk(`c0a6cc98`) + `kfree` loop over `PART_NUM` (`ldr r3,[r5,#4]`, stride 40) | "MBR offset invald: MBR offset 0x%llx!=0x%llx(preset)\n" — **the exact string the fork's pmt.c:612 carries** + the identical NULL-name free loop |

**The preset itself:** `u64` at VA **`c0b5fc80` = `0x0000000001400000`**
(20,971,520 B). Read two ways: (1) from the pinned decomp flat image at file offset
`0xb57c80` (VA − base 0xc0008000); (2) cross-proof from the symbol ELF
(`.kernel` vaddr `c0008000` @ fileoff `0x124`, `readelf -SW`) → same 8 bytes.

**2b. Scatter cross-check** (`.hermes/q5-recovery/spft/live-geometry/
MT6582_live_scatter.txt`, project **j5052**): `PRELOADER linear 0x0, size 0x1400000,
region EMMC_BOOT_1`; **`MBR linear_start_addr: 0x1400000` in EMMC_USER**. 0x1400000 ✓.

**2c. Re-decode corrections to the task's constant geography** (important for
architecture review):

- The **live** definition of `MBR_START_ADDRESS_BYTE` linked into `pmt.c:610` (and
  `dumchar.c`, `mt_dump.c`, and sd.c's own `msdc_get_offset`/`msdc_cal_offset`) is the
  board global `arch/arm/mach-mt6582/<board>/partition/cust_part_mbr.c`
  (`extern u64 MBR_START_ADDRESS_BYTE;` in `mach/partition_define.h:10`).
- The `#define MBR_START_ADDRESS_BYTE (0x660000)` the task cites at
  `mmc-host/mt6582/sd.c:231` is **DEAD text**: it sits inside the
  `#ifdef FPGA_PLATFORM` legacy sample block **and** inside a `/* … */` comment
  (sd.c:230/231 — the block closes at line 257). It never compiled on the fork
  either; the fork's boot panic came from the **live** global = the a106 clone's
  `12288*1024` (0xC00000) vs the Q5's 0x1400000.
- The vendor's own sd.c consumes the **global**, not a local define: Lithium
  `msdc_get_offset` @`c04fa754` = `bl msdc_get_other_capacity; movw/movt r3,
  c0b5fc80; ldr r3,[r3]; rsb r0, r0, r3; lsr r0, r0, #9` (and `msdc_get_reserve`
  @c04fa784 adds `0xa800` = `0x1500000>>9` — the fork's hardcoded
  `l_mtk_reserve` is already correct for the Q5's PRO_INFO @0x1500000 ✓).

## 3. The patch — `patches/kernel/D21.patch` (3 touchpoints, one D-id)

**3a. `arch/arm/mach-mt6582/q5/partition/cust_part_mbr.c` (the LIVE fix).**
`u64 MBR_START_ADDRESS_BYTE = 12288 * 1024;` → `u64 MBR_START_ADDRESS_BYTE = (0x1400000);`
with the decode-trail comment (blob anchors, scatter cross-check, the F1 panic story).
This is the value the pmt.c:610 preset check now compares against — the check passes
on the Q5 like it does in the stock Lithium kernel.

**3b. `drivers/misc/mediatek/dum-char/mt6582/dumchar.c` (the defensive guard).**
```c
    result = init_pmt();
    if (result) {
        /* D21 … why comment … */
        printk(KERN_ERR "[Dumchar]D21: init_pmt() failed (err=%d) - PMT/MBR "
               "state unusable; failing probe instead of dereferencing the "
               "NULL PartInfo names\n", result);
        return -ENODEV;
    }
```
Plain early return (not the goto ladder) because at the call site **nothing has been
acquired in `dumchar_probe` yet** (the `kzalloc` of `dumchar_devices` and
`alloc_chrdev_region` both come after) — the return IS the clean fail. The guard sits
inside the existing `CONFIG_MTK_EMMC_SUPPORT` block; the `msdc_get_cache_region()`
cascade only runs on success. `KERN_ERR` matches the D19 guard idiom. Any future PMT
failure (`load_pmt` fail, PART_NUM=0, malloc failure, MBR mismatch) is now a logged,
bound-out driver — diagnosable, not a boot death.

**3c. `drivers/misc/mediatek/mmc-host/mt6582/sd.c` (dead-block hygiene, per §2c).**
The D21 note is inserted inside the FPGA sample comment block (plain text — **no
nested `*/`**, so the sample table stays inert), and the sample value is updated
`0x660000` → `0x1400000` so a future de-comment cannot resurrect the stale constant.
No compiled code change in sd.c (its uses were always on the extern global — which is
now the right value).

## 4. Pipeline changes

- **`build/62_kernel_delta_board.sh`** now builds the NEW O dir
  **`build-beta-touch-lcm-board2`** (decision: new `-board2` dir, so the pinned M4
  `beta-touch-lcm-board` artifacts — including Hera's already-flashed F1 image — stay
  byte-stable and reproducible from the pre-D21 history at m1b HEAD). D21 appended to
  `PATCH_ORDER`; the tracked-file WANTED-set and mtime pinning extended with
  `drivers/misc/mediatek/dum-char/mt6582/dumchar.c` (`cust_part_mbr.c` is untracked
  q5/ content, covered by the recursive q5 pin).
  - **New source asserts (§D21 invariants):** q5 global `(0x1400000)` present,
    a106 value absent in q5, a106 origin file **pristine** (`12288 * 1024` — no
    cross-board leak), sd.c note + `#define MBR_START_ADDRESS_BYTE (0x1400000)`
    + stale-0x660000 define-form absent, dumchar.c `result = init_pmt();` +
    D21 marker + `return -ENODEV;` + **no bare `    init_pmt();` call**.
  - **New D21 COMPILED GATE** (post-build, separate python block): `cust_part_mbr.o`
    carries the `0x1400000` u64 at a word-aligned file offset (0x38, verified) and the
    a106 `0xC00000` form is absent at ANY offset; `dumchar.o` .rodata carries
    `"D21: init_pmt() failed"`; `pmt.o` keeps the vendor `"MBR offset invald"`
    preset-check string. (Note: the task's literal phrasing "assert pmt.o/dumchar.o
    contains the NEW MBR constant" is implemented at the constant's definition site —
    `cust_part_mbr.o` — because pmt.o only references the extern; explained in §3a.)
  - δ-parity extended: D21 compile-side FACT lines; shipped-Image MUST-HAVE for the
    D21 marker and the `[Dumchar]MBR address` format string.
  - Reset-audit/O-dir whitelists extended (`board2` + keep `board`); all §3.3
    D2/D3/D5/D6/D7/D15/D16/D17/D18/D19/D20 asserts re-run unchanged.
- **`build/55_repack_boot.sh`**: tag `beta-touch-lcm-board2` added (usage strings +
  zImage path + die message; repack/verify machinery untouched).
- **Additive hygiene in 50/60/61**: O-dir whitelist regex adds `beta-touch-lcm-board2`
  (keeps `board`). Nothing else changed — no defconfig changes.
- **`patches/kernel/DELTA-NOTES.md`**: D21 section appended.

## 5. Build + gate results

- `bash build/62_kernel_delta_board.sh` **PASS** (full log `/tmp/forge-d21-62.log`,
  rerun `/tmp/forge-d21-62-rerun.log`): donors-pins ✓, reset-audit ✓, D1…D21 applied ✓
  (D21 at fuzz 0), tracked-file WANTED-set ✓, all D2..D20 invariants ✓, **D21 source
  invariants ✓**, defconfig→`.config` LCM line ✓, both gc9503v `built-in.o`s ✓,
  banner `Linux version 3.10.54 (forge@fork) …` ✓, δ-parity PASS
  (`out/kernel-parity-beta-touch-lcm-board2.txt`; D18-table pins hold: mt6323=19,
  auxadc=210, hx8369b=0, fan5405_config_interface=0, battery_meter 24=24),
  **precedence gate PASS** (hal_kpd/camera/sd.o/accdet.o — unchanged from M4),
  **D21 compiled gate PASS** (`cust_part_mbr.o u64=0x1400000 & no 0xC00000, dumchar.o
  D21 marker, pmt.o preset-check string`).
- **Idempotency**: rerun → identical zImage
  `45e02bd5f86e2c4ff2f59b8d99f31417832683e267279b7a8d37bc5fe68020c5`
  (4,264,888 B); identical Image `259c53d05dde07a991a31cfc547ed7a3719d8ee5ef456c8a3a
  7432f3840d24ad` (14,113,192 B).
- **Shipped-Image strings**: `D21: init_pmt() failed` ×1, `[Dumchar]MBR address` ×1 —
  on a healthy Q5 boot the log will now print `[Dumchar]MBR address 1400000`; on any
  PMT failure it will print the loud
  `[Dumchar]D21: init_pmt() failed (err=…) - PMT/MBR state unusable; failing probe…`
  marker instead of panicking.
- **Compiler warnings**: 937 == 937 vs the M4 β-touch-lcm-board build, identical
  warning-file sets → zero new warnings from D21.
- `bash build/55_repack_boot.sh beta-touch-lcm-board2` **PASS**: `verify OK: headers
  byte-identical except ksz (3809720 (donor) vs 4265400); ramdisk byte-identical
  (1394157 B, sha c0be6c46333b…)`.

**Final artifact: `out/boot-m1b-beta-touch-lcm-board2.img` — 5,662,720 B —
sha256 `0b6ed1b2e2f30b41ffeb3ac9ba019b9d7635ba0fb38763b05d9758fc0b10c2cc`**
(sidecar `out/boot-m1b-beta-touch-lcm-board2.img.sha256` identical).
Pinned prior artifacts untouched (`boot-m1b-beta-touch-lcm-board.img` still
`2ecb317e…`). For Hera (per the task's Note): flash `boot-m1b-beta-touch-lcm-board2.img`
and watch the boot; expected dmesg includes `[Dumchar]MBR address 1400000`.

## 6. Deviations / notes for Bob (implementation-level, no architecture change)

1. **Task-row correction — the sd.c:231 constant is dead text** (§2c): the task's
   "a106 kernel hardcodes MBR_START_ADDRESS_BYTE (0x660000) in sd.c:231" describes a
   commented-out MT6575-era FPGA sample; the live value feeding pmt.c:610 is the
   `cust_part_mbr.c` board global (a106 = 0xC00000, Q5 stock = 0x1400000). D21 fixes
   the live global (the actual panic fix) AND updates the dead sample text + adds the
   DEAD-text note (the task's sd.c intent, kept). Verified: the vendor's sd.c itself
   reads the global (`msdc_get_offset` @c04fa754).
2. **Assert placement**: "compiled pmt.o/dumchar.o contains the NEW MBR constant" is
   proven at `cust_part_mbr.o` (.data — the constant's only definition site, word-
   aligned + a106-form-absent) plus the marker strings in `dumchar.o`/`pmt.o`, since
   pmt.o never materialises the constant (extern reference).
3. **First-run gate bug fixed**: the original `! grep -q '0x660000' sd.c` assert tripped
   on the D21 note's own mention of the stale value; re-pinned to the exact
   define-form `^#define MBR_START_ADDRESS_BYTE (0x660000)$`.
4. **Residual hardening deferred to Bob** (not expanded scope): pmt.c's `mbr_invalid`
   could also reset `PART_NUM = 0` after freeing the names (defense in depth for any
   other caller of `init_pmt()`); `PartInfo[i].name = kzalloc(...)` unchecked in
   pmt.c's refill loop (an OOM there derefs NULL at line ~581) — both are pmt.c
   one-liners if a follow-up D-id wants belt-and-braces; nothing else consumes
   `init_pmt()` in this tree.
5. **`init eMMC success` in the captured log** comes from the MSDC/LK-side prints; the
   panic followed it because `dumchar_probe` is the first in-kernel consumer of the
   PMT state (its probe runs during `platform_device_register` from
   `msdc_init`/board init) — consistent with the backtrace ordering.

## 7. Bookkeeping

Committed: `patches/kernel/D21.patch` (new), `patches/kernel/DELTA-NOTES.md` (D21
section), `build/62_kernel_delta_board.sh` (board2 + D21 gates), `build/55_repack_boot.sh`
(tag), additive whitelist hygiene in `50/60/61`. `out/` artifacts and the kernel
O-dirs stay gitignored per convention. Scratch build logs: `/tmp/forge-d21-62.log`,
`/tmp/forge-d21-62-rerun.log`.

**Implementation complete.**
