// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const Parser = @This();

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;

const Diagnostics = @import("root.zig").Diagnostics;
const Tokenizer = @import("Tokenizer.zig");
const Token = @import("Tokenizer.zig").Token;
const Features = @import("toml.zig").Features;
const default_version = @import("toml.zig").default_version;
const Version = @import("toml.zig").Version;

state: State = .table,
token: ?Token = null,
tokenizer: *Tokenizer,
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
        /// Bare key used in a table header.
        table_key,
    };

    pub const Value = union(enum) {
        literal: []const u8,
        string: []const u8,
        literal_string: []const u8,
        int: i64,
        float: f64,
        boolean: bool,
        // TODO: Datetimes.
        // TODO: Array.
        // TODO: Table.
    };
};

pub const Error = Diagnostics.Error || Tokenizer.Error || error{
    InvalidCharacter,
    InvalidState,
    UnterminatedHeader,
};

const State = enum {
    invalid,
    table,
    table_header,
    table_header_incomplete,
};

pub fn init(tokenizer: *Tokenizer, options: Options) Parser {
    return .{
        .tokenizer = tokenizer,
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
            const token = self.token orelse try self.tokenizer.next();

            switch (token.tag) {
                .end_of_file => return null,
                .newline => continue :state .table,
                .left_bracket => {
                    self.state = .table_header_incomplete;
                    self.token = null;
                    result.tag = .table_header_start;
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
    }

    return result;
}

fn isBareKey(c: u8) bool {
    switch (c) {
        '-', '0'...'9', 'A'...'Z', '_', 'a'...'z' => return true,
        else => return false,
    }
}

fn fail(self: Parser, err: Error, msg: ?[]const u8) Error {
    assert(err != error.Reported);

    if (self.diagnostics) |diag| {
        diag.* = .{
            .position = self.tokenizer.position(),
            .message = if (msg) |m| m else switch (err) {
                error.InvalidCharacter => "invalid character",
                error.InvalidControlCharacter => "invalid control character",
                error.InvalidEscapeSequence => "invalid escape sequence",
                error.InvalidState => "invalid parser state",
                error.InvalidUtf8 => "invalid UTF-8 sequence",
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

const TestItem = struct {
    tag: Tag,
    value: ?Value = null,

    pub const Tag = enum {
        @"error",

        table_header_start,
        table_header_end,
        table_key,
    };

    pub const Value = union(enum) {
        @"error": Error,

        literal: []const u8,
        string: []const u8,
        literal_string: []const u8,
        int: i64,
        float: f64,
        boolean: bool,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (!builtin.is_test) {
                @compileError("TestItem.Value may only be used in tests");
            }

            try writer.print(".{{ .{t}: ", .{self});

            switch (self) {
                .literal, .string, .literal_string => |s| try writer.print("{s}", .{s}),
                else => |v| try writer.print("{any}", .{v}),
            }

            try writer.writeAll(" }");
        }
    };

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (!builtin.is_test) {
            @compileError("TestItem may only be used in tests");
        }

        try writer.print("{{ tag: .{t}, value: {?f} }}", .{ self.tag, self.value });
    }
};

const NextTestCase = struct {
    buffer: []const u8,
    items: []const ?TestItem,
    toml_version: Version = default_version,
};

const next_test_cases: []const NextTestCase = &.{
    .{
        .buffer = "",
        .items = &.{null},
    },
    .{
        .buffer = "",
        .items = &.{ null, null, null },
    },
    .{
        .buffer = "[a]",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal = "a",
                },
            },
            .{
                .tag = .table_header_end,
            },
            null,
        },
    },
    .{
        .buffer = "[a.b]",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal = "a",
                },
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal = "b",
                },
            },
            .{
                .tag = .table_header_end,
            },
            null,
        },
    },
    .{
        .buffer = "[a.b.c]",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal = "a",
                },
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal = "b",
                },
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal = "c",
                },
            },
            .{
                .tag = .table_header_end,
            },
            null,
        },
    },
    .{
        .buffer = "[\"a\"]",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .table_key,
                .value = .{
                    .string = "\"a\"",
                },
            },
            .{
                .tag = .table_header_end,
            },
            null,
        },
    },
    .{
        .buffer = "['a']",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal_string = "'a'",
                },
            },
            .{
                .tag = .table_header_end,
            },
            null,
        },
    },
    .{
        .buffer = "[a.\"b\".c]",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal = "a",
                },
            },
            .{
                .tag = .table_key,
                .value = .{
                    .string = "\"b\"",
                },
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal = "c",
                },
            },
            .{
                .tag = .table_header_end,
            },
            null,
        },
    },
    .{
        .buffer = "[a.'b'.c]",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal = "a",
                },
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal_string = "'b'",
                },
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal = "c",
                },
            },
            .{
                .tag = .table_header_end,
            },
            null,
        },
    },
    .{
        .buffer = "[a.'b'.\"c\".d]",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal = "a",
                },
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal_string = "'b'",
                },
            },
            .{
                .tag = .table_key,
                .value = .{
                    .string = "\"c\"",
                },
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal = "d",
                },
            },
            .{
                .tag = .table_header_end,
            },
            null,
        },
    },
    .{
        .buffer = "[\"a\".b.'c']",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .table_key,
                .value = .{
                    .string = "\"a\"",
                },
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal = "b",
                },
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal_string = "'c'",
                },
            },
            .{
                .tag = .table_header_end,
            },
            null,
        },
    },
    .{
        .buffer = "[.]",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .@"error",
                .value = .{
                    .@"error" = error.UnexpectedToken,
                },
            },
        },
    },
    .{
        .buffer = "[a.]",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal = "a",
                },
            },
            .{
                .tag = .@"error",
                .value = .{
                    .@"error" = error.UnexpectedToken,
                },
            },
        },
    },
    .{
        .buffer = "[.a]",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .@"error",
                .value = .{
                    .@"error" = error.UnexpectedToken,
                },
            },
        },
    },
    .{
        .buffer = "[a..b]",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal = "a",
                },
            },
            .{
                .tag = .@"error",
                .value = .{
                    .@"error" = error.UnexpectedToken,
                },
            },
        },
    },
    .{
        .buffer = "[\"a\".]",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .table_key,
                .value = .{
                    .string = "\"a\"",
                },
            },
            .{
                .tag = .@"error",
                .value = .{
                    .@"error" = error.UnexpectedToken,
                },
            },
        },
    },
    .{
        .buffer = "[.\"a\"]",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .@"error",
                .value = .{
                    .@"error" = error.UnexpectedToken,
                },
            },
        },
    },
    .{
        .buffer = "[\"a\"..b]",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .table_key,
                .value = .{
                    .string = "\"a\"",
                },
            },
            .{
                .tag = .@"error",
                .value = .{
                    .@"error" = error.UnexpectedToken,
                },
            },
        },
    },
    .{
        .buffer = "[\"a\"..\"b\"]",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .table_key,
                .value = .{
                    .string = "\"a\"",
                },
            },
            .{
                .tag = .@"error",
                .value = .{
                    .@"error" = error.UnexpectedToken,
                },
            },
        },
    },
    .{
        .buffer = "['a'.]",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal_string = "'a'",
                },
            },
            .{
                .tag = .@"error",
                .value = .{
                    .@"error" = error.UnexpectedToken,
                },
            },
        },
    },
    .{
        .buffer = "['a'..b]",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal_string = "'a'",
                },
            },
            .{
                .tag = .@"error",
                .value = .{
                    .@"error" = error.UnexpectedToken,
                },
            },
        },
    },
    .{
        .buffer = "['a'..'b']",
        .items = &.{
            .{
                .tag = .table_header_start,
            },
            .{
                .tag = .table_key,
                .value = .{
                    .literal_string = "'a'",
                },
            },
            .{
                .tag = .@"error",
                .value = .{
                    .@"error" = error.UnexpectedToken,
                },
            },
        },
    },
};

