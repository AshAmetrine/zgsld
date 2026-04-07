# Greeter Development

If you would like complete greeter implementations to use as reference, check the [Greeters](greeters.md) section.

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

- `standalone`
When this is `true`, your greeter will not depend on the `zgsld` binary and will have all `zgsld` functionality built-in to the built executable.

- `x11`
Whether standalone builds should support starting the X server. This is a no-op when `.standalone = false`.

## Standalone Greeters

Standalone greeter support lets a greeter embed `zgsld` functionality without requiring the `zgsld` executable to be installed separately.

This is useful when the greeter wants to own the complete entrypoint while still relying on `zgsld` for authentication and session-launch behaviour.

## API

### Zgsld.init

In your `main()` function, you will want to `init` the `Zgsld` struct and then call the `run` function:

```zig
const app = Zgsld.init(allocator, &.{
    .run = run,
    .configure = configure,
});
```

#### .run

Function Signature: `fn run(ctx: Zgsld.GreeterContext) !void`

The `run` function is the main entrypoint to your greeter. This will be called in both standalone and greeter-only builds.

You most likely want to parse any args your greeter needs here, then run your greeter code.

#### .configure

Function Signature: `fn configure(ctx: Zgsld.ConfigureContext) !void`

`configure` is for standalone builds to have control over `zgsld` configuration options. It is never called in greeter-only (non-standalone) builds. 

### Runtime Behaviour

After `const app = Zgsld.init(...)`, you can now call `app.run()`.

`app.run()` behaves differently depending on how the greeter was built.

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

You can forward logs from a greeter to the same place as ZGSLD for consolidation of logs.

First, you will need to set the log function in `std_options` in your `main.zig` file:

```zig
const zgsld = @import("zgsld");
pub const std_options: std.Options = .{ .logFn = zgsld.logFn };
```

Then in `main()`, you can call `zgsld.initZgsldLog()`. 

ZGSLD passes `ZGSLD_LOG` (ZGSLD's log file descriptor) through to the greeter, and `initZgsldLog` fetches this environment variable and stores it for usage by `zgsld.logFn`.

### Previews

ZGSLD supports previews, so you can test your greeter with dummy PAM flows.
You can even define your own dummy PAM flows and test your greeter against them.

This also allows users to view configuration changes they make in the greeter's config if your greeter supports a way for a user to customise the theme.

#### Example

This is a small snippet from a project which runs a preview based on build options.

```zig
    const app = Zgsld.init(allocator, &.{
        .run = run,
        .configure = configure,
    });

    if (build_options.preview) {
        try app.runPreview(.{ 
            .authenticate_steps = &zgsld.preview.password_auth_steps, 
            .post_auth_steps = &zgsld.preview.change_auth_token_steps,
        });
    } else {
        try app.run();
    }
```
