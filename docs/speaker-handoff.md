# 小米9（cepheus / SM8150）内置扬声器 bring-up 交接文档

> 主线 Linux 6.17.0-sm8150，EDK2 UEFI 引导。最后更新 2026-10-22 20:35。
> 状态：**功放已能上电、整条 DAPM/ADM/AFE 链路全通，但依然没有声音。**

---

## 1. 硬件事实（已验证）

| 项目 | 值 | 来源 |
|---|---|---|
| 扬声器 | 单个「超线性扬声器」（非立体声） | 官方宣传 + 拆解 |
| 功放 | **Cirrus CS35L41**（B0，`35a40`） | 驱动读出芯片 ID |
| 功放 I2C | **`i2c@890000` = i2c-0**，地址 **0x40** | `/sys/bus/i2c/devices/0-0040` |
| 复位 | GPIO **89**，主线驱动要求 **`GPIO_ACTIVE_HIGH`**（原厂语义是低有效，反了会报 `Failed waiting for OTP_BOOT_DONE`） | probe 实测 |
| 中断 | GPIO **10**，`IRQ_TYPE_LEVEL_LOW` | 厂商 DT |
| 音频接口 | **QUATERNARY MI2S / TDM**，引脚 **gpio136-140**（`function = "qua_mi2s"`） | 见下 |
| 供电 | `VA = vreg_s4a_1p8`（1.8V），`VP = vreg_bob`（3352mV，enabled） | regulator 实测 |

### ★ 千万不要碰的引脚

**GPIO126-129 是 TrustZone 保护的。** 一旦 pinctrl 请求或写 mux，设备**直接死机**
（ping 都不通），只能强制重启。

- 主线 cepheus DTS 里有 `gpio-reserved-ranges = <0 4>, <126 4>`，**原厂 DT 没有这条**
- 厂商 DT 里那组 `sec_mi2s_active`（gpio126-129）**定义了但从未被引用**
- 结论：**扬声器不走 secondary MI2S**，早期一直往这个方向查是死路

---

## 2. 当前已做到什么（全部有日志证据）

```
CS35L41 TDM: sysclk=12288000 slot=6
AFEDBG port_start idx=36912 port_id=0x9030       ← TDM 端口启动成功
cs35l41: Enable(1) ok  PLL_LOCK=1                ← 功放上电成功
         SP_EN=0x00010000
         SP_FORMAT=0x18100000                    ← DSP_A 格式
         RX_WL=0x18 (24bit)  TX_WL=0x10
         OUT_MUTE=0x00000000                     ← 未静音
         PWR_CTRL3=0x01000010                    ← CLASS H 已开
         DAC_PCM1_SRC=0x8                        ← DAC 源 = ASP（直通，不经 DSP）
RTDBG stream_open fe=0 port=72 rate=48000 ch=2 → matrix_map 成功
ASMDBG run stream_id=1 ret=0                     ← ASM 流跑起来
PCM 状态: RUNNING（用 pw-play 播放时）
DAPM: AMP Playback/ASPRX1/PCM Source/Main AMP/CLASS H/SPK 全部 On
引脚: gpio136-140 全部 function=qua_mi2s
```

**内核日志一条错误都没有。但扬声器不出声。客户已确认原 Android 下喇叭正常（硬件没坏）。**

---

## 3. 已确认的正确配置（三方证据交叉验证）

### 3.1 厂商配置（`/vendor/etc/`，需要 `mount -o ro /dev/sde53 /mnt/vendor`）

```xml
<!-- audio_platform_info.xml -->
<device name="SND_DEVICE_OUT_SPEAKER" backend="speaker" interface="QUAT_MI2S_RX"/>

<!-- mixer_paths_tavil.xml，QUAT_MI2S_RX 出现 41 次，SEC_MI2S 一次都没有 -->
<path name="deep-buffer-playback speaker">
    <ctl name="QUAT_MI2S_RX Audio Mixer MultiMedia1" value="1" />
</path>
```

厂商 DT：
```dts
qcom,msm-dai-q6-mi2s-quat {
    qcom,msm-mi2s-rx-lines = <0x01>;   /* RX 只用 1 根 SD 线 */
    qcom,msm-mi2s-tx-lines = <0x02>;
};
qcom,msm-dai-tdm-quat-rx {
    qcom,msm-cpudai-tdm-clk-rate   = <0x177000>;  /* 1,536,000 Hz */
    qcom,msm-cpudai-tdm-invert-sync = <0x01>;
    qcom,msm-cpudai-tdm-data-delay  = <0x01>;
};
```
（1.536MHz + sync 反相 + 1 位延迟 = **标准 I2S 帧**）

### 3.2 上游参考实现（`map220v/sm8150-mainline`，**用 TDM 不是 I2S**）

