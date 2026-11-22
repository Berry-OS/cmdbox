// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// tac nl fold paste comm expand unexpand rev - GNU coreutils / util-linux semantics
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");

const HELP: u8 = 200;
const VERSION: u8 = 201;

fn readFd(fd: i32) ?[]u8 {
    var data = u.Vec(u8).init(u.alloc);
    var buf: [65536]u8 = undefined;
    while (true) {
        const rc = linux.read(fd, &buf, buf.len);
        if (u.errno(rc) == .INTR) continue;
        if (!u.ok(rc)) return null;
        if (rc == 0) break;
        data.pushSlice(buf[0..rc]);
    }
    return data.items;
}

/// read a whole operand ("-" = stdin); prints the GNU diagnostic on failure
fn slurp(prog: []const u8, name: []const u8) ?[]u8 {
    if (std.mem.eql(u8, name, "-")) return readFd(0) orelse {
        u.errf("{s}: standard input: read error\n", .{prog});
        return null;
    };
    const rc = linux.open(u.zstr(name), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(rc)) {
        u.errf("{s}: {s}: {s}\n", .{ prog, name, u.strerr(u.errno(rc)) });
        return null;
    }
    const d = readFd(@intCast(rc));
    _ = linux.close(@intCast(rc));
    return d orelse {
        u.errf("{s}: {s}: read error\n", .{ prog, name });
        return null;
    };
}

fn common(prog: []const u8, key: u8, usage: []const u8) ?u8 {
    if (key == HELP) {
        u.out(usage);
        return 0;
    }
    if (key == VERSION) {
        u.outf("{s} (cmdbox)\n", .{prog});
        return 0;
    }
    return null;
}

const hv = [_]g.Opt{
    .{ .name = "help", .key = HELP },
    .{ .name = "version", .key = VERSION },
};

// ===================== tac =====================
pub fn tac(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "before", .key = 'b' },
        .{ .name = "regex", .key = 'r' },
        .{ .name = "separator", .key = 's', .arg = .req },
    } ++ hv;
    var p = g.Parser.init("tac", args, &opts);
    var before = false;
    var sep: []const u8 = "\n";
    while (p.next() catch return 1) |it| {
        if (common("tac", it.key, "Usage: tac [OPTION]... [FILE]...\nWrite each FILE to standard output, last line first.\n")) |r| return r;
        switch (it.key) {
            'b' => before = true,
            's' => sep = it.val.?,
            else => {},
        }
    }
    if (sep.len == 0) {
        u.err("tac: separator cannot be empty\n");
        return 1;
    }
    var files = p.operands;
    if (files.items.len == 0) files.push("-");
    var rc: u8 = 0;
    for (files.items) |name| {
        const data = slurp("tac", name) orelse {
            rc = 1;
            continue;
        };
        var o = u.Vec(u8).init(u.alloc);
        // split into records
        var recs = u.Vec([]const u8).init(u.alloc);
        var start: usize = 0;
        var i: usize = 0;
        if (!before) {
            while (i + sep.len <= data.len) {
                if (std.mem.eql(u8, data[i .. i + sep.len], sep)) {
                    recs.push(data[start .. i + sep.len]);
                    i += sep.len;
                    start = i;
                } else i += 1;
            }
            if (start < data.len) recs.push(data[start..]);
        } else {
            while (i + sep.len <= data.len) {
                if (std.mem.eql(u8, data[i .. i + sep.len], sep)) {
                    if (i > start or recs.items.len > 0 or i > 0) {
                        if (i > start) recs.push(data[start..i]);
                    }
                    start = i;
                    i += sep.len;
                } else i += 1;
            }
            if (start < data.len) recs.push(data[start..]);
        }
        var k = recs.items.len;
        while (k > 0) {
            k -= 1;
            o.pushSlice(recs.items[k]);
        }
        u.out(o.items);
    }
    return rc;
}

