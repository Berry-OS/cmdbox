// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// bzip2 bunzip2 bzcat - bzip2 compatible compressor / decompressor (own implementation)
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");

const Error = error{ NotBz, Truncated, Corrupt, Crc, NoMem, Io, Unsupported };

// ---------------------------------------------------------------- CRC (MSB first, poly 0x04c11db7)
const crc_table: [256]u32 = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @as(u32, @intCast(i)) << 24;
        for (0..8) |_| c = if (c & 0x80000000 != 0) (c << 1) ^ 0x04c11db7 else c << 1;
        t[i] = c;
    }
    break :blk t;
};

fn crcUpdate(crc: u32, d: []const u8) u32 {
    var c = crc;
    for (d) |b| c = (c << 8) ^ crc_table[(c >> 24) ^ b];
    return c;
}

// ---------------------------------------------------------------- bit reader
const BitReader = struct {
    fd: i32,
    buf: [65536]u8 = undefined,
    pos: usize = 0,
    end: usize = 0,
    acc: u64 = 0,
    nbits: u6 = 0,
    total: u64 = 0,

    fn fill(self: *BitReader) Error!bool {
        while (true) {
            const r = linux.read(self.fd, &self.buf, self.buf.len);
            if (u.errno(r) == .INTR) continue;
            if (!u.ok(r)) return error.Io;
            if (r == 0) return false;
            self.pos = 0;
            self.end = r;
            return true;
        }
    }

    fn bits(self: *BitReader, n: u6) Error!u32 {
        while (self.nbits < n) {
            if (self.pos >= self.end) {
                if (!try self.fill()) return error.Truncated;
            }
            self.acc = (self.acc << 8) | self.buf[self.pos];
            self.pos += 1;
            self.total += 1;
            self.nbits += 8;
        }
        self.nbits -= n;
        return @intCast((self.acc >> self.nbits) & ((@as(u64, 1) << n) - 1));
    }

    fn bit(self: *BitReader) Error!u1 {
        return @intCast(try self.bits(1));
    }

    fn alignByte(self: *BitReader) void {
        self.nbits -= self.nbits % 8;
    }

    /// true when no more input is available (after alignment)
    fn atEof(self: *BitReader) Error!bool {
        if (self.nbits >= 8) return false;
        if (self.pos < self.end) return false;
        return !(try self.fill());
    }
};

// ---------------------------------------------------------------- decoder
const BLOCK_MAGIC: u64 = 0x314159265359;
const END_MAGIC: u64 = 0x177245385090;

const Out = struct {
    fd: i32,
    discard: bool,
    buf: u.Vec(u8),
    total: u64 = 0,

    fn flush(self: *Out) Error!void {
        if (self.buf.items.len > 0 and !self.discard) try writeAll(self.fd, self.buf.items);
        self.buf.items.len = 0;
    }

    fn put(self: *Out, d: []const u8) Error!void {
        self.buf.pushSlice(d);
        self.total += d.len;
        if (self.buf.items.len >= 1 << 16) try self.flush();
    }
};

fn writeAll(fd: i32, data: []const u8) Error!void {
    var off: usize = 0;
    while (off < data.len) {
        const r = linux.write(fd, data.ptr + off, data.len - off);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r)) return error.Io;
        off += r;
    }
}

fn magic48(br: *BitReader) Error!u64 {
    const hi = try br.bits(24);
    const lo = try br.bits(24);
    return (@as(u64, hi) << 24) | lo;
}

fn makeDecodeTables(limit: *[24]i32, base: *[24]i32, perm: *[258]u16, length: []const u8, min_len: usize, max_len: usize, alpha: usize) void {
    var pp: usize = 0;
    var i: usize = min_len;
    while (i <= max_len) : (i += 1) {
        for (0..alpha) |j| if (length[j] == i) {
            perm[pp] = @intCast(j);
            pp += 1;
        };
    }
    @memset(base, 0);
    for (0..alpha) |k| base[length[k] + 1] += 1;
    for (1..24) |k| base[k] += base[k - 1];
    @memset(limit, 0);
    var vec: i32 = 0;
    i = min_len;
    while (i <= max_len) : (i += 1) {
        vec += base[i + 1] - base[i];
        limit[i] = vec - 1;
        vec <<= 1;
    }
    i = min_len + 1;
    while (i <= max_len) : (i += 1) base[i] = ((limit[i - 1] + 1) << 1) - base[i];
}

