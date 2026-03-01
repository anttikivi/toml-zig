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

    var dir = try cwd.makeOpenPath(bench_options.data_path, .{});
    defer dir.close();

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

        var prng = std.Random.DefaultPrng.init(bench_options.bench_seed);
        const rand = prng.random();

        var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        const data = if (bench_options.random_bench) switch (pattern) {
            .array_tables => try generateArrayTablesRandom(arena, rand, size.targetSize()),
            .flat_kv => try generateFlatKvRandom(arena, rand, size.targetSize()),
            .inline_heavy => try generateInlineHeavyRandom(arena, rand, size.targetSize()),
            else => blk: {
                std.debug.print("not yet implemented\n", .{});
                break :blk "";
            },
        } else switch (pattern) {
            .array_tables => try generateArrayTablesDeterministic(arena, size.targetSize()),
            .flat_kv => try generateFlatKvDeterministic(arena, size.targetSize()),
            .inline_heavy => try generateInlineHeavyDeterministic(arena, size.targetSize()),
            else => blk: {
                std.debug.print("not yet implemented\n", .{});
                break :blk "";
            },
        };

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

fn generateArrayTablesDeterministic(arena: Allocator, target_size: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;

    const array_names = [_][]const u8{ "items", "users", "products", "entries" };

    var i: usize = 0;
    while (result.items.len < target_size) : (i += 1) {
        const name = array_names[i % array_names.len];
        try appendPrint(arena, &result, "[[{s}]]\n", .{name});
        const s = try generateKeyValueDeterministic(arena, i);
        defer arena.free(s);
        try result.appendSlice(arena, s);
        try appendPrint(arena, &result, "name = \"item_{d}\"\n", .{i});
        try appendPrint(arena, &result, "enabled = {s}\n", .{if (i % 2 == 0) "true" else "false"});
        try appendPrint(arena, &result, "tags = [\"tag{d}\", \"tag{d}\", \"common\"]\n\n", .{ i % 10, (i + 1) % 10 });
    }

    return result.toOwnedSlice(arena);
}

fn generateArrayTablesRandom(arena: Allocator, rand: std.Random, target_size: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;
    errdefer result.deinit(arena);

    var array_names: ArrayList([]const u8) = .empty;
    const tables = rand.intRangeAtMost(usize, 4, 9);

    for (0..tables) |_| {
        const s = try randomStringRange(arena, rand, 4, 10);
        try array_names.append(arena, s);
    }

    var i: usize = 0;
    while (result.items.len < target_size) : (i += 1) {
        const name = array_names.items[i % array_names.items.len];
        try appendPrint(arena, &result, "[[{s}]]\n", .{name});
        const keys = rand.intRangeAtMost(usize, 2, 7);
        for (0..keys) |j| {
            const s = try generateKeyValueDeterministic(arena, j);
            try result.appendSlice(arena, s);
        }
        try result.append(arena, '\n');
    }

    return result.toOwnedSlice(arena);
}

fn generateFlatKvDeterministic(arena: Allocator, target_size: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;

    var i: usize = 0;
    while (result.items.len < target_size) : (i += 1) {
        const s = try generateKeyValueDeterministic(arena, i);
        try result.appendSlice(arena, s);
    }

    return result.toOwnedSlice(arena);
}

fn generateFlatKvRandom(arena: Allocator, rand: std.Random, target_size: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;

    var i: usize = 0;
    while (result.items.len < target_size) : (i += 1) {
        const s = try generateKeyValueRandom(arena, rand, i);
        try result.appendSlice(arena, s);
    }

    return result.toOwnedSlice(arena);
}

fn generateInlineHeavyDeterministic(arena: Allocator, target_size: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;

    var i: usize = 0;
    while (result.items.len < target_size) : (i += 1) {
        try appendPrint(
            arena,
            &result,
            "array_{d} = {s}\n",
            .{
                i,
                try generateInlineArrayDeterministic(arena, i, 0),
            },
        );
        try appendPrint(
            arena,
            &result,
            "table_{d} = {s}\n",
            .{
                i,
                try generateInlineTableDeterministic(arena, i, 0),
            },
        );
    }

    return result.toOwnedSlice(arena);
}

