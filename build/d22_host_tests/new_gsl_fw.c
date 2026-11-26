/*
 * D22 host test — the repaired firmware loader (actual source extracted from
 * the patched mtk_gslX680.c by run.sh) driven over EVERY extracted Q5
 * firmware array plus synthetic edge arrays.
 *
 * Proves (hera-d22-input-diagnosis contract):
 *   - every record of every real Q5 array is emitted EXACTLY once, in order,
 *     encoded as page/data transfers (reconstruction == input array);
 *   - page writes are exactly reg 0xf0 + 4 payload bytes, values explicit
 *     little-endian;
 *   - batches are bounded at 128 payload bytes (129 wire) — the old loader's
 *     stack smash shape (buf[129] overrun, ASAN proof) cannot occur;
 *   - final partial batch flushes (the real arrays end exactly on a full
 *     batch, so synthetic arrays cover the partial/discontinuity paths);
 *   - injected short/negative transport returns propagate as failures,
 *     including a failure of the final partial batch;
 *   - ASAN-clean.
 */
#include "pre-new.h"
#include "mock-i2c.h"
#include "x-new-spana.c"

/* this harness exercises the loader, not the full init path (see
 * new_gsl_init.c); satisfy check_mem_data's reference with an inert stub */
static int gsl_sw_init(struct i2c_client *client) { (void)client; return 0; }

static int failures = 0;

#define CHECK(cond, name) do { \
	if (!(cond)) { fprintf(stderr, "FAIL %s\n", name); failures++; } \
	else fprintf(stderr, "ok   %s\n", name); \
} while (0)

struct rec { u32 offset; u32 val; };

static struct i2c_client cli = { .addr = 0x40, .flags = I2C_M_TEN };

/* decode the mock's on-wire log back into {register,LE32-value} records */
static int reconstruct(struct rec *out, int cap)
{
	int n = 0;
	int i;
	int k;

	for (i = 0; i < M.nops; i++) {
		const struct i2c_op *op = &M.ops[i];
		if (!op->is_write)
			continue;	/* reads only happen in the init test */
		if (op->reg == 0xf0) {
			if (n >= cap)
				return -1;
			if (op->wire_len != 5)
				return -2;
			out[n].offset = 0xf0;
			out[n].val = (u32)op->wire[1] | ((u32)op->wire[2] << 8) |
				     ((u32)op->wire[3] << 16) | ((u32)op->wire[4] << 24);
			n++;
			continue;
		}
		if ((op->wire_len - 1) % 4 != 0)
			return -3;
		for (k = 0; k * 4 < op->wire_len - 1; k++) {
			const u8 *w = &op->wire[1 + k * 4];
			if (n >= cap)
				return -1;
			out[n].offset = (u32)(op->reg + 4 * k);
			out[n].val = (u32)w[0] | ((u32)w[1] << 8) |
				     ((u32)w[2] << 16) | ((u32)w[3] << 24);
			n++;
		}
	}
	return n;
}

/* drive one array through the loader and verify record-exact emission */
static int check_array(const struct fw_data *fw, u32 count, const char *name)
{
	struct rec *got;
	int n;
	int i;
	int bad = 0;

	mock_reset();
	if (gsl_load_fw(&cli, fw, count) != 0) {
		fprintf(stderr, "FAIL %s: load_fw returned error\n", name);
		return 1;
	}
	got = malloc(sizeof(*got) * (count + 1));
	if (!got)
		return 1;
	n = reconstruct(got, count + 1);
	if (n != (int)count) {
		fprintf(stderr, "FAIL %s: reconstructed %d records, want %u (err %d)\n",
			name, n, count, n);
		free(got);
		return 1;
	}
	for (i = 0; i < (int)count; i++) {
		if (got[i].offset != fw[i].offset || got[i].val != fw[i].val) {
			fprintf(stderr, "FAIL %s: record %d got {0x%x,0x%08x} want {0x%x,0x%08x}\n",
				name, i, got[i].offset, got[i].val, fw[i].offset, fw[i].val);
			bad = 1;
			break;
		}
	}
	/* batch bound: every transfer's payload ≤ 128 bytes (wire ≤ 129);
	 * page writes exactly 4 payload bytes; values little-endian (the
	 * reconstruction equality above IS the LE proof) */
	for (i = 0; i < M.nops; i++) {
		int pl = M.ops[i].wire_len - 1;
		if (!M.ops[i].is_write)
			continue;
		if (M.ops[i].reg == 0xf0 && pl != 4)
			bad = 1;
		if (pl < 1 || pl > 128)
			bad = 1;
	}
	if (bad)
		fprintf(stderr, "FAIL %s: batch/page encoding violated\n", name);
	else
		fprintf(stderr, "ok   %s: %u records emitted exactly (%d transfers)\n",
			name, count, M.nops);
	free(got);
	return bad;
}

