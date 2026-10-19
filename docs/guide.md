# 小米9 (cepheus / SM8150) 主线 Linux —— 打通 WiFi (WCN3990 / ath10k_snoc)

> 这份文档是"交接包 + 本轮实测"的合并版。凡是**实测过**的都标了证据，
> 凡是**没验证过的**都明确写了"没验证"，不要当成结论。
>
> **2026-10-19 续**：蓝牙（WCN3990 / uart13）也已打通，`hciconfig` 显示
> `UP RUNNING` 且能扫到真实 BLE 设备 —— 过程与三个坑见
> `docs/root-cause.md §10.17`，验收清单见 `docs/verify.md §九`。
> 同一轮还完成了"放弃 GUI、当服务器用"的底座改造（§10.16，版本 `2026-10-19-srv5`）。

---

## 0. 一句话结论

**"没有 wlan0" 不是单一的 DTB 问题。** 它是一条 5 环链条，**缺一环就永远没有 wlan0**：

| 环 | 内容 | 之前的状态 |
|---|---|---|
| 1 | **DTB** 里把 `&remoteproc_adsp` 打开，**并且带 `firmware-name`** | 实验版镜像开了 `status`，但**没写 `firmware-name`** → `qcom_q6v5_pas` 直接 probe 失败 |
| 2 | **ADSP 必须真的 `running`**（固件文件存在、`adsp_mem`、供电） | 从未验证过 |
| 3 | **userspace 必须跑 `tqftpserv`** —— ADSP 里的 WLAN 固件要通过 QRTR/TFTP 向用户态索取 `wlanmdsp.mbn` | **从来没有部署过 ← 最大的缺口** |
| 4 | **`board-2.bin` 要含 `qmi-chip-id=30224`** | 手机上那份只有 30214，**本轮已解决并随包提供** |
| 5 | **`/lib/firmware/qcom/sm8150/adsp.mdt` 必须存在**（ADSP 固件本体） | 手机上有（拆分固件），但要自己确认一遍 |

本轮新查实的两点（都是本轮才有的证据）：

* **环 1 的第二重原因**：`qcom_q6v5_pas` 的 probe 里 `devm_kstrdup(dev, ...)` 会读
  DT 的 `firmware-name`；**没有这个属性就 probe 失败**。之前那版"已经打开 remoteproc 的 DTB"
  其实一个 `firmware-name` 都没有 → ADSP 根本没起来。**光 `status="okay"` 是不够的。**
* **环 3 的实现细节**：`tqftpserv` 的**官方 systemd 单元就是 `ExecStart=/usr/bin/tqftpserv`（不带任何参数）**，
  路径翻译规则写在它的 `translate.c` 里（见 §1.3）。所以 `wlanmdsp.mbn` 的**唯一正确落点**是
  `/lib/firmware/qcom/sm8150/wlanmdsp.mbn`（与 DTB 里 `firmware-name` 的目录同名）。

---

## 1. 证据链

### 1.1 DTB 是怎么送到内核手里的 —— 先纠正一个关键误解

交接文档说"改 DTB = 改 boot 镜像"，但没说是哪个文件。实测（本机解析交接包的 boot 镜像）：

```
文件 USB正常版-boot-cepheus-wifi.img
magic = ANDROID!          header_version = 1     ← 没有 boot.img 自带的 dtb 区
kernel_size = 6854353     page_size = 2048
全文件只有 1 个 FDT magic：offset = 0x5f245b，size = 621174
    → 它落在 kernel 区内部，是"追在 Image 尾巴上的厂商 DTB"
    → 内容里只有 qcom,smem@，没有 soc@0、没有 wifi@18800000
```

本轮**把那个 621 KB 的 DTB 认出来了**：它就是 edk2-msm 里
`Platform/Xiaomi/sm8150/FdtBlob_compat/cepheus.dtb`（621174 字节，
`model = "CEPHEUS"`、`compatible = "qcom,sm8150-cdp"`、**没有 `soc@0`**）。
`build.sh` 的收尾函数就是把它追在 boot 镜像最后：

```sh
# platform_build_kernel()
cat tools/BootShim/BootShim.bin workspace/.../FV/SM8150_UEFI.fd | gzip -c > uefi-cepheus.img.gz
cat uefi-cepheus.img.gz Platform/Xiaomi/sm8150/FdtBlob_compat/cepheus.dtb > uefi-cepheus-kernel
```

它是给 **ABL 看**的（"compat" 就是兼容厂商 ABL 那套），**Linux 不用它，别动它**。

但手机上 `/sys/firmware/devicetree/base/` 里**有** `soc@0/wifi@18800000`（主线风格）。结论：

* 内核**不使用** Image 尾巴上那个 621 KB 厂商 DTB；
* 内核实际用的是 **edk2 UEFI 固件里内嵌的 DTB**（通过 UEFI 配置表 `LINUX_EFI_DTB_TABLE_GUID` 交给 Linux）；
* 源头是 edk2-msm 的
  `Platform/Xiaomi/sm8150/FdtBlob/cepheus/sm8150-xiaomi-cepheus.dtb`；
  它在 FDF 里是这么进去的（`cepheus.fdf.inc`）：

  ```
  FILE FREEFORM = 25462CDA-221F-47DF-AC1D-259CFAA4E326 {
      SECTION RAW = Platform/Xiaomi/sm8150/FdtBlob/cepheus/sm8150-xiaomi-cepheus.dtb
  }
  ```

  `25462CDA-221F-47DF-AC1D-259CFAA4E326` 就是 edk2 的
  **`gDtPlatformDefaultDtbFileGuid`**（默认 DTB 文件）→ 由 `DtPlatformDxe`
  装成系统 DTB。**这就是"改哪个文件"的权威依据。**
* 本轮**实测反编译了这个文件**：`wifi@18800000` 的 `status = "disabled"`，
  `firmware-name` / `vdd-*-supply` **全部不存在**，`/chosen` 里只有 `stdout-path`、**没有 bootargs**；
* 它在 edk2 里是**压缩存放**的（整个 edk2 镜像里扫不到第二个未压缩 DTB），
  所以**不能二进制打补丁，必须重编 edk2**。

**本轮还做了双向验证**（03 脚本里已自动化）：

* 编译中间产物 `workspace/Build/cepheus/RELEASE_CLANG38/FV/FVMAIN.Fv`（**未压缩**，
  32 MB）里能直接 `grep` 到我们的标记 —— `qcom/sm8150/adsp.mdt` /
  `vdd-0.8-cx-mx-supply` / `Xiaomi_raphael` / `wcn3990-wifi`；
* 出自同一次构建的 `boot-cepheus.img` 里也能定位到那个 DTB
  （offset 0x1ebbacc，size 98536 = 恰好是内核编出来的大小）。

> 为什么不能直接扫 `boot-cepheus.img`：`FVMAIN`（32 MB）被 LZMA 压成了
> `FVMAIN_COMPACT`（7 MB）再被 gzip 包进 boot 镜像 —— **双层压缩**，
> 所以扫 boot 镜像找不到 FDT magic，这是正常的，不代表 DTB 没进去。

→ **改 DTB 的产物是 `boot-cepheus.img`（刷 boot 分区），不是 `Image`。**

