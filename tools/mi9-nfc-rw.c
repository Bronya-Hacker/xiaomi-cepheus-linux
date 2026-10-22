/*
 * mi9-nfc-rw.c —— 小米9（cepheus）用户态 NFC 读写工具
 *
 * 直接通过 I2C 驱动 SN100U，不经过内核 NCI 层，这样可以自由收发
 * 原始 RF 帧（读/写 MIFARE 扇区需要这个）。
 *
 * 关键实现要点（都是踩过的坑）：
 *   1. 上电：VEN 拉低 → 等 → 拉高 → 等，芯片才干净启动
 *   2. I2C 读：必须先写 2 字节再在同一事务里读，否则恒返回 0x00
 *   3. 芯片在 NCI 包之间插一个 0xFF 填充字节，读包首要跳过
 *
 * 编译： gcc -O2 -o mi9-nfc-rw mi9-nfc-rw.c
 * 用法：
 *   ./mi9-nfc-rw uid          只读卡片 UID / ATQA / SAK
 *   ./mi9-nfc-rw read <块号>   读一个 16 字节块（需认证）
 *   ./mi9-nfc-rw write <块号> <hex>   写一个块
 *
 * 注意：运行前需要先解绑内核驱动：
 *   echo 1-0028 > /sys/bus/i2c/drivers/nxp-nci_i2c/unbind
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

#define NCI_HDR_LEN	3
#define RX_RING		512

static int i2c_fd = -1;
static int gpio_fd = -1;
static int ven_off_num = 103;

/* ---------- GPIO（VEN） ---------- */

static int gpio_setup(const char *chip, int ven)
{
	struct gpio_v2_line_request req;
	int cfd, ret;

	cfd = open(chip, O_RDWR);
	if (cfd < 0) {
		perror("open gpiochip");
		return -1;
	}
	memset(&req, 0, sizeof(req));
	req.offsets[0] = ven;
	req.num_lines = 1;
	snprintf(req.consumer, sizeof(req.consumer), "mi9-nfc-rw");
	req.config.flags = GPIO_V2_LINE_FLAG_OUTPUT;
	ret = ioctl(cfd, GPIO_V2_GET_LINE_IOCTL, &req);
	if (ret < 0) {
		perror("GPIO_V2_GET_LINE_IOCTL");
		return -1;
	}
	gpio_fd = req.fd;
	close(cfd);
	ven_off_num = 0;
	return 0;
}

static int ven_set(int val)
{
	struct gpio_v2_line_values v;

	memset(&v, 0, sizeof(v));
	v.mask = 1;
	v.bits = val ? 1 : 0;
	return ioctl(gpio_fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &v);
}

/* ---------- I2C 传输 ---------- */

/* 读：先写 2 字节，再同事务读；重试若干次 */
static int i2c_read_raw(unsigned char *buf, int len)
{
	unsigned char dummy[2] = { 0, 0 };
	struct i2c_msg m[2];
	int i, r;

	m[0].addr = 0; m[0].flags = 0;
	m[0].len = 2; m[0].buf = dummy;
	m[1].addr = 0; m[1].flags = I2C_M_RD;
	m[1].len = len; m[1].buf = buf;

	for (i = 0; i < 20; i++) {
		r = ioctl(i2c_fd, I2C_RDWR,
			  &(struct i2c_rdwr_ioctl_data){ .msgs = m, .nmsgs = 2 });
		if (r >= 0)
			return 0;
		usleep(3000);
	}
	return -1;
}

static int i2c_write_raw(const unsigned char *buf, int len)
{
	struct i2c_msg m = { .addr = 0, .flags = 0, .len = len,
			     .buf = (unsigned char *)buf };
	int i, r;

	for (i = 0; i < 10; i++) {
		r = ioctl(i2c_fd, I2C_RDWR,
			  &(struct i2c_rdwr_ioctl_data){ .msgs = &m, .nmsgs = 1 });
		if (r >= 0)
			return 0;
		usleep(2000);
	}
	return -1;
}

/* ---------- NCI 收（含环形缓冲 + 跳过 0xFF 填充） ---------- */

struct nci_rx {
	unsigned char ring[RX_RING];
	int avail, pos;
};

static struct nci_rx rx;

static int rx_fill(int need)
{
	int chunk;

	if (rx.pos > 0) {
		memmove(rx.ring, rx.ring + rx.pos, rx.avail - rx.pos);
		rx.avail -= rx.pos;
		rx.pos = 0;
	}
	while (rx.avail < need) {
		if (rx.avail >= RX_RING)
			break;
		chunk = RX_RING - rx.avail;
		if (chunk > 32)
			chunk = 32;
		if (i2c_read_raw(rx.ring + rx.avail, chunk) < 0)
			return -1;
		rx.avail += chunk;
	}
	return 0;
}

