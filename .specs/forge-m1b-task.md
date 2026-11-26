# Forge — Implement M1b (kernel rebuild: camera + charging)

## Read first
`.specs/bob-m2-spec.md` — your implementation spec is §4 (layout §4.0, M1b-α §4.1, M1b-β §4.2,
acceptance §4.3, forbidden §4.4). The exact delta table is §3 (D1–D16, with per-row before/after).
Follow it exactly — do not improvise board values.

## Scope — build BOTH sub-milestones in one dispatch
1. **M1b-α (parity build)** — §4.1: `make a106_defconfig && make zImage` in
   `.reference-kernel-3.10.54/kernel-3.10/` (toolchain `../arm-eabi-4.8/`), repack with Lithium's
   exact boot args (§4.1.3) + Lithium's stock ramdisk → `out/boot-m1b-alpha.img`.
2. **Parity check** — §4.1.2 + §3.2-B.10: decompress the α zImage, `strings -a`, and diff the
   driver-name inventory vs the Lithium blob `5217dd41…` (`~/.hermes/cache/scratch/opencode/bob-m1/lithium/kernel`).
   Record the report.
3. **M1b-β (delta build)** — §4.2: apply D1–D16 (charger/gauge drop, camera sensor port, lens port,
   AW87559 amp port + I2C bus-2 registration) exactly as tabled → `out/boot-m1b-beta.img`.

## Donor sources (§3.6 — hash-assert every one into `manifests/kernel-sources.sha256`)
- GC5004: `PersimmonProject/android_kernel_archos_persimmon_3_10`
- HI253/HI704: `CyanogenMod/android_kernel_mediatek_sprout`
- DW9714AF/DW9719AF: `bq/aquaris-E5FHD`
- AW87559 amp: `MotorolaMobilityLLC/kernel-mtk` (contract ref `artificery-dev/tempo`)

## Hard rules (from M1 §2.0 + M2 §4.4 — non-negotiable)
1. Kernel tree + donor sources are gitignored references; commit ONLY `patches/kernel/*.patch`,
   `manifests/kernel-sources.sha256`, and `build/4*_kernel*.sh`. Never commit the tree or `.img`.
2. Every §3 delta becomes a committed patch file (one per D-id, D-id in the commit message).
3. No 3.4.67 sources grafted in; no bct24157/MAX17050SW6106 port; no ramdisk edits; no invented
   GPIO/keypad values (D15/D16 are evidence-gated — leave at lineage defaults).
4. Idempotent + hash-asserted re-runs.

## Output (write INCREMENTALLY to `.specs/forge-m1b-report.md`)
- α build result + parity report (string-set diff vs the Lithium blob).
- β build result + which deltas applied (D1–D16 status).
- `out/boot-m1b-alpha.img` + `out/boot-m1b-beta.img` hashes + sizes.
- Warnings / any deviation from spec (with reason) / build errors.

## Gate note (do NOT flash anything — Hera owns the device)
After you finish, Hera runs G2 on the α image (boot parity) before any β flash. Your job ends at
producing both boot images + the report; do not attempt any device flash.
