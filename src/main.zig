const std = @import("std");
const net = std.net;
const expect = std.testing.expect;

pub fn main() !void {
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

    // Print response
    try stdout.print("Server response: {s}\n", .{buffer[0..bytes_read]});
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