### 1.2 为什么 `-517` 会消失但 `wlan0` 不出现

* `ath10k_snoc` probe 时：
  1. `qmi_handle_init(..., AF_QIPCRTR)` → 需要 `qrtr`（`af_qrtr`），
     否则 `sock_create_kern` 返回 `-EAFNOSUPPORT` → 驱动 `-EPROBE_DEFER`，
     日志就是 `failed to register wlfw qmi client: -517`；
  2. `qmi_add_lookup(WLFW_SERVICE_ID_V01)` → 去 QRTR 名字服务里**找 WLFW 这个 QMI 服务**。
* 加载 `qrtr` + `qrtr-smd` + `qcom_glink_smem` 之后第 1 步过了，但第 2 步还没有结果，因为：
  * WLFW 服务是 **ADSP 里的 WLAN 固件**广播的，不在内核里；
  * 内核侧 QRTR 的路径是：
    `qrtr-smd`（`net/qrtr/smd.c`，匹配 rpmsg 通道名 `"IPCRTR"`）
    ← `qcom_glink_smem` ← **`remoteproc_adsp` 的 `glink-edge`**（`label="lpass"`, `qcom,remote-pid=<2>`）。
  * `glink-edge` 是 `remoteproc@17300000` 的**子节点** → **remoteproc 不 running，IPCRTR 通道就不存在**。
* 所以：`/sys/class/rpmsg` 与 `/sys/bus/rpmsg/devices/` 空 = **ADSP 从来没起来**。
* 另：`ath10k_snoc_probe()` 在 `ath10k_qmi_init()` 之后**直接 `return 0`**，
  然后**静默等 WLFW**。所以 `-517` 消失后 `wlan0` 不出现、也**不再报错**，是符合代码的。

### 1.3 为什么 ADSP 起来了还需要 tqftpserv（本轮拿到了权威依据）

**权威依据 1 —— ath10k 邮件列表（Dmitry Baryshkov，tqftpserv 作者）原话：**
> On WCN3990 platforms actual firmware, `wlanmdsp.mbn`, is sideloaded to the modem DSP via the TQFTPserv.

**权威依据 2 —— 源码里根本没有**：这棵树里搜 `wlanmdsp` **零出现**；
本机全树也没有任何 TFTP 服务端驱动（只有 netfilter 的 `nf_conntrack_tftp`，那是跟踪包用的）。
→ 必然由**用户态**做。

**权威依据 3 —— `tqftpserv` 自己的 `README.md` 与 `translate.c`（本轮拉取上游原文）：**

虚拟路径两套：

| 客户端请求前缀 | 翻译到 |
|---|---|
| `/readonly/firmware/image/` | `/lib/firmware/<remoteproc 的 firmware-name 目录>/` |
| `/readwrite/` | `/var/lib/tqftpserv/` |

`translate.c` 的核心逻辑（本机核对过原文）：

```c
#define READONLY_PATH      "/readonly/firmware/image/"
#define READONLY_FW_BASE   "/readonly/firmware/"
#define READONLY_MODEM_PATH READONLY_FW_BASE "modem_pr"
...
#ifndef ANDROID
#define FIRMWARE_BASE      "/lib/firmware/"
#define TQFTPSERV_RW_DIR   "/var/lib/tqftpserv"
#else
#define FIRMWARE_BASE      "/vendor/firmware/"
#endif
```

它会**遍历 `/sys/class/remoteproc/*/firmware`**，取每个 remoteproc 的 `firmware-name`
的**目录名**，依次尝试：

1. `/sys/module/firmware_class/parameters/path` 下的同名文件（如果设了）
2. `/lib/firmware/updates/<目录名>/<请求的相对路径>`
3. `/lib/firmware/<目录名>/<请求的相对路径>`

取第一个存在的。**并且会自动尝试 `.xz` / `.zst` 压缩版**。

**⟹ 结论（源码级，不用再猜）：**
我们的 DTB 给 ADSP 和 MPSS 都写 `firmware-name = "qcom/sm8150/xxx.mdt"`，
目录名都是 `qcom/sm8150`，所以客户端请求 `wlanmdsp.mbn` 命中

```
/lib/firmware/qcom/sm8150/wlanmdsp.mbn
```

（两个 remoteproc 目录名相同，等于上了双保险。`payload/` 里还在
`lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn` 留了一份 linux-firmware 原始位置，无害。）

**权威依据 4 —— 官方 systemd 单元照抄（本轮从 Debian 包里取出）：**

```ini
[Unit]
Description=QRTR TFTP service

[Service]
ExecStart=/usr/bin/tqftpserv     ← 不带参数！别自己加 -r /lib/firmware（没有这个参数）
Restart=always
StateDirectory=tqftpserv

[Install]
WantedBy=multi-user.target
```

`StateDirectory=tqftpserv` 正好对应 `translate.c` 里的 `/var/lib/tqftpserv`（读写路径）。
**默认只读根就是 `/lib/firmware`**，所以裸跑即可。

**本轮还把这条结论在二进制里核对了一遍**（`strings out/tqftpserv`）：

```
/lib/firmware/                 ← 只读根
/readonly/firmware/image/      ← 客户端虚拟前缀
/readonly/firmware/modem_pr
/readwrite/                    ← 读写虚拟前缀
```

和 `translate.c` 完全一致。

### 1.4 board-2.bin 的 chip-id（★ 本轮解决）

* 手机上 `/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin`（约 670 KB）只带 `qmi-chip-id=30214`，
  而 sm8150 上的 WCN3990 要 **30224**；
* `firmware-5.bin`（60 字节，magic `QCA-ATH10K`）是**桩文件**，本身没问题
  （WCN3990 的真固件跑在 ADSP 里，这个文件只是列 ath10k 的 API 版本）。

**本轮找到并已随包提供：** Debian `firmware-atheros_20260916-1_all.deb` 里的
`ath10k/WCN3990/hw1.0/board-2.bin`（**893 528 字节**）同时含

```
qmi-chip-id=120 140 150 30214 30224 320 4320
```

已放进 `payload/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin`，
**刷机时会随 payload 自动覆盖到手机上**，不需要再手工找。
同一个包里还带了 `wlanmdsp.mbn`（3 725 044 字节）和 `firmware-5.bin`，也一起给了。

### 1.5 ADSP 固件本体必须存在（新加的"环 5"）

DTB 里写 `firmware-name = "qcom/sm8150/adsp.mdt"`，`qcom_q6v5_pas` 就会老老实实
`request_firmware("qcom/sm8150/adsp.mdt")`。**文件不在 → probe 失败 → ADSP 不 running → 没有 IPCRTR → 没有 WLFW。**

* 这台手机上 `/lib/firmware/qcom/sm8150/` 里是**拆分固件**（`adsp.mdt` + `adsp.b00…`），
  所以 DTB 必须写 `.mdt`，**不能写 `.mbn`**；
* 但注意：**拆分的 `.mdt` 和单体的 `.mbn` 不是一回事**。上游 pmOS 的 nabu 用的是单体
  `qcom/sm8150/Xiaomi/nabu/adsp.mbn`（14.4 MB），那是 linux-firmware 给的单体固件；
  **我们这台机器上没有单体的 cepheus adsp**，所以只能走手机自带的拆分固件。