fn decodeStream(br: *BitReader, out: *Out, first: bool) Error!bool {
    // returns false when no further stream follows
    if (!first) {
        br.alignByte();
        if (try br.atEof()) return false;
    }
    const b = try br.bits(8);
    const z = br.bits(8) catch return if (first) error.NotBz else error.NotBz;
    const h = br.bits(8) catch return error.NotBz;
    const lv = br.bits(8) catch return error.NotBz;
    if (b != 'B' or z != 'Z' or h != 'h' or lv < '1' or lv > '9') {
        if (first) return error.NotBz;
        return error.NotBz;
    }
    const level: u32 = lv - '0';
    const block_max: usize = 100000 * level;
    const tt = u.alloc.alloc(u32, block_max) catch return error.NoMem;
    defer u.alloc.free(tt);
    var combined: u32 = 0;
    while (true) {
        const mg = try magic48(br);
        if (mg == END_MAGIC) {
            const stored = try br.bits(32);
            if (stored != combined) return error.Crc;
            return true;
        }
        if (mg != BLOCK_MAGIC) return error.Corrupt;
        const stored_crc = try br.bits(32);
        if (try br.bit() == 1) return error.Unsupported; // randomised blocks are obsolete
        const orig_ptr = try br.bits(24);
        // symbol map
        var seq_to_unseq: [256]u8 = undefined;
        var n_in_use: usize = 0;
        const in16 = try br.bits(16);
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            if (in16 & (@as(u32, 0x8000) >> @intCast(i)) != 0) {
                const b16 = try br.bits(16);
                var j: usize = 0;
                while (j < 16) : (j += 1) {
                    if (b16 & (@as(u32, 0x8000) >> @intCast(j)) != 0) {
                        seq_to_unseq[n_in_use] = @intCast(i * 16 + j);
                        n_in_use += 1;
                    }
                }
            }
        }
        if (n_in_use == 0) return error.Corrupt;
        const alpha = n_in_use + 2;
        const n_groups = try br.bits(3);
        if (n_groups < 2 or n_groups > 6) return error.Corrupt;
        const n_sel = try br.bits(15);
        if (n_sel < 1) return error.Corrupt;
        const selectors = u.alloc.alloc(u8, n_sel) catch return error.NoMem;
        defer u.alloc.free(selectors);
        var pos = [_]u8{ 0, 1, 2, 3, 4, 5 };
        i = 0;
        while (i < n_sel) : (i += 1) {
            var j: usize = 0;
            while (try br.bit() == 1) {
                j += 1;
                if (j >= n_groups) return error.Corrupt;
            }
            const v = pos[j];
            while (j > 0) : (j -= 1) pos[j] = pos[j - 1];
            pos[0] = v;
            selectors[i] = v;
        }
        // coding tables
        var lens: [6][258]u8 = undefined;
        var t: usize = 0;
        while (t < n_groups) : (t += 1) {
            var curr: i32 = @intCast(try br.bits(5));
            var k: usize = 0;
            while (k < alpha) : (k += 1) {
                while (true) {
                    if (curr < 1 or curr > 20) return error.Corrupt;
                    if (try br.bit() == 0) break;
                    if (try br.bit() == 0) curr += 1 else curr -= 1;
                }
                lens[t][k] = @intCast(curr);
            }
        }
        var limit: [6][24]i32 = undefined;
        var base: [6][24]i32 = undefined;
        var perm: [6][258]u16 = undefined;
        var min_len: [6]usize = undefined;
        t = 0;
        while (t < n_groups) : (t += 1) {
            var mn: usize = 32;
            var mx: usize = 0;
            for (lens[t][0..alpha]) |l| {
                mn = @min(mn, l);
                mx = @max(mx, l);
            }
            min_len[t] = mn;
            makeDecodeTables(&limit[t], &base[t], &perm[t], lens[t][0..alpha], mn, mx, alpha);
        }
        // MTF / RLE2 decoding
        var yy: [256]u8 = undefined;
        for (0..256) |k| yy[k] = @intCast(k);
        var unzftab = [_]u32{0} ** 256;
        const eob = alpha - 1;
        var nblock: usize = 0;
        var group_no: usize = 0;
        var group_pos: usize = 0;
        var cur: usize = 0;
        const next = struct {
            fn sym(brr: *BitReader, gn: *usize, gp: *usize, c: *usize, sels: []const u8, n_sel_: usize, lim: *const [6][24]i32, bas: *const [6][24]i32, prm: *const [6][258]u16, mnl: *const [6]usize) Error!usize {
                if (gp.* == 0) {
                    if (gn.* >= n_sel_) return error.Corrupt;
                    c.* = sels[gn.*];
                    gn.* += 1;
                    gp.* = 50;
                }
                gp.* -= 1;
                const tb = c.*;
                var zn = mnl[tb];
                var zvec: i32 = @intCast(try brr.bits(@intCast(zn)));
                while (true) {
                    if (zn > 20) return error.Corrupt;
                    if (zvec <= lim[tb][zn]) break;
                    zn += 1;
                    zvec = (zvec << 1) | @as(i32, try brr.bit());
                }
                const idx = zvec - bas[tb][zn];
                if (idx < 0 or idx >= 258) return error.Corrupt;
                return prm[tb][@intCast(idx)];
            }
        }.sym;
        var sym = try next(br, &group_no, &group_pos, &cur, selectors, n_sel, &limit, &base, &perm, &min_len);
        while (true) {
            if (sym == eob) break;
            if (sym <= 1) {
                var es: i64 = -1;
                var nn: i64 = 1;
                while (sym <= 1) {
                    es += if (sym == 0) nn else 2 * nn;
                    nn *= 2;
                    if (nn > 1 << 24) return error.Corrupt;
                    sym = try next(br, &group_no, &group_pos, &cur, selectors, n_sel, &limit, &base, &perm, &min_len);
                }
                es += 1;
                const uc = seq_to_unseq[yy[0]];
                unzftab[uc] += @intCast(es);
                if (nblock + @as(usize, @intCast(es)) > block_max) return error.Corrupt;
                var c: i64 = 0;
                while (c < es) : (c += 1) {
                    tt[nblock] = uc;
                    nblock += 1;
                }
                continue;
            }
            if (nblock >= block_max) return error.Corrupt;
            const mi = sym - 1;
            if (mi >= n_in_use) return error.Corrupt;
            const v = yy[mi];
            var k = mi;
            while (k > 0) : (k -= 1) yy[k] = yy[k - 1];
            yy[0] = v;
            const uc = seq_to_unseq[v];
            unzftab[uc] += 1;
            tt[nblock] = uc;
            nblock += 1;
            sym = try next(br, &group_no, &group_pos, &cur, selectors, n_sel, &limit, &base, &perm, &min_len);
        }
        if (orig_ptr >= nblock) return error.Corrupt;
        // inverse BWT
        var cftab: [257]u32 = undefined;
        cftab[0] = 0;
        for (0..256) |k| cftab[k + 1] = cftab[k] + unzftab[k];
        i = 0;
        while (i < nblock) : (i += 1) {
            const uc: u8 = @truncate(tt[i]);
            tt[cftab[uc]] |= @as(u32, @intCast(i)) << 8;
            cftab[uc] += 1;
        }
        var tpos: u32 = tt[orig_ptr] >> 8;
        var crc: u32 = 0xFFFFFFFF;
        var last: i32 = -1;
        var run: u32 = 0;
        var chunk: [4096]u8 = undefined;
        var cn: usize = 0;
        i = 0;
        while (i < nblock) : (i += 1) {
            tpos = tt[tpos];
            const ch: u8 = @truncate(tpos);
            tpos >>= 8;
            if (run == 4) {
                var r: u32 = ch;
                while (r > 0) : (r -= 1) {
                    if (cn == chunk.len) {
                        crc = crcUpdate(crc, chunk[0..cn]);
                        try out.put(chunk[0..cn]);
                        cn = 0;
                    }
                    chunk[cn] = @intCast(last);
                    cn += 1;
                }
                run = 0;
                last = -1;
                continue;
            }
            if (cn == chunk.len) {
                crc = crcUpdate(crc, chunk[0..cn]);
                try out.put(chunk[0..cn]);
                cn = 0;
            }
            chunk[cn] = ch;
            cn += 1;
            if (ch == last) {
                run += 1;
            } else {
                last = ch;
                run = 1;
            }
        }
        crc = crcUpdate(crc, chunk[0..cn]);
        try out.put(chunk[0..cn]);
        crc = ~crc;
        if (crc != stored_crc) return error.Crc;
        combined = ((combined << 1) | (combined >> 31)) ^ crc;
    }
}

