#requires -Version 5.1
<#
.SYNOPSIS
    Safe Windows PowerShell 5.1 file, process, env, git-worktree, and console primitives (v2).
    Dot-source this file inside operational scripts:
        . "$env:USERPROFILE\.gemini\config\skills\windows-storage-ops\scripts\safe-fs.ps1"
#>

function Disable-ConsoleQuickEdit {
    <# Prevents accidental mouse clicks in PowerShell console from freezing long-running scripts. #>
    try {
        if (-not ('Win32.ConsoleQuickEdit' -as [type])) {
            Add-Type -Namespace Win32 -Name ConsoleQuickEdit -MemberDefinition @'
                [DllImport("kernel32.dll", SetLastError = true)]
                public static extern IntPtr GetStdHandle(int nStdHandle);
                [DllImport("kernel32.dll", SetLastError = true)]
                public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
                [DllImport("kernel32.dll", SetLastError = true)]
                public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
        }
        $handle = [Win32.ConsoleQuickEdit]::GetStdHandle(-10)
        [uint32]$mode = 0
        if ([Win32.ConsoleQuickEdit]::GetConsoleMode($handle, [ref]$mode)) {
            $ENABLE_QUICK_EDIT = 0x0040
            $ENABLE_EXTENDED_FLAGS = 0x0080
            $newMode = ($mode -band (-bnot $ENABLE_QUICK_EDIT)) -bor $ENABLE_EXTENDED_FLAGS
            [void][Win32.ConsoleQuickEdit]::SetConsoleMode($handle, $newMode)
        }
    } catch { }
}

function Find-FileLockers {
    <# Uses Windows Restart Manager (rstrtmgr.dll) to find exact PIDs holding file handles (catches GUI apps like Typora/IDE). #>
    param(
        [Parameter(Mandatory = $true)][string[]]$FilePaths
    )
    $valid = @($FilePaths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($valid.Count -eq 0) { return @() }

    if (-not ('Win32.RestartManagerLocker' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;
namespace Win32 {
    public class RestartManagerLocker {
        [StructLayout(LayoutKind.Sequential)]
        struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct RM_PROCESS_INFO {
            public RM_UNIQUE_PROCESS Process;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]  public string strServiceShortName;
            public int ApplicationType; public uint AppStatus; public uint TSSessionId;
            [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
        }
        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);
        [DllImport("rstrtmgr.dll")] static extern int RmEndSession(uint pSessionHandle);
        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames, uint nApplications, IntPtr rgApplications, uint nServices, string[] rgsServiceNames);
        [DllImport("rstrtmgr.dll")] static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);
        public static List<string> WhoLocks(string[] paths) {
            var res = new List<string>();
            uint handle; string key = Guid.NewGuid().ToString();
            if (RmStartSession(out handle, 0, key) != 0) return res;
            try {
                if (RmRegisterResources(handle, (uint)paths.Length, paths, 0, IntPtr.Zero, 0, null) != 0) return res;
                uint needed = 0, count = 0, reasons = 0;
                RmGetList(handle, out needed, ref count, null, ref reasons);
                if (needed > 0) {
                    var infos = new RM_PROCESS_INFO[needed]; count = needed;
                    if (RmGetList(handle, out needed, ref count, infos, ref reasons) == 0) {
                        for (int i = 0; i < count; i++) res.Add("PID=" + infos[i].Process.dwProcessId + " (" + infos[i].strAppName + ")");
                    }
                }
            } finally { RmEndSession(handle); }
            return res;
        }
    }
}
'@
    }
    return @([Win32.RestartManagerLocker]::WhoLocks($valid) | Sort-Object -Unique)
}

function Move-DirAtomic {
    <# All-or-nothing same-volume directory move. Never partial-splits a directory on lock/ACL error. #>
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source)) { return [PSCustomObject]@{ Ok = $false; Status = 'MISSING_SRC'; Message = $Source } }
    if (Test-Path -LiteralPath $Destination)   { return [PSCustomObject]@{ Ok = $false; Status = 'EXISTS_DST';  Message = $Destination } }
    try {
        [System.IO.Directory]::Move($Source, $Destination)
        return [PSCustomObject]@{ Ok = $true; Status = 'MOVED'; Message = "$Source -> $Destination" }
    } catch {
        return [PSCustomObject]@{ Ok = $false; Status = 'LOCKED_OR_DENIED'; Message = $_.Exception.Message }
    }
}

