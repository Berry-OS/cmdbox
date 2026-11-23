// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// sort - GNU coreutils sort(1): keys, all ordering options, check, merge, unique, random, files0-from
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const input = @import("input.zig");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("strings.h");
});

const Flags = struct {
    numeric: bool = false,
    general: bool = false,
    human: bool = false,
    month: bool = false,
    random: bool = false,
    version: bool = false,
    reverse: bool = false,
    fold: bool = false,
    blank: bool = false,
    dictionary: bool = false,
    nonprinting: bool = false,

    fn any(self: Flags) bool {
        return self.numeric or self.general or self.human or self.month or self.random or self.version or self.reverse or self.fold or self.blank or self.dictionary or self.nonprinting;
    }
};

const Key = struct { first: usize, first_char: usize = 1, last: usize = std.math.maxInt(usize), last_char: usize = 0, flags: Flags = .{}, own_flags: bool = false };
const Context = struct { flags: Flags, keys: []const Key, delimiter: ?u8, stable: bool, unique: bool, salt: [16]u8 };

fn setFlag(flags: *Flags, byte: u8) bool {
    switch (byte) {
        'n' => flags.numeric = true,
        'g' => flags.general = true,
        'h' => flags.human = true,
        'M' => flags.month = true,
        'R' => flags.random = true,
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
            const ch = std.fmt.parseInt(usize, value[start..i], 10) catch return null;
            if (end == 0) {
                if (ch == 0) return null;
                key.first_char = ch;
            } else key.last_char = ch;
        }
        for (value[i..]) |flag| {
            if (!setFlag(&key.flags, flag)) return null;
            key.own_flags = true;
        }
    };
    return key;
}

fn isBlank(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}

fn fieldStart(line: []const u8, field: usize, delimiter: ?u8) usize {
    var current: usize = 1;
    var pos: usize = 0;
    while (current < field and pos < line.len) : (current += 1) {
        if (delimiter) |d| {
            while (pos < line.len and line[pos] != d) pos += 1;
            if (pos < line.len) pos += 1;
        } else {
            while (pos < line.len and isBlank(line[pos])) pos += 1;
            while (pos < line.len and !isBlank(line[pos])) pos += 1;
        }
    }
    return pos;
}

fn keyText(line: []const u8, key: Key, delimiter: ?u8, flags: Flags) []const u8 {
    var start = fieldStart(line, key.first, delimiter);
    if (flags.blank) while (start < line.len and isBlank(line[start])) {
        start += 1;
    };
    start = @min(line.len, start +| (key.first_char - 1));
    var end = line.len;
    if (key.last != std.math.maxInt(usize)) {
        end = fieldStart(line, key.last, delimiter);
        if (key.last_char > 0) {
            if (flags.blank) while (end < line.len and isBlank(line[end])) {
                end += 1;
            };
            end = @min(line.len, end +| key.last_char);
        } else if (delimiter) |d| {
            while (end < line.len and line[end] != d) end += 1;
        } else {
            while (end < line.len and isBlank(line[end])) end += 1;
            while (end < line.len and !isBlank(line[end])) end += 1;
        }
    }
    return line[start..@max(start, end)];
}

// ---------- numeric comparisons ----------
const Number = struct { negative: bool, integer: []const u8, fraction: []const u8, end: usize };

fn parseNumber(text: []const u8, thousands: bool) Number {
    var i: usize = 0;
    while (i < text.len and isBlank(text[i])) i += 1;
    var negative = false;
    if (i < text.len and text[i] == '-') {
        negative = true;
        i += 1;
    }
    const ds = i;
    var buf = u.Vec(u8).init(u.alloc);
    while (i < text.len and (std.ascii.isDigit(text[i]) or (thousands and text[i] == ',' and i > ds))) : (i += 1) {
        if (text[i] != ',') buf.push(text[i]);
    }
    var integer: []const u8 = buf.items;
    while (integer.len > 0 and integer[0] == '0') integer = integer[1..];
    var fraction: []const u8 = "";
    if (i < text.len and text[i] == '.') {
        const fs = i + 1;
        var j = fs;
        while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
        fraction = std.mem.trimEnd(u8, text[fs..j], "0");
        i = j;
    }
    if (integer.len == 0 and fraction.len == 0) negative = false;
    return .{ .negative = negative, .integer = integer, .fraction = fraction, .end = i };
}

