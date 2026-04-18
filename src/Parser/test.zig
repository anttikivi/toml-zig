// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const builtin = @import("builtin");
const std = @import("std");

const Parser = @import("../Parser.zig");
const Error = Parser.Error;
const Item = Parser.Item;
const State = Parser.State;
const Span = @import("../root.zig").Span;
const Date = @import("../value.zig").Date;
const Time = @import("../value.zig").Time;
const Datetime = @import("../value.zig").Datetime;
const default_version = @import("../toml.zig").default_version;
const Float = @import("../toml.zig").Float;
const Int = @import("../toml.zig").Int;
const Version = @import("../toml.zig").Version;

const TestItem = struct {
    tag: Tag,
    span: Span = undefined,
    value: ?Value = null,

    pub const Tag = enum {
        @"error",

        table_header_start,
        table_header_end,
        table_key,
        array_table_header_start,
        array_table_header_end,
        array_table_key,
        key,
        value,
        array_start,
        array_end,
        inline_table_start,
        inline_table_end,
    };

    pub const Value = union(enum) {
        @"error": Error,

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

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (!builtin.is_test) {
                @compileError("TestItem.Value may only be used in tests");
            }

            switch (self) {
                .literal, .string, .literal_string => |s| {
                    try writer.print(".{{ .{t}: ", .{self});
                    try writer.print("{s}", .{s});
                    try writer.writeAll(" }");
                },
                else => |v| try writer.print("{any}", .{v}),
            }
        }
    };

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (!builtin.is_test) {
            @compileError("TestItem may only be used in tests");
        }

        try writer.print("{{ tag: .{t}, span: {any}, value: {?f} }}", .{
            self.tag,
            self.span,
            self.value,
        });
    }
};

const TestCase = struct {
    buffer: []const u8,
    items: []const ?TestItem,
    toml_version: Version = default_version,
};

fn expectedTag(tag: TestItem.Tag) ?Item.Tag {
    if (tag == .@"error") {
        return null;
    }

    return std.meta.stringToEnum(Item.Tag, @tagName(tag)).?;
}

fn expectedValueTag(value: TestItem.Value) std.meta.Tag(Item.Value) {
    return std.meta.stringToEnum(std.meta.Tag(Item.Value), @tagName(std.meta.activeTag(value))).?;
}

fn expectedSyntaxToken(tag: Item.Tag) ?[]const u8 {
    return switch (tag) {
        .table_header_start, .array_start => "[",
        .table_header_end, .array_end => "]",
        .array_table_header_start => "[[",
        .array_table_header_end => "]]",
        .inline_table_start => "{",
        .inline_table_end => "}",
        else => null,
    };
}

const test_cases: []const TestCase = &.{
    .{
        .buffer = "",
        .items = &.{null},
    },
    .{
        .buffer = "",
        .items = &.{ null, null, null },
    },
};

