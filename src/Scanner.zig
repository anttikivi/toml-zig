//! The parsing API that emits tokens based on the TOML document input.
//!
//! TODO: Consider implementing streaming so that we can parse TOML documents
//! with smaller memory footprint.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ascii = std.ascii;
const assert = std.debug.assert;
const mem = std.mem;

const Date = @import("value.zig").Date;
const Datetime = @import("value.zig").Datetime;
const Time = @import("value.zig").Time;

allocator: Allocator,
input: []const u8 = "",
cursor: usize = 0,
end: usize = 0,
line: u64 = 0,

/// Last error message set by scanning/parsing routines for diagnostics.
last_error_message: ?[]const u8 = null,

/// Internal buffer for formatted error messages.
err_buf: [256]u8 = undefined,
err_len: usize = 0,

/// Constant that marks the end of input when scanning for the next character.
const end_of_input: u8 = 0;

/// Represents a token in the TOML document.
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

/// Initialize a `Scanner` with the complete TOML document input as a single
/// slice.
pub fn initCompleteInput(arena: Allocator, input: []const u8) @This() {
    return .{
        .allocator = arena,
        .input = input,
        .end = input.len,
    };
}

/// Get the next token in the TOML document with the key mode enabled.
pub fn nextKey(self: *@This()) !Token {
    return self.next(true);
}

/// Get the next token in the TOML document with the key mode disabled.
pub fn nextValue(self: *@This()) !Token {
    return self.next(false);
}

pub inline fn setErrorMessage(self: *@This(), msg: []const u8) void {
    self.last_error_message = msg;
}

inline fn setErrorMessageFmt(self: *@This(), comptime fmt_str: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(&self.err_buf, fmt_str, args) catch {
        self.last_error_message = fmt_str;
        return;
    };

    self.err_len = written.len;
    self.last_error_message = self.err_buf[0..self.err_len];
}

fn isValidChar(c: u8) bool {
    return ascii.isPrint(c) or (c & 0x80) != 0;
}

/// Check if the next character matches c.
fn match(self: *const @This(), c: u8) bool {
    if (self.cursor < self.end and self.input[self.cursor] == c) {
        return true;
    }

    if (c == '\n' and self.cursor + 1 < self.end) {
        return self.input[self.cursor] == '\r' and self.input[self.cursor + 1] == '\n';
    }

    return false;
}

/// Check if the next character matches any of the characters in s.
fn matchAny(self: *const @This(), s: []const u8) bool {
    for (s) |c| {
        if (self.match(c)) {
            return true;
        }
    }

    return false;
}

/// Check if the next n characters match c.
fn matchN(self: *const @This(), c: u8, n: comptime_int) bool {
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

/// Check if the next token might be a time.
fn matchTime(self: *const @This()) bool {
    return self.cursor + 2 < self.end and ascii.isDigit(self.input[self.cursor]) and
        ascii.isDigit(self.input[self.cursor + 1]) and self.input[self.cursor + 2] == ':';
}

/// Check if the next token might be a date.
fn matchDate(self: *const @This()) bool {
    return self.cursor + 4 < self.end and ascii.isDigit(self.input[self.cursor]) and
        ascii.isDigit(self.input[self.cursor + 1]) and
        ascii.isDigit(self.input[self.cursor + 2]) and
        ascii.isDigit(self.input[self.cursor + 3]) and
        self.input[self.cursor + 4] == '-';
}

/// Check if the next token might be a boolean literal.
fn matchBool(self: *const @This()) bool {
    return self.cursor < self.end and
        (self.input[self.cursor] == 't' or self.input[self.cursor] == 'f');
}

/// Check if the next token might be some number literal.
fn matchNumber(self: *const @This()) bool {
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

/// Get the next character in the input. It returns '\0' when it finds
/// the end of input regardless of whether the input is null-terminated.
fn nextChar(self: *@This()) u8 {
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

/// Get the next token from the input.
fn next(self: *@This(), comptime key_mode: bool) !Token {
    // Limit the loop to the maximum length of the input even though we
    // basically loop until we find a return value.
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
                            self.setErrorMessage("invalid control character in comment");
                            return error.InvalidCharacter;
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
                    self.setErrorMessage("invalid control character in document");
                    return error.InvalidCharacter;
                }
                self.cursor -= 1;
                return if (key_mode) self.scanLiteral() else self.scanNonstringLiteral();
            },
        }
    }

    return .end_of_file;
}

