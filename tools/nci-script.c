/*
 * nci-script.c —— 按 NXP .pnscr 脚本逐条给 NCI 芯片发命令，并打印应答
 *
 * NXP HAL 上电后就是把 .pnscr 里的 send 命令逐条发给芯片完成初始化。
 * 用法： ./nci-script <i2c总线号> <地址> <.pnscr 文件>
 * 例：   ./nci-script 1 0x28 /mnt/vendor/etc/sn100u_bootup.pnscr
 *
 * 支持的行：
 *   reset <n>         —— 打印提示（真正拉 EN 请在外层脚本用 gpioset）
 *   interval <ms>     —— 延时
 *   send <hex...>     —— 发送这些字节；^M 等非十六进制字符会被忽略
 *   其它/以 # 开头     —— 忽略（注释里通常写着期望的应答，会一起打印出来对照）
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <ctype.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>

static int hexval(int c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

/* 从一行里提取十六进制字节，跳过 ^M 之类 */
static int parse_hex(const char *s, unsigned char *out, int cap)
{
	int hi = -1, n = 0;

	for (; *s && n < cap; s++) {
		int v = hexval((unsigned char)*s);

		if (v < 0) {
			hi = -1;
			continue;
		}
		if (hi < 0) {
			hi = v;
		} else {
			out[n++] = (unsigned char)((hi << 4) | v);
			hi = -1;
		}
	}
	return n;
}

static int i2c_write(int fd, const unsigned char *b, int n)
{
	struct i2c_msg msg;

	msg.addr = 0;	/* 由 ioctl 的 slave 设置 */
	msg.flags = 0;
	msg.len = n;
	msg.buf = (unsigned char *)b;
	return ioctl(fd, I2C_RDWR, &(struct i2c_rdwr_ioctl_data){ .msgs = &msg, .nmsgs = 1 }) < 0 ? -errno : 0;
}

static int i2c_read(int fd, unsigned char *b, int n)
{
	struct i2c_msg msg;

	msg.addr = 0;
	msg.flags = I2C_M_RD;
	msg.len = n;
	msg.buf = b;
	return ioctl(fd, I2C_RDWR, &(struct i2c_rdwr_ioctl_data){ .msgs = &msg, .nmsgs = 1 }) < 0 ? -errno : 0;
}

static void dump(const char *tag, const unsigned char *b, int n)
{
	int i;

	printf("%s", tag);
	for (i = 0; i < n; i++)
		printf(" %02x", b[i]);
	printf("\n");
}

int main(int argc, char **argv)
{
	int fd, addr, bus;
	char path[32];
	FILE *f;
	char line[1024];
	int lineno = 0, sent = 0, got = 0;

	if (argc < 4) {
		printf("用法: %s <i2c总线> <地址> <.pnscr>\n", argv[0]);
		return 1;
	}
	bus = atoi(argv[1]);
	addr = (int)strtol(argv[2], NULL, 0);
	snprintf(path, sizeof(path), "/dev/i2c-%d", bus);

	fd = open(path, O_RDWR);
	if (fd < 0) {
		printf("打不开 %s: %s\n", path, strerror(errno));
		return 1;
	}
	if (ioctl(fd, I2C_SLAVE, addr) < 0) {
		printf("设置从地址 0x%02x 失败: %s\n", addr, strerror(errno));
		return 1;
	}
	printf("已打开 %s，从地址 0x%02x\n", path, addr);

	f = fopen(argv[3], "r");
	if (!f) {
		printf("打不开脚本 %s\n", argv[3]);
		return 1;
	}

	while (fgets(line, sizeof(line), f)) {
		char *p = line;
		unsigned char buf[260];
		int n;

		lineno++;
		while (*p == ' ' || *p == '\t')
			p++;

		if (*p == '#' || *p == '\n' || *p == '\r' || *p == '\0') {
			/* 注释里常写着期望的应答，打出来便于对照 */
			if (strstr(p, "<<") || strstr(p, "-=("))
				printf("      (脚本注释) %s", p);
			continue;
		}

		if (!strncmp(p, "reset", 5)) {
			printf("[%3d] reset —— 请在外层确认 EN 已拉高\n", lineno);
			usleep(50 * 1000);
			continue;
		}
		if (!strncmp(p, "interval", 8)) {
			int ms = atoi(p + 8);

			printf("[%3d] interval %d ms\n", lineno, ms);
			usleep(ms * 1000);
			continue;
		}
		if (!strncmp(p, "send", 4)) {
			n = parse_hex(p + 4, buf, sizeof(buf));
			if (n <= 0) {
				printf("[%3d] send 行解析不出字节，跳过\n", lineno);
				continue;
			}
			dump("  -> ", buf, n);
			{
				int r = i2c_write(fd, buf, n);

				if (r < 0) {
					/* 原厂脚本就是靠重发冲缓冲，这里重试 3 次 */
					int t;

					printf("     写失败 %d，重试…\n", r);
					for (t = 0; t < 3 && r < 0; t++) {
						usleep(20 * 1000);
						r = i2c_write(fd, buf, n);
					}
				}
				if (r < 0)
					printf("     写仍失败: %d\n", r);
				else
					sent++;
			}
			/* 读应答 */
			usleep(60 * 1000);
			{
				unsigned char rb[260];
				int i;

				for (i = 0; i < 3; i++) {
					int r = i2c_read(fd, rb, sizeof(rb));

					if (r < 0) {
						printf("     读失败: %d\n", r);
						break;
					}
					{
						int nonzero = 0, k;

						for (k = 0; k < (int)sizeof(rb); k++)
							if (rb[k]) {
								nonzero = 1;
								break;
							}
						if (nonzero) {
							dump("  <- ", rb, 32);
							got++;
							break;
						}
					}
					usleep(30 * 1000);
				}
			}
			continue;
		}
		printf("[%3d] 未知指令，跳过: %s", lineno, p);
	}
	fclose(f);
	close(fd);

	printf("\n完成：发送 %d 条，收到非零应答 %d 条\n", sent, got);
	return 0;
}
