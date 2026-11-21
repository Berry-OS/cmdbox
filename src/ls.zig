// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// ls - GNU coreutils ls(1): all formats (-1 -C -x -m -l), sorting, quoting, indicators, colors, time styles
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const color = @import("color.zig");
const dt = @import("datetime.zig");
const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("grp.h");
    @cInclude("fnmatch.h");
});

const Format = enum { many_per_line, horizontal, commas, long, single };
const SortKey = enum { name, size, time, version, extension, none };
const TimeKind = enum { mtime, atime, ctime };
const Quoting = enum { literal, shell, shell_always, shell_escape, shell_escape_always, c, escape, locale };
const Indicator = enum { none, slash, file_type, classify };
const Deref = enum { undefined, never, command_line, command_line_dir, always };

const Opts = struct {
    format: Format = .single,
    sort: SortKey = .name,
    time: TimeKind = .mtime,
    reverse: bool = false,
    all: bool = false,
    almost: bool = false,
    ignore_backups: bool = false,
    directory: bool = false,
    recursive: bool = false,
    inode: bool = false,
    size: bool = false,
    numeric: bool = false,
    no_owner: bool = false,
    no_group: bool = false,
    author: bool = false,
    context: bool = false,
    human: u8 = 0, // 'h' 1024, 'H' 1000
    block_size: u64 = 1024,
    indicator: Indicator = .none,
    deref: Deref = .undefined,
    group_dirs: bool = false,
    color_on: bool = false,
    quoting: Quoting = .literal,
    hide_ctl: bool = false,
    show_ctl: bool = false,
    time_style: []const u8 = "locale",
    tabsize: usize = 8,
    width: usize = 80,
    zero: bool = false,
    no_sort_f: bool = false,
};

var opts = Opts{};
var hide_pats = u.Vec([]const u8).init(u.alloc);
var ignore_pats = u.Vec([]const u8).init(u.alloc);
var now_sec: i64 = 0;
var now_nsec: i64 = 0;
var color_started = false;
var exit_status: u8 = 0;
var out_buf = u.Vec(u8).init(u.alloc);

const Ent = struct {
    name: []const u8, // as displayed
    path: []const u8, // for stat / recursion
    st: u.Stat = undefined,
    have_st: bool = false,
    is_dir: bool = false,
    link_target: ?[]const u8 = null,
};

fn flush() void {
    if (out_buf.items.len > 0) {
        u.out(out_buf.items);
        out_buf.items.len = 0;
    }
}

fn emit(s: []const u8) void {
    out_buf.pushSlice(s);
    if (out_buf.items.len > 1 << 16) flush();
}

fn emitFmt(comptime fmt: []const u8, args: anytype) void {
    var tmp: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, fmt, args) catch return;
    emit(s);
}

fn spaces(n: usize) void {
    out_buf.pushN(' ', n);
}

// ---------- names, quoting ----------
fn needsShellQuote(name: []const u8) bool {
    if (name.len == 0) return true;
    for (name, 0..) |ch, i| {
        if (ch < 0x20 or ch == 0x7f) return true;
        switch (ch) {
            ' ', '!', '"', '$', '&', '\'', '(', ')', '*', ';', '<', '>', '?', '[', '\\', '^', '`', '{', '|', '}' => return true,
            '#', '~', '=' => if (i == 0) return true,
            else => {},
        }
    }
    return false;
}

fn hasCtl(name: []const u8) bool {
    for (name) |ch| if (ch < 0x20 or ch == 0x7f) return true;
    return false;
}

fn quoteName(name: []const u8, o: *u.Vec(u8)) void {
    switch (opts.quoting) {
        .literal => {
            if (opts.hide_ctl) {
                for (name) |ch| o.push(if (ch < 0x20 or ch == 0x7f) '?' else ch);
            } else o.pushSlice(name);
        },
        .shell, .shell_always, .shell_escape, .shell_escape_always => {
            const always = opts.quoting == .shell_always or opts.quoting == .shell_escape_always;
            const esc = opts.quoting == .shell_escape or opts.quoting == .shell_escape_always;
            if (esc and hasCtl(name)) {
                o.pushSlice("$'");
                for (name) |ch| escapeChar(ch, o, false);
                o.push('\'');
                return;
            }
            if (!always and !needsShellQuote(name)) {
                if (opts.hide_ctl) {
                    for (name) |ch| o.push(if (ch < 0x20 or ch == 0x7f) '?' else ch);
                } else o.pushSlice(name);
                return;
            }
            o.push('\'');
            for (name) |ch| {
                if (ch == '\'') o.pushSlice("'\\''") else if (opts.hide_ctl and (ch < 0x20 or ch == 0x7f)) o.push('?') else o.push(ch);
            }
            o.push('\'');
        },
        .c => {
            o.push('"');
            for (name) |ch| escapeChar(ch, o, true);
            o.push('"');
        },
        .escape => {
            for (name) |ch| escapeChar(ch, o, false);
        },
        .locale => {
            o.pushSlice("'");
            for (name) |ch| escapeChar(ch, o, false);
            o.pushSlice("'");
        },
    }
}

fn escapeChar(ch: u8, o: *u.Vec(u8), dq: bool) void {
    switch (ch) {
        7 => o.pushSlice("\\a"),
        8 => o.pushSlice("\\b"),
        9 => o.pushSlice("\\t"),
        10 => o.pushSlice("\\n"),
        11 => o.pushSlice("\\v"),
        12 => o.pushSlice("\\f"),
        13 => o.pushSlice("\\r"),
        '\\' => o.pushSlice("\\\\"),
        '"' => if (dq) o.pushSlice("\\\"") else o.push('"'),
        ' ' => if (opts.quoting == .escape) o.pushSlice("\\ ") else o.push(' '),
        else => {
            if (ch < 0x20 or ch == 0x7f) {
                var tmp: [4]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "\\{o:0>3}", .{ch}) catch return;
                o.pushSlice(s);
            } else o.push(ch);
        },
    }
}

