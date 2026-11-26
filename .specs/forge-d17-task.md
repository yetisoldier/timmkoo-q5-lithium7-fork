# Forge — D17: port the GSL touch driver (HARD GATE — no flash without touch)

## Context (Eric's directive)
Do NOT flash any build without working touch. The β kernel (`m1b-beta`) lacks the GSL touch driver
(GAP-1 in `bob-m2-spec.md` §1.4). The Q5's touch is `gsl_tp` at **I2C bus 0, addr 0x40**
(GSL1680-family, live device `0-0040 gsl_tp`). The driver is built into the Lithium blob only
(`gsl_tp` + `cst2xx` strings); the heyrudra tree has NO touch driver (a106_defconfig has no
`CONFIG_CUSTOM_KERNEL_TOUCHPANEL`).

## What to do
1. **Find the donor.** A GSL1680 / gslX680 MTK-touchpanel driver for an MT6582-class 3.10.54 tree
   (`drivers/input/touchscreen/mediatek/gslX680/` or `…/GSL1680/`, or a `gsl1680.c` with the MTK
   `tpd_*` API). Check in order: `atharvnegi/kernel_xiaomi_selene` (already used for AW87559),
   `CyanogenMod/android_kernel_mediatek_sprout`, `PersimmonProject/android_kernel_archos_persimmon_3_10`,
   `bq/aquaris-E5FHD`, then any MT6582 3.10.54 tree with a GSL driver. Prefer a `tpd`-framework
   driver (matches how the Lithium blob registers `gsl_tp`), NOT a mainline-DT `silead.c`.
2. **Port it (D17).** Drop the driver into the tree's touchscreen/mediatek path; add the `tpd`
   glue (`tpd_custom.c`/`tpd_default.c` registration so the panel probes as the Q5's `gsl_tp`).
   Wire `CONFIG_CUSTOM_KERNEL_TOUCHPANEL` in `q5_defconfig` to the ported driver name.
3. **Wire the board.** Register the touch on I2C bus 0 addr 0x40 (board `core.c`/i2c info) and set
   the touch interrupt/reset GPIO in `cust_gpio_usage.h`. Do NOT invent GPIO numbers — take them
   from the donor's board example and cross-check against the Q5's live I2C map (bus 0 / 0x40) and
   the Lithium blob's touch strings.
4. **Rebuild β with touch.** `make q5_defconfig && make -j zImage` (same pinned toolchain/env as
   the m1b build). Run the parity check: the new blob MUST contain `gsl_tp`/`gsl1680`/`gslX680`
   strings, and must NOT regress the m1b-β set (gc5004/hi253/hi704/aw87559 present, bct24157/
   MAX17050SW6106/fan5405 absent).
5. **Repack** → `out/boot-m1b-beta-touch.img` (keep `boot-m1b-beta.img` untouched for comparison).

## Rules (unchanged)
- Hash-assert the donor into `manifests/kernel-sources.sha256`; commit the patch as
  `patches/kernel/D17.patch` (D17 in the commit message). Never commit the tree or `.img`.
- Idempotent + deterministic re-runs (same pinned build identity as m1b).
- Do NOT flash anything (Hera owns the device).

## Output (write to `.specs/forge-d17-report.md`)
- Donor repo + the exact driver files ported, and the tpd wiring you added.
- `q5_defconfig` + `cust_gpio_usage.h` + I2C registration changes.
- Parity result (gsl strings present; m1b-β set intact).
- `out/boot-m1b-beta-touch.img` hash + size.
