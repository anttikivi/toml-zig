// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Sentinel value for empty hash buckets.
pub const empty_bucket: u32 = std.math.maxInt(u32);

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,
    datetime: Datetime,
    local_datetime: Datetime,
    local_date: Date,
    local_time: Time,
    array: Array,
    table: Table,

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        switch (self) {
            .string => |s| try writer.print("{s}", .{s}),
            .int => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .datetime, .local_datetime => |dt| {
                assert(dt.isValid());
                try writer.print("{f}", .{dt});
            },
            .local_date => |d| {
                assert(d.isValid());
                try writer.print("{f}", .{d});
            },
            .local_time => |t| {
                assert(t.isValid());
                try writer.print("{f}", .{t});
            },
            .array => |array| {
                try writer.writeByte('[');
                for (array.items, 0..) |item, i| {
                    if (i > 0) {
                        try writer.writeAll(", ");
                    }
                    try writer.print("{f}", .{item});
                }
                try writer.writeByte(']');
            },
            .table => |t| {
                try writer.writeByte('{');
                var it = t.iterator();
                var i: usize = 0;
                while (it.next()) |entry| : (i += 1) {
                    if (i > 0) {
                        try writer.writeAll(", ");
                    }
                    try writer.print("{s} = {f}", .{ entry.key, entry.value });
                }
                try writer.writeByte('}');
            },
        }
    }
};

pub const Datetime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    nano: ?u32 = null,

    /// Timezone offset in minutes from UTC. If `null`, it means local datetime.
    tz: ?i16 = null,

    pub fn eql(self: @This(), other: @This()) bool {
        return self.year == other.year and
            self.month == other.month and
            self.day == other.day and
            self.hour == other.hour and
            self.minute == other.minute and
            self.second == other.second and
            self.nano == other.nano and
            self.tz == other.tz;
    }

    pub fn isValid(self: @This()) bool {
        if (self.month == 0 or self.month > 12) {
            return false;
        }

        const is_leap_year = self.year % 4 == 0 and (self.year % 100 != 0 or self.year % 400 == 0);
        const days_in_month = [_]u8{
            31,
            if (is_leap_year) 29 else 28,
            31,
            30,
            31,
            30,
            31,
            31,
            30,
            31,
            30,
            31,
        };
        if (self.day == 0 or self.day > days_in_month[self.month - 1]) {
            return false;
        }

        if (self.hour > 23) {
            return false;
        }

        if (self.minute > 59) {
            return false;
        }

        if ((self.month == 6 and self.day == 30) or (self.month == 12 and self.day == 31)) {
            if (self.second > 60) {
                return false;
            }
        } else if (self.second > 59) {
            return false;
        }

        return if (self.tz) |tz| isValidTimezone(tz) else true;
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        assert(self.isValid());

        try writer.print(
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}",
            .{ self.year, self.month, self.day, self.hour, self.minute, self.second },
        );

        if (self.nano) |nano| {
            assert(nano <= 999999999);
            try writer.print(".{d:0>9}", .{nano});
        }

        if (self.tz) |tz| {
            assert(tz >= -1440 and tz <= 1440);

            const t: u16 = @intCast(@abs(tz));
            if (t == 0) {
                try writer.writeAll("Z");
            } else {
                const h: u16 = t / 60;
                const m: u16 = t % 60;
                assert(h <= 23);
                assert(m <= 59);

                const sign = if (tz < 0) "-" else "+";

                try writer.print("{s}{d:0>2}:{d:0>2}", .{ sign, h, m });
            }
        }
    }
};

pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,

    pub fn eql(self: @This(), other: @This()) bool {
        return self.year == other.year and
            self.month == other.month and
            self.day == other.day;
    }

    pub fn isValid(self: @This()) bool {
        if (self.month == 0 or self.month > 12) {
            return false;
        }

        const is_leap_year = self.year % 4 == 0 and (self.year % 100 != 0 or self.year % 400 == 0);
        const days_in_month = [_]u8{
            31,
            if (is_leap_year) 29 else 28,
            31,
            30,
            31,
            30,
            31,
            31,
            30,
            31,
            30,
            31,
        };

        return self.day > 0 and self.day <= days_in_month[self.month - 1];
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        assert(self.isValid());
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ self.year, self.month, self.day });
    }
};

pub const Time = struct {
    hour: u8,
    minute: u8,
    second: u8,
    nano: ?u32 = null,

    pub fn eql(self: @This(), other: @This()) bool {
        return self.hour == other.hour and
            self.minute == other.minute and
            self.second == other.second and
            self.nano == other.nano;
    }

    pub fn isValid(self: @This()) bool {
        if (self.hour > 23) {
            return false;
        }

        if (self.minute > 59) {
            return false;
        }

        return self.second <= 59;
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        assert(self.isValid());
        try writer.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ self.hour, self.minute, self.second });

        if (self.nano) |nano| {
            assert(nano <= 999999999);
            try writer.print(".{d:0>9}", .{nano});
        }
    }
};

pub const Array = []const Value;

