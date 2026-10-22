/*
 * nfc-mifare.c —— 通过 AF_NFC raw socket 读写 NFC 卡片
 *
 * 支持 NTAG/Ultralight（无需认证）和 MIFARE Classic（AUTH-A + Crypto1）
 *
 * 关键坑（实测踩出来的）：
 *   1. socket 必须 SOCK_SEQPACKET（SOCK_RAW 的 connect 是空实现 → EOPNOTSUPP）
 *   2. target 索引从 0 开始
 *   3. 协议号 MIFARE=2 / ISO14443=4
 *   4. MIFARE 每个字节要额外喂 1 个校验位给密码状态（9 位帧）
 *
 * Crypto1 参考 Proxmark3/crapto1（bla@blapost, GPLv2+）
 *
 * 用法：
 *   ./nfc-mifare uid
 *   ./nfc-mifare read <块>
 *   ./nfc-mifare write <块> <32hex>
 *   ./nfc-mifare dump
 *   ./nfc-mifare key <12hex>
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <linux/nfc.h>

#define BIT(x, n) (((x) >> (n)) & 1)
#define LF_POLY_ODD  0x29CE5C
#define LF_POLY_EVEN 0x870804

struct c1_state { uint32_t odd, even; };

static int c1_filter(uint32_t x)
{
	uint32_t f;
	f  = 0xf22c0 >> (x       & 0xf) & 16;
	f |= 0x6c9c0 >> (x >>  4 & 0xf) &  8;
	f |= 0x3c8b0 >> (x >>  8 & 0xf) &  4;
	f |= 0x1e458 >> (x >> 12 & 0xf) &  2;
	f |= 0x0d938 >> (x >> 16 & 0xf) &  1;
	return BIT(0xEC57E80A, f);
}

static void c1_init(struct c1_state *s, uint64_t key)
{
	int i;
	s->odd = 0;
	s->even = 0;
	for (i = 47; i > 0; i -= 2) {
		s->odd  = s->odd  << 1 | BIT(key, (i - 1) ^ 7);
		s->even = s->even << 1 | BIT(key, i ^ 7);
	}
}

static uint8_t c1_bit(struct c1_state *s, uint8_t in, int is_enc)
{
	uint32_t feedin, t;
	uint8_t ret = c1_filter(s->odd);

	feedin  = ret & (!!is_enc);
	feedin ^= !!in;
	feedin ^= LF_POLY_ODD & s->odd;
	feedin ^= LF_POLY_EVEN & s->even;
	s->even = s->even << 1 | (__builtin_parity(feedin));

	t = s->odd;
	s->odd = s->even;
	s->even = t;
	return ret;
}

static uint8_t c1_byte(struct c1_state *s, uint8_t in, int is_enc)
{
	uint8_t ret = 0;
	int i;
	for (i = 0; i < 8; i++)
		ret |= c1_bit(s, BIT(in, i), is_enc) << i;
	return ret;
}

static uint8_t c1_enc(struct c1_state *s, uint8_t b)
{
	uint8_t ks = c1_byte(s, b, 1);
	(void)c1_bit(s, __builtin_parity(ks), 1);
	return ks;
}

static uint8_t c1_dec(struct c1_state *s, uint8_t b)
{
	uint8_t pt = c1_byte(s, b, 1);
	(void)c1_bit(s, __builtin_parity(b), 1);
	return pt;
}

static uint32_t prng_successor(uint32_t x, uint32_t n)
{
	uint32_t y = ((x >> 8 & 0xff00ff) | (x & 0xff00ff) << 8);
	y = y >> 16 | y << 16;
	while (n--)
		y = y >> 1 | (y >> 16 ^ y >> 18 ^ y >> 19 ^ y >> 21) << 31;
	x = ((y >> 8 & 0xff00ff) | (y & 0xff00ff) << 8);
	return x >> 16 | x << 16;
}

static int sock = -1;
static int dev_idx = 0;
static unsigned char key_a[6] = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
static struct c1_state c1;
static int authed = 0;

static int try_connect_once(void)
{
	int protos[] = { 2, 4, 1, 8, 5, 3 };
	int pi, ti;

	for (pi = 0; pi < 6; pi++) {
		for (ti = 0; ti <= 3; ti++) {
			struct sockaddr_nfc addr;

			memset(&addr, 0, sizeof(addr));
			addr.sa_family = AF_NFC;
			addr.dev_idx = dev_idx;
			addr.target_idx = ti;
			addr.nfc_protocol = protos[pi];
			if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
				printf("已连接卡片 (target=%d 协议=%d)\n", ti, protos[pi]);
				return protos[pi];
			}
			if (errno != ENOTCONN && errno != EINVAL)
				return -1;
		}
	}
	return 0;
}

/* 自动等待卡片：最多等 wait_s 秒 */
static int open_target(void)
{
	int r, i;

	sock = socket(AF_NFC, SOCK_SEQPACKET, NFC_SOCKPROTO_RAW);
	if (sock < 0) { perror("socket AF_NFC"); return -1; }

	printf("等待卡片（最多 30 秒，请把卡贴在手机背面顶部）...\n");
	for (i = 0; i < 150; i++) {
		r = try_connect_once();
		if (r < 0)
			break;
		if (r > 0)
			return r;
		if (i % 20 == 0 && i)
			printf("  ...已等 %d 秒\n", i / 5);
		usleep(200000);
	}
	printf("没等到卡片（确认 mi9-nfcd 在跑、卡贴对了位置）\n");
	return -1;
}

