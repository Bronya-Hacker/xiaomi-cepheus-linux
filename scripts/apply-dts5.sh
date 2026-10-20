#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# apply-dts5.sh —— 把相机/红外/NFC 的板级补充打进 cepheus 的设备树
#
#   bash scripts/apply-dts5.sh [KDIR]
#
# 作用：
#   1) 把 dts/cepheus-cam-ir-nfc.dtsi 拷到内核的 qcom 目录；
#   2) 在 sm8150-xiaomi-cephues.dts 末尾追加 #include（只加一次）。
#
# 为什么需要它：02-build-kernel.sh 每次都会跑 apply-dts*.sh 重建板级 DTS，
# 手工往 DTS 里加的东西会被冲掉（2026-10-20 就被冲过一次）。
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KDIR="${1:-${KDIR:-/root/build/linux}}"

DTS="$KDIR/arch/arm64/boot/dts/qcom/sm8150-xiaomi-cepheus.dts"
SRC="$HERE/dts/cepheus-cam-ir-nfc.dtsi"
DST="$(dirname "$DTS")/cepheus-cam-ir-nfc.dtsi"

[ -f "$DTS" ] || { echo "找不到 $DTS" >&2; exit 1; }
[ -f "$SRC" ] || { echo "找不到 $SRC" >&2; exit 1; }

cp -a "$SRC" "$DST"

if grep -q 'cepheus-cam-ir-nfc.dtsi' "$DTS"; then
	echo "✓ 相机/红外/NFC dtsi 已在 DTS 里（不动）"
else
	cp -a "$DTS" "$DTS.bak-cam-ir-nfc"
	printf '\n#include "cepheus-cam-ir-nfc.dtsi"\n' >> "$DTS"
	echo "✓ 已追加 #include \"cepheus-cam-ir-nfc.dtsi\""
fi
