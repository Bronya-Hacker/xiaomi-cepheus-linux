/*
 * nfc-poll-netlink.c —�?�?NFC generic netlink �?NQ 芯片轮询附近的卡
 *
 * 主线内核�?NCI 不暴露字符设�?套接字，用户态通过 NFC netlink 控制�? *   NFC_CMD_DEV_UP -> NFC_CMD_START_POLL -> 反复 NFC_CMD_GET_TARGET
 *
 * 编译�?gcc -O2 -o nfc-poll-netlink nfc-poll-netlink.c
 * 运行�?./nfc-poll-netlink [秒数]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <linux/netlink.h>
#include <linux/genetlink.h>

/* �ں��ڲ��꣬�û�̬ͷ�ļ���û�У��Լ��� */
#ifndef NLA_ALIGNTO
#define NLA_ALIGNTO 4
#endif
#ifndef NLA_ALIGN
#define NLA_ALIGN(len) (((len) + NLA_ALIGNTO - 1) & ~(NLA_ALIGNTO - 1))
#endif
#ifndef NLA_HDRLEN
#define NLA_HDRLEN ((int)NLA_ALIGN(sizeof(struct nlattr)))
#endif
#ifndef NLA_TYPE_MASK
#define NLA_TYPE_MASK 0x3fff
#endif
#define NLA_OK(nla, len) ((len) >= (int)sizeof(struct nlattr) && (nla)->nla_len >= sizeof(struct nlattr) && (nla)->nla_len <= (len))
#define NLA_NEXT(nla, attrlen) ((attrlen) -= NLA_ALIGN((nla)->nla_len), (struct nlattr *)(((char *)(nla)) + NLA_ALIGN((nla)->nla_len)))
#define NFC_GENL_NAME    "nfc"
#define NFC_GENL_VERSION 1

enum {
	NFC_CMD_UNSPEC,
	NFC_CMD_GET_DEVICE,
	NFC_CMD_DEV_UP,
	NFC_CMD_DEV_DOWN,
	NFC_CMD_DEP_LINK_UP,
	NFC_CMD_DEP_LINK_DOWN,
	NFC_CMD_START_POLL,
	NFC_CMD_STOP_POLL,
	NFC_CMD_GET_TARGET,
};

enum {
	NFC_ATTR_UNSPEC,
	NFC_ATTR_DEVICE_INDEX,
	NFC_ATTR_DEVICE_NAME,
	NFC_ATTR_PROTOCOLS,
	NFC_ATTR_TARGET_INDEX,
	NFC_ATTR_TARGET_SENS_RES,
	NFC_ATTR_TARGET_SEL_RES,
	NFC_ATTR_TARGET_NFCID1,
	NFC_ATTR_TARGET_SENSB_RES,
	NFC_ATTR_TARGET_SENSF_RES,
	NFC_ATTR_COMM_MODE,
	NFC_ATTR_RF_MODE,
};

#define NFC_PROTO_MIFARE     2
#define NFC_PROTO_FELICA     3
#define NFC_PROTO_ISO14443   4
#define NFC_PROTO_ISO14443_B 7

#define NFC_RF_INITIATOR 2

static int nl_fd = -1;
static int nfc_family = -1;

