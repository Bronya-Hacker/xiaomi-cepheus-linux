#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 02-build-kernel.sh —— 配置 + 编 Image(内嵌initramfs) + dtb + modules
#
#   bash 02-build-kernel.sh <内核树目录>
#
# 产出（都在 wifi-bringup/out/ 下）：
#   Image                            ← 内核（已内嵌 initramfs）
#   sm8150-xiaomi-cepheus.dtb        ← ★给 edk2 FdtBlob 用
#   mods.tar.gz                      ← 模块包（顶层目录 6.17.0-sm8150）
#   initramfs.cpio.gz                ← 单独留一份，方便查
#
# 关键点（都是踩过的坑）：
#   * 顺序必须是：先配好 .config（含 CONFIG_LOCALVERSION）→ 再取 kernelrelease
#     → 再打包 initramfs（init 脚本里要填模块目录名）。
#     反过来的话 kernelrelease 会是 6.17.0 而模块目录是 6.17.0-sm8150，对不上。
#   * 每次编 Image 前必须 rm -f usr/initramfs_data.o，否则 initramfs 不更新。
#   * 千万别写 `yes n | make olddefconfig`：yes 收不到 EOF 会吃 SIGPIPE，
#     配合 set -o pipefail 会让整个脚本以 141 退出。用 </dev/null。
# ---------------------------------------------------------------------------
set -euo pipefail

K="${1:?用法: bash 02-build-kernel.sh <内核树目录>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$HERE/out}"
JOBS="${JOBS:-$(nproc)}"
mkdir -p "$OUT"

cd "$K"
# ★ KCFLAGS 里的 -Wno-error=strict-prototypes 是必须的：
#   scripts/Makefile.extrawarn 无条件加了 -Werror=strict-prototypes，
#   而 sm8150.config 片段把厂家触摸屏驱动
#   CONFIG_TOUCHSCREEN_STM_FTS_DOWNSTREAM=y 编进来了，它里面
#   `struct spi_device *getClient()` 这种 K&R 声明在 clang 18 下直接报错，
#   整个内核编不出来（Image 都没有）。这里把它降级成警告。
M="make ARCH=arm64 CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS=-Wno-error=strict-prototypes"