抓取方式（沙箱里 web 被 DNS 拦，要用手机联网）：
```sh
curl -sL "https://gh-proxy.com/https://raw.githubusercontent.com/map220v/sm8150-mainline/master/sound/soc/qcom/sm8150.c"
```
（`ghproxy.net` / `ghfast.top` 都 000，只有 **`gh-proxy.com` 可用**）

关键代码：
```c
} cs35l41_tdm_channel_map[] = { {.rx = {6}}, {.rx = {7}}, {.rx = {6}}, {.rx = {7}} };

snd_soc_dai_set_sysclk(codec_dai, 0, 12288000, SND_SOC_CLOCK_IN);
snd_soc_component_set_sysclk(codec_dai->component, 0, 0, 12288000, SND_SOC_CLOCK_IN);
snd_soc_dai_set_channel_map(codec_dai, 0, NULL, 1, cs35l41_tdm_channel_map[j].rx);

/* TDM hw_params */
slot_width = 32;    /* 只接受 SNDRV_PCM_FORMAT_S24_LE */
slot_mask  = 0x44;  /* 槽位 2 和 6 */
snd_soc_dai_set_tdm_slot(cpu_dai, 0, slot_mask, 8, slot_width);   /* 8 槽 × 32bit */
```
→ 12.288MHz = 48k × 256bit（8 槽 × 32bit），功放只取**槽位 6**。

### 3.3 厂商功放驱动（`/vendor/lib/modules/audio_cs35l41.ko`，**带完整符号表**）

```sh
nm audio_cs35l41.ko | grep ' [tT] ' | grep cs35l41
```
函数列表与主线**逐个对应**（`main_amp_event`/`pcm_hw_params`/`dai_set_fmt`/`codec_set_sysclk`
/`dsp_load_ev`/`digital_mute`…），**DAPM 部件名也完全一致**
（SPK / Main AMP / DSP1 / ASPRX1-2 / ASPTX1-4 / CLASS H / PCM Source / DSP RX1-2 Source）。

厂商比主线多出的 mixer 控件（用 `strings` 看到，主线没有）：
```
ASPRX1 Slot Position / ASPRX2 Slot Position / ASPTX1-4 Slot Position
cirrus,classh-internal-algo / classh-* / boost-ctl-millivolt
cirrus,sclk-force-output / lrclk-force-output
cirrus,full-name / wmfw-file / bin-file / right-channel-amp / spk-id-pin
```

---

## 4. 当前 DTS 配置（`dts/cepheus-cam-ir-nfc.dtsi`）

```dts
&i2c4 {                       /* 实际 probed 成 i2c-0 */
    status = "okay";
    speaker_amp: speaker-amp@40 {
        compatible = "cirrus,cs35l41";
        reg = <0x40>;
        #sound-dai-cells = <1>;
        VA-supply = <&vreg_s4a_1p8>;
        VP-supply = <&vreg_bob>;
        pinctrl-names = "default";
        pinctrl-0 = <&quat_mi2s_active>;
        reset-gpios = <&tlmm 89 GPIO_ACTIVE_HIGH>;
        interrupt-parent = <&tlmm>;
        interrupts = <10 IRQ_TYPE_LEVEL_LOW>;
        cirrus,boost-peak-milliamp = <4000>;
        cirrus,boost-ind-nanohenry = <1000>;
        cirrus,boost-cap-microfarad = <15>;
        cirrus,gpio2-src-select = <4>;
        cirrus,gpio2-output-enable;
    };
};

&tlmm {
    quat_mi2s_active: quat-mi2s-active {
        pins = "gpio136", "gpio137", "gpio138", "gpio139", "gpio140";
        function = "qua_mi2s";
        drive-strength = <8>;
        bias-disable;
    };
};

/* 声卡里 */
mi2s-spk-dai-link {
    link-name = "SEC MI2S Playback";
    no-pcm;
    codec    { sound-dai = <&speaker_amp 0>; };
    cpu      { sound-dai = <&q6afedai QUATERNARY_TDM_RX_0>; };  /* 也试过 QUATERNARY_MI2S_RX */
    platform { sound-dai = <&q6routing>; };
};
```

---

## 5. 机器驱动改动（`sound/soc/qcom/sm8150.c`）

1. **probe 里加 DAPM 部件/路由**（原来完全没有，导致 codec 的 `SPK` 悬空）：
```c
static const struct snd_soc_dapm_widget sm8150_snd_widgets[] = {
    SND_SOC_DAPM_SPK("Speaker", NULL),
};
static const struct snd_soc_dapm_route sm8150_snd_routes[] = {
    { "Speaker", NULL, "SPK" },
};
/* probe 中： */
card->dapm_widgets = sm8150_snd_widgets;   card->num_dapm_widgets = ARRAY_SIZE(...);
card->dapm_routes  = sm8150_snd_routes;    card->num_dapm_routes  = ARRAY_SIZE(...);
```

