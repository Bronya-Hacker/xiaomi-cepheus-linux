# 音频（Xiaomi Mi 9 / cepheus）

2026-10-20 完成到「声卡注册成功」。主板用的是 **WCD9340（原厂名 tavil）**。

## 已达成（真机验证）

```
$ cat /proc/asound/cards
 0 [sm8150tavilsndc]: sm8150 - sm8150-tavil-snd-card
                      Xiaomi-MI9-cepheus
```

- 声卡注册成功，**1240 个混音器控件**，5 个前端 PCM（MultiMedia1..5）；
- Headset Jack（耳机检测）正常工作，`input4` 出现；
- WCD934x codec 探测成功：`WCD934x chip id major 0x108, minor 0x1`；
- 所有音频模块开机自动加载（黑名单已删）。

## 硬件接线（从原厂 DT 挖出）

| 信号 | 引脚 |
|---|---|
| codec IRQ | GPIO **123** |
| codec 复位 | GPIO **143** |
| 电源 vdd-buck/tx/rx/io/micbias | `pm8150 S4`（1.8V，板级标签 `vreg_s4a_1p8`） |
| 电源 vdd-vbat（3.3V） | `pm8150l BOB`（`vreg_bob`） |
| SLIMbus | `slim-ngd@171c0000`，codec 地址 `217:250:1:0` |

## 关键踩坑

1. **q6asm-dai 被黑名单屏蔽**：之前为压内核报错，在 `startup.nsh` 的 cmdline
   （`modprobe.blacklist=q6asm_dai`）和 `payload/etc/modprobe.d/blacklist-audio.conf`
   里都屏蔽了它。做音频时这两处都要删，否则 FE dai 一直 defer。
2. **q6asm-dai 需要 dais 子节点**：`&q6asmdai { dai@0 { reg = <MSM_FRONTEND_DAI_MULTIMEDIA1>; }; ... }`，
   否则报 `No dais found in DT`。
3. **audio-routing 要用 WCD9340 的有效 widget**（AMIC/DMIC/MIC BIAS/RX_BIAS），
   不能用 vendor 的 `MADINPUT`/`Headset Mic` 那些（是 vendor 私有 widget）。
4. 板级 DTS 会被 `apply-dts*.sh` 冲掉 → 所有音频 DT 都放在
   `dts/cepheus-cam-ir-nfc.dtsi` 里，由 `apply-dts5.sh` 追加。

## 还没做的（最后一段）

1. **真正出声**：FE PCM（MultiMedia1）打开还报 `-22`，需要把 FE↔BE 的 DSP 路由
   打通（`q6routing` / AUDIO RX 混音），并接好 SLIM playback BE → WCD9340 的
   AIF1_PB / 耳机（HPH）/ 麦克风通路；
2. **扬声器**：主板有 4 个 WSA881x 功放挂在 WCD9340 内部的 SoundWire 上，
   目前只定义了 SWR master，还没加 wsa881x 子节点 → 扬声器无声，耳机可能可以；
3. UCM 配置（给 PulseAudio 用）。

## 重启条件 / 下一步

- 先加 wsa881x 子节点 + 正确的 `audio-routing` 和 DAPM 通路，
  再用 `speaker-test` / `amixer` 逐步调试，直到耳机和扬声器都能出声。

## 追加：出声的最后一步卡在 AFE 口（2026-10-20 18:30）

### 已打通

- 声卡 `sm8150-tavil-snd-card` 注册，codec chip id 0x108，Headset Jack 正常；
- FE↔BE 路由通了：`amixer cset name='SLIMBUS_0_RX Audio Mixer MultiMedia1' 1`
  之后 `speaker-test` 不再报 "no backend DAIs"，说明 FE(MultiMedia1) 已经连到 BE(SLIM Playback)。

### 卡点

```
qcom-q6afe: cmd = 0x100e5 returned error = 0x9
qcom-q6afe: AFE enable for port 0x4000 failed -22
q6afe-dai: fail to start AFE port 2  (SLIMBUS_0_RX)
```

ADSP 固件拒绝启用 SLIMBUS_0_RX 这个 AFE 口（DSP error 9）。试过 S16/S24、
mono/stereo、48k/44.1k 都一样。这不是码率/位宽问题，而是 **SLIM RX 口的
AFE port 配置（vendor 有专门的 slimbus port config 步骤）主线这边缺了**，
或者 tavil 的 SLIM RX 口需要在 codec AIF1 侧先把 SLIMbus stream 配好。

### 下一步方向

1. 对照 vendor 的 `q6afe` port config（SLIMBUS_0_RX 的 channels/bit_width
   /slimbus 映射），确认主线 `q6afe-dai` 有没有少传 port config；
2. 或在 `sm8150_be_hw_params_fixup` 里给 SLIM RX 口补 8 通道的 SLIMbus 映射
   （tavil AIF1 是 8 路 SLIM 通道）；
3. 顺带把 WSA881x 扬声器功放接上（挂在 WCD9340 内部 SoundWire）。

## 追加2：SLIMbus 口配置已攻克（2026-10-20 18:50）

### 根因（主线 bug）

`q6afe_slim_port_prepare()` 有两个问题，导致 ADSP 拒绝 SLIM RX 口配置：

1. **`slimbus_dev_id` 从没被设置**（一直是 0）—— struct `q6afe_slim_cfg` 里
   根本没有这个字段，prepare 也没传；SM8150 固件要求 `AFE_SLIMBUS_DEVICE_1 = 1`。
2. **`shared_ch_mapping` 填错了**——注释明确写着是「128..255 的共享通道 ID」，
   我最初填成 1,2,3,4，正确是 128,129,130,131。

### 修法（3 处，都在 qdsp6 下）

- `q6afe.h`：`struct q6afe_slim_cfg` 加 `u16 slimbus_dev_id;`
- `q6afe.c`：`q6afe_slim_port_prepare()` 里传 `pcfg->slim_cfg.slimbus_dev_id = cfg->slimbus_dev_id;`
- `q6afe-dai.c`：`q6slim_hw_params()` 里 `slim->slimbus_dev_id = 1;`
  且 `ch_mapping = {128,129,130,131}`

改完后 `AFE enable for port 0x4000` 不再报错，说明 SLIM 口配置已被 DSP 接受。

### 现在卡在下一层

```
qcom-q6asm: DSP returned error[1]
q6asm-dai: Memory_map_regions failed
q6asm-dai: Audio Start: Buffer Allocation failed rc = -22
```

FE（MultiMedia1）的 PCM 缓冲区在做 `q6asm` 的 memory-map 时被 DSP 拒（error 1）。
q6asm 的 iommu SID 0x1b21 与 vendor 一致，audio_pd 也已 up（PDR 有指示）。
下一步方向：q6asm memory map 的缓冲区对齐/拓扑（topology）设置，或
`ASM_STREAM_CMD_MEMORY_MAP` 前的 session 配置顺序。

## 追加3：memory-map 的最后一层（2026-10-20 19:10）

### 试过但无效

| 尝试 | 结果 |
|---|---|
| `open_write` 与 `memory_map` 换顺序 | 仍 error 1 |
| 强制 `sid=-1`（地址不带 SID 高位） | 仍 error 1 |
| `shared_ch_mapping` 用 128–131 | ✅ 有效（AFE 口配置被接受） |

### 现场数据

```
MEMMAPDBG pool=3 regions=1 sz=524288 phys=0x00000000fff80000
qcom-q6asm: DSP returned error[1]
q6asm-dai: Memory_map_regions failed
```

