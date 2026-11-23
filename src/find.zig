// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// find, xargs - GNU findutils semantics (common expression language)
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const dt = @import("datetime.zig");
const c = @cImport({
    @cInclude("fnmatch.h");
    @cInclude("regex.h");
    @cInclude("pwd.h");
    @cInclude("grp.h");
});

// ===================== find =====================
const Kind = enum {
    name, iname, path, ipath, regex, iregex, type_, size, mtime, mmin, atime, amin, ctime, cmin, newer, perm, user, group, uid, gid,
    empty, readable, writable, executable, links, inum, true_, false_, prune, print, print0, printf, ls, exec, execdir, ok, delete, quit,
    xtype, fprint, fprint0, fprintf, fls,
    not, and_, or_, comma, lparen, rparen,
};

const Cmp = enum { eq, gt, lt };

const Node = struct {
    kind: Kind,
    str: []const u8 = "",
    num: i64 = 0,
    cmp: Cmp = .eq,
    argv: [][]const u8 = &.{},
    plus: bool = false,
    ref: ?u.Stat = null,
    perm_mode: u32 = 0,
    perm_kind: u8 = 0, // 0 exact, '-' all bits, '/' any bit
    l: ?*Node = null,
    r: ?*Node = null,
    size_unit: u8 = 'b',
    fd: i32 = -1,
    fmt2: []const u8 = "",
};

const Opts = struct {
    maxdepth: usize = std.math.maxInt(usize),
    mindepth: usize = 0,
    depth_first: bool = false,
    xdev: bool = false,
    follow: enum { never, cmd, always } = .never,
    has_action: bool = false,
};

var opts = Opts{};
var failed = false;
var start_secs: i64 = 0;
var quit_flag = false;
var exec_plus: u.Vec(*Node) = undefined;

const Entry = struct { path: []const u8, name_off: usize, depth: usize, st: u.Stat, dev0: u64 };

fn openOut(file: []const u8) ?i32 {
    if (std.mem.eql(u8, file, "/dev/stdout")) return 1;
    if (std.mem.eql(u8, file, "/dev/stderr")) return 2;
    const rc = linux.open(u.zstr(file), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666);
    if (!u.ok(rc)) return null;
    return @intCast(rc);
}
fn writeFd(fd: i32, data: []const u8) void {
    if (fd == 1) {
        u.out(data);
        return;
    }
    _ = (u.File{ .fd = fd }).write(data);
}
var cur_root: []const u8 = "";

fn perr(comptime fmt: []const u8, args: anytype) void {
    u.errf("find: " ++ fmt ++ "\n", args);
}