* `wifi-up.sh` 里已经加了开机自检：`adsp.mdt` 在不在、是不是只有 `adsp.mbn`，都会写进
  `/run/wifi-up.log`。

---

## 2. 物料在哪（都是本轮确认过的路径）

| 东西 | 位置 | 说明 |
|---|---|---|
| **内核源码** | `…\mi9-linux-project\local-build\dl\kernel.tar.gz`（254 MB） | 版本 6.17.0，`CONFIG_LOCALVERSION="-sm8150"` → 模块目录 `6.17.0-sm8150`。自带 `sm8150-xiaomi-cepheus.dts` 和 `arch/arm64/configs/sm8150.config` |
| **配置片段** | 同上 `arch/arm64/configs/sm8150.config` | `make ARCH=arm64 defconfig` 后 `make ARCH=arm64 sm8150.config`（走 kbuild 的 `%.config` 规则合并，**这是合法的**） |
| **edk2-msm** | `https://github.com/edk2-porting/edk2-msm` | 本机没有，必须 clone。**github 直连被墙**，见 §4.1 |
| **tqftpserv** | Debian/Ubuntu 的 arm64 `.deb` | 不交叉编译，直接拆包（见 `scripts/04-build-tqftpserv.sh`） |
| **board-2.bin / wlanmdsp.mbn / firmware-5.bin** | Debian `firmware-atheros_20260916-1_all.deb` | **已随本包提供**，在 `payload/lib/firmware/` 下 |
| **编译机** | **本机 WSL Ubuntu 24.04**（`wsl -d Ubuntu-24.04`） | 不再是旧机 `192.168.31.2` |

---

## 3. 要落地的五件事（按依赖顺序）

```
[0] DTB(UFS) : ★ 给板级 DTS 补 &ufs_mem_hc / &ufs_mem_phy = okay + 供电/复位
               —— 不做这一步，内核根本看不到 /dev/sda*，手机卡死在 initramfs（见 4.7）
[1] DTB      : 给 sm8150-xiaomi-cepheus.dts 追加 &remoteproc_adsp/&remoteproc_mpss/&wifi  —— 见 dts/
[2] 内核     : 编 Image（内嵌 initramfs）+ dtb + modules（6.17.0-sm8150）
[3] edk2     : 把新 dtb 塞进 FdtBlob，重编 → boot-cepheus.img（★ DTB 靠这一步才生效）
[4] userspace: tqftpserv + libqrtr/libzstd + wpa_supplicant 配置 + 模块加载顺序 → wifi-cfg.tar.gz
[5] 固件     : wlanmdsp.mbn + board-2.bin(30224) 随 payload 走；adsp.mdt 靠手机自带
```

DTB 补丁（`dts/cepheus-wifi.dtsi`，本轮已合并进内核树并**验证过编译产物**）：

**第 0 部分 —— UFS（"能启动"的前提，★ 2026-10-18 血坑）**

* `&ufs_mem_hc { status = "okay"; reset-gpios = <&tlmm 175 GPIO_ACTIVE_LOW>; vcc-supply = <&vreg_l10a_2p5>; vccq2-supply = <&vreg_s4a_1p8>; }`
* `&ufs_mem_phy { status = "okay"; vdda-phy-supply = <&vreg_l5a_0p875>; vdda-pll-supply = <&vreg_l3c_1p2>; }`
* 上游 `sm8150-xiaomi-cepheus.dts` **完全没有**这两段，`sm8150.dtsi` 里默认 `status="disabled"`。
  取值与"前人能启动镜像"的 DTB **逐属性一致**（对照方法见 4.7）。

**第 1 部分 —— WiFi（环 1~环 5）**

* `&remoteproc_adsp { status = "okay"; firmware-name = "qcom/sm8150/adsp.mdt"; }` ← 环 1
* `&remoteproc_mpss { status = "okay"; firmware-name = "qcom/sm8150/modem.mdt"; }`
* `&remoteproc_cdsp / &remoteproc_slpi { status = "disabled"; }`（固件不在手机上，别开）
* `&wifi { status = "okay";` 四路电源 `vdd-0.8-cx-mx=<&vreg_l1a_0p75>` / `vdd-1.8-xo=<&vreg_l7a_1p8>` /
  `vdd-1.3-rfa=<&vreg_l2c_1p3>` / `vdd-3.3-ch0=<&vreg_l11c_3p3>`；`qcom,calibration-variant = "Xiaomi_raphael"; }`

四路电源的取值是拿 **pmOS 编好的 sm8150 各机型 DTB 交叉验证过**的：
nabu / vayu / flame / mtp / hdk 都是这四路、都**没有** `vdd-3.3-ch1`。

**本轮实测编译产物（`arch/arm64/boot/dts/qcom/sm8150-xiaomi-cepheus.dtb`）里确认有：**

```
wifi@18800000            status = "okay"
                         vdd-0.8-cx-mx-supply / vdd-1.8-xo-supply / vdd-1.3-rfa-supply / vdd-3.3-ch0-supply
                         qcom,calibration-variant = "Xiaomi_raphael"
remoteproc@17300000      status = "okay";  firmware-name = "qcom/sm8150/adsp.mdt"
    glink-edge           label = "lpass";  qcom,remote-pid = <0x02>
chosen                   stdout-path = "serial0:115200n8"   （本来就有的，不用补）
```

---

## 4. 动手

### 4.1 编译机（本机 WSL Ubuntu 24.04）

```bash
# 在 Windows PowerShell 里进 WSL
wsl -d Ubuntu-24.04 -u root
```

**依赖安装**（`scripts/01-setup-buildhost.sh` 干的就是这件事，已按本轮实测修过）：

```bash
cd /root/wifi-bringup
sudo bash scripts/01-setup-buildhost.sh
```

必须有的东西（本机都已就绪，核对过版本）：
`clang`(18.1.3) / `lld` / `dtc` / `mtools`(`mformat`,`mcopy`,`mdir`) / `nasm` / `iasl` /
`meson` / `ninja` / `python3` / `gettext`(`msgfmt` **edk2 必须**) / `brotli` / `cmake` /
`uuid-runtime` / `depmod` / `gcc-aarch64-linux-gnu`。

**github 直连被墙**，clone 必须走代理（`gh-proxy.com`，本轮实测可用）：

```bash
git config --global url."https://gh-proxy.com/https://github.com/".insteadOf "https://github.com/"
# ★ openssl 里嵌了一个 googlesource 上的 boringssl，不重写它会卡死 135 秒然后失败
git config --global url."https://gh-proxy.com/https://github.com/google/boringssl".insteadOf "https://boringssl.googlesource.com/boringssl"
```

### 4.2 准备源码

```bash
mkdir -p ~/build && cd ~/build
tar xzf /path/to/kernel.tar.gz                 # → linux-v6.17.0-sm8150-379d8fe3…
git clone --depth 1 https://github.com/edk2-porting/edk2-msm
cd edk2-msm && git submodule update --init --recursive --depth 1
```

