//! JSON backend for the typed walk.
//!
//! The typed layer decides what Zig type is being read or written. This file
//! only implements JSON syntax, tokenization, and container state management.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic_mod = @import("diagnostic.zig");
const typed = @import("typed.zig");
const meta = @import("meta.zig");
const bulk = @import("bulk.zig");
const Number = typed.Number;
const StringToken = typed.StringToken;
const ValueKind = typed.ValueKind;

pub const FieldCase = meta.FieldCase;

/// How a `[N]u8` field is carried in JSON, which has no byte type.
pub const BytesEncoding = enum {
    /// A JSON string holding the raw bytes. Exact only for valid UTF-8.
    string,
    /// Padded standard base64 (RFC 4648 §4), as JSON Schema's `contentEncoding: base64`.
    base64,
    /// Unpadded URL-safe base64 (RFC 4648 §5), as JOSE (RFC 7515) and URL path segments use.
    base64url,
};

/// Reader-side limits and aliasing policy.
/// One JSON value kept as its text; see `typed.RawOf`.
pub const Raw = typed.RawOf(.json);

pub const ReadConfig = struct {
    max_input_bytes: usize = 16 * 1024 * 1024,
    borrow_strings: bool = false,
    /// Must match the writer's `bytes`; a base64 field that does not decode is `error.InvalidBytes`.
    bytes: BytesEncoding = .string,
    /// Most containers open at once, at most 128 (`error.JsonNestingTooDeep`).
    max_depth: usize = 128,
    /// Most values in the whole input, object keys and values each counted (`error.TooManyItems`).
    max_items: usize = std.math.maxInt(usize),
    /// Longest string in bytes after its escapes are decoded (`error.StringTooLong`).
    max_string_len: usize = std.math.maxInt(usize),
};
pub const WriteConfig = struct {
    bytes: BytesEncoding = .string,
    /// For `valueWriter`: sort each map's keys as deterministic CBOR does (shorter first, then bytewise).
    sort_keys: bool = true,
};

fn bytesEncoding(comptime Config: type, cfg: Config) BytesEncoding {
    if (comptime meta.hasField(Config, "bytes")) return cfg.bytes;
    return .string;
}
pub const ParseError = anyerror;

const ContainerKind = enum {
    object,
    array,
};

const Container = struct {
    kind: ContainerKind,
    first: bool,
};

pub fn serializer(writer: *std.Io.Writer, comptime cfg: anytype) JsonSerializer(@TypeOf(cfg)) {
    return JsonSerializer(@TypeOf(cfg)).init(writer, cfg);
}

/// The container stack is fixed at 128, so a larger `max_depth` cannot be honoured.
fn checkLimits(comptime cfg: anytype) void {
    if (comptime meta.hasField(@TypeOf(cfg), "max_depth") and cfg.max_depth > 128) {
        @compileError("max_depth is at most 128, the depth of the container stack");
    }
}

/// Reader-backed deserializer. The reader payload is copied and owned by the backend.
pub fn readerDeserializer(allocator: Allocator, reader: *std.Io.Reader, comptime cfg: anytype) !JsonDeserializer(@TypeOf(cfg)) {
    comptime checkLimits(cfg);
    const input = try reader.allocRemaining(allocator, .limited(effectiveMaxInputBytes(cfg)));
    return JsonDeserializer(@TypeOf(cfg)).initOwned(input, cfg);
}

/// Slice-backed deserializer. The raw bytes are borrowed from the caller.
pub fn sliceDeserializer(allocator: Allocator, input: []const u8, comptime cfg: anytype) !JsonDeserializer(@TypeOf(cfg)) {
    comptime checkLimits(cfg);
    _ = allocator;
    return JsonDeserializer(@TypeOf(cfg)).initBorrowed(input, cfg);
}

/// Streaming JSON writer used by the typed layer.
pub fn JsonSerializer(comptime Config: type) type {
    return struct {
        writer: *std.Io.Writer,
        cfg: Config,
        stack: [128]Container = undefined,
        stack_len: usize = 0,

        const Self = @This();

        /// A tagged union is a string or a one-entry object (see `typed.zig`).
        pub const supports_unions = true;

        fn init(writer: *std.Io.Writer, cfg: Config) Self {
            return .{
                .writer = writer,
                .cfg = cfg,
            };
        }

        pub fn emitNull(self: *Self) !void {
            _ = self.cfg;
            try self.writer.writeAll("null");
        }

        pub fn emitBool(self: *Self, value: bool) !void {
            if (value) {
                try self.writer.writeAll("true");
            } else {
                try self.writer.writeAll("false");
            }
        }

        pub fn emitInteger(self: *Self, value: anytype) !void {
            try self.writer.print("{}", .{value});
        }

        /// JSON has no NaN or infinity (RFC 8259 §6), so a float that is neither finite is
        /// refused instead of written as `nan` or `inf`, which no JSON parser accepts.
        pub fn emitFloat(self: *Self, value: anytype) !void {
            if (!std.math.isFinite(value)) return error.NonFiniteFloat;
            try self.writer.print("{}", .{value});
        }

        pub fn emitString(self: *Self, value: []const u8) !void {
            try writeEscapedString(self.writer, value);
        }

        /// Where the writer is in an extras object (see `beginExtras`).
        pub const ExtrasCursor = struct {
            bytes: []const u8,
            pos: usize,
        };

        /// Starts walking an extras object: JSON text as a read leaves it, `{"key":value,...}`.
        pub fn beginExtras(self: *Self, bytes: []const u8) !ExtrasCursor {
            _ = self;
            if (bytes.len == 0) return .{ .bytes = bytes, .pos = 0 };
            var parser: Parser = .{ .input = bytes };
            parser.skipWhitespace();
            if (parser.consume() != '{') return error.UnexpectedToken;
            return .{ .bytes = bytes, .pos = parser.index };
        }

        /// Writes the members of an extras object after the declared ones, each as it is. None may
        /// repeat a declared member.
        pub fn finishExtras(self: *Self, cursor: *ExtrasCursor, comptime declared: []const meta.FieldKey) !void {
            if (cursor.bytes.len == 0) return;
            var parser: Parser = .{ .input = cursor.bytes, .index = cursor.pos };
            parser.skipWhitespace();
            if (parser.peek() == '}') return;
            while (true) {
                parser.skipWhitespace();
                const key_start = parser.index;
                try parser.skipStringTrusted();
                const key = cursor.bytes[key_start..parser.index];
                inline for (declared) |member| {
                    switch (member) {
                        .text => |name| if (rawKeyIs(key, name)) return error.DuplicateField,
                        .integer => {},
                    }
                }
                parser.skipWhitespace();
                if (parser.consume() != ':') return error.UnexpectedToken;
                parser.skipWhitespace();
                const value_start = parser.index;
                try parser.skipValueTrusted(0);

                const container = self.current();
                if (container.kind != .object) return error.InvalidJsonState;
                if (!container.first) try self.writer.writeByte(',') else container.first = false;
                try self.writer.writeAll(key);
                try self.writer.writeByte(':');
                try self.writer.writeAll(cursor.bytes[value_start..parser.index]);

                parser.skipWhitespace();
                switch (parser.consume() orelse return error.UnexpectedEndOfInput) {
                    ',' => {},
                    '}' => return,
                    else => return error.UnexpectedToken,
                }
            }
        }

        /// A streaming writer for a wire type's encode hook; see `Encoder`.
        pub fn encoder(self: *Self) Encoder {
            return .{ .writer = self.writer, .encoding = bytesEncoding(Config, self.cfg) };
        }

        pub const raw_format: typed.RawFormat = .json;

        /// Writes JSON text that was read as `json.Raw`, unchanged.
        pub fn emitRaw(self: *Self, value: []const u8) !void {
            try self.writer.writeAll(value);
        }

        pub fn emitBytes(self: *Self, value: []const u8) !void {
            try writeBytesText(self.writer, bytesEncoding(Config, self.cfg), value);
        }

        pub fn beginStruct(self: *Self, comptime T: type) !void {
            _ = T;
            try self.writer.writeByte('{');
            try self.push(.{ .kind = .object, .first = true });
        }

        pub fn structPassCount(comptime T: type) usize {
            _ = T;
            return 1;
        }

        pub fn includeStructField(comptime Parent: type, comptime FieldType: type, comptime pass: usize) bool {
            _ = Parent;
            _ = FieldType;
            _ = pass;
            return true;
        }

        pub fn beginStructField(self: *Self, comptime Parent: type, comptime name: []const u8, comptime FieldType: type) !bool {
            _ = Parent;
            _ = FieldType;
            const container = self.current();
            if (container.kind != .object) return error.InvalidJsonState;
            if (!container.first) {
                try self.writer.writeByte(',');
            } else {
                container.first = false;
            }
            try writeEscapedString(self.writer, name);
            try self.writer.writeByte(':');
            return true;
        }

        pub fn endStructField(self: *Self, comptime Parent: type, comptime name: []const u8, comptime FieldType: type) !void {
            _ = self;
            _ = Parent;
            _ = name;
            _ = FieldType;
        }

        pub fn endStruct(self: *Self, comptime T: type) !void {
            _ = T;
            _ = self.pop();
            try self.writer.writeByte('}');
        }

        pub fn beginArray(self: *Self, comptime Child: type, len: usize) !void {
            _ = Child;
            _ = len;
            try self.writer.writeByte('[');
            try self.push(.{ .kind = .array, .first = true });
        }

        pub fn beginArrayItem(self: *Self, comptime Child: type, index: usize) !void {
            _ = Child;
            _ = index;
            const container = self.current();
            if (container.kind != .array) return error.InvalidJsonState;
            if (!container.first) {
                try self.writer.writeByte(',');
            } else {
                container.first = false;
            }
        }

        pub fn endArrayItem(self: *Self, comptime Child: type, index: usize) !void {
            _ = self;
            _ = Child;
            _ = index;
        }

        pub fn endArray(self: *Self, comptime Child: type, len: usize) !void {
            _ = Child;
            _ = len;
            _ = self.pop();
            try self.writer.writeByte(']');
        }

        fn push(self: *Self, container: Container) !void {
            if (self.stack_len == self.stack.len) return error.JsonNestingTooDeep;
            self.stack[self.stack_len] = container;
            self.stack_len += 1;
        }

        fn pop(self: *Self) Container {
            self.stack_len -= 1;
            return self.stack[self.stack_len];
        }

        fn current(self: *Self) *Container {
            return &self.stack[self.stack_len - 1];
        }
    };
}

