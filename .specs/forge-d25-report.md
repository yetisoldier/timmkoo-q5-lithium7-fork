# Forge D25 report — touch via the MTK tpd framework (board6)

**Task:** `.specs/touch-tpd-framework-task.md`
**Design (binding):** `.specs/bob-tpd-framework-spec.md` (§5 work order)
**Status:** implementation complete, all gates PASS, image produced, no flashing performed.

---

## 1. Artifacts

| Artifact | Detail |
|---|---|
| `patches/kernel/D25-tpd-framework-integration.patch` | 418 lines, **2 files**, +249/−19; applies cleanly on the production chain `D1 D2 D8 D9 D10 D11 D12 D13 D14 D4 D17 D18 D19 D20 D21 D22 D24` (D23 not applied). sha256 `351233b0abd80cbdbbbd736c8b66f3a47892e947a1d0b735c182ecd080c9b852` |
| `build/66_kernel_delta_tpd.sh` | new stage, 65's shape (donors-pin pass, reset rm-list, mtime pinning, BUILD_CC stamps), O-dir `build-beta-touch-lcm-board6`, chain `…D22 D24 D25` |
| `build/55_repack_boot.sh` | case tag `beta-touch-lcm-board6` added (existing tags untouched) |
| `out/boot-m1b-beta-touch-lcm-board6.img` | 5,664,768 B, sha256 `3987415b68db3dc3c8ef86a939f3e605510d4061a3393b21853cdfbfb3014f01` |
| `out/boot-m1b-beta-touch-lcm-board6.img.sha256` | written by 55 |
| `out/kernel-parity-beta-touch-lcm-board6.txt` | δ-parity report (§4.2.8 + D17–D22 + D25 lines) |
| `patches/kernel/DELTA-NOTES.md` | D25 entry appended |
| Reference kernel tree | left in the post-stage-66 state (applied chain), like every prior stage run |

Post-D25 tree file hashes (for the record):
`mtk_gslX680.c` = `af4b70a82ad500f5ac402305d593755a6648dd78782e2f399e8cfbc2e42870c8`,
`tpd_custom_gsl_tp.h` = `ab2bc6b9d05e380682072fb82128d8339f8d7c7a017a2b32d7a9b0727b6c5dbf`.
Base-state (pre-D25) snapshots preserved at
`~/.hermes/cache/scratch/opencode/forge-d25/{mtk_gslX680.c,tpd_custom_gsl_tp.h}.base`
(sha `f98f8bbb…` / `9dc7f79d…`).

---

## 2. Exact commands and their outputs

```
build/66_kernel_delta_tpd.sh          # run 1: found 1 new warning (const discard) — fixed
                                      # run 2: found 2 parity-gate miscalibrations — re-pinned
                                      # run 3..5: ALL GATES PASS (incl. one fresh-O-dir run)
build/55_repack_boot.sh beta-touch-lcm-board6   # run twice, identical image sha
```

Reproducibility proof (M2): moved `build-beta-touch-lcm-board6/` aside and re-ran stage 66
completely fresh — zImage rebuilt from scratch reproduced **`2263934f678842d2ceae29afc8471c36b8141b0be58e77ca52320f9f112e573b`**
byte-identically; an incremental re-run also reproduced it, and both `55` runs produced the
identical image sha above. Full-build wall time on this machine: ≈ 82 s.

Kernel shas:

| Binary | sha256 |
|---|---|
| `build-beta-touch-lcm-board6/arch/arm/boot/zImage` | `2263934f678842d2ceae29afc8471c36b8141b0be58e77ca52320f9f112e573b` |
| `build-beta-touch-lcm-board6/arch/arm/boot/Image` | `e64a4670a56967d120f20c5781acfd26f182fe8e47717fd06c24b9d34ed664db` |
| `out/boot-m1b-beta-touch-lcm-board6.img` | `3987415b68db3dc3c8ef86a939f3e605510d4061a3393b21853cdfbfb3014f01` |

Banner: `Linux version 3.10.54 (forge@fork) (gcc version 4.8 (GCC) ) #1 SMP PREEMPT 2026-11-25T13:47:27-06:00`
(pinned identities — same anchor as every prior stage).

Repack verify: `verify OK: headers byte-identical except ksz (3809720 (donor) vs 4266096); ramdisk byte-identical (1394157 B, sha c0be6c46333b…)`.