/* synthetic arrays for the paths the real (page-aligned) arrays never hit */
static const struct fw_data syn_discontinuity[] = {
	{0xf0, 0x00000001},
	{0x00, 0x11223344}, {0x04, 0x55667788},
	{0x10, 0x99aabbcc}, {0x14, 0xddeeff01},	/* register gap 0x04->0x10 */
	{0xf0, 0x00000002},
	{0x40, 0x12345678}, {0x44, 0x9abcdef0},	/* trailing partial batch */
};
static const struct fw_data syn_full_batch_overflow[] = {
	{0xf0, 0x00000001},
	/* 33 contiguous data records: forces the 128-byte cap mid-page */
	{0x00, 0}, {0x04, 1}, {0x08, 2}, {0x0c, 3}, {0x10, 4}, {0x14, 5},
	{0x18, 6}, {0x1c, 7}, {0x20, 8}, {0x24, 9}, {0x28, 10}, {0x2c, 11},
	{0x30, 12}, {0x34, 13}, {0x38, 14}, {0x3c, 15}, {0x40, 16}, {0x44, 17},
	{0x48, 18}, {0x4c, 19}, {0x50, 20}, {0x54, 21}, {0x58, 22}, {0x5c, 23},
	{0x60, 24}, {0x64, 25}, {0x68, 26}, {0x6c, 27}, {0x70, 28}, {0x74, 29},
	{0x78, 30}, {0x7c, 31}, {0x80, 32},
};
static const struct fw_data syn_partial_only[] = {
	{0xf0, 0x00000009},
	{0x00, 0x040b0e42}, {0x04, 0xf801000f},	/* final batch = 2 records */
};

