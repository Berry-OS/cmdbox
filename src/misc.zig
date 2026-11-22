// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// expr timeout printenv nproc tty arch truncate link unlink uptime pidof pgrep pkill
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const kill_mod = @import("kill.zig");
const dt = @import("datetime.zig");
const c = @cImport({
    @cInclude("regex.h");
    @cInclude("unistd.h");
    @cInclude("sched.h");
});

const HELP: u8 = 200;
const VERSION: u8 = 201;

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

// ===================== expr =====================
const Val = union(enum) {
    int: i64,
    str: []const u8,

    fn text(self: Val) []const u8 {
        return switch (self) {
            .int => |i| std.fmt.allocPrint(u.alloc, "{d}", .{i}) catch "",
            .str => |s| s,
        };
    }
    fn asInt(self: Val) ?i64 {
        return switch (self) {
            .int => |i| i,
            .str => |s| blk: {
                if (s.len == 0) break :blk null;
                break :blk std.fmt.parseInt(i64, s, 10) catch null;
            },
        };
    }
    fn truthy(self: Val) bool {
        return switch (self) {
            .int => |i| i != 0,
            .str => |s| blk: {
                if (s.len == 0) break :blk false;
                if (std.fmt.parseInt(i64, s, 10)) |i| break :blk i != 0 else |_| break :blk true;
            },
        };
    }
};

const ExprErr = error{ Syntax, Arith, Regex };

const Expr = struct {
    toks: []const []const u8,
    pos: usize = 0,

    fn peek(self: *Expr) ?[]const u8 {
        return if (self.pos < self.toks.len) self.toks[self.pos] else null;
    }

    fn orExpr(self: *Expr) ExprErr!Val {
        var l = try self.andExpr();
        while (self.peek()) |t| {
            if (!std.mem.eql(u8, t, "|")) break;
            self.pos += 1;
            const r = try self.andExpr();
            l = if (l.truthy()) l else if (r.truthy()) r else Val{ .int = 0 };
        }
        return l;
    }

    fn andExpr(self: *Expr) ExprErr!Val {
        var l = try self.cmpExpr();
        while (self.peek()) |t| {
            if (!std.mem.eql(u8, t, "&")) break;
            self.pos += 1;
            const r = try self.cmpExpr();
            l = if (l.truthy() and r.truthy()) l else Val{ .int = 0 };
        }
        return l;
    }

    fn cmpExpr(self: *Expr) ExprErr!Val {
        var l = try self.addExpr();
        while (self.peek()) |t| {
            const ops = [_][]const u8{ "=", "==", "!=", "<", "<=", ">", ">=" };
            var found = false;
            for (ops) |o| if (std.mem.eql(u8, t, o)) {
                found = true;
            };
            if (!found) break;
            self.pos += 1;
            const r = try self.addExpr();
            var ord: std.math.Order = undefined;
            if (l.asInt()) |a| {
                if (r.asInt()) |b| ord = std.math.order(a, b) else ord = std.mem.order(u8, l.text(), r.text());
            } else ord = std.mem.order(u8, l.text(), r.text());
            const res = if (std.mem.eql(u8, t, "=") or std.mem.eql(u8, t, "==")) ord == .eq else if (std.mem.eql(u8, t, "!=")) ord != .eq else if (std.mem.eql(u8, t, "<")) ord == .lt else if (std.mem.eql(u8, t, "<=")) ord != .gt else if (std.mem.eql(u8, t, ">")) ord == .gt else ord != .lt;
            l = Val{ .int = @intFromBool(res) };
        }
        return l;
    }

    fn addExpr(self: *Expr) ExprErr!Val {
        var l = try self.mulExpr();
        while (self.peek()) |t| {
            if (!(std.mem.eql(u8, t, "+") or std.mem.eql(u8, t, "-"))) break;
            self.pos += 1;
            const r = try self.mulExpr();
            const a = l.asInt() orelse return error.Syntax;
            const b = r.asInt() orelse return error.Syntax;
            l = Val{ .int = if (t[0] == '+') a +% b else a -% b };
        }
        return l;
    }

    fn mulExpr(self: *Expr) ExprErr!Val {
        var l = try self.matchExpr();
        while (self.peek()) |t| {
            if (!(std.mem.eql(u8, t, "*") or std.mem.eql(u8, t, "/") or std.mem.eql(u8, t, "%"))) break;
            self.pos += 1;
            const r = try self.matchExpr();
            const a = l.asInt() orelse return error.Syntax;
            const b = r.asInt() orelse return error.Syntax;
            if (t[0] != '*' and b == 0) return error.Arith;
            l = Val{ .int = switch (t[0]) {
                '*' => a *% b,
                '/' => @divTrunc(a, b),
                else => @rem(a, b),
            } };
        }
        return l;
    }

    fn matchExpr(self: *Expr) ExprErr!Val {
        var l = try self.primary();
        while (self.peek()) |t| {
            if (!std.mem.eql(u8, t, ":")) break;
            self.pos += 1;
            const r = try self.primary();
            l = try regexMatch(l.text(), r.text());
        }
        return l;
    }

    fn primary(self: *Expr) ExprErr!Val {
        const t = self.peek() orelse return error.Syntax;
        self.pos += 1;
        if (std.mem.eql(u8, t, "(")) {
            const v = try self.orExpr();
            const cl = self.peek() orelse return error.Syntax;
            if (!std.mem.eql(u8, cl, ")")) return error.Syntax;
            self.pos += 1;
            return v;
        }
        if (std.mem.eql(u8, t, "+")) {
            const w = self.peek() orelse return error.Syntax;
            self.pos += 1;
            return Val{ .str = w };
        }
        if (std.mem.eql(u8, t, "length")) {
            const a = try self.primary();
            return Val{ .int = @intCast(std.unicode.utf8CountCodepoints(a.text()) catch a.text().len) };
        }
        if (std.mem.eql(u8, t, "match")) {
            const a = try self.primary();
            const b = try self.primary();
            return regexMatch(a.text(), b.text());
        }
        if (std.mem.eql(u8, t, "substr")) {
            const s = try self.primary();
            const p = try self.primary();
            const l = try self.primary();
            const pos = p.asInt() orelse return error.Syntax;
            const len = l.asInt() orelse return error.Syntax;
            const st = s.text();
            if (pos < 1 or len < 1 or pos > st.len) return Val{ .str = "" };
            const start: usize = @intCast(pos - 1);
            const end: usize = @min(st.len, start + @as(usize, @intCast(len)));
            return Val{ .str = st[start..end] };
        }
        if (std.mem.eql(u8, t, "index")) {
            const s = try self.primary();
            const chars = try self.primary();
            const st = s.text();
            for (st, 0..) |ch, i| if (std.mem.indexOfScalar(u8, chars.text(), ch) != null) return Val{ .int = @intCast(i + 1) };
            return Val{ .int = 0 };
        }
        if (std.fmt.parseInt(i64, t, 10)) |i| return Val{ .int = i } else |_| {}
        return Val{ .str = t };
    }
};

