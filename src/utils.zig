const std = @import("std");
const ChildProcess = std.process.Child;

pub const NetconfVersion = enum {
    v1_0, // Uses EOM framing
    v1_1, // Uses chunked framing
};

// See: https://datatracker.ietf.org/doc/html/rfc6242#section-4.1
//
// The <hello> message MUST be followed by the character sequence
// ]]>]]>. If the :base:1.1 capability is advertised by both
// peers, the chunked framing mechanism (see Section 4.2) is used for
// the remainder of the NETCONF session.  Otherwise, the old end-of-
// message-based mechanism (see Section 4.3) is used.

pub const end_frame_1_0: []const u8 = "]]>]]>"[0..];
pub const end_frame_1_1: []const u8 = "\n##\n"[0..];

pub const hello_1_0: []const u8 =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<hello xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">
    \\  <capabilities>
    \\    <capability>urn:ietf:params:netconf:base:1.0</capability>
    \\  </capabilities>
    \\</hello>]]>]]>
;

pub const hello_1_1: []const u8 =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<hello xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">
    \\  <capabilities>
    \\    <capability>urn:ietf:params:netconf:base:1.0</capability>
    \\    <capability>urn:ietf:params:netconf:base:1.1</capability>
    \\  </capabilities>
    \\</hello>]]>]]>
;

pub const get_config: [:0]const u8 =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0"  message-id="1">
    \\  <get-config>
    \\    <source>
    \\      <running/>
    \\    </source>
    \\  </get-config>
    \\</rpc>
;

pub const close_sessions: [:0]const u8 =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0"  message-id="2">
    \\  <close-session/>
    \\</rpc>
;

// Construct a get-config message with a specific filter
pub fn getConfig(allocator: std.mem.Allocator, filter: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0"  message-id="1">
        \\  <get-config>
        \\    <source>
        \\      <running/>
        \\    </source>
        \\    <filter>{s}</filter>
        \\  </get-config>
        \\</rpc>
    , .{filter});
}

const start_marker = "\n#"[0..];
const end_marker = "\n##\n"[0..];

pub const ChunkedError = error{
    UnexpectedData,
    IncompleteMessage,
    OutOfMemory,
    EndOfStream,
    StreamTooLong,
    SystemResources,
    InputOutput,
    InvalidCharacter,
    Overflow,
    Timeout,
    FrameMarkerNotFound,
};

pub const State = enum {
    Init,
    Buffer,
    Finished,
    IncompleteMessage,
};

pub fn readChunkedNetconf(allocator: std.mem.Allocator, stream: anytype) ChunkedError![]u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var buf: [16384]u8 = undefined;
    var read_attempts: usize = 0;
    const max_attempts = 1000; // Prevent infinite loops
    var total_bytes: usize = 0;
    const max_total_bytes = 100 * 1024 * 1024; // 100MB total message size limit

    // Read in chunks until we have a complete message
    while (read_attempts < max_attempts) : (read_attempts += 1) {
        if (total_bytes >= max_total_bytes) {
            debugPrintln(@src(), "Message exceeds maximum size of {d} bytes", .{max_total_bytes});
            return ChunkedError.StreamTooLong;
        }

        const bytes_read = stream.read(&buf) catch |err| {
            debugPrintln(@src(), "Read error: {any}", .{err});
            return ChunkedError.InputOutput;
        };

        if (bytes_read == 0) {
            if (buffer.items.len == 0) {
                return ChunkedError.EndOfStream;
            }
            break;
        }

        buffer.appendSlice(buf[0..bytes_read]) catch return ChunkedError.OutOfMemory;
        total_bytes += bytes_read;

        // Try to parse what we have so far
        if (parseChunkedNetconf(allocator, buffer.items)) |slices| {

            // Calculate total length needed
            var total_len: usize = 0;
            for (slices) |slice| {
                total_len += slice.len;
            }

            // Allocate result buffer
            var result = allocator.alloc(u8, total_len) catch {
                // Clean up slices if allocation fails
                for (slices) |slice| {
                    allocator.free(slice);
                }
                allocator.free(slices);
                return ChunkedError.OutOfMemory;
            };
            errdefer allocator.free(result);

            // Copy chunks to result buffer
            var pos: usize = 0;
            for (slices) |slice| {
                std.mem.copyForwards(u8, result[pos..], slice);
                pos += slice.len;
                allocator.free(slice);
            }
            allocator.free(slices);
            return result;
        } else |err| switch (err) {
            ChunkedError.UnexpectedData => {
                //debugPrintln(@src(), "Unexpected data, continuing", .{});
                continue;
            },
            ChunkedError.IncompleteMessage => {
                //debugPrintln(@src(), "Incomplete message, continuing to read", .{});
                continue;
            },
            else => {
                debugPrintln(@src(), "Error during parsing: {any}", .{err});
                return err;
            },
        }
    }

    if (read_attempts >= max_attempts) {
        debugPrintln(@src(), "Exceeded maximum read attempts", .{});
        return ChunkedError.Timeout;
    }

    debugPrintln(@src(), "Failed to parse complete message", .{});
    return ChunkedError.IncompleteMessage;
}

