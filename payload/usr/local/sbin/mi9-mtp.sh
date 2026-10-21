#!/bin/sh
# mi9-mtp —— 把通过 OTG 接上的安卓手机（MTP 模式）挂载成本地目录
#
#   mi9-mtp            看状态
#   mi9-mtp mount      挂载到 /mnt/mtp
#   mi9-mtp umount     卸载
#   mi9-mtp ls         挂载后列一下顶层
#
# 为什么需要它：
#   安卓手机"文件传输"模式说的是 **MTP**（USB interface class 6），
#   不是 U 盘（mass storage）。内核只负责枚举设备，真正读写文件要用户态的
#   MTP 客户端 —— 本机装的是 jmtpfs（apt install jmtpfs）。
#
# 前置条件：
#   1) Type-C 口要处于 **host** 模式（mi9-usb 看，mi9-usb host 手动切）
#   2) 对端手机要在"传输文件/MTP"模式下（不是仅充电）
set -u

MP=/mnt/mtp
log() { logger -t mi9-mtp "$*"; }

is_mounted() { grep -q " $MP " /proc/mounts 2>/dev/null; }

status() {
	echo "=== OTG 角色 ==="
	echo "  role = $(cat /sys/class/usb_role/a600000.usb-role-switch/role 2>/dev/null || echo '?')"

	echo
	echo "=== 接上的 USB 设备 ==="
	for d in /sys/bus/usb/devices/*; do
		[ -f "$d/idVendor" ] || continue
		n=$(basename "$d")
		case "$n" in usb*) continue ;; esac
		echo "  $n: $(cat "$d/idVendor"):$(cat "$d/idProduct")  $(cat "$d/product" 2>/dev/null)"
	done

	echo
	echo "=== 挂载状态 ==="
	if is_mounted; then
		echo "  已挂载在 $MP"
		df -h "$MP" 2>/dev/null | tail -n 1
		echo "  内容:"
		ls "$MP" 2>/dev/null | sed 's/^/    /'
	else
		echo "  未挂载（mi9-mtp mount）"
	fi
}

do_mount() {
	command -v jmtpfs >/dev/null || {
		echo "没装 jmtpfs：apt-get update && apt-get install -y jmtpfs" >&2
		exit 1
	}
	is_mounted && { echo "已经挂着了：$MP"; return 0; }

	role=$(cat /sys/class/usb_role/a600000.usb-role-switch/role 2>/dev/null)
	if [ "$role" != "host" ]; then
		echo "当前 USB 角色是 '$role'，需要 host。" >&2
		echo "先拔掉充电线，只插 OTG 设备；或手动： mi9-usb host" >&2
		exit 1
	fi

	mkdir -p "$MP"
	if jmtpfs -o allow_other "$MP" 2>/dev/null && is_mounted; then
		log "已挂载 $MP"
		echo "已挂载：$MP"
		ls "$MP" 2>/dev/null | sed 's/^/  /'
	else
		echo "挂载失败（对端手机是不是没选“传输文件/MTP”？）" >&2
		exit 1
	fi
}

do_umount() {
	is_mounted || { echo "本来就没挂载"; return 0; }
	umount "$MP" 2>/dev/null || fusermount -u "$MP" 2>/dev/null
	is_mounted && { echo "卸载失败（有文件在用？）" >&2; exit 1; }
	log "已卸载 $MP"
	echo "已卸载"
}

case "${1:-status}" in
	status|"") status ;;
	mount)     do_mount ;;
	umount|unmount) do_umount ;;
	ls)        is_mounted && ls "$MP" || echo "未挂载" ;;
	*)         echo "用法: mi9-mtp [status|mount|umount|ls]" >&2; exit 1 ;;
esac
