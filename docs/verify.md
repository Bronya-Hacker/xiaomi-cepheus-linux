# 上机验证清单（一关一关过）

> 原则：**前一层没通过，就不要看后面。**
> 每一关都给了「通过的样子」和「没过时先看哪里」。
> 所有命令在手机上的 Ubuntu 里执行（串口 tty0 / COM4，或 SSH `umeko@<ip>`）。

---

## 一键诊断（最省事）

payload 里带了一个诊断脚本，刷完机直接跑它，把输出整段发回来：

```sh
sh /usr/sbin/wifi-diag.sh 2>&1 | tee /tmp/wifi-diag.txt
ls -l /tmp/wifi-diag.txt
```

它按下面第 0~6 关的顺序逐层打印状态，哪一关断了输出里一眼能看出来。
下面是**人工逐关**的版本，想自己查的时候用。

---

## 第 0 关 —— DTB 到底换没换（地基）

**不需要 dtc**，直接读 `/proc/device-tree`（它就是活着的 DTB）。

> ★ 先看这一条：**你能读到这一段，本身就说明 UFS 是 okay 的**。
> 如果 `ufshc` 不是 okay，内核看不到 `/dev/sda*`，你连系统都进不来
> （现象：企鹅画出来了但日志不滚、Windows 也扫不到 USB）——详见 README 4.7。
> 为了以后少走弯路，还是把它一起打出来：

```sh
cat /proc/device-tree/soc@0/ufshc@1d84000/status; echo      # 期望 okay
cat /proc/device-tree/soc@0/phy@1d87000/status;  echo      # 期望 okay

W=/proc/device-tree/soc@0/wifi@18800000
A=/proc/device-tree/soc@0/remoteproc@17300000

cat $W/status; echo                              # 期望 okay
cat $A/status; echo                              # 期望 okay
cat $A/firmware-name; echo                       # 期望 qcom/sm8150/adsp.mdt
cat $A/glink-edge/qcom,remote-pid; echo          # 期望 <0x02>（2 = ADSP）

# 四路电源的 phandle（不是全 0 才算真的指到了 regulator）
for p in vdd-0.8-cx-mx-supply vdd-1.8-xo-supply vdd-1.3-rfa-supply vdd-3.3-ch0-supply; do
	printf '%-24s ' "$p"; od -An -tx1 $W/$p
done
cat $W/qcom,calibration-variant; echo            # 期望 Xiaomi_raphael

# ★ 顺便确认刷进去的确实是"我们新编的 edk2"：
#   bootargs 是 03-build-edk2.sh 注入的，原厂 FdtBlob 里没有这一项。
cat /proc/device-tree/chosen/bootargs; echo      # 期望 console=tty0 loglevel=7
cat /proc/device-tree/chosen/stdout-path; echo   # 期望 serial0:115200n8
```

通过的样子：

| 检查项 | 期望 |
|---|---|
| `ufshc@1d84000/status` | `okay`（不 okay 你看不到这行） |
| `phy@1d87000/status` | `okay` |
| `wifi@18800000/status` | `okay` |
| `wifi@18800000/` 下有 4 个 `vdd-*-supply` | 都存在，且不是 `00 00 00 00` |
| `remoteproc@17300000/status` | `okay` |
| `remoteproc@17300000/firmware-name` | 内容是 `qcom/sm8150/adsp.mdt` |
| `chosen/bootargs` | `console=tty0 loglevel=7`（有它 = 刷的是新 edk2） |

**注意 `/proc/device-tree/.../status` 打印出来不带换行**（DT 里的字符串没有结尾 `\0`），
所以后面要跟一个 `echo`。

没过时先看：

* `status` 还是 `disabled` / 找不到节点 → **edk2 没换成功**，或 boot 分区没刷进去。
  回编译机确认 `out/boot-cepheus.img` 是新的（时间戳），
  并确认 03 脚本报告了 `✓✓ 固件里确实含我们打补丁的 DTB`。
* 有 `status` 但没有 `firmware-name` → 上一版的坑：**只开 `status` 是不够的**，
  `qcom_q6v5_pas` 必须要 `firmware-name` 才会 probe。
* `chosen/bootargs` 是 `(无)` → 刷的还是旧 `boot.img`，重新刷。

> ★ 这一关不过，后面全部免谈。改 DTB 只能靠重编 edk2 + 刷 `boot`，
> 光刷 `Image`（kernelfat）是没用的。

---

## 第 1 关 —— 固件文件齐不齐（本轮新加）

