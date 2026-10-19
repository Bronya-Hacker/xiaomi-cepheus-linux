#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 04-build-tqftpserv.sh —— 拿到 aarch64 的 tqftpserv 及其运行时依赖
#
#   bash 04-build-tqftpserv.sh [工作目录]
#
#   → out/tqftpserv             (aarch64 ELF)
#     out/libqrtr.so.1.0        (tqftpserv NEEDED libqrtr.so.1)
#     out/libzstd.so.1.5.5      (tqftpserv NEEDED libzstd.so.1)
#     out/tqftpserv.service     (官方单元文件，照抄用)
#
# 为什么用“拆 Debian/Ubuntu 的 arm64 deb”而不是交叉编译：
#   - Debian 官方就打包了 tqftpserv（维护者正是 linux-msm 的 Dmitry Baryshkov），
#     二进制 67 KB，依赖只有 libqrtr1 + libzstd1；
#   - 交叉编译要处理 libqrtr + glib 的 arm64 开发包，麻烦得多；
#   - 拿到的二进制和包里的 systemd 单元是**官方配对**的，参数不会写错。
#
# 背景（为什么非得有它）：WCN3990 的 wlanmdsp.mbn 不是 ath10k 加载的，是
#   ADSP 里的 WLAN 子系统通过 QRTR 上的 TFTP 向 userspace 要的。
#   交接包里从来没部署过这一环，这是 wlan0 不出现的真正原因之一。
# ---------------------------------------------------------------------------
set -euo pipefail

WORK="${1:-$PWD/tqftpserv-build}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$HERE/out}"
mkdir -p "$OUT" "$WORK"
cd "$WORK"

need() { command -v "$1" >/dev/null 2>&1 || { echo "缺命令 $1"; return 1; }; }
need curl || exit 1
need dpkg-deb || { echo "缺 dpkg-deb（Debian/Ubuntu 自带；其它发行版请装 dpkg）"; exit 1; }

# ---------------------------------------------------------------------------
# 镜像候选（国内可达 + 官方兜底）
# ---------------------------------------------------------------------------
DEB_MIRRORS=(
	"https://mirrors.tuna.tsinghua.edu.cn/debian"
	"https://mirrors.ustc.edu.cn/debian"
	"https://deb.debian.org/debian"
)
PORTS_MIRRORS=(
	"https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports"
	"https://mirrors.ustc.edu.cn/ubuntu-ports"
	"http://ports.ubuntu.com/ubuntu-ports"
)

# tqftpserv：优先 Debian（版本新，1.2-1），兜底 Ubuntu（1.1.1-1）
TQFTP_DEB="pool/main/t/tqftpserv/tqftpserv_1.2-1_arm64.deb"
TQFTP_DEB_FB="pool/universe/t/tqftpserv/tqftpserv_1.1.1-1_arm64.deb"
# 依赖（Ubuntu 上 libqrtr1 在 main，libzstd1 在 main）
LIBQRTR_DEB="pool/main/libq/libqrtr/libqrtr1_1.0-2ubuntu3_arm64.deb"
LIBZSTD_DEB="pool/main/libz/libzstd/libzstd1_1.5.5+dfsg2-2build1.1_arm64.deb"

fetch() {  # fetch <输出文件名> <相对路径...>  （在给定镜像列表里逐个试）
	local out="$1"; shift
	local m
	for m in "$@"; do
		echo "   试 $m"
		if curl -fsSL --connect-timeout 15 --retry 2 -o "$out" "$m" 2>/dev/null && [ -s "$out" ]; then
			echo "   ✓ $(stat -c%s "$out") 字节"
			return 0
		fi
		rm -f "$out"
	done
	return 1
}

echo "=========================================================================="
echo "1) 取 tqftpserv 的 arm64 deb"
echo "=========================================================================="
for m in "${DEB_MIRRORS[@]}"; do
	DEBS+=("$m/$TQFTP_DEB")
done
if ! fetch tqftpserv.deb "${DEBS[@]}"; then
	echo "   Debian 源没取到，换 Ubuntu ports"
	UB=()
	for m in "${PORTS_MIRRORS[@]}"; do UB+=("$m/$TQFTP_DEB_FB"); done
	fetch tqftpserv.deb "${UB[@]}" || { echo "✗ 取不到 tqftpserv.deb"; exit 1; }
fi

echo
echo "=========================================================================="
echo "2) 取运行时依赖的 arm64 deb（libqrtr1 / libzstd1）"
echo "=========================================================================="
# libqrtr1：Ubuntu ports main 有
UBQRTR=(); UBZSTD=()
for m in "${PORTS_MIRRORS[@]}"; do
	UBQRTR+=("$m/$LIBQRTR_DEB")
	UBZSTD+=("$m/$LIBZSTD_DEB")
done
fetch libqrtr1.deb "${UBQRTR[@]}" || echo "   ⚠️ libqrtr1 没取到（若手机已有 libqrtr.so.1 可忽略）"
fetch libzstd1.deb "${UBZSTD[@]}" || echo "   ⚠️ libzstd1 没取到（手机一般已有 libzstd.so.1）"

echo
echo "=========================================================================="
echo "3) 拆包"
echo "=========================================================================="
rm -rf x
mkdir -p x
for d in tqftpserv.deb libqrtr1.deb libzstd1.deb; do
	[ -s "$d" ] || continue
	echo "--- $d"
	dpkg-deb -x "$d" x
done

echo
echo "--- 包信息（确认是 arm64）---"
dpkg-deb -f tqftpserv.deb Package Version Architecture Depends 2>/dev/null || true

echo
echo "=========================================================================="
echo "4) 收集产物到 out/"
echo "=========================================================================="
BIN="$(find x -type f -name tqftpserv | head -1)"
[ -n "$BIN" ] || { echo "✗ 包里没找到 tqftpserv 可执行文件"; exit 1; }
install -m 0755 "$BIN" "$OUT/tqftpserv"
echo "   out/tqftpserv  <- $BIN"

# 官方单元文件（照抄，只做了 Ordering 相关的小调整可自行 diff）
UNIT="$(find x -type f -path '*systemd/system/tqftpserv.service' | head -1)"
if [ -n "$UNIT" ]; then
	cp -v "$UNIT" "$OUT/tqftpserv.service"
	echo "   ↑ 这是官方单元，重跑 05 时会被带进 payload 的 /etc/systemd/system/"
fi

for so in libqrtr.so.1.0 libzstd.so.1.5.5; do
	f="$(find x -type f -name "$so" | head -1)"
	if [ -n "$f" ]; then
		install -m 0644 "$f" "$OUT/$so"
		echo "   out/$so  <- $f"
	fi
done

echo
echo "=========================================================================="
echo "5) 自检"
echo "=========================================================================="
file "$OUT/tqftpserv"
echo "--- NEEDED ---"
readelf -d "$OUT/tqftpserv" | grep -i needed | sed 's/^/   /'
echo "--- 二进制里的默认路径（应为 /readonly/firmware/image/ 和 /lib/firmware/）---"
strings "$OUT/tqftpserv" | grep -E '^/(readonly|readwrite|lib/firmware)' | sed 's/^/   /'

echo
echo "MAKE_TQFTPSERV_DONE"
echo "下一步：bash 05-make-payload.sh [--wlanmdsp <手机上的 wlanmdsp.mbn>]"
