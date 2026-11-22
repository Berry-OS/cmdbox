// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// cpio - GNU cpio compatible: -o -i -p -t, formats newc crc odc bin, -d -m -u -v -V -0 -L -R -F -I -O -H -c -f -n -B -C --quiet ...
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const dt = @import("datetime.zig");
const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("grp.h");
    @cInclude("unistd.h");
});

const Format = enum { newc, crc, odc, bin, auto };

const Hdr = struct {
    ino: u64 = 0,
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    nlink: u32 = 1,
    mtime: u64 = 0,
    size: u64 = 0,
    dev_maj: u32 = 0,
    dev_min: u32 = 0,
    rdev_maj: u32 = 0,
    rdev_min: u32 = 0,
    name: []const u8 = "",
    check: u32 = 0,
};

const Cfg = struct {
    mode: u8 = 0, // 'o' 'i' 'p'
    list: bool = false,
    format: Format = .auto,
    verbose: bool = false,
    dot: bool = false,
    mkdirs: bool = false,
    preserve_mtime: bool = false,
    unconditional: bool = false,
    null_names: bool = false,
    deref: bool = false,
    reset_atime: bool = false,
    nonmatching: bool = false,
    numeric: bool = false,
    quiet: bool = false,
    no_owner: bool = false,
    link: bool = false,
    no_abs: bool = false,
    owner_uid: ?u32 = null,
    owner_gid: ?u32 = null,
    archive: ?[]const u8 = null,
    out_archive: ?[]const u8 = null,
    dir: ?[]const u8 = null,
    block_size: usize = 512,
    patterns: []const []const u8 = &.{},
    pat_file: ?[]const u8 = null,
};

// ---------------------------------------------------------------- IO helpers
const Reader = struct {
    fd: i32,
    buf: [65536]u8 = undefined,
    pos: usize = 0,
    end: usize = 0,
    total: u64 = 0,

    fn fill(self: *Reader) bool {
        while (true) {
            const r = linux.read(self.fd, &self.buf, self.buf.len);
            if (u.errno(r) == .INTR) continue;
            if (!u.ok(r) or r == 0) return false;
            self.pos = 0;
            self.end = r;
            return true;
        }
    }

    /// reads exactly dst.len bytes; false when the stream ends early
    fn readExact(self: *Reader, dst: []u8) bool {
        var i: usize = 0;
        while (i < dst.len) {
            if (self.pos >= self.end and !self.fill()) return false;
            const n = @min(dst.len - i, self.end - self.pos);
            @memcpy(dst[i .. i + n], self.buf[self.pos .. self.pos + n]);
            self.pos += n;
            self.total += n;
            i += n;
        }
        return true;
    }

    fn skip(self: *Reader, n: u64) bool {
        var left = n;
        while (left > 0) {
            if (self.pos >= self.end and !self.fill()) return false;
            const k: usize = @intCast(@min(left, self.end - self.pos));
            self.pos += k;
            self.total += k;
            left -= k;
        }
        return true;
    }
};

const Writer = struct {
    fd: i32,
    buf: u.Vec(u8),
    total: u64 = 0,

    fn put(self: *Writer, d: []const u8) void {
        self.buf.pushSlice(d);
        self.total += d.len;
        if (self.buf.items.len >= 1 << 16) self.flush();
    }

    fn pad(self: *Writer, n: usize) void {
        var z = [_]u8{0} ** 512;
        var left = n;
        while (left > 0) {
            const k = @min(left, z.len);
            self.put(z[0..k]);
            left -= k;
        }
    }

    fn flush(self: *Writer) void {
        var off: usize = 0;
        while (off < self.buf.items.len) {
            const r = linux.write(self.fd, self.buf.items.ptr + off, self.buf.items.len - off);
            if (u.errno(r) == .INTR) continue;
            if (!u.ok(r)) break;
            off += r;
        }
        self.buf.items.len = 0;
    }
};

fn hex8(o: *u.Vec(u8), v: u64) void {
    var b: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&b, "{X:0>8}", .{@as(u32, @truncate(v))}) catch {};
    o.pushSlice(&b);
}

fn oct(o: *u.Vec(u8), v: u64, width: usize) void {
    var tmp: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{o}", .{v}) catch "";
    if (s.len < width) o.pushN('0', width - s.len);
    o.pushSlice(if (s.len > width) s[s.len - width ..] else s);
}

fn devMajor(d: u64) u32 {
    return @intCast(((d >> 8) & 0xfff) | ((d >> 32) & ~@as(u64, 0xfff)));
}
fn devMinor(d: u64) u32 {
    return @intCast((d & 0xff) | ((d >> 12) & ~@as(u64, 0xff)));
}

fn writeHeader(w: *Writer, fmt: Format, h: *const Hdr) void {
    var o = u.Vec(u8).init(u.alloc);
    const nsize = h.name.len + 1;
    switch (fmt) {
        .newc, .crc => {
            o.pushSlice(if (fmt == .newc) "070701" else "070702");
            hex8(&o, h.ino);
            hex8(&o, h.mode);
            hex8(&o, h.uid);
            hex8(&o, h.gid);
            hex8(&o, h.nlink);
            hex8(&o, h.mtime);
            hex8(&o, h.size);
            hex8(&o, h.dev_maj);
            hex8(&o, h.dev_min);
            hex8(&o, h.rdev_maj);
            hex8(&o, h.rdev_min);
            hex8(&o, nsize);
            hex8(&o, h.check);
            o.pushSlice(h.name);
            o.push(0);
            o.pushN(0, (4 - o.items.len % 4) % 4);
        },
        .odc => {
            o.pushSlice("070707");
            oct(&o, (@as(u64, h.dev_maj) << 8) | h.dev_min, 6);
            oct(&o, h.ino, 6);
            oct(&o, h.mode, 6);
            oct(&o, h.uid, 6);
            oct(&o, h.gid, 6);
            oct(&o, h.nlink, 6);
            oct(&o, (@as(u64, h.rdev_maj) << 8) | h.rdev_min, 6);
            oct(&o, h.mtime, 11);
            oct(&o, nsize, 6);
            oct(&o, h.size, 11);
            o.pushSlice(h.name);
            o.push(0);
        },
        .bin, .auto => {
            const w16 = struct {
                fn f(out: *u.Vec(u8), v: u64) void {
                    out.push(@truncate(v));
                    out.push(@truncate(v >> 8));
                }
            }.f;
            w16(&o, 0o070707);
            w16(&o, (@as(u64, h.dev_maj) << 8) | h.dev_min);
            w16(&o, h.ino);
            w16(&o, h.mode);
            w16(&o, h.uid);
            w16(&o, h.gid);
            w16(&o, h.nlink);
            w16(&o, (@as(u64, h.rdev_maj) << 8) | h.rdev_min);
            w16(&o, h.mtime >> 16);
            w16(&o, h.mtime);
            w16(&o, nsize);
            w16(&o, h.size >> 16);
            w16(&o, h.size);
            o.pushSlice(h.name);
            o.push(0);
            if (o.items.len % 2 == 1) o.push(0);
        },
    }
    w.put(o.items);
}

