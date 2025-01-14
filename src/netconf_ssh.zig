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
extern fn ssh_get_error(session: ssh_session) [*c]const u8;
extern fn ssh_userauth_password(session: ssh_session, username: [*c]const u8, password: [*c]const u8) c_int;
extern fn ssh_channel_new(session: ssh_session) ssh_channel;
extern fn ssh_channel_open_session(channel: ssh_channel) c_int;
extern fn ssh_channel_request_subsystem(channel: ssh_channel, subsystem: [*c]const u8) c_int;
extern fn ssh_channel_write(channel: ssh_channel, buffer: [*c]const u8, count: u32) c_int;
extern fn ssh_channel_read(channel: ssh_channel, buffer: [*c]u8, count: u32, is_stderr: c_int) c_int;
extern fn ssh_channel_poll(channel: ssh_channel, is_stderr: *c_int) c_int;
extern fn ssh_channel_read_timeout(channel: ssh_channel, buffer: [*c]u8, count: u32, is_stderr: *c_int, timeout: c_int) c_int;
extern fn ssh_channel_read_nonblocking(channel: ssh_channel, buffer: [*c]u8, count: u32, is_stderr: *c_int, timeout: c_int) c_int;
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

pub const SshChannel = struct {
    channel: ssh_channel,
    is_stderr: c_int,
    timeout: c_int,

    const Self = @This();

    pub fn init(channel: ssh_channel) Self {
        return .{
            .channel = channel,
            .is_stderr = 0,
            .timeout = 1000, // ms
        };
    }

    pub fn read(self: *Self, buffer: []u8) !usize {

        const bytes_read = ssh_channel_read(self.channel, buffer.ptr, @intCast(buffer.len), self.is_stderr);

        if (bytes_read == 0) {
            // End of file
            return 0;
        }

        if (bytes_read < 0) {
            // SSH_AGAIN (-2) means timeout/would block, treat as no data available
            if (bytes_read == -2) {
                std.time.sleep(1 * std.time.ns_per_ms); // Small sleep to prevent busy loop
                return 0;
            }
            return error.SshReadError;
        }
        return @intCast(bytes_read);
    }
};

pub const NetconfSSH = struct {
    allocator: std.mem.Allocator,
    version: utils.NetconfVersion,
    username: []const u8,
    password: []const u8,
    debug: bool,
    session: ssh_session,
    channel: SshChannel,
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
        //
        // SSH_OPTIONS_HOST = 0
        if (ssh_options_set(self.session, 0, host.ptr) != 0) {
            return error.SshOptionsError;
        }

        if (self.debug)
            utils.debugPrintln(@src(), "Setting SSH port option", .{});

        // SSH_OPTIONS_PORT_STR = 2
        const port_str = try std.fmt.allocPrint(self.allocator, "{d}", .{port});
        defer self.allocator.free(port_str);
        if (ssh_options_set(self.session, 2, port_str.ptr) != 0) { 
            return error.SshOptionsError;
        }

        // SSH_OPTIONS_LOG_VERBOSITY_STR = 14
        const verbose: u8 = if (self.debug) 9 else 0;
        const verbosity_str = try std.fmt.allocPrint(self.allocator, "{d}", .{ verbose });
        defer self.allocator.free(verbosity_str);
        if (ssh_options_set(self.session, 14, verbosity_str.ptr) != 0) {
            return error.SshOptionsError;
        }

        if (self.debug)
            utils.debugPrintln(@src(), "Connecting to SSH host: {s}:{d}", .{host, port});

        // Connect to the SSH server
        if (ssh_connect(self.session) != 0) {
            utils.debugPrintln(@src(), "Connect failed: {s}", .{ssh_get_error(self.session)});
            return error.SshConnectError;
        }

        if (self.debug)
            utils.debugPrintln(@src(), "Authenticating, username = {s}", .{self.username});

        // Authenticate
        if (ssh_userauth_password(self.session, self.username.ptr, self.password.ptr) != 0) {
            return error.SshAuthError;
        }

        // Create and open channel
        const raw_channel = ssh_channel_new(self.session);
        if (raw_channel == undefined) {
            return error.SshChannelCreateError;
        }

        if (ssh_channel_open_session(raw_channel) != 0) {
            ssh_channel_free(raw_channel);
            return error.SshChannelOpenError;
        }

        // Request the NETCONF subsystem
        if (ssh_channel_request_subsystem(raw_channel, "netconf") != 0) {
            ssh_channel_free(raw_channel);
            return error.SshSubsystemRequestError;
        }

        self.channel = SshChannel.init(raw_channel);

        if (self.debug)
            utils.debugPrintln(@src(), "SSH connection established", .{});
    }

    pub fn deinit(self: *NetconfSSH) void {
        if (@typeInfo(@TypeOf(self.channel)) != .Undefined) {
            ssh_channel_free(self.channel.channel);
        }
        if (@typeInfo(@TypeOf(self.session)) != .Undefined) {
            ssh_free(self.session);
        }
        // Note: username and password are not owned by this struct
    }

    pub fn sendHello(self: *NetconfSSH, hello_msg: []const u8) !void {
        if (self.debug)
            utils.debugPrintln(@src(), "Sending hello message", .{});

        const bytes_written = ssh_channel_write(self.channel.channel, hello_msg.ptr, @intCast(hello_msg.len));
        if (bytes_written < 0) {
            return error.SshWriteError;
        }
    }

    pub fn write(self: *NetconfSSH, buffer: []const u8) !void {
        // Version-specific framing
        switch (self.version) {
            .v1_0 => {
                // Write data + EOF marker in one operation
                const full_message = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{buffer, utils.end_frame_1_0});
                defer self.allocator.free(full_message);

                const bytes_written = ssh_channel_write(self.channel.channel, full_message.ptr, @intCast(full_message.len));
                if (bytes_written < 0) {
                    return error.SshWriteError;
                }
            },
            .v1_1 => {
                // Write chunk header + data + EOF marker in one operation
                const frame_1_1 = try std.fmt.allocPrint(self.allocator, "\n#{d}\n", .{buffer.len});
                defer self.allocator.free(frame_1_1);

                const full_message = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{frame_1_1, buffer, utils.end_frame_1_1});
                defer self.allocator.free(full_message);

                const bytes_written = ssh_channel_write(self.channel.channel, full_message.ptr, @intCast(full_message.len));
                if (bytes_written < 0) {
                    return error.SshWriteError;
                }
            },
        }
    }

    pub fn readResponse(self: *NetconfSSH) ![]u8 {
        if (self.debug) {
            utils.debugPrintln(@src(), "Reading response with version: {}", .{self.version});
        }
        switch (self.version) {
            .v1_0 => {
                if (self.debug) {
                    utils.debugPrintln(@src(), "Using 1.0 framing", .{});
                }
                return self.recvBytesFraming1_0();
            },
            .v1_1 => {
                if (self.debug) {
                    utils.debugPrintln(@src(), "Using 1.1 framing", .{});
                }
                return self.recvChunkBytesFraming1_1();
            },
        }
    }

    // Note: Always used when expecting a HELLO response from the server.
    pub fn recvBytesFraming1_0(self: *NetconfSSH) ![]u8 {
        return utils.readUntilFrameMarker(self.allocator, &self.channel, utils.end_frame_1_0);
    }

    pub fn recvChunkBytesFraming1_1(self: *NetconfSSH) ![]u8 {
        return utils.readChunkedNetconf(self.allocator, &self.channel);
    }
};
