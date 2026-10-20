#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 06-make-kernelfat.sh —— 生成 kernelfat.img（刷到 recovery 分区）
#
#   bash 06-make-kernelfat.sh
#
# 内容：
#   /Image           内核（已内嵌 initramfs，initramfs 里又内嵌了 mods/wifi-cfg）
#   /startup.nsh     UEFI Shell 启动脚本，必须直接执行 fs3:\Image
#
# ★ 2026-10-18 起不再往这个 FAT 里放 mods.tar.gz / wifi-cfg.tar.gz：
#   1) Linux 根本挂不上它 —— UFS 逻辑块是 4096B，而这个 FAT（mformat 默认）
#      是 512B 扇区，内核 vfat 会拒绝："logical sector size too small for device"。
#      （UEFI 固件不在意，所以引导一直正常。）
#   2) 64MB 分区也放不下 47MB 的 Image + 14.5MB 的包。
#   两个包现在由 02 脚本内嵌进 initramfs，init 脚本从 /payload/ 解包。
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$HERE/out}"
SIZE_MB="${SIZE_MB:-64}"

for f in Image; do
	[ -s "$OUT/$f" ] || { echo "缺少 $OUT/$f" >&2; exit 1; }
done

# 空间自检：Image + startup.nsh（+FAT 表开销）必须装得进 SIZE_MB
isz=$(stat -c%s "$OUT/Image")
if [ "$isz" -gt $(( SIZE_MB * 1024 * 1024 - 2 * 1024 * 1024 )) ]; then
	echo "✗ Image 太大（$isz 字节），${SIZE_MB}MB 分区放不下。" >&2
	echo "  Image 里内嵌了 initramfs（含 payload），检查是不是把不需要的大文件塞进去了。" >&2
	exit 1
fi

IMG="$OUT/kernelfat.img"
rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1M count="$SIZE_MB" status=none
mformat -F -i "$IMG" ::

mcopy -i "$IMG" "$OUT/Image"          ::/Image

