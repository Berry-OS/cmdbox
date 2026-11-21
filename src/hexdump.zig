// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// hexdump - util-linux/BSD compatible: -b -c -C -d -o -x -v -n -s -e -f, '*' squeezing
const std = @import("std");
const u = @import("util.zig");
const g = @import("getopt.zig");
const c = @cImport({
    @cInclude("stdio.h");
});

const Kind = enum { lit, int_s, int_u, flt, chr, str, addr, addr_end, c_name, c_print, c_ascii };

const Item = struct {
    kind: Kind,
    text: []const u8 = "", // literal text, or printf spec without the length modifier/conversion
    conv: u8 = 0, // conversion char
    bytes: usize = 0,
    radix: u8 = 'x', // for addr
    width: usize = 0, // for _c/_p/_u and blank padding
};

const Unit = struct { reps: usize = 1, items: []Item };

var fss = u.Vec([]Unit).init(u.alloc);

fn isWs(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n';
}

fn natural(conv: u8) usize {
    return switch (conv) {
        'd', 'i', 'o', 'u', 'x', 'X' => 4,
        'e', 'E', 'f', 'F', 'g', 'G' => 8,
        'c' => 1,
        else => 1,
    };
}

fn parseFormat(text: []const u8) bool {
    var units = u.Vec(Unit).init(u.alloc);
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and isWs(text[i])) i += 1;
        if (i >= text.len) break;
        var reps: usize = 1;
        var bytes: ?usize = null;
        if (std.ascii.isDigit(text[i])) {
            var n: usize = 0;
            while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) n = n * 10 + (text[i] - '0');
            if (i < text.len and text[i] == '/') {
                reps = n;
                i += 1;
                var m: usize = 0;
                var have = false;
                while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
                    m = m * 10 + (text[i] - '0');
                    have = true;
                }
                if (have) bytes = m;
            } else {
                bytes = n;
            }
        } else if (text[i] == '/') {
            i += 1;
            var m: usize = 0;
            while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) m = m * 10 + (text[i] - '0');
            bytes = m;
        }
        while (i < text.len and isWs(text[i])) i += 1;
        if (i >= text.len or text[i] != '"') {
            u.err("hexdump: bad format {}\n");
            return false;
        }
        i += 1;
        var items = u.Vec(Item).init(u.alloc);
        var lit = u.Vec(u8).init(u.alloc);
        var nconv: usize = 0;
        var closed = false;
        while (i < text.len) {
            const ch = text[i];
            if (ch == '"') {
                i += 1;
                closed = true;
                break;
            }
            if (ch == '\\' and i + 1 < text.len) {
                i += 1;
                lit.push(switch (text[i]) {
                    'n' => '\n',
                    't' => '\t',
                    'a' => 7,
                    'b' => 8,
                    'f' => 12,
                    'r' => '\r',
                    'v' => 11,
                    '0' => 0,
                    else => text[i],
                });
                i += 1;
                continue;
            }
            if (ch != '%') {
                lit.push(ch);
                i += 1;
                continue;
            }
            if (i + 1 < text.len and text[i + 1] == '%') {
                lit.push('%');
                i += 2;
                continue;
            }
            // conversion
            if (lit.items.len > 0) {
                items.push(.{ .kind = .lit, .text = lit.items });
                lit = u.Vec(u8).init(u.alloc);
            }
            var j = i + 1;
            while (j < text.len and std.mem.indexOfScalar(u8, "-+ #0", text[j]) != null) j += 1;
            var width: usize = 0;
            var jw = j;
            while (jw < text.len and std.ascii.isDigit(text[jw])) : (jw += 1) width = width * 10 + (text[jw] - '0');
            var prec: ?usize = null;
            var jp = jw;
            if (jp < text.len and text[jp] == '.') {
                jp += 1;
                var pv: usize = 0;
                while (jp < text.len and std.ascii.isDigit(text[jp])) : (jp += 1) pv = pv * 10 + (text[jp] - '0');
                prec = pv;
            }
            const spec = text[i..jp]; // "%" flags width .prec
            if (jp >= text.len) return false;
            var it = Item{ .kind = .lit, .text = spec, .width = width };
            if (text[jp] == '_') {
                if (jp + 1 >= text.len) return false;
                const k = text[jp + 1];
                jp += 2;
                switch (k) {
                    'a', 'A' => {
                        if (jp >= text.len or std.mem.indexOfScalar(u8, "dox", text[jp]) == null) return false;
                        it.kind = if (k == 'a') .addr else .addr_end;
                        it.radix = text[jp];
                        jp += 1;
                    },
                    'c' => it.kind = .c_name,
                    'p' => it.kind = .c_print,
                    'u' => it.kind = .c_ascii,
                    else => return false,
                }
                it.bytes = 1;
            } else {
                const cv = text[jp];
                jp += 1;
                it.conv = cv;
                switch (cv) {
                    'd', 'i' => it.kind = .int_s,
                    'o', 'u', 'x', 'X' => it.kind = .int_u,
                    'e', 'E', 'f', 'F', 'g', 'G' => it.kind = .flt,
                    'c' => it.kind = .chr,
                    's' => it.kind = .str,
                    else => return false,
                }
                it.bytes = natural(cv);
                if (cv == 's') it.bytes = prec orelse 0;
                nconv += 1;
            }
            items.push(it);
            i = jp;
        }
        if (!closed) return false;
        if (lit.items.len > 0) items.push(.{ .kind = .lit, .text = lit.items });
        if (bytes) |b| {
            // an explicit byte count applies to a single conversion
            var seen: usize = 0;
            for (items.items) |*it| {
                if (it.kind != .lit) {
                    seen += 1;
                    if (seen == 1 and nconv == 1) it.bytes = b;
                }
            }
        }
        units.push(.{ .reps = reps, .items = items.items });
    }
    fss.push(units.items);
    return true;
}