- `mem_pool_id = 3`（`ADSP_MEMORY_MAP_SHMEM8_4K_POOL`），与 vendor 相同；
- 缓冲区大小 512 KB（`buffer_bytes_max`）；
- 地址 `0xfff80000` —— 这是 **apps_smmu 分配的 IOVA**（不是物理地址）。

### 判断

DSP 拒绝这个 IOVA。大概率是 **ADSP 侧看不到 apps_smmu 分配的这段 IOVA**：
音频缓冲区需要由 ADSP 自己的 SMMU/共享内存池来映射，而主线把 q6asmdai 挂在
`apps_smmu 0x1b21` 上，地址空间对不上。

vendor 用的是 **`msm-audio-ion`**（专用 Ion heap + ADSP 可访问的固定物理区），
主线这条路径没有对应实现。

### 下一步（需要更多信息）

1. 查 sm8150 是否有独立的 **ADSP SMMU**（不是 apps_smmu），把 q6asmdai 的
   iommus 指过去；
2. 或者参考 vendor 的 `msm-audio-ion`，给音频缓冲分配一段 ADSP 可见的固定内存，
   用物理地址做 memory-map（而不是 IOVA）；
3. 这一步基本要靠 ADSP 固件的接口文档，主线没有现成参考（sm8250 音频用的是
   GPR/Audioreach 新架构，路径不同）。

## 追加4：播放打通后，扬声器（WSA881x）卡在 SWR 链路

### 已完成

- `q6asm` 内存映射**解决**：连续映射失败自动退化为按 period 分段映射，
  2 秒 440Hz `aplay` 跑完、dmesg 零错误；
- WSA881x 两个功放在 SoundWire 上**枚举成功**：
  `sdw:0:0:0217:2010:00:1` / `:2`，`wsa881x-codec` 驱动绑定；
- 时钟核对无误：`ln_bb_clk2` = 19.2 MHz（与 vendor 一致），
  codec 的 `mclk` = 19.2/2 = 9.6 MHz（SWR 时钟门）。

### 卡点

加了功放之后，寄存器读写全部失败：

```
soundwire sdw-master-0-0: trf on Slave 0 failed:-5
qcom-soundwire: SWR CMD error, fifo status 0x3e000127, flushing fifo
qcom-soundwire: swrm_wait_for_frame_gen_enabled: link status not disconnected
qcom-soundwire: link failed to connect
wsa881x-codec: Initialization not complete, timed out
```

把功放放进 BE 的 codec 列表后，BE 启动会等它们，结果播放超时（-ETIMEDOUT），
所以先摘掉——现在播放恢复干净。

### 已排除

| 假设 | 结论 |
|---|---|
| DT 配置抄错 | 与主线 db845c（同为 wcd9340 + qcom-soundwire v1.3.0）完全一致 |
| `default_rows/cols` 缺失 | `swrm_v1_3_data` 有 48/16，正常 |
| 时钟频率不对 | 19.2 MHz / 9.6 MHz 均与 vendor 一致 |
| `iface` 时钟拿不到 | 驱动 probe 成功，无报错 |
| 功放没供电/被 shutdown | 能枚举说明已上电且不在 shutdown |

### 下一步方向

1. 怀疑 **codec 电源状态顺序**：功放 probe 时 codec 还在 DAPM standby，
   内部 SWR 时钟被自己的电源管理关掉 → 没有帧。可试"先跑一次 DAPM 路径
   （如录音）再让功放 probe"；
2. 或检查 `wcd934x_swrm_clock()` 写 `WCD934X_CDC_CLK_RST_CTRL_SWR_CONTROL`
   时 codec 是否真的接受（该寄存器经 SLIMbus 写入，可加调试打印确认）；
3. fifo status `0x3e000127` 可对照 qcom-soundwire 的错误位定义进一步定位。
## 能用起来的部分：`mi9-audio` 工具

```sh
mi9-audio setup          # 只配置路由
mi9-audio tone 2         # 播 2 秒 440Hz 测试音
mi9-audio play foo.raw   # 播放 raw PCM（S16_LE 立体声）
mi9-audio status         # 看声卡和路由状态
```

它把 `SLIMBUS_0_RX Audio Mixer MultiMedia1` 和耳机（HPH）通路的 12 个
amixer 设置打包好了，省得每次手敲。已放进 `payload/usr/local/bin/`，
下次刷 payload 就会出现在 `/usr/local/bin/mi9-audio`。

### 录音状态

`arecord` 能跑通（1 秒 = 192000 字节），但**录到的全是 0**：
采集链路（AMIC → DEC0 → SLIM TX0 → AIF1_CAP）的 DAPM 通路还没接对，
和扬声器一样属于"最后调音"范畴。

## 追加5：录音全 0 的真凶方向 —— SLIMbus 通道编号

### 实测（录音时 DAPM 状态）

```
MIC BIAS2    On      AMIC2   On      ADC2   On
AMIC MUX0    On      CDC_IF TX0 MUX On   SLIM TX0  On
AIF1_CAP Mixer On    AIF1 CAP On    AIF1 Capture On
PCM state: RUNNING   arecord 6 秒 → 576000 样本，峰值 0
```

也就是说：**软件链路全通、流在跑，但数据是纯 0**。模拟静音不会这么干净，
说明 codec 根本没往 SLIMbus 上发数据。

### 原因方向

两套通道编号对不上：

| 侧 | 编号 |
|---|---|
| codec（wcd934x） | SLIM TX 通道 **0–15**，SLIM RX 通道 **16–31** |
| AFE（q6afe） | `shared_ch_mapping` 要求 **128–255** 的共享通道 ID |

我在 `q6slim_hw_params` 里给两个方向都填了 `128,129,130,131`——RX 方向 DSP 接受了
（所以播放能跑），但 codec 实际用的是 0–15/16–31，两边接不到同一根通道上，
于是没有数据搬运。播放"成功"目前只验证到 DSP 接受缓冲区，**并不代表 codec 真收到了音频**。

### 下一步

查 vendor  tavil 的 SLIMbus 通道映射：AFE 的 shared channel 与 codec 的
port 通道怎么对应（可能是 `128+port` 或需要 `wcd934x_slim_set_channel_map()`
把 codec 端口映射到 128 起的共享通道）。定下来之后播放和录音应该一起通。

### 通道基址实验（已做完）

给 `q6afe-dai.c` 加了两个调试参数 `rx_ch_base` / `tx_ch_base`，
把 AFE 的共享通道映射做成运行时可调，一次重启里试了
`tx_ch_base = 128 / 0 / 16 / 32 / 64`——**全部仍然录到纯 0**。

同时确认：

- 控制器实现了 `enable_stream`（会发 `SLIM_MSG_MC_DEF_ACT_CHAN` 激活通道），
  架构上不缺数据通路；
- 该基址下 DSP 都接受配置、不报 AFE 错误；
- 录音时 codec 侧 `AIF1 Capture` 是 `On`、PCM `RUNNING`。

### 结论

控制面（SLIMbus 寄存器读写、DAPM、AFE 端口启动）全通，
**数据面（SLIMbus 音频通道真正搬数据）不工作**，而且与通道基址无关。
下一步需要对照 vendor 的 SLIMbus 通道分配表，或用逻辑分析仪抓 SLIMbus 波形，
确认 codec 是否真的把数据推上了总线。

## 追加6：内部环回实验 —— 决定性证据

### 端口编号是交错的（我之前的判断错了）

```c
#define SLIMBUS_0_RX  2
#define SLIMBUS_0_TX  3
#define SLIMBUS_1_RX  4
#define SLIMBUS_1_TX  5
```

