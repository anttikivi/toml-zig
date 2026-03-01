// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
// SPDX-License-Identifier: Apache-2.0

const TrackingAllocator = @This();

const std = @import("std");
const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;

child_allocator: Allocator,
alloc_count: u64 = 0,
total_allocated: u64 = 0,
total_freed: u64 = 0,
live_bytes: u64 = 0,
peak_live_bytes: u64 = 0,

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
    const result = self.child_allocator.rawAlloc(len, alignment, ret_addr);
    if (result != null) {
        const n: u64 = @intCast(len);
        self.total_allocated += n;
        self.alloc_count += 1;
        self.live_bytes += n;
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
    }
    return result;
}

fn resize(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
    const result = self.child_allocator.rawResize(buf, alignment, new_len, ret_addr);
    if (result) {
        self.alloc_count += 1;

        const old_n: u64 = @intCast(buf.len);
        const new_n: u64 = @intCast(new_len);

        if (new_n > old_n) {
            const diff = new_n - old_n;
            self.total_allocated += diff;
            self.live_bytes += diff;
        } else {
            const diff = old_n - new_n;
            std.debug.assert(self.live_bytes >= diff);
            self.total_freed += diff;
            self.live_bytes -= diff;
        }

        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
    }
    return result;
}

fn remap(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
    const result = self.child_allocator.rawRemap(buf, alignment, new_len, ret_addr);
    if (result != null) {
        self.alloc_count += 1;

        const old_n: u64 = @intCast(buf.len);
        const new_n: u64 = @intCast(new_len);

        if (new_n > old_n) {
            const diff = new_n - old_n;
            self.total_allocated += diff;
            self.live_bytes += diff;
        } else {
            const diff = old_n - new_n;
            std.debug.assert(self.live_bytes >= diff);
            self.total_freed += diff;
            self.live_bytes -= diff;
        }

        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
    }
    return result;
}

fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
    const n: u64 = @intCast(buf.len);
    std.debug.assert(self.live_bytes >= n);
    self.total_freed += n;
    self.live_bytes -= n;
    self.child_allocator.rawFree(buf, alignment, ret_addr);
}