// ---------- expression parser ----------
const Parser = struct {
    toks: []const []const u8,
    pos: usize = 0,
    bad: bool = false,

    fn peek(self: *Parser) ?[]const u8 {
        return if (self.pos < self.toks.len) self.toks[self.pos] else null;
    }

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) ?*Node {
        if (!self.bad) perr(fmt, args);
        self.bad = true;
        return null;
    }

    fn mk(kind: Kind) *Node {
        const n = u.alloc.create(Node) catch @panic("oom");
        n.* = .{ .kind = kind };
        return n;
    }

    fn parseOr(self: *Parser) ?*Node {
        var l = self.parseAnd() orelse return null;
        while (self.peek()) |t| {
            if (std.mem.eql(u8, t, "-o") or std.mem.eql(u8, t, "-or")) {
                self.pos += 1;
                const r = self.parseAnd() orelse return self.fail("expected an expression after '-o'", .{});
                const n = mk(.or_);
                n.l = l;
                n.r = r;
                l = n;
            } else break;
        }
        return l;
    }

    fn parseComma(self: *Parser) ?*Node {
        var l = self.parseOr() orelse return null;
        while (self.peek()) |t| {
            if (std.mem.eql(u8, t, ",")) {
                self.pos += 1;
                const r = self.parseOr() orelse return null;
                const n = mk(.comma);
                n.l = l;
                n.r = r;
                l = n;
            } else break;
        }
        return l;
    }

    fn parseAnd(self: *Parser) ?*Node {
        var l = self.parseNot() orelse return null;
        while (self.peek()) |t| {
            if (std.mem.eql(u8, t, "-o") or std.mem.eql(u8, t, "-or") or std.mem.eql(u8, t, ")") or std.mem.eql(u8, t, ",")) break;
            if (std.mem.eql(u8, t, "-a") or std.mem.eql(u8, t, "-and")) self.pos += 1;
            const r = self.parseNot() orelse return null;
            const n = mk(.and_);
            n.l = l;
            n.r = r;
            l = n;
        }
        return l;
    }

    fn parseNot(self: *Parser) ?*Node {
        const t = self.peek() orelse return null;
        if (std.mem.eql(u8, t, "!") or std.mem.eql(u8, t, "-not")) {
            self.pos += 1;
            const inner = self.parseNot() orelse return self.fail("expected an expression after '!'", .{});
            const n = mk(.not);
            n.l = inner;
            return n;
        }
        return self.parsePrimary();
    }

    fn num(self: *Parser, s: []const u8, n: *Node, what: []const u8) bool {
        var body = s;
        if (body.len > 0 and (body[0] == '+' or body[0] == '-')) {
            n.cmp = if (body[0] == '+') .gt else .lt;
            body = body[1..];
        }
        n.num = std.fmt.parseInt(i64, body, 10) catch {
            _ = self.fail("invalid argument `{s}' to `{s}'", .{ s, what });
            return false;
        };
        return true;
    }

    fn arg(self: *Parser, what: []const u8) ?[]const u8 {
        if (self.pos >= self.toks.len) {
            _ = self.fail("missing argument to `{s}'", .{what});
            return null;
        }
        const a = self.toks[self.pos];
        self.pos += 1;
        return a;
    }

    fn parsePrimary(self: *Parser) ?*Node {
        const t = self.peek() orelse return null;
        self.pos += 1;
        const e = std.mem.eql;
        if (e(u8, t, "(")) {
            const inner = self.parseComma() orelse return self.fail("invalid expression; expected an expression after '('", .{});
            const cl = self.peek() orelse return self.fail("invalid expression; I was expecting to find a ')' somewhere but did not see one.", .{});
            if (!e(u8, cl, ")")) return self.fail("invalid expression; I was expecting to find a ')' somewhere but did not see one.", .{});
            self.pos += 1;
            return inner;
        }
        const simple = [_]struct { n: []const u8, k: Kind }{
            .{ .n = "-name", .k = .name }, .{ .n = "-iname", .k = .iname }, .{ .n = "-path", .k = .path }, .{ .n = "-wholename", .k = .path },
            .{ .n = "-ipath", .k = .ipath }, .{ .n = "-regex", .k = .regex }, .{ .n = "-iregex", .k = .iregex }, .{ .n = "-user", .k = .user },
            .{ .n = "-group", .k = .group },
        };
        for (simple) |s| if (e(u8, t, s.n)) {
            const n = mk(s.k);
            n.str = self.arg(t) orelse return null;
            if (s.k == .regex or s.k == .iregex) opts.has_action = opts.has_action;
            return n;
        };
        const numeric = [_]struct { n: []const u8, k: Kind }{
            .{ .n = "-mtime", .k = .mtime }, .{ .n = "-mmin", .k = .mmin }, .{ .n = "-atime", .k = .atime }, .{ .n = "-amin", .k = .amin },
            .{ .n = "-ctime", .k = .ctime }, .{ .n = "-cmin", .k = .cmin }, .{ .n = "-uid", .k = .uid }, .{ .n = "-gid", .k = .gid },
            .{ .n = "-links", .k = .links }, .{ .n = "-inum", .k = .inum },
        };
        for (numeric) |s| if (e(u8, t, s.n)) {
            const n = mk(s.k);
            const a = self.arg(t) orelse return null;
            if (!self.num(a, n, t)) return null;
            return n;
        };
        if (e(u8, t, "-type")) {
            const n = mk(.type_);
            n.str = self.arg(t) orelse return null;
            for (n.str) |ch| if (std.mem.indexOfScalar(u8, "bcdpfls,", ch) == null) return self.fail("Unknown argument to -type: {c}", .{ch});
            return n;
        }
        if (e(u8, t, "-xtype")) {
            const n = mk(.xtype);
            n.str = self.arg(t) orelse return null;
            for (n.str) |ch| if (std.mem.indexOfScalar(u8, "bcdpfls,", ch) == null) return self.fail("Unknown argument to -xtype: {c}", .{ch});
            return n;
        }
        if (e(u8, t, "-fprint") or e(u8, t, "-fprint0") or e(u8, t, "-fls") or e(u8, t, "-fprintf")) {
            opts.has_action = true;
            const n = mk(if (e(u8, t, "-fprint")) .fprint else if (e(u8, t, "-fprint0")) .fprint0 else if (e(u8, t, "-fls")) .fls else .fprintf);
            const file = self.arg(t) orelse return null;
            if (n.kind == .fprintf) n.fmt2 = self.arg(t) orelse return null;
            n.fd = openOut(file) orelse return self.fail("{s}: cannot open for writing", .{file});
            return n;
        }
        if (e(u8, t, "-size")) {
            const n = mk(.size);
            var a = self.arg(t) orelse return null;
            if (a.len > 0 and (a[0] == '+' or a[0] == '-')) {
                n.cmp = if (a[0] == '+') .gt else .lt;
                a = a[1..];
            }
            var unit: u8 = 'b';
            if (a.len > 0 and std.mem.indexOfScalar(u8, "bcwkMGT", a[a.len - 1]) != null) {
                unit = a[a.len - 1];
                a = a[0 .. a.len - 1];
            }
            n.num = std.fmt.parseInt(i64, a, 10) catch return self.fail("invalid argument `{s}' to `-size'", .{a});
            n.size_unit = unit;
            return n;
        }
        if (e(u8, t, "-newer")) {
            const n = mk(.newer);
            const f = self.arg(t) orelse return null;
            n.ref = u.stat(f, true) orelse return self.fail("'{s}': No such file or directory", .{f});
            return n;
        }
        if (e(u8, t, "-perm")) {
            const n = mk(.perm);
            var a = self.arg(t) orelse return null;
            if (a.len > 0 and (a[0] == '-' or a[0] == '/' or a[0] == '+')) {
                n.perm_kind = if (a[0] == '+') '/' else a[0];
                a = a[1..];
            }
            if (std.fmt.parseInt(u32, a, 8)) |m| n.perm_mode = m else |_| {
                n.perm_mode = @import("mode.zig").apply(a, 0, false, 0) orelse return self.fail("invalid mode '{s}'", .{a});
            }
            return n;
        }
        const flags = [_]struct { n: []const u8, k: Kind }{
            .{ .n = "-empty", .k = .empty }, .{ .n = "-readable", .k = .readable }, .{ .n = "-writable", .k = .writable }, .{ .n = "-executable", .k = .executable },
            .{ .n = "-true", .k = .true_ }, .{ .n = "-false", .k = .false_ }, .{ .n = "-prune", .k = .prune }, .{ .n = "-print", .k = .print },
            .{ .n = "-print0", .k = .print0 }, .{ .n = "-ls", .k = .ls }, .{ .n = "-delete", .k = .delete }, .{ .n = "-quit", .k = .quit },
        };
        for (flags) |s| if (e(u8, t, s.n)) {
            if (s.k == .print or s.k == .print0 or s.k == .ls or s.k == .delete or s.k == .quit) opts.has_action = true;
            if (s.k == .delete) opts.depth_first = true;
            return mk(s.k);
        };
        if (e(u8, t, "-nouser") or e(u8, t, "-nogroup")) {
            const n = mk(.false_);
            return n;
        }
        if (e(u8, t, "-printf")) {
            opts.has_action = true;
            const n = mk(.printf);
            n.str = self.arg(t) orelse return null;
            return n;
        }
        if (e(u8, t, "-exec") or e(u8, t, "-execdir") or e(u8, t, "-ok")) {
            opts.has_action = true;
            const n = mk(if (e(u8, t, "-exec")) .exec else if (e(u8, t, "-execdir")) .execdir else .ok);
            var av = u.Vec([]const u8).init(u.alloc);
            while (true) {
                const a = self.arg(t) orelse return self.fail("missing argument to `{s}'", .{t});
                if (e(u8, a, ";")) break;
                if (e(u8, a, "+") and av.items.len > 0 and e(u8, av.items[av.items.len - 1], "{}")) {
                    n.plus = true;
                    break;
                }
                av.push(a);
            }
            n.argv = av.items;
            return n;
        }
        // global options appearing inside the expression
        if (e(u8, t, "-maxdepth") or e(u8, t, "-mindepth")) {
            const a = self.arg(t) orelse return null;
            const v = std.fmt.parseInt(usize, a, 10) catch return self.fail("Expected a positive decimal integer argument to {s}, but got `{s}'", .{ t, a });
            if (t[2] == 'a') opts.maxdepth = v else opts.mindepth = v;
            return mk(.true_);
        }
        if (e(u8, t, "-depth") or e(u8, t, "-d")) {
            opts.depth_first = true;
            return mk(.true_);
        }
        if (e(u8, t, "-xdev") or e(u8, t, "-mount")) {
            opts.xdev = true;
            return mk(.true_);
        }
        if (e(u8, t, "-noleaf") or e(u8, t, "-ignore_readdir_race") or e(u8, t, "-noignore_readdir_race") or e(u8, t, "-follow")) {
            if (e(u8, t, "-follow")) opts.follow = .always;
            return mk(.true_);
        }
        if (t.len > 0 and t[0] == '-' or std.mem.eql(u8, t, "!")) return self.fail("unknown predicate `{s}'", .{t});
        return self.fail("paths must precede expression: `{s}'", .{t});
    }
};