const table_header_cases: []const TestCase = &.{
    .{
        .buffer = "[a]",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .table_header_end,
                .span = .{ .start = 2, .end = 3 },
            },
            null,
        },
    },
    .{
        .buffer = "[a.b]",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 3, .end = 4 },
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .table_header_end,
                .span = .{ .start = 4, .end = 5 },
            },
            null,
        },
    },
    .{
        .buffer = "[a.b.c]",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 3, .end = 4 },
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 5, .end = 6 },
                .value = .{ .literal = "c" },
            },
            .{
                .tag = .table_header_end,
                .span = .{ .start = 6, .end = 7 },
            },
            null,
        },
    },
    .{
        .buffer = "[\"a\"]",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 2, .end = 3 },
                .value = .{ .string = "a" },
            },
            .{
                .tag = .table_header_end,
                .span = .{ .start = 4, .end = 5 },
            },
            null,
        },
    },
    .{
        .buffer = "['a']",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 2, .end = 3 },
                .value = .{ .literal_string = "a" },
            },
            .{
                .tag = .table_header_end,
                .span = .{ .start = 4, .end = 5 },
            },
            null,
        },
    },
    .{
        .buffer = "[a.\"b\".c]",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 4, .end = 5 },
                .value = .{ .string = "b" },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 7, .end = 8 },
                .value = .{ .literal = "c" },
            },
            .{
                .tag = .table_header_end,
                .span = .{ .start = 8, .end = 9 },
            },
            null,
        },
    },
    .{
        .buffer = "[a.'b'.c]",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 4, .end = 5 },
                .value = .{ .literal_string = "b" },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 7, .end = 8 },
                .value = .{ .literal = "c" },
            },
            .{
                .tag = .table_header_end,
                .span = .{ .start = 8, .end = 9 },
            },
            null,
        },
    },
    .{
        .buffer = "[a.'b'.\"c\".d]",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 4, .end = 5 },
                .value = .{ .literal_string = "b" },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 8, .end = 9 },
                .value = .{ .string = "c" },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 11, .end = 12 },
                .value = .{ .literal = "d" },
            },
            .{
                .tag = .table_header_end,
                .span = .{ .start = 12, .end = 13 },
            },
            null,
        },
    },
    .{
        .buffer = "[\"a\".b.'c']",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 2, .end = 3 },
                .value = .{ .string = "a" },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 5, .end = 6 },
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 8, .end = 9 },
                .value = .{ .literal_string = "c" },
            },
            .{
                .tag = .table_header_end,
                .span = .{ .start = 10, .end = 11 },
            },
            null,
        },
    },
    .{
        .buffer = "[.]",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "[a.]",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "[.a]",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "[a..b]",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "[\"a\".]",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 2, .end = 3 },
                .value = .{ .string = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "[.\"a\"]",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "[\"a\"..b]",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 2, .end = 3 },
                .value = .{ .string = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "[\"a\"..\"b\"]",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 2, .end = 3 },
                .value = .{ .string = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "['a'.]",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 2, .end = 3 },
                .value = .{ .literal_string = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "['a'..b]",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 2, .end = 3 },
                .value = .{ .literal_string = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "['a'..'b']",
        .items = &.{
            .{
                .tag = .table_header_start,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .table_key,
                .span = .{ .start = 2, .end = 3 },
                .value = .{ .literal_string = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
};

const array_table_header_cases: []const TestCase = &.{
    .{
        .buffer = "[[a]]",
        .items = &.{
            .{ .tag = .array_table_header_start, .span = .{ .start = 0, .end = 2 } },
            .{
                .tag = .array_table_key,
                .span = .{ .start = 2, .end = 3 },
                .value = .{ .literal = "a" },
            },
            .{ .tag = .array_table_header_end, .span = .{ .start = 3, .end = 5 } },
            null,
        },
    },
    .{
        .buffer = "[[a.b]]",
        .items = &.{
            .{ .tag = .array_table_header_start, .span = .{ .start = 0, .end = 2 } },
            .{
                .tag = .array_table_key,
                .span = .{ .start = 2, .end = 3 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .array_table_key,
                .span = .{ .start = 4, .end = 5 },
                .value = .{ .literal = "b" },
            },
            .{ .tag = .array_table_header_end, .span = .{ .start = 5, .end = 7 } },
            null,
        },
    },
    .{
        .buffer = "[[\"a\".'b']]",
        .items = &.{
            .{ .tag = .array_table_header_start, .span = .{ .start = 0, .end = 2 } },
            .{
                .tag = .array_table_key,
                .span = .{ .start = 3, .end = 4 },
                .value = .{ .string = "a" },
            },
            .{
                .tag = .array_table_key,
                .span = .{ .start = 7, .end = 8 },
                .value = .{ .literal_string = "b" },
            },
            .{ .tag = .array_table_header_end, .span = .{ .start = 9, .end = 11 } },
            null,
        },
    },
    .{
        .buffer = "[[a.]]",
        .items = &.{
            .{ .tag = .array_table_header_start, .span = .{ .start = 0, .end = 2 } },
            .{
                .tag = .array_table_key,
                .span = .{ .start = 2, .end = 3 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "[[a",
        .items = &.{
            .{ .tag = .array_table_header_start, .span = .{ .start = 0, .end = 2 } },
            .{
                .tag = .array_table_key,
                .span = .{ .start = 2, .end = 3 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnterminatedHeader },
            },
        },
    },
};

const key_value_cases: []const TestCase = &.{
    .{
        .buffer = "a = \"b\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 1 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 5, .end = 6 },
                .value = .{ .string = "b" },
            },
            null,
        },
    },
    .{
        .buffer = "a.b = \"cde\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 1 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 2, .end = 3 },
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 7, .end = 10 },
                .value = .{ .string = "cde" },
            },
            null,
        },
    },
    .{
        .buffer = "a.b.c = \"def\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 1 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 2, .end = 3 },
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 4, .end = 5 },
                .value = .{ .literal = "c" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 9, .end = 12 },
                .value = .{ .string = "def" },
            },
            null,
        },
    },
    .{
        .buffer = "\"a\" = \"bcd\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .string = "a" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 7, .end = 10 },
                .value = .{ .string = "bcd" },
            },
            null,
        },
    },
    .{
        .buffer = "\"a\".b = \"cde\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .string = "a" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 4, .end = 5 },
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 9, .end = 12 },
                .value = .{ .string = "cde" },
            },
            null,
        },
    },
    .{
        .buffer = "a.\"b\" = \"cde\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 1 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 3, .end = 4 },
                .value = .{ .string = "b" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 9, .end = 12 },
                .value = .{ .string = "cde" },
            },
            null,
        },
    },
    .{
        .buffer = "\"a\".\"b\" = \"cde\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .string = "a" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 5, .end = 6 },
                .value = .{ .string = "b" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 11, .end = 14 },
                .value = .{ .string = "cde" },
            },
            null,
        },
    },
    .{
        .buffer = "\"a\".b.\"c\" = \"def\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .string = "a" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 4, .end = 5 },
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 7, .end = 8 },
                .value = .{ .string = "c" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 13, .end = 16 },
                .value = .{ .string = "def" },
            },
            null,
        },
    },
    .{
        .buffer = "a.\"b\".c = \"def\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 1 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 3, .end = 4 },
                .value = .{ .string = "b" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 6, .end = 7 },
                .value = .{ .literal = "c" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 11, .end = 14 },
                .value = .{ .string = "def" },
            },
            null,
        },
    },
    .{
        .buffer = "'a' = \"bcd\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .literal_string = "a" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 7, .end = 10 },
                .value = .{ .string = "bcd" },
            },
            null,
        },
    },
    .{
        .buffer = "'a'.'b' = \"cde\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .literal_string = "a" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 5, .end = 6 },
                .value = .{ .literal_string = "b" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 11, .end = 14 },
                .value = .{ .string = "cde" },
            },
            null,
        },
    },
    .{
        .buffer = "'a'.b = \"cde\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .literal_string = "a" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 4, .end = 5 },
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 9, .end = 12 },
                .value = .{ .string = "cde" },
            },
            null,
        },
    },
    .{
        .buffer = "a.'b' = \"cde\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 1 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 3, .end = 4 },
                .value = .{ .literal_string = "b" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 9, .end = 12 },
                .value = .{ .string = "cde" },
            },
            null,
        },
    },
    .{
        .buffer = "'a'.b.'c' = \"def\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .literal_string = "a" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 4, .end = 5 },
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 7, .end = 8 },
                .value = .{ .literal_string = "c" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 13, .end = 16 },
                .value = .{ .string = "def" },
            },
            null,
        },
    },
    .{
        .buffer = "a.'b'.c = \"def\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 1 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 3, .end = 4 },
                .value = .{ .literal_string = "b" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 6, .end = 7 },
                .value = .{ .literal = "c" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 11, .end = 14 },
                .value = .{ .string = "def" },
            },
            null,
        },
    },
    .{
        .buffer = "'a'.\"b\".c = \"def\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .literal_string = "a" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 5, .end = 6 },
                .value = .{ .string = "b" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 8, .end = 9 },
                .value = .{ .literal = "c" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 13, .end = 16 },
                .value = .{ .string = "def" },
            },
            null,
        },
    },
    .{
        .buffer = ". = \"cde\"",
        .items = &.{
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "a. = \"cde\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 1 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = ".a = \"cde\"",
        .items = &.{
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "a..b = \"cde\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 1 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "\"a\". = \"cde\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .string = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = ".\"a\" = \"cde\"",
        .items = &.{
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "\"a\"..b = \"cde\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .string = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "\"a\"..\"b\" = \"cde\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .string = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "'a'. = \"cde\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .literal_string = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = ".'a' = \"cde\"",
        .items = &.{
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "'a'..b = \"cde\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .literal_string = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "'a'..'b' = \"cde\"",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 2 },
                .value = .{ .literal_string = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
};

const bool_cases: []const TestCase = &.{
    .{
        .buffer = "bool = true",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "bool" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 7, .end = 11 },
                .value = .{ .boolean = true },
            },
            null,
        },
    },
    .{
        .buffer = "bool = false",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "bool" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 7, .end = 12 },
                .value = .{ .boolean = false },
            },
            null,
        },
    },
    .{
        .buffer = "bool=true",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "bool" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 5, .end = 9 },
                .value = .{ .boolean = true },
            },
            null,
        },
    },
    .{
        .buffer = "bool\t=\ttrue",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "bool" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 7, .end = 11 },
                .value = .{ .boolean = true },
            },
            null,
        },
    },
    .{
        .buffer = "bool   =true     ",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "bool" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 12 },
                .value = .{ .boolean = true },
            },
            null,
        },
    },
    .{
        .buffer = "bool=   true\t",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "bool" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 12 },
                .value = .{ .boolean = true },
            },
            null,
        },
    },
    .{
        .buffer =
        \\
        \\bool = true
        \\
        ,
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 5 },
                .value = .{ .literal = "bool" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 12 },
                .value = .{ .boolean = true },
            },
            null,
        },
    },
};

