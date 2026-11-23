// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// diff - GNU diffutils 3.12 compatible: normal / context / unified / ed / rcs / side-by-side output,
// directory comparison (-r -N -x -X -S), ignore options (-i -b -w -Z -E -B -I --strip-trailing-cr),
// -p/-F function headers, --color. The core is the same algorithm as GNU diff: line equivalence
// classes, discarding of unmatched lines, Myers' linear-space compareseq and shift_boundaries().

const std = @import("std");
const u = @import("util.zig");
const g = @import("getopt.zig");
const color = @import("color.zig");
const regex = @import("regex.zig");
const c = @cImport({
    @cInclude("time.h");
});

const help_text = @embedFile("diff_help.txt");
const version_text = @embedFile("diff_version.txt");

const Style = enum { normal, context, unified, ed, rcs, sdiff };

const Opts = struct {
    style: Style = .normal,
    context: usize = 3,
    text: bool = false,
    brief: bool = false,
    report_same: bool = false,
    icase: bool = false,
    ignore_all_space: bool = false,
    ignore_space_change: bool = false,
    ignore_trailing_space: bool = false,
    ignore_blank_lines: bool = false,
    ignore_tab_expansion: bool = false,
    strip_cr: bool = false,
    minimal: bool = false,
    recursive: bool = false,
    new_file: bool = false,
    unidir: bool = false,
    show_c_function: bool = false,
    expand_tabs: bool = false,
    initial_tab: bool = false,
    tabsize: usize = 8,
    width: usize = 130,
    left_column: bool = false,
    suppress_common: bool = false,
    starting_file: ?[]const u8 = null,
};
var o = Opts{};
var colored = false;
var palette: []const u8 = "";
var ignore_res: u.Vec(regex.Regex) = undefined;
var func_re: ?regex.Regex = null;
var excludes: u.Vec([]const u8) = undefined;
var labels: [2]?[]const u8 = .{ null, null };
var switches: []const u8 = "";
var style_set = false;
var style_conflict = false;
fn setStyle(st: Style) void {
    if (style_set and o.style != st) style_conflict = true;
    style_set = true;
    o.style = st;
}

// ---------------------------------------------------------------- colour
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn colorCode(key: []const u8, default_code: []const u8) []const u8 {
    var code = default_code;
    var entries = std.mem.splitScalar(u8, palette, ':');
    while (entries.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (same(entry[0..eq], key)) code = entry[eq + 1 ..];
    }
    return code;
}
fn begin(key: []const u8, default_code: []const u8) bool {
    if (!colored) return false;
    const code = colorCode(key, default_code);
    if (code.len == 0) return false;
    u.outf("\x1b[{s}m", .{code});
    return true;
}
fn endColor(active: bool) void {
    if (active) u.out("\x1b[0m");
}
fn beginBuf(buf: *u.Vec(u8), key: []const u8, default_code: []const u8) bool {
    if (!colored) return false;
    const code = colorCode(key, default_code);
    if (code.len == 0) return false;
    buf.pushSlice("\x1b[");
    buf.pushSlice(code);
    buf.push('m');
    return true;
}

// ---------------------------------------------------------------- line model
const Hunk = struct { l0: usize, d: usize, l1: usize, n: usize };

const File = struct {
    epoch: bool = false,
    name: []const u8,
    data: []const u8,
    lines: []const []const u8 = &.{},
    cls: []u32 = &.{},
    missing: bool = false,
    st: ?u.Stat = null,
};

fn splitLines(data: []const u8) []const []const u8 {
    var result = u.Vec([]const u8).init(u.alloc);
    var start: usize = 0;
    while (start < data.len) {
        const end = if (std.mem.indexOfScalarPos(u8, data, start, '\n')) |p| p + 1 else data.len;
        result.push(data[start..end]);
        start = end;
    }
    return result.items;
}

fn isSpaceByte(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r' or b == 0x0b or b == 0x0c or b == '\n';
}

fn normKey(raw: []const u8, out: *u.Vec(u8)) []const u8 {
    var text = raw;
    const nl = text.len > 0 and text[text.len - 1] == '\n';
    if (nl) text = text[0 .. text.len - 1];
    if (o.strip_cr and text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];
    if (o.ignore_trailing_space or o.ignore_space_change or o.ignore_all_space) {
        while (text.len > 0 and isSpaceByte(text[text.len - 1])) text = text[0 .. text.len - 1];
    }
    out.items.len = 0;
    var col: usize = 0;
    var prev_space = false;
    for (text) |b| {
        if (b == '\t' and o.ignore_tab_expansion) {
            const n = o.tabsize - col % o.tabsize;
            var k: usize = 0;
            while (k < n) : (k += 1) pushNorm(out, ' ', &prev_space);
            col += n;
            continue;
        }
        col += 1;
        pushNorm(out, b, &prev_space);
    }
    // white-space ignoring options treat the final newline as white space too
    if (nl and !(o.ignore_trailing_space or o.ignore_space_change or o.ignore_all_space or o.style == .ed)) out.push('\n');
    return out.items;
}
fn pushNorm(out: *u.Vec(u8), b: u8, prev_space: *bool) void {
    const sp = b == ' ' or b == '\t' or b == '\r' or b == 0x0b or b == 0x0c;
    if (sp and o.ignore_all_space) return;
    if (sp and o.ignore_space_change) {
        if (!prev_space.*) out.push(' ');
        prev_space.* = true;
        return;
    }
    prev_space.* = false;
    out.push(if (o.icase) std.ascii.toLower(b) else b);
}

fn anyNorm() bool {
    return o.icase or o.ignore_all_space or o.ignore_space_change or o.ignore_trailing_space or o.ignore_tab_expansion or o.strip_cr or o.style == .ed;
}

fn classify(f0: *File, f1: *File) void {
    var map = std.StringHashMapUnmanaged(u32){};
    var next: u32 = 0;
    var tmp = u.Vec(u8).init(u.alloc);
    const files = [2]*File{ f0, f1 };
    for (files) |f| {
        f.cls = u.alloc.alloc(u32, f.lines.len) catch @panic("oom");
        for (f.lines, 0..) |line, i| {
            const key: []const u8 = if (anyNorm()) u.alloc.dupe(u8, normKey(line, &tmp)) catch @panic("oom") else line;
            const gop = map.getOrPut(u.alloc, key) catch @panic("oom");
            if (!gop.found_existing) {
                gop.value_ptr.* = next;
                next += 1;
            }
            f.cls[i] = gop.value_ptr.*;
        }
    }
}

// ---------------------------------------------------------------- compareseq (Myers, linear space)
const Seq = struct {
    xs: []const u32,
    ys: []const u32,
    fd: []isize,
    bd: []isize,
    off: isize,
    chx: []bool,
    chy: []bool,
    too_expensive: isize = 4096,
};
const Part = struct { xmid: isize, ymid: isize, lo_min: bool = true, hi_min: bool = true };
const SNAKE_LIMIT: isize = 20;

inline fn eqAt(s: *const Seq, x: isize, y: isize) bool {
    return s.xs[@intCast(x)] == s.ys[@intCast(y)];
}
inline fn fdAt(s: *Seq, d: isize) *isize {
    return &s.fd[@intCast(d + s.off)];
}
inline fn bdAt(s: *Seq, d: isize) *isize {
    return &s.bd[@intCast(d + s.off)];
}

