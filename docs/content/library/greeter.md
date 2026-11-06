# Building a greeter

See the [generated Zig docs](pathname:///zgsld/zig/) for the full API reference and [Greeters](../ecosystem.md#greeters) for complete implementations.

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

    // Defaults to true
    // Set to false to build a greeter launched by an external daemon
    .embed_daemon = embed_daemon,

    // Only applies when embed_daemon = true.
    // Defaults to true.
    .x11 = x11_support,
});
```

Add the greeter module as an import:

```zig
exe.root_module.addImport("zgsld-greeter", zgsld.module("greeter"));
```

## `Greeter.init`

In your `main()` function, you will want to `init` the `Greeter` struct and then call the `run` function:

```zig
const zgsld = @import("zgsld-greeter");
const Greeter = zgsld.Greeter;

const app = Greeter.init(.fromInit(&init), .{
    .vtable = &.{
        .run = run,
        .configure = configure,
    },
});
```

### `.run`

Function Signature: `fn run(ctx: Greeter.RunContext) !void`

The `run` callback is the main entry point for your greeter. It is called when using either an embedded or external daemon.

You most likely want to parse any args your greeter needs here, then run your greeter code.

### `.configure`

Function Signature: `fn configure(ctx: Greeter.ConfigureContext) !void`

The optional `configure` callback runs before the embedded ZGSLD daemon starts and can be used to change its configuration. It isn't called when using an external daemon.

## `Greeter.run`

### External Daemon

When the greeter is launched by `zgsld`, `app.run()` uses the IPC connection passed through by `zgsld` in the `ZGSLD_SOCK` environment variable and then calls your `.run` callback.

### Embedded Daemon

When built with `embed_daemon = true` and launched directly, `app.run()` starts the embedded ZGSLD daemon.

This launches the manager and the worker processes needed to:

- run the greeter
- handle PAM authentication
- start the user session

The manager process forwards IPC events between the greeter and the session worker.

## Custom IPC codecs

You can pass a custom codec to `Greeter.init`:

```zig
const app = zgsld.Greeter.init(.fromInit(&init), .{
    .ipc_codec = &my_codec.interface,
    .vtable = &.{
        .run = run,
        .configure = configure,
    },
});

try app.run();
```

When your greeter runs under an external daemon, its codec must match the daemon's protocol. The standard `zgsld` executable uses the built-in binary codec.

See [Custom IPC codecs](ipc.md) for details on making a custom codec.

[Previews](previews.md) use the codec supplied to `Greeter.init`, so you can test a custom codec alongside your greeter by calling `app.runPreview()` instead of `app.run()`:

```zig
try app.runPreview(.{
    .authenticate_steps = &zgsld.preview.password_auth_steps,
    .post_auth_steps = &zgsld.preview.change_auth_token_steps,
});
```

## Logging

Greeter stderr is inherited from ZGSLD, so you can use `std.log` or write to stderr directly.

Terminal greeters should write their UI to stdout.
