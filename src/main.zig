const std = @import("std");
const clap: type = @import("clap");
const net = std.net;
const expect = std.testing.expect;
const ChildProcess = std.process.Child;
const Allocator = std.mem.Allocator;

extern fn getuid() callconv(.C) u32;
extern fn getgid() callconv(.C) u32;

const hello_1_0: []const u8 =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<hello xmlns="urn:ietf:params:netconf:base:1.0">
    \\  <capabilities>
    \\    <capability>urn:ietf:params:netconf:base:1.0</capability>
    \\  </capabilities>
    \\</hello>
;

const hello_1_1: []const u8 =
    \\<?xml version="1.1" encoding="UTF-8"?>
    \\<hello xmlns="urn:ietf:params:netconf:base:1.1">
    \\  <capabilities>
    \\    <capability>urn:ietf:params:netconf:base:1.1</capability>
    \\  </capabilities>
    \\</hello>
;

// When running Netconf over TCP we use the following custom header:
//
//   [<username>;<IP>;<proto>;<uid>;<gid>;<xtragids>;<homedir>;<group list>;]\n
//
// here described in the corresponding Python code:
//
// tcp_hdr = '[{0};{1};tcp;{2};{3};{4};{5};{6};]\n'.format(
//             self.username, sockname[0], os.getuid(), os.getgid(),
//             self.suplementing_gids, os.getenv("HOME", "/tmp"), self.groups)

const NetconfTCP = struct {
    allocator: std.mem.Allocator,
    username: []const u8,
    ip: []const u8,
    uid: u32,
    gid: u32,
    sup_gids: []const u8,
    homedir: []const u8,
    groups: []const u8,
    stream: net.Stream,

    pub fn init(
        allocator: std.mem.Allocator,
        username: []const u8,
        uid: u32,
        gid: u32,
        sup_gids: []const u8,
        homedir: []const u8,
        groups: []const u8,
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

        debugPrintln(@src(), "Address: {any}", .{address});
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

    pub fn readResponse(self: *NetconfTCP, buffer: []u8) !usize {
        return try self.stream.read(buffer);
    }
};

const Proto = enum { tcp, ssh };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var vsn_1_0 = false;
    var username: []const u8 = "admin";
    var password: []const u8 = "admin";
    var host: []const u8 = "localhost";
    var port: u16 = 2022;
    var groups: []const u8 = "";
    var sup_gids: []const u8 = "";
    var proto: Proto = .tcp;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                 Display this help and exit.
        \\--netconf10                Use Netconf vsn 1.0 (default: 1.1)
        \\-u, --user  <STR>          Username (default: admin)
        \\-p, --password <STR>       Password (default: admin)
        \\--proto <PROTO>            Protocol (default: tcp)
        \\--host <STR>               Host (default: localhost)
        \\--port <INT>               Port (default: 2022)
        \\--groups <STR>             Groups, comma separated
        \\--sup_gids <STR>           Suplementary groups, comma separated
        \\
    );

    // Declare our own parsers which are used to map the argument strings to other
    // types.
    const parsers = comptime .{
        .STR = clap.parsers.string,
        .INT = clap.parsers.int(u16, 10),
        .PROTO = clap.parsers.enumeration(Proto),
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = gpa.allocator(),
    }) catch |err| {
        // Report useful error and exit.
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return error.CommandLineParseError;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("Usage: zig build run -- [options]\n", .{});
        std.debug.print("Options:\n", .{});
        std.debug.print("  -h, --help             Display this help and exit\n", .{});
        std.debug.print("  --netconf10            Use Netconf vsn 1.0 (default: 1.1)\n", .{});
        std.debug.print("  -u, --user <username>  Username to use (default: admin)\n", .{});
        std.debug.print("  --password <password>  Password to use (default: admin)\n", .{});
        std.debug.print("  --host <host>          Host to connect to (default: localhost)\n", .{});
        std.debug.print("  --port <port>          Port to connect to (default: 2022)\n", .{});
        std.debug.print("  --proto <proto>        Protocol to use (default: tcp)\n", .{});
        std.debug.print("  --groups <groups>      Comma separated list of groups (default: )\n", .{});
        std.debug.print("  --sup-gids <groups>    Comma separated list of supplementary groups (default: )\n", .{});
        return;
    }

    if (res.args.netconf10 != 0)
        vsn_1_0 = true;

    if (res.args.user != null)
        username = res.args.user.?;
    if (res.args.password != null)
        password = res.args.password.?;
    if (res.args.host != null)
        host = res.args.host.?;
    if (res.args.port != null)
        port = res.args.port.?;
    if (res.args.proto != null)
        proto = res.args.proto.?;
    if (res.args.groups != null)
        groups = res.args.groups.?;
    if (res.args.sup_gids != null)
        sup_gids = res.args.sup_gids.?;

    const stdout = std.io.getStdOut().writer();

    debugPrintln(@src(), "username={s}", .{username});

    // Get current user info
    const uid = getuid();
    debugPrintln(@src(), "uid={d}", .{uid});
    const gid = getgid();
    debugPrintln(@src(), "gid={d}", .{gid});
    const homedir = std.process.getEnvVarOwned(gpa.allocator(), "HOME") catch "/tmp";
    debugPrintln(@src(), "homedir={s}", .{homedir});
    defer gpa.allocator().free(homedir);

    // Initialize TCP connection handler
    var tcp_conn = NetconfTCP.init(
        gpa.allocator(),
        username,
        uid,
        gid,
        sup_gids,
        homedir,
        groups,
    );

    // Connect to server
    try tcp_conn.connect(host, port); // Use IP address instead of hostname
    defer tcp_conn.deinit();

    // Send NETCONF Hello
    try tcp_conn.sendHello(if (vsn_1_0) hello_1_0 else hello_1_1);

    // Read response
    var buffer: [1024]u8 = undefined;
    const bytes_read = try tcp_conn.readResponse(&buffer);

    // Pretty print XML response
    const xml_response = buffer[0..bytes_read];

    var process = ChildProcess.init(&.{ "xmllint", "--format", "-" }, gpa.allocator());
    process.stdin_behavior = .Pipe;
    process.stdout_behavior = .Pipe;

    try process.spawn();

    if (process.stdin) |stdin| {
        try stdin.writeAll(xml_response);
        stdin.close();
        process.stdin = null;
    }

    const formatted_xml = try process.stdout.?.reader().readAllAlloc(gpa.allocator(), 1024 * 1024);
    defer gpa.allocator().free(formatted_xml);

    const term_result = try process.wait();
    if (term_result.Exited != 0) {
        return error.XmlLintFailed;
    }

    try stdout.print("\n{s}\n", .{formatted_xml});
}

/// Print debug message with source location information
pub fn debugPrint(src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[{s}:{d}] " ++ fmt, .{ src.file, src.line } ++ args);
}

/// Print debug message with source location information and newline
/// Example: utils.debugPrintln(@src(), "Freeing String: {s}", .{self.chars});
pub fn debugPrintln(src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    debugPrint(src, fmt ++ "\n", args);
}

test "string hashmap" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();

    var map = std.StringHashMap(enum { cool, uncool, rocking }).init(
        gpa_allocator,
    );
    defer map.deinit();

    const name = try gpa_allocator.dupe(u8, "you");
    defer gpa_allocator.free(name);

    try map.put(name, .uncool);
    try map.put("me", .cool);
    try map.put(name, .rocking);

    try expect(map.get("me").? == .cool);
    try expect(map.get(name).? == .rocking);
}
