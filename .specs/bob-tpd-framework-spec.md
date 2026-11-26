# Bob — Touch integration via the MTK tpd framework (D25 design)

**Task:** `.specs/touch-tpd-framework-task.md` (design only; no implementation, no flashing).
**Status:** **Design complete.** Evidence basis: live device facts (2026-11-25), the pinned
Lithium blob disassembly (Forge D17 symbol-aware ELF, `~/.hermes/cache/scratch/opencode/forge-d17/lithium.elf`),
and this tree's `drivers/input/touchscreen/mediatek/{mtk_tpd.c,tpd.h,tpd_setting.c,tpd_default.c,tpd_button.c}`
plus `drivers/misc/mediatek/i2c/mt6582/i2c.c` and `arch/arm/mach-mt6582/mt_devs.c`.

---

## 0. Executive summary

The task's premise — "the panel answers the MTK framework driver, not our standalone i2c driver" —
must be read **operationally, not mechanically**: `mtk_tpd.c` contains **zero i2c code**. The
framework owns the input device, the probe loop, and the suspend/resume hooks; every electrical
property of the touch path (power rails, reset pulse, EINT, i2c transactions) comes from the
**panel driver** underneath it. What actually distinguishes stock Lithium from our fork is:

1. **The blob's panel driver names its i2c driver `TPD_DEVICE` ("mtk-tpd")** — proven today by
   reading the compiled `struct i2c_driver` out of the blob (§2.5). This is why stock shows
   `0-0040 -> mtk-tpd`. Our D17 port named it `"gsl_tp"` (an inference D17 made from the
   `id_table`, which the disassembly now refutes) — this alone breaks the acceptance criterion
   even if touch worked.
2. **The blob's probe sequence differs from ours** in ways D22/D23/D24 did not restore: it
   pre-masks the EINT and gates entry on a **5-retry read of reg 0xfc** before anything else,
   runs `gsl_sw_init` unconditionally before the alive check, sets its `sw_inited` guard (which
   our port declares but never sets — a latent bug found today), and has no late-i2c-board-info
   or diagnostic-keep-registered logic. Our port does a single-shot `check_mem_data` read
   immediately after the 100 ms settle and aborts on the first transport error.
3. For **every register the failing probe accesses**, the two implementations' wire bytes, bus
   speed (100 kHz standard path), power rails (D24 = byte-decoded blob order), and pin configs
   are **statically proven identical** (§4). Therefore the residual root cause of the ACKERR is
   not isolated by statics — the most defensible engineering move (and the one the task
   mandates) is to **converge every remaining observable on the blob implementation** and
   re-verify on hardware, with a disciplined diagnostic fallback that never ships.

**D25** therefore (a) renames the i2c driver to `TPD_DEVICE`, (b) rewrites the probe/local-init
sequences to the disassembled blob order, (c) ports the blob's virtual-button glue so
`mtk-tpd-kpd` exists, (d) removes the D23 diagnostic and the force-address-list side effects,
and (e) sets the never-set `sw_inited` guard. D22's repaired write/loader/alive-gate internals,
host tests, D24's 5-rail power, and D1–D21 stay untouched. Build: new stage
`66_kernel_delta_tpd.sh` → O-dir `build-beta-touch-lcm-board6` →
`out/boot-m1b-beta-touch-lcm-board6.img`.

---

## 1. Decisive, newly-generated evidence (this session)

All blob facts below come from the pinned, hash-asserted Lithium kernel blob (kernel
`5217dd41…`, decomp `d284ba16…`) disassembled through the D17 symbol-aware ELF (48,393 kallsyms
symbols). Line references quoted verbatim; Forge can reproduce each with
`.reference-kernel-3.10.54/arm-eabi-4.8/bin/arm-eabi-objdump -s/-d`.