Pin checks (nothing disturbed):
`boot-m1b-beta-touch-lcm-board5.img` `695f5592bd43529a8298d13978b7c168c5be66686be81af52bb7b7fabf39a846` ✓,
`boot-m1b-lithium-ctl.img` `443e40c3b27eb9c76250e4dbae61a45e2426c1b714754ff6838c056bed85df8f` ✓.

---

## 3. What the D25 patch does (Bob §5.1 a→h, one-to-one)

1. **a. i2c driver identity:** `.driver.name = TPD_DEVICE` ("mtk-tpd"); `id_table`
   (`gsl_tp`/`gsl1680`/`gsl915`) and `.detect` kept; `force[]`/`forces[]`/`.address_list`
   removed (blob E1: detect present, address_list NULL — the force list would only feed the
   core's smbus-quick emulation; the client comes from the pre-registered
   `i2c_board_info{gsl_tp@0x40}`).
2. **b. pre-gate:** `gsl_await_chip()` = blob `gsl_test_i2c`-as-gate shape (E5): ≤5 reads of
   4 B @reg 0xfc, 0 on first success, after 5 failures prints
   `gsl_tp: chip not answering 0xfc after 5 reads` and returns −1; constants
   `GSL_CHIP_AWAIT_REG 0xfc`, `GSL_CHIP_AWAIT_TRIES 5`, plus `GSL_CHIP_CONFIRM_TRIES 4` for
   the probe tail.
3. **c. probe reorder (E4/E5/E6):** `gsl_power_on()` (D24 five rails, unchanged) →
   `gsl_gpio_init()` (RST pulse + INT pull-up + `msleep(100)`, unchanged) → `mt_eint_mask(2)`
   (pre-mask before the FIRST i2c contact) → `gsl_await_chip` → guarded unconditional
   `gsl_sw_init` → `msleep(20)` → `check_mem_data` (keeps the `D22: init failed` marker) →
   `gsl_eint_register()` (`(2, RISING, handler, auto_umask=1)` unchanged; its embedded unmask
   moved out so the EINT stays masked until the blob-faithful tail) → `kthread_run` →
   `tpd_load_status = 1` → proc/db state unchanged → `gsl_data_init_selected()` (probe-end
   `gsl_DataInit` over the ACTIVE config, E6) → `mt_eint_unmask(2)` → bounded non-fatal tail
   (`msleep(5)` + ≤4 reads of 0xfc, log only).
4. **d. `sw_inited`:** `gsl_dev.sw_inited = 1` set immediately after the guard in
   `gsl_sw_init`, with a loud comment spelling the semantics (set at entry, never cleared,
   also on failure — blob @0xc034d7e8; our port never set it).
5. **e. `tpd_local_init` rewrite (E2):** `gsl_bootmode = get_boot_mode(); if (SW_REBOOT) 0;`
   → `tpd_button_setting(...)` → `i2c_add_driver(&tpd_i2c_driver)` (−1 on add failure) →
   `tpd_load_status == 0` ⇒ `i2c_del_driver` + −1 (D22 production semantics; the diagnostic
   keep-driver-registered block is **deleted**; no bind-hint strings remain) → retained
   `input_set_abs_params(ABS_MT_TRACKING_ID …)` (documented deliberate deviation, Bob §3) →
   `tpd_type_cap = 1`. Power/GPIO are gone from local_init (blob E2: none there — the probe
   owns them, synchronously inside `i2c_add_driver`).
6. **f/g. buttons (E3):** `#define TPD_HAVE_BUTTON 1` + `gsl_tp_keys[2] = {172, 158}`
   (KEY_HOMEPAGE/KEY_BACK, verified against `include/uapi/linux/input.h`: 374/388) +
   `gsl_tp_keys_dim[2][4] = {{100,900,40,40},{300,900,40,40}}`; `.tpd_have_button = 1` (the
   `#ifdef` branch dropped); `tpd_button(ti->x[0], ti->y[0], 1)` in `gsl_report_point`'s
   down branch, annotated `D25 [BLOB c034d4f0]` with the no-release-site note.
7. **h. prologue:** D25 evidence paragraph (E1–E8 anchors) and provenance-note bump added.