// ---------------------------------------------------------------- encoder
const BitWriter = struct {
    out: *u.Vec(u8),
    acc: u64 = 0,
    n: u6 = 0,

    fn put(self: *BitWriter, nbits: u6, value: u32) void {
        const mask: u64 = (@as(u64, 1) << nbits) - 1;
        self.acc = (self.acc << nbits) | (@as(u64, value) & mask);
        self.n += nbits;
        while (self.n >= 8) {
            self.n -= 8;
            self.out.push(@truncate(self.acc >> self.n));
        }
    }

    fn flush(self: *BitWriter) void {
        if (self.n > 0) {
            self.out.push(@truncate(self.acc << (8 - self.n)));
            self.n = 0;
        }
    }
};

/// Sort cyclic rotations of s; returns the permutation (rotation start indices in sorted order).
fn sortRotations(s: []const u8) Error![]u32 {
    const n = s.len;
    const p = u.alloc.alloc(u32, n) catch return error.NoMem;
    var c = u.alloc.alloc(u32, n) catch return error.NoMem;
    var pn = u.alloc.alloc(u32, n) catch return error.NoMem;
    var cn = u.alloc.alloc(u32, n) catch return error.NoMem;
    defer {
        u.alloc.free(c);
        u.alloc.free(pn);
        u.alloc.free(cn);
    }
    var cnt = u.alloc.alloc(u32, @max(n, 256)) catch return error.NoMem;
    defer u.alloc.free(cnt);
    // initial counting sort by first byte
    @memset(cnt[0..256], 0);
    for (s) |b| cnt[b] += 1;
    for (1..256) |i| cnt[i] += cnt[i - 1];
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        cnt[s[i]] -= 1;
        p[cnt[s[i]]] = @intCast(i);
    }
    c[p[0]] = 0;
    var classes: u32 = 1;
    for (1..n) |k| {
        if (s[p[k]] != s[p[k - 1]]) classes += 1;
        c[p[k]] = classes - 1;
    }
    var h: usize = 0;
    while ((@as(usize, 1) << @intCast(h)) < n and classes < n) : (h += 1) {
        const half = @as(usize, 1) << @intCast(h);
        for (0..n) |k| {
            const v: isize = @as(isize, @intCast(p[k])) - @as(isize, @intCast(half));
            pn[k] = @intCast(if (v < 0) v + @as(isize, @intCast(n)) else v);
        }
        @memset(cnt[0..classes], 0);
        for (0..n) |k| cnt[c[pn[k]]] += 1;
        for (1..classes) |k| cnt[k] += cnt[k - 1];
        var k2: usize = n;
        while (k2 > 0) {
            k2 -= 1;
            cnt[c[pn[k2]]] -= 1;
            p[cnt[c[pn[k2]]]] = pn[k2];
        }
        cn[p[0]] = 0;
        classes = 1;
        for (1..n) |k| {
            const a1 = c[p[k]];
            const a2 = c[(p[k] + half) % n];
            const b1 = c[p[k - 1]];
            const b2 = c[(p[k - 1] + half) % n];
            if (a1 != b1 or a2 != b2) classes += 1;
            cn[p[k]] = classes - 1;
        }
        std.mem.swap([]u32, &c, &cn);
    }
    return p;
}

