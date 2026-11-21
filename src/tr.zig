// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const u = @import("util.zig");
const linux = std.os.linux;
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn character(s: []const u8, index: *usize) ?u8 {
    if (index.* >= s.len) return null;
    const byte = s[index.*];
    index.* += 1;
    if (byte != '\\' or index.* == s.len) return byte;
    const next = s[index.*];
    index.* += 1;
    if (next >= '0' and next <= '7') {
        var value: u16 = next - '0';
        var digits: usize = 1;
        while (digits < 3 and index.* < s.len and s[index.*] >= '0' and s[index.*] <= '7') : (digits += 1) {
            value = value * 8 + s[index.*] - '0';
            index.* += 1;
        }
        return @truncate(value);
    }
    return switch (next) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        'a' => 7,
        'b' => 8,
        'f' => 12,
        'v' => 11,
        else => next,
    };
}
fn class(name: []const u8, byte: u8) ?bool {
    if (same(name, "alnum")) return std.ascii.isAlphanumeric(byte);
    if (same(name, "alpha")) return std.ascii.isAlphabetic(byte);
    if (same(name, "blank")) return byte == ' ' or byte == '\t';
    if (same(name, "cntrl")) return byte < 32 or byte == 127;
    if (same(name, "digit")) return std.ascii.isDigit(byte);
    if (same(name, "graph")) return byte > 32 and byte < 127;
    if (same(name, "lower")) return std.ascii.isLower(byte);
    if (same(name, "print")) return byte >= 32 and byte < 127;
    if (same(name, "punct")) return byte > 32 and byte < 127 and !std.ascii.isAlphanumeric(byte);
    if (same(name, "space")) return std.ascii.isWhitespace(byte);
    if (same(name, "upper")) return std.ascii.isUpper(byte);
    if (same(name, "xdigit")) return std.ascii.isHex(byte);
    return null;
}
fn expand(s: []const u8, buffer: *u.Vec(u8), repeat_length: usize) bool {
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], "[:")) {
            const end = std.mem.indexOf(u8, s[i + 2 ..], ":]") orelse return false;
            const name = s[i + 2 .. i + 2 + end];
            for (0..256) |n| {
                const byte: u8 = @intCast(n);
                if (class(name, byte) orelse return false) buffer.push(byte);
            }
            i += end + 4;
            continue;
        }
        if (std.mem.startsWith(u8, s[i..], "[=")) {
            i += 2;
            const byte = character(s, &i) orelse return false;
            if (!std.mem.startsWith(u8, s[i..], "=]")) return false;
            buffer.push(byte);
            i += 2;
            continue;
        }
        if (s[i] == '[') {
            var at = i + 1;
            const byte = character(s, &at) orelse return false;
            if (at < s.len and s[at] == '*') {
                at += 1;
                const end = std.mem.indexOfScalarPos(u8, s, at, ']') orelse return false;
                const number = s[at..end];
                var amount = if (number.len == 0) @as(usize, 0) else std.fmt.parseInt(usize, number, if (number[0] == '0') 8 else 10) catch return false;
                if (amount == 0) amount = repeat_length -| buffer.items.len;
                if (amount > 1048576) return false;
                for (0..amount) |_| buffer.push(byte);
                i = end + 1;
                continue;
            }
        }
        const first = character(s, &i) orelse return false;
        if (i + 1 < s.len and s[i] == '-') {
            i += 1;
            const last = character(s, &i) orelse return false;
            if (last < first) return false;
            var byte: u16 = first;
            while (byte <= last) : (byte += 1) buffer.push(@intCast(byte));
        } else buffer.push(first);
    }
    return true;
}
fn runInner(args: []const []const u8) u8 {
    var delete = false;
    var squeeze = false;
    var complement = false;
    var truncate = false;
    var sets = u.Vec([]const u8).init(u.alloc);
    var options = true;
    for (args) |arg| {
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and arg.len > 1 and arg[0] == '-') {
            if (same(arg, "--delete")) delete = true else if (same(arg, "--squeeze-repeats")) squeeze = true else if (same(arg, "--complement")) complement = true else if (same(arg, "--truncate-set1")) truncate = true else for (arg[1..]) |flag| switch (flag) {
                'd' => delete = true,
                's' => squeeze = true,
                'c', 'C' => complement = true,
                't' => truncate = true,
                else => return bad(),
            };
        } else {
            options = false;
            sets.push(arg);
        }
    }
    if (sets.items.len == 0 or sets.items.len > 2 or !delete and !squeeze and sets.items.len != 2 or delete and !squeeze and sets.items.len != 1 or delete and squeeze and sets.items.len != 2) return bad();
    var first = u.Vec(u8).init(u.alloc);
    var second = u.Vec(u8).init(u.alloc);
    if (!expand(sets.items[0], &first, 0)) return bad();
    if (complement) {
        var present: [256]bool = @splat(false);
        for (first.items) |byte| present[byte] = true;
        first.items.len = 0;
        for (0..256) |n| if (!present[n]) {
            first.push(@intCast(n));
        };
    }
    if (sets.items.len == 2 and !expand(sets.items[1], &second, first.items.len)) return bad();
    const translate = !delete and sets.items.len == 2;
    if (translate and second.items.len == 0 and !truncate) return bad();
    var map: [256]u8 = undefined;
    var removed: [256]bool = @splat(false);
    var squeezed: [256]bool = @splat(false);
    for (0..256) |n| map[n] = @intCast(n);
    if (delete) for (first.items) |byte| {
        removed[byte] = true;
    };
    if (translate) for (first.items, 0..) |byte, n| {
        if (n < second.items.len) map[byte] = second.items[n] else if (!truncate) map[byte] = second.items[second.items.len - 1];
    };
    if (squeeze) for (if (sets.items.len == 2) second.items else first.items) |byte| {
        squeezed[byte] = true;
    };
    var last: ?u8 = null;
    var buffer: [16384]u8 = undefined;
    const stdout = u.File{ .fd = 1 };
    while (true) {
        const rc = linux.read(0, &buffer, buffer.len);
        if (u.errno(rc) == .INTR) continue;
        if (!u.ok(rc)) return 1;
        if (rc == 0) break;
        var used: usize = 0;
        for (buffer[0..rc]) |original| {
            if (removed[original]) continue;
            const byte = map[original];
            if (squeezed[byte] and last != null and last.? == byte) continue;
            buffer[used] = byte;
            used += 1;
            last = byte;
        }
        if (!stdout.write(buffer[0..used])) return 1;
    }
    return 0;
}
fn bad() u8 {
    u.errf("tr: invalid operands or character set\n", .{});
    return 1;
}

pub fn run(args: []const []const u8) u8 {
    const g = @import("getopt.zig");
    const spec = g.Spec{
        .prog = "tr",
        .short = "cCdst",
        .long = &.{ "complement", "delete", "squeeze-repeats", "truncate-set1" },
        .help = "Usage: tr [OPTION]... STRING1 [STRING2]\nTranslate, squeeze, and/or delete characters from standard input,\nwriting to standard output.\n",
    };
    switch (g.normalize(spec, args)) {
        .exit => |code| return code,
        .args => |a| return runInner(a),
    }
}
