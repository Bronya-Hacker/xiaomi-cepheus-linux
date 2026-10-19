#!/bin/sh
# ---------------------------------------------------------------------------
# wifi-up.sh —— 按正确顺序把 WCN3990 WiFi 拉起来
#
# 顺序很重要（2026-10-18 实测定稿）：
#   1) QRTR 传输层（qrtr / qrtr-smd / qcom_glink_smem）
#   2) tqftpserv 先就绪
#   3) ★ 启动 modem（MPSS）——真正要 wlanmdsp.mbn 的是 **modem DSP**，不是 ADSP。
#      它通过 QRTR/TFTP 向 tqftpserv 要 /readonly/firmware/image/wlanmdsp.mbn，
#      这个文件就是要侧载给它的 WCN3990 固件。modem 不起来 = 永远没有 WLFW 服务。
#   4) 再拉 rmtfs + pd-mapper（rmtfs 要 modem 的 rproc fd；pd-mapper 给 modem
#      定位 PD 固件。这两样失败时 modem 会 `DOG detects stalled initialization`
#      每 ~40 秒崩一次，而且**不会**去要 wlanmdsp.mbn）
#   5) 启动 ADSP（remoteproc）
#   6) 最后 modprobe ath10k_snoc（它只注册 WLFW lookup，等 modem 的 WLAN 服务）
#
# 任何一个环节缺了都不会报错，只会"静默地没有 wlan0"。
#
# 见 wifi-bringup/README.md 第 1.3 节。日志写在 /run/wifi-up.log
# ---------------------------------------------------------------------------
set -u
LOG=/run/wifi-up.log
: > "$LOG"
log() { echo "[wifi-up] $*" | tee -a "$LOG"; }

# ---------------------------------------------------------------------------
# 0) 先补齐 tqftpserv 的运行时依赖
#    tqftpserv 的 NEEDED: libqrtr.so.1 / libzstd.so.1 / libc.so.6
#    手机 rootfs 一般没有 libqrtr1（Ubuntu main 里有但要单独装，而手机没网），
#    所以 payload 自带一份放在 /usr/lib/tqftpserv-bundle/，这里按需补进系统目录。
#    只在“系统里本来没有”时才动手，不覆盖已有文件。
# ---------------------------------------------------------------------------
LIBDIR=/usr/lib/aarch64-linux-gnu
BUNDLE=/usr/lib/tqftpserv-bundle
ensure_dep() {   # $1 = SONAME 文件名     $2 = bundle 里的实际文件名
	[ -e "$LIBDIR/$1" ] && return 0
	if [ -f "$BUNDLE/$2" ]; then
		cp -f "$BUNDLE/$2" "$LIBDIR/$2"
		ln -sf "$2" "$LIBDIR/$1"
		log "补上运行时依赖 $LIBDIR/$1"
		return 0
	fi
	log "!! 缺 $LIBDIR/$1，且 bundle 里没有 $2 —— tqftpserv 很可能起不来"
	return 1
}
ensure_dep libqrtr.so.1 libqrtr.so.1.0
ensure_dep libzstd.so.1 libzstd.so.1.5.5
command -v ldconfig >/dev/null 2>&1 && ldconfig 2>/dev/null

if [ ! -x /usr/bin/tqftpserv ]; then
	log "!! /usr/bin/tqftpserv 不存在（payload 没解包到？）—— 查: ls -l /usr/bin/tqftpserv"
fi

# --- ADSP 固件自检：DTB 里 firmware-name = "qcom/sm8150/adsp.mdt" ---
#     qcom_q6v5_pas 只会去 request_firmware() 这个名字，文件不在就 probe 失败。
if [ -s /lib/firmware/qcom/sm8150/adsp.mdt ]; then
	log "ADSP 固件: /lib/firmware/qcom/sm8150/adsp.mdt 存在（拆分固件）"
