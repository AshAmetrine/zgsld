{
  description = "ZGSLD: a minimal display manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;
      zgsldOverlay = final: _prev: {
        zgsld = final.callPackage ./nix/package.nix { };
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
            nixpkgs.overlays = [ self.overlays.default ];
            #services.zgsld.package = lib.mkDefault self.packages.${pkgs.system}.default;
          };
        default = self.nixosModules.zgsld;
      };

      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ zgsldOverlay ];
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
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.nixfmt-tree
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            name = "zgsld-devshell";
            packages = with pkgs; [
              zig
              zls
              linux-pam
            ];
          };
        }
      );
    };
}