> `tools/Installer` 空着**没关系**（它只在 `build.sh --installer-zip` 时才用，默认关）。
> 但 `Common/edk2`、`Common/edk2-platforms`、`GPLDrivers/Library/SimpleInit`、
> `Platform/EFI_Binaries` **必须有内容**，否则 `build.sh` 会直接报错退出。

### 4.3 打 DTB 补丁 + 编内核

```bash
cd /root/wifi-bringup
bash scripts/apply-dts.sh ~/build/linux-v6.17.0-sm8150-379d8fe3…
bash scripts/02-build-kernel.sh ~/build/linux-v6.17.0-sm8150-379d8fe3…
```

产出（都在 `wifi-bringup/out/`）：
* `Image`（已内嵌 initramfs）
* `sm8150-xiaomi-cepheus.dtb` ← **重点，给 edk2 用**
* `mods.tar.gz`（模块，顶层目录 `6.17.0-sm8150`）
* `initramfs.cpio.gz`

**这一轮踩过的 5 个坑（脚本里都已修）：**

1. **★ `CONFIG_REMOTEPROC` 是 `bool`，用 `--module` 会把整块砍掉（最坑的一个）。**
   `drivers/remoteproc/Kconfig` 整个文件被 `if REMOTEPROC` 包着；
   `scripts/config --module REMOTEPROC` 写出 `CONFIG_REMOTEPROC=m`（非法值）→
   `olddefconfig` 回落成 `n` → **`QCOM_Q6V5_PAS` / `QCOM_Q6V5_COMMON` / `QCOM_RPROC_COMMON` 全部消失**。
   症状极隐蔽：**内核能编完、`Image` 能出，但模块包里没有 `qcom_q6v5_pas.ko`** → ADSP 永远起不来。
   修法：bool 的符号用 `--enable`（`REMOTEPROC` / `QCOM_SCM` / `RPMSG`），
   并且在编之前加了**硬性门槛检查**，缺项直接退出不浪费时间。
2. **符号名别写错**：是 `CONFIG_RPMSG_QCOM_GLINK_SMEM`（模块 `qcom_glink_smem.ko`），
   **不叫** `QCOM_GLINK_SMEM`。写错了 `olddefconfig` 会**静默丢掉**，不报错。
3. **`-Werror=strict-prototypes` 会把内核编废。**
   `scripts/Makefile.extrawarn` 无条件加了它，而 `sm8150.config` 片段把厂家触摸屏驱动
   `CONFIG_TOUCHSCREEN_STM_FTS_DOWNSTREAM=y` 编了进来，它里面
   `struct spi_device *getClient()` 这种 K&R 声明在 clang 18 下**直接报错**，
   连 `Image` 都出不来。脚本里加了 `KCFLAGS=-Wno-error=strict-prototypes`。
4. **别写 `yes n | make olddefconfig`。** `yes` 收不到 EOF 会吃 SIGPIPE，
   配合 `set -o pipefail` 整个脚本以 **141** 退出（看起来像"编完了"，其实什么都没编）。
   同类还有 **`tar tzf … | grep -q …`** —— `grep -q` 命中就早退，`tar` 收 SIGPIPE，
   `pipefail` 下判成失败。要先用管道就得 `</dev/null`，或者把清单落文件再 `grep 文件`。
5. **`make -s kernelrelease` 时机不对会打 `6.17.0`**（漏掉 `-sm8150`）。
   它只有在 `include/config/auto.conf` 生成后才带 `CONFIG_LOCALVERSION`。
   脚本改成本：initramfs 的 init 脚本遍历 `/lib/modules/*/` 做 depmod（不依赖这个值），
   打包模块时再从 `include/config/kernel.release` 读真名。

> ⚠️ 每次重编 Image 前必须 `rm -f usr/initramfs_data.o`，否则 initramfs 不更新（脚本里已做）。

### 4.4 edk2（DTB 在这里生效）

```bash
bash scripts/03-build-edk2.sh ~/build/edk2-msm out/sm8150-xiaomi-cepheus.dtb
# → out/boot-cepheus.img
```

脚本会：备份原 FdtBlob → **校验**新 DTB（`adsp.mdt`/四路电源/`bootargs`/`wifi status=okay`
缺任何一个就报错退出）→ 给 `/chosen` **注入** `bootargs` → 替换
`Platform/Xiaomi/sm8150/FdtBlob/cepheus/sm8150-xiaomi-cepheus.dtb`
→ `./build.sh --device cepheus`（失败自动带 `--fixclang` 重试一次）
→ **扫未压缩的 `FVMAIN.Fv` 确认我们的 DTB 真的编进去了**（终极校验）。

**关于 bootargs**：内核编出来的 DTB 里 `/chosen` 已经有
`stdout-path = "serial0:115200n8"`，命令行本来也可以由 kernelfat 里的 `startup.nsh`
（`fs3:\Image console=tty0 loglevel=7 clk_ignore_unused …`）传。
但**上一任编出来、确认能启动的那个镜像**是往 DTB 里也补了
`bootargs = "console=tty0 loglevel=7"` 的，所以本脚本照做（对齐已知能启动的配置，
且多一份显示控制台兜底）。副作用：`/proc/device-tree/chosen/bootargs` 有值 ——
正好可以用它判断"刷进去的到底是不是新编的 edk2"（第 0 关会看这个）。

**别改错 DTB**：`FdtBlob_compat/cepheus.dtb`（621174 字节、`model="CEPHEUS"`）
是给 ABL 的，追在 boot 镜像尾部；**Linux 用的是 `FdtBlob/cepheus/*.dtb`**。
详见 `docs/root-cause.md` §9.1b。

### 4.5 tqftpserv + payload + kernelfat

```bash
bash scripts/04-build-tqftpserv.sh    # 拆 Debian/Ubuntu 的 arm64 deb → out/tqftpserv + libqrtr.so.1.0 + libzstd.so.1.5.5
bash scripts/05-make-payload.sh       # → out/wifi-cfg.tar.gz（固件已随包，无需参数）
bash scripts/06-make-kernelfat.sh     # → out/kernelfat.img（Image + mods + payload + startup.nsh）
```

**为什么不交叉编译 tqftpserv**：Debian 官方就打包了它（维护者正是 tqftpserv 的作者），
二进制 67 KB，依赖只有 `libqrtr1` + `libzstd1`；而且**包里的 systemd 单元和二进制是官方配对的**，
参数不会写错。交叉编译要处理 libqrtr + glib 的 arm64 开发包，麻烦得多、更容易错。

> ⚠️ **改了 `payload/` 里任何东西，都必须重跑 05 和 06**：
> `wifi-cfg.tar.gz` 和 `kernelfat.img` 都是打包出来的快照，
> 改源文件不会自动生效。三行搞定：
>
> ```bash
> bash scripts/05-make-payload.sh && bash scripts/06-make-kernelfat.sh
> ```

`tqftpserv` 的依赖 `libqrtr.so.1` 手机 rootfs 上**大概率没有**（Ubuntu main 里有但要单独装，而手机没网），
所以 payload 里带了一份放在 `/usr/lib/tqftpserv-bundle/`，由 `wifi-up.sh` **按需**补进
`/usr/lib/aarch64-linux-gnu/`（**只在系统里本来没有时才动手，不覆盖已有文件**）。

