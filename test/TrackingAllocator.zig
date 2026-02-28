// SPDX-FileCopyrightText: 2026 Antti Kivi <antti@anttikivi.com>
// SPDX-License-Identifier: Apache-2.0

const TrackingAllocator = @This();

const std = @import("std");
const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;

child_allocator: Allocator,
total_allocated: u64 = 0,
total_freed: u64 = 0,
alloc_count: u64 = 0,

pub fn init(child_allocator: Allocator) TrackingAllocator {
    return .{ .child_allocator = child_allocator };
}

pub fn allocator(self: *TrackingAllocator) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
    const result = self.parent.rawAlloc(len, alignment, ret_addr);
    if (result != null) {
        self.total_allocated += len;
        self.allocation_count += 1;
    }
    return result;
}

fn resize(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
    const result = self.parent.rawResize(buf, alignment, new_len, ret_addr);
    if (result) {
        if (new_len > buf.len) {
            self.total_allocated += new_len - buf.len;
        } else {
            self.total_freed += buf.len - new_len;
        }
    }
    return result;
}

fn remap(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
    const result = self.parent.rawRemap(buf, alignment, new_len, ret_addr);
    if (result != null) {
        if (new_len > buf.len) {
            self.total_allocated += new_len - buf.len;
        } else {
            self.total_freed += buf.len - new_len;
        }
    }
    return result;
}

fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
    self.total_freed += buf.len;
    self.parent.rawFree(buf, alignment, ret_addr);
}