fn convertItem(src: ?Item) ?TestItem {
    if (!builtin.is_test) {
        @compileError("convertItem may only be used in tests");
    }

    if (src == null) {
        return null;
    }

    return .{
        .tag = blk: switch (src.?.tag) {
            inline else => |tag| {
                const field_name = @tagName(tag);
                if (!@hasField(Item.Tag, field_name)) {
                    @compileError("invalid Item.Tag field name: " ++ field_name);
                }

                break :blk std.meta.stringToEnum(TestItem.Tag, field_name).?;
            },
        },
        .value = blk: {
            if (src.?.value == null) {
                break :blk null;
            }

            switch (src.?.value.?) {
                inline else => |payload, tag| {
                    const field_name = @tagName(tag);
                    if (!@hasField(Item.Value, field_name)) {
                        @compileError("invalid Item.Value field name: " ++ field_name);
                    }

                    break :blk @unionInit(TestItem.Value, field_name, payload);
                },
            }
        },
    };
}

test next {
    for (next_test_cases) |case| {
        var items: std.ArrayList(u8) = .empty;
        defer items.deinit(std.testing.allocator);

        errdefer std.debug.print("collected items: {s}\n", .{items.items});
        errdefer std.debug.print("failing test case: {s}\n", .{case.buffer});

        var tokenizer: Tokenizer = .init(case.buffer, .{ .toml_version = case.toml_version });
        var parser = init(&tokenizer, .{ .toml_version = case.toml_version });

        for (case.items) |expected| {
            if (expected == null) {
                try std.testing.expectEqual(null, try parser.next());
                items.appendSlice(std.testing.allocator, "\nnull,") catch @panic("OOM");
            } else {
                switch (expected.?.tag) {
                    .@"error" => {
                        try std.testing.expectError(expected.?.value.?.@"error", parser.next());
                        try std.testing.expectEqual(State.invalid, parser.state);
                        try std.testing.expectEqual(null, parser.token);
                        try std.testing.expectError(error.InvalidState, parser.next());
                        try std.testing.expectEqual(State.invalid, parser.state);
                        try std.testing.expectEqual(null, parser.token);
                    },
                    else => {
                        const actual = convertItem(try parser.next());
                        var buf: [128]u8 = undefined;
                        items.appendSlice(
                            std.testing.allocator,
                            std.fmt.bufPrint(&buf, "\n{f},", .{actual.?}) catch @panic("overflow"),
                        ) catch @panic("OOM");
                        try std.testing.expectEqualDeep(expected, actual);
                    },
                }
            }
        }
    }
}
