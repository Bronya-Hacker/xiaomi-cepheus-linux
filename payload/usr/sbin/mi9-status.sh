#!/bin/sh
# ---------------------------------------------------------------------------
# mi9-status.sh —— 小米9（cepheus / SM8150）主线 Linux：一页纸状态
#
# 谁在用：
#   * mi9-dashboard.service  → 每 5 秒把本脚本输出画到手机屏幕（tty1）
#   * mi9-doctor.sh          → 取其几行做健康记录
#   * 人工：SSH / 串口里直接敲 `mi9-status`
#
# ★ 输出必须是**纯 ASCII**：手机屏幕是 fbcon + TER16x32（ASCII 字库），
#   中文一律显示成豆腐块；英文在 SSH/串口里也不会有编码麻烦。
#   所以本文件里除了注释**不要**写中文，也不要用 printf 的中文格式。
#
# 排版：手机屏 1080px 宽 / 16px 字宽 = 67 列 —— 所有行都控制在 66 列内，
#       否则会折行，仪表盘立刻变得没法读。
#
# 设计：所有取值都做保护（缺文件/缺工具都给 "?" 而不是报错），因为这个脚本
#       会被 systemd 每 5 秒跑一次，绝不能因为某个 sysfs 文件不存在就刷错误。
# ---------------------------------------------------------------------------
set -u

W=66
r()   { [ -r "$1" ] && cat "$1" 2>/dev/null || echo "?"; }
mhz() { case "${1:-}" in ''|'?') echo "?" ;; *) echo "$(( $1 / 1000 ))MHz" ;; esac; }
c2f() { case "${1:-}" in ''|'?') echo "?" ;; *) echo "$(( $1 / 1000 )).$(( ($1 % 1000) / 100 ))C" ;; esac; }
sec2h() {
	_s="${1:-0}"; _d=$(( _s / 86400 )); _h=$(( (_s % 86400) / 3600 )); _m=$(( (_s % 3600) / 60 ))
	if   [ "$_d" -gt 0 ]; then echo "${_d}d ${_h}h"
	elif [ "$_h" -gt 0 ]; then echo "${_h}h ${_m}m"
	else echo "${_m}m"; fi
}
du_m() { [ -d "$1" ] || { echo 0; return; }; _k=$(du -sk "$1" 2>/dev/null | awk '{print $1}'); echo $(( ${_k:-0} / 1024 )); }
line() { printf '%*s\n' "$W" '' | tr ' ' '-'; }
# systemctl is-active / is-enabled 对 inactive / disabled 会返回非零，
# 旧写法 "|| echo ?" 会把 "?" 追加成第二行，把屏幕格式彻底打乱。
# 统一走这里：只取 stdout，空则给 unknown。
scq() { _o=$("$@" 2>/dev/null); printf '%s' "${_o:-unknown}"; }

echo
echo "=========================== MI 9 LINUX ==========================="
printf 'host %-24s kernel %s\n' "$(hostname 2>/dev/null || echo '?')" "$(uname -r 2>/dev/null)"
printf 'time %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$(date '+%Z%z' 2>/dev/null)"
printf 'up   %-24s load %s\n' "$(sec2h "$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)")" \
	"$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null | tr -s ' ')"
_rtc=$(cat /sys/class/rtc/rtc0/since_epoch 2>/dev/null || echo ?)
_now=$(date +%s 2>/dev/null || echo ?)
if [ "$_rtc" != "?" ] && [ "$_now" != "?" ]; then
	_d=$(( _now - _rtc )); [ "$_d" -lt 0 ] && _d=$(( 0 - _d ))
	if [ "$_d" -le 5 ]; then _rs="rtc ok (drift ${_d}s, UTC)"
	else _rs="rtc ** DRIFT ${_d}s ** check rtc-save"; fi
else _rs="rtc ? (no /sys/class/rtc/rtc0)"; fi
printf '%-34s watchdog %s\n' "$_rs" "$(systemctl show -p RuntimeWatchdogUSec --value 2>/dev/null || echo ?)"
line

echo "CPU -----------------------------------------------------------------"
printf 'cores %-3s part %s\n' "$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo ?)" \
	"$(awk -F': ' '/^CPU part/{print $2}' /proc/cpuinfo 2>/dev/null | uniq | tr '\n' ' ')"
_np=0
for p in /sys/devices/system/cpu/cpufreq/policy*; do
	[ -d "$p" ] || continue
	_np=$(( _np + 1 ))
	_cores=$(wc -w < "$p/related_cpus" 2>/dev/null || echo ?)
	_max=$(cat "$p/scaling_max_freq" 2>/dev/null)
	printf 'policy%-2s %2s cores  cur %-9s gov %-10s max %s\n' "${p##*policy}" "$_cores" \
		"$(mhz "$(cat "$p/scaling_cur_freq" 2>/dev/null)")" \
		"$(cat "$p/scaling_governor" 2>/dev/null)" "$(mhz "${_max:-}")"
done
[ "$_np" = 0 ] && echo "(no cpufreq -- kernel without qcom-cpufreq-hw?)"

_tmax=0; _tname="?"
for z in /sys/class/thermal/thermal_zone*; do
	[ -r "$z/temp" ] || continue
	_t=$(cat "$z/temp" 2>/dev/null || echo 0)
	if [ "$_t" -gt "$_tmax" ] 2>/dev/null; then _tmax=$_t; _tname=$(cat "$z/type" 2>/dev/null || echo ?); fi
