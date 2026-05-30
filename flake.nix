{
  description = "neomouse — Vim-motion mouse control daemon for macOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      version = "0.0.0";
    in
    {
      packages.${system}.default = pkgs.stdenvNoCC.mkDerivation {
        pname = "neomouse";
        inherit version;

        # Wraps the pre-built, ad-hoc-signed release binary so users don't need
        # a Swift toolchain or Xcode. Update url + hash + `version` together
        # — `scripts/release.sh` does this automatically each release.
        src = pkgs.fetchurl {
          url = "https://github.com/KangaZero/neomouse/releases/download/v${version}/neomouse-v${version}-macos-arm64.tar.gz";
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
          platforms = [ "aarch64-darwin" ];
          mainProgram = "neomouse";
        };
      };

      apps.${system}.default = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/neomouse";
      };
    };
}
