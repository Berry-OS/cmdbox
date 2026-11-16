// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// vi.zig - compact vi-style visual editor applet
//
// Supported subset (busybox-vi flavor):
//   motion   h j k l 0 $ ^ w b e G gg arrows Ctrl-F/B/D/U
//   edit     i a A I o O x X s D C S r ~ J p P dd dw de db d$ d0 dG gg y$ u Ctrl-R ZZ
//   insert   printable input, Backspace, Enter, Ctrl-W (word delete), arrows
//   search   /pattern ?pattern n N (plain text match)
//   ex       :w :w FILE :q :q! :wq :x :e FILE :e! :N :set ... :help
//   other    count prefixes, "-- INSERT --" status line

const std = @import("std");
const u = @import("util.zig");
const linux = std.os.linux;

const TCGETS: u32 = 0x5401;
const TCSETS: u32 = 0x5402;
const TIOCGWINSZ: u32 = 0x5413;
const Winsize = extern struct { row: u16, col: u16, xpixel: u16, ypixel: u16 };

// ---------- buffer state ----------
var lines: [][]u8 = &.{}; // owned lines, no trailing '\n'
var nlines: usize = 0;
var lcap: usize = 0;
var cur: usize = 0; // cursor line
var col: usize = 0; // cursor column (byte offset)
var top: usize = 0; // first buffer line on screen
var rows: usize = 24;
var cols: usize = 80;
var modified = false;
var readonly = false;
var fname: []const u8 = "";
var noeol = false; // original file lacked a trailing newline

var msg: []const u8 = "";
var msg_buf: [160]u8 = undefined;
var last_search: []const u8 = "";
var search_back = false;

var yank_buf: []u8 = ""; // last yank/delete register
var yank_line = false; // linewise register

const Snap = struct { lines: [][]u8, n: usize, cur: usize, col: usize };
var undo_stack: [32]Snap = undefined;
var undo_n: usize = 0;
var redo_stack: [32]Snap = undefined;
var redo_n: usize = 0;

var ob: u.Vec(u8) = undefined; // render output buffer
var inserting = false;

// ---------- buffer primitives ----------
fn bufReserve() void {
    if (nlines < lcap) return;
    const nc = if (lcap == 0) 64 else lcap * 2;
    const nb = u.alloc.alloc([]u8, nc) catch @panic("oom");
    @memcpy(nb[0..nlines], lines);
    if (lcap > 0) u.alloc.free(lines);
    lines = nb;
    lcap = nc;
}

fn insertLine(at: usize, s: []const u8) void {
    bufReserve();
    var i = nlines;
    while (i > at) : (i -= 1) lines[i] = lines[i - 1];
    const m = u.alloc.alloc(u8, s.len) catch @panic("oom");
    @memcpy(m, s);
    lines[at] = m;
    nlines += 1;
}

fn removeLine(at: usize) void {
    u.alloc.free(lines[at]);
    var i = at;
    while (i + 1 < nlines) : (i += 1) lines[i] = lines[i + 1];
    nlines -= 1;
}

fn setLine(i: usize, s: []const u8) void {
    const m = u.alloc.alloc(u8, s.len) catch @panic("oom");
    @memcpy(m, s);
    u.alloc.free(lines[i]);
    lines[i] = m;
}

fn insertChar(i: usize, at: usize, ch: u8) void {
    const m = u.alloc.alloc(u8, lines[i].len + 1) catch @panic("oom");
    @memcpy(m[0..at], lines[i][0..at]);
    m[at] = ch;
    @memcpy(m[at + 1 ..], lines[i][at..]);
    u.alloc.free(lines[i]);
    lines[i] = m;
}

fn deleteChar(i: usize, at: usize) void {
    if (at >= lines[i].len) return;
    const m = u.alloc.alloc(u8, lines[i].len - 1) catch @panic("oom");
    @memcpy(m[0..at], lines[i][0..at]);
    @memcpy(m[at..], lines[i][at + 1 ..]);
    u.alloc.free(lines[i]);
    lines[i] = m;
}

fn splitLine(i: usize, at: usize) void {
    const tail = u.alloc.alloc(u8, lines[i].len - at) catch @panic("oom");
    @memcpy(tail, lines[i][at..]);
    setLine(i, lines[i][0..at]);
    insertLine(i + 1, tail);
    u.alloc.free(tail);
}

fn ensureBuffer() void {
    if (nlines == 0) insertLine(0, "");
}

// keep col valid in normal mode: 0 for empty lines, len-1 otherwise
fn clampCol() void {
    const len = lines[cur].len;
    const limit: usize = if (len == 0) 0 else len - 1;
    if (col > limit) col = limit;
}

// ---------- undo / redo ----------
fn snapTake() Snap {
    const nl = u.alloc.alloc([]u8, nlines) catch @panic("oom");
    for (lines[0..nlines], 0..) |l, i| {
        nl[i] = u.alloc.alloc(u8, l.len) catch @panic("oom");
        @memcpy(nl[i], l);
    }
    return .{ .lines = nl, .n = nlines, .cur = cur, .col = col };
}

fn snapFree(s: *Snap) void {
    for (s.lines[0..s.n]) |l| u.alloc.free(l);
    u.alloc.free(s.lines);
    s.* = .{ .lines = &.{}, .n = 0, .cur = 0, .col = 0 };
}

fn snapApply(s: Snap) void {
    for (lines[0..nlines]) |l| u.alloc.free(l);
    if (lcap > 0) u.alloc.free(lines);
    lines = s.lines;
    lcap = s.n;
    nlines = s.n;
    if (nlines == 0) ensureBuffer();
    if (cur >= nlines) cur = nlines - 1;
    clampCol();
    modified = true;
}

