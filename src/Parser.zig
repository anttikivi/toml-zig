// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

//! Parses TOML tokens into syntax-aware items and decodes scalars from
//! the input.

const Parser = @This();

const std = @import("std");
const assert = std.debug.assert;

const Diagnostics = @import("root.zig").Diagnostics;
const Tokenizer = @import("Tokenizer.zig");
const Token = @import("Tokenizer.zig").Token;
const default_version = @import("toml.zig").default_version;
const Features = @import("toml.zig").Features;
const Float = @import("toml.zig").Float;
const Int = @import("toml.zig").Int;
const Version = @import("toml.zig").Version;

state: State = .table,
token: ?Token = null,
tokenizer: Tokenizer,
features: Features,
diagnostics: ?*Diagnostics,

pub const Options = struct {
    toml_version: Version = default_version,
    diagnostics: ?*Diagnostics = null,
};

pub const Item = struct {
    tag: Tag,
    value: ?Value = null,

    pub const Tag = enum {
        table_header_start,
        table_header_end,
        /// Key used in a table header.
        table_key,
        /// Key before a value.
        key,
        value,
    };

    pub const Value = union(enum) {
        literal: []const u8,
        string: []const u8,
        multiline_string: []const u8,
        literal_string: []const u8,
        multiline_literal_string: []const u8,
        int: Int,
        float: Float,
        boolean: bool,
        datetime: Datetime,
        local_datetime: Datetime,
        local_date: Date,
        local_time: Time,
        // TODO: Array.
        // TODO: Table.
    };
};

pub const Error = Diagnostics.Error || Tokenizer.Error || error{
    InvalidCharacter,
    InvalidDatetime,
    InvalidState,
    InvalidTime,
    Overflow,
    UnexpectedEnd,
    UnterminatedHeader,
};

/// TODO: Move to a more fitting place.
pub const Datetime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    nano: ?u32 = null,
    /// Timezone offset in minutes from UTC. `null` means local datetime.
    tz: ?i16 = null,
};
/// TODO: Move to a more fitting place.
pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,
};
/// TODO: Move to a more fitting place.
pub const Time = struct {
    hour: u8,
    minute: u8,
    second: u8,
    nano: ?u32 = null,
};

pub const State = enum {
    invalid,
    table,
    table_header,
    table_header_incomplete,
    key,
    key_incomplete,
    value_start,
};

pub fn init(input: []const u8, options: Options) Parser {
    return .{
        .tokenizer = .init(input, .{
            .toml_version = options.toml_version,
            .diagnostics = options.diagnostics,
        }),
        .features = .init(options.toml_version),
        .diagnostics = options.diagnostics,
    };
}

