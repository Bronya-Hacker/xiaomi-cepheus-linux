// mi9-nfc-poll: 用 NFC netlink 接口轮询标签并打印 UID
//
// 用法: mi9-nfc-poll [秒数]      (默认 15 秒)
//
// 不需要 nfctool / neard：直接走 AF_NETLINK + NETLINK_NFC + genl family "nfc"。
// 流程: DEV_UP -> START_POLL(ISO14443A) -> 等 TARGETS_FOUND -> GET_TARGET -> 打印 NFCID1

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>
#include <sys/socket.h>
#include <linux/netlink.h>
#include <linux/genetlink.h>
#include <linux/nfc.h>

#ifndef NLA_OK
#define NLA_OK(nla, len) \
	((len) >= (int)sizeof(struct nlattr) && \
	 (nla)->nla_len >= sizeof(struct nlattr) && \
	 (nla)->nla_len <= (len))
#endif
#ifndef NLA_NEXT
#define NLA_NEXT(nla, attrlen) \
	((attrlen) -= NLA_ALIGN((nla)->nla_len), \
	 (struct nlattr *)(((char *)(nla)) + NLA_ALIGN((nla)->nla_len)))
#endif

#define BUF_SIZE 4096

static int nl_fd = -1;
static int nfc_family = -1;
static unsigned int nl_seq = 0;

struct attr_buf {
	unsigned char buf[BUF_SIZE];
	int len;
};

static void attr_put(struct attr_buf *a, int type, const void *data, int len)
{
	struct nlattr *na = (struct nlattr *)(a->buf + a->len);

	na->nla_type = type;
	na->nla_len = NLA_HDRLEN + len;
	if (a->len + NLA_ALIGN(na->nla_len) > BUF_SIZE) {
		fprintf(stderr, "attr buffer overflow\n");
		exit(1);
	}
	memcpy((char *)na + NLA_HDRLEN, data, len);
	a->len += NLA_ALIGN(na->nla_len);
}

static void attr_put_u32(struct attr_buf *a, int type, unsigned int v)
{
	attr_put(a, type, &v, sizeof(v));
}

static int nl_send(int cmd, int flags, struct attr_buf *attrs)
{
	unsigned char buf[BUF_SIZE];
	struct nlmsghdr *nlh = (struct nlmsghdr *)buf;
	struct genlmsghdr *gh;
	int len;

	memset(buf, 0, sizeof(buf));
	nlh->nlmsg_type = nfc_family;
	nlh->nlmsg_flags = NLM_F_REQUEST | flags;
	nlh->nlmsg_seq = ++nl_seq;

	gh = (struct genlmsghdr *)NLMSG_DATA(nlh);
	gh->cmd = cmd;
	gh->version = 0;

	len = NLMSG_HDRLEN + GENL_HDRLEN;
	if (attrs) {
		memcpy(buf + len, attrs->buf, attrs->len);
		len += attrs->len;
	}
	nlh->nlmsg_len = NLMSG_ALIGN(len);

	if (send(nl_fd, buf, nlh->nlmsg_len, 0) < 0) {
		perror("send");
		return -1;
	}
	return 0;
}

static struct nlattr *nl_attr_find(struct nlmsghdr *nlh, int attrtype)
{
	int len = nlh->nlmsg_len - NLMSG_HDRLEN - GENL_HDRLEN;
	struct nlattr *na = (struct nlattr *)((char *)NLMSG_DATA(nlh) + GENL_HDRLEN);

	while (NLA_OK(na, len)) {
		if (na->nla_type == attrtype)
			return na;
		na = NLA_NEXT(na, len);
	}
	return NULL;
}

static int resolve_family(const char *name)
{
	unsigned char buf[BUF_SIZE];
	struct nlmsghdr *nlh = (struct nlmsghdr *)buf;
	struct genlmsghdr *gh;
	struct attr_buf attrs;
	int len, ret;

	memset(&attrs, 0, sizeof(attrs));
	attr_put(&attrs, CTRL_ATTR_FAMILY_NAME, name, strlen(name) + 1);

	memset(buf, 0, sizeof(buf));
	nlh->nlmsg_type = GENL_ID_CTRL;
	nlh->nlmsg_flags = NLM_F_REQUEST;
	nlh->nlmsg_seq = ++nl_seq;

	gh = (struct genlmsghdr *)NLMSG_DATA(nlh);
	gh->cmd = CTRL_CMD_GETFAMILY;
	gh->version = 1;

	len = NLMSG_HDRLEN + GENL_HDRLEN;
	memcpy(buf + len, attrs.buf, attrs.len);
	len += attrs.len;
	nlh->nlmsg_len = NLMSG_ALIGN(len);

	if (send(nl_fd, buf, nlh->nlmsg_len, 0) < 0)
		return -1;

	ret = recv(nl_fd, buf, sizeof(buf), 0);
	if (ret < 0)
		return -1;

	for (nlh = (struct nlmsghdr *)buf; NLMSG_OK(nlh, ret); nlh = NLMSG_NEXT(nlh, ret)) {
		struct nlattr *na = nl_attr_find(nlh, CTRL_ATTR_FAMILY_ID);

		if (na)
			return *(unsigned short *)((char *)na + NLA_HDRLEN);
	}
	return -1;
}