fn displayLen(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn indicatorChar(e: *const Ent) u8 {
    if (opts.indicator == .none) return 0;
    const mode = e.st.mode;
    const t = mode & linux.S.IFMT;
    if (t == linux.S.IFDIR) return '/';
    if (opts.indicator == .slash) return 0;
    if (t == linux.S.IFLNK) return '@';
    if (t == linux.S.IFIFO) return '|';
    if (t == linux.S.IFSOCK) return '=';
    if (opts.indicator == .classify and t == linux.S.IFREG and mode & 0o111 != 0) return '*';
    return 0;
}

fn quotedName(e: *const Ent) []const u8 {
    var o = u.Vec(u8).init(u.alloc);
    quoteName(e.name, &o);
    return o.items;
}

// ---------- numbers / sizes ----------
fn humanSize(n: u64, o: *u.Vec(u8), base: u64) void {
    const sfx_b = [_][]const u8{ "", "K", "M", "G", "T", "P", "E", "Z", "Y" };
    const sfx_s = [_][]const u8{ "", "k", "M", "G", "T", "P", "E", "Z", "Y" };
    var e: usize = 0;
    var pw: u128 = 1;
    while (e < 8 and n >= pw * base) : (e += 1) pw *= base;
    var tmp: [64]u8 = undefined;
    if (e == 0) {
        const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return;
        o.pushSlice(s);
        return;
    }
    var tenths = (@as(u128, n) * 10 + pw - 1) / pw;
    if (tenths >= base * 10 and e < 8) {
        e += 1;
        pw *= base;
        tenths = (@as(u128, n) * 10 + pw - 1) / pw;
    }
    const sfx = if (base == 1000) sfx_s[e] else sfx_b[e];
    const s = if (tenths < 100)
        std.fmt.bufPrint(&tmp, "{d}.{d}{s}", .{ tenths / 10, tenths % 10, sfx }) catch return
    else
        std.fmt.bufPrint(&tmp, "{d}{s}", .{ (@as(u128, n) + pw - 1) / pw, sfx }) catch return;
    o.pushSlice(s);
}

fn sizeText(bytes: u64) []const u8 {
    var o = u.Vec(u8).init(u.alloc);
    if (opts.human != 0) {
        humanSize(bytes, &o, if (opts.human == 'H') 1000 else 1024);
    } else {
        var tmp: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{bytes}) catch "";
        o.pushSlice(s);
    }
    return o.items;
}

fn blocksText(st: u.Stat) []const u8 {
    const bytes = st.blocks * 512;
    var o = u.Vec(u8).init(u.alloc);
    if (opts.human != 0) {
        humanSize(bytes, &o, if (opts.human == 'H') 1000 else 1024);
    } else {
        var tmp: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{(bytes + opts.block_size - 1) / opts.block_size}) catch "";
        o.pushSlice(s);
    }
    return o.items;
}

fn userName(uid: u32) []const u8 {
    if (!opts.numeric) if (c.getpwuid(uid)) |p| return std.mem.sliceTo(p.*.pw_name, 0);
    return std.fmt.allocPrint(u.alloc, "{d}", .{uid}) catch "?";
}

fn groupName(gid: u32) []const u8 {
    if (!opts.numeric) if (c.getgrgid(gid)) |p| return std.mem.sliceTo(p.*.gr_name, 0);
    return std.fmt.allocPrint(u.alloc, "{d}", .{gid}) catch "?";
}

fn hasXattr(path: []const u8, name: [:0]const u8) bool {
    const rc = linux.syscall4(.lgetxattr, @intFromPtr(u.zstr(path).ptr), @intFromPtr(name.ptr), 0, 0);
    return u.ok(rc);
}

fn modeString(e: *const Ent) [11]u8 {
    const mode = e.st.mode;
    var r: [11]u8 = .{ '-', '-', '-', '-', '-', '-', '-', '-', '-', '-', ' ' };
    r[0] = switch (mode & linux.S.IFMT) {
        linux.S.IFDIR => 'd',
        linux.S.IFLNK => 'l',
        linux.S.IFIFO => 'p',
        linux.S.IFSOCK => 's',
        linux.S.IFCHR => 'c',
        linux.S.IFBLK => 'b',
        else => '-',
    };
    const letters = "rwxrwxrwx";
    for (letters, 0..) |l, i| if (mode & (@as(u32, 0o400) >> @as(u5, @intCast(i))) != 0) {
        r[i + 1] = l;
    };
    if (mode & 0o4000 != 0) r[3] = if (mode & 0o100 != 0) 's' else 'S';
    if (mode & 0o2000 != 0) r[6] = if (mode & 0o010 != 0) 's' else 'S';
    if (mode & 0o1000 != 0) r[9] = if (mode & 0o001 != 0) 't' else 'T';
    return r;
}

fn aclFlag(e: *const Ent) u8 {
    if (e.st.mode & linux.S.IFMT == linux.S.IFLNK) return ' ';
    if (hasXattr(e.path, "system.posix_acl_access")) return '+';
    if (hasXattr(e.path, "security.selinux")) return '.';
    return ' ';
}

fn timeOf(st: u.Stat) dt.Ts {
    return switch (opts.time) {
        .mtime => .{ .sec = st.mtime, .nsec = st.mtime_nsec },
        .atime => .{ .sec = st.atime, .nsec = st.atime_nsec },
        .ctime => .{ .sec = st.ctime, .nsec = st.ctime_nsec },
    };
}

