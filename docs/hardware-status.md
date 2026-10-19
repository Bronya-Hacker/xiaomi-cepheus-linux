# 硬件支持现状（对照"成熟主线移植"）

> 最后实测：2026-10-19（内核 `6.17.0-sm8150`，Ubuntu 24.04 rootfs）。
> 表中"现状"全部来自设备实测（`/sys`、`dmesg`、`iw`、`hciconfig`），不是推测。
> 复现命令见文末。

## 一、核心功能

| 功能 | 成熟移植应有的水平 | 本机现状 | 差距 / 影响 |
|---|---|---|---|
| 启动链 | UEFI/ABL 引导、可回滚、刷机稳定 | ✅ edk2-msm UEFI + `fs3:\Image`；`sda28` 有备份可回退 | Linux 侧写不进 boot 分区，改 DTB 必须走 fastboot |
| 显示 | DRM/KMS（DPU+DSI 面板）+ 背光/亮度/刷新率 | ⚠️ 仅 `simple-framebuffer`（`/proc/fb` = `0 simple`），无 `/dev/dri` | 只有 fbcon 文本；无亮度调节、无 Wayland/X |
| GPU | Adreno 640（msm/adreno + devfreq） | ❌ 无驱动、无 devfreq | 纯 CPU 渲染（本机无 GUI，影响小） |
| 触摸 | FTS 驱动 + input 事件 + 手势 | ⚠️ 驱动 probe、`fts` input 节点已注册，但初始化报 `ERROR 800E0007` | 触摸大概率不可用（无 GUI 时影响小） |
| 音频 | q6asm/q6afe + WCD9385 + 扬声器/听筒/麦克风 + UCM | ❌ 无 soundcard，`q6asm_dai` 仍在 cmdline 黑名单 | 完全无声音 |
| 蜂窝 | modem 固件 + IPA/rmnet + ModemManager + SIM/通话/短信/数据 | ❌ `remoteproc modem=running`，但无 `/dev/wwan`、无 IPA/rmnet | 完全不可用（暂缓） |
| WiFi | 2.4G+5G、WPA3、接近线速、挂起恢复 | ✅ 2.4G 已连；iperf3 实测 **60–72 Mbit/s**；5G 收发已验证（自建 AP 在 ch44/ch149 均能被 PC 关联） | 家里路由器 5G 不回应本机认证（AP 侧）；未验证 WPA3 / 挂起恢复 |
| 蓝牙 | BR/EDR + BLE、配对/重连、A2DP/HID、开机自启 | ✅ `hci0 UP RUNNING`、BLE 扫描通过、bluez 开机自启 | A2DP 不可用（无音频子系统）；长稳测试见 §四 |
| GPS/GNSS | qcom 定位 + gpsd | ❌ 无 | 无 |
| 电池/充电 | PMIC charger + Type-C(tcpm) + fuel gauge + 快充 + 电量/温度上报 | ✅ `pm8150b-charger` + `qcom-battery`（容量/电压/电流/温度/状态）；软件停充可用 | **无 Type-C 角色/ALT mode、无快充协商、无充电上限硬件寄存器**（用软件停充代替） |
| 电源键 | 可配置短按/长按 | ✅ logind `HandlePowerKey=ignore`（服务器化） | 良好 |
| 挂起 | deep suspend（s2idle + deep） | ⚠️ 只有 `s2idle` | 服务器常开，不算问题 |

## 二、外设与接口

| 功能 | 成熟移植 | 本机现状 | 差距 |
|---|---|---|---|
| USB device | RNDIS/ECM/NCM + ADB/MTP | ✅ RNDIS/NCM + `ttyGS0` 串口控制台 | 无 ADB/MTP（不需要） |
| USB Host / OTG | 双角色 + 供电管理 | ❌ 仅 gadget，无 `usb_role`/`extcon` | 不能接 U 盘/键鼠/网卡 |
| Type-C | tcpm + 翻转/角色/ALT mode | ❌ 无 `typec` 类 | 无 |
| 传感器 | 加速度/陀螺/ALS/气压/霍尔 | ❌ `iio` 只有 3 个 PMIC ADC | 无 |
| 相机 | CAMSS/CSI + sensor + libcamera | ❌ 无 `/dev/video*` | 无 |
| 指纹 / NFC / 红外 / 马达 / LED | 各自驱动 | ❌ 全无（无 `/sys/class/leds`） | 无 |
| 存储 | UFS HS-G4 + 健康监控 | ✅ 系统跑在 `/dev/sda31`（110G） | 良好 |
| 温控 | 多热区 + passive/critical trip | ✅ 27 个热区，passive 90/95 °C，critical 110 °C | 良好 |

## 三、工程化与运维

| 项 | 常见移植水平 | 本机现状 |
|---|---|---|
| 内核改动可复现 | 有，但常散落成文档 | ✅ `patches/*.patch` + 幂等 apply 脚本 + 构建期 DTB 门禁 |
| DTS 上游化 | 独立 dtsi，可提交上游 | ⚠️ vendor DTS + 追加片段（第 1~4 部分），尚未拆成上游式 dtsi |
| 硬件看门狗 | 很少有 | ✅ `qcom_wdt` 60 s，实测可自动复位 |
| 内存/交换 | 很少配 | ✅ zram 2G + `swappiness=100` |
| 无人值守自愈 | 基本没有 | ✅ `mi9-doctor`（15 分钟自检+自愈+健康日志） |
| 远程运维 | SSH | ✅ SSH keepalive、journal 上限、NTP、无关服务 mask、权限加固 |
| 仪表盘 | 无 | ✅ tty1 只读状态面板（NET/SERVICES/RECENT ERR） |

## 四、明确的待办（按性价比）

1. ~~**充电策略**~~ ✅ 已完成：`mi9-charge-guard`（75%~80% 往返 + 45 °C 停充），开机自启。
2. ~~**WiFi 5G + 吞吐**~~ ✅ 已测：2.4G 60–72 Mbit/s；5G 收发正常（自建 AP 验证）；家里路由器 5G 不接本机（AP 侧）。
3. ~~**蓝牙长稳**~~ ✅ 已完成：40/40 轮 `UP RUNNING`，0 次掉线，平均 17.5 个 BLE 设备/轮。
4. 触摸 `800E0007`（想接屏幕再说）。
5. deep suspend / OTG / 传感器 / 相机 / 音频 / modem：按计划搁置。

## 五、复现命令

```sh
# 电源管理
ls /sys/devices/system/cpu/cpu0/cpuidle/     # state0 state1
cat /sys/power/mem_sleep                     # [s2idle]

# 显示/GPU
ls /dev/dri; cat /proc/fb                    # 无 dri；0 simple

# 音频/传感器/相机
cat /proc/asound/cards                       # --- no soundcards ---
for d in /sys/bus/iio/devices/iio:device*; do cat $d/name; done
ls /dev/video* 2>/dev/null

# 电源/充电
for d in /sys/class/power_supply/*/; do echo "== $d"; cat $d/status $d/capacity $d/voltage_now $d/temp 2>/dev/null; done
ls /sys/class/typec /sys/class/extcon /sys/class/usb_role 2>/dev/null

# 网络
iw phy phy0 info | grep 'Band '
ls /dev/wwan* 2>/dev/null
for r in /sys/class/remoteproc/*; do echo "$(cat $r/name)=$(cat $r/state)"; done

# 温控/看门狗
ls /sys/class/hwmon | wc -l
ls /dev/watchdog*
```
