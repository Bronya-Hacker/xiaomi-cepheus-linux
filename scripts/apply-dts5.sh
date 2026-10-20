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
BOARDSRC="$HERE/dts/sm8150-xiaomi-cepheus.dts"

[ -f "$DTS" ] || { echo "找不到 $DTS" >&2; exit 1; }
[ -f "$SRC" ] || { echo "找不到 $SRC" >&2; exit 1; }

cp -a "$SRC" "$DST"

python3 - "$BOARDSRC" "$DTS" <<'PY'
import sys, shutil, os

boardsrc, dts = sys.argv[1], sys.argv[2]
inc = '#include "cepheus-cam-ir-nfc.dtsi"'

if os.path.isfile(boardsrc):
    new = open(boardsrc).read()
    old = open(dts).read() if os.path.isfile(dts) else ""

    # 内核树那份末尾可能带着脚本追加的 include，同步后要保证它还在
    if inc not in new:
        new = new.rstrip("\n") + "\n\n" + inc + "\n"

    if new.strip() != old.strip():
        if os.path.isfile(dts):
            shutil.copyfile(dts, dts + ".bak-boarddts")
        open(dts, "w").write(new)
        print("OK 板级 DTS 已同步（仓库 dts/ -> 内核树）")
    else:
        print("OK 板级 DTS 两边一致（不动）")
else:
    print("WARN 仓库里没有 dts/sm8150-xiaomi-cepheus.dts，跳过同步")
PY

if grep -q 'cepheus-cam-ir-nfc.dtsi' "$DTS"; then
	echo "OK 相机/红外/NFC dtsi 已在 DTS 里（不动）"
else
	cp -a "$DTS" "$DTS.bak-cam-ir-nfc"
	printf '\n#include "cepheus-cam-ir-nfc.dtsi"\n' >> "$DTS"
	echo "OK 已追加 #include \"cepheus-cam-ir-nfc.dtsi\""
fi
