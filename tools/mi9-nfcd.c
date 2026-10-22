/*
 * mi9-nfcd.c —— 小米9（cepheus）NFC 常驻服务
 *
 * 做三件事：
 *   1. 通过 NFC netlink 做 DEV_UP + START_POLL，并且一直持有 socket
 *      （主线内核在 socket 关闭时会自动停止轮询，所以必须常驻）
 *   2. 打印 TARGET_FOUND 等事件
 *   3. 从 /dev/kmsg 里解析驱动打印的 NCI 原始帧，取出卡片 UID
 *      （主线 netlink 事件不携带 target 属性，只能这样拿 UID）
 *
 * 编译： gcc -O2 -o mi9-nfcd mi9-nfcd.c
 * 运行： ./mi9-nfcd [设备号，默认 0]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <poll.h>
#include <errno.h>
#include <time.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <linux/netlink.h>
#include <linux/genetlink.h>
#include <linux/nfc.h>

#ifndef NLA_ALIGNTO
#define NLA_ALIGNTO 4
#endif
#ifndef NLA_ALIGN
#define NLA_ALIGN(len) (((len) + NLA_ALIGNTO - 1) & ~(NLA_ALIGNTO - 1))
#endif
#define NLA_OK(nla, len) \
	((len) >= (int)sizeof(struct nlattr) && \
	 (nla)->nla_len >= sizeof(struct nlattr) && \
	 (int)(nla)->nla_len <= (len))
#define NLA_NEXT(nla, attrlen) \
	((attrlen) -= NLA_ALIGN((nla)->nla_len), \
	 (struct nlattr *)(((char *)(nla)) + NLA_ALIGN((nla)->nla_len)))

static int resolve_family(int fd, const char *name)
{
	struct sockaddr_nl addr;
	struct {
		struct nlmsghdr n;
		struct genlmsghdr g;
		char buf[128];
	} req;
	struct nlattr *na;
	char resp[4096];
	int len, ret = -1;

	memset(&addr, 0, sizeof(addr));
	addr.nl_family = AF_NETLINK;

	memset(&req, 0, sizeof(req));
	req.n.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
	req.n.nlmsg_type = GENL_ID_CTRL;
	req.n.nlmsg_flags = NLM_F_REQUEST;
	req.n.nlmsg_seq = 1;
	req.g.cmd = CTRL_CMD_GETFAMILY;
	req.g.version = 1;

	na = (struct nlattr *)((char *)&req + req.n.nlmsg_len);
	na->nla_type = CTRL_ATTR_FAMILY_NAME;
	na->nla_len = NLA_HDRLEN + strlen(name) + 1;
	strcpy((char *)na + NLA_HDRLEN, name);
	req.n.nlmsg_len += NLA_ALIGN(na->nla_len);

	if (sendto(fd, &req, req.n.nlmsg_len, 0,
		   (struct sockaddr *)&addr, sizeof(addr)) < 0)
		return -1;

	len = recv(fd, resp, sizeof(resp), 0);
	if (len > 0) {
		struct nlmsghdr *nh = (struct nlmsghdr *)resp;
		struct genlmsghdr *gh = (struct genlmsghdr *)NLMSG_DATA(nh);
		struct nlattr *a;
		int alen = nh->nlmsg_len - NLMSG_LENGTH(GENL_HDRLEN);

		for (a = (struct nlattr *)((char *)gh + GENL_HDRLEN);
		     NLA_OK(a, alen); a = NLA_NEXT(a, alen)) {
			if (a->nla_type == CTRL_ATTR_FAMILY_ID) {
				ret = *(unsigned short *)((char *)a + NLA_HDRLEN);
				break;
			}
		}
	}
	return ret;
}

static int send_dev_cmd(int fd, int fam, int cmd, unsigned int idx)
{
	struct sockaddr_nl addr;
	struct {
		struct nlmsghdr n;
		struct genlmsghdr g;
		char buf[64];
	} req;
	struct nlattr *na;

	memset(&addr, 0, sizeof(addr));
	addr.nl_family = AF_NETLINK;

	memset(&req, 0, sizeof(req));
	req.n.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
	req.n.nlmsg_type = fam;
	req.n.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
	req.n.nlmsg_seq = 2;
	req.g.cmd = cmd;
	req.g.version = 1;

	na = (struct nlattr *)((char *)&req + req.n.nlmsg_len);
	na->nla_type = NFC_ATTR_DEVICE_INDEX;
	na->nla_len = NLA_HDRLEN + sizeof(unsigned int);
	memcpy((char *)na + NLA_HDRLEN, &idx, sizeof(idx));
	req.n.nlmsg_len += NLA_ALIGN(na->nla_len);

	if (sendto(fd, &req, req.n.nlmsg_len, 0,
		   (struct sockaddr *)&addr, sizeof(addr)) < 0)
		return -1;
	return 0;
}

static int start_poll(int fd, int fam, unsigned int idx, unsigned int protos)
{
	struct sockaddr_nl addr;
	struct {
		struct nlmsghdr n;
		struct genlmsghdr g;
		char buf[128];
	} req;
	struct nlattr *na;
	unsigned char rf_mode = 1;	/* NFC_RF_PASSIVE_MODE */

	memset(&addr, 0, sizeof(addr));
	addr.nl_family = AF_NETLINK;

	memset(&req, 0, sizeof(req));
	req.n.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
	req.n.nlmsg_type = fam;
	req.n.nlmsg_flags = NLM_F_REQUEST;
	req.n.nlmsg_seq = 3;
	req.g.cmd = NFC_CMD_START_POLL;
	req.g.version = 1;

	na = (struct nlattr *)((char *)&req + req.n.nlmsg_len);
	na->nla_type = NFC_ATTR_DEVICE_INDEX;
	na->nla_len = NLA_HDRLEN + sizeof(unsigned int);
	memcpy((char *)na + NLA_HDRLEN, &idx, sizeof(idx));
	req.n.nlmsg_len += NLA_ALIGN(na->nla_len);

	na = (struct nlattr *)((char *)&req + req.n.nlmsg_len);
	na->nla_type = NFC_ATTR_IM_PROTOCOLS;
	na->nla_len = NLA_HDRLEN + sizeof(unsigned int);
	memcpy((char *)na + NLA_HDRLEN, &protos, sizeof(protos));
	req.n.nlmsg_len += NLA_ALIGN(na->nla_len);

	na = (struct nlattr *)((char *)&req + req.n.nlmsg_len);
	na->nla_type = NFC_ATTR_RF_MODE;
	na->nla_len = NLA_HDRLEN + sizeof(rf_mode);
	memcpy((char *)na + NLA_HDRLEN, &rf_mode, sizeof(rf_mode));
	req.n.nlmsg_len += NLA_ALIGN(na->nla_len);

	if (sendto(fd, &req, req.n.nlmsg_len, 0,
		   (struct sockaddr *)&addr, sizeof(addr)) < 0)
		return -1;
	return 0;
}

