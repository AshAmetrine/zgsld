const std = @import("std");
const ipc = @import("ipc");
pub const pam = @cImport({
    @cInclude("security/pam_appl.h");
});

pub const PamCtx = struct {
    user: [:0]const u8,
    ipc: *ipc.Ipc,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
};

pub const Pam = struct {
    handle: ?*pam.pam_handle,
    ctx: *PamCtx,
    status: c_int,
    session_open: bool = false,
    creds_established: bool = false,

    pub fn init(service_name: []const u8, ctx: *PamCtx) !Pam {
        const conv = pam.pam_conv{
            .conv = loginConv,
            .appdata_ptr = @ptrCast(ctx),
        };

        var handle: ?*pam.pam_handle = undefined;

        const status = pam.pam_start(service_name.ptr, null, &conv, &handle);
        if (status != pam.PAM_SUCCESS) return pamDiagnose(status);

        return .{ .handle = handle, .ctx = ctx, .status = status };
    }

    pub fn deinit(self: *Pam) void {
        if (self.handle == null) return;
        if (self.session_open) _ = pam.pam_close_session(self.handle, 0);
        if (self.creds_established) _ = pam.pam_setcred(self.handle, pam.PAM_DELETE_CRED);
        _ = pam.pam_end(self.handle, self.status);
        self.handle = null;
    }

    pub fn authenticate(self: *Pam) !void {
        self.status = pam.pam_authenticate(self.handle, 0);
        if (self.status != pam.PAM_SUCCESS) return pamDiagnose(self.status);

        self.status = pam.pam_acct_mgmt(self.handle, 0);
        if (self.status != pam.PAM_SUCCESS) return pamDiagnose(self.status);
    }

    pub fn establishCred(self: *Pam) !void {
        self.status = pam.pam_setcred(self.handle, pam.PAM_ESTABLISH_CRED);
        if (self.status != pam.PAM_SUCCESS) return pamDiagnose(self.status);
        self.creds_established = true;
    }

    pub fn openSession(self: *Pam) !void {
        self.status = pam.pam_open_session(self.handle, 0);
        if (self.status != pam.PAM_SUCCESS) return pamDiagnose(self.status);
        self.session_open = true;
    }

    pub fn setItem(self: *Pam, item_type: c_int, str: [:0]const u8) !void {
        self.status = pam.pam_set_item(self.handle, item_type, str.ptr);
        if (self.status != pam.PAM_SUCCESS) return pamDiagnose(self.status);
    }

    pub fn putEnv(self: *Pam, kv: [:0]const u8) !void {
        self.status = pam.pam_putenv(self.handle, kv);
        if (self.status != pam.PAM_SUCCESS) return pamDiagnose(self.status);
    }

    fn getEnvList(self: *Pam) ?[*:null]?[*:0]u8 {
        return pam.pam_getenvlist(self.handle);
    }

    fn freeEnvList(env_list: ?[*:null]?[*:0]u8) void {
        const list = env_list orelse return;
        var i: usize = 0;
        while (list[i]) |entry| : (i += 1) {
            std.c.free(@ptrCast(entry));
        }
        std.c.free(@ptrCast(list));
    }

    pub fn createEnvListMap(self: *Pam, allocator: std.mem.Allocator) !std.process.EnvMap {
        var env_map = std.process.EnvMap.init(allocator);
        errdefer env_map.deinit();

        const env_list = self.getEnvList();
        defer freeEnvList(env_list);

        if (env_list) |list| {
            var i: usize = 0;
            while (list[i]) |entry| : (i += 1) {
                const s = std.mem.span(entry);
                const eq = std.mem.indexOfScalar(u8, s, '=') orelse continue;
                if (eq == 0) continue;
                try env_map.put(s[0..eq],s[eq+1..]);
            }
        }

        return env_map;
    }
};