int main(void)
{
	int ret;
	int i;
	int opidx;

	/* 1. every real extracted Q5 array must emit exactly its records */
	CHECK(check_array(GSL_TP_CHECK_FW, ARRAY_SIZE(GSL_TP_CHECK_FW), "GSL_TP_CHECK_FW") == 0,
	      "real-array GSL_TP_CHECK_FW");
	CHECK(check_array(gsl_fw_hw, ARRAY_SIZE(gsl_fw_hw), "gsl_fw_hw") == 0, "real-array gsl_fw_hw");
	CHECK(check_array(gsl_fw_dsj, ARRAY_SIZE(gsl_fw_dsj), "gsl_fw_dsj") == 0, "real-array gsl_fw_dsj");
	CHECK(check_array(gsl_fw_wl, ARRAY_SIZE(gsl_fw_wl), "gsl_fw_wl") == 0, "real-array gsl_fw_wl");
	CHECK(check_array(gsl_fw_cfg5, ARRAY_SIZE(gsl_fw_cfg5), "gsl_fw_cfg5") == 0, "real-array gsl_fw_cfg5");
	CHECK(check_array(gsl_fw_jx2, ARRAY_SIZE(gsl_fw_jx2), "gsl_fw_jx2") == 0, "real-array gsl_fw_jx2");

	/* 2. explicit little-endian byte order on a known record:
	 * gsl_fw_hw page 1 carries {0x64, 0xf801000f} -> the first 128-byte
	 * batch (reg 0x00, wire 129) must hold bytes 0f 00 01 f8 at record
	 * slot 0x64/4 = 25 (wire offsets 101..104) */
	mock_reset();
	gsl_load_fw(&cli, gsl_fw_hw, ARRAY_SIZE(gsl_fw_hw));
	opidx = -1;
	for (i = 0; i < M.nops; i++)
		if (M.ops[i].is_write && M.ops[i].reg == 0x00 && M.ops[i].wire_len == 129)
			{ opidx = i; break; }
	CHECK(opidx >= 0, "known batch (reg 0x00, 129 wire bytes) present");
	CHECK(opidx >= 0 && M.ops[opidx].wire[101] == 0x0f && M.ops[opidx].wire[102] == 0x00 &&
	      M.ops[opidx].wire[103] == 0x01 && M.ops[opidx].wire[104] == 0xf8,
	      "value 0xf801000f at reg 0x64 is explicit little-endian on the wire");

	/* 3. register discontinuity inside a page + trailing partial batch */
	CHECK(check_array(syn_discontinuity, ARRAY_SIZE(syn_discontinuity),
			  "syn-discontinuity") == 0, "synthetic discontinuity + partial end");
	/* the discontinuity must have broken the batch BEFORE 0x10 */
	mock_reset();
	gsl_load_fw(&cli, syn_discontinuity, ARRAY_SIZE(syn_discontinuity));
	CHECK(M.nops == 5, "syn-discontinuity 5 transfers (page, batch, batch, page, batch)");
	CHECK(M.ops[1].reg == 0x00 && M.ops[1].wire_len == 1 + 2 * 4,
	      "flush at register discontinuity (batch 0x00..0x04 only)");
	CHECK(M.ops[2].reg == 0x10 && M.ops[2].wire_len == 1 + 2 * 4,
	      "new batch starts at the disjoint register");
	CHECK(M.ops[4].reg == 0x40 && M.ops[4].wire_len == 1 + 2 * 4,
	      "final partial batch flushed at end of array");

	/* 4. full-batch cap: 33 contiguous records -> 128-byte batch + 4-byte tail */
	CHECK(check_array(syn_full_batch_overflow, ARRAY_SIZE(syn_full_batch_overflow),
			  "syn-full-batch-cap") == 0, "synthetic full-batch cap");
	mock_reset();
	gsl_load_fw(&cli, syn_full_batch_overflow, ARRAY_SIZE(syn_full_batch_overflow));
	CHECK(M.nops == 3, "full-batch overflow -> 3 transfers");
	CHECK(M.ops[1].wire_len == 129, "first batch is exactly 128 payload bytes (129 wire)");
	CHECK(M.ops[1].reg == 0x00 && M.ops[2].reg == 0x80 && M.ops[2].wire_len == 5,
	      "overflow record starts its own batch at 0x80");

	/* 5. injected failures propagate (short + negative), incl. final batch */
	{
		mock_reset();
		mock_fail_idx(0, -5);
		ret = gsl_load_fw(&cli, syn_partial_only, ARRAY_SIZE(syn_partial_only));
		CHECK(ret != 0, "page-selector write failure propagates");

		mock_reset();
		mock_fail_idx(1, 0);	/* short return on the data batch */
		ret = gsl_load_fw(&cli, syn_partial_only, ARRAY_SIZE(syn_partial_only));
		CHECK(ret != 0, "data-batch short transfer propagates");

		mock_reset();
		mock_fail_idx(1, -5);
		ret = gsl_load_fw(&cli, syn_partial_only, ARRAY_SIZE(syn_partial_only));
		CHECK(ret != 0, "FINAL PARTIAL BATCH transport failure propagates");
	}

	/* 6. the firmware array itself is never mutated (const payload contract) */
	{
		u32 snapshot[2 * ARRAY_SIZE(syn_partial_only)];
		memcpy(snapshot, syn_partial_only, sizeof(snapshot));
		mock_reset();
		gsl_load_fw(&cli, syn_partial_only, ARRAY_SIZE(syn_partial_only));
		CHECK(memcmp(snapshot, syn_partial_only, sizeof(snapshot)) == 0,
		      "fw array bits unchanged by the loader");
	}

	if (failures) {
		fprintf(stderr, "new-fw-tests: %d FAILURE(S)\n", failures);
		return 1;
	}
	fprintf(stderr, "new-fw-tests: ALL PASS\n");
	return 0;
}
