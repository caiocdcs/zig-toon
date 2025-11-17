const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const options = @import("options.zig");
const EncodeOptions = options.EncodeOptions;
const Delimiter = options.Delimiter;
const quoting = @import("quoting.zig");

pub const EncodeError = error{
    OutOfMemory,
};

pub const Encoder = struct {
    allocator: Allocator,
    options: EncodeOptions,
    output: std.ArrayList(u8),
    depth: usize,

    pub fn init(allocator: Allocator, opts: EncodeOptions) Encoder {
        return Encoder{
            .allocator = allocator,
            .options = opts,
            .output = std.ArrayList(u8){},
            .depth = 0,
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.output.deinit(self.allocator);
    }

    pub fn encode(self: *Encoder, value: Value) ![]u8 {
        try self.encodeValue(value, true);
        return self.output.toOwnedSlice(self.allocator);
    }

    fn encodeValue(self: *Encoder, value: Value, is_root: bool) EncodeError!void {
        switch (value) {
            .null => try self.encodePrimitive(value),
            .bool => try self.encodePrimitive(value),
            .number => try self.encodePrimitive(value),
            .string => try self.encodePrimitive(value),
            .array => |arr| {
                if (arr.items.len == 0) {
                    if (is_root) {
                        try self.output.appendSlice(self.allocator, "[0]:");
                    } else {
                        try self.output.appendSlice(self.allocator, "[0]:");
                    }
                    return;
                }

                if (self.isTabularArray(arr.items)) {
                    try self.encodeTabularArray(arr.items, is_root);
                } else if (self.isPrimitiveArray(arr.items)) {
                    try self.encodePrimitiveArray(arr.items, is_root);
                } else {
                    try self.encodeListArray(arr.items, is_root);
                }
            },
            .object => |obj| {
                if (is_root and obj.items.len == 0) {
                    return;
                }
                try self.encodeObject(obj.items, is_root);
            },
        }
    }

    fn isPrimitiveArray(self: *Encoder, items: []const Value) bool {
        _ = self;
        for (items) |item| {
            switch (item) {
                .null, .bool, .number, .string => {},
                else => return false,
            }
        }
        return true;
    }

    fn isTabularArray(self: *Encoder, items: []const Value) bool {
        _ = self;
        if (items.len == 0) return false;

        var first_obj: ?[]const Value.Entry = null;
        var field_count: usize = 0;

        for (items) |item| {
            switch (item) {
                .object => |obj| {
                    if (first_obj == null) {
                        first_obj = obj.items;
                        field_count = obj.items.len;
                    } else {
                        // Check if same number of keys
                        if (obj.items.len != field_count) {
                            return false;
                        }

                        // Check if same set of keys (order may vary)
                        for (first_obj.?) |first_entry| {
                            var found = false;
                            for (obj.items) |entry| {
                                if (std.mem.eql(u8, entry.key, first_entry.key)) {
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) return false;
                        }
                    }

                    // All values must be primitives
                    for (obj.items) |entry| {
                        switch (entry.value) {
                            .null, .bool, .number, .string => {},
                            else => return false,
                        }
                    }
                },
                else => return false,
            }
        }

        return first_obj != null and field_count > 0;
    }

    fn encodePrimitiveArray(self: *Encoder, items: []const Value, is_root: bool) !void {
        if (!is_root) {
            try self.output.writer(self.allocator).print("[{d}]: ", .{items.len});
        } else {
            try self.output.writer(self.allocator).print("[{d}]: ", .{items.len});
        }

        for (items, 0..) |item, i| {
            if (i > 0) {
                try self.output.append(self.allocator, self.options.delimiter.toChar());
            }
            const str = try self.primitiveToString(item);
            defer self.allocator.free(str);
            try self.output.appendSlice(self.allocator, str);
        }
    }

    fn encodeTabularArray(self: *Encoder, items: []const Value, is_root: bool) !void {
        const first_obj = items[0].object;
        const fields = first_obj.items;

        if (!is_root) {
            try self.output.writer(self.allocator).print("[{d}]{{", .{items.len});
        } else {
            try self.output.writer(self.allocator).print("[{d}]{{", .{items.len});
        }

        for (fields, 0..) |entry, i| {
            if (i > 0) {
                try self.output.append(self.allocator, self.options.delimiter.toChar());
            }
            const key = try quoting.quoteKey(self.allocator, entry.key);
            defer self.allocator.free(key);
            try self.output.appendSlice(self.allocator, key);
        }

        try self.output.appendSlice(self.allocator, "}:");

        for (items) |item| {
            try self.output.append(self.allocator, '\n');
            try self.writeIndent(self.depth + 1);

            // Output values in the order of the first object's keys
            for (fields, 0..) |field_entry, i| {
                if (i > 0) {
                    try self.output.append(self.allocator, self.options.delimiter.toChar());
                }

                // Find the value for this field in the current item
                var value: ?Value = null;
                for (item.object.items) |entry| {
                    if (std.mem.eql(u8, entry.key, field_entry.key)) {
                        value = entry.value;
                        break;
                    }
                }

                // Value must exist (validated by isTabularArray)
                const str = try self.primitiveToString(value.?);
                defer self.allocator.free(str);
                try self.output.appendSlice(self.allocator, str);
            }
        }
    }

    fn encodeListArray(self: *Encoder, items: []const Value, is_root: bool) !void {
        if (!is_root) {
            try self.output.writer(self.allocator).print("[{d}]:", .{items.len});
        } else {
            try self.output.writer(self.allocator).print("[{d}]:", .{items.len});
        }

        for (items) |item| {
            try self.output.append(self.allocator, '\n');
            try self.writeIndent(self.depth + 1);
            try self.output.appendSlice(self.allocator, "- ");

            switch (item) {
                .object => |obj| {
                    if (obj.items.len == 0) {
                        self.output.shrinkRetainingCapacity(self.output.items.len - 2);
                        try self.output.append(self.allocator, '-');
                        continue;
                    }

                    const first = obj.items[0];
                    const key = try quoting.quoteKey(self.allocator, first.key);
                    defer self.allocator.free(key);
                    try self.output.appendSlice(self.allocator, key);

                    const old_depth = self.depth;
                    self.depth = self.depth + 1;

                    switch (first.value) {
                        .object => |nested_obj| {
                            try self.output.appendSlice(self.allocator, ":");
                            if (nested_obj.items.len > 0) {
                                self.depth += 1;
                                try self.output.append(self.allocator, '\n');
                                try self.encodeObjectFields(nested_obj.items);
                                self.depth -= 1;
                            }
                        },
                        .array => {
                            try self.encodeValue(first.value, false);
                        },
                        else => {
                            try self.output.appendSlice(self.allocator, ": ");
                            const str = try self.primitiveToString(first.value);
                            defer self.allocator.free(str);
                            try self.output.appendSlice(self.allocator, str);
                        },
                    }

                    if (obj.items.len > 1) {
                        for (obj.items[1..]) |entry| {
                            try self.output.append(self.allocator, '\n');
                            try self.writeIndent(self.depth + 1);

                            const k = try quoting.quoteKey(self.allocator, entry.key);
                            defer self.allocator.free(k);
                            try self.output.appendSlice(self.allocator, k);

                            switch (entry.value) {
                                .object => |nested_obj| {
                                    try self.output.appendSlice(self.allocator, ":");
                                    if (nested_obj.items.len > 0) {
                                        self.depth += 2;
                                        try self.output.append(self.allocator, '\n');
                                        try self.encodeObjectFields(nested_obj.items);
                                        self.depth -= 2;
                                    }
                                },
                                .array => {
                                    self.depth += 1;
                                    try self.encodeValue(entry.value, false);
                                    self.depth -= 1;
                                },
                                else => {
                                    try self.output.appendSlice(self.allocator, ": ");
                                    const str = try self.primitiveToString(entry.value);
                                    defer self.allocator.free(str);
                                    try self.output.appendSlice(self.allocator, str);
                                },
                            }
                        }
                    }

                    self.depth = old_depth;
                },
                .array => |arr| {
                    if (self.isPrimitiveArray(arr.items)) {
                        if (arr.items.len == 0) {
                            try self.output.writer(self.allocator).print("[{d}]:", .{arr.items.len});
                        } else {
                            try self.output.writer(self.allocator).print("[{d}]: ", .{arr.items.len});
                            for (arr.items, 0..) |val, i| {
                                if (i > 0) {
                                    try self.output.append(self.allocator, self.options.delimiter.toChar());
                                }
                                const str = try self.primitiveToString(val);
                                defer self.allocator.free(str);
                                try self.output.appendSlice(self.allocator, str);
                            }
                        }
                    } else {
                        try self.output.writer(self.allocator).print("[{d}]:", .{arr.items.len});
                        const old_depth = self.depth;
                        self.depth = self.depth + 2;
                        for (arr.items) |inner| {
                            try self.output.append(self.allocator, '\n');
                            try self.writeIndent(self.depth);
                            try self.output.appendSlice(self.allocator, "- ");
                            try self.encodePrimitive(inner);
                        }
                        self.depth = old_depth;
                    }
                },
                else => {
                    try self.encodePrimitive(item);
                },
            }
        }
    }

    fn encodeObject(self: *Encoder, entries: []const Value.Entry, is_root: bool) !void {
        _ = is_root;
        try self.encodeObjectFields(entries);
    }

    fn encodeObjectFields(self: *Encoder, entries: []const Value.Entry) !void {
        for (entries, 0..) |entry, i| {
            if (i > 0) {
                try self.output.append(self.allocator, '\n');
            }
            try self.writeIndent(self.depth);

            const key = try quoting.quoteKey(self.allocator, entry.key);
            defer self.allocator.free(key);
            try self.output.appendSlice(self.allocator, key);
            try self.output.appendSlice(self.allocator, ": ");

            switch (entry.value) {
                .object => |obj| {
                    if (obj.items.len == 0) {
                        // Empty object - just key:
                        self.output.shrinkRetainingCapacity(self.output.items.len - 1);
                    } else {
                        self.output.shrinkRetainingCapacity(self.output.items.len - 1);
                        self.depth += 1;
                        try self.output.append(self.allocator, '\n');
                        try self.encodeObjectFields(obj.items);
                        self.depth -= 1;
                    }
                },
                .array => {
                    self.output.shrinkRetainingCapacity(self.output.items.len - 2);
                    try self.encodeValue(entry.value, false);
                },
                else => {
                    const str = try self.primitiveToString(entry.value);
                    defer self.allocator.free(str);
                    try self.output.appendSlice(self.allocator, str);
                },
            }
        }
    }

    fn encodePrimitive(self: *Encoder, value: Value) !void {
        const str = try self.primitiveToString(value);
        defer self.allocator.free(str);
        try self.output.appendSlice(self.allocator, str);
    }

    fn primitiveToString(self: *Encoder, value: Value) ![]u8 {
        return switch (value) {
            .null => self.allocator.dupe(u8, "null"),
            .bool => |b| self.allocator.dupe(u8, if (b) "true" else "false"),
            .number => |n| try self.formatNumber(n),
            .string => |s| quoting.quote(self.allocator, s, self.options.delimiter),
            else => error.OutOfMemory,
        };
    }

    fn formatNumber(self: *Encoder, n: f64) ![]u8 {
        if (std.math.isNan(n) or std.math.isInf(n)) {
            return self.allocator.dupe(u8, "null");
        }

        if (n == 0.0) {
            return self.allocator.dupe(u8, "0");
        }

        if (n == @floor(n) and @abs(n) < 1e15) {
            const int_val = @as(i64, @intFromFloat(n));
            return std.fmt.allocPrint(self.allocator, "{d}", .{int_val});
        }

        var buf: [64]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d}", .{n}) catch {
            return std.fmt.allocPrint(self.allocator, "{d}", .{n});
        };

        var result = std.ArrayList(u8){};
        errdefer result.deinit(self.allocator);

        if (std.mem.indexOfScalar(u8, str, 'e')) |_| {
            return std.fmt.allocPrint(self.allocator, "{d}", .{n});
        }

        try result.appendSlice(self.allocator, str);

        if (std.mem.indexOfScalar(u8, str, '.')) |_| {
            while (result.items.len > 0 and result.items[result.items.len - 1] == '0') {
                _ = result.pop();
            }
            if (result.items.len > 0 and result.items[result.items.len - 1] == '.') {
                _ = result.pop();
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn writeIndent(self: *Encoder, depth: usize) !void {
        const spaces = depth * self.options.indent;
        var i: usize = 0;
        while (i < spaces) : (i += 1) {
            try self.output.append(self.allocator, ' ');
        }
    }
};

pub fn encode(allocator: Allocator, value: Value, opts: EncodeOptions) ![]u8 {
    var encoder = Encoder.init(allocator, opts);
    defer encoder.deinit();
    return encoder.encode(value);
}