| # | Fact | Provenance |
|---|------|-------------|
| E1 | Stock's touch i2c driver name is **`"mtk-tpd"`**, not `"gsl_tp"` | `struct i2c_driver` @ VA `0xc0b74d64`, field `+0x24` (`device_driver.name`) = pointer `0xc0a00da0` = string `"mtk-tpd"` (rodata context: `…virtualkeys.` `mtk-tpd\0` `[tpd_em_log]…`). Struct also: `probe=0xc034e048 (gsl_probe)`, `remove=0xc034c188 (gsl_remove)`, `id_table=0xc0886914 ("gsl_tp" table)`, `detect=0xc034c3e4 (gsl_detect)`, **`address_list=NULL`**, self-linked `clients` head. |
| E2 | The blob's `tpd_local_init` (`0xc034c344`) = `get_boot_mode()` store ≠ `SW_REBOOT` → `tpd_button_setting(keycnt=2, keys@0xc0b74d3c, dims@0xc0b74d44)` → `i2c_register_driver(NULL-owner, &tpd_i2c_driver)` → on failure return `-ENODEV`; after return, `tpd_load_status==0` ⇒ `i2c_del_driver` + `-ENODEV`; success ⇒ store `1` into `tpd_load_status` (`0xc0c681c8`, the module param). **No power, no GPIO, no board-info in local_init.** | disasm `c034c344–c034c3dc` |
| E3 | Blob's virtual keys = **`{172, 158}` = `{KEY_HOMEPAGE, KEY_BACK}`**, dims `{{100,900,40,40},{300,900,40,40}}` (`x, y, width, height`). Blob's report path calls `tpd_button(x, y, down=1)` on the touch-down branch (site `0xc034d4f0`, between the `ABS_MT_POSITION_X` and `ABS_MT_TRACKING_ID` events); **no release-path call site exists** (keys sit at y=900 outside the 480×800 panel — vendor-faithful is down-only). | disasm + rodata `0xc0b74d3c–0xc0b74d60` |
| E4 | Blob's `gsl_probe` order (`0xc034e048`): alloc state → 5× `hwPowerOn`: **`(0x22=MT65XX_POWER_LDO_VGP4, 2800)`, `(25=MT65XX_POWER_LDO_VIO28, 1800)`, `(0x1f=MT65XX_POWER_LDO_VGP1, 2800)`, `(5=MT6323_POWER_LDO_VGP1, 2800)`, `(0=MT6323_POWER_LDO_VIO28, 1800)`** tag `TP`; reset pulse GPIO14 (mode0/out, low 20 ms → high 20 ms); INT GPIO2 (mode0, in, pull-up); **`msleep(100)`; `mt_eint_mask(2)`**; `dev_set_drvdata`; **`gsl_test_i2c`** (below); then `gsl_probe.part.4`. | disasm `c034e048–c034e1ac` |
| E5 | Blob's `gsl_test_i2c` (`0xc034c2b4`) = gate, not self-test: **read 4 bytes of reg `0xfc`, up to 5 attempts** (`r4=#5` loop, `bgt` early-out); `-1` after 5 failures; probe aborts on failure (`blt → kfree, return`). | disasm `c034c2b4–c034c320` |
| E6 | Blob's `gsl_probe.part.4` (`0xc034de40`): `gsl_sw_init(client)` (guarded by `sw_inited`, set to 1 **at entry** — `0xc034d7e8`) → `msleep(20)` → `check_mem_data` (read 4 B reg `0xb0`; alive ⇔ **all four bytes `0x5a`**; else `gsl_sw_init` which is now a guarded no-op) → `kthread_create_on_node`+`wake_up_process` → `mt_eint_registration(2, RISING, handler, auto_umask=1)` → `proc_create_data("gsl_config", …)` → `gsl_DataInit(cfg[selected])` → `sysfs_create_group` → `mt_eint_unmask(2)` → tail: 1 write + `msleep(5)` + up to 4× read (results only logged, non-fatal). | disasm `c034de40–c034e020`, `c034d7ac–c034d80c`, `c034dcdc–c034dd50` |
| E7 | Blob's transfer helpers: writes = single-message `i2c_transfer` with a staged `[addr … | reg | payload]` buffer, `len=num+1`, `timing=400` (site `0xc034c514`), under a mutex; **reads = plain generic `i2c_master_send`(1-byte reg) + `i2c_master_recv`(≤8-byte chunks, register re-sent/advanced per chunk)** (sites `0xc034c208/c034c218/…`); no ext flags anywhere. | disasm `c034c1a4–c034c2b0`, `c034c480–c034c52c` |
| E8 | This tree's mt6582 i2c core: `USE_I2C_MTK_EXT` **undefined** ⇒ `master_xfer = standard_i2c_transfer`; `COMPATIBLE_WITH_AOSP` **commented out** (`i2c.c:33`) ⇒ per-message `ext_flag` zeroed and `timing` replaced by `pdata->speed` (`i2c.c:1043–1049`); multi-message transfers are **split into separate STOP-terminated transactions** per message. Adapter speeds = `mt_i2c_data_t[]` in `mt_devs.c`: **bus0=100, bus1=110, bus2=120 kHz**. `I2C_ENEXT_FLAG = 0x0200` is consumed **nowhere** in this core (inert). | `i2c.c` (grep anchors: :1339 selection, :1043 :1048 drop, :890–940 translate), `mt_devs.c:866–882` |
| E9 | Client instantiation on **our fork is live and equivalent**: `__initcall_tpd_driver_init6` (`tpd_driver_init`, drivers/input/touchscreen → links at `0xc0c878c8`) runs **before** `__initcall_mt_i2c_init6` (`0xc0c87a30`, drivers/misc/mediatek/i2c) on the built board5 `vmlinux` — so our module_init `i2c_register_board_info(0, {"gsl_tp",0x40})` is scanned at adapter-add; the D23 live test (`echo 0-0040 > /sys/bus/i2c/drivers/gsl_tp/bind` worked) proves the client exists on hardware. drivers/Makefile: `input/` (line 58) before `misc/` (line 59). | `nm -n` on `build-beta-touch-lcm-board5/vmlinux`; drivers/Makefile |
| E10 | `ERROR 548` = `i2c.c:548 I2CERR("I2C_ACKERR")` — the controller genuinely saw the address phase NAKed (SDA high at ACK), post-transaction softreset per error. Not a timeout, not DMA. | `i2c.c:547–548` |
| E11 | Pin boot-defaults (q5 DCT lineage — byte-equal to the a106/D15/D16-asserted headers): GPIO84 `MODE_01` (i2c function), in, pull-up; GPIO14 out/high off-reset; GPIO2 in, pull-up. `cust_gpio_usage.h` is identical to the blob's wiring constants (D17 §2.4). | `cust_gpio_boot.h:112–116, 602–606`; `cust_gpio_usage.h:43,133` |
| E12 | The stock blob registered `{gsl_tp@0x40, Hyn_device@0x5a, Hyn_device_cst2xx@0x5d}` board info from **board/mach-level init** (rodata table @`0xc0b0af98`, calls in the `0xc0aef…–0xc0af4…` mach region), not from the driver; this tree's `mt_devs.c:845–1642` has the equivalents **commented out** — D17's driver-side registration is our live equivalent. | disasm call sites; `mt_devs.c:851` |

---

## 2. Framework contract (`drivers/input/touchscreen/mediatek/`)

### 2.1 `mtk_tpd.c` — the framework core

* `tpd_device_init` is a **`late_initcall`** (line 594): registers the platform device
  `TPD_DEVICE` = `"mtk-tpd"` (CONFIG_OF branch) and the platform driver of the same name.
  Every panel driver must already have called `tpd_driver_add()` from its own
  **`module_init`** (device_initcall — earlier in time, so `tpd_driver_list` is populated).
