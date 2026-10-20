#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 05-make-payload.sh —— 打包 wifi-cfg.tar.gz
#
#   bash 05-make-payload.sh [--wlanmdsp <wlanmdsp.mbn>] [--board2 <board-2.bin>]
#
# 所有内容都取自 firewalls_dir/payload/ 这份模板（= 交付包里已经放好的文件），
# 所以正常情况下不需要任何参数，直接跑即可。
#
# wifi-cfg.tar.gz 会被 initramfs 解包到 rootfs 的 / 上，内容：
#   usr/bin/tqftpserv                                 ← ADSP 要的 TFTP 服务端
#   usr/lib/tqftpserv-bundle/libqrtr.so.1.0           ← 它的运行时依赖（按需补）
#   usr/lib/tqftpserv-bundle/libzstd.so.1.5.5
#   usr/sbin/wifi-up.sh                               ← 按顺序拉起 qrtr/tqftpserv/adsp/ath10k
#   etc/systemd/system/{tqftpserv,wifi-up}.service
#   etc/systemd/system/multi-user.target.wants/…      ← 启用
#   etc/modules-load.d/wifi.conf                      ← 模块加载顺序
#   etc/wpa_supplicant/wpa_supplicant-wlan0.conf      ← 兜底用（NM 才是主路径）
#   etc/systemd/network/25-wlan0.network              ← DHCP
#   usr/lib/firmware/qcom/sm8150/wlanmdsp.mbn          ← ★ ADSP 通过 tqftpserv 要的文件
#                                                        （★ 必须是手机自带厂商版，
#                                                          4054436 B / md5 a84629fea38d647dff0dd74154ae30d1；
#                                                          linux-firmware 那份 3725044 B 会让
#                                                          modem 每 ~42s 崩一次 → wlan0 不出现）
#   usr/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin  ← ★ 实测可用那份（26440 B，
#                                                          md5 38c24167a9ba16150f07a03f4dd68218）
#   usr/lib/firmware/ath10k/WCN3990/hw1.0/firmware-5.bin ← 60 字节桩，列出 ath10k API 版本
#   etc/NetworkManager/system-connections/mi9-wifi.nmconnection ← 2.4G(SSID 560) 自动连
#                                                          （band=bg 锁 2.4G，psk 在内）
#   etc/systemd/network/25-wlan0.network.unused        ← 只在没有 NM 时由 wifi-up.sh 启用
#                                                        （有 NM 时它会让 networkd 和 NM 抢 wlan0）
#
# ★★ 固件必须放 usr/lib/firmware，**绝对不能**让包里出现 ./lib/ 这一项！
#   rootfs（Ubuntu merged-usr）里 /lib 是指向 usr/lib 的**符号链接**。
#   tar 解压 `./lib/`（目录项）时默认会把符号链接**换成一个真实空目录**，
#   于是 /lib/ld-linux-aarch64.so.1 消失 → 全系统动态程序（bash/ls/ssh）全部
#   变成 "cannot execute: required file not found"。2026-10-18 就是这么把手机
#   搞瘫的。放 usr/lib/firmware 时 /lib 只是被"穿过"（写入 usr/lib/firmware），
#   符号链接完好无损；运行时 /lib/firmware 照样能访问到同一份文件。
#
# ★★ 关于 wlanmdsp.mbn 的落点（有源码依据，别再改路径）：
#   upstream tqftpserv 的 translate.c 会遍历 /sys/class/remoteproc/*/firmware，
#   取每个 remoteproc 的 firmware-name 的【目录名】，拼成
#       /lib/firmware/<目录名>/<客户端请求的相对路径>
#   我们的 DTB 给 ADSP 和 MPSS 都写了 firmware-name = "qcom/sm8150/xxx.mdt"，
#   目录名就是 qcom/sm8150，所以文件必须放
#       /lib/firmware/qcom/sm8150/wlanmdsp.mbn
#   （两个 remoteproc 都是这个目录名，所以就算其中一个没配对成功也还能命中）
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$HERE/out}"
WLANMDSP=""; BOARD2=""
while [ $# -gt 0 ]; do
	case "$1" in
		--wlanmdsp) WLANMDSP="$2"; shift 2;;
		--board2)   BOARD2="$2";   shift 2;;
		*) echo "未知参数: $1" >&2; exit 1;;
	esac
