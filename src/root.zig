// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

/// TOML versions that this parser supports.
pub const Version = enum {
    @"1.1.0",
    @"1.0.0",
};

test {
    std.testing.refAllDecls(@This());
}