```sh
# ADSP 固件本体（手机自带，拆分固件）。缺了 ADSP 根本起不来。
ls -l /lib/firmware/qcom/sm8150/adsp.mdt
ls -l /lib/firmware/qcom/sm8150/ | head -30

# 这两个由 payload 投递
ls -l /lib/firmware/qcom/sm8150/wlanmdsp.mbn
ls -l /lib/firmware/ath10k/WCN3990/hw1.0/

# board-2.bin 里必须有 30224
strings /lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin | grep -o 'qmi-chip-id=30224'
```

通过的样子：

| 文件 | 来源 | 期望大小（参考） |
|---|---|---|
| `/lib/firmware/qcom/sm8150/adsp.mdt` | 手机自带（拆分固件） | 非 0 |
| `/lib/firmware/qcom/sm8150/wlanmdsp.mbn` | payload（★ ADSP 通过 tqftpserv 取这份） | 3 725 044 |
| `/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin` | payload | 893 528 |
| `/lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn` | payload（linux-firmware 原始位置，备用） | 3 725 044 |
| `/lib/firmware/ath10k/WCN3990/hw1.0/firmware-5.bin` | payload | 60（桩文件，正常） |

没过时先看：

* **没有 `adsp.mdt`，只有 `adsp.mbn`** → DTB 里写的是 `.mdt`，两者不匹配，ADSP probe 会失败。
  要么把拆分固件补齐，要么把 DTB 的 `firmware-name` 改成 `qcom/sm8150/adsp.mbn` 再重编 edk2。
* **`wlanmdsp.mbn` 不在 `qcom/sm8150/` 下** → `translate.c` 的翻译规则命不中（见 README §1.3），
  ADSP 拿不到 WLAN 固件 → 没有 WLFW → `wlan0` 不会出现。
* **`grep 30224` 没输出** → 手机上那份 board-2.bin 是旧的，payload 没覆盖成功。

---

## 第 2 关 —— 模块 / QRTR 传输层

```sh
# 模块文件在不在（mods.tar.gz 有没有正确解包 + depmod 有没有跑）
ls /lib/modules/$(uname -r)/kernel/net/qrtr/
ls /lib/modules/$(uname -r)/kernel/drivers/soc/qcom/ | grep -E 'q6v5|glink|smem'
ls /lib/modules/$(uname -r)/kernel/drivers/net/wireless/ath/ath10k/ | grep snoc

# 实际加载了哪些
lsmod | grep -E 'qrtr|glink|q6v5|ath10k|remoteproc|qmi'

# rpmsg 通道（★ 出现 IPCRTR 才说明 ADSP 的 glink-edge 起来了）
ls /sys/bus/rpmsg/devices/
ls /sys/class/rpmsg/
```

设计意图（`payload/etc/` 里配好了）：

* `modules-load.d/wifi.conf` 只自动加载**传输层**：
  `qcom_q6v5`、`qcom_glink_smem`、`qrtr`、`qrtr-smd`；
* `modprobe.d/wifi-order.conf` **blacklist** 掉 `qcom_q6v5_pas` 和 `ath10k_snoc`；
* 这两个由 `wifi-up.sh` 在 **tqftpserv 就绪之后** 显式 `modprobe`（顺序很重要）。

没过时先看：

* 模块文件不存在 → `mods.tar.gz` 没解包或版本目录名不对
  （`uname -r` 应该是 `6.17.0-sm8150`）。看 initramfs 的 `depmod` 那几行输出。
* `lsmod` 里没有 `qrtr` → 看 `dmesg | grep -i qrtr`、`modprobe qrtr` 手动试。

---

## 第 3 关 —— ADSP 有没有真的 running

```sh
# ★ ADSP 出复位靠 AOSS QMP（DTB 里 adsp 节点带 qcom,qmp = <&aoss_qmp>）
ls /sys/bus/platform/drivers/qcom_aoss_qmp/ | head

for r in /sys/class/remoteproc/remoteproc*; do
	echo "$(basename $r): name=$(cat $r/name) state=$(cat $r/state)"
done

dmesg | grep -iE 'q6v5|remoteproc|adsp|pas|mdt|firmware|aoss' | tail -40
```

通过的样子（**两个都要 `running`，编号别记错**）：

```
remoteproc0: name=modem state=running     ← ★ WCN3990 的 wlanmdsp.mbn 是它去要的
remoteproc1: name=adsp  state=running     ← 负责广播 WLFW 服务
```

（`cdsp`/`slpi` 我们故意 disabled，不该出现。）

> ★★ **2026-10-18 纠正**：早前这里写过"只有 modem 缺席 / modem 报一堆错 → 无害，别管它"，
> **那是错的**。真正向 `tqftpserv` 要 `wlanmdsp.mbn` 的是 **modem DSP（MPSS）**
> （ath10k 作者原话 *sideloaded to the modem DSP via the TQFTPserv*）。
> DTB 里 MPSS 没有 auto-boot，没有东西会启动它 → 它一直 `offline` → 没有 WLFW 服务 →
> `ath10k_snoc` 静默等到天荒地老、`wlan0` 永远不出现（**而且不报任何错**）。
> 完整链条见 `docs/root-cause.md` §10.8。

