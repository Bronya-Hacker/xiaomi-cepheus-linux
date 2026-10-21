#!/bin/sh
# mi9-usb-role.sh —— 决定 dwc3 该当 host 还是 device，并写进 role switch
#
# ★ 为什么不直接用 Type-C（tcpm）的 data_role：
#   本机 tcpm 的 CC 判断有偏差 —— 插电脑（DFP）会被读成 not_dfp，
#   于是它认为该当 host，dwc3 就不以设备身份挂总线，usb0 起不来。
#
# ★★ 为什么要消抖 + 优先当设备（2026-10-21 踩到卡死）：
#   如果用带充电口的扩展坞，插上电脑后会出现「我们在对外供 5V」和
#   「外部也在供 VBUS」两个条件同时成立的情况。若判据在这两者之间来回跳，
#   就会不停写 role，dwc3 反复切 host/device → 整机卡死（sshd 连 banner
#   都发不出来）。
#   所以：
#     1) **外部供电优先判为 device**（充电优先，保住 USB 网卡）；
#     2) 必须连续 3 次采样一致才真正切换（约 3 秒消抖）；
#     3) 两次切换之间至少间隔 5 秒。
set -u

RS=/sys/class/usb_role/a600000.usb-role-switch/role
CHG=/sys/class/power_supply/pm8150b-charger/online
STABLE_NEED=3     # 连续一致次数
MIN_GAP=5         # 两次切换最小间隔（秒）

log() { logger -t mi9-usb-role "$*"; }

vbus_users() {
	ls -d /sys/class/regulator/regulator.* 2>/dev/null | while read -r r; do
		[ "$(cat "$r/name" 2>/dev/null)" = "usb_vbus" ] && {
			cat "$r/num_users" 2>/dev/null
			break
		}
	done
}

decide() {
	vu=$(vbus_users)
	vu=${vu:-0}
	co=$(cat "$CHG" 2>/dev/null || echo 0)

	# 外部供电优先 → 当设备（充电 / USB 网卡）
	if [ "$co" = "1" ]; then
		echo device
	elif [ "$vu" -gt 0 ]; then
		echo host
	else
		echo device
	fi
}

# role switch 由 dwc3 probe 时创建，比 typec 晚
i=0
while [ ! -e "$RS" ] && [ $i -lt 120 ]; do
	sleep 0.5
	i=$((i + 1))
done
[ -e "$RS" ] || { log "role switch 不存在，退出"; exit 0; }

log "启动（判据：charger-online 优先 device，其次 usb_vbus 有使用者→host；3 次消抖）"

cand=""
cnt=0
last_switch=0

while :; do
	d=$(decide)

	if [ "$d" = "$cand" ]; then
		cnt=$((cnt + 1))
	else
		cand="$d"
		cnt=1
	fi

	if [ "$cnt" -ge "$STABLE_NEED" ]; then
		now=$(cat "$RS" 2>/dev/null)
		if [ "$now" != "$d" ]; then
			ts=$(date +%s)
			if [ $((ts - last_switch)) -ge "$MIN_GAP" ]; then
				if echo "$d" > "$RS" 2>/dev/null; then
					last_switch=$ts
					cnt=0
					log "切换 -> $d（连续 $STABLE_NEED 次一致）"
				fi
			fi
		else
			cnt=0
		fi
	fi

	sleep 1
done
