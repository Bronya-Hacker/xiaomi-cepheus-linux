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