fn cmpNumbers(x: Number, y: Number) std.math.Order {
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

fn numeric(a: []const u8, b: []const u8) std.math.Order {
    return cmpNumbers(parseNumber(a, false), parseNumber(b, false));
}

fn suffixRank(ch: u8) ?u8 {
    return switch (ch) {
        'K', 'k' => 1,
        'M' => 2,
        'G' => 3,
        'T' => 4,
        'P' => 5,
        'E' => 6,
        'Z' => 7,
        'Y' => 8,
        'R' => 9,
        'Q' => 10,
        else => null,
    };
}

fn human(a: []const u8, b: []const u8) std.math.Order {
    const x = parseNumber(a, true);
    const y = parseNumber(b, true);
    const xr: u8 = if (x.end < a.len) (suffixRank(a[x.end]) orelse 0) else 0;
    const yr: u8 = if (y.end < b.len) (suffixRank(b[y.end]) orelse 0) else 0;
    if (x.negative != y.negative) return if (x.negative) .lt else .gt;
    // compare by magnitude: suffix first, then the number
    var order = std.math.order(xr, yr);
    if (order == .eq) order = cmpNumbers(.{ .negative = false, .integer = x.integer, .fraction = x.fraction, .end = 0 }, .{ .negative = false, .integer = y.integer, .fraction = y.fraction, .end = 0 });
    return if (x.negative) order.invert() else order;
}

fn general(a: []const u8, b: []const u8) std.math.Order {
    var ea: [*c]u8 = undefined;
    var eb: [*c]u8 = undefined;
    const za = u.zstr(std.mem.trimStart(u8, a, " \t"));
    const zb = u.zstr(std.mem.trimStart(u8, b, " \t"));
    const x = c.strtod(za.ptr, &ea);
    const y = c.strtod(zb.ptr, &eb);
    const xv = ea != @as([*c]u8, @ptrCast(@constCast(za.ptr)));
    const yv = eb != @as([*c]u8, @ptrCast(@constCast(zb.ptr)));
    // non-numbers sort before numbers; NaN sorts before real numbers
    if (!xv or !yv) return if (!xv and !yv) .eq else if (!xv) .lt else .gt;
    const xn = std.math.isNan(x);
    const yn = std.math.isNan(y);
    if (xn or yn) return if (xn and yn) .eq else if (xn) .lt else .gt;
    return std.math.order(x, y);
}

fn monthVal(s: []const u8) u8 {
    var i: usize = 0;
    while (i < s.len and isBlank(s[i])) i += 1;
    const names = [_][]const u8{ "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC" };
    if (s.len - i < 3) return 0;
    var up: [3]u8 = undefined;
    for (0..3) |k| up[k] = std.ascii.toUpper(s[i + k]);
    for (names, 0..) |nm, k| if (std.mem.eql(u8, nm, &up)) return @intCast(k + 1);
    return 0;
}

fn randomKey(ctx: Context, text: []const u8) [16]u8 {
    var h = std.crypto.hash.Md5.init(.{});
    h.update(&ctx.salt);
    h.update(text);
    var out: [16]u8 = undefined;
    h.final(&out);
    return out;
}

fn nextChar(text: []const u8, index: *usize, flags: Flags) ?u8 {
    while (index.* < text.len) {
        const byte = text[index.*];
        index.* += 1;
        if (flags.dictionary and !std.ascii.isAlphanumeric(byte) and !isBlank(byte)) continue;
        if (flags.nonprinting and (byte < 32 or byte > 126)) continue;
        return if (flags.fold) std.ascii.toUpper(byte) else byte;
    }
    return null;
}

fn compareText(ctx: Context, a: []const u8, b: []const u8, flags: Flags) std.math.Order {
    var order: std.math.Order = .eq;
    if (flags.numeric) {
        order = numeric(a, b);
    } else if (flags.general) {
        order = general(a, b);
    } else if (flags.human) {
        order = human(a, b);
    } else if (flags.month) {
        order = std.math.order(monthVal(a), monthVal(b));
    } else if (flags.version) {
        order = u.fileverCmp(a, b);
    } else if (flags.random) {
        if (std.mem.eql(u8, a, b)) {
            order = .eq;
        } else order = std.mem.order(u8, &randomKey(ctx, a), &randomKey(ctx, b));
    } else {
        var ai: usize = 0;
        var bi: usize = 0;
        const left = if (flags.blank) std.mem.trimStart(u8, a, " \t") else a;
        const right = if (flags.blank) std.mem.trimStart(u8, b, " \t") else b;
        if (!flags.dictionary and !flags.nonprinting and !flags.fold) {
            order = std.mem.order(u8, left, right);
        } else while (true) {
            const x = nextChar(left, &ai, flags);
            const y = nextChar(right, &bi, flags);
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
        const order = compareText(ctx, a, b, ctx.flags);
        if (order != .eq) return order;
    } else for (ctx.keys) |key| {
        var flags = if (key.own_flags) key.flags else ctx.flags;
        if (key.own_flags and !key.flags.any()) flags = ctx.flags;
        const order = compareText(ctx, keyText(a, key, ctx.delimiter, flags), keyText(b, key, ctx.delimiter, flags), flags);
        if (order != .eq) return order;
    }
    if (!fallback or ctx.stable or ctx.unique) return .eq;
    const order = std.mem.order(u8, a, b);
    return if (ctx.flags.reverse) order.invert() else order;
}

fn readFd(fd: i32) ?[]u8 {
    var data = u.Vec(u8).init(u.alloc);
    var buffer: [16384]u8 = undefined;
    while (true) {
        const rc = linux.read(fd, &buffer, buffer.len);
        if (u.errno(rc) == .INTR) continue;
        if (!u.ok(rc)) return null;
        if (rc == 0) break;
        data.pushSlice(buffer[0..rc]);
    }
    return data.items;
}

pub fn run(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "ignore-leading-blanks", .key = 'b' },
        .{ .name = "dictionary-order", .key = 'd' },
        .{ .name = "ignore-case", .key = 'f' },
        .{ .name = "general-numeric-sort", .key = 'g' },
        .{ .name = "human-numeric-sort", .key = 'h' },
        .{ .name = "ignore-nonprinting", .key = 'i' },
        .{ .name = "month-sort", .key = 'M' },
        .{ .name = "numeric-sort", .key = 'n' },
        .{ .name = "random-sort", .key = 'R' },
        .{ .name = "reverse", .key = 'r' },
        .{ .name = "version-sort", .key = 'V' },
        .{ .name = "sort", .key = 130, .arg = .req },
        .{ .name = "check", .key = 'c', .arg = .opt },
        .{ .key = 'C' },
        .{ .name = "merge", .key = 'm' },
        .{ .name = "output", .key = 'o', .arg = .req },
        .{ .name = "stable", .key = 's' },
        .{ .name = "buffer-size", .key = 'S', .arg = .req },
        .{ .name = "field-separator", .key = 't', .arg = .req },
        .{ .name = "temporary-directory", .key = 'T', .arg = .req },
        .{ .name = "unique", .key = 'u' },
        .{ .name = "zero-terminated", .key = 'z' },
        .{ .name = "key", .key = 'k', .arg = .req },
        .{ .name = "parallel", .key = 131, .arg = .req },
        .{ .name = "batch-size", .key = 132, .arg = .req },
        .{ .name = "compress-program", .key = 133, .arg = .req },
        .{ .name = "debug", .key = 134 },
        .{ .name = "files0-from", .key = 135, .arg = .req },
        .{ .name = "random-source", .key = 136, .arg = .req },
        .{ .name = "help", .key = 200 },
        .{ .name = "version", .key = 201 },
    };
    var ctx = Context{ .flags = .{}, .keys = &.{}, .delimiter = null, .stable = false, .unique = false, .salt = [_]u8{0} ** 16 };
    var keys = u.Vec(Key).init(u.alloc);
    var output: ?[]const u8 = null;
    var rec_delim: u8 = '\n';
    var check: u8 = 0;
    var merge = false; // 'c' diagnose, 'C' quiet
    var files0: ?[]const u8 = null;
    var random_source: ?[]const u8 = null;
    var p = g.Parser.init("sort", args, &opts);
    while (p.next() catch return 2) |it| {
        switch (it.key) {
            'b', 'd', 'f', 'g', 'h', 'i', 'M', 'n', 'R', 'r', 'V' => _ = setFlag(&ctx.flags, it.key),
            130 => {
                const v = it.val.?;
                const m = [_]struct { n: []const u8, f: u8 }{ .{ .n = "general-numeric", .f = 'g' }, .{ .n = "human-numeric", .f = 'h' }, .{ .n = "month", .f = 'M' }, .{ .n = "numeric", .f = 'n' }, .{ .n = "random", .f = 'R' }, .{ .n = "version", .f = 'V' } };
                var ok = false;
                for (m) |e| if (std.mem.eql(u8, e.n, v)) {
                    _ = setFlag(&ctx.flags, e.f);
                    ok = true;
                };
                if (!ok) {
                    u.errf("sort: invalid argument '{s}' for '--sort'\nValid arguments are:\n  - 'general-numeric', 'g'\n  - 'human-numeric', 'h'\n  - 'month', 'M'\n  - 'numeric', 'n'\n  - 'random', 'R'\n  - 'version', 'V'\nTry 'sort --help' for more information.\n", .{v});
                    return 2;
                }
            },
            'c' => {
                if (it.val) |v| {
                    if (std.mem.eql(u8, v, "quiet") or std.mem.eql(u8, v, "silent")) check = 'C' else if (std.mem.eql(u8, v, "diagnose-first")) check = 'c' else {
                        u.errf("sort: invalid argument '{s}' for '--check'\n", .{v});
                        return 2;
                    }
                } else check = 'c';
            },
            'C' => check = 'C',
            'm' => merge = true,
            'S', 'T', 131, 132, 133, 134 => {},
            'o' => output = it.val,
            's' => ctx.stable = true,
            't' => {
                const v = it.val.?;
                if (v.len == 2 and v[0] == '\\' and v[1] == '0') {
                    ctx.delimiter = 0;
                } else if (v.len != 1) {
                    u.errf("sort: multi-character tab '{s}'\n", .{v});
                    return 2;
                } else ctx.delimiter = v[0];
            },
            'u' => ctx.unique = true,
            'z' => rec_delim = 0,
            'k' => keys.push(parseKey(it.val.?) orelse {
                u.errf("sort: invalid number at field start: invalid count at start of '{s}'\n", .{it.val.?});
                return 2;
            }),
            135 => files0 = it.val,
            136 => random_source = it.val,
            200 => {
                u.out("Usage: sort [OPTION]... [FILE]...\nWrite sorted concatenation of all FILE(s) to standard output.\n");
                return 0;
            },
            201 => {
                u.out("sort (cmdbox)\n");
                return 0;
            },
            else => {},
        }
    }
    ctx.keys = keys.items;
    if (ctx.flags.random) {
        if (random_source) |rs| {
            const d = input.read(rs, false) orelse return 2;
            for (d[0..@min(16, d.len)], 0..) |b, i| ctx.salt[i] = b;
        } else _ = linux.getrandom(&ctx.salt, ctx.salt.len, 0);
    }
    var files = p.operands;
    if (files0) |f0| {
        if (files.items.len > 0) {
            u.errf("sort: extra operand '{s}' not allowed with --files0-from\n", .{files.items[0]});
            return 2;
        }
        const d = (if (std.mem.eql(u8, f0, "-")) readFd(0) else input.read(f0, false)) orelse return 2;
        var it = std.mem.splitScalar(u8, d, 0);
        while (it.next()) |nm| if (nm.len > 0) files.push(nm);
    }
    if (files.items.len == 0) files.push("-");
    var lines = u.Vec([]const u8).init(u.alloc);
    var file_ends = u.Vec(usize).init(u.alloc);
    var status: u8 = 0;
    for (files.items) |name| {
        var data: []u8 = undefined;
        if (std.mem.eql(u8, name, "-")) {
            data = readFd(0) orelse {
                u.err("sort: read failed: -: Input/output error\n");
                return 2;
            };
        } else {
            const rc = linux.open(u.zstr(name), .{ .ACCMODE = .RDONLY }, 0);
            if (!u.ok(rc)) {
                u.errf("sort: cannot read: {s}: {s}\n", .{ name, u.strerr(u.errno(rc)) });
                return 2;
            }
            const d = readFd(@intCast(rc));
            _ = linux.close(@intCast(rc));
            data = d orelse {
                u.errf("sort: read failed: {s}: Is a directory\n", .{name});
                return 2;
            };
        }
        const records = input.records(data, rec_delim);
        for (records.items) |record| lines.push(record.text);
        file_ends.push(lines.items.len);
    }
    if (check != 0) {
        var idx: usize = 1;
        while (idx < lines.items.len) : (idx += 1) {
            const order = compare(ctx, lines.items[idx - 1], lines.items[idx], true);
            if (order == .gt or (ctx.unique and order == .eq)) {
                if (check == 'c') u.errf("sort: {s}:{d}: disorder: {s}\n", .{ if (files.items.len > 0) files.items[0] else "-", idx + 1, lines.items[idx] });
                return 1;
            }
        }
        return 0;
    }
    if (merge) {
        // -m: k-way merge of inputs that are assumed to be sorted already; ties go to the earlier file
        const nf = file_ends.items.len;
        const pos = u.alloc.alloc(usize, nf) catch return 2;
        for (pos, 0..) |*pp, k| pp.* = if (k == 0) 0 else file_ends.items[k - 1];
        var merged = u.Vec([]const u8).init(u.alloc);
        while (true) {
            var best: ?usize = null;
            for (0..nf) |k| {
                if (pos[k] >= file_ends.items[k]) continue;
                if (best == null or compare(ctx, lines.items[pos[k]], lines.items[pos[best.?]], true) == .lt) best = k;
            }
            const bi = best orelse break;
            merged.push(lines.items[pos[bi]]);
            pos[bi] += 1;
        }
        lines = merged;
    } else std.mem.sort([]const u8, lines.items, ctx, struct {
        fn less(context: Context, a: []const u8, b: []const u8) bool {
            return compare(context, a, b, true) == .lt;
        }
    }.less);
    var dest_fd: i32 = 1;
    if (output) |name| {
        const rc = linux.open(u.zstr(name), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666);
        if (!u.ok(rc)) {
            u.errf("sort: open failed: {s}: {s}\n", .{ name, u.strerr(u.errno(rc)) });
            return 2;
        }
        dest_fd = @intCast(rc);
    }
    var out = u.Vec(u8).init(u.alloc);
    var previous: ?[]const u8 = null;
    for (lines.items) |line| {
        if (ctx.unique and previous != null and compare(ctx, previous.?, line, false) == .eq) continue;
        out.pushSlice(line);
        out.push(rec_delim);
        previous = line;
        if (out.items.len > 1 << 16) {
            _ = (u.File{ .fd = dest_fd }).write(out.items);
            out.items.len = 0;
        }
    }
    if (!(u.File{ .fd = dest_fd }).write(out.items)) status = 2;
    if (dest_fd != 1) _ = linux.close(dest_fd);
    return status;
}
