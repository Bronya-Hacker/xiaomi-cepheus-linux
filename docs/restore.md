# 还原点与恢复手册

> 目标：**任何时候都能把手机还原成"已知能用的最干净状态"**。
> 下面分 4 层，按"改动大小"选择最小的一层，不要动不动就全盘重来。

## 0. 四层还原点

| 层 | 内容 | 存放位置 | 体积 | 恢复耗时 | 会丢什么 |
|---|---|---|---|---|---|
| **L0 引导层** | `boot-cepheus.img`（edk2 UEFI + 内嵌 DTB） | PC `backups/golden-*/`、设备 `/root/` | 6.9 MB | ~1 min（fastboot） | 只影响 DTB/UEFI |
| **L1 系统层** | `kernelfat.img`（`Image` + initramfs + payload） | PC `backups/golden-*/`、设备 `/root/` | 64 MB | ~2 min（dd + 重启） | 内核/initramfs/payload 覆盖层 |
| **L2 配置层** | `/etc` + `/root/*.sh` + 包清单（`mi9-snapshot`） | 设备 `/root/snapshots/`、PC | 5–20 MB | ~1 min（解包） | 只会回退手工改过的配置 |
| **L3 全盘** | rootfs 压缩包（可选） | PC | ~5 GB | 20–40 min | 回到"装完系统"那一刻 |

**判断规则**

- 只改了 DTB / edk2 → **L0**
- 改了内核 / initramfs / `payload/`（且 bump 了版本）→ **L1**
- 只把 `/etc` 改乱了（网络、systemd、sysctl、SSH）→ **L2**
- 装了一堆包、系统被折腾得不成样子 → **L3**（或直接重刷 Ubuntu base）

## 1. 当前"已知好"版本（2026-10-19）

| 产物 | 版本 | 校验 |
|---|---|---|
| `boot-cepheus.img` | DTB = 4 段（WiFi+BT+充电） | md5 `e8bce1256e63a853e94b3a32c14ea820` / sha256 `0deec99f7d5280805338a97497d9055554c256f951fb0acef8df76ab9f0e887f` |
| `kernelfat.img` | payload `2026-10-19-wifi-3c3445-r3.3`（无 WiFi 口令、不注入公钥） | sha256 `4f7bfdcd0ab5d29346a3c45183e092db75f8a9d8f0ed5a7d9af3f2c7c0588b91` |
| ↳ 旧内核（Release 里那份） | 同一 payload，但**升级 payload 会覆盖本机 WiFi 档案** | sha256 `36c1e132e31dbd6feafe2f81988520b353848cddbba006fc134e8ab183190bee` |
| ~~r2 内核包~~ | 含真实 WiFi 口令，**已废弃**（公开产物已删除） | sha256 `d3f9699c20f06e871db092d58b91790925d7fe25e4cee163748e51e14d38f9d5` |
| 设备 `/root/` 里还有 | `kernelfat-srv5/6/7/8/9.img`、`sda28-before-srv2.img`、`dtbo-stock.img` | 见设备 `sha256sum` |

## 2. L1：恢复内核 + payload（最常用）

```sh
# 方式 A：设备上已有备份
sha256sum /root/kernelfat-srv7.img
dd if=/root/kernelfat-srv7.img of=/dev/sda28 bs=1M conv=fsync
sync
reboot

# 方式 B：从 PC 推
scp out/kernelfat.img root@169.254.42.1:/root/kernelfat.img
ssh root@169.254.42.1 'dd if=/root/kernelfat.img of=/dev/sda28 bs=1M conv=fsync; sync; reboot'
```

回读校验（必须一致）：

```sh
dd if=/dev/sda28 bs=1M count=64 2>/dev/null | sha256sum
```

> 只改 payload 时也要 **bump `payload/etc/wifi-cfg.ver`**，否则重启后
> initramfs 认为"版本没变"，不会重新解压，改了等于没改。

## 3. L2：恢复配置（`/etc`）

