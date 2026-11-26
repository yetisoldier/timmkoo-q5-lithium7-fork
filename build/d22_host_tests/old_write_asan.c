/*
 * D22 host test — the OLD (pre-D22) write helper, actual source extracted
 * from the pre-patch mtk_gslX680.c (the D17 state) by run.sh.
 *
 * Reproduces the hera-d22 diagnosis §1 isolated ASAN proof: the old helper
 * takes a payload-only buffer, overwrites buf[0] with the register and
 * declares a transfer of num+1 bytes — the consuming stub below (like the
 * real i2c core walking msg->len) reads ONE BYTE PAST the caller's buffer.
 *
 * Expected result: ABORT under ASAN with a stack-buffer-overflow READ.
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

/* consuming stub: walks exactly len bytes of the message buffer — what a
 * real i2c core/DMA path would copy (this is the memory consumption that
 * makes the OOB READ observable instead of dead-code) */
static int i2c_transfer(void *adapter, struct i2c_msg *m, int n)
{
	volatile unsigned sum = 0;
	int j;
	(void)adapter;
	for (j = 0; j < n; j++) {
		int k;
		for (k = 0; k < m[j].len; k++)
			sum += m[j].buf[k];
	}
	printf("stub: consumed %d msg len=%d sum=%u\n", n, m[0].len, sum);
	return n;
}

#include "x-old-write.c"

int main(void)
{
	struct i2c_client c = { .addr = 0x40, .flags = I2C_M_TEN };
	u8 payload[4] = { 0x01, 0x02, 0x03, 0x04 };
	u32 ret = gsl_write_interface(&c, 0xf0, payload, 4);
	printf("old write helper returned %u (payload byte0 now 0x%02x — overwritten)\n",
	       ret, payload[0]);
	return 0;
}
