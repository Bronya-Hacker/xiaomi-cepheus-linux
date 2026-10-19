#!/bin/busybox sh
# ---------------------------------------------------------------------------
# initramfs /init —— 内核内嵌 initramfs 的第一个进程
#
# 顺序（★ 顺序很重要）：
#   0) 挂 configfs，先把 USB gadget（NCM + ACM 串口）建起来
#      —— 这台手机唯一的交互口就是 USB。先建 gadget，Windows 上立刻就有
#         COM 串口；就算后面 rootfs 挂载失败，也能从串口进去救。
#   1) 串口 /dev/ttyGS0 上挂一个兜底 root shell（同样用于抢救）
#   2) 等 UFS rootfs（打诊断：/proc/partitions 里有没有 sda*）
#   3) 修 /lib 符号链接（被 tar 顶掉的话）→ 按 payload 版本号决定要不要把
#      mods.tar.gz / wifi-cfg.tar.gz 解到 rootfs（版本一样就跳过，避免每开一次
#      机就把 rootfs 冲一遍）。payload 优先用**内嵌在 Image 里**的那份
#      （/payload/，由 02 脚本放进去），其次才是 recovery 的 vfat 分区兜底。
#   4) depmod、注入 SSH 公钥、放行 root 登录
#   5) switch_root
#
# 占位符由 02-build-kernel.sh 用 sed 替换：
#   @KVER@  @PAYLOADVER@  @SSHKEY@  @SSHKEY2@
# ---------------------------------------------------------------------------
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc     proc     /proc
mount -t sysfs    sysfs    /sys
mount -t devtmpfs devtmpfs /dev
mount -t configfs none     /sys/kernel/config 2>/dev/null
mkdir -p /mnt/root /mnt/fat

# say：既打 /dev/console（= 命令行里最后一个 console=，这里是 USB 串口），
#      也强制打到手机屏幕 tty0 —— 用户只读屏幕也能看到关键信息
say() { echo "$*"; echo "$*" >/dev/tty0 2>/dev/null; }

say "[initramfs] ============ 第一阶段：先把 USB gadget 建起来 ============"
if [ -x /sbin/usb-mode.sh ]; then
	/sbin/usb-mode.sh up ncm
else
	say "[initramfs] ★ 缺 /sbin/usb-mode.sh，USB 通道起不来（没法远程救）"
fi

# 兜底 shell：rootfs 万一没起来，串口上还有一个 root shell
# （switch_root 之后这个 shell 会消失，由 rootfs 的 getty 接管串口）
if [ -c /dev/ttyGS0 ] && command -v setsid >/dev/null 2>&1; then
	setsid sh -c 'exec </dev/ttyGS0 >/dev/ttyGS0 2>&1
		while true; do
			echo
			echo "=== initramfs 兜底 shell（rootfs 没起来时用；exit 会重开）==="
			sh -i
			sleep 1
		done' &
	say "[initramfs] 兜底 shell 已挂在 /dev/ttyGS0（Windows: COMx, 115200）"
fi

say "[initramfs] 内核当前看到的块设备（/proc/partitions）："
cat /proc/partitions 2>/dev/null || true
say "[initramfs] 等待 UFS rootfs ..."
# ★ 这里以前写的是 `ls /dev/sd[a-z][0-9]* /dev/mmcblk*p*`：第二个通配符没命中时
#   会被 ash 原样传给 ls → ls 必然返回非 0 → `&& break` 永远不成立 →
#   每次开机都白等满 150 秒（2026-10-18 实测就是这样）。改成 [ -e ] 判断。
i=0
while [ $i -lt 150 ]; do
	_f=""
	for _d in /dev/sda[0-9]* /dev/mmcblk[0-9]*p[0-9]*; do
		[ -e "$_d" ] && { _f=1; break; }
	done
	[ -n "$_f" ] && break
	i=$((i + 1))
	if [ $((i % 15)) -eq 0 ]; then
		say "[initramfs] 已等 ${i}s，还没有任何 sd*/mmcblk* 分区，块设备如下："
		cat /proc/partitions 2>/dev/null || true
	fi
	sleep 1
done

