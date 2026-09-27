# CLAUDE.md

Guidance for AI coding assistants working on MacLens. User-facing documentation lives in README.md. The design rationale and the macOS API findings live in RESEARCH.md.

## What this is

MacLens is a native macOS monitor and disk cleaner for developers:
- Swift 6 / SwiftUI, macOS 14+, Apple Silicon.
- Built with **SwiftPM only**. There is no Xcode project, and it builds with just the Command Line Tools.
- **No third-party dependencies, and no feature may require root.** Keep it that way. If something truly needs root, propose an isolated, optional helper first.

## Layout

| Path | Contents |
|---|---|
| `Sources/MacLensCore/` | All system access and logic, UI-free and testable: processes, sensors, power/battery, ports, disk scanner, FSEvents, artifacts, deletion guard, caffeinate, battery alerts |
| `Sources/MacLens/` | SwiftUI app: `Engine` (background sampler), `Model` (stores, settings, notifier), views per tab, `DebugSnapshot` |
| `Sources/SelfTest/` | `maclens-selftest`, the test suite (see below) |
| `scripts/build-app.sh` | Release build → `dist/MacLens.app` (icon, Info.plist, codesign) |
| `scripts/measure.sh` | Footprint measurement |
| `scripts/make-icon.swift` | Generates `Resources/AppIcon.icns` |

## Commands

Build, release and test:

```bash
swift build
```

```bash
./scripts/build-app.sh
```

```bash
swift run maclens-selftest
```

- **Run the self-test after any core change.** It must print `ALL CHECKS PASSED`.
- `swift run maclens-selftest --scan PATH` and `swift run maclens-selftest --artifacts PATH` do read-only scans of PATH and print timings.
- `./scripts/measure.sh` reports CPU and memory for idle, open-window and scan states. Re-run it after anything that touches sampling or UI refresh, and update the README's footprint table with the real numbers.
- **Swift Testing and XCTest are not available** with the Command Line Tools, which is why tests are a plain executable.

## Verifying UI changes

Screen capture usually isn't permitted, so the app renders itself:
- `MacLens --snapshot DIR` writes one PNG per tab, then quits. It uses `--assume-visible` behaviour.
- Content inside SwiftUI `ScrollView`, and AppKit-backed controls, may be missing from the window capture. For the Heat & Battery and Dashboard content, look at `heat-content.png` and `dashboard-content.png`, which `ImageRenderer` produces. Yellow boxes there are placeholders for AppKit controls, not bugs.

Other flags:
- `--tab NAME` opens a specific tab.
- `--background` launches without opening the window.
- `--autoscan-home` and `--autoscan-artifacts` start scans at launch.
- `DASH_WAIT=<s>` sets how long snapshot mode waits on the Dashboard.

## Rules that must not regress

- **Deletion goes through `DeletionGuard` / `Deleter` in the core**, never `FileManager` directly from the UI.
  - The guard blocks system paths, SIP-protected items, other users' files, mount points and home/top-level folders.
  - Trash is the default. Permanent delete is a separate, explicit action.
- **Never delete anything outside a test directory during development.** The self-test uses `./.selftest/run-*` and sets `MACLENS_DELETE_SANDBOX` (the Deleter refuses paths outside it) and `MACLENS_CACHE_DIR`. Tests must not touch the real app cache (`~/Library/Caches/dev.maclens`).
- **Kill safety:**
  - `ProcessControl.policy` refuses critical processes and other users' processes.
  - System components require an explicit warning.
  - Identity is re-checked by `ProcKey` (PID + start time) before signalling.
- **Lightweight is a feature:**
  - Background (window closed) must stay under ~1% CPU of one core.
  - Poll expensive sources (`ps`, `netstat`, temperatures, `system_profiler`) only when their view is visible, or at long intervals.
  - Avoid many Swift `Chart` instances; draw sparklines as `Path`.
- **Honest data:**
  - Label estimates (`~`) and state what needs root.
  - Don't present unverified numbers as fact.

## Hard-won gotchas

