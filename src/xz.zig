// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// xz unxz xzcat lzma unlzma lzcat - .xz and .lzma compression (xz utils compatible command line)
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const lz = @import("lzmacodec.zig");

const CheckKind = enum(u8) { none = 0, crc32 = 1, crc64 = 4, sha256 = 10 };

const Format = enum { auto, xz, lzma };

const XzError = lz.Error || error{ Format, Check, Exists, Skip };

fn errText(e: anyerror) []const u8 {
    return switch (e) {
        error.Corrupt, error.Check => "Compressed data is corrupt",
        error.Truncated => "Unexpected end of input",
        error.Unsupported => "Unsupported options",
        error.NoMem => "Cannot allocate memory",
        error.Format => "File format not recognized",
        error.Io => "Input/output error",
        else => "Unknown error",
    };
}

// ---------------------------------------------------------------- integrity checks
const Check = struct {
    kind: CheckKind,
    c32: std.hash.Crc32 = std.hash.Crc32.init(),
    c64: std.hash.crc.Crc64Xz = std.hash.crc.Crc64Xz.init(),
    sha: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),

    fn update(self: *Check, d: []const u8) void {
        switch (self.kind) {
            .none => {},
            .crc32 => self.c32.update(d),
            .crc64 => self.c64.update(d),
            .sha256 => self.sha.update(d),
        }
    }

    fn size(kind: CheckKind) usize {
        return switch (kind) {
            .none => 0,
            .crc32 => 4,
            .crc64 => 8,
            .sha256 => 32,
        };
    }

    fn final(self: *Check, out: *[32]u8) usize {
        switch (self.kind) {
            .none => return 0,
            .crc32 => {
                std.mem.writeInt(u32, out[0..4], self.c32.final(), .little);
                return 4;
            },
            .crc64 => {
                std.mem.writeInt(u64, out[0..8], self.c64.final(), .little);
                return 8;
            },
            .sha256 => {
                self.sha.final(out);
                return 32;
            },
        }
    }
};

fn kindFromId(id: u8) ?CheckKind {
    return switch (id) {
        0 => .none,
        1 => .crc32,
        4 => .crc64,
        10 => .sha256,
        else => null,
    };
}

// ---------------------------------------------------------------- output sink
const OutCtx = struct {
    fd: i32,
    check: ?*Check = null,
    total: u64 = 0,
    discard: bool = false,
};

fn writeAll(fd: i32, data: []const u8) lz.Error!void {
    var off: usize = 0;
    while (off < data.len) {
        const r = linux.write(fd, data.ptr + off, data.len - off);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r)) return error.Io;
        off += r;
    }
}

fn sinkWrite(ctx: *anyopaque, data: []const u8) lz.Error!void {
    const oc: *OutCtx = @ptrCast(@alignCast(ctx));
    if (oc.check) |c| c.update(data);
    oc.total += data.len;
    if (!oc.discard) try writeAll(oc.fd, data);
}

// ---------------------------------------------------------------- vli
fn readVli(src: *lz.Source) lz.Error!u64 {
    var v: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        const b = try src.byte();
        v |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) {
            if (b == 0 and i > 0) return error.Corrupt;
            return v;
        }
        shift += 7;
    }
    return error.Corrupt;
}

fn pushVli(o: *u.Vec(u8), value: u64) void {
    var v = value;
    while (v >= 0x80) {
        o.push(@as(u8, @truncate(v)) | 0x80);
        v >>= 7;
    }
    o.push(@as(u8, @truncate(v)));
}

fn dictFromProp(b: u8) ?u64 {
    if (b > 40) return null;
    if (b == 40) return 0xFFFFFFFF;
    return (@as(u64, 2) | (b & 1)) << @intCast(b / 2 + 11);
}

fn dictToProp(d: u64) u8 {
    var b: u8 = 0;
    while (b < 40 and (dictFromProp(b) orelse 0) < d) b += 1;
    return b;
}

// ---------------------------------------------------------------- .xz decoding
const StreamInfo = struct { blocks: u64 = 0, unc: u64 = 0, comp: u64 = 0, check: CheckKind = .none };

