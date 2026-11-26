# Bob — Investigate the fork kernel boot hang (β+touch+lcm fails to boot)

## Symptom (verified on device)
The fork's boot (`out/boot-m1b-beta-touch-lcm.img` = heyrudra 3.10.54 + q5 board config + D1–D18 +
Lithium ramdisk + Lithium boot args) hangs at the **LK logo ("Timmkoo" splash)** and never reaches
Android. Preloader + LK boot fine (logo shows); the KERNEL is the failure point. Device was rolled
back to Mint (known-good).

## What to determine — root cause, ranked, with evidence
1. **Boot args / physical memory map.** Confirm the repack used Lithium's exact args (base 0x80000000,
   pg 2048, koff 0x8000, roff 0x04000000, soff 0x00f00000, toff 0x0e000000, board 1441186574,
   cmdline `bootopt=64S3,32S1,32S1 androidboot.selinux=permissive buildvariant=userdebug`). Is the
   heyrudra 3.10.54 kernel compatible with base 0x80000000 and Lithium's MT6582 memory map? Check the
   heyrudra tree's `.config`/Kconfig `CONFIG_` memory/DDR/PHYS_OFFSET settings vs what MT6582 needs.
2. **DRAM / memory.** Does the heyrudra `mach-mt6582` board config (DRAM type/size, memory layout)
   match the Q5? Compare the heyrudra tree's memory init vs Lithium's kernel blob (`5217dd41…`)
   string inventory for memory/DDR/emi/md32 hints.
3. **Board-config completeness.** The `q5` board dir was cloned from `a106`. What a106-specific init
   (clocks, PMIC, eint, GPIO, DDR, LCM) could be wrong for the Q5? Cross-check against Lithium's blob.
4. **Early-driver panic candidates.** Rank LCM (gc9503v), touch (gsl), camera (gc5004/hi253/hi704),
   amp (aw87559) as panic-at-init risks, and how to confirm.
5. **The decisive bisect.** The α image (`out/boot-m1b-alpha.img`) is the STOCK a106 build (NO
   deltas). If α boots (even with a dark a106-LCM screen), the tree is fine and a DELTA broke it; if
   α ALSO hangs, the tree/board-config itself is wrong. State this explicitly as the next flash test.

## Key references
- Known-good Lithium boot: `~/q5-flash/rom/boot.img` (boots, but has charging/audio bugs).
- α stock build: `out/boot-m1b-alpha.img`; β deltas: `out/boot-m1b-beta.img`;
  β+touch+lcm: `out/boot-m1b-beta-touch-lcm.img`.
- heyrudra tree: `.reference-kernel-3.10.54/kernel-3.10/` (a106 + q5 board dirs).

## Output — write to `.specs/bob-m3-boot-debug.md`
1. Root-cause hypotheses ranked (with the evidence for each).
2. The exact fix.
3. A minimal test plan: what to flash next and in what order (α-first isolation, then per-delta bisect).
4. Anything Forge should fix vs. rebuild from scratch.
