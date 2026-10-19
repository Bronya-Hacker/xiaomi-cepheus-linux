# 证据链存档（为什么这么改）

本文记录做判断时实际看过的文件和命令输出，方便以后复核，不用再重新考古。

---

## 0. ★ 2026-10-18：卡死在 initramfs —— UFS 在板级 DTS 里是关的（现象极具误导性）

### 0.1 现象

第二轮刷完 boot+recovery 后，手机上：

* 屏幕顶上有几只企鹅（`fbcon` 起来了），下面一片内核日志；
* **日志不再滚动**，等下去也不动；
* **Windows 也扫不到 USB 设备**（`adb` / `fastboot` 都空）。

很容易误判成「时钟挂了 / 内核 panic / USB 没配好」。
（当时也确实按这个方向查过：`CONFIG_PHY_QCOM_QMP_UFS`、`EXT4_FS`、
`QCOM_INLINE_CRYPTO_ENGINE` …… 结果**全都是 `=y`，一点问题没有**。）

### 0.2 真正原因

把编出来的 DTB 解成 DTS，看根文件系统所在的 UFS：

```dts
ufshc@1d84000 {
	compatible = "qcom,sm8150-ufshc\0qcom,ufshc\0jedec,ufs-2.0";
	...
	qcom,ice = <0x61>;
	status = "disabled";      /* ←★ 就是这里 */
};
```

* `sm8150.dtsi` 里 `ufs_mem_hc` / `ufs_mem_phy` 默认都是 `status = "disabled"`；
* 上游 `sm8150-xiaomi-cepheus.dts` **一个字都没提** `&ufs_mem_hc`
  （板级支持不全，`grep -n 'ufs_mem\|ufshc\|ufsphy' sm8150-xiaomi-cepheus.dts` 结果为空）；
* 于是内核**根本没有 `/dev/sda*`**，而根文件系统（ext4 Ubuntu 24.04）就在 UFS 上；
* initramfs 里"等 rootfs"的循环等不到设备 → 超时后进 `while true; do sleep 60; done`（静默死循环）；
* USB 是**症状不是病因**：`usb0` 那个 gadget 是 userspace 用 configfs 拉起来的，没进 userspace 就没有。

### 0.3 对照基准：前人的**能启动镜像**

本机 `local-build/cepheus.dts`（前人 modify 过的 cepheus DTS）里，同一个节点是：

```dts
ufshc@1d84000 {
	...
	status = "okay";
	reset-gpios = <&tlmm 175 GPIO_ACTIVE_LOW>;
	vcc-supply  = <&vreg_l10a_2p5>;   vcc-max-microamp   = <750000>;
	vccq2-supply = <&vreg_s4a_1p8>;   vccq2-max-microamp = <750000>;
};
phy@1d87000 {   /* UFS PHY */
	status = "okay";
	vdda-phy-supply = <&vreg_l5a_0p875>;
	vdda-pll-supply = <&vreg_l3c_1p2>;
};
```

即：**前人的内核 tree 里给板级 DTS 打过"能启动"补丁，而 `dl/kernel.tar.gz` 是原版**。
把两份 DTB 都解成 DTS 逐节点对账（851 vs 851 个节点），`status` 只差 5 处：

| 节点 | 前人（能启动） | 我们（修前） | 说明 |
|---|---|---|---|
| `/soc@0/ufshc@1d84000` | okay | **disabled** | ★ 根因 |
| `/soc@0/phy@1d87000` | okay | **disabled** | ★ 根因 |
| `/soc@0/wifi@18800000` | disabled | okay | 我们有意开 |
| `/soc@0/remoteproc@17300000` | disabled | okay | 我们有意开 |
| `/soc@0/remoteproc@4080000` | disabled | okay | 我们有意开 |

修完后再对一次账：**只剩我们有意开的那 3 处**，且 UFS 两个节点的属性
（含 `reset-gpios`/`vcc-supply`/`vccq2-supply`/`vdda-phy-supply`/`vdda-pll-supply`）
与能启动版**逐属性一致**（连 dtc 分到的 phandle 数值都相同：`0x60/0x61/0x62/0x63/0x64/0x65/0x66`）。

各 regulator 的反查结果（用前人的 phandle → 节点名 → regulator-name）：

| 前人 phandle | 节点 | regulator-name | 我们 tree 里的 label |
|---|---|---|---|
| `0x62` | `…/pm8150-rpmh-regulators/ldo10` | `pm8150_l10a_2p5` | `vreg_l10a_2p5` |
| `0x63` | `/pm8150-s4-regulator`（`regulator-fixed`） | `vreg_s4a_1p8` | `vreg_s4a_1p8` |
| `0x65` | `…/pm8150-rpmh-regulators/ldo5` | `pm8150_l5a_0p875` | `vreg_l5a_0p875` |
| `0x66` | `…/pm8150l-rpmh-regulators/ldo3` | `pm8150l_l3c_1p2` | `vreg_l3c_1p2` |
| `0x5c` | `/soc@0/pinctrl@3100000` | — | `&tlmm`（GPIO 175 复位脚） |

### 0.4 修法与防复发

* `dts/cepheus-wifi.dtsi` 加了「第 0 部分 UFS」（两个节点 + 供电 + 复位脚）；
* `apply-dts.sh` 改成：只有旧版补丁（无 UFS 段）在树里时**报错退出**，不盲目再追加；
* `02-build-kernel.sh` / `03-build-edk2.sh` 都加了**编译期硬门槛**：
  解 DTB 检查 `ufshc@1d84000` / `phy@1d87000` 的 `status` 必须是 `okay`，
  不是就退出（这个坑绝不能再让它走到刷机那一步）；
* initramfs 的 init 脚本改成：**开机先打印 `/proc/partitions`**，
  等待过程中每 15 秒再打一次，超时提示里直接写明"没有 sda* = DTB 里 ufshc 不是 okay"。

> ⚠️ 另一个连带教训：`wsl-run-edk2.sh` 之类的"同步交付包"脚本如果连 `out/` 一起覆盖，
> 会把刚编好的新 DTB 用 Windows 上的旧产物冲掉，导致 03 校验时又看到 `disabled`
> （这次白编了一轮）。现在同步用 `tar --exclude=./out`。

---

## 1. DTB 是怎么送到内核手里的

### 1.1 解析交接包里的 boot 镜像

工具：本机新写的 `tools/bootimg.ps1`（Android boot image 头解析 + 全文件 FDT magic 扫描）。

```
文件：USB正常版-boot-cepheus-wifi.img（以及其它 handoff boot 镜像）
  magic            = ANDROID!
  header_version   = 1
  page_size        = 2048
  kernel_size      = 6854353
  ramdisk_size     = 1
  → 没有 boot image 自带的 dtb 区（v2 才有）
  全文件 FDT magic（0xd00dfeed）命中：
    offset 0x5f245b / 0x5f218a，totalsize = 621174
```

那 621KB 的 FDT 落在 kernel 区内（2048 .. 6856401），说明它是**追在 `Image` 尾巴上的
厂商 DTB**（内容里只有 `qcom,smem@`、`qcom,sm8150-cdp` 之类，没有 `soc@0/wifi@18800000`）。
内核不会用它。

### 1.2 那内核用的 DTB 在哪？

手机上 `/sys/firmware/devicetree/base/` 里有 `soc@0/wifi@18800000`（主线风格），
说明 DTB 是主线编译出来的。来源只可能是：

* edk2-msm 仓库里的
  `Platform/Xiaomi/sm8150/FdtBlob/cepheus/sm8150-xiaomi-cepheus.dtb`
  （旧编译机的 `rebuild-uefi-dtb.sh` 就是改这个文件然后 `./build.sh --device cepheus`）；
* 通过 UEFI 的 `LINUX_EFI_DTB_TABLE_GUID` 配置表交给 Linux。

在 edk2 镜像里扫不到第二个**未压缩**的 FDT → 它是被压缩存放的（edk2 的 FV 压缩要 brotli，
旧机器上正好报过 `BROTLI_MISSING`）。→ 不能二进制原地替换，**必须重编 edk2**。

### 1.3 结论

```
改 DTB 的正确姿势：
  改 sm8150-xiaomi-cepheus.dts
    → make dtbs → sm8150-xiaomi-cepheus.dtb
    → 覆盖 edk2 的 FdtBlob/cepheus/sm8150-xiaomi-cepheus.dtb
    → ./build.sh --device cepheus
    → fastboot flash boot boot-cepheus.img     ★ 产物是 boot 分区镜像
```

---

## 2. -517 与 WLFW 的关系

### 2.1 源码（本机上游 6.17 树，drivers/net/wireless/ath/ath10k/）

`snoc.c`：

```c
static const char * const ath10k_regulators[] = {
	"vdd-0.8-cx-mx", "vdd-1.8-xo", "vdd-1.3-rfa", "vdd-3.3-ch0", "vdd-3.3-ch1",
};
...
ret = ath10k_fw_init(ar);                     /* 1804~1814 */
ret = ath10k_qmi_init(ar, msa_size);          /* 1816 */
if (ret) {
	ath10k_warn(ar, "failed to register wlfw qmi client: %d\n", ret);
	goto err_fw_deinit;
}
ret = ath10k_modem_init(ar);
...
return 0;                                     /* probe 到这里就返回成功 */
```

* 驱动要 **5 路**电源（含 `vdd-3.3-ch1`）；DT 里没写的会变成 dummy regulator
  （日志里的 `supply ... not found, using dummy regulator`）。
* `ath10k_qmi_init()` 里做 `qmi_handle_init(..., AF_QIPCRTR)` + `qmi_add_lookup(WLFW)`。

`qmi.c`：

```c
#define ATH10K_QMI_TIMEOUT	30            /* 秒，用于单条 QMI txn */
int ath10k_qmi_init(struct ath10k *ar, u32 msa_size) {
	...
	ret = qmi_handle_init(...);           /* 1091: 需要 AF_QIPCRTR 已注册 */
	if (ret) goto err;                    /* ← -EAFNOSUPPORT 就从这里出去 */
	...
	qmi->event_wq = alloc_ordered_workqueue(...);
	...
	/* 不阻塞等 WLFW，只是注册 lookup，服务出现后回调 */
}
```

### 2.2 结论

| 现象 | 含义 |
|---|---|
| `failed to register wlfw qmi client: -517` | `-517 = EPROBE_DEFER`，来自 `qmi_handle_init` 里 `sock_create_kern(AF_QIPCRTR)` 返回 `-EAFNOSUPPORT` → **`qrtr` 模块没加载** |
| 加载 `qrtr`+`qrtr-smd`+`qcom_glink_smem` 后 `-517` 消失，但**没有 wlan0** | probe 成功了（`ath10k_qmi_init` 返回 0），但它在**等 WLFW 这个 QMI 服务的通知**，而 WLFW 一直没出现 → probe 成功、wlan0 永远不出现、也不报新错 |

**这一点很关键**：它解释了为什么"日志变干净了但 wlan0 还是没有"。
不是驱动坏了，是它一直在安静地等一个永远不会来的服务。

---

## 3. WLFW 服务从哪来

`sm8150.dtsi` 结构：

```
remoteproc@17300000  (compatible = "qcom,sm8150-adsp-pas"  → 驱动 qcom_q6v5_pas)
├── glink-edge        (label = "lpass", qcom,remote-pid = <2>)
└── ...
        ↓ rpmsg 通道 "IPCRTR"
net/qrtr/smd.c  (qrtr-smd.ko, MODULE_ALIAS("rpmsg:IPCRTR"))
        ↓
QRTR 名字服务
        ↓
ADSP 里的 WLAN 固件广播服务 "WLFW"
        ↓
ath10k_snoc 的 qmi_add_lookup 命中 → 继续初始化 → wlan0
```

* `sm8150.dtsi` 里 4 个 remoteproc（adsp/mpss/slpi/cdsp）都是 `status = "disabled"`；
  cepheus.dts 里没有一条 `&remoteproc_*` 覆写 → **ADSP 从来没被 Linux 启动过**；
* remoteproc 不起来 → glink-edge 不存在 → 没有 `IPCRTR` → `qrtr-smd` 绑不上；
* 这就对应"手机上 `/sys/class/rpmsg` 和 `/sys/bus/rpmsg/devices/` 都是空的"。

**所以：`&remoteproc_adsp` 必须开。** 这就是本次 DTB 补丁的第一件事。

---

## 4. 为什么 ADSP 起来了还不够 —— tqftpserv

WCN3990 的 `wlanmdsp.mbn` **不是 Linux 的 ath10k 加载的**，
是 **ADSP 里的 WLAN 子系统**加载的，取文件的方式是
**通过 QRTR 上的 TFTP 协议向 userspace 请求**。

佐证：

* 本机 grep 整棵内核树，**没有任何 TFTP 服务端驱动**
  （只有 netfilter 的 `nf_conntrack_tftp`，那是做 conntrack 用的，不是服务端）；
* 也就是说必须有**用户态守护进程** `tqftpserv` 应答这个请求 —— 这是
  linux-msm 项目里标准做法（Dmitry Baryshkov 在 ath10k 邮件列表里的答复）。

**这是交接包里从来没有过的环节。** 之前的尝试改了 DTB、加载了 qrtr 模块，
唯独没有 tqftpserv，所以：
ADSP（即使起来了）→ WLAN 子固件拿不到文件 → WLFW 服务不出现 → wlan0 不出现。

### 4.1 本轮补上的权威依据（三条，都是原文/源码）

**(a) ath10k 邮件列表，Dmitry Baryshkov（tqftpserv 作者）原话：**

> On WCN3990 platforms actual firmware, `wlanmdsp.mbn`, is sideloaded to the modem DSP
> via the TQFTPserv.

**(b) 整棵内核树里 grep `wlanmdsp` = 零出现。** 只有 netfilter 的
`nf_conntrack_tftp`（那是跟踪包用的，不是服务端）。→ 只能由用户态做。

**(c) `tqftpserv` 上游 `translate.c`（本轮拉了原文核对）：**

```c
#define READONLY_PATH        "/readonly/firmware/image/"
#define READONLY_FW_BASE     "/readonly/firmware/"
#define READONLY_MODEM_PATH  READONLY_FW_BASE "modem_pr"
...
#ifndef ANDROID
#define FIRMWARE_BASE        "/lib/firmware/"
#define TQFTPSERV_RW_DIR     "/var/lib/tqftpserv"
#else
#define FIRMWARE_BASE        "/vendor/firmware/"
#endif
```

| 客户端请求前缀 | 翻译到 |
|---|---|
| `/readonly/firmware/image/` | `/lib/firmware/<remoteproc 的 firmware-name 目录>/` |
| `/readwrite/` | `/var/lib/tqftpserv/` |

它会遍历 `/sys/class/remoteproc/*/firmware`，取每个 remoteproc 的 `firmware-name`
的**目录名**，依次试：

1. `/sys/module/firmware_class/parameters/path`（如果设了）
2. `/lib/firmware/updates/<目录名>/<相对路径>`
3. `/lib/firmware/<目录名>/<相对路径>`

并且**自动支持 `.xz` / `.zst`**。

**⟹ 我们的 DTB 给 ADSP 和 MPSS 都写 `firmware-name = "qcom/sm8150/xxx.mdt"`，
目录名 = `qcom/sm8150`，所以文件必须放在：**

```
/lib/firmware/qcom/sm8150/wlanmdsp.mbn
```

（两个 remoteproc 目录名相同 → 双保险。之前在别处铺的别名路径全部不需要了。）

**(d) 官方 systemd 单元（本轮从 Debian 包 `tqftpserv_1.2-1_arm64.deb` 里取出）：**

```ini
[Unit]
Description=QRTR TFTP service

[Service]
ExecStart=/usr/bin/tqftpserv        ← 不带任何参数
Restart=always
StateDirectory=tqftpserv            ← 正对应 translate.c 的 /var/lib/tqftpserv
```

