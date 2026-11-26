#requires -Version 5.1
<#
.SYNOPSIS
    Self-verification suite for windows-storage-ops skill repository.
    Checks:
      1. Zero leaked private paths/usernames/secrets across all files.
      2. Clean PowerShell 5.1 AST syntax parse on every scripts/*.ps1.
      3. Valid JSON on .claude-plugin/marketplace.json and tests/test-prompts.json.
      4. End-to-end sandbox test of invoke-storage-plan.ps1 (Auth block -> DryRun -> Execute -> LIFO Undo).
#>

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Path $PSScriptRoot -Parent
$failures = 0

Write-Host "================ WINDOWS-STORAGE-OPS VERIFY SUITE ================" -ForegroundColor Cyan

# 1. Privacy & Hardcoded Path Leak Scan
Write-Host "`n[1/4] Privacy & Hardcoded Path Leak Scan..." -ForegroundColor Yellow
$forbiddenPattern = 'C:\\Users\\yuwen|SAIL\\|mysql-5\.7\.19_archived|develop-worktree-t3|长沙理工大学|兰州理工大学|eye-diagnosis|VisionSpace|ai-interview|sk-[A-Za-z0-9]{16,}'
$leakHits = @()
Get-ChildItem -LiteralPath $skillRoot -Recurse -File | Where-Object {
    $_.Name -ne 'verify-skill.ps1' -and
    $_.FullName -notmatch '\\\.git\\' -and
    $_.Extension -notin @('.gif','.png','.jpg','.ico')
} | ForEach-Object {
    $m = Select-String -Path $_.FullName -Pattern $forbiddenPattern -ErrorAction SilentlyContinue
    if ($m) { $leakHits += $m }
}
if ($leakHits.Count -eq 0) {
    Write-Host "  [PASS] 0 private path / secret leaks found." -ForegroundColor Green
} else {
    $failures++
    Write-Host "  [FAIL] Found $($leakHits.Count) leak(s):" -ForegroundColor Red
    $leakHits | ForEach-Object { Write-Host "    $($_.Path):$($_.LineNumber): $($_.Line.Trim())" -ForegroundColor Red }
}

# 2. PowerShell 5.1 AST Syntax Validation
Write-Host "`n[2/4] PowerShell 5.1 AST Syntax Validation..." -ForegroundColor Yellow
$psFiles = @(Get-ChildItem -LiteralPath (Join-Path $skillRoot "scripts") -Filter "*.ps1")
$parseErrs = 0
foreach ($f in $psFiles) {
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    if ($errs.Count -gt 0) {
        $parseErrs += $errs.Count
        Write-Host "  [FAIL] $($f.Name): $($errs[0].Message)" -ForegroundColor Red
    } else {
        Write-Host "  [PASS] $($f.Name)" -ForegroundColor Green
    }
}
if ($parseErrs -gt 0) { $failures++ }

# 3. JSON Manifest & Test Suite Validation
Write-Host "`n[3/4] JSON Schema Validation..." -ForegroundColor Yellow
foreach ($rel in @('.claude-plugin\marketplace.json','tests\test-prompts.json')) {
    $jp = Join-Path $skillRoot $rel
    try {
        $null = Get-Content -LiteralPath $jp -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host "  [PASS] $rel" -ForegroundColor Green
    } catch {
        $failures++
        Write-Host "  [FAIL] $rel : $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 4. End-to-End Sandbox Test (Auth Gate -> Dry-Run -> Execute -> LIFO Undo)
Write-Host "`n[4/4] End-to-End Sandbox Test (Auth Gate -> Dry-Run -> Execute -> LIFO Undo)..." -ForegroundColor Yellow
$sbx = Join-Path $env:TEMP ("wso_verify_" + [guid]::NewGuid().ToString('N').Substring(0,8))
$logDir = Join-Path $sbx "logs"
try {
    New-Item -ItemType Directory -Path "$sbx\src_dir","$sbx\cache_dir" -Force | Out-Null
    Set-Content -Path "$sbx\src_dir\data.txt" -Value "ok" -Encoding UTF8
    Set-Content -Path "$sbx\cache_dir\junk.tmp" -Value "tmp" -Encoding UTF8
    Set-Content -Path "$sbx\app.ini" -Value "path=C:\Old" -Encoding UTF8

    $planFile = Join-Path $sbx "plan.json"
    @{
        name = "verify-sandbox"
        actions = @(
            @{ type = "move_dir_atomic"; source = "$sbx\src_dir"; destination = "$sbx\dst_dir"; description = "move" },
            @{ type = "clean_cache_best_effort"; path = "$sbx\cache_dir"; description = "clean" },
            @{ type = "update_text_replace"; path = "$sbx\app.ini"; find = "C:\Old"; replace = "D:\New"; description = "edit" }
        )
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $planFile -Encoding UTF8

    $execScript = Join-Path $PSScriptRoot "invoke-storage-plan.ps1"

    # 4a. Auth gate must block (exit 2) — expect stderr under Continue
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $execScript -PlanPath $planFile -Execute -LogDir $logDir 2>&1
    $authCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($authCode -ne 2) { throw "Auth gate returned $authCode instead of 2" }

    # 4b. Dry-run must not mutate
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $execScript -PlanPath $planFile -LogDir $logDir 2>&1 | Out-Null
    if (-not (Test-Path "$sbx\src_dir\data.txt") -or (Test-Path "$sbx\dst_dir")) { throw "Dry-run mutated files!" }

    # 4c. Authorized execute must mutate & emit log/json/undo
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $execScript -PlanPath $planFile -Execute -ConfirmedByUser -LogDir $logDir 2>&1 | Out-Null
    $undo = Get-ChildItem $logDir -Filter "undo_*.ps1" | Select-Object -First 1
    if ((Test-Path "$sbx\src_dir") -or -not (Test-Path "$sbx\dst_dir\data.txt") -or -not $undo) { throw "Execute failed or missing undo script!" }

    # 4d. Undo must restore moved dir & config
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $undo.FullName 2>&1 | Out-Null
    if (-not (Test-Path "$sbx\src_dir\data.txt") -or (Test-Path "$sbx\dst_dir") -or ((Get-Content "$sbx\app.ini" -Raw).Trim() -ne "path=C:\Old")) {
        throw "Undo failed to restore state!"
    }
    Write-Host "  [PASS] AuthGate=2, DryRun=0-mutation, Execute=OK, Undo=100%-restored." -ForegroundColor Green
} catch {
    $failures++
    Write-Host "  [FAIL] Sandbox test: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Remove-Item -LiteralPath $sbx -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n================ RESULT: $failures FAILURE(S) ================" -ForegroundColor $(if($failures -eq 0){'Green'}else{'Red'})
exit $failures
