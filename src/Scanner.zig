const Scanner = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ascii = std.ascii;
const assert = std.debug.assert;
const mem = std.mem;

const Date = @import("value.zig").Date;
const Datetime = @import("value.zig").Datetime;
const Position = @import("decoder.zig").Position;
const Time = @import("value.zig").Time;

arena: Allocator,
input: []const u8 = "",
cursor: usize = 0,
end: usize = 0,
line: u64 = 0,

/// Constant that marks the end of input when scanning for the next character.
const end_of_input: u8 = 0;

var stderr_buffer: [4096]u8 = undefined;

pub const Token = union(enum) {
    dot,
    equal,
    comma,
    left_bracket, // [
    double_left_bracket, // [[
    right_bracket, // ]
    double_right_bracket, // ]]
    left_brace, // {
    right_brace, // }

    literal: []const u8,
    string: []const u8,
    multiline_string: []const u8,
    literal_string: []const u8,
    multiline_literal_string: []const u8,

    int: i64,
    float: f64,
    bool: bool,

    datetime: Datetime,
    local_datetime: Datetime,
    local_date: Date,
    local_time: Time,

    line_feed,
    end_of_file,
};

pub fn initCompleteInput(self: *Scanner, arena: Allocator, input: []const u8) void {
    self.* = .{
        .arena = arena,
        .input = input,
        .end = input.len,
    };
}

pub fn nextKey(self: *Scanner) !Token {
    assert(self.cursor <= self.end);

    return self.next(true);
}

pub fn nextValue(self: *Scanner) !Token {
    assert(self.cursor <= self.end);

    return self.next(false);
}

fn isValidChar(c: u8) bool {
    return ascii.isPrint(c) or (c & 0x80) != 0;
}

fn match(self: *const Scanner, c: u8) bool {
    if (self.cursor < self.end and self.input[self.cursor] == c) {
        return true;
    }

    if (c == '\n' and self.cursor + 1 < self.end) {
        return self.input[self.cursor] == '\r' and self.input[self.cursor + 1] == '\n';
    }

    return false;
}

fn matchAny(self: *const Scanner, s: []const u8) bool {
    for (s) |c| {
        if (self.match(c)) {
            return true;
        }
    }

    return false;
}

fn matchN(self: *const Scanner, c: u8, n: comptime_int) bool {
    if (n < 2) {
        @compileError("calling Scanner.matchN with n < 2");
    }

    assert(c != '\n');

    if (self.cursor + n >= self.end) {
        return false;
    }

    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (self.input[self.cursor + i] != c) {
            return false;
        }
    }

    return true;
}

fn matchTime(self: *const Scanner) bool {
    return self.cursor + 2 < self.end and ascii.isDigit(self.input[self.cursor]) and
        ascii.isDigit(self.input[self.cursor + 1]) and self.input[self.cursor + 2] == ':';
}

fn matchDate(self: *const Scanner) bool {
    return self.cursor + 4 < self.end and ascii.isDigit(self.input[self.cursor]) and
        ascii.isDigit(self.input[self.cursor + 1]) and
        ascii.isDigit(self.input[self.cursor + 2]) and
        ascii.isDigit(self.input[self.cursor + 3]) and
        self.input[self.cursor + 4] == '-';
}

fn matchBool(self: *const Scanner) bool {
    return self.cursor < self.end and
        (self.input[self.cursor] == 't' or self.input[self.cursor] == 'f');
}

fn matchNumber(self: *const Scanner) bool {
    if (self.cursor < self.end and
        mem.indexOfScalar(u8, "0123456789+-._", self.input[self.cursor]) != null)
    {
        return true;
    }

    if (self.cursor + 2 < self.end) {
        if (mem.eql(u8, "nan", self.input[self.cursor .. self.cursor + 3]) or
            mem.eql(u8, "inf", self.input[self.cursor .. self.cursor + 3]))
        {
            return true;
        }
    }

    return false;
}

