// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const Tokenizer = @import("../Tokenizer.zig");
const Error = Tokenizer.Error;
const Token = Tokenizer.Token;
const default_version = @import("../toml.zig").default_version;
const Version = @import("../toml.zig").Version;

const NextTestCase = struct {
    buffer: []const u8,
    tokens: []const Token,
    @"error": ?Error = null,
    toml_version: Version = default_version,
    comment_tokens: bool = false,
    whitespace_tokens: bool = false,
};

const next_test_cases: []const NextTestCase = &.{
    .{
        .buffer =
        \\
        \\
        ,
        .tokens = &.{
            .{
                .tag = .newline,
                .span = .{
                    .start = 0,
                    .end = 1,
                },
            },
            .{
                .tag = .end_of_file,
                .span = .{
                    .start = 1,
                    .end = 1,
                },
            },
        },
    },
    .{
        .buffer = "\"hello\"",
        .tokens = &.{
            .{
                .tag = .string,
                .span = .{ .start = 0, .end = 7 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 7, .end = 7 },
            },
        },
    },
    .{
        .buffer = "'hello'",
        .tokens = &.{
            .{
                .tag = .literal_string,
                .span = .{ .start = 0, .end = 7 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 7, .end = 7 },
            },
        },
    },
    .{
        .buffer = "\"\"\"\"\"\"",
        .tokens = &.{
            .{
                .tag = .multiline_string,
                .span = .{ .start = 0, .end = 6 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 6, .end = 6 },
            },
        },
    },
    .{
        .buffer = "''' '''",
        .tokens = &.{
            .{
                .tag = .multiline_literal_string,
                .span = .{ .start = 0, .end = 7 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 7, .end = 7 },
            },
        },
    },
    .{
        .buffer =
        \\"""
        \\first
        \\second
        \\"""
        ,
        .tokens = &.{
            .{
                .tag = .multiline_string,
                .span = .{ .start = 0, .end = 20 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 20, .end = 20 },
            },
        },
    },
    .{
        .buffer =
        \\'''
        \\first
        \\second
        \\'''
        ,
        .tokens = &.{
            .{
                .tag = .multiline_literal_string,
                .span = .{ .start = 0, .end = 20 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 20, .end = 20 },
            },
        },
    },
    .{
        .buffer = "\r\n",
        .tokens = &.{
            .{
                .tag = .newline,
                .span = .{ .start = 0, .end = 2 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 2, .end = 2 },
            },
        },
    },
    .{
        .buffer = "#a\n#b\n",
        .tokens = &.{
            .{
                .tag = .newline,
                .span = .{ .start = 2, .end = 3 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 5, .end = 6 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 6, .end = 6 },
            },
        },
    },
    .{
        .buffer = "#a\n#b\n",
        .tokens = &.{
            .{
                .tag = .comment,
                .span = .{ .start = 0, .end = 2 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 2, .end = 3 },
            },
            .{
                .tag = .comment,
                .span = .{ .start = 3, .end = 5 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 5, .end = 6 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 6, .end = 6 },
            },
        },
        .comment_tokens = true,
    },
    .{
        .buffer = " \t\n",
        .tokens = &.{
            .{
                .tag = .newline,
                .span = .{ .start = 2, .end = 3 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 3, .end = 3 },
            },
        },
    },
    .{
        .buffer = " \t\n",
        .tokens = &.{
            .{
                .tag = .whitespace,
                .span = .{ .start = 0, .end = 2 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 2, .end = 3 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 3, .end = 3 },
            },
        },
        .whitespace_tokens = true,
    },
    .{
        .buffer = "key",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 3 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 3, .end = 3 },
            },
        },
    },
    .{
        .buffer = "bare-key",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 8 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 8, .end = 8 },
            },
        },
    },
    .{
        .buffer = "a.b.c",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 5 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 5, .end = 5 },
            },
        },
    },
    .{
        .buffer = "12345",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 5 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 5, .end = 5 },
            },
        },
    },
    .{
        .buffer = "+99",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 3 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 3, .end = 3 },
            },
        },
    },
    .{
        .buffer = "-17",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 3 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 3, .end = 3 },
            },
        },
    },
    .{
        .buffer = "1_000",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 5 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 5, .end = 5 },
            },
        },
    },
    .{
        .buffer = "3.1415",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 6 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 6, .end = 6 },
            },
        },
    },
    .{
        .buffer = "1e+06",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 5 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 5, .end = 5 },
            },
        },
    },
    .{
        .buffer = "0xDEADBEEF",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 10 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 10, .end = 10 },
            },
        },
    },
    .{
        .buffer = "true",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 4 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 4, .end = 4 },
            },
        },
    },
    .{
        .buffer = "false",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 5 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 5, .end = 5 },
            },
        },
    },
    .{
        .buffer = "+inf",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 4 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 4, .end = 4 },
            },
        },
    },
    .{
        .buffer = "nan",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 3 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 3, .end = 3 },
            },
        },
    },
    .{
        .buffer = "1979-05-27",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 10 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 10, .end = 10 },
            },
        },
    },
    .{
        .buffer = "07:32:00",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 8 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 8, .end = 8 },
            },
        },
    },
    .{
        .buffer = "1979-05-27T07:32:00Z",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 20 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 20, .end = 20 },
            },
        },
    },
    .{
        .buffer = "1979-05-27 07:32:00Z",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 10 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 11, .end = 20 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 20, .end = 20 },
            },
        },
    },
    .{
        .buffer = "1979-05-27T07:32:00.999999-07:00",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 32 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 32, .end = 32 },
            },
        },
    },
    .{
        .buffer = "key=value",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 3 },
            },
            .{
                .tag = .equal,
                .span = .{ .start = 3, .end = 4 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 4, .end = 9 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 9, .end = 9 },
            },
        },
    },
    .{
        .buffer = "[table]",
        .tokens = &.{
            .{
                .tag = .left_bracket,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 1, .end = 6 },
            },
            .{
                .tag = .right_bracket,
                .span = .{ .start = 6, .end = 7 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 7, .end = 7 },
            },
        },
    },
    .{
        .buffer = "[[products]]",
        .tokens = &.{
            .{
                .tag = .double_left_bracket,
                .span = .{ .start = 0, .end = 2 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 2, .end = 10 },
            },
            .{
                .tag = .double_right_bracket,
                .span = .{ .start = 10, .end = 12 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 12, .end = 12 },
            },
        },
    },
    .{
        .buffer = "{foo=bar}",
        .tokens = &.{
            .{
                .tag = .left_brace,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 1, .end = 4 },
            },
            .{
                .tag = .equal,
                .span = .{ .start = 4, .end = 5 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 5, .end = 8 },
            },
            .{
                .tag = .right_brace,
                .span = .{ .start = 8, .end = 9 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 9, .end = 9 },
            },
        },
    },
    .{
        .buffer = "[true,false]",
        .tokens = &.{
            .{
                .tag = .left_bracket,
                .span = .{ .start = 0, .end = 1 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 1, .end = 5 },
            },
            .{
                .tag = .comma,
                .span = .{ .start = 5, .end = 6 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 6, .end = 11 },
            },
            .{
                .tag = .right_bracket,
                .span = .{ .start = 11, .end = 12 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 12, .end = 12 },
            },
        },
    },
    .{
        .buffer = "key # note\n",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 3 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 10, .end = 11 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 11, .end = 11 },
            },
        },
    },
    .{
        .buffer = "key # note\n",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 3 },
            },
            .{
                .tag = .comment,
                .span = .{ .start = 4, .end = 10 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 10, .end = 11 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 11, .end = 11 },
            },
        },
        .comment_tokens = true,
    },
    .{
        .buffer = "key\nvalue",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 3 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 3, .end = 4 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 4, .end = 9 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 9, .end = 9 },
            },
        },
    },
    .{
        .buffer = "\"x\" \t\"hello\"\n",
        .tokens = &.{
            .{
                .tag = .string,
                .span = .{ .start = 0, .end = 3 },
            },
            .{
                .tag = .string,
                .span = .{ .start = 5, .end = 12 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 12, .end = 13 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 13, .end = 13 },
            },
        },
    },
    .{
        .buffer = "\"x\" \t\"hello\"\n",
        .tokens = &.{
            .{
                .tag = .string,
                .span = .{ .start = 0, .end = 3 },
            },
            .{
                .tag = .whitespace,
                .span = .{ .start = 3, .end = 5 },
            },
            .{
                .tag = .string,
                .span = .{ .start = 5, .end = 12 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 12, .end = 13 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 13, .end = 13 },
            },
        },
        .whitespace_tokens = true,
    },
    .{
        .buffer = "\"x\"#note\n\"hello\"\n",
        .tokens = &.{
            .{
                .tag = .string,
                .span = .{ .start = 0, .end = 3 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 8, .end = 9 },
            },
            .{
                .tag = .string,
                .span = .{ .start = 9, .end = 16 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 16, .end = 17 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 17, .end = 17 },
            },
        },
    },
    .{
        .buffer = "\"x\"#note\n",
        .tokens = &.{
            .{
                .tag = .string,
                .span = .{ .start = 0, .end = 3 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 8, .end = 9 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 9, .end = 9 },
            },
        },
    },
    .{
        .buffer = "\"x\"#note\n",
        .tokens = &.{
            .{
                .tag = .string,
                .span = .{ .start = 0, .end = 3 },
            },
            .{
                .tag = .comment,
                .span = .{ .start = 3, .end = 8 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 8, .end = 9 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 9, .end = 9 },
            },
        },
        .comment_tokens = true,
    },
    .{
        .buffer = "\"\\n\"",
        .tokens = &.{
            .{
                .tag = .string,
                .span = .{ .start = 0, .end = 4 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 4, .end = 4 },
            },
        },
    },
    .{
        .buffer = "\"\\t\"",
        .tokens = &.{
            .{
                .tag = .string,
                .span = .{ .start = 0, .end = 4 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 4, .end = 4 },
            },
        },
    },
    .{
        .buffer = "\"\\\"\"",
        .tokens = &.{
            .{
                .tag = .string,
                .span = .{ .start = 0, .end = 4 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 4, .end = 4 },
            },
        },
    },
    .{
        .buffer = "\"\\\\\"",
        .tokens = &.{
            .{
                .tag = .string,
                .span = .{ .start = 0, .end = 4 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 4, .end = 4 },
            },
        },
    },
    .{
        .buffer = "\"emoji \xf0\x9f\x98\x80\"",
        .tokens = &.{
            .{
                .tag = .string,
                .span = .{ .start = 0, .end = 12 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 12, .end = 12 },
            },
        },
    },
    .{
        .buffer = "\"emoji 😀\"",
        .tokens = &.{
            .{
                .tag = .string,
                .span = .{ .start = 0, .end = 12 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 12, .end = 12 },
            },
        },
    },
    .{
        .buffer = "",
        .tokens = &.{
            .{
                .tag = .end_of_file,
                .span = .{ .start = 0, .end = 0 },
            },
        },
    },
    .{
        .buffer = "\x00",
        .tokens = &.{},
        .@"error" = error.InvalidControlCharacter,
    },
    .{
        .buffer = "\r",
        .tokens = &.{},
        .@"error" = error.InvalidControlCharacter,
    },
    .{
        .buffer = "@",
        .tokens = &.{},
        .@"error" = error.UnexpectedToken,
    },
    .{
        .buffer = "\"\n",
        .tokens = &.{},
        .@"error" = error.UnterminatedString,
    },
    .{
        .buffer = "\"\\q\"",
        .tokens = &.{},
        .@"error" = error.InvalidEscapeSequence,
    },
    .{
        .buffer = "\"\\e\"",
        .tokens = &.{},
        .@"error" = error.InvalidEscapeSequence,
        .toml_version = .@"1.0.0",
    },
    .{
        .buffer = "\"\\xy\"",
        .tokens = &.{},
        .@"error" = error.InvalidEscapeSequence,
    },
    .{
        .buffer = "\"\\xuh\"",
        .tokens = &.{},
        .@"error" = error.InvalidEscapeSequence,
    },
    .{
        .buffer = "\"\\x41\"",
        .tokens = &.{},
        .@"error" = error.InvalidEscapeSequence,
        .toml_version = .@"1.0.0",
    },
    .{
        .buffer = "\"\\uhexs\"",
        .tokens = &.{},
        .@"error" = error.InvalidEscapeSequence,
    },
    .{
        .buffer = "\"\\uh\"",
        .tokens = &.{},
        .@"error" = error.InvalidEscapeSequence,
    },
    .{
        .buffer = "\"\\Uhexhexab\"",
        .tokens = &.{},
        .@"error" = error.InvalidEscapeSequence,
    },
    .{
        .buffer = "\"\\Uhex\"",
        .tokens = &.{},
        .@"error" = error.InvalidEscapeSequence,
    },
    .{
        .buffer = "# A comment \x80",
        .tokens = &.{},
        .@"error" = error.InvalidUtf8,
    },
    .{
        .buffer = "\"\x80\"",
        .tokens = &.{},
        .@"error" = error.InvalidUtf8,
    },
    .{
        .buffer =
        \\#comment
        \\key = "string"
        \\key2 = 123
        \\a.b.c = 1
        \\array = [1, 2, 3]
        \\inline = { foo = "bar" }
        ,
        .tokens = &.{
            .{
                .tag = .comment,
                .span = .{ .start = 0, .end = 8 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 8, .end = 9 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 9, .end = 12 },
            },
            .{
                .tag = .whitespace,
                .span = .{ .start = 12, .end = 13 },
            },
            .{
                .tag = .equal,
                .span = .{ .start = 13, .end = 14 },
            },
            .{
                .tag = .whitespace,
                .span = .{ .start = 14, .end = 15 },
            },
            .{
                .tag = .string,
                .span = .{ .start = 15, .end = 23 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 23, .end = 24 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 24, .end = 28 },
            },
            .{
                .tag = .whitespace,
                .span = .{ .start = 28, .end = 29 },
            },
            .{
                .tag = .equal,
                .span = .{ .start = 29, .end = 30 },
            },
            .{
                .tag = .whitespace,
                .span = .{ .start = 30, .end = 31 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 31, .end = 34 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 34, .end = 35 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 35, .end = 40 },
            },
            .{
                .tag = .whitespace,
                .span = .{ .start = 40, .end = 41 },
            },
            .{
                .tag = .equal,
                .span = .{ .start = 41, .end = 42 },
            },
            .{
                .tag = .whitespace,
                .span = .{ .start = 42, .end = 43 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 43, .end = 44 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 44, .end = 45 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 45, .end = 50 },
            },
            .{
                .tag = .whitespace,
                .span = .{ .start = 50, .end = 51 },
            },
            .{
                .tag = .equal,
                .span = .{ .start = 51, .end = 52 },
            },
            .{
                .tag = .whitespace,
                .span = .{ .start = 52, .end = 53 },
            },
            .{
                .tag = .left_bracket,
                .span = .{ .start = 53, .end = 54 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 54, .end = 55 },
            },
            .{
                .tag = .comma,
                .span = .{ .start = 55, .end = 56 },
            },
            .{
                .tag = .whitespace,
                .span = .{ .start = 56, .end = 57 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 57, .end = 58 },
            },
            .{
                .tag = .comma,
                .span = .{ .start = 58, .end = 59 },
            },
            .{
                .tag = .whitespace,
                .span = .{ .start = 59, .end = 60 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 60, .end = 61 },
            },
            .{
                .tag = .right_bracket,
                .span = .{ .start = 61, .end = 62 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 62, .end = 63 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 63, .end = 69 },
            },
            .{
                .tag = .whitespace,
                .span = .{ .start = 69, .end = 70 },
            },
            .{
                .tag = .equal,
                .span = .{ .start = 70, .end = 71 },
            },
            .{
                .tag = .whitespace,
                .span = .{ .start = 71, .end = 72 },
            },
            .{
                .tag = .left_brace,
                .span = .{ .start = 72, .end = 73 },
            },
            .{
                .tag = .whitespace,
                .span = .{ .start = 73, .end = 74 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 74, .end = 77 },
            },
            .{
                .tag = .whitespace,
                .span = .{ .start = 77, .end = 78 },
            },
            .{
                .tag = .equal,
                .span = .{ .start = 78, .end = 79 },
            },
            .{
                .tag = .whitespace,
                .span = .{ .start = 79, .end = 80 },
            },
            .{
                .tag = .string,
                .span = .{ .start = 80, .end = 85 },
            },
            .{
                .tag = .whitespace,
                .span = .{ .start = 85, .end = 86 },
            },
            .{
                .tag = .right_brace,
                .span = .{ .start = 86, .end = 87 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 87, .end = 87 },
            },
        },
        .comment_tokens = true,
        .whitespace_tokens = true,
    },
    .{
        .buffer =
        \\#comment
        \\key = "string"
        \\key2 = 123
        \\a.b.c = 1
        \\array = [1, 2, 3]
        \\inline = { foo = "bar" }
        ,
        .tokens = &.{
            .{
                .tag = .newline,
                .span = .{ .start = 8, .end = 9 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 9, .end = 12 },
            },
            .{
                .tag = .equal,
                .span = .{ .start = 13, .end = 14 },
            },
            .{
                .tag = .string,
                .span = .{ .start = 15, .end = 23 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 23, .end = 24 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 24, .end = 28 },
            },
            .{
                .tag = .equal,
                .span = .{ .start = 29, .end = 30 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 31, .end = 34 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 34, .end = 35 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 35, .end = 40 },
            },
            .{
                .tag = .equal,
                .span = .{ .start = 41, .end = 42 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 43, .end = 44 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 44, .end = 45 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 45, .end = 50 },
            },
            .{
                .tag = .equal,
                .span = .{ .start = 51, .end = 52 },
            },
            .{
                .tag = .left_bracket,
                .span = .{ .start = 53, .end = 54 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 54, .end = 55 },
            },
            .{
                .tag = .comma,
                .span = .{ .start = 55, .end = 56 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 57, .end = 58 },
            },
            .{
                .tag = .comma,
                .span = .{ .start = 58, .end = 59 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 60, .end = 61 },
            },
            .{
                .tag = .right_bracket,
                .span = .{ .start = 61, .end = 62 },
            },
            .{
                .tag = .newline,
                .span = .{ .start = 62, .end = 63 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 63, .end = 69 },
            },
            .{
                .tag = .equal,
                .span = .{ .start = 70, .end = 71 },
            },
            .{
                .tag = .left_brace,
                .span = .{ .start = 72, .end = 73 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 74, .end = 77 },
            },
            .{
                .tag = .equal,
                .span = .{ .start = 78, .end = 79 },
            },
            .{
                .tag = .string,
                .span = .{ .start = 80, .end = 85 },
            },
            .{
                .tag = .right_brace,
                .span = .{ .start = 86, .end = 87 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 87, .end = 87 },
            },
        },
    },
    .{
        .buffer = "a.\"b\".c",
        .tokens = &.{
            .{
                .tag = .literal,
                .span = .{ .start = 0, .end = 2 },
            },
            .{
                .tag = .string,
                .span = .{ .start = 2, .end = 5 },
            },
            .{
                .tag = .dot,
                .span = .{ .start = 5, .end = 6 },
            },
            .{
                .tag = .literal,
                .span = .{ .start = 6, .end = 7 },
            },
            .{
                .tag = .end_of_file,
                .span = .{ .start = 7, .end = 7 },
            },
        },
    },
};

test "Tokenizer.next" {
    for (next_test_cases) |case| {
        var tokenizer: Tokenizer = .init(case.buffer, .{
            .toml_version = case.toml_version,
            .comment_tokens = case.comment_tokens,
            .whitespace_tokens = case.whitespace_tokens,
        });

        if (case.@"error") |expected| {
            try std.testing.expectError(expected, tokenizer.next());
        } else {
            for (case.tokens) |expected| {
                const actual = try tokenizer.next();
                try std.testing.expectEqualDeep(expected, actual);
            }
        }
    }
}
