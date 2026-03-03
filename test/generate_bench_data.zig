// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
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
var stderr_buffer: [8192]u8 = undefined;

fn effectiveMaxNesting() usize {
    return @max(@as(usize, 1), @as(usize, bench_options.max_nesting));
}

pub fn main() !void {
    const gpa = debug_allocator.allocator();
    defer _ = debug_allocator.deinit();

    var stderr_stream = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_stream.interface;

    const cwd = std.fs.cwd();

    var dir = try cwd.makeOpenPath(bench_options.data_path, .{});
    defer dir.close();

    var fixtures: ArrayList([]const u8) = .empty;
    defer {
        for (fixtures.items) |item| {
            gpa.free(item);
        }
        fixtures.deinit(gpa);
    }

    for (bench_options.benchmarks) |fixture| {
        if (std.meta.stringToEnum(Size, fixture)) |_| {
            for (std.meta.fieldNames(Pattern)) |pattern| {
                const full_fixture = try std.mem.concat(gpa, u8, &.{ fixture, "-", pattern });

                for (fixtures.items) |f| {
                    if (std.mem.eql(u8, f, full_fixture)) {
                        try stderr.print("duplicate fixture {s}\n", .{full_fixture});
                        try stderr.flush();
                        return error.DuplicateFixture;
                    }
                }

                try fixtures.append(gpa, full_fixture);
            }
        } else {
            const full_fixture = try gpa.dupe(u8, fixture);

            for (fixtures.items) |f| {
                if (std.mem.eql(u8, f, full_fixture)) {
                    try stderr.print("duplicate fixture {s}\n", .{full_fixture});
                    try stderr.flush();
                    return error.DuplicateFixture;
                }
            }

            try fixtures.append(gpa, full_fixture);
        }
    }

    for (fixtures.items) |fixture| {
        try stderr.print("generating {s}\n", .{fixture});
        try stderr.flush();

        const i = std.mem.indexOfScalar(
            u8,
            fixture,
            '-',
        ) orelse std.debug.panic("invalid benchmark generation target: {s}", .{fixture});
        const size_name = fixture[0..i];
        const pattern_name = fixture[i + 1 ..];
        const size = std.meta.stringToEnum(Size, size_name) orelse std.debug.panic("invalid benchmark size in {s}", .{fixture});
        const pattern = std.meta.stringToEnum(
            Pattern,
            pattern_name,
        ) orelse std.debug.panic("invalid benchmark pattern in {s}", .{fixture});

        var prng = std.Random.DefaultPrng.init(bench_options.bench_seed);
        const rand = prng.random();

        var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        const data = if (bench_options.random_bench) switch (pattern) {
            .array_tables => try generateArrayTablesRandom(arena, rand, size.targetSize()),
            .flat_kv => try generateFlatKvRandom(arena, rand, size.targetSize()),
            .inline_heavy => try generateInlineHeavyRandom(arena, rand, size.targetSize()),
            .mixed_realistic => try generateMixedRealisticRandom(arena, rand, size.targetSize()),
            .nested_tables => try generateNestedTablesRandom(arena, rand, size.targetSize()),
            .string_escapes => try generateStringEscapesRandom(arena, rand, size.targetSize()),
        } else switch (pattern) {
            .array_tables => try generateArrayTablesDeterministic(arena, size.targetSize()),
            .flat_kv => try generateFlatKvDeterministic(arena, size.targetSize()),
            .inline_heavy => try generateInlineHeavyDeterministic(arena, size.targetSize()),
            .mixed_realistic => try generateMixedRealisticDeterministic(arena, size.targetSize()),
            .nested_tables => try generateNestedTablesDeterministic(arena, size.targetSize()),
            .string_escapes => try generateStringEscapesDeterministic(arena, size.targetSize()),
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

        const full_path = try std.fs.path.join(gpa, &.{ bench_options.data_path, filename });
        defer gpa.free(full_path);

        try stderr.print("wrote {d} bytes to {s}\n", .{ data.len, full_path });
        try stderr.flush();
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
        try result.appendSlice(arena, s);
        try appendPrint(arena, &result, "name = \"item_{d}\"\n", .{i});
        try appendPrint(arena, &result, "enabled = {s}\n", .{if (i % 2 == 0) "true" else "false"});
        try appendPrint(arena, &result, "tags = [\"tag{d}\", \"tag{d}\", \"common\"]\n\n", .{ i % 10, (i + 1) % 10 });
    }

    return result.toOwnedSlice(arena);
}

fn generateArrayTablesRandom(arena: Allocator, rand: std.Random, target_size: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;
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

    const nested = if (nesting < effectiveMaxNesting()) blk: {
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

    const nested = if (nesting < effectiveMaxNesting()) blk: {
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

fn generateMixedRealisticDeterministic(arena: Allocator, target_size: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;

    const sections = [_][]const u8{ "server", "database", "logging", "cache", "auth", "metrics", "notifications" };

    var i: usize = 0;
    while (result.items.len < target_size) : (i += 1) {
        switch (i % 7) {
            0 => {
                const section = sections[i / 7 % sections.len];
                try appendPrint(arena, &result, "[{s}.config_{d}]\n", .{ section, i });
                try appendPrint(arena, &result, "name = \"service_{d}\"\n", .{i});
                try appendPrint(arena, &result, "enabled = {s}\n", .{if (i % 2 == 0) "true" else "false"});
                try appendPrint(arena, &result, "port = {d}\n", .{8000 + i});
                try appendPrint(arena, &result, "weight = {d}\n", .{@as(f64, @floatFromInt(i)) * 0.75 + 1.5});
                try appendPrint(arena, &result, "created = 2024-{d:0>2}-{d:0>2}T{d:0>2}:00:00Z\n\n", .{
                    (i % 12) + 1,
                    (i % 28) + 1,
                    i % 24,
                });
            },
            1 => {
                try appendPrint(arena, &result, "[[services]]\n", .{});
                try appendPrint(arena, &result, "id = {d}\n", .{i});
                try appendPrint(arena, &result, "host = \"host_{d}.example.com\"\n", .{i});
                try appendPrint(arena, &result, "tags = [\"prod\", \"v{d}\", \"region_{d}\"]\n\n", .{ i % 10, i % 5 });
            },
            2 => {
                try appendPrint(
                    arena,
                    &result,
                    "endpoint_{d} = {{ url = \"https://api.example.com/v{d}\", timeout = {d}, retries = {d} }}\n",
                    .{ i, i % 5 + 1, (i + 1) * 100, i % 3 + 1 },
                );
            },
            3 => {
                try appendPrint(arena, &result, "description_{d} = \"\"\"\n", .{i});
                try appendPrint(arena, &result, "This is entry number {d}.\n", .{i});
                try appendPrint(arena, &result, "It contains multiple lines of text\n", .{});
                try appendPrint(arena, &result, "for testing purposes.\n\"\"\"\n\n", .{});
            },
            4 => {
                const section = sections[(i / 7 + 1) % sections.len];
                try appendPrint(arena, &result, "[{s}.pool_{d}]\n", .{ section, i });
                try appendPrint(arena, &result, "min_size = {d}\n", .{i % 10 + 1});
                try appendPrint(arena, &result, "max_size = {d}\n", .{i % 10 + 50});
                try appendPrint(arena, &result, "idle_timeout = {d}\n\n", .{(i + 1) * 30});
            },
            5 => {
                try appendPrint(arena, &result, "[[rules]]\n", .{});
                try appendPrint(arena, &result, "priority = {d}\n", .{i % 10});
                try appendPrint(arena, &result, "action = {{ type = \"redirect\", target = \"/path_{d}\" }}\n", .{i});
                try appendPrint(arena, &result, "conditions = [\"method=GET\", \"path=/api/{d}\"]\n\n", .{i});
            },
            6 => {
                try appendPrint(arena, &result, "global_flag_{d} = {s}\n", .{ i, if (i % 3 == 0) "true" else "false" });
                try appendPrint(arena, &result, "global_count_{d} = {d}\n", .{ i, i * 42 });
                try appendPrint(arena, &result, "global_ratio_{d} = {d}\n", .{ i, @as(f64, @floatFromInt(i)) * 3.14 });
                try appendPrint(arena, &result, "global_label_{d} = \"label_{d}\"\n\n", .{ i, i });
            },
            else => unreachable,
        }
    }

    return result.toOwnedSlice(arena);
}

fn generateMixedRealisticRandom(arena: Allocator, rand: std.Random, target_size: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;

    var section_names: ArrayList([]const u8) = .empty;
    for (0..rand.intRangeAtMost(usize, 5, 10)) |_| {
        const s = try randomStringRange(arena, rand, 4, 12);
        try section_names.append(arena, s);
    }

    var i: usize = 0;
    while (result.items.len < target_size) : (i += 1) {
        switch (rand.uintAtMost(u8, 6)) {
            0 => {
                const section = section_names.items[rand.uintLessThan(usize, section_names.items.len)];
                try appendPrint(arena, &result, "[{s}.", .{section});
                try appendRandomString(arena, rand, &result, 3, 8);
                try appendPrint(arena, &result, "_{d}]\n", .{i});
                const kvs = rand.intRangeAtMost(usize, 3, 7);
                for (0..kvs) |j| {
                    const s = try generateKeyValueRandom(arena, rand, j);
                    try result.appendSlice(arena, s);
                }
                try result.append(arena, '\n');
            },
            1 => {
                try result.appendSlice(arena, "[[");
                try appendRandomString(arena, rand, &result, 4, 10);
                try result.appendSlice(arena, "]]\n");
                const kvs = rand.intRangeAtMost(usize, 2, 5);
                for (0..kvs) |j| {
                    const s = try generateKeyValueRandom(arena, rand, j);
                    try result.appendSlice(arena, s);
                }
                try result.append(arena, '\n');
            },
            2 => {
                try appendRandomString(arena, rand, &result, 3, 8);
                try appendPrint(arena, &result, "_{d} = {{ ", .{i});
                const fields = rand.intRangeAtMost(usize, 2, 4);
                for (0..fields) |f| {
                    if (f != 0) try result.appendSlice(arena, ", ");
                    try appendRandomString(arena, rand, &result, 3, 8);
                    try result.appendSlice(arena, " = ");
                    switch (rand.uintAtMost(u8, 2)) {
                        0 => {
                            try result.append(arena, '"');
                            try appendRandomString(arena, rand, &result, 3, 12);
                            try result.append(arena, '"');
                        },
                        1 => try appendPrint(arena, &result, "{d}", .{rand.int(u32)}),
                        2 => try appendPrint(arena, &result, "{d}", .{
                            @as(f64, @floatFromInt(rand.int(u8))) + rand.float(f64),
                        }),
                        else => unreachable,
                    }
                }
                try result.appendSlice(arena, " }\n");
            },
            3 => {
                try appendRandomString(arena, rand, &result, 3, 8);
                try appendPrint(arena, &result, "_{d} = \"\"\"\n", .{i});
                const lines = rand.intRangeAtMost(usize, 2, 4);
                for (0..lines) |_| {
                    try appendRandomString(arena, rand, &result, 10, 40);
                    try result.append(arena, '\n');
                }
                try result.appendSlice(arena, "\"\"\"\n");
            },
            4 => {
                const section = section_names.items[rand.uintLessThan(usize, section_names.items.len)];
                try appendPrint(arena, &result, "[{s}.", .{section});
                const depth = rand.intRangeAtMost(usize, 1, 3);
                for (0..depth) |d| {
                    if (d != 0) try result.append(arena, '.');
                    try appendRandomString(arena, rand, &result, 3, 7);
                }
                try appendPrint(arena, &result, ".n_{d}]\n", .{i});
                const kvs = rand.intRangeAtMost(usize, 2, 5);
                for (0..kvs) |j| {
                    const s = try generateKeyValueRandom(arena, rand, j);
                    try result.appendSlice(arena, s);
                }
                try result.append(arena, '\n');
            },
            5 => {
                try appendRandomString(arena, rand, &result, 3, 8);
                try appendPrint(arena, &result, "_{d} = [", .{i});
                const elems = rand.intRangeAtMost(usize, 3, 6);
                for (0..elems) |e| {
                    if (e != 0) try result.appendSlice(arena, ", ");
                    try result.append(arena, '"');
                    try appendRandomString(arena, rand, &result, 3, 10);
                    try result.append(arena, '"');
                }
                try result.appendSlice(arena, "]\n");
            },
            6 => {
                const kvs = rand.intRangeAtMost(usize, 2, 5);
                for (0..kvs) |j| {
                    const s = try generateKeyValueRandom(arena, rand, j);
                    try result.appendSlice(arena, s);
                }
            },
            else => unreachable,
        }
    }

    return result.toOwnedSlice(arena);
}

fn generateNestedTablesDeterministic(arena: Allocator, target_size: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;

    const table_names = [_][]const u8{ "server", "database", "logging", "cache", "auth", "metrics" };

    var i: usize = 0;
    while (result.items.len < target_size) : (i += 1) {
        const root = table_names[i % table_names.len];

        var path: ArrayList(u8) = .empty;
        try path.appendSlice(arena, root);
        const depth = (i % effectiveMaxNesting()) + 1;
        for (0..depth) |d| {
            try appendPrint(arena, &path, ".level_{d}", .{d});
        }
        try appendPrint(arena, &path, ".n_{d}", .{i});
        try appendPrint(arena, &result, "[{s}]\n", .{path.items});

        const kvs = (i % 5) + 2;
        for (0..kvs) |j| {
            const s = try generateKeyValueDeterministic(arena, i * 7 + j);
            try result.appendSlice(arena, s);
        }
        try result.append(arena, '\n');
    }

    return result.toOwnedSlice(arena);
}

fn generateNestedTablesRandom(arena: Allocator, rand: std.Random, target_size: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;

    var root_names: ArrayList([]const u8) = .empty;
    const roots = rand.intRangeAtMost(usize, 4, 8);
    for (0..roots) |_| {
        const s = try randomStringRange(arena, rand, 4, 10);
        try root_names.append(arena, s);
    }

    var i: usize = 0;
    while (result.items.len < target_size) : (i += 1) {
        const root = root_names.items[i % root_names.items.len];

        var path: ArrayList(u8) = .empty;
        try path.appendSlice(arena, root);
        const depth = rand.intRangeAtMost(usize, 1, effectiveMaxNesting());
        for (0..depth) |_| {
            try path.append(arena, '.');
            try appendRandomString(arena, rand, &path, 3, 8);
        }
        try appendPrint(arena, &path, ".n_{d}", .{i});
        try appendPrint(arena, &result, "[{s}]\n", .{path.items});

        const kvs = rand.intRangeAtMost(usize, 2, 7);
        for (0..kvs) |j| {
            const s = try generateKeyValueRandom(arena, rand, j);
            try result.appendSlice(arena, s);
        }
        try result.append(arena, '\n');
    }

    return result.toOwnedSlice(arena);
}

fn generateStringEscapesDeterministic(arena: Allocator, target_size: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;

    const escape_strings = [_][]const u8{
        "\"hello\\tworld\\n\"",
        "\"path\\\\to\\\\file\"",
        "\"quote\\\"inside\\\"string\"",
        "\"line1\\nline2\\nline3\"",
        "\"tab\\there\\tand\\tthere\"",
        "\"backspace\\b and formfeed\\f\"",
        "\"unicode \\u0041\\u0042\\u0043\"",
        "\"mixed \\t\\n\\r\\\\\\\"end\"",
        "\"\"\"\nmultiline\nstring\nvalue\n\"\"\"",
        "\"\"\"first line\nsecond line\nthird line\n\"\"\"",
        "'literal \\n no escape'",
        "'C:\\Users\\admin\\docs'",
        "'''\nliteral\nmultiline\n'''",
        "'''\nno \\escapes\n\\at \\all\n'''",
    };

    var i: usize = 0;
    while (result.items.len < target_size) : (i += 1) {
        const val = escape_strings[i % escape_strings.len];
        switch (i % 3) {
            0 => try appendPrint(arena, &result, "str_{d} = {s}\n", .{ i, val }),
            1 => {
                try appendPrint(arena, &result, "[section_{d}]\n", .{i});
                try appendPrint(arena, &result, "value = {s}\n", .{val});
                try appendPrint(arena, &result, "label = \"entry_{d}\"\n\n", .{i});
            },
            2 => try appendPrint(arena, &result, "escaped_{d} = {s}\n", .{ i, val }),
            else => unreachable,
        }
    }

    return result.toOwnedSlice(arena);
}

fn generateStringEscapesRandom(arena: Allocator, rand: std.Random, target_size: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;

    var i: usize = 0;
    while (result.items.len < target_size) : (i += 1) {
        const key = try randomStringRange(arena, rand, 3, 12);
        switch (rand.uintAtMost(u8, 5)) {
            0 => {
                try appendPrint(arena, &result, "{s}_{d} = \"", .{ key, i });
                const parts = rand.intRangeAtMost(usize, 2, 5);
                for (0..parts) |_| {
                    try appendRandomString(arena, rand, &result, 3, 10);
                    const esc = switch (rand.uintAtMost(u8, 5)) {
                        0 => "\\n",
                        1 => "\\t",
                        2 => "\\\\",
                        3 => "\\\"",
                        4 => "\\r",
                        5 => "\\b",
                        else => unreachable,
                    };
                    try result.appendSlice(arena, esc);
                }
                try appendRandomString(arena, rand, &result, 2, 8);
                try result.appendSlice(arena, "\"\n");
            },
            1 => {
                try appendPrint(arena, &result, "{s}_{d} = \"\"\"\n", .{ key, i });
                const lines = rand.intRangeAtMost(usize, 2, 5);
                for (0..lines) |_| {
                    try appendRandomString(arena, rand, &result, 5, 30);
                    try result.append(arena, '\n');
                }
                try result.appendSlice(arena, "\"\"\"\n");
            },
            2 => {
                try appendPrint(arena, &result, "{s}_{d} = '", .{ key, i });
                try appendRandomString(arena, rand, &result, 5, 25);
                try result.appendSlice(arena, "\\n\\t\\\\");
                try appendRandomString(arena, rand, &result, 3, 10);
                try result.appendSlice(arena, "'\n");
            },
            3 => {
                try appendPrint(arena, &result, "{s}_{d} = '''\n", .{ key, i });
                const lines = rand.intRangeAtMost(usize, 2, 4);
                for (0..lines) |_| {
                    try appendRandomString(arena, rand, &result, 5, 25);
                    try result.appendSlice(arena, " \\not\\escaped");
                    try result.append(arena, '\n');
                }
                try result.appendSlice(arena, "'''\n");
            },
            4 => {
                try appendPrint(arena, &result, "{s}_{d} = \"\\u00", .{ key, i });
                const code = rand.intRangeAtMost(u8, 0x41, 0x5A);
                try appendPrint(arena, &result, "{X:0>2}", .{code});
                try appendRandomString(arena, rand, &result, 3, 10);
                try result.appendSlice(arena, "\"\n");
            },
            5 => {
                try appendPrint(arena, &result, "{s}_{d} = \"", .{ key, i });
                const count = rand.intRangeAtMost(usize, 4, 10);
                for (0..count) |_| {
                    const esc = switch (rand.uintAtMost(u8, 3)) {
                        0 => "\\n",
                        1 => "\\t",
                        2 => "\\\\",
                        3 => "\\r",
                        else => unreachable,
                    };
                    try result.appendSlice(arena, esc);
                    try appendRandomString(arena, rand, &result, 1, 4);
                }
                try result.appendSlice(arena, "\"\n");
            },
            else => unreachable,
        }
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

fn generateInlineArrayRandom(arena: Allocator, rand: std.Random, pos: usize, nesting: usize) ![]const u8 {
    var result: ArrayList(u8) = .empty;

    const nested = if (nesting < effectiveMaxNesting()) blk: {
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

    const nested = if (nesting < effectiveMaxNesting()) blk: {
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