done
mkdir -p "$OUT"

# ★ 暂存目录必须放在 **Linux 本地文件系统**（/tmp），不能放 out/。
#   仓库在 /mnt/c（Windows 挂载）上，那里 chmod 是无效的 —— 目录永远显示 0777，
#   于是后面 `chmod 755 "$STAGE"` 白做，tar 里的 "./" 就是 drwxrwxrwx，
#   解压到手机后 **/ 会被 chmod 成 0777**（SSH 直接全废）。
#   2026-10-21 就是这么被 05 的权限回归测试拦下来的。
STAGE="${MI9_PAYLOAD_STAGE:-/tmp/mi9-payload-stage}"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$HERE/payload/." "$STAGE/"

# --- ★ WiFi 口令不进仓库：仓库里只有 *.example，真实档案被 .gitignore 排除 ----
#   刚 clone 下来还没有真实档案时用模板兜底（否则整个构建会缺文件），
#   但必须在日志里说清楚：模板里的 psk 是占位符，设备不会自动连上。
for p in "etc/NetworkManager/system-connections/mi9-wifi.nmconnection" \
         "etc/wpa_supplicant/wpa_supplicant-wlan0.conf"; do
	if [ ! -f "$STAGE/$p" ] && [ -f "$STAGE/$p.example" ]; then
		cp -a "$STAGE/$p.example" "$STAGE/$p"
		echo "⚠️ 缺少 $p，已用 .example 兜底（psk 是占位符，设备不会自动连 WiFi）"
	elif [ -f "$STAGE/$p" ]; then
		# 仓库里不存在这两份文件（.gitignore 排除真实档案），能走到这里说明
		# 本机用 10-provision-wifi.ps1 灌过真实口令 —— r2 泄密就是这条路径。
		if grep -q 'changeme123' "$STAGE/$p" 2>/dev/null; then
			echo "✓ $p 仍是占位符（psk=changeme123），可安全公开"
		else
			echo "⚠️ $p 含本机真实 WiFi 口令：这个包只能自用，公开镜像前必须"
			echo "   删除 payload/ 下的 mi9-wifi.nmconnection 与 wpa_supplicant-wlan0.conf"
		fi
	fi
done

# --- ★ 归一化：把 payload 里的 lib/ 并进 usr/lib/，并从包里彻底去掉 lib/ ---
# 原因见文件头：Ubuntu 的 /lib 是 → usr/lib 的符号链接，包里有 ./lib/ 目录项
# 就会把符号链接顶掉，整机 userland 报废。
if [ -d "$STAGE/lib" ]; then
	mkdir -p "$STAGE/usr/lib"
	cp -a "$STAGE/lib/." "$STAGE/usr/lib/"
	rm -rf "$STAGE/lib"
	echo "已把 payload/lib/ 合并进 payload/usr/lib/（避免顶掉 rootfs 的 /lib 符号链接）"
fi

# --- 同步 tqftpserv 的二进制与运行时依赖（优先用 04 脚本的产物）---
if [ -s "$OUT/tqftpserv" ]; then
	mkdir -p "$STAGE/usr/bin"
	install -m 0755 "$OUT/tqftpserv" "$STAGE/usr/bin/tqftpserv"
	echo "已放入 tqftpserv <- out/ ($(stat -c%s "$OUT/tqftpserv") 字节)"
elif [ -s "$STAGE/usr/bin/tqftpserv" ]; then
	echo "使用 payload/ 里已带的 tqftpserv ($(stat -c%s "$STAGE/usr/bin/tqftpserv") 字节)"
