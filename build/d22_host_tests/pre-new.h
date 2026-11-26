/*
 * hera-d22 host-test preamble (new-source side).
 *
 * Kernel API shims sufficient to compile the EXACT function text extracted
 * from the D22-patched mtk_gslX680.c (see build/d22_host_tests/run.sh for the
 * extraction markers). The repair logic must not depend on any of these:
 * they are inert stand-ins so the real driver code runs unmodified on the
 * host under ASAN (hera-d22-input-diagnosis: "exercise REAL functions rather
 * than copying formulas").
 */
#ifndef _D22_PRE_NEW_H_
#define _D22_PRE_NEW_H_

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef int32_t s32;

/* MTK i2c flag vocabulary must match what the extracted text uses */
#define I2C_MASK_FLAG	0x00ff
#define I2C_ENEXT_FLAG	0x0000
#define I2C_M_TEN	0x0010
#define I2C_M_RD	0x0001

struct i2c_msg {
	unsigned short addr;
	unsigned short flags;
	unsigned short len;
	u8 *buf;
	int timing;
};

struct i2c_client {
	int addr;
	unsigned short flags;
	void *adapter;
};

/* the extracted region declares a forward static struct (kernel type);
 * only pointer/integrity matters on the host */
struct i2c_driver { int unused; };
struct task_struct;

/* ---- kernel API shims (no-ops) ---- */
static void usleep_range(unsigned long min_us, unsigned long max_us)
{
	(void)min_us; (void)max_us;
}
static void msleep(unsigned int msecs) { (void)msecs; }
#define min_t(type, x, y) (((type)(x) < (type)(y)) ? (type)(x) : (type)(y))
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
/* source spells it as: static DECLARE_WAIT_QUEUE_HEAD(waiter); */
#define DECLARE_WAIT_QUEUE_HEAD(x) int x
#define TPD_DEVICE "mtk-tpd"
#define printk printf

unsigned int hweight32(u32 w)
{
	unsigned int c = 0;
	while (w) { c += w & 1u; w >>= 1; w &= w - 1; }
	return c;
}

/* gpio stubs used by gsl_sw_init's reset pulse */
#define GPIO_CTP_RST_PIN         (14 | 0x80000000u)
#define GPIO_CTP_RST_PIN_M_GPIO  0u
typedef enum { GPIO_DIR_OUT = 0, GPIO_DIR_IN = 1 } mt_gpio_dir_mock;
typedef enum { GPIO_OUT_ZERO = 0, GPIO_OUT_ONE = 1 } mt_gpio_out_mock;
static int mock_gpio_out = -1;
static inline void mt_set_gpio_mode(unsigned int pin, unsigned int mode)
{
	(void)pin; (void)mode;
}
static inline void mt_set_gpio_dir(unsigned int pin, unsigned int dir)
{
	(void)pin; (void)dir;
}
static inline void mt_set_gpio_out(unsigned int pin, unsigned int val)
{
	(void)pin; mock_gpio_out = (int)val;
}

/* tuning-word consumer (extern in the driver text) */
void gsl_DataInit(unsigned int *conf_in) { (void)conf_in; }

/* driver logging macros (GSL_DEBUG=0 in the real file → LOGD silent) */
#define GSL_LOGD(fmt, ...) \
	do { if (getenv("GSLH_DEBUG")) fprintf(stderr, "gsl_tp:D " fmt, ##__VA_ARGS__); } while (0)
#define GSL_LOGF() do { } while (0)
#define GSL_LOGE(fmt, ...) fprintf(stderr, "gsl_tp:E " fmt, ##__VA_ARGS__)

#endif /* _D22_PRE_NEW_H_ */
