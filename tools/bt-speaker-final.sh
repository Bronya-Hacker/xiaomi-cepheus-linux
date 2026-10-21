#!/bin/sh
# mi9-bt-speaker —— 把系统音频输出接到蓝牙音箱（小爱音箱），并保持连接
#
# 背景：这台机器的内部喇叭卡在 ADSP/DSP 层，能出数据但没有声音。
# 蓝牙这条路完全绕开 ADSP：应用 -> PipeWire -> bluez5(A2DP) -> UART -> QCA 芯片 -> 音箱。
#
# 关键点（踩过的坑，全记在 docs/bluetooth.md）：
#   1. root 没有登录会话：既没有 XDG_RUNTIME_DIR 也没有会话 D-Bus，
#      PipeWire/WirePlumber 都起不来（"Cannot autolaunch D-Bus without X11 $DISPLAY"）。
#      → 自己造 /run/user/0 和一条 unix:path=.../bus 的会话总线。
#   2. 光有 bluez5 库不够，要装 libspa-0.2-bluetooth 才有 A2DP 端点
#      （否则连接报 br-connection-profile-unavailable）。
#   3. WirePlumber 默认空闲 5 秒挂起节点，A2DP transport 一挂起音箱就断开。
#      → /etc/wireplumber/bluetooth.lua.d/51-no-suspend-bluez.lua 里设
#        session.suspend-timeout-seconds = 0。
#   4. 同时跑两个 wireplumber 会让蓝牙 profile 注册失败：
#        sco_listen: listen(): Address already in use
#        register_profile_reply: RegisterProfile() failed: org.bluez.Error.NotPermitted
#      结果永远生成不出 A2DP sink。user@0 会话自带一套音频栈，所以这里
#      **优先复用会话里那套**，实在没有才自己起，且起之前把残留的全部清掉。
#   5. 拿 /dev/zero 当静音流保活行不通（sndfile 不认，进程立刻退出），
#      真要保活就循环播 /usr/share/mi9/silence-60s.wav（BT_KEEPALIVE=1）。
#
# 用法：
#   mi9-bt-speaker start   守护循环（systemd 用这个）
#   mi9-bt-speaker once    只连接一次并设为默认输出
#   mi9-bt-speaker status  看状态
#   mi9-bt-speaker stop    停止
#
# 配置（也可写进 /etc/mi9-bt-speaker.conf）：
#   BT_MAC=40:31:3C:81:D6:DA   音箱 MAC
#   BT_VOLUME=0.8              音量（1.0 = 100%）
#   BT_KEEPALIVE=0             额外静音流保活（默认关，靠 no-suspend 规则）

set -u

BT_MAC_DEFAULT="40:31:3C:81:D6:DA"	# 小爱音箱-3418
BT_VOLUME_DEFAULT="0.8"
BT_KEEPALIVE_DEFAULT="0"
RUNTIME_DIR=/run/user/0
KEEPALIVE_PID=/run/mi9-bt-keepalive.pid
DAEMON_PID=/run/mi9-bt-speaker.pid

[ -r /etc/mi9-bt-speaker.conf ] && . /etc/mi9-bt-speaker.conf
BT_MAC="${BT_MAC:-$BT_MAC_DEFAULT}"
BT_VOLUME="${BT_VOLUME:-$BT_VOLUME_DEFAULT}"
BT_KEEPALIVE="${BT_KEEPALIVE:-$BT_KEEPALIVE_DEFAULT}"

log() { logger -t mi9-bt-speaker "$*"; echo "$*"; }

# root 没有登录会话，得自己准备运行时目录 + 会话 D-Bus
setup_runtime() {
	mkdir -p "$RUNTIME_DIR"
	chmod 700 "$RUNTIME_DIR"
	export XDG_RUNTIME_DIR="$RUNTIME_DIR"

	if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
		if [ ! -S "$RUNTIME_DIR/bus" ]; then
			dbus-daemon --session --address="unix:path=$RUNTIME_DIR/bus" \
				--nofork --nopidfile >/dev/null 2>&1 &
			i=0
			while [ ! -S "$RUNTIME_DIR/bus" ] && [ $i -lt 20 ]; do
				sleep 0.2; i=$((i + 1))
			done
		fi
		[ -S "$RUNTIME_DIR/bus" ] && {
			DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus"
			export DBUS_SESSION_BUS_ADDRESS
		}
	fi
}

# 音频栈可用才算数（wpctl 连得上）
ensure_audio_stack() {
	if wpctl status >/dev/null 2>&1; then
		return 0
	fi

	# 1) 先让 root 的 user 会话把自带的音频栈拉起来（优先复用，避免两份并存）
	systemctl start user@0.service >/dev/null 2>&1
	i=0
	while [ $i -lt 12 ]; do
		sleep 1
		wpctl status >/dev/null 2>&1 && { log "已用 user@0 会话自带的音频栈"; return 0; }
		i=$((i + 1))
	done

	# 2) 会话那套没起来，才自己起一份：先把所有残留清干净，保证只剩一个 wireplumber
	log "会话音频栈不可用，自己起 pipewire / wireplumber"
	systemctl --user stop wireplumber pipewire pipewire.socket >/dev/null 2>&1
	pkill -x wireplumber 2>/dev/null
	sleep 1
	pgrep -x wireplumber >/dev/null 2>&1 || \
		nohup wireplumber >/var/log/mi9-wireplumber.log 2>&1 &
	sleep 3
	pgrep -x pipewire >/dev/null 2>&1 || \
		nohup pipewire >/var/log/mi9-pipewire.log 2>&1 &
	sleep 2
}