fn dataPad(fmt: Format, size: u64) usize {
    return switch (fmt) {
        .newc, .crc => @intCast((4 - size % 4) % 4),
        .bin, .auto => @intCast(size % 2),
        .odc => 0,
    };
}

// ---------------------------------------------------------------- name reading
fn readNames(cfg: *const Cfg) [][]const u8 {
    var data = u.Vec(u8).init(u.alloc);
    var buf: [65536]u8 = undefined;
    while (true) {
        const r = linux.read(0, &buf, buf.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r) or r == 0) break;
        data.pushSlice(buf[0..r]);
    }
    var names = u.Vec([]const u8).init(u.alloc);
    const sep: u8 = if (cfg.null_names) 0 else '\n';
    var it = std.mem.splitScalar(u8, data.items, sep);
    while (it.next()) |n| {
        if (n.len == 0) continue;
        names.push(n);
    }
    return names.items;
}

fn stripDot(name: []const u8) []const u8 {
    var n = name;
    while (n.len >= 2 and n[0] == '.' and n[1] == '/') {
        n = n[2..];
        while (n.len > 0 and n[0] == '/') n = n[1..];
    }
    if (n.len == 0) return name;
    return n;
}

// ---------------------------------------------------------------- copy-out
const Deferred = struct { h: Hdr, path: []const u8 };
const Group = struct { dev: u64, ino: u64, entries: u.Vec(Deferred), nlink: u32 };

fn readFileData(path: []const u8, size: u64, w: *Writer, crc_sum: ?*u32) bool {
    const rc = linux.open(u.zstr(path), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(rc)) return false;
    defer _ = linux.close(@intCast(rc));
    var left = size;
    var buf: [65536]u8 = undefined;
    while (left > 0) {
        const want: usize = @intCast(@min(left, buf.len));
        const r = linux.read(@intCast(rc), &buf, want);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r) or r == 0) break;
        if (crc_sum) |cs| for (buf[0..r]) |b| {
            cs.* +%= b;
        };
        w.put(buf[0..r]);
        left -= r;
    }
    if (left > 0) w.pad(@intCast(left)); // file shrank
    return true;
}

fn checksumOf(path: []const u8) u32 {
    const rc = linux.open(u.zstr(path), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(rc)) return 0;
    defer _ = linux.close(@intCast(rc));
    var sum: u32 = 0;
    var buf: [65536]u8 = undefined;
    while (true) {
        const r = linux.read(@intCast(rc), &buf, buf.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r) or r == 0) break;
        for (buf[0..r]) |b| sum +%= b;
    }
    return sum;
}

fn emitEntry(w: *Writer, fmt: Format, h: *Hdr, path: []const u8, with_data: bool) void {
    const t = h.mode & linux.S.IFMT;
    var hh = h.*;
    if (!with_data and t == linux.S.IFREG) hh.size = 0;
    if (fmt == .crc and t == linux.S.IFREG and with_data) hh.check = checksumOf(path);
    writeHeader(w, fmt, &hh);
    if (t == linux.S.IFLNK) {
        var lb: [4096]u8 = undefined;
        const r = linux.readlink(u.zstr(path), &lb, lb.len);
        const n: usize = if (u.ok(r)) r else 0;
        w.put(lb[0..n]);
        w.pad(dataPad(fmt, n));
    } else if (t == linux.S.IFREG and with_data and hh.size > 0) {
        _ = readFileData(path, hh.size, w, null);
        w.pad(dataPad(fmt, hh.size));
    }
}

fn copyOut(cfg: *const Cfg, fmt: Format, out_fd: i32) u8 {
    var w = Writer{ .fd = out_fd, .buf = u.Vec(u8).init(u.alloc) };
    const names = readNames(cfg);
    var rc: u8 = 0;
    var groups = u.Vec(Group).init(u.alloc);
    for (names) |name| {
        const st = u.stat(name, cfg.deref) orelse {
            u.errf("cpio: {s}: Cannot stat: No such file or directory\n", .{name});
            rc = 2;
            continue;
        };
        var h = Hdr{
            .ino = st.ino,
            .mode = st.mode,
            .uid = st.uid,
            .gid = st.gid,
            .nlink = st.nlink,
            .mtime = @intCast(st.mtime),
            .size = st.size,
            .dev_maj = @intCast(st.dev >> 32),
            .dev_min = @intCast(st.dev & 0xffffffff),
            .name = stripDot(name),
        };
        const t = st.mode & linux.S.IFMT;
        if (t == linux.S.IFCHR or t == linux.S.IFBLK) {
            h.rdev_maj = devMajor(st.rdev);
            h.rdev_min = devMinor(st.rdev);
        }
        if (t == linux.S.IFDIR or t == linux.S.IFIFO or t == linux.S.IFSOCK or t == linux.S.IFCHR or t == linux.S.IFBLK) h.size = 0;
        if (t == linux.S.IFLNK) {
            var lb: [4096]u8 = undefined;
            const r = linux.readlink(u.zstr(name), &lb, lb.len);
            h.size = if (u.ok(r)) r else 0;
        }
        if (cfg.verbose) u.errf("{s}\n", .{h.name});
        if (cfg.dot) u.err(".");
        const linkable = (fmt == .newc or fmt == .crc) and st.nlink > 1 and t != linux.S.IFDIR;
        if (linkable) {
            var found: ?*Group = null;
            for (groups.items) |*gr| if (gr.dev == st.dev and gr.ino == st.ino) {
                found = gr;
            };
            if (found == null) {
                groups.push(.{ .dev = st.dev, .ino = st.ino, .entries = u.Vec(Deferred).init(u.alloc), .nlink = st.nlink });
                found = &groups.items[groups.items.len - 1];
            }
            found.?.entries.push(.{ .h = h, .path = name });
            if (found.?.entries.items.len == found.?.nlink) {
                const es = found.?.entries.items;
                for (es, 0..) |*e, i| emitEntry(&w, fmt, &e.h, e.path, i + 1 == es.len);
                found.?.entries.items.len = 0;
                found.?.nlink = 0;
            }
            continue;
        }
        emitEntry(&w, fmt, &h, name, true);
    }
    for (groups.items) |*gr| {
        const es = gr.entries.items;
        for (es, 0..) |*e, i| emitEntry(&w, fmt, &e.h, e.path, i + 1 == es.len);
    }
    var tr = Hdr{ .name = "TRAILER!!!", .nlink = 1 };
    if (fmt == .odc or fmt == .bin) tr.nlink = 1;
    writeHeader(&w, fmt, &tr);
    const bs = cfg.block_size;
    w.pad(@intCast((bs - w.total % bs) % bs));
    w.flush();
    if (!cfg.quiet) {
        const blocks = (w.total + bs - 1) / bs;
        if (cfg.dot) u.err("\n");
        u.errf("{d} block{s}\n", .{ blocks, if (blocks == 1) "" else "s" });
    }
    return rc;
}

