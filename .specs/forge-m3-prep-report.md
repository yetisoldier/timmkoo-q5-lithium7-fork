# Forge — M3 boot-debug prep report (T0 control + debug cmdline + D19 draft)

**Task:** `.specs/bob-m3-boot-debug.md` §6 (Forge tasks). **Status: all three items ready.**
No device touched, no tree edits, no rebuild. Committed: `build/55_repack_boot.sh` (M3 changes)
+ `patches/kernel/D19-dsi-timeout.patch` (draft). Binaries in `out/` only (gitignored).

---

## 1. T0 repack-control — READY, and stronger than required

`55_repack_boot.sh lithium-ctl` extracts the pinned donor's kernel payload
verbatim — `boot.img[2048 : 2048+3809720]` = 512 B MTK `KERNEL` header + zImage —
hash-asserts it against the already-pinned `LITHIUM_KERNEL_IMG_SHA` (`5217dd41…`),
then re-packs it through the unchanged mkbootimg path + donor args + the same
verify step (`VERIFY_MODE=ctl`).

**Result: byte-identical to the donor at the strongest level — the full-image sha IS
the donor pin.**

| | sha256 |
|---|---|
| donor `~/q5-flash/rom/boot.img` | `443e40c3b27eb9c76250e4dbae61a45e2426c1b714754ff6838c056bed85df8f` |
| `out/boot-m1b-lithium-ctl.img` | `443e40c3b27eb9c76250e4dbae61a45e2426c1b714754ff6838c056bed85df8f` |

- `cmp` vs donor: silent (identical); donor pin re-asserted by `verify_lithium_donor` each run.
- Verify prints: `verify OK (ctl, T0): BYTE-IDENTICAL to donor boot.img; ksz equal (3809720 B); ramdisk byte-identical (1394157 B, sha c0be6c46…)` — **`ksz` equal, as required by §5 T0**.
- Idempotent: re-run produced the same sha; donor hash-gate runs before use every time.
- Sidecars written: `out/boot-m1b-lithium-ctl.img.sha256`.
- Side bonus this closes on statics: T0 byte-identity proves our mkbootimg invocation + header/padding reproduce the known-good image *exactly*, including the donor's MTK-header anatomy (magic + LE32 len + `"KERNEL"` + 24×NUL + 472×0xFF) and the 20-byte id field (`c4df36ae…` matches the donor's).

**Hera's T0 artifact:** flash `out/boot-m1b-lithium-ctl.img` (sha above). Pass gate per §5: Android boots with the usual Lithium quirks.

## 2. Debug-cmdline flag — READY (off by default)

`55_repack_boot.sh <tag> --debug-cmdline` (bob-m3 §5.4):
appends exactly `console=ttyMT3,921600n1 initcall_debug printk.time=1` to the donor cmdline and
writes `out/boot-m1b-<tag>-dbg.img` — **never** the default images, and rejected with
`lithium-ctl` (T0 must stay pristine). Default paths are byte-for-byte the pre-M3 behaviour.

Proof run (`--debug-cmdline` on α, kept as evidence):
- `out/boot-m1b-alpha-dbg.img` = `934b8f49523a401f982d9b8736e98f4b2373410dd36ce5dea39cb87244c2dd0d`
- machine-checked: cmdline == donor's + `" "` + exact suffix; ksz == α's normal ksz; body `[2048:]` == α normal; only 53 header-page bytes differ (the appended cmdline text region).
- α default image untouched and idempotent: re-run `alpha` produced the same sha as pinned (`d886ccfe…`).
- Error paths: unknown tag → usage/exit 64; `lithium-ctl --debug-cmdline` → loud refusal.

Hera's use, the moment any flash fails: `bash build/55_repack_boot.sh beta-touch-lcm --debug-cmdline` → flash `out/boot-m1b-beta-touch-lcm-dbg.img` for the §5.4 UART/ram-console captures.

## 3. D19 DSI-timeout hardening — DRAFT ONLY (as ordered)

`patches/kernel/D19-dsi-timeout.patch` — **not applied, not compiled, not flashed.**

Touches only `drivers/misc/mediatek/video/mt6582/dsi_drv.c`, 5 hunks:
1. `_WaitForEngineNotBusy()` 576–588: `break` in the 2 s-timeout arm (was: endless re-arm — the live-path infinite wait inside `mtkfb_probe`).
2–5. The four §3.4 timeout-free polls in `DSI_Detect_CLK_Glitch_Default()` (1606 BUSY, 1619+1629 CMD_DONE, 1639 STATE_DBG0 bit0) bounded with the sibling 100 ms `get_current_time_us` budget (same idiom as 1387/1419/1484), WARN + break, `(D19: 100ms budget)` strings for log self-identification.

Validation: byte-derived from git-HEAD pristine file (site-by-site byte asserts); `patch -p1 --dry-run` OK, real apply == intended edit, clean reverse-apply; braces balanced file-wide and per-touched-function. Prologue documents scope, reachability, and NOT-landed residuals.

**Two findings for Bob's landing decision** (implementation-level, no architecture change):
- **Reachability nuance:** in this tree the four glitch polls are *gated off at boot* — `dsi_glitch_enable` defaults false and its only enabler is commented out (`disp_drv_dsi.c:141`). The live pre-logo fix in D19 is the `_WaitForEngineNotBusy` **break** (on `mtkfb_probe/DSI_set_cmdq/DSI_transfer` for every α/β image). The poll bounds are hardening for the day that gate opens.
- **Residual same-class unbounded waits** (found in the sweep, deliberately not in the draft per §4's enumerated scope — all listed in the patch prologue with line numbers): `1649` (bit18, same loop as 1639), `1819/1901` (Parallel variant), `4043` (RACK `do{…}while(BUSY)` in `DSI_dcs_read_lcm_reg_v2` — **this one IS on the live α/β name-miss autodetect read path**, the RD_RDY wait above it is bounded), `4120` (packet_type retry loop), `3899` (`DSI_dcs_read_lcm_reg`), `323` (inside `#if 0`, dead). Recommend: land D19 as drafted after evidence names the branch; bound `4043`/`1649` in the same commit or an immediate follow-up only on Bob's sign-off.

## 4. Deliverables & bookkeeping

| Item | State |
|---|---|
| `build/55_repack_boot.sh` | committed: `lithium-ctl` tag + `--debug-cmdline` flag (-dbg naming) + ctl/`kernel-debug` verify modes |
| `out/boot-m1b-lithium-ctl.img` | built, **sha256 == donor pin `443e40c3…`**, idempotent |
| `out/boot-m1b-*{,-dbg}.img` | binaries in `out/` (uncommitted, per convention); α's other images untouched/sha-stable |
| `patches/kernel/D19-dsi-timeout.patch` | committed as DRAFT — top line says NOT APPLIED |
| Flash order unchanged | Hera: T0 (`lithium-ctl`) → T1 (α) per §5; evidence protocol §5.4 on every failure |
| Not done | no tree edits, no rebuilds, no kernel config changes, no flashing — Branch A/B decision stays evidence-gated |

Forge did not alter any board value, defconfig, or kernel code in the tree; the draft lives in one file, and the pipeline's D-order (`…D14, D4`) is untouched — D19 would slot after D18 only when and if Bob lands it.
