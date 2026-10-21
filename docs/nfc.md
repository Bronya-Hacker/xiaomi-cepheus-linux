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

---

## 追加：100kHz / 上电时序 / 读行为全面排查（2026-10-22 01:05）

| 试验 | 结果 |
|---|---|
| i2c 降到 **100kHz** | 仍读回全 0（速率不是原因） |
| 确认总线对应关系 | `i2c-1 = a84000.i2c` ✅ 就是 i2c9，没搞错总线 |
| EN 低→高 + 静置 0.5/1/2/4/8s | 读都成功但**恒为 0x00** |
| 连发 CORE_RESET ×4 后连读 10 次 | 全 0x00 |
| 写操作 | 一直"成功"（I2C 无错误） |

### 关键观察

读操作**不报错**、但数据恒为 `0x00`。正常 NCI 芯片"无数据"时应该是 NAK 或 0xFF。
恒 0 说明 **MISO 被拉低 / 芯片核心在跑但无输出**。

最可能的解释：**芯片的 VBAT 主供电没上**（只有 VEN 控制的 IO 电在），
所以 I2C 从机地址能应答，但 NCI 核不运行。

vendor DT 的 NFC 节点**没有任何 supply 属性**，说明这路电由 bootloader 或
vendor 内核别处控制；主线里我们没找到对应 regulator。

### 结论

纯软件层面已无手段。需要：
1. 原理图/PCB 点测 NFC 的 VBAT、CLK、VEN、FIRM 四条线；或
2. 小米内核源码里 NFC 的供电/时钟初始化代码。

### 当前状态（保留的改动）

- `&i2c9 { clock-frequency = <100000>; }`（无害，保留）
- NFC 节点：`clocks = <&rpmhcc RPMH_LN_BB_CLK3>`、`nfc_clk`
- 驱动：`nxp-nci-i2c` 支持可选 `nfc_clk`
- 工具：`tools/nfc-poll-netlink.c`、`tools/nci-script.c`

---

## 追加：拿到厂商 NFC 驱动 + 修好 PMIC 时钟链路（2026-10-22 06:25）

### 设备是有反应的，问题在时钟

用厂商的上电时序（`nfcc_hw_check`）测试：

```
VEN=1 →10ms→ VEN=0 →10ms→ VEN=1 →10ms→ CORE_RESET(20 00 01 00)
```

- 芯片 A**CK 地址 0x28**（i2cdetect 能看到）
- 写入**成功**（无 I2C 错误）
- 但读取**恒为 0x00**，任何长度都是
- **CLKREQ(GPIO113)**：VEN 关时浮空=1，VEN 开时芯片主动拉低=**0（在请求时钟）**

→ 结论：芯片 I2C 从机能应答（由 SCL 驱动），但核心没跑起来 —— **参考时钟没到**。

### 修掉的三个真实缺陷

**1. 主线 DT 完全没有 PMIC 时钟分频器节点**

原厂有三个 `qcom,spmi-clkdiv`：

```
PM8150  clock-controller@5b00  reg<0x5b00 0x200>  num-clkdivs=2  → div_clk1/2
PM8150B clock-controller@5b00  reg<0x5b00 0x100>  num-clkdivs=1
PM8150L clock-controller@5b00  reg<0x5b00 0x100>  num-clkdivs=1
```

主线 `pm8150.dtsi` 里**一个都没有**。已补进板级 dtsi：

```dts
&pm8150_0 {
	pm8150_clkdiv: clock-controller@5b00 {
		compatible = "qcom,spmi-clkdiv";
		reg = <0x5b00 0x200>;
		#clock-cells = <1>;
		qcom,num-clkdivs = <2>;
		clock-output-names = "pm8150_div_clk1", "pm8150_div_clk2";
		clocks = <&rpmhcc RPMH_CXO_CLK>;
		clock-names = "xo";
	};
};
```

**2. `CONFIG_SPMI_PMIC_CLKDIV` 没编译**

```
# CONFIG_SPMI_PMIC_CLKDIV is not set
```
驱动在树里（`drivers/clk/qcom/clk-spmi-pmic-div.c`）但没启用。已改为 `=y`。

**3. clkdiv 索引是 1 基的，且默认频率极低**

- `clocks = <&pm8150_clkdiv 0>` 非法，驱动报
  `index value 0 is invalid; allowed range [1, 2]` → 要用 **1**
- 默认 rate 只有 **300kHz**，驱动里必须先 `clk_set_rate(19200000)` 再使能

修完后实测：

```
div_clk1  rate=19200000  enable=1   ← PMIC 的 NFC 候选时钟，真的在跑了
div_clk2  rate=19200000  enable=1
dmesg: nfc_clk set to 19200000 Hz / nfc_clk enabled
```

### 但 CLKREQ 仍是 0、读取仍是 0

说明 `div_clk1/div_clk2` **不是** NFC 的时钟源（或者还有别的门控）。

