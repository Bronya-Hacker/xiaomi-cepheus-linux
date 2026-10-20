#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# apply-dts5.sh —— 把板级补充打进 cepheus 的设备树
#
#   bash scripts/apply-dts5.sh [KDIR]
#
# 作用：
#   1) 把 dts/cepheus-cam-ir-nfc.dtsi 拷到内核的 qcom 目录；
#   2) ★ 把仓库的 dts/sm8150-xiaomi-cepheus.dts 同步进内核树（板级 DTS 本体）；
#   3) 在板级 DTS 末尾追加 #include（只加一次）。
#
# 为什么需要它：02-build-kernel.sh 每次都会跑 apply-dts*.sh 重建板级 DTS；
# 手工往内核树里改的东西容易和仓库脱节。2026-10-21 就踩过：仓库那份已经去掉了
# `gpio-reserved-ranges` 里的 `<126 4>`，但内核树那份没同步 → 编出来的 DTB 仍然
# 保留 126-129，pinctrl 申请不到功放的 MI2S 引脚（pin-126 -EINVAL）。
#
# ★ 所以：**板级 DTS 的改动请改仓库 dts/ 下那份**，由本脚本同步进内核树。
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KDIR="${1:-${KDIR:-/root/build/linux}}"

DTS="$KDIR/arch/arm64/boot/dts/qcom/sm8150-xiaomi-cepheus.dts"
SRC="$HERE/dts/cepheus-cam-ir-nfc.dtsi"
DST="$(dirname "$DTS")/cepheus-cam-ir-nfc.dtsi"
USBSRC="$HERE/dts/cepheus-usb.dtsi"
USBDST="$(dirname "$DTS")/cepheus-usb.dtsi"
BOARDSRC="$HERE/dts/sm8150-xiaomi-cepheus.dts"

[ -f "$DTS" ] || { echo "找不到 $DTS" >&2; exit 1; }
[ -f "$SRC" ] || { echo "找不到 $SRC" >&2; exit 1; }

cp -a "$SRC" "$DST"

# USB / OTG / Type-C 也走 dtsi（直接追加到 .dts 末尾会被 apply-dts*.sh 冲掉）
if [ -f "$USBSRC" ]; then
	cp -a "$USBSRC" "$USBDST"
	if grep -q 'cepheus-usb.dtsi' "$DTS"; then
		echo "OK USB dtsi 已在 DTS 里（不动）"
	else
		printf '\n#include "cepheus-usb.dtsi"\n' >> "$DTS"
		echo "OK 已追加 #include \"cepheus-usb.dtsi\""
	fi
fi

# ★ 千万不要把仓库的 dts/sm8150-xiaomi-cepheus.dts 覆盖到内核树！
#   仓库那份是**干净的主线板级 DTS**（没有 UFS / 充电 / 触摸 / 蓝牙等补丁），
#   内核树那份才是 apply-dts*.sh 打过补丁的完整版。覆盖会一夜回到解放前
#   （2026-10-21 真踩过：覆盖后 DTB 校验大面积失败，UFS 都起不来）。
#
#   所以这里只做一件事：如果两边不一致，提醒一声，但不动内核树那份。
#   板级 DTS 要改就直接改内核树那份（改完记得同步一份到 dts/ 留档）。
python3 - "$BOARDSRC" "$DTS" <<'PY'
import sys, os

boardsrc, dts = sys.argv[1], sys.argv[2]

if os.path.isfile(boardsrc) and os.path.isfile(dts):
    a = open(boardsrc).read().strip()
    b = open(dts).read().strip()
    if a != b:
        print("WARN 仓库 dts/ 与内核树的板级 DTS 不一致（不同步是正常的：内核树那份带补丁）")
        print("     改板级 DTS 请直接改内核树那份，改完可复制回 dts/ 留档。")
PY

if grep -q 'cepheus-cam-ir-nfc.dtsi' "$DTS"; then
	echo "OK 相机/红外/NFC dtsi 已在 DTS 里（不动）"
else
	cp -a "$DTS" "$DTS.bak-cam-ir-nfc"
	printf '\n#include "cepheus-cam-ir-nfc.dtsi"\n' >> "$DTS"
	echo "OK 已追加 #include \"cepheus-cam-ir-nfc.dtsi\""
fi
