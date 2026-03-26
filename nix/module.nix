{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.zgsld;
  x11Support = cfg.package.x11Support;
  xserverBin = config.services.xserver.displayManager.xserverBin;
  xserverArgs = config.services.xserver.displayManager.xserverBin;

  x11Command = lib.escapeShellArgs ([ xserverBin ] ++ xserverArgs);

  iniFmt = pkgs.formats.iniWithGlobalSection { };

  defaultConfig = {
    globalSection = {
      vt = cfg.vt;
    };
    sections = {
      session = {
        service_name = "zgsld";
      };
      greeter = {
        user = "greeter";
        service_name = "zgsld-greeter";
        session_type = cfg.greeter.sessionType;
        command = cfg.greeter.command;
      };
    };
  }
  // lib.optionalAttrs (x11Support) {
    sections.x11.cmd = x11Command;
  };

  finalConfig = lib.recursiveUpdate defaultConfig cfg.settings;
in
{
  options.services.zgsld = {
    enable = lib.mkEnableOption "zgsld daemon";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.zgsld;
      description = ''
        The `zgsld` package to run.
      '';
    };

    settings = lib.mkOption {
      type = iniFmt.type;
      default = { };
      description = ''
        Additional INI settings merged into the generated `zgsld.ini`.
      '';
    };

    vt = lib.mkOption {
      type = lib.types.ints.between 1 63;
      default = 1;
      description = ''
        VT to switch to before launching the greeter.
      '';
    };

    greeter = {
      command = lib.mkOption {
        type = lib.types.nonEmptyStr;
        example = "/run/current-system/sw/bin/zgsld-agetty-greeter";
        description = ''
          Command executed as the greeter.
        '';
      };

      sessionType = lib.mkOption {
        type = lib.types.enum [
          "command"
          "x11"
        ];
        default = "command";
        description = ''
          Session backend used for the greeter.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.greeter.sessionType != "x11" || x11Support != false;
        message = ''
          services.zgsld.greeter.sessionType = "x11" requires an x11-enabled package.
          Set services.zgsld.package = pkgs.zgsld.override { x11Support = true; }.
        '';
      }
    ];

    systemd.services."autovt@tty${toString cfg.vt}".enable = false;

    users.users.${cfg.greeter.user} = {
      isSystemUser = true;
      group = cfg.greeter.user;
    };

    users.groups.${cfg.greeter.user} = { };

    security.pam.services = {
      zgsld = {
        startSession = true;
        enableGnomeKeyring = lib.mkDefault config.services.gnome.gnome-keyring.enable;
      };
      zgsld-greeter = {
        startSession = true;
        setLoginUid = false;
        unixAuth = false;
      };
    };

    systemd.services.zgsld = {
      description = "Zig Greeter and Session Launcher Daemon";
      aliases = [ "display-manager.service" ];
      wantedBy = [ "multi-user.target" ];
      after = [
        "systemd-user-sessions.service"
        "getty@tty${toString cfg.vt}.service"
      ];
      restartIfChanged = false;
      conflicts = [ "getty@tty${toString cfg.vt}.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${lib.getExe cfg.package} --config ${iniFmt.generate "zgsld.ini" finalConfig}";
        Restart = "on-failure";
        RestartSec = "1s";
      };
    };
  };
}
