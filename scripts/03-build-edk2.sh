#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 03-build-edk2.sh —— 把新 dtb 塞进 edk2 的 FdtBlob 并重编 → boot-cepheus.img
#
#   bash 03-build-edk2.sh <edk2-msm目录> <新的 sm8150-xiaomi-cepheus.dtb>
#
# ★ 这一步才是 DTB 真正生效的地方：内核拿到的 DTB 来自 edk2 内嵌的 FdtBlob，
#   不是 Image 尾巴上那个厂商 DTB。
#
# 实测事实（别怀疑）：
#   * edk2-msm 里 Platform/Xiaomi/sm8150/FdtBlob/cepheus/sm8150-xiaomi-cepheus.dtb
#     是**原厂未改版**：wifi@18800000 的 status 是 "disabled"，
#     一个 remoteproc 的 firmware-name 都没有 → 这就是 wlan0 从来不出来的一半原因。
#   * 那个 DTB 的 /chosen 里**只有 stdout-path，没有 bootargs**。
#     上一任交接脚本（rebuild-uefi-dtb.sh）会往 chosen 里补
#     bootargs = "console=tty0 loglevel=7"，而且那样编出来的镜像**确实能启动**。
#     所以本脚本也照着补（见第 2 步）—— 对齐"已知能启动"的配置，少赌一把。
#
# ★ 注意别改错文件：FdtBlob_compat/cepheus.dtb 是追在 boot 镜像**尾部**的
#   厂商 DTB（621174 字节，model="CEPHEUS"，只有 qcom,sm8150-cdp，没有 soc@0），
#   那是给 ABL 看的，**Linux 不用它**，不要动。Linux 用的是本脚本替换的
#   FdtBlob/cepheus/sm8150-xiaomi-cepheus.dtb，它作为 FFS 文件
#   （GUID 25462CDA-221F-47DF-AC1D-259CFAA4E326 = gDtPlatformDefaultDtbFileGuid）
#   编进 FVMAIN，再由 UEFI 作为系统 DTB 交给内核。
#
# edk2 编译要 msgfmt（gettext）、brotli、python3、nasm、iasl —— 01 脚本已装。
# github 直连被墙，clone 时务必先配 gh-proxy（见 01 脚本末尾的说明）。
# ---------------------------------------------------------------------------
set -euo pipefail

ED="${1:?用法: bash 03-build-edk2.sh <edk2-msm目录> <dtb文件>}"
DTB="${2:?用法: bash 03-build-edk2.sh <edk2-msm目录> <dtb文件>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$HERE/out}"
mkdir -p "$OUT"

[ -d "$ED" ]  || { echo "edk2 目录不存在: $ED" >&2; exit 1; }
[ -f "$DTB" ] || { echo "dtb 不存在: $DTB" >&2; exit 1; }

FB="$ED/Platform/Xiaomi/sm8150/FdtBlob/cepheus/sm8150-xiaomi-cepheus.dtb"
FBDIR="$(dirname "$FB")"

echo "=========================================================================="
echo "1) 备份 edk2 原有的 FdtBlob"
echo "=========================================================================="
if [ -f "$FB" ]; then
	[ -f "$FB.edk2-orig" ] || cp -a "$FB" "$FB.edk2-orig"
	echo "原版已留档: $FB.edk2-orig ($(stat -c%s "$FB.edk2-orig") 字节)"
else
	mkdir -p "$FBDIR"
fi

echo
echo "=========================================================================="
echo "2) 校验新 DTB（这一步很关键，别跳）"
echo "=========================================================================="
# 说明：内核编出来的这个 DTB 里 /chosen 已经有 stdout-path = "serial0:115200n8"。
#       内核命令行本来由 kernelfat 里的 startup.nsh 传（fs3:\\Image console=...），
#       但**上一任已能启动的镜像**是同时往 DTB 的 chosen 里补了 bootargs 的，
#       所以这里也补一份（display 控制台兜底，双保险，多一份 bootargs 无副作用）。
WORK="$OUT/dtb-work"
rm -rf "$WORK"; mkdir -p "$WORK"
dtc -I dtb -O dts -o "$WORK/dtb.dts" "$DTB"
echo "反编译得到 $(wc -l < "$WORK/dtb.dts") 行 dts"

