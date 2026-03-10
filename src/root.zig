// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub const decode = @import("Decoder.zig").decode;
pub const Decoder = @import("Decoder.zig");
pub const Diagnostics = @import("Diagnostics.zig");
pub const Parser = @import("Parser.zig");
pub const Tokenizer = @import("Tokenizer.zig");

/// TOML versions that this parser supports.
pub const Version = enum {
    @"1.1.0",
    @"1.0.0",
};

test {
    std.testing.refAllDecls(@This());
}