else
	echo "⚠️ 没有 tqftpserv 二进制 —— WiFi 一定不工作！先跑 04-build-tqftpserv.sh"
fi
if [ -s "$OUT/tqftpserv.service" ]; then
	install -m 0644 "$OUT/tqftpserv.service" "$STAGE/etc/systemd/system/tqftpserv.service"
	echo "已放入官方 tqftpserv.service <- out/"
fi
for so in libqrtr.so.1.0 libzstd.so.1.5.5; do
	if [ -s "$OUT/$so" ]; then
		mkdir -p "$STAGE/usr/lib/tqftpserv-bundle"
		install -m 0644 "$OUT/$so" "$STAGE/usr/lib/tqftpserv-bundle/$so"
		echo "已放入运行时依赖 $so"
	fi
done

# --- wlanmdsp.mbn：只有 qcom/sm8150/ 那一份有用 -------------------------------
#   upstream tqftpserv 按 remoteproc 的 firmware-name 目录名去 /lib/firmware/<dir>/
#   取文件，我们的 DTB 是 qcom/sm8150/*.mdt → 所以只认
#       /lib/firmware/qcom/sm8150/wlanmdsp.mbn
#   ath10k/WCN3990/hw1.0/ 下那份**没有任何作用**（2026-10-18 实测过），不再放，
#   免得以后有人以为换了那里就能生效。
mdsp_qcom="$STAGE/usr/lib/firmware/qcom/sm8150/wlanmdsp.mbn"
rm -f "$STAGE/usr/lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn"
if [ -n "$WLANMDSP" ] && [ -f "$WLANMDSP" ]; then
	mkdir -p "$(dirname "$mdsp_qcom")"
	install -m 0644 "$WLANMDSP" "$mdsp_qcom"
	echo "已用 --wlanmdsp 覆盖 $mdsp_qcom"
fi
if [ -s "$mdsp_qcom" ]; then
	_msize=$(stat -c%s "$mdsp_qcom")
	echo "✓ wlanmdsp.mbn 已就位: $_msize 字节  ($mdsp_qcom)"
	if [ "$_msize" = 4054436 ]; then
		echo "  ✓ 是厂商版（ADSP/modem 不会 42s 崩）"
	elif [ "$_msize" = 3725044 ]; then
		echo "  ✗✗ 这是 linux-firmware 版！modem 会每 ~42 秒崩一次，wlan0 不会出现。"
		echo "      换成手机自带那份：bash 05-make-payload.sh --wlanmdsp <厂商 wlanmdsp.mbn>"
		exit 1
	else
		echo "  ⚠ 大小既不是 4054436(厂商版) 也不是 3725044(linux-firmware 版)，请确认来源"
	fi
else
	echo "⚠️ 没有 wlanmdsp.mbn！ADSP 会拿不到 WLAN 固件，wlan0 不会出现。"
	echo "   解决：bash 05-make-payload.sh --wlanmdsp <手机上的 wlanmdsp.mbn>"
	exit 1
fi

# --- board-2.bin --------------------------------------------------------------
#   payload 里那份是**实测可用**的 linux-firmware 版：
#       26440 B / md5 38c24167a9ba16150f07a03f4dd68218
#   2026-10-18 实测（2.4G 连上 + 5G ch149 自建 AP 被 PC/另一台手机看到 + ath10k 探测
#   全部正常）用的就是它。厂商大包（893528 B，md5 420356eb…）留在 extras/ 里备查，
#   没必要用它 —— 想试可以 --board2 指定。
b2="$STAGE/usr/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin"
if [ -n "$BOARD2" ] && [ -f "$BOARD2" ]; then
	install -m 0644 "$BOARD2" "$b2"
	echo "已用 --board2 覆盖 board-2.bin"
fi
if [ -s "$b2" ]; then
	echo "✓ board-2.bin 已就位: $(stat -c%s "$b2") 字节 (md5 $(md5sum "$b2" | cut -d' ' -f1))"
	if command -v strings >/dev/null 2>&1; then
		printf '   里面的 qmi-chip-id: '
		strings "$b2" | grep -oE 'qmi-chip-id=[0-9]+' | sed 's/qmi-chip-id=//' | sort -un | tr '\n' ' '
		echo
	fi