fn decodeXzStream(src: *lz.Source, oc: *OutCtx, info: *StreamInfo) XzError!void {
    var hdr: [12]u8 = undefined;
    try src.read(&hdr);
    if (!std.mem.eql(u8, hdr[0..6], "\xFD7zXZ\x00")) return error.Format;
    if (std.hash.Crc32.hash(hdr[6..8]) != std.mem.readInt(u32, hdr[8..12], .little)) return error.Corrupt;
    if (hdr[6] != 0 or hdr[7] & 0xf0 != 0) return error.Unsupported;
    const kind = kindFromId(hdr[7] & 0x0f) orelse return error.Unsupported;
    info.check = kind;
    const stream_hdr_flags = hdr[6..8].*;
    var rec_unpadded = u.Vec(u64).init(u.alloc);
    var rec_unc = u.Vec(u64).init(u.alloc);
    while (true) {
        const hb = try src.byte();
        if (hb == 0) break; // index indicator
        const hsize: usize = (@as(usize, hb) + 1) * 4;
        var bh = u.alloc.alloc(u8, hsize) catch return error.NoMem;
        defer u.alloc.free(bh);
        bh[0] = hb;
        try src.read(bh[1..]);
        if (std.hash.Crc32.hash(bh[0 .. hsize - 4]) != std.mem.readInt(u32, bh[hsize - 4 ..][0..4], .little)) return error.Corrupt;
        const bflags = bh[1];
        const nfilters: usize = (bflags & 3) + 1;
        var off: usize = 2;
        var sub = lz.Source.init(-1);
        _ = &sub;
        const readV = struct {
            fn f(b: []const u8, o: *usize) XzError!u64 {
                var v: u64 = 0;
                var sh: u6 = 0;
                var i: usize = 0;
                while (i < 9) : (i += 1) {
                    if (o.* >= b.len) return error.Corrupt;
                    const x = b[o.*];
                    o.* += 1;
                    v |= @as(u64, x & 0x7f) << sh;
                    if (x & 0x80 == 0) return v;
                    sh += 7;
                }
                return error.Corrupt;
            }
        }.f;
        var csize: ?u64 = null;
        var usize_: ?u64 = null;
        if (bflags & 0x40 != 0) csize = try readV(bh[0 .. hsize - 4], &off);
        if (bflags & 0x80 != 0) usize_ = try readV(bh[0 .. hsize - 4], &off);
        var dict: u64 = 0;
        var k: usize = 0;
        while (k < nfilters) : (k += 1) {
            const id = try readV(bh[0 .. hsize - 4], &off);
            const psz = try readV(bh[0 .. hsize - 4], &off);
            if (off + psz > hsize - 4) return error.Corrupt;
            if (id != 0x21 or k + 1 != nfilters or psz != 1) return error.Unsupported;
            dict = dictFromProp(bh[off]) orelse return error.Corrupt;
            off += @intCast(psz);
        }
        // reserved bits and padding must be clean
        if (bflags & 0x3c != 0) return error.Unsupported;
        for (bh[off .. hsize - 4]) |z| if (z != 0) return error.Corrupt;
        var chk = Check{ .kind = kind };
        var bo = OutCtx{ .fd = oc.fd, .check = &chk, .discard = oc.discard };
        var win = try lz.Window.init(@intCast(@min(dict, 1 << 30)), .{ .ctx = &bo, .write = sinkWrite });
        defer win.deinit();
        const start = src.total;
        const got = try lz.lzma2Decode(src, &win);
        try win.flush();
        _ = got;
        const comp_len = src.total - start;
        if (csize) |c| if (c != comp_len) return error.Corrupt;
        if (usize_) |us| if (us != bo.total) return error.Corrupt;
        var pad = (4 - (comp_len % 4)) % 4;
        while (pad > 0) : (pad -= 1) if (try src.byte() != 0) return error.Corrupt;
        if (kind != .none) {
            var want: [32]u8 = undefined;
            const n = Check.size(kind);
            try src.read(want[0..n]);
            var have: [32]u8 = undefined;
            _ = chk.final(&have);
            if (!std.mem.eql(u8, want[0..n], have[0..n])) return error.Check;
        }
        oc.total += bo.total;
        info.blocks += 1;
        info.unc += bo.total;
        rec_unpadded.push(hsize + comp_len + Check.size(kind));
        rec_unc.push(bo.total);
    }
    // index
    const idx_start = src.total - 1;
    const nrec = try readVli(src);
    if (nrec != rec_unc.items.len) return error.Corrupt;
    var i: usize = 0;
    while (i < nrec) : (i += 1) {
        const up = try readVli(src);
        const un = try readVli(src);
        if (up != rec_unpadded.items[i] or un != rec_unc.items[i]) return error.Corrupt;
    }
    var ipad = (4 - ((src.total - idx_start) % 4)) % 4;
    while (ipad > 0) : (ipad -= 1) if (try src.byte() != 0) return error.Corrupt;
    const idx_size = src.total - idx_start;
    var icrc: [4]u8 = undefined;
    try src.read(&icrc);
    // footer
    var ft: [12]u8 = undefined;
    try src.read(&ft);
    if (!std.mem.eql(u8, ft[10..12], "YZ")) return error.Corrupt;
    if (std.hash.Crc32.hash(ft[4..10]) != std.mem.readInt(u32, ft[0..4], .little)) return error.Corrupt;
    if (!std.mem.eql(u8, ft[8..10], &stream_hdr_flags)) return error.Corrupt;
    if ((@as(u64, std.mem.readInt(u32, ft[4..8], .little)) + 1) * 4 != idx_size + 4) return error.Corrupt;
}

// ---------------------------------------------------------------- .lzma decoding
fn decodeLzmaAlone(src: *lz.Source, oc: *OutCtx, info: *StreamInfo) XzError!void {
    var hdr: [13]u8 = undefined;
    try src.read(&hdr);
    const props = lz.Props.fromByte(hdr[0]) orelse return error.Format;
    const dict = std.mem.readInt(u32, hdr[1..5], .little);
    const usize_ = std.mem.readInt(u64, hdr[5..13], .little);
    var bo = OutCtx{ .fd = oc.fd, .discard = oc.discard };
    var win = try lz.Window.init(@intCast(@min(@max(dict, 4096), 1 << 30)), .{ .ctx = &bo, .write = sinkWrite });
    defer win.deinit();
    var dec = try lz.Decoder.init(props, &win);
    var rd = try lz.rangeDecoderInit(src);
    var ended = false;
    const limit: ?u64 = if (usize_ == std.math.maxInt(u64)) null else usize_;
    const got = try dec.run(&rd, limit, &ended);
    try win.flush();
    if (limit) |l| if (got != l) return error.Corrupt;
    oc.total += bo.total;
    info.blocks = 1;
    info.unc = bo.total;
}