// ---------------------------------------------------------------- header reading
fn parseHex(s: []const u8) ?u64 {
    return std.fmt.parseInt(u64, s, 16) catch null;
}

fn parseOct(s: []const u8) ?u64 {
    return std.fmt.parseInt(u64, s, 8) catch null;
}

/// Returns null at end of archive / on a format error (err set).
fn readHeader(r: *Reader, fmt_io: *Format, err: *[]const u8) ?Hdr {
    var magic: [6]u8 = undefined;
    if (!r.readExact(magic[0..2])) {
        err.* = "premature end of archive";
        return null;
    }
    var h = Hdr{};
    var nsize: usize = 0;
    var fmt = fmt_io.*;
    // bin format first (two byte magic)
    const m16: u16 = @as(u16, magic[0]) | (@as(u16, magic[1]) << 8);
    const swapped = m16 == 0o070707 and false;
    _ = swapped;
    if (m16 == 0o070707 or (magic[0] == 0o307 and magic[1] == 0o161) or (magic[0] == 0o161 and magic[1] == 0o307)) {
        const be = magic[0] == 0o161 and magic[1] == 0o307;
        var raw: [24]u8 = undefined;
        if (!r.readExact(&raw)) {
            err.* = "premature end of file";
            return null;
        }
        const w16 = struct {
            fn f(b: []const u8, i: usize, big: bool) u64 {
                return if (big) (@as(u64, b[i * 2]) << 8) | b[i * 2 + 1] else (@as(u64, b[i * 2 + 1]) << 8) | b[i * 2];
            }
        }.f;
        h.dev_maj = @intCast(w16(&raw, 0, be) >> 8);
        h.dev_min = @intCast(w16(&raw, 0, be) & 0xff);
        h.ino = w16(&raw, 1, be);
        h.mode = @intCast(w16(&raw, 2, be));
        h.uid = @intCast(w16(&raw, 3, be));
        h.gid = @intCast(w16(&raw, 4, be));
        h.nlink = @intCast(w16(&raw, 5, be));
        h.rdev_maj = @intCast(w16(&raw, 6, be) >> 8);
        h.rdev_min = @intCast(w16(&raw, 6, be) & 0xff);
        h.mtime = (w16(&raw, 7, be) << 16) | w16(&raw, 8, be);
        nsize = @intCast(w16(&raw, 9, be));
        h.size = (w16(&raw, 10, be) << 16) | w16(&raw, 11, be);
        fmt = .bin;
        fmt_io.* = fmt;
        const nb = u.alloc.alloc(u8, nsize + nsize % 2) catch return null;
        if (!r.readExact(nb)) {
            err.* = "premature end of file";
            return null;
        }
        h.name = nb[0 .. nsize -| 1];
        return h;
    }
    if (!r.readExact(magic[2..6])) {
        err.* = "premature end of archive";
        return null;
    }
    if (std.mem.eql(u8, &magic, "070701") or std.mem.eql(u8, &magic, "070702")) {
        var raw: [104]u8 = undefined;
        if (!r.readExact(&raw)) {
            err.* = "premature end of file";
            return null;
        }
        var f: [13]u64 = undefined;
        for (0..13) |i| f[i] = parseHex(raw[i * 8 .. i * 8 + 8]) orelse {
            err.* = "invalid header: checksum error";
            return null;
        };
        h.ino = f[0];
        h.mode = @intCast(f[1]);
        h.uid = @intCast(f[2]);
        h.gid = @intCast(f[3]);
        h.nlink = @intCast(f[4]);
        h.mtime = f[5];
        h.size = f[6];
        h.dev_maj = @intCast(f[7]);
        h.dev_min = @intCast(f[8]);
        h.rdev_maj = @intCast(f[9]);
        h.rdev_min = @intCast(f[10]);
        nsize = @intCast(f[11]);
        h.check = @intCast(f[12]);
        fmt_io.* = if (magic[5] == '1') .newc else .crc;
        const total_hdr = 110 + nsize;
        const padn = (4 - total_hdr % 4) % 4;
        const nb = u.alloc.alloc(u8, nsize + padn) catch return null;
        if (!r.readExact(nb)) {
            err.* = "premature end of file";
            return null;
        }
        h.name = nb[0 .. nsize -| 1];
        return h;
    }
    if (std.mem.eql(u8, &magic, "070707")) {
        var raw: [70]u8 = undefined;
        if (!r.readExact(&raw)) {
            err.* = "premature end of file";
            return null;
        }
        const o = struct {
            fn f(b: []const u8, a: usize, n: usize) ?u64 {
                return parseOct(b[a .. a + n]);
            }
        }.f;
        const dev = o(&raw, 0, 6) orelse return null;
        h.dev_maj = @intCast(dev >> 8);
        h.dev_min = @intCast(dev & 0xff);
        h.ino = o(&raw, 6, 6) orelse return null;
        h.mode = @intCast(o(&raw, 12, 6) orelse return null);
        h.uid = @intCast(o(&raw, 18, 6) orelse return null);
        h.gid = @intCast(o(&raw, 24, 6) orelse return null);
        h.nlink = @intCast(o(&raw, 30, 6) orelse return null);
        const rdev = o(&raw, 36, 6) orelse return null;
        h.rdev_maj = @intCast(rdev >> 8);
        h.rdev_min = @intCast(rdev & 0xff);
        h.mtime = o(&raw, 42, 11) orelse return null;
        nsize = @intCast(o(&raw, 53, 6) orelse return null);
        h.size = o(&raw, 59, 11) orelse return null;
        fmt_io.* = .odc;
        const nb = u.alloc.alloc(u8, nsize) catch return null;
        if (!r.readExact(nb)) {
            err.* = "premature end of file";
            return null;
        }
        h.name = nb[0 .. nsize -| 1];
        return h;
    }
    err.* = "premature end of archive";
    return null;
}

