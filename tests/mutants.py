#!/usr/bin/env python3
"""Mutation check of the guards in the typed layer and the CBOR, JSON, MessagePack and BSON readers.

Each mutant removes or weakens one guard. `zig build test` must fail on it (a compile error or a
crash counts: the guard is structural). A mutant that survives is a guard without a test.

    python3 tests/mutants.py            # every mutant
    python3 tests/mutants.py 3 17       # by index

The source is copied aside and restored after each mutant, and again on exit. Run it on a clean tree;
`flock` is used when a lock path is given in MUTANT_LOCK.
"""
import os
import re
import shutil
import signal
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

# (file, original, mutated)
MUTANTS = [
    ("cbor.zig", "if (header.major != 3) return error.UnexpectedType;\n            return self.finishString(allocator, header);", "return self.finishString(allocator, header);"),
    ("cbor.zig", "if (header.major != 2) return error.UnexpectedType;\n            return self.finishString(allocator, header);", "return self.finishString(allocator, header);"),
    ("cbor.zig", "if (is_text and !bulk.validUtf8(raw)) return error.InvalidUtf8;\n                return .{ .bytes = raw, .allocated = false };", "return .{ .bytes = raw, .allocated = false };"),
    ("cbor.zig", "if (is_text and !bulk.validUtf8(raw)) return error.InvalidUtf8;\n                try assembled", "try assembled"),
    ("cbor.zig", "if (chunk.major != header.major or chunk.indefinite) return error.InvalidStringChunk;", "if (chunk.indefinite) return error.InvalidStringChunk;"),
    ("cbor.zig", "if (chunk.major != header.major or chunk.indefinite) return error.InvalidStringChunk;", "if (chunk.major != header.major) return error.InvalidStringChunk;"),
    ("cbor.zig", "                const header = try self.nextHead();\n                if (header.major != 6) return header;\n                if (header.value != self_described_tag) return error.UnexpectedTag;", "                const header = try self.nextHead();\n                if (header.major != 6) return header;"),
    ("cbor.zig", "if (major == 7 and value < 32) return error.InvalidSimpleValue;", "if (false) return error.InvalidSimpleValue;"),
    ("cbor.zig", "if (count > available) return error.UnexpectedEndOfInput;", "if (count > available and false) return error.UnexpectedEndOfInput;"),
    ("cbor.zig", "4 => {\n                    if (depth >= self.max_depth) return error.CborNestingTooDeep;", "4 => {"),
    ("cbor.zig", "5 => {\n                    if (depth >= self.max_depth) return error.CborNestingTooDeep;", "5 => {"),
    ("cbor.zig", "if (self.stack_len >= self.max_depth) return error.CborNestingTooDeep;", "if (self.stack_len >= self.stack.len) @panic(\"x\");"),
    ("cbor.zig", "while (header.major == 6) header = try self.nextHead();", "if (header.major == 6) header = try self.nextHead();"),
    ("cbor.zig", "if (self.keyOrder(own[previous], record) == .eq) return error.DuplicateField;", "if (self.keyOrder(own[previous], record) == .eq and false) return error.DuplicateField;"),
    ("cbor.zig", "if (own.len >= 2) {", "if (own.len >= 3) {"),
    ("cbor.zig", "if (a.kind != b.kind) return std.math.order(@backingInt(a.kind), @backingInt(b.kind));", "if (false) return .lt;"),
    ("cbor.zig", ".{ .kind = kind, .pooled = true, .a = offset, .b = token.bytes.len }", ".{ .kind = kind, .pooled = false, .a = offset, .b = token.bytes.len }"),
    ("cbor.zig", "self.keys.items.len = keys_base;", "self.keys.items.len = self.keys.items.len;"),
    ("cbor.zig", "try self.recordText(token);\n                    return .unknown;", "return .unknown;"),
    ("cbor.zig", "try self.recordText(token);\n            return token;", "return token;"),
    ("cbor.zig", "try self.keys.append(self.allocator, .{ .kind = if (header.major == 0) .uint else .nint, .a = header.value });\n                    return .unknown;", "return .unknown;"),
    ("cbor.zig", "const value: i128 = if (header.major == 0) header.value else -@as(i128, header.value) - 1;", "const value: i128 = if (header.major == 0) header.value else header.value;"),
    ("cbor.zig", "return if (wide == 0) 0 else @bitCast(wide);", "return @bitCast(wide);"),
    ("cbor.zig", "return (@as(u64, 0x7ff) << 52) | (significand << (52 - sig_bits));", "return 0x7ff8_0000_0000_0000;"),
    ("cbor.zig", "std.sort.pdq(CanonicalEntry, entries.items, Sort{ .bytes = self.key_bytes.items }, Sort.less);", ""),
    ("cbor.zig", "if (header.indefinite) {\n                        while (try self.moreItems()) : (count += 1) try self.canonicalItem();\n                    } else {", "if (false) {\n                    } else {"),
    ("cbor.zig", "try self.appendHead(6, header.value);\n                    try self.canonicalItem();", "try self.canonicalItem();"),
    ("cbor.zig", "try self.appendHead(header.major, token.bytes.len);", "_ = 0;"),
    ("cbor.zig", "len = writeHead(&buffer, 0, std.math.cast(u64, value)", "len = writeHead(&buffer, 1, std.math.cast(u64, value)"),
    ("cbor.zig", "if (effectiveDeterministic(cfg)) return .{ .default = .encoded_key, .required = true };", "if (effectiveDeterministic(cfg)) return .{ .default = .length_first, .required = true };"),
    ("typed.zig", ".float => error.UnexpectedType,\n    };\n}\n\nfn decodeFloatNumber", ".float => |n| std.math.cast(T, @as(i128, @intFromFloat(@round(n)))) orelse error.IntegerOverflow,\n    };\n}\n\nfn decodeFloatNumber"),
    ("typed.zig", "if (std.math.isInf(narrowed) and !std.math.isInf(wide)) return error.FloatOutOfRange;", "if (std.math.isInf(narrowed) and !std.math.isInf(wide) and false) return error.FloatOutOfRange;"),
    ("typed.zig", "            .bytes => try deserializer.readBytes(allocator),\n            else => error.UnexpectedType,", "            .bytes => try deserializer.readBytes(allocator),\n            .string => try deserializer.readString(allocator),\n            else => error.UnexpectedType,"),
    ("typed.zig", "return error.LengthMismatch;\n            }\n            return result;", "return result;\n            }\n            return result;"),
    ("typed.zig", "const key = (try nextUnionKey(deserializer, allocator, integer_keys)) orelse return error.LengthMismatch;", "const key = (try nextUnionKey(deserializer, allocator, integer_keys)) orelse return error.InvalidEnumTag;"),
    ("typed.zig", "if (FieldType != void and matches) {", "if (matches) {"),
    ("typed.zig", ".nullable => false,\n        .absent => value == null,", ".nullable => value == null,\n        .absent => value == null,"),
    ("typed.zig", ".absent => value == null,\n    };\n}", ".absent => false,\n    };\n}"),
    ("typed.zig", "if (try deserializer.peekKind() == .null) return error.UnexpectedType;", "_ = 0;"),
    ("typed.zig", "meta.effectiveOptionalPolicy(T, field_name, cfg) == .nullable) {\n                    return error.MissingField;", "meta.effectiveOptionalPolicy(T, field_name, cfg) == .nullable and false) {\n                    return error.MissingField;"),
    ("typed.zig", "if (comptime isNestedOptional(FieldType)) return value == null;", "if (comptime isNestedOptional(FieldType)) return false;"),
    ("typed.zig", ".integer => |expected| if (expected == actual) return i,", ".integer => |expected| if (expected == actual and false) return i,"),
    ("typed.zig", ".bytewise, .encoded_key => std.mem.lessThan(u8, a, b),", ".bytewise, .encoded_key => std.mem.lessThan(u8, b, a),"),
    ("typed.zig", ".length_first => if (a.len != b.len) a.len < b.len else std.mem.lessThan(u8, a, b),", ".length_first => std.mem.lessThan(u8, a, b),"),
    ("meta.zig", "if (comptime fieldOverrideHas(cfg, field_name, \"key\")) return .{ .integer = fieldOverride(cfg, field_name, \"key\") };", "if (comptime fieldOverrideHas(cfg, field_name, \"key\") and false) return .{ .integer = fieldOverride(cfg, field_name, \"key\") };"),
    ("meta.zig", "if (comptime fieldOverrideHas(cfg, field_name, \"optional\")) return fieldOverride(cfg, field_name, \"optional\");", "if (comptime fieldOverrideHas(cfg, field_name, \"optional\") and false) return fieldOverride(cfg, field_name, \"optional\");"),
    ("json.zig", "if (parsed.is_float) return error.UnexpectedType;\n\n            return switch (@typeInfo(T)) {\n                .comptime_int", "_ = 0;\n\n            return switch (@typeInfo(T)) {\n                .comptime_int"),
    ("json.zig", "if (std.math.isInf(value)) return error.FloatOutOfRange;", "_ = 0;"),
    ("json.zig", "if (!std.math.isFinite(value)) return error.NonFiniteFloat;", "_ = 0;"),
    ("json.zig", "if (!bulk.validUtf8(value)) return error.InvalidUtf8;\n            try writeEscapedString(writer, value);", "try writeEscapedString(writer, value);"),
    ("json.zig", ".bytes = try validUtf8(self.input[start .. self.index - 1]),", ".bytes = self.input[start .. self.index - 1],"),
    ("json.zig", "try builder.appendSlice(allocator, try validUtf8(self.input[start .. self.index - 1]));\n                    try self.appendEscape", "try builder.appendSlice(allocator, self.input[start .. self.index - 1]);\n                    try self.appendEscape"),
    ("json.zig", "try builder.appendSlice(allocator, try validUtf8(self.input[chunk_start .. self.index - 1]));\n                    return", "try builder.appendSlice(allocator, self.input[chunk_start .. self.index - 1]);\n                    return"),
    ("json.zig", "try builder.appendSlice(allocator, try validUtf8(self.input[chunk_start .. self.index - 1]));\n                    try self.appendEscape", "try builder.appendSlice(allocator, self.input[chunk_start .. self.index - 1]);\n                    try self.appendEscape"),
    ("json.zig", ".number => {\n                    try self.count();\n                    _ = try self.parser.parseNumberSlice();", ".number => {\n                    try self.count();\n                    _ = try self.readNumber();"),
    ("json.zig", "return .{ .float = try parseFiniteFloat(f64, parsed.slice) };", "return .{ .float = std.fmt.parseFloat(f64, parsed.slice) catch return error.InvalidNumber };"),
    ("msgpack.zig", ".integer => castIntValue(T, try self.decodeInteger(tag)),\n                else", ".integer => castIntValue(T, try self.decodeInteger(tag)),\n                .float => castIntValue(T, @as(i128, @intFromFloat(try self.decodeFloat(tag)))),\n                else"),
    ("msgpack.zig", ".float => try typed.narrowFloat(T, try self.decodeFloat(tag)),", ".float => @as(T, @floatCast(try self.decodeFloat(tag))),"),
    ("bson.zig", "self.pending_type orelse return if (self.stack_len == 0 and self.index == 0) .object else error.UnexpectedType;", "self.pending_type orelse return error.UnexpectedType;"),
    ("cbor.zig", "25 => (header.value >> 10) & 0x1f == 0x1f,", "25 => false,"),
    ("cbor.zig", "26 => (header.value >> 23) & 0xff == 0xff,", "26 => false,"),
    ("cbor.zig", "27 => (header.value >> 52) & 0x7ff == 0x7ff,", "27 => false,"),
    ("cbor.zig", "                7 => try self.checkFloat(header),", "                7 => {},"),
    ("cbor.zig", "            const header = try self.nextHead();\n            try self.checkFloat(header);\n            const record", "            const header = try self.nextHead();\n            const record"),
    ("cbor.zig", "            const header = try self.readHeader();\n            try self.checkFloat(header);", "            const header = try self.readHeader();"),
    ("typed.zig", ".integer => |number| try serializer.emitInteger(number),", ".integer => try serializer.emitString(\"x\"),"),
    ("typed.zig", ".integer => |number| _ = try serializer.beginStructFieldInteger(T, number, Payload),", ".integer => |number| _ = try serializer.beginStructFieldInteger(T, number + 1, Payload),"),
    ("typed.zig", ".integer => |key| key == number,", ".integer => |key| key == number or true,"),
    ("typed.zig", "if (!integer_keys) return error.UnexpectedType;", "_ = 0;"),
    ("typed.zig", "if (comptime meta.effectiveEnumRepr(T, cfg) == .integer) return error.UnexpectedType;", "if (comptime meta.effectiveEnumRepr(T, cfg) == .integer and false) return error.UnexpectedType;"),
    ("typed.zig", "if (comptime meta.effectiveEnumRepr(T, cfg) == .integer) {\n                try serializer.emitInteger", "if (false) {\n                try serializer.emitInteger"),
    ("meta.zig", "if (comptime cfgHasField(cfg, \"enum_repr\")) return @field(cfg, \"enum_repr\");", "if (comptime cfgHasField(cfg, \"enum_repr\") and false) return @field(cfg, \"enum_repr\");"),
    ("cbor.zig", "                else => return error.UnexpectedType,\n            }\n        }\n\n        /// The next key of a struct's map", "                else => return null,\n            }\n        }\n\n        /// The next key of a struct's map"),
    ("cbor.zig", "if (header.indefinite or !isShortestHead(header)) return error.NonDeterministicEncoding;", "if (header.indefinite and false or !isShortestHead(header)) return error.NonDeterministicEncoding;"),
    ("cbor.zig", "if (header.indefinite or !isShortestHead(header)) return error.NonDeterministicEncoding;", "if (header.indefinite or !isShortestHead(header) and false) return error.NonDeterministicEncoding;"),
    ("cbor.zig", "if (header.major == 6) return error.UnexpectedTag;", "if (header.major == 6 and false) return error.UnexpectedTag;"),
    ("cbor.zig", "if (header.major == 7 and !isPreferredFloat(header)) return error.NonDeterministicEncoding;", "if (header.major == 7 and !isPreferredFloat(header) and false) return error.NonDeterministicEncoding;"),
    ("cbor.zig", "24 => header.value >= 24,", "24 => true,"),
    ("cbor.zig", "25 => header.value > 0xff,", "25 => true,"),
    ("cbor.zig", "26 => header.value > 0xffff,", "26 => true,"),
    ("cbor.zig", "27 => header.value > 0xffff_ffff,", "27 => true,"),
    ("cbor.zig", "return !std.math.isNan(half) or header.value == 0x7e00;", "_ = half;\n            return true;"),
    ("cbor.zig", "if (!std.math.isFinite(single)) return false;", "if (false) return false;"),
    ("cbor.zig", "return @as(f32, half) != single;", "_ = half;\n            return true;"),
    ("cbor.zig", "if (!std.math.isFinite(double)) return false;", "if (false) return false;"),
    ("cbor.zig", "return @as(f64, single) != double;", "_ = single;\n            return true;"),
    ("cbor.zig", "if (std.mem.eql(u8, before, key)) return error.DuplicateField;", "if (std.mem.eql(u8, before, key) and false) return error.DuplicateField;"),
    ("cbor.zig", "if (!std.mem.lessThan(u8, before, key)) return error.NonDeterministicEncoding;", "if (!std.mem.lessThan(u8, before, key) and false) return error.NonDeterministicEncoding;"),
    ("cbor.zig", "try self.checkKeyOrder(&previous, start);\n            frame.prev_key_start", "previous = .{ 0, 0 };\n            frame.prev_key_start"),
    ("cbor.zig", "try self.orderFrameKey(start);\n            try self.recordText(token);\n            return token;", "_ = start;\n            try self.recordText(token);\n            return token;"),
    ("cbor.zig", "try self.orderFrameKey(start);\n                    try self.recordText(token);\n                    return .{ .text = token };", "try self.recordText(token);\n                    return .{ .text = token };"),
    ("cbor.zig", "0, 1 => {\n                    try self.orderFrameKey(start);", "0, 1 => {"),
    ("cbor.zig", "try self.checkKeyOrder(&previous, key_start);\n                            try self.skipItem(depth + 1);\n                        }\n                    }\n", "previous = .{ 0, 0 };\n                            _ = key_start;\n                            try self.skipItem(depth + 1);\n                        }\n                    }\n"),
    ("cbor.zig", "if (self.items > self.max_items) return error.TooManyItems;", "if (self.items > self.max_items and false) return error.TooManyItems;"),
    ("cbor.zig", "if (header.value > self.max_string_len) return error.StringTooLong;\n                const raw", "const raw"),
    ("cbor.zig", "if (header.value > self.max_string_len) return error.StringTooLong;\n                        const raw", "const raw"),
    ("cbor.zig", "if (chunk.value > self.max_string_len - assembled.items.len) return error.StringTooLong;", "if (chunk.value > self.max_string_len) return error.StringTooLong;"),
    ("cbor.zig", "self.items -= 1;\n                    try self.skipItem(depth);", "try self.skipItem(depth);"),
    ("cbor.zig", "self.items -= 1;\n                    try self.recordKeyItem(self.stack_len);", "try self.recordKeyItem(self.stack_len);"),
    ("cbor.zig", "if (self.stack_len >= self.max_depth) return error.CborNestingTooDeep;", "if (self.stack_len >= self.stack.len) return error.CborNestingTooDeep;"),
    ("cbor.zig", "if (depth >= self.max_depth) return error.CborNestingTooDeep;", "if (depth >= max_nesting) return error.CborNestingTooDeep;"),
    ("cbor.zig", "if (comptime std.mem.eql(u8, name, \"max_depth\")) return @min(value, max_nesting);", "_ = 0;"),
    ("json.zig", "pub fn readInt(self: *Self, comptime T: type) !T {\n            try self.count();", "pub fn readInt(self: *Self, comptime T: type) !T {"),
    ("json.zig", "pub fn readString(self: *Self, allocator: Allocator) !StringToken {\n            try self.count();", "pub fn readString(self: *Self, allocator: Allocator) !StringToken {"),
    ("json.zig", "pub fn beginArray(self: *Self) !void {\n            try self.count();", "pub fn beginArray(self: *Self) !void {"),
    ("json.zig", "try self.count();\n            const key = try self.parser.parseStringToken(allocator);", "const key = try self.parser.parseStringToken(allocator);"),
    ("json.zig", ".number => {\n                    try self.count();", ".number => {"),
    ("json.zig", "if (self.items > self.max_items) return error.TooManyItems;", "if (self.items > self.max_items and false) return error.TooManyItems;"),
    ("json.zig", "if (self.stack_len >= self.max_depth) return error.JsonNestingTooDeep;", "if (self.stack_len >= self.stack.len) return error.JsonNestingTooDeep;"),
    ("json.zig", "if (token.bytes.len > self.max_string_len) {", "if (token.bytes.len > self.max_string_len and false) {"),
    ("cbor.zig", "            try self.skipItem(self.stack_len);\n            return .{ .bytes = self.input[start..self.index], .allocated = false };", "            if (self.index > self.input.len) try self.skipItem(self.stack_len);\n            return .{ .bytes = self.input[start..self.index], .allocated = false };"),
    ("cbor.zig", "return .{ .bytes = self.input[start..self.index], .allocated = false };", "return .{ .bytes = self.input[start..start], .allocated = false };"),
    ("json.zig", "            try self.skipValue(allocator);\n            return .{ .bytes = self.input[start..self.parser.index], .allocated = false };", "            if (start > self.input.len) try self.skipValue(allocator);\n            return .{ .bytes = self.input[start..self.parser.index], .allocated = false };"),
    ("json.zig", "            self.parser.skipWhitespace();\n            const start = self.parser.index;", "            const start = self.parser.index;"),
    ("typed.zig", "    return allocator.dupe(u8, token.bytes);\n}\n\nfn deserializeStruct(", "    return token.bytes;\n}\n\nfn deserializeStruct("),
    ("typed.zig", "if (@hasDecl(DeserializerType, \"borrowStrings\") and deserializer.borrowStrings()) return token.bytes;\n    return allocator.dupe(u8, token.bytes);\n}\n\nfn deserializeStruct(", "if (@hasDecl(DeserializerType, \"borrowStrings\") and deserializer.borrowStrings() and false) return token.bytes;\n    return allocator.dupe(u8, token.bytes);\n}\n\nfn deserializeStruct("),
    ("typed.zig", "if (len < bounds.min_len or len > bounds.max_len) return error.LengthOutOfBounds;", "if (len > bounds.max_len) return error.LengthOutOfBounds;"),
    ("typed.zig", "if (len < bounds.min_len or len > bounds.max_len) return error.LengthOutOfBounds;", "if (len < bounds.min_len) return error.LengthOutOfBounds;"),
    ("typed.zig", "if (bounds.min) |min| if (value < min) return error.ValueOutOfRange;", "_ = bounds.min;"),
    ("typed.zig", "if (bounds.max) |max| if (value > max) return error.ValueOutOfRange;", "_ = bounds.max;"),
    ("typed.zig", "if (try readNullIfPresent(deserializer)) return null;", "if (false) return null;"),
    ("typed.zig", "if (items.items.len >= bounds.max_len) return error.LengthOutOfBounds;", "_ = 0;"),
    ("typed.zig", "            try checkLength(bounds, items.items.len);\n", "            _ = 0;\n"),
    ("typed.zig", "                try checkLength(bounds, len);\n                const items = try allocator.alloc", "                const items = try allocator.alloc"),
    ("typed.zig", "                try checkLength(bounds, token.bytes.len);\n                // Aliased", "                // Aliased"),
    ("typed.zig", "    errdefer token.deinit(allocator);\n    try checkLength(bounds, token.bytes.len);\n", "    errdefer token.deinit(allocator);\n    _ = bounds;\n"),
    ("typed.zig", "    try checkLength(bounds, token.bytes.len);\n    if (@hasDecl(DeserializerType, \"borrowStrings\")", "    _ = bounds;\n    if (@hasDecl(DeserializerType, \"borrowStrings\")"),
    ("typed.zig", "if (comptime @hasDecl(T, \"check\")) try result.check();", "_ = result;"),
    ("typed.zig", "        try checkStruct(T, &result);\n        return result;", "        return result;"),
    ("typed.zig", "        try checkStruct(T, &ordered_result);\n", "        _ = 0;\n"),
    ("meta.zig", "if (fieldOverrideHas(cfg, field_name, option)) break :blk fieldOverride(cfg, field_name, option);", "if (fieldOverrideHas(cfg, field_name, option) and false) break :blk fieldOverride(cfg, field_name, option);"),
    ("meta.zig", "if (@hasDecl(T, \"serde\") and fieldOverrideHas(T.serde, field_name, option)) break :blk fieldOverride(T.serde, field_name, option);", "if (@hasDecl(T, \"serde\") and fieldOverrideHas(T.serde, field_name, option) and false) break :blk fieldOverride(T.serde, field_name, option);"),
    ("typed.zig", "        if (comptime extras_name != null) try storeExtras(T, info, allocator, deserializer, extras_mark, &result, &seen);\n        try fillMissingFields(T, info, cfg, &result, &seen);\n        try checkStruct(T, &result);\n        return result;", "        try fillMissingFields(T, info, cfg, &result, &seen);\n        try checkStruct(T, &result);\n        return result;"),
    ("typed.zig", "    if (comptime extras_name != null) try storeExtras(T, info, allocator, deserializer, extras_mark, &result, &seen);\n    try fillMissingFields(T, info, cfg, &result, &seen);\n    try checkStruct(T, &result);\n    return result;\n}", "    try fillMissingFields(T, info, cfg, &result, &seen);\n    try checkStruct(T, &result);\n    return result;\n}"),
    ("typed.zig", "        if (comptime meta.isExtrasField(T, field_name)) continue;\n        switch (comptime meta.effectiveFieldKey(T, field_name, cfg)) {\n            .text => |expected|", "        switch (comptime meta.effectiveFieldKey(T, field_name, cfg)) {\n            .text => |expected|"),
    ("typed.zig", "                        if (comptime meta.isExtrasField(T, field_name)) continue;\n                        if (SerializerType.includeStructField(T, field_type, pass)) {\n                            if (!omitField", "                        if (SerializerType.includeStructField(T, field_type, pass)) {\n                            if (!omitField"),
    ("typed.zig", "                    if (comptime meta.isExtrasField(T, field_name)) continue;\n                    if (SerializerType.includeStructField(T, field_type, pass)) {\n                        const field_value", "                    if (SerializerType.includeStructField(T, field_type, pass)) {\n                        const field_value"),
    ("typed.zig", "                                try serializer.emitExtrasBefore(&extras, comptime Format.encodeKey(meta.effectiveFieldKey(T, field_name, cfg)));", "                                _ = &extras;"),
    ("typed.zig", "            if (comptime extras_name != null) try serializer.finishExtras(&extras, comptime declaredKeys(T, info, cfg));", "            _ = &extras;"),
    ("typed.zig", "var field_count: usize = if (comptime extras_name != null) try serializer.extrasCount(extras_bytes) else 0;", "var field_count: usize = 0;"),
    ("typed.zig", "                        const key = try deserializer.unknownKey(allocator);\n                        defer key.deinit(allocator);\n                        try deserializer.captureExtra(allocator, key.bytes);", "                        try deserializer.skipValue(allocator);"),
    ("cbor.zig", "                    .eq => return error.DuplicateField,", "                    .eq => {},"),
    ("cbor.zig", "                    .gt => return,", "                    .gt => {},"),
    ("cbor.zig", "if (std.mem.eql(u8, key, comptime encodeKey(member))) return error.DuplicateField;", "if (std.mem.eql(u8, key, comptime encodeKey(member)) and false) return error.DuplicateField;"),
    ("cbor.zig", "            if (x.len != y.len) return x.len < y.len;\n            return std.mem.lessThan(u8, x, y);", "            return std.mem.lessThan(u8, x, y);"),
    ("cbor.zig", "                self.extras.items.len = mark;", "                self.extras.items.len = self.extras.items.len;"),
    ("cbor.zig", "            const header = try parseHeader(self.input, &self.index);\n            if (header.major != 3) return error.UnexpectedType;\n            return self.finishString(allocator, header);", "            const header = try parseHeader(self.input, &self.index);\n            return self.finishString(allocator, header);"),
    ("cbor.zig", "            if (result == .unknown) self.last_key = .{ start, self.index };", "            _ = 0;"),
    ("cbor.zig", "if (header.major != 5 or header.indefinite) return error.UnexpectedType;\n    return .{ .bytes = bytes, .pos = index, .remaining = header.value };", "if (header.major != 5) return error.UnexpectedType;\n    return .{ .bytes = bytes, .pos = index, .remaining = header.value };"),
    ("cbor.zig", "if (header.major != 5 or header.indefinite) return error.UnexpectedType;\n    return .{ .bytes = bytes, .pos = index, .remaining = header.value };", "if (header.indefinite) return error.UnexpectedType;\n    return .{ .bytes = bytes, .pos = index, .remaining = header.value };"),
    ("json.zig", ".text => |name| if (rawKeyIs(key, name)) return error.DuplicateField,", ".text => |name| if (rawKeyIs(key, name) and false) return error.DuplicateField,"),
    ("json.zig", "if (!container.first) try self.writer.writeByte(',') else container.first = false;", "container.first = false;"),
    ("json.zig", "if (index != 0) try out.writer.writeByte(',');", "_ = index;"),
    ("json.zig", "try writeEscapedString(&out.writer, self.extra_keys.items[entry.key_start..][0..entry.key_len]);", "try out.writer.writeAll(self.extra_keys.items[entry.key_start..][0..entry.key_len]);"),
    ("json.zig", "'u' => {\n                    var scan: Parser", "'u' => {\n                    if (name.len >= 0) return false;\n                    var scan: Parser"),
    ("json.zig", "if (n + piece.len > name.len or !std.mem.eql(u8, piece, name[n..][0..piece.len])) return false;", "if (n + piece.len > name.len) return false;"),
    ("json.zig", "    return n == name.len;\n}", "    return true;\n}"),
    ("json.zig", "if (bytes.len == 0) return .{ .bytes = bytes, .pos = 0 };", "_ = 0;"),
    ("cbor.zig", "if (!try d.nextArrayItem()) {\n                        self.done = d.stack_len == self.base;\n                        return .array_end;", "if (!try d.nextArrayItem()) {\n                        return .array_end;"),
    ("cbor.zig", "if (try d.beginObjectEntry()) {\n                        self.done = d.stack_len == self.base;\n                        return .map_end;", "if (try d.beginObjectEntry()) {\n                        return .map_end;"),
    ("cbor.zig", "const event = try self.valueEvent();\n                if (d.stack_len == self.base) self.done = true;\n                return event;", "const event = try self.valueEvent();\n                return event;"),
    ("cbor.zig", "                    self.want_value[depth] = true;\n                    return try self.keyEvent();", "                    return try self.keyEvent();"),
    ("cbor.zig", "if (kind == .array or kind == .object) return error.UnexpectedType;\n            const start = d.index;", "const start = d.index;"),
    ("cbor.zig", "            d.index = start;\n            d.items -= 1;\n            const event", "            d.index = start;\n            const event"),
    ("cbor.zig", "            std.debug.assert(d.index == end);\n            try d.orderFrameKey(start);", "            std.debug.assert(d.index == end);"),
    ("cbor.zig", "pub fn next(self: *Self) !?typed.Event {\n            self.release();\n            const d = self.d;", "pub fn next(self: *Self) !?typed.Event {\n            const d = self.d;"),
    ("cbor.zig", "            if (token.allocated) self.scratch = @constCast(token.bytes);\n            return token.bytes;", "            _ = self;\n            return token.bytes;"),
    ("cbor.zig", "            if (!self.done) return error.UnexpectedEndOfInput;\n            try self.d.finish();", "            try self.d.finish();"),
    ("cbor.zig", "return .{ .map_begin = if (frame.indefinite) null else frame.remaining };", "return .{ .map_begin = null };"),
    ("json.zig", "const key = (try d.nextObjectField(self.allocator)) orelse {\n                        self.done = d.stack_len == self.base;\n                        return .map_end;", "const key = (try d.nextObjectField(self.allocator)) orelse {\n                        return .map_end;"),
    ("json.zig", "                    self.want_value[depth] = true;\n                    return .{ .text = self.keep(key) };", "                    return .{ .text = self.keep(key) };"),
    ("json.zig", "const event = try self.valueEvent();\n                if (d.stack_len == self.base) self.done = true;\n                return event;", "const event = try self.valueEvent();\n                return event;"),
    ("json.zig", "if (!try d.nextArrayItem()) {\n                        self.done = d.stack_len == self.base;\n                        return .array_end;", "if (!try d.nextArrayItem()) {\n                        return .array_end;"),
    ("json.zig", "        pub fn next(self: *Self) !?typed.Event {\n            self.release();", "        pub fn next(self: *Self) !?typed.Event {"),
    ("json.zig", "            if (!self.done) return error.UnexpectedEndOfInput;\n            try self.d.finish();", "            try self.d.finish();"),
    ("cbor.zig", "            std.sort.pdq(Entry, entries, Order{ .body = body }, Order.less);\n", "            _ = Order;\n"),
    ("cbor.zig", "body[entry.key_start..entry.key_end])) return error.DuplicateField;", "body[entry.key_start..entry.key_end]) and false) return error.DuplicateField;"),
    ("cbor.zig", "        if (!frame.expect_key) return error.UnbalancedContainers;", "        _ = 0;"),
    ("cbor.zig", "    pub fn finish(self: *ValueWriter) !void {\n        if (self.depth != 0) return error.UnbalancedContainers;", "    pub fn finish(self: *ValueWriter) !void {\n        if (self.depth != 0 and false) return error.UnbalancedContainers;"),
    ("cbor.zig", "if (self.depth == 0 or self.frames[self.depth - 1].kind != kind) return error.UnbalancedContainers;", "if (self.depth == 0) return error.UnbalancedContainers;"),
    ("cbor.zig", "if (self.deterministic) try writePreferredFloat(self.sink(), value) else try encodeFloat(self.sink(), value);", "try encodeFloat(self.sink(), value);"),
    ("cbor.zig", "if (frame.kind == .object and frame.expect_key) frame.key_start = frame.buf.written().len;", "_ = frame;"),
    ("cbor.zig", "try writeMajorValue(out, 5, frame.count);", "try writeMajorValue(out, 5, frame.count + 1);"),
    ("cbor.zig", "        if (self.depth >= max_nesting) return error.CborNestingTooDeep;\n        self.frames[self.depth] =", "        self.frames[self.depth] ="),
    ("json.zig", "            std.sort.pdq(Entry, entries, Order{ .keys = keys }, Order.less);\n", "            _ = Order;\n"),
    ("json.zig", "                    if (x.len != y.len) return x.len < y.len;\n                    return std.mem.lessThan(u8, x, y);\n                }\n            };\n            std.sort.pdq(Entry, entries, Order{ .keys = keys }", "                    return std.mem.lessThan(u8, x, y);\n                }\n            };\n            std.sort.pdq(Entry, entries, Order{ .keys = keys }"),
    ("json.zig", "keys[entry.key_start..][0..entry.key_len])) return error.DuplicateField;", "keys[entry.key_start..][0..entry.key_len]) and false) return error.DuplicateField;"),
    ("json.zig", "            if (index != 0) try out.writeByte(',');\n            try out.writeAll(body[entry.start..entry.end]);", "            try out.writeAll(body[entry.start..entry.end]);"),
    ("json.zig", "                if (!frame.first) try self.sink().writeByte(',');", "                _ = 0;"),
    ("json.zig", "            .object => if (frame.expect_key) return error.UnexpectedType,", "            .object => {},"),
    ("json.zig", "    pub fn writeFloat(self: *ValueWriter, value: f64) !void {\n        if (!std.math.isFinite(value)) return error.NonFiniteFloat;", "    pub fn writeFloat(self: *ValueWriter, value: f64) !void {"),
    ("json.zig", "    fn push(self: *ValueWriter, kind: ContainerKind) !void {\n        if (self.depth >= self.frames.len) return error.JsonNestingTooDeep;", "    fn push(self: *ValueWriter, kind: ContainerKind) !void {"),
    ("json.zig", "                try writeEscapedString(out, value);\n                try out.writeByte(':');", "                try out.writeAll(value);\n                try out.writeByte(':');"),
    ("json.zig", "    pub fn finish(self: *ValueWriter) !void {\n        if (self.depth != 0) return error.UnbalancedContainers;", "    pub fn finish(self: *ValueWriter) !void {\n        if (self.depth != 0 and false) return error.UnbalancedContainers;"),
    ("json.zig", "    pub fn writeFloat(self: *Encoder, value: f64) !void {\n        if (!std.math.isFinite(value)) return error.NonFiniteFloat;", "    pub fn writeFloat(self: *Encoder, value: f64) !void {"),
    ("typed.zig", "        try value.zerdeEncode(&encoder);\n        return;", "        _ = &encoder;\n        return;"),
    ("typed.zig", "        if (!reader.done) return error.HookIncomplete;", "        _ = 0;"),
    ("typed.zig", "        var reader = deserializer.pullView(allocator);\n        defer reader.deinit();", "        var reader = deserializer.pullView(allocator);"),
    ("typed.zig", "        if (!borrowed_strings) value.zerdeFree(allocator);", "        _ = value;"),
    ("cbor.zig", "    pub fn beginArray(self: *Encoder, len: usize) !void {\n        try writeMajorValue(self.writer, 4, len);", "    pub fn beginArray(self: *Encoder, len: usize) !void {\n        try writeMajorValue(self.writer, 4, len + 1);"),
    ("cbor.zig", "    pub fn beginMap(self: *Encoder, len: usize) !void {\n        try writeMajorValue(self.writer, 5, len);", "    pub fn beginMap(self: *Encoder, len: usize) !void {\n        try writeMajorValue(self.writer, 5, len + 1);"),
    ("cbor.zig", "            return .{ .d = d, .owns = false, .base = d.stack_len, .allocator = allocator };", "            return .{ .d = d, .owns = false, .base = 0, .allocator = allocator };"),
    ("cbor.zig", "            return .{ .d = d, .owns = false, .base = d.stack_len, .allocator = allocator };", "            return .{ .d = d, .owns = true, .base = d.stack_len, .allocator = allocator };"),
    ("json.zig", "            return .{ .d = d, .owns = false, .base = d.stack_len, .allocator = allocator };", "            return .{ .d = d, .owns = false, .base = 0, .allocator = allocator };"),
    ("json.zig", "                if (!frame.first) try self.writer.writeByte(',');\n                frame.first = false;\n                try writeEscapedString(self.writer, value);", "                frame.first = false;\n                try writeEscapedString(self.writer, value);"),
    ("json.zig", "                if (!frame.first) try self.writer.writeByte(',');\n                frame.first = false;\n            },\n            .object => if (frame.expect_key) return error.UnexpectedType,\n        }\n    }\n\n    fn afterValue(self: *Encoder) void {", "                frame.first = false;\n            },\n            .object => if (frame.expect_key) return error.UnexpectedType,\n        }\n    }\n\n    fn afterValue(self: *Encoder) void {"),
    ("json.zig", "            .object => if (frame.expect_key) return error.UnexpectedType,\n        }\n    }\n\n    fn afterValue(self: *Encoder) void {", "            .object => {},\n        }\n    }\n\n    fn afterValue(self: *Encoder) void {"),
    ("json.zig", "        if (frame.kind == .object) frame.expect_key = true;\n    }\n\n    fn push(self: *Encoder", "        _ = frame;\n    }\n\n    fn push(self: *Encoder"),
    ("reflect.zig", "if (comptime hasAnyHook(T)) return .hook;", "if (comptime hasAnyHook(T) and false) return .hook;"),
    ("reflect.zig", "        .array => |info| if (info.child == u8) .byte_array else .array,", "        .array => .array,"),
    ("reflect.zig", "            .slice => if (info.child == u8) .text else .list,", "            .slice => .list,"),
    ("reflect.zig", "                .wire = meta.effectiveFieldKey(T, name, cfg),\n                .type = FieldType,", "                .wire = .{ .text = name },\n                .type = FieldType,"),
    ("reflect.zig", "                .bounds = meta.effectiveBounds(T, name, cfg),", "                .bounds = .{},"),
    ("reflect.zig", "                .optional = meta.effectiveOptionalPolicy(T, name, cfg),", "                .optional = .lenient,"),
    ("reflect.zig", "                .has_default = attrs.defaultValue(FieldType) != null,", "                .has_default = false,"),
    ("reflect.zig", "                .extras = meta.isExtrasField(T, name),", "                .extras = false,"),
    ("reflect.zig", "                    .optional => |o| @typeInfo(o.child) == .optional,", "                    .optional => false,"),
    ("reflect.zig", "            if (meta.isExtrasField(T, info.field_names[index])) continue;", "            _ = 0;"),
    ("reflect.zig", "                .wire = meta.effectiveFieldKey(T, name, cfg),\n                .type = PayloadType,", "                .wire = .{ .text = name },\n                .type = PayloadType,"),
    ("reflect.zig", "return .{ .repr = meta.effectiveEnumRepr(T, cfg), .values = &final };", "return .{ .repr = .name, .values = &final };"),
    ("reflect.zig", "        const order = typed.structFieldOrder(T, Format, info, cfg, policy);", "        const order = typed.structFieldOrder(T, Format, info, cfg, meta.FieldOrderPolicy{});"),
    ("bulk.zig", "if (hasZero(word ^ (ones * '\"')) or hasZero(word ^ (ones * '\\\\')) or hasBelow(word, 0x20)) break;", "if (hasZero(word ^ (ones * '\\\\')) or hasBelow(word, 0x20)) break;"),
    ("bulk.zig", "if (hasZero(word ^ (ones * '\"')) or hasZero(word ^ (ones * '\\\\')) or hasBelow(word, 0x20)) break;", "if (hasZero(word ^ (ones * '\"')) or hasBelow(word, 0x20)) break;"),
    ("bulk.zig", "if (hasZero(word ^ (ones * '\"')) or hasZero(word ^ (ones * '\\\\')) or hasBelow(word, 0x20)) break;", "if (hasZero(word ^ (ones * '\"')) or hasZero(word ^ (ones * '\\\\'))) break;"),
    ("bulk.zig", "        if (c == '\"' or c == '\\\\' or c < 0x20) return i;\n    }\n    return bytes.len;", "        if (c == '\"' or c == '\\\\') return i;\n    }\n    return bytes.len;"),
    ("bulk.zig", "        if (end + 8 > bytes.len) end = bytes.len;\n", "        _ = 0;\n"),
    ("bulk.zig", "        if (!std.unicode.utf8ValidateSlice(bytes[i..end])) return false;\n        i = end;", "        i = end;"),
    ("bulk.zig", "        if (at > start) try writer.writeAll(bytes[start..at]);", "        _ = 0;"),
    ("bulk.zig", "            0x08 => try writer.writeAll(\"\\\\b\"),", "            0x08 => try writer.writeAll(\"\\\\f\"),"),
    ("bulk.zig", "hex[c >> 4], hex[c & 0xf] }", "hex[c & 0xf], hex[c >> 4] }"),
    ("bulk.zig", "        start = at + 1;\n    }\n}", "        start = at;\n    }\n}"),
    ("json.zig", "    fn push(self: *Encoder, kind: ContainerKind) !void {\n        if (self.depth >= self.frames.len) return error.JsonNestingTooDeep;", "    fn push(self: *Encoder, kind: ContainerKind) !void {"),
    ("typed.zig", "            freeTypedPartial(T, allocator, decoded, @hasDecl(DeserializerType, \"borrowStrings\") and deserializer.borrowStrings());\n", "            _ = 0;\n"),
    ("typed.zig", "                errdefer freeTypedPartial(info.child, allocator, item, borrowed_strings);\n                try items.append(allocator, item);", "                try items.append(allocator, item);"),
    ("typed.zig", "if (comptime hasMax(bounds) and @hasDecl(DeserializerType, \"readStringMax\"))", "if (comptime false and @hasDecl(DeserializerType, \"readStringMax\"))"),
    ("typed.zig", "if (comptime hasMax(bounds) and @hasDecl(DeserializerType, \"readByteTokenMax\"))", "if (comptime false and @hasDecl(DeserializerType, \"readByteTokenMax\"))"),
    ("cbor.zig", "if (max < saved) self.max_string_len = max;\n            return self.readString(allocator)", "return self.readString(allocator)"),
    ("cbor.zig", "if (err == error.StringTooLong and max < saved) error.LengthOutOfBounds else err;\n        }\n\n        /// `readByteToken`", "err;\n        }\n\n        /// `readByteToken`"),
]
# Not reproducible by a source mutation (equivalent or structural): the BSON `readBytes` text arm
# (covered by typed.readByteToken), the `supports_unions` and `supports_integer_keys` compile gates,
# and the unreachable else branch of JSON parseStringToken.


