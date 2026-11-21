// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// ps - procps compatible: UNIX (-e -A -a -x -f -F -l -j -o -p -C -u -U --sort ...) and BSD (aux, ax, ...) syntax
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const dt = @import("datetime.zig");
const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("grp.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
});

const Col = enum {
    pid, ppid, pgid, sid, tid, uid, gid, user, ruser, group, tty, time, cmd, args, comm, stat, s, pcpu, pmem,
    vsz, rss, ni, pri, c, stime, start, etime, nlwp, wchan, psr, f, addr, sz,
};

const ColDef = struct { names: []const []const u8, header: []const u8, width: usize, left: bool = false };

fn defs(col: Col) ColDef {
    return switch (col) {
        .pid => .{ .names = &.{"pid"}, .header = "PID", .width = pid_width },
        .ppid => .{ .names = &.{"ppid"}, .header = "PPID", .width = pid_width },
        .pgid => .{ .names = &.{ "pgid", "pgrp" }, .header = "PGID", .width = pid_width },
        .sid => .{ .names = &.{ "sid", "sess", "session" }, .header = "SID", .width = pid_width },
        .tid => .{ .names = &.{ "tid", "spid", "lwp" }, .header = "TID", .width = pid_width },
        .uid => .{ .names = &.{ "uid", "euid" }, .header = "UID", .width = 5 },
        .gid => .{ .names = &.{ "gid", "egid" }, .header = "GID", .width = 5 },
        .user => .{ .names = &.{ "user", "euser", "uname" }, .header = "USER", .width = 8, .left = true },
        .ruser => .{ .names = &.{ "ruser", "ruid" }, .header = "RUSER", .width = 8, .left = true },
        .group => .{ .names = &.{ "group", "egroup" }, .header = "GROUP", .width = 8, .left = true },
        .tty => .{ .names = &.{ "tty", "tt", "tname" }, .header = "TTY", .width = 8, .left = true },
        .time => .{ .names = &.{ "time", "cputime" }, .header = "TIME", .width = 8 },
        .cmd => .{ .names = &.{ "cmd", "command" }, .header = "CMD", .width = 0, .left = true },
        .args => .{ .names = &.{ "args", "cmdline" }, .header = "COMMAND", .width = 0, .left = true },
        .comm => .{ .names = &.{ "comm", "ucmd", "ucomm", "fname" }, .header = "COMMAND", .width = 0, .left = true },
        .stat => .{ .names = &.{"stat"}, .header = "STAT", .width = 4, .left = true },
        .s => .{ .names = &.{ "s", "state" }, .header = "S", .width = 1, .left = true },
        .pcpu => .{ .names = &.{ "pcpu", "%cpu", "cp" }, .header = "%CPU", .width = 4 },
        .pmem => .{ .names = &.{ "pmem", "%mem" }, .header = "%MEM", .width = 4 },
        .vsz => .{ .names = &.{ "vsz", "vsize", "vsz_" }, .header = "VSZ", .width = 6 },
        .rss => .{ .names = &.{ "rss", "rssize", "rsz" }, .header = "RSS", .width = 5 },
        .ni => .{ .names = &.{ "ni", "nice" }, .header = "NI", .width = 3 },
        .pri => .{ .names = &.{"pri"}, .header = "PRI", .width = 3 },
        .c => .{ .names = &.{ "c", "util" }, .header = "C", .width = 2 },
        .stime => .{ .names = &.{"stime"}, .header = "STIME", .width = 5, .left = true },
        .start => .{ .names = &.{ "start", "start_time", "bsdstart" }, .header = "START", .width = 5, .left = true },
        .etime => .{ .names = &.{"etime"}, .header = "ELAPSED", .width = 11 },
        .nlwp => .{ .names = &.{ "nlwp", "thcount" }, .header = "NLWP", .width = 4 },
        .wchan => .{ .names = &.{"wchan"}, .header = "WCHAN", .width = 6, .left = true },
        .psr => .{ .names = &.{"psr"}, .header = "PSR", .width = 3 },
        .f => .{ .names = &.{ "f", "flag", "flags" }, .header = "F", .width = 1 },
        .addr => .{ .names = &.{"addr"}, .header = "ADDR", .width = 4 },
        .sz => .{ .names = &.{"sz"}, .header = "SZ", .width = 6 },
    };
}

var pid_width: usize = 5;