# startup.nsh：注意必须是“直接执行”，不能 load（load 会报 Image is not a driver）
#
#   console=tty0              屏幕控制台（手机上能看到内核日志）
#
#   ★★ 2026-10-18 起**不再**把 USB 串口写进 console= ★★
#   原来这里是 `console=tty0 console=ttyGS0,115200`。因为 userspace 的 /dev/console
#   取的是**最后一个** console=，所以 systemd 的所有日志都往 USB gadget 串口写。
#   PC 侧只要没人读 COM 口，ACM 的发送缓冲就会灌满 → printk/日志写入**阻塞** →
#   整机冻结。实测（本机）：`systemd-analyze blame` 头一行是
#       `9min 2.287s dev-sda31.device`
#   同一秒 dbus / logind / usb-net / ttyGS0 的启动超时一起触发；dbus 第二次尝试
#   1 秒就成功 → 不是坏，是**被冻住 9 分钟**。而且 dbus 超时会让 NetworkManager
#   的依赖作业失败，NM 再也不会自己起来（WiFi 就没了）。
#   去掉它之后：内核日志只上屏幕（fbcon），systemd 日志只进 journal；
#   **USB 串口的登录 shell 仍然保留**（rootfs 里有 serial-getty@ttyGS0 +
#   autottyGS0.service，initramfs 里也有兜底 shell），救砖路径不受影响。
#
#   fw_devlink=off            ★ 前人「USB 正常版」就是带这个参数启动的，
#                             不带时 USB PHY/UDC 可能因为 supplier 没 probe 上而不工作
#   clk_ignore_unused         不用的一开始就关时钟，避免某些时钟被误关
#   fbcon=font:TER16x32       屏幕上字大一点
#  
#                             ★ 音频的 ASM DAI 驱动找不到 DTS 里的 dais 子节点，
#                               probe 必失败并刷两条 err
#                               （"No dais found in DT" + "probe with driver q6asm-dai failed with error -22"）。
#                               音频不在本轮范围，先按名字屏蔽掉（后面做音频时删掉这一项即可）。
#                               这里放 cmdline 是为了连显式 modprobe 也拦住；
#                               payload 里还有一份 /etc/modprobe.d/blacklist-audio.conf 做双保险。
#
# ★★ 2026-10-18 显示器排查：**不要去动 ABL 留下的东西** ★★
#   现象：非原装屏在 Android / fastboot / UEFI 菜单下正常，Linux 启动到后期变白屏+竖线。
#   已确认：edk2 的显示驱动（SimpleFbDxe）只把 ABL 建好的 framebuffer（0x9C000000,
#           1080x2340）包成 GOP，不发 DSI 命令、不初始化面板；面板是 **ABL(XBL)** 点亮的，
#           之后一直靠 ABL 留下的 DPU/DSI 流水线在扫这块 framebuffer。
#   所以白屏 = Linux 把 ABL 留下的某条电/时钟/域弄没了。已知：
#     - 时钟：clk_ignore_unused 已挡住（日志 "clk: Not disabling unused clocks"）
#     - 电源域：加 pd_ignore_unused 挡住（日志 "genpd: Disabling unused power domains"）
#     - 供电：  加 regulator_ignore_unused 挡住（late_initcall 会关掉"没人认领"的 regulator，
#               实测 refgen 已经是 disabled 状态）
#   consoleblank=0            关掉控制台自动熄屏（10 分钟），排障时屏幕别自己黑
#   iomem=relaxed             诊断用：放开 /dev/mem 对 MMIO 的访问（默认被
#                             CONFIG_IO_STRICT_DEVMEM 拦成 "mmap: Operation not permitted"）
#   log_buf_len=4M            诊断用：默认 ring buffer 太小，loglevel=7 时早期启动日志
#                             会被后面的刷掉（这轮要对比"启动早期 vs 后期"的状态）
#
# ★★★ 2026-10-19 白屏根因（已实锤）：dispcc 驱动把显示时钟「停车」了 ★★★
#   真凶：drivers/clk/qcom/dispcc-sm8250.c（CONFIG_SM_DISPCC_8250=y，内建）
#     它有三个 RCG 用 clk_rcg2_shared_ops：
#       disp_cc_mdss_ahb_clk_src  (cmd_rcgr=0x22bc)
#       disp_cc_mdss_mdp_clk_src  (cmd_rcgr=0x20c8)
#       disp_cc_mdss_rot_clk_src  (cmd_rcgr=0x20e0)
#     而 clk_rcg2_shared_ops.init = clk_rcg2_shared_init() 在**注册时无条件**调
#     clk_rcg2_shared_disable()，把 RCG 的时钟源切到 safe source（=XO 19.2MHz）：
#       源码注释："The safest option here is to 'park' the RCG at init so that
#                  the clk can never get stuck on or off."
#     唯一能「解停车」的路径是有 Linux 消费者 clk_prepare_enable() 这些时钟
#     （clk_rcg2_shared_enable() 会把 parked_cfg 写回硬件）。
#
#   为什么永远没人解停车：我们 DTB 里 framebuffer@9c000000 的 clocks 只写了
#     <&gcc GCC_DISP_HF_AXI_CLK>, <&gcc GCC_DISP_SF_AXI_CLK>  ← GCC 的
#     （这是 "no panel driver yet & no dispcc either" 时代的写法，抄自 kumano）。
#     设备实测：这两个 GCC 时钟 enable_count=1（simplefb claim 了），而全部
#     disp_cc_mdss_* 时钟的 enable_count=0 → 没有任何消费者 → 停车永不撤销。
#
#   后果：ABL 点亮的 DPU/DSI 流水线时钟源被换成 19.2MHz XO → 视频流断流 →
#         面板（video 模式、无 GRAM）白屏 + 竖线。
#   为什么 debugfs 里 mdp_clk_src 还显示 345MHz？因为停在车状态下
#     clk_rcg2_shared_recalc_rate() 返回的是 parked_cfg 缓存（=注册时存下的
#     ABL 原值），不是硬件真实值 —— 是个假象，别被骗。
#
#   药方：initcall_blacklist=disp_cc_sm8250_driver_init
#     —— 让 dispcc 驱动完全不注册，于是：
#       * 显示时钟源保持 ABL 配好的样子（不被停车）→ 面板继续正常显示
#       * mdss_gdsc / MMCX 也不会被内核碰（关电那一步已被 pd_ignore_unused 挡住）
#       * simplefb 用的是 GCC 时钟，不受影响 → /dev/fb0 照常可用
#     以后真上 DRM(msm)+面板驱动时，必须删掉这一项（那时由显示驱动正式接管）。
#
#   已排除的旧假设（留档，别再走一遍）：
#     - SMMU：加了 arm-smmu.disable_bypass=0、实测参数确实生效，仍白屏 ⇒ 不是主因。
#     - clk_ignore_unused / pd_ignore_unused / regulator_ignore_unused：都管不住
#       「注册那一刻就停车」，所以无效。
#     - PMIC 调压 / disp_vddio_vreg(TLMM GPIO84)：逐条比对厂商 DTB 一致，且当前
#      running DTB 里根本没有 disp_vddio_vreg 节点（Linux 压根没动显示 VDDIO）。
#
# ---- 以下为**已推翻**的旧假设，仅留档 ----
# ★★★ [已推翻] 2026-10-18 猜测：SMMU 把显示子系统的 stream 判成 FAULT ★★★
#   证据链：
#     1) .config 里 CONFIG_ARM_SMMU_DISABLE_BYPASS_BY_DEFAULT=y
#        → arm-smmu.c: disable_bypass 初值 = true
#        → s2cr_init_val = S2CR_TYPE_FAULT；arm_smmu_device_reset() 把所有
#          stream 组重写成 FAULT，并置 sCR0.USFCFG（未匹配的 stream 也 abort）
#     2) dmesg: "arm-smmu 15000000.iommu: preserved 0 boot mappings"
#        → 只有 ACPI/IORT RMR 里的映射才会被保留；我们用 DTB 启动 → 必然是 0，
#          也就是说 ABL 配在 SMMU 里的东西一条都没被保住
#     3) 我们的 DTB 里 display-subsystem/dpu/dsi 全是 status="disabled"
#        → 显示子系统在 Linux 里"没人认领" → 它原来 bypass 的 stream 被改成 FAULT
#   后果：DPU 从 0x9C000000 取像的 AXI 读被 SMMU 拒绝 → 面板丢掉像素流
#         → 白屏 + 竖线。时间点吻合：fbcon 画企鹅在 0.227s，SMMU 重写在 0.236s，
#         所以最多只闪一下。
#   当时的药方（**已被推翻**；disable_bypass=0 实测仍白屏，保留只为安全兜底）：
#     arm-smmu.disable_bypass=0
#   → disable_bypass=false → s2cr_init_val 变回 BYPASS，且不置 USFCFG
#   → "没人认领"的 stream 恢复 bypass → DPU 取像恢复正常。
#   注意：这是 module_param，built-in 代码在 cmdline 里的名字带模块名前缀，
#         所以必须写成 arm-smmu.disable_bypass=0（KBUILD_MODNAME = "arm-smmu"）。
#   代价：未知 stream 也放行（安全上宽松一点），等以后真上 DRM(msm)+面板驱动、
#         让显示子系统自己认领 stream 之后，就可以删掉这一项。
cat > "$OUT/startup.nsh" <<'EOF'
fs3:\Image console=tty0 loglevel=7 log_buf_len=4M fw_devlink=off clk_ignore_unused regulator_ignore_unused pd_ignore_unused arm-smmu.disable_bypass=0 initcall_blacklist=disp_cc_sm8250_driver_init iomem=relaxed consoleblank=0 fbcon=font:TER16x32
EOF
mcopy -i "$IMG" "$OUT/startup.nsh" ::/startup.nsh

echo "================= kernelfat.img 内容 ================="
mdir -i "$IMG" :: 2>/dev/null || true
echo
echo "产物: $IMG ($(stat -c%s "$IMG") 字节)"
echo "大小参考：交接包里的 kernelfat-clean.img 是 67108864 字节（64MB）"
echo "MAKE_KERNELFAT_DONE"
