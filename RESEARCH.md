# Research: lightweight Mac monitor + dev-disk cleaner

Checked 2026-09-27 on macOS 26.6.1, Apple M4 Pro. Labels used below:
- **measured**: I ran it on this machine.
- **source**: read in the project's code or README.
- **unverified**: not confirmed.

## 1. Existing open-source tools

### System monitoring

| Tool | Covers | Missing | Footprint | Maintained |
|---|---|---|---|---|
| [Stats](https://github.com/exelban/stats) (Swift, MIT, ~42k★) | Per-module top-N processes, per-process energy (shells out to `top -o power`), SMC temps and fans without a helper, battery W, kill | No ports view, no power-assertion UI, no full sortable process list, no hide-system toggle | 7.6 MB dmg; RAM unverified | Yes, v3.0.18 on 2026-09-27 |
| [btop](https://github.com/aristocratos/btop) (C++) | Full process list, signals, CPU temps via SMC | Energy, battery W, ports, assertions | Small; unverified | Yes, v1.4.7 on 2026-05 |
| [bottom](https://github.com/ClementTsang/bottom) (Rust) | Process list, kill, temps and battery widgets | Energy, ports, assertions | ~1.5 MB package | Yes, 0.14.9 on 2026-08 |
| [glances](https://github.com/nicolargo/glances) (Python) | Process list, web UI | macOS temps (psutil has none), energy, listening ports (its "ports" plugin probes remote hosts) | Heavy, Python runtime; unverified | Yes |
| [mactop v2](https://github.com/metaspartan/mactop) (Go) | Process list plus kill, all SMC temps, fans, thermal state, CPU/GPU/ANE W, all without sudo | Per-process energy, ports, assertions | ~4 MB; unverified | Yes, v2.1.5 on 2026-06 |
| [macmon](https://github.com/vladkens/macmon) (Rust, also a library) | CPU/GPU power via IOReport, temps via IOHID, system W via SMC `PSTR`, all without sudo | No process list at all | 747 KB tarball | Yes, 2026-08 |
| [PortKill (fr3on)](https://github.com/fr3on/portkill) (Swift) | Listening ports with PID, user, path, project dir, SIGTERM then SIGKILL, system toggle, polls only while open | Everything else | Small; unverified | New, 63★ |
| [port-killer](https://github.com/productdevbook/port-killer) (Swift, ~5k★) | Ports, graceful and force kill, "System" category, k8s and tunnels | Everything else | Unverified | Yes |
| [SleepGuard](https://github.com/anoyah/SleepGuard) | Power assertions (what keeps the Mac awake) | Everything else | Unverified | New, 1★ |
| htop, zenith, asitop (stale 2024, sudo), eul (dead 2021), MacJet (needs sudo for energy) | Subsets | n/a | n/a | Mixed |

### Disk and dev artifacts

| Tool | Covers | Missing | Footprint | Maintained |
|---|---|---|---|---|
| [gdu](https://github.com/dundee/gdu) (Go) | Parallel scan and drill-down, **persistent SQLite/Badger cache**, `D` moves to Trash, hard links counted once | No dev-artifact detection, no clone dedup | Unverified | Yes, v5.37 on 2026-08 |
| [dua-cli](https://github.com/Byron/dua-cli) (Rust) | Interactive drill-down, trash, hard links counted once, **`--deduplicate-apfs-clones`** | No cache, no dev artifacts | Unverified | Yes, 2026-09 |
| [dust](https://github.com/bootandy/dust) (Rust) | Fast static tree | Not interactive, no delete | Unverified | Yes |
| ncdu 1.x/2.x (C/Zig) | Classic TUI, JSON and binary export | No dev artifacts, permanent delete only | Unverified | Yes, 2.9.2 on 2025-10 |
| GrandPerspective | Treemap GUI, saved scans | No dev artifacts | Unverified | Yes, 3.8.1 on 2026-09 |
| [kondo](https://github.com/tbillington/kondo) (Rust) | **Marker-based detection**: pom.xml→target, build.gradle→build, package.json→node_modules, Cargo and 20+ others; newest-mtime "last modified"; `--older` filter | No venv (pyvenv.cfg) or conda; no ~/.m2 or ~/.gradle; **permanent delete only** | Unverified | Moderate, v0.9 on 2026-01 |
| [npkill](https://github.com/voidcosmos/npkill) (TS) | node_modules with last_mod | Matches names only; multi-language profiles unreleased (npm 0.12.2 from 2024-06); permanent delete | Node runtime | Slow |
| [Mole](https://github.com/tw93/Mole) (~69k★) | `analyze` TUI with cache and Trash; `purge` for build dirs | Purge matches `target`/`build` **by name**; purge is permanent | Unverified | Very active |
| DevCleaner (Xcode only), Pearcleaner (app uninstaller), mac-cleanup-py (fixed global caches) | Narrow slices | n/a | n/a | Yes |

### Verdict

No single tool covers most of the requirements. The closest combination:
- **Stats** for heat and battery.
- **PortKill** for ports.
- **gdu** for disk.
- **kondo** for artifacts.

Together they get about 75% of the way. Gaps: no power-assertion view, no venv, conda, .m2 or .gradle handling, and kondo deletes permanently. It is also four tools, so there is no single "why" view.

If you'd rather not build, the cheapest path is: install Stats, PortKill and gdu, then contribute pyvenv.cfg/conda detection and a trash mode to kondo. That leaves out the unified hot/drain view, assertions, and a shared hide-system rule. Since those are central to what you asked for, I recommend a small custom app.

## 2. Candidate stacks

| | Swift / SwiftUI (menu bar + window) | Tauri + Rust | Rust TUI (ratatui) | Go TUI (bubbletea) |
|---|---|---|---|---|
| Idle CPU | Lowest; direct syscalls, no runtime | Rust side low; WebView repaints add cost | Low, but the terminal redraws | Low; GC |
| Idle RAM | ~20–40 MB (estimate) | ~60–120 MB across WebKit processes (unverified) | ~5–15 MB | ~10–20 MB |
| Binary | ~2–5 MB | ~5–10 MB | ~2–5 MB | ~5–10 MB |
| macOS APIs (libproc, IOKit, IOPM, SMC, getattrlistbulk, FSEvents, Trash) | All native. `FileManager.trashItem`, `NSWorkspace` reveal, hover tooltips | Via FFI crates; Trash via the `trash` crate | Via FFI; no Finder reveal or hover tooltips | cgo for IOKit; weaker |
| UI effort | Moderate; `Table` gives sorting for free | Moderate (web UI plus IPC) | Low to moderate, but no hover/tooltip UX | Low to moderate |
| Distribution | `.app`; ad-hoc sign for local use; FDA grant per signed identity | Same | CLI; FDA must be granted to the terminal app | Same |
| Toolchain here | **Swift 6.2 CLT is installed. SwiftUI compiles and links without Xcode (measured).** | Rust not installed | Rust not installed | Go not installed |

**Recommendation: native Swift/SwiftUI, built with SwiftPM and packaged into a `.app` by a script.**
- It is the only option that calls every needed API directly.
- It has the lowest footprint of the GUI options.
- It gives you the Finder, Trash and tooltip behaviour you asked for.
- It needs no new toolchain.

Rejected:
- **Tauri**: the WebView roughly triples RAM for no gain.
- **TUIs**: they can't do hover tooltips or Finder integration, and Full Disk Access would land on the terminal emulator instead of the tool.

## 3. What macOS exposes (probed on this Mac)

Summary of access (details per signal below):

| Needs | Signals |
|---|---|
| Nothing (plain user) | Own-user process metrics, paths of all processes, thermal state, SMC temps, battery watts, assertions, all listening ports with PIDs |
| Root (a privileged helper) | Exact CPU, memory and energy for other users' processes; `powermetrics` |
| Full Disk Access | Complete scans of protected parts of ~/Library and other users' areas |

### CPU and memory per process
- **Own-user processes:** `proc_pidinfo(PROC_PIDTASKINFO)` and `proc_pid_rusage(RUSAGE_INFO_V6)` give CPU time, RSS and phys_footprint. **measured, no root.**
- **Other users' processes (root, `_windowserver`, …):** both calls return **EPERM**. `proc_pidpath` still works, and `sysctl KERN_PROC_ALL` gives uid, ppid, start time and name. **measured.**
- **Workaround:** `/bin/ps` is setuid root. `ps -axo pid,%cpu,rss,time,...` covers all processes for about 10 ms per sample (**measured**). The app runs it once per tick for foreign PIDs only. No helper needed.
- **Args and open fds of other users' processes:** also blocked (`KERN_PROCARGS2` EINVAL, `PROC_PIDLISTFDS` EPERM). The details pane will show "not visible without root" for these.

### "Heat" (no per-process metric exists)
Proxy score per process:
- **Own-user processes:** Δ`ri_energy_nj` (kernel-measured CPU energy per process) plus Δ interrupt and package-idle wakeups. **measured, no root.** Correction found during the build: `ri_billed_energy` stays near zero for most processes (a Chrome helper at 16% CPU read about 0 mW billed versus 24 mW `ri_energy_nj`), so the build uses `ri_energy_nj`.
- **Foreign processes:** CPU% from `ps`.
- **On demand:** a `top -l 2 -stats pid,power` sample gives true POWER for every process. `top` holds the `system-task-ports.read` entitlement, but one sample costs about 1.2 s of CPU (**measured**). It only runs when you press "Precise sample" in the Heat view, never on the timer.

Machine-level signals shown next to the ranking:

| Signal | Source | Status |
|---|---|---|
| Thermal state | `ProcessInfo.thermalState` and its change notification | measured |
| SMC access (fan RPM `F0Ac`) | `IOServiceOpen(AppleSMC)` | Open works without root (**measured**); reading `F0Ac` is from Stats/macmon source |
| Temperatures | IOHID sensor client, as macmon and mactop do it | source |
| CPU/GPU package power | IOReport | Needs private `libIOReport`, so it is optional; source |

The UI will label the ranking "Energy impact (estimated)", not "heat".

### Battery drain

| Signal | Source | Status |
|---|---|---|
| System load (mW) | `AppleSmartBattery` → `PowerTelemetryData.SystemLoad` (read 16,024 mW = 16 W on battery) | measured |
| Fallback wattage | `Amperage` × `Voltage` | measured |
| Time remaining | `TimeRemaining` / `IOPSCopyPowerSourcesInfo` "Time to Empty" | measured |
| Battery temperature | `AppleSmartBattery` | measured |
| What keeps the Mac awake | `IOPMCopyAssertionsByProcess`: PID → type and name. It returned 5 PIDs including WindowServer's UserIsActive | measured, no root |

### Ports
- `netstat -anv -p tcp|udp` prints `process:pid` for **every** socket, including root ones, without root, in under 10 ms (**measured**). It reads the `net.inet.{tcp,udp}.pcblist_n` sysctl, which carries `so_last_pid`.
- `lsof`, which the existing port apps wrap, only sees your own processes unless run as root.
- Plan:
  - Parse `netstat -anv` output, polling only while the Ports view is visible.
  - Take the executable path from `proc_pidpath` (works for all PIDs).
  - Take the user from `ps`/`kinfo_proc`.
- Reading `pcblist_n` directly is possible, but its structs are private to XNU. I rejected it as fragile for a small speed gain.

### Kill
- `kill(2)` on another user's process returns EPERM without root. So the app can only kill **your own** processes.
- The "refuse critical system processes" rule is therefore enforced by the OS. On top of that, the app hard-blocks a deny-list even for same-user processes (launchd, loginwindow, WindowServer, Dock, Finder, SystemUIServer, the app itself) behind a strong warning.

### Hide-system definition (shown in the UI)
A process counts as "system" if **any** of these hold:
- uid < 500, or the username starts with `_`.
- The executable is under `/System/`, `/usr/libexec/`, `/usr/sbin/`, `/sbin/`, `/usr/bin/` or `/Library/Apple/`.
- It is Apple-signed: `SecStaticCodeCheckValidity` with `anchor apple`, cached per path.

Its ports are hidden with it.

### Disk sizing on APFS
- **Traversal:** `getattrlistbulk` on an `open(O_DIRECTORY)` fd returns name, type, fileid, link count, logical length and **allocated size** per entry in batches, with no per-file `stat`. It never follows symlinks; a symlink counts as its own small size.
- Work runs on a bounded concurrent pool of about 4–8 directories at a time. Scan scope is limited:
  - Stay on the starting device (check `st_dev`).
  - Skip `/System/Volumes/Data` re-entry via firmlinks: scanning "Macintosh HD" means scanning the Data volume.
- **Size shown:** "On disk" is the allocated size, the primary figure. "Logical" is available as a toggle.
- **Hard links:** when link count > 1, count the file once per `(dev, fileid)` using a set.
- **APFS clones:** allocated size double-counts clones. For dev-artifact candidates (the only things we'd delete), fetch `ATTR_CMNEXT_PRIVATESIZE`, the bytes actually freed on delete. The dev-artifacts view shows that as "Reclaimable". Full scans don't fetch it, to keep them fast.
- Snapshots (Time Machine local) can also hold space, so the "Reclaimable" tooltip says: "freed space may be lower while local snapshots exist."
- **Cache and rescan:**
  - Store a compact binary tree of (path, dir mtime, sizes, counts), plus the FSEvents event ID and volume UUID at scan end.
  - On rescan, `FSEventsCopyUUIDForDevice` plus a `sinceWhen` history replay lists the directories that changed. Only those are re-read.
  - If the history is unavailable, fall back to re-reading only directories whose mtime changed. A directory's mtime reflects direct children only, so every directory is still `stat`ed, but files are not.

### "Last used" for a directory

| Option | Verdict |
|---|---|
| atime | **Rejected.** On APFS, reading a file updates atime only when atime < mtime, and listing a directory bumps its atime. So our own scanner, Spotlight and backups destroy the signal (**measured**). |
| Spotlight `kMDItemLastUsedDate` | **Rejected.** It is set only for files opened through LaunchServices, and it was `null` for a directory (**measured**). |
| Newest mtime inside the artifact | **Kept.** It tells you when it was last installed or rebuilt. It comes free from the scan. |
| Newest mtime of the owning project's files, excluding artifact dirs | **Kept.** Uses the marker files plus a bounded walk of the source tree. |
| Last git activity | **Kept.** `mtime` of `.git/logs/HEAD` catches commits and checkouts, falling back to the commit time from `git log -1 --format=%ct`. |

The app shows **Last activity = max(project file mtime, git activity, artifact mtime)** and labels the source, for example "Last activity: 41 days ago (git checkout)". The tooltip explains that this is modification-based, not "last opened". For global caches (~/.m2, ~/.gradle), the label is "Last dependency written".

### Artifact markers

| Type | Rule |
|---|---|
| node_modules | Folder named `node_modules` whose parent has `package.json`. Nested node_modules are not listed separately. |
| Python venv | Any directory containing `pyvenv.cfg`, whatever its name. That is stricter and broader than "venv/.venv/env". |
| Conda env | A directory containing `conda-meta/`, plus the entries in `~/.conda/environments.txt`. |
| Maven | `target/` with a sibling `pom.xml`. |
| Gradle | `build/` with a sibling `build.gradle`, `build.gradle.kts`, `settings.gradle` or `settings.gradle.kts`. |
| Global caches | `~/.m2/repository`, `~/.gradle/caches`, `~/.gradle/wrapper/dists`. |

### Permissions
- **Full Disk Access** is needed only for complete scans of protected paths such as ~/Library/Mail, Safari and other users' folders. Desktop, Documents and Downloads trigger one-time TCC prompts. Without FDA, the scan reports skipped folders instead of failing.
- **Signing:**
  - An ad-hoc-signed local build works.
  - TCC ties grants to the code signature, so the build script signs with a stable local identity when one exists; otherwise the FDA grant resets on rebuild.
  - Notarization isn't needed for your own machine.
- **Optional privileged helper:** would give exact CPU/memory/energy for foreign processes (and `powermetrics`). Not needed for v1; can be deferred without affecting anything else.

## 4. Proposed extra features (ranked, for your approval)

1. **Menu bar indicator**: thermal state, current watts, and the top offender at a glance. This is the whole point of a "lightweight" monitor.
2. **Rolling 5-minute energy ranking** alongside the instantaneous one. Heat and drain build up over minutes, so a single snapshot misleads.
3. **More artifact types**: Xcode DerivedData, Rust `target/` (by `Cargo.toml`), `~/.npm/_cacache`, `~/Library/Caches/pip`, Homebrew cache. These are usually the next biggest dev-disk hogs.
4. **"Free port N" quick action**: type a port, see who owns it, and terminate it in one step. This is the most common port task.
5. **Notification** when the thermal state reaches Serious, or a process holds more than X% CPU for N minutes. It catches runaway builds before the fan does.

Not proposed:
- Fan control: it needs root and writes to the SMC.
- A treemap: it adds UI cost, and the sorted list answers the question.
