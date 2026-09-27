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
   2. on `macos-26`, runs the self-test and builds `MacLens.app` (version from `version.txt`, build number = CI run number, ad-hoc signed);
   3. packages `MacLens-X.Y.Z.zip` and its `.sha256`, attests build provenance, and uploads them to the release;
   4. writes `Casks/maclens.rb` (new version + SHA-256) to `amrakshay/homebrew-tap`, so `brew upgrade` picks it up.

Users can check that a download was built by this repo's CI with `gh attestation verify MacLens-X.Y.Z.zip --repo amrakshay/maclens`.

The first release (1.0.0) was pinned with `"release-as"` in `release-please-config.json`; that pin has since been removed, so versions now follow the commits.

## One-time setup

**Repository settings:**
- Settings → Actions → General → Workflow permissions: **Read and write**, and tick **Allow GitHub Actions to create and approve pull requests** (release-please needs this).
- Settings → General → Pull Requests: allow **squash merging** only, with the default commit message set to "Pull request title".
- Settings → Rules → Rulesets: protect `main`. Require a PR, require the `build-and-test` status check, and block force pushes and deletion.
- Settings → Code security: enable **Private vulnerability reporting**, **Secret scanning** and **Push protection**. Dependabot alerts are optional.

**Homebrew tap:** see [Homebrew tap setup](#homebrew-tap-setup) below.

## Homebrew tap setup

MacLens is distributed through its own tap, `amrakshay/homebrew-tap`. The main `homebrew/cask` repo only accepts notarized apps, and MacLens deliberately isn't notarized.

One-time setup:
1. **Create the tap repo.** On GitHub, create a **public** repo named exactly **`homebrew-tap`** under `amrakshay`. Homebrew maps `amrakshay/tap` to `github.com/amrakshay/homebrew-tap`. Initialise it with a README.
2. **Create a token for CI.** GitHub → Settings → Developer settings → Fine-grained personal access tokens → Generate new token:
   - Resource owner: `amrakshay`. Expiration: up to 1 year (put a reminder in your calendar).
   - Repository access: **Only select repositories → `homebrew-tap`**.
   - Repository permissions: **Contents → Read and write**. Metadata read-only is added automatically.
3. **Store the token.** In **this** repo (`maclens`): Settings → Secrets and variables → Actions → New repository secret → name **`HOMEBREW_TAP_TOKEN`**, value = the token.
4. **Publish the current release once.** Actions → **Publish Homebrew cask** → Run workflow → tag `v1.0.0`. Every release after that updates the cask automatically in `release.yml`.

Users then install and update with:

```bash
brew install --cask amrakshay/tap/maclens
```

```bash
brew upgrade --cask maclens
```

**When the token expires:** the Release workflow's "Update Homebrew tap" step fails. Create a new token and update the secret, then re-run **Publish Homebrew cask** for the latest tag.

The cask comes from `scripts/make-cask.sh`, and `scripts/publish-cask.sh` pushes it. To change the cask (description, caveats, `depends_on`), edit `make-cask.sh`; the next release carries the change.

**Gatekeeper:** releases are ad-hoc signed and not notarized. That's free, with no Apple Developer Program. As a result, macOS blocks the first launch until the user clicks **Open Anyway** under System Settings → Privacy & Security. The cask's caveats and the README say so. Homebrew no longer offers a way to skip quarantine, so this step is expected.

## Building a release locally

This writes into `dist/` only:

```bash
./scripts/build-app.sh && ./scripts/package-release.sh
```
