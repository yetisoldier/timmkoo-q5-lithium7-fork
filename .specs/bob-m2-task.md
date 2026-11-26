# Bob — Design M1b (kernel rebuild: camera + charging)

## Read first (all in this repo)
1. `.specs/bob-m1-spec.md` — esp. §2.7 (M1b board-config delta, source-agnostic), §1.6 ADR-5
   (camera), §1.4 ADR-3 (charging, Case A/B/C), §1.7 ADR-6 (kernel sourcing).
2. `.specs/q1b-kernel-source-decision.md` — Q1b resolution + candidate 3.10.54 trees.
3. `.specs/hardware-facts-q5-mint.md` — live Mint baseline (charging works; Hynix camera on
   I2C 0-005a; AW87559 amp on I2C bus 2 addr 0x58).
4. `.specs/hermes-release-plan-v0.1.0-combined.md` — this is a COMBINED release (no M1a alone).

## Objective
Design the M1b kernel rebuild: a 3.10.54 MT6582 kernel that runs the Lithium Android-7 userspace
but with the Q5 Mint board config, fixing (1) front camera (Hynix HI253/HI704 sensor list) and
(2) charging (correct gauge/charger board config).

## What to do

1. **Pick + clone the kernel tree.** From the Q1b candidates, choose a 3.10.54 MT6582 tree
   (Lollipop ALPS.L0 family). Verify it is actually 3.10.54 (check `Makefile` VERSION/PATCHLEVEL)
   and has a complete `mediatek/` tree (`drivers/misc/mediatek/power/mt6582/`,
   `mediatek/custom/`, `mediatek/config/mt6582/ProjectConfig.mk`). Clone `--depth 1` into a
   gitignored `.reference-kernel-3.10.54/`. If the first candidate is incomplete, try the next.

2. **Extract the Mint board config.** From the Mint 3.4.67 kernel binary
   (`~/.hermes/q5-recovery/base/Mint_V1.0/boot.img` → unpack → kernel blob), recover the
   hardware-specific values the port needs:
   - battery profile + fuel-gauge tables (capacity curve, R_sense, NTC, FGADC params) — around
     the `[FGADC]` / `[FG]` / battery strings.
   - charger selection (Mint uses NO external charger IC — autonomous SW6106; confirm no
     fan5405/bct24157 string in Mint blob).
   - camera sensor list (GC5004_RAW, HI253_YUV, HI704_YUV — already in Bob E8) + per-sensor I2C
     addrs/power-gpio order.
   - keypad matrix + GPIO usage (cust_kpd / cust_gpio_usage) — the 3-side-button + home map.
   - I2C bus assignments (AW87559 on bus 2 addr 0x58 — the hardware-facts note).
   Use `strings` + targeted binary search; the 3.4.67 binary's DCT data is the ground truth.

3. **Enumerate the exact deltas** (§2.7 structure): for each board-config file, state the
   before/after value or the new entry — `ProjectConfig.mk` (battery/charger/sensor feature
   flags), `cust_battery*.h` / `cust_battery_meter.h` / `cust_fuel_gauge.h`, `cust_gpio_usage.h`,
   `cust_kpd.h`, `kd_sensorlist.h` / `imgsensor` list + `lenslist` (keep DW9714/DW9719), and the
   charger config (ADR-3: drop bct24157 selection → pmic-only/autonomous, per the Mint ground
   truth; gauge = FGADC with Mint battery profile, since the SW6106 hybrid gauge is not in the
   Mint kernel).

4. **Charging case note.** Hera has the Mint baseline (charges, 0→18%). The Lithium/T-ROM
   baseline (flash + dmesg) is still pending — that determines Case A (gauge mis-probe) vs B
   (charge-disable). Design BOTH in the delta table; mark which branch each delta belongs to.

## Output — write INCREMENTALLY to `.specs/bob-m2-spec.md`
1. **Chosen tree** (repo + version proof + completeness note).
2. **Mint board-config extraction** (the recovered values, with where you found them).
3. **Board-config delta table** (exact before/after per file, camera + charging + keys + GPIO +
   I2C).
4. **Implementation spec for Forge M1b** (build steps, toolchain, the exact edits, the defconfig
   parity check vs the `5217dd41…` blob).
5. **Open questions / risks** (e.g. anything not recoverable from the binary that needs the G3
   Lithium-baseline flash to resolve).

End with "Design complete" or "partial (blocked on X)" + the remaining entry points.