fn generateInlineHeavyRandom(arena: Allocator, rand: std.Random, target_size: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;

    var i: usize = 0;
    while (result.items.len < target_size) : (i += 1) {
        try appendPrint(
            arena,
            &result,
            "{s}_{d} = {s}\n",
            .{
                try randomStringRange(arena, rand, 3, 9),
                i,
                try generateInlineArrayRandom(arena, rand, i, 0),
            },
        );
        try appendPrint(
            arena,
            &result,
            "{s}_{d} = {s}\n",
            .{
                try randomStringRange(arena, rand, 3, 9),
                i,
                try generateInlineTableRandom(arena, rand, i, 0),
            },
        );
    }

    return result.toOwnedSlice(arena);
}

fn generateInlineArrayDeterministic(arena: Allocator, pos: usize, nesting: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;

    const nested = if (nesting <= bench_options.max_nesting) blk: {
        break :blk try generateInlineArrayDeterministic(arena, pos + 1, nesting + 1);
    } else "\"last\"";

    switch (pos % 4) {
        0 => try appendPrint(
            arena,
            &result,
            "[{s}, {d}, \"str\", {d}]",
            .{
                nested,
                pos * 3,
                @as(f64, @floatFromInt(pos * 2)) + 0.12,
            },
        ),
        1 => try appendPrint(
            arena,
            &result,
            "[{d}, {s}, \"str\", {d}]",
            .{
                pos * 3,
                nested,
                @as(f64, @floatFromInt(pos * 2)) + 0.12,
            },
        ),
        2 => try appendPrint(
            arena,
            &result,
            "[{d}, \"str\", {s}, {d}]",
            .{
                pos * 3,
                nested,
                @as(f64, @floatFromInt(pos * 2)) + 0.12,
            },
        ),
        3 => try appendPrint(
            arena,
            &result,
            "[{d}, \"str\", {d}, {s}]",
            .{
                pos * 3,
                @as(f64, @floatFromInt(pos * 2)) + 0.12,
                nested,
            },
        ),
        else => unreachable,
    }

    return result.toOwnedSlice(arena);
}

fn generateInlineTableDeterministic(arena: Allocator, pos: usize, nesting: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;

    const nested = if (nesting <= bench_options.max_nesting) blk: {
        break :blk try generateInlineTableDeterministic(arena, pos + 1, nesting + 1);
    } else blk: {
        const keyval = try generateKeyValueDeterministic(arena, nesting);
        const trimmed = std.mem.trim(u8, keyval, " \t\n");
        const i = std.mem.indexOfScalar(u8, trimmed, '=').?;
        break :blk trimmed[i + 2 ..];
    };

    switch (pos % 4) {
        0 => try appendPrint(
            arena,
            &result,
            "{{ table = {s}, number = {d}, foo = \"bar\", product = {d} }}",
            .{
                nested,
                pos * 3,
                @as(f64, @floatFromInt(pos * 2)) + 0.12,
            },
        ),
        1 => try appendPrint(
            arena,
            &result,
            "{{ number = {d}, table = {s}, foo = \"bar\", product = {d} }}",
            .{
                pos * 3,
                nested,
                @as(f64, @floatFromInt(pos * 2)) + 0.12,
            },
        ),
        2 => try appendPrint(
            arena,
            &result,
            "{{ number = {d}, foo = \"bar\", table = {s}, product = {d} }}",
            .{
                pos * 3,
                nested,
                @as(f64, @floatFromInt(pos * 2)) + 0.12,
            },
        ),
        3 => try appendPrint(
            arena,
            &result,
            "{{ number = {d}, foo = \"bar\", product = {d}, table = {s} }}",
            .{
                pos * 3,
                @as(f64, @floatFromInt(pos * 2)) + 0.12,
                nested,
            },
        ),
        else => unreachable,
    }

    return result.toOwnedSlice(arena);
}

