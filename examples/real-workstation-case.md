# Real-World Workstation Governance Case Study (Anonymized)

> Hardware profile: Windows 11 laptop, 1 TB single NVMe SSD (C: 300 GB + D: 653 GB), 16 GB RAM, full-stack Java/Node/Python + AI coding agent workload.
> All personal names, account names, and private project identifiers have been anonymized.

---

## Before vs. After (Verified Live Measurements)

| Metric | Before | After | Delta |
|---|---:|---:|---|
| **C: Free Space (300 GB)** | 66.00 GB (22.0%) | **137.39 GB (45.8%)** | **+71.39 GB** (free space doubled) |
| **D: Free Space (653 GB)** | 267.34 GB (40.9%) | **349.07 GB (53.5%)** | **+81.73 GB** (after absorbing 23 GB WSL/Docker VHDXs) |
| **Combined Reclaimed** | 333.34 GB free | **486.46 GB free** | **+153.12 GB** |
| **Search Indexer DB (Everything)** | 7.54 GB (2× 3.77 GB) | **59.6 MB** | **126x smaller** |
| **Host RAM Utilization (16 GB)** | 96.2% (0.5 GB free) | **69.3% (4.67 GB free)** | **~4 GB RAM reclaimed** |
| **Dead `PATH` Entries** | 17 (10 User + 7 Machine) | **0** | All stale paths removed with backups |
| **Data Drive Root Clutter** | 32 mixed folders | **14 structured folders** | Consolidated into 5 core pillars |
| **Read-Only Deep Audit Time** | 91 min (recursive PS1) | **3.8 min (228.5 s)** | **24x faster** via `fast-audit.ps1` |

---

## Key High-Leverage Root Causes Caught

1. **Full-Disk Content Indexing Eating 4 GB RAM + 7.5 GB Disk**:
   Inspecting `Everything-1.5a.ini` revealed `include_file_content=1` across `C:\;D:\` with `content_max_size=0`, loading text from `node_modules` and huge PDFs into RAM. Disabling full-disk content indexing + adding dev exclusions shrank the index from 7.54 GB to 59.6 MB and dropped host RAM usage from 96.2% to 69.3%.
2. **Legacy Database Engine Holding Active Schemas**:
   Before uninstalling an old MySQL 5.7 instance (port 3306), inspecting `data/` schema folder names revealed 32 user databases—including an actively developed project absent from MySQL 8.0 (port 3307). All 32 schemas were safely dumped, 25 non-conflicting schemas imported into MySQL 8.0, 331 leftover automated CI test schemas dropped, and MySQL 8.0 relocated cleanly to `<DATA>:\Services\mysql` on port 3306 via `sc.exe config`.
3. **Cross-Tool Environment Coupling & Stale Inherited Env**:
   Moving the Maven repository revealed `Machine::GRADLE_USER_HOME` was still pointing to the old path, and an older terminal session briefly recreated the old directory when running `gradle -v`. Fixed via `Set-EnvVarIdempotent` + `Sync-ProcessEnv`.
4. **Hidden GUI File-Handle Lock**:
   Moving an archived repo hit `Access Denied` despite zero command-line process references. `Find-FileLockers` (`rstrtmgr.dll`) pinpointed a desktop Markdown editor holding an open handle inside a backup subfolder; closing the editor allowed instant atomic relocation.
5. **Preventing Second-Order Over-Engineering**:
   Rather than inventing a new top-level GUI app folder or creating risky cross-volume NTFS Junctions for Electron/AI agent configs and IDE-managed JDKs, GUI apps stayed on Windows defaults while caches, services, runtimes, and cold code converged cleanly into 5 pillars.
