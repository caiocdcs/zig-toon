const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    null: void,
    bool: bool,
    number: f64,
    string: []const u8,
    array: std.ArrayList(Value),
    object: std.ArrayList(Entry),

    pub const Entry = struct {
        key: []const u8,
        value: Value,
    };

    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .null, .bool, .number => {},
            .string => |s| allocator.free(s),
            .array => |*arr| {
                for (arr.items) |*item| {
                    item.deinit(allocator);
                }
                arr.deinit(allocator);
            },
            .object => |*obj| {
                for (obj.items) |*entry| {
                    allocator.free(entry.key);
                    entry.value.deinit(allocator);
                }
                obj.deinit(allocator);
            },
        }
    }

    pub fn clone(self: Value, allocator: Allocator) !Value {
        return switch (self) {
            .null => .{ .null = {} },
            .bool => |b| .{ .bool = b },
            .number => |n| .{ .number = n },
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .array => |arr| {
                var new_arr = std.ArrayList(Value){};
                errdefer new_arr.deinit(allocator);
                for (arr.items) |item| {
                    try new_arr.append(allocator, try item.clone(allocator));
                }
                return .{ .array = new_arr };
            },
            .object => |obj| {
                var new_obj = std.ArrayList(Entry){};
                errdefer new_obj.deinit(allocator);
                for (obj.items) |entry| {
                    try new_obj.append(allocator, .{
                        .key = try allocator.dupe(u8, entry.key),
                        .value = try entry.value.clone(allocator),
                    });
                }
                return .{ .object = new_obj };
            },
        };
    }

    pub fn fromNull() Value {
        return .{ .null = {} };
    }

    pub fn fromBool(b: bool) Value {
        return .{ .bool = b };
    }

    pub fn fromNumber(n: f64) Value {
        return .{ .number = n };
    }

    pub fn fromString(allocator: Allocator, s: []const u8) !Value {
        return .{ .string = try allocator.dupe(u8, s) };
    }

    pub fn fromArray(allocator: Allocator) Value {
        _ = allocator;
        return .{ .array = std.ArrayList(Value){} };
    }

    pub fn fromObject(allocator: Allocator) Value {
        _ = allocator;
        return .{ .object = std.ArrayList(Entry){} };
    }

    pub fn eql(self: Value, other: Value) bool {
        if (@as(std.meta.Tag(Value), self) != @as(std.meta.Tag(Value), other)) {
            return false;
        }
        return switch (self) {
            .null => true,
            .bool => |a| a == other.bool,
            .number => |a| a == other.number,
            .string => |a| std.mem.eql(u8, a, other.string),
            .array => |a| {
                if (a.items.len != other.array.items.len) return false;
                for (a.items, other.array.items) |item_a, item_b| {
                    if (!item_a.eql(item_b)) return false;
                }
                return true;
            },
            .object => |a| {
                if (a.items.len != other.object.items.len) return false;
                for (a.items, other.object.items) |entry_a, entry_b| {
                    if (!std.mem.eql(u8, entry_a.key, entry_b.key)) return false;
                    if (!entry_a.value.eql(entry_b.value)) return false;
                }
                return true;
            },
        };
    }
};
