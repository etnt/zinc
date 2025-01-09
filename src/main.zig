const std = @import("std");
const clap: type = @import("clap");
const net = std.net;
const utils = @import("utils.zig");
const NetconfTCP = @import("netconf_tcp.zig").NetconfTCP;
const NetconfSSH = @import("netconf_ssh.zig").NetconfSSH;
const expect = std.testing.expect;

const Connection = union(Proto) {
    tcp: *NetconfTCP,
    ssh: *NetconfSSH,

    pub fn sendHello(self: Connection, hello_msg: []const u8) !void {
        var result: anyerror!void = undefined;
        switch (self) {
            .tcp => |conn| result = conn.sendHello(hello_msg),
            .ssh => |conn| result = conn.sendHello(hello_msg),
        }
        return result;
    }

    pub fn write(self: Connection, buffer: []const u8) !void {
        var result: anyerror!void = undefined;
        switch (self) {
            .tcp => |conn| result = conn.write(buffer),
            .ssh => |conn| result = conn.write(buffer),
        }
        return result;
    }

    pub fn writeEOF(self: Connection) !void {
        var result: anyerror!void = undefined;
        switch (self) {
            .tcp => |conn| result = conn.writeEOF(),
            .ssh => |conn| result = conn.writeEOF(),
        }
        return result;
    }

    pub fn readResponse(self: Connection) ![]u8 {
        var result: anyerror![]u8 = undefined;
        switch (self) {
            .tcp => |conn| result = conn.readResponse(),
            .ssh => |conn| result = conn.readResponse(),
        }
        return result;
    }

    pub fn recvBytesFraming1_0(self: Connection) ![]u8 {
        var result: anyerror![]u8 = undefined;
        switch (self) {
            .tcp => |conn| result = conn.recvBytesFraming1_0(),
            .ssh => |conn| result = conn.recvBytesFraming1_0(),
        }
        return result;
    }

    pub fn recvChunkBytesFraming1_1(self: Connection) ![]u8 {
        var result: anyerror![]u8 = undefined;
        switch (self) {
            .tcp => |conn| result = conn.recvChunkBytesFraming1_1(),
            .ssh => |conn| result = conn.recvChunkBytesFraming1_1(),
        }
        return result;
    }

    pub fn deinit(self: Connection) void {
        switch (self) {
            .tcp => |conn| conn.deinit(),
            .ssh => |conn| conn.deinit(),
        }
    }

    pub fn updateVersion(self: Connection, buffer: []const u8, force_1_0: bool) void {
        const version: utils.NetconfVersion = if (force_1_0) 
            .v1_0 
        else if (std.mem.indexOf(u8, buffer, "urn:ietf:params:netconf:base:1.1") != null) 
            .v1_1 
        else 
            .v1_0;

        switch (self) {
            .tcp => |conn| conn.version = version,
            .ssh => |conn| conn.version = version,
        }
    }
};

extern fn getuid() callconv(.C) u32;
extern fn getgid() callconv(.C) u32;

