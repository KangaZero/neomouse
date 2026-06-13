# CLAUDE.md

Guidance for Claude Code (and contributors) working in this repo.

**neomouse** is a Vim-motion mouse-control daemon for macOS — a menu-bar
(LSUIElement) app that drives the cursor, gestures, and clipboard from the
keyboard via a `CGEventTap`. macOS 14+. Swift 6 (tools 6.3, `swiftLanguageModes: [.v6]`).

## Build / test / run

Use `just` (run `just` for the full list). Key recipes:

| Command | What |
|---|---|
| `just build` / `just release` | debug / release build |
| `just run` / `just run-release` | build + assemble the `.app` + launch (stdout stays attached) |
| `just test` | `swift test` (injects Testing.framework rpaths for CLT) |
| `just lint` / `just fmt` | `swift format lint --strict` / format in place |
| `just check-config` | `taplo check settings.toml` against `schema/settings.schema.json` |
| `just check` | lint + test + check-config (what the pre-commit hook runs) |
| `just all` | check + release build (what CI runs) |
| `just release-local [vX]` | full local release dry-run → installs `/Applications/NeoMouseTest.app` (full Xcode only) |

Plain `swift build` / `swift test` work too. **Universal (arm64 + x86_64) builds
need full Xcode** (not just Command Line Tools) — `swift build -c release --arch
arm64 --arch x86_64`; the multi-arch product is under `.build/apple/Products/Release/`
(resolve with `swift build … --show-bin-path`, not the `.build/release` symlink).

Git hooks: `scripts/setup-hooks.sh` (once after clone) → `core.hooksPath=.githooks`.
- **pre-commit**: lint staged Swift + conditional `taplo check` (only when `settings.toml`/`schema/` staged) + `swift test`.
- **pre-push**: `swift build -c release`. Bypass either with `--no-verify`.

## Architecture — five SwiftPM targets (deps point downward)

```
neomouse (exe) ─► neomouseDB ─► neomouseUtils ─► neomouseTypes
       └────────► neomouseConfig ─┘                  ▲
       └────────► (Utils, Config, Types directly) ───┘
```

