const std = @import("std");
const clap: type = @import("clap");
const net = std.net;
const utils = @import("utils.zig");
const NetconfTCP = @import("netconf_tcp.zig").NetconfTCP;
const expect = std.testing.expect;


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
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    var debug = false;
    var vsn_1_0 = false;
    var hello: bool = false;
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
        \\--hello                    Only send a NETCONF Hello message
        \\-u, --user  <STR>          Username (default: admin)
        \\-p, --password <STR>       Password (default: admin)
        \\--proto <PROTO>            Protocol (default: tcp)
        \\--host <STR>               Host (default: localhost)
        \\--port <INT>               Port (default: 2022)
        \\--groups <STR>             Groups, comma separated
        \\--sup-gids <STR>           Suplementary groups, comma separated
        \\<FILE>                     Input file (optional, reads from stdin if not provided)
        \\
    );

    // Declare our own parsers which are used to map the argument strings to other
    // types.
    const parsers = comptime .{
        .STR = clap.parsers.string,
        .FILE = clap.parsers.string,
        .INT = clap.parsers.int(u16, 10),
        .PROTO = clap.parsers.enumeration(Proto),
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        // Report useful error and exit.
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return 1;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("Usage: zig build run -- [options] [file]\n", .{});
        std.debug.print("Options:\n", .{});
        std.debug.print("  -h, --help             Display this help and exit\n", .{});
        std.debug.print("  -d, --debug            Enable debug output\n", .{});
        std.debug.print("  --netconf10            Use Netconf vsn 1.0 (default: 1.1)\n", .{});
        std.debug.print("  --hello                Only send a NETCONF Hello message\n", .{});
        std.debug.print("  -u, --user <username>  Username to use (default: admin)\n", .{});
        std.debug.print("  --password <password>  Password to use (default: admin)\n", .{});
        std.debug.print("  --host <host>          Host to connect to (default: localhost)\n", .{});
        std.debug.print("  --port <port>          Port to connect to (default: 2022)\n", .{});
        std.debug.print("  --proto <proto>        Protocol to use (default: tcp)\n", .{});
        std.debug.print("  --groups <groups>      Comma separated list of groups (default: )\n", .{});
        std.debug.print("  --sup-gids <groups>    Comma separated list of supplementary groups (default: )\n", .{});
        std.debug.print("\nIf no file is specified, reads from stdin\n", .{});
        return 0;
    }

    if (res.args.debug != 0)
        debug = true;
    if (res.args.netconf10 != 0)
        vsn_1_0 = true;
    if (res.args.hello != 0)
        hello = true;
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
    // The @ syntax (below) allows you to access fields
    // whose names are not regular identifiers.
    if (res.args.@"sup-gids" != null)
        sup_gids = res.args.@"sup-gids".?;

    // Get current user info
    const uid = getuid();
    const gid = getgid();
    const homedir = std.process.getEnvVarOwned(allocator, "HOME") catch "/tmp";
    defer allocator.free(homedir);

    // Initialize TCP connection handler
    var tcp_conn = NetconfTCP.init(
        allocator,
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

    if (hello) {
        if (!utils.prettyPrint(allocator, buffer[0..bytes_read])) {
            std.debug.print("Failed to pretty print XML\n", .{});
            return 1;
        }
        return 0;
    }

    // Set up the reader based on whether a file was provided
    var file: ?std.fs.File = null;
    defer if (file) |f| f.close();

    var reader: std.fs.File.Reader = undefined;
    if (res.positionals.len > 0) {
        // Read from file
        file = std.fs.cwd().openFile(res.positionals[0], .{}) catch |err| {
            std.debug.print("Failed to open file '{s}': {any}\n", .{ res.positionals[0], err });
            return 1;
        };
        reader = file.?.reader();
    } else {
        // Read from stdin
        reader = std.io.getStdIn().reader();
    }

    var inbuf: [1024*1024]u8 = undefined;
    while (true) {
        const maybe_line = reader.readUntilDelimiterOrEof(&inbuf, '\n') catch |err| {
            std.debug.print("Read failed: {any}\n", .{err});
            return 1;
        };

        if (maybe_line) |line| {
            tcp_conn.write(line) catch |err| {
                std.debug.print("Write to TCP failed: {any}\n", .{err});
                break;
            };
        } else {
            // EOF reached
            break;
        }
    }

    return 0;
}
