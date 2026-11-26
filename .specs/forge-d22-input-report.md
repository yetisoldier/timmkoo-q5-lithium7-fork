# Forge D22 input-repair report

Task (binding): `.specs/hera-d22-input-diagnosis.md` (verified diagnosis; Forge fixes, does not
re-investigate). Status: **IMPLEMENTATION COMPLETE — all D22 host tests, source invariants,
compiled gates and the build/repack passed; hardware gates remain open (§5).**

Constraints honored on every step below: **no ADB, no flash, no reboot, no live I2C writes,
no device actions, no commits/pushes/releases** — build + host tests only. The D21 board2
artifacts (`build-beta-touch-lcm-board2` O dir, `out/boot-m1b-beta-touch-lcm-board2.img`) stay
byte-immutable as the rollback/reference pair.

## 0. Scope taken (per the contract)

| # | Contract item | Target | State |
|---|---------------|--------|-------|
| 1 | I2C payload contract repair (const payload, bounded staging, no caller mutation, payload-only call sites, MTK flags/timing preserved) | `drivers/input/touchscreen/mediatek/gslX680/mtk_gslX680.c` | DONE (§2.1) |
| 2 | `gsl_load_fw` rewrite: bounded contiguous-register page-aware batches ≤128 B, flush on full/page/discontinuity/end, LE words, signed return, all failed/short transfers propagated (incl. final partial batch) | same file | DONE (§2.1) |
| 3 | Failure propagation through init path + bounded alive check reg 0xb0 (0x5a signature) before probe success; vendor delays/fingerprint/firmware/tuning arrays preserved | same file | DONE (§2.1) |
| 4 | Q5 volume-key reversal: `KPD_INIT_KEYMAP()` `[0]↔[1]` (KEY_VOLUMEUP / KEY_VOLUMEDOWN) in the Q5-pinned `cust_kpd.h`; matrix keymap not duplicated in `mtk_kpd.h` (verified — only `cust_kpd.h` carries `KPD_INIT_KEYMAP`); invariant/parity checks re-pinned so DrvGen regeneration cannot revert | `arch/arm/mach-mt6582/q5/dct/dct/inc/cust_kpd.h` + build script | DONE (§2.1, §2.2) |
| 5 | Reproducible actual-source host tests: old write helper + old loader fail under ASAN; repaired helpers pass ASAN + payload immutability + exact byte stream; every extracted Q5 firmware array emits exactly its records as page/data transfers (final partial batch, page transitions, discontinuities, injected short/negative I2C returns); init failure does NOT report success (REAL functions exercised) | `build/d22_host_tests/` | DONE (§2.3, §3.1) |
| 6 | NEW D22 patch/build artifact (patch `patches/kernel/D22.patch`, O dir `build-beta-touch-lcm-board3`, image `out/boot-m1b-beta-touch-lcm-board3.img`); board2 rollback pair untouched; build+repack+existing gates, no new warnings; image hash + commands recorded | `patches/`, `build/63_kernel_delta_input.sh` | DONE (§2.2, §3.2–§3.3, §4) |

Deliberate non-goals (contract): no retry loops beyond bounds, no firmware-array/GPIO/delay
changes, no D1–D21 regressions (MBR=0x1400000 and all D20 precedence gates re-asserted in the
D22 stage), no git tag creation (D22 content is intentionally uncommitted — see §6 note).

## 1. Pre-flight state

