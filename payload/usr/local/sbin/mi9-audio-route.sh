#!/bin/sh
# mi9-audio-route —— 设置扬声器（CS35L41 / QUAT MI2S）默认路由与音量
#
# 为什么需要它：扬声器通路要手动把 MultiMedia1 路由到 QUAT_MI2S_RX，
# 并把功放音量拉起来；这些设置重启就没了。本脚本在开机（及开机后
# 若声卡晚到会重试）时统一设置一次。
#
# 关键背景（详见 docs/audio.md 追加 11-13）：
#   - 功放 CS35L41 挂在 QUATERNARY MI2S（GPIO137/138 SCLK/WS，139 SD0）
#   - 采集/播放要走这条 BE，否则一点声音都没有
#   - 功放上电依赖 PLL 正确配置（SCLK 参考 1536000），已在机器驱动里修好
set -u

CARD=${CARD:-0}
log() { logger -t mi9-audio-route "$*"; }

ctl() {
	# ctl <name> <value>，失败不致命
	amixer -c "$CARD" cset name="$1" "$2" >/dev/null 2>&1 && return 0
	return 1
}

i=0
while [ ! -e /proc/asound/card$CARD ] && [ $i -lt 120 ]; do
	sleep 0.5
	i=$((i + 1))
done
if [ ! -e "/proc/asound/card$CARD" ]; then
	log "声卡没出现，退出"
	exit 0
fi

# 等功放绑定
i=0
while [ ! -d /sys/bus/i2c/devices/0-0040 ] && [ $i -lt 60 ]; do
	sleep 0.5
	i=$((i + 1))
done

# 1) 关掉 SLIM 通路（避免和 MI2S 抢同一条 FE）
ctl 'SLIMBUS_0_RX Audio Mixer MultiMedia1' 0
ctl 'SLIMBUS_1_RX Audio Mixer MultiMedia1' 0

# 2) 打开扬声器：MultiMedia1 -> QUAT MI2S
ctl 'QUAT_MI2S_RX Audio Mixer MultiMedia1' 1

# 3) 音量：功放数字/模拟都拉到 100%，再按需衰减
ctl 'Digital PCM Volume' 100%
ctl 'Analog PCM Volume' 100%

log "扬声器路由已设置（QUAT MI2S + 100%% 音量）"

# 4) 打印一下结果，便于 journalctl 排查
if amixer -c "$CARD" cget name='QUAT_MI2S_RX Audio Mixer MultiMedia1' >/dev/null 2>&1; then
	log "QUAT 路由 = on"
fi
