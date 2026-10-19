Xiaomi Mi 9 (cepheus / SM8150) -- headless mainline Linux
fastboot package, payload @VERSION@
built @BUILT@

Contents
  boot.img        UEFI (edk2-msm) + DTB            -> fastboot flash boot
  recovery.img    64 MiB FAT: Image + initramfs +  -> fastboot flash recovery
                  payload (WiFi / Bluetooth / charge)
  MANIFEST.txt    sha256 of the images
  verify-images.ps1
  flash-all.bat   one click: verify, flash boot, flash recovery, continue

How to flash
  1. Get fastboot: Android platform-tools. This batch file looks in PATH and
     in %LOCALAPPDATA%\Android\platform-tools.
  2. Enter fastboot on the phone:
       - power off, hold Volume-Down + Power until the screen shows FASTBOOT, or
       - from a running system: adb reboot bootloader
  3. Run flash-all.bat (double click).

What it does NOT touch
  userdata (your files and /etc), dtbo, vbmeta, persist, modem, xbl/abl.
  Do NOT run: fastboot erase dtbo / vbmeta / persist

After flashing
  First boot takes 60-90 s. Then:
    ssh root@169.254.42.1 'cat /etc/wifi-cfg.ver; mi9-doctor.sh'

WiFi
  This package ships NO credentials (only *.example templates).
  Configure your own network once the system is up:
    nmcli dev wifi connect "YOUR-SSID" password "YOUR-PASS"
  or copy /etc/NetworkManager/system-connections/mi9-wifi.nmconnection.example
  to mi9-wifi.nmconnection and edit ssid/psk.

Rollback
  The previous images are kept on the phone in /root/kernelfat-srv*.img and
  /root/boot-cepheus.img (see docs/restore.md).
