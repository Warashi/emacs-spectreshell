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
        default = libspectreshell;
        libspectreshell = pkgs.callPackage ./nix/libspectreshell.nix {
          zig = pkgs.zig_0_15;
        };
      });
    };
}