const datetime_cases: []const TestCase = &.{
    .{
        .buffer = "dt = 1979-05-27T07:32:45Z",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 5, .end = 25 },
                .value = .{
                    .datetime = .{
                        .year = 1979,
                        .month = 5,
                        .day = 27,
                        .hour = 7,
                        .minute = 32,
                        .second = 45,
                        .tz = 0,
                    },
                },
            },
            null,
        },
    },
    .{
        .buffer = "dt = 1979-05-27 07:32:45Z",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 5, .end = 25 },
                .value = .{
                    .datetime = .{
                        .year = 1979,
                        .month = 5,
                        .day = 27,
                        .hour = 7,
                        .minute = 32,
                        .second = 45,
                        .tz = 0,
                    },
                },
            },
            null,
        },
    },
    .{
        .buffer = "dt = 1979-05-27 07:32:45",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 5, .end = 24 },
                .value = .{
                    .local_datetime = .{
                        .year = 1979,
                        .month = 5,
                        .day = 27,
                        .hour = 7,
                        .minute = 32,
                        .second = 45,
                    },
                },
            },
            null,
        },
    },
    .{
        .buffer = "dt = 1979-05-27\t07:32:45Z",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidDatetime },
            },
        },
    },
    .{
        .buffer = "dt = 1979-05-27  07:32:45Z",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidDatetime },
            },
        },
    },
    .{
        .buffer = "dt = 1979-05-27 07:32:45.23",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 5, .end = 27 },
                .value = .{
                    .local_datetime = .{
                        .year = 1979,
                        .month = 5,
                        .day = 27,
                        .hour = 7,
                        .minute = 32,
                        .second = 45,
                        .nano = 230000000,
                    },
                },
            },
            null,
        },
    },
    .{
        .buffer = "dt = 1979-05-27 07:32:45.23-07:00",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 5, .end = 33 },
                .value = .{
                    .datetime = .{
                        .year = 1979,
                        .month = 5,
                        .day = 27,
                        .hour = 7,
                        .minute = 32,
                        .second = 45,
                        .nano = 230000000,
                        .tz = -420,
                    },
                },
            },
            null,
        },
    },
    .{
        .buffer = "dt = 1979-05-27 07:32:45-11:23",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 5, .end = 30 },
                .value = .{
                    .datetime = .{
                        .year = 1979,
                        .month = 5,
                        .day = 27,
                        .hour = 7,
                        .minute = 32,
                        .second = 45,
                        .tz = -683,
                    },
                },
            },
            null,
        },
    },
    .{
        .buffer = "dt = 1979-05-27 07:32:45.23+07:00",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 5, .end = 33 },
                .value = .{
                    .datetime = .{
                        .year = 1979,
                        .month = 5,
                        .day = 27,
                        .hour = 7,
                        .minute = 32,
                        .second = 45,
                        .nano = 230000000,
                        .tz = 420,
                    },
                },
            },
            null,
        },
    },
    .{
        .buffer = "dt = 1979-05-27 07:32:45+11:23",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 5, .end = 30 },
                .value = .{
                    .datetime = .{
                        .year = 1979,
                        .month = 5,
                        .day = 27,
                        .hour = 7,
                        .minute = 32,
                        .second = 45,
                        .tz = 683,
                    },
                },
            },
            null,
        },
    },
    .{
        .buffer = "date = 1979-05-27",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "date" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 7, .end = 17 },
                .value = .{
                    .local_date = .{
                        .year = 1979,
                        .month = 5,
                        .day = 27,
                    },
                },
            },
            null,
        },
    },
    .{
        .buffer = "date = 1979-00-27",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "date" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidDatetime },
            },
        },
    },
    .{
        .buffer = "date = 1979-13-27",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "date" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidDatetime },
            },
        },
    },
    .{
        .buffer = "date = 1979-02-30",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "date" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidDatetime },
            },
        },
    },
    .{
        .buffer = "dt = 1979-05-27T07:32Z",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 5, .end = 22 },
                .value = .{
                    .datetime = .{
                        .year = 1979,
                        .month = 5,
                        .day = 27,
                        .hour = 7,
                        .minute = 32,
                        .second = 0,
                        .tz = 0,
                    },
                },
            },
            null,
        },
    },
    .{
        .buffer = "dt = 1979-05-27T07:32Z",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidDatetime },
            },
        },
        .toml_version = .@"1.0.0",
    },
    .{
        .buffer = "dt = 1979-05-27T07:32",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 5, .end = 21 },
                .value = .{
                    .local_datetime = .{
                        .year = 1979,
                        .month = 5,
                        .day = 27,
                        .hour = 7,
                        .minute = 32,
                        .second = 0,
                    },
                },
            },
            null,
        },
    },
    .{
        .buffer = "dt = 1979-05-27T07:32",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidDatetime },
            },
        },
        .toml_version = .@"1.0.0",
    },
    .{
        .buffer = "dt = 1979-05-27T07:32-07:00",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 5, .end = 27 },
                .value = .{
                    .datetime = .{
                        .year = 1979,
                        .month = 5,
                        .day = 27,
                        .hour = 7,
                        .minute = 32,
                        .second = 0,
                        .tz = -420,
                    },
                },
            },
            null,
        },
    },
    .{
        .buffer = "dt = 1979-05-27T07:32-07:00",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidDatetime },
            },
        },
        .toml_version = .@"1.0.0",
    },
    .{
        .buffer = "dt = 1979-05-27T24:00:00Z",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidDatetime },
            },
        },
    },
    .{
        .buffer = "dt = 1979-05-27T07:60:00Z",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidDatetime },
            },
        },
    },
    .{
        .buffer = "dt = 1979-05-27T07:32:60Z",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 5, .end = 25 },
                .value = .{
                    .datetime = .{
                        .year = 1979,
                        .month = 5,
                        .day = 27,
                        .hour = 7,
                        .minute = 32,
                        .second = 60,
                        .tz = 0,
                    },
                },
            },
            null,
        },
    },
    .{
        .buffer = "dt = 1979-05-27T07:32:61Z",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidDatetime },
            },
        },
    },
    .{
        .buffer = "dt = 1979-05-27T07:32.23-07:00",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidDatetime },
            },
        },
    },
    .{
        .buffer = "dt = 1979-05-27T07:32.23",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 2 },
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidDatetime },
            },
        },
    },
    .{
        .buffer = "time = 07:32:45Z",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "time" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidTime },
            },
        },
    },
    .{
        .buffer = "time = 07:32:45abc",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "time" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidTime },
            },
        },
    },
    .{
        .buffer = "time = 07:32:45.",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "time" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidTime },
            },
        },
    },
    .{
        .buffer = "time = 07:32:45",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "time" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 7, .end = 15 },
                .value = .{
                    .local_time = .{
                        .hour = 7,
                        .minute = 32,
                        .second = 45,
                    },
                },
            },
            null,
        },
    },
    .{
        .buffer = "time = 24:00:00",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "time" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidTime },
            },
        },
    },
    .{
        .buffer = "time = 07:60:00",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "time" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidTime },
            },
        },
    },
    .{
        .buffer = "time = 07:32:60",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "time" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 7, .end = 15 },
                .value = .{
                    .local_time = .{
                        .hour = 7,
                        .minute = 32,
                        .second = 60,
                    },
                },
            },
            null,
        },
    },
    .{
        .buffer = "time = 07:32:61",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "time" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidTime },
            },
        },
    },
    .{
        .buffer = "time = 07:32:00",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "time" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 7, .end = 15 },
                .value = .{
                    .local_time = .{
                        .hour = 7,
                        .minute = 32,
                        .second = 0,
                    },
                },
            },
            null,
        },
    },
    .{
        .buffer = "time = 07:32:45.1234",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "time" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 7, .end = 20 },
                .value = .{
                    .local_time = .{
                        .hour = 7,
                        .minute = 32,
                        .second = 45,
                        .nano = 123400000,
                    },
                },
            },
            null,
        },
    },
    .{
        .buffer = "time = 07:32.1234",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "time" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidTime },
            },
        },
    },
    .{
        .buffer = "time = 07:32",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "time" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 7, .end = 12 },
                .value = .{
                    .local_time = .{
                        .hour = 7,
                        .minute = 32,
                        .second = 0,
                    },
                },
            },
            null,
        },
    },
    .{
        .buffer = "time = 07:32",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 4 },
                .value = .{ .literal = "time" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidTime },
            },
        },
        .toml_version = .@"1.0.0",
    },
};

