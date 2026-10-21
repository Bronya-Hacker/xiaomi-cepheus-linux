#!/bin/sh
# mi9-bt-speaker —— 蓝牙音箱音频桥（自动连接 + 断线自愈 + 音频栈守护）
#
# 背景：这台手机的内部喇叭/麦克风卡在 ADSP 固件层，出不了声。
# 蓝牙这条路完全绕开 ADSP：
#     应用 -> PipeWire -> bluez5(A2DP) -> hci_uart -> QCA wcn3990 -> 音箱
#
# 设计取舍（哪些是主流、哪些是不得已，写清楚便于以后替换）：
#   ✅ 主流：单实例 PipeWire/WirePlumber/pipewire-pulse；BlueZ 信任设备；
#            WirePlumber 里禁用蓝牙节点空闲挂起、开启 bluez5.auto-connect；
#            BlueZ [Policy] 打开 ReconnectUUIDs 让链路超时后自动恢复。
#   ⚠️ 不得已：root 无 logind 会话，必须自己造 XDG_RUNTIME_DIR 和会话 D-Bus。
#   ⚠️ 不得已：BlueZ 的 ReconnectUUIDs 只处理"链路超时"，对"音箱自己关机再开"
#            这类情况不会重连，所以需要一个监督者在需要时发起 Device1.Connect。
#            这里用事件驱动（监听 BlueZ 信号）+ 30 秒慢兜底，而不是盲轮询。
#   ⚠️ 保活流：本音箱空闲一段时间会自己断，因此常驻一路静音 WAV。
#
# 用法：
#   mi9-bt-speaker start    守护（systemd 用这个）
#   mi9-bt-speaker once     连一次并设为默认输出
#   mi9-bt-speaker status   状态
#   mi9-bt-speaker stop     停止
#   mi9-bt-speaker test     放一段测试音（有 /usr/share/mi9/tone.wav 就放它）
#   mi9-bt-speaker volume N 设音量 0.0~1.0
#
# 配置 /etc/mi9-bt-speaker.conf：
#   BT_MAC=40:31:3C:81:D6:DA
#   BT_VOLUME=0.9
#   BT_KEEPALIVE=1

set -u

BT_MAC_DEFAULT="40:31:3C:81:D6:DA"	# 小爱音箱-3418
BT_VOLUME_DEFAULT="0.9"
BT_KEEPALIVE_DEFAULT="1"
FALLBACK_POLL=30			# 慢兜底间隔（秒）
RUNTIME_DIR=/run/user/0
KEEPALIVE_PID=/run/mi9-bt-keepalive.pid
DAEMON_PID=/run/mi9-bt-speaker.pid
SILENCE=/usr/share/mi9/silence-60s.wav

[ -r /etc/mi9-bt-speaker.conf ] && . /etc/mi9-bt-speaker.conf
BT_MAC="${BT_MAC:-$BT_MAC_DEFAULT}"
BT_VOLUME="${BT_VOLUME:-$BT_VOLUME_DEFAULT}"
BT_KEEPALIVE="${BT_KEEPALIVE:-$BT_KEEPALIVE_DEFAULT}"

log() { logger -t mi9-bt-speaker "$*"; echo "$*"; }

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

# 等蓝牙适配器就绪（开机时 bluetoothd 可能还没起来）
wait_adapter() {
	i=0
	while [ $i -lt 30 ]; do
		bluetoothctl list 2>/dev/null | grep -q 'Controller' && return 0
		sleep 1; i=$((i + 1))
	done
	return 1
}

# 音频栈健康判据：连得上 + wireplumber 恰好一份 + pulse 兼容层在
# （两个 wireplumber 会抢注册 A2DP profile，导致一连就断）
stack_healthy() {
	wpctl status >/dev/null 2>&1 || return 1
	[ "$(pgrep -xc wireplumber 2>/dev/null || echo 0)" = "1" ] || return 1
	[ "$(pgrep -xc pipewire-pulse 2>/dev/null || echo 0)" -ge 1 ] || return 1
	return 0
}

ensure_audio_stack() {
	stack_healthy && return 0

	log "重建音频栈（pipewire=$(pgrep -xc pipewire 2>/dev/null || echo 0) wireplumber=$(pgrep -xc wireplumber 2>/dev/null || echo 0) pulse=$(pgrep -xc pipewire-pulse 2>/dev/null || echo 0)）"
	systemctl --user stop pipewire-pulse wireplumber pipewire pipewire.socket >/dev/null 2>&1
	pkill -x pipewire-pulse 2>/dev/null
	pkill -x wireplumber 2>/dev/null
	pkill -x pipewire 2>/dev/null
	sleep 2
	nohup pipewire       >/var/log/mi9-pipewire.log       2>&1 &
	sleep 2
	nohup pipewire-pulse >/var/log/mi9-pipewire-pulse.log 2>&1 &
	sleep 1
	nohup wireplumber    >/var/log/mi9-wireplumber.log    2>&1 &
	sleep 3
	stack_healthy
}