**不存在 `-r` / 指定根目录的参数**；默认只读根就是 `/lib/firmware`。
之前文档里写的 `-r /lib/firmware` 是**错的**，会让服务起不来。

**(e) 二进制里内嵌的路径常量（本轮 `strings out/tqftpserv` 实测，最硬的证据）：**

```
/lib/firmware/
/readonly/firmware/image/
/readonly/firmware/modem_pr
/readwrite/
/readonly/vendor/firmware_mnt/image/
/readonly/vendor/firmware/
```

前四条正好对应上表的翻译规则；后两条是 Android（`#ifdef ANDROID`）分支的路径，
编译进 Debian 包时是关着的，只是字符串还在。

二进制身份（`file` / `readelf -d`）：

```
ELF 64-bit LSB pie executable, ARM aarch64, dynamically linked, stripped
NEEDED: libqrtr.so.1, libzstd.so.1, libc.so.6, ld-linux-aarch64.so.1
Debian tqftpserv 1.2-1  (Depends: libc6>=2.38, libqrtr1>=0.3, libzstd1>=1.5.5)
```

---

## 5. board-2.bin 的 chip-id（★ 本轮已解决）

手机上 `/lib/firmware/ath10k/WCN3990/hw1.0/`：

| 文件 | 大小 | 状态 |
|---|---|---|
| `board-2.bin` | 670 KB | 只含 qmi-chip-id **30214**，sm8150 需要 **30224** ✗ |
| `firmware-5.bin` | 60 B | 正常（桩文件，只列 ath10k 的 API 版本） |

`firmware-5.bin` 的 60 字节内容（od 出来）：

```
Q C A - A T H 1 0 K \0   7 7 01 00 00   04 00 00 00   5b be e4 a4   ...
```

magic `QCA-ATH10K`。WCN3990 的真固件跑在 ADSP 里（这就是为什么需要 `wlanmdsp.mbn`），
这个文件只是本地的一个"能力描述桩"，60 字节是对的，不要以为它坏了。

**本轮找到并随包提供的正确版本：**

Debian `firmware-atheros_20260916-1_all.deb`（清华镜像）里的
`ath10k/WCN3990/hw1.0/board-2.bin`，**893 528 字节**，`strings` 出来的
`qmi-chip-id` 全集：

```
120  140  150  30214  30224  320  4320
```

**含 30224 ✓**。同一个包还带了 `wlanmdsp.mbn`（3 725 044 B）和 `firmware-5.bin`。

已放进 `payload/lib/firmware/ath10k/WCN3990/hw1.0/`，
`wlanmdsp.mbn` 另外在 `payload/lib/firmware/qcom/sm8150/` 也放了一份（ADSP 实际取的那份）。

`qcom,calibration-variant` 匹配不到不会致命
（`ath10k_core_fetch_board_data_api_n()` 会回退到非 variant 条目），
所以补丁里填的是真实存在的 `Xiaomi_raphael`。

---

## 6. 源码树身份

`local-build/dl/kernel.tar.gz`（254,231,570 B）解出来是
`linux-v6.17.0-sm8150-379d8fe35c7ca685a650bd82fd023af0ea3f0de0`：

* `Makefile`: VERSION 6 / PATCHLEVEL 17 / SUBLEVEL 0 / EXTRAVERSION 空
* `arch/arm64/configs/sm8150.config` 里 `CONFIG_LOCALVERSION="-sm8150"`
  → `make kernelrelease` = **`6.17.0-sm8150`**（模块目录名）
* 设备集合：cepheus / raphael / nabu / oneplus-common(guacamole,hotdog) / google-flame
  → 即 **sm8150-mainline** 定制树
* `arch/arm64/boot/dts/qcom/Makefile` 第 277 行已有
  `dtb-$(CONFIG_ARCH_QCOM) += sm8150-xiaomi-cepheus.dtb`

配置机制（`scripts/kconfig/Makefile`）：

```make
all-config-fragments = $(call configfiles,*.config)
config-fragments = $(call configfiles,$@)          # ← 取的就是 arch/arm64/configs/<name>.config
cmd_merge_fragments = $(srctree)/scripts/kconfig/merge_config.sh -m $(KCONFIG_CONFIG) $(config-fragments)
%.config: $(obj)/conf
	$(call cmd,merge_fragments)
	$(Q)$(MAKE) -f $(srctree)/Makefile olddefconfig
```

→ 正确用法是先 `make ARCH=arm64 defconfig`，再 `make ARCH=arm64 sm8150.config` 合并片段。

---

## 7. 编译环境事实（已迁移到 WSL）

**旧事实（交接时的本机）：** 无 python / git / clang / gcc / dtc / make / mformat /
mcopy / 7z / docker；`wsl.exe` 存在但**一个发行版都没装**；旧编译机 `192.168.31.2` ping 不通。

**现在（本轮建成并实际用它编完了内核）：**

* 编译机 = **本机 WSL Ubuntu 24.04**（`wsl -d Ubuntu-24.04 -u root`），16 核 / 7.8 GB；
* 已装：`clang 18.1.3` / `lld` / `dtc` / `mtools`(`mformat`,`mcopy`,`mdir`) / `nasm` /
  `iasl` / `meson` / `ninja` / `python3` / `gettext`(`msgfmt`) / `brotli` / `cmake` /
  `uuid-runtime` / `depmod` / `gcc-aarch64-linux-gnu`；
* 加了 arm64 端口源（清华 `ubuntu-ports` noble/main/universe）；
* 内核树在 `/root/build/linux`，edk2-msm 在 `/root/build/edk2-msm`。

**可访问：** `gh-proxy.com`（github 代理，git/raw 都行）、清华/USTC/阿里镜像、
`mirror.postmarketos.org`、`cdn.kernel.org`。
**被封：** `github.com` / `raw.githubusercontent.com` / `git.kernel.org` /
`lore.kernel.org` / `boringssl.googlesource.com`。

---

## 8. 本轮踩到的构建坑（全部已修进脚本）

### 8.1 ★ `CONFIG_REMOTEPROC` 是 bool，用 `--module` 写会把整块砍掉

这是最坑的一个，**症状很隐蔽**：内核能编完、Image 能出，但模块包里
**没有 `qcom_q6v5_pas.ko`** → ADSP 永远起不来。

原理：

```makefile
# drivers/remoteproc/Kconfig 整个文件被 if REMOTEPROC 包着
menu "Remoteproc drivers"
config REMOTEPROC
	bool "Support for Remote Processor subsystem"      ← bool！只能 y/n
...
if REMOTEPROC
config QCOM_Q6V5_PAS
	tristate ...
```

`./scripts/config --module REMOTEPROC` 会写 `CONFIG_REMOTEPROC=m`，
kconfig 判为非法值 → `olddefconfig` 回落到 `n` → **`QCOM_Q6V5_PAS` /
`QCOM_Q6V5_COMMON` / `QCOM_RPROC_COMMON` 一起消失**。

修法：bool 的符号改用 `--enable`：

```sh
./scripts/config --enable REMOTEPROC QCOM_SCM RPMSG
./scripts/config --module QCOM_Q6V5_PAS QCOM_Q6V5_COMMON QCOM_RPROC_COMMON QRTR QRTR_SMD ...
```

并且在编之前加了**硬性门槛检查**（`CONFIG_REMOTEPROC=y` / `CONFIG_QCOM_Q6V5_PAS=m`
/ … 缺一个就直接退出，不浪费时间编）。

### 8.2 符号名别写错：是 `CONFIG_RPMSG_QCOM_GLINK_SMEM`

不叫 `QCOM_GLINK_SMEM`。写错了 `olddefconfig` 会静默把它丢掉（不报错），
表面上"配置过了"，实际模块可能是靠别的途径来的。核对方式：

```sh
grep -E '^CONFIG_.*GLINK' .config
# CONFIG_RPMSG_QCOM_GLINK=y
# CONFIG_RPMSG_QCOM_GLINK_SMEM=m     ← 模块名 qcom_glink_smem.ko
```

### 8.3 `-Werror=strict-prototypes` 会把内核编废

`scripts/Makefile.extrawarn` 里**无条件**加了：

```makefile
KBUILD_CFLAGS += -Werror=strict-prototypes
```

而 `sm8150.config` 片段把厂家触摸屏驱动
`CONFIG_TOUCHSCREEN_STM_FTS_DOWNSTREAM=y` 编了进来，它里面有

```c
struct spi_device *getClient()          /* K&R 声明，clang 18 直接报错 */
```

→ **`Image` 都出不来**。修法：

```sh
make ... KCFLAGS=-Wno-error=strict-prototypes
```

（不关 `CONFIG_WERROR`，那个开关管不到这几个 `-Werror=xxx`。）

### 8.4 `yes n | make olddefconfig` + `set -o pipefail` = 141 退出

`yes` 收不到 EOF 会吃 `SIGPIPE`（141 = 128+13）。脚本看起来"跑完了"，
其实**什么都没编**。修法：`make olddefconfig </dev/null`。

### 8.5 `make -s kernelrelease` 的时机

刚 `defconfig` 完时它打 **`6.17.0`**（漏掉 `-sm8150`），因为
`CONFIG_LOCALVERSION` 要等 `include/config/auto.conf` 生成后才生效。
而模块实际装到 `6.17.0-sm8150`。修法：

* initramfs 的 init 脚本改成**遍历 `/lib/modules/*/`** 做 depmod（不依赖这个值）；
* 打包模块时从 `include/config/kernel.release` 读真名。

### 8.6 `boringssl.googlesource.com` 被墙，clone 子模块会卡死

`edk2 → CryptoPkg/…/openssl → boringssl` 这一层走 googlesource，
连 135 秒后失败、整个 `git submodule update` 中断，
导致 `Common/edk2-platforms` / `SimpleInit` / `EFI_Binaries` 全空。
修法：

```sh
git config --global url."https://gh-proxy.com/https://github.com/".insteadOf "https://github.com/"
git config --global url."https://gh-proxy.com/https://github.com/google/boringssl".insteadOf "https://boringssl.googlesource.com/boringssl"
```

`tools/Installer` 空着**没关系**（只在 `build.sh --installer-zip` 时用，默认关）。

### 8.7 重编 Image 前必须 `rm -f usr/initramfs_data.o`

否则 initramfs 不更新（内核不会因为 cpio 变了就重新生成这个目标文件）。

### 8.8 PowerShell 5.1 读无 BOM 的 UTF-8 `.ps1` 会乱码 → 语法报错

`flash.ps1` 里全是中文，第一次直接 `-File` 跑报了一堆
`字符串缺少终止符` / `<` 被当成重定向 —— **文件语法其实是对的**，
是 Windows PowerShell 5.1 把**无 BOM 的 UTF-8** 当 ANSI 解码了。

修法：给 `flash.ps1` 写入 UTF-8 BOM（本包里已经写好了）：

```powershell
$p = '...\scripts\flash.ps1'
$c = [System.IO.File]::ReadAllText($p, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($p, $c, [System.Text.UTF8Encoding]::new($true))
```

校验语法（不执行）：

```powershell
$err = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$err)
if ($err.Count) { $err | % { $_.Message } } else { 'OK' }
```

同一类坑还有：`wsl.exe ... -- bash -c "...$( ... )..."` 里的 `$()` 会被
**PowerShell 先吃掉**。含 `$` / `|` / `()` 的命令**一律写成 .sh 文件**再 `bash <文件>`。

---

## 9. 实测到的关键事实（本轮，用来交叉验证）

### 9.1 edk2 内嵌的 cepheus DTB 是原厂未改版

```sh
dtc -I dtb -O dts Platform/Xiaomi/sm8150/FdtBlob/cepheus/sm8150-xiaomi-cepheus.dtb
```

结果（91012 字节）：

```
wifi@18800000            status = "disabled";          ← 没开
remoteproc@*             全无 firmware-name             ← q6v5_pas 会 probe 失败
vdd-0.8-cx-mx-supply …   不存在
chosen                   stdout-path = "serial0:115200n8";   ← 没有 bootargs
```

→ 必须整体换掉，而且不能二进制打补丁（edk2 里是压缩存的）。

### 9.1b ★ DTB 到底从哪来：两个 DTB，别认错（本轮查清）

edk2-msm 的 boot 镜像里有**两个** DTB，很多人会认错：

| 文件 | 大小 | 内容 | 谁用 |
|---|---|---|---|
| `Platform/Xiaomi/sm8150/FdtBlob/cepheus/sm8150-xiaomi-cepheus.dtb` | 91012（原版） | **主线风格**，有 `soc@0`、`wifi@18800000` | **Linux**（★ 要改的是这个） |
| `Platform/Xiaomi/sm8150/FdtBlob_compat/cepheus.dtb` | 621174 | 厂商风格，`model="CEPHEUS"`、`qcom,sm8150-cdp`，**没有 `soc@0`** | **ABL**（不要动） |

证据 1 —— `cepheus.fdf.inc` 里主线 DTB 是作为 FFS 文件编进 FV 的：

```
FILE FREEFORM = 25462CDA-221F-47DF-AC1D-259CFAA4E326 {
    SECTION RAW = Platform/Xiaomi/sm8150/FdtBlob/cepheus/sm8150-xiaomi-cepheus.dtb
}
```

`25462CDA-221F-47DF-AC1D-259CFAA4E326` = edk2 的 `gDtPlatformDefaultDtbFileGuid`
（默认 DTB 文件），由 `DtPlatformDxe` 装成系统 DTB。

证据 2 —— `build.sh` 收尾时把 **compat** 那个追在 boot 镜像尾部：

```sh
# platform_build_kernel()
cat tools/BootShim/BootShim.bin workspace/.../FV/SM8150_UEFI.fd | gzip -c > uefi-cepheus.img.gz
cat uefi-cepheus.img.gz Platform/Xiaomi/sm8150/FdtBlob_compat/cepheus.dtb > uefi-cepheus-kernel
```

证据 3 —— 手机开机后 `/sys/firmware/devicetree/base/soc@0/wifi@18800000` 存在
（主线风格）→ 内核拿到的是 FV 里那个主线 DTB，不是尾部 compat DTB。

**为什么扫 `boot-cepheus.img` 找不到 FDT**：`FVMAIN`（32 MB）被 LZMA 压成
`FVMAIN_COMPACT`（7 MB），再被 gzip 包进 boot 镜像 —— **双层压缩**。
要验证得扫 edk2 的中间产物 `workspace/Build/cepheus/RELEASE_CLANG38/FV/FVMAIN.Fv`
（未压缩，32 MB）。本轮扫它，命中我们打补丁的 DTB
（offset 0x1ebbacc，size 98581），且 `qcom/sm8150/adsp.mdt` /
`vdd-0.8-cx-mx-supply` / `Xiaomi_raphael` / `wcn3990-wifi` 各 1 次。03 脚本里已把这个校验自动化。

**前人（`rebuild-uefi-dtb.sh`）改的也是 `FdtBlob/cepheus/…`**，并且还往 `chosen`
注入了 `bootargs = "console=tty0 loglevel=7"` —— 那样编出来的镜像**确实能启动**，
所以本交付包的 03 脚本也照做（对齐"已知能启动"的配置）。

### 9.2 我们编出来的 DTB 已经是对的

```sh
dtc -I dtb -O dts out/sm8150-xiaomi-cepheus.dtb | grep -c qcom/sm8150/adsp.mdt   # 1
```

确认存在：`wifi@18800000 status="okay"` + 四路 `vdd-*-supply` +
`qcom,calibration-variant="Xiaomi_raphael"` +
`remoteproc@17300000 { status="okay"; firmware-name="qcom/sm8150/adsp.mdt"; }` +
`glink-edge { label="lpass"; qcom,remote-pid=<2>; }` +
`chosen/stdout-path`（本来就有的，不用补）。

### 9.3 ADSP 固件：这台手机是**拆分固件**

手机上 `/lib/firmware/qcom/sm8150/` 是 `adsp.mdt` + `adsp.b00…`，
所以 DTB 里必须写 `.mdt`，**不能写 `.mbn`**。