fn pushUndo() void {
    if (nlines > 20000) return; // keep memory bounded on huge files
    if (undo_n == undo_stack.len) {
        snapFree(&undo_stack[0]);
        for (1..undo_stack.len) |i| undo_stack[i - 1] = undo_stack[i];
        undo_n -= 1;
    }
    undo_stack[undo_n] = snapTake();
    undo_n += 1;
    // a new branch of changes invalidates the redo stack
    for (redo_stack[0..redo_n]) |*s| snapFree(s);
    redo_n = 0;
}

fn pushRedo() void {
    if (redo_n == redo_stack.len) {
        snapFree(&redo_stack[0]);
        for (1..redo_stack.len) |i| redo_stack[i - 1] = redo_stack[i];
        redo_n -= 1;
    }
    redo_stack[redo_n] = snapTake();
    redo_n += 1;
}

fn setMsg(comptime fmt: []const u8, args: anytype) void {
    msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "";
}

// ---------- word helpers ----------
fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

// position of the start of the next word
fn wordFwd(l: usize, c: usize) struct { l: usize, c: usize } {
    var li = l;
    var ci = c;
    const len = lines[li].len;
    if (ci >= len) {
        while (li + 1 < nlines) {
            li += 1;
            if (lineStartWord(li)) |wc| return .{ .l = li, .c = wc };
        }
        return .{ .l = nlines - 1, .c = lines[nlines - 1].len };
    }
    // skip the current word / punctuation run
    if (!isBlank(lines[li][ci])) {
        const w = isWordChar(lines[li][ci]);
        while (ci < len and isWordChar(lines[li][ci]) == w and !isBlank(lines[li][ci])) ci += 1;
    }
    // skip whitespace
    while (ci < len and isBlank(lines[li][ci])) ci += 1;
    if (ci < len) return .{ .l = li, .c = ci };
    while (li + 1 < nlines) {
        li += 1;
        if (lineStartWord(li)) |wc| return .{ .l = li, .c = wc };
    }
    return .{ .l = nlines - 1, .c = lines[nlines - 1].len };
}

fn lineStartWord(i: usize) ?usize {
    const l = lines[i];
    if (l.len == 0) return 0;
    if (!isBlank(l[0])) return 0;
    var ci: usize = 0;
    while (ci < l.len and isBlank(l[ci])) ci += 1;
    if (ci < l.len) return ci;
    return null;
}

// end of the word at/after the cursor
fn wordEnd(l: usize, c: usize) struct { l: usize, c: usize } {
    var li = l;
    var ci = c;
    while (true) {
        const len = lines[li].len;
        if (ci < len and isWordChar(lines[li][ci])) {
            // already inside a word: run to its end
            while (ci + 1 < len and isWordChar(lines[li][ci + 1])) ci += 1;
            return .{ .l = li, .c = ci };
        }
        // scan forward for the next word and its end
        ci += 1;
        if (ci >= len) {
            if (li + 1 >= nlines) return .{ .l = li, .c = if (len > 0) len - 1 else 0 };
            li += 1;
            ci = 0;
            if (lines[li].len == 0) return .{ .l = li, .c = 0 };
            continue;
        }
    }
}

// start of the previous word
fn wordBack(l: usize, c: usize) struct { l: usize, c: usize } {
    var li = l;
    var ci = c;
    while (true) {
        if (ci == 0) {
            if (li == 0) return .{ .l = 0, .c = 0 };
            li -= 1;
            ci = lines[li].len;
            if (ci == 0) return .{ .l = li, .c = 0 };
            continue;
        }
        ci -= 1;
        if (isWordChar(lines[li][ci])) {
            while (ci > 0 and isWordChar(lines[li][ci - 1])) ci -= 1;
            return .{ .l = li, .c = ci };
        }
    }
}

// ---------- motions ----------
const Pos = struct { l: usize, c: usize };

fn mLeft(n: usize) void {
    col -= @min(n, col);
}

fn mRight(n: usize) void {
    const len = lines[cur].len;
    if (len > 0) col += @min(n, len - 1 - col);
}

fn mUp(n: usize) void {
    const want = col;
    cur -= @min(n, cur);
    col = want;
    clampCol();
}

fn mDown(n: usize) void {
    const want = col;
    cur += @min(n, nlines - 1 - cur);
    col = want;
    clampCol();
}

fn mLineStart() void {
    col = 0;
}

fn mFirstNonBlank() void {
    const l = lines[cur];
    var i: usize = 0;
    while (i < l.len and isBlank(l[i])) i += 1;
    col = if (i < l.len) i else 0;
}

fn mLineEnd() void {
    col = if (lines[cur].len > 0) lines[cur].len - 1 else 0;
}

fn mWordFwd(n: usize) void {
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const t = wordFwd(cur, col);
        cur = t.l;
        col = t.c;
    }
    clampCol();
}

fn mWordEnd(n: usize) void {
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const t = wordEnd(cur, col);
        cur = t.l;
        col = t.c;
    }
    clampCol();
}

fn mWordBack(n: usize) void {
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const t = wordBack(cur, col);
        cur = t.l;
        col = t.c;
    }
    clampCol();
}

fn mGotoLine(n: usize) void {
    cur = if (n == 0) nlines - 1 else @min(n - 1, nlines - 1);
    mFirstNonBlank();
}

fn mPageFwd() void {
    const step = @max(@as(usize, 1), rows - 2);
    cur += @min(step, nlines - 1 - cur);
    mFirstNonBlank();
}

fn mPageBack() void {
    const step = @max(@as(usize, 1), rows - 2);
    cur -= @min(step, cur);
    mFirstNonBlank();
}