所以播放是 id=2（SLIMBUS_0_RX）、录音是 id=3（SLIMBUS_0_TX），
我原来用 `id >= SLIMBUS_0_RX && id <= SLIMBUS_6_RX` 判断方向是错的
（id=3 被当成 RX）。已改成按奇偶判断：

```c
if (((dai->id - SLIMBUS_0_RX) % 2) == 0)   /* RX */
```

### 实验：codec 内部环回

把采集源设成 codec 内部的 `RX_MIX_TX0`（把播放混音直接接到采集口），
同时播放 440 Hz，再录音：

```
内部环回录音 -> RMS 0  峰值 0
```

codec 的 SLIM TX 端口寄存器确认已使能（`0x50 = 0x05`，water mark 12 字节 +
enable；通道掩码 `0x100 = 0x01`）。

### 结论

**SoC 侧 SLIMbus 接收方向（ADSP AFE 从总线取数据）没有工作**，
与麦克风、与通道基址（0/16/32/128 全试过）都无关。
这解释了为什么播放"能跑"但听不到、录音"在跑"但全是 0。

主线 `slim-ngd` 只实现了控制面的 `enable_stream`（发 DEF_ACT_CHAN），
而 vendor 的音频走的是 SLIMbus **共享通道**那一套，两边机制可能不完全等价。
要继续需要：SLIMbus 抓包确认 codec 是否真的在推数据，或补上共享通道支持。

## 追加7：把 codec 通道号改到共享区（128+）—— 无效

### 想法

SLIMbus 的 0–127 是「非共享通道」，128–255 才是「共享通道」。音频数据通常
必须走共享通道才能被 SoC 侧的 SLIMbus 硬件路由到 ADSP 的 AFE 端口。
主线 `wcd934x_set_channel_map()` 用的是 framework 给的通道号（0 起），
于是试着在驱动里统一加 128。

### 结果

- codec 驱动改完（纯模块，重启生效）后做 `RX_MIX_TX0` 内部环回录音：
  **仍然是 RMS 0**；
- 而且采集的 prepare 直接报错：
  `q6asm_dai_prepare: stream reg failed ret:-22`
  （`q6routing_stream_open` 失败）；
- 普通播放不受影响。

说明把通道号推到 128+ 反而让 ADM 路由注册失败，方向不对。已回退。

### 结论

通道编号不是这层的原因。数据面问题要么在 ADSP 的 AFE←SLIMbus 硬件配置，
要么需要 vendor 的 SLIMbus 通道分配表。继续盲试的性价比已经很低。

## 追加8：扬声器功放是 CS35L41，已经 probe 成功！（2026-10-20 23:10）

### 发现过程

之前一直以为扬声器是 WSA881x（走 codec 内部 SoundWire），折腾了很久都读不了寄存器。
挂载原厂 **vendor 分区**（`/dev/sde53`，只读）后翻到：

```
/vendor/firmware/cs35l41-dsp1-spk-prot.bin / .wmfw
/vendor/lib/modules/audio_cs35l41.ko
/vendor/etc/cs35l41_cal.wav
原厂 DT: cs35l41@40 { compatible = "cirrus,cs35l41"; ... } 在 i2c@890000
```

**扬声器功放是 Cirrus CS35L41**，而且主线内核**已经有 cs35l41 驱动**
（`CONFIG_SND_SOC_CS35L41=m` + `_I2C=m`，而且我们早就编进去了）。

### 接线

| 信号 | 值 |
|---|---|
| I2C | `i2c@890000`（主线 **i2c4**），地址 **0x40** |
| 复位 | GPIO **89** |
| 中断 | GPIO **10**（低电平） |
| 音频输入 | **secondary MI2S**：GPIO126（SCLK）、127（WS）、128/129（SD0/SD1）|

### 踩的坑：复位极性

第一版照原厂语义写成 `GPIO_ACTIVE_LOW`，驱动报：

```
cs35l41 0-0040: error -ENXIO: Failed waiting for OTP_BOOT_DONE
```

原因：主线驱动假设复位是**高有效**——先拉低 2ms 再拉高释放；用 ACTIVE_LOW
时逻辑 1 变成物理低，等于一直按着复位。改成 `GPIO_ACTIVE_HIGH` 后：

```
cs35l41 0-0040: Cirrus Logic CS35L41 (35a40), Revision: B0
```

**驱动 probe 成功**，芯片 ID `35a40` 读出来了，I2C 上还能直接读到同样的 ID。

### 还差的一步

功放已经是 ASoC 组件但还没接进声卡。要出声需要：

1. 把 GPIO126-129 mux 成 `sec_mi2s`；
2. 在声卡里加一条 dai-link：`cpu = <&q6afedai SECONDARY_MI2S_RX>`、
   `codec = <&speaker_amp 0>`；
3. 给功放配 MCLK（原厂有 `sec_mi2s_mclk` 引脚）。

这条路比 WSA881x/SoundWire 那条干净得多——全是主线现成的驱动。

### 追加8.1：MI2S 接线已通，只差 I2S 格式配置（2026-10-20 23:20）

把 CS35L41 以 BE dai-link 接进声卡：

```dts
	mi2s-spk-dai-link {
		link-name = "SEC MI2S Playback";
		no-pcm;
		codec { sound-dai = <&speaker_amp 0>; };
		cpu { sound-dai = <&q6afedai SECONDARY_MI2S_RX>; };
		platform { sound-dai = <&q6routing>; };
	};
```

结果：

- 声卡正常注册（`sm8150-tavilsndc`），多出了
  **`SEC_MI2S_RX Audio Mixer MultiMedia1`** 这个路由控件 —— 说明 AFE 侧的
  链路是通的；
- 打开它再播放，`snd_soc_dai_prepare() on SEC_MI2S_RX` 报 **-22**。

原因：**`sound/soc/qcom/sm8150.c` 里只有 SLIM 和 TDM 的 `hw_params`，
没有 I2S 的 `set_fmt` / 格式配置**，所以 `q6afe` 的 I2S 端口拿不到格式参数。

### 下一步（扬声器真正出声）

1. 在机器驱动里给 MI2S 加 `hw_params`/`set_fmt`（I2S、32bit、48k）；
2. 解决 `sec_mi2s` 引脚复用那个 `-EINVAL`（`msm_pinmux_request` 认为
   引脚 126 无效，但 pinctrl debugfs 里 pin 126 是注册着的，需要再查）；
3. 给 CS35L41 配 MCLK 和 `cirrus,firmware-name`（可选，纯播放不一定需要）。

功放已经认识、能读 ID、驱动绑定，剩下的是把数字音频送进去。

### 追加8.2：MI2S 准备过了，卡在功放最后上电（2026-10-21 01:20）

#### 已解决

1. **`qcom,sd-lines`**：`&q6afedai` 里必须给 MI2S 的 DAI 声明 SD 线，
   否则 `sd_line_mask = 0`，`SEC_MI2S_RX` 的 prepare 永远 -22。
   加了 `dai@18 { reg = <SECONDARY_MI2S_RX>; qcom,sd-lines = <0>; }` 后
   prepare 通过；
2. **I2S 格式**：`sm8150.c` 只有 SLIM / TDM 的 `hw_params`，补了一个
   `sm8150_i2s_snd_hw_params()`：给 cpu dai 设 `SND_SOC_DAIFMT_I2S|
   NB_NF|CBC_CFC`，并给 codec dai 设 `set_sysclk(CS35L41_CLKID_SCLK, ...)`。