对照：上游 pmOS 的 nabu 用的是**单体** `qcom/sm8150/Xiaomi/nabu/adsp.mbn`（14.4 MB），
那是 linux-firmware 给的单体固件。**单体 ≠ 拆分，不能混用** ——
`qcom_q6v5_pas` 会照 `firmware-name` 原样 `request_firmware()`，
名字不匹配就是 `-ENOENT`。

`payload/usr/sbin/wifi-up.sh` 里已加开机自检：`adsp.mdt` 在不在、
是不是只有 `adsp.mbn`，都会写进 `/run/wifi-up.log`。

---

## 10. 收尾（2026-10-18）：2.4G 通了，5G 定案，配置固化进 payload

### 10.1 结论：2.4G WiFi 完全可用

| 项 | 值 |
|---|---|
| SSID / 密码 | `560` / `changeme123`（示例值，见本地配置） （BSSID `a4:a9:30:c3:5b:92`，ch7） |
| 链路 | auth → assoc → 4-way → `COMPLETED` → DHCP → DNS → 外网，`0%` 丢包 |
| 速率 / 信号 | VHT-MCS9 ~173 Mbps / RSSI −39 dBm |
| 持久化 | `/etc/NetworkManager/system-connections/560-wifi.nmconnection`（`band=bg`、`autoconnect=yes`、priority 20）；重启 NM 后 ~4 秒自动重连 |

**`wlan0` 的 MAC 是 `02:00:71:96:e3:d6`，不是问题**：驱动报的 `46:a0:3f:70:5c:49`
是 locally-administered，于是 systemd 的 `99-default.link`
（`MACAddressPolicy=persistent`）按 `machine-id`+`ifname` 又生成了一个持久 MAC。
小米路由器接受它（2.4G 关联成功），**不用修**。

### 10.2 5G（`560_5G` / ch44）连不上的真正原因 —— 在路由器侧，不在手机

证据链：

1. **手机的 5G 发射是好的**：在 ch149 起自建 AP（`cepheus5gtx`），PC 扫描能看到，
   用户另一台手机能搜到并进入"获取 IP 地址"（卡在拿 IP 是因为那个测试 AP 没跑 DHCP）。
2. **连 `560_5G`（BSSID `a4:a9:30:c3:5b:93`，5220 = ch44）时 auth 没有响应**，
   连 4-way 都进不去。
3. **CN 域下 ch36–48 全部带 `[RADAR]`（DFS）**；`iw reg set US` 也清不掉
   （global 域变成 country 98，phy 仍然 `radar detection`）。
   ch52–64 = `no IR`，ch149–165 = 非 DFS、33 dBm。

→ **STA 在 radar 信道上握手完不成**（DFS slave / CAC 那一套），这与手机射频能力无关。
**解法（完全不涉及手机）：把路由器的 5G 信道从 ch44 改到 149~165。**
已按用户要求暂停，不再投入。

### 10.3 顺便排除掉的误区：不要用"自环"验证这颗芯片

在这颗芯片上**自环（同一个 phy 上自己起 AP，再用自己的 sta 去连）物理上不可能成功**：
自建 AP 已经 `COMPLETED`、日志有 `Set beacon`，但同一个 phy 的 sta 全信道真扫也
**扫不到**这个 AP，AP 侧的 `station dump` 也没有任何 sta 痕迹。
→ 固件对自身 vdev 之间的收发做了抑制。**以后别再用自环当判据**，
要么用外部设备（PC / 另一台手机），要么直接看 `iw dev X link`。

### 10.4 固化进 payload 的清单（版本 → `2026-10-18-usb4`）

| # | 改动 | 为什么 |
|---|---|---|
| 1 | `wlanmdsp.mbn` 换**厂商版**（4054436 B，md5 `a84629fea38d647dff0dd74154ae30d1`），**只放** `qcom/sm8150/` | linux-firmware 那份（3725044 B）会让 modem 每 ~42 s 崩一次 → `wlan0` 根本不出现 |
| 2 | 删掉 `ath10k/WCN3990/hw1.0/wlanmdsp.mbn` | 那个位置**换什么都没用**（tqftpserv 只认 DTB `firmware-name` 的目录名 `qcom/sm8150`） |
| 3 | `board-2.bin` 用**实测可用**那份：26440 B，md5 `38c24167a9ba16150f07a03f4dd68218`（含 `qmi-chip-id=30224`） | 本轮所有成功（2.4G 连上、5G 发射、ath10k 探测）都是它跑出来的；厂商大包 893528 B（md5 `420356eb…`）挪到 `extras/` 备查 |
| 4 | 新增 `etc/NetworkManager/system-connections/560-wifi.nmconnection` | 2.4G 自动连的主路径（`wifi-up.sh` 每开机 `chmod 600` 一次，NM 才认） |
| 5 | `25-wlan0.network` → `25-wlan0.network.unused` | 它会让 `systemd-networkd` 与 NetworkManager **同时抢 `wlan0`**；只在没有 NM 的 rootfs 上由 `wifi-up.sh` 启用 |
| 6 | `wifi-up.sh`：删掉 `systemctl enable --now wpa_supplicant@wlan0` 和 `nmcli con add/up wifi-cepheus 560_5G`，改成"等 NM 连上（超时则 `nmcli con up 560`）" | 原来那两行**每个开机都会造出第二个 supplicant + 另一个 `autoconnect=yes` 的 5G 档案**去抢 `wlan0` |
| 7 | `wifi-up.service`：`Before=wpa_supplicant@wlan0.service` → `After=NetworkManager.service` | 保证 `nmcli` 可用；没有 NM 时是空操作 |
| 8 | `initramfs-init.sh`：解包后、`depmod` 前把 `updates/` `extra/` `weak-updates/` 挪到 `/root/stale-modules-<ver>/` | depmod 搜索优先级是 `updates > extra > weak-updates > kernel`，旧模块会盖掉刚解的新模块（就是"`struct module` 尺寸不匹配"那个坑） |
| 9 | `05-make-payload.sh` 加硬校验：payload 里出现 `25-wlan0.network`（不带 `.unused`）或 `ath10k/.../wlanmdsp.mbn` → `exit 1` | 这两样回来了就是回归 |
| 10 | `etc/wpa_supplicant/wpa_supplicant-wlan0.conf` 改成 2.4G `560` | 那个服务在设备上已 `mask`，这份文件只是手工兜底，别再指向 5G |

### 10.5 两条构建/同步的教训

* **payload 版本号就是"解包开关"**：initramfs 的 `init` 比对 rootfs 的
  `/etc/wifi-cfg.ver` 与镜像内 `@PAYLOADVER@`，**一样就跳过解包**（这样保住
  rootfs 上的手工修复，重启不白干）。所以**改了仓库 payload 不会自动上机**，
  必须 bump 版本 + 重刷 Image。
* **往 WSL 同步必须"镜像式"（`rsync -a --delete --exclude=/out`）**：
  `tar xf` **不会删除** WSL 侧多出来的旧文件 —— 旧 `25-wlan0.network` 就这样
  一直在 WSL 树里，最后被上面第 9 条的硬校验逮住、整个构建中断。
* 固件落点永远是 `usr/lib/firmware/...`：rootfs 里 `/lib` 是 → `usr/lib` 的
  **符号链接**，包里一旦出现 `./lib/` 目录项就会把符号链接顶掉，
  全系统动态程序全部 `cannot execute`。

### 10.6 ★ 被实测抓出来的大坑：USB 串口控制台会把整机冻住（启动要 9 分钟）

第一次把固化后的镜像刷进去、重启验收时：**SSH 十几分钟都不回来**，但串口（COM5）
里能看到完整的启动日志。查下去发现

```
systemd-analyze blame 的头一行 = 9min 2.287s dev-sda31.device
```

而且同一秒（13:55:40）`dbus.service` / `systemd-logind` / `usb-net.service` /
`dev-ttyGS0.device` 的启动**超时全部一起触发**，`dbus` 的第二次尝试 **1 秒就成功**
（→ 它不是坏，是"被冻住"。）后果很严重：dbus 超时 → `NetworkManager.service` 的
**依赖作业失败** → systemd 不会重试依赖失败的作业 → **NM 永远不会启动** →
`wlan0` 一直 `DOWN`（本次就是这样丢的 WiFi）。

原因：`startup.nsh` 的启动参数里原来有

```
console=tty0 console=ttyGS0,115200 loglevel=7 …
```

userspace 的 `/dev/console` 取的是**最后一个** `console=`，所以内核和 systemd 的日志
**全都往 USB gadget 串口写**；PC 侧只要没人读 COM 口，ACM 的发送缓冲就会灌满 →
printk / 写控制台 **阻塞** → 整个系统（含 systemd）停摆。时间线完全吻合：
我在 PC 上打开 COM5 读了一下，手机立刻"活"过来、SSH 随即可达。

修法（本轮已改）：

1. `06-make-kernelfat.sh` 的 startup.nsh **去掉 `console=ttyGS0,115200`**，只留
   `console=tty0`；内核日志上屏幕（fbcon）、systemd 日志进 journal，都不可能阻塞。
   **USB 串口的救砖能力没有丢**：rootfs 有 `serial-getty@ttyGS0`（自动登录）+
   `autottyGS0.service`，initramfs 里也还有兜底 shell。
2. payload 新增 `etc/systemd/system.conf.d/10-timeouts.conf`：
   `DefaultTimeoutStartSec=300`（`DefaultTimeoutStopSec=180`）—— 宁可某个单元慢
   5 分钟，也不要让 dbus 超时把 NetworkManager 的依赖作业带崩。
3. `wifi-up.sh`：发现 NM 不活跃时**主动 `systemctl start NetworkManager`**。
   原来的 networkd 兜底其实**无效**：`systemd-networkd` 自己不做 WPA2，它依赖
   `wpa_supplicant@wlan0` 单元，而那个单元正是被我们 mask 掉的；现在只有
   "根本没有 NetworkManager 的 rootfs"才走那条路，并且会先 `unmask`
   `wpa_supplicant@wlan0` 再启用 `25-wlan0.network`。

### 10.7 收尾（usb6）：networkd 抢 `wlan0` 的自愈，以及 warm reboot 会进 fastboot

**症状**：刷上 usb5 之后第一次启动，`NetworkManager=active` 但 `wlan0` **没有任何连接**、
`ping` 报 `Network is unreachable`。

**原因**：更早那版 `wifi-up.sh` 的"NM 不活跃 → networkd 兜底"分支，在 `dbus` 超时那次
被触发过，于是把 `/etc/systemd/network/25-wlan0.network` 从 `.unused` **启用了**。
而 `systemd-networkd` 自己不做 WPA2（它靠 `wpa_supplicant@wlan0` 单元，那个单元被我们
mask 了），于是 networkd 一直霸占 `wlan0` → NM 连不上。**注意：payload 解包是"只覆盖不删除"，
所以那张旧的 `.network` 不会因为新版 payload 只带 `.unused` 就消失。**

**修法**（usb6）：`wifi-up.sh` 的 NM 分支里加自愈 —— 只要 NM 在跑，发现
`/etc/systemd/network/25-wlan0.network` 存在就 `mv` 回 `.unused`（networkd 立刻释放
`wlan0`，紧接着的 NM 等待 / `nmcli con up 560` 兜底就能连上）。同时
`wifi-up.service` 的 `TimeoutStartSec` 180 → 300（要给"拉起 NM 30s + 等连 90s"留余地）。

**另外记住这个设备行为**：**从 Linux 里 `systemctl reboot`（warm reboot）会落到 fastboot**，
不会直接进 Linux，必须 `fastboot continue`（或 `fastboot flash recovery` 后再 `continue`）；
而**冷启动**（长按电源/断电重开）会正常走 ABL → UEFI → `startup.nsh` → Linux。
所以"重启验收"必须在 PC 侧准备好 fastboot 那条路。

### 10.8 ★★ 跨启动不稳定的真凶：modem 没人启动 + `rmtfs`/`pd-mapper` 失败（usb7）

**现象**：同一份镜像，有时候一开机 `wlan0` 就在并自动连上 `560`；有时候**完全没有 `wlan0`**，
而且不报任何新错（`ath10k_snoc` 加载完之后静默等待 WLFW，`iw dev` 空的）。

**排查结论（2026-10-18 实测定案，三环相扣）**：

1. **真正"要 `wlanmdsp.mbn`"的是 modem DSP（MPSS），不是 ADSP。**
   ath10k 作者原话是 *sideloaded to the modem DSP via the TQFTPserv*；实测 `tqftpserv`
   收到的请求路径是 `/readonly/firmware/image/wlanmdsp.mbn`，触发点就是**modem 启动**。
2. **DTB 里 MPSS 没有 auto-boot，我们的 payload 里也没有任何东西启动它。**
   `qcom_q6v5_pas` probe 时只把 ADSP 拉起来（`remoteproc1: powering up adsp`），
   `remoteproc0`(modem) 长期 `offline`。之前几次能用，是别的路径（手动 `echo start`、
   modem 崩溃自恢复）恰好把它带起来的 —— 所以表现出"时好时坏"。
3. **`rmtfs` 依赖 modem 的 rproc fd**：modem 没起来时它报 `Failed to get rprocfd` 失败退出；
   `pd-mapper` 报 `no pd maps available`。这两个都失败后，modem 的 PD 固件没人给它定位，
   于是报 **`DOG detects stalled initialization`、每 ~40 秒 `fatal error without message` 崩一次**，
   而且**永远不会向 `tqftpserv` 要 `wlanmdsp.mbn`** → WLFW 服务不出现 →
   `ath10k_snoc` 的 `qmi_add_lookup(WLFW)` 永远不命中 → 没有 `wlan0`。
4. 驱动整条链的上游仍然是**启动慢**（`console=ttyGS0` 阻塞，见 10.6）：慢启动把
   `rmtfs`/`pd-mapper`（以及 `dbus`/NM）拖到超时失败，而 systemd 不会重试。

**实测有效的修复顺序**（已固化进 `wifi-up.sh`）：先手工验证：拉起 `rmtfs`/`pd-mapper` 再
`stop/start` modem，**+4 秒就出现 `wlan0`**，紧接着 `tqftpserv` 收到 modem 的请求、
ath10k 完成 `qmi chip_id 0x30224 / fw_version 0x3003015e / htt-ver 3.70`，modem 崩溃计数停在 #24。

```
qrtr 模块 → tqftpserv → 启动 modem（echo start > remoteproc0/state）
         → 拉 rmtfs + pd-mapper（★ 必须在 modem 之后，否则 rmtfs 拿不到 rprocfd）
         → 启动 ADSP → modprobe ath10k_snoc
         → 20 秒还没 wlan0：重启一次 modem（再等 25 秒）→ 还不行才重启 ADSP
```

**判据速查表**：

| 现象 | 含义 |
|---|---|
| `wlan0` 不存在、ath10k 加载后无任何新日志 | WLFW 没出现：先查 modem 是否 running、`rmtfs`/`pd-mapper` 是否 active |
| `crash detected in modem ... DOG detects stalled initialization` 每 ~40 秒 | `rmtfs`/`pd-mapper` 没工作，modem 读不到自己的 PD 固件 |
| `rmtfs: Failed to get rprocfd` | `rmtfs` 启动时 modem 还没 running（顺序错了） |
| `pd-mapper: no pd maps available` | `pd-mapper` 拿不到 PD 映射（慢启动/顺序错都常见） |
| `tqftpserv` 日志出现 `/readonly/firmware/image/wlanmdsp.mbn opened` | 链条走通了，接着等 WLFW → `wlan0` |

### 10.9 ★ usb8：`wlan0` 出来了但 NM 不接 —— 档案权限 + 关机卡 13 分钟

