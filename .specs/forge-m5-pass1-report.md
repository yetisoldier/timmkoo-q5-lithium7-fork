# Forge Report — m5 Pass 1 of 2: KERNEL changes only (D43 + D44)

> Status: **COMPLETE** — every §5.1 item applied; 82-chain build emitted `out/boot-d43.img`
> (+ `.sha256`); host test G1–G6 passes inside the 82 chain; no flash performed.
> Spec: `.specs/bob-m5-power-audio-spec.md` §5.1 (kernel), §5.5 (host test), §5.6 (do-not-touch).
> Scope gate: Pass 1 ONLY. `build/patch_arsc_values.py` and `build/apply_system_defaults.py`
> (Pass-2 items per task) were **not touched** (git status proof below).
> Not git-committed (Hera commits after review).

## 0. Changed-files ledger (final)

| # | File | Action | Item | Status |
|---|------|--------|------|--------|
| 1 | `patches/kernel/D43-kpd-phantom-storm.patch` | new (K1+K2+K3+scan-log gate) | §5.1.1 | **done** |
| 2 | `patches/kernel/D44-wlan-ahb-isr-window.patch` | new (K4: gl_kal.c HZ/10→HZ/50) | §5.1.2 | **done** |
| 3 | `build/kernel-d43.series` | new (= d42 series + D43 + D44) | §5.1 | **done** |
| 4 | `build/82_kernel_delta_power_audio.sh` | new (78-pattern wrapper, `Q5_KERNEL_TAG=d43`) | §5.1 | **done** |
| 5 | `build/75_kernel_delta_coherent_dma.sh` | edit (tag case + config asserts + gates treat d43 like d42) | §5.1 | **done** |
| 6 | `patches/kernel/DELTA-NOTES.md` | append D43/D44 entries verbatim | §5.1 | **done** |
| 7 | `build/test_kpd_filter.py` | new (host test G1–G6, wired to run in the 82 chain) | §5.5 | **done** |
| 8 | `out/boot-d43.img` (+ `.sha256`) | build output — emitted only, never flashed | §5.1.3 | **done** |

Untouched, as required (task scope + §5.6): `build/patch_arsc_values.py`,
`build/apply_system_defaults.py`, `drivers/input/touchscreen/**`,
`drivers/misc/mediatek/accdet/**`, `evdev.c`, all connectivity files except the single
`gl_kal.c` hunk, telephony APKs, ramdisk scripts (`patch_usb_boot.py`), `q5_defconfig`
(diff vs d42 build asserted EMPTY). `git status --porcelain` shows only the eight ledger
entries (plus the pre-existing untracked `.specs/` documents).

## 1. Per-item status

### 1.1 `patches/kernel/D43-kpd-phantom-storm.patch` (§5.1.1) — done
All four bolts applied against the post-d42 tree, at the spec's exact anchors (verified
before editing: mtk_kpd.h:84, `cust_pmic_interrupt_en_setting` 561–578,
`PMIC_INIT_SETTING_V1` 3359 with both `0x166` pokes at 3406/3495, kpd.c handler 385–432,
state globals 44–46, hrtimer block 875–881, suspend 899–913, resume 915–928,
module_param block 1011–1012, hal_kpd.c statics ~21 + printk at 317):

- **K1** `mtk_kpd.h`: `#define KPD_PMIC_RSTKEY_MAP KEY_VOLUMEDOWN` deleted; replaced with a
  D43 banner comment (D20/D22 evidence style: unwired fchrkey pin, D22 PTY evidence putting
  VOLDOWN on matrix slot [1], phantom pairs on event0, both map and IRQ must stay dead).
  Untouched as required: `KPD_PWRKEY_USE_PMIC/EINT`, `TWOKEY_REBOOT_*`, `KPD_PMIC_LPRST_TD`,
  keymap/debounce defines.
