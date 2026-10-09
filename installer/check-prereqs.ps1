<#
.SYNOPSIS
  Check the rpimount prerequisites and report them through the exit code (bit mask):
    1 = WSL not available, 2 = usbipd not installed, 4 = no usable WSL2 distribution.
  Exit code 0 means everything is available.
#>
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$code = 0

# WSL available?
$wslOk = $false
if (Get-Command wsl.exe) {
    $null = & wsl.exe --status 2>&1
    if ($LASTEXITCODE -eq 0) { $wslOk = $true }
}
if (-not $wslOk) { $code += 1 }

# usbipd installed?
$usbipd = (Get-Command usbipd.exe) -or (Test-Path (Join-Path $env:ProgramFiles 'usbipd-win\usbipd.exe'))
if (-not $usbipd) { $code += 2 }

# At least one WSL2 distribution (Docker Desktop's internal ones do not count)
$distro = $false
if ($wslOk) {
    $out = (& wsl.exe -l -v 2>&1 | ForEach-Object { "$_" }) -join "`n"
    foreach ($l in ($out -replace "`0", '') -split "`n") {
        if ($l -match '^\s*\*?\s*(?<name>\S+)\s+.*?(?<ver>\d)\s*$' -and $Matches.ver -eq '2' -and $Matches.name -notmatch '^docker-desktop') {
            $distro = $true
        }
    }
}
if (-not $distro) { $code += 4 }

exit $code