/// Huffman code lengths limited to max_len (same scaling trick as the reference implementation).
fn makeCodeLengths(len: []u8, freq: []const u32, max_len: u8) void {
    const alpha = freq.len;
    var weight: [258]u64 = undefined;
    var parent: [516]i32 = undefined;
    var scale: u32 = 0;
    while (true) {
        var nodes = u.Vec(struct { w: u64, id: u32 }).init(u.alloc);
        for (0..alpha) |i| {
            const f: u64 = if (freq[i] == 0) 1 else freq[i];
            weight[i] = (f << 8) >> @intCast(scale);
            if (weight[i] == 0) weight[i] = 1;
            nodes.push(.{ .w = weight[i], .id = @intCast(i) });
        }
        @memset(&parent, -1);
        var next_id: u32 = @intCast(alpha);
        var wts: [516]u64 = undefined;
        for (0..alpha) |i| wts[i] = weight[i];
        while (nodes.items.len > 1) {
            // pick the two smallest
            var a: usize = 0;
            for (nodes.items, 0..) |nd, i| if (nd.w < nodes.items[a].w or (nd.w == nodes.items[a].w and nd.id < nodes.items[a].id)) {
                a = i;
            };
            const na = nodes.items[a];
            nodes.items[a] = nodes.items[nodes.items.len - 1];
            nodes.items.len -= 1;
            var b: usize = 0;
            for (nodes.items, 0..) |nd, i| if (nd.w < nodes.items[b].w or (nd.w == nodes.items[b].w and nd.id < nodes.items[b].id)) {
                b = i;
            };
            const nb = nodes.items[b];
            nodes.items[b] = nodes.items[nodes.items.len - 1];
            nodes.items.len -= 1;
            parent[na.id] = @intCast(next_id);
            parent[nb.id] = @intCast(next_id);
            wts[next_id] = na.w + nb.w;
            nodes.push(.{ .w = na.w + nb.w, .id = next_id });
            next_id += 1;
        }
        var too_long = false;
        for (0..alpha) |i| {
            var d: u32 = 0;
            var k: i32 = @intCast(i);
            while (parent[@intCast(k)] >= 0) : (d += 1) k = parent[@intCast(k)];
            if (alpha == 1) d = 1;
            len[i] = @intCast(@min(d, 255));
            if (d > max_len) too_long = true;
        }
        if (!too_long) return;
        scale += 1;
    }
}

const Block = struct {
    data: []u8,
    n: usize = 0,
    crc: u32 = 0xFFFFFFFF,
};

fn encodeBlock(bw: *BitWriter, blk: []const u8, crc: u32) Error!void {
    const n = blk.len;
    const p = try sortRotations(blk);
    defer u.alloc.free(p);
    var orig_ptr: u32 = 0;
    var last_col = u.alloc.alloc(u8, n) catch return error.NoMem;
    defer u.alloc.free(last_col);
    for (0..n) |i| {
        if (p[i] == 0) orig_ptr = @intCast(i);
        last_col[i] = blk[(p[i] + n - 1) % n];
    }
    var in_use = [_]bool{false} ** 256;
    for (blk) |b| in_use[b] = true;
    var unseq_to_seq: [256]u8 = undefined;
    var n_in_use: usize = 0;
    for (0..256) |i| if (in_use[i]) {
        unseq_to_seq[i] = @intCast(n_in_use);
        n_in_use += 1;
    };
    const alpha = n_in_use + 2;
    // MTF + RLE2
    var mtfv = u.Vec(u16).init(u.alloc);
    var yy: [256]u8 = undefined;
    for (0..n_in_use) |i| yy[i] = @intCast(i);
    var freq = [_]u32{0} ** 258;
    var zpend: u32 = 0;
    const flushRun = struct {
        fn f(z: *u32, v: *u.Vec(u16), fr: *[258]u32) void {
            if (z.* == 0) return;
            z.* -= 1;
            while (true) {
                if (z.* & 1 != 0) {
                    v.push(1);
                    fr[1] += 1;
                } else {
                    v.push(0);
                    fr[0] += 1;
                }
                if (z.* < 2) break;
                z.* = (z.* - 2) / 2;
            }
            z.* = 0;
        }
    }.f;
    for (last_col) |b| {
        const sq = unseq_to_seq[b];
        var j: usize = 0;
        while (yy[j] != sq) j += 1;
        if (j == 0) {
            zpend += 1;
        } else {
            flushRun(&zpend, &mtfv, &freq);
            var k = j;
            while (k > 0) : (k -= 1) yy[k] = yy[k - 1];
            yy[0] = sq;
            mtfv.push(@intCast(j + 1));
            freq[j + 1] += 1;
        }
    }
    flushRun(&zpend, &mtfv, &freq);
    const eob: u16 = @intCast(n_in_use + 1);
    mtfv.push(eob);
    freq[eob] += 1;
    const nmtf = mtfv.items.len;
    // Huffman table selection
    const n_groups: usize = if (nmtf < 200) 2 else if (nmtf < 600) 3 else if (nmtf < 1200) 4 else if (nmtf < 2400) 5 else 6;
    var lens: [6][258]u8 = undefined;
    // initial split by cumulative frequency
    {
        var n_part = n_groups;
        var rem_f: u64 = nmtf;
        var gs: usize = 0;
        while (n_part > 0) : (n_part -= 1) {
            const t_freq: u64 = rem_f / n_part;
            var ge: usize = gs;
            var a_freq: u64 = 0;
            while (a_freq < t_freq and ge < alpha) {
                a_freq += freq[ge];
                ge += 1;
            }
            if (ge > gs and n_part != n_groups and n_part != 1 and ((n_groups - n_part) % 2 == 1)) {
                a_freq -= freq[ge - 1];
                ge -= 1;
            }
            for (0..alpha) |v| lens[n_part - 1][v] = if (v >= gs and v < ge) 0 else 15;
            rem_f -= a_freq;
            gs = ge;
        }
    }
    const n_sel = (nmtf + 49) / 50;
    const selectors = u.alloc.alloc(u8, n_sel) catch return error.NoMem;
    defer u.alloc.free(selectors);
    var iter: usize = 0;
    while (iter < 4) : (iter += 1) {
        var rfreq: [6][258]u32 = undefined;
        for (0..n_groups) |t| @memset(rfreq[t][0..alpha], 0);
        var gi: usize = 0;
        var sel_i: usize = 0;
        while (gi < nmtf) : (sel_i += 1) {
            const ge = @min(gi + 50, nmtf);
            var best: usize = 0;
            var best_cost: u32 = std.math.maxInt(u32);
            for (0..n_groups) |t| {
                var cost: u32 = 0;
                for (mtfv.items[gi..ge]) |sym| cost += lens[t][sym];
                if (cost < best_cost) {
                    best_cost = cost;
                    best = t;
                }
            }
            selectors[sel_i] = @intCast(best);
            for (mtfv.items[gi..ge]) |sym| rfreq[best][sym] += 1;
            gi = ge;
        }
        for (0..n_groups) |t| makeCodeLengths(lens[t][0..alpha], rfreq[t][0..alpha], 17);
    }
    // assign codes
    var codes: [6][258]u32 = undefined;
    for (0..n_groups) |t| {
        var mn: u8 = 32;
        var mx: u8 = 0;
        for (lens[t][0..alpha]) |l| {
            mn = @min(mn, l);
            mx = @max(mx, l);
        }
        var vec: u32 = 0;
        var l = mn;
        while (l <= mx) : (l += 1) {
            for (0..alpha) |i| if (lens[t][i] == l) {
                codes[t][i] = vec;
                vec += 1;
            };
            vec <<= 1;
        }
    }
    // header
    bw.put(24, 0x314159);
    bw.put(24, 0x265359);
    bw.put(32, crc);
    bw.put(1, 0);
    bw.put(24, orig_ptr);
    var in16: u32 = 0;
    for (0..16) |i| {
        for (0..16) |j| if (in_use[i * 16 + j]) {
            in16 |= @as(u32, 0x8000) >> @intCast(i);
        };
    }
    bw.put(16, in16);
    for (0..16) |i| {
        if (in16 & (@as(u32, 0x8000) >> @intCast(i)) != 0) {
            var b16: u32 = 0;
            for (0..16) |j| if (in_use[i * 16 + j]) {
                b16 |= @as(u32, 0x8000) >> @intCast(j);
            };
            bw.put(16, b16);
        }
    }
    bw.put(3, @intCast(n_groups));
    bw.put(15, @intCast(n_sel));
    var pos = [_]u8{ 0, 1, 2, 3, 4, 5 };
    for (selectors[0..n_sel]) |s| {
        var j: usize = 0;
        while (pos[j] != s) j += 1;
        var k = j;
        while (k > 0) : (k -= 1) pos[k] = pos[k - 1];
        pos[0] = s;
        for (0..j) |_| bw.put(1, 1);
        bw.put(1, 0);
    }
    for (0..n_groups) |t| {
        var curr: i32 = lens[t][0];
        bw.put(5, @intCast(curr));
        for (0..alpha) |i| {
            while (curr < lens[t][i]) {
                bw.put(2, 2);
                curr += 1;
            }
            while (curr > lens[t][i]) {
                bw.put(2, 3);
                curr -= 1;
            }
            bw.put(1, 0);
        }
    }
    var gi: usize = 0;
    var si: usize = 0;
    while (gi < nmtf) : (si += 1) {
        const ge = @min(gi + 50, nmtf);
        const t = selectors[si];
        for (mtfv.items[gi..ge]) |sym| bw.put(@intCast(lens[t][sym]), codes[t][sym]);
        gi = ge;
    }
}

