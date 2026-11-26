#requires -Version 5.1
<#
.SYNOPSIS
    Fast read-only quarterly workstation storage & hygiene audit (universal, zero hardcoded user paths).
    Auto-discovers fixed volumes, user Downloads/Temp, configured cache env dirs, Everything DB,
    dead PATH / stale *_HOME env vars, and optional archive roots.
#>
param(
    [string[]]$ArchiveRoots = @(),
    [string[]]$ExtraCacheDirs = @()
)

$ErrorActionPreference = 'Continue'

Write-Host "================ WORKSTATION QUARTERLY AUDIT ($(Get-Date -Format 'yyyy-MM-dd HH:mm')) ================" -ForegroundColor Cyan

# 1. All Fixed Disks Free Space & Thresholds
Write-Host "`n[1] Disk Space" -ForegroundColor Yellow
$fixedVols = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size -gt 1GB } | Sort-Object DriveLetter)
foreach ($v in $fixedVols) {
    $sizeGB  = [math]::Round($v.Size / 1GB, 2)
    $freeGB  = [math]::Round($v.SizeRemaining / 1GB, 2)
    $freePct = [math]::Round($v.SizeRemaining / $v.Size * 100, 1)
    $status  = if ($v.DriveLetter -eq 'C' -and $freePct -lt 25) { 'WARN (<25%)' } elseif ($freePct -lt 20) { 'WARN (<20%)' } else { 'OK' }
    Write-Host ("  {0}:  Free {1,6} GB / {2,6} GB  ({3,5}%)  [{4}]" -f $v.DriveLetter, $freeGB, $sizeGB, $freePct, $status)
}

# 2. Memory Pressure Snapshot
$os = Get-CimInstance Win32_OperatingSystem
$ramUsedPct = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 1)
Write-Host ("`n[2] RAM Usage: {0}% used ({1:N1} GB total)" -f $ramUsedPct, ($os.TotalVisibleMemorySize / 1MB)) -ForegroundColor Yellow

# 3. Archive Build-Artifact Hygiene (auto-discover common archive roots if not provided)
Write-Host "`n[3] Archive Build-Artifact Hygiene" -ForegroundColor Yellow
if ($ArchiveRoots.Count -eq 0) {
    foreach ($v in $fixedVols) {
        foreach ($rel in @('Dev\archive','Projects\archive','Archive')) {
            $cand = "$($v.DriveLetter):\$rel"
            if (Test-Path -LiteralPath $cand) { $ArchiveRoots += $cand }
        }
    }
}
if ($ArchiveRoots.Count -eq 0) {
    Write-Host "  No archive roots discovered (pass -ArchiveRoots to check specific directories)." -ForegroundColor Gray
} else {
    foreach ($ar in ($ArchiveRoots | Sort-Object -Unique)) {
        $archArtifacts = @(Get-ChildItem -LiteralPath $ar -Directory -Recurse -Depth 4 -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in @('node_modules','.venv','venv','target') -and $_.FullName -notmatch '(node_modules|\.venv|venv|target).*(\\|/)(node_modules|\.venv|venv|target)' })
        Write-Host ("  $ar -> build artifacts (node_modules/.venv/target): " + $archArtifacts.Count)
        $archArtifacts | Select-Object -First 8 | ForEach-Object { Write-Host "    - $($_.FullName)" -ForegroundColor Gray }
    }
}

# 4. Cache, Downloads, Temp & Everything Index Health
Write-Host "`n[4] Cache, Downloads & Everything Health" -ForegroundColor Yellow
$cacheCheck = New-Object System.Collections.Generic.List[string]
$cacheCheck.Add((Join-Path $env:USERPROFILE "Downloads"))
$cacheCheck.Add((Join-Path $env:LOCALAPPDATA "Temp"))
foreach ($envKey in @('NPM_CONFIG_CACHE','PNPM_STORE_DIR','PIP_CACHE_DIR','UV_CACHE_DIR','PLAYWRIGHT_BROWSERS_PATH','GRADLE_USER_HOME')) {
    $val = [Environment]::GetEnvironmentVariable($envKey, 'User')
    if (-not $val) { $val = [Environment]::GetEnvironmentVariable($envKey, 'Machine') }
    if ($val -and (Test-Path -LiteralPath $val)) {
        $parent = Split-Path -Path $val -Parent
        if ($parent -and $parent -match 'Cache$') { $cacheCheck.Add($parent) } else { $cacheCheck.Add($val) }
    }
}
foreach ($extra in $ExtraCacheDirs) { if (Test-Path -LiteralPath $extra) { $cacheCheck.Add($extra) } }