const Proc = struct {
    pid: i64 = 0,
    comm: []const u8 = "",
    state: u8 = '?',
    ppid: i64 = 0,
    pgrp: i64 = 0,
    sid: i64 = 0,
    tty_nr: u64 = 0,
    tpgid: i64 = 0,
    flags: u64 = 0,
    utime: u64 = 0,
    stime: u64 = 0,
    prio: i64 = 0,
    nice: i64 = 0,
    nlwp: i64 = 0,
    starttime: u64 = 0,
    vsize: u64 = 0,
    rss: i64 = 0,
    processor: i64 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    ruid: u32 = 0,
    cmdline: []const u8 = "",
    locked: bool = false,
};

fn readFile(path: []const u8) ?[]const u8 {
    var f = u.File.open(path, .{ .ACCMODE = .RDONLY }, 0) orelse return null;
    defer f.close();
    var all = u.Vec(u8).init(u.alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = f.read(&buf);
        if (n == 0) break;
        for (buf[0..n]) |b| all.push(b);
    }
    return all.items;
}

fn loadProc(pid: i64) ?Proc {
    var pb: [64]u8 = undefined;
    const sp = std.fmt.bufPrint(&pb, "/proc/{d}/stat", .{pid}) catch return null;
    const text = readFile(sp) orelse return null;
    const lp = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    const rp = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    var p = Proc{ .pid = pid, .comm = text[lp + 1 .. rp] };
    var it = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, text[rp + 1 ..], "\n"), ' ');
    var idx: usize = 3;
    while (it.next()) |t| : (idx += 1) {
        const n = std.fmt.parseInt(i64, t, 10) catch 0;
        switch (idx) {
            3 => p.state = t[0],
            4 => p.ppid = n,
            5 => p.pgrp = n,
            6 => p.sid = n,
            7 => p.tty_nr = @intCast(@max(n, 0)),
            8 => p.tpgid = n,
            9 => p.flags = @intCast(@max(n, 0)),
            14 => p.utime = @intCast(@max(n, 0)),
            15 => p.stime = @intCast(@max(n, 0)),
            18 => p.prio = n,
            19 => p.nice = n,
            20 => p.nlwp = n,
            22 => p.starttime = @intCast(@max(n, 0)),
            23 => p.vsize = @intCast(@max(n, 0)),
            24 => p.rss = n,
            39 => p.processor = n,
            else => {},
        }
    }
    var dp: [64]u8 = undefined;
    const dir = std.fmt.bufPrint(&dp, "/proc/{d}", .{pid}) catch return null;
    const st = u.stat(dir, true) orelse return null;
    p.uid = st.uid;
    p.gid = st.gid;
    p.ruid = st.uid;
    var sb: [64]u8 = undefined;
    if (readFile(std.fmt.bufPrint(&sb, "/proc/{d}/status", .{pid}) catch "")) |stt| {
        var lines = std.mem.splitScalar(u8, stt, '\n');
        while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, "Uid:")) {
                var t = std.mem.tokenizeAny(u8, l[4..], " \t");
                p.ruid = std.fmt.parseInt(u32, t.next() orelse "0", 10) catch st.uid;
            } else if (std.mem.startsWith(u8, l, "VmLck:")) {
                var t = std.mem.tokenizeAny(u8, l[6..], " \t");
                p.locked = (std.fmt.parseInt(u64, t.next() orelse "0", 10) catch 0) > 0;
            }
        }
    }
    var cb: [64]u8 = undefined;
    if (readFile(std.fmt.bufPrint(&cb, "/proc/{d}/cmdline", .{pid}) catch "")) |cl| {
        var o = u.Vec(u8).init(u.alloc);
        var trimmed = cl;
        while (trimmed.len > 0 and trimmed[trimmed.len - 1] == 0) trimmed = trimmed[0 .. trimmed.len - 1];
        for (trimmed) |b| o.push(if (b == 0) ' ' else b);
        p.cmdline = o.items;
    }
    return p;
}

fn userName(uid: u32) []const u8 {
    if (c.getpwuid(uid)) |p| return std.mem.sliceTo(p.*.pw_name, 0);
    return std.fmt.allocPrint(u.alloc, "{d}", .{uid}) catch "?";
}
fn groupName(gid: u32) []const u8 {
    if (c.getgrgid(gid)) |p| return std.mem.sliceTo(p.*.gr_name, 0);
    return std.fmt.allocPrint(u.alloc, "{d}", .{gid}) catch "?";
}

