/*
 * D22 host test — the repaired init path (actual source extracted from the
 * patched mtk_gslX680.c by run.sh): check_mem_data, gsl_sw_init, the chip
 * helpers and the bounded alive gate.
 *
 * Proves (hera-d22-input-diagnosis contract):
 *   - init failure does NOT report success (transport errors, dead signature,
 *     firmware-load failures all return non-zero — the probe binds only on a
 *     confirmed reg 0xb0 == 0x5a);
 *   - success path runs the REAL vendor sequence: canary load → fingerprint
 *     read → selected-config load → start → alive confirmation;
 *   - the alive gate is bounded (exactly GSL_FW_ALIVE_TRIES reads) and
 *     transport failures surface directly;
 *   - ASAN-clean.
 */
#include "pre-new.h"
#include "mock-i2c.h"
#include "x-new-spana.c"
#include "x-new-swinit.c"

static int failures = 0;

#define CHECK(cond, name) do { \
	if (!(cond)) { fprintf(stderr, "FAIL %s\n", name); failures++; } \
	else fprintf(stderr, "ok   %s\n", name); \
} while (0)

static struct i2c_client cli = { .addr = 0x40, .flags = I2C_M_TEN };

/* the driver's config state persists per boot on the real device (that is
 * correct vendor behaviour); each harness scenario starts from a fresh chip
 * state, so reset it like the driver's own cold boot */
static void sw_fresh(void)
{
	memset(&gsl_dev, 0, sizeof(gsl_dev));
}

/* count 0xb0 reads that happen AFTER the last write (the post-load alive
 * gate), excluding the initial probe read of check_mem_data */
static int count_alive_reads(void)
{
	int last_write = -1;
	int i;
	int n = 0;
	for (i = M.nops - 1; i >= 0; i--)
		if (M.ops[i].is_write) { last_write = i; break; }
	for (i = last_write + 1; i < M.nops; i++)
		if (!M.ops[i].is_write && M.ops[i].reg == 0xb0)
			n++;
	return n;
}

/* fingerprint chosen to match gsl_fp_table[2] (0xff807807) -> config id 3 ->
 * cascade picks config 2 (WL). Any deterministic choice works; the point is
 * that the selected config's bytes stream through the same load_fw. */
static void preset_fingerprint(u32 fp)
{
	M.mem[0xb8] = fp & 0xff;
	M.mem[0xb9] = (fp >> 8) & 0xff;
	M.mem[0xba] = (fp >> 16) & 0xff;
	M.mem[0xbb] = (fp >> 24) & 0xff;
}
static void preset_alive(void)
{
	M.mem[0xb0] = 0x5a;	/* the vendor's fw-alive signature */
}
static void preset_canary_answer(void)
{
	M.mem[0xb6] = 0x02;	/* reg 0xb4: (buf[2] | buf[3]<<8) == 2 > 1 */
}

static int count_ops(int is_write, int reg, int min_wire, int max_wire)
{
	int n = 0;
	int i;
	for (i = 0; i < M.nops; i++) {
		if (M.ops[i].is_write != is_write || M.ops[i].reg != reg)
			continue;
		if (min_wire >= 0 && (M.ops[i].wire_len < min_wire || M.ops[i].wire_len > max_wire))
			continue;
		n++;
	}
	return n;
}