// ---------- evaluation ----------
fn fnmatchOk(pat: []const u8, text: []const u8, icase: bool) bool {
    const flags: c_int = if (icase) c.FNM_CASEFOLD else 0;
    return c.fnmatch(u.zstr(pat).ptr, u.zstr(text).ptr, flags) == 0;
}

fn cmpNum(cmp: Cmp, a: i64, b: i64) bool {
    return switch (cmp) {
        .eq => a == b,
        .gt => a > b,
        .lt => a < b,
    };
}

fn typeChar(mode: u32) u8 {
    return switch (mode & linux.S.IFMT) {
        linux.S.IFREG => 'f',
        linux.S.IFDIR => 'd',
        linux.S.IFLNK => 'l',
        linux.S.IFBLK => 'b',
        linux.S.IFCHR => 'c',
        linux.S.IFIFO => 'p',
        linux.S.IFSOCK => 's',
        else => '?',
    };
}

fn baseOf(path: []const u8) []const u8 {
    var s = path;
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| {
        if (s.len == 1) return s;
        return s[i + 1 ..];
    }
    return s;
}

fn regexMatches(pat: []const u8, text: []const u8, icase: bool) bool {
    var re: c.regex_t = undefined;
    const anchored = std.fmt.allocPrint(u.alloc, "^({s})$", .{pat}) catch return false;
    if (c.regcomp(&re, u.zstr(anchored).ptr, c.REG_EXTENDED | c.REG_NOSUB | (if (icase) c.REG_ICASE else 0)) != 0) return false;
    defer c.regfree(&re);
    return c.regexec(&re, u.zstr(text).ptr, 0, null, 0) == 0;
}

fn userNameOf(uid: u32) []const u8 {
    if (c.getpwuid(uid)) |p| return std.mem.sliceTo(p.*.pw_name, 0);
    return "";
}
fn groupNameOf(gid: u32) []const u8 {
    if (c.getgrgid(gid)) |p| return std.mem.sliceTo(p.*.gr_name, 0);
    return "";
}

fn runExec(n: *Node, e: *const Entry, files: []const []const u8) bool {
    var av = u.Vec([:0]const u8).init(u.alloc);
    for (n.argv) |a| {
        if (std.mem.eql(u8, a, "{}")) {
            for (files) |f| av.push(u.zstr(f));
        } else if (std.mem.indexOf(u8, a, "{}") != null and files.len == 1) {
            const rep = std.mem.replaceOwned(u8, u.alloc, a, "{}", files[0]) catch a;
            av.push(u.zstr(rep));
        } else av.push(u.zstr(a));
    }
    _ = e;
    const pid = linux.fork();
    if (!u.ok(pid)) return false;
    if (pid == 0) {
        var pb: [u.PATH_MAX]u8 = undefined;
        const path = u.findInPath(n.argv[0], &pb) orelse {
            u.errf("find: '{s}': No such file or directory\n", .{n.argv[0]});
            linux.exit_group(127);
        };
        _ = linux.execve(path.ptr, u.argvp(av.items), u.envp(&.{}));
        linux.exit_group(126);
    }
    var st: u32 = 0;
    _ = linux.waitpid(@intCast(pid), &st, 0);
    return st & 0x7f == 0 and (st >> 8) & 0xff == 0;
}

