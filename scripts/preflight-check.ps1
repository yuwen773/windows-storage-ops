#requires -Version 5.1
<#
.SYNOPSIS
    Read-only pre-flight probe (v2) before any Windows directory move, cleanup, or migration.
    Fixes v1 gaps:
      - Excludes self PID ($PID) to eliminate false-positive powershell.exe lock reports.
      - Uses Windows Restart Manager (rstrtmgr.dll) to detect hidden file-handle lockers (e.g. Typora/IDE).
      - Detects Git worktrees, Python .venv, Docker Compose files, and ALL User/Machine env var references.
#>
param(
    [Parameter(Mandatory = $true)][string[]]$Paths,
    [switch]$SkipHandleScan,
    [int]$HandleScanDepth = 2,
    [int]$HandleScanMaxFiles = 150
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot "safe-fs.ps1")

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "=== PRE-FLIGHT CONTEXT (v2) ===" -ForegroundColor Cyan
Write-Host "IS_ADMIN : $isAdmin"
Write-Host "USER     : $env:USERDOMAIN\$env:USERNAME"

$userEnv  = [Environment]::GetEnvironmentVariables('User')
$machEnv  = [Environment]::GetEnvironmentVariables('Machine')
$selfPid  = $PID
$allProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $selfPid } |
    Select-Object Name, ProcessId, ExecutablePath, CommandLine)

foreach ($p in $Paths) {
    Write-Host "`n--- TARGET: $p ---" -ForegroundColor Yellow
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host "  STATUS: NOT FOUND" -ForegroundColor Red
        continue
    }

    $item = Get-Item -LiteralPath $p -Force
    $acl  = Get-Acl -LiteralPath $p -ErrorAction SilentlyContinue
    Write-Host ("  TYPE       : " + $(if ($item.PSIsContainer) { 'Directory' } else { 'File' }))
    Write-Host ("  ATTRIBUTES : " + $item.Attributes)
    if ($acl) {
        Write-Host ("  OWNER      : " + $acl.Owner)
        Write-Host ("  ACL_LOCKED : " + $acl.AreAccessRulesProtected + $(if ($acl.AreAccessRulesProtected -and -not $isAdmin) { "  [WARNING: likely needs Admin]" } else { "" }))
    }

    # 1. Process command-line / executable matches (excluding self PID)
    $escaped = [regex]::Escape($p.TrimEnd('\'))
    $escapedFwd = [regex]::Escape(($p.TrimEnd('\') -replace '\\','/'))
    $hits = @($allProcs | Where-Object {
        ($_.ExecutablePath -and $_.ExecutablePath -match "(?i)$escaped") -or
        ($_.CommandLine -and ($_.CommandLine -match "(?i)$escaped" -or $_.CommandLine -match "(?i)$escapedFwd"))
    })
    if ($hits.Count -gt 0) {
        Write-Host ("  PROC_REFS  : " + $hits.Count + " running process(es)") -ForegroundColor Red
        $hits | Select-Object -First 8 | ForEach-Object {
            Write-Host ("    - $($_.Name) (PID $($_.ProcessId)): $($_.ExecutablePath)")
        }
    } else {
        Write-Host "  PROC_REFS  : 0" -ForegroundColor Green
    }

    # 2. Real OS file-handle lockers via Restart Manager (rstrtmgr.dll)
    if (-not $SkipHandleScan) {
        $sampleFiles = if ($item.PSIsContainer) {
            @(Get-ChildItem -LiteralPath $p -Recurse -Depth $HandleScanDepth -File -Force -ErrorAction SilentlyContinue |
                Select-Object -First $HandleScanMaxFiles -ExpandProperty FullName)
        } else {
            @($item.FullName)
        }
        $lockers = @(Find-FileLockers -FilePaths $sampleFiles)
        if ($lockers.Count -gt 0) {
            Write-Host ("  HANDLE_LOCK: " + ($lockers -join ', ')) -ForegroundColor Red
        } else {
            Write-Host ("  HANDLE_LOCK: 0 (checked $($sampleFiles.Count) files up to depth $HandleScanDepth)") -ForegroundColor Green
        }
    }

    # 3. Cross-tool User & Machine env var / PATH references (both \ and / forms)
    $envHits = @()
    foreach ($pair in @(@{S='User';E=$userEnv}, @{S='Machine';E=$machEnv})) {
        foreach ($k in $pair.E.Keys) {
            $val = [string]$pair.E[$k]
            if ($val -match "(?i)$escaped" -or $val -match "(?i)$escapedFwd") {
                $envHits += "$($pair.S)::$k"
            }
        }
    }
    if ($envHits.Count -gt 0) {
        Write-Host ("  ENV_REFS   : " + ($envHits -join ', ')) -ForegroundColor Magenta
    } else {
        Write-Host "  ENV_REFS   : None" -ForegroundColor Green
    }

    # 4. Structural coupling markers (Git Worktrees / Python .venv / Docker Compose / Sibling count)
    if ($item.PSIsContainer) {
        $children = @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue)
        $hasWt = @(Get-ChildItem -LiteralPath $p -Directory -Recurse -Depth 2 -Filter "worktrees" -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\\.git\\worktrees$' }).Count
        $hasVenv = @(Get-ChildItem -LiteralPath $p -File -Recurse -Depth 3 -Filter "pyvenv.cfg" -Force -ErrorAction SilentlyContinue).Count
        $hasCompose = @(Get-ChildItem -LiteralPath $p -File -Recurse -Depth 2 -Filter "*compose*.y*ml" -Force -ErrorAction SilentlyContinue).Count
        Write-Host ("  TOP_ITEMS  : " + $children.Count)
        Write-Host ("  COUPLING   : GitWorktreeRepos=$hasWt | PythonVenvs=$hasVenv | DockerCompose=$hasCompose") -ForegroundColor Cyan
    }
}
