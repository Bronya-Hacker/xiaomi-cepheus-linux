#!/bin/sh
# mi9-usb-role.sh —— 把 Type-C（tcpm）的判断同步给 dwc3 的 role switch
#
# 背景：主线里 tcpm 应该通过 device-tree graph 自动找到 dwc3 的 role switch，
# 但在这台机器上没接上（见 docs/usb.md）。结果 Type-C 层判断是对的
# （插 OTG 设备时 data_role=host），dwc3 却一直停在 device 模式。
#
# 这个脚本就是补那一环：轮询 /sys/class/typec/port0/data_role，
# 一旦和 dwc3 当前 role 不一致就写一次 /sys/class/usb_role/*/role。
#
# 前提：内核里给 dwc3 的 role switch 打开了 allow_userspace_control
#       （drivers/usb/dwc3/drd.c 的本地补丁），否则 role 文件不存在。

set -u

TC=/sys/class/typec/port0/data_role
RS=/sys/class/usb_role/a600000.usb-role-switch/role

# sysfs 里 data_role 的格式是 "host [device]" 或 "device [host]"，
# 第一段是当前值。
cur_tc_role() {
	[ -r "$TC" ] || return 1
	awk '{print $1}' "$TC" 2>/dev/null
}

log() { logger -t mi9-usb-role "$*"; }

# 等 role switch 出现（dwc3 probe 比 typec 晚）
i=0
while [ ! -e "$RS" ] && [ $i -lt 120 ]; do
	sleep 0.5
	i=$((i + 1))
done
[ -e "$RS" ] || { log "role switch 不存在，退出"; exit 0; }

log "启动，跟随 $TC 同步到 $RS"

last=""
while :; do
	want=$(cur_tc_role) || { sleep 2; continue; }
	case "$want" in
	host|device) ;;
	*) sleep 2; continue ;;
	esac

	if [ "$want" != "$last" ]; then
		now=$(cat "$RS" 2>/dev/null)
		if [ "$now" != "$want" ]; then
			if echo "$want" > "$RS" 2>/dev/null; then
				log "切换 -> $want（Type-C 判定 $want）"
			else
				log "写 $RS 失败"
			fi
		fi
		last="$want"
	fi
	sleep 1
done
