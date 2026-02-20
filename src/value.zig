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
    array: []const Value,
    table: Table,
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
};

pub const Table = struct {
    entries: []const Entry,
    index: ?Index = null,

    const Self = @This();

    pub const Entry = struct {
        key: []const u8,
        value: Value,
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

                while (i < self.mask) : (i += 1) {
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

    pub fn contains(self: *const Self, key: []const u8) bool {
        return self.get(key) != null;
    }

    pub fn get(self: *const Self, key: []const u8) ?Value {
        if (self.index) |index| {
            if (index.lookup(self.entries, key)) |i| {
                return self.entries[i].value;
            }

            return null;
        }

        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return entry.value;
            }
        }

        return null;
    }
};

fn isValidTimezone(tz: i16) bool {
    const t: u16 = @abs(tz);
    const h = t / 60;
    const m = t % 60;

    if (h > 23) {
        return false;
    }

    return m < 60;
}
