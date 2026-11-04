# IPC Protocol

Inter-process communication (IPC) is used between the greeter and zgsld to
authenticate users and request a session to launch.

## Events

### Authentication

The greeter sends `pam_start_auth` to start PAM authentication for the supplied username.

#### ZGSLD Response

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

### Session Environment

After successful authentication, the greeter can optionally set environment variables through `set_session_env` before sending `start_session`.

Supported variables are:

- `PATH`
- `XDG_SESSION_DESKTOP`
- `XDG_CURRENT_DESKTOP`
- `XDG_SESSION_TYPE`

Other variable names are ignored.

### Session Request

To request a session to start, the greeter must send the `start_session` event which carries the session type and command to be launched by ZGSLD.

#### ZGSLD Response

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

### Cancellation

To cancel during PAM authentication or before requesting a session, the greeter can send the `login_cancel` event.

#### ZGSLD Response

- `login_cancelled`

  ZGSLD sends this event once cancellation and cleanup have finished.
  The greeter should ignore other events while waiting for this response,
  then start a new attempt with `pam_start_auth`.

  After `session_accepted`, the greeter should exit instead of cancelling.