# --- 注入 bootargs（chosen 里没有才补）---
if grep -q 'bootargs' "$WORK/dtb.dts"; then
	echo "chosen 里已有 bootargs，不重复注入"
else
	# 在 "chosen {" 之后插入一行
	awk '/^[[:space:]]*chosen[[:space:]]*\{/ && !done {
		print
		print "\t\tbootargs = \"console=tty0 loglevel=7\";"
		done = 1
		next
	}
	{ print }' "$WORK/dtb.dts" > "$WORK/dtb.bootargs.dts"
	mv -f "$WORK/dtb.bootargs.dts" "$WORK/dtb.dts"
	echo "已注入 bootargs = \"console=tty0 loglevel=7\""
fi
grep -n -A3 'chosen {' "$WORK/dtb.dts" | head -6
dtc -I dts -O dtb -o "$WORK/dtb.patched.dtb" "$WORK/dtb.dts"
DTB="$WORK/dtb.patched.dtb"
echo "重新编码: $DTB ($(stat -c%s "$DTB") 字节)"
dtc -I dtb -O dts -o "$WORK/dtb.dts" "$DTB"

printf '%-34s %s\n' 'wifi@18800000 status' "$(awk '/wifi@18800000/{f=1} f&&/status/{print $0; exit}' "$WORK/dtb.dts" | tr -d '\t;')"
printf '%-34s %s\n' 'adsp remoteproc status' "$(awk '/remoteproc@17300000/{f=1} f&&/status/{print $0; exit}' "$WORK/dtb.dts" | tr -d '\t;')"
printf '%-34s %s\n' 'ufshc@1d84000 status' "$(awk '/ufshc@1d84000/{f=1} f&&/status/{print $0; exit}' "$WORK/dtb.dts" | tr -d '\t;')"
printf '%-34s %s\n' 'ufs phy@1d87000 status' "$(awk '/phy@1d87000/{f=1} f&&/status/{print $0; exit}' "$WORK/dtb.dts" | tr -d '\t;')"
for k in 'qcom/sm8150/adsp.mdt' 'qcom/sm8150/modem.mdt' 'vdd-0.8-cx-mx-supply' 'vdd-1.8-xo-supply' 'vdd-1.3-rfa-supply' 'vdd-3.3-ch0-supply' 'Xiaomi_raphael' 'stdout-path' \
         'vdd-3.3-ch1-supply' 'local-mac-address' 'rtc-offset@bc' \
         'nvmem-cell-names = "offset"' 'touchscreen@49' 'st,max-coords' 'st,irq-gpio'; do
	printf '%-34s %s\n' "$k" "$(grep -c -- "$k" "$WORK/dtb.dts")"
done

fail=0
grep -q 'qcom/sm8150/adsp.mdt'  "$WORK/dtb.dts" || { echo "✗ 缺 firmware-name=qcom/sm8150/adsp.mdt —— ADSP 不会 probe"; fail=1; }
grep -q 'vdd-0.8-cx-mx-supply'  "$WORK/dtb.dts" || { echo "✗ 缺 vdd-0.8-cx-mx-supply —— ath10k 会报 dummy regulator"; fail=1; }
grep -q 'bootargs'             "$WORK/dtb.dts" || { echo "✗ chosen 里没有 bootargs"; fail=1; }
awk '/wifi@18800000/{f=1} f&&/status = "okay"/{ok=1} f&&/^[[:space:]]*};/{exit} END{exit !ok}' "$WORK/dtb.dts" || { echo "✗ wifi@18800000 不是 okay"; fail=1; }
# ★ UFS：少这一段手机会卡死在 initramfs（内核看不到 /dev/sda*），
#   现象是“企鹅画出来了但日志不滚、Windows 也扫不到 USB”，很难反查，所以在编译期就拦住。
awk '/ufshc@1d84000/{f=1} f&&/status = "okay"/{ok=1} f&&/^[[:space:]]*};/{exit} END{exit !ok}' "$WORK/dtb.dts" || { echo "✗ ufshc@1d84000 不是 okay —— 内核看不到 /dev/sda*，必卡 initramfs"; fail=1; }
awk '/phy@1d87000/{f=1} f&&/status = "okay"/{ok=1} f&&/^[[:space:]]*};/{exit} END{exit !ok}' "$WORK/dtb.dts" || { echo "✗ ufs phy@1d87000 不是 okay —— UFS 起不来"; fail=1; }
grep -q 'vccq2-supply'          "$WORK/dtb.dts" || { echo "✗ ufshc 缺 vccq2-supply（1.8V）"; fail=1; }
grep -q 'vdda-phy-supply'       "$WORK/dtb.dts" || { echo "✗ ufs phy 缺 vdda-phy-supply"; fail=1; }

