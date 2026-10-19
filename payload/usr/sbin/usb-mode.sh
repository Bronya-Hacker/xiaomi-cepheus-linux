#!/bin/sh
# ---------------------------------------------------------------------------
# usb-mode.sh —— 用 configfs 建 / 切 / 守 USB gadget（NCM 或 RNDIS 网卡 + ACM 串口）
#
#   usb-mode.sh up [ncm|rndis|acm]    建好并绑定（默认 ncm）
#   usb-mode.sh check [ncm|rndis]     查：期望的模式是否正跑着（返回码 0/1）
#   usb-mode.sh switch <mode> [秒]    切换；<秒>（默认 90）内没有
#                                     touch /tmp/usb-mode.keep 就自动回滚到旧模式
#   usb-mode.sh keep                  确认新模式可用，取消回滚
#   usb-mode.sh down                  解绑
#   usb-mode.sh status                报告状态
#
# 为什么默认 ncm：
#   2026-10-17 前人实测「NCM + ACM」时 Windows 能枚举成功并出现 COM4 串口，
#   而 RNDIS 因为 MS OS 兼容 ID 没设对（f_rndis 的 ext_compat_id 默认全 0），
#   Windows 一直认不出设备。这台手机唯一的交互通道就是 USB，所以：
#     启动时先用**能枚举成功**的 NCM+ACM 拿到串口控制台，
#     再用 `usb-mode.sh switch rndis` 试 RNDIS，90 秒内没人 keep 就自动回滚
#     —— 就算 RNDIS 把设备搞挂，串口也会自己回来，不会失去通道。
#
# 两个模式都会带 ACM 串口功能（设备节点 /dev/ttyGS0，Windows 上是 COMx）。
#
# ★ 2026-10-18 补：手机 rootfs 里已有一个「自己的」gadget 服务（idProduct=0x4e26、
#   序列号 CEPHEUS）。实测它在 Windows 上是「USB Composite Device 启动失败
#   (代码 10)」——枚举不出来，既没有网卡也没有串口。所以本脚本会：
#     1) neutralize：把 rootfs 里会抢 configfs gadget 的 systemd 单元按掉/屏蔽
#     2) do_up 之后起一个 5 分钟的看护循环（每 30 秒 check 一次，被抢就重建）
# ---------------------------------------------------------------------------
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

G=/sys/kernel/config/usb_gadget/g1
STATE=/tmp/usb-mode.state
KEEP=/tmp/usb-mode.keep
LOG=/tmp/usb-mode.log
SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"

log() { echo "[usb] $*"; echo "[usb] $*" >>"$LOG" 2>/dev/null; }
# say：既进日志/stdout，也强制打到手机屏幕（tty0），这样用户只读屏幕也能看到
say() { log "$@"; echo "$*" >/dev/tty0 2>/dev/null; }

udc_name() { ls /sys/class/udc/ 2>/dev/null | head -1; }
mount_cfg() { mount -t configfs none /sys/kernel/config 2>/dev/null; }

unbind() {
	[ -f "$G/UDC" ] || return 0
	echo "" >"$G/UDC" 2>/dev/null
	sleep 1
	return 0
}

similar_mode() { case "$1" in rndis) echo 0x4e26 ;; *) echo 0x4ee2 ;; esac; }

# 期望的 gadget 是否正跑着（返回 0 = 是）
gadget_ok() {
	want="${1:-ncm}"
	[ "$(cat "$G/idProduct" 2>/dev/null)" = "$(similar_mode "$want")" ] || return 1
	[ -n "$(cat "$G/UDC" 2>/dev/null)" ] || return 1
	[ -L "$G/configs/c.1/acm.usb0" ] || return 1
	if [ "$want" = "rndis" ]; then
		[ -L "$G/configs/c.1/rndis.usb0" ] || return 1
	elif [ "$want" = "acm" ]; then
		:
	else
		[ -L "$G/configs/c.1/ncm.usb0" ] || return 1
	fi
	return 0
}