fn diag(s: *Seq, xoff: isize, xlim: isize, yoff: isize, ylim: isize, find_minimal: bool) Part {
    const dmin = xoff - ylim;
    const dmax = xlim - yoff;
    const fmid = xoff - yoff;
    const bmid = xlim - ylim;
    var fmin = fmid;
    var fmax = fmid;
    var bmin = bmid;
    var bmax = bmid;
    const odd = @mod(fmid - bmid, 2) != 0;
    fdAt(s, fmid).* = xoff;
    bdAt(s, bmid).* = xlim;
    var cost: isize = 1;
    while (true) : (cost += 1) {
        var big_snake = false;
        if (fmin > dmin) {
            fmin -= 1;
            fdAt(s, fmin - 1).* = -1;
        } else fmin += 1;
        if (fmax < dmax) {
            fmax += 1;
            fdAt(s, fmax + 1).* = -1;
        } else fmax -= 1;
        var d = fmax;
        while (d >= fmin) : (d -= 2) {
            const tlo = fdAt(s, d - 1).*;
            const thi = fdAt(s, d + 1).*;
            const x0 = if (tlo < thi) thi else tlo + 1;
            var x = x0;
            var y = x0 - d;
            while (x < xlim and y < ylim and eqAt(s, x, y)) {
                x += 1;
                y += 1;
            }
            if (x - x0 > SNAKE_LIMIT) big_snake = true;
            fdAt(s, d).* = x;
            if (odd and bmin <= d and d <= bmax and bdAt(s, d).* <= x) return .{ .xmid = x, .ymid = y };
        }
        if (bmin > dmin) {
            bmin -= 1;
            bdAt(s, bmin - 1).* = std.math.maxInt(isize);
        } else bmin += 1;
        if (bmax < dmax) {
            bmax += 1;
            bdAt(s, bmax + 1).* = std.math.maxInt(isize);
        } else bmax -= 1;
        d = bmax;
        while (d >= bmin) : (d -= 2) {
            const tlo = bdAt(s, d - 1).*;
            const thi = bdAt(s, d + 1).*;
            const x0 = if (tlo < thi) tlo else thi - 1;
            var x = x0;
            var y = x0 - d;
            while (xoff < x and yoff < y and eqAt(s, x - 1, y - 1)) {
                x -= 1;
                y -= 1;
            }
            if (x0 - x > SNAKE_LIMIT) big_snake = true;
            bdAt(s, d).* = x;
            if (!odd and fmin <= d and d <= fmax and x <= fdAt(s, d).*) return .{ .xmid = x, .ymid = y };
        }
        if (find_minimal) continue;

        // Heuristic: a diagonal that made lots of progress compared with the edit distance
        if (cost > 200 and big_snake) {
            var best: isize = 0;
            var res = Part{ .xmid = 0, .ymid = 0 };
            d = fmax;
            while (d >= fmin) : (d -= 2) {
                const dd = d - fmid;
                const x = fdAt(s, d).*;
                const y = x - d;
                const v = (x - xoff) * 2 - dd;
                if (v > 12 * (cost + (if (dd < 0) -dd else dd))) {
                    if (v > best and xoff + SNAKE_LIMIT <= x and x < xlim and yoff + SNAKE_LIMIT <= y and y < ylim) {
                        var k: isize = 1;
                        while (eqAt(s, x - k, y - k)) : (k += 1) {
                            if (k == SNAKE_LIMIT) {
                                best = v;
                                res.xmid = x;
                                res.ymid = y;
                                break;
                            }
                        }
                    }
                }
            }
            if (best > 0) {
                res.lo_min = true;
                res.hi_min = false;
                return res;
            }
            best = 0;
            d = bmax;
            while (d >= bmin) : (d -= 2) {
                const dd = d - bmid;
                const x = bdAt(s, d).*;
                const y = x - d;
                const v = (xlim - x) * 2 + dd;
                if (v > 12 * (cost + (if (dd < 0) -dd else dd))) {
                    if (v > best and xoff < x and x <= xlim - SNAKE_LIMIT and yoff < y and y <= ylim - SNAKE_LIMIT) {
                        var k: isize = 0;
                        while (eqAt(s, x + k, y + k)) : (k += 1) {
                            if (k == SNAKE_LIMIT - 1) {
                                best = v;
                                res.xmid = x;
                                res.ymid = y;
                                break;
                            }
                        }
                    }
                }
            }
            if (best > 0) {
                res.lo_min = false;
                res.hi_min = true;
                return res;
            }
        }

        // Heuristic: gone well beyond the call of duty - report halfway between the best results so far
        if (cost >= s.too_expensive) {
            var fxybest: isize = -1;
            var fxbest: isize = 0;
            d = fmax;
            while (d >= fmin) : (d -= 2) {
                var x = @min(fdAt(s, d).*, xlim);
                var y = x - d;
                if (ylim < y) {
                    x = ylim + d;
                    y = ylim;
                }
                if (fxybest < x + y) {
                    fxybest = x + y;
                    fxbest = x;
                }
            }
            var bxybest: isize = std.math.maxInt(isize);
            var bxbest: isize = 0;
            d = bmax;
            while (d >= bmin) : (d -= 2) {
                var x = @max(xoff, bdAt(s, d).*);
                var y = x - d;
                if (y < yoff) {
                    x = yoff + d;
                    y = yoff;
                }
                if (x + y < bxybest) {
                    bxybest = x + y;
                    bxbest = x;
                }
            }
            if ((xlim + ylim) - bxybest < fxybest - (xoff + yoff)) {
                return .{ .xmid = fxbest, .ymid = fxybest - fxbest, .lo_min = true, .hi_min = false };
            }
            return .{ .xmid = bxbest, .ymid = bxybest - bxbest, .lo_min = false, .hi_min = true };
        }
    }
}

fn compareseq(s: *Seq, xoff_in: isize, xlim_in: isize, yoff_in: isize, ylim_in: isize, find_minimal: bool) void {
    var xoff = xoff_in;
    var xlim = xlim_in;
    var yoff = yoff_in;
    var ylim = ylim_in;
    while (xoff < xlim and yoff < ylim and eqAt(s, xoff, yoff)) {
        xoff += 1;
        yoff += 1;
    }
    while (xoff < xlim and yoff < ylim and eqAt(s, xlim - 1, ylim - 1)) {
        xlim -= 1;
        ylim -= 1;
    }
    if (xoff == xlim) {
        while (yoff < ylim) : (yoff += 1) s.chy[@intCast(yoff)] = true;
    } else if (yoff == ylim) {
        while (xoff < xlim) : (xoff += 1) s.chx[@intCast(xoff)] = true;
    } else {
        const part = diag(s, xoff, xlim, yoff, ylim, find_minimal);
        compareseq(s, xoff, part.xmid, yoff, part.ymid, part.lo_min);
        compareseq(s, part.xmid, xlim, part.ymid, ylim, part.hi_min);
    }
}

/// changed flags are stored with one sentinel slot in front and behind (index i lives at [i + 1])
fn chAt(arr: []bool, i: isize) *bool {
    return &arr[@intCast(i + 1)];
}

fn shiftBoundaries(cls: []const u32, changed: []bool, other: []bool) void {
    const i_end: isize = @intCast(cls.len);
    var i: isize = 0;
    var j: isize = 0;
    while (true) {
        while (i < i_end and !chAt(changed, i).*) {
            while (chAt(other, j).*) j += 1;
            j += 1;
            i += 1;
        }
        if (i == i_end) break;
        var start = i;
        i += 1;
        while (chAt(changed, i).*) i += 1;
        while (chAt(other, j).*) j += 1;
        var corresponding: isize = i_end;
        var runlength: isize = 0;
        while (true) {
            runlength = i - start;
            while (start > 0 and cls[@intCast(start - 1)] == cls[@intCast(i - 1)]) {
                start -= 1;
                chAt(changed, start).* = true;
                i -= 1;
                chAt(changed, i).* = false;
                while (chAt(changed, start - 1).*) start -= 1;
                j -= 1;
                while (chAt(other, j).*) j -= 1;
            }
            corresponding = if (chAt(other, j - 1).*) i else i_end;
            while (i != i_end and cls[@intCast(start)] == cls[@intCast(i)]) {
                chAt(changed, start).* = false;
                start += 1;
                chAt(changed, i).* = true;
                i += 1;
                while (chAt(changed, i).*) i += 1;
                j += 1;
                while (chAt(other, j).*) {
                    corresponding = i;
                    j += 1;
                }
            }
            if (runlength == i - start) break;
        }
        while (corresponding < i) {
            start -= 1;
            chAt(changed, start).* = true;
            i -= 1;
            chAt(changed, i).* = false;
            j -= 1;
            while (chAt(other, j).*) j -= 1;
        }
    }
}

