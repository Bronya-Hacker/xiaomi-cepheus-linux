# NFC（NXP SN100U）

## 硬件

- 芯片：**NXP SN100U**（NFC 控制器 + eSE）
- 总线：i2c9（主线 `i2c@a84000`，与原厂 `i2c@a84000` 一致）
- 地址：`0x28`
- 引脚：IRQ=GPIO47，VEN(EN)=GPIO103，FIRM(GPIO48)，CLKREQ=GPIO113

原厂在 vendor 分区里带了一整套 NXP HAL 资源（可见是 SN100U）：

```
/mnt/vendor/etc/sn100u_bootup.pnscr          ← 上电后要执行的 NCI 脚本
/mnt/vendor/etc/libnfc-qrd-SN100.conf
/mnt/vendor/lib64/nfc_nci.nqx.default.hw.so
```

## 已做到（2026-10-22 00:40）

| 项目 | 状态 |
|---|---|
| 驱动绑定 | ✅ `nxp-nci-i2c` 已绑定到 `1-0028`，`/sys/class/nfc/nfc0` 存在 |
| 内核配置 | ✅ `CONFIG_NFC` / `NFC_NCI` / `NFC_NXP_NCI(_I2C)` = m |
| 用户态工具 | ✅ 自己写了 `tools/nfc-poll-netlink.c`（走 NFC generic netlink：DEV_UP → START_POLL → GET_TARGET） |
| **CLKREQ 引脚** | ✅ **已修**：原厂把 GPIO113 配成 `bias-pull-up` 输入，我们原来完全没配 → 悬空 → I2C 无应答（-121）。补上后芯片**开始应答 I2C** |
| I2C 探测 | ✅ EN 拉高后 `i2cdetect` 能看到 `0x28` |
| NCI 写入 | ✅ 第一次写会失败，之后可写（原厂脚本也是"连发 CORE_RESET 冲缓冲"） |
| NCI 读取 | ❌ **读回全是 0x00**，没有 `CORE_RESET_NTF` |
| 发现卡片 | ❌ `DEV_UP` 仍超时 |

## 结论与下一步

芯片供电/总线/使能都通了，但**NCI 核没有真正响应**（读全 0、无 CORE_RESET_NTF）。
这通常意味着：

1. **需要跑原厂的上电脚本**：`sn100u_bootup.pnscr` 是一串 NCI 命令
   （`reset 1` / `interval 50` / 多条 `send 20000100` 即 CORE_RESET_CMD …）。
   原厂 HAL 在 CORE_RESET 之后会把这个脚本逐条发给芯片完成初始化。
   → 下一步：写个脚本解析 `.pnscr` 并逐条发送，看能否拿到响应。
2. **参考时钟**：`libnfc-qrd-SN100.conf` 里 `NXP_SYS_CLK_SRC_SEL=0x02`(PLL)、
   `CLK_FREQ_19_2MHZ`，说明芯片需要外部参考时钟。若板上时钟由 PMIC 门控、
   而 mainline 没有打开，芯片可能起不来。需要确认 NFC 时钟来源。

## 工具

`tools/nfc-poll-netlink.c`：gcc 直接编译，`./nfc-poll-netlink 30` 轮询 30 秒。
依赖 NFC generic netlink（主线 NCI 不暴露字符设备）。

## 调试技巧

- 驱动绑定后 `i2cdetect` 会显示 `UU`（被占用）；要直接探测得先解绑：
  `echo 1-0028 > /sys/bus/i2c/drivers/nxp-nci_i2c/unbind`
- 解绑后芯片默认断电（EN 低）；用 `gpioset -m time -s 20 gpiochip3 103=1` 手动给 EN
- NXP NCI 的读是**纯 I2C 读**（不带寄存器地址）：`i2ctransfer -y 1 r3@0x28`

---

## 追加：时钟与 FIRM 引脚试验（2026-10-22 00:35）

### 做了什么

1. 给 `nxp-nci-i2c` 驱动打了补丁：按 DT 取 `nfc_clk` 并 `clk_prepare_enable()`
   （见下面"内核补丁"），并在 NFC 节点加：

   ```dts
   clocks = <&rpmhcc RPMH_LN_BB_CLK3>;   /* PMIC ln_bb_clk3 = 19.2MHz */
   clock-names = "nfc_clk";
   ```

   实测生效：`ln_bb_clk3 rate=19200000 enable=1`，
   dmesg 有 `NFC: nfc_clk enabled at 19200000 Hz`。
   （19.2MHz 正好对上 `libnfc-qrd-SN100.conf` 里的 `CLK_FREQ_19_2MHZ`）

2. 也写了 `tools/nci-script.c`：解析原厂 `sn100u_bootup.pnscr`
   并逐条发送 NCI 命令（原厂 HAL 就是这么初始化的）。

### 结果：仍然没有 NCI 响应

| 试验 | 结果 |
|---|---|
| 时钟使能后 `DEV_UP` | ❌ 仍超时（read -121） |
| 解绑后手动 EN=1 + 写 CORE_RESET | 写成功，**读回全 0x00** |
| FIRM(48)=0 / FIRM=1（正常/下载模式） | 都读回全 0x00 |
| CLKREQ(113) 电平 | 一直为 **0**（芯片在请求时钟？还是线路问题） |

### 下一步排查方向

1. **确认 NFC 的参考时钟到底来自哪**：`ln_bb_clk3` 打开后 CLKREQ 仍为 0，
   说明时钟可能没真正走到 NFC（也许该用 `ln_bb_clk1`，或 PMIC 的 div_clk，
   而后者在当前 DT 里根本没有节点）。
2. **回放 `sn100u_bootup.pnscr`**：需要在芯片能响应写的状态下做；目前写能过但无应答。
3. 用示波器量 NFC 的 26/19.2MHz 时钟脚最直接（用户暂时没有）。

### 内核补丁（不在仓库里，需手动应用）

`drivers/nfc/nxp-nci/i2c.c`：

```c
#include <linux/clk.h>
...
	struct gpio_desc *gpiod_fw;
	struct clk *nfc_clk;          /* 新增 */
...
	phy->nfc_clk = devm_clk_get_optional(dev, "nfc_clk");
	if (IS_ERR(phy->nfc_clk))
		return PTR_ERR(phy->nfc_clk);
	if (phy->nfc_clk) {
		r = clk_prepare_enable(phy->nfc_clk);
		if (r)
			return r;
		nfc_info(dev, "nfc_clk enabled at %lu Hz\n", clk_get_rate(phy->nfc_clk));
	}
```

### 当前设备状态

- r3.46，NFC 驱动绑定正常、`nfc0` 存在、时钟已使能
- 仍未读到任何卡

---

## 追加：DIV_CLK1 试验（2026-10-22 00:45）

`RPMH_DIV_CLK1`（很多平台用作 NFC 19.2M 时钟源）在本平台**不可用** ——
`rpmhcc` 没有提供它，`devm_clk_get_optional("nfc_clk")` 直接返回 NULL，
dmesg 里没有 `nfc_clk enabled`，`/sys/kernel/debug/clk/` 里也没有 `div_clk1`。

所以 DT 里的 `clocks` 回退为 `RPMH_LN_BB_CLK3`（19.2MHz，实测能启用）。

结论：**目前能确认可用的、频率也对得上的只有 ln_bb_clk3**，
但启用它之后 SN100U 的 NCI 核仍然不响应（读回全 0）。

要真正确定 NFC 的时钟来源，最直接是：
- 有示波器量芯片的 CLK 脚；或
- 从 vendor 内核模块/ADSP 配置里找 NFC 时钟的使能路径。