fn loginConv(
    num_msg: c_int,
    msg: ?[*]?*const pam.pam_message,
    resp: ?*?[*]pam.pam_response,
    appdata_ptr: ?*anyopaque,
) callconv(.c) c_int {
    const message_count: u32 = @intCast(num_msg);
    const messages = msg.?;

    const allocator = std.heap.c_allocator;
    const response = allocator.alloc(pam.pam_response, message_count) catch return pam.PAM_BUF_ERR;

    // Initialise allocated memory to 0
    // This ensures memory can be freed correctly by pam on success
    @memset(response, std.mem.zeroes(pam.pam_response));

    var status: c_int = pam.PAM_SUCCESS;

    const ctx: *PamCtx = @ptrCast(@alignCast(appdata_ptr));
    const ipc_reader = ctx.reader;
    const ipc_writer = ctx.writer;

    var ipc_buf: [ipc.PAM_CONV_BUF_SIZE]u8 = undefined;
    defer std.crypto.secureZero(u8, &ipc_buf);

    for (0..message_count) |i| set_credentials: {
        const message = messages[i].?;
        const msg_text = std.mem.span(message.msg);
        switch (message.msg_style) {
            pam.PAM_PROMPT_ECHO_ON, pam.PAM_PROMPT_ECHO_OFF => |style| {
                const req = ipc.IpcEvent{
                    .pam_request = .{
                        .echo = style == pam.PAM_PROMPT_ECHO_ON,
                        .message = msg_text,
                    },
                };
                ctx.ipc.writeEvent(ipc_writer, &req) catch {
                    status = pam.PAM_CONV_ERR;
                    break :set_credentials;
                };
                ipc_writer.flush() catch {};

                const event = ctx.ipc.readEvent(ipc_reader, ipc_buf[0..]) catch {
                    status = pam.PAM_CONV_ERR;
                    break :set_credentials;
                };
                switch (event) {
                    .pam_response => |resp_bytes| {
                        response[i].resp = allocator.dupeZ(u8, resp_bytes) catch {
                            status = pam.PAM_BUF_ERR;
                            break :set_credentials;
                        };
                    },
                    else => unreachable,
                }
            },
            pam.PAM_TEXT_INFO, pam.PAM_ERROR_MSG => |style| {
                const display_msg = ipc.IpcEvent{ 
                    .pam_message = .{
                        .is_error = style == pam.PAM_ERROR_MSG,
                        .message = msg_text,
                    },
                };
                ctx.ipc.writeEvent(ipc_writer, &display_msg) catch {
                    status = pam.PAM_CONV_ERR;
                    break :set_credentials;
                };
                ipc_writer.flush() catch {};
            },
            else => unreachable,
        }
    }

    if (status != pam.PAM_SUCCESS) {
        // Memory is freed by pam otherwise
        for (response) |r| {
            if (r.resp) |r_resp| {
                const p = std.mem.span(r_resp);
                std.crypto.secureZero(u8,p);
                allocator.free(p);
            }
        }
        allocator.free(response);
    } else {
        resp.?.* = response.ptr;
    }

    return status;
}

pub const PamError = error{
    AccountExpired,
    AuthError,
    AuthInfoUnavailable,
    BufferError,
    CredentialsError,
    CredentialsExpired,
    CredentialsInsufficient,
    CredentialsUnavailable,
    MaximumTries,
    NewAuthTokenRequired,
    PermissionDenied,
    SessionError,
    SystemError,
    UserUnknown,
    Abort,
};

fn pamDiagnose(status: c_int) PamError {
    return switch (status) {
        pam.PAM_ACCT_EXPIRED => return error.AccountExpired,
        pam.PAM_AUTH_ERR => return error.AuthError,
        pam.PAM_AUTHINFO_UNAVAIL => return error.AuthInfoUnavailable,
        pam.PAM_BUF_ERR => return error.BufferError,
        pam.PAM_CRED_ERR => return error.CredentialsError,
        pam.PAM_CRED_EXPIRED => return error.CredentialsExpired,
        pam.PAM_CRED_INSUFFICIENT => return error.CredentialsInsufficient,
        pam.PAM_CRED_UNAVAIL => return error.CredentialsUnavailable,
        pam.PAM_MAXTRIES => return error.MaximumTries,
        pam.PAM_NEW_AUTHTOK_REQD => return error.NewAuthTokenRequired,
        pam.PAM_PERM_DENIED => return error.PermissionDenied,
        pam.PAM_SESSION_ERR => return error.SessionError,
        pam.PAM_SYSTEM_ERR => return error.SystemError,
        pam.PAM_USER_UNKNOWN => return error.UserUnknown,
        pam.PAM_ABORT => return error.Abort,
        else => unreachable,
    };
}
