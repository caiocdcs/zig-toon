const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const options = @import("options.zig");
const DecodeOptions = options.DecodeOptions;
const Delimiter = options.Delimiter;
const tokenizer = @import("tokenizer.zig");
const array_header = @import("array_header.zig");
const quoting = @import("quoting.zig");

pub const DecodeError = error{
    InvalidSyntax,
    MissingColon,
    InvalidHeader,
    CountMismatch,
    WidthMismatch,
    InvalidIndentation,
    InvalidEscape,
    UnterminatedString,
    BlankLineInArray,
    InvalidLength,
    OutOfMemory,
    TypeMismatch,
    ArraySizeMismatch,
    MissingField,
    InvalidEnumValue,
    InvalidUnionTag,
    UnsupportedType,
};

pub const Decoder = struct {
    allocator: Allocator,
    options: DecodeOptions,
    lines: []Line,
    current: usize,

    const Line = struct {
        content: []const u8,
        depth: usize,
        line_num: usize,
    };

    pub fn init(allocator: Allocator, source: []const u8, opts: DecodeOptions) !Decoder {
        var lines = std.ArrayList(Line){};
        errdefer lines.deinit(allocator);

        var iter = tokenizer.splitLines(source);
        var line_num: usize = 0;
        while (iter.next()) |raw_line| : (line_num += 1) {
            if (tokenizer.isBlankLine(raw_line)) {
                continue;
            }

            const depth = try tokenizer.computeDepth(raw_line, opts.indent, opts.strict);
            const content = std.mem.trimLeft(u8, raw_line, " \t");

            try lines.append(allocator, .{
                .content = content,
                .depth = depth,
                .line_num = line_num,
            });
        }

        return Decoder{
            .allocator = allocator,
            .options = opts,
            .lines = try lines.toOwnedSlice(allocator),
            .current = 0,
        };
    }

    pub fn deinit(self: *Decoder) void {
        self.allocator.free(self.lines);
    }

    pub fn decode(self: *Decoder) !Value {
        if (self.lines.len == 0) {
            return Value.fromObject(self.allocator);
        }

        const first_line = self.lines[0];

        // Check if root is an array header
        if (self.isArrayHeader(first_line.content)) {
            return self.parseRootArray();
        }

        // Check if single primitive
        if (self.lines.len == 1 and first_line.depth == 0) {
            if (tokenizer.findUnquoted(first_line.content, ':') == null) {
                return self.parsePrimitive(first_line.content);
            }
        }

        // Otherwise parse as object
        return self.parseObject(0, 0);
    }

    fn isArrayHeader(self: *Decoder, line: []const u8) bool {
        _ = self;

        // Find the colon position (unquoted)
        const colon_pos = tokenizer.findUnquoted(line, ':') orelse return false;

        // Look for brackets before the colon
        const bracket_start = tokenizer.findUnquoted(line, '[') orelse return false;
        const bracket_end = tokenizer.findUnquoted(line, ']') orelse return false;

        // Brackets must be in correct order and before the colon
        return bracket_start < bracket_end and bracket_end < colon_pos;
    }

    fn parseRootArray(self: *Decoder) !Value {
        const line = self.lines[self.current];
        var header = try array_header.parseHeader(self.allocator, line.content);
        defer header.deinit(self.allocator);

        self.current += 1;

        if (header.inline_values) |values_str| {
            return self.parsePrimitiveArray(header.length, header.delimiter, values_str);
        }

        if (header.fields) |_| {
            return self.parseTabularArray(header.length, header.delimiter, header.fields.?, line.depth + 1);
        }

        return self.parseListArray(header.length, line.depth + 1);
    }

    fn parseObject(self: *Decoder, start_depth: usize, start_idx: usize) !Value {
        var obj = Value.fromObject(self.allocator);
        errdefer obj.deinit(self.allocator);

        self.current = start_idx;
        while (self.current < self.lines.len) {
            const line = self.lines[self.current];

            if (line.depth < start_depth) {
                break;
            }

            if (line.depth > start_depth) {
                break;
            }

            const colon_pos = tokenizer.findUnquoted(line.content, ':') orelse {
                if (self.options.strict) {
                    return error.MissingColon;
                }
                self.current += 1;
                continue;
            };

            const key_raw = line.content[0..colon_pos];
            const key = try self.parseKey(key_raw);
            errdefer self.allocator.free(key);

            const after_colon = std.mem.trimLeft(u8, line.content[colon_pos + 1 ..], " ");

            self.current += 1;

            const value = if (after_colon.len == 0) blk: {
                if (self.current < self.lines.len and self.lines[self.current].depth > start_depth) {
                    break :blk try self.parseValue(after_colon, start_depth + 1);
                } else {
                    break :blk Value.fromObject(self.allocator);
                }
            } else blk: {
                break :blk try self.parseValue(after_colon, start_depth + 1);
            };

            try obj.object.append(self.allocator, .{ .key = key, .value = value });
        }

        return obj;
    }

    fn parseValue(self: *Decoder, content: []const u8, next_depth: usize) DecodeError!Value {
        if (self.isArrayHeader(content)) {
            return self.parseArrayValue(content, next_depth);
        }

        if (content.len > 0) {
            return self.parsePrimitive(content);
        }

        if (self.current < self.lines.len and self.lines[self.current].depth >= next_depth) {
            return self.parseObject(next_depth, self.current);
        }

        return Value.fromObject(self.allocator);
    }

    fn parseArrayValue(self: *Decoder, content: []const u8, next_depth: usize) DecodeError!Value {
        var header = try array_header.parseHeader(self.allocator, content);
        defer header.deinit(self.allocator);

        if (header.inline_values) |values_str| {
            return self.parsePrimitiveArray(header.length, header.delimiter, values_str);
        }

        if (header.fields) |_| {
            return self.parseTabularArray(header.length, header.delimiter, header.fields.?, next_depth);
        }

        return self.parseListArray(header.length, next_depth);
    }

    fn parsePrimitiveArray(self: *Decoder, expected_len: usize, delimiter: Delimiter, values_str: []const u8) !Value {
        const tokens = try tokenizer.parseDelimitedValues(self.allocator, values_str, delimiter);
        defer self.allocator.free(tokens);

        if (self.options.strict and tokens.len != expected_len) {
            return error.CountMismatch;
        }

        var arr = Value.fromArray(self.allocator);
        errdefer arr.deinit(self.allocator);
        for (tokens) |token| {
            const val = try self.parsePrimitive(token);
            try arr.array.append(self.allocator, val);
        }

        return arr;
    }

    fn parseTabularArray(self: *Decoder, expected_len: usize, delimiter: Delimiter, fields: [][]const u8, row_depth: usize) !Value {
        var arr = Value.fromArray(self.allocator);
        errdefer arr.deinit(self.allocator);

        var row_count: usize = 0;
        while (self.current < self.lines.len) {
            const line = self.lines[self.current];

            if (line.depth < row_depth) {
                break;
            }

            if (line.depth > row_depth) {
                break;
            }

            const delim_pos = tokenizer.findUnquoted(line.content, delimiter.toChar());
            const colon_pos = tokenizer.findUnquoted(line.content, ':');

            const is_row = if (delim_pos == null and colon_pos == null) blk: {
                break :blk true;
            } else if (delim_pos != null and colon_pos == null) blk: {
                break :blk true;
            } else if (delim_pos != null and colon_pos != null) blk: {
                break :blk delim_pos.? < colon_pos.?;
            } else blk: {
                break :blk false;
            };

            if (!is_row) {
                break;
            }

            const values = try tokenizer.parseDelimitedValues(self.allocator, line.content, delimiter);
            defer self.allocator.free(values);

            if (self.options.strict and values.len != fields.len) {
                return error.WidthMismatch;
            }

            var obj = Value.fromObject(self.allocator);
            errdefer obj.deinit(self.allocator);
            for (fields, 0..) |field, i| {
                if (i < values.len) {
                    const key = try self.allocator.dupe(u8, field);
                    const val = try self.parsePrimitive(values[i]);
                    try obj.object.append(self.allocator, .{ .key = key, .value = val });
                }
            }

            try arr.array.append(self.allocator, obj);
            row_count += 1;
            self.current += 1;
        }

        if (self.options.strict and row_count != expected_len) {
            return error.CountMismatch;
        }

        return arr;
    }

    fn parseListArray(self: *Decoder, expected_len: usize, item_depth: usize) !Value {
        var arr = Value.fromArray(self.allocator);
        errdefer arr.deinit(self.allocator);

        var item_count: usize = 0;
        while (self.current < self.lines.len) {
            const line = self.lines[self.current];

            if (line.depth < item_depth) {
                break;
            }

            if (line.depth > item_depth) {
                break;
            }

            if (!tokenizer.isListItem(line.content)) {
                break;
            }

            const item_content = tokenizer.stripListMarker(line.content);
            self.current += 1;

            const val = try self.parseListItem(item_content, item_depth);
            try arr.array.append(self.allocator, val);
            item_count += 1;
        }

        if (self.options.strict and item_count != expected_len) {
            return error.CountMismatch;
        }

        return arr;
    }

    fn parseListItem(self: *Decoder, content: []const u8, item_depth: usize) DecodeError!Value {
        if (content.len == 0) {
            if (self.current < self.lines.len and self.lines[self.current].depth > item_depth) {
                return self.parseObject(item_depth + 1, self.current);
            }
            return Value.fromObject(self.allocator);
        }

        if (self.isArrayHeader(content)) {
            var header = try array_header.parseHeader(self.allocator, content);
            defer header.deinit(self.allocator);

            if (header.inline_values) |values_str| {
                return self.parsePrimitiveArray(header.length, header.delimiter, values_str);
            }

            if (header.fields) |_| {
                return self.parseTabularArray(header.length, header.delimiter, header.fields.?, item_depth + 1);
            }

            return self.parseListArray(header.length, item_depth + 1);
        }

        const colon_pos = tokenizer.findUnquoted(content, ':');
        if (colon_pos) |pos| {
            const key_raw = content[0..pos];
            const key = try self.parseKey(key_raw);
            const after_colon = std.mem.trimLeft(u8, content[pos + 1 ..], " ");

            var obj = Value.fromObject(self.allocator);
            errdefer obj.deinit(self.allocator);

            const first_value = if (after_colon.len == 0) blk: {
                if (self.current < self.lines.len and self.lines[self.current].depth > item_depth) {
                    break :blk try self.parseValue(after_colon, item_depth + 2);
                } else {
                    break :blk Value.fromObject(self.allocator);
                }
            } else blk: {
                break :blk try self.parseValue(after_colon, item_depth + 2);
            };

            try obj.object.append(self.allocator, .{ .key = key, .value = first_value });

            while (self.current < self.lines.len) {
                const line = self.lines[self.current];

                if (line.depth < item_depth + 1) {
                    break;
                }

                if (line.depth > item_depth + 1) {
                    break;
                }

                const col_pos = tokenizer.findUnquoted(line.content, ':') orelse {
                    break;
                };

                const next_key_raw = line.content[0..col_pos];
                const next_key = try self.parseKey(next_key_raw);
                const next_after_colon = std.mem.trimLeft(u8, line.content[col_pos + 1 ..], " ");

                self.current += 1;

                const next_value = if (next_after_colon.len == 0) blk: {
                    if (self.current < self.lines.len and self.lines[self.current].depth > item_depth + 1) {
                        break :blk try self.parseValue(next_after_colon, item_depth + 2);
                    } else {
                        break :blk Value.fromObject(self.allocator);
                    }
                } else blk: {
                    break :blk try self.parseValue(next_after_colon, item_depth + 2);
                };

                try obj.object.append(self.allocator, .{ .key = next_key, .value = next_value });
            }

            return obj;
        }

        return self.parsePrimitive(content);
    }

    fn parseKey(self: *Decoder, raw: []const u8) ![]const u8 {
        const trimmed = std.mem.trim(u8, raw, " ");

        if (trimmed.len == 0) {
            return self.allocator.dupe(u8, "");
        }

        if (trimmed[0] == '"') {
            return quoting.unescape(self.allocator, trimmed);
        }

        return self.allocator.dupe(u8, trimmed);
    }

    fn parsePrimitive(self: *Decoder, raw: []const u8) !Value {
        const trimmed = std.mem.trim(u8, raw, " ");

        if (trimmed.len == 0) {
            return Value{ .string = try self.allocator.dupe(u8, "") };
        }

        if (trimmed[0] == '"') {
            const unescaped = try quoting.unescape(self.allocator, trimmed);
            return Value{ .string = unescaped };
        }

        if (std.mem.eql(u8, trimmed, "null")) {
            return Value.fromNull();
        }

        if (std.mem.eql(u8, trimmed, "true")) {
            return Value.fromBool(true);
        }

        if (std.mem.eql(u8, trimmed, "false")) {
            return Value.fromBool(false);
        }

        if (self.parseNumber(trimmed)) |num| {
            return Value.fromNumber(num);
        }

        return Value{ .string = try self.allocator.dupe(u8, trimmed) };
    }

    fn parseNumber(self: *Decoder, s: []const u8) ?f64 {
        _ = self;

        if (s.len == 0) return null;

        if (s[0] == '0' and s.len > 1 and std.ascii.isDigit(s[1])) {
            return null;
        }

        const num = std.fmt.parseFloat(f64, s) catch return null;
        return num;
    }
};

