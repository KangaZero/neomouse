class Neomouse < Formula
  desc "Vim-motion mouse control daemon for macOS"
  homepage "https://github.com/KangaZero/neomouse"
  url "https://github.com/KangaZero/neomouse/releases/download/v0.0.0/neomouse-v0.0.0-macos-arm64.tar.gz"
  sha256 "c2c5e16b38a6130baff74fb7dc87401d4f81c17222cca2ab3116b3c0ba8779f1"
  version "0.0.0"
  license "MIT"

  depends_on macos: :sonoma
  depends_on arch: :arm64

  # The release tarball now ships a `neomouse.app` bundle (not a bare binary)
  # because SwiftUI's MenuBarExtra status item only registers when
  # LaunchServices can read CFBundleIdentifier from .app/Contents/Info.plist.
  # We install the bundle under the prefix and symlink the inner binary onto
  # PATH so `neomouse` still works as a CLI invocation.
  def install
    prefix.install "neomouse.app"
    bin.install_symlink prefix/"neomouse.app/Contents/MacOS/neomouse"
  end

  def caveats
    <<~EOS
      neomouse is a menu-bar daemon. The .app bundle is installed at:
        #{opt_prefix}/neomouse.app

      Launch options (any of these works):
        neomouse                                    # via the PATH symlink
        open #{opt_prefix}/neomouse.app
        #{opt_prefix}/neomouse.app/Contents/MacOS/neomouse

      First launch:
        - macOS will prompt for Accessibility permissions. Allow `neomouse` in
          System Settings → Privacy & Security → Accessibility, then relaunch.
        - The bundled default `settings.toml` is copied to
          ~/.config/neomouse/settings.toml (only if no file is already there).
          Edit that file to customize; the deploy never overwrites your config.
    EOS
  end

  test do
    assert_predicate bin/"neomouse", :executable?
    assert_predicate prefix/"neomouse.app/Contents/Info.plist", :exist?
    assert_predicate prefix/"neomouse.app/Contents/Resources/settings.toml", :exist?
  end
end
