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