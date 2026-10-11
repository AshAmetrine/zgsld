{
  description = "ZGSLD: a minimal display manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zls-flake = {
      url = "github:zigtools/zls/0.17.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      zig-overlay,
      zls-flake,
      treefmt-nix,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;
      zgsldOverlay = final: _prev: {
        zgsld = final.callPackage ./nix/package.nix { };
      };
      zigDevOverlay =
        final: prev:
        let
          system = prev.stdenv.hostPlatform.system;
        in
        {
          zls = zls-flake.packages.${system}.zls;
          zig = zig-overlay.packages.${system}."0.17.0";
        };
    in
    {
      overlays.default = zgsldOverlay;

      nixosModules = {
        zgsld =
          {
            lib,
            pkgs,
            ...
          }:
          {
            imports = [ ./nix/module.nix ];
            nixpkgs.overlays = [
              zigDevOverlay
              self.overlays.default
            ];
          };
        default = self.nixosModules.zgsld;
      };

      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              zigDevOverlay
              zgsldOverlay
            ];
          };
        in
        {
          inherit (pkgs) zgsld;

          default = pkgs.zgsld;
        }
      );

      formatter = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ zigDevOverlay ];
          };
        in
        (treefmt-nix.lib.evalModule pkgs ./nix/treefmt.nix).config.build.wrapper
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ zigDevOverlay ];
          };
        in
        {
          default = pkgs.mkShell {
            name = "zgsld-devshell";
            packages = with pkgs; [
              zig
              zls
              linux-pam
              mkdocs
              python3Packages.mkdocs-material
              zon2nix
            ];
          };
        }
      );
    };
}
