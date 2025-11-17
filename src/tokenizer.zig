const std = @import("std");
const Allocator = std.mem.Allocator;
const options = @import("options.zig");
const Delimiter = options.Delimiter;

pub const TokenError = error{
    InvalidIndentation,
    OutOfMemory,
};

pub const Line = struct {
    content: []const u8,
    depth: usize,
    raw: []const u8,
};

pub fn computeDepth(line: []const u8, indent_size: u8, strict: bool) TokenError!usize {
    var spaces: usize = 0;
    for (line) |c| {
        if (c == ' ') {
            spaces += 1;
        } else if (c == '\t') {
            if (strict) {
                return error.InvalidIndentation;
            }
            // Non-strict: treat tab as single indent level (implementation-defined)
            spaces += indent_size;
        } else {
            break;
        }
    }

    if (strict and spaces % indent_size != 0) {
        return error.InvalidIndentation;
    }

    return spaces / indent_size;
}

pub fn isBlankLine(line: []const u8) bool {
    for (line) |c| {
        if (!std.ascii.isWhitespace(c)) {
            return false;
        }
    }
    return true;
}

pub fn splitLines(source: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, source, '\n');
}

/// Parse a delimited line (for inline arrays or tabular rows)
pub fn parseDelimitedValues(allocator: Allocator, line: []const u8, delimiter: Delimiter) ![][]const u8 {
    var values = std.ArrayList([]const u8){};
    errdefer values.deinit(allocator);

    const delim_char = delimiter.toChar();
    var start: usize = 0;
    var i: usize = 0;
    var in_quotes = false;

    while (i < line.len) : (i += 1) {
        const c = line[i];

        if (c == '"') {
            in_quotes = !in_quotes;
        } else if (c == '\\' and in_quotes and i + 1 < line.len) {
            i += 1; // Skip escaped char
        } else if (c == delim_char and !in_quotes) {
            const token = std.mem.trim(u8, line[start..i], " ");
            try values.append(allocator, token);
            start = i + 1;
        }
    }

    // Last value
    const token = std.mem.trim(u8, line[start..], " ");
    try values.append(allocator, token);

    return values.toOwnedSlice(allocator);
}

/// Find first unquoted occurrence of a character
pub fn findUnquoted(line: []const u8, char: u8) ?usize {
    var in_quotes = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '"') {
            in_quotes = !in_quotes;
        } else if (c == '\\' and in_quotes and i + 1 < line.len) {
            i += 1;
        } else if (c == char and !in_quotes) {
            return i;
        }
    }
    return null;
}

/// Check if line starts with list marker "- "
pub fn isListItem(line: []const u8) bool {
    if (line.len == 0) return false;
    if (line[0] != '-') return false;
    // Accept "- " or just "-" (empty object list item per §10)
    return line.len == 1 or (line.len >= 2 and line[1] == ' ');
}

/// Strip list marker and return content after "- "
pub fn stripListMarker(line: []const u8) []const u8 {
    if (isListItem(line)) {
        // For just "-", return empty string; for "- ...", return content after "- "
        if (line.len == 1) return "";
        return line[2..];
    }
    return line;
}
