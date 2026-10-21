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
