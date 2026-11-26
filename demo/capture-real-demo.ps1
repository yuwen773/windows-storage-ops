#requires -Version 5.1
<#
.SYNOPSIS
    Runs a real, isolated sandbox demo of windows-storage-ops and captures actual CLI output
    into demo/captured_session.json (with all local user paths/hostnames sanitized).
#>

$ErrorActionPreference = 'Continue'
$repoRoot   = Split-Path -Path $PSScriptRoot -Parent
$scriptsDir = Join-Path $repoRoot "scripts"
$outJson    = Join-Path $PSScriptRoot "captured_session.json"

$sbx    = Join-Path $env:TEMP ("wso_demo_" + [guid]::NewGuid().ToString('N').Substring(0,8))
$logDir = Join-Path $sbx "logs"

function Invoke-Sanitize {
    param([string[]]$Lines)
    $userEsc      = [regex]::Escape($env:USERPROFILE)
    $localAppEsc  = [regex]::Escape($env:LOCALAPPDATA)
    $sbxEsc       = [regex]::Escape($sbx)
    $scriptsEsc   = [regex]::Escape($scriptsDir)
    $domainUser   = [regex]::Escape("$env:USERDOMAIN\$env:USERNAME")
    $userNameEsc  = [regex]::Escape($env:USERNAME)

    $clean = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        $s = [string]$line
        $s = $s -replace $sbxEsc, 'D:\DemoWorkstation'
        $s = $s -replace $scriptsEsc, '.\scripts'
        $s = $s -replace $localAppEsc, '%LOCALAPPDATA%'
        $s = $s -replace $userEsc, 'C:\Users\dev'
        $s = $s -replace $domainUser, 'WORKSTATION\dev'
        if ($env:USERNAME -and $env:USERNAME.Length -ge 3) {
            $s = $s -replace "(?i)(?<=\\|/|\s|:)$userNameEsc(?=\b)", 'dev'
        }
        $clean.Add($s)
    }
    return @($clean)
}

try {
    New-Item -ItemType Directory -Path "$sbx\legacy_project","$sbx\npm_cache_demo" -Force | Out-Null
    Set-Content -Path "$sbx\legacy_project\README.md" -Value "# Legacy Service" -Encoding UTF8
    Set-Content -Path "$sbx\npm_cache_demo\pkg.tgz" -Value "cache-bytes" -Encoding UTF8
    Set-Content -Path "$sbx\my.ini" -Value "datadir=D:\Work\Backend\mysql\data" -Encoding UTF8

    $planFile = Join-Path $sbx "cleanup_plan.json"
    @{
        name = "workstation-cleanup-and-migrate"
        actions = @(
            @{
                type        = "move_dir_atomic"
                source      = "$sbx\legacy_project"
                destination = "$sbx\Dev\archive\legacy_project"
                description = "Atomically archive legacy project"
            },
            @{
                type        = "clean_cache_best_effort"
                path        = "$sbx\npm_cache_demo"
                description = "Clean stale npm cache files"
            },
            @{
                type        = "update_text_replace"
                path        = "$sbx\my.ini"
                find        = "D:\Work\Backend\mysql\data"
                replace     = "D:\Services\mysql\data"
                description = "Redirect MySQL datadir to D:\Services"
            }
        )
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $planFile -Encoding UTF8

    $scenes = @()

    # Scene 1: Pre-flight Probe
    $raw1 = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$scriptsDir\preflight-check.ps1" -Paths "$sbx\legacy_project" 2>&1 | ForEach-Object { "$_" })
    $exit1 = $LASTEXITCODE
    $scenes += [PSCustomObject]@{
        id       = "preflight"
        pill     = "1 Pre-Flight"
        title    = "Stage 1: Pre-Flight Probe (ACL + rstrtmgr.dll Lock Scan)"
        command  = ".\scripts\preflight-check.ps1 -Paths D:\DemoWorkstation\legacy_project"
        exitCode = $exit1
        lines    = @(Invoke-Sanitize -Lines $raw1)
    }

    # Scene 2: Authorization Gate Block
    $raw2 = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$scriptsDir\invoke-storage-plan.ps1" -PlanPath $planFile -Execute -LogDir $logDir 2>&1 | ForEach-Object { "$_" })
    $exit2 = $LASTEXITCODE
    $scenes += [PSCustomObject]@{
        id       = "auth-gate"
        pill     = "2 Auth Gate"
        title    = "Stage 2: Hard Authorization Gate (Blocked Without User Approval)"
        command  = ".\scripts\invoke-storage-plan.ps1 -PlanPath .\cleanup_plan.json -Execute"
        exitCode = $exit2
        lines    = @(Invoke-Sanitize -Lines ($raw2 | Where-Object { $_ -and $_ -notmatch '^\s*\+\s|~|^At ' }))
    }

    # Scene 3: Dry-Run Preview
    $raw3 = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$scriptsDir\invoke-storage-plan.ps1" -PlanPath $planFile -LogDir $logDir 2>&1 | ForEach-Object { "$_" })
    $exit3 = $LASTEXITCODE
    $scenes += [PSCustomObject]@{
        id       = "dry-run"
        pill     = "3 Dry-Run"
        title    = "Stage 3: Default Dry-Run Preview (Zero Modifications)"
        command  = ".\scripts\invoke-storage-plan.ps1 -PlanPath .\cleanup_plan.json"
        exitCode = $exit3
        lines    = @(Invoke-Sanitize -Lines $raw3)
    }

    # Scene 4: Authorized Execution + LIFO Undo Verification
    $raw4 = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$scriptsDir\invoke-storage-plan.ps1" -PlanPath $planFile -Execute -ConfirmedByUser -LogDir $logDir 2>&1 | ForEach-Object { "$_" })
    $exit4 = $LASTEXITCODE
    $undoScript = Get-ChildItem -LiteralPath $logDir -Filter "undo_*.ps1" | Select-Object -First 1
    $undoVerdict = "SKIPPED"
    if ($undoScript) {
        $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $undoScript.FullName 2>&1
        $restoredOk = (Test-Path "$sbx\legacy_project\README.md") -and (-not (Test-Path "$sbx\Dev\archive\legacy_project")) -and ((Get-Content "$sbx\my.ini" -Raw).Trim() -eq 'datadir=D:\Work\Backend\mysql\data')
        $undoVerdict = if ($restoredOk) { "[UNDO VERIFIED] Executed $($undoScript.Name): moved folder & my.ini 100% restored!" } else { "[UNDO FAILED]" }
    }
    $raw4All = @($raw4) + @("", $undoVerdict)
    $scenes += [PSCustomObject]@{
        id       = "execute-undo"
        pill     = "4 Execute & Undo"
        title    = "Stage 4: Authorized Execution + Transcript Log + Auto LIFO Undo"
        command  = ".\scripts\invoke-storage-plan.ps1 -PlanPath .\cleanup_plan.json -Execute -ConfirmedByUser"
        exitCode = $exit4
        lines    = @(Invoke-Sanitize -Lines $raw4All)
    }

    $payload = [PSCustomObject]@{
        generated_at = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
        title        = "Windows Storage Master - Live Verified Replay"
        scenes       = $scenes
    }
    $payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $outJson -Encoding UTF8
    Write-Host "Captured 4 live sanitized scenes -> $outJson" -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $sbx) {
        Remove-Item -LiteralPath $sbx -Recurse -Force -ErrorAction SilentlyContinue
    }
}
