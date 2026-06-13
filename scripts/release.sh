#!/usr/bin/env bash
# Cut a new release of neomouse.
#
# Usage:
#   scripts/release.sh vX.Y.Z              # full release: tag, push, GitHub
#                                            Release, Homebrew + flake bumps
#   DRY_RUN=1 scripts/release.sh vX.Y.Z    # build + sign + package only;
#                                            stop before anything touches a
#                                            remote (no git tag, no gh release,
#                                            no formula bump, no flake push)
#   SKIP_HOMEBREW=1 scripts/release.sh …   # skip just the Homebrew tap bump
#   SKIP_FLAKE=1    scripts/release.sh …   # skip just the flake.nix bump
#   SKIP_TAG=1      scripts/release.sh …   # don't create/push the git tag, and
#                                            skip the branch / clean-tree /
#                                            origin-sync preconditions. Used by
#                                            the GitHub Actions release workflow,
#                                            which is itself *triggered by* a
#                                            pushed tag — so the tag already
#                                            exists and we must not re-create it.
#
# DRY_RUN is for `just release-local` / local end-to-end testing of the
# release tarball before cutting an actual release.
#
# The build is a UNIVERSAL Mach-O (arm64 + x86_64 via `swift build --arch …`),
# so the single tarball runs natively on both Apple Silicon and Intel Macs.
# `--arch` cross-slicing requires full Xcode (not just Command Line Tools).

set -euo pipefail
DRY_RUN="${DRY_RUN:-}"
SKIP_TAG="${SKIP_TAG:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

step() { printf "\n\033[1;34m==>\033[0m %s\n" "$1"; }
fail() {
  printf "\033[1;31merror:\033[0m %s\n" "$1" >&2
  exit 1
}

# ---------- args ----------