Plus the §5.1-2 header file: `tpd_custom_gsl_tp.h` comment-only (driver-name decode note;
`TPD_I2C_NUMBER 0`, `GSLX680_NAME "gsl_tp"`, `GSLX680_ADDR 0x40`, power tags,
`TPD_EINT_FLOW EINTF_TRIGGER_RISING` byte-unchanged, source-gated).

**Preserved:** D22 transport/loader/alive-gate internals byte-untouched (D22 host tests run
green on the pre-D24 snapshots), D24 5-rail order + 100 ms settle, GPIO14 reset, GPIO2 INT
pull-up, EINT 2 rising, D20 header precedence (source + compiled gates), D21 MBR 0x1400000,
D17 fw sha pin, D1–D14 invariants — all re-asserted by the stage.

---

## 4. Gate results (stage 66, final run)

All carried invariants: **PASS** (D2/D3/D5/D6/D7, D15/D16/D22-keymap re-pins, D17 fw sha +
config, D18 LCM list, D19 guards, D20 source + compiled precedence, D21 source + compiled,
D22 host tests + source + compiled, D24 rails/settle).

New D25 gates:

| Gate | Result |
|---|---|
| Source: `.driver.name = TPD_DEVICE`, no `= GSLX680_NAME` in the driver struct | PASS |
| Source: `.address_list` / `force[]` / `forces[]` absent; id_table + board info present | PASS |
| Source: `gsl_dev.sw_inited = 1` present | PASS |
| Source: `gsl_await_chip` + `GSL_CHIP_AWAIT_TRIES` + reg `0xfc` + vendor 5-read failure log | PASS |
| Source: `tpd_button_setting(` in local_init; keys {172,158}; dims; `tpd_have_button = 1`; down-branch `tpd_button`; **no** release call | PASS |
| Source probe order: power>gpio>**mask**>await>swinit>ms20>mem>eint>kthread>DataInit>**unmask**>confirm (EINT pre-mask before the first i2c contact) | PASS |
| Source: no `D23` / `manual rebind` / `keep-registered` tokens; `i2c_del_driver(&tpd_i2c_driver)` on the failure path | PASS |
| Compiled: `mtk_gslX680.o` carries the four `D25:` markers, the vendor 0xfc-failure string, a standalone `mtk-tpd` literal, `gsl_tp`/`gsl1680`/`gsl915` id literals, key/dim words {172,158}/{100,900,40,40}/{300,900,40,40}; **no** `D23`/`manual rebind`/`keep-registered` bytes | PASS |
| Compiled: link-order (E9) `__initcall_tpd_driver_init6 @0xc0c878d0` < `__initcall_mt_i2c_init6 @0xc0c87a30` | PASS |
| Compiled: **linked E1-style decode** — in vmlinux, our `tpd_i2c_driver`'s `.driver.name` pointer dereferences to `mtk-tpd` (ptr @0xc0af6fd8), id_table = {gsl_tp, gsl1680, gsl915}, no stray `gsl_tp` field references; `tpd_device_driver` = {name "gsl_tp", have_button = 1}; keys/dims in rodata | PASS |
| Image: `mtk-tpd` > 0, `virtualkeys.mtk-tpd` present, `mtk-tpd-kpd` present, `D25:` markers ≥ 1, exact `gsl_tp` literals ≥ 2, `gsl1680`/`gsl915` == blob == 1, **diagnostic bind-hint string = 0** | PASS |
| Warnings: **zero new** vs the board5 baseline — in fact the warning sets are byte-identical (654 = 654 lines, `comm` diff empty both directions; the D25-edited file emits **0** warnings in a full rebuild) | PASS |

(The Image still contains three `…cmd23…` MMC vendor strings that merely *contain* "d23" —
related to the SD host controller's CMD23, unrelated to, and pre-dating, the diagnostic
patch; the exact diagnostic markers are gone.)

---

## 5. Invariants I had to re-pin (with justification)

1. **Stage-65 whitelist for the reset-state check extended to board4/board5/board6 O-dirs.**
   Bob §5.2 says "clone 65's shape … board6 added to the whitelist". The tree currently
   carries `build-beta-touch-lcm-board4/` (removed at some point, but 64's diagnostic image
   history) and `build-beta-touch-lcm-board5/` — 65's hardcoded whitelist names only
   alpha…board3, so a literal clone would die on the *first* run with
   "unexpected reference-tree state". Re-pinned: whitelist now covers
   alpha/beta/beta-touch-lcm/board…board6 (board4 included defensively).