fn mHalfFwd() void {
    const step = @max(@as(usize, 1), (rows - 2) / 2);
    cur += @min(step, nlines - 1 - cur);
    mFirstNonBlank();
}

fn mHalfBack() void {
    const step = @max(@as(usize, 1), (rows - 2) / 2);
    cur -= @min(step, cur);
    mFirstNonBlank();
}

// target position of a motion for operators (d / y / c)
fn opTarget(kind: u8, count: usize) struct { p: Pos, line_motion: bool } {
    const n = @max(@as(usize, 1), count);
    switch (kind) {
        'w' => {
            var li = cur;
            var ci = col;
            var k: usize = 0;
            while (k < n) : (k += 1) {
                const t = wordFwd(li, ci);
                li = t.l;
                ci = t.c;
            }
            return .{ .p = .{ .l = li, .c = ci }, .line_motion = false };
        },
        'e' => {
            var li = cur;
            var ci = col;
            var k: usize = 0;
            while (k < n) : (k += 1) {
                const t = wordEnd(li, ci);
                li = t.l;
                ci = t.c;
            }
            return .{ .p = .{ .l = li, .c = ci + 1 }, .line_motion = false };
        },
        'b' => {
            var li = cur;
            var ci = col;
            var k: usize = 0;
            while (k < n) : (k += 1) {
                const t = wordBack(li, ci);
                li = t.l;
                ci = t.c;
            }
            return .{ .p = .{ .l = li, .c = ci }, .line_motion = false };
        },
        '$' => return .{ .p = .{ .l = cur, .c = lines[cur].len }, .line_motion = false },
        '0' => return .{ .p = .{ .l = cur, .c = 0 }, .line_motion = false },
        '^' => {
            var ci: usize = 0;
            const l = lines[cur];
            while (ci < l.len and isBlank(l[ci])) ci += 1;
            return .{ .p = .{ .l = cur, .c = ci }, .line_motion = false };
        },
        'G' => return .{ .p = .{ .l = nlines - 1, .c = 0 }, .line_motion = true },
        'g' => return .{ .p = .{ .l = 0, .c = 0 }, .line_motion = true }, // gg
        else => return .{ .p = .{ .l = cur, .c = col }, .line_motion = false },
    }
}

// ---------- range editing ----------
fn joinRange(from: usize, to: usize, sep: []const u8) []u8 {
    var total: usize = 0;
    var i = from;
    while (i <= to) : (i += 1) total += lines[i].len;
    total += sep.len * (to - from);
    const m = u.alloc.alloc(u8, @max(@as(usize, 1), total)) catch @panic("oom");
    var n: usize = 0;
    i = from;
    while (i <= to) : (i += 1) {
        if (i > from) {
            @memcpy(m[n..n + sep.len], sep);
            n += sep.len;
        }
        @memcpy(m[n..n + lines[i].len], lines[i]);
        n += lines[i].len;
    }
    return m[0..n];
}

fn copyRange(l1: usize, c1: usize, l2: usize, c2: usize, linewise: bool) []u8 {
    if (linewise or l1 == l2) {
        if (linewise) return joinRange(l1, l2, "\n");
        const m = u.alloc.alloc(u8, @max(@as(usize, 1), c2 - c1)) catch @panic("oom");
        @memcpy(m[0..c2 - c1], lines[l1][c1..c2]);
        return m[0..c2 - c1];
    }
    // multi-line charwise
    var total = lines[l1].len - c1 + c2 + 1;
    var i = l1 + 1;
    while (i < l2) : (i += 1) total += lines[i].len + 1;
    const m = u.alloc.alloc(u8, total) catch @panic("oom");
    var n: usize = 0;
    @memcpy(m[0..lines[l1].len - c1], lines[l1][c1..]);
    n = lines[l1].len - c1;
    m[n] = '\n';
    n += 1;
    i = l1 + 1;
    while (i < l2) : (i += 1) {
        @memcpy(m[n..n + lines[i].len], lines[i]);
        n += lines[i].len;
        m[n] = '\n';
        n += 1;
    }
    @memcpy(m[n..n + c2], lines[l2][0..c2]);
    return m[0..n + c2];
}

fn setYank(data: []u8, linewise: bool) void {
    if (yank_buf.len > 0) u.alloc.free(yank_buf);
    yank_buf = data;
    yank_line = linewise;
}

fn deleteRange(l1: usize, c1: usize, l2: usize, c2: usize, linewise: bool) void {
    if (linewise) {
        setYank(joinRange(l1, l2, "\n"), true);
        var i = l2 + 1;
        while (i > l1) : (i -= 1) removeLine(i - 1);
        ensureBuffer();
        if (cur >= nlines) cur = nlines - 1;
        clampCol();
        modified = true;
        return;
    }
    setYank(copyRange(l1, c1, l2, c2, false), false);
    if (l1 == l2) {
        if (c2 > c1) {
            const m = u.alloc.alloc(u8, lines[l1].len - (c2 - c1)) catch @panic("oom");
            @memcpy(m[0..c1], lines[l1][0..c1]);
            @memcpy(m[c1..], lines[l1][c2..]);
            u.alloc.free(lines[l1]);
            lines[l1] = m;
        }
    } else {
        // first line keeps its prefix, last line keeps its suffix
        const keep1 = lines[l1][0..c1];
        const keep2 = lines[l2][c2..];
        const m = u.alloc.alloc(u8, keep1.len + keep2.len) catch @panic("oom");
        @memcpy(m[0..keep1.len], keep1);
        @memcpy(m[keep1.len..], keep2);
        setLine(l1, m);
        u.alloc.free(m);
        var i = l2 + 1;
        while (i > l1 + 1) : (i -= 1) removeLine(i - 1);
    }
    ensureBuffer();
    clampCol();
    modified = true;
}

