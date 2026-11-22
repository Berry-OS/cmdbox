// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// pstree - psmisc compatible: -a -A -U -G -c -g -h -H -l -n -N -p -s -t -T -u -V, PID|USER
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("unistd.h");
});

const version_text =
    "pstree (PSmisc) 23.7\n" ++
    "Copyright (C) 1993-2024 Werner Almesberger and Craig Small\n" ++
    "\n" ++
    "PSmisc comes with ABSOLUTELY NO WARRANTY.\n" ++
    "This is free software, and you are welcome to redistribute it under\n" ++
    "the terms of the GNU General Public License.\n" ++
    "For more information about these matters, see the files named COPYING.\n";

const usage_text =
    "Usage: pstree [-acglpsStTuZ] [ -h | -H PID ] [ -n | -N type ]\n" ++
    "              [ -A | -G | -U ] [ PID | USER ]\n" ++
    "   or: pstree -V\n" ++
    "\n" ++
    "Display a tree of processes.\n" ++
    "\n" ++
    "  -a, --arguments     show command line arguments\n" ++
    "  -A, --ascii         use ASCII line drawing characters\n" ++
    "  -c, --compact-not   don't compact identical subtrees\n" ++
    "  -C, --color=TYPE    color process by attribute\n" ++
    "                      (age)\n" ++
    "  -g, --show-pgids    show process group ids; implies -c\n" ++
    "  -G, --vt100         use VT100 line drawing characters\n" ++
    "  -h, --highlight-all highlight current process and its ancestors\n" ++
    "  -H PID, --highlight-pid=PID\n" ++
    "                      highlight this process and its ancestors\n" ++
    "  -l, --long          don't truncate long lines\n" ++
    "  -n, --numeric-sort  sort output by PID\n" ++
    "  -N TYPE, --ns-sort=TYPE\n" ++
    "                      sort output by this namespace type\n" ++
    "                              (cgroup, ipc, mnt, net, pid, time, user, uts)\n" ++
    "  -p, --show-pids     show PIDs; implies -c\n" ++
    "  -s, --show-parents  show parents of the selected process\n" ++
    "  -S, --ns-changes    show namespace transitions\n" ++
    "  -t, --thread-names  show full thread names\n" ++
    "  -T, --hide-threads  hide threads, show only processes\n" ++
    "  -u, --uid-changes   show uid transitions\n" ++
    "  -U, --unicode       use UTF-8 (Unicode) line drawing characters\n" ++
    "  -V, --version       display version information\n" ++
    "  -Z, --security-context\n" ++
    "                      show security attributes\n" ++
    "\n" ++
    "  PID    start at this PID; default is 1 (init)\n" ++
    "  USER   show only trees rooted at processes of this user\n" ++
    "\n";

const Node = struct {
    pid: i64,
    ppid: i64,
    pgid: i64,
    uid: u32,
    comm: []const u8,
    args: []const u8,
    thread: bool,
    kids: u.Vec(*Node),
    hl: bool = false,
    empty_cmd: bool = false,
};

const Opts = struct {
    args: bool = false,
    ascii: bool = true,
    compact: bool = true,
    pgids: bool = false,
    pids: bool = false,
    long: bool = false,
    numeric: bool = false,
    parents: bool = false,
    no_threads: bool = false,
    thread_names: bool = false,
    uids: bool = false,
    width: usize = 132,
};

const Chars = struct { h: []const u8, plus: []const u8, tee: []const u8, end: []const u8 };

fn readSmall(path: []const u8) ?[]u8 {
    const rc = linux.open(u.zstr(path), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(rc)) return null;
    defer _ = linux.close(@intCast(rc));
    var data = u.Vec(u8).init(u.alloc);
    var buf: [8192]u8 = undefined;
    while (true) {
        const r = linux.read(@intCast(rc), &buf, buf.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r) or r == 0) break;
        data.pushSlice(buf[0..r]);
    }
    return data.items;
}