fn isEndFs(fs: []Unit) bool {
    for (fs) |un| for (un.items) |it| if (it.kind == .addr_end) return true;
    return false;
}

fn unitBytes(un: Unit) usize {
    var t: usize = 0;
    for (un.items) |it| if (it.kind != .lit and it.kind != .addr and it.kind != .addr_end) {
        t += it.bytes;
    };
    return t * un.reps;
}

var addr_out: u64 = 0;

fn emitSpec(o: *u.Vec(u8), spec: []const u8, mod: []const u8, conv: u8, comptime T: type, v: T) void {
    var fmt: [64]u8 = undefined;
    const f = std.fmt.bufPrintZ(&fmt, "{s}{s}{c}", .{ spec, mod, conv }) catch return;
    var buf: [256]u8 = undefined;
    const n = c.snprintf(&buf, buf.len, f.ptr, v);
    if (n > 0) for (buf[0..@min(@as(usize, @intCast(n)), buf.len - 1)]) |ch| o.push(ch);
}

fn pad(o: *u.Vec(u8), s: []const u8, width: usize, left: bool) void {
    if (!left) {
        var k = s.len;
        while (k < width) : (k += 1) o.push(' ');
    }
    for (s) |ch| o.push(ch);
    if (left) {
        var k = s.len;
        while (k < width) : (k += 1) o.push(' ');
    }
}

fn leftFlag(spec: []const u8) bool {
    return std.mem.indexOfScalar(u8, spec, '-') != null;
}

const names = [_][]const u8{ "nul", "soh", "stx", "etx", "eot", "enq", "ack", "bel", "bs", "ht", "lf", "vt", "ff", "cr", "so", "si", "dle", "dc1", "dc2", "dc3", "dc4", "nak", "syn", "etb", "can", "em", "sub", "esc", "fs", "gs", "rs", "us" };

