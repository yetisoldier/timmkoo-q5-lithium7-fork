# Bob — M4: design the board-config port (fix the α panic)

## Context (new evidence since M3)
The fork kernel (heyrudra tree + `q5` board cloned from `a106`) **PANICS** — reset-loop ~5 s
(`CONFIG_PANIC_TIMEOUT=5`) — on the Q5, confirmed by the α flash (stock a106, ZERO deltas) also
panicking. Deltas exonerated; board-config is the culprit. The panic log was LOST (ram-console
cleared by the SP flash; no AEE dump; no UART adapter available), so the fix is a **broad
board-config port**: decode the Q5's critical boot values from the Lithium kernel blob and port
them into `q5/`, replacing the a106 truth.

## What to determine (DESIGN — do not implement, do not build)
1. **Which board-config classes execute before the panic.** The logo persists ⇒ crash is before
   `mtkfb_probe` completes. Enumerate the early-init classes and rank by (a) how early they run and
   (b) how likely a wrong value is to cause a null-pointer / invalid-access PANIC (vs a hang):
   clocks/PLL, `cust_gpio_boot.h` boot-time pin modes/states, PMIC rails (`cust_pmic`/upmu), EINT
   channel map (`cust_eint.h`), keypad matrix, `cust_leds` backlight/PWM, DSI-LANE/TE pin modes.
2. **Which of these are decodable from the Lithium kernel blob** (`5217dd41…`, decomp at
   `~/.hermes/cache/scratch/opencode/bob-m1/lithium/kernel.decomp`, strings at `…/lithium-strings.txt`)
   using the proven D17/D18 method (the values are compiled constants / `mt_set_gpio_*` /
   regulator / clock-table literals in the blob). For each decodable class, state the decode method
   and the expected symbol/table shape.
3. **The port plan**: the exact files in
   `.reference-kernel-3.10.54/kernel-3.10/arch/arm/mach-mt6582/q5/` (and any defconfig clock/PLL
   toggles) to edit, the value to port, and a priority order — highest-risk-first (the earliest,
   panic-capable values), so the first re-flash maximizes the chance of a boot.
4. **A staged re-test plan**: flash the ported build → does it boot (or at least get further)?
   What observable (adb / dmesg / logo-clears) marks progress at each stage.

## Reference
- Lithium kernel blob + decomp + strings: `~/.hermes/cache/scratch/opencode/bob-m1/lithium/`.
- q5 board: `.reference-kernel-3.10.54/kernel-3.10/arch/arm/mach-mt6582/q5/` (a106 clone + D1–D18).
- D17/D18 reports (the blob-decode method) are in `.specs/`.

## Output — `.specs/bob-m4-board-port.md`
1. Early-init class ranking (with why each could panic).
2. Decode targets + method per class.
3. The port plan (files, values, priority) — implementation-ready for Forge.
4. Staged re-test plan.

End with "Design complete" or "partial (blocked on X)" + the remaining entry points.