// ===================== rev =====================
pub fn rev(args: []const []const u8) u8 {
    var files = u.Vec([]const u8).init(u.alloc);
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            u.out("Usage: rev [options] [file ...]\nReverse lines characterwise.\n");
            return 0;
        }
        if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) {
            u.out("rev (cmdbox)\n");
            return 0;
        }
        files.push(a);
    }
    if (files.items.len == 0) files.push("-");
    var rc: u8 = 0;
    for (files.items) |name| {
        const data = slurp("rev", name) orelse {
            rc = 1;
            continue;
        };
        var o = u.Vec(u8).init(u.alloc);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |ln| {
            if (it.peek() == null and ln.len == 0) break;
            // reverse by UTF-8 code points
            var items = u.Vec([]const u8).init(u.alloc);
            var j: usize = 0;
            while (j < ln.len) {
                const l = std.unicode.utf8ByteSequenceLength(ln[j]) catch 1;
                const e = @min(ln.len, j + l);
                items.push(ln[j..e]);
                j = e;
            }
            var k = items.items.len;
            while (k > 0) {
                k -= 1;
                o.pushSlice(items.items[k]);
            }
            o.push('\n');
        }
        u.out(o.items);
    }
    return rc;
}

// ===================== nl =====================
pub fn nl(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "body-numbering", .key = 'b', .arg = .req },
        .{ .name = "section-delimiter", .key = 'd', .arg = .req },
        .{ .name = "footer-numbering", .key = 'f', .arg = .req },
        .{ .name = "header-numbering", .key = 'h', .arg = .req },
        .{ .name = "line-increment", .key = 'i', .arg = .req },
        .{ .name = "join-blank-lines", .key = 'l', .arg = .req },
        .{ .name = "number-format", .key = 'n', .arg = .req },
        .{ .name = "no-renumber", .key = 'p' },
        .{ .name = "number-separator", .key = 's', .arg = .req },
        .{ .name = "starting-line-number", .key = 'v', .arg = .req },
        .{ .name = "number-width", .key = 'w', .arg = .req },
    } ++ hv;
    var p = g.Parser.init("nl", args, &opts);
    var style: u8 = 't';
    var pattern: ?[]const u8 = null;
    var fmt: []const u8 = "rn";
    var width: usize = 6;
    var sepstr: []const u8 = "\t";
    var start: i64 = 1;
    var inc: i64 = 1;
    var join: usize = 1;
    var renumber = true;
    defer _ = &renumber;
    while (p.next() catch return 1) |it| {
        if (common("nl", it.key, "Usage: nl [OPTION]... [FILE]...\nWrite each FILE to standard output, with line numbers added.\n")) |r| return r;
        const v = it.val orelse "";
        switch (it.key) {
            'b' => {
                if (v.len > 0 and v[0] == 'p') {
                    style = 'p';
                    pattern = v[1..];
                } else if (v.len == 1 and (v[0] == 'a' or v[0] == 't' or v[0] == 'n')) style = v[0] else {
                    u.errf("nl: invalid body numbering style: '{s}'\n", .{v});
                    return 1;
                }
            },
            'f', 'h', 'd' => {},
            'i' => inc = std.fmt.parseInt(i64, v, 10) catch {
                u.errf("nl: invalid line number increment: '{s}'\n", .{v});
                return 1;
            },
            'l' => join = std.fmt.parseInt(usize, v, 10) catch {
                u.errf("nl: invalid line number of blank lines: '{s}'\n", .{v});
                return 1;
            },
            'n' => {
                if (std.mem.eql(u8, v, "ln") or std.mem.eql(u8, v, "rn") or std.mem.eql(u8, v, "rz")) fmt = v else {
                    u.errf("nl: invalid line numbering format: '{s}'\n", .{v});
                    return 1;
                }
            },
            'p' => renumber = false,
            's' => sepstr = v,
            'v' => start = std.fmt.parseInt(i64, v, 10) catch {
                u.errf("nl: invalid starting line number: '{s}'\n", .{v});
                return 1;
            },
            'w' => {
                width = std.fmt.parseInt(usize, v, 10) catch 0;
                if (width == 0) {
                    u.errf("nl: invalid line number field width: '{s}'\n", .{v});
                    return 1;
                }
            },
            else => {},
        }
    }
    var files = p.operands;
    if (files.items.len == 0) files.push("-");
    var n = start;
    var blank_run: usize = 0;
    var rc: u8 = 0;
    for (files.items) |name| {
        const data = slurp("nl", name) orelse {
            rc = 1;
            continue;
        };
        var o = u.Vec(u8).init(u.alloc);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |ln| {
            if (it.peek() == null and ln.len == 0) break;
            var number_it = false;
            const blank = ln.len == 0;
            switch (style) {
                'a' => number_it = true,
                't' => number_it = !blank,
                'n' => number_it = false,
                else => number_it = pattern != null and std.mem.indexOf(u8, ln, pattern.?) != null,
            }
            if (blank and number_it) {
                blank_run += 1;
                if (blank_run < join) number_it = false else blank_run = 0;
            } else if (!blank) blank_run = 0;
            if (number_it) {
                var tmp: [64]u8 = undefined;
                const digits = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch "";
                if (std.mem.eql(u8, fmt, "rz")) {
                    var neg = false;
                    var body: []const u8 = digits;
                    if (n < 0) {
                        neg = true;
                        body = digits[1..];
                    }
                    if (neg) o.push('-');
                    var k = body.len + @as(usize, @intFromBool(neg));
                    while (k < width) : (k += 1) o.push('0');
                    o.pushSlice(body);
                } else if (std.mem.eql(u8, fmt, "ln")) {
                    o.pushSlice(digits);
                    var k = digits.len;
                    while (k < width) : (k += 1) o.push(' ');
                } else {
                    var k = digits.len;
                    while (k < width) : (k += 1) o.push(' ');
                    o.pushSlice(digits);
                }
                o.pushSlice(sepstr);
                n += inc;
            } else {
                o.pushN(' ', width + sepstr.len);
            }
            o.pushSlice(ln);
            o.push('\n');
        }
        u.out(o.items);
    }
    return rc;
}

