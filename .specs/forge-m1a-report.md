# Forge — M1a implementation report (system.img patch: audio + buttons)

**Spec:** `.specs/bob-m1-spec.md` §2.0–2.6 (op table), §2.4 (acceptance), §2.9 (conventions)
**Status: COMPLETE — 99_verify GREEN (13/13), reproducible, tagged `m1a` (7574d5f).**
**Build method:** §2.0 hard-rule 5, **`debugfs -w` surgery on a `work/` copy** (e2fsprogs 1.47.0). No unpack/repack toolchain; output image is the donor ext4 filesystem itself, modified in place on the copy — size and block count therefore match D-LITHIUM-SYS exactly by construction.

---

## 1. Environment / donor inventory (verified this session)

Tools present: `debugfs 1.47.0 (5-Feb-2023)`, `simg2img`, `img2simg`, `patch`, `zip`, `dumpe2fs`, `sha256sum`.
**shellcheck is not installed** on this host — scripts written to shellcheck-clean conventions (§2.9) but could not be machine-checked locally. (`readelf` also unavailable; ELF checks done with `od`/magic + `debugfs`.)

All three donor system images are **raw ext4** (no Android sparse header; `0xEF53` at offset 1080), so no `simg2img` conversion stage is required in the pipeline (it is still implemented and would trigger automatically if a future donor is sparse).

| Donor | Path | Size (B) | sha256 (pinned) |
|---|---|---|---|
| D-LITHIUM-BOOT | `~/q5-flash/rom/boot.img` | 5,208,064 | `443e40c3b27eb9c76250e4dbae61a45e2426c1b714754ff6838c056bed85df8f` |
| D-LITHIUM-SYS | `~/q5-flash/rom/system.img` | 761,761,792 | `cd6e9b54736d5aea7cc233937061711c677b38b5aa82708059b044d50f96b0b6` |
| D-LITHIUM-SCATTER | `~/q5-flash/rom/MT6582_Android_scatter.txt` | 6,876 | *(pinned in manifests/donors.sha256; consumed by 90_package)* |
| D-TROM-SYS | `~/.hermes/q5-recovery/base/T-ROM_V2.3/system.img` | 1,415,577,600 | `3d5350e7fc0bb6d6b3e78a572e19217e2cc26a876844dbbc7ee513c25f1cd839` |
| D-MINT-SYS | `~/.hermes/q5-recovery/base/Mint_V1.0/system.img` | 859,832,320 | `ba1b9b916eaf978c2084a7037ade6f2e1ec4de9dd67b392f82a29aca60b3c56a` |

