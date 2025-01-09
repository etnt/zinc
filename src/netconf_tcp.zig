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
    username: []const u8,
    ip: []const u8,
    uid: u32,
    gid: u32,
    sup_gids: []const u8,
    homedir: []const u8,
    groups: []const u8,
    debug: bool,
    stream: net.Stream,

    pub fn init(
        allocator: std.mem.Allocator,
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
            .username = username,
            .ip = "",
            .uid = uid,
            .gid = gid,
            .sup_gids = sup_gids,
            .homedir = homedir,
            .groups = groups,
            .debug = debug,
            .stream = undefined,
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

        // Connect to the first resolved address
        self.stream = try net.tcpConnectToAddress(address);
    }

    pub fn deinit(self: *NetconfTCP) void {
        self.allocator.free(self.ip);
        // Note: other fields are not owned by this struct
        self.stream.close();
    }

    pub fn sendHello(self: *NetconfTCP, hello_msg: []const u8) !void {
        // Format the TCP header
        const header = try std.fmt.allocPrint(self.allocator, "[{s};{s};tcp;{d};{d};{s};{s};{s};]\n", .{ self.username, self.ip, self.uid, self.gid, self.sup_gids, self.homedir, self.groups });
        defer self.allocator.free(header);

        // Send header followed by hello message
        try self.stream.writeAll(header);
        try self.stream.writeAll(hello_msg);
    }

    pub fn write(self: *NetconfTCP, buffer: []const u8) !void {
        try self.stream.writeAll(buffer);
    }

    pub fn readResponse(self: *NetconfTCP, buffer: []u8) !usize {
        return try self.stream.read(buffer);
    }
};
