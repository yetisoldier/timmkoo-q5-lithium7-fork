# Forge — D18 implementation report (gc9503v WVGA LCM port — dark-screen fix)

**Task:** `.specs/forge-d18-task.md` (display = must-preserve; bob-m2-spec OQ-7).
**Status: COMPLETE — β+touch+D18 kernel built, parity PASS (gc9503v in / hx8369b out / full
m1b-β+D17 set intact), `out/boot-m1b-beta-touch-lcm.img` packed & hash-pinned; α/β/β-touch
artifacts byte-untouched; NO flashing performed.** Commit: adds `patches/kernel/D18.patch`
(D18 in the message), donor pins in `manifests/kernel-sources.sha256`, pipeline `build/61_kernel_delta_lcm.sh` + `55_repack_boot.sh beta-touch-lcm` tag.

---

## 0. Session log (incremental)

- Working from HEAD `b70087b` (D17). Scratch: `~/.hermes/cache/scratch/opencode/forge-d18/`.
- Forensic tooling reused from D17: the pinned Lithium decomp (`d284ba16…`) rebuilt into the
  symbol-aware ELF (`lithium.elf`) + kallsyms (`lithium.syms`); GC9503V driver region decoded with
  the in-tree arm-eabi-4.8 objdump; the blob's `LCM_PARAMS`/`LCM_UTIL_FUNCS` layouts verified
  against this tree's `lcm_drv.h` (host-compiled offsetof probe).

## 1. Donor search (task step 1) — the honest result

The task's suggested donors carry **no gc9503 LCM at all**:

| Donor (as instructed / priority) | gc9503v? | Finding |
|---|---|---|
| `bq/aquaris-E5FHD` | ✗ | `git ls-tree -r` grep: zero gc9503 anywhere |
| `CyanogenMod/android_kernel_mediatek_sprout` | ✗ | zero gc9503 |
| `PersimmonProject/…persimmon_3_10`, oxygen, motorola, selene (already cloned) | ✗ | zero gc9503 in their full git trees |
| Public code indexes: grep.app, Sourcegraph global (incl. `archived:yes fork:yes`), searchcode, DuckDuckGo, GitHub issue search for `gc9503v_wvga_dsi_vdo(_hsd/_boe)` | 0 hits | the exact name is essentially unindexed outside ROM blobs |

**The one Public GC9503V implementation in this ODM's lineage:** `SchulzCode/Y2Linux`
@ `c53427ae21fcefad575385e02868f322c383c36a` (GPL-2.0), the Linux CFW for the **Innioasis Y2 —
board `eastaeon82_wet_kk`, MT6582** (same Chinese-ODM family as the Q5; the Q5's own Lithium
kernel was built by `wangliang@innioasis117` per the Q1b decision). Its `kernel/platform/panel.c`
(documents, from an independent stock-binary decode: the GC9503V ID contract "DCS 0x04 =
xx 95 03/04", the 0xF0 `{55 AA 52 08 00}` unlock block, gamma rows 0xD1–0xD6, the
reset-high/low/high init pulse, packet-type rule ≤0xAF = DCS vs >0xAF = generic write, and the
suspend epilogue that "leaves reset HIGH for 50 ms"; plus its two-panels-per-product hazard:
GC9503V vs ST7701S across units). Pinned as `donors/y2linux/kernel/platform/panel.c`
(`d7e64b98…`) — **corroboration donor: the port's command tables are NOT taken from it**, they
are decoded from the Q5's own blob (§2); the Y2's panel is a sibling product's HVGA variant, and
its tuning values differ row-by-row from the Q5's WVGA table (Y2Linux's "never send one panel's
commands to the other" applies between Y2 and Q5 too).

**Driver-search escalation note for Bob:** no public tree carries `gc9503v_wvga_dsi_vdo*`. The
port therefore uses the only *valid* donor in this device family (Y2Linux = documented vendor
contract) with the authoritative data from the pinned blob — the same evidence-locked model as
D17 (donor skeleton + blob data). Alternative donors (bq/sprout trees with unrelated panel ICs)
would have been pure guesswork and were rejected.

## 2. Q5 ground truth — forensics on the pinned Lithium blob + the Q5's own LK

### 2.1 What the Q5's bootloader hands the kernel (name contract)

The Q5's **own preboot LK** (`T-ROM_V2.3/lk.bin` = `Manufactory_latest/appsboot.raw`,
sha `a9b556db…` — already hash-documented in the recovery-base manifest; now pinned as
`donors/lk-q5.bin`) carries exactly four LCM driver names and the format string
`%s lcm=%1d-%s`:

