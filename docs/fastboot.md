# fastboot 线刷包（一键刷入）

> 目标：**插上 USB，进 fastboot，双击一个 `.bat`，3 秒钟刷完，60 秒开机。**
> 不碰 userdata —— 你的文件、`/etc`、WiFi 口令都保留。

## 0. 包里有什么

| 文件 | 内容 | 刷到哪个分区 |
|---|---|---|
| `boot.img` | edk2-msm UEFI + 内嵌 DTB（WiFi / BT / 充电） | `fastboot flash boot`（`sde49`，128 MiB） |
| `recovery.img` | 64 MiB FAT：`Image` + `initramfs` + payload | `fastboot flash recovery`（`sda28`，64 MiB） |
| `MANIFEST.txt` | 两个镜像的 sha256 | — |
| `verify-images.ps1` | 刷前自动校验哈希 | — |
| `flash-all.bat` | 一键：校验 → 刷 boot → 刷 recovery → 开机 | — |
| `README.txt` | 同上的英文简版 | — |

**不含** rootfs（`userdata` / `sda31`）。所以：

- ✅ 不会丢文件、不会丢 `/etc`、不会丢 WiFi 口令
- ✅ 不做 `erase`，`dtbo` / `vbmeta` / `persist` / `modem` 原封不动
- ⚠️ 反过来，它**不能**修复 rootfs 里被删坏的文件（那要用 L2 快照或 L3）

## 1. 生成

```powershell
powershell -ExecutionPolicy Bypass -File scripts\09-make-fastboot-package.ps1
# 产物：flash\cepheus-<payload 版本>\
```

只复制 `out\` 里已经构建好的镜像，不做编译。`flash/` 已加入 `.gitignore`（70 MB）。

## 2. 进入 fastboot

**方法 A（推荐，已实测）**：在系统里直接重启进 fastboot

```sh
reboot bootloader        # 约 24 秒后出现在 fastboot 里
```

**方法 B**：关机后按住 **音量下 + 电源**，直到屏幕出现 `FASTBOOT` 字样。

PC 侧确认：

```powershell
fastboot devices
# 2470336a        fastboot
```

> 没有 fastboot？下载 Android platform-tools，解压到
> `%LOCALAPPDATA%\Android\platform-tools`（`flash-all.bat` 会自动去这里找），
> 或者把 `fastboot.exe` 放进 PATH。

## 3. 刷入

双击 `flash-all.bat`，或者：

```powershell
cd flash\cepheus-<版本>
.\flash-all.bat
```

实际输出（2026-10-19 实测）：

```text
== verify images ==
[ok] boot.img
[ok] recovery.img
[ok] all images verified

== device ==
2470336a        fastboot

== flash boot (UEFI + DTB) ==
Sending 'boot' (6698 KB)                           OKAY [  0.216s]
Writing 'boot'                                     OKAY [  0.039s]
== flash recovery (kernel + initramfs + payload) ==
Sending 'recovery' (65536 KB)                      OKAY [  2.036s]
Writing 'recovery'                                   OKAY [  0.325s]

== continue (boot the phone) ==
Resuming boot                                      OKAY [  0.491s]
[ok] done.
```

刷入本身 **~3 秒**，开机 **~50 秒**。

## 4. 只刷其中一层

```powershell
# 只更新内核/payload（改了 Image / initramfs / payload）
fastboot flash recovery recovery.img
fastboot continue

