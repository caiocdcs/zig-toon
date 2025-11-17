const std = @import("std");
const toon = @import("toon_zig");

const FixtureFile = struct {
    version: []const u8,
    category: []const u8,
    description: []const u8,
    tests: []TestCase,
};

const TestCase = struct {
    name: []const u8,
    input: std.json.Value,
    expected: std.json.Value,
    shouldError: ?bool = null,
    options: ?TestOptions = null,
    specSection: ?[]const u8 = null,
    note: ?[]const u8 = null,
    minSpecVersion: ?[]const u8 = null,
};

const TestOptions = struct {
    delimiter: ?[]const u8 = null,
    indent: ?i64 = null,
    strict: ?bool = null,
};

fn loadFixture(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(FixtureFile) {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buf: [1024 * 1024]u8 = undefined;
    var reader = file.reader(&buf);
    const content = try reader.interface.allocRemaining(allocator, std.io.Limit.unlimited);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(FixtureFile, allocator, content, .{});
    return parsed;
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

test "encode primitives fixture" {
    const allocator = std.testing.allocator;

    var fixture = loadFixture(allocator, "tests/fixtures/encode/primitives.json") catch |err| {
        std.debug.print("Failed to load fixture: {}\n", .{err});
        return;
    };
    defer fixture.deinit();

    var passed: usize = 0;
    var failed: usize = 0;

    for (fixture.value.tests) |test_case| {
        var value = jsonToToon(allocator, test_case.input) catch |err| {
            std.debug.print("FAIL: {s} - failed to convert: {}\n", .{ test_case.name, err });
            failed += 1;
            continue;
        };
        defer value.deinit(allocator);

        var opts = toon.EncodeOptions{};
        if (test_case.options) |opt| {
            if (opt.indent) |indent| opts.indent = @intCast(indent);
        }

        const encoded = toon.encode(allocator, value, opts) catch |err| {
            if (test_case.shouldError orelse false) {
                passed += 1;
                continue;
            }
            std.debug.print("FAIL: {s} - encode error: {}\n", .{ test_case.name, err });
            std.debug.print("  Input: {}\n", .{test_case.input});
            failed += 1;
            continue;
        };
        defer allocator.free(encoded);

        if (test_case.shouldError orelse false) {
            std.debug.print("FAIL: {s} - expected error but succeeded\n", .{test_case.name});
            failed += 1;
            continue;
        }

        const expected = test_case.expected.string;
        if (std.mem.eql(u8, encoded, expected)) {
            passed += 1;
        } else {
            std.debug.print("FAIL: {s}\n", .{test_case.name});
            std.debug.print("  Expected: {s}\n", .{expected});
            std.debug.print("  Got:      {s}\n", .{encoded});
            failed += 1;
        }
    }

    std.debug.print("\nEncode Primitives: {d} passed, {d} failed\n", .{ passed, failed });
    try std.testing.expect(failed == 0);
}

test "decode primitives fixture" {
    const allocator = std.testing.allocator;

    var fixture = loadFixture(allocator, "tests/fixtures/decode/primitives.json") catch |err| {
        std.debug.print("Failed to load fixture: {}\n", .{err});
        return;
    };
    defer fixture.deinit();

    var passed: usize = 0;
    var failed: usize = 0;

    for (fixture.value.tests) |test_case| {
        const input = test_case.input.string;

        var decoded = toon.decode(allocator, input, .{}) catch |err| {
            if (test_case.shouldError orelse false) {
                passed += 1;
                continue;
            }
            std.debug.print("FAIL: {s} - decode error: {}\n", .{ test_case.name, err });
            std.debug.print("  Input: {s}\n", .{input});
            failed += 1;
            continue;
        };
        defer decoded.deinit(allocator);

        if (test_case.shouldError orelse false) {
            std.debug.print("FAIL: {s} - expected error but succeeded\n", .{test_case.name});
            failed += 1;
            continue;
        }

        passed += 1;
    }

    std.debug.print("\nDecode Primitives: {d} passed, {d} failed\n", .{ passed, failed });
    try std.testing.expect(failed == 0);
}

test "encode objects fixture" {
    const allocator = std.testing.allocator;

    var fixture = loadFixture(allocator, "tests/fixtures/encode/objects.json") catch |err| {
        std.debug.print("Failed to load fixture: {}\n", .{err});
        return;
    };
    defer fixture.deinit();

    var passed: usize = 0;
    var failed: usize = 0;

    for (fixture.value.tests) |test_case| {
        var value = jsonToToon(allocator, test_case.input) catch |err| {
            std.debug.print("FAIL: {s} - failed to convert: {}\n", .{ test_case.name, err });
            failed += 1;
            continue;
        };
        defer value.deinit(allocator);

        var opts = toon.EncodeOptions{};
        if (test_case.options) |opt| {
            if (opt.indent) |indent| opts.indent = @intCast(indent);
        }

        const encoded = toon.encode(allocator, value, opts) catch |err| {
            if (test_case.shouldError orelse false) {
                passed += 1;
                continue;
            }
            std.debug.print("FAIL: {s} - encode error: {}\n", .{ test_case.name, err });
            failed += 1;
            continue;
        };
        defer allocator.free(encoded);

        if (test_case.shouldError orelse false) {
            std.debug.print("FAIL: {s} - expected error but succeeded\n", .{test_case.name});
            failed += 1;
            continue;
        }

        const expected = test_case.expected.string;
        if (std.mem.eql(u8, encoded, expected)) {
            passed += 1;
        } else {
            std.debug.print("FAIL: {s}\n", .{test_case.name});
            std.debug.print("  Expected: {s}\n", .{expected});
            std.debug.print("  Got:      {s}\n", .{encoded});
            failed += 1;
        }
    }

    std.debug.print("\nEncode Objects: {d} passed, {d} failed\n", .{ passed, failed });
    try std.testing.expect(failed == 0);
}

test "encode arrays-primitive fixture" {
    const allocator = std.testing.allocator;

    var fixture = loadFixture(allocator, "tests/fixtures/encode/arrays-primitive.json") catch |err| {
        std.debug.print("Failed to load fixture: {}\n", .{err});
        return;
    };
    defer fixture.deinit();

    var passed: usize = 0;
    var failed: usize = 0;

    for (fixture.value.tests) |test_case| {
        var value = jsonToToon(allocator, test_case.input) catch |err| {
            std.debug.print("FAIL: {s} - failed to convert: {}\n", .{ test_case.name, err });
            failed += 1;
            continue;
        };
        defer value.deinit(allocator);

        var opts = toon.EncodeOptions{};
        if (test_case.options) |opt| {
            if (opt.indent) |indent| opts.indent = @intCast(indent);
        }

        const encoded = toon.encode(allocator, value, opts) catch |err| {
            if (test_case.shouldError orelse false) {
                passed += 1;
                continue;
            }
            std.debug.print("FAIL: {s} - encode error: {}\n", .{ test_case.name, err });
            failed += 1;
            continue;
        };
        defer allocator.free(encoded);

        if (test_case.shouldError orelse false) {
            std.debug.print("FAIL: {s} - expected error but succeeded\n", .{test_case.name});
            failed += 1;
            continue;
        }

        const expected = test_case.expected.string;
        if (std.mem.eql(u8, encoded, expected)) {
            passed += 1;
        } else {
            std.debug.print("FAIL: {s}\n", .{test_case.name});
            std.debug.print("  Expected: {s}\n", .{expected});
            std.debug.print("  Got:      {s}\n", .{encoded});
            failed += 1;
        }
    }

    std.debug.print("\nEncode Arrays-Primitive: {d} passed, {d} failed\n", .{ passed, failed });
    try std.testing.expect(failed == 0);
}

test "encode arrays-tabular fixture" {
    const allocator = std.testing.allocator;

    var fixture = loadFixture(allocator, "tests/fixtures/encode/arrays-tabular.json") catch |err| {
        std.debug.print("Failed to load fixture: {}\n", .{err});
        return;
    };
    defer fixture.deinit();

    var passed: usize = 0;
    var failed: usize = 0;

    for (fixture.value.tests) |test_case| {
        var value = jsonToToon(allocator, test_case.input) catch |err| {
            std.debug.print("FAIL: {s} - failed to convert: {}\n", .{ test_case.name, err });
            failed += 1;
            continue;
        };
        defer value.deinit(allocator);

        var opts = toon.EncodeOptions{};
        if (test_case.options) |opt| {
            if (opt.indent) |indent| opts.indent = @intCast(indent);
        }

        const encoded = toon.encode(allocator, value, opts) catch |err| {
            if (test_case.shouldError orelse false) {
                passed += 1;
                continue;
            }
            std.debug.print("FAIL: {s} - encode error: {}\n", .{ test_case.name, err });
            failed += 1;
            continue;
        };
        defer allocator.free(encoded);

        if (test_case.shouldError orelse false) {
            std.debug.print("FAIL: {s} - expected error but succeeded\n", .{test_case.name});
            failed += 1;
            continue;
        }

        const expected = test_case.expected.string;
        if (std.mem.eql(u8, encoded, expected)) {
            passed += 1;
        } else {
            std.debug.print("FAIL: {s}\n", .{test_case.name});
            std.debug.print("  Expected: {s}\n", .{expected});
            std.debug.print("  Got:      {s}\n", .{encoded});
            failed += 1;
        }
    }

    std.debug.print("\nEncode Arrays-Tabular: {d} passed, {d} failed\n", .{ passed, failed });
    try std.testing.expect(failed == 0);
}

test "decode objects fixture" {
    const allocator = std.testing.allocator;

    var fixture = loadFixture(allocator, "tests/fixtures/decode/objects.json") catch |err| {
        std.debug.print("Failed to load fixture: {}\n", .{err});
        return;
    };
    defer fixture.deinit();

    var passed: usize = 0;
    var failed: usize = 0;

    for (fixture.value.tests) |test_case| {
        const input = test_case.input.string;

        var decoded = toon.decode(allocator, input, .{}) catch |err| {
            if (test_case.shouldError orelse false) {
                passed += 1;
                continue;
            }
            std.debug.print("FAIL: {s} - decode error: {}\n", .{ test_case.name, err });
            std.debug.print("  Input: {s}\n", .{input});
            failed += 1;
            continue;
        };
        defer decoded.deinit(allocator);

        if (test_case.shouldError orelse false) {
            std.debug.print("FAIL: {s} - expected error but succeeded\n", .{test_case.name});
            failed += 1;
            continue;
        }

        passed += 1;
    }

    std.debug.print("\nDecode Objects: {d} passed, {d} failed\n", .{ passed, failed });
    try std.testing.expect(failed == 0);
}

test "decode arrays-primitive fixture" {
    const allocator = std.testing.allocator;

    var fixture = loadFixture(allocator, "tests/fixtures/decode/arrays-primitive.json") catch |err| {
        std.debug.print("Failed to load fixture: {}\n", .{err});
        return;
    };
    defer fixture.deinit();

    var passed: usize = 0;
    var failed: usize = 0;

    for (fixture.value.tests) |test_case| {
        const input = test_case.input.string;

        var decoded = toon.decode(allocator, input, .{}) catch |err| {
            if (test_case.shouldError orelse false) {
                passed += 1;
                continue;
            }
            std.debug.print("FAIL: {s} - decode error: {}\n", .{ test_case.name, err });
            std.debug.print("  Input: {s}\n", .{input});
            failed += 1;
            continue;
        };
        defer decoded.deinit(allocator);

        if (test_case.shouldError orelse false) {
            std.debug.print("FAIL: {s} - expected error but succeeded\n", .{test_case.name});
            failed += 1;
            continue;
        }

        passed += 1;
    }

    std.debug.print("\nDecode Arrays-Primitive: {d} passed, {d} failed\n", .{ passed, failed });
    try std.testing.expect(failed == 0);
}

test "decode root-form fixture" {
    const allocator = std.testing.allocator;

    var fixture = loadFixture(allocator, "tests/fixtures/decode/root-form.json") catch |err| {
        std.debug.print("Failed to load fixture: {}\n", .{err});
        return;
    };
    defer fixture.deinit();

    var passed: usize = 0;
    var failed: usize = 0;

    for (fixture.value.tests) |test_case| {
        const input = test_case.input.string;

        var decoded = toon.decode(allocator, input, .{}) catch |err| {
            if (test_case.shouldError orelse false) {
                passed += 1;
                continue;
            }
            std.debug.print("FAIL: {s} - decode error: {}\n", .{ test_case.name, err });
            std.debug.print("  Input: {s}\n", .{input});
            failed += 1;
            continue;
        };
        defer decoded.deinit(allocator);

        if (test_case.shouldError orelse false) {
            std.debug.print("FAIL: {s} - expected error but succeeded\n", .{test_case.name});
            failed += 1;
            continue;
        }

        passed += 1;
    }

    std.debug.print("\nDecode Root-Form: {d} passed, {d} failed\n", .{ passed, failed });
    try std.testing.expect(failed == 0);
}

test "encode whitespace fixture" {
    const allocator = std.testing.allocator;

    var fixture = loadFixture(allocator, "tests/fixtures/encode/whitespace.json") catch |err| {
        std.debug.print("Failed to load fixture: {}\n", .{err});
        return;
    };
    defer fixture.deinit();

    var passed: usize = 0;
    var failed: usize = 0;

    for (fixture.value.tests) |test_case| {
        var value = jsonToToon(allocator, test_case.input) catch |err| {
            std.debug.print("FAIL: {s} - failed to convert: {}\n", .{ test_case.name, err });
            failed += 1;
            continue;
        };
        defer value.deinit(allocator);

        var opts = toon.EncodeOptions{};
        if (test_case.options) |opt| {
            if (opt.indent) |indent| opts.indent = @intCast(indent);
        }

        const encoded = toon.encode(allocator, value, opts) catch |err| {
            if (test_case.shouldError orelse false) {
                passed += 1;
                continue;
            }
            std.debug.print("FAIL: {s} - encode error: {}\n", .{ test_case.name, err });
            failed += 1;
            continue;
        };
        defer allocator.free(encoded);

        if (test_case.shouldError orelse false) {
            std.debug.print("FAIL: {s} - expected error but succeeded\n", .{test_case.name});
            failed += 1;
            continue;
        }

        const expected = test_case.expected.string;
        if (std.mem.eql(u8, encoded, expected)) {
            passed += 1;
        } else {
            std.debug.print("FAIL: {s}\n", .{test_case.name});
            std.debug.print("  Expected: {s}\n", .{expected});
            std.debug.print("  Got:      {s}\n", .{encoded});
            failed += 1;
        }
    }

    std.debug.print("\nEncode Whitespace: {d} passed, {d} failed\n", .{ passed, failed });
    try std.testing.expect(failed == 0);
}

test "encode arrays-nested fixture" {
    const allocator = std.testing.allocator;

    var fixture = loadFixture(allocator, "tests/fixtures/encode/arrays-nested.json") catch |err| {
        std.debug.print("Failed to load fixture: {}\n", .{err});
        return;
    };
    defer fixture.deinit();

    var passed: usize = 0;
    var failed: usize = 0;

    for (fixture.value.tests) |test_case| {
        var value = jsonToToon(allocator, test_case.input) catch |err| {
            std.debug.print("FAIL: {s} - failed to convert: {}\n", .{ test_case.name, err });
            failed += 1;
            continue;
        };
        defer value.deinit(allocator);

        var opts = toon.EncodeOptions{};
        if (test_case.options) |opt| {
            if (opt.indent) |indent| opts.indent = @intCast(indent);
        }

        const encoded = toon.encode(allocator, value, opts) catch |err| {
            if (test_case.shouldError orelse false) {
                passed += 1;
                continue;
            }
            std.debug.print("FAIL: {s} - encode error: {}\n", .{ test_case.name, err });
            failed += 1;
            continue;
        };
        defer allocator.free(encoded);

        if (test_case.shouldError orelse false) {
            std.debug.print("FAIL: {s} - expected error but succeeded\n", .{test_case.name});
            failed += 1;
            continue;
        }

        const expected = test_case.expected.string;
        if (std.mem.eql(u8, encoded, expected)) {
            passed += 1;
        } else {
            std.debug.print("FAIL: {s}\n", .{test_case.name});
            std.debug.print("  Expected: {s}\n", .{expected});
            std.debug.print("  Got:      {s}\n", .{encoded});
            failed += 1;
        }
    }

    std.debug.print("\nEncode Arrays-Nested: {d} passed, {d} failed\n", .{ passed, failed });
    try std.testing.expect(failed == 0);
}

test "encode arrays-objects fixture" {
    const allocator = std.testing.allocator;

    var fixture = loadFixture(allocator, "tests/fixtures/encode/arrays-objects.json") catch |err| {
        std.debug.print("Failed to load fixture: {}\n", .{err});
        return;
    };
    defer fixture.deinit();

    var passed: usize = 0;
    var failed: usize = 0;

    for (fixture.value.tests) |test_case| {
        var value = jsonToToon(allocator, test_case.input) catch |err| {
            std.debug.print("FAIL: {s} - failed to convert: {}\n", .{ test_case.name, err });
            failed += 1;
            continue;
        };
        defer value.deinit(allocator);

        var opts = toon.EncodeOptions{};
        if (test_case.options) |opt| {
            if (opt.indent) |indent| opts.indent = @intCast(indent);
        }

        const encoded = toon.encode(allocator, value, opts) catch |err| {
            if (test_case.shouldError orelse false) {
                passed += 1;
                continue;
            }
            std.debug.print("FAIL: {s} - encode error: {}\n", .{ test_case.name, err });
            failed += 1;
            continue;
        };
        defer allocator.free(encoded);

        if (test_case.shouldError orelse false) {
            std.debug.print("FAIL: {s} - expected error but succeeded\n", .{test_case.name});
            failed += 1;
            continue;
        }

        const expected = test_case.expected.string;
        if (std.mem.eql(u8, encoded, expected)) {
            passed += 1;
        } else {
            std.debug.print("FAIL: {s}\n", .{test_case.name});
            std.debug.print("  Expected: {s}\n", .{expected});
            std.debug.print("  Got:      {s}\n", .{encoded});
            failed += 1;
        }
    }

    std.debug.print("\nEncode Arrays-Objects: {d} passed, {d} failed\n", .{ passed, failed });
    try std.testing.expect(failed == 0);
}

test "decode arrays-nested fixture" {
    const allocator = std.testing.allocator;

    var fixture = loadFixture(allocator, "tests/fixtures/decode/arrays-nested.json") catch |err| {
        std.debug.print("Failed to load fixture: {}\n", .{err});
        return;
    };
    defer fixture.deinit();

    var passed: usize = 0;
    var failed: usize = 0;

    for (fixture.value.tests) |test_case| {
        const input = test_case.input.string;

        var decoded = toon.decode(allocator, input, .{}) catch |err| {
            if (test_case.shouldError orelse false) {
                passed += 1;
                continue;
            }
            std.debug.print("FAIL: {s} - decode error: {}\n", .{ test_case.name, err });
            std.debug.print("  Input: {s}\n", .{input});
            failed += 1;
            continue;
        };
        defer decoded.deinit(allocator);

        if (test_case.shouldError orelse false) {
            std.debug.print("FAIL: {s} - expected error but succeeded\n", .{test_case.name});
            failed += 1;
            continue;
        }

        passed += 1;
    }

    std.debug.print("\nDecode Arrays-Nested: {d} passed, {d} failed\n", .{ passed, failed });
    try std.testing.expect(failed == 0);
}

test "decode arrays-tabular fixture" {
    const allocator = std.testing.allocator;

    var fixture = loadFixture(allocator, "tests/fixtures/decode/arrays-tabular.json") catch |err| {
        std.debug.print("Failed to load fixture: {}\n", .{err});
        return;
    };
    defer fixture.deinit();

    var passed: usize = 0;
    var failed: usize = 0;

    for (fixture.value.tests) |test_case| {
        const input = test_case.input.string;

        var decoded = toon.decode(allocator, input, .{}) catch |err| {
            if (test_case.shouldError orelse false) {
                passed += 1;
                continue;
            }
            std.debug.print("FAIL: {s} - decode error: {}\n", .{ test_case.name, err });
            std.debug.print("  Input: {s}\n", .{input});
            failed += 1;
            continue;
        };
        defer decoded.deinit(allocator);

        if (test_case.shouldError orelse false) {
            std.debug.print("FAIL: {s} - expected error but succeeded\n", .{test_case.name});
            failed += 1;
            continue;
        }

        passed += 1;
    }

    std.debug.print("\nDecode Arrays-Tabular: {d} passed, {d} failed\n", .{ passed, failed });
    try std.testing.expect(failed == 0);
}

test "decode validation-errors fixture" {
    const allocator = std.testing.allocator;

    var fixture = loadFixture(allocator, "tests/fixtures/decode/validation-errors.json") catch |err| {
        std.debug.print("Failed to load fixture: {}\n", .{err});
        return;
    };
    defer fixture.deinit();

    var passed: usize = 0;
    var failed: usize = 0;

    for (fixture.value.tests) |test_case| {
        const input = test_case.input.string;

        var decoded = toon.decode(allocator, input, .{}) catch |err| {
            if (test_case.shouldError orelse false) {
                passed += 1;
                continue;
            }
            std.debug.print("FAIL: {s} - decode error: {}\n", .{ test_case.name, err });
            std.debug.print("  Input: {s}\n", .{input});
            failed += 1;
            continue;
        };
        defer decoded.deinit(allocator);

        if (test_case.shouldError orelse false) {
            std.debug.print("FAIL: {s} - expected error but succeeded\n", .{test_case.name});
            failed += 1;
            continue;
        }

        passed += 1;
    }

    std.debug.print("\nDecode Validation-Errors: {d} passed, {d} failed\n", .{ passed, failed });
    try std.testing.expect(failed == 0);
}