fn isLzmaAlone(h: []const u8) bool {
    if (h.len < 13) return false;
    const props = lz.Props.fromByte(h[0]) orelse return false;
    _ = props;
    const dict = std.mem.readInt(u32, h[1..5], .little);
    if (dict < 4096 and false) return false;
    // dictionary sizes are 2^n or 2^n + 2^(n-1)
    var ok = dict == 0;
    var n: u6 = 0;
    while (n < 32) : (n += 1) {
        const a: u64 = @as(u64, 1) << n;
        if (dict == a or dict == a + (a >> 1)) ok = true;
    }
    if (!ok) return false;
    const us = std.mem.readInt(u64, h[5..13], .little);
    return us == std.math.maxInt(u64) or us < (1 << 38);
}

// ---------------------------------------------------------------- compression
const Level = struct { dict: u32, nice: usize, depth: usize, lazy: bool };

fn levelParams(level: u8, extreme: bool) Level {
    const dicts = [_]u32{ 256 << 10, 1 << 20, 2 << 20, 4 << 20, 4 << 20, 8 << 20, 8 << 20, 16 << 20, 32 << 20, 64 << 20 };
    var l = Level{ .dict = dicts[@min(level, 9)], .nice = 32, .depth = 8, .lazy = false };
    switch (level) {
        0, 1 => l = .{ .dict = l.dict, .nice = 16, .depth = 4, .lazy = false },
        2 => l = .{ .dict = l.dict, .nice = 32, .depth = 8, .lazy = false },
        3 => l = .{ .dict = l.dict, .nice = 48, .depth = 16, .lazy = true },
        4, 5, 6 => l = .{ .dict = l.dict, .nice = 64, .depth = 32, .lazy = true },
        else => l = .{ .dict = l.dict, .nice = 128, .depth = 64, .lazy = true },
    }
    if (extreme) {
        l.nice = @min(l.nice * 2, 273);
        l.depth *= 4;
    }
    return l;
}

fn vecAppend(ctx: *anyopaque, data: []const u8) lz.Error!void {
    const v: *u.Vec(u8) = @ptrCast(@alignCast(ctx));
    v.pushSlice(data);
}

fn compressXz(data: []const u8, level: Level, kind: CheckKind, out: *u.Vec(u8)) XzError!void {
    var hdr = [_]u8{ 0xFD, '7', 'z', 'X', 'Z', 0, 0, @intFromEnum(kind), 0, 0, 0, 0 };
    std.mem.writeInt(u32, hdr[8..12], std.hash.Crc32.hash(hdr[6..8]), .little);
    out.pushSlice(&hdr);
    var index = u.Vec(u8).init(u.alloc);
    index.push(0);
    if (data.len == 0) {
        pushVli(&index, 0);
    } else {
        pushVli(&index, 1);
        // block header
        const dict = if (data.len < level.dict) @max(@as(u32, 4096), std.math.ceilPowerOfTwo(u32, @intCast(@min(data.len, 1 << 30))) catch level.dict) else level.dict;
        const dprop = dictToProp(@max(dict, 4096));
        var bh = [_]u8{ 2, 0, 0x21, 1, dprop, 0, 0, 0, 0, 0, 0, 0 };
        std.mem.writeInt(u32, bh[8..12], std.hash.Crc32.hash(bh[0..8]), .little);
        out.pushSlice(&bh);
        const start = out.items.len;
        try lz.lzma2Encode(data, .{ .dict_size = @intCast(dictFromProp(dprop).?), .nice_len = level.nice, .depth = level.depth, .lazy = level.lazy }, out, vecAppend);
        const comp_len = out.items.len - start;
        out.pushN(0, (4 - (comp_len % 4)) % 4);
        var chk = Check{ .kind = kind };
        chk.update(data);
        var cb: [32]u8 = undefined;
        const n = chk.final(&cb);
        out.pushSlice(cb[0..n]);
        pushVli(&index, bh.len + comp_len + Check.size(kind));
        pushVli(&index, data.len);
    }
    index.pushN(0, (4 - (index.items.len % 4)) % 4);
    var c: [4]u8 = undefined;
    std.mem.writeInt(u32, &c, std.hash.Crc32.hash(index.items), .little);
    index.pushSlice(&c);
    out.pushSlice(index.items);
    var ft: [12]u8 = undefined;
    std.mem.writeInt(u32, ft[4..8], @intCast(index.items.len / 4 - 1), .little);
    ft[8] = 0;
    ft[9] = @intFromEnum(kind);
    std.mem.writeInt(u32, ft[0..4], std.hash.Crc32.hash(ft[4..10]), .little);
    ft[10] = 'Y';
    ft[11] = 'Z';
    out.pushSlice(&ft);
}

