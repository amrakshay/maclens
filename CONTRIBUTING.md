# Contributing to MacLens

Thanks for helping! Bug reports, ideas and pull requests are all welcome.

## Before you start

- For anything bigger than a small fix, open an issue first so we can agree on the approach.
- MacLens has three design rules. Please keep them:
  - **No third-party dependencies.**
  - **No feature that requires root.**
  - **Stay light.** The app should use under ~1% CPU with the window closed.
- Read [CLAUDE.md](CLAUDE.md). It lists the architecture, the safety rules (deletion guard, kill policy) and the macOS gotchas we've already hit.

## Build and test

You need macOS 14+ on Apple Silicon and the Xcode Command Line Tools (Swift 6). Full Xcode isn't needed.

```bash
swift build
```

```bash
swift run maclens-selftest
```

```bash
./scripts/build-app.sh && open dist/MacLens.app
```

- The self-test must print `ALL CHECKS PASSED`.
- It works inside `./.selftest/` and never deletes anything outside it.
- Add a check for any new core behaviour, especially anything that deletes, kills processes or classifies files or processes.
- If your change affects sampling or UI refresh, run `./scripts/measure.sh` and put the numbers in the PR.

## Pull requests

- **Title:** use [Conventional Commits](https://www.conventionalcommits.org/), for example `feat: show GPU load`, `fix: ports list misses UDP`, `docs: …`, `chore: …`.
  - PRs are squash-merged, so the title becomes the commit message.
  - The title drives the changelog and version numbers: `feat` bumps minor, `fix` bumps patch, and `feat!` or a `BREAKING CHANGE:` footer bumps major.
- Keep each PR focused on one change.
- Update README.md in the same PR for anything user-visible.
- CI (build + self-test + packaging) must pass.

## Code style

- Match the code around your change.
- Core (`Sources/MacLensCore`) is UI-free and `public`. The app layer uses `@MainActor` stores.
- Label estimates as estimates, and say when something needs root. Don't show a guess as a fact.

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
