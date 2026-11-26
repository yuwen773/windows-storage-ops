#requires -Version 5.1
<#
.SYNOPSIS
    Fast, strictly READ-ONLY deep workstation audit collector (universal, zero hardcoded user paths).
    Auto-discovers all fixed NTFS volumes, user profile directories, dev caches, DB services,
    Everything config flags, and Git secondary worktrees (with dirty file counts).
    Never modifies files, never starts stopped services, never reads secrets or DB business rows.
#>
param(
    [string[]]$Drives = @(),
    [string[]]$CodeRoots = @(),
    [double]$MinReportGB = 0.3
)

$ErrorActionPreference = 'Continue'

function Get-DirStatsFast {
    <# Multi-threaded native NTFS size + file count via robocopy /L /XJ (supports en-US & zh-CN). #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $out = @(robocopy $Path "NULL" /L /E /BYTES /NFL /NDL /NJH /XJ /R:0 /W:0 /MT:8 2>$null)
    $files = 0L; $bytes = 0L
    foreach ($line in $out) {
        if ($line -match '^\s*(?:Files|文件)\s*:\s*(\d+)') { $files = [int64]$Matches[1] }
        elseif ($line -match '^\s*(?:Bytes|字节)\s*:\s*(\d+)') { $bytes = [int64]$Matches[1] }
    }
    return [PSCustomObject]@{
        Path  = $Path
        Files = $files
        GB    = [math]::Round($bytes / 1GB, 2)
        Bytes = $bytes
    }
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Auto-discover fixed local drives if not explicitly supplied
if ($Drives.Count -eq 0) {
    $Drives = @(Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size -gt 1GB } |
        Sort-Object DriveLetter |
        ForEach-Object { [string]$_.DriveLetter })
}

# Auto-discover candidate code roots across fixed drives + user profile if not supplied
if ($CodeRoots.Count -eq 0) {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($dl in $Drives) {
        foreach ($rel in @('Dev\active','Dev\lab','Dev\archive','Dev','Work\code','Work','code','Projects','repos','src')) {
            $p = "${dl}:\$rel"
            if (Test-Path -LiteralPath $p) { $candidates.Add($p) }
        }
    }
    foreach ($uRel in @('projects','Projects','source\repos','code','dev')) {
        $p = Join-Path $env:USERPROFILE $uRel
        if (Test-Path -LiteralPath $p) { $candidates.Add($p) }
    }
    $CodeRoots = @($candidates | Sort-Object -Unique)
}

Write-Host "================ FAST READ-ONLY DEEP AUDIT ($(Get-Date -Format 'yyyy-MM-dd HH:mm')) ================" -ForegroundColor Cyan

# --- PHASE 0: Baseline ---
Write-Host "`n[Phase 0] System, Hardware, RAM & Disk Baseline" -ForegroundColor Yellow
$os = Get-CimInstance Win32_OperatingSystem
$ramTotalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
$ramFreeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
$ramUsedPct = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 1)
Write-Host "  OS         : $($os.Caption) | Build $($os.BuildNumber) | Installed $($os.InstallDate.ToString('yyyy-MM-dd'))"
Write-Host "  Elevation  : IS_ADMIN=$isAdmin"
Write-Host "  RAM        : $ramUsedPct% used ($ramFreeGB GB free / $ramTotalGB GB total)"

$pf = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
foreach ($p in $pf) {
    Write-Host ("  PageFile   : $($p.Name) | Alloc=$([math]::Round($p.AllocatedBaseSize/1024,2))GB | Current=$([math]::Round($p.CurrentUsage/1024,2))GB | Peak=$([math]::Round($p.PeakUsage/1024,2))GB")
}

$disks = @(Get-Disk -ErrorAction SilentlyContinue)
Write-Host ("  PhysDisks  : " + $disks.Count)
foreach ($dk in $disks) {
    $parts = @(Get-Partition -DiskNumber $dk.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object { "$($_.DriveLetter):" })
    Write-Host ("    - Disk $($dk.Number): $($dk.FriendlyName) | $([math]::Round($dk.Size/1GB,2)) GB | Health=$($dk.HealthStatus) | Partitions=$($parts -join ', ')")
}
if ($isAdmin) {
    Get-PhysicalDisk | ForEach-Object {
        $rc = $_ | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        if ($rc) {
            Write-Host ("    SMART ($($_.FriendlyName)): Temp=$($rc.Temperature)C | Wear=$($rc.Wear)% | ReadErr=$($rc.ReadErrorsUncorrected) | WriteErr=$($rc.WriteErrorsUncorrected)")
        }
    }
} else {
    Write-Host "    SMART Counters: Unverified (requires Administrator privileges)" -ForegroundColor DarkYellow
}