fn parseStat(st: []const u8, ppid: *i64, pgid: *i64, comm: *[]const u8) bool {
    const lp = std.mem.indexOfScalar(u8, st, '(') orelse return false;
    const rp = std.mem.lastIndexOfScalar(u8, st, ')') orelse return false;
    comm.* = u.alloc.dupe(u8, st[lp + 1 .. rp]) catch return false;
    var it = std.mem.tokenizeScalar(u8, st[rp + 1 ..], ' ');
    _ = it.next(); // state
    ppid.* = std.fmt.parseInt(i64, it.next() orelse return false, 10) catch return false;
    pgid.* = std.fmt.parseInt(i64, it.next() orelse return false, 10) catch return false;
    return true;
}

fn cmdEmpty(pid: i64) bool {
    var pb: [64]u8 = undefined;
    const d = readSmall(std.fmt.bufPrint(&pb, "/proc/{d}/cmdline", .{pid}) catch return false) orelse return false;
    return d.len == 0;
}

fn cmdArgs(pid: i64) []const u8 {
    var pb: [64]u8 = undefined;
    const d = readSmall(std.fmt.bufPrint(&pb, "/proc/{d}/cmdline", .{pid}) catch return "") orelse return "";
    const first = std.mem.indexOfScalar(u8, d, 0) orelse return "";
    return d[first + 1 ..];
}

// render the arguments so that "label + args" fits the 127 column budget psmisc uses
fn renderArgs(raw: []const u8, used: usize, show_ids: bool, unlimited: bool) []const u8 {
    const budget: usize = if (unlimited) std.math.maxInt(usize) / 2 else 127;
    var o = u.Vec(u8).init(u.alloc);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, raw, "\x00"), 0);
    var total = used;
    var idx: usize = 0;
    while (it.next()) |arg| : (idx += 1) {
        var esc = u.Vec(u8).init(u.alloc);
        escapeInto(&esc, arg);
        const need = esc.items.len + (if (idx > 0) @as(usize, 1) else 0);
        if (total + need > budget) {
            const excess = total + need - budget;
            if (arg.len > 120 and !show_ids and std.mem.indexOfScalar(u8, esc.items, '\\') == null) {
                // psmisc glues the start of an oversized argument to the previous one
                o.pushSlice(esc.items);
            } else o.pushSlice(if (excess <= 10 and arg.len <= 120) " ..." else "...");
            return o.items;
        }
        if (idx > 0) o.push(' ');
        o.pushSlice(esc.items);
        total += need;
    }
    return o.items;
}

fn escapeInto(o: *u.Vec(u8), arg: []const u8) void {
    for (arg) |ch| {
        if (ch == '\\') {
            o.pushSlice("\\\\");
        } else if (ch < 0x20 or ch >= 0x7f) {
            o.pushSlice(std.fmt.allocPrint(u.alloc, "\\{o:0>3}", .{ch}) catch "");
        } else o.push(ch);
    }
}

fn userName(uid: u32) []const u8 {
    if (c.getpwuid(uid)) |p| return std.mem.sliceTo(p.*.pw_name, 0);
    return std.fmt.allocPrint(u.alloc, "{d}", .{uid}) catch "?";
}

fn cmpTree(a: *Node, b: *Node) std.math.Order {
    const c1 = std.math.order(a.kids.items.len, b.kids.items.len);
    if (c1 != .eq) return c1;
    for (a.kids.items, b.kids.items) |x, y| {
        const cn = std.mem.order(u8, labelName(x), labelName(y));
        if (cn != .eq) return cn;
        const ct = cmpTree(x, y);
        if (ct != .eq) return ct;
    }
    return .eq;
}

fn lessByName(_: void, a: *Node, b: *Node) bool {
    const o = std.mem.order(u8, labelName(a), labelName(b));
    if (o != .eq) return o == .lt;
    return a.pid < b.pid;
}

fn lessByPid(_: void, a: *Node, b: *Node) bool {
    return a.pid < b.pid;
}

fn labelName(n: *Node) []const u8 {
    if (!n.thread) return n.comm;
    return std.fmt.allocPrint(u.alloc, "{{{s}}}", .{n.comm}) catch n.comm;
}

fn sortAll(n: *Node, numeric: bool) void {
    for (n.kids.items) |k| sortAll(k, numeric);
    if (numeric) std.mem.sort(*Node, n.kids.items, {}, lessByPid) else std.mem.sort(*Node, n.kids.items, {}, lessByName);
}

