const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const fail = @import("fail.zig").fail;

pub const MakeTempDirResult = struct {
    dir: std.fs.Dir,
    name: []const u8,

    pub fn deinit(self: *@This(), gpa: Allocator, dir: std.fs.Dir) void {
        self.dir.close();
        dir.deleteTree(self.name) catch @panic("failed to delete temporary directory");
        gpa.free(self.name);
    }
};

pub fn extractGz(input_dir: std.fs.Dir, output_dir: std.fs.Dir, input_path: []const u8, output_path: []const u8) !void {
    var input = try input_dir.openFile(input_path, .{});
    defer input.close();

    var output = try output_dir.createFile(output_path, .{ .truncate = true });
    defer output.close();

    var input_buf: [1024]u8 = undefined;
    var output_buf: [1024]u8 = undefined;
    var input_reader = input.reader(&input_buf);
    var output_writer = output.writer(&output_buf);

    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&input_reader.interface, .gzip, &decompress_buf);

    _ = try decompress.reader.streamRemaining(&output_writer.interface);
    try output_writer.interface.flush();
}

pub fn fetch(gpa: Allocator, dir: std.fs.Dir, url: []const u8, dest: []const u8) !void {
    var file = try dir.createFile(dest, .{ .exclusive = true, .truncate = true });
    defer file.close();

    var buf: [1024]u8 = undefined;
    var writer = file.writer(&buf);

    var client: std.http.Client = .{ .allocator = gpa };
    defer client.deinit();

    const download_result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer.interface,
    });

    if (download_result.status != .ok) {
        return fail("failed to download, status {d}\n", .{download_result.status});
    }

    try writer.interface.flush();
}

pub fn makeTempDir(gpa: Allocator, dir: std.fs.Dir, comptime name: []const u8) !MakeTempDirResult {
    const rand_int = std.crypto.random.int(u64);
    const dir_name = try std.mem.concat(gpa, u8, &.{ name, ".", &std.fmt.hex(rand_int) });
    return .{ .dir = try dir.makeOpenPath(dir_name, .{}), .name = dir_name };
}

pub fn verifySha256(dir: std.fs.Dir, path: []const u8, expected: *const [Sha256.digest_length * 2]u8) !void {
    const file = try dir.openFile(path, .{});
    defer file.close();

    var buf: [1024]u8 = undefined;
    var reader = file.reader(&buf);

    var hasher = Sha256.init(.{});
    var hash_buf: [1024]u8 = undefined;
    var n = try reader.interface.readSliceShort(&hash_buf);
    while (n != 0) {
        hasher.update(hash_buf[0..n]);
        n = try reader.interface.readSliceShort(&hash_buf);
    }

    const digest: [Sha256.digest_length]u8 = hasher.finalResult();
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, expected)) {
        return fail("SHA256 checksums did not match: expected '{s}', got '{s}'\n", .{ expected, hex });
    }
}