/// Scan the upcoming multiline string in the TOML document and return
/// a token matching it.
fn scanMultilineString(self: *@This()) !Token {
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
                    self.setErrorMessage("invalid triple quote sequence in multiline string");
                    return error.UnexpectedToken;
                }
            } else {
                break;
            }
        }

        var c = self.nextChar();

        if (c == end_of_input) {
            self.setErrorMessage("unterminated multiline string");
            return error.UnexpectedEndOfInput;
        }

        if (c != '\\') {
            if (!(isValidChar(c) or mem.indexOfScalar(u8, " \t\n", c) != null)) {
                self.setErrorMessage("invalid character in multiline string");
                return error.UnexpectedToken;
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
                    self.setErrorMessage("invalid unicode escape in string");
                    return error.UnexpectedToken;
                }
            }
            continue;
        }

        if (c == ' ' or c == '\t') {
            while (c != end_of_input and (c == ' ' or c == '\t')) {
                c = self.nextChar();
            }

            if (c != '\n') {
                self.setErrorMessage("backslash line continuation must be followed by newline");
                return error.UnexpectedToken;
            }
        }

        if (c == '\n') {
            while (self.matchAny(" \t\n")) {
                _ = self.nextChar();
            }
            continue;
        }

        self.setErrorMessage("invalid escape sequence in multiline string");
        return error.UnexpectedToken;
    }

    const result: Token = .{ .multiline_string = self.input[start..self.cursor] };

    if (!self.matchN('"', 3)) {
        self.setErrorMessage("unterminated multiline string");
        return error.UnexpectedEndOfInput;
    }
    _ = self.nextChar();
    _ = self.nextChar();
    _ = self.nextChar();

    return result;
}

/// Scan the upcoming regular string in the TOML document and return a token
/// matching it.
fn scanString(self: *@This()) !Token {
    assert(self.match('"'));

    if (self.matchN('"', 3)) {
        return self.scanMultilineString();
    }

    _ = self.nextChar(); // skip the opening quote
    const start = self.cursor;

    while (!self.match('"')) {
        var c = self.nextChar();
        if (c == end_of_input) {
            self.setErrorMessage("unterminated string");
            return error.UnexpectedEndOfInput;
        }

        if (c != '\\') {
            if (!(isValidChar(c) or c == ' ' or c == '\t')) {
                return error.UnexpectedToken;
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
                    self.setErrorMessage("invalid unicode escape in string");
                    return error.UnexpectedToken;
                }
            }
            continue;
        }

        self.setErrorMessage("invalid escape sequence in string");
        return error.UnexpectedToken; // bad escape character
    }

    const result: Token = .{ .string = self.input[start..self.cursor] };

    assert(self.match('"'));
    _ = self.nextChar();

    return result;
}

/// Scan the upcoming multiline literal string in the TOML document and
/// return a token matching it.
fn scanMultilineLiteralString(self: *@This()) !Token {
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
                    return error.UnexpectedToken;
                }
            } else {
                break;
            }
        }

        const c = self.nextChar();

        if (c == end_of_input) {
            self.setErrorMessage("unterminated multiline literal string");
            return error.UnexpectedEndOfInput;
        }

        if (!(isValidChar(c) or mem.indexOfScalar(u8, " \t\n", c) != null)) {
            self.setErrorMessage("invalid character in multiline literal string");
            return error.UnexpectedToken;
        }
    }

    const result: Token = .{ .multiline_literal_string = self.input[start..self.cursor] };

    if (!self.matchN('\'', 3)) {
        self.setErrorMessage("unterminated multiline literal string");
        return error.UnexpectedEndOfInput;
    }
    _ = self.nextChar();
    _ = self.nextChar();
    _ = self.nextChar();

    return result;
}