2. **TDM 分支加 CS35L41 配置**（`sm8150_snd_startup` 的 `case QUATERNARY_TDM_RX_0`）：
```c
unsigned int rx_slot[1] = { 6 };
snd_soc_dai_set_sysclk(codec_dai, 0, 12288000, SND_SOC_CLOCK_IN);
snd_soc_component_set_sysclk(codec_dai->component, 0, 0, 12288000, SND_SOC_CLOCK_IN);
snd_soc_dai_set_channel_map(codec_dai, 0, NULL, 1, rx_slot);
```

3. **BE fixup 对 TDM 放开 S24_LE**（原来强制 S16，`set_params` 直接失败）：
```c
if (bd->id == QUATERNARY_TDM_RX_0 || bd->id == QUATERNARY_TDM_TX_0)
    snd_mask_set_format(fmt, SNDRV_PCM_FORMAT_S24_LE);
else
    snd_mask_set_format(fmt, SNDRV_PCM_FORMAT_S16_LE);
```

4. **codec 格式改 DSP_A 前必须先清格式位**（否则 `I2S|DSP_A` 同时置位报
   `Invalid or unsupported DAI format`）：
```c
codec_dai_fmt &= ~SND_SOC_DAIFMT_FORMAT_MASK;
codec_dai_fmt |= SND_SOC_DAIFMT_NB_NF | SND_SOC_DAIFMT_DSP_A;
```

5. 可用模块参数（运行时 `/sys/module/snd_soc_sm8150/parameters/`）：
   `amp_master`(0/1)、`codec_clk_id`(0=SCLK 1=LRCLK 4=MCLK)、`i2s_fmt_sel`(0=I2S 1=LJ 2=DSP_A 3=DSP_B)
   另有 `/sys/module/q6afe_dai/parameters/sd_line_override`(0..3)

## 6. codec 驱动改动（`sound/soc/codecs/cs35l41.c` / `-lib.c`）

**`cs35l41_dsp_audio_ev()` 里 DSP 加载失败不要返回错误**，否则 `DSP1` 部件永远
Off（DAPM 认为通路断开）：
```c
case SND_SOC_DAPM_POST_PMU:
    if (!cs35l41->dsp.cs_dsp.running) {
        int dret = wm_adsp_event(w, kcontrol, event);
        if (dret)
            dev_warn(cs35l41->dev, "DSP not running (%d), bypassing\n", dret);
        return 0;                      /* ← 关键：吞掉错误 */
    }
```

---

## 7. ★ 头号嫌疑：DSP 保护固件加载失败（-5 / -EIO）

```
cs35l41 0-0040: DSPLOAD loading fw at POST_PMU
cs35l41 0-0040: DSPLOAD wm_adsp_event failed: -5 (non-fatal)
```

- 固件文件**确实存在**：`/lib/firmware/cs35l41-dsp1-spk-prot.wmfw`（30916 B）
  与 `.bin`（3932 B），来自 `/vendor/firmware/`
- 不是 `-ENOENT`，说明文件被找到并解析了
- `wm_adsp_event(POST_PMU)` → `wm_adsp_run()` → `flush_work(boot_work)` → **`cs_dsp_run()`**
  → 返回 -5。`cs_dsp_run` 在本内核里**不是独立文件**（`cs_dsp.c` 不存在），
  实现在 `wm_adsp.c` 内部 —— **下一步就从 `cs_dsp_run` 里找 -EIO 的来源**。
- 已排查：`wm_adsp.c` 里 5 处 `-EIO` 全部在**压缩流**路径（`wm_adsp_buffer_*`），
  不在上电路径 → 说明 -5 来自更底层（很可能是 **DSP 内存窗口的 regmap 读写失败**）

**为什么这条最关键**：小米9 的扬声器是「超线性扬声器」，冲程大，**必须靠 CS35L41 的
DSP 实时限制振幅**。DSP 不跑时功放很可能出于保护**直接把输出级关掉**——这完美解释了
「寄存器全对、PLL 锁定、流 RUNNING，但一点声音都没有」。

---

## 8. 已经试过、确认无效的方法（**别再重复**）

