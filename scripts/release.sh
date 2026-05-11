#!/usr/bin/env bash
# Cut a new release of neomouse.
#
# Usage: scripts/release.sh vX.Y.Z
#
# Builds, ad-hoc signs, packages, tags, pushes, and publishes a GitHub Release.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

step() { printf "\n\033[1;34m==>\033[0m %s\n" "$1"; }
fail() { printf "\033[1;31merror:\033[0m %s\n" "$1" >&2; exit 1; }

# ---------- args ----------

[[ $# -eq 1 ]] || fail "Usage: $0 vX.Y.Z"

VERSION="$1"
# accept either "0.1.0" or "v0.1.0"
[[ "$VERSION" =~ ^v ]] || VERSION="v$VERSION"
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version must be vX.Y.Z (got: $VERSION)"

# ---------- preconditions ----------

step "Checking preconditions"

command -v gh >/dev/null    || fail "gh CLI not installed (brew install gh)"
command -v swift >/dev/null || fail "swift toolchain not found"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated (run: gh auth login)"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || fail "Not on main (on: $BRANCH)"

[[ -z "$(git status --porcelain)" ]] || fail "Working tree is dirty. Commit or stash first."

git rev-parse "$VERSION" >/dev/null 2>&1 && fail "Tag $VERSION already exists locally."
git ls-remote --exit-code --tags origin "$VERSION" >/dev/null 2>&1 \
  && fail "Tag $VERSION already exists on origin."

git fetch --quiet origin
[[ "$(git rev-parse main)" == "$(git rev-parse origin/main)" ]] \
  || fail "Local main differs from origin/main. Pull or push first."

echo "  branch: main"
echo "  commit: $(git rev-parse --short HEAD)"
echo "  tag:    $VERSION"

# ---------- build ----------

step "Building release binary"
swift build -c release

BIN=".build/release/neomouse"
[[ -x "$BIN" ]] || fail "Build did not produce $BIN"
file "$BIN"

# ---------- sign ----------

step "Ad-hoc signing"
codesign --sign - --force --options runtime --timestamp=none "$BIN"
codesign -dv "$BIN" 2>&1 | grep -E "Signature|Format" || true

# ---------- package ----------

step "Packaging"
mkdir -p dist
ARCHIVE_NAME="neomouse-${VERSION}-macos-arm64.tar.gz"
ARCHIVE="dist/$ARCHIVE_NAME"

tar -czf "$ARCHIVE" -C .build/release neomouse
( cd dist && shasum -a 256 "$ARCHIVE_NAME" | tee "$ARCHIVE_NAME.sha256" )

ls -la "$ARCHIVE" "$ARCHIVE.sha256"

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

cat > "$NOTES_FILE" <<EOF
## Install

1. Download \`$ARCHIVE_NAME\` below.
2. Extract:
   \`\`\`sh
   tar -xzf $ARCHIVE_NAME
   \`\`\`
3. Remove macOS download quarantine (the binary is ad-hoc signed, not Developer ID signed):
   \`\`\`sh
   xattr -dr com.apple.quarantine ./neomouse
   \`\`\`
4. Run \`./neomouse\` and grant Accessibility permissions on first launch.

## Verify

\`\`\`sh
shasum -a 256 -c $ARCHIVE_NAME.sha256
\`\`\`

## $CHANGES_HEADER

$(git log --pretty=format:'- %s' "$RANGE")

## Platform

macOS 13+, Apple Silicon only.
EOF

# ---------- gh release ----------

step "Creating GitHub Release"
gh release create "$VERSION" \
  --title "$VERSION" \
  --notes-file "$NOTES_FILE" \
  "$ARCHIVE" "$ARCHIVE.sha256"

URL="$(gh release view "$VERSION" --json url -q .url)"
step "Done"
echo "Release: $URL"