#### 仍然卡住

```
cs35l41 0-0040: Enable(1) failed: -110
cs35l41 0-0040: ASoC: PRE_PMU: Main AMP event failed: -110
```

`global_enable()` 在等 PUP/PDN 中断超时。试过并**无效**的：

- 接 `VA-supply = <&vreg_s4a_1p8>` / `VP-supply = <&vreg_bob>`；
- 补原厂的 GPIO2 配置（`cirrus,gpio2-src-select = <4>` + output-enable）；
- 设 sysclk 用 SCLK（位时钟）当参考。

#### 关键线索

反绑定驱动后，I2C 地址 0x40 **不再应答**（`No such device or address`）——
功放只在驱动释放复位后短暂出现。OTP boot 能完成、ID `35a40` 读得到，
说明芯片本体是好的；但一使能输出级（GLOBAL_EN）就起不来。

推断：**功放的 VP（功率电源）没真正供上**。它多半直接取自电池 / 或由某个
未开的负载开关控制，不是 PMIC 可控轨，`vreg_bob` 替代不了。

#### 下一步

要确认功放 VP 的真实来源，需要从原厂的电源树（原理图 / vendor 的 regulator
映射）找它挂在哪个源上，而不是继续猜 PMIC 轨。

★ 当前设备状态：**健康**（声卡注册、SLIM 路由播放正常、功放驱动仍绑定，
只是扬声器不响）。MI2S 相关改动都保留在 DT 和机器驱动里。

### ★ 重要工程坑：模块改动必须走 payload，手动拷进 /lib/modules 无效（2026-10-21 01:35）

今天在设备上改 cs35l41 / sm8150 机器驱动时发现：

- 手动 `cp *.ko /lib/modules/...` + `depmod` + `modprobe` 看似生效；
- **但一重启就回到原样** —— 因为开机时 initramfs 会解 `mods.tar.gz`
  （payload）到 `/lib/modules`，把手动放进去的文件**覆盖掉**。

也就是说：**改内核模块必须重跑 02（重打 mods.tar.gz）→ 06（kernelfat）
→ 刷 kernelfat 才会真正生效**。今天早些时候把 payload 版本号改成内容指纹
正是为了这个（否则连刷 kernelfat 都不会重新解压）。

推论：之前几次"改了模块、重启后行为没变"的困惑，根源就在这里。

### ★ 根因：secondary MI2S 的引脚在主线 pinctrl 里没有 GPIO 功能（2026-10-21 02:00）

实测 `gpioget gpiochip3 <n>`：

| 引脚 | 作用 | 结果 |
|---|---|---|
| 126 | SEC_MI2S SCLK | ❌ Invalid argument |
| 127 | SEC_MI2S WS | ❌ Invalid argument |
| 128 | SEC_MI2S SD0 | ❌ Invalid argument |
| 129 | SEC_MI2S SD1 | ❌ Invalid argument |
| 130 | SEC_MI2S MCLK | ✅ 能读 |

看 `drivers/pinctrl/qcom/pinctrl-sm8150.c`：

```c
[126] = PINGROUP(126, SOUTH, sec_mi2s, qup2, phase_flag, _, ...);
[130] = PINGROUP(130, SOUTH, sec_mi2s, pll_bist, atest_usb20, atest_char0, ...);
```

126-129 的功能表里**没有 gpio 位**（对比 130 有），所以这些脚在 gpiochip 的
valid_mask 之外 → pinctrl 框架 `ops->request` 走 `gpiochip_line_is_valid()`
失败 → 任何引用它们的 pinctrl 状态都会 `-EINVAL`（这就是之前挂在 &sound 上
导致声卡注册失败的原因）。

也就是说：**在主线 sm8150 的 pinctrl 定义下，secondary MI2S 的 SCLK/WS/SD
根本申请不到**，功放这条路被 pinctrl 卡住，不是音频驱动的问题。

### 解决方向

给 `pinctrl-sm8150.c` 里 126-129 的 PINGROUP 补上 gpio 功能位（4 行改动），
让它们能被 request；然后 pinctrl 状态才能把它们 mux 成 sec_mi2s。

★ 注意：这属于改动主线 pinctrl 定义，要确认不影响其它功能（这几个脚只有
sec_mi2s / qup2 / phase_flag 等，加 gpio 位只是允许 GPIO 用法）。

### ★★ 真凶：我们自己的 DTS 把功放的 MI2S 引脚保留掉了（2026-10-21 02:50）

绕了一大圈，根因其实在我们自己的板级 DTS 里：

```dts
/* dts/sm8150-xiaomi-cepheus.dts 第 538 行（原） */
gpio-reserved-ranges = <0 4>, <126 4>;
```

`<126 4>` 把 **126-129 四个脚从 gpiochip 的可用范围里剔除**，于是 pinctrl
框架申请它们时必然 `-EINVAL`：

```
sm8150-pinctrl: error -EINVAL: pin-126 (0-0040)
cs35l41 0-0040: Error applying setting, reverse things back
```

这多半是当初照抄主线 sm8150 板子（mtp / hdk / surface-duo 都写了 `<126 4>`）
带进来的——**那些板子不用 secondary MI2S，但小米 9 的功放 CS35L41 就接在
126-129 上**（原厂 DT 里它们就是 `function = "sec_mi2s"`）。

所以：
- 不是主线 pinctrl 的限制；
- 不是功放坏了（OTP boot 成功、ID `35a40` 读得到）；
- 不是缺固件；
- **就是这行保留把 MI2S 引脚锁死了**。

修法：去掉 `<126 4>`（只留 `<0 4>`）。

## 追加9：声卡起不来的真凶是 q6asm_dai 没自动加载（2026-10-21 04:50）

### 现象

```
platform sound: deferred probe pending: snd-sm8150: MultiMedia1:
                error getting cpu dai name
```

声卡一直 registered 不了。一度怀疑是 DTB 写错。

### 真因

`q6asm_dai` 模块**没有自动加载**。`apr-service@7:dais` 这个平台设备的 modalias
没有触发 udev 去 modprobe 它，于是声卡注册时找不到 "MultiMedia1" 这个 CPU DAI。

手动 `modprobe q6asm_dai` 之后，声卡立刻注册，**1032 个混音器控件**全部出现。

### 修复

`payload/etc/modules-load.d/mi9-audio.conf`：按依赖顺序显式列出整条音频模块链
（snd 核心 → q6core/q6afe/q6asm/q6adm/q6routing → SLIMbus+WCD9340 → CS35L41 → sm8150）。

### 顺带：ir-spi 开机 modprobe 报 Exec format error

但 `insmod` 同一个文件却成功（`rc rc0: lirc_dev: driver ir-spi registered`，
`/dev/lirc0` 出现）。vermagic 完全一致（`6.17.0-sm8150 SMP preempt mod_unload aarch64`），
属于 modprobe 的模块查找路径问题，不是模块本身坏。

---

## ★★ 极其重要：删掉 `gpio-reserved-ranges` 里的 `<126 4>` 会让手机起不来

今天为了给功放腾出 secondary MI2S 的 126-129，我把板级 DTS 里的

```dts
gpio-reserved-ranges = <0 4>, <126 4>;
```

改成了 `<0 4>`。结果**刷进去直接起不来**（不进 fastboot、没有网络、没有串口输出）。

实测对照（同一次 kernelfat、只换 boot）：

| boot 里的保留 | 结果 |
|---|---|
| `<0 4>, <126 4>`（原样） | ✅ 正常启动 |
| `<0 4>`（去掉 126-129） | ❌ 起不来 |