Write-Host "  Volumes:"
foreach ($dl in $Drives) {
    $v = Get-Volume -DriveLetter $dl -ErrorAction SilentlyContinue
    if ($v) {
        $sz = [math]::Round($v.Size/1GB, 2); $fr = [math]::Round($v.SizeRemaining/1GB, 2)
        $pct = [math]::Round($v.SizeRemaining/$v.Size*100, 1)
        Write-Host ("    - ${dl}: Free $fr GB / $sz GB ($pct% free)")
    }
}

Write-Host "  Top 8 RAM Processes:"
(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 8 Name, Id, @{N='RAM_MB';E={[math]::Round($_.WorkingSet64/1MB,0)}} | Format-Table -AutoSize | Out-String).TrimEnd() | Write-Host

# --- PHASE 1: Level-1 Drive Distribution ---
foreach ($dl in $Drives) {
    Write-Host "`n[Phase 1] Top Level-1 Directories on ${dl}:\ (>=$MinReportGB GB)" -ForegroundColor Yellow
    $rows = @()
    foreach ($dir in @(Get-ChildItem "${dl}:\" -Directory -Force -ErrorAction SilentlyContinue | Where-Object { ($_.Attributes -notmatch 'ReparsePoint') -and ($_.Name -notin @('System Volume Information','$Recycle.Bin','$RECYCLE.BIN')) })) {
        $st = Get-DirStatsFast -Path $dir.FullName
        if ($st -and $st.GB -ge $MinReportGB) {
            $acl = Get-Acl -LiteralPath $dir.FullName -ErrorAction SilentlyContinue
            $rows += [PSCustomObject]@{ Name = $dir.Name; GB = $st.GB; Files = $st.Files; ACLProtected = $(if($acl){$acl.AreAccessRulesProtected}else{'?'}) }
        }
    }
    (($rows | Sort-Object GB -Descending | Format-Table -AutoSize | Out-String).TrimEnd()) | Write-Host
}

# --- PHASE 2: User Profile & AppData ---
Write-Host "`n[Phase 2] User Profile & AppData Top Consumers (>=$MinReportGB GB)" -ForegroundColor Yellow
foreach ($baseDir in @($env:USERPROFILE, "$env:USERPROFILE\AppData\Local", "$env:USERPROFILE\AppData\Roaming")) {
    Write-Host "  -- $baseDir --" -ForegroundColor Cyan
    $rows = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $baseDir -Directory -Force -ErrorAction SilentlyContinue | Where-Object { ($_.Attributes -notmatch 'ReparsePoint') -and ($_.FullName -ne "$env:USERPROFILE\AppData") })) {
        $st = Get-DirStatsFast -Path $d.FullName
        if ($st -and $st.GB -ge $MinReportGB) {
            $rows += [PSCustomObject]@{ Name = $d.Name; GB = $st.GB; Files = $st.Files; LastWrite = $d.LastWriteTime.ToString('yyyy-MM-dd') }
        }
    }
    (($rows | Sort-Object GB -Descending | Select-Object -First 15 | Format-Table -AutoSize | Out-String).TrimEnd()) | Write-Host
}

# --- PHASE 3: Config Metadata Allowlist & Env Var Audit ---
Write-Host "`n[Phase 3] Config Metadata Allowlist & Env Var Health" -ForegroundColor Yellow
foreach ($scope in @('User','Machine')) {
    $dead = @(([Environment]::GetEnvironmentVariable('Path', $scope) -split ';') |
        Where-Object { $_ -and $_.Trim() -ne '' -and -not (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($_))) })
    Write-Host ("  $scope dead PATH entries: " + $dead.Count)
    foreach ($dp in $dead) { Write-Host "    - $dp" -ForegroundColor DarkYellow }

    $vars = [Environment]::GetEnvironmentVariables($scope)
    foreach ($k in ($vars.Keys | Sort-Object)) {
        if ($k -match '(?i)(HOME|DIR|CACHE|MODELS|PATH)$' -and $k -notin @('Path','HOMEPATH','HOMEDRIVE','PSModulePath')) {
            $v = [string]$vars[$k]
            if ($v -match '^[A-Za-z]:\\') {
                $exists = Test-Path -LiteralPath $v
                $tag = if ($exists) { 'OK' } else { 'MISSING!' }
                Write-Host ("    [$scope::$k] = $v  [$tag]") -ForegroundColor $(if($exists){'Gray'}else{'Red'})
            }
        }
    }
}