# 只更新 UEFI/DTB（改了 edk2 或 DTS）
fastboot flash boot boot.img
fastboot continue
```

> 注意：**改 DTB 要刷 `boot`**（DTB 内嵌在 UEFI 里），**改内核要刷 `recovery`**。
> 这与 `docs/restore.md` 的 L0 / L1 是同一件事，只是换了交付方式。

## 5. 刷完验收

```sh
ssh root@169.254.42.1 'cat /etc/wifi-cfg.ver; mi9-doctor.sh; mi9-status.sh'
```

合格标准：

- `cat /etc/wifi-cfg.ver` 是包里 README 写的版本
- `mi9-doctor: bad=0`
- `wlan0:connected:560`
- `hci0` 是 `UP RUNNING`
- 电池守护 `active`

## 6. 出问题怎么办

| 现象 | 处理 |
|---|---|
| `fastboot devices` 空 | 换 USB 口/线；Windows 设备管理器看是否有 `Android Bootloader Interface`；重进 fastboot |
| `Sending 'boot' ... FAILED (remote: ...)` | 别慌，手机还在 fastboot；重新跑 `flash-all.bat` |
| 刷完卡在 UEFI 画面 | 断电重启一次；仍不行就刷 `backups\golden-srv8\boot-cepheus.img` |
| 起不来但能进 fastboot | 用已验证的旧镜像：`/root/kernelfat-srv7.img`（设备上）或 PC 的 `backups\` |
| `flash-all.bat` 说找不到 fastboot | 按上面的路径装 platform-tools，或设置 PATH |

**永远不要**执行：

```text
fastboot erase dtbo
fastboot erase vbmeta
fastboot erase persist
fastboot erase modem
```

这些分区存着原厂校准/校验，擦掉后 WiFi、基带、传感器都可能永久失效（我们从来没有擦过）。

## 7. 与还原点的关系

| 还原点 | 等价操作 |
|---|---|
| **L0** 引导层 | `fastboot flash boot boot.img` |
| **L1** 系统层 | `fastboot flash recovery recovery.img` |
| L2 配置层 | 刷完后用 `mi9-restore` 解快照（线刷包不含 `/etc`） |
| L3 全盘 | 线刷包不含 rootfs |

所以这个包 = **L0 + L1 的"离线交付形态"**：即使手机进不了系统（只要还能进 fastboot），也能 3 秒恢复内核和 payload。

## 8. 刷机前选 WiFi（不用在手机上打字）

两种方式，任选：

### A. 打包时嵌入（推荐，刷完自动连）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\10-provision-wifi.ps1
#   WiFi SSID: 560
#   WiFi password: ****
# 会自动：写 NetworkManager 档案 + wpa_supplicant 兜底 + bump payload 版本
#        + 重建（~3 分钟）+ 重新生成 flash\cepheus-<版本>\

# 非交互：
powershell -File scripts\10-provision-wifi.ps1 -Ssid "560" -Psk "你的口令"
# 只改配置不重建：
powershell -File scripts\10-provision-wifi.ps1 -Ssid "560" -Psk "..." -NoBuild
```

然后照常 `flash-all.bat`。开机会直接连上指定 WiFi。

- 口令只写进 `payload/.../mi9-wifi.nmconnection`（600 权限），该文件被 `.gitignore` 排除
- 想固定 2.4G：加 `-Band bg`；默认 `auto`
- SSID 里的引号/反斜杠会被拒绝（避免 keyfile 转义问题）

### B. 刷完之后用 USB 改（不重建、不重启）

手机在 USB 上永远有 `169.254.42.1` 这个固定地址（NCM gadget），WiFi 挂了也能进：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\11-wifi-usb.ps1 -List
powershell -ExecutionPolicy Bypass -File scripts\11-wifi-usb.ps1
#   SSID to connect: 560
#   password: ****
```

它会：

1. 通过 USB SSH 连上手机（不需要 WiFi）
2. 列出可见的 SSID
3. `nmcli con mod mi9-wifi wifi.ssid/psk` → `nmcli con up mi9-wifi`
4. 打印新连接和 IP

> 连接档案统一叫 `mi9-wifi`（`wifi-up.sh` 会自动发现它，不再写死 `560`）。
> 旧版设备上的 `560-wifi.nmconnection` 会在首次开机时自动迁移到
> `/root/560-wifi.nmconnection.legacy`。

### C. 整机包（空机安装）

Release `full-2026-10-19-r3` 是"空机可装"的完整包：`boot.img` + `recovery.img`
+ `rootfs.img.tar.zst`（4 GB ext4，tar+zstd）。

```powershell
# 1) 下载 cepheus-full-2026-10-19-r3.zip 和 rootfs.img.tar.zst，解压 zip
# 2) 把 rootfs.img.tar.zst 放进解压目录
# 3) 双击 flash-all.bat
```

脚本等价于：

```
fastboot flash boot    boot.img
fastboot flash recovery recovery.img
fastboot flash userdata rootfs.img
fastboot continue
```

首次开机自动扩容到 110 GB、生成 SSH host key；root 密码 `mi9`（强制改密）。
镜像里**不含任何 WiFi 口令**（只有 `*.example` 模板），需要自己
`nmcli dev wifi connect "SSID" password "PASS"`。

#### ★ fastboot 内存坑（本机实测）

`platform-tools` 30+ 的 `fastboot flash userdata` 会把**整个镜像读进内存**
（`ReadFileToString`），10 GB 镜像在 16 GB / 空闲 5.3 GB 的机器上直接：

```
libc++abi: terminating due to uncaught exception of type std::bad_alloc
```

4 GB 镜像在空闲提交内存 6.4 GB 时也会失败。两个办法：

1. **用 platform-tools 28.x 的 fastboot**（推荐）
   ```powershell
   curl.exe -L -o pt28.zip https://dl.google.com/android/repository/platform-tools_r28.0.2-windows.zip
   tar -xf pt28.zip
   .\platform-tools\fastboot.exe flash userdata rootfs.img
   ```
   它会自动切成 5 片稀疏镜像发送（每片 ~750 MB），4 GB 只要 ~2.3 分钟，
   内存占用只有一片的大小。

2. 关掉浏览器等占内存的程序，让空闲提交内存 > 镜像大小的 2 倍。

> 这也是为什么公开镜像从 10 GB 缩到 **4 GB**：既省内存又省下载流量
> （压缩后 1.01 GiB），首次开机照样自动扩到 110 GB。

---

# ★ 刷 rootfs（userdata / sda31）—— 2026-10-22 实测成功

仓库原来的线刷包**不含 rootfs**，需要"重装 Ubuntu base"。这里记录一个已在真机验证的
完整方法：把 rootfs 备份包做成 ext4 镜像，用 `fastboot flash userdata` 整块写入。

## 什么时候用

- 系统被折腾乱了、`/etc` 残留文件导致服务起不来（例如 sshd 在 banner 阶段就断开）
- 想要"完整空白"的重装，而不是覆盖式还原

**为什么覆盖式还原不够**：`tar -x` 只覆盖归档里的文件，**归档之后新增的文件不会被删除**。
如果之后升级过库（`apt install`），新版 `.so` 会留下，和旧二进制不匹配
（实测症状：sshd 起来但连接在 `kex_exchange_identification` 阶段被关闭）。
要真正干净，必须整块重写分区。

## 步骤

### 1. 在 WSL 里解包归档

```bash
mkdir -p /root/newroot
zstd -dc /mnt/c/Users/MAO/Desktop/小米9移植linux/wifi-bringup/backups/golden-wifi-r2/rootfs-r2.tar.zst \
  | tar -x --numeric-owner -C /root/newroot