# ===========================================================================
# 0) 本地内核补丁（★ 可复现：补丁文件放仓库 patches/，每次构建幂等套用）
#
#    为什么要有这一步：有些噪音/问题只改驱动代码才能根治（例如 ath10k 那条
#    "chan info: invalid frequency 0"），但**手改内核树是不可复现的** ——
#    下次 rsync/重建就丢了，而且极易踩 README 坑 32（手敲 make 漏 ARCH → 整份
#    .config 被改写成 x86）。所以补丁进仓库、由脚本幂等套用。
#
#    判据：
#      * 反向 dry-run 成功  → 树里已经打过了（幂等跳过）
#      * 正向 dry-run 成功  → 打上
#      * 两个都失败        → 树与补丁不匹配，直接停（别带着不明的树往下编）
# ===========================================================================
if [ -d "$HERE/patches" ]; then
	shopt -s nullglob
	for p in "$HERE"/patches/*.patch; do
		name="$(basename "$p")"
		if patch -p1 -R --dry-run -s -f < "$p" >/dev/null 2>&1; then
			echo "  本地补丁（已套用）: $name"
		elif patch -p1 --dry-run -s -f < "$p" >/dev/null 2>&1; then
			if patch -p1 -s -f < "$p" >/dev/null 2>&1; then
				echo "  本地补丁（新套用）: $name"
			else
				echo "  ✗ 套用失败: $name" >&2
				exit 1
			fi
		else
			echo "  ✗ 补丁既不能正向也不能反向套用（树与补丁不匹配）: $name" >&2
			echo "     补救：如果是你刚改了补丁内容，先在 $K 里用" >&2
			echo "           patch -p1 -R < '${p}'  撤销旧版，再重跑本脚本。" >&2
			exit 1
		fi
	done
else
	echo "  （没有 patches/ 目录，跳过本地补丁）"
fi

# ===========================================================================
# 0b) DTS 补丁（幂等，已打过会跳过）
#
#   第 1 部分 cepheus-wifi.dtsi  ：UFS（缺了内核看不到 /dev/sda*，卡在 initramfs）+ WiFi
#   第 2 部分 cepheus-extra.dtsi ：RTC 可写 + WiFi 收尾 + 触摸(FTS)
#
#   ★ 每次编内核都过一遍：保证"树里的 DTS"和仓库里的片段一致（可复现）。
#     以前这两步是手敲的，一旦忘了就出现"改了 dts/ 却没生效"的假象
#     （README 坑 39）。
# ===========================================================================
for s in apply-dts.sh apply-dts2.sh apply-dts3.sh apply-dts4.sh apply-dts5.sh; do
	if [ -f "$HERE/scripts/$s" ]; then
		echo "----- $s -----"
		bash "$HERE/scripts/$s" "$K"
		echo
	else
		echo "⚠️ 缺少 $HERE/scripts/$s" >&2
	fi
done

# ===========================================================================
# 1) 配置
# ===========================================================================
if [ ! -f .config ]; then
	echo "===== 生成 .config（defconfig + 这棵树自带的 sm8150.config 片段）====="
	$M defconfig
	$M sm8150.config      # 走 scripts/kconfig 的 %.config 规则做 merge
else
	echo "===== 已有 .config，跳过 defconfig ====="
fi

# ★★ 配置改动检测用：先记下改之前的 .config 指纹。
#    理由见 §1b 末尾（本树的增量重建对"配置符号变化"不可靠）。
CFG_BEFORE="$(sha256sum .config 2>/dev/null | cut -d' ' -f1)"

./scripts/config --set-str CONFIG_INITRAMFS_SOURCE "$OUT/initramfs.cpio.gz"
./scripts/config --set-str CONFIG_LOCALVERSION "-sm8150"

# WiFi 全链路要的驱动：QRTR 传输层 + 远程处理器 + ath10k_snoc + 无线核心
# 说明：qcom_q6v5_pas 负责带起 ADSP，ath10k_snoc 负责 WCN3990。
#
# ★★ 这里有个大坑（第一次就是这么翻车的）：
#    CONFIG_REMOTEPROC / CONFIG_QCOM_SCM / CONFIG_RPMSG 是 **bool**，
#    只能 y 或 n。用 --module 去写 "=m" 会被 kconfig 判为非法值，
#    olddefconfig 直接把它回落成 n；而 drivers/remoteproc/Kconfig 整个文件
#    被 `if REMOTEPROC` 包着 → 一旦 REMOTEPROC=n，
#    QCOM_Q6V5_PAS 连同 QCOM_Q6V5_COMMON/QCOM_RPROC_COMMON 全部消失，
#    结果就是模块包里**没有 qcom_q6v5_pas.ko**，ADSP 永远起不来。
for sym in \
	CONFIG_QRTR CONFIG_QRTR_SMD CONFIG_RPMSG_QCOM_GLINK_SMEM \
	CONFIG_QCOM_Q6V5_PAS CONFIG_QCOM_Q6V5_COMMON \
	CONFIG_QCOM_RPROC_COMMON \
	CONFIG_QCOM_SMEM RPMSG_CHAR RPMSG_CTRL \
	CONFIG_CFG80211 CONFIG_MAC80211 CONFIG_ATH10K CONFIG_ATH10K_SNOC \
	; do
	./scripts/config --module "${sym#CONFIG_}" 2>/dev/null || true
done
# bool 的那些必须用 --enable
for sym in CONFIG_REMOTEPROC CONFIG_QCOM_SCM CONFIG_RPMSG CONFIG_QCOM_QMI_HELPERS; do
	./scripts/config --enable "${sym#CONFIG_}" 2>/dev/null || true
done
./scripts/config --enable CONFIG_DEVTMPFS
./scripts/config --enable CONFIG_DEVTMPFS_MOUNT
# ath10k 要能从 sysfs/debugfs 看状态，排障很有用
./scripts/config --enable CONFIG_ATH10K_DEBUGFS 2>/dev/null || true

# ===========================================================================
# 1b) ★ 日志噪音清理（2026-10-18，第①项"内核报错清零"，usb12）
#     每条都有 usb11 冷启动 dmesg 的实测依据；不在配置里做掉，就每次开机都刷。
# ===========================================================================
# * CONFIG_SECURITY_NETWORK：net/core/sock.c 里 SO_PASSSEC 的实现是
#     if (IS_ENABLED(CONFIG_SECURITY_NETWORK) && sk_may_scm_recv(sk)) ... else ret = -EOPNOTSUPP;
#   我们 SECURITY=y 但没开它 → journald 设 SO_PASSSEC 失败，每次刷 3 条
#     "systemd-journald.socket: SO_PASSSEC failed: Operation not supported"
./scripts/config --enable  SECURITY_NETWORK 2>/dev/null || true
# * 这台机器的 EFI 运行时时钟读不了（每次开机的 err 级）：
#     "rtc-efi rtc-efi.0: hctosys: unable to read the hardware clock"
./scripts/config --disable RTC_DRV_EFI 2>/dev/null || true
# * 关掉 EFI RTC 之后，pm8150 的 rtc@6000（DTB 里 compatible="qcom,pm8941-rtc"，
#   而 rtc-pm8xxx 支持它）就变成 rtc0 → hctosys 读到真时间 →
#   ★ 系统时间可以跨重启保留（之前每次开机时间都错，只能等 NTP 纠正）。
#   ⚠ rtc-pm8xxx 的 Kconfig 是 `depends on MFD_SPMI_PMIC`：不先把这个打开，
#      RTC_DRV_PM8XXX 在 .config 里**可见性都没有**，`scripts/config --enable`
#      写不进去（2026-10-18 实测）。
./scripts/config --enable  MFD_SPMI_PMIC 2>/dev/null || true
./scripts/config --enable  RTC_DRV_PM8XXX 2>/dev/null || true
# * 我们已经有 ramoops，EFI 那份每次刷：
#     "pstore: backend 'ramoops' already in use: ignoring 'efi_pstore'"
./scripts/config --disable EFI_VARS_PSTORE 2>/dev/null || true
# * ★ 触摸屏（STM FTS / FingerTipS，第②项）：
#   fts_touch/Kconfig 里 I2C / SPI 是**互斥的 choice**，而这棵树里继承下来的
#   .config 选的是 SPI（CONFIG_TOUCHSCREEN_STM_FTS_DOWNSTREAM_SPI=y）。
#   手机上的触摸 IC 挂在 I2C（SE17 = i2c@c80000, fts@49）上，
#   如果编成 SPI 版，probe 里会走 spi_setup()，i2c 总线上永远 match 不到设备
#   → /proc/bus/input/devices 里没有 fts，摸屏幕没反应。
./scripts/config --enable  TOUCHSCREEN_STM_FTS_DOWNSTREAM     2>/dev/null || true
./scripts/config --enable  TOUCHSCREEN_STM_FTS_DOWNSTREAM_I2C 2>/dev/null || true
./scripts/config --disable TOUCHSCREEN_STM_FTS_DOWNSTREAM_SPI 2>/dev/null || true
# * 触摸屏会 select TOUCHSCREEN_HEATMAP（bool），显式带上，免得 olddefconfig
#   的交互提示把整个构建卡住。
./scripts/config --enable  TOUCHSCREEN_HEATMAP 2>/dev/null || true
# * 关于 "ITS: No ITS available, not enabling LPIs"（irq-gic-v3-its.c:5835）：
#   **关不掉**，别浪费一次构建去试。Symbol ARM_GIC_V3_ITS 无 prompt、
#   `default ARM_GIC_V3`，而且 arch/arm64/Kconfig:128 是
#   `select ARM_GIC_V3_ITS if PCI` —— 只要开了 PCI 它就必然 =y，
#   `scripts/config --disable` 会被 olddefconfig 直接还原。
#   真正的解法是给 DTB 补 ITS 节点（硬件上有 GIC ITS@17a20000），
#   归到"改 DTB"那一轮做，见 docs/root-cause.md。

$M olddefconfig </dev/null >/dev/null

# ===========================================================================
# 1c) ★★ 硬门禁：配置变了就必须 make clean
# ---------------------------------------------------------------------------
# 2026-10-18 实测踩到：给 .config 加了 CONFIG_SECURITY_NETWORK=y（见 §1b）后直接
# 增量构建，结果 **built-in 目标根本没重编**：
#     security/security.o      仍是 03:56 的旧文件
#     net/core/sock.o          仍是 03:55 的旧文件
# 而 IS_ENABLED(CONFIG_SECURITY_NETWORK) / security_sk_clone() 这些
# 都是**编译期**决定的：旧 .o 里既没有新调用、security.o 里也没有新导出，
# 于是 modpost 直接炸：
#     ERROR: modpost: "security_sk_clone" [net/bluetooth/bluetooth.ko] undefined!
#     ERROR: modpost: "security_sk_classify_flow" [net/ipv6/ipv6.ko] undefined!
#     make[2]: *** [scripts/Makefile.modpost:147: Module.symvers] Error 1
# （手动 `make security/security.o` 一叫就会重编 —— 说明不是依赖信息缺失，
#   而是这条构建路径上 built-in 的重编时机不可靠。既然不可靠，就别赌。）
# 结论：改配置 = 必须干净重编。make clean 保留 .config，只丢 .o/.cmd，
#       对已经编过的树就是多花一次全量时间，换掉一个随机翻车点，值得。
# ===========================================================================
CFG_AFTER="$(sha256sum .config 2>/dev/null | cut -d' ' -f1)"
if [ "$CFG_BEFORE" != "$CFG_AFTER" ]; then
	echo "★ .config 发生变化（${CFG_BEFORE:0:12} -> ${CFG_AFTER:0:12}）→ 强制 make clean 后全量重编"
	$M clean >/dev/null 2>&1 || true
	echo "  clean 完成"
else
	echo "===== .config 未变，走增量构建 ====="
fi

echo "===== 确认关键配置 ====="
grep -E '^CONFIG_(INITRAMFS_SOURCE|LOCALVERSION|QRTR|QRTR_SMD|QCOM_GLINK_SMEM|QCOM_Q6V5_PAS|QCOM_Q6V5_COMMON|QCOM_QMI_HELPERS|REMOTEPROC|QCOM_RPROC_COMMON|QCOM_SCM|QCOM_SMEM|RPMSG|CFG80211|MAC80211|ATH10K|ATH10K_SNOC|ATH10K_DEBUGFS|DEVTMPFS)=' .config || true

# ★ 硬性门槛：这几项缺任何一个，ADSP 就永远起不来，整个 WiFi 白做。
#   （第一次就是因为 REMOTEPROC 被冲掉，编完才发现模块包里没有 qcom_q6v5_pas.ko）
missing=0
for chk in 'CONFIG_REMOTEPROC=y' 'CONFIG_QCOM_Q6V5_PAS=m' 'CONFIG_QCOM_Q6V5_COMMON=m' \
           'CONFIG_QRTR=m' 'CONFIG_QRTR_SMD=m' 'CONFIG_RPMSG_QCOM_GLINK_SMEM=m' \
           'CONFIG_ATH10K_SNOC=m' 'CONFIG_CFG80211=m' 'CONFIG_MAC80211=m' \
           'CONFIG_TOUCHSCREEN_STM_FTS_DOWNSTREAM_I2C=y'; do
	if ! grep -q "^${chk}$" .config; then
		echo "  ✗ 配置缺失: $chk"
		missing=1
	fi
done

# ★ 触摸＝I2C 变体，不能是 SPI（Kconfig 里是互斥 choice）
if grep -q '^CONFIG_TOUCHSCREEN_STM_FTS_DOWNSTREAM_SPI=y$' .config; then
	echo "  ✗ 触摸驱动被选成了 SPI 变体（CONFIG_TOUCHSCREEN_STM_FTS_DOWNSTREAM_SPI=y）"
	echo "     手机上是 I2C（i2c17 / fts@49）：必须 I2C 变体，见本脚本 §1b"
	missing=1
fi

if [ "$missing" != 0 ]; then
	echo
	echo "✗ Kconfig 关键项没配上，先别编。常见原因："
	echo "  * CONFIG_REMOTEPROC 被写成 =m（它是 bool）→ 用 scripts/config --enable REMOTEPROC"
	echo "  * 依赖没满足（exports/ARCH_QCOM/QCOM_SMEM/RPMSG_QCOM_GLINK_SMEM）"
	echo "  * .config 是旧的：删掉 .config 重跑本脚本（会重新 defconfig + sm8150.config）"
	exit 1
fi
echo "✓ 关键配置全部就位"

# ★★ 第二道门禁：§1b 那几项"日志噪音清理"配置必须真的写进 .config。
#    为什么必须验：`scripts/config` 对**在 .config 里根本不存在（不可见）的符号**
#    是**静默失效**的（不报错、不写、退出码 0，被 `|| true` 吞掉）。
#    2026-10-18 实测后果：手工敲了一条不带 ARCH=arm64 的 make 之后，
#    syncconfig 把 .config 重写成 x86 版，ARCH_QCOM 整支符号从文件里消失，
#    于是 --module/--enable 全部没生效，最后是上面那道门禁才发现
#    "CONFIG_QCOM_Q6V5_PAS 缺失"。新加的项同理，必须自己验。
missing2=0
for chk in 'CONFIG_SECURITY_NETWORK=y' 'CONFIG_MFD_SPMI_PMIC=y' 'CONFIG_RTC_DRV_PM8XXX=y'; do
	if ! grep -q "^${chk}$" .config; then
		echo "  ✗ 日志噪音清理项缺失: $chk"
		missing2=1
	fi
done
for off in CONFIG_RTC_DRV_EFI CONFIG_EFI_VARS_PSTORE; do
	if ! grep -q "^# ${off} is not set$" .config; then
		echo "  ✗ 应保持关闭却开着: $off"
		missing2=1
	fi
done
if [ "$missing2" != 0 ]; then
	echo
	echo "✗ 日志噪音清理项没配上，先别编。最常见原因："
	echo "  * .config 是别的 ARCH（如 x86）留下的 → 那些符号在文件里不可见，"
	echo "    scripts/config 静默失效。删掉 .config 重跑本脚本即可。"
	exit 1
fi
echo "✓ 日志噪音清理项全部就位"

# ===========================================================================
# 2) 拿 kernelrelease
#    ⚠️ 坑：`make -s kernelrelease` 只有在 include/config/auto.conf 已生成时
#    才会带上 CONFIG_LOCALVERSION。刚 defconfig 完时它常常还打 "6.17.0"，
#    而模块实际装到 "6.17.0-sm8150"。所以这里只当预估，真正取值在编完之后
#    （见第 5 步，从 include/config/kernel.release 读）。
#    initramfs 的 init 脚本已经改成遍历 /lib/modules/*/ 做 depmod，
#    所以不依赖这个值。
# ===========================================================================
KVER="$($M -s kernelrelease)"
echo
echo "内核树        : $K"
echo "kernelrelease : $KVER    (预估；编完后以 include/config/kernel.release 为准)"
echo "并行          : $JOBS"