const int_cases: []const TestCase = &.{
    .{
        .buffer = "int = 0",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 6, .end = 7 },
                .value = .{ .int = 0 },
            },
            null,
        },
    },
    .{
        .buffer = "int = 123",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 6, .end = 9 },
                .value = .{ .int = 123 },
            },
            null,
        },
    },
    .{
        .buffer = "int = 123_456",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 6, .end = 13 },
                .value = .{ .int = 123456 },
            },
            null,
        },
    },
    .{
        .buffer = "int = +123",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 6, .end = 10 },
                .value = .{ .int = 123 },
            },
            null,
        },
    },
    .{
        .buffer = "int = -456",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 6, .end = 10 },
                .value = .{ .int = -456 },
            },
            null,
        },
    },
    .{
        .buffer = "int = -0",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 6, .end = 8 },
                .value = .{ .int = 0 },
            },
            null,
        },
    },
    .{
        .buffer = "int = 0b11010110",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 6, .end = 16 },
                .value = .{ .int = 214 },
            },
            null,
        },
    },
    .{
        .buffer = "int = 0B11010110",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "int = 0o01234567",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 6, .end = 16 },
                .value = .{ .int = 342391 },
            },
            null,
        },
    },
    .{
        .buffer = "int = 0O01234567",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "int = 0xdead_beef",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 6, .end = 17 },
                .value = .{ .int = 3735928559 },
            },
            null,
        },
    },
    .{
        .buffer = "int = 0Xdead_beef",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "int = 9223372036854775807",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 6, .end = 25 },
                .value = .{ .int = std.math.maxInt(Int) },
            },
            null,
        },
    },
    .{
        .buffer = "int = -9223372036854775808",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 6, .end = 26 },
                .value = .{ .int = std.math.minInt(Int) },
            },
            null,
        },
    },
    .{
        .buffer = "int = 0123",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "int = +0123",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "int = -0123",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "int = 1__23",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "int = 0b_1",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "int = 0b",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "int = 0o_7",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "int = 0o",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "int = 0xdead__beef",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "int = 0x",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "int = 0x_1",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "int = +0xdead_beef",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "int = -0xdead_beef",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "int = 9223372036854775808",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.Overflow },
            },
        },
    },
    .{
        .buffer = "int = -9223372036854775809",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 3 },
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.Overflow },
            },
        },
    },
};