fn label(n: *Node, parent_uid: ?u32, o: *const Opts, prefix_len: usize) []const u8 {
    var b = u.Vec(u8).init(u.alloc);
    if (n.hl) b.pushSlice("\x1b[1m");
    const paren = o.args and !n.thread and n.empty_cmd;
    if (paren) b.push('(');
    b.pushSlice(labelName(n));
    if (paren) b.push(')');
    if (n.hl) b.pushSlice("\x1b[0m");
    if (o.pids or o.pgids) {
        b.push(if (o.args) ',' else '(');
        if (o.pids) b.pushSlice(std.fmt.allocPrint(u.alloc, "{d}", .{n.pid}) catch "");
        if (o.pids and o.pgids) b.push(',');
        if (o.pgids) b.pushSlice(std.fmt.allocPrint(u.alloc, "{d}", .{n.pgid}) catch "");
        if (!o.args) b.push(')');
    }
    if (o.uids) if (parent_uid) |pu| if (pu != n.uid) {
        b.push(if (o.args) ',' else '(');
        b.pushSlice(userName(n.uid));
        if (!o.args) b.push(')');
    };
    if (o.args and !n.thread and n.args.len > 0) {
        const sp = b.items.len;
        b.push(' ');
        const ra = renderArgs(n.args, prefix_len + visLen(b.items), o.pids or o.pgids or prefix_len > 0, o.long);
        if (ra.len == 0) b.items.len = sp else b.pushSlice(ra);
    }
    return b.items;
}

fn same(a: *Node, b: *Node, o: *const Opts) bool {
    // with -a only threads are merged
    if (o.args and !a.thread) return false;
    if (a.thread != b.thread or !std.mem.eql(u8, a.comm, b.comm)) return false;
    if (o.args and !std.mem.eql(u8, a.args, b.args)) return false;
    if (o.uids and a.uid != b.uid) return false;
    if (a.kids.items.len != b.kids.items.len) return false;
    for (a.kids.items, b.kids.items) |x, y| if (!same(x, y, o)) return false;
    return true;
}

// visible width of a string (escape sequences are zero width)
fn visLen(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and !(s[i] >= 0x40 and s[i] <= 0x7e)) i += 1;
            i += 1;
            continue;
        }
        if (s[i] & 0xc0 != 0x80) n += 1;
        i += 1;
    }
    return n;
}

const Group = struct { node: *Node, count: usize };