没过时先看：

* `probe` 报 `failed to load firmware` / `-ENOENT` → 第 1 关的固件文件问题。
* `-EPROBE_DEFER` 且 dmesg 里带 `aoss_qmp` / `qmp` → AOSS QMP 没就绪
  （内核里应是 `CONFIG_QCOM_AOSS_QMP=y`，我们的配置已经是 y）。
* **完全没有 `adsp` 这个 remoteproc** → DTB 没生效（回第 0 关），
  或者 `qcom_q6v5_pas` 没被 modprobe
  （**先确认 `qcom_q6v5_pas.ko` 真的编出来了**，见 README §4.3 坑 1）。
* `state=attached` / `crashed` → 看 `dmesg` 里 `qcom_q6v5-pas` 的具体报错；
  常见是 `adsp_mem` / `mem_region` 或签名问题。
* `remoteproc0`(modem) 是 `offline` → 手动起一次看报什么：
  `echo start > /sys/class/remoteproc/remoteproc0/state`（`wifi-up.sh` 正常会自动做）。
* **modem 每 ~40 秒崩一次**（`crash detected in modem` / `DOG detects stalled initialization`）
  → `rmtfs`/`pd-mapper` 没工作，modem 读不到自己的 PD 固件：
  ```sh
  for u in rmtfs pd-mapper tqftpserv; do printf '%-10s %s\n' $u "$(systemctl is-active $u)"; done
  journalctl -u rmtfs -b --no-pager | tail -5   # Failed to get rprocfd = 顺序错（必须先起 modem）
  ```
* `wifi-up.sh` 会在 20 秒内没看到 `wlan0` 时**重启一次 modem**，再不行才重启 ADSP；
  每一步都写进 `/run/wifi-up.log`。

---

## 第 4 关 —— tqftpserv 在跑，而且真的喂了固件

```sh
systemctl status tqftpserv --no-pager
journalctl -u tqftpserv -n 80 --no-pager

# 二进制和依赖
ls -l /usr/bin/tqftpserv
ldd /usr/bin/tqftpserv
ls -l /usr/lib/aarch64-linux-gnu/libqrtr.so.1* /usr/lib/aarch64-linux-gnu/libzstd.so.1*
```

通过的样子：

* `Active: active (running)`；
* journal 里出现**收到 ADSP 的文件请求并成功发送**的日志
  （会看到它去 `/lib/firmware/qcom/sm8150/wlanmdsp.mbn` 取文件）。

没过时先看：

| 症状 | 原因 | 处置 |
|---|---|---|
| `Failed to start` + `status=203/EXEC` | 二进制不存在 / 没有执行权限 | `ls -l /usr/bin/tqftpserv` |
| `error while loading shared libraries: libqrtr.so.1` | 依赖缺失 | `wifi-up.sh` 第 0 步会自动把 `payload/usr/lib/tqftpserv-bundle/` 里的补进 `/usr/lib/aarch64-linux-gnu/`，看 `/run/wifi-up.log` |
| `active` 但 journal 一条文件请求都没有 | ADSP 没起来，或 QRTR 通道不通 | 回第 2、3 关 |
| `active` 但一直报 `open ... No such file` | **落点不对** | 必须放在 `/lib/firmware/qcom/sm8150/wlanmdsp.mbn` |

> ⚠️ **不要给 `tqftpserv` 加参数。** 官方单元的 `ExecStart` 就是
> `/usr/bin/tqftpserv`，默认可读根就是 `/lib/firmware`。
> 传 `-r /lib/firmware` 这类参数是**错的**（程序没有这个选项，会起不来）。

---

## 第 5 关 —— wlan0 出现

```sh
ip link show wlan0
dmesg | grep -iE 'ath10k|wlfw|wcn3990|board|qmi|qrtr' | tail -80
```

通过的样子：`ip link` 里出现 `wlan0`。

没过时先看 `dmesg` 里的关键字：

| 日志 | 含义 | 对应第几关 |
|---|---|---|
| `failed to register wlfw qmi client: -517` | `qrtr` 没加载（`AF_QIPCRTR` 不支持） | 2 |
| `failed to fetch board data` / `unsupported chip id` | board-2.bin 不含 30224 | 1 |
| `failed to find board file` | 同上，或 `qmi_board_id` 不匹配 | 1 |
| `supply vdd-* not found, using dummy regulator` | 四路电源没配 | 0 |
| `probe` 之后**什么都不报** | **这是正常的**：`ath10k_snoc_probe()` 注册完 WLFW lookup 就 `return 0` 静默等待 | — |
| 一直没反应 | ADSP 没起 / tqftpserv 没喂固件 | 3、4 |

