# Hermes Release Plan — Q5 Lithium 7 Fork v0.1.0 (COMBINED)

## Decision (Eric, 2026-11-25)
Do NOT ship M1a (audio + buttons) alone. The M1a base is the Lithium system.img, whose kernel
still has the charging defect (stuck 0-1%) — a device that can't charge is worse than one with
broken audio. **Ship M1a + M1b together as one fork** so the device comes up with all four fixes.

## Workstreams (both must land before the release commit)
1. **M1a** — system.img patch (audio + buttons). Forge implementing now.
2. **M1b** — kernel rebuild (camera + charging): Hynix sensor-list port + charging board config,
   on a public 3.10.54 MT6582 tree (Q1b decision: `q1b-kernel-source-decision.md`).

## Sequencing
- M1a (Forge) and M1b-design (Bob M2) run in parallel (disjoint files: `build/`+`out/` vs `.specs/`).
- M1b implementation (Forge M1b) after Bob M2 spec.
- One combined validation (Karen) + one hardware round (Hera G0–G6) over the FULL fork.
- One version stamp, one commit, one release tag `v0.1.0` pushed to GitHub + Gitea.

## Release gate
The device must boot Android 7.1.2 with: charging (SOC climbs), speaker + aux + BT audio,
all physical buttons + nav, front camera enumerating, **and TOUCH working** — all verified on
hardware. No partial ship.

## Hard gate (Eric, 2026-11-25): touch is mandatory
Do NOT flash any build unless touch works. The β kernel currently lacks the GSL touch driver
(GAP-1 in bob-m2-spec §1.4: the heyrudra tree has no GSL driver; the Q5's `gsl_tp` at I2C 0x40
needs a GSL1680-family driver that is built into the Lithium blob only). A touch port (D17) is a
required delta before any flash: find a GSL1680/gslX680 MTK-touchpanel donor (I2C 0x40), wire
`CONFIG_CUSTOM_KERNEL_TOUCHPANEL` + board I2C + touch GPIO, rebuild β, and only then flash.
