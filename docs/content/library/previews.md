# Previews

ZGSLD supports previews, so you can test your greeter with dummy PAM flows.
You can even define your own dummy PAM flows and test your greeter against them.

This also allows users to view configuration changes they make in the greeter's config if your greeter supports a way for a user to customise the theme.

Previews also support and can be useful for testing [custom IPC codecs](ipc.md).

## Example

To run a preview, call `app.runPreview()` instead of `app.run()`.
The following snippet is from a project which runs a preview based on build options:

```zig
pub fn main(init: std.process.Init) !void {
    const app = Greeter.init(.fromInit(&init), .{
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
