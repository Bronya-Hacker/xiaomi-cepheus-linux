# 红外发射与 NFC（Xiaomi Mi 9 / cepheus）

2026-10-20 完成，**两者都已在真机跑通到设备节点**。

## 一、红外发射（IR blaster）

### 硬件

- 一颗红外 LED 挂在 **SPI1**（QUP `0x884000`）上，原厂 DT 用的是 `irled@0 { compatible = "ir-spi"; }`；
- 引脚：GPIO114–117，功能 `qup1`（和主线 `qup_spi1_default` 完全一致）；
- 主线的 `ir-spi` 驱动 compatible 叫 **`ir-spi-led`**（不是 `ir-spi`），并**必须**有一个名为
  `irda_regulator` 的电源。

### 实现

- `dts/cepheus-cam-ir-nfc.dtsi` 里加了：
  - `ir_vreg`（固定 3.3V，常开）当 `irda_regulator`；
  - `&qupv3_id_0 { status = "okay"; }`（**父节点必须是 okay，只开 spi1 没用**）；
  - `&spi1` 使能 + `irled: ir@0 { compatible = "ir-spi-led"; ... }`。
- 内核配置：`CONFIG_LIRC=y`、`CONFIG_IR_SPI=m`。
  注意 `LIRC` 是 bool，要求 `RC_CORE=y`，而后者又要求 `MEDIA_SUPPORT=y`
  —— 所以 media 核心现在是内建，其余驱动仍是模块。

### 验证

```
# insmod spi-geni-qcom.ko; insmod ir-spi.ko
rc rc0: IR SPI ... no receiver, raw IR transmitter
/dev/lirc0

ir-ctl -d /dev/lirc0 --scancode nec:0x20df10ef   # 返回 0，SPI 已把波形发出去
```

（`ir-ctl` 对 NEC 扩展码会提示 "will be decoded as nec:0x2010"，属正常。）

### 用法

```sh
ir-ctl -d /dev/lirc0 --scancode nec:0x20df10ef     # 电视电源
ir-ctl -d /dev/lirc0 --send=raw.txt                # 自定义脉冲/间隔
```

## 二、NFC（NXP NQ 系列）

### 硬件

- `nq@28`，I2C 地址 **0x28**，挂在 **i2c9**（QUP `0xa84000`）；
- 引脚：IRQ=GPIO47、VEN=GPIO103、FIRM=GPIO48、CLKREQ=GPIO113（后两个在本驱动里不用）。

### 实现

- DT：`&qupv3_id_1 { status = "okay"; }` + `&gpi_dma1 { status = "okay"; }`
  + `&i2c9` + `nq@28 { compatible = "nxp,nxp-nci-i2c"; ... }`；
- 模块依赖链：`nfc.ko` → `nci.ko` → `nxp-nci.ko` → `nxp-nci_i2c.ko`；
- 内核配置：`CONFIG_NFC_NXP_NCI=m`、`CONFIG_NFC_NXP_NCI_I2C=m`（原本就有）。

### 验证

```
i2c-0 上的设备 0-0028
/sys/bus/i2c/devices/0-0028/driver -> .../drivers/nxp-nci_i2c   ← 已绑定
/sys/class/nfc/nfc0                                            ← NFC 设备已注册
```

**踩过的坑**：`geni_i2c` 一开始报 "Failed to get tx DMA ch" 而 defer ——
原因是 `gpi_dma0/1` 在设备树里是 `disabled`，QUP 的 I2C/SPI 都需要它。

### 还差的

Ubuntu arm64 里没有 `nfc-tools` / `neard` 包，所以还没有用户态工具去
真正点数标签（tag）。驱动层已就绪，装了 nfctool 或者自己写个 AF_NFC
小程序就能读卡。

## 三、开机自动加载

`payload/etc/modules-load.d/ir-nfc.conf`：

```
spi-geni-qcom
ir-spi
nxp-nci
nxp-nci-i2c
```

payload 版本已升到 **r3.6**，下次刷 kernelfat 时会连同新模块一起解压安装。

## 坑：`make modules` 会留下「由 =m 改成 =y」的旧 .ko

2026-10-20 排查 `systemd-modules-load` 失败时发现：

- `CONFIG_RC_CORE` 从 `=m` 改成 `=y` 之后，编译树里**旧的 `rc-core.ko` 不会被删除**；
- 它跟着 `modules_install` 进了 payload，设备上 `modprobe ir-spi` 会先尝试加载这个
  旧模块，直接报 `Exec format error`，于是开机 `ir-spi` 加载失败、`/dev/lirc0` 消失；
- 而 `insmod ir-spi.ko` 却能成功（因为 `rc_core` 已经内建，符号都在）——这个
  差异就是排查的突破口。

处理：删掉编译树里的 `rc-core.ko` 并重建 payload；设备上删掉
`/lib/modules/.../drivers/media/rc/rc-core.ko` 后 `depmod -a`。

★ 以后任何 `=m → =y` 的配置变更，都要顺手删掉对应的旧 `.ko`，否则会混进 payload。