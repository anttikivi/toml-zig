// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

//! Parses TOML tokens into syntax-aware items and decodes scalars from
//! the input. It emits `Item`s that contain the information parsed from
//! the tokens it receives.
//!
//! The Parser validates the syntax of the tokens it receives. However, it does
//! not keep track of the keys and values so checking for duplicate keys and
//! other such requirements is left for the receiver. As it does not use
//! an allocator, it does not parse string values. The receiver must handle
//! the strings, e.g. normalize the line endings and parse escape sequences.

const Parser = @This();

const std = @import("std");
const assert = std.debug.assert;

const Diagnostics = @import("root.zig").Diagnostics;
const Span = @import("root.zig").Span;
const Tokenizer = @import("Tokenizer.zig");
const Token = @import("Tokenizer.zig").Token;
const default_version = @import("toml.zig").default_version;
const Features = @import("toml.zig").Features;
const Float = @import("toml.zig").Float;
const Int = @import("toml.zig").Int;
const Version = @import("toml.zig").Version;
const Datetime = @import("value.zig").Datetime;
const Date = @import("value.zig").Date;
const Time = @import("value.zig").Time;

state: State = .table,
token: ?Token = null,
nesting: Stack(enum { array, inline_table }, max_nesting),
tokenizer: Tokenizer,
features: Features,
diagnostics: ?*Diagnostics,

const max_nesting = 128;

pub const Options = struct {
    toml_version: Version = default_version,
    diagnostics: ?*Diagnostics = null,
};