---

## 第 6 关 —— 连上 WiFi（★ 2026-10-18 起：NetworkManager + 2.4G）

**正常情况什么都不用做**：payload 会把档案
`/etc/NetworkManager/system-connections/560-wifi.nmconnection` 放好
（SSID `560` / 密码示例 `changeme123` / `band=bg` / `autoconnect=yes`），
开机后 NetworkManager 自动连，`wifi-up.sh` 只是等它连上（必要时 `nmcli con up 560`）。

```sh
nmcli -t dev status | grep wlan0                 # connected
nmcli -t -f NAME,AUTOCONNECT con show            # 只有 560 应该是 yes
ip -4 addr show wlan0
iw dev wlan0 link                                # 看信号/速率
ip route
ping -c3 192.168.31.1
ping -c3 223.5.5.5
```

> ★★ **不要**再 `systemctl enable --now wpa_supplicant@wlan0`，
> **不要**再 `systemctl enable --now systemd-networkd` + `25-wlan0.network`：
> 会和 NM 抢 wlan0（第二个 supplicant、第二个 DHCP 客户端），把连好的连接弄掉。
> `25-wlan0.network` 在 payload 里已改名 `.unused`，只在没有 NM 的 rootfs 上
> 才由 `wifi-up.sh` 启用。
>
> `payload/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` 里现在是 2.4G `560`
> （那个服务在设备上已 `mask`，这份文件只是手工兜底）。

> ⚠️ **5G（`560_5G`）连不上是路由器信道的问题，不是手机的**：该 SSID 在 ch44，
> CN 域是 `[RADAR]`(DFS)，STA 侧握手完不成；手机自己的 5G 发射是好的
> （ch149 自建 AP 能被 PC / 另一台手机看到）。**把路由器 5G 信道改成 149~165 即可**，
> 详见 `docs/root-cause.md` §10。已定案暂停，不要在这上面继续耗。

> ⚠️ **前提：档案必须是 `0600`。** payload 打包时（`05-make-payload.sh`）已经 `chmod 600`；
> 如果是旧设备/旧解包，`wifi-up.sh` 会 `chmod 600` + `nmcli con reload` 兜底。
> 症状是 NM 日志里
> `keyfile: load: ".../560-wifi.nmconnection": failed to load connection: File permissions (100777) are insecure`，
> `nmcli con show` 里根本没有 `560`、`wlan0` 一直是 `unmanaged`（2026-10-18 实测踩到，
> 见 `docs/root-cause.md` §10.9）。手工修：`chmod 600 /etc/NetworkManager/system-connections/*.nmconnection; nmcli con reload`。

> ⚠️ **前提：rootfs 里得有 NetworkManager（或至少 wpa_supplicant）。** 手机没网装不了东西，所以先确认：
>
> ```sh
> command -v wpa_supplicant wpa_cli iw
> ls /lib/systemd/system/wpa_supplicant@.service
> ```
>
> 三样都没有的话，`wlan0` 出来了也连不上网。那时可以用
> `iw dev wlan0 scan | head` 先确认射频正常，再想办法补 wpa_supplicant
> （在编译机上拆 Debian/Ubuntu 的 arm64 deb 塞进 payload，就像 tqftpserv 那样）。
> `wifi-diag.sh` 的第 6 关会自动列出这几样在不在。

---

## 第 7 关 —— 启动可用性（★ 判据是"不开串口也能起来"）

```sh
# PC 侧触发重启：★ 用 --no-block，别把 reboot 放进 `( ... ) &` 后台子 shell
#   （SSH 一断开就被 SIGHUP 杀掉，看起来像"重启没生效"）
ssh umeko@169.254.42.1 'systemctl reboot --no-block'

# 起来之后（全程不要打开 COM5）：
uptime
systemd-analyze blame | head -10
systemctl --failed --no-legend
cat /run/wifi-up.log
nmcli -t dev status | grep wlan0
```

通过的样子（2026-10-18 `usb9` 实测口径）：