```sh
# 打快照（默认保留最近 5 份）
mi9-snapshot

# 预览差异（dry-run，不动文件）
mi9-restore /root/snapshots/mi9-cfg-<时间>-<版本>.tar.gz

# 真恢复（会先自动备份当前 /etc 到 pre-restore-*.tar.gz）
mi9-restore <归档> --yes          # 只恢复 /etc
mi9-restore <归档> --yes --all    # 同时恢复 /root 下的脚本
reboot
```

回滚：

```sh
tar -xzf /root/snapshots/pre-restore-<时间>.tar.gz -C /
reboot
```

> 建议通过 **USB（169.254.42.1）** 做恢复：如果快照里的 WiFi 口令不同，
> 恢复后 SSH over WiFi 会按快照重连，可能直接断开。

## 4. L0：恢复引导（只有改 DTB / edk2 才需要）

```text
fastboot flash boot out/boot-cepheus.img
fastboot continue
```

- **不要** `fastboot erase dtbo` / `erase vbmeta`（会破坏原厂校准/校验）。
- 刷完 `fastboot reboot` 可能被拦，用 `fastboot continue`。

## 5. L3：全盘 rootfs 备份（可选，需要先在 PC 上准备空间）

当前 `sda31` 用了约 9%（≈10 GB），排除 `/proc /sys /dev /run /tmp /var/log /root/snapshots`
后压缩大约 **4–6 GB**。

PC 侧空间已确认充足（C: 剩余 ~238 GB）。做法：

```sh
# 设备上打全盘包（US 压缩，速度优先）
tar --one-file-system --numeric-owner -I 'zstd -3 -T0' \
    -cf /root/rootfs-<日期>.tar.zst \
    -C / \
    --exclude=proc --exclude=sys --exclude=dev --exclude=run \
    --exclude=tmp --exclude=var/log --exclude=var/cache \
    --exclude=root/snapshots --exclude=root/*.img \
    .
# 传到 PC
scp root@192.168.31.177:/root/rootfs-<日期>.tar.zst backups/
```

恢复 L3 需要一个"不在被覆盖的分区上运行"的环境（initramfs / UEFI shell / 另一块盘），
不能直接在运行中的根上解包。建议方案（需要时再做）：

1. 在 `initramfs-init.sh` 里加一个 `mi9.restore=1` 模式：只挂载 `sda28`，
   从 `fs3:\rootfs.tar.zst` 解包到 `sda31`；
2. 或者用 PC 侧 ADB/fastboot + 临时 live 镜像恢复。

在这套机制做好之前，L3 的实用替代方案是：**重刷 Ubuntu base + `dd` 一次 L1**，
再把 L2 快照解回去（大约 20 分钟，效果与 L3 接近）。

## 6. 恢复演练（建议每月一次）

```sh
# 1) 打一份快照
mi9-snapshot /tmp
# 2) dry-run 验证能读、差异合理
mi9-restore /tmp/mi9-cfg-*.tar.gz | head -20
# 3) 校验 kernelfat 的哈希（不写盘）
sha256sum /root/kernelfat-srv7.img
```

演练不需要任何写操作；只要 dry-run 能列出差异，就说明归档可用。

## 7. 风险与禁忌

- 不要在 rootfs 运行中 `dd` 到 `/dev/sda31`（会当场损坏文件系统）。
- 不要 `fastboot erase` 任何分区。
- 不要把 `kernelfat.img` 写到 `sda28` 以外的分区（尤其 `sda31`）。
- 恢复 `/etc` 后如果不 reboot，systemd 仍用旧配置（容易误判"恢复没生效"）。

---

## L3 · 全盘 rootfs 备份（2.5 GB，手动、按需）

L0/L1 只覆盖 boot 和内核/payload；L2 只覆盖 `/etc`。L3 是整块 `sda31` 的内容。

| 项目 | 值 |
|---|---|
| 文件 | `backups/golden-wifi-r2/rootfs-r2.tar.zst` |
| 大小 | 2.47 GB（压缩比 ~3:1） |
| sha256 | `1cc89b608cc8c9cccbc920638e55e6c5655c1fbf235085b5e55f367b61958c18` |
| 生成 | `tar -C / --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run --exclude=./tmp --exclude=./mnt --exclude=./var/log --exclude=./var/cache/apt/archives --exclude='./root/*.img' -cf - . \| zstd -3 -T0` |
| 耗时 | 打包 ~80 s + USB 传到 PC ~60 s |