- **`neomouseTypes`** (no deps) — pure value types: `NeomouseType` (Mode, FindState, VisualState, `NormalModePendingOperation`, …) in `modes.swift`.
- **`neomouseUtils`** (→ Types) — caseless-`enum` namespaces: `Mouse`, `Screen`, `Zoom`, `Pasteboard`, `Gesture`, `System`, `MotionTarget`, `HJKLDirection`, `KeyCodeMap`; plus `debug()` and screenshot helpers. Kept UI-light. `Mouse.frontmostAppUnder()` / `Mouse.setActiveApp(_:)` live here.
- **`neomouseConfig`** (→ Utils, Types, TOMLDecoder) — `Config` + `Config.Theme` (the ~958-line `theme.swift`). **Deliberately SwiftUI/AppKit-free** — the SwiftUI bridge `Theme+SwiftUI.swift` lives in the exe target instead. Strict TOML validation in `strictDecoding.swift`.
- **`neomouseDB`** (→ Utils, Types, GRDB, TOMLDecoder) — GRDB models in `models/` (`Session`, `Mark`, `Register`, `Jump`, `Macro`, `ExecutedOperation`), `AppDatabase.swift` (global `dbQueue`, `initializeDB`). The operation-category enums (`OperationName` etc.) live here (they conform to GRDB's `DatabaseValueConvertible`).
- **`neomouse`** (exe → all) — `@main NeoMouse: App`, the `NeoMouseState` observable model, `KeyEventTap` (CGEventTap install), `KeyHandlers` (per-mode key dispatch — currently a ~1500-line monolith), `CoreOperations`, and all UI under `ui/` (overlays, menus, command line, settings, menu bar).

Key flow: keypress → `KeyEventTap` callback → `NeoMouse.keyHandler` builds a `KeyEventContext` and switches on `appState.mode` → the `handle*Mode` handlers in `KeyHandlers.swift`.

> SwiftPM target membership is **path-prefix based** (no `sources:`/`exclude:` in `Package.swift`), so files can be moved into new subfolders under a target's path with no `Package.swift` edit.

## Conventions

- **Commits**: prefix with `<feat>` / `<fix>` / `<refactor>` / `<docs>`; detailed bodies explaining the *why*. **Do NOT add `Co-Authored-By` / Claude self-attribution** trailers.
- **Namespacing**: prefer caseless-`enum` static namespaces over top-level free functions (some legacy free funcs remain — see #4).
- Swift 6 strict concurrency; most app/UI code is `@MainActor`. DB writes go through `dbQueue.write` (synchronous).
- `settings.toml` ↔ `schema/settings.schema.json` ↔ the `Config` model must stay in sync; new config keys use `decodeIfPresent` + a `defaultX` static so older files keep loading.

## Platform & distribution

- **Universal binary** (arm64 + Intel x86_64), shipped as one `neomouse-vX-macos-universal.tar.gz`.
- Distribution: Homebrew tap (`KangaZero/homebrew-neomouse`), Nix flake (both `aarch64-darwin` + `x86_64-darwin`), and manual tarball. See `RELEASING.md`.
- Releases: tag `vX.Y.Z` → `.github/workflows/release.yml` builds/signs/publishes + bumps flake & tap (reuses `scripts/release.sh` via `SKIP_TAG=1`). Requires repo secret `HOMEBREW_TAP_TOKEN`.
- CI (`.github/workflows/ci.yml`): lint once; build+test on **macos-15 (arm64) and macos-13 (Intel)**; universal-build slice check; `nix flake check --all-systems` on both runners.

## Project status & open work — as of 2026-06-13

Recently landed on `main`:
- **Intel / universal support** (PR #2): universal build, dual-arch CI, flake + Homebrew for both systems.
- **`front_app_follows_mouse` config groundwork** (`e2903a0`): the config key, `NeoMouseState` flag, Settings toggle, schema + `settings.toml`, and `Mouse.frontmostAppUnder()` exist — **but the runtime behavior is not wired yet** (see #3).
- CI binary-path fix for multi-arch builds (`26544a8`); tiered git hooks (`c825588`).

**Open issues** (planning docs, drafted + reviewed by agents against the code):
- **#1 — Intel/universal follow-ups**: add `HOMEBREW_TAP_TOKEN` secret; on first universal release, remove `depends_on arch: :arm64` from the live tap formula. Caveats: `macos-13` Intel runner deprecation; nixpkgs 26.05 = last `x86_64-darwin`.
- **#3 — Command categorization + pre/after-hook pipeline**: a hook chokepoint to (a) wire `setExecutedOperation` DB recording, (b) finish `front_app_follows_mouse` as a movement after-hook, (c) kill the `appState.mode = .normal(...)` reset boilerplate. Includes a ⚠️ Step 0 fix: `ExecutedOperation.databaseTableName` typo `"excecuted_operation"` → `"executed_operation"` (Swift constant only, no migration).
- **#4 — Source-tree reorg**: whole-project structural cleanup — split the monoliths (`KeyHandlers.swift`, `NeoMouseApp.swift`), group by concern in every target, delete dead `old/` code, namespace stray free funcs. No behavior change.
- **#5 — Code-health audit**: verified bugs + improvements. Notable: `Session.update` filters the wrong column **and** never calls `update(db)` (renames silently no-op); `$` motion missing its modifier guard; force-unwrap crash risks; no DB migration path (destructive re-init); silent error-swallowing; thin test coverage.

**Sequencing**: #4 and #3 are coupled through `KeyHandlers.swift`. Land #4's chokepoint extraction (`KeyDispatch.swift`) + per-mode split + the `ExecutedOperation.set` rename **first**, then #3 slots its hooks into that seam. #4's library-level cleanups are independent and can land anytime.
