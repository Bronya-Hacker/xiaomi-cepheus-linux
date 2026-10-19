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