- **Per-process energy:** use `ri_energy_nj`. `ri_billed_energy` stays about 0 for most processes.
- **Other users' processes:** libproc calls return EPERM. CPU and RSS come from setuid `/bin/ps`. Only `proc_pidpath` and `kinfo_proc` work.
- **Battery on AC:** `PowerTelemetryData.BatteryPower` reads "discharging" while charging.
  - Battery flow comes from `InstantAmperage × Voltage`.
  - System draw on AC is `SystemPowerIn − charging − AdapterEfficiencyLoss`.
  - Registry integers are unsigned; convert negatives with `Int64(bitPattern:)`.
- **Battery health:** only `system_profiler SPPowerDataType -json` matches System Settings. The raw mAh ratio doesn't, and the power-source API's `BatteryHealth` key has said "Check Battery" while Settings said "Normal".
- **Ports:** `netstat -anv` carries PIDs for every socket without root; `lsof` doesn't. Process names in netstat output can contain spaces.
- **atime** is useless on APFS for "last used". Listing a folder updates the folder's own access time.
- **Disk rescans:** FSEvents history drives incremental rescans. Tests must sleep ~1.5 s after writes so events get IDs before the baseline scan.
- **Hard links:** attributed after traversal, with `ScanTree.linkOwners` persisted in the cache. This avoids double counting on rescans.
- **SwiftUI:** a `Table` nested inside a `ScrollView` collapses. `GroupBox` content doesn't appear in layer captures, which is why `Panel` is used.
- **Signing:** TCC (Full Disk Access) grants are tied to the code signature, so ad-hoc builds lose FDA on every rebuild.

## Workflow (mandatory)

1. **Issue first.** Before starting any work, check GitHub for an issue covering it:

   ```bash
   gh issue list -R amrakshay/maclens --state all --search "<keywords>"
   ```

   If there isn't one, create it first with `gh issue create`. Give it a Conventional-Commit-style title, the problem, the proposal and acceptance criteria. Then start.
2. **Never commit or push to `main`.** Branch from an up-to-date `main` as `<type>/<issue>-<slug>`, e.g. `feat/5-update-checker`. Open a PR with `gh pr create` and `Closes #N` in the body. The PR title is a Conventional Commit, since it becomes the squash commit and the changelog entry.
3. **CI must pass before merge:** `build-and-test` covers build, self-test, version check and cask lint. The maintainer merges, with squash.
   - CodeQL doesn't run on PRs, because a scan takes about 15 minutes. It runs on `main`, weekly, and on demand via Actions → CodeQL → Run workflow. Run it on the branch before merging anything security-sensitive (deletion guard, kill policy, updater).
4. **Don't merge release-please's release PRs yourself.** They're how releases ship; the maintainer merges them.

## Releases and commits

- **Commit messages and PR titles are [Conventional Commits](https://www.conventionalcommits.org/)** (`feat:`, `fix:`, `docs:`, `chore:`, `ci:`, …). release-please derives the version and CHANGELOG from them.
- **Never edit `version.txt` or released CHANGELOG sections by hand.** The release PR does that.
- Distribution is **GitHub Releases + the `amrakshay/homebrew-tap` cask only**. Releases are ad-hoc signed; there is no paid Apple signing or notarization by design, so don't add it.
- The cask comes from `scripts/make-cask.sh`, and `scripts/publish-cask.sh` pushes it to the tap.
- Full flow, secrets and one-time setup: [docs/RELEASING.md](docs/RELEASING.md).
- The version is never edited by hand. `scripts/check-version.sh` fails CI or a release if the app, zip, cask and tag disagree with `version.txt`.
- The app checks GitHub Releases for updates (`Updater` in core, `UpdateStore` in the app). Release assets must keep the names `MacLens-X.Y.Z.zip` and `.zip.sha256`, because the updater and the cask depend on them.
- CI runs on `macos-26`. The self-test skips hardware checks when `CI` is set, so any new hardware-dependent check must use `hardwareCheck`.

## Conventions

- Match the surrounding code's density and naming. Core types are `public`; the app target uses `@MainActor` stores.
- Add a self-test check for new core behaviour, especially anything that deletes, kills or classifies.
- Update README.md in the same change as any user-visible feature. Update RESEARCH.md if an API finding changes.