const Printer = struct {
    o: *const Opts,
    ch: Chars,
    out: u.Vec(u8),
    line: u.Vec(u8),

    fn flushLine(self: *Printer) void {
        var s = self.line.items;
        if (!self.o.long and visLen(s) >= self.o.width) {
            // truncate to width visible cells, keep escape sequences intact
            var cells: usize = 0;
            var i: usize = 0;
            while (i < s.len) {
                if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
                    i += 2;
                    while (i < s.len and !(s[i] >= 0x40 and s[i] <= 0x7e)) i += 1;
                    i += 1;
                    continue;
                }
                if (s[i] & 0xc0 != 0x80) {
                    if (cells + 1 == self.o.width) break;
                    cells += 1;
                }
                i += 1;
            }
            s = s[0..i];
        }
        self.out.pushSlice(s);
        self.out.push('\n');
        self.line.items.len = 0;
    }

    fn groups(self: *Printer, n: *Node) []Group {
        var gs = u.Vec(Group).init(u.alloc);
        // identical subtrees are merged even when not adjacent; the group sits at its first member
        for (n.kids.items) |k| {
            var merged = false;
            if (self.o.compact) for (gs.items) |*g| {
                if (same(g.node, k, self.o)) {
                    g.count += 1;
                    merged = true;
                    break;
                }
            };
            if (!merged) gs.push(.{ .node = k, .count = 1 });
        }
        return gs.items;
    }

    fn spaces(n: usize) []const u8 {
        const b = u.alloc.alloc(u8, n) catch return "";
        @memset(b, ' ');
        return b;
    }

    fn dump(self: *Printer, n: *Node, count: usize, cont: []const u8, parent_uid: ?u32, closers: usize) void {
        _ = closers;
        var lab = u.Vec(u8).init(u.alloc);
        if (count > 1) lab.pushSlice(std.fmt.allocPrint(u.alloc, "{d}*[", .{count}) catch "");
        lab.pushSlice(label(n, parent_uid, self.o, visLen(self.line.items) + (if (count > 1) @as(usize, 3) else 0)));
        const gs = self.groups(n);
        const close: []const u8 = if (count > 1) "]" else "";
        if (self.o.args) {
            self.line.pushSlice(lab.items);
            if (gs.len == 0) {
                self.line.pushSlice(close);
                self.flushLine();
                return;
            }
            self.flushLine();
            self.dumpKidsArgs(n, gs, cont, close);
            return;
        }
        self.line.pushSlice(lab.items);
        const ll = visLen(lab.items);
        if (gs.len == 0) {
            self.line.pushSlice(close);
            self.flushLine();
            return;
        }
        if (gs.len == 1) {
            self.line.pushSlice(self.ch.h);
            const nc = std.fmt.allocPrint(u.alloc, "{s}{s}", .{ cont, spaces(ll + 3) }) catch cont;
            self.dumpWithClose(gs[0], nc, n.uid, close);
            return;
        }
        self.line.pushSlice(self.ch.plus);
        for (gs, 0..) |g, i| {
            const last = i + 1 == gs.len;
            if (i > 0) {
                self.line.pushSlice(cont);
                self.line.pushSlice(spaces(ll + 1));
                self.line.pushSlice(if (last) self.ch.end else self.ch.tee);
            }
            const nc = std.fmt.allocPrint(u.alloc, "{s}{s}{s} ", .{ cont, spaces(ll + 1), if (last) " " else vbarOf(self.ch) }) catch cont;
            self.dumpWithClose(g, nc, n.uid, close);
        }
    }

    fn dumpKidsArgs(self: *Printer, n: *Node, gs: []Group, cont: []const u8, close: []const u8) void {
        for (gs, 0..) |g, i| {
            const last = i + 1 == gs.len;
            self.line.pushSlice(cont);
            self.line.pushSlice("  ");
            self.line.pushSlice(if (last) self.ch.end else self.ch.tee);
            const nc = std.fmt.allocPrint(u.alloc, "{s}  {s} ", .{ cont, if (last) " " else vbarOf(self.ch) }) catch cont;
            self.dumpWithClose(g, nc, n.uid, close);
        }
    }

    // dump a group, appending `extra_close` to its last output line
    fn dumpWithClose(self: *Printer, g: Group, cont: []const u8, parent_uid: u32, extra_close: []const u8) void {
        const start = self.out.items.len;
        self.dump(g.node, g.count, cont, parent_uid, 0);
        if (extra_close.len > 0) {
            // append before the trailing newline of the last line
            self.out.items.len -= 1;
            self.out.pushSlice(extra_close);
            self.out.push('\n');
        }
        _ = start;
    }
};

fn vbarOf(ch: Chars) []const u8 {
    return if (std.mem.eql(u8, ch.h, "---")) "|" else "│";
}

