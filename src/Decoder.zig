// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const Decoder = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn decode(gpa: Allocator, input: []const u8) void {
    _ = gpa;
    _ = input;
}