static int transceive(const unsigned char *tx, int txlen,
		      unsigned char *rx, int rxmax, int wait_ms)
{
	int r, i;

	r = send(sock, tx, txlen, 0);
	if (r < 0) return -1;
	for (i = 0; i < wait_ms; i++) {
		r = recv(sock, rx, rxmax, MSG_DONTWAIT);
		if (r > 0) return r;
		if (r < 0 && errno != EAGAIN && errno != EWOULDBLOCK) return -1;
		usleep(1000);
	}
	return -2;
}

static int mifare_auth_a(int block)
{
	unsigned char tx[8], rx[16];
	uint32_t nt, nr, ar, at, expect;
	int r, i;

	tx[0] = 0x60; tx[1] = (unsigned char)block;
	r = transceive(tx, 2, rx, sizeof(rx), 80);
	if (r < 4) { printf("AUTH: 没收到 nt (r=%d)\n", r); return -1; }

	nt = rx[0] | (rx[1] << 8) | (rx[2] << 16) | ((uint32_t)rx[3] << 24);
	printf("AUTH: nt=%08X\n", nt);

	c1_init(&c1, ((uint64_t)key_a[0]) | ((uint64_t)key_a[1] << 8) |
		     ((uint64_t)key_a[2] << 16) | ((uint64_t)key_a[3] << 24) |
		     ((uint64_t)key_a[4] << 32) | ((uint64_t)key_a[5] << 40));

	for (i = 0; i < 4; i++) c1_byte(&c1, (nt >> (8 * i)) & 0xff, 0);

	nr = prng_successor(nt, 64);
	ar = prng_successor(nt, 96);

	for (i = 0; i < 4; i++) tx[i] = c1_enc(&c1, (nr >> (8 * i)) & 0xff);
	r = transceive(tx, 4, rx, sizeof(rx), 40);

	for (i = 0; i < 4; i++) tx[4 + i] = c1_enc(&c1, (ar >> (8 * i)) & 0xff);
	r = transceive(tx + 4, 4, rx, sizeof(rx), 80);
	if (r < 4) { printf("AUTH: 没收到 at (r=%d) — 密钥可能不对\n", r); return -1; }

	at = 0;
	for (i = 0; i < 4; i++) at |= c1_dec(&c1, rx[i]) << (8 * i);
	expect = prng_successor(nt, 128);
	if (at != expect) {
		printf("AUTH: at=%08X 期望=%08X — 认证失败\n", at, expect);
		return -1;
	}
	printf("AUTH: 认证成功\n");
	authed = 1;
	return 0;
}

