# 硬件支持现状

> **最后实测：2026-10-22 21:00**（内核 `6.17.0-sm8150`，Ubuntu 24.04 rootfs，
> EDK2 UEFI 引导 + FAT kernelfat）
>
> 表中每一项都来自设备实测（`/sys`、`dmesg`、`iw`、`bluetoothctl`、`amixer`、
> `debugfs`），不是推测。复现命令见文末。

---

## 一、完全可用（实测通过）

| 功能 | 现状 | 怎么验证的 |
|---|---|---|
| **启动链** | ✅ EDK2 UEFI（boot 分区）+ FAT kernelfat（recovery 分区 `sda28`），`startup.nsh` 跑 `fs3:\Image` | 单日重启 15+ 次零失败 |
| **换内核** | ✅ kernelfat 已改成 **4096 字节扇区 FAT16**，Linux 可 `mount /dev/sda28` 后 `cp Image` 直接换内核，**不用刷机** | `df` 显示 64M 正确、写入后 md5 一致 |
| **WiFi** | ✅ 2.4G 已连，iperf3 **60–72 Mbit/s**；5G 收发已验证（自建 AP ch44/ch149 可被 PC 关联） | `iw phy0 info`、iperf3 |
| **蓝牙** | ✅ `hci0 UP RUNNING`，BR/EDR + BLE，bluez 开机自启 | 40/40 轮长稳，0 掉线，平均 17.5 个 BLE 设备/轮 |
| **蓝牙音频（A2DP）** | ✅ PipeWire + bluez5，EDIFIER W800BT Plus 实测出声；`mi9-bt-pair` 自动配对守护（20 秒轮询，见设备就连） | 贴卡提示音从耳机里听到 |
| **红外发射** | ✅ `/dev/lirc0`，SPI1（QUP 0x884000）GPIO114-117 | `ir-ctl --scancode nec:0x20df10ef` 实测发出 |
| **NFC 读卡** | ✅ SN100U（i2c@a84000 / 0x28）完整工作：上电、NCI 初始化、轮询、读 UID/ATQA/SAK | UID `BC 33 55 81` / ATQA `0004` / SAK `08`，与 PC 商用读卡器 `nfc-list` **逐字段完全一致** |
| **NFC 贴卡提示音** | ✅ 检测到卡片 → 通过 PipeWire 播 `/usr/share/mi9/nfc-beep.wav`（蓝牙耳机/音箱出声）+ 日志打印卡号 | 实测贴卡耳机响两声 |
| **充电/电池** | ✅ `pm8150b-charger` + `qcom-battery`（容量/电压/电流/温度/状态）；`mi9-charge-guard` 75↔80% 往返 + 45°C 停充 | `/sys/class/power_supply/*` |
| **USB 网络** | ✅ RNDIS/NCM（`169.254.42.1`）+ `ttyGS0` 串口控制台 | SSH 全程使用 |
| **热控 / 看门狗** | ✅ 27 个热区（passive 90/95°C，critical 110°C）；`qcom_wdt` 60s 可自动复位 | `/sys/class/hwmon`、`/dev/watchdog` |
| **无人值守自愈** | ✅ `mi9-doctor` 15 分钟自检 + 日志；`mi9-dashboard` 在 tty1 显示 NET/SERVICES/ERROR | journal |
| **熄屏省电** | ✅ 开机 60s 熄屏（写黑 AMOLED framebuffer），电源键短按亮/灭，空闲 60s 再熄 | `/etc/mi9-screen.conf` |
| **内存压缩** | ✅ zram 2G + `swappiness=100` | `zramctl` |

## 二、部分可用

| 功能 | 现状 | 卡在哪 |
|---|---|---|
| **显示** | 🟡 只有 `simple-framebuffer`（`/proc/fb = 0 simple`），fbcon 文本可用 | 无 DPU/DSI 面板驱动，无 `/dev/dri`、无亮度调节、无 Wayland/X |
| **触摸** | 🟡 FTS 驱动 probe 成功、input 节点注册 | 初始化报 `ERROR 800E0007`，实际不可用（无 GUI 时影响小） |
| **内置扬声器** | 🟡 功放 CS35L41 能上电（`PLL_LOCK=1`）、DAPM/ADM/AFE 链路全通、流 RUNNING | **不出声**。保护 DSP 固件加载失败（-5）。完整记录见 `docs/speaker-handoff.md` |
| **麦克风** | 🟡 采集能跑起来 | WCD9340 ADC 输出全 0（`RX_MIX_TX0` 内部环回也是 0，与外部无关） |
| **NFC MIFARE 读写** | 🟡 raw socket 能连上卡片 | AUTH 帧格式不对（NCI 数据帧格式待攻关），工具 `tools/nfc-mifare.c` 已写好 |

## 三、不可用

| 功能 | 原因 |
|---|---|
| GPU（Adreno 640） | 无 msm/adreno 驱动 |
| 相机 | SoC 侧全通，模组从不应答（已归档 `archive/camera/`） |
| 传感器 | 挂在 SLPI 上（原厂 DT 有 `qcom,slpi_qrtr`），I2C 总线归 SLPI 管，AP 侧看不到 |
| 蜂窝网络 | modem remoteproc 起来了，但没有 IPA/rmnet |
| OTG Host / Type-C | 只有 gadget，无 `usb_role`/`extcon`/`typec` |
| 指纹 / 振动马达 / LED | 无驱动 |

---

## 四、开机自启的服务

```
mi9-nfcd          NFC 初始化 + 轮询 + 读卡 + 贴卡提示音
mi9-bt-pair       蓝牙耳机自动配对（20 秒轮询）
mi9-bt-speaker    蓝牙音箱保活
mi9-pipewire      PipeWire 音频栈
mi9-pipewire-pulse / mi9-wireplumber
mi9-charge-guard  充电守护（75↔80% + 45°C 停充）
mi9-doctor        自检自愈（timer，15 分钟）
mi9-dashboard     tty1 状态面板
mi9-screen-off    自动熄屏（timer）
mi9-usb-role      USB 角色切换
usb-net / wifi-up 网络
zram-swap         压缩内存
rtc-save          时钟保存
tqftpserv / pd-mapper / rmtfs   ADSP 固件加载
```

## 五、仍需做的事（按性价比）

1. **扬声器**：保护 DSP 固件加载失败（-5），是目前最大缺口。需要示波器测 GPIO138，
   或深挖 `cs_dsp_run()` 的 -EIO 来源。见 `docs/speaker-handoff.md`
2. **麦克风**：WCD9340 ADC 不转换，需要 SLIMbus 抓包或 ADSP AFE 配置
3. **NFC MIFARE**：NCI 数据帧格式
4. **触摸** `800E0007`（想接屏幕再说）
5. 显示（DPU/DSI 面板）、GPU、传感器、相机、modem：按计划搁置

---

## 六、复现命令

```sh
# 启动 / 换内核
cat /proc/cmdline
df -h /mnt/kernelfat          # 4K 扇区 FAT16，64M

# 网络
iw phy phy0 info | grep 'Band '
bluetoothctl devices; hciconfig hci0

# NFC
systemctl status mi9-nfcd
journalctl -u mi9-nfcd -n 20 | grep UID

# 音频
cat /proc/asound/cards                    # sm8150-tavil-snd-card
amixer -c 0 controls | wc -l
wpctl status | sed -n '/Sinks:/,/Sources:/p'

# 电源/充电
for d in /sys/class/power_supply/*/; do echo "== $d"; cat $d/status $d/capacity 2>/dev/null; done

# 热控/看门狗
ls /sys/class/hwmon | wc -l; ls /dev/watchdog*
```
