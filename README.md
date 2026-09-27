# MacLens

[![CI](https://github.com/amrakshay/maclens/actions/workflows/ci.yml/badge.svg)](https://github.com/amrakshay/maclens/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/amrakshay/maclens)](https://github.com/amrakshay/maclens/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A small native macOS app for developers. It answers:
- Why is the Mac hot?
- Why is the battery draining?
- Who owns this port?
- Which build artifacts can I delete?

It is written in Swift/SwiftUI with no third-party dependencies and needs no root. With the window closed it uses about 0.3% of one CPU core. The reasoning behind the design is in [RESEARCH.md](RESEARCH.md).

## Install

You need macOS 14 or later on Apple Silicon.

**Homebrew:**

```bash
brew install --cask amrakshay/tap/maclens
```

To update: `brew upgrade --cask maclens`.

**Direct download:** get `MacLens-X.Y.Z.zip` from [Releases](https://github.com/amrakshay/maclens/releases/latest), unzip it, and move `MacLens.app` to Applications.

MacLens is free and not notarized by Apple (notarization needs a paid Apple Developer account), so macOS blocks the first launch. To allow it:
1. Open MacLens once.
2. Go to System Settings → Privacy & Security, find "MacLens was blocked…", and click **Open Anyway**.

To check that a download came from this repo's CI:

```bash
gh attestation verify MacLens-X.Y.Z.zip --repo amrakshay/maclens
```

## Build from source

You need macOS 14 or later, Apple Silicon, and the Xcode Command Line Tools (Swift 6). Full Xcode is not required.

```bash
./scripts/build-app.sh
```

```bash
open dist/MacLens.app
```

MacLens runs like any other app, with a Dock icon, and also puts an indicator in the menu bar. The main window opens on the Dashboard. Closing the window keeps MacLens running in the menu bar; click the Dock icon to reopen it. The menu bar menu shows:
- Thermal state and system watts.
- The top 3 energy users over the last 5 minutes.
- What is keeping the Mac awake.

**Open MacLens** opens the main window. Launch with `--background` to skip opening the window at start.

Self-test of the core library:

```bash
swift run maclens-selftest
```

- Everything it creates or deletes lives in `./.selftest/`.
- It fences deletions with `MACLENS_DELETE_SANDBOX`.
- It uses its own cache directory.
- It sends one tiny file to the Trash to test that path.

Measure the app's own footprint:

```bash
./scripts/measure.sh
```

The measurement script is read-only: its scan phase only reads your home folder.

## Permissions

| Permission | Needed for | Without it |
|---|---|---|
| **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access → add `MacLens.app`) | Sizing TCC-protected folders in Storage scans (Mail, Safari, other apps' containers) | Those folders are skipped. The scan reports how many and marks them with a lock. |
| Notifications (prompted on first launch) | Thermal, runaway-process and battery-level alerts | Alerts are not shown. |
| Desktop / Documents / Downloads prompts | The first scan that enters them | Those folders are skipped. |

No feature needs root. Settings → Permissions shows whether Full Disk Access is granted.

**FDA and rebuilds:** macOS ties the Full Disk Access grant to the code signature. The default build is ad-hoc signed, so the grant resets after every rebuild. To keep it, sign with a stable identity:
1. Create a self-signed "Code Signing" certificate in Keychain Access.
2. Build with `MACLENS_SIGN_IDENTITY="<name>" ./scripts/build-app.sh`.

## What each view does

**Dashboard** (the default view)
- **Stat tiles:**
  - Thermal state, shown with a status color, icon and label.
  - System power, CPU load (all cores) and memory used. Memory is Activity Monitor's definition: app + wired + compressed, with swap.
  - Hottest CPU die and fan speed.
  - Battery and time left.
  - Battery health: maximum capacity, condition and cycle count, the same figures as System Settings → Battery → Battery Health.
  - Power, CPU, memory and CPU temperature also have a sparkline.
- **Sleep control:**
  - **Prevent sleep** runs `/usr/bin/caffeinate -d`, so the display and system stay awake.
  - The bar then shows every running `caffeinate`, with its arguments, PID, start time, and whether MacLens or something else started it.
  - **Allow sleep** stops them so macOS sleeps on its normal schedule. It asks first if one was started outside MacLens.
  - The `caffeinate` process is independent of MacLens: it keeps running if you quit, and MacLens picks it up again on relaunch.
  - A coffee cup appears in the menu bar while it's active, and the menu has the same toggle.
- **Trend charts** (5 / 15 / 30 min) for power, CPU load, memory and CPU temperature. Hover a chart for the exact value and time.
- **Two ranked bar charts:**
  - Top energy users over the last 5 minutes.
  - Reclaimable developer artifacts by type, from the last Developer Artifacts scan, next to disk capacity.
- **Short lists** of what's keeping the Mac awake and your apps' listening ports. Each links to its full tab.
- **History:** kept in memory for 30 minutes and recorded even while the window is closed. It starts empty at launch.
- **Colors:** the palette was checked for colorblind separation and contrast in light and dark mode. Every chart shows a single measure on one axis, and every bar carries its value as a label.

**Processes**
- System processes are hidden by default. Untick **Hide system processes** to show them; the ⓘ next to it shows the definition.
- Every process with CPU %, memory, energy now, and energy over 5 minutes. Columns sort; search and refresh interval (1–10 s) are available.
- Selecting a row shows:
  - Path and arguments.
  - Parent, user and start time.
  - Open ports.
  - **Terminate (SIGTERM)** and **Force Kill (SIGKILL)** buttons. Both ask for confirmation. If the process survives SIGTERM, the app suggests Force Kill.
- Kill safety:
  - Critical processes (launchd, WindowServer, loginwindow, kernel_task, …) are refused.
  - Other users' processes are refused; macOS itself forbids signalling them without root.
  - Your own macOS components (Dock, Finder, …) need a second, explicit warning.

**Heat & Battery**
- Shows system processes by default, because WindowServer and other daemons are often the real heat source.
- Thermal state, whole-system watts, battery flow and time remaining, CPU/battery/SSD temperatures, and fan RPM.
- Battery health:
  - Maximum capacity and condition ("Normal" or "Service Recommended"), as System Settings shows them.
  - Cycle count against the rated count (e.g. 258 of 1000).
  - Full-charge versus design capacity in mAh.
- The top energy users, ranked now or by 5-minute average.
- The power assertions keeping the Mac awake.
- **Precise sample** runs `/usr/bin/top` once to get Apple's energy score for every process.

**Ports**
- System-owned ports are hidden by default (**Hide system ports**).
- Every listening TCP socket and bound UDP socket, for all users: port, protocol, address, PID, process, user and path. Search is available.
- **Free a port:** type a port number to see its owner and terminate it.

**Storage**
- Scan targets: Home, the Data volume, or any folder.
- Scans run in the background with progress and a Cancel button.
- Results sort by size (on disk or logical). Double-click a folder to drill into it.
- The details bar shows full path, size, item count and modified date, with **Reveal in Finder** and **Move to Trash**.
- Results are cached. A rescan replays FSEvents history and re-reads only folders that changed.

**Developer Artifacts**
- Finds build artifacts by marker file (rules below).
- Columns: type, size, reclaimable bytes, owning project, last activity (with its source), and path.
- Filter by type, by "not used in N days", or by text. Sort by any column. Totals update with the filter and selection.
- **Move to Trash…** is the default. **Delete Permanently…** is a separate button. Either one shows a confirmation that lists every path and the total size. Global caches carry a re-download warning.

**Updates**
- MacLens checks GitHub Releases once a day, with one small request. You can turn this off or run **Check now** in Settings.
- When a newer version is out, you get one notification per version, a banner on the Dashboard and an entry in the menu bar menu.
- The update window shows the changelog, with **Update and restart**, **Skip this version** and **Later**.
- **Update and restart** works like this:
  - Homebrew installs run `brew upgrade --cask maclens`.
  - Downloaded copies fetch the release zip and verify its SHA-256, code signature, bundle ID and version. The old copy goes to the Trash, the new one goes in its place, and MacLens relaunches.
  - Development builds just link to the release page.
- **No Gatekeeper prompt after updates.** Once an update passes verification (this repo's release, SHA-256, code signature, bundle ID, newer version), MacLens clears macOS's quarantine flag on it, so the new version opens without the "Apple could not verify…" prompt. This applies to both update paths, and a toggle in Settings → Updates turns it off. Files that fail verification are never touched.
  - The very first install still shows the prompt once: allow it via System Settings → Privacy & Security → **Open Anyway**.
  - So does updating from 1.1.0, which predates this feature.
- Full Disk Access has to be re-enabled after an update, because each release is ad-hoc signed.

**Settings**
- Version and build, update options, refresh intervals, notification thresholds, and Full Disk Access status.
- **Battery alerts:**
  - On by default: low at **20%** while on battery, high at **80%** while charging. The levels change in 5% steps, and a toggle turns the alerts off.
  - Each alert fires once when the level is reached. It re-arms only after the battery moves 2% back past the level.
  - A level already past its threshold when MacLens starts doesn't alert.
  - **Send test alert** checks that notifications are allowed.
- The exact "system process" and "protected path" definitions.

### Detection rules (marker files, not folder names)

| Type | Rule |
|---|---|
| node_modules | `node_modules/` next to `package.json` (nested ones aren't listed separately) |
| Python venv | any folder containing `pyvenv.cfg`, whatever its name |
| Conda env | a folder containing `conda-meta/`, plus entries in `~/.conda/environments.txt`; base installs are excluded (their `envs/*` are listed) |
| Maven | `target/` next to `pom.xml` |
| Gradle | `build/` next to `build.gradle[.kts]` or `settings.gradle[.kts]` |
| Rust | `target/` next to `Cargo.toml` |
| Global caches | `~/.m2/repository`, `~/.gradle/caches`, `~/.gradle/wrapper/dists`, `~/.npm/_cacache`, `~/Library/Caches/pip`, `~/Library/Caches/Homebrew` |
| Xcode | each `~/Library/Developer/Xcode/DerivedData/*`, with its project read from `info.plist` |

A folder called `target` without `pom.xml` or `Cargo.toml`, or an `env` folder without `pyvenv.cfg`, is not flagged. The self-test checks this.

**Last activity** is the newest of three dates:
- Project files modified (depth ≤ 3, excluding artifact folders).
- Git activity (`.git/logs/HEAD` or `.git/index`).
- Newest item inside the artifact.

The column shows which one it used. It is based on modifications because APFS rarely updates access times, and listing a folder updates the folder's own access time. RESEARCH.md §3 has the details.

**Reclaimable** counts only files with a single link, using APFS private size. So pnpm-style hard links and clone-shared blocks aren't promised as freed space.

### Deletion guard

This lives in `DeletionGuard`/`Deleter` in the core library. Every delete path goes through it, not just the UI. Deletion is refused for:
- `/System`, `/usr` (except `/usr/local/*`), `/bin`, `/sbin`, `/Library`, `/private` (so also `/etc`, `/var`, `/tmp`).
- SIP-protected or immutable items.
- Mount points and volume roots, `/Users`, `/Applications`, and your home folder itself.
- Anything not owned by you.

Symlinks are judged by the link's real parent folder, and `/System/Volumes/Data/...` by its firmlinked location. A disabled delete button shows the reason on hover.

## Measured footprint

Measured on an M4 Pro running macOS 26.6.1 with `./scripts/measure.sh`, release build, 2.7 MB binary. CPU is a percentage of one core and includes the `ps`/`netstat` child processes. Memory is the physical footprint (what Activity Monitor shows).

| State | CPU | Memory |
|---|---|---|
| **Background** (window closed, menu bar only, 5 s refresh; the normal idle state) | **0.31 %** | **24 MB** |
| Window open on Dashboard (3 s refresh, 11 charts) | ~1.3 % steady (2.1 % over a 140 s run including launch) | 61–65 MB (182 MB peak during the first render) |
| Window open on Processes (~740 rows) | ~2.2–2.7 % | ~90–120 MB |
| Window open on Heat & Battery | ~1.5 % | — |
| Window open on Ports | ~0.9 % | — |
| Window open on Settings | ~0.3 % | — |
| **Full home-folder scan** (173 GB: 289k folders, 2.05M files; no cache) | 12–13 s | **105 MB peak** (app with window). The scan core alone peaks at 51 MB. |
| Incremental rescan of the same tree | 0.96 s (re-read 5 of 289k folders) | — |
| Developer-artifact scan of home (89 items, 37 GB) | 11.9 s | 13 MB peak (scan core) |

Notes:
- The window-open numbers use `--assume-visible` because the display may be asleep during automated runs. The rendering cost on an awake, visible screen is unverified.
- One of six Processes runs showed a short burst to about 10 %. I did not find the cause.
- The biggest cost with the window open is SwiftUI `Table` diffing about 740 rows every refresh. The sampler itself uses under 1 %.
- The Dashboard's sparklines are drawn as plain paths rather than charts. That cut its memory from 175 MB to about 61 MB.
- Closing the window drops the process list and the scan tree from memory. The tree is reloaded from the on-disk cache when needed.

## How it works

The core library is `Sources/MacLensCore`; the app is `Sources/MacLens`.

| Signal | Source | Root? |
|---|---|---|
| Own processes: CPU, memory, energy | `proc_pid_rusage` (CPU time, `phys_footprint`, `ri_energy_nj`, wakeups) | no |
| Other users' processes | `sysctl KERN_PROC_ALL` for identity, `proc_pidpath` for path, setuid `/bin/ps` for CPU/RSS; energy estimated as CPU × W/core, calibrated from your processes ("~") | no |
| Temperatures | IOHIDEventSystem sensors (private symbols, resolved at runtime) | no |
| Fans | SMC read (`FNum`, `F<n>Ac`) | no |
| Battery watts / time | Battery flow = measured current × voltage. System draw: on battery, `PowerTelemetryData.SystemLoad`; on power, adapter input − charging power − adapter loss. The telemetry's `BatteryPower` field reads "discharging" while charging, so it's ignored. Time from IOPowerSources. | no |
| Awake blockers | `IOPMCopyAssertionsByProcess` | no |
| Updates | `api.github.com/repos/amrakshay/maclens/releases/latest` (unauthenticated, once a day). Downloads are accepted only from this repo's release assets and verified with SHA-256 + `codesign --verify`. | no |
| Battery health | `system_profiler SPPowerDataType -json` every 10 min (~0.05 s CPU) for Apple's maximum-capacity % and condition; cycles and mAh from `AppleSmartBattery`. The raw mAh ratio and the power-source API's `BatteryHealth` key disagree with System Settings, so they aren't used for the verdict. | no |
| Ports | `netstat -anv`, which carries the PID of every socket; `lsof` would only see your own | no |
| Machine CPU / memory | `host_statistics` (`HOST_CPU_LOAD_INFO`, `HOST_VM_INFO64`), `vm.swapusage` | no |
| Disk sizes | `getattrlistbulk` (allocated/logical size, link count, file ID; never follows symlinks; stays on one volume), bounded thread pool, FSEvents history for rescans | no |

Only your own processes' arguments and exact energy are readable without root. Other users' arguments show as "not visible without root". A privileged helper could add them, but none is included.

Debug flags:
- `--snapshot DIR` renders each tab of the window to PNGs, then quits.
- `--tab NAME` opens a specific tab.
- `--assume-visible` treats the window as on-screen.
- `--autoscan-home` starts a home scan at launch.

## Contributing

Issues and PRs are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md), and [SECURITY.md](SECURITY.md) for reporting safety problems privately. Releases are automated with release-please; see [docs/RELEASING.md](docs/RELEASING.md).

## License

[MIT](LICENSE)
