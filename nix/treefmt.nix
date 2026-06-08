{ pkgs, ... }:
{
  projectRootFile = "flake.nix";

  programs.nixfmt.enable = true;
  programs.zig.enable = true;
  programs.zig.package = pkgs.zig;
}