fn formatPrintf(fmt: []const u8, e: *const Entry, o: *u.Vec(u8)) void {
    var i: usize = 0;
    while (i < fmt.len) {
        const ch = fmt[i];
        if (ch == '\\' and i + 1 < fmt.len) {
            i += 1;
            switch (fmt[i]) {
                'n' => o.push('\n'),
                't' => o.push('\t'),
                '0' => o.push(0),
                '\\' => o.push('\\'),
                'a' => o.push(7),
                'r' => o.push('\r'),
                else => {
                    o.push('\\');
                    o.push(fmt[i]);
                },
            }
            i += 1;
            continue;
        }
        if (ch != '%' or i + 1 >= fmt.len) {
            o.push(ch);
            i += 1;
            continue;
        }
        i += 1;
        var tmp: [64]u8 = undefined;
        switch (fmt[i]) {
            '%' => o.push('%'),
            'p' => o.pushSlice(e.path),
            'f' => o.pushSlice(baseOf(e.path)),
            'h' => o.pushSlice(std.fs.path.dirname(e.path) orelse "."),
            's' => o.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{e.st.size}) catch ""),
            'd' => o.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{e.depth}) catch ""),
            'm' => o.pushSlice(std.fmt.bufPrint(&tmp, "{o}", .{e.st.mode & 0o7777}) catch ""),
            'M' => {
                const t = typeChar(e.st.mode);
                o.push(if (t == 'f') '-' else t);
                const letters = "rwxrwxrwx";
                for (letters, 0..) |l, k| o.push(if (e.st.mode & (@as(u32, 0o400) >> @as(u5, @intCast(k))) != 0) l else '-');
            },
            'u' => o.pushSlice(userNameOf(e.st.uid)),
            'g' => o.pushSlice(groupNameOf(e.st.gid)),
            'U' => o.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{e.st.uid}) catch ""),
            'G' => o.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{e.st.gid}) catch ""),
            'i' => o.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{e.st.ino}) catch ""),
            'n' => o.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{e.st.nlink}) catch ""),
            'y' => o.push(typeChar(e.st.mode)),
            'b' => o.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{e.st.blocks}) catch ""),
            'k' => o.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{(e.st.blocks + 1) / 2}) catch ""),
            'l' => {
                var buf: [u.PATH_MAX]u8 = undefined;
                const rl = linux.readlink(u.zstr(e.path), &buf, buf.len);
                if (u.ok(rl)) o.pushSlice(buf[0..rl]);
            },
            'P' => {
                var rel: []const u8 = if (e.path.len >= cur_root.len) e.path[cur_root.len..] else e.path;
                while (rel.len > 0 and rel[0] == '/') rel = rel[1..];
                o.pushSlice(rel);
            },
            'H' => o.pushSlice(cur_root),
            'a', 'c', 't' => {
                const secs = switch (fmt[i]) {
                    'a' => e.st.atime,
                    'c' => e.st.ctime,
                    else => e.st.mtime,
                };
                const nsec = switch (fmt[i]) {
                    'a' => e.st.atime_nsec,
                    'c' => e.st.ctime_nsec,
                    else => e.st.mtime_nsec,
                };
                const tm = dt.localtime(secs);
                var head: [48]u8 = undefined;
                var spec1 = [_:0]u8{ '%', 'a', ' ', '%', 'b', ' ', '%', 'e', ' ', '%', 'T' };
                const n1 = dt.c.strftime(&head, head.len, &spec1, &tm);
                var year: [16]u8 = undefined;
                const n2 = dt.c.strftime(&year, year.len, "%Y", &tm);
                o.pushSlice(head[0..n1]);
                o.pushSlice(std.fmt.bufPrint(&tmp, ".{d:0>9}0 ", .{nsec}) catch "");
                o.pushSlice(year[0..n2]);
            },
            'Y' => {
                const lt = u.stat(e.path, true);
                o.push(if (lt) |s2| typeChar(s2.mode) else 'N');
            },
            'T', 'A', 'C' => {
                // %T@ / %Tc style time: only the common forms
                const which = fmt[i];
                const secs = switch (which) {
                    'A' => e.st.atime,
                    'C' => e.st.ctime,
                    else => e.st.mtime,
                };
                if (i + 1 < fmt.len) {
                    i += 1;
                    if (fmt[i] == '@') {
                        o.pushSlice(std.fmt.bufPrint(&tmp, "{d}.{d:0>9}0", .{ secs, switch (which) {
                            'A' => e.st.atime_nsec,
                            'C' => e.st.ctime_nsec,
                            else => e.st.mtime_nsec,
                        } }) catch "");
                    } else {
                        const tm = dt.localtime(secs);
                        var spec: [3]u8 = .{ '%', fmt[i], 0 };
                        const n = dt.c.strftime(&tmp, tmp.len, @ptrCast(&spec), &tm);
                        o.pushSlice(tmp[0..n]);
                    }
                }
            },
            else => {
                o.push('%');
                o.push(fmt[i]);
            },
        }
        i += 1;
    }
}

fn modeString(mode: u32, buf: *[10]u8) []const u8 {
    const t = typeChar(mode);
    buf[0] = if (t == 'f') '-' else t;
    const letters = "rwxrwxrwx";
    for (letters, 0..) |l, k| buf[1 + k] = if (mode & (@as(u32, 0o400) >> @as(u5, @intCast(k))) != 0) l else '-';
    if (mode & 0o4000 != 0) buf[3] = if (buf[3] == 'x') 's' else 'S';
    if (mode & 0o2000 != 0) buf[6] = if (buf[6] == 'x') 's' else 'S';
    if (mode & 0o1000 != 0) buf[9] = if (buf[9] == 'x') 't' else 'T';
    return buf[0..10];
}

/// find -ls prints names in "escape" quoting style: blanks, backslashes and control characters are escaped
fn escapeName(name: []const u8) []const u8 {
    var out = u.Vec(u8).init(u.alloc);
    for (name) |b| switch (b) {
        ' ' => out.pushSlice("\\ "),
        '\\' => out.pushSlice("\\\\"),
        7 => out.pushSlice("\\a"),
        8 => out.pushSlice("\\b"),
        9 => out.pushSlice("\\t"),
        10 => out.pushSlice("\\n"),
        11 => out.pushSlice("\\v"),
        12 => out.pushSlice("\\f"),
        13 => out.pushSlice("\\r"),
        else => if (b < 0x20 or b == 0x7f) out.pushSlice(std.fmt.allocPrint(u.alloc, "\\{o:0>3}", .{b}) catch "") else out.push(b),
    };
    return out.items;
}