/* 读一个完整 NCI 包（先 3 字节头，再负载），返回包长 */
static int nci_recv(unsigned char *out, int maxlen, int packet_start)
{
	int i, plen, need;

	if (packet_start) {
		for (i = 0; i < 200; i++) {
			if (rx_fill(1) < 0)
				return -1;
			if (rx.ring[rx.pos] == 0xff)
				rx.pos++;
			else
				break;
		}
	}
	if (rx_fill(rx.pos + NCI_HDR_LEN) < 0)
		return -1;
	memcpy(out, rx.ring + rx.pos, NCI_HDR_LEN);
	rx.pos += NCI_HDR_LEN;

	plen = out[2];
	if (plen == 0)
		return NCI_HDR_LEN;
	if (plen > maxlen - NCI_HDR_LEN) {
		fprintf(stderr, "包太大 %d\n", plen);
		return -1;
	}
	need = rx.pos + plen;
	if (rx_fill(need) < 0)
		return -1;
	memcpy(out + NCI_HDR_LEN, rx.ring + rx.pos, plen);
	rx.pos += plen;
	return NCI_HDR_LEN + plen;
}

static void hexdump(const char *tag, const unsigned char *d, int n)
{
	int i;

	printf("%s", tag);
	for (i = 0; i < n; i++)
		printf(" %02x", d[i]);
	printf("\n");
}

/* 发一个 NCI 命令并等对应的 RSP；返回 RSP 的负载长度 */
static int nci_cmd(int gid, int oid, const unsigned char *payload, int plen,
		   unsigned char *rsp, int rsp_max)
{
	unsigned char pkt[300];
	int i, n;

	pkt[0] = (1 << 5) | gid;	/* MT=command */
	pkt[1] = oid;
	pkt[2] = (unsigned char)plen;
	if (plen)
		memcpy(pkt + 3, payload, plen);
	if (i2c_write_raw(pkt, 3 + plen) < 0) {
		fprintf(stderr, "写失败\n");
		return -1;
	}

	for (i = 0; i < 300; i++) {
		n = nci_recv(rsp, rsp_max, 1);
		if (n < 0)
			return -1;
		if (n < 3)
			continue;
		/* 等 RSP：MT=2 (0x40) 且 GID/OID 匹配 */
		if ((rsp[0] & 0xe0) == 0x40 && rsp[0] == ((2 << 5) | gid) &&
		    rsp[1] == oid) {
			if (rsp[3] != 0x00) {
				fprintf(stderr, "命令 %d/%d 失败 status=0x%02x\n",
					gid, oid, rsp[3]);
				return -1;
			}
			return n - 3;
		}
		/* 其他包（NTF）丢掉 */
	}
	return -1;
}

/* 等指定的 NTF（GID/OID 匹配） */
static int nci_wait_ntf(int gid, int oid, unsigned char *ntf, int max, int loops)
{
	int i, n;

	for (i = 0; i < loops; i++) {
		n = nci_recv(ntf, max, 1);
		if (n < 0)
			return -1;
		if (n >= 3 && (ntf[0] & 0xe0) == 0x60 &&
		    ntf[0] == ((3 << 5) | gid) && ntf[1] == oid)
			return n - 3;
	}
	return -1;
}

/* ---------- 初始化 ---------- */

static int nfc_power_on(void)
{
	ven_set(0);
	usleep(150000);
	ven_set(1);
	usleep(300000);
	return 0;
}

static int nfc_init(void)
{
	unsigned char rsp[300];
	unsigned char reset[] = { 0x01 };	/* keep config */
	unsigned char init[] = { 0x00, 0x00 };
	unsigned char map[] = { 0x01, 0x00, 0x01, 0x01 };  /* NFC-A → Frame */
	unsigned char disc[] = { 0x01, 0x00, 0x01 };	   /* NFC-A passive poll */

	rx.pos = rx.avail = 0;

	if (nci_cmd(0, 0x00, reset, 1, rsp, sizeof(rsp)) < 0) {
		fprintf(stderr, "CORE_RESET 失败\n");
		return -1;
	}
	/* CORE_RESET 之后芯片会再发一个 NTF，必须收掉 */
	nci_wait_ntf(0, 0x00, rsp, sizeof(rsp), 20);

	if (nci_cmd(0, 0x01, init, 2, rsp, sizeof(rsp)) < 0) {
		fprintf(stderr, "CORE_INIT 失败\n");
		return -1;
	}

	if (nci_cmd(1, 0x00, map, sizeof(map), rsp, sizeof(rsp)) < 0) {
		fprintf(stderr, "RF_DISCOVER_MAP 失败\n");
		return -1;
	}

	if (nci_cmd(1, 0x03, disc, sizeof(disc), rsp, sizeof(rsp)) < 0) {
		fprintf(stderr, "RF_DISCOVER 失败\n");
		return -1;
	}
	return 0;
}

