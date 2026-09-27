# Releasing MacLens

Releases are automated. You merge pull requests, and CI handles versions, the changelog, the build and publishing.

## How a release happens

1. **Merge PRs to `main`** with [Conventional Commit](https://www.conventionalcommits.org/) titles. PRs are squash-merged, so the title becomes the commit.
   - `fix:` bumps the patch version.
   - `feat:` bumps the minor version.
   - `feat!:` or a `BREAKING CHANGE:` footer bumps the major version.
   - `docs:`, `chore:`, `ci:`, `refactor:` and `test:` don't trigger a release on their own.
2. **release-please** (`.github/workflows/release.yml`) opens or updates a PR titled `chore(main): release X.Y.Z`. That PR bumps `version.txt` and prepends the new entries to `CHANGELOG.md`.
3. **Merge that release PR** when you want to ship.
   - The PR is opened by the Actions bot, so GitHub holds its CI run. Open the PR's **Checks** tab and click **Approve and run workflows** so the required `build-and-test` check can pass.
   - If you'd rather not approve every time, give release-please a fine-grained personal access token (Contents + Pull requests: read/write on this repo) as the `token:` input. PRs it opens then trigger CI normally.
   - If the release PR ever shows conflicts (e.g. after editing CHANGELOG.md or version.txt on `main`), delete its branch `release-please--branches--main`. The next push to `main` regenerates the PR.

   After the merge, the workflow:
   1. tags `vX.Y.Z` and creates the GitHub Release with the changelog as notes;
   2. on `macos-26`, runs the self-test, builds `MacLens.app` (version from `version.txt`, build number = CI run number), and signs and notarizes it if the Apple secrets exist;
   3. packages `MacLens-X.Y.Z.zip` and its `.sha256`, attests build provenance, and uploads them to the release;
   4. updates `Casks/maclens.rb` in `amrakshay/homebrew-tap`, if its token secret exists.

Users can check that a download was built by this repo's CI with `gh attestation verify MacLens-X.Y.Z.zip --repo amrakshay/maclens`.

The first release is pinned to **1.0.0** by `"release-as": "1.0.0"` in `release-please-config.json`. **Remove that line after 1.0.0 ships**, otherwise every release PR proposes 1.0.0.

## One-time setup

**Repository settings:**
- Settings → Actions → General → Workflow permissions: **Read and write**, and tick **Allow GitHub Actions to create and approve pull requests** (release-please needs this).
- Settings → General → Pull Requests: allow **squash merging** only, with the default commit message set to "Pull request title".
- Settings → Rules → Rulesets: protect `main`. Require a PR, require the `build-and-test` status check, and block force pushes and deletion.
- Settings → Code security: enable **Private vulnerability reporting**, **Secret scanning** and **Push protection**. Dependabot alerts are optional.

**Homebrew tap (optional; release uploads work without it):**
1. Create a public repo `amrakshay/homebrew-tap` (empty, with a README).
2. Create a fine-grained personal access token with **Contents: read and write** on that repo only.
3. Add it to this repo: Settings → Secrets and variables → Actions → `HOMEBREW_TAP_TOKEN`.

After the next release, users install with:

```bash
brew install --cask amrakshay/tap/maclens
```

## Signing and notarization (optional, later)

Until these secrets exist, releases are ad-hoc signed. Users then have to allow the app once under System Settings → Privacy & Security → Open Anyway. Adding the secrets switches on Developer ID signing, the hardened runtime and notarization, with no workflow change needed.

These require the Apple Developer Program.

| Secret | What it is |
|---|---|
| `MACOS_CERT_P12` | "Developer ID Application" certificate plus private key, exported as .p12, base64-encoded (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERT_PASSWORD` | Password of that .p12 |
| `MACOS_SIGN_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `NOTARY_KEY_P8` | App Store Connect API key (.p8 contents), role Developer |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | Issuer ID from App Store Connect → Users and Access → Integrations |

The signing and notarization steps have not been run yet, because there are no certificates. Expect to debug them on the first signed release. The hardened runtime may need entitlements if something breaks under it; test locally with `MACLENS_HARDENED=1 MACLENS_SIGN_IDENTITY="…" ./scripts/build-app.sh`.

Once releases are notarized:
- The Gatekeeper caveat in `scripts/package-release.sh` can go.
- The app becomes eligible for the main `homebrew/cask` repo. That repo also needs notable popularity: at least 225 stars / 90 forks / 90 watchers when the author submits it.
- Sparkle auto-updates become worthwhile.

## Building a release locally

This writes into `dist/` only:

```bash
./scripts/build-app.sh && ./scripts/package-release.sh
```
