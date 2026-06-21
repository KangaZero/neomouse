# DEV.md — neomouse architecture & runtime behavior

A developer-facing tour of **how neomouse actually works at runtime**: the data
flow from keystroke to cursor warp, the mode state machine, the configuration /
persistence layers, and — the part that's easy to get wrong — **what happens on
each error or edge case, and what falls back to what**.

This complements `CLAUDE.md` (which covers the build/test/release tooling, the
SwiftPM target layout, and contribution conventions). For *how to build*, see
`CLAUDE.md`; for *how it behaves*, read on.

> neomouse is a Vim-motion mouse-control daemon for macOS: a menu-bar
> (`LSUIElement`) app that drives the cursor, gestures, clipboard, and window
> focus from the keyboard via a `CGEventTap`. macOS 14+, Swift 6.

---

## 1. The big picture

Five SwiftPM targets, dependencies pointing downward (see `CLAUDE.md` for the
full module map):

```
neomouse (exe) ─► neomouseDB ─► neomouseUtils ─► neomouseTypes
       └────────► neomouseConfig ─┘                  ▲
       └────────► (Utils, Config, Types directly) ───┘
```

- **`neomouseTypes`** — pure value types, no deps. The `Mode` enum and its
  sub-states (`NormalModePendingOperation`, `FindState`, `VisualState`) live in
  `modes.swift`. This is the vocabulary the whole app speaks.
- **`neomouseUtils`** — caseless-`enum` namespaces (`Mouse`, `Screen`, `Zoom`,
  `Pasteboard`, `Gesture`, `System`, `MotionTarget`, `HJKLDirection`,
  `KeyCodeMap`), the layout-independent ASCII helpers, and `debug()`.
- **`neomouseConfig`** — the `Config` model, `Config.Theme`, the remappable
  `Config.VimAsciiKeymap`, and strict TOML validation. **AppKit/SwiftUI-free** on
  purpose (the SwiftUI bridge lives in the exe).
- **`neomouseDB`** — GRDB models (`Session`, `Mark`, `Register`, `Jump`, `Macro`,
  `ExecutedOperation`) + `AppDatabase` (the global `dbQueue`).
- **`neomouse`** (exe) — `@main NeoMouse: App`, the `NeoMouseState` observable
  model, the `CGEventTap` install, the per-mode key handlers, `CoreOperations`,
  the `ExecutionPipeline`, and all of `ui/`.

**One-line data flow:** `keypress → CGEventTap → makeKeyHandler → (derive
context, resolve keymap, handle ⌘E) → switch on appState.mode → per-mode handler
→ CoreOperations → Mouse/Gesture/Pasteboard → overlays re-render from
@Published state`.

---

## 2. From keystroke to action (the hot path)

Every keydown flows through this pipeline. Files: `Input/KeyEventTap.swift`,
`Input/KeyDispatch.swift`, `Input/KeyEventContext.swift`, `Input/Handlers/*`.

1. **The CGEventTap callback fires** (`KeyEventTap.swift`). The tap is installed
   in one of two flavors (see §6). It decides whether to *swallow* the key
   (`.defaultTap`) or merely *observe* it (`.listenOnly`), then forwards the
   `NSEvent` to `NeoMouse.keyHandler`.

2. **`makeKeyHandler` builds a per-keystroke context** (`KeyDispatch.swift`),
   inside `MainActor.assumeIsolated`:
   - Resets the one-shot `swallowCurrentKeyEvent` flag.
   - Reads cursor position (`Mouse.location()`) and the display under it; **falls
     back to the main display** if none matches (`CGDisplayBounds(CGMainDisplayID())`).
   - If cursor position *or* screen size is `nil`, logs `[guard fail]` and
     **returns early — the keystroke is dropped** (no handler runs).
   - Computes the operation count from the count buffer (`"5"` → `5`, default `1`).
   - Computes layout-independent ASCII chars (see §11): `asciiKey`
     (shift+option) and `asciiKeyBase` (shift only).
   - Resolves the **canonical** Vim char for the pressed physical key via the
     keymap (`appState.keymaps.canonical(forPhysical:)`) — see §7.4. A `[keymap]`
     debug line logs `physical → canonical`.

