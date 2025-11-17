# TOON Format for Zig

Spec-compliant Zig implementation of [TOON v2.0](https://github.com/toon-format/spec) - a compact format for LLM data transfer.

## Quick Example

**JSON** (40 bytes):
```json
{"users":[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]}
```

**TOON** (28 bytes - 30% smaller):
```
users[2]{id,name}:
  1,Alice
  2,Bob
```

## Installation

```bash
git clone https://github.com/your-org/toon-zig
cd toon-zig
zig build
```

## Usage

```zig
const toon = @import("toon_zig");

// Encode
const encoded = try toon.encode(allocator, value, .{});
defer allocator.free(encoded);

// Decode to generic Value
var value = try toon.decode(allocator, source, .{});
defer value.deinit(allocator);

// Decode directly into Zig types
const User = struct { name: []const u8, age: i32 };
const user = try toon.decodeInto(User, allocator, "name: Alice\nage: 30", .{});
defer allocator.free(user.name);
```

### Options

```zig
// Custom indent and delimiter
const encoded = try toon.encode(allocator, value, .{
    .indent = 4,
    .delimiter = .tab,
});

// Strict validation (default: true)
var decoded = try toon.decode(allocator, source, .{
    .strict = false,
});
```

## Testing

```bash
zig build test  # 212 tests, all passing
```

## Features

- Full TOON v2.0 spec compliance
- Primitives, objects, arrays (primitive, tabular, nested, mixed)
- Direct deserialization into Zig types with `decodeInto`
- Optional fields, default values, enums, nested structs
- Custom delimiters (comma, tab, pipe)
- Strict validation mode
- Zero memory leaks

### decodeInto

Deserialize TOON directly into Zig types:

```zig
// Structs
const User = struct { name: []const u8, age: i32 };
const user = try toon.decodeInto(User, allocator, input, .{});

// Arrays
const nums = try toon.decodeInto([]i32, allocator, "[3]: 10,20,30", .{});

// With optionals and defaults
const Config = struct {
    host: []const u8 = "localhost",
    port: ?i32,
};
```

See `examples/decode_into.zig` for more examples.

## License

MIT
