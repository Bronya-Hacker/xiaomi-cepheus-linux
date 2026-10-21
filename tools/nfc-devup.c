/*
 * nfc-devup.c —— 通过 NFC netlink 打开/关闭 NFC 设备
 *
 * 打开时会触发内核 nci 核心发 NCI_RST（CORE_RESET），
 * 随后 CORE_INIT。这是我们验证 nxp-nci 读协议是否修好的关键测试。
 *
 * 编译： gcc -O2 -o nfc-devup nfc-devup.c
 * 用法： ./nfc-devup up|down [设备号]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <poll.h>
#include <errno.h>
#include <sys/socket.h>
#include <linux/netlink.h>
#include <linux/genetlink.h>
#include <linux/nfc.h>

/* 用户态没有这两个宏，自己定义 */
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

static int send_cmd(int fd, int fam, int cmd, unsigned int idx)
{
	struct sockaddr_nl addr;
	struct {
		struct nlmsghdr n;
		struct genlmsghdr g;
		char buf[64];
	} req;
	struct nlattr *na;
	int len;

	memset(&addr, 0, sizeof(addr));
	addr.nl_family = AF_NETLINK;
	addr.nl_pid = 0;
	addr.nl_groups = 0;

	memset(&req, 0, sizeof(req));
	req.n.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
	req.n.nlmsg_type = fam;
	req.n.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
	req.n.nlmsg_seq = 1;
	req.g.cmd = cmd;
	req.g.version = 1;

	na = (struct nlattr *)((char *)&req + req.n.nlmsg_len);
	na->nla_type = NFC_ATTR_DEVICE_INDEX;
	na->nla_len = NLA_HDRLEN + sizeof(unsigned int);
	memcpy((char *)na + NLA_HDRLEN, &idx, sizeof(idx));
	req.n.nlmsg_len += NLA_ALIGN(na->nla_len);

	if (sendto(fd, &req, req.n.nlmsg_len, 0,
		   (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		perror("sendto");
		return -1;
	}

	/* 读回内核的 ACK/错误，否则根本不知道请求有没有被接受 */
	{
		char resp[1024];
		int n = recv(fd, resp, sizeof(resp), 0);

		if (n < 0) {
			perror("recv ack");
			return -1;
		}
		{
			struct nlmsghdr *nh = (struct nlmsghdr *)resp;

			if (nh->nlmsg_type == NLMSG_ERROR) {
				struct nlmsgerr *e = (struct nlmsgerr *)NLMSG_DATA(nh);

				if (e->error)
					printf("内核返回错误: %d (%s)\n", e->error,
					       strerror(-e->error));
				else
					printf("内核确认成功\n");
			}
		}
	}
	return 0;
}

/* 用 genl ctrl 解析 "nfc" 家族的 id */
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
		   (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		perror("sendto ctrl");
		return -1;
	}

	len = recv(fd, resp, sizeof(resp), 0);
	if (len < 0) {
		perror("recv ctrl");
		return -1;
	}

	{
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

/* 启动 RF 轮询（找卡）。协议位图：JEWEL=1 MIFARE=2 FELICA=4 ISO14443=8 ISO15693=16 */
static int start_poll(int fd, int fam, unsigned int idx, unsigned int protos)
{
	struct sockaddr_nl addr;
	struct {
		struct nlmsghdr n;
		struct genlmsghdr g;
		char buf[128];
	} req;
	struct nlattr *na;
	int len;
	unsigned char rf_mode = 1;	/* NFC_RF_PASSIVE_MODE，内核要 u8 */

	memset(&addr, 0, sizeof(addr));
	addr.nl_family = AF_NETLINK;

	memset(&req, 0, sizeof(req));
	req.n.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
	req.n.nlmsg_type = fam;
	req.n.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
	req.n.nlmsg_seq = 2;
	req.g.cmd = NFC_CMD_START_POLL;
	req.g.version = 1;

	na = (struct nlattr *)((char *)&req + req.n.nlmsg_len);
	na->nla_type = NFC_ATTR_DEVICE_INDEX;
	na->nla_len = NLA_HDRLEN + sizeof(unsigned int);
	memcpy((char *)na + NLA_HDRLEN, &idx, sizeof(idx));
	req.n.nlmsg_len += NLA_ALIGN(na->nla_len);

	na = (struct nlattr *)((char *)&req + req.n.nlmsg_len);
	na->nla_type = NFC_ATTR_PROTOCOLS;
	na->nla_len = NLA_HDRLEN + sizeof(unsigned int);
	memcpy((char *)na + NLA_HDRLEN, &protos, sizeof(protos));
	req.n.nlmsg_len += NLA_ALIGN(na->nla_len);

	na = (struct nlattr *)((char *)&req + req.n.nlmsg_len);
	na->nla_type = NFC_ATTR_RF_MODE;
	na->nla_len = NLA_HDRLEN + sizeof(rf_mode);
	memcpy((char *)na + NLA_HDRLEN, &rf_mode, sizeof(rf_mode));
	req.n.nlmsg_len += NLA_ALIGN(na->nla_len);

	if (sendto(fd, &req, req.n.nlmsg_len, 0,
		   (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		perror("sendto poll");
		return -1;
	}
	{
		char resp[1024];
		int n = recv(fd, resp, sizeof(resp), 0);

		if (n > 0) {
			struct nlmsghdr *nh = (struct nlmsghdr *)resp;

			if (nh->nlmsg_type == NLMSG_ERROR) {
				struct nlmsgerr *e = (struct nlmsgerr *)NLMSG_DATA(nh);

				if (e->error)
					printf("轮询失败: %d (%s)\n", e->error,
					       strerror(-e->error));
				else
					printf("轮询已启动\n");
			}
		}
	}
	return 0;
}
/* 订阅 nfc 多播组，打印内核推上来的事件（找卡、丢卡等） */
static int listen_events(int fd, const char *name, int seconds)
{
	struct sockaddr_nl addr;
	struct {
		struct nlmsghdr n;
		struct genlmsghdr g;
		char buf[128];
	} req;
	struct nlattr *na;
	char resp[8192];
	int len, group = -1, i;

	memset(&addr, 0, sizeof(addr));
	addr.nl_family = AF_NETLINK;

	memset(&req, 0, sizeof(req));
	req.n.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
	req.n.nlmsg_type = GENL_ID_CTRL;
	req.n.nlmsg_flags = NLM_F_REQUEST;
	req.n.nlmsg_seq = 7;
	req.g.cmd = CTRL_CMD_GETFAMILY;
	req.g.version = 1;

	na = (struct nlattr *)((char *)&req + req.n.nlmsg_len);
	na->nla_type = CTRL_ATTR_FAMILY_NAME;
	na->nla_len = NLA_HDRLEN + strlen(name) + 1;
	strcpy((char *)na + NLA_HDRLEN, name);
	req.n.nlmsg_len += NLA_ALIGN(na->nla_len);

	if (sendto(fd, &req, req.n.nlmsg_len, 0,
		   (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		perror("sendto groups");
		return -1;
	}
	len = recv(fd, resp, sizeof(resp), 0);
	if (len > 0) {
		struct nlmsghdr *nh = (struct nlmsghdr *)resp;
		struct genlmsghdr *gh = (struct genlmsghdr *)NLMSG_DATA(nh);
		struct nlattr *a;
		int alen = nh->nlmsg_len - NLMSG_LENGTH(GENL_HDRLEN);

		for (a = (struct nlattr *)((char *)gh + GENL_HDRLEN);
		     NLA_OK(a, alen); a = NLA_NEXT(a, alen)) {
			if (a->nla_type == CTRL_ATTR_MCAST_GROUPS) {
				/* 嵌套结构：每个子属性是一个组，
				 * 里面有 GRP_NAME 和 GRP_ID。
				 */
				struct nlattr *g;
				int glen = a->nla_len - NLA_HDRLEN;

				for (g = (struct nlattr *)((char *)a + NLA_HDRLEN);
				     NLA_OK(g, glen); g = NLA_NEXT(g, glen)) {
					struct nlattr *x;
					int xlen = g->nla_len - NLA_HDRLEN;

					for (x = (struct nlattr *)((char *)g + NLA_HDRLEN);
					     NLA_OK(x, xlen); x = NLA_NEXT(x, xlen)) {
						if (x->nla_type == CTRL_ATTR_MCAST_GRP_ID) {
							group = *(unsigned int *)((char *)x + NLA_HDRLEN);
							printf("找到多播组 id=%d\n", group);
						}
					}
					if (group > 0)
						break;
				}
				break;
			}
		}
	}

	/* 已 sendto 过的 socket 不能再 bind，单独开一个订阅用 */
	{
		struct sockaddr_nl sa;
		int lfd;

		lfd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
		if (lfd < 0) {
			perror("socket listen");
			return -1;
		}
		memset(&sa, 0, sizeof(sa));
		sa.nl_family = AF_NETLINK;
		sa.nl_groups = (group > 0) ? (1u << (group - 1)) : 1u;
		if (bind(lfd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
			perror("bind group");
			return -1;
		}
		fd = lfd;
	}

	printf("开始监听 NFC 事件 %d 秒（请把卡贴到手机背面）...\n", seconds);
	for (i = 0; i < seconds * 5; i++) {
		struct pollfd pfd = { .fd = fd, .events = POLLIN };
		int pr = poll(&pfd, 1, 200);

		if (pr > 0 && (pfd.revents & POLLIN)) {
			len = recv(fd, resp, sizeof(resp), 0);
			if (len > 0) {
				struct nlmsghdr *nh = (struct nlmsghdr *)resp;
				struct genlmsghdr *gh;

				if (nh->nlmsg_type == NLMSG_ERROR)
					continue;
				gh = (struct genlmsghdr *)NLMSG_DATA(nh);
				printf(">>> NFC 事件 cmd=%d len=%d\n",
				       gh->cmd, nh->nlmsg_len);
				{
					struct nlattr *a;
					int alen = nh->nlmsg_len -
						   NLMSG_LENGTH(GENL_HDRLEN);

					for (a = (struct nlattr *)((char *)gh +
								GENL_HDRLEN);
					     NLA_OK(a, alen);
					     a = NLA_NEXT(a, alen))
						printf("    attr type=%d len=%d\n",
						       a->nla_type, a->nla_len);
				}
			}
		}
	}
	return 0;
}

int main(int argc, char **argv)
{
	int fd, fam;
	unsigned int idx = 0;

	if (argc < 2) {
		printf("用法: %s up|down [设备号]\n", argv[0]);
		return 1;
	}
	if (argc > 2)
		idx = atoi(argv[2]);

	fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
	if (fd < 0) {
		perror("socket");
		return 1;
	}

	fam = resolve_family(fd, "nfc");
	if (fam < 0) {
		printf("找不到 nfc netlink 家族\n");
		return 1;
	}

	if (!strcmp(argv[1], "listen")) {
		listen_events(fd, "nfc", 30);
	} else if (!strcmp(argv[1], "poll")) {
		start_poll(fd, fam, idx, 0x1f);
	} else if (!strcmp(argv[1], "up")) {
		if (send_cmd(fd, fam, NFC_CMD_DEV_UP, idx) == 0)
			printf("已请求 DEV_UP (idx=%u)\n", idx);
	} else {
		if (send_cmd(fd, fam, NFC_CMD_DEV_DOWN, idx) == 0)
			printf("已请求 DEV_DOWN (idx=%u)\n", idx);
	}

	sleep(1);
	return 0;
}
