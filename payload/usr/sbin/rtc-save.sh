#!/bin/sh
# ---------------------------------------------------------------------------
# rtc-save.sh —— 把当前系统时间写进 PMIC RTC（/dev/rtc0，驱动 rtc-pm8xxx）
#
# 为什么需要它（docs/root-cause.md §10.13）：
#   内核自带的 RTC_SYSTOHC（每 11 分钟回写 RTC）**要求 userspace 通过
#   adjtimex() 上报"时间已同步"**（清掉 STA_UNSYNC，见 kernel/time/ntp.c 的
#   ntp_synced()）。systemd-timesyncd 只维护自己那套，不报这个状态 →
#   本机这条自动回写永远不触发，RTC 会一直停在它上次被写入的时刻。
#
#   这里用 hwclock 直接把系统时间写进去，完全不依赖内核那条路。
#
#   PMIC RTC 的写入走 rtc-pm8xxx 的 nvmem offset 机制（DTB 里给了
#   &pm8150_rtc 的 nvmem-cells = <&rtc_offset>）：
#   它把"目标时间 - RTC 硬件时间"存进 PM8150 的 SDAM，读的时候再加回来。
#
# 谁调用：rtc-save.service（开机 + 关机/重启前）+ rtc-save.timer（每 30 分钟）
# 原则：写不进去也不报错退出 —— RTC 没写上最多是时间又没存住，
#       绝不该影响开机/关机。
# ---------------------------------------------------------------------------
set -u

# 优先用系统自带的（util-linux 版）hwclock，没有就用 busybox 的 applet。
# 注意：rootfs 上**没有**装 util-linux-extra，所以 hwclock 通常不存在；
# busybox 在 initramfs 包里（/usr/lib/initramfs-tools/bin/busybox）一定有，
# payload 也会带一份 /usr/local/bin/busybox 兜底。
#
# ★★ 2026-10-19 实测踩到（srv1 刷完复现）：**busybox 的 hwclock 默认按"本地时间"
#    对待 RTC**（等价于 util-linux 的 `-l/--localtime`），而 util-linux 的默认是 UTC。
#    上面那句 `busybox hwclock -w -f /dev/rtc0` 于是把**本地时间**写进 RTC：
#        写：12:04（CST 本地）→ RTC  硬件里存的是 12:04
#        开机：内核 hctosys 按 **UTC** 读 → 系统时间 12:04 UTC = 20:04 CST（+8h 超前）
#        几秒后 systemd-timesyncd 用 NTP 纠回来 → 现象是"每次开机时间先超前 8 小时"，
#        而且**断网时永远差 8 小时**（服务器没网就没人能纠了）。
#    两边都必须显式声明"RTC 里存的是 UTC"（`-u` / `--utc`）。
if command -v hwclock >/dev/null 2>&1; then
	exec hwclock --systohc --utc --rtc /dev/rtc0
fi

for bb in /usr/local/bin/busybox \
          /usr/lib/initramfs-tools/bin/busybox \
          /bin/busybox /usr/bin/busybox; do
	if [ -x "$bb" ]; then
		exec "$bb" hwclock -w -u -f /dev/rtc0
	fi
done

echo "rtc-save: 既没有 hwclock 也没有 busybox，跳过（不影响开机）" >&2
exit 0