fn readInt(data: []const u8, n: usize) u64 {
    var v: u64 = 0;
    var k: usize = 0;
    while (k < n and k < 8) : (k += 1) v |= @as(u64, if (k < data.len) data[k] else 0) << @intCast(8 * k);
    return v;
}

fn printAddr(o: *u.Vec(u8), it: Item, addr: u64) void {
    const mod = "ll";
    const conv = it.radix;
    emitSpec(o, it.text, mod, conv, u64, addr);
}

fn render(o: *u.Vec(u8), un: Unit, data: []const u8, have: usize, base_off: *usize, line_addr: u64, first: bool) void {
    _ = first;
    var rep: usize = 0;
    while (rep < un.reps) : (rep += 1) {
        for (un.items) |it| {
            switch (it.kind) {
                .lit => for (it.text) |ch| o.push(ch),
                .addr => printAddr(o, it, line_addr),
                .addr_end => {},
                else => {
                    const start = base_off.*;
                    base_off.* += it.bytes;
                    const avail = if (start >= have) 0 else @min(it.bytes, have - start);
                    if (avail == 0 and it.bytes > 0) {
                        // out of data: blank-fill numeric conversions, print nothing for characters
                        switch (it.kind) {
                            .c_name, .c_print, .c_ascii, .chr, .str => {},
                            else => {
                                var tv = u.Vec(u8).init(u.alloc);
                                const zero = [_]u8{0} ** 8;
                                renderOne(&tv, it, zero[0..it.bytes]);
                                var k: usize = 0;
                                while (k < tv.items.len) : (k += 1) o.push(' ');
                            },
                        }
                        continue;
                    }
                    renderOne(o, it, data[@min(start, data.len)..@min(start + it.bytes, data.len)]);
                },
            }
        }
    }
}

fn renderOne(o: *u.Vec(u8), it: Item, d: []const u8) void {
    switch (it.kind) {
        .int_s => {
            const raw = readInt(d, it.bytes);
            const bits: u7 = @intCast(it.bytes * 8);
            var sv: i64 = @bitCast(raw);
            if (bits < 64) {
                const sh: u6 = @intCast(64 - bits);
                sv = (sv << sh) >> sh;
            }
            emitSpec(o, it.text, "ll", it.conv, i64, sv);
        },
        .int_u => emitSpec(o, it.text, "ll", it.conv, u64, readInt(d, it.bytes)),
        .flt => {
            var buf = [_]u8{0} ** 8;
            @memcpy(buf[0..d.len], d);
            if (it.bytes == 4) {
                const f: f32 = @bitCast(buf[0..4].*);
                emitSpec(o, it.text, "", it.conv, f64, f);
            } else {
                const f: f64 = @bitCast(buf);
                emitSpec(o, it.text, "", it.conv, f64, f);
            }
        },
        .chr => {
            var s: [1]u8 = .{if (d.len > 0) d[0] else 0};
            pad(o, &s, it.width, leftFlag(it.text));
        },
        .str => {
            var end = d.len;
            if (std.mem.indexOfScalar(u8, d, 0)) |z| end = z;
            pad(o, d[0..end], it.width, leftFlag(it.text));
        },
        .c_print => {
            const ch = if (d.len > 0) d[0] else 0;
            var s: [1]u8 = .{if (ch >= 0x20 and ch < 0x7f) ch else '.'};
            pad(o, &s, it.width, leftFlag(it.text));
        },
        .c_name => {
            const ch = if (d.len > 0) d[0] else 0;
            var tmp: [8]u8 = undefined;
            const s: []const u8 = switch (ch) {
                0 => "\\0",
                7 => "\\a",
                8 => "\\b",
                9 => "\\t",
                10 => "\\n",
                11 => "\\v",
                12 => "\\f",
                13 => "\\r",
                else => if (ch >= 0x20 and ch < 0x7f) blk: {
                    tmp[0] = ch;
                    break :blk tmp[0..1];
                } else std.fmt.bufPrint(&tmp, "{o:0>3}", .{ch}) catch "",
            };
            pad(o, s, it.width, leftFlag(it.text));
        },
        .c_ascii => {
            const ch = if (d.len > 0) d[0] else 0;
            var tmp: [8]u8 = undefined;
            const s: []const u8 = if (ch < 32) names[ch] else if (ch == 0x7f) "del" else blk: {
                tmp[0] = ch;
                break :blk tmp[0..1];
            };
            pad(o, s, it.width, leftFlag(it.text));
        },
        else => {},
    }
}


