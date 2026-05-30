# neomouse

A keyboard-driven mouse control daemon for macOS, inspired by [warpd](https://github.com/rvaiya/warpd) but built around true Vim motions.

The goal is to feel like you never left Vim — mouse control that maps naturally to muscle memory.

## How it works

`neomouse` is a SwiftUI macOS app that installs a global `CGEventTap` to intercept keyboard events and translate Vim motions into mouse movements, clicks, scrolls, and gestures. It lives in the menu bar (no Dock icon, mode-colored status icon) and runs in the background.

The interaction model is mode-based, mirroring Vim:

- **normal** — hjkl moves the cursor; counts (`5j`), motions (`gg`/`G`/`0`/`$`), `s` snaps to the nearest ruler cell, capital `H`/`J`/`K`/`L` scrolls, `Ctrl-w` + `hjkl` jumps between displays, `m{a-z}` sets a mark, `'{a-z}`/`` `{a-z} `` jumps back, `"{reg}` selects a register, `?` shows the help dialog.
- **find** — a labelled grid overlay covers the screen; one or two keypresses warps the cursor to a cell.
- **specialFind** — a small grid pops up *around the current cursor*; a single keypress lands it on the picked cell. `q`/`w`/`e`/`r` nudge ±10 pts.
- **visual** — `v` enters visual mode; movement extends a highlighted region. `y` yanks (screenshot via `ScreenCaptureKit`), pasteboard-aware register flow (`"ay`, `"ap`, …) round-trips real `NSPasteboardItem`s.
- **command** — `:` opens a command-line overlay with fuzzy-filtered suggestions (`numbers`, `relativenumbers`, `delmarks`, `restart`, …); `Tab`/`Shift-Tab` and `Ctrl-n`/`Ctrl-p` cycle hits.
- **menu** — marks browser and Pasty-style register browser, both keyboard-navigable.
- **disabled** — tap is in `.listenOnly`; every keypress passes straight to the focused app.

The codebase is a multi-target SwiftPM package: a thin `neomouse` executable that owns the app shell and overlays, plus four libraries — `neomouseUtils` (input / screen / pasteboard / gesture / zoom / screenshot / motion helpers, each grouped into a `Mouse` / `Screen` / `Pasteboard` / `Gesture` / `Zoom` / `System` namespace), `neomouseDB` ([GRDB](https://github.com/groue/GRDB.swift)-backed sessions, marks, registers, macros, jumps, and executed-operation store), `neomouseConfig` ([TOMLDecoder](https://github.com/dduan/TOMLDecoder)-backed runtime configuration), and `neomouseTypes` (shared value types — `NeomouseType.Mode`, `.Direction`, `.VisualState`, etc.). Runtime tuning lives in `settings.toml`, validated against `schema/settings.schema.json`.

Tested on macOS 14+ with up to 3 displays. Mouse, gesture, and clipboard event synthesis is wired through `.cgSessionEventTap` + `CGWarpMouseCursorPosition` so it keeps working under macOS Accessibility Zoom.

## Requirements

- **macOS 14 (Sonoma) or later** — visual-mode screen capture uses `ScreenCaptureKit`, which raises the floor from macOS 13 to 14.
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

# Extract — produces neomouse.app/ in the current directory
tar -xzf "neomouse-${VERSION}-macos-arm64.tar.gz"

# Clear macOS download quarantine (only needed on the manual path)
xattr -dr com.apple.quarantine ./neomouse.app

# Launch — any of these works:
open ./neomouse.app                       # standard
./neomouse.app/Contents/MacOS/neomouse    # keeps stdout in your terminal
# …or double-click neomouse.app in Finder.

# Optional: move to /Applications, and symlink the inner binary onto PATH
mv ./neomouse.app /Applications/
sudo ln -sf /Applications/neomouse.app/Contents/MacOS/neomouse /usr/local/bin/neomouse
```

On first launch, neomouse copies the bundled default `settings.toml` (shipped at `neomouse.app/Contents/Resources/settings.toml`) to `~/.config/neomouse/settings.toml` if no file is already there. Edit that file to customize. The auto-deploy never overwrites an existing config — your customizations are safe across re-installs.

> Why a `.app` bundle and not a bare binary: SwiftUI's `MenuBarExtra` status item only registers when LaunchServices can read `CFBundleIdentifier` from `.app/Contents/Info.plist`. A bare-binary install would launch the daemon but show no menu-bar icon.

## Development

Requires Swift 6.3+ (`swift --version`). No Xcode required for building — Command Line Tools is enough. [`just`](https://github.com/casey/just) is the front door for every common task; underlying `swift` commands are documented below if you'd rather invoke them directly.

### Tools

Everything the dev workflow touches. The recommended path is `mise` + `swiftly` (handled automatically by the Setup section below); manual install columns are there if you'd rather wire them up yourself.

| Tool | Why it's needed | Install (manual) |
|---|---|---|
| [Swift](https://www.swift.org/install/) 6.3+ | Compiler / `swift build` / `swift test` / `swift-format` (bundled). | [swiftly](https://www.swift.org/swiftly/documentation/swiftly/) (recommended — respects `.swift-version`), the swift.org installer, or full Xcode. **Not** Command Line Tools alone: its `Testing.framework` is missing `_TestingInterop`, which `swift test` hard-links. |
| [just](https://github.com/casey/just) | Task runner — every common workflow is a `just <recipe>`. | `brew install just` |
| [taplo](https://taplo.tamasfe.dev/) | TOML linter for `just check-config` (validates `settings.toml` against the schema). | `brew install taplo` |
| [mise](https://mise.jdx.dev/) *(recommended)* | Per-repo version pinning for `just` + `taplo` via `mise.toml`; auto-activates on `cd`. | `brew install mise` or `curl https://mise.run \| sh` |
| [swiftly](https://www.swift.org/swiftly/documentation/swiftly/) *(recommended)* | Swift toolchain manager; ships the full `xctoolchain` bundle that `sourcekit-lsp` and `swift-testing` need. | `curl -O https://download.swift.org/swiftly/darwin/swiftly.pkg && installer -pkg swiftly.pkg -target CurrentUserHomeDirectory` (see swiftly docs) |
| git | Repo + pre-commit hook (`scripts/setup-hooks.sh` activates `.githooks/`). | Comes with Command Line Tools (`xcode-select --install`). |

`swift-format`, `swift-testing`, and `sourcekit-lsp` all ship inside the Swift toolchain — no separate install.

### Setup

```sh
git clone https://github.com/KangaZero/neomouse
cd neomouse

# One-time per clone: enable the repo's git hooks
scripts/setup-hooks.sh
```

The repo pins `just` and `taplo` in `mise.toml`, so they stay out of your global environment. Swift itself is managed separately by [swiftly](https://www.swift.org/swiftly/documentation/swiftly/) (see Tools table above) — `mise` does not pin the Swift toolchain. If you use [mise](https://mise.jdx.dev/):

```sh
mise trust   # one-time, allow this repo's mise.toml to run
mise install # fetches the pinned versions of just + taplo
```

mise installs each tool into `~/.local/share/mise/installs/<tool>/<version>/` and only adds them to `PATH` while you're inside this repo (via the shell hook). Outside the repo, neither is available.

> Why swiftly and not Command Line Tools: macOS's CLT toolchain ships `Testing.framework` without the `_TestingInterop` C bridge that `swift-testing` 6.3 hard-links. The swift.org toolchain (what swiftly installs) ships both, so `swift test` works without any rpath gymnastics. Full Xcode also works.

If you don't use mise, install `just` / `taplo` however you prefer (`brew install just taplo`, etc.) and Swift via swiftly or the swift.org installer.

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
| `just run` | Build, assemble `.build/debug/neomouse.app` wrapper, run the binary from inside it |
| `just run-release` | Same, for the release config |
| `just test` | Run the test suite (`swift test`) |
| `just lint` | `swift format lint --strict` on `Sources/` and `Tests/` |
| `just fmt` | `swift format -i` to auto-format in place |
| `just check-config` | Validate `settings.toml` against `schema/settings.schema.json` (Taplo) |
| `just check` | `lint + test + check-config` (what the pre-commit hook runs) |
| `just clean` | `swift package clean` and remove `.build/` |

macOS will prompt for Accessibility permissions the first time you launch from each build path. Allow `neomouse` in **System Settings → Privacy & Security → Accessibility**, then relaunch.

### Underlying commands

The justfile is a thin wrapper. If you want to run things by hand:

```sh
swift build                  # debug build (binary only, no .app wrapper)
swift build -c release       # release build (binary only, no .app wrapper)
swift run                    # build + run debug — but see caveat below
swift run -c release         # build + run release — same caveat
swift test                   # run the test suite
```

> **Heads up:** `swift run` launches the bare Mach-O at `.build/<config>/neomouse` directly. macOS LaunchServices only reads `CFBundleIdentifier` from a real `.app/Contents/Info.plist` — embedding the same plist in the binary's `__TEXT,__info_plist` section is not enough — so SwiftUI's `MenuBarExtra` silently fails to register a status item. `just run` works around this by assembling `.build/<config>/neomouse.app` from the repo-root `Info.plist` and launching the inner binary from inside that bundle. **If you're working on anything menu-bar-related, use `just run` (or hand-assemble the wrapper yourself), not `swift run`.**

`swift test` uses [swift-testing](https://github.com/swiftlang/swift-testing) (`import Testing`). With the mise-pinned swift.org toolchain (or full Xcode), it Just Works — both `Testing` and `_TestingInterop` ship in the toolchain. If you're stuck on a Command Line Tools-only install, `_TestingInterop` is missing and the link step will fail; install full Xcode or use the mise pin above.

### Configuration

Runtime tuning is in `settings.toml`. `Config.loadConfig` is called once at app start; properties on `NeoMouseState` fall back to inline defaults when no settings file is resolved. Resolution order (first match wins):

1. `$NEOMOUSE_CONFIG`
2. `~/.config/neomouse/settings.toml`
3. `~/Library/Application Support/neomouse/settings.toml`

The repo-root `settings.toml` is a **template**, not auto-loaded. For local dev, either symlink it (`ln -s "$(pwd)/settings.toml" ~/.config/neomouse/settings.toml`) or `export NEOMOUSE_CONFIG="$(pwd)/settings.toml"`.

Sections (full schema in `schema/settings.schema.json`):

- `[grid]` — find-mode overlay: `divisions`, `inner_divisions`, `inset`, the per-cell label alphabets, `is_always_show_inner_characters`.
- `[motion]` — `rows_on_screen` / `columns_on_screen` (integer or `"automatic"` to derive from screen size; auto keeps cells square), `is_clamp_cursor_to_current_screen`.
- `[visual]` — `minimum_highlight_width`, `mouse_event_on_visual` (e.g. press-and-hold left/right mouse on visual enter for drag-select).
- `[gesture]` — pinch/zoom `zoom_step_value`, scroll `increments_per_gesture`, rotate `degrees_to_rotate`.
- `[commands]` — whitelisted command-line commands the user can invoke via `:`.
- `[configuration]` — session/history caps (`max_session_count`, `max_operations_per_session`, `max_jumps_per_session`), `new_session_on_open`, `is_disable_key_input` (swallow plain-key presses when active vs. listen-only).

`just check-config` runs Taplo against `schema/settings.schema.json` so schema drift is caught at commit time, not at startup.

### Dev seed

The DB starts with a single seed session ("Cookiezi"). To reinitialise from scratch with extra sessions and randomly-placed marks (useful when exercising mark UX), set `NEOMOUSE_SEED=1`:

```sh
NEOMOUSE_SEED=1 swift run
```

This **wipes and re-creates every table** (`forceReIntialize: true`), then runs `seedAll(sessionCount: 3, marksPerSession: 5, registersPerSession: 3)` — extra sessions, randomly-placed marks, and registers `a`–`c` populated with sample `NSPasteboardItem`s. Do not set this on a database you care about.

### Debug logging

`debug(...)` in `Sources/neomouseUtils/dev/debug.swift` writes to two independent sinks: **stdout** and **a log file**. Each is gated separately.

**Stdout** is enabled when either:

- The binary was built in debug configuration (`swift build` / `swift run`), so `#if DEBUG` is set automatically, **or**
- The runtime env var `DEBUG` is set to a non-empty, non-falsy value (anything except `0` / `false`).

```sh
DEBUG=1 neomouse              # installed via brew/nix
DEBUG=1 swift run -c release  # locally built release binary
```

Debug builds always print to stdout regardless of the env var.

**File logging** is enabled when *either* of these is true:

- `LOG` env var is non-empty / non-falsy (explicit opt-in — primarily a dev override), **or**
- The process is running from a bundled `.app` (i.e. `Bundle.main.bundleIdentifier` is set — `just run`, brew install, nix run, manual `.app` extraction). Set `LOG=0` (or `false`) to opt back out in that case.

This means **users running the release `.app` get a log file by default** — no env-var dance — and the menu-bar **Diagnostics → Show Debug Log** / **Reveal Log in Finder** items open it for them.

**Destination** (first match):

1. `$LOG_LOCATION` — full file path if it ends in `.log`, else dir + `neomouse.log`.
2. `~/Library/Logs/neomouse/neomouse.log` — when running from a bundle. Standard Apple location; opens directly in Console.app.
3. `/tmp/neomouse/logs/neomouse.log` — legacy fallback (LOG=1 set, no LOG_LOCATION, bare `swift run`).

```sh
# Bundled install (brew/nix/manual .app/`just run`): log file is on by default.
# Disable explicitly:
LOG=0 neomouse

# Override the destination:
LOG_LOCATION=~/scratch/nm.log neomouse
LOG_LOCATION=/tmp/x neomouse           # → /tmp/x/neomouse.log

# Bare `swift run` (no bundle): logs to stdout only unless you opt in
LOG=1 swift run                        # → /tmp/neomouse/logs/neomouse.log
LOG=1 LOG_LOCATION=~/scratch/nm.log swift run
DEBUG=1 LOG=1 swift run                # both stdout and file
```

The env-var + bundle checks are evaluated once at module load, so per-`debug()` overhead is a `Bool` check plus formatting. File writes are serialized on a background queue.

### Lint / format config

`.swift-format` at the repo root: 4-space indent, 120-line limit, `NoAssignmentInExpressions` disabled (the codebase intentionally uses `return state = ...`).

### Project layout

```
Package.swift                — SwiftPM manifest (1 executable + 4 library targets + test target)
.swift-version               — pinned toolchain version (read by swiftly)
settings.toml                — runtime config template (TOML)
schema/settings.schema.json  — JSON schema enforced by Taplo (`just check-config`)
justfile                     — developer commands (`just`)
mise.toml                    — pinned dev tool versions: just, taplo (mise)
.swift-format                — formatter / linter config
.githooks/pre-commit         — lint staged Swift + run tests + check-config
.github/workflows/ci.yml     — CI: lint + build + test on macos-15 (Swift 6.3 via swiftly)
flake.nix / flake.lock       — Nix flake distribution
scripts/release.sh           — cut a release (binary + tarball + tag + GitHub Release + brew tap bump + flake bump)
scripts/setup-hooks.sh       — one-time hook activation

Sources/neomouse/            — executable target: app shell, key event tap, modes, overlays, menus
  NeoMouseApp.swift          — @main entry, NeoMouseState, key/mouse/pasteboard monitors, mode dispatch
  AppDelegate.swift          — applicationWillTerminate cleanup; .accessory activation policy
  KeyEventTap.swift          — global CGEventTap install (defaultTap vs. listenOnly); AX permission prompt
  CoreOperations.swift       — shared operation implementations (yank, paste, marks, visual, etc.) called from the key handler
  modes/visual.swift         — visual-mode exit + selection-state reset
  ui/MenuBar.swift           — MenuBarExtra status item (mode-colored icon, dropdown actions, Quit)
  ui/CommandLine.swift       — command-line overlay with wildmenu-style fuzzy suggestions
  ui/HelpDialog.swift        — `?`-triggered keybind reference overlay
  ui/KeyCast.swift           — keycast overlay
  ui/GridOverlay.swift       — find-mode labelled grid (outer + inner divisions)
  ui/NumbersOverlay.swift    — numbers / relativenumbers ruler + cursorline / cursorcolumn
  ui/CursorSurroundedGridOverlay.swift — specialFind small grid around current cursor position
  ui/VisualHighlightOverlay.swift — visual-mode selection rectangle
  ui/MarksMenu.swift         — marks browser (`menu(window: .marks)`)
  ui/RegisterMenu.swift      — Pasty-style register browser (`menu(window: .register)`)
  ui/ToastManager.swift      — transient on-screen status toasts
  ui/Alert.swift             — `showFatalAlertAndQuit` (NSAlert + Report Issue + quit)

Sources/neomouseUtils/       — library: input / screen / pasteboard / gesture / zoom helpers
  mouse.swift                — `Mouse` namespace: location, moveToGlobal/Screen/Relative, click/down/up/drag
  screen.swift               — `Screen` namespace: activeDisplays, currentSize, adjacentDisplayRectByDirection, allBoundingRect, cgToAppKit
  pasteboard.swift           — `Pasteboard` namespace: get (richest content), watch (changeCount polling), dump (debug)
  window.swift               — frontmost-app AX window introspection
  zoom.swift                 — `Zoom` namespace: isCurrentlyZoomed, currentZoomFactor, zoomIn / zoomOut (macOS Accessibility Zoom)
  screenshot.swift           — multi-display visual-mode capture via ScreenCaptureKit
  motions.swift              — pure MotionTarget math (cell-center + insets) — unit-tested
  hjkl.swift                 — pure direction → CGVector helper (unit-tested)
  keyCodeToCharMap.swift     — keycode ↔ character lookup table
  stringToInt.swift          — operation-count parsing
  validation.swift           — config-time string validation
  actions/gestures.swift     — `Gesture` namespace: pinchZoom, rotate, swipe, smartMagnify, scroll
  actions/postGestureEvent.swift — low-level kCGEventGesture poster
  actions/system.swift       — `System.simulate` (Cmd-C/V/X synthesis with sentinel userData)
  helpers/isStringHasDuplicates.swift
  dev/debug.swift            — gated debug logger (see Debug logging above)

Sources/neomouseDB/          — library: GRDB-backed store
  AppDatabase.swift          — schema bootstrap, dbQueue, initializeDB(forceReIntialize:)
  models/Session.swift       — Session (parent of all per-session data)
  models/Mark.swift          — vim-style marks (`ma` / `'a`) — upsert by (sessionId, mark); carries isVisual + start/end CGPoints
  models/Register.swift      — vim-style registers storing `NSPasteboardItem` round-trips (flatten to `[typeRaw: Data]`, archive via NSKeyedArchiver); `cycleNumbered` maintains the `"1`–`"9` FIFO ring from the pasteboard watcher
  models/Macro.swift         — recorded key sequences
  models/Jump.swift          — cursor-position jump list
  models/ExecutedOperation.swift — telemetry of every executed motion / gesture for analysis
  models/dev/seed.swift      — `seedAll` for dev fixtures (gated by `NEOMOUSE_SEED=1`)

Sources/neomouseConfig/      — library: TOMLDecoder → Config; LoadError; resolution paths
  config.swift               — Config struct, loadConfig, defaults
  keymap.swift               — (WIP, currently fully commented) configurable keymap parser

Sources/neomouseTypes/       — library: shared value types (kept import-light to avoid cycles)
  modes.swift                — `NeomouseType` namespace: Mode (disabled/normal/find/command/menu/specialFind), Direction, VisualState, MenuWindow, NormalModePendingOperation

Tests/neomouseTests/         — swift-testing (`import Testing`) suites
  HJKLTests.swift            — direction → vector
  MotionTargetsTests.swift   — cell-center coord math
  ScreenTests.swift          — 5x5 grid suite for adjacentDisplayRectByDirection
  PendingOpReducerTests.swift — normal-mode pending-operation state machine
```

Both `Sources/neomouse/old/` and `Sources/neomouseUtils/old/` hold superseded experiments (undotree, operation, findModeKeys, getTwoLetterPermutations) — not on the active code path; kept for reference until reimplementation lands.

## Status

Active development. See [TODO.md](TODO.md) for the roadmap.

## Releases

Pre-built binaries are published on the [Releases page](https://github.com/KangaZero/neomouse/releases). To cut a new release, see [RELEASING.md](RELEASING.md).

## License

[MIT](LICENSE). Copyright © 2026 Samuel Wai Weng Yong.