fn lsLine(e: *const Entry) []const u8 {
    var out = u.Vec(u8).init(u.alloc);
    var tm = u.Vec(u8).init(u.alloc);
    const t = dt.localtime(e.st.mtime);
    const age = start_secs - e.st.mtime;
    if (age >= 0 and age < 183 * 86400) dt.format("%b %e %H:%M", .{ .sec = e.st.mtime }, &t, &tm) else dt.format("%b %e  %Y", .{ .sec = e.st.mtime }, &t, &tm);
    var mb: [10]u8 = undefined;
    var ubuf: [16]u8 = undefined;
    var gbuf: [16]u8 = undefined;
    var uname = userNameOf(e.st.uid);
    var gname = groupNameOf(e.st.gid);
    if (uname.len == 0) uname = std.fmt.bufPrint(&ubuf, "{d}", .{e.st.uid}) catch "";
    if (gname.len == 0) gname = std.fmt.bufPrint(&gbuf, "{d}", .{e.st.gid}) catch "";
    out.pushSlice(std.fmt.allocPrint(u.alloc, "{d: >9} {d: >6} {s} {d: >3} {s: <8} {s: <8} {d: >8} {s} {s}", .{ e.st.ino, (e.st.blocks + 1) / 2, modeString(e.st.mode, &mb), e.st.nlink, uname, gname, e.st.size, tm.items, escapeName(e.path) }) catch "");
    if (e.st.mode & linux.S.IFMT == linux.S.IFLNK) {
        var buf: [u.PATH_MAX]u8 = undefined;
        const rl = linux.readlink(u.zstr(e.path), &buf, buf.len);
        if (u.ok(rl)) {
            out.pushSlice(" -> ");
            out.pushSlice(escapeName(buf[0..rl]));
        }
    }
    out.push('\n');
    return out.items;
}

const EvalCtx = struct { pruned: bool = false };

fn eval(n: *Node, e: *const Entry, cx: *EvalCtx) bool {
    switch (n.kind) {
        .and_ => return eval(n.l.?, e, cx) and eval(n.r.?, e, cx),
        .or_ => return eval(n.l.?, e, cx) or eval(n.r.?, e, cx),
        .not => return !eval(n.l.?, e, cx),
        .comma => {
            _ = eval(n.l.?, e, cx);
            return eval(n.r.?, e, cx);
        },
        .true_ => return true,
        .false_ => return false,
        .name => return fnmatchOk(n.str, baseOf(e.path), false),
        .iname => return fnmatchOk(n.str, baseOf(e.path), true),
        .path => return fnmatchOk(n.str, e.path, false),
        .ipath => return fnmatchOk(n.str, e.path, true),
        .regex => return regexMatches(n.str, e.path, false),
        .iregex => return regexMatches(n.str, e.path, true),
        .type_ => return std.mem.indexOfScalar(u8, n.str, typeChar(e.st.mode)) != null,
        .size => {
            const bytes: i64 = @intCast(e.st.size);
            const unit: i64 = switch (n.size_unit) {
                'c' => 1,
                'w' => 2,
                'k' => 1024,
                'M' => 1 << 20,
                'G' => 1 << 30,
                'T' => 1 << 40,
                else => 512,
            };
            const blocks = @divTrunc(bytes + unit - 1, unit);
            return cmpNum(n.cmp, blocks, n.num);
        },
        .mtime, .atime, .ctime => {
            const t = switch (n.kind) {
                .mtime => e.st.mtime,
                .atime => e.st.atime,
                else => e.st.ctime,
            };
            const days = @divFloor(start_secs - t, 86400);
            return cmpNum(n.cmp, days, n.num);
        },
        .mmin, .amin, .cmin => {
            const t = switch (n.kind) {
                .mmin => e.st.mtime,
                .amin => e.st.atime,
                else => e.st.ctime,
            };
            const mins = @divFloor(start_secs - t + 59, 60);
            return cmpNum(n.cmp, mins, n.num);
        },
        .newer => {
            const r = n.ref.?;
            return e.st.mtime > r.mtime or (e.st.mtime == r.mtime and e.st.mtime_nsec > r.mtime_nsec);
        },
        .perm => {
            const m = e.st.mode & 0o7777;
            return switch (n.perm_kind) {
                '-' => m & n.perm_mode == n.perm_mode,
                '/' => n.perm_mode == 0 or m & n.perm_mode != 0,
                else => m == n.perm_mode,
            };
        },
        .user => {
            if (std.fmt.parseInt(u32, n.str, 10)) |v| return e.st.uid == v else |_| {}
            return std.mem.eql(u8, userNameOf(e.st.uid), n.str);
        },
        .group => {
            if (std.fmt.parseInt(u32, n.str, 10)) |v| return e.st.gid == v else |_| {}
            return std.mem.eql(u8, groupNameOf(e.st.gid), n.str);
        },
        .uid => return cmpNum(n.cmp, e.st.uid, n.num),
        .gid => return cmpNum(n.cmp, e.st.gid, n.num),
        .links => return cmpNum(n.cmp, e.st.nlink, n.num),
        .inum => return cmpNum(n.cmp, @intCast(e.st.ino), n.num),
        .empty => {
            if (e.st.mode & linux.S.IFMT == linux.S.IFREG) return e.st.size == 0;
            if (e.st.mode & linux.S.IFMT == linux.S.IFDIR) {
                var ents = u.Vec(u.DirEnt).init(u.alloc);
                return u.listDir(e.path, &ents) and ents.items.len == 0;
            }
            return false;
        },
        .readable => return u.ok(linux.access(u.zstr(e.path), 4)),
        .writable => return u.ok(linux.access(u.zstr(e.path), 2)),
        .executable => return u.ok(linux.access(u.zstr(e.path), 1)),
        .prune => {
            cx.pruned = true;
            return true;
        },
        .print => {
            u.outf("{s}\n", .{e.path});
            return true;
        },
        .print0 => {
            u.out(e.path);
            u.out(&[_]u8{0});
            return true;
        },
        .printf => {
            var o = u.Vec(u8).init(u.alloc);
            formatPrintf(n.str, e, &o);
            u.out(o.items);
            return true;
        },
        .ls => {
            u.out(lsLine(e));
            return true;
        },
        .fls => {
            writeFd(n.fd, lsLine(e));
            return true;
        },
        .fprint => {
            var o = u.Vec(u8).init(u.alloc);
            o.pushSlice(e.path);
            o.push('\n');
            writeFd(n.fd, o.items);
            return true;
        },
        .fprint0 => {
            var o = u.Vec(u8).init(u.alloc);
            o.pushSlice(e.path);
            o.push(0);
            writeFd(n.fd, o.items);
            return true;
        },
        .fprintf => {
            var o = u.Vec(u8).init(u.alloc);
            formatPrintf(n.fmt2, e, &o);
            writeFd(n.fd, o.items);
            return true;
        },
        .xtype => {
            const cur = e.st.mode;
            const other = u.stat(e.path, true) orelse {
                // dangling link
                return std.mem.indexOfScalar(u8, n.str, 'l') != null;
            };
            const tc = if (opts.follow == .never) typeChar(other.mode) else typeChar(cur);
            return std.mem.indexOfScalar(u8, n.str, tc) != null;
        },
        .delete => {
            if (e.depth == 0) return true;
            const rc = if (e.st.mode & linux.S.IFMT == linux.S.IFDIR) linux.rmdir(u.zstr(e.path)) else linux.unlink(u.zstr(e.path));
            if (!u.ok(rc)) {
                perr("cannot delete '{s}': {s}", .{ e.path, u.strerr(u.errno(rc)) });
                failed = true;
                return false;
            }
            return true;
        },
        .quit => {
            quit_flag = true;
            return true;
        },
        .exec, .execdir, .ok => {
            if (n.plus) {
                // accumulate; run at the end
                n.argv = n.argv;
                collected(n, e.path);
                return true;
            }
            if (n.kind == .ok) {
                u.errf("< {s} ... {s} > ? ", .{ n.argv[0], e.path });
                var b: [8]u8 = undefined;
                const r = linux.read(0, &b, 1);
                if (!u.ok(r) or r == 0 or (b[0] != 'y' and b[0] != 'Y')) return false;
            }
            const files = [_][]const u8{e.path};
            return runExec(n, e, &files);
        },
        else => return true,
    }
}