fn compressStream(in_fd: i32, out: *u.Vec(u8), level: u32, in_total: *u64) Error!void {
    const block_max: usize = 100000 * level - 19;
    var bw = BitWriter{ .out = out };
    bw.put(8, 'B');
    bw.put(8, 'Z');
    bw.put(8, 'h');
    bw.put(8, '0' + level);
    const blk = u.alloc.alloc(u8, block_max + 16) catch return error.NoMem;
    defer u.alloc.free(blk);
    var n: usize = 0;
    var crc: u32 = 0xFFFFFFFF;
    var combined: u32 = 0;
    var run_byte: i32 = -1;
    var run_len: u32 = 0;
    var input: [65536]u8 = undefined;
    const Ctx = struct {
        blk: []u8,
        n: *usize,
        crc: *u32,
        fn flushRun(self: @This(), rb: i32, rl: u32) void {
            if (rl == 0) return;
            const c: u8 = @intCast(rb);
            var i: u32 = 0;
            while (i < rl) : (i += 1) self.crc.* = (self.crc.* << 8) ^ crc_table[(self.crc.* >> 24) ^ c];
            const reps: u32 = if (rl < 4) rl else 4;
            i = 0;
            while (i < reps) : (i += 1) {
                self.blk[self.n.*] = c;
                self.n.* += 1;
            }
            if (rl >= 4) {
                self.blk[self.n.*] = @intCast(rl - 4);
                self.n.* += 1;
            }
        }
    };
    const cx = Ctx{ .blk = blk, .n = &n, .crc = &crc };
    while (true) {
        const r = linux.read(in_fd, &input, input.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r)) return error.Io;
        if (r == 0) break;
        in_total.* += r;
        for (input[0..r]) |b| {
            if (@as(i32, b) == run_byte and run_len < 255) {
                run_len += 1;
                continue;
            }
            cx.flushRun(run_byte, run_len);
            run_byte = b;
            run_len = 1;
            if (n >= block_max) {
                const bc = ~crc;
                try encodeBlock(&bw, blk[0..n], bc);
                combined = ((combined << 1) | (combined >> 31)) ^ bc;
                n = 0;
                crc = 0xFFFFFFFF;
            }
        }
    }
    cx.flushRun(run_byte, run_len);
    if (n > 0) {
        const bc = ~crc;
        try encodeBlock(&bw, blk[0..n], bc);
        combined = ((combined << 1) | (combined >> 31)) ^ bc;
    }
    bw.put(24, 0x177245);
    bw.put(24, 0x385090);
    bw.put(32, combined);
    bw.flush();
}