# ---------------------------------------------------------------------------
# repair_lib —— 救被 tar 顶掉的 /lib 符号链接
#
# Ubuntu(merged-usr) 里 /lib → usr/lib 是符号链接。如果哪次解包把带 ./lib/ 的
# 包解到了 rootfs，tar 会把这个符号链接换成真实空目录 → /lib/ld-linux-aarch64.so.1
# 消失 → bash/ls/ssh/systemd 全部起不来（"cannot execute: required file not found"）。
# 这里在 switch_root 之前把它修回来，并把误放的固件挪到 usr/lib/firmware。
# 判定条件很保守：只有「/lib 是真实目录」＋「usr/lib 里有动态链接器」
# ＋「/lib 里没有动态链接器」三条同时成立才动手。
# ---------------------------------------------------------------------------
repair_lib() {
	[ -L /mnt/root/lib ] && return 0
	[ -d /mnt/root/lib ] || return 0
	[ -e /mnt/root/usr/lib/ld-linux-aarch64.so.1 ] || return 0
	[ -e /mnt/root/lib/ld-linux-aarch64.so.1 ] && return 0
	say "[initramfs] ★ /lib 被 tar 换成了真实目录 → 恢复成 → usr/lib 的符号链接"
	mkdir -p /mnt/root/usr/lib/firmware
	for _x in /mnt/root/lib/*; do
		[ -e "$_x" ] || continue
		mv "$_x" /mnt/root/usr/lib/firmware/ 2>/dev/null || \
			cp -a "$_x" /mnt/root/usr/lib/firmware/ 2>/dev/null
	done
	rm -rf /mnt/root/lib
	ln -s usr/lib /mnt/root/lib
	[ -e /mnt/root/lib/ld-linux-aarch64.so.1 ] && say "[initramfs] ✓ /lib 已修好"
}

for dev in $(ls /dev/sd[a-z]* /dev/mmcblk*p* 2>/dev/null); do
	case "$dev" in
		/dev/sda|/dev/sdb|/dev/sdc) continue ;;
	esac
	# -o noatime：服务器不会有依赖"访问时间"的东西，少一次元数据写 = UFS 少磨损、快一点。
	# （本机 /etc/fstab 里没有 / 的条目，所以 systemd-remount-fs 不会把它改回来 —— 2026-10-19 实测确认。）
	mount -t ext4 -o noatime "$dev" /mnt/root 2>/dev/null || continue
	if [ -f /mnt/root/etc/os-release ]; then
		say "[initramfs] rootfs = $dev"
		repair_lib

		# --- payload（内核模块 + wifi 配置/固件）：★ 按版本号决定解不解 ---
		pv_now="$(head -1 /mnt/root/etc/wifi-cfg.ver 2>/dev/null)"
		if [ "$pv_now" = "@PAYLOADVER@" ]; then
			say "[initramfs] payload 版本一致（@PAYLOADVER@）→ 跳过解压，保留 rootfs 上的手工修改"
		else
			say "[initramfs] payload 版本不同（rootfs='$pv_now' 本包='@PAYLOADVER@'）→ 解压"

			# 来源 1：内嵌在 Image 里（随内核走，最可靠；02 脚本把两个包放进 /payload/）
			# 来源 2：recovery 的 vfat 分区（兜底。注意 UFS 逻辑块是 4096B，而
			#         mtools 打出来的是 512B 扇区 FAT32 —— 内核 vfat 会直接拒挂：
			#         "logical sector size too small for device"，所以基本指望不上）
			PDIR=""
			if [ -f /payload/mods.tar.gz ] || [ -f /payload/wifi-cfg.tar.gz ]; then
				PDIR=/payload
				say "[initramfs] payload 来自内嵌 /payload/（随 Image）"
			else
				for f in $(ls /dev/sd[a-z]* /dev/mmcblk*p* 2>/dev/null); do
					mount -t vfat "$f" /mnt/fat 2>/dev/null || continue
					if [ -f /mnt/fat/mods.tar.gz ] || [ -f /mnt/fat/wifi-cfg.tar.gz ]; then
						PDIR=/mnt/fat
						say "[initramfs] payload 来自 $f"
						break
					fi
					umount /mnt/fat 2>/dev/null
				done
			fi

			if [ -n "$PDIR" ]; then
				_pok=1
				mkdir -p /mnt/root/usr/lib/modules /mnt/root/lib
				if [ -f "$PDIR/mods.tar.gz" ]; then
					tar xzf "$PDIR/mods.tar.gz" -C /mnt/root/usr/lib/modules/ 2>/dev/null || _pok=0
				fi
				if [ -f "$PDIR/wifi-cfg.tar.gz" ]; then
					# ★ payload 会覆盖 /etc 下的同名文件，而有些文件属于"本机身份"
					#   （WiFi 档案、SSH host key、machine-id…）：被 payload 里的
					#   占位符盖掉就等于丢配置 —— 2026-10-19 r3 升级后设备掉 WiFi
					#   就是这么来的。清单见 /payload/protect.list
					#   （源自 scripts/payload-protect.list）：解压前抄出来、解压后放回。
					_prot="$PDIR/protect.list"
					_kp=/tmp/payload-keep
					_kn=0
					rm -rf "$_kp"
					mkdir -p "$_kp"
					if [ -f "$_prot" ]; then
						while IFS= read -r _pat; do
							case "$_pat" in ''|'#'*) continue ;; esac
							for _f in /mnt/root/$_pat; do
								[ -f "$_f" ] || continue
								_rel=${_f#/mnt/root/}
								mkdir -p "$_kp/$(dirname "$_rel")"
								cp -a "$_f" "$_kp/$_rel" 2>/dev/null && _kn=$(( _kn + 1 ))
							done
						done < "$_prot"
					fi
					tar xzf "$PDIR/wifi-cfg.tar.gz" -C /mnt/root/ 2>/dev/null || _pok=0
					if [ "$_kn" -gt 0 ]; then
						cp -a "$_kp/." /mnt/root/ 2>/dev/null && \
							say "[initramfs] ✓ 本机配置已保留（protect.list 命中 $_kn 个文件）"
					fi
					rm -rf "$_kp"
				fi
				repair_lib           # 双保险：解完再查一次
				if [ "$_pok" = 1 ]; then
					echo "@PAYLOADVER@" > /mnt/root/etc/wifi-cfg.ver
					say "[initramfs] ✓ payload 已解压（版本号已写 @PAYLOADVER@）"
				else
					say "[initramfs] ★ payload 解压有错，不写版本号（下次开机重试）"
				fi
			else
				say "[initramfs] ★ 没找到 payload（内嵌/FAT 都没有）→ 跳过解压"
			fi
			# BUILD-ID：内核 + payload 的联合指纹，写进 rootfs，方便回答
			# "这台机器到底跑的是哪次构建"（mi9-doctor 会显示它）
			echo "@BUILDID@" > /mnt/root/etc/build-id 2>/dev/null
			[ "$PDIR" = /mnt/fat ] && umount /mnt/fat 2>/dev/null

			# --- ★ 先清掉会成为"高优先级阴影"的旧模块目录 -------------
			# depmod 查找内核模块的优先级是：
			#     updates/ > extra/ > weak-updates/ > kernel/
			# rootfs 上的 Ubuntu 包 / 以前刷进去的旧模块常放在 updates|extra|
			# weak-updates 里；它们会盖掉我们刚解出来的 kernel/ 新模块。
			# 2026-10-18 就是被这个坑到：ath10k 加载了 updates/ 里的旧模块，
			# 报 "struct module 尺寸不匹配"，wlan0 根本起不来。
			# 所以这里把这三个目录挪到 /root/stale-modules-<ver>/ 下面（留证不删）。
			for mdir in /mnt/root/usr/lib/modules/*/; do
				[ -d "$mdir" ] || continue
				for shadow in updates extra weak-updates; do
					[ -d "$mdir$shadow" ] || continue
					mkdir -p "/mnt/root/root/stale-modules-$(basename "$mdir")"
					mv "$mdir$shadow" "/mnt/root/root/stale-modules-$(basename "$mdir")/" 2>/dev/null || \
						rm -rf "$mdir$shadow"
					say "[initramfs] 移走阴影模块目录 $(basename "$mdir")/$shadow"
				done
			done

			# --- depmod：把 /lib/modules 下每个版本目录都 depmod 一遍 ---
			mount -t proc  none /mnt/root/proc 2>/dev/null
			mount -t sysfs none /mnt/root/sys  2>/dev/null
			for mdir in /mnt/root/usr/lib/modules/*/; do
				[ -d "$mdir" ] || continue
				mv="$(basename "$mdir")"
				say "[initramfs] depmod $mv"
				chroot /mnt/root /sbin/depmod -a "$mv" 2>/dev/null || \
				  chroot /mnt/root /usr/sbin/depmod -a "$mv" 2>/dev/null || \
				  busybox depmod -b /mnt/root/usr/lib/modules -a "$mv" 2>/dev/null || true
			done
			umount /mnt/root/sys  2>/dev/null
			umount /mnt/root/proc 2>/dev/null
		fi

		# --- 注入 SSH 公钥（root 的 authorized_keys）---
		if [ -n "@SSHKEY@" ]; then
			mkdir -p /mnt/root/root/.ssh
			{
				printf '%s\n' "@SSHKEY@"
				printf '%s\n' "@SSHKEY2@"
			} > /mnt/root/root/.ssh/authorized_keys
			chmod 700 /mnt/root/root/.ssh
			chmod 600 /mnt/root/root/.ssh/authorized_keys
			say "[initramfs] 已注入 root SSH 公钥"
		fi

		# --- ★★ 兜底：/root 与根目录权限必须正确（2026-10-19 事故的保险丝）★★ ---
		# 事故经过：payload 里的**目录条目**（./  ./root/  ./etc/ ...）是 Windows/drvfs
		#   带出来的 0777，而 GNU tar 解压时**会把已存在的目录也 chmod** →
		#     ① /root 变 0777 → sshd StrictModes 判定 home 目录 group/world 可写
		#        → **直接拒绝 root 公钥登录**，日志只有一句
		#        "Permission denied (publickey,password)"，非常难定位；
		#     ② / /etc /usr /usr/sbin ... 全变 0777。
		#   结果：手机彻底失联，只能串口进去用普通用户，靠"往 /etc 里塞个 uid=0 账号
		#   再 su 提权"才救回来（详见 docs/root-cause.md §10.16）。
		# 双保险：打包侧 05-make-payload.sh 已把目录权限归一（含 STAGE 本身），
		#   这里在 switch_root 之前再掰一次 —— root SSH 是这台机器唯一的维护入口，
		#   绝不能因为一次解压就丢掉。
		if [ -d /mnt/root/root ]; then
			chmod 700 /mnt/root/root 2>/dev/null || true
			chmod 755 /mnt/root/ /mnt/root/etc /mnt/root/usr \
			          /mnt/root/usr/bin /mnt/root/usr/sbin /mnt/root/usr/lib 2>/dev/null || true
			say "[initramfs] 已强制 /root=0700（root SSH 通道保险丝）"
		fi

		# --- 放行 root 登录（手机没键盘，SSH 是主要入口）---
		if [ -d /mnt/root/etc/ssh ]; then
			mkdir -p /mnt/root/etc/ssh/sshd_config.d
			{
				echo "# 由 initramfs 生成：手机没键盘，放开 root/密码登录"
				echo "PermitRootLogin yes"
				echo "PasswordAuthentication yes"
			} > /mnt/root/etc/ssh/sshd_config.d/99-cepheus.conf
			say "[initramfs] 已写 /etc/ssh/sshd_config.d/99-cepheus.conf"
		fi

		say "[initramfs] switch_root -> $dev"
		exec switch_root /mnt/root /sbin/init
	fi
	umount /mnt/root
done

say "[initramfs] ROOTFS_NOT_FOUND"
say "[initramfs] ★ 自查：上面 /proc/partitions 若连 sda* 都没有，说明内核根本没看到 UFS——"
say "            多半是 DTB 里 ufshc@1d84000 的 status 不是 okay"
say "            （见 dts/cepheus-wifi.dtsi 的『第 0 部分 UFS』/ README 第 4.7 节）"
cat /proc/partitions 2>/dev/null || true
say "[initramfs] 停在兜底 shell（串口 /dev/ttyGS0 可直接操作）"
while true; do sleep 60; done