pub const Table = struct {
    entries: []const Entry,
    index: ?Index = null,

    const Self = @This();

    pub const Entry = struct {
        key: []const u8,
        value: Value,
    };

    pub const Iterator = struct {
        entries: []const Entry,
        cursor: usize = 0,

        pub fn next(self: *@This()) ?*const Entry {
            if (self.cursor >= self.entries.len) {
                return null;
            }

            const entry = &self.entries[self.cursor];
            self.cursor += 1;
            return entry;
        }
    };

    pub fn HashIndex(comptime E: type) type {
        return struct {
            buckets: []u32,
            mask: u32,

            pub fn init(gpa: Allocator, entries: []const E, capacity: usize) Allocator.Error!@This() {
                assert(std.math.isPowerOfTwo(capacity));
                assert(entries.len <= capacity / 2);

                const buckets = try gpa.alloc(u32, capacity);
                @memset(buckets, empty_bucket);

                const mask: u32 = @intCast(capacity - 1);

                for (entries, 0..) |entry, i| {
                    const hash = std.hash.Wyhash.hash(0, entry.key);
                    var bucket = hash & mask;
                    while (buckets[bucket] != empty_bucket) {
                        bucket = (bucket + 1) & mask;
                    }
                    buckets[bucket] = @intCast(i);
                }

                return .{
                    .buckets = buckets,
                    .mask = mask,
                };
            }

            pub fn deinit(self: @This(), gpa: Allocator) void {
                gpa.free(self.buckets);
            }

            pub fn lookup(self: @This(), entries: []const E, key: []const u8) ?usize {
                const hash = std.hash.Wyhash.hash(0, key);
                var bucket = hash & self.mask;
                var i: u32 = 0;

                while (i < self.buckets.len) : (i += 1) {
                    const j = self.buckets[bucket];
                    if (j == empty_bucket) {
                        return null;
                    }

                    if (std.mem.eql(u8, entries[j].key, key)) {
                        return j;
                    }

                    bucket = (bucket + 1) & self.mask;
                }

                return null;
            }
        };
    }

    pub const Index = HashIndex(Entry);

    pub fn iterator(self: *const Self) Iterator {
        return .{ .entries = self.entries };
    }

    pub fn contains(self: *const Self, key: []const u8) bool {
        return self.get(key) != null;
    }

    pub fn get(self: *const Self, key: []const u8) ?Value {
        if (self.getEntryPtr(key)) |entry| {
            return entry.value;
        }

        return null;
    }

    pub fn getPtr(self: *const Self, key: []const u8) ?*const Value {
        if (self.getEntryPtr(key)) |entry| {
            return &entry.value;
        }

        return null;
    }

    pub fn getEntryPtr(self: *const Self, key: []const u8) ?*const Entry {
        if (self.index) |index| {
            if (index.lookup(self.entries, key)) |i| {
                return &self.entries[i];
            }

            return null;
        }

        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return entry;
            }
        }

        return null;
    }

    pub fn getPath(self: *const Self, parts: []const []const u8) ?*const Value {
        if (parts.len == 0) {
            return null;
        }

        var table = self;
        for (parts, 0..) |part, i| {
            const value = table.getPtr(part) orelse return null;
            if (i == parts.len - 1) {
                return value;
            }

            switch (value.*) {
                .table => |*next_table| table = next_table,
                else => return null,
            }
        }

        return null;
    }
};

test "Table iterator, getEntryPtr, and getPath" {
    const testing = std.testing;

    const nested_entries = [_]Table.Entry{
        .{ .key = "c", .value = .{ .int = 1 } },
        .{ .key = "d.e", .value = .{ .string = "dot-key" } },
    };
    const nested: Table = .{ .entries = &nested_entries };

    const root_entries = [_]Table.Entry{
        .{ .key = "a", .value = .{ .table = nested } },
        .{ .key = "a.b", .value = .{ .int = 2 } },
    };
    const root: Table = .{ .entries = &root_entries };

    var it = root.iterator();
    try testing.expect(it.next() != null);
    try testing.expect(it.next() != null);
    try testing.expect(it.next() == null);

    const entry = root.getEntryPtr("a") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("a", entry.key);

    const nested_value = root.getPath(&.{ "a", "c" }) orelse return error.TestUnexpectedResult;
    try testing.expectEqualDeep(Value{ .int = 1 }, nested_value.*);

    const dotted_key_value = root.getPath(&.{"a.b"}) orelse return error.TestUnexpectedResult;
    try testing.expectEqualDeep(Value{ .int = 2 }, dotted_key_value.*);

    const dotted_nested_key_value = root.getPath(&.{ "a", "d.e" }) orelse return error.TestUnexpectedResult;
    try testing.expectEqualDeep(Value{ .string = "dot-key" }, dotted_nested_key_value.*);

    try testing.expect(root.getPath(&.{ "a", "missing" }) == null);
}

fn isValidTimezone(tz: i16) bool {
    const t: u16 = @abs(tz);
    const h = t / 60;
    const m = t % 60;

    if (h > 23) {
        return false;
    }

    return m < 60;
}
