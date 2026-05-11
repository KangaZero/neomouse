# Releasing

How to cut a new release of **neomouse**.

## TL;DR

```sh
scripts/release.sh v0.1.0
```

…done. Tag is pushed, binary is built and signed, and a GitHub Release is published with the `.tar.gz` and `.sha256` attached.

## Prerequisites

One-time setup on the machine doing the release:

| Requirement | Check | Install |
|---|---|---|
| `gh` CLI, authenticated | `gh auth status` | `brew install gh && gh auth login` |
| Swift 6.3+ toolchain | `swift --version` | Xcode 16 or Swift toolchain |
| Push access to the repo | `git push --dry-run origin main` | Be added as a collaborator |

The script will refuse to run if any of these are missing.

## Versioning

Semver — `vMAJOR.MINOR.PATCH`:

- `v0.0.x` — pre-MVP, breaking changes anytime.
- `v0.x.0` — feature releases on the way to a stable v1.
- `vMAJOR.0.0` (≥1) — stable; bump when the keymap / behavior changes incompatibly.

The script accepts either `v0.1.0` or bare `0.1.0` — it normalizes.

## What the script does

`scripts/release.sh` runs these steps top-to-bottom and aborts on the first failure:

1. **Preconditions** — `gh` authed, on `main`, working tree clean, `main` in sync with `origin/main`, tag doesn't already exist locally or on origin.
2. **Build** — `swift build -c release` → `.build/release/neomouse`.
3. **Sign** — ad-hoc codesign (`codesign --sign -`). Required for the binary to run on Apple Silicon without `SIGKILL`. Does **not** mark it as Developer-ID signed.
4. **Package** — `dist/neomouse-<VERSION>-macos-arm64.tar.gz` plus a `.sha256` file.
5. **Tag** — annotated tag pushed to `origin`.
6. **Release** — `gh release create` with the archive + checksum attached. Release notes are auto-generated from `git log <prev-tag>..<this-tag>`.

Order matters: local artifacts and the tag are produced before anything is pushed remotely, so a failure in the build won't leave you with a dangling tag on GitHub.

## Recovering from a failed release

| Where it failed | Recovery |
|---|---|
| Preconditions / build / sign / package | Fix the issue and rerun. Nothing on the remote was changed. |
| After `git push origin <tag>` but before `gh release create` | Delete and rerun: `git tag -d <tag> && git push origin :<tag>` then rerun the script. |
| Release created but assets wrong | `gh release upload <tag> <file> --clobber` to replace, or `gh release delete <tag>` and rerun. |

## Limitations & future work

- **Apple Silicon only.** A universal binary needs full Xcode (not just Command Line Tools) for SwiftPM's `--arch arm64 --arch x86_64`. Adding `--universal` to the script is a TODO.
- **Ad-hoc signed, not notarized.** Users have to run `xattr -dr com.apple.quarantine ./neomouse` after downloading. To skip that for end users you'd need to:
  1. Enroll in the Apple Developer Program ($99/yr).
  2. Get a *Developer ID Application* cert into your keychain.
  3. Replace the signing step with `codesign --sign "Developer ID Application: …" --options runtime --timestamp`.
  4. Submit with `xcrun notarytool submit … --wait` and `xcrun stapler staple`.

  When you're ready, extend `scripts/release.sh` with these.
- **Local only.** Releases are cut from a developer machine. You could move this to GitHub Actions (macOS runner, triggered on tag push) once the project warrants it — the existing script is structured so it'd port over cleanly.

## Example session

```sh
$ scripts/release.sh v0.1.0

==> Checking preconditions
  branch: main
  commit: a5cd6f3
  tag:    v0.1.0

==> Building release binary
Build complete! (12.34s)
.build/release/neomouse: Mach-O 64-bit executable arm64

==> Ad-hoc signing
Format=Mach-O thin (arm64)
Signature=adhoc

==> Packaging
neomouse-v0.1.0-macos-arm64.tar.gz
  …  neomouse-v0.1.0-macos-arm64.tar.gz.sha256

==> Tagging v0.1.0
To github.com:KangaZero/neomouse.git
 * [new tag]         v0.1.0 -> v0.1.0

==> Creating GitHub Release
https://github.com/KangaZero/neomouse/releases/tag/v0.1.0

==> Done
Release: https://github.com/KangaZero/neomouse/releases/tag/v0.1.0
```