fn timeText(st: u.Stat) []const u8 {
    const ts = timeOf(st);
    const tm = dt.localtime(ts.sec);
    const six: i64 = 31556952 / 2;
    const after_six = ts.sec > now_sec - six or (ts.sec == now_sec - six and ts.nsec >= now_nsec);
    const not_future = ts.sec < now_sec or (ts.sec == now_sec and ts.nsec <= now_nsec);
    const recent = after_six and not_future;
    var fmt: []const u8 = undefined;
    var fmt_old: []const u8 = undefined;
    const style = opts.time_style;
    if (std.mem.eql(u8, style, "full-iso")) {
        fmt = "%Y-%m-%d %H:%M:%S.%N %z";
        fmt_old = fmt;
    } else if (std.mem.eql(u8, style, "long-iso")) {
        fmt = "%Y-%m-%d %H:%M";
        fmt_old = fmt;
    } else if (std.mem.eql(u8, style, "iso")) {
        fmt = "%m-%d %H:%M";
        fmt_old = "%Y-%m-%d ";
    } else if (style.len > 0 and style[0] == '+') {
        const body = style[1..];
        if (std.mem.indexOfScalar(u8, body, '\n')) |nl| {
            fmt_old = body[0..nl];
            fmt = body[nl + 1 ..];
        } else {
            fmt = body;
            fmt_old = body;
        }
    } else {
        fmt = "%b %e %H:%M";
        fmt_old = "%b %e  %Y";
    }
    var o = u.Vec(u8).init(u.alloc);
    dt.format(if (recent) fmt else fmt_old, ts, &tm, &o);
    return o.items;
}

// ---------- sorting ----------
fn cmpVersion(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            var si = i;
            while (si < a.len and a[si] == '0') si += 1;
            var sj = j;
            while (sj < b.len and b[sj] == '0') sj += 1;
            var ei = si;
            while (ei < a.len and std.ascii.isDigit(a[ei])) ei += 1;
            var ej = sj;
            while (ej < b.len and std.ascii.isDigit(b[ej])) ej += 1;
            const la = ei - si;
            const lb = ej - sj;
            if (la != lb) return std.math.order(la, lb);
            const o = std.mem.order(u8, a[si..ei], b[sj..ej]);
            if (o != .eq) return o;
            const zi = si - i;
            const zj = sj - j;
            if (zi != zj) return std.math.order(zj, zi);
            i = ei;
            j = ej;
        } else {
            if (a[i] != b[j]) return std.math.order(a[i], b[j]);
            i += 1;
            j += 1;
        }
    }
    return std.math.order(a.len - i, b.len - j);
}

fn extOf(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |d| {
        if (d > 0) return name[d..];
    }
    return "";
}

fn lessEnt(_: void, a: Ent, b: Ent) bool {
    if (opts.group_dirs) {
        if (a.is_dir != b.is_dir) return a.is_dir;
    }
    var ord: std.math.Order = .eq;
    switch (opts.sort) {
        .size => ord = std.math.order(b.st.size, a.st.size),
        .time => {
            const ta = timeOf(a.st);
            const tb = timeOf(b.st);
            ord = std.math.order(tb.sec, ta.sec);
            if (ord == .eq) ord = std.math.order(tb.nsec, ta.nsec);
        },
        .version => ord = cmpVersion(a.name, b.name),
        .extension => {
            ord = std.mem.order(u8, extOf(a.name), extOf(b.name));
        },
        else => {},
    }
    if (ord == .eq) ord = std.mem.order(u8, a.name, b.name);
    if (opts.reverse) return ord == .gt;
    return ord == .lt;
}

fn sortEnts(items: []Ent) void {
    if (opts.sort == .none and !opts.group_dirs) {
        if (opts.reverse) std.mem.reverse(Ent, items);
        return;
    }
    if (opts.sort == .none) {
        // keep directory order, only group directories first
        var dirs = u.Vec(Ent).init(u.alloc);
        var rest = u.Vec(Ent).init(u.alloc);
        for (items) |e| if (e.is_dir) dirs.push(e) else rest.push(e);
        var k: usize = 0;
        for (dirs.items) |e| {
            items[k] = e;
            k += 1;
        }
        for (rest.items) |e| {
            items[k] = e;
            k += 1;
        }
        return;
    }
    std.mem.sort(Ent, items, {}, lessEnt);
}

// ---------- printing ----------
const Cols = struct { inode: usize = 0, blocks: usize = 0, nlink: usize = 0, owner: usize = 0, group: usize = 0, author: usize = 0, ctx: usize = 0, size: usize = 0 };

fn colorStart(e: *const Ent) bool {
    if (!opts.color_on) return false;
    const code = color.lsCode(e.path, e.name, e.st) orelse return false;
    if (!color_started) {
        flush();
        color.lsEnd();
        color_started = true;
    }
    return startCode(code);
}

fn startCode(code: []const u8) bool {
    flush();
    _ = color.lsStart(code);
    return true;
}

fn endCode() void {
    flush();
    color.lsEnd();
}

/// print the (quoted, colored) name followed by the type indicator; returns display width
fn printName(e: *const Ent, with_ind: bool) usize {
    const q = quotedName(e);
    var w = displayLen(q);
    const colored = colorStart(e);
    emit(q);
    if (colored) endCode();
    if (with_ind) {
        const ind = indicatorChar(e);
        if (ind != 0) {
            emit(&[_]u8{ind});
            w += 1;
        }
    }
    return w;
}

fn frills(e: *const Ent, cols: *const Cols) usize {
    var w: usize = 0;
    if (opts.inode) w += cols.inode + 1;
    if (opts.size) w += cols.blocks + 1;
    _ = e;
    return w;
}

fn nameWidth(e: *const Ent) usize {
    var w = displayLen(quotedName(e));
    if (indicatorChar(e) != 0) w += 1;
    return w;
}

