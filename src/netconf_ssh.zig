const std = @import("std");
const utils = @import("utils.zig");

// External SSH types and functions
const ssh_session_struct = opaque {};
const ssh_session = *ssh_session_struct;
const ssh_channel_struct = opaque {};
const ssh_channel = *ssh_channel_struct;

extern fn ssh_new() ssh_session;
extern fn ssh_free(session: ssh_session) void;
extern fn ssh_options_set(session: ssh_session, option: c_int, value: [*c]const u8) c_int;
extern fn ssh_options_set_port(session: ssh_session, value: c_int) c_int;
extern fn ssh_connect(session: ssh_session) c_int;
extern fn ssh_userauth_password(session: ssh_session, username: [*c]const u8, password: [*c]const u8) c_int;
extern fn ssh_channel_new(session: ssh_session) ssh_channel;
extern fn ssh_channel_open_session(channel: ssh_channel) c_int;
extern fn ssh_channel_request_subsystem(channel: ssh_channel, subsystem: [*c]const u8) c_int;
extern fn ssh_channel_write(channel: ssh_channel, buffer: [*c]const u8, count: u32) c_int;
extern fn ssh_channel_read(channel: ssh_channel, buffer: [*c]u8, count: u32, is_stderr: *c_int) c_int;
extern fn ssh_channel_free(channel: ssh_channel) void;

const SshError = error{
    SshOptionsError,
    SshConnectError,
    SshAuthError,
    SshChannelCreateError,
    SshChannelOpenError,
    SshSubsystemRequestError,
    SshWriteError,
    SshReadError,
};

pub const NetconfSSH = struct {
    allocator: std.mem.Allocator,
    version: utils.NetconfVersion,
    username: []const u8,
    password: []const u8,
    debug: bool,
    session: ssh_session,
    channel: ssh_channel,
    frame: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        vsn_1_0: bool,  // kept for compatibility
        username: []const u8,
        password: []const u8,
        debug: bool,
    ) NetconfSSH {
        return NetconfSSH{
            .allocator = allocator,
            .version = if (vsn_1_0) .v1_0 else .v1_1,
            .username = username,
            .password = password,
            .debug = debug,
            .session = undefined,
            .channel = undefined,
            .frame = if (vsn_1_0) utils.end_frame_1_0 else utils.end_frame_1_1,
        };
    }

    pub fn connect(self: *NetconfSSH, host: []const u8, port: u16) !void {
        self.session = ssh_new();
        errdefer ssh_free(self.session);

        if (self.debug)
            utils.debugPrintln(@src(), "Setting SSH host option", .{});

        // Set SSH options
        // See: https://git.libssh.org/projects/libssh.git/tree/include/libssh/libssh.h
        if (ssh_options_set(self.session, 1, host.ptr) != 0) { // SSH_OPTIONS_HOST = 1
            return error.SshOptionsError;
        }

        if (self.debug)
            utils.debugPrintln(@src(), "Setting SSH port option", .{});

        const port_str = try std.fmt.allocPrint(self.allocator, "{d}", .{port});
        defer self.allocator.free(port_str);

        if (ssh_options_set(self.session, 3, port_str.ptr) != 0) { // SSH_OPTIONS_PORT_STR = 3
            return error.SshOptionsError;
        }

        if (self.debug)
            utils.debugPrintln(@src(), "Connecting to SSH host: {s}:{d}", .{host, port});

        // Connect to the SSH server
        if (ssh_connect(self.session) != 0) {
            return error.SshConnectError;
        }

        if (self.debug)
            utils.debugPrintln(@src(), "Authenticating, username = {s}", .{self.username});

        // Authenticate
        if (ssh_userauth_password(self.session, self.username.ptr, self.password.ptr) != 0) {
            return error.SshAuthError;
        }

        // Create and open channel
        self.channel = ssh_channel_new(self.session);
        if (self.channel == undefined) {
            return error.SshChannelCreateError;
        }

        if (ssh_channel_open_session(self.channel) != 0) {
            return error.SshChannelOpenError;
        }

        // Request the NETCONF subsystem
        if (ssh_channel_request_subsystem(self.channel, "netconf") != 0) {
            return error.SshSubsystemRequestError;
        }

        if (self.debug)
            utils.debugPrintln(@src(), "SSH connection established", .{});
    }

    pub fn deinit(self: *NetconfSSH) void {
        if (@typeInfo(@TypeOf(self.channel)) != .Undefined) {
            ssh_channel_free(self.channel);
        }
        if (@typeInfo(@TypeOf(self.session)) != .Undefined) {
            ssh_free(self.session);
        }
        // Note: username and password are not owned by this struct
    }

    pub fn sendHello(self: *NetconfSSH, hello_msg: []const u8) !void {
        if (self.debug)
            utils.debugPrintln(@src(), "Sending hello message", .{});

        const bytes_written = ssh_channel_write(self.channel, hello_msg.ptr, @intCast(hello_msg.len));
        if (bytes_written < 0) {
            return error.SshWriteError;
        }
    }

    pub fn write(self: *NetconfSSH, buffer: []const u8) !void {
        // Version-specific framing
        switch (self.version) {
            .v1_0 => {
                const bytes_written = ssh_channel_write(self.channel, buffer.ptr, @intCast(buffer.len));
                if (bytes_written < 0) {
                    return error.SshWriteError;
                }
            },
            .v1_1 => {
                // Write chunk header
                const frame_1_1 = try std.fmt.allocPrint(self.allocator, "\n#{d}\n", .{buffer.len});
                defer self.allocator.free(frame_1_1);
                
                var bytes_written = ssh_channel_write(self.channel, frame_1_1.ptr, @intCast(frame_1_1.len));
                if (bytes_written < 0) {
                    return error.SshWriteError;
                }
                
                // Write data
                bytes_written = ssh_channel_write(self.channel, buffer.ptr, @intCast(buffer.len));
                if (bytes_written < 0) {
                    return error.SshWriteError;
                }
            },
        }
    }

    // Write End-Of-Frame
    pub fn writeEOF(self: *NetconfSSH) !void {
        const frame = switch (self.version) {
            .v1_0 => utils.end_frame_1_0,
            .v1_1 => utils.end_frame_1_1,
        };
        const bytes_written = ssh_channel_write(self.channel, frame.ptr, @intCast(frame.len));
        if (bytes_written < 0) {
            return error.SshWriteError;
        }
    }

    pub fn readResponse(self: *NetconfSSH) ![]u8 {
        switch (self.version) {
            .v1_0 => return self.recvBytesFraming1_0(),
            .v1_1 => return self.recvChunkBytesFraming1_1(),
        }
        //var is_stderr: c_int = 0;
        //const bytes_read = ssh_channel_read(self.channel, buffer.ptr, @intCast(buffer.len), &is_stderr);
        //if (bytes_read < 0) {
        //    return error.SshReadError;
        //}
        //return @intCast(bytes_read);
        return error.FramingError; // Placeholder implementation

    }

    pub fn recvBytesFraming1_0(_: *NetconfSSH) ![]u8  {
        return error.FramingError; // Placeholder implementation
    }

    pub fn recvChunkBytesFraming1_1(_: *NetconfSSH) ![]u8  {
        return error.FramingError; // Placeholder implementation
    }
};
