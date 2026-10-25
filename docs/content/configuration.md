# Configuration

The default config file path is `/etc/zgsld/zgsld.ini`.

## Example

```ini
# VT handling mode for the greeter/session.
# valid values: current, unmanaged, or a VT number
vt = current

[session]
# PAM service name for starting a user session
service_name = zgsld

[autologin]
# Autologin user
user =

# Session backend used for autologin.
# valid values: command, x11
session_type = command

# Session command with optional args
command =

# Delay before autologin starts.
# Any local input during the delay will spawn the greeter instead.
timeout_seconds = 0

[greeter]
# The user the greeter is run as
user = greeter

# PAM service for starting a greeter session
service_name = zgsld-greeter

# Session backend used to run the greeter.
# valid values: command, x11
session_type = command

# Greeter command with optional args
command = /usr/bin/zgsld-agetty-greeter

# Only when built with x11 support (-Dx11)
[x11]
# X server command with optional args
command = /bin/X

# VT used for X11 sessions.
# Leave empty to use the main vt setting.
# valid values: empty or a VT number
vt =
```

## Option Reference

### `vt`

Controls how zgsld manages the active TTY/VT for the greeter and session.

- Default: `current`
- Valid values: `current`, `unmanaged`, or a VT number such as `1`

Use `current` when zgsld is started with a current controlling TTY.

Use `unmanaged` when another launcher is already responsible for VT setup. In this mode, zgsld avoids managing the controlling TTY and respects environment such as `XDG_VTNR`.

Use a number when zgsld should switch to a specific VT before starting the greeter or session.

Example:

```ini
vt = current
```

### `[session]`
#### `service_name`

Controls which PAM service is used when starting a user session after authentication.

- Default: `login`
- Valid values: PAM service name

Example:

```ini
[session]
service_name = login
```

### `[autologin]`
#### `user`

Sets the account used for autologin. Leave it empty to disable autologin.

- Default: unset
- Valid values: username or empty

Example:

```ini
[autologin]
user = alice
```

#### `session_type`

Controls how the autologin session is launched.

- Default: `command`
- Valid values: `command`, or `x11` when built with `-Dx11`

Example:

```ini
[autologin]
session_type = command
```

#### `command`

Sets the session command run for autologin. This should usually point to the user's session or session wrapper.

- Default: unset
- Valid values: command string with optional args

Example:

```ini
[autologin]
command = /usr/bin/sway
```

#### `timeout_seconds`

Sets how long zgsld waits before launching autologin. Any local input during the delay cancels autologin and starts the greeter instead.

- Default: `0`
- Valid values: non-negative integer

Example:

```ini
[autologin]
timeout_seconds = 5
```

### `[greeter]`
#### `user`

Sets the system account used to run the greeter process.

- Default: `greeter`
- Valid values: username

Example:

```ini
[greeter]
user = greeter
```

#### `service_name`

Controls which PAM service is used when opening the greeter session. 
When unset, it defaults to the same `service_name` as in `[session]`.

- Default: unset
- Valid values: PAM service name

Example:

```ini
[greeter]
service_name =
```

#### `session_type`

Controls how the greeter session is launched.

- Default: `command`
- Valid values: `command`, or `x11` when built with `-Dx11`

Example:

```ini
[greeter]
session_type = command
```

#### `command`

Sets the greeter command zgsld runs. This has to be set or zgsld has no greeter to display and will result in an error.

- Default: unset
- Valid values: command string with optional args

Example:

```ini
[greeter]
command = /usr/bin/zgsld-agetty-greeter
```

### `[x11]`

This section is only relevant if ZGSLD was built with `-Dx11`.

#### `command`

Sets the X server command used for X11 sessions. Only applicable when zgsld is built with X11 support with `-Dx11`.

- Default: `/bin/X`
- Valid values: X server command with optional args

Example:

```ini
[x11]
command = /bin/X
```

#### `vt`

Sets the VT used to launch X11 sessions.

- Default: unset
- Valid values: empty or a VT number such as `7`

Example:

```ini
[x11]
vt = 7
```