fn numText(v: u64) []const u8 {
    return std.fmt.allocPrint(u.alloc, "{d}", .{v}) catch "";
}

fn padL(s: []const u8, w: usize) void {
    if (s.len < w) spaces(w - s.len);
    emit(s);
}

fn padR(s: []const u8, w: usize) void {
    emit(s);
    if (s.len < w) spaces(w - s.len);
}

fn computeCols(ents: []const Ent) Cols {
    var cw = Cols{};
    for (ents) |*e| {
        cw.inode = @max(cw.inode, numText(e.st.ino).len);
        cw.blocks = @max(cw.blocks, blocksText(e.st).len);
        if (opts.format == .long) {
            cw.nlink = @max(cw.nlink, numText(e.st.nlink).len);
            cw.owner = @max(cw.owner, userName(e.st.uid).len);
            cw.group = @max(cw.group, groupName(e.st.gid).len);
            cw.author = cw.owner;
            cw.ctx = 1;
            const t = e.st.mode & linux.S.IFMT;
            const sl = if (t == linux.S.IFCHR or t == linux.S.IFBLK) 0 else sizeText(e.st.size).len;
            cw.size = @max(cw.size, sl);
        }
    }
    if (opts.format == .long) {
        // device numbers "major, minor" share the size column
        for (ents) |*e| {
            const t = e.st.mode & linux.S.IFMT;
            if (t == linux.S.IFCHR or t == linux.S.IFBLK) {
                const mm = devText(e.st.rdev);
                cw.size = @max(cw.size, mm.len);
            }
        }
    }
    return cw;
}

fn devMajor(rdev: u64) u64 {
    return ((rdev >> 8) & 0xfff) | ((rdev >> 32) & ~@as(u64, 0xfff));
}
fn devMinor(rdev: u64) u64 {
    return (rdev & 0xff) | ((rdev >> 12) & ~@as(u64, 0xff));
}
fn devText(rdev: u64) []const u8 {
    return std.fmt.allocPrint(u.alloc, "{d}, {d}", .{ devMajor(rdev), devMinor(rdev) }) catch "";
}

fn printLong(e: *const Ent, cw: *const Cols) void {
    if (opts.inode) {
        padL(numText(e.st.ino), cw.inode);
        emit(" ");
    }
    if (opts.size) {
        padL(blocksText(e.st), cw.blocks);
        emit(" ");
    }
    const ms = modeString(e);
    emit(ms[0..10]);
    const acl = aclFlag(e);
    if (acl != ' ') emit(&[_]u8{acl}) else emit(" ");
    padL(numText(e.st.nlink), cw.nlink);
    emit(" ");
    if (!opts.no_owner) {
        padR(userName(e.st.uid), cw.owner);
        emit(" ");
    }
    if (!opts.no_group) {
        padR(groupName(e.st.gid), cw.group);
        emit(" ");
    }
    if (opts.author) {
        padR(userName(e.st.uid), cw.author);
        emit(" ");
    }
    if (opts.context) {
        emit("? ");
    }
    const t = e.st.mode & linux.S.IFMT;
    if (t == linux.S.IFCHR or t == linux.S.IFBLK) {
        padL(devText(e.st.rdev), cw.size);
    } else padL(sizeText(e.st.size), cw.size);
    emit(" ");
    emit(timeText(e.st));
    emit(" ");
    _ = printName(e, true);
    if (e.link_target) |tgt| {
        // GNU ls colors and annotates only the link name; the target is
        // printed as plain text, even when it is a directory or an orphan.
        emit(" -> ");
        var o = u.Vec(u8).init(u.alloc);
        quoteName(tgt, &o);
        emit(o.items);
    }
    emit(if (opts.zero) "\x00" else "\n");
}

fn printShort(ents: []const Ent, cw: *const Cols) void {
    const n = ents.len;
    if (n == 0) return;
    const term: []const u8 = if (opts.zero) "\x00" else "\n";
    if (opts.format == .single or (opts.format == .many_per_line and opts.width == 1)) {
        for (ents) |*e| {
            frillPrint(e, cw);
            _ = printName(e, true);
            emit(term);
        }
        return;
    }
    if (opts.format == .commas) {
        var pos: usize = 0;
        for (ents, 0..) |*e, i| {
            const len = nameWidth(e) + frills(e, cw);
            if (i > 0) {
                if (opts.width != 0 and pos + len + 2 + 1 > opts.width) {
                    emit(",\n");
                    pos = 0;
                } else {
                    emit(", ");
                    pos += 2;
                }
            }
            frillPrint(e, cw);
            _ = printName(e, true);
            pos += len;
        }
        emit("\n");
        return;
    }
    // columns (vertical or horizontal)
    const line_len: usize = if (opts.width == 0) std.math.maxInt(usize) else opts.width;
    const min_col: usize = 3;
    var max_cols: usize = if (opts.width == 0) n else @max(1, @min(n, line_len / min_col));
    if (max_cols > n) max_cols = n;
    var lens = u.Vec(usize).init(u.alloc);
    for (ents) |*e| lens.push(nameWidth(e) + frills(e, cw));

    var best: usize = 1;
    var best_widths: []usize = &.{};
    var cols_n: usize = max_cols;
    while (cols_n >= 1) : (cols_n -= 1) {
        const widths = u.alloc.alloc(usize, cols_n) catch return;
        @memset(widths, min_col);
        var total: usize = cols_n * min_col;
        var valid = true;
        const rows = (n + cols_n - 1) / cols_n;
        for (lens.items, 0..) |l, f| {
            const idx = if (opts.format == .many_per_line) f / rows else f % cols_n;
            if (idx >= cols_n) {
                valid = false;
                break;
            }
            const real = l + (if (idx == cols_n - 1) @as(usize, 0) else 2);
            if (widths[idx] < real) {
                total += real - widths[idx];
                widths[idx] = real;
            }
            if (total >= line_len) {
                valid = false;
                break;
            }
        }
        if (valid) {
            best = cols_n;
            best_widths = widths;
            break;
        }
        if (cols_n == 1) break;
    }
    if (best_widths.len == 0) {
        const widths = u.alloc.alloc(usize, 1) catch return;
        widths[0] = 0;
        best_widths = widths;
        best = 1;
    }
    const rows = (n + best - 1) / best;
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        var pos: usize = 0;
        var col: usize = 0;
        while (col < best) : (col += 1) {
            const idx = if (opts.format == .many_per_line) col * rows + r else r * best + col;
            if (idx >= n) break;
            const e = &ents[idx];
            frillPrint(e, cw);
            const w = printName(e, true) + frills(e, cw);
            // next entry in this row?
            const next_idx = if (opts.format == .many_per_line) (col + 1) * rows + r else r * best + col + 1;
            if (col + 1 < best and next_idx < n) {
                const target = pos + best_widths[col];
                indent(pos + w, target);
                pos = target;
            }
        }
        emit("\n");
    }
}