/// Port of the per-file part of GNU diff's discard_confusing_lines().
fn discardLines(cls: []const u32, other_counts: []const u32) []u8 {
    const end = cls.len;
    const discards = u.alloc.alloc(u8, end) catch @panic("oom");
    @memset(discards, 0);
    var many: usize = 5;
    var tem: usize = end / 64;
    while (tem > 0) {
        tem >>= 2;
        many <<= 1;
    }
    for (cls, 0..) |k, i| {
        const nmatch = other_counts[k];
        if (nmatch == 0) discards[i] = 1 else if (nmatch > many) discards[i] = 2;
    }
    var i: usize = 0;
    while (i < end) : (i += 1) {
        if (discards[i] == 2) {
            discards[i] = 0;
        } else if (discards[i] != 0) {
            var j: usize = i;
            var provisional: usize = 0;
            while (j < end) : (j += 1) {
                if (discards[j] == 0) break;
                if (discards[j] == 2) provisional += 1;
            }
            while (j > i and discards[j - 1] == 2) {
                j -= 1;
                discards[j] = 0;
                provisional -= 1;
            }
            const length = j - i;
            if (provisional * 4 > length) {
                while (j > i) {
                    j -= 1;
                    if (discards[j] == 2) discards[j] = 0;
                }
            } else {
                var minimum: usize = 1;
                var t2: usize = length >> 2;
                while (true) {
                    t2 >>= 2;
                    if (t2 == 0) break;
                    minimum <<= 1;
                }
                minimum += 1;
                var consec: usize = 0;
                var jj: isize = 0;
                const len_i: isize = @intCast(length);
                while (jj < len_i) : (jj += 1) {
                    const idx: usize = i + @as(usize, @intCast(jj));
                    if (discards[idx] != 2) {
                        consec = 0;
                    } else {
                        consec += 1;
                        if (minimum == consec) {
                            jj -= @intCast(consec);
                        } else if (minimum < consec) discards[idx] = 0;
                    }
                }
                var k2: usize = 0;
                consec = 0;
                while (k2 < length) : (k2 += 1) {
                    if (k2 >= 8 and discards[i + k2] == 1) break;
                    if (discards[i + k2] == 2) {
                        consec = 0;
                        discards[i + k2] = 0;
                    } else if (discards[i + k2] == 0) {
                        consec = 0;
                    } else consec += 1;
                    if (consec == 3) break;
                }
                i += length - 1;
                k2 = 0;
                consec = 0;
                while (k2 < length) : (k2 += 1) {
                    if (k2 >= 8 and discards[i - k2] == 1) break;
                    if (discards[i - k2] == 2) {
                        consec = 0;
                        discards[i - k2] = 0;
                    } else if (discards[i - k2] == 0) {
                        consec = 0;
                    } else consec += 1;
                    if (consec == 3) break;
                }
            }
        }
    }
    return discards;
}

/// Compute the list of change hunks (GNU "script") between two classified files.
/// Like GNU diff, identical leading/trailing lines are stripped first (find_identical_ends) and only
/// the remaining middle part is discarded, compared and shifted.
fn computeHunks(f0: *File, f1: *File) []const Hunk {
    const n0 = f0.lines.len;
    const n1 = f1.lines.len;
    var pre: usize = 0;
    while (pre < n0 and pre < n1 and same(f0.lines[pre], f1.lines[pre])) pre += 1;
    var suf: usize = 0;
    while (suf < n0 - pre and suf < n1 - pre and same(f0.lines[n0 - 1 - suf], f1.lines[n1 - 1 - suf])) suf += 1;
    // context styles keep that many identical lines at both ends in the compared part
    const keep: usize = switch (o.style) {
        .context, .unified => o.context,
        else => 0,
    };
    pre = pre -| keep;
    suf = suf -| keep;
    const m0 = n0 - pre - suf;
    const m1 = n1 - pre - suf;
    const cls0 = f0.cls[pre .. pre + m0];
    const cls1 = f1.cls[pre .. pre + m1];
    const ch0 = u.alloc.alloc(bool, m0 + 2) catch @panic("oom");
    const ch1 = u.alloc.alloc(bool, m1 + 2) catch @panic("oom");
    @memset(ch0, false);
    @memset(ch1, false);
    // GNU discard_confusing_lines: lines without a counterpart (and, inside runs of such lines, very
    // frequent lines) are certainly changed and are left out of the search
    var max_cls: u32 = 0;
    for (cls0) |k| max_cls = @max(max_cls, k);
    for (cls1) |k| max_cls = @max(max_cls, k);
    const cnt0 = u.alloc.alloc(u32, max_cls + 1) catch @panic("oom");
    const cnt1 = u.alloc.alloc(u32, max_cls + 1) catch @panic("oom");
    @memset(cnt0, 0);
    @memset(cnt1, 0);
    for (cls0) |k| cnt0[k] += 1;
    for (cls1) |k| cnt1[k] += 1;
    const disc0 = if (o.minimal) u.alloc.alloc(u8, cls0.len) catch @panic("oom") else discardLines(cls0, cnt1);
    const disc1 = if (o.minimal) u.alloc.alloc(u8, cls1.len) catch @panic("oom") else discardLines(cls1, cnt0);
    if (o.minimal) {
        @memset(disc0, 0);
        @memset(disc1, 0);
    }
    var r0 = u.Vec(usize).init(u.alloc);
    var r1 = u.Vec(usize).init(u.alloc);
    var x0 = u.Vec(u32).init(u.alloc);
    var x1 = u.Vec(u32).init(u.alloc);
    for (cls0, 0..) |k, i| {
        if (disc0[i] != 0) chAt(ch0, @intCast(i)).* = true else {
            r0.push(i);
            x0.push(k);
        }
    }
    for (cls1, 0..) |k, i| {
        if (disc1[i] != 0) chAt(ch1, @intCast(i)).* = true else {
            r1.push(i);
            x1.push(k);
        }
    }
    const rx = x0.items.len;
    const ry = x1.items.len;
    const chx = u.alloc.alloc(bool, rx + 1) catch @panic("oom");
    const chy = u.alloc.alloc(bool, ry + 1) catch @panic("oom");
    @memset(chx, false);
    @memset(chy, false);
    const diag_len = rx + ry + 3;
    var seq = Seq{
        .xs = x0.items,
        .ys = x1.items,
        .fd = u.alloc.alloc(isize, diag_len) catch @panic("oom"),
        .bd = u.alloc.alloc(isize, diag_len) catch @panic("oom"),
        .off = @intCast(ry + 1),
        .chx = chx,
        .chy = chy,
    };
    // approximate square root of the input size, bounded below by 4096
    var te: isize = 1;
    var diags: usize = rx + ry + 3;
    while (diags > 0) : (diags >>= 2) te <<= 1;
    seq.too_expensive = @max(4096, te);
    compareseq(&seq, 0, @intCast(rx), 0, @intCast(ry), o.minimal);
    for (r0.items, 0..) |orig, k| if (chx[k]) {
        chAt(ch0, @intCast(orig)).* = true;
    };
    for (r1.items, 0..) |orig, k| if (chy[k]) {
        chAt(ch1, @intCast(orig)).* = true;
    };
    shiftBoundaries(cls0, ch0, ch1);
    shiftBoundaries(cls1, ch1, ch0);
    var hunks = u.Vec(Hunk).init(u.alloc);
    var ia: usize = 0;
    var ib: usize = 0;
    while (ia < m0 or ib < m1) {
        const c0 = ia < m0 and chAt(ch0, @intCast(ia)).*;
        const c1 = ib < m1 and chAt(ch1, @intCast(ib)).*;
        if (!c0 and !c1) {
            ia += 1;
            ib += 1;
            continue;
        }
        const s0 = ia;
        const s1 = ib;
        while (ia < m0 and chAt(ch0, @intCast(ia)).*) ia += 1;
        while (ib < m1 and chAt(ch1, @intCast(ib)).*) ib += 1;
        hunks.push(.{ .l0 = pre + s0, .d = ia - s0, .l1 = pre + s1, .n = ib - s1 });
    }
    return hunks.items;
}

// ---------------------------------------------------------------- hunk filtering (-B, -I) and grouping
fn lineIsBlank(line: []const u8) bool {
    var t = line;
    if (t.len > 0 and t[t.len - 1] == '\n') t = t[0 .. t.len - 1];
    if (o.strip_cr and t.len > 0 and t[t.len - 1] == '\r') t = t[0 .. t.len - 1];
    return t.len == 0;
}
fn lineMatchesIgnore(line: []const u8) bool {
    var t = line;
    if (t.len > 0 and t[t.len - 1] == '\n') t = t[0 .. t.len - 1];
    for (ignore_res.items) |*re| if (re.find(t, 0) != null) return true;
    return false;
}
fn hunkIgnorable(h: Hunk, f0: *const File, f1: *const File) bool {
    if (!o.ignore_blank_lines and ignore_res.items.len == 0) return false;
    if (o.ignore_blank_lines) {
        var all = true;
        for (f0.lines[h.l0 .. h.l0 + h.d]) |l| if (!lineIsBlank(l)) {
            all = false;
            break;
        };
        if (all) for (f1.lines[h.l1 .. h.l1 + h.n]) |l| if (!lineIsBlank(l)) {
            all = false;
            break;
        };
        if (all) return true;
    }
    if (ignore_res.items.len > 0) {
        var all = true;
        for (f0.lines[h.l0 .. h.l0 + h.d]) |l| if (!lineMatchesIgnore(l)) {
            all = false;
            break;
        };
        if (all) for (f1.lines[h.l1 .. h.l1 + h.n]) |l| if (!lineMatchesIgnore(l)) {
            all = false;
            break;
        };
        if (all) return true;
    }
    return false;
}