// ===================== fold =====================
pub fn fold(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "bytes", .key = 'b' },
        .{ .name = "characters", .key = 'c' },
        .{ .name = "spaces", .key = 's' },
        .{ .name = "width", .key = 'w', .arg = .req },
    } ++ hv;
    var p = g.Parser.init("fold", args, &opts);
    var width: usize = 80;
    var spaces = false;
    var bytes = false;
    // legacy -NUM
    var args2 = u.Vec([]const u8).init(u.alloc);
    for (args) |a| {
        if (a.len > 1 and a[0] == '-' and std.ascii.isDigit(a[1])) {
            args2.push("-w");
            args2.push(a[1..]);
        } else args2.push(a);
    }
    p = g.Parser.init("fold", args2.items, &opts);
    while (p.next() catch return 1) |it| {
        if (common("fold", it.key, "Usage: fold [OPTION]... [FILE]...\nWrap input lines in each FILE, writing to standard output.\n")) |r| return r;
        switch (it.key) {
            'b' => bytes = true,
            'c' => {},
            's' => spaces = true,
            'w' => {
                width = std.fmt.parseInt(usize, it.val.?, 10) catch 0;
                if (width == 0) {
                    u.errf("fold: invalid number of columns: '{s}'\n", .{it.val.?});
                    return 1;
                }
            },
            else => {},
        }
    }
    var files = p.operands;
    if (files.items.len == 0) files.push("-");
    var rc: u8 = 0;
    for (files.items) |name| {
        const data = slurp("fold", name) orelse {
            rc = 1;
            continue;
        };
        var o = u.Vec(u8).init(u.alloc);
        var col: usize = 0;
        var line = u.Vec(u8).init(u.alloc); // pending text of the current output line
        for (data) |ch| {
            if (ch == '\n') {
                o.pushSlice(line.items);
                o.push('\n');
                line.items.len = 0;
                col = 0;
                continue;
            }
            if (ch == '\r') {
                line.push(ch);
                col = 0;
                continue;
            }
            if (ch == 8) {
                line.push(ch);
                if (col > 0) col -= 1;
                continue;
            }
            const w: usize = if (ch == '\t') 8 - (col % 8) else if (bytes or ((ch & 0xc0) != 0x80)) 1 else 0;
            if (col + w > width and !(ch & 0xc0 == 0x80 and !bytes)) {
                // break the line
                if (spaces) {
                    if (std.mem.lastIndexOfAny(u8, line.items, " \t")) |sp| {
                        o.pushSlice(line.items[0 .. sp + 1]);
                        o.push('\n');
                        const rest = u.alloc.dupe(u8, line.items[sp + 1 ..]) catch "";
                        line.items.len = 0;
                        line.pushSlice(rest);
                        col = 0;
                        for (rest) |rc2| col += if (rc2 == '\t') 8 - (col % 8) else if (bytes or ((rc2 & 0xc0) != 0x80)) @as(usize, 1) else 0;
                    } else {
                        o.pushSlice(line.items);
                        o.push('\n');
                        line.items.len = 0;
                        col = 0;
                    }
                } else {
                    o.pushSlice(line.items);
                    o.push('\n');
                    line.items.len = 0;
                    col = 0;
                }
            }
            line.push(ch);
            col += if (ch == '\t') 8 - (col % 8) else if (bytes or ((ch & 0xc0) != 0x80)) @as(usize, 1) else 0;
        }
        o.pushSlice(line.items);
        u.out(o.items);
    }
    return rc;
}