const float_cases: []const TestCase = &.{
    .{
        .buffer = "float = 0.0",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 11 },
                .value = .{ .float = 0 },
            },
            null,
        },
    },
    .{
        .buffer = "float = 1.0",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 11 },
                .value = .{ .float = 1 },
            },
            null,
        },
    },
    .{
        .buffer = "float = +1.0",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 12 },
                .value = .{ .float = 1 },
            },
            null,
        },
    },
    .{
        .buffer = "float = 1.1",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 11 },
                .value = .{ .float = 1.1 },
            },
            null,
        },
    },
    .{
        .buffer = "float = 2.3456789",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 17 },
                .value = .{ .float = 2.3456789 },
            },
            null,
        },
    },
    .{
        .buffer = "float = 0.29375927359253",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 24 },
                .value = .{ .float = 0.29375927359253 },
            },
            null,
        },
    },
    .{
        .buffer = "float = 1234e-2",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 15 },
                .value = .{ .float = 12.34 },
            },
            null,
        },
    },
    .{
        .buffer = "float = 1e2",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 11 },
                .value = .{ .float = 100 },
            },
            null,
        },
    },
    .{
        .buffer = "float = 1e+2",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 12 },
                .value = .{ .float = 100 },
            },
            null,
        },
    },
    .{
        .buffer = "float = 1E2",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 11 },
                .value = .{ .float = 100 },
            },
            null,
        },
    },
    .{
        .buffer = "float = 1_000.5",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 15 },
                .value = .{ .float = 1000.5 },
            },
            null,
        },
    },
    .{
        .buffer = "float = 1e1_0",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 13 },
                .value = .{ .float = 10000000000 },
            },
            null,
        },
    },
    .{
        .buffer = "float = -0.0",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 12 },
                .value = .{ .float = -0.0 },
            },
            null,
        },
    },
    .{
        .buffer = "float = -1.0",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 12 },
                .value = .{ .float = -1 },
            },
            null,
        },
    },
    .{
        .buffer = "float = -1.1",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 12 },
                .value = .{ .float = -1.1 },
            },
            null,
        },
    },
    .{
        .buffer = "float = -2.3456789",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 18 },
                .value = .{ .float = -2.3456789 },
            },
            null,
        },
    },
    .{
        .buffer = "float = -0.29375927359253",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 25 },
                .value = .{ .float = -0.29375927359253 },
            },
            null,
        },
    },
    .{
        .buffer = "float = -1234e-2",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 16 },
                .value = .{ .float = -12.34 },
            },
            null,
        },
    },
    .{
        .buffer = "float = inf",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 11 },
                .value = .{ .float = std.math.inf(Float) },
            },
            null,
        },
    },
    .{
        .buffer = "float = +inf",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 12 },
                .value = .{ .float = std.math.inf(Float) },
            },
            null,
        },
    },
    .{
        .buffer = "float = -inf",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 12 },
                .value = .{ .float = -std.math.inf(Float) },
            },
            null,
        },
    },
    .{
        .buffer = "float = nan",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 11 },
                .value = .{ .float = std.math.nan(Float) },
            },
            null,
        },
    },
    .{
        .buffer = "float = +nan",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 12 },
                .value = .{ .float = std.math.nan(Float) },
            },
            null,
        },
    },
    .{
        .buffer = "float = -nan",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 8, .end = 12 },
                .value = .{ .float = -std.math.nan(Float) },
            },
            null,
        },
    },
    .{
        .buffer = "float = 1.",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "float = 01.2",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "float = -01.2",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "float = .1",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "float = 1e",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "float = 01e2",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "float = -01e2",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "float = 1e_",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "float = 1e+",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "float = 1e-",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "float = 1E12__1",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "float = 1_.0",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "float = 1._0",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
    .{
        .buffer = "float = 1.1.1",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
            },
        },
    },
};