const Group = struct { s: usize, e: usize }; // inclusive range of hunk indices

fn groupHunks(hunks: []const Hunk, f0: *const File, f1: *const File, ctx: usize) []const Group {
    var groups = u.Vec(Group).init(u.alloc);
    var i: usize = 0;
    while (i < hunks.len) {
        const s = i;
        var e = i;
        var has_real = !hunkIgnorable(hunks[i], f0, f1);
        var j = i + 1;
        while (j < hunks.len) {
            const gap = hunks[j].l0 - (hunks[e].l0 + hunks[e].d);
            const ign = hunkIgnorable(hunks[j], f0, f1);
            // GNU find_hunk: 2*context+1 between non-ignorable changes, only context before an ignorable one
            const thresh = if (ign) ctx else ctx * 2 + 1;
            if (gap >= thresh) break;
            if (!ign) has_real = true;
            e = j;
            j += 1;
        }
        if (has_real) groups.push(.{ .s = s, .e = e });
        i = e + 1;
    }
    return groups.items;
}

// ---------------------------------------------------------------- output helpers
fn tsCol(col: usize) usize {
    return (col / o.tabsize + 1) * o.tabsize;
}

/// Prints a line prefix; returns the output column after it. -T replaces a trailing blank by a tab.
fn prefixOut(pre: []const u8) usize {
    if (!o.initial_tab or pre.len == 0) {
        u.out(pre);
        return pre.len;
    }
    var col: usize = pre.len;
    if (pre[pre.len - 1] == ' ') {
        u.out(pre[0 .. pre.len - 1]);
        col = pre.len - 1;
    } else u.out(pre);
    u.out("\t");
    return tsCol(col);
}

fn emitBody(text: []const u8, col0: usize) void {
    if (!o.expand_tabs) {
        u.out(text);
        return;
    }
    var col = col0;
    var start: usize = 0;
    for (text, 0..) |b, i| {
        if (b != '\t') {
            col += 1;
            continue;
        }
        u.out(text[start..i]);
        const n = o.tabsize - col % o.tabsize;
        var k: usize = 0;
        while (k < n) : (k += 1) u.out(" ");
        col += n;
        start = i + 1;
    }
    u.out(text[start..]);
}

/// Prints "<pre><line>\n" (+ the GNU "\ No newline at end of file" note); key/def select the colour.
fn printLine(pre: []const u8, line: []const u8, key: []const u8, def: []const u8) void {
    const active = begin(key, def);
    _ = prefixOut(pre);
    const col: usize = 0;
    const terminated = line.len > 0 and line[line.len - 1] == '\n';
    emitBody(if (terminated) line[0 .. line.len - 1] else line, col);
    endColor(active);
    u.out("\n");
    if (!terminated) u.out("\\ No newline at end of file\n");
}
fn printRaw(line: []const u8) void {
    u.out(line);
    if (!(line.len > 0 and line[line.len - 1] == '\n')) u.out("\n");
}

fn cLocale() bool {
    const l = u.getEnv("LC_ALL") orelse u.getEnv("LC_TIME") orelse u.getEnv("LANG") orelse "";
    return l.len == 0 or same(l, "C") or same(l, "POSIX");
}
fn fmtTime(f: *const File, style_ctx: bool) void {
    if (f.missing or f.epoch) {
        u.out("\t1970-01-01 00:00:00.000000000 +0000");
        return;
    }
    const st = f.st orelse return;
    var timestamp: c.time_t = @intCast(st.mtime);
    var local: c.struct_tm = undefined;
    if (style_ctx and cLocale() and c.localtime_r(&timestamp, &local) != null) {
        // traditional ctime-like stamp used by context headers in the C locale
        var date: [64]u8 = undefined;
        const n = c.strftime(&date, date.len, "%a %b %e %H:%M:%S %Y", &local);
        u.outf("\t{s}", .{date[0..n]});
        return;
    }
    if (c.localtime_r(&timestamp, &local) != null) {
        var date: [64]u8 = undefined;
        var zone: [16]u8 = undefined;
        const n = c.strftime(&date, date.len, "%Y-%m-%d %H:%M:%S", &local);
        const z = c.strftime(&zone, zone.len, "%z", &local);
        u.outf("\t{s}.{d:0>9} {s}", .{ date[0..n], @as(u64, st.mtime_nsec), zone[0..z] });
    }
}
fn header(prefix: []const u8, f: *const File, label: ?[]const u8) void {
    const active = begin("hd", "1");
    if (label) |value| {
        u.outf("{s} {s}", .{ prefix, value });
    } else {
        u.outf("{s} {s}", .{ prefix, f.name });
        fmtTime(f, o.style == .context);
    }
    endColor(active);
    u.out("\n");
}

// numbers
fn numRange(start: usize, count: usize) void { // normal/context style: "a" or "a,b"; empty => line before
    u.outf("{d}", .{if (count == 0) start else start + 1});
    if (count > 1) u.outf(",{d}", .{start + count});
}
fn numRangeInc(first: isize, last: isize) void { // context headers on inclusive 0-based first..last
    if (last >= first) {
        u.outf("{d}", .{first + 1});
        if (last > first) u.outf(",{d}", .{last + 1});
    } else u.outf("{d}", .{first});
}
fn uniRange(first: isize, last: isize) void {
    const count = last - first + 1;
    if (count <= 0) {
        u.outf("{d},0", .{first});
        return;
    }
    u.outf("{d}", .{first + 1});
    if (count != 1) u.outf(",{d}", .{count});
}

// function-name header (-p / -F)
var func_last_search: isize = 0;
var func_last_match: ?[]const u8 = null;
fn findFunction(f: *const File, linenum: isize) ?[]const u8 {
    const re = func_re orelse return null;
    var i = linenum;
    const last = func_last_search;
    func_last_search = i;
    while (true) {
        i -= 1;
        if (i < last or i < 0) break;
        var line = f.lines[@intCast(i)];
        if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
        if (re.find(line, 0) != null) {
            var len = @min(line.len, 40);
            while (len > 0 and isSpaceByte(line[len - 1])) len -= 1;
            func_last_match = line[0..len];
            return func_last_match;
        }
    }
    return func_last_match;
}

// ---------------------------------------------------------------- styles
fn printNormal(hunks: []const Hunk, groups: []const Group, f0: *const File, f1: *const File) void {
    for (groups) |gr| {
        var k = gr.s;
        while (k <= gr.e) : (k += 1) {
            const h = hunks[k];
            const active = begin("ln", "36");
            numRange(h.l0, h.d);
            u.out(if (h.d == 0) "a" else if (h.n == 0) "d" else "c");
            numRange(h.l1, h.n);
            endColor(active);
            u.out("\n");
            for (f0.lines[h.l0 .. h.l0 + h.d]) |l| printLine("< ", l, "de", "31");
            if (h.d > 0 and h.n > 0) u.out("---\n");
            for (f1.lines[h.l1 .. h.l1 + h.n]) |l| printLine("> ", l, "ad", "32");
        }
    }
}

fn printEd(hunks: []const Hunk, groups: []const Group, f1: *const File) void {
    var gi = groups.len;
    while (gi > 0) {
        gi -= 1;
        var k = groups[gi].e + 1;
        while (k > groups[gi].s) {
            k -= 1;
            const h = hunks[k];
            numRange(h.l0, h.d);
            u.out(if (h.d == 0) "a" else if (h.n == 0) "d" else "c");
            u.out("\n");
            if (h.n > 0) {
                var insert_mode = true;
                for (f1.lines[h.l1 .. h.l1 + h.n]) |l| {
                    if (!insert_mode) {
                        u.out("a\n");
                        insert_mode = true;
                    }
                    if (same(l, ".\n")) {
                        u.out("..\n.\ns/.//\n");
                        insert_mode = false;
                    } else printRaw(l);
                }
                if (insert_mode) u.out(".\n");
            }
        }
    }
}

fn printRcs(hunks: []const Hunk, groups: []const Group, f1: *const File) void {
    for (groups) |gr| {
        var k = gr.s;
        while (k <= gr.e) : (k += 1) {
            const h = hunks[k];
            if (h.d > 0) u.outf("d{d} {d}\n", .{ h.l0 + 1, h.d });
            if (h.n > 0) {
                u.outf("a{d} {d}\n", .{ h.l0 + h.d, h.n });
                for (f1.lines[h.l1 .. h.l1 + h.n]) |l| u.out(l);
            }
        }
    }
}

