# 小米9（cepheus / SM8150）主线 Linux —— 无头服务器移植

**Mainline Linux on the Xiaomi Mi 9 (cepheus, SM8150) as a headless server.**
UEFI (edk2-msm) boot, WiFi + Bluetooth working, no GUI, self-healing systemd units.

![status](https://img.shields.io/badge/status-可用%20%2F%20usable-brightgreen)
![kernel](https://img.shields.io/badge/kernel-6.17--sm8150-blue)
![rootfs](https://img.shields.io/badge/rootfs-Ubuntu%2024.04-orange)
![boot](https://img.shields.io/badge/boot-edk2--msm%20UEFI-purple)
[![lint](https://github.com/Bronya-Hacker/xiaomi-cepheus-linux/actions/workflows/lint.yml/badge.svg)](https://github.com/Bronya-Hacker/xiaomi-cepheus-linux/actions/workflows/lint.yml)

> 这是一个**个人实测项目**，不是官方发行版。所有结论都有设备上的证据；
> 没验证过的地方会明确标注"未验证"。刷机有变砖风险，风险自负。

---

## 目录

- [这是什么](#这是什么)
- [当前状态](#当前状态)
- [与 postmarketOS 方案的区别](#与-postmarketos-方案的区别)
- [仓库结构](#仓库结构)
- [快速开始](#快速开始)
- [关键设计](#关键设计)
- [文档](#文档)
- [固件与第三方组件](#固件与第三方组件)
- [免责声明](#免责声明)
- [致谢](#致谢)

---

## 这是什么

把一台 2019 年的小米9 变成**无显示器的 Linux 服务器**：

- 启动链：ABL → **edk2-msm UEFI** → 从 `sda28`（原 recovery 分区）读 `Image` 启动
- 系统：Ubuntu 24.04（`sda31`，约 110 GB），内核 `6.17.0-sm8150`
- 网络：WiFi 2.4G（`ath10k_snoc` + WCN3990）、USB RNDIS/NCM、蓝牙 BLE
- 运维：SSH、串口控制台（`ttyGS0`）、tty1 只读仪表盘、15 分钟自检自愈、60 s 硬件看门狗、zram swap
- 电源：`pm8150b-charger` + `qcom-battery`（电量/电压/电流/温度/状态），支持软件停充

**不启用**：GUI、Wayland/X、GPU 加速、音频、相机、蜂窝数据、OTG、传感器。

## 当前状态

| 子系统 | 状态 | 说明 |
|---|---|---|
| 启动（UEFI + `Image`） | ✅ | edk2-msm，`fs3:\Image`，`sda28` 有备份可回退 |
| CPU / 调频 / 温控 | ✅ | 8 核 `cpufreq-qcom-hw`，27 个热区，passive 90/95 °C，critical 110 °C |
| 存储（UFS） | ✅ | 系统在 `/dev/sda31`（110 G） |
| WiFi | ✅ 2.4G 实测 | `wlan0` 已连，iperf3 **60–72 Mbit/s**；5G 收发正常（自建 AP 在 ch44/ch149 均可被关联）；家里路由器 5G 不回应本机认证（AP 侧问题） |
| 蓝牙 | ✅ | `hci0 UP RUNNING`，BLE 扫描通过，bluez 开机自启；30 分钟 soak 40/40 轮 0 掉线 |
| USB 网络 / 串口 | ✅ | RNDIS/NCM + `ttyGS0` 控制台 |
| RTC | ✅ | `rtc-pm8xxx` + nvmem offset，掉电走时正常 |
| 充电 / 电量 | ✅ | `pm8150b-charger` / `qcom-battery`，软件停充已验证 |
| 硬件看门狗 | ✅ | `qcom_wdt` 60 s，实测能自动复位 |
| 显示 | ⚠️ | 仅 `simple-framebuffer` 文本控制台（无 DRM/GPU） |
| 触摸 | ⚠️ | 驱动 probe，但初始化报 `800E0007`（无 GUI 影响小） |
| 音频 / 相机 / 蜂窝 / 传感器 / 指纹 / NFC / 红外 | ❌ | 未移植 |
| USB Host / OTG / Type-C | ❌ | 仅 device 模式 |

完整对照表（含"成熟移植应有的样子"和复现命令）：[`docs/hardware-status.md`](docs/hardware-status.md)。

## 与 postmarketOS 方案的区别

这个项目走的是**"UEFI 引导 + 单分区 rootfs + 版本化 payload"**的路线，不是
postmarketOS 的 `boot.img` + `pmbootstrap` 流程：

| | postmarketOS | 本项目 |
|---|---|---|
| 引导 | 手机 boot 分区（Android bootimg） | edk2 UEFI 从 `sda28` 读 `Image` |
| 系统更新 | 重刷 rootfs 分区 | `dd` 一个 `kernelfat.img`（内核+initramfs+payload） |
| 配置下发 | 包管理器 | payload tar 按**版本号**决定是否解压 |
| 目标 | 手机 / 桌面 | 无头服务器（SSH + 串口） |

好处：改内核或系统都不用碰 rootfs，`dd` 60 MB 就完成一次升级，回滚就是刷回旧镜像。
坏处：没有包管理级别的原子性（所以有备份 + 自检 + 看门狗兜底）。

## 仓库结构

```
.
├── dts/                       # 设备树片段（按"第 1~4 部分"顺序追加到内核树）
│   ├── sm8150-xiaomi-cepheus.dts   # 主线 cepheus DTS（来自 pmOS）
│   ├── cepheus-wifi.dtsi           # ① UFS + WiFi + ADSP
│   ├── cepheus-extra.dtsi          # ② RTC 可写 / 触摸 / WiFi 收尾
│   ├── cepheus-bt.dtsi             # ③ WCN3990 蓝牙（uart13）
│   └── cepheus-chg.dtsi            # ④ PM8150B 充电器 + 电量计
├── patches/                   # 内核补丁（必须能被 02 脚本自动应用）
├── payload/                   # 会被打进 initramfs 的 rootfs 覆盖层
│   ├── etc/                   # 网络、systemd、sysctl、logind、journald……
│   ├── usr/sbin/              # mi9-status / mi9-doctor / wifi-up / rtc-save……
│   └── lib/firmware/          # ath10k board-2.bin 等
├── scripts/
│   ├── 01-setup-buildhost.sh  # 装编译依赖（WSL 或 Linux）
│   ├── 02-build-kernel.sh     # 打 patch、apply DTS、编 Image + dtb + modules
│   ├── 03-build-edk2.sh       # 把 DTB 塞进 edk2 FdtBlob，生成 boot 镜像
│   ├── 04-build-tqftpserv.sh  # QRTR/TFTP 服务（ADSP WiFi 固件必需）
│   ├── 05-make-payload.sh     # 打 payload tar + 权限归一 + 硬校验
│   ├── 06-make-kernelfat.sh   # 生成可 dd 的 kernelfat.img
│   ├── 07-rebuild-all-wsl.sh  # 一条命令全量重建（Windows 侧调用）
│   ├── apply-dts*.sh          # 幂等追加 DTS 片段（片段变了会自动替换）
│   └── flash.ps1              # fastboot 刷 boot（不 erase dtbo/vbmeta）
├── docs/
│   ├── root-cause.md          # 每一处坑的根因、证据链与修复
│   ├── verify.md              # 验收清单与故障对照表
│   ├── hardware-status.md     # 硬件支持现状对照
│   ├── restore.md             # 还原点与恢复手册
│   ├── fastboot.md            # 一键 fastboot 线刷包
│   └── guide.md               # 长篇构建/踩坑指南（原 README）
└── .github/workflows/lint.yml # CI：bash -n、CRLF、敏感信息、DTS marker
```

## 快速开始

### 直接下载（不想自己编）

| 包 | 内容 | 用途 |
|---|---|---|
| [`flash-2026-10-19-wifi-3c3445-r3`](https://github.com/Bronya-Hacker/xiaomi-cepheus-linux/releases/tag/flash-2026-10-19-wifi-3c3445-r3) | `boot.img` + `recovery.img`（34 MB） | 已有系统，只更新内核 / payload |
| [`full-2026-10-19-r3`](https://github.com/Bronya-Hacker/xiaomi-cepheus-linux/releases/tag/full-2026-10-19-r3) | 上面两个 + `rootfs.img.tar.zst`（4 GB rootfs） | **空机整机安装**，刷完即用 |

整机包实测：刷入 4 GB rootfs → 首启自动扩容到 110 GB、0 失败单元。
公开包**不含任何 WiFi 口令**（只有 `*.example` 模板）。

> ⚠️ 旧的 `r2` 包曾把本机 WiFi 口令打进镜像，Release 已删除；如果你下载过，
> 请改用 `r3`，并建议更换 WiFi 密码。

> ⚠️ 新版 fastboot 会把整个镜像读进内存（10 GB 镜像在 16 GB 机器上会
> `std::bad_alloc`）。整机包已缩到 4 GB；还是失败的话用 platform-tools 28.x
> 的 `fastboot`（分块发送，见 `docs/fastboot.md`）。

### 0. 前置

- 一台已解锁、能进 fastboot 的小米9（`cepheus`）
- Windows + WSL2（本项目的构建脚本按 WSL 写），或原生 Linux
- 内核树 `~/build/linux`（6.17 系）、`edk2-msm` 树、`mkbootimg`、`clang`/`lld`
- **不要** `fastboot erase dtbo` / `erase vbmeta`

### 1. 配置 WiFi（口令不进仓库）

仓库里只有模板，真实档案被 `.gitignore` 排除（避免把自家密码推到 GitHub）：

```sh
cd wifi-bringup
cp payload/etc/NetworkManager/system-connections/560-wifi.nmconnection{.example,}
cp payload/etc/wpa_supplicant/wpa_supplicant-wlan0.conf{.example,}
# 然后编辑这两个文件里的 ssid= 与 psk=
```

> 没有真实档案时 `05-make-payload.sh` 会用 `.example` 兜底并在日志里警告，
> 但模板里的 psk 是占位符，设备不会自动连上。

### 2. 全量重建（Windows 侧）

```powershell
wsl bash /mnt/c/<仓库路径>/scripts/07-rebuild-all-wsl.sh
```

产物在 `out/`：`Image`、`kernelfat.img`、`initramfs.cpio.gz`、`boot-cepheus.img` 等。

### 3. 刷机

```text
# 只有改 DTB / edk2 才需要刷 boot：
fastboot flash boot out/boot-cepheus.img
fastboot continue

# 只改内核 / initramfs / payload 时，把 kernelfat.img 推进 sda28：
scp out/kernelfat.img root@<ip>:/root/
ssh root@<ip> 'dd if=/root/kernelfat.img of=/dev/sda28 bs=1M conv=fsync'
ssh root@<ip> 'sha256sum /dev/sda28'   # 与本地 sha256 对比
ssh root@<ip> reboot
```

> `payload/` 改动必须同时 bump `payload/etc/wifi-cfg.ver`，否则设备上的
> initramfs 会认为"版本没变"而跳过解压。

### 4. 推送到 GitHub

仓库已经初始化好（`main` 分支，含首个提交），只差远端：

```sh
# Windows 没装 git 的话，用 WSL：
wsl bash -c 'cd "/mnt/c/Users/MAO/Desktop/小米9移植linux/wifi-bringup" && \
  git remote add origin git@github.com:<你的账号>/xiaomi-cepheus-linux.git && \
  git push -u origin main'
```

推之前建议再检查一次"真实 WiFi 档案有没有被跟踪"：

```sh
git ls-files | grep -E '\.nmconnection$|wpa_supplicant-[^/]*\.conf$' \
  && echo 'BAD: 真实 WiFi 档案进了仓库' || echo clean
```

## 关键设计

| 机制 | 为什么 |
|---|---|
| **payload 版本号**（`/etc/wifi-cfg.ver`） | 每次开机不必解压 60 MB；只有版本变化才覆盖 rootfs |
| **权限归一**（05 打包时统一 `644`/`755`） | 彻底避免"SSH 密钥 600 变成 777 导致 sshd 拒绝"这类事故 |
| **DTB 构建门禁** | 编译期检查 `uart13 okay`、`wcn3990-bt`、`pm8150b-charger` 等，防止"改了 dts 却没生效" |
| **幂等 apply 脚本** | 片段内容一变就整段替换，不看标记就跳过 |
| **mi9-doctor** | 15 分钟自检：WiFi/蓝牙/swap/磁盘/温度/权限，异常自动修 |
| **看门狗** | `qcom_wdt` 60 s，任何全局锁死都能自动复位 |
| **tty1 仪表盘** | 没有键盘的手机也能一眼看到 IP/温度/服务状态（纯 ASCII） |

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/root-cause.md`](docs/root-cause.md) | 每个坑的根因分析、证据链、改动清单（含 §10.16 服务器化、§10.17 蓝牙、§10.18 充电） |
| [`docs/verify.md`](docs/verify.md) | 分模块验收清单 + "现象 → 原因 → 修法"对照表 |
| [`docs/hardware-status.md`](docs/hardware-status.md) | 硬件支持现状 vs 成熟移植 |
| [`docs/restore.md`](docs/restore.md) | 还原点与恢复手册（L0 引导 / L1 系统 / L2 配置 / L3 全盘） |
| [`docs/fastboot.md`](docs/fastboot.md) | 一键 fastboot 线刷包（boot + recovery，实测 3 秒刷完） |
| [`docs/guide.md`](docs/guide.md) | 长篇构建指南与历史记录 |

## 固件与第三方组件

- `payload/lib/firmware/qcom/sm8150/wlanmdsp.mbn`、`ath10k/WCN3990/*`：
  来自 `linux-firmware` / 设备分区，**仅用于互操作**，版权归 Qualcomm/Atheros 所有。
- `payload/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin`：26440 字节的实测可用版本
  （含 `qmi-chip-id=30224`）。原厂 893528 字节那份不入库（`.gitignore` 已排除）。
- `payload/usr/bin/tqftpserv`：QRTR/TFTP 服务，由 `scripts/04-build-tqftpserv.sh` 构建。
- `patches/*.patch`：衍生自 Linux 内核，GPL-2.0。

## 免责声明

- 本项目与小米、Qualcomm、Google 无任何关联。
- 刷机、改分区、`dd` 到块设备都可能**永久损坏设备**，请先备份。
- 仓库中的 WiFi 密码/用户名均为占位符，请使用你自己的配置。
- 不要在未确认分区布局的情况下照抄 `dd` 命令。

## 致谢

- [postmarketOS](https://postmarketos.org/) 与 cepheus 设备树原作者（Alexey Minnekhanov）
- [edk2-msm](https://github.com/msm8916-mainline/edk2-msm)（UEFI for Qualcomm）
- [linux-msm](https://github.com/linux-msm) 社区与主线内核维护者
- QRTR / tqftpserv 项目

## License

原创脚本与文档：[MIT](LICENSE)。
`patches/` 与 `dts/` 的内核衍生部分：GPL-2.0。