else
	echo "⚠️ 没有 board-2.bin，ath10k 可能报 unsupported chip id"
fi

# --- 启用 systemd 单元 ---
# ★ 2026-10-19 起本机定位改为**服务器**（用户决定放弃 GUI，纯命令行/SSH 使用），
#   所以 phoneui.service **不再自动启用**。文件仍然留在 payload 里（/root/phoneui/*.py
#   + unit），哪天想看画面 `systemctl enable --now phoneui` 就能捡回来。
mkdir -p "$STAGE/etc/systemd/system/multi-user.target.wants"
for u in tqftpserv.service wifi-up.service usb-net.service rtc-save.service \
         mi9-dashboard.service mi9-charge-guard.service \
         mi9-audio-setup.service \
         mi9-pwrkey.service; do
	[ -f "$STAGE/etc/systemd/system/$u" ] && \
		ln -sf "/etc/systemd/system/$u" "$STAGE/etc/systemd/system/multi-user.target.wants/$u"
done
mkdir -p "$STAGE/etc/systemd/system/timers.target.wants"
for t in rtc-save.timer mi9-doctor.timer mi9-screen-off.timer mi9-soak.timer; do
	[ -f "$STAGE/etc/systemd/system/$t" ] && \
		ln -sf "/etc/systemd/system/$t" "$STAGE/etc/systemd/system/timers.target.wants/$t"
done

# --- 命令入口：文档里一直写 `mi9-doctor` / `mi9-status` / `mi9-snapshot`，---------
#   但包里只有 *.sh，设备上敲命令是 command not found（2026-10-20 发现）。
#   这里补不带后缀的符号链接，.sh 仍保留（脚本之间互相调用用的是全名）。
for s in mi9-doctor mi9-status mi9-snapshot mi9-restore; do
	if [ -f "$STAGE/usr/sbin/$s.sh" ] && [ ! -e "$STAGE/usr/sbin/$s" ]; then
		ln -sf "/usr/sbin/$s.sh" "$STAGE/usr/sbin/$s"
	fi
done

# --- ★ tty1 的 getty 换成状态仪表盘（2026-10-19 服务器化）--------------------
#   手机没键盘，tty1 上那个 getty（自动登录 root）谁也敲不了，纯占屏。
#   改成 mi9-dashboard.service 往 tty1 画只读状态屏；交互走串口 ttyGS0 / SSH。
#   想恢复登录提示符：systemctl unmask getty@tty1 && systemctl start getty@tty1
#   （顺带把 GETTY 盘出来，将来真接上 USB 键盘时有据可查）
ln -sf /dev/null "$STAGE/etc/systemd/system/getty@tty1.service"

# --- 屏蔽 netplan 的 generator（systemd 每条开机刷一条 warn）------------------
# netplan 的 systemd generator 会在 /run/systemd/system/ 里生成
# netplan-ovs-cleanup.service，那份文件权限是 "world-inaccessible"，
# 于是每次开机都有一条：
#   "Configuration file /run/systemd/system/netplan-ovs-cleanup.service is
#    marked world-inaccessible. This has no effect as configuration data is
#    accessible via APIs without restrictions. Proceeding anyway."（warn 级）
# 我们完全不用 netplan（网络是 NetworkManager 管的），直接屏蔽：
#   /etc/systemd/system/ 的优先级高于 /run/systemd/system/，
#   屏蔽后 systemd 连加载都不会加载 /run 里那份，warn 消失。
# （2026-10-18 usb12 实测：这条是剩下 6 条 warn 里唯一与我们 payload 无关的）
ln -sf /dev/null "$STAGE/etc/systemd/system/netplan-ovs-cleanup.service"

