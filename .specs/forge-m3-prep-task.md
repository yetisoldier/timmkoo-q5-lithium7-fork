# Forge — boot-debug prep (T0 control + debug cmdline + DSI hardening draft)

## Read first
`.specs/bob-m3-boot-debug.md` — esp. §4 (decision tree), §5 (T0/T1 test plan), §6 (your three tasks),
§5.4 (evidence protocol).

## Your three tasks (build-side only — do NOT flash, do NOT land the hardening patch)
1. **`lithium-ctl` repack-control (T0).** Extend `build/55_repack_boot.sh` with a `lithium-ctl` tag
   that packs the **donor's own kernel payload verbatim** — extract the kernel region from the pinned
   Lithium donor `~/q5-flash/rom/boot.img` (`boot.img[2048 : 2048+3809720]`, i.e. the 512-byte MTK
   header + zImage) and re-pack it through the identical mkbootimg path + asserts. Expected result is
   **byte-identical (or header-identical) to the donor**. The script's verify step must print `ksz`
   equal. Output: `out/boot-m1b-lithium-ctl.img`.
2. **Debug-cmdline flag.** Add a script flag to `55_repack_boot.sh` that appends
   `console=ttyMT3,921600n1 initcall_debug printk.time=1` to the cmdline (one-line change, ready the
   moment any flash fails — do not build it into the default images).
3. **DSI-timeout hardening patch — DRAFT ONLY.** Write `patches/kernel/D19-dsi-timeout.patch`
   (or a draft file) that bounds the timeout-free polls in `dsi_drv.c` (~1606/1619/1629/1639) with
   the sibling 100 ms `get_current_time_us` budget, and adds a `break` to the timeout arm of
   `_WaitForEngineNotBusy`'s while loop (~530). **Do NOT apply it to the tree and do NOT rebuild with
   it** — Bob will land it only after T0/T1 evidence names a branch.

## Rules
- Idempotent + deterministic; hash-assert the donor before use. No flashing (Hera owns the device).
- Commit the `55_repack_boot.sh` changes + the draft patch; binaries stay in `out/`.

## Output
- `out/boot-m1b-lithium-ctl.img` (+ its sha256) — must be byte-identical to `~/q5-flash/rom/boot.img`.
- A short `.specs/forge-m3-prep-report.md` confirming the three items are ready.