fn regexMatch(s: []const u8, pat: []const u8) ExprErr!Val {
    var re: c.regex_t = undefined;
    const anchored = std.fmt.allocPrint(u.alloc, "^\\({s}\\)", .{pat}) catch return error.Regex;
    // GNU anchors the pattern at the start; a sub-expression in the pattern yields \1
    const has_group = std.mem.indexOf(u8, pat, "\\(") != null;
    const use = if (has_group) std.fmt.allocPrint(u.alloc, "^{s}", .{pat}) catch return error.Regex else anchored;
    if (c.regcomp(&re, u.zstr(use).ptr, 0) != 0) return error.Regex;
    defer c.regfree(&re);
    var m: [3]c.regmatch_t = undefined;
    if (c.regexec(&re, u.zstr(s).ptr, 3, &m, 0) != 0) {
        return if (has_group) Val{ .str = "" } else Val{ .int = 0 };
    }
    if (has_group) {
        // group 1 is the user's group in the unmodified pattern; with the added wrapper it is group 2
        const gi: usize = 1;
        if (m[gi].rm_so < 0) return Val{ .str = "" };
        return Val{ .str = s[@intCast(m[gi].rm_so)..@intCast(m[gi].rm_eo)] };
    }
    return Val{ .int = @intCast(m[0].rm_eo - m[0].rm_so) };
}

pub fn expr(args: []const []const u8) u8 {
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        u.out("Usage: expr EXPRESSION\n  or:  expr OPTION\nPrint the value of EXPRESSION to standard output.\n");
        return 0;
    }
    if (args.len == 1 and std.mem.eql(u8, args[0], "--version")) {
        u.out("expr (cmdbox)\n");
        return 0;
    }
    var toks = args;
    if (toks.len > 0 and std.mem.eql(u8, toks[0], "--")) toks = toks[1..];
    if (toks.len == 0) {
        u.err("expr: missing operand\nTry 'expr --help' for more information.\n");
        return 2;
    }
    var e = Expr{ .toks = toks };
    const v = e.orExpr() catch |err| {
        switch (err) {
            error.Syntax => u.err("expr: syntax error\n"),
            error.Arith => u.err("expr: division by zero\n"),
            error.Regex => u.err("expr: Invalid regular expression\n"),
        }
        return if (err == error.Syntax) 2 else 2;
    };
    if (e.pos < toks.len) {
        u.errf("expr: syntax error: unexpected argument '{s}'\n", .{toks[e.pos]});
        return 2;
    }
    u.outf("{s}\n", .{v.text()});
    return if (v.truthy()) 0 else 1;
}

// ===================== timeout =====================
fn parseDuration(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    var mult: f64 = 1;
    var body = s;
    switch (s[s.len - 1]) {
        's' => body = s[0 .. s.len - 1],
        'm' => {
            mult = 60;
            body = s[0 .. s.len - 1];
        },
        'h' => {
            mult = 3600;
            body = s[0 .. s.len - 1];
        },
        'd' => {
            mult = 86400;
            body = s[0 .. s.len - 1];
        },
        else => {},
    }
    const v = std.fmt.parseFloat(f64, body) catch return null;
    if (v < 0) return null;
    return v * mult;
}

fn nowMono() f64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1e9;
}