static void now_str(char *b, size_t n)
{
	time_t t = time(NULL);
	struct tm tm;

	localtime_r(&t, &tm);
	strftime(b, n, "%H:%M:%S", &tm);
}

/* 从 "NCIRAW RX: 61 05 15 01 01 02 00 ff 01 0a 04 00 04 bc ..." 提取 UID */
static void parse_nci_line(const char *line)
{
	unsigned char buf[64];
	int n = 0, i, off;
	const char *p;
	char ts[16];
	unsigned int sel_res = 0, sens_res = 0;

	p = strstr(line, "NCIRAW RX:");
	if (!p)
		return;
	p += 10;

	while (n < (int)sizeof(buf)) {
		int v;
		char *end;

		while (*p == ' ')
			p++;
		if (!*p || *p == '\n')
			break;
		v = (int)strtol(p, &end, 16);
		if (end == p)
			break;
		buf[n++] = (unsigned char)v;
		p = end;
	}

	/* RF_INTF_ACTIVATED_NTF: 61 05 len | id iface proto tech bitrate credits
	 *                        plen | sens_res(2) uid_len uid... sel_len sel
	 */
	if (n < 14 || buf[0] != 0x61 || buf[1] != 0x05)
		return;

	off = 7;			/* 跳过 3 字节头 + 6 字节固定字段前 4 个 */
	/* buf[0..2] = 61 05 len
	 * buf[3]=id buf[4]=iface buf[5]=proto buf[6]=tech
	 * buf[7]=bitrate buf[8]=credits buf[9]=params_len
	 */
	{
		int plen = buf[9];

		if (plen < 3)
			return;
		sens_res = buf[10] | (buf[11] << 8);
		{
			int uid_len = buf[12];

			if (uid_len < 1 || uid_len > 10 || 13 + uid_len > n)
				return;
			now_str(ts, sizeof(ts));
			printf("[%s] ★ 卡片 UID =", ts);
			for (i = 0; i < uid_len; i++)
				printf(" %02X", buf[13 + i]);
			if (13 + uid_len + 1 < n)
				sel_res = buf[13 + uid_len + 1];
			printf("   (SENS_RES=%04X SEL_RES=%02X 协议=%u)\n",
			       sens_res, sel_res, buf[5]);
			fflush(stdout);
		}
	}
}

