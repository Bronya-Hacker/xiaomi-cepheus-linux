#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 01-setup-buildhost.sh —— 新编译机一键装依赖（Ubuntu 22.04 / 24.04 x86_64）
#
#   sudo bash 01-setup-buildhost.sh
#
# 装完会打印各工具版本；同时尝试把 aarch64 静态 busybox 抓到 out/busybox
# （编 initramfs 要用；抓不到也没关系，手工放一个即可）。
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$HERE/out}"
mkdir -p "$OUT"

if [ "$(id -u)" != "0" ]; then
	echo "请用 sudo 运行：sudo bash $0" >&2
	exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y

# --- 基础编译链 ---
apt-get install -y --no-install-recommends \
	build-essential bc bison flex \
	libssl-dev libelf-dev libncurses-dev \
	python3 python3-pip python3-venv python3-setuptools \
	cpio kmod rsync zstd lz4 xz-utils gzip tar file unzip \
	device-tree-compiler \
	clang lld llvm \
	mtools dosfstools \
	git curl wget ca-certificates \
	uuid-dev nasm iasl pkg-config \
	meson ninja-build \
	gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu

# --- tqftpserv 不再交叉编译（直接取 Debian/Ubuntu 的 aarch64 deb，见 04 脚本），
#     所以 glib 开发包不用装了；要自己编译的话再装 libglib2.0-dev ---
# --- edk2 的 build.sh 要 msgfmt（gettext 包）---
apt-get install -y --no-install-recommends gettext || true

# --- edk2 的 FV 压缩要 brotli（旧机器上就是因为缺它才报 BROTLI_MISSING）---
apt-get install -y --no-install-recommends brotli libbrotli-dev || \
	apt-get install -y --no-install-recommends libbrotli-dev || true

# --- edk2 的 BaseTools 有时还需要这些 ---
apt-get install -y --no-install-recommends python3-distutils || true
apt-get install -y --no-install-recommends acpica-tools || true
# edk2-msm 的 build.sh 会跑 SimpleInit 的 gen-rootfs-source.sh；cmake/uuidgen 装上保险
apt-get install -y --no-install-recommends cmake uuid-runtime || true

echo
echo "================= 版本检查 ================="
for t in clang lld ld.lld make dtc mformat mcopy objcopy nasm iasl meson ninja python3; do
	if command -v "$t" >/dev/null 2>&1; then
		printf '%-10s %s\n' "$t" "$(command -v "$t")"
	else
		printf '%-10s !! 缺失\n' "$t"
	fi
done
clang --version | head -1
echo

# --- aarch64 静态 busybox：initramfs 用 ---
#     busybox.net 那个 binaries/... 目录已经 404（实测），改从 Ubuntu ports 的
#     busybox-static (arm64) deb 里取 ./usr/bin/busybox（它就是静态链接的）。
BB="$OUT/busybox"
if [ ! -s "$BB" ]; then
	echo "取 aarch64 静态 busybox（Ubuntu ports 的 busybox-static deb）..."
	TMP="$(mktemp -d)"; ok=0
	for u in \
		"https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/pool/main/b/busybox/busybox-static_1.36.1-6ubuntu3.1_arm64.deb" \
		"https://mirrors.ustc.edu.cn/ubuntu-ports/pool/main/b/busybox/busybox-static_1.36.1-6ubuntu3.1_arm64.deb" \
		"https://ports.ubuntu.com/pool/main/b/busybox/busybox-static_1.36.1-6ubuntu3.1_arm64.deb" \
	; do
		echo "   试 $u"
		if curl -fsSL --connect-timeout 20 -o "$TMP/bb.deb" "$u" && [ -s "$TMP/bb.deb" ]; then ok=1; break; fi
	done
	if [ "$ok" = 1 ] && command -v dpkg-deb >/dev/null 2>&1; then
		dpkg-deb -x "$TMP/bb.deb" "$TMP/x"
		f="$(find "$TMP/x" -type f -name busybox | head -1)"
		[ -n "$f" ] && { cp "$f" "$BB"; chmod +x "$BB"; echo "busybox 已保存到 $BB"; }
	fi
	if [ ! -s "$BB" ]; then
		cat <<'EOF'
⚠️ busybox 自动获取失败。请手工准备一个 aarch64 静态 busybox 放到 out/busybox：
   - 方式1：从 Ubuntu ports 的 busybox-static (arm64) .deb 里取 ./usr/bin/busybox
   - 方式2：其它来源的 aarch64 静态 busybox
   放好后重跑本脚本即可（有文件就跳过下载）。
EOF
	else
		file "$BB"
	fi
	rm -rf "$TMP"
else
	echo "已有 $BB（跳过下载）"
fi

echo "SETUP_BUILDHOST_DONE"
echo "下一步："
echo "  1) 解开内核源码：tar xzf <kernel.tar.gz> -C ~/build/"
echo "  2) 打 DTB 补丁：  bash apply-dts.sh ~/build/linux-6.17.0-sm8150-..."
echo "  3) clone edk2-msm（github 直连被墙，必须走 gh-proxy，且 boringssl 要单独重写）："
echo "       git config --global url.\"https://gh-proxy.com/https://github.com/\".insteadOf \"https://github.com/\""
echo "       git config --global url.\"https://gh-proxy.com/https://github.com/google/boringssl\".insteadOf \"https://boringssl.googlesource.com/boringssl\""
echo "       git clone --depth 1 https://github.com/edk2-porting/edk2-msm"
echo "       cd edk2-msm && git submodule update --init --recursive --depth 1"
echo "  4) bash 02-build-kernel.sh ~/build/linux-6.17.0-sm8150-..."
echo "  5) bash 04-build-tqftpserv.sh        # 取 aarch64 的 tqftpserv + libqrtr/libzstd"
echo "  6) bash 05-make-payload.sh           # 固件已随包提供，无需参数"
echo "  7) bash 03-build-edk2.sh ~/build/edk2-msm out/sm8150-xiaomi-cepheus.dtb"