/// Scan the upcoming literal string in the TOML document.
fn scanLiteralString(self: *@This()) !Token {
    assert(self.match('\''));

    if (self.matchN('\'', 3)) {
        return self.scanMultilineLiteralString();
    }

    _ = self.nextChar(); // skip the opening quote
    const start = self.cursor;

    while (!self.match('\'')) {
        const c = self.nextChar();
        if (c == end_of_input) {
            self.setErrorMessage("unterminated literal string");
            return error.UnexpectedEndOfInput;
        }

        if (!(isValidChar(c) or c == '\t')) {
            self.setErrorMessage("invalid character in literal string");
            return error.UnexpectedToken;
        }
    }

    const result: Token = .{ .literal_string = self.input[start..self.cursor] };

    assert(self.match('\''));
    _ = self.nextChar();

    return result;
}

/// Scan an upcoming literal that is not a string, i.e. a value of some
/// other type.
fn scanNonstringLiteral(self: *@This()) !Token {
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

    self.setErrorMessage("expected a value (number, datetime, or boolean)");
    return error.UnexpectedToken;
}

/// Scan an upcoming literal, for example a key.
fn scanLiteral(self: *@This()) Token {
    const start = self.cursor;
    while (self.cursor < self.end and (ascii.isAlphanumeric(self.input[self.cursor]) or
        self.input[self.cursor] == '_' or self.input[self.cursor] == '-')) : (self.cursor += 1)
    {}
    return .{ .literal = self.input[start..self.cursor] };
}

/// Read an integer value from the upcoming characters without the sign.
fn readInt(self: *@This(), comptime T: type) T {
    var val: T = 0;
    while (ascii.isDigit(self.input[self.cursor])) : (self.cursor += 1) {
        val = val * 10 + @as(T, @intCast(self.input[self.cursor] - '0'));
    }
    return val;
}

/// Read exactly N digits as an unsigned integer value.
fn readFixedDigits(self: *@This(), comptime N: usize) !u32 {
    if (self.cursor + N > self.end) return error.UnexpectedEndOfInput;
    var v: u32 = 0;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const c = self.input[self.cursor + i];
        if (!ascii.isDigit(c)) {
            self.setErrorMessage("expected digit");
            return error.UnexpectedToken;
        }
        v = v * 10 + (c - '0');
    }
    self.cursor += N;
    return v;
}

