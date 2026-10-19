#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# apply-dts2.sh —— 把 cepheus-extra.dtsi 追加到内核树里的
#                  arch/arm64/boot/dts/qcom/sm8150-xiaomi-cepheus.dts
#
#   bash apply-dts2.sh ~/build/linux-v6.17.0-sm8150-379d8fe3...
#
#   这是**第 2 部分**（第 1 部分 cepheus-wifi.dtsi 由 apply-dts.sh 负责，
#   里面是 UFS + WiFi，缺了手机根本进不去系统）。
#
#   本部分内容（全部依据 usb12 冷启动实测日志，详见 docs/root-cause.md §10.12）：
#     1) &pm8150_rtc  allow-set-time;          ← rtc-pm8xxx 才注册可写 set_time
#     2) &usb_1_qmpphy 兩路电                   ← 消掉 devm_regulator_bulk_get 报错
#     3) &wifi  第 5 路电 + local-mac-address   ← 消掉 supply / invalid MAC 两条 warn
#     4) 触摸 STM FTS（i2c17 + fts@49 + 三个 pin 配置 + gpio84 供电）
#
#   幂等：已经打过就跳过（靠 MARK 字符串识别）。会先备份原文件。
#   前提：先跑过 apply-dts.sh（有 &ufs_mem_hc 段）；否则报错退出。
# ---------------------------------------------------------------------------
set -euo pipefail

K="${1:?用法: bash apply-dts2.sh <内核树目录>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DTS="$K/arch/arm64/boot/dts/qcom/sm8150-xiaomi-cepheus.dts"
FRAG="$HERE/dts/cepheus-extra.dtsi"
MARK='regulator-touch-vddio'      # 只有本片段才有，用来判断"已打过"
NEED='&ufs_mem_hc {'              # 第 1 部分（UFS）的标志

[ -d "$K" ]   || { echo "内核树不存在: $K" >&2; exit 1; }
[ -f "$DTS" ] || { echo "找不到 $DTS" >&2; exit 1; }
[ -f "$FRAG" ]|| { echo "找不到补丁片段 $FRAG" >&2; exit 1; }

# 必须already有第 1 部分，否则顺序错了（本片段引用 &wifi / &wifi 的
# vdd-3.3-ch1，还有 &ufs 相关节点都来自第 1 部分）
if ! grep -qF -- "$NEED" "$DTS"; then
	echo "★ 树里还没有第 1 部分补丁（cepheus-wifi.dtsi）。" >&2
	echo "  请先: bash $HERE/scripts/apply-dts.sh $K" >&2
	exit 1
fi

if grep -qF -- "$MARK" "$DTS"; then
	echo "已经打过第 2 部分补丁，跳过。"
else
	bak="$DTS.bak2-$(date +%Y%m%d-%H%M%S)"
	cp -a "$DTS" "$bak"
	echo "已备份原文件 -> $bak"
	[ -n "$(tail -c1 "$DTS")" ] && echo >> "$DTS"
	cat "$FRAG" >> "$DTS"
	echo "已追加第 2 部分补丁 -> $DTS"
fi

echo
echo "======== 追加结果自检 ========"
# 注意：这些字符串必须与 dts/cepheus-extra.dtsi 完全一致。
# 触摸那几条故意用 st, 前缀（这棵树的驱动只认 st,*），
# 如果哪天手滑改回厂商的 fts,*，这里立刻会显示 0。
for k in 'nvmem-cell-names = "offset"' 'rtc-offset@bc' \
         'vdd-3.3-ch1-supply = <&vreg_l11c_3p3>' \
         'local-mac-address = [02 00 71 96 e3 d6]' \
         'regulator-touch-vddio' '&qupv3_id_2 {' '&i2c17 {' \
         'touchscreen@49 {' 'compatible = "st,fts"' \
         'st,irq-gpio = <&tlmm 122 IRQ_TYPE_LEVEL_LOW>' \
         'st,reset-gpio = <&tlmm 12 GPIO_ACTIVE_HIGH>' \
         'st,max-coords = <1079 2339>' 'st,disable-auto-fw-update' \
         'avdd-supply = <&vreg_l1c_1p8>'; do
	printf '%-52s %s\n' "$k" "$(grep -cF -- "$k" "$DTS" || true)"
done
echo APPLY_DTS2_DONE