fn indent(from_in: usize, to: usize) void {
    var from = from_in;
    while (from < to) {
        if (opts.tabsize != 0 and to / opts.tabsize > (from + 1) / opts.tabsize) {
            emit("\t");
            from += opts.tabsize - from % opts.tabsize;
        } else {
            emit(" ");
            from += 1;
        }
    }
}

fn frillPrint(e: *const Ent, cw: *const Cols) void {
    if (opts.inode) {
        padL(numText(e.st.ino), cw.inode);
        emit(" ");
    }
    if (opts.size) {
        padL(blocksText(e.st), cw.blocks);
        emit(" ");
    }
}

fn printEnts(ents: []Ent, total_line: bool) void {
    const cw = computeCols(ents);
    if (total_line and (opts.format == .long or opts.size)) {
        var blocks: u64 = 0;
        for (ents) |e| blocks += e.st.blocks;
        var o = u.Vec(u8).init(u.alloc);
        if (opts.human != 0) {
            humanSize(blocks * 512, &o, if (opts.human == 'H') 1000 else 1024);
        } else {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{(blocks * 512 + opts.block_size - 1) / opts.block_size}) catch "";
            o.pushSlice(s);
        }
        emit("total ");
        emit(o.items);
        emit("\n");
    }
    if (opts.format == .long) {
        for (ents) |*e| printLong(e, &cw);
    } else printShort(ents, &cw);
}

// ---------- reading ----------
fn matchAny(pats: []const []const u8, name: []const u8) bool {
    for (pats) |p| if (c.fnmatch(u.zstr(p).ptr, u.zstr(name).ptr, 0) == 0) return true;
    return false;
}

fn statEnt(e: *Ent, follow: bool) bool {
    const st = u.stat(e.path, follow) orelse return false;
    e.st = st;
    e.have_st = true;
    e.is_dir = st.mode & linux.S.IFMT == linux.S.IFDIR;
    if (st.mode & linux.S.IFMT == linux.S.IFLNK and (opts.format == .long or opts.indicator != .none or opts.color_on)) {
        var buf: [u.PATH_MAX]u8 = undefined;
        const rc = linux.readlink(u.zstr(e.path), &buf, buf.len);
        if (u.ok(rc)) {
            e.link_target = u.alloc.dupe(u8, buf[0..rc]) catch null;
        }
    }
    return true;
}

fn joinPath(dir: []const u8, name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, dir, "/")) return std.fmt.allocPrint(u.alloc, "{s}{s}", .{ dir, name }) catch name;
    return std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ dir, name }) catch name;
}

var visited = u.Vec(struct { dev: u64, ino: u64 }).init(u.alloc);

fn listDir(path: []const u8, header: bool, first: *bool) void {
    const dst = u.stat(path, true) orelse {
        u.errf("ls: cannot access '{s}': No such file or directory\n", .{path});
        exit_status = 2;
        return;
    };
    for (visited.items) |v| if (v.dev == dst.dev and v.ino == dst.ino) {
        u.errf("ls: {s}: not listing already-listed directory\n", .{path});
        exit_status = 2;
        return;
    };
    visited.push(.{ .dev = dst.dev, .ino = dst.ino });
    defer visited.pop();
    if (header) {
        if (!first.*) emit("\n");
        var o = u.Vec(u8).init(u.alloc);
        quoteName(path, &o);
        emit(o.items);
        emit(":\n");
    }
    first.* = false;
    var names = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir(path, &names)) {
        flush();
        u.errf("ls: cannot open directory '{s}': Permission denied\n", .{path});
        exit_status = 2;
        return;
    }
    var ents = u.Vec(Ent).init(u.alloc);
    if (opts.all) {
        for ([_][]const u8{ ".", ".." }) |dn| {
            var e = Ent{ .name = dn, .path = joinPath(path, dn) };
            if (statEnt(&e, opts.deref == .always)) ents.push(e);
        }
    }
    for (names.items) |dn| {
        const name: []const u8 = dn.name;
        if (!opts.all and !opts.almost and name[0] == '.') continue;
        if (opts.ignore_backups and name[name.len - 1] == '~') continue;
        if (!opts.all and !opts.almost and hide_pats.items.len > 0 and matchAny(hide_pats.items, name)) continue;
        if (ignore_pats.items.len > 0 and matchAny(ignore_pats.items, name)) continue;
        var e = Ent{ .name = name, .path = joinPath(path, name) };
        if (!statEnt(&e, opts.deref == .always)) {
            flush();
            u.errf("ls: cannot access '{s}': No such file or directory\n", .{e.path});
            exit_status = 2;
            continue;
        }
        ents.push(e);
    }
    if (!opts.no_sort_f) sortEnts(ents.items);
    printEnts(ents.items, true);
    if (opts.recursive) {
        for (ents.items) |e| {
            if (!e.is_dir) continue;
            if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
            // symlinks to directories are not followed in recursion unless -L
            if (opts.deref != .always) {
                const lst = u.stat(e.path, false) orelse continue;
                if (lst.mode & linux.S.IFMT == linux.S.IFLNK) continue;
            }
            listDir(e.path, true, first);
        }
    }
}

