#requires -Version 5.1
<#
.SYNOPSIS
    Plan-driven, logged, authorization-gated Windows cleanup & migration executor.
    - Defaults to Dry-Run preview (zero modifications).
    - Requires BOTH -Execute and -ConfirmedByUser to mutate disk/env state.
    - Records full Start-Transcript log + JSON summary + auto-generated undo_<ts>.ps1 rollback script.
    - Uses safe-fs.ps1 atomic primitives and rstrtmgr.dll lock diagnostics on any access failure.
#>
param(
    [Parameter(Mandatory = $true)][string]$PlanPath,
    [switch]$Execute,
    [switch]$ConfirmedByUser,
    [string]$LogDir = (Join-Path $env:LOCALAPPDATA "windows-storage-ops\logs")
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot "safe-fs.ps1")
Disable-ConsoleQuickEdit

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Plan JSON file not found: $PlanPath"
}

$plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
$actions = @($plan.actions)
if ($actions.Count -eq 0) {
    Write-Host "Plan contains 0 actions. Nothing to do." -ForegroundColor Yellow
    exit 0
}

# Hard Authorization Gate
$isRealRun = ($Execute.IsPresent -and $ConfirmedByUser.IsPresent)
if ($Execute.IsPresent -and -not $ConfirmedByUser.IsPresent) {
    Write-Error "AUTHORIZATION GATE BLOCKED: -Execute requires explicit -ConfirmedByUser after user approval via AskUserQuestion/confirmation."
    exit 2
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

$logFile    = Join-Path $LogDir "run_${ts}.log"
$resultFile = Join-Path $LogDir "result_${ts}.json"
$undoFile   = Join-Path $LogDir "undo_${ts}.ps1"

$modeLabel = if ($isRealRun) { "EXECUTE (AUTHORIZED)" } else { "DRY-RUN PREVIEW (NO CHANGES)" }
Start-Transcript -Path $logFile -Force | Out-Null

$undoLines = New-Object System.Collections.Generic.List[string]
$undoLines.Add("#requires -Version 5.1")
$undoLines.Add("# Auto-generated rollback script for plan '$($plan.name)' ($ts)")
$undoLines.Add("# NOTE: Only reversible actions (moves, env vars, PATH, config edits) are included; permanent deletions cannot be undone.")
$undoLines.Add("`$ErrorActionPreference = 'Continue'")
$undoLines.Add(". `"$PSScriptRoot\safe-fs.ps1`"")

function Get-FixedDriveFreeMap {
    $map = [ordered]@{}
    Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size -gt 1GB } |
        Sort-Object DriveLetter | ForEach-Object {
            $map[[string]$_.DriveLetter] = [math]::Round($_.SizeRemaining / 1GB, 3)
        }
    return $map
}

try {
    Write-Host "================ STORAGE PLAN EXECUTOR : $modeLabel ================" -ForegroundColor Cyan
    Write-Host "Plan     : $($plan.name) ($PlanPath)"
    Write-Host "Actions  : $($actions.Count)"
    Write-Host "IS_ADMIN : $isAdmin"
    Write-Host "Log File : $logFile"

    $beforeFree = Get-FixedDriveFreeMap
    $results = @()
    $idx = 0

    foreach ($act in $actions) {
        $idx++
        $type = [string]$act.type
        $desc = if ($act.description) { [string]$act.description } else { $type }
        Write-Host "`n[$idx/$($actions.Count)] [$type] $desc" -ForegroundColor Yellow

        if (-not $isRealRun) {
            # Dry-run validation
            $previewDetail = ""
            switch ($type) {
                'move_dir_atomic'       { $previewDetail = "$($act.source) -> $($act.destination) (SrcExists=$(Test-Path -LiteralPath $act.source), DstExists=$(Test-Path -LiteralPath $act.destination))" }
                'move_dir_cross_volume' { $previewDetail = "$($act.source) -> $($act.destination) (SrcExists=$(Test-Path -LiteralPath $act.source))" }
                'remove_longpath_dir'   { $previewDetail = "DELETE DIR $($act.path) (Exists=$(Test-Path -LiteralPath $act.path))" }
                'clean_cache_best_effort' { $previewDetail = "CLEAN CACHE $($act.path) (Exists=$(Test-Path -LiteralPath $act.path))" }
                'remove_file'           { $previewDetail = "DELETE FILE $($act.path) (Exists=$(Test-Path -LiteralPath $act.path))" }
                'set_env_var'           { $previewDetail = "ENV [$($act.scope)] $($act.name) = '$($act.value)'" }
                'update_path_replace'   { $previewDetail = "PATH [$($act.scope)] replace '$($act.oldPattern)' -> '$($act.newValue)'" }
                'update_text_replace'   { $previewDetail = "CONFIG $($act.path): '$($act.find)' -> '$($act.replace)' (Exists=$(Test-Path -LiteralPath $act.path))" }
                'repair_git_worktrees'  { $previewDetail = "GIT REPAIR $($act.repo) ($((@($act.worktrees)).Count) worktree(s))" }
                default                 { $previewDetail = "UNKNOWN action type: $type" }
            }
            Write-Host "  [DRY-RUN] $previewDetail" -ForegroundColor Gray
            $results += [PSCustomObject]@{ Index = $idx; Type = $type; Status = 'DRY_RUN'; Detail = $previewDetail }
            continue
        }

        # Real Authorized Execution
        $status = 'OK'; $detail = ''
        try {
            switch ($type) {
                'move_dir_atomic' {
                    $parent = Split-Path -Path $act.destination -Parent
                    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                    $r = Move-DirAtomic -Source $act.source -Destination $act.destination
                    if ($r.Ok) {
                        $detail = $r.Message
                        $undoLines.Add("Move-DirAtomic -Source `"$($act.destination)`" -Destination `"$($act.source)`"")
                    } else {
                        $status = 'FAILED'
                        $sampleFiles = @(Get-ChildItem -LiteralPath $act.source -Recurse -Depth 2 -File -Force -ErrorAction SilentlyContinue | Select-Object -First 80 -ExpandProperty FullName)
                        $lockers = @(Find-FileLockers -FilePaths $sampleFiles)
                        $lockHint = if ($lockers.Count -gt 0) { " | Lockers: $($lockers -join ', ')" } else { "" }
                        $detail = "$($r.Status): $($r.Message)$lockHint"
                    }
                }
                'move_dir_cross_volume' {
                    New-Item -ItemType Directory -Path $act.destination -Force | Out-Null
                    robocopy $act.source $act.destination /E /MOVE /R:1 /W:1 /MT:8 /NFL /NDL /NJH /NJS /NP | Out-Null
                    $rc = $LASTEXITCODE
                    if ($rc -lt 8) {
                        $detail = "robocopy exit=$rc ($($act.source) -> $($act.destination))"
                        $undoLines.Add("robocopy `"$($act.destination)`" `"$($act.source)`" /E /MOVE /R:1 /W:1 /MT:8 /NFL /NDL /NJH /NJS /NP")
                    } else {
                        $status = 'FAILED'; $detail = "robocopy error exit=$rc"
                    }
                }
                'remove_longpath_dir' {
                    $ok = Remove-LongPathDir -Path $act.path
                    if ($ok) { $detail = "Removed $($act.path)" } else { $status = 'FAILED'; $detail = "Still exists: $($act.path)" }
                }
                'clean_cache_best_effort' {
                    $r = Remove-FilesBestEffort -Directory $act.path
                    $detail = "Deleted=$($r.Deleted), LockedSkipped=$($r.Locked)"
                }
                'remove_file' {
                    if (Test-Path -LiteralPath $act.path) {
                        Remove-Item -LiteralPath $act.path -Force -ErrorAction Stop
                        $detail = "Deleted file $($act.path)"
                    } else {
                        $status = 'SKIPPED'; $detail = "Already absent: $($act.path)"
                    }
                }
                'set_env_var' {
                    $scope = if ($act.scope) { [string]$act.scope } else { 'User' }
                    if ($scope -eq 'Machine' -and -not $isAdmin) { throw "Machine env var requires Administrator privileges." }
                    $prev = [Environment]::GetEnvironmentVariable($act.name, $scope)
                    $r = Set-EnvVarIdempotent -Name $act.name -Value $act.value -Scope $scope
                    $detail = "Scope=$scope Changed=$($r.Changed) Value='$($act.value)'"
                    if ($r.Changed) {
                        $prevEsc = if ($null -eq $prev) { '$null' } else { "`"$prev`"" }
                        $undoLines.Add("Set-EnvVarIdempotent -Name `"$($act.name)`" -Value $prevEsc -Scope `"$scope`"")
                    }
                }
                'update_path_replace' {
                    $scope = if ($act.scope) { [string]$act.scope } else { 'User' }
                    if ($scope -eq 'Machine' -and -not $isAdmin) { throw "Machine PATH update requires Administrator privileges." }
                    $raw = [Environment]::GetEnvironmentVariable('Path', $scope)
                    $bakFile = Join-Path $LogDir "path_backup_${scope}_${ts}.txt"
                    $raw | Set-Content -LiteralPath $bakFile -Encoding UTF8
                    $parts = @($raw -split ';' | Where-Object { $_ -and $_.Trim() -ne '' })
                    $newParts = New-Object System.Collections.Generic.List[string]
                    $seen = @{}
                    foreach ($p in $parts) {
                        $entry = $p
                        if ($act.oldPattern -and $entry -match $act.oldPattern) {
                            if ($act.newValue) { $entry = [string]$act.newValue } else { continue }
                        }
                        $norm = $entry.Trim().TrimEnd('\').ToLower()
                        if (-not $seen.ContainsKey($norm)) { $newParts.Add($entry); $seen[$norm] = $true }
                    }
                    if ($act.newValue) {
                        $normNew = ([string]$act.newValue).Trim().TrimEnd('\').ToLower()
                        if (-not $seen.ContainsKey($normNew)) { $newParts.Add([string]$act.newValue) }
                    }
                    $joined = $newParts -join ';'
                    if ($joined -ne $raw) {
                        [Environment]::SetEnvironmentVariable('Path', $joined, $scope)
                        Sync-ProcessEnv
                        $undoLines.Add("[Environment]::SetEnvironmentVariable('Path', (Get-Content -Raw `"$bakFile`"), `"$scope`")")
                        $detail = "Updated $scope PATH (backup: $bakFile)"
                    } else {
                        $detail = "No change needed in $scope PATH"
                    }
                }
                'update_text_replace' {
                    if (-not (Test-Path -LiteralPath $act.path)) { throw "Config file not found: $($act.path)" }
                    $bak = "$($act.path).bak_$ts"
                    Copy-Item -LiteralPath $act.path -Destination $bak -Force
                    $raw = Get-Content -LiteralPath $act.path -Raw -Encoding UTF8
                    $updated = $raw.Replace([string]$act.find, [string]$act.replace)
                    Set-Content -LiteralPath $act.path -Value $updated -NoNewline -Encoding UTF8
                    $undoLines.Add("Copy-Item -LiteralPath `"$bak`" -Destination `"$($act.path)`" -Force")
                    $detail = "Updated $($act.path) (backup: $bak)"
                }
                'repair_git_worktrees' {
                    $r = Repair-GitWorktreesSafe -RepoPath $act.repo -WorktreePaths @($act.worktrees) -OldPrefixPattern ([string]$act.oldPrefixPattern)
                    if ($r.StaleOldCount -eq 0) {
                        $detail = "Repaired $($r.TotalCount) worktree(s), StaleOldCount=0"
                    } else {
                        $status = 'WARN'; $detail = "StaleOldCount=$($r.StaleOldCount)"
                    }
                }
                default {
                    $status = 'FAILED'; $detail = "Unsupported action type: $type"
                }
            }
        } catch {
            $status = 'FAILED'
            $detail = $_.Exception.Message
        }

        $color = if ($status -eq 'OK') { 'Green' } elseif ($status -eq 'SKIPPED' -or $status -eq 'WARN') { 'Yellow' } else { 'Red' }
        Write-Host "  [$status] $detail" -ForegroundColor $color
        $results += [PSCustomObject]@{ Index = $idx; Type = $type; Status = $status; Detail = $detail }
    }

    $afterFree = Get-FixedDriveFreeMap
    $deltas = [ordered]@{}
    foreach ($dl in $beforeFree.Keys) {
        if ($afterFree.Contains($dl)) {
            $deltas[$dl] = [math]::Round($afterFree[$dl] - $beforeFree[$dl], 3)
        }
    }

    if ($isRealRun -and $undoLines.Count -gt 5) {
        # Keep 5-line header, emit rollback commands in reverse (LIFO) order
        $header = @($undoLines[0..4])
        $body   = @($undoLines[5..($undoLines.Count - 1)])
        [array]::Reverse($body)
        ($header + $body) | Set-Content -LiteralPath $undoFile -Encoding UTF8
        Write-Host "`nRollback script generated: $undoFile" -ForegroundColor Cyan
    }

    $summary = [PSCustomObject]@{
        Timestamp   = $ts
        Mode        = $modeLabel
        PlanName    = $plan.name
        LogFile     = $logFile
        UndoScript  = $(if ($isRealRun -and (Test-Path -LiteralPath $undoFile)) { $undoFile } else { $null })
        BeforeFreeGB = $beforeFree
        AfterFreeGB  = $afterFree
        DeltaGB      = $deltas
        Results      = $results
    }
    $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resultFile -Encoding UTF8

    Write-Host "`n================ SUMMARY ================" -ForegroundColor Cyan
    foreach ($dl in $deltas.Keys) {
        Write-Host ("  Drive ${dl}:  $($beforeFree[$dl]) GB -> $($afterFree[$dl]) GB  (Delta: $($deltas[$dl]) GB)")
    }
    Write-Host "  JSON Report : $resultFile"
    Write-Host "  Full Log    : $logFile"
    Write-Host "`n=== ALL DONE! You can close this window now. ===" -ForegroundColor Green
} finally {
    Stop-Transcript | Out-Null
}