const usage_text =
    "bzip2, a block-sorting file compressor.  Version 1.0.8, 13-Jul-2019.\n" ++
    "\n" ++
    "   usage: bzip2 [flags and input files in any order]\n" ++
    "\n" ++
    "   -h --help           print this message\n" ++
    "   -d --decompress     force decompression\n" ++
    "   -z --compress       force compression\n" ++
    "   -k --keep           keep (don't delete) input files\n" ++
    "   -f --force          overwrite existing output files\n" ++
    "   -t --test           test compressed file integrity\n" ++
    "   -c --stdout         output to standard out\n" ++
    "   -q --quiet          suppress noncritical error messages\n" ++
    "   -v --verbose        be verbose (a 2nd -v gives more)\n" ++
    "   -L --license        display software version & license\n" ++
    "   -V --version        display software version & license\n" ++
    "   -s --small          use less memory (at most 2500k)\n" ++
    "   -1 .. -9            set block size to 100k .. 900k\n" ++
    "   --fast              alias for -1\n" ++
    "   --best              alias for -9\n" ++
    "\n" ++
    "   If invoked as `bzip2', default action is to compress.\n" ++
    "              as `bunzip2',  default action is to decompress.\n" ++
    "              as `bzcat', default action is to decompress to stdout.\n" ++
    "\n" ++
    "   If no file names are given, bzip2 compresses or decompresses\n" ++
    "   from standard input to standard output.  You can combine\n" ++
    "   short flags, so `-v -4' means the same as -v4 or -4v, &c.\n" ++
    "\n";

const recover_text = "\nYou can use the `bzip2recover' program to attempt to recover\ndata from undamaged sections of corrupted files.\n\n";

const Cfg = struct {
    decomp: bool = false,
    test_: bool = false,
    stdout: bool = false,
    keep: bool = false,
    force: bool = false,
    quiet: bool = false,
    verbose: u32 = 0,
    level: u32 = 9,
    prog: []const u8 = "bzip2",
};

var worst: u8 = 0;

fn fail(code: u8) void {
    if (code > worst) worst = code;
}

fn isTty(fd: i32) bool {
    var t: linux.termios = undefined;
    return u.ok(linux.ioctl(fd, 0x5401, @intFromPtr(&t)));
}

fn padName(name: []const u8) []const u8 {
    const s = std.fmt.allocPrint(u.alloc, "{s}:", .{name}) catch return name;
    if (s.len >= 8) return s;
    const o = u.alloc.alloc(u8, 8) catch return s;
    @memcpy(o[0..s.len], s);
    @memset(o[s.len..], ' ');
    return o;
}

fn copyMeta(st: u.Stat, fd: i32, path: []const u8) void {
    _ = linux.fchown(fd, st.uid, st.gid);
    _ = linux.fchmod(fd, @intCast(st.mode & 0o7777));
    var times = [2]linux.timespec{ .{ .sec = @intCast(st.atime), .nsec = @intCast(st.atime_nsec) }, .{ .sec = @intCast(st.mtime), .nsec = @intCast(st.mtime_nsec) } };
    _ = linux.utimensat(linux.AT.FDCWD, u.zstr(path), &times, 0);
}

fn decodeAll(in_fd: i32, out: *Out, trailing: *bool) Error!void {
    const br = u.alloc.create(BitReader) catch return error.NoMem;
    defer u.alloc.destroy(br);
    br.* = .{ .fd = in_fd };
    var first = true;
    while (true) {
        const more = decodeStream(br, out, first) catch |e| {
            if (!first and e == error.NotBz) {
                trailing.* = true;
                break;
            }
            if (!first and e == error.Truncated) {
                trailing.* = true;
                break;
            }
            return e;
        };
        first = false;
        if (!more) break;
    }
    try out.flush();
}

const integrity_text = "\nIt is possible that the compressed file(s) have become corrupted.\nYou can use the -tvv option to test integrity of such files.\n";

fn report(cfg: *const Cfg, disp: []const u8, out_name: []const u8, e: Error, is_stdin: bool) void {
    switch (e) {
        error.NotBz => {
            if (cfg.test_) u.errf("{s}: {s}: bad magic number (file not created by bzip2)\n{s}", .{ cfg.prog, disp, recover_text }) else u.errf("{s}: {s} is not a bzip2 file.\n", .{ cfg.prog, disp });
        },
        error.Truncated => {
            if (cfg.test_) {
                u.errf("{s}: {s}: file ends unexpectedly\n{s}", .{ cfg.prog, disp, recover_text });
            } else u.errf("\n{s}: Compressed file ends unexpectedly;\n\tperhaps it is corrupted?  *Possible* reason follows.\n{s}: {s}\n\tInput file = {s}, output file = {s}\n{s}{s}", .{ cfg.prog, cfg.prog, if (is_stdin) "Inappropriate ioctl for device" else "No such file or directory", disp, out_name, integrity_text, recover_text });
        },
        error.Crc, error.Corrupt => {
            if (cfg.test_) u.errf("{s}: {s}: data integrity (CRC) error in data\n{s}", .{ cfg.prog, disp, recover_text }) else u.errf("\n{s}: Data integrity error when decompressing.\n\tInput file = {s}, output file = {s}\n{s}{s}", .{ cfg.prog, disp, out_name, integrity_text, recover_text });
        },
        error.Unsupported => u.errf("{s}: {s}: this stream uses randomised blocks, which are not supported\n", .{ cfg.prog, disp }),
        error.NoMem => u.errf("{s}: Can't allocate enough memory\n", .{cfg.prog}),
        error.Io => u.errf("{s}: I/O or other error, bailing out.  Possible reason follows.\n", .{cfg.prog}),
    }
}