/// Get the next character in the input. It returns '\0' when it finds the end
/// of input regardless of whether the input is null-terminated.
fn nextChar(self: *Scanner) u8 {
    assert(self.cursor <= self.end);

    var ret: u8 = end_of_input;

    if (self.cursor < self.end) {
        ret = self.input[self.cursor];
        self.cursor += 1;

        if (ret == '\r' and self.cursor < self.end and self.input[self.cursor] == '\n') {
            ret = self.input[self.cursor];
            self.cursor += 1;
        }
    }

    if (ret == '\n') {
        self.line += 1;
    }

    return ret;
}

fn next(self: *Scanner, comptime key_mode: bool) !Token {
    assert(self.cursor <= self.end);

    while (self.cursor < self.end) {
        var c = self.nextChar();

        switch (c) {
            '\n' => return .line_feed,

            ' ', '\t' => continue, // skip whitespace

            '#' => {
                while (!self.match('\n')) {
                    c = self.nextChar();
                    if (c == end_of_input and self.cursor >= self.end) {
                        break;
                    }

                    switch (c) {
                        0...8, 0x0a...0x1f, 0x7f => {
                            return self.fail("invalid control character in comment");
                        },
                        else => {},
                    }
                }

                continue; // skip comment
            },

            '.' => return .dot,
            '=' => return .equal,
            ',' => return .comma,

            '[' => {
                if (key_mode and self.match('[')) {
                    _ = self.nextChar();
                    return .double_left_bracket;
                }

                return .left_bracket;
            },

            ']' => {
                if (key_mode and self.match(']')) {
                    _ = self.nextChar();
                    return .double_right_bracket;
                }

                return .right_bracket;
            },

            '{' => return .left_brace,
            '}' => return .right_brace,

            '"' => {
                // Move back so that `scanString` finds the first quote.
                self.cursor -= 1;
                return self.scanString();
            },
            '\'' => {
                self.cursor -= 1;
                return self.scanLiteralString();
            },

            else => {
                // Disallow unprintable control characters outside strings/comments
                if ((c <= 8) or (c >= 0x0a and c <= 0x1f) or c == 0x7f) {
                    return self.fail("invalid control character in document");
                }

                self.cursor -= 1;
                return if (key_mode) self.scanLiteral() else self.scanNonstringLiteral();
            },
        }
    }

    return .end_of_file;
}

fn scanMultilineString(self: *Scanner) !Token {
    assert(self.matchN('"', 3));

    // Skip the opening quotes.
    _ = self.nextChar();
    _ = self.nextChar();
    _ = self.nextChar();

    // Trim the first newline after opening the multiline string.
    if (self.match('\n')) {
        _ = self.nextChar();
    }

    const start = self.cursor;

    while (self.cursor < self.end) { // force upper limit to loop
        if (self.matchN('"', 3)) {
            if (self.matchN('"', 4)) {
                if (self.matchN('"', 6)) {
                    return self.fail("invalid triple quote sequence in multiline string");
                }
            } else {
                break;
            }
        }

        var c = self.nextChar();

        if (c == end_of_input) {
            return self.fail("unterminated multiline string");
        }

        if (c != '\\') {
            if (!(isValidChar(c) or mem.indexOfScalar(u8, " \t\n", c) != null)) {
                return self.fail("invalid character in multiline string");
            }

            continue;
        }

        c = self.nextChar();
        if (mem.indexOfScalar(u8, "\"\\bfnrt", c) != null) {
            continue; // skip the "normal" escape sequences
        }

        if (c == 'u' or c == 'U') {
            const len: usize = if (c == 'u') 4 else 8;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (!ascii.isHex(self.nextChar())) {
                    return self.fail("invalid unicode escape in string");
                }
            }

            continue;
        }

        if (c == ' ' or c == '\t') {
            while (c != end_of_input and (c == ' ' or c == '\t')) {
                c = self.nextChar();
            }

            if (c != '\n') {
                return self.fail("backslash line continuation must be followed by newline");
            }
        }

        if (c == '\n') {
            while (self.matchAny(" \t\n")) {
                _ = self.nextChar();
            }

            continue;
        }

        return self.fail("invalid escape sequence in multiline string");
    }

    const result: Token = .{ .multiline_string = self.input[start..self.cursor] };

    if (!self.matchN('"', 3)) {
        return self.fail("unterminated multiline string");
    }

    _ = self.nextChar();
    _ = self.nextChar();
    _ = self.nextChar();

    return result;
}

