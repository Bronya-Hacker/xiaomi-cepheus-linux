# WIP: camcc-sm8150（相机时钟控制器）

**状态（2026-10-20 更新）：M1 已达成 —— 真机跑通，96 个 cam_cc_* 全部注册、0 oops。**

旧状态：能编译，但一上真机就锁总线（2026-10-20，两次刷机两次靠 fastboot 救回）。
构建默认关闭（CONFIG_SM_CAMCC_8150 保持 n），不要直接启用。**

## 已有内容

- `camcc-sm8150.c`：从下游 `MiCode/Xiaomi_Kernel_OpenSource`（cepheus-q-oss）机械移植，
  已适配主线 6.17 的 `qcom_cc_really_probe(&dev, ...)`、`clk_alpha_pll_trion_ops`、
  去掉 vdd/msm-bus；96 个时钟 / 5 个 PLL 的寄存器表都保留。
- `qcom,camcc-sm8150.h`：时钟 ID 绑定（96 个）。
- 必需改动：Kconfig 加 `SM_CAMCC_8150`、Makefile 加 `camcc-sm8150.o`、
  匹配 `qcom,sm8150-camcc`（主线 sm8150.dtsi 里已有该节点）。

## 已验证的失败模式

1. 第一次：编进内核（=y）→ 开机即失联（USB/串口全无）。
   原因：探针里漏了 `cfg_ahb`（GCC_CAMERA_AHB_CLK）时钟就写寄存器。
2. 第二次：`cfg_ahb` 已加、desc 的 `.config` 补回、模块方式加载 →
   USB 网卡活着（ping 通）但 rootfs 没起来、串口无输出 = 总线锁死，不是 panic。

## 下一步（按顺序）

1. 确认 `ad00000.clock-controller` 为什么**没有挂到 MMCX 电源域**：
   设备上 `power/domain` 不存在，而 sm8250 的 camcc 是挂了的。
   对照 sm8250.dtsi 的节点：它有 `clock-names = "iface", "bi_tcxo", ...`，
   我们的 sm8150 节点没有 clock-names。
2. 加 `cfg_ahb` 之前先确认它真的 enable 成功（打印 `clk_get_rate`）。
3. 只做"读寄存器"的最小模块（ioremap + readl 0xad00000..0xad00010），
   确认读安全后再写 PLL。
4. 每次测试前：`dd if=/dev/sda28 of=/root/kernelfat-safe-*.img`，并确认能按到 fastboot。

## 救援

```powershell
fastboot flash recovery flash\cepheus-2026-10-19-wifi-3c3445-r3\recovery.img
fastboot reboot
```