### 恢复（整机回滚）

**前提**：能进 initramfs 的串口救援 shell（`/dev/ttyGS0`，USB 连 PC）。

```sh
# 1) 把归档传回手机
scp -i C:\Users\MAO\.ssh\mi9_key rootfs-r2.tar.zst root@169.254.42.1:/root/

# 2) 手机端（串口 shell 或正常 SSH 都行，正常 SSH 时下面三步是一样的）
sha256sum /root/rootfs-r2.tar.zst      # 必须等于 1cc89b60...
mkdir -p /mnt/root
mount /dev/sda31 /mnt/root
cd /mnt/root
tar --zstd -xpf /root/rootfs-r2.tar.zst --numeric-owner
sync
umount /mnt/root
reboot
```

- 归档里**不含**它自己（`--exclude=./root/rootfs-*.tar.zst`），所以边解边读安全
- 解包会覆盖 `/etc`、`/usr`、`/var`（日志被排除），但**不会**删掉归档之后新建的文件
  —— 要“完全回到当时”请先 `rm -rf` 除 `/root` 外的目录，或接受“叠加式恢复”
- 正常运行的 SSH 里直接解包到 `/` 是**不安全**的（正在运行的程序会读到半新半旧的文件），
  所以推荐从 initramfs 救援 shell 做

> 位置：`/root/rootfs-r2.tar.zst`（手机上那份保留，方便再次回滚；PC 上是主副本）

## 5. 整机镜像（空机安装 / 整机重装）

公开 Release 里的整机包：`full-2026-10-19-r3`

| 文件 | 内容 | 大小 | sha256 |
|---|---|---|---|
| `cepheus-full-2026-10-19-r3.zip` | `boot.img` + `recovery.img` + `flash-all.bat` + `README` | 34.2 MB | `eb7a512153ba8c62ee76a96d451e8195f80aae69d0584466773fcfd80efdd5cf` |
| `rootfs.img.tar.zst` | ext4 rootfs，4 GB（tar+zstd） | 1.01 GiB | `9bad365d77808d02d3534b325f4a1ab9a3799be8ccef7e43bf3f4fc797e4ed48` |
| ↳ `recovery.img` | payload `2026-10-19-wifi-3c3445-r3.3`（不注入任何公钥，升级 payload 不覆盖本机 WiFi 档案） | 64 MiB | `4f7bfdcd0ab5d29346a3c45183e092db75f8a9d8f0ed5a7d9af3f2c7c0588b91` |

刷入：解压 zip，把 `rootfs.img.tar.zst` 放进去，跑 `flash-all.bat`
（等价于 `fastboot flash boot` / `flash recovery` / `flash userdata`）。

- 镜像从 r2 快照构建，**4 GB**（用 3.2 GB），首次开机 `mi9-firstboot.service`
  自动 `resize2fs /dev/sda31` 扩到整个 110 GB
- 已清洗：无 NM/wpa 真实档案、无 netplan WiFi 配置、无 SSH host key、无
  `authorized_keys`、无 machine-id、无日志/历史、无 `/root/wifi-cfg.tar.gz`
- `02-build-kernel.sh` 默认 `SSHKEY=""`：**不再把构建者公钥注入**每个刷机用户的
  `root/.ssh/authorized_keys`（公开镜像等于后门）；自己方便可显式传 `SSHKEY=...`
- root 密码 `mi9`，`shadow` 第 3 字段为 0 → 首次登录强制改密

> **fastboot 内存坑**：新版 platform-tools（30+）会把整个镜像读进内存，10 GB
> 镜像在 16 GB 机器上直接 `std::bad_alloc`。4 GB 镜像在空闲内存 < 6.4 GB 时也会
> 失败。解决办法：用 platform-tools **28.x** 的 `fastboot`（分 5 片稀疏发送，
> 4 GB 约 2.5 分钟），或关掉占内存的程序。
