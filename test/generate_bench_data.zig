// SPDX-FileCopyrightText: 2026 Antti Kivi <antti@anttikivi.com>
// SPDX-License-Identifier: Apache-2.0

const bench_options = @import("bench_options");
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Pattern = @import("bench_data.zig").Pattern;
const Size = @import("bench_data.zig").Size;

const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789_-";
const nums = "0123456789";

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const gpa = debug_allocator.allocator();
    defer _ = debug_allocator.deinit();

    const cwd = std.fs.cwd();

    inline for (bench_options.benchmarks) |fixture| {
        std.debug.print("generating {s}\n", .{fixture});

        const i = std.mem.indexOfScalar(
            u8,
            fixture,
            '-',
        ) orelse @panic("invalid benchmark generation target: " ++ fixture);
        const size_name = fixture[0..i];
        const pattern_name = fixture[i + 1 ..];
        const size = std.meta.stringToEnum(Size, size_name) orelse @panic("invalid benchmark size in " ++ fixture);
        const pattern = std.meta.stringToEnum(
            Pattern,
            pattern_name,
        ) orelse @panic("invalid benchmark pattern in " ++ fixture);

        const data = switch (pattern) {
            .flat_kv => try generateFlatKv(gpa, size.targetSize()),
            else => blk: {
                std.debug.print("not yet implemented\n", .{});
                break :blk "";
            },
        };
        defer gpa.free(data);

        var dir = try cwd.makeOpenPath(bench_options.data_path, .{});
        defer dir.close();

        const filename = try if (bench_options.random_bench) std.fmt.allocPrint(
            gpa,
            "{s}-0x{x}.toml",
            .{ fixture, bench_options.bench_seed },
        ) else std.fmt.allocPrint(
            gpa,
            "{s}-static.toml",
            .{fixture},
        );
        defer gpa.free(filename);

        var file = try dir.createFile(filename, .{ .truncate = true });
        defer file.close();

        var buf: [1024]u8 = undefined;
        var writer = file.writer(&buf);
        try writer.interface.writeAll(data);
        try writer.interface.flush();
    }
}

fn generateFlatKv(gpa: Allocator, target_size: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);

    var prng = std.Random.DefaultPrng.init(bench_options.bench_seed);
    const rand = prng.random();

    var i: usize = 0;
    while (result.items.len < target_size) : (i += 1) {
        if (bench_options.random_bench) {
            switch (prng.random().uintAtMost(u8, 4)) {
                0 => {
                    try appendRandomString(gpa, rand, &result, 3, 20);
                    try appendPrint(gpa, &result, "_{d} = \"", .{i});
                    try appendRandomString(gpa, rand, &result, 3, 20);
                    try result.appendSlice(gpa, "\"\n");
                },
                1 => {
                    try appendRandomString(gpa, rand, &result, 3, 20);
                    try appendPrint(gpa, &result, "_{d} = ", .{i});
                    if (rand.uintAtMost(u32, 100_000) % 2 == 0) {
                        try result.appendSlice(gpa, "true\n");
                    } else {
                        try result.appendSlice(gpa, "false\n");
                    }
                },
                2 => {
                    try appendRandomString(gpa, rand, &result, 3, 20);
                    switch (rand.int(u3)) {
                        0 => try appendPrint(gpa, &result, "_{d} = 0b{b}\n", .{ i, rand.int(u32) }),
                        1 => try appendPrint(gpa, &result, "_{d} = 0o{o}\n", .{ i, rand.int(u32) }),
                        2 => try appendPrint(gpa, &result, "_{d} = 0x{x}\n", .{ i, rand.int(u32) }),
                        else => try appendPrint(gpa, &result, "_{d} = {d}\n", .{ i, rand.int(i64) }),
                    }
                },
                3 => {
                    try appendRandomString(gpa, rand, &result, 3, 20);
                    switch (rand.int(u1)) {
                        0 => try appendPrint(gpa, &result, "_{d} = {e}\n", .{
                            i,
                            rand.float(f64) + @as(f64, @floatFromInt(rand.int(u32))),
                        }),
                        1 => try appendPrint(gpa, &result, "_{d} = {d}\n", .{
                            i,
                            rand.float(f64) + @as(f64, @floatFromInt(rand.int(u32))),
                        }),
                    }
                },
                4 => {
                    try appendRandomString(gpa, rand, &result, 3, 20);
                    try appendPrint(gpa, &result, "_{d} = {d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}\n", .{
                        i,
                        rand.intRangeAtMost(u32, 1000, 9999),
                        rand.intRangeAtMost(u8, 1, 12),
                        rand.intRangeAtMost(u8, 1, 28),
                        rand.intRangeAtMost(u8, 0, 23),
                        rand.intRangeAtMost(u8, 0, 59),
                        rand.intRangeAtMost(u8, 0, 59),
                    });
                },
                else => unreachable,
            }
        } else {
            switch (i % 5) {
                0 => try appendPrint(gpa, &result, "string_{d} = \"string_val_{d}\"\n", .{ i, i }),
                1 => try appendPrint(gpa, &result, "bool_{d} = {s}\n", .{ i, if (i % 2 == 0) "true" else "false" }),
                2 => try appendPrint(gpa, &result, "int_{d} = {d}\n", .{ i, i * 44 }),
                3 => try appendPrint(gpa, &result, "float_{d} = {d}\n", .{ i, @as(f64, @floatFromInt(i * 27)) }),
                4 => try appendPrint(gpa, &result, "dt_{d} = 2024-01-{d:0>2}T12:00:00Z\n", .{ i, (i % 28) + 1 }),
                else => unreachable,
            }
        }
    }

    return result.toOwnedSlice(gpa);
}

fn appendPrint(gpa: Allocator, list: *ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const line = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(line);
    try list.appendSlice(gpa, line);
}

fn appendRandomString(gpa: Allocator, rand: std.Random, list: *ArrayList(u8), at_least: usize, at_most: usize) !void {
    const len = rand.intRangeAtMost(usize, at_least, at_most);
    const buf: []u8 = try gpa.alloc(u8, len);
    defer gpa.free(buf);
    randomString(rand, buf);
    try list.appendSlice(gpa, buf);
}

fn randomString(rand: std.Random, out: []u8) void {
    for (out) |*c| {
        const b = rand.int(u8);
        c.* = alphabet[b % alphabet.len];
    }
}
