# Q1b — Kernel source decision (resolved 2026-11-25)

## Resolution
The exact 3.10.54 MT6582 kernel tree used for the Lithium/T-ROM "innioasis117" build is
**not published**. Verified by listing both orgs: T-ROM-Project has device trees (CM-12.1) +
vendor blobs but no `android_kernel_*` repo; NoahDomingues/Lithium is an unpacked system.img
only. The kernel was built by the manufacturer (`wangliang@innioasis117`) and never open-sourced.

**Decision: proceed with Q1b — port the Q5 board config onto a public 3.10.54 MT6582 tree.**

## Candidate public trees (3.10.54 MT6582, ALPS Lollipop family)
- `MTK-Kernels/android_kernel_mediatek_mt6582` — generic MT6582 base (verify version)
- `heyrudra/android_kernel_micromax_a106` — Micromax Unite 2, Lollipop Stock 3.10.54
- `s0rd3s/android_kenel_alps_lcsh6582_w_l` — Lenovo A3300, 3.10.54
- `Ultimate-1/android_kernel_senseit_e400_mt6582` — Senseit E400, 3.10.54
- `assusdan/android_kernel_huawei_h30u10-3.10` — Huawei H30U10, 3.10.54

## Board config source (no full source needed)
The boot.img carries the COMPILED zImage, not source — so the source must come from a public
tree. But the BOARD CONFIG (the hardware-specific values the port actually needs) is recoverable
from the binaries:
- Lithium/T-ROM 3.10.54 kernel blob `5217dd41…` — string inventory (driver set: bct24157,
  MAX17050SW6106, aw87559_pa, mt6323, ccci, mali, kpd) already done (Bob E5/E8).
- Mint 3.4.67 kernel binary — battery-profile tables, sensor list, kpd matrix (ground truth for
  the Mint hardware; extract via string tables + DCT data).

## What this feeds
Bob's M2 design (§2.7 of the M1 spec already enumerates the board-config deltas source-agnostically).
The M2 task = pick one 3.10.54 tree, reconstruct the Q5 board config (ProjectConfig.mk,
cust_gpio_usage.h, cust_kpd.h, cust_battery*.h, imgsensor list), and enumerate the exact deltas.