int main(void)
{
	int ret;

	/* --- s1: warm chip (signature already alive) binds immediately --- */
	mock_reset();
	sw_fresh();
	preset_alive();
	ret = check_mem_data(&cli);
	CHECK(ret == 0, "s1 alive signature -> init returns 0");
	CHECK(M.nops == 1, "s1 exactly one read, no sw_init rerun");

	/* --- s2: cold start — full vendor flow, real canary + config load --- */
	mock_reset();
	sw_fresh();
	M.sim_boot = 1;
	preset_fingerprint(0xff807807);
	preset_canary_answer();
	ret = check_mem_data(&cli);
	CHECK(ret == 0, "s2 cold-start init returns 0 ONLY after alive confirmation");
	CHECK(M.nops > 100, "s2 the canary + selected-config firmwares streamed");
	CHECK(count_ops(1, 0xf0, 5, 5) > 29 + 29,
	      "s2 page-selector writes for canary + selected config (+io_control pages)");
	CHECK(count_ops(1, 0x00, 129, 129) > 0,
	      "s2 full 128-byte data batches present (wire 129B, CHECK_FW is page-aligned)");
	/* the last write before the alive reads must be the 4-zero start core
	 * write (0xe0, wire = 1+4) */
	{
		int last_wr = -1;
		int i;
		for (i = M.nops - 1; i >= 0; i--)
			if (M.ops[i].is_write) { last_wr = i; break; }
		CHECK(M.ops[last_wr].reg == 0xe0 && M.ops[last_wr].wire_len == 5 &&
		      M.ops[last_wr].wire[1] == 0 && M.ops[last_wr].wire[4] == 0,
		      "s2 init ends with the vendor start-core write");
	}
	CHECK(count_ops(0, 0xb0, 0, 0) >= 1, "s2 the alive gate read reg 0xb0");

	/* --- s3: dead-signature chip must NOT report success --- */
	mock_reset();
	sw_fresh();
	M.sim_boot = 0;	/* start writes do not boot the mock firmware */
	preset_fingerprint(0xff807807);
	preset_canary_answer();
	ret = check_mem_data(&cli);
	CHECK(ret == -EIO, "s3 dead-signature chip fails the bounded alive gate (-EIO)");

	/* --- s4: transport error on ANY stage write fails the init --- */
	mock_reset();
	sw_fresh();
	M.sim_boot = 1;
	preset_fingerprint(0xff807807);
	preset_canary_answer();
	M.fail_wr_0xbc_after = 1;	/* fail the 2nd reset-core (the selected-config stage) */
	ret = check_mem_data(&cli);
	CHECK(ret != 0, "s4 firmware-stage transport failure does NOT report success");
	CHECK(M.nops > 30, "s4 the canary stage still ran before the failure");

	/* --- s5: alive gate is bounded (exactly GSL_FW_ALIVE_TRIES reads) --- */
	/* replay s3's run and count the post-load alive reads only */
	mock_reset();
	sw_fresh();
	M.sim_boot = 0;
	preset_fingerprint(0xff807807);
	preset_canary_answer();
	ret = check_mem_data(&cli);
	CHECK(ret == -EIO && count_alive_reads() == GSL_FW_ALIVE_TRIES,
	      "s5 alive gate reads exactly GSL_FW_ALIVE_TRIES times post-load, then -EIO");

	/* --- s6: warm-alive shortcut does not even call the loader --- */
	mock_reset();
	sw_fresh();
	preset_alive();
	ret = check_mem_data(&cli);
	CHECK(ret == 0 && M.nops == 1 && count_ops(1, 0xf0, 5, 5) == 0,
	      "s6 alive chip: no firmware reload before binding");

	/* --- s7: fingerprint read failure propagates --- */
	{
		int idx = -1;
		int i;
		mock_reset();
		sw_fresh();
		M.sim_boot = 1;
		preset_fingerprint(0xff807807);
		preset_canary_answer();
		/* find the index pattern first from a clean run, then fail the
		 * fingerprint read (0xb8) by index — the op sequence up to and
		 * incl. the 0xb8 read is deterministic */
		ret = check_mem_data(&cli);
		CHECK(ret == 0, "s7 setup: clean run passes");
		for (i = M.nops - 1; i >= 0; i--)
			if (!M.ops[i].is_write && M.ops[i].reg == 0xb8) { idx = i; break; }
		CHECK(idx > 0, "s7 setup: fingerprint read present");
		mock_reset();
		sw_fresh();
		M.sim_boot = 1;
		preset_fingerprint(0xff807807);
		preset_canary_answer();
		mock_fail_idx(idx, -5);
		ret = check_mem_data(&cli);
		CHECK(ret != 0, "s7 fingerprint-read transport failure does NOT report success");
	}

	if (failures) {
		fprintf(stderr, "new-init-tests: %d FAILURE(S)\n", failures);
		return 1;
	}
	fprintf(stderr, "new-init-tests: ALL PASS\n");
	return 0;
}
