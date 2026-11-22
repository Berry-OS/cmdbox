// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// od - GNU coreutils: -A -j -N -t (a c d f o u x, sizes, z) -v -w -b -c -d -f -h -i -l -o -s -x --endian
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});

const Kind = enum { a, c, d, u, o, x, f };

const Spec = struct { kind: Kind, size: usize, text: bool = false };

const char_names = [_][]const u8{ "nul", "soh", "stx", "etx", "eot", "enq", "ack", "bel", "bs", "ht", "nl", "vt", "ff", "cr", "so", "si", "dle", "dc1", "dc2", "dc3", "dc4", "nak", "syn", "etb", "can", "em", "sub", "esc", "fs", "gs", "rs", "us", "sp" };

fn valueWidth(s: Spec) usize {
    return switch (s.kind) {
        .a, .c => 3,
        .o => switch (s.size) {
            1 => 3,
            2 => 6,
            4 => 11,
            else => 22,
        },
        .x => s.size * 2,
        .u => switch (s.size) {
            1 => 3,
            2 => 5,
            4 => 10,
            else => 20,
        },
        .d => switch (s.size) {
            1 => 4,
            2 => 6,
            4 => 11,
            else => 20,
        },
        .f => switch (s.size) {
            4 => 15,
            8 => 24,
            else => 40,
        },
    };
}

fn readInt(data: []const u8, size: usize, big: bool) u64 {
    var v: u64 = 0;
    var k: usize = 0;
    while (k < size) : (k += 1) {
        const b: u64 = if (k < data.len) data[k] else 0;
        if (big) v = (v << 8) | b else v |= b << @intCast(8 * k);
    }
    return v;
}

fn fmtValue(s: Spec, data: []const u8, big: bool, o: *u.Vec(u8)) void {
    var tmp: [96]u8 = undefined;
    switch (s.kind) {
        .a => {
            const b = data[0] & 0x7f;
            if (b <= 32) o.pushSlice(char_names[b]) else if (b == 127) o.pushSlice("del") else o.push(b);
        },
        .c => {
            const b = data[0];
            const t: []const u8 = switch (b) {
                0 => "\\0",
                7 => "\\a",
                8 => "\\b",
                9 => "\\t",
                10 => "\\n",
                11 => "\\v",
                12 => "\\f",
                13 => "\\r",
                else => if (b >= 32 and b < 127) &[_]u8{b} else (std.fmt.bufPrint(&tmp, "{o:0>3}", .{b}) catch ""),
            };
            if (b >= 32 and b < 127) o.push(b) else o.pushSlice(t);
        },
        .o => {
            const v = readInt(data, s.size, big);
            o.pushSlice(std.fmt.bufPrint(&tmp, "{o:0>[1]}", .{ v, valueWidth(s) }) catch "");
        },
        .x => {
            const v = readInt(data, s.size, big);
            o.pushSlice(std.fmt.bufPrint(&tmp, "{x:0>[1]}", .{ v, valueWidth(s) }) catch "");
        },
        .u => {
            const v = readInt(data, s.size, big);
            o.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{v}) catch "");
        },
        .d => {
            const raw = readInt(data, s.size, big);
            const bits: u7 = @intCast(s.size * 8);
            var sv: i64 = @bitCast(raw);
            if (bits < 64) {
                const sh: u6 = @intCast(64 - bits);
                sv = (sv << sh) >> sh;
            }
            o.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{sv}) catch "");
        },
        .f => {
            const raw = readInt(data, s.size, big);
            var f: f64 = 0;
            var prec: c_int = 17;
            if (s.size == 4) {
                const f32v: f32 = @bitCast(@as(u32, @truncate(raw)));
                f = f32v;
                prec = 9;
            } else f = @bitCast(raw);
            var buf: [64]u8 = undefined;
            var p: c_int = 1;
            var n: c_int = 0;
            while (p <= prec) : (p += 1) {
                n = c.snprintf(&buf, buf.len, "%.*g", p, f);
                if (n <= 0) break;
                buf[@intCast(n)] = 0;
                if (s.size == 4) {
                    const back = c.strtof(@ptrCast(&buf), null);
                    if (back == @as(f32, @floatCast(f))) break;
                } else {
                    const back = c.strtod(@ptrCast(&buf), null);
                    if (back == f or (std.math.isNan(f) and std.math.isNan(back))) break;
                }
            }
            if (n > 0) o.pushSlice(buf[0..@intCast(n)]);
        },
    }
}