# 把 rootfs 里会抢 gadget 的 systemd 单元按掉（我们自己的除外）
neutralize() {
	[ -d /etc/systemd/system ] || return 0
	command -v systemctl >/dev/null 2>&1 || return 0
	for f in $(find /etc/systemd/system -maxdepth 3 \( -name '*.service' -o -name '*.timer' \) 2>/dev/null); do
		[ -f "$f" ] || continue
		b="$(basename "$f")"
		case "$b" in
			usb-net.service|usb-net-reassert*|sys-*|systemd-*) continue ;;
			# ★ 串口/getty 相关的一律不碰：那是这台手机唯一的交互通道
			*getty*|autotty*|*ttyGS*) continue ;;
		esac
		# 只要单元文件里出现「在建 gadget」的痕迹就按掉。
		# 前人的 usb-gadget.service（Description=USB gadget setup (net+serial)，
		# ExecStart=/usr/local/bin/usb-gadget-setup.sh，WantedBy=multi-user.target）
		# 就是靠 usb[-_ ]?gadget 命中的（旧正则只认下划线，漏掉了它）。
		grep -qiE 'usb[-_ ]?gadget|gadget[-_ ]?(setup|init)|configfs|sys-kernel-config|RNDIS|rndis\.usb0|ncm\.usb0|acm\.usb0|echo .*UDC' "$f" 2>/dev/null || continue
		log "按掉会抢 USB gadget 的单元：$b"
		# ★ 用 timeout 兜住：万一某个单元的 stop 卡住（比如 getty 卡在 ttyGS0 的写上），
		#   不能让整个 usb-net.service 卡到超时（那会把 NM/wifi-up 一起拖后 3 分钟）。
		timeout 10 systemctl disable --now "$b" >/dev/null 2>&1
		systemctl mask "$b"        >/dev/null 2>&1
	done
	return 0
}

set_ids() {
	mode="$1"
	echo 0x18d1 >"$G/idVendor"
	echo "$(similar_mode "$mode")" >"$G/idProduct"
	echo 0x0201 >"$G/bcdUSB"
	echo 0x0100 >"$G/bcdDevice"
}

mk_strings() {
	mkdir -p "$G/strings/0x409" "$G/configs/c.1/strings/0x409"
	echo "Xiaomi"            >"$G/strings/0x409/manufacturer"
	echo "cepheus-linux"     >"$G/strings/0x409/product"
	echo "cepheus-mainline"  >"$G/strings/0x409/serialnumber"
	echo "Linux USB"         >"$G/configs/c.1/strings/0x409/configuration"
}

link_funcs() {
	mode="$1"
	rm -f "$G/configs/c.1/ncm.usb0" "$G/configs/c.1/rndis.usb0" "$G/configs/c.1/acm.usb0"
	case "$mode" in
	ncm)
		mkdir -p "$G/functions/ncm.usb0"
		ln -sf "$G/functions/ncm.usb0" "$G/configs/c.1/ncm.usb0"
		;;
	rndis)
		mkdir -p "$G/functions/rndis.usb0"
		# ★★ 让 Windows 认成「Remote NDIS Compatible Device」的两件事：
		#   1) 打开 MS OS 描述符（os_desc/use + 0xcd + MSFT100 + config 软链）
		#   2) 把 RNDIS 接口的兼容 ID 写成 "RNDIS"（默认是全 0，Windows 认不出！）
		mkdir -p "$G/os_desc"
		echo 1       >"$G/os_desc/use"
		echo 0xcd    >"$G/os_desc/b_vendor_code"
		echo MSFT100 >"$G/os_desc/qw_sign"
		echo RNDIS   >"$G/functions/rndis.usb0/os_desc/interface.rndis/compatible_id" 2>/dev/null
		echo 5162001 >"$G/functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id" 2>/dev/null
		rm -f "$G/os_desc/c.1"
		ln -sf "$G/configs/c.1" "$G/os_desc/c.1"
		ln -sf "$G/functions/rndis.usb0" "$G/configs/c.1/rndis.usb0"
		;;
	esac
}

bind() {
	udc="$(udc_name)"
	[ -n "$udc" ] || { log "★ 没有 UDC：dwc3/PHY 没起来，USB 不可能工作"; return 1; }
	echo "$udc" >"$G/UDC" || { log "★ 绑定 UDC=$udc 失败"; return 1; }
	log "已绑定 UDC=$udc"
	return 0
}

