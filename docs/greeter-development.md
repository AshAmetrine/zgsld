# Greeter Development

You can use the ZGSLD library to build a greeter that handles user interaction, while ZGSLD manages authentication and launching sessions.

For complete implementations, see [Greeters](greeters.md).

## Add The Dependency

Fetch the project as a Zig dependency:

```sh
zig fetch --save git+https://github.com/ashametrine/zgsld
```

Then add the dependency in your build:

```zig
const zgsld = b.dependency("zgsld", .{
    .target = target,
    .optimize = optimize,
    .standalone = standalone,

    // Extra options for standalone builds.
    .x11 = x11_support,
});

exe.root_module.addImport("zgsld", zgsld.module("zgsld"));
```

## Build Options

### `standalone`

Whether to embed the daemon in your greeter. Defaults to `true`, producing a standalone executable.

Set this to `false` to use a separate `zgsld` daemon, allowing users to switch greeters while keeping the same daemon setup.

### `x11`

Whether standalone builds should support starting the X server. This is a no-op when `.standalone = false`.

## API

For the full API reference, see the [generated Zig docs](../zig/).

### `Zgsld.init`

In your `main()` function, you will want to `init` the `Zgsld` struct and then call the `run` function:

```zig
const app = Zgsld.init(.{
    .process = .fromInit(init),
    .vtable = &.{
        .run = run,
        .configure = configure,
    },
});
```

#### `.run`

Function Signature: `fn run(ctx: Zgsld.GreeterContext) !void`

The `run` function is the main entrypoint to your greeter. This will be called in both standalone and greeter-only builds.

You most likely want to parse any args your greeter needs here, then run your greeter code.


#### `.configure`

Function Signature: `fn configure(ctx: Zgsld.ConfigureContext) !void`

`configure` is for standalone builds to have control over `zgsld` configuration options. It is never called in greeter-only (non-standalone) builds. 

### `Zgsld.run`

#### Greeter only builds

When the greeter is launched by `zgsld`, `app.run()` uses the IPC connection passed through by `zgsld` in the `ZGSLD_SOCK` environment variable and then calls your `.run` callback.

#### Standalone builds

When a standalone greeter executable is launched directly, `app.run()` starts the embedded zgsld runtime.

This launches the manager and the worker processes needed to: 

- run the greeter
- handle PAM authentication
- start the user session

The manager process forwards IPC between the greeter and the session worker. 
It also ensures the greeter process has exited before the session worker receives `start_session`.

**NOTE:** Greeters are expected to exit as soon as possible after they send a `start_session` IPC event.

### Logging

Greeter stderr is inherited from ZGSLD, so you can use `std.log` or write to stderr directly.

Terminal greeters should write their UI to stdout.

### Previews

ZGSLD supports previews, so you can test your greeter with dummy PAM flows.
You can even define your own dummy PAM flows and test your greeter against them.

This also allows users to view configuration changes they make in the greeter's config if your greeter supports a way for a user to customise the theme.

Previews also support and can be useful for testing [custom IPC codecs](#ipc-codecs).

#### Example

To run a preview, call `app.runPreview()` instead of `app.run()`.
The following snippet is from a project which runs a preview based on build options:

```zig
pub fn main(init: std.process.Init) !void {
    const app = Zgsld.init(.{
        .process = .fromInit(init),
        .vtable = &.{
            .run = run,
            .configure = configure,
        },
    });

    if (build_options.preview) {
        try app.runPreview(.{ 
            .authenticate_steps = &zgsld.preview.password_auth_steps, 
            .post_auth_steps = &zgsld.preview.change_auth_token_steps,
        });
    } else {
        try app.run();
    }
}
```

### IPC codecs

Inter-process communication (IPC) is used between the greeter and zgsld to authenticate users and request a session to launch.

This library supports replacing the default IPC codec by implementing `readEvent` and `writeEvent`, which convert between bytes and `zgsld.ipc.Event`.

If you are building your greeter without the daemon built-in, then your codec must match whichever daemon runs it. The standard `zgsld` executable uses the built-in binary codec. 

#### Example

In the following example, `readEvent` and `writeEvent` delegate to the built-in binary codec. For a custom codec, replace them with your own decoding/encoding implementations.

```zig
const std = @import("std");
const zgsld = @import("zgsld");
const ipc = zgsld.ipc;

const my_codec: ipc.Codec = .{
    .vtable = &.{
        .readEvent = readEvent,
        .writeEvent = writeEvent,
    },
};

fn readEvent(
    _: *const ipc.Codec,
    reader: *std.Io.Reader,
    event_buf: []u8,
) !ipc.Event {
    return ipc.Codec.binary.readEvent(reader, event_buf);
}

fn writeEvent(
    _: *const ipc.Codec,
    writer: *std.Io.Writer,
    event: *const ipc.Event,
) !void {
    try ipc.Codec.binary.writeEvent(writer, event);
}
```

You can pass your custom codec to `Zgsld.init`:

```zig
const app = zgsld.Zgsld.init(.{
    .process = .fromInit(init),
    .ipc_codec = &my_codec,
    .vtable = &.{
        .run = run,
        .configure = configure,
    },
});

try app.run();
```

[Previews](#previews) use the codec supplied to `Zgsld.init`, so you can test your custom codec alongside your greeter by calling `app.runPreview()` instead of `app.run()`:

```zig
try app.runPreview(.{
    .authenticate_steps = &zgsld.preview.password_auth_steps,
    .post_auth_steps = &zgsld.preview.change_auth_token_steps,
});
```