fn groupBounds(hunks: []const Hunk, gr: Group, f0: *const File, f1: *const File, ctx: usize) struct { first0: isize, last0: isize, first1: isize, last1: isize } {
    const hs = hunks[gr.s];
    const he = hunks[gr.e];
    const c_: isize = @intCast(ctx);
    const first0 = @max(0, @as(isize, @intCast(hs.l0)) - c_);
    const end0: isize = @as(isize, @intCast(he.l0 + he.d)) - 1; // last changed line in file 0
    const last0 = @min(@as(isize, @intCast(f0.lines.len)) - 1, end0 + c_);
    const first1 = @as(isize, @intCast(hs.l1)) - (@as(isize, @intCast(hs.l0)) - first0);
    const end1: isize = @as(isize, @intCast(he.l1 + he.n)) - 1;
    const last1 = end1 + (last0 - end0);
    _ = f1;
    return .{ .first0 = first0, .last0 = last0, .first1 = first1, .last1 = last1 };
}

fn printUnified(hunks: []const Hunk, groups: []const Group, f0: *const File, f1: *const File) void {
    header("---", f0, labels[0]);
    header("+++", f1, labels[1]);
    for (groups) |gr| {
        const b = groupBounds(hunks, gr, f0, f1, o.context);
        const active = begin("ln", "36");
        u.out("@@ -");
        uniRange(b.first0, b.last0);
        u.out(" +");
        uniRange(b.first1, b.last1);
        u.out(" @@");
        endColor(active);
        if (o.show_c_function) if (findFunction(f0, b.first0)) |fn_text| {
            u.out(" ");
            u.out(fn_text);
        };
        u.out("\n");
        var ia: isize = b.first0;
        var k = gr.s;
        while (k <= gr.e) : (k += 1) {
            const h = hunks[k];
            while (ia < @as(isize, @intCast(h.l0))) : (ia += 1) printLine(" ", f0.lines[@intCast(ia)], "", "");
            for (f0.lines[h.l0 .. h.l0 + h.d]) |l| printLine("-", l, "de", "31");
            for (f1.lines[h.l1 .. h.l1 + h.n]) |l| printLine("+", l, "ad", "32");
            ia = @intCast(h.l0 + h.d);
        }
        while (ia <= b.last0) : (ia += 1) printLine(" ", f0.lines[@intCast(ia)], "", "");
    }
}

fn printContext(hunks: []const Hunk, groups: []const Group, f0: *const File, f1: *const File) void {
    header("***", f0, labels[0]);
    header("---", f1, labels[1]);
    for (groups) |gr| {
        const b = groupBounds(hunks, gr, f0, f1, o.context);
        u.out("***************");
        if (o.show_c_function) if (findFunction(f0, b.first0)) |fn_text| {
            u.out(" ");
            u.out(fn_text);
        };
        u.out("\n");
        var show_old = false;
        var show_new = false;
        var k = gr.s;
        while (k <= gr.e) : (k += 1) {
            if (hunks[k].d > 0) show_old = true;
            if (hunks[k].n > 0) show_new = true;
        }
        var active = begin("ln", "36");
        u.out("*** ");
        numRangeInc(b.first0, b.last0);
        u.out(" ****");
        endColor(active);
        u.out("\n");
        if (show_old) {
            k = gr.s;
            var i: isize = b.first0;
            while (i <= b.last0) : (i += 1) {
                while (k < gr.e and @as(isize, @intCast(hunks[k].l0 + hunks[k].d)) <= i) k += 1;
                const h = hunks[k];
                const iu: usize = @intCast(i);
                const in_change = iu >= h.l0 and iu < h.l0 + h.d;
                const pre: []const u8 = if (in_change) (if (h.n > 0) "! " else "- ") else "  ";
                printLine(pre, f0.lines[iu], "de", "31");
            }
        }
        active = begin("ln", "36");
        u.out("--- ");
        numRangeInc(b.first1, b.last1);
        u.out(" ----");
        endColor(active);
        u.out("\n");
        if (show_new) {
            k = gr.s;
            var i: isize = b.first1;
            while (i <= b.last1) : (i += 1) {
                while (k < gr.e and @as(isize, @intCast(hunks[k].l1 + hunks[k].n)) <= i) k += 1;
                const h = hunks[k];
                const iu: usize = @intCast(i);
                const in_change = iu >= h.l1 and iu < h.l1 + h.n;
                const pre: []const u8 = if (in_change) (if (h.d > 0) "! " else "+ ") else "  ";
                printLine(pre, f1.lines[iu], "ad", "32");
            }
        }
    }
}

// ---------------------------------------------------------------- side by side
var sd_half: usize = 0;
var sd_col2: usize = 0;

fn tabFromTo(buf: *u.Vec(u8), from_in: usize, to: usize) usize {
    var from = from_in;
    if (!o.expand_tabs and o.tabsize > 0) {
        var tab = from + o.tabsize - from % o.tabsize;
        while (tab <= to) : (tab += o.tabsize) {
            buf.push('\t');
            from = tab;
        }
    }
    while (from < to) : (from += 1) buf.push(' ');
    return to;
}

fn charWidth(cp: u21) usize {
    if (cp >= 0x1100 and (cp <= 0x115f or (cp >= 0x2e80 and cp <= 0xa4cf) or (cp >= 0xac00 and cp <= 0xd7a3) or (cp >= 0xf900 and cp <= 0xfaff) or (cp >= 0xfe30 and cp <= 0xfe6f) or (cp >= 0xff00 and cp <= 0xff60) or (cp >= 0xffe0 and cp <= 0xffe6) or (cp >= 0x20000 and cp <= 0x3fffd))) return 2;
    return 1;
}

fn utf8Locale() bool {
    const l = u.getEnv("LC_ALL") orelse u.getEnv("LC_CTYPE") orelse u.getEnv("LANG") orelse "";
    var buf: [64]u8 = undefined;
    const n = @min(l.len, buf.len);
    for (l[0..n], 0..) |ch, k| buf[k] = std.ascii.toLower(ch);
    return std.mem.indexOf(u8, buf[0..n], "utf-8") != null or std.mem.indexOf(u8, buf[0..n], "utf8") != null;
}

fn halfLine(buf: *u.Vec(u8), text: []const u8, indent: usize, out_bound: usize) usize {
    const utf8 = utf8Locale();
    var in_pos: usize = 0;
    var out_pos: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b == '\t') {
            in_pos += o.tabsize - in_pos % o.tabsize;
            i += 1;
        } else if (b == '\r') {
            buf.push('\r');
            _ = tabFromTo(buf, 0, indent);
            in_pos = 0;
            out_pos = 0;
            i += 1;
        } else if (b == '\n') {
            i += 1;
        } else {
            var len: usize = 1;
            var w: usize = 1;
            if (b < 0x20 or b == 0x7f) {
                w = 0; // control characters are copied through without taking a column
            } else if (utf8 and b >= 0x80) {
                len = std.unicode.utf8ByteSequenceLength(b) catch 1;
                if (i + len > text.len) len = 1;
                if (len > 1) {
                    const cp = std.unicode.utf8Decode(text[i .. i + len]) catch blk: {
                        len = 1;
                        break :blk @as(u21, b);
                    };
                    w = charWidth(cp);
                }
            }
            if (in_pos + w <= out_bound) {
                out_pos = tabFromTo(buf, out_pos, in_pos);
                buf.pushSlice(text[i .. i + len]);
                out_pos += w;
            }
            in_pos += w;
            i += len;
        }
    }
    return out_pos;
}

fn sdiffLine(left: ?[]const u8, sep_in: u8, right: ?[]const u8, ckey: []const u8, cdef: []const u8) void {
    var buf = u.Vec(u8).init(u.alloc);
    var sep = sep_in;
    var col: usize = 0;
    var put_newline = false;
    const active = if (ckey.len > 0) beginBuf(&buf, ckey, cdef) else false;
    if (left) |l| {
        put_newline = put_newline or (l.len > 0 and l[l.len - 1] == '\n');
        col = halfLine(&buf, l, 0, sd_half);
    }
    if (sep != ' ') {
        col = tabFromTo(&buf, col, (sd_half + sd_col2 - 1) / 2) + 1;
        if (sep == '|') {
            const r = right.?;
            const r_nl = r.len > 0 and r[r.len - 1] == '\n';
            if (put_newline != r_nl) sep = if (put_newline) '/' else '\\';
        }
        buf.push(sep);
    }
    if (right) |r| {
        put_newline = put_newline or (r.len > 0 and r[r.len - 1] == '\n');
        if (!(r.len > 0 and r[0] == '\n')) {
            col = tabFromTo(&buf, col, sd_col2);
            _ = halfLine(&buf, r, col, sd_half);
        }
    }
    if (put_newline) buf.push('\n');
    if (active) buf.pushSlice("\x1b[0m");
    u.out(buf.items);
}

