# ---------------------------------------------------------------------------
# 11-wifi-usb.ps1 -- change the WiFi network of a RUNNING phone over USB
#
#   powershell -ExecutionPolicy Bypass -File scripts\11-wifi-usb.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\11-wifi-usb.ps1 -Ssid "560" -Psk "secret"
#   ... -List        only list visible networks
#
# Why: after flashing, the phone is reachable at 169.254.42.1 over the USB
# gadget even when WiFi is down. This script updates the existing "mi9-wifi"
# NetworkManager profile (or creates one) and reconnects -- no rebuild, no
# reboot, no typing on the phone.
#
# Requirements: root SSH key (C:\Users\MAO\.ssh\mi9_key by default), USB cable.
# Pure ASCII on purpose.
# ---------------------------------------------------------------------------
param(
    [string]$Ssid = "",
    [string]$Psk = "",
    [switch]$List,
    [string]$Key = "$env:USERPROFILE\.ssh\mi9_key",
    [string]$HostIP = "169.254.42.1"
)

$ErrorActionPreference = "Continue"
$utf8 = New-Object System.Text.UTF8Encoding($false)
$tmpDir = Join-Path $env:TEMP "mi9-wifi"
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

function Invoke-Remote([string]$ScriptPath) {
    $out = cmd /c "ssh -i `"$Key`" -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL root@$HostIP bash -s < `"$ScriptPath`"" 2>&1
    return ($out | Out-String)
}

# ---- connectivity ---------------------------------------------------------
$probe = Join-Path $tmpDir "probe.sh"
[IO.File]::WriteAllText($probe, "echo ok`n", $utf8)
$r = Invoke-Remote $probe
if ($r -notmatch "ok") {
    Write-Host "[x] cannot reach root@$HostIP over USB."
    Write-Host "    - is the cable connected?"
    Write-Host "    - is the key at $Key ?"
    Write-Host $r
    exit 1
}

# ---- list networks --------------------------------------------------------
$scan = Join-Path $tmpDir "scan.sh"
[IO.File]::WriteAllText($scan,
    "nmcli -t -f SSID,SIGNAL,SECURITY dev wifi list 2>/dev/null | head -40`n", $utf8)
$scanOut = Invoke-Remote $scan

Write-Host "== visible networks (SSID : signal : security) =="
$scanOut.Split("`n") | Where-Object { $_.Trim() -ne "" } | ForEach-Object { "  " + $_.Trim() }

if ($List) { exit 0 }

if ($Ssid -eq "") { $Ssid = (Read-Host "`nSSID to connect").Trim() }
if ($Psk -eq "") {
    $sec = Read-Host "password" -AsSecureString
    $Psk = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
if ($Ssid -eq "" -or $Psk -eq "") { throw "SSID/password required" }

# base64 keeps the values out of shell quoting entirely
$b64s = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Ssid))
$b64p = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Psk))

$body = @'
if nmcli -t -f NAME con show 2>/dev/null | grep -qx mi9-wifi; then
    nmcli con mod mi9-wifi wifi.ssid "$S"
    nmcli con mod mi9-wifi wifi-sec.psk "$P"
    nmcli con up mi9-wifi
else
    nmcli dev wifi connect "$S" password "$P" ifname wlan0
fi
sleep 2
echo
echo '== result =='
nmcli -t -f GENERAL.CONNECTION,GENERAL.STATE,IP4.ADDRESS dev show wlan0 2>/dev/null
ip -4 -o addr show wlan0 2>/dev/null | awk '{print "wlan0", $4}'
'@

$header = "S=`$(printf '%s' '$b64s' | base64 -d)" + "`n" + "P=`$(printf '%s' '$b64p' | base64 -d)" + "`n"

$connect = Join-Path $tmpDir "connect.sh"
[IO.File]::WriteAllText($connect, $header + $body, $utf8)

Write-Host ""
Write-Host "== switching to '$Ssid' =="
Invoke-Remote $connect