fn ttyName(nr: u64) []const u8 {
    if (nr == 0) return "?";
    const major = (nr >> 8) & 0xfff;
    const minor = (nr & 0xff) | ((nr >> 12) & 0xfff00);
    if (major == 136) return std.fmt.allocPrint(u.alloc, "pts/{d}", .{minor}) catch "?";
    if (major == 4) {
        if (minor < 64) return std.fmt.allocPrint(u.alloc, "tty{d}", .{minor}) catch "?";
        return std.fmt.allocPrint(u.alloc, "ttyS{d}", .{minor - 64}) catch "?";
    }
    if (major == 5 and minor == 0) return "tty";
    if (major == 5 and minor == 1) return "console";
    if (major == 188) return std.fmt.allocPrint(u.alloc, "ttyUSB{d}", .{minor}) catch "?";
    if (major == 204) return std.fmt.allocPrint(u.alloc, "ttyAMA{d}", .{minor}) catch "?";
    return "?";
}

var hertz: u64 = 100;
var boot_time: i64 = 0;
var now_secs: i64 = 0;
var mem_total_kb: u64 = 1;
var page_kb: u64 = 4;

fn fmtTime(secs: u64, bsd: bool) []const u8 {
    if (bsd) return std.fmt.allocPrint(u.alloc, "{d}:{d:0>2}", .{ secs / 60, secs % 60 }) catch "";
    const d = secs / 86400;
    const h = (secs / 3600) % 24;
    const m = (secs / 60) % 60;
    const s = secs % 60;
    if (d > 0) return std.fmt.allocPrint(u.alloc, "{d}-{d:0>2}:{d:0>2}:{d:0>2}", .{ d, h, m, s }) catch "";
    return std.fmt.allocPrint(u.alloc, "{d:0>2}:{d:0>2}:{d:0>2}", .{ secs / 3600, m, s }) catch "";
}

fn startEpoch(p: Proc) i64 {
    return boot_time + @as(i64, @intCast(p.starttime / hertz));
}

fn fmtStart(p: Proc) []const u8 {
    const t = startEpoch(p);
    const tm = dt.localtime(t);
    var buf: [32]u8 = undefined;
    const age = now_secs - t;
    const fmt: [*c]const u8 = if (age < 86400) "%H:%M" else if (age < 86400 * 364) "%b%d" else "%Y";
    const n = dt.c.strftime(&buf, buf.len, fmt, &tm);
    return u.alloc.dupe(u8, buf[0..n]) catch "";
}

fn statStr(p: Proc) []const u8 {
    var o = u.Vec(u8).init(u.alloc);
    o.push(p.state);
    if (p.nice < 0) o.push('<');
    if (p.nice > 0) o.push('N');
    if (p.locked) o.push('L');
    if (p.sid == p.pid) o.push('s');
    if (p.nlwp > 1) o.push('l');
    if (p.tpgid != -1 and p.pgrp == p.tpgid and p.tty_nr != 0) o.push('+');
    return o.items;
}

fn cpuPercent(p: Proc) f64 {
    const elapsed = @as(f64, @floatFromInt(@max(now_secs - startEpoch(p), 1)));
    const cpu = @as(f64, @floatFromInt(p.utime + p.stime)) / @as(f64, @floatFromInt(hertz));
    return @min(cpu * 100.0 / elapsed, 999.9);
}