### 4.6 刷机（Windows，fastboot）

```powershell
cd C:\Users\MAO\Desktop\小米9移植linux\wifi-bringup
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flash.ps1
```

> ⚠️ **必须用 `-File` 方式调用，而且 `flash.ps1` 必须带 UTF-8 BOM。**
> Windows PowerShell 5.1 对 **无 BOM 的 UTF-8 `.ps1`** 会按 ANSI 解码，
> 文件里的中文会把语法搞坏（报一堆 `字符串缺少终止符` / `<` 被当成重定向，
> 明明文件本身语法是对的）。本包里的 `flash.ps1` 已经写入 BOM。
> 如果你用编辑器重存过它，记得**保存成"UTF-8 带 BOM"**，或者用 PowerShell 7（`pwsh`）。

等价于：

```
fastboot flash boot     out\boot-cepheus.img
fastboot flash recovery out\kernelfat.img
fastboot continue
```

> **红线：绝对不要 `fastboot erase dtbo` / `fastboot erase vbmeta`**（ABL 直接 Load Error）。
> **`fastboot reboot` 在这台机器上会被 bootloader 拦下**，所以脚本用的是 `fastboot continue`
> （失败再退到 `adb reboot`）。
> 刷机工具：`…\mi9-linux-project\tools\pt33\platform-tools\fastboot.exe`。

### 4.7 ★ UFS："看起来像卡死"的真正原因（2026-10-18 上机实证）

**现象**（如果只打 WiFi 段、漏掉 UFS 段）：

* 屏幕上出现几只企鹅（= `fbcon` 起来了），下面一堆内核日志，
  然后**日志不再滚动**，等多久都不动；
* **Windows 也扫不到 USB 设备**。

**看起来像**内核崩了/时钟挂了，**实际是**：

1. 板级 DTS 没开 `&ufs_mem_hc`（上游 cepheus 的板级文件里根本没有这一段），
   DTB 里 `/soc@0/ufshc@1d84000` 是 `status = "disabled"`；
2. 于是内核**根本没有 `/dev/sda*`**（根文件系统在 UFS 上！）；
3. initramfs 里那个"等 rootfs"的循环永远等不到 → 超时后进死循环（默认静默）；
4. "USB 扫不到"只是**症状不是病因**：USB gadget（`usb0`）是 userspace 用 configfs
   拉起来的，系统没进 userspace 自然没有。

**怎么一眼确认**（不用刷机，编完就能查）：

```bash
dtc -I dtb -O dts -o /tmp/x.dts out/sm8150-xiaomi-cepheus.dtb
awk '/ufshc@1d84000 \{/{f=1} f&&/status/{print; exit}' /tmp/x.dts
#   status = "okay";      ← 对
#   status = "disabled";  ← ★ 必卡 initramfs
```

`02-build-kernel.sh` 和 `03-build-edk2.sh` 现在**都会在编译期拦这一项**（不是 okay 直接退出），
所以只要脚本跑通，就不该再出现这个现象。

**取值是从哪来的**：本机 `local-build/cepheus.dts`（前人的**能启动镜像**反编译出来的 DTS）。
对照方法（也是这次的排错方法）——把两份 DTB 都解成 DTS，只比 `status`：

```
/soc@0/ufshc@1d84000        前人=okay      我们(修前)=disabled   ← 就是它
/soc@0/phy@1d87000          前人=okay      我们(修前)=disabled
/soc@0/wifi@18800000        前人=disabled  我们=okay     ← 我们有意的
/soc@0/remoteproc@17300000  前人=disabled  我们=okay     ← 我们有意的
/soc@0/remoteproc@4080000   前人=disabled  我们=okay     ← 我们有意的
共 5 处；节点总数都是 851，其余全部一致
```

修完后再比一次，**只剩我们有意开的那 3 处**，UFS 两个节点的属性（含 `reset-gpios` /
`vcc-supply` / `vccq2-supply` / `vdda-phy-supply` / `vdda-pll-supply`）与能启动版**逐字节一致**。

> ⚠️ 复现这一坑的**唯一**做法是"只打 WiFi 段"。`apply-dts.sh` 已经改成
> 检测到旧版补丁（没 UFS 段）就**报错退出**，不会闷头追加第二遍。

---

## 5. 上机验证（一关一关过，不要跳）

**一键诊断**：`docs/verify.md` 里有 `wifi-diag.sh`，直接跑它最省事。

### 第 0 关：DTB 到底换了没有（不用 dtc）

```sh
cat /proc/device-tree/soc@0/ufshc@1d84000/status        # ← 必须是 okay（不 okay 你根本进不到这里）
cat /proc/device-tree/soc@0/wifi@18800000/status
cat /proc/device-tree/soc@0/remoteproc@17300000/status
cat /proc/device-tree/soc@0/remoteproc@17300000/firmware-name
```

期望：`okay` / `okay` / `okay` / `qcom/sm8150/adsp.mdt`。

**如果还是 `disabled` 或没有 `firmware-name`，后面全部免谈** ——
说明 edk2 没刷成功 / FdtBlob 没换。

### 第 1 关：固件文件齐不齐（本轮新加）

```sh
ls -l /lib/firmware/qcom/sm8150/adsp.mdt            # 手机自带（拆分固件入口）
ls -l /lib/firmware/qcom/sm8150/wlanmdsp.mbn        # payload 投递
ls -l /lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin
strings /lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin | grep -o 'qmi-chip-id=30224'
```

最后一条**必须有输出**（这就是环 4）。

### 第 2 关：ADSP 有没有起来

```sh
dmesg | grep -iE 'q6v5|remoteproc|adsp'
for r in /sys/class/remoteproc/*; do echo "$r: $(cat $r/name) $(cat $r/state)"; done
ls /sys/bus/rpmsg/devices/
```

期望：`adsp` state = `running`；`/sys/bus/rpmsg/devices/` 里出现 `IPCRTR` 之类。

模块加载顺序由 `payload/etc/modules-load.d/wifi.conf` 与 `modprobe.d/wifi-order.conf` 控制：
只自动加载 `qcom_q6v5 / qcom_glink_smem / qrtr / qrtr-smd`，
**`qcom_q6v5_pas` 与 `ath10k_snoc` 被 blacklist**，由 `wifi-up.sh` 在 tqftpserv 就绪后显式 modprobe。

### 第 3 关：tqftpserv 在跑 + 真的喂了固件

```sh
systemctl status tqftpserv
journalctl -u tqftpserv -n 50
```

期望：日志里出现**收到 ADSP 的文件请求并成功发送**。

### 第 4 关：wlan0

**★ 先过三个前置条件**（缺任何一个，`wlan0` 都不会出现，而且**不报任何错**）：

```sh
for u in tqftpserv rmtfs pd-mapper; do printf '%-10s %s\n' $u "$(systemctl is-active $u)"; done
cat /sys/class/remoteproc/remoteproc0/state    # ★ modem(MPSS)：必须是 running
dmesg | grep -c 'crash detected in modem'      # 不该持续增长（每 ~40 秒 +1 就是 rmtfs 没工作）
```

