// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const builtin = @import("builtin");
const std = @import("std");

const Parser = @import("../Parser.zig");
const Date = Parser.Date;
const Error = Parser.Error;
const Item = Parser.Item;
const State = Parser.State;
const Time = Parser.Time;
const Datetime = Parser.Datetime;
const default_version = @import("../toml.zig").default_version;
const Float = @import("../toml.zig").Float;
const Int = @import("../toml.zig").Int;
const Version = @import("../toml.zig").Version;

const TestItem = struct {
    tag: Tag,
    value: ?Value = null,

    pub const Tag = enum {
        @"error",

        table_header_start,
        table_header_end,
        table_key,
        key,
        value,
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
                .value = .{ .literal = "a" },
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
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .table_key,
                .value = .{ .literal = "b" },
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
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .table_key,
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .table_key,
                .value = .{ .literal = "c" },
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
                .value = .{ .string = "a" },
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
                .value = .{ .literal_string = "a" },
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
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .table_key,
                .value = .{ .string = "b" },
            },
            .{
                .tag = .table_key,
                .value = .{ .literal = "c" },
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
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .table_key,
                .value = .{ .literal_string = "b" },
            },
            .{
                .tag = .table_key,
                .value = .{ .literal = "c" },
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
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .table_key,
                .value = .{ .literal_string = "b" },
            },
            .{
                .tag = .table_key,
                .value = .{ .string = "c" },
            },
            .{
                .tag = .table_key,
                .value = .{ .literal = "d" },
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
                .value = .{ .string = "a" },
            },
            .{
                .tag = .table_key,
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .table_key,
                .value = .{ .literal_string = "c" },
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
                .value = .{ .@"error" = error.UnexpectedToken },
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
            },
            .{
                .tag = .table_key,
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
            },
            .{
                .tag = .table_key,
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
            },
            .{
                .tag = .table_key,
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
            },
            .{
                .tag = .table_key,
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
            },
            .{
                .tag = .table_key,
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
            },
            .{
                .tag = .table_key,
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
            },
            .{
                .tag = .table_key,
                .value = .{ .literal_string = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "a = \"b\"",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .key,
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .key,
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .key,
                .value = .{ .literal = "c" },
            },
            .{
                .tag = .value,
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
                .value = .{ .string = "a" },
            },
            .{
                .tag = .value,
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
                .value = .{ .string = "a" },
            },
            .{
                .tag = .key,
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .key,
                .value = .{ .string = "b" },
            },
            .{
                .tag = .value,
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
                .value = .{ .string = "a" },
            },
            .{
                .tag = .key,
                .value = .{ .string = "b" },
            },
            .{
                .tag = .value,
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
                .value = .{ .string = "a" },
            },
            .{
                .tag = .key,
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .key,
                .value = .{ .string = "c" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .key,
                .value = .{ .string = "b" },
            },
            .{
                .tag = .key,
                .value = .{ .literal = "c" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal_string = "a" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal_string = "a" },
            },
            .{
                .tag = .key,
                .value = .{ .literal_string = "b" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal_string = "a" },
            },
            .{
                .tag = .key,
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .key,
                .value = .{ .literal_string = "b" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal_string = "a" },
            },
            .{
                .tag = .key,
                .value = .{ .literal = "b" },
            },
            .{
                .tag = .key,
                .value = .{ .literal_string = "c" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "a" },
            },
            .{
                .tag = .key,
                .value = .{ .literal_string = "b" },
            },
            .{
                .tag = .key,
                .value = .{ .literal = "c" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal_string = "a" },
            },
            .{
                .tag = .key,
                .value = .{ .string = "b" },
            },
            .{
                .tag = .key,
                .value = .{ .literal = "c" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal_string = "a" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.UnexpectedToken },
            },
        },
    },
    .{
        .buffer = "bool = true",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "bool" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "bool" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "bool" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "bool" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "bool" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "bool" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "bool" },
            },
            .{
                .tag = .value,
                .value = .{ .boolean = true },
            },
            null,
        },
    },
    .{
        .buffer = "dt = 1979-05-27T07:32:45Z",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
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
        .buffer = "dt = 1979-05-27 07:32:45.23",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "date" },
            },
            .{
                .tag = .value,
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
        .buffer = "dt = 1979-05-27T07:32Z",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .value,
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
        .buffer = "dt = 1979-05-27T07:32.23-07:00",
        .items = &.{
            .{
                .tag = .key,
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
                .value = .{ .literal = "dt" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidDatetime },
            },
        },
    },
    .{
        .buffer = "time = 07:32:45",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "time" },
            },
            .{
                .tag = .value,
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
        .buffer = "time = 07:32:00",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "time" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "time" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "time" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "time" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidTime },
            },
        },
        .toml_version = .@"1.0.0",
    },
    .{
        .buffer = "int = 0",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .value,
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
                .value = .{ .literal = "int" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.Overflow },
            },
        },
    },
    .{
        .buffer = "float = 0.0",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = 0 },
            },
        },
    },
    .{
        .buffer = "float = 1.0",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = 1 },
            },
        },
    },
    .{
        .buffer = "float = +1.0",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = 1 },
            },
        },
    },
    .{
        .buffer = "float = 1.1",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = 1.1 },
            },
        },
    },
    .{
        .buffer = "float = 2.3456789",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = 2.3456789 },
            },
        },
    },
    .{
        .buffer = "float = 0.29375927359253",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = 0.29375927359253 },
            },
        },
    },
    .{
        .buffer = "float = 1234e-2",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = 12.34 },
            },
        },
    },
    .{
        .buffer = "float = 1e2",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = 100 },
            },
        },
    },
    .{
        .buffer = "float = 1e+2",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = 100 },
            },
        },
    },
    .{
        .buffer = "float = 1E2",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = 100 },
            },
        },
    },
    .{
        .buffer = "float = 1_000.5",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = 1000.5 },
            },
        },
    },
    .{
        .buffer = "float = 1e1_0",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = 10000000000 },
            },
        },
    },
    .{
        .buffer = "float = -0.0",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = -0.0 },
            },
        },
    },
    .{
        .buffer = "float = -1.0",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = -1 },
            },
        },
    },
    .{
        .buffer = "float = -1.1",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = -1.1 },
            },
        },
    },
    .{
        .buffer = "float = -2.3456789",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = -2.3456789 },
            },
        },
    },
    .{
        .buffer = "float = -0.29375927359253",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = -0.29375927359253 },
            },
        },
    },
    .{
        .buffer = "float = -1234e-2",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = -12.34 },
            },
        },
    },
    .{
        .buffer = "float = inf",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = std.math.inf(Float) },
            },
        },
    },
    .{
        .buffer = "float = +inf",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = std.math.inf(Float) },
            },
        },
    },
    .{
        .buffer = "float = -inf",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = -std.math.inf(Float) },
            },
        },
    },
    .{
        .buffer = "float = nan",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = std.math.nan(Float) },
            },
        },
    },
    .{
        .buffer = "float = +nan",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = std.math.nan(Float) },
            },
        },
    },
    .{
        .buffer = "float = -nan",
        .items = &.{
            .{
                .tag = .key,
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .value,
                .value = .{ .float = -std.math.nan(Float) },
            },
        },
    },
    .{
        .buffer = "float = 1.",
        .items = &.{
            .{
                .tag = .key,
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
                .value = .{ .literal = "float" },
            },
            .{
                .tag = .@"error",
                .value = .{ .@"error" = error.InvalidCharacter },
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

fn expectEqualTestItem(expected: ?TestItem, actual: ?TestItem) !void {
    if (expected == null or actual == null) {
        try std.testing.expectEqualDeep(expected, actual);
        return;
    }

    try std.testing.expectEqual(expected.?.tag, actual.?.tag);

    if (expected.?.value == null or actual.?.value == null) {
        try std.testing.expectEqualDeep(expected.?.value, actual.?.value);
        return;
    }

    try std.testing.expectEqual(std.meta.activeTag(expected.?.value.?), std.meta.activeTag(actual.?.value.?));

    switch (expected.?.value.?) {
        .float => |expected_float| {
            const actual_float = actual.?.value.?.float;
            const expected_bits: u64 = @bitCast(expected_float);
            const actual_bits: u64 = @bitCast(actual_float);
            try std.testing.expectEqual(expected_bits, actual_bits);
        },
        else => try std.testing.expectEqualDeep(expected.?.value, actual.?.value),
    }
}

test "Parser.next" {
    for (next_test_cases) |case| {
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
                        const actual = convertItem(try parser.next());
                        var buf: [512]u8 = undefined;
                        items.appendSlice(
                            std.testing.allocator,
                            std.fmt.bufPrint(&buf, "\n - {f},", .{actual.?}) catch @panic("overflow"),
                        ) catch @panic("OOM");
                        try expectEqualTestItem(expected, actual);
                    },
                }
            }
        }
    }
}