[[ $# -eq 1 ]] || fail "Usage: $0 vX.Y.Z"

VERSION="$1"
# accept either "0.1.0" or "v0.1.0"
[[ "$VERSION" =~ ^v ]] || VERSION="v$VERSION"
# Strict semver, with an optional pre-release suffix (`-rc1`, `-local`, etc.).
# The suffix path is useful for DRY_RUN test builds and for real RC releases.
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] ||
  fail "Version must be vX.Y.Z (optionally with -suffix); got: $VERSION"

# ---------- preconditions ----------

step "Checking preconditions"

command -v gh >/dev/null || fail "gh CLI not installed (brew install gh)"
command -v swift >/dev/null || fail "swift toolchain not found"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated (run: gh auth login)"

if [[ "$DRY_RUN" == "1" || "$SKIP_TAG" == "1" ]]; then
  echo "  $([ "$DRY_RUN" = "1" ] && echo DRY_RUN || echo SKIP_TAG): skipping branch / tag / origin-sync checks"
else
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  [[ "$BRANCH" == "main" ]] || fail "Not on main (on: $BRANCH)"

  [[ -z "$(git status --porcelain)" ]] || fail "Working tree is dirty. Commit or stash first."

  git rev-parse "$VERSION" >/dev/null 2>&1 && fail "Tag $VERSION already exists locally."
  git ls-remote --exit-code --tags origin "$VERSION" >/dev/null 2>&1 &&
    fail "Tag $VERSION already exists on origin."

  git fetch --quiet origin
  [[ "$(git rev-parse main)" == "$(git rev-parse origin/main)" ]] ||
    fail "Local main differs from origin/main. Pull or push first."
fi

echo "  branch: $(git rev-parse --abbrev-ref HEAD)"
echo "  commit: $(git rev-parse --short HEAD)"
echo "  tag:    $VERSION$([ "$DRY_RUN" = "1" ] && echo "  (DRY_RUN — not actually tagged)")$([ "$SKIP_TAG" = "1" ] && echo "  (SKIP_TAG — tag assumed to already exist)")"

# ---------- build ----------

step "Building release binary (universal: arm64 + x86_64)"
# `--arch arm64 --arch x86_64` produces a single fat Mach-O so the one tarball
# runs natively on both Apple Silicon and Intel. Needs full Xcode for the
# x86_64 macOS SDK slice; bare Command Line Tools can't cross-slice.
swift build -c release --arch arm64 --arch x86_64

# A multi-`--arch` build does NOT populate the `.build/release` symlink (that
# only exists for single-arch builds); the universal product lands under
# `.build/apple/Products/Release/`. Ask SwiftPM for the real path rather than
# hardcoding it — `--show-bin-path` resolves without rebuilding.
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/neomouse"
[[ -x "$BIN" ]] || fail "Build did not produce $BIN"
file "$BIN"

# Guard the universal contract — abort if either slice is missing rather than
# silently shipping a single-arch binary under the "-universal" name.
ARCHS="$(lipo -archs "$BIN")"
echo "  slices: $ARCHS"
[[ "$ARCHS" == *arm64* ]] || fail "Binary is missing the arm64 slice (got: $ARCHS)"
[[ "$ARCHS" == *x86_64* ]] || fail "Binary is missing the x86_64 slice (got: $ARCHS) — full Xcode required for cross-slicing"

# ---------- assemble .app wrapper ----------
#
# SwiftUI's MenuBarExtra status item only registers when LaunchServices can
# read CFBundleIdentifier from .app/Contents/Info.plist — embedding the same
# plist into the Mach-O's __TEXT,__info_plist section is not sufficient
# (lsappinfo reports CFBundleIdentifier=NULL for bare-binary processes).
# We ship a .app bundle so brew/nix/manual install paths all get a working
# status item out of the box.

step "Assembling neomouse.app"
APP_STAGE="dist/build"
APP_DIR="$APP_STAGE/neomouse.app"
rm -rf "$APP_STAGE"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp Info.plist "$APP_DIR/Contents/Info.plist"
# Ships the default config inside the bundle so first launch can auto-deploy
# it to ~/.config/neomouse/settings.toml. See deployBundledDefaultsIfMissing
# in Sources/neomouse/NeoMouseApp.swift.
cp settings.toml "$APP_DIR/Contents/Resources/settings.toml"
cp "$BIN" "$APP_DIR/Contents/MacOS/neomouse"

# ---------- sign ----------

step "Ad-hoc signing the bundle"
# --deep signs the nested binary plus the bundle itself. Ad-hoc (signer "-")
# means no Developer ID — users still have to `xattr -dr com.apple.quarantine`
# on a manual download to clear Gatekeeper; brew/nix install paths handle
# this for the user.
codesign --sign - --force --options runtime --timestamp=none --deep "$APP_DIR"
codesign -dv "$APP_DIR" 2>&1 | grep -E "Signature|Format|Identifier" || true

# ---------- package ----------

step "Packaging"
mkdir -p dist
ARCHIVE_NAME="neomouse-${VERSION}-macos-universal.tar.gz"
ARCHIVE="dist/$ARCHIVE_NAME"

# Archive contains `neomouse.app/` at the top level (Contents/Info.plist,
# Contents/MacOS/neomouse). Extraction lands the .app in the user's cwd.
tar -czf "$ARCHIVE" -C "$APP_STAGE" "neomouse.app"
(cd dist && shasum -a 256 "$ARCHIVE_NAME" | tee "$ARCHIVE_NAME.sha256")

ls -la "$ARCHIVE" "$ARCHIVE.sha256"

# Values reused by the Homebrew + flake bump steps below.
HASH_HEX="$(awk '{print $1}' "$ARCHIVE.sha256")"
ASSET_URL="https://github.com/KangaZero/neomouse/releases/download/${VERSION}/${ARCHIVE_NAME}"
BARE_VERSION="${VERSION#v}"

# ---------- dry-run short-circuit ----------
#
# Everything above produces local artifacts (the .app bundle, the tarball,
# the .sha256). Everything below touches a remote — tagging, pushing,
# creating a GitHub Release, bumping the Homebrew tap, bumping flake.nix.
# DRY_RUN stops here so you can test the local artifacts before committing
# to a real release.
if [[ "$DRY_RUN" == "1" ]]; then
  step "DRY_RUN: skipping tag, push, gh release, Homebrew + flake bumps"
  echo
  echo "Local artifacts:"
  echo "  $ARCHIVE"
  echo "  $ARCHIVE.sha256"
  echo
  echo "Try it locally:"
  echo "  TEMP=\$(mktemp -d)"
  echo "  tar -xzf $ARCHIVE -C \"\$TEMP\""
  echo "  xattr -dr com.apple.quarantine \"\$TEMP/neomouse.app\""
  echo "  open \"\$TEMP/neomouse.app\""
  echo "  # then: look for the cursor icon in your menu bar"
  exit 0
fi

# ---------- tag + push ----------

if [[ "$SKIP_TAG" == "1" ]]; then
  step "Skipping tag creation (SKIP_TAG=1 — workflow was triggered by this tag)"
  git rev-parse "$VERSION" >/dev/null 2>&1 || fail "SKIP_TAG=1 but tag $VERSION does not exist"
else
  step "Tagging $VERSION"
  git tag -a "$VERSION" -m "$VERSION"
  git push origin "$VERSION"
fi

# ---------- release notes ----------

PREV_TAG="$(git describe --tags --abbrev=0 "$VERSION^" 2>/dev/null || true)"
if [[ -n "$PREV_TAG" ]]; then
  RANGE="$PREV_TAG..$VERSION"
  CHANGES_HEADER="Changes since $PREV_TAG"
else
  RANGE="$(git rev-list --max-parents=0 HEAD)..$VERSION"
  CHANGES_HEADER="Changes"
fi

NOTES_FILE="$(mktemp)"
trap 'rm -f "$NOTES_FILE"' EXIT

cat >"$NOTES_FILE" <<EOF
## Install

1. Download \`$ARCHIVE_NAME\` below.
2. Extract:
   \`\`\`sh
   tar -xzf $ARCHIVE_NAME
   \`\`\`
   This expands a \`neomouse.app\` bundle in your current directory.
3. Remove macOS download quarantine (the bundle is ad-hoc signed, not Developer ID signed):
   \`\`\`sh
   xattr -dr com.apple.quarantine ./neomouse.app
   \`\`\`
4. Launch it — any of these works:
   \`\`\`sh
   open ./neomouse.app                       # standard
   ./neomouse.app/Contents/MacOS/neomouse    # keeps stdout in your terminal
   \`\`\`
   …or double-click \`neomouse.app\` in Finder. Grant Accessibility permissions on first launch (macOS will prompt). Optional: drag \`neomouse.app\` into \`/Applications\` to keep it around.

## Verify

\`\`\`sh
shasum -a 256 -c $ARCHIVE_NAME.sha256
\`\`\`

## $CHANGES_HEADER

$(git log --pretty=format:'- %s' "$RANGE")

## Platform

macOS 14+. Universal binary — runs natively on Apple Silicon **and** Intel Macs.
EOF

# ---------- gh release ----------

step "Creating GitHub Release"
gh release create "$VERSION" \
  --title "$VERSION" \
  --notes-file "$NOTES_FILE" \
  "$ARCHIVE" "$ARCHIVE.sha256"

URL="$(gh release view "$VERSION" --json url -q .url)"

# ---------- bump homebrew tap ----------

if [[ "${SKIP_HOMEBREW:-}" == "1" ]]; then
  step "Skipping Homebrew tap bump (SKIP_HOMEBREW=1)"
else
  step "Bumping Homebrew formula in KangaZero/homebrew-neomouse"

  TAP_DIR="$(mktemp -d)"
  # Append tap-dir cleanup to the existing trap (which removes NOTES_FILE).
  trap 'rm -f "$NOTES_FILE"; rm -rf "$TAP_DIR"' EXIT

  # Locally we push over SSH (your key). In CI there's no SSH key, so when
  # HOMEBREW_TAP_TOKEN is set (a PAT with contents:write on the tap repo —
  # github.token can't push to a *different* repo) clone/push over HTTPS with
  # the token embedded. The token is only ever in this short-lived URL string.
  if [[ -n "${HOMEBREW_TAP_TOKEN:-}" ]]; then
    TAP_REMOTE="https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/KangaZero/homebrew-neomouse.git"
  else
    TAP_REMOTE="git@github.com:KangaZero/homebrew-neomouse.git"
  fi

  git clone --quiet --depth 1 "$TAP_REMOTE" "$TAP_DIR"

  FORMULA="$TAP_DIR/Formula/neomouse.rb"
  [[ -f "$FORMULA" ]] || fail "Formula not found at $FORMULA in cloned tap"

  # BSD sed (macOS) — anchor each replacement to the field it should match.
  sed -i.bak \
    -e "s|^  url \".*\"|  url \"$ASSET_URL\"|" \
    -e "s|^  sha256 \".*\"|  sha256 \"$HASH_HEX\"|" \
    -e "s|^  version \".*\"|  version \"$BARE_VERSION\"|" \
    "$FORMULA"
  rm -f "$FORMULA.bak"

  grep -q "$ASSET_URL" "$FORMULA" || fail "Formula url did not update"
  grep -q "$HASH_HEX" "$FORMULA" || fail "Formula sha256 did not update"
  grep -q "$BARE_VERSION" "$FORMULA" || fail "Formula version did not update"

  if git -C "$TAP_DIR" diff --quiet -- Formula/neomouse.rb; then
    echo "Formula already at $VERSION; nothing to push."
  else
    git -C "$TAP_DIR" add Formula/neomouse.rb
    git -C "$TAP_DIR" -c user.email="$(git config user.email)" \
      -c user.name="$(git config user.name)" \
      commit -q -m "neomouse $VERSION"
    git -C "$TAP_DIR" push --quiet origin HEAD
    echo "Pushed formula bump to homebrew-neomouse."
  fi
fi

# ---------- bump in-repo flake.nix ----------

if [[ "${SKIP_FLAKE:-}" == "1" ]]; then
  step "Skipping flake.nix bump (SKIP_FLAKE=1)"
elif [[ ! -f flake.nix ]]; then
  step "No flake.nix in repo; skipping flake bump"
else
  step "Bumping in-repo flake.nix"

  command -v nix >/dev/null || fail "nix not found; can't compute SRI hash"
  SRI_HASH="$(nix hash convert --hash-algo sha256 --to sri "$HASH_HEX")"

  sed -i.bak \
    -e "s|version = \".*\";|version = \"$BARE_VERSION\";|" \
    -e "s|hash = \"sha256-.*\";|hash = \"$SRI_HASH\";|" \
    flake.nix
  rm -f flake.nix.bak

  grep -q "version = \"$BARE_VERSION\";" flake.nix || fail "flake.nix version did not update"
  grep -q "$SRI_HASH" flake.nix || fail "flake.nix hash did not update"

  if git diff --quiet -- flake.nix; then
    echo "flake.nix already at $VERSION; nothing to commit."
  else
    git add flake.nix
    git commit -q -m "flake: bump to $VERSION"
    git push --quiet origin main
    echo "Pushed flake.nix bump to origin/main."
  fi
fi

step "Done"
echo "Release: $URL"