net_up() {
	i=0
	while [ $i -lt 15 ]; do
		[ -d /sys/class/net/usb0 ] && break
		i=$((i + 1))
		sleep 1
	done
	if [ ! -d /sys/class/net/usb0 ]; then
		log "没有出现 usb0（这个模式不带网卡功能？）"
		return 1
	fi
	ip link set usb0 up 2>/dev/null
	ip addr add 192.168.2.2/24  dev usb0 2>/dev/null
	ip addr add 169.254.42.1/16 dev usb0 2>/dev/null
	log "usb0 就绪: $(ip addr show usb0 2>/dev/null | grep -o 'inet [0-9.]*' | tr '\n' ' ')"
	return 0
}

ensure_console() {
	command -v systemctl >/dev/null 2>&1 || return 0
	# ★★ 绝对不要 restart getty！
	#   2026-10-18 实测：ttyGS0 上没有人读的时候，getty 的写会阻塞，
	#   `systemctl restart serial-getty@ttyGS0.service` 会卡到作业超时（卡满 180 秒），
	#   而 usb-net.service 是 `Before=network-pre.target` →
	#   NetworkManager / wifi-up 全被拖后整整 3 分钟（WiFi 因此 3 分钟才可用）。
	#   已经 active 就完全不动它；真要拉起也用 --no-block，不等它。
	systemctl is-active --quiet serial-getty@ttyGS0.service 2>/dev/null || \
		systemctl start --no-block serial-getty@ttyGS0.service 2>/dev/null
	systemctl is-active --quiet getty@tty1.service 2>/dev/null || \
		systemctl start --no-block getty@tty1.service 2>/dev/null
	return 0
}

try_sshd() {
	command -v systemctl >/dev/null 2>&1 || return 1
	# ★★ 也绝对不能**同步** start ssh.service：
	#   本单元是 `Before=network-pre.target`，而 `ssh.service` 是 `After=network.target`
	#   （network.target 在 network-pre.target 之后）→ 同步 start 会和自己的依赖互等，
	#   一直卡到 180 秒超时为止。2026-10-18 实测：SSH 直到 +234 秒才可用，
	#   正好是 usb-net 超时（+233 秒）之后 —— 连"明明是网卡的问题"都算不上，
	#   纯粹是这个顺序死锁。所以这里只查状态 + `--no-block` 拉一把。
	rc=1
	for u in ssh.service sshd.service; do
		if systemctl is-active --quiet "$u" 2>/dev/null; then
			log "$u 已在运行"
			rc=0
		else
			systemctl start --no-block "$u" 2>/dev/null
		fi
	done
	[ "$rc" = 0 ] && return 0
	# 走到这里说明 ssh/sshd 单元都还没 active（正常：multi-user 稍后会拉起它们）。
	# 只有当系统里**根本没有**这两个单元时才退化成直接起 sshd。
	if systemctl list-unit-files 'ssh*.service' 2>/dev/null | grep -q 'ssh'; then
		return 1
	fi
	for s in /usr/sbin/sshd /usr/bin/sshd; do
		if [ -x "$s" ]; then
			"$s" >/dev/null 2>&1 && { log "$s 已直接启动"; return 0; }
		fi
	done
	log "没找到能启动的 sshd（rootfs 里没装？）"
	return 1
}

banner() {
	mode="${1:-$(cat "$STATE" 2>/dev/null)}"
	say "==================== USB 就绪 ===================="
	say " 模式   : $mode"
	say " 串口   : /dev/ttyGS0   (Windows: COMx, 115200 8N1)"
	if ip addr show usb0 >/dev/null 2>&1; then
		say " 网口   : usb0  $(ip addr show usb0 2>/dev/null | grep -o 'inet [0-9./]*' | tr '\n' ' ')"
	fi
	if ip addr show wlan0 >/dev/null 2>&1; then
		say " WiFi   : wlan0 $(ip addr show wlan0 2>/dev/null | grep -o 'inet [0-9./]*' | tr '\n' ' ')"
	fi
	say " SSH    : ssh umeko@192.168.2.2    或   169.254.42.1"
	say " 切换   : usb-mode.sh switch rndis | switch ncm | keep"
	say " 状态   : usb-mode.sh status"
}

