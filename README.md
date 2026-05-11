# neomouse

A keyboard-driven mouse control daemon for macOS, inspired by [warpd](https://github.com/rvaiya/warpd) but built around true Vim motions.

The goal is to feel like you never left Vim — mouse control that maps naturally to muscle memory.

## How it works

`neomouse` is a SwiftUI macOS app that installs a global event monitor to intercept keyboard events and translate Vim motions into mouse movements and gestures. It uses [GRDB](https://github.com/groue/GRDB.swift) for local session state.

## Requirements

- **macOS 13 (Ventura) or later**
- **Apple Silicon (arm64).** Intel Macs are not yet supported.
- **Accessibility permissions** — granted on first run. macOS prompts you; allow `neomouse` in **System Settings → Privacy & Security → Accessibility**, then relaunch.

The release binary is ad-hoc signed (not Apple Developer ID signed). The Homebrew and Nix install paths handle this transparently; the manual-download path needs one extra command to clear the Gatekeeper quarantine — see below.

## Install

Pick one. All three install the same v0.0.0 binary from the [Releases page](https://github.com/KangaZero/neomouse/releases).

### 1. Homebrew

```sh
brew tap KangaZero/neomouse
brew install neomouse
```

Then run:

```sh
neomouse
```

Update later with `brew upgrade neomouse`. Uninstall with `brew uninstall neomouse && brew untap KangaZero/neomouse`.

> If your Homebrew is managed declaratively by [`nix-homebrew`](https://github.com/zhaofengli/nix-homebrew), add `github:KangaZero/homebrew-neomouse` as a flake input and put `"neomouse"` in your `homebrew.brews` list. (`brew tap` will not work on a Nix-managed `/opt/homebrew`.)

### 2. Nix

Apple Silicon only. Requires Nix with [flakes enabled](https://nixos.wiki/wiki/Flakes#Enable_flakes_temporarily) (`experimental-features = nix-command flakes` in `~/.config/nix/nix.conf`).

**Try it once without installing anything:**

```sh
nix run github:KangaZero/neomouse
```

This downloads the prebuilt binary into your Nix store, runs it, and leaves no trace on next garbage collection.

**Install into your user profile** (puts `neomouse` on your `PATH` permanently):

```sh
nix profile add github:KangaZero/neomouse
```

> On Nix older than 2.20, the subcommand is `nix profile install` instead of `add`. Both still work in recent versions, but `install` is now a deprecated alias.

Update later with `nix profile upgrade neomouse`, or `nix profile upgrade --all`. Remove with `nix profile remove neomouse`.

**Add to your system flake** (recommended if you use `nix-darwin`, NixOS, or `home-manager`):

```nix
# In your existing flake.nix, add the input:
{
  inputs.neomouse = {
    url = "github:KangaZero/neomouse";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, neomouse, ... }: {
    # ...your existing config...
  };
}
```

Then reference the package wherever you list packages — e.g. inside your nix-darwin module:

```nix
environment.systemPackages = [
  neomouse.packages.aarch64-darwin.default
];
```

…or inside home-manager:

```nix
home.packages = [
  neomouse.packages.aarch64-darwin.default
];
```

Rebuild your system (`darwin-rebuild switch --flake .#<host>` or `home-manager switch --flake .#<user>`). Pick up new releases with `nix flake update neomouse` and rebuild.

### 3. Manual (download a tarball)

```sh
# Pick the latest release URL from https://github.com/KangaZero/neomouse/releases
VERSION=v0.0.0
curl -LO "https://github.com/KangaZero/neomouse/releases/download/${VERSION}/neomouse-${VERSION}-macos-arm64.tar.gz"
curl -LO "https://github.com/KangaZero/neomouse/releases/download/${VERSION}/neomouse-${VERSION}-macos-arm64.tar.gz.sha256"

# Verify the download
shasum -a 256 -c "neomouse-${VERSION}-macos-arm64.tar.gz.sha256"

# Extract
tar -xzf "neomouse-${VERSION}-macos-arm64.tar.gz"

# Clear macOS download quarantine (only needed on the manual path)
xattr -dr com.apple.quarantine ./neomouse

# Run
./neomouse

# Optional: put it on your PATH
sudo install -m 755 ./neomouse /usr/local/bin/neomouse
```

## Development

Requires Swift 6.3+ (`swift --version`). No Xcode required for building — Command Line Tools is enough. [`just`](https://github.com/casey/just) is the front door for every common task; underlying `swift` commands are documented below if you'd rather invoke them directly.

### Setup

```sh
git clone https://github.com/KangaZero/neomouse
cd neomouse

# Install just (the command runner). Pick one:
cargo install just      # via Rust toolchain
brew install just       # via Homebrew
# (or nix profile add nixpkgs#just)

# One-time per clone: enable the repo's git hooks
scripts/setup-hooks.sh
```

`setup-hooks.sh` sets `core.hooksPath=.githooks`. The pre-commit hook runs `swift format lint --strict` on staged Swift files and `swift test` before each commit. The same checks run in CI on every push to `main` and every PR.

### `just` — the catch-all

```sh
just               # list every recipe with a one-line description
just all           # catch-all: lint + test + release build (what CI runs)
```

Other recipes:

| Recipe | Does |
|---|---|
| `just build` | Debug build → `.build/debug/neomouse` |
| `just release` | Release build → `.build/release/neomouse` |
| `just run` | Build and run the debug binary |
| `just run-release` | Build and run the release binary |
| `just test` | Run the test suite (with `Testing.framework` rpath flags) |
| `just lint` | `swift format lint --strict` on `Sources/` and `Tests/` |
| `just fmt` | `swift format -i` to auto-format in place |
| `just check` | `lint + test` (what the pre-commit hook runs) |
| `just clean` | `swift package clean` and remove `.build/` |

macOS will prompt for Accessibility permissions the first time you launch from each build path. Allow `neomouse` in **System Settings → Privacy & Security → Accessibility**, then relaunch.

### Underlying commands

The justfile is a thin wrapper. If you want to run things by hand:

```sh
swift build                  # debug build
swift build -c release       # release build
swift run                    # build + run debug
swift run -c release         # build + run release
```

For `swift test`, the test target uses `import Testing` (Swift Testing), which needs `Testing.framework` and `lib_TestingInterop.dylib` resolved at runtime. Under Command Line Tools they live under `$(xcode-select -p)` but aren't on the default rpath, so `swift test` needs:

```sh
DEV_DIR="$(xcode-select -p)"
swift test \
    -Xswiftc -F -Xswiftc "$DEV_DIR/Library/Developer/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV_DIR/Library/Developer/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV_DIR/Library/Developer/usr/lib"
```

Full Xcode finds them itself; the flags are harmless either way. `just test` injects these for you.

### Debug logging

`debug(...)` in `Sources/neomouse/utils/debug.swift` writes to two independent sinks: **stdout** and **a log file**. Each is gated separately.

**Stdout** is enabled when either:

- The binary was built in debug configuration (`swift build` / `swift run`), so `#if DEBUG` is set automatically, **or**
- The runtime env var `DEBUG` is set to a non-empty, non-falsy value (anything except `0` / `false`).

```sh
DEBUG=1 neomouse              # installed via brew/nix
DEBUG=1 swift run -c release  # locally built release binary
```

Debug builds always print to stdout regardless of the env var.

**File logging** is enabled when:

- The env var `LOG` is set to a non-empty, non-falsy value.
- `LOG_LOCATION` (optional) sets the destination. Default: `/tmp/neomouse/logs/neomouse.log`.
  - If `LOG_LOCATION` ends in `.log`, it's treated as a full file path.
  - Otherwise it's treated as a directory and `neomouse.log` is appended.
  - The parent directory is created if missing. The file is opened append-only.

```sh
LOG=1 neomouse                                         # → /tmp/neomouse/logs/neomouse.log
LOG=1 LOG_LOCATION=~/Library/Logs/neomouse neomouse    # → ~/Library/Logs/neomouse/neomouse.log
LOG=1 LOG_LOCATION=/tmp/x.log neomouse                 # → /tmp/x.log
DEBUG=1 LOG=1 neomouse                                 # both stdout and file
```

The env-var checks are evaluated once at module load, so per-`debug()` overhead is a `Bool` check plus formatting. File writes are serialized on a background queue.

### Lint / format config

`.swift-format` at the repo root: 4-space indent, 120-line limit, `NoAssignmentInExpressions` disabled (the codebase intentionally uses `return state = ...`).

### Project layout

```
Package.swift                — SwiftPM manifest
justfile                     — developer commands (`just`)
.swift-format                — formatter / linter config
.githooks/pre-commit         — lint staged Swift + run tests
.github/workflows/ci.yml     — CI: lint + build + test on macos-15 (Swift 6.3 via swiftly)
scripts/release.sh           — cut a release (binary + tarball + tag + GitHub Release + brew tap bump + flake bump)
scripts/setup-hooks.sh       — one-time hook activation

Sources/neomouse/            — app sources
  swift.swift                — @main entry point, event monitors, app state
  mode.swift                 — mode definitions (normal, visual, find, …)
  operation.swift            — keymap → operation dispatch
  undotree.swift             — undo/redo state
  ui/                        — SwiftUI overlays (command line, keycast)
  utils/                     — helpers (mouse, screen, window, gestures, …)
    debug.swift              — gated debug logger (see Debug logging above)
    hjkl.swift               — pure direction → CGVector helper, unit-tested
  database/                  — GRDB session store

Tests/neomouseTests/         — swift-testing (`import Testing`) suites
```

## Status

Active development. See [TODO.md](TODO.md) for the roadmap.

## Releases

Pre-built binaries are published on the [Releases page](https://github.com/KangaZero/neomouse/releases). To cut a new release, see [RELEASING.md](RELEASING.md).

## License

[MIT](LICENSE). Copyright © 2026 Samuel Wai Weng Yong.
