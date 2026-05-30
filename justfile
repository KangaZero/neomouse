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

# Dry-run the full release pipeline LOCALLY — produces the exact same
# artifacts `scripts/release.sh` would (release build, ad-hoc-signed
# `neomouse.app` bundle inside `dist/neomouse-<version>-macos-arm64.tar.gz`
# plus its `.sha256`), then stops short of anything that touches a remote:
# no git tag, no `gh release create`, no Homebrew tap update, no flake bump.
#
# Use this to verify a release works end-to-end before cutting it for real.
# Output lands in `dist/`; the script prints extract + launch instructions
# at the end. Default version is `v0.0.0-local` so it doesn't collide with
# real release tags.
#
# Usage: `just release-local` (uses v0.0.0-local) or `just release-local v0.0.1-rc1`.
release-local version="v0.0.0-local":
    @DRY_RUN=1 scripts/release.sh {{version}}

# Lint + test + config schema check — what the pre-commit hook runs
check: lint test check-config

# Catch-all: lint + test + config check + release build — what CI runs
all: lint test check-config release

# Remove SwiftPM build artifacts
clean:
    swift package clean
    rm -rf .build