fn scanString(self: *Scanner) !Token {
    assert(self.match('"'));

    if (self.matchN('"', 3)) {
        return self.scanMultilineString();
    }

    _ = self.nextChar(); // skip the opening quote
    const start = self.cursor;

    while (!self.match('"')) {
        var c = self.nextChar();
        if (c == end_of_input) {
            return self.fail("unterminated string");
        }

        if (c != '\\') {
            if (!(isValidChar(c) or c == ' ' or c == '\t')) {
                return self.fail("unexpected token");
            }

            continue;
        }

        c = self.nextChar();
        if (mem.indexOfScalar(u8, "\"\\bfnrt", c) != null) {
            continue; // skip the "normal" escape sequences
        }

        if (c == 'u' or c == 'U') {
            const len: usize = if (c == 'u') 4 else 8;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (!ascii.isHex(self.nextChar())) {
                    return self.fail("invalid Unicode escape sequence in string");
                }
            }

            continue;
        }

        return self.fail("invalid escape sequence in string");
    }

    const result: Token = .{ .string = self.input[start..self.cursor] };

    assert(self.match('"'));
    _ = self.nextChar();

    return result;
}

fn scanMultilineLiteralString(self: *Scanner) !Token {
    assert(self.matchN('\'', 3));

    _ = self.nextChar();
    _ = self.nextChar();
    _ = self.nextChar();

    if (self.match('\n')) {
        _ = self.nextChar();
    }

    const start = self.cursor;

    while (self.cursor < self.end) { // force upper limit to loop
        if (self.matchN('\'', 3)) {
            if (self.matchN('\'', 4)) {
                if (self.matchN('\'', 6)) {
                    return self.fail("unexpected token");
                }
            } else {
                break;
            }
        }

        const c = self.nextChar();

        if (c == end_of_input) {
            return self.fail("unterminated multiline literal string");
        }

        if (!(isValidChar(c) or mem.indexOfScalar(u8, " \t\n", c) != null)) {
            return self.fail("invalid character in multiline literal string");
        }
    }

    const result: Token = .{ .multiline_literal_string = self.input[start..self.cursor] };

    if (!self.matchN('\'', 3)) {
        return self.fail("unterminated multiline literal string");
    }

    _ = self.nextChar();
    _ = self.nextChar();
    _ = self.nextChar();

    return result;
}

fn scanLiteralString(self: *Scanner) !Token {
    assert(self.match('\''));

    if (self.matchN('\'', 3)) {
        return self.scanMultilineLiteralString();
    }

    _ = self.nextChar(); // skip the opening quote
    const start = self.cursor;

    while (!self.match('\'')) {
        const c = self.nextChar();
        if (c == end_of_input) {
            return self.fail("unterminated literal string");
        }

        if (!(isValidChar(c) or c == '\t')) {
            return self.fail("invalid character in literal string");
        }
    }

    const result: Token = .{ .literal_string = self.input[start..self.cursor] };

    assert(self.match('\''));

    _ = self.nextChar();

    return result;
}

fn scanNonstringLiteral(self: *Scanner) !Token {
    if (self.matchTime()) {
        return self.scanTime();
    }

    if (self.matchDate()) {
        return self.scanDatetime();
    }

    if (self.matchBool()) {
        return self.scanBool();
    }

    if (self.matchNumber()) {
        return self.scanNumber();
    }

    return self.fail("expected a number, date, time, or datetime, or boolean");
}