du -sh /root/newroot        # 实测 7.6G
```

### 2. 直接生成 ext4 镜像（不需要 loop mount）

`mke2fs 1.47` 支持 `-d <dir>`，一步把文件树写进镜像：

```bash
truncate -s 12G /root/userdata.img
mkfs.ext4 -F -L userdata -m 0 -d /root/newroot /root/userdata.img
# 实测 54 秒
```

> 镜像只要装得下就行，**不用等于分区大小**。开机后 systemd 会自动
> `growfs` 把文件系统扩到整个 110G 分区（实测 12G 镜像 → 开机后 `df` 显示 110G）。

### 3. 复制到 Windows 侧

```bash
cp /root/userdata.img /mnt/c/Users/MAO/AppData/Local/Temp/userdata.img   # 2 分钟
```

### 4. 刷入

```powershell
fastboot devices
fastboot getvar partition-type:userdata     # 应回 ext4
fastboot flash userdata C:\Users\MAO\AppData\Local\Temp\userdata.img
# 实测 5.5 分钟（fastboot 自动按 sparse 分片传输）
fastboot reboot
```

### 5. 验证

```sh
ssh mi9-usb 'systemctl is-system-running; systemctl --failed'
# running，无失败服务
find /root /usr/local /opt /home -xdev -newermt "2026-10-20" -type f | wc -l
# 0 —— 确实是干净的
df -h /
# 110G，用了 7.4G
```

## 注意事项

- **配套镜像要一起刷**：rootfs 与 `kernelfat`（内核+模块）、`boot`（UEFI+DTB）必须是同一版本，
  否则模块 vermagic 不匹配。本次刷的是 `backups/golden-20261019-1504/` 那套（payload `2026-10-19-srv8`）
- `fastboot flash userdata` 会**清空全部用户数据**（包括 WiFi 口令、SSH 公钥、
  所有装过的软件）——归档里带着 10-19 那一刻的 WiFi 配置和公钥，所以开机后还能直接登录
- 刷之前确认 fastboot 的 `partition-type:userdata` 是 `ext4`（本机实测是）
- 镜像里不要放大的临时文件（例如备份的 `.tar.zst` 本身），会白占空间

## 本次实测结果（2026-10-22 23:43）

```
systemd: running，0 个失败服务
载荷: 2026-10-19-srv8
残留文件: 0
WiFi: 能上外网；USB: 169.254.42.1 + 192.168.2.2
磁盘: 110G / 用 7.4G
蓝牙 hci0: UP，66 个模块
密码/公钥: 保留（能 SSH 登录）
```
