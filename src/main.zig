const std = @import("std");
const net = std.net;
const expect = std.testing.expect;
const ChildProcess = std.process.Child;
const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Connect to localhost:8080
    const address = try net.Address.parseIp4("127.0.0.1", 8080);

    const stdout = std.io.getStdOut().writer();

    var stream = net.tcpConnectToAddress(address) catch |err| {
        try stdout.print("Error: Could not connect to server at {}\n", .{address});
        try stdout.print("Make sure a server is running on port 8080\n", .{});
        return err;
    };
    defer stream.close();

    try stdout.print("Connected to server at {}\n", .{address});

    // Send "Hello World"
    try stream.writeAll("Hello World");

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
