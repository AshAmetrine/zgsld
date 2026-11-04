---
slug: /
---

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

- [Installation](daemon/installation.md)
- [Greeters](ecosystem.md#greeters)
- [Configuration](daemon/configuration.md)

## Using the library

- [Building a greeter](library/greeter.md)
- [Building a daemon](library/daemon.md)
- [Custom IPC codecs](library/ipc.md)
- [Previews](library/previews.md)
- [API reference](pathname:///zgsld/zig/)

## IPC protocol

See [IPC protocol](ipc-protocol.md) for details of ZGSLD's IPC protocol.

## Ecosystem

See [Ecosystem](ecosystem.md) for greeters, daemons, and libraries built with ZGSLD.