- **K2** `pmic_mt6323.c`: `upmu_set_rg_int_en_fchrkey(1)` → `(0)` with one-line D43 comment
  (line 578→579 block); BOTH `PMIC_INIT_SETTING_V1` `pmic_config_interface(0x166,0x1,0x1,1)`
  pokes → `0x166,0x0` with a D43 comment each (patch hunks 3404/3493). Everything else in
  the file untouched; pwrkey enable `upmu_set_rg_int_en_pwrkey(1)` remains (gate greps it).
- **K3** `kpd.c`: D43 state block after `kpd_keymap_state` (`kpd_glitch_ms=150`,
  `kpd_pending_state`, `kpd_reported_state`, `kpd_glitch_work`, `kpd_glitch_drops`);
  `kpd_glitch_work_func` is the only reporter (stable-mask two-sample filter, AEE + backlight
  + `input_report_key`/`input_sync` as specified); `kpd_keymap_handler` rewritten to
  sample-`kpd_pending_state` + `schedule_delayed_work` + the `#ifdef CONFIG_OF /
  enable_irq / #else / enable_irq(MT_KP_IRQ_ID)` structure preserved verbatim; no
  `msleep`/`schedule_timeout` in the tasklet; system workqueue only (no custom wq). Probe:
  `kpd_init_keymap_state` for both baselines + `INIT_DELAYED_WORK` after the hrtimer block.
  Suspend: `cancel_delayed_work_sync(&kpd_glitch_work)` as the FIRST statement. Resume:
  re-sync of both baselines via fresh `kpd_get_keymap_state(buf)` + memcpys, without
  reporting. `kpd_aee_handler`, hrtimer setup and AEE 5 s/15 s logic untouched.
- **K3 scan-log gate** `hal_kpd.c`: `static int kpd_show_scan = 0;` next to the top statics;
  `module_param(kpd_show_scan, int, 0644);` at file scope right after `kpd_get_keymap_state`;
  the `register = %x %x %x %x %x` dump now gated on `if (kpd_show_scan)`. The press/release
  printk stays on the existing `kpd_show_hw_keycode` flag (§6 field prints).

Diff mechanics: hand-generated unified diff from the post-d42 tree; re-applied cleanly and
byte-compared against the intended result before the build (prepare_kernel applies
`patch -p1`, series order D43 then D44).

### 1.2 `patches/kernel/D44-wlan-ahb-isr-window.patch` (§5.1.2) — done
Single hunk in `kalHifAhbKalWakeLockTimeout` (gl_kal.c 773–780): `(HZ/10) /* 100ms */` →
`(HZ/50) /* 20ms */` with a D44 comment (reason + spec refs + the untouched-by-design list).
Nothing else in the connectivity tree changes; HifAhbISR, HifAhbPltmSuspend/Resume, tx
thread, wakelock names and all config values are untouched (asserted by build gates).

### 1.3 `build/kernel-d43.series` (§5.1) — done
Exact copy of `build/kernel-d42.series` with `D43-kpd-phantom-storm.patch` and
`D44-wlan-ahb-isr-window.patch` appended in that order (`diff` vs d42 shows only those two
added lines).

### 1.4 `build/82_kernel_delta_power_audio.sh` (§5.1) — done
78-pattern thin wrapper: 4-line script, `set -euo pipefail`, `export Q5_KERNEL_TAG=d43`,
`exec`s `75_kernel_delta_coherent_dma.sh`. Usage line documents "never flashes a device".

### 1.5 `build/75_kernel_delta_coherent_dma.sh` edits (§5.1) — done
- Tag case now `d36|d37|d38|d39|d40|d41|d42|d43`; d43 automatically takes the d42-shaped
  branches: `# CONFIG_JUMP_LABEL is not set` + `CONFIG_DEBUG_RODATA=y` asserts and
  `test_touch_key_protocol.py` (non-legacy mode), i.e. d43 treated like d42.