上到 usb7 之后 `wlan0` **确实出现了**（`wifi-up.log` 完整走出新链条、modem 崩溃计数 = 0），
但 `nmcli` 显示 `wlan0:wifi:**unmanaged**`，连接列表里**根本没有 `560`**。两个新坑：

**坑 1：NM 的连接档案必须是 0600，`777` 会被直接拒绝加载。**

```
NetworkManager[683]: <warn> keyfile: load: "/etc/NetworkManager/system-connections/560-wifi.nmconnection":
                             failed to load connection: File permissions (100777) are insecure
```

payload 打包时 tar 按**源文件模式**带出 `0777`，NM 启动时看到 group/world 可读写 →
**拒绝加载**（不是警告，是整个档案不见）→ 没有 `560` 档案 → 永远不会自动连。
而且 **NM 不会因为后来权限变好而自动重读**，`wifi-up.sh` 里原来的 `chmod 600` 跑在 NM 之后，
完全来不及。

修法两处（都在 usb8）：
* `05-make-payload.sh`：打包前 `chmod 600 .../system-connections/*.nmconnection`（治本）；
* `wifi-up.sh`：发现 NM 里没有 `560` 时，`chmod 600` + **`nmcli con reload`**（治旧设备）。

实测：`chmod 600` + `nmcli con reload` 之后，`560` 立刻出现在 `nmcli con show` 里，
**4 秒内 `wlan0:wifi:connected:560`**，`192.168.31.177/24`、网关/外网/DNS 全 0% 丢包。

**坑 2：关机/`reboot` 卡 13 分钟（不是启动慢）。**

一次"看起来又卡住了"的重启，串口尾巴给出真相 —— 它卡在**关机**：

```
Job NetworkManager.service/stop  running (11min 57s / 13min 24s)
Job wpa_supplicant.service/stop  running (11min 57s / 13min 24s)
[ 3738.071716] wlan0: failed to remove key (0, a4:a9:30:c3:5b:92) from hardware (-110)
  OK  Stopped NetworkManager.service ... Reached target reboot.target
```

`-110` = 超时：modem 在崩溃循环时，所有 WiFi 操作（去 key / 关接口）都超时 → NM 的 stop
作业拖了 12 分钟才结束。**这解释了之前两次"重启后没进 fastboot 也没起 Linux"**：
不是启动慢，是**关机慢**（那两次我误判成"重启没发出去"）。
modem 健康之后这个现象应当消失（usb7 的 `10-timeouts.conf` 也把 stop 上限压到 180 秒）。

### 10.10 ★ usb9：`usb-net.service` 卡 3 分钟 = getty 写阻塞（启动可用性收尾）

usb8 把 WiFi 做成"开机自动连"之后，`systemd-analyze blame` 的头一名变成了
**`3min 157ms usb-net.service`**。根因在 `usb-mode.sh` 的 `ensure_console()`：

```sh
systemctl restart serial-getty@ttyGS0.service   # ← 卡满 180 秒
```

**ttyGS0 上没人读的时候，getty 往这个 tty 写会阻塞**，`restart` 的作业就挂住了，
直到 `usb-net.service` 的 `TimeoutStartSec=180` 超时。`/tmp/usb-mode.log` 正好停在
`usb0 就绪` 那一行之后（`ensure_console` 是它的下一步）——证据闭合。

而这个单元是 **`Before=network-pre.target`**，于是 **NetworkManager / wifi-up 一起被拖后 3 分钟**：
实测 `wifi-up` 15:48:37 才启动，正好在 `usb-net` 15:48:35 超时**后 2 秒**，
`ath10k` 189 秒才初始化。⇒ **"WiFi 3 分钟才可用"根本不是 WiFi 的问题，是 usb-net 拖的。**

改法（usb9）：

1. `ensure_console`：**已经 active 就不动它**；真要拉起用 `systemctl start --no-block`；
2. `neutralize` 里每个 `systemctl disable --now` 用 `timeout 10` 兜住（防同类挂死）；
3. `do_up` 加**快路径**：`gadget_ok "$mode"` 为真（initramfs 阶段已建好）就跳过重建 ——
   顺带消掉"启动过程中 COM 口消失 / NCM MAC 变掉"，那正是 unbind/rebind UDC 触发的重新枚举。

顺带给 `wifi-up.sh` 加了**屏幕自检**：结束时往 `/dev/tty0` 打一段 ASCII 状态
（payload 版本 / SSID / IP / modem / rmtfs）—— 用户不接串口也能在手机屏幕上看到结果
（fbcon 的 TER16x32 没有 CJK 字形，所以只能用 ASCII）。

#### usb10 补一环：卡点从 `ensure_console` 挪到了 `try_sshd`（同一个死锁）

usb9 上机后 `usb-net.service` **仍然卡满 180 秒**，日志显示
`gadget 已就绪 → 跳过重建` 之后只多打了一行 `usb0 就绪` 就停住了 —— 卡点往后挪到了
`try_sshd()` 的 `systemctl start ssh.service`。原因是**同一个顺序死锁**：

* `usb-net.service` 里有 `Before=network-pre.target`；
* `ssh.service` 是 `After=network.target`（排在 `network-pre.target` 之后）；
* 于是 `try_sshd` 里那句**同步** `systemctl start ssh.service` 与自己的依赖互等，
  一直等到 180 秒超时。

铁证：那次启动 **SSH 直到 +234 秒才可用**，而 `usb-net` 恰好在 +233 秒超时结束 ——
SSH 根本不是"网络没起来"，是被这个死锁锁着。（`try_sshd` 是"救砖兜底"逻辑，
本轮反而成了主要阻塞源。）

usb10 两条一起改：

1. `try_sshd` 只查状态、需要时 `systemctl start --no-block`，**绝不阻塞**；
2. `usb-net.service` **去掉 `Before=network-pre.target`**（只留 `Wants=`）——
   这样它将来再慢也拖不动 NetworkManager / wifi-up；`TimeoutStartSec` 180 → 45。

> 教训：**一个 `Before=<网络 target>` 的 oneshot 单元里，任何阻塞式 `systemctl`
> 都可能把自己连同整个网络栈一起锁住。** 这类单元里只用读数查询或 `--no-block`。

**usb10 实测（同一台机、同一"关机→冷启动"口径）**：

| 指标 | usb9 | usb10 |
|---|---|---|
| 关机耗时（reboot → SSH 断） | 2 s | 2 s |
| SSH 可用 | **+234 s** | **+56 s** |
| WiFi 连上 `560` | **+244 s** | **+63 s** |
| `usb-net.service` | `3min 190ms`（failed） | **747 ms**（成功） |
| `systemd-analyze blame` 头名 | `usb-net.service` 3min | **`wifi-up.service` 12.2 s** |
| 失败单元 | `usb-net` | 只剩 `pd-mapper`（见 10.11） |

⇒ **"开机 3 分钟才联网"这个问题彻底消掉了**：现在 1 分钟内手机自动上网。

### 10.11 ★ usb11：`pd-mapper` 被 systemd 自己的启动频率限制永久锁死

`/usr/local/lib/systemd/system/pd-mapper.service` 只有 `Restart=always`，**没有解除 systemd
的启动频率限制**。开机时 modem 还没起来，它只报

```
pd-mapper[556]: no pd maps available
```

就 `exit 1`；连试 5 次（每次 `Duration: 10ms`）后 systemd 判定

```
pd-mapper.service: Scheduled restart job, restart counter is at 5.
pd-mapper.service: Start request repeated too quickly.
pd-mapper.service: Failed with result 'exit-code'.
```

单元进入 **failed，而且此后不再重试** —— 连 `wifi-up.sh` 里那句 `systemctl start pd-mapper`
都会被 systemd 用同一句话直接拒掉。于是 modem 全程拿不到 PD 固件定位表。
（`rmtfs` 是同一个毛病，只是它侥幸成功过一次，所以看起来像"pd-mapper 单点问题"。）

**真正阴的地方**：问题不是"它起不来"，而是"它在 modem 之前**试过了**"——
和 §10.8 的"顺序错了就永远起不来"是同一类，只是这次的锁是 systemd 自己上的。

usb11 的改法：

1. payload 新增 drop-in `etc/systemd/system/{pd-mapper,rmtfs}.service.d/10-wait-modem.conf`：
   `StartLimitIntervalSec=0` + `Restart=always` + `RestartSec=10` —— 不设频率限制，
   modem 一就绪自然就成功；
2. `wifi-up.sh` 拉起它们之前先 `systemctl reset-failed`（治旧设备/旧 rootfs）；
3. `05-make-payload.sh` 自检加了两条**硬门禁**：drop-in 必须在包里、
   NM 档案权限必须 `600`（否则 `exit 1`，不再让坏包出门）。

> 教训：**任何"要等另一个异步单元先就绪"的常驻服务，都必须解除 systemd 的启动频率限制**
> （`StartLimitIntervalSec=0`），否则它会在依赖就绪之前把重试次数用完，然后永久躺平 ——
> 而且要等到有人去看 `systemctl --failed` 才会发现。

**usb11 实测（冷启动，与 usb10 同口径）**：

```
systemctl --failed            → （空）            ← 第一次做到没有任何失败单元
/run/wifi-up.log              → pd-mapper=active rmtfs=active
systemd-analyze blame 头三名 → wifi-up.service 20.2s / rmtfs.service 10.3s / pd-mapper.service 10.3s
```

`rmtfs`/`pd-mapper` 各 10 秒正是 `RestartSec=10` 的一次重试：
**开机先试一次（modem 还没起来，失败）→ 10 秒后 modem 已就绪 → 成功**，
完全按设计走。其余：SSH **+56 s**、WiFi **+70 s**、关机 **2 s**、modem 崩溃 **0 次**。

### 10.12 ★ usb12：第①项"内核日志报错清零"第 1 轮（不改 DTB 的全做了）

#### 做法：每条噪音都追到源码/配置，不接受"看着像噪音就关掉"

usb11 冷启动基线：**7 err / 19 warn / WARN-BUG 0**。逐条定位：

| 现象 | 级别 | 根因（源码／配置） |
|---|---|---|
| `rtc-efi rtc-efi.0: hctosys: unable to read the hardware clock` | err | `CONFIG_RTC_DRV_EFI=y` 先注册成 rtc0，而 UEFI 运行时没有可读 RTC（见 §10.13） |
| `q6asm-dai …:dais: No dais found in DT` + `probe … failed with error -22` | err | `q6asm-dai.c` 用 `of_get_child_count(dev->of_node)` 要求 DTS 有 `dais` 子节点；我们没接音频那一整套 |
| `Warning: unable to open an initial console.` | err | initramfs 里 `/dev` 是空的，而内核跑 `/init` **之前**就要 open `/dev/console` |
| `systemd-journald.socket: SO_PASSSEC failed: Operation not supported` ×3 | warn | `net/core/sock.c`：`IS_ENABLED(CONFIG_SECURITY_NETWORK)` 为 0 时直接返回 `-EOPNOTSUPP` |
| `Configuration file … marked executable / world-writable` ×6 | warn | payload 的 `/etc/**` 是从 Windows 侧拷进去的，带上了 0777 |
| `pstore: backend 'ramoops' already in use: ignoring 'efi_pstore'` | warn | `EFI_VARS_PSTORE=y` 与我们的 `ramoops` 撞车 |
| `chan info: invalid frequency 0 (idx 41 out of bounds)` ×3（**之后每 5 分钟还刷 1 条**） | warn | `ath10k/wmi.c`：固件会发 `freq=0` 的占位 chan_info 事件，`freq_to_idx()` 返回越界下标 |

改法（全部在**不动 DTB** 的范围内）：

1. `CONFIG_RTC_DRV_EFI=n` + `CONFIG_RTC_DRV_PM8XXX=y`（根因见 §10.13）
2. cmdline 加 `modprobe.blacklist=q6asm_dai`，payload 再加 `etc/modprobe.d/blacklist-audio.conf`（双保险）
3. initramfs root 里 `mknod dev/console c 5 1`、`dev/null c 1 3`
4. `CONFIG_SECURITY_NETWORK=y`（无 LSM 时这些 hook 都是空实现，但 `sock.c` 那条 `IS_ENABLED` 就能过）
5. `05-make-payload.sh`：`find "$STAGE/etc" -type f -exec chmod 644`，nmconnection 单独 600
6. `CONFIG_EFI_VARS_PSTORE=n`
7. 新建**本地补丁机制**（`patches/*.patch` + 02 里幂等套用）：
   `patches/0001-ath10k-downgrade-freq-0-chan-info-warn.patch` —— 只把那条 `ath10k_warn` 降成
   `ath10k_dbg`（默认 `debug_mask=0` 不打印，需要时用
   `/sys/module/ath10k/parameters/debug_mask` 打开），**行为完全不变**

顺带在本轮暴露并已固化的构建链问题 → README 坑 32–37（手敲 `make` 漏 `ARCH` 会把 `.config`
冲成 x86、配置变更后 built-in 目标不重编、干净树不能只 `make modules`、`ARM_GIC_V3_ITS`
被 `select` 强制关不掉、`scripts/config` 对不可见符号静默失效）。

#### 实测（usb12 冷启动，同口径）

```
dmesg --level=err   →  2         （usb11: 7）
dmesg --level=warn  →  6         （usb11: 19）
WARN / BUG / gpf / panic / oops / Call trace  →  全部 0
systemctl --failed  →  空
rtc0                →  rtc-pm8xxx c440000.spmi:pmic@0:rtc@6000   （usb11 是坏的 rtc-efi）
wlan0 MAC           →  02:00:71:96:e3:d6   （NM 的 cloned-mac-address 生效）
q6asm_dai           →  lsmod 0 条
SSH +56 s / WiFi +69 s / 关机 2 s      （usb11: +56 / +70 / 2 —— 没有回退）
```

#### 剩下 8 条（2 err + 6 warn）的归属

- `qcom-qmp-combo-phy 88e8000.phy: failed at devm_regulator_bulk_get`（err）
- `aux_bridge … error -ENODEV: failed to acquire drm_bridge`（err）

  两条都在**显示/DP 路径**上，根因是 DTB 里的供电器/桥节点 → 归第②项（显示）那一轮。

- `ath10k_snoc: supply vdd-3.3-ch1 not found, using dummy regulator`（warn）→ DTB 缺这个供电器
- `ath10k_snoc: invalid MAC address; choosing random`（warn）→ 需要 DTB 的 `local-mac-address`
  加内核侧 `of_get_mac_address` 补丁（NM 已经把用户态 MAC 固定住了，这条只剩内核日志）
- `ITS: No ITS available, not enabling LPIs`（warn）→ 只能在 DTB 补 ITS 节点（配置项被 `select` 强制，见坑 35）
- `KASLR disabled due to lack of seed`（warn）→ UEFI 没提供 RNG，**故意保留**（为此关 KASLR 得不偿失）
- `clk: Not disabling unused clocks`（warn）→ 是我们自己 cmdline 里的 `clk_ignore_unused`，**故意保留**
- `systemd[1]: Configuration file /run/systemd/system/netplan-ovs-cleanup.service is marked world-inaccessible`（warn）
  → netplan 的 systemd generator 在 `/run` 里生成的文件权限不对，**不是我们的 payload**；
  下一轮用 payload 里一个 mask 符号链接消掉

另外那 3 条 `modprobe@efi_pstore.service`（Starting/Finished/Deactivated）是 **info 级**，
systemd 的正常行为，不在 err/warn 统计里。

> 教训：**噪音要按"根因归属"分类，而不是"能关就关"**。本轮 7 条里有 4 条是配置/权限/构造问题
> （可以当场做掉），3 条是驱动+固件的交互（要打补丁），剩下 8 条里有一半在 DTB 里 ——
> 硬扛着不动 DTB 去做只会把真正的问题藏起来。

### 10.13 ★ 为什么"时间一直不保留"：坏的 EFI RTC 抢了 rtc0

usb12 之前每次开机系统时间都是错的（只能等 NTP 纠正），根因不是"没有 RTC"，而是**RTC 编号**：

