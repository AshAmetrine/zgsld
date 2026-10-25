{
  description = "ZGSLD: a minimal display manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    zig2nix = {
      url = "github:Cloudef/zig2nix";
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
      zig2nix,
      zls-flake,
      treefmt-nix,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs (builtins.attrNames zig2nix.packages);
      zigEnv =
        system:
        zig2nix.outputs.zig-env.${system} {
          inherit nixpkgs;
          zig = zig2nix.packages.${system}.zig-0_17_0;
          zls = zls-flake.packages.${system}.zls;
        };
      zgsldOverlay = final: _prev: {
        zgsld = final.callPackage ./nix/package.nix {
          zigPackage = (zigEnv final.stdenv.hostPlatform.system).package;
        };
      };
      zigDevOverlay =
        final: prev:
        let
          env = zigEnv prev.stdenv.hostPlatform.system;
        in
        {
          inherit (env) zig zls;
        };
      treefmtFor =
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ zigDevOverlay ];
          };
        in
        treefmt-nix.lib.evalModule pkgs ./nix/treefmt.nix;
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

      formatter = forAllSystems (system: (treefmtFor system).config.build.wrapper);

      checks = forAllSystems (system: {
        formatting = (treefmtFor system).config.build.check self;
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ zigDevOverlay ];
          };
        in
        {
          default = (zigEnv system).mkShell {
            name = "zgsld-devshell";
            nativeBuildInputs = with pkgs; [
              linux-pam
              mkdocs
              python3Packages.mkdocs-material
            ];
          };
        }
      );
    };
}