// ===================== paste =====================
fn unescapeDelims(s: []const u8) u.Vec(u8) {
    var d = u.Vec(u8).init(u.alloc);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                'n' => d.push('\n'),
                't' => d.push('\t'),
                '0' => d.push(0),
                '\\' => d.push('\\'),
                else => d.push(s[i]),
            }
        } else d.push(s[i]);
    }
    return d;
}

pub fn paste(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "delimiters", .key = 'd', .arg = .req },
        .{ .name = "serial", .key = 's' },
        .{ .name = "zero-terminated", .key = 'z' },
    } ++ hv;
    var p = g.Parser.init("paste", args, &opts);
    var delims = unescapeDelims("\t");
    var serial = false;
    var term: u8 = '\n';
    while (p.next() catch return 1) |it| {
        if (common("paste", it.key, "Usage: paste [OPTION]... [FILE]...\nWrite lines consisting of the sequentially corresponding lines from\neach FILE, separated by TABs, to standard output.\n")) |r| return r;
        switch (it.key) {
            'd' => delims = unescapeDelims(it.val.?),
            's' => serial = true,
            'z' => term = 0,
            else => {},
        }
    }
    var files = p.operands;
    if (files.items.len == 0) files.push("-");
    if (delims.items.len == 0) delims.push(0);
    var contents = u.Vec([]const u8).init(u.alloc);
    var rc: u8 = 0;
    var dash_count: usize = 0;
    for (files.items) |name| if (std.mem.eql(u8, name, "-")) {
        dash_count += 1;
    };
    var dash_parts = u.Vec(u.Vec(u8)).init(u.alloc);
    if (dash_count > 1) {
        // several "-" operands share standard input line by line
        const all = readFd(0) orelse "";
        var k: usize = 0;
        while (k < dash_count) : (k += 1) dash_parts.push(u.Vec(u8).init(u.alloc));
        var it = std.mem.splitScalar(u8, all, term);
        var idx: usize = 0;
        while (it.next()) |ln| {
            if (it.peek() == null and ln.len == 0) break;
            dash_parts.items[idx % dash_count].pushSlice(ln);
            dash_parts.items[idx % dash_count].push(term);
            idx += 1;
        }
    }
    var dash_seen: usize = 0;
    for (files.items) |name| {
        if (dash_count > 1 and std.mem.eql(u8, name, "-")) {
            contents.push(dash_parts.items[dash_seen].items);
            dash_seen += 1;
            continue;
        }
        contents.push(slurp("paste", name) orelse {
            rc = 1;
            contents.push("");
            continue;
        });
    }
    var o = u.Vec(u8).init(u.alloc);
    if (serial) {
        for (contents.items) |d| {
            var it = std.mem.splitScalar(u8, d, term);
            var di: usize = 0;
            var first = true;
            while (it.next()) |ln| {
                if (it.peek() == null and ln.len == 0) break;
                if (!first) {
                    o.push(delims.items[di % delims.items.len]);
                    di += 1;
                }
                first = false;
                o.pushSlice(ln);
            }
            o.push(term);
        }
    } else {
        var lists = u.Vec(std.mem.SplitIterator(u8, .scalar)).init(u.alloc);
        for (contents.items) |d| lists.push(std.mem.splitScalar(u8, d, term));
        // count lines of each file
        var maxn: usize = 0;
        var counts = u.Vec(usize).init(u.alloc);
        for (contents.items) |d| {
            var n: usize = 0;
            for (d) |ch| if (ch == term) {
                n += 1;
            };
            if (d.len > 0 and d[d.len - 1] != term) n += 1;
            counts.push(n);
            maxn = @max(maxn, n);
        }
        var row: usize = 0;
        while (row < maxn) : (row += 1) {
            for (lists.items, 0..) |*it, fi| {
                if (fi > 0) o.push(delims.items[(fi - 1) % delims.items.len]);
                if (row < counts.items[fi]) {
                    if (it.next()) |ln| o.pushSlice(ln);
                }
            }
            o.push(term);
        }
    }
    u.out(o.items);
    return rc;
}