elif [ -s /lib/firmware/qcom/sm8150/adsp.mbn ]; then
	log "!! 只找到 adsp.mbn（单体固件），但 DTB 里写的是 qcom/sm8150/adsp.mdt —— 不匹配，ADSP 起不来"
	log "   解决：改用单体固件的话，要把 DTB 里 firmware-name 改成 qcom/sm8150/adsp.mbn 再重编 edk2"
else
	log "!! /lib/firmware/qcom/sm8150/ 下没有 adsp.mdt 也没有 adsp.mbn —— ADSP 不可能起来"
	log "   先看: ls -l /lib/firmware/qcom/sm8150/"
fi

modprobe qrtr           2>/dev/null
modprobe qrtr-smd       2>/dev/null
modprobe qcom_glink_smem 2>/dev/null
log "qrtr 传输层: $(lsmod | grep -cE '^(qrtr|qrtr_smd|qcom_glink)' ) 个模块"

# --- tqftpserv 必须先就绪 ---
systemctl start tqftpserv 2>/dev/null || true
if systemctl is-active --quiet tqftpserv; then
	log "tqftpserv 已运行"
else
	log "!! tqftpserv 没起来 —— wlan0 一定不会出现，先查: journalctl -u tqftpserv"
fi

rproc_of() {  # $1 = 远端名字(adsp/modem/...)
	for r in /sys/class/remoteproc/remoteproc*; do
		[ -r "$r/name" ] || continue
		[ "$(cat "$r/name" 2>/dev/null)" = "$1" ] && { echo "$r"; return 0; }
	done
	return 1
}

start_adsp() {
	modprobe qcom_q6v5_pas 2>/dev/null
	i=0
	while [ $i -lt 30 ]; do
		r="$(rproc_of adsp)" && \
			[ "$(cat "$r/state" 2>/dev/null)" = "running" ] && { log "ADSP running ($r)"; return 0; }
		sleep 1; i=$((i+1))
	done
	log "ADSP 30 秒内没到 running"
	return 1
}

restart_adsp() {
	r="$(rproc_of adsp)" || { log "找不到 adsp remoteproc"; return 1; }
	log "重启 ADSP 以重新触发 wlanmdsp.mbn 请求 ($r)"
	echo stop  > "$r/state" 2>/dev/null
	sleep 2
	echo start > "$r/state" 2>/dev/null
	i=0
	while [ $i -lt 30 ]; do
		[ "$(cat "$r/state" 2>/dev/null)" = "running" ] && { log "ADSP 重启后 running"; return 0; }
		sleep 1; i=$((i+1))
	done
	log "ADSP 重启后仍未 running"
	return 1
}

# --- ★★ modem（MPSS）才是真正"要 wlanmdsp.mbn"的那个 ---
#   WCN3990 的 wlanmdsp.mbn 是**侧载到 modem DSP** 的（ath10k 作者原话），
#   modem 启动时通过 QRTR/TFTP 向 tqftpserv 要 /readonly/firmware/image/wlanmdsp.mbn。
#   2026-10-18 实测：DTB 里 MPSS 节点没有 auto-boot，**没有任何东西会主动启动它**
#   → modem 一直 offline → 没有 WLFW 服务 → ath10k_snoc 的 qmi_add_lookup 永远不命中
#   → wlan0 永远不出现（而且不报任何新错，就是静默等待）。
#   所以这里必须显式启动 modem，并且顺序是：modem 先起（rmtfs 要它的 rproc fd），
#   再拉 rmtfs/pd-mapper，再让 modem 重新加载一次 PD。
start_modem() {
	modprobe qcom_q6v5_pas 2>/dev/null
	r="$(rproc_of modem)" || { log "找不到 modem remoteproc"; return 1; }
	if [ "$(cat "$r/state" 2>/dev/null)" = "running" ]; then
		log "modem 已在运行 ($r)"
		return 0
	fi
	log "启动 modem ($r) —— 它会向 tqftpserv 要 wlanmdsp.mbn"
	echo start > "$r/state" 2>/dev/null
	i=0
	while [ $i -lt 30 ]; do
		[ "$(cat "$r/state" 2>/dev/null)" = "running" ] && { log "modem running"; return 0; }
		sleep 1; i=$((i+1))
	done
	log "modem 30 秒内没到 running"
	return 1
}