pub fn next(self: *Parser) Error!?Item {
    errdefer self.state = .invalid;
    errdefer self.token = null;

    var result: Item = .{
        .tag = undefined,
        .value = null,
    };

    state: switch (self.state) {
        .invalid => return self.fail(error.InvalidState, null),
        .table => {
            if (self.token == null) {
                self.token = self.token orelse try self.tokenizer.next();
            }

            switch (self.token.?.tag) {
                .end_of_file => {
                    self.token = null;
                    return null;
                },
                .newline => {
                    self.token = null;
                    continue :state .table;
                },
                .left_bracket => {
                    self.state = .table_header_incomplete;
                    self.token = null;
                    result.tag = .table_header_start;
                },
                .literal, .string, .literal_string => {
                    self.state = .key_incomplete;
                    continue :state .key_incomplete;
                },
                else => return self.fail(error.UnexpectedToken, null),
            }
        },
        .table_header, .table_header_incomplete => {
            if (self.token == null) {
                self.token = try self.tokenizer.next();
            }

            switch (self.token.?.tag) {
                .end_of_file => return self.fail(error.UnterminatedHeader, null),
                .dot => {
                    if (self.state == .table_header_incomplete) {
                        return self.fail(error.UnexpectedToken, null);
                    }
                    self.state = .table_header_incomplete;
                    self.token = null;
                    continue :state .table_header_incomplete;
                },
                .right_bracket => {
                    if (self.state == .table_header_incomplete) {
                        return self.fail(error.UnexpectedToken, null);
                    }
                    self.state = .table;
                    self.token = null;
                    result.tag = .table_header_end;
                },
                .literal => {
                    result.tag = .table_key;

                    const start = self.token.?.loc.start;

                    if (self.state == .table_header_incomplete and self.tokenizer.buffer[start] == '.') {
                        return self.fail(error.UnexpectedToken, null);
                    }

                    var end = start;

                    while (end < self.token.?.loc.end) : (end += 1) {
                        const c = self.tokenizer.buffer[end];
                        if (!isBareKey(c)) {
                            switch (c) {
                                '.' => {
                                    self.state = .table_header_incomplete;
                                    self.token.?.loc.start = end + 1;
                                    break;
                                },
                                else => return self.fail(error.InvalidCharacter, null),
                            }
                        }
                    }

                    if (end == self.token.?.loc.end or self.token.?.loc.start == self.token.?.loc.end) {
                        if (self.tokenizer.buffer[end] != '.') {
                            self.state = .table_header;
                        }
                        self.token = null;
                    }

                    result.value = .{ .literal = self.tokenizer.buffer[start..end] };
                },
                .string => {
                    self.state = .table_header;
                    result.tag = .table_key;
                    result.value = .{
                        .string = self.tokenizer.buffer[self.token.?.loc.start..self.token.?.loc.end],
                    };
                    self.token = null;
                },
                .literal_string => {
                    self.state = .table_header;
                    result.tag = .table_key;
                    result.value = .{
                        .literal_string = self.tokenizer.buffer[self.token.?.loc.start..self.token.?.loc.end],
                    };
                    self.token = null;
                },
                else => return self.fail(error.UnexpectedToken, "table header not terminated"),
            }
        },
        .key, .key_incomplete => {
            if (self.token == null) {
                self.token = try self.tokenizer.next();
            }

            switch (self.token.?.tag) {
                .end_of_file => return self.fail(error.UnexpectedEnd, null),
                .dot => {
                    if (self.state == .key_incomplete) {
                        return self.fail(error.UnexpectedToken, null);
                    }
                    self.state = .key_incomplete;
                    self.token = null;
                    continue :state .key_incomplete;
                },
                .equal => {
                    if (self.state == .key_incomplete) {
                        return self.fail(error.UnexpectedToken, null);
                    }
                    self.state = .value_start;
                    self.token = null;
                    continue :state .value_start;
                },
                .literal => {
                    result.tag = .key;

                    const start = self.token.?.loc.start;

                    if (self.state == .key_incomplete and self.tokenizer.buffer[start] == '.') {
                        return self.fail(error.UnexpectedToken, null);
                    }

                    var end = start;

                    while (end < self.token.?.loc.end) : (end += 1) {
                        const c = self.tokenizer.buffer[end];
                        if (!isBareKey(c)) {
                            switch (c) {
                                '.' => {
                                    self.state = .key_incomplete;
                                    self.token.?.loc.start = end + 1;
                                    break;
                                },
                                else => return self.fail(error.InvalidCharacter, null),
                            }
                        }
                    }

                    if (end == self.token.?.loc.end or self.token.?.loc.start == self.token.?.loc.end) {
                        if (self.tokenizer.buffer[end] != '.') {
                            self.state = .key;
                        }
                        self.token = null;
                    }

                    result.value = .{ .literal = self.tokenizer.buffer[start..end] };
                },
                .string => {
                    self.state = .key;
                    result.tag = .key;
                    result.value = .{
                        .string = self.tokenizer.buffer[self.token.?.loc.start..self.token.?.loc.end],
                    };
                    self.token = null;
                },
                .literal_string => {
                    self.state = .key;
                    result.tag = .key;
                    result.value = .{
                        .literal_string = self.tokenizer.buffer[self.token.?.loc.start..self.token.?.loc.end],
                    };
                    self.token = null;
                },
                else => return self.fail(error.UnexpectedToken, "key not terminated"),
            }
        },
        .value_start => {
            self.token = try self.tokenizer.next();

            switch (self.token.?.tag) {
                .string => {
                    self.state = .table;
                    result.tag = .value;
                    result.value = .{
                        .string = self.tokenizer.buffer[self.token.?.loc.start + 1 .. self.token.?.loc.end - 1],
                    };
                    self.token = null;
                },
                .multiline_string => {
                    self.state = .table;
                    result.tag = .value;
                    result.value = .{
                        .multiline_string = self.tokenizer.buffer[self.token.?.loc.start + 3 .. self.token.?.loc.end - 3],
                    };
                    self.token = null;
                },
                .literal_string => {
                    self.state = .table;
                    result.tag = .value;
                    result.value = .{
                        .literal_string = self.tokenizer.buffer[self.token.?.loc.start + 1 .. self.token.?.loc.end - 1],
                    };
                    self.token = null;
                },
                .multiline_literal_string => {
                    self.state = .table;
                    result.tag = .value;
                    result.value = .{
                        .multiline_literal_string = self.tokenizer.buffer[self.token.?.loc.start + 3 .. self.token.?.loc.end - 3],
                    };
                    self.token = null;
                },
                .literal => {
                    result.tag = .value;

                    var buf = self.tokenizer.buffer[self.token.?.loc.start..self.token.?.loc.end];
                    buf = std.mem.trim(u8, buf, " \t\r\n");

                    if (buf.len == 0) {
                        return self.fail(error.UnexpectedToken, null);
                    }

                    if (std.mem.eql(u8, buf, "true")) {
                        self.state = .table;
                        result.tag = .value;
                        result.value = .{ .boolean = true };
                        self.token = null;
                        break :state;
                    }

                    if (std.mem.eql(u8, buf, "false")) {
                        self.state = .table;
                        result.tag = .value;
                        result.value = .{ .boolean = false };
                        self.token = null;
                        break :state;
                    }

                    if (std.mem.eql(u8, buf, "inf") or std.mem.eql(u8, buf, "+inf")) {
                        self.state = .table;
                        result.tag = .value;
                        result.value = .{ .float = std.math.inf(Float) };
                        self.token = null;
                        break :state;
                    }

                    if (std.mem.eql(u8, buf, "-inf")) {
                        self.state = .table;
                        result.tag = .value;
                        result.value = .{ .float = -std.math.inf(Float) };
                        self.token = null;
                        break :state;
                    }

                    if (std.mem.eql(u8, buf, "nan") or std.mem.eql(u8, buf, "+nan")) {
                        self.state = .table;
                        result.tag = .value;
                        result.value = .{ .float = std.math.nan(Float) };
                        self.token = null;
                        break :state;
                    }

                    if (std.mem.eql(u8, buf, "-nan")) {
                        self.state = .table;
                        result.tag = .value;
                        result.value = .{ .float = -std.math.nan(Float) };
                        self.token = null;
                        break :state;
                    }

                    if (buf.len > 4 and
                        std.ascii.isDigit(buf[0]) and
                        std.ascii.isDigit(buf[1]) and
                        std.ascii.isDigit(buf[2]) and
                        std.ascii.isDigit(buf[3]) and
                        buf[4] == '-')
                    {
                        self.state = .table;
                        result.tag = .value;
                        result.value = self.parseDatetime(buf) catch |err| return switch (err) {
                            error.Reported => err,
                            else => self.fail(err, null),
                        };
                        break :state;
                    }

                    if (buf.len > 4 and
                        std.ascii.isDigit(buf[0]) and
                        std.ascii.isDigit(buf[1]) and
                        std.ascii.isDigit(buf[3]) and
                        std.ascii.isDigit(buf[4]) and
                        buf[2] == ':')
                    {
                        self.state = .table;
                        result.tag = .value;
                        result.value = self.parseTime(buf) catch |err| return switch (err) {
                            error.Reported => err,
                            else => self.fail(err, null),
                        };
                        break :state;
                    }

                    self.state = .table;
                    result.tag = .value;
                    result.value = self.parseNumber(buf) catch |err| return switch (err) {
                        error.Reported => err,
                        else => self.fail(err, null),
                    };

                    // break :state;
                },
                // TODO: inline array and table start.
                else => return self.fail(error.UnexpectedToken, null),
            }
        },
    }

    return result;
}

