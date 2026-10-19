# 内置相机移植计划（SM8150 / cepheus）

> 目标：让小米9的**自带摄像头**在主线内核上出图，最终能当监控用。
> 结论先说：这不是调参，是从零补四个子系统。下面是把"要做什么"钉死的计划，
> 以及每个阶段的验收标准。**不要在没有 M1 的情况下承诺"能出图"**。

## 一、现状（2026-10-20 实测）

| 组件 | 主线状态 | 结论 |
|---|---|---|
| camss（CSID/VFE 框架） | 支持 msm8916/8953/8996/668/670/845/8250/8280xp/8550… | **没有 SM8150**（CAMSS 175） |
| CSIPHY | 有 3ph-1-0 / 2ph 等 | SM8150 是 `csiphy-v1.1`（下游 compatible） | 
| CCI（相机 i2c 控制器） | 有 `i2c-qcom-cci`，含 sm8250（cci_v2） | 大概率可直接用（待验证） |
| 相机时钟 camcc | **没有 camcc-sm8150 驱动**，gcc-sm8150 里也没有 CAM_CC | **头号阻塞** |
| 传感器驱动 | 树里没有 IMX586 / IMX481 / S5K3M5 / IMX471 | 四颗都要写/移植 |
| 设备树 | `sm8150.dtsi` 无 camss/csiphy/csid/cci 节点 | 要新写 |

## 二、硬件地图（从设备上的下游 DT 提取，`out/sde49-dump.img` 内的 FDT）

| 模块 | 地址 | 说明 |
|---|---|---|
| CCI0 / CCI1 | `0xac4a000` / `0xac4b000` | 两个 i2c master，驱动传感器 |
| CSIPHY0..3 | `0xac65000` / `0xac66000` / `0xac67000` / `0xac68000` | `qcom,csiphy-v1.1` |
| CSID0 / CSID1 | `0xacb3000` / `0xacba000` | `csid175`，各 0x1000 |
| VFE0 / VFE1 | `0xacaf000` / `0xacb6000` | `vfe175`，0x4000 + camnoc 0xac42000 |
| CSID-lite0/1 | `0xacc8000` … | `csid-lite175` |
| CAMNOC | `0xac42000` | VFE 的 cam_camnoc |
| MCLK | 24 MHz（0x124f800） | 每颗 sensor 一路 |
| 供电 | cam_vio / cam_vana / cam_vdig（PMIC） | 电压见下游 DT |

> 注意：这份 DT 是 **CDP 参考板**的（model=Cepheus 但 compatible 是 cdp），
> 板级接线（哪颗 sensor 接哪个 CSIPHY、i2c 地址、复位 GPIO）在小米的
> `cepheus-camera.dtsi` 里，需要用同样的方法从下游源码/DTS 取。

## 三、四个子工程与工作量

### M1 `camcc-sm8150` 时钟驱动（阻塞项，1–2 周）

下游 `drivers/clk/qcom/camcc-sm8150.c` 有 **67 KB / 128 个时钟 / 5 个 PLL**。
主线有 `camcc-sm8250.c` 可作模板，但寄存器表必须从下游逐个搬（没有公开文档）。
验收：`/sys/kernel/debug/clk/clk_summary` 里能看到 `cam_cc_*`，且能 enable 出
CSI PHY 的 `cphy_rx_clk_src`。

### M2 camss 175 资源表 + DT（2–4 周）

在 `camss.c` 里加 `sm8150_resources`（csiphy/csid/vfe 三张表 + icc 路径 +
`CAMSS_175` 版本号），DT 里补 camss/csiphy/csid/vfe/cci 节点。
验收：`dmesg` 里 camss probe 成功，`media-ctl -p` 能看到 CSIPHY→CSID→VFE 的实体图。

### M3 传感器驱动（每颗 1–2 周，先用主摄）

IMX586 主线没有。可以从下游 `techpack/camera` 的 sensor 模块搬初始化序列
（寄存器表 + PLL 表 + 模式表），改写成主线 `v4l2_subdev` + `media_entity` 风格。
验收：CCI 上 `i2cdetect` 能看到地址，读 chip id 正确，`v4l2-ctl --list-formats` 有 RAW10。

### M4 出流（1 周）

