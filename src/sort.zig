// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const u = @import("util.zig");
const input = @import("input.zig");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("stdlib.h");
    @cInclude("string.h");
});
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
const Flags = struct { numeric: bool = false, general: bool = false, reverse: bool = false, fold: bool = false, blank: bool = false, dictionary: bool = false, nonprinting: bool = false, version: bool = false };
const Key = struct { first: usize, first_char: usize = 1, last: usize = std.math.maxInt(usize), last_char: usize = 0, flags: Flags = .{}, own_flags: bool = false };
const Context = struct { flags: Flags, keys: []const Key, delimiter: ?u8, stable: bool, unique: bool };
fn flagsSet(flags: *Flags, byte: u8) bool {
    switch (byte) {
        'n' => flags.numeric = true,
        'g' => flags.general = true,
        'r' => flags.reverse = true,
        'f' => flags.fold = true,
        'b' => flags.blank = true,
        'd' => flags.dictionary = true,
        'i' => flags.nonprinting = true,
        'V' => flags.version = true,
        else => return false,
    }
    return true;
}
fn parseKey(text: []const u8) ?Key {
    var key = Key{ .first = 1 };
    var endpoints = std.mem.splitScalar(u8, text, ',');
    const first = endpoints.next().?;
    const last = endpoints.next();
    if (endpoints.next() != null) return null;
    const parts = [_]?[]const u8{ first, last };
    for (parts, 0..) |part, end| if (part) |value| {
        var i: usize = 0;
        while (i < value.len and std.ascii.isDigit(value[i])) i += 1;
        const field = std.fmt.parseInt(usize, value[0..i], 10) catch return null;
        if (field == 0) return null;
        if (end == 0) key.first = field else key.last = field;
        if (i < value.len and value[i] == '.') {
            i += 1;
            const start = i;
            while (i < value.len and std.ascii.isDigit(value[i])) i += 1;
            const char = std.fmt.parseInt(usize, value[start..i], 10) catch return null;
            if (end == 0) {
                if (char == 0) return null;
                key.first_char = char;
            } else key.last_char = char;
        }
        for (value[i..]) |flag| {
            if (!flagsSet(&key.flags, flag)) return null;
            key.own_flags = true;
        }
    };
    return key;
}
fn fieldStart(line: []const u8, field: usize, delimiter: ?u8) usize {
    var current: usize = 1;
    var pos: usize = 0;
    while (current < field and pos < line.len) : (current += 1) {
        if (delimiter) |d| {
            while (pos < line.len and line[pos] != d) pos += 1;
            if (pos < line.len) pos += 1;
        } else {
            while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
            while (pos < line.len and line[pos] != ' ' and line[pos] != '\t') pos += 1;
        }
    }
    return pos;
}
fn keyText(line: []const u8, key: Key, delimiter: ?u8, flags: Flags) []const u8 {
    var start = fieldStart(line, key.first, delimiter);
    if (flags.blank) while (start < line.len and (line[start] == ' ' or line[start] == '\t')) {
        start += 1;
    };
    start = @min(line.len, start +| (key.first_char - 1));
    var end = line.len;
    if (key.last != std.math.maxInt(usize)) {
        end = fieldStart(line, key.last, delimiter);
        if (key.last_char > 0) {
            if (flags.blank) while (end < line.len and (line[end] == ' ' or line[end] == '\t')) {
                end += 1;
            };
            end = @min(line.len, end +| key.last_char);
        } else if (delimiter) |d| {
            while (end < line.len and line[end] != d) end += 1;
        } else {
            while (end < line.len and (line[end] == ' ' or line[end] == '\t')) end += 1;
            while (end < line.len and line[end] != ' ' and line[end] != '\t') end += 1;
        }
    }
    return line[start..@max(start, end)];
}
const Number = struct { negative: bool, integer: []const u8, fraction: []const u8 };
fn number(text: []const u8) Number {
    var s = std.mem.trimStart(u8, text, " \t");
    var negative = false;
    if (s.len > 0 and s[0] == '-') {
        negative = true;
        s = s[1..];
    }
    var end: usize = 0;
    while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
    var integer = s[0..end];
    while (integer.len > 0 and integer[0] == '0') integer = integer[1..];
    var fraction: []const u8 = "";
    if (end < s.len and s[end] == '.') {
        const start = end + 1;
        end = start;
        while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
        fraction = std.mem.trimEnd(u8, s[start..end], "0");
    }
    if (integer.len == 0 and fraction.len == 0) negative = false;
    return .{ .negative = negative, .integer = integer, .fraction = fraction };
}
fn numeric(a: []const u8, b: []const u8) std.math.Order {
    const x = number(a);
    const y = number(b);
    if (x.negative != y.negative) return if (x.negative) .lt else .gt;
    var order = std.math.order(x.integer.len, y.integer.len);
    if (order == .eq) order = std.mem.order(u8, x.integer, y.integer);
    if (order == .eq) {
        for (0..@max(x.fraction.len, y.fraction.len)) |i| {
            order = std.math.order(if (i < x.fraction.len) x.fraction[i] else @as(u8, '0'), if (i < y.fraction.len) y.fraction[i] else @as(u8, '0'));
            if (order != .eq) break;
        }
    }
    return if (x.negative) order.invert() else order;
}
fn next(text: []const u8, index: *usize, flags: Flags) ?u8 {
    while (index.* < text.len) {
        const byte = text[index.*];
        index.* += 1;
        if (flags.dictionary and !std.ascii.isAlphanumeric(byte) and byte != ' ' and byte != '\t') continue;
        if (flags.nonprinting and (byte < 32 or byte > 126)) continue;
        return if (flags.fold) std.ascii.toUpper(byte) else byte;
    }
    return null;
}
fn compareText(a: []const u8, b: []const u8, flags: Flags) std.math.Order {
    var order: std.math.Order = .eq;
    if (flags.numeric) order = numeric(a, b) else if (flags.general) {
        const x = c.strtod(u.zstr(a), null);
        const y = c.strtod(u.zstr(b), null);
        order = if (std.math.isNan(x)) (if (std.math.isNan(y)) .eq else .lt) else if (std.math.isNan(y)) .gt else std.math.order(x, y);
    } else if (flags.version) order = std.math.order(c.strverscmp(u.zstr(a), u.zstr(b)), @as(c_int, 0)) else {
        var ai: usize = 0;
        var bi: usize = 0;
        const left = if (flags.blank) std.mem.trimStart(u8, a, " \t") else a;
        const right = if (flags.blank) std.mem.trimStart(u8, b, " \t") else b;
        while (true) {
            const x = next(left, &ai, flags);
            const y = next(right, &bi, flags);
            if (x == null or y == null) {
                order = if (x == null) (if (y == null) .eq else .lt) else .gt;
                break;
            }
            order = std.math.order(x.?, y.?);
            if (order != .eq) break;
        }
    }
    return if (flags.reverse) order.invert() else order;
}
fn compare(ctx: Context, a: []const u8, b: []const u8, fallback: bool) std.math.Order {
    if (ctx.keys.len == 0) {
        const order = compareText(a, b, ctx.flags);
        if (order != .eq) return order;
    } else for (ctx.keys) |key| {
        const flags = if (key.own_flags) key.flags else ctx.flags;
        const order = compareText(keyText(a, key, ctx.delimiter, flags), keyText(b, key, ctx.delimiter, flags), flags);
        if (order != .eq) return order;
    }
    if (!fallback or ctx.stable or ctx.unique) return .eq;
    const order = std.mem.order(u8, a, b);
    return if (ctx.flags.reverse) order.invert() else order;
}
pub fn run(args: []const []const u8) u8 {
    var ctx = Context{ .flags = .{}, .keys = &.{}, .delimiter = null, .stable = false, .unique = false };
    var keys = u.Vec(Key).init(u.alloc);
    var files = u.Vec([]const u8).init(u.alloc);
    var output: ?[]const u8 = null;
    var delimiter: u8 = '\n';
    var check = false;
    var options = true;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and std.mem.startsWith(u8, arg, "--")) {
            if (same(arg, "--numeric-sort")) ctx.flags.numeric = true else if (same(arg, "--general-numeric-sort")) ctx.flags.general = true else if (same(arg, "--reverse")) ctx.flags.reverse = true else if (same(arg, "--unique")) ctx.unique = true else if (same(arg, "--stable")) ctx.stable = true else if (same(arg, "--ignore-case")) ctx.flags.fold = true else if (same(arg, "--zero-terminated")) delimiter = 0 else if (same(arg, "--check") or same(arg, "--check=quiet")) check = true else if (std.mem.startsWith(u8, arg, "--key=")) keys.push(parseKey(arg[6..]) orelse return bad()) else if (std.mem.startsWith(u8, arg, "--output=")) output = arg[9..] else return bad();
        } else if (options and arg.len > 1 and arg[0] == '-') {
            var k: usize = 1;
            while (k < arg.len) : (k += 1) {
                if (flagsSet(&ctx.flags, arg[k])) continue;
                switch (arg[k]) {
                    'u' => ctx.unique = true,
                    's' => ctx.stable = true,
                    'z' => delimiter = 0,
                    'c', 'C' => check = true,
                    'm' => {},
                    'k', 't', 'o', 'S', 'T' => |flag| {
                        const value = if (k + 1 < arg.len) arg[k + 1 ..] else blk: {
                            i += 1;
                            if (i == args.len) return bad();
                            break :blk args[i];
                        };
                        if (flag == 'k') keys.push(parseKey(value) orelse return bad()) else if (flag == 't') {
                            if (value.len != 1) return bad();
                            ctx.delimiter = value[0];
                        } else if (flag == 'o') output = value;
                        break;
                    },
                    else => return bad(),
                }
            }
        } else files.push(arg);
    }
    ctx.keys = keys.items;
    if (files.items.len == 0) files.push("-");
    var lines = u.Vec([]const u8).init(u.alloc);
    for (files.items) |name| {
        const data = input.read(name, false) orelse return 2;
        const records = input.records(data, delimiter);
        for (records.items) |record| lines.push(record.text);
    }
    if (check) {
        for (1..@max(lines.items.len, 1)) |index| {
            const order = compare(ctx, lines.items[index - 1], lines.items[index], true);
            if (order == .gt or ctx.unique and order == .eq) return 1;
        }
        return 0;
    }
    std.mem.sort([]const u8, lines.items, ctx, struct {
        fn less(context: Context, a: []const u8, b: []const u8) bool {
            return compare(context, a, b, true) == .lt;
        }
    }.less);
    const destination = if (output) |name| u.File.open(name, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666) orelse return 2 else u.File{ .fd = 1 };
    defer if (destination.fd != 1) destination.close();
    var previous: ?[]const u8 = null;
    for (lines.items) |line| {
        if (ctx.unique and previous != null and compare(ctx, previous.?, line, false) == .eq) continue;
        if (!destination.write(line) or !destination.write(&.{delimiter})) return 2;
        previous = line;
    }
    return 0;
}
fn bad() u8 {
    u.errf("sort: invalid option or key\n", .{});
    return 2;
}
