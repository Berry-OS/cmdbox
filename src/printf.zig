// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const u = @import("util.zig");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("errno.h");
    @cInclude("locale.h");
    @cInclude("time.h");
});
/// bash extensions (%q, %(fmt)T) are enabled only inside the shell
pub var bash_mode = false;

fn quoteBash(a: std.mem.Allocator, value: []const u8) []const u8 {
    var o = u.Vec(u8).init(a);
    if (value.len == 0) return "''";
    var ctl = false;
    for (value) |ch| if (ch < 32 or ch == 127) {
        ctl = true;
    };
    if (ctl) {
        o.push('$');
        o.push('\'');
        for (value) |ch| {
            switch (ch) {
                '\n' => o.pushSlice("\\n"),
                '\t' => o.pushSlice("\\t"),
                '\r' => o.pushSlice("\\r"),
                7 => o.pushSlice("\\a"),
                8 => o.pushSlice("\\b"),
                12 => o.pushSlice("\\f"),
                11 => o.pushSlice("\\v"),
                27 => o.pushSlice("\\E"),
                '\'' => o.pushSlice("\\'"),
                '\\' => o.pushSlice("\\\\"),
                else => {
                    if (ch < 32 or ch == 127) {
                        var b: [8]u8 = undefined;
                        o.pushSlice(std.fmt.bufPrint(&b, "\\{o:0>3}", .{ch}) catch "");
                    } else o.push(ch);
                },
            }
        }
        o.push('\'');
        return o.items;
    }
    for (value, 0..) |ch, k| {
        const safe = std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "_@%+=:,./-", ch) != null or ch >= 128;
        if (!safe or (k == 0 and ch == '~')) o.push('\\');
        o.push(ch);
    }
    return o.items;
}
const Escaped = struct { bytes: []const u8, stop: bool = false };
pub fn escapes(text: []const u8, is_argument: bool) ?Escaped {
    return decode(text, is_argument, false, false);
}
pub fn echoEscapes(text: []const u8) ?Escaped {
    return decode(text, false, true, false);
}
pub fn ansiEscapes(text: []const u8) ?Escaped {
    return decode(text, false, false, true);
}
fn decode(text: []const u8, is_argument: bool, is_echo: bool, is_ansi: bool) ?Escaped {
    var bytes = u.Vec(u8).init(u.alloc);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\' or i + 1 == text.len) {
            bytes.push(text[i]);
            continue;
        }
        i += 1;
        const byte = text[i];
        switch (byte) {
            'a' => bytes.push(7),
            'b' => bytes.push(8),
            'e' => bytes.push(27),
            'f' => bytes.push(12),
            'n' => bytes.push(10),
            'r' => bytes.push(13),
            't' => bytes.push(9),
            'v' => bytes.push(11),
            '\\' => bytes.push(byte),
            'c' => {
                if (is_ansi and i + 1 < text.len) {
                    i += 1;
                    bytes.push(if (text[i] == '?') 127 else std.ascii.toUpper(text[i]) & 31);
                } else return .{ .bytes = bytes.items, .stop = true };
            },
            '\'', '"', '?' => {
                if (!is_ansi) bytes.push('\\');
                bytes.push(byte);
            },
            'x', 'u', 'U' => {
                if (is_echo and byte != 'x') {
                    bytes.push('\\');
                    bytes.push(byte);
                    continue;
                }
                const limit: usize = if (byte == 'x') 2 else if (byte == 'u') 4 else 8;
                var value: u32 = 0;
                var digits: usize = 0;
                while (i + 1 < text.len and digits < limit) {
                    const digit = std.fmt.charToDigit(text[i + 1], 16) catch break;
                    i += 1;
                    digits += 1;
                    value = value * 16 + digit;
                }
                if (digits == 0 or byte != 'x' and digits != limit) {
                    if (is_echo) {
                        bytes.push('\\');
                        bytes.push(byte);
                        continue;
                    }
                    return null;
                }
                if (byte == 'x') bytes.push(@truncate(value)) else {
                    if (value > 0x10ffff) return null;
                    const loc = std.mem.sliceTo(c.setlocale(c.LC_CTYPE, null), 0);
                    if (value > 127 and (std.mem.eql(u8, loc, "C") or std.mem.eql(u8, loc, "POSIX"))) {
                        var literal: [16]u8 = undefined;
                        const text_value = if (value <= 0xffff) std.fmt.bufPrint(&literal, "\\u{X:0>4}", .{value}) catch return null else std.fmt.bufPrint(&literal, "\\U{X:0>8}", .{value}) catch return null;
                        for (text_value) |b| bytes.push(b);
                        continue;
                    }
                    var buffer: [4]u8 = undefined;
                    const size = std.unicode.utf8Encode(@intCast(value), &buffer) catch return null;
                    for (buffer[0..size]) |b| bytes.push(b);
                }
            },
            '0'...'7' => {
                var value: u16 = if ((is_argument or is_echo) and byte == '0') 0 else byte - '0';
                var digits: usize = if ((is_argument or is_echo) and byte == '0') 0 else 1;
                if (is_argument and byte != '0') {
                    bytes.push('\\');
                    bytes.push(byte);
                    continue;
                }
                while (i + 1 < text.len and digits < 3 and text[i + 1] >= '0' and text[i + 1] <= '7') {
                    i += 1;
                    digits += 1;
                    value = value * 8 + text[i] - '0';
                }
                bytes.push(@truncate(value));
            },
            else => {
                bytes.push('\\');
                bytes.push(byte);
            },
        }
    }
    return .{ .bytes = bytes.items };
}
fn argument(args: []const []const u8, index: *usize) []const u8 {
    if (index.* == args.len) return "";
    const value = args[index.*];
    index.* += 1;
    return value;
}
fn output(comptime T: type, format: [:0]const u8, value: T) bool {
    const size = c.snprintf(null, 0, format.ptr, value);
    if (size < 0) return false;
    const buffer = u.alloc.alloc(u8, @as(usize, @intCast(size)) + 1) catch return false;
    defer u.alloc.free(buffer);
    _ = c.snprintf(buffer.ptr, buffer.len, format.ptr, value);
    u.out(buffer[0..@intCast(size)]);
    return true;
}
fn quoted(value: []const u8) ?u32 {
    if (value.len == 0 or value[0] != '\'' and value[0] != '"') return null;
    if (value.len == 1) return 0;
    const size = std.unicode.utf8ByteSequenceLength(value[1]) catch return value[1];
    if (value.len < size + 1) return value[1];
    return std.unicode.utf8Decode(value[1 .. size + 1]) catch value[1];
}
pub fn run(all_args: []const []const u8) u8 {
    const args = if (all_args.len > 0 and std.mem.eql(u8, all_args[0], "--")) all_args[1..] else all_args;
    if (args.len == 0) {
        u.errf("printf: missing format\n", .{});
        return 1;
    }
    const format = args[0];
    var arg_index: usize = 1;
    var failed = false;
    while (true) {
        const before = arg_index;
        var i: usize = 0;
        while (i < format.len) {
            if (format[i] == '\\') {
                const start = i;
                i += 1;
                if (i < format.len) {
                    const byte = format[i];
                    i += 1;
                    const digits: usize = if (byte == 'x') 2 else if (byte == 'u') 4 else if (byte == 'U') 8 else if (byte >= '0' and byte <= '7') 2 else 0;
                    var n: usize = 0;
                    while (i < format.len and n < digits) : (n += 1) {
                        if (if (byte >= '0' and byte <= '7') format[i] < '0' or format[i] > '7' else !std.ascii.isHex(format[i])) break;
                        i += 1;
                    }
                }
                const value = escapes(format[start..i], false) orelse return bad();
                u.out(value.bytes);
                if (value.stop) return @intFromBool(failed);
                continue;
            }
            if (format[i] != '%') {
                const start = i;
                while (i < format.len and format[i] != '%' and format[i] != '\\') i += 1;
                u.out(format[start..i]);
                continue;
            }
            i += 1;
            if (i == format.len) return bad();
            if (format[i] == '%') {
                u.out("%");
                i += 1;
                continue;
            }
            var spec = u.Vec(u8).init(u.alloc);
            spec.push('%');
            while (i < format.len and std.mem.indexOfScalar(u8, "#0- +I'", format[i]) != null) : (i += 1) spec.push(format[i]);
            if (i < format.len and format[i] == '*') {
                const width = std.fmt.parseInt(i32, argument(args, &arg_index), 10) catch blk: {
                    failed = true;
                    break :blk 0;
                };
                var buf: [32]u8 = undefined;
                const value = std.fmt.bufPrint(&buf, "{d}", .{width}) catch return 1;
                for (value) |byte| spec.push(byte);
                i += 1;
            } else while (i < format.len and std.ascii.isDigit(format[i])) : (i += 1) spec.push(format[i]);
            if (i < format.len and format[i] == '.') {
                spec.push('.');
                i += 1;
                if (i < format.len and format[i] == '*') {
                    const precision = std.fmt.parseInt(i32, argument(args, &arg_index), 10) catch blk: {
                        failed = true;
                        break :blk 0;
                    };
                    if (precision >= 0) {
                        var buf: [32]u8 = undefined;
                        const value = std.fmt.bufPrint(&buf, "{d}", .{precision}) catch return 1;
                        for (value) |byte| spec.push(byte);
                    } else spec.pop();
                    i += 1;
                } else while (i < format.len and std.ascii.isDigit(format[i])) : (i += 1) spec.push(format[i]);
            }
            while (i < format.len and std.mem.indexOfScalar(u8, "hlLjzt", format[i]) != null) i += 1;
            if (i == format.len) return bad();
            if (bash_mode and format[i] == '(') {
                const close = std.mem.indexOfScalarPos(u8, format, i, ')') orelse return bad();
                if (close + 1 >= format.len or format[close + 1] != 'T') return bad();
                const tfmt = format[i + 1 .. close];
                i = close + 2;
                const av = argument(args, &arg_index);
                var tt: c.time_t = c.time(null);
                if (av.len > 0) {
                    const num = std.fmt.parseInt(i64, av, 10) catch return bad();
                    if (num >= 0) tt = @intCast(num);
                }
                var tmv: c.struct_tm = undefined;
                _ = c.localtime_r(&tt, &tmv);
                var tbuf: [512]u8 = undefined;
                const tl = c.strftime(&tbuf, tbuf.len, u.zstr(tfmt), &tmv);
                u.out(tbuf[0..tl]);
                continue;
            }
            const conversion = format[i];
            i += 1;
            const value = argument(args, &arg_index);
            switch (conversion) {
                's', 'b' => {
                    spec.push('s');
                    const escaped = if (conversion == 'b') escapes(value, true) orelse return bad() else Escaped{ .bytes = value };
                    // %b can contain NUL, so use direct output when no width/precision.
                    if (conversion == 'b') {
                        if (spec.items.len != 2) return bad();
                        u.out(escaped.bytes);
                    } else if (!output([*:0]const u8, u.zstr(spec.items), u.zstr(escaped.bytes).ptr)) failed = true;
                    if (escaped.stop) return @intFromBool(failed);
                },
                'q' => {
                    if (!bash_mode) return bad();
                    const qv = quoteBash(u.alloc, value);
                    if (spec.items.len == 1) u.out(qv) else {
                        spec.push('s');
                        if (!output([*:0]const u8, u.zstr(spec.items), u.zstr(qv).ptr)) failed = true;
                    }
                },
                'c' => {
                    spec.push('c');
                    if (!output(c_int, u.zstr(spec.items), if (value.len > 0) value[0] else 0)) failed = true;
                },
                'd', 'i', 'o', 'u', 'x', 'X' => {
                    spec.push('l');
                    spec.push('l');
                    spec.push(conversion);
                    const text = u.zstr(value);
                    var end: [*c]u8 = undefined;
                    c.__errno_location().* = 0;
                    if (conversion == 'd' or conversion == 'i') {
                        const number: c_longlong = if (quoted(value)) |v| v else if (value.len == 0) 0 else c.strtoll(text, &end, 0);
                        if (quoted(value) == null and value.len > 0 and (end == text.ptr or end[0] != 0 or c.__errno_location().* != 0)) failed = true;
                        if (!output(c_longlong, u.zstr(spec.items), number)) failed = true;
                    } else {
                        const number: c_ulonglong = if (quoted(value)) |v| v else if (value.len == 0) 0 else c.strtoull(text, &end, 0);
                        if (quoted(value) == null and value.len > 0 and (end == text.ptr or end[0] != 0 or c.__errno_location().* != 0)) failed = true;
                        if (!output(c_ulonglong, u.zstr(spec.items), number)) failed = true;
                    }
                },
                'f', 'F', 'e', 'E', 'g', 'G', 'a', 'A' => {
                    spec.push(conversion);
                    const text = u.zstr(value);
                    var end: [*c]u8 = undefined;
                    c.__errno_location().* = 0;
                    const number: f64 = if (quoted(value)) |v| @floatFromInt(v) else if (value.len == 0) 0 else c.strtod(text, &end);
                    if (quoted(value) == null and value.len > 0 and (end == text.ptr or end[0] != 0 or c.__errno_location().* != 0)) failed = true;
                    if (!output(f64, u.zstr(spec.items), number)) failed = true;
                },
                else => return bad(),
            }
        }
        if (arg_index == before or arg_index == args.len) break;
    }
    return @intFromBool(failed);
}
fn bad() u8 {
    u.errf("printf: invalid format or escape\n", .{});
    return 1;
}