static void print_hex(const char *label, const unsigned char *d, int len)
{
	int i;

	printf("%s", label);
	for (i = 0; i < len; i++)
		printf("%02x", d[i]);
	printf("\n");
}

static void dump_target(struct nlmsghdr *nlh)
{
	struct nlattr *na;
	unsigned int target_idx = 0, protocols = 0;

	na = nl_attr_find(nlh, NFC_ATTR_TARGET_INDEX);
	if (na)
		target_idx = *(unsigned int *)((char *)na + NLA_HDRLEN);

	na = nl_attr_find(nlh, NFC_ATTR_PROTOCOLS);
	if (na)
		protocols = *(unsigned int *)((char *)na + NLA_HDRLEN);

	printf("  目标 #%u  协议位掩码 0x%08x\n", target_idx, protocols);

	na = nl_attr_find(nlh, NFC_ATTR_TARGET_NFCID1);
	if (na) {
		int len = na->nla_len - NLA_HDRLEN;

		print_hex("  UID (NFCID1): ", (unsigned char *)na + NLA_HDRLEN, len);
	} else {
		printf("  （没有 NFCID1，可能不是 Type 2 标签）\n");
	}

	na = nl_attr_find(nlh, NFC_ATTR_TARGET_SENS_RES);
	if (na)
		print_hex("  SENS_RES: ", (unsigned char *)na + NLA_HDRLEN,
			  na->nla_len - NLA_HDRLEN);
}

int main(int argc, char **argv)
{
	struct sockaddr_nl sa;
	struct timeval tv;
	int timeout = (argc > 1) ? atoi(argv[1]) : 15;
	int found_total = 0;
	time_t deadline;

	nl_fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
	if (nl_fd < 0) {
		perror("socket(NETLINK_NFC)");
		return 1;
	}

	memset(&sa, 0, sizeof(sa));
	sa.nl_family = AF_NETLINK;
	if (bind(nl_fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		perror("bind");
		return 1;
	}

	nfc_family = resolve_family("nfc");
	if (nfc_family < 0) {
		fprintf(stderr, "找不到 nfc genl family（NFC 核心没加载？）\n");
		return 1;
	}
	printf("nfc genl family id = %d\n", nfc_family);

	{
		struct attr_buf a;

		memset(&a, 0, sizeof(a));
		attr_put_u32(&a, NFC_ATTR_DEVICE_INDEX, 0);
		if (nl_send(NFC_CMD_DEV_UP, 0, &a) < 0)
			return 1;
	}

	{
		struct attr_buf a;
		unsigned int rf_mode = NFC_RF_INITIATOR;
		unsigned int protos = NFC_PROTO_ISO14443_MASK | NFC_PROTO_MIFARE_MASK |
				      NFC_PROTO_FELICA_MASK | NFC_PROTO_ISO14443_B_MASK;

		memset(&a, 0, sizeof(a));
		attr_put_u32(&a, NFC_ATTR_DEVICE_INDEX, 0);
		attr_put_u32(&a, NFC_ATTR_RF_MODE, rf_mode);
		attr_put_u32(&a, NFC_ATTR_PROTOCOLS, protos);
		if (nl_send(NFC_CMD_START_POLL, 0, &a) < 0)
			return 1;
	}

	printf("开始轮询（%d 秒）… 把标签贴到手机背面\n", timeout);

	tv.tv_sec = 1;
	tv.tv_usec = 0;
	setsockopt(nl_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

	deadline = time(NULL) + timeout;
	while (time(NULL) < deadline) {
		unsigned char buf[BUF_SIZE];
		struct nlmsghdr *nlh;
		int len = recv(nl_fd, buf, sizeof(buf), 0);

		if (len < 0) {
			if (errno == EAGAIN || errno == EWOULDBLOCK)
				continue;
			perror("recv");
			break;
		}

		for (nlh = (struct nlmsghdr *)buf; NLMSG_OK(nlh, len);
		     nlh = NLMSG_NEXT(nlh, len)) {
			struct genlmsghdr *gh;
			struct attr_buf a;

			if (nlh->nlmsg_type == NLMSG_ERROR) {
				struct nlmsgerr *err = (struct nlmsgerr *)NLMSG_DATA(nlh);

				if (err->error)
					fprintf(stderr, "netlink error: %s\n",
						strerror(-err->error));
				continue;
			}

			if (nlh->nlmsg_type != nfc_family)
				continue;

			gh = (struct genlmsghdr *)NLMSG_DATA(nlh);
			if (gh->cmd == NFC_EVENT_TARGETS_FOUND) {
				printf("找到标签！\n");
				found_total++;
				memset(&a, 0, sizeof(a));
				attr_put_u32(&a, NFC_ATTR_DEVICE_INDEX, 0);
				nl_send(NFC_CMD_GET_TARGET, NLM_F_DUMP, &a);
			} else if (gh->cmd == NFC_CMD_GET_TARGET) {
				dump_target(nlh);
			}
		}
	}

	{
		struct attr_buf a;

		memset(&a, 0, sizeof(a));
		attr_put_u32(&a, NFC_ATTR_DEVICE_INDEX, 0);
		nl_send(NFC_CMD_STOP_POLL, 0, &a);
	}

	printf("结束，共发现 %d 次\n", found_total);
	close(nl_fd);
	return 0;
}
