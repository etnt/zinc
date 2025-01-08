const std = @import("std");
const net = std.net;

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
