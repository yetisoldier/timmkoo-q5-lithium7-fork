# Hardware facts — Q5 Mint (live device, Mint KK base, 2026-11-25)

> **Correction, 2026-11-26:** The camera identification below was inferred
> incorrectly from a device name. Mint's `cst2xx_ts_init` registers
> `Hyn_device` at I²C0:0x5a, and `cst21680se_ts_init` registers
> `Hyn_device_cst2xx` at I²C0:0x5d. Both belong to CST touch-controller drivers.
> These entries do not identify Hynix camera sensors. The ported HI253/HI704
> drivers use 8-bit write IDs 0x40/0x60 (7-bit addresses 0x20/0x30).
> Mint's libcameracustom SensorList is a 56-byte zero-initialized terminator,
> and the reference kernel exposes no camera SensorInit functions. A lens-like
> feature was reported by the user, but camera operation on this unit has not
> been demonstrated. Treat sensor identity/presence as unresolved. The original
> session notes below are retained as historical evidence, not current facts.

## Charging (Mint baseline — G3 data point)
- Battery climbed **0% → 18%** over this session; voltage now **3617 mV**, "Charging", USB powered.
  ⇒ Mint hardware charges AUTONOMOUSLY (SW6106 without host control), consistent with Bob E5.
- Mint `power_supply` exposes `capacity` (18) but NOT `current_now`/`voltage_now`; `dumpsys battery`
  shows no `Max charging current/voltage` fields. ⇒ "Max charging current 0" is a **cosmetic**
  artifact of the MTK vendor stack not exporting those sysfs attributes — NOT the fault itself.
- The real Lithium symptom ("SOC stuck 0–1%") is therefore the Lithium kernel's
  `MAX17050SW6106`/`bct24157` drivers mis-probing the Mint hardware (gauge returns garbage / charger
  toggles into thin air), while Mint's own kernel has neither driver and just works.

## I2C device map (Mint, /sys/bus/i2c/devices/)
| Bus:addr | Driver/name | What it is |
|---|---|---|
| 0-0040 | gsl_tp | touch panel |
| **0-005a** | **Hyn_device** | **Hynitron CST touch-driver board entry; not a camera ID** |
| 0-005d | Hyn_device_cst2xx | CST touch-driver variant board entry |
| 1-0036 | CAM_CAL_DRV | camera calibration |
| 1-0050 | dummy_eeprom | — |
| 2-0018 | DUMMY | — |
| **2-0058** | **aw87559_pa** | **Awinic AW87559 speaker amp (I2C bus 2, addr 0x58)** |

## Battery capacity
**2000 mAh** (confirmed by Eric from the product listing/ad) — matches Bob's D4 `Q_MAX` default.
FGADC aging-learning still refines it over charge cycles; initial SOC slope is now accurate.

## Notes for M1b port
- Original camera=Hynix inference was incorrect; sensor identity remains unknown.
- AW87559 on **I2C bus 2** under Mint's 3.4.67 kernel (earlier Lithium observation was bus 1) — the
  bus numbering is a board-config detail the M1b rebuild must get right.
- Charging fix likely Case A (gauge mis-probe) and/or Case B (bct24157 charge-disable), NOT Case C —
  the "stuck at 0%" is real on Lithium, cosmetic only on the current/voltage-max dumpsys fields.