pub fn timeout(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "foreground", .key = 'f' },
        .{ .name = "kill-after", .key = 'k', .arg = .req },
        .{ .name = "preserve-status", .key = 'p' },
        .{ .name = "signal", .key = 's', .arg = .req },
        .{ .name = "verbose", .key = 'v' },
    } ++ hv;
    var p = g.Parser.init("timeout", args, &opts);
    p.stop_at_operand = true;
    var kill_after: f64 = 0;
    var sig: u32 = 15;
    var preserve = false;
    var verbose = false;
    while (p.next() catch return 125) |it| {
        if (common("timeout", it.key, "Usage: timeout [OPTION] DURATION COMMAND [ARG]...\nStart COMMAND, and kill it if still running after DURATION.\n")) |r| return r;
        switch (it.key) {
            'k' => kill_after = parseDuration(it.val.?) orelse {
                u.errf("timeout: invalid time interval '{s}'\nTry 'timeout --help' for more information.\n", .{it.val.?});
                return 125;
            },
            'p' => preserve = true,
            's' => sig = kill_mod.sigNum(it.val.?) orelse {
                u.errf("timeout: {s}: invalid signal\nTry 'timeout --help' for more information.\n", .{it.val.?});
                return 125;
            },
            'v' => verbose = true,
            else => {},
        }
    }
    const rest = p.rest();
    if (rest.len < 2) {
        u.err(if (rest.len == 0) "timeout: missing operand\nTry 'timeout --help' for more information.\n" else "timeout: missing operand after '");
        if (rest.len == 1) u.errf("{s}'\nTry 'timeout --help' for more information.\n", .{rest[0]});
        return 125;
    }
    const dur = parseDuration(rest[0]) orelse {
        u.errf("timeout: invalid time interval '{s}'\nTry 'timeout --help' for more information.\n", .{rest[0]});
        return 125;
    };
    const cmd = rest[1..];
    const pid_raw = linux.fork();
    if (!u.ok(pid_raw)) return 125;
    if (pid_raw == 0) {
        var pb: [u.PATH_MAX]u8 = undefined;
        const path = u.findInPath(cmd[0], &pb) orelse {
            u.errf("timeout: failed to run command '{s}': No such file or directory\n", .{cmd[0]});
            linux.exit_group(127);
        };
        var av = u.Vec([:0]const u8).init(u.alloc);
        for (cmd) |a| av.push(u.zstr(a));
        _ = linux.execve(path.ptr, u.argvp(av.items), u.envp(&.{}));
        u.errf("timeout: failed to run command '{s}': {s}\n", .{ cmd[0], "Permission denied" });
        linux.exit_group(126);
    }
    const pid: i32 = @intCast(pid_raw);
    const start = nowMono();
    var timed_out = false;
    var killed = false;
    var status: u32 = 0;
    while (true) {
        const r = linux.waitpid(pid, &status, 1); // WNOHANG
        if (u.ok(r) and r != 0) break;
        const el = nowMono() - start;
        if (!timed_out and el >= dur and dur > 0 or (!timed_out and dur == 0 and false)) {
            timed_out = true;
            if (verbose) u.errf("timeout: sending signal {s} to command '{s}'\n", .{ if (sig < u.signals.len) u.signals[sig] else "?", cmd[0] });
            _ = linux.syscall2(.kill, @bitCast(@as(isize, pid)), sig);
            if (sig != 9 and sig != 18) _ = linux.syscall2(.kill, @bitCast(@as(isize, pid)), 18); // SIGCONT
        } else if (timed_out and kill_after > 0 and !killed and el >= dur + kill_after) {
            killed = true;
            _ = linux.syscall2(.kill, @bitCast(@as(isize, pid)), 9);
        }
        var ts = linux.timespec{ .sec = 0, .nsec = 10_000_000 };
        _ = linux.nanosleep(&ts, null);
    }
    if (timed_out and !preserve) return if (status & 0x7f == 9) 137 else 124;
    if (status & 0x7f != 0 and status & 0x7f != 0x7f) return @intCast(128 + (status & 0x7f));
    return @intCast((status >> 8) & 0xff);
}

// ===================== printenv / nproc / tty / arch =====================
pub fn printenv(args: []const []const u8) u8 {
    const opts = [_]g.Opt{.{ .name = "null", .key = '0' }} ++ hv;
    var p = g.Parser.init("printenv", args, &opts);
    var nul = false;
    while (p.next() catch return 2) |it| {
        if (common("printenv", it.key, "Usage: printenv [OPTION]... [VARIABLE]...\nPrint the values of the specified environment VARIABLE(s).\n")) |r| return r;
        if (it.key == '0') nul = true;
    }
    const term: u8 = if (nul) 0 else '\n';
    var o = u.Vec(u8).init(u.alloc);
    if (p.operands.items.len == 0) {
        for (u.raw_env) |kv| if (kv) |v| {
            o.pushSlice(std.mem.sliceTo(v, 0));
            o.push(term);
        };
        u.out(o.items);
        return 0;
    }
    var rc: u8 = 0;
    for (p.operands.items) |name| {
        if (std.mem.indexOfScalar(u8, name, '=') != null) {
            rc = 1;
            continue;
        }
        var found = false;
        for (u.raw_env) |kv| if (kv) |v| {
            const s = std.mem.sliceTo(v, 0);
            if (s.len > name.len and s[name.len] == '=' and std.mem.eql(u8, s[0..name.len], name)) {
                o.pushSlice(s[name.len + 1 ..]);
                o.push(term);
                found = true;
                break;
            }
        };
        if (!found) rc = 1;
    }
    u.out(o.items);
    return rc;
}

