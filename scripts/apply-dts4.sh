#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# apply-dts4.sh —— 把 cepheus-chg.dtsi 追加到内核树里的
#                  arch/arm64/boot/dts/qcom/sm8150-xiaomi-cepheus.dts
#
#   bash apply-dts4.sh ~/build/linux-v6.17.0-sm8150-...
#
#   这是**第 4 部分**（第 1 部分 UFS+WiFi 由 apply-dts.sh 负责，
#   第 2 部分 RTC/触摸/WiFi 补尾由 apply-dts2.sh 负责，
#   第 3 部分 WCN3990 蓝牙由 apply-dts3.sh 负责）。
#
#   本部分内容：PM8150B 充电器（qcom,pm8150b-charger）+ 电量计
#   （qcom,pm8150b-fg）+ simple-battery。依据见 dts/cepheus-chg.dtsi 顶部注释。
#
#   幂等：以 MARK 定位上一次追加的段落（片段永远追加在文件末尾），
#         内容有变化就整段替换，没变化就跳过。会先备份原文件。
#   前提：先跑过 apply-dts3.sh；否则报错退出。
# ---------------------------------------------------------------------------
set -euo pipefail

K="${1:?用法: bash apply-dts4.sh <内核树目录>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DTS="$K/arch/arm64/boot/dts/qcom/sm8150-xiaomi-cepheus.dts"
FRAG="$HERE/dts/cepheus-chg.dtsi"
MARK='==== cepheus-chg'           # 片段第一行的标记（唯一），用来定位旧段
NEED='qcom,wcn3990-bt'            # 第 3 部分（cepheus-bt.dtsi）的标志

[ -d "$K" ]    || { echo "内核树不存在: $K" >&2; exit 1; }
[ -f "$DTS" ]  || { echo "找不到 $DTS" >&2; exit 1; }
[ -f "$FRAG" ] || { echo "找不到补丁片段 $FRAG" >&2; exit 1; }

if ! grep -qF -- "$NEED" "$DTS"; then
	echo "★ 树里还没有第 3 部分补丁（cepheus-bt.dtsi）。" >&2
	echo "  请先: bash $HERE/scripts/apply-dts3.sh $K" >&2
	exit 1
fi

_line="$(grep -nF -- "$MARK" "$DTS" 2>/dev/null | head -1 | cut -d: -f1 || true)"
if [ -n "${_line:-}" ]; then
	if tail -n +"$_line" "$DTS" | diff -q - "$FRAG" >/dev/null 2>&1; then
		echo "充电段已存在且与 dts/cepheus-chg.dtsi 一致，跳过。"
	else
		bak="$DTS.bak4-$(date +%Y%m%d-%H%M%S)"
		cp -a "$DTS" "$bak"
		echo "已备份原文件 -> $bak"
		head -n "$(( _line - 1 ))" "$DTS" > "$DTS.tmp4"
		mv "$DTS.tmp4" "$DTS"
		[ -n "$(tail -c1 "$DTS")" ] && echo >> "$DTS"
		cat "$FRAG" >> "$DTS"
		echo "已把旧充电段替换为最新版本 -> $DTS"
	fi
else
	bak="$DTS.bak4-$(date +%Y%m%d-%H%M%S)"
	cp -a "$DTS" "$bak"
	echo "已备份原文件 -> $bak"
	[ -n "$(tail -c1 "$DTS")" ] && echo >> "$DTS"
	cat "$FRAG" >> "$DTS"
	echo "已追加第 4 部分补丁（充电/电量计）-> $DTS"
fi

echo
echo "======== 追加结果自检 ========"
for k in 'qcom,pm8150b-charger' 'qcom,pm8150b-fg' \
         'charge-full-design-microamp-hours' 'monitored-battery' \
         'power-supplies = <&pm8150b_charger>'; do
	printf '%-40s %s\n' "$k" "$(grep -cF -- "$k" "$DTS" || true)"
done
echo APPLY_DTS4_DONE