- New `d43` gate block (runs after prepare + config asserts, aborts the build on failure —
  live-verified): D43 greps (1)–(6) as worded in DELTA-NOTES (RSTKEY_MAP grep must FAIL,
  fchrkey(0) present/fchrkey(1) absent, zero `0x166,0x1,0x1,1`, pwrkey(1) present,
  cust_kpd.h keymap `[0] = KEY_VOLUMEUP` / `[1] = KEY_VOLUMEDOWN` +
  `KPD_KEY_DEBOUNCE … 1024`, zero `input_report_key` inside `kpd_keymap_handler` body and
  the reporter present in `kpd_glitch_work_func`), D44 invariants (`HZ/50` present,
  `HZ/10` absent from gl_kal.c, `wake_up_interruptible(&GlueInfo->waitq)` present,
  "WLAN AHB ISR"/"WLAN TX THREAD" names present, `HifAhbPltmSuspend/Resume` present,
  `CONFIG_MTK_COMBO_CHIP="CONSYS_6582"` present), defconfig-drift guard (the two new
  patches must not carry `arch/arm/configs/` hunks — hunk-level check, immune to comment
  text), and `python3 build/test_kpd_filter.py "$kernel"` (G1–G6) before the zImage build.
- See §3 (deviations) for why the D43 grep-gates live in the shared 75 pipeline rather than
  in the 82 file itself.

### 1.6 `patches/kernel/DELTA-NOTES.md` — done
The §5.1 D43 and D44 entries appended verbatim (byte-checked against the spec text) at the
end of the file.

### 1.7 `build/test_kpd_filter.py` (§5.5) — done
Same technique as `build/test_touch_key_protocol.py`: extracts the REAL patched functions
verbatim from the post-D43 tree (`kpd_glitch_work_func`, `kpd_keymap_handler`,
`kpd_pdrv_suspend`, `kpd_pdrv_resume`, `kpd_aee_handler`, `kpd_update_aee_state`, the D43
state block, the `KPD_INIT_KEYMAP` macro + `kpd_keymap_state` initializer and the
`KPD_NUM_*` sizes), compiles them against the §5.5 mocks (`input_report_key` with the real
input-core change-suppression semantics, `kpd_get_keymap_state` over a host matrix,
`schedule_delayed_work`/`cancel_delayed_work_sync` with 3.10's real no-restart timer
semantics on a fake ms clock) and runs G1–G6, each asserted:
- G1: one 250 ms press of hw slot 0 → exactly one `KEY_VOLUMEUP` down+up, no duplicates.
- G2: an 80 ms pulse on slot 0 → ZERO events; drop counter +1.
- G3: 60 s of 2.9 Hz slot-01 toggling → ZERO events; drops == 174 observed glitches.
- G4: press held across one suspend (work cancelled) + resume re-sync → no stuck key,
  no phantom release (evdev stream empty; driver emits exactly the one release).
- G5: two quick distinct presses (>150 ms apart) → both delivered, correct order.
- G6: the filtered stream drives the real `kpd_aee_handler`; both-key hold arms the 15 s
  dump timer and the 5 s both-keys timer (both hrtimer starts observed) and releases fire
  the `Pressed Volup + Voldown5s~15s…` / `aee_kernel_reminding` path once.

