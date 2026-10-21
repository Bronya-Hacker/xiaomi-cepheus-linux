# 厂商内核源码（对比用）

本目录存放从 Qualcomm techpack 抓下来的 wcd934x 编解码器驱动片段，
用来和主线 `sound/soc/codecs/wcd934x.c` 对比，找出主线缺失的初始化序列。

## 怎么下的

`raw.githubusercontent.com` 在国内不通，**但 ghproxy 可以**：

```powershell
Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 `
  -Uri 'https://ghproxy.net/https://raw.githubusercontent.com/LineageOS/android_kernel_xiaomi_sm8150/lineage-22.2/techpack/audio/asoc/codecs/wcd934x/wcd934x.c' `
  -OutFile vendor-wcd934x.c
```

（352871 字节，11381 行；`gh-proxy.com` 同样可用）

## 已确认的差异（截至 2026-10-22 04:40）

| 项目 | 厂商 | 主线 | 是否已排除 |
|---|---|---|---|
| TX 静音位 | `TX_VOL_CTL` bit4 (0x10)：PRE_PMD 置位、延迟工作队列里清除 | **没有静音/取消静音逻辑** | 已试写 bit4=0，仍为 0 → 不是根因 |
| DEC 电源档位 HP/LP/DF | `DEC_PWR_LVL_MASK` 按 AMIC 档位设置 | 有 | 一致 |
| ADC 使能 | `tavil_codec_enable_adc` = 只设 tx_hold | 同上 | 一致 |
| DMIC 时钟 | `CPE_SS_DMIC*_CTL` + 引用计数 | 有 | 一致 |
| DEC 使能 | `tavil_codec_enable_dec` | 有，逐段比对基本一致 | 待继续 |

## 尚未比对的

- `tavil_codec_set_i2s_tx_ch` / SLIM 端口相关（我们走 SLIM，已证明通路 OK）
- `tavil_codec_enable_anc`（回声参考路，可能影响 mic 供电）
- 上电顺序：厂商在 `tavil_codec_enable_dec` PRE_PMU 里还会读 AMIC 电源档位，
  若档位读错可能设成 LP（低功耗）而听起来像没数据
