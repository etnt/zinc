const std = @import("std");
const ChildProcess = std.process.Child;


/// Pretty print XML
pub fn prettyPrint(allocator: std.mem.Allocator, xml: []const u8) bool {
    const stdout = std.io.getStdOut().writer();

    var process = ChildProcess.init(&.{ "xmllint", "--format", "-" }, allocator);
    process.stdin_behavior = .Pipe;
    process.stdout_behavior = .Pipe;

    process.spawn() catch |err| {
        std.debug.print("Spawn process failed: {any}\n", .{err});
        return false;
    };

    if (process.stdin) |stdin| {
        stdin.writeAll(xml) catch |err| {
            std.debug.print("Write to stdin failed: {any}\n", .{err});
            return false;
        };
        stdin.close();
        process.stdin = null;
    }

    const formatted_xml = process.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024) catch |err| {
        std.debug.print("Read from stdout failed: {any}\n", .{err});
        return false;
    };
    defer allocator.free(formatted_xml);

    _ = process.wait() catch |err| {
        std.debug.print("Wait for process failed: {any}\n", .{err});
        return false;
    };

    stdout.print("\n{s}\n", .{formatted_xml}) catch |err| {
        std.debug.print("Print to stdout failed: {any}\n", .{err});
        return false;
    };

    return true;
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