fn isBareKey(c: u8) bool {
    switch (c) {
        '-', '0'...'9', 'A'...'Z', '_', 'a'...'z' => return true,
        else => return false,
    }
}

fn parseDatetime(self: *Parser, s: []const u8) Error!Item.Value {
    var buf = s;

    if (buf.len < 10 or buf[7] != '-') {
        return self.fail(error.InvalidDatetime, null);
    }

    const year = parseDatetimeDigits(u16, 4, buf[0..4]) catch return self.fail(error.InvalidDatetime, null);
    const month = parseDatetimeDigits(u8, 2, buf[5..7]) catch return self.fail(error.InvalidDatetime, null);
    const day = parseDatetimeDigits(u8, 2, buf[8..10]) catch return self.fail(error.InvalidDatetime, null);

    // Due to how the tokenizer works, we need to check if the next token
    // continues the datetime.
    if (buf.len == 10) {
        self.token = try self.tokenizer.next();
        switch (self.token.?.tag) {
            .literal => { // continue datetime
                buf = std.mem.trim(u8, self.tokenizer.buffer[self.token.?.loc.start..self.token.?.loc.end], " \t\r\n");
            },
            else => {
                return .{
                    .local_date = .{
                        .year = year,
                        .month = month,
                        .day = day,
                    },
                };
            },
        }
    } else if (buf[10] == 'T' or buf[10] == 't') {
        // The length is guaranteed to be over 10 here.
        buf = buf[11..];
    } else {
        return self.fail(error.InvalidDatetime, null);
    }

    if (buf.len < 5 or buf[2] != ':') {
        return self.fail(error.InvalidDatetime, null);
    }

    const hour = parseDatetimeDigits(u8, 2, buf[0..2]) catch return self.fail(error.InvalidDatetime, null);
    const minute = parseDatetimeDigits(u8, 2, buf[3..5]) catch return self.fail(error.InvalidDatetime, null);
    const second = blk: {
        if (buf.len >= 8 and buf[5] == ':') {
            break :blk parseDatetimeDigits(u8, 2, buf[6..8]) catch return self.fail(error.InvalidDatetime, null);
        } else if (!self.features.optional_seconds) {
            return self.fail(error.InvalidDatetime, "missing seconds");
        }

        break :blk null;
    };

    buf = if (second == null) buf[5..] else buf[8..];

    const nano = blk: {
        if (buf.len > 1 and buf[0] == '.') {
            if (second == null) {
                return self.fail(error.InvalidDatetime, "no seconds before fraction");
            }

            buf = buf[1..];

            var n: u32 = 0;
            var i: usize = 0;
            while (i < buf.len and std.ascii.isDigit(buf[i]) and i < 9) : (i += 1) {
                n = n * 10 + (buf[i] - '0');
            }

            buf = buf[i..];

            while (i < 9) : (i += 1) {
                n *= 10;
            }

            break :blk n;
        }

        break :blk null;
    };
    const tz = blk: {
        if (buf.len == 0) {
            break :blk null;
        }
        if (buf.len == 1 and (buf[0] == 'Z' or buf[0] == 'z')) {
            break :blk 0;
        }
        if (buf.len == 6 and (buf[0] == '-' or buf[0] == '+') and buf[3] == ':') {
            const sign: i16 = if (buf[0] == '-') -1 else 1;
            const h: i16 = parseDatetimeDigits(u8, 2, buf[1..3]) catch return self.fail(error.InvalidDatetime, null);
            const m: i16 = parseDatetimeDigits(u8, 2, buf[4..6]) catch return self.fail(error.InvalidDatetime, null);
            if (h > 23 or m > 59) {
                return self.fail(error.InvalidDatetime, null);
            }
            break :blk sign * (h * 60 + m);
        }
        return self.fail(error.InvalidDatetime, "invalid timezone notation");
    };

    self.token = null;

    if (tz) |t| {
        return .{
            .datetime = .{
                .year = year,
                .month = month,
                .day = day,
                .hour = hour,
                .minute = minute,
                .second = second orelse 0,
                .nano = nano,
                .tz = t,
            },
        };
    }

    return .{
        .local_datetime = .{
            .year = year,
            .month = month,
            .day = day,
            .hour = hour,
            .minute = minute,
            .second = second orelse 0,
            .nano = nano,
            .tz = null,
        },
    };
}