```
gc9503v_wvga_dsi_vdo_hsd      gc9503v_wvga_dsi_vdo_boe
st7701_wvga_dsi_vdo_ivo       st7701_wvga_dsi_vdo_dingsj
```

So at boot the kernel's cmdline contains `lcm=<n>-<one of these four names>`. This kills the
task step-3 literal wiring (`CONFIG_CUSTOM_KERNEL_LCM="gc9503v_wvga_dsi_vdo"`): in
`drivers/misc/mediatek/video/mt6582/disp_drv.c`, `disp_get_lcm_name_boot()` sets
`isLCMFound = 1` for **any** non-empty name after `lcm=?-` — before knowing whether a driver
matches; `DISP_SelectDeviceBoot()` name-misses leave `lcm_drv = NULL`, and
`disp_drv_init_context()` then **skips** `DISP_DetectDevice()` (compare_id auto-detect never
runs) — the device boots with a dark screen *even with the right driver compiled under the
wrong name*. That is precisely the failure being fixed. **The wiring deviation (documented in
the D18.patch prologue): the defconfig sets both blob-locked names,
`CONFIG_CUSTOM_KERNEL_LCM="gc9503v_wvga_dsi_vdo_hsd gc9503v_wvga_dsi_vdo_boe"` — the exact
build shape of the Q5 vendor kernel.** `CONFIG_LCM_HEIGHT="800"`/`CONFIG_LCM_WIDTH="480"` kept
(blob params are 480×800).

### 2.2 The blob's LCM inventory and driver structure

- `lcm_driver_list[]` @VA `0xc0b8a458` = `{st7701_ivo, st7701_dingsj, gc9503v_hsd, gc9503v_boe}`
  (4 entries; `nt35510_wvga_dsi_vdo` is compiled but unlisted — inert, same as a106-side extras).
- Two GC9503V `LCM_DRIVER` structs @VA `0xc0b8c9fc` (hsd) / `0xc0b8f184` (boe) — layout matches
  this tree's `lcm_drv.h` exactly (name / set_util_funcs / get_params / init / suspend / resume /
  … / compare_id); only those six pointers non-NULL, the rest NULL (a minimal vendor driver).
- `LCM_PARAMS` layout == this tree's header (mode @0x14c, LANE_NUM @0x160, data_format @0x164,
  intermediat @0x174, PS @0x178, word_count @0x17c, V/H timings @0x184–0x1a8, PLL_CLOCK @0x200,
  cont_clock @0x214); the vendor's `sizeof` 688 vs this tree's 696 = the tree's extra
  `od_table` tail (12 bytes beyond `physical_height`, no DSI semantics). `LCM_UTIL_FUNCS`
  offsets match at ARM32 (mdelay @0x10, dsi_set_cmdq_V2 @0x24, dsi_set_cmdq @0x28,
  dsi_dcs_read_lcm_reg_v2 @0x3c); vendor memcpy 92 B vs tree 88 B = one trailing unused
  vendor-only pointer, never called by the gc9503v code — the port uses `sizeof(LCM_UTIL_FUNCS)`
  provider/consumer-consistently.
