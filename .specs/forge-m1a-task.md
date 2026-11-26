# Forge — Implement M1a (audio + buttons) system.img patch

## Read first
`.specs/bob-m1-spec.md` — your implementation spec is §2.0–2.6. Follow it exactly:
- §2.0 repo layout + hard rules
- §2.2 the exact 9-op table (audio pair swap + delete mixer stub + keylayout + build.prop)
- §2.5 literal merged `mtk-kpd.kl` content
- §2.6 literal `Generic.kl` patch
- §2.9 coding conventions (bash, set -euo pipefail)
- §2.10 open questions — do NOT resolve by guessing

## Scope — M1a ONLY
Implement the system.img-only patch (audio + buttons). Do NOT touch boot.img / kernel / camera /
charging (those are M1b, gated on kernel source). Do NOT modify any file outside the 9-op table.

## What to build
1. `build/` pipeline scripts (`00_env.sh` … `99_verify.sh`) per §2.0.
2. `patches/` text assets: `usr/keylayout/mtk-kpd.kl` (§2.5), `usr/keylayout/ACCDET.kl`,
   `usr/keylayout/Generic.kl.patch` (§2.6), `build.prop.patch`.
3. `manifests/donors.sha256` — pin the donor hashes before any use.
4. Run the pipeline → produce `out/system.img` (the forked system) + `SHA256SUMS.txt` +
   `scatter-fork.txt` + `fork-manifest.txt`.
5. Self-check per §2.4 acceptance criteria; run `99_verify.sh`.

## Donor images (external, read-only via bash; do NOT copy into the repo)
- Lithium system (base): `~/q5-flash/rom/system.img` (761,761,792 B, raw ext4)
- T-ROM system (audio donor pair): `~/.hermes/q5-recovery/base/T-ROM_V2.3/system.img`
- Mint system (ACCDET.kl / kpd-WAKE reference): `~/.hermes/q5-recovery/base/Mint_V1.0/system.img`
- Lithium boot (repack params reference only — M1a does NOT flash boot): `~/q5-flash/rom/boot.img`

Ext4 surgery: prefer `debugfs -w` on a `work/` copy (avoids full repack toolchain); if you use the
unpack/repack route, use `simg2img`/`debugfs`/`mkuserimg` from android-tools. Pick ONE method and
stick to it; the output `out/system.img` must mount read-only and stay ≤ 0x33400000 (850 MB).

## Hard rules (repeat — non-negotiable)
1. Never commit donor binaries (`*.img *.bin *.zip *.so`). `.gitignore` already excludes them.
2. Hash-assert EVERY donor read against `manifests/donors.sha256`; abort on mismatch.
3. All writes go to `work/` then `out/`; never modify donor images in place.
4. Idempotent: clean re-run reproduces byte-identical output.
5. Apply EXACTLY the 9 ops of §2.2 — no "improvements" to donor content.

## Output (write INCREMENTALLY to `.specs/forge-m1a-report.md`)
- What you changed (the 9 ops, with hashes before/after).
- Verified: `99_verify.sh` result, mounts read-only, each op hash-checked.
- Warnings / anything you deviated from spec (with reason).
- Final: `out/system.img` path + sha256 + size + the git tag `m1a` if you committed.