fn sdiffSetup() void {
    const w = o.width;
    if (o.expand_tabs) {
        sd_half = if (w >= 3) (w - 3) / 2 else 0;
        sd_col2 = w - sd_half;
    } else {
        sd_col2 = o.tabsize * ((w + o.tabsize * 3 / 2 - 1) / (o.tabsize * 2));
        const a = w -| sd_col2;
        const b = sd_col2 -| 3;
        sd_half = @min(a, b);
    }
}

fn printSdiff(hunks: []const Hunk, f0: *const File, f1: *const File) void {
    sdiffSetup();
    var ia: usize = 0;
    var ib: usize = 0;
    var k: usize = 0;
    // hunks that are ignorable (-B / -I) are shown as common lines
    const total = hunks.len;
    while (true) {
        var next_l0 = f0.lines.len;
        while (k < total and hunkIgnorable(hunks[k], f0, f1)) k += 1;
        if (k < total) next_l0 = hunks[k].l0;
        // common lines
        while (ia < next_l0) : (ia += 1) {
            if (!o.suppress_common) {
                if (o.left_column) sdiffLine(f0.lines[ia], '(', null, "", "") else sdiffLine(f0.lines[ia], ' ', f1.lines[ib], "", "");
            }
            ib += 1;
        }
        if (k >= total) break;
        const h = hunks[k];
        const common = @min(h.d, h.n);
        var j: usize = 0;
        while (j < common) : (j += 1) sdiffLine(f0.lines[h.l0 + j], '|', f1.lines[h.l1 + j], "", "");
        while (j < h.d) : (j += 1) sdiffLine(f0.lines[h.l0 + j], '<', null, "de", "31");
        j = common;
        while (j < h.n) : (j += 1) sdiffLine(null, '>', f1.lines[h.l1 + j], "ad", "32");
        ia = h.l0 + h.d;
        ib = h.l1 + h.n;
        k += 1;
    }
}

// ---------------------------------------------------------------- comparing two buffers
fn readAll(name: []const u8) ?[]const u8 {
    var fd: i32 = 0;
    if (!same(name, "-")) {
        const rc = std.os.linux.open(u.zstr(name), .{ .ACCMODE = .RDONLY }, 0);
        if (!u.ok(rc)) {
            u.errf("diff: {s}: {s}\n", .{ name, u.strerr(u.errno(rc)) });
            return null;
        }
        fd = @intCast(rc);
    }
    defer if (fd != 0) {
        _ = std.os.linux.close(fd);
    };
    var data = u.Vec(u8).init(u.alloc);
    var chunk: [65536]u8 = undefined;
    while (true) {
        const rc = std.os.linux.read(fd, &chunk, chunk.len);
        if (u.errno(rc) == .INTR) continue;
        if (!u.ok(rc)) {
            u.errf("diff: {s}: {s}\n", .{ name, u.strerr(u.errno(rc)) });
            return null;
        }
        if (rc == 0) break;
        data.pushSlice(chunk[0..rc]);
    }
    return data.items;
}

fn looksBinary(data: []const u8) bool {
    return std.mem.indexOfScalar(u8, data[0..@min(data.len, 8192)], 0) != null;
}

/// Compares two loaded files, printing the result. Returns 0 (same), 1 (differ).
fn compareBuffers(f0: *File, f1: *File, in_dir: bool) u8 {
    const nm0 = labels[0] orelse f0.name;
    const nm1 = labels[1] orelse f1.name;
    const identical_bytes = same(f0.data, f1.data);
    if (identical_bytes and o.style != .sdiff) {
        if (o.report_same) u.outf("Files {s} and {s} are identical\n", .{ nm0, nm1 });
        return 0;
    }
    if (!o.text and !identical_bytes and (looksBinary(f0.data) or looksBinary(f1.data))) {
        if (o.brief) u.outf("Files {s} and {s} differ\n", .{ nm0, nm1 }) else u.outf("Binary files {s} and {s} differ\n", .{ nm0, nm1 });
        return 1;
    }
    f0.lines = splitLines(f0.data);
    f1.lines = splitLines(f1.data);
    classify(f0, f1);
    if (identical_bytes) {
        // -y prints every line even when the files are the same
        if (in_dir) u.outf("diff{s} {s} {s}\n", .{ switches, nm0, nm1 });
        printSdiff(&.{}, f0, f1);
        return 0;
    }
    const hunks = computeHunks(f0, f1);
    const ctx: usize = switch (o.style) {
        .context, .unified => o.context,
        else => 0,
    };
    const groups = groupHunks(hunks, f0, f1, ctx);
    // sdiff reports every non-ignorable change; other styles need at least one printable group
    if (groups.len == 0) {
        if (o.style == .ed and !o.brief) {
            var trouble = false;
            for ([2]*File{ f0, f1 }) |f| {
                if (f.data.len > 0 and f.data[f.data.len - 1] != '\n') {
                    u.errf("diff: {s}: No newline at end of file\n\n", .{f.name});
                    trouble = true;
                }
            }
            if (trouble) return 2;
        }
        if (o.style == .sdiff and !o.brief) {
            printSdiff(hunks, f0, f1);
            return 0;
        }
        if (o.report_same) u.outf("Files {s} and {s} are identical\n", .{ nm0, nm1 });
        return 0;
    }
    if (o.brief) {
        u.outf("Files {s} and {s} differ\n", .{ nm0, nm1 });
        return 1;
    }
    var ed_trouble = false;
    if (o.style == .ed) {
        for ([2]*File{ f0, f1 }) |f| {
            if (f.data.len > 0 and f.data[f.data.len - 1] != '\n') {
                u.errf("diff: {s}: No newline at end of file\n\n", .{f.name});
                ed_trouble = true;
            }
        }
    }
    if (in_dir) u.outf("diff{s} {s} {s}\n", .{ switches, labels[0] orelse f0.name, labels[1] orelse f1.name });
    func_last_search = 0;
    func_last_match = null;
    switch (o.style) {
        .normal => printNormal(hunks, groups, f0, f1),
        .context => printContext(hunks, groups, f0, f1),
        .unified => printUnified(hunks, groups, f0, f1),
        .ed => printEd(hunks, groups, f1),
        .rcs => printRcs(hunks, groups, f1),
        .sdiff => printSdiff(hunks, f0, f1),
    }
    return if (ed_trouble) 2 else 1;
}

// ---------------------------------------------------------------- files and directories
const S_IFMT: u32 = 0o170000;
const S_IFDIR: u32 = 0o040000;
const S_IFREG: u32 = 0o100000;

fn isDirSt(st: ?u.Stat) bool {
    return if (st) |s| (s.mode & S_IFMT) == S_IFDIR else false;
}
fn typeName(mode: u32) []const u8 {
    return switch (mode & S_IFMT) {
        0o040000 => "directory",
        0o100000 => "regular file",
        0o120000 => "symbolic link",
        0o060000 => "block special file",
        0o020000 => "character special file",
        0o010000 => "fifo",
        0o140000 => "socket",
        else => "weird file",
    };
}

fn joinPath(dir: []const u8, name: []const u8) []const u8 {
    var d = dir;
    while (d.len > 0 and d[d.len - 1] == '/') d = d[0 .. d.len - 1];
    return std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ d, name }) catch @panic("oom");
}

fn excluded(name: []const u8) bool {
    for (excludes.items) |pat| if (u.matchPat(pat, name)) return true;
    return false;
}

/// Compares two named paths that are not both directories. `s0`/`s1` are their stat results (null: missing).
fn compareFilePair(n0: []const u8, n1: []const u8, s0: ?u.Stat, s1: ?u.Stat, in_dir: bool) u8 {
    const both_epoch = !in_dir and (s0 == null or s1 == null);
    var f0 = File{ .name = n0, .data = "", .st = s0, .missing = s0 == null, .epoch = both_epoch };
    var f1 = File{ .name = n1, .data = "", .st = s1, .missing = s1 == null, .epoch = both_epoch };
    if (s0 == null and !(o.new_file or o.unidir)) {
        u.errf("diff: {s}: No such file or directory\n", .{n0});
        return 2;
    }
    if (s1 == null and !o.new_file) {
        u.errf("diff: {s}: No such file or directory\n", .{n1});
        return 2;
    }
    if (s0) |a| if (s1) |b| {
        if (isDirSt(s0) != isDirSt(s1)) {
            u.outf("File {s} is a {s} while file {s} is a {s}\n", .{ labels[0] orelse n0, typeName(a.mode), labels[1] orelse n1, typeName(b.mode) });
            return 1;
        }
        if (o.style != .sdiff and a.dev == b.dev and a.ino == b.ino and (a.mode & S_IFMT) == S_IFREG) {
            if (o.report_same) u.outf("Files {s} and {s} are identical\n", .{ n0, n1 });
            return 0;
        }
    };
    if (isDirSt(s0) or isDirSt(s1)) { // directory vs missing
        u.outf("File {s} is a directory while file {s} is a {s}\n", .{ n0, n1, "missing" });
        return 1;
    }
    if (s0 != null) f0.data = readAll(n0) orelse return 2;
    if (s1 != null) f1.data = readAll(n1) orelse return 2;
    return compareBuffers(&f0, &f1, in_dir);
}

