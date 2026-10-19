#!/bin/sh
# ---------------------------------------------------------------------------
# mi9-snapshot.sh -- 打一个"配置基线"快照（不含系统包、不含大文件）
#
# 为什么需要它：
#   本机是"payload 覆盖层 + 手改 /etc"的混合体。payload 每次开机只会按版本号
#   解压一次，之后手工改的 /etc（NetworkManager、systemd、sysctl、SSH……）
#   不会被 payload 还原。想回到"刚刷完 srvN 那一刻"，需要一份配置快照。
#
# 快照内容（全部是文本，通常几 MB）：
#   etc/                 /etc 全量（含 NM 连接、unit、sysctl、sshd 配置）
#   root-scripts/        /root/*.sh（运维脚本；不含 60MB 的 kernelfat）
#   usr-local/           /usr/local（自定义命令）
#   dpkg-selections.txt  已装包列表（重装系统后一键核对）
#   unit-files.txt       systemd 单元启用状态
#   meta.txt             uname / 版本号 / 时间 / 磁盘
#
# 用法：
#   mi9-snapshot                 -> /root/snapshots/mi9-cfg-<时间>-<版本>.tar.gz
#   mi9-snapshot /path/dir       -> 指定目录
#   KEEP=3 mi9-snapshot          -> 只保留最近 3 份（默认 5）
#
# 还原：见 mi9-restore.sh（默认 dry-run）
# ---------------------------------------------------------------------------
set -u

DEST="${1:-/root/snapshots}"
KEEP="${KEEP:-5}"
TS=$(date +%Y%m%d-%H%M%S)
VER=$(cat /etc/wifi-cfg.ver 2>/dev/null | head -1)
[ -n "${VER:-}" ] || VER=unknown
OUT="$DEST/mi9-cfg-$TS-$VER.tar.gz"

mkdir -p "$DEST" || exit 1
STAGE=$(mktemp -d /tmp/mi9-snap.XXXXXX) || exit 1
trap 'rm -rf "$STAGE"' EXIT

echo "[1/4] 收集 /etc ..."
cp -a /etc "$STAGE/etc" 2>/dev/null || { echo "复制 /etc 失败" >&2; exit 1; }
# 不把易变/巨大的运行时缓存带进去
rm -rf "$STAGE/etc/ld.so.cache" "$STAGE/etc/mtab" 2>/dev/null

echo "[2/4] 收集 /root 脚本与 /usr/local ..."
mkdir -p "$STAGE/root-scripts"
find /root -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) \
	-exec cp -a {} "$STAGE/root-scripts/" \; 2>/dev/null
[ -d /usr/local ] && cp -a /usr/local "$STAGE/usr-local" 2>/dev/null

echo "[3/4] 记录包与单元状态 ..."
dpkg --get-selections > "$STAGE/dpkg-selections.txt" 2>/dev/null || true
systemctl list-unit-files --no-pager > "$STAGE/unit-files.txt" 2>/dev/null || true
{
	echo "time: $(date -Is)"
	echo "kernel: $(uname -r)"
	echo "payload: $VER"
	echo "rootfs: $(findmnt -n -o SOURCE / 2>/dev/null)"
	echo "disk: $(df -h / | tail -1)"
} > "$STAGE/meta.txt"

echo "[4/4] 打包 ..."
tar -czf "$OUT" -C "$STAGE" . || { echo "打包失败" >&2; exit 1; }
sha256sum "$OUT" > "$OUT.sha256" 2>/dev/null || true
chmod 600 "$OUT" 2>/dev/null

# 轮转：只留最近 KEEP 份
ls -1t "$DEST"/mi9-cfg-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r f; do
	rm -f "$f" "$f.sha256"
done

echo
echo "快照: $OUT"
echo "大小: $(du -h "$OUT" | cut -f1)"
echo "恢复演练（只预览，不改动）: mi9-restore.sh \"$OUT\""