```
/sys/class/rtc/rtc0   name=rtc-efi      rtc-efi.0                          ← 坏的，读不出来
/sys/class/rtc/rtc1   name=rtc-pm8xxx   c440000.spmi:pmic@0:rtc@6000       ← 其实早就绑定成功了
```

`drivers/rtc/hctosys.c` 的 `rtc_hctosys()` 只对**第一个注册成功的 RTC（rtc0）**做
"读 RTC → 设置系统时间"，`RTC_SYSTOHC` 的 11 分钟回写同样只写 rtc0。而 rtc0 是
`CONFIG_RTC_DRV_EFI=y` 带来的 `rtc-efi`，UEFI 那边根本没有可读的运行时时钟 →
`hctosys: unable to read the hardware clock`，于是：

- **开机**：读不到 → 系统时间停在 1970/错值，直到 NTP 同步；
- **运行中**：`systohc` 把时间写回 rtc0（坏的）→ 白写；
- **PMIC RTC（rtc1）**：从头到尾没人读也没人写 → 它的值一直是
  `1970-01-03`（这正是"从没被写过"的证据）。

改法：`CONFIG_RTC_DRV_EFI=n` + `CONFIG_RTC_DRV_PM8XXX=y`（BSP 的 PMIC RTC 升为 rtc0），
配合本来就 `=y` 的 `CONFIG_RTC_HCTOSYS=y` / `CONFIG_RTC_SYSTOHC=y`。

usb12 实测：`rtc0 = rtc-pm8xxx c440000.spmi:pmic@0:rtc@6000` ✓。
（首次开机 RTC 里还是旧垃圾值，NTP 同步后由 `systohc` 在 ~11 分钟内写回真时间，
**从下一次开机起时间就是对的**。）

### 10.14 ★ usb13：第①项收尾 + 触摸（终于要动 DTB 的那一轮）—— 顺手纠正 3 个误判

这一轮的目标是把 usb12 剩下的 8 条（2 err + 6 warn）清掉，同时把"必须改 DTB"的东西
一次带上（RTC / WiFi 收尾 / 触摸）。**三个"看起来是 DTB 问题、其实不是"的误判，
都是在动手之前被实测挡下来的**，单独记下来，免得以后再踩。

#### A) 先纠错：两条 err 都不是"DTB 缺供电器"

**1. `qcom-qmp-combo-phy 88e8000.phy: failed at devm_regulator_bulk_get`**

板子的 `&usb_1_qmpphy` 上游 cepheus dts **早就给了两路电**：
`vdda-phy = <&vreg_l3c_1p2>`、`vdda-pll = <&vreg_l5a_0p875>`，而驱动
（`phy-qcom-qmp-combo.c` 里 sm8150 用的是 `sc8180x_usb3dpphy_cfg`）**总共只要这两路**。
如果照"缺供电器"去补 DTB，就会把**真实电源轨改错**（比如把 0.875V 换成 0.8V）。

设备上的实测证据：

```
/sys/bus/platform/devices/88e8000.phy/driver -> .../drivers/qcom-qmp-combo-phy   ← 绑定成功了
/sys/class/phy/phy-88e8000.phy.0   /sys/class/phy/phy-88e8000.phy.1               ← 两个 phy 都注册了
```

→ 那条 err 只是**开机 0.22s 时的一次 `-EPROBE_DEFER`**（RPMH regulator 还没注册好），
而这段代码把"延迟探测"也按 err 打出来了：

```c
ret = devm_regulator_bulk_get(dev, num, qmp->vregs);
if (ret) { dev_err(dev, "failed at devm_regulator_bulk_get\n"); return ret; }
```

改法：**不动 DTB**，用仓库补丁 `0003-qmp-combo-dev-err-probe-regulators.patch` 换成
`dev_err_probe()`：`-EPROBE_DEFER` 不再打日志，真错误照旧上报（这也是上游后来的写法）。

**2. `aux_bridge.aux_bridge.aux_bridge.0: error -ENODEV: failed to acquire drm_bridge`**

`aux_bridge` 这个辅助设备**是 PHY 自己注册的**（`phy-qcom-qmp-combo.c` 里
`drm_aux_bridge_register(dev)`），它是 DRM 桥链里的**占位符**。它 probe 时用
`devm_drm_of_get_bridge()` 去找"下一级桥"，而本机 `displayport-controller@ae90000`
是 `status = "disabled"`（后面 E 段有取证）→ 根本没有下一级 → `-ENODEV`。

`aux-bridge.c` 本身已经用了 `dev_err_probe()`，但 `-ENODEV` 不等于 `-EPROBE_DEFER`，
所以照样按 err 打。改法：补丁 `0004-drm-aux-bridge-quiet-on-enodev.patch` ——
`-ENODEV` 时降成 info（"这条桥链没有下一级，用不上我"），其它错误维持原等级。
正解当然是第②项把显示栈做出来，但现在先把"事实"和"噪音"分开。

**3. 还有一个"同款"的、随机出现的：`ufshcd-qcom 1d84000.ufshc: ufshcd_get_vreg: vccq2 get failed, err=-517`（err）**

这是换上新 Image 后的第一次冷启动才冒出来的（`-517` 就是 `-EPROBE_DEFER`）：
UFS 在开机 0.27 秒时去取 `vccq2` 那路电，此时 PMIC 的 regulator 还没注册好 → 延迟探测 →
而 `drivers/ufs/core/ufshcd.c` 的 `ufshcd_get_vreg()` 同样是 `dev_err()`，
把"完全正常的一次延迟探测"打成了 err（系统最后照常从 UFS 启动，说明它自愈了）。

→ 补丁 `0007-ufs-dev-err-probe-vreg.patch` 换成 `dev_err_probe()`。

★ 这一类"**defer 被当成 err 打**"的噪音，现在已经抓到三处：qmp-combo（0003）、UFS（0007）、
以及结构性 `-ENODEV` 的 aux_bridge（0004）。**以后再看到 err 级日志，第一步先看 errno 是不是 -517**，
基本就能判断是不是同一类问题（真故障不会自愈，defer 会）。

#### B) RTC：把"写时间"这条路也打通（§10.13 的下半篇）

§10.13 解决的是"**读**"（rtc0 从坏的 rtc-efi 换回 PMIC RTC）。"**写**"还没通：
`rtc-pm8xxx` 的 `set_time` 只有两条岔路 ——

```c
if (rtc_dd->allow_set_time)          /* 来自 DT 属性 allow-set-time */
        __pm8xxx_rtc_set_time();     /* 直接写 RTC 寄存器 */
else
        pm8xxx_rtc_update_offset();  /* 把 (目标时间 - RTC 硬件时间) 存进 nvmem cell */
```

两条都没配 → 走 offset 那条时 `devm_nvmem_cell_get(dev, "offset")` 拿不到 cell →
`-ENODEV`（busybox `hwclock -w` 报 Invalid argument）。

★ 采用**同门机型 sm8150-xiaomi-nabu / raphael 的现成写法**：给 `&pm8150_rtc` 配
`nvmem-cells = <&rtc_offset>` + `nvmem-cell-names = "offset"`，并把 `&pm8150_sdam_2`
打开、加一个 `rtc-offset@bc` cell（`reg = <0xbc 0x4>`，这两个数字直接从 nabu 抄）。
理由是它**不需要写 RTC 寄存器**（不受"RTC 可能被 modem/ABL 占着"影响），
而且兄弟机型上已经是可复现的先例。（想换成直写，把这两行换成 `allow-set-time;`。）

**还有一个只有读内核代码才知道的坑**：`RTC_SYSTOHC`（每 11 分钟回写 RTC）要求
userspace 通过 `adjtimex()` 上报"时间已同步" —— `kernel/time/ntp.c` 的 `ntp_synced()`
看的是 `STA_UNSYNC`。`systemd-timesyncd` **不报**这个状态，所以内核那条自动回写
**在本机永远不触发**，RTC 只会停在它上次被写入的时刻。

→ payload 里补了 userspace 的兜底单元（不依赖内核那条路）：

```
/usr/sbin/rtc-save.sh                 busybox hwclock -w -f /dev/rtc0
etc/systemd/system/rtc-save.service   开机 + 关机/重启前各存一次（ExecStart/ExecStop）
etc/systemd/system/rtc-save.timer     开机 2 分钟后一次，之后每 30 分钟一次
```

（rootfs 上没有 util-linux 的 `hwclock`，所以 payload 顺带带一份静态 busybox 到
`/usr/local/bin/busybox` 当兜底。）

#### C) 触摸：最大的两个坑是**属性前缀**和**总线变体**

厂商 DTB 里 `fts@49` 的属性全是 `fts,*`，而这棵树里的驱动
（`drivers/input/touchscreen/fts_touch/`，ST 新版 FTM5）**只认 `st,*`**：

| 驱动真正读的 | 厂商 DTB 里写的 |
|---|---|
| `st,irq-gpio`（★ 中断就是从这来的） | `fts,irq-gpio` |
| `st,reset-gpio` | `fts,reset-gpio` |
| `st,regulator_dvdd` / `st,regulator_avdd`（字符串，再拿去 `devm_regulator_get()`） | `fts,pwr-reg-name` / `fts,bus-reg-name` |
| `st,max-coords = <1079 2339>`（驱动默认是 1440x2560-1，不写就全屏错位） | `fts,x-max` / `fts,y-max` |
| `st,disable-auto-fw-update` | —（厂商驱动另有开关） |

照抄厂商节点 = 驱动一个属性都不认（中断拿不到、坐标错、调节器找不到）。

另外两个只有读代码才知道的点：

- **驱动不读 DT 的 `interrupts`**：probe 里是
  `info->client->irq = gpio_to_irq(info->board->irq_gpio)` → 真正决定中断的是
  `st,irq-gpio = <&tlmm 122 IRQ_TYPE_LEVEL_LOW>`（厂商的 `0x2008` 低 4 位 = 8
  = `IRQ_TYPE_LEVEL_LOW`，对得上；`interrupts` 属性只让 i2c 核心也认一下）。
- **总线变体是 Kconfig 的互斥 choice**：`TOUCHSCREEN_STM_FTS_DOWNSTREAM_I2C` 与 `_SPI`。
  继承下来的 `.config` 里选的是 **SPI=y**，而手机上触摸挂 I2C
  （SE17 = `i2c@c80000`，`fts@49`）→ SPI 版的驱动在 i2c 总线上**永远 match 不到设备**。
  02 脚本里已强制切成 I2C 变体，并在门禁里加了"SPI 必须不被选上"的反向检查。
- **这个驱动是旧签名，编 I2C 变体的那一刻会直接编译不过**：
  `i2c_driver.probe` 从 6.3 起去掉了第二个参数
  （`include/linux/i2c.h` 现在是 `int (*probe)(struct i2c_client *client);`），
  而这份从厂商树带出来的驱动还是
  `fts_probe(struct i2c_client *client, const struct i2c_device_id *idp)` →
  `-Wincompatible-function-pointer-types` 报错。
  之所以以前没暴露：SPI 变体那条分支的 `fts_probe(struct spi_device *)` 恰好就是新签名。
  → 补丁 `0005-touch-fts-i2c-probe-new-signature.patch` 删掉那个从头到尾没被用过的参数。
  （§教训：**切总线变体 = 换一整条编译路径**，别以为只是改个 .config 开关。）
- **同一条路径上还有第二处**：`fts_proc.c` 里散步着一句 SPI 专属的
  `if (getClient() && (getClient()->mode & SPI_3WIRE) == 0)`
  —— `struct i2c_client` 根本没有 `mode` 成员，`SPI_3WIRE` 也没定义
  → `no member named 'mode'` / `use of undeclared identifier 'SPI_3WIRE'`。
  它位于\"用户态请求刷固件\"的路径上，而 I2C 下\"不是 3-wire\"恒为真，
  所以补丁 `0006-touch-fts-proc-i2c-spi3wire-guard.patch` 用
  `#ifdef ..._I2C` 把 I2C 分支写成直接置位、SPI 分支原样保留。
  （这两处是**切变体后暴露的全部**编译错误：clang 把 fts.c / fts_proc.o、
  fts_lib 全编一遍，剩下只有两条警告。）

固件：驱动会 `request_firmware("st_fts_f1.ftb")`，但**整机翻遍了根本没这个文件**
（vendor 只有 `stm_fts_production_limits.csv`，system / persist 也没有）。
IC 里烧的是原厂固件、CRC 正常 → 用 `st,disable-auto-fw-update` 关掉自动升级
（否则每次开机都会刷一条 request_firmware 失败）；那个 limits csv 顺手投进 payload 备用。

硬件侧逐条照抄厂商：`touch_vddio_vreg`（`regulator-fixed`，TLMM gpio84，
`startup-delay-us = 4000`，`enable-active-high`，`regulator-boot-on`——
与厂商 `disp_vddio_vreg` 一字不差）、`avdd` = PM8150L LDO1（`vreg_l1c_1p8`）、
以及三个 pin 配置（`ts_active` / `ts_int_suspend` / `ts_reset_suspend`，数值照抄）。
★ 这个驱动**不用 pinctrl**（只 include 了 consumer.h），所以把厂商的"有效态"
直接命名为 `default`，由设备核心在绑定时**自动应用**，正好把
drive-strength=8 / pull-up 用上。

#### D) 剩下那些 warn 的归属

| warn | 本轮处理 |
|---|---|
| `ath10k_snoc: supply vdd-3.3-ch1 not found, using dummy regulator` | DTB 加 `vdd-3.3-ch1-supply`。厂商 icnss 节点里**只有** `vdd-3.3-ch0`，ch1 在 cepheus 上做进了同一路 3.3V → 复用 ch0 的 `vreg_l11c_3p3` |
| `ath10k_snoc: invalid MAC address; choosing random` | DTB 加 `local-mac-address = [02 00 71 96 e3 d6]`（与 NM 档案的 `cloned-mac-address` 同值）+ 补丁 `0002`（上游 ath10k 只认固件 MAC，这里在它无效时才用 `of_get_mac_address()` 兜底） |
| `netplan-ovs-cleanup.service is marked world-inaccessible` | payload 里放一个 `ln -sf /dev/null` 的 mask（`/etc/systemd/system/` 优先级高于 `/run/systemd/system/`，systemd 连加载都不会加载 /run 那份） |
| `ITS: No ITS available, not enabling LPIs` | **决定不动**：厂商 DT 里没有 ITS 节点，也查不到 SM8150 的 ITS 地址证据；乱加一个地址错了只会引入**新的**报错。保留并记录 |
| `KASLR disabled due to lack of seed` | 故意保留（UEFI 没给 RNG；为此关 KASLR 得不偿失） |
| `clk: Not disabling unused clocks` | 故意保留（我们自己的 cmdline 里有 `clk_ignore_unused`） |

#### E) 本轮顺手取证、写进结论的

- `display-subsystem@ae00000` 与 `displayport-controller@ae90000` 在编出来的 DTB 里
  都是 `status = "disabled"`。手机屏幕现在能显示，靠的是 **edk2 GOP + 内核 efifb**
  （`/dev/fb0` + fbcon，cmdline 有 `fbcon=font:TER16x32`）。
  → DTB 片段里**绝不许**打开 dp/display/dpu/dsi（会顶掉 efifb → 黑屏），
  03 的门禁里有反向检查（"display-subsystem 不许是 okay"）。
- 标签可用性（编译期不会报未定义）：`pm8150_rtc` / `pm8150_sdam_2` 在 `pm8150.dtsi`；
  `vreg_l1c_1p8` / `vreg_l3c_1p2` / `vreg_l11c_3p3` / `vreg_l5a_0p875` / `vreg_l18a_0p8`
  都在 cepheus dts 自己的 `apps_rsc` 段里。
- 触摸驱动所在的 `i2c@c80000`（SE17）在 edk2 DTB 里处于
  `geniqup@cc0000` 之下，wrapper 与 i2c 节点都要 `okay`（03 的门禁查这两条）。