# --- ★ 屏蔽 rootfs 镜像自带的遗留服务（2026-10-19 服务器化）--------------------
#   这台机器的 rootfs 是别人做的 **Klipper / 3D 打印机**镜像，自带一堆跟我们
#   毫无关系、开机就抢 CPU/内存/端口的服务（2026-10-19 实测开机后真在跑）：
#     klipper / moonraker（打印机固件 + API 服务）
#     crowsnest（摄像头串流）      nginx（web 前端）
#     autocanup（CAN 总线脚本）    autowebssh（网页 SSH）
#     auto_rmi4_reload（反复重载触摸屏 rmi4 模块，而且**开机就 failed**）
#   另外还有 **三套网络管理同时跑**（NetworkManager + systemd-networkd +
#   ifupdown/networking），以及 apport / motd-news / man-db / e2scrub 这类噪音。
#   做法：在 /etc/systemd/system/ 放 -> /dev/null 的软链接——效果等于
#   `systemctl mask`，但**不需要 systemd 在运行**就能固化，解压即生效，并且
#   以后 `systemctl unmask xxx` 可以随时反悔。
for u in klipper.service moonraker.service crowsnest.service nginx.service \
         autocanup.service autowebssh.service auto_rmi4_reload.service \
         networkd-dispatcher.service systemd-networkd.service \
         systemd-networkd.socket systemd-networkd-wait-online.service \
         networking.service systemd-network-generator.service \
         apport.service apport-autoreport.service apport-autoreport.path \
         apport-autoreport.timer apport-forward.socket \
         motd-news.timer man-db.timer e2scrub_reap.service e2scrub_all.timer; do
	ln -sf /dev/null "$STAGE/etc/systemd/system/$u"
done

# --- zram 交换（zram-swap.service 是 WantedBy=swap.target）---------------------
mkdir -p "$STAGE/etc/systemd/system/swap.target.wants"
[ -f "$STAGE/etc/systemd/system/zram-swap.service" ] && \
	ln -sf /etc/systemd/system/zram-swap.service \
	       "$STAGE/etc/systemd/system/swap.target.wants/zram-swap.service"

# --- busybox：给 rtc-save.sh 提供 hwclock applet ------------------------------
# rootfs 上没有 util-linux-extra（= 没有 hwclock）。initramfs 包里那份
# /usr/lib/initramfs-tools/bin/busybox 通常都在，但那是别的包的私有文件，
# 哪天被清掉就没人能给 RTC 写时间了 → 自己带一份（01 脚本编的静态 aarch64）。
if [ -s "$OUT/busybox" ]; then
	mkdir -p "$STAGE/usr/local/bin"
	install -m 0755 "$OUT/busybox" "$STAGE/usr/local/bin/busybox"
	echo "已放入 busybox <- out/ ($(stat -c%s "$OUT/busybox") 字节)，供 rtc-save.sh 的 hwclock 用"
else
	echo "⚠️ 没找到 $OUT/busybox（rtc-save.sh 会退回用 rootfs 里已有的 busybox）"
fi

chmod +x "$STAGE/usr/bin/tqftpserv" "$STAGE/usr/sbin/wifi-up.sh" "$STAGE/usr/sbin/wifi-diag.sh" "$STAGE/usr/sbin/usb-mode.sh" "$STAGE/usr/sbin/rtc-save.sh" 2>/dev/null || true
# ★ /etc 下所有文件统一 0644（tar 会按源文件模式带出 Windows 侧的 0777）。
#   不统一的话 systemd 每次开机刷一堆（2026-10-18 usb11 冷启动实测 6 条）：
#     "Configuration file /etc/systemd/system/wifi-up.service is marked executable."
#     "... is marked world-writable."（usb-net.service / 10-timeouts.conf 同样）
#   注意只能用 -type f（不动符号链接，否则 chmod 会跟着改到目标上）。
find "$STAGE/etc" -type f -exec chmod 644 {} + 2>/dev/null || true