fn compareDirs(d0: []const u8, d1: []const u8, has0: bool, has1: bool, top: bool) u8 {
    var l0 = u.Vec(u.DirEnt).init(u.alloc);
    var l1 = u.Vec(u.DirEnt).init(u.alloc);
    if (has0 and !u.listDir(d0, &l0)) {
        u.errf("diff: {s}: Cannot read directory\n", .{d0});
        return 2;
    }
    if (has1 and !u.listDir(d1, &l1)) {
        u.errf("diff: {s}: Cannot read directory\n", .{d1});
        return 2;
    }
    var status: u8 = 0;
    var i: usize = 0;
    var j: usize = 0;
    while (i < l0.items.len or j < l1.items.len) {
        var name: []const u8 = undefined;
        var in0 = false;
        var in1 = false;
        if (j >= l1.items.len) {
            name = l0.items[i].name;
            in0 = true;
        } else if (i >= l0.items.len) {
            name = l1.items[j].name;
            in1 = true;
        } else switch (std.mem.order(u8, l0.items[i].name, l1.items[j].name)) {
            .lt => {
                name = l0.items[i].name;
                in0 = true;
            },
            .gt => {
                name = l1.items[j].name;
                in1 = true;
            },
            .eq => {
                name = l0.items[i].name;
                in0 = true;
                in1 = true;
            },
        }
        if (in0) i += 1;
        if (in1) j += 1;
        if (excluded(name)) continue;
        if (top) if (o.starting_file) |sf| if (std.mem.order(u8, name, sf) == .lt) continue;
        const p0 = joinPath(d0, name);
        const p1 = joinPath(d1, name);
        const s0: ?u.Stat = if (in0) u.stat(p0, true) else null;
        const s1: ?u.Stat = if (in1) u.stat(p1, true) else null;
        if (in0 and in1) {
            if (isDirSt(s0) and isDirSt(s1)) {
                if (o.recursive) {
                    status = @max(status, compareDirs(p0, p1, true, true, false));
                } else u.outf("Common subdirectories: {s} and {s}\n", .{ p0, p1 });
                continue;
            }
            status = @max(status, compareFilePair(p0, p1, s0, s1, true));
            continue;
        }
        // present in only one directory
        const only_s = if (in0) s0 else s1;
        const fill = o.new_file or (o.unidir and in1);
        if (!fill) {
            u.outf("Only in {s}: {s}\n", .{ if (in0) d0 else d1, name });
            status = @max(status, 1);
            continue;
        }
        if (isDirSt(only_s)) {
            if (o.recursive) {
                status = @max(status, if (in0) compareDirs(p0, p1, true, false, false) else compareDirs(p0, p1, false, true, false));
            } else {
                u.outf("Only in {s}: {s}\n", .{ if (in0) d0 else d1, name });
                status = @max(status, 1);
            }
            continue;
        }
        status = @max(status, compareFilePair(p0, p1, s0, s1, true));
    }
    return status;
}

// ---------------------------------------------------------------- command line
fn shellQuote(word: []const u8) []const u8 {
    var plain = word.len > 0;
    for (word) |b| {
        if (!(std.ascii.isAlphanumeric(b) or b == '_' or b == '.' or b == ',' or b == '/' or b == ':' or b == '@' or b == '%' or b == '+' or b == '-')) plain = false;
    }
    if (plain) return word;
    var out = u.Vec(u8).init(u.alloc);
    out.push('\'');
    for (word) |b| {
        if (b == '\'') out.pushSlice("'\\''") else out.push(b);
    }
    out.push('\'');
    return out.items;
}

fn usageErr(msg_args: []const u8) u8 {
    u.errf("diff: {s}\ndiff: Try 'diff --help' for more information.\n", .{msg_args});
    return 2;
}

const K_CONTEXT: u8 = 140;
const K_UNIFIED: u8 = 141;
const K_NORMAL: u8 = 142;
const K_LEFT: u8 = 143;
const K_SUPPRESS: u8 = 144;
const K_STRIPCR: u8 = 145;
const K_FROM: u8 = 146;
const K_TO: u8 = 147;
const K_TABSIZE: u8 = 148;
const K_COLOR: u8 = 149;
const K_PALETTE: u8 = 150;
const K_HELP: u8 = 151;
const K_HORIZON: u8 = 152;
const K_NOFOLLOW: u8 = 153;
const K_IGNFN: u8 = 154;