fn stdFormat(kind: u8) void {
    const f = switch (kind) {
        'b' => "\"%07.7_Ax\\n\"\n\"%07.7_ax \" 16/1 \"%03o \" \"\\n\"",
        'c' => "\"%07.7_Ax\\n\"\n\"%07.7_ax \" 16/1 \"%3_c \" \"\\n\"",
        'C' => "\"%08.8_Ax\\n\"\n\"%08.8_ax  \" 8/1 \"%02x \" \" \" 8/1 \"%02x \"\n\" |\" 16/1 \"%_p\" \"|\\n\"",
        'd' => "\"%07.7_Ax\\n\"\n\"%07.7_ax \" 8/2 \"  %05u \" \"\\n\"",
        'o' => "\"%07.7_Ax\\n\"\n\"%07.7_ax \" 8/2 \" %06o \" \"\\n\"",
        'x' => "\"%07.7_Ax\\n\"\n\"%07.7_ax \" 8/2 \"   %04x \" \"\\n\"",
        else => "\"%07.7_Ax\\n\"\n\"%07.7_ax \" 8/2 \"%04x \" \"\\n\"",
    };
    var it = std.mem.splitScalar(u8, f, '\n');
    while (it.next()) |ln| _ = parseFormat(ln);
}

fn parseNum(s: []const u8) ?u64 {
    var v = s;
    var mult: u64 = 1;
    if (v.len > 1 and !std.mem.startsWith(u8, v, "0x") and !std.mem.startsWith(u8, v, "0X")) {
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
        .{ .name = "one-byte-octal", .key = 'b' },
        .{ .name = "one-byte-char", .key = 'c' },
        .{ .name = "canonical", .key = 'C' },
        .{ .name = "two-bytes-decimal", .key = 'd' },
        .{ .name = "two-bytes-octal", .key = 'o' },
        .{ .name = "two-bytes-hex", .key = 'x' },
        .{ .name = "no-squeezing", .key = 'v' },
        .{ .name = "length", .key = 'n', .arg = .req },
        .{ .name = "skip", .key = 's', .arg = .req },
        .{ .name = "format", .key = 'e', .arg = .req },
        .{ .name = "format-file", .key = 'f', .arg = .req },
        .{ .name = "color", .key = 130, .arg = .opt },
        .{ .name = "help", .key = 'h' },
        .{ .name = "version", .key = 'V' },
    };
    var p = g.Parser.init("hexdump", args, &opts);
    var squeeze = true;
    var limit: ?u64 = null;
    var skip: u64 = 0;
    var std_kinds = u.Vec(u8).init(u.alloc);
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'b', 'c', 'C', 'd', 'o', 'x' => std_kinds.push(it.key),
            'v' => squeeze = false,
            'n' => limit = parseNum(it.val.?) orelse {
                u.errf("hexdump: invalid length: {s}\n", .{it.val.?});
                return 1;
            },
            's' => skip = parseNum(it.val.?) orelse {
                u.errf("hexdump: invalid offset: {s}\n", .{it.val.?});
                return 1;
            },
            'e' => if (!parseFormat(it.val.?)) {
                u.errf("hexdump: bad format string\n", .{});
                return 1;
            },
            'f' => {
                var f = u.File.open(it.val.?, .{ .ACCMODE = .RDONLY }, 0) orelse {
                    u.errf("hexdump: {s}: No such file or directory\n", .{it.val.?});
                    return 1;
                };
                var lines = u.Vec([]const u8).init(u.alloc);
                u.readAllLines(&f, &lines);
                f.close();
                for (lines.items) |ln| {
                    const t = std.mem.trim(u8, ln, " \t");
                    if (t.len == 0 or t[0] == '#') continue;
                    if (!parseFormat(t)) {
                        u.err("hexdump: bad format string\n");
                        return 1;
                    }
                }
            },
            'h' => {
                u.out("Usage:\n hexdump [options] <file>...\n\nDisplay file contents in hexadecimal, decimal, octal, or ascii.\n");
                return 0;
            },
            'V' => {
                u.out("hexdump (cmdbox)\n");
                return 0;
            },
            else => {},
        }
    }
    for (std_kinds.items) |k| stdFormat(k);
    if (fss.items.len == 0) stdFormat(0);

    // block size = bytes consumed by one pass of all units
    var blocksize: usize = 0;
    for (fss.items) |fs| {
        var t: usize = 0;
        for (fs) |un| t += unitBytes(un);
        blocksize = @max(blocksize, t);
    }
    if (blocksize == 0) blocksize = 16;

    // gather input
    var files = p.operands;
    if (files.items.len == 0) files.push("-");
    var rc: u8 = 0;
    var data = u.Vec(u8).init(u.alloc);
    for (files.items) |name| {
        var f: u.File = undefined;
        const is_stdin = std.mem.eql(u8, name, "-");
        if (is_stdin) f = .{ .fd = 0 } else f = u.File.open(name, .{ .ACCMODE = .RDONLY }, 0) orelse {
            const e = std.os.linux.open(u.zstr(name), .{ .ACCMODE = .RDONLY }, 0);
            u.errf("hexdump: {s}: {s}\n", .{ name, u.strerr(u.errno(e)) });
            rc = 1;
            continue;
        };
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = f.read(&buf);
            if (n == 0) break;
            for (buf[0..n]) |b| data.push(b);
            if (limit != null and data.items.len >= skip + limit.?) break;
        }
        if (!is_stdin) f.close();
    }
    var all = data.items;
    if (skip >= all.len) {
        if (data.items.len == 0 and rc != 0) return rc;
        all = all[all.len..];
    } else all = all[@intCast(skip)..];
    if (limit) |l| if (all.len > l) {
        all = all[0..@intCast(l)];
    };

    var o = u.Vec(u8).init(u.alloc);
    var off: usize = 0;
    var prev: ?[]const u8 = null;
    var squeezing = false;
    const first_pass = true;
    if (all.len == 0) {
        // nothing to dump: hexdump prints nothing
        return rc;
    }
    while (off < all.len) {
        const end = @min(off + blocksize, all.len);
        const chunk = all[off..end];
        const full = chunk.len == blocksize;
        if (squeeze and full and prev != null and std.mem.eql(u8, prev.?, chunk)) {
            if (!squeezing) {
                o.push('*');
                o.push('\n');
                squeezing = true;
            }
            off = end;
            continue;
        }
        squeezing = false;
        prev = if (full) chunk else null;
        for (fss.items) |fs| {
            if (isEndFs(fs)) continue;
            var bo: usize = 0;
            for (fs) |un| render(&o, un, chunk, chunk.len, &bo, skip + off, first_pass);
        }
        off = end;
        if (o.items.len > 32768) {
            u.out(o.items);
            o.items.len = 0;
        }
    }
    // end address (_A)
    for (fss.items) |fs| {
        if (!isEndFs(fs)) continue;
        for (fs) |un| {
            for (un.items) |it| switch (it.kind) {
                .addr_end => printAddr(&o, it, skip + all.len),
                .lit => for (it.text) |ch| o.push(ch),
                else => {},
            };
        }
    }
    u.out(o.items);
    return rc;
}
