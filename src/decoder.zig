const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const assert = std.debug.assert;

const Parser = @import("Parser.zig");
const Scanner = @import("Scanner.zig");
const Value = @import("value.zig").Value;

var stderr_buffer: [4096]u8 = undefined;

pub const Position = struct {
    line: usize,
    column: usize,
    snippet: []const u8,

    pub fn find(input: []const u8, cursor: usize) @This() {
        const line = 1 + std.mem.count(u8, input[0..cursor], "\n");
        return findLineKnown(input, cursor, line);
    }

    pub fn findLineKnown(input: []const u8, cursor: usize, line: usize) @This() {
        const start = std.mem.lastIndexOfScalar(u8, input[0..cursor], '\n') orelse 0;
        const end = std.mem.indexOfScalarPos(u8, input, cursor, '\n') orelse input.len;
        const col = (cursor - start) + 1;

        return .{
            .line = line,
            .column = col,
            .snippet = input[(if (start > 0) start + 1 else start)..end],
        };
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            "error parsing TOML document on line {d}, column {d}\n",
            .{ self.line, self.column },
        );

        try writer.writeAll(self.snippet);
        try writer.writeByte('\n');
        try writer.splatByteAll(' ', self.column - 1);
        try writer.writeByte('^');
    }
};

pub fn parse(gpa: Allocator, input: []const u8) !Value {
    try utf8Validate(input);

    var arena_instance: ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var parsing_root: Parser.ParsingValue = .{ .value = .{ .table = .init(arena) } };
    var scanner: Scanner = undefined;
    scanner.initCompleteInput(arena, input);

    var parser: Parser = undefined;
    parser.init(arena, &scanner, &parsing_root);

    while (scanner.cursor < input.len) {
        var token = try scanner.nextKey();
        if (token == .end_of_file) {
            break;
        }

        switch (token) {
            .line_feed => continue,
            .left_bracket => {
                try parser.parseTableExpression();
                continue;
            },
            .double_left_bracket => {
                try parser.parseArrayTableExpression();
                continue;
            },
            .end_of_file => unreachable,
            .literal,
            .string,
            .literal_string,
            => try parser.parseKeyValueExpressionStartingWith(token),
            else => return fail("unexpected token", &scanner),
        }

        token = try scanner.nextKey();
        if (token == .line_feed or token == .end_of_file) {
            continue;
        }

        return fail("unexpected token", &scanner);
    }

    return parseResult(gpa, parsing_root);
}

/// Convert the intermediate parsing values into the proper TOML return values.
fn parseResult(allocator: Allocator, parsed_value: Parser.ParsingValue) !Value {
    switch (parsed_value.value) {
        .string => |s| return .{ .string = try allocator.dupe(u8, s) },
        .int => |i| return .{ .int = i },
        .float => |f| return .{ .float = f },
        .bool => |b| return .{ .bool = b },
        .datetime => |dt| {
            assert(dt.isValid());
            return .{ .datetime = dt };
        },
        .local_datetime => |dt| {
            assert(dt.isValid());
            return .{ .local_datetime = dt };
        },
        .local_date => |d| {
            assert(d.isValid());
            return .{ .local_date = d };
        },
        .local_time => |t| {
            assert(t.isValid());
            return .{ .local_time = t };
        },
        .array => |array| {
            var result: Value = .{ .array = .empty };
            for (array.items) |item| {
                try result.array.append(allocator, try parseResult(allocator, item));
            }
            return result;
        },
        .table => |table| {
            var result: Value = .{ .table = .init(allocator) };
            var iterator = table.iterator();
            while (iterator.next()) |entry| {
                try result.table.put(
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try parseResult(allocator, entry.value_ptr.*),
                );
            }
            return result;
        },
    }
}

/// Check if the input is a valid UTF-8 string. The function goes through
/// the whole input and checks each byte. It may be skipped if working under
/// strict constraints.
///
/// See: http://unicode.org/mail-arch/unicode-ml/y2003-m02/att-0467/01-The_Algorithm_to_Valide_an_UTF-8_String
fn utf8Validate(input: []const u8) !void {
    const Utf8State = enum { start, a, b, c, d, e, f, g };
    var state: Utf8State = .start;
    var i: usize = 0;

    while (i < input.len) : (i += 1) {
        const c = input[i];
        switch (state) {
            .start => switch (c) {
                0...0x7F => {},
                0xC2...0xDF => state = .a,
                0xE1...0xEC, 0xEE...0xEF => state = .b,
                0xE0 => state = .c,
                0xED => state = .d,
                0xF1...0xF3 => state = .e,
                0xF0 => state = .f,
                0xF4 => state = .g,
                0x80...0xBF, 0xC0...0xC1, 0xF5...0xFF => return failUtf8(input, i),
            },
            .a => switch (c) {
                0x80...0xBF => state = .start,
                else => return failUtf8(input, i),
            },
            .b => switch (c) {
                0x80...0xBF => state = .a,
                else => return failUtf8(input, i),
            },
            .c => switch (c) {
                0xA0...0xBF => state = .a,
                else => return failUtf8(input, i),
            },
            .d => switch (c) {
                0x80...0x9F => state = .a,
                else => return failUtf8(input, i),
            },
            .e => switch (c) {
                0x80...0xBF => state = .b,
                else => return failUtf8(input, i),
            },
            .f => switch (c) {
                0x90...0xBF => state = .b,
                else => return failUtf8(input, i),
            },
            .g => switch (c) {
                0x80...0x8F => state = .b,
                else => return failUtf8(input, i),
            },
        }
    }
}

fn fail(msg: []const u8, scanner: *const Scanner) error{ Reported, WriteFailed } {
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    try stderr.print("{f}", .{Position.findLineKnown(scanner.input, scanner.cursor, scanner.line)});
    try stderr.writeByte(' ');
    try stderr.writeAll(msg);
    try stderr.writeByte('\n');
    try stderr.flush();

    return error.Reported;
}

fn failUtf8(input: []const u8, cursor: usize) error{ Reported, WriteFailed } {
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    try stderr.print("{f}", .{Position.find(input, cursor)});
    try stderr.writeAll(" invalid UTF-8\n");
    try stderr.flush();

    return error.Reported;
}
