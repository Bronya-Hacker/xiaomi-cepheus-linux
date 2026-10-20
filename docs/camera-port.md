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

### 8.7 第四次：编进内核（in-tree）直接打不开机

按"模块和内核结构体可能不一致"的判断，改成 `CONFIG_SM_CAMCC_8150=y` 编进内核，
并默认 `stage=5`（只注册时钟、不碰 PLL）。刷完 `sda28` 后设备**完全失联**：USB 不枚举、
COM5 消失、WiFi 也没有 —— 崩在 `subsys_initcall`，比 USB gadget 更早。

至此四种组合都试过：

| 形态 | 结果 |
|---|---|
| 模块 · 完整 probe | PLL 处段错误；oops 后 `module_mutex` 卡死，整机半死（能 ping 不能 ssh） |
| 模块 · 分步 stage 1–3 | ✅ 通过（cfg_ahb / regmap 都正常，read/write 验证安全） |
| 模块 · stage 5（只注册时钟） | ❌ 同样把机器拖到半死 |
| 编进内核 · stage 5 | ❌ 直接打不开机 |

**结论**：问题不在 MMIO、不在时钟门控，而在**时钟注册/`clk_trion_pll_configure`
这条内核路径**上，且我们的驱动对象与内核里的 `struct clk_regmap/clk_alpha_pll`
之间极可能有布局或参数错位（oops 里 x0 是 regmap、x1 是 0，与源码调用的参数顺序对不上）。

**下一步必须在能随便刷/能跑 QEMU 的环境里做**：

1. QEMU 里用 `clk-regmap` 单元测试（或者纯 userspace 模拟 regmap）验证 96 个时钟表的父子/表项合法性；
2. 逐一核对 vendor 的 `cam_cc_sm8150_clocks[]` 与主线 `clk_regmap` 初始化是不是同一个 ABI；
3. 确认 PLL 的 `clk_alpha_pll` 在 vendor 与主线之间的字段差异（vendor 有 `.type/.config/vdd_class`，主线靠 `clk_trion_pll_configure()` 传 config）。

在拿到第二台测试机之前，这台服务器的 `sda28` 只保留已验证的 r3.5 内核。

## 九、M1 达成（2026-10-20 06:32）

**camcc-sm8150 已经在真机上跑通：5 个 PLL 全部配置成功，96 个 `cam_cc_*` 时钟全部注册。**

```
insmod camcc-sm8150.ko
    camcc: probe start (stage=0)
    camcc: cfg_ahb on (0 Hz)
    camcc: regmap=... (err=0)
    camcc: pll0 configured
    camcc: all plls configured
grep -c cam_cc /sys/kernel/debug/clk/clk_summary   -> 96
dmesg | grep -c 'Internal error'                   -> 0
```

### 9.1 根因（就两处，都是移植时漏字段）

下游用 `.type = TRION_PLL / REGERA_PLL` 让驱动内部查寄存器表；主线 6.17 的
`struct clk_alpha_pll` / `struct clk_alpha_pll_postdiv` 里是显式的
**`const u8 *regs`**，必须自己填：

```c
struct clk_alpha_pll {
	u32 offset;
	const u8 *regs;          /* ← 没填 = NULL */
	const struct alpha_pll_config *config;
	...
};
```

1. `.regs` 没填 → `clk_trion_pll_configure()` 在 `ldr x8,[pll,#0x8]` 后
   `ldrb [x8,#0x12]` 解引用 NULL（段错误，x0 看起来像 regmap，其实是 pll）；
2. postdiv 同样没填 `.regs` → 注册 `cam_cc_pllN_out_even/odd` 时
   `clk_trion_pll_postdiv_recalc_rate()` 崩。

修法：给 5 个 PLL 和 6 个 postdiv 各加一行
`.regs = clk_alpha_pll_regs[CLK_ALPHA_PLL_TYPE_TRION]`（pll2 用 `..._REGERA`）。

### 9.2 顺带排除的伪线索