# ★★ /usr 下所有文件统一 0644，再把"确实要执行的"放回 0755 ★★
#   同样来自 Windows/drvfs 的 0777。危害比 /etc 那批**大得多**：
#   非 root 用户（本机 umeko，串口/tty1 都能拿到 shell）能改写
#   /usr/sbin/*.sh，而这些脚本是 **root 的 systemd 单元**在跑
#   → 等于本机任何登录用户都能提权成 root。
#   （2026-10-19 我就是**反过来**用了这个洞：把 /usr/sbin/rtc-save.sh 换成
#     一个含 chmod 的脚本，借 root 的定时器自救 —— 洞必须堵上，手法要记住。）
find "$STAGE/usr" -type f -exec chmod 644 {} + 2>/dev/null || true
# ★ 这几个目录里放的都是可执行脚本/程序，一律 755。
#   以前只匹配 *.sh，结果**不带 .sh 的脚本**（usr/sbin/mi9-doctor、
#   usr/local/bin/mi9-audio）被留成 644，开机 systemd 报
#       /bin/sh: 1: exec: /usr/local/bin/mi9-audio: Permission denied
#   mi9-audio-setup.service 于是一直失败（2026-10-21 踩到）。
chmod 755 "$STAGE/usr/bin/tqftpserv" \
          "$STAGE/usr/sbin/"* \
          "$STAGE/usr/local/sbin/"* \
          "$STAGE/usr/local/bin/"* 2>/dev/null || true

# ★ NetworkManager 的连接档案**必须是 0600**：tar 会按源文件模式带出 0777，
#   而 NM 见到 group/world 可读写会**直接拒绝加载**，日志是
#     keyfile: load: ".../mi9-wifi.nmconnection": failed to load connection:
#              File permissions (100777) are insecure
#   后果：`nmcli con show` 里根本没有 560 → 开机永远不会自动连（2026-10-18 实测踩到）。
#   注意 NM **不会**因为后来权限变好而自动重读，所以打包时就得是 600。
chmod 600 "$STAGE/etc/NetworkManager/system-connections/"*.nmconnection 2>/dev/null || true

# ★★★ 目录权限统一（2026-10-19 血泪教训，务必保留）★★★
#   payload 里的**目录条目**（./  ./etc/  ./usr/  ./root/ ...）是从 Windows(drvfs)
#   带出来的 0777，而 **GNU tar 解压时会连"已经存在的目录"一起 chmod** →
#     /  /etc  /usr  /usr/sbin ... 全变 0777；最致命的是 payload 里第一次出现
#     ./root/ 条目 → 手机上的 /root 变 0777 → sshd 的 StrictModes 判定
#     "home dir is group/world writable" → **直接拒绝 root 公钥登录**，
#     症状只有一句 "Permission denied (publickey,password)"，极难定位
#     （2026-10-19 实测：刷完 ui1 后 root SSH 全废，只有打串口用普通用户才救得回来）。
#   所以：打包时就把目录权限定死，并且 /root 必须 700。
find "$STAGE" -mindepth 1 -type d -exec chmod 755 {} + 2>/dev/null || true
# ★ 注意：find -mindepth 1 **不含 $STAGE 自身**，而 tar 里 "./" 那一项的权限就是
#   $STAGE 自己的权限（上面 `cp -a payload/.` 会把 payload/ 目录的 0777 带过来）
#   → 必须单独 chmod，否则手机上的 **/** 会被 chmod 成 0777（实测踩到过）。
chmod 755 "$STAGE"
[ -d "$STAGE/root" ] && chmod 700 "$STAGE/root"
[ -d "$STAGE/root/phoneui" ] && chmod 755 "$STAGE/root/phoneui"
# /root 下的文件：shell 脚本 700（可能要被 root 直接执行），其余 600（root 私有）
find "$STAGE/root" -type f ! -name '*.sh' -exec chmod 600 {} + 2>/dev/null || true
find "$STAGE/root" -type f -name '*.sh' -exec chmod 700 {} + 2>/dev/null || true
# NM 连接档案目录 700（NM 只硬校验文件 600，但目录收紧更安全）
chmod 700 "$STAGE/etc/NetworkManager/system-connections" 2>/dev/null || true
# ★★★ 目录权限统一结束 ★★★