* `tpd_probe(pdev)`: allocates `struct tpd_device` + the input device named **`TPD_DEVICE`**
  ("mtk-tpd" — the event node's name; this is a framework constant, not per-panel), sizes
  `TPD_RES_X/Y` from `CONFIG_LCM_WIDTH/HEIGHT`, then iterates **`tpd_driver_list[1..TP_DRV_MAX_COUNT-1]`**
  (`TP_DRV_MAX_COUNT = 20`): for each entry with a non-NULL name it calls
  **`tpd_local_init()`** and accepts the first one that leaves the global
  **`tpd_load_status == 1`** as `g_tpd_drv`. If no cap driver succeeds it falls back to slot 0
  (`"generic"` R-touch probe) and otherwise prints
  `"cap touch and Generic touch both are not loaded!!"` and **returns 0 with no input device
  registered** — i.e. an absent/failed panel driver manifests as the *silent absence* of
  `mtk-tpd`/`mtk-tpd-kpd` (important for validation).
* After a driver is selected: abs-event setup (incl. `ABS_MT_TRACKING_ID` bit), earlysuspend
  handler wired to the panel's `suspend/resume`, `input_register_device`, and
  **`tpd_button_init()` iff the panel set `tpd_have_button = 1`** (registers the second input
  device `tpd->kpd->name = TPD_DEVICE "-kpd"` = **"mtk-tpd-kpd"**, `tpd_button.c:56`) plus
  per-driver sysfs attrs and the three fw-info files on the platform device.
* `tpd_driver_add(struct tpd_driver_t*)`: refuses a second registration once `g_tpd_drv` is set
  (`-1`), dedups by `tpd_device_name` (`1` = already present), stores
  `{tpd_device_name, tpd_local_init, suspend, resume, tpd_have_button, attrs,
  tpd_get_fw_version, tpd_get_fw_vendor_name}` into slots 1..19; slot 0 is the reserved
  `"generic"` R-touch entry.
* **The framework never touches I2C, GPIO, PMIC or EINT.** The only artifacts it owns are the
  input devices, the probe loop, and suspend/resume dispatch (earlysuspend level
  `EARLY_SUSPEND_LEVEL_STOP_DRAWING - 1`).

### 2.2 `struct tpd_driver_t` — what a panel driver must provide

```c
struct tpd_driver_t {                  /* filled by D25 (blob-decoded values) */
	char *tpd_device_name;         /* list identity only; "generic" is reserved.
	                                  Keep "gsl_tp" (blob-parity for tpd_probe's log). */
	int  (*tpd_local_init)(void);  /* called from tpd_probe; see 2.3 */
	void (*suspend)(struct early_suspend *h);   /* our D22 tpd_suspend */
	void (*resume)(struct early_suspend *h);    /* our D22 tpd_resume  */
	int tpd_have_button;           /* must be 1 (blob E3) so mtk-tpd-kpd registers */
	struct tpd_attrs attrs;        /* empty */
	int (*tpd_get_fw_version)(void);        /* NULL */
	void (*tpd_get_fw_vendor_name)(char *); /* NULL */
};
```

### 2.3 `tpd_local_init` semantics (blob E2, normative for D25)

1. Read `get_boot_mode()`; store it (`0` if it equals `SW_REBOOT`) into a static.
2. `tpd_button_setting(2, gsl_tp_keys, gsl_tp_keys_dim)` with
   `keys = {172, 158}` (KEY_HOMEPAGE, KEY_BACK) and
   `keys_dim = {{100,900,40,40},{300,900,40,40}}` (`tpd_button.c:108` memcpy contract:
   `keycnt*4` + `keycnt*4*4` bytes).
3. `i2c_add_driver(&tpd_i2c_driver)` — this is where `mtk-tpd` appears on the i2c bus and
   where the pre-created `0-0040` client binds (id-table match on `"gsl_tp"`) and
   **synchronously runs the i2c probe** — i.e. the entire panel bring-up happens *inside* this
   call from the framework's `tpd_probe` context.
4. On registration failure → return `-1`.
5. After the register call returns: if `tpd_load_status == 0` → `i2c_del_driver(&tpd_i2c_driver)`
   + return `-1` (**this is exactly the D22 production behavior D23 disabled**); else return 0.

### 2.4 Ownership map (who does what)

| Asset | Owner | Notes |
|---|---|---|
| `mtk-tpd` + `mtk-tpd-kpd` input devices, abs ranges, `misc "touch"` node, fw sysfs attrs | framework (`mtk_tpd.c`, `tpd_button.c`) | names are `TPD_DEVICE`-derived constants |
| i2c client `0-0040` ("gsl_tp") | board info → i2c core | created at adapter-add (E9); the panel driver does not instantiate it |
| i2c **driver** name seen in sysfs (`0-0040 -> mtk-tpd`) | panel driver (`tpd_i2c_driver.driver.name = TPD_DEVICE`) | binding itself is by `id_table` vs client name |
| bus speed | adapter platform data (`mt_i2c_data_t[]`, bus0=100 kHz) | per-message `timing`/`ext_flag` are inert on this build (E8) |
| EINT 2 rising (`CUST_EINT_TOUCH_PANEL_NUM`, `TPD_EINT_FLOW`) | panel driver (`mt_eint_registration`, auto_umask=1) | blob pre-masks before first contact (E4/E6) |
| power rails | panel driver i2c probe (5-call D24 sequence = E4, byte-verified) | framework has no power step |
| suspend/resume | framework earlysuspend → panel fns | i2c_driver suspend/resume stay NULL (blob E1 struct: both 0) |
| `/proc/gsl_config`, `db_interface` class | panel driver | D17/D22 state preserved |

### 2.5 Interaction with the i2c name `"gsl_tp"`/0x40

`tpd_driver_t.tpd_device_name` has **no** connection to i2c naming: it is only the
registration-list identity (dedup + probe logging). The i2c chain is:

- client name `"gsl_tp"`, addr `0x40`, bus `0` — from `I2C_BOARD_INFO(GSLX680_NAME, 0x40)`
  registered in our `tpd_driver_init` (module_init), scanned at adapter-add (E9);
- **binding** = i2c core matches `client->name` against `tpd_i2c_driver.id_table`
  (`{"gsl_tp","gsl1680","gsl915"}`, matches `gsl_device_id` in blob rodata);
- the sysfs driver link shows **`tpd_i2c_driver.driver.name`** — which must be
  **`TPD_DEVICE` ("mtk-tpd")** to satisfy the acceptance and match E1. Because all MTK panel
  drivers conventionally use this same name, exactly one panel CONFIG may be enabled at a
  time (a second `mtk-tpd` i2c driver registration would `-EBUSY` on the sysfs name).

### 2.6 `tpd_default.c` / `tpd_setting.c`

`tpd_default.c` is a shared dummy (trembling-tolerance fn) — unchanged, untouched. `tpd_setting.c`
carries the globals (`TPD_RES_X/Y`, `tpd_type_cap`, **`tpd_load_status` as a module param**
— readable at `/sys/module/tpd_setting/parameters/tpd_load_status`, identical mechanism to the
blob's `__param_tpd_load_status`) — no changes needed.

---

## 3. Mapping of our existing D17/D22/D23/D24 code into the framework shape

| Existing piece (state today, board5 tree) | Disposition under D25 | Belongs to |
|---|---|---|
| `gsl_read_interface` / `gsl_write_interface` + D22 payload contract (`mtk_gslX680.c:228–284`) | **keep verbatim (Phase A)** — E7 proves the write wire form is identical (single staged write) and the read form is identical for every register the flow touches (W(reg);STOP;R(4) after the core splits our 2-msg form). The blob's ≤8 B read chunking / `(reg+8)&0x5c` low-reg settle is inert for our traffic; port only if Phase A fails on hardware (Phase B, §7). | panel i2c `.probe` helpers |
| `gsl_i2c_read_bytes` / `gsl_i2c_write_bytes` (128 B chunking, payload-only) | keep verbatim | panel helpers |
| `gsl_load_fw` (D22 bounded page-aware batches, LE) | keep verbatim — wire-equivalent to the blob's per-record small writes; D22 host tests pin it | panel helpers |
| `gsl_check_alive` bounded 0xb0 gate (D22, 3×200 ms) | **keep (deliberate bounded deviation)** — blob confirms once; ours is a superset, harmless | panel i2c `.probe` |
| `check_mem_data` | keep, but reposition after `gsl_sw_init` per blob order (E6), and keep the D22 signature-only-byte0 gate (blob wants all 4 bytes `0x5a`; our bounded re-check subsumes) | panel i2c `.probe` |
| `gsl_sw_init` (fingerprint cascade, canary, load) | keep verbatim; **add `gsl_dev.sw_inited = 1` at entry** (E6 — our port declares but never sets it, so a re-probe would re-download) | panel i2c `.probe` |
| reset GPIO14 (`gsl_gpio_init` first half), 100 ms settle (D24) | keep; **call order changes** — blob pulses reset in probe, then INT pin, then 100 ms, then EINT mask (E4) | panel i2c `.probe` |
| INT GPIO2 pull-up | keep (blob-identical) | panel i2c `.probe` |
| EINT 2 rising (`gsl_eint_register`) | keep registration `(2, RISING, handler, 1)`; **add `mt_eint_mask(2)` before the first i2c contact** (E4/E6: mask → … → register → unmask after DataInit) | panel i2c `.probe` |
| 5-rail power (`gsl_power_on`, D24) | keep verbatim — D24's call list is byte-identical to E4's decode (34→25→31→5→0); D24's "no-op VGP4" claim matches the task evidence | panel i2c `.probe` |
| event thread (`touch_event_handler`) + `mt_eint` handler | keep verbatim | panel i2c `.probe` |
| report path (`report_data_handle`/`gsl_report_point`) | keep; **add `tpd_button(x, y, 1)` on the down branch** (E3, site `c034d4f0`) — no release site in the blob, documented | panel report path |
| `/proc/gsl_config` debug interface | keep verbatim | panel driver |
| `db_interface` class | keep (blob uses a sysfs group instead; inert either way) | panel driver |
| `i2c_register_board_info(0, {gsl_tp @0x40}, 1)` in `tpd_driver_init` | **keep** — proven live by E9; the blob does the equivalent from mach init (E12) | panel module_init |
| `tpd_i2c_probe` (= the framework's i2c side, our "tpd_i2c_probe equivalent") | **rewrite order + add the 0xfc×5 pre-gate + EINT pre-mask** (E4–E6) | panel i2c `.probe` |
| D23 keep-registered diagnostic block in `tpd_local_init` | **remove** — replace with blob's `i2c_del_driver` + `-1` (E2); D23 must not ship (task step 5) | `tpd_local_init` |
| `tpd_i2c_driver.driver.name = "gsl_tp"`, `.address_list = {0x40,…}`, `.detect` | **rename to `TPD_DEVICE`; delete `.address_list`/`force[]`** (blob keeps `.detect` registered but `address_list=NULL` so it is inert; our force list also triggers the core's smbus-quick emulation against a core that rejects NULL-msg buffers — dead weight at best) | panel i2c driver struct |
| `tpd_local_init` (power-on + register + status check) | **rewrite to blob order** (E2): boot-mode store → `tpd_button_setting` → `i2c_add_driver` → status check/del; **drop the `input_set_abs_params(ABS_MT_TRACKING_ID…)` line** from local_init? **No — keep it** (deliberate deviation: the framework only sets the `ABS_MT_TRACKING_ID` *bit* without a range; leaving our range set protects MT-B id events; harmless vs blob) | `tpd_local_init` |
| `tpd_device_driver.tpd_have_button = 0` (dead `#ifdef TPD_HAVE_BUTTON`) | **set 1** + provide keys/dims (E3) — without it the framework skips `tpd_button_init` and **`mtk-tpd-kpd` never exists** (acceptance failure) | `struct tpd_driver_t` |
| `tpd_suspend` / `tpd_resume` (D22) | keep verbatim | `struct tpd_driver_t` + earlysuspend |
| D24 `100 ms` settle + 5-rail order | keep verbatim (already blob-exact) | panel i2c `.probe` |

---

## 4. Why the standalone path fails — proven facts vs hypotheses

### 4.1 The task's candidate causes, answered from evidence

* **"Client/bus configuration"** — *proven equivalent.* Client `0-0040`/bus 0 is instantiated
  from static board info in both kernels (E9/E12), and existed live on our fork (D23 bind).
  Binding is by id_table; the only difference is the driver's sysfs **name** (E1 vs ours) — a
  name cannot change what a panel ACKs on the wire, and the framework itself performs zero i2c
  (`§2.1`). So "the framework driver answers because it is the framework" is not a mechanism;
  the mechanism must lie in the panel driver's sequence/identity, which is what D25 restores.
* **"Timing at `device_initcall` vs `module_init`"** — *proven equivalent.* The blob's
  `tpd_device_init` is also `late_initcall` (`c0aea134` region matches the in-tree late_initcall
  shape), and the client precedes adapter-add in both (E9). No ordering gap exists.
* **"Bus speed"** — *proven identical.* Bus 0 runs at 100 kHz via `standard_i2c_transfer` in
  both; per-message `timing=400`/ext flags are dropped by this core (E8) and were equally
  inert in the blob's standard path. A slower-than-stock clock cannot NAK a chip that ACKs
  faster traffic; a minimum-clock requirement is not physically plausible.
* **"Pull-up/pin state at that moment"** — *proven equal at the source level* (E11): I²C0 pins
  are mode-01/pull-up from boot defaults (same DCT lineage, D15/D16-asserted), reset/INT pins
  identical, and our driver writes the same mode/dir/pull values the blob writes. Residual
  caveat (hypothesis-grade): the *runtime application* of the DCT boot table in our compiled
  kernel vs the blob's compiled table was not disassembly-proven (D20's class of bug) — this is
  covered by hypothesis H-KERN below.
* **"The framework's power sequence order"** — the framework *has none*; the panel driver's
  power sequence is **proven identical** after D24 (E4: five `hwPowerOn` calls, IDs and voltages
  decoded; VGP4 is the verified MT6323 no-op; rails `VGP1=1, VIO28=1` verified on device).

### 4.2 Proven remaining deviations from the one implementation that works (the blob)

| # | Deviation (ours → blob) | Effect class |
|---|---|---|
| P1 | i2c driver name `"gsl_tp"` → `"mtk-tpd"` | acceptance/wiring (§2.5) |
| P2 | single-shot first access (`check_mem_data` read @0xb0 right after 100 ms) → blob gates entry on a **5×-retried 0xfc read** and pre-masks EINT | probe liveness under panel boot-state races |
| P3 | our probe never runs `gsl_sw_init` when the 0xb0 check passes, sets `sw_inited` never → re-probes re-download; blob sets `sw_inited=1` at entry and always runs guarded sw_init first, then confirms | re-probe/earlysuspend-state fidelity |
| P4 | `tpd_have_button=0`, no `tpd_button_setting`, no `tpd_button` down-call ⇒ **no `mtk-tpd-kpd`** | input-device presence (acceptance) |
| P5 | D23 keep-registered diagnostic + force-address-list | must not ship; force list invokes the core's NULL-message quick path |

### 4.3 Hypotheses for the live ACKERR (none statically resolvable — ranked, each with its
discriminating live test; **no cause may be asserted by Forge**)  {#sec-4.3}

**H-SEQ (probe liveness window).** The panel was not ACK-capable at the exact moment of our
single first read, and our path aborts instantly while the blob rides it out (0xfc×5 retries,
long masked-EINT window, unconditional re-init at probe). *Contradicting datum:* the D23 rebind
sweep re-ran power+pulse+100 ms after boot and still NAKed — so H-SEQ alone explains boot-time
failure but not persistence. *Discriminator (D26 diag):* with rails verified on, issue a
bounded 0xfc read loop from a diagnostic image and log each attempt's error over ~10 s; if the
panel ever ACKs, H-SEQ's race model holds and the blob's gate absorbs it.

**H-KERN (residual kernel-lineage delta not covered by strings parity).** Our kernel is compiled
from the donor lineage; the blob's from the vendor tree. δ-parity pins *strings*, not e.g. the
compiled DCT boot-table application, mt_gpio init ordering, PMIC rail-up timing, or the i2c
controller's clock/divisor inputs (`i2c_set_speed` uses `i2c->clk` from the CCF clock tree).
A difference in any of these changes effective pin/pad or clock state at access time with no
string trace. *Discriminator:* full `cat /proc/mt_pmic/dump_ldo_status`, a `mtk-i2c` `ut`
debug dump (`/sys/…/i2c_common/ut op=3` prints controller registers + GPIO in-states —
`i2c_common.c:350–352`) and a boot-dmesg diff stock-vs-ours on i2c-0.

**H-STATE (our earlier-boot drivers leave the panel/bad state).** Drivers we ported (D18 LCM,
D14 camera/Hynix on bus 0, power/charging D1–D7) bring up shared resources *in our order*; if
any leaves a shared rail/pad/reset in a state the blob's compiled siblings did not (e.g. an
LCM/board pad that aliases CTP_RST GPIO14 or a camera toggling shared pull rails), the panel is
dead-or-reset at late_initcall and our driver never recovers it. *Discriminator:* compare
`cust_gpio_boot`-applied states (ut op=3 dump), then in the diag build add explicit
mode/dir/readback prints for GPIO2/14/84/85 immediately before the 0xfc gate.

**Explicitly non-assertable:** the task's literal wording ("the panel answers the framework")
must not be recorded as a mechanism; §4.1 documents why no framework-side i2c mechanism exists.

### 4.4 Design conclusion

Every statically-known parameter is proven equal; every statically-known *deviation* is P1–P5.
D25 removes P1–P5 by converging to the blob — the only implementation ever observed ACKing this
panel — and the D26 diagnostic (built only if hardware still fails) exists solely to
discriminate H-SEQ/H-KERN/H-STATE. This satisfies "do not assert an unverified cause" while
giving Forge a decisive, evidence-complete implementation.

---

## 5. D25 implementation plan — exact files and order of operations

### 5.1 Patch: `patches/kernel/D25-tpd-framework-integration.patch`

Applies on the stage chain `D1 D2 D8 D9 D10 D11 D12 D13 D14 D4 D17 D18 D19 D20 D21 D22 D24`
(the production chain; **D23 is not applied**) — i.e. on top of the board5 (D24) state.
Touches **only the two untracked D17 files** (the tracked-file set asserted by the stage stays
exactly the 65-stage list):

1. **`drivers/input/touchscreen/mediatek/gslX680/mtk_gslX680.c`** (in this order, all changes
   flagged `/* D25 */` with the evidence anchor):

   a. *i2c driver identity:* `.driver.name = TPD_DEVICE` (was `GSLX680_NAME`). Remove
      `static unsigned short force[]`/`forces[]` and the `.address_list = …` initializer.
      Keep `.id_table` (`gsl_tp/gsl1680/gsl915`), `.detect = tpd_i2c_detect`, `.probe`,
      `.remove` (blob E1: detect present, address_list absent).
   b. *New blob-faithful pre-gate:* `static int gsl_await_chip(struct i2c_client *client)`
      = blob `gsl_test_i2c` shape (E5): loop `GSL_CHIP_AWAIT_TRIES = 5`:
      `gsl_read_interface(client, 0xfc, buf, 4)`; return 0 on first success; after 5 failures
      print `gsl_tp: chip not answering 0xfc after 5 reads` and return `-1`.
   c. *`tpd_i2c_probe` reorder* (E4/E5/E6):
      ```
      gsl_power_on();                         /* 5 rails, D24 order — unchanged */
      gsl_gpio_init();                        /* RST pulse + INT pull-up + msleep(100) — unchanged */
      mt_eint_mask(CUST_EINT_TOUCH_PANEL_NUM);/* D25: pre-mask before first contact */
      ret = gsl_await_chip(client);           /* D25: blob 0xfc×5 gate */
      if (ret != 0) { GSL_LOGE("D25: chip gate failed"); return ret; }
      ret = gsl_sw_init(client);              /* guarded; now sets sw_inited */
      if (ret != 0) { ... return ret; }
      msleep(20);
      ret = check_mem_data(client);           /* alive confirm (+sw_init if dead) */
      if (ret != 0) { "D22: init failed" path — keep marker; return ret; }
      gsl_eint_register();                    /* registration(2, RISING, h, 1) — unchanged */
      thread = kthread_run(...);              /* unchanged */
      tpd_load_status = 1;
      proc_create(...) / db class state      /* unchanged */
      gsl_dev.halt = 0;
      gsl_data_init_selected(client);         /* D25: blob does gsl_DataInit(cfg[selected]) at
                                                 probe end (E6) — add: call gsl_DataInit over the
                                                 ACTIVE config's words (identical to what
                                                 gsl_start_core already does; keep for parity) */
      mt_eint_unmask(CUST_EINT_TOUCH_PANEL_NUM);
      /* D25 bounded confirm (non-fatal): msleep(5) + read 4 B reg 0xfc up to 4 tries, log only */
      return 0;
      ```
      Keep every `D22: …` marker string that the 65-stage rodata gate greps
      (`D22: init failed`, `D22: fw load failed`, `D22: resume init failed`).
   d. *`gsl_sw_init`:* set `gsl_dev.sw_inited = 1` immediately after the guard check (E6).
   e. *`tpd_local_init` rewrite* (E2):
      ```
      static int gsl_bootmode;               /* D25 blob parity (E2 step 1) */
      tpd_local_init() {
          gsl_bootmode = get_boot_mode();    /* BOOTMODE enum, mt_devs.c:36 extern; SW_REBOOT→0 */
          if (gsl_bootmode == SW_REBOOT) gsl_bootmode = 0;
          tpd_button_setting(ARRAY_SIZE(gsl_tp_keys), gsl_tp_keys, gsl_tp_keys_dim);
          if (i2c_add_driver(&tpd_i2c_driver) != 0) { GSL_LOGE("add i2c driver failed"); return -1; }
          if (tpd_load_status == 0) {        /* D22 production semantics restored; D23 removed */
              i2c_del_driver(&tpd_i2c_driver);
              GSL_LOGE("probe failed — i2c driver unregistered");
              return -1;
          }
          input_set_abs_params(tpd->dev, ABS_MT_TRACKING_ID, 0, MAX_CONTACTS + 1, 0, 0);
          tpd_type_cap = 1;                   /* kept deliberately — see §3 (harmless deviation) */
          return 0;
      }
      ```
      The `D23 DIAG ONLY` block is deleted; no `bind`-hint strings remain.
   f. *Buttons (E3):*
      ```c
      #define TPD_HAVE_BUTTON 1  /* local, above the keys table */
      static const int gsl_tp_keys[2]      = { 172 /*KEY_HOMEPAGE*/, 158 /*KEY_BACK*/ };
      static const int gsl_tp_keys_dim[2][4]   = { {100, 900, 40, 40}, {300, 900, 40, 40} };
      ```
      `tpd_device_driver.tpd_have_button = 1;` (drop the `#ifdef TPD_HAVE_BUTTON` branch).
      In `gsl_report_point`'s down branch, after the `ABS_MT_POSITION_X` report of contact 0:
      `tpd_button(ti->x[0], ti->y[0], 1);` (blob site `c034d4f0`; no release call — blob has
      none; document in the comment). `tpd_button` is declared in `tpd.h`.
   g. *Report-path comment*: annotate the `tpd_button` call site with `D25 [BLOB c034d4f0]`.
   h. *Prologue*: append the D25 evidence paragraph to the file header (E1–E8 anchors) and bump
      the provenance note: i2c driver name = `TPD_DEVICE` per blob struct decode `0xc0b74d64/0xc0a00da0`.

2. **`arch/arm/mach-mt6582/q5/touchpanel/gsl_tp/tpd_custom_gsl_tp.h`** — comment-only update:
   note that the i2c driver name is `TPD_DEVICE` (blob-decoded), constants unchanged
   (`TPD_I2C_NUMBER 0`, `GSLX680_NAME "gsl_tp"`, `GSLX680_ADDR 0x40`, power tags,
   `TPD_EINT_FLOW EINTF_TRIGGER_RISING`).

3. **Nothing else**: no Kconfig/defconfig/Makefile/keymap/board/MBR/LCM changes.
   `mtk_tpd.c`, `tpd_button.c`, `tpd_setting.c`, `tpd_default.c` are **not modified** by D25.

### 5.2 Build stage: `build/66_kernel_delta_tpd.sh`

Clone the 65-stage structure exactly (determinism: donors-pin pass, reference-tree reset with
the same `rm`-list + `build-beta-touch-lcm-board6` added to the O-dir whitelist, patch order
`D1 D2 D8 D9 D10 D11 D12 D13 D14 D4 D17 D18 D19 D20 D21 D22 D24 D25` last, mtime pinning with
the same find-list, `BUILD_CC` stamps from `40_kernel_env.sh`), O-dir
`build-beta-touch-lcm-board6`, out `out/kernel-parity-beta-touch-lcm-board6.txt`.

Gates, in order:

1. All carried invariants re-asserted (identical greps/`cmp` to the 65 stage):
   **D2** (14 charger `is not set` lines), **D3** (`CONFIG_MTK_SMART_BATTERY=y`), **D5/D6**
   (power-table clones), **D7** (bct24157 absent), **D15/D16 re-pinned** (`mtk_kpd.h` clone +
   `cust_gpio_usage.h` clone + GPIO2/GPIO14 pin define greps) with the **D22 keymap form**
   (`[0]=KEY_VOLUMEUP, [1]=KEY_VOLUMEDOWN`, absence of the D20 pair), **D17** (fw sha
   `bae204cb…`, `CONFIG_TOUCHSCREEN_MTK_GSL_TP=y`, glue-not-a-clone check), **D18** (LCM list),
   **D19** (mtkfb/dsi guards), **D20** (source constants + compiled precedence gates:
   `hal_kpd.o` `(115,114)`, `kd_camera_hw.o` pin words, `sd.o`/`accdet.o` immediates),
   **D21** (`cust_part_mbr.o` u64 `0x1400000`, `dumchar.o` guard marker, `pmt.o` preset string),
   **D22** (host tests run green — the Phase-A changes do not touch the extracted functions;
   source invariants: staged write helper, batch bound, alive-gate tail, `0x5a`; **rodata
   markers `D22: init failed`/`D22: fw load failed`/`D22: resume init failed` still present**),
   **D24** (5-rail order + `msleep(100)` in `gsl_gpio_init`).
2. **New D25 source invariants** (grep the post-patch tree):
   - `mtk_gslX680.c` contains `\.driver\.name = TPD_DEVICE` and does **not** contain
     `= GSLX680_NAME` as the i2c driver name;
   - `.address_list` absent from `mtk_gslX680.c`;
   - `gsl_dev.sw_inited = 1` present;
   - `gsl_await_chip` + `GSL_CHIP_AWAIT_TRIES` + reg `0xfc` present;
   - `tpd_button_setting(` called in `tpd_local_init`; `{ 172, 158 }` keys table present;
   - `tpd_have_button = 1`;
   - **D23 absence**: `keep-registered`/`D23`/`manual rebind` strings **absent** from
     `mtk_gslX680.c`; `i2c_del_driver(&tpd_i2c_driver)` present on the failure path;
   - `mt_eint_mask` precedes the first `gsl_read_interface` in probe source order.
3. **New compiled gates** on `O=build-beta-touch-lcm-board6`:
   - `mtk_gslX680.o` rodata carries `D25:` markers and **does not** carry the D23 bind-hint
     string;
   - **link-order gate (E9 pinned)**:
     `arm-eabi-nm -n O/vmlinux | grep __initcall6 | grep -E "(tpd_driver_init|mt_i2c_init)"`
     must yield `__initcall_tpd_driver_init6` at a **lower address** than
     `__initcall_mt_i2c_init6` (today `c0c878c8 < c0c87a30` on board5). This is the
     client-instantiation mechanism made explicit and drift-proofed.
4. **δ-parity** extended as in 65 plus: `mtk-tpd` string count increases by
   (i2c driver name + local_init log prints) but must stay > 0 and `gsl_tp`/`gsl1680`/`gsl915`
   counts unchanged (id table + client name still present); no MUST-NOT regressions.

### 5.3 Repack tag

`build/55_repack_boot.sh`: additive case entry
`beta-touch-lcm-board6) ZIMAGE=build-beta-touch-lcm-board6/arch/arm/boot/zImage` (and a
`beta-touch-lcm-board6-dbg` entry **only if a D26 diagnostic image is ever requested**),
producing `out/boot-m1b-beta-touch-lcm-board6.img` + `.sha256`. Header/ramdisk byte-parity
assertions in 55 stay as-is.

### 5.4 Validation ownership

Forge: build + gates only (no flashing). Hera: flash + hardware acceptance (§7). The user:
physical swipe + volume keys.

---

## 6. Risks and fallback

| Risk | Analysis | Mitigation |
|---|---|---|
| Somebody else claims 0x40 first | On our fork exactly one i2c driver matches `gsl_tp` (`TOUCHSCREEN_MTK_GSL_TP=y`; every other panel dir is Kconfig-off, and `mt_devs.c` board tables are commented out) — nothing can race us. The framework's platform driver does not touch i2c. | D25 comment in `tpd_custom_gsl_tp.h`: the MTK convention is `driver.name = TPD_DEVICE` for all panel drivers ⇒ **only one panel CONFIG may ever be enabled**; a second would fail `i2c_add_driver` with `-EBUSY` — the framework would then silently fall to the generic probe (no input device). The D25 source gates lock the current single-driver state. |
| D23 diagnostic leaks into production | D23 (`keep-registered`) is applied only by the frozen stage `64_kernel_delta_diag.sh` → `board4` (a historic diagnostic image, not the release line). | Stage 66 never applies `D23-…patch`; gates assert the D23 strings are **absent** from source and from `mtk_gslX680.o` rodata; parity greps would catch a rogue `gsl_tp` driver-name string count change. |
| Framework falls back to "generic" silently | If `tpd_local_init` returns success without `tpd_load_status==1`, `mtk_tpd.c` prints `cap touch and Generic touch both are not loaded!!` and registers **no input device** — boot looks fine, touch absent. | `tpd_load_status` is only set on a controller-confirmed alive gate (D22 semantics kept); failure ⇒ `i2c_del_driver` + `-1` (blob E2). Validation step must check `/proc/bus/input/devices` rather than boot health. |
| Rename side effects in userspace | The sysfs path `/sys/bus/i2c/drivers/gsl_tp` becomes `…/mtk-tpd`; the D23-era manual rebind command changes accordingly. SELinux is permissive on this boot image (`bootopt…androidboot.selinux=permissive`), and no shipped userspace references the i2c driver name (HAL talks to `/dev/input` + `/proc/gsl_config`). | No code action; document in the D25 patch prologue. |
| `input_set_abs_params` removal risk | The framework never sets an ABS_MT_TRACKING_ID *range*; our local_init's range set is a deliberate retained deviation (§3) — removing it could clamp MT-B ids in some input-core paths. | keep as-is; noted in the mapping table. |
| Build determinism | D25 adds one patch; stage mirrors 65's reset/whitelist/mtime discipline; O-dir `build-beta-touch-lcm-board6` must be `mkdir -p`ed before `O=` first use (the 50/60/61/65 pattern). | carried verbatim in 66. |
| D25 lands but hardware still NAKs | P1–P5 removed; H-SEQ/H-KERN/H-STATE remain → follow §4.3. | **D26 diagnostic (never ships):** new patch `D26-tpd-diag` (apply on 66: `gsl_await_chip` retry count raised + per-attempt reg/gpio/ldo prints + `i2c_common.c` `ut` dump hook call before the gate + optional Phase-B transport shape swap) built by `67_kernel_delta_tpd_diag.sh` into `build-beta-touch-lcm-board6-dbg` + `boot-m1b-beta-touch-lcm-board6-dbg.img`, only ever flashed on explicit instruction. Decision data expected: which H survives. |
| Rollback | Stock Lithium boot image is known-good and pinned. | `out/boot-m1b-lithium-ctl.img` (`boot-m1b-lithium-ctl.img.sha256`) and the frozen `boot-m1b-beta-touch-lcm-board5.img` (pre-D25 reference) both stay pinned; Hera flashes stock `boot-m1b-lithium-ctl.img` to restore. System/ramdisk untouched by all of this (kernel-only delta). |
| Single points of failure | Panel/gsl chip; PMIC rails; the single `mtk-tpd` i2c name slot. | The i2c core soft-resets the controller after every error (`i2c.c:545–565`); our probe is bounded and unregisters on failure; `/proc/gsl_config` remains for live re-init (`st`/`en` commands). |

---

## 7. Validation baseline (for Karen — expand as needed)

**Hardware acceptance (Hera + user, from the task, unchanged):**

1. `for f in /sys/bus/i2c/devices/*/driver; do echo "$(basename $(dirname $f)) -> $(basename $f | xargs readlink)" …` — **`0-0040` bound to `mtk-tpd`** on our fork.
2. `/proc/bus/input/devices` lists **`mtk-tpd`** *and* **`mtk-tpd-kpd`**.
3. Physical swipe produces coordinates: `adb shell -tt getevent -lt` (**never** without `-tt`).
4. Volume keys still VOLUMEUP/VOLUMEDOWN correctly; boot, display, charging, audio unchanged.

**Probe-path observations (dmesg, collected with the debug-cmdline image if needed):**

5. Sequence markers in order: 5-rail power logs (or silence + rails ON in
   `dump_ldo_status`), `mtk-tpd` framework probe, `gsl_await_chip` success (no log = first
   try), `gsl_test_i2c`/canary/fingerprint stage, `------GSLX680_FW_*------` banner, `D22:`/`D25:`
   failures absent, `tpd_load_status` readable as `1` via
   `/sys/module/tpd_setting/parameters/tpd_load_status`.
6. **Negative expectations:** no `[mt-i2c]ERROR 548: I2C_ACKERR` for address 0x40 on bus 0
   after probe; no `cap touch and Generic touch both are not loaded!!`; no `D23`/`manual
   rebind` strings anywhere in `dmesg`.

**Edge cases & failure scenarios:**

7. Touch probe fails ⇒ no `mtk-tpd` input device AND `/sys/bus/i2c/drivers/mtk-tpd` absent
   (i2c_del_driver ran); system boots normally otherwise.
8. Suspend/resume: `mtk-tpd` events stop/resume across display blank/unblank (earlysuspend
   hooks; D22 resume logs `D22: resume init failed` on a dead chip — acceptable log only).
9. `/proc/gsl_config` present after successful probe; `st`/`en` commands still bounded-guarded.
10. Both virtual keys registered (172/158 visible in the kpd input device's keybit set).
11. Regression sweep: charging SOC climbs (D4/D14), display works (D18/D19), all other i2c
    clients unchanged (camera `0-005a/0-005d` enumerate as before, amp on bus 2 undisturbed),
    MBR/pmt behavior intact (D21), volume keymap bytes (D22).

**Performance expectations (unchanged contract):** probe completes within the existing bounded
delays (≈100 ms settle + ≤5×0xfc gate + init cascade ≈ blob timing); no new watchdog/timeout
paths; no unbounded retries anywhere.

**Security expectations:** no new device nodes or sysfs modes (existing `/proc/gsl_config`
perms unchanged); no kernel-commandline changes; selinux state untouched (permissive build).

**Build/CI expectations:** all §5.2 gates green; zImage sha256 recorded in the stage output;
55 header/ramdisk byte-parity PASS; repeated 66 runs reproduce the identical zImage.

---

## 8. Milestones (implementation order for Forge)

| # | Milestone | Artifact | Acceptance |
|---|---|---|---|
| M1 | D25 patch authored (§5.1, file order a→h) | `patches/kernel/D25-tpd-framework-integration.patch` | applies cleanly on the D24-chain snapshot; every §5.2-2 source grep passes |
| M2 | Stage 66 authored with carried + new gates | `build/66_kernel_delta_tpd.sh` | full stage run: host tests PASS, all D1–D24 invariants plus D25 gates green, zImage sha logged, fresh-O-dir rerun reproduces byte-identically |
| M3 | Repack tag + image | `55_repack_boot.sh` board6 entry; `out/boot-m1b-beta-touch-lcm-board6.img(+.sha256)` | 55 header/ramdisk parity PASS; image sha recorded |
| M4 | Hand-off | report in the established report-file pattern | no flashing performed; board5/stock pins verified untouched |

---

## 9. ADR record (condensed)

* **ADR-1 — converge on the blob-verbatim integration rather than a bespoke framework client.**
  Alternatives: keep the standalone-shaped port (refuted by P1–P4 + acceptance), rewrite
  `mtk_tpd.c` (massive churn, no evidence of a framework-side mechanism — §2.1), device-tree
  instantiation (this 3.10.54 tree has no DT for touch on this platform). Decision rationale:
  the blob is the only implementation ever observed ACKing this panel/electricals; every
  statically-known deviation must disappear. Consequences: high source fidelity, small patch.
* **ADR-2 — i2c driver renamed to `TPD_DEVICE`.** Proven by struct decode (E1); required by
  acceptance; consequences: sysfs path change (§6), single-panel-config convention enforced.
* **ADR-3 — Phase A (identity+sequence+buttons+guard) ships; Phase B (blob read-chunk/master_send
  transport shape) deferred.** Rationale: reads are wire-equivalent for every touched register
  (§3, §4.1); Phase B is only reachable via H-discrimination and must not churn the D22-tested
  transport before hardware evidence demands it.
* **ADR-4 — keep module_init board-info registration + nm link-order gate.** Alternative
  (mach-level registration, the blob's E12 way) rejected: bigger blast radius, D17 precedent is
  proven live on hardware; the nm gate (§5.2-3) makes the dependency drift-proof.
* **ADR-5 — D23 excluded from the production chain; diagnostic capability re-created, only on
  demand (D26), with a separate stage/O-dir/tag.** Same discipline as 64/board4.

---

## 10. Open items for Hermes/Hera

1. Root cause of the live ACKERR remains hypothesis-grade (§4.3) — the discriminator is the D26
   diagnostic run **only if** D25 fails on hardware. Do not record any §4.3 cause as fact.
2. If D25 succeeds on hardware, D23/D24's diagnostic images (`board4`, and board5 as a frozen
   reference) must never be flashed forward again.
3. Future note: if a second touch panel is ever enabled, the shared `mtk-tpd` i2c driver name
   becomes a real conflict (§6 row 1).

Design complete.