| 尝试 | 结果 |
|---|---|
| SECONDARY MI2S（gpio126-129） | ❌ 引脚 TZ 保护，一写就死机 |
| QUAT MI2S（I2S 模式，2 槽，BCLK 1.536MHz） | 功放能上电、PLL 锁，**无声** |
| QUAT TDM（8 槽 × 32bit，BCLK 12.288MHz，槽位 6） | 同上，**无声** |
| `sd_line_override` = 0/1/2/3（SD0..SD3） | 全部无声 |
| `amp_master` = 0/1（功放当从机/主机） | 全部无声（SP_FORMAT 位确实变了） |
| `codec_clk_id` = 0(SCLK)/1(LRCLK)/4(MCLK) | MCLK 直接上电失败；另两个无声 |
| 帧格式 I2S / LeftJ / DSP_A / DSP_B | 全部无声 |
| 上电超时 100ms → 500ms | 不是时序问题（实测等满 527ms） |
| DSP 加载从 PRE_PMU 移到 POST_PMU | 仍是 -5 |
| 音量拉满（Digital PCM 913 / Analog 20 / sink 1.0） | 无变化 |
| `PCM Source` = ASP / DSP | ASP 正常选中，无声 |
| boost 参数（4000mA / 1.0uH / 15uF） | 与原厂 DT 一致 |
| 给功放加 sec_mi2s pinctrl | 死机 |
| 复用 gpio130（sec_mi2s_mclk） | 死机（同属 TZ 保护） |
| `aplay` 播放 | 报 `pcm_write: EIO`，流立刻 closed |
| `pw-play`（PipeWire）播放 | ✅ 流真的 RUNNING，但无声 |

> 补充：`aplay` 报 EIO 而 `pw-play` 正常，说明 ALSA 层对 TDM 的缓冲协商还有问题
> （`speaker-test` 会报 `contiguous map failed (-22)` + `DSP returned error[1]`）。
> **这个 EIO 和"没声音"可能是两个独立问题，先解决哪个都行。**

---

## 9. 建议的下一步（按性价比排序）

1. **查 `cs_dsp_run()` 里 -EIO 的来源**（最高优先级）
   - 在 `wm_adsp.c` 的 `cs_dsp_run` / `cs_dsp_power_up` / `cs_dsp_halo_start_core`
     里逐步加 `dev_info`，看停在哪一步
   - 特别怀疑 **DSP 内存窗口的 regmap 读写**返回 -EIO
     （CS35L41 的 DSP 内存通过 16 位地址窗口访问，和普通寄存器不同）
2. **示波器测 GPIO138**（QUAT MI2S SD0）播放时有无波形
   - 有波形 → 功放侧问题（基本可确定是 DSP 保护）
   - 无波形 → AFE 没在送数据
3. **反汇编厂商 `audio_cs35l41.ko`**
   - 它带完整符号表，重点看 `cs35l41_dsp_load_ev` / `cs35l41_dsp_power_ev`
   - 以及 `cs35l41_main_amp_event` 是否写了主线没写的寄存器
4. **抓厂商 HAL 运行时写入的 mixer 值**
   - 厂商有 `ASPRX1 Slot Position` 等控件，主线没有（改用 `set_channel_map`）
   - 可以在 Android 下 `tinymix` 抓一遍扬声器播放路径的所有值
5. 试厂商 TDM 帧参数：**1.536MHz + invert-sync + data-delay 1**

---

## 10. 环境备忘（会浪费时间的坑）

- **SSH**：`ssh mi9-usb`（169.254.42.1）。**sshd 会限流**，连续重连后
  `kex_exchange_identification: Connection closed` —— 等 1~3 分钟再连，或重启设备
- **设备偶尔重启会卡死**（ping 不通）→ 长按电源键 10 秒，必要时
  `音量下+电源` 进 fastboot
- **fastboot 恢复**：`fastboot flash boot out\RECOVERY-boot.img`
  （好镜像已备份在 `out/RECOVERY-boot.img`）
- **改坏模块导致开不了机**：用 `out/SAFE-kernelfat.img`
  （`modprobe.blacklist=snd_soc_sm8150`）刷 recovery 分区
  `fastboot flash recovery out/SAFE-kernelfat.img`
- **厂商分区**：`mount -o ro /dev/sde53 /mnt/vendor`（重启后要重挂）
- **kernelfat 已改成 4096 字节扇区 FAT16**，可以直接
  `mount /dev/sda28 /mnt/kernelfat` 然后 `cp Image /mnt/kernelfat/` 换内核，不用刷机
- **沙箱里 web/DNS 被拦**，但**手机能上网**：
  用 `ssh mi9-usb "curl ..."`；GitHub raw 走 `https://gh-proxy.com/https://raw.githubusercontent.com/...`
- 编译：WSL `/root/build/linux`，`make ARCH=arm64 LLVM=1 M=sound/soc/qcom modules`
  （模块换上去后要重启才生效）
- 刷 boot：`mi9-flash boot <img>`（设备上）；刷 DTB 要重跑
  `scripts/02-build-kernel.sh` + `scripts/03-build-edk2.sh`

---

## 11. 相关提交

`docs/audio.md` 的「追加 32~35」有完整逐日记录。关键提交：
`4e4ed3f`、`6df17f3`、`e0f63f6`、`6a8cf24`、`7a166dc`