( cd "$STAGE" && tar czf "$OUT/wifi-cfg.tar.gz" . )

# ★ 硬校验：包里**不许**出现 ./lib/ 这一项（会把 rootfs 的 /lib 符号链接顶掉）
tar tzf "$OUT/wifi-cfg.tar.gz" > "$OUT/.payload.list"
if grep -qE '^\.?/?lib(/|$)' "$OUT/.payload.list"; then
	echo "✗ 包里出现了 ./lib/ 目录项 —— 这会把 rootfs 的 /lib 符号链接顶掉，整机 userland 报废！" >&2
	grep -nE '^\./lib' "$OUT/.payload.list" | head -5 >&2
	rm -f "$OUT/.payload.list"
	exit 1
fi

echo
echo "================= payload 内容 ================="
grep -vE '/$' "$OUT/.payload.list" | sort | sed 's|^\./||'
rm -f "$OUT/.payload.list"
echo
echo "固件/配置落点自检："
for f in usr/lib/firmware/qcom/sm8150/wlanmdsp.mbn \
         usr/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin \
         usr/lib/firmware/ath10k/WCN3990/hw1.0/firmware-5.bin \
         etc/NetworkManager/system-connections/mi9-wifi.nmconnection \
         etc/systemd/network/25-wlan0.network.unused \
         etc/systemd/system.conf.d/10-timeouts.conf \
         etc/systemd/system/pd-mapper.service.d/10-wait-modem.conf \
         etc/systemd/system/rmtfs.service.d/10-wait-modem.conf \
         etc/modprobe.d/blacklist-audio.conf \
         usr/sbin/usb-mode.sh usr/bin/tqftpserv etc/wifi-cfg.ver \
         etc/systemd/logind.conf.d/50-server.conf \
         etc/systemd/system/zram-swap.service \
         etc/systemd/system.conf.d/20-watchdog.conf \
         etc/sysctl.d/90-zram.conf etc/sysctl.d/99-sysrq.conf \
         usr/sbin/rtc-save.sh \
         usr/sbin/mi9-status.sh usr/sbin/mi9-doctor.sh usr/sbin/mi9-dashboard.sh \
         usr/local/sbin/mi9-screen.sh usr/local/sbin/mi9-pwrkey.py \
         etc/systemd/system/mi9-screen-off.service \
         etc/systemd/system/mi9-screen-off.timer \
         etc/systemd/system/mi9-pwrkey.service \
         etc/systemd/system/mi9-dashboard.service \
         etc/systemd/system/mi9-doctor.service \
         etc/systemd/system/mi9-doctor.timer \
         etc/systemd/journald.conf.d/10-limits.conf \
         etc/systemd/timesyncd.conf.d/10-cn.conf \
         etc/ssh/sshd_config.d/98-keepalive.conf \
         etc/systemd/system/rtc-save.service \
         etc/systemd/system/rtc-save.timer \
         usr/lib/firmware/stm_fts_production_limits.csv \
         usr/local/bin/busybox \
         root/phoneui/phoneui.py root/phoneui/fblib.py root/phoneui/uitap.py \
         etc/systemd/system/phoneui.service; do
	if [ -e "$STAGE/$f" ]; then echo "  ✓ $f"; else echo "  ✗ 缺 $f"; fi