> ★★ **真正要 `wlanmdsp.mbn` 的是 modem DSP，不是 ADSP**。DTB 里 MPSS 没有 auto-boot，
> 没有任何服务会主动启动它 → 必须显式 `echo start > /sys/class/remoteproc/remoteproc0/state`
> （`wifi-up.sh` 现在会做）。而 `rmtfs` 又要 modem 的 rproc fd，所以顺序是
> **modem 先起 → 再拉 `rmtfs`/`pd-mapper`**。详见 `docs/root-cause.md` §10.8。

```sh
ip link show wlan0
dmesg | grep -iE 'ath10k|wlfw|wcn3990|board'
```

### 第 5 关：联网（★ 2026-10-18 起：NetworkManager + 2.4G）

**主路径是 NetworkManager**，档案随 payload 落到
`/etc/NetworkManager/system-connections/560-wifi.nmconnection`
（SSID `560`、`psk changeme123`（示例值）、`band=bg` 锁 2.4G、`autoconnect=yes`）。
开机后 NM 自动连，不用做任何事；`wifi-up.sh` 负责把整条链拉起来
（tqftpserv → **启动 modem** → `rmtfs`/`pd-mapper` → ADSP → `ath10k_snoc`，见 §10.8），
然后等 NM 连上、必要时 `nmcli con up 560`。

```sh
nmcli -t dev status | grep wlan0            # 期望 connected
nmcli -t -f NAME,AUTOCONNECT con show       # 期望只有 560 是 yes
ip -4 addr show wlan0
ping -c3 192.168.31.1
ping -c3 223.5.5.5
```

> ★★ **绝对不要**再 `systemctl enable --now wpa_supplicant@wlan0`，
> 也不要用 `systemd-networkd` + `/etc/systemd/network/25-wlan0.network` ——
> 那会和 NM 抢 wlan0（两个 supplicant、两个 DHCP 客户端），把已经连上的
> wlan0 弄掉。payload 里 `25-wlan0.network` 已改名 `.unused`，
> 只在**没有 NM** 的 rootfs 上才由 `wifi-up.sh` 启用。
>
> ★ 关于 **5G（SSID `560_5G`）**：连接**不成功，已定案暂停**。原因见
> `docs/root-cause.md` §10 —— 那个 SSID 在 ch44，CN 域里是 `[RADAR]`（DFS），
> STA 侧握手完不成（我们自己的 5G 发射是好的：ch149 自建 AP 被 PC 和另一台手机
> 都看到了）。**要让 5G 通，只要把路由器的 5G 信道从 ch44 改到 149~165（非 DFS）**，
> 与手机侧无关。

`payload/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` 现在写的是 2.4G `560`，
但那个服务在设备上是 **masked** 的，这份文件只是"万一有人手工起它"的兜底。

---

## 6. 已知坑 / 不要做的事

1. **不要 `fastboot erase dtbo` / `erase vbmeta`** → ABL 直接 Load Error。
2. **不要 `fastboot reboot`**（会被拦），用 `fastboot continue`。
3. **不要 `load fs3:\Image`**，只能直接执行 `fs3:\Image`（`startup.nsh` 里已是正确写法）。
4. **改 DTB 只刷 `Image` 没用** —— 必须重编 edk2 并刷 `boot-cepheus.img`。
5. **DTB 里 `firmware-name` 一个都不能少** —— 少了 `qcom_q6v5_pas` 直接 probe 失败。
6. `qcom,calibration-variant` 填不存在的名字不会失败（会回退），但也不会帮你匹配；
   现在填的是 `Xiaomi_raphael`。
7. **`-Werror=strict-prototypes`**（见 §4.3 坑 3）—— 换编译器版本时可能又冒出来，
   解法一样：`KCFLAGS=-Wno-error=strict-prototypes`。
8. **`yes | make xxx` 和 `tar | grep -q` 这类管道 + `set -o pipefail`** → 假失败
   （141 / SIGPIPE，见 §4.3 坑 4）。
9. **`make kernelrelease` 的时机**（见 §4.3 坑 5）。
10. **boringssl 走 googlesource 会卡死**（见 §4.1）—— 必须配那条 `insteadOf`。
    **不配的话 `git submodule update` 会中断，`edk2-platforms`/`SimpleInit`/`EFI_Binaries` 全空。**
11. **`CONFIG_REMOTEPROC` 只能 `=y`**（见 §4.3 坑 1）。编完一定核一遍
    `tar tzf out/mods.tar.gz | grep qcom_q6v5_pas.ko`。
12. **符号名 `RPMSG_QCOM_GLINK_SMEM`**（见 §4.3 坑 2）—— 写错会静默丢失。
13. 交接文档里"rootfs 被污染"的说法**不是** wlan0 消失的原因（证据见 §1.2/§1.3）。
14. 手机**没有网络**，所以设备上不能 `apt install` 任何东西 ——
    所有东西必须通过 FAT / initramfs payload 投递。
15. USB/RNDIS/NCM 路线是用户明确放弃的，不要再回头。
16. **payload 版本号就是"解包开关"**：initramfs 的 `init` 会比对 rootfs 上的
    `/etc/wifi-cfg.ver` 和镜像里 `@PAYLOADVER@`，**一样就跳过解包**（这样保住了
    rootfs 上的手工修改，重启不会白干）。反过来说：**改了仓库 payload 不会自动上机**，
    必须 bump 版本号 + 重刷 Image 才会生效。
17. **`wpa_supplicant@wlan0` 与 `25-wlan0.network` 不能和 NetworkManager 并存**：
    同时开会变成两个 supplicant + 两个 DHCP 客户端抢 wlan0（2026-10-18 的坑）。
    现在：`wpa_supplicant@wlan0` 已 `mask`、`25-wlan0.network` 已改名 `.unused`。
18. **往 WSL 同步一定要"镜像式"**：`tar xf` **不会删除** WSL 侧多出来的旧文件，
    旧 `25-wlan0.network` 就是这样一直活在 WSL 树里，最后被 05 的硬校验逮住、
    整个构建中断。用 `rsync -a --delete --exclude=/out`。
19. **`wlanmdsp.mbn` 必须是手机自带厂商版**（4054436 B /
    md5 `a84629fea38d647dff0dd74154ae30d1`）：linux-firmware 那份（3725044 B）
    会让 modem 每 ~42 秒崩一次、`wlan0` 根本不出现。而且**只有
    `/lib/firmware/qcom/sm8150/` 那一份有用**，ath10k 目录下那份换什么都没用。
20. **5G（`560_5G`）连不上是路由器信道问题**，不是手机问题：该 SSID 在 ch44，
    CN 域是 `[RADAR]`(DFS)，STA 侧握手完不成。手机自己 5G 发射正常
    （ch149 自建 AP 被 PC / 另一台手机看到）。**把路由器 5G 信道改到 149~165 即可**。
21. **同芯自环（自己起 AP，再用同一个 phy 的 sta 去连）在这颗芯片上不可能成功**：
    固件会抑制自身 vdev 之间的收发（自建 AP 已 `Set beacon`、`COMPLETED`，
    同 phy 的 sta 全信道真扫也扫不到它）。**不要用自环做判据。**