这也解释了为什么主线所有 sm8150 板子（mtp / hdk / surface-duo / oneplus / sony）
都写着 `<126 4>` —— **这 4 个脚在这颗 SoC 上被保留是有原因的**
（大概率是 UFS / 电源相关，被别的东西用着）。

**结论：扬声器走 secondary MI2S 这条路，在"保留不能去掉"的前提下走不通。**
要继续攻扬声器，得换个思路（例如查这 4 个脚到底被谁用、或者确认功放是否有其它输入路径）。

---

## 追加10：录音全 0 的新线索（2026-10-21 05:28）

模块问题全修好之后，声卡和播放都正常了，但**录音仍然是全 0**：

```
$ arecord ... -d 2 /tmp/rec.raw
样本 192000  峰值 0  非零 0

dmesg:
  q6afe-dai ... SLIMDBG id=3 rate=48000 bits=16 ch=2 fmt=0 map=128,129,130,131
  q6asm-dai ... command[0x10bdb] not expecting rsp
```

- `SLIMDBG id=3` 说明 **SLIMBUS_0_TX 端口参数是配上了**的（3 = SLIMBUS_0_TX）；
- 但紧接着 `command[0x10bdb] not expecting rsp`：DSP 给了一条驱动**没在等**的响应，
  说明命令/响应配对出了问题（`q6asm.c` 里我们改过 `mem_pool_id=3` 和
  `contig_override`，需要盯一下这条是不是它引起的）。

### 下一步排查方向

1. 把 `q6asm.c` 里我们改动的地方（mem_pool_id / contig_override）逐条回退对照，
   确认 `0x10bdb` 是不是自找的；
2. TX 的通道映射：现在 capture 也用 `map=128,129,130,131`（和 playback 一样），
   但 vendor 的 capture 映射可能不同（之前强行改成 128+ 导致
   `q6routing_stream_open ret:-22` 而回退过）；
3. 确认 codec 侧 ADC/TX 真的在出数据（读 WCD9340 的 TX 端口状态寄存器）。

---

## 追加11：★ 扬声器真正的音频通道是 QUATERNARY MI2S（2026-10-21 05:45）

### 怎么找到的

翻原厂 vendor 分区的 mixer 配置，找到 **cepheus 专用的 overlay**：

```
/mnt/vendor/etc/mixer_paths_overlay_static.xml

  <path name="deep-buffer-playback speaker">
      <ctl name="QUAT_MI2S_RX Audio Mixer MultiMedia1" value="1" />
  </path>
  <path name="low-latency-playback speaker">
      <ctl name="QUAT_MI2S_RX Audio Mixer MultiMedia5" value="1" />
  </path>
  ...
  <ctl name="AMP Enable Switch" value="0" />
  <ctl name="DSP1 Firmware" value="Protection" />
  <ctl name="PCM Source" value="DSP" />
  <ctl name="AMP PCM Gain" value="17" />
  <ctl name="ASP TX1 Source" value="Zero" />
```

两件事一次说清：

1. **扬声器走 QUATERNARY MI2S**（`QUAT_MI2S_RX`），**不是** secondary MI2S
   —— 我前面折腾半天的 126-129 引脚方向从根上就错了；
2. `AMP Enable Switch` / `DSP1 Firmware` / `PCM Source=DSP` 这些是 **CS35L41 的
   DSP 控件**，确认功放就是 CS35L41（不是 WSA881x，WSA 那些控件是参考设计遗留）。

### 引脚

quat_mi2s 用的是 **GPIO136（MCLK）/ 137 / 138 / 139 / 140**，
而保留区是 0-3 和 126-129 —— **136-140 完全是自由的**，主线 `pinctrl-sm8150`
也支持（`qua_mi2s_groups` 含 gpio136-140）。

### 已做的改动（已刷入验证）

- dtsi：`quat_mi2s_active`（gpio136-140，function `qua_mi2s`）挂到功放节点；
- dtsi：`&q6afedai` 的 dai 节点改成 `reg = <QUATERNARY_MI2S_RX>` + `qcom,sd-lines = <0>`；
- dtsi：后端链路 cpu 改成 `<&q6afedai QUATERNARY_MI2S_RX>`；
- 机器驱动：`sm8150_i2s_snd_hw_params()` 按端口选 IBIT 时钟
  （新增 `AFE_CLK_{PRI,TER,QUAD}_MI2S_IBIT`），并让 `QUATERNARY_MI2S_RX` 走这条路径。

### 结果：引脚复用成功了！

```
pin 136 (GPIO_136): 0-0040 (GPIO UNCLAIMED) function qua_mi2s group gpio136
pin 137..140:       同上
```

声卡注册、**`QUAT_MI2S_RX Audio Mixer MultiMedia1` 控件出现**、功放绑定、
**启动完全正常**（没有动保留区，所以不会变砖）。

### 但功放仍然上电失败

```
cs35l41 0-0040: Enable(1) failed: -110
cs35l41 0-0040: ASoC: PRE_PMU: Main AMP event failed: -110
```

所以卡点不在音频通道，而在**功放自身的上电**。

### 接下来三个方向

1. **VP 供电**：CS35L41 的功率级要 VP（约 3.8V）。原厂靠 ADSP 控制
   （`PCM Source=DSP`），主线上我们只能自己管理。现在指到 `vreg_bob`(3.35V)，
   很可能**并不是板上真正给功放的那一路**（多半直连电池或经负载开关）。
2. **MCLK**：GPIO136 是 quat_mi2s 的 MCLK，但 AFE 侧我们只设了 `MCLK_1`，
   到底哪一路 AFE 时钟接到 136 不确定，需要试 `MCLK_2/3/4`。
3. **DSP 固件**：主线这个版本的 cs35l41 驱动**没有**加载 wmfw 的能力
   （没有 `cirrus,firmware-name` 属性读取）。而原厂是
   `DSP1 Firmware=Protection` —— 说明厂商靠 DSP 固件做扬声器保护。
   若要完全对齐厂商行为，需要升级到支持 cs_dsp 固件的新版驱动，
   并把 `/vendor/firmware/cs35l41-dsp1-spk-prot.wmfw` 放进 `/lib/firmware`。

---

## 追加12：★ 功放 -110 的真因：CS35L41 的 PLL 从来没被配置（2026-10-21 16:30）

### 怎么一步步定位到的

用寄存器现场（`cs35l41-lib.c` 里加的失败 dump）逐个排除：

| 观测 | 结论 |
|---|---|
| `DEVID=0x00035a40` | 芯片活着、I2C 通 |
| `STATUS4` bit1 = 1 | OTP boot 成功 |
| `PWR_CTRL1 = 0x1` | GLOBAL_EN 已置位 |
| `PWR_CTRL2 = 0x20` | boost 使能位写进去了（说明写操作有效、核心在工作） |
| `STATUS2 = 0` | **没有任何错误标志**（不是短路/过温/欠压保护） |
| `STATUS3 = 0x20000000` | **bit1 PLL_LOCK = 0 —— 芯片没有可用时钟** |
| DSP 固件写超时 `-110` | 同一件事的另一种表现（DSP 也要时钟） |

### 真因

CS35L41 的时钟配置有**两个层次**，机器驱动只做了一半：

| 函数 | 作用 | 之前 |
|---|---|---|
| `snd_soc_dai_set_sysclk()` | 只写 **FS monitor 窗口**（`TST_FS_MON0`） | ✅ 有调用 |
| `snd_soc_component_set_sysclk()` | **真正配置并启用 PLL**：选参考源（SCLK/LRCLK/MCLK）、按采样率查表写参考频率、最后 `PLL_CLK_EN=1` | ❌ **从没调用** |

