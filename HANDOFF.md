# TIMMKOO Q5 — Lithium 7 Fork: Handoff & Touch Bring-Up Log

> **Codex update, 2026-11-26:** The old touch-blocker diagnosis below is
> superseded. **D34 fixes touch with coherent DMA buffers. D36 fixes speaker
> initialization and the legacy speaker-on/off hooks.** The user confirmed
> physical touch, clear speaker playback, and speaker playback after unplugging
> headphones and pressing Play. On-screen navigation is enabled by default;
> the gnome splash, boot display and default wallpaper are installed. **D37 adds
> the missing Mint touch variants; D39 fixes duplicate bezel/touch Home events.**
> The user confirmed repeated quick taps now go Home normally. D38 also fixes
> a network-triggered kernel crash. Native Home shortcuts are installed: tap
> Home, double-tap Back, hold Recents, with navigation visible. Browser APKs are
> removed from system. Subsequent audit adds FM, a voice recorder and a
> Settings navigation visibility switch; see [FUNCTIONAL-AUDIT.md](FUNCTIONAL-AUDIT.md).
> Camera is omitted per purchase evidence. The prior Hynix
> identification was incorrect (Hyn_device belongs to the touch controller). See
> [CURRENT-STATUS.md](CURRENT-STATUS.md) for evidence, hashes and reproduction.
>
> Everything below is Hera's historical handoff, retained for provenance.

> **Status at handoff (2026-11-26):** Touch is NOT yet working. Transport, power,
> display, buttons, MBR and framework are all fixed and verified. The single open
> problem is that the GSL touch controller's **firmware will not boot** (alive
> register `0xb0` reads `0x00`, expected `0x5a`). See "Current blocker" below.

---

## 1. Goal

Fork **Lithium 7 (Android 7.1.2)** onto the **TIMMKOO Q5** while porting the
fixes from the **Q5 Mint** ROM so the fork works on Q5 hardware. Hard rule:
**never lose a working function** (touch, buttons, audio, camera, charging).

- Fork base: Lithium 7 (donor boot.img + system.img).
- Functional reference: Mint v1.0 (Sendew/TIMMKOO-Q5-Mint-Custom-ROM).
- Kernel source: `heyrudra/android_kernel_micromax_a106` (3.10.54, in-tree gcc 4.8).

## 2. Repo / artifact map

| Path | Content | Tracked? |
|------|---------|----------|
| `build/*.sh` | build + delta-gate + repack pipeline (`55_repack_boot.sh`, `6x_kernel_delta_*.sh`) | yes |
| `patches/kernel/D*.patch` | every kernel change, in apply order | yes |
| `patches/kernel/DELTA-NOTES.md` | invariants + rationale per delta | yes |
| `manifests/*.sha256` | donor + kernel-source pins | yes |
| `.specs/*.md` | Bob/Forge specs & reports (full per-pass detail) | **force-added** |
| `.reference-kernel-3.10.54/` | kernel source w/ patches applied (build tree) | **no** (re-clone + apply) |
| `donors/` | decompiled donor blobs (symlinked into scratch) | **no** (re-derive) |
| `out/`, `work/` | build outputs / images | **no** |
| `~/.hermes/q5-recovery/base/Mint_V1.0/` | Mint reference (boot/system/logo/scatter) | external |
| `~/q5-flash/` | Lithium donor (boot.img + scatter + zip) | external |

## 3. Confirmed hardware facts (`.specs/hardware-facts-q5-mint.md`)

- Battery: **2000 mAh** (product ad).
- Touch: GSL X680-family, I²C bus 0, addr `0x40` (`0-0040`), EINT channel 2
  RISING edge, reset GPIO14, interrupt GPIO2.
- Panel: gc9503v WVGA DSI 480×800 (LK contract name), 8-bit.
- Power rails: **VIO28 @1.8 V (LDO 25) + VGP1 @2.8 V (LDO 31)** — verified ON via
  `/proc/mt_pmic/dump_ldo_status`. MT6323 has **no VGP4** (that decode was a no-op).
- Boot geometry: `BOOTIMG linear_start_addr 0x3180000, partition_size 0x1000000`;
  Q5 MBR preset `0x1400000`.

## 4. Pass timeline (chronological)

### System level (M1a)
- **M1a** — audio + button fixes at system-image level (Mint reference). Report:
  `.specs/forge-m1a-report.md`.

### Kernel tree + board port (M1b)
- **M1b** — chose `heyrudra/android_kernel_micromax_a106`; verified kernel 3.10.54,
  in-tree gcc 4.8. `.specs/bob-m2-spec.md`, `.specs/forge-m1b-report.md`.