fn generateInlineArrayRandom(arena: Allocator, rand: std.Random, pos: usize, nesting: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;

    const nested = if (nesting <= bench_options.max_nesting) blk: {
        break :blk try generateInlineArrayRandom(arena, rand, pos + 1, nesting + 1);
    } else try std.mem.concat(arena, u8, &.{ "\"", try randomStringRange(arena, rand, 5, 12), "\"" });

    switch (pos % 4) {
        0 => try appendPrint(
            arena,
            &result,
            "[{s}, {d}, \"{s}\", {d}]",
            .{
                nested,
                rand.int(u32),
                try randomStringRange(arena, rand, 2, 20),
                @as(f64, @floatFromInt(rand.int(u8))) + rand.float(f64),
            },
        ),
        1 => try appendPrint(
            arena,
            &result,
            "[{d}, {s}, \"{s}\", {d}]",
            .{
                rand.int(u32),
                nested,
                try randomStringRange(arena, rand, 2, 20),
                @as(f64, @floatFromInt(rand.int(u8))) + rand.float(f64),
            },
        ),
        2 => try appendPrint(
            arena,
            &result,
            "[{d}, \"{s}\", {s}, {d}]",
            .{
                rand.int(u32),
                try randomStringRange(arena, rand, 2, 20),
                nested,
                @as(f64, @floatFromInt(rand.int(u8))) + rand.float(f64),
            },
        ),
        3 => try appendPrint(
            arena,
            &result,
            "[{d}, \"{s}\", {d}, {s}]",
            .{
                rand.int(u32),
                try randomStringRange(arena, rand, 2, 20),
                @as(f64, @floatFromInt(rand.int(u8))) + rand.float(f64),
                nested,
            },
        ),
        else => unreachable,
    }

    return result.toOwnedSlice(arena);
}

fn generateInlineTableRandom(arena: Allocator, rand: std.Random, pos: usize, nesting: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;

    const nested = if (nesting <= bench_options.max_nesting) blk: {
        break :blk try generateInlineTableRandom(arena, rand, pos + 1, nesting + 1);
    } else blk: {
        const keyval = try generateKeyValueRandom(arena, rand, nesting);
        const trimmed = std.mem.trim(u8, keyval, " \t\n");
        const i = std.mem.indexOfScalar(u8, trimmed, '=').?;
        break :blk trimmed[i + 2 ..];
    };

    switch (pos % 4) {
        0 => try appendPrint(
            arena,
            &result,
            "{{ table = {s}, number = {d}, foo = \"{s}\", product = {d} }}",
            .{
                nested,
                rand.int(u32),
                try randomStringRange(arena, rand, 3, 14),
                @as(f64, @floatFromInt(rand.int(u8))) + rand.float(f64),
            },
        ),
        1 => try appendPrint(
            arena,
            &result,
            "{{ number = {d}, table = {s}, foo = \"{s}\", product = {d} }}",
            .{
                rand.int(u32),
                nested,
                try randomStringRange(arena, rand, 3, 14),
                @as(f64, @floatFromInt(rand.int(u8))) + rand.float(f64),
            },
        ),
        2 => try appendPrint(
            arena,
            &result,
            "{{ number = {d}, foo = \"{s}\", table = {s}, product = {d} }}",
            .{
                rand.int(u32),
                try randomStringRange(arena, rand, 3, 14),
                nested,
                @as(f64, @floatFromInt(rand.int(u8))) + rand.float(f64),
            },
        ),
        3 => try appendPrint(
            arena,
            &result,
            "{{ number = {d}, foo = \"{s}\", product = {d}, table = {s} }}",
            .{
                rand.int(u32),
                try randomStringRange(arena, rand, 3, 14),
                @as(f64, @floatFromInt(rand.int(u8))) + rand.float(f64),
                nested,
            },
        ),
        else => unreachable,
    }

    return result.toOwnedSlice(arena);
}