done
printf 'temp max %-8s (%s)   critical trip 110.0C\n' "$(c2f "$_tmax")" "$_tname"
for n in cpu0-thermal cpu7-thermal cluster0-thermal gpu-top-thermal wlan-thermal pm8150-thermal; do
	for z in /sys/class/thermal/thermal_zone*; do
		[ "$(cat "$z/type" 2>/dev/null)" = "$n" ] || continue
		printf '  %-20s %s\n' "$n" "$(c2f "$(cat "$z/temp" 2>/dev/null)")"
		break
	done
done
line

echo "MEM -----------------------------------------------------------------"
awk '
/MemTotal/     {t=$2}
/MemAvailable/ {a=$2}
/SwapTotal/    {st=$2}
/SwapFree/     {sf=$2}
END {
	if (t > 0) printf "ram   %.1fG avail / %.1fG total\n", a/1048576, t/1048576;
	if (st > 0) printf "swap  %.1fG (%.2fG used)  %s\n", st/1048576, (st-sf)/1048576, "zram";
	else printf "swap  none\n";
}' /proc/meminfo 2>/dev/null
_sw=$(swapon --show=NAME,SIZE,USED --noheadings 2>/dev/null | tr -s ' ' | tr '\n' ' ')
[ -n "$_sw" ] && echo "swapdev: $_sw"
line

echo "DISK ----------------------------------------------------------------"
df -h / 2>/dev/null | awk 'NR==2{printf "root %-12s %s used / %s (%s)\n", $1, $3, $2, $5}'
printf 'journal %sMB in /var/log/journal   zram-swap unit %s\n' \
	"$(du_m /var/log/journal)" "$(scq systemctl is-active zram-swap.service)"
line

echo "NET -----------------------------------------------------------------"
if command -v iw >/dev/null 2>&1; then
	_iwl=$(iw dev wlan0 link 2>/dev/null)
	printf 'wlan0 %-14s %-15s %s\n' \
		"$(echo "$_iwl" | awk -F': ' '/SSID/{print $2}')" \
		"$(ip -o -4 addr show wlan0 2>/dev/null | awk '{print $4}')" \
		"$(echo "$_iwl" | awk -F': ' '/signal/{print $2}') $(echo "$_iwl" | awk -F': ' '/bitrate/{print $2}')"
fi
printf 'usb0  %s udc %s\n' "$(ip -o -4 addr show usb0 2>/dev/null | awk '{printf "%s ", $4}')" \
	"$(scq sh -c 'cat /sys/class/udc/*/state')"
# 蓝牙：hciconfig 只要 2ms；没有 bluez 就退回看 sysfs 节点在不在
if command -v hciconfig >/dev/null 2>&1; then
	_bt=$(hciconfig hci0 2>/dev/null)
	if [ -n "${_bt:-}" ]; then
		printf 'bt    hci0 %-17s %s\n' \
			"$(echo "$_bt" | awk 'NR==2{print $3}')" \
			"$(echo "$_bt" | awk 'NR==3{print $1, $2}')"
	else
		printf 'bt    hci0 absent\n'
	fi
else
	printf 'bt    hci0 %s (bluez not installed)\n' \
		"$([ -d /sys/class/bluetooth/hci0 ] && echo present || echo absent)"
fi
printf 'ssh sessions %s   ports %s\n' "$(who 2>/dev/null | wc -l)" \
	"$(ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | sed 's/.*://' | sort -u | tr '\n' ' ')"
line

echo "SERVICES / HEALTH ---------------------------------------------------"
printf 'failed units %s   temp %sC   disk %s%%   load %s\n' \
	"$(systemctl --failed --no-legend 2>/dev/null | wc -l)" \
	"$(( _tmax / 1000 ))" "$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')" \
	"$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)"
for u in ssh NetworkManager wpa_supplicant tqftpserv rmtfs mi9-doctor.timer mi9-dashboard; do
	printf '  %-20s %s\n' "$u" "$(scq systemctl is-active "$u")"
done
printf 'phoneui(GUI) %s   getty@tty1 %s   phoneui files kept in /root/phoneui\n' \
	"$(scq systemctl is-enabled phoneui)" "$(scq systemctl is-enabled getty@tty1)"
_top=$(ps -eo pcpu,comm --sort=-pcpu 2>/dev/null | awk 'NR>1 && $2 !~ /^(ps|awk|sed|grep|sh|bash|mi9-status.sh)$/ && NR<6{printf "%s%%%s ", $1, $2}')
[ -n "${_top:-}" ] && echo "top cpu: $_top"
line

echo "RECENT ERR ----------------------------------------------------------"
if command -v dmesg >/dev/null 2>&1; then
	_dm=$(dmesg --level=err 2>/dev/null | tail -3)
	[ -n "${_dm:-}" ] && printf '%s\n' "$_dm" || echo "(none)"
else echo "(dmesg unavailable)"; fi
echo "serial /dev/ttyGS0 115200 8N1    ssh root@169.254.42.1 (usb) / 192.168.31.x"
echo "help: mi9-status | mi9-doctor [--fix] | systemctl --failed | journalctl -b -p err"
echo "====================================================================="