pub fn run(args: []const []const u8) u8 {
    var o = Opts{};
    var utf = false;
    for ([_][]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |v| if (u.getEnv(v)) |val| if (val.len > 0) {
        utf = std.ascii.indexOfIgnoreCase(val, "utf-8") != null or std.ascii.indexOfIgnoreCase(val, "utf8") != null;
        break;
    };
    var highlight_self = false;
    var hl_pid: ?i64 = null;
    var target: ?[]const u8 = null;
    var i: usize = 0;
    var done = false;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (done or a.len < 2 or a[0] != '-') {
            if (target != null) {
                u.err(usage_text);
                return 1;
            }
            target = a;
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            done = true;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--")) {
            const n = a[2..];
            if (std.mem.eql(u8, n, "arguments")) o.args = true else if (std.mem.eql(u8, n, "ascii")) utf = false else if (std.mem.eql(u8, n, "unicode")) utf = true else if (std.mem.eql(u8, n, "vt100")) utf = false else if (std.mem.eql(u8, n, "compact-not")) o.compact = false else if (std.mem.eql(u8, n, "show-pgids")) {
                o.pgids = true;
                o.compact = false;
            } else if (std.mem.eql(u8, n, "thread-names")) o.thread_names = true else if (std.mem.eql(u8, n, "highlight-all")) highlight_self = true else if (std.mem.eql(u8, n, "long")) o.long = true else if (std.mem.eql(u8, n, "numeric-sort")) o.numeric = true else if (std.mem.eql(u8, n, "show-pids")) {
                o.pids = true;
                o.compact = false;
            } else if (std.mem.eql(u8, n, "show-parents")) o.parents = true else if (std.mem.eql(u8, n, "hide-threads")) o.no_threads = true else if (std.mem.eql(u8, n, "uid-changes")) o.uids = true else if (std.mem.eql(u8, n, "ns-changes") or std.mem.eql(u8, n, "security-context")) {} else if (std.mem.eql(u8, n, "version")) {
                u.err(version_text);
                return 0;
            } else {
                u.errf("pstree: unrecognized option '{s}'\n", .{a});
                return 1;
            }
            continue;
        }
        var k: usize = 1;
        while (k < a.len) : (k += 1) switch (a[k]) {
            'a' => o.args = true,
            'A' => utf = false,
            'U' => utf = true,
            'G' => utf = false,
            'c' => o.compact = false,
            'g' => o.pgids = true,
            'h' => highlight_self = true,
            'l' => o.long = true,
            'n' => o.numeric = true,
            'p' => {
                o.pids = true;
                o.compact = false;
            },
            's' => o.parents = true,
            't' => o.thread_names = true,
            'S', 'Z' => {},
            'T' => o.no_threads = true,
            'u' => o.uids = true,
            'V' => {
                u.err(version_text);
                return 0;
            },
            'H', 'N', 'C' => {
                var val: []const u8 = a[k + 1 ..];
                if (val.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        u.err(usage_text);
                        return 1;
                    }
                    val = args[i];
                }
                if (a[k] == 'H') hl_pid = std.fmt.parseInt(i64, val, 10) catch {
                    u.errf("pstree: invalid process id: {s}\n", .{val});
                    return 1;
                };
                k = a.len;
            },
            else => {
                u.errf("pstree: invalid option -- '{c}'\n", .{a[k]});
                u.err(usage_text);
                return 1;
            },
        };
    }
    const ch = if (utf) Chars{ .h = "───", .plus = "─┬─", .tee = "├─", .end = "└─" } else Chars{ .h = "---", .plus = "-+-", .tee = "|-", .end = "`-" };
    if (u.getEnv("COLUMNS")) |cs| {
        o.width = std.fmt.parseInt(usize, cs, 10) catch 132;
    } else {
        const Winsize = extern struct { row: u16, col: u16, xpixel: u16, ypixel: u16 };
        var ws: Winsize = undefined;
        if (u.ok(linux.ioctl(1, 0x5413, @intFromPtr(&ws))) and ws.col > 0) o.width = ws.col;
    }
    if (highlight_self) hl_pid = c.getpid();

    // load processes
    var nodes = std.AutoHashMap(i64, *Node).init(u.alloc);
    var order = u.Vec(*Node).init(u.alloc);
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir("/proc", &ents)) {
        u.err("pstree: cannot open /proc\n");
        return 1;
    }
    for (ents.items) |e| {
        const pid = std.fmt.parseInt(i64, e.name, 10) catch continue;
        var pb: [96]u8 = undefined;
        const st = readSmall(std.fmt.bufPrint(&pb, "/proc/{d}/stat", .{pid}) catch continue) orelse continue;
        var ppid: i64 = 0;
        var pgid: i64 = 0;
        var comm: []const u8 = "";
        if (!parseStat(st, &ppid, &pgid, &comm)) continue;
        var uid: u32 = 0;
        if (u.stat(std.fmt.bufPrint(&pb, "/proc/{d}", .{pid}) catch "", true)) |ps| uid = ps.uid;
        const n = u.alloc.create(Node) catch continue;
        n.* = .{ .pid = pid, .ppid = ppid, .pgid = pgid, .uid = uid, .comm = comm, .args = if (o.args) cmdArgs(pid) else "", .empty_cmd = o.args and cmdEmpty(pid), .thread = false, .kids = u.Vec(*Node).init(u.alloc) };
        nodes.put(pid, n) catch continue;
        order.push(n);
        if (!o.no_threads) {
            var tents = u.Vec(u.DirEnt).init(u.alloc);
            if (u.listDir(std.fmt.bufPrint(&pb, "/proc/{d}/task", .{pid}) catch "", &tents)) for (tents.items) |te| {
                const tid = std.fmt.parseInt(i64, te.name, 10) catch continue;
                if (tid == pid) continue;
                var tb: [96]u8 = undefined;
                const tst = readSmall(std.fmt.bufPrint(&tb, "/proc/{d}/task/{d}/stat", .{ pid, tid }) catch continue) orelse continue;
                var tp: i64 = 0;
                var tg: i64 = 0;
                var tc: []const u8 = "";
                if (!parseStat(tst, &tp, &tg, &tc)) continue;
                const tn = u.alloc.create(Node) catch continue;
                tn.* = .{ .pid = tid, .ppid = pid, .pgid = tg, .uid = uid, .comm = if (o.thread_names) tc else comm, .args = "", .thread = true, .kids = u.Vec(*Node).init(u.alloc) };
                order.push(tn);
            };
        }
    }
    // link: threads attach to their process; processes to their parent
    for (order.items) |n| {
        if (n.thread) {
            if (nodes.get(n.ppid)) |p| p.kids.push(n);
        } else if (n.ppid != n.pid) {
            if (nodes.get(n.ppid)) |p| p.kids.push(n);
        }
    }
    if (hl_pid) |hp| {
        var cur = nodes.get(hp);
        var guard: usize = 0;
        while (cur) |n| : (guard += 1) {
            n.hl = true;
            if (guard > 4096 or n.ppid == n.pid) break;
            cur = nodes.get(n.ppid);
        }
    }
    for (order.items) |n| if (!n.thread) sortAll(n, o.numeric);

    var roots = u.Vec(*Node).init(u.alloc);
    var show_parents_of: ?*Node = null;
    if (target) |t| {
        if (std.fmt.parseInt(i64, t, 10)) |pid| {
            const n = nodes.get(pid) orelse return 0;
            if (o.parents) show_parents_of = n else roots.push(n);
        } else |_| {
            const uid = u.findUser(t) orelse {
                u.errf("No such user name: {s}\n", .{t});
                return 1;
            };
            for (order.items) |n| {
                if (n.thread or n.uid != uid) continue;
                const par = nodes.get(n.ppid);
                if (par == null or par.?.uid != uid) roots.push(n);
            }
            if (roots.items.len == 0) return 0;
        }
    } else if (o.parents) {
        show_parents_of = nodes.get(c.getpid());
    } else {
        const n = nodes.get(1) orelse return 0;
        roots.push(n);
    }
    var pr = Printer{ .o = &o, .ch = ch, .out = u.Vec(u8).init(u.alloc), .line = u.Vec(u8).init(u.alloc) };
    if (show_parents_of) |tn| {
        // chain from the top ancestor down to the target, siblings pruned
        var chain = u.Vec(*Node).init(u.alloc);
        var cur: ?*Node = tn;
        while (cur) |n| {
            chain.push(n);
            if (n.ppid == n.pid) break;
            cur = nodes.get(n.ppid);
        }
        std.mem.reverse(*Node, chain.items);
        // clone the chain with single children
        var prev: ?*Node = null;
        var top: ?*Node = null;
        for (chain.items) |n| {
            const cl = u.alloc.create(Node) catch return 1;
            cl.* = n.*;
            cl.kids = u.Vec(*Node).init(u.alloc);
            if (n == tn) cl.kids = n.kids;
            if (prev) |p| p.kids.push(cl) else top = cl;
            prev = cl;
        }
        roots.push(top.?);
    }
    for (roots.items) |r| pr.dump(r, 1, "", null, 0);
    u.out(pr.out.items);
    return 0;
}
