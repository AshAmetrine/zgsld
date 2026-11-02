# API

For the full API reference, see the [generated Zig docs](pathname:///zgsld/zig/).

## `Zgsld.init`

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

### `.run`

Function Signature: `fn run(ctx: Zgsld.GreeterContext) !void`

The `run` function is the main entrypoint to your greeter. This will be called in both standalone and greeter-only builds.

You most likely want to parse any args your greeter needs here, then run your greeter code.


### `.configure`

Function Signature: `fn configure(ctx: Zgsld.ConfigureContext) !void`

`configure` is for standalone builds to have control over `zgsld` configuration options. It is never called in greeter-only (non-standalone) builds. 

## `Zgsld.run`

### Greeter only builds

When the greeter is launched by `zgsld`, `app.run()` uses the IPC connection passed through by `zgsld` in the `ZGSLD_SOCK` environment variable and then calls your `.run` callback.

### Standalone builds

When a standalone greeter executable is launched directly, `app.run()` starts the embedded zgsld runtime.

This launches the manager and the worker processes needed to: 

- run the greeter
- handle PAM authentication
- start the user session

The manager process forwards IPC events between the greeter and the session worker. 

## Logging

Greeter stderr is inherited from ZGSLD, so you can use `std.log` or write to stderr directly.

Terminal greeters should write their UI to stdout.

## Previews

ZGSLD supports previews, so you can test your greeter with dummy PAM flows.
You can even define your own dummy PAM flows and test your greeter against them.

This also allows users to view configuration changes they make in the greeter's config if your greeter supports a way for a user to customise the theme.

Previews also support and can be useful for testing [custom IPC codecs](#custom-codecs).

### Example

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

## IPC

Inter-process communication (IPC) is used between the greeter and zgsld to
authenticate users and request a session to launch.

### Events

#### Authentication

The greeter sends `pam_start_auth` to start PAM authentication for the supplied username.

##### ZGSLD Response

- `pam_message`

  A PAM message to display. 
  `is_error` does not mean authentication has failed.

- `pam_request`

  During PAM authentication, the greeter will receive requests from PAM. 
  The greeter should respond to each with a `pam_response` event.

- `pam_auth_result`

  When authentication has concluded, the result is passed through this event.
  If `ok` is `true`, then the greeter can proceed with requesting a session. 
  Otherwise, the greeter can start another authentication attempt with `pam_start_auth`.

- `err`

  ZGSLD can respond with an `err` event with the `internal_error` code if an internal error occurs during PAM authentication. 
  The greeter can then start another authentication attempt with `pam_start_auth`.

#### Session Environment

After successful authentication, the greeter can optionally set environment variables through `set_session_env` before sending `start_session`.

Supported variables are:

- `PATH`
- `XDG_SESSION_DESKTOP`
- `XDG_CURRENT_DESKTOP`
- `XDG_SESSION_TYPE`

Other variable names are ignored.

#### Session Request

To request a session to start, the greeter must send the `start_session` event which carries the session type and command to be launched by ZGSLD.

##### ZGSLD Response

- `session_accepted`

  Greeters should exit shortly after receiving this response after requesting a session. Once the greeter process has ended, the requested session will be started.

  If the requested session failed to start, the greeter will be launched again so the user can reauthenticate and start a different session.

- `err`

  ZGSLD can respond with an `err` event with the `invalid_request` code if an invalid session is received.

  This can happen because:
  - An X11 session was requested, when ZGSLD was not built with X11 support.
  - The session command is empty.
  - The command contains a NUL byte.

  If this event is received, the greeter can attempt to start a new session again with `start_session` or send `login_cancel` to abandon the attempt.

#### Cancellation

To cancel during PAM authentication or before requesting a session, the greeter can send the `login_cancel` event.

##### ZGSLD Response

- `login_cancelled`

  ZGSLD sends this event once cancellation and cleanup have finished.
  The greeter should ignore other events while waiting for this response, 
  then start a new attempt with `pam_start_auth`.

  After `session_accepted`, the greeter should exit instead of cancelling.

### Custom Codecs

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
    _: ?*anyopaque,
    reader: *std.Io.Reader,
    event_buf: []u8,
) !ipc.Event {
    return ipc.Codec.binary.readEvent(reader, event_buf);
}

fn writeEvent(
    _: ?*anyopaque,
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
    .ipc_codec = my_codec,
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