3. **⌘E activation toggle** is checked *before* the mode switch. It compares the
   **raw** key against `keymaps.toggleActivation` (default `"e"`) with ⌘ held:
   - `.disabled` → `.normal` (toast "Activated").
   - any active mode → `.disabled` (hides every overlay, resets grid divisions,
     and sets `swallowCurrentKeyEvent = true` so the "e" never reaches the app).

4. **Dispatch on `appState.mode`** — bundles everything into a `KeyEventContext`
   and calls the matching handler:

   | Mode | Handler | Post-hooks |
   |---|---|---|
   | `.disabled` | `handleDisabledMode` (no-op; ⌘E handled above) | — |
   | `.normal` | `handleNormalMode` | auto-snap, sync visual end to cursor, follow-app |
   | `.find` | `handleFindMode` | follow-app |
   | `.command` | `handleCommandMode` | — |
   | `.menu` | `handleMenuMode` | — |
   | `.specialFind` | `handleSpecialFindMode` | follow-app |

   **Only `handleNormalMode` reads the canonical keymap chars.** Every other
   handler reads the raw `asciiKey`, so command typing, mark/register names, and
   menu search are never remapped.

---

## 3. The mode state machine

Defined in `neomouseTypes/modes.swift`. `appState.mode` is the single source of
truth; it's `@Published`, so the menu-bar icon and overlays react to it.

### Modes

| Mode | Carries | Enter / Leave |
|---|---|---|
| `.disabled` | — | ⌘E toggles ↔ `.normal`. All keys pass through to the OS. |
| `.normal(pendingOp, countString)` | pending op + count buffer | The default active mode. `Esc` returns here from anywhere. |
| `.find(pendingOp, findState, isQuickFind)` | grid selection | `f` (full grid) / `F` (quick N-grid); leave via `Esc` or a cell pick. |
| `.command(command, suggestionIndex)` | typed text + wildmenu cursor | `:`; leave via `Return` (execute) or `Esc`. |
| `.menu(window)` | `.marks` or `.register` | `` ` `` / `"`; leave via `Return` or `Esc`. |
| `.specialFind` | — | `<space>f`; one dense grid around the cursor, single pick. |

### Normal-mode pending operations (`NormalModePendingOperation`)

