# Installation

Choose a [greeter](../ecosystem.md#greeters) to run with ZGSLD.

## Dependencies

- libc
- pam

## Nix Flake

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

## From Source

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
