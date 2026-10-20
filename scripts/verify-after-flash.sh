#!/bin/sh
# 刷机后一体检：系统 / 外设 / 音频 / 扬声器
# 用法（设备上）： sh /tmp/verify.sh
echo "=== 系统 ==="
echo "内核    : $(uname -r)"
echo "build   : $(cat /etc/build-id 2>/dev/null)"
echo "payload : $(cat /etc/wifi-cfg.ver 2>/dev/null)"
echo "失败单元: $(systemctl list-units --state=failed --no-pager 2>/dev/null | grep -c 'loaded failed')"
echo "负载    : $(cut -d' ' -f1-3 /proc/loadavg)"
echo
echo "=== 外设 ==="
echo "WiFi  : $(iw dev 2>/dev/null | grep -c Interface) 个接口"
echo "红外  : $(ls /dev/lirc0 2>/dev/null || echo 缺)"
echo "NFC   : $(ls /sys/class/nfc/ 2>/dev/null || echo 缺)"
echo "声卡  : $(head -n1 /proc/asound/cards 2>/dev/null | tr -s ' ' || echo 缺)"
echo "功放  : $(ls /sys/bus/i2c/devices/0-0040/driver 2>/dev/null | head -n1 || echo 缺)"
echo "i2c   : $(ls -d /sys/bus/i2c/devices/i2c-* 2>/dev/null | wc -l) 条总线"
echo
echo "=== 电池 ==="
echo "$(cat /sys/class/power_supply/qcom-battery/capacity 2>/dev/null)%  $(cat /sys/class/power_supply/qcom-battery/status 2>/dev/null)"
echo
echo "=== 音频路由控件 ==="
amixer -c 0 scontrols 2>/dev/null | grep -cE "MultiMedia" | sed 's/^/混音器控件: /'
amixer -c 0 scontrols 2>/dev/null | grep -E "SEC_MI2S_RX Audio Mixer MultiMedia1|SLIMBUS_0_RX Audio Mixer MultiMedia1" | head -n 2
echo
echo "=== MI2S 引脚 mux 状态 ==="
grep -E "pin 12[6-9]|pin 130" /sys/kernel/debug/pinctrl/3100000.pinctrl/pinmux-pins 2>/dev/null | head -n 5
echo
echo "=== 音频相关 dmesg ==="
dmesg | grep -iE "cs35l41|mi2s|snd-sm8150" | tail -n 6