/// Pull-based JSON reader used by the typed layer.
pub fn JsonDeserializer(comptime Config: type) type {
    return struct {
        input: []const u8,
        cfg: Config,
        parser: Parser,
        owns_input: bool,
        can_borrow_strings: bool,
        stack: [128]Container = undefined,
        stack_len: usize = 0,
        max_depth: usize = 128,
        max_items: usize = std.math.maxInt(usize),
        items: usize = 0,
        /// Members collected for an extras field, innermost struct last; see `captureExtra`.
        extras: std.ArrayList(ExtraEntry) = .empty,
        extra_keys: std.ArrayList(u8) = .empty,

        const Self = @This();

        /// A tagged union is a string or a one-entry object (see `typed.zig`).
        pub const supports_unions = true;

        fn initBorrowed(input: []const u8, cfg: Config) Self {
            return .{
                .input = input,
                .cfg = cfg,
                .parser = .{ .input = input, .max_string_len = readLimit(cfg, "max_string_len", std.math.maxInt(usize)) },
                .max_depth = readLimit(cfg, "max_depth", 128),
                .max_items = readLimit(cfg, "max_items", std.math.maxInt(usize)),
                .owns_input = false,
                .can_borrow_strings = effectiveBorrowStrings(cfg),
            };
        }

        fn initOwned(input: []const u8, cfg: Config) Self {
            return .{
                .input = input,
                .cfg = cfg,
                .parser = .{ .input = input, .max_string_len = readLimit(cfg, "max_string_len", std.math.maxInt(usize)) },
                .max_depth = readLimit(cfg, "max_depth", 128),
                .max_items = readLimit(cfg, "max_items", std.math.maxInt(usize)),
                .owns_input = true,
                .can_borrow_strings = false,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.extras.deinit(allocator);
            self.extra_keys.deinit(allocator);
            if (self.owns_input) allocator.free(@constCast(self.input));
        }

        pub fn finish(self: *Self) !void {
            _ = self.cfg;
            self.parser.skipWhitespace();
            if (!self.parser.eof()) return error.TrailingCharacters;
        }

        pub fn borrowStrings(self: *Self) bool {
            return self.can_borrow_strings;
        }

        pub fn errorLocation(self: *Self) diagnostic_mod.Location {
            return diagnostic_mod.locationFromOffset(self.input, self.parser.index);
        }

        /// Reads a `[N]u8` field in the configured `ReadConfig.bytes` encoding.
        pub fn readByteToken(self: *Self, allocator: Allocator) !StringToken {
            const token = try self.readString(allocator);
            const codec = switch (bytesEncoding(Config, self.cfg)) {
                .string => return token,
                .base64 => std.base64.standard.Decoder,
                .base64url => std.base64.url_safe_no_pad.Decoder,
            };
            defer token.deinit(allocator);

            const decoded_len = codec.calcSizeForSlice(token.bytes) catch return error.InvalidBytes;
            const buffer = try allocator.alloc(u8, decoded_len);
            errdefer allocator.free(buffer);
            codec.decode(buffer, token.bytes) catch return error.InvalidBytes;
            return .{ .bytes = buffer, .allocated = true };
        }

        // The typed layer uses this to branch for optionals, enums, and skipping.
        pub fn peekKind(self: *Self) !ValueKind {
            self.parser.skipWhitespace();
            return switch (self.parser.peek() orelse return error.UnexpectedEndOfInput) {
                'n' => .null,
                't', 'f' => .bool,
                '-', '0'...'9' => .number,
                '"' => .string,
                '[' => .array,
                '{' => .object,
                else => error.UnexpectedToken,
            };
        }

        pub fn readNull(self: *Self) !void {
            try self.count();
            self.parser.skipWhitespace();
            try self.parser.consumeLiteral("null");
        }

        pub fn readBool(self: *Self) !bool {
            try self.count();
            self.parser.skipWhitespace();
            return switch (self.parser.peek() orelse return error.UnexpectedEndOfInput) {
                't' => blk: {
                    try self.parser.consumeLiteral("true");
                    break :blk true;
                },
                'f' => blk: {
                    try self.parser.consumeLiteral("false");
                    break :blk false;
                },
                else => error.UnexpectedToken,
            };
        }

        pub fn readNumber(self: *Self) !Number {
            try self.count();
            self.parser.skipWhitespace();
            return self.parser.parseNumberToken();
        }

        /// An integer field takes an integer literal only: `1.0` and `1e2` are floats, so they are a
        /// type error even when their value is whole.
        pub fn readInt(self: *Self, comptime T: type) !T {
            try self.count();
            self.parser.skipWhitespace();
            const parsed = try self.parser.parseNumberSlice();
            if (parsed.is_float) return error.UnexpectedType;

            return switch (@typeInfo(T)) {
                .comptime_int => std.fmt.parseInt(i128, parsed.slice, 10) catch return error.InvalidNumber,
                .int => |info| blk: {
                    if (info.signedness == .unsigned and parsed.slice.len > 0 and parsed.slice[0] == '-') {
                        break :blk error.IntegerOverflow;
                    }
                    break :blk std.fmt.parseInt(T, parsed.slice, 10) catch |err| switch (err) {
                        error.Overflow => error.IntegerOverflow,
                        error.InvalidCharacter => error.InvalidNumber,
                    };
                },
                else => error.UnsupportedType,
            };
        }

        /// A float field takes any number literal. One too large for `T` is `error.FloatOutOfRange`:
        /// `1e999` must not become infinity, which JSON cannot write and a field cannot mean.
        pub fn readFloat(self: *Self, comptime T: type) !T {
            try self.count();
            self.parser.skipWhitespace();
            const parsed = try self.parser.parseNumberSlice();

            return switch (@typeInfo(T)) {
                .comptime_float => @as(T, @floatCast(try parseFiniteFloat(f64, parsed.slice))),
                .float => try parseFiniteFloat(T, parsed.slice),
                else => error.UnsupportedType,
            };
        }

        pub fn readString(self: *Self, allocator: Allocator) !StringToken {
            try self.count();
            self.parser.skipWhitespace();
            return self.parser.parseStringToken(allocator);
        }

        pub fn beginArray(self: *Self) !void {
            try self.count();
            self.parser.skipWhitespace();
            if (self.parser.consume() != '[') return error.UnexpectedToken;
            try self.push(.{ .kind = .array, .first = true });
        }

        pub fn beginArrayLen(self: *Self) !?usize {
            try self.beginArray();
            return null;
        }

        pub fn nextArrayItem(self: *Self) !bool {
            const frame = self.current();
            if (frame.kind != .array) return error.InvalidJsonState;

            self.parser.skipWhitespace();
            if (frame.first) {
                if (self.parser.peek() == ']') {
                    _ = self.parser.consume();
                    _ = self.pop();
                    return false;
                }
                frame.first = false;
                return true;
            }

            const next = self.parser.consume() orelse return error.UnexpectedEndOfInput;
            switch (next) {
                ',' => {
                    self.parser.skipWhitespace();
                    return true;
                },
                ']' => {
                    _ = self.pop();
                    return false;
                },
                else => return error.UnexpectedToken,
            }
        }

        pub fn beginObject(self: *Self) !void {
            try self.count();
            self.parser.skipWhitespace();
            if (self.parser.consume() != '{') return error.UnexpectedToken;
            try self.push(.{ .kind = .object, .first = true });
        }

        pub fn nextObjectField(self: *Self, allocator: Allocator) !?StringToken {
            const frame = self.current();
            if (frame.kind != .object) return error.InvalidJsonState;

            self.parser.skipWhitespace();
            if (frame.first) {
                if (self.parser.peek() == '}') {
                    _ = self.parser.consume();
                    _ = self.pop();
                    return null;
                }
                frame.first = false;
            } else {
                const next = self.parser.consume() orelse return error.UnexpectedEndOfInput;
                switch (next) {
                    ',' => self.parser.skipWhitespace(),
                    '}' => {
                        _ = self.pop();
                        return null;
                    },
                    else => return error.UnexpectedToken,
                }
            }

            if (self.parser.peek() != '"') return error.UnexpectedToken;
            try self.count();
            const key = try self.parser.parseStringToken(allocator);
            errdefer key.deinit(allocator);

            self.parser.skipWhitespace();
            if (self.parser.consume() != ':') return error.UnexpectedToken;
            return key;
        }

        /// A reader of the next value of this read, for a wire type's decode hook.
        pub fn pullView(self: *Self, allocator: Allocator) PullReader(Config) {
            return PullReader(Config).view(self, allocator);
        }

        /// Where the extras of a struct begin, so a struct read inside another keeps its own.
        pub fn extrasMark(self: *Self) usize {
            return self.extras.items.len;
        }

        /// Takes the member whose value is next: `key` is its decoded name, and the value is checked
        /// and kept as the text it was read from.
        pub fn captureExtra(self: *Self, allocator: Allocator, key: []const u8) !void {
            self.parser.skipWhitespace();
            const start = self.parser.index;
            try self.skipValue(allocator);
            const key_start = self.extra_keys.items.len;
            try self.extra_keys.appendSlice(allocator, key);
            try self.extras.append(allocator, .{ .key_start = key_start, .key_len = key.len, .value_start = start, .value_end = self.parser.index });
        }

        /// Ends the extras since `mark` as one object, its members in input order and each value as
        /// it was read, owned by the caller. With none it is null, or `{}` when `want_empty`.
        pub fn finishExtras(self: *Self, allocator: Allocator, mark: usize, want_empty: bool) !?[]u8 {
            const entries = self.extras.items[mark..];
            defer {
                if (entries.len != 0) self.extra_keys.items.len = entries[0].key_start;
                self.extras.items.len = mark;
            }
            if (entries.len == 0 and !want_empty) return null;

            var out: std.Io.Writer.Allocating = .init(allocator);
            errdefer out.deinit();
            try out.writer.writeByte('{');
            for (entries, 0..) |entry, index| {
                if (index != 0) try out.writer.writeByte(',');
                try writeEscapedString(&out.writer, self.extra_keys.items[entry.key_start..][0..entry.key_len]);
                try out.writer.writeByte(':');
                try out.writer.writeAll(self.input[entry.value_start..entry.value_end]);
            }
            try out.writer.writeByte('}');
            return try out.toOwnedSlice();
        }

        /// The next value as the text it was read from, without the whitespace around it.
        pub const raw_format: typed.RawFormat = .json;

        pub fn readRaw(self: *Self, allocator: Allocator) !StringToken {
            self.parser.skipWhitespace();
            const start = self.parser.index;
            try self.skipValue(allocator);
            return .{ .bytes = self.input[start..self.parser.index], .allocated = false };
        }

        pub fn skipValue(self: *Self, allocator: Allocator) !void {
            switch (try self.peekKind()) {
                .null => try self.readNull(),
                .bool => _ = try self.readBool(),
                // Skipping checks the grammar and nothing more: a number too large for any type is still JSON.
                .number => {
                    try self.count();
                    _ = try self.parser.parseNumberSlice();
                },
                .bytes => {
                    const token = try self.readString(allocator);
                    token.deinit(allocator);
                },
                .string => {
                    const token = try self.readString(allocator);
                    token.deinit(allocator);
                },
                .array => {
                    try self.beginArray();
                    while (try self.nextArrayItem()) {
                        try self.skipValue(allocator);
                    }
                },
                .object => {
                    try self.beginObject();
                    while (try self.nextObjectField(allocator)) |field_name| {
                        field_name.deinit(allocator);
                        try self.skipValue(allocator);
                    }
                },
            }
        }

        /// Counts one value against `max_items`.
        fn count(self: *Self) !void {
            self.items += 1;
            if (self.items > self.max_items) return error.TooManyItems;
        }

        fn push(self: *Self, container: Container) !void {
            if (self.stack_len >= self.max_depth) return error.JsonNestingTooDeep;
            self.stack[self.stack_len] = container;
            self.stack_len += 1;
        }

        fn pop(self: *Self) Container {
            self.stack_len -= 1;
            return self.stack[self.stack_len];
        }

        fn current(self: *Self) *Container {
            return &self.stack[self.stack_len - 1];
        }
    };
}

/// A pull reader over a JSON text: `next` returns the events of one value in order, for a shape
/// that is only known while reading; see `cbor.PullReader`. Object keys arrive as text events. A
/// text event is valid until the next call. The input must outlive the reader.
pub fn pullReader(allocator: Allocator, input: []const u8, comptime cfg: anytype) !PullReader(@TypeOf(cfg)) {
    comptime checkLimits(cfg);
    return PullReader(@TypeOf(cfg)).init(allocator, input, cfg);
}

pub fn PullReader(comptime Config: type) type {
    return struct {
        d: *JsonDeserializer(Config),
        /// Whether this reader made `d` and frees it; see `cbor.PullReader`.
        owns: bool,
        base: usize,
        allocator: Allocator,
        scratch: ?[]u8 = null,
        done: bool = false,
        /// Whether an object frame, by depth, has read a key and expects its value.
        want_value: [128]bool = @splat(false),

        const Self = @This();

        fn init(allocator: Allocator, input: []const u8, cfg: Config) !Self {
            const d = try allocator.create(JsonDeserializer(Config));
            d.* = JsonDeserializer(Config).initBorrowed(input, cfg);
            return .{ .d = d, .owns = true, .base = 0, .allocator = allocator };
        }

        /// A reader of the next value of a deserializer that is already reading.
        pub fn view(d: *JsonDeserializer(Config), allocator: Allocator) Self {
            return .{ .d = d, .owns = false, .base = d.stack_len, .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.release();
            if (self.owns) {
                self.d.deinit(self.allocator);
                self.allocator.destroy(self.d);
            }
        }

        /// The next event, or null after the value is complete.
        pub fn next(self: *Self) !?typed.Event {
            self.release();
            const d = self.d;
            if (d.stack_len == self.base) {
                if (self.done) return null;
                const event = try self.valueEvent();
                if (d.stack_len == self.base) self.done = true;
                return event;
            }
            const frame = d.current();
            const depth = d.stack_len - 1;
            switch (frame.kind) {
                .array => {
                    if (!try d.nextArrayItem()) {
                        self.done = d.stack_len == self.base;
                        return .array_end;
                    }
                    return try self.valueEvent();
                },
                .object => {
                    if (self.want_value[depth]) {
                        self.want_value[depth] = false;
                        return try self.valueEvent();
                    }
                    const key = (try d.nextObjectField(self.allocator)) orelse {
                        self.done = d.stack_len == self.base;
                        return .map_end;
                    };
                    self.want_value[depth] = true;
                    return .{ .text = self.keep(key) };
                },
            }
        }

        /// Consumes the next value whole; see `cbor.PullReader.skip`.
        pub fn skip(self: *Self) !void {
            var depth: usize = 0;
            while (try self.next()) |event| {
                switch (event) {
                    .array_begin, .map_begin => depth += 1,
                    .array_end, .map_end => depth -= 1,
                    else => {},
                }
                if (depth == 0) return;
            }
        }

        /// After the last event: nothing but whitespace follows.
        pub fn finish(self: *Self) !void {
            if (!self.done) return error.UnexpectedEndOfInput;
            try self.d.finish();
        }

        fn release(self: *Self) void {
            if (self.scratch) |bytes| self.allocator.free(bytes);
            self.scratch = null;
        }

        fn keep(self: *Self, token: StringToken) []const u8 {
            if (token.allocated) self.scratch = @constCast(token.bytes);
            return token.bytes;
        }

        fn valueEvent(self: *Self) !typed.Event {
            const d = self.d;
            switch (try d.peekKind()) {
                .null => {
                    try d.readNull();
                    return .null;
                },
                .bool => return .{ .bool = try d.readBool() },
                .number => return switch (try d.readNumber()) {
                    .integer => |value| .{ .integer = value },
                    .float => |value| .{ .float = value },
                },
                .string => return .{ .text = self.keep(try d.readString(self.allocator)) },
                .array => {
                    try d.beginArray();
                    self.want_value[d.stack_len - 1] = false;
                    return .{ .array_begin = null };
                },
                .object => {
                    try d.beginObject();
                    self.want_value[d.stack_len - 1] = false;
                    return .{ .map_begin = null };
                },
                .bytes => unreachable,
            }
        }
    };
}

/// A writer for a wire type's encode hook: values go out as they are written, with no buffering
/// and no allocation. A map's items are keys (text) and values alternately, in the order the caller
/// wants them written, and the lengths given to `beginArray` and `beginMap` are ignored. Bytes follow
/// the config's `bytes` encoding, and a NaN or infinity is refused.
pub const Encoder = struct {
    writer: *std.Io.Writer,
    encoding: BytesEncoding,
    frames: [128]struct { kind: ContainerKind, first: bool, expect_key: bool } = undefined,
    depth: usize = 0,

    pub fn writeNull(self: *Encoder) !void {
        try self.beforeValue();
        try self.writer.writeAll("null");
        self.afterValue();
    }

    pub fn writeBool(self: *Encoder, value: bool) !void {
        try self.beforeValue();
        try self.writer.writeAll(if (value) "true" else "false");
        self.afterValue();
    }

    pub fn writeInt(self: *Encoder, value: i128) !void {
        try self.beforeValue();
        try self.writer.print("{}", .{value});
        self.afterValue();
    }

    pub fn writeFloat(self: *Encoder, value: f64) !void {
        if (!std.math.isFinite(value)) return error.NonFiniteFloat;
        try self.beforeValue();
        try self.writer.print("{}", .{value});
        self.afterValue();
    }

    /// In a map's key position, this is the key.
    pub fn writeText(self: *Encoder, value: []const u8) !void {
        if (self.depth != 0) {
            const frame = &self.frames[self.depth - 1];
            if (frame.kind == .object and frame.expect_key) {
                if (!frame.first) try self.writer.writeByte(',');
                frame.first = false;
                try writeEscapedString(self.writer, value);
                try self.writer.writeByte(':');
                frame.expect_key = false;
                return;
            }
        }
        try self.beforeValue();
        try writeEscapedString(self.writer, value);
        self.afterValue();
    }

    pub fn writeBytes(self: *Encoder, value: []const u8) !void {
        try self.beforeValue();
        try writeBytesText(self.writer, self.encoding, value);
        self.afterValue();
    }

    /// JSON text that is already valid, unchanged.
    pub fn writeRaw(self: *Encoder, text: []const u8) !void {
        try self.beforeValue();
        try self.writer.writeAll(text);
        self.afterValue();
    }

    pub fn beginArray(self: *Encoder, len: usize) !void {
        _ = len;
        try self.beforeValue();
        try self.push(.array);
        try self.writer.writeByte('[');
    }

    pub fn endArray(self: *Encoder) !void {
        if (self.depth == 0 or self.frames[self.depth - 1].kind != .array) return error.UnbalancedContainers;
        try self.writer.writeByte(']');
        self.depth -= 1;
        self.afterValue();
    }

    pub fn beginMap(self: *Encoder, len: usize) !void {
        _ = len;
        try self.beforeValue();
        try self.push(.object);
        try self.writer.writeByte('{');
    }

    pub fn endMap(self: *Encoder) !void {
        if (self.depth == 0 or self.frames[self.depth - 1].kind != .object or !self.frames[self.depth - 1].expect_key) return error.UnbalancedContainers;
        try self.writer.writeByte('}');
        self.depth -= 1;
        self.afterValue();
    }

    fn beforeValue(self: *Encoder) !void {
        if (self.depth == 0) return;
        const frame = &self.frames[self.depth - 1];
        switch (frame.kind) {
            .array => {
                if (!frame.first) try self.writer.writeByte(',');
                frame.first = false;
            },
            .object => if (frame.expect_key) return error.UnexpectedType,
        }
    }

    fn afterValue(self: *Encoder) void {
        if (self.depth == 0) return;
        const frame = &self.frames[self.depth - 1];
        if (frame.kind == .object) frame.expect_key = true;
    }

    fn push(self: *Encoder, kind: ContainerKind) !void {
        if (self.depth >= self.frames.len) return error.JsonNestingTooDeep;
        self.frames[self.depth] = .{ .kind = kind, .first = true, .expect_key = true };
        self.depth += 1;
    }
};

/// A writer for a value whose shape is only known while writing; see `cbor.ValueWriter`. A map's
/// keys are text, and the map is buffered until it closes so its members can be sorted: with
/// `sort_keys` (the default) shorter keys come first and equal lengths bytewise, which is the order of
/// deterministic CBOR keys, and a repeated key is `error.DuplicateField`. Arrays are written as they
/// come. Bytes are written in the config's `bytes` encoding, and a NaN or infinity is refused.
pub fn valueWriter(allocator: Allocator, writer: *std.Io.Writer, comptime cfg: anytype) ValueWriter {
    return ValueWriter.init(allocator, writer, readLimitFlag(cfg, "sort_keys", true), bytesEncoding(@TypeOf(cfg), cfg));
}

pub const ValueWriter = struct {
    allocator: Allocator,
    out: *std.Io.Writer,
    sort_keys: bool,
    encoding: BytesEncoding,
    frames: [128]Frame = undefined,
    depth: usize = 0,

    const Frame = struct {
        kind: ContainerKind,
        /// Only a map owns a buffer; an array writes to the map around it, or to the output.
        buf: std.Io.Writer.Allocating,
        first: bool = true,
        entries: std.ArrayList(Entry) = .empty,
        /// The key text of every entry, back to back.
        keys: std.ArrayList(u8) = .empty,
        expect_key: bool = true,
        entry_start: usize = 0,
        key_start: usize = 0,
        key_len: usize = 0,
    };

    /// A map entry: its key text in `keys`, and its `"key":value` text in the buffer.
    const Entry = struct { key_start: usize, key_len: usize, start: usize, end: usize };

    fn init(allocator: Allocator, writer: *std.Io.Writer, sort_keys: bool, encoding: BytesEncoding) ValueWriter {
        return .{ .allocator = allocator, .out = writer, .sort_keys = sort_keys, .encoding = encoding };
    }

    /// Releases the buffers of containers still open.
    pub fn deinit(self: *ValueWriter) void {
        for (self.frames[0..self.depth]) |*frame| self.release(frame);
        self.depth = 0;
    }

    /// After the last value: every container is closed.
    pub fn finish(self: *ValueWriter) !void {
        if (self.depth != 0) return error.UnbalancedContainers;
    }

    pub fn writeNull(self: *ValueWriter) !void {
        try self.beforeValue();
        try self.sink().writeAll("null");
        try self.afterValue();
    }

    pub fn writeBool(self: *ValueWriter, value: bool) !void {
        try self.beforeValue();
        try self.sink().writeAll(if (value) "true" else "false");
        try self.afterValue();
    }

    pub fn writeInt(self: *ValueWriter, value: i128) !void {
        try self.beforeValue();
        try self.sink().print("{}", .{value});
        try self.afterValue();
    }

    pub fn writeFloat(self: *ValueWriter, value: f64) !void {
        if (!std.math.isFinite(value)) return error.NonFiniteFloat;
        try self.beforeValue();
        try self.sink().print("{}", .{value});
        try self.afterValue();
    }

    /// In a map's key position, this is the key.
    pub fn writeText(self: *ValueWriter, value: []const u8) !void {
        if (self.depth != 0) {
            const frame = &self.frames[self.depth - 1];
            if (frame.kind == .object and frame.expect_key) {
                const out = &frame.buf.writer;
                frame.entry_start = frame.buf.written().len;
                try writeEscapedString(out, value);
                try out.writeByte(':');
                frame.key_start = frame.keys.items.len;
                frame.key_len = value.len;
                try frame.keys.appendSlice(self.allocator, value);
                frame.expect_key = false;
                return;
            }
        }
        try self.beforeValue();
        try writeEscapedString(self.sink(), value);
        try self.afterValue();
    }

    pub fn writeBytes(self: *ValueWriter, value: []const u8) !void {
        try self.beforeValue();
        try writeBytesText(self.sink(), self.encoding, value);
        try self.afterValue();
    }

    /// Writes JSON text that is already valid, unchanged: a `Raw` that was read, say.
    pub fn writeRaw(self: *ValueWriter, text: []const u8) !void {
        try self.beforeValue();
        try self.sink().writeAll(text);
        try self.afterValue();
    }

    pub fn beginArray(self: *ValueWriter) !void {
        try self.beforeValue();
        try self.push(.array);
        try self.sink().writeByte('[');
    }

    pub fn endArray(self: *ValueWriter) !void {
        if (self.depth == 0 or self.frames[self.depth - 1].kind != .array) return error.UnbalancedContainers;
        try self.sink().writeByte(']');
        self.depth -= 1;
        try self.afterValue();
    }

    pub fn beginMap(self: *ValueWriter) !void {
        try self.beforeValue();
        try self.push(.object);
    }

    pub fn endMap(self: *ValueWriter) !void {
        if (self.depth == 0 or self.frames[self.depth - 1].kind != .object) return error.UnbalancedContainers;
        const frame = &self.frames[self.depth - 1];
        if (!frame.expect_key) return error.UnbalancedContainers;
        const body = frame.buf.written();
        const keys = frame.keys.items;
        const entries = frame.entries.items;
        if (self.sort_keys) {
            const Order = struct {
                keys: []const u8,
                fn less(ctx: @This(), a: Entry, b: Entry) bool {
                    const x = ctx.keys[a.key_start..][0..a.key_len];
                    const y = ctx.keys[b.key_start..][0..b.key_len];
                    if (x.len != y.len) return x.len < y.len;
                    return std.mem.lessThan(u8, x, y);
                }
            };
            std.sort.pdq(Entry, entries, Order{ .keys = keys }, Order.less);
            for (entries[@min(1, entries.len)..], 0..) |entry, previous| {
                const before = entries[previous];
                if (std.mem.eql(u8, keys[before.key_start..][0..before.key_len], keys[entry.key_start..][0..entry.key_len])) return error.DuplicateField;
            }
        }
        const out = self.sinkAt(self.depth - 1);
        try out.writeByte('{');
        for (entries, 0..) |entry, index| {
            if (index != 0) try out.writeByte(',');
            try out.writeAll(body[entry.start..entry.end]);
        }
        try out.writeByte('}');
        self.release(frame);
        self.depth -= 1;
        try self.afterValue();
    }

    /// Writes one event of a pull read, so a reader can be copied into a writer.
    pub fn writeEvent(self: *ValueWriter, event: typed.Event) !void {
        switch (event) {
            .null => try self.writeNull(),
            .bool => |value| try self.writeBool(value),
            .integer => |value| try self.writeInt(value),
            .float => |value| try self.writeFloat(value),
            .text => |value| try self.writeText(value),
            .bytes => |value| try self.writeBytes(value),
            .array_begin => try self.beginArray(),
            .array_end => try self.endArray(),
            .map_begin => try self.beginMap(),
            .map_end => try self.endMap(),
        }
    }

    /// Where the text of the innermost open container goes: its own buffer if it is a map, else
    /// the buffer of the nearest map around it, else the output.
    fn sink(self: *ValueWriter) *std.Io.Writer {
        return self.sinkAt(self.depth);
    }

    fn sinkAt(self: *ValueWriter, depth: usize) *std.Io.Writer {
        var level = depth;
        while (level > 0) : (level -= 1) {
            if (self.frames[level - 1].kind == .object) return &self.frames[level - 1].buf.writer;
        }
        return self.out;
    }

    /// Separates an array element from the one before it, and refuses a value where a key is due.
    fn beforeValue(self: *ValueWriter) !void {
        if (self.depth == 0) return;
        const frame = &self.frames[self.depth - 1];
        switch (frame.kind) {
            .array => {
                if (!frame.first) try self.sink().writeByte(',');
                frame.first = false;
            },
            .object => if (frame.expect_key) return error.UnexpectedType,
        }
    }

    /// Closes the entry of a map whose value was just written.
    fn afterValue(self: *ValueWriter) !void {
        if (self.depth == 0) return;
        const frame = &self.frames[self.depth - 1];
        if (frame.kind != .object) return;
        try frame.entries.append(self.allocator, .{ .key_start = frame.key_start, .key_len = frame.key_len, .start = frame.entry_start, .end = frame.buf.written().len });
        frame.expect_key = true;
    }

    fn push(self: *ValueWriter, kind: ContainerKind) !void {
        if (self.depth >= self.frames.len) return error.JsonNestingTooDeep;
        self.frames[self.depth] = .{ .kind = kind, .buf = if (kind == .object) .init(self.allocator) else undefined };
        self.depth += 1;
    }

    fn release(self: *ValueWriter, frame: *Frame) void {
        if (frame.kind != .object) return;
        frame.buf.deinit();
        frame.entries.deinit(self.allocator);
        frame.keys.deinit(self.allocator);
    }
};

pub fn serialize(writer: *std.Io.Writer, value: anytype) !void {
    try serializeWith(writer, value, .{}, .{});
}

/// Convenience wrapper around the format-neutral typed serializer.
pub fn serializeWith(
    writer: *std.Io.Writer,
    value: anytype,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !void {
    try typed.serialize(@This(), writer, value, serde_cfg, format_cfg);
}

pub fn deserialize(comptime T: type, allocator: Allocator, reader: *std.Io.Reader) ParseError!T {
    return deserializeWith(T, allocator, reader, .{}, .{});
}

/// Reader entrypoint that owns the input buffer and returns fully-owned strings.
pub fn deserializeWith(
    comptime T: type,
    allocator: Allocator,
    reader: *std.Io.Reader,
    comptime serde_cfg: anytype,
    comptime read_cfg: anytype,
) ParseError!T {
    var deserializer = try readerDeserializer(allocator, reader, read_cfg);
    defer deserializer.deinit(allocator);
    const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
    try deserializer.finish();
    return value;
}

pub fn parseSlice(comptime T: type, allocator: Allocator, input: []const u8) ParseError!T {
    return parseSliceWith(T, allocator, input, .{}, .{});
}

/// Slice entrypoint that still duplicates strings when the caller wants owned data.
pub fn parseSliceWith(
    comptime T: type,
    allocator: Allocator,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime read_cfg: anytype,
) ParseError!T {
    var deserializer = try sliceDeserializer(allocator, input, read_cfg);
    defer deserializer.deinit(allocator);
    const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
    try deserializer.finish();
    return value;
}

/// Parses from a stable input slice and may alias unescaped strings directly into that slice.
pub fn parseSliceAliased(comptime T: type, allocator: Allocator, input: []const u8) ParseError!T {
    return parseSliceAliasedWith(T, allocator, input, .{}, .{});
}

/// Slice entrypoint that asks the deserializer to reuse unescaped input bytes when possible.
pub fn parseSliceAliasedWith(
    comptime T: type,
    allocator: Allocator,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime read_cfg: anytype,
) ParseError!T {
    var deserializer = try sliceDeserializer(allocator, input, read_cfg);
    defer deserializer.deinit(allocator);
    // The caller's whole configuration applies; only the aliasing is added.
    deserializer.can_borrow_strings = true;
    const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
    try deserializer.finish();
    return value;
}

/// Writes bytes as a JSON string in `encoding`. The raw-string encoding is exact only for UTF-8, so
/// any other bytes would write invalid JSON and are refused.
fn writeBytesText(writer: *std.Io.Writer, encoding: BytesEncoding, value: []const u8) !void {
    switch (encoding) {
        .string => {
            if (!bulk.validUtf8(value)) return error.InvalidUtf8;
            try writeQuoted(writer, value);
        },
        .base64 => {
            try writer.writeByte('"');
            try std.base64.standard.Encoder.encodeWriter(writer, value);
            try writer.writeByte('"');
        },
        .base64url => {
            try writer.writeByte('"');
            try std.base64.url_safe_no_pad.Encoder.encodeWriter(writer, value);
            try writer.writeByte('"');
        },
    }
}

fn readLimitFlag(cfg: anytype, comptime name: []const u8, default: bool) bool {
    if (comptime meta.hasField(@TypeOf(cfg), name)) return @field(cfg, name);
    return default;
}

pub fn writeEscapedString(writer: *std.Io.Writer, bytes: []const u8) !void {
    if (!bulk.validUtf8(bytes)) return error.InvalidUtf8;
    try writeQuoted(writer, bytes);
}

/// A string literal for text already known to be UTF-8.
fn writeQuoted(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('"');
    try bulk.writeEscaped(writer, bytes);
    try writer.writeByte('"');
}

fn effectiveMaxInputBytes(comptime cfg: anytype) usize {
    if (comptime meta.hasField(@TypeOf(cfg), "max_input_bytes")) return @field(cfg, "max_input_bytes");
    return 16 * 1024 * 1024;
}

/// One member collected for an extras field: its key in `extra_keys`, its value in the input.
const ExtraEntry = struct { key_start: usize, key_len: usize, value_start: usize, value_end: usize };

/// Whether the string literal `raw` (quotes included) decodes to `name`.
fn rawKeyIs(raw: []const u8, name: []const u8) bool {
    var i: usize = 1;
    var n: usize = 0;
    while (i + 1 < raw.len) {
        var buffer: [4]u8 = undefined;
        var piece: []const u8 = raw[i..][0..1];
        if (raw[i] == '\\') {
            i += 1;
            switch (raw[i]) {
                '"', '\\', '/' => piece = raw[i..][0..1],
                'b' => piece = "\x08",
                'f' => piece = "\x0c",
                'n' => piece = "\n",
                'r' => piece = "\r",
                't' => piece = "\t",
                'u' => {
                    var scan: Parser = .{ .input = raw, .index = i + 1 };
                    const first = scan.parseHex4() catch return false;
                    var code: u21 = first;
                    i += 4;
                    if (std.unicode.utf16IsHighSurrogate(first)) {
                        scan.index += 2; // the `\u` of the low half
                        const second = scan.parseHex4() catch return false;
                        code = std.unicode.utf16DecodeSurrogatePair(&.{ first, second }) catch return false;
                        i += 6;
                    }
                    piece = buffer[0 .. std.unicode.utf8Encode(code, &buffer) catch return false];
                },
                else => return false,
            }
        }
        if (n + piece.len > name.len or !std.mem.eql(u8, piece, name[n..][0..piece.len])) return false;
        n += piece.len;
        i += 1;
    }
    return n == name.len;
}

/// Parses a number literal as a float. A literal too large for `T` would round to infinity, which
/// JSON has no way to write and no field means, so it is `error.FloatOutOfRange`. One too small
/// rounds to zero or a subnormal, a loss of precision RFC 8259 §6 leaves to the implementation.
fn parseFiniteFloat(comptime T: type, slice: []const u8) error{ InvalidNumber, FloatOutOfRange }!T {
    const value = std.fmt.parseFloat(T, slice) catch return error.InvalidNumber;
    if (std.math.isInf(value)) return error.FloatOutOfRange;
    return value;
}

fn readLimit(cfg: anytype, comptime name: []const u8, default: usize) usize {
    if (comptime meta.hasField(@TypeOf(cfg), name)) return @field(cfg, name);
    return default;
}

fn effectiveBorrowStrings(cfg: anytype) bool {
    if (comptime meta.hasField(@TypeOf(cfg), "borrow_strings")) return cfg.borrow_strings;
    return false;
}

const Parser = struct {
    input: []const u8,
    index: usize = 0,
    max_string_len: usize = std.math.maxInt(usize),

    const NumberSlice = struct {
        slice: []const u8,
        is_float: bool,
    };

    pub const Error = Allocator.Error || error{
        UnexpectedEndOfInput,
        UnexpectedToken,
        TrailingCharacters,
        InvalidNumber,
        InvalidStringEscape,
        InvalidUnicodeEscape,
        InvalidUnicodeSurrogate,
        InvalidStringCharacter,
        InvalidUtf8,
        FloatOutOfRange,
        StringTooLong,
        JsonNestingTooDeep,
    };

    // Shared token parser for both direct typed reads and recursive skipping.
    fn parseNumberToken(self: *Parser) Error!Number {
        const parsed = try self.parseNumberSlice();
        if (parsed.is_float) {
            return .{ .float = try parseFiniteFloat(f64, parsed.slice) };
        }
        return .{ .integer = std.fmt.parseInt(i128, parsed.slice, 10) catch return error.InvalidNumber };
    }

    fn parseNumberSlice(self: *Parser) Error!NumberSlice {
        const start = self.index;
        var is_float = false;

        if (self.peek() == '-') _ = self.consume();

        const first_digit = self.peek() orelse return error.UnexpectedEndOfInput;
        switch (first_digit) {
            '0' => _ = self.consume(),
            '1'...'9' => {
                _ = self.consume();
                while (self.peek()) |c| {
                    if (!std.ascii.isDigit(c)) break;
                    _ = self.consume();
                }
            },
            else => return error.InvalidNumber,
        }

        if (self.peek() == '.') {
            is_float = true;
            _ = self.consume();
            const first_fraction = self.peek() orelse return error.InvalidNumber;
            if (!std.ascii.isDigit(first_fraction)) return error.InvalidNumber;
            while (self.peek()) |c| {
                if (!std.ascii.isDigit(c)) break;
                _ = self.consume();
            }
        }

        if (self.peek()) |c| {
            if (c == 'e' or c == 'E') {
                is_float = true;
                _ = self.consume();
                if (self.peek()) |sign| {
                    if (sign == '+' or sign == '-') _ = self.consume();
                } else return error.InvalidNumber;

                const first_exp = self.peek() orelse return error.InvalidNumber;
                if (!std.ascii.isDigit(first_exp)) return error.InvalidNumber;
                while (self.peek()) |digit| {
                    if (!std.ascii.isDigit(digit)) break;
                    _ = self.consume();
                }
            }
        }

        return .{
            .slice = self.input[start..self.index],
            .is_float = is_float,
        };
    }

    /// A string's raw bytes between escapes must be UTF-8. Each run is checked alone, which is
    /// enough: an escape is ASCII, so no code point spans two runs.
    fn validUtf8(bytes: []const u8) Error![]const u8 {
        if (!bulk.validUtf8(bytes)) return error.InvalidUtf8;
        return bytes;
    }

    // Plain strings borrow from the input; escaped strings allocate rewritten bytes.
    fn parseStringToken(self: *Parser, allocator: Allocator) Error!StringToken {
        const token = try self.parseStringTokenUnbounded(allocator);
        if (token.bytes.len > self.max_string_len) {
            token.deinit(allocator);
            return error.StringTooLong;
        }
        return token;
    }

    fn parseStringTokenUnbounded(self: *Parser, allocator: Allocator) Error!StringToken {
        if (self.consume() != '"') return error.UnexpectedToken;

        const start = self.index;
        var builder: std.ArrayList(u8) = .empty;
        var builder_owned_here = true;
        errdefer if (builder_owned_here) builder.deinit(allocator);

        while (true) {
            self.index = bulk.findStringSpecial(self.input, self.index);
            const c = self.consume() orelse return error.UnexpectedEndOfInput;
            switch (c) {
                '"' => {
                    if (builder.items.len == 0) {
                        return .{
                            .bytes = try validUtf8(self.input[start .. self.index - 1]),
                            .allocated = false,
                        };
                    }

                    try builder.appendSlice(allocator, try validUtf8(self.input[start .. self.index - 1]));
                    return .{
                        .bytes = try builder.toOwnedSlice(allocator),
                        .allocated = true,
                    };
                },
                '\\' => {
                    try builder.appendSlice(allocator, try validUtf8(self.input[start .. self.index - 1]));
                    try self.appendEscape(allocator, &builder);
                    builder_owned_here = false;
                    return self.finishEscapedString(allocator, builder);
                },
                0...31 => return error.InvalidStringCharacter,
                else => {},
            }
        }
    }

    fn finishEscapedString(self: *Parser, allocator: Allocator, initial_builder: std.ArrayList(u8)) Error!StringToken {
        var builder = initial_builder;
        errdefer builder.deinit(allocator);

        var chunk_start = self.index;
        while (true) {
            self.index = bulk.findStringSpecial(self.input, self.index);
            const c = self.consume() orelse return error.UnexpectedEndOfInput;
            switch (c) {
                '"' => {
                    try builder.appendSlice(allocator, try validUtf8(self.input[chunk_start .. self.index - 1]));
                    return .{
                        .bytes = try builder.toOwnedSlice(allocator),
                        .allocated = true,
                    };
                },
                '\\' => {
                    try builder.appendSlice(allocator, try validUtf8(self.input[chunk_start .. self.index - 1]));
                    try self.appendEscape(allocator, &builder);
                    chunk_start = self.index;
                },
                0...31 => return error.InvalidStringCharacter,
                else => {},
            }
        }
    }

    fn appendEscape(self: *Parser, allocator: Allocator, builder: *std.ArrayList(u8)) Error!void {
        const escape = self.consume() orelse return error.UnexpectedEndOfInput;
        switch (escape) {
            '"', '\\', '/' => try builder.append(allocator, escape),
            'b' => try builder.append(allocator, '\x08'),
            'f' => try builder.append(allocator, '\x0c'),
            'n' => try builder.append(allocator, '\n'),
            'r' => try builder.append(allocator, '\r'),
            't' => try builder.append(allocator, '\t'),
            'u' => try self.appendUnicodeEscape(allocator, builder),
            else => return error.InvalidStringEscape,
        }
    }

    fn appendUnicodeEscape(self: *Parser, allocator: Allocator, builder: *std.ArrayList(u8)) Error!void {
        const first = try self.parseHex4();
        var codepoint: u21 = first;

        if (std.unicode.utf16IsHighSurrogate(first)) {
            if (self.consume() != '\\' or self.consume() != 'u') return error.InvalidUnicodeSurrogate;
            const second = try self.parseHex4();
            if (!std.unicode.utf16IsLowSurrogate(second)) return error.InvalidUnicodeSurrogate;
            codepoint = std.unicode.utf16DecodeSurrogatePair(&[_]u16{ first, second }) catch {
                return error.InvalidUnicodeSurrogate;
            };
        } else if (std.unicode.utf16IsLowSurrogate(first)) {
            return error.InvalidUnicodeSurrogate;
        }

        var utf8: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &utf8) catch unreachable;
        try builder.appendSlice(allocator, utf8[0..len]);
    }

    fn parseHex4(self: *Parser) Error!u16 {
        var value: u16 = 0;
        var count: usize = 0;
        while (count < 4) : (count += 1) {
            const c = self.consume() orelse return error.UnexpectedEndOfInput;
            value <<= 4;
            value |= switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => 10 + (c - 'a'),
                'A'...'F' => 10 + (c - 'A'),
                else => return error.InvalidUnicodeEscape,
            };
        }
        return value;
    }

    /// Steps over a string literal that is already known to be valid.
    fn skipStringTrusted(self: *Parser) Error!void {
        if (self.consume() != '"') return error.UnexpectedToken;
        while (true) {
            switch (self.consume() orelse return error.UnexpectedEndOfInput) {
                '"' => return,
                '\\' => _ = self.consume() orelse return error.UnexpectedEndOfInput,
                else => {},
            }
        }
    }

    /// Steps over a value that is already known to be valid, without checking it again. Too deep
    /// nesting is an error, not a trap.
    fn skipValueTrusted(self: *Parser, depth: usize) Error!void {
        if (depth > 128) return error.JsonNestingTooDeep;
        self.skipWhitespace();
        switch (self.peek() orelse return error.UnexpectedEndOfInput) {
            '"' => try self.skipStringTrusted(),
            '{', '[' => {
                const object = self.consume().? == '{';
                self.skipWhitespace();
                if (self.peek() == (if (object) @as(u8, '}') else ']')) {
                    _ = self.consume();
                    return;
                }
                while (true) {
                    if (object) {
                        self.skipWhitespace();
                        try self.skipStringTrusted();
                        self.skipWhitespace();
                        if (self.consume() != ':') return error.UnexpectedToken;
                    }
                    try self.skipValueTrusted(depth + 1);
                    self.skipWhitespace();
                    switch (self.consume() orelse return error.UnexpectedEndOfInput) {
                        ',' => {},
                        '}', ']' => return,
                        else => return error.UnexpectedToken,
                    }
                }
            },
            't' => try self.consumeLiteral("true"),
            'f' => try self.consumeLiteral("false"),
            'n' => try self.consumeLiteral("null"),
            else => _ = try self.parseNumberSlice(),
        }
    }

    fn consumeLiteral(self: *Parser, comptime expected: []const u8) Error!void {
        inline for (expected) |c| {
            if (self.consume() != c) return error.UnexpectedToken;
        }
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.peek()) |c| {
            switch (c) {
                ' ', '\n', '\r', '\t' => _ = self.consume(),
                else => return,
            }
        }
    }

    fn peek(self: *Parser) ?u8 {
        if (self.index >= self.input.len) return null;
        return self.input[self.index];
    }

    fn consume(self: *Parser) ?u8 {
        const c = self.peek() orelse return null;
        self.index += 1;
        return c;
    }

    fn eof(self: *Parser) bool {
        return self.index >= self.input.len;
    }
};

