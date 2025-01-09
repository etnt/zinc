const std = @import("std");
const net = std.net;
const utils = @import("utils.zig");

// When running Netconf over TCP we use the following custom header:
//
//   [<username>;<IP>;<proto>;<uid>;<gid>;<xtragids>;<homedir>;<group list>;]\n
//
// here described in the corresponding Python code:
//
// tcp_hdr = '[{0};{1};tcp;{2};{3};{4};{5};{6};]\n'.format(
//             self.username, sockname[0], os.getuid(), os.getgid(),
//             self.suplementing_gids, os.getenv("HOME", "/tmp"), self.groups)

pub const NetconfTCP = struct {
    allocator: std.mem.Allocator,
    version: utils.NetconfVersion,
    username: []const u8,
    host: []const u8,
    uid: u32,
    gid: u32,
    sup_gids: []const u8,
    homedir: []const u8,
    groups: []const u8,
    debug: bool,
    stream: net.Stream,
    header: []u8,
    frame: []const u8,
    eom_found: bool = false,
    buf_bytes: std.ArrayList(u8),

    pub const Error = error{
        EndOfStream,
        FramingError,
        InvalidChunkSize,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        vsn_1_0: bool,  // kept for compatibility
        username: []const u8,
        uid: u32,
        gid: u32,
        sup_gids: []const u8,
        homedir: []const u8,
        groups: []const u8,
        debug: bool,
    ) NetconfTCP {
        return NetconfTCP{
            .allocator = allocator,
            .version = if (vsn_1_0) .v1_0 else .v1_1,
            .username = username,
            .host = "",
            .uid = uid,
            .gid = gid,
            .sup_gids = sup_gids,
            .homedir = homedir,
            .groups = groups,
            .debug = debug,
            .stream = undefined,
            .header = "",
            .frame = if (vsn_1_0) utils.end_frame_1_0 else utils.end_frame_1_1,
            .eom_found = false,
            .buf_bytes = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn connect(self: *NetconfTCP, host: []const u8, port: u16) !void {
        var address: std.net.Address = undefined;

        // Try to parse as an IP address first
        address = net.Address.parseIp(host, port) catch blk: {
            // If not an IP, resolve as a hostname
            const list = try net.getAddressList(self.allocator, host, port);
            defer list.deinit();
            break :blk list.addrs[0];
        };

        if (self.debug)
            utils.debugPrintln(@src(), "Address: {any}", .{address});

        const header = try std.fmt.allocPrint(self.allocator,
                                              "[{s};{s};tcp;{d};{d};{s};{s};{s};]\n",
                                              .{ self.username, host, self.uid, self.gid, self.sup_gids, self.homedir, self.groups });

        self.header = header;
        self.host = host;

        // Connect to the first resolved address
        self.stream = try net.tcpConnectToAddress(address);
    }

    pub fn deinit(self: *NetconfTCP) void {
        self.allocator.free(self.header);
        self.buf_bytes.deinit();
        // Note: other fields are not owned by this struct
        self.stream.close();
    }

    pub fn sendHello(self: *NetconfTCP, hello_msg: []const u8) !void {
        // FIXME ? check that stream is initilized: if (self.stream) ...

        if (self.debug)
            utils.debugPrintln(@src(), "Sending hello message, header={s}", .{self.header});

        // The type of framing to be used is determined by the version
        // of the NETCONF protocol as indicated in the hello messages.
        // So therefore we need to send the hello message first with the
        // 1.0 framing, and then switch to 1.1 framing, if so negotiated.
        try self.stream.writeAll(self.header);
        try self.stream.writeAll(hello_msg);
        try self.stream.writeAll(utils.end_frame_1_0);
    }

    pub fn write(self: *NetconfTCP, buffer: []const u8) !void {
        // FIXME ? check that stream is initilized: if (self.stream) ...
        switch (self.version) {
            .v1_0 => {
            try self.stream.writeAll(buffer);
            },
            .v1_1 => {
            const frame_1_1 = try std.fmt.allocPrint(self.allocator, "\n#{d}\n", .{ buffer.len });
            defer self.allocator.free(frame_1_1);

            try self.stream.writeAll(frame_1_1);
            try self.stream.writeAll(buffer);
            },
        }
    }

    // Write End-Of-Frame
    pub fn writeEOF(self: *NetconfTCP) !void {
        switch (self.version) {
            .v1_0 => {
            try self.stream.writeAll(utils.end_frame_1_0);
            },
            .v1_1 => {
            try self.stream.writeAll(utils.end_frame_1_1);
            },
        }
    }

    pub fn readResponse(self: *NetconfTCP) ![]u8 {
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
    pub fn recvBytesFraming1_0(self: *NetconfTCP) ![]u8 {
        return utils.readUntilFrameMarker(self.allocator, self.stream, utils.end_frame_1_0);
    }

    pub fn recvChunkBytesFraming1_1(self: *NetconfTCP) ![]u8 {
        return utils.readChunkedNetconf(self.allocator, self.stream);
    }
};
