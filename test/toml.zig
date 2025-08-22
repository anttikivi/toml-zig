const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const fmt = std.fmt;
const Io = std.Io;
const json = std.json;

const toml = @import("toml");

const native_os = builtin.target.os.tag;

const Error = Allocator.Error || fmt.BufPrintError || error{ InvalidDatetime, InvalidTomlValue };

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    const toml_bytes = try stdin.allocRemaining(allocator, .unlimited);
    defer allocator.free(toml_bytes);

    var parsed = toml.parse(allocator, toml_bytes) catch |e| {
        var diag: toml.Diagnostics = undefined;
        _ = toml.parseWithDiagnostics(allocator, toml_bytes, &diag) catch {};
        std.debug.print("{f}\n", .{diag});
        return e;
    };
    defer parsed.deinit(allocator);

    const json_value = try createJsonValue(allocator, parsed);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stdout = &stdout_writer.interface;

    try json.Stringify.value(json_value, .{}, stdout);
    try stdout.flush();
}

fn createJsonValue(allocator: Allocator, toml_value: toml.Value) Error!json.Value {
    var obj_map = json.ObjectMap.init(allocator);
    var toml_table: toml.Table = undefined;

    switch (toml_value) {
        .table => |t| toml_table = t,
        else => return error.InvalidTomlValue,
    }

    for (toml_table.keys()) |key| {
        const val = toml_table.get(key) orelse return error.InvalidTomlValue;
        try obj_map.put(try allocator.dupe(u8, key), try objectFromValue(allocator, val));
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
            for (arr.items) |item| {
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