pub fn nproc(args: []const []const u8) u8 {
    const opts = [_]g.Opt{ .{ .name = "all", .key = 'a' }, .{ .name = "ignore", .key = 'i', .arg = .req } } ++ hv;
    var p = g.Parser.init("nproc", args, &opts);
    var all = false;
    var ignore: usize = 0;
    while (p.next() catch return 1) |it| {
        if (common("nproc", it.key, "Usage: nproc [OPTION]...\nPrint the number of processing units available to the current process.\n")) |r| return r;
        switch (it.key) {
            'a' => all = true,
            'i' => ignore = std.fmt.parseInt(usize, it.val.?, 10) catch {
                u.errf("nproc: invalid number: '{s}'\n", .{it.val.?});
                return 1;
            },
            else => {},
        }
    }
    var n: usize = 0;
    if (all) {
        n = @intCast(@max(c.sysconf(c._SC_NPROCESSORS_CONF), 1));
    } else {
        var mask: [128]usize = [_]usize{0} ** 128;
        const rc = linux.syscall3(.sched_getaffinity, 0, @sizeOf(@TypeOf(mask)), @intFromPtr(&mask));
        if (u.ok(rc)) {
            for (mask) |w| n += @popCount(w);
        }
        if (n == 0) n = @intCast(@max(c.sysconf(c._SC_NPROCESSORS_ONLN), 1));
    }
    n = if (n > ignore) n - ignore else 1;
    u.outf("{d}\n", .{n});
    return 0;
}

pub fn tty(args: []const []const u8) u8 {
    var silent = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--silent") or std.mem.eql(u8, a, "--quiet")) silent = true else if (std.mem.eql(u8, a, "--help")) {
            u.out("Usage: tty [OPTION]...\nPrint the file name of the terminal connected to standard input.\n");
            return 0;
        } else if (std.mem.eql(u8, a, "--version")) {
            u.out("tty (cmdbox)\n");
            return 0;
        } else {
            u.errf("tty: invalid option -- '{s}'\nTry 'tty --help' for more information.\n", .{a});
            return 2;
        }
    }
    var t: [64]u8 = undefined;
    if (!u.ok(linux.ioctl(0, 0x5401, @intFromPtr(&t)))) {
        if (!silent) u.out("not a tty\n");
        return 1;
    }
    var buf: [u.PATH_MAX]u8 = undefined;
    const rl = linux.readlink("/proc/self/fd/0", &buf, buf.len);
    if (!silent) u.outf("{s}\n", .{if (u.ok(rl)) buf[0..rl] else "/dev/tty"});
    return 0;
}

pub fn arch(args: []const []const u8) u8 {
    if (args.len > 0) {
        if (std.mem.eql(u8, args[0], "--help")) {
            u.out("Usage: arch [OPTION]\nPrint machine architecture.\n");
            return 0;
        }
        if (std.mem.eql(u8, args[0], "--version")) {
            u.out("arch (cmdbox)\n");
            return 0;
        }
        u.errf("arch: extra operand '{s}'\nTry 'arch --help' for more information.\n", .{args[0]});
        return 1;
    }
    const un = std.posix.uname();
    u.outf("{s}\n", .{std.mem.sliceTo(&un.machine, 0)});
    return 0;
}