| 指标 | 期望（`usb11` 实测口径） | 必须能认出来的坏值 |
|---|---|---|
| `dev-sda31.device` | **1.6 秒** | **`9min 2s`** = cmdline 里 `console=ttyGS0` 把 printk 卡住（§10.6） |
| `usb-net.service` | **747 ms** | **`3min`（failed）** = 单元内的同步 `systemctl` 与它自己的 `Before=network-pre.target` 互等（§10.10） |
| SSH 可用 | **+56 秒** | **`+234 秒`** = 恰好等于 usb-net 的超时时间 → 顺序死锁，不是网络问题（§10.10） |
| `wlan0` = connected | **+63 秒** | `+244 秒`（被 usb-net 拖后） |
| 关机耗时（reboot → SSH 断） | **2 秒** | **`780 秒`** = modem 崩溃循环时 WiFi 操作全部 `-110` 超时（§10.9） |
| modem 崩溃次数 | **`0`** | 每 ~40 秒 +1（`rmtfs`/`pd-mapper` 没工作） |
| `systemctl --failed` | **空** | `pd-mapper.service` = 被启动频率限制锁死（§10.11） |
| `systemd-analyze blame` 头名 | **`wifi-up.service` ≈ 12 秒** | `usb-net.service` 3 分钟 |

> 速查：`systemd-analyze blame | head -3`；`journalctl -u wifi-up -b --no-pager` 看**各阶段真实时间戳**；
> `wifi-up.sh` 结束时会往 `/dev/tty0`（手机屏幕）打一行自检结果（ASCII，fbcon 没有中文字形）。

---

## 第 8 关 —— 日志噪音清零 + 触摸 + RTC（★ 2026-10-18 `usb13` 起）

前 7 关管"能不能用"，这一关管"干不干净"外加两个功能落点（触摸 / RTC 跨重启）。
PC 侧用法：把 `r95.sh` / `r96.sh` / `r97.sh` scp 到手机上 `bash` 跑，结果同时打到手机屏幕
（★ 屏幕提示只能用 ASCII —— edk2 GOP / fbcon 的内置字体没有中文字形，写中文会变方块）。

### 8.1 噪音（判据：err 级为 0，warn 只剩 3 条已知保留）

| 指标 | usb12 实测 | usb13 目标 | 说明 |
|---|---|---|---|
| `dmesg -l err,crit,alert,emerg` 条数 | 2 | **0** | 两条都是"延迟探测 / 桥链没有下一级"被当 err 打出来 → 补丁 0003 / 0004（§10.14 A） |
| `dmesg -l warn` 条数 | 6 | **3** | 保留 `KASLR disabled`、`ITS: No ITS available`、`clk: Not disabling unused clocks`（§10.14 D） |
| `WARNING:` / `BUG:` / `Oops` / `panic` / `gpf` | 0 | **0** | 任何一个非 0 都要停下来查 |
| `systemctl --failed` | 空 | **空** | |

```sh
dmesg -l err,crit,alert,emerg | grep -c .      # → 0
dmesg -l warn | sort | uniq -c                 # → 只剩那 3 条
systemctl --failed --no-legend                 # → 空
```

坏值速认：

- 又出现 `qmp-combo-phy … devm_regulator_bulk_get` → 补丁 0003 没打上
- 又出现 `aux_bridge … failed to acquire drm_bridge` → 补丁 0004 没打上
- 出现 `ufshcd-qcom … vccq2 get failed, err=-517` → 补丁 0007 没打上
  （★ `-517` = `-EPROBE_DEFER`，是"延迟探测被当 err 打"，不是真故障；系统会自愈）
- `ath10k_snoc: supply vdd-3.3-ch1 not found` → DTB 的 WiFi 收尾段没编进去
  （查 `cat /proc/device-tree/soc@0/wifi@18800000/vdd-3.3-ch1-supply`，应该打印一串 phandle 字节）
- `ath10k_snoc: invalid MAC address; choosing random` → 补丁 0002 与 DTB `local-mac-address` 缺一
  （★ 即使这条在，NM 也会用 `cloned-mac-address` 把用户态 MAC 固定住，所以是一条"假安全"的噪音）

> 先确认跑的是哪个 Image：`uname -v`（里面有编译时间/编号，每次重编都会变），
> 以及 `cat /etc/wifi-cfg.ver`（payload 版本号）。两个都要是当轮的。

### 8.2 触摸（这一关要真的摸一下屏幕）

```sh
ls /sys/bus/i2c/devices/ | grep 17-0049            # 设备在不在（i2c17 + 地址 0x49）
readlink -f /sys/bus/i2c/devices/17-0049/driver    # → .../drivers/ftm5
grep -iE 'fts|touch' /proc/bus/input/devices       # 有没有 input 设备
bash /root/r96.sh                                  # ★ 会往手机屏幕打提示，让你摸 40 秒
```

通过的样子：

- `17-0049` 存在且 driver 指向 `ftm5`（`FTS_TS_DRV_NAME`，老版本叫 `fts_touch`）；
- `/proc/bus/input/devices` 里有 name 含 `fts` 的 event 节点；
- 摸的时候 `r96.sh` 报 `RESULT: TOUCH OK (N events)`（N>0）；完全不摸则 `NO TOUCH EVENTS`
  （= 驱动在、但没数据/没中断）。

坏值速认：