fn paste(after: bool, count: usize) void {
    if (yank_buf.len == 0) return;
    var k: usize = 0;
    while (k < count) : (k += 1) {
        if (yank_line) {
            const at = if (after) cur + 1 else cur;
            var it = std.mem.splitScalar(u8, yank_buf, '\n');
            var li = at;
            while (it.next()) |seg| {
                insertLine(li, seg);
                li += 1;
            }
            cur = at;
            col = 0;
        } else {
            const ci = if (after and lines[cur].len > 0) col + 1 else col;
            const prefix = lines[cur][0..ci];
            const tail = u.alloc.alloc(u8, lines[cur].len - ci) catch @panic("oom");
            @memcpy(tail, lines[cur][ci..]);
            // collect segments
            var segs = u.Vec([]const u8).init(u.alloc);
            var it = std.mem.splitScalar(u8, yank_buf, '\n');
            while (it.next()) |seg| segs.push(seg);
            if (segs.items.len == 1) {
                const total = prefix.len + segs.items[0].len + tail.len;
                const m = u.alloc.alloc(u8, total) catch @panic("oom");
                @memcpy(m[0..prefix.len], prefix);
                @memcpy(m[prefix.len..prefix.len + segs.items[0].len], segs.items[0]);
                @memcpy(m[prefix.len + segs.items[0].len ..], tail);
                setLine(cur, m);
                u.alloc.free(m);
                col = ci;
            } else {
                const total = prefix.len + segs.items[0].len;
                const m = u.alloc.alloc(u8, total) catch @panic("oom");
                @memcpy(m[0..prefix.len], prefix);
                @memcpy(m[prefix.len..], segs.items[0]);
                setLine(cur, m);
                u.alloc.free(m);
                var li = cur;
                var si: usize = 1;
                while (si < segs.items.len) : (si += 1) {
                    li += 1;
                    if (si == segs.items.len - 1) {
                        const m2 = u.alloc.alloc(u8, segs.items[si].len + tail.len) catch @panic("oom");
                        @memcpy(m2[0..segs.items[si].len], segs.items[si]);
                        @memcpy(m2[segs.items[si].len ..], tail);
                        insertLine(li, m2);
                        u.alloc.free(m2);
                    } else insertLine(li, segs.items[si]);
                }
                col = ci;
            }
            u.alloc.free(tail);
        }
    }
    modified = true;
    clampCol();
}

// ---------- file io ----------
fn loadFile(path: []const u8) bool {
    const data = @import("input.zig").read(path, true) orelse return false;
    if (data.len == 0) return true;
    noeol = data[data.len - 1] != '\n';
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |seg| insertLine(nlines, seg);
    if (!noeol) removeLine(nlines - 1); // split produced an empty final line
    return true;
}

fn saveFile(path: []const u8) bool {
    var mode: u32 = 0o644;
    if (u.stat(path, true)) |st| mode = st.mode & 0o7777;
    const f = u.File.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, mode) orelse {
        setMsg("\"{s}\" E212: can't open file for writing", .{path});
        return false;
    };
    defer f.close();
    var total: usize = 0;
    for (lines[0..nlines]) |l| total += l.len + 1;
    if (noeol) total -= 1;
    if (total == 0) {
        modified = false;
        return true;
    }
    const data = u.alloc.alloc(u8, total) catch @panic("oom");
    defer u.alloc.free(data);
    var n: usize = 0;
    for (lines[0..nlines], 0..) |l, i| {
        @memcpy(data[n..n + l.len], l);
        n += l.len;
        if (i + 1 < nlines or !noeol) {
            data[n] = '\n';
            n += 1;
        }
    }
    if (!f.write(data[0..n])) {
        setMsg("write error", .{});
        return false;
    }
    modified = false;
    return true;
}

// ---------- terminal ----------
var saved_tio: linux.termios = undefined;

fn setRaw(t: *linux.termios, vmin: u8, vtime: u8) void {
    t.iflag.IXON = false;
    t.lflag.ISIG = false;
    t.lflag.ICANON = false;
    t.lflag.ECHO = false;
    t.lflag.IEXTEN = false;
    t.cc[@intFromEnum(linux.V.MIN)] = vmin;
    t.cc[@intFromEnum(linux.V.TIME)] = vtime;
}

fn rawOn() bool {
    var t: linux.termios = undefined;
    if (!u.ok(linux.ioctl(0, TCGETS, @intFromPtr(&t)))) return false;
    saved_tio = t;
    setRaw(&t, 1, 0);
    return u.ok(linux.ioctl(0, TCSETS, @intFromPtr(&t)));
}

fn rawOff() void {
    _ = linux.ioctl(0, TCSETS, @intFromPtr(&saved_tio));
}

fn querySize() void {
    var ws: Winsize = undefined;
    if (u.ok(linux.ioctl(1, TIOCGWINSZ, @intFromPtr(&ws))) and ws.row > 4 and ws.col > 4) {
        rows = ws.row;
        cols = ws.col;
    }
}

fn readByte() u8 {
    var c: [1]u8 = undefined;
    while (true) {
        const rc = linux.read(0, &c, 1);
        if (u.errno(rc) == .INTR) continue;
        if (u.ok(rc) and rc == 1) return c[0];
        rawOff();
        u.out("\x1b[?25h");
        u.errf("vi: input error\n", .{});
        linux.exit(1);
    }
}