// ===================== truncate / link / unlink =====================
pub fn truncate(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "no-create", .key = 'c' },
        .{ .name = "io-blocks", .key = 'o' },
        .{ .name = "reference", .key = 'r', .arg = .req },
        .{ .name = "size", .key = 's', .arg = .req },
    } ++ hv;
    var p = g.Parser.init("truncate", args, &opts);
    var no_create = false;
    var ref: ?[]const u8 = null;
    var size_s: ?[]const u8 = null;
    while (p.next() catch return 1) |it| {
        if (common("truncate", it.key, "Usage: truncate OPTION... FILE...\nShrink or extend the size of each FILE to the specified size\n")) |r| return r;
        switch (it.key) {
            'c' => no_create = true,
            'r' => ref = it.val,
            's' => size_s = it.val,
            else => {},
        }
    }
    if (ref == null and size_s == null) {
        u.err("truncate: you must specify either '--size' or '--reference'\nTry 'truncate --help' for more information.\n");
        return 1;
    }
    if (p.operands.items.len == 0) {
        u.err("truncate: missing file operand\nTry 'truncate --help' for more information.\n");
        return 1;
    }
    var base: ?i64 = null;
    if (ref) |r| {
        const st = u.stat(r, true) orelse {
            u.errf("truncate: cannot stat '{s}': No such file or directory\n", .{r});
            return 1;
        };
        base = @intCast(st.size);
    }
    var op: u8 = 0;
    var amount: i64 = 0;
    var has_size = false;
    if (size_s) |s0| {
        var s = s0;
        if (s.len > 0 and std.mem.indexOfScalar(u8, "+-<>/%", s[0]) != null) {
            op = s[0];
            s = s[1..];
        }
        var i: usize = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        var v = std.fmt.parseInt(i64, s[0..i], 10) catch {
            u.errf("truncate: Invalid number: '{s}'\n", .{s0});
            return 1;
        };
        const sfx = s[i..];
        if (sfx.len > 0) {
            const idx = std.mem.indexOfScalar(u8, "KMGTPEZY", std.ascii.toUpper(sfx[0])) orelse {
                u.errf("truncate: Invalid number: '{s}'\n", .{s0});
                return 1;
            };
            var b: i64 = 1024;
            if (sfx.len == 2 and sfx[1] == 'B') b = 1000;
            var k: usize = 0;
            while (k <= idx) : (k += 1) v *%= b;
        }
        amount = v;
        has_size = true;
    }
    var rc: u8 = 0;
    for (p.operands.items) |path| {
        var fd_rc = linux.open(u.zstr(path), .{ .ACCMODE = .WRONLY, .CREAT = !no_create, .NOCTTY = true }, 0o666);
        if (!u.ok(fd_rc)) {
            if (no_create and u.errno(fd_rc) == .NOENT) continue;
            u.errf("truncate: cannot open '{s}' for writing: {s}\n", .{ path, u.strerr(u.errno(fd_rc)) });
            rc = 1;
            continue;
        }
        const fd: i32 = @intCast(fd_rc);
        var cur: i64 = 0;
        if (u.statFd(fd)) |st| cur = @intCast(st.size);
        var target: i64 = if (has_size) amount else (base orelse 0);
        if (has_size) {
            const b: i64 = base orelse cur;
            target = switch (op) {
                '+' => b + amount,
                '-' => b - amount,
                '<' => @min(b, amount),
                '>' => @max(b, amount),
                '/' => if (amount > 0) @divTrunc(b, amount) * amount else b,
                '%' => if (amount > 0) @divTrunc(b + amount - 1, amount) * amount else b,
                else => amount,
            };
        }
        if (target < 0) target = 0;
        fd_rc = linux.syscall2(.ftruncate, @as(usize, @intCast(fd)), @intCast(target));
        if (!u.ok(fd_rc)) {
            u.errf("truncate: failed to truncate '{s}' at {d} bytes: {s}\n", .{ path, target, u.strerr(u.errno(fd_rc)) });
            rc = 1;
        }
        _ = linux.close(fd);
    }
    return rc;
}

pub fn link(args: []const []const u8) u8 {
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        u.out("Usage: link FILE1 FILE2\n  or:  link OPTION\nCall the link function to create a link named FILE2 to an existing FILE1.\n");
        return 0;
    }
    if (args.len != 2) {
        if (args.len < 2) u.err("link: missing operand\n") else u.errf("link: extra operand '{s}'\n", .{args[2]});
        u.err("Try 'link --help' for more information.\n");
        return 1;
    }
    const rc = linux.link(u.zstr(args[0]), u.zstr(args[1]));
    if (!u.ok(rc)) {
        u.errf("link: cannot create link '{s}' to '{s}': {s}\n", .{ args[1], args[0], u.strerr(u.errno(rc)) });
        return 1;
    }
    return 0;
}

pub fn unlink(args: []const []const u8) u8 {
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        u.out("Usage: unlink FILE\n  or:  unlink OPTION\nCall the unlink function to remove the specified FILE.\n");
        return 0;
    }
    if (args.len != 1) {
        if (args.len < 1) u.err("unlink: missing operand\n") else u.errf("unlink: extra operand '{s}'\n", .{args[1]});
        u.err("Try 'unlink --help' for more information.\n");
        return 1;
    }
    const rc = linux.unlink(u.zstr(args[0]));
    if (!u.ok(rc)) {
        u.errf("unlink: cannot unlink '{s}': {s}\n", .{ args[0], u.strerr(u.errno(rc)) });
        return 1;
    }
    return 0;
}

// ===================== uptime =====================
fn readSmall(path: []const u8) ?[]const u8 {
    var f = u.File.open(path, .{ .ACCMODE = .RDONLY }, 0) orelse return null;
    defer f.close();
    var buf: [4096]u8 = undefined;
    const n = f.read(&buf);
    return u.alloc.dupe(u8, buf[0..n]) catch null;
}

fn countUsers() usize {
    var f = u.File.open("/var/run/utmp", .{ .ACCMODE = .RDONLY }, 0) orelse return 0;
    defer f.close();
    var n: usize = 0;
    var rec: [384]u8 = undefined;
    while (true) {
        var got: usize = 0;
        while (got < rec.len) {
            const r = f.read(rec[got..]);
            if (r == 0) break;
            got += r;
        }
        if (got < rec.len) break;
        const typ = std.mem.readInt(i16, rec[0..2], .little);
        if (typ == 7 and rec[44] != 0) n += 1;
    }
    return n;
}