fn parseType(t: []const u8, specs: *u.Vec(Spec)) bool {
    var i: usize = 0;
    while (i < t.len) {
        const ch = t[i];
        i += 1;
        var kind: Kind = undefined;
        var size: usize = 0;
        switch (ch) {
            'a', 'c' => {
                var text = false;
                if (i < t.len and t[i] == 'z') {
                    text = true;
                    i += 1;
                }
                specs.push(.{ .kind = if (ch == 'a') .a else .c, .size = 1, .text = text });
                continue;
            },
            'd' => kind = .d,
            'o' => kind = .o,
            'u' => kind = .u,
            'x' => kind = .x,
            'f' => kind = .f,
            else => return false,
        }
        // size: digits or C/S/I/L (F/D/L for floats)
        if (i < t.len and std.ascii.isDigit(t[i])) {
            var v: usize = 0;
            while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) v = v * 10 + (t[i] - '0');
            size = v;
        } else if (i < t.len and std.mem.indexOfScalar(u8, "CSILFD", t[i]) != null) {
            const l = t[i];
            i += 1;
            size = switch (l) {
                'C' => 1,
                'S' => 2,
                'I' => 4,
                'L' => if (kind == .f) 16 else 8,
                'F' => 4,
                'D' => 8,
                else => 4,
            };
        } else size = if (kind == .f) 8 else 4;
        if (kind == .f) {
            if (size != 4 and size != 8 and size != 16) return false;
            if (size == 16) size = 8;
        } else if (size != 1 and size != 2 and size != 4 and size != 8) return false;
        var text = false;
        if (i < t.len and t[i] == 'z') {
            text = true;
            i += 1;
        }
        specs.push(.{ .kind = kind, .size = size, .text = text });
    }
    return true;
}

fn parseOffset(s: []const u8) ?u64 {
    var v = s;
    var mult: u64 = 1;
    if (std.mem.startsWith(u8, v, "0x") or std.mem.startsWith(u8, v, "0X")) {
        // hex offsets may not take size suffixes except b
    } else if (v.len > 1) {
        switch (v[v.len - 1]) {
            'b' => {
                mult = 512;
                v = v[0 .. v.len - 1];
            },
            'k' => {
                mult = 1024;
                v = v[0 .. v.len - 1];
            },
            'm' => {
                mult = 1 << 20;
                v = v[0 .. v.len - 1];
            },
            else => {},
        }
    }
    const n = std.fmt.parseInt(u64, v, 0) catch return null;
    return n * mult;
}