fn cell(col: Col, p: Proc, bsd: bool, cmd_full: bool) []const u8 {
    return switch (col) {
        .pid, .tid => std.fmt.allocPrint(u.alloc, "{d}", .{p.pid}) catch "",
        .ppid => std.fmt.allocPrint(u.alloc, "{d}", .{p.ppid}) catch "",
        .pgid => std.fmt.allocPrint(u.alloc, "{d}", .{p.pgrp}) catch "",
        .sid => std.fmt.allocPrint(u.alloc, "{d}", .{p.sid}) catch "",
        .uid => if (bsd) userName(p.uid) else std.fmt.allocPrint(u.alloc, "{d}", .{p.uid}) catch "",
        .gid => std.fmt.allocPrint(u.alloc, "{d}", .{p.gid}) catch "",
        .user => userName(p.uid),
        .ruser => userName(p.ruid),
        .group => groupName(p.gid),
        .tty => ttyName(p.tty_nr),
        .time => fmtTime((p.utime + p.stime) / hertz, bsd),
        .cmd, .args => blk: {
            if (p.state == 'Z') break :blk std.fmt.allocPrint(u.alloc, "[{s}] <defunct>", .{p.comm}) catch "";
            if (cmd_full and p.cmdline.len > 0) break :blk p.cmdline;
            if (cmd_full) break :blk std.fmt.allocPrint(u.alloc, "[{s}]", .{p.comm}) catch "";
            break :blk p.comm;
        },
        .comm => p.comm,
        .stat => statStr(p),
        .s => &[_]u8{p.state},
        .pcpu => std.fmt.allocPrint(u.alloc, "{d:.1}", .{cpuPercent(p)}) catch "",
        .pmem => std.fmt.allocPrint(u.alloc, "{d:.1}", .{@as(f64, @floatFromInt(@as(u64, @intCast(@max(p.rss, 0))) * page_kb)) * 100.0 / @as(f64, @floatFromInt(mem_total_kb))}) catch "",
        .vsz => std.fmt.allocPrint(u.alloc, "{d}", .{p.vsize / 1024}) catch "",
        .rss => std.fmt.allocPrint(u.alloc, "{d}", .{@as(u64, @intCast(@max(p.rss, 0))) * page_kb}) catch "",
        .ni => if (p.nice == 0 and false) "-" else std.fmt.allocPrint(u.alloc, "{d}", .{p.nice}) catch "",
        .pri => std.fmt.allocPrint(u.alloc, "{d}", .{19 - (p.prio - 20)}) catch "",
        .c => std.fmt.allocPrint(u.alloc, "{d}", .{@as(u64, @intFromFloat(@min(cpuPercent(p), 99.0)))}) catch "",
        .stime, .start => fmtStart(p),
        .etime => blk: {
            const e: u64 = @intCast(@max(now_secs - startEpoch(p), 0));
            const d = e / 86400;
            const h = (e / 3600) % 24;
            const m = (e / 60) % 60;
            const s = e % 60;
            if (d > 0) break :blk std.fmt.allocPrint(u.alloc, "{d}-{d:0>2}:{d:0>2}:{d:0>2}", .{ d, h, m, s }) catch "";
            if (h > 0) break :blk std.fmt.allocPrint(u.alloc, "{d:0>2}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch "";
            break :blk std.fmt.allocPrint(u.alloc, "{d:0>2}:{d:0>2}", .{ m, s }) catch "";
        },
        .nlwp => std.fmt.allocPrint(u.alloc, "{d}", .{p.nlwp}) catch "",
        .wchan => "-",
        .psr => std.fmt.allocPrint(u.alloc, "{d}", .{p.processor}) catch "",
        .f => std.fmt.allocPrint(u.alloc, "{d}", .{if (p.flags & 0x40 != 0) @as(u8, 1) else 0}) catch "",
        .addr => "-",
        .sz => std.fmt.allocPrint(u.alloc, "{d}", .{p.vsize / 4096}) catch "",
    };
}

fn colByName(n: []const u8) ?Col {
    var low: [32]u8 = undefined;
    if (n.len > low.len) return null;
    for (n, 0..) |ch, i| low[i] = std.ascii.toLower(ch);
    const l = low[0..n.len];
    inline for (@typeInfo(Col).@"enum".fields) |f| {
        const col: Col = @enumFromInt(f.value);
        for (defs(col).names) |nm| if (std.mem.eql(u8, nm, l)) return col;
    }
    return null;
}

const Spec = struct { col: Col, header: ?[]const u8 = null };

fn die(comptime fmt: []const u8, args: anytype) u8 {
    u.errf("ps: " ++ fmt ++ "\n", args);
    return 1;
}

fn parseList(s: []const u8, out: *u.Vec([]const u8)) void {
    var it = std.mem.tokenizeAny(u8, s, ", ");
    while (it.next()) |t| out.push(t);
}

pub fn run(args: []const []const u8) u8 {
    var all = false; // -e / -A
    var sel_a = false; // -a (tty, not session leaders)
    var sel_bsd_a = false; // a
    var sel_x = false; // x
    var sel_d = false;
    var sel_r = false;
    var pids = u.Vec(i64).init(u.alloc);
    var cmds = u.Vec([]const u8).init(u.alloc);
    var users = u.Vec([]const u8).init(u.alloc);
    var any_sel = false;
    var fmt_kind: u8 = 0; // 'f','F','l','j','u','v', 's'
    var bsd_style = false;
    var headers = true;
    var width_mode: u8 = 0; // 0 auto, 1 w, 2 ww
    var sorts = u.Vec([]const u8).init(u.alloc);
    var forest = false;
    _ = &forest;
    var i: usize = 0;
    var extra_o = u.Vec(Spec).init(u.alloc);
    var have_o = false;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len > 1 and a[0] == '-' and a[1] == '-') {
            const name_end = std.mem.indexOfScalar(u8, a, '=') orelse a.len;
            const name = a[2..name_end];
            var val: ?[]const u8 = if (name_end < a.len) a[name_end + 1 ..] else null;
            if (std.mem.eql(u8, name, "no-headers") or std.mem.eql(u8, name, "no-heading")) {
                headers = false;
            } else if (std.mem.eql(u8, name, "headers")) {
                headers = true;
            } else if (std.mem.eql(u8, name, "forest")) {
                forest = true;
            } else if (std.mem.eql(u8, name, "help")) {
                u.out("\nUsage:\n ps [options]\n\n Try 'ps --help <simple|list|output|threads|misc|all>'\n  or 'ps --help <s|l|o|t|m|a>'\n for additional help text.\n");
                return 0;
            } else if (std.mem.eql(u8, name, "version")) {
                u.out("ps (cmdbox)\n");
                return 0;
            } else if (std.mem.eql(u8, name, "sort") or std.mem.eql(u8, name, "pid") or std.mem.eql(u8, name, "user") or std.mem.eql(u8, name, "width") or std.mem.eql(u8, name, "cols") or std.mem.eql(u8, name, "columns") or std.mem.eql(u8, name, "format") or std.mem.eql(u8, name, "ppid")) {
                if (val == null) {
                    if (i + 1 >= args.len) return die("option '--{s}' requires an argument", .{name});
                    i += 1;
                    val = args[i];
                }
                if (std.mem.eql(u8, name, "sort")) parseList(val.?, &sorts) else if (std.mem.eql(u8, name, "pid")) {
                    any_sel = true;
                    var l = u.Vec([]const u8).init(u.alloc);
                    parseList(val.?, &l);
                    for (l.items) |t| pids.push(std.fmt.parseInt(i64, t, 10) catch return die("process ID list syntax error", .{}));
                } else if (std.mem.eql(u8, name, "user")) {
                    any_sel = true;
                    parseList(val.?, &users);
                } else if (std.mem.eql(u8, name, "format")) {
                    have_o = true;
                    if (!addFormat(val.?, &extra_o)) return 1;
                }
            } else {
                u.errf("ps: unrecognized option '--{s}'\n", .{name});
                return 1;
            }
            continue;
        }
        const unix = a.len > 1 and a[0] == '-';
        if (!unix and i > 0 and false) {}
        var k: usize = if (unix) 1 else 0;
        if (!unix) {
            bsd_style = bsd_style or true;
            // a bare number list is a pid list in BSD syntax
            if (a.len > 0 and std.ascii.isDigit(a[0])) {
                var l = u.Vec([]const u8).init(u.alloc);
                parseList(a, &l);
                any_sel = true;
                for (l.items) |t| pids.push(std.fmt.parseInt(i64, t, 10) catch return die("process ID list syntax error", .{}));
                continue;
            }
        }
        while (k < a.len) : (k += 1) {
            const ch = a[k];
            const takes_arg = std.mem.indexOfScalar(u8, if (unix) "pCuUoOtgGsq" else "pOotU", ch) != null;
            if (takes_arg) {
                var v: []const u8 = undefined;
                if (k + 1 < a.len) {
                    v = a[k + 1 ..];
                } else if (i + 1 < args.len) {
                    i += 1;
                    v = args[i];
                } else return die("option requires an argument -- '{c}'", .{ch});
                k = a.len;
                switch (ch) {
                    'p', 'q' => {
                        any_sel = true;
                        var l = u.Vec([]const u8).init(u.alloc);
                        parseList(v, &l);
                        for (l.items) |t| pids.push(std.fmt.parseInt(i64, t, 10) catch return die("process ID list syntax error", .{}));
                    },
                    'C' => {
                        any_sel = true;
                        parseList(v, &cmds);
                    },
                    'u', 'U' => {
                        any_sel = true;
                        parseList(v, &users);
                    },
                    'o', 'O' => {
                        have_o = true;
                        if (!addFormat(v, &extra_o)) return 1;
                    },
                    else => {},
                }
                continue;
            }
            if (unix) {
                switch (ch) {
                    'e', 'A' => all = true,
                    'a' => sel_a = true,
                    'x' => sel_x = true,
                    'd' => sel_d = true,
                    'f' => fmt_kind = if (fmt_kind == 'F') 'F' else 'f',
                    'F' => fmt_kind = 'F',
                    'l' => fmt_kind = 'l',
                    'j' => fmt_kind = 'j',
                    'y', 'H', 'c', 'm', 'L', 'M', 'Z', 'n', 'h' => {
                        if (ch == 'H') forest = true;
                        if (ch == 'h') headers = false;
                    },
                    'w' => width_mode = if (width_mode == 0) 1 else 2,
                    'V' => {
                        u.out("ps (cmdbox)\n");
                        return 0;
                    },
                    else => return die("invalid option -- '{c}'", .{ch}),
                }
            } else {
                switch (ch) {
                    'a' => sel_bsd_a = true,
                    'x' => sel_x = true,
                    'u' => fmt_kind = 'u',
                    'l' => fmt_kind = 'L',
                    'j' => fmt_kind = 'j',
                    'v' => fmt_kind = 'v',
                    's' => fmt_kind = 's',
                    'w' => width_mode = if (width_mode == 0) 1 else 2,
                    'r' => sel_r = true,
                    'e', 'f', 'h', 'n', 'm', 'c', 'S', 'T', 'H', 'L' => {
                        if (ch == 'h') headers = false;
                        if (ch == 'f') forest = true;
                    },
                    '-' => {},
                    else => return die("unsupported option (BSD syntax)", .{}),
                }
            }
        }
    }

    // environment
    if (readFile("/proc/sys/kernel/pid_max")) |pm| {
        const t = std.mem.trim(u8, pm, " \n");
        pid_width = @max(t.len, 5);
    }
    if (readFile("/proc/stat")) |st| {
        var lines = std.mem.splitScalar(u8, st, '\n');
        while (lines.next()) |l| if (std.mem.startsWith(u8, l, "btime ")) {
            boot_time = std.fmt.parseInt(i64, std.mem.trim(u8, l[6..], " "), 10) catch 0;
        };
    }
    if (readFile("/proc/meminfo")) |mi| {
        var lines = std.mem.splitScalar(u8, mi, '\n');
        while (lines.next()) |l| if (std.mem.startsWith(u8, l, "MemTotal:")) {
            var t = std.mem.tokenizeAny(u8, l[9..], " kB");
            mem_total_kb = @max(std.fmt.parseInt(u64, t.next() orelse "1", 10) catch 1, 1);
        };
    }
    hertz = @intCast(@max(c.sysconf(c._SC_CLK_TCK), 1));
    now_secs = u.nowSecs();
    page_kb = @intCast(@max(@divTrunc(c.sysconf(c._SC_PAGESIZE), 1024), 1));

    // format
    var bsd_time = false;
    var cmd_full = false;
    var cols = u.Vec(Spec).init(u.alloc);
    const S = struct {
        fn add(list: *u.Vec(Spec), cl: []const Col) void {
            for (cl) |x| list.push(.{ .col = x });
        }
    };
    if (have_o) {
        for (extra_o.items) |e| cols.push(e);
        for (cols.items) |e| if (e.col == .args or e.col == .cmd) {
            cmd_full = true;
        };
        for (cols.items) |*e| if (e.col == .cmd and e.header == null) {
            e.header = "CMD";
        };
        // comm-style columns stay short
        for (cols.items) |e| if (e.col == .cmd) {
            cmd_full = true;
        };
    } else switch (fmt_kind) {
        'f' => {
            S.add(&cols, &.{ .user, .pid, .ppid, .c, .stime, .tty, .time, .cmd });
            cols.items[0].header = "UID";
            cmd_full = true;
        },
        'F' => {
            S.add(&cols, &.{ .user, .pid, .ppid, .c, .sz, .rss, .psr, .stime, .tty, .time, .cmd });
            cols.items[0].header = "UID";
            cmd_full = true;
        },
        'l' => {
            S.add(&cols, &.{ .f, .s, .uid, .pid, .ppid, .c, .pri, .ni, .addr, .sz, .wchan, .tty, .time, .cmd });
        },
        'j' => {
            if (bsd_style) S.add(&cols, &.{ .ppid, .pid, .pgid, .sid, .tty, .time, .cmd }) else S.add(&cols, &.{ .pid, .pgid, .sid, .tty, .time, .cmd });
        },
        'u' => {
            S.add(&cols, &.{ .user, .pid, .pcpu, .pmem, .vsz, .rss, .tty, .stat, .start, .time, .args });
            bsd_time = true;
            cmd_full = true;
        },
        'L' => {
            S.add(&cols, &.{ .f, .uid, .pid, .ppid, .pri, .ni, .vsz, .rss, .wchan, .stat, .tty, .time, .args });
            bsd_time = true;
            cmd_full = true;
        },
        'v' => {
            S.add(&cols, &.{ .pid, .tty, .stat, .time, .rss, .pmem, .args });
            bsd_time = true;
            cmd_full = true;
        },
        's' => {
            S.add(&cols, &.{ .uid, .pid, .tty, .stat, .time, .args });
            bsd_time = true;
            cmd_full = true;
        },
        else => {
            if (bsd_style) {
                S.add(&cols, &.{ .pid, .tty, .stat, .time, .args });
                bsd_time = true;
                cmd_full = true;
            } else S.add(&cols, &.{ .pid, .tty, .time, .cmd });
        },
    }
    if (fmt_kind == 'f' or fmt_kind == 'F') {}

    // selection
    var self_tty: u64 = 0;
    var self_euid: u32 = @intCast(c.geteuid());
    if (loadProc(@intCast(c.getpid()))) |me| self_tty = me.tty_nr;
    _ = &self_euid;
    var uidset = u.Vec(u32).init(u.alloc);
    for (users.items) |un| {
        if (c.getpwnam(u.zstr(un))) |pw| {
            uidset.push(pw.*.pw_uid);
        } else if (std.fmt.parseInt(u32, un, 10)) |v| uidset.push(v) else |_| return die("user name does not exist", .{});
    }
    var procs = u.Vec(Proc).init(u.alloc);
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir("/proc", &ents)) return die("error: can not access /proc.", .{});
    for (ents.items) |e| {
        const pid = std.fmt.parseInt(i64, e.name, 10) catch continue;
        const p = loadProc(pid) orelse continue;
        var take = false;
        if (all) take = true;
        if (sel_bsd_a and p.tty_nr != 0 and !sel_x) take = true;
        if (sel_bsd_a and sel_x) take = true;
        if (sel_x and !sel_bsd_a and p.uid == self_euid) take = true;
        if (sel_a and p.tty_nr != 0 and p.sid != p.pid) take = true;
        if (sel_d and p.sid != p.pid) take = true;
        for (pids.items) |q| if (q == pid) {
            take = true;
        };
        for (cmds.items) |nm| if (std.mem.eql(u8, nm, p.comm)) {
            take = true;
        };
        for (uidset.items) |q| if (q == p.uid) {
            take = true;
        };
        if (!take and !all and !sel_a and !sel_d and !sel_bsd_a and !sel_x and !any_sel) {
            take = p.uid == self_euid and p.tty_nr == self_tty;
        }
        if (sel_r and p.state != 'R') take = false;
        if (take) procs.push(p);
    }
    // ps itself is listed like any other process (procps does too)

    // sort
    if (sorts.items.len > 0) {
        const Ctx = struct { keys: []const []const u8 };
        const ctx = Ctx{ .keys = sorts.items };
        std.mem.sort(Proc, procs.items, ctx, struct {
            fn lt(cx: Ctx, a: Proc, b: Proc) bool {
                for (cx.keys) |key| {
                    var k = key;
                    var desc = false;
                    if (k.len > 0 and (k[0] == '-' or k[0] == '+')) {
                        desc = k[0] == '-';
                        k = k[1..];
                    }
                    const col = colByName(k) orelse continue;
                    const x = cell(col, a, false, true);
                    const y = cell(col, b, false, true);
                    const nx = std.fmt.parseFloat(f64, x) catch null;
                    const ny = std.fmt.parseFloat(f64, y) catch null;
                    var ord: std.math.Order = undefined;
                    if (nx != null and ny != null) ord = std.math.order(nx.?, ny.?) else ord = std.mem.order(u8, x, y);
                    if (ord == .eq) continue;
                    return if (desc) ord == .gt else ord == .lt;
                }
                return a.pid < b.pid;
            }
        }.lt);
    } else {
        std.mem.sort(Proc, procs.items, {}, struct {
            fn lt(_: void, a: Proc, b: Proc) bool {
                return a.pid < b.pid;
            }
        }.lt);
    }

    // render
    var ws: extern struct { row: u16, col: u16, x: u16, y: u16 } = undefined;
    var term_cols: usize = 0;
    if (u.ok(linux.ioctl(1, 0x5413, @intFromPtr(&ws))) and ws.col > 0) term_cols = ws.col;
    const limit: usize = switch (width_mode) {
        0 => term_cols, // 0 = unlimited when piped
        1 => if (term_cols > 132) term_cols else 132,
        else => 0,
    };
    var o = u.Vec(u8).init(u.alloc);
    const nc = cols.items.len;
    const emit = struct {
        fn line(out: *u.Vec(u8), cs: []Spec, texts: []const []const u8, bsd_t: bool, lim: usize) void {
            var ln = u.Vec(u8).init(u.alloc);
            for (cs, 0..) |sp, idx| {
                const d = defs(sp.col);
                var w = d.width;
                if (bsd_t and sp.col == .time) w = 6;
                const t = texts[idx];
                const last = idx == cs.len - 1;
                if (idx > 0) ln.push(' ');
                if (last and (d.width == 0 or d.left)) {
                    for (t) |ch| ln.push(ch);
                } else if (d.left) {
                    var shown = t;
                    if (shown.len > w and w > 1) shown = shown[0 .. w - 1];
                    for (shown) |ch| ln.push(ch);
                    if (t.len > w and w > 1) ln.push('+');
                    var k = shown.len + @as(usize, @intFromBool(t.len > w and w > 1));
                    while (k < w) : (k += 1) ln.push(' ');
                } else {
                    var k = t.len;
                    while (k < w) : (k += 1) ln.push(' ');
                    for (t) |ch| ln.push(ch);
                }
            }
            var s = ln.items;
            if (lim > 0 and s.len > lim) s = s[0..lim];
            for (s) |ch| out.push(ch);
            out.push('\n');
        }
    }.line;
    if (headers) {
        var hs = u.Vec([]const u8).init(u.alloc);
        for (cols.items) |sp| hs.push(sp.header orelse defs(sp.col).header);
        // BSD-style 'u' uses COMMAND for the last column, 'f'/'-ef' use CMD
        emit(&o, cols.items, hs.items, bsd_time, limit);
    }
    for (procs.items) |p| {
        var ts = u.Vec([]const u8).init(u.alloc);
        for (cols.items) |sp| {
            var col = sp.col;
            if (col == .cmd and !cmd_full) col = .comm;
            if (col == .cmd and cmd_full) col = .args;
            ts.push(cell(col, p, bsd_time, cmd_full));
        }
        emit(&o, cols.items, ts.items, bsd_time, limit);
    }
    _ = nc;
    // blank headers (-o pid=) must not leave an empty header line
    if (headers and have_o) {
        var all_blank = true;
        for (cols.items) |sp| if (sp.header == null or sp.header.?.len > 0) {
            all_blank = false;
        };
        if (all_blank) {
            // drop the first line
            const nl = std.mem.indexOfScalar(u8, o.items, '\n') orelse 0;
            u.out(o.items[nl + 1 ..]);
            return if (procs.items.len == 0) 1 else 0;
        }
    }
    u.out(o.items);
    return if (procs.items.len == 0) 1 else 0;
}

fn addFormat(s: []const u8, out: *u.Vec(Spec)) bool {
    var it = std.mem.tokenizeAny(u8, s, ", ");
    while (it.next()) |tok| {
        var name = tok;
        var header: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
            name = tok[0..eq];
            header = tok[eq + 1 ..];
        }
        const col = colByName(name) orelse {
            u.errf("error: unknown user-defined format specifier \"{s}\"\n", .{name});
            return false;
        };
        out.push(.{ .col = col, .header = header });
    }
    return true;
}
