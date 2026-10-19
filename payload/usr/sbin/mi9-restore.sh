#!/bin/sh
# ---------------------------------------------------------------------------
# mi9-restore.sh -- 从 mi9-snapshot 的归档恢复配置层
#
# 默认是 **dry-run**（只列出差异，不动任何文件）。确认后加 --yes。
#
# 用法：
#   mi9-restore.sh /root/snapshots/mi9-cfg-20261019-150000-2026-10-19-srv8.tar.gz
#   mi9-restore.sh <归档> --yes          # 真恢复 /etc（先自动备份当前 /etc）
#   mi9-restore.sh <归档> --yes --all    # 同时恢复 /root 下的运维脚本
#
# 行为：
#   1) 有 .sha256 就先校验；
#   2) 解包到 /tmp，`diff -rq` 列出差异（dry-run 到此为止）；
#   3) --yes：先把当前 /etc 打包到 /root/snapshots/pre-restore-<时间>.tar.gz，
#      再用 tar 覆盖回 /etc（保留权限）；
#   4) 提示 reboot（systemd / NetworkManager 需要重新加载）。
#
# ★ 注意：如果快照里的 WiFi 口令与当前不同，恢复后网络会按快照走。
#   通过 USB（169.254.42.1）操作最安全。
# ---------------------------------------------------------------------------
set -u

ARCHIVE=""
YES=0
ALL=0
for a in "$@"; do
	case "$a" in
		--yes) YES=1 ;;
		--all) ALL=1 ;;
		-h|--help)
			sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
			exit 0 ;;
		-*) echo "未知参数: $a" >&2; exit 1 ;;
		*)  ARCHIVE="$a" ;;
	esac
done

if [ -z "$ARCHIVE" ]; then
	echo "用法: mi9-restore.sh <snapshot.tar.gz> [--yes] [--all]" >&2
	exit 1
fi
[ -r "$ARCHIVE" ] || { echo "读不到归档: $ARCHIVE" >&2; exit 1; }

# --- 校验 ---
if [ -r "$ARCHIVE.sha256" ]; then
	if ! ( cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$ARCHIVE").sha256" >/dev/null 2>&1 ); then
		echo "sha256 校验失败，拒绝恢复: $ARCHIVE" >&2
		exit 1
	fi
	echo "sha256: ok"
fi

STAGE=$(mktemp -d /tmp/mi9-restore.XXXXXX) || exit 1
trap 'rm -rf "$STAGE"' EXIT
tar -xzf "$ARCHIVE" -C "$STAGE" 2>/dev/null || { echo "解包失败" >&2; exit 1; }
[ -d "$STAGE/etc" ] || { echo "归档里没有 etc/，不是 mi9-snapshot 的产物" >&2; exit 1; }

echo "== 快照信息 =="
cat "$STAGE/meta.txt" 2>/dev/null || echo "(无 meta.txt)"
echo
echo "== 与当前 /etc 的差异（前 40 行）=="
diff -rq /etc "$STAGE/etc" 2>/dev/null | head -40
echo

if [ "$YES" != 1 ]; then
	echo "dry-run：没有改动任何文件。确认无误后加 --yes。"
	exit 0
fi

# --- 先备份当前 /etc ---
BK="/root/snapshots/pre-restore-$(date +%Y%m%d-%H%M%S).tar.gz"
mkdir -p /root/snapshots
if tar -czf "$BK" -C / etc 2>/dev/null; then
	echo "当前 /etc 已备份: $BK ($(du -h "$BK" | cut -f1))"
else
	echo "备份当前 /etc 失败，已中止" >&2
	exit 1
fi

# --- 覆盖恢复 ---
echo "恢复 /etc ..."
if ! ( cd "$STAGE" && tar -cf - etc ) | ( cd / && tar -xpf - ); then
	echo "恢复失败；可用上面的备份回滚：" >&2
	echo "  tar -xzf $BK -C /" >&2
	exit 1
fi

if [ "$ALL" = 1 ] && [ -d "$STAGE/root-scripts" ]; then
	echo "恢复 /root 脚本 ..."
	find "$STAGE/root-scripts" -maxdepth 1 -type f -exec cp -a {} /root/ \; 2>/dev/null
fi

echo
echo "完成。建议 reboot：systemd / NetworkManager / sshd 都需要重新加载配置。"
echo "回滚（如果恢复后不对劲）：tar -xzf $BK -C / && reboot"
