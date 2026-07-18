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

    systems = {
      url = "github:nix-systems/default";
      flake = false;
    };

    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-compat.follows = "flake-compat";
        systems.follows = "systems";
      };
    };

    zon2nix = {
      url = "github:nix-community/zon2nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        zig-overlay.follows = "zig-overlay";
      };
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      zig-overlay,
      zon2nix,
      ...
    }@inputs:
    let
      platforms = nixpkgs.lib.attrNames zig-overlay.packages;
      forAllPlatforms = f: nixpkgs.lib.genAttrs platforms (s: f nixpkgs.legacyPackages.${s});
    in
    {
      formatter = forAllPlatforms (pkgs: pkgs.nixfmt-tree);
      devShells = forAllPlatforms (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.nixfmt
          ];
        };
      });
    };
}