done
# ★ 本轮（usb13）新增的三条软链接必须**指向正确**（tar 会原样保存符号链接）：
#     netplan-ovs-cleanup.service -> /dev/null          （屏蔽 netplan 的 warn）
#     multi-user.target.wants/rtc-save.service          （开机 + 关机前存 RTC）
#     timers.target.wants/rtc-save.timer                （每 30 分钟存 RTC）
#   ★ 2026-10-19 起定位为服务器，phoneui.service **不再自动启用**，所以这里
#     不再校验 multi-user.target.wants/phoneui.service 这条链接。
for l in etc/systemd/system/netplan-ovs-cleanup.service \
         etc/systemd/system/klipper.service \
         etc/systemd/system/systemd-networkd.service \
         etc/systemd/system/getty@tty1.service \
         etc/systemd/system/multi-user.target.wants/rtc-save.service \
         etc/systemd/system/multi-user.target.wants/mi9-dashboard.service \
         etc/systemd/system/multi-user.target.wants/mi9-charge-guard.service \
         etc/systemd/system/multi-user.target.wants/mi9-pwrkey.service \
         etc/systemd/system/timers.target.wants/mi9-screen-off.timer \
         etc/systemd/system/swap.target.wants/zram-swap.service \
         etc/systemd/system/timers.target.wants/rtc-save.timer \
         etc/systemd/system/timers.target.wants/mi9-doctor.timer; do
	if [ -L "$STAGE/$l" ]; then
		echo "  ✓ 软链接 $l -> $(readlink "$STAGE/$l")"
	else
		echo "  ✗ $l 不是软链接（netplan 屏蔽 / 遗留服务屏蔽 / RTC / zram 会失效）"
		exit 1
	fi
done

# ★★★ 回归测试：包内 "./" 与 "./root/" 的权限（2026-10-19 事故的守门员）★★★
#   事故：这两个目录条目是从 Windows/drvfs 带出来的 0777，而 GNU tar 解压时
#   **连已存在的目录也 chmod** → 手机 /root 变 0777 → sshd StrictModes 直接拒绝
#   root 公钥登录（只剩 "Permission denied (publickey,password)" 一句话），
#   整机失联。这里直接从 tar 里读出来硬校验，错了就中断打包。
_m_slash=$(tar tzvf "$OUT/wifi-cfg.tar.gz" | awk '$NF=="./"{print $1}')
_m_root=$(tar tzvf "$OUT/wifi-cfg.tar.gz" | awk '$NF=="./root/"{print $1}')
echo "  包内 \"./\"     权限 = $_m_slash"
echo "  包内 \"./root/\" 权限 = $_m_root"
if [ "$_m_slash" != "drwxr-xr-x" ]; then
	echo "  ✗ 包内 ./ 权限必须 drwxr-xr-x（否则解压后手机 / 变 0777）" >&2
	exit 1
fi
if [ "$_m_root" != "drwx------" ]; then
	echo "  ✗ 包内 ./root/ 权限必须 drwx------（否则解压后 /root 变 0777，root SSH 全废）" >&2
	exit 1
fi
echo "  ✓ 目录权限回归测试通过（/ = 0755，/root = 0700）"
# ★ NM 档案权限必须是 600（NM 见到 group/world 可写会直接拒绝加载，见 README 坑 28）
mode=$(stat -c%a "$STAGE/etc/NetworkManager/system-connections/mi9-wifi.nmconnection" 2>/dev/null)
if [ "$mode" = "600" ]; then
	echo "  ✓ mi9-wifi.nmconnection 权限 = 600"
else
	echo "  ✗ mi9-wifi.nmconnection 权限 = $mode（必须是 600，NM 会拒绝加载）"
	exit 1
fi
if [ -e "$STAGE/etc/systemd/network/25-wlan0.network" ]; then
	echo "  ✗ payload 里出现了 25-wlan0.network（不带 .unused）——"
	echo "    它会让 systemd-networkd 和 NetworkManager 同时抢 wlan0。改名成 .unused。"
	exit 1
fi
if [ -e "$STAGE/usr/lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn" ]; then
	echo "  ✗ payload 里出现了 ath10k/.../wlanmdsp.mbn（无效位置，只会误导）—— 删掉它。"
	exit 1
fi
echo
echo "产物: $OUT/wifi-cfg.tar.gz ($(stat -c%s "$OUT/wifi-cfg.tar.gz") 字节)"
echo "MAKE_PAYLOAD_DONE"