pub fn uptime(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "pretty", .key = 'p' },
        .{ .name = "since", .key = 's' },
    } ++ hv;
    var p = g.Parser.init("uptime", args, &opts);
    var pretty = false;
    var since = false;
    while (p.next() catch return 1) |it| {
        if (common("uptime", it.key, "Usage: uptime [options]\nTell how long the system has been running.\n")) |r| return r;
        if (it.key == 'p') pretty = true else if (it.key == 's') since = true;
    }
    const raw = readSmall("/proc/uptime") orelse return 1;
    const up_f = std.fmt.parseFloat(f64, std.mem.sliceTo(raw, ' ')) catch 0;
    const up: u64 = @intFromFloat(up_f);
    const now = u.nowSecs();
    if (since) {
        const tm = dt.localtime(now - @as(i64, @intCast(up)));
        var o = u.Vec(u8).init(u.alloc);
        dt.format("%Y-%m-%d %H:%M:%S", .{ .sec = now - @as(i64, @intCast(up)) }, &tm, &o);
        u.outf("{s}\n", .{o.items});
        return 0;
    }
    const days = up / 86400;
    const hours = (up / 3600) % 24;
    const mins = (up / 60) % 60;
    if (pretty) {
        var o = u.Vec(u8).init(u.alloc);
        o.pushSlice("up ");
        var first = true;
        const parts = [_]struct { v: u64, n: []const u8 }{ .{ .v = days / 7, .n = "week" }, .{ .v = days % 7, .n = "day" }, .{ .v = hours, .n = "hour" }, .{ .v = mins, .n = "minute" } };
        for (parts) |pt| if (pt.v > 0) {
            if (!first) o.pushSlice(", ");
            first = false;
            o.pushSlice(std.fmt.allocPrint(u.alloc, "{d} {s}{s}", .{ pt.v, pt.n, if (pt.v == 1) "" else "s" }) catch "");
        };
        if (first) o.pushSlice("0 minutes");
        u.outf("{s}\n", .{o.items});
        return 0;
    }
    const tm = dt.localtime(now);
    var tb = u.Vec(u8).init(u.alloc);
    dt.format("%H:%M:%S", .{ .sec = now }, &tm, &tb);
    var upstr = u.Vec(u8).init(u.alloc);
    if (days > 0) upstr.pushSlice(std.fmt.allocPrint(u.alloc, "{d} day{s}, ", .{ days, if (days == 1) "" else "s" }) catch "");
    if (hours > 0 or days > 0) {
        upstr.pushSlice(std.fmt.allocPrint(u.alloc, "{d:>2}:{d:0>2}", .{ hours, mins }) catch "");
    } else upstr.pushSlice(std.fmt.allocPrint(u.alloc, "{d} min", .{mins}) catch "");
    const users = countUsers();
    var load: [3][]const u8 = .{ "0.00", "0.00", "0.00" };
    if (readSmall("/proc/loadavg")) |la| {
        var it = std.mem.tokenizeScalar(u8, la, ' ');
        var k: usize = 0;
        while (it.next()) |t| : (k += 1) {
            if (k >= 3) break;
            load[k] = t;
        }
    }
    u.outf(" {s} up {s},  {d} user{s},  load average: {s}, {s}, {s}\n", .{ tb.items, upstr.items, users, if (users == 1) "" else "s", load[0], load[1], load[2] });
    return 0;
}

// ===================== pidof / pgrep / pkill =====================
const ProcInfo = struct { pid: i64, comm: []const u8, cmdline: []const u8, ppid: i64, pgrp: i64, sid: i64, uid: u32, euid: u32, start: u64 };

fn listProcs() []ProcInfo {
    var out = u.Vec(ProcInfo).init(u.alloc);
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir("/proc", &ents)) return out.items;
    for (ents.items) |e| {
        const pid = std.fmt.parseInt(i64, e.name, 10) catch continue;
        var pb: [64]u8 = undefined;
        const st = readSmall(std.fmt.bufPrint(&pb, "/proc/{d}/stat", .{pid}) catch continue) orelse continue;
        const lp = std.mem.indexOfScalar(u8, st, '(') orelse continue;
        const rp = std.mem.lastIndexOfScalar(u8, st, ')') orelse continue;
        var info = ProcInfo{ .pid = pid, .comm = st[lp + 1 .. rp], .cmdline = "", .ppid = 0, .pgrp = 0, .sid = 0, .uid = 0, .euid = 0, .start = 0 };
        var it = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, st[rp + 1 ..], "\n"), ' ');
        var idx: usize = 3;
        while (it.next()) |t| : (idx += 1) {
            const v = std.fmt.parseInt(i64, t, 10) catch 0;
            switch (idx) {
                4 => info.ppid = v,
                5 => info.pgrp = v,
                6 => info.sid = v,
                22 => info.start = @intCast(@max(v, 0)),
                else => {},
            }
        }
        var cb: [64]u8 = undefined;
        if (readSmall(std.fmt.bufPrint(&cb, "/proc/{d}/cmdline", .{pid}) catch "")) |cl| {
            var o = u.Vec(u8).init(u.alloc);
            var trimmed: []const u8 = cl;
            while (trimmed.len > 0 and trimmed[trimmed.len - 1] == 0) trimmed = trimmed[0 .. trimmed.len - 1];
            for (trimmed) |b| o.push(if (b == 0) ' ' else b);
            info.cmdline = o.items;
        }
        var sb: [64]u8 = undefined;
        if (readSmall(std.fmt.bufPrint(&sb, "/proc/{d}/status", .{pid}) catch "")) |stt| {
            var lines = std.mem.splitScalar(u8, stt, '\n');
            while (lines.next()) |l| if (std.mem.startsWith(u8, l, "Uid:")) {
                var tt = std.mem.tokenizeAny(u8, l[4..], " \t");
                info.uid = std.fmt.parseInt(u32, tt.next() orelse "0", 10) catch 0;
                info.euid = std.fmt.parseInt(u32, tt.next() orelse "0", 10) catch 0;
            };
        }
        out.push(info);
    }
    return out.items;
}