// after ESC: grab the rest of the sequence with a short timeout
fn readSeq(buf: []u8) usize {
    var t = saved_tio;
    setRaw(&t, 0, 2); // 0.2 s inter-byte timeout
    _ = linux.ioctl(0, TCSETS, @intFromPtr(&t));
    defer {
        setRaw(&t, 1, 0);
        _ = linux.ioctl(0, TCSETS, @intFromPtr(&t));
    }
    var n: usize = 0;
    while (n < buf.len) {
        const rc = linux.read(0, buf.ptr + n, 1);
        if (!u.ok(rc) or rc == 0) break;
        n += 1;
    }
    return n;
}

// ---------- display ----------
fn dispw(s: []const u8, upto: usize) usize {
    var w: usize = 0;
    for (s[0..@min(upto, s.len)]) |ch| {
        if (ch == '\t') w += 8 - (w % 8) else w += 1;
    }
    return w;
}

fn wrapCount(s: []const u8) usize {
    const w = dispw(s, s.len);
    return @max(@as(usize, 1), (w + cols - 1) / cols);
}

fn push(comptime fmt: []const u8, args: anytype) void {
    var tmp: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, fmt, args) catch return;
    pushStr(s);
}

fn pushStr(s: []const u8) void {
    for (s) |c| ob.push(c);
}

// emit display cells [from, to) of one buffer line with tabs expanded
fn pushCells(line: []const u8, from: usize, to: usize) void {
    var cell: usize = 0;
    var i: usize = 0;
    const width = dispw(line, line.len);
    const end = @min(to, width);
    while (i < line.len and cell < end) : (i += 1) {
        const ch = line[i];
        if (ch == '\t') {
            const next = cell + (8 - (cell % 8));
            while (cell < next) {
                if (cell >= from) ob.push(' ');
                cell += 1;
            }
        } else {
            if (cell >= from) ob.push(ch);
            cell += 1;
        }
    }
    while (cell < end) {
        if (cell >= from) ob.push(' ');
        cell += 1;
    }
}

fn render() void {
    ob = u.Vec(u8).init(u.alloc);
    push("\x1b[H", .{});
    const vis = @max(@as(usize, 1), rows - 2);
    var crow: usize = vis - 1;
    var ccol: usize = 0;

    var srow: usize = 0;
    var li: usize = top;
    var crow_found = false;
    while (li < nlines and srow < vis) : (li += 1) {
        const l = lines[li];
        const wc = wrapCount(l);
        const start_row = srow;
        var seg: usize = 0;
        while (seg < wc and srow < vis) : (seg += 1) {
            pushCells(l, seg * cols, (seg + 1) * cols);
            push("\x1b[K\r\n", .{});
            srow += 1;
        }
        if (li == cur and !crow_found) {
            const dw = dispw(l, col);
            const target = start_row + @min(dw / cols, wc - 1);
            if (target < vis) {
                crow = target;
                ccol = @min(dw % cols, cols - 1);
                crow_found = true;
            }
        }
    }
    while (srow < vis) {
        push("\x1b[K\r\n", .{});
        srow += 1;
    }
    if (!crow_found) {
        crow = vis - 1;
        ccol = 0;
    }

    // status line (reverse video)
    var stat: [256]u8 = undefined;
    const pct: usize = if (nlines <= 1) 100 else ((cur + 1) * 100 + nlines / 2) / nlines;
    const left: []const u8 = if (inserting) "-- INSERT --" else if (readonly) "-- VIEW --" else "";
    const right = std.fmt.bufPrint(&stat, "\"{s}\"{s} {d}L {d}%  {d},{d}", .{
        fname, if (modified) " [Modified]" else "", nlines, pct, cur + 1, col + 1,
    }) catch "";
    push("\x1b[7m", .{});
    const used = @min(left.len + right.len, cols);
    pushStr(left[0..@min(left.len, used)]);
    if (left.len < used) pushStr(right[0..@min(right.len, used - left.len)]);
    var p: usize = used;
    while (p < cols) : (p += 1) ob.push(' ');
    push("\x1b[0m\x1b[K\r\n", .{});

    // command / message line
    push("\x1b[7m", .{});
    pushStr(msg[0..@min(msg.len, cols)]);
    push("\x1b[0m\x1b[K", .{});

    push("\x1b[{d};{d}H", .{ crow + 1, ccol + 1 });
    u.out(ob.items);
}

// ---------- prompt (for ':' and '/') ----------
var prompt_text: [256]u8 = undefined;
var prompt_len: usize = 0;

fn promptLoop(prompt: []const u8) ?[]const u8 {
    prompt_len = 0;
    while (true) {
        msg = std.fmt.bufPrint(&msg_buf, "{s}{s}", .{ prompt, prompt_text[0..prompt_len] }) catch "";
        renderPromptRow(prompt.len + prompt_len + 1);
        const c = readByte();
        switch (c) {
            '\r', '\n' => {
                msg = "";
                return prompt_text[0..prompt_len];
            },
            0x1b => {
                msg = "";
                return null;
            },
            0x7f, 0x08 => {
                if (prompt_len > 0) prompt_len -= 1;
            },
            0x15 => prompt_len = 0, // Ctrl-U
            else => {
                if (c >= 0x20 and prompt_len < prompt_text.len) {
                    prompt_text[prompt_len] = c;
                    prompt_len += 1;
                }
            },
        }
    }
}

fn renderPromptRow(ccol: usize) void {
    var b: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "\x1b[{d};1H\x1b[7m{s}\x1b[0m\x1b[K\x1b[{d};{d}H", .{
        rows, msg[0..@min(msg.len, cols)], rows, @min(ccol, cols),
    }) catch return;
    u.out(s);
}

