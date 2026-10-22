# 引导架构与 kernelfat 4096 字节扇区改造

## 引导链路

```
boot 分区 (sde49)         ← boot-cepheus.img = EDK2 UEFI 固件（内嵌 DTB）
recovery 分区 (sda28, 64MB) ← kernelfat.img = FAT，含 /Image + /startup.nsh
```

EDK2 UEFI Shell 执行 `startup.nsh`：

```
fs3:\Image console=tty0 loglevel=7 log_buf_len=4M fw_devlink=off ...
```

## 为什么用 EDK2+FAT 而不是 Android bootimg

| | EDK2 + FAT（现用） | Android bootimg |
|---|---|---|
| 换内核 | 重建 kernelfat（现在可直接 cp） | mkbootimg 重打包 + 刷 boot |
| DTB | EDK2 里 FFS 那份才是 Linux 用的 | 容易误改镜像尾部给 ABL 的厂商 DTB |
| 命令行 | startup.nsh 里改，零成本 | 要重新打包 |
| 体积 | 47MB Image 无压力 | 打包和分区都更紧 |

**结论：保持 EDK2 + FAT。**

## ★ 2026-10-22：kernelfat 改成 4096 字节扇区 + FAT16

### 问题

原来用 `mformat -F`（默认 512 字节扇区）。而 UFS 逻辑块是 4096，
Linux 的 vfat 会拒绝挂载：

```
vfat: logical sector size too small for device
```

所以 mods.tar.gz / wifi-cfg.tar.gz 只能内嵌进 initramfs。

### 关键坑（两个都踩了）

**坑 1：`mformat -S 5` 是假的 4096**

`mformat` 的 `-S` 参数是个**指数**（每扇区字节数 = `512 << (n-2)`，n=5 → 4096），
BPB 里的每扇区字节数确实变成 4096 了，**但总扇区数仍按 512 计算** —— 几何差 8 倍：

```
/dev/sda28  511M  46M  466M   ← 64MB 的分区报成 511M
```

这样写入会越界，非常危险。

**坑 2：64MB 装不下 FAT32**

4096 字节扇区下 64MB 只有 16384 个簇，而 FAT32 要求至少 65525 个簇。
用 `mkfs.vfat -F 32 -S 4096` 会警告簇数不足。

### 正确做法

```sh
mkfs.vfat -F 16 -S 4096 -n KERNELFAT "$IMG"
```

- FAT16（EDK2 和 Linux 都支持）
- 总扇区 16384 × 4096 = **正好 64MB**
- `fsck.fat -n` 通过
- EDK2 能正常引导（实测）

### 效果

```sh
mount -t vfat /dev/sda28 /mnt/kernelfat
ls /mnt/kernelfat/          # Image  startup.nsh
df -h /mnt/kernelfat        # 64M  46M  19M  71%
echo hi > /mnt/kernelfat/t  # ✅ 可写
```

已加进 `/etc/fstab`（带 `nofail`，不会阻塞启动）：

```
/dev/sda28  /mnt/kernelfat  vfat  defaults,noatime,umask=022,nofail,x-systemd.device-timeout=5  0 0
```

**升级内核从此只要一句话**（`startup.nsh` 里的 `fs3:\Image` 读的就是这个文件）：

```sh
cp Image /mnt/kernelfat/
```

而且能放多个内核，改 `startup.nsh` 一行就切换 —— 出问题也能留着旧内核兜底。

旧镜像备份在 `out/kernelfat-512.img`。
