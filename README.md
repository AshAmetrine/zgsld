# ZGSLD

ZGSLD (Zig Greeter and Session Launcher Daemon) provides a daemon for launching greeters and user sessions, alongside a Zig library.

The library includes modules for building greeters and custom daemons. Greeters can use an external daemon or embed the ZGSLD daemon in the same executable. Custom IPC codecs support integration with greeters and daemons that were not built for ZGSLD.

## Features

- Greeters with an optional embedded ZGSLD daemon.
- Custom IPC codecs for compatibility with other greeters and daemons.
- Greeter previews with mock authentication.
- Autologin with an optional interruptible delay.
- X11 session support.

## Running the daemon

Choose a [greeter](docs/content/ecosystem.md#greeters) to run with ZGSLD.

### Dependencies

- libc
- pam

### Installation

#### Nix Flake

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

#### From Source

Building from source requires Zig 0.17.0.

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
sudo cp res/pam.d/zgsld-greeter /etc/pam.d/zgsld-greeter
```

Then **install the appropriate service file for your init system** from `res/services/`.

### Configuration

The default config file path is `/etc/zgsld/zgsld.ini`.
Set `command` in the `[greeter]` section to your greeter executable.

See [`res/zgsld.ini`](res/zgsld.ini) for the available sections and settings.

## Using the library

### Adding the dependency

Add the dependency with `zig fetch`:

```sh
zig fetch --save git+https://github.com/ashametrine/zgsld
```

Configure the dependency in `build.zig`:

```zig
const zgsld = b.dependency("zgsld", .{
    .target = target,
    .optimize = optimize,
});
```

### Modules

Choose the module for your project.

#### Greeter

For building greeter applications.

```zig
exe.root_module.addImport("zgsld-greeter", zgsld.module("greeter"));
```

#### Daemon

For building custom daemons.

```zig
exe.root_module.addImport("zgsld", zgsld.module("daemon"));
```

#### IPC

For implementing custom codecs.

```zig
exe.root_module.addImport("zgsld-ipc", zgsld.module("ipc"));
```

### Build options

| Option         | Default | Modules         | Description                                       |
|----------------|---------|-----------------|---------------------------------------------------|
| `embed_daemon` | `true`  | Greeter         | Embed the ZGSLD daemon in the greeter executable. |
| `x11`          | `true`  | Daemon, Greeter | Enable X11 session support.                       |

For greeters, `x11` only applies when `embed_daemon = true`.

Set `embed_daemon = false` to build a greeter launched by an external daemon.