- **D17** — port gslX680 touch driver from the Lithium blob. Firmware arrays
  (5 variants) pinned byte-exact in `gslX680_fw_q5.h`; power rails VIO28+VGP1.
- **D18** — port gc9503v WVGA LCM (display). `.specs/forge-d18-report.md`.
- **D19** — display-path guards: miss-bail in `mtkfb_probe` (-ENODEV) + bound the
  four DSI glitch polls + `_WaitForEngineNotBusy` break.
- **D20** — board-value port via DCT include-precedence (DrvGen O-dir no longer
  shadows source headers).
- **D21** — **MBR geometry fix**: live `cust_part_mbr` global was a106's
  `0xC00000`; Q5/Lithium require `0x1400000`. Added `init_pmt()` guard in
  `dumchar_probe`. Commit `fc2fd23`. (`0x660000` in `sd.c` was dead sample text.)
- **D22** — input repairs: touch driver loader/error-propagation + keymap
  `{VOLUP, VOLDOWN}` = `{172,158}`; added **alive gate** (reg `0xb0` == `0x5a`).
  Commit `8541368`. `.specs/forge-d22-input-report.md`.
- **D23 / D26** — *diagnostic-only* keep-driver-registered variants (NOT shipped).
- **D24** — power rails + 100 ms settle: 5-call `hwPowerOn` order (VGP4→VIO28→
  VGP1→MT6323_VGP1→MT6323_VIO28), byte-identical to the blob's E4 decode. The
  VGP4 call is a verified MT6323 no-op.
- **D25** — tpd framework integration (`.specs/bob-tpd-framework-spec.md`):
  `tpd_i2c_driver` name `mtk-tpd`, id_table `{gsl_tp,gsl1680,gsl915}`,
  initcall ordering (tpd before mt_i2c), `sw_inited` set AT ENTRY.

### Touch I²C bring-up (D27 → D33) — the current frontier

These were diagnosed iteratively against real device logs:

| Pass | Change | Result |
|------|--------|--------|
| **D27** | drop `I2C_ENEXT_FLAG` from transfers | controller stopped rejecting (`-14` gone) |
| **D28** | zero every `struct i2c_msg` (`ext_flag`) | adapter stopped wedging "busy" |
| *(after D27+D28)* | — | **panel answers: reads return real data** |
| **D29** | chunk transfers to ≤8 B (non-DMA) | **too slow** — firmware upload outran the watchdog → reset-loop (preloader blip ~60 s) |
| **D30** | DMA with `virt_to_phys()` buffer | boots; 81-byte DMA write goes out; `0xb0` still `0x00` |
| **D31** | alive gate non-fatal (experiment) | driver bound a DEAD chip → **no events** + device thrash (load 9+) |
| **D32** | restore fatal gate + print canary `0xb4` | fatal gate correct; canary print lost to boot-log rotation |
| **D33** | print `0xb0`/`0xb8`/`0xb4` on every `check_mem_data` | *board14 built (sha `abd3e7bdd13f…`), ready to flash* |

### Critical technical finding — heyrudra mt6582 I²C semantics

`drivers/misc/mediatek/i2c/mt6582/i2c.c`:
- `DMA_ADDRESS_HIGH = 0xC0000000`; a DMA buffer pointer must be **≤ 0xC0000000**
  (physical/low), else `-EINVAL_I2C` "DMA mode should use physical buffer address".
- `standard_i2c_start_xfer` **auto-DMAs when `msg->len > I2C_FIFO_SIZE` (8)**: it
  copies the caller's *virtual* buffer into `i2c->dma_buf.vaddr` and swaps in
  `dma_buf.paddr` itself. **Callers must NOT set `I2C_DMA_FLAG` themselves and
  must NOT pass `virt_to_phys()`** — a plain virtual buffer + full length +
  `ext_flag=0` works for any length.
- Non-DMA path rejects `trans_len * trans_num > 8`.
- `ext_flag` garbage (when `USE_I2C_MTK_EXT` is on) can set `I2C_3DCAMERA_FLAG`
  → keeps the clock enabled → "Current I2C Adapter is busy".
- Working in-tree convention (`ft5x06tb`): WRITE reg = 1-byte msg `{flags=0,
  timing=400}`; READ = write-reg-byte msg + read msg; all `i2c_msg` zeroed.

## 5. Current blocker

**The GSL chip's firmware does not boot.** Evidence:
- Transport is proven working: reads return real bytes, an 81-byte DMA write
  demonstrably goes out (`TX_LEN=81` in the register dump).