fn parseSizeArg(s: []const u8) ?u64 {
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    var mult: u64 = if (i > 0) (std.fmt.parseInt(u64, s[0..i], 10) catch return null) else 1;
    const sfx = s[i..];
    if (sfx.len > 0) {
        const idx = std.mem.indexOfScalar(u8, "KMGTPEZY", std.ascii.toUpper(sfx[0])) orelse return null;
        var b: u64 = 1024;
        if (sfx.len == 2 and sfx[1] == 'B') b = 1000 else if (sfx.len != 1 and !(sfx.len == 3 and std.mem.eql(u8, sfx[1..], "iB"))) return null;
        var k: usize = 0;
        while (k <= idx) : (k += 1) mult *%= b;
    }
    return if (mult == 0) null else mult;
}

fn quotingFromName(s: []const u8) ?Quoting {
    if (std.mem.eql(u8, s, "literal")) return .literal;
    if (std.mem.eql(u8, s, "shell")) return .shell;
    if (std.mem.eql(u8, s, "shell-always")) return .shell_always;
    if (std.mem.eql(u8, s, "shell-escape")) return .shell_escape;
    if (std.mem.eql(u8, s, "shell-escape-always")) return .shell_escape_always;
    if (std.mem.eql(u8, s, "c")) return .c;
    if (std.mem.eql(u8, s, "escape")) return .escape;
    if (std.mem.eql(u8, s, "locale") or std.mem.eql(u8, s, "clocale")) return .locale;
    return null;
}

fn isTty(fd: i32) bool {
    var t: [64]u8 = undefined;
    return u.ok(linux.ioctl(fd, 0x5401, @intFromPtr(&t)));
}

fn badArg(comptime what: []const u8, v: []const u8) u8 {
    u.errf("ls: invalid argument '{s}' for '--{s}'\nTry 'ls --help' for more information.\n", .{ v, what });
    return 2;
}