// ---------------------------------------------------------------- pattern matching
fn fnmatch(pat: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star_p: ?usize = null;
    var star_i: usize = 0;
    while (i < s.len) {
        if (p < pat.len and pat[p] == '*') {
            star_p = p;
            star_i = i;
            p += 1;
            continue;
        }
        if (p < pat.len) {
            var matched = false;
            var adv: usize = 1;
            if (pat[p] == '?') {
                matched = true;
            } else if (pat[p] == '[') {
                var q = p + 1;
                var neg = false;
                if (q < pat.len and (pat[q] == '!' or pat[q] == '^')) {
                    neg = true;
                    q += 1;
                }
                var any = false;
                var first = true;
                while (q < pat.len and (pat[q] != ']' or first)) : (q += 1) {
                    first = false;
                    if (q + 2 < pat.len and pat[q + 1] == '-' and pat[q + 2] != ']') {
                        if (s[i] >= pat[q] and s[i] <= pat[q + 2]) any = true;
                        q += 2;
                    } else if (pat[q] == s[i]) any = true;
                }
                if (q < pat.len) {
                    matched = any != neg;
                    adv = q + 1 - p;
                }
            } else if (pat[p] == '\\' and p + 1 < pat.len) {
                matched = pat[p + 1] == s[i];
                adv = 2;
            } else matched = pat[p] == s[i];
            if (matched) {
                p += adv;
                i += 1;
                continue;
            }
        }
        if (star_p) |sp| {
            p = sp + 1;
            star_i += 1;
            i = star_i;
            continue;
        }
        return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

fn selected(cfg: *const Cfg, name: []const u8) bool {
    if (cfg.patterns.len == 0) return !cfg.nonmatching;
    var m = false;
    for (cfg.patterns) |p| if (fnmatch(p, name)) {
        m = true;
    };
    return m != cfg.nonmatching;
}

// ---------------------------------------------------------------- listing
fn userName(uid: u32, numeric: bool) []const u8 {
    if (!numeric) if (c.getpwuid(uid)) |p| return std.mem.sliceTo(p.*.pw_name, 0);
    return std.fmt.allocPrint(u.alloc, "{d}", .{uid}) catch "?";
}

fn groupName(gid: u32, numeric: bool) []const u8 {
    if (!numeric) if (c.getgrgid(gid)) |p| return std.mem.sliceTo(p.*.gr_name, 0);
    return std.fmt.allocPrint(u.alloc, "{d}", .{gid}) catch "?";
}

fn modeString(mode: u32) [10]u8 {
    var s = [_]u8{'-'} ** 10;
    s[0] = switch (mode & linux.S.IFMT) {
        linux.S.IFDIR => 'd',
        linux.S.IFLNK => 'l',
        linux.S.IFCHR => 'c',
        linux.S.IFBLK => 'b',
        linux.S.IFIFO => 'p',
        linux.S.IFSOCK => 's',
        else => '-',
    };
    const bits = "rwxrwxrwx";
    for (0..9) |i| if (mode & (@as(u32, 0o400) >> @intCast(i)) != 0) {
        s[i + 1] = bits[i];
    };
    if (mode & 0o4000 != 0) s[3] = if (s[3] == 'x') 's' else 'S';
    if (mode & 0o2000 != 0) s[6] = if (s[6] == 'x') 's' else 'S';
    if (mode & 0o1000 != 0) s[9] = if (s[9] == 'x') 't' else 'T';
    return s;
}

fn longListing(cfg: *const Cfg, h: *const Hdr, link_target: ?[]const u8) []const u8 {
    var tb = u.Vec(u8).init(u.alloc);
    const tm = dt.localtime(@intCast(h.mtime));
    const now = u.nowSecs();
    const six_months: i64 = 15778476;
    const old = @as(i64, @intCast(h.mtime)) < now - six_months or @as(i64, @intCast(h.mtime)) > now + six_months;
    dt.format(if (old) "%b %e  %Y" else "%b %e %H:%M", .{ .sec = @intCast(h.mtime) }, &tm, &tb);
    const ms = modeString(h.mode);
    var sizes: [32]u8 = undefined;
    const sz: []const u8 = if ((h.mode & linux.S.IFMT) == linux.S.IFCHR or (h.mode & linux.S.IFMT) == linux.S.IFBLK)
        std.fmt.bufPrint(&sizes, "{d},{d: >4}", .{ h.rdev_maj, h.rdev_min }) catch ""
    else
        std.fmt.bufPrint(&sizes, "{d}", .{h.size}) catch "";
    return std.fmt.allocPrint(u.alloc, "{s} {d: >3} {s: <8} {s: <8} {s: >8} {s} {s}{s}{s}", .{ &ms, h.nlink, userName(h.uid, cfg.numeric), groupName(h.gid, cfg.numeric), sz, tb.items, h.name, if (link_target != null) " -> " else "", link_target orelse "" }) catch "";
}

// ---------------------------------------------------------------- copy-in
const Pending = struct { h: Hdr, name: []const u8 };

fn announce(cfg: *const Cfg, name: []const u8, redirected: bool) void {
    _ = redirected;
    if (cfg.verbose) u.errf("{s}\n", .{name});
    if (cfg.dot) u.err(".");
}

fn mkParents(path: []const u8) bool {
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            const sub = path[0..i];
            if (u.stat(sub, true) == null) {
                if (!u.ok(linux.mkdir(u.zstr(sub), 0o777))) return false;
            }
        }
    }
    return true;
}