static int mifare_read_block(int block, unsigned char *out)
{
	unsigned char tx[2], rx[32];
	int r, i;

	tx[0] = 0x30; tx[1] = (unsigned char)block;
	r = transceive(tx, 2, rx, sizeof(rx), 80);
	if (r < 16) {
		printf("READ: 回应 %d 字节 (%s)\n", r, authed ? "长度不对" : "未认证");
		return -1;
	}
	for (i = 0; i < 16; i++) out[i] = c1_dec(&c1, rx[i]);
	return 0;
}

static int mifare_write_block(int block, const unsigned char *data)
{
	unsigned char tx[18], rx[8];
	int r, i;

	tx[0] = 0xA0; tx[1] = (unsigned char)block;
	for (i = 0; i < 16; i++) tx[2 + i] = c1_enc(&c1, data[i]);
	r = transceive(tx, 18, rx, sizeof(rx), 80);
	if (r < 1) { printf("WRITE: 无回应\n"); return -1; }
	printf("WRITE: 回应 %d 字节: %02x\n", r, rx[0]);
	return 0;
}

int main(int argc, char **argv)
{
	unsigned char out[32];
	int proto, i;

	if (argc < 2) {
		printf("用法: %s uid|read <块>|write <块> <hex>|dump|key <hex>\n", argv[0]);
		return 1;
	}

	if (!strcmp(argv[1], "key")) {
		if (argc >= 3) {
			const char *h = argv[2];
			for (i = 0; i < 6 && h[i*2] && h[i*2+1]; i++) {
				char b[3] = { h[i*2], h[i*2+1], 0 };
				key_a[i] = (unsigned char)strtol(b, NULL, 16);
			}
			printf("Key A 设为 %s\n", argv[2]);
		}
		return 0;
	}

	proto = open_target();
	if (proto < 0) {
		printf("连不上卡片：确认 mi9-nfcd 在跑、卡贴在手机上\n");
		return 2;
	}

	if (!strcmp(argv[1], "uid")) return 0;

	if (proto == 2) {
		if (mifare_auth_a(0) < 0) return 3;
	}

	if (!strcmp(argv[1], "read")) {
		int blk = argc > 2 ? atoi(argv[2]) : 0;
		if (mifare_read_block(blk, out) < 0) return 4;
		printf("块 %d:", blk);
		for (i = 0; i < 16; i++) printf(" %02x", out[i]);
		printf("\n");
		return 0;
	}

	if (!strcmp(argv[1], "write")) {
		unsigned char data[16];
		const char *h;
		int blk;

		if (argc < 4) { printf("用法: %s write <块> <32hex>\n", argv[0]); return 1; }
		blk = atoi(argv[2]);
		h = argv[3];
		for (i = 0; i < 16; i++) {
			char b[3] = { 0, 0, 0 };
			if (h[i*2]) b[0] = h[i*2];
			if (h[i*2+1]) b[1] = h[i*2+1];
			data[i] = (unsigned char)strtol(b, NULL, 16);
		}
		if (mifare_write_block(blk, data) < 0) return 4;
		printf("已写入块 %d\n", blk);
		return 0;
	}

	if (!strcmp(argv[1], "dump")) {
		for (i = 0; i < 64; i++) {
			int j;
			if (i % 4 == 3) { printf("块 %2d (尾块跳过)\n", i); continue; }
			if (mifare_read_block(i, out) == 0) {
				printf("块 %2d:", i);
				for (j = 0; j < 16; j++) printf(" %02x", out[j]);
				printf("\n");
			} else {
				printf("块 %2d: 失败\n", i);
			}
		}
		return 0;
	}

	printf("未知命令\n");
	return 1;
}