// ===================== comm =====================
pub fn comm(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .key = '1' },
        .{ .key = '2' },
        .{ .key = '3' },
        .{ .name = "check-order", .key = 130 },
        .{ .name = "nocheck-order", .key = 131 },
        .{ .name = "output-delimiter", .key = 132, .arg = .req },
        .{ .name = "total", .key = 133 },
        .{ .name = "zero-terminated", .key = 'z' },
    } ++ hv;
    var p = g.Parser.init("comm", args, &opts);
    var hide = [_]bool{ false, false, false };
    var delim: []const u8 = "\t";
    var term: u8 = '\n';
    var total = false;
    var check_order = false;
    while (p.next() catch return 1) |it| {
        if (common("comm", it.key, "Usage: comm [OPTION]... FILE1 FILE2\nCompare sorted files FILE1 and FILE2 line by line.\n")) |r| return r;
        switch (it.key) {
            '1' => hide[0] = true,
            '2' => hide[1] = true,
            '3' => hide[2] = true,
            130 => check_order = true,
            131 => check_order = false,
            132 => delim = it.val.?,
            133 => total = true,
            'z' => term = 0,
            else => {},
        }
    }
    const ops = p.operands.items;
    if (ops.len != 2) {
        if (ops.len < 2) u.errf("comm: missing operand{s}\n", .{if (ops.len == 1) " after '" else ""}) else u.errf("comm: extra operand '{s}'\n", .{ops[2]});
        u.err("Try 'comm --help' for more information.\n");
        return 1;
    }
    const a = slurp("comm", ops[0]) orelse return 1;
    const b = slurp("comm", ops[1]) orelse return 1;
    var la = u.Vec([]const u8).init(u.alloc);
    var lb = u.Vec([]const u8).init(u.alloc);
    for ([_][]const u8{ a, b }, 0..) |d, k| {
        var it = std.mem.splitScalar(u8, d, term);
        while (it.next()) |ln| {
            if (it.peek() == null and ln.len == 0) break;
            if (k == 0) la.push(ln) else lb.push(ln);
        }
    }
    var o = u.Vec(u8).init(u.alloc);
    var i: usize = 0;
    var j: usize = 0;
    var counts = [_]usize{ 0, 0, 0 };
    var disorder = false;
    const emit = struct {
        fn line(out: *u.Vec(u8), col: usize, hide_: [3]bool, dl: []const u8, text: []const u8, t: u8) void {
            if (hide_[col]) return;
            var k: usize = 0;
            while (k < col) : (k += 1) if (!hide_[k]) out.pushSlice(dl);
            out.pushSlice(text);
            out.push(t);
        }
    }.line;
    while (i < la.items.len or j < lb.items.len) {
        var ord: std.math.Order = undefined;
        if (i >= la.items.len) ord = .gt else if (j >= lb.items.len) ord = .lt else ord = std.mem.order(u8, la.items[i], lb.items[j]);
        if (check_order) {
            if (i > 0 and i < la.items.len and std.mem.order(u8, la.items[i - 1], la.items[i]) == .gt and !disorder) {
                u.errf("comm: file 1 is not in sorted order\n", .{});
                disorder = true;
            }
            if (j > 0 and j < lb.items.len and std.mem.order(u8, lb.items[j - 1], lb.items[j]) == .gt and !disorder) {
                u.errf("comm: file 2 is not in sorted order\n", .{});
                disorder = true;
            }
        }
        switch (ord) {
            .lt => {
                emit(&o, 0, hide, delim, la.items[i], term);
                counts[0] += 1;
                i += 1;
            },
            .gt => {
                emit(&o, 1, hide, delim, lb.items[j], term);
                counts[1] += 1;
                j += 1;
            },
            .eq => {
                emit(&o, 2, hide, delim, la.items[i], term);
                counts[2] += 1;
                i += 1;
                j += 1;
            },
        }
    }
    if (total) o.pushSlice(std.fmt.allocPrint(u.alloc, "{d}{s}{d}{s}{d}{s}total\n", .{ counts[0], delim, counts[1], delim, counts[2], delim }) catch "");
    u.out(o.items);
    return if (disorder) 1 else 0;
}