bt_connected() { bluetoothctl info "$BT_MAC" 2>/dev/null | grep -q "Connected: yes"; }
bt_paired()    { bluetoothctl info "$BT_MAC" 2>/dev/null | grep -q "Paired: yes"; }

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
	[ -f "$SILENCE" ] || { log "缺少 $SILENCE，跳过保活"; return 1; }
	setsid sh -c "export XDG_RUNTIME_DIR=$RUNTIME_DIR; while :; do pw-play --target '$node' '$SILENCE' || sleep 1; done" \
		>/var/log/mi9-bt-keepalive.log 2>&1 &
	echo $! > "$KEEPALIVE_PID"
	log "保活流已启动（pid $(cat "$KEEPALIVE_PID"))"
}

stop_keepalive() {
	keepalive_running && {
		kill -- -"$(cat "$KEEPALIVE_PID")" 2>/dev/null
		log "保活流已停止"
	}
	rm -f "$KEEPALIVE_PID"
}

connect_once() {
	bt_paired || { log "音箱 $BT_MAC 未配对（先 bluetoothctl pair $BT_MAC）"; return 1; }
	bt_connected && return 0
	log "连接 $BT_MAC ..."
	bluetoothctl connect "$BT_MAC" >/dev/null 2>&1
	sleep 3
	bt_connected
}

apply_route() {
	info=$(bt_sink_node)
	[ -n "$info" ] || return 1
	id=${info%% *}
	node=${info##* }
	cur=$(wpctl inspect "$id" 2>/dev/null | grep -c 'default')
	wpctl set-default "$id" >/dev/null 2>&1
	wpctl set-volume "$id" "$BT_VOLUME" >/dev/null 2>&1
	[ "$BT_KEEPALIVE" = "1" ] && start_keepalive "$node"
	return 0
}

# 完整一步：健康检查 -> 连接 -> 路由
step() {
	ensure_audio_stack || return 1
	connect_once || return 1
	sleep 1
	apply_route
}

do_once() {
	setup_runtime
	wait_adapter
	step && log "已切换到蓝牙音箱"
}

# 事件驱动：监听 BlueZ 的断开信号后立刻处理一次
watch_events() {
	busctl monitor --match "type='signal',interface='org.bluez.Device1'" org.bluez 2>/dev/null |
	while read -r line; do
		case "$line" in
		*Disconnected*|*Powered*|*Connected*)
			touch /run/mi9-bt-event
			;;
		esac
	done
}

do_daemon() {
	setup_runtime
	echo $$ > "$DAEMON_PID"
	log "守护启动：目标 $BT_MAC，兜底间隔 ${FALLBACK_POLL}s"

	wait_adapter || log "警告：蓝牙适配器未就绪，继续等待"

	[ -f /run/mi9-bt-event ] || : > /run/mi9-bt-event
	( while :; do watch_events; sleep 3; done ) >/dev/null 2>&1 &

	last=$(( $(date +%s) - FALLBACK_POLL ))
	while :; do
		now=$(date +%s)
		evt=0
		if [ /run/mi9-bt-event -nt /run/mi9-bt-event.seen ] 2>/dev/null; then
			touch /run/mi9-bt-event.seen
			evt=1
		fi
		if [ "$evt" = "1" ] || [ $((now - last)) -ge $FALLBACK_POLL ]; then
			last=$now
			bt_connected || stop_keepalive
			step || true
		fi
		sleep 2
	done
}

do_status() {
	setup_runtime
	printf '音箱 MAC    : %s\n' "$BT_MAC"
	printf '已配对      : %s\n' "$(bt_paired && echo 是 || echo 否)"
	printf '已连接      : %s\n' "$(bt_connected && echo 是 || echo 否)"
	printf '音频栈      : %s\n' "$(stack_healthy && echo 健康 || echo 异常)"
	printf '  进程      : pipewire=%s wireplumber=%s pulse=%s\n' \
		"$(pgrep -xc pipewire 2>/dev/null || echo 0)" \
		"$(pgrep -xc wireplumber 2>/dev/null || echo 0)" \
		"$(pgrep -xc pipewire-pulse 2>/dev/null || echo 0)"
	printf '保活流      : %s\n' "$(keepalive_running && echo 运行中 || echo 未运行)"
	printf '守护进程    : %s\n' "$([ -f "$DAEMON_PID" ] && kill -0 "$(cat "$DAEMON_PID" 2>/dev/null)" 2>/dev/null && echo 运行中 || echo 未运行)"
	echo '--- 输出设备 ---'
	wpctl status 2>/dev/null | sed -n '/Sinks:/,/Sources:/p' | head -n 6
}

do_test() {
	setup_runtime
	node=$(bt_sink_node)
	[ -n "$node" ] || { log "没有蓝牙 sink，先 once"; return 1; }
	node=${node##* }
	[ -f /usr/share/mi9/tone.wav ] && f=/usr/share/mi9/tone.wav || f="$SILENCE"
	log "播放 $f"
	pw-play --target "$node" "$f"
}

case "${1:-status}" in
start|daemon) do_daemon ;;
once) do_once ;;
status) do_status ;;
test) do_test ;;
volume) BT_VOLUME="${2:-0.9}"; setup_runtime; id=$(bt_sink_node); [ -n "$id" ] && wpctl set-volume ${id%% *} "$BT_VOLUME" && echo "音量设为 $BT_VOLUME" ;;
stop)
	[ -f "$DAEMON_PID" ] && kill "$(cat "$DAEMON_PID")" 2>/dev/null && rm -f "$DAEMON_PID"
	stop_keepalive
	log "已停止"
	;;
*) echo "用法: mi9-bt-speaker [start|once|status|test|volume N|stop]" ;;
esac
