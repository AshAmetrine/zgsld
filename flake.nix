{
  description = "zgsld flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
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
        pkgs.nixfmt-rfc-style
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
