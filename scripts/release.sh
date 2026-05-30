#!/usr/bin/env bash
# Cut a new release of neomouse.
#
# Usage: scripts/release.sh vX.Y.Z
#
# Builds, ad-hoc signs, packages, tags, pushes, and publishes a GitHub Release,
# then bumps Formula/neomouse.rb in KangaZero/homebrew-neomouse to the new
# url/sha256/version and pushes that update.
#
# Set SKIP_HOMEBREW=1 to skip the Homebrew tap bump.

set -euo pipefail

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
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version must be vX.Y.Z (got: $VERSION)"

# ---------- preconditions ----------

step "Checking preconditions"

command -v gh >/dev/null || fail "gh CLI not installed (brew install gh)"
command -v swift >/dev/null || fail "swift toolchain not found"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated (run: gh auth login)"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || fail "Not on main (on: $BRANCH)"

[[ -z "$(git status --porcelain)" ]] || fail "Working tree is dirty. Commit or stash first."

git rev-parse "$VERSION" >/dev/null 2>&1 && fail "Tag $VERSION already exists locally."
git ls-remote --exit-code --tags origin "$VERSION" >/dev/null 2>&1 &&
  fail "Tag $VERSION already exists on origin."

git fetch --quiet origin
[[ "$(git rev-parse main)" == "$(git rev-parse origin/main)" ]] ||
  fail "Local main differs from origin/main. Pull or push first."

echo "  branch: main"
echo "  commit: $(git rev-parse --short HEAD)"
echo "  tag:    $VERSION"

# ---------- build ----------

step "Building release binary"
swift build -c release

BIN=".build/release/neomouse"
[[ -x "$BIN" ]] || fail "Build did not produce $BIN"
file "$BIN"

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
cp Info.plist "$APP_DIR/Contents/Info.plist"
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
ARCHIVE_NAME="neomouse-${VERSION}-macos-arm64.tar.gz"
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

# ---------- tag + push ----------

step "Tagging $VERSION"
git tag -a "$VERSION" -m "$VERSION"
git push origin "$VERSION"

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

macOS 14+, Apple Silicon only.
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

  git clone --quiet --depth 1 \
    git@github.com:KangaZero/homebrew-neomouse.git "$TAP_DIR"

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
