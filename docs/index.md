# Getting Started

ZGSLD (Zig Greeter and Session Launcher Daemon), is a daemon for launching greeters, handling PAM authentication through IPC, and launching a session.

Greeters are made by using the provided Zig module, which supports embedding ZGSLD functionality, so greeters do not have to depend on the `zgsld` executable. If you would like to find out more about developing a greeter with ZGSLD, refer to the [Greeter Development](greeter-development.md) section.

## Features

ZGSLD officially supports Linux and FreeBSD.

- Supports standalone greeter builds without requiring the `zgsld` executable to be installed.
- Autologin support with an optional interruptible delay that falls back to the greeter.
- Can be built with X11 session support.

## Usage

First, choose a greeter you want to use.

Greeters can provide a standalone build with ZGSLD functionality built-in. 
If you would rather have a single executable rather than requiring to run it with `zgsld`, 
refer to the greeter's documentation to see if the greeter supports this use-case.

Otherwise, continue reading through this guide.

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

### Build From Source

#### Dependencies

- [Zig 0.15.2](https://ziglang.org/)
- libc
- libpam

#### Building

Build and install the `zgsld` executable:

```sh
zig build -Doptimize=ReleaseSafe

sudo cp zig-out/bin/zgsld /usr/local/bin/zgsld
```

#### Create The Greeter User

- **Linux:** `#!sh sudo useradd -M greeter`
- **FreeBSD:** `#!sh sudo pw useradd greeter -d /nonexistent -s /usr/sbin/nologin`

#### Install Example Configuration And PAM Files

The repository ships example configuration, PAM, and service files in `res/`.

```sh
sudo mkdir /etc/zgsld

sudo cp res/zgsld.ini /etc/zgsld/zgsld.ini
sudo cp res/pam.d/zgsld /etc/pam.d/zgsld
```

#### Install Service File

Some service files are provided in the repository at `res/services`.

If none of them are applicable to your system, feel free to open an issue or a pull request.
