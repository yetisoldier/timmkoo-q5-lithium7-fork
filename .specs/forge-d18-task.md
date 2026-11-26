# Forge — D18: port the gc9503v LCM (display) — dark-screen fix

## Context (hard preserve — Eric)
The β+touch build uses the donor tree's `hx8369b_wvga_dsi_vdo_tinno` panel (a106 board), but the
Q5 uses **`gc9503v_wvga_dsi_vdo`** (confirmed: Lithium blob has gc9503 strings; bob-m2-spec OQ-7).
Without this, the device boots but the **SCREEN IS DARK**. Display is a must-preserve function.

## What to do
1. **Find the donor** — a `gc9503v_wvga_dsi_vdo` LCM driver for an MT6582 3.10.54-class tree
   (`drivers/misc/mediatek/lcm/gc9503v_wvga_dsi_vdo/` or similar). Bob's OQ-7 suggests
   `bq/aquaris-E5FHD` or `CyanogenMod/android_kernel_mediatek_sprout`. Search those + any MT6582
   tree with a gc9503v LCM.
2. **Port it (D18)** — drop the lcm driver into the tree's lcm path, add it to the lcm Makefile/Kconfig
   list (follow the in-tree hx8369b pattern for the registration/init signature).
3. **Wire it** — `CONFIG_CUSTOM_KERNEL_LCM="gc9503v_wvga_dsi_vdo"` in `q5_defconfig` (replace the
   hx8369b entry; keep `CONFIG_LCM_HEIGHT="800"` / `CONFIG_LCM_WIDTH="480"`).
4. **Rebuild β+touch+D18** — parity: `gc9503v` strings present, `hx8369b` gone; every other m1b-β
   count unchanged (gsl_tp 19, ccci 750, mali 809, aw87559 3, dw9714 28, dw9719 53, FGADC 24;
   must-nots 0).
5. **Repack** → `out/boot-m1b-beta-touch-lcm.img` (leave the touch-only image untouched).

## Rules (unchanged)
- Hash-assert the donor into `manifests/kernel-sources.sha256`; commit as `patches/kernel/D18.patch`
  (D18 in the message). Never commit the tree or `.img`.
- Deterministic + idempotent re-runs (same pinned build identity). No flashing (Hera owns the device).

## Output (write to `.specs/forge-d18-report.md`)
- Donor repo + the lcm driver files ported + the wiring.
- Parity result (gc9503v in, hx8369b out, m1b-β set intact).
- `out/boot-m1b-beta-touch-lcm.img` hash + size.
