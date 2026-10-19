# ---------------------------------------------------------------------------
# 09-make-fastboot-package.ps1 -- build a one-click fastboot package
#
# Usage (Windows PowerShell):
#   powershell -ExecutionPolicy Bypass -File scripts\09-make-fastboot-package.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\09-make-fastboot-package.ps1 -Dest D:\flash\cepheus
#
# Output (default: <repo>\flash\cepheus-<payload version>\):
#   boot.img            UEFI (edk2-msm) + DTB          -> fastboot flash boot
#   recovery.img        64 MiB FAT: Image + initramfs  -> fastboot flash recovery
#                       + payload (WiFi / BT / charge)
#   MANIFEST.txt        sha256 of the images
#   verify-images.ps1   hash check used by flash-all.bat
#   flash-all.bat       one-click: verify -> flash boot -> flash recovery -> continue
#   README.txt          instructions
#
# What this package does NOT touch: userdata, dtbo, vbmeta, persist, modem,
# xbl/abl.  The images come from out\ (the same bytes that are on the phone).
# Pure ASCII on purpose (PowerShell 5.1 + Chinese console = mojibake).
# ---------------------------------------------------------------------------
param(
    [string]$Dest = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Src  = Join-Path $Root "out"

$VerFile = Join-Path $Root "payload\etc\wifi-cfg.ver"
$Ver = if (Test-Path $VerFile) { (Get-Content $VerFile -TotalCount 1).Trim() } else { "unknown" }

if ($Dest -eq "") {
    $Dest = Join-Path $Root ("flash\cepheus-" + $Ver)
}
New-Item -ItemType Directory -Force -Path $Dest | Out-Null

# ---- images ---------------------------------------------------------------
$map = [ordered]@{
    "boot-cepheus.img" = "boot.img"
    "kernelfat.img"    = "recovery.img"
}
$manifest = New-Object System.Collections.Generic.List[string]
$manifest.Add("# Mi9 (cepheus) fastboot package")
$manifest.Add("version : $Ver")
$manifest.Add("built   : " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
$manifest.Add("")
$manifest.Add("# sha256 (sha256sum -c compatible):")

foreach ($k in $map.Keys) {
    $imgSrc = Join-Path $Src $k
    $dst = Join-Path $Dest $map[$k]
    if (-not (Test-Path $imgSrc)) { throw "missing $imgSrc -- run scripts\07-rebuild-all-wsl.sh first" }
    Copy-Item $imgSrc $dst -Force
    $h = (Get-FileHash $dst -Algorithm SHA256).Hash.ToLower()
    $sz = (Get-Item $dst).Length
    $manifest.Add(("{0}  {1}" -f $h, $map[$k]))
    Write-Host ("  {0,-14} {1,8:N1} MB  {2}" -f $map[$k], ($sz / 1MB), $h.Substring(0, 16))
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllLines((Join-Path $Dest "MANIFEST.txt"), $manifest, $utf8)

# ---- verify-images.ps1 ----------------------------------------------------
$verify = @'
$ErrorActionPreference = "Stop"
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$man = Join-Path $dir "MANIFEST.txt"
if (-not (Test-Path $man)) { Write-Host "[x] MANIFEST.txt missing"; exit 1 }
$bad = 0
foreach ($line in Get-Content $man) {
    if ($line -match '^([0-9a-f]{64})\s+\*?(.+)$') {
        $want = $Matches[1]
        $name = $Matches[2].Trim()
        $p = Join-Path $dir $name
        if (-not (Test-Path $p)) { Write-Host "[x] missing $name"; $bad++; continue }
        $got = (Get-FileHash $p -Algorithm SHA256).Hash.ToLower()
        if ($got -ne $want) { Write-Host "[x] hash mismatch: $name"; $bad++ }
        else { Write-Host "[ok] $name" }
    }
}
if ($bad -ne 0) { Write-Host "[x] $bad file(s) failed"; exit 1 }
Write-Host "[ok] all images verified"
exit 0
'@
[IO.File]::WriteAllText((Join-Path $Dest "verify-images.ps1"), ($verify -replace "`r", "`r"), $utf8)

# ---- flash-all.bat --------------------------------------------------------
$bat = @'
@echo off
setlocal
cd /d "%~dp0"
title Mi9 (cepheus) fastboot flash

set "FB=fastboot"
where fastboot >nul 2>&1
if errorlevel 1 set "FB=%LOCALAPPDATA%\Android\platform-tools\fastboot.exe"
if not exist "%FB%" if /i not "%FB%"=="fastboot" goto nofb

echo == verify images ==
powershell -NoProfile -ExecutionPolicy Bypass -File "verify-images.ps1"
if errorlevel 1 goto fail

echo.
echo == device ==
"%FB%" devices
echo.

echo == flash boot (UEFI + DTB) ==
"%FB%" flash boot boot.img
if errorlevel 1 goto fail

echo == flash recovery (kernel + initramfs + payload) ==
"%FB%" flash recovery recovery.img
if errorlevel 1 goto fail

echo.
echo == continue (boot the phone) ==
"%FB%" continue
echo.
echo [ok] done. First boot takes 60-90 seconds.
echo      Check: cat /etc/wifi-cfg.ver   and   mi9-doctor.sh
pause
exit /b 0

:nofb
echo [x] fastboot not found.
echo     Install Android platform-tools, or put fastboot.exe in PATH,
echo     or extract them to %LOCALAPPDATA%\Android\platform-tools
pause
exit /b 1

:fail
echo.
echo [x] FLASH FAILED. The phone should still be in fastboot -- just run this again.
echo     Never run: fastboot erase dtbo / vbmeta / persist
pause
exit /b 1
'@
[IO.File]::WriteAllText((Join-Path $Dest "flash-all.bat"), ($bat -replace "`r", "`r"), $utf8)

# ---- README.txt -----------------------------------------------------------
$readme = @"
Xiaomi Mi 9 (cepheus / SM8150) -- headless mainline Linux
fastboot package, payload $Ver
built $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

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

Rollback
  The previous images are kept on the phone in /root/kernelfat-srv*.img and
  /root/boot-cepheus.img (see docs/restore.md).
"@
[IO.File]::WriteAllText((Join-Path $Dest "README.txt"), ($readme -replace "`r", "`r"), $utf8)

Write-Host ""
Write-Host "package: $Dest"
Write-Host ("files  : " + ((Get-ChildItem $Dest -File | Measure-Object Length -Sum).Sum / 1MB).ToString("N1") + " MB")
Write-Host ""
Write-Host "flash: double-click flash-all.bat (phone must be in fastboot)"