- **Parameters (both variants, `lcm_get_params` @0xc03d0f64/0xc03d159c — byte-identical
  stores):** type DSI; 480×800; `dbi.te_mode=VSYNC_ONLY(1)/rising(0)` (blob head bytes 0x48=1 /
  0x4c=0 — feed only LCD-TE init, inert for a DSI panel; replicated for byte parity);
  `mode=SYNC_PULSE_VDO_MODE`, two lanes, RGB color order / MSB-first / LSB-pad / **RGB888 packed
  24-bit**, word_count 1440 = 480×3, `packet_size` left 0 (blob never writes it; nothing in this
  tree's mt6582 disp stack consumes `dsi.packet_size`), vertical **8/60/60 active 800**,
  horizontal **10/20/20 active 480**, `PLL_CLOCK=200`, `cont_clock=1`.
- **compare_id @0xc03d0e88 (hsd) / 0xc03d14b8 (boe):** reset pulse high 5 ms / low 25 ms / high
  120 ms; `dsi_set_cmdq({0x00033700}, 1, 1)` read setup; `read_reg_v2(0x04, buf, 3)`;
  id = (buf[1]<<8)|buf[2]; print `"gc9503v kernel id = 0x%x  %x %x %x"` (hsd, args id/buf0/buf1/
  buf2) or `"gc9503v boe %s,buffer[0]=0x%x,buffer[1]=0x%x,id = 0x%x"` (boe, args func/buf0/buf1/
  id); hsd accepts **0x9503 | 0x9504**, boe **0x9505 | 0x9506** (two GC9503V mask/ID classes =
  the two panel vendors' part lots). Cross-checked with Y2Linux's independent decode ("0x04 =
  xx 95 03/04").
- **init/resume @0xc03d10d0 (hsd), 0xc03d1708 (boe):** SET_RESET_PIN high 10 ms / low 10 ms /
  high 120 ms + push_table. hsd init table **49 rows** @0xc0b8b13c, boe **43 rows** @0xc0b8da74.
  `lcm_resume` is exactly `lcm_init` (tail-call), same as the in-tree hx8369b pattern.
- **suspend @0xc03d1164 (hsd) / 0xc03d179c (boe):** the **39-row analog power-down table**
  (both variants byte-identical; @0xc0b8bf04 == @0xc0b8e68c): 0xF0-unlock, rail shrink rows,
  0x28 display-off, 20 ms, 0x10 sleep-in, then the 0xF0-unlocked final rail block, then
  **SET_RESET_PIN(1) + 50 ms** (reset left HIGH — exactly the sequence Y2Linux documents
  independently from the Y2's stock kernel).
- **Table encoding:** the vendor's `push_table` (blob 0xc03d1040/0xc03d1678) treats `0xFFE` rows
  as `mdelay(count)` and `0xFFF` as end marker (NOT this tree's older 0xFE/0x00 convention) —
  the port reproduces the vendor literals so the byte stream matches.
- **Tiling proof:** hsd init 49×72 B ends exactly at the hsd suspend table; 39×72 B ends exactly
  at the hsd `LCM_DRIVER` struct (zero gap). boe init 43×72 ends at 0xc0b8e68c (with a 256 B
  constant-table gap), suspend 39×72 ends exactly at the boe struct. 170 rows total were
  round-trip-parsed out of the generated C and re-compared byte-exact with the pinned decomp
  (checker `PASS — all 170 rows match the pinned blob's transmitted bytes`).

## 3. The port (task step 2) — files & wiring

`patches/kernel/D18.patch` (one file, D18 in the prologue) adds/changes:

1. `drivers/misc/mediatek/lcm/gc9503v_wvga_dsi_vdo_hsd/gc9503v_wvga_dsi_vdo_hsd.c` (new, 352
   lines) — hx8369b-pattern driver; `.name = "gc9503v_wvga_dsi_vdo_hsd"`; all functions and
   tables as decoded in §2.2 (49-row init, shared 39-row suspend, compare_id with the hsd ID
   window and printk format).
2. `drivers/misc/mediatek/lcm/gc9503v_wvga_dsi_vdo_hsd/Makefile` (new) — hx8369b Makefile
   convention (`obj-y += …` + `Makefile.custom` include).
3. `drivers/misc/mediatek/lcm/gc9503v_wvga_dsi_vdo_boe/gc9503v_wvga_dsi_vdo_boe.c` (new, 346
   lines) — `.name = "gc9503v_wvga_dsi_vdo_boe"`; 43-row init table; boe ID window (0x9505/
   0x9506) and printk format.
4. `drivers/misc/mediatek/lcm/gc9503v_wvga_dsi_vdo_boe/Makefile` (new).
5. `drivers/misc/mediatek/lcm/mt65xx_lcm_list.c` (+12) — both externs + `#if defined(...)` list
   entries right after the tinno group (the defines come from `Makefile.custom`'s
   `CONFIG_CUSTOM_KERNEL_LCM` `-D` pass-through, exactly like hx8369b).
6. `arch/arm/configs/q5_defconfig` — `CONFIG_CUSTOM_KERNEL_LCM="gc9503v_wvga_dsi_vdo_hsd
   gc9503v_wvga_dsi_vdo_boe"` (replaces the hx8369b entry; `CONFIG_LCM_HEIGHT/WIDTH` untouched).

**Task step-3 deviation, restated for the record:** the literal `CONFIG_CUSTOM_KERNEL_LCM=
"gc9503v_wvga_dsi_vdo"` cannot be honored — that name matches no compiled driver in the Q5
blob and no string the Q5 LK can pass; the disp boot flow pins `isLCMFound=1` on any `lcm=?-`
name and never falls back to compare_id, so an unsuffixed entry would re-create the dark
screen it is meant to fix. The evidence-locked equivalent (both blob names, one driver dir
each — what the vendor itself shipped) is what landed. If a later boot log shows a unit with a
ST7701S panel (LK's other two names), that becomes an evidence-gated D19 follow-up.

## 4. Build + parity (task steps 4–5)

Pipeline: new `build/61_kernel_delta_lcm.sh` = the m1b-β sequence with D17 applied after, **D18
last**, built into a **separate O dir `build-beta-touch-lcm`**, extended D18 invariants,
extended δ-parity; then `55_repack_boot.sh beta-touch-lcm` (tag added additively; alpha/beta/
beta-touch behavior unchanged). 50/60 got additive hygiene only (D18 lcm dirs now in their
reset rm-list, `build-beta-touch-lcm` whitelisted in the pristine-audit) — pinned behavior
unchanged (cf. D17 report §5.3).

- **β-touch-lcm zImage**: 4,264,352 B, sha256
  **`b5bf28c39a016f54ae2378c0fb96ba0db8cb467506642a654fe9ea0fa7100e39`**
- **β-touch-lcm Image**: 14,113,192 B, sha256
  `0e97a6c0cc0767632d31da8a3c33ed0ba1501e6e3e872a64229e46f088614fd2`
- Banner (pinned identity): `Linux version 3.10.54 (forge@fork) (gcc version 4.8 (GCC)) #1 SMP
  PREEMPT 2026-11-25T13:47:27-06:00`
- **Determinism:** 61 re-run — identical zImage sha both times; byte-flat incremental. A fully
  fresh O dir **inside the reference repo** (`build-fresh-lcm-probe`, since removed) reproduced
  end-to-end twice (`7dff183d…`) and its Image differs from the pinned incremental Image in
  **exactly 20 bytes** — the `.note.gnu.build-id` description (sha over vmlinux ELF metadata,
  not shipped code) — the same fresh-vs-incremental property the m1b-β and D17 documented.
  Diagnostic caveat for the record: an O dir **outside** the reference git repo is *not*
  byte-equivalent — the mali Kbuild embeds `SVN_REV_STRING` from `git describe --always` run in
  the build tree (absent → different bytes + layout). Every pinned pipeline O dir lives inside
  `.reference-kernel-3.10.54/` by design, so the property holds; flagged in the risks below.
- **δ-parity `out/kernel-parity-beta-touch-lcm.txt`** (grep -ic line hits):

| D18 must-have | β-touch-lcm | Lithium blob | verdict |
|---|---|---|---|
| `gc9503v_wvga_dsi_vdo_hsd` | 1 | 1 | ✓ exact name parity |
| `gc9503v_wvga_dsi_vdo_boe` | 1 | 1 | ✓ exact name parity |
| `gc9503v kernel id` (hsd printk) | 1 | 1 | ✓ |
| `gc9503v boe` (boe printk) | 1 | 1 | ✓ |
| `gc9503v` total | 6 | 4 | ✓ (the 2 extra are truncated `Dgc9503v_wvga_ds` copies of the names in a second section — name bytes, no new content) |
| `hx8369b` | **0** | 0 | ✓ **hx8369b gone** from the blob |

| β-carry-over (no regression) | β-touch-lcm | m1b-β (pinned §2.3/§4) | verdict |
|---|---|---|---|
| gc5004mipiraw / hi253yuv / hi704yuv | 2 / 6 / 7 | 2 / 6 / 7 | ✓ identical |
| dw9714 / dw9719 | 28 / 53 | 28 / 53 | ✓ identical |
| `aw87559_pa` | 3 | 3 | ✓ |
| ccci / mali / mt6323 / mtk-kpd / auxadc | 750 / 809 / 19 / 1 / 210 | 750 / 809 / 19 / 1 / 210 | ✓ |
| battery_meter+[FGADC] | 24 | 24 | ✓ |
| gsl_tp / gsl1680 / gsl915 / gslX680 / GSLX680_FW / gsl_alg_id_main / gsl_config | 19 / 1 / 1 / 4 / 4 / 1 / 3 | D17 β-touch values | ✓ identical |
| must-not bct24157 / MAX17050SW6106 / fan5405_config_interface | 0 / 0 / 0 | 0 / 0 / 0 | ✓ |

Parity verdict: **PASS — the LCM delta is purely additive; every m1b-β and D17 count
unchanged; both gc9503v variant names + both printk formats exactly match the blob.**

### 4.1 Repacked image (task step 5)

`build/55_repack_boot.sh beta-touch-lcm` → **`out/boot-m1b-beta-touch-lcm.img`**:

- **Size: 5,662,720 B, sha256 `16ae327ca95ec006c863dfa142bba3d5eea8d9d036263ea2bb873b0a06052be1`**
- Header fields byte-identical to the donor except kernel size (4,264,864 = 512 +
  4,264,352); ramdisk region byte-identical to the donor blob (`c0be6c46…`); re-run of 55
  reproduces the image byte-for-byte.
- Untouched (verified re-hash): `out/boot-m1b-beta-touch.img` **`2c6d5753…`**, `out/boot-m1b-beta.img`
  **`2c3ac47a…`**, `out/boot-m1b-alpha.img` **`d886ccfe…`** — the touch-only image exactly as the
  task requires.

## 5. Developer notes / risks (for Bob & Hera; no blocker found in evidence)

- **Boot-time selection is name-driven** (LK's `lcm=<n>-<name>`), with compare_id as an
  in-Driver fallback only for no-`lcm=` cmdlines. Our two-driver list covers every gc9503v name
  the Q5's LK can pass. On boot expect dmesg `[LCM Auto Detect] … [LCM Specified]
  [gc9503v_wvga_dsi_vdo_hsd|boe]` — the LK's own detect (`gc9503v %s,…id = 0x%x` / `gc9503v boe
  %s,…` prints) names the panel vendor before the kernel runs.
- **Backlight is a separate subsystem**: the blob's LCM drivers leave `set_backlight=NULL`
  (GC9503V panels here are PWM-led driven via the mt65xx leds/PWM stack and the a106-clone
  `cust_leds`/GPIO map — untouched, per D16's no-speculative-edits rule). If G2 shows a lit
  panel with black backlight, that is an evidence-gated LED/PWM-config delta, NOT this driver.
- If Hera's unit happens to carry the **ST7701S** panels (LK's `st7701_wvga_dsi_vdo_ivo/dingsj`
  names), the screen stays dark and the boot log will show `st7701s …` prints from LK + no
  kernel LCM match — that is LK-side evidence for a D19 (the blob also compiled both st7701s
  drivers; they'd port the same way).
- The mali `SVN_REV_STRING` git-describe dependency (see §4 determinism caveat) means build
  O dirs must stay inside `.reference-kernel-3.10.54/` — the pinned scripts already guarantee
  it; no action needed, just don't relocate O dirs to non-repo scratch.
- Deferred (not ported): the blob's `nt35510_wvga_dsi_vdo` (compiled-but-unlisted in the blob;
  inert), the two st7701s drivers (out of D18's gc9503v scope), and the Y2Linux-style
  `power_down/stock_suspend` module params (not applicable to this vendor LCM API).

## 6. Artifacts & bookkeeping

- `patches/kernel/D18.patch` (D18 prologue + commit message); donor pins appended to
  `manifests/kernel-sources.sha256` (`donors/y2linux/kernel/platform/panel.c` `d7e64b98…`,
  `donors/lk-q5.bin` `a9b556db…` @ `SchulzCode/Y2Linux c53427ae` + LK provenance comments);
  `donors/y2linux/` (full clone) and `donors/lk-q5.bin` (symlink into `~/.hermes/q5-recovery`)
  are gitignored references.
- `out/kernel-parity-beta-touch-lcm.txt` — the parity report quoted in §4.
- `out/boot-m1b-beta-touch-lcm.img` — **5,662,720 B, sha256 `16ae327ca95ec006c863dfa142bba3d5e
  ea8d9d036263ea2bb873b0a06052be1`** (+ `.img.sha256` sidecar).
- `git ls-files` contains no kernel tree, no `.img`/`.bin`; `donors/` and `out/` stay
  gitignored per repo policy.

**Hera hand-off:** the flash candidate for the combined gate is now
`out/boot-m1b-beta-touch-lcm.img` (BOOT only, system = stock Lithium). Expected on boot:
`uname -r` 3.10.54, dmesg `[mtkfb] LCM is connected` + `[LCM Specified] [gc9503v_wvga_dsi_vdo_hsd|boe]`
+ `[mtkfb] LCM resolution: 480 x 800`, plus `0-0040 gsl_tp` and one `mtk-tpd` input device from
D17. **No flashing performed by Forge — flash is Hera's gate.**