// ---------- search ----------
fn doSearch(pat: []const u8, back: bool) void {
    if (pat.len > 0) {
        const m = u.alloc.dupe(u8, pat) catch return;
        if (last_search.len > 0) u.alloc.free(last_search);
        last_search = m;
        search_back = back;
    }
    if (last_search.len == 0) {
        setMsg("E35: No previous regular expression", .{});
        return;
    }
    const dir: isize = if (back) -1 else 1;
    var li = cur;
    var k: usize = 0;
    while (k < nlines) : (k += 1) {
        li = @intCast(@mod(@as(isize, @intCast(li)) + dir, @as(isize, @intCast(nlines))));
        if (std.mem.indexOf(u8, lines[li], last_search)) |hit| {
            cur = li;
            col = hit;
            setMsg("/{s}", .{last_search});
            return;
        }
    }
    setMsg("E486: Pattern not found: {s}", .{last_search});
}

// ---------- ex commands ----------
fn exCommand(cmd: []const u8) bool { // false = quit the editor
    const name0 = std.mem.trim(u8, cmd, " \t");
    if (name0.len == 0) return true;

    var name = name0;
    var force = false;
    if (name.len > 1 and name[name.len - 1] == '!') {
        force = true;
        name = std.mem.trim(u8, name[0 .. name.len - 1], " \t");
    }

    // :N (goto line), :$ (goto last line)
    if (u.toInt(name)) |num| {
        mGotoLine(@intCast(@max(@as(i64, 1), num)));
        return true;
    }
    if (std.mem.eql(u8, name, "$")) {
        mGotoLine(0);
        return true;
    }
    if (std.mem.eql(u8, name, "q")) {
        if (modified and !force) {
            setMsg("E37: No write since last change (add ! to override)", .{});
            return true;
        }
        return false;
    }
    if (std.mem.eql(u8, name, "wq")) {
        _ = saveFile(fname);
        return false;
    }
    if (std.mem.eql(u8, name, "x")) {
        if (modified or noeol) _ = saveFile(fname);
        return false;
    }
    if (std.mem.eql(u8, name, "w")) {
        if (readonly and !force) {
            setMsg("E45: 'readonly' option is set (add ! to override)", .{});
            return true;
        }
        if (saveFile(fname)) setMsg("\"{s}\" {d}L written", .{ fname, nlines });
        return true;
    }
    if (std.mem.startsWith(u8, name, "w ")) {
        const rest = std.mem.trim(u8, name[2..], " \t");
        if (rest.len > 0) fname = u.alloc.dupe(u8, rest) catch fname;
        if (saveFile(fname)) setMsg("\"{s}\" {d}L written", .{ fname, nlines });
        return true;
    }
    if (std.mem.startsWith(u8, name, "e")) {
        const rest = std.mem.trim(u8, name[1..], " \t");
        if (modified and !force) {
            setMsg("E37: No write since last change (add ! to override)", .{});
            return true;
        }
        if (rest.len > 0) fname = u.alloc.dupe(u8, rest) catch fname;
        for (lines[0..nlines]) |l| u.alloc.free(l);
        nlines = 0;
        top = 0;
        cur = 0;
        col = 0;
        modified = false;
        noeol = false;
        if (!loadFile(fname)) {
            ensureBuffer();
            setMsg("\"{s}\" [New File]", .{fname});
        }
        mGotoLine(1);
        return true;
    }
    if (std.mem.startsWith(u8, name, "set")) {
        const rest = std.mem.trim(u8, name[3..], " \t");
        if (rest.len == 0) setMsg("(options not supported in this build)", .{}) else setMsg("E518: Unknown option: {s}", .{rest});
        return true;
    }
    if (std.mem.eql(u8, name, "help")) {
        setMsg("w/w FILE/q/q!/wq/x/e FILE/N/set/help", .{});
        return true;
    }
    setMsg("E492: Not an editor command: {s}", .{name});
    return true;
}

// ---------- insert mode ----------
fn insertSession(how: u8) void {
    inserting = true;
    defer inserting = false;
    switch (how) {
        'i' => {},
        'a' => {
            if (lines[cur].len > 0) col += 1;
        },
        'I' => mFirstNonBlank(),
        'A' => col = lines[cur].len,
        'o' => {
            splitLine(cur, lines[cur].len);
            cur += 1;
            col = 0;
        },
        'O' => {
            splitLine(cur, 0);
            col = 0;
        },
        else => {},
    }
    while (true) {
        render();
        const c = readByte();
        if (c == 0x1b) {
            var seq: [8]u8 = undefined;
            const n = readSeq(&seq);
            if (n == 0) break; // plain ESC: back to normal mode
            if (seq[0] == '[' and n >= 2) { // arrows stay in insert mode
                switch (seq[1]) {
                    'A' => mUp(1),
                    'B' => mDown(1),
                    'C' => {
                        if (col < lines[cur].len) col += 1;
                    },
                    'D' => mLeft(1),
                    else => {},
                }
                continue;
            }
            break;
        }
        switch (c) {
            '\r', '\n' => {
                splitLine(cur, col);
                cur += 1;
                col = 0;
            },
            0x7f, 0x08 => {
                if (col > 0) {
                    col -= 1;
                    deleteChar(cur, col);
                } else if (cur > 0) {
                    // join with the previous line; cursor lands at the junction
                    const prev_len = lines[cur - 1].len;
                    const m = joinRange(cur - 1, cur, "");
                    setLine(cur - 1, m);
                    u.alloc.free(m);
                    removeLine(cur);
                    cur -= 1;
                    col = prev_len;
                }
                if (lines[cur].len == 0) col = 0 else if (col > lines[cur].len) col = lines[cur].len;
            },
            0x17 => { // Ctrl-W: delete the word before the cursor
                if (col > 0) {
                    var ci = col;
                    while (ci > 0 and isBlank(lines[cur][ci - 1])) ci -= 1;
                    if (ci > 0 and isWordChar(lines[cur][ci - 1])) {
                        while (ci > 0 and isWordChar(lines[cur][ci - 1])) ci -= 1;
                    } else while (ci > 0 and !isWordChar(lines[cur][ci - 1]) and !isBlank(lines[cur][ci - 1])) ci -= 1;
                    deleteRange(cur, ci, cur, col, false);
                    col = ci;
                }
            },
            0x03, 0x1a => break, // Ctrl-C / Ctrl-Z
            '\t' => {
                insertChar(cur, col, '\t');
                col += 1;
            },
            else => {
                if (c >= 0x20) {
                    insertChar(cur, col, c);
                    col += 1;
                }
            },
        }
    }
    clampCol();
    modified = true;
}