restart_modem() {
	r="$(rproc_of modem)" || { log "找不到 modem remoteproc"; return 1; }
	log "重启 modem 以重新触发 wlanmdsp.mbn 请求 ($r)"
	echo stop  > "$r/state" 2>/dev/null
	sleep 2
	echo start > "$r/state" 2>/dev/null
	i=0
	while [ $i -lt 30 ]; do
		[ "$(cat "$r/state" 2>/dev/null)" = "running" ] && { log "modem 重启后 running"; return 0; }
		sleep 1; i=$((i+1))
	done
	log "modem 重启后仍未 running"
	return 1
}

wait_wlan0() {  # $1=秒
	i=0
	while [ $i -lt "$1" ]; do
		[ -e /sys/class/net/wlan0 ] && { log "wlan0 出现"; return 0; }
		sleep 1; i=$((i+1))
	done
	return 1
}

start_adsp  || true
start_modem || true

# --- rmtfs / pd-mapper：modem 靠它们才能读到自己的 PD 固件 --------------------
#   ★ 2026-10-18 实测的两个坑：
#     * 慢启动时它们会失败：rmtfs 报 `Failed to get rprocfd`（它要 modem 的
#       remoteproc fd，**必须 modem 先起来**），pd-mapper 报 `no pd maps available`；
#     * 它们失败时 modem 报 `DOG detects stalled initialization`，**每 ~40 秒崩一次**，
#       而且**不会**向 tqftpserv 要 wlanmdsp.mbn → WLFW 不出现 → wlan0 不出现。
#   rmtfs 一起来，modem 的崩溃循环立刻停止（实测 crash #24 是最后一次）。
for u in pd-mapper rmtfs; do
	# ★ 必须先 reset-failed：开机时这两个（尤其 pd-mapper）会在 modem 起来之前就试，
	#   失败几次后触发 systemd 的启动频率限制 → 单元永久 failed，此后
	#   `systemctl start` 会被一句 "Start request repeated too quickly" 直接拒掉。
	#   2026-10-18 实测：pd-mapper 就是这样从头到尾没跑起来过的。
	systemctl reset-failed "$u" 2>/dev/null
	systemctl is-active --quiet "$u" || systemctl start "$u" 2>/dev/null
done
log "pd-mapper=$(systemctl is-active pd-mapper 2>/dev/null) rmtfs=$(systemctl is-active rmtfs 2>/dev/null)"

log "加载 ath10k_snoc"
modprobe ath10k_snoc 2>/dev/null

if ! wait_wlan0 20; then
	# 典型竞态：modem 比 rmtfs/tqftpserv 先就绪，PD 固件没读到（或崩过一次），
	# 错过了 wlanmdsp.mbn 请求。按已知有效的做法重启一次 modem（实测 +4 秒出 wlan0），
	# 再不行才重启 ADSP。
	restart_modem || true
	modprobe ath10k_snoc 2>/dev/null
	if ! wait_wlan0 25; then
		restart_adsp || true
		modprobe ath10k_snoc 2>/dev/null
		wait_wlan0 25
	fi
fi

