# Q5 Lithium 7 Fork — Hermes Brief v0.1.0

## Objective

Fork **Lithium 7** (Android 7.1.2) so it runs correctly on Eric's **Q5 Mint** hardware variant,
porting the three hardware fixes that the Mint base firmware already has:

1. **Charging / PMIC** — Lithium reports `Max charging current: 0`, `Max charging voltage: 0`,
   and sits stuck at 0–1% battery. Mint's base charges correctly (USB-powered, voltage climbing).
2. **Speaker audio** — Lithium's internal speaker is silent (aux + bluetooth work).
3. **Buttons** — some physical buttons were non-functional under Lithium.
4. **Front camera** — the Q5 Mint has a front camera (Hynix sensor + DW9719/DW9714 focus
   actuator), marking the newer revision Lithium wasn't built for.

Goal: keep Android 7 (so modern apps / Apple Music remain possible) while carrying the correct
hardware configuration for THIS unit.

## Root-cause understanding (verified evidence)

**The device is the "Q5 Mint" variant** — a cheaper, quickly-discontinued hardware revision of
the Timmkoo Q5. This is the author's own description in the Mint ROM README: the mint-green unit
uses "a very similar official base, but with small differences likely made to reduce cost."

- **Mint ROM (Android 4.4.2 KitKat)** = theming changes on top of the Q5 Mint's *correct official
  KitKat firmware*. That is why its PMIC/audio/button config matches this hardware. The Mint author
  did NOT "fix" charging/audio/buttons — his base firmware already had them right.
- **Lithium 7 (Android 7.1.2)** targets the older / better-known Q5, whose hardware config differs.

So the fork is: keep Lithium 7's Android-7 userspace, but carry the hardware-correct config from
the Q5 Mint base (Mint ROM = our reference for that base).

### Audio (already forensically root-caused — see `~/q5-recovery/audio-delta-map.md`)
The kernel (`zImage`) is byte-identical across working (T-ROM/Manufactory) and broken (Lithium)
builds. The speaker defect is USERSpace, in three files:
1. `audio.primary.mt6582.so` — Lithium's HAL (846,160 B) lost the codec/amp routing vs the working
   T-ROM HAL (850,256 B).
2. `audio_policy.conf` — Lithium ships `audio_hal_version 2.0`; working builds ship `3.0`.
3. `mixer_paths.xml` — Lithium has a 122-byte stub whose only content is a bogus
   `<ctl name='MX2 WV3' value='100'/>`.

Speaker amp = Awinic **AW87559** (I2C `1-0058`); codec/DAC = **MT6323 PMIC**. `/proc/asound/cards`
stays empty on every ROM including the working ones, so that is NOT a reliable broken-audio signal.

### Charging (not yet root-caused — this is the main open question)
Lithium's battery service reports `Max charging current 0 / Max charging voltage 0` and the cell
stays at 0–1% despite USB power. Mint's base charges. Likely cause is the charger/PMIC device-tree
or kernel config in `boot.img` (the DTB), but this has NOT been diffed yet.

### Buttons (not yet root-caused)
`mtk-kpd` keypad driver loads on Mint; key layout config differs. Not yet diffed.

## Reference images (all on disk)

| ROM | boot.img | system.img | Notes |
|---|---|---|---|
| Lithium 7 (base to fork) | `~/q5-flash/rom/boot.img` (5,208,064 B) | `~/q5-flash/rom/system.img` (761,761,792 B) | the Android-7 base |
| T-ROM V2.3 (working audio HAL) | `~/.hermes/q5-recovery/base/T-ROM_V2.3/boot.img` | `~/.hermes/q5-recovery/base/T-ROM_V2.3/system.img` | audio reference |
| Mint V1.0 (correct hardware base) | `~/.hermes/q5-recovery/base/Mint_V1.0/boot.img` (16,777,216 B) | `~/.hermes/q5-recovery/base/Mint_V1.0/system.img` (859,832,320 B) | charging/button/PMIC reference |

Mint scatter: BOOTIMG at `0x3180000` (size `0x1000000`); ANDROID/system at `0x6500000`.

## Decisions Bob must make

1. **Charging fix** — is it a DTB patch (port Mint's charger/PMIC nodes into Lithium's `boot.img`
   DTB), a kernel-module/config change, or a userspace battery HAL config? Produce the exact
   porting plan with the specific nodes/files.
2. **Audio fix** — confirm the 7.1-compatible route: port T-ROM's `audio.primary.mt6582.so`
   codec/amp routing into a 7.1 HAL + fix `audio_policy.conf` (3.0) + real `mixer_paths.xml`, OR
   carry Mint's audio approach. Name the exact files and the porting method.
3. **Button mapping** — diff Lithium vs Mint key layout/config (`/system/usr/keylayout/*.kl`,
   `mtk-kpd`); map each physical button (side buttons + home) to its key code; name the exact fix.
4. **Camera fix** — is Lithium's kernel missing the front-camera sensor + DW9719 focus-actuator
   driver? Port it from the Mint base (kernel-level, like charging).

## Output

The fork delivers a modified **Lithium 7** `boot.img` + `system.img` that Eric flashes to the Q5
Mint, with charging, speaker, and buttons all working on Android 7.