def run(index):
    name, old, new = MUTANTS[index]
    path = os.path.join("src", name)
    text = open(path).read()
    if old not in text:
        return f"{index} {name}: PATTERN NOT FOUND"
    open(path, "w").write(text.replace(old, new, 1))
    cmd = ["zig", "build", "test"]
    if os.environ.get("MUTANT_LOCK"):
        cmd = ["flock", os.environ["MUTANT_LOCK"]] + cmd
    # A mutant can loop forever. A run that does not end in two minutes is a kill, and its whole
    # process group is ended, test binary included.
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=120)
        returncode = process.returncode
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        output, returncode = "", 124
    # Every mutant builds new objects, and the cache can fill the disk: keep it under bounds.
    if shutil.disk_usage(".").free < 60 * 1024**3:
        shutil.rmtree(".zig-cache", ignore_errors=True)
    failed = sorted(set(re.findall(r"error: '(.+?)' failed", output)))
    verdict = "KILLED" if returncode != 0 else "SURVIVED"
    detail = failed[:2] or (("timeout" if returncode == 124 else "compile error or crash") if returncode != 0 else "")
    return f"{index} {name}: {verdict} {detail} | {old[:56]!r}".replace("\n", " ")


def main():
    backup = "/tmp/zerde-mutants-src"
    shutil.rmtree(backup, ignore_errors=True)
    shutil.copytree("src", backup)
    indexes = [int(a) for a in sys.argv[1:]] or range(len(MUTANTS))
    try:
        for index in indexes:
            try:
                print(run(index), flush=True)
            finally:
                for name in os.listdir(backup):
                    shutil.copy(os.path.join(backup, name), os.path.join("src", name))
    finally:
        shutil.rmtree(backup, ignore_errors=True)


if __name__ == "__main__":
    main()
