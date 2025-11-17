const std = @import("std");
const Allocator = std.mem.Allocator;
const options = @import("options.zig");
const Delimiter = options.Delimiter;

pub const QuoteError = error{
    InvalidEscape,
    UnterminatedString,
    OutOfMemory,
};

/// Escape a string according to TOON spec (only \\ \" \n \r \t)
pub fn escape(allocator: Allocator, s: []const u8) ![]u8 {
    var count: usize = 0;
    for (s) |c| {
        count += switch (c) {
            '\\', '"', '\n', '\r', '\t' => 2,
            else => 1,
        };
    }

    if (count == s.len) {
        return allocator.dupe(u8, s);
    }

    var result = try allocator.alloc(u8, count);
    var i: usize = 0;
    for (s) |c| {
        switch (c) {
            '\\' => {
                result[i] = '\\';
                result[i + 1] = '\\';
                i += 2;
            },
            '"' => {
                result[i] = '\\';
                result[i + 1] = '"';
                i += 2;
            },
            '\n' => {
                result[i] = '\\';
                result[i + 1] = 'n';
                i += 2;
            },
            '\r' => {
                result[i] = '\\';
                result[i + 1] = 'r';
                i += 2;
            },
            '\t' => {
                result[i] = '\\';
                result[i + 1] = 't';
                i += 2;
            },
            else => {
                result[i] = c;
                i += 1;
            },
        }
    }
    return result;
}

/// Unescape a quoted string (must start and end with ")
pub fn unescape(allocator: Allocator, s: []const u8) QuoteError![]u8 {
    if (s.len < 2 or s[0] != '"' or s[s.len - 1] != '"') {
        return error.UnterminatedString;
    }

    const content = s[1 .. s.len - 1];
    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '\\') {
            if (i + 1 >= content.len) {
                return error.InvalidEscape;
            }
            const next = content[i + 1];
            const c: u8 = switch (next) {
                '\\' => '\\',
                '"' => '"',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => return error.InvalidEscape,
            };
            try result.append(allocator, c);
            i += 2;
        } else {
            try result.append(allocator, content[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Check if a string needs quoting according to TOON spec
pub fn needsQuoting(s: []const u8, delimiter: Delimiter) bool {
    if (s.len == 0) return true;

    // Leading or trailing whitespace
    if (std.ascii.isWhitespace(s[0]) or std.ascii.isWhitespace(s[s.len - 1])) {
        return true;
    }

    // Reserved literals
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "null")) {
        return true;
    }

    // Starts with hyphen
    if (s[0] == '-') {
        return true;
    }

    // Numeric-like (simple check for common patterns)
    if (isNumericLike(s)) {
        return true;
    }

    // Check for special characters
    const delim_char = delimiter.toChar();
    for (s) |c| {
        if (c == ':' or c == '"' or c == '\\' or c == '[' or c == ']' or c == '{' or c == '}') {
            return true;
        }
        if (c == delim_char) {
            return true;
        }
        if (c == '\n' or c == '\r' or c == '\t') {
            return true;
        }
    }

    return false;
}

fn isNumericLike(s: []const u8) bool {
    if (s.len == 0) return false;

    var i: usize = 0;
    if (s[i] == '-') {
        i += 1;
        if (i >= s.len) return false;
    }

    // Check for leading zero pattern (like "05", "0001")
    if (s[i] == '0' and i + 1 < s.len and std.ascii.isDigit(s[i + 1])) {
        return true;
    }

    var has_digit = false;
    var has_dot = false;
    var has_e = false;

    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (std.ascii.isDigit(c)) {
            has_digit = true;
        } else if (c == '.') {
            if (has_dot or has_e) return false;
            has_dot = true;
        } else if (c == 'e' or c == 'E') {
            if (has_e or !has_digit) return false;
            has_e = true;
            has_digit = false;
            if (i + 1 < s.len and (s[i + 1] == '+' or s[i + 1] == '-')) {
                i += 1;
            }
        } else {
            return false;
        }
    }

    return has_digit;
}

/// Check if a key is a valid unquoted key (identifier pattern)
pub fn isValidUnquotedKey(s: []const u8) bool {
    if (s.len == 0) return false;

    const first = s[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') {
        return false;
    }

    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') {
            return false;
        }
    }

    return true;
}

/// Quote a string for TOON output
pub fn quote(allocator: Allocator, s: []const u8, delimiter: Delimiter) ![]u8 {
    if (!needsQuoting(s, delimiter)) {
        return allocator.dupe(u8, s);
    }

    const escaped = try escape(allocator, s);
    defer allocator.free(escaped);

    var result = try allocator.alloc(u8, escaped.len + 2);
    result[0] = '"';
    @memcpy(result[1 .. result.len - 1], escaped);
    result[result.len - 1] = '"';

    return result;
}

/// Quote a key for TOON output
pub fn quoteKey(allocator: Allocator, key: []const u8) ![]u8 {
    if (isValidUnquotedKey(key)) {
        return allocator.dupe(u8, key);
    }

    const escaped = try escape(allocator, key);
    defer allocator.free(escaped);

    var result = try allocator.alloc(u8, escaped.len + 2);
    result[0] = '"';
    @memcpy(result[1 .. result.len - 1], escaped);
    result[result.len - 1] = '"';

    return result;
}