- Working tree at `fc2fd23` (m1b/D21), `git status` clean before edits. Prior stopped run left
  no source edits or surviving processes (per Hermes' live facts).
- Reproduction evidence read and accepted: `~/.hermes/cache/scratch/q5-gsl-write-asan.c`
  (stack-buffer-overflow READ in the transfer stub consuming the declared `num+1` length),
  `q5-gsl-fw-asan.c` (stack-buffer-overflow WRITE at the next-page memcpy into `buf+129`).
- Live defects located in the D17-patched `mtk_gslX680.c` (`.reference-kernel-3.10.54/kernel-3.10`,
  created by `patches/kernel/D17.patch`, unmodified since):
  1. `gsl_write_interface` sets `buf[0] = reg` on a buffer whose callers pass **payload-only**
     data (`gsl_i2c_write_bytes` and the loader) and declares `len = num + 1`: first payload
     byte destroyed + one byte read past the caller's buffer on every single I2C write.
  2. `gsl_load_fw` flush compares `send_flag == 1 % burst` / `== 0 % burst` — constants, only
     matching after a u8 wrap (~256 records): `cur` runs past `buf[129]` (stack smash) and the
     page selector is written from stale buffer bytes (`cur` never reset at page records).
  3. `check_mem_data` ignores the read result and the `gsl_sw_init` return and `return result`
     is hardcoded 0; probe trusts it and marks `tpd_load_status = 1` unconditionally.
  4. Keymap: live PTY capture shows physical VolumeUp → KEY_VOLUMEDOWN under the D20 map
     (`[0]=VOLDOWN, [1]=VOLUP`) — the two active slots are reversed vs this board's wiring.

## 2. Repairs (incremental)

### 2.1 `patches/kernel/D22.patch` (created; applies cleanly on the D21 tree)

**`drivers/input/touchscreen/mediatek/gslX680/mtk_gslX680.c`**

- **Write contract repaired.** `gsl_write_interface` is now
  `static int gsl_write_interface(client, u8 reg, const u8 *payload, u16 num)`:
  payload-only, const caller buffer, bounded staging buffer
  (`staged[GSL_I2C_MAX_PAYLOAD + 1]`, cap `GSL_I2C_MAX_PAYLOAD = 128`), register
  byte first, payload copied unchanged after it, exactly `num + 1` wire bytes.
  Sizes validated (`< 1` / `> 128` → `-EINVAL` before any transfer). The old
  `buf[0] = reg` form is removed from the tree. MTK message spelling is
  byte-identical to the D17/vendor form: `addr = (client->addr &
  I2C_MASK_FLAG) | I2C_ENEXT_FLAG`, `flags = client->flags & I2C_M_TEN`,
  `timing = 400`.
- **`gsl_i2c_write_bytes`** now `const u8 *txbuf`, validates `len ∈ [1,128]` and
  forwards — the dead chunk loop (with its u8-offset wrap class) is gone. Every
  call site (chip helpers, loader, report path, proc path, proc debug read) is
  already payload-only; no site needed a reserved-prefix buffer.
- **`gsl_load_fw` rewritten** (diagnosis §2): bounded contiguous-register
  page-aware batches ≤ `DMA_TRANS_LEN` records = 128 payload bytes. Flush on
  full batch / page selector / register discontinuity / end of array; page
  writes are exactly reg 0xf0 + one LE32 word; each data word staged with
  explicit little-endian byte order (`gsl_fw_word_le`); every record emitted
  exactly once in order, including the final partial batch; `static int`,
  returning 0 only if every page and data write (incl. the final partial batch)
  succeeded; page-selector and batch failures log the failing reg and abort.
- **Failure propagation** (diagnosis §3): `gsl_read_interface` returns int
  (`-EFAULT` on short read); `gsl_clear_reg` / `gsl_reset_core` / `gsl_io_control`
  / `gsl_start_core` all return int with early-abort on first failed write
  (vendor delays kept on the success path); `gsl_sw_init` propagates the link
  test, the canary stage (transport failure falls straight to the required
  default-firmware load, which reports the same dying link; an unanswered
  canary keeps the vendor's bounded 3-try loop), the fingerprint read, and the
  load stage (clear → reset → io_control → load_fw → io_control → start, each
  checked, loud `D22: fw load failed` marker).
- **`check_mem_data`**: read result checked (transport error → return);
  signature 0x5a → return 0; otherwise full `gsl_sw_init`, then a **bounded
  alive gate** `gsl_check_alive` (reg 0xb0, ≤ `GSL_FW_ALIVE_TRIES = 3` reads @
  `GSL_FW_ALIVE_DELAY_MS = 200`; transport errors return directly; signature
  mismatch after the bound → `-EIO` with a loud log). Probe success
  (`tpd_load_status = 1`) only happens when `check_mem_data` returns 0 —
  i.e. only on a controller-confirmed alive signature. Resume path logs the
  same way (`D22: resume init failed`); earlysuspend hooks are void, so failures
  are loud, not silent. Proc write paths ('st'/'en'/'wr') log failures.
- Preserved verbatim: vendor delays, fingerprint cascade + banner mapping,
  io_control×2 blob call sequence, all firmware/tuning arrays (fw header still
  D17-pinned byte-exact), GPIO/EINT/power wiring, report path, input node.

**`arch/arm/mach-mt6582/q5/dct/dct/inc/cust_kpd.h`**

- `KPD_INIT_KEYMAP()` reversed for exactly the two active keys:
  `[0] = KEY_VOLUMEUP`, `[1] = KEY_VOLUMEDOWN` (was D20's
  `[0]=VOLDOWN,[1]=VOLUP`). Nothing else moved: `KPD_DL_KEY*` /
  `MT65XX_RECOVERY_KEY` stay HW-keycode contracts, `KPD_KEY_DEBOUNCE 1024`,
  `MTK_PMIC_PWR_KEY 8`, HOME/system layout untouched. The matrix keymap is
  **not duplicated** in `mtk_kpd.h` (verified — the only `KPD_INIT_KEYMAP`
  definitions in the tree are the DCT headers; the q5 `keypad/mtk_kpd.h`
  carries none), so `mtk_kpd.h` stays byte-identical to the a106 lineage
  (re-asserted by the build stage).

### 2.2 `build/63_kernel_delta_input.sh` (new D22 stage)

- Reproduces D1…D21 via `patches/kernel/*` into the **new** O dir
  `build-beta-touch-lcm-board3` (board2 O dir untouched), applies `D22.patch`
  last, and:
  - **host-test gate** (`bash build/d22_host_tests/run.sh <pre-D22 snapshot>
    <post-D22 snapshot> <tree gsl dir>`) — aborts the stage before any kernel
    build if the repairs do not hold;
  - re-asserts every D2/D3/D5/D6/D7/D15/D16/D17/D18/D19/D20/D21 invariant,
    with the D20 keymap greps re-pinned for the D22 reversed map **and an
    explicit absence check for the D20 form** (so DrvGen regeneration cannot
    revert the mapping without failing the build);
  - new D22 source invariants (staged write helper, no `[reg|payload]`
    remnant, signed loader signature, batch bound, LE staging, alive-gate
    tail, 0x5a define, D22 markers, `ret = check_mem_data(...)`);
  - DCT-precedence compiled gate with the **D22 keymap bytes**:
    `hal_kpd.o` must carry `(115,114)` = {VOLUP,VOLDOWN} and must NOT carry
    D20's `(114,115)` nor a106's `(0,115,114)`;
  - D22 compiled gate: `mtk_gslX680.o` rodata carries `D22: fw load failed`,
    `D22: init failed`, `D22: resume init failed` and the batch-failure format
    string;
  - D21 compiled gate re-asserted (MBR 0x1400000 u64, dumchar guard, pmt
    preset-string);
  - δ-parity vs the Lithium blob extended with the D22 Image-string checks.

### 2.3 `build/d22_host_tests/` (new, actual-source host tests)

`run.sh` extracts the OLD function text from a pre-D22 source snapshot and the
NEW text from the post-D22 source (drift-proofed against the known defect
shapes before running), builds both under ASAN (`-fsanitize=address
-fno-omit-frame-pointer -g -O0`), and runs:

| suite | proves (per contract) |
|---|---|
| `old_write_asan` | old helper aborts: **stack-buffer-overflow READ** (stub consumes the declared `num+1`) |
| `old_fw_asan` | old loader aborts: **stack-buffer-overflow WRITE** against the REAL `GSL_TP_CHECK_FW` |
| `new_gsl_write` | exact byte stream (reg first), payload immutability (caged buffer), 0/over-cap rejection before any transfer, cap transfer = 129 wire bytes, short/hard transport errors propagate, MTK msg fields verbatim |
| `new_gsl_fw` | **every extracted Q5 array** (`GSL_TP_CHECK_FW` 957, `gsl_fw_hw` 5049, `gsl_fw_dsj` 4851, `gsl_fw_wl` 4983, `gsl_fw_cfg5` 4983, `gsl_fw_jx2` 4983) reconstructs record-exactly from the wire stream; explicit LE on a known record; synthetic discontinuity / full-batch-cap / final-partial-batch arrays; injected short + negative failures propagate incl. the final partial batch; fw array unmutated |
| `new_gsl_init` | init success only after bounded alive confirmation; dead signature → `-EIO` after exactly 3 post-load reads; mid-load transport failure and fingerprint-read failure never report success; full vendor sequence on the success path (canary + selected config streamed, start-core write last before the alive gate) |

The harnesses run the REAL extracted functions with a mock transport (mock i2c
core + fake GSL register file + failure injection) — no formulas copied.

### 2.4 `build/55_repack_boot.sh` — additive `beta-touch-lcm-board3` tag.

## 3. Executed tests

All commands run from the repo root; every stage ends `exit 0` unless noted.
No device was touched at any point (no ADB, no flash, no reboot, no live I2C).

### 3.1 Host tests (ASAN, actual-source extraction) — `build/d22_host_tests/run.sh`

Executed inside `build/63_kernel_delta_input.sh` (and iterated standalone against
the scratch sources first). Final in-stage result:

```
[d22-host-tests] 1. OLD write helper — expect ASAN stack-buffer-overflow READ (abort)
[d22-host-tests]    OK: aborted with ASAN stack-buffer-overflow
[d22-host-tests] 2. OLD firmware loader — expect ASAN stack-buffer-overflow WRITE (abort)
[d22-host-tests]    OK: aborted with ASAN stack-buffer-overflow
[d22-host-tests] 3. NEW write helper — payload immutability + exact byte stream + validation
new-write-tests: ALL PASS            (t1–t5: exact stream, caged-buffer immutability,
                                      size validation incl. the 128-byte cap = 129 wire,
                                      short/hard transport errors propagate, MTK fields)
[d22-host-tests] 4. NEW firmware loader — all real Q5 arrays + synthetic edges + injected failures
ok   GSL_TP_CHECK_FW: 957 records emitted exactly (58 transfers)
ok   gsl_fw_hw: 5049 records emitted exactly (306 transfers)
ok   gsl_fw_dsj: 4851 records emitted exactly (294 transfers)
ok   gsl_fw_wl:  4983 records emitted exactly (302 transfers)
ok   gsl_fw_cfg5: 4983 records emitted exactly (302 transfers)
ok   gsl_fw_jx2: 4983 records emitted exactly (302 transfers)
ok   value 0xf801000f at reg 0x64 is explicit little-endian on the wire
ok   synthetic discontinuity + partial end; full-batch cap (129-wire first batch);
     overflow record starts its own batch; FINAL PARTIAL BATCH transports propagate
ok   fw array bits unchanged by the loader
new-fw-tests: ALL PASS
[d22-host-tests] 5. NEW init path — failure never reports success; bounded alive gate
new-init-tests: ALL PASS   (s1 warm-bind, s2 full vendor sequence ends at start-core
                            write + alive gate, s3 dead signature → -EIO after exactly
                            3 post-load reads, s4 mid-load transport failure refused,
                            s5 bounded retry count, s6 warm chip → no reload,
                            s7 fingerprint-read failure refused)
[d22-host-tests] ALL D22 HOST TESTS PASS (old defects still reproduce; repairs verified on actual source)
```

Notes: the OLD-side extraction is byte-verified against the tree (the pre-D22
`mtk_gslX680.c` equals the D17 state, `cmp`-checked); the fw header is
sha-asserted (`bae204cb…` = D17 pin) before the tests run.

### 3.2 The D22 stage — `bash build/63_kernel_delta_input.sh`

```
[forgem1b] D22 host tests PASS (old defects reproduce under ASAN; repairs verified on actual source)
[forgem1b] all patches applied; asserting the modified-tracked-file set   (== the D21 set: D22 touches untracked files only)
[forgem1b] D2/D3/D5/D6/D7 + D15/D16(re-pinned) + D17 + D18 + D19 + D20 + D21 invariants asserted
[forgem1b] D22 source invariants asserted (payload-only write, bounded loader, propagation, alive gate, untouched fw gen)
[forgem1b] β-touch-lcm-board3 build: make q5_defconfig / make zImage      (fresh O dir build-beta-touch-lcm-board3)
[forgem1b] β-touch-lcm-board3 zImage sha256: b0237a93f8c8631daa407312d3cf393523881edb9fc069b98d86c3a31af2e958
[forgem1b] β-touch-lcm-board banner: Linux version 3.10.54 (forge@fork) (gcc version 4.8 (GCC)) #1 SMP PREEMPT 2026-11-25T13:47:27-06:00
precedence gate: OK (hal_kpd D22 keymap bytes {VOLUP,VOLDOWN}, kd_camera_hw pin words, sd.o ch3/deb0, accdet.o ch4/GPIO4)
D21 gate: OK (cust_part_mbr.o u64=0x1400000 & no 0xC00000, dumchar.o D21 marker, pmt.o preset-check string)
D22 gate: OK (marker rodata + batch-fail format present in mtk_gslX680.o)
[forgem1b] δ-parity report (β-touch-lcm-board3): out/kernel-parity-beta-touch-lcm-board3.txt
[forgem1b] D22 β-touch-lcm-board3 build + δ-parity + precedence/D21/D22 gates + host tests PASS
```

- **Keymap compiled proof**: `hal_kpd.o` carries the D22 reversed u16 pair
  `(115 = KEY_VOLUMEUP, 114 = KEY_VOLUMEDOWN)` at a word-aligned offset; the
  D20 pair `(114,115)` and a106's `(0,115,114)` are absent (word-aligned scan;
  the naive unaligned scan would false-positive on two padding zeros before
  the array head — documented in the gate).
- **Parity**: `gsl_tp`/`gsl1680`/`gsl915`/`gslX680`/`gsl_alg_id_main`/
  `gsl_config`/`GSLX680_FW` string sets unchanged in kind vs the D21 build;
  `mt6323:19 auxadc:210` count pins held; no must-not strings appeared.
- **No new warnings**: warning lines normalized/compared against the D21
  baseline log — identical 934 vendor warnings, zero diff; the repaired
  `mtk_gslX680.c` compiles with **0 warnings**, `hal_kpd.c` still has exactly
  its 4 pre-existing `unused variable/function` vendor warnings (unchanged).
- **Reproducibility re-run**: running 63 again produced the byte-identical
  zImage (`b0237a93…`), then 55 re-produced the identical image hash.

### 3.3 Repack — `bash build/55_repack_boot.sh beta-touch-lcm-board3`

```
verify OK: headers byte-identical except ksz (3809720 (donor) vs 4266104);
           ramdisk byte-identical (1394157 B, sha c0be6c46333b…)
out/boot-m1b-beta-touch-lcm-board3.img: 5664768 B
```

## 4. Build artifacts

| artifact | value |
|---|---|
| patch | `patches/kernel/D22.patch` (banner + 2 files: `cust_kpd.h` keymap hunk, `mtk_gslX680.c` repair body) |
| build stage | `build/63_kernel_delta_input.sh` |
| host tests | `build/d22_host_tests/` (`run.sh`, 3 new-code harnesses, 2 old-defect ASAN proofs, mock transport + extraction) |
| O dir | `.reference-kernel-3.10.54/kernel-3.10/build-beta-touch-lcm-board3` |
| zImage | sha256 **`b0237a93f8c8631daa407312d3cf393523881edb9fc069b98d86c3a31af2e958`** |
| boot image | `out/boot-m1b-beta-touch-lcm-board3.img` — 5664768 B, sha256 **`0703f7fc3a2d29d815bfc5f2cf048e1ba0ea8a2215285bb2f161ebcbaf7da8ba`** (sidecar `.sha256` written) |
| parity report | `out/kernel-parity-beta-touch-lcm-board3.txt` |
| rollback pair (untouched, verified) | board2 image `OK` against its `.sha256` pin (`0b6ed1b2e2f3…`); board2 zImage `45e02bd5f86e…` matches the D21 report's recorded value |
| repo state | HEAD `fc2fd23` unchanged; working tree carries exactly: `M build/55_repack_boot.sh`, `M patches/kernel/DELTA-NOTES.md`, `?? patches/kernel/D22.patch`, `?? build/63_kernel_delta_input.sh`, `?? build/d22_host_tests/` (+ gitignored `.specs/`, `out/`) |
| artifact hashes | `patches/kernel/D22.patch` sha256 `444b32287093df554a03c6b78f167a7a01669756d93c6b6e61c46e81890b12c3`; `build/63_kernel_delta_input.sh` sha256 `18e393aa3fa617e1e14462c23395a4e8021a1a96c6c19ed07f0e7026f4f9aa43`; `build/d22_host_tests/` tree sha256 `2b1b9127b8bcfeed0b311f1388572f36037848a201bbf2b7e7230c23b1c1485d` |

## 5. Remaining hardware gates (NOT claimable from host tests)

- Real swipe must emit evdev event3 coordinates and work visually (touch path).
- **Both** physical volume directions verified by a human on the device: the fix
  targets the live-captured VolumeUp→VOLDOWN reversal; the complementary
  VolumeDown mapping is explicitly listed in the contract as hardware-tested
  only after fix.
- No crash/regression on boot (all D1–D21 invariants re-asserted in the D22
  stage and the image re-packed from the same stock ramdisk, but the boot
  itself is untested by design here).
- **Do not call hardware fixed merely because tests/build pass.**

## 6. Notes / escalations

- **No git tag was created**: the contract forbids commits and the D22
  patch/artifacts are intentionally uncommitted working-tree content, so a
  tag on HEAD would anchor pre-D22 state — misleading rather than useful.
  D22 identity is carried by the patch id, the new O dir
  `build-beta-touch-lcm-board3`, and the image + `.sha256`. If a tag is
  wanted, it belongs to the commit step owned by Hermes.
- **Design decisions made inside the contract's latitude** (no architecture
  change):
  - Canary-stage transport failures fall straight to the required
    default-firmware load instead of burning the remaining bounded retries
    against a dead link; an *unanswered* canary (read OK, wrong value) keeps
    the vendor's 3-try loop. The default load then reports terminal failures.
  - A failed fingerprint read (0xb8) after a successful canary is a hard
    failure, not a silent default-config fallback (garbage fingerprint would
    silently misselect the panel firmware).
  - The alive gate retries only on *signature mismatch* (bounded, 3 × 200 ms —
    firmware boot time); transport errors return directly (a NAK does not
    recover inside msleep).
- **Assumptions/limits**: the host tests run the real extracted functions
  against a mock transport; they are not live-hardware proof (the contract's
  hardware gates above stay open). `I2C_SMBUS_FORCE`/DMA-vs-smbus define
  splits from the original donor do not exist in this D17-trimmed driver —
  the D22 write path models exactly the vendor message shape the D17 driver
  used (single transfer, vendor flags), with payloads > 8 B handled by the
  vendor i2c core's internal DMA (same class as the vendor's own 129-byte
  HIGH_SPEED transfers).
- No system.img / scatter changes: D22 is kernel-only; the 90-package and
  99-verify stages are unaffected by this delta.
