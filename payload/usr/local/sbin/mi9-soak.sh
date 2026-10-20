#!/bin/sh
# ---------------------------------------------------------------------------
# mi9-soak.sh —— 长稳监控：每小时往 /var/log/mi9-soak.csv 追加一行
#
# 目的：把"跑了 30 天没出事"这种口头结论变成可查的数据。只读 /proc /sys
# 和 power_supply，不装任何额外软件、不发网络请求。
#
# 列：ts, uptime_s, load1, mem_used_pct, temp_c, cpu_mhz, wlan_dbm,
#     wlan_tx_fail, disk_used_pct, batt_pct, batt_temp_c, dmesg_err_delta
#
# 重启会被看出来：uptime_s 变小就是重启过（脚本不做判断，分析脚本做）。
# ---------------------------------------------------------------------------
set -u

LOG=/var/log/mi9-soak.csv
STATE=/run/mi9-soak.dmesg
HDR="ts,uptime_s,load1,mem_used_pct,temp_c,cpu_mhz,wlan_dbm,wlan_tx_fail,disk_used_pct,batt_pct,batt_temp_c,dmesg_err_delta"

[ -f "$LOG" ] || echo "$HDR" > "$LOG"

now=$(date +%s)
# 时钟合理性：RTC 还没被 NTP 校正时可能写出离谱的时间戳（2026-10-20 的 CSV
# 里就出现过 2084 年的记录，会让分析脚本误判）。超出 2023..2033 就跳过本次。
if [ "$now" -lt 1700000000 ] || [ "$now" -gt 2000000000 ]; then
	logger -t mi9-soak "clock not trustworthy (ts=$now), skipping this sample" 2>/dev/null || true
	exit 0
fi
up=$(cut -d. -f1 /proc/uptime)
load1=$(cut -d' ' -f1 /proc/loadavg)

mem_used=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{if(t>0) printf "%d", (t-a)*100/t; else print 0}' /proc/meminfo)

temp=""
for z in /sys/class/thermal/thermal_zone*/temp; do
	[ -r "$z" ] || continue
	v=$(cat "$z" 2>/dev/null) || continue
	case "$v" in ''|*[!0-9-]*) continue ;; esac
	[ "$v" -gt 1000 ] && v=$(( v / 1000 ))
	if [ -z "$temp" ] || [ "$v" -gt "$temp" ]; then temp=$v; fi
done

mhz=""
for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
	[ -r "$c" ] || continue
	v=$(cat "$c" 2>/dev/null) || continue
	case "$v" in ''|*[!0-9]*) continue ;; esac
	v=$(( v / 1000 ))
	if [ -z "$mhz" ] || [ "$v" -gt "$mhz" ]; then mhz=$v; fi
done

# WiFi：信号强度（iw，没有就留空）/ 发送错误计数（sysfs）
# 注意：这版内核没有 /proc/net/wireless（CFG80211_DEBUGFS 没开），只能问 iw。
dbm=""; txerr=""
if [ -r /sys/class/net/wlan0/statistics/tx_errors ]; then
	txerr=$(cat /sys/class/net/wlan0/statistics/tx_errors 2>/dev/null)
fi
if command -v iw >/dev/null 2>&1; then
	dbm=$(iw dev wlan0 link 2>/dev/null | sed -n 's/.*signal: \(-\{0,1\}[0-9][0-9]*\) dBm.*/\1/p' | head -n 1)
fi

disk=$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')

batt=""; btemp=""
for b in /sys/class/power_supply/*battery*; do
	[ -d "$b" ] || continue
	batt=$(cat "$b/capacity" 2>/dev/null)
	bt=$(cat "$b/temp" 2>/dev/null)
	case "$bt" in ''|*[!0-9-]*) ;; *) btemp=$(( bt / 10 )) ;; esac
	break
done

# dmesg 里"错误级"的新增条数（增量，不是总数）
errs=$(dmesg 2>/dev/null | grep -c -E 'error|Error|failed|Failed|timeout|Timeout' || true)
prev=$(cat "$STATE" 2>/dev/null || echo "$errs")
delta=$(( errs - prev ))
[ "$delta" -lt 0 ] && delta=0
echo "$errs" > "$STATE" 2>/dev/null

echo "$now,$up,$load1,$mem_used,${temp:-},${mhz:-},${dbm:-},${txerr:-},${disk:-},${batt:-},${btemp:-},$delta" >> "$LOG"

# 防止无限增长：超过 20000 行就只留最后 10000 行（约 2 年）
if [ "$(wc -l < "$LOG")" -gt 20000 ]; then
	tail -n 10000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
