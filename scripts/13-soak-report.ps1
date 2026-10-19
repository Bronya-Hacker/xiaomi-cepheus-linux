# ---------------------------------------------------------------------------
# 13-soak-report.ps1 -- pull the long-run CSV off the phone and summarise it
#
# Usage (Windows PowerShell):
#   powershell -ExecutionPolicy Bypass -File scripts\13-soak-report.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\13-soak-report.ps1 -Target root@192.168.31.177
#
# Reads /var/log/mi9-soak.csv (one row per hour, written by mi9-soak.timer),
# writes <repo>\out\soak\mi9-soak.csv locally and prints:
#   * sample count / coverage / gaps (>2 h)
#   * reboots (uptime_s going backwards) with the timestamp
#   * min/avg/max for load, mem, temp, wifi dBm, disk, battery
#   * total dmesg error deltas (spikes flagged)
#   * out\soak\soak.svg  -- temperature + load sparkline, no extra modules
#
# Pure ASCII on purpose (PowerShell 5.1 + Chinese console = mojibake).
# ---------------------------------------------------------------------------
param(
    [string]$Target = "mi9",
    [string]$Remote = "/var/log/mi9-soak.csv",
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
if ($OutDir -eq "") { $OutDir = Join-Path $Root "out\soak" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$local = Join-Path $OutDir "mi9-soak.csv"

Write-Host "== fetch $Target`:$Remote"
& scp -q "${Target}:$Remote" $local
if (-not (Test-Path $local)) { Write-Host "[x] no data yet (wait for mi9-soak.timer, or run: systemctl start mi9-soak)"; exit 1 }

$rows = @(Import-Csv $local)
if ($rows.Count -eq 0) { Write-Host "[x] csv is empty"; exit 1 }

function Num($v) { if ($null -eq $v -or "$v" -eq "") { return $null } ; return [double]$v }
function Stat($name, $values) {
    $v = @($values | Where-Object { $null -ne $_ })
    if ($v.Count -eq 0) { Write-Host ("  {0,-12} (no data)" -f $name); return }
    $m = $v | Measure-Object -Minimum -Maximum -Average
    Write-Host ("  {0,-12} min {1,8:N1}  avg {2,8:N1}  max {3,8:N1}   n={4}" -f $name, $m.Minimum, $m.Average, $m.Maximum, $v.Count)
}

$t0 = [datetimeoffset]::FromUnixTimeSeconds([long]$rows[0].ts).LocalDateTime
$t1 = [datetimeoffset]::FromUnixTimeSeconds([long]$rows[-1].ts).LocalDateTime
$span = $t1 - $t0
Write-Host ("== {0} samples, {1:yyyy-MM-dd HH:mm} -> {2:yyyy-MM-dd HH:mm} ({3:N1} days)" -f $rows.Count, $t0, $t1, $span.TotalDays)

# gaps and reboots
$prev = $null
$gapCount = 0; $rebootCount = 0
foreach ($r in $rows) {
    if ($null -ne $prev) {
        $d = ([long]$r.ts) - ([long]$prev.ts)
        if ($d -gt 7200) {
            $gapCount++
            $when = [datetimeoffset]::FromUnixTimeSeconds([long]$r.ts).LocalDateTime
            Write-Host ("  [gap]    {0:yyyy-MM-dd HH:mm}  {1:N1} h without a sample" -f $when, ($d / 3600))
        }
        if ([long]$r.uptime_s -lt [long]$prev.uptime_s) {
            $rebootCount++
            $when = [datetimeoffset]::FromUnixTimeSeconds([long]$r.ts).LocalDateTime
            Write-Host ("  [reboot] {0:yyyy-MM-dd HH:mm}  uptime reset to {1:N0} s" -f $when, [long]$r.uptime_s)
        }
    }
    $prev = $r
}
Write-Host ("== gaps >2h: {0}   reboots: {1}" -f $gapCount, $rebootCount)

Write-Host "== ranges"
Stat "load1"   ($rows | ForEach-Object { Num $_.load1 })
Stat "mem%"    ($rows | ForEach-Object { Num $_.mem_used_pct })
Stat "temp C"  ($rows | ForEach-Object { Num $_.temp_c })
Stat "cpu MHz" ($rows | ForEach-Object { Num $_.cpu_mhz })
Stat "wlan dBm" ($rows | ForEach-Object { if ($_.wlan_dbm -like "-*") { Num $_.wlan_dbm } })
Stat "tx fail" ($rows | ForEach-Object { Num $_.wlan_tx_fail })
Stat "disk%"   ($rows | ForEach-Object { Num $_.disk_used_pct })
Stat "batt%"   ($rows | ForEach-Object { Num $_.batt_pct })

$errTotal = 0; $errSpikes = 0
foreach ($r in $rows) {
    $d = Num $_.dmesg_err_delta; if ($null -eq $d) { continue }
    $errTotal += $d
    if ($d -ge 20) { $errSpikes++ }
}
Write-Host ("== dmesg error lines (new, summed): {0:N0}   hours with >=20: {1}" -f $errTotal, $errSpikes)

# ---- tiny SVG sparkline (temp + load) -------------------------------------
$svg = Join-Path $OutDir "soak.svg"
$w = 900; $h = 260; $pad = 30
$n = $rows.Count
function Points($prop) {
    $vals = @(); foreach ($r in $rows) { $v = Num $r.$prop; if ($null -ne $v) { $vals += $v } }
    if ($vals.Count -lt 2) { return $null }
    $min = ($vals | Measure-Object -Minimum).Minimum
    $max = ($vals | Measure-Object -Maximum).Maximum
    if ($max -eq $min) { $max = $min + 1 }
    $pts = @(); $i = 0
    foreach ($r in $rows) {
        $v = Num $r.$prop
        if ($null -eq $v) { $i++; continue }
        $x = $pad + ($w - 2 * $pad) * $i / [Math]::Max(1, $n - 1)
        $y = $h - $pad - ($h - 2 * $pad) * ($v - $min) / ($max - $min)
        $pts += ("{0:N1},{1:N1}" -f $x, $y)
        $i++
    }
    return @{ pts = ($pts -join " "); min = $min; max = $max }
}
$pt = Points "temp_c"
$pl = Points "load1"
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("<svg xmlns='http://www.w3.org/2000/svg' width='$w' height='$h' font-family='monospace' font-size='12'>")
[void]$sb.AppendLine("<rect width='$w' height='$h' fill='#101418'/>")
[void]$sb.AppendLine("<text x='$pad' y='18' fill='#9ad' >temp C (blue) / load1 (orange) -- $($rows.Count) hourly samples</text>")
if ($pt) { [void]$sb.AppendLine("<polyline fill='none' stroke='#4aa3ff' stroke-width='2' points='$($pt.pts)'/>") }
if ($pl) { [void]$sb.AppendLine("<polyline fill='none' stroke='#ffa64a' stroke-width='2' points='$($pl.pts)'/>") }
if ($pt) { [void]$sb.AppendLine("<text x='$pad' y='$($h-8)' fill='#4aa3ff'>$([Math]::Round($pt.min))..$([Math]::Round($pt.max)) C</text>") }
if ($pl) { [void]$sb.AppendLine("<text x='$($w-160)' y='$($h-8)' fill='#ffa64a'>load $([Math]::Round($pl.min,1))..$([Math]::Round($pl.max,1))</text>") }
[void]$sb.AppendLine("</svg>")
[IO.File]::WriteAllText($svg, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "csv : $local"
Write-Host "svg : $svg"