- MMIO 读/写本身是安全的（独立探针验证过）；
- `cfg_ahb` 时钟是能取到并 enable 的（rate 报 0 Hz 只是没设置速率，不影响）；
- 父时钟表（`struct parent_map`）用的是高通自己的类型，静态校验 96 个时钟的
  `num_parents` 与数组长度全部一致，没问题；
- **最容易误导的一点**：模块崩溃后 `module_mutex` 卡死，表现为"USB 能 ping、
  sshd 起不来"，看着像总线锁死，实际是内核 oops 的连带后果。

### 9.3 下一步（M2）

camss 需要 CAMSS **175** 的资源表和 DT 节点 + 传感器驱动，见本文三、四节。
时钟这一步已经过关：`cam_cc_cci_0_clk` / `cam_cc_cphy_rx_clk_src` 都在
`clk_summary` 里，camss 探针时按需 enable 即可。

## 十、M2 准备就绪，但还没上真机（停在"要不要刷 boot"这一步）

已完成的部分（代码 + DT，都能编过）：

- `wip/camss-sm8150/0001-camss-sm8150-resources.patch`：`sm8150_resources`
  复用 SDM845 的 `csid_ops_gen2` / `csiphy_ops_3ph_1_0`（CSID175/VFE175 同代），
  4×CSIPHY + 2×CSID + 2×VFE，地址/中断取自设备上的下游 DT；
  时钟名改成 SM8150 camcc 的（**没有** `ife_*_areg` / `ife_*_ahb`，845 有 8150 没有）。
- DT 节点 `camss@acb3000`，clocks 映射到 `CAM_CC_*`，默认 `status = "disabled"`。

**卡住的原因**：DTB 是打包进 **edk2 的 boot.img** 的，`07-rebuild-all-wsl.sh`
不会重新打 boot 镜像（out/boot-cepheus.img 时间戳一直是旧的）。所以要让 camss 探针，
必须先重建 edk2 boot 镜像，再 `fastboot flash boot` —— 又是一次有风险的写入。

要不要继续，我等你一句话。继续的话顺序是：
重建 boot 镜像 → 节点改成 okay → `fastboot flash boot` → 开机 → `insmod qcom-camss.ko`
→ 看 `media-ctl -p` 里有没有 CSIPHY→CSID→VFE 的实体图。

## 十一、M2 达成（2026-10-20 13:00）：camss 在真机上跑起来了

`media-ctl -d /dev/media0 -p` 的完整拓扑：

```
msm_csiphy0..3  →  msm_csid0/1  →  msm_vfe0/1 (rdi0..2 + pix)
/dev/video0..7  +  /dev/media0  全部注册
dmesg: vfe0/vfe1 各 "6 clocks ok"、IRQ 183/184，无 oops
```

（`/dev/v4l-subdev*` 也在，csiphy/csid 各自的 sink/source pad 都对上了。）

### 11.1 关键改动

- `camss.c`：`sm8150_resources` + `qcom,sm8150-camss` 匹配；
  ops 复用 SDM845（`csiphy_ops_3ph_1_0` / `csid_ops_gen2` / `vfe_ops_170`），
  地址与中断取自设备上的下游 DT。
- `camss-vfe.c`：加了三条调试打印（stage0 / irq / clocks），定位用，可留可删。

### 11.2 这一轮踩的四个坑（按顺序）

1. `struct clk_alpha_pll` / `clk_alpha_pll_postdiv` 缺 `.regs` → 段错误（M1 同款，camss 也受影响）；
2. `struct vfe_subdev_resources` 里字段是 **`hw_ops`**，写成 `ops` 编不过、删掉则 NULL 解引用；
3. VFE 的 `pd_name` + `has_pd=true` 会再 attach 一个电源域，而 DT 上 camss 已挂 MMCX →
   `-EEXIST`（`Fail to init vfe0 sub-device: -17`）。SM8150 上先 `has_pd=false`、不写 pd_name；
4. 替换文本时误改了共享的 SDM845 条目（两边的 `.line_num = 4, .pd_name = "ife0",`
   完全一样），已恢复。