- T-ROM hash matches the pinned `~/.hermes/q5-recovery/base/MANIFEST.sha256` → no donor drift.
- **Discrepancy flag for Bob/Hera (§2.10 escalation, not blocking):** `Mint_V1.0/SHA256SUMS.txt` in the ROM package lists `98A2715703B27F5F…` for `system.img`, but the extracted file hashes `ba1b9b91…`. The publisher sums evidently refer to different bytes than the extracted tree. All M1a evidence (Bob's E6/E7 forensics) matches the extracted file, so it is pinned as-read. Worth confirming with the ROM publisher offline.

Donor filesystem facts (D-LITHIUM-SYS, via `dumpe2fs -h`): volume `system`, UUID `da594c53-9beb-f85c-85c5-cedf76546f7a`, 185,977 × 4,096 B blocks (**761,761,792 B = file size exactly**), free blocks 37,360, features `has_journal ext_attr resize_inode filetype extent sparse_super large_file uninit_bg`, inode 256 B, **state: clean, last mount n/a** — no metadata_csum/64bit → safe for debugfs surgery; `state: clean` means the device kernel will not attempt journal replay on mount. Verified `Mint_V1.0` partition ceiling `0x33400000` (859,832,320 B) ≥ image size ✓ (E9).

Donor parent-dir stats (all single-block, **not** htree-indexed → debugfs dirent edits are safe without index maintenance), all `0755 0:0`, nsec=0:

| Dir | mtime (=ctime=atime, hex) |
|---|---|
| `/etc` | `0x6848bdad` |
| `/usr/keylayout` | `0x6848bdaf` |
| `/lib/hw` | `0x6848bdae` |
| `/vendor/etc` | `0x6848bfa3` |

(In-image T-ROM/Mint asset hashes recorded in §3; they matched spec E6 prefixes `2510d408…`, `579c9d04…`, `7379e023…` exactly.)

## 2. debugfs write-mechanics findings (validated on a scratch copy before implementation)

- `rm <path>` = unlink **and** kill_file (frees blocks) ✓. On missing path it prints an error but **debugfs still exits 0** → the pipeline verifies every op by *readback* (stat/dump/hash), never by exit code alone.
- `write <src> <dst>` allocates a fresh inode; dumped content hash == source ✓.
- `sif <path> {mode,uid,gid,mtime,atime,ctime,crtime,extra_isize}` all work; `@<epoch>` accepted; donor nsec is 0 so `@sec` restores byte-identical time fields.
- `ea_set -f <file> <path> security.selinux` restores the donor xattr exactly: `u:object_r:system_file:s0` + NUL (26 B).
- Fresh inodes have `extra_isize 32` and `crtime = now` → both pinned (`extra_isize 28`, donor `crtime = 0`) for reproducibility.
- Wall-clock touches: `mkdir`/`rm`/`write` update the **parent directory** `{m,c,a}time` → all touched parent dirs (and the fs root for `build.prop`) are re-pinned to their donor timestamps after ops.

## 3. Pinned assets (patches/ + manifests/donors.sha256)

Authoring method: the literal key-layout strings were **parsed programmatically out of the spec text** (§2.5/§2.6 lines) and applied byte-precisely to the donor-dumped Lithium bases with a generation script that asserts the resulting diff changes *exactly* the spec'd lines. No line was retyped by hand.

| Asset | Size (B) | sha256 | Content |
|---|---|---|---|
| `manifests/donors.sha256` | 3,336 | — | 5 donor pins + 9 in-image extract pins (`img:<DONOR>:<path>`) incl. "before" audit trail |
| `patches/usr/keylayout/mtk-kpd.kl` | 1,702 | `5c2ad7771c444c2943d4d7501ae467e97d8166fa4453013d688c2275fd76c957` | §2.5 literal merged file: base + 102/172 HOME WAKE_DROPPED, VOLUME_UP/DOWN WAKE_DROPPED, MUTE WAKE_DROPPED, POWER WAKE, + appended 744 FCOVER_1 / 745 FCOVER_2 WAKE; 36 other entries byte-identical to donor |
| `patches/usr/keylayout/ACCDET.kl` | 144 | `13e1d4f88e107e7101166219b6940a9667c9892b2d5f8a51634cd9748ee230a4` | **Byte-exact copy of Mint donor file** (6 keys); pipeline asserts `cmp` vs re-extracted Mint content both in 10 and at build |
| `patches/usr/keylayout/Generic.kl.patch` | 1,223 | `cfe9a55967fe102f16a33b38b36a3ec0d692610fc7694b90d0af1c48e9acf19e` | §2.6: exactly 7 line edits (116/152 POWER WAKE, 127/139 MENU WAKE_DROPPED, 142/143 → POWER WAKE, 158 BACK WAKE_DROPPED); COPY(133)/PASTE(135)/CUT(137) + LED section untouched |
| `patches/build.prop.patch` | 202 | `0ac0dab96d98b8a4e8f10c7840919a30074b68f40a494fcdce40208cba5bb2f5` | one line: `qemu.hw.mainkeys=1` → `0` (3-line context) |

Cross-check vs Bob's forensics: all four in-image donor hashes match E6 prefixes (`2510d408…`, `579c9d04…`, `7379e023…`, ACCDET `13e1d4f8…`); the Lithium "before" hashes match (`.so a7cc2dbe…`, policy `ef82488d…`, effects `13a0b6bb…`, 1559 B kpd). Donor Lithium `mtk-kpd.kl`/`Generic.kl` are byte-identical to the GitHub `.reference-lithium` tree — the repo's provenance chain is consistent end-to-end.

Note: T-ROM also ships `ACCDET.kl` (140 B) but it lacks `WAKE` on `key 122 ENDCALL`; spec op 5 correctly designates the Mint content as authoritative — used as-is.

## 4. Op execution records (out/system.img build)

Pipeline = 10 → 20 → 30 → 90 → 99 (all `set -euo pipefail`, donor-hash-gated, debugfs -w on `work/images/system-fork.img`). Every op asserts pre-state (donor-identical inode) and verifies post-state by dump+hash+stat read-back (debugfs always exits 0 — exit codes are meaningless).

| # | Op | Path (system tree) | before (sha256 / size / uid:gid) | after (sha256 / size / uid:gid) | Post-verify |
|---|---|---|---|---|---|
| 1 | replace | `lib/hw/audio.primary.mt6582.so` | `a7cc2dbe2cc2b8fd…` / 846,160 / 0:2000 | `2510d4086dcebf69…` / 850,256 / 0:0 | hash == T-ROM pin; inode fields == T-ROM donor (incl. T-ROM mtimes `1764277905`, selinux xattr restored) |
| 2 | replace | `etc/audio_policy.conf` | `ef82488dbdb87c71…` / 5,182 / 0:2000 | `579c9d04ca195d2e…` / 5,467 / 0:0 | hash == T-ROM pin |
| 3 | replace | `etc/audio_effects.conf` | `13a0b6bb634c657c…` / 6,681 / 0:2000 | `7379e023f8a543d5…` / 5,433 / 0:0 | hash == T-ROM pin |
| 4 | delete | `vendor/etc/mixer_paths.xml` | `dd94815692e404f3…` / 122 / 0:0 | *(absent — dir now empty)* | `df_exists` = false; dir inode re-pinned to donor times |
| 5 | add | `usr/keylayout/ACCDET.kl` | — | `13e1d4f88e107e71…` / 144 / 0:0 | hash == Mint pin == committed patch asset; Mint donor mtime `1765753082` preserved |
| 6 | replace | `usr/keylayout/mtk-kpd.kl` | `538b7d505e8216ed…` / 1,540 / 0:2000 | `5c2ad7771c444c29…` / 1,702 / 0:0 | hash == patch file; 102/172 `HOME WAKE_DROPPED` + FCOVER lines grepped in-image |
| 7 | patch | `usr/keylayout/Generic.kl` | `52997f63cd859457…` / 9,167 / 0:2000 | `5f39f62483d43f48…` / 9,312 / 0:0 | `patch --dry-run` then apply against donor base; hash == patched donor; the 7 flagged lines + intact COPY/CUT/PASTE asserted |
| 8 | edit | `build.prop` | `2180f8393b67a136…` / 10,940 / 0:2000 | `18e62d70ea4f98f5…` / 10,940 / 0:0 | diff vs donor == exactly the mainkeys line; single `qemu.hw.mainkeys=0` |
| 9 | add | `etc/fork/fork-manifest.txt` | — | *(2,819 B at build rev)* | present, non-empty; records git rev/date, tools, 5 donor hashes, 9-op hashes |

Inode identity policy (determinism): replaced/rewritten inodes keep their donor `{c,a,m}time` with `crtime=0`, get `extra_isize 28` (donor value) and `security.selinux = u:object_r:system_file:s0` restored via `ea_set`; fork-authored files (op 9) use the build tree's HEAD commit epoch; all touched parent dirs (`/`, `/etc`, `/usr/keylayout`, `/lib/hw`, `/vendor/etc`) are re-pinned to donor timestamps after ops. One extra field not reachable via debugfs: **superblock `s_wtime`** is re-stamped with wall-clock on every `debugfs -w` close (`ext2fs_flush`) — the pipeline captures the donor's zeroed 4 bytes and restores them once all write sessions are done; a full-post-superblock byte comparison of two independent builds came out **identical**, proving this was the sole nondeterminism.

Stage 3/4 outputs:
- `out/system.img` — raw ext4, **761,761,792 B (donor-exact size class)** ≤ Mint `0x33400000` ceiling; filesystem `state: clean`; 185,977×4 KiB blocks; free blocks 37,357 (donor 37,360 — Δ−3 from the 9 ops).
- `out/scatter-fork.txt` — donor scatter with file_name `NONE` on 17 rows, `boot.img` retained for BOOTIMG, `system.img` for ANDROID; diff vs donor touches only `file_name` lines.
- `out/SHA256SUMS.txt` (covers system.img + scatter-fork.txt), `out/fork-m1a-system.zip` (deterministic: entry mtimes = HEAD epoch, `zip -X -j`) + `out/fork-m1a-system.zip.sha256`.

## 5. Verification results

**`build/99_verify.sh`: GREEN — 13 passed / 0 failed, exit 0** (final run + two post-fix confirmation runs):

- A0/A1: all 5 donor pins re-hashed OK; `out/SHA256SUMS.txt` `-c` verifies and covers the published image.
- A2: full recursive debugfs walk + content-hash diff fork vs D-LITHIUM-SYS (**2,121 paths**): the changed-tuple set equals **exactly the §2.2 op table** (16 changed/added/removed tuples = 3 adds + 1 del + 6×2 changed) — any 10th difference would fail by construction.
- A3: `audio_policy.conf` braces balanced (36/{}/36), `audio_hal_version 3.0` exactly once (primary), byte-identical to T-ROM donor.
- A4: `audio.primary.mt6582.so` = ELF32 LSB ARM shared object; **DT_NEEDED satisfiable — all 26 needed libs present in fork `/system/lib`+`/vendor/lib`**; `.so` byte-identical to donor ⇒ exported symbol set unchanged.
- A5: `.kl` syntax (mtk-kpd/ACCDET/Generic) clean; dual `key 102 HOME` + `key 172 HOME` with WAKE_DROPPED; Generic.kl carries the 7 WAKE-flag edits.
- A6: `build.prop` diff == exactly one line (mainkeys 0).
- A7: `/vendor/etc/mixer_paths.xml` absent; `/etc/fork/fork-manifest.txt` present, non-empty, records HEAD+donor pins.
- A8: debugfs read-back OK; `state: clean`; size 761,761,792 ≤ 0x33400000; free blocks sane.
- A9: all changed paths 0644/0755 root:root; **no new world-writable entries** anywhere in the walk.

**Idempotency (§2.0 rule 4):** two full clean re-runs (rm -rf work out → 10→20→30→90→99) produced **byte-identical** `out/system.img`, `scatter-fork.txt`, `SHA256SUMS.txt` and zip. Pipeline runtime ≈ 1.5 min wall-clock.

## 6. Deviations from spec / notes

1. **`.gitignore` extension** — spec §2.0 claims `work/ out/ donors/` are excluded; they were not. Added (donor-binary exclusion `*.img *.bin *.zip` was already present).
2. **Mint publisher hash mismatch (flag for Bob/Hera, §2.10)** — `Mint_V1.0/SHA256SUMS.txt` says `98A27157…` for system.img; the extracted file hashes `ba1b9b91…`. Pinned as-read; all E6/E7 cross-checks still matched, so the extracted tree is what Bob analyzed. Recommend confirming with the ROM publisher offline.
3. **Permission normalization on ops 6/7/8** — donor files were `0644 root:shell(2000)`; changed files are `0644 root:root(0:0)` per §2.9/§3.2-9 ("changed files 0644 root:root"). Content bytes untouched; recorded here because donor *stat map* (§2.9 parenthesis) conflicts with §3.2-9 for these three paths, and Karen's check is the enforcement point.
4. **DT_NEEDED count is 26** (Bob's E6 said 27) — all satisfiable within the fork image; count is informational (possibly a duplicate-entry counting difference in the forensics tool).
5. **`40_unpack_boot.sh` / `50_repack_boot.sh` deferred** — M1b scope (gated on Q1 kernel source); M1a must not touch boot. Not stubbed to avoid half-artifacts.
6. **`out/boot.img` is intentionally not shipped**, yet `scatter-fork.txt` keeps `file_name: boot.img` on BOOTIMG (spec §2.3 wording). Hera/Karen runbook note: for the M1a flash, either place Eric's stock-Lithium backup `boot.img` (sha `443e40c3…`) beside the package or set BOOTIMG not-downloadable in SPFT — SPFT errors out rather than flashing something else if the file is missing, so there is no wrong-boot risk.
7. **fork-manifest timestamps** — spec op 9 wants a "date"; to keep rule-4 byte-identity the fork-authored inodes use the build tree's HEAD commit epoch (same repo state ⇒ same bytes); the manifest text records `git_commit_date` explicitly.
8. **`shellcheck`/`readelf` unavailable on this host** — scripts follow §2.9 conventions but couldn't be machine-linted; ELF/DT_NEEDED checks use a self-contained header/program-header parser instead of readelf. Install shellcheck and run it before M1b.
9. **Spec §2.0 names the repack output `out/system-fork.img`; task file pins `out/system.img`** — used `out/system.img` (task naming; scatter/SHA256SUMS reference it).
10. In-build defect found and fixed during development: the manifest's `zip` version probe initially read "version unavailable" (wrong flag); corrected to `zip -v`. Affects only manifest text (next build onward).

## 7. Deliverables

Repository state: commits `117a5d5` (pins+ignores) → `930750c` (patch assets) → `7574d5f` (pipeline), annotated tag **`m1a`** on `7574d5f515787af7edf2b973ef5a3118b19790a1`. No donor binary committed (verified via `git ls-files`). The report lives under the gitignored `.specs/` (repo policy: agent coordination not tracked) — the tag annotation carries the artifact summary.

**Final artifacts (built at the tagged rev; two consecutive clean builds byte-identical):**

| Artifact | Size (B) | sha256 |
|---|---|---|
| `out/system.img` — the forked system (raw ext4, donor-exact size class) | 761,761,792 | `2dc728846bc587f9a49eb04443bdb3bf4ca7a9f615f9cdbecefaab4ab864def4` |
| `out/scatter-fork.txt` | 6,830 | `a2e4aa27c1abad823458364d0bc1bf70dc3eeebb857ac25f09a5f9c8b52290cf` |
| `out/SHA256SUMS.txt` (covers the two above) | 158 | `12a091b08978454865f1a80010aa2b34e255c1ea7cf6c22a13df41664f20908d` |
| `out/fork-m1a-system.zip` (system.img + scatter + SHA256SUMS) | 296,579,039 | `17e2a0bcd06cd4f18059ff47e0f7550bee7b1b172b8ddc2351fa5068e54240f8` |
| `out/fork-m1a-system.zip.sha256` | 86 | — |

In-image fork-manifest (op 9) records `git_rev: 7574d5f515787af7edf2b973ef5a3118b19790a1`, HEAD commit date, tool versions, all 5 donor hashes and per-op before/after hashes.

**Hand-off notes for Karen (§3.2) / Hera (G0→G1):**
1. Flash **ANDROID only** via SP Flash Tool Download-Only using `out/scatter-fork.txt`: place `system.img` beside it; for BOOTIMG either supply Eric's stock-Lithium `boot.img` (sha `443e40c3…`) or leave BOOTIMG unchecked — SPFT aborts on a missing download rather than flashing a wrong file.
2. G4 fallback B is pre-gated: if `loadHwModule` errors appear, the Fallback-B conf change is `audio_policy.conf` line 32 `audio_hal_version 3.0 → 2.0` (documented for a future op, NOT applied — spec ships T-ROM verbatim).
3. Donor re-runs: any donor byte drift now aborts loudly at stage 10 (`donor pin mismatch — STOP per §2.10`); re-inventory with Bob before rebuilding.
4. `work/` artifacts (donor walk cache, ops log, patchwork outputs) are rebuildable and gitignored; the audit trail of record is this report + the in-image manifest + git history.