// ===================== expand / unexpand =====================
fn parseTabs(spec: []const u8) ?struct { stops: []usize, rep: usize } {
    var stops = u.Vec(usize).init(u.alloc);
    var it = std.mem.tokenizeAny(u8, spec, ", ");
    var rep: usize = 0;
    while (it.next()) |t| {
        var s = t;
        var is_rep = false;
        if (s.len > 0 and (s[0] == '/' or s[0] == '+')) {
            is_rep = true;
            s = s[1..];
        }
        const n = std.fmt.parseInt(usize, s, 10) catch return null;
        if (is_rep) rep = n else stops.push(n);
    }
    if (stops.items.len == 1 and rep == 0) rep = stops.items[0];
    if (stops.items.len == 0 and rep == 0) return null;
    return .{ .stops = stops.items, .rep = rep };
}

fn nextStop(stops: []const usize, rep: usize, col: usize) usize {
    for (stops) |s| if (s > col) return s;
    if (rep > 0) {
        const last = if (stops.len > 0) stops[stops.len - 1] else 0;
        const base = if (col >= last) last else 0;
        return base + ((col - base) / rep + 1) * rep;
    }
    return col + 1;
}

pub fn expand(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "initial", .key = 'i' },
        .{ .name = "tabs", .key = 't', .arg = .req },
    } ++ hv;
    var args2 = u.Vec([]const u8).init(u.alloc);
    for (args) |a| {
        if (a.len > 1 and a[0] == '-' and (std.ascii.isDigit(a[1]) or a[1] == ',')) {
            args2.push("-t");
            args2.push(a[1..]);
        } else args2.push(a);
    }
    var p = g.Parser.init("expand", args2.items, &opts);
    var initial = false;
    var tabs = parseTabs("8").?;
    while (p.next() catch return 1) |it| {
        if (common("expand", it.key, "Usage: expand [OPTION]... [FILE]...\nConvert tabs in each FILE to spaces, writing to standard output.\n")) |r| return r;
        switch (it.key) {
            'i' => initial = true,
            't' => tabs = parseTabs(it.val.?) orelse {
                u.errf("expand: tab size contains invalid character(s): '{s}'\n", .{it.val.?});
                return 1;
            },
            else => {},
        }
    }
    var files = p.operands;
    if (files.items.len == 0) files.push("-");
    var rc: u8 = 0;
    for (files.items) |name| {
        const data = slurp("expand", name) orelse {
            rc = 1;
            continue;
        };
        var o = u.Vec(u8).init(u.alloc);
        var col: usize = 0;
        var leading = true;
        for (data) |ch| {
            if (ch == '\t' and (!initial or leading)) {
                const nx = nextStop(tabs.stops, tabs.rep, col);
                o.pushN(' ', nx - col);
                col = nx;
            } else {
                if (ch == '\n') {
                    col = 0;
                    leading = true;
                } else {
                    if (ch != ' ' and ch != '\t') leading = false;
                    if (ch == 8) {
                        if (col > 0) col -= 1;
                    } else if ((ch & 0xc0) != 0x80) col += 1;
                }
                o.push(ch);
            }
        }
        u.out(o.items);
    }
    return rc;
}

