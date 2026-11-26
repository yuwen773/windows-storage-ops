#requires -Version 5.1
<#
.SYNOPSIS
    Generates a clean, zero-nested-quote UAC .cmd launcher for any PowerShell script or plan execution.
    Eliminates flash-close, quote-escaping bugs, and QuickEdit pauses.
#>
param(
    [Parameter(Mandatory = $true)][string]$TargetScript,
    [string[]]$ScriptArguments = @(),
    [Parameter(Mandatory = $true)][string]$OutputCmdPath,
    [string]$WindowTitle = "Windows Storage Ops (Administrator)"
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $TargetScript)) {
    throw "Target script not found: $TargetScript"
}

$outDir = Split-Path -Path $OutputCmdPath -Parent
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# Build safe wrapper .ps1 next to .cmd so Start-Process -Verb RunAs passes ONLY -File (zero nested quote bugs!)
$wrapperPs1 = [System.IO.Path]::ChangeExtension($OutputCmdPath, '.runner.ps1')
$argLine = ($ScriptArguments | ForEach-Object {
    if ($_ -match '^-') { $_ } else { "`"$_`"" }
}) -join ' '

$wrapperContent = @"
#requires -Version 5.1
. "$PSScriptRoot\safe-fs.ps1"
Disable-ConsoleQuickEdit
& "$TargetScript" $argLine
"@
Set-Content -LiteralPath $wrapperPs1 -Value $wrapperContent -Encoding UTF8

$cmdContent = @"
@echo off
title $WindowTitle
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','$wrapperPs1'"
"@
Set-Content -LiteralPath $OutputCmdPath -Value $cmdContent -Encoding ASCII

Write-Host "Created UAC launcher: $OutputCmdPath" -ForegroundColor Green
Write-Host "Wrapper script      : $wrapperPs1" -ForegroundColor Cyan