- 没有 `17-0049` → i2c17 没开（查 DTB 的 `i2c@c80000` status）或 QUP wrapper 没开
- `17-0049` 在但没 driver → probe 失败，看 `dmesg | grep -i fts`
  （最常见：`st,regulator_dvdd` / `st,regulator_avdd` 给的字符串与 `*-supply` 对不上）
- 驱动在、能读设备但摸不动 → 中断没通：确认 `st,irq-gpio = <&tlmm 122 …>` 编进去了
  （★ 这个驱动**不读** `interrupts` 属性，中断是从 `st,irq-gpio` 用 `gpio_to_irq()` 拿的）
- 坐标错位／只能划一半屏 → `st,max-coords = <1079 2339>` 没编进去（驱动默认 1440x2560-1）

### 8.3 RTC（跨重启才算过）

```sh
bash /root/r97.sh before          # 写一次 + 记录（写入前后都会打印 nvmem offset）
# PC 侧：systemctl reboot --no-block
bash /root/r97.sh after           # 起来后对比
```

通过的样子：

- `rtc0` 的 name = `rtc-pm8xxx`；
- `before` 里"写完后 RTC 读数"≈ 当时的系统时间（不再是 `1970-01-03`）；
- 重启后 `after` 打印 `结论：★ RTC 成功跨过了这次重启（差值 < 10 分钟）`。

坏值速认：

- `hwclock -w` 报 `Invalid argument` → `nvmem-cells = <&rtc_offset>` / `rtc-offset@bc`
  没编进 DTB（§10.14 B）
- 写的时候不报错、但重启后丢 → SDAM cell 没真写进去：
  比较 `od -An -tx4 -j 188 -N 4 /sys/bus/nvmem/devices/*/nvmem` 在写前后的值

> 提醒：`/usr/sbin/rtc-save.sh` 是**开机 2 分钟后**才第一次写（timer 的 `OnBootSec=2min`），
> 刚开机那 2 分钟内 RTC 里还是上一次的值，这是正常的。

### 8.4 顺带确认（本轮新增落点）

```sh
cat /etc/wifi-cfg.ver                                       # → 2026-10-18-usb13
cat /sys/class/net/wlan0/address                            # → 02:00:71:96:e3:d6
readlink /etc/systemd/system/netplan-ovs-cleanup.service    # → /dev/null
systemctl is-active rtc-save.timer                          # → active
test -x /usr/local/bin/busybox && echo busybox ok
test -e /usr/lib/firmware/stm_fts_production_limits.csv && echo limits ok
cat /proc/device-tree/model | tr -d '\0'; echo             # → Xiaomi Mi 9 (cepheus)
```

---

## 附：常用定位命令

```sh
# 内核看 ath10k 的完整状态（需要 CONFIG_ATH10K_DEBUGFS，已在 02 里打开）
ls /sys/kernel/debug/ath10k/ 2>/dev/null
cat /sys/kernel/debug/ath10k/snoc*/simulate_fw_crash 2>/dev/null

# QRTR 名字服务里有没有 WLFW（qmi 服务）
ls /sys/class/rpmsg/
cat /sys/bus/rpmsg/devices/*/name 2>/dev/null

# remoteproc 的完整状态
for r in /sys/class/remoteproc/*; do echo "== $r"; cat $r/name; cat $r/state; done

# wifi-up 自己的日志（最有用的一份）
cat /run/wifi-up.log
journalctl -u wifi-up -n 100 --no-pager

# 一次性把上面所有东西打包
sh /usr/sbin/wifi-diag.sh 2>&1 | tee /tmp/wifi-diag.txt
```

## 九、蓝牙（WCN3990 / uart13，2026-10-19 加入）

### 9.1 设备树有没有真的生效

```sh
cat /proc/device-tree/soc@0/geniqup@cc0000/serial@c8c000/status      # 期望 okay
ls  /proc/device-tree/soc@0/geniqup@cc0000/serial@c8c000/            # 期望看到 bluetooth
cat /proc/device-tree/soc@0/geniqup@cc0000/serial@c8c000/bluetooth/local-bd-address \
    | od -An -tx1                                                    # 期望 02 00 71 96 e3 d7
```

> 注意两条容易误判的路径：`geniqup@ac0000`（含 `serial@a90000`/uart2）是**调试串口**，
> 一直是 disabled；蓝牙在 `geniqup@cc0000`（uart13）。DTB 里真有节点、运行时不出现，
> 八成是刷了旧的 `boot-cepheus.img`（见 root-cause §10.17 B-3）。

### 9.2 驱动与固件