- TLMM **gpio84** 在 cepheus dts 里没人用（`gpio-reserved-ranges = <0 4>, <126 4>`
  也不含它）→ 触摸供电那个 fixed regulator 不会跟别人抢 GPIO。
- 触摸**固件**：`/vendor/firmware/` 里只有 `stm_fts_production_limits.csv`；
  `/vendor/firmware_mnt` 是空的；`/dev/sde54`（3.4G，system）里也没有 `.ftb`。
  → "没有固件可升级"是这台机器的**事实**，不是我们漏拷了文件。

### 10.15 ★ 2026-10-19：显示"白嫖"ABL、触摸彻底打通、自写手机 GUI（版本 → `2026-10-19-ui1`）

第②项（显示/触摸/背光 + 轻量 GUI）落地。这一轮最大的收获不是"配对了某个属性"，
而是**三个被现象带偏很久的误判**被逐一证伪。

#### A) 显示：没有 DRM 也能出画面，靠的是"别断电"

- **根因**：内核 genpd 起来后把 **MMCX** 等域按"没人引用"断电了，而这些域是
  bootloader（ABL）**已经配好**的 DSI/DPU 流水线赖以工作的电源 → 流水线一停就黑屏。
  补丁 `0008-genpd-keep-bootloader-power-domains.patch`：core.c 不再对"启动时已开启"
  的域断电 + rpmhpd.c 对 `!pd->enabled` 直接 continue。
  dmesg 里可自查这一行：`PM: genpd: keeping mmcx powered (bring-up)`。
- **为什么不需要 msm DRM/panel 驱动**：ABL 把 DSI 面板配成命令模式并持续刷帧，
  内核只要**从 framebuffer 取到那块内存**就能显示 → `efifb`（`/dev/fb0`）+ fbcon 足够。
- **因此三条禁令**（写进 03 脚本门禁、已实测）：
  1. DTB 里 `display-subsystem` / `displayport-controller` / dpu / dsi **必须保持 disabled**
     （一旦 okay，efifb 被顶掉 → 黑屏）；
  2. cmdline 保留 `initcall_blacklist=disp_cc_sm8250_driver_init`；
  3. 将来若真上 msm DRM，必须先删上面这条 blacklist、并重新处理 MMCX/时钟接管。
- **教训**：一开始"没有 `/dev/dri` 所以显示不了"是个错误前提。**先确认像素到底有没有到屏**，
  再决定要不要写驱动。

#### B) 电源键"一按就关机"不是死机：是 `systemd-logind` 的默认行为

- `HandlePowerKey=poweroff` 是 logind 默认值，短按电源键 = 干净关机（屏幕直接黑），
  现象上很像"卡死/重启"，白白浪费了很多排查时间。
- 修法（双保险，都已在 payload 里）：
  - `/etc/systemd/logind.conf.d/50-phoneui.conf`：`HandlePowerKey=ignore`；
  - GUI 自己对 `pm8941_pwrkey` 做 `EVIOCGRAB`，把电源键变成"确定/回主页"。

#### C) 触摸真正的坎：**拿不到 DMA 通道 = 整个 probe 失败**（不是 FIFO 兜底能救的）

- `i2c-qcom-geni.c` 的 probe 会读 `GENI_IF_DISABLE_RO.FIFO_IF_DISABLE`，
  SM8150 的 SE **硬件把 FIFO 接口禁掉了**（值=1）→ 走 DMA；此时 `dma_request_chan()`
  失败 probe 直接返回 `-EPROBE_DEFER`，**没有退回 FIFO 的分支**。
- 所以只加 `fts@49` 没用：必须让 `&gpi_dma2` 是 `okay`（`cepheus-extra.dtsi` §3c-2），
  否则 `i2c-0` 上**根本不会出现** `0-0049`，现象是"驱动没加载"（极具误导性）。
- 03 脚本已加门禁：DTB 里 `gpi_dma2` 必须是 `okay`。
- 跑通的证据：`i2c-0 上 0-0049: fts`、`FW VER=0060 / SVN 2260`、注册 `event2 (fts)`、
  `msmgpio 122` 中断计数随手指增长。

#### D) ★★ "底部导航栏点不动"的真凶：GUI 里一行坐标夹紧（`min(W-1, …)` 用在了 y 上）

- 原始事件抓包（`touchraw2.py`，带时间戳 + 每包 slot/tid/x/y 汇总）证明
  **驱动侧完全正常**：协议 B、单指、靠 `ABS_MT_TRACKING_ID` 区分按下/抬起，
  上报序列 `KEY(330,1) → TRACKING_ID → POSITION_X → POSITION_Y → PRESSURE → SYN_REPORT`，
  坐标与屏幕 1:1（点左下角"返回"= `(163, 2297)`，点"主页"= `(488, 2281)`）。
  ⚠️ 注意：这颗 IC 的**上报里没有 `ABS_MT_SLOT` 事件**（单指时 slot 恒为 0，不重复上报），
  所以"abs 掩码里没有 bit47"是正常现象，不是驱动缺陷——**别照掩码判断协议**。
- 真正的 bug 在我自己的 GUI 里：
  ```python
  def _px(self, v, s):
      return max(0, min(W - 1, int(v * s)))   # ← x、y 共用，y 也被夹到 1079
  ```
  `H=2340`，于是**所有 y>1079 的触摸（含整个底部导航栏 y≥2220）都被压成 1079**，
  永远进不了导航栏分支 → "导航栏按不了"。修法：x 夹 `W-1`、y 夹 `H-1`。
- 顺带抓出第二个 bug：`ClockApp.tap()` 里把**字符串属性** `ui.toast` 当函数调用
  （应为 `ui.toast_msg`）→ `TypeError: 'str' object is not callable` → GUI 崩溃自动重启，
  而重启前没关 evdev fd → `EVIOCGRAB` 不释放 → 新实例报
  `grab fail pm8941_pwrkey [Errno 16] Device or resource busy`。
  已在重启路径上加 `cleanup()` 统一关 fd。
- **方法论收获（以后都这么干）**：`/dev/uinput` 可用 → 自造一个虚拟多点触摸设备
  （`uitap.py`，靠 FIFO `/run/uitap.fifo` 下发 `tap x y [ms]` / `swipe` / `hold`），
  GUI 改成同时监听**多个**触摸设备，就能**全自动**回归触摸链路（不用人反复戳屏幕）：
  注入 `tap 163 2290` → 日志出现 `touch down x=163 y=2290` → `tap … cur=时钟` → 回主页。
  （踩坑：`/dev/uinput` 的 EINVAL 是因为新内核要求先 `write()` 传统 `struct uinput_user_dev`
  标记 setup 完成，才允许 `UI_DEV_CREATE`；另外 FIFO 要用 `<>` 打开，否则守护进程会被阻塞到
  第一个写入者出现，GUI 重启时枚举不到虚拟设备。）

#### E) 自写"手机壳" GUI（`phoneui`）：零依赖、直写 `fb0`

- 不用 GNOME/KDE/Phosh（没有 `/dev/dri`，也没必要）：直接对 `/dev/fb0`
  （1080x2340、stride 4320、32bpp，小端 BGRA，A=255）做 mmap，PIL 画图，启动时 `dmesg -n 1`。
- 10 个应用：时钟 / 系统 / 显示 / 日志 / 网络 / 终端 / 文件 / 设置 / 触摸 / 关于；
  底部导航栏三键（返回 / 主页 / 应用，**画图形而不是字符**，否则中文变豆腐块）；
  点按 + 拖动滚动；`/run/phoneui.fifo` 远程控制；`--shot` 截图。
- 亮度：**没有背光驱动**（面板亮度由 ABL 那边的 DSI 命令控制）→ 软件调光：
  对 RGB 做缩放（`fblib.BRIGHTNESS` / `blit(..., brightness=)`）。
- systemd 单元 `phoneui.service`（`Restart=always`）。
  ★ 坑：unit 里**绝对不要**写 `Conflicts=/After=getty@tty1` —— 实测那样开机时
  unit 根本不会被拉起，journal 里一条记录都没有。getty 在 tty1 打一行登录横幅无害
  （GUI 每帧全屏重绘）。
- 固化的文件（payload 里）：`root/phoneui/{phoneui.py,fblib.py,uitap.py}` +
  `etc/systemd/system/phoneui.service`（05 脚本已把它加进 enable 列表）。

> ↑ 注：**本节的 GUI 路线已于同日被用户叫停**（见 §10.16 F：改当服务器用），
> phoneui 文件仍留在 payload 里但**不再自动 enable**。

### 10.16 ★★★ 2026-10-19（续）刷完 ui1 之后**整机失联**：payload 的目录权限把 `/root` 改成了 0777

这是本项目最危险的一次自锁事故 —— 而且它**不是内核/驱动问题，是打包问题**。
刷入 ui1（`dd` 进 `/dev/sda28`）重启后，`ssh root@169.254.42.1` 只剩一句话：

```
root@169.254.42.1: Permission denied (publickey,password).
```

#### A) 现象与现场

| 通道 | 事故后状态 |
|---|---|
| 串口 COM5 / `ttyGS0` | ✅ 能进，但只是 `umeko`（普通用户，无 sudo） |
| `ssh umeko@…` | ✅ 能进（`/home/umeko` 权限没被改） |
| `ssh root@…` | ❌ `Permission denied (publickey,password)` |
| `ls -ld /root / /etc /usr /usr/sbin` | ❌ 全是 `drwxrwxrwx` |

#### B) 根因链（三个环节，缺一不可）

1. **payload 里的目录条目是 0777**：`payload/` 是从 Windows（drvfs）同步过来的，
   目录一律 `drwxrwxrwx`；而 05 脚本开头是 `cp -a "$HERE/payload/." "$STAGE/"`
   —— `cp -a` **连 `payload/` 目录自己的模式也一起带到 `$STAGE`**。
2. **GNU tar 解压会把"已经存在的目录"也 chmod**：这点最容易误判 —— 直觉是
   "解压只会 chmod 新建的目录"，实际上 `tar xf` 遇到目录条目会**无条件** `chmod`，
   哪怕目标早就存在。于是包里的 `./root/`（0777）→ 手机上的 `/root` 变 0777；
   `./`（0777）→ `/` 也变 0777。
3. **sshd `StrictModes`**：只要 home 目录对 group/other 可写，**公钥认证直接拒绝**。
   客户端侧看不到任何原因，服务端 journal 里才有一行
   `Authentication refused: bad ownership or modes for directory /root`。

#### C) 为什么这次特别难查（以及几条走不通的路）

- root 是*唯一*的管理入口 → 事故直接把门反锁；串口进得去，但只有普通用户。
- 常规提权全都堵死：`umeko` 不在 `sudo`/`adm` 组；没有 root 密码（所以 `su`/polkit 都不行）；
  `/etc/sudoers.d`、`/etc/pam.d`、`/etc/ssh` 这些**目录**本身还是 0755（不可写）。
- `/etc/ssh/sshd_config` 是 0644 **可读**，改它也没用：sshd 只在**启动时**读配置，
  重启 sshd 又要 root。
- 纠结过"把 `/root` 改名再建一个"：`/` 是 0777 确实能 rename，但新建出来的目录
  **属主是 umeko**，sshd 的 owner 检查照样过不去（需要 uid 0）。
- 最后是靠"**利用同一个事故的副作用**"出去的：

#### D) 救援实证：`/etc` 也是 0777 → 塞一个 uid=0 的账号，用 `su` 提权

思路：`/etc` 可写 → 可以**替换 `/etc/passwd`**（该文件世界可读，能先读出来再追加）。

```sh
# ① 追加一个 uid=0 的救援账号；哈希**直接写进 passwd 第 2 字段**
python3 - <<'PY'
import crypt, os
h = crypt.crypt('Mi9Rescue!2026', crypt.mksalt(crypt.METHOD_SHA512))
l = [x for x in open('/etc/passwd').read().splitlines() if not x.startswith('svc:')]
l.append('svc:' + h + ':0:0:rescue:/root:/bin/bash')
open('/tmp/passwd.new','w').write('\n'.join(l) + '\n')
os.chmod('/tmp/passwd.new', 0o644); os.replace('/tmp/passwd.new', '/etc/passwd')
PY

# ② 用 pty 喂密码给 su（su 从 /dev/tty 读密码，普通管道喂不进去）
python3 - <<'PY'
import os, pty, sys, time, select
pid, fd = pty.fork()
if pid == 0: os.execv('/bin/su', ['su','svc','-c','chmod 700 /root; stat -c%a /root; id'])
buf=b''; sent=False; t0=time.time()
while time.time()-t0 < 60:
    r,_,_ = select.select([fd],[],[],1)
    if fd in r:
        d = os.read(fd,4096)
        if not d: break
        sys.stdout.write(d.decode('utf-8','replace')); buf += d
        if not sent and b'assword' in buf:
            os.write(fd, b'Mi9Rescue!2026\n'); sent=True
PY
```

**能成立的两个关键点（都值得记下来）**：

- **没有动 `/etc/shadow`**：umeko 读不了它，盲写=毁掉所有账号哈希。而 glibc/PAM 的行为是
  "**`/etc/shadow` 里没有这个用户时，回退用 `/etc/passwd` 的哈希**"（`pam_unix` 的经典回退），
  实测确实生效 —— 所以救援账号只需要写 `passwd`。
- **`su` 必须在 pty 里跑**：它不读 stdin，只认 `/dev/tty`（`ssh` 非交互会话里没有 tty）。

拿到 root 后立刻 `chmod 700 /root` → `ssh -i mi9_key root@…` **当场恢复**，
然后清理（`grep -v '^svc:' > /etc/passwd` in-place 写回、`chown root:root`、
把 35 个 0777 目录统一 `chmod go-w`）。

#### E) 根治（三层保险，全部已固化进仓库）

1. `05-make-payload.sh`：
   - `chmod 755 "$STAGE"` —— ★ **`find … -mindepth 1` 不包含目录自身**，
     而 tar 里 `./` 那一条的权限就是 `$STAGE` 自己的（`cp -a` 带过来的 0777）；
   - 所有目录 755、`/root` **700**、`/root/**` 文件 600（`.sh` 给 700）、
     `system-connections` 700；
2. **打包期回归测试**：直接从 tar 里读权限，不是 `drwxr-xr-x`（`./`）与
   `drwx------`（`./root/`）就 `exit 1`，坏包不出门；
3. `initramfs-init.sh`：`switch_root` 之前**再强制**一次
   `chmod 700 /mnt/root/root` + 顶层目录 755（防"哪天真被人改回去"）。

#### F) 顺手做掉的**服务器化**（版本 → `2026-10-19-srv1`）

用户决定**放弃 GUI、把手机当服务器/命令行用**，于是本轮：

- `phoneui.service` 不再自动 enable（文件留在 payload，想要就
  `systemctl enable --now phoneui` 捡回来）；
- **电源键不再关机**：`etc/systemd/logind.conf.d/50-server.conf`
  （原 `50-phoneui.conf` 改名）+ `HandlePowerKey(LowPress)=ignore`
  —— 服务器被误碰一下就断电是不可接受的；
- **zram 2G 交换**：`zram-swap.service`（`WantedBy=swap.target` +
  `swap.target.wants` 链接）+ `sysctl.d/90-zram.conf`（`swappiness=100`）；
- **systemd 托管硬件看门狗**：`system.conf.d/20-watchdog.conf`
  ```ini
  [Manager]                 # ★★ 必须有段头，否则整段静默失效
  RuntimeWatchdogSec=60s
  ```
  ★ 坑（实测）：漏了 `[Manager]`，systemd 只打一行
  `20-watchdog.conf:5: Assignment outside of section. Ignoring.`，
  然后 `RuntimeWatchdogUSec` 一直是 `0`，**看起来"配了"其实没生效**。
  修好后 journal 有 `Using hardware watchdog 'qcom_wdt', version 0, device /dev/watchdog0`。
  （另外实测验证：故意 `open("/dev/watchdog")` 后不喂 → 约 1 分钟后手机自动复位，
  起来后一切正常、`/root` 仍是 700 —— 也就是说**下次再卡死不用跑过去长按电源**。）
