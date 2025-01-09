const std = @import("std");
const clap: type = @import("clap");
const net = std.net;
const expect = std.testing.expect;
const ChildProcess = std.process.Child;
const Allocator = std.mem.Allocator;

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var vsn_1_0 = false;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\--netconf10            Use Netconf vsn 1.0 (default: 1.1)
        \\
    );


    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
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
        return;
    }

    if (res.args.netconf10 != 0)
        vsn_1_0 = true;


    // Connect to localhost:8080
    const address = try net.Address.parseIp4("127.0.0.1", 8080);

    const stdout = std.io.getStdOut().writer();

    var stream = net.tcpConnectToAddress(address) catch |err| {
        try stdout.print("Error: Could not connect to server at {}\n", .{address});
        try stdout.print("Make sure a server is running on port 8080\n", .{});
        return err;
    };
    defer stream.close();

    // Send NETCONF Hello
    if (vsn_1_0) {
        try stream.writeAll(hello_1_0);
    } else {
        try stream.writeAll(hello_1_1);
    }

    // Read response
    var buffer: [1024]u8 = undefined;
    const bytes_read = try stream.read(&buffer);

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
