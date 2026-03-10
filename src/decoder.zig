// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DecodeOptions = struct {};

pub const Parsed = struct {};

pub fn decode(gpa: Allocator, input: []const u8, options: DecodeOptions) !Parsed {
    _ = gpa;
    _ = input;
    _ = options;

    return .{};
}
