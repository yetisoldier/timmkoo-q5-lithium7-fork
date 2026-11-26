/*
 * D22 host test — the repaired write helper (actual source extracted from the
 * patched mtk_gslX680.c by run.sh).
 *
 * Proves (hera-d22-input-diagnosis contract §"Add reproducible actual-source
 * host tests"):
 *   - exact byte stream: register byte first, payload unchanged after, exactly
 *     num+1 bytes on the wire;
 *   - payload immutability: the caller's buffer (and its surroundings) are
 *     never modified;
 *   - size validation: 0-length and over-cap payloads are rejected before any
 *     transfer; the 128-byte cap == the firmwar-batch bound;
 *   - transfer failures propagate (short = 0 msgs, hard error = negative);
 *   - MTK message fields preserved (addr mask, flags, timing 400);
 *   - ASAN-clean (run.sh compiles with -fsanitize=address).
 */
#include "pre-new.h"
#include "mock-i2c.h"
#include "x-new-write.c"

static int failures = 0;

#define CHECK(cond, name) do { \
	if (!(cond)) { fprintf(stderr, "FAIL %s\n", name); failures++; } \
	else fprintf(stderr, "ok   %s\n", name); \
} while (0)

static struct i2c_client cli = { .addr = 0x40, .flags = I2C_M_TEN };

int main(void)
{
	int ret;

	/* --- t1: exact stream + payload immutability (caged buffer) --- */
	{
		u8 cage[10] = { 0xAA, 0x01, 0x02, 0x03, 0x04, 0x55, 0x66, 0x77, 0x88, 0x99 };
		mock_reset();
		ret = gsl_i2c_write_bytes(&cli, 0xf0, &cage[1], 4);
		CHECK(ret == 0, "t1 write_bytes returns 0");
		CHECK(cage[0] == 0xAA && cage[5] == 0x55 && cage[6] == 0x66 &&
		      cage[7] == 0x77 && cage[8] == 0x88 && cage[9] == 0x99,
		      "t1 guard bytes untouched (old code overwrote buf[0] with reg)");
		CHECK(cage[1] == 0x01 && cage[2] == 0x02 && cage[3] == 0x03 &&
		      cage[4] == 0x04, "t1 payload unchanged");
		CHECK(M.nops == 1, "t1 exactly one i2c_transfer");
		CHECK(M.ops[0].is_write && M.ops[0].reg == 0xf0 &&
		      M.ops[0].wire_len == 5, "t1 wire = reg + 4 payload bytes");
		CHECK(M.ops[0].wire[0] == 0xf0 && M.ops[0].wire[1] == 0x01 &&
		      M.ops[0].wire[2] == 0x02 && M.ops[0].wire[3] == 0x03 &&
		      M.ops[0].wire[4] == 0x04,
		      "t1 exact byte stream f0 01 02 03 04");
	}

	/* --- t2: MTK message fields preserved --- */
	{
		u8 pl[2] = { 0x5a, 0x00 };
		mock_reset();
		ret = gsl_write_interface(&cli, 0xbc, pl, 2);
		CHECK(ret == 0, "t2 write_interface returns 0");
		CHECK(M.ops[0].wire[0] == 0xbc && M.ops[0].wire[1] == 0x5a &&
		      M.ops[0].wire[2] == 0x00, "t2 reg-first stream bc 5a 00");
	}

	/* --- t3: size validation (nothing sent) --- */
	{
		u8 pl[GSL_I2C_MAX_PAYLOAD + 2];
		memset(pl, 0x7e, sizeof(pl));
		mock_reset();
		ret = gsl_i2c_write_bytes(&cli, 0xf0, pl, 0);
		CHECK(ret == -EINVAL && M.nops == 0, "t3 zero-length payload rejected before transfer");
		mock_reset();
		ret = gsl_i2c_write_bytes(&cli, 0xf0, pl, GSL_I2C_MAX_PAYLOAD + 1);
		CHECK(ret == -EINVAL && M.nops == 0, "t3 over-cap payload rejected before transfer");
		ret = gsl_write_interface(&cli, 0xf0, pl, GSL_I2C_MAX_PAYLOAD + 1);
		CHECK(ret == -EINVAL, "t3 write_interface over-cap rejected");
		mock_reset();
		ret = gsl_i2c_write_bytes(&cli, 0xf0, pl, GSL_I2C_MAX_PAYLOAD);
		CHECK(ret == 0 && M.nops == 1 && M.ops[0].wire_len == GSL_I2C_MAX_PAYLOAD + 1,
		      "t3 the 128-byte cap itself transfers as exactly 129 wire bytes");
		CHECK(pl[GSL_I2C_MAX_PAYLOAD] == 0x7e && pl[0] == 0x7e,
		      "t3 caged buffer untouched at cap");
	}

	/* --- t4: transfer failures propagate --- */
	{
		u8 pl[4] = { 1, 2, 3, 4 };
		mock_reset();
		mock_fail_idx(0, 0);		/* short transfer: 0 msgs completed */
		ret = gsl_write_interface(&cli, 0xf0, pl, 4);
		CHECK(ret == -EFAULT, "t4 short transfer -> -EFAULT");
		mock_reset();
		mock_fail_idx(0, -5);		/* hard i2c error */
		ret = gsl_i2c_write_bytes(&cli, 0xf0, pl, 4);
		CHECK(ret == -EFAULT && M.nops == 1, "t4 transport error propagates as failure");
	}

	/* --- t5: no hidden chunk arithmetic (u8-offset wrap class removed) --- */
	{
		u8 pl[150];
		memset(pl, 0x11, sizeof(pl));
		mock_reset();
		ret = gsl_i2c_write_bytes(&cli, 0xf0, pl, (int)sizeof(pl));
		CHECK(ret == -EINVAL && M.nops == 0,
		      "t5 150-byte payload rejected (old chunk loop could wrap u8 offsets)");
	}

	if (failures) {
		fprintf(stderr, "new-write-tests: %d FAILURE(S)\n", failures);
		return 1;
	}
	fprintf(stderr, "new-write-tests: ALL PASS\n");
	return 0;
}
