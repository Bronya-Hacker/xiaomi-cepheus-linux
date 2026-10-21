#!/bin/sh
# mi9-flash —— 在 Linux 系统内直接写分区，**不需要进 fastboot**
#
# 用法：
#   mi9-flash boot     <镜像>     # 写 boot 分区（edk2 + DTB，128MB）
#   mi9-flash recovery <镜像>     # 写 recovery 分区（kernelfat，64MB）
#   mi9-flash status              # 看当前各分区与镜像大小
#
# 选项：
#   --no-reboot   写完不自动重启（默认写完重启）
#   --no-backup   不备份原分区内容（默认备份到 /var/backups/mi9-flash/）
#
# 为什么需要它：本机 by-partlabel 可用（99 个分区都能按名字访问），
# 所以可以直接 dd 写 boot/recovery，省掉"走到手机旁按音量下+电源"的步骤。
# 写完 sync 后重启即可生效。
#
# ★ 安全措施：
#   1. 只允许 boot / recovery 两个分区（白名单），避免误写把设备刷砖
#   2. 写入前校验镜像不大于分区大小
#   3. 默认先把原分区备份到 /var/backups/mi9-flash/
#   4. 写完回读校验 md5
set -u

PARTLABEL_DIR=/dev/disk/by-partlabel
BACKUP_DIR=/var/backups/mi9-flash
REBOOT=1
DO_BACKUP=1

log() { logger -t mi9-flash "$*"; echo "$*"; }

part_size_bytes() {
	dev=$(readlink -f "$PARTLABEL_DIR/$1" 2>/dev/null) || return 1
	[ -b "$dev" ] || return 1
	sec=$(cat "/sys/class/block/$(basename "$dev")/size" 2>/dev/null) || return 1
	echo $((sec * 512))
}

show_status() {
	echo "=== 分区 ==="
	for p in boot recovery; do
		dev=$(readlink -f "$PARTLABEL_DIR/$p" 2>/dev/null)
		sz=$(part_size_bytes "$p" 2>/dev/null || echo 0)
		printf '  %-10s %-14s %s MB\n' "$p" "${dev:-无}" "$((sz / 1024 / 1024))"
	done
	echo "=== 备份 ==="
	ls -l "$BACKUP_DIR" 2>/dev/null | tail -n 5
}

do_flash() {
	part=$1
	img=$2

	case "$part" in
	boot|recovery) ;;
	*) log "拒绝：只允许 boot / recovery（收到 '$part'）"; exit 1 ;;
	esac

	[ -f "$img" ] || { log "镜像不存在：$img"; exit 1; }

	dev=$(readlink -f "$PARTLABEL_DIR/$part" 2>/dev/null)
	[ -b "$dev" ] || { log "找不到分区 $part"; exit 1; }

	psz=$(part_size_bytes "$part")
	isz=$(stat -c %s "$img")
	if [ "$isz" -gt "$psz" ]; then
		log "拒绝：镜像 $isz 字节 > 分区 $psz 字节"
		exit 1
	fi

	log "写入 $part ($dev)：$img ($isz 字节 / 分区 $psz 字节)"

	if [ "$DO_BACKUP" = "1" ]; then
		mkdir -p "$BACKUP_DIR"
		bk="$BACKUP_DIR/${part}.$(date +%Y%m%d-%H%M%S).img"
		log "备份原内容 -> $bk"
		dd if="$dev" of="$bk" bs=1M count=$((psz / 1024 / 1024)) 2>/dev/null
		log "备份完成 $(stat -c %s "$bk" 2>/dev/null) 字节"
	fi

	log "写入中..."
	if ! dd if="$img" of="$dev" bs=1M conv=fsync 2>/dev/null; then
		log "写入失败！"
		exit 1
	fi
	sync

	# 回读校验
	n=$((isz / 1024 / 1024))
	[ "$n" -lt 1 ] && n=1
	a=$(md5sum "$img" | cut -d' ' -f1)
	b=$(dd if="$dev" bs=1M count=$n 2>/dev/null | head -c "$isz" | md5sum | cut -d' ' -f1)
	if [ "$a" = "$b" ]; then
		log "校验通过 md5=$a"
	else
		log "校验不一致！镜像=$a 分区=$b"
		exit 1
	fi

	if [ "$REBOOT" = "1" ]; then
		log "重启生效..."
		sync
		systemctl reboot &
	fi
}

case "${1:-status}" in
status|"")
	show_status
	;;
boot|recovery)
	part=$1
	shift
	img=""
	for a in "$@"; do
		case "$a" in
		--no-reboot) REBOOT=0 ;;
		--no-backup) DO_BACKUP=0 ;;
		*) img=$a ;;
		esac
	done
	[ -n "$img" ] || { log "用法: mi9-flash $part <镜像> [--no-reboot] [--no-backup]"; exit 1; }
	do_flash "$part" "$img"
	;;
*)
	log "用法: mi9-flash [status|boot <img>|recovery <img>] [--no-reboot] [--no-backup]"
	exit 1
	;;
esac
