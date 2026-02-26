# ZGSLD

ZGSLD (Zig Greeter and Session Launcher Daemon), is a daemon for launching greeters, handling PAM authentication through IPC, and launching a session.

## Quick start



## API Documentation

Generate docs locally:

```sh
zig build docs
```

Generated files are written to `zig-out/docs`.

## Configuration

An example configuration is in `res/zgsld.ini`.

## Dependencies

- Zig 0.15.2
- libc
- pam

## Greeter Development

A greeter can be built either as a separate executable or bundled with zgsld to produce a single executable which will call itself to launch the greeter.

Add the dependency with `zig fetch`:

```sh
zig fetch --save git+https://github.com/Kawaii-Ash/zgsld
```

```zig
const zgsld = b.dependency("zgsld", .{
    .target = target,
    .optimize = optimize,
    .standalone = standalone,
    .x11 = false,
});

exe.root_module.addImport("zgsld", zgsld.module("zgsld"));
```

For a usage example, you can check [zgsld-agetty](https://github.com/Kawaii-Ash/zgsld-agetty)
