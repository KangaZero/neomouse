{
  description = "neomouse — Vim-motion mouse control daemon for macOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      version = "0.0.0";

      # Both Mac families. The release tarball is a UNIVERSAL binary (arm64 +
      # x86_64), so every system fetches the *same* artifact with the *same*
      # hash — no per-system url/hash split needed.
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      mkNeomouse =
        pkgs:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "neomouse";
          inherit version;

          # Wraps the pre-built, ad-hoc-signed release binary so users don't
          # need a Swift toolchain or Xcode. Update url + hash + `version`
          # together — `scripts/release.sh` does this automatically each
          # release. The "-macos-universal" tarball runs on both arm64 + x86_64.
          src = pkgs.fetchurl {
            url = "https://github.com/KangaZero/neomouse/releases/download/v${version}/neomouse-v${version}-macos-universal.tar.gz";
            hash = "sha256-wsXhazimEwuv90+33IdAHU+BwXIizKKrMRazwLqHefE=";
          };

          # The tarball expands to `neomouse.app/` at the root (Contents/
          # Info.plist, Contents/MacOS/neomouse).
          sourceRoot = ".";

          # SwiftUI's MenuBarExtra status item only registers when
          # LaunchServices can read CFBundleIdentifier from a .app/Contents/
          # Info.plist — a bare-binary install won't show the menu-bar icon.
          # So we install the whole .app under $out/Applications/ and symlink
          # the inner binary into $out/bin/ so `neomouse` is on PATH.
          installPhase = ''
            runHook preInstall
            mkdir -p "$out/Applications"
            cp -R neomouse.app "$out/Applications/"
            mkdir -p "$out/bin"
            ln -s "$out/Applications/neomouse.app/Contents/MacOS/neomouse" "$out/bin/neomouse"
            runHook postInstall
          '';

          meta = {
            description = "Vim-motion mouse control daemon for macOS";
            homepage = "https://github.com/KangaZero/neomouse";
            license = pkgs.lib.licenses.mit;
            platforms = pkgs.lib.platforms.darwin;
            mainProgram = "neomouse";
          };
        };
    in
    {
      packages = forAllSystems (pkgs: {
        default = mkNeomouse pkgs;
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${mkNeomouse pkgs}/bin/neomouse";
        };
      });
    };
}
