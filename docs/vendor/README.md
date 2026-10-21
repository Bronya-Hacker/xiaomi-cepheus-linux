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

---

## 第三轮比对：发现主线缺失整张「寄存器默认值表」+ 内部 PLL（05:30）

### 厂商有一张 `tavil_codec_reg_defaults[]` 表，主线完全没有

```c
static const struct tavil_reg_mask_val tavil_codec_reg_defaults[] = {
	{WCD934X_BIAS_VBG_FINE_ADJ,    0xFF, 0x75},   /* 带隙基准微调 */
	{WCD934X_CODEC_CPR_SVS_CX_VDD, 0xFF, 0x7C},
	{WCD934X_CODEC_CPR_SVS2_CX_VDD,0xFF, 0x58},
	{WCD934X_CDC_RX*_RX_PATH_DSMDEM_CTL, 0x01, 0x01},
	{WCD934X_CDC_TX0..8_TX_PATH_CFG1, 0x01, 0x00}, /* 清 bit0 */
	{WCD934X_CDC_CLSH_DECAY_CTRL,  0x03, 0x00},
	{WCD934X_MICB1_TEST_CTL_2,     0x07, 0x01},
	{WCD934X_CDC_BOOST0/1_BOOST_CFG1, 0x3F, 0x12},
	{WCD934X_CODEC_RPM_CLK_MCLK_CFG, 0x04, 0x04},
	...
};
```

其中 10 条能映射到主线已定义的地址，已用 `dbg_writes` 整批写入测试
（含 `0x0629=0x75` 带隙基准、`0x5022/0x5023` CPR、`0x0a33` 的 bit0）
—— **仍为 0**。

### ★ 关键：codec 内部 PLL（CLK_SYS_INT）在主线里根本不存在

厂商表里还有一整套 PLL 配置（11 条，主线 `registers.h` 里没有这些寄存器定义）：

```
CLK_SYS_INT_POST_DIV_REG0 = 0x5E
CLK_SYS_INT_POST_DIV_REG1 = 0x1F
CLK_SYS_INT_REF_DIV_REG0  = 0x54
CLK_SYS_INT_REF_DIV_REG1  = 0x01
CLK_SYS_INT_PLL_L_VAL     = 0x93
CLK_SYS_INT_PLL_N_VAL     = 0xFA
CLK_SYS_INT_VCO_PROG      = 0xF8
CLK_SYS_INT_PFD_CP_DSM_PROG = 0x7E
CLK_SYS_INT_TEST_REG0     = 0x90
CLK_SYS_INT_FILTER_REG1   = 0x04
```

而且厂商在用 PLL 时会显式使能（`tavil_enable_native_supply`）：

```c
snd_soc_update_bits(codec, WCD934X_CLK_SYS_PLL_ENABLES, 0x01, 0x01);
snd_soc_update_bits(codec, WCD934X_CLK_SYS_MCLK2_PRG1,  0x06, 0x02);
snd_soc_update_bits(codec, WCD934X_CLK_SYS_MCLK2_PRG1,  0x01, 0x01);
snd_soc_update_bits(codec, WCD934X_CODEC_RPM_CLK_GATE,  0x04, 0x00);
snd_soc_update_bits(codec, WCD934X_CDC_CLK_RST_CTRL_MCLK_CONTROL, 0x02, 0x02);
snd_soc_update_bits(codec, WCD934X_CDC_CLK_RST_CTRL_FS_CNT_CONTROL,0x10, 0x10);
```

主线只有后三条（`CODEC_RPM_CLK_GATE`/`MCLK_CONTROL`/`FS_CNT_CONTROL`），
**`WCD934X_CLK_SYS_PLL_ENABLES` 在主线里完全没有定义**，PLL 从未使能。

### 这是目前最强的剩余嫌疑

如果 ADC/DEC 的时钟来自 codec 内部 PLL（而不是直接用 MCLK），
那么 PLL 没配置、没使能 → ADC/DEC 无时钟 → **输出精确 0**，与现象完全吻合。

### 下一步需要

- 厂商 `registers.h` 里 `WCD934X_CLK_SYS_INT_*` / `CLK_SYS_PLL_ENABLES` 的**地址**
  （GitHub API 被限流，raw 路径没试全；mainline 的 `registers.h` 里 0x0700-0x0710
  这段是空的，说明这些寄存器在主线里被裁掉了）
- 拿到地址后：先用 debugfs 读一遍确认身份，再用 `dbg_writes` 写 PLL 配置 +
  使能 bit，最后录音验证
