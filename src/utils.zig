const std = @import("std");

/// Print debug message with source location information
pub fn debugPrint(src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[{s}:{d}] " ++ fmt, .{ src.file, src.line } ++ args);
}

/// Print debug message with source location information and newline
/// Example: utils.debugPrintln(@src(), "Freeing String: {s}", .{self.chars});
pub fn debugPrintln(src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    debugPrint(src, fmt ++ "\n", args);
}