fn generateKeyValueRandom(arena: Allocator, rand: std.Random, i: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;

    switch (rand.uintAtMost(u8, 4)) {
        0 => {
            try appendRandomString(arena, rand, &result, 3, 20);
            try appendPrint(arena, &result, "_{d} = \"", .{i});
            try appendRandomString(arena, rand, &result, 3, 20);
            try result.appendSlice(arena, "\"\n");
        },
        1 => {
            try appendRandomString(arena, rand, &result, 3, 20);
            try appendPrint(arena, &result, "_{d} = ", .{i});
            if (rand.uintAtMost(u32, 100_000) % 2 == 0) {
                try result.appendSlice(arena, "true\n");
            } else {
                try result.appendSlice(arena, "false\n");
            }
        },
        2 => {
            try appendRandomString(arena, rand, &result, 3, 20);
            switch (rand.int(u3)) {
                0 => try appendPrint(arena, &result, "_{d} = 0b{b}\n", .{ i, rand.int(u32) }),
                1 => try appendPrint(arena, &result, "_{d} = 0o{o}\n", .{ i, rand.int(u32) }),
                2 => try appendPrint(arena, &result, "_{d} = 0x{x}\n", .{ i, rand.int(u32) }),
                else => try appendPrint(arena, &result, "_{d} = {d}\n", .{ i, rand.int(i64) }),
            }
        },
        3 => {
            try appendRandomString(arena, rand, &result, 3, 20);
            switch (rand.int(u1)) {
                0 => try appendPrint(arena, &result, "_{d} = {e}\n", .{
                    i,
                    rand.float(f64) + @as(f64, @floatFromInt(rand.int(u32))),
                }),
                1 => try appendPrint(arena, &result, "_{d} = {d}\n", .{
                    i,
                    rand.float(f64) + @as(f64, @floatFromInt(rand.int(u32))),
                }),
            }
        },
        4 => {
            try appendRandomString(arena, rand, &result, 3, 20);
            try appendPrint(arena, &result, "_{d} = {d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}\n", .{
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

    return result.toOwnedSlice(arena);
}

fn generateKeyValueDeterministic(arena: Allocator, i: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;

    switch (i % 5) {
        0 => try appendPrint(arena, &result, "string_{d} = \"string_val_{d}\"\n", .{ i, i }),
        1 => try appendPrint(arena, &result, "bool_{d} = {s}\n", .{ i, if (i % 2 == 0) "true" else "false" }),
        2 => try appendPrint(arena, &result, "int_{d} = {d}\n", .{ i, i * 44 }),
        3 => try appendPrint(arena, &result, "float_{d} = {d}\n", .{ i, @as(f64, @floatFromInt(i * 27)) }),
        4 => try appendPrint(arena, &result, "dt_{d} = 2024-01-{d:0>2}T12:00:00Z\n", .{ i, (i % 28) + 1 }),
        else => unreachable,
    }

    return result.toOwnedSlice(arena);
}

fn appendPrint(arena: Allocator, list: *ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const line = try std.fmt.allocPrint(arena, fmt, args);
    try list.appendSlice(arena, line);
}

fn appendRandomString(arena: Allocator, rand: std.Random, list: *ArrayList(u8), at_least: usize, at_most: usize) !void {
    const s = try randomStringRange(arena, rand, at_least, at_most);
    try list.appendSlice(arena, s);
}

fn randomStringRange(arena: Allocator, rand: std.Random, at_least: usize, at_most: usize) ![]const u8 {
    const len = rand.intRangeAtMost(usize, at_least, at_most);
    const buf: []u8 = try arena.alloc(u8, len);
    randomString(rand, buf);
    return buf;
}

fn randomString(rand: std.Random, out: []u8) void {
    for (out) |*c| {
        const b = rand.int(u8);
        c.* = alphabet[b % alphabet.len];
    }
}