/// Read a time in the HH:MM:SS.fraction format from the upcoming
/// characters.
fn readTime(self: *@This()) !Time {
    var ret: Time = .{ .hour = undefined, .minute = undefined, .second = undefined };
    ret.hour = @intCast(try self.readFixedDigits(2));
    if (self.cursor >= self.end or self.input[self.cursor] != ':') {
        self.setErrorMessage("invalid time: expected ':' between hour and minute");
        return error.InvalidTime;
    }

    self.cursor += 1;
    ret.minute = @intCast(try self.readFixedDigits(2));
    if (self.cursor >= self.end or self.input[self.cursor] != ':') {
        self.setErrorMessage("invalid time: expected ':' between minute and second");
        return error.InvalidTime;
    }

    self.cursor += 1;
    ret.second = @intCast(try self.readFixedDigits(2));
    if (ret.hour > 23 or ret.minute > 59 or ret.second > 59) {
        self.setErrorMessage("invalid time value");
        return error.InvalidTime;
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

/// Read a date in the YYYY-MM-DD format from the upcoming characters.
fn readDate(self: *@This()) !Date {
    var ret: Date = .{ .year = undefined, .month = undefined, .day = undefined };
    ret.year = @intCast(try self.readFixedDigits(4));
    if (self.cursor >= self.end or self.input[self.cursor] != '-') {
        self.setErrorMessage("invalid date: expected '-' after year");
        return error.InvalidDate;
    }

    self.cursor += 1;
    ret.month = @intCast(try self.readFixedDigits(2));
    if (self.cursor >= self.end or self.input[self.cursor] != '-') {
        self.setErrorMessage("invalid date: expected '-' after month");
        return error.InvalidDate;
    }

    self.cursor += 1;
    ret.day = @intCast(try self.readFixedDigits(2));

    return ret;
}

/// Read a timezone from the next characters.
fn readTimezone(self: *@This()) !?i16 {
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
        self.setErrorMessage("invalid timezone offset: expected ':' between hour and minute");
        return error.InvalidDatetime;
    }

    self.cursor += 1;
    const minute: i16 = @intCast(try self.readFixedDigits(2));
    if (hour > 23 or minute > 59) {
        self.setErrorMessage("invalid timezone offset value");
        return error.InvalidDatetime;
    }

    return (hour * 60 + minute) * sign;
}

/// Scan upcoming local time value.
fn scanTime(self: *@This()) !Token {
    const t = try self.readTime();
    if (!t.isValid()) {
        self.setErrorMessage("invalid time literal");
        return error.InvalidTime;
    }

    return .{ .local_time = t };
}

/// Scan an upcoming datetime value.
fn scanDatetime(self: *@This()) !Token {
    if (self.cursor + 2 >= self.end) {
        self.setErrorMessage("unterminated datetime");
        return error.UnexpectedEndOfInput;
    }

    if (ascii.isDigit(self.input[self.cursor]) and
        ascii.isDigit(self.input[self.cursor + 1]) and self.input[self.cursor + 2] == ':')
    {
        const t = try self.readTime();
        if (!t.isValid()) {
            self.setErrorMessage("invalid time literal");
            return error.InvalidTime;
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
            self.setErrorMessage("invalid date literal");
            return error.InvalidDate;
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
            self.setErrorMessage("invalid datetime value");
            return error.InvalidDatetime;
        }

        return .{ .local_datetime = dt };
    }

    dt.tz = tz;
    if (!dt.isValid()) {
        self.setErrorMessage("invalid datetime value");
        return error.InvalidDatetime;
    }

    return .{ .datetime = dt };
}

/// Scan a possible upcoming boolean value.
fn scanBool(self: *@This()) !Token {
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
        return error.UnexpectedToken;
    }

    if (self.cursor < self.end and
        null == mem.indexOfScalar(u8, "# \r\n\t,}]", self.input[self.cursor]))
    {
        self.setErrorMessage("invalid trailing characters after boolean literal");
        return error.UnexpectedToken;
    }

    return .{ .bool = val };
}

/// Scan a possible upcoming number, i.e. integer or float.
fn scanNumber(self: *@This()) !Token {
    // Non-decimal bases
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
                self.setErrorMessage("invalid digits for base-prefixed integer");
                return error.UnexpectedToken;
            };

            if (end_idx == start) {
                self.setErrorMessage("missing digits after base prefix");
                return error.InvalidNumber;
            }

            var prev_underscore = false;
            var i: usize = start;
            while (i < end_idx) : (i += 1) {
                const c = self.input[i];
                if (c == '_') {
                    if (prev_underscore or i == start or i + 1 == end_idx) {
                        self.setErrorMessage("invalid underscore placement in number");
                        return error.InvalidNumber;
                    }
                    prev_underscore = true;
                } else {
                    prev_underscore = false;
                }
            }

            var buf: ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);

            i = start;
            while (i < end_idx) : (i += 1) {
                const c = self.input[i];
                if (c != '_') {
                    try buf.append(self.allocator, c);
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
        self.setErrorMessage("unexpected end of input while reading number");
        return error.UnexpectedEndOfInput;
    }

    if (self.input[idx] == 'i' or self.input[idx] == 'n') {
        return self.scanFloat();
    }

    // Find token end
    idx = mem.indexOfNonePos(u8, self.input, self.cursor, "_0123456789eE.+-") orelse {
        self.setErrorMessage("malformed number literal");
        return error.UnexpectedToken;
    };

    if (idx == start) {
        self.setErrorMessage("missing digits in number");
        return error.InvalidNumber;
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
        self.setErrorMessage("leading zeros are not allowed in integers");
        return error.InvalidNumber;
    }

    var prev_underscore = false;

    var j: usize = s_off;
    while (j < slice.len) : (j += 1) {
        const c = slice[j];
        if (c == '_') {
            if (prev_underscore or j == s_off or j + 1 == slice.len) {
                self.setErrorMessage("invalid underscore placement in number");
                return error.InvalidNumber;
            }
            prev_underscore = true;
        } else if (!ascii.isDigit(c)) {
            self.setErrorMessage("invalid character in integer literal");
            return error.InvalidNumber;
        } else {
            prev_underscore = false;
        }
    }

    var buf: ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);

    j = 0;
    while (j < slice.len) : (j += 1) {
        const c = slice[j];
        if (c != '_') {
            try buf.append(self.allocator, c);
        }
    }

    const n = try std.fmt.parseInt(i64, buf.items, 10);
    self.cursor = idx;

    return .{ .int = n };
}