CSIPHY/CSID/VFE 打通，`v4l2-ctl --stream-mmap` 拿到 RAW Bayer 帧。
到这个阶段"能出图"但还不能直接看（Bayer）。

### M5 可用画面（1–2 周）

CPU 侧 debayer + 缩放（`libcamera` 的 software ISP 或自写），然后
`mjpg-streamer`/`motion` 出 JPEG/H.264 流。

## 四、现实评估

- **总计 2–3 个月**（不含 ISP 调优、不含四颗全做）；任何一步卡住都会更久。
- 最大风险是 **M1**：128 个时钟没有文档，只能对着下游代码逐个核对，
  错一个分频就会表现为"probe 成功但没数据"。
- 好消息：下游源码是公开的（`MiCode/Xiaomi_Kernel_OpenSource`，分支
  `cepheus-q-oss`），camcc/camss/传感器初始化序列都能拿到，不是纯逆向。

## 五、克隆/取文件（不要整仓 clone，5.7 GB）

按需取单个文件（实测 gh-proxy 很快，67 KB 不到 1 秒）：

```bash
curl -sSL -o camcc-sm8150.c \
  https://gh-proxy.com/https://raw.githubusercontent.com/MiCode/Xiaomi_Kernel_OpenSource/cepheus-q-oss/drivers/clk/qcom/camcc-sm8150.c
```

已知有用的路径：

| 内容 | 路径 |
|---|---|
| 相机时钟 | `drivers/clk/qcom/camcc-sm8150.c` |
| camera 驱动栈 | `techpack/camera/drivers/...` |
| 板级 DTS | `arch/arm64/boot/dts/vendor/qcom/`（cepheus*.dtsi） |

## 六、如果监控是硬需求

在这套东西打通之前，设备侧有两条零成本/低成本路线，别让监控等驱动：

1. **USB UVC 摄像头**：内核里 `CONFIG_USB_VIDEO_CLASS=m` 已经开了；缺的是
   host 模式（`dr_mode = "host"` + 供电/角色切换），大约 1 天。
2. **IP 摄像头 / RTSP**：设备只做录像、转码、NVR，零驱动工作。

## 七、下一步（本计划的第一件事）

1. 拉 `camcc-sm8150.c`，与 `camcc-sm8250.c` 对照，产出"寄存器/时钟映射表"；
2. 按映射写 `drivers/clk/qcom/camcc-sm8150.c`（主线风格：`clk_alpha_pll`、
   `clk_rcg2`、`clk_branch`、`gdsc`），配 `dt-bindings/clock/qcom,camcc-sm8150.h`；
3. DT 加 `camcc@ad00000` 节点；验收见 M1。

> 备注：本文件只记录计划与事实，不代表已经开始写驱动。开工时把每一步的
> 实测结果追加到 `docs/root-cause.md`（相机部分单独开一节 §11）。

## 八、事故记录与安全迭代协议（2026-10-20）

### 8.1 第一次上机：直接刷挂

把 `camcc-sm8150` 编进内核（`=y`）后 `dd` 到 `sda28`，重启后**整机失联**：
USB 不枚举、WiFi 不通、串口也没有（串口同样走 USB gadget 的 `ttyGS0`）。

原因分析：下游驱动的 probe 里第一步是 `devm_clk_get(&pdev->dev, "cfg_ahb_clk")`
并 enable，然后才动 camcc 寄存器。移植时把这步当"vdd/msb 噪音"删掉了 ——
**没有 CAMERA AHB 时钟就去读写 `0xad00000`，NoC 挂死**。

`/proc/sys/kernel/panic_on_oops` 是 0，所以这甚至不是 panic：是总线锁死，
内核连 panic 都打不出来。恢复只能：

```powershell
fastboot flash recovery cepheus-…-r3\recovery.img   # 已验证可启动的 r3.5 内核
fastboot reboot
```

（`recovery` 分区 = `sda28`，正是内核所在；不动 dtbo/vbmeta。）

### 8.2 之后的规矩（写死在流程里）

1. **相机这类新驱动一律 `=m`**，开机不加载。崩了最多 `modprobe` 失败，不会拖死整机。
2. 每次刷实验内核前，先在设备上备份当前 `sda28`：
   `dd if=/dev/sda28 of=/root/kernelfat-safe-$(date +%m%d%H%M).img bs=1M`