pub fn unexpand(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "all", .key = 'a' },
        .{ .name = "first-only", .key = 130 },
        .{ .name = "tabs", .key = 't', .arg = .req },
    } ++ hv;
    var p = g.Parser.init("unexpand", args, &opts);
    var all = false;
    var tabs = parseTabs("8").?;
    while (p.next() catch return 1) |it| {
        if (common("unexpand", it.key, "Usage: unexpand [OPTION]... [FILE]...\nConvert blanks in each FILE to tabs, writing to standard output.\n")) |r| return r;
        switch (it.key) {
            'a' => all = true,
            130 => all = false,
            't' => {
                tabs = parseTabs(it.val.?) orelse {
                    u.errf("unexpand: tab size contains invalid character(s): '{s}'\n", .{it.val.?});
                    return 1;
                };
                all = true;
            },
            else => {},
        }
    }
    var files = p.operands;
    if (files.items.len == 0) files.push("-");
    var rc: u8 = 0;
    for (files.items) |name| {
        const data = slurp("unexpand", name) orelse {
            rc = 1;
            continue;
        };
        var o = u.Vec(u8).init(u.alloc);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |ln| {
            if (it.peek() == null and ln.len == 0) break;
            var col: usize = 0;
            var i: usize = 0;
            var leading = true;
            while (i < ln.len) {
                if (ln[i] == ' ' or ln[i] == '\t') {
                    // collect a run of blanks
                    var j = i;
                    var ccol = col;
                    while (j < ln.len and (ln[j] == ' ' or ln[j] == '\t')) : (j += 1) {
                        ccol = if (ln[j] == '\t') nextStop(tabs.stops, tabs.rep, ccol) else ccol + 1;
                    }
                    if (all or leading) {
                        // replace by as many tabs as possible, then spaces
                        var cur = col;
                        while (true) {
                            const nx = nextStop(tabs.stops, tabs.rep, cur);
                            if (nx <= ccol and (j - i > 1 or ln[i] == '\t' or nx - cur > 1 or true)) {
                                if (nx - cur == 1 and ccol - cur == 1 and ln[i] == ' ' and j - i == 1) break;
                                o.push('\t');
                                cur = nx;
                            } else break;
                        }
                        o.pushN(' ', ccol - cur);
                    } else o.pushSlice(ln[i..j]);
                    col = ccol;
                    i = j;
                } else {
                    leading = false;
                    o.push(ln[i]);
                    if (ln[i] == 8) {
                        if (col > 0) col -= 1;
                    } else if ((ln[i] & 0xc0) != 0x80) col += 1;
                    i += 1;
                }
            }
            o.push('\n');
        }
        u.out(o.items);
    }
    return rc;
}