```sh
dmesg | grep -iE 'hci0|qca|wcn3990'
# 期望依次看到：
#   Bluetooth: hci0: setting up wcn399x
#   QCA Downloading qca/crbtfw21.tlv
#   QCA Downloading qca/crnv21.bin
#   QCA setup on UART is completed
lsmod | grep -E 'hci_uart|btqca'          # 两个模块都在
ls /lib/firmware/qca/crbtfw21.tlv* /lib/firmware/qca/crnv21.bin*   # 有 .zst 也行
```

### 9.3 控制器状态（蓝莓 = bluez 5.72，apt 装的）

```sh
hciconfig -a          # UP RUNNING；ACL MTU 1024:7；BD Address 非 00:00:00:00:00:00
bluetoothctl show     # Controller ... (public) / Powered: yes
timeout 10 bluetoothctl scan on     # 能列出周围 BLE 设备
```

若出现下面任一现象，直接对号入座：

| 现象 | 原因 |
|---|---|
| `hci0` 不存在，dmesg 无 `setting up wcn399x` | uart13 没 okay / 没刷对新 boot |
| `QCA Failed to request file: qca/crbtfw01.tlv (-2)` | 缺 `firmware-name`，驱动按错误的 rom_ver 拼了文件名 |
| `Can't init device hci0: Operation not supported (95)` + `bluetoothctl` 报 No default controller | 缺 `local-bd-address`，控制器处于 HCI_UNCONFIGURED |


---

## 十、充电与电量（PM8150B，2026-10-19 加入）

### 10.1 一次跑完的检查

```sh
# 1) 两个 psy 都在
ls /sys/class/power_supply/                 # pm8150b-charger  qcom-battery

# 2) 数值是否合理
cat /sys/class/power_supply/qcom-battery/capacity      # 0..100
cat /sys/class/power_supply/qcom-battery/voltage_now   # ~4 300 000 uV
cat /sys/class/power_supply/qcom-battery/temp          # 0.1C，如 340 = 34.0C
cat /sys/class/power_supply/pm8150b-charger/online     # 插电=1
cat /sys/class/power_supply/pm8150b-charger/usb_type   # 方括号里是当前端口类型

# 3) 驱动真的绑上了
dmesg | grep -i "qcom-smbx\|qcom-fg"       # Generation SMB5

# 4) 限充守护
systemctl is-enabled mi9-charge-guard      # enabled
systemctl is-active  mi9-charge-guard      # active
/usr/sbin/mi9-charge-guard.sh --status

# 5) 停充/恢复（会真的停止从 USB 取电，但 SSH/RNDIS 不受影响）
/usr/sbin/mi9-charge-guard.sh --stop
sleep 2; cat /sys/class/power_supply/pm8150b-charger/online      # 0
/usr/sbin/mi9-charge-guard.sh --resume
sleep 2; cat /sys/class/power_supply/pm8150b-charger/online      # 1
journalctl -t mi9-charge-guard -n 10 --no-pager
```

### 10.2 判据

| 项 | 合格 |
|---|---|
| psy | `pm8150b-charger` + `qcom-battery` 同时存在 |
| 电量 | `capacity` 在 0..100，且与"用了多久"趋势一致 |
| 电压 | 3.4–4.4 V（满电 4.39–4.40 V） |
| 温度 | 20–40 °C 常见；≥45 °C 守护必须停充 |
| 守护 | `enabled` + `active`，状态文件 `/run/mi9-charge-guard.state` 为 resumed/suspended |
| 停充 | 写 Unknown 后 `online=0` 且电池电流为负；写 Charging 后恢复为正 |

### 10.3 故障对照

| 现象 | 原因 / 修法 |
|---|---|
| `/sys/class/power_supply` 为空 | DTB 没带 `cepheus-chg.dtsi`（`charger@1000` / `fuel-gauge@4000` 不是 okay）→ 重编 DTB 并刷 boot |
| 只有 `pm8150b-charger`，没有 `qcom-battery` | `&pm8150b_fg` 没开，或 FG probe 失败（看 `dmesg | grep -i fg`） |
| `charger@1000` probe 报 `Couldn't get usbin_v IIO channel` | `pm8150b_adc` 被关掉了（本机默认是开的） |
| 插墙充仍是 450/500 mA | 端口被识别成 SDP；换线/换口，或看 `usb_type` 方括号值 |
| 守护 `enabled` 但 `inactive (dead)`、日志为空 | unit 里同时写了 `After=multi-user.target` 与 `WantedBy=multi-user.target`（排序环）→ 删掉 After |
| 停充后电量不降 | 电流显示为 0 是因为刚切换，等 10 s 再看 `current_now` |
| 电池 `status` 显示 Charging 但电流为负 | FG 的状态判断在"输入挂起"时不可信，看 `online` / 守护状态文件 |
---

## 十一、WiFi 吞吐与 5G（2026-10-19 加入）

### 11.1 2.4G 吞吐

