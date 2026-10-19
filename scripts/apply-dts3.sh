#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# apply-dts3.sh —— 把 cepheus-bt.dtsi 追加到内核树里的
#                  arch/arm64/boot/dts/qcom/sm8150-xiaomi-cepheus.dts
#
#   bash apply-dts3.sh ~/build/linux-v6.17.0-sm8150-...
#
#   这是**第 3 部分**（第 1 部分 UFS+WiFi 由 apply-dts.sh 负责，
#   第 2 部分 RTC/触摸/WiFi 补尾由 apply-dts2.sh 负责）。
#
#   本部分内容：WCN3990 蓝牙（uart13 四线 + 三路供电映射）。
#   依据见 dts/cepheus-bt.dtsi 顶部注释（原厂 dtbo 反编译 + 同 SoC 板子对照）。
#
#   幂等：已经打过就跳过（靠 MARK 字符串识别）。会先备份原文件。
#   前提：先跑过 apply-dts2.sh；否则报错退出。
# ---------------------------------------------------------------------------
set -euo pipefail

K="${1:?用法: bash apply-dts3.sh <内核树目录>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DTS="$K/arch/arm64/boot/dts/qcom/sm8150-xiaomi-cepheus.dts"
FRAG="$HERE/dts/cepheus-bt.dtsi"
MARK='==== cepheus-bt'             # 片段第一行的标记（唯一），用来定位旧段
NEED='regulator-touch-vddio'      # 第 2 部分（cepheus-extra.dtsi）的标志

[ -d "$K" ]    || { echo "内核树不存在: $K" >&2; exit 1; }
[ -f "$DTS" ]  || { echo "找不到 $DTS" >&2; exit 1; }
[ -f "$FRAG" ] || { echo "找不到补丁片段 $FRAG" >&2; exit 1; }

if ! grep -qF -- "$NEED" "$DTS"; then
	echo "★ 树里还没有第 2 部分补丁（cepheus-extra.dtsi）。" >&2
	echo "  请先: bash $HERE/scripts/apply-dts2.sh $K" >&2
	exit 1
fi

# ★ 片段永远追加在文件末尾，所以"标记行 → EOF"就是上一次追加的内容。
#   这样改了 dts/cepheus-bt.dtsi 之后重跑本脚本，会自动替换成最新版，
#   而不是像老脚本那样"看到标记就跳过"（那会导致改了 dts 却编不进去）。
_line="$(grep -nF -- "$MARK" "$DTS" 2>/dev/null | head -1 | cut -d: -f1 || true)"
if [ -n "${_line:-}" ]; then
	if tail -n +"$_line" "$DTS" | diff -q - "$FRAG" >/dev/null 2>&1; then
		echo "蓝牙段已存在且与 dts/cepheus-bt.dtsi 一致，跳过。"
	else
		bak="$DTS.bak3-$(date +%Y%m%d-%H%M%S)"
		cp -a "$DTS" "$bak"
		echo "已备份原文件 -> $bak"
		head -n "$(( _line - 1 ))" "$DTS" > "$DTS.tmp3"
		mv "$DTS.tmp3" "$DTS"
		[ -n "$(tail -c1 "$DTS")" ] && echo >> "$DTS"
		cat "$FRAG" >> "$DTS"
		echo "已把旧蓝牙段替换为最新版本 -> $DTS"
	fi
else
	bak="$DTS.bak3-$(date +%Y%m%d-%H%M%S)"
	cp -a "$DTS" "$bak"
	echo "已备份原文件 -> $bak"
	[ -n "$(tail -c1 "$DTS")" ] && echo >> "$DTS"
	cat "$FRAG" >> "$DTS"
	echo "已追加第 3 部分补丁（蓝牙）-> $DTS"
fi

echo
echo "======== 追加结果自检 ========"
for k in 'qcom,wcn3990-bt' 'vddio-supply' 'vddxo-supply' \
         'vddrf-supply' 'vddch0-supply' 'firmware-name = "crnv21.bin", "crbtfw21.tlv"' \
         'max-speed = <3200000>'; do
	printf '%-32s %s\n' "$k" "$(grep -cF -- "$k" "$DTS" || true)"
done
echo APPLY_DTS3_DONE
