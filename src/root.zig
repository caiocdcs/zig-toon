const std = @import("std");

pub const Value = @import("value.zig").Value;
pub const Encoder = @import("encoder.zig");
pub const Decoder = @import("decoder.zig");
pub const options = @import("options.zig");
pub const quoting = @import("quoting.zig");
pub const tokenizer = @import("tokenizer.zig");
pub const array_header = @import("array_header.zig");

pub const EncodeOptions = options.EncodeOptions;
pub const DecodeOptions = options.DecodeOptions;
pub const Delimiter = options.Delimiter;

pub const EncodeError = Encoder.EncodeError;
pub const DecodeError = Decoder.DecodeError;

pub fn encode(allocator: std.mem.Allocator, value: Value, opts: EncodeOptions) EncodeError![]u8 {
    return Encoder.encode(allocator, value, opts);
}

pub fn decode(allocator: std.mem.Allocator, source: []const u8, opts: DecodeOptions) DecodeError!Value {
    return Decoder.decode(allocator, source, opts);
}

pub fn decodeInto(comptime T: type, allocator: std.mem.Allocator, source: []const u8, opts: DecodeOptions) DecodeError!T {
    return Decoder.decodeInto(T, allocator, source, opts);
}

test "basic encode/decode round-trip" {
    const allocator = std.testing.allocator;

    var obj = Value.fromObject(allocator);
    defer obj.deinit(allocator);

    const key = try allocator.dupe(u8, "name");
    const val = try Value.fromString(allocator, "Alice");
    try obj.object.append(allocator, .{ .key = key, .value = val });

    const encoded = try encode(allocator, obj, .{});
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("name: Alice", encoded);

    var decoded = try decode(allocator, encoded, .{});
    defer decoded.deinit(allocator);

    try std.testing.expect(decoded.eql(obj));
}

test "encode primitive array" {
    const allocator = std.testing.allocator;

    var arr = Value.fromArray(allocator);
    defer arr.deinit(allocator);

    try arr.array.append(allocator, try Value.fromString(allocator, "a"));
    try arr.array.append(allocator, try Value.fromString(allocator, "b"));
    try arr.array.append(allocator, try Value.fromString(allocator, "c"));

    const encoded = try encode(allocator, arr, .{});
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("[3]: a,b,c", encoded);
}

test "decode primitive array" {
    const allocator = std.testing.allocator;

    const input = "[3]: a,b,c";
    var decoded = try decode(allocator, input, .{});
    defer decoded.deinit(allocator);

    try std.testing.expect(decoded == .array);
    try std.testing.expectEqual(@as(usize, 3), decoded.array.items.len);
}

test "encode tabular array" {
    const allocator = std.testing.allocator;

    var arr = Value.fromArray(allocator);
    defer arr.deinit(allocator);

    var obj1 = Value.fromObject(allocator);
    try obj1.object.append(allocator, .{
        .key = try allocator.dupe(u8, "id"),
        .value = Value.fromNumber(1),
    });
    try obj1.object.append(allocator, .{
        .key = try allocator.dupe(u8, "name"),
        .value = try Value.fromString(allocator, "Alice"),
    });

    var obj2 = Value.fromObject(allocator);
    try obj2.object.append(allocator, .{
        .key = try allocator.dupe(u8, "id"),
        .value = Value.fromNumber(2),
    });
    try obj2.object.append(allocator, .{
        .key = try allocator.dupe(u8, "name"),
        .value = try Value.fromString(allocator, "Bob"),
    });

    try arr.array.append(allocator, obj1);
    try arr.array.append(allocator, obj2);

    const encoded = try encode(allocator, arr, .{});
    defer allocator.free(encoded);

    var decoded = try decode(allocator, encoded, .{});
    defer decoded.deinit(allocator);

    try std.testing.expect(decoded == .array);
    try std.testing.expectEqual(@as(usize, 2), decoded.array.items.len);
}

test "empty object" {
    const allocator = std.testing.allocator;

    var obj = Value.fromObject(allocator);
    defer obj.deinit(allocator);

    const encoded = try encode(allocator, obj, .{});
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("", encoded);

    var decoded = try decode(allocator, "", .{});
    defer decoded.deinit(allocator);

    try std.testing.expect(decoded == .object);
    try std.testing.expectEqual(@as(usize, 0), decoded.object.items.len);
}

