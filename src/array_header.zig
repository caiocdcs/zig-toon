const std = @import("std");
const Allocator = std.mem.Allocator;
const options = @import("options.zig");
const Delimiter = options.Delimiter;
const quoting = @import("quoting.zig");

pub const HeaderError = error{
    InvalidHeader,
    InvalidLength,
    MissingColon,
    OutOfMemory,
    InvalidEscape,
    UnterminatedString,
};

pub const ArrayHeader = struct {
    length: usize,
    delimiter: Delimiter,
    fields: ?[][]const u8,
    inline_values: ?[]const u8,

    pub fn deinit(self: *ArrayHeader, allocator: Allocator) void {
        if (self.fields) |fields| {
            for (fields) |field| {
                allocator.free(field);
            }
            allocator.free(fields);
        }
    }
};

/// Parse array header: [N<delim?>]{field1<delim>field2}:
/// Returns header info and position after the colon
pub fn parseHeader(allocator: Allocator, line: []const u8) HeaderError!ArrayHeader {
    var pos: usize = 0;

    // Skip leading whitespace
    while (pos < line.len and std.ascii.isWhitespace(line[pos])) : (pos += 1) {}

    // Skip over quoted key if present (e.g., "key[test]"[3]: ...)
    if (pos < line.len and line[pos] == '"') {
        pos += 1;
        var in_escape = false;
        while (pos < line.len) : (pos += 1) {
            if (in_escape) {
                in_escape = false;
                continue;
            }
            if (line[pos] == '\\') {
                in_escape = true;
                continue;
            }
            if (line[pos] == '"') {
                pos += 1; // Move past closing quote
                break;
            }
        }
        // Skip any whitespace after the quoted key
        while (pos < line.len and line[pos] == ' ') : (pos += 1) {}
    }

    // Find opening bracket (after any quoted key)
    const bracket_start = std.mem.indexOfScalarPos(u8, line, pos, '[') orelse return error.InvalidHeader;
    pos = bracket_start + 1;

    // Parse length and delimiter
    const bracket_end = std.mem.indexOfScalarPos(u8, line, pos, ']') orelse return error.InvalidHeader;
    const bracket_content = line[pos..bracket_end];

    var length: usize = 0;
    var delimiter: Delimiter = .comma;

    // Check if last char in bracket is delimiter
    if (bracket_content.len > 0) {
        const last_char = bracket_content[bracket_content.len - 1];
        if (last_char == '\t') {
            delimiter = .tab;
            length = std.fmt.parseInt(usize, bracket_content[0 .. bracket_content.len - 1], 10) catch return error.InvalidLength;
        } else if (last_char == '|') {
            delimiter = .pipe;
            length = std.fmt.parseInt(usize, bracket_content[0 .. bracket_content.len - 1], 10) catch return error.InvalidLength;
        } else {
            length = std.fmt.parseInt(usize, bracket_content, 10) catch return error.InvalidLength;
        }
    } else {
        return error.InvalidLength;
    }

    pos = bracket_end + 1;

    // Check for fields segment {field1,field2,...}
    var fields: ?[][]const u8 = null;

    // Skip whitespace after bracket
    while (pos < line.len and line[pos] == ' ') : (pos += 1) {}

    if (pos < line.len and line[pos] == '{') {
        pos += 1;
        const brace_end = std.mem.indexOfScalarPos(u8, line, pos, '}') orelse return error.InvalidHeader;
        const fields_content = line[pos..brace_end];

        fields = try parseFields(allocator, fields_content, delimiter);
        pos = brace_end + 1;
    }

    // Skip whitespace before colon
    while (pos < line.len and line[pos] == ' ') : (pos += 1) {}

    // Must have colon
    if (pos >= line.len or line[pos] != ':') {
        if (fields) |f| {
            for (f) |field| allocator.free(field);
            allocator.free(f);
        }
        return error.MissingColon;
    }
    pos += 1;

    // Get inline values after colon (if any)
    var inline_values: ?[]const u8 = null;
    if (pos < line.len) {
        // Skip exactly one space after colon if present
        if (line[pos] == ' ') {
            pos += 1;
        }
        if (pos < line.len) {
            inline_values = line[pos..];
        }
    }

    return ArrayHeader{
        .length = length,
        .delimiter = delimiter,
        .fields = fields,
        .inline_values = inline_values,
    };
}

fn parseFields(allocator: Allocator, content: []const u8, delimiter: Delimiter) ![][]const u8 {
    var fields = std.ArrayList([]const u8){};
    errdefer {
        for (fields.items) |field| allocator.free(field);
        fields.deinit(allocator);
    }

    const delim_char = delimiter.toChar();
    var start: usize = 0;
    var i: usize = 0;
    var in_quotes = false;

    while (i < content.len) : (i += 1) {
        const c = content[i];

        if (c == '"') {
            in_quotes = !in_quotes;
        } else if (c == '\\' and in_quotes and i + 1 < content.len) {
            i += 1; // Skip next char
        } else if (c == delim_char and !in_quotes) {
            const field_raw = content[start..i];
            const field = try parseField(allocator, field_raw);
            try fields.append(allocator, field);
            start = i + 1;
        }
    }

    // Last field
    const field_raw = content[start..];
    const field = try parseField(allocator, field_raw);
    try fields.append(allocator, field);

    return fields.toOwnedSlice(allocator);
}

fn parseField(allocator: Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " ");

    if (trimmed.len == 0) {
        return allocator.dupe(u8, "");
    }

    if (trimmed[0] == '"') {
        return quoting.unescape(allocator, trimmed);
    }

    return allocator.dupe(u8, trimmed);
}