```sh
# 设备侧
iperf3 -s -1 -p 5201 &
# PC 侧（WSL）
iperf3 -c 192.168.31.177 -t 10 -P 4      # 上行
iperf3 -c 192.168.31.177 -t 10 -P 4 -R   # 下行
```

判据：2.4G / 20 MHz 下 **≥ 50 Mbit/s** 算正常（本机实测 60–72 Mbit/s，PC 也走 WiFi 属共享空口）。

### 11.2 5G 能力（不依赖路由器）

```sh
nmcli con down 560
iw phy phy0 interface add ap0 type __ap
ip link set ap0 address 02:00:71:96:e3:dd
ip link set ap0 up
hostapd -B /tmp/hostapd-ch44.conf       # hw_mode=a, channel=44 或 149
iw dev ap0 info                          # 应显示 type AP + channel 44/149
# 用另一台设备"定向连接"该 SSID：
#   Windows: netsh wlan add profile ... ; netsh wlan connect name=<profile>
pkill hostapd; iw dev ap0 del; nmcli con up 560
```

判据：ch44 与 ch149 都能被 PC 关联 → 手机 5G 收发正常。

### 11.3 连不上家里 5G 时怎么判断

| 现象 | 判断 |
|---|---|
| 手机能扫到 5G（-30~-50 dBm），auth 3 次全超时 | 路由器不回应；看 5G 安全模式 / WiFi6 模式 / MAC 过滤 / band steering |
| 手机自建 AP 在同一信道能被别的设备连上 | 手机的发射没问题，问题在路由器 |
| `netsh wlan show networks` 只列出 1 个 SSID | Windows 扫描缓存，**不能**据此判断"扫不到"；改用定向连接 |
| 自建 AP 在 ch44 起不来 / 立刻 DOWN | 看 `iw reg get`（CN 允许 5150–5250）与 `dmesg | grep -i dfs` |

### 11.4 故障对照

| 现象 | 原因 / 修法 |
|---|---|
| 自建 AP 报 `Name not unique on network` | ap0 与 wlan0 用了同一个 MAC，先 `ip link set ap0 address <不同 MAC>` |
| `netsh` 里 SSID 列表不刷新 | Windows 扫描节流；等 15–30 s 或直接定向连接 |
| 5G 关联后没有 IP | 自建 AP 没跑 DHCP；测链路用，不必拿 IP |
### 9.4 长稳（soak，30 分钟）

```sh
# 设备上（脚本已放在 /root/bt-soak.sh）
nohup /root/bt-soak.sh >/dev/null 2>&1 &
tail -f /var/log/bt-soak.log
```

判据：

| 项 | 合格 |
|---|---|
| 轮次 | 40/40 完成 |
| 状态 | 每轮都 `UP RUNNING`，0 次掉线 |
| 扫描 | 每轮 8 个以上 BLE 设备 |
| 计数器 | `hciconfig` 的 `errors: 0` |
| 强制 off/on | 允许偶发 1 次 `baudrate` 超时，但下一轮必须自恢复 |

日常开关蓝牙请用 `bluetoothctl power off/on`，**不要** `hciconfig down/up`
（后者会重新跑 QCA 固件初始化，偶发 `command tx timeout`）。
## 第 12 关 —— 屏幕省电（开机 60 s 熄屏 / 电源键唤醒）

```sh
# 开机 60 s 后（timer 从内核启动算起，不等 wifi-up）
systemctl list-timers mi9-screen-off.timer
cat /run/mi9-screen.state                  # off
systemctl is-active mi9-dashboard.service  # inactive
od -An -tx1 -N16 /dev/fb0                  # 全 0
md5sum /dev/fb0                            # 隔 10 s 再算一次，必须一样（光标没有重绘）
cat /sys/class/graphics/fbcon/cursor_blink # 0
cat /proc/sys/kernel/printk                # 1 4 1 7（console_loglevel=1）

# 短按电源键
cat /run/mi9-screen.state                  # on
systemctl is-active mi9-dashboard.service  # active
journalctl -u mi9-pwrkey -n 5              # mi9-pwrkey: wake

# 手动切换
/usr/local/sbin/mi9-screen.sh off|on|toggle|status
```

判据：屏黑后 ssh / 串口**不受影响**；短按电源键画面回来；长按电源键仍是 PMIC 硬关机。

注意：`/sys/class/graphics/fb0/blank` 在本机是 EINVAL（simplefb 没有实现
`fb_blank`），`/sys/module/kernel/parameters/consoleblank` 也是只读的（0444），
所以**不要**试图用 `echo 4 > .../blank` 或内核 console blanking 熄屏 ——
payload 里的做法是停仪表盘 + 关光标闪烁 + 写黑 framebuffer。
