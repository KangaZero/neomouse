# neomouse — developer commands.
# Install just with `cargo install just` (or `brew install just`).
# Run `just` (or `just --list`) for the full list. `just all` is the catch-all.

# Swift Testing (`import Testing`) needs Testing.framework + lib_TestingInterop
# resolved at runtime. Under Command Line Tools they live at these paths;
# under full Xcode the toolchain finds them itself and the flags are no-ops.
dev_dir := `xcode-select -p`

# Default: print available recipes.
default:
    @{{just_executable()}} --list

# Build the debug binary → .build/debug/neomouse
build:
    swift build

# Build the release binary → .build/release/neomouse
release:
    swift build -c release

# Assemble a minimal .app wrapper around an existing binary so SwiftUI's
# MenuBarExtra registers a status item (LaunchServices only reads bundle
# metadata from .app/Contents/Info.plist — embedding the Info.plist into
# the bare Mach-O's __TEXT,__info_plist section is not sufficient).
# Also bundles settings.toml under Contents/Resources/ so the app can
# auto-deploy a default config to ~/.config/neomouse/ on first launch
# (see deployBundledDefaultsIfMissing in NeoMouseApp.swift).
# Args: $1 = build config dir ("debug" / "release").
_app config:
    @mkdir -p ".build/{{config}}/neomouse.app/Contents/MacOS"
    @mkdir -p ".build/{{config}}/neomouse.app/Contents/Resources"
    @cp Info.plist ".build/{{config}}/neomouse.app/Contents/Info.plist"
    @cp settings.toml ".build/{{config}}/neomouse.app/Contents/Resources/settings.toml"
    @cp ".build/{{config}}/neomouse" ".build/{{config}}/neomouse.app/Contents/MacOS/neomouse"

# Build + assemble debug .app, then run it from inside the bundle so stdout
# stays attached to this terminal (vs. `open` which detaches). Launching via
# the .app/Contents/MacOS/<binary> path is what makes LaunchServices treat
# the process as a bundled UI app — the menu-bar status item depends on it.
run: build (_app "debug")
    .build/debug/neomouse.app/Contents/MacOS/neomouse

# Same shape, release config.
run-release: release (_app "release")
    .build/release/neomouse.app/Contents/MacOS/neomouse

# Run the test suite
test:
    swift test \
        -Xswiftc -F -Xswiftc {{dev_dir}}/Library/Developer/Frameworks \
        -Xlinker -L -Xlinker {{dev_dir}}/Library/Developer/usr/lib \
        -Xlinker -rpath -Xlinker {{dev_dir}}/Library/Developer/Frameworks \
        -Xlinker -rpath -Xlinker {{dev_dir}}/Library/Developer/usr/lib

# Check Swift formatting / style
lint:
    swift format lint --strict --recursive Sources Tests

# Auto-format Swift sources in place
fmt:
    swift format -i --recursive Sources Tests

# Validate settings.toml against schema/settings.schema.json via Taplo.
# Install Taplo with `mise install` (pinned in mise.toml) or `brew install taplo`.
check-config:
    taplo check settings.toml

# Install the repo-root settings.toml as the user's default config at
# ~/.config/neomouse/settings.toml. OVERWRITES any existing file there —
# this is intentional, the recipe exists for resetting to known defaults.
# Resolution order at runtime (first match wins): $NEOMOUSE_CONFIG,
# ~/.config/neomouse/settings.toml, ~/Library/Application Support/neomouse/settings.toml.
init:
    @mkdir -p ~/.config/neomouse
    @cp settings.toml ~/.config/neomouse/settings.toml
    @echo "Installed default settings to ~/.config/neomouse/settings.toml"

# Dry-run the full release pipeline LOCALLY *and* install the freshly-built
# bundle to `/Applications/NeoMouseTest.app` so you can test against a real,
# TCC-stable install. Two phases:
#
#   1. Same artifacts `scripts/release.sh` would produce: a release build,
#      ad-hoc-signed `neomouse.app` bundle inside
#      `dist/neomouse-<version>-macos-arm64.tar.gz` plus its `.sha256`. Stops
#      short of anything that touches a remote (no git tag, no `gh release
#      create`, no Homebrew tap update, no flake bump).
#
#   2. Replace `/Applications/NeoMouseTest.app` with the freshly-built bundle,
#      rewriting bundle identity so TCC tracks the test install separately
#      from a future production NeoMouse:
#        CFBundleIdentifier:  com.kangazero.NeoMouseTest  (≠ production)
#        CFBundleName / DisplayName: NeoMouseTest         (≠ "NeoMouse")
#      Re-signs after the plist edit (--deep, ad-hoc) and clears quarantine.
#      `/Applications/` is the only stable path TCC reliably honors — `/tmp/`
#      and `.build/` paths get a fresh TCC identity each rebuild and macOS
#      sometimes refuses to add them via System Settings → Privacy → Input
#      Monitoring → "+". Putting the test bundle in /Applications means
#      granting Accessibility + Input Monitoring once carries across every
#      subsequent `just release-local`.
#
# After the first launch, grant once:
#   System Settings → Privacy & Security → Accessibility    → enable NeoMouseTest
#   System Settings → Privacy & Security → Input Monitoring → enable NeoMouseTest
# Subsequent runs replace the bundle in place; TCC keeps both grants.
#
# Usage: `just release-local` (uses v0.0.0-local) or `just release-local v0.0.1-rc1`.
release-local version="v0.0.0-local":
    #!/usr/bin/env bash
    set -euo pipefail
    # Phase 1 — build the tarball + sha256 into dist/.
    DRY_RUN=1 scripts/release.sh {{version}}
    # Phase 2 — install to /Applications/NeoMouseTest.app with rewritten identity.
    # Stop any running NeoMouseTest so we can replace the bundle in /Applications.
    pkill -f "NeoMouseTest.app/Contents/MacOS/neomouse" 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/NeoMouseTest.app
    STAGE=$(mktemp -d)
    tar -xzf dist/neomouse-{{version}}-macos-arm64.tar.gz -C "$STAGE"
    mv "$STAGE/neomouse.app" /Applications/NeoMouseTest.app
    rm -rf "$STAGE"
    # Rewrite identity in the installed Info.plist. plutil edits invalidate
    # the existing signature, so re-sign afterwards.
    plutil -replace CFBundleIdentifier  -string "com.kangazero.NeoMouseTest" /Applications/NeoMouseTest.app/Contents/Info.plist
    plutil -replace CFBundleName        -string "NeoMouseTest"               /Applications/NeoMouseTest.app/Contents/Info.plist
    plutil -replace CFBundleDisplayName -string "NeoMouseTest"               /Applications/NeoMouseTest.app/Contents/Info.plist
    codesign --sign - --force --options runtime --timestamp=none --deep /Applications/NeoMouseTest.app
    xattr -dr com.apple.quarantine /Applications/NeoMouseTest.app 2>/dev/null || true
    echo
    echo "Installed /Applications/NeoMouseTest.app — launching"
    echo "First-run TCC: System Settings → Privacy & Security → Accessibility + Input Monitoring → enable NeoMouseTest"
    echo
    open /Applications/NeoMouseTest.app

# Back-compat alias for the old name. `release-test` and `release-local` now
# do the same thing — kept so existing muscle memory + scripts keep working.
release-test: release-local

# Lint + test + config schema check — what the pre-commit hook runs
check: lint test check-config

# Catch-all: lint + test + config check + release build — what CI runs
all: lint test check-config release

# Remove SwiftPM build artifacts
clean:
    swift package clean
    rm -rf .build