fn compressLzma(data: []const u8, level: Level, out: *u.Vec(u8)) XzError!void {
    const props = lz.Props{};
    var h: [13]u8 = undefined;
    h[0] = props.byte();
    std.mem.writeInt(u32, h[1..5], level.dict, .little);
    std.mem.writeInt(u64, h[5..13], std.math.maxInt(u64), .little);
    out.pushSlice(&h);
    try lz.lzmaEncode(data, .{ .dict_size = level.dict, .nice_len = level.nice, .depth = level.depth, .lazy = level.lazy, .props = props }, out, vecAppend);
}

// ---------------------------------------------------------------- CLI
const Mode = enum { compress, decompress, test_, list };

const Cfg = struct {
    mode: Mode = .compress,
    stdout: bool = false,
    keep: bool = false,
    force: bool = false,
    quiet: u32 = 0,
    verbose: bool = false,
    level: u8 = 6,
    extreme: bool = false,
    format: Format = .auto,
    check: CheckKind = .crc64,
    suffix: ?[]const u8 = null,
    prog: []const u8 = "xz",
};

var warned = false;

fn msg(cfg: *const Cfg, comptime fmt: []const u8, args: anytype) void {
    if (cfg.quiet > 1) return;
    u.errf("{s}: " ++ fmt ++ "\n", .{cfg.prog} ++ args);
}

fn wmsg(cfg: *const Cfg, comptime fmt: []const u8, args: anytype) void {
    if (cfg.quiet > 0) return;
    u.errf("{s}: " ++ fmt ++ "\n", .{cfg.prog} ++ args);
}

fn readAllFd(fd: i32) ?[]u8 {
    var data = u.Vec(u8).init(u.alloc);
    var buf: [65536]u8 = undefined;
    while (true) {
        const r = linux.read(fd, &buf, buf.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r)) return null;
        if (r == 0) break;
        data.pushSlice(buf[0..r]);
    }
    return data.items;
}

fn isTty(fd: i32) bool {
    var t: linux.termios = undefined;
    return u.ok(linux.ioctl(fd, 0x5401, @intFromPtr(&t)));
}

/// Decode everything readable from `in_fd` to `out_fd` (or discard). Returns error on bad data.
fn decodeAll(cfg: *const Cfg, in_fd: i32, out_fd: i32, discard: bool, info_out: ?*StreamInfo) XzError!void {
    var src = lz.Source.init(in_fd);
    var oc = OutCtx{ .fd = out_fd, .discard = discard };
    var first = true;
    var tot = StreamInfo{};
    while (true) {
        if (!first) {
            // stream padding (multiples of four zero bytes), then either EOF or another stream
            var zeros: usize = 0;
            while (true) {
                const pk = try src.peekByte();
                if (pk == null) {
                    if (zeros % 4 != 0) return error.Corrupt;
                    if (info_out) |io| io.* = tot;
                    return;
                }
                if (pk.? != 0) break;
                _ = try src.byte();
                zeros += 1;
            }
            if (zeros % 4 != 0) return error.Corrupt;
        }
        const pk = try src.peekByte();
        if (pk == null) {
            if (first) return; // empty input is not valid, handled by caller
            if (info_out) |io| io.* = tot;
            return;
        }
        // detect format on the first bytes
        var si = StreamInfo{};
        if (pk.? == 0xFD and cfg.format != .lzma) {
            try decodeXzStream(&src, &oc, &si);
            tot.blocks += si.blocks;
            tot.unc += si.unc;
            tot.check = si.check;
        } else if (!first) {
            return error.Format;
        } else if (cfg.format == .xz) {
            return error.Format;
        } else {
            // .lzma: look at the header before committing
            if (src.end - src.pos < 13) {
                // make sure the header bytes are buffered
                if (src.pos > 0) {
                    std.mem.copyForwards(u8, src.buf[0 .. src.end - src.pos], src.buf[src.pos..src.end]);
                    src.end -= src.pos;
                    src.pos = 0;
                }
                while (src.end < 13) {
                    const r = linux.read(src.fd, src.buf[src.end..].ptr, src.buf.len - src.end);
                    if (u.errno(r) == .INTR) continue;
                    if (!u.ok(r) or r == 0) break;
                    src.end += r;
                }
            }
            if (!isLzmaAlone(src.buf[src.pos..src.end])) return error.Format;
            try decodeLzmaAlone(&src, &oc, &si);
            tot.blocks += 1;
            tot.unc += si.unc;
            tot.check = .none;
            if (try src.peekByte() != null) {
                // trailing garbage after a .lzma stream
                if (info_out) |io| io.* = tot;
                return error.Corrupt;
            }
        }
        first = false;
    }
}

fn applySuffix(cfg: *const Cfg, name: []const u8) ?[]const u8 {
    if (cfg.suffix) |suf| {
        if (std.mem.endsWith(u8, name, suf) and name.len > suf.len) return name[0 .. name.len - suf.len];
        return null;
    }
    const map = [_][2][]const u8{ .{ ".xz", "" }, .{ ".txz", ".tar" }, .{ ".lzma", "" }, .{ ".tlz", ".tar" } };
    for (map) |m| {
        if (std.mem.endsWith(u8, name, m[0]) and name.len > m[0].len) {
            return std.fmt.allocPrint(u.alloc, "{s}{s}", .{ name[0 .. name.len - m[0].len], m[1] }) catch null;
        }
    }
    return null;
}