- **打开 sysrq**：`sysctl.d/99-sysrq.conf`（`kernel.sysrq=1`）→ 串口上
  `BREAK` + `s`/`b` 就能同步/强重启；
- **屏蔽 rootfs 镜像自带的 Klipper 3D 打印机遗留服务**（开机实测真在跑）：
  `klipper` / `moonraker` / `crowsnest` / `nginx` / `autocanup` / `autowebssh` /
  `auto_rmi4_reload`（这个还开机就 failed），做法是在 payload 里放
  `ln -sf /dev/null /etc/systemd/system/<unit>` —— 等价于 `systemctl mask`，
  但**不需要 systemd 在跑**，解压即固化，`systemctl unmask` 随时可逆；
- **只留一套网络栈**：屏蔽 `systemd-networkd{,.socket,-wait-online}`、
  `networkd-dispatcher`、`networking`（ifupdown）、`systemd-network-generator`
  —— 之前三套同跑抢 `wlan0`；
- 清掉噪音单元：`apport*`、`motd-news.timer`、`man-db.timer`、`e2scrub*`。

#### G) 教训（写给以后的自己）

- **`tar` 解压会 chmod 已存在的目录**。任何"含目录条目"的包，都必须显式规范权限，
  并在**打包阶段**直接从 tar 里读出来做回归测试 —— 别指望解压端"只创建不修改"。
- **`find <dir> -mindepth 1` 不含 `<dir>` 自身**，而 `./` 条目的权限正是目录自己的模式；
  `cp -a src/.` 会把 `src` 的模式带过去（drvfs 上是 0777）。
- **唯一入口必须有多条救援路**。现在有三条：① 串口 `ttyGS0` + sysrq；
  ② 看门狗自动复位；③ `/etc` 可写时可"塞 uid=0 账号 + pty 里 `su`"。
- 换 sshd/`/root` 相关的任何东西，**先确认还能 SSH 进去再重启**。

### 10.17 ★ 2026-10-19（续）蓝牙 WCN3990 打通（版本 `2026-10-19-srv3`，收尾在 `srv5`）

结论先说：**BT 走 uart13（QUPV3 WRAP2 SE3，四线带流控）**，三路电映射到
`L7A(1.8) / L2C(1.3) / L11C(3.3)`，固件用 `qca/crbtfw21.tlv` + `qca/crnv21.bin`
（设备上是 `.zst` 压缩版）。最终状态：

```
hci0:  Type: Primary  Bus: UART
       BD Address: D7:E3:96:71:00:02  ACL MTU: 1024:7  SCO MTU: 240:4
       UP RUNNING
bluetoothctl show   -> Controller D7:E3:96:71:00:02 (public)  Powered: yes
bluetoothctl scan on -> 能扫到真实 BLE 设备（含 ManufacturerData）
```

#### A) 证据链：不要猜，去原厂 dtbo 里挖

手机上的原厂 `dtbo` 分区（`/dev/sde45`，33MB）还是完好的（我们只改 boot/rootfs），
它就是**最权威的板级接线表**：

```sh
dd if=/dev/sde45 of=/root/dtbo-stock.img bs=1M status=none
# Android DTBO 格式：offset 0 是 dt_table_header（magic 0xd7b7ab1e）
#   本机 1 个 entry、274034 字节、FDT magic 0xd00dfeed
python3 -c '...按 >8I 解头、按 entry 切出 .dtb...'
dtc -I dtb -O dts -o /tmp/dtbo.dts /tmp/dtbo/00-id0-rev0.dtb
```

得到三条关键信息：

1. `aliases` 里写着 `qupv3_se13_4uart = "/fragment@71"`，而 `fragment@70` 正是
   `bt_wcn3990 { compatible = "qca,wcn3990"; }` —— **BT = vendor 的 se13 = 主线 uart13**。
   （`qupv3_se12_2uart` / `serial0 = &uart2` 只是调试串口，别动它。）
2. `bt_wcn3990` 的供电 phandle 落在 `pm8150_l7(1.8V)`、`pm8150l_l2(1.304V)`、
   `pm8150l_l11(3.312V)`；主线 `hci_qca` 的 wcn3990 要 4 路
   （vddio/vddxo/vddrf/vddch0），对照小米 raphael 即
   `vddio=vddxo=L7A`、`vddrf=L2C`、`vddch0=L11C` —— 与 WiFi 节点用的三路完全相同。
3. vdd 名字/电压都能对上，才敢写 DTS（旁证：raphael/nabu/flame 三个同 SoC 板子
   的 BT 节点写法）。

#### B) 三个真坑（每个都实测过）

1. **固件名**：`btqca` 用 `soc_ver` 反推 ROM 版本（`((soc_ver & 0xf00) >> 4) | (soc_ver & 0xf)`），
   这颗芯片上报的值让驱动算成 `rom_ver=1` → 去找 `qca/crbtfw01.tlv` →
   `-ENOENT`（日志：`QCA Failed to download patch (-2)`，随后 `preshutdown_cmd failed (-56)`）。
   修法：DTS 里显式 `firmware-name = "crnv21.bin", "crbtfw21.tlv";`
   ——顺序固定（index0=nvm、index1=rampatch，见 `hci_qca.c`
   `qca_get_firmware_name`/`qca_get_rampatch_name`），raphael 也是这么写的。
2. **`local-bd-address` 必须给**：固件下载完后 `qca_check_bdaddr()`
   （`drivers/bluetooth/btqca.c`）会读芯片地址，若等于 NVM 里的默认值就置
   `HCI_QUIRK_USE_BDADDR_PROPERTY`，控制器进入 `HCI_UNCONFIGURED`。现象非常误导：
   - `bluetoothctl` → `No default controller available`
   - `btmgmt info` → `Index list with 0 items`（未配置的 index 不在正常列表里）
   - `hciconfig hci0 up` → `Can't init device hci0: Operation not supported (95)`
   - `/sys/class/bluetooth/hci0/` 只有 `reset/rfkill0`，没有 address/type/name
   修法：`local-bd-address = [02 00 71 96 e3 d7];`（和 WiFi 固定 MAC 同一套编号；
   DT 里是小端，显示出来是 `D7:E3:96:71:00:02`）。改完驱动会走
   `qca_set_bdaddr()` 把地址写进芯片，`invalid_bdaddr` 清掉 → 正常注册。
3. **改 DTB 之后要刷 boot，而 03 的产物落在 WSL 镜像目录**：
   `03-build-edk2.sh` 的 `$OUT` 是 `/root/wifi-bringup/out`，Windows 侧的
   `out/` 靠 07 回传（07 的 cp 列表里没有 `boot-cepheus.img`）。我们因此**刷过一次
   旧的 boot 镜像**，现象是"DTB 里明明有 bluetooth 节点，运行时 `/proc/device-tree`
   里却没有"。以后刷机前先比对 Windows 侧文件的 mtime/md5。

#### C) 改动清单

| 文件 | 改动 |
|---|---|
| `dts/cepheus-bt.dtsi` | 新增：`&uart13 { bluetooth { ... } }`（4 路供电、firmware-name、local-bd-address、max-speed=3200000） |
| `scripts/apply-dts3.sh` | 新增：第 3 段 apply；**片段变了会自动替换**（从标记行截断重写），不再"看到标记就跳过" |
| `scripts/02-build-kernel.sh` | apply 循环加 `apply-dts3.sh`；DTB 门禁加 uart13 okay / wcn3990-bt / crnv21.bin 等 |
| `scripts/03-build-edk2.sh` | FVMAIN 终检加 `qcom,wcn3990-bt`、`vddch0-supply` |

设备侧：`apt install bluez`（5.72）。bluez 的文件在 `/usr`，payload 解压不会删，
所以**只有重刷 rootfs 才需要重装**。

#### D) 验证（一分钟版）

```sh
cat /proc/device-tree/soc@0/geniqup@cc0000/serial@c8c000/status   # okay
dmesg | grep -i hci0        # QCA setup on UART is completed
hciconfig -a                # UP RUNNING, ACL MTU 1024:7
bluetoothctl show           # Powered: yes
timeout 10 bluetoothctl scan on   # 能列出周围 BLE 设备
```

注：开机日志里有一条 `Bluetooth: hci0: Frame reassembly failed (-84)`
（第一帧版本应答被打断），随后版本/固件都正常，**属良性**，暂不追。

#### E) 收尾（`srv4` / `srv5`，都是 payload 改动 → 必须 bump 版本才会解压）

- `mi9-status.sh`：NET 段加一行 `bt hci0 <MAC> UP RUNNING`（`hciconfig` 只用 2ms；
  没装 bluez 时退回看 `/sys/class/bluetooth/hci0` 在不在）；`top cpu` 行过滤掉
  `ps/awk/sed/bash` 自己，免得刚开机时把"`300%ps`"当成负载。
- `mi9-doctor.sh`：加蓝牙自检（`hci0` 在不在 → `UP RUNNING`），健康日志字段
  从 `wifi=…` 扩成 `wifi=… bt=up|down|absent|no-bluez`。现在一行长这样：
  ```
  2026-10-19T13:27:19+08:00 bad=0 fixed=0 temp=49C wifi=connected bt=up swap=2G disk=9% load=2.32
  ```
- 注意 payload 版本机制：`initramfs-init.sh` 只有 `rootfs 上的 /etc/wifi-cfg.ver`
  与包内版本**不同**时才解压。所以只改 `payload/` 而不 bump 版本号，
  **设备上永远不会生效**。

### 10.18 ★ 2026-10-19（续）充电与电量：PM8150B charger + fuel gauge，以及"限充"的真实做法

目标：`/sys/class/power_supply` 从空的变成能读电量/电压/电流/温度/状态，
并且能按 80% 上限停充（长期插电当服务器，满电常挂对电池不友好）。

#### A) 结论：驱动早就在主线里，缺的只是 DT 的 `status`

查 6.17 源码：

| 驱动 | 配置 | compatible | 提供 |
|---|---|---|---|
| `drivers/power/supply/qcom_smbx.c` | `CONFIG_CHARGER_QCOM_SMB2=y`（已编入） | `qcom,pm8150b-charger` | `pm8150b-charger`（USB psy） |
| `drivers/power/supply/qcom_fg.c` | `CONFIG_BATTERY_QCOM_FG=y`（已编入） | `qcom,pm8150b-fg` | `qcom-battery`（电池 psy） |

本机 DTS 本来就 `#include "pm8150b.dtsi"`，所以 `&pm8150b_charger` / `&pm8150b_fg`
两个 label 直接可用；只是这两个节点在 dtsi 里默认 `status = "disabled"`。
`pm8150b_adc`（给充电器提供 `usbin_i` / `usbin_v` 两个 IIO 通道）没有 status，
默认就是 okay —— 所以**不需要动任何寄存器地址、也不需要改内核 config**。

#### B) 新增片段 `dts/cepheus-chg.dtsi`（第 4 部分）

```dts
/ {
	battery: battery {
		compatible = "simple-battery";
		charge-full-design-microamp-hours = <3300000>;   /* 小米9 3300mAh */
		voltage-min-design-microvolt = <3400000>;
		voltage-max-design-microvolt = <4400000>;        /* 原厂 fv-max-uv=0x432380 */
	};
};

&pm8150b_fg {
	status = "okay";
	monitored-battery = <&battery>;
	power-supplies = <&pm8150b_charger>;
};

&pm8150b_charger {
	status = "okay";
	monitored-battery = <&battery>;
};
```

依据：
- 原厂 dtbo 的 `qcom,fv-max-uv = 0x432380` = **4 400 000 µV**，与 3300 mAh 电池吻合；
- 主线 **raphael / nabu / flame** 三块同 SoC 板子的写法完全一样（都是
  `monitored-battery` + `power-supplies = <&pm8150b_charger>`），照抄即可；
- `pm8150b_vbus`（OTG 输出）**没开**，因为本机暂不做 USB Host。

#### C) 实测：psy 出现了，数值也对

```text
$ ls /sys/class/power_supply/
pm8150b-charger  qcom-battery

pm8150b-charger: type=USB status=Full online=1 current_max=450000 usb_type=Unknown [SDP] DCP CDP
qcom-battery:    type=Battery status=Not charging capacity=99 voltage_now=4396228
                 current_now=0 temp=340        # 0.1C -> 34.0C
```

dmesg 只有一行 `qcom-smbx-charger c440000.spmi:pmic@2:charger@1000: Generation SMB5`，
没有报错。

两个"看起来奇怪、其实正常"的点：

1. **ICL 只有 450 mA**：因为当时插在 PC 的 USB 口上，APSD 识别为 **SDP**
   （标准下行端口，上限 500 mA）。插墙充会识别成 DCP，驱动会把 ICL 提到 1.5 A
   （`DCP_CURRENT_UA`）。写 `current_max` 会被 `smb_status_change_work` 按端口
   类型再覆盖回去（实测写 2 800 000 后被改回 375 000），**不要指望它突破端口上限**。
2. **`usb_type` 的格式**是 `Unknown [SDP] DCP CDP`，方括号里才是当前值；
   仪表盘取方括号内容显示成 `SDP`。

#### D) "限充"的真相：没有截止电压寄存器，但有 `status` 这个开关

`qcom_smbx` 暴露的属性只有
`MANUFACTURER/MODEL_NAME/CURRENT_MAX/CURRENT_NOW/VOLTAGE_NOW/STATUS/HEALTH/ONLINE/USB_TYPE`，
**没有** `charge_control_end_threshold` / `constant_charge_voltage`。
但 `STATUS` 是可写的：

```c
case POWER_SUPPLY_PROP_STATUS:
	return regmap_update_bits(chip->regmap, chip->base + USBIN_CMD_IL,
				  USBIN_SUSPEND_BIT, !val->intval);
```

即：写 `Unknown`（枚举值 0）→ `!0 = 1` → **置 USBIN_SUSPEND_BIT**，停止从 USB 取电；
写 `Charging`（1）→ 清位，恢复。实测：

```text
before:    charger=Full       online=1  batt=Not charging cap=99
Unknown:   charger=Discharging online=0 batt=Charging  ibat=-234863
Charging:  charger=Charging   online=1  batt=Discharging ibat=+430175
```

两个注意点：

1. **USB 数据链路不受影响**：RNDIS/NCM、`ttyGS0` 都还在（整个实验就是通过 USB SSH 做的）。
2. **停充期间 FG 的 `status` 不可信**：它报 `Charging`，但 `current_now` 是负的。
   判断"停没停"要看充电器的 `online` 或守护自己的状态文件。

#### E) 守护 `mi9-charge-guard`（窗口 + 过温）

| 文件 | 作用 |
|---|---|
| `payload/etc/default/mi9-charge-guard` | 配置：`LIMIT=80` / `RESUME=75` / `MAX_TEMP=45` / `INTERVAL=60` |
| `payload/usr/sbin/mi9-charge-guard.sh` | 主循环；`--status` / `--stop` / `--resume` 手动模式 |
| `payload/etc/systemd/system/mi9-charge-guard.service` | `Restart=on-failure`，开机启用 |

> ★ 坑（第一版就踩了）：unit 里**不要**同时写 `After=multi-user.target` 和
> `WantedBy=multi-user.target` —— 这是排序环，systemd 会直接把启动任务丢掉。
> 症状极隐蔽：`systemctl is-enabled` 显示 `enabled`，但 `is-active` 是
> `inactive (dead)`，而且 `journalctl -u` **一条记录都没有**（因为根本没执行）。
> 去掉 `After=` 之后开机就正常拉起了。