pub const Item = struct {
    tag: Tag,
    span: Span,
    value: ?Value = null,

    pub const Tag = enum {
        table_header_start,
        table_header_end,
        /// Key used in a table header.
        table_key,
        array_table_header_start,
        array_table_header_end,
        array_table_key,
        /// Key before a value.
        key,
        value,
        array_start,
        array_end,
        inline_table_start,
        inline_table_end,
    };

    pub const Value = union(enum) {
        // TODO: Consider renaming as this is used for bare keys.
        literal,
        string,
        multiline_string,
        literal_string,
        multiline_literal_string,
        int: Int,
        float: Float,
        boolean: bool,
        datetime: Datetime,
        local_datetime: Datetime,
        local_date: Date,
        local_time: Time,
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

pub const State = enum {
    invalid,
    table,
    table_header,
    table_header_incomplete,
    array_table_header,
    array_table_header_incomplete,
    key,
    key_incomplete,
    value_start,
    value_end,
    inline_table,
};

/// Stack for storing the current nesting status of the parser when inside
/// arrays and inline tables.
fn Stack(comptime T: type, comptime c: usize) type {
    return struct {
        buf: [c]T = undefined,
        len: usize = 0,

        const Self = @This();

        fn push(self: *Self, v: T) error{Overflow}!void {
            if (self.len >= c) {
                return error.Overflow;
            }

            self.buf[self.len] = v;
            self.len += 1;
        }

        fn pop(self: *Self) ?T {
            if (self.len == 0) {
                return null;
            }

            self.len -= 1;
            return self.buf[self.len];
        }

        fn top(self: *const Self) ?T {
            if (self.len == 0) {
                return null;
            }

            return self.buf[self.len - 1];
        }
    };
}

pub fn init(input: []const u8, options: Options) Parser {
    return .{
        .tokenizer = .init(input, .{
            .toml_version = options.toml_version,
            .diagnostics = options.diagnostics,
        }),
        .nesting = .{},
        .features = .init(options.toml_version),
        .diagnostics = options.diagnostics,
    };
}

/// Returns the next `Item` parsed from the tokens obtained from the input.
/// The string values are always slices from the original input buffer, and
/// the receiver of the `Item` must either duplicate the strings or inform
/// the caller of the decoder on the ownership and borrowing of the strings.
pub fn next(self: *Parser) Error!?Item {
    errdefer self.state = .invalid;
    errdefer self.token = null;

    var result: Item = .{
        .tag = undefined,
        .span = undefined,
    };

    state: switch (self.state) {
        .invalid => return self.fail(error.InvalidState, null),
        .table => {
            if (self.token == null) {
                self.token = try self.tokenizer.next();
            }

            assert(self.nesting.len == 0);

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
                    result.tag = .table_header_start;
                    result.span = self.token.?.span;
                    self.state = .table_header_incomplete;
                    self.token = null;
                },
                .double_left_bracket => {
                    result.tag = .array_table_header_start;
                    result.span = self.token.?.span;
                    self.state = .array_table_header_incomplete;
                    self.token = null;
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
                    result.tag = .table_header_end;
                    result.span = self.token.?.span;
                    self.state = .table;
                    self.token = null;
                },
                .literal => {
                    result.tag = .table_key;

                    const start = self.token.?.span.start;

                    if (self.state == .table_header_incomplete and
                        self.tokenizer.buffer[start] == '.')
                    {
                        return self.fail(error.UnexpectedToken, null);
                    }

                    var end = start;

                    while (end < self.token.?.span.end) : (end += 1) {
                        const c = self.tokenizer.buffer[end];
                        if (!isBareKey(c)) {
                            switch (c) {
                                '.' => {
                                    self.state = .table_header_incomplete;
                                    self.token.?.span.start = end + 1;
                                    break;
                                },
                                else => return self.fail(error.InvalidCharacter, null),
                            }
                        }
                    }

                    if (end == self.token.?.span.end) {
                        self.state = .table_header;
                        self.token = null;
                    } else if (self.token.?.span.start == self.token.?.span.end) {
                        self.token = null;
                    }

                    result.span = .{ .start = start, .end = end };
                    result.value = .literal;
                },
                .string => {
                    result.tag = .table_key;
                    result.span = self.token.?.span.narrow(1);
                    result.value = .string;
                    self.state = .table_header;
                    self.token = null;
                },
                .literal_string => {
                    result.tag = .table_key;
                    result.span = self.token.?.span.narrow(1);
                    result.value = .literal_string;
                    self.state = .table_header;
                    self.token = null;
                },
                else => return self.fail(error.UnexpectedToken, "table header not terminated"),
            }
        },
        .array_table_header, .array_table_header_incomplete => {
            if (self.token == null) {
                self.token = try self.tokenizer.next();
            }

            switch (self.token.?.tag) {
                .end_of_file => return self.fail(error.UnterminatedHeader, null),
                .dot => {
                    if (self.state == .array_table_header_incomplete) {
                        return self.fail(error.UnexpectedToken, null);
                    }
                    self.state = .array_table_header_incomplete;
                    self.token = null;
                    continue :state .array_table_header_incomplete;
                },
                .double_right_bracket => {
                    if (self.state == .array_table_header_incomplete) {
                        return self.fail(error.UnexpectedToken, null);
                    }
                    result.tag = .array_table_header_end;
                    result.span = self.token.?.span;
                    self.state = .table;
                    self.token = null;
                },
                .literal => {
                    result.tag = .array_table_key;

                    const start = self.token.?.span.start;

                    if (self.state == .array_table_header_incomplete and
                        self.tokenizer.buffer[start] == '.')
                    {
                        return self.fail(error.UnexpectedToken, null);
                    }

                    var end = start;

                    while (end < self.token.?.span.end) : (end += 1) {
                        const c = self.tokenizer.buffer[end];
                        if (!isBareKey(c)) {
                            switch (c) {
                                '.' => {
                                    self.state = .array_table_header_incomplete;
                                    self.token.?.span.start = end + 1;
                                    break;
                                },
                                else => return self.fail(error.InvalidCharacter, null),
                            }
                        }
                    }

                    if (end == self.token.?.span.end) {
                        self.state = .array_table_header;
                        self.token = null;
                    } else if (self.token.?.span.start == self.token.?.span.end) {
                        self.token = null;
                    }

                    result.span = .{ .start = start, .end = end };
                    result.value = .literal;
                },
                .string => {
                    result.tag = .array_table_key;
                    result.span = self.token.?.span.narrow(1);
                    result.value = .string;
                    self.state = .array_table_header;
                    self.token = null;
                },
                .literal_string => {
                    result.tag = .array_table_key;
                    result.span = self.token.?.span.narrow(1);
                    result.value = .literal_string;
                    self.state = .array_table_header;
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

                    const start = self.token.?.span.start;

                    if (self.state == .key_incomplete and self.tokenizer.buffer[start] == '.') {
                        return self.fail(error.UnexpectedToken, null);
                    }

                    var end = start;

                    while (end < self.token.?.span.end) : (end += 1) {
                        const c = self.tokenizer.buffer[end];
                        if (!isBareKey(c)) {
                            switch (c) {
                                '.' => {
                                    self.state = .key_incomplete;
                                    self.token.?.span.start = end + 1;
                                    break;
                                },
                                else => return self.fail(error.InvalidCharacter, null),
                            }
                        }
                    }

                    if (end == self.token.?.span.end) {
                        self.state = .key;
                        self.token = null;
                    } else if (self.token.?.span.start == self.token.?.span.end) {
                        self.token = null;
                    }

                    result.span = .{ .start = start, .end = end };
                    result.value = .literal;
                },
                .string => {
                    result.tag = .key;
                    result.span = self.token.?.span.narrow(1);
                    result.value = .string;
                    self.state = .key;
                    self.token = null;
                },
                .literal_string => {
                    result.tag = .key;
                    result.span = self.token.?.span.narrow(1);
                    result.value = .literal_string;
                    self.state = .key;
                    self.token = null;
                },
                else => return self.fail(error.UnexpectedToken, "key not terminated"),
            }
        },
        .value_start => {
            if (self.token == null) {
                self.token = try self.tokenizer.next();
            }

            switch (self.token.?.tag) {
                .newline => {
                    if (self.nesting.top()) |t| {
                        switch (t) {
                            .array => {
                                self.token = null;
                                continue :state .value_start;
                            },
                            .inline_table => return self.fail(error.UnexpectedToken, null),
                        }
                    }

                    return self.fail(error.UnexpectedToken, null);
                },
                .double_left_bracket => {
                    result.tag = .array_start;
                    result.span = .{
                        .start = self.token.?.span.start,
                        .end = self.token.?.span.start + 1,
                    };
                    self.state = .value_start;
                    self.token.?.tag = .left_bracket;
                    self.token.?.span.start += 1;
                    self.nesting.push(.array) catch |err| return self.printFail(
                        err,
                        "exceeded maximum nesting level {d}",
                        .{max_nesting},
                    );
                },
                .left_bracket => {
                    result.tag = .array_start;
                    result.span = self.token.?.span;
                    self.state = .value_start;
                    self.token = null;
                    self.nesting.push(.array) catch |err| return self.printFail(
                        err,
                        "exceeded maximum nesting level {d}",
                        .{max_nesting},
                    );
                },
                .double_right_bracket => {
                    if (self.nesting.pop()) |p| {
                        switch (p) {
                            .array => {
                                result.tag = .array_end;
                                result.span = .{
                                    .start = self.token.?.span.start,
                                    .end = self.token.?.span.start + 1,
                                };
                                self.state = .value_end;
                                self.token.?.tag = .right_bracket;
                                self.token.?.span.start += 1;
                                break :state;
                            },
                            else => return self.fail(error.UnexpectedToken, null),
                        }
                    }

                    return self.fail(error.UnexpectedToken, null);
                },
                .right_bracket => {
                    if (self.nesting.pop()) |p| {
                        switch (p) {
                            .array => {
                                result.tag = .array_end;
                                result.span = self.token.?.span;
                                self.state = .value_end;
                                self.token = null;
                                break :state;
                            },
                            .inline_table => return self.fail(error.UnexpectedToken, null),
                        }
                    }

                    return self.fail(error.UnexpectedToken, "array not closed");
                },
                .left_brace => {
                    result.tag = .inline_table_start;
                    result.span = self.token.?.span;
                    self.state = .inline_table;
                    self.token = null;
                    self.nesting.push(.inline_table) catch |err| return self.printFail(
                        err,
                        "exceeded maximum nesting level {d}",
                        .{max_nesting},
                    );
                },
                .string => {
                    result.tag = .value;
                    result.span = self.token.?.span.narrow(1);
                    result.value = .string;
                    self.state = .value_end;
                    self.token = null;
                },
                .multiline_string => {
                    result.tag = .value;
                    result.span = self.token.?.span.narrow(3);
                    result.value = .multiline_string;
                    self.state = .value_end;
                    self.token = null;
                },
                .literal_string => {
                    result.tag = .value;
                    result.span = self.token.?.span.narrow(1);
                    result.value = .literal_string;
                    self.state = .value_end;
                    self.token = null;
                },
                .multiline_literal_string => {
                    result.tag = .value;
                    result.span = self.token.?.span.narrow(3);
                    result.value = .multiline_literal_string;
                    self.state = .value_end;
                    self.token = null;
                },
                .literal => {
                    // TODO: Consider if the parsing (up until floats) could be done using a single
                    // loop through the characters in the buffer.
                    result.tag = .value;
                    self.state = .value_end;

                    var start = self.token.?.span.start;
                    var end = self.token.?.span.end;
                    while (start < end and std.mem.findScalar(
                        u8,
                        " \t\r\n",
                        self.tokenizer.buffer[start],
                    )) : (start += 1) {}
                    while (end > start and std.mem.findScalar(
                        u8,
                        " \t\r\n",
                        self.tokenizer.buffer[end],
                    )) : (end -= 1) {}

                    if (start == end) {
                        return self.fail(error.UnexpectedToken, null);
                    }

                    const buf = self.tokenizer.buffer[start..end];
                    result.span = .{ .start = start, .end = end };

                    if (std.mem.eql(u8, buf, "true")) {
                        result.value = .{ .boolean = true };
                        self.token = null;
                        break :state;
                    }

                    if (std.mem.eql(u8, buf, "false")) {
                        result.value = .{ .boolean = false };
                        self.token = null;
                        break :state;
                    }

                    if (std.mem.eql(u8, buf, "inf") or std.mem.eql(u8, buf, "+inf")) {
                        result.value = .{ .float = std.math.inf(Float) };
                        self.token = null;
                        break :state;
                    }

                    if (std.mem.eql(u8, buf, "-inf")) {
                        result.value = .{ .float = -std.math.inf(Float) };
                        self.token = null;
                        break :state;
                    }

                    if (std.mem.eql(u8, buf, "nan") or std.mem.eql(u8, buf, "+nan")) {
                        result.value = .{ .float = std.math.nan(Float) };
                        self.token = null;
                        break :state;
                    }

                    if (std.mem.eql(u8, buf, "-nan")) {
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
                        // Datetimes may be broken into two tokens, breaking the earlier handling of
                        // the span. The result needs to be passed into the function and modified
                        // there.
                        self.parseDatetime(&result, buf) catch |err| return switch (err) {
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
                        result.value = self.parseTime(buf, null) catch |err| return switch (err) {
                            error.Reported => err,
                            else => self.fail(err, null),
                        };
                        break :state;
                    }

                    result.value = self.parseNumber(buf) catch |err| return switch (err) {
                        error.Reported => err,
                        else => self.fail(err, null),
                    };
                },
                else => return self.fail(error.UnexpectedToken, null),
            }
        },
        .value_end => {
            if (self.token == null) {
                self.token = try self.tokenizer.next();
            }

            switch (self.token.?.tag) {
                .end_of_file => {
                    if (self.nesting.top()) |t| {
                        switch (t) {
                            .array => return self.fail(error.UnexpectedEnd, "array not closed"),
                            .inline_table => return self.fail(error.UnexpectedEnd, "inline table not closed"),
                        }
                    }

                    assert(self.nesting.len == 0);
                    self.token = null;
                    return null;
                },
                .newline => {
                    if (self.nesting.top()) |t| {
                        switch (t) {
                            .array => {
                                // When inside array, a newline is allowed if
                                // the array is terminated after that.
                                self.token = try self.tokenizer.next();
                                retry: switch (self.token.?.tag) {
                                    .double_right_bracket => {
                                        const p = self.nesting.pop().?;
                                        assert(p == .array);

                                        result.tag = .array_end;
                                        result.span = .{
                                            .start = self.token.?.span.start,
                                            .end = self.token.?.span.start + 1,
                                        };

                                        self.state = .value_end;
                                        self.token.?.tag = .right_bracket;
                                        self.token.?.span.start += 1;
                                    },
                                    .right_bracket => {
                                        const p = self.nesting.pop().?;
                                        assert(p == .array);

                                        result.tag = .array_end;
                                        result.span = self.token.?.span;

                                        self.state = .value_end;
                                        self.token = null;
                                    },
                                    .newline => {
                                        self.token = try self.tokenizer.next();
                                        continue :retry self.token.?.tag;
                                    },
                                    else => return self.fail(
                                        error.UnexpectedToken,
                                        "array not closed",
                                    ),
                                }
                            },
                            .inline_table => {
                                self.token = try self.tokenizer.next();
                                retry: switch (self.token.?.tag) {
                                    .right_brace => if (self.features.inline_table_newlines) {
                                        const p = self.nesting.pop().?;
                                        assert(p == .inline_table);

                                        result.tag = .inline_table_end;
                                        result.span = self.token.?.span;

                                        self.state = .value_end;
                                        self.token = null;

                                        break :state;
                                    } else {
                                        return self.fail(error.UnexpectedToken, null);
                                    },
                                    .newline => if (self.features.inline_table_newlines) {
                                        self.token = try self.tokenizer.next();
                                        continue :retry self.token.?.tag;
                                    } else {
                                        return self.fail(error.UnexpectedToken, null);
                                    },
                                    else => return self.fail(error.UnexpectedToken, "inline table not closed"),
                                }
                            },
                        }

                        break :state;
                    }

                    self.state = .table;
                    self.token = null;
                    continue :state .table;
                },
                .double_right_bracket => {
                    if (self.nesting.pop()) |p| {
                        switch (p) {
                            .array => {
                                result.tag = .array_end;
                                result.span = .{
                                    .start = self.token.?.span.start,
                                    .end = self.token.?.span.start + 1,
                                };
                                self.state = .value_end;
                                self.token.?.tag = .right_bracket;
                                self.token.?.span.start += 1;
                                break :state;
                            },
                            else => return self.fail(error.UnexpectedToken, null),
                        }
                    }

                    return self.fail(error.UnexpectedToken, null);
                },
                .right_bracket => {
                    if (self.nesting.pop()) |p| {
                        switch (p) {
                            .array => {
                                result.tag = .array_end;
                                result.span = self.token.?.span;
                                self.state = .value_end;
                                self.token = null;
                                break :state;
                            },
                            else => return self.fail(error.UnexpectedToken, null),
                        }
                    }

                    return self.fail(error.UnexpectedToken, null);
                },
                .right_brace => {
                    if (self.nesting.pop()) |p| {
                        switch (p) {
                            .inline_table => {
                                result.tag = .inline_table_end;
                                result.span = self.token.?.span;
                                self.state = .value_end;
                                self.token = null;
                                break :state;
                            },
                            else => return self.fail(error.UnexpectedToken, null),
                        }
                    }

                    return self.fail(error.UnexpectedToken, null);
                },
                .comma => {
                    if (self.nesting.top()) |t| {
                        switch (t) {
                            .array => {
                                self.token = try self.tokenizer.next();
                                retry: switch (self.token.?.tag) {
                                    .double_right_bracket => {
                                        const p = self.nesting.pop().?;
                                        assert(p == .array);

                                        result.tag = .array_end;
                                        result.span = .{
                                            .start = self.token.?.span.start,
                                            .end = self.token.?.span.start + 1,
                                        };

                                        self.state = .value_end;
                                        self.token.?.tag = .right_bracket;
                                        self.token.?.span.start += 1;
                                        break :state;
                                    },
                                    .right_bracket => {
                                        const p = self.nesting.pop().?;
                                        assert(p == .array);

                                        result.tag = .array_end;
                                        result.span = self.token.?.span;

                                        self.state = .value_end;
                                        self.token = null;
                                        break :state;
                                    },
                                    .newline => {
                                        self.token = try self.tokenizer.next();
                                        continue :retry self.token.?.tag;
                                    },
                                    .double_left_bracket,
                                    .left_bracket,
                                    .string,
                                    .multiline_string,
                                    .literal_string,
                                    .multiline_literal_string,
                                    .literal,
                                    => {
                                        self.state = .value_start;
                                        continue :state .value_start;
                                    },
                                    else => return self.fail(error.UnexpectedToken, "array not closed"),
                                }
                            },
                            .inline_table => {
                                self.token = try self.tokenizer.next();
                                retry: switch (self.token.?.tag) {
                                    .right_brace => if (self.features.inline_table_trailing_comma) {
                                        const p = self.nesting.pop().?;
                                        assert(p == .inline_table);

                                        result.tag = .inline_table_end;
                                        result.span = self.token.?.span;

                                        self.state = .value_end;
                                        self.token = null;
                                        break :state;
                                    } else {
                                        return self.fail(error.UnexpectedToken, null);
                                    },
                                    .newline => if (self.features.inline_table_newlines) {
                                        self.token = try self.tokenizer.next();
                                        continue :retry self.token.?.tag;
                                    } else {
                                        return self.fail(error.UnexpectedToken, null);
                                    },
                                    .literal, .string, .literal_string => {
                                        self.state = .inline_table;
                                        continue :state .inline_table;
                                    },
                                    else => return self.fail(error.UnexpectedToken, "inline table not closed"),
                                }
                            },
                        }
                    }

                    return self.fail(error.UnexpectedToken, null);
                },
                else => return self.fail(error.UnexpectedToken, null),
            }
        },
        .inline_table => {
            if (self.token == null) {
                self.token = try self.tokenizer.next();
            }

            assert(self.nesting.len > 0);

            switch (self.token.?.tag) {
                .right_brace => {
                    const p = self.nesting.pop().?;
                    assert(p == .inline_table);

                    result.tag = .inline_table_end;
                    result.span = self.token.?.span;

                    self.state = .value_end;
                    self.token = null;
                    break :state;
                },
                .newline => if (self.features.inline_table_newlines) {
                    self.token = null;
                    continue :state .inline_table;
                } else {
                    return self.fail(error.UnexpectedToken, null);
                },
                .literal, .string, .literal_string => {
                    self.state = .key_incomplete;
                    continue :state .key_incomplete;
                },
                else => return self.fail(error.UnexpectedToken, null),
            }
        },
    }

    return result;
}

fn parseDatetime(self: *Parser, result: *Item, s: []const u8) Error!void {
    var buf = s;

    if (buf.len < 10 or buf[4] != '-' or buf[7] != '-') {
        return self.fail(error.InvalidDatetime, null);
    }

    const year = parseDatetimeDigits(u16, 4, buf[0..4]) catch {
        return self.fail(error.InvalidDatetime, null);
    };
    const month = parseDatetimeDigits(u8, 2, buf[5..7]) catch {
        return self.fail(error.InvalidDatetime, null);
    };
    const day = parseDatetimeDigits(u8, 2, buf[8..10]) catch {
        return self.fail(error.InvalidDatetime, null);
    };

    const max_day = switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if ((year % 4 == 0 and year % 100 != 0) or (year % 400 == 0)) 29 else 28,
        else => self.fail(error.InvalidDatetime, null),
    };
    if (day == 0 or day > max_day) {
        return self.fail(error.InvalidDatetime, null);
    }

    // Due to how the tokenizer works, we need to check if the next token continues the datetime.
    if (buf.len == 10) {
        const date_end = self.token.?.span.end;
        self.token = try self.tokenizer.next();
        switch (self.token.?.tag) {
            .literal => { // continue datetime
                const start = self.token.?.span.start;

                if (start != date_end + 1 or self.tokenizer.buffer[date_end] != ' ') {
                    return self.fail(error.InvalidDatetime, null);
                }

                var end = self.token.?.span.end;
                while (end > start and std.mem.findScalar(
                    u8,
                    " \t\r\n",
                    self.tokenizer.buffer[end],
                )) : (end -= 1) {}

                if (start == end) {
                    return self.fail(error.UnexpectedToken, null);
                }

                buf = self.tokenizer.buffer[start..end];
                result.span.end = end;
            },
            else => {
                result.value = .{
                    .local_date = .{
                        .year = year,
                        .month = month,
                        .day = day,
                    },
                };
                return;
            },
        }
    } else if (buf[10] == 'T' or buf[10] == 't') {
        // The length is guaranteed to be over 10 here.
        buf = buf[11..];
    } else {
        return self.fail(error.InvalidDatetime, null);
    }

    var consumed: u8 = 0;
    const time = self.parseTime(buf, &consumed) catch |err| return switch (err) {
        error.InvalidTime => error.InvalidDatetime,
        else => err,
    };

    if (consumed < buf.len) {
        buf = buf[consumed..];
    }

    const tz = blk: {
        if (buf.len == 0) {
            break :blk null;
        }
        if (buf.len == 1 and (buf[0] == 'Z' or buf[0] == 'z')) {
            break :blk 0;
        }
        if (buf.len == 6 and (buf[0] == '-' or buf[0] == '+') and buf[3] == ':') {
            const sign: i16 = if (buf[0] == '-') -1 else 1;
            const h: i16 = parseDatetimeDigits(u8, 2, buf[1..3]) catch {
                return self.fail(error.InvalidDatetime, null);
            };
            const m: i16 = parseDatetimeDigits(u8, 2, buf[4..6]) catch {
                return self.fail(error.InvalidDatetime, null);
            };
            if (h > 23 or m > 59) {
                return self.fail(error.InvalidDatetime, null);
            }
            break :blk sign * (h * 60 + m);
        }
        return self.fail(error.InvalidDatetime, "invalid timezone notation");
    };

    self.token = null;

    if (tz) |t| {
        result.value = .{
            .datetime = .{
                .year = year,
                .month = month,
                .day = day,
                .hour = time.hour,
                .minute = time.minute,
                .second = time.second,
                .nano = time.nano,
                .tz = t,
            },
        };
        return;
    }

    result.value = .{
        .local_datetime = .{
            .year = year,
            .month = month,
            .day = day,
            .hour = time.hour,
            .minute = time.minute,
            .second = time.second,
            .nano = time.nano,
            .tz = null,
        },
    };
}