static int nl_open(void)
{
	struct sockaddr_nl sa;

	nl_fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
	if (nl_fd < 0) {
		perror("netlink socket");
		return -1;
	}
	memset(&sa, 0, sizeof(sa));
	sa.nl_family = AF_NETLINK;
	if (bind(nl_fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		perror("netlink bind");
		return -1;
	}
	return 0;
}

static int genl_resolve(const char *name)
{
	struct {
		struct nlmsghdr n;
		struct genlmsghdr g;
		char buf[128];
	} req;
	struct nlattr *na;
	char resp[4096];
	int len;

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

	if (send(nl_fd, &req, req.n.nlmsg_len, 0) < 0) {
		perror("send getfamily");
		return -1;
	}
	len = recv(nl_fd, resp, sizeof(resp), 0);
	if (len < 0) {
		perror("recv getfamily");
		return -1;
	}
	{
		struct nlmsghdr *nh = (struct nlmsghdr *)resp;
		int off = NLMSG_HDRLEN + GENL_HDRLEN;
		int rem = nh->nlmsg_len - off;

		if (nh->nlmsg_type == NLMSG_ERROR) {
			printf("getfamily 失败\n");
			return -1;
		}
		if (rem > 0) {
			struct nlattr *a = (struct nlattr *)(resp + off);

			for (; NLA_OK(a, rem); a = NLA_NEXT(a, rem)) {
				if ((a->nla_type & NLA_TYPE_MASK) == CTRL_ATTR_FAMILY_ID) {
					nfc_family = *(unsigned short *)((char *)a + NLA_HDRLEN);
					return 0;
				}
			}
		}
	}
	return -1;
}

static int genl_send(int cmd, const void *extra, int extra_len)
{
	struct {
		struct nlmsghdr n;
		struct genlmsghdr g;
		char buf[256];
	} req;
	char resp[1024];
	int len;

	memset(&req, 0, sizeof(req));
	req.n.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
	req.n.nlmsg_type = nfc_family;
	req.n.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
	req.n.nlmsg_seq = 2;
	req.g.cmd = cmd;
	req.g.version = NFC_GENL_VERSION;
	if (extra && extra_len > 0) {
		memcpy(req.buf, extra, extra_len);
		req.n.nlmsg_len += extra_len;
	}
	if (send(nl_fd, &req, req.n.nlmsg_len, 0) < 0) {
		perror("send cmd");
		return -1;
	}
	len = recv(nl_fd, resp, sizeof(resp), 0);
	if (len >= (int)sizeof(struct nlmsghdr)) {
		struct nlmsghdr *nh = (struct nlmsghdr *)resp;

		if (nh->nlmsg_type == NLMSG_ERROR) {
			struct nlmsgerr *e = (struct nlmsgerr *)NLMSG_DATA(nh);

			if (e->error != 0) {
				printf("  命令 %d 失败: %s\n", cmd, strerror(-e->error));
				return -1;
			}
		}
	}
	return 0;
}

static void add_u32(char *buf, int *len, int type, unsigned int val)
{
	struct nlattr *a = (struct nlattr *)(buf + *len);

	a->nla_type = type;
	a->nla_len = NLA_HDRLEN + 4;
	memcpy((char *)a + NLA_HDRLEN, &val, 4);
	*len += NLA_ALIGN(a->nla_len);
}

int main(int argc, char **argv)
{
	int secs = (argc > 1) ? atoi(argv[1]) : 30;
	int i, found = 0;

	if (nl_open() < 0)
		return 1;
	if (genl_resolve(NFC_GENL_NAME) < 0) {
		printf("找不�?nfc 家族\n");
		return 1;
	}
	printf("nfc 家族 id = %d\n", nfc_family);

	{
		char b[64];
		int l = 0;

		add_u32(b, &l, NFC_ATTR_DEVICE_INDEX, 0);
		printf("DEV_UP ...\n");
		genl_send(NFC_CMD_DEV_UP, b, l);
	}

	{
		char b[64];
		int l = 0;
		unsigned int protos = (1u << NFC_PROTO_ISO14443) |
				      (1u << NFC_PROTO_ISO14443_B) |
				      (1u << NFC_PROTO_MIFARE) |
				      (1u << NFC_PROTO_FELICA);

		add_u32(b, &l, NFC_ATTR_DEVICE_INDEX, 0);
		add_u32(b, &l, NFC_ATTR_PROTOCOLS, protos);
		add_u32(b, &l, NFC_ATTR_RF_MODE, NFC_RF_INITIATOR);
		printf("START_POLL（现在请把卡贴到手机背面�?..\n");
		if (genl_send(NFC_CMD_START_POLL, b, l) < 0)
			return 1;
	}

	for (i = 0; i < secs * 2; i++) {
		char b[64];
		int l = 0;
		char resp[2048];
		int len;
		struct {
			struct nlmsghdr n;
			struct genlmsghdr g;
			char buf[64];
		} req;

		add_u32(b, &l, NFC_ATTR_DEVICE_INDEX, 0);
		memset(&req, 0, sizeof(req));
		req.n.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN) + l;
		req.n.nlmsg_type = nfc_family;
		req.n.nlmsg_flags = NLM_F_REQUEST;
		req.n.nlmsg_seq = 3 + i;
		req.g.cmd = NFC_CMD_GET_TARGET;
		req.g.version = NFC_GENL_VERSION;
		memcpy(req.buf, b, l);
		send(nl_fd, &req, req.n.nlmsg_len, 0);

		len = recv(nl_fd, resp, sizeof(resp), 0);
		if (len > 0) {
			struct nlmsghdr *nh = (struct nlmsghdr *)resp;
			int off = NLMSG_HDRLEN + GENL_HDRLEN;
			int rem = nh->nlmsg_len - off;

			if (nh->nlmsg_type != NLMSG_ERROR && rem > 0) {
				struct nlattr *a = (struct nlattr *)(resp + off);

				for (; NLA_OK(a, rem); a = NLA_NEXT(a, rem)) {
					int type = a->nla_type & NLA_TYPE_MASK;
					int n = a->nla_len - NLA_HDRLEN;
					unsigned char *p = (unsigned char *)a + NLA_HDRLEN;

					if (type == NFC_ATTR_TARGET_INDEX && n >= 4) {
						unsigned int ti;

						memcpy(&ti, p, 4);
						printf(">>> 发现目标！target_index=%u�?d 秒）\n",
						       ti, i / 2);
						found = 1;
					} else if (type == NFC_ATTR_TARGET_NFCID1 && n > 0) {
						int k;

						printf("    UID(%d):", n);
						for (k = 0; k < n; k++)
							printf(" %02x", p[k]);
						printf("\n");
					}
				}
			}
		}
		usleep(500 * 1000);
	}

	printf(found ? "轮询结束：发现过卡片\n" : "轮询结束：没发现卡片（贴近天线再试）\n");
	{
		char b[64];
		int l = 0;

		add_u32(b, &l, NFC_ATTR_DEVICE_INDEX, 0);
		genl_send(NFC_CMD_STOP_POLL, b, l);
	}
	return 0;
}
