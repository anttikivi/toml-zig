// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub const decode = @import("Decoder.zig").decode;
pub const Decoder = @import("Decoder.zig");
pub const Diagnostics = @import("Diagnostics.zig");
pub const Parser = @import("Parser.zig");
pub const Tokenizer = @import("Tokenizer.zig");

/// The default TOML version used by the library.
pub const default_version: Version = .@"1.1.0";

/// TOML versions that this parser supports.
pub const Version = enum {
    @"1.1.0",
    @"1.0.0",
};

/// State type used by the UTF-8 validation algorithm.
/// For more information, see:
/// https://unicode.org/mail-arch/unicode-ml/y2003-m02/att-0467/01-The_Algorithm_to_Valide_an_UTF-8_String
pub const Utf8State = enum { start, a, b, c, d, e, f, g };

test {
    std.testing.refAllDecls(@This());
}
