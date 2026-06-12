# Releasing

How to cut a new release of **neomouse**.

## TL;DR

Push a tag and let CI do it:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

The [`Release` workflow](.github/workflows/release.yml) builds the universal
binary, signs, packages, publishes the GitHub Release, and bumps `flake.nix` +
the Homebrew tap. Or cut it locally (needs full Xcode + `gh` + push access):

```sh
scripts/release.sh v0.1.0
```

…done. Tag is pushed, the **universal** (arm64 + x86_64) binary is built and
signed, and a GitHub Release is published with the `.tar.gz` and `.sha256`
attached.

## Prerequisites

One-time setup on the machine doing the release:

| Requirement | Check | Install |
|---|---|---|
| `gh` CLI, authenticated | `gh auth status` | `brew install gh && gh auth login` |
| **Full Xcode** (not just Command Line Tools) | `xcrun --show-sdk-path` resolves under `Xcode.app` | Install Xcode, then `sudo xcode-select -s /Applications/Xcode.app` |
| Swift 6.3+ toolchain | `swift --version` | Xcode 16 or Swift toolchain |
| `nix` (for the flake.nix hash bump) | `nix --version` | https://nixos.org/download |
| Push access to the repo | `git push --dry-run origin main` | Be added as a collaborator |

The script will refuse to run if any of these are missing.

> **Full Xcode is required** because the release is a universal binary built
> with `swift build --arch arm64 --arch x86_64` — the x86_64 macOS SDK slice
> ships only with full Xcode, not the bare Command Line Tools. (CI uses the
> `macos-15` runner, which has full Xcode.)

## Versioning

Semver — `vMAJOR.MINOR.PATCH`:

- `v0.0.x` — pre-MVP, breaking changes anytime.
- `v0.x.0` — feature releases on the way to a stable v1.
- `vMAJOR.0.0` (≥1) — stable; bump when the keymap / behavior changes incompatibly.

The script accepts either `v0.1.0` or bare `0.1.0` — it normalizes.

## What the script does

`scripts/release.sh` runs these steps top-to-bottom and aborts on the first failure:

1. **Preconditions** — `gh` authed, on `main`, working tree clean, `main` in sync with `origin/main`, tag doesn't already exist locally or on origin. (Skipped under `SKIP_TAG=1` — see below.)
2. **Build** — `swift build -c release --arch arm64 --arch x86_64` → a universal `.build/release/neomouse`. `lipo -archs` is then asserted to contain **both** `arm64` and `x86_64`; the script aborts if either slice is missing.
3. **Sign** — ad-hoc codesign (`codesign --sign -`). Required for the binary to run on Apple Silicon without `SIGKILL`. Does **not** mark it as Developer-ID signed.
4. **Package** — `dist/neomouse-<VERSION>-macos-universal.tar.gz` plus a `.sha256` file.
5. **Tag** — annotated tag pushed to `origin`.
6. **Release** — `gh release create` with the archive + checksum attached. Release notes are auto-generated from `git log <prev-tag>..<this-tag>`.
7. **Homebrew tap bump** — clones `KangaZero/homebrew-neomouse`, rewrites `Formula/neomouse.rb`'s `url` / `sha256` / `version` to the new release, commits as `neomouse <VERSION>`, and pushes. Skip with `SKIP_HOMEBREW=1 scripts/release.sh ...`.
8. **Flake bump** — rewrites the in-repo `flake.nix` `version` + `hash` (SRI-encoded SHA-256) to the new release, commits as `flake: bump to <VERSION>`, and pushes to `origin/main`. So `nix run github:KangaZero/neomouse` always tracks latest. Skip with `SKIP_FLAKE=1`.

Order matters: local artifacts and the tag are produced before anything is pushed remotely, so a failure in the build won't leave you with a dangling tag on GitHub. The Homebrew + flake bumps run last so they only fire when the release assets are confirmed published.

## Recovering from a failed release

