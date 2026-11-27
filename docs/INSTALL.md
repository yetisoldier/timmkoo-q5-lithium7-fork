# Install v1.0.1 on Q5 Gen 7 (Q5 Mint)

Only for the **MT6582, 480×800 Mint-style Q5 with one front Home circle**.
Read the README's compatibility and known-limits sections first.

## Prepare

1. Charge the Q5. Use a reliable USB data cable and keep the computer powered
   and awake throughout the write.
2. Back up internal files and accounts. A clean install erases them, including
   keys for adopted/encrypted microSD storage. Remove portable microSD cards.
3. Download `Q5-Gen7-Lithium7-v1.0.1.zip` and its `.zip.sha256` from the v1.0.1
   release. GitHub's Source code ZIP is not firmware.
4. Compare the entire SHA-256 result with the checksum file, then extract:

   ```powershell
   Get-FileHash .\Q5-Gen7-Lithium7-v1.0.1.zip -Algorithm SHA256
   ```

The bundle contains raw images, not an OTA. **Do not use TWRP Install ZIP.**
It does not repartition the Q5 or install a recovery.

## Method A: existing compatible TWRP and ADB

This is the automated route tested on the release device, which already has
compatible TWRP **3.6.0_9-0**. Do not flash a random Q5 recovery to meet this
prerequisite. You need Python **3.11+**, Android platform-tools (`adb` on PATH)
and a root ADB shell in that recovery. No Android root app is required.

1. If Android is running, enable USB debugging, approve your computer, then:

   ```text
   adb reboot recovery
   adb devices
   ```

   Wait for `recovery` beside the serial. If the host loses the connection,
   try `adb kill-server`, then `adb start-server`.
2. Open a terminal in the extracted release folder, substitute your serial.
   **For a clean installation** (required when coming from Mint/another ROM):

   ```text
   python install-adb-recovery.py --serial YOUR_SERIAL --factory-reset --reboot
   ```

   **To upgrade an existing official v1.0.0 or v1.0.1 installation while
   preserving apps, accounts, files and adopted-storage keys**, use this instead:

   ```text
   python install-adb-recovery.py --serial YOUR_SERIAL --upgrade --reboot
   ```

   The installer checks the installed release and private data/key fingerprints.
   It does not format data or clear cache in upgrade mode. Backups are still
   recommended; do not bypass a failed assertion.

3. Keep USB connected until all three images report **Readback verified**.
   The script validates hashes/layout and writes boot/system/logo. Only
   `--factory-reset` formats data and clears cache; `--upgrade` preserves them. Do not bypass a failed assertion.
4. Allow several minutes for first boot and complete Android setup. Approve
   USB debugging again only if you want to use ADB.

The installer does not format an external card. A former adopted card needs
reformatting for reuse once its internal decryption key has been erased.
See the [TWRP command-line reference](https://twrp.me/faq/openrecoveryscript.html)
for the recovery commands used by the script.

## Method B: an established MT6582 SP Flash Tool setup

Use your known-working Q5 Mint SP Flash Tool and MediaTek USB driver setup.
These tools/drivers are not bundled. The scatter uses the verified Mint
layout; the release device was installed using Method A, not this GUI route.

1. Arrange a working way to reset internal data in your existing compatible
   recovery. When moving from Mint/another Android version, format data before
   the new system's first boot. In compatible TWRP: **Wipe → Format Data**,
   then power off. This is not a whole-flash format.
2. Load the extracted `MT6582_Android_scatter.txt` in SP Flash Tool.
3. Select **Download Only** and check exactly:

   | Entry | Image |
   |---|---|
   | BOOTIMG | boot.img |
   | ANDROID | system.img |
   | LOGO | logo.bin |

4. Leave every other entry unchecked, including PRELOADER, MBR/EBR, UBOOT/LK,
   RECOVERY, NVRAM and PROTECT. **Never use Format All or Firmware Upgrade.**
   Do not mix files or scatters from different hardware revisions.
5. Click Download, then connect the powered-off Q5 using your established
   procedure. Wait for the success indication before unplugging.
6. Boot the Q5. If you have not reset data, use your existing compatible
   recovery to format internal data before continuing.

## After installation

- Navigation buttons start visible. Change **Settings → Buttons → Show
  navigation buttons** if desired.
- Physical Home: tap Home, double-tap Back, hold Recent Apps.
- Choose **Transfer files** in USB options to copy media.
- Plug in headphones as the FM antenna and tune a local station.
- After a clean install, reinstall optional streaming clients and sign in afresh. They and Google
  services are not included in the firmware bundle.
- A former adopted card may prompt for formatting. This erases its old files;
  choose portable storage to move it between the Q5 and a computer.

## Troubleshooting

First boot takes longer. If startup fails, return to the existing recovery,
check that all three images match this release, and confirm you used the appropriate clean-install or supported-upgrade mode.
Collect recovery/ADB logs when available. A failure is not a reason to format
the entire flash or write a different preloader.

Keep your own original/Mint backup. The project's `reference-firmware`
release is an archive, not a universal rollback package or a replacement for
your unit's NVRAM/calibration. Report reproducible issues without private data.
