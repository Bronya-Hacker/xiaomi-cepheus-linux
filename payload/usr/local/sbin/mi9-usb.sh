#!/bin/sh
# mi9-usb —— USB / OTG / Type-C 状态速查
#
#   mi9-usb         看状态
#   mi9-usb host    尝试切到 host（需要 role switch 可用）
#   mi9-usb device  切回 device（USB 网卡/ADB）
#
# 背景与排障记录见 docs/usb.md。

set -u

show_status() {
	echo "=== USB 控制器 ==="
	echo "dwc3 设备: $(ls -d /sys/bus/platform/devices/*.usb 2>/dev/null | tr '\n' ' ')"
	if [ -d /sys/class/udc/a600000.usb ]; then
		echo "gadget 状态: $(cat /sys/class/udc/a600000.usb/state 2>/dev/null)"
		echo "gadget 地址: $(cat /sys/class/udc/a600000.usb/current_speed 2>/dev/null)"
	fi

	echo
	echo "=== usb_role_switch ==="
	if [ -d /sys/class/usb_role ]; then
		for d in /sys/class/usb_role/*/; do
			[ -d "$d" ] || continue
			n=$(basename "$d")
			if [ -e "$d/role" ]; then
				echo "  $n: role=$(cat "$d/role" 2>/dev/null)"
			else
				echo "  $n: (没有 role 属性 —— tcpm 尚未接管切换)"
			fi
		done
	else
		echo "  没有 usb_role class"
	fi

	echo
	echo "=== Type-C ==="
	if [ -d /sys/class/typec ]; then
		for p in /sys/class/typec/port*; do
			[ -d "$p" ] || continue
			case "$(basename "$p")" in *-*) continue;; esac
			b=$(basename "$p")
			echo "  $b: type=$(cat $p/port_type 2>/dev/null)"
			echo "      power_role=$(cat $p/power_role 2>/dev/null)  data_role=$(cat $p/data_role 2>/dev/null)"
			echo "      orientation=$(cat $p/orientation 2>/dev/null)  preferred=$(cat $p/preferred_role 2>/dev/null)"
		done
		for pt in /sys/class/typec/port*-partner; do
			[ -d "$pt" ] && echo "  对端类型: $(cat $pt/type 2>/dev/null)"
		done
	else
		echo "  没有 typec class（pmic-typec 未 probe 成功）"
	fi

	echo
	echo "=== USB 总线（host 模式下才有内容）==="
	if [ -d /sys/bus/usb/devices ]; then
		n=$(ls /sys/bus/usb/devices/ 2>/dev/null | wc -l)
		echo "  设备数: $n"
		ls /sys/bus/usb/devices/ 2>/dev/null | head -n 8 | while read -r d; do
			echo "    $d  $(cat /sys/bus/usb/devices/$d/product 2>/dev/null)"
		done
	else
		echo "  没有 USB 总线"
	fi
}

set_role() {
	want="$1"
	found=0
	for d in /sys/class/usb_role/*/; do
		[ -e "$d/role" ] || continue
		echo "$want" > "$d/role" 2>/dev/null && {
			echo "已把 $(basename "$d") 切到 $want"
			found=1
		}
	done
	[ "$found" = 1 ] || {
		echo "没有可写的 role 属性 —— 当前切不了。" >&2
		echo "（原因见 docs/usb.md：tcpm 还没和 dwc3 的 role switch 关联上）" >&2
		return 1
	}
}

case "${1:-status}" in
	status|"") show_status ;;
	host)     set_role host ;;
	device)   set_role device ;;
	*)        echo "用法: mi9-usb [status|host|device]" >&2; exit 1 ;;
esac