fn uidOf(s: []const u8) ?u32 {
    if (std.fmt.parseInt(u32, s, 10)) |v| return v else |_| {}
    return u.findUser(s);
}

pub fn pidof(args: []const []const u8) u8 {
    var single = false;
    var omit = u.Vec(i64).init(u.alloc);
    var names = u.Vec([]const u8).init(u.alloc);
    var i: usize = 0;
    var script = false;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-s")) single = true else if (std.mem.eql(u8, a, "-x")) script = true else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "-q")) {} else if (std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i < args.len) {
                var it = std.mem.tokenizeScalar(u8, args[i], ',');
                while (it.next()) |t| omit.push(if (std.mem.eql(u8, t, "%PPID")) @as(i64, c.getppid()) else std.fmt.parseInt(i64, t, 10) catch -1);
            }
        } else names.push(a);
    }
    if (names.items.len == 0) return 1;
    const me: i64 = c.getpid();
    var procs = listProcs();
    // highest pid first (newest), like procps pidof
    std.mem.sort(ProcInfo, procs[0..], {}, struct {
        fn lt(_: void, a: ProcInfo, b: ProcInfo) bool {
            return a.pid > b.pid;
        }
    }.lt);
    var o = u.Vec(u8).init(u.alloc);
    var found = false;
    for (procs) |pr| {
        if (pr.pid == me) continue;
        var skip = false;
        for (omit.items) |om| if (om == pr.pid) {
            skip = true;
        };
        if (skip) continue;
        for (names.items) |nm| {
            const base = u.basename(nm);
            var match = std.mem.eql(u8, pr.comm, base) or (base.len > 15 and std.mem.eql(u8, pr.comm, base[0..15]));
            if (!match) {
                // argv[0] basename (also scripts when -x)
                var it = std.mem.tokenizeScalar(u8, pr.cmdline, ' ');
                const a0 = it.next() orelse "";
                if (std.mem.eql(u8, u.basename(a0), base)) match = true;
                if (!match and script) {
                    if (it.next()) |a1| if (std.mem.eql(u8, u.basename(a1), base)) {
                        match = true;
                    };
                }
            }
            if (match) {
                if (found) o.push(' ');
                o.pushSlice(std.fmt.allocPrint(u.alloc, "{d}", .{pr.pid}) catch "");
                found = true;
                break;
            }
        }
        if (found and single) break;
    }
    if (found) {
        o.push('\n');
        u.out(o.items);
        return 0;
    }
    return 1;
}