fn setMeta(cfg: *const Cfg, h: *const Hdr, path: []const u8, is_link: bool) void {
    if (!is_link) {
        if (c.geteuid() == 0 and !cfg.no_owner) {
            _ = linux.chown(u.zstr(path), cfg.owner_uid orelse h.uid, cfg.owner_gid orelse h.gid);
        } else if (cfg.owner_uid != null or cfg.owner_gid != null) {
            _ = linux.chown(u.zstr(path), cfg.owner_uid orelse 0xFFFFFFFF, cfg.owner_gid orelse 0xFFFFFFFF);
        }
        _ = linux.chmod(u.zstr(path), @intCast(h.mode & 0o7777));
        if (cfg.preserve_mtime) {
            var times = [2]linux.timespec{ .{ .sec = @intCast(h.mtime), .nsec = 0 }, .{ .sec = @intCast(h.mtime), .nsec = 0 } };
            _ = linux.utimensat(linux.AT.FDCWD, u.zstr(path), &times, 0);
        }
    } else {
        if (c.geteuid() == 0 and !cfg.no_owner) {
            _ = linux.syscall5(.fchownat, @bitCast(@as(isize, linux.AT.FDCWD)), @intFromPtr(u.zstr(path).ptr), cfg.owner_uid orelse h.uid, cfg.owner_gid orelse h.gid, 0x100);
        }
        if (cfg.preserve_mtime) {
            var times = [2]linux.timespec{ .{ .sec = @intCast(h.mtime), .nsec = 0 }, .{ .sec = @intCast(h.mtime), .nsec = 0 } };
            _ = linux.utimensat(linux.AT.FDCWD, u.zstr(path), &times, 0x100);
        }
    }
}

fn makeDev(maj: u32, min: u32) u64 {
    return (@as(u64, maj & 0xfff) << 8) | (min & 0xff) | (@as(u64, min & 0xffffff00) << 12) | (@as(u64, maj & 0xfffff000) << 32);
}

fn copyIn(cfg: *const Cfg, fmt0: Format, in_fd: i32) u8 {
    var r = Reader{ .fd = in_fd };
    var fmt = fmt0;
    var rc: u8 = 0;
    var pend = u.Vec(Pending).init(u.alloc);
    var seen_links = u.Vec(struct { ino: u64, dev_maj: u32, dev_min: u32, name: []const u8 }).init(u.alloc);
    var seen_trailer = false;
    while (true) {
        var err: []const u8 = "";
        const h0 = readHeader(&r, &fmt, &err);
        if (h0 == null) {
            if (err.len > 0) {
                u.errf("cpio: {s}\n", .{err});
                return 2;
            }
            break;
        }
        var h = h0.?;
        if (std.mem.eql(u8, h.name, "TRAILER!!!")) {
            seen_trailer = true;
            break;
        }
        const t = h.mode & linux.S.IFMT;
        const data_size = h.size;
        const dpad = dataPad(fmt, data_size);
        var want = selected(cfg, h.name);
        const linked0 = (fmt == .newc or fmt == .crc) and h.nlink > 1 and t == linux.S.IFREG;
        var redirect: ?Pending = null;
        if (!want and !cfg.list and linked0 and data_size > 0) {
            // the data of a link group arrives with its last member; pending (selected) members get it
            var pi: usize = 0;
            while (pi < pend.items.len) : (pi += 1) {
                const pn = pend.items[pi];
                if (pn.h.ino == h.ino and pn.h.dev_maj == h.dev_maj and pn.h.dev_min == h.dev_min) {
                    redirect = pn;
                    pend.items[pi] = pend.items[pend.items.len - 1];
                    pend.items.len -= 1;
                    want = true;
                    break;
                }
            }
        }
        // symlink targets live in the data area
        var link_target: ?[]u8 = null;
        if (t == linux.S.IFLNK and data_size < 4096) {
            const lt = u.alloc.alloc(u8, @intCast(data_size)) catch break;
            if (!r.readExact(lt)) {
                u.err("cpio: premature end of file\n");
                return 2;
            }
            if (!r.skip(dpad)) break;
            link_target = lt;
        }
        if (!want) {
            if (link_target == null) {
                if (!r.skip(data_size + dpad)) {
                    u.err("cpio: premature end of file\n");
                    return 2;
                }
            }
            continue;
        }
        if (cfg.list) {
            if (cfg.verbose) {
                u.outf("{s}\n", .{longListing(cfg, &h, if (link_target) |l| l else null)});
            } else u.outf("{s}\n", .{h.name});
            if (link_target == null and !r.skip(data_size + dpad)) {
                u.err("cpio: premature end of file\n");
                return 2;
            }
            continue;
        }
        // ---- extraction
        if (redirect) |rd| {
            h.mode = rd.h.mode;
            h.uid = rd.h.uid;
            h.gid = rd.h.gid;
            h.mtime = rd.h.mtime;
            h.name = rd.h.name;
        }
        var name = h.name;
        if (cfg.no_abs) {
            while (name.len > 0 and name[0] == '/') name = name[1..];
            if (name.len == 0) name = ".";
        }
        h.name = name;
        const dest = if (redirect) |rd| rd.name else if (cfg.dir) |d| (std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ d, name }) catch name) else name;
        // newer-or-same-age check
        if (!cfg.unconditional and t != linux.S.IFDIR) {
            if (u.stat(dest, false)) |ex| {
                if (ex.mtime >= @as(i64, @intCast(h.mtime))) {
                    u.errf("cpio: {s} not created: newer or same age version exists\n", .{name});
                    announce(cfg, name, redirect != null);
                    if (link_target == null and !r.skip(data_size + dpad)) break;
                    continue;
                }
            }
        }
        if (cfg.mkdirs) _ = mkParents(dest);
        const linked = (fmt == .newc or fmt == .crc) and h.nlink > 1 and t == linux.S.IFREG;
        if (linked and data_size == 0) {
            // data comes with a later link of the same file
            pend.push(.{ .h = h, .name = dest });
            announce(cfg, name, false);
            continue;
        }
        switch (t) {
            linux.S.IFDIR => {
                const mrc = linux.mkdir(u.zstr(dest), 0o777);
                if (!u.ok(mrc) and u.errno(mrc) != .EXIST) {
                    u.errf("cpio: {s}: Cannot mkdir: {s}\n", .{ name, u.strerr(u.errno(mrc)) });
                    rc = 2;
                } else {
                    setMeta(cfg, &h, dest, false);
                }
            },
            linux.S.IFREG => {
                if (!linked and h.nlink > 1) {
                    var hit: ?[]const u8 = null;
                    for (seen_links.items) |sl| if (sl.ino == h.ino and sl.dev_maj == h.dev_maj and sl.dev_min == h.dev_min) {
                        hit = sl.name;
                    };
                    if (hit) |first| {
                        if (!r.skip(data_size + dpad)) break;
                        _ = linux.unlink(u.zstr(dest));
                        if (!u.ok(linux.link(u.zstr(first), u.zstr(dest)))) {
                            u.errf("cpio: cannot link {s} to {s}\n", .{ first, dest });
                            rc = 2;
                        } else if (cfg.verbose) u.errf("cpio: {s} linked to {s}\n", .{ first, dest });
                        announce(cfg, name, false);
                        continue;
                    }
                    seen_links.push(.{ .ino = h.ino, .dev_maj = h.dev_maj, .dev_min = h.dev_min, .name = dest });
                }
                _ = linux.unlink(u.zstr(dest));
                const ofd = linux.open(u.zstr(dest), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
                if (!u.ok(ofd)) {
                    u.errf("cpio: {s}: Cannot open: {s}\n", .{ name, u.strerr(u.errno(ofd)) });
                    rc = 2;
                    _ = r.skip(data_size + dpad);
                    continue;
                }
                var left = data_size;
                var buf: [65536]u8 = undefined;
                var ok_data = true;
                while (left > 0) {
                    const n: usize = @intCast(@min(left, buf.len));
                    if (!r.readExact(buf[0..n])) {
                        ok_data = false;
                        break;
                    }
                    var off: usize = 0;
                    while (off < n) {
                        const wr = linux.write(@intCast(ofd), buf[off..].ptr, n - off);
                        if (u.errno(wr) == .INTR) continue;
                        if (!u.ok(wr)) break;
                        off += wr;
                    }
                    left -= n;
                }
                _ = linux.close(@intCast(ofd));
                if (!ok_data) {
                    u.err("cpio: premature end of file\n");
                    return 2;
                }
                if (!r.skip(dpad)) break;
                setMeta(cfg, &h, dest, false);
                // links that were waiting for this data
                var i: usize = 0;
                while (i < pend.items.len) {
                    const pn = pend.items[i];
                    if (pn.h.ino == h.ino and pn.h.dev_maj == h.dev_maj and pn.h.dev_min == h.dev_min) {
                        _ = linux.unlink(u.zstr(pn.name));
                        if (!u.ok(linux.link(u.zstr(dest), u.zstr(pn.name)))) {
                            u.errf("cpio: cannot link {s} to {s}\n", .{ dest, pn.name });
                            rc = 2;
                        } else if (cfg.verbose) u.errf("cpio: {s} linked to {s}\n", .{ dest, pn.name });
                        pend.items[i] = pend.items[pend.items.len - 1];
                        pend.items.len -= 1;
                    } else i += 1;
                }
            },
            linux.S.IFLNK => {
                _ = linux.unlink(u.zstr(dest));
                const lr = linux.symlink(u.zstr(link_target orelse ""), u.zstr(dest));
                if (!u.ok(lr)) {
                    u.errf("cpio: {s}: Cannot symlink: {s}\n", .{ name, u.strerr(u.errno(lr)) });
                    rc = 2;
                } else setMeta(cfg, &h, dest, true);
            },
            else => {
                _ = linux.unlink(u.zstr(dest));
                const mr = linux.mknod(u.zstr(dest), @intCast(h.mode), @intCast(makeDev(h.rdev_maj, h.rdev_min)));
                if (!u.ok(mr)) {
                    u.errf("cpio: {s}: Cannot mknod: {s}\n", .{ name, u.strerr(u.errno(mr)) });
                    rc = 2;
                } else setMeta(cfg, &h, dest, false);
                if (!r.skip(data_size + dpad)) break;
            },
        }
        if (redirect == null) announce(cfg, name, false);
    }
    // links whose data never arrived become empty files
    for (pend.items) |pn| {
        const fd = linux.open(u.zstr(pn.name), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
        if (u.ok(fd)) _ = linux.close(@intCast(fd));
        setMeta(cfg, &pn.h, pn.name, false);
    }
    if (!cfg.quiet) {
        // GNU rounds the bytes consumed up to the block size
        const bs = cfg.block_size;
        const blocks = (r.total + bs - 1) / bs;
        if (cfg.dot) u.err("\n");
        u.errf("{d} block{s}\n", .{ blocks, if (blocks == 1) "" else "s" });
    }
    return rc;
}

