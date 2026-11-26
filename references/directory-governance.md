# Windows Workstation Directory Governance & Second-Order Coupling Guide

Use this reference whenever diagnosing messy drive layouts, naming issues, or misplaced
apps/caches/services, and before proposing ANY migration plan. Replace `<DATA>:` with the
user's non-system data drive (e.g., `D:\` or `E:\` if a second SSD is present).

---

## 1. Recommended 5-Pillar Data Drive Architecture (Pure ASCII, Zero Spaces)

| Pillar | Responsibility | Recommended Substructure | Backup Strategy |
|---|---|---|---|
| **`<DATA>:\Dev\`** | Single root for all new code & worktrees | `active\` (3–5 current repos), `lab\` (demos/OSS/scripts), `worktrees\` (AI/Git worktrees), `archive\` (>3 mo idle; strip `node_modules`/`.venv`/`target` on entry) | Keep active repos `git push`ed |
| **`<DATA>:\Personal\`** | Irreplaceable personal documents (**only** zone allowing localized/non-ASCII names) | Documents, courses, papers, books, patents, media archives | **Primary 3-2-1 backup target** (cloud + offline disk) |
| **`<DATA>:\Env\`** *(or existing ASCII runtime root)* | Stateless CLI runtimes & build tools (zero spaces!) | `python3xx\`, `nodejs\`, `maven\`, `gradle\`, `uv\`, `go\` | Reinstallable |
| **`<DATA>:\Services\`** | Stateful local services & virtual disks | `wsl\`, `docker\`, `mysql\` (prefer Docker Compose for Redis/ES/MQ/PG/Grafana/Prometheus instead of native Windows installs) | Periodic DB dumps for business schemas |
| **`<DATA>:\Cache\`** | Rebuildable dev caches (add to search indexer & AV exclusions) | `npm\`, `pnpm\`, `playwright\`, `maven\`, `gradle\`, `pip\` | Disposable anytime |

**Strict Separation: App Caches vs Irreplaceable App User Data**
- Pure disposable GUI app caches (media streaming cache, browser PDF/video cache) may live in a dedicated app-cache folder (e.g., `<DATA>:\AppCache\`) and be excluded from search indexing.
- **NEVER** mix irreplaceable app user data (chat histories such as WeChat/QQ/Telegram, downloaded personal media) into `<DATA>:\Cache\` or any directory named `Cache`—name collision invites accidental deletion.

---

## 2. Common Layout Smells to Diagnose & Propose Fixes For

1. **System Drive Overload**: `C:` <25% free while large relocatable stores (`WSL2 ext4.vhdx`, `Docker docker_data.vhdx`, `npm-cache`, `ms-playwright`, `Downloads` installers) sit on `C:`.
2. **Spaces or Non-ASCII in CLI/Code Paths**: Build tools (Java/Maven/Gradle/CMake/Python/Docker mounts) frequently break under paths containing spaces or localized characters. Keep all code, runtime, cache, and service paths pure ASCII with zero spaces.
3. **Code Root Fragmentation**: Multiple competing code roots (e.g., `code\`, `Work\code\`, `Frontend\`, `Backend\`, `C:\Users\<user>\projects\`) plus orphan worktrees duplicating `node_modules`.
4. **Native Middleware Sprawl**: Multiple versions of Redis/Tomcat/MySQL/RabbitMQ manually unzipped on Windows instead of 1 host DB + Docker Compose.
5. **Root-Installed Software / Runtimes**: Apps or Python installed directly into a parent folder root (scattering `.dll` / `.exe` files across the directory). Fix via official uninstall + clean reinstall into a dedicated subfolder—never drag files manually.

---

## 3. Anti-Patterns & Second-Order Coupling Traps (NEVER Propose These!)

1. **Standards Proliferation (XKCD 927)**:
   - Do **NOT** invent a brand-new top-level GUI software folder while legacy `Program Files` roots stay pinned by Windows Registry & auto-updaters.
   - Normal GUI desktop apps are small and depend on `C:` registry/AppData/auto-updaters anyway—let them install to default Windows locations (or manage via `winget`) and redirect only their **large data & caches** to `<DATA>:`.
2. **Junction Hacks for Electron / AI Agents / IDE-Managed JDKs**:
   - Do **NOT** recommend moving `.claude`, `.codex`, `.t3`, `.vscode`, or `%USERPROFILE%\.jdks` across volumes via NTFS Junctions unless `C:` is critically starved (<10% free after all safe cleans). Cross-volume Junctions break Electron auto-updaters, SQLite locking, and IDE SDK bindings—and offer zero I/O or SSD wear relief when `C:` and `D:` share one physical disk.
3. **Moving Hot Projects Without Mapping Coupling**:
   - Moving an active repo impacts:
     - **Git Worktree bidirectional absolute paths** (must run `Repair-GitWorktreesSafe` and verify `StaleOldCount == 0`);
     - **Python `.venv`** (hardcoded absolute paths in `pyvenv.cfg` and `Scripts\*.exe` shims);
     - **AI Agent session histories** (`~/.claude`, `~/.codex`, `~/.t3` index conversations by absolute path);
     - **Docker Compose host bind mounts**.
   - **Rule**: Migrate **cold/static assets first**; keep hot/active projects in place until a natural iteration boundary unless the user explicitly chooses full migration after reviewing the coupling trade-offs.
4. **Single-Disk Myth**:
   - When `C:` and `D:` are partitions on Disk 0, moving data from `C:` to `D:` relieves `C:` fullness and OS reinstall risk, but does **NOT** isolate I/O, reduce total SSD wear, or provide redundancy. Prioritize **RAM upgrades** (when RAM >85% + active paging) and **3-2-1 backup** before recommending a second SSD unless local AI model weights/datasets demand capacity.