3. 刷之前确认**人能碰到手机**（要能按音量下+电源进 fastboot），远程无人值守时禁止刷实验内核。
4. 改 `payload/` 才 bump `wifi-cfg.ver`；只换内核不 bump，模块不会重新解压（这次的坑之一）。

### 8.3 下一版要验证的点

- `modprobe camcc-sm8150` 后 `dmesg` 是否出现时钟注册错误/超时；
- `clk_summary` 里 `cam_cc_*` 是否出现且可 enable；
- 若仍挂：用 `devmem` 在"已开 AHB"的前提下先读 `0xad00000`，确认 MMIO 安全再进驱动。

### 8.4 第二次上机（模块方式）：仍然锁总线，但这次留下了线索

改成 `=m` + 先开 `cfg_ahb` 后，模块能加载，但 probe 走到写 PLL 时整机又锁死：
**USB 网卡还活着（能 ping），rootfs 起不来、串口无输出** —— 不是 panic，是 NoC 停摆。

恢复后（`fastboot flash recovery` r3.5）查到两个事实：

| 观察 | 值 | 含义 |
|---|---|---|
| `pm_genpd_summary` 的 `mmcx` | `on`（64 个用户） | MMCX 本身是开着的 |
| `ad00000.clock-controller/power/domain` | **不存在** | camcc 设备根本没挂到电源域 |
| `cx` | `off-0` | 下游 DT 给 camcc 同时挂了 `vdd_mx`(CX) 和 `vdd_mm`(MMCX) |

对照主线里能工作的 **sm8250 camcc** 节点，差别很明显：它有

```dts
clock-names = "iface", "bi_tcxo", "bi_tcxo_ao", "sleep_clk";
```

而 sm8150 的节点只有 `clocks` 没有 `clock-names`。也就是说这个上游节点是"先写了个
架子"，驱动真正接进来之前没人验证过 —— 我们的 `of_clk_get(node, 1)` 取到的到底
是不是 CAMERA AHB，从来没有被证实。

**下一步不再是猜**：先写一个只 `ioremap + readl(0xad00000)` 的最小模块（不写、不注册），
在串口盯着的情况下 insmod，确认"读"这一层安不安全；再逐段加写操作。每次只前进一步，
且每次都能用 fastboot 退回。

### 8.5 第三次：模块树被实验版本污染

删掉 `camcc_sm8150.ko` 再重启，机器仍然"USB 能 ping、sshd 不启动、串口只停在 login"。
用 fastboot 重新刷同一份 r3.5 镜像又立刻恢复正常 —— 说明问题不在内核，而在 rootfs
里的**模块树与内核不匹配**：

- 实验期间刷过 r3.9 / r3.10 的内核，initramfs 把对应 `mods.tar.gz` 解进了 rootfs；
- 再刷回 r3.5 时，因为 `/etc/wifi-cfg.ver` 也是 r3.5，initramfs **判定版本相同、跳过解压**，
  于是 r3.5 的内核配着 r3.10 的模块跑（`depmod` 也会按新树重写），某些模块加载失败/行为异常，
  启动链卡在中间。

**规矩补一条**：实验内核和 payload 必须**成对**回滚。要么刷回旧镜像时同时删掉
`/etc/wifi-cfg.ver` 强制重解压，要么把 payload 版本一起改，不能只换内核。

### 8.6 已经拿到的确定性结论（下次接着用）

| 结论 | 证据 |
|---|---|
| camcc 的 MMIO **读**是安全的 | `camcc-touch` 读 `0xad00000..0x0c` → 0,0,0,1，整机无恙 |
| camcc 的 MMIO **单次写**是安全的 | 写 `0xad0000c=1` 读回 1，整机无恙 |
| 锁死发生在驱动的**后续序列**里 | 完整 probe 两次 wedge，但读/写本身都没事 |
| `stage=` 分步探针已经就绪 | `wip/camcc-sm8150/camcc-sm8150.c` 里 stage 1..5，可在真机上逐段停 |

下次的下一步：`insmod camcc-sm8150.ko stage=4`（只配 PLL0），串口盯着；若锁死，
对照 vendor 的 `cam_cc_pll0_config_sm8150_v2` 逐字段核。**务必用备用机做。**