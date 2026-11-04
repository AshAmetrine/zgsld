# Building a daemon

See the [generated Zig docs](pathname:///zgsld/zig/) for the full API reference and [Libraries and Daemons](../ecosystem.md#libraries-and-daemons) for complete implementations.

## Adding the dependency

Add the dependency with `zig fetch`:

```sh
zig fetch --save git+https://github.com/ashametrine/zgsld
```

Configure the dependency in `build.zig`:

```zig
const zgsld = b.dependency("zgsld", .{
    .target = target,
    .optimize = optimize,
    .x11 = x11_support,
});
```

Add the daemon module as an import:

```zig
exe.root_module.addImport("zgsld", zgsld.module("daemon"));
```

## Minimal Example

```zig
const std = @import("std");
const zgsld = @import("zgsld");

pub fn main(init: std.process.Init) !void {
    if (try zgsld.runWorkerIfRequested(.fromInit(&init))) return;

    try zgsld.run(.fromInit(&init), .{
        .config = .{
            .greeter = .{
                .command = "path/to/greeter",
            },
        },
    });
}
```

Call `runWorkerIfRequested` before any application setup. Continue normal setup if it returns false. Otherwise, return from `main`.

See [Configuration](../daemon/configuration.md) for the settings accepted by `.config`.

## Custom IPC codecs

The daemon uses the built-in binary codec by default. Pass a custom codec through `.ipc_codec`:

```zig
try zgsld.run(.fromInit(&init), .{
    .config = config,
    .ipc_codec = &codec.interface,
});
```

See [Custom IPC codecs](ipc.md) for details on writing a custom codec.
