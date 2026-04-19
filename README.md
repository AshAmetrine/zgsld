# ZGSLD

ZGSLD (Zig Greeter and Session Launcher Daemon), is a daemon for launching greeters, handling PAM authentication through IPC, and launching a session.

## Features

- Supports standalone greeter builds without requiring the `zgsld` executable to be installed.
- Autologin support with an optional interruptible delay that falls back to the greeter.
- Can be built with X11 session support.

## Dependencies

- Zig 0.16.0
- libc
- pam

## Installation

### Nix Flake

Add `zgsld` as a flake input:

```nix
{
  inputs.zgsld.url = "github:ashametrine/zgsld";
}
```

For NixOS, import the module and enable the service:

```nix
{
  outputs = { nixpkgs, zgsld, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        zgsld.nixosModules.default
        {
          services.zgsld = {
            enable = true;
            vt = 1;
            greeter = {
              command = "/path/to/your-greeter";
              sessionType = "command"; # or "x11"
            };
          };
        }
      ];
    };
  };
}
```

### From Source

**Build and install the `zgsld` executable:**

```sh
zig build -Doptimize=ReleaseSafe

sudo cp zig-out/bin/zgsld /usr/local/bin/zgsld
```

Example config, PAM, and service files are available in `res/`.

**Create the greeter user:**

```sh
# Linux
sudo useradd -M greeter

# FreeBSD
sudo pw useradd greeter -d /nonexistent -s /usr/sbin/nologin
```

**Copy the config and PAM files:**

```sh
sudo mkdir -p /etc/zgsld /etc/pam.d
sudo cp res/zgsld.ini /etc/zgsld/zgsld.ini
sudo cp res/pam.d/zgsld /etc/pam.d/zgsld
```

Then **install the appropriate service file for your init system** from `res/services/`.

## Usage

First, choose a greeter you want to use.

Some greeters may provide a standalone build with `zgsld` functionality built in. In that case, refer to the greeter's documentation.

Otherwise, `zgsld` runs the greeter configured in `/etc/zgsld/zgsld.ini`.

## Configuration

The default config file path is `/etc/zgsld/zgsld.ini`.

See `res/zgsld.ini` for the documented example configuration file. The inline comments describe the available sections and settings.

## Greeter Development

A greeter can be built either as a separate executable or bundled with zgsld to produce a single executable which will call itself to launch the greeter.

Add the dependency with `zig fetch`:

```sh
zig fetch --save git+https://github.com/ashametrine/zgsld
```

```zig
const zgsld = b.dependency("zgsld", .{
    .target = target,
    .optimize = optimize,
    .standalone = standalone,

    // extra opts for standalone builds
    .x11 = x11_support,
});

exe.root_module.addImport("zgsld", zgsld.module("zgsld"));
```

### API Documentation

Generate and serve the API documentation for local browsing:

```sh
zig build docs
python3 -m http.server --bind 127.0.0.1 -d zig-out/docs
```