逻辑：
- 开机先把状态强制恢复成 `Charging`（避免上次停充残留）；
- `capacity >= LIMIT` → `Unknown`（停）；`capacity <= RESUME` → `Charging`（恢复）；
- 中间区间保持现状（滞回，避免 79↔80 频繁开关）；
- `temp >= 45C` → 无条件停充（独立于窗口）；
- 状态写 `/run/mi9-charge-guard.state`，每次切换 `logger -t mi9-charge-guard` 记一条；
- 不写 sysfs 时只记日志、不进重启循环。

语义上的取舍：停充后手机**靠电池运行**（不是"插着电但不充"），所以电量会在
80→75 之间缓慢往返。这是充电阈值型设备的常见行为；如果想改成"插电直供、
不碰电池"，那需要硬件层面的 power path 控制，主线驱动没暴露。

#### F) 仪表盘与自检

- `mi9-status.sh` 新增 **PWR** 段：
  ```text
  PWR -----------------------------------------------------------------
  batt  99% 4.40V  +430mA 34.0C Charging
  chg  online=1 icl=450mA SDP  guard=resumed
  ```
- `mi9-doctor.sh` 新增第 8 项：电池温度 ≥45 °C 报 BAD、守护没跑就 `--fix` 拉起；
  健康日志加 `batt=99%/34C` 字段。

#### G) 改动清单

| 文件 | 改动 |
|---|---|
| `dts/cepheus-chg.dtsi` | 新增：battery + `&pm8150b_fg` + `&pm8150b_charger` |
| `scripts/apply-dts4.sh` | 新增：第 4 段幂等 apply（片段变了自动替换） |
| `scripts/02-build-kernel.sh` | apply 循环加 `apply-dts4.sh`；DTB 门禁加 charger/fg 的 compatible 与 `status=okay` |
| `scripts/03-build-edk2.sh` | FVMAIN 终检加 `qcom,pm8150b-charger` / `qcom,pm8150b-fg` |
| `payload/usr/sbin/mi9-charge-guard.sh` | 新增：限充守护 |
| `payload/etc/default/mi9-charge-guard` | 新增：窗口/温度配置 |
| `payload/etc/systemd/system/mi9-charge-guard.service` | 新增：开机启用 |
| `payload/usr/sbin/mi9-status.sh` | 新增 PWR 段与 `volt/amp/tenth` 换算 |
| `payload/usr/sbin/mi9-doctor.sh` | 新增电池/守护自检 + `batt=` 日志字段 |
| `scripts/05-make-payload.sh` | 启用列表与软链接校验加 `mi9-charge-guard.service` |

#### H) 验证

```sh
ls /sys/class/power_supply/                     # pm8150b-charger qcom-battery
cat /sys/class/power_supply/qcom-battery/{capacity,voltage_now,current_now,temp,status}
cat /sys/class/power_supply/pm8150b-charger/{online,current_max,usb_type}
systemctl status mi9-charge-guard --no-pager
mi9-charge-guard.sh --status
mi9-charge-guard.sh --stop    && sleep 2 && cat /sys/class/power_supply/pm8150b-charger/online   # 0
mi9-charge-guard.sh --resume  && sleep 2 && cat /sys/class/power_supply/pm8150b-charger/online   # 1
journalctl -t mi9-charge-guard -n 20 --no-pager
```

#### I) 收尾（`srv6`）

payload 改动（新增守护/配置/单元、仪表盘与自检）必须 **bump** 版本号才会在
设备上解压，本轮为 `2026-10-19-srv6`。DTB 变化只需刷 `boot`，payload 变化只需
`dd` `kernelfat.img` 到 `sda28` —— 两者互不影响。


---

### 10.19 ★ 2026-10-19（续）WiFi 实测：2.4G 吞吐 + 5G 到底能不能用

#### A) 2.4G 吞吐（iperf3，PC ↔ 手机，4 流 10 s）

环境：手机连 AP 的 2.4G（ch7），`MCS15 / 144.4 Mbit/s`，RSSI -41 dBm；
PC 本身连同一路由器的 5G（2162 Mbit/s）——所以这是"空口共享后的下限值"。

| 方向 | 发送 | 接收 |
|---|---|---|
| WSL → 手机 | 66.6 Mbit/s | 60.2 Mbit/s |
| 手机 → WSL | 72.0 Mbit/s | 62.0 Mbit/s |

结论：2.4G / 20 MHz / 单空间流级别的正常水平（PHY 130–144 Mbit/s，TCP 大约打对折）。

#### B) 5G：手机侧完全正常（关键证据）

用 hostapd 在手机上自建 AP，让 PC 连：

| 手机 AP 信道 | 结果 |
|---|---|
| **ch149**（5745 MHz，UNII-3） | AP 起来，PC 直接连上，5 GHz / 149，链路 156 Mbit/s |
| **ch44**（5220 MHz，UNII-1） | AP 起来，PC 直接连上，RSSI -45 dBm |

> ★ 观测坑（很重要）：`netsh wlan show networks` 有时**只返回当前连接的那一个 SSID**
> （Windows 扫描缓存/节流）。于是"ch44/ch36 的 AP 扫不到"被我误判成"手机发射坏了"。
> 可信的做法是**定向连接**：先 `netsh wlan add profile` 导入目标 SSID 的配置，再
> `netsh wlan connect name=<profile>`；能连上就说明对方在正常发射。

#### C) 连不上 `560_5G` 的真正原因：路由器不回应认证

同一时刻的证据：

| 谁 | 目标 | 结果 |
|---|---|---|
| PC（AX211） | `560_5G` BSSID `…:93`，ch44 | **连上**，2162 Mbit/s，RSSI -36 |
| 手机（WCN3990） | 同一个 BSSID，RSSI **-39** | `authenticate` → 3 次 `send auth` → **timed out** |
| 手机自建 AP | ch44 | PC 能连上（见上表） |

手机在**同一信道**上既收得到（扫描 -39 dBm）又发得出（自建 AP 可被连接），
所以**不是手机的射频/驱动/board 文件问题**，而是**路由器选择性地不回应这台手机的认证帧**。

可尝试（都在路由器侧，不涉及手机）：
1. 5G 安全模式：WPA2-PSK 与 WPA2/WPA3 混合都试一遍（部分路由器对 11ac 客户端只给 WPA2）；
2. 关掉"WiFi 6 专用 / 仅 AX"之类的开关；
3. 检查 MAC 过滤 / 家长控制 / 设备黑名单（2.4G 与 5G 可能是两套 ACL）；
4. 5G 固定到 **149–165**（非 DFS、33 dBm）再试。

#### D) 复现命令

```sh
# 吞吐（设备当 server）
iperf3 -s -1 -p 5201 &
iperf3 -c <设备IP> -t 10 -P 4          # 上行
iperf3 -c <设备IP> -t 10 -P 4 -R       # 下行

# 手机自建 5G AP（验证发射）
nmcli con down 560
iw phy phy0 interface add ap0 type __ap
ip link set ap0 address 02:00:71:96:e3:dd
ip link set ap0 up
hostapd -B /tmp/hostapd-ch44.conf      # hw_mode=a, channel=44|149, ssid=cepheus-ch44
iw dev ap0 info                        # type AP + channel
# 收尾
pkill hostapd; iw dev ap0 del; nmcli con up 560
```

#### E) 小结

- **2.4G 可用**，实测 60–72 Mbit/s（共享空口的下限）。
- **5G 硬件/驱动可用**（自建 AP 在 ch44、ch149 都被 PC 成功关联）。
- **家里这台路由器的 5G 不接这台手机**——待用户改路由器设置后再复测；手机侧没有遗留问题。
---

### 10.20 ★ 2026-10-19（续）蓝牙 30 分钟长测（soak）

方法（`/root/bt-soak.sh`，日志 `/var/log/bt-soak.log`）：

- 40 轮；每轮 `bluetoothctl --timeout 8 scan on` 做一次 BLE 扫描；
- 每 5 轮做一次 `hciconfig hci0 down; sleep 1; hciconfig hci0 up`（故意折腾控制器）；
- 每轮记录：设备数、`hciconfig` 状态行、时间戳。

结果：

| 指标 | 数值 |
|---|---|
| 完成轮次 | **40 / 40** |
| 状态为 `UP RUNNING` 的轮次 | **40**（0 次掉线/异常） |
| 每轮扫到的 BLE 设备 | 平均 **17.5** 个（8–22） |
| `hciconfig` 计数器 | `errors: 0`，`RX 165236 / TX 1686868` |
| 强制 down/up | 8 次；其中 **1 次** 出现 `Failed to change controller baudrate` + `command tx timeout`，**下一轮自动恢复** |
| `Frame reassembly failed (-84)` | 8 次，均为良性（已知） |

结论与建议：

1. **控制器长稳没问题**：连续 30 分钟扫描 + 反复 off/on，没有一次掉线。
2. **不要用 `hciconfig hci0 down/up` 当日常开关**：down 会让驱动重新跑 QCA 的
   波特率协商（`hci_qca` 的 setup），偶发 `baudrate` 超时。日常请用
   `bluetoothctl power off/on`（mgmt 层，不重新初始化固件）。
3. `Frame reassembly failed (-84)` 只出现在初始化/重连时，不影响功能。

复现：

```sh
nohup /root/bt-soak.sh >/dev/null 2>&1 &
tail -f /var/log/bt-soak.log
```
### 10.21 — 2026-10-19：5G 关联失败 + 80 MHz 下加密吞吐塌陷

**现象**：2.4G(`560`) 正常；5G(`560_5G`) 一直 `authentication ... timed out`（dmesg 里
`send auth 1/3..3/3` 后超时）。PC 连同一个 BSSID `a4:a9:30:c3:5b:93` 正常。

**排除项**（都实测过）：

| 假设 | 实验 | 结果 |
|---|---|---|
| MAC 过滤 | 换随机 MAC 连 5G | 同样超时 → 排除 |
| 加密方式 | AP 改成开放 | 仍然超时 → 排除 |
| 信号弱 | `iw scan` | -39 dBm → 排除 |
| AP 坏 | PC 连同一 BSSID | 正常 → 排除 |

**根因**：AP 的 5G 被配成 **80+80 / 160 MHz**（beacon: `VHT center freq segment 1=42`、
`segment 2=50`，主信道 44，160 MHz 跨到 DFS 52–64）。QCA6174 + mainline ath10k 在
80+80 AP 上能收到 beacon（RX 正常），但 **auth 帧被发到错误的中心频点**，AP 收不到。
**把 AP 改成 80 MHz 后立即关联成功**。

**关联成功后的第二个问题**：80 MHz + 加密帧吞吐只有 23–26 Mbit/s。

| 组合 | 结果 |
|---|---|
| 5G · 开放 · 80 MHz（局域网 iperf3） | 354 / 287 Mbit/s |
| 5G · WPA2 · 80 MHz | 23 / 53 Mbit/s |
| 5G · WPA3-SAE · 80 MHz | 23 Mbit/s |
| 5G · WPA2 · 80 MHz · 外网下载 | 44 Mbit/s（同一时刻 PC 204 Mbit/s） |
| 5G · WPA2 · 80 MHz · UDP 200M | 26 Mbit/s，**丢包 84%** |
| 2.4G · WPA2 · 40 MHz | **125–130 Mbit/s** |

- 接口计数 `errors 0 / dropped 0` → 丢在空口，不是本机解密
- 换 SAE 无变化 → 不是 WPA2/WPA3 混合模式
- 开放网络 80 MHz 正常 → 不是射频/校准
- 试过 `ath10k_core.cryptmode=1`（软件加密）：固件不支持 raw mode，
  probe 报 `fatal problem with firmware features: -22`，wlan0 消失 → 不可用，已恢复默认

**结论**：这版 `htt-ver 3.70` 固件在 **80 MHz + 加密** 组合下有吞吐硬伤，与 2.4G 无关。
服务器链接最终用 2.4G（125–130 Mbit/s）；`560_5G` 档案保留，但
`autoconnect-priority=10`（低于 2.4G 的 20），只作兜底。

**复现**：`nmcli dev wifi connect 560_5G` → `iw dev wlan0 link` →
`iperf3 -c <peer> -u -b 200M`；AP 侧把带宽从 160 改 80 是关联成功的关键。

### 10.22 — 2026-10-20：VHT80 塌陷的根因是 PMF（802.11w），不是加密也不是 A-MSDU

10.21 把"80 MHz + 加密 → 23 Mbit/s"归因为固件加密路径；当天用同一 AP、同一口令、
同一 iperf3 对端做了隔离，结论要改：**开关是 PMF（802.11w 受保护管理帧）**。

**隔离实验**（AP `560_5G`、ch44、80 MHz、CCMP；设备 `WCN3990` + `htt 3.70`）：

| 组合 | 关联 | PHY | TCP 下行 | TCP 上行 |
|---|---|---|---|---|
| 2.4G · 40 MHz · VHT · WPA2 · 无 PMF | 正常 | MCS9 192 | 142–145 | – |
| 5G · 80 MHz · VHT80 · WPA2 · **PMF 强制**（`ieee80211w=2`） | 正常 | MCS7 650 | **19–24** | 48 |
| 5G · 80 MHz · VHT80 · WPA2 · **无 PMF**（`ieee80211w=0`） | 正常 | MCS7 650 | **255** | **232** |
| 5G · 80 MHz · VHT80 · WPA3-SAE（=PMF 强制，NetworkManager 默认） | 正常 | MCS7 650 | **20** | 48 |

同一条链路、同一分钟，只把 PMF 关掉，吞吐从 19 变 255；UDP 200M 那组在 PMF 下
丢 86%。PHY 速率两种情况下都是 MCS7 650 Mbit/s —— 所以不是射频、不是加密算法、
不是频段，是聚合在受保护管理帧下塌了（ADDBA 这类 action frame 被 PMF 保护后，
固件处理成近乎逐包）。

**中途的误判（留档）**：先试了 `disable_max_amsdu=1`，得到 304 Mbit/s，一度以为
是 A-MSDU。实际那几次快测用的都是 **WPA2 无 PMF**，慢测用的都是 SAE/PMF —— 变量
一直是 PMF，A-MSDU 只是伴随项。驱动侧清 `IEEE80211_HT_CAP_MAX_AMSDU` 的补丁
（曾编号 0009）经实测**无效**，已撤回。

**为什么 NetworkManager 会自动踩坑**：AP 是 WPA2/WPA3 过渡模式，NM 会优先用
SAE 并强制 PMF（supplicant 里 `key_mgmt=SAE`, `ieee80211w=2`）；profile 里写
`key-mgmt=wpa-psk` 也压不住（NM 1.46 仍选 SAE）。`pmf=1` 会让 5G 激活失败。

**可用方案（二选一）**：

1. **推荐：把 AP 的 5G 改成 WPA2-PSK（关掉 WPA3 过渡 / PMF）**。NM 随即走
   WPA2，实测 250+ Mbit/s，什么都不用改。
2. 不动路由器：用一份 **`ieee80211w=0` 的 wpa_supplicant 配置**连 5G（绕过 NM）：

   ```ini
   network={
       ssid="560_5G"
       psk="..."
       key_mgmt=WPA-PSK
       ieee80211w=0
   }
   ```

   实测 255/232 Mbit/s；代价是不能和 NM 同时管 wlan0。

**复现**：

```sh
# 慢（PMF 强制）
wpa_supplicant -i wlan0 -c <(printf 'network={ssid="560_5G"\npsk="***"\nieee80211w=2\n}')
iperf3 -c <peer> -t 8            # ~20 Mbit/s
# 快（关 PMF）
sed -i 's/ieee80211w=2/ieee80211w=0/' ...; iperf3 -c <peer> -t 8   # ~255 Mbit/s
```

**遗留**：根因在固件的 PMF/聚合路径，驱动侧没有开关可关；要彻底解决得等更新固件
（`WLAN.HL.3.0.c2-00350` 之后）或 QCA 修。当前服务器仍以 2.4G 为主链路，
5G 作为"AP 改 WPA2 后"的高速选项。