A small sub-state machine for multi-key chords: `.none`, `.g` / `.gg` / `.ggy` /
`.ggv` (the `g`-prefix family), `.special` / `.window` (the `<space>` prefix —
scroll/window/find), `.setMark` (`m`), `.goToMark` (`'`) /
`.goToMarkExactState` (`` ` ``), `.goToRegister` (`"`) / `.registerAction(name)`.

### The count buffer

Digits accumulate into `operationCountAsString` (`"1"`…`"9"` append; `"0"`
appends *only* if a count is already pending, otherwise it's the "line start"
motion). `KeyDispatch` parses it to `operationCount` (clamped `> 0`, default
`1`). Any non-digit key resets it to `nil`. **This is why digits can't be remap
targets** — rebinding a motion onto a digit would corrupt counts like `5j`.

---

## 4. The per-mode handlers (`Input/Handlers/`)

- **`NormalModeHandler`** (the monolith) — motions `hjkl`/`0`/`$`/`|`/`M`/`G`/`gm`,
  mode switches `v`/`V`/`f`/`F`, ops `y`/`d`/`p` and their register forms,
  prefixes `g`/`<space>`/`m`, scroll `H`/`J`/`K`/`L`, `:`/`?`/`s`. A wrong
  modifier or unknown key resets to `.normal(.none, nil)` and returns.
- **`FindModeHandler`** — two-keystroke grid find: first key picks the outer
  cell, second the inner cell, then warps and returns to normal. `Esc` bails.
- **`CommandModeHandler`** — the `:` buffer with wildmenu cycling (Tab/Shift-Tab,
  Ctrl-n/Ctrl-p), Backspace, `Return` executes, `Esc` exits.
- **`MenuModeHandler`** — ↑/↓ (marks) or ←/→ (registers), a typed search filter,
  `Return` activates, `Esc` closes.
- **`SpecialFindModeHandler`** — one dense grid around the cursor; a single cell
  char warps and exits.
- **`DisabledModeHandler`** — intentionally empty.

---

## 5. Permissions & the event tap

`Input/KeyEventTap.swift`. neomouse needs three TCC grants, requested up front:

1. **Accessibility** (`AXIsProcessTrustedWithOptions`) — to install the tap.
2. **Input Monitoring** (`IOHIDRequestAccess`) — to receive key events.
3. **Screen Recording** — for yank (ScreenCaptureKit); requested lazily/separately.

**If a permission is missing**, the relevant debug line warns and the tap fails
to take effect *this run* — macOS only applies a fresh grant on the next launch.

### Two tap flavors (driven by `is_disable_key_input`)

- **`.defaultTap`** (`true`, default): actively swallows plain keys (`a–z`,
  `0–9`) while neomouse is active. **Always passes through:** ⌘/⌃/⌥ chords, Esc,
  Tab, Backspace, arrows, Return, F1–F20, and keycodes ≥128. In command/menu
  modes the special-key pass-through is relaxed so those modes can consume
  Esc/Tab/Return.
- **`.listenOnly`** (`false`): every key reaches the focused app; neomouse only
  observes to update state.

### The swallow flag and self-events

- `NeoMouse.swallowCurrentKeyEvent` is the **only** sanctioned "drop this event"
  bridge, and it exists for exactly one purpose: ⌘E deactivation must not type an
  "e". Reset at the top of every keystroke; set only in the deactivation branch.
- Synthesized events neomouse posts itself (e.g. ⌘C/⌘V for the clipboard) are
  tagged with `System.synthesizedEventUserData` ("NMOUSE") so the tap recognizes
  and passes them through instead of recursing.

### Tap disable / re-enable

If macOS disables the tap (`.tapDisabledByTimeout` / `.tapDisabledByUserInput`),
the callback re-enables it inline and passes the event through. This is a
**reactive re-enable on the next event**, not a background retry loop. If the tap
*can't be created at all*, `attachTapToRunLoop` logs and returns — the app runs
with no input interception (no crash).

---

## 6. Configuration

`neomouseConfig/config.swift`, `strictDecoding.swift`, `VimAsciiKeymap.swift`;
the shipped template is `settings.toml`, validated against
`schema/settings.schema.json` (`just check-config`).

### 6.1 Resolution order (first existing file wins)

1. `$NEOMOUSE_CONFIG` (explicit override)
2. `~/.config/neomouse/settings.toml`
3. `~/Library/Application Support/neomouse/settings.toml`

On first launch, `deployBundledDefaultsIfMissing()` copies the bundled
`settings.toml` (from the `.app`'s Resources) to `~/.config/neomouse/` so
brew/nix/manual installs all get a working template. It **never overwrites** an
existing file. Under bare `swift run` there's no bundle, so this is a no-op
(use `just init` in dev).

### 6.2 Loading & strict validation

`Config.loadConfig(from:)` reads the file and decodes with
`TOMLDecoder(.convertFromSnakeCase)`. Decoding is **strict and all-or-nothing**:
unknown keys, bad enum values, out-of-range numbers, and (for `[keymaps]`)
multi-char values or digit targets all throw. Failures surface as
`Config.LoadError` (`fileNotFound` / `readFailed` / `decodeFailed`), and the
underlying `DecodingError` names the offending key with a friendly message.

> There is **no per-option fallback** — a single bad key/value rejects the whole
> file. See §8 for what happens then.

New config keys must be additive: use `decodeIfPresent` + a `defaultX` static so
older files keep loading, keep `settings.toml`, the schema, and the model in
sync.

### 6.3 Hot reload

`Observers/SettingsWatcher.swift` watches the resolved file (debounced ~250 ms,
handles atomic-save renames). On a successful re-decode it calls
`appState.reload(from:)` and toasts "Reloaded settings.toml". **Selectively
live-reloadable:** `theme`, `is_auto_snap`, `front_app_follows_mouse`, and
`[keymaps]` (a keymap change also resets any pending op to avoid a mid-chord
desync). Everything else — `is_disable_key_input` (would require swapping the tap
flavor), `mode_on_start`, `[commands].available` — needs a restart.

### 6.4 Remappable keybindings (`[keymaps]`)

`Config.VimAsciiKeymap` lets users rebind letter/symbol Vim keys and the ⌘
activation chord, **without touching any handler logic** ("canonicalize once"):

- The map is keyed by the **canonical** Vim char; the value is the *physical*
  key you press. `canonical(forPhysical:)` reverse-resolves a pressed key to its
  canonical char *once* in `KeyDispatch`, and only `handleNormalMode` consumes
  it — so its `case "h":` literals never change.
- **Default == identity:** an empty map (and `toggle_activation = "e"`)
  reproduces today's behavior byte-for-byte. `[keymaps]` is optional.
- **Remapping moves an action:** if `j` is rebound to physical `n`, pressing the
  old `j` key resolves to `nil` (the default is *freed*, not duplicated). Swaps
  resolve both ways. Digit keys are the exception — never freed, never targets
  (they feed the count buffer).
- The Settings → Keybindings editor writes the section back via `KeymapWriter`
  (see §9.3). `settings.toml` ships every binding at its default, grouped, so the
  file documents the full catalog and round-trips cleanly.

---

## 7. Fallbacks & error handling — "what happens when…"

This is the section to read before assuming neomouse will crash on bad input. The
guiding rule: **be non-destructive and stay running.**

| Situation | What happens |
|---|---|
| **No `settings.toml` anywhere** | First run deploys the bundled default; otherwise launch with built-in defaults (`NeoMouseState()`). Not an error. |
| **`settings.toml` invalid at startup** | Caught in `NeoMouseApp.sharedState`; the message is stashed in `startupConfigError` and **toasted once the UI is up** ("settings.toml error — using defaults: …"). Falls back to **all** built-in defaults (whole file ignored). Never crashes. |
| **`settings.toml` invalid on hot-reload** | `SettingsWatcher` keeps the **previous good config** (the bad file is *not* applied) and toasts "Reload failed: …". |
| **Bad value granularity** | Whole-file, not per-option. One bad key rejects the entire file; the error names the key. There is no "default just that one option." |
| **Cursor position / screen size unavailable** | `makeKeyHandler` logs `[guard fail]` and drops the keystroke. |
| **No display under cursor** | `Screen.currentSize()` / `Mouse.moveRelative()` fall back to the main display; `moveToGlobal` clamps to the union of all displays (passes through unclamped if there are none). |
| **Accessibility / Input Monitoring not granted** | Tap fails to take effect this run; debug warning; grant applies next launch. |
| **OS disables the tap** | Re-enabled inline on the next event (reactive, not a retry loop). |
| **Screen Recording denied (yank)** | Toast "Screen Recording permission required…" and opens the Settings pane; the screenshot is skipped. |
| **Clipboard race on yank/paste** | `Pasteboard.waitForChange()` polls `changeCount`; **times out after ~1.5 s** and returns `nil` so callers skip stale content rather than store the wrong thing. |
| **Focus-follows-mouse with no window under cursor** | `setFrontMostAppOnCursorAsActiveIfNeeded` is a no-op (gated on `front_app_follows_mouse`, and `frontmostAppUnder()` may return `nil`). |
| **DB open fails** | `AppDatabase` calls `fatalError("Failed to open database")` — this is the one hard crash. |
| **DB read/write fails** | Caught and logged via `debug()`, then **swallowed silently** (~27 sites). The app stays consistent in memory but the write may be lost. |
| **Non-printable key (arrows, F-keys) in keybind matching** | `latinASCIIChar` returns `nil`; callers handle `nil` (no match). |

---

## 8. Persistence

### 8.1 The database (`neomouseDB`)

- **Location:** the SQLite file lives in `FileManager.default.temporaryDirectory`
  (`…/T/neomouse.sqlite`). ⚠️ This is the system temp dir — **not guaranteed to
  survive a reboot**. Treat session history as ephemeral until this moves to
  Application Support.
- **`initializeDB`** (run once at launch) is **not destructive by default**: it
  checks whether all six tables exist and returns early if so. It only drops &
  recreates everything when `FORCE_REINTIALIZE=1` is set. There is **no schema
  migration framework** — a schema change means manual deletion or
  `FORCE_REINTIALIZE=1` (this is tracked as an open issue; see `CLAUDE.md` #5).
- **Models** (`models/`): `Session` (name + timestamps), `Mark` (one per
  `(session, name)`, optional visual rect), `Register` (Vim-style clipboard slot
  storing a serialized `NSPasteboardItem`; `cycleNumbered()` implements the 1–9
  numbered-register ring), `Jump`, `Macro` (table creation currently commented
  out), and `ExecutedOperation` (per-keystroke history; table name
  `executed_operation`). The operation-category enums live here because they
  conform to GRDB's `DatabaseValueConvertible`.
- **Sessions:** `initializeDB` seeds one session (`id = 1`); on launch
  `Session.getLast()` (highest id) is the "current" session. ⚠️
  `new_session_on_open` and `max_session_count` are **parsed but not yet acted
  on** — sessions don't rotate or prune.

### 8.2 Why error swallowing matters here

DB writes go through `dbQueue.write` (synchronous) and every model wraps its I/O
in `try/catch` → `debug()`. A failed write (disk full, permission, conflict) is
invisible beyond the log, so the in-memory state and the DB can silently diverge.
Surfacing these is a known gap.

### 8.3 The settings.toml writers (Settings → Save)

`UI/Settings/SettingsView.swift`. Three writers persist edits back to the file.
All are **atomic** (write-temp-then-rename) and run in this order on Save:
`ConfigWriter` → `KeymapWriter` → `ThemeWriter` (each re-reads the file fresh).

- **`ConfigWriter`** — updates individual `[configuration]` booleans in place.
- **`KeymapWriter`** — replaces the `[keymaps]` block **in place** wherever the
  user put it (or introduces it before the theme block when absent). It does
  **not** relocate an existing section.
- **`ThemeWriter`** — regenerates the `[theme.*]` block **in place**: it replaces
  the contiguous run of theme sections (from the first `[theme.*]` header to the
  next non-theme header, or EOF) and **preserves everything before *and* after**.

> **Section ordering is free.** Because the theme writer no longer truncates to
> EOF, you can order `settings.toml`'s sections however you like — a `[keymaps]`
> (or any other) section placed *after* `[theme.*]` now survives a Save. The one
> assumption: keep the `[theme.*]` sub-sections contiguous as a group.

---

## 9. UI overlays & the theme bridge

Every overlay is a `.shared` singleton wired once at launch via
`passAppState(state:)` (except `ToastManager`, which reads
`NeoMouse.sharedState` directly). They render from `@Published` state, so config
hot-reloads and mode changes re-render them automatically.

- **`GridOverlay`** — the full-screen labeled grid for `f` find (narrows after
  the first keypress). **`CursorSurroundedGridOverlay`** — the dense one-shot
  grid around the cursor for `<space>f`. **`NumbersOverlay`** — the Vim ruler /
  `:cursorline`/`:cursorcolumn` bands (installs a mouse monitor in relative
  mode). **`VisualHighlightOverlay`** — the selection rectangle.
- **`ToastManager`** — transient pill, auto-dismiss ~3 s. **`KeyCast`** — the
  `showcmd` pill (count + pending op), gated by `is_show_key_cast`.
- **`CommandLine`** — the `:` panel + fuzzy wildmenu. **`HelpDialog`** — the `?`
  help window. **`MarksMenu`** / **`RegisterMenu`** — non-activating panels.
  **`MenuBar`** — the status item; its icon color encodes the current mode.
- **Theme bridge:** `Config.Theme` is AppKit/SwiftUI-free; `UI/Theme/
  Theme+SwiftUI.swift` maps `ThemeColor`/`ThemeFont`/`ThemeMaterial`/`ThemeAnchor`
  to SwiftUI/AppKit. A custom font family that can't be found falls back to the
  system font.

---

## 10. Operations & utils

- **`CoreOperations`** / **`ExecutionPipeline`** — yank (`normalYank` screenshots
  the visual rect, excluding overlay windows), register yank/paste, visual
  enter/exit/restore-previous (`gv`), and `setFrontMostAppOnCursorAsActiveIfNeeded`
  (the focus-follows-mouse hook, gated on the config flag). The pipeline has
  `preHooks`/`postHooks` arrays; post-hooks currently just record operations.
- **`Mouse`** — `moveToGlobal` does a `CGWarpMouseCursorPosition` *then* posts a
  synthetic move/drag to `.cgSessionEventTap` (so observers and drags track),
  clamped to all displays. **`Screen`** — display geometry with main-display
  fallbacks. **`Gesture`** — pinch-zoom / rotate / smart-magnify via phased
  events. **`Zoom`** — reads/pans the macOS accessibility zoom. **`Pasteboard`** —
  serialize items + the `waitForChange` race-fix. **`System`** — synthesized-key
  tagging and `restart()`.
- **Layout-independent ASCII** (`Keyboard/keyCodeToCharMap.swift`): Vim keys must
  work on any keyboard layout/IME. `latinASCIIChar(keyCode, modifiers)` translates
  the keycode against an ASCII-capable layout regardless of the active input
  source (only Shift/Option count; Cmd/Ctrl/CapsLock are ignored). `asciiChar`
  (shift+option) and `asciiCharIgnoringModifiers` (shift only) are the
  event-level wrappers used in dispatch. `KeyCodeMap` rebuilds on layout-switch
  notifications, lock-guarded.

---

## 11. App lifecycle

`App/NeoMouseApp.swift`, `App/AppDelegate.swift`.

- **Launch:** `sharedState` deploys defaults if missing → loads config (or
  defaults, stashing any error) → `initializeDB` → resolve current session
  (fatal dialog if none) → wire overlays' `passAppState` → `installKeyEventTap`
  → build `keyHandler` → install the visual/pasteboard/settings observers →
  `notifyStartupConfigErrorIfNeeded()` (toasts a bad-config message). The scene
  is a single `MenuBar` (`LSUIElement` + `.accessory` activation policy → no Dock
  icon).
- **Terminate** (`applicationWillTerminate`): disable+remove the tap, cancel
  Combine subscriptions, stop watchers, post mouse-up to release any synthetic
  drag, exit visual mode, hide overlays, clear state.
- **`:restart`** (`System.restart()`): spawns a detached relaunch (bundled `.app`
  via `open`, or `swift run` in dev), posts mouse-up to release a drag, then calls
  **`exit(0)` directly** — bypassing AppKit's shutdown so the successor doesn't
  briefly run a second event tap. TCC grants carry over because the path is
  unchanged.

---

## 12. Known gaps (see `CLAUDE.md` "Open work" for the tracked issues)

- **DB in the temp dir** → history may not survive reboots; **no migration path**
  (schema change = destructive re-init).
- **Silent DB error swallowing** — failures only hit the debug log.
- **`new_session_on_open` / `max_session_count` unused** — no session rotation.
- **Config errors are whole-file**, not per-option (startup now toasts; reload
  already did).
- **`KeyHandlers`/`NeoMouseApp` monoliths** and the `#3` command-categorization /
  pre-after-hook pipeline are the active refactor seams.

---

*Keep this doc honest: it describes runtime behavior, which moves fast. When you
change a fallback, a mode transition, or an error path, update the relevant
section here and the "what happens when…" table in §7.*