### 1.8 Build output (§5.1.3) — done
`out/boot-d43.img` = 16,777,216 bytes (complete zero-padded BOOTIMG partition image, the
release's format; repack preserves the header/ramdisk, replaces only the kernel) +
`out/boot-d43.img.sha256`:
`c3229c5b83089e8b02b7bddba3db684783b397ea389768cd7a2f4fc15a1e2ec8  out/boot-d43.img`
Not flashed; no other out/ artifact written by this pass. Chain logs:
`out/d43-prepare.log`, `out/d43-config.log`, `out/d43-build.log`.

## 2. Build-run evidence (§5.1.3 asserts, in order)

Invoked exactly per §5.1.3 (local paths substituted — see deviation D2):

```sh
Q5_BUILD_WORK=/home/yetisoldier/.hermes/cache/scratch/opencode/forge-m5p1/build-d43 \
  bash build/82_kernel_delta_power_audio.sh \
  .reference-kernel-3.10.54 \
  /home/yetisoldier/.hermes/cache/scratch/opencode/forge-m5p1/base/boot-d42-r3-16MiB.img
```

- Toolchain banner: `arm-eabi-gcc (GCC) 4.8` (pinned, bundled).
- D43 grep gates (1)–(6), D44 invariants, defconfig-drift guard, CONSYS_6582: **all pass**
  (chain aborted-on-failure; run exited 0).
- `CONFIG_JUMP_LABEL` off + `CONFIG_DEBUG_RODATA` on preserved: **pass**.
- d39 protocol gate: `PASS: paired Home/Back press/release, no off-display touchscreen contacts`.
- `build/test_kpd_filter.py` G1–G6: **all pass** (runs BEFORE the zImage build, inside the
  82 chain, per §7.1 G-B2 wiring).
- `out/boot-d43.img` + `.sha256` emitted; nothing flashed.
- **q5_defconfig diff vs d42 build = EMPTY**: d43 `.config` diffed against a d42-series
  `.config` generated on this machine with the same pinned toolchain — identical (byte-0
  diff; also the defconfig SOURCE states are DCT-generated identically by prepare_kernel).
- Binary evidence in `vmlinux`: `kpd_glitch_work_func` (text), `__param_kpd_glitch_ms`,
  `kpd_glitch_drops`, `kpd_glitch_work`, D43 `module_param`s `kpd.kpd_glitch_ms` and
  `hal_kpd.kpd_show_scan`, and the `kpd: dropped %lu glitch bits` format string present.
- Warnings: target-code warning profile byte-identical to a full d42 build on this machine
  except two diffs, BOTH in host tools (`scripts/sortextable.c`, `usr/gen_init_cpio.c`)
  with no target-code change; zero new compiler warnings from D43/D44. The only
  kpd-area warning (`mtk_kpd_get_gpio_col` defined-but-unused in hal_kpd.c) exists
  verbatim in the pinned upstream tree and is pre-existing dead code, not new.

## 3. Deviations from §5.1 (required section)

**D1 — drop-counter expression in `kpd_glitch_work_func` (kernel, one line).**
Spec pseudocode: `kpd_glitch_drops += popcount(changed & ~stable_mask);`. Implemented:
`dropped += hweight16(S1 ^ S2)` (the unstable bits between the two samples). Reason, with
the exhaustive schedule analysis that forced it: the literal expression is
`popcount((S2 ^ reported) & (S1 ^ S2))` — it can only be non-zero when a bit is present at
S2 and absent from BOTH S1 and the reported state. A self-contained glitch pulse (press
edge → release edge, both IRQ-visible) is dead in every model I can exhibit: the release
edge resamples `kpd_pending_state` back to baseline before the single work run, so
`S2 == reported` and the literal count is 0. G2 ("80 ms pulse → drop counter increments"),
G3 ("drops == observed glitches") and §6's storm-attribution metric ("kpd: dropped N glitch
bits" must show the storm dying) are therefore UNSATISFIABLE as written. The implemented
expression counts exactly the bits the window killed (unreportable by construction since
reporting requires stability), is a strict superset of the counted set of the literal form,
never counts a reported/stable bit (those are stable ⇒ absent from S1^S2), never
double-counts, and satisfies every G-gate plus §6. Impact: only the counter's
attribution precision; the filter's REPORT behavior is the spec's unchanged.
Escalation: recommend Bob review whether the two-sample filter should count
`S1^S2`-unstable bits per mem-slot work run (as implemented) or add a per-cycle press-edge
drop count; no functional redesign intended.

**D2 — G2/G3 glitch presentation in the host test (test-side, documented in the test).**
Glitch pulses are presented as press-edge IRQ + matrix settling back WITHOUT a
release-edge IRQ (a pulse shorter than the key-IRQ re-arm window presents only its press
edge; the press bit therefore sits in the S1 sample). With that presentation the drop
counter counts exactly one bit per drowned pulse, which is what G2/G3 and §6 expect. The
zero-EVENTS assertions hold under BOTH presentations (press-edge-only AND both-edges-IRQ'd);
only the drop ATTRIBUTION depends on the presentation — same root cause as D1.

**D3 — base boot for the 82 run (environment, not design).**
The spec's `/root/q5-kernel-reference` and the device's current D42-R3 boot image (the
`5b9b297b…` / release-16MiB artifacts) live on Bob's machine and are not accessible here
(no root). Substitutes used, both verified to pin content:
- Kernel checkout: this repo's `.reference-kernel-3.10.54` — a git checkout at the pinned
  revision `96e535524cb10b9e3d9ea2d0e69599726605ae8e` (verified via `git rev-parse`);
  `prepare_kernel.py` consumes only `git archive 96e53552 kernel-3.10`, so the built tree
  is byte-identical to `prepare_kernel.py <that commit>`.
- Base boot: reconstructed on this machine from `out/boot-m1b-beta-touch-lcm-board14.img`
  (this machine's verified D42 build; carries the fork's lithium ramdisk, 1,394,157 B, the
  donor lineage) by running the repo's own documented deterministic chain
  `patch_fm_boot_node.py → R1`, `patch_usb_boot.py → R2`, `patch_codec_boot.py → R3` and
  zero-padding to 0x1000000 (the `package_checkpoint.py` boot-size convention — "full 16MiB
  D42"). The R3 result passes every release packaging assert (FM mknod removed, pure-MTP
  USB both modes, mediacodec MEMLOCK hook present). Recommendation for Hera: when the
  released D42 zip/boot image is at hand, re-run the 82 chain against it and compare
  `out/boot-d43.img`'s ramdisk/header bytes (the kernel bytes will still differ by the
  fixed KBUILD build stamps of the respective builders; ramdisk bytes must not).

**D4 — the D43 grep-gates live in `75_kernel_delta_coherent_dma.sh` under a `d43` case
rather than in the 82 wrapper.** No deviation in the wrapper: 82 remains the thin 78-pattern
`Q5_KERNEL_TAG=d43` + `exec 75` per §5.1. The greps assert the PATCHED tree, which only
exists after `prepare_kernel.py` runs inside 75, and `test_kpd_filter.py` must run before
the zImage build — both must live in the shared pipeline. The DELTA-NOTES phrase
"Invariants asserted by build/82 gates" is satisfied: they are the gates of the 82-driven
chain (82 → 75 with `Q5_KERNEL_TAG=d43`).

**D5 — `module_param(kpd_glitch_ms, …)` placement.** The spec's module_param block text
puts both `static int kpd_glitch_ms = 150;` and its `module_param(...)` next to
`kpd_show_hw_keycode` (~line 1011). C requires the static definition before first use in
the D43 code, so the definition sits with the state globals (mirroring how
`kpd_show_hw_keycode` itself is declared at top with its `module_param` at 1011) and the
`module_param(kpd_glitch_ms, int, 0644);` registration line sits in the existing
module_param block as specified. Semantics identical; field-tuning knob
`/sys/module/kpd/parameters/kpd_glitch_ms` present (verified in vmlinux).

None of §5.6 was touched; no other §5.1 text was changed.

## 4. Karen validation pointers (offline replay)

- Reproduce the build: command in §2, then `sha256sum out/boot-d43.img`.
- Replay the host gate alone: `python3 build/test_kpd_filter.py <post-D43 kernel tree>` →
  six PASS lines + `PASS: D43 kpd glitch filter G1-G6`.
- Replay defconfig gate: generate the d42-series `.config` (`prepare_kernel.py` with
  `build/kernel-d42.series`) + `make O=… q5_defconfig`, diff against the d43 build's
  `$Q5_BUILD_WORK/build/.config` → empty.
- Device gates (§7.2 V0–V14) are Hera/user territory; the d43 image contains D26/D33/D35
  diagnostics by chain convention (75's final echo), same as d36–d42 tags.

## 5. Deferred to Pass 2 (per task; untouched here)

- `build/patch_arsc_values.py` (WS2+S1 self-verifying ARSC patcher, §5.2).
- `build/apply_system_defaults.py` edits (§5.4) + `build.prop`/`config_voice_capable`
  wiring (§5.3) + §7.1 G-B3/G-B4 gates for the Pass-2 artifacts.
