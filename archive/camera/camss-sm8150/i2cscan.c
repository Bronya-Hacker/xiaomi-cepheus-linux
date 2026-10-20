// SPDX-License-Identifier: GPL-2.0
/* 调试用：用 i2c_transfer(2 字节寄存器读) 扫描适配器 */
#include <linux/module.h>
#include <linux/i2c.h>

static int bus = 2;
module_param(bus, int, 0444);
static int first = 8;
module_param(first, int, 0444);
static int last = 0x77;
module_param(last, int, 0444);

static int __init scan_init(void)
{
	struct i2c_adapter *adap = i2c_get_adapter(bus);
	int addr, found = 0;

	if (!adap) { pr_err("i2cscan: no adap %d\n", bus); return -ENODEV; }

	for (addr = first; addr <= last; addr++) {
		u8 reg[2] = { 0x00, 0x16 };
		u8 val[2] = { 0 };
		struct i2c_msg m[2] = {
			{ .addr = addr, .flags = 0, .len = 2, .buf = reg },
			{ .addr = addr, .flags = I2C_M_RD, .len = 2, .buf = val },
		};
		int ret = i2c_transfer(adap, m, 2);

		if (ret == 2) {
			pr_info("i2cscan: bus %d addr 0x%02x ACK id=%02x%02x\n",
				bus, addr, val[0], val[1]);
			found++;
		}
	}
	pr_info("i2cscan: bus %d done, %d ACK\n", bus, found);
	i2c_put_adapter(adap);
	return -EINVAL;
}
module_init(scan_init);
MODULE_LICENSE("GPL");
