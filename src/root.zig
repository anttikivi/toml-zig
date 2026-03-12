// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub const decode = @import("Decoder.zig").decode;
pub const Decoder = @import("Decoder.zig");
pub const Parser = @import("Parser.zig");
pub const Tokenizer = @import("Tokenizer.zig");
pub const Token = @import("Tokenizer.zig").Token;
pub const default_version = @import("toml.zig").default_version;
pub const Features = @import("toml.zig").Features;
pub const Version = @import("toml.zig").Version;

/// Optional diagnostics for the TOML parser. To enable diagnostics, declare
/// `var diagnostics: Diagnostics = .{};` and then pass it into the library
/// component with the appropriate options:
/// `const options: Options = .{ .diagnostics = &diagnostics };`.
///
/// When the diagnostics option is set, it will be populated whenever an error occurs during the parsing.
pub const Diagnostics = struct {
    position: Position = .{},
    message: []const u8 = "",

    pub const Error = error{Reported};
};

/// Stores the position where an error has occured as accurately as possible for
/// diagnostics.
pub const Position = struct {
    line_number: usize = 1,
    column: usize = 0,
    snippet: []const u8 = "",
};

/// State type used internally by the library in the UTF-8 validation algorithm.
/// For more information, see:
/// https://unicode.org/mail-arch/unicode-ml/y2003-m02/att-0467/01-The_Algorithm_to_Valide_an_UTF-8_String
pub const Utf8State = enum { start, a, b, c, d, e, f, g };

test {
    std.testing.refAllDecls(@This());
}