也就是说：PLL 一直是**关闭**状态，芯片内部没有时钟可用，
`GLOBAL_EN` 之后永远等不到 `PUP_DONE`，于是 1 秒后超时 → `-110`。

### 修法

`sm8150_i2s_snd_hw_params()` 里在调 DAI 的 `set_sysclk` 之前，先调
`snd_soc_component_set_sysclk(codec_dai->component, clk_id, 0, rate, SND_SOC_CLOCK_IN)`；
时钟源（0=SCLK / 1=LRCLK / 4=MCLK）仍留在模块参数 `codec_clk_id` 里，
一次刷机就能把三种都试一遍。

### 顺带加的调试

- `q6afe-dai.c` 里 `I2SDBG`：打印实际下给 DSP 的端口参数
  （实测 `id=22`(QUATERNARY_MI2S_RX) `rate=48000 bits=16 ch=2 fmt=0 sd_mask=0x1`）
- `cs35l41-lib.c`：失败时 dump `STATUS1/2/3/4 + PWR_CTRL1/2 + OTP + FS_MON0`

---

## 追加13：★★ 功放已经能上电了！（2026-10-21 18:30）

### 里程碑

`Main AMP` widget 实测 **`On`** 持续可见，`Enable(1) failed: -110` 完全消失。
也就是说 CS35L41 的 PLL 锁上了、GLOBAL_EN 等到了 `PUP_DONE`。

### 修掉的三个真 bug（按发现顺序）

1. **PLL 从来没被启用** —— 只调了 `snd_soc_dai_set_sysclk()`（只写频率监测窗口），
   而真正选参考源 + 使能 PLL 的是 `snd_soc_component_set_sysclk()`。
2. **MI2S 分支没给 codec 设 DAI 格式** —— `sm8150_snd_startup()` 只处理了 TDM 和 SLIM，
   MI2S 落到 default 分支（日志 `invalid dai id 0x16`），codec 保持默认 ASP 配置，
   和 SoC 抢时钟。而且要带 `SND_SOC_DAIFMT_I2S`，只写 `CBC_CFC` 会被
   cs35l41 判为 "Invalid or unsupported DAI format"。
3. **PLL 参考频率传错** —— `cs35l41_pll_sysclk[]` 表里是**时钟频率**
   （32768 ~ 6.4MHz+），不是采样率。之前一律传 48000：
   - LRCLK 碰巧对（48k）
   - **SCLK 必须传 1536000**（48k × 32）
   - MCLK 必须传 12288000
   
   实测只有 `codec_clk_id=0`(SCLK) + 1536000 这一组能上电。

### 关于 pin 的确认（来自原厂 DT）

- `quat_mi2s_active` = **gpio137/138（SCLK/WS）**，`quat_mi2s_sd0_active` = gpio139，
  `quat_mi2s_sd1_active` = gpio140 —— 和我们 mux 的完全一致。
- **`quat_mi2s_mclk`(gpio136) 根本没被 `sound-tavil` 引用**
  → 功放是从**位时钟 SCLK** 取参考的，不需要 MCLK。这解释了为什么 mclk_id 怎么调都没用。

### 还剩的问题：DSP 不消费数据

现在 `aplay` 报的 EIO 其实是 ALSA core 的
**"playback write timeout (DMA or IRQ trouble?)"**（`sound/core/pcm_lib.c:2027`）：
FE 会话起来了，但 DSP 一个 period 都不消费 → 1 秒超时。

- SLIM 通路一切正常（对照组），只有 MI2S 通路这样。
- AFE 端口配置正确：`id=22(QUATERNARY_MI2S_RX) rate=48000 bits=16 ch=2 sd_mask=0x1`
  → 内部映射到 `AFE_PORT_ID_QUATERNARY_MI2S_RX = 0x1006`，
  `q6afe_port_start()` 没有报错。
- 怀疑点：**ADM matrix map 的时机** —— 我们先用 `amixer` 设路由（触发 map），
  之后 aplay 在 prepare 里 `q6afe_port_stop()` + 重新 start，
  map 可能因此失效，导致 COPP 没有接到运行中的端口上。

下一步方向：让 q6routing 在 BE prepare 之后再 map 一次（或在 port start 后重发 map）。

---

## 追加14：功放已上电/通路全开，但仍无声（2026-10-21 19:20）

### 已验证正常的（全部实测）

| 项目 | 证据 |
|---|---|
| 功放上电 | `OKDBG Enable(1) ok`，`STATUS1=0x01400000`（bit24 PUP_DONE） |
| PLL 锁 | `STATUS3=0x2000002e`，`PLL_LOCK=1` |
| 升压目标电压 | `BST_VCTRL1=0x78`（8500mV，主线原本写 0，已修） |
| 升压使能 | `PWR_CTRL2=0x20` |
| 功放增益 | `AMP_GAIN=0x280`，`Digital/Analog PCM Volume` 均在最大 |
| 内部通路 | `AMP Playback: On` → `ASPRX1: On` → `Main AMP: On`、`CLASS H: On` |
| DSP 送数据 | `aplay` 退出码 0，无超时（FE 正常消费） |
| 四种数据线 | `sd_line_override=0/1/2/3` 全部播放成功（`sd_line_mask=0x1/0x2/0x4/0x8`） |
| codec 直推 | WCD9340 只有 `EAR PA Volume`，**没有 SPK 功放控件** → 喇叭不是 codec 直推 |

### 仍无声的两个主要怀疑

1. **PCM 实际走 DSP 而不是 ASP**
   原厂配置是 `PCM Source=DSP` + `DSP1 Firmware=Protection`。
   主线默认让 PCM 直连功放；如果这颗芯片的 OTP 把内部通路设成 DSP，
   直连路径就没有声音。
   尝试加载 `cs35l41-dsp1-spk-prot.wmfw`（已放进 /lib/firmware）：
   固件能被解析，但**写 DSP 内存超时**（`Failed to write 18280 bytes at 0 in PM_PACKED: -110`），
   即使功放已上电、PLL 已锁、强制 SCLK/LRCLK 也照样超时
   → 怀疑 DSP 需要 **MCLK**（板上 gpio136 未接），或需要原厂的 HALO 引导私有步骤。

2. **喇叭可能不接在这颗功放上**
   I2C 上确实有 CS35L41（`0x40`，`35a40`），但无法从软件确认它驱动的是主喇叭。

### 已做成的工具/服务

- `mi9-audio-route.service` + `mi9-audio-route.sh`：开机自动设置 QUAT MI2S 路由与音量
- 模块参数：`codec_clk_id`（PLL 时钟源）、`boost_mv`（升压电压）、
  `sd_line_override`（MI2S 数据线）—— 都可在运行时调整，方便后续排查
- 调试打印：`OKDBG`（功放上电后寄存器）、`BOOSTDBG`、`AFEDBG/RTDBG/ASMDBG`（DSP 命令）

---

## 追加15：★ 喇叭硬件确认没坏（2026-10-21 19:45）

### 怎么验证的

用桌面上现成的 MIUI 线刷包
`cepheus_images_V12.5.5.0.RFACNXM_20211025.0000.00_11.0_cn.tgz` 里的 `boot.img`，
**只做 `fastboot boot`（从内存启动，不写任何分区）**：

```sh
tar xzf cepheus_images_*.tgz --wildcards '*/images/boot.img'
fastboot boot images/boot.img
```

