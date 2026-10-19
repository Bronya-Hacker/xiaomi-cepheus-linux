#!/bin/sh
# ---------------------------------------------------------------------------
# mi9-screen.sh —— 屏幕省电开关（服务器模式）
#
# 这块屏是 AMOLED：显示纯黑时像素基本不耗电。但这台机器的 fb0 是 simplefb
# （UEFI 交接过来的），**没有实现 fb_blank**：
#     echo 4 > /sys/class/graphics/fb0/blank   -> EINVAL
# 而 /sys/module/kernel/parameters/consoleblank 是只读的（0444），cmdline 里
# 又是 consoleblank=0，所以内核那套 VT blanking 也用不上。
#
# 因此这里用最直接、可验证的办法：
#   1) 停掉往 tty1 画仪表盘的 mi9-dashboard.service
#      （不停的话它每 5 秒把画面刷回来）
#   2) 把 tty1 切到 KD_GRAPHICS —— fbcon 从此不再渲染任何字符
#      （不切的话，systemd/内核往 /dev/console 写一行，fbcon 就会把
#        旧启动日志重新画到屏幕中间；console_loglevel 只能挡 printk）
#   3) 关掉 fbcon 光标闪烁（否则黑屏上会定时冒出一个白方块）
#   4) 把 console_loglevel 压到 1，减少内核日志
#   5) 直接往 /dev/fb0 写 0（整屏纯黑）
# 唤醒是反操作：恢复 loglevel + 重启仪表盘（它会立刻重画）。
#
# 用法: mi9-screen.sh off|on|toggle|status
# ---------------------------------------------------------------------------
set -u

STATE=/run/mi9-screen.state
LVL=/run/mi9-screen.loglevel
FB=/dev/fb0
CONS=/sys/class/graphics/fbcon/cursor_blink
DASH=mi9-dashboard.service

fb_bytes() {
	# virtual_size = "1080,2340"，bits_per_pixel = 32 -> 10,108,800 字节
	set -- $(tr ',' ' ' < /sys/class/graphics/fb0/virtual_size 2>/dev/null)
	w=${1:-1080}
	h=${2:-2340}
	bpp=$(cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null || echo 32)
	echo $(( w * h * bpp / 8 ))
}

vt_kd() {
	# 1 = KD_GRAPHICS, 0 = KD_TEXT（linux/kd.h: KDSETMODE 0x4B3A）
	# ★ 熄屏必须切到图形模式：fbcon 在 KD_TEXT 下会继续把 /dev/console 的
	#   输出（systemd 的 "Started ..."、内核日志）画到 tty1 上 —— 实测熄屏
	#   40 秒后屏幕中间又冒出 12 行启动日志（console_loglevel 只能挡 printk，
	#   挡不住 userspace 往 /dev/console 写）。X server 也是用这招接管 VT 的。
	python3 - "$1" <<'PY' 2>/dev/null || true
import fcntl, os, sys
fd = os.open("/dev/tty1", os.O_RDWR | os.O_NOCTTY)
try:
    fcntl.ioctl(fd, 0x4B3A, int(sys.argv[1]))
finally:
    os.close(fd)
PY
}

do_off() {
	# 先停绘制再抹屏 —— 顺序反了会被仪表盘下一轮刷回来
	systemctl stop "$DASH" >/dev/null 2>&1 || true
	vt_kd 1
	echo 0 > "$CONS" 2>/dev/null || true
	cut -d' ' -f1 /proc/sys/kernel/printk > "$LVL" 2>/dev/null || echo 4 > "$LVL"
	echo 1 > /proc/sys/kernel/printk 2>/dev/null || true
	n=$(fb_bytes)
	# 一次写完（fb_write 接受任意长度）；失败再按 4 KiB 分块重试
	dd if=/dev/zero of="$FB" bs="$n" count=1 conv=notrunc >/dev/null 2>&1 || \
		dd if=/dev/zero of="$FB" bs=4096 count=$(( n / 4096 )) conv=notrunc >/dev/null 2>&1 || true
	echo off > "$STATE"
	# 屏黑了以后 ssh / 串口照常可用：这是服务器，屏幕只是"看"的
	logger -t mi9-screen "screen off (fb ${n} bytes)" 2>/dev/null || true
}

do_on() {
	lvl=$(cat "$LVL" 2>/dev/null || echo 4)
	[ -n "$lvl" ] || lvl=4
	echo "$lvl" > /proc/sys/kernel/printk 2>/dev/null || true
	vt_kd 0
	# 清掉 VT 缓冲，避免 KD_TEXT 的瞬间把旧日志闪一下；仪表盘随后会重画
	printf '\033[2J\033[H' > /dev/tty1 2>/dev/null || true
	systemctl start "$DASH" >/dev/null 2>&1 || true
	echo 0 > "$CONS" 2>/dev/null || true
	echo on > "$STATE"
	logger -t mi9-screen "screen on" 2>/dev/null || true
}

case "${1:-status}" in
	off)    do_off ;;
	on)     do_on ;;
	toggle) if [ "$(cat "$STATE" 2>/dev/null || echo on)" = off ]; then do_on; else do_off; fi ;;
	status) cat "$STATE" 2>/dev/null || echo on ;;
	*) echo "用法: $0 off|on|toggle|status" >&2; exit 2 ;;
esac
