# Custom IPC codecs

This library supports replacing the default IPC codec by implementing `readEvent` and `writeEvent`, which convert between bytes and `ipc.Event`.

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
});
```

Add the ipc module as an import:

```zig
exe.root_module.addImport("zgsld-ipc", zgsld.module("ipc"));
```

## Example

In the following example, `readEvent` and `writeEvent` delegate to the built-in binary codec. For a custom codec, replace them with your own decoding/encoding implementations.

`readEvent` receives a reader and writer for the same connection, allowing codecs to send protocol replies while decoding events.
The codec must flush these replies before reading further input or returning an event.

```zig
const std = @import("std");
const ipc = @import("zgsld-ipc");

pub var interface: ipc.Codec = .{
    .vtable = &.{
        .readEvent = readEvent,
        .writeEvent = writeEvent,
    },
};

fn readEvent(
    _: *ipc.Codec,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    event_buf: []u8,
) !ipc.Event {
    return ipc.Codec.binary.readEvent(reader, writer, event_buf);
}

fn writeEvent(
    _: *ipc.Codec,
    writer: *std.Io.Writer,
    event: *const ipc.Event,
) !void {
    try ipc.Codec.binary.writeEvent(writer, event);
}
```
