const std = @import("std");
const clap: type = @import("clap");
const net = std.net;
const utils = @import("utils.zig");
const NetconfTCP = @import("netconf_tcp.zig").NetconfTCP;
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



const Proto = enum { tcp, ssh };

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var debug = false;
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
        \\-d, --debug                Enable debug output
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
        return 1;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("Usage: zig build run -- [options]\n", .{});
        std.debug.print("Options:\n", .{});
        std.debug.print("  -h, --help             Display this help and exit\n", .{});
        std.debug.print("  -d, --debug            Enable debug output\n", .{});
        std.debug.print("  --netconf10            Use Netconf vsn 1.0 (default: 1.1)\n", .{});
        std.debug.print("  -u, --user <username>  Username to use (default: admin)\n", .{});
        std.debug.print("  --password <password>  Password to use (default: admin)\n", .{});
        std.debug.print("  --host <host>          Host to connect to (default: localhost)\n", .{});
        std.debug.print("  --port <port>          Port to connect to (default: 2022)\n", .{});
        std.debug.print("  --proto <proto>        Protocol to use (default: tcp)\n", .{});
        std.debug.print("  --groups <groups>      Comma separated list of groups (default: )\n", .{});
        std.debug.print("  --sup-gids <groups>    Comma separated list of supplementary groups (default: )\n", .{});
        return 0;
    }

    if (res.args.debug != 0)
        debug = true;

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

    // Get current user info
    const uid = getuid();
    const gid = getgid();
    const homedir = std.process.getEnvVarOwned(gpa.allocator(), "HOME") catch "/tmp";
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
        debug,
    );

    // Connect to server
    tcp_conn.connect(host, port) catch |err| {
        std.debug.print("Connect failed: {any}\n", .{err});
        return 1;
    };
    defer tcp_conn.deinit();

    // Send NETCONF Hello
    tcp_conn.sendHello(if (vsn_1_0) hello_1_0 else hello_1_1) catch |err| {
        std.debug.print("Send HELLO failed: {any}\n", .{err});
        return 1;
    };

    // Read response
    var buffer: [1024]u8 = undefined;
    const bytes_read = tcp_conn.readResponse(&buffer) catch |err| {
        std.debug.print("Read response failed: {any}\n", .{err});
        return 1;
    };

    // Pretty print XML response
    const xml_response = buffer[0..bytes_read];

    var process = ChildProcess.init(&.{ "xmllint", "--format", "-" }, gpa.allocator());
    process.stdin_behavior = .Pipe;
    process.stdout_behavior = .Pipe;

    process.spawn() catch |err| {
        std.debug.print("Spawn process failed: {any}\n", .{err});
        return 1;
    };

    if (process.stdin) |stdin| {
        stdin.writeAll(xml_response) catch |err| {
            std.debug.print("Write to stdin failed: {any}\n", .{err});
            return 1;
        };
        stdin.close();
        process.stdin = null;
    }

    const formatted_xml = process.stdout.?.reader().readAllAlloc(gpa.allocator(), 1024 * 1024) catch |err| {
        std.debug.print("Read from stdout failed: {any}\n", .{err});
        return 1;
    };
    defer gpa.allocator().free(formatted_xml);

    _ = process.wait() catch |err| {
        std.debug.print("Wait for process failed: {any}\n", .{err});
        return 1;
    };

    stdout.print("\n{s}\n", .{formatted_xml}) catch |err| {
        std.debug.print("Print to stdout failed: {any}\n", .{err});
        return 1;
    };

    return 0;

}

