/*
 * D22 host test — the OLD (pre-D22) firmware loader + old write helper,
 * actual source extracted from the pre-patch mtk_gslX680.c (the D17 state)
 * by run.sh, driven with the REAL extracted GSL_TP_CHECK_FW array.
 *
 * Reproduces the hera-d22 diagnosis §2 isolated ASAN proof: the old loader
 * flushes only when u8 send_flag wraps (≈256 records) into buf[129] — the
 * 33rd record of every page (the page selector right after a full 32-record
 * data run) memcpy's past the buffer end.
 *
 * Expected result: ABORT under ASAN with a stack-buffer-overflow WRITE.
 * run.sh asserts the non-zero exit + the ASAN report.
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint8_t u8;
typedef uint32_t u32;
#define I2C_MASK_FLAG 0x00ff
#define I2C_ENEXT_FLAG 0x0000
#define I2C_M_TEN 0x0010
struct i2c_client { int addr; unsigned short flags; void *adapter; };
struct i2c_msg { unsigned short addr; unsigned short flags; unsigned short len; u8 *buf; int timing; };

static int i2c_transfer(void *adapter, struct i2c_msg *m, int n)
{
	/* minimal sink: the old loader's damage is the WRITE side, which ASAN
	 * catches before/during this stub — no consumption needed */
	(void)adapter; (void)m; (void)n;
	return n;
}

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
/* the old loader's constants, exactly as the pre-D22 source defines them */
#define DMA_TRANS_LEN 0x20
#define GSL_PAGE_REG 0xf0
struct fw_data { unsigned int offset; unsigned int val; };

#include "x-old-write.c"
#include "x-old-load.c"
#include <x-real-fw-check.h>

int main(void)
{
	struct i2c_client c = { .addr = 0x40 };
	printf("old loader vs REAL GSL_TP_CHECK_FW (%u records)...\n",
	       (unsigned)(sizeof(GSL_TP_CHECK_FW) / sizeof(GSL_TP_CHECK_FW[0])));
	gsl_load_fw(&c, GSL_TP_CHECK_FW,
		    (u32)(sizeof(GSL_TP_CHECK_FW) / sizeof(GSL_TP_CHECK_FW[0])));
	printf("old loader returned (never reaches here under ASAN)\n");
	return 0;
}