test "nested objects" {
    const allocator = std.testing.allocator;

    var root = Value.fromObject(allocator);
    defer root.deinit(allocator);

    var nested = Value.fromObject(allocator);
    try nested.object.append(allocator, .{
        .key = try allocator.dupe(u8, "x"),
        .value = Value.fromNumber(42),
    });

    try root.object.append(allocator, .{
        .key = try allocator.dupe(u8, "data"),
        .value = nested,
    });

    const encoded = try encode(allocator, root, .{});
    defer allocator.free(encoded);

    var decoded = try decode(allocator, encoded, .{});
    defer decoded.deinit(allocator);

    try std.testing.expect(decoded.eql(root));
}

test "decodeInto basic struct" {
    const allocator = std.testing.allocator;

    const User = struct {
        name: []const u8,
        age: i32,
        active: bool,
    };

    const input =
        \\name: Alice
        \\age: 30
        \\active: true
    ;

    const user = try decodeInto(User, allocator, input, .{});
    defer allocator.free(user.name);

    try std.testing.expectEqualStrings("Alice", user.name);
    try std.testing.expectEqual(@as(i32, 30), user.age);
    try std.testing.expect(user.active);
}

test "decodeInto with optional fields" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        email: ?[]const u8,
        age: ?i32,
    };

    const input =
        \\name: Bob
        \\email: bob@example.com
    ;

    const person = try decodeInto(Person, allocator, input, .{});
    defer {
        allocator.free(person.name);
        if (person.email) |email| allocator.free(email);
    }

    try std.testing.expectEqualStrings("Bob", person.name);
    try std.testing.expect(person.email != null);
    try std.testing.expectEqualStrings("bob@example.com", person.email.?);
    try std.testing.expect(person.age == null);
}

test "decodeInto with slice field" {
    const allocator = std.testing.allocator;

    const input = "[3]: 10,20,30";

    const numbers = try decodeInto([]i32, allocator, input, .{});
    defer allocator.free(numbers);

    try std.testing.expectEqual(@as(usize, 3), numbers.len);
    try std.testing.expectEqual(@as(i32, 10), numbers[0]);
    try std.testing.expectEqual(@as(i32, 20), numbers[1]);
    try std.testing.expectEqual(@as(i32, 30), numbers[2]);
}

test "decodeInto nested struct" {
    const allocator = std.testing.allocator;

    const Address = struct {
        city: []const u8,
        zip: i32,
    };

    const Person = struct {
        name: []const u8,
        address: Address,
    };

    const input =
        \\name: Charlie
        \\address:
        \\  city: NYC
        \\  zip: 10001
    ;

    const person = try decodeInto(Person, allocator, input, .{});
    defer {
        allocator.free(person.name);
        allocator.free(person.address.city);
    }

    try std.testing.expectEqualStrings("Charlie", person.name);
    try std.testing.expectEqualStrings("NYC", person.address.city);
    try std.testing.expectEqual(@as(i32, 10001), person.address.zip);
}

test "decodeInto array of structs" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i32,
        name: []const u8,
    };

    const input =
        \\[2]{id,name}:
        \\  1,Alice
        \\  2,Bob
    ;

    const users = try decodeInto([]User, allocator, input, .{});
    defer {
        for (users) |user| {
            allocator.free(user.name);
        }
        allocator.free(users);
    }

    try std.testing.expectEqual(@as(usize, 2), users.len);
    try std.testing.expectEqual(@as(i32, 1), users[0].id);
    try std.testing.expectEqualStrings("Alice", users[0].name);
    try std.testing.expectEqual(@as(i32, 2), users[1].id);
    try std.testing.expectEqualStrings("Bob", users[1].name);
}

test "decodeInto with default values" {
    const allocator = std.testing.allocator;

    const Config = struct {
        host: []const u8 = "localhost",
        port: i32 = 8080,
        debug: bool = false,
    };

    const input = "host: example.com";

    const config = try decodeInto(Config, allocator, input, .{});
    defer allocator.free(config.host);

    try std.testing.expectEqualStrings("example.com", config.host);
    try std.testing.expectEqual(@as(i32, 8080), config.port);
    try std.testing.expect(!config.debug);
}

test "decodeInto with enum" {
    const allocator = std.testing.allocator;

    const Status = enum {
        active,
        inactive,
        pending,
    };

    const Account = struct {
        name: []const u8,
        status: Status,
    };

    const input =
        \\name: Test
        \\status: active
    ;

    const account = try decodeInto(Account, allocator, input, .{});
    defer allocator.free(account.name);

    try std.testing.expectEqualStrings("Test", account.name);
    try std.testing.expectEqual(Status.active, account.status);
}