22. **★★ 不要把 USB 串口写进 `console=`**（`console=ttyGS0,115200`）：
    userspace 的 `/dev/console` 取最后一个 `console=`，于是内核 + systemd 日志全往
    USB gadget 串口写；PC 侧没人读 COM 口时发送缓冲灌满 → **写控制台阻塞 → 整机冻结**。
    实测表现：`systemd-analyze blame` 头一行 `9min … dev-sda31.device`，同一秒
    dbus/logind/usb-net/ttyGS0 超时齐发（dbus 第二次尝试 1 秒就成功），
    然后 **dbus 超时把 NetworkManager 的依赖作业带崩 → NM 永不启动 → wlan0 DOWN**。
    救砖能力由 `serial-getty@ttyGS0`（自动登录）+ initramfs 兜底 shell 提供，**不依赖
    这个 console=**。已在 `06-make-kernelfat.sh` 里去掉。
23. **启动超时别用默认 90 秒**：payload 里的
    `/etc/systemd/system.conf.d/10-timeouts.conf` 把 `DefaultTimeoutStartSec` 放宽到
    300 秒。原因同上：dbus 一旦超时，NM 的**依赖作业失败不会被重试**，WiFi 就没了。
    `wifi-up.sh` 里还加了"NM 不活跃就主动 `systemctl start NetworkManager`"。
24. **`wlan0` 被 `systemd-networkd` 抢走的自愈**：`systemd-networkd` **不做 WPA2**（靠
    `wpa_supplicant@wlan0` 单元，而它被 mask 了）。一旦 `/etc/systemd/network/25-wlan0.network`
    被启用过，它就会一直霸占 `wlan0` → 症状是 `NetworkManager=active` 但 `wlan0` 没有连接、
    网络不可达。payload 解包**只覆盖不删除**，所以旧文件不会自己消失；现在 `wifi-up.sh`
    在 NM 分支里会主动把它 `mv` 回 `.unused`。
25. **这台机 warm reboot（Linux 里 `reboot`）会落在 fastboot**，需要 PC 侧 `fastboot continue`；
    冷启动才直接进 Linux。做"重启验收"必须先准备好 fastboot 这条路。
26. **★★ modem（MPSS）必须显式启动**：真正要 `wlanmdsp.mbn` 的是 **modem DSP**（ath10k 作者的
    原话 *sideloaded to the modem DSP via the TQFTPserv*），而 DTB 里 MPSS 没有 auto-boot，
    我们的 payload 里**没有任何东西会启动它** → modem 一直 `offline` → 没有 WLFW 服务 →
    `ath10k_snoc` 静默等到天荒地老 → **没有 `wlan0`，也不报错**。
    正确顺序（`wifi-up.sh` 已固化）：`tqftpserv` → **启动 modem** → `rmtfs` + `pd-mapper`
    （★ 必须在 modem 之后，`rmtfs` 要 modem 的 rproc fd）→ ADSP → `ath10k_snoc`。
27. **`rmtfs`/`pd-mapper` 失败会让 modem 每 ~40 秒崩一次**：症状是
    `crash detected in modem ... DOG detects stalled initialization` / `fatal error without
    message`，此时 modem **不会**去要 `wlanmdsp.mbn`，`wlan0` 不会出现。
    它们失败的原因常见就是"启动太慢/顺序不对"（`rmtfs: Failed to get rprocfd`、
    `pd-mapper: no pd maps available`）。判据速查表见 `docs/root-cause.md` §10.8。
28. **★ NetworkManager 的连接档案必须是 `0600`**：payload 里 tar 会按源文件模式带出 `0777`，
    NM 见到 group/world 可读写会**直接拒绝加载**（日志 `failed to load connection:
    File permissions (100777) are insecure`）→ `nmcli con show` 里根本没有 `560` →
    开机永远不自动连，而且 `wlan0` 会显示 `unmanaged`。NM **不会**因为后来权限变好而自动重读，
    所以打包时就要 `chmod 600`（`05-make-payload.sh` 已做），旧设备靠 `wifi-up.sh` 的
    `chmod 600` + `nmcli con reload` 兜底。
29. **"重启后既没进 fastboot 也没起 Linux" ≠ 重启没发出去**：可能是**关机**卡住了。
    modem 崩溃循环时 WiFi 操作全部超时（`wlan0: failed to remove key ... (-110)`），
    `NetworkManager.service/stop` 能拖 **12 分钟**。判断方法：读 COM5 看是不是关机序列
    （`Stopped NetworkManager` / `reboot.target`）。另外别把 `systemctl reboot` 放进
    `( ... ) &` 后台子 shell —— SSH 一断开就被 SIGHUP 杀掉，用 `systemctl reboot --no-block`。
30. **`usb-net.service` 卡 3 分钟（getty 写阻塞）**：`usb-mode.sh` 的 `ensure_console` 里
    `systemctl restart serial-getty@ttyGS0`，在**没人读 ttyGS0** 时会死等到作业超时（180 秒）；
    而这个单元是 `Before=network-pre.target` → NM/wifi-up 被一起拖后 3 分钟
    （"WiFi 3 分钟才可用"的真凶）。已修：已经 active 就不动它 / 拉起用 `start --no-block` /
    `neutralize` 的 `systemctl disable --now` 用 `timeout 10` 兜住 /
    `gadget_ok` 为真时跳过重建（顺带消掉启动中 COM 口重新枚举）。详见 `docs/root-cause.md` §10.10。
    ★ 补（usb10）：卡点其实还会从 `ensure_console` **挪到 `try_sshd`**（同一个死锁：
    `usb-net` 是 `Before=network-pre.target`，而 `ssh.service` 是 `After=network.target`，
    同步 `systemctl start ssh.service` 会互等到超时）。所以：`try_sshd` 也改成
    只查状态 + `--no-block`，并且**把 `Before=network-pre.target` 整个去掉**，
    `TimeoutStartSec` 180→45。判断迹象：**SSH 的可用时间恰好等于 usb-net 的超时时间**。
    usb10 实测：SSH +234s→**+56s**，WiFi +244s→**+63s**，usb-net 3min→**747ms**。
31. **`pd-mapper`/`rmtfs` 被 systemd 的启动频率限制永久锁死**：这两个服务必须在 modem 之后
    才能工作（`pd-mapper: no pd maps available`、`rmtfs: Failed to get rprocfd`），
    可开机时 modem 还没起来 → 它们连试 5 次 → `Start request repeated too quickly` →
    **单元永久 failed，之后连手动 `systemctl start` 都会被拒**（这才是"试过了反而更糟"）。
    已修：payload 加 drop-in（`StartLimitIntervalSec=0` + `RestartSec=10`）+
    `wifi-up.sh` 先 `systemctl reset-failed`。详见 `docs/root-cause.md` §10.11。
    usb11 实测：`systemctl --failed` **空**、`pd-mapper=active rmtfs=active`、
    SSH +56s / WiFi +70s / 关机 2s / modem 崩溃 0 次。
