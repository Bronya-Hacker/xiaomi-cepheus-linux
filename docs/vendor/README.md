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

---

## 第二轮比对结论（2026-10-22 04:50）

### 逐项比对结果：驱动层已确认等价

| 项目 | 厂商 | 主线 | 结论 |
|---|---|---|---|
| `ADC1-4` widget | `DAPM_ADC_E("ADC3", NULL, ANA_AMIC3, 7, ...)` | 完全相同 | ✅ 一致 |
| `ADC MUX0-8` | `MUX_E(..., TX0_TX_PATH_CTL, 5, ...)` | 完全相同 | ✅ 一致 |
| `AMIC MUX0-8` | enum 写 `TX_INP_MUX_ADC_MUX0_CFG0` 位 0-2 | 完全相同 | ✅ 一致 |
| `DEC 电源档位` | 按 AMIC 档位设 LP/HP/DF | 有 | ✅ 一致 |
| `enable_dec` POST_PMU | HPF + 应用增益 | 有 | ✅ 一致 |
| TX 静音位 | PRE_PMU 置位、延迟队列清除 | **缺失** | ⚠️ 已实测，非根因 |
| `SLIM TX0-13` mixer | `MIXER("SLIM TX0", NOPM, ...)` | 有 | ✅ 一致 |

### 实测数据补充

- 采集时 `0x0d1d`（AMIC MUX0 选择）= **0x0b** → 低 3 位 = 3 = ADC3 ✅ 选择正确
- `0x0d3a`（TX 端口路由）= **0x02** → 端口接到 DEC0 ✅
- `0x0a31/32/33/34/39` 各值合理
- **声学实测**：音箱大音量放歌 + 手机录音 8 秒 → `nonzero=0, peak=0`（精确 0）

### 重要警告：debugfs 寄存器读值不可靠

同一配置下多次读取，`0x0a31` 读到过 `0x04` / `0x24`，`0x0a34` 读到过 `0x7c` / `0x10`，
`0x060e` 读到过 `0xb4` / `0x34`。说明 regmap debugfs 落在不同 bank，
**不能用它做寄存器状态的判断依据**。后续要读寄存器，应该在驱动里加 dev_info 打印。

### 下一步建议（按性价比排序）

1. **在驱动里打印真实寄存器**（`wcd934x_slim_set_hw_params` 里用 `regmap_read` + dev_info），
   替代不可靠的 debugfs，然后与厂商期望值对比
2. 比对 `tavil_codec_enable_micbias` vs `wcd934x_micbias_control`：
   厂商可能设了偏置电压/内部电荷泵，而主线只开了开关
3. 检查 `CLSH`（class-H）初始化：`tavil_codec_clsh_buck_ctrl` 之类，
   若模拟供电没真正起来，ADC 会输出硬 0
4. 实在不行：用 USB 声卡麦克风或蓝牙耳机麦（HFP），完全绕开 codec ADC