/// Scan a possible upcoming floating-point literal.
fn scanFloat(self: *@This()) !Token {
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
        self.cursor = mem.indexOfNonePos(
            u8,
            self.input,
            self.cursor,
            "_0123456789eE.+-",
        ) orelse {
            self.setErrorMessage("malformed float literal");
            return error.UnexpectedToken;
        };
    }

    const slice = self.input[start..self.cursor];

    // Validate underscores not at ends or adjacent to dot or exponent
    // signs.
    var prev_char: u8 = 0;

    var i: usize = 0;
    while (i < slice.len) : (i += 1) {
        const c = slice[i];
        if (c == '_') {
            if (i == 0 or i + 1 == slice.len) {
                self.setErrorMessage("invalid underscore placement in float literal");
                return error.InvalidNumber;
            }
            const nxt = slice[i + 1];
            if (!ascii.isDigit(prev_char) or !ascii.isDigit(nxt)) {
                self.setErrorMessage("invalid underscore placement in float literal");
                return error.InvalidNumber;
            }
        }
        prev_char = c;
    }

    var buf: ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);

    i = 0;
    while (i < slice.len) : (i += 1) {
        const c = slice[i];
        if (c != '_') {
            try buf.append(self.allocator, c);
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
            self.setErrorMessage("leading zeros are not allowed in float literal");
            return error.InvalidNumber;
        }
    }

    // Disallow floats like 1., .1, or exponents with missing mantissa per
    // TOML.
    if (mem.indexOfScalar(u8, buf.items, '.') != null) {
        // Must have digits on both sides of '.'.
        const dot_idx = mem.indexOfScalar(u8, buf.items, '.').?;
        if (dot_idx == 0 or dot_idx + 1 >= buf.items.len) {
            self.setErrorMessage("decimal point must have digits on both sides");
            return error.InvalidNumber;
        }

        if (!ascii.isDigit(buf.items[dot_idx - 1]) or !ascii.isDigit(buf.items[dot_idx + 1])) {
            self.setErrorMessage("decimal point must have digits on both sides");
            return error.InvalidNumber;
        }
    }

    // Validate exponent placement: must have digits before and after 'e' or
    // 'E' (with optional sign).
    if (mem.indexOfAny(u8, buf.items, "eE")) |e_idx| {
        if (e_idx == 0) {
            self.setErrorMessage("invalid exponent format");
            return error.InvalidNumber;
        }

        if (!ascii.isDigit(buf.items[e_idx - 1]) and buf.items[e_idx - 1] != '.') {
            self.setErrorMessage("invalid exponent format");
            return error.InvalidNumber;
        }

        var after = e_idx + 1;
        if (after < buf.items.len and (buf.items[after] == '+' or buf.items[after] == '-')) {
            after += 1;
        }

        if (after >= buf.items.len or !ascii.isDigit(buf.items[after])) {
            self.setErrorMessage("invalid exponent format");
            return error.InvalidNumber;
        }
    }

    const f = try std.fmt.parseFloat(f64, buf.items);

    return .{ .float = f };
}

fn checkNumberStr(self: *@This(), len: usize, base: u8) bool {
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
