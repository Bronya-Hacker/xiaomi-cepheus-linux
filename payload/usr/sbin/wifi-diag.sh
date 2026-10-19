#!/bin/sh
# ---------------------------------------------------------------------------
# wifi-diag.sh —— 一条命令把 WiFi 链路每层状态打出来
#
#   用法：  sh /usr/sbin/wifi-diag.sh            # 打到屏幕
#           sh /usr/sbin/wifi-diag.sh > /tmp/d.txt && cat /tmp/d.txt
#
# 对应 docs/verify.md 的第 0~6 关。哪一关断了，输出里一眼能看出来。
# ---------------------------------------------------------------------------
PATH=/bin:/sbin:/usr/bin:/usr/sbin
W=/proc/device-tree/soc@0/wifi@18800000
ADSP=/proc/device-tree/soc@0/remoteproc@17300000
ADSPM=/proc/device-tree/soc@0/remoteproc@4080000
UFS=/proc/device-tree/soc@0/ufshc@1d84000
UFSPHY=/proc/device-tree/soc@0/phy@1d87000
CHOSEN=/proc/device-tree/chosen
FWFW=/lib/firmware/qcom/sm8150
ATHFW=/lib/firmware/ath10k/WCN3990/hw1.0

hr() { echo; echo "=================== $* ==================="; }

hr "0. 环境"
uname -a
echo "cmdline: $(cat /proc/cmdline 2>/dev/null)"
echo "网络接口: $(ls /sys/class/net 2>/dev/null | tr '\n' ' ')"
echo "块设备: $(ls /dev/sd* /dev/mmcblk* 2>/dev/null | tr '\n' ' ')"
echo "rootfs: $(findmnt -no SOURCE / 2>/dev/null || awk '$2=="/"{print $1}' /proc/mounts)"

hr "0. 第0关 DTB（期望 ufshc=okay / ufsphy=okay / wifi=okay / adsp=okay）"
for u in "$UFS:ufshc@1d84000(UFS 控制器)" \
         "$UFSPHY:phy@1d87000(UFS PHY)"; do
	node="${u%%:*}"; desc="${u##*:}"
	if [ -e "$node" ]; then
		s="$(cat "$node/status" 2>/dev/null)"
		if [ "$s" = "okay" ]; then
			printf '%-30s: %s\n' "$desc" "$s"
		else
			printf '%-30s: %s  ← ★ 不对！UFS 起不来 → 内核看不到 /dev/sda*（见 README 4.7）\n' "$desc" "${s:-（无）}"
		fi
	else
		printf '%-30s: 找不到节点\n' "$desc"
	fi
done
if [ -d "$W" ]; then
	printf 'wifi@18800000/status          : %s\n' "$(cat $W/status 2>/dev/null)"
	for p in vdd-0.8-cx-mx-supply vdd-1.8-xo-supply vdd-1.3-rfa-supply vdd-3.3-ch0-supply; do
		if [ -e "$W/$p" ]; then
			printf '%-30s: 存在 (%s)\n' "$p" "$(od -An -tx1 "$W/$p" | tr -d ' \n')"
		else
			printf '%-30s: ✗ 缺失（ath10k 会报 dummy regulator）\n' "$p"
		fi
	done
	printf 'calibration-variant           : %s\n' "$(cat $W/qcom,calibration-variant 2>/dev/null)"
else
	echo "✗ 找不到 $W —— DTB 没换！（edk2/boot 分区没刷成功）"
fi
if [ -d "$ADSP" ]; then
	printf 'adsp remoteproc status         : %s\n' "$(cat $ADSP/status 2>/dev/null)"
	printf 'adsp firmware-name            : %s\n' "$(cat $ADSP/firmware-name 2>/dev/null)"
	printf 'adsp glink-edge label         : %s\n' "$(cat $ADSP/glink-edge/label 2>/dev/null)"
