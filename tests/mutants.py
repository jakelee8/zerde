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
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

# (file, original, mutated)
MUTANTS = [
    # CBOR reader: string types, UTF-8, chunks, tags, simple values, bounds
    ("cbor.zig", "if (header.major != 3) return error.UnexpectedType;\n            return self.finishString(allocator, header);", "return self.finishString(allocator, header);"),
    ("cbor.zig", "if (header.major != 2) return error.UnexpectedType;\n            return self.finishString(allocator, header);", "return self.finishString(allocator, header);"),
    ("cbor.zig", "if (is_text and !std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;\n                return .{ .bytes = raw, .allocated = false };", "return .{ .bytes = raw, .allocated = false };"),
    ("cbor.zig", "if (is_text and !std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;\n                try assembled", "try assembled"),
    ("cbor.zig", "if (chunk.major != header.major or chunk.indefinite) return error.InvalidStringChunk;", "if (chunk.indefinite) return error.InvalidStringChunk;"),
    ("cbor.zig", "if (chunk.major != header.major or chunk.indefinite) return error.InvalidStringChunk;", "if (chunk.major != header.major) return error.InvalidStringChunk;"),
    ("cbor.zig", "if (header.value != self_described_tag) return error.UnexpectedTag;", "if (false) return error.UnexpectedTag;"),
    ("cbor.zig", "if (major == 7 and value < 32) return error.InvalidSimpleValue;", "if (false) return error.InvalidSimpleValue;"),
    ("cbor.zig", "if (count > available) return error.UnexpectedEndOfInput;", "if (count > available and false) return error.UnexpectedEndOfInput;"),
    ("cbor.zig", "4 => {\n                    if (depth >= max_nesting) return error.CborNestingTooDeep;", "4 => {"),
    ("cbor.zig", "5 => {\n                    if (depth >= max_nesting) return error.CborNestingTooDeep;", "5 => {"),
    ("cbor.zig", "if (self.stack_len == self.stack.len) return error.CborNestingTooDeep;", "if (self.stack_len == self.stack.len) @panic(\"x\");"),
    ("cbor.zig", "while (header.major == 6) header = try parseHeader(self.input, &self.index);", "if (header.major == 6) header = try parseHeader(self.input, &self.index);"),
    # CBOR duplicate keys
    ("cbor.zig", "if (self.keyOrder(own[previous], record) == .eq) return error.DuplicateField;", "if (self.keyOrder(own[previous], record) == .eq and false) return error.DuplicateField;"),
    ("cbor.zig", "if (own.len >= 2) {", "if (own.len >= 3) {"),
    ("cbor.zig", "if (a.kind != b.kind) return std.math.order(@backingInt(a.kind), @backingInt(b.kind));", "if (false) return .lt;"),
    ("cbor.zig", ".{ .kind = kind, .pooled = true, .a = offset, .b = token.bytes.len }", ".{ .kind = kind, .pooled = false, .a = offset, .b = token.bytes.len }"),
    ("cbor.zig", "self.keys.items.len = keys_base;", "self.keys.items.len = self.keys.items.len;"),
    ("cbor.zig", "try self.recordText(token);\n                    return .unknown;", "return .unknown;"),
    ("cbor.zig", "try self.recordText(token);\n            return token;", "return token;"),
    ("cbor.zig", "try self.keys.append(self.allocator, .{ .kind = if (header.major == 0) .uint else .nint, .a = header.value });\n                    return .unknown;", "return .unknown;"),
    ("cbor.zig", "const value: i128 = if (header.major == 0) header.value else -@as(i128, header.value) - 1;", "const value: i128 = if (header.major == 0) header.value else header.value;"),
    # CBOR key equality (RFC 8949 section 5.6.1)
    ("cbor.zig", "return if (wide == 0) 0 else @bitCast(wide);", "return @bitCast(wide);"),
    ("cbor.zig", "return (@as(u64, 0x7ff) << 52) | (significand << (52 - sig_bits));", "return 0x7ff8_0000_0000_0000;"),
    ("cbor.zig", "std.sort.pdq(CanonicalEntry, entries.items, Sort{ .bytes = self.key_bytes.items }, Sort.less);", ""),
    ("cbor.zig", "if (header.indefinite) {\n                        while (try self.moreItems()) : (count += 1) try self.canonicalItem();\n                    } else {", "if (false) {\n                    } else {"),
    ("cbor.zig", "try self.appendHead(6, header.value);\n                    try self.canonicalItem();", "try self.canonicalItem();"),
    ("cbor.zig", "try self.appendHead(header.major, token.bytes.len);", "_ = 0;"),
    # CBOR integer keys and key order
    ("cbor.zig", "len = writeHead(&buffer, 0, std.math.cast(u64, value)", "len = writeHead(&buffer, 1, std.math.cast(u64, value)"),
    ("cbor.zig", "if (effectiveDeterministic(cfg)) return .{ .default = .encoded_key, .required = true };", "if (effectiveDeterministic(cfg)) return .{ .default = .length_first, .required = true };"),
    # typed layer
    ("typed.zig", ".float => error.UnexpectedType,\n    };\n}\n\nfn decodeFloatNumber", ".float => |n| std.math.cast(T, @as(i128, @intFromFloat(@round(n)))) orelse error.IntegerOverflow,\n    };\n}\n\nfn decodeFloatNumber"),
    ("typed.zig", "if (std.math.isInf(narrowed) and !std.math.isInf(wide)) return error.FloatOutOfRange;", "if (std.math.isInf(narrowed) and !std.math.isInf(wide) and false) return error.FloatOutOfRange;"),
    ("typed.zig", "            .bytes => try deserializer.readBytes(allocator),\n            else => error.UnexpectedType,", "            .bytes => try deserializer.readBytes(allocator),\n            .string => try deserializer.readString(allocator),\n            else => error.UnexpectedType,"),
    ("typed.zig", "return error.LengthMismatch;\n            }\n            return result;", "return result;\n            }\n            return result;"),
    ("typed.zig", "const key = (try deserializer.nextObjectField(allocator)) orelse return error.LengthMismatch;", "const key = (try deserializer.nextObjectField(allocator)) orelse return error.InvalidEnumTag;"),
    ("typed.zig", "if (FieldType != void and std.mem.eql(u8, key.bytes,", "if (std.mem.eql(u8, key.bytes,"),
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
    # JSON
    ("json.zig", "if (parsed.is_float) return error.UnexpectedType;\n\n            return switch (@typeInfo(T)) {\n                .comptime_int", "_ = 0;\n\n            return switch (@typeInfo(T)) {\n                .comptime_int"),
    ("json.zig", "if (std.math.isInf(value)) return error.FloatOutOfRange;", "_ = 0;"),
    ("json.zig", "if (!std.math.isFinite(value)) return error.NonFiniteFloat;", "_ = 0;"),
    ("json.zig", "if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;\n                    try writeEscapedString", "try writeEscapedString"),
    ("json.zig", ".bytes = try validUtf8(self.input[start .. self.index - 1]),", ".bytes = self.input[start .. self.index - 1],"),
    ("json.zig", "try builder.appendSlice(allocator, try validUtf8(self.input[start .. self.index - 1]));\n                    try self.appendEscape", "try builder.appendSlice(allocator, self.input[start .. self.index - 1]);\n                    try self.appendEscape"),
    ("json.zig", "try builder.appendSlice(allocator, try validUtf8(self.input[chunk_start .. self.index - 1]));\n                    return", "try builder.appendSlice(allocator, self.input[chunk_start .. self.index - 1]);\n                    return"),
    ("json.zig", "try builder.appendSlice(allocator, try validUtf8(self.input[chunk_start .. self.index - 1]));\n                    try self.appendEscape", "try builder.appendSlice(allocator, self.input[chunk_start .. self.index - 1]);\n                    try self.appendEscape"),
    ("json.zig", ".number => _ = try self.parser.parseNumberSlice(),", ".number => _ = try self.readNumber(),"),
    ("json.zig", "return .{ .float = try parseFiniteFloat(f64, parsed.slice) };", "return .{ .float = std.fmt.parseFloat(f64, parsed.slice) catch return error.InvalidNumber };"),
    # MessagePack, BSON
    ("msgpack.zig", ".integer => castIntValue(T, try self.decodeInteger(tag)),\n                else", ".integer => castIntValue(T, try self.decodeInteger(tag)),\n                .float => castIntValue(T, @as(i128, @intFromFloat(try self.decodeFloat(tag)))),\n                else"),
    ("msgpack.zig", ".float => try typed.narrowFloat(T, try self.decodeFloat(tag)),", ".float => @as(T, @floatCast(try self.decodeFloat(tag))),"),
    ("bson.zig", "self.pending_type orelse return if (self.stack_len == 0 and self.index == 0) .object else error.UnexpectedType;", "self.pending_type orelse return error.UnexpectedType;"),
    # CBOR refuse_non_finite
    ("cbor.zig", "25 => (header.value >> 10) & 0x1f == 0x1f,", "25 => false,"),
    ("cbor.zig", "26 => (header.value >> 23) & 0xff == 0xff,", "26 => false,"),
    ("cbor.zig", "27 => (header.value >> 52) & 0x7ff == 0x7ff,", "27 => false,"),
    ("cbor.zig", "                7 => try self.checkFloat(header),", "                7 => {},"),
    ("cbor.zig", "            const header = try parseHeader(self.input, &self.index);\n            try self.checkFloat(header);\n            const record", "            const header = try parseHeader(self.input, &self.index);\n            const record"),
    ("cbor.zig", "            const header = try self.readHeader();\n            try self.checkFloat(header);", "            const header = try self.readHeader();"),
    # Integer variant keys and integer enums
    ("typed.zig", ".integer => |number| try serializer.emitInteger(number),", ".integer => try serializer.emitString(\"x\"),"),
    ("typed.zig", ".integer => |number| _ = try serializer.beginStructFieldInteger(T, number, Payload),", ".integer => |number| _ = try serializer.beginStructFieldInteger(T, number + 1, Payload),"),
    ("typed.zig", ".integer => |key| key == number,", ".integer => |key| key == number or true,"),
    ("typed.zig", "if (!integer_keys) return error.UnexpectedType;", "_ = 0;"),
    ("typed.zig", "if (comptime meta.effectiveEnumRepr(T, cfg) == .integer) return error.UnexpectedType;", "if (comptime meta.effectiveEnumRepr(T, cfg) == .integer and false) return error.UnexpectedType;"),
    ("typed.zig", "if (comptime meta.effectiveEnumRepr(T, cfg) == .integer) {\n                try serializer.emitInteger", "if (false) {\n                try serializer.emitInteger"),
    ("meta.zig", "if (comptime cfgHasField(cfg, \"enum_repr\")) return @field(cfg, \"enum_repr\");", "if (comptime cfgHasField(cfg, \"enum_repr\") and false) return @field(cfg, \"enum_repr\");"),
    ("cbor.zig", "                else => return error.UnexpectedType,\n            }\n        }\n\n        /// The next key of a struct's map", "                else => return null,\n            }\n        }\n\n        /// The next key of a struct's map"),
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
    result = subprocess.run(cmd, capture_output=True, text=True)
    output = result.stdout + result.stderr
    failed = sorted(set(re.findall(r"error: '(.+?)' failed", output)))
    verdict = "KILLED" if result.returncode != 0 else "SURVIVED"
    detail = failed[:2] or ("compile error or crash" if result.returncode != 0 else "")
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
