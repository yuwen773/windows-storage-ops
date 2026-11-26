# Changelog

All notable changes to `windows-storage-ops` are documented in this file.
Every release explains **why** changes were made, not just what changed.

## [1.0.0] - 2026-11-26

### Why This Release Exists
Born out of a real Windows 11 developer workstation overhaul (153 GB reclaimed, Everything index shrunk 126x from 7.54 GB to 59.6 MB, 16 GB RAM usage cut from 96.2% to 69.3%), this release turns hard-won Windows storage failure modes into a zero-API, cross-runtime, verification-first Agent Skill.

### Added
- **Read-Only Fast Collector (`scripts/fast-audit.ps1`)**: Replaces slow recursive scans with multi-threaded native `robocopy /L /XJ`, checking RAM Top processes, Everything `include_file_content`, MySQL `data/` schema counts (zero row reads), cross-tool env vars, and Git secondary worktree `DirtyFiles`.
- **Pre-Flight Lock & Coupling Probe (`scripts/preflight-check.ps1`)**: Integrates Windows Restart Manager (`rstrtmgr.dll`) to catch hidden GUI file-handle locks before moving folders, with self-PID exclusion and cross-tool env/worktree/venv/Compose detection.
- **Safe PowerShell 5.1 Primitives (`scripts/safe-fs.ps1`)**: `Move-DirAtomic`, `Remove-LongPathDir`, `Remove-FilesBestEffort`, `Find-FileLockers`, `Disable-ConsoleQuickEdit`, `Set-EnvVarIdempotent`, `Sync-ProcessEnv`, and `Repair-GitWorktreesSafe`.
- **Logged & Reversible Execution Engine (`scripts/invoke-storage-plan.ps1` & `scripts/new-admin-task.ps1`)**: Defaults to Dry-Run, enforces hard `-Execute -ConfirmedByUser` authorization gate (exit code `2` if unconfirmed), records full `Start-Transcript` logs + JSON deltas, and auto-generates LIFO `undo_<timestamp>.ps1`.
- **Interactive Decision Protocol (`SKILL.md`)**: Enforces structured `AskUserQuestion` / `ask_question` UI choices at every decision checkpoint, with numbered-menu fallback for CLI runtimes.
- **Self-Verification & CI (`scripts/verify-skill.ps1`, `.github/workflows/ci.yml`)**: Automated privacy leak scan, PowerShell 5.1 AST parse check, JSON validation, and end-to-end AuthGate/DryRun/Execute/Undo sandbox verification on `windows-latest`.
- **Reproducible Demo Pipeline (`demo/`)**: Live sandbox capture + animated GIF renderer (`assets/demo.gif`) plus anonymized real case study (`examples/real-workstation-case.md`).
