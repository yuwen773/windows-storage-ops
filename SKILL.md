---
name: windows-storage-ops
description: >-
  磁盘清理大师 (Windows Storage Master) — End-to-end Windows 10/11 developer workstation
  storage auditor, safe disk cleaner, directory/app/service migration operator, and
  quarterly drift monitor. Workflow: (1) fast read-only deep audit, (2) interactive
  decision checkpoints via AskUserQuestion/ask_question, (3) safe cleanup & rational
  drive/directory/app relocation via logged, authorization-gated PowerShell scripts
  with auto-generated undo rollback, and (4) 5-second quarterly health checks.
  Triggers: 磁盘清理大师, 清理C盘, 磁盘审计, 合理规划磁盘, 磁盘空间不足, 清理缓存,
  迁移WSL/Docker/MySQL/目录, 清理node_modules/worktree, 文件被占用谁锁的,
  disk cleanup, audit C/D drive, reorganize Windows drives, migrate dev caches.
  Do NOT use for Linux/macOS-only servers, OS reinstallation or partition formatting,
  ordinary application code refactoring, or blind deletion of unknown Windows system files.
---

# Windows Storage Master — 磁盘清理大师

An evidence-driven, verification-first Windows 10/11 storage skill built for developers
and heavy AI coding-agent users. It combines **fast read-only deep auditing**, **guided
interactive choices**, and **logged, reversible PowerShell automation**—never deleting
or moving a single byte without explicit user authorization.

---

## Core Interaction & Safety Rules (Non-Negotiable)

### 1. Mandatory `AskUserQuestion` Interactive Protocol
Whenever user input, selection, or authorization is needed (after audit, choosing cleanup
buckets, adopting directory/app relocation suggestions, or approving script execution):
- **MUST invoke the host runtime's structured selection tool** (`ask_question` in
  Antigravity, `AskUserQuestion` in Claude Code, or equivalent interactive choice tool).
  Put the recommended option first prefixed with `(Recommended)`, and use multi-select
  when the user can pick several cleanup/migration items.
- **DO NOT** ask the user to manually type long answers in the chat box when a structured
  question tool is available.
- **Cross-runtime fallback**: Only if the active runtime provides no structured question
  tool, present a compact numbered choice table so the user can reply with short indices.

### 2. Strict Authorization Gate & Audit Trail
- **Read-Only First**: Always audit first; NEVER delete, move, prune, edit env vars, or
  start/stop services during discovery.
- **No Unapproved Execution**: Never run mutating actions until the user explicitly approves
  via `AskUserQuestion` / imperative confirmation. Confirming questions ("这样就行了吧？"
  "没问题吗？") are status checks, **NOT** execution authorization.