pub fn run(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "address-radix", .key = 'A', .arg = .req },
        .{ .name = "skip-bytes", .key = 'j', .arg = .req },
        .{ .name = "read-bytes", .key = 'N', .arg = .req },
        .{ .name = "format", .key = 't', .arg = .req },
        .{ .name = "output-duplicates", .key = 'v' },
        .{ .name = "width", .key = 'w', .arg = .opt },
        .{ .name = "strings", .key = 'S', .arg = .opt },
        .{ .name = "endian", .key = 130, .arg = .req },
        .{ .key = 'a' },
        .{ .key = 'b' },
        .{ .key = 'c' },
        .{ .key = 'd' },
        .{ .key = 'f' },
        .{ .key = 'h' },
        .{ .key = 'i' },
        .{ .key = 'l' },
        .{ .key = 'o' },
        .{ .key = 's' },
        .{ .key = 'x' },
        .{ .name = "traditional", .key = 131 },
        .{ .name = "help", .key = 200 },
        .{ .name = "version", .key = 201 },
    };
    var p = g.Parser.init("od", args, &opts);
    var radix: u8 = 'o';
    var skip: u64 = 0;
    var limit: ?u64 = null;
    var specs = u.Vec(Spec).init(u.alloc);
    var verbose = false;
    var width: usize = 16;
    var big = false;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'A' => {
                const v = it.val.?;
                if (v.len != 1 or std.mem.indexOfScalar(u8, "doxn", v[0]) == null) {
                    u.errf("od: invalid output address radix '{s}'; it must be one character from [doxn]\n", .{v});
                    return 1;
                }
                radix = v[0];
            },
            'j' => skip = parseOffset(it.val.?) orelse {
                u.errf("od: invalid skip argument '{s}'\n", .{it.val.?});
                return 1;
            },
            'N' => limit = parseOffset(it.val.?) orelse {
                u.errf("od: invalid limit argument '{s}'\n", .{it.val.?});
                return 1;
            },
            't' => if (!parseType(it.val.?, &specs)) {
                u.errf("od: invalid type string '{s}'\n", .{it.val.?});
                return 1;
            },
            'v' => verbose = true,
            'w' => width = if (it.val) |v| (std.fmt.parseInt(usize, v, 10) catch {
                u.errf("od: invalid -w argument '{s}'\n", .{v});
                return 1;
            }) else 32,
            'S' => {},
            130 => big = std.mem.eql(u8, it.val.?, "big"),
            'a' => _ = parseType("a", &specs),
            'b' => _ = parseType("o1", &specs),
            'c' => _ = parseType("c", &specs),
            'd' => _ = parseType("u2", &specs),
            'f' => _ = parseType("fF", &specs),
            'h' => _ = parseType("x2", &specs),
            'i' => _ = parseType("dI", &specs),
            'l' => _ = parseType("dL", &specs),
            'o' => _ = parseType("o2", &specs),
            's' => _ = parseType("d2", &specs),
            'x' => _ = parseType("x2", &specs),
            131 => {},
            200 => {
                u.out("Usage: od [OPTION]... [FILE]...\n  or:  od [-abcdfilosx]... [FILE] [[+]OFFSET[.][b]]\nWrite an unambiguous representation, octal bytes by default, of FILE to standard output.\n");
                return 0;
            },
            201 => {
                u.out("od (cmdbox)\n");
                return 0;
            },
            else => {},
        }
    }
    if (specs.items.len == 0) specs.push(.{ .kind = .o, .size = 2 });
    // line width must be a multiple of the largest element
    var maxsz: usize = 1;
    for (specs.items) |s| maxsz = @max(maxsz, s.size);
    if (width % maxsz != 0) {
        u.errf("od: warning: invalid width {d}; using {d} instead\n", .{ width, maxsz });
        width = maxsz;
    }
    if (width == 0) width = 16;
    // read the input
    var data = u.Vec(u8).init(u.alloc);
    var files = p.operands;
    if (files.items.len == 0) files.push("-");
    var rc: u8 = 0;
    for (files.items) |name| {
        var fd: i32 = 0;
        if (!std.mem.eql(u8, name, "-")) {
            const r = linux.open(u.zstr(name), .{ .ACCMODE = .RDONLY }, 0);
            if (!u.ok(r)) {
                u.errf("od: {s}: {s}\n", .{ name, u.strerr(u.errno(r)) });
                rc = 1;
                continue;
            }
            fd = @intCast(r);
        }
        var buf: [65536]u8 = undefined;
        while (true) {
            const r = linux.read(fd, &buf, buf.len);
            if (u.errno(r) == .INTR) continue;
            if (!u.ok(r) or r == 0) break;
            data.pushSlice(buf[0..r]);
            if (limit != null and data.items.len >= skip + limit.?) break;
        }
        if (fd != 0) _ = linux.close(fd);
    }
    var all: []const u8 = data.items;
    if (skip > all.len) {
        u.err("od: cannot skip past end of combined input\n");
        return 1;
    }
    all = all[@intCast(skip)..];
    if (limit) |l| if (all.len > l) {
        all = all[0..@intCast(l)];
    };
    // field geometry
    var max_total: usize = 0;
    for (specs.items) |s| {
        const n = width / s.size;
        max_total = @max(max_total, n * (valueWidth(s) + 1));
    }
    var o = u.Vec(u8).init(u.alloc);
    const addrW: usize = switch (radix) {
        'x' => 6,
        'n' => 0,
        else => 7,
    };
    const addr = struct {
        fn put(out: *u.Vec(u8), rdx: u8, w: usize, v: u64) void {
            if (rdx == 'n') return;
            var tmp: [32]u8 = undefined;
            const s = switch (rdx) {
                'x' => std.fmt.bufPrint(&tmp, "{x:0>[1]}", .{ v, w }) catch "",
                'd' => std.fmt.bufPrint(&tmp, "{d:0>[1]}", .{ v, w }) catch "",
                else => std.fmt.bufPrint(&tmp, "{o:0>[1]}", .{ v, w }) catch "",
            };
            out.pushSlice(s);
        }
    }.put;
    var off: usize = 0;
    var prev: ?[]const u8 = null;
    var squeezing = false;
    while (off < all.len) {
        const end = @min(all.len, off + width);
        const chunk = all[off..end];
        if (!verbose and prev != null and chunk.len == width and std.mem.eql(u8, prev.?, chunk)) {
            if (!squeezing) {
                o.pushSlice("*\n");
                squeezing = true;
            }
            off = end;
            continue;
        }
        squeezing = false;
        prev = if (chunk.len == width) chunk else null;
        for (specs.items, 0..) |s, si| {
            if (si == 0) addr(&o, radix, addrW, skip + off) else o.pushN(' ', addrW);
            const nfull = width / s.size;
            const n = (chunk.len + s.size - 1) / s.size;
            const w = valueWidth(s);
            const pad = (max_total - nfull * (w + 1)) / nfull;
            var k: usize = 0;
            while (k < n) : (k += 1) {
                const lo = k * s.size;
                const hi = @min(chunk.len, lo + s.size);
                var vb = u.Vec(u8).init(u.alloc);
                fmtValue(s, chunk[lo..hi], big, &vb);
                o.push(' ');
                if (vb.items.len < w + pad) o.pushN(' ', w + pad - vb.items.len);
                o.pushSlice(vb.items);
            }
            if (s.text) {
                // pad the unused fields, then the character column
                var m = n;
                while (m < nfull) : (m += 1) o.pushN(' ', w + pad + 1);
                o.pushSlice("  >");
                for (chunk) |b| o.push(if (b >= 32 and b < 127) b else '.');
                o.push('<');
            }
            o.push('\n');
        }
        off = end;
    }
    if (radix != 'n') {
        addr(&o, radix, addrW, skip + all.len);
        o.push('\n');
    }
    u.out(o.items);
    return rc;
}