var collect_files: std.AutoHashMapUnmanaged(*Node, u.Vec([]const u8)) = .{};

fn collected(n: *Node, path: []const u8) void {
    const gop = collect_files.getOrPut(u.alloc, n) catch return;
    if (!gop.found_existing) gop.value_ptr.* = u.Vec([]const u8).init(u.alloc);
    gop.value_ptr.push(u.alloc.dupe(u8, path) catch path);
}

fn flushPlus(n: *Node) void {
    if (collect_files.getPtr(n)) |lst| {
        if (lst.items.len == 0) return;
        const dummy = Entry{ .path = "", .name_off = 0, .depth = 0, .st = undefined, .dev0 = 0 };
        if (!runExec(n, &dummy, lst.items)) failed = true;
        lst.items.len = 0;
    }
}

fn collectPlus(n: ?*Node, out: *u.Vec(*Node)) void {
    const nn = n orelse return;
    if ((nn.kind == .exec or nn.kind == .execdir) and nn.plus) out.push(nn);
    collectPlus(nn.l, out);
    collectPlus(nn.r, out);
}

fn walk(root: *Node, path: []const u8, depth: usize, dev0: u64, is_cmd: bool) void {
    if (quit_flag) return;
    const follow = opts.follow == .always or (opts.follow == .cmd and is_cmd);
    const st = u.stat(path, follow) orelse blk: {
        // dangling symlink with -L: fall back to the link itself
        if (follow) if (u.stat(path, false)) |s| break :blk s;
        perr("'{s}': No such file or directory", .{path});
        failed = true;
        return;
    };
    const e = Entry{ .path = path, .name_off = 0, .depth = depth, .st = st, .dev0 = dev0 };
    const is_dir = st.mode & linux.S.IFMT == linux.S.IFDIR;
    var cx = EvalCtx{};
    const visit_now = !opts.depth_first;
    if (visit_now and depth >= opts.mindepth) {
        if (!opts.has_action) {
            if (eval(root, &e, &cx)) u.outf("{s}\n", .{path});
        } else _ = eval(root, &e, &cx);
    }
    if (is_dir and depth < opts.maxdepth and !cx.pruned and !(opts.xdev and depth > 0 and st.dev != dev0)) {
        var ents = u.Vec(u.DirEnt).init(u.alloc);
        if (u.listDirRaw(path, &ents)) {
            for (ents.items) |en| {
                const child = if (std.mem.endsWith(u8, path, "/")) std.fmt.allocPrint(u.alloc, "{s}{s}", .{ path, en.name }) catch continue else std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ path, en.name }) catch continue;
                walk(root, child, depth + 1, if (depth == 0) st.dev else dev0, false);
                if (quit_flag) return;
            }
        } else {
            perr("'{s}': Permission denied", .{path});
            failed = true;
        }
    }
    if (!visit_now and depth >= opts.mindepth) {
        var cx2 = EvalCtx{};
        if (!opts.has_action) {
            if (eval(root, &e, &cx2)) u.outf("{s}\n", .{path});
        } else _ = eval(root, &e, &cx2);
    }
}