- Power is proven working: VGP1/VIO28 ON.
- Firmware arrays are present and correct (5 variants in `gslX680_fw_q5.h`).
- Yet `0xb0` (alive) stays `0x00`, and with a non-fatal gate (D31) **no physical
  touch events flow** — so the chip genuinely is not running firmware.

Most likely remaining causes, in order:
1. **Wrong firmware variant selected.** `gsl_sw_init` reads fingerprint reg
   `0xb8` to pick among 5 configs; if it reads `0` it falls back to `gsl_fw_hw`.
   The panel may need a different variant, or the fingerprint read itself fails.
2. **Load-sequence mismatch** (`io_control` / page select / `start_core` order or
   timing) vs what this specific chip expects.

**The decisive next datum is the fingerprint (`0xb8`) value — that is exactly what
board14 (D33) prints on every probe.**

## 6. Next step for Codex (resume point)

1. If board14 finished building: repack, flash (`BOOTIMG` only), then read the
   fingerprint by triggering a probe:

```bash
cd /home/yetisoldier/projects/timmkoo-q5-lithium7-fork
bash build/55_repack_boot.sh beta-touch-lcm-board14
# flash out/boot-m1b-beta-touch-lcm-board14.img via SP Flash Tool (BOOTIMG only)
adb root; adb shell 'echo 0-0040 > /sys/bus/i2c/drivers/mtk-tpd/bind'
adb shell 'dmesg | grep D33'   # -> alive(0xb0), fp(0xb8), canary(0xb4)
```

2. Interpret `fp(0xb8)`:
   - Non-zero, matches a known GSL variant → force `config_id` to the right entry
     in `gsl_cfg_table[]` (`.specs/bob-tpd-framework-spec.md` §5 has the mapping).
   - All-zero → the chip cannot report its ID; the load path/sequence is the
     problem (verify `gsl_io_control`, page-select `0xf0` writes, `start_core`).

3. Build/flash cycle (see §7). Always flash **BOOTIMG only** — never preloader,
   MBR/EBR, NVRAM, or calibration regions.

## 7. Reproduce the build & flash

Build a board image:
```bash
cd /home/yetisoldier/projects/timmkoo-q5-lithium7-fork
# ensure pristine kernel tree (re-clone heyrudra/android_kernel_micromax_a106 as .reference-kernel-3.10.54/kernel-3.10)
bash build/7x_kernel_delta_*.sh        # applies D1..D30+D32+D33, builds zImage + runs parity gates
bash build/55_repack_boot.sh beta-touch-lcm-board14   # repacks boot.img
```

Flash (BOOTIMG only) with SP Flash Tool:
```bash
cd /home/yetisoldier/.hermes/q5-recovery/spft/SP_Flash_Tool_v5.1648_Linux
./flash_tool -i /home/yetisoldier/.hermes/q5-recovery/spft/configs/q5-d32-boot-only.xml
```

Device bring-up / diagnostic:
- Device in preloader = `0e8d:2000`; Android ADB = `17ef:7495`, serial
  `0123456789ABCDEF`; `adb root` available after tapping the prompt.
- If `adb` is unresponsive (bound-dead-driver thrash): poke the **reset hole**
  then power.
- Reset-loop symptom = preloader blip reappearing every ~60 s.

## 8. Reference firmware inventory

| Firmware | Source | Location | Size |
|----------|--------|----------|------|
| Mint v1.0 boot.img | Sendew/TIMMKOO-Q5-Mint-Custom-ROM | `~/.hermes/q5-recovery/base/Mint_V1.0/boot.img` | 16 MB |
| Mint v1.0 system.img | same | `.../Mint_V1.0/system.img` | 859 MB |
| Mint v1.0 logo.bin | same | `.../Mint_V1.0/logo.bin` | 257 KB |
| Mint v1.0 scatter | same | `.../Mint_V1.0/MT6582_Android_scatter.txt` | 7 KB |
| Lithium donor boot.img | Lithium.Beta.v7.1.06.13.25.zip | `~/q5-flash/boot.img` | 5.2 MB |
| Lithium donor scatter | same | `~/q5-flash/MT6582_Android_scatter.txt` | 7 KB |
| Lithium full zip | vendor | `~/q5-flash/Lithium.Beta.v7.1.06.13.25.zip` | 307 MB |
| Mint full zip | Sendew GitHub | `~/.hermes/q5-recovery/base/TIMMKOO_Q5_MINT.zip` | 1.21 GB |

The essential `.img`/`.txt`/`.bin` files are attached to the GitHub release
`reference-firmware`; the full zips are re-downloadable from upstream.