// ---------------------------------------------------------------- pass-through
fn copyFileTo(src: []const u8, dest: []const u8, size: u64) bool {
    const in = linux.open(u.zstr(src), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(in)) return false;
    defer _ = linux.close(@intCast(in));
    _ = linux.unlink(u.zstr(dest));
    const out = linux.open(u.zstr(dest), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
    if (!u.ok(out)) return false;
    defer _ = linux.close(@intCast(out));
    var buf: [65536]u8 = undefined;
    var left = size;
    while (left > 0) {
        const r = linux.read(@intCast(in), &buf, buf.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r) or r == 0) break;
        var off: usize = 0;
        while (off < r) {
            const w = linux.write(@intCast(out), buf[off..].ptr, r - off);
            if (u.errno(w) == .INTR) continue;
            if (!u.ok(w)) return false;
            off += w;
        }
        left -|= r;
    }
    return true;
}

fn passThrough(cfg: *const Cfg, destdir: []const u8) u8 {
    const names = readNames(cfg);
    var rc: u8 = 0;
    var bytes: u64 = 0;
    var seen = u.Vec(struct { dev: u64, ino: u64, dest: []const u8 }).init(u.alloc);
    for (names) |name| {
        const st = u.stat(name, cfg.deref) orelse {
            u.errf("cpio: {s}: Cannot stat: No such file or directory\n", .{name});
            rc = 2;
            continue;
        };
        if (std.mem.eql(u8, name, ".")) {
            if (cfg.dot) u.err(".");
            continue;
        }
        const dest = std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ destdir, name }) catch continue;
        const t = st.mode & linux.S.IFMT;
        var h = Hdr{ .mode = st.mode, .uid = st.uid, .gid = st.gid, .mtime = @intCast(st.mtime), .name = name, .ino = st.ino, .size = st.size };
        if (!cfg.unconditional and t != linux.S.IFDIR) {
            if (u.stat(dest, false)) |ex| if (ex.mtime >= st.mtime) {
                u.errf("cpio: {s} not created: newer or same age version exists\n", .{dest});
                if (cfg.verbose) u.errf("{s}\n", .{dest});
                continue;
            };
        }
        if (cfg.mkdirs) _ = mkParents(dest);
        // files sharing an inode become hard links in the destination
        if (t != linux.S.IFDIR and t != linux.S.IFLNK and st.nlink > 1 and !cfg.link) {
            var first: ?[]const u8 = null;
            for (seen.items) |sn| if (sn.dev == st.dev and sn.ino == st.ino) {
                first = sn.dest;
            };
            if (first) |f| {
                _ = linux.unlink(u.zstr(dest));
                if (!u.ok(linux.link(u.zstr(f), u.zstr(dest)))) {
                    u.errf("cpio: cannot link {s} to {s}\n", .{ f, dest });
                    rc = 2;
                } else if (cfg.verbose) u.errf("cpio: {s} linked to {s}\n", .{ f, dest });
                if (cfg.verbose) u.errf("{s}\n", .{dest});
                continue;
            }
        }
        switch (t) {
            linux.S.IFDIR => {
                const mr = linux.mkdir(u.zstr(dest), 0o777);
                if (!u.ok(mr) and u.errno(mr) != .EXIST) {
                    u.errf("cpio: {s}: Cannot mkdir: {s}\n", .{ dest, u.strerr(u.errno(mr)) });
                    rc = 2;
                } else setMeta(cfg, &h, dest, false);
            },
            else => {
                if (cfg.link and t != linux.S.IFLNK) {
                    _ = linux.unlink(u.zstr(dest));
                    if (!u.ok(linux.link(u.zstr(name), u.zstr(dest)))) {
                        u.errf("cpio: cannot link {s} to {s}\n", .{ name, dest });
                        rc = 2;
                    } else if (cfg.verbose) u.errf("cpio: {s} linked to {s}\n", .{ name, dest });
                } else switch (t) {
                    linux.S.IFREG => {
                        if (!copyFileTo(name, dest, st.size)) {
                            u.errf("cpio: {s}: Cannot open: {s}\n", .{ dest, if (u.stat(name, true) == null) "No such file or directory" else "No such file or directory" });
                            rc = 2;
                        } else {
                            bytes += st.size;
                            setMeta(cfg, &h, dest, false);
                        }
                    },
                    linux.S.IFLNK => {
                        var lb: [4096]u8 = undefined;
                        const r = linux.readlink(u.zstr(name), &lb, lb.len);
                        if (u.ok(r)) {
                            _ = linux.unlink(u.zstr(dest));
                            const sr = linux.symlink(u.zstr(lb[0..r]), u.zstr(dest));
                            if (!u.ok(sr)) {
                                u.errf("cpio: {s}: Cannot create symlink to '{s}': {s}\n", .{ lb[0..r], dest, u.strerr(u.errno(sr)) });
                                rc = 2;
                            } else setMeta(cfg, &h, dest, true);
                        }
                    },
                    else => {
                        _ = linux.unlink(u.zstr(dest));
                        const mr = linux.mknod(u.zstr(dest), @intCast(st.mode), @intCast(makeDev(devMajor(st.rdev), devMinor(st.rdev))));
                        if (!u.ok(mr)) {
                            u.errf("cpio: {s}: Cannot mknod: {s}\n", .{ dest, u.strerr(u.errno(mr)) });
                            rc = 2;
                        } else setMeta(cfg, &h, dest, false);
                    },
                }
            },
        }
        if (t != linux.S.IFDIR and st.nlink > 1 and u.stat(dest, false) != null) {
            var known = false;
            for (seen.items) |sn| if (sn.dev == st.dev and sn.ino == st.ino) {
                known = true;
            };
            if (!known) seen.push(.{ .dev = st.dev, .ino = st.ino, .dest = dest });
        }
        if (cfg.verbose) u.errf("{s}\n", .{dest});
        if (cfg.dot) u.err(".");
    }
    if (!cfg.quiet) {
        const blocks = (bytes + cfg.block_size - 1) / cfg.block_size;
        if (cfg.dot) u.err("\n");
        u.errf("{d} block{s}\n", .{ blocks, if (blocks == 1) "" else "s" });
    }
    return rc;
}