fn scanLiteral(self: *Scanner) Token {
    const start = self.cursor;
    while (self.cursor < self.end and (ascii.isAlphanumeric(self.input[self.cursor]) or
        self.input[self.cursor] == '_' or self.input[self.cursor] == '-')) : (self.cursor += 1)
    {}
    return .{ .literal = self.input[start..self.cursor] };
}

fn readInt(self: *Scanner, comptime T: type) T {
    var val: T = 0;
    while (ascii.isDigit(self.input[self.cursor])) : (self.cursor += 1) {
        val = val * 10 + @as(T, @intCast(self.input[self.cursor] - '0'));
    }
    return val;
}

fn readFixedDigits(self: *Scanner, comptime N: usize) !u32 {
    if (self.cursor + N > self.end) {
        return self.fail("unexpected end of input");
    }

    var v: u32 = 0;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const c = self.input[self.cursor + i];
        if (!ascii.isDigit(c)) {
            return self.fail("expected digit");
        }

        v = v * 10 + (c - '0');
    }

    self.cursor += N;

    return v;
}

fn readTime(self: *Scanner) !Time {
    var ret: Time = .{ .hour = undefined, .minute = undefined, .second = undefined };
    ret.hour = @intCast(try self.readFixedDigits(2));
    if (self.cursor >= self.end or self.input[self.cursor] != ':') {
        return self.fail("invalid time: expected ':' between hour and minute");
    }

    self.cursor += 1;
    ret.minute = @intCast(try self.readFixedDigits(2));
    if (self.cursor >= self.end or self.input[self.cursor] != ':') {
        return self.fail("invalid time: expected ':' between minute and second");
    }

    self.cursor += 1;
    ret.second = @intCast(try self.readFixedDigits(2));
    if (ret.hour > 23 or ret.minute > 59 or ret.second > 59) {
        return self.fail("invalid time value");
    }

    if (self.cursor >= self.end or self.input[self.cursor] != '.') {
        return ret;
    }

    self.cursor += 1;
    ret.nano = 0;
    var i: usize = 0;
    while (self.cursor < self.end and
        ascii.isDigit(self.input[self.cursor]) and i < 9) : (self.cursor += 1)
    {
        ret.nano = ret.nano.? * 10 + (self.input[self.cursor] - '0');
        i += 1;
    }

    while (i < 9) : (i += 1) {
        ret.nano = ret.nano.? * 10;
    }

    return ret;
}

fn readDate(self: *Scanner) !Date {
    var ret: Date = .{ .year = undefined, .month = undefined, .day = undefined };
    ret.year = @intCast(try self.readFixedDigits(4));
    if (self.cursor >= self.end or self.input[self.cursor] != '-') {
        return self.fail("invalid date: expected '-' after year");
    }

    self.cursor += 1;
    ret.month = @intCast(try self.readFixedDigits(2));
    if (self.cursor >= self.end or self.input[self.cursor] != '-') {
        return self.fail("invalid date: expected '-' after month");
    }

    self.cursor += 1;
    ret.day = @intCast(try self.readFixedDigits(2));

    return ret;
}

fn readTimezone(self: *Scanner) !?i16 {
    const c = self.input[self.cursor];
    if (c == 'Z' or c == 'z') {
        self.cursor += 1;
        return 0; // UTC+00:00
    }

    const sign: i16 = switch (c) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };

    self.cursor += 1;

    const hour: i16 = @intCast(try self.readFixedDigits(2));
    if (self.cursor >= self.end or self.input[self.cursor] != ':') {
        return self.fail("invalid timezone offset: expected ':' between hour and minute");
    }

    self.cursor += 1;
    const minute: i16 = @intCast(try self.readFixedDigits(2));
    if (hour > 23 or minute > 59) {
        return self.fail("invalid timezone offset value");
    }

    return (hour * 60 + minute) * sign;
}

fn scanTime(self: *Scanner) !Token {
    const t = try self.readTime();
    if (!t.isValid()) {
        return self.fail("invalid time literal");
    }

    return .{ .local_time = t };
}