# ★★ 第 2 部分（cepheus-extra.dtsi，usb13 批次）的落地门禁。
#    这些项全部来自 usb12 冷启动实测的 err/warn 清单，缺一个就等于"改了没编进去"。
#    （dtc 输出里数值是 16 进制，所以只查属性名/节点名，不查数值。）
#    RTC：写时间要靠 nvmem offset cell（rtc-pm8xxx 的两条路之一，见 §10.13）
grep -q 'nvmem-cell-names = "offset"' "$WORK/dtb.dts" || { echo "✗ 缺 nvmem-cell-names = \"offset\" —— RTC 写时间会 -ENODEV（hwclock -w 失败）"; fail=1; }
grep -q 'rtc-offset@bc'               "$WORK/dtb.dts" || { echo "✗ 缺 rtc-offset@bc 节点 —— rtc-pm8xxx 拿不到 nvmem cell"; fail=1; }
#    WiFi：第 5 路电 + 固定 MAC
grep -q 'vdd-3.3-ch1-supply'          "$WORK/dtb.dts" || { echo "✗ 缺 vdd-3.3-ch1-supply —— ath10k 会报 dummy regulator warn"; fail=1; }
grep -q 'local-mac-address'           "$WORK/dtb.dts" || { echo "✗ 缺 local-mac-address —— 补丁 0002 拿不到 MAC，只能随机"; fail=1; }
grep -q 'st,irq-gpio'                 "$WORK/dtb.dts" || { echo "✗ 缺 st,irq-gpio —— FTS 触摸驱动拿不到中断（它不用 interrupts 属性）"; fail=1; }
grep -q 'st,max-coords'               "$WORK/dtb.dts" || { echo "✗ 缺 st,max-coords —— 触摸坐标会按驱动默认 1440x2560 算，全屏错位"; fail=1; }
grep -q 'touchscreen@49'              "$WORK/dtb.dts" || { echo "✗ 缺 touchscreen@49 —— 触摸节点没编进去"; fail=1; }
grep -q 'st,disable-auto-fw-update'   "$WORK/dtb.dts" || { echo "✗ 缺 st,disable-auto-fw-update —— 会反复 request_firmware 找不到 .ftb"; fail=1; }
#    蓝牙（第 3 部分 cepheus-bt.dtsi）：uart13 + WCN3990 四路供电
grep -q 'qcom,wcn3990-bt'             "$WORK/dtb.dts" || { echo "✗ 缺 qcom,wcn3990-bt —— 蓝牙节点没编进去（dts/cepheus-bt.dtsi）"; fail=1; }
grep -q 'vddch0-supply'               "$WORK/dtb.dts" || { echo "✗ 缺 vddch0-supply —— hci_qca 的 wcn3990 少一路电会 probe 失败"; fail=1; }
awk '/serial@c8c000/{f=1} f&&/status = "okay"/{ok=1} f&&/^[[:space:]]*};/{exit} END{exit !ok}' "$WORK/dtb.dts" || { echo "✗ serial@c8c000(uart13) 不是 okay —— 蓝牙串口没开"; fail=1; }
#    充电/电量计（第 4 部分 cepheus-chg.dtsi）：PM8150B charger + fuel-gauge
grep -q 'qcom,pm8150b-charger'        "$WORK/dtb.dts" || { echo "✗ 缺 qcom,pm8150b-charger —— 充电器节点没编进去（dts/cepheus-chg.dtsi）"; fail=1; }
grep -q 'qcom,pm8150b-fg'             "$WORK/dtb.dts" || { echo "✗ 缺 qcom,pm8150b-fg —— 电量计节点没编进去"; fail=1; }
awk '/charger@1000/{f=1} f&&/status = "okay"/{ok=1} f&&/^[[:space:]]*};/{exit} END{exit !ok}' "$WORK/dtb.dts" || { echo "✗ charger@1000 不是 okay —— power_supply 仍为空"; fail=1; }
awk '/fuel-gauge@4000/{f=1} f&&/status = "okay"/{ok=1} f&&/^[[:space:]]*};/{exit} END{exit !ok}' "$WORK/dtb.dts" || { echo "✗ fuel-gauge@4000 不是 okay —— 读不到电量"; fail=1; }
#    i2c17（SE17）与它的 QUP wrapper 必须是 okay，否则 i2c 设备根本不上总线
awk '/i2c@c80000/{f=1} f&&/status = "okay"/{ok=1} f&&/^[[:space:]]*};/{exit} END{exit !ok}' "$WORK/dtb.dts" || { echo "✗ i2c@c80000(i2c17) 不是 okay —— 触摸不会 probe"; fail=1; }
awk '/geniqup@cc0000/{f=1} f&&/status = "okay"/{ok=1} f&&/^[[:space:]]*};/{exit} END{exit !ok}' "$WORK/dtb.dts" || { echo "✗ geniqup@cc0000(SE17 wrapper) 不是 okay"; fail=1; }
#    ★ SE17 的 GPI DMA（gpi_dma2 @0xc00000）也必须是 okay。
#      SM8150 的 SE 硬件把 FIFO 接口禁了（GENI_IF_DISABLE_RO.FIFO_IF_DISABLE=1），
#      i2c-qcom-geni 只允许 GPI DMA 模式；拿不到 DMA 通道就整个 probe 失败
#      （-EPROBE_DEFER），i2c 总线上什么都不会出现，触摸静默不 probe。
awk '/dma-controller@c00000/{f=1} f&&/status = "okay"/{ok=1} f&&/^[[:space:]]*};/{exit} END{exit !ok}' "$WORK/dtb.dts" || { echo "✗ gpi_dma2(dma-controller@c00000) 不是 okay —— i2c17 拿不到 DMA 通道（geni_i2c: Failed to get tx DMA ch），触摸永远不 probe"; fail=1; }
#    ★ 反向门禁：显示栈**绝对不许**被打开（会顶掉 efifb → 黑屏，见 cepheus-extra.dtsi 文件头）
if awk '/display-subsystem@ae00000/{f=1} f&&/status = "okay"/{ok=1} f&&/^[[:space:]]*};/{exit} END{exit !ok}' "$WORK/dtb.dts"; then
	echo "✗ display-subsystem@ae00000 被打开了！没有面板驱动，efifb 会被顶掉 → 黑屏"
	fail=1