else
	echo "✗ 找不到 $ADSP —— DTB 里 adsp 节点都没有"
fi
[ -d "$ADSPM" ] && printf 'mpss firmware-name            : %s\n' "$(cat $ADSPM/firmware-name 2>/dev/null)"
# 这一行能确认"刷进去的确实是新编的 edk2"：bootargs 是我们 03 脚本注入的
if [ -e "$CHOSEN/bootargs" ]; then
	printf 'chosen/bootargs               : %s\n' "$(cat $CHOSEN/bootargs 2>/dev/null)"
else
	printf 'chosen/bootargs               : (无) ← 03 脚本注入过 bootargs，没有说明 boot 镜像不是我们编的\n'
fi
printf 'chosen/stdout-path            : %s\n' "$(cat $CHOSEN/stdout-path 2>/dev/null)"

hr "1. 第1关 固件文件（全都要有）"
for f in "$FWFW/adsp.mdt" "$FWFW/adsp.mbn" "$FWFW/wlanmdsp.mbn" \
         "$ATHFW/board-2.bin" "$ATHFW/wlanmdsp.mbn" "$ATHFW/firmware-5.bin"; do
	if [ -s "$f" ]; then printf '  ✓ %-52s %s 字节\n' "$f" "$(stat -c%s "$f")"; else printf '  ✗ %s  ← 缺失\n' "$f"; fi
done
echo "--- /lib/firmware/qcom/sm8150/ 内容 ---"
ls -l "$FWFW" 2>/dev/null | head -30
if [ -s "$ATHFW/board-2.bin" ] && command -v strings >/dev/null 2>&1; then
	printf 'board-2.bin 里的 qmi-chip-id: '
	strings "$ATHFW/board-2.bin" | grep -oE 'qmi-chip-id=[0-9]+' | sed 's/qmi-chip-id=//' | sort -un | tr '\n' ' '
	echo
	strings "$ATHFW/board-2.bin" | grep -q 'qmi-chip-id=30224' \
		&& echo "  ✓ 含 30224（WCN3990 on sm8150 要的就是它）" \
		|| echo "  ✗ 不含 30224 ← ath10k 会 failed to fetch board data"
fi

hr "2. 第2关 模块 / QRTR 传输层"
lsmod 2>/dev/null | grep -E 'qrtr|glink|q6v5|ath10k|remoteproc|qmi' || echo "(一个都没加载)"
echo "--- 期望里的模块文件是否存在 ---"
KREL=$(uname -r)
for m in qrtr qrtr-smd qcom_glink_smem qcom_q6v5_pas ath10k_snoc; do
	f=$(find "/lib/modules/$KREL" -name "${m//-/_}.ko*" 2>/dev/null | head -1)
	[ -n "$f" ] && echo "  ✓ $m -> $f" || echo "  ✗ $m 找不到（mods.tar.gz 没装对或 depmod 没跑）"
done
echo "--- rpmsg 通道（有 IPCRTR 说明 ADSP 的 glink 起来了）---"
ls /sys/bus/rpmsg/devices/ 2>/dev/null || echo "(空)"
echo "--- 光说 rpmsg 设备 ---"
ls /sys/class/rpmsg/ 2>/dev/null || echo "(空)"

hr "3. 第3关 ADSP"
echo "--- AOSS QMP（SM8150 的 ADSP 必须靠它出复位；DTB 里 adsp 有 qcom,qmp=<&aoss_qmp>）---"
ls /sys/bus/platform/drivers/qcom_aoss_qmp/ 2>/dev/null | grep -v '^\s*$' || echo "  ⚠ 没有 sysfs 目录（可能驱动没加载，看下一步 dmesg）"
for r in /sys/class/remoteproc/remoteproc*; do
	[ -d "$r" ] || continue
	printf '  %-14s name=%-8s state=%s\n' "$(basename $r)" "$(cat $r/name 2>/dev/null)" "$(cat $r/state 2>/dev/null)"
