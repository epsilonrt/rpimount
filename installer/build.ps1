<#
.SYNOPSIS
  Build the rpimount installer locally with Inno Setup 6.
.EXAMPLE
  .\installer\build.ps1 -Version 0.1.0
#>
param([string]$Version = '0.0.0')

$iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 (ISCC.exe) not found.' }

& $iscc (Join-Path $PSScriptRoot 'rpimount.iss') "/DAppVersion=$Version"
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }
Write-Host "Installer: $(Join-Path $PSScriptRoot "Output\rpimount-setup-$Version.exe")"
