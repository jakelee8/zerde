//! Structured diagnostics for parse and deserialize failures.
//!
//! The normal `!T` APIs stay lightweight. Callers that want richer failures can
//! pass a `Diagnostic` to the `...WithDiagnostics` entrypoints and get the
//! failing field path plus best-effort location data.

const std = @import("std");

pub const Location = struct {
    offset: ?usize = null,
    line: ?usize = null,
    column: ?usize = null,
};

pub const PathSegment = union(enum) {
    field: []const u8,
    index: usize,
};

/// The kind of a value in the input, as a diagnostic reports it.
pub const Kind = enum { null, bool, integer, float, string, bytes, array, object, tag };
pub const KindSet = std.EnumSet(Kind);
/// A value's start in the input and its kind; `kind` is null when the bytes there are not a well-formed value start.
/// `tagged`: the first head at `offset` is a CBOR tag (any tag, 55799 included), which `kind` reads through when it can.
pub const Found = struct { offset: usize, kind: ?Kind, tagged: bool = false };

pub const Detail = union(enum) {
    none,
    type_mismatch: struct { expected: KindSet, found: Kind },
    /// The key's text is `Diagnostic.unknownKey()`, when it could be read.
    unknown_field,
    /// Zig field names, as the path uses.
    duplicate_field: []const u8,
    missing_field: []const u8,
    length_out_of_bounds: struct { min_len: usize, max_len: usize },
    value_out_of_range: struct { min: ?i128, max: ?i128 },
};

pub const Diagnostic = struct {
    path: [64]PathSegment = undefined,
    path_len: usize = 0,
    /// The path was longer than `path` holds, and its outermost segments were dropped.
    path_truncated: bool = false,
    location: Location = .{},
    detail: Detail = .none,
    key_buffer: [64]u8 = undefined,
    key_len: ?usize = null,
    key_truncated: bool = false,

    pub fn clear(self: *Diagnostic) void {
        self.path_len = 0;
        self.path_truncated = false;
        self.location = .{};
        self.detail = .none;
        self.key_len = null;
        self.key_truncated = false;
    }

    /// Adds a field segment as an error unwinds through it; segments arrive innermost first.
    pub fn unwindField(self: *Diagnostic, name: []const u8) void {
        self.push(.{ .field = name });
    }

    /// Adds an index segment as an error unwinds through it; segments arrive innermost first.
    pub fn unwindIndex(self: *Diagnostic, index: usize) void {
        self.push(.{ .index = index });
    }

    /// Puts the unwound path outermost first.
    pub fn finishPath(self: *Diagnostic) void {
        std.mem.reverse(PathSegment, self.path[0..self.path_len]);
    }

    /// Keeps up to 64 bytes of an unknown key's text.
    pub fn setKey(self: *Diagnostic, bytes: []const u8) void {
        const len = @min(bytes.len, self.key_buffer.len);
        @memcpy(self.key_buffer[0..len], bytes[0..len]);
        self.key_len = len;
        self.key_truncated = bytes.len > self.key_buffer.len;
    }

    pub fn unknownKey(self: *const Diagnostic) ?[]const u8 {
        const len = self.key_len orelse return null;
        return self.key_buffer[0..len];
    }

    pub fn captureFromDeserializer(self: *Diagnostic, deserializer: anytype) void {
        if (self.location.offset) |offset| {
            // The typed layer pointed at the value that failed; only its line and column are left to resolve.
            if (@hasDecl(@TypeOf(deserializer.*), "locationAt")) self.location = deserializer.locationAt(offset);
            return;
        }
        const DeserializerType = @TypeOf(deserializer.*);
        if (@hasDecl(DeserializerType, "errorLocation")) {
            self.mergeLocation(deserializer.errorLocation());
        } else if (@hasDecl(DeserializerType, "errorOffset")) {
            self.mergeLocation(.{ .offset = deserializer.errorOffset() });
        }
    }

    pub fn format(self: *const Diagnostic, writer: *std.Io.Writer, err: anytype) !void {
        try writer.print("{s}", .{@errorName(err)});

        if (self.path_len != 0) {
            try writer.writeAll(" at root");
            if (self.path_truncated) try writer.writeAll("[...]");
            for (self.path[0..self.path_len]) |segment| {
                switch (segment) {
                    .field => |name| try writer.print(".{s}", .{name}),
                    .index => |index| try writer.print("[{d}]", .{index}),
                }
            }
        }

        if (self.location.offset != null or self.location.line != null) {
            try writer.writeAll(" (");
            var wrote = false;

            if (self.location.offset) |offset| {
                try writer.print("offset {d}", .{offset});
                wrote = true;
            }
            if (self.location.line) |line| {
                if (wrote) try writer.writeAll(", ");
                if (self.location.column) |column| {
                    try writer.print("line {d}, column {d}", .{ line, column });
                } else {
                    try writer.print("line {d}", .{line});
                }
            }

            try writer.writeAll(")");
        }

        if (self.detail != .none) try writer.writeAll(": ");
        switch (self.detail) {
            .none => {},
            .type_mismatch => |mismatch| {
                try writer.writeAll("expected ");
                var kinds = mismatch.expected.iterator();
                var first = true;
                while (kinds.next()) |kind| {
                    if (!first) try writer.writeAll(" or ");
                    first = false;
                    try writer.writeAll(@tagName(kind));
                }
                try writer.print(", found {s}", .{@tagName(mismatch.found)});
            },
            .unknown_field => if (self.unknownKey()) |key| {
                try writer.print("unknown field \"{f}", .{std.zig.fmtString(key)});
                if (self.key_truncated) try writer.writeAll("...");
                try writer.writeAll("\"");
            } else {
                try writer.writeAll("unknown field");
            },
            .duplicate_field => |name| try writer.print("duplicate field \"{s}\"", .{name}),
            .missing_field => |name| try writer.print("missing field \"{s}\"", .{name}),
            .length_out_of_bounds => |bounds| {
                const min: ?usize = if (bounds.min_len == 0) null else bounds.min_len;
                const max: ?usize = if (bounds.max_len == std.math.maxInt(usize)) null else bounds.max_len;
                try writeRange(writer, "length", min, max);
            },
            .value_out_of_range => |range| try writeRange(writer, "value", range.min, range.max),
        }
    }

    fn push(self: *Diagnostic, segment: PathSegment) void {
        if (self.path_len == self.path.len) {
            self.path_truncated = true;
            return;
        }

        self.path[self.path_len] = segment;
        self.path_len += 1;
    }

    fn mergeLocation(self: *Diagnostic, location: Location) void {
        if (location.offset != null) self.location.offset = location.offset;
        if (location.line != null) self.location.line = location.line;
        if (location.column != null) self.location.column = location.column;
    }
};

fn writeRange(writer: *std.Io.Writer, comptime what: []const u8, min: anytype, max: @TypeOf(min)) !void {
    if (min == null) return writer.print(what ++ " must be at most {d}", .{max.?});
    if (max == null) return writer.print(what ++ " must be at least {d}", .{min.?});
    try writer.print(what ++ " must be within [{d}, {d}]", .{ min.?, max.? });
}

pub fn locationFromOffset(input: []const u8, offset: usize) Location {
    const clamped = @min(offset, input.len);

    var line: usize = 1;
    var column: usize = 1;
    for (input[0..clamped]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }

    return .{
        .offset = clamped,
        .line = line,
        .column = column,
    };
}