// ---------- normal mode ----------
fn doOperation(op: u8, motion: u8, count: usize) void {
    if (motion == op) { // doubled operator: dd / yy / cc (linewise)
        const n = @max(@as(usize, 1), count);
        const l2 = @min(cur + n - 1, nlines - 1);
        switch (op) {
            'd' => {
                pushUndo();
                deleteRange(cur, 0, l2, 0, true);
            },
            'y' => setYank(joinRange(cur, l2, "\n"), true),
            'c' => {
                pushUndo();
                setLine(cur, "");
                var i = cur + 1;
                while (i <= l2) : (i += 1) removeLine(cur + 1);
                col = 0;
                modified = true;
                insertSession('i');
            },
            else => {},
        }
        return;
    }
    // vi special case: cw behaves like ce (keeps trailing whitespace)
    const eff_motion: u8 = if (op == 'c' and motion == 'w') 'e' else motion;
    const t = opTarget(eff_motion, count);
    const a = Pos{ .l = cur, .c = col };
    var b = t.p;
    // dw before the last word clamps to end of line
    if (motion == 'w' and (b.l > cur or b.c == col)) b = .{ .l = cur, .c = lines[cur].len };
    switch (op) {
        'd' => {
            pushUndo();
            deleteRange(a.l, a.c, b.l, b.c, t.line_motion);
        },
        'y' => setYank(copyRange(a.l, a.c, b.l, b.c, t.line_motion), t.line_motion),
        'c' => {
            pushUndo();
            if (t.line_motion) {
                // cG / cgg clear the lines
                var li2 = a.l;
                while (li2 <= b.l) : (li2 += 1) setLine(li2, "");
                var li3 = a.l + 1;
                while (li3 <= b.l) : (li3 += 1) removeLine(a.l + 1);
                col = 0;
                modified = true;
                insertSession('i');
            } else {
                deleteRange(a.l, a.c, b.l, b.c, false);
                if (cur >= nlines) cur = nlines - 1;
                clampCol();
                insertSession('i');
            }
        },
        else => {},
    }
}