fn parseTime(self: *Parser, s: []const u8) Error!Item.Value {
    var buf = s;

    const hour = parseDatetimeDigits(u8, 2, buf[0..2]) catch return self.fail(error.InvalidTime, null);
    const minute = parseDatetimeDigits(u8, 2, buf[3..5]) catch return self.fail(error.InvalidTime, null);
    const second = blk: {
        if (buf.len >= 8 and buf[5] == ':') {
            break :blk parseDatetimeDigits(u8, 2, buf[6..8]) catch return self.fail(error.InvalidTime, null);
        } else if (!self.features.optional_seconds) {
            return self.fail(error.InvalidTime, "missing seconds");
        }

        break :blk null;
    };

    buf = if (second == null) buf[5..] else buf[8..];

    const nano = blk: {
        if (buf.len > 1 and buf[0] == '.') {
            if (second == null) {
                return self.fail(error.InvalidTime, "no seconds before fraction");
            }

            buf = buf[1..];

            var n: u32 = 0;
            var i: usize = 0;
            while (i < buf.len and std.ascii.isDigit(buf[i]) and i < 9) : (i += 1) {
                n = n * 10 + (buf[i] - '0');
            }

            while (i < 9) : (i += 1) {
                n *= 10;
            }

            break :blk n;
        }

        break :blk null;
    };

    self.token = null;
    return .{
        .local_time = .{
            .hour = hour,
            .minute = minute,
            .second = second orelse 0,
            .nano = nano,
        },
    };
}

