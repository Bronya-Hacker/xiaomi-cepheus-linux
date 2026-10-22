/*
 * nfc-tag.c —— 通过 AF_NFC raw socket 读写 NFC 卡片数据
 *
 * 原理：内核 NFC 栈提供 NFC_SOCKPROTO_RAW socket，bind 到某个 target 后
 * 就能用 send()/recv() 和卡片交换原始帧。这样不用碰 I2C/GPIO，
 * 硬件完全由内核驱动管理，稳定可靠。
 *
 * 对 NTAG / MIFARE Ultralight（T2T）：
 *   READ  0x30 <页号>  → 返回 16 字节（4 页 × 4 字节），无需认证
 *   WRITE 0xA2 <页号> <4字节> → 写一页，返回 0x0A（ACK）
 *
 * 对 MIFARE Classic（需要 Crypto1 认证，本工具暂不支持）：
 *   AUTH 0x60/0x61 <块号> ...
 *
 * 编译： gcc -O2 -o nfc-tag nfc-tag.c
 * 用法：
 *   ./nfc-tag read          读第 0~3 页（含 UID）
 *   ./nfc-tag read <页号>   读指定页
 *   ./nfc-tag write <页号> <8位十六进制>   写一页（4 字节）
 *
 * 需要 mi9-nfcd 服务在跑（它负责上电+轮询），并且卡已贴在手机上。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <linux/nfc.h>

static int dev_idx = 0;

static int try_target(int sock, int target_idx, unsigned int proto)
{
	struct sockaddr_nfc addr;

	memset(&addr, 0, sizeof(addr));
	addr.sa_family = AF_NFC;
	addr.dev_idx = dev_idx;
	addr.target_idx = target_idx;
	addr.nfc_protocol = proto;

	return connect(sock, (struct sockaddr *)&addr, sizeof(addr));
}

int main(int argc, char **argv)
{
	int sock, i, r;
	unsigned char tx[64], rx[64];
	int target_idx, proto;

	if (argc < 2) {
		printf("用法: %s read [页号] | write <页号> <8位hex>\n", argv[0]);
		return 1;
	}

	/* 依次尝试常见的 target 索引 / 协议组合 */
	sock = socket(AF_NFC, SOCK_SEQPACKET, NFC_SOCKPROTO_RAW);
	if (sock < 0) {
		perror("socket AF_NFC");
		printf("提示：内核需要 CONFIG_NFC_SHDLC/rawsock 支持\n");
		return 1;
	}

	r = -1;
	{
		int protos[] = { 4, 2, 1, 8, 5, 3 };
		int pi, ti;

		for (pi = 0; pi < 6 && r < 0; pi++) {
			for (ti = 0; ti <= 3; ti++) {
				errno = 0;
				r = try_target(sock, ti, protos[pi]);
				printf("  尝试 target=%d 协议=%d -> %s\n", ti,
				       protos[pi],
				       r == 0 ? "成功" : strerror(errno));
				if (r == 0) {
					target_idx = ti;
					proto = protos[pi];
					break;
				}
			}
		}
	}
	if (r < 0) {
		perror("connect 失败");
		printf("提示：卡没贴好，或者轮询没跑（检查 systemctl status mi9-nfcd）\n");
		return 2;
	}

	if (!strcmp(argv[1], "read")) {
		int page = argc > 2 ? atoi(argv[2]) : 0;

		tx[0] = 0x30;
		tx[1] = (unsigned char)page;
		r = send(sock, tx, 2, 0);
		if (r < 0) {
			perror("send READ");
			return 3;
		}
		memset(rx, 0, sizeof(rx));
		r = recv(sock, rx, sizeof(rx), 0);
		if (r < 0) {
			perror("recv READ");
			return 3;
		}
		printf("读取 %d 字节:", r);
		for (i = 0; i < r; i++)
			printf(" %02x", rx[i]);
		printf("\n");
		if (r >= 16) {
			printf("  —— 分页 ——\n");
			for (i = 0; i < 4; i++)
				printf("  page %-2d: %02x %02x %02x %02x\n",
				       page + i, rx[i * 4], rx[i * 4 + 1],
				       rx[i * 4 + 2], rx[i * 4 + 3]);
		}
		return 0;
	}

	if (!strcmp(argv[1], "write")) {
		int page;
		unsigned int val;

		if (argc < 4) {
			printf("用法: %s write <页号> <8位hex，如 DEADBEEF>\n",
			       argv[0]);
			return 1;
		}
		page = atoi(argv[2]);
		val = (unsigned int)strtoul(argv[3], NULL, 16);

		tx[0] = 0xA2;
		tx[1] = (unsigned char)page;
		tx[2] = (val >> 24) & 0xff;
		tx[3] = (val >> 16) & 0xff;
		tx[4] = (val >> 8) & 0xff;
		tx[5] = val & 0xff;
		r = send(sock, tx, 6, 0);
		if (r < 0) {
			perror("send WRITE");
			return 3;
		}
		memset(rx, 0, sizeof(rx));
		r = recv(sock, rx, sizeof(rx), 0);
		if (r < 0) {
			perror("recv WRITE");
			return 3;
		}
		printf("写入页 %d = %08X，回应 %d 字节:", page, val, r);
		for (i = 0; i < r; i++)
			printf(" %02x", rx[i]);
		printf("\n");
		if (r >= 1 && rx[0] == 0x0A)
			printf("  ✅ 卡片确认写入成功 (ACK 0x0A)\n");
		else
			printf("  ⚠️ 回应不是 0x0A，可能失败\n");
		return 0;
	}

	printf("未知命令\n");
	return 1;
}
