---
slug: /greeter-development
---

# Setup

You can use the ZGSLD library to build a greeter that handles user interaction, while ZGSLD manages authentication and launching sessions.

For complete implementations, see [Greeters](../greeters.md).

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

Whether standalone builds should support starting the X server. Defaults to `true`. This is a no-op when `.standalone = false`.
