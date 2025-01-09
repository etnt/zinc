const std = @import("std");
const utils = @import("utils.zig");

test "simple chunked encoding" {
    const allocator = std.testing.allocator;
    const input = "\n#7\n<hello>\n#5\n12345\n##\n";

    const slices = try utils.parseChunkedNetconf(allocator, input);
    defer {
        for (slices) |slice| {
            allocator.free(slice);
        }
        allocator.free(slices);
    }

    try std.testing.expectEqual(@as(usize, 2), slices.len);
    try std.testing.expectEqualStrings("<hello>", slices[0]);
    try std.testing.expectEqualStrings("12345", slices[1]);
}

test "chunked encoding" {
    const allocator = std.testing.allocator;

    const input = "\n#4\n<rpc\n#18\n message-id=\"102\"\n\n#79\n     xmlns=\"urn:ietf:params:xml:ns:netconf:base:1.0\">\n  <close-session/>\n</rpc>\n##\n";
    const expected_output = "<rpc message-id=\"102\"\n     xmlns=\"urn:ietf:params:xml:ns:netconf:base:1.0\">\n  <close-session/>\n</rpc>";

    const slices = try utils.parseChunkedNetconf(allocator, input);
    defer {
        for (slices) |slice| {
            allocator.free(slice);
        }
        allocator.free(slices);
    }

    // Calculate total length needed for concatenated result
    var total_len: usize = 0;
    for (slices) |slice| {
        total_len += slice.len;
    }

    // Allocate buffer and concatenate all slices
    var result = try allocator.alloc(u8, total_len);
    defer allocator.free(result);

    var pos: usize = 0;
    for (slices) |slice| {
        std.mem.copyForwards(u8, result[pos..], slice);
        pos += slice.len;
    }

    try std.testing.expectEqualStrings(expected_output, result);
}

test "chunked encoding via pipe" {
    const allocator = std.testing.allocator;

    const input = "\n#4\n<rpc\n#18\n message-id=\"102\"\n\n#79\n     xmlns=\"urn:ietf:params:xml:ns:netconf:base:1.0\">\n  <close-session/>\n</rpc>\n##\n";
    const expected_output = "<rpc message-id=\"102\"\n     xmlns=\"urn:ietf:params:xml:ns:netconf:base:1.0\">\n  <close-session/>\n</rpc>";

    // Create a pipe to simulate a network stream
    const pipe = try std.posix.pipe();
    const reader = std.fs.File{ .handle = pipe[0] };
    defer reader.close();
    const writer = std.fs.File{ .handle = pipe[1] };

    // Write the input data to the pipe and close writer
    _ = try writer.writeAll(input);
    writer.close();

    // Create a stream from the reader
    const stream = std.net.Stream{ .handle = reader.handle };

    // Read and parse the chunked message
    const result = try utils.readChunkedNetconf(allocator, stream);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(expected_output, result);
}
