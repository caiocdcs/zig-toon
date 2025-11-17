const std = @import("std");

pub const Delimiter = enum {
    comma,
    tab,
    pipe,

    pub fn toChar(self: Delimiter) u8 {
        return switch (self) {
            .comma => ',',
            .tab => '\t',
            .pipe => '|',
        };
    }

    pub fn fromChar(c: u8) ?Delimiter {
        return switch (c) {
            ',' => .comma,
            '\t' => .tab,
            '|' => .pipe,
            else => null,
        };
    }

    pub fn toString(self: Delimiter) []const u8 {
        return switch (self) {
            .comma => ",",
            .tab => "\t",
            .pipe => "|",
        };
    }
};

pub const EncodeOptions = struct {
    indent: u8 = 2,
    delimiter: Delimiter = .comma,
};

pub const DecodeOptions = struct {
    indent: u8 = 2,
    strict: bool = true,
};