pub fn find(args: []const []const u8) u8 {
    opts = Opts{};
    failed = false;
    quit_flag = false;
    collect_files = .{};
    start_secs = u.nowSecs();
    var i: usize = 0;
    // leading -H -L -P
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-H")) opts.follow = .cmd else if (std.mem.eql(u8, a, "-L")) opts.follow = .always else if (std.mem.eql(u8, a, "-P")) opts.follow = .never else break;
    }
    if (i < args.len and (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "--version"))) {
        if (args[i][2] == 'h') u.out("Usage: find [-H] [-L] [-P] [path...] [expression]\n") else u.out("find (cmdbox)\n");
        return 0;
    }
    var paths = u.Vec([]const u8).init(u.alloc);
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len > 0 and (a[0] == '-' or std.mem.eql(u8, a, "!") or std.mem.eql(u8, a, "(") or std.mem.eql(u8, a, ","))) break;
        paths.push(a);
    }
    if (paths.items.len == 0) paths.push(".");
    var root: *Node = Parser.mk(.true_);
    if (i < args.len) {
        var p = Parser{ .toks = args[i..] };
        const parsed = p.parseComma();
        if (p.bad or parsed == null) return 1;
        if (p.pos < p.toks.len) {
            perr("unexpected extra predicate", .{});
            return 1;
        }
        root = parsed.?;
    }
    for (paths.items) |path| {
        cur_root = path;
        walk(root, path, 0, 0, true);
        if (quit_flag) break;
    }
    var plus = u.Vec(*Node).init(u.alloc);
    collectPlus(root, &plus);
    for (plus.items) |n| flushPlus(n);
    return if (failed) 1 else 0;
}

