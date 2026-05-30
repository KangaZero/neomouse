# v0.0.1 release prep

This directory holds artifacts that must be deployed alongside the v0.0.1
release tag — they can't be pushed independently or `brew install neomouse`
will break for users on the still-current v0.0.0 tarball.

## `neomouse.rb` — Homebrew formula update

The release tarball will start shipping a `neomouse.app` bundle (not a bare
binary) at v0.0.1 — required for SwiftUI MenuBarExtra to register a
status item. The current tap formula installs as a bare binary
(`bin.install "neomouse"`) and would error on v0.0.1's tarball with "no
such file 'neomouse'".

`neomouse.rb` in this directory has the updated `install` block (installs
the .app bundle under prefix + symlinks the inner binary to `bin/`), a
`caveats` block explaining the bundle location, and bumps `depends_on
macos:` from `:ventura` (13) to `:sonoma` (14) to match the project's
actual floor (ScreenCaptureKit requires 14+).

### How to apply

Right before — or as the first step of — cutting v0.0.1:

```sh
git clone git@github.com:KangaZero/homebrew-neomouse.git /tmp/tap
cp scripts/release-v0.0.1-prep/neomouse.rb /tmp/tap/Formula/neomouse.rb
cd /tmp/tap
git add Formula/neomouse.rb
git commit -m "formula: install .app bundle and symlink inner binary to bin/"
git push origin main
```

Then run `scripts/release.sh v0.0.1`. The release script's existing sed step
will bump the `url` / `sha256` / `version` lines to point at the new
release; everything else (install block / caveats / depends_on) is what
this manual update set.

## Verification after release

```sh
brew untap KangaZero/neomouse 2>/dev/null   # in case it's tapped
brew tap KangaZero/neomouse
brew install neomouse
brew test neomouse
neomouse                                     # via the symlink on PATH
open "$(brew --prefix neomouse)/neomouse.app"
```

The menu bar should show the cursor status icon. If it doesn't:
1. `lsappinfo info "$(pgrep -f neomouse.app | head -1)"` — confirm
   `CFBundleIdentifier=com.kangazero.neomouse`. If NULL, the bundle's
   metadata isn't being read.
2. `codesign --verify --strict "$(brew --prefix neomouse)/neomouse.app"`
   should pass.