done 2>/dev/null || echo "(没有 remoteproc)"
echo "--- 日志 ---"
dmesg 2>/dev/null | grep -iE 'q6v5|remoteproc|adsp|pas |mdt|firmware' | tail -40

hr "4. 第4关 tqftpserv"
systemctl is-active tqftpserv 2>/dev/null
systemctl status tqftpserv --no-pager 2>/dev/null | head -15
echo "--- 二进制 / 依赖 ---"
ls -l /usr/bin/tqftpserv 2>/dev/null || echo "✗ /usr/bin/tqftpserv 不存在"
ls -l /usr/lib/tqftpserv-bundle/ 2>/dev/null
ls -l /usr/lib/aarch64-linux-gnu/libqrtr.so.1* 2>/dev/null || echo "✗ libqrtr.so.1 缺（wifi-up.sh 应该会自动补）"
echo "--- journalctl -u tqftpserv ---"
journalctl -u tqftpserv -n 60 --no-pager 2>/dev/null

hr "5. 第5关 wlan0 / ath10k"
ip link show wlan0 2>/dev/null || echo "✗ 没有 wlan0"
dmesg 2>/dev/null | grep -iE 'ath10k|wlfw|wcn3990|board|qmi|qrtr' | tail -60

hr "6. 第6关 联网"
echo "--- 连接工具在不在（手机没网，装不了，只能看有没有）---"
for t in wpa_supplicant wpa_cli iw iwconfig dhclient nmcli; do
	if command -v "$t" >/dev/null 2>&1; then echo "  ✓ $t -> $(command -v $t)"; else echo "  ✗ $t 没有"; fi
done
echo "--- wpa_supplicant@.service 模板在不在（Debian/Ubuntu 由 wpasupplicant 包提供）---"
ls /lib/systemd/system/wpa_supplicant@.service /usr/lib/systemd/system/wpa_supplicant@.service 2>/dev/null \
	|| echo "  ✗ 没有这个模板 —— 需要 rootfs 里已装 wpasupplicant"
ip -4 addr show wlan0 2>/dev/null
systemctl is-active wpa_supplicant@wlan0 systemd-networkd NetworkManager 2>/dev/null
[ -x /usr/sbin/iw ] && iw dev wlan0 link 2>/dev/null
ip route 2>/dev/null

hr "自带的 wifi-up 日志"
cat /run/wifi-up.log 2>/dev/null || echo "(没有 /run/wifi-up.log —— wifi-up.service 没跑过？)"

hr "wifi-cfg 里的配置文件有没有到位"
for f in /etc/systemd/system/tqftpserv.service /etc/systemd/system/wifi-up.service \
         /etc/modules-load.d/wifi.conf /etc/modprobe.d/wifi-order.conf \
         /etc/wpa_supplicant/wpa_supplicant-wlan0.conf \
         /etc/NetworkManager/system-connections/560-wifi.nmconnection \
         /etc/systemd/network/25-wlan0.network.unused; do
	[ -e "$f" ] && echo "  ✓ $f" || echo "  ✗ $f  ← payload 没解包到"
done
echo "--- 不该存在的东西（存在就是有人又把它打开了）---"
for f in /etc/systemd/network/25-wlan0.network; do
	[ -e "$f" ] && echo "  ⚠ $f 存在！networkd 会和 NetworkManager 抢 wlan0" || echo "  ✓ 没有 $f"
done
echo "--- NM 档案权限（必须是 600，否则 NM 会忽略）---"
ls -l /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null || echo "  (没有 NM 档案)"
echo "--- NM 里谁是 autoconnect=yes（期望只有 560）---"
nmcli -t -f NAME,UUID,AUTOCONNECT con show 2>/dev/null | sed 's/^/  /'

echo
echo "=================== 诊断结束 ==================="
echo "把上面整段发回来即可定位。也可先看 docs/verify.md 的『一键诊断』一节。"
