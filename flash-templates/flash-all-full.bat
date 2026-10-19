@echo off
setlocal
cd /d "%~dp0"
title Mi9 (cepheus) FULL system install

set "FB=fastboot"
where fastboot >nul 2>&1
if errorlevel 1 set "FB=%LOCALAPPDATA%\Android\platform-tools\fastboot.exe"
if not exist "%FB%" if /i not "%FB%"=="fastboot" goto nofb

echo ============================================================
echo   Mi9 (cepheus) FULL system install
echo.
echo   WARNING: this ERASES userdata (all files on the phone).
echo   Make sure you have a backup before you continue.
echo.
echo   fastboot loads the whole image into RAM. If it fails with
echo   std::bad_alloc, close some programs (browser etc.) and retry.
echo ============================================================
pause

echo.
echo == device ==
"%FB%" devices
echo.
echo == verify boot/recovery ==
powershell -NoProfile -ExecutionPolicy Bypass -File "verify-images.ps1"
if errorlevel 1 goto fail

echo.
echo == [1/4] flash boot (UEFI + DTB) ==
"%FB%" flash boot boot.img
if errorlevel 1 goto fail

echo.
echo == [2/4] flash recovery (kernel + initramfs + payload) ==
"%FB%" flash recovery recovery.img
if errorlevel 1 goto fail

echo.
echo == [3/4] prepare rootfs image (needs ~5 GB free disk) ==
if exist rootfs.img goto flashroot
if not exist rootfs.img.tar.zst goto notar
echo     decompressing with tar (about 1 min) ...
tar -xf rootfs.img.tar.zst
if errorlevel 1 goto fail
if not exist rootfs.img goto fail

:flashroot
echo.
echo == [4/4] flash userdata (4 GB, about 3-5 min) ==
"%FB%" flash userdata rootfs.img
if errorlevel 1 goto fail

echo.
echo == booting ==
"%FB%" continue
echo.
echo [ok] done.
echo      First boot takes 1-2 minutes, then the 4 GB filesystem
echo      is grown to the full 110 GB automatically.
echo      root password: mi9   (you must change it at first login)
pause
exit /b 0

:notar
echo [x] rootfs.img.tar.zst not found.
echo     Download it from the GitHub release and put it next to this file.
pause
exit /b 1

:nofb
echo [x] fastboot not found.
echo     Install Android platform-tools, or put fastboot.exe in PATH,
echo     or extract them to %LOCALAPPDATA%\Android\platform-tools
pause
exit /b 1

:fail
echo.
echo [x] FAILED. The phone should still be in fastboot -- just run this again.
echo     Never run: fastboot erase dtbo / vbmeta / persist
pause
exit /b 1