# Auto-discover Everything.ini across standard locations
$evSearchRoots = @()
foreach ($dl in $Drives) {
    foreach ($sub in @('Program Files','Program Files (x86)')) {
        $p = "${dl}:\$sub"
        if (Test-Path -LiteralPath $p) { $evSearchRoots += $p }
    }
}
$evSearchRoots += "$env:APPDATA\Everything"
$evIni = $evSearchRoots | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object {
    Get-ChildItem -LiteralPath $_ -Recurse -Depth 2 -Filter "Everything*.ini" -ErrorAction SilentlyContinue
} | Where-Object { $_.Name -notmatch 'backup' } | Select-Object -First 1
if ($evIni) {
    $flag = (Select-String -Path $evIni.FullName -Pattern "^include_file_content=" -ErrorAction SilentlyContinue | Select-Object -First 1).Line
    Write-Host ("  Everything INI ($($evIni.FullName)): $flag")
}

# --- PHASE 4: Docker, WSL2 & Database Services (Read-Only, never auto-start!) ---
Write-Host "`n[Phase 4] WSL2, Docker & Database Services" -ForegroundColor Yellow
$wslOut = @(wsl --list --verbose 2>$null)
if ($wslOut.Count -gt 0) {
    Write-Host "  WSL2:"
    ($wslOut | Out-String).TrimEnd() | Write-Host
}
$dockerRunning = @(Get-Process -Name "com.docker.backend" -ErrorAction SilentlyContinue).Count -gt 0
if ($dockerRunning) {
    Write-Host "  Docker (running):"
    (docker system df 2>&1 | Out-String).TrimEnd() | Write-Host
} else {
    Write-Host "  Docker: Stopped (not auto-started per read-only policy)" -ForegroundColor Gray
}
$dbSvcs = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)mysql|mariadb|postgres|redis|mongo' })
Write-Host ("  Database Windows Services: " + $dbSvcs.Count)
foreach ($s in $dbSvcs) {
    Write-Host "    - $($s.Name) [$($s.State)/$($s.StartMode)]: $($s.PathName)"
    if ($s.PathName -match '--defaults-file=([^\s]+)') {
        $iniPath = $Matches[1].Trim('"')
        if (Test-Path -LiteralPath $iniPath) {
            $dd = (Select-String -Path $iniPath -Pattern '^\s*datadir\s*=\s*(.+)$' | Select-Object -First 1)
            if ($dd) {
                $dataPath = $dd.Matches[0].Groups[1].Value.Trim().Trim('"')
                if (Test-Path -LiteralPath $dataPath) {
                    $schemas = @(Get-ChildItem -LiteralPath $dataPath -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('mysql','performance_schema','sys','#innodb_temp') })
                    Write-Host ("      DataDir schemas (names only, no row read): " + $schemas.Count)
                }
            }
        }
    }
}

# --- PHASE 5: Git Worktrees Dirty-State Audit ---
Write-Host "`n[Phase 5] Git Secondary Worktrees & Dirty Status" -ForegroundColor Yellow
$seenRepos = @{}
$wtFound = 0
foreach ($root in $CodeRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($repo in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        $key = $repo.FullName.ToLower()
        if ($seenRepos.ContainsKey($key)) { continue }
        $seenRepos[$key] = $true
        if (Test-Path -LiteralPath (Join-Path $repo.FullName ".git\worktrees")) {
            $lines = @(git -C $repo.FullName worktree list --porcelain 2>$null)
            $wtPaths = @($lines | Where-Object { $_ -match '^worktree (.+)$' } | ForEach-Object { $Matches[1] })
            for ($i = 1; $i -lt $wtPaths.Count; $i++) {
                $wt = $wtPaths[$i]
                $wtFound++
                $dirty = @(git -C $wt status --porcelain 2>$null).Count
                $branch = git -C $wt rev-parse --abbrev-ref HEAD 2>$null
                Write-Host ("  [$($repo.Name)] $wt | Branch=$branch | DirtyFiles=$dirty") -ForegroundColor $(if($dirty -gt 0){'Yellow'}else{'Green'})
            }
        }
    }
}
if ($wtFound -eq 0) { Write-Host "  No secondary worktrees found under discovered CodeRoots." }

$sw.Stop()
Write-Host ("`n================ AUDIT COMPLETE in {0:N1}s (STRICT READ-ONLY: ZERO CHANGES MADE) ================" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Cyan