fn parseDatetimeDigits(comptime T: type, comptime n: usize, buffer: []const u8) error{ InvalidCharacter, Underflow }!T {
    comptime {
        if (n < 1) {
            @compileError("number of digits must be greater than 0");
        }

        const info = @typeInfo(T);
        if (info != .int or info.int.signedness != .unsigned) {
            @compileError("parseDatetimeDigits requires an unsigned integer type");
        }

        const max_digits = switch (T) {
            u8 => 2,
            u16 => 4,
            u32 => 9,
            else => @compileError("parseDatetimeDigits requires u8, u16, or u32"),
        };

        if (n > max_digits) {
            @compileError(std.fmt.comptimePrint("{s} is too small for {d} digits", .{ @typeName(T), n }));
        }
    }

    if (n > buffer.len) {
        return error.Underflow;
    }

    var result: T = 0;
    for (0..n) |i| {
        if (!std.ascii.isDigit(buffer[i])) {
            return error.InvalidCharacter;
        }

        result = result * 10 + @as(T, buffer[i] - '0');
    }

    return result;
}

fn parseNumber(self: *Parser, buf: []const u8) Error!Item.Value {
    if (buf.len == 0) {
        return self.fail(error.InvalidCharacter, "empty number literal");
    }

    var i: usize = 0;
    const sign: enum { pos, neg } = blk: {
        if (buf[0] == '+') {
            i += 1;
            break :blk .pos;
        }

        if (buf[0] == '-') {
            i += 1;
            break :blk .neg;
        }

        break :blk .pos;
    };

    // We can have the base as the right type right away to avoid casting it. We
    // control all of the types in this implementation so there is no risk of
    // invalid values.
    const base: Int = blk: {
        if (buf.len > i + 2 and buf[i] == '0') {
            switch (buf[i + 1]) {
                'b' => {
                    i += 2;
                    break :blk 2;
                },
                'o' => {
                    i += 2;
                    break :blk 8;
                },
                'x' => {
                    i += 2;
                    break :blk 16;
                },
                else => {},
            }
        }
        break :blk 10;
    };
    if (base != 10 and (buf[0] == '-' or buf[0] == '+')) {
        return self.fail(error.InvalidCharacter, null);
    }
    if (i >= buf.len) {
        return self.fail(error.InvalidCharacter, "missing digits after base prefix");
    }
    if (base == 10 and buf.len > i + 1 and buf[i] == '0' and std.ascii.isDigit(buf[i + 1])) {
        return self.fail(error.InvalidCharacter, "leading zeroes are not allowed");
    }
    if (buf[i] == '_' or buf[buf.len - 1] == '_') {
        return self.fail(error.InvalidCharacter, "number may not start or end with an underscore");
    }
    if (buf[i] == '.' or buf[buf.len - 1] == '.') {
        return self.fail(error.InvalidCharacter, "number may not start or end with a decimal separator");
    }

    var int: Int = 0;
    var float_found = false;
    var underscore = false;
    for (buf[i..]) |c| {
        if (c == '_') {
            if (underscore) {
                return self.fail(error.InvalidCharacter, "two consecutive underscores");
            }
            i += 1;
            underscore = true;
            continue;
        }

        underscore = false;

        if (c == '.') {
            float_found = true;
            break;
        }

        if (base == 10 and (c == 'E' or c == 'e')) {
            float_found = true;
            break;
        }

        i += 1;

        const digit: Int = switch (c) {
            '0'...'9' => c - '0',
            'A'...'F' => c - 'A' + 10,
            'a'...'f' => c - 'a' + 10,
            else => return self.fail(error.InvalidCharacter, null),
        };
        if (digit >= base) {
            return self.fail(error.InvalidCharacter, null);
        }

        if (int != 0) {
            int = std.math.mul(Int, int, base) catch return self.fail(error.Overflow, null);
        } else if (sign == .neg) {
            int = -digit;
            continue;
        }

        const ov = switch (sign) {
            .pos => @addWithOverflow(int, digit),
            .neg => @subWithOverflow(int, digit),
        };
        if (ov[1] != 0) {
            return self.fail(error.Overflow, null);
        }
        int = ov[0];
    }

    if (!float_found) {
        self.token = null;
        return .{ .int = int };
    }

    if (base != 10) {
        return self.fail(error.InvalidCharacter, "floating-point values may only be decimal");
    }

    // Just parse the full string again. Otherwise, we'd risk losing precision
    // over probably negligible performance gains.
    return .{ .float = std.fmt.parseFloat(Float, buf) catch |err| return self.fail(err, null) };
}

fn fail(self: Parser, err: Error, msg: ?[]const u8) Error {
    assert(err != error.Reported);

    if (self.diagnostics) |diag| {
        diag.* = .{
            .position = self.tokenizer.position(),
            .message = if (msg) |m| m else switch (err) {
                error.InvalidCharacter => "invalid character",
                error.InvalidControlCharacter => "invalid control character",
                error.InvalidDatetime => "invalid datetime",
                error.InvalidEscapeSequence => "invalid escape sequence",
                error.InvalidState => "invalid parser state",
                error.InvalidTime => "invalid local time",
                error.InvalidUtf8 => "invalid UTF-8 sequence",
                error.Overflow => "integer overflow",
                error.UnexpectedEnd => "unexpected end of input",
                error.UnexpectedToken => "unexpected token",
                error.UnterminatedHeader => "unterminated table header",
                error.UnterminatedString => "unterminated string literal",
                error.Reported => unreachable,
            },
        };

        return error.Reported;
    }

    return err;
}

test {
    _ = @import("Parser/test.zig");
}