MIUI 正常进桌面，**放音乐喇叭有声** → **喇叭、功放、走线全部正常**。

测完恢复 Linux（`boot` 分区其实没被改动，因为 `fastboot boot` 只写内存）：

```sh
fastboot flash boot    out/OTG-boot-cepheus.img   # DTB/EDK2
fastboot flash recovery out/kernelfat.img         # 内核/模块
```

### 因此结论明确

问题 100% 在**我们的软件配置**，不是硬件。剩下的差异只可能在：

1. **功放的保护 DSP 固件没跑起来**（原厂是 `DSP1 Firmware=Protection` + `PCM Source=DSP`）。
   主线能解析固件但**写 DSP 内存超时**（`PM_PACKED: -110`），
   即使功放已上电、PLL 已锁也一样 —— 说明 DSP 核本身没在应答。
2. 原厂 reg_default 里那些主线不写的寄存器
   （`0x6404/0x6408` VPBR/VBBR 保护阈值、`0x4000`、`0x3818` 等）。

### 已核对过、确认**一致**的部分

- `cs35l41_pup_patch` / `pdn_patch`：与原厂逐字节相同
- `cs35l41_dsp1_regions`（DSP 内存窗口）：type/base 完全相同
- `revb0_errata_patch`：原厂多一条 `ASP_CONTROL4(0x4854)=0x01010000`（已补上）
- 原厂独有的 `PCM Source` 控件：`DAC_PCM1_SRC(0x4C00)`，ASP=8 / DSP=50（已做成参数）

### 下一步方向

- 继续查 DSP 核为什么不响应（需要看 HALO 引导的私有步骤/MCLK 需求）
- 或者：**既然 MIUI 音频完全正常，把"小爱音箱"的软件直接做在 Android 上**
  （喇叭、麦克风、蓝牙都是现成的），比死磕主线音频更快见效

---

## 追加16：功放寄存器全绿，只剩 DSP 固件这一关（2026-10-21 20:05）

播放中实测（`OKDBG`，48k/16bit/2ch，QUAT MI2S）：

```
S1=0x01400000  PUP_DONE          S3=0x2000002e  PLL_LOCK=1
BST_VCTRL1=0x78 (8.5V)           PWR_CTRL2=0x20 (boost on)
AMP_GAIN=0x280                   OUT_MUTE=0x0   ← 输出没被静音
SP_EN=0x00010000                 ← ASPRX1 已使能
SP_FORMAT=0x10180200             ← ASP_FMT=2(I2S)
RX_WL=0x10 (16bit)               TX_WL=0x18
PWR_CTRL3=0x01000010             DAC_PCM1_SRC=0x8 (ASP)
```

也就是说：**从 DSP 到功放的所有环节都是"正常"状态，但仍然没有声音**，
而同一块硬件的 MIUI 能出声。

### 唯一剩下的差异：保护 DSP 固件

`cs35l41-dsp1-spk-prot.wmfw` 能被 cs_dsp 解析，但
`regmap_raw_write(PM_PACKED, ..., 18280)` **返回 -110（超时）** —— 是 I2C 写本身超时，
说明 DSP 内存窗口没在应答（DSP 核没跑起来）。

已排除：
- `cs35l41_dsp1_regions`、`otp_map_1/2`（99 条）、`pup/pdn_patch`：与原厂**完全一致**
- regmap `max_register=0x03804FE8`：覆盖 DSP 窗口，不是被 regmap 拒绝

怀疑：DSP 核需要**常驻 MCLK**（笔记本设计里平台一直给 12.288MHz；
本板原厂 `sound-tavil` 的 pinctrl-0 只引用 `quat_mi2s_active/sd0/sd1`，**没有 mclk**），
或需要原厂私有步骤（模块里有 `cs35l41_set_csplmboxcmd`，主线没有对应实现）。

### 下一步（下次接着做）

1. 打开 GPIO136 的 MCLK 输出（AFE `mclk_id` 已做成参数），再试加载 DSP 固件
2. 反汇编原厂 `cs35l41_set_csplmboxcmd` / `cs35l41_dsp_load_ev`，复刻它的 HALO 引导顺序
3. 若 DSP 固件始终加载不了，改用"纯 ASP 直连"路线，但要弄清功放为什么不放行
   （可能内部需要有 DSP 的"保护已就绪"信号才解除静音）

---

## 追加17：复刻原厂 POST_PMU 加载时机（2026-10-21 20:20）

反汇编原厂 `cs35l41_dsp_power_ev` / `cs35l41_dsp_load_ev` 得到关键差异：

| | 加载保护固件的时机 |
|---|---|
| 原厂 | **POST_PMU**（功放上电**之后**，`cs35l41_dsp_load_ev` 收到 event=2）|
| 主线 | PRE_PMU（上电**之前**，`cs35l41_dsp_preload_ev`）|

已按原厂改：给 `Main AMP` widget 增加 `SND_SOC_DAPM_POST_PMU`，
在 `cs35l41_main_amp_event()` 的 POST_PMU 里调用 `wm_adsp_event()`。

结果：

```
DSPLOAD loading fw at POST_PMU
DSPLOAD wm_adsp_event failed: -5 (non-fatal)
```

错误从 `-110`（写 DSP 内存 I2C 超时）变成 `-5`（EIO，`cs_dsp_run` 失败），
说明时机确实对了，但 **DSP 核仍然起不来**。

已把失败改成**非致命**（`ret = 0`），否则 DAPM 会回滚、连播放都起不来。
r3.35 实测：`aplay` 退出码 0、系统 0 失败单元，只是仍然没有声音。

### 结论（本阶段）

功放、供电、时钟、DSP→功放的数据通路全部已验证正常，
**唯一缺口是 CS35L41 内部保护 DSP 无法引导**。要特底解决需要：

- 复刻原厂 ADSP 侧的引导（私有命令，模块里 `cs35l41_set_csplmboxcmd` 等），或
- 给芯片提供板上没有的常驻 MCLK，或
- 找到让功放在"DSP 未运行"时也放行输出的配置（保护策略相关寄存器）

---

## 追加18：麦克风/采集通路打通到 DAPM，但数据仍为 0（2026-10-21 21:00）

### 一路排查下来搞清的采集链路

```
FE "MultiMedia1 Mixer"   （控件 'MultiMedia1 Mixer SLIMBUS_0_TX' = 1）
  → BE "Slimbus Capture" （slimcap-dai-link：cpu=SLIMBUS_0_TX / codec=AIF1_CAP）
    → codec "AIF1 Capture"
      → "CDC_IF TX0 MUX"  ★ 必须选 DEC0（默认是 RX_MIX_TX0 → 录出来全 0）
        → "ADC MUX0"      ★ 选 AMIC 或 DMIC
          → "AMIC MUX0"   ★ 必须选 ADC1（默认 ADC4 → 链路断）
            → "ADC1" → "AMIC1" → "MIC BIAS1"
```

其中 **`ADC1` 的供电在 codec 驱动里写死依赖 `AMIC1`**：

```c
{ "ADC1", NULL, "AMIC1" }
```

但我们的 DT 只给 AMIC2/3/4 配了偏置 → 已补上：
`dts/cepheus-cam-ir-nfc.dtsi` 的 `audio-routing` 增加 `"AMIC1", "MIC BIAS1"`。

### 现在的状态

录音时 DAPM 全绿：

```
MIC BIAS1: On   AMIC1: On   ADC1: On   AMIC MUX0: On   ADC MUX0: On
```