foreach ($cDir in ($cacheCheck | Sort-Object -Unique)) {
    $gb = [math]::Round(((Get-ChildItem -LiteralPath $cDir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB), 2)
    Write-Host ("  {0,-42} : {1,6} GB" -f $cDir, $gb)
}

# Auto-discover Everything DB & INI
$evRoots = @("$env:APPDATA\Everything","$env:LOCALAPPDATA\Everything")
foreach ($v in $fixedVols) {
    foreach ($sub in @('Program Files','Program Files (x86)')) {
        $p = "$($v.DriveLetter):\$sub"
        if (Test-Path -LiteralPath $p) {
            Get-ChildItem -LiteralPath $p -Directory -Filter "*Everything*" -ErrorAction SilentlyContinue | ForEach-Object { $evRoots += $_.FullName }
        }
    }
}
foreach ($er in ($evRoots | Sort-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $er)) { continue }
    Get-ChildItem -LiteralPath $er -Recurse -Depth 2 -Filter "Everything*.db*" -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host ("  Everything DB {0,-28} : {1,6:N1} MB" -f $_.Name, ($_.Length / 1MB))
    }
    $evIni = Get-ChildItem -LiteralPath $er -Recurse -Depth 2 -Filter "Everything*.ini" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'backup' } | Select-Object -First 1
    if ($evIni) {
        $contentFlag = (Select-String -Path $evIni.FullName -Pattern "^include_file_content=" | Select-Object -First 1).Line
        Write-Host ("  Everything INI flag                        : $contentFlag" + $(if ($contentFlag -eq 'include_file_content=1') { "  [WARN: eats RAM & disk!]" } else { "  [OK]" }))
    }
}

# 5. Dead PATH & Stale *_HOME / *_DIR / *_CACHE Env Vars
Write-Host "`n[5] Dead PATH & Stale Path Env Vars" -ForegroundColor Yellow
foreach ($scope in @('User','Machine')) {
    $dead = @(([Environment]::GetEnvironmentVariable('Path', $scope) -split ';') |
        Where-Object { $_ -and $_.Trim() -ne '' -and -not (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($_))) })
    Write-Host ("  {0,-7} dead PATH entries: {1}" -f $scope, $dead.Count)
    $dead | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkYellow }

    $vars = [Environment]::GetEnvironmentVariables($scope)
    foreach ($k in ($vars.Keys | Sort-Object)) {
        if ($k -match '(?i)(HOME|DIR|CACHE|MODELS)$' -and $k -notin @('HOMEPATH','HOMEDRIVE')) {
            $v = [string]$vars[$k]
            if ($v -match '^[A-Za-z]:\\' -and -not (Test-Path -LiteralPath $v)) {
                Write-Host "    [STALE ENV $scope::$k] -> $v (missing!)" -ForegroundColor Red
            }
        }
    }
}

# 6. Docker Quick Summary (only if already running)
Write-Host "`n[6] Docker Space" -ForegroundColor Yellow
if (@(Get-Process -Name "com.docker.backend" -ErrorAction SilentlyContinue).Count -gt 0) {
    (docker system df 2>&1 | Out-String).TrimEnd() | Write-Host
} else {
    Write-Host "  Docker daemon not running (skipped)." -ForegroundColor Gray
}

# 7. Operation Logs & Rollback Reminder
$logRoot = Join-Path $env:LOCALAPPDATA "windows-storage-ops\logs"
if (Test-Path -LiteralPath $logRoot) {
    $logs = @(Get-ChildItem -LiteralPath $logRoot -File -ErrorAction SilentlyContinue)
    Write-Host ("`n[7] Skill Operation Logs: $($logs.Count) file(s) in $logRoot") -ForegroundColor Cyan
}
Write-Host "`n[8] Backup Reminder: Verify irreplaceable personal documents are backed up off-disk & active repos are git-pushed." -ForegroundColor Cyan
