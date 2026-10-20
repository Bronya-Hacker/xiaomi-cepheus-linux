# 扬声器实验计划（待执行）

## 背景

小米 9 的扬声器功放是 **CS35L41**（i2c4 / 0x40，已 probe 成功），音频输入来自
**secondary MI2S**：GPIO126(SCLK) 127(WS) 128/129(SD) 130(MCLK)。

问题：主线 sm8150 的板级 DTS 里

```dts
gpio-reserved-ranges = <0 4>, <126 4>;
```

把 **126-129 保留**了，导致 pinctrl 申请这些脚时 `-EINVAL`，MI2S 配不上，
功放拿不到 I2S 信号（`Enable(1) failed: -110`）。

## 已知事实

- 只把保留去掉（`<0 4>`），**当时实测起不来**（三次变砖）；
- 但当时那些镜像**同时**还挂着功放的 `pinctrl-0 = <&sec_mi2s_active>`，
  **两个变量混在一起，没分离**；
- 反查：i2c-2（c80000，触摸屏 0x49）用的是 `qup_i2c17_default` 的引脚，
  **不是** 126/127；`qup_i2c2_default` 才用 126/127，而 QUP2 并没有启用；
- 也就是说**当前 DTB 里没有别的设备抢 126-129**。

## 三个可用镜像（都在 `out/`）

| 文件 | 内容 | 用途 |
|---|---|---|
| `SAFE-boot-cepheus.img` | 保留 `<0 4>, <126 4>`，功放不挂 pinctrl | **现在设备上跑的就是这版，正常** |
| `TEST-A-unreserve-boot.img` | 只去掉保留 `<0 4>`，功放**不挂** pinctrl | **先试这个**：单独验证"保留"是否有罪 |
| `TEST-mi2s-boot.img` | 去掉保留 **+** 功放挂 sec_mi2s pinctrl | 第二步：真正让 MI2S 跑起来 |

kernelfat 用现在的 `out/kernelfat.img`（r3.9，含全部修复），不用动。

## 执行步骤

### 第一步：TEST-A（只去掉保留）

```powershell
fastboot flash boot out\TEST-A-unreserve-boot.img
fastboot reboot
```

- **能开机** → 说明"保留"本身没问题，之前变砖是 pinctrl 害的。
  进入第二步。
- **起不来**（无网络、不在 fastboot）→ 长按电源 10 秒 → 音量下+电源 →
  刷回 `SAFE-boot-cepheus.img`。结论：保留不能动，扬声器走 MI2S 这条路彻底堵死。

### 第二步：TEST-mi2s（去保留 + 挂 pinctrl）

```powershell
fastboot flash boot out\TEST-mi2s-boot.img
fastboot reboot
```

开机后（如果能开机）应该看到：

```sh
# 引脚应该被 claim 成 sec_mi2s，不再是 UNCLAIMED
grep -E 'pin 12[6-9]' /sys/kernel/debug/pinctrl/3100000.pinctrl/pinmux-pins
# 功放应该 probe 成功
ls /sys/bus/i2c/devices/0-0040/driver
```

然后放音：

```sh
amixer -c 0 cset name='SLIMBUS_0_RX Audio Mixer MultiMedia1' 0
amixer -c 0 cset name='SEC_MI2S_RX Audio Mixer MultiMedia1' 1
aplay -D hw:0,0 -t raw -f S16_LE -r 48000 -c 2 /var/lib/mi9-audio/melody.raw
```

- 如果 `Enable(1) failed: -110` 消失并且喇叭出声 → **扬声器打通了**。
- 如果仍然 -110 → 功放的供电（VP）或 MCLK 还有问题，见下。

### 万一又起不来

```powershell
# 长按电源 10 秒关机 → 音量下+电源
fastboot flash boot out\SAFE-boot-cepheus.img
fastboot reboot
```

## 如果第二步也不行，下一步查什么

1. **功放 VP 供电**：CS35L41 的功率电源多半直连电池或经负载开关，
   不是 PMIC 可控轨。`vreg_bob` 顶不上。需要从原厂电源树确认。
2. **MCLK**：原厂有 `sec_mi2s_mclk`（GPIO130）。我们已把 130 加进 pinctrl，
   但 AFE 侧要给 MCLK（`AFE_CLK_MCLK_1`, 12.288 MHz），机器驱动里已经加了。
3. 若确认是供电问题，可以先用**耳机通路**验证播放链路（已可用），
   扬声器等硬件改造后再试。
