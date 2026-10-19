#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# apply-dts.sh —— 把 cepheus-wifi.dtsi 追加到内核树里的
#                 arch/arm64/boot/dts/qcom/sm8150-xiaomi-cepheus.dts
#
#   bash apply-dts.sh ~/build/linux-v6.17.0-sm8150-379d8fe3...
#
#   补丁分两部分，**两部分都必须打上**：
#     第 0 部分 UFS   —— 没有它内核看不到 /dev/sda*，卡死在 initramfs
#                        （现象：企鹅画出来了但日志不滚、USB 也扫不到）
#     第 1 部分 WiFi  —— WCN3990 / ath10k_snoc
#
# 幂等：全套已经打过就跳过。会先备份原文件。
# ⚠️ 如果树里只有**旧版**补丁（只有 WiFi、没有 UFS），本脚本会报错退出，
#    不会盲目再追加一遍。这时请先还原再重跑：
#       cp -a <DTS>.bak-* <DTS>   # 挑最早的备份
#       bash apply-dts.sh <内核树目录>
# ---------------------------------------------------------------------------
set -euo pipefail

K="${1:?用法: bash apply-dts.sh <内核树目录>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DTS="$K/arch/arm64/boot/dts/qcom/sm8150-xiaomi-cepheus.dts"
FRAG="$HERE/dts/cepheus-wifi.dtsi"
MARK='ath10k_snoc WiFi 启用'   # 旧版也有，用来识别“打过但版本旧”
MARK2='&ufs_mem_hc {'          # 只有新版才有（UFS 段）

[ -d "$K" ]         || { echo "内核树不存在: $K" >&2; exit 1; }
[ -f "$DTS" ]       || { echo "找不到 $DTS" >&2; exit 1; }
[ -f "$FRAG" ]      || { echo "找不到补丁片段 $FRAG" >&2; exit 1; }

if grep -qF -- "$MARK2" "$DTS"; then
	echo "已经打过补丁（含 UFS 段），跳过。"
elif grep -qF -- "$MARK" "$DTS"; then
	echo "★ 树里是【旧版】补丁：只有 WiFi，没有 UFS 段。" >&2
	echo "  这一版会漏掉 UFS → 手机卡在 initramfs（内核看不到 /dev/sda*）。" >&2
	echo "  请先还原再重跑：" >&2
	echo "      cp -a $DTS.bak-* $DTS" >&2
	echo "      bash $0 $K" >&2
	exit 1
else
	bak="$DTS.bak-$(date +%Y%m%d-%H%M%S)"
	cp -a "$DTS" "$bak"
	echo "已备份原文件 -> $bak"
	# 保证以换行结尾，然后追加
	[ -n "$(tail -c1 "$DTS")" ] && echo >> "$DTS"
	cat "$FRAG" >> "$DTS"
	echo "已追加补丁 -> $DTS"
fi

echo
echo "======== 追加结果自检 ========"
for k in '&ufs_mem_hc {' '&ufs_mem_phy {' 'reset-gpios = <&tlmm 175' \
         'vdda-phy-supply' '&remoteproc_adsp' '&remoteproc_mpss' \
         '&wifi {' 'vdd-0.8-cx-mx-supply' 'firmware-name' \
         'qcom,calibration-variant'; do
	printf '%-32s %s\n' "$k" "$(grep -cF -- "$k" "$DTS" || true)"
done
echo APPLY_DTS_DONE
