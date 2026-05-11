# neomouse

A keyboard-driven mouse control daemon for macOS, inspired by [warpd](https://github.com/rvaiya/warpd) but built around true Vim motions.

The goal is to feel like you never left Vim — mouse control that maps naturally to muscle memory.

## How it works

`neomouse` is a SwiftUI macOS app that installs a global event monitor to intercept keyboard events and translate Vim motions into mouse movements and gestures. It uses [GRDB](https://github.com/groue/GRDB.swift) for local session state.

## Requirements

| | Minimum | Check with |
|---|---|---|
| macOS | 13 (Ventura) | `sw_vers` |
| Swift toolchain | 6.3 | `swift --version` |
| bash (release script only) | 3.2 (default on macOS) | `bash --version` |
| `gh` CLI (release script only) | any | `gh --version` |

Accessibility permissions are requested by the app on first run.

The Swift toolchain and macOS minimums are enforced by `Package.swift` — SwiftPM will refuse to build on older systems with a clear error.

## Build

```sh
# Debug build
swift build

# Release build
swift build -c release
```

The release binary is written to `.build/release/neomouse`.

## Run

```sh
swift run -c release
# or directly:
.build/release/neomouse
```

> macOS will prompt for Accessibility permissions on first launch. Grant them in **System Settings → Privacy & Security → Accessibility**, then relaunch.

## Install (optional)

Copy the release binary somewhere on your `PATH`:

```sh
swift build -c release
cp .build/release/neomouse /usr/local/bin/
```

## Project structure

```
Package.swift                — SwiftPM manifest
Sources/neomouse/            — app sources
  swift.swift                — @main entry point, event monitors, app state
  mode.swift                 — mode definitions (normal, visual, find, …)
  operation.swift            — keymap → operation dispatch
  undotree.swift             — undo/redo state
  ui/                        — SwiftUI overlays (command line, keycast)
  utils/                     — helpers (mouse, screen, window, gestures, …)
  database/                  — GRDB session store
Tests/neomouseTests/         — unit tests
```

## Contributing

After cloning, enable the repo's git hooks (one-time, per clone):

```sh
scripts/setup-hooks.sh
```

This points `core.hooksPath` at `.githooks/`, so the pre-commit hook runs `swift format lint` on staged Swift files and `swift test` before each commit. The same checks run in CI on every push to `main` and every PR.

## Status

Active development. See [TODO.md](TODO.md) for the roadmap.

## Releases

Pre-built binaries are published on the [Releases page](https://github.com/KangaZero/neomouse/releases). To cut a new release, see [RELEASING.md](RELEASING.md).

## License

[MIT](LICENSE). Copyright © 2026 Samuel Wai Weng Yong.