| Where it failed | Recovery |
|---|---|
| Preconditions / build / sign / package | Fix the issue and rerun. Nothing on the remote was changed. |
| After `git push origin <tag>` but before `gh release create` | Delete and rerun: `git tag -d <tag> && git push origin :<tag>` then rerun the script. |
| Release created but assets wrong | `gh release upload <tag> <file> --clobber` to replace, or `gh release delete <tag>` and rerun. |
| Release created but Homebrew bump failed | The script can't rerun cleanly because the tag now exists. Fix the tap manually: `git clone git@github.com:KangaZero/homebrew-neomouse`, edit `Formula/neomouse.rb` (url, sha256, version), commit and push. Or rerun the script with `SKIP_HOMEBREW=1` after deleting the tag, but that's heavier than just patching the formula. |

## Releasing from GitHub Actions

The [`Release` workflow](.github/workflows/release.yml) is the preferred path —
it runs on the `macos-15` runner (full Xcode, so the x86_64 slice is always
reproducible) and reuses `scripts/release.sh` verbatim.

**To cut a release:** push a `v*` tag.

```sh
git tag v0.1.0 && git push origin v0.1.0
```

The workflow checks out `main`, then runs `SKIP_TAG=1 scripts/release.sh v0.1.0`:

- **`SKIP_TAG=1`** — the tag already exists (it's what triggered the run), so
  the script skips tag creation and the on-`main` / clean-tree / origin-sync
  preconditions. The script *verifies* the tag exists and aborts otherwise.
- It checks out `main` (not the detached tag) so the `flake.nix` bump can be
  committed and pushed back to `main`. The tag points at `main`'s tip, so the
  built content is identical.
- After publishing, the workflow runs `nix build .#default` to prove the flake
  builds against the freshly-uploaded universal tarball.

**Required repo secret:**

| Secret | What | Why |
|---|---|---|
| `HOMEBREW_TAP_TOKEN` | Fine-grained PAT with `contents: write` on `KangaZero/homebrew-neomouse` | The built-in `GITHUB_TOKEN` can only push to *this* repo, not the separate tap. If the secret is unset, the workflow skips the Homebrew bump (warns) and you bump the tap by hand. |

`manual` reruns: use **Run workflow** (`workflow_dispatch`) and pass the existing
tag in the `tag` input.

## Limitations & future work

- **Ad-hoc signed, not notarized.** Users have to run `xattr -dr com.apple.quarantine ./neomouse` after downloading. To skip that for end users you'd need to:
  1. Enroll in the Apple Developer Program ($99/yr).
  2. Get a *Developer ID Application* cert into your keychain.
  3. Replace the signing step with `codesign --sign "Developer ID Application: …" --options runtime --timestamp`.
  4. Submit with `xcrun notarytool submit … --wait` and `xcrun stapler staple`.

  When you're ready, extend `scripts/release.sh` with these.
- **Tap formula `depends_on arch:`.** The first time you release a universal build, remove the stale `depends_on arch: :arm64` line from `Formula/neomouse.rb` in the `KangaZero/homebrew-neomouse` tap by hand — `scripts/release.sh` only rewrites the formula's `url` / `sha256` / `version`, not the arch constraint. (The in-repo prep copy at `scripts/release-v0.0.1-prep/neomouse.rb` is already updated.)

## Example session

```sh
$ scripts/release.sh v0.1.0

==> Checking preconditions
  branch: main
  commit: a5cd6f3
  tag:    v0.1.0

==> Building release binary (universal: arm64 + x86_64)
Build complete! (24.68s)
.build/release/neomouse: Mach-O universal binary with 2 architectures: [arm64] [x86_64]
  slices: arm64 x86_64

==> Ad-hoc signing
Format=Mach-O universal (arm64 x86_64)
Signature=adhoc

==> Packaging
neomouse-v0.1.0-macos-universal.tar.gz
  …  neomouse-v0.1.0-macos-universal.tar.gz.sha256

==> Tagging v0.1.0
To github.com:KangaZero/neomouse.git
 * [new tag]         v0.1.0 -> v0.1.0

==> Creating GitHub Release
https://github.com/KangaZero/neomouse/releases/tag/v0.1.0

==> Done
Release: https://github.com/KangaZero/neomouse/releases/tag/v0.1.0
```