# ===========================================================================
# 3) 编模块 + 打 mods.tar.gz
#
#    ★ 必须排在「装 initramfs」之前：payload（mods.tar.gz + wifi-cfg.tar.gz）
#      现在要**内嵌进 Image**（见第 4 步），所以得先把包做出来。
# ===========================================================================
echo
echo "===== 编模块 + 打包 mods.tar.gz ====="
# ★★ 坑（2026-10-18 实测）：干净树上**不能**只写 `make modules`。
#    顶层 Makefile 里有这么一段：
#        KBUILD_BUILTIN := 1
#        ifeq ($(MAKECMDGOALS),modules)
#          KBUILD_BUILTIN := $(if $(CONFIG_MODVERSIONS),1)
#        endif
#    我们没开 CONFIG_MODVERSIONS → 目标**恰好只有** modules 时 KBUILD_BUILTIN
#    被清空 → built-in 目标一个都不编、vmlinux.o 不存在，modpost 立刻炸：
#        WARNING: vmlinux.o is missing.
#        ERROR: modpost: "cpu_have_feature" [arch/arm64/crypto/sha3-ce.ko] undefined!
#        make[2]: *** [scripts/Makefile.modpost:147: modules-only.symvers] Error 1
#    以前一直没暴露，是因为树里始终留着上一次构建的 vmlinux.o（增量构建不会删它）。
#    解法：把 vmlinux 一起列成目标（两个目标时 KBUILD_BUILTIN 保持 1），
#    它顺带把所有 built-in 都编了。这一遍嵌进 vmlinux 的 initramfs 是旧的/占位的
#    —— 无所谓：第 4 步会重做 cpio，第 5 步会 rm usr/initramfs_data.o 重新链。
if [ ! -s "$OUT/initramfs.cpio.gz" ]; then
	echo "  （没有现成的 initramfs.cpio.gz：先造一个占位 cpio，只为让 vmlinux 能链上）"
	PH="$OUT/.initramfs-ph"; rm -rf "$PH"; mkdir -p "$PH"
	echo "placeholder: the real initramfs is generated later in this script" > "$PH/README"
	( cd "$PH" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$OUT/initramfs.cpio.gz"
	rm -rf "$PH"
	echo "  占位 initramfs -> $(stat -c%s "$OUT/initramfs.cpio.gz") 字节"
fi
$M -j"$JOBS" vmlinux modules

# ★ 编完之后 kbuild 已经写出 include/config/kernel.release，这里面才是
#   带 CONFIG_LOCALVERSION 的真名（6.17.0-sm8150）
KVER="$(cat include/config/kernel.release 2>/dev/null || echo "$KVER")"
echo "实际模块目录名: $KVER"

INST="$OUT/modinst"
rm -rf "$INST"
$M INSTALL_MOD_PATH="$INST" INSTALL_MOD_STRIP=1 modules_install >/dev/null
if [ ! -d "$INST/lib/modules/$KVER" ]; then
	echo "⚠️ $INST/lib/modules/$KVER 不存在，实际是："
	ls -l "$INST/lib/modules/" 2>&1
	KVER="$(ls "$INST/lib/modules/" 2>/dev/null | head -1)"
	echo "改用: $KVER"
fi
# depmod 生成 modules.dep，供设备上 switch_root 前/后自动加载
depmod -b "$INST" "$KVER" 2>/dev/null || true

( cd "$INST/lib/modules" && tar czf "$OUT/mods.tar.gz" "$KVER" )
rm -rf "$INST"

# ===========================================================================
# 4) initramfs：busybox + init 脚本 + 内嵌 payload
#    作用：等 UFS rootfs -> 挂载 -> （必要时修 /lib）-> 解 mods.tar.gz /
#          wifi-cfg.tar.gz -> depmod -> switch_root
#    ★ payload 放 /payload/ 里随 Image 走 —— 不再依赖 recovery 的 FAT
#      （UFS 逻辑块 4096B，mtools 打的 512B 扇区 FAT32 内核 vfat 会拒挂：
#       "logical sector size too small for device"）。
# ===========================================================================
BB="${BUSYBOX:-$OUT/busybox}"
[ -s "$BB" ] || { echo "缺少 aarch64 静态 busybox：$BB（先跑 01-setup-buildhost.sh）" >&2; exit 1; }

IR="$OUT/initramfs-root"
rm -rf "$IR"
mkdir -p "$IR"/{bin,sbin,etc,proc,sys,dev,mnt/root,mnt/fat}
# ★ /dev/console 必须在 cpio 里就存在：内核真正跑 /init **之前**会先
#   open("/dev/console")（init/main.c），失败就打印一条 err 级的
#   "Warning: unable to open an initial console."（usb11 冷启动实测每次都有）。
#   原来我们只放了个空的 dev/ 目录 → 必然失败。
#   （init 脚本随后会 mount devtmpfs 盖住 /dev，这两个静态节点只服务内核那一次 open。）
if command -v mknod >/dev/null 2>&1; then
	mknod -m 622 "$IR/dev/console" c 5 1 2>/dev/null || true
	mknod -m 666 "$IR/dev/null"    c 1 3 2>/dev/null || true
fi
cp "$BB" "$IR/bin/busybox"
chmod +x "$IR/bin/busybox"

# init 脚本独立成文件（更好读好改）：scripts/initramfs-init.sh
install -m 0755 "$HERE/scripts/initramfs-init.sh" "$IR/init"

# ★ USB gadget 脚本：与 rootfs 里 /usr/sbin/usb-mode.sh 用同一份文件
install -m 0755 "$HERE/payload/usr/sbin/usb-mode.sh" "$IR/sbin/usb-mode.sh"

# ★★ payload 内嵌：把两个包塞进 initramfs 的 /payload/。
#    init 脚本优先从这里解包 —— 完全不碰 recovery 那个 FAT。
mkdir -p "$IR/payload"
if [ -s "$OUT/mods.tar.gz" ]; then
	cp "$OUT/mods.tar.gz" "$IR/payload/"
	echo "内嵌 mods.tar.gz ($(stat -c%s "$OUT/mods.tar.gz") 字节)"
fi
if [ -s "$OUT/wifi-cfg.tar.gz" ]; then
	cp "$OUT/wifi-cfg.tar.gz" "$IR/payload/"
	echo "内嵌 wifi-cfg.tar.gz ($(stat -c%s "$OUT/wifi-cfg.tar.gz") 字节)"
else
	echo "⚠️ 没有 $OUT/wifi-cfg.tar.gz —— 固件/wifi 配置不会随 Image 走，先跑 05-make-payload.sh"
fi

# ★ 覆盖保护清单（payload 解压前抄、解压后放回，见 initramfs-init.sh）
if [ -f "$HERE/scripts/payload-protect.list" ]; then
	cp "$HERE/scripts/payload-protect.list" "$IR/payload/protect.list"
	echo "内嵌 protect.list ($(grep -cv '^[[:space:]]*\(#\|$\)' "$IR/payload/protect.list") 条规则)"
fi

# payload 版本号：payload/etc/wifi-cfg.ver 里那行。initramfs 拿它与 rootfs 上
# 的 /etc/wifi-cfg.ver 比较，一样就跳过解压（避免每次开机都把 rootfs 冲一遍）。
PAYLOADVER="$(head -1 "$HERE/payload/etc/wifi-cfg.ver" 2>/dev/null)"
PAYLOADVER="${PAYLOADVER:-unknown}"
echo "payload 版本号 : $PAYLOADVER"

# BUILD-ID：把本次构建的"输入"揉成一个短哈希 —— 内核 Image 是由 initramfs
# 决定的，而 initramfs 由 payload + init 脚本决定，所以这四样就够定位。
# 它会被写进 rootfs 的 /etc/build-id（见 initramfs-init.sh），mi9-doctor 显示。
BUILDID=$( { sha256sum "$OUT/wifi-cfg.tar.gz" "$OUT/mods.tar.gz" \
                      "$HERE/scripts/initramfs-init.sh" \
                      "$HERE/payload/etc/wifi-cfg.ver" 2>/dev/null || true; } \
           | sha256sum | cut -c1-12 )
BUILDID="${BUILDID:-unknown}"
echo "build id       : $BUILDID"

# SSH 公钥：手机没键盘，SSH/串口是唯一入口。
# ★ 默认**不注入**任何公钥 —— 公开镜像不能把构建者自己的 key 写进每个用户的
#   root/.ssh/authorized_keys（等于给所有刷机的人装了一个后门）。
#   自己用的时候显式传：
#     SSHKEY="ssh-ed25519 AAAA... me" SSHKEY2="" wsl bash scripts/07-rebuild-all-wsl.sh
SSHKEY="${SSHKEY:-}"
SSHKEY2="${SSHKEY2:-}"
sed -i "s|@KVER@|$KVER|g; s|@PAYLOADVER@|$PAYLOADVER|g; s|@BUILDID@|$BUILDID|g; s|@SSHKEY@|$SSHKEY|g; s|@SSHKEY2@|$SSHKEY2|g" "$IR/init"
chmod +x "$IR/init" "$IR/sbin/usb-mode.sh"
# ● USB 通道要塞要用的 applet 全链上：ip/ifconfig/route（配 usb0）、setsid（挂后台
#   shell）、printf/sed/awk/cut/head（usb-mode.sh 里用得到）
for a in sh mount umount switch_root sleep cat echo grep ls mkdir ln rm tar chroot cp \
	 date basename dirname head tail printf sed awk cut tr id uname sync \
	 ip ifconfig route setsid; do
	ln -sf busybox "$IR/bin/$a"
done

( cd "$IR" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$OUT/initramfs.cpio.gz" )
echo "initramfs -> $OUT/initramfs.cpio.gz ($(stat -c%s "$OUT/initramfs.cpio.gz") 字节)"

# 自检：initramfs 里确实带上了 init / payload / usb-mode.sh
# 注意：cpio -t 列出的路径**不带** ./ 前缀（例如 init、payload/mods.tar.gz）
gzip -dc "$OUT/initramfs.cpio.gz" | cpio -t > "$OUT/.ir.list" 2>/dev/null || true
for f in init sbin/usb-mode.sh payload/mods.tar.gz payload/wifi-cfg.tar.gz; do
	if grep -qx -- "$f" "$OUT/.ir.list"; then echo "  ✓ initramfs 含 $f"; else echo "  ✗ initramfs 缺 $f"; fi
done
rm -f "$OUT/.ir.list"

# ===========================================================================
# 5) 编 Image（把上面那份 initramfs 链进去）+ dtbs
#    ★ 模块第 3 步已经编完了，这里只补 Image/dtb，很快。
# ===========================================================================
echo
echo "===== 编 Image / dtbs ====="
rm -f usr/initramfs_data.o                # ★★ 关键，不删 initramfs 不生效
$M -j"$JOBS" Image dtbs

# ===========================================================================
# 6) 收集产物 + 自检
# ===========================================================================
cp arch/arm64/boot/Image                                   "$OUT/Image"
cp arch/arm64/boot/dts/qcom/sm8150-xiaomi-cepheus.dtb      "$OUT/sm8150-xiaomi-cepheus.dtb"

# ★ 再核一遍：这 4 个 .ko 必须真的在包里（少一个 WiFi 就没戏）
#   注意：这里**不能**写 `tar tzf ... | grep -q`：grep -q 命中就早退，
#   tar 收到 SIGPIPE，配合 set -o pipefail 会判成失败（就是坑 8.4 的同类）。
#   先把清单落成文件，再对文件 grep。
echo
echo "模块包关键 .ko 自检："
tar tzf "$OUT/mods.tar.gz" > "$OUT/.mods.list"
missing_ko=0
for ko in qcom_q6v5_pas.ko qcom_q6v5.ko qcom_common.ko qrtr.ko qrtr-smd.ko qcom_glink_smem.ko ath10k_snoc.ko ath10k_core.ko; do
	if grep -q "/$ko\$" "$OUT/.mods.list"; then
		echo "  ✓ $ko"
	else
		echo "  ✗ $ko 不在模块包里！← 配置或依赖没满足，回上面看 Kconfig 检查"
		missing_ko=1
	fi
done
rm -f "$OUT/.mods.list"
[ "$missing_ko" = 0 ] || { echo "模块包不完整，别刷机" >&2; exit 1; }
echo "✓ 模块包完整"

echo
echo "================= 产物 ================="
ls -l "$OUT/Image" "$OUT/sm8150-xiaomi-cepheus.dtb" "$OUT/mods.tar.gz" "$OUT/initramfs.cpio.gz"
echo
# ★ 同 8.4 的教训：`strings … | grep -q` 也会踩 SIGPIPE —— grep -q 一命中就早退，
#   strings 收到 EPIPE，配合 set -o pipefail 会被判成"失败"。
#   2026-10-18 就因此随机误报"DTB 不合格、别刷机"（同一份 DTB 上一秒还通过）。
#   所以先把 strings 落成文件，再对文件 grep。
strings "$OUT/sm8150-xiaomi-cepheus.dtb" 2>/dev/null > "$OUT/.dtb.strings"
echo "dtb 自检（应该能看到 firmware-name / vdd- 之类的字符串）："
grep -E 'qcom/sm8150|vdd-|calibration' "$OUT/.dtb.strings" || true
echo
dtbfail=0
if grep -q 'qcom/sm8150/adsp.mdt' "$OUT/.dtb.strings"; then
	echo "✓ DTB 里已含 firmware-name = qcom/sm8150/adsp.mdt"
else
	echo "✗ 没看到 qcom/sm8150/adsp.mdt —— 补丁没打上！先跑 apply-dts.sh"
	dtbfail=1
fi
rm -f "$OUT/.dtb.strings"

# ★ UFS 段自检：这是 2026-10-18 那次“卡死在 initramfs”的根因。
#   只用 strings 看不出 enabled/disabled，所以这里真的解一遍 DTB。
if command -v dtc >/dev/null 2>&1; then
	dtc -I dtb -O dts -o /tmp/.02-dtb.dts "$OUT/sm8150-xiaomi-cepheus.dtb" 2>/dev/null || true
	for pair in 'ufshc@1d84000:UFS 控制器' 'phy@1d87000:UFS PHY' \
	            'geniqup@cc0000:QUP wrapper(SE17)' 'i2c@c80000:触摸 I2C(i2c17)' \
	            'serial@c8c000:蓝牙串口(uart13)'; do
		node="${pair%%:*}"; desc="${pair##*:}"
		if awk -v n="$node" '$0 ~ n {f=1} f && /status = "okay"/ {ok=1} f && /^[[:space:]]*};/ {exit} END{exit !ok}' /tmp/.02-dtb.dts; then
			echo "✓ DTB 里 $desc ($node) status = okay"
		else
			echo "✗ DTB 里 $desc ($node) 不是 okay —— 整条链就断了（UFS 断=卡 initramfs）"
			echo "   → 检查 dts/cepheus-wifi.dtsi（UFS/WiFi）与 dts/cepheus-extra.dtsi（第 2 部分）是否都打上"
			dtbfail=1
		fi
	done

	# ★★ 第 2 部分（cepheus-extra.dtsi）落地自检：防止"改了 dts 但没编进去"。
	#    dtc 输出里数值是 16 进制，所以只查属性名/子节点名，不查数值。
	for k in 'touchscreen@49' 'compatible = "st,fts"' 'st,irq-gpio' \
	         'st,reset-gpio' 'st,max-coords' 'st,disable-auto-fw-update' \
	         'st,regulator_dvdd' 'nvmem-cell-names = "offset"' \
	         'rtc-offset@bc' 'local-mac-address' 'vdd-3.3-ch1-supply'; do
		if grep -qF -- "$k" /tmp/.02-dtb.dts; then
			echo "✓ DTB 里含 $k"
		else
			echo "✗ DTB 里**没有** $k —— dts/cepheus-extra.dtsi 没打上（跑 scripts/apply-dts2.sh）"
			dtbfail=1
		fi
	done
	# ★★ 第 3 部分（cepheus-bt.dtsi）落地自检：蓝牙节点必须真的进了 DTB。
	for k in 'qcom,wcn3990-bt' 'vddio-supply' 'vddxo-supply' \
	         'vddrf-supply' 'vddch0-supply' 'max-speed' 'crnv21.bin' 'crbtfw21.tlv'; do
		if grep -qF -- "$k" /tmp/.02-dtb.dts; then
			echo "✓ DTB 里含 $k"
		else
			echo "✗ DTB 里**没有** $k —— dts/cepheus-bt.dtsi 没打上（跑 scripts/apply-dts3.sh）"
			dtbfail=1
		fi
	done
	# ★★ 第 4 部分（cepheus-chg.dtsi）落地自检：充电器/电量计必须真的进了 DTB。
	for k in 'qcom,pm8150b-charger' 'qcom,pm8150b-fg' \
	         'charge-full-design-microamp-hours' 'monitored-battery'; do
		if grep -qF -- "$k" /tmp/.02-dtb.dts; then
			echo "✓ DTB 里含 $k"
		else
			echo "✗ DTB 里**没有** $k —— dts/cepheus-chg.dtsi 没打上（跑 scripts/apply-dts4.sh）"
			dtbfail=1
		fi
	done
	#    充电器/电量计节点的 status 必须是 okay（否则 power_supply 还是空的）
	for pair in 'charger@1000:PM8150B 充电器' 'fuel-gauge@4000:PM8150B 电量计'; do
		node="${pair%%:*}"; desc="${pair##*:}"
		if awk -v n="$node" '$0 ~ n {f=1} f && /status = "okay"/ {ok=1} f && /^[[:space:]]*};/ {exit} END{exit !ok}' /tmp/.02-dtb.dts; then
			echo "✓ DTB 里 $desc ($node) status = okay"
		else
			echo "✗ DTB 里 $desc ($node) 不是 okay —— power_supply 仍然为空"
			dtbfail=1
		fi
	done
	rm -f /tmp/.02-dtb.dts
else
	echo "⚠️  没有 dtc，跳过 UFS status 自检（03 脚本里还会再查一次）"
fi
[ "$dtbfail" = 0 ] || { echo "DTB 不合格，别刷机" >&2; exit 1; }
echo "BUILD_KERNEL_DONE"
