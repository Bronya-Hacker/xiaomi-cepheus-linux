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
