{
  inputs = {
    nixpkgs = {
      url = "github:NixOS/nixpkgs?ref=nixpkgs-unstable";
    };

    # Used for shell.nix
    flake-compat = {
      url = "github:NixOS/flake-compat";
      flake = false;
    };

    zon2nix = {
      url = "github:jcollie/zon2nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      zon2nix,
      ...
    }@inputs:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
      devShells = forAllSystems (pkgs: {
        default = pkgs.callPackage ./nix/devShell.nix {
          zig = pkgs.zig_0_15;
          zon2nix = zon2nix.packages.${pkgs.stdenv.hostPlatform.system}.zon2nix;
        };
      });
      packages = forAllSystems (pkgs: rec {
        default = emacs-spectreshell;
        emacs-spectreshell = pkgs.callPackage ./nix/emacs-spectreshell.nix {
          zig = pkgs.zig_0_15;
        };
      });
      checks = forAllSystems (
        pkgs:
        let
          package = self.packages.${pkgs.stdenv.hostPlatform.system}.emacs-spectreshell;
        in
        {
          # doCheck = true のパッケージビルド自体が Zig テストと ERT を含む。
          package = package;
          # Justfile の nix-check 相当: 成果物レイアウトだけで module-load +
          # feed + terminfo 検出が成立することのスモークテスト。
          artifact-smoke =
            pkgs.runCommand "emacs-spectreshell-artifact-smoke"
              {
                nativeBuildInputs = [ pkgs.emacs31-nox ];
              }
              ''
                test -f ${package}/share/info/spectreshell.info
                test -f ${package}/share/doc/spectreshell/LICENSE
                test -f ${package}/share/doc/spectreshell/THIRD-PARTY-NOTICES.org
                emacs -Q --batch -L ${package}/share/emacs/site-lisp --eval '
                  (progn
                    (require (quote spectreshell))
                    (require (quote spectreshell-eshell))
                    (with-temp-buffer
                      (let ((term (spectreshell-start (current-buffer) 5 10 (lambda (bytes) bytes))))
                        (spectreshell-feed term "hello")
                        (unless (string-prefix-p "hello" (buffer-string))
                          (error "artifact-smoke: unexpected buffer contents: %S" (buffer-string)))
                        (unless spectreshell-terminfo-directory
                          (error "artifact-smoke: terminfo not auto-detected"))
                        (message "artifact-smoke OK"))))'
                touch $out
              '';
        }
      );
    };
}
