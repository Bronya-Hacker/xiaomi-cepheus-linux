Xiaomi Mi 9 (cepheus / SM8150) -- 整机安装包 full-2026-10-19-r3
payload version @VERSION@ (screen blanking, power-key wake, idle blank after 60 s)
================================================================

这是一个完整系统安装包：刷完就是一台能直接用的 Ubuntu 24.04 服务器，
不需要事先在手机上装任何东西。

内容
  boot.img                  UEFI (edk2-msm) + DTB
  recovery.img              64 MiB FAT：内核 Image + initramfs + payload
  rootfs.img.tar.zst        完整根文件系统（ext4 4 GB，tar+zstd，压缩后 1.01 GiB）
  flash-all.bat             一键安装
  verify-images.ps1         校验 boot/recovery
  MANIFEST.txt              sha256

安装前提
  - 小米9 (cepheus)，bootloader 已解锁
  - Windows + Android platform-tools（fastboot 不在 PATH 时放在
    %LOCALAPPDATA%\Android\platform-tools）
  - 磁盘剩余 >= 5 GB（要解压出 4 GB 的 rootfs.img）
  - 空闲内存 >= 6 GB：新版 fastboot 会把整个镜像读进内存，内存不够会报
    std::bad_alloc。遇到就关掉浏览器等程序再试；或者用 platform-tools
    28.x 的 fastboot（会分块发送，4 GB 只要 ~2.5 分钟）
  - 手机进 fastboot 模式（关机后按住 音量下 + 电源）

安装
  1. 从 Release 下载这 2 个文件，放进同一个目录：
       cepheus-full-2026-10-19-r3.zip
       rootfs.img.tar.zst
  2. 解压 zip（得到 boot.img / recovery.img / flash-all.bat 等）
  3. 把 rootfs.img.tar.zst 拷进解压出来的目录
  4. 双击 flash-all.bat，按提示确认

  脚本做的事：
    校验 boot/recovery -> 刷 boot -> 刷 recovery
    -> tar 解压出 rootfs.img
    -> fastboot flash userdata rootfs.img
    -> fastboot continue 开机

会清掉  userdata (sda31)：手机上的所有数据、系统、配置
不会动  dtbo / vbmeta / persist / modem / xbl / abl
  绝对不要执行：fastboot erase dtbo / erase vbmeta / erase persist

首次开机
  - 1-2 分钟
  - 自动把 4 GB 的文件系统扩展到整个 110 GB 分区（几秒钟）
  - 自动生成 SSH host key
  - root 密码：mi9（首次登录会强制修改）
  - 主机名：umeko-device
  - 不含任何 WiFi 口令（只有 *.example 模板）

WiFi
  系统起来后配置你自己的网络：
    nmcli dev wifi connect "你的SSID" password "你的密码"
  或者把 /etc/NetworkManager/system-connections/mi9-wifi.nmconnection.example
  复制成 mi9-wifi.nmconnection 再改 ssid/psk。

登录方式
  1) USB 网口（推荐，开箱即用）
     手机插电脑 -> Windows 会多一个网卡 -> 设 IP 169.254.42.2/24
     ssh root@169.254.42.1
  2) USB 串口：设备管理器里的 COM 口，115200 8N1，ttyGS0
  3) WiFi：见上面，配置好之后 ssh root@<手机IP>

校验
  rootfs.img.tar.zst sha256 9bad365d77808d02d3534b325f4a1ab9a3799be8ccef7e43bf3f4fc797e4ed48

回滚
  重新刷原来的小包（boot + recovery）不会恢复 userdata。
  要恢复数据请用你自己事先做的 L3 备份（docs/restore.md）。