fn copyMeta(src_st: u.Stat, out_fd: i32, out_path: []const u8) void {
    _ = linux.fchown(out_fd, src_st.uid, src_st.gid);
    _ = linux.fchmod(out_fd, @intCast(src_st.mode & 0o7777 & ~@as(u32, 0o6000)));
    var times = [2]linux.timespec{ .{ .sec = @intCast(src_st.atime), .nsec = @intCast(src_st.atime_nsec) }, .{ .sec = @intCast(src_st.mtime), .nsec = @intCast(src_st.mtime_nsec) } };
    _ = linux.utimensat(linux.AT.FDCWD, u.zstr(out_path), &times, 0);
}

fn verboseLine(name: []const u8, comp: u64, unc: u64) void {
    var a = u.Vec(u8).init(u.alloc);
    var b = u.Vec(u8).init(u.alloc);
    fmtSize(comp, &a);
    fmtSize(unc, &b);
    var rb: [16]u8 = undefined;
    const ratio: f64 = if (unc == 0) 0 else @as(f64, @floatFromInt(comp)) / @as(f64, @floatFromInt(unc));
    const rs = if (unc == 0) "---" else (std.fmt.bufPrint(&rb, "{d:.3}", .{ratio}) catch "");
    u.errf("{s}: {s} / {s} {s} {s}\n", .{ name, a.items, b.items, if (ratio > 9.999) ">" else "=", if (ratio > 9.999) "9.999" else rs });
}