fn scanDatetime(self: *Scanner) !Token {
    if (self.cursor + 2 >= self.end) {
        return self.fail("unterminated datetime");
    }

    if (ascii.isDigit(self.input[self.cursor]) and
        ascii.isDigit(self.input[self.cursor + 1]) and self.input[self.cursor + 2] == ':')
    {
        const t = try self.readTime();
        if (!t.isValid()) {
            return self.fail("invalid time literal");
        }

        return .{ .local_time = t };
    }

    const date = try self.readDate();
    const c = self.input[self.cursor];
    if (self.cursor + 3 >= self.end or (c != 'T' and c != 't' and c != ' ') or
        !ascii.isDigit(self.input[self.cursor + 1]) or
        !ascii.isDigit(self.input[self.cursor + 2]) or self.input[self.cursor + 3] != ':')
    {
        if (!date.isValid()) {
            return self.fail("invalid date literal");
        }

        return .{ .local_date = date };
    }

    self.cursor += 1;
    const time = try self.readTime();
    var dt: Datetime = .{
        .year = date.year,
        .month = date.month,
        .day = date.day,
        .hour = time.hour,
        .minute = time.minute,
        .second = time.second,
        .nano = time.nano,
    };

    const tz = try self.readTimezone();
    if (tz == null) {
        if (!dt.isValid()) {
            return self.fail("invalid datetime value");
        }

        return .{ .local_datetime = dt };
    }

    dt.tz = tz;
    if (!dt.isValid()) {
        return self.fail("invalid datetime value");
    }

    return .{ .datetime = dt };
}

fn scanBool(self: *Scanner) !Token {
    var val: bool = undefined;
    if (self.cursor + 3 < self.end and
        mem.eql(u8, "true", self.input[self.cursor .. self.cursor + 4]))
    {
        val = true;
        self.cursor += 4;
    } else if (self.cursor + 4 < self.end and
        mem.eql(u8, "false", self.input[self.cursor .. self.cursor + 5]))
    {
        val = false;
        self.cursor += 5;
    } else {
        return self.fail("unexpected token");
    }

    if (self.cursor < self.end and
        null == mem.indexOfScalar(u8, "# \r\n\t,}]", self.input[self.cursor]))
    {
        return self.fail("invalid trailing characters after boolean literal");
    }

    return .{ .bool = val };
}

