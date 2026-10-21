#!/bin/sh
# mi9-usb-role.sh —— 决定 dwc3 该当 host 还是 device，并写进 role switch
#
# ★ 为什么不直接用 Type-C（tcpm）的 data_role：
#   本机 tcpm 的 CC 判断有偏差 —— 插电脑（DFP）会被读成 not_dfp，
#   于是它认为该当 host，dwc3 就不会以设备身份挂上总线，
#   usb0 起不来、USB 网卡断掉（2026-10-21 实测）。
#
# 改用更可靠的判据（都来自 PMIC，和 CC 无关）：
#   1) 我们自己在对 Type-C 口供 5V（usb_vbus 有使用者 = 在给外设供电）→ host
#   2) 外部有 VBUS 进来（pm8150b-charger online=1 = 在从电脑取电）    → device
#   3) 什么都没插                                                      → device
#      （保持 device，这样 USB 网卡随时可用）
#
# 实测：
#   插 USB-C 扩展坞 + 键盘 → vbus_users=1 charger_online=0 → host，键盘可用
#   插电脑                  → vbus_users=0 charger_online=1 → device，usb0 恢复
set -u

RS=/sys/class/usb_role/a600000.usb-role-switch/role
CHG=/sys/class/power_supply/pm8150b-charger/online

log() { logger -t mi9-usb-role "$*"; }

vbus_users() {
	ls -d /sys/class/regulator/regulator.* 2>/dev/null | while read -r r; do
		[ "$(cat "$r/name" 2>/dev/null)" = "usb_vbus" ] && {
			cat "$r/num_users" 2>/dev/null
			break
		}
	done
}

# role switch 是 dwc3 probe 时才建的，比 typec 晚
i=0
while [ ! -e "$RS" ] && [ $i -lt 120 ]; do
	sleep 0.5
	i=$((i + 1))
done
[ -e "$RS" ] || { log "role switch 不存在（dwc3 未开 allow_userspace_control？），退出"; exit 0; }

log "启动（判据：usb_vbus 使用者 / 充电器 online）"

last=""
while :; do
	vu=$(vbus_users)
	vu=${vu:-0}
	co=$(cat "$CHG" 2>/dev/null || echo 0)

	if [ "$vu" -gt 0 ]; then
		want=host
	else
		# 外部供电 或 什么都没插 → 都当设备
		want=device
	fi

	if [ "$want" != "$last" ]; then
		now=$(cat "$RS" 2>/dev/null)
		if [ "$now" != "$want" ]; then
			if echo "$want" > "$RS" 2>/dev/null; then
				log "切换 -> $want (vbus_users=$vu charger_online=$co)"
			else
				log "写 $RS 失败"
			fi
		fi
		last="$want"
	fi
	sleep 1
done