const array_cases: []const TestCase = &.{
    .{
        .buffer = "array = [\"hello\", 13, true]",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "array" },
            },
            .{ .tag = .array_start, .span = .{ .start = 8, .end = 9 } },
            .{
                .tag = .value,
                .span = .{ .start = 10, .end = 15 },
                .value = .{ .string = "hello" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 18, .end = 20 },
                .value = .{ .int = 13 },
            },
            .{
                .tag = .value,
                .span = .{ .start = 22, .end = 26 },
                .value = .{ .boolean = true },
            },
            .{ .tag = .array_end, .span = .{ .start = 26, .end = 27 } },
            null,
        },
    },
    .{
        .buffer = "array = []",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "array" },
            },
            .{ .tag = .array_start, .span = .{ .start = 8, .end = 9 } },
            .{ .tag = .array_end, .span = .{ .start = 9, .end = 10 } },
            null,
        },
    },
    .{
        .buffer = "array = [1,]",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "array" },
            },
            .{ .tag = .array_start, .span = .{ .start = 8, .end = 9 } },
            .{
                .tag = .value,
                .span = .{ .start = 9, .end = 10 },
                .value = .{ .int = 1 },
            },
            .{ .tag = .array_end, .span = .{ .start = 11, .end = 12 } },
            null,
        },
    },
    .{
        .buffer = "array = [[1], [2, 3]]",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "array" },
            },
            .{ .tag = .array_start, .span = .{ .start = 8, .end = 9 } },
            .{ .tag = .array_start, .span = .{ .start = 9, .end = 10 } },
            .{
                .tag = .value,
                .span = .{ .start = 10, .end = 11 },
                .value = .{ .int = 1 },
            },
            .{ .tag = .array_end, .span = .{ .start = 11, .end = 12 } },
            .{ .tag = .array_start, .span = .{ .start = 14, .end = 15 } },
            .{
                .tag = .value,
                .span = .{ .start = 15, .end = 16 },
                .value = .{ .int = 2 },
            },
            .{
                .tag = .value,
                .span = .{ .start = 18, .end = 19 },
                .value = .{ .int = 3 },
            },
            .{ .tag = .array_end, .span = .{ .start = 19, .end = 20 } },
            .{ .tag = .array_end, .span = .{ .start = 20, .end = 21 } },
            null,
        },
    },
    .{
        .buffer = "array = [[]]",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "array" },
            },
            .{ .tag = .array_start, .span = .{ .start = 8, .end = 9 } },
            .{ .tag = .array_start, .span = .{ .start = 9, .end = 10 } },
            .{ .tag = .array_end, .span = .{ .start = 10, .end = 11 } },
            .{ .tag = .array_end, .span = .{ .start = 11, .end = 12 } },
            null,
        },
    },
    .{
        .buffer =
        \\
        \\array = [
        \\  []
        \\]
        ,
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 6 },
                .value = .{ .literal = "array" },
            },
            .{ .tag = .array_start, .span = .{ .start = 9, .end = 10 } },
            .{ .tag = .array_start, .span = .{ .start = 13, .end = 14 } },
            .{ .tag = .array_end, .span = .{ .start = 14, .end = 15 } },
            .{ .tag = .array_end, .span = .{ .start = 16, .end = 17 } },
            null,
        },
    },
    .{
        .buffer =
        \\
        \\array = [
        \\  [
        \\]]
        ,
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 6 },
                .value = .{ .literal = "array" },
            },
            .{ .tag = .array_start, .span = .{ .start = 9, .end = 10 } },
            .{ .tag = .array_start, .span = .{ .start = 13, .end = 14 } },
            .{ .tag = .array_end, .span = .{ .start = 15, .end = 16 } },
            .{ .tag = .array_end, .span = .{ .start = 16, .end = 17 } },
            null,
        },
    },
    .{
        .buffer =
        \\
        \\array = [
        \\  [1
        \\  ]
        \\]
        ,
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 6 },
                .value = .{ .literal = "array" },
            },
            .{ .tag = .array_start, .span = .{ .start = 9, .end = 10 } },
            .{ .tag = .array_start, .span = .{ .start = 13, .end = 14 } },
            .{
                .tag = .value,
                .span = .{ .start = 14, .end = 15 },
                .value = .{ .int = 1 },
            },
            .{ .tag = .array_end, .span = .{ .start = 18, .end = 19 } },
            .{ .tag = .array_end, .span = .{ .start = 20, .end = 21 } },
            null,
        },
    },
    .{
        .buffer =
        \\
        \\array = [
        \\  [1],
        \\  [2
        \\  ]
        \\]
        ,
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 6 },
                .value = .{ .literal = "array" },
            },
            .{ .tag = .array_start, .span = .{ .start = 9, .end = 10 } },
            .{ .tag = .array_start, .span = .{ .start = 13, .end = 14 } },
            .{
                .tag = .value,
                .span = .{ .start = 14, .end = 15 },
                .value = .{ .int = 1 },
            },
            .{ .tag = .array_end, .span = .{ .start = 15, .end = 16 } },
            .{ .tag = .array_start, .span = .{ .start = 20, .end = 21 } },
            .{
                .tag = .value,
                .span = .{ .start = 21, .end = 22 },
                .value = .{ .int = 2 },
            },
            .{ .tag = .array_end, .span = .{ .start = 25, .end = 26 } },
            .{ .tag = .array_end, .span = .{ .start = 27, .end = 28 } },
            null,
        },
    },
    .{
        .buffer = "array = [[],]",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "array" },
            },
            .{ .tag = .array_start, .span = .{ .start = 8, .end = 9 } },
            .{ .tag = .array_start, .span = .{ .start = 9, .end = 10 } },
            .{ .tag = .array_end, .span = .{ .start = 10, .end = 11 } },
            .{ .tag = .array_end, .span = .{ .start = 12, .end = 13 } },
            null,
        },
    },
    .{
        .buffer =
        \\
        \\array = ["hello",
        \\  13,
        \\  true,
        \\]
        ,
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 6 },
                .value = .{ .literal = "array" },
            },
            .{ .tag = .array_start, .span = .{ .start = 9, .end = 10 } },
            .{
                .tag = .value,
                .span = .{ .start = 11, .end = 16 },
                .value = .{ .string = "hello" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 21, .end = 23 },
                .value = .{ .int = 13 },
            },
            .{
                .tag = .value,
                .span = .{ .start = 27, .end = 31 },
                .value = .{ .boolean = true },
            },
            .{ .tag = .array_end, .span = .{ .start = 33, .end = 34 } },
            null,
        },
    },
    .{
        .buffer = "array = [1979-05-27, 07:32:45, 1979-05-27T07:32:45Z]",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "array" },
            },
            .{ .tag = .array_start, .span = .{ .start = 8, .end = 9 } },
            .{
                .tag = .value,
                .span = .{ .start = 9, .end = 19 },
                .value = .{
                    .local_date = .{
                        .year = 1979,
                        .month = 5,
                        .day = 27,
                    },
                },
            },
            .{
                .tag = .value,
                .span = .{ .start = 21, .end = 29 },
                .value = .{
                    .local_time = .{
                        .hour = 7,
                        .minute = 32,
                        .second = 45,
                    },
                },
            },
            .{
                .tag = .value,
                .span = .{ .start = 31, .end = 51 },
                .value = .{
                    .datetime = .{
                        .year = 1979,
                        .month = 5,
                        .day = 27,
                        .hour = 7,
                        .minute = 32,
                        .second = 45,
                        .tz = 0,
                    },
                },
            },
            .{ .tag = .array_end, .span = .{ .start = 51, .end = 52 } },
            null,
        },
    },
    .{
        .buffer = "array = [1 2]",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "array" },
            },
            .{ .tag = .array_start, .span = .{ .start = 8, .end = 9 } },
            .{
                .tag = .value,
                .span = .{ .start = 9, .end = 10 },
                .value = .{ .int = 1 },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "array = [1,,2]",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "array" },
            },
            .{ .tag = .array_start, .span = .{ .start = 8, .end = 9 } },
            .{
                .tag = .value,
                .span = .{ .start = 9, .end = 10 },
                .value = .{ .int = 1 },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "array = [1",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "array" },
            },
            .{ .tag = .array_start, .span = .{ .start = 8, .end = 9 } },
            .{
                .tag = .value,
                .span = .{ .start = 9, .end = 10 },
                .value = .{ .int = 1 },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedEnd },
            },
        },
    },
    .{
        .buffer =
        \\
        \\array = [1
        \\2]
        ,
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 6 },
                .value = .{ .literal = "array" },
            },
            .{ .tag = .array_start, .span = .{ .start = 9, .end = 10 } },
            .{
                .tag = .value,
                .span = .{ .start = 10, .end = 11 },
                .value = .{ .int = 1 },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer =
        \\
        \\array = [
        \\]
        ,
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 6 },
                .value = .{ .literal = "array" },
            },
            .{ .tag = .array_start, .span = .{ .start = 9, .end = 10 } },
            .{ .tag = .array_end, .span = .{ .start = 11, .end = 12 } },
            null,
        },
    },
    .{
        .buffer = "array = [1, [[]]]",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "array" },
            },
            .{ .tag = .array_start, .span = .{ .start = 8, .end = 9 } },
            .{
                .tag = .value,
                .span = .{ .start = 9, .end = 10 },
                .value = .{
                    .int = 1,
                },
            },
            .{ .tag = .array_start, .span = .{ .start = 12, .end = 13 } },
            .{ .tag = .array_start, .span = .{ .start = 13, .end = 14 } },
            .{ .tag = .array_end, .span = .{ .start = 14, .end = 15 } },
            .{ .tag = .array_end, .span = .{ .start = 15, .end = 16 } },
            .{ .tag = .array_end, .span = .{ .start = 16, .end = 17 } },
            null,
        },
    },
    .{
        .buffer = "array = [[1], [[]]]",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "array" },
            },
            .{ .tag = .array_start, .span = .{ .start = 8, .end = 9 } },
            .{ .tag = .array_start, .span = .{ .start = 9, .end = 10 } },
            .{
                .tag = .value,
                .span = .{ .start = 10, .end = 11 },
                .value = .{
                    .int = 1,
                },
            },
            .{ .tag = .array_end, .span = .{ .start = 11, .end = 12 } },
            .{ .tag = .array_start, .span = .{ .start = 14, .end = 15 } },
            .{ .tag = .array_start, .span = .{ .start = 15, .end = 16 } },
            .{ .tag = .array_end, .span = .{ .start = 16, .end = 17 } },
            .{ .tag = .array_end, .span = .{ .start = 17, .end = 18 } },
            .{ .tag = .array_end, .span = .{ .start = 18, .end = 19 } },
            null,
        },
    },
};