pub fn parseChunkedNetconf(allocator: std.mem.Allocator, input: []const u8) ChunkedError![]const []const u8 {
    var state: State = .Init;
    var buffer: []u8 = allocator.alloc(u8, input.len) catch return ChunkedError.OutOfMemory;
    defer allocator.free(buffer);

    std.mem.copyForwards(u8, buffer, input);

    var slices = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (slices.items) |slice| {
            allocator.free(slice);
        }
        slices.deinit();
    }

    var i: usize = 0;
    while (i < buffer.len) {
        switch (state) {
            .Init => {
                state = .Buffer;
            },
            .Buffer => {
                if (checkLengthMarker(buffer, i)) {
                    // Parse the chunk size
                    const chunk_size = parseChunkSize(buffer, i) catch |err| switch (err) {
                        error.InvalidCharacter => return ChunkedError.InvalidCharacter,
                        error.Overflow => return ChunkedError.Overflow,
                    };

                    // Move index past the length marker
                    i = skipLengthMarker(buffer, i);

                    // Check if there's enough data for the chunk
                    if (i + chunk_size > buffer.len) {
                        return ChunkedError.IncompleteMessage;
                    }

                    // Extract and duplicate the chunk data
                    const chunk_start = i;
                    const chunk_end = i + chunk_size;
                    if (chunk_end > buffer.len) {
                        debugPrintln(@src(), "Chunk extends beyond buffer (start: {d}, end: {d}, len: {d})", .{ chunk_start, chunk_end, buffer.len });
                        return ChunkedError.IncompleteMessage;
                    }
                    const chunk_data = allocator.dupe(u8, buffer[chunk_start..chunk_end]) catch return ChunkedError.OutOfMemory;
                    slices.append(chunk_data) catch return ChunkedError.OutOfMemory;
                    i = chunk_end;
                } else if (checkEndMarker(buffer, i)) {
                    state = .Finished;
                    // Skip past end marker - either "##" or "\n##"
                    i += if (buffer[i] == '\n') 4 else 3; // Include trailing newline
                    break;
                } else {
                    i += 1;
                }
            },
            .Finished => break,
            .IncompleteMessage => {
                return ChunkedError.IncompleteMessage;
            },
        }
    }

    if (state != .Finished) {
        return ChunkedError.IncompleteMessage;
    }

    const result = slices.toOwnedSlice();
    // Note: ownership of the individual slices is transferred to the caller
    return result;
}

