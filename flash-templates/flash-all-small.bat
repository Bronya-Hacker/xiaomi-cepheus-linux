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