bt_connected() {
	bluetoothctl info "$BT_MAC" 2>/dev/null | grep -q "Connected: yes"
}

bt_paired() {
	bluetoothctl info "$BT_MAC" 2>/dev/null | grep -q "Paired: yes"
}

# 找蓝牙 sink：输出 "<id> <node.name>"
bt_sink_node() {
	wpctl status 2>/dev/null |
		sed -n '/Sinks:/,/Sources:/p' |
		grep -oE '[0-9]+\.' | tr -d '.' |
		while read -r id; do
			nm=$(wpctl inspect "$id" 2>/dev/null | grep 'node.name' | head -n1 |
			     sed 's/.*"\(.*\)".*/\1/')
			case "$nm" in
			*bluez_output*) echo "$id $nm"; return 0 ;;
			esac
		done
}

keepalive_running() {
	[ -f "$KEEPALIVE_PID" ] && kill -0 "$(cat "$KEEPALIVE_PID" 2>/dev/null)" 2>/dev/null
}

start_keepalive() {
	node=$1
	keepalive_running && return 0
	[ -f /usr/share/mi9/silence-60s.wav ] || {
		log "缺少 /usr/share/mi9/silence-60s.wav，跳过保活"
		return 1
	}
	setsid sh -c "export XDG_RUNTIME_DIR=$RUNTIME_DIR; while :; do pw-play --target '$node' /usr/share/mi9/silence-60s.wav || sleep 1; done" \
		>/var/log/mi9-bt-keepalive.log 2>&1 &
	echo $! > "$KEEPALIVE_PID"
	log "静音保活流已启动 (pid $(cat "$KEEPALIVE_PID"))"
}

stop_keepalive() {
	if keepalive_running; then
		kill -- -"$(cat "$KEEPALIVE_PID")" 2>/dev/null
		log "静音保活流已停止"
	fi
	rm -f "$KEEPALIVE_PID"
}

connect_once() {
	if ! bt_paired; then
		log "音箱 $BT_MAC 还没配对（先 bluetoothctl pair $BT_MAC 配一次）"
		return 1
	fi
	bt_connected && return 0
	log "连接 $BT_MAC ..."
	bluetoothctl connect "$BT_MAC" >/dev/null 2>&1
	sleep 2
	bt_connected
}

apply_route() {
	info=$(bt_sink_node)
	[ -n "$info" ] || return 1
	id=${info%% *}
	node=${info##* }
	wpctl set-default "$id" 2>/dev/null
	wpctl set-volume "$id" "$BT_VOLUME" 2>/dev/null
	[ "$BT_KEEPALIVE" = "1" ] && start_keepalive "$node"
	return 0
}

do_once() {
	setup_runtime
	ensure_audio_stack
	connect_once || return 1
	sleep 1
	apply_route || { log "找不到蓝牙 sink"; return 1; }
	log "已切换到蓝牙音箱输出"
	return 0
}

do_daemon() {
	setup_runtime
	echo $$ > "$DAEMON_PID"
	log "守护启动，目标音箱 $BT_MAC"
	while :; do
		ensure_audio_stack
		if bt_connected; then
			apply_route || true
		else
			stop_keepalive
			connect_once || true
			sleep 1
			apply_route || true
		fi
		sleep 5
	done
}

do_status() {
	setup_runtime
	printf '音箱 MAC   : %s\n' "$BT_MAC"
	printf '已配对     : %s\n' "$(bt_paired && echo 是 || echo 否)"
	printf '已连接     : %s\n' "$(bt_connected && echo 是 || echo 否)"
	printf '音频栈     : %s\n' "$(wpctl status >/dev/null 2>&1 && echo 正常 || echo 未运行)"
	printf 'wireplumber: %s 个进程\n' "$(pgrep -c -x wireplumber 2>/dev/null || echo 0)"
	printf '保活流     : %s\n' "$(keepalive_running && echo 运行中 || echo '未启用/未运行')"
	printf '守护进程   : %s\n' "$([ -f "$DAEMON_PID" ] && kill -0 "$(cat "$DAEMON_PID" 2>/dev/null)" 2>/dev/null && echo 运行中 || echo 未运行)"
	echo "--- 当前输出设备 ---"
	wpctl status 2>/dev/null | sed -n '/Sinks:/,/Sources:/p' | head -n 6
}

case "${1:-status}" in
start|daemon) do_daemon ;;
once) do_once ;;
status) do_status ;;
stop)
	[ -f "$DAEMON_PID" ] && kill "$(cat "$DAEMON_PID")" 2>/dev/null && rm -f "$DAEMON_PID"
	stop_keepalive
	log "已停止"
	;;
*)
	echo "用法: mi9-bt-speaker [start|once|status|stop]"
	exit 1
	;;
esac