const Proto = enum { tcp, ssh };

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    var debug = false;
    var vsn_1_0 = false; // default is: 1.1
    var hello: bool = false;
    var pretty: bool = false;
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
        \\--pretty                   Pretty print the output
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
        std.debug.print("  --pretty               Pretty print the output\n", .{});
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
    if (res.args.pretty != 0)
        pretty = true;
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

    // Initialize connection handler based on protocol
    var conn: Connection = switch (proto) {
        .tcp => blk: {
            const tcp_conn = allocator.create(NetconfTCP) catch |err| {
                std.debug.print("Allocate NetconfTCP failed: {any}\n", .{err});
                return 1;
            };
            tcp_conn.* = NetconfTCP.init(
                allocator,
                vsn_1_0,
                username,
                uid,
                gid,
                sup_gids,
                homedir,
                groups,
                debug,
            );
            break :blk .{ .tcp = tcp_conn };
        },
        .ssh => blk: {
            const ssh_conn = allocator.create(NetconfSSH) catch |err| {
                std.debug.print("Allocate NetconfSSH failed: {any}\n", .{err});
                return 1;
            };
            ssh_conn.* = NetconfSSH.init(
                allocator,
                vsn_1_0,
                username,
                password,
                debug,
            );
            break :blk .{ .ssh = ssh_conn };
        },
    };
    defer switch (conn) {
        .tcp => |c| allocator.destroy(c),
        .ssh => |c| allocator.destroy(c),
    };

    if (debug)
        utils.debugPrintln(@src(), "Connection initialized.", .{});

    // Connect to server
    switch (conn) {
        .tcp => |c| c.connect(host, port) catch |err| {
            std.debug.print("Connect TCP failed: {any}\n", .{err});
            return 1;
        },
        .ssh => |c| c.connect(host, port) catch |err| {
            std.debug.print("Connect SSH failed: {any}\n", .{err});
            return 1;
        },
    }
    defer conn.deinit();

    // Send NETCONF Hello
    conn.sendHello(if (vsn_1_0) utils.hello_1_0 else utils.hello_1_1) catch |err| {
        std.debug.print("Send HELLO failed: {any}\n", .{err});
        return 1;
    };

    if (debug)
        utils.debugPrintln(@src(), "Sending hello message OK!", .{});

    // Read HELLO response
    const buffer = conn.recvBytesFraming1_0() catch |err| {
        std.debug.print("Read response failed: {any}\n", .{err});
        return 1;
    };
    defer allocator.free(buffer);

    // Update connection version based on HELLO response
    conn.updateVersion(buffer, vsn_1_0);

    if (debug) {
        const version = switch (conn) {
            .tcp => |c| c.version,
            .ssh => |c| c.version,
        };
        utils.debugPrintln(@src(), "Reading HELLO response, read {d} bytes, vsn={s}", .{
            buffer.len,
            switch (version) {
                .v1_0 => "1.0",
                .v1_1 => "1.1",
            },
        });
    }

    if (hello) {
        if (pretty) {
            if (!utils.prettyPrint(allocator, buffer)) {
                std.debug.print("Failed to pretty print XML\n", .{});
                return 1;
            }
            return 0;
        } else {
            std.debug.print("{s}\n", .{buffer});
            return 0;
        }
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
        if (debug)
            utils.debugPrintln(@src(), "Reading from stdin", .{});
        reader = std.io.getStdIn().reader();
    }

    var inbuf: [1024*1024]u8 = undefined;
    var inmsg_len: usize = 0;
    while (true) {
        const maybe_line = reader.readUntilDelimiterOrEof(&inbuf, '\n') catch |err| {
            std.debug.print("Read failed: {any}\n", .{err});
            return 1;
        };

        if (maybe_line) |line| {
            inmsg_len += line.len;
            conn.write(line) catch |err| {
                std.debug.print("Write failed: {any}\n", .{err});
                break;
            };
        } else {
            // EOF reached
            conn.writeEOF() catch |err| {
                std.debug.print("Write EOF failed: {any}\n", .{err});
            };
            break;
        }
    }

    if (debug)
        utils.debugPrintln(@src(), "Wrote {d} bytes to stream", .{inmsg_len});

    // Read response using the appropriate framing based on negotiated version
    const buffer2 = conn.readResponse() catch |err| {
        std.debug.print("Read response 2 failed: {any}\n", .{err});
        return 1;
    };
    defer allocator.free(buffer2);

    if (debug)
        utils.debugPrintln(@src(), "Reading response, read {d} bytes", .{buffer2.len});

    if (pretty) {
        if (!utils.prettyPrint(allocator, buffer2)) {
            std.debug.print("Failed to pretty print XML\n", .{});
            return 1;
        }
        return 0;
    } else {
        std.io.getStdOut().writer().print("{s}\n", .{buffer2}) catch {
            std.debug.print("Failed to print result to stdout\n", .{});
            return 1;
        };
        return 0;
    }

    return 0;
}