fn processFile(cfg: *const Cfg, name: []const u8) u8 {
    const is_stdin = std.mem.eql(u8, name, "-");
    var in_fd: i32 = 0;
    var st: ?u.Stat = null;
    if (!is_stdin) {
        st = u.stat(name, false);
        if (st == null) {
            msg(cfg, "{s}: No such file or directory", .{name});
            return 1;
        }
        const t = st.?.mode & linux.S.IFMT;
        if (t != linux.S.IFREG) {
            // symlinks to regular files are fine with --stdout
            var ok2 = false;
            if (cfg.stdout or cfg.force) if (u.stat(name, true)) |s2| {
                if (s2.mode & linux.S.IFMT == linux.S.IFREG) {
                    st = s2;
                    ok2 = true;
                }
            };
            if (!ok2) {
                const why: []const u8 = if (t == linux.S.IFLNK) "Is a symbolic link" else if (t == linux.S.IFDIR) "Is a directory" else "Not a regular file";
                wmsg(cfg, "{s}: {s}, skipping", .{ name, why });
                warned = true;
                return 0;
            }
        }
        if (!cfg.stdout and !cfg.force and cfg.mode != .test_ and cfg.mode != .list and st.?.nlink > 1) {
            wmsg(cfg, "{s}: Input file has more than one hard link, skipping", .{name});
            warned = true;
            return 0;
        }
        const rc = linux.open(u.zstr(name), .{ .ACCMODE = .RDONLY }, 0);
        if (!u.ok(rc)) {
            msg(cfg, "{s}: {s}", .{ name, u.strerr(u.errno(rc)) });
            return 1;
        }
        in_fd = @intCast(rc);
    }
    defer if (!is_stdin) {
        _ = linux.close(in_fd);
    };
    const to_stdout = cfg.stdout or is_stdin;
    const disp: []const u8 = if (is_stdin) "(stdin)" else name;
    switch (cfg.mode) {
        .test_, .decompress => {
            if (!is_stdin and st != null) {
                var hb: [13]u8 = undefined;
                const nr = linux.pread(in_fd, &hb, hb.len, 0);
                const got: usize = if (u.ok(nr)) nr else 0;
                const is_xz = got >= 6 and std.mem.eql(u8, hb[0..6], "\xFD7zXZ\x00");
                const ok_fmt = switch (cfg.format) {
                    .xz => is_xz,
                    .lzma => isLzmaAlone(hb[0..got]),
                    .auto => is_xz or isLzmaAlone(hb[0..got]),
                };
                if (!ok_fmt) {
                    msg(cfg, "{s}: File format not recognized", .{disp});
                    return 1;
                }
            }
            var dest: ?[]const u8 = null;
            if (!to_stdout and cfg.mode == .decompress) {
                dest = applySuffix(cfg, name);
                if (dest == null) {
                    wmsg(cfg, "{s}: Filename has an unknown suffix, skipping", .{name});
                    warned = true;
                    return 0;
                }
            }
            if (is_stdin and isTty(0)) {
                msg(cfg, "Compressed data cannot be read from a terminal", .{});
                return 1;
            }
            var out_fd: i32 = 1;
            var created = false;
            if (dest) |d| {
                if (u.stat(d, false) != null) {
                    if (!cfg.force) {
                        msg(cfg, "{s}: File exists", .{d});
                        return 1;
                    }
                    _ = linux.unlink(u.zstr(d));
                }
                const rc = linux.open(u.zstr(d), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
                if (!u.ok(rc)) {
                    msg(cfg, "{s}: {s}", .{ d, u.strerr(u.errno(rc)) });
                    return 1;
                }
                out_fd = @intCast(rc);
                created = true;
            }
            var di = StreamInfo{};
            const res = decodeAll(cfg, in_fd, out_fd, cfg.mode == .test_, &di);
            if (res) |_| {
                // an empty input file is not a valid compressed file
                if (di.blocks == 0 and di.unc == 0 and st != null and st.?.size == 0) {
                    msg(cfg, "{s}: File format not recognized", .{disp});
                    if (created) {
                        _ = linux.close(out_fd);
                        _ = linux.unlink(u.zstr(dest.?));
                    }
                    return 1;
                }
            } else |e| {
                msg(cfg, "{s}: {s}", .{ disp, errText(e) });
                if (created) {
                    _ = linux.close(out_fd);
                    _ = linux.unlink(u.zstr(dest.?));
                }
                return 1;
            }
            if (created) {
                if (st) |s| copyMeta(s, out_fd, dest.?);
                _ = linux.close(out_fd);
                if (!cfg.keep) _ = linux.unlink(u.zstr(name));
            }
            if (cfg.verbose and !is_stdin) verboseLine(disp, if (st) |s0| s0.size else 0, di.unc);
            return 0;
        },
        .compress => {
            const fmt: Format = if (cfg.format == .auto) .xz else cfg.format;
            const suffix: []const u8 = cfg.suffix orelse (if (fmt == .lzma) ".lzma" else ".xz");
            if (!to_stdout) {
                const known = [_][]const u8{ ".xz", ".txz", ".lzma", ".tlz" };
                var has = std.mem.endsWith(u8, name, suffix);
                if (cfg.suffix == null) for (known) |k| if (std.mem.endsWith(u8, name, k)) {
                    has = true;
                };
                if (has) {
                    wmsg(cfg, "{s}: File already has '{s}' suffix, skipping", .{ name, suffix });
                    warned = true;
                    return 0;
                }
            } else if (isTty(1)) {
                msg(cfg, "Compressed data cannot be written to a terminal", .{});
                return 1;
            }
            const data = readAllFd(in_fd) orelse {
                msg(cfg, "{s}: Read error", .{disp});
                return 1;
            };
            var out = u.Vec(u8).init(u.alloc);
            const lvl = levelParams(cfg.level, cfg.extreme);
            const r = if (fmt == .lzma) compressLzma(data, lvl, &out) else compressXz(data, lvl, cfg.check, &out);
            r catch |e| {
                msg(cfg, "{s}: {s}", .{ disp, errText(e) });
                return 1;
            };
            if (to_stdout) {
                writeAll(1, out.items) catch {
                    msg(cfg, "Write error", .{});
                    return 1;
                };
                if (cfg.verbose and !is_stdin) verboseLine(disp, out.items.len, data.len);
                return 0;
            }
            const dest = std.fmt.allocPrint(u.alloc, "{s}{s}", .{ name, suffix }) catch return 1;
            if (u.stat(dest, false) != null) {
                if (!cfg.force) {
                    msg(cfg, "{s}: File exists", .{dest});
                    return 1;
                }
                _ = linux.unlink(u.zstr(dest));
            }
            const rc = linux.open(u.zstr(dest), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
            if (!u.ok(rc)) {
                msg(cfg, "{s}: {s}", .{ dest, u.strerr(u.errno(rc)) });
                return 1;
            }
            const ofd: i32 = @intCast(rc);
            writeAll(ofd, out.items) catch {
                msg(cfg, "{s}: Write error", .{dest});
                _ = linux.close(ofd);
                _ = linux.unlink(u.zstr(dest));
                return 1;
            };
            copyMeta(st.?, ofd, dest);
            _ = linux.close(ofd);
            if (!cfg.keep) _ = linux.unlink(u.zstr(name));
            if (cfg.verbose) verboseLine(disp, out.items.len, data.len);
            return 0;
        },
        .list => {
            if (is_stdin) {
                u.errf("xz: --list does not support reading from standard input\n", .{});
                return 1;
            }
            return listFile(cfg, name, in_fd);
        },
    }
}

// ---------------------------------------------------------------- --list
const ListTotals = struct { files: u32 = 0, strms: u64 = 0, blocks: u64 = 0, comp: u64 = 0, unc: u64 = 0 };

fn fmtSize(n: u64, o: *u.Vec(u8)) void {
    // xz style: bytes below 10000, otherwise one decimal in the first unit whose value is below 10000
    var buf: [48]u8 = undefined;
    if (n < 10000) {
        o.pushSlice(std.fmt.bufPrint(&buf, "{d} B", .{n}) catch "");
        return;
    }
    const units = [_][]const u8{ "KiB", "MiB", "GiB", "TiB", "PiB" };
    var v: f64 = @floatFromInt(n);
    var k: usize = 0;
    v /= 1024.0;
    while (v >= 9999.95 and k < 4) : (k += 1) v /= 1024.0;
    o.pushSlice(std.fmt.bufPrint(&buf, "{d:.1} {s}", .{ v, units[k] }) catch "");
}

var list_hdr_done = false;
var list_tot = ListTotals{};
var list_check: CheckKind = .none;

fn listTotals() void {
    if (list_tot.files < 2) return;
    var c1 = u.Vec(u8).init(u.alloc);
    fmtSize(list_tot.comp, &c1);
    var c2 = u.Vec(u8).init(u.alloc);
    fmtSize(list_tot.unc, &c2);
    const ratio: f64 = if (list_tot.unc == 0) 0 else @as(f64, @floatFromInt(list_tot.comp)) / @as(f64, @floatFromInt(list_tot.unc));
    var rb: [16]u8 = undefined;
    const rs = if (list_tot.unc == 0) "---" else if (ratio > 9.999) "> 9.999" else (std.fmt.bufPrint(&rb, "{d:.3}", .{ratio}) catch "");
    const chk_name: []const u8 = switch (list_check) {
        .none => "None",
        .crc32 => "CRC32",
        .crc64 => "CRC64",
        .sha256 => "SHA-256",
    };
    u.out("-------------------------------------------------------------------------------\n");
    u.outf("{d: >5} {d: >7} {s: >12} {s: >12} {s: >6}  {s: <7} {d} files\n", .{ list_tot.strms, list_tot.blocks, c1.items, c2.items, rs, chk_name, list_tot.files });
}

fn listFile(cfg: *const Cfg, name: []const u8, in_fd: i32) u8 {
    _ = cfg;
    const data = readAllFd(in_fd) orelse return 1;
    if (data.len == 0) {
        u.errf("xz: {s}: File is empty\n", .{name});
        return 1;
    }
    if (data.len < 24 or !std.mem.eql(u8, data[0..6], "\xFD7zXZ\x00")) {
        u.errf("xz: {s}: File format not recognized\n", .{name});
        return 1;
    }
    // walk the streams from the end using the footers
    var strms: u64 = 0;
    var blocks: u64 = 0;
    var unc: u64 = 0;
    var end = data.len;
    var check: CheckKind = .none;
    while (end >= 24) {
        // skip stream padding
        while (end >= 4 and std.mem.readInt(u32, data[end - 4 ..][0..4], .little) == 0) end -= 4;
        if (end < 24) break;
        const ft = data[end - 12 .. end];
        if (!std.mem.eql(u8, ft[10..12], "YZ")) {
            u.errf("xz: {s}: File format not recognized\n", .{name});
            return 1;
        }
        const back = (@as(usize, std.mem.readInt(u32, ft[4..8][0..4], .little)) + 1) * 4;
        if (end < 12 + back + 12) return 1;
        const idx = data[end - 12 - back .. end - 12];
        var p: usize = 1;
        const rd = struct {
            fn f(b: []const u8, o: *usize) u64 {
                var v: u64 = 0;
                var sh: u6 = 0;
                while (o.* < b.len) {
                    const x = b[o.*];
                    o.* += 1;
                    v |= @as(u64, x & 0x7f) << sh;
                    if (x & 0x80 == 0) break;
                    sh += 7;
                }
                return v;
            }
        }.f;
        const n = rd(idx, &p);
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            _ = rd(idx, &p);
            unc += rd(idx, &p);
        }
        blocks += n;
        strms += 1;
        check = kindFromId(ft[9] & 0x0f) orelse .none;
        const stream_len = 12 + back + 12;
        // the stream begins stream_len + compressed blocks earlier; use header search by walking back is complex,
        // so account for it by scanning blocks sizes in the index
        var total_blocks: usize = 0;
        var q: usize = 1;
        _ = rd(idx, &q);
        var j: u64 = 0;
        while (j < n) : (j += 1) {
            const unp = rd(idx, &q);
            _ = rd(idx, &q);
            total_blocks += @intCast((unp + 3) / 4 * 4);
        }
        if (end < stream_len + total_blocks) return 1;
        end -= stream_len + total_blocks;
        if (end == 0) break;
    }
    var o = u.Vec(u8).init(u.alloc);
    if (!list_hdr_done) o.pushSlice("Strms  Blocks   Compressed Uncompressed  Ratio  Check   Filename\n");
    list_hdr_done = true;
    list_tot.files += 1;
    list_tot.strms += strms;
    list_tot.blocks += blocks;
    list_tot.comp += data.len;
    list_tot.unc += unc;
    list_check = check;
    var c1 = u.Vec(u8).init(u.alloc);
    fmtSize(data.len, &c1);
    var c2 = u.Vec(u8).init(u.alloc);
    fmtSize(unc, &c2);
    const ratio: f64 = if (unc == 0) 0 else @as(f64, @floatFromInt(data.len)) / @as(f64, @floatFromInt(unc));
    const chk_name: []const u8 = switch (check) {
        .none => "None",
        .crc32 => "CRC32",
        .crc64 => "CRC64",
        .sha256 => "SHA-256",
    };
    var rb: [16]u8 = undefined;
    const rs = if (unc == 0) "---" else if (ratio > 9.999) "> 9.999" else (std.fmt.bufPrint(&rb, "{d:.3}", .{ratio}) catch "");
    o.pushSlice(std.fmt.allocPrint(u.alloc, "{d: >5} {d: >7} {s: >12} {s: >12} {s: >6}  {s: <7} {s}\n", .{ strms, blocks, c1.items, c2.items, rs, chk_name, name }) catch "");
    u.out(o.items);
    return 0;
}

pub fn run(args: []const []const u8) u8 {
    return runAs(args, u.applet_name);
}

fn runAs(args: []const []const u8, prog_name: []const u8) u8 {
    const name = u.basename(prog_name);
    var cfg = Cfg{};
    cfg.prog = name;
    if (std.mem.eql(u8, name, "unxz")) cfg.mode = .decompress else if (std.mem.eql(u8, name, "xzcat")) {
        cfg.mode = .decompress;
        cfg.stdout = true;
    } else if (std.mem.eql(u8, name, "lzma")) cfg.format = .lzma else if (std.mem.eql(u8, name, "unlzma")) {
        cfg.mode = .decompress;
        cfg.format = .lzma;
    } else if (std.mem.eql(u8, name, "lzcat")) {
        cfg.mode = .decompress;
        cfg.stdout = true;
        cfg.format = .lzma;
    }
    const opts = [_]g.Opt{
        .{ .name = "compress", .key = 'z' },
        .{ .name = "decompress", .key = 'd' },
        .{ .name = "uncompress", .key = 'd' },
        .{ .name = "test", .key = 't' },
        .{ .name = "list", .key = 'l' },
        .{ .name = "keep", .key = 'k' },
        .{ .name = "force", .key = 'f' },
        .{ .name = "stdout", .key = 'c' },
        .{ .name = "to-stdout", .key = 'c' },
        .{ .name = "suffix", .key = 'S', .arg = .req },
        .{ .name = "format", .key = 'F', .arg = .req },
        .{ .name = "check", .key = 'C', .arg = .req },
        .{ .name = "quiet", .key = 'q' },
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "extreme", .key = 'e' },
        .{ .name = "fast", .key = '0' },
        .{ .name = "best", .key = '9' },
        .{ .name = "threads", .key = 'T', .arg = .req },
        .{ .name = "memlimit", .key = 'M', .arg = .req },
        .{ .name = "no-warn", .key = 'Q' },
        .{ .name = "help", .key = 'h' },
        .{ .name = "version", .key = 'V' },
        .{ .key = '1' },
        .{ .key = '2' },
        .{ .key = '3' },
        .{ .key = '4' },
        .{ .key = '5' },
        .{ .key = '6' },
        .{ .key = '7' },
        .{ .key = '8' },
    };
    var p = g.Parser.init(name, args, &opts);
    p.hint_prefix = true;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'z' => cfg.mode = .compress,
            'd' => cfg.mode = .decompress,
            't' => cfg.mode = .test_,
            'l' => cfg.mode = .list,
            'k' => cfg.keep = true,
            'f' => cfg.force = true,
            'c' => cfg.stdout = true,
            'S' => cfg.suffix = it.val,
            'F' => {
                const v = it.val.?;
                if (std.mem.eql(u8, v, "auto")) cfg.format = .auto else if (std.mem.eql(u8, v, "xz")) cfg.format = .xz else if (std.mem.eql(u8, v, "lzma") or std.mem.eql(u8, v, "alone")) cfg.format = .lzma else {
                    u.errf("{s}: {s}: Unknown file format type\n", .{ name, v });
                    return 1;
                }
            },
            'C' => {
                const v = it.val.?;
                cfg.check = if (std.mem.eql(u8, v, "none")) .none else if (std.mem.eql(u8, v, "crc32")) .crc32 else if (std.mem.eql(u8, v, "crc64")) .crc64 else if (std.mem.eql(u8, v, "sha256")) .sha256 else {
                    u.errf("{s}: {s}: Unsupported integrity check type\n", .{ name, v });
                    return 1;
                };
            },
            'q' => cfg.quiet += 1,
            'v' => cfg.verbose = true,
            'e' => cfg.extreme = true,
            'T', 'M', 'Q' => {},
            'h' => {
                u.outf("Usage: {s} [OPTION]... [FILE]...\nCompress or decompress .xz and .lzma files.\n", .{name});
                return 0;
            },
            'V' => {
                u.out("xz (cmdbox) 5.8.2\nliblzma (cmdbox) 5.8.2\n");
                return 0;
            },
            '0'...'9' => cfg.level = it.key - '0',
            else => {},
        }
    }
    var rc: u8 = 0;
    const ops = p.operands.items;
    if (ops.len == 0) {
        rc = processFile(&cfg, "-");
    } else for (ops) |f| {
        const r = processFile(&cfg, f);
        if (r > rc) rc = r;
    }
    if (cfg.mode == .list) listTotals();
    if (rc == 0 and warned and cfg.quiet < 2) rc = 2;
    return rc;
}

pub fn xz(args: []const []const u8) u8 {
    return runAs(args, "xz");
}
pub fn unxz(args: []const []const u8) u8 {
    return runAs(args, "unxz");
}
pub fn xzcat(args: []const []const u8) u8 {
    return runAs(args, "xzcat");
}
pub fn lzma(args: []const []const u8) u8 {
    return runAs(args, "lzma");
}
pub fn unlzma(args: []const []const u8) u8 {
    return runAs(args, "unlzma");
}
pub fn lzcat(args: []const []const u8) u8 {
    return runAs(args, "lzcat");
}
