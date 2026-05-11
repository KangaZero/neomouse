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

        # The tarball contains just the binary at the root, with no enclosing
        # directory.
        sourceRoot = ".";

        installPhase = ''
          runHook preInstall
          install -Dm755 neomouse "$out/bin/neomouse"
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