pub fn run(args: []const []const u8) u8 {
    opts = Opts{};
    hide_pats = u.Vec([]const u8).init(u.alloc);
    ignore_pats = u.Vec([]const u8).init(u.alloc);
    color_started = false;
    exit_status = 0;
    out_buf = u.Vec(u8).init(u.alloc);
    visited = .{ .a = u.alloc };
    {
        var tsp: linux.timespec = undefined;
        if (u.ok(linux.clock_gettime(.REALTIME, &tsp))) {
            now_sec = tsp.sec;
            now_nsec = tsp.nsec;
        } else now_sec = u.nowSecs();
    }
    const tty = isTty(1);

    const table = [_]g.Opt{
        .{ .name = "all", .key = 'a' },
        .{ .name = "almost-all", .key = 'A' },
        .{ .name = "author", .key = 130 },
        .{ .name = "escape", .key = 'b' },
        .{ .name = "block-size", .key = 131, .arg = .req },
        .{ .name = "ignore-backups", .key = 'B' },
        .{ .key = 'c' },
        .{ .key = 'C' },
        .{ .name = "color", .key = 132, .arg = .opt },
        .{ .name = "directory", .key = 'd' },
        .{ .name = "dired", .key = 'D' },
        .{ .key = 'f' },
        .{ .name = "classify", .key = 'F', .arg = .opt },
        .{ .name = "file-type", .key = 133 },
        .{ .name = "format", .key = 134, .arg = .req },
        .{ .name = "full-time", .key = 135 },
        .{ .key = 'g' },
        .{ .name = "group-directories-first", .key = 136 },
        .{ .name = "no-group", .key = 'G' },
        .{ .name = "human-readable", .key = 'h' },
        .{ .name = "si", .key = 137 },
        .{ .name = "dereference-command-line", .key = 'H' },
        .{ .name = "dereference-command-line-symlink-to-dir", .key = 138 },
        .{ .name = "hide", .key = 139, .arg = .req },
        .{ .name = "hyperlink", .key = 140, .arg = .opt },
        .{ .name = "indicator-style", .key = 141, .arg = .req },
        .{ .name = "inode", .key = 'i' },
        .{ .name = "ignore", .key = 'I', .arg = .req },
        .{ .name = "kibibytes", .key = 'k' },
        .{ .key = 'l' },
        .{ .name = "dereference", .key = 'L' },
        .{ .key = 'm' },
        .{ .name = "numeric-uid-gid", .key = 'n' },
        .{ .name = "literal", .key = 'N' },
        .{ .key = 'o' },
        .{ .key = 'p' },
        .{ .name = "hide-control-chars", .key = 'q' },
        .{ .name = "show-control-chars", .key = 142 },
        .{ .name = "quote-name", .key = 'Q' },
        .{ .name = "quoting-style", .key = 143, .arg = .req },
        .{ .name = "reverse", .key = 'r' },
        .{ .name = "recursive", .key = 'R' },
        .{ .name = "size", .key = 's' },
        .{ .key = 'S' },
        .{ .name = "sort", .key = 144, .arg = .req },
        .{ .name = "time", .key = 145, .arg = .req },
        .{ .name = "time-style", .key = 146, .arg = .req },
        .{ .key = 't' },
        .{ .name = "tabsize", .key = 'T', .arg = .req },
        .{ .key = 'u' },
        .{ .key = 'U' },
        .{ .key = 'v' },
        .{ .name = "width", .key = 'w', .arg = .req },
        .{ .key = 'x' },
        .{ .key = 'X' },
        .{ .name = "context", .key = 'Z' },
        .{ .name = "zero", .key = 147 },
        .{ .key = '1' },
        .{ .name = "help", .key = 200 },
        .{ .name = "version", .key = 201 },
    };
    var p = g.Parser.init("ls", args, &table);
    var format_set = false;
    var color_mode: color.Mode = .never;
    var width_set = false;
    var quoting_set = false;
    var long_flag = false;
    var time_style_arg: ?[]const u8 = null;
    var dired_ignored = false;
    _ = &dired_ignored;
    var hide_ctl_set = false;
    while (p.next() catch return 2) |it| {
        switch (it.key) {
            'a' => {
                opts.all = true;
                opts.almost = false;
            },
            'A' => opts.almost = true,
            130 => opts.author = true,
            'b' => {
                opts.quoting = .escape;
                quoting_set = true;
            },
            131 => opts.block_size = parseSizeArg(it.val.?) orelse {
                u.errf("ls: invalid --block-size argument '{s}'\n", .{it.val.?});
                return 2;
            },
            'B' => opts.ignore_backups = true,
            'c' => opts.time = .ctime,
            'C' => {
                opts.format = .many_per_line;
                format_set = true;
                long_flag = false;
            },
            132 => color_mode = if (it.val) |v| (color.parse(v) orelse return badArg("color", v)) else .always,
            'd' => opts.directory = true,
            'D' => {},
            'f' => {
                opts.all = true;
                opts.sort = .none;
                opts.no_sort_f = true;
                if (opts.format == .long and !format_set) {}
            },
            'F' => {
                if (it.val) |v| {
                    if (std.mem.eql(u8, v, "never") or std.mem.eql(u8, v, "no") or std.mem.eql(u8, v, "none")) {
                        opts.indicator = .none;
                    } else if (std.mem.eql(u8, v, "always") or std.mem.eql(u8, v, "yes") or std.mem.eql(u8, v, "force")) {
                        opts.indicator = .classify;
                    } else if (std.mem.eql(u8, v, "auto") or std.mem.eql(u8, v, "tty") or std.mem.eql(u8, v, "if-tty")) {
                        opts.indicator = if (tty) .classify else .none;
                    } else return badArg("classify", v);
                } else opts.indicator = .classify;
            },
            133 => opts.indicator = .file_type,
            134 => {
                const v = it.val.?;
                format_set = true;
                if (std.mem.eql(u8, v, "long") or std.mem.eql(u8, v, "verbose")) {
                    opts.format = .long;
                } else if (std.mem.eql(u8, v, "single-column")) {
                    opts.format = .single;
                } else if (std.mem.eql(u8, v, "across") or std.mem.eql(u8, v, "horizontal")) {
                    opts.format = .horizontal;
                } else if (std.mem.eql(u8, v, "commas")) {
                    opts.format = .commas;
                } else if (std.mem.eql(u8, v, "vertical")) {
                    opts.format = .many_per_line;
                } else return badArg("format", v);
            },
            135 => {
                opts.format = .long;
                format_set = true;
                time_style_arg = "full-iso";
            },
            'g' => {
                opts.format = .long;
                format_set = true;
                opts.no_owner = true;
            },
            136 => opts.group_dirs = true,
            'G' => opts.no_group = true,
            'h' => opts.human = 'h',
            137 => opts.human = 'H',
            'H' => opts.deref = .command_line,
            138 => opts.deref = .command_line_dir,
            139 => hide_pats.push(it.val.?),
            140 => {},
            141 => {
                const v = it.val.?;
                if (std.mem.eql(u8, v, "none")) opts.indicator = .none else if (std.mem.eql(u8, v, "slash")) opts.indicator = .slash else if (std.mem.eql(u8, v, "file-type")) opts.indicator = .file_type else if (std.mem.eql(u8, v, "classify")) opts.indicator = .classify else return badArg("indicator-style", v);
            },
            'i' => opts.inode = true,
            'I' => ignore_pats.push(it.val.?),
            'k' => {
                opts.block_size = 1024;
                opts.human = 0;
            },
            'l' => {
                opts.format = .long;
                format_set = true;
                long_flag = true;
            },
            'L' => opts.deref = .always,
            'm' => {
                opts.format = .commas;
                format_set = true;
            },
            'n' => {
                opts.format = .long;
                format_set = true;
                opts.numeric = true;
            },
            'N' => {
                opts.quoting = .literal;
                quoting_set = true;
            },
            'o' => {
                opts.format = .long;
                format_set = true;
                opts.no_group = true;
            },
            'p' => opts.indicator = .slash,
            'q' => {
                opts.hide_ctl = true;
                hide_ctl_set = true;
            },
            142 => {
                opts.show_ctl = true;
                opts.hide_ctl = false;
                hide_ctl_set = true;
            },
            'Q' => {
                opts.quoting = .c;
                quoting_set = true;
            },
            143 => {
                opts.quoting = quotingFromName(it.val.?) orelse return badArg("quoting-style", it.val.?);
                quoting_set = true;
            },
            'r' => opts.reverse = true,
            'R' => opts.recursive = true,
            's' => opts.size = true,
            'S' => opts.sort = .size,
            144 => {
                const v = it.val.?;
                if (std.mem.eql(u8, v, "none")) opts.sort = .none else if (std.mem.eql(u8, v, "size")) opts.sort = .size else if (std.mem.eql(u8, v, "time")) opts.sort = .time else if (std.mem.eql(u8, v, "version")) opts.sort = .version else if (std.mem.eql(u8, v, "extension")) opts.sort = .extension else if (std.mem.eql(u8, v, "name")) opts.sort = .name else return badArg("sort", v);
            },
            145 => {
                const v = it.val.?;
                if (std.mem.eql(u8, v, "atime") or std.mem.eql(u8, v, "access") or std.mem.eql(u8, v, "use")) opts.time = .atime else if (std.mem.eql(u8, v, "ctime") or std.mem.eql(u8, v, "status")) opts.time = .ctime else if (std.mem.eql(u8, v, "mtime") or std.mem.eql(u8, v, "modification") or std.mem.eql(u8, v, "birth") or std.mem.eql(u8, v, "creation")) opts.time = .mtime else return badArg("time", v);
            },
            146 => time_style_arg = it.val,
            't' => opts.sort = .time,
            'T' => opts.tabsize = std.fmt.parseInt(usize, it.val.?, 10) catch {
                u.errf("ls: invalid tab size: '{s}'\n", .{it.val.?});
                return 2;
            },
            'u' => opts.time = .atime,
            'U' => opts.sort = .none,
            'v' => opts.sort = .version,
            'w' => {
                opts.width = std.fmt.parseInt(usize, it.val.?, 10) catch {
                    u.errf("ls: invalid line width: '{s}'\n", .{it.val.?});
                    return 2;
                };
                width_set = true;
            },
            'x' => {
                opts.format = .horizontal;
                format_set = true;
            },
            'X' => opts.sort = .extension,
            'Z' => opts.context = true,
            147 => {
                opts.zero = true;
                if (!long_flag) {
                    opts.format = .single;
                    format_set = true;
                }
            },
            '1' => {
                opts.format = .single;
                format_set = true;
            },
            200 => {
                u.out("Usage: ls [OPTION]... [FILE]...\nList information about the FILEs (the current directory by default).\n");
                return 0;
            },
            201 => {
                u.out("ls (cmdbox)\n");
                return 0;
            },
            else => {},
        }
    }

    // defaults depending on the output device
    if (!format_set) opts.format = if (tty) .many_per_line else .single;
    if (!quoting_set) {
        if (u.getEnv("QUOTING_STYLE")) |qs| {
            if (quotingFromName(qs)) |q| opts.quoting = q;
        } else if (tty) opts.quoting = .shell_escape;
    }
    if (!hide_ctl_set) opts.hide_ctl = tty and opts.quoting == .literal;
    if (opts.quoting == .literal and opts.show_ctl) opts.hide_ctl = false;
    if (opts.format == .long and false) {}
    if (opts.sort == .none and !opts.no_sort_f and false) {}
    opts.color_on = color.lsEnabled(color_mode);
    if (opts.no_sort_f) {
        opts.color_on = color.lsEnabled(color_mode);
    }
    // block size from the environment (ls -s / total)
    if (u.getEnv("POSIXLY_CORRECT") != null and opts.block_size == 1024) opts.block_size = 512;
    // time style
    var ts: []const u8 = time_style_arg orelse (u.getEnv("TIME_STYLE") orelse "locale");
    if (std.mem.startsWith(u8, ts, "posix-")) ts = ts[6..];
    if (std.mem.eql(u8, ts, "locale")) {} else if (!(std.mem.eql(u8, ts, "full-iso") or std.mem.eql(u8, ts, "long-iso") or std.mem.eql(u8, ts, "iso") or (ts.len > 0 and ts[0] == '+'))) {
        u.errf("ls: invalid argument '{s}' for 'time style'\nValid arguments are:\n  - [posix-]full-iso\n  - [posix-]long-iso\n  - [posix-]iso\n  - [posix-]locale\n  - +FORMAT (e.g., +%H:%M) for a 'date'-style format\nTry 'ls --help' for more information.\n", .{ts});
        return 2;
    }
    opts.time_style = ts;
    // width
    if (!width_set) {
        if (u.getEnv("COLUMNS")) |cv| {
            if (std.fmt.parseInt(usize, cv, 10)) |n| {
                if (n > 0) opts.width = n;
            } else |_| {}
        } else if (tty) {
            var ws: extern struct { row: u16, col: u16, x: u16, y: u16 } = undefined;
            if (u.ok(linux.ioctl(1, 0x5413, @intFromPtr(&ws))) and ws.col > 0) opts.width = ws.col;
        }
    }
    if (opts.deref == .undefined) {
        opts.deref = if (opts.directory or opts.indicator == .classify or opts.format == .long) .never else .command_line_dir;
    }
    if (opts.format == .long) {
        // nothing: long format never uses columns
    }

    var operands = p.operands;
    if (operands.items.len == 0) operands.push(".");

    var files = u.Vec(Ent).init(u.alloc);
    var dirs = u.Vec(Ent).init(u.alloc);
    for (operands.items) |path| {
        var e = Ent{ .name = path, .path = path };
        const follow = switch (opts.deref) {
            .always, .command_line => true,
            else => false,
        };
        if (!statEnt(&e, follow)) {
            flush();
            u.errf("ls: cannot access '{s}': No such file or directory\n", .{path});
            exit_status = 2;
            continue;
        }
        if (opts.deref == .command_line_dir and e.st.mode & linux.S.IFMT == linux.S.IFLNK) {
            // follow a command-line symlink only when it points to a directory
            if (u.stat(path, true)) |t| {
                if (t.mode & linux.S.IFMT == linux.S.IFDIR) {
                    e.st = t;
                    e.is_dir = true;
                    e.link_target = null;
                }
            }
        }
        if (e.is_dir and !opts.directory) dirs.push(e) else files.push(e);
    }
    if (!opts.no_sort_f) {
        sortEnts(files.items);
        sortEnts(dirs.items);
    }
    var first = true;
    if (files.items.len > 0) {
        printEnts(files.items, false);
        first = false;
    }
    const header = operands.items.len > 1 or opts.recursive;
    for (dirs.items) |d| listDir(d.path, header, &first);
    flush();
    return exit_status;
}