2. **Two of Bob's §5.2-4-string-parity ideas were replaced by strictly stronger proofs.**
   (a) "`mtk-tpd` string count increases …" and (b) exact-line `gsl_tp` counts at blob
   parity. Measured on the linked kernel: GNU ld tail-merges the driver-name literal into
   `virtualkeys.mtk-tpd` (tpd_button.c), so an `strings(1)` exact-line `mtk-tpd` can never
   appear in the Image; and the fork's LOGE-prefix composition (`"gsl_tp:[%04d]%s " +
   message` concatenation per call site) makes Image line-count parity with the blob
   structurally impossible (fork exact `gsl_tp` = 3 against the blob's 2 — the extra slot is
   our `.tpd_device_name` literal, which Bob §2.2 explicitly keeps). Re-pinned as:
   **linked E1-style decode** (§4 table) + object-level standalone-literal check + Image
   gates that remain sound (`mtk-tpd` substring > 0 = unchanged against board5; `virtualkeys.mtk-tpd`
   present; alias exact-literals == blob; exact `gsl_tp` ≥ 2 = id_table + client name).

3. **Added one gate beyond Bob's list — the single-`mtk-tpd`-name slot, made real.**
   Bob §6 row 1 argues no other i2c driver can race us because "every other panel dir is
   Kconfig-off" — but the a106-derived defconfig actually compiles `CONFIG_MTK_GOODIX9XX=y`
   and `CONFIG_MTK_EKTF2K=y` panel TUs into the framework dir (three
   `__initcall_tpd_driver_init6` slots, pre-existing). Verified at source level: Goodix
   names its i2c driver `"gt9xx"` and ektf2k `"ekft2k"` (its `.name = TPD_DEVICE` is only a
   trailing comment), so the `mtk-tpd` name slot remains exclusively ours; the stage now
   source-gates the competing compiled panels against an uncommented `.name = TPD_DEVICE`
   so a future defconfig/panel change cannot silently -EBUSY us.

4. **`tpd_button_setting` const-cast (implementation detail under Bob's pseudocode).** The
   framework's signature is `void tpd_button_setting(int, void*, void*)`; passing the const
   `int` tables bare produces a new `-Wdiscards-qualifiers` warning, which would break the
   zero-new-warnings gate. The tables stay `const` (rodata, like the blob's) and the call
   casts to `void *` explicitly with a comment noting the framework only memcpy()s from
   them (tpd_button.c:108).

5. **`gsl_eint_register` contract narrowed** (registered only; unmask moved to the probe
   tail). Bob's probe pseudocode ends with the unmask after `gsl_data_init_selected`, which
   is only consistent if the helper no longer unmasks; its single caller is the probe, and
   the registration arguments are unchanged. The probe-order gate pins the final order.

---

## 6. Known limitations / notes for Karen and Hera

- Hardware acceptance is still open (no flashing done here): `0-0040 → mtk-tpd`,
  `mtk-tpd` + `mtk-tpd-kpd` in `/proc/bus/input/devices`, physical swipe with
  `adb shell -tt getevent -lt`, volume keys, boot/display/charging regression sweep —
  §7 of the Bob spec is the checklist.
- The `mtk-tpd`/`gsl_tp` string **counts** in the δ-parity report vs the blob are printed
  for information; the *gates* are the structural ones above (line-count parity is not
  meaningful across the two builds' different log-site composition, see §5-2).
- `mtk-tpd` substring count = 54 lines in both board5 and board6 Images (the framework's
  own strings; our new log strings use the `gsl_tp:` prefix, so the count is unchanged —
  the rename is proven structurally by the linked-identity decode, not by counting).
- If hardware still NAKs after D25: H-SEQ/H-KERN/H-STATE remain (§4.3); the D26 diagnostic
  (separate O-dir/tag, never ships) is the discriminating step. Do not assert any cause.
- Rollback pins untouched: stock `boot-m1b-lithium-ctl.img` and the frozen
  `boot-m1b-beta-touch-lcm-board5.img` both hash as pinned.
- A stale `build-beta-touch-lcm-board6/` directory is a state gate: stage 66 tolerates it
  (incremental reuse, `mkdir -p` first use); a *fresh* run reproduces the identical zImage
  as proven in §2.

Implementation complete.