if [ ! -e /sys/class/net/wlan0 ]; then
	log "!! wlan0 仍然没有出现。诊断信息："
	{
		echo "--- dmesg (ath10k/qmi/qrtr/q6v5/adsp) ---"
		dmesg 2>/dev/null | grep -iE 'ath10k|wlfw|qmi|qrtr|glink|q6v5|adsp|remoteproc|wlanmdsp' | tail -60
		echo "--- remoteproc ---"
		for r in /sys/class/remoteproc/remoteproc*; do
			[ -r "$r/name" ] && echo "$(cat "$r/name"): $(cat "$r/state")"
		done
		echo "--- rmtfs / pd-mapper ---"
		for u in rmtfs pd-mapper tqftpserv; do
			echo "$u: $(systemctl is-active "$u" 2>/dev/null)"
		done
		echo "--- modem 崩溃次数 ---"
		dmesg 2>/dev/null | grep -c 'crash detected in modem'
		dmesg 2>/dev/null | grep 'crash detected in modem' | tail -3
		echo "--- rpmsg ---"
		ls /sys/bus/rpmsg/devices/ 2>/dev/null
		echo "--- journalctl -u tqftpserv ---"
		journalctl -u tqftpserv -n 30 --no-pager 2>/dev/null
	} >> "$LOG" 2>&1
	exit 0    # 不要因为失败阻塞启动
fi


# --- 等 NetworkManager 把 2.4G(560) 连上 -------------------------------------
# 档案随 payload 落在 /etc/NetworkManager/system-connections/560-wifi.nmconnection
# （autoconnect=yes，band=bg 锁 2.4G）。★ 绝对不要再在这里 enable
#   wpa_supplicant@wlan0 或者 nmcli con add 560_5G —— 那会造出第二个 supplicant /
#   第二个 autoconnect 档案，把 wlan0 从正在工作的连接上抢走（2026-10-18 的坑）。
if [ -d /etc/NetworkManager/system-connections ]; then
	chown root:root /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null
	chmod 600       /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null
fi

nm_active() { systemctl is-active --quiet NetworkManager 2>/dev/null; }

# ★ 2026-10-18 实测的坑：慢启动时 dbus.service 的首次启动可能被拖到超时，
#   于是 NetworkManager 的**依赖作业失败**，systemd 不会重试 → NM 永远不启动
#   → wlan0 永远连不上。这里主动把它拉起来（配合 payload 里的
#   /etc/systemd/system.conf.d/10-timeouts.conf 放宽默认启动超时，双保险）。
if ! nm_active; then
	log "NetworkManager 不活跃 → 主动拉起（可能是依赖作业被 dbus 超时带崩了）"
	systemctl start NetworkManager 2>/dev/null
	i=0
	while [ $i -lt 30 ] && ! nm_active; do sleep 2; i=$((i+2)); done
fi