/* 等卡片激活，取出 UID */
static int nfc_activate(unsigned char *uid, int *uid_len,
			unsigned char *sens, unsigned char *sel, int *proto)
{
	unsigned char ntf[300];
	int n, plen, i;

	n = nci_wait_ntf(1, 0x05, ntf, sizeof(ntf), 400);
	if (n < 0) {
		fprintf(stderr, "没有卡片激活（贴卡了吗？）\n");
		return -1;
	}
	/* ntf: 61 05 len | id iface proto tech bitrate credits plen | ... */
	if (n < 7)
		return -1;
	*proto = ntf[5];
	plen = ntf[9];
	if (plen < 3)
		return -1;
	*sens = ntf[10];
	*sel = 0;
	{
		int ulen = ntf[12];

		if (ulen < 1 || ulen > 10)
			return -1;
		for (i = 0; i < ulen; i++)
			uid[i] = ntf[13 + i];
		*uid_len = ulen;
		if (13 + ulen + 1 < n)
			*sel = ntf[13 + ulen + 1];
	}
	return 0;
}

/* ---------- 与卡片交换原始帧 ---------- */

/* 发一帧给卡片并收回复。返回回复长度，负数为错误 */
static int card_transceive(const unsigned char *tx, int txlen,
			   unsigned char *rx_buf, int rx_max, int wait_ms)
{
	unsigned char pkt[300], resp[300];
	int n, i;

	/* NCI 数据包：MT=0 (data)，GID/OID 用作 PBF/连接ID */
	pkt[0] = 0x00;
	pkt[1] = 0x00;
	pkt[2] = (unsigned char)txlen;
	memcpy(pkt + 3, tx, txlen);

	if (i2c_write_raw(pkt, 3 + txlen) < 0)
		return -2;

	for (i = 0; i < wait_ms; i++) {
		n = nci_recv(resp, sizeof(resp), 1);
		if (n < 0)
			return -2;
		if (n < 3)
			continue;
		/* 数据包 MT=0 */
		if ((resp[0] & 0xe0) == 0x00) {
			int l = resp[2];

			if (l > rx_max)
				l = rx_max;
			memcpy(rx_buf, resp + 3, l);
			return l;
		}
		usleep(1000);
	}
	return -1;
}

int main(int argc, char **argv)
{
	unsigned char uid[16], sens = 0, sel = 0;
	int ulen = 0, proto = 0;

	if (argc < 2) {
		printf("用法: %s uid|read <块>|write <块> <hex16>\n", argv[0]);
		return 1;
	}

	if (gpio_setup("/dev/gpiochip3", 103) < 0)
		return 1;

	i2c_fd = open("/dev/i2c-1", O_RDWR);
	if (i2c_fd < 0) {
		perror("open i2c-1");
		return 1;
	}
	if (ioctl(i2c_fd, I2C_SLAVE, 0x28) < 0) {
		perror("I2C_SLAVE");
		return 1;
	}

	nfc_power_on();
	usleep(200000);

	if (nfc_init() < 0)
		return 1;

	if (nfc_activate(uid, &ulen, &sens, &sel, &proto) < 0)
		return 1;

	printf("卡片已激活：协议=%d ATQA=%02x%02x SAK=%02x UID=", proto, sens,
	       sens, sel);
	{
		int i;

		for (i = 0; i < ulen; i++)
			printf("%02X", uid[i]);
		printf("\n");
	}

	if (!strcmp(argv[1], "uid"))
		return 0;

	if (!strcmp(argv[1], "read")) {
		int blk = argc > 2 ? atoi(argv[2]) : 0;
		unsigned char cmd[2] = { 0x30, (unsigned char)blk };
		unsigned char out[64];
		int n = card_transceive(cmd, 2, out, sizeof(out), 50);

		if (n < 0) {
			printf("读块 %d 失败（MIFARE Classic 需要先认证）\n", blk);
			return 2;
		}
		hexdump("数据:", out, n);
		return 0;
	}

	if (!strcmp(argv[1], "write")) {
		printf("写功能待实现（需要 Crypto1 认证）\n");
		return 3;
	}

	return 0;
}