fn scanNumber(self: *Scanner) !Token {
    if (self.input[self.cursor] == '0' and self.cursor + 1 < self.end) {
        const base: ?u8 = switch (self.input[self.cursor + 1]) {
            'x' => 16,
            'o' => 8,
            'b' => 2,
            else => null,
        };
        if (base) |b| {
            self.cursor += 2;
            const start = self.cursor;
            const allowed: []const u8 = switch (b) {
                16 => "_0123456789abcdefABCDEF",
                8 => "_01234567",
                2 => "_01",
                else => unreachable,
            };

            const end_idx = mem.indexOfNonePos(u8, self.input, start, allowed) orelse {
                return self.fail("invalid digits for base-prefixed integer");
            };

            if (end_idx == start) {
                return self.fail("missing digits after base prefix");
            }

            var prev_underscore = false;
            var i: usize = start;
            while (i < end_idx) : (i += 1) {
                const c = self.input[i];
                if (c == '_') {
                    if (prev_underscore or i == start or i + 1 == end_idx) {
                        return self.fail("invalid underscore placement in number");
                    }

                    prev_underscore = true;
                } else {
                    prev_underscore = false;
                }
            }

            var buf: ArrayList(u8) = .empty;
            defer buf.deinit(self.arena);

            i = start;
            while (i < end_idx) : (i += 1) {
                const c = self.input[i];
                if (c != '_') {
                    try buf.append(self.arena, c);
                }
            }

            const n = try std.fmt.parseInt(i64, buf.items, b);
            self.cursor = end_idx;

            return .{ .int = n };
        }
    }

    // Decimal or float.
    const start = self.cursor;
    var idx = self.cursor;
    if (self.input[idx] == '+' or self.input[idx] == '-') {
        idx += 1;
    }

    if (idx >= self.end) {
        return self.fail("unexpected end of input while reading number");
    }

    if (self.input[idx] == 'i' or self.input[idx] == 'n') {
        return self.scanFloat();
    }

    // Find token end.
    idx = mem.indexOfNonePos(u8, self.input, self.cursor, "_0123456789eE.+-") orelse {
        return self.fail("malformed number literal");
    };

    if (idx == start) {
        return self.fail("missing digits in number");
    }

    const slice = self.input[start..idx];
    const has_dot = mem.indexOfScalar(u8, slice, '.') != null;
    const has_exp = mem.indexOfAny(u8, slice, "eE") != null;

    if (has_dot or has_exp) {
        return self.scanFloat();
    }

    // Validate underscores and leading zero rule.
    var s_off: usize = 0;
    if (slice[0] == '+' or slice[0] == '-') {
        s_off = 1;
    }

    if (slice[s_off] == '0' and slice.len > s_off + 1) {
        return self.fail("leading zeros are not allowed in integers");
    }

    var prev_underscore = false;

    var j: usize = s_off;
    while (j < slice.len) : (j += 1) {
        const c = slice[j];
        if (c == '_') {
            if (prev_underscore or j == s_off or j + 1 == slice.len) {
                return self.fail("invalid underscore placement in number");
            }

            prev_underscore = true;
        } else if (!ascii.isDigit(c)) {
            return self.fail("invalid character in integer literal");
        } else {
            prev_underscore = false;
        }
    }

    var buf: ArrayList(u8) = .empty;
    defer buf.deinit(self.arena);

    j = 0;
    while (j < slice.len) : (j += 1) {
        const c = slice[j];
        if (c != '_') {
            try buf.append(self.arena, c);
        }
    }

    const n = try std.fmt.parseInt(i64, buf.items, 10);
    self.cursor = idx;

    return .{ .int = n };
}

fn scanFloat(self: *Scanner) !Token {
    const start = self.cursor;
    if (self.input[self.cursor] == '+' or self.input[self.cursor] == '-') {
        self.cursor += 1;
    }

    if (self.cursor + 3 <= self.end and
        (mem.eql(u8, self.input[self.cursor .. self.cursor + 3], "inf") or
            mem.eql(u8, self.input[self.cursor .. self.cursor + 3], "nan")))
    {
        self.cursor += 3;
    } else {
        self.cursor = mem.indexOfNonePos(u8, self.input, self.cursor, "_0123456789eE.+-") orelse {
            return self.fail("malformed float literal");
        };
    }

    const slice = self.input[start..self.cursor];

    // Validate underscores not at ends or adjacent to dot or exponent signs.
    var prev_char: u8 = 0;

    var i: usize = 0;
    while (i < slice.len) : (i += 1) {
        const c = slice[i];
        if (c == '_') {
            if (i == 0 or i + 1 == slice.len) {
                return self.fail("invalid underscore placement in float literal");
            }

            const nxt = slice[i + 1];
            if (!ascii.isDigit(prev_char) or !ascii.isDigit(nxt)) {
                return self.fail("invalid underscore placement in float literal");
            }
        }
        prev_char = c;
    }

    var buf: ArrayList(u8) = .empty;
    defer buf.deinit(self.arena);

    i = 0;
    while (i < slice.len) : (i += 1) {
        const c = slice[i];
        if (c != '_') {
            try buf.append(self.arena, c);
        }
    }

    // Reject leading zero before decimal point (e.g. 03.14) per TOML.
    if (buf.items.len >= 2) {
        var sign_idx: usize = 0;
        if (buf.items[0] == '+' or buf.items[0] == '-') {
            sign_idx = 1;
        }

        if (buf.items[sign_idx] == '0' and buf.items.len > sign_idx + 1 and
            buf.items[sign_idx + 1] == '.')
        {
            // ok: 0.xxx
        } else if (buf.items[sign_idx] == '0' and buf.items.len > sign_idx + 1 and
            ascii.isDigit(buf.items[sign_idx + 1]))
        {
            return self.fail("leading zeros are not allowed in float literal");
        }
    }

    // Disallow floats like 1., .1, or exponents with missing mantissa per TOML.
    if (mem.indexOfScalar(u8, buf.items, '.') != null) {
        // Must have digits on both sides of '.'.
        const dot_idx = mem.indexOfScalar(u8, buf.items, '.').?;
        if (dot_idx == 0 or dot_idx + 1 >= buf.items.len) {
            return self.fail("decimal point must have digits on both sides");
        }

        if (!ascii.isDigit(buf.items[dot_idx - 1]) or !ascii.isDigit(buf.items[dot_idx + 1])) {
            return self.fail("decimal point must have digits on both sides");
        }
    }

    // Validate exponent placement: must have digits before and after 'e' or 'E'
    // (with optional sign).
    if (mem.indexOfAny(u8, buf.items, "eE")) |e_idx| {
        if (e_idx == 0) {
            return self.fail("invalid exponent format");
        }

        if (!ascii.isDigit(buf.items[e_idx - 1]) and buf.items[e_idx - 1] != '.') {
            return self.fail("invalid exponent format");
        }

        var after = e_idx + 1;
        if (after < buf.items.len and (buf.items[after] == '+' or buf.items[after] == '-')) {
            after += 1;
        }

        if (after >= buf.items.len or !ascii.isDigit(buf.items[after])) {
            return self.fail("invalid exponent format");
        }
    }

    const f = try std.fmt.parseFloat(f64, buf.items);

    return .{ .float = f };
}