PM8150L 的那路分频器因**名字冲突**注册失败：

```
failed to register clk 'div_clk1' (-EEXIST)
```

驱动按 `div_clk%d` 硬编码命名，两个 PMIC 撞名 → 需要改驱动让它用
`clock-output-names`，才能测 PM8150L 那一路。

### 下一步

1. 改 `clk-spmi-pmic-div.c` 用 DT 的 `clock-output-names` 命名（解决撞名），
   然后测 PM8150L div_clk1
2. 若仍不行，怀疑 NFC 时钟来自别处（SoC 内部无 NFC 时钟，也可能由
   bootloader 直接配置 PMIC 的某一路而 Linux 看不到）

### 顺带确认

`/sys/class/gpio` 没编进内核（用 `gpioset` 的 GPIO v2 uAPI 代替），
写了个 `tools/nfc-pulse.c` 可以精确做 VEN 脉冲 + 发 NCI 命令。

### 追加：三路 PMIC 分频时钟全部跑起来了（06:35）

修掉 clkdiv 驱动的**命名冲突**（硬编码 `div_clk%d`，PM8150 与 PM8150L 撞名
导致第二个 `-EEXIST` 注册失败），改为优先使用 DT 的 `clock-output-names`。

现在：

```
pm8150_div_clk1    rate=19200000  enable=1
pm8150_div_clk2    rate=19200000  enable=1
pm8150l_div_clk1   rate=300000    enable=0   ← 这路设不上 19.2MHz
```

NFC 驱动依次把它们都挂上（`nfc_clk` / `nfc_clk2` / `nfc_clk3`）。

**但芯片仍然：ACK 地址、接受写入、IRQ 会响应，读恒为 0。**

### 当前的确定与不确定

**确定：**

- 芯片有电（I2C 从机能应答 0x28）
- 芯片对 CORE_RESET 有反应（IRQ 从 0 变 1）
- 无论等 10ms / 100ms / 500ms / 1s，读都返回全 0
- 无论读 1/3/6/10/12/16/32 字节，都是全 0
- `CLKREQ` 在 VEN 高时被芯片主动拉低（=0）

**不确定：**

- `CLKREQ=0` 到底是"请求时钟"还是"时钟就绪"（极性未确认）
- 若是"请求时钟"，那三路 PMIC 分频器都不是它要的那一路
- 芯片是否处于固件下载模式（该模式读协议不同）

### 下一步（若继续）

1. 用**示波器/逻辑分析仪**量 NFC 的 CLK 脚最直接 —— 能立刻区分上面两种情况
2. 或反汇编 vendor 的 `nfc_nci.nqx.default.hw.so`（HAL），看它读之前做了哪些
   额外步骤（比如先写某个 vendor 命令把芯片唤醒）
3. 或接受现状：NFC 在主线暂时不通

### 本轮修复的真实缺陷汇总

| # | 缺陷 |
|---|---|
| 1 | DT 缺少 PMIC `qcom,spmi-clkdiv` 节点（原厂有 3 个，主线 0 个） |
| 2 | `CONFIG_SPMI_PMIC_CLKDIV` 没编译 |
| 3 | clkdiv 索引是 1 基的（0 被拒） |
| 4 | clkdiv 默认 300kHz，必须先设 19.2MHz |
| 5 | clkdiv 驱动硬编码名字导致 PM8150/PM8150L 撞名 |

---

# ★★★ NFC 打通了！（2026-10-22 07:40）

```
$ ./nfc-devup up 0
内核确认成功                     ← NCI 初始化完成
$ ./nfc-devup poll 0
轮询已启动                       ← RF 发现已开始
$ dmesg | grep -i nfc
（无任何错误）
```

## 真正的根因：读事务方式 + 包间填充字节

怀疑了几轮时钟之后，用逐字节试探终于把协议搞清楚了：

### 1. 纯 I2C 读拿不到数据

```
i2ctransfer r13@0x28                → 00 00 00 00 ...   （永远全 0）
i2ctransfer w2@0x28 00 00 r13@0x28  → 40 00 01 00 ff 60 00 0a ...  ✅
```

**必须先写 2 个字节（内容无关）再在同一事务里读。** 这是 SM8150 的
Geni I2C 控制器对这颗芯片的行为差异。

### 2. 那"5 字节前缀"其实是 CORE_RESET_RSP

一开始以为是固定前缀就跳了 5 字节 —— 结果把 RSP 吃掉，后面全乱。
真实的数据流是**连续的字节流，包之间有一个 0xFF 填充字节**：

```
40 00 01 | 00 | ff | 60 00 0a 02 00 20 04 05 00 a4 01 10 07
RSP 头    负载  填充  NTF 头     NTF 负载
```

`0xFF` 是总线空闲值（芯片没更多数据时读到的就是 1）。

### 3. 芯片其实一直是好的

决定性实验：