**但录到的样本仍然全是 0**（峰值 0）。所以问题已经不在 codec 的模拟/数字前端，
而在 **SLIMbus TX 数据面**：codec 没把数据送到 AFE 期望的通道上。

### 下次接着查

- AFE 侧收到的 TX 通道是 `map=128,129,130,131`（`SLIMDBG id=3`）
- 对照 codec 的 `wcd934x_tx_chs` / `wcd934x_set_channel_map()` 是否一致
- 以及 `qcom,slim-ngd` 的 TX 端口是否真的在收发（`SLIM SAT` 日志、
  `command[0x10bdb] not expecting rsp` 这类可疑响应）

### 采集用的手动配置（还没进开机服务）

```sh
amixer -c 0 cset name='MultiMedia1 Mixer SLIMBUS_0_TX' 1
amixer -c 0 cset name='CDC_IF TX0 MUX' DEC0
amixer -c 0 cset name='ADC MUX0' AMIC
amixer -c 0 cset name='AMIC MUX0' ADC1
amixer -c 0 cset name='ADC1 Volume' 100%
amixer -c 0 cset name='DEC0 Volume' 100%
```

---

## 追加19：采集又挖出两个坑（2026-10-21 21:30）

### 坑 1：还有一个隐藏开关 `SLIM TX0`

wcd934x 里 SLIMbus TX 端口是单独的 `SOC_SINGLE_EXT("SLIM TX0", ...)`，
它不只是开关，还负责把该端口登记到 `slim_ch_list`（通道列表）。
只设 `CDC_IF TX0 MUX` 是不够的，必须：

```sh
amixer -c 0 cset name='SLIM TX0' 1
```

打开后整条链路才真正全 On：

```
SLIM TX0: On  AIF1_CAP Mixer: On  MIC BIAS1: On  AMIC1: On  ADC1: On
```

### 坑 2：`wcd934x_set_channel_map()` 拒绝 NULL 槽位

```c
if (!tx_slot || !rx_slot)
        return -EINVAL;      /* 采集时我们只传 tx，rx 传了 NULL → 永远失败 */
```

这个错误被 `sm8150_slim_snd_hw_params()` 里的 `pr_err` 埋掉了，加打印才看到
`codec set_channel_map failed: -22`。

改成 `set_channel_map(codec_dai, tx_cnt, tx_ch, 1, rx_dummy)` 后不再报错，
**但采集进程立刻卡在 `D` 状态**（不可中断睡眠），甚至阻塞了后续 `reboot`。

### 结论：SLIMbus 通道必须由框架分配，不能硬填

强塞 128/129（或 0/1）都会让 SLIMbus 侧等一个永远不会来的 ACK。
正确做法应该是用 `slim-ngd` / SLIMbus 框架分配出来的通道号
（`slim_stream_alloc`），而不是写死。

已把 `slim_tx_ch_base` 默认改成 **-1（不覆盖）**，避免再卡死；
r3.38 镜像已包含该默认值。

### 下次要查

- mainline `wcd934x` 是否实现了 SLIMbus 通道申请（`slim_stream_alloc`）
- `qcom,slim-ngd-ctrl` 分配了哪些通道（`SLIM SAT` 日志 / `slim_stream` debugfs）
- 把框架分配到的通道号透传给 codec 的 `set_channel_map`

---

## 追加20：SLIMbus 通道必须由框架分配（2026-10-21 21:50）

### 又挖到一层：`wcd934x_slim_set_hw_params()` 用不到通道

```c
	list_for_each_entry(ch, slim_ch_list, list) {   /* ← 列表此时是空的 */
		cfg->ch_count++;
		payload |= 1 << ch->shift;
	}
	...
	cfg->chs = kcalloc(cfg->ch_count, ...);         /* ch_count=0 */
```

`slim_ch_list` 要等 DAPM 上电（`SLIM TX0` 的 put 回调）才登记，
而 `hw_params` 比它早 → `ch_count=0` → **端口寄存器根本没写 payload** →
codec 一个采样都不发（录出来全 0）。

已在 `wcd934x.c` 加退化路径（`SLIMFB` 日志）：列表为空时用
`slim_set_channel_map()` 设进来的通道号自己建配置并写端口寄存器。

### 但强行给通道号会让 SLIMbus 卡死

实测（`kernelfat` r3.39，`slim_tx_ch_base=128`）：

```
arecord → 进程进入 D 状态（不可中断），kill -9 无效，
          并且后续 reboot 也被阻塞，只能长按电源强制重启
```

说明 128/129 这两个通道**在 SLIMbus 上并不存在**（没有经过
`slim_stream_prepare()` → `slim_alloc_chan()` 的分配）。

### 结论

通道号必须来自 **SLIMbus 框架的分配结果**，不能凭空指定。
下次的方向：

1. 在 `wcd934x_trigger` 的 `slim_stream_prepare()` 之后，把框架实际分配的
   `sruntime->ch[]` 读出来，反写进 codec 的端口寄存器
2. 或者让 AFE 侧使用与 codec 相同的通道（需要先知道框架分了哪些）
3. 检查 `slim-ngd` 的 `slim_stream` debugfs / `SLIM SAT` 日志

`slim_tx_ch_base` 默认已恢复 **-1**（不覆盖），避免再卡死系统。

---

## 追加21：采集卡死的真正位置 —— SLIMbus 寄存器访问被 ADSP 挡住（2026-10-21 22:20）

### 定位过程

r3.40 里加了 `slim_skip_stream=1`（跳过 `slim_stream_prepare/enable`），
确认卡死**不在**框架的流准备，而在 codec 一侧：

`dmesg` 最后一条是机器驱动的 `SLIMCHDBG capture ch_cnt=2 base=128`，
之后**没有任何日志**（连我们退化路径的 `SLIMFB` 都没打印），
说明卡在紧接着的 `wcd934x_slim_set_hw_params()` 里 —— 也就是那一串
`regmap_write(wcd->if_regmap, WCD934X_SLIM_PGD_TX_PORT_*, ...)`。

这些是**通过 SLIMbus 访问 codec 接口设备的寄存器**，在
`qcom,slim-ngd`（卫星控制器，主控是 ADSP）上会**不可中断阻塞**
（进程进 D 状态，连 `reboot` 都被挡住，只能长按电源）。

### 结论

- 只要打开 `SLIM TX0`（把 TX 端口登记进 `slim_ch_list`），
  `ch_count` 就变成非 0，随后就会去写 codec 的 SLIM 端口寄存器 → 卡死
- 不开 `SLIM TX0` 则 `ch_count=0`，不写寄存器 → 不卡，但录到全 0

也就是说：**在 ADSP 掌管 SLIMbus 的这个平台上，Linux 侧无法编程 codec 的
采集端口**。通道分配和端口配置本该由 ADSP 完成（原厂就是这么做的）。

### 下一步方向（供以后）

1. 不再由 Linux 配 codec 端口，改为让 **ADSP** 配置（需要 ADSP 侧的
   "SLIMbus port mapping" 命令，主线的 q6afe SLIM 配置里没有这部分）
2. 或者确认 ADSP 是否已把 codec 的 TX 端口配好、只是通道号与 AFE 不一致
   （可在 AFE 侧改 `SLIMBUS_0_TX` 的 `ch_mapping` 去试）
3. 若都不行，麦克风在主线短期内难通；可用 USB 麦克风替代

### 安全默认值（已固化）

- `slim_tx_ch_base = -1`（不覆盖通道）
- `slim_skip_stream` 默认为 1（不调用会阻塞的框架流准备）
- **注意：仍然不要在采集前打开 `SLIM TX0`**，否则会卡死系统
