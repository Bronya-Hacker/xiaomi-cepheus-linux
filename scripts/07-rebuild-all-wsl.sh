#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 07-rebuild-all-wsl.sh —— 在 WSL 里"一条命令"全量重建（Windows 侧调用）
#
# 用法（在 Windows PowerShell 里）：
#     wsl bash /mnt/c/<本仓库路径>/scripts/07-rebuild-all-wsl.sh
#
# 做四件事：
#   0) 备份 WSL 侧的 payload（防止 Windows 树里没有的固件被同步覆盖）
#   1) 镜像式同步 Windows 工作树 -> WSL 工作树（★ rsync --delete，见下）
#   2) 05 打 payload -> 02 编内核(Image 内嵌 initramfs+payload) -> 06 打 kernelfat
#   3) 校验（startup.nsh 无 ttyGS0 / 包内无 ./lib/ / initramfs 内嵌 payload）
#   4) 把产物回传 Windows 的 out/
#
# ★ 为什么必须"镜像式"同步：`tar xf` **不会删除** WSL 侧多出来的旧文件。
#   2026-10-18 就吃过这个亏：Windows 侧已把 25-wlan0.network 改名成 .unused，
#   但 WSL 树里那份旧的还在，结果被 05 的硬校验逮住、整个构建中断。
#
# 可用环境变量覆盖：WSRC WDEST K OUT
# ---------------------------------------------------------------------------
set -uo pipefail

WSRC="${WSRC:-/mnt/c/Users/MAO/Desktop/小米9移植linux/wifi-bringup}"
WDST="${WDST:-/root/wifi-bringup}"
K="${K:-/root/build/linux}"
LOG="${LOG:-/mnt/c/Users/MAO/AppData/Local/Temp/opencode/rebuild.log}"
BK="${BK:-/mnt/c/Users/MAO/AppData/Local/Temp/opencode/payload-wsl-backup}"

exec >"$LOG" 2>&1
echo "===== rebuild start $(date -Is) ====="

echo
echo "########## 0) 备份 WSL 侧 payload ##########"
rm -rf "$BK"; mkdir -p "$BK"
cp -a "$WDST/payload/." "$BK/" 2>/dev/null || true
echo "备份到 $BK ($(find "$BK" -type f | wc -l) 个文件)"

echo
echo "########## 1) 同步 Windows -> WSL（镜像式）##########"
cd "$WSRC" || exit 1
if command -v rsync >/dev/null 2>&1; then
	rsync -a --delete --exclude='/out' "$WSRC/" "$WDST/" && echo "  ok rsync -a --delete (out/ 除外)"
else
	echo "  (没有 rsync，用 rm -rf payload/ + tar 兜底)"
	rm -rf "$WDST/payload"
	tar cf - --exclude=./out . | ( cd "$WDST" && tar xf - )
fi
for f in scripts/02-build-kernel.sh scripts/initramfs-init.sh scripts/05-make-payload.sh \
         scripts/06-make-kernelfat.sh payload/usr/sbin/wifi-up.sh payload/etc/wifi-cfg.ver; do
	if diff -q "$WSRC/$f" "$WDST/$f" >/dev/null 2>&1; then echo "  same  $f"; else echo "  DIFF  $f"; fi
done

echo
echo "########## 2) 05 打 payload ##########"
cd "$WDST" || exit 1
OUT="$WDST/out" bash scripts/05-make-payload.sh
rc=$?; echo "05 rc=$rc"
[ $rc -eq 0 ] || { echo "== 05 失败，停"; exit 1; }

echo
echo "########## 3) 02 编内核 ##########"
OUT="$WDST/out" bash scripts/02-build-kernel.sh "$K"
rc=$?; echo "02 rc=$rc"
[ $rc -eq 0 ] || { echo "== 02 失败，停"; exit 1; }

echo
echo "########## 4) 06 打 kernelfat ##########"
OUT="$WDST/out" bash scripts/06-make-kernelfat.sh
rc=$?; echo "06 rc=$rc"
[ $rc -eq 0 ] || { echo "== 06 失败，停"; exit 1; }

echo
echo "########## 5) 校验 startup.nsh（必须没有 console=ttyGS0）##########"
cat "$WDST/out/startup.nsh"
if grep -q 'ttyGS0' "$WDST/out/startup.nsh"; then
	echo "== 致命：startup.nsh 里还有 console=ttyGS0（会把整机冻住 9 分钟）"
	exit 1
else
	echo "  ok 没有 ttyGS0 控制台"
fi

echo
echo "########## 6) 校验 initramfs ##########"
rm -rf /tmp/irchk; mkdir -p /tmp/irchk; cd /tmp/irchk
gzip -dc "$WDST/out/initramfs.cpio.gz" | cpio -id 2>/dev/null
ls -l payload 2>&1 | sed 's/^/  /'
echo "--- payload 版本号出现次数（应为 6 左右）---"
grep -c "$(head -1 "$WDST/payload/etc/wifi-cfg.ver")" init
echo "--- 阴影模块清理逻辑出现次数（应为 1）---"
grep -c 'stale-modules' init

echo
echo "########## 7) 校验 wifi-cfg.tar.gz ##########"
tar tzf "$WDST/out/wifi-cfg.tar.gz" | grep -vE '/$' | sort | sed 's/^/  /'
tar tzf "$WDST/out/wifi-cfg.tar.gz" | grep -E '^\.?/?lib(/|$)' && echo "== 包里还有 ./lib/！" || echo "  ok 包内没有 ./lib/ 目录项"
tar tzf "$WDST/out/wifi-cfg.tar.gz" | grep -E '25-wlan0\.network$' && echo "== 包里有未改名的 25-wlan0.network！" || echo "  ok 只有 .unused"

echo
echo "########## 8) 校验 kernelfat.img ##########"
mdir -i "$WDST/out/kernelfat.img" :: 2>&1 | sed 's/^/  /'
stat -c '%n %s' "$WDST/out/Image" "$WDST/out/kernelfat.img"

echo
echo "########## 9) 回传产物到 Windows out/ ##########"
cp -f "$WDST/out/Image" "$WDST/out/mods.tar.gz" "$WDST/out/wifi-cfg.tar.gz" \
      "$WDST/out/initramfs.cpio.gz" "$WDST/out/kernelfat.img" "$WDST/out/startup.nsh" \
      "$WSRC/out/"
ls -l "$WSRC/out/" | sed 's/^/  /'
echo "Image sha256:     $(sha256sum "$WDST/out/Image" | cut -c1-16)"
echo "kernelfat sha256: $(sha256sum "$WDST/out/kernelfat.img" | cut -c1-16)"
echo REBUILD_DONE