| 发送内容 | IRQ 反应 |
|---|---|
| 垃圾 `FF FF FF FF` | 保持低（不响应） |
| 合法 `CORE_RESET` | 拉高（处理了） |

芯片**完整解析 NCI 协议**，核心一直在运行。

### 4. 需要厂商的上电复位脉冲

厂商 `nfcc_hw_check()` 不是简单把 EN 拉高，而是：

```c
EN=1 → 10ms → EN=0 → 10ms → EN=1 → 10ms
```

少了这个脉冲，第二次初始化就 NAK（`Read failed with error -121`）。

## 驱动改动（sound/…/drivers/nfc/nxp-nci/i2c.c）

1. 新增 `nxp_nci_i2c_raw()`：写 2 字节 + 同事务读，失败重试 10 次
2. 新增环形缓冲 `rx_ring[320]`：按需填充，**每个包开头跳过 0xFF 填充**
3. `nxp_nci_i2c_recv(phy, buf, len, packet_start)`：从环形缓冲取数
4. `set_mode()` 加 VEN 复位脉冲
5. 保留 `nfc_clk` / `nfc_clk2` / `nfc_clk3` 三路时钟使能

## 工具

`tools/nfc-devup.c` —— 通过 NFC netlink 控制设备：

```
./nfc-devup up 0      # 上电 + NCI 初始化
./nfc-devup poll 0    # 启动 RF 轮询找卡
./nfc-devup down 0
```

注意：`NFC_ATTR_RF_MODE` 必须是 **u8**（不是 u32），否则内核报
`attribute type 11 has an invalid length`。

## 已知遗留

- **每次开机只能初始化一次**：DEV_DOWN 之后再 UP 仍会超时
  （芯片需要在两次之间做完整掉电，可能要 CNTRL 时序调整）
- 还没验证实际读卡（需要监听 `NFC_CMD_TARGET_FOUND` 事件，或装 libnfc）

### 工具完善：监听找卡事件

`tools/nfc-devup.c` 现在支持：

```
./nfc-devup up 0      # 上电 + NCI 初始化（每次开机第一次有效）
./nfc-devup poll 0    # 启动 RF 轮询
./nfc-devup listen    # 订阅 nfc 多播组，打印内核推来的事件
```

要点：

- `NFC_ATTR_RF_MODE` 必须是 **u8**，否则内核报
  `attribute type 11 has an invalid length`
- nfc 多播组 id 是 **9**（不是 1），要解析 `CTRL_ATTR_MCAST_GROUPS`
  嵌套属性拿 `CTRL_ATTR_MCAST_GRP_ID`；`nl_groups` 要设 `1 << (id-1)`
- **必须用一个独立的 socket 订阅**：已经 `sendto` 过的 socket 再 `bind`
  会返回 `EINVAL`
- `/sys/kernel/debug/dynamic_debug/control` 没编进内核，所以开不了
  nci/nxp_nci 的动态调试，找卡只能靠 netlink 事件

实测：`内核确认成功` → `轮询已启动` → 监听正常绑定（组 9），
但还没抓到实际找卡事件（需要贴卡验证）。

---

# ★★★★ 实卡验证成功（2026-10-22 07:50）

贴卡实测，两次都收到了内核事件：

```
$ ./nfc-devup listen
找到多播组 id=9
轮询已启动
开始监听 NFC 事件 30 秒...
>>> NFC 事件 cmd=9 len=28          ← NFC_CMD_TARGET_FOUND
    attr type=1 len=4 data: 00 00 00 00
```

`NFC_CMD_TARGET_FOUND = 9`，说明：

- 芯片上电、NCI 初始化完成
- RF 轮询在跑，射频场已开启
- **实际检测到卡片**，内核 NFC 栈收到并广播了事件

至此小米9（cepheus）在主线 Linux 上的 NFC 从
「完全没反应、读回全 0」到「能初始化、能轮询、能识别卡片」全部打通。

## 使用方式

```sh
/root/nfc-devup up 0      # 上电 + NCI 初始化（每次开机第一次有效）
/root/nfc-devup poll 0    # 启动 RF 轮询
/root/nfc-devup listen    # 订阅事件（会自动重启轮询，便于现场抓卡）
```

贴卡后 `listen` 会打印 `cmd=9`（TARGET_FOUND）。

## 遗留

1. **每次开机只能初始化一次**：`DEV_DOWN` 后再 `DEV_UP` 仍超时。
   芯片需要在两次之间做完整掉电（可能要在 set_mode 里拉长 ULPM 时间，
   或在 DOWN 时把 EN 拉到低电平并等待）。
2. 事件里没有 target 详情（UID/协议）—— 主线 `nfc_targets_found()` 只发
   设备索引，不携带 target 属性。要读卡号需要走 LLCP/raw 通路
   （用 libnfc 或直接发 RF 命令）。
3. 还没做成开机自启服务 + 应用层读卡工具。