fi

[ "$fail" = 0 ] || { echo "DTB 不合格，先跑 apply-dts.sh + apply-dts2.sh 再重编内核（02 脚本会自动跑）" >&2; exit 1; }
echo "✓ DTB 校验通过（WiFi 段 + UFS 段 + RTC/WiFi 收尾/触摸段 都在；显示栈未开）"

echo
echo "=========================================================================="
echo "3) 替换 edk2 的 FdtBlob"
echo "=========================================================================="
mkdir -p "$FBDIR"
cp -f "$DTB" "$FB"
echo "新 FdtBlob: $FB ($(stat -c%s "$FB") 字节)  <- $DTB"
echo "（原版留档: $FB.edk2-orig）"

echo
echo "=========================================================================="
echo "4) 编 edk2（./build.sh --device cepheus）"
echo "=========================================================================="
cd "$ED"
LOG="$OUT/edk2-build.log"
set +e
./build.sh --device cepheus 2>&1 | tee "$LOG"
rc="${PIPESTATUS[0]}"
if [ "$rc" != 0 ]; then
	echo
	echo "第一次失败（rc=$rc）。用 --fixclang 再试一次"
	echo "（新版 clang 对 edk2 的 -Os 处理不同，edk2-msm 有个专门的开关）"
	./build.sh --device cepheus --fixclang 2>&1 | tee -a "$LOG"
	rc="${PIPESTATUS[0]}"