32. **★ 在树里手工跑 `make` 必须带全 `$M` 那串变量**（`ARCH=arm64 CC=clang LLVM=1 LLVM_IAS=1`）。
    漏掉 `ARCH=arm64` 时 kbuild 会按**宿主架构（x86）**重跑 syncconfig，把 `.config`
    整个改写成 `# Linux/x86 …`：`ARCH_QCOM` 整支符号从文件里消失。
    更阴的是 `scripts/config` 对**在 `.config` 里不存在（不可见）的符号是静默失效**的
    （不报错、退出码 0，还被 `|| true` 吞掉），于是 `--module`/`--enable` 全部白写，
    最后才由门禁报出 "CONFIG_QCOM_Q6V5_PAS 缺失"。**2026-10-18 就是这么把构建搞崩的。**
    急救：删掉 `.config` 重跑 02（会重新 `defconfig` + merge
    `arch/arm64/configs/sm8150.config`）。02 现在还有第二道门禁，新配置项没落地就
    `exit 1`，不会再带着坏配置往下编。
33. **★ 改过 `.config` 之后不能指望增量构建**：本树实测 `security/security.o`、
    `net/core/sock.o` 在配置变更后**不会重编**（仍是几小时前的旧文件，而 `.cmd` 里明明
    记着 `include/config/SECURITY_NETWORK` 这条依赖）。后果：模块用新头文件编出来、
    引用 `security_sk_clone()` 等新符号，而 `security.o` 里没有对应导出 →
    `ERROR: modpost: "security_sk_clone" [net/bluetooth/bluetooth.ko] undefined!`。
    **已固化**：02 在 `olddefconfig` 前后比对 `.config` 指纹，一变就 `make clean` 全量重编。
34. **★ 干净树上不能只写 `make modules`**：顶层 Makefile 有
    `ifeq ($(MAKECMDGOALS),modules) KBUILD_BUILTIN := $(if $(CONFIG_MODVERSIONS),1)`，
    我们没开 `MODVERSIONS` → built-in 目标一个都不编、`vmlinux.o` 不存在 →
    `WARNING: vmlinux.o is missing.` + 几万条 undefined + `modules-only.symvers` 失败。
    以前没暴露，是因为树里一直留着上一次构建的 `vmlinux.o`（增量构建不会删）。
    **已固化**：02 改成 `$M -j vmlinux modules`，并在没有 initramfs 源时先造一个占位 cpio。
35. **`ARM_GIC_V3_ITS` 关不掉，别浪费一次构建去试**：该符号没有 prompt、
    `default ARM_GIC_V3`，而且 `arch/arm64/Kconfig:128` 是
    `select ARM_GIC_V3_ITS if PCI` —— 只要开 PCI 就必然 `=y`，
    `scripts/config --disable` 会被 `olddefconfig` 直接还原。所以
    `ITS: No ITS available, not enabling LPIs`（`irq-gic-v3-its.c:5835`）
    **只能靠给 DTB 补 ITS 节点清掉**，不是配置问题。
36. **`RTC_DRV_PM8XXX` 的可见性依赖 `MFD_SPMI_PMIC`**：后者的 Kconfig 是
    `depends on MFD_SPMI_PMIC`，不满足时 `RTC_DRV_PM8XXX` 在 `.config` 里连行都不存在，
    `--enable` 静默失效（同坑 32 的机制）。本树 `MFD_SPMI_PMIC=y`，所以直接开就行。
37. **"时间一直不保留"的真因**：设备上 `rtc0 = rtc-efi`（EFI 运行时时钟读不了，
    `rtc-efi rtc-efi.0: hctosys: unable to read the hardware clock`），而 **PMIC RTC
    其实早就绑定成功了**（`rtc1 = rtc-pm8xxx c440000.spmi:pmic@0:rtc@6000`）。
    `hctosys`/`systohc` 只认 **rtc0** → 读不到也写不回 → 每次开机时间都是错的、只能等 NTP。
    修法：`CONFIG_RTC_DRV_EFI=n` + `RTC_DRV_PM8XXX=y`（PMIC RTC 升为 rtc0），
    配 `RTC_HCTOSYS=y` / `RTC_SYSTOHC=y` 读写。
38. **`chan info: invalid frequency 0 (idx 41 out of bounds)` 是长期噪音，不是开机一次**：
    usb11 实测每 **5 分钟**刷一条（16:44:43 / 16:49:43 / …）。来源是 WCN3990 固件会把
    一个 `freq=0` 的占位 chan_info 事件也发上来，而
    `ath10k_wmi_event_chan_info_*()`（`drivers/net/wireless/ath/ath10k/wmi.c:2738/2769`）
    用 `freq_to_idx()` 找不到就返回越界下标 → `ath10k_warn()`。属于固件怪癖，
    要根治得在这两个函数开头加一句 `if (!params->freq) return;`（本地补丁）。

---

## 7. 目录说明

```
wifi-bringup/
├── README.md                       ← 本文件
├── dts/
│   ├── cepheus-wifi.dtsi           ← DTB 补丁片段（带完整注释）
│   ├── sm8150-xiaomi-cepheus.dts   ← 已拼好的完整 DTS
│   └── sm8150-xiaomi-cepheus.dts.orig
├── scripts/
│   ├── 01-setup-buildhost.sh       ← 编译机装依赖（含 gettext/brotli/cmake；busybox 从 Ubuntu ports deb 取）
│   ├── apply-dts.sh                ← 把补丁合并进内核树（幂等）
│   ├── 02-build-kernel.sh          ← 配置 + Image + dtb + modules
│   ├── 03-build-edk2.sh            ← 校验 DTB + 换 FdtBlob + 编 edk2 → boot-cepheus.img
│   ├── 04-build-tqftpserv.sh       ← 拆 Debian/Ubuntu arm64 deb → tqftpserv + 依赖 + 官方 unit
│   ├── 05-make-payload.sh          ← 打包 wifi-cfg.tar.gz
│   ├── 06-make-kernelfat.sh        ← 生成 kernelfat.img（Image + payload + startup.nsh）
│   └── flash.ps1                   ← Windows 侧刷机（用 fastboot continue）
├── payload/                        ← wifi-cfg.tar.gz 的源目录
│   ├── usr/bin/tqftpserv           ← aarch64 二进制（Debian 1.2-1）
│   ├── usr/lib/tqftpserv-bundle/   ← libqrtr.so.1.0 + libzstd.so.1.5.5（按需补）
│   ├── usr/sbin/wifi-up.sh         ← 按顺序拉起 qrtr/tqftpserv/adsp/ath10k
│   ├── etc/systemd/system/         ← tqftpserv.service（官方写法）+ wifi-up.service
│   ├── etc/modules-load.d/wifi.conf / etc/modprobe.d/wifi-order.conf
│   ├── etc/NetworkManager/system-connections/560-wifi.nmconnection ← ★ 2.4G 自动连（主路径）
│   ├── etc/wpa_supplicant/wpa_supplicant-wlan0.conf   ← 兜底（服务已 mask）
│   ├── etc/systemd/network/25-wlan0.network.unused    ← 只在没有 NM 时才启用
│   └── lib/firmware/               ← wlanmdsp.mbn(厂商版) + board-2.bin(26440,实测可用) + firmware-5.bin
├── out/                            ← 编译产物（busybox 预置在这里）
├── tqftpserv/README.md             ← tqftpserv 的上游信息与依据
└── docs/
    ├── verify.md                   ← 上机验证清单 + 一键诊断
    └── root-cause.md               ← 证据存档
```