fn checkLengthMarker(buffer: []const u8, index: usize) bool {
    // Check if we have enough characters for minimum marker ("#1\n")
    if (index + 2 >= buffer.len) {
        return false;
    }

    // Find the # position - either at index or after a newline
    const hash_pos = if (buffer[index] == '\n' and index + 1 < buffer.len) index + 1 else index;
    if (hash_pos >= buffer.len or buffer[hash_pos] != '#') {
        return false;
    }

    // Check for digits after #
    var i = hash_pos + 1;
    var found_digit = false;
    var digit_count: usize = 0;
    while (i < buffer.len and buffer[i] != '\n') {
        if (!std.ascii.isDigit(buffer[i])) {
            return false;
        }
        found_digit = true;
        digit_count += 1;
        i += 1;
    }

    if (!found_digit) {
        return false;
    }

    if (digit_count > 10) { // Reasonable limit for chunk size digits
        return false;
    }

    if (i >= buffer.len or buffer[i] != '\n') {
        return false;
    }

    return true;
}

fn parseChunkSize(buffer: []const u8, index: usize) !usize {
    // Find the # position
    const hash_pos = if (buffer[index] == '\n' and index + 1 < buffer.len) index + 1 else index;

    // Find the end of the number
    var end = hash_pos + 1;
    while (end < buffer.len and buffer[end] != '\n') {
        if (!std.ascii.isDigit(buffer[end])) {
            debugPrintln(@src(), "Invalid character in chunk size: {c}", .{buffer[end]});
            return error.InvalidCharacter;
        }
        end += 1;
    }

    if (end >= buffer.len or buffer[end] != '\n') {
        debugPrintln(@src(), "No newline after chunk size", .{});
        return error.InvalidCharacter;
    }

    const chunk_size_str = buffer[hash_pos + 1 .. end];
    const size = try std.fmt.parseInt(usize, chunk_size_str, 10);

    // Sanity check the chunk size
    if (size == 0) {
        debugPrintln(@src(), "Invalid zero chunk size", .{});
        return error.InvalidCharacter;
    }
    if (size > 1024 * 1024 * 10) { // 10MB max chunk size
        debugPrintln(@src(), "Chunk size too large: {d}", .{size});
        return error.Overflow;
    }

    return size;
}

fn skipLengthMarker(buffer: []const u8, index: usize) usize {
    // Find the # position
    const hash_pos = if (buffer[index] == '\n' and index + 1 < buffer.len) index + 1 else index;

    // Skip to end of line
    var i = hash_pos + 1;
    while (i < buffer.len and buffer[i] != '\n') {
        i += 1;
    }
    return i + 1; // Skip final newline
}

fn checkEndMarker(buffer: []const u8, index: usize) bool {
    // End marker must be "\n##\n"
    if (index + 3 >= buffer.len) {
        return false;
    }

    // Check for exact sequence
    const is_end_marker = buffer[index] == '\n' and
        buffer[index + 1] == '#' and
        buffer[index + 2] == '#' and
        buffer[index + 3] == '\n';

    return is_end_marker;
}

fn findFrameMarker(buffer: []const u8, marker: []const u8) ?usize {
    return std.mem.indexOf(u8, buffer, marker);
}

pub fn readUntilFrameMarker(allocator: std.mem.Allocator, stream: anytype, marker: []const u8) ![]u8 {
    const chunk_size = 1024 * 4; // Adjust chunk size as needed
    var temp_buf: [chunk_size]u8 = undefined;
    var result = std.ArrayList(u8).init(allocator);

    while (true) {
        const read_bytes = try stream.read(&temp_buf);
        if (read_bytes == 0) break; // End of stream

        try result.appendSlice(temp_buf[0..read_bytes]);

        const marker_index = findFrameMarker(result.items, marker);
        if (marker_index != null) {
            const final_result = try result.toOwnedSlice();
            const trimmed_result = try allocator.alloc(u8, marker_index.?);
            std.mem.copyForwards(u8, trimmed_result, final_result[0..marker_index.?]);
            allocator.free(final_result);
            return trimmed_result;
        }
    }

    return error.FrameMarkerNotFound;
}

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
