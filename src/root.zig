// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub const decode = @import("decoder.zig").decode;
pub const DecodeOptions = @import("decoder.zig").DecodeOptions;
pub const Parsed = @import("decoder.zig").Parsed;

/// TOML versions that this parser supports.
pub const Version = enum {
    @"1.1.0",
    @"1.0.0",
};

test {
    std.testing.refAllDecls(@This());
}