test "typed serialize supports rename_all and omit_null_fields" {
    const Example = struct {
        firstName: []const u8,
        internal_id: u32,
        nickname: ?[]const u8,
    };

    const value = Example{
        .firstName = "Ada",
        .internal_id = 42,
        .nickname = null,
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try serializeWith(&out.writer, value, .{
        .rename_all = .snake_case,
        .omit_null_fields = true,
    }, .{});

    try std.testing.expectEqualStrings(
        "{\"first_name\":\"Ada\",\"internal_id\":42}",
        out.written(),
    );
}

test "typed deserialize supports config rename_all" {
    const Example = struct {
        firstName: []const u8,
        accountId: u64,
    };

    const allocator = std.testing.allocator;
    const decoded = try parseSliceWith(Example, allocator, "{\"first_name\":\"Ada\",\"account_id\":99}", .{
        .rename_all = .snake_case,
    }, .{});
    defer allocator.free(decoded.firstName);

    try std.testing.expectEqualStrings("Ada", decoded.firstName);
    try std.testing.expectEqual(@as(u64, 99), decoded.accountId);
}

test "typed deserialize handles escaped strings on direct path" {
    const Example = struct {
        message: []const u8,
        nickname: ?[]const u8,
    };

    const allocator = std.testing.allocator;
    const decoded = try parseSliceWith(Example, allocator, "{\"message\":\"Ada\\nLovelace\",\"nickname\":null}", .{}, .{});
    defer allocator.free(decoded.message);

    try std.testing.expectEqualStrings("Ada\nLovelace", decoded.message);
    try std.testing.expectEqual(@as(?[]const u8, null), decoded.nickname);
}

test "parseSliceAliased reuses unescaped strings from input" {
    const Example = struct {
        message: []const u8,
    };

    const input = "{\"message\":\"Ada\"}";
    const decoded = try parseSliceAliased(Example, std.testing.allocator, input);

    try std.testing.expectEqualStrings("Ada", decoded.message);
    try std.testing.expect(@intFromPtr(decoded.message.ptr) >= @intFromPtr(input.ptr));
    try std.testing.expect(@intFromPtr(decoded.message.ptr) < @intFromPtr(input.ptr) + input.len);
}

test "typed deserialize detects duplicate and unknown fields on direct path" {
    const Example = struct {
        port: u16,
    };

    try std.testing.expectError(
        error.DuplicateField,
        parseSliceWith(Example, std.testing.allocator, "{\"port\":8080,\"port\":9090}", .{}, .{}),
    );

    try std.testing.expectError(
        error.UnknownField,
        parseSliceWith(Example, std.testing.allocator, "{\"port\":8080,\"extra\":1}", .{
            .deny_unknown_fields = true,
        }, .{}),
    );
}

test "reader and writer entrypoints work" {
    const allocator = std.testing.allocator;

    var reader = std.Io.Reader.fixed("{\"service_name\":\"api\",\"port\":8080}");
    const Example = struct {
        serviceName: []const u8,
        port: u16,
    };

    const decoded = try deserializeWith(Example, allocator, &reader, .{
        .rename_all = .snake_case,
    }, .{});
    defer allocator.free(decoded.serviceName);

    try std.testing.expectEqualStrings("api", decoded.serviceName);
    try std.testing.expectEqual(@as(u16, 8080), decoded.port);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try serializeWith(&out.writer, decoded, .{
        .rename_all = .snake_case,
    }, .{});

    try std.testing.expectEqualStrings(
        "{\"service_name\":\"api\",\"port\":8080}",
        out.written(),
    );
}

test "a fixed byte array is a raw string by default" {
    const Example = struct { tag: [2]u8 };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serializeWith(&out.writer, Example{ .tag = "ok".* }, .{}, .{});
    try std.testing.expectEqualStrings("{\"tag\":\"ok\"}", out.written());

    const decoded = try parseSlice(Example, std.testing.allocator, out.written());
    try std.testing.expectEqualDeep("ok".*, decoded.tag);
}

test "a fixed byte array round-trips as padded standard base64" {
    const Example = struct { digest: [4]u8 };
    const value = Example{ .digest = .{ 0xfb, 0xff, 0x00, 0x3e } };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serializeWith(&out.writer, value, .{}, WriteConfig{ .bytes = .base64 });
    try std.testing.expectEqualStrings("{\"digest\":\"+/8APg==\"}", out.written());

    const decoded = try parseSliceWith(Example, std.testing.allocator, out.written(), .{}, .{ .bytes = .base64 });
    try std.testing.expectEqualDeep(value, decoded);
}

test "a fixed byte array round-trips as unpadded url-safe base64" {
    const Example = struct { digest: [4]u8 };
    const value = Example{ .digest = .{ 0xfb, 0xff, 0x00, 0x3e } };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serializeWith(&out.writer, value, .{}, .{ .bytes = .base64url });
    try std.testing.expectEqualStrings("{\"digest\":\"-_8APg\"}", out.written());

    const decoded = try parseSliceWith(Example, std.testing.allocator, out.written(), .{}, ReadConfig{ .bytes = .base64url });
    try std.testing.expectEqualDeep(value, decoded);
}

test "a base64 field that does not decode is refused" {
    const Example = struct { digest: [4]u8 };
    try std.testing.expectError(
        error.InvalidBytes,
        parseSliceWith(Example, std.testing.allocator, "{\"digest\":\"not base64!\"}", .{}, .{ .bytes = .base64 }),
    );
}

test "a type can ask for bytewise field order" {
    const Example = struct {
        zeta: u8,
        alpha: u8,

        pub const serde = .{ .field_order = .bytewise };
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serializeWith(&out.writer, Example{ .zeta = 1, .alpha = 2 }, .{}, .{});
    try std.testing.expectEqualStrings("{\"alpha\":2,\"zeta\":1}", out.written());
}
