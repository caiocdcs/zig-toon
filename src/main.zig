const std = @import("std");
const toon = @import("toon_zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip();

    const command = args.next() orelse {
        std.debug.print("TOON CLI\n", .{});
        std.debug.print("Usage: toon_zig encode|decode|validate\n", .{});
        std.process.exit(1);
    };

    if (std.mem.eql(u8, command, "encode")) {
        try runEncode(allocator);
    } else if (std.mem.eql(u8, command, "decode")) {
        try runDecode(allocator);
    } else if (std.mem.eql(u8, command, "validate")) {
        try runValidate(allocator);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        std.process.exit(1);
    }
}

fn runEncode(allocator: std.mem.Allocator) !void {
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);

    const input = try stdin_reader.interface.allocRemaining(allocator, std.io.Limit.unlimited);
    defer allocator.free(input);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch |err| {
        std.debug.print("Failed to parse JSON: {}\n", .{err});
        std.process.exit(1);
    };
    defer parsed.deinit();

    var value = try jsonToToon(allocator, parsed.value);
    defer value.deinit(allocator);

    const encoded = toon.encode(allocator, value, .{}) catch |err| {
        std.debug.print("Failed to encode TOON: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(encoded);

    std.debug.print("{s}\n", .{encoded});
}

fn runDecode(allocator: std.mem.Allocator) !void {
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);

    const input = try stdin_reader.interface.allocRemaining(allocator, std.io.Limit.unlimited);
    defer allocator.free(input);

    var decoded = toon.decode(allocator, input, .{}) catch |err| {
        std.debug.print("Failed to decode TOON: {}\n", .{err});
        std.process.exit(1);
    };
    defer decoded.deinit(allocator);

    std.debug.print("Decoded successfully\n", .{});
}

fn runValidate(allocator: std.mem.Allocator) !void {
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);

    const input = try stdin_reader.interface.allocRemaining(allocator, std.io.Limit.unlimited);
    defer allocator.free(input);

    var decoded = toon.decode(allocator, input, .{ .strict = true }) catch |err| {
        std.debug.print("Validation failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer decoded.deinit(allocator);

    std.debug.print("Valid TOON document\n", .{});
}

fn jsonToToon(allocator: std.mem.Allocator, json_value: std.json.Value) !toon.Value {
    return switch (json_value) {
        .null => toon.Value.fromNull(),
        .bool => |b| toon.Value.fromBool(b),
        .integer => |i| toon.Value.fromNumber(@floatFromInt(i)),
        .float => |f| toon.Value.fromNumber(f),
        .number_string => |s| blk: {
            const num = std.fmt.parseFloat(f64, s) catch break :blk try toon.Value.fromString(allocator, s);
            break :blk toon.Value.fromNumber(num);
        },
        .string => |s| try toon.Value.fromString(allocator, s),
        .array => |arr| {
            var toon_arr = toon.Value.fromArray(allocator);
            for (arr.items) |item| {
                const val = try jsonToToon(allocator, item);
                try toon_arr.array.append(allocator, val);
            }
            return toon_arr;
        },
        .object => |obj| {
            var toon_obj = toon.Value.fromObject(allocator);
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try jsonToToon(allocator, entry.value_ptr.*);
                try toon_obj.object.append(allocator, .{ .key = key, .value = val });
            }
            return toon_obj;
        },
    };
}
