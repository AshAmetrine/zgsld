{
  lib,
  stdenv,
  zigPackage,
  autoPatchelfHook,
  linux-pam,
  versionCheckHook,
  x11Support ? true,
}:

zigPackage {
  pname = "zgsld";
  version = "0.1.0";

  src = lib.cleanSource ../.;
  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [
    linux-pam
  ];

  zigBuildFlags = [
    "--release=safe"
  ]
  ++ lib.optional x11Support "-Dx11";

  nativeInstallCheckInputs = [ versionCheckHook ];
  doInstallCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;

  meta = {
    description = "Zig Greeter and Session Launcher Daemon";
    homepage = "https://github.com/ashametrine/zgsld";
    license = lib.licenses.mit;
    mainProgram = "zgsld";
    platforms = lib.platforms.linux;
  };

  passthru = {
    inherit x11Support;
  };
}