fn pgrepCommon(args: []const []const u8, is_pkill: bool) u8 {
    const prog: []const u8 = if (is_pkill) "pkill" else "pgrep";
    // pkill -SIGNAL shorthand
    var sig: u32 = 15;
    var a2 = u.Vec([]const u8).init(u.alloc);
    for (args) |a| {
        if (is_pkill and a.len > 1 and a[0] == '-' and a[1] != '-' and std.mem.indexOfScalar(u8, "flxvinoaucdsgPUGtSeVh", a[1]) == null) {
            if (kill_mod.sigNum(a[1..])) |sn| {
                sig = sn;
                continue;
            }
        }
        a2.push(a);
    }
    const opts = [_]g.Opt{
        .{ .name = "full", .key = 'f' },
        .{ .name = "exact", .key = 'x' },
        .{ .name = "newest", .key = 'n' },
        .{ .name = "oldest", .key = 'o' },
        .{ .name = "euid", .key = 'u', .arg = .req },
        .{ .name = "uid", .key = 'U', .arg = .req },
        .{ .name = "parent", .key = 'P', .arg = .req },
        .{ .name = "pgroup", .key = 'g', .arg = .req },
        .{ .name = "session", .key = 's', .arg = .req },
        .{ .name = "list-name", .key = 'l' },
        .{ .name = "list-full", .key = 'a' },
        .{ .name = "count", .key = 'c' },
        .{ .name = "delimiter", .key = 'd', .arg = .req },
        .{ .name = "inverse", .key = 'v' },
        .{ .name = "ignore-case", .key = 'i' },
        .{ .name = "signal", .key = 'S', .arg = .req },
        .{ .name = "help", .key = HELP },
        .{ .name = "version", .key = 'V' },
    };
    var p = g.Parser.init(prog, a2.items, &opts);
    var full = false;
    var exact = false;
    var newest = false;
    var oldest = false;
    var list_name = false;
    var list_full = false;
    var count = false;
    var inverse = false;
    var icase = false;
    var delim: []const u8 = "\n";
    var euid: ?u32 = null;
    var ruid: ?u32 = null;
    var parent: ?i64 = null;
    var pgrp: ?i64 = null;
    var sess: ?i64 = null;
    while (p.next() catch return 2) |it| {
        switch (it.key) {
            'f' => full = true,
            'x' => exact = true,
            'n' => newest = true,
            'o' => oldest = true,
            'u' => euid = uidOf(it.val.?) orelse {
                u.errf("{s}: invalid user name: {s}\n", .{ prog, it.val.? });
                return 2;
            },
            'U' => ruid = uidOf(it.val.?) orelse {
                u.errf("{s}: invalid user name: {s}\n", .{ prog, it.val.? });
                return 2;
            },
            'P' => parent = std.fmt.parseInt(i64, it.val.?, 10) catch return 2,
            'g' => pgrp = std.fmt.parseInt(i64, it.val.?, 10) catch return 2,
            's' => sess = std.fmt.parseInt(i64, it.val.?, 10) catch return 2,
            'l' => list_name = true,
            'a' => list_full = true,
            'c' => count = true,
            'd' => delim = it.val.?,
            'v' => inverse = true,
            'i' => icase = true,
            'S' => sig = kill_mod.sigNum(it.val.?) orelse return 2,
            HELP => {
                u.outf("Usage:\n {s} [options] <pattern>\n", .{prog});
                return 0;
            },
            'V' => {
                u.outf("{s} (cmdbox)\n", .{prog});
                return 0;
            },
            else => {},
        }
    }
    const pattern: ?[]const u8 = if (p.operands.items.len > 0) p.operands.items[0] else null;
    if (pattern == null and euid == null and ruid == null and parent == null and pgrp == null and sess == null) {
        u.errf("{s}: no matching criteria specified\nTry `{s} --help' for more information.\n", .{ prog, prog });
        return 2;
    }
    var re: c.regex_t = undefined;
    var have_re = false;
    if (pattern) |pat| {
        const src = if (exact) std.fmt.allocPrint(u.alloc, "^({s})$", .{pat}) catch return 2 else pat;
        if (c.regcomp(&re, u.zstr(src).ptr, c.REG_EXTENDED | c.REG_NOSUB | (if (icase) c.REG_ICASE else 0)) != 0) {
            u.errf("{s}: regex error\n", .{prog});
            return 2;
        }
        have_re = true;
    }
    const me: i64 = c.getpid();
    var matches = u.Vec(ProcInfo).init(u.alloc);
    for (listProcs()) |pr| {
        if (pr.pid == me) continue;
        var ok = true;
        if (euid != null and pr.euid != euid.?) ok = false;
        if (ruid != null and pr.uid != ruid.?) ok = false;
        if (parent != null and pr.ppid != parent.?) ok = false;
        if (pgrp != null and pr.pgrp != pgrp.?) ok = false;
        if (sess != null and pr.sid != sess.?) ok = false;
        if (ok and have_re) {
            const subj = if (full and pr.cmdline.len > 0) pr.cmdline else pr.comm;
            ok = c.regexec(&re, u.zstr(subj).ptr, 0, null, 0) == 0;
        }
        if (inverse) ok = !ok;
        if (ok) matches.push(pr);
    }
    if (have_re) c.regfree(&re);
    var sel = matches.items;
    if (newest or oldest) {
        if (sel.len > 0) {
            var best = sel[0];
            for (sel) |m| {
                if (newest and (m.start > best.start or (m.start == best.start and m.pid > best.pid))) best = m;
                if (oldest and (m.start < best.start or (m.start == best.start and m.pid < best.pid))) best = m;
            }
            sel = u.alloc.dupe(ProcInfo, &.{best}) catch return 2;
        }
    }
    if (sel.len == 0) {
        if (count) u.out("0\n");
        return 1;
    }
    if (is_pkill) {
        var rc: u8 = 0;
        for (sel) |m| {
            const r = linux.syscall2(.kill, @bitCast(@as(isize, @intCast(m.pid))), sig);
            if (!u.ok(r)) {
                u.errf("pkill: killing pid {d} failed: {s}\n", .{ m.pid, u.strerr(u.errno(r)) });
                rc = 1;
            } else if (list_name or list_full) u.outf("{s} killed (pid {d})\n", .{ m.comm, m.pid });
        }
        return rc;
    }
    if (count) {
        u.outf("{d}\n", .{sel.len});
        return 0;
    }
    std.mem.sort(ProcInfo, sel, {}, struct {
        fn lt(_: void, a: ProcInfo, b: ProcInfo) bool {
            return a.pid < b.pid;
        }
    }.lt);
    var o = u.Vec(u8).init(u.alloc);
    for (sel, 0..) |m, i| {
        if (i > 0) o.pushSlice(delim);
        if (list_full) o.pushSlice(std.fmt.allocPrint(u.alloc, "{d} {s}", .{ m.pid, if (m.cmdline.len > 0) m.cmdline else m.comm }) catch "") else if (list_name) o.pushSlice(std.fmt.allocPrint(u.alloc, "{d} {s}", .{ m.pid, m.comm }) catch "") else o.pushSlice(std.fmt.allocPrint(u.alloc, "{d}", .{m.pid}) catch "");
    }
    o.pushSlice(if (std.mem.eql(u8, delim, "\n")) "\n" else "\n");
    u.out(o.items);
    return 0;
}

pub fn pgrep(args: []const []const u8) u8 {
    return pgrepCommon(args, false);
}

pub fn pkill(args: []const []const u8) u8 {
    return pgrepCommon(args, true);
}
