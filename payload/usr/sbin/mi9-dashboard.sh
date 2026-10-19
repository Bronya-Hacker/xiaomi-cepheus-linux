#!/bin/sh
# ---------------------------------------------------------------------------
# mi9-dashboard.sh —— 手机屏幕（tty1）上的**只读状态屏**
#
# 背景（2026-10-19 服务器化）：
#   用户放弃 GUI，但没有键盘触摸也打不了字 —— 屏幕唯一的价值就是"看"。
#   原来 tty1 是 getty 自动登录 root（一个谁也敲不了的 shell），现在把它换成
#   这个只读仪表盘：每 5 秒跑一次 mi9-status.sh，内容有变化才重画（不闪）。
#   交互请走串口 ttyGS0（115200 8N1）或 SSH —— 那两条路一直都在。
#
# 由 mi9-dashboard.service 拉起（TTYPath=/dev/tty1, StandardOutput=tty）。
# ---------------------------------------------------------------------------
set -u

TTY="${MI9_DASH_TTY:-/dev/tty1}"
S="${MI9_STATUS:-/usr/sbin/mi9-status.sh}"
INTERVAL="${MI9_DASH_INTERVAL:-5}"

prev=""
fails=0
while :; do
	cur=$("$S" 2>/dev/null)
	if [ -z "${cur:-}" ]; then
		fails=$(( fails + 1 ))
		[ "$fails" -ge 3 ] && {
			printf '\033[2J\033[Hmi9-status.sh produced no output (%s tries)\n' "$fails" > "$TTY" 2>/dev/null
		}
		sleep 15
		continue
	fi
	fails=0
	# 只在内容变化时重画：一是避免闪屏，二是别把屏幕刷得没法读
	if [ "$cur" != "$prev" ]; then
		{
			printf '\033[2J\033[H'      # 清屏 + 光标回左上
			printf '%s\n' "$cur"
		} > "$TTY" 2>/dev/null || { sleep 30; continue; }
		prev="$cur"
	fi
	sleep "$INTERVAL"
done