// ---------------------------------------------------------------- main
fn parseOwner(spec: []const u8, cfg: *Cfg) bool {
    var uname = spec;
    var gname: ?[]const u8 = null;
    if (std.mem.indexOfAny(u8, spec, ":.")) |i| {
        uname = spec[0..i];
        gname = spec[i + 1 ..];
    }
    if (uname.len > 0) {
        cfg.owner_uid = std.fmt.parseInt(u32, uname, 10) catch u.findUser(uname) orelse {
            u.errf("cpio: invalid user: {s}\n", .{uname});
            return false;
        };
    }
    if (gname) |gn| if (gn.len > 0) {
        cfg.owner_gid = std.fmt.parseInt(u32, gn, 10) catch u.findGroup(gn) orelse {
            u.errf("cpio: invalid group: {s}\n", .{gn});
            return false;
        };
    };
    return true;
}

pub fn run(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "create", .key = 'o' },
        .{ .name = "extract", .key = 'i' },
        .{ .name = "pass-through", .key = 'p' },
        .{ .name = "list", .key = 't' },
        .{ .name = "format", .key = 'H', .arg = .req },
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "dot", .key = 'V' },
        .{ .name = "make-directories", .key = 'd' },
        .{ .name = "preserve-modification-time", .key = 'm' },
        .{ .name = "unconditional", .key = 'u' },
        .{ .name = "null", .key = '0' },
        .{ .name = "dereference", .key = 'L' },
        .{ .name = "reset-access-time", .key = 'a' },
        .{ .name = "nonmatching", .key = 'f' },
        .{ .name = "numeric-uid-gid", .key = 'n' },
        .{ .name = "quiet", .key = 200 },
        .{ .name = "no-preserve-owner", .key = 201 },
        .{ .name = "preserve-owner", .key = 202 },
        .{ .name = "no-absolute-filenames", .key = 203 },
        .{ .name = "absolute-filenames", .key = 204 },
        .{ .name = "link", .key = 'l' },
        .{ .name = "owner", .key = 'R', .arg = .req },
        .{ .name = "file", .key = 'F', .arg = .req },
        .{ .name = "directory", .key = 'D', .arg = .req },
        .{ .name = "block-size", .key = 205, .arg = .req },
        .{ .name = "io-size", .key = 'C', .arg = .req },
        .{ .name = "pattern-file", .key = 'E', .arg = .req },
        .{ .name = "force-local", .key = 206 },
        .{ .name = "help", .key = 'h' },
        .{ .name = "version", .key = 207 },
        .{ .key = 'B' },
        .{ .key = 'c' },
        .{ .key = 'I', .arg = .req },
        .{ .key = 'O', .arg = .req },
        .{ .key = 'A' },
        .{ .key = 'r' },
        .{ .key = 'b' },
        .{ .key = 's' },
        .{ .key = 'S' },
        .{ .key = 'e' },
    };
    var p = g.Parser.init("cpio", args, &opts);
    var cfg = Cfg{};
    while (p.next() catch return 64) |it| {
        switch (it.key) {
            'o', 'i', 'p' => {
                if (cfg.mode != 0 and cfg.mode != it.key) {
                    u.err("cpio: Mode already defined\nTry 'cpio --help' or 'cpio --usage' for more information.\n");
                    return 2;
                }
                cfg.mode = it.key;
            },
            't' => cfg.list = true,
            'H' => {
                const v = it.val.?;
                cfg.format = if (std.ascii.eqlIgnoreCase(v, "newc")) .newc else if (std.ascii.eqlIgnoreCase(v, "crc")) .crc else if (std.ascii.eqlIgnoreCase(v, "odc")) .odc else if (std.ascii.eqlIgnoreCase(v, "bin")) .bin else {
                    u.errf("cpio: invalid archive format `{s}'; valid formats are:\ncrc newc odc bin ustar tar (all-caps also recognized)\n", .{v});
                    return 2;
                };
            },
            'c' => cfg.format = .newc,
            'v' => cfg.verbose = true,
            'V' => cfg.dot = true,
            'd' => cfg.mkdirs = true,
            'm' => cfg.preserve_mtime = true,
            'u' => cfg.unconditional = true,
            '0' => cfg.null_names = true,
            'L' => cfg.deref = true,
            'a' => cfg.reset_atime = true,
            'f' => cfg.nonmatching = true,
            'n' => cfg.numeric = true,
            200 => cfg.quiet = true,
            201 => cfg.no_owner = true,
            202 => cfg.no_owner = false,
            203 => cfg.no_abs = true,
            204 => cfg.no_abs = false,
            'l' => cfg.link = true,
            'R' => if (!parseOwner(it.val.?, &cfg)) return 2,
            'F' => cfg.archive = it.val,
            'I' => cfg.archive = it.val,
            'O' => cfg.out_archive = it.val,
            'D' => cfg.dir = it.val,
            'B' => cfg.block_size = 5120,
            205 => cfg.block_size = (std.fmt.parseInt(usize, it.val.?, 10) catch 1) * 512,
            'C' => cfg.block_size = std.fmt.parseInt(usize, it.val.?, 10) catch 512,
            'E' => cfg.pat_file = it.val,
            'h' => {
                u.out("Usage: cpio [OPTION...] [destination-directory]\nGNU `cpio' copies files to and from archives\n");
                return 0;
            },
            207 => {
                u.out("cpio (GNU cpio) 2.15\n");
                return 0;
            },
            else => {},
        }
    }
    if (cfg.mode == 0 and cfg.list) cfg.mode = 'i';
    if (cfg.mode == 0) {
        u.err("cpio: You must specify one of -oipt options.\nTry 'cpio --help' or 'cpio --usage' for more information.\n");
        return 2;
    }
    var ops = p.operands.items;
    if (cfg.mode == 'i') {
        var pats = u.Vec([]const u8).init(u.alloc);
        for (ops) |o| pats.push(o);
        if (cfg.pat_file) |pf| {
            const rc = linux.open(u.zstr(pf), .{ .ACCMODE = .RDONLY }, 0);
            if (u.ok(rc)) {
                var d = u.Vec(u8).init(u.alloc);
                var b: [4096]u8 = undefined;
                while (true) {
                    const r = linux.read(@intCast(rc), &b, b.len);
                    if (!u.ok(r) or r == 0) break;
                    d.pushSlice(b[0..r]);
                }
                _ = linux.close(@intCast(rc));
                var it2 = std.mem.splitScalar(u8, d.items, '\n');
                while (it2.next()) |l| if (l.len > 0) pats.push(l);
            }
        }
        cfg.patterns = pats.items;
        ops = &.{};
    }
    switch (cfg.mode) {
        'o' => {
            var out_fd: i32 = 1;
            if (cfg.out_archive orelse cfg.archive) |a| {
                const rc = linux.open(u.zstr(a), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666);
                if (!u.ok(rc)) {
                    u.errf("cpio: Cannot open {s}: {s}\n", .{ a, u.strerr(u.errno(rc)) });
                    return 2;
                }
                out_fd = @intCast(rc);
            } else {
                var t: linux.termios = undefined;
                if (u.ok(linux.ioctl(1, 0x5401, @intFromPtr(&t)))) {
                    u.err("cpio: Refusing to write archive contents to terminal (missing -F -O or redirection)\n");
                    return 2;
                }
            }
            if (cfg.dir) |d| _ = linux.chdir(u.zstr(d));
            const fmt: Format = if (cfg.format == .auto) .bin else cfg.format;
            return copyOut(&cfg, fmt, out_fd);
        },
        'i' => {
            var in_fd: i32 = 0;
            if (cfg.archive) |a| {
                const rc = linux.open(u.zstr(a), .{ .ACCMODE = .RDONLY }, 0);
                if (!u.ok(rc)) {
                    u.errf("cpio: Cannot open {s}: {s}\n", .{ a, u.strerr(u.errno(rc)) });
                    return 2;
                }
                in_fd = @intCast(rc);
            } else {
                var t: linux.termios = undefined;
                if (u.ok(linux.ioctl(0, 0x5401, @intFromPtr(&t)))) {
                    u.err("cpio: Refusing to read archive contents from terminal (missing -I or redirection)\n");
                    return 2;
                }
            }
            if (cfg.dir) |d| {
                if (!u.ok(linux.chdir(u.zstr(d)))) {
                    u.errf("cpio: Cannot chdir to {s}: {s}\n", .{ d, "No such file or directory" });
                    return 2;
                }
                cfg.dir = null;
            }
            return copyIn(&cfg, cfg.format, in_fd);
        },
        'p' => {
            if (ops.len == 0) {
                u.err("cpio: Not enough arguments\nTry 'cpio --help' or 'cpio --usage' for more information.\n");
                return 2;
            }
            return passThrough(&cfg, ops[0]);
        },
        else => return 2,
    }
}
