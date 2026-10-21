/*
 * nfc-pulse.c —— 按厂商时序给 NXP SN100U 做上电复位脉冲，并发 NCI 命令
 *
 * 厂商 nq-nci.c 的 nfcc_hw_check() 里的时序（我们之前从没做过）：
 *
 *	VEN=1 → 10ms → VEN=0 → 10ms → VEN=1 → 10ms → 发 CORE_RESET(20 00 01 00)
 *
 * 失败时它会切到固件下载模式：拉高 FIRM、再 VEN 低→高，然后发
 *	00 04 F1 00 00 00 6E EF
 * 这条"取版本"命令。
 *
 * 编译： gcc -O2 -o nfc-pulse nfc-pulse.c
 * 用法： ./nfc-pulse <gpiochip> <ven偏移> <firm偏移> <i2cbus> <addr>
 *   例： ./nfc-pulse gpiochip3 103 48 1 0x28
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/gpio.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>

static int line_fd = -1;
static int chip_fd = -1;
static int offsets[2];		/* [0]=ven, [1]=firm */
static int nlines = 0;

/* 用 GPIO v2 uAPI 一次性拿到 VEN/FIRM 两条线 */
static int gpio_open(const char *chip, int ven, int firm)
{
	struct gpio_v2_line_request req;
	int ret;

	chip_fd = open(chip, O_RDWR);
	if (chip_fd < 0) {
		perror("open gpiochip");
		return -1;
	}
	memset(&req, 0, sizeof(req));
	offsets[0] = ven;
	nlines = 1;
	if (firm >= 0) {
		offsets[1] = firm;
		nlines = 2;
	}
	memcpy(req.offsets, offsets, sizeof(int) * nlines);
	req.num_lines = nlines;
	snprintf(req.consumer, sizeof(req.consumer), "nfc-pulse");
	req.config.flags = GPIO_V2_LINE_FLAG_OUTPUT;

	ret = ioctl(chip_fd, GPIO_V2_GET_LINE_IOCTL, &req);
	if (ret < 0) {
		perror("GPIO_V2_GET_LINE_IOCTL");
		return -1;
	}
	line_fd = req.fd;
	return 0;
}

static int gpio_set(int idx, int val)
{
	struct gpio_v2_line_values v;

	memset(&v, 0, sizeof(v));
	v.mask = 1ULL << idx;
	v.bits = val ? (1ULL << idx) : 0;
	return ioctl(line_fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &v);
}

static void dump(const char *tag, unsigned char *b, int n)
{
	int i;

	printf("%s", tag);
	for (i = 0; i < n; i++)
		printf(" %02x", b[i]);
	printf("\n");
}

static int i2c_w(int fd, unsigned char *b, int n)
{
	struct i2c_msg m = { .addr = 0, .flags = 0, .len = n, .buf = b };

	return ioctl(fd, I2C_RDWR,
		     &(struct i2c_rdwr_ioctl_data){ .msgs = &m, .nmsgs = 1 }) < 0 ?
	       -errno : 0;
}

static int i2c_r(int fd, unsigned char *b, int n)
{
	struct i2c_msg m = { .addr = 0, .flags = I2C_M_RD, .len = n, .buf = b };

	return ioctl(fd, I2C_RDWR,
		     &(struct i2c_rdwr_ioctl_data){ .msgs = &m, .nmsgs = 1 }) < 0 ?
	       -errno : 0;
}

int main(int argc, char **argv)
{
	int bus, addr, fd, i;
	char path[32];
	unsigned char cmd[16], rsp[64];
	int ven_off, firm_off;

	if (argc < 6) {
		printf("用法: %s <gpiochip> <ven> <firm> <i2cbus> <addr>\n", argv[0]);
		return 1;
	}
	ven_off = atoi(argv[2]);
	firm_off = atoi(argv[3]);
	bus = atoi(argv[4]);
	addr = (int)strtol(argv[5], NULL, 0);

	if (gpio_open(argv[1], ven_off, firm_off) < 0)
		return 1;

	snprintf(path, sizeof(path), "/dev/i2c-%d", bus);
	fd = open(path, O_RDWR);
	if (fd < 0) {
		perror("open i2c");
		return 1;
	}
	if (ioctl(fd, I2C_SLAVE, addr) < 0) {
		perror("I2C_SLAVE");
		return 1;
	}

	/* ---- 厂商时序：1 → 10ms → 0 → 10ms → 1 → 10ms ---- */
	printf("== VEN 复位脉冲 (1/10ms, 0/10ms, 1/10ms) ==\n");
	if (nlines > 1)
		gpio_set(1, 0);		/* FIRM = 0（正常模式） */
	gpio_set(0, 1); usleep(10000);
	gpio_set(0, 0); usleep(10000);
	gpio_set(0, 1); usleep(10000);

	/* 保持 VEN 高（不释放），发 CORE_RESET */
	memset(cmd, 0, sizeof(cmd));
	cmd[0] = 0x20; cmd[1] = 0x00; cmd[2] = 0x01; cmd[3] = 0x00;
	printf("== 发 CORE_RESET: ");
	dump("", cmd, 4);
	i = i2c_w(fd, cmd, 4);
	printf("   写结果: %d\n", i);

	usleep(10000);
	for (i = 0; i < 3; i++) {
		memset(rsp, 0, sizeof(rsp));
		if (i2c_r(fd, rsp, 12) == 0) {
			dump("   <- 读12字节:", rsp, 12);
		} else {
			printf("   读失败 %d\n", errno);
		}
		usleep(15000);
	}

	/* ---- 若上面没有 NTF，试固件下载模式 ---- */
	printf("\n== 如果上面没有 60 00 ... 则试下载模式握手 ==\n");
	if (nlines > 1) {
		gpio_set(1, 1);		/* FIRM = 1 */
		usleep(10000);
		gpio_set(0, 0); usleep(10000);
		gpio_set(0, 1); usleep(10000);
		{
			unsigned char ver[8] = { 0x00, 0x04, 0xF1, 0x00, 0x00, 0x00, 0x6E, 0xEF };

			dump("  -> get_version:", ver, 8);
			printf("   写结果: %d\n", i2c_w(fd, ver, 8));
			usleep(10000);
			memset(rsp, 0, sizeof(rsp));
			if (i2c_r(fd, rsp, 16) == 0)
				dump("   <- 读16字节:", rsp, 16);
			else
				printf("   读失败 %d\n", errno);
		}
		gpio_set(1, 0);
	}

	printf("\n完成（VEN 保持高，进程退出后释放）\n");
	return 0;
}