pub fn run(args: []const []const u8) u8 {
    o = Opts{};
    style_set = false;
    style_conflict = false;
    colored = false;
    palette = "";
    ignore_res = u.Vec(regex.Regex).init(u.alloc);
    excludes = u.Vec([]const u8).init(u.alloc);
    func_re = null;
    labels = .{ null, null };
    var color_mode: color.Mode = .never;
    var from_file: ?[]const u8 = null;
    var to_file: ?[]const u8 = null;
    var func_pat: ?[]const u8 = null;
    var digits: ?usize = null;

    const opts = [_]g.Opt{
        .{ .name = "text", .key = 'a' },
        .{ .name = "ignore-space-change", .key = 'b' },
        .{ .name = "ignore-blank-lines", .key = 'B' },
        .{ .key = 'c' },
        .{ .key = 'C', .arg = .req },
        .{ .name = "context", .key = K_CONTEXT, .arg = .opt },
        .{ .name = "minimal", .key = 'd' },
        .{ .name = "ed", .key = 'e' },
        .{ .name = "ignore-tab-expansion", .key = 'E' },
        .{ .key = 'f' },
        .{ .name = "forward-ed", .key = 'f' },
        .{ .name = "show-function-line", .key = 'F', .arg = .req },
        .{ .key = 'h' },
        .{ .name = "speed-large-files", .key = 'H' },
        .{ .name = "ignore-case", .key = 'i' },
        .{ .name = "ignore-matching-lines", .key = 'I', .arg = .req },
        .{ .name = "paginate", .key = 'l' },
        .{ .name = "label", .key = 'L', .arg = .req },
        .{ .name = "rcs", .key = 'n' },
        .{ .name = "new-file", .key = 'N' },
        .{ .name = "show-c-function", .key = 'p' },
        .{ .name = "unidirectional-new-file", .key = 'P' },
        .{ .name = "brief", .key = 'q' },
        .{ .name = "recursive", .key = 'r' },
        .{ .name = "report-identical-files", .key = 's' },
        .{ .name = "starting-file", .key = 'S', .arg = .req },
        .{ .name = "expand-tabs", .key = 't' },
        .{ .name = "initial-tab", .key = 'T' },
        .{ .key = 'u' },
        .{ .key = 'U', .arg = .req },
        .{ .name = "unified", .key = K_UNIFIED, .arg = .opt },
        .{ .key = 'v' },
        .{ .name = "version", .key = 'v' },
        .{ .name = "ignore-all-space", .key = 'w' },
        .{ .name = "width", .key = 'W', .arg = .req },
        .{ .name = "exclude", .key = 'x', .arg = .req },
        .{ .name = "exclude-from", .key = 'X', .arg = .req },
        .{ .name = "side-by-side", .key = 'y' },
        .{ .name = "ignore-trailing-space", .key = 'Z' },
        .{ .name = "normal", .key = K_NORMAL },
        .{ .name = "left-column", .key = K_LEFT },
        .{ .name = "suppress-common-lines", .key = K_SUPPRESS },
        .{ .name = "strip-trailing-cr", .key = K_STRIPCR },
        .{ .name = "from-file", .key = K_FROM, .arg = .req },
        .{ .name = "to-file", .key = K_TO, .arg = .req },
        .{ .name = "tabsize", .key = K_TABSIZE, .arg = .req },
        .{ .name = "color", .key = K_COLOR, .arg = .opt },
        .{ .name = "palette", .key = K_PALETTE, .arg = .req },
        .{ .name = "help", .key = K_HELP },
        .{ .name = "horizon-lines", .key = K_HORIZON, .arg = .req },
        .{ .name = "no-dereference", .key = K_NOFOLLOW },
        .{ .name = "ignore-file-name-case", .key = K_IGNFN },
        .{ .name = "no-ignore-file-name-case", .key = K_IGNFN },
        .{ .key = '0' }, .{ .key = '1' }, .{ .key = '2' }, .{ .key = '3' }, .{ .key = '4' },
        .{ .key = '5' }, .{ .key = '6' }, .{ .key = '7' }, .{ .key = '8' }, .{ .key = '9' },
    };
    var p = g.Parser.init("diff", args, &opts);
    p.hint_prefix = true;
    while (true) {
        const it = (p.next() catch return 2) orelse break;
        switch (it.key) {
            'a' => o.text = true,
            'b' => o.ignore_space_change = true,
            'B' => o.ignore_blank_lines = true,
            'c' => setStyle(.context),
            'C', K_CONTEXT => {
                setStyle(.context);
                if (it.val) |v| o.context = std.fmt.parseInt(usize, v, 10) catch {
                    return usageErr(std.fmt.allocPrint(u.alloc, "invalid context length '{s}'", .{v}) catch "invalid context length");
                };
            },
            'd' => o.minimal = true,
            'H', 'h', 'l', K_HORIZON, K_NOFOLLOW, K_IGNFN => {},
            'e', 'f' => setStyle(.ed),
            'E' => o.ignore_tab_expansion = true,
            'F' => func_pat = it.val,
            'i' => o.icase = true,
            'I' => {
                const re = regex.Regex.init(it.val.?, false, false) orelse return 2;
                ignore_res.push(re);
            },
            'L' => {
                if (labels[0] == null) labels[0] = it.val else if (labels[1] == null) labels[1] = it.val else return usageErr("extra operand for --label");
            },
            'n' => setStyle(.rcs),
            'N' => o.new_file = true,
            'p' => o.show_c_function = true,
            'P' => o.unidir = true,
            'q' => o.brief = true,
            'r' => o.recursive = true,
            's' => o.report_same = true,
            'S' => o.starting_file = it.val,
            't' => o.expand_tabs = true,
            'T' => o.initial_tab = true,
            'u' => setStyle(.unified),
            'U', K_UNIFIED => {
                setStyle(.unified);
                if (it.val) |v| o.context = std.fmt.parseInt(usize, v, 10) catch {
                    return usageErr(std.fmt.allocPrint(u.alloc, "invalid context length '{s}'", .{v}) catch "invalid context length");
                };
            },
            'v' => {
                u.out(version_text);
                return 0;
            },
            'w' => o.ignore_all_space = true,
            'W' => o.width = std.fmt.parseInt(usize, it.val.?, 10) catch {
                return usageErr(std.fmt.allocPrint(u.alloc, "invalid width '{s}'", .{it.val.?}) catch "invalid width");
            },
            'x' => excludes.push(it.val.?),
            'X' => {
                const data = readAll(it.val.?) orelse return 2;
                var ls = std.mem.splitScalar(u8, data, '\n');
                while (ls.next()) |l| if (l.len > 0) excludes.push(l);
            },
            'y' => setStyle(.sdiff),
            'Z' => o.ignore_trailing_space = true,
            K_NORMAL => setStyle(.normal),
            K_LEFT => o.left_column = true,
            K_SUPPRESS => o.suppress_common = true,
            K_STRIPCR => o.strip_cr = true,
            K_FROM => from_file = it.val,
            K_TO => to_file = it.val,
            K_TABSIZE => {
                o.tabsize = std.fmt.parseInt(usize, it.val.?, 10) catch {
                    return usageErr(std.fmt.allocPrint(u.alloc, "invalid tabsize '{s}'", .{it.val.?}) catch "invalid tabsize");
                };
                if (o.tabsize == 0) {
                    return usageErr("invalid tabsize '0'");
                }
            },
            K_COLOR => color_mode = if (it.val) |v| (color.parse(v) orelse {
                return usageErr(std.fmt.allocPrint(u.alloc, "invalid color '{s}'", .{v}) catch "invalid color");
            }) else .auto,
            K_PALETTE => palette = it.val.?,
            K_HELP => {
                u.out(help_text);
                return 0;
            },
            '0'...'9' => {
                digits = (digits orelse 0) * 10 + (it.key - '0');
            },
            else => return usageErr("invalid option"),
        }
    }
    if (style_conflict) return usageErr("conflicting output style options");
    if (digits) |d| o.context = d;
    if (func_pat != null or o.show_c_function) {
        func_re = regex.Regex.init(func_pat orelse "^[[:alpha:]$_]", false, false) orelse return 2;
        o.show_c_function = true;
    }
    colored = color.grepEnabled(color_mode);

    // operands
    var ops = u.Vec([]const u8).init(u.alloc);
    for (p.operands.items) |x| ops.push(x);
    if (from_file) |ff| {
        if (ops.items.len == 0) return usageErr(std.fmt.allocPrint(u.alloc, "missing operand after '{s}'", .{if (args.len > 0) args[args.len - 1] else "diff"}) catch "missing operand");
        // diff --from-file=F operand...: compare F with every operand
        var status: u8 = 0;
        for (ops.items) |x| status = @max(status, compareTop(ff, x));
        return status;
    }
    if (to_file) |tf| {
        if (ops.items.len == 0) return usageErr(std.fmt.allocPrint(u.alloc, "missing operand after '{s}'", .{if (args.len > 0) args[args.len - 1] else "diff"}) catch "missing operand");
        var status: u8 = 0;
        for (ops.items) |x| status = @max(status, compareTop(x, tf));
        return status;
    }
    if (ops.items.len < 2) {
        const last: []const u8 = if (ops.items.len == 1) ops.items[0] else if (args.len > 0 and p.operands.items.len == 0 and false) args[args.len - 1] else "diff";
        return usageErr(std.fmt.allocPrint(u.alloc, "missing operand after '{s}'", .{last}) catch "missing operand");
    }
    if (ops.items.len > 2) return usageErr(std.fmt.allocPrint(u.alloc, "extra operand '{s}'", .{ops.items[2]}) catch "extra operand");

    // the "diff <switches> a b" header line echoes the command line without the two operands
    var sw = u.Vec(u8).init(u.alloc);
    var skip0 = true;
    var skip1 = true;
    var idx = args.len;
    var keep = u.alloc.alloc(bool, args.len) catch @panic("oom");
    @memset(keep, true);
    while (idx > 0) {
        idx -= 1;
        if (skip1 and same(args[idx], ops.items[1])) {
            skip1 = false;
            keep[idx] = false;
        } else if (!skip1 and skip0 and same(args[idx], ops.items[0])) {
            skip0 = false;
            keep[idx] = false;
        }
    }
    for (args, 0..) |a, k| if (keep[k]) {
        sw.push(' ');
        sw.pushSlice(shellQuote(a));
    };
    switches = sw.items;
    return compareTop(ops.items[0], ops.items[1]);
}

fn compareTop(a: []const u8, b: []const u8) u8 {
    var n0 = a;
    var n1 = b;
    const s0: ?u.Stat = if (same(a, "-")) u.statFd(0) else u.stat(a, true);
    const s1: ?u.Stat = if (same(b, "-")) u.statFd(0) else u.stat(b, true);
    if (isDirSt(s0) and isDirSt(s1)) return compareDirs(a, b, true, true, true);
    if (isDirSt(s0) != isDirSt(s1) and s0 != null and s1 != null) {
        // a file compared with a directory: use the file's name inside the directory
        if (isDirSt(s0)) {
            if (same(b, "-")) {
                u.errf("diff: cannot compare '-' to a directory\n", .{});
                return 2;
            }
            n0 = joinPath(a, u.basename(b));
            return compareFilePair(n0, n1, u.stat(n0, true), s1, false);
        }
        if (same(a, "-")) {
            u.errf("diff: cannot compare '-' to a directory\n", .{});
            return 2;
        }
        n1 = joinPath(b, u.basename(a));
        return compareFilePair(n0, n1, s0, u.stat(n1, true), false);
    }
    if (s0 == null and !(o.new_file or o.unidir)) {
        u.errf("diff: {s}: No such file or directory\n", .{a});
        return 2;
    }
    if (s1 == null and !o.new_file) {
        u.errf("diff: {s}: No such file or directory\n", .{b});
        return 2;
    }
    if ((s0 == null or s1 == null) and o.recursive) {
        // -N with a missing directory operand
        if (isDirSt(s0) or isDirSt(s1)) return compareDirs(a, b, s0 != null, s1 != null, true);
    }
    return compareFilePair(n0, n1, s0, s1, false);
}