- **Logged & Reversible Automation**: Execute cleanup and migration plans through
  [invoke-storage-plan.ps1](./scripts/invoke-storage-plan.ps1):
  1. First run in default **Dry-Run** preview mode (modifies nothing).
  2. Present the preview, log path (`%LOCALAPPDATA%\windows-storage-ops\logs\`), and
     rollback coverage (`undo_<timestamp>.ps1`) to the user via `AskUserQuestion`.
  3. Only after explicit approval, run with `-Execute -ConfirmedByUser`.
  4. If any step requires Administrator privileges (Machine `PATH`, Windows services,
     `DeliveryOptimization`, ACL-protected folders), package them into **ONE** elevated
     launcher via [new-admin-task.ps1](./scripts/new-admin-task.ps1).

---

## End-to-End 4-Stage Workflow

### Stage 1: Read-Only Deep Disk Audit
1. Load [deep-audit-protocol.md](./references/deep-audit-protocol.md) for full Phase 0–8
   safety, privacy, and 4-bucket reclaimable space rules.
2. Run the fast, universal read-only collector:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\scripts\fast-audit.ps1"
   ```
   - Auto-discovers all fixed volumes, `%USERPROFILE%`, AppData consumers, dead `PATH` &
     stale `*_HOME`/`*_DIR`/`*_CACHE` env vars, Everything `.ini` `include_file_content`
     switch, running DB services + `data/` schema counts (names only, zero row reads),
     WSL2/Docker status (without starting stopped services), and Git secondary worktree
     `DirtyFiles` counts.
   - Copy all paths and localized directory names verbatim from command output.
   - If any sensitive/anomalous file is found, expand and report its entire parent directory.
3. Present concise findings (Disk/RAM baseline, P0–P3 issues, 4-bucket non-overlapping
   reclaimable space) and **STOP**—use `AskUserQuestion` to let the user choose which
   cleanup and reorganization items to proceed with.

### Stage 2: Safe Basic Disk Cleanup
For user-approved cleanup items:
1. Build a structured JSON plan (`actions[]`) targeting only approved items:
   - Live caches (`Temp`, media/browser caches) → `clean_cache_best_effort`
   - Deep build artifacts (`node_modules`, `.venv`, `target`, obsolete dirs) → `remove_longpath_dir`
   - Verified leftover files (old installers, diagnostic dumps) → `remove_file`
   - Cache env redirects (`NPM_CONFIG_CACHE`, `PNPM_STORE_DIR`, `PLAYWRIGHT_BROWSERS_PATH`,
     `GRADLE_USER_HOME`, `PIP_CACHE_DIR`) → `set_env_var` + `update_path_replace`
2. Dry-run preview → `AskUserQuestion` authorization → authorized execution via
   [invoke-storage-plan.ps1](./scripts/invoke-storage-plan.ps1) → report verified GB delta
   and log file path.

### Stage 3: Directory, Drive & App Placement Governance + Migration
When drive layout, folder naming, or app/service placement is messy:
1. Load [directory-governance.md](./references/directory-governance.md) and apply
   **first-principles & second-order coupling checks** BEFORE proposing moves:
   - Flag spaces/non-ASCII in CLI/code paths, code-root fragmentation, native middleware
     sprawl, root-installed runtimes, and mixed caches vs irreplaceable user data.
   - **Never propose** standards-proliferating GUI app roots, cross-volume NTFS Junctions
     for Electron/AI Agent dirs or IDE-managed JDKs, or moving hot active projects without
     accounting for Git worktrees, `.venv`, Docker bind mounts, and AI path-keyed histories.
2. Present concrete migration proposals with trade-offs and let the user pick which
   suggestions to adopt via `AskUserQuestion`.
3. Before touching any adopted migration target, run
   [preflight-check.ps1](./scripts/preflight-check.ps1):
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\scripts\preflight-check.ps1" -Paths "<target1>","<target2>"
   ```
   Checks `IS_ADMIN`, ACL inheritance protection, process refs (self-PID excluded),
   **real OS file-handle lockers via `rstrtmgr.dll` (`HANDLE_LOCK`)**, cross-tool env
   refs, and Git worktree / `.venv` / Docker Compose coupling.
4. Execute adopted migrations via [invoke-storage-plan.ps1](./scripts/invoke-storage-plan.ps1)
   (atomic same-volume `move_dir_atomic`, cross-volume `move_dir_cross_volume`,
   `update_text_replace`, `repair_git_worktrees`, `set_env_var`, `update_path_replace`)
   — or via [new-admin-task.ps1](./scripts/new-admin-task.ps1) for Windows services
   (always `sc.exe config`, never raw Registry alone) and Machine env vars.
5. Call `Sync-ProcessEnv` (from [safe-fs.ps1](./scripts/safe-fs.ps1)) before running
   post-migration CLI checks (`mvn -v`, `gradle -v`, `node -v`, `git worktree list`) so
   stale inherited env vars never recreate deleted directories.

### Stage 4: Quarterly 5-Second Health Check
Run [quarterly-audit.ps1](./scripts/quarterly-audit.ps1) periodically to catch space,
RAM, Everything `include_file_content`, archive build-artifact, and env-var drift:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\scripts\quarterly-audit.ps1"
```

---

## Anti-Pattern Blacklist (Never Do These)

- Never use raw PowerShell `Move-Item` on large same-volume dirs (partial-splits on ACL/lock errors).
- Never rely solely on PowerShell 5.1 `Remove-Item -Recurse` for `node_modules` (>260 char `MAX_PATH`) or live caches.
- Never omit `@(...)` around dynamic collections before splatting/indexing in PowerShell 5.1.
- Never mix multiple bare `Select-Object`/`Format-Table` objects into one stdout stream (pipe each through `| Format-Table -AutoSize | Out-String`).
- Never treat `WinSxS`, `Windows\Installer`, active DB data, or dirty Git worktrees as plain trash.
- Never mix irreplaceable user app data (e.g., chat histories) into directories named `Cache`.
- Never execute mutating scripts without `-Execute -ConfirmedByUser` after explicit user approval.
