# ---------------------------------------------------------------------------
# 08-backup-golden.ps1 -- save the current known-good artifacts to backups\
#
# Usage (Windows PowerShell):
#   powershell -ExecutionPolicy Bypass -File scripts\08-backup-golden.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\08-backup-golden.ps1 -Dest backups\golden-2026-10-19
#   powershell -ExecutionPolicy Bypass -File scripts\08-backup-golden.ps1 -Verify backups\golden-2026-10-19
#
# What it copies: boot-cepheus.img, kernelfat.img, Image, initramfs.cpio.gz,
# wifi-cfg.tar.gz + a MANIFEST.txt with sha256 and the payload version.
# Pure ASCII on purpose (PowerShell 5.1 + Chinese console = mojibake).
# ---------------------------------------------------------------------------
param(
    [string]$Dest = "",
    [string]$Verify = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot          # repo root
$Out  = Join-Path $Root "out"

function Get-Sha256([string]$Path) {
    (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
}

function Get-Version {
    $f = Join-Path $Root "payload\etc\wifi-cfg.ver"
    if (Test-Path $f) { (Get-Content $f -TotalCount 1).Trim() } else { "unknown" }
}

# ---------------- verify mode ----------------
if ($Verify -ne "") {
    $man = Join-Path $Verify "MANIFEST.txt"
    if (-not (Test-Path $man)) { Write-Host "no MANIFEST.txt in $Verify"; exit 1 }
    $bad = 0
    foreach ($line in Get-Content $man) {
        if ($line -match '^([0-9a-f]{64})\s+\*?(.+)$') {
            $want = $Matches[1]
            $name = $Matches[2].Trim()
            $p = Join-Path $Verify $name
            if (-not (Test-Path $p)) { Write-Host "MISSING $name"; $bad++; continue }
            $got = Get-Sha256 $p
            if ($got -eq $want) { Write-Host "ok      $name" }
            else { Write-Host "BAD     $name`n  want $want`n  got  $got"; $bad++ }
        }
    }
    if ($bad -eq 0) { Write-Host "`nall files verified."; exit 0 }
    Write-Host "`n$bad file(s) failed."; exit 1
}

# ---------------- backup mode ----------------
if ($Dest -eq "") {
    $Dest = Join-Path $Root ("backups\golden-" + (Get-Date -Format "yyyyMMdd-HHmm"))
}
New-Item -ItemType Directory -Force -Path $Dest | Out-Null

$files = @(
    "boot-cepheus.img",
    "kernelfat.img",
    "Image",
    "initramfs.cpio.gz",
    "wifi-cfg.tar.gz"
)

$lines = @()
$lines += "# Mi9 (cepheus) golden backup"
$lines += "time    : " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
$lines += "payload : " + (Get-Version)
$lines += "source  : $Out"
$lines += ""
$lines += "# sha256                                                            size      file"

foreach ($f in $files) {
    $src = Join-Path $Out $f
    if (-not (Test-Path $src)) { Write-Host "skip (missing) $f"; continue }
    $dst = Join-Path $Dest $f
    Copy-Item -Path $src -Destination $dst -Force
    $h = Get-Sha256 $dst
    $s = (Get-Item $dst).Length
    $lines += ("{0}  {1,10}  {2}" -f $h, $s, $f)
    Write-Host ("copied {0}  ({1:N1} MB)" -f $f, ($s / 1MB))
}

$man = Join-Path $Dest "MANIFEST.txt"
[IO.File]::WriteAllLines($man, $lines, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "golden backup: $Dest"
Write-Host "manifest     : $man"
Write-Host ""
Write-Host "verify later :"
Write-Host "  powershell -ExecutionPolicy Bypass -File scripts\08-backup-golden.ps1 -Verify `"$Dest`""