fn parseTime(self: *Parser, s: []const u8, consumed: ?*u8) Error!Item.Value {
    var buf = s;

    if (buf.len < 5 or buf[2] != ':') {
        return self.fail(error.InvalidTime, null);
    }

    const hour = parseDatetimeDigits(u8, 2, buf[0..2]) catch {
        return self.fail(error.InvalidTime, null);
    };
    const minute = parseDatetimeDigits(u8, 2, buf[3..5]) catch {
        return self.fail(error.InvalidTime, null);
    };

    if (consumed) |c| {
        c.* += 5;
    }

    const second = blk: {
        if (buf.len >= 8 and buf[5] == ':') {
            if (consumed) |c| {
                c.* += 3;
            }

            break :blk parseDatetimeDigits(u8, 2, buf[6..8]) catch {
                return self.fail(error.InvalidTime, null);
            };
        } else if (!self.features.optional_seconds) {
            return self.fail(error.InvalidTime, "missing seconds");
        }

        break :blk null;
    };

    buf = if (second == null) buf[5..] else buf[8..];

    if (hour > 23 or minute > 59) {
        return self.fail(error.InvalidTime, null);
    }

    if (second) |sec| {
        // RFC 3339 permits 60 to account for leap seconds.
        if (sec > 60) {
            return self.fail(error.InvalidTime, null);
        }
    }

    const nano = blk: {
        if (buf.len > 1 and buf[0] == '.') {
            if (second == null) {
                return self.fail(error.InvalidTime, "no seconds before fraction");
            }

            buf = buf[1..];
            if (buf.len == 0 or !std.ascii.isDigit(buf[0])) {
                return self.fail(error.InvalidTime, null);
            }

            var n: u32 = 0;
            var i: usize = 0;
            while (i < buf.len and std.ascii.isDigit(buf[i])) : (i += 1) {
                if (i < 9) {
                    n = n * 10 + (buf[i] - '0');
                }
            }

            buf = buf[i..];

            if (consumed) |c| {
                c.* += i;
            }

            var significant_digits: usize = @min(i, 9);
            while (significant_digits < 9) : (significant_digits += 1) {
                n *= 10;
            }

            break :blk n;
        }

        break :blk null;
    };

    if (consumed == null) {
        if (buf.len != 0) {
            return self.fail(error.InvalidTime, null);
        }

        self.token = null;
    }

    return .{
        .local_time = .{
            .hour = hour,
            .minute = minute,
            .second = second orelse 0,
            .nano = nano,
        },
    };
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

    // TODO: Should we scan if the number is a float right at the beginning before integer parsing?
    if (!float_found) {
        self.token = null;
        return .{ .int = int };
    }

    if (base != 10) {
        return self.fail(error.InvalidCharacter, "floating-point values may only be decimal");
    }

    // Just parse the full string again. Otherwise, we'd risk losing precision over probably
    // negligible performance gains.
    self.token = null;
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

fn printFail(self: Parser, err: Error, comptime fmt: []const u8, args: anytype) Error {
    assert(err != error.Reported);
    return self.fail(err, std.fmt.comptimePrint(fmt, args));
}

fn parseDatetimeDigits(comptime T: type, comptime n: usize, buffer: []const u8) error{
    InvalidCharacter,
    Underflow,
}!T {
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

fn isBareKey(c: u8) bool {
    switch (c) {
        '-', '0'...'9', 'A'...'Z', '_', 'a'...'z' => return true,
        else => return false,
    }
}

test {
    _ = @import("Parser/test.zig");
}