fn checkNumberStr(self: *Scanner, len: usize, base: u8) bool {
    const start = self.cursor;
    const underscore = mem.indexOfScalarPos(u8, self.input, self.cursor, '_');
    if (underscore) |u| {
        var i: usize = u - start;
        while (i < len) : (i += 1) {
            if (self.input[self.cursor + i] != '_') {
                continue;
            }

            const left: u8 = if (i == 0) 0 else self.input[self.cursor + i - 1];
            const right: u8 = if (self.cursor + i >= self.end)
                0
            else
                self.input[self.cursor + i + 1];

            if (!ascii.isDigit(left) and !(base == 16 and ascii.isHex(left))) {
                return false;
            }

            if (!ascii.isHex(right) and !(base == 16 and ascii.isHex(right))) {
                return false;
            }
        }
    }

    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (self.input[self.cursor + i] == '.') {
            if (i == 0 or !ascii.isDigit(self.input[self.cursor - 1]) or
                !ascii.isDigit(self.input[self.cursor + 1]))
            {
                return false;
            }
        }
    }

    if (base == 10) {
        i = if (self.input[self.cursor] == '+' or self.input[self.cursor] == '-')
            self.cursor + 1
        else
            self.cursor;

        if (self.input[i] == '0' and ascii.isDigit(self.input[i + 1])) {
            return false;
        }

        if (mem.indexOfScalarPos(u8, self.input, self.cursor, 'e')) |idx| {
            i = if (self.input[idx] == '+' or self.input[idx] == '-') idx + 1 else idx;
            if (self.input[i] == '0' and ascii.isDigit(self.input[i + 1])) {
                return false;
            }
        } else if (mem.indexOfScalarPos(u8, self.input, self.cursor, 'E')) |idx| {
            i = if (self.input[idx] == '+' or self.input[idx] == '-') idx + 1 else idx;
            if (self.input[i] == '0' and ascii.isDigit(self.input[i + 1])) {
                return false;
            }
        }
    }

    return true;
}

fn fail(self: *const Scanner, msg: []const u8) error{ Reported, WriteFailed } {
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    try stderr.print("{f}", .{Position.findLineKnown(self.input, self.cursor, self.line)});
    try stderr.writeByte(' ');
    try stderr.writeAll(msg);
    try stderr.writeByte('\n');
    try stderr.flush();

    return error.Reported;
}
