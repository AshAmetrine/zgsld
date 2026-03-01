{
  lib,
  stdenv,
  callPackage,
  zig,
  linux-pam,
  x11Support ? true,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "zgsld";
  version = "0.1.0";

  src = lib.cleanSource ../.;
  deps = callPackage ./build.zig.zon.nix { };

  nativeBuildInputs = [
    zig.hook
  ];

  buildInputs = [
    linux-pam
  ];

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
  ]
  ++ lib.optional x11Support "-Dx11";

  meta = {
    description = "Zig Greeter and Session Launcher Daemon";
    homepage = "https://github.com/Kawaii-Ash/zgsld";
    license = lib.licenses.mit;
    mainProgram = "zgsld";
    platforms = lib.platforms.linux;
  };

  passthru = {
    inherit x11Support;
  };
})