// ===================== xargs =====================
pub fn xargs(args: []const []const u8) u8 {
    const opts_t = [_]g.Opt{
        .{ .name = "null", .key = '0' },
        .{ .name = "delimiter", .key = 'd', .arg = .req },
        .{ .name = "eof", .key = 'E', .arg = .req },
        .{ .key = 'e', .arg = .opt },
        .{ .name = "replace", .key = 'I', .arg = .req },
        .{ .key = 'i', .arg = .opt },
        .{ .name = "max-lines", .key = 'L', .arg = .req },
        .{ .name = "max-args", .key = 'n', .arg = .req },
        .{ .name = "max-procs", .key = 'P', .arg = .req },
        .{ .name = "interactive", .key = 'p' },
        .{ .name = "no-run-if-empty", .key = 'r' },
        .{ .name = "max-chars", .key = 's', .arg = .req },
        .{ .name = "verbose", .key = 't' },
        .{ .name = "exit", .key = 'x' },
        .{ .name = "arg-file", .key = 'a', .arg = .req },
        .{ .name = "open-tty", .key = 'o' },
        .{ .name = "help", .key = 200 },
        .{ .name = "version", .key = 201 },
    };
    var p = g.Parser.init("xargs", args, &opts_t);
    p.stop_at_operand = true;
    var delim: ?u8 = null;
    var use_null = false;
    var eof_str: ?[]const u8 = null;
    var repl: ?[]const u8 = null;
    var max_args: usize = 0;
    var max_lines: usize = 0;
    var no_run_empty = false;
    var verbose = false;
    var max_chars: usize = 128 * 1024;
    var argfile: ?[]const u8 = null;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            '0' => use_null = true,
            'd' => {
                const v = it.val.?;
                if (v.len == 1) delim = v[0] else if (std.mem.eql(u8, v, "\\n")) delim = '\n' else if (std.mem.eql(u8, v, "\\t")) delim = '\t' else if (std.mem.eql(u8, v, "\\0")) delim = 0 else {
                    u.errf("xargs: Invalid input delimiter specification {s}: the delimiter must be either a single character or an escape sequence starting with \\.\n", .{v});
                    return 1;
                }
            },
            'E' => eof_str = it.val,
            'e' => eof_str = it.val,
            'I' => repl = it.val,
            'i' => repl = it.val orelse "{}",
            'L' => max_lines = std.fmt.parseInt(usize, it.val.?, 10) catch {
                u.errf("xargs: invalid number for -L option\n", .{});
                return 1;
            },
            'n' => {
                max_args = std.fmt.parseInt(usize, it.val.?, 10) catch 0;
                if (max_args == 0) {
                    u.errf("xargs: invalid number \"{s}\" for -n option\nTry 'xargs --help' for more information.\n", .{it.val.?});
                    return 1;
                }
            },
            'P', 'p', 'x', 'o' => {},
            'r' => no_run_empty = true,
            's' => max_chars = std.fmt.parseInt(usize, it.val.?, 10) catch 128 * 1024,
            't' => verbose = true,
            'a' => argfile = it.val,
            200 => {
                u.out("Usage: xargs [OPTION]... COMMAND [INITIAL-ARGS]...\nRun COMMAND with arguments INITIAL-ARGS and more arguments read from input.\n");
                return 0;
            },
            201 => {
                u.out("xargs (cmdbox)\n");
                return 0;
            },
            else => {},
        }
    }
    var base_cmd = u.Vec([]const u8).init(u.alloc);
    for (p.rest()) |a| base_cmd.push(a);
    if (base_cmd.items.len == 0) base_cmd.push("echo");
    // read the input
    var data = u.Vec(u8).init(u.alloc);
    {
        const fd: i32 = if (argfile) |f| blk: {
            const rc = linux.open(u.zstr(f), .{ .ACCMODE = .RDONLY }, 0);
            if (!u.ok(rc)) {
                u.errf("xargs: {s}: {s}\n", .{ f, u.strerr(u.errno(rc)) });
                return 1;
            }
            break :blk @intCast(rc);
        } else 0;
        var buf: [65536]u8 = undefined;
        while (true) {
            const rc = linux.read(fd, &buf, buf.len);
            if (u.errno(rc) == .INTR) continue;
            if (!u.ok(rc) or rc == 0) break;
            data.pushSlice(buf[0..rc]);
        }
    }
    // tokenise
    var items = u.Vec([]const u8).init(u.alloc);
    var line_ends = u.Vec(usize).init(u.alloc); // item indices where a line ended
    const d: ?u8 = if (use_null) 0 else if (repl != null and delim == null) @as(?u8, '\n') else delim;
    if (d) |dc| {
        var it = std.mem.splitScalar(u8, data.items, dc);
        while (it.next()) |t0| {
            if (it.peek() == null and t0.len == 0) break;
            var t = t0;
            if (repl != null and !use_null) t = std.mem.trimStart(u8, t, " \t");
            if (repl != null and !use_null and t.len == 0) continue;
            items.push(t);
        }
    } else {
        var i: usize = 0;
        const s = data.items;
        while (i < s.len) {
            while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n')) : (i += 1) {
                if (s[i] == '\n' and items.items.len > 0 and (line_ends.items.len == 0 or line_ends.items[line_ends.items.len - 1] != items.items.len)) line_ends.push(items.items.len);
            }
            if (i >= s.len) break;
            var tok = u.Vec(u8).init(u.alloc);
            while (i < s.len and s[i] != ' ' and s[i] != '\t' and s[i] != '\n') {
                const ch = s[i];
                if (ch == '\'' or ch == '"') {
                    const q = ch;
                    i += 1;
                    while (i < s.len and s[i] != q and s[i] != '\n') : (i += 1) tok.push(s[i]);
                    if (i >= s.len or s[i] == '\n') {
                        u.err("xargs: unmatched " ++ "single quote; by default quotes are special to xargs unless you use the -0 option\n");
                        return 1;
                    }
                    i += 1;
                } else if (ch == '\\' and i + 1 < s.len) {
                    tok.push(s[i + 1]);
                    i += 2;
                } else {
                    tok.push(ch);
                    i += 1;
                }
            }
            items.push(tok.items);
            if (i < s.len and s[i] == '\n') {
                line_ends.push(items.items.len);
            }
        }
    }
    // end-of-file string
    if (eof_str) |es| {
        for (items.items, 0..) |t, k| if (std.mem.eql(u8, t, es)) {
            items.items.len = k;
            break;
        };
    }
    var rc: u8 = 0;
    const run = struct {
        fn go(cmd: []const []const u8, verb: bool) u8 {
            if (verb) {
                var o = u.Vec(u8).init(u.alloc);
                for (cmd, 0..) |a, k| {
                    if (k > 0) o.push(' ');
                    o.pushSlice(a);
                }
                o.push('\n');
                u.err(o.items);
            }
            const pid = linux.fork();
            if (!u.ok(pid)) return 126;
            if (pid == 0) {
                var pb: [u.PATH_MAX]u8 = undefined;
                const path = u.findInPath(cmd[0], &pb) orelse {
                    u.errf("xargs: {s}: No such file or directory\n", .{cmd[0]});
                    linux.exit_group(127);
                };
                var av = u.Vec([:0]const u8).init(u.alloc);
                for (cmd) |a| av.push(u.zstr(a));
                _ = linux.execve(path.ptr, u.argvp(av.items), u.envp(&.{}));
                u.errf("xargs: {s}: cannot run\n", .{cmd[0]});
                linux.exit_group(126);
            }
            var st: u32 = 0;
            _ = linux.waitpid(@intCast(pid), &st, 0);
            if (st & 0x7f != 0) return 125;
            return @intCast((st >> 8) & 0xff);
        }
    }.go;
    if (items.items.len == 0) {
        if (no_run_empty) return 0;
        const st0 = run(base_cmd.items, verbose);
        return if (st0 == 0) 0 else if (st0 == 127 or st0 == 126) st0 else 123;
    }
    if (repl) |rs| {
        for (items.items) |it| {
            var cmd = u.Vec([]const u8).init(u.alloc);
            for (base_cmd.items) |a| cmd.push(std.mem.replaceOwned(u8, u.alloc, a, rs, it) catch a);
            const st = run(cmd.items, verbose);
            if (st == 255) {
                u.errf("xargs: {s}: exited with status 255; aborting\n", .{base_cmd.items[0]});
                return 124;
            }
            if (st != 0) rc = 123;
        }
        return rc;
    }
    var start: usize = 0;
    while (start < items.items.len) {
        var end = items.items.len;
        if (max_args > 0) end = @min(end, start + max_args);
        if (max_lines > 0) {
            // end at the max_lines-th line boundary after start
            var lines: usize = 0;
            var e2 = start;
            for (line_ends.items) |le| {
                if (le > start) {
                    lines += 1;
                    e2 = le;
                    if (lines == max_lines) break;
                }
            }
            if (lines > 0) end = @min(end, e2) else end = @min(end, items.items.len);
        }
        // size limit
        var size: usize = 0;
        for (base_cmd.items) |a| size += a.len + 1;
        var k = start;
        while (k < end) : (k += 1) {
            size += items.items[k].len + 1;
            if (size > max_chars and k > start) {
                end = k;
                break;
            }
        }
        var cmd = u.Vec([]const u8).init(u.alloc);
        for (base_cmd.items) |a| cmd.push(a);
        for (items.items[start..end]) |a| cmd.push(a);
        const st = run(cmd.items, verbose);
        if (st == 255) {
            u.errf("xargs: {s}: exited with status 255; aborting\n", .{base_cmd.items[0]});
            return 124;
        }
        if (st == 127 or st == 126) return st;
        if (st != 0) rc = 123;
        start = end;
    }
    return rc;
}