fn processOne(cfg: *const Cfg, name: []const u8) void {
    const is_stdin = std.mem.eql(u8, name, "-");
    const disp: []const u8 = if (is_stdin) "(stdin)" else name;
    var st: ?u.Stat = null;
    var in_fd: i32 = 0;
    if (!is_stdin) {
        st = u.stat(name, false);
        if (st == null) {
            u.errf("{s}: Can't open input file {s}: No such file or directory.\n", .{ cfg.prog, name });
            fail(1);
            return;
        }
        const t = st.?.mode & linux.S.IFMT;
        if (t == linux.S.IFDIR) {
            u.errf("{s}: Input file {s} is a directory.\n", .{ cfg.prog, name });
            fail(1);
            return;
        }
        if (t != linux.S.IFREG and !cfg.stdout) {
            u.errf("{s}: Input file {s} is not a normal file.\n", .{ cfg.prog, name });
            fail(1);
            return;
        }
        const rc = linux.open(u.zstr(name), .{ .ACCMODE = .RDONLY }, 0);
        if (!u.ok(rc)) {
            u.errf("{s}: Can't open input file {s}: {s}.\n", .{ cfg.prog, name, u.strerr(u.errno(rc)) });
            fail(1);
            return;
        }
        in_fd = @intCast(rc);
    }
    defer if (!is_stdin) {
        _ = linux.close(in_fd);
    };
    const to_stdout = cfg.stdout or is_stdin;
    if (!cfg.decomp and !cfg.test_) {
        // ----- compress
        if (!is_stdin and !cfg.stdout) {
            const sufs = [_][]const u8{ ".bz2", ".bz", ".tbz2", ".tbz" };
            for (sufs) |sf| if (std.mem.endsWith(u8, name, sf)) {
                u.errf("{s}: Input file {s} already has {s} suffix.\n", .{ cfg.prog, name, sf });
                fail(1);
                return;
            };
        }
        if (st) |s0| if (!cfg.stdout and !cfg.force and !cfg.test_ and s0.nlink > 1) {
            u.errf("{s}: Input file {s} has {d} other link{s}.\n", .{ cfg.prog, name, s0.nlink - 1, if (s0.nlink > 2) "s" else "" });
            fail(1);
            return;
        };
        if (to_stdout and isTty(1)) {
            u.errf("{s}: I won't write compressed data to a terminal.\n{s}: For help, type: `{s} --help'.\n", .{ cfg.prog, cfg.prog, cfg.prog });
            fail(1);
            return;
        }
        var out = u.Vec(u8).init(u.alloc);
        var in_total: u64 = 0;
        compressStream(in_fd, &out, cfg.level, &in_total) catch |e| {
            report(cfg, disp, "", e, is_stdin);
            fail(2);
            return;
        };
        if (to_stdout) {
            writeAll(1, out.items) catch {
                fail(1);
                return;
            };
        } else {
            const dest = std.fmt.allocPrint(u.alloc, "{s}.bz2", .{name}) catch return;
            if (u.stat(dest, false) != null) {
                if (!cfg.force) {
                    u.errf("{s}: Output file {s} already exists.\n", .{ cfg.prog, dest });
                    fail(1);
                    return;
                }
                _ = linux.unlink(u.zstr(dest));
            }
            const rc = linux.open(u.zstr(dest), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
            if (!u.ok(rc)) {
                u.errf("{s}: Can't create output file {s}: {s}.\n", .{ cfg.prog, dest, u.strerr(u.errno(rc)) });
                fail(1);
                return;
            }
            const ofd: i32 = @intCast(rc);
            writeAll(ofd, out.items) catch {
                _ = linux.close(ofd);
                _ = linux.unlink(u.zstr(dest));
                fail(1);
                return;
            };
            if (st) |s| copyMeta(s, ofd, dest);
            _ = linux.close(ofd);
            if (!cfg.keep) _ = linux.unlink(u.zstr(name));
        }
        if (cfg.verbose >= 1) {
            if (in_total == 0) {
                u.errf("  {s}  no data compressed.\n", .{padName(disp)});
            } else {
                const fi: f64 = @floatFromInt(in_total);
                const fo: f64 = @floatFromInt(out.items.len);
                u.errf("  {s} {d: >6.3}:1, {d: >6.3} bits/byte, {d: >5.2}% saved, {d} in, {d} out.\n", .{ padName(disp), fi / fo, 8.0 * fo / fi, 100.0 * (1.0 - fo / fi), in_total, out.items.len });
            }
        }
        return;
    }
    // ----- decompress / test
    if (is_stdin and isTty(0)) {
        u.errf("{s}: I won't read compressed data from a terminal.\n{s}: For help, type: `{s} --help'.\n", .{ cfg.prog, cfg.prog, cfg.prog });
        fail(1);
        return;
    }
    var dest: ?[]const u8 = null;
    if (!to_stdout and !cfg.test_) {
        const maps = [_][2][]const u8{ .{ ".bz2", "" }, .{ ".bz", "" }, .{ ".tbz2", ".tar" }, .{ ".tbz", ".tar" } };
        var found = false;
        for (maps) |m| if (std.mem.endsWith(u8, name, m[0]) and name.len > m[0].len) {
            dest = std.fmt.allocPrint(u.alloc, "{s}{s}", .{ name[0 .. name.len - m[0].len], m[1] }) catch return;
            found = true;
            break;
        };
        if (!found) {
            if (!cfg.quiet) u.errf("{s}: Can't guess original name for {s} -- using {s}.out\n", .{ cfg.prog, name, name });
            dest = std.fmt.allocPrint(u.alloc, "{s}.out", .{name}) catch return;
        }
    }
    if (st) |s0| if (!cfg.stdout and !cfg.force and !cfg.test_ and s0.nlink > 1) {
        u.errf("{s}: Input file {s} has {d} other link{s}.\n", .{ cfg.prog, name, s0.nlink - 1, if (s0.nlink > 2) "s" else "" });
        fail(1);
        return;
    };
    var out_fd: i32 = 1;
    var created = false;
    if (dest) |d| {
        if (u.stat(d, false) != null) {
            if (!cfg.force) {
                u.errf("{s}: Output file {s} already exists.\n", .{ cfg.prog, d });
                fail(1);
                return;
            }
            _ = linux.unlink(u.zstr(d));
        }
        const rc = linux.open(u.zstr(d), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
        if (!u.ok(rc)) {
            u.errf("{s}: Can't create output file {s}: {s}.\n", .{ cfg.prog, d, u.strerr(u.errno(rc)) });
            fail(1);
            return;
        }
        out_fd = @intCast(rc);
        created = true;
    }
    var out = Out{ .fd = out_fd, .discard = cfg.test_, .buf = u.Vec(u8).init(u.alloc) };
    var trailing = false;
    decodeAll(in_fd, &out, &trailing) catch |e| {
        report(cfg, disp, if (dest) |d| d else "(stdout)", e, is_stdin);
        if (created and e != error.NotBz) u.errf("{s}: Deleting output file {s}, if it exists.\n", .{ cfg.prog, dest.? });
        if (created) {
            _ = linux.close(out_fd);
            _ = linux.unlink(u.zstr(dest.?));
        }
        fail(2);
        return;
    };
    if (trailing and !cfg.quiet) u.errf("{s}: {s}: trailing garbage after EOF ignored\n", .{ cfg.prog, disp });
    if (created) {
        if (st) |s| copyMeta(s, out_fd, dest.?);
        _ = linux.close(out_fd);
        if (!cfg.keep) _ = linux.unlink(u.zstr(name));
    }
    if (cfg.verbose >= 1) {
        if (cfg.verbose >= 2 and cfg.test_) {
            u.errf("  {s} \n    [1: huff+mtf rt+rld]\n    ok\n", .{padName(disp)});
        } else u.errf("  {s} {s}\n", .{ padName(disp), if (cfg.test_) "ok" else "done" });
    }
}

fn runAs(args: []const []const u8, prog_name: []const u8) u8 {
    const name = u.basename(prog_name);
    var cfg = Cfg{};
    cfg.prog = name;
    if (std.mem.eql(u8, name, "bunzip2")) cfg.decomp = true;
    if (std.mem.eql(u8, name, "bzcat")) {
        cfg.decomp = true;
        cfg.stdout = true;
    }
    var files = u.Vec([]const u8).init(u.alloc);
    var done = false;
    for (args) |a| {
        if (done or a.len < 2 or a[0] != '-') {
            files.push(a);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            done = true;
            continue;
        }
        if (a[1] == '-') {
            const n = a[2..];
            if (std.mem.eql(u8, n, "decompress")) cfg.decomp = true else if (std.mem.eql(u8, n, "compress")) cfg.decomp = false else if (std.mem.eql(u8, n, "keep")) cfg.keep = true else if (std.mem.eql(u8, n, "force")) cfg.force = true else if (std.mem.eql(u8, n, "test")) {
                cfg.test_ = true;
                cfg.decomp = true;
            } else if (std.mem.eql(u8, n, "stdout")) cfg.stdout = true else if (std.mem.eql(u8, n, "quiet")) cfg.quiet = true else if (std.mem.eql(u8, n, "verbose")) cfg.verbose += 1 else if (std.mem.eql(u8, n, "small")) {} else if (std.mem.eql(u8, n, "fast")) cfg.level = 1 else if (std.mem.eql(u8, n, "best")) cfg.level = 9 else if (std.mem.eql(u8, n, "help")) {
                u.out(usage_text);
                return 0;
            } else if (std.mem.eql(u8, n, "version") or std.mem.eql(u8, n, "license")) {
                u.err("bzip2, a block-sorting file compressor.  Version 1.0.8 (cmdbox), 13-Jul-2019.\n");
                return 0;
            } else {
                u.errf("{s}: Bad flag `{s}'\n", .{ name, a });
                u.err(usage_text);
                return 1;
            }
            continue;
        }
        for (a[1..]) |ch| switch (ch) {
            'd' => cfg.decomp = true,
            'z' => cfg.decomp = false,
            'k' => cfg.keep = true,
            'f' => cfg.force = true,
            't' => {
                cfg.test_ = true;
                cfg.decomp = true;
            },
            'c' => cfg.stdout = true,
            'q' => cfg.quiet = true,
            'v' => cfg.verbose += 1,
            's' => {},
            'h' => {
                u.out(usage_text);
                return 0;
            },
            'L', 'V' => {
                u.err("bzip2, a block-sorting file compressor.  Version 1.0.8 (cmdbox), 13-Jul-2019.\n");
                return 0;
            },
            '1'...'9' => cfg.level = ch - '0',
            else => {
                u.errf("{s}: Bad flag `{s}'\n", .{ name, a });
                u.err(usage_text);
                return 1;
            },
        };
    }
    if (files.items.len == 0) {
        processOne(&cfg, "-");
    } else for (files.items) |f| processOne(&cfg, f);
    return worst;
}

pub fn bzip2(args: []const []const u8) u8 {
    return runAs(args, "bzip2");
}
pub fn bunzip2(args: []const []const u8) u8 {
    return runAs(args, "bunzip2");
}
pub fn bzcat(args: []const []const u8) u8 {
    return runAs(args, "bzcat");
}