int main(int argc, char **argv)
{
	int nlfd, fam, kmfd;
	unsigned int idx = 0;

	if (argc > 1)
		idx = atoi(argv[1]);

	setvbuf(stdout, NULL, _IONBF, 0);

	nlfd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
	if (nlfd < 0) {
		perror("socket netlink");
		return 1;
	}
	fam = resolve_family(nlfd, "nfc");
	if (fam < 0) {
		fprintf(stderr, "找不到 nfc netlink 家族\n");
		return 1;
	}

	send_dev_cmd(nlfd, fam, NFC_CMD_DEV_UP, idx);
	usleep(600000);
	start_poll(nlfd, fam, idx, 0x1f);
	printf("NFC 已启动（设备 %u），开始监听...\n", idx);

	kmfd = open("/dev/kmsg", O_RDONLY | O_NONBLOCK);
	if (kmfd < 0)
		fprintf(stderr, "打开 /dev/kmsg 失败，UID 不会显示\n");

	for (;;) {
		struct pollfd pf[2];
		int nf = 1, r;

		pf[0].fd = nlfd;
		pf[0].events = POLLIN;
		if (kmfd >= 0) {
			pf[1].fd = kmfd;
			pf[1].events = POLLIN;
			nf = 2;
		}

		r = poll(pf, nf, 2000);
		if (r < 0 && errno != EINTR) {
			perror("poll");
			break;
		}
		if (r <= 0)
			continue;

		if (pf[0].revents & POLLIN) {
			char buf[4096];
			int len = recv(nlfd, buf, sizeof(buf), 0);

			if (len > 0) {
				struct nlmsghdr *nh = (struct nlmsghdr *)buf;

				if (nh->nlmsg_type != NLMSG_ERROR) {
					struct genlmsghdr *gh =
						(struct genlmsghdr *)
						NLMSG_DATA(nh);
					char ts[16];

					now_str(ts, sizeof(ts));
					if (gh->cmd == NFC_EVENT_TARGETS_FOUND)
						printf("[%s] 检测到卡片（事件）\n",
						       ts);
					else
						printf("[%s] NFC 事件 cmd=%d\n",
						       ts, gh->cmd);
				}
			}
		}

		if (nf > 1 && (pf[1].revents & POLLIN)) {
			char line[512];
			int len = read(kmfd, line, sizeof(line) - 1);

			if (len > 0) {
				line[len] = 0;
				parse_nci_line(line);
			}
		}
	}

	return 0;
}
