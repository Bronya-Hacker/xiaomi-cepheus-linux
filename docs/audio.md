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