function Remove-LongPathDir {
    <# Safely deletes deep trees (>260 char MAX_PATH) such as node_modules using robocopy /MIR + \\?\ rd. #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $empty = Join-Path $env:TEMP ("empty_del_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $empty -Force | Out-Null
    try {
        robocopy $empty $Path /MIR /R:1 /W:0 /NFL /NDL /NJH /NJS /NP | Out-Null
        cmd.exe /c "rd /s /q `"\\?\$Path`"" 2>&1 | Out-Null
        return (-not (Test-Path -LiteralPath $Path))
    } finally {
        Remove-Item -LiteralPath $empty -Force -ErrorAction SilentlyContinue
    }
}

function Remove-FilesBestEffort {
    <# Deletes unlocked files inside a live cache directory without aborting the entire subtree on a single lock. #>
    param([Parameter(Mandatory = $true)][string]$Directory)
    $deleted = 0; $locked = 0
    if (-not (Test-Path -LiteralPath $Directory)) {
        return [PSCustomObject]@{ Deleted = 0; Locked = 0 }
    }
    Get-ChildItem -LiteralPath $Directory -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
            $deleted++
        } catch {
            $locked++
        }
    }
    Get-ChildItem -LiteralPath $Directory -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
            if ((Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    return [PSCustomObject]@{ Deleted = $deleted; Locked = $locked }
}

function Set-EnvVarIdempotent {
    <# Updates User/Machine env var ONLY if value changed (avoids slow redundant WM_SETTINGCHANGE broadcasts) and syncs current process. #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowNull()][string]$Value,
        [ValidateSet('User','Machine')][string]$Scope = 'User'
    )
    $current = [Environment]::GetEnvironmentVariable($Name, $Scope)
    if ($current -ne $Value) {
        [Environment]::SetEnvironmentVariable($Name, $Value, $Scope)
        [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
        return [PSCustomObject]@{ Name = $Name; Scope = $Scope; Changed = $true; Value = $Value }
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
    return [PSCustomObject]@{ Name = $Name; Scope = $Scope; Changed = $false; Value = $Value }
}

function Sync-ProcessEnv {
    <# Refreshes current PowerShell process env vars & Path from Machine + User Registry so CLI verifications never use stale inherited vars. #>
    $preserve = @('Path','USERNAME','USERDOMAIN','USERDOMAIN_ROAMINGPROFILE','USERPROFILE','COMPUTERNAME','LOGONSERVER','HOMEDRIVE','HOMEPATH')
    foreach ($scope in @('Machine','User')) {
        $vars = [Environment]::GetEnvironmentVariables($scope)
        foreach ($k in $vars.Keys) {
            if ($preserve -notcontains $k) {
                [Environment]::SetEnvironmentVariable($k, $vars[$k], 'Process')
            }
        }
    }
    $mPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $uPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($mPath, $uPath) | Where-Object { $_ }) -join ';'
}

function Repair-GitWorktreesSafe {
    <# Repairs Git worktree bidirectional pointers after a repo move. Immune to PowerShell 5.1 single-item scalar collapse. #>
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string[]]$WorktreePaths,
        [string]$OldPrefixPattern = ''
    )
    $existing = @($WorktreePaths | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    foreach ($wt in $existing) {
        git -C $RepoPath worktree repair $wt 2>&1 | Out-Null
    }
    $list = @(git -C $RepoPath worktree list 2>$null)
    $stale = if ($OldPrefixPattern) { @($list | Where-Object { $_ -match $OldPrefixPattern }) } else { @() }
    return [PSCustomObject]@{
        Repo          = $RepoPath
        TotalCount    = $list.Count
        StaleOldCount = $stale.Count
        StaleEntries  = $stale
    }
}