const inline_table_cases: []const TestCase = &.{
    .{
        .buffer = "table = {}",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "table" },
            },
            .{ .tag = .inline_table_start, .span = .{ .start = 8, .end = 9 } },
            .{ .tag = .inline_table_end, .span = .{ .start = 9, .end = 10 } },
            null,
        },
    },
    .{
        .buffer = "table = { a = 1 }",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "table" },
            },
            .{ .tag = .inline_table_start, .span = .{ .start = 8, .end = 9 } },
            .{
                .tag = .key,
                .span = .{ .start = 10, .end = 11 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 14, .end = 15 },
                .value = .{ .int = 1 },
            },
            .{ .tag = .inline_table_end, .span = .{ .start = 16, .end = 17 } },
            null,
        },
    },
    .{
        .buffer = "table = { a = 1, b = true, c = \"hello\" }",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "table" },
            },
            .{ .tag = .inline_table_start, .span = .{ .start = 8, .end = 9 } },
            .{
                .tag = .key,
                .span = .{ .start = 10, .end = 11 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 14, .end = 15 },
                .value = .{ .int = 1 },
            },
            .{
                .tag = .key,
                .span = .{ .start = 17, .end = 18 },
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 21, .end = 25 },
                .value = .{ .boolean = true },
            },
            .{
                .tag = .key,
                .span = .{ .start = 27, .end = 28 },
                .value = .{ .literal = "c" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 32, .end = 37 },
                .value = .{ .string = "hello" },
            },
            .{ .tag = .inline_table_end, .span = .{ .start = 39, .end = 40 } },
            null,
        },
    },
    .{
        .buffer = "table = { \"a\" = 1, 'b' = 2 }",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "table" },
            },
            .{ .tag = .inline_table_start, .span = .{ .start = 8, .end = 9 } },
            .{
                .tag = .key,
                .span = .{ .start = 11, .end = 12 },
                .value = .{ .string = "a" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 16, .end = 17 },
                .value = .{ .int = 1 },
            },
            .{
                .tag = .key,
                .span = .{ .start = 20, .end = 21 },
                .value = .{ .literal_string = "b" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 25, .end = 26 },
                .value = .{ .int = 2 },
            },
            .{ .tag = .inline_table_end, .span = .{ .start = 27, .end = 28 } },
            null,
        },
    },
    .{
        .buffer = "table = { a.b = 1, c.\"d\" = 2 }",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "table" },
            },
            .{ .tag = .inline_table_start, .span = .{ .start = 8, .end = 9 } },
            .{
                .tag = .key,
                .span = .{ .start = 10, .end = 11 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 12, .end = 13 },
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 16, .end = 17 },
                .value = .{ .int = 1 },
            },
            .{
                .tag = .key,
                .span = .{ .start = 19, .end = 20 },
                .value = .{ .literal = "c" },
            },
            .{
                .tag = .key,
                .span = .{ .start = 22, .end = 23 },
                .value = .{ .string = "d" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 27, .end = 28 },
                .value = .{ .int = 2 },
            },
            .{ .tag = .inline_table_end, .span = .{ .start = 29, .end = 30 } },
            null,
        },
    },
    .{
        .buffer = "table = { point = { x = 1, y = 2 }, values = [3, 4] }",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "table" },
            },
            .{ .tag = .inline_table_start, .span = .{ .start = 8, .end = 9 } },
            .{
                .tag = .key,
                .span = .{ .start = 10, .end = 15 },
                .value = .{ .literal = "point" },
            },
            .{ .tag = .inline_table_start, .span = .{ .start = 18, .end = 19 } },
            .{
                .tag = .key,
                .span = .{ .start = 20, .end = 21 },
                .value = .{ .literal = "x" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 24, .end = 25 },
                .value = .{ .int = 1 },
            },
            .{
                .tag = .key,
                .span = .{ .start = 27, .end = 28 },
                .value = .{ .literal = "y" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 31, .end = 32 },
                .value = .{ .int = 2 },
            },
            .{ .tag = .inline_table_end, .span = .{ .start = 33, .end = 34 } },
            .{
                .tag = .key,
                .span = .{ .start = 36, .end = 42 },
                .value = .{ .literal = "values" },
            },
            .{ .tag = .array_start, .span = .{ .start = 45, .end = 46 } },
            .{
                .tag = .value,
                .span = .{ .start = 46, .end = 47 },
                .value = .{ .int = 3 },
            },
            .{
                .tag = .value,
                .span = .{ .start = 49, .end = 50 },
                .value = .{ .int = 4 },
            },
            .{ .tag = .array_end, .span = .{ .start = 50, .end = 51 } },
            .{ .tag = .inline_table_end, .span = .{ .start = 52, .end = 53 } },
            null,
        },
    },
    .{
        .buffer =
        \\
        \\table = {
        \\  a = 1,
        \\  b = 2,
        \\}
        ,
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 6 },
                .value = .{ .literal = "table" },
            },
            .{ .tag = .inline_table_start, .span = .{ .start = 9, .end = 10 } },
            .{
                .tag = .key,
                .span = .{ .start = 13, .end = 14 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 17, .end = 18 },
                .value = .{ .int = 1 },
            },
            .{
                .tag = .key,
                .span = .{ .start = 22, .end = 23 },
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 26, .end = 27 },
                .value = .{ .int = 2 },
            },
            .{ .tag = .inline_table_end, .span = .{ .start = 29, .end = 30 } },
            null,
        },
    },
    .{
        .buffer =
        \\
        \\table = {
        \\  a = 1,
        \\  b = 2,
        \\}
        ,
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 1, .end = 6 },
                .value = .{ .literal = "table" },
            },
            .{ .tag = .inline_table_start, .span = .{ .start = 9, .end = 10 } },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
        .toml_version = .@"1.0.0",
    },
    .{
        .buffer = "table = { a = 1, }",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "table" },
            },
            .{ .tag = .inline_table_start, .span = .{ .start = 8, .end = 9 } },
            .{
                .tag = .key,
                .span = .{ .start = 10, .end = 11 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 14, .end = 15 },
                .value = .{ .int = 1 },
            },
            .{ .tag = .inline_table_end, .span = .{ .start = 17, .end = 18 } },
            null,
        },
    },
    .{
        .buffer = "table = { a = 1, }",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "table" },
            },
            .{ .tag = .inline_table_start, .span = .{ .start = 8, .end = 9 } },
            .{
                .tag = .key,
                .span = .{ .start = 10, .end = 11 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 14, .end = 15 },
                .value = .{ .int = 1 },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
        .toml_version = .@"1.0.0",
    },
    .{
        .buffer = "table = { a = 1 b = 2 }",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "table" },
            },
            .{ .tag = .inline_table_start, .span = .{ .start = 8, .end = 9 } },
            .{
                .tag = .key,
                .span = .{ .start = 10, .end = 11 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 14, .end = 15 },
                .value = .{ .int = 1 },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "table = { a = 1, , b = 2 }",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "table" },
            },
            .{ .tag = .inline_table_start, .span = .{ .start = 8, .end = 9 } },
            .{
                .tag = .key,
                .span = .{ .start = 10, .end = 11 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 14, .end = 15 },
                .value = .{ .int = 1 },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "table = { a = }",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "table" },
            },
            .{ .tag = .inline_table_start, .span = .{ .start = 8, .end = 9 } },
            .{
                .tag = .key,
                .span = .{ .start = 10, .end = 11 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "table = { a = { b = } }",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "table" },
            },
            .{ .tag = .inline_table_start, .span = .{ .start = 8, .end = 9 } },
            .{
                .tag = .key,
                .span = .{ .start = 10, .end = 11 },
                .value = .{ .literal = "a" },
            },
            .{ .tag = .inline_table_start, .span = .{ .start = 14, .end = 15 } },
            .{
                .tag = .key,
                .span = .{ .start = 16, .end = 17 },
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "table = { a = 1",
        .items = &.{
            .{
                .tag = .key,
                .span = .{ .start = 0, .end = 5 },
                .value = .{ .literal = "table" },
            },
            .{ .tag = .inline_table_start, .span = .{ .start = 8, .end = 9 } },
            .{
                .tag = .key,
                .span = .{ .start = 10, .end = 11 },
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .value,
                .span = .{ .start = 14, .end = 15 },
                .value = .{ .int = 1 },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedEnd },
            },
        },
    },
};

