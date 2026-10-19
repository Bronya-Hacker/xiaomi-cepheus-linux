<#
  flash.ps1 —— Windows 侧刷机（fastboot）

  用法（在 wifi-bringup 目录下）：
      .\scripts\flash.ps1 -Boot .\out\boot-cepheus.img -Kernelfat .\out\kernelfat.img

  或者用默认路径（自动找 out\ 下的产物）：
      .\scripts\flash.ps1

  ★ 安全红线：
    - 绝对不要执行 fastboot erase dtbo / erase vbmeta  → 会 Load Error
    - 本脚本只做两件事：flash boot、flash recovery
#>
[CmdletBinding()]
param(
    [string]$Boot,
    [string]$Kernelfat,
    [string]$Fastboot = "C:\Users\MAO\DoubaoWork\chats\2026-10-15\new-chat\mi9-linux-project\tools\pt33\platform-tools\fastboot.exe",
    [switch]$NoReboot
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot      # wifi-bringup\
$out  = Join-Path $root 'out'

if (-not $Boot)      { $Boot      = Join-Path $out 'boot-cepheus.img' }
if (-not $Kernelfat) { $Kernelfat = Join-Path $out 'kernelfat.img' }

function Fail($m) { Write-Host "✗ $m" -ForegroundColor Red; exit 1 }
function Ok($m)   { Write-Host "✓ $m" -ForegroundColor Green }
function Info($m) { Write-Host "  $m" }

Write-Host "`n===== 检查输入 =====" -ForegroundColor Cyan
foreach ($f in @($Boot, $Kernelfat)) {
    if (-not (Test-Path -LiteralPath $f)) { Fail "找不到文件: $f" }
    $len = (Get-Item -LiteralPath $f).Length
    Info ("{0}  ({1} 字节)" -f (Split-Path -Leaf $f), $len)
}
if ($Kernelfat -and (Get-Item -LiteralPath $Kernelfat).Length -ne 67108864) {
    Write-Host "  ⚠ kernelfat 不是 67108864 字节（64MB），确认一下是不是搞错了文件" -ForegroundColor Yellow
}
if (-not (Test-Path -LiteralPath $Fastboot)) {
    Fail "找不到 fastboot: $Fastboot`n   请用 -Fastboot <路径> 指定"
}

Write-Host "`n===== 检查手机 =====" -ForegroundColor Cyan
$devices = & $Fastboot devices 2>&1
if (-not $devices -or "$devices" -notmatch '\S') {
    Fail "fastboot 没看到设备。请让手机进 fastboot 模式（音量- + 电源），接好 USB，再重跑。"
}
Info "$devices"

Write-Host "`n===== 开始刷写 =====" -ForegroundColor Cyan
Info "1/2  boot     <- $(Split-Path -Leaf $Boot)      （UEFI 固件，内含 DTB）"
& $Fastboot flash boot $Boot
if ($LASTEXITCODE -ne 0) { Fail "fastboot flash boot 失败" }
Ok "boot 刷写完成"

Info "2/2  recovery <- $(Split-Path -Leaf $Kernelfat)  （Image + payload + startup.nsh）"
& $Fastboot flash recovery $Kernelfat
if ($LASTEXITCODE -ne 0) { Fail "fastboot flash recovery 失败" }
Ok "recovery 刷写完成"

if ($NoReboot) {
    Write-Host "`n已按 -NoReboot 跳过重启。" -ForegroundColor Yellow
} else {
    Write-Host "`n===== 重启进系统 =====" -ForegroundColor Cyan
    # ★ 这台机器上 `fastboot reboot` 会被 bootloader 拦下（报错/不生效），
    #   用 `fastboot continue` 从 fastboot 直接正常启动。
    & $Fastboot continue
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  fastboot continue 没成功，改用 adb reboot 试试" -ForegroundColor Yellow
        $adb = Join-Path (Split-Path -Parent $Fastboot) 'adb.exe'
        if (Test-Path -LiteralPath $adb) { & $adb reboot } else { Write-Host "  请手动长按电源键重启手机" }
    }
}

Write-Host @"

================ 刷完了，接下来 ================
手机重启后进 UEFI Shell → 执行 fs3:\Image → 进 Ubuntu。

上机第一件事（第 0 关，确认 DTB 真的换了）：
    cat /proc/device-tree/soc@0/wifi@18800000/status
    cat /proc/device-tree/soc@0/remoteproc@17300000/status
    cat /proc/device-tree/soc@0/remoteproc@17300000/firmware-name
期望：okay / okay / qcom/sm8150/adsp.mdt

然后看 WiFi 三件事：
    systemctl status tqftpserv wifi-up
    cat /run/wifi-up.log
    ip link show wlan0

固件自检（缺一个都不行）：
    ls -l /lib/firmware/qcom/sm8150/adsp.mdt          # 手机自带，拆分固件的入口
    ls -l /lib/firmware/qcom/sm8150/wlanmdsp.mbn      # payload 投递
    ls -l /lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin

详细清单见 wifi-bringup/docs/verify.md
"@ -ForegroundColor Gray