pub fn decode(allocator: Allocator, source: []const u8, opts: DecodeOptions) !Value {
    var decoder = try Decoder.init(allocator, source, opts);
    defer decoder.deinit();
    return decoder.decode();
}

pub fn decodeInto(comptime T: type, allocator: Allocator, source: []const u8, opts: DecodeOptions) !T {
    var decoder = try Decoder.init(allocator, source, opts);
    defer decoder.deinit();
    const value = try decoder.decode();
    defer {
        var mut_value = value;
        mut_value.deinit(allocator);
    }
    return parseInto(T, allocator, value);
}

fn parseInto(comptime T: type, allocator: Allocator, value: Value) !T {
    const type_info = @typeInfo(T);

    switch (type_info) {
        .bool => {
            return switch (value) {
                .bool => |b| b,
                else => error.TypeMismatch,
            };
        },
        .int => {
            return switch (value) {
                .number => |n| @intFromFloat(n),
                else => error.TypeMismatch,
            };
        },
        .float => {
            return switch (value) {
                .number => |n| @floatCast(n),
                else => error.TypeMismatch,
            };
        },
        .optional => |opt| {
            if (value == .null) {
                return null;
            }
            return try parseInto(opt.child, allocator, value);
        },
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                if (ptr.child == u8) {
                    // String type
                    return switch (value) {
                        .string => |s| try allocator.dupe(u8, s),
                        else => error.TypeMismatch,
                    };
                } else {
                    // Slice of other types
                    return switch (value) {
                        .array => |arr| {
                            const slice = try allocator.alloc(ptr.child, arr.items.len);
                            errdefer allocator.free(slice);
                            for (arr.items, 0..) |item, i| {
                                slice[i] = try parseInto(ptr.child, allocator, item);
                            }
                            return slice;
                        },
                        else => error.TypeMismatch,
                    };
                }
            }
            return error.UnsupportedType;
        },
        .array => |arr| {
            return switch (value) {
                .array => |val_arr| {
                    if (val_arr.items.len != arr.len) {
                        return error.ArraySizeMismatch;
                    }
                    var result: T = undefined;
                    for (val_arr.items, 0..) |item, i| {
                        result[i] = try parseInto(arr.child, allocator, item);
                    }
                    return result;
                },
                else => error.TypeMismatch,
            };
        },
        .@"struct" => |struct_info| {
            if (value != .object) {
                return error.TypeMismatch;
            }

            var result: T = undefined;
            inline for (struct_info.fields) |field| {
                var found = false;
                for (value.object.items) |entry| {
                    if (std.mem.eql(u8, entry.key, field.name)) {
                        @field(result, field.name) = try parseInto(field.type, allocator, entry.value);
                        found = true;
                        break;
                    }
                }

                if (!found) {
                    if (field.defaultValue()) |default_value| {
                        @field(result, field.name) = default_value;
                    } else if (@typeInfo(field.type) == .optional) {
                        @field(result, field.name) = null;
                    } else {
                        return error.MissingField;
                    }
                }
            }
            return result;
        },
        .@"enum" => |enum_info| {
            _ = enum_info;
            return switch (value) {
                .string => |s| std.meta.stringToEnum(T, s) orelse error.InvalidEnumValue,
                else => error.TypeMismatch,
            };
        },
        .@"union" => |union_info| {
            if (union_info.tag_type == null) {
                return error.UnsupportedType;
            }

            if (value != .object or value.object.items.len != 1) {
                return error.TypeMismatch;
            }

            const entry = value.object.items[0];
            inline for (union_info.fields) |field| {
                if (std.mem.eql(u8, entry.key, field.name)) {
                    const field_value = try parseInto(field.type, allocator, entry.value);
                    return @unionInit(T, field.name, field_value);
                }
            }
            return error.InvalidUnionTag;
        },
        else => {
            @compileError("Unsupported type: " ++ @typeName(T));
        },
    }
}