fn expectEqualTestItem(expected: ?TestItem, actual: ?Item, buffer: []const u8) !void {
    if (expected == null or actual == null) {
        try std.testing.expectEqual(expected == null, actual == null);
        return;
    }

    const expected_tag = expectedTag(expected.?.tag).?;

    try std.testing.expectEqual(expected_tag, actual.?.tag);
    try std.testing.expectEqualDeep(expected.?.span, actual.?.span);

    if (expectedSyntaxToken(expected_tag)) |expected_slice| {
        try std.testing.expectEqualStrings(
            expected_slice,
            buffer[actual.?.span.start..actual.?.span.end],
        );
    }

    if (expected.?.value == null or actual.?.value == null) {
        try std.testing.expectEqual(expected.?.value == null, actual.?.value == null);
        return;
    }

    const expected_value = expected.?.value.?;
    const actual_value = actual.?.value.?;

    try std.testing.expectEqual(expectedValueTag(expected_value), std.meta.activeTag(actual_value));

    switch (expected_value) {
        .literal,
        .string,
        .multiline_string,
        .literal_string,
        .multiline_literal_string,
        => |expected_text| {
            try std.testing.expectEqualStrings(
                expected_text,
                buffer[actual.?.span.start..actual.?.span.end],
            );
        },
        .float => |expected_float| {
            const actual_float = actual_value.float;
            const expected_bits: u64 = @bitCast(expected_float);
            const actual_bits: u64 = @bitCast(actual_float);
            try std.testing.expectEqual(expected_bits, actual_bits);
        },
        .int => |expected_int| try std.testing.expectEqual(expected_int, actual_value.int),
        .boolean => |expected_boolean| try std.testing.expectEqual(
            expected_boolean,
            actual_value.boolean,
        ),
        .datetime => |expected_datetime| try std.testing.expectEqualDeep(
            expected_datetime,
            actual_value.datetime,
        ),
        .local_datetime => |expected_local_datetime| try std.testing.expectEqualDeep(
            expected_local_datetime,
            actual_value.local_datetime,
        ),
        .local_date => |expected_local_date| try std.testing.expectEqualDeep(
            expected_local_date,
            actual_value.local_date,
        ),
        .local_time => |expected_local_time| try std.testing.expectEqualDeep(
            expected_local_time,
            actual_value.local_time,
        ),
        .@"error" => unreachable,
    }
}

fn runTests(cases: []const TestCase) !void {
    for (cases) |case| {
        var items: std.ArrayList(u8) = .empty;
        defer items.deinit(std.testing.allocator);

        errdefer std.debug.print("collected items: {s}\n", .{items.items});
        errdefer std.debug.print("failing test case: {s}\n", .{case.buffer});

        var parser: Parser = .init(case.buffer, .{ .toml_version = case.toml_version });

        for (case.items) |expected| {
            if (expected == null) {
                try std.testing.expectEqual(null, try parser.next());
                items.appendSlice(std.testing.allocator, "\n - null,") catch @panic("OOM");
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
                        const actual = try parser.next();
                        var buf: [512]u8 = undefined;
                        items.appendSlice(
                            std.testing.allocator,
                            std.fmt.bufPrint(
                                &buf,
                                "\n - {any},",
                                .{actual.?},
                            ) catch @panic("overflow"),
                        ) catch @panic("OOM");
                        try expectEqualTestItem(expected, actual, case.buffer);
                    },
                }
            }
        }
    }
}

test "Parser.next" {
    try runTests(test_cases);
}

test "Parser.next table headers" {
    try runTests(table_header_cases);
}

test "Parser.next array table headers" {
    try runTests(array_table_header_cases);
}

test "Parser.next key value" {
    try runTests(key_value_cases);
}

test "Parser.next booleans" {
    try runTests(bool_cases);
}

test "Parser.next datetimes" {
    try runTests(datetime_cases);
}

test "Parser.next ints" {
    try runTests(int_cases);
}

test "Parser.next floats" {
    try runTests(float_cases);
}

test "Parser.next arrays" {
    try runTests(array_cases);
}

test "Parser.next inline tables" {
    try runTests(inline_table_cases);
}