fn normalKey(c: u8, count: usize) bool { // false = quit the editor
    const n = @max(@as(usize, 1), count);
    switch (c) {
        'h', 0x08 => mLeft(n),
        'l', ' ' => mRight(n),
        'j' => mDown(n),
        'k' => mUp(n),
        '0' => mLineStart(),
        '$' => mLineEnd(),
        '^' => mFirstNonBlank(),
        'w' => mWordFwd(n),
        'e' => mWordEnd(n),
        'b' => mWordBack(n),
        'G' => mGotoLine(count), // no count: last line
        'g' => {
            const k = readByte();
            if (k == 'g') mGotoLine(if (count == 0) 1 else count) else setMsg("not supported", .{});
        },
        0x06 => mPageFwd(), // Ctrl-F
        0x02 => mPageBack(), // Ctrl-B
        0x04 => mHalfFwd(), // Ctrl-D
        0x15 => mHalfBack(), // Ctrl-U
        'x' => {
            pushUndo();
            var k: usize = 0;
            while (k < n) : (k += 1) {
                if (lines[cur].len == 0 or col >= lines[cur].len) break;
                setYank(copyRange(cur, col, cur, col + 1, false), false);
                deleteChar(cur, col);
            }
            modified = true;
            clampCol();
        },
        'X' => {
            if (col > 0) {
                pushUndo();
                var k: usize = 0;
                while (k < n and col > 0) : (k += 1) {
                    col -= 1;
                    setYank(copyRange(cur, col, cur, col + 1, false), false);
                    deleteChar(cur, col);
                }
                modified = true;
            }
        },
        's' => {
            pushUndo();
            if (lines[cur].len > 0 and col < lines[cur].len) {
                setYank(copyRange(cur, col, cur, col + 1, false), false);
                deleteChar(cur, col);
            }
            insertSession('i');
        },
        'D' => {
            pushUndo();
            deleteRange(cur, col, cur, lines[cur].len, false);
        },
        'C' => {
            pushUndo();
            deleteRange(cur, col, cur, lines[cur].len, false);
            insertSession('i');
        },
        'S' => {
            pushUndo();
            setLine(cur, "");
            col = 0;
            modified = true;
            insertSession('i');
        },
        'r' => {
            const k = readByte();
            if (k != 0x1b and lines[cur].len > 0 and col < lines[cur].len) {
                pushUndo();
                lines[cur][col] = k;
                modified = true;
            }
        },
        '~' => {
            if (col < lines[cur].len) {
                pushUndo();
                const ch = lines[cur][col];
                lines[cur][col] = if (ch >= 'a' and ch <= 'z') ch - 32 else if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
                if (col + 1 < lines[cur].len) col += 1;
                modified = true;
            }
        },
        'J' => {
            if (cur + 1 < nlines) {
                pushUndo();
                const next = lines[cur + 1];
                var sep: []const u8 = " ";
                if (next.len == 0 or isBlank(next[0]) or next[0] == ')') sep = "";
                const joined_len = lines[cur].len + sep.len + lines[cur + 1].len;
                if (joined_len > 0) {
                    const m = joinRange(cur, cur + 1, sep);
                    setLine(cur, m);
                    u.alloc.free(m);
                } else setLine(cur, "");
                removeLine(cur + 1);
                modified = true;
                clampCol();
            }
        },
        'd', 'y', 'c' => {
            const k = readByte();
            if (k == c) {
                doOperation(c, c, count);
            } else if (k == 'g') {
                const k2 = readByte();
                if (k2 == 'g') doOperation(c, 'g', count) else setMsg("not supported", .{});
            } else switch (k) {
                'w', 'e', 'b', '$', '0', '^', 'G' => doOperation(c, k, count),
                'i' => setMsg("(inner text objects not supported)", .{}),
                else => setMsg("not supported", .{}),
            }
        },
        'p' => {
            pushUndo();
            paste(true, n);
        },
        'P' => {
            pushUndo();
            paste(false, n);
        },
        'i' => {
            pushUndo();
            insertSession('i');
        },
        'a' => {
            pushUndo();
            insertSession('a');
        },
        'I' => {
            pushUndo();
            insertSession('I');
        },
        'A' => {
            pushUndo();
            insertSession('A');
        },
        'o' => {
            pushUndo();
            insertSession('o');
        },
        'O' => {
            pushUndo();
            insertSession('O');
        },
        'u' => {
            if (undo_n > 0) {
                const s = undo_stack[undo_n - 1];
                undo_n -= 1;
                pushRedo();
                snapApply(s);
            } else setMsg("Already at oldest change", .{});
        },
        0x12 => { // Ctrl-R
            if (redo_n > 0) {
                const s = redo_stack[redo_n - 1];
                redo_n -= 1;
                pushUndo();
                snapApply(s);
            } else setMsg("Already at newest change", .{});
        },
        'n' => doSearch("", search_back),
        'N' => doSearch("", !search_back),
        '/' => {
            if (promptLoop("/")) |pat| doSearch(pat, false);
        },
        '?' => {
            if (promptLoop("?")) |pat| doSearch(pat, true);
        },
        ':' => {
            if (promptLoop(":")) |cmd| {
                if (!exCommand(cmd)) return false;
            }
        },
        'Z' => {
            const k = readByte();
            if (k == 'Z') {
                if (modified or noeol) _ = saveFile(fname);
                return false;
            }
            if (k == 'Q') {
                if (modified and !readonly) {
                    setMsg("E37: No write since last change", .{});
                    return true;
                }
                return false;
            }
        },
        0x03, 0x1a, 0x00 => {}, // Ctrl-C / Ctrl-Z / NUL: ignored
        else => {},
    }
    if (msg.len > 0 and c != ':' and c != '/' and c != '?') msg = "";
    return true;
}

// ---------- main ----------
pub fn run(args: []const []const u8) u8 {
    if (!isTty()) {
        u.errf("vi: standard input is not a tty\n", .{});
        return 1;
    }
    var file_arg: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-R") or std.mem.eql(u8, arg, "--readonly") or std.mem.eql(u8, arg, "-Z")) {
            readonly = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            if (i < args.len) file_arg = args[i];
            break;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            u.errf("vi: unsupported option: {s}\n", .{arg});
            return 1;
        } else {
            file_arg = arg;
            break;
        }
    }
    if (file_arg) |path| {
        fname = u.alloc.dupe(u8, path) catch path;
        if (!loadFile(path)) {
            if (u.stat(path, false) != null) {
                u.errf("vi: {s}: cannot open\n", .{path});
                return 1;
            }
            setMsg("\"{s}\" [New File]", .{path});
        }
    } else {
        fname = "";
        setMsg("[No file]", .{});
    }
    ensureBuffer();
    mGotoLine(1);

    if (!rawOn()) {
        u.errf("vi: cannot set terminal mode\n", .{});
        return 1;
    }
    defer rawOff();

    u.out("\x1b[?25l\x1b[2J");
    defer u.out("\r\x1b[K\x1b[?25h");

    var count: usize = 0;
    while (true) {
        querySize();
        render();
        const c = readByte();
        if (c >= '1' and c <= '9') {
            count = count * 10 + (c - '0');
            continue;
        }
        const keep = count;
        count = 0;
        if (c == 0x1b) {
            var seq: [8]u8 = undefined;
            const sn = readSeq(&seq);
            if (sn >= 2 and seq[0] == '[') {
                switch (seq[1]) {
                    'A' => mUp(keep),
                    'B' => mDown(keep),
                    'C' => mRight(keep),
                    'D' => mLeft(keep),
                    'H' => mLineStart(),
                    'F' => mLineEnd(),
                    '1' => if (sn >= 3 and seq[2] == '~') mLineStart(),
                    '4' => if (sn >= 3 and seq[2] == '~') mLineEnd(),
                    '3' => if (sn >= 3 and seq[2] == '~') { // Delete = x
                        if (!normalKey('x', keep)) break;
                    },
                    '5' => mPageBack(), // PgUp
                    '6' => mPageFwd(), // PgDn
                    else => {},
                }
            }
            continue; // plain ESC: no-op in normal mode
        }
        if (!normalKey(c, keep)) break;
    }
    return 0;
}

fn isTty() bool {
    var t: [64]u8 = undefined;
    return u.ok(linux.ioctl(0, TCGETS, @intFromPtr(&t)));
}