# 5 分钟看护：每 30 秒确认一次我们的 gadget 还在，被别人抢了就重建
start_guard() {
	mode="$1"
	[ -d /run ] || return 0
	command -v setsid >/dev/null 2>&1 || return 0
	setsid sh -c 'i=0
		while [ $i -lt 10 ]; do
			sleep 30
			if ! '"$SELF"' check '"$mode"' >/dev/null 2>&1; then
				echo "[usb] 看护：gadget 被抢了，重建 '"$mode"'" >>'"$LOG"' 2>/dev/null
				'"$SELF"' up '"$mode"' >>'"$LOG"' 2>&1
			fi
			i=$((i + 1))
		done' >/dev/null 2>&1 &
	return 0
}

do_up() {
	mode="${1:-ncm}"
	# ★★ 快路径：gadget 已经就绪（一般是 initramfs 阶段 /sbin/usb-mode.sh 建好的）就不重建。
	#   重建会 unbind/rebind UDC → Windows 侧设备号和 COM 口重新枚举（这正是
	#   "启动过程中 COM 口消失 / NCM MAC 变掉"的来源），而且多花时间。
	#   实测 rootfs 阶段 gadget 本来就是好的，所以这里只补网卡地址 + 收尾。
	if gadget_ok "$mode"; then
		log "gadget 已就绪（$mode），跳过重建（不重新枚举 USB）"
		echo "$mode" >"$STATE" 2>/dev/null
		net_up
		ensure_console
		try_sshd
		banner "$mode"
		return 0
	fi
	neutralize
	mount_cfg
	mkdir -p "$G"
	unbind
	set_ids "$mode"
	mk_strings
	link_funcs "$mode"
	mkdir -p "$G/functions/acm.usb0"
	ln -sf "$G/functions/acm.usb0" "$G/configs/c.1/acm.usb0"
	bind || return 1
	echo "$mode" >"$STATE" 2>/dev/null
	net_up
	ensure_console
	try_sshd
	banner "$mode"
	return 0
}

case "${1:-status}" in
up)
	do_up "${2:-ncm}"
	;;
check)
	gadget_ok "${2:-ncm}" && { echo "ok"; exit 0; } || { echo "not-ok"; exit 1; }
	;;
switch)
	new="${2:-rndis}"
	to="${3:-90}"
	old="$(cat "$STATE" 2>/dev/null || echo ncm)"
	if [ "$new" = "$old" ] && gadget_ok "$new"; then log "当前已经是 $new"; exit 0; fi
	rm -f "$KEEP"
	log "切换 $old -> $new（${to} 秒内不 touch $KEEP 就自动回滚到 $old）"
	do_up "$new" || { log "切换失败，直接回滚"; do_up "$old"; exit 1; }
	(
		sleep "$to"
		if [ ! -f "$KEEP" ]; then
			log "看门狗：没人执行 keep，回滚到 $old"
			do_up "$old"
		fi
	) >/tmp/usb-mode-watchdog.log 2>&1 &
	log "看门狗已启动；确认 Windows 那边能认出来后执行： usb-mode.sh keep"
	;;
keep)
	: >"$KEEP"
	log "已确认当前模式可用（$KEEP），看门狗不会再回滚"
	;;
guard)
	start_guard "${2:-ncm}"
	;;
down)
	unbind
	log "已解绑 UDC"
	;;
status)
	log "状态:"
	log "  UDC       : $(udc_name)"
	log "  已绑定    : $(cat "$G/UDC" 2>/dev/null)"
	log "  idProduct : $(cat "$G/idProduct" 2>/dev/null)  ($(cat "$STATE" 2>/dev/null))"
	log "  函数      : $(ls "$G/configs/c.1" 2>/dev/null | tr '\n' ' ')"
	log "  os_desc   : use=$(cat "$G/os_desc/use" 2>/dev/null) compat=$(cat "$G/functions/rndis.usb0/os_desc/interface.rndis/compatible_id" 2>/dev/null)"
	log "  串口设备  : $(ls /dev/ttyGS* 2>/dev/null | tr '\n' ' ')"
	log "  网卡      : usb0 [$(ip addr show usb0 2>/dev/null | grep -o 'inet [0-9./]*' | tr '\n' ' ')] wlan0 [$(ip addr show wlan0 2>/dev/null | grep -o 'inet [0-9./]*' | tr '\n' ' ')]"
	log "  sshd      : $(command -v sshd 2>/dev/null || echo '(无)')"
	;;
*)
	echo "用法: $0 up [ncm|rndis|acm] | check [ncm|rndis] | switch <mode> [秒] | keep | guard [mode] | down | status"
	;;
esac
