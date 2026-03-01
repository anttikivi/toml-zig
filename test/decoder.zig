// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const fmt = std.fmt;
const json = std.json;
const test_options = @import("test_options");

const toml = @import("toml");

const Error = Allocator.Error || fmt.BufPrintError || error{ InvalidDatetime, InvalidTomlValue };

pub fn main() void {
    run() catch {
        std.process.exit(1);
        unreachable;
    };
}

fn run() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    const toml_bytes = try stdin.allocRemaining(allocator, .unlimited);
    defer allocator.free(toml_bytes);

    var parsed = try toml.decode(
        allocator,
        toml_bytes,
        .{
            .version = std.meta.stringToEnum(toml.Version, test_options.toml_version).?,
        },
    );
    defer parsed.deinit();

    const json_value = try createJsonValue(allocator, .{ .table = parsed.root });
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    var stdout = &stdout_writer.interface;

    try json.Stringify.value(json_value, .{}, stdout);
    try stdout.flush();
}

fn createJsonValue(allocator: Allocator, toml_value: toml.Value) Error!json.Value {
    var obj_map = json.ObjectMap.init(allocator);

    const toml_table = switch (toml_value) {
        .table => |t| t,
        else => return error.InvalidTomlValue,
    };

    for (toml_table.entries) |entry| {
        try obj_map.put(try allocator.dupe(u8, entry.key), try objectFromValue(allocator, entry.value));
    }

    return .{ .object = obj_map };
}

fn objectFromValue(allocator: Allocator, toml_value: toml.Value) Error!json.Value {
    switch (toml_value) {
        .string => |s| {
            var obj: json.ObjectMap = .init(allocator);
            try obj.put("type", .{ .string = "string" });
            try obj.put("value", .{ .string = try allocator.dupe(u8, s) });
            return .{ .object = obj };
        },
        .int => |i| {
            var obj: json.ObjectMap = .init(allocator);
            try obj.put("type", .{ .string = "integer" });
            const s = try fmt.allocPrint(allocator, "{d}", .{i});
            try obj.put("value", .{ .string = s });
            return .{ .object = obj };
        },
        .float => |f| {
            var obj: json.ObjectMap = .init(allocator);
            try obj.put("type", .{ .string = "float" });
            const s = try fmt.allocPrint(allocator, "{d}", .{f});
            try obj.put("value", .{ .string = s });
            return .{ .object = obj };
        },
        .bool => |b| {
            var obj: json.ObjectMap = .init(allocator);
            try obj.put("type", .{ .string = "bool" });
            try obj.put("value", .{ .string = if (b) "true" else "false" });
            return .{ .object = obj };
        },
        .datetime => |dt| {
            var obj: json.ObjectMap = .init(allocator);
            try obj.put("type", .{ .string = "datetime" });
            const s = try fmt.allocPrint(allocator, "{f}", .{dt});
            try obj.put("value", .{ .string = s });
            return .{ .object = obj };
        },
        .local_datetime => |dt| {
            var obj: json.ObjectMap = .init(allocator);
            try obj.put("type", .{ .string = "datetime-local" });
            const s = try fmt.allocPrint(allocator, "{f}", .{dt});
            try obj.put("value", .{ .string = s });
            return .{ .object = obj };
        },
        .local_date => |d| {
            var obj: json.ObjectMap = .init(allocator);
            try obj.put("type", .{ .string = "date-local" });
            const s = try fmt.allocPrint(allocator, "{f}", .{d});
            try obj.put("value", .{ .string = s });
            return .{ .object = obj };
        },
        .local_time => |t| {
            var obj: json.ObjectMap = .init(allocator);
            try obj.put("type", .{ .string = "time-local" });
            const s = try fmt.allocPrint(allocator, "{f}", .{t});
            try obj.put("value", .{ .string = s });
            return .{ .object = obj };
        },
        .array => |arr| {
            var array: json.Array = .init(allocator);
            for (arr) |item| {
                const json_value = try objectFromValue(allocator, item);
                try array.append(json_value);
            }
            return .{ .array = array };
        },
        .table => {
            return try createJsonValue(allocator, toml_value);
        },
    }
}
