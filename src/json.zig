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
    /// Do not check that text is UTF-8 (`error.InvalidUtf8`): for an item known to be valid already,
    /// such as one this library wrote and a store authenticated, where checking again costs more than
    /// the rest of the read. Input that has not been checked once must not be read this way.
    trusted_text: bool = false,
};
pub const WriteConfig = struct {
    bytes: BytesEncoding = .string,
    /// Do not check that text is UTF-8 on the way out (`error.InvalidUtf8`): for text known to be
    /// valid already, such as a string just read from a source that was checked.
    trusted_text: bool = false,
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
            try writeStringText(self.writer, value, readLimitFlag(self.cfg, "trusted_text", false));
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
            try verifyText(bytes);
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
            return .{ .writer = self.writer, .encoding = bytesEncoding(Config, self.cfg), .trusted_text = readLimitFlag(self.cfg, "trusted_text", false) };
        }

        pub const raw_format: typed.RawFormat = .json;

        /// Writes JSON text that was read as `json.Raw`, after checking it is one JSON value.
        pub fn emitRaw(self: *Self, value: []const u8) !void {
            try verifyText(value);
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
        /// A word the caller keeps with the deserializer, for decode hooks to read (`PullReader.userData`).
        user_data: usize = 0,
        /// Where the key of the last member `nextObjectFieldIndex` called unknown starts.
        last_key: usize = 0,
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
                .parser = .{ .input = input, .max_string_len = readLimit(cfg, "max_string_len", std.math.maxInt(usize)), .trusted_text = readLimitFlag(cfg, "trusted_text", false) },
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
                .parser = .{ .input = input, .max_string_len = readLimit(cfg, "max_string_len", std.math.maxInt(usize)), .trusted_text = readLimitFlag(cfg, "trusted_text", false) },
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
            const codec = switch (bytesEncoding(Config, self.cfg)) {
                .string => return self.readString(allocator),
                .base64 => &std.base64.standard.Decoder,
                .base64url => &std.base64.url_safe_no_pad.Decoder,
            };
            try self.count();
            self.parser.skipWhitespace();
            return self.parser.parseBytesToken(allocator, codec);
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

        /// `readString` for a field with a `max_len`: a string longer than `max` is refused as it is
        /// built, so an escaped string is not joined into memory the bound exists to deny.
        pub fn readStringMax(self: *Self, allocator: Allocator, max: usize) !StringToken {
            return self.readWithin(allocator, max, readString);
        }

        /// `readByteToken` for a field with a `max_len` on the decoded bytes: the token it is read from
        /// is at most as long as `max` bytes take in the config's encoding.
        pub fn readByteTokenMax(self: *Self, allocator: Allocator, max: usize) !StringToken {
            const text_max = switch (bytesEncoding(Config, self.cfg)) {
                .string => max,
                .base64, .base64url => std.math.add(usize, max / 3 * 4, 8) catch std.math.maxInt(usize),
            };
            return self.readWithin(allocator, text_max, readByteToken);
        }

        fn readWithin(self: *Self, allocator: Allocator, max: usize, comptime read: anytype) !StringToken {
            const saved = self.parser.max_string_len;
            defer self.parser.max_string_len = saved;
            if (max < saved) self.parser.max_string_len = max;
            return read(self, allocator) catch |err| if (err == error.StringTooLong and max < saved) error.LengthOutOfBounds else err;
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

        /// Moves to the next key of the map being read: false at its end, with the map closed.
        fn startObjectKey(self: *Self) !bool {
            const frame = self.current();
            if (frame.kind != .object) return error.InvalidJsonState;

            self.parser.skipWhitespace();
            if (frame.first) {
                if (self.parser.peek() == '}') {
                    _ = self.parser.consume();
                    _ = self.pop();
                    return false;
                }
                frame.first = false;
            } else {
                const next = self.parser.consume() orelse return error.UnexpectedEndOfInput;
                switch (next) {
                    ',' => self.parser.skipWhitespace(),
                    '}' => {
                        _ = self.pop();
                        return false;
                    },
                    else => return error.UnexpectedToken,
                }
            }

            if (self.parser.peek() != '"') return error.UnexpectedToken;
            try self.count();
            return true;
        }

        fn endObjectKey(self: *Self) !void {
            self.parser.skipWhitespace();
            if (self.parser.consume() != ':') return error.UnexpectedToken;
        }

        pub fn nextObjectField(self: *Self, allocator: Allocator) !?StringToken {
            if (!try self.startObjectKey()) return null;
            const key = try self.parser.parseStringToken(allocator);
            errdefer key.deinit(allocator);
            try self.endObjectKey();
            return key;
        }

        /// The next key of a union's map (see `readStringShort`), or null at its end.
        pub fn nextObjectKeyShort(self: *Self, comptime cap: usize, buffer: *[cap]u8) !?typed.ObjectKeyShort {
            if (!try self.startObjectKey()) return null;
            const key = try self.parser.parseStringShort(cap, buffer);
            try self.endObjectKey();
            return switch (key) {
                .text => |bytes| .{ .text = bytes },
                .long => .long,
            };
        }

        /// A string compared with names a type declares, read without allocating (see `typed.ShortText`).
        pub fn readStringShort(self: *Self, comptime cap: usize, buffer: *[cap]u8) !typed.ShortText {
            try self.count();
            self.parser.skipWhitespace();
            return self.parser.parseStringShort(cap, buffer);
        }

        /// The next key of a struct's map, matched to one of `T`'s fields where it is read, so a key is not
        /// allocated; one that names no field is `.unknown` and `unknownKey` reads it again.
        pub fn nextObjectFieldIndex(self: *Self, comptime T: type, comptime cfg: anytype) !typed.ObjectFieldLookup {
            if (!try self.startObjectKey()) return .end;
            self.parser.skipWhitespace();
            const start = self.parser.index;
            const cap = comptime typed.longestFieldName(T, cfg);
            var buffer: [cap]u8 = undefined;
            const key = try self.parser.parseStringShort(cap, &buffer);
            try self.endObjectKey();
            switch (key) {
                .text => |bytes| if (typed.matchStructFieldIndex(T, cfg, bytes)) |index| return .{ .field_index = index },
                .long => {},
            }
            self.last_key = start;
            return .unknown;
        }

        /// The key of the member `nextObjectFieldIndex` called `.unknown`, decoded into the allocator's memory.
        pub fn unknownKey(self: *Self, allocator: Allocator) !StringToken {
            var parser = self.parser;
            parser.index = self.last_key;
            return parser.parseStringToken(allocator);
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

        pub const raw_format: typed.RawFormat = .json;

        /// The next value as the text it was read from, without the whitespace around it.
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

        /// The whole item as a `T`, read by the typed layer with the deserializer's mode and limits and
        /// `serde_cfg`: for a decode hook whose type is a schema type with some fixed layout around
        /// it. Only before the first event; it takes the item, so the reader is done after it.
        pub fn readTyped(self: *Self, comptime T: type, allocator: Allocator, comptime serde_cfg: anytype) !T {
            self.release();
            if (self.done or self.d.stack_len != self.base) return error.InvalidJsonState;
            const value = try typed.deserialize(T, allocator, self.d, serde_cfg);
            self.done = self.d.stack_len == self.base;
            return value;
        }

        /// The caller's word set on the deserializer (`user_data`), such as the base address of the
        /// spans a wire type writes.
        pub fn userData(self: *const Self) usize {
            return self.d.user_data;
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

        /// The next value whole, as the bytes it was read from: what `readRaw` gives a `Raw` field. For
        /// a wire type's decode hook, which can return the span it consumed. Call it where a value is
        /// expected, as `next` would return one. The item is checked as the mode and limits say, and
        /// the bytes are valid as long as the input is. An end or a map key where a value is due is
        /// `error.UnexpectedType`.
        pub fn raw(self: *Self) ![]const u8 {
            self.release();
            const d = self.d;
            if (d.stack_len == self.base) {
                if (self.done) return error.UnexpectedEndOfInput;
                const token = try d.readRaw(self.allocator);
                self.done = d.stack_len == self.base;
                return token.bytes;
            }
            const depth = d.stack_len - 1;
            switch (d.current().kind) {
                .array => {
                    if (!try d.nextArrayItem()) {
                        self.done = d.stack_len == self.base;
                        return error.UnexpectedType;
                    }
                },
                .object => {
                    if (!self.want_value[depth]) return error.UnexpectedType;
                    self.want_value[depth] = false;
                },
            }
            return (try d.readRaw(self.allocator)).bytes;
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
/// wants them written. It keeps the guarantees of `ValueWriter` that it can without buffering: the
/// lengths given to `beginArray` and `beginMap` are met exactly (`error.LengthMismatch`; JSON does not
/// state them, but the same hook writes CBOR), nesting is at most 128, text is UTF-8, `writeRaw` takes
/// one valid JSON value, and `finish` says the one item is complete. Bytes follow the config's `bytes`
/// encoding, and a NaN or infinity is refused.
pub const Encoder = struct {
    writer: *std.Io.Writer,
    encoding: BytesEncoding,
    trusted_text: bool = false,
    frames: [128]struct { kind: ContainerKind, first: bool, expect_key: bool, remaining: u64 } = undefined,
    depth: usize = 0,
    root_done: bool = false,

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
                if (frame.remaining == 0) return error.LengthMismatch;
                if (!frame.first) try self.writer.writeByte(',');
                frame.first = false;
                try writeStringText(self.writer, value, self.trusted_text);
                try self.writer.writeByte(':');
                frame.expect_key = false;
                frame.remaining -= 1;
                return;
            }
        }
        try self.beforeValue();
        try writeStringText(self.writer, value, self.trusted_text);
        self.afterValue();
    }

    pub fn writeBytes(self: *Encoder, value: []const u8) !void {
        try self.beforeValue();
        try writeBytesText(self.writer, self.encoding, value);
        self.afterValue();
    }

    /// One JSON value that is already text, checked first.
    pub fn writeRaw(self: *Encoder, text: []const u8) !void {
        try verifyText(text);
        try self.beforeValue();
        try self.writer.writeAll(text);
        self.afterValue();
    }

    pub fn beginArray(self: *Encoder, len: usize) !void {
        try self.beforeValue();
        try self.push(.array, len);
        try self.writer.writeByte('[');
    }

    pub fn endArray(self: *Encoder) !void {
        if (self.depth == 0 or self.frames[self.depth - 1].kind != .array) return error.UnbalancedContainers;
        if (self.frames[self.depth - 1].remaining != 0) return error.LengthMismatch;
        try self.writer.writeByte(']');
        self.depth -= 1;
        self.afterValue();
    }

    pub fn beginMap(self: *Encoder, len: usize) !void {
        try self.beforeValue();
        try self.push(.object, std.math.mul(u64, len, 2) catch return error.LengthMismatch);
        try self.writer.writeByte('{');
    }

    pub fn endMap(self: *Encoder) !void {
        if (self.depth == 0 or self.frames[self.depth - 1].kind != .object or !self.frames[self.depth - 1].expect_key) return error.UnbalancedContainers;
        if (self.frames[self.depth - 1].remaining != 0) return error.LengthMismatch;
        try self.writer.writeByte('}');
        self.depth -= 1;
        self.afterValue();
    }

    /// After the item: it is complete, and nothing is open.
    pub fn finish(self: *Encoder) !void {
        if (self.depth != 0 or !self.root_done) return error.LengthMismatch;
    }

    fn beforeValue(self: *Encoder) !void {
        if (self.depth == 0) {
            if (self.root_done) return error.LengthMismatch;
            return;
        }
        const frame = &self.frames[self.depth - 1];
        if (frame.remaining == 0) return error.LengthMismatch;
        switch (frame.kind) {
            .array => {
                if (!frame.first) try self.writer.writeByte(',');
                frame.first = false;
            },
            .object => if (frame.expect_key) return error.UnexpectedType,
        }
    }

    fn afterValue(self: *Encoder) void {
        if (self.depth == 0) {
            self.root_done = true;
            return;
        }
        const frame = &self.frames[self.depth - 1];
        frame.remaining -= 1;
        if (frame.kind == .object) frame.expect_key = true;
    }

    fn push(self: *Encoder, kind: ContainerKind, len: u64) !void {
        if (self.depth >= self.frames.len) return error.JsonNestingTooDeep;
        self.frames[self.depth] = .{ .kind = kind, .first = true, .expect_key = true, .remaining = len };
        self.depth += 1;
    }
};

/// A writer for a value whose shape is only known while writing; see `cbor.ValueWriter`. A map's
/// keys are text, and the map is buffered until it closes so its members can be sorted: with
/// `sort_keys` (the default) shorter keys come first and equal lengths bytewise, which is the order of
/// deterministic CBOR keys, and a repeated key is `error.DuplicateField`. Arrays are written as they
/// come. Bytes are written in the config's `bytes` encoding, and a NaN or infinity is refused.
pub fn valueWriter(allocator: Allocator, writer: *std.Io.Writer, comptime cfg: anytype) ValueWriter {
    var result = ValueWriter.init(allocator, writer, readLimitFlag(cfg, "sort_keys", true), bytesEncoding(@TypeOf(cfg), cfg));
    result.trusted_text = readLimitFlag(cfg, "trusted_text", false);
    return result;
}

pub const ValueWriter = struct {
    allocator: Allocator,
    out: *std.Io.Writer,
    sort_keys: bool,
    encoding: BytesEncoding,
    trusted_text: bool = false,
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
                try writeStringText(out, value, self.trusted_text);
                try out.writeByte(':');
                frame.key_start = frame.keys.items.len;
                frame.key_len = value.len;
                try frame.keys.appendSlice(self.allocator, value);
                frame.expect_key = false;
                return;
            }
        }
        try self.beforeValue();
        try writeStringText(self.sink(), value, self.trusted_text);
        try self.afterValue();
    }

    pub fn writeBytes(self: *ValueWriter, value: []const u8) !void {
        try self.beforeValue();
        try writeBytesText(self.sink(), self.encoding, value);
        try self.afterValue();
    }

    /// Writes JSON text that is already valid: a `Raw` that was read, say. It is checked first.
    pub fn writeRaw(self: *ValueWriter, text: []const u8) !void {
        try verifyText(text);
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

/// A JSON string for `value`, checked for UTF-8 unless the caller says it is known to be valid.
fn writeStringText(writer: *std.Io.Writer, value: []const u8, trusted: bool) !void {
    if (trusted) try writeQuoted(writer, value) else try writeEscapedString(writer, value);
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

/// Checks, without allocating, that `text` is exactly one JSON value (whitespace around it allowed)
/// that the writer may put out as it is: well-formed, strings valid, nesting within 128. A repeated
/// member name is not looked for: that needs an allocation.
fn verifyText(text: []const u8) !void {
    var parser: Parser = .{ .input = text, .checked = true };
    try parser.skipValueTrusted(0);
    parser.skipWhitespace();
    if (parser.index != text.len) return error.TrailingCharacters;
}

const Parser = struct {
    input: []const u8,
    index: usize = 0,
    max_string_len: usize = std.math.maxInt(usize),
    /// Text is not checked for UTF-8; see `ReadConfig.trusted_text`.
    trusted_text: bool = false,
    /// `skipValueTrusted` checks the strings it steps over (escapes, control characters, UTF-8).
    checked: bool = false,

    const NumberSlice = struct {
        slice: []const u8,
        is_float: bool,
    };

    /// What reading a base64 string adds to a string's errors.
    const BytesError = Error || error{InvalidBytes};

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
    fn validUtf8(self: *const Parser, bytes: []const u8) Error![]const u8 {
        if (!self.trusted_text and !bulk.validUtf8(bytes)) return error.InvalidUtf8;
        return bytes;
    }

    // Plain strings borrow from the input; an escaped string is measured first and written once into an
    // exact allocation: the walk below runs twice over it, to count (and check) and to write.
    fn parseStringToken(self: *Parser, allocator: Allocator) Error!StringToken {
        const token = try self.parseStringTokenUnbounded(allocator);
        if (token.bytes.len > self.max_string_len) {
            token.deinit(allocator);
            return error.StringTooLong;
        }
        return token;
    }

    /// Reads up to the first escape or the closing quote of the string at `self.index` (after its opening
    /// quote): the input's own bytes if it has no escape, else null with `self.index` where the string began.
    fn plainString(self: *Parser) Error!?[]const u8 {
        const start = self.index;
        while (true) {
            self.index = bulk.findStringSpecial(self.input, self.index);
            const c = self.consume() orelse return error.UnexpectedEndOfInput;
            switch (c) {
                '"' => return try self.validUtf8(self.input[start .. self.index - 1]),
                '\\' => {
                    self.index = start;
                    return null;
                },
                0...31 => return error.InvalidStringCharacter,
                else => {},
            }
        }
    }

    fn parseStringTokenUnbounded(self: *Parser, allocator: Allocator) Error!StringToken {
        if (self.consume() != '"') return error.UnexpectedToken;
        if (try self.plainString()) |plain| return .{ .bytes = plain, .allocated = false };

        const start = self.index;
        var measure: Measure = .{ .max = self.max_string_len };
        try self.walkString(&measure);
        const end = self.index;
        self.index = start;
        const buffer = try allocator.alloc(u8, measure.len);
        errdefer allocator.free(buffer);
        var write: Write = .{ .dest = buffer };
        try self.walkString(&write);
        std.debug.assert(self.index == end);
        return .{ .bytes = buffer, .allocated = true };
    }

    /// The text of a string with no allocation to measure it: how long it is, checked against `max`, and its last two bytes.
    const Measure = struct {
        max: usize,
        len: usize = 0,
        tail: [2]u8 = .{ 0, 0 },
        const checks = true;

        fn put(self: *Measure, bytes: []const u8) Error!void {
            self.len += bytes.len;
            if (self.len > self.max) return error.StringTooLong;
            if (bytes.len >= 2) {
                self.tail = .{ bytes[bytes.len - 2], bytes[bytes.len - 1] };
            } else if (bytes.len == 1) {
                self.tail = .{ self.tail[1], bytes[0] };
            }
        }
    };

    /// The text of a string into the exact buffer `Measure` sized.
    const Write = struct {
        dest: []u8,
        at: usize = 0,
        const checks = false;

        fn put(self: *Write, bytes: []const u8) Error!void {
            @memcpy(self.dest[self.at..][0..bytes.len], bytes);
            self.at += bytes.len;
        }
    };

    /// Walks the string at `self.index` (after its opening quote) to its closing quote, giving each run of
    /// plain bytes and each escape's UTF-8 bytes to `out.put`, in order. With `Out.checks` it also checks
    /// every run is UTF-8 and a control character is refused; the pass that writes runs after one that checked.
    fn walkString(self: *Parser, out: anytype) !void {
        const Out = @typeInfo(@TypeOf(out)).pointer.child;
        var run_start = self.index;
        while (true) {
            self.index = bulk.findStringSpecial(self.input, self.index);
            const c = self.consume() orelse return error.UnexpectedEndOfInput;
            switch (c) {
                '"', '\\' => {
                    const run = self.input[run_start .. self.index - 1];
                    try out.put(if (Out.checks) try self.validUtf8(run) else run);
                    if (c == '"') return;
                    var bytes: [4]u8 = undefined;
                    const length = try self.escapeBytes(&bytes);
                    try out.put(bytes[0..length]);
                    run_start = self.index;
                },
                0...31 => return error.InvalidStringCharacter,
                else => {},
            }
        }
    }

    /// A string that holds base64 in the config's encoding, decoded into an exact allocation. One with no
    /// escape is decoded from the input itself; one with escapes is measured, then unescaped through a
    /// small buffer into the decoder, so the token is never built.
    fn parseBytesToken(self: *Parser, allocator: Allocator, codec: *const std.base64.Base64Decoder) BytesError!StringToken {
        if (self.consume() != '"') return error.UnexpectedToken;
        if (try self.plainString()) |plain| {
            if (plain.len > self.max_string_len) return error.StringTooLong;
            const length = codec.calcSizeForSlice(plain) catch return error.InvalidBytes;
            const buffer = try allocator.alloc(u8, length);
            errdefer allocator.free(buffer);
            codec.decode(buffer, plain) catch return error.InvalidBytes;
            return .{ .bytes = buffer, .allocated = true };
        }

        const start = self.index;
        var measure: Measure = .{ .max = self.max_string_len };
        try self.walkString(&measure);
        const end = self.index;
        self.index = start;
        var length = codec.calcSizeUpperBound(measure.len) catch return error.InvalidBytes;
        if (codec.pad_char) |pad| {
            if (measure.len >= 1 and measure.tail[1] == pad) length -= 1;
            if (measure.len >= 2 and measure.tail[0] == pad) length -= 1;
        }
        const buffer = try allocator.alloc(u8, length);
        errdefer allocator.free(buffer);
        var write: DecodeBase64 = .{ .codec = codec, .dest = buffer };
        try self.walkString(&write);
        try write.finish();
        std.debug.assert(self.index == end);
        return .{ .bytes = buffer, .allocated = true };
    }

    /// The text of a base64 string, decoded as it is unescaped: a chunk of 256 characters (a multiple of four, so
    /// each decodes on its own) at a time into the exact buffer `Measure` sized.
    const DecodeBase64 = struct {
        codec: *const std.base64.Base64Decoder,
        dest: []u8,
        at: usize = 0,
        chunk: [256]u8 = undefined,
        filled: usize = 0,
        const checks = false;

        fn put(self: *DecodeBase64, bytes: []const u8) BytesError!void {
            var rest = bytes;
            while (rest.len != 0) {
                const take = @min(rest.len, self.chunk.len - self.filled);
                @memcpy(self.chunk[self.filled..][0..take], rest[0..take]);
                self.filled += take;
                rest = rest[take..];
                if (self.filled == self.chunk.len) try self.flush();
            }
        }

        fn finish(self: *DecodeBase64) BytesError!void {
            if (self.filled != 0) try self.flush();
            if (self.at != self.dest.len) return error.InvalidBytes;
        }

        fn flush(self: *DecodeBase64) BytesError!void {
            const text = self.chunk[0..self.filled];
            self.filled = 0;
            const length = self.codec.calcSizeForSlice(text) catch return error.InvalidBytes;
            self.codec.decode(self.dest[self.at..][0..length], text) catch return error.InvalidBytes;
            self.at += length;
        }
    };

    /// The UTF-8 bytes of the escape after a backslash (up to four), which is consumed.
    fn escapeBytes(self: *Parser, out: *[4]u8) Error!usize {
        const escape = self.consume() orelse return error.UnexpectedEndOfInput;
        switch (escape) {
            '"', '\\', '/' => out[0] = escape,
            'b' => out[0] = '\x08',
            'f' => out[0] = '\x0c',
            'n' => out[0] = '\n',
            'r' => out[0] = '\r',
            't' => out[0] = '\t',
            'u' => return self.unicodeEscapeBytes(out),
            else => return error.InvalidStringEscape,
        }
        return 1;
    }

    fn unicodeEscapeBytes(self: *Parser, out: *[4]u8) Error!usize {
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

        return std.unicode.utf8Encode(codepoint, out) catch unreachable;
    }

    /// A string, decoded into `buffer` if it is at most `cap` bytes, or read to its end and checked and
    /// called `.long`; a string with no escape is the input's own bytes. Nothing is allocated.
    fn parseStringShort(self: *Parser, comptime cap: usize, buffer: *[cap]u8) Error!typed.ShortText {
        if (self.consume() != '"') return error.UnexpectedToken;
        var run_start = self.index;
        var length: usize = 0;
        var total: usize = 0;
        var long = false;
        var escaped = false;
        while (true) {
            self.index = bulk.findStringSpecial(self.input, self.index);
            const c = self.consume() orelse return error.UnexpectedEndOfInput;
            switch (c) {
                '"', '\\' => {
                    const run = try self.validUtf8(self.input[run_start .. self.index - 1]);
                    total += run.len;
                    if (c == '"' and !escaped) {
                        if (total > self.max_string_len) return error.StringTooLong;
                        return .{ .text = run };
                    }
                    escaped = true;
                    if (!long and length + run.len <= cap) {
                        @memcpy(buffer[length..][0..run.len], run);
                        length += run.len;
                    } else long = true;
                    if (c == '"') {
                        if (total > self.max_string_len) return error.StringTooLong;
                        return if (long) .long else .{ .text = buffer[0..length] };
                    }
                    var bytes: [4]u8 = undefined;
                    const count = try self.escapeBytes(&bytes);
                    total += count;
                    if (total > self.max_string_len) return error.StringTooLong;
                    if (!long and length + count <= cap) {
                        @memcpy(buffer[length..][0..count], bytes[0..count]);
                        length += count;
                    } else long = true;
                    run_start = self.index;
                },
                0...31 => return error.InvalidStringCharacter,
                else => {},
            }
        }
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

    /// Steps over a string literal and checks it: UTF-8, no control character, valid escapes.
    fn skipStringChecked(self: *Parser) Error!void {
        if (self.consume() != '"') return error.UnexpectedToken;
        const start = self.index;
        while (true) {
            self.index = bulk.findStringSpecial(self.input, self.index);
            switch (self.consume() orelse return error.UnexpectedEndOfInput) {
                '"' => {
                    if (!bulk.validUtf8(self.input[start .. self.index - 1])) return error.InvalidUtf8;
                    return;
                },
                '\\' => switch (self.consume() orelse return error.UnexpectedEndOfInput) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {},
                    'u' => {
                        const first = try self.parseHex4();
                        if (std.unicode.utf16IsHighSurrogate(first)) {
                            if (self.consume() != '\\' or self.consume() != 'u') return error.InvalidUnicodeSurrogate;
                            if (!std.unicode.utf16IsLowSurrogate(try self.parseHex4())) return error.InvalidUnicodeSurrogate;
                        } else if (std.unicode.utf16IsLowSurrogate(first)) {
                            return error.InvalidUnicodeSurrogate;
                        }
                    },
                    else => return error.InvalidStringEscape,
                },
                0...31 => return error.InvalidStringCharacter,
                else => {},
            }
        }
    }

    /// Steps over a value that is already known to be valid, without checking it again, unless
    /// `checked`. Too deep nesting is an error, not a trap.
    fn skipValueTrusted(self: *Parser, depth: usize) Error!void {
        if (depth > 128) return error.JsonNestingTooDeep;
        self.skipWhitespace();
        switch (self.peek() orelse return error.UnexpectedEndOfInput) {
            '"' => if (self.checked) try self.skipStringChecked() else try self.skipStringTrusted(),
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
                        if (self.checked) try self.skipStringChecked() else try self.skipStringTrusted();
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