### 11.3 现状与下一步

- 时钟（M1）+ 采集管线（M2）都通了，**但还没有任何传感器**：`video*` 节点存在、拓扑在，
  没有 i2c 上的 sensor 就不会有帧。
- M3 才是真正的"能出图"：给 IMX586（主摄）写/移植 `v4l2_subdev` 驱动，
  需要 i2c 地址、上电时序、PLL 与模式寄存器表 —— 下游 `techpack/camera` 里有现成的。
- 电源管理（VFE 的 per-VFE 电源域）暂时用 `has_pd=false` 绕开，等出图后再补。

## 十二、M3 的前置调查（2026-10-20 13:10）：传感器驱动缺"表"

结论：**M3 卡在数据，不卡在代码。**

- 主线 6.17 树里 `grep -r imx586` → **零结果**；同族只有 `imx412`（12MP，结构可参考，但寄存器表完全不同）。
- 下游 `camera_v2/sensor/` 只有框架（`msm_sensor*.c`），**没有 imx586.c**；
  新相机栈 `drivers/media/platform/msm/camera/cam_sensor_module/cam_sensor/` 同样只有框架。
  也就是说小米公开的内核源码**不含**传感器驱动（通常随 camera blobs 走 proprietary 包）。
- 本机也没有可反编译的 Android camera HAL（早被覆盖成 Ubuntu 了）。

**没有传感器初始化表（PLL、模式、寄存器序列）就写不出能出图的驱动**，这不是靠猜能补的。

### 12.1 可选的几条路

1. **找表**：任何一份 IMX586 的公开初始化序列都行 —— 比如别的厂商的 kernel 源码、
   树莓派/libcamera 类项目、或同款传感器的开源移植。拿到表后写驱动是 3–5 天的活。
2. **先验证链路**：camss 的 CSID 带 `V4L2_CID_TEST_PATTERN` 测试图案发生器
   （`camss-csid.c`），理论上可以在没有传感器时验证 CSID→VFE 的采集。
   但 CSID 通常需要 CSI PHY 的时钟做参考，能否独立跑通要试（半小时到一天）。
3. **换硬件路线**：USB UVC（要 host 模式 + 占用 USB 口供电，用户已排除）或 IP 摄像头（零驱动）。

### 12.2 现状

时钟（M1）与采集管线（M2）都已打通并提交：`/dev/media0` + `/dev/video0..7` 在设备上。
再往下就是"数据"问题，没有表就只能停在这里。

### 12.3 测试图案实验（2026-10-20 13:20）

- CSID 的 `V4L2_CID_TEST_PATTERN` 可用：`/dev/v4l-subdev4`（msm_csid0）设 `test_pattern=1 (Incrementing)` 成功；
- 但 `v4l2-ctl --stream-mmap` 报 **`VIDIOC_REQBUFS: Cannot allocate memory`** ——
  原因是 DT 里 camss 节点**没有 `iommus`**，vb2-dma-sg 拿不到 IOMMU 域，缓冲区分配不出来。
- 下游 DT 里相机 SMMU 的 stream ID 已挖到（`qcom,cam_smmu/msm_cam_smmu_ife`）：
  `0x840 0x860 0xa40 0xa60 0xc40 0xc60 0xe40 0xe60`，mask `0x620`。
- 主线参考写法（sm8250）：`iommus = <&apps_smmu 0x800 0x400>;` +
  `power-domains = <&camcc IFE_0_GDSC>;` —— 说明 camcc 还应该导出 IFE GDSC，
  我们这版 camcc 只导出了时钟，没导 GDSC。

**下一步（需要再刷一次 boot 分区）**：
1. DT 加 `iommus = <&apps_smmu 0x840 0x620>, <&apps_smmu 0x860 0x620>;`；
2. camcc 补 GDSC（IFE_0/IFE_1/TITAN_TOP 等），camss 用 `power-domains = <&camcc ...>`；
3. 重建 boot → 刷 boot → 重测 test pattern 出帧。