fi
set -e
[ "$rc" = 0 ] || { echo "edk2 编译失败，看日志 $LOG" >&2; exit 1; }

echo
echo "=========================================================================="
echo "5) 收集 boot-cepheus.img"
echo "=========================================================================="
IMG=""
for c in "$ED/boot-cepheus.img" "$ED/build/boot-cepheus.img" ./boot-cepheus.img; do
	[ -f "$c" ] && { IMG="$c"; break; }
done
if [ -z "$IMG" ]; then
	IMG="$(find "$ED" -maxdepth 2 -name 'boot-cepheus*.img' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
fi
[ -n "$IMG" ] || { echo "没找到 boot-cepheus.img，看日志 $LOG" >&2; exit 1; }

cp -v "$IMG" "$OUT/boot-cepheus.img"
echo
echo "产物: $OUT/boot-cepheus.img ($(stat -c%s "$OUT/boot-cepheus.img") 字节)"
echo "对照：交接包里的 boot-cepheus-*.img 是 6858752 字节（同量级即可）"

echo
echo "=========================================================================="
echo "6) ★ 终极校验：编出来的固件里到底有没有我们打补丁的 DTB"
echo "=========================================================================="
# 原理：DTB 作为 FFS 文件编进 FVMAIN，而 FVMAIN 被 LZMA 压进了 FVMAIN_COMPACT；
#       直接扫 boot-cepheus.img 是扫不到的（双层压缩）。
#       但 edk2 的中间产物里有**未压缩**的 FVMAIN.Fv，扫它最直接。
FVF="$(find "$ED" -type f -name 'FVMAIN.Fv' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
if [ -z "$FVF" ] || [ ! -f "$FVF" ]; then
	echo "⚠️  没找到未压缩的 FVMAIN.Fv，跳过（不影响刷机；上机后用"
	echo "    cat /proc/device-tree/soc@0/wifi@18800000/status 验证即可）"
else
	printf '未压缩固件: %s (%s 字节)\n' "$FVF" "$(stat -c%s "$FVF")"
	fvok=1
	for k in 'qcom/sm8150/adsp.mdt' 'vdd-0.8-cx-mx-supply' 'vdd-1.8-xo-supply' \
	         'vdd-1.3-rfa-supply' 'vdd-3.3-ch0-supply' 'Xiaomi_raphael' 'wcn3990-wifi' \
	         'vccq2-supply' 'vdda-phy-supply' 'qcom,sm8150-ufshc' \
	         'vdd-3.3-ch1-supply' 'nvmem-cell-names' 'rtc-offset' \
	         'touchscreen@49' 'st,max-coords' 'st,irq-gpio' \
	         'qcom,wcn3990-bt' 'vddch0-supply' \
	         'qcom,pm8150b-charger' 'qcom,pm8150b-fg'; do
		n="$(grep -a -c -- "$k" "$FVF" 2>/dev/null || true)"
		printf '   %-28s %s\n' "$k" "${n:-0}"
		[ "${n:-0}" -gt 0 ] || fvok=0
	done
	if [ "$fvok" = 1 ]; then
		echo "   ✓✓ 固件里确实含我们打补丁的 DTB —— 这个 boot 镜像是对的"
	else
		echo "   ✗ 固件里没找到我们的 DTB！FdtBlob 没被编进去（检查上面第 3 步的路径）"
		exit 1
	fi
fi
echo
echo "下一步：用 scripts/flash.ps1 刷 boot 分区（★ 不要 fastboot erase dtbo/vbmeta）"
echo "BUILD_EDK2_DONE"