if nm_active; then
	# ★★ 自愈：老版本 wifi-up（在"NM 不活跃"分支里）会把
	#   /etc/systemd/network/25-wlan0.network 从 .unused 启用起来，而
	#   systemd-networkd **自己不做 WPA2**（靠 wpa_supplicant@wlan0，那个单元
	#   被我们 mask 了），于是 networkd 会一直霸占 wlan0 → NM 连不上。
	#   症状：`NetworkManager=active` 但 wlan0 没有任何连接、网络不可达
	#   （2026-10-18 实测踩到）。只要 NM 在跑，就必须确保这张配置不在生效位置。
	if [ -f /etc/systemd/network/25-wlan0.network ]; then
		log "发现过期的 25-wlan0.network（networkd 会和 NM 抢 wlan0）→ 收回成 .unused"
		mv -f /etc/systemd/network/25-wlan0.network \
		      /etc/systemd/network/25-wlan0.network.unused
	fi
	# ★ NM 的连接档案必须是 0600，否则 NM 直接拒绝加载：
	#     keyfile: load: ".../560-wifi.nmconnection": failed to load connection:
	#              File permissions (100777) are insecure
	#   症状是 `nmcli con show` 里没有 560、wlan0 一直 unmanaged/disconnected
	#   （2026-10-18 实测踩到）。而且**改完权限 NM 不会自动重读**，必须 reload。
	#   payload 打包时已经是 600，这里是对旧设备/旧解包的兜底。
	chmod 600 /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null
	# --- 连接档案名不再写死（srv9）：取第一个 WiFi 档案 ---
	# 迁移：旧版 560-wifi.nmconnection 与新的 mi9-wifi.nmconnection 重复时，挪走旧的
	if [ -f /etc/NetworkManager/system-connections/560-wifi.nmconnection ] && \
	   [ -f /etc/NetworkManager/system-connections/mi9-wifi.nmconnection ]; then
		mv -f /etc/NetworkManager/system-connections/560-wifi.nmconnection \
		      /root/560-wifi.nmconnection.legacy 2>/dev/null
		log "迁移：旧档案 560-wifi.nmconnection -> /root/*.legacy"
		nmcli con reload 2>/dev/null || true
	fi
	WIFI_CONN="$(nmcli -t -f NAME,TYPE con show 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1; exit}')"
	if [ -z "$WIFI_CONN" ]; then
		log "NM 里没有 560 档案 → chmod 600 + nmcli con reload"
		nmcli con reload 2>/dev/null || systemctl reload NetworkManager 2>/dev/null
	fi
	i=0
	while [ $i -lt 90 ]; do
		nmcli -t -f GENERAL.STATE dev show wlan0 2>/dev/null | grep -q '(connected)' && break
		sleep 2; i=$((i+2))
	done
	if nmcli -t -f GENERAL.STATE dev show wlan0 2>/dev/null | grep -q '(connected)'; then
		log "NM 已自动连上：$(nmcli -t -f GENERAL.CONNECTION dev show wlan0 2>/dev/null)"
	else
		log "NM 还没连上，主动 up 一次 560"
		nmcli con up "$WIFI_CONN" 2>/dev/null || log "!! nmcli con up 560 失败（看 nmcli dev status）"
	fi
else
	# 只有"根本没有 NetworkManager"的 rootfs 才走这条路。
	# ★ 注意：systemd-networkd **自己不会做 WPA2**，它靠 wpa_supplicant@<if> 单元，
	#   所以这里必须把它解除 mask，否则启用 networkd 也是白忙（2026-10-18 实测）。
	log "这个 rootfs 没有 NetworkManager → systemd-networkd 兜底（需要 wpa_supplicant@wlan0）"
	systemctl unmask wpa_supplicant@wlan0 2>/dev/null
	[ -f /etc/systemd/network/25-wlan0.network.unused ] && \
		mv -f /etc/systemd/network/25-wlan0.network.unused /etc/systemd/network/25-wlan0.network
	systemctl enable --now systemd-networkd 2>/dev/null || true
fi

# --- 把自检结果打到手机屏幕 ------------------------------------------------
# 用户没法在手机上打字，屏幕是唯一能直接看到结果的地方。
# ★ 必须用 ASCII：fbcon 的 TER16x32 字体没有 CJK 字形，中文只会变成方块。
screen_report() {
	ver="$(cat /etc/wifi-cfg.ver 2>/dev/null)"
	ssid="$(nmcli -t -f GENERAL.CONNECTION dev show wlan0 2>/dev/null | cut -d: -f2)"
	ip4="$(ip -4 -o addr show wlan0 2>/dev/null | awk '{print $4}')"
	mdm="$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)"
	rmt="$(systemctl is-active rmtfs 2>/dev/null)"
	{
		echo ""
		echo "=================================================="
		echo " Xiaomi 9 (cepheus) mainline Linux - WiFi check"
		echo " payload : ${ver:-?}"
		echo " WiFi    : ${ssid:-not-connected}  ${ip4}"
		echo " modem   : ${mdm:-?}   rmtfs: ${rmt:-?}"
		echo " SSH     : ssh umeko@192.168.2.2"
		echo "=================================================="
	} >/dev/tty0 2>/dev/null
	return 0
}
screen_report

log "wifi-up 完成。检查: ip -4 addr show wlan0 / nmcli dev status"
exit 0
