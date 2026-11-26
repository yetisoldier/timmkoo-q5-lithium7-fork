/*
 * hera-d22 mock transport — every i2c op is logged with its exact on-wire
 * bytes so the tests can assert the byte stream (D22 contract: payload
 * immutability + exact byte stream) and inject failures.
 *
 * Read side models a minimal GSL device: a flat 256-byte register file
 * (writes store their payload at reg..reg+len-1; repeats the vendor's echo
 * behaviour that gsl_test_i2c relies on), plus two scripted behaviours:
 *   - a 4-byte zero write @0xe0 (gsl_start_core) "boots" the firmware and
 *     flips reg 0xb0 byte0 to 0x5a (unless sim_boot == 0);
 *   - reads of 0xb0/0xb4/0xb8 return whatever the test pre-set (or zeros).
 */
#ifndef _D22_MOCK_I2C_H_
#define _D22_MOCK_I2C_H_

#define MOCK_MAX_OPS 20000
struct i2c_op {
	int is_write;		/* 1 = write (n==1 msg), 0 = read (n==2 msgs) */
	u8 reg;
	int wire_len;		/* write: total on-wire bytes (reg-first) */
	int rd_len;		/* read: requested payload length */
	u8 wire[256];		/* write bytes exactly as passed to i2c_transfer */
};

struct mock_state {
	struct i2c_op ops[MOCK_MAX_OPS];
	int nops;
	/* failure injection */
	int fail_idx[64]; int nfail;	/* fail i2c_transfer whose op index matches */
	int fail_val[64];		/* value the failing transfer returns (0 = short, <0 = error) */
	int fail_wr_0xbc_after;		/* fail the (k+1)-th and later writes @0xbc; -1 = off */
	int n_wr_0xbc;
	/* fake device state */
	u8 mem[256];
	int sim_boot;			/* 1: a 4-byte zero write @0xe0 "boots" fw (mem[0xb0]:=0x5a) */
};
static struct mock_state M;

static void mock_reset(void)
{
	memset(&M, 0, sizeof(M));
	M.fail_wr_0xbc_after = -1;
}

static void mock_fail_idx(int idx, int val)
{
	M.fail_idx[M.nfail] = idx;
	M.fail_val[M.nfail] = val;
	M.nfail++;
}

static void mock_fill_wire(struct i2c_op *op, struct i2c_msg *msg)
{
	int n = msg->len;
	if (n < 0) n = 0;
	if (n > (int)sizeof(op->wire)) n = (int)sizeof(op->wire);
	memcpy(op->wire, msg->buf, (size_t)n);
	op->wire_len = msg->len;
}

static int i2c_transfer(void *adapter, struct i2c_msg *msgs, int n)
{
	struct i2c_op *op;
	int idx;
	int i;

	(void)adapter;
	if (M.nops >= MOCK_MAX_OPS)
		return 0;
	idx = M.nops;
	op = &M.ops[M.nops++];
	op->is_write = (n == 1);
	op->reg = msgs[0].buf[0];
	if (op->is_write) {
		int boff, k;
		op->rd_len = 0;
		mock_fill_wire(op, &msgs[0]);
		/* store payload into the flat register file (echo semantics) */
		boff = msgs[0].buf[0] & 0xff;
		for (k = 1; k < msgs[0].len; k++)
			M.mem[(boff + k - 1) & 0xff] = msgs[0].buf[k];
		if (op->reg == 0xbc && msgs[0].len == 5)
			M.n_wr_0xbc++;
	} else {
		op->rd_len = msgs[1].len;
		op->wire_len = 0;
	}

	for (i = 0; i < M.nfail; i++)
		if (M.fail_idx[i] == idx)
			return M.fail_val[i];
	if (op->is_write && op->reg == 0xbc && msgs[0].len == 5 &&
	    M.fail_wr_0xbc_after >= 0 && M.n_wr_0xbc > M.fail_wr_0xbc_after)
		return -5;

	if (op->is_write && M.sim_boot && op->reg == 0xe0 && msgs[0].len == 5 &&
	    msgs[0].buf[1] == 0x00 && msgs[0].buf[2] == 0x00 &&
	    msgs[0].buf[3] == 0x00 && msgs[0].buf[4] == 0x00) {
		/* firmware "boots" after the run command: reg 0xb0 byte0 = 0x5a */
		M.mem[0xb0] = 0x5a;
		M.mem[0xb1] = 0x00; M.mem[0xb2] = 0x00; M.mem[0xb3] = 0x00;
	} else if (!op->is_write) {
		int boff = msgs[0].buf[0] & 0xff;	/* the reg is sent via msg[0] */
		for (i = 0; i < msgs[1].len; i++)
			msgs[1].buf[i] = M.mem[(boff + i) & 0xff];
	}
	return n;
}

#endif /* _D22_MOCK_I2C_H_ */
