// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// renice time dmesg reset logger sysctl chroot pivot_root lsmod insmod rmmod swapon swapoff mkswap
// dnsdomainname killall5 add-shell remove-shell - util-linux / procps / kmod / GNU time compatible
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const dt = @import("datetime.zig");
const color = @import("color.zig");
const kill_mod = @import("kill.zig");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("pwd.h");
    @cInclude("sys/resource.h");
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

fn readFile(path: []const u8) ?[]u8 {
    const rc = linux.open(u.zstr(path), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(rc)) return null;
    defer _ = linux.close(@intCast(rc));
    var data = u.Vec(u8).init(u.alloc);
    var buf: [65536]u8 = undefined;
    while (true) {
        const r = linux.read(@intCast(rc), &buf, buf.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r) or r == 0) break;
        data.pushSlice(buf[0..r]);
    }
    return data.items;
}

// ===================== renice =====================
pub fn renice(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "priority", .key = 'n', .arg = .req },
        .{ .name = "pid", .key = 'p' },
        .{ .name = "pgrp", .key = 'g' },
        .{ .name = "user", .key = 'u' },
        .{ .key = 'h' },
        .{ .key = 'V' },
    } ++ hv;
    // legacy form: renice PRIORITY [-p|-g|-u] ID...
    var p = g.Parser.init("renice", args, &opts);
    var incr = false;
    var prio: ?i32 = null;
    var which: i32 = 0; // PRIO_PROCESS
    var ids = u.Vec(struct { w: i32, id: []const u8 }).init(u.alloc);
    var cur: i32 = 0;
    while (p.next() catch return 1) |it| {
        if (it.key == HELP or it.key == 'h') {
            u.out("\nUsage:\n renice [-n|--priority|--relative] <priority> [-p|--pid] <pid>...\n renice [-n|--priority|--relative] <priority>  -g|--pgrp <pgid>...\n renice [-n|--priority|--relative] <priority>  -u|--user <user>...\n\nAlter the priority of running processes.\n\nOptions:\n -n <num>               specify the nice value;\n                          if POSIXLY_CORRECT flag is set in environment,\n                          then the priority is 'relative' to current\n                          process priority; otherwise it is 'absolute'\n --priority <num>       specify the 'absolute' nice value\n --relative <num>       specify the 'relative' nice value\n -p, --pid              interpret arguments as process ID (default)\n -g, --pgrp             interpret arguments as process group ID\n -u, --user             interpret arguments as username or user ID\n\n -h, --help             display this help\n -V, --version          display version\n\nFor more details see renice(1).\n");
            return 0;
        }
        if (it.key == VERSION or it.key == 'V') {
            u.out("renice from util-linux 2.41.5\n");
            return 0;
        }
        switch (it.key) {
            'n' => {
                incr = true;
                prio = std.fmt.parseInt(i32, it.val.?, 10) catch {
                    u.errf("renice: invalid priority '{s}'\nTry 'renice --help' for more information.\n", .{it.val.?});
                    return 1;
                };
            },
            'p' => cur = 0,
            'g' => cur = 1,
            'u' => cur = 2,
            else => {},
        }
    }
    which = cur;
    var ops = p.operands.items;
    if (prio == null) {
        if (ops.len == 0) {
            u.err("renice: not enough arguments\nTry 'renice --help' for more information.\n");
            return 1;
        }
        prio = std.fmt.parseInt(i32, ops[0], 10) catch {
            u.errf("renice: invalid priority '{s}'\nTry 'renice --help' for more information.\n", .{ops[0]});
            return 1;
        };
        ops = ops[1..];
    }
    for (ops) |a| ids.push(.{ .w = which, .id = a });
    if (ids.items.len == 0) {
        u.err("renice: not enough arguments\nTry 'renice --help' for more information.\n");
        return 1;
    }
    var rc: u8 = 0;
    for (ids.items) |e| {
        var id: u32 = 0;
        if (e.w == 2) {
            id = (if (std.fmt.parseInt(u32, e.id, 10)) |v| v else |_| u.findUser(e.id)) orelse {
                u.errf("renice: unknown user {s}\n", .{e.id});
                rc = 1;
                continue;
            };
        } else id = std.fmt.parseInt(u32, e.id, 10) catch {
            u.errf("renice: bad {s} value: {s}\n", .{ if (e.w == 1) "process group ID" else "process ID", e.id });
            rc = 1;
            continue;
        };
        const old_raw = linux.syscall2(.getpriority, @intCast(e.w), id);
        if (!u.ok(old_raw)) {
            const kind0: []const u8 = if (e.w == 0) "process ID" else if (e.w == 1) "process group ID" else "user ID";
            u.errf("renice: failed to get priority for {d} ({s}): {s}\n", .{ id, kind0, u.strerr(u.errno(old_raw)) });
            rc = 1;
            continue;
        }
        const old: i32 = 20 - @as(i32, @intCast(old_raw));
        var np = prio.?;
        if (incr) np += old;
        np = std.math.clamp(np, -20, 19);
        const r = linux.syscall3(.setpriority, @intCast(e.w), id, @bitCast(@as(isize, np)));
        const kind: []const u8 = if (e.w == 0) "process ID" else if (e.w == 1) "process group ID" else "user ID";
        if (!u.ok(r)) {
            u.errf("renice: failed to set priority for {d} ({s}): {s}\n", .{ id, kind, u.strerr(u.errno(r)) });
            rc = 1;
            continue;
        }
        u.outf("{d} ({s}) old priority {d}, new priority {d}\n", .{ id, kind, old, np });
    }
    return rc;
}

// ===================== time =====================
pub fn time(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "portability", .key = 'p' },
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "format", .key = 'f', .arg = .req },
        .{ .name = "output", .key = 'o', .arg = .req },
        .{ .name = "append", .key = 'a' },
        .{ .name = "quiet", .key = 'q' },
    } ++ hv;
    var p = g.Parser.init("time", args, &opts);
    p.stop_at_operand = true;
    var posix = false;
    var verbose = false;
    var fmt: ?[]const u8 = null;
    var outfile: ?[]const u8 = null;
    var append = false;
    while (p.next() catch return 125) |it| {
        if (common("time", it.key, "Usage: time [-apvV] [-f format] [-o file] [--help] [--version] command [arg...]\n")) |r| return r;
        switch (it.key) {
            'p' => posix = true,
            'v' => verbose = true,
            'f' => fmt = it.val,
            'o' => outfile = it.val,
            'a' => append = true,
            else => {},
        }
    }
    const rest = p.rest();
    if (rest.len == 0) {
        u.err("Usage: time [-apvV] [-f format] [-o file] [--help] [--version] command [arg...]\n");
        return 1;
    }
    var t0: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &t0);
    const pid_raw = linux.fork();
    if (!u.ok(pid_raw)) return 125;
    if (pid_raw == 0) {
        var pb: [u.PATH_MAX]u8 = undefined;
        const path = u.findInPath(rest[0], &pb) orelse {
            u.errf("time: cannot run {s}: No such file or directory\n", .{rest[0]});
            linux.exit_group(127);
        };
        var av = u.Vec([:0]const u8).init(u.alloc);
        for (rest) |a| av.push(u.zstr(a));
        _ = linux.execve(path.ptr, u.argvp(av.items), u.envp(&.{}));
        u.errf("time: cannot run {s}: Permission denied\n", .{rest[0]});
        linux.exit_group(126);
    }
    var status: u32 = 0;
    var ru: linux.rusage = undefined;
    while (true) {
        const r = linux.wait4(@intCast(pid_raw), &status, 0, &ru);
        if (u.errno(r) == .INTR) continue;
        break;
    }
    var t1: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &t1);
    const real = @as(f64, @floatFromInt(t1.sec - t0.sec)) + @as(f64, @floatFromInt(t1.nsec - t0.nsec)) / 1e9;
    const user = @as(f64, @floatFromInt(ru.utime.sec)) + @as(f64, @floatFromInt(ru.utime.usec)) / 1e6;
    const sys = @as(f64, @floatFromInt(ru.stime.sec)) + @as(f64, @floatFromInt(ru.stime.usec)) / 1e6;
    var o = u.Vec(u8).init(u.alloc);
    const code: u8 = if (status & 0x7f != 0) @intCast(128 + (status & 0x7f)) else @intCast((status >> 8) & 0xff);
    if (status & 0x7f != 0 and !(posix)) o.pushSlice(std.fmt.allocPrint(u.alloc, "Command terminated by signal {d}\n", .{status & 0x7f}) catch "") else if (code != 0 and !posix) o.pushSlice(std.fmt.allocPrint(u.alloc, "Command exited with non-zero status {d}\n", .{code}) catch "");
    const elapsed = struct {
        fn f(secs: f64) []const u8 {
            const total: u64 = @intFromFloat(secs);
            const h = total / 3600;
            const m = (total / 60) % 60;
            const s = secs - @as(f64, @floatFromInt(h * 3600 + m * 60));
            if (h > 0) return std.fmt.allocPrint(u.alloc, "{d}:{d:0>2}:{d:0>5.2}", .{ h, m, s }) catch "";
            return std.fmt.allocPrint(u.alloc, "{d}:{d:0>5.2}", .{ m, s }) catch "";
        }
    }.f;
    if (posix) {
        o.pushSlice(std.fmt.allocPrint(u.alloc, "real {d:.2}\nuser {d:.2}\nsys {d:.2}\n", .{ real, user, sys }) catch "");
    } else if (fmt) |f| {
        var i: usize = 0;
        while (i < f.len) : (i += 1) {
            if (f[i] == '%' and i + 1 < f.len) {
                i += 1;
                switch (f[i]) {
                    'e' => o.pushSlice(std.fmt.allocPrint(u.alloc, "{d:.2}", .{real}) catch ""),
                    'E' => o.pushSlice(elapsed(real)),
                    'U' => o.pushSlice(std.fmt.allocPrint(u.alloc, "{d:.2}", .{user}) catch ""),
                    'S' => o.pushSlice(std.fmt.allocPrint(u.alloc, "{d:.2}", .{sys}) catch ""),
                    'P' => o.pushSlice(std.fmt.allocPrint(u.alloc, "{d}%", .{if (real > 0) @as(u64, @intFromFloat((user + sys) * 100 / real)) else 0}) catch ""),
                    'M' => o.pushSlice(std.fmt.allocPrint(u.alloc, "{d}", .{ru.maxrss}) catch ""),
                    'x' => o.pushSlice(std.fmt.allocPrint(u.alloc, "{d}", .{code}) catch ""),
                    'F' => o.pushSlice(std.fmt.allocPrint(u.alloc, "{d}", .{ru.majflt}) catch ""),
                    'R' => o.pushSlice(std.fmt.allocPrint(u.alloc, "{d}", .{ru.minflt}) catch ""),
                    'c' => o.pushSlice(std.fmt.allocPrint(u.alloc, "{d}", .{ru.nivcsw}) catch ""),
                    'w' => o.pushSlice(std.fmt.allocPrint(u.alloc, "{d}", .{ru.nvcsw}) catch ""),
                    'C' => for (rest, 0..) |a, k| {
                        if (k > 0) o.push(' ');
                        o.pushSlice(a);
                    },
                    '%' => o.push('%'),
                    else => {
                        o.push('%');
                        o.push(f[i]);
                    },
                }
            } else if (f[i] == '\\' and i + 1 < f.len) {
                i += 1;
                o.push(switch (f[i]) {
                    'n' => '\n',
                    't' => '\t',
                    else => f[i],
                });
            } else o.push(f[i]);
        }
        o.push('\n');
    } else if (verbose) {
        o.pushSlice(std.fmt.allocPrint(u.alloc, "\tCommand being timed: \"{s}\"\n\tUser time (seconds): {d:.2}\n\tSystem time (seconds): {d:.2}\n\tElapsed (wall clock) time (h:mm:ss or m:ss): {s}\n\tMaximum resident set size (kbytes): {d}\n\tExit status: {d}\n", .{ rest[0], user, sys, elapsed(real), ru.maxrss, code }) catch "");
    } else {
        o.pushSlice(std.fmt.allocPrint(u.alloc, "{d:.2}user {d:.2}system {s}elapsed {d}%CPU (0avgtext+0avgdata {d}maxresident)k\n{d}inputs+{d}outputs ({d}major+{d}minor)pagefaults 0swaps\n", .{ user, sys, elapsed(real), if (real > 0) @as(u64, @intFromFloat((user + sys) * 100 / real)) else 0, ru.maxrss, ru.inblock, ru.oublock, ru.majflt, ru.minflt }) catch "");
    }
    if (outfile) |f| {
        const fd = linux.open(u.zstr(f), .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = append, .TRUNC = !append }, 0o666);
        if (u.ok(fd)) {
            _ = (u.File{ .fd = @intCast(fd) }).write(o.items);
            _ = linux.close(@intCast(fd));
        }
    } else u.err(o.items);
    return code;
}

// ===================== reset =====================
pub fn reset(args: []const []const u8) u8 {
    for (args) |a| {
        if (std.mem.eql(u8, a, "-V")) {
            u.out("reset (cmdbox)\n");
            return 0;
        }
    }
    // full reset (RIS), soft reset, normal modes, clear screen and scrollback
    u.out("\x1bc\x1b[!p\x1b[?3;4l\x1b[4l\x1b>\x1b[H\x1b[2J\x1b[3J");
    return 0;
}

// ===================== logger =====================
const Sockaddr_un = extern struct { family: u16 = 1, path: [108]u8 = [_]u8{0} ** 108 };

const logger_help = @embedFile("logger_help.txt");

pub fn logger(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .key = 'i' },
        .{ .name = "id", .key = 131, .arg = .opt },
        .{ .name = "stderr", .key = 's' },
        .{ .name = "skip-empty", .key = 'e' },
        .{ .name = "tag", .key = 't', .arg = .req },
        .{ .name = "priority", .key = 'p', .arg = .req },
        .{ .name = "file", .key = 'f', .arg = .req },
        .{ .name = "socket", .key = 'u', .arg = .req },
        .{ .name = "server", .key = 'n', .arg = .req },
        .{ .name = "port", .key = 'P', .arg = .req },
        .{ .name = "size", .key = 'S', .arg = .req },
        .{ .name = "udp", .key = 'd' },
        .{ .name = "tcp", .key = 'T' },
        .{ .name = "no-act", .key = 130 },
        .{ .name = "octet-count", .key = 132 },
        .{ .name = "prio-prefix", .key = 133 },
        .{ .name = "rfc3164", .key = 134 },
        .{ .name = "rfc5424", .key = 135, .arg = .opt },
        .{ .name = "sd-id", .key = 136, .arg = .req },
        .{ .name = "sd-param", .key = 137, .arg = .req },
        .{ .name = "msgid", .key = 138, .arg = .req },
        .{ .name = "socket-errors", .key = 139, .arg = .req },
        .{ .name = "journald", .key = 140, .arg = .opt },
        .{ .name = "help", .key = 'h' },
        .{ .name = "version", .key = 'V' },
    };
    var p = g.Parser.init("logger", args, &opts);
    p.hint_prefix = false;
    var include_pid = false;
    var id_text: ?[]const u8 = null;
    var to_stderr = false;
    var skip_empty = false;
    var tag: ?[]const u8 = null;
    var pri: u32 = 13; // user.notice
    var file: ?[]const u8 = null;
    var sockpath: []const u8 = "/dev/log";
    var server: ?[]const u8 = null;
    var port: []const u8 = "syslog";
    var use_tcp = false;
    var max_size: usize = 1024;
    var no_act = false;
    var prio_prefix = false;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'h' => {
                u.out(logger_help);
                return 0;
            },
            'V' => {
                u.out("logger from util-linux 2.41.5\n");
                return 0;
            },
            'i' => include_pid = true,
            131 => {
                include_pid = true;
                id_text = it.val;
            },
            's' => to_stderr = true,
            'e' => skip_empty = true,
            't' => tag = it.val,
            'S' => max_size = std.fmt.parseInt(usize, it.val.?, 10) catch {
                u.errf("logger: failed to parse size: '{s}'\n", .{it.val.?});
                return 1;
            },
            'p' => {
                const v = it.val.?;
                const facs = [_][]const u8{ "kern", "user", "mail", "daemon", "auth", "syslog", "lpr", "news", "uucp", "cron", "authpriv", "ftp" };
                const lvls = [_][]const u8{ "emerg", "alert", "crit", "err", "warning", "notice", "info", "debug" };
                var fac: u32 = 1;
                var lvl: u32 = 5;
                if (std.fmt.parseInt(u32, v, 10)) |n| {
                    pri = n;
                } else |_| {
                    var parts = std.mem.splitScalar(u8, v, '.');
                    const f = parts.next() orelse "user";
                    const l = parts.next() orelse "notice";
                    var okf = false;
                    for (facs, 0..) |nm, k| if (std.mem.eql(u8, nm, f)) {
                        fac = @intCast(k);
                        okf = true;
                    };
                    if (std.mem.startsWith(u8, f, "local") and f.len == 6 and f[5] >= '0' and f[5] <= '7') {
                        fac = 16 + (f[5] - '0');
                        okf = true;
                    }
                    var okl = false;
                    for (lvls, 0..) |nm, k| if (std.mem.eql(u8, nm, l) or (std.mem.eql(u8, nm, "warning") and std.mem.eql(u8, l, "warn")) or (std.mem.eql(u8, nm, "err") and std.mem.eql(u8, l, "error"))) {
                        lvl = @intCast(k);
                        okl = true;
                    };
                    if (!okf or !okl) {
                        u.errf("logger: unknown {s} name: {s}\n", .{ if (!okf) "facility" else "priority", if (!okf) f else l });
                        return 1;
                    }
                    pri = fac * 8 + lvl;
                }
            },
            'f' => file = it.val,
            'u' => sockpath = it.val.?,
            'n' => server = it.val,
            'P' => port = it.val.?,
            'T' => use_tcp = true,
            'd' => use_tcp = false,
            130 => no_act = true,
            133 => prio_prefix = true,
            else => {},
        }
    }
    // collect the messages: the operands (one message), a file or stdin (one message per line)
    var msgs = u.Vec([]const u8).init(u.alloc);
    if (p.operands.items.len > 0) {
        var m = u.Vec(u8).init(u.alloc);
        for (p.operands.items, 0..) |a, k| {
            if (k > 0) m.push(' ');
            m.pushSlice(a);
        }
        msgs.push(m.items);
    } else {
        var data: []const u8 = "";
        if (file) |f| {
            data = readFile(f) orelse {
                u.errf("logger: {s}: No such file or directory\n", .{f});
                return 1;
            };
        } else {
            var all = u.Vec(u8).init(u.alloc);
            var buf: [65536]u8 = undefined;
            while (true) {
                const r = linux.read(0, &buf, buf.len);
                if (!u.ok(r) or r == 0) break;
                all.pushSlice(buf[0..r]);
            }
            data = all.items;
        }
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |l| {
            if (l.len == 0 and it.peek() == null) break;
            if (l.len == 0 and skip_empty) continue;
            msgs.push(l);
        }
    }
    if (tag == null) {
        const pw = c.getpwuid(c.getuid());
        tag = if (pw != null) std.mem.sliceTo(pw.*.pw_name, 0) else "user";
    }
    var sock: usize = 0;
    var have_sock = false;
    if (!no_act) {
        if (server) |host| {
            const ai = @cImport(@cInclude("netdb.h"));
            var hints = std.mem.zeroes(ai.struct_addrinfo);
            hints.ai_socktype = if (use_tcp) ai.SOCK_STREAM else ai.SOCK_DGRAM;
            var res: ?*ai.struct_addrinfo = null;
            const rc = ai.getaddrinfo(u.zstr(host).ptr, u.zstr(port).ptr, &hints, &res);
            if (rc != 0 or res == null) {
                u.errf("logger: failed to resolve name {s} port {s}: {s}\n", .{ host, port, (if (rc == ai.EAI_NONAME) "Name or service not known" else if (rc == ai.EAI_AGAIN) "Temporary failure in name resolution" else std.mem.sliceTo(ai.gai_strerror(rc), 0)) });
                return 1;
            }
            const r0 = res.?;
            const sk = linux.socket(@intCast(r0.ai_family), @intCast(r0.ai_socktype), 0);
            if (!u.ok(sk) or !u.ok(linux.connect(@intCast(sk), @ptrCast(r0.ai_addr), @intCast(r0.ai_addrlen)))) {
                u.errf("logger: failed to connect to {s}:{s}\n", .{ host, port });
                return 1;
            }
            sock = sk;
            have_sock = true;
        } else {
            const sk = linux.socket(1, 2, 0); // AF_UNIX, SOCK_DGRAM
            if (u.ok(sk)) {
                var sa = Sockaddr_un{};
                const n = @min(sockpath.len, sa.path.len - 1);
                @memcpy(sa.path[0..n], sockpath[0..n]);
                if (u.ok(linux.connect(@intCast(sk), @ptrCast(&sa), @sizeOf(Sockaddr_un)))) {
                    sock = sk;
                    have_sock = true;
                } else _ = linux.close(@intCast(sk));
            }
            if (!have_sock) {
                u.errf("logger: socket {s}: {s}\n", .{ sockpath, u.strerr(.NOENT) });
                return 1;
            }
        }
    }
    defer if (have_sock) {
        _ = linux.close(@intCast(sock));
    };
    var rc: u8 = 0;
    for (msgs.items) |m0| {
        var m = m0;
        var this_pri = pri;
        if (prio_prefix and m.len > 2 and m[0] == '<') {
            if (std.mem.indexOfScalar(u8, m, '>')) |e| {
                if (std.fmt.parseInt(u32, m[1..e], 10)) |pv| {
                    this_pri = pv;
                    m = m[e + 1 ..];
                } else |_| {}
            }
        }
        if (m.len > max_size) m = m[0..max_size];
        const ts = u.nowSecs();
        const tm = dt.localtime(ts);
        var tb = u.Vec(u8).init(u.alloc);
        dt.format("%b %e %H:%M:%S", .{ .sec = ts }, &tm, &tb);
        var line = u.Vec(u8).init(u.alloc);
        line.pushSlice(std.fmt.allocPrint(u.alloc, "<{d}>{s} {s}", .{ this_pri, tb.items, tag.? }) catch "");
        if (include_pid) {
            if (id_text) |idt| line.pushSlice(std.fmt.allocPrint(u.alloc, "[{s}]", .{idt}) catch "") else line.pushSlice(std.fmt.allocPrint(u.alloc, "[{d}]", .{c.getpid()}) catch "");
        }
        line.pushSlice(": ");
        line.pushSlice(m);
        if (to_stderr and m.len > 0) u.errf("{s}\n", .{line.items});
        if (no_act) continue;
        if (have_sock) {
            var send_buf = u.Vec(u8).init(u.alloc);
            send_buf.pushSlice(line.items);
            if (use_tcp) send_buf.push('\n');
            const w = linux.write(@intCast(sock), send_buf.items.ptr, send_buf.items.len);
            if (!u.ok(w)) {
                u.errf("logger: send message failed: {s}\n", .{u.strerr(u.errno(w))});
                rc = 1;
            }
        }
    }
    return rc;
}

// ===================== sysctl =====================
fn sysctlPath(name: []const u8) []const u8 {
    var o = u.Vec(u8).init(u.alloc);
    o.pushSlice("/proc/sys/");
    // dots separate components unless the name already uses slashes
    const slash = std.mem.indexOfScalar(u8, name, '/') != null;
    for (name) |ch| o.push(if (!slash and ch == '.') '/' else if (slash and ch == '.') '.' else ch);
    return o.items;
}

fn sysctlName(rel: []const u8) []const u8 {
    var o = u.Vec(u8).init(u.alloc);
    for (rel) |ch| o.push(if (ch == '/') '.' else ch);
    return o.items;
}

fn sysctlListDir(path: []const u8, rel: []const u8, show_names: bool, quiet: bool, out: *u.Vec(u8)) void {
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir(path, &ents)) return;
    for (ents.items) |e| {
        const child = std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ path, e.name }) catch continue;
        const crel = if (rel.len == 0) u.alloc.dupe(u8, e.name) catch continue else std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ rel, e.name }) catch continue;
        const st = u.stat(child, true) orelse continue;
        if (st.mode & linux.S.IFMT == linux.S.IFDIR) {
            sysctlListDir(child, crel, show_names, quiet, out);
        } else if (st.mode & 0o444 != 0) {
            const d = readFile(child) orelse continue;
            const v = if (d.len > 0 and d[d.len - 1] == '\n') d[0 .. d.len - 1] else d;
            var lns = std.mem.splitScalar(u8, v, '\n');
            while (lns.next()) |one| {
                if (show_names) {
                    out.pushSlice(sysctlName(crel));
                    out.pushSlice(" = ");
                }
                out.pushSlice(one);
                out.push('\n');
            }
        }
    }
}

const sysctl_usage =
    "\nUsage:\n sysctl [options] [variable[=value] ...]\n\nOptions:\n  -a, --all            display all variables\n  -A                   alias of -a\n  -X                   alias of -a\n      --deprecated     include deprecated parameters to listing\n      --dry-run        Print the key and values but do not write\n  -b, --binary         print value without new line\n  -e, --ignore         ignore unknown variables errors\n  -N, --names          print variable names without values\n  -n, --values         print only values of the given variable(s)\n  -p, --load[=<file>]  read values from file\n  -f                   alias of -p\n      --system         read values from all system directories\n  -r, --pattern <expression>\n                       select setting that match expression\n  -q, --quiet          do not echo variable set\n  -w, --write          enable writing a value to variable\n  -o                   does nothing\n  -x                   does nothing\n  -d                   alias of -h\n\n -h, --help     display this help and exit\n -V, --version  output version information and exit\n\nFor more details see sysctl(8).\n";

pub fn sysctl(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "all", .key = 'a' },
        .{ .key = 'A' },
        .{ .key = 'X' },
        .{ .name = "names", .key = 'N' },
        .{ .name = "values", .key = 'n' },
        .{ .name = "ignore", .key = 'e' },
        .{ .name = "write", .key = 'w' },
        .{ .name = "load", .key = 'p', .arg = .opt },
        .{ .name = "system", .key = 130 },
        .{ .name = "quiet", .key = 'q' },
        .{ .name = "pattern", .key = 'r', .arg = .req },
        .{ .key = 'b' },
        .{ .key = 'o' },
        .{ .key = 'x' },
        .{ .key = 'd' },
    } ++ hv;
    var p = g.Parser.init("sysctl", args, &opts);
    var all = false;
    var names_only = false;
    var values_only = false;
    var ignore = false;
    var write = false;
    var quiet = false;
    var load: ?[]const u8 = null;
    var load_set = false;
    while (p.next() catch return 255) |it| {
        if (common("sysctl", it.key, sysctl_usage)) |r| return r;
        switch (it.key) {
            'a', 'A', 'X' => all = true,
            'N' => names_only = true,
            'n' => values_only = true,
            'e' => ignore = true,
            'w' => write = true,
            'p' => {
                load_set = true;
                load = it.val;
            },
            130 => {
                load_set = true;
                load = "/etc/sysctl.conf";
            },
            'q' => quiet = true,
            else => {},
        }
    }
    var out = u.Vec(u8).init(u.alloc);
    var rc: u8 = 0;
    const setOne = struct {
        fn go(name: []const u8, value: []const u8, quiet_: bool, ign: bool, vonly: bool, o: *u.Vec(u8)) u8 {
            const path = sysctlPath(name);
            if (u.stat(path, true) == null) {
                if (!ign) u.errf("sysctl: cannot stat {s}: No such file or directory\n", .{path});
                return if (ign) 0 else 255;
            }
            const fd = linux.open(u.zstr(path), .{ .ACCMODE = .WRONLY }, 0);
            if (!u.ok(fd)) {
                u.errf("sysctl: permission denied on key '{s}'\n", .{name});
                return 255;
            }
            const data = std.fmt.allocPrint(u.alloc, "{s}\n", .{value}) catch return 255;
            const w = linux.write(@intCast(fd), data.ptr, data.len);
            _ = linux.close(@intCast(fd));
            if (!u.ok(w)) {
                u.errf("sysctl: setting key \"{s}\": {s}\n", .{ name, u.strerr(u.errno(w)) });
                return 255;
            }
            if (!quiet_) {
                if (vonly) o.pushSlice(std.fmt.allocPrint(u.alloc, "{s}\n", .{value}) catch "") else o.pushSlice(std.fmt.allocPrint(u.alloc, "{s} = {s}\n", .{ name, value }) catch "");
            }
            return 0;
        }
    }.go;
    if (load_set) {
        const f = load orelse "/etc/sysctl.conf";
        const d = readFile(f) orelse {
            u.errf("sysctl: cannot open \"{s}\": No such file or directory\n", .{f});
            return 255;
        };
        var lines = std.mem.splitScalar(u8, d, '\n');
        while (lines.next()) |ln0| {
            const ln = std.mem.trim(u8, ln0, " \t\r");
            if (ln.len == 0 or ln[0] == '#' or ln[0] == ';') continue;
            const eq = std.mem.indexOfScalar(u8, ln, '=') orelse continue;
            const nm = std.mem.trim(u8, ln[0..eq], " \t");
            const val = std.mem.trim(u8, ln[eq + 1 ..], " \t");
            const r = setOne(nm, val, quiet, true, values_only, &out);
            if (r != 0) rc = r;
        }
        u.out(out.items);
        return rc;
    }
    if (all) {
        sysctlListDir("/proc/sys", "", !values_only, quiet, &out);
        u.out(out.items);
        return 0;
    }
    if (p.operands.items.len == 0) {
        u.err(sysctl_usage);
        return 1;
    }
    for (p.operands.items) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            const r = setOne(arg[0..eq], arg[eq + 1 ..], quiet, ignore, values_only, &out);
            if (r != 0) rc = r;
            continue;
        }
        if (write) {
            u.errf("sysctl: \"{s}\" must be of the form name=value\n", .{arg});
            rc = 255;
            continue;
        }
        const path = sysctlPath(arg);
        const st = u.stat(path, true) orelse {
            if (!ignore) u.errf("sysctl: cannot stat {s}: No such file or directory\n", .{path});
            if (!ignore) rc = 255;
            continue;
        };
        if (st.mode & linux.S.IFMT == linux.S.IFDIR) {
            sysctlListDir(path, std.mem.trimEnd(u8, std.mem.replaceOwned(u8, u.alloc, arg, ".", "/") catch arg, "/"), !values_only, quiet, &out);
            continue;
        }
        const d = readFile(path) orelse {
            u.errf("sysctl: permission denied on key '{s}'\n", .{arg});
            rc = 255;
            continue;
        };
        const v = if (d.len > 0 and d[d.len - 1] == '\n') d[0 .. d.len - 1] else d;
        var lns = std.mem.splitScalar(u8, v, '\n');
        var shown = u.Vec(u8).init(u.alloc);
        for (arg) |ch| shown.push(if (ch == '/') '.' else ch);
        while (lns.next()) |one| {
            if (names_only) {
                out.pushSlice(shown.items);
                out.push('\n');
                break;
            }
            if (!values_only) {
                out.pushSlice(shown.items);
                out.pushSlice(" = ");
            }
            out.pushSlice(one);
            out.push('\n');
        }
    }
    u.out(out.items);
    return rc;
}

// ===================== chroot / pivot_root =====================
pub fn chroot(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "groups", .key = 'G', .arg = .req },
        .{ .name = "userspec", .key = 'u', .arg = .req },
        .{ .name = "skip-chdir", .key = 130 },
    } ++ hv;
    var p = g.Parser.init("chroot", args, &opts);
    p.stop_at_operand = true;
    var userspec: ?[]const u8 = null;
    var skip_chdir = false;
    while (p.next() catch return 125) |it| {
        if (common("chroot", it.key, "Usage: chroot [OPTION] NEWROOT [COMMAND [ARG]...]\n  or:  chroot OPTION\nRun COMMAND with root directory set to NEWROOT.\n")) |r| return r;
        switch (it.key) {
            'u' => userspec = it.val,
            130 => skip_chdir = true,
            else => {},
        }
    }
    const rest = p.rest();
    if (rest.len == 0) {
        u.err("chroot: missing operand\nTry 'chroot --help' for more information.\n");
        return 125;
    }
    const newroot = rest[0];
    if (!skip_chdir and std.mem.eql(u8, newroot, "/") == false and false) {}
    const r = linux.chroot(u.zstr(newroot));
    if (!u.ok(r)) {
        u.errf("chroot: cannot change root directory to '{s}': {s}\n", .{ newroot, u.strerr(u.errno(r)) });
        return 125;
    }
    if (!skip_chdir) {
        if (!u.ok(linux.chdir("/"))) {
            u.err("chroot: cannot chdir to root directory\n");
            return 125;
        }
    }
    if (userspec) |us| {
        var uname = us;
        var gname: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, us, ':')) |ci| {
            uname = us[0..ci];
            gname = us[ci + 1 ..];
        }
        if (uname.len > 0) {
            const uid = (if (std.fmt.parseInt(u32, uname, 10)) |v| v else |_| u.findUser(uname)) orelse {
                u.errf("chroot: invalid user '{s}'\n", .{uname});
                return 125;
            };
            if (gname) |gn| if (gn.len > 0) {
                const gid = (if (std.fmt.parseInt(u32, gn, 10)) |v| v else |_| u.findGroup(gn)) orelse {
                    u.errf("chroot: invalid group '{s}'\n", .{gn});
                    return 125;
                };
                _ = linux.setgid(gid);
            };
            _ = linux.setuid(uid);
        }
    }
    var cmd = u.Vec([]const u8).init(u.alloc);
    if (rest.len > 1) {
        for (rest[1..]) |a| cmd.push(a);
    } else {
        cmd.push(u.getEnv("SHELL") orelse "/bin/sh");
        cmd.push("-i");
    }
    var pb: [u.PATH_MAX]u8 = undefined;
    const path = u.findInPath(cmd.items[0], &pb) orelse {
        u.errf("chroot: failed to run command '{s}': No such file or directory\n", .{cmd.items[0]});
        return 127;
    };
    var av = u.Vec([:0]const u8).init(u.alloc);
    for (cmd.items) |a| av.push(u.zstr(a));
    _ = linux.execve(path.ptr, u.argvp(av.items), u.envp(&.{}));
    u.errf("chroot: failed to run command '{s}': {s}\n", .{ cmd.items[0], "Permission denied" });
    return 126;
}

pub fn pivot_root(args: []const []const u8) u8 {
    var ops = u.Vec([]const u8).init(u.alloc);
    for (args) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            u.out("\nUsage:\n pivot_root [options] new_root put_old\n\nChange the root filesystem.\n\nOptions:\n -h, --help     display this help\n -V, --version  display version\n\nFor more details see pivot_root(8).\n");
            return 0;
        }
        if (std.mem.eql(u8, a, "-V") or std.mem.eql(u8, a, "--version")) {
            u.out("pivot_root from util-linux 2.41.5\n");
            return 0;
        }
        if (a.len > 1 and a[0] == '-' and !std.mem.eql(u8, a, "--")) {
            if (a[1] == '-') u.errf("pivot_root: unrecognized option '{s}'\nTry 'pivot_root --help' for more information.\n", .{a}) else u.errf("pivot_root: invalid option -- '{c}'\nTry 'pivot_root --help' for more information.\n", .{a[1]});
            return 1;
        }
        if (!std.mem.eql(u8, a, "--")) ops.push(a);
    }
    if (ops.items.len != 2) {
        u.err("pivot_root: bad usage\nTry 'pivot_root --help' for more information.\n");
        return 1;
    }
    const r = linux.syscall2(.pivot_root, @intFromPtr(u.zstr(ops.items[0]).ptr), @intFromPtr(u.zstr(ops.items[1]).ptr));
    if (!u.ok(r)) {
        u.errf("pivot_root: failed to change root from `{s}' to `{s}': {s}\n", .{ ops.items[0], ops.items[1], u.strerr(u.errno(r)) });
        return 1;
    }
    return 0;
}

// ===================== lsmod / insmod / rmmod =====================
pub fn lsmod(args: []const []const u8) u8 {
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            u.out("Usage: lsmod\n");
            return 0;
        }
        if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) {
            u.out("lsmod (cmdbox)\n");
            return 0;
        }
        u.errf("Usage: lsmod\n", .{});
        return 1;
    }
    const d = readFile("/proc/modules") orelse {
        u.err("lsmod: could not open /proc/modules: No such file or directory\n");
        return 1;
    };
    var o = u.Vec(u8).init(u.alloc);
    o.pushSlice("Module                  Size  Used by\n");
    var lines = std.mem.splitScalar(u8, d, '\n');
    while (lines.next()) |ln| {
        if (ln.len == 0) continue;
        var it = std.mem.tokenizeScalar(u8, ln, ' ');
        const name = it.next() orelse continue;
        const size = it.next() orelse continue;
        const refs = it.next() orelse "0";
        const deps = it.next() orelse "-";
        o.pushSlice(std.fmt.allocPrint(u.alloc, "{s: <19} {s: >8}  {s}", .{ name, size, refs }) catch "");
        if (!std.mem.eql(u8, deps, "-")) {
            o.push(' ');
            o.pushSlice(std.mem.trimEnd(u8, deps, ","));
        }
        o.push('\n');
    }
    u.out(o.items);
    return 0;
}

pub fn insmod(args: []const []const u8) u8 {
    if (args.len == 0) {
        u.err("Usage: insmod filename [args]\n");
        return 1;
    }
    if (std.mem.eql(u8, args[0], "--help")) {
        u.out("Usage: insmod filename [args]\n");
        return 0;
    }
    var params = u.Vec(u8).init(u.alloc);
    for (args[1..], 0..) |a, k| {
        if (k > 0) params.push(' ');
        params.pushSlice(a);
    }
    const fd = linux.open(u.zstr(args[0]), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(fd)) {
        u.errf("insmod: ERROR: could not load module {s}: {s}\n", .{ args[0], u.strerr(u.errno(fd)) });
        return 1;
    }
    defer _ = linux.close(@intCast(fd));
    const r = linux.syscall3(.finit_module, @intCast(fd), @intFromPtr(u.zstr(params.items).ptr), 0);
    if (!u.ok(r)) {
        const en = u.errno(r);
        if (en == .EXIST) u.errf("insmod: ERROR: could not insert module {s}: File exists\n", .{args[0]}) else u.errf("insmod: ERROR: could not insert module {s}: {s}\n", .{ args[0], u.strerr(en) });
        return 1;
    }
    return 0;
}

pub fn rmmod(args: []const []const u8) u8 {
    var force = false;
    var names = u.Vec([]const u8).init(u.alloc);
    for (args) |a| {
        if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--force")) force = true else if (std.mem.eql(u8, a, "-w") or std.mem.eql(u8, a, "--wait") or std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "-s")) {} else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            u.out("Usage: rmmod [options] modulename ...\n");
            return 0;
        } else names.push(a);
    }
    if (names.items.len == 0) {
        u.err("Usage: rmmod [options] modulename ...\n");
        return 1;
    }
    var rc: u8 = 0;
    for (names.items) |nm0| {
        // accept paths and file names: foo.ko -> foo, dashes and underscores are equivalent
        var nm = u.basename(nm0);
        if (std.mem.indexOf(u8, nm, ".ko")) |i| nm = nm[0..i];
        var cn = u.Vec(u8).init(u.alloc);
        for (nm) |ch| cn.push(if (ch == '-') '_' else ch);
        const r = linux.syscall2(.delete_module, @intFromPtr(u.zstr(cn.items).ptr), 0x800 | (if (force) @as(usize, 0x200) else 0)); // O_NONBLOCK | O_TRUNC
        if (!u.ok(r)) {
            const en = u.errno(r);
            if (en == .NOENT) u.errf("rmmod: ERROR: Module {s} is not currently loaded\n", .{cn.items}) else if (en == .BUSY) u.errf("rmmod: ERROR: Module {s} is in use\n", .{cn.items}) else u.errf("rmmod: ERROR: could not remove '{s}': {s}\n", .{ cn.items, u.strerr(en) });
            rc = 1;
        }
    }
    return rc;
}

// ===================== swapon / swapoff / mkswap =====================
pub fn swapon(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "all", .key = 'a' },
        .{ .name = "priority", .key = 'p', .arg = .req },
        .{ .name = "summary", .key = 's' },
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "fixpgsz", .key = 'f' },
        .{ .name = "discard", .key = 'd', .arg = .opt },
        .{ .name = "ifexists", .key = 130 },
        .{ .name = "show", .key = 131, .arg = .opt },
        .{ .name = "noheadings", .key = 132 },
        .{ .name = "raw", .key = 133 },
        .{ .name = "bytes", .key = 134 },
        .{ .name = "options", .key = 'o', .arg = .req },
    } ++ hv;
    var p = g.Parser.init("swapon", args, &opts);
    var all = false;
    var prio: ?u32 = null;
    var summary = false;
    var verbose = false;
    var ifexists = false;
    while (p.next() catch return 1) |it| {
        if (common("swapon", it.key, "Usage:\n swapon [options] [<spec>]\n\nEnable devices and files for paging and swapping.\n")) |r| return r;
        switch (it.key) {
            'a' => all = true,
            'p' => prio = std.fmt.parseInt(u32, it.val.?, 10) catch {
                u.errf("swapon: failed to parse priority: {s}\n", .{it.val.?});
                return 1;
            },
            's' => summary = true,
            'v' => verbose = true,
            130 => ifexists = true,
            else => {},
        }
    }
    if (summary or (p.operands.items.len == 0 and !all)) {
        const d = readFile("/proc/swaps") orelse return 1;
        if (summary) {
            if (std.mem.count(u8, d, "\n") > 1) u.out(d);
        } else {
            // --show style table
            var lines = std.mem.splitScalar(u8, d, '\n');
            _ = lines.next();
            var o = u.Vec(u8).init(u.alloc);
            var rows = u.Vec([5][]const u8).init(u.alloc);
            while (lines.next()) |ln| {
                if (ln.len == 0) continue;
                var t = std.mem.tokenizeAny(u8, ln, " \t");
                var cells: [5][]const u8 = .{ "", "", "", "", "" };
                var k: usize = 0;
                while (t.next()) |x| : (k += 1) {
                    if (k >= 5) break;
                    cells[k] = x;
                }
                rows.push(cells);
            }
            if (rows.items.len == 0) return 0;
            const humanK = struct {
                fn f(kb_s: []const u8) []const u8 {
                    const kb = std.fmt.parseInt(u64, kb_s, 10) catch 0;
                    var v: f64 = @floatFromInt(kb);
                    const un = [_][]const u8{ "K", "M", "G", "T" };
                    var e: usize = 0;
                    while (v >= 1024 and e < 3) : (e += 1) v /= 1024;
                    return if (v < 10 and e > 0) std.fmt.allocPrint(u.alloc, "{d:.1}{s}", .{ v, un[e] }) catch "" else std.fmt.allocPrint(u.alloc, "{d:.0}{s}", .{ v, un[e] }) catch "";
                }
            }.f;
            var w0: usize = 4;
            var w1: usize = 4;
            for (rows.items) |r| {
                w0 = @max(w0, r[0].len);
                w1 = @max(w1, r[1].len);
            }
            o.pushSlice(std.fmt.allocPrint(u.alloc, "{s: <[2]} {s: <[3]} SIZE USED PRIO\n", .{ "NAME", "TYPE", w0, w1 }) catch "");
            for (rows.items) |r| o.pushSlice(std.fmt.allocPrint(u.alloc, "{s: <[5]} {s: <[6]} {s: >4} {s: >4} {s: >4}\n", .{ r[0], r[1], humanK(r[2]), humanK(r[3]), r[4], w0, w1 }) catch "");
            u.out(o.items);
        }
        return 0;
    }
    var devs = u.Vec([]const u8).init(u.alloc);
    if (all) {
        const d = readFile("/etc/fstab") orelse "";
        var lines = std.mem.splitScalar(u8, d, '\n');
        while (lines.next()) |ln0| {
            const ln = std.mem.trim(u8, ln0, " \t");
            if (ln.len == 0 or ln[0] == '#') continue;
            var t = std.mem.tokenizeAny(u8, ln, " \t");
            const dev = t.next() orelse continue;
            _ = t.next();
            const fs = t.next() orelse continue;
            const optsf = t.next() orelse "";
            if (!std.mem.eql(u8, fs, "swap") or std.mem.indexOf(u8, optsf, "noauto") != null) continue;
            devs.push(dev);
        }
    }
    for (p.operands.items) |d| devs.push(d);
    var rc: u8 = 0;
    for (devs.items) |d| {
        if (ifexists and u.stat(d, true) == null) continue;
        if (u.stat(d, true) == null) {
            u.errf("swapon: cannot open {s}: No such file or directory\n", .{d});
            rc = 255;
            continue;
        }
        var flags: usize = 0;
        if (prio) |pr| flags = 0x8000 | (pr & 0x7fff);
        const r = linux.syscall2(.swapon, @intFromPtr(u.zstr(d).ptr), flags);
        if (!u.ok(r)) {
            const en = u.errno(r);
            if (all and en == .BUSY) continue;
            u.errf("swapon: {s}: swapon failed: {s}\n", .{ d, u.strerr(en) });
            rc = 255;
        } else if (verbose) u.outf("swapon {s}\n", .{d});
    }
    return rc;
}

pub fn swapoff(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "all", .key = 'a' },
        .{ .name = "verbose", .key = 'v' },
    } ++ hv;
    var p = g.Parser.init("swapoff", args, &opts);
    var all = false;
    var verbose = false;
    while (p.next() catch return 1) |it| {
        if (common("swapoff", it.key, "Usage:\n swapoff [options] [<spec>]\n\nDisable devices and files for paging and swapping.\n")) |r| return r;
        if (it.key == 'a') all = true else if (it.key == 'v') verbose = true;
    }
    var devs = u.Vec([]const u8).init(u.alloc);
    if (all) {
        const d = readFile("/proc/swaps") orelse "";
        var lines = std.mem.splitScalar(u8, d, '\n');
        _ = lines.next();
        while (lines.next()) |ln| {
            if (ln.len == 0) continue;
            var t = std.mem.tokenizeAny(u8, ln, " \t");
            if (t.next()) |nm| devs.push(nm);
        }
    }
    for (p.operands.items) |d| devs.push(d);
    if (devs.items.len == 0 and !all) {
        u.err("swapoff: no swap device or file specified\n");
        return 1;
    }
    var rc: u8 = 0;
    for (devs.items) |d| {
        const r = linux.syscall1(.swapoff, @intFromPtr(u.zstr(d).ptr));
        if (!u.ok(r)) {
            u.errf("swapoff: {s}: swapoff failed: {s}\n", .{ d, u.strerr(u.errno(r)) });
            rc = 4;
        } else if (verbose) u.outf("swapoff {s}\n", .{d});
    }
    return rc;
}

fn parseUuid(s: []const u8, out: *[16]u8) bool {
    var k: usize = 0;
    var hex = u.Vec(u8).init(u.alloc);
    for (s) |ch| if (ch != '-') hex.push(ch);
    if (hex.items.len != 32) return false;
    while (k < 16) : (k += 1) {
        out[k] = (std.fmt.charToDigit(hex.items[2 * k], 16) catch return false) << 4 | (std.fmt.charToDigit(hex.items[2 * k + 1], 16) catch return false);
    }
    return true;
}

fn sizeHuman(bytes: u64, o: *u.Vec(u8)) void {
    const un = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };
    var v: f64 = @floatFromInt(bytes);
    var e: usize = 0;
    while (v >= 1024 and e < 5) : (e += 1) v /= 1024;
    var tmp: [48]u8 = undefined;
    if (e == 0) {
        o.pushSlice(std.fmt.bufPrint(&tmp, "{d} B", .{bytes}) catch "");
    } else {
        // one decimal, trailing ".0" dropped like util-linux
        const s = std.fmt.bufPrint(&tmp, "{d:.1}", .{v}) catch "";
        o.pushSlice(if (std.mem.endsWith(u8, s, ".0")) s[0 .. s.len - 2] else s);
        o.push(' ');
        o.pushSlice(un[e]);
    }
}

const mkswap_help = @embedFile("mkswap_help.txt");

fn detectSignature(fd: i32) ?[]const u8 {
    var buf: [2048]u8 = undefined;
    const r = linux.pread(fd, &buf, buf.len, 0);
    if (!u.ok(r)) return null;
    const n = r;
    // swap signature at the end of the first page for the common page sizes
    for ([_]usize{ 4096, 8192, 16384, 65536 }) |ps| {
        var sig: [10]u8 = undefined;
        const rr = linux.pread(fd, &sig, 10, @intCast(ps - 10));
        if (u.ok(rr) and rr == 10 and (std.mem.eql(u8, &sig, "SWAPSPACE2") or std.mem.eql(u8, &sig, "SWAP-SPACE"))) return "swap";
    }
    if (n >= 1082 and buf[1080] == 0x53 and buf[1081] == 0xef) {
        const incompat = std.mem.readInt(u32, buf[1024 + 96 ..][0..4], .little);
        const compat = std.mem.readInt(u32, buf[1024 + 92 ..][0..4], .little);
        if (incompat & 0x40 != 0 or incompat & 0x80 != 0) return "ext4";
        if (compat & 0x4 != 0) return "ext3";
        return "ext2";
    }
    if (n >= 4 and std.mem.eql(u8, buf[0..4], "XFSB")) return "xfs";
    return null;
}

pub fn mkswap(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "check", .key = 'c' },
        .{ .name = "force", .key = 'f' },
        .{ .name = "quiet", .key = 'q' },
        .{ .name = "pagesize", .key = 'p', .arg = .req },
        .{ .name = "label", .key = 'L', .arg = .req },
        .{ .name = "swapversion", .key = 'v', .arg = .req },
        .{ .name = "uuid", .key = 'U', .arg = .req },
        .{ .name = "endianness", .key = 'e', .arg = .req },
        .{ .name = "offset", .key = 'o', .arg = .req },
        .{ .name = "size", .key = 's', .arg = .req },
        .{ .name = "file", .key = 'F' },
        .{ .name = "verbose", .key = 130 },
        .{ .name = "lock", .key = 131, .arg = .opt },
        .{ .name = "help", .key = 'h' },
        .{ .name = "version", .key = 'V' },
    };
    var p = g.Parser.init("mkswap", args, &opts);
    var label: []const u8 = "";
    var uuid_arg: ?[]const u8 = null;
    const sys_page: usize = @intCast(@max(c.sysconf(c._SC_PAGESIZE), 4096));
    var pagesize: usize = sys_page;
    var page_given = false;
    var quiet = false;
    var force = false;
    var check_bad = false;
    var offset: u64 = 0;
    var file_size: ?u64 = null;
    var create_file = false;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'h' => {
                u.out(mkswap_help);
                return 0;
            },
            'V' => {
                u.out("mkswap from util-linux 2.41.5 (features: extends-check, nocow, fallocate, blkid-check, uuid, selinux)\n");
                return 0;
            },
            'q' => quiet = true,
            'f' => force = true,
            'c' => check_bad = true,
            'F' => create_file = true,
            130, 'e' => {
                if (it.key == 'e') {
                    const v = it.val.?;
                    if (!(std.mem.eql(u8, v, "native") or std.mem.eql(u8, v, "little") or std.mem.eql(u8, v, "big"))) {
                        u.errf("mkswap: invalid endianness {s} is not supported\n", .{v});
                        return 1;
                    }
                }
            },
            131 => if (it.val) |v| {
                if (!(std.mem.eql(u8, v, "yes") or std.mem.eql(u8, v, "no") or std.mem.eql(u8, v, "nonblock") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "0"))) {
                    u.errf("mkswap: unsupported lock mode: {s}\n", .{v});
                    return 1;
                }
            },
            'L' => label = it.val.?,
            'U' => uuid_arg = it.val,
            'v' => {
                const v = std.fmt.parseInt(u32, it.val.?, 10) catch {
                    u.errf("mkswap: invalid swap version argument: {s}\n", .{it.val.?});
                    return 1;
                };
                if (v != 1) {
                    u.errf("mkswap: swapspace version {d} is not supported\n", .{v});
                    return 1;
                }
            },
            'p' => {
                pagesize = std.fmt.parseInt(usize, it.val.?, 10) catch {
                    u.errf("mkswap: invalid page size argument: {s}\n", .{it.val.?});
                    return 1;
                };
                page_given = true;
            },
            'o' => offset = std.fmt.parseInt(u64, it.val.?, 0) catch {
                u.errf("mkswap: invalid offset argument: {s}\n", .{it.val.?});
                return 1;
            },
            's' => file_size = std.fmt.parseInt(u64, it.val.?, 0) catch {
                u.errf("mkswap: invalid size argument: {s}\n", .{it.val.?});
                return 1;
            },
            else => {},
        }
    }
    if (page_given and (pagesize < 4096 or pagesize & (pagesize - 1) != 0)) {
        u.errf("mkswap: Bad user-specified page size {d}\n", .{pagesize});
        return 1;
    }
    const ops = p.operands.items;
    if (ops.len == 0) {
        u.err("mkswap: error: Nowhere to set up swap on?\nTry 'mkswap --help' for more information.\n");
        return 1;
    }
    if (ops.len > 2) {
        u.err("mkswap: only one device argument is currently supported\nTry 'mkswap --help' for more information.\n");
        return 1;
    }
    if (page_given and pagesize != sys_page and !quiet) u.errf("mkswap: Using user-specified page size {d}, instead of the system value {d}\n", .{ pagesize, sys_page });
    const dev = ops[0];
    const fd_rc = linux.open(u.zstr(dev), .{ .ACCMODE = .RDWR, .CREAT = create_file }, 0o600);
    if (!u.ok(fd_rc)) {
        u.errf("mkswap: cannot open {s}: {s}\n", .{ dev, u.strerr(u.errno(fd_rc)) });
        return 1;
    }
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var size: u64 = 0;
    var is_blk = false;
    var is_reg = false;
    var mode: u32 = 0;
    if (u.statFd(fd)) |st| {
        mode = st.mode;
        if (st.mode & linux.S.IFMT == linux.S.IFBLK) {
            is_blk = true;
            var sz: u64 = 0;
            _ = linux.ioctl(fd, 0x80081272, @intFromPtr(&sz));
            size = sz;
        } else if (st.mode & linux.S.IFMT == linux.S.IFREG) {
            is_reg = true;
            size = st.size;
        } else {
            u.errf("mkswap: cannot determine size of {s}: Block device required\n", .{dev});
            return 1;
        }
    }
    if (file_size) |fs| {
        if (is_reg) {
            if (create_file or fs > size) _ = linux.ftruncate(fd, @intCast(fs));
            size = fs;
        }
    }
    if (ops.len > 1) {
        const kb = std.fmt.parseInt(u64, ops[1], 10) catch {
            u.errf("mkswap: invalid block count argument: '{s}'\n", .{ops[1]});
            return 1;
        };
        if (kb * 1024 > size and !force) {
            u.errf("mkswap: error: size {d} KiB is larger than device size {d} KiB\n", .{ kb, size / 1024 });
            return 1;
        }
        size = kb * 1024;
    }
    if (offset >= size) {
        u.errf("mkswap: error: offset {d} is larger than device size\n", .{offset});
        return 1;
    }
    const avail = size - offset;
    if (avail / pagesize < 10) {
        u.errf("mkswap: error: swap area needs to be at least {d} KiB\n", .{pagesize * 10 / 1024});
        return 1;
    }
    if (check_bad and !is_blk and !quiet) u.errf("mkswap: warning: checking bad blocks from swap file is not supported: {s}\n", .{dev});
    if (is_reg and mode & 0o077 != 0 and !quiet) u.errf("mkswap: {s}: insecure permissions {o:0>4}, fix with: chmod 0600 {s}\n", .{ dev, mode & 0o7777, dev });
    var uuid: [16]u8 = undefined;
    if (uuid_arg) |ua| {
        if (std.mem.eql(u8, ua, "clear")) {
            @memset(&uuid, 0);
        } else if (std.mem.eql(u8, ua, "time")) {
            _ = linux.getrandom(&uuid, uuid.len, 0);
            const ts: u64 = @as(u64, @intCast(u.nowSecs())) * 10_000_000 + 0x01B21DD213814000;
            std.mem.writeInt(u32, uuid[0..4], @truncate(ts), .big);
            std.mem.writeInt(u16, uuid[4..6], @truncate(ts >> 32), .big);
            std.mem.writeInt(u16, uuid[6..8], @as(u16, @truncate(ts >> 48)) & 0x0fff | 0x1000, .big);
            uuid[8] = (uuid[8] & 0x3f) | 0x80;
        } else if (std.mem.eql(u8, ua, "random")) {
            _ = linux.getrandom(&uuid, uuid.len, 0);
            uuid[6] = (uuid[6] & 0x0f) | 0x40;
            uuid[8] = (uuid[8] & 0x3f) | 0x80;
        } else if (ua.len != 36 or !parseUuid(ua, &uuid)) {
            u.err("mkswap: error: parsing UUID failed\n");
            return 1;
        }
    } else {
        _ = linux.getrandom(&uuid, uuid.len, 0);
        uuid[6] = (uuid[6] & 0x0f) | 0x40;
        uuid[8] = (uuid[8] & 0x3f) | 0x80;
    }
    if (!quiet) if (detectSignature(fd)) |sig| u.errf("mkswap: {s}: warning: wiping old {s} signature.\n", .{ dev, sig });
    var truncated = false;
    if (label.len > 15) {
        label = label[0..15];
        truncated = true;
    }
    if (truncated and !quiet) u.err("mkswap: Label was truncated.\n");
    const last_page: u32 = @intCast(avail / pagesize - 1);
    var hdr = u.alloc.alloc(u8, @intCast(pagesize)) catch return 1;
    @memset(hdr, 0);
    std.mem.writeInt(u32, hdr[1024..1028], 1, .little);
    std.mem.writeInt(u32, hdr[1028..1032], last_page, .little);
    std.mem.writeInt(u32, hdr[1032..1036], 0, .little);
    @memcpy(hdr[1036..1052], &uuid);
    @memcpy(hdr[1052 .. 1052 + label.len], label);
    @memcpy(hdr[pagesize - 10 ..], "SWAPSPACE2");
    // wipe the first sector (old signatures) then write the header
    _ = linux.syscall3(.lseek, @intCast(fd), @intCast(offset), 0);
    var zero: [1024]u8 = [_]u8{0} ** 1024;
    _ = linux.write(fd, &zero, zero.len);
    _ = linux.syscall3(.lseek, @intCast(fd), @intCast(offset), 0);
    var off: usize = 0;
    while (off < hdr.len) {
        const w = linux.write(fd, hdr.ptr + off, hdr.len - off);
        if (!u.ok(w) or w == 0) {
            u.errf("mkswap: {s}: unable to write swap header\n", .{dev});
            return 1;
        }
        off += w;
    }
    _ = linux.syscall1(.fsync, @intCast(fd));
    if (quiet) return 0;
    var o = u.Vec(u8).init(u.alloc);
    const usable = (@as(u64, last_page)) * pagesize;
    o.pushSlice("Setting up swapspace version 1, size = ");
    sizeHuman(usable, &o);
    o.pushSlice(std.fmt.allocPrint(u.alloc, " ({d} bytes)\n", .{usable}) catch "");
    if (label.len > 0) o.pushSlice(std.fmt.allocPrint(u.alloc, "LABEL={s}, ", .{label}) catch "") else o.pushSlice("no label, ");
    o.pushSlice(std.fmt.allocPrint(u.alloc, "UUID={x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{ uuid[0], uuid[1], uuid[2], uuid[3], uuid[4], uuid[5], uuid[6], uuid[7], uuid[8], uuid[9], uuid[10], uuid[11], uuid[12], uuid[13], uuid[14], uuid[15] }) catch "");
    u.out(o.items);
    return 0;
}

// ===================== dnsdomainname / killall5 / add-shell / remove-shell =====================
pub fn dnsdomainname(args: []const []const u8) u8 {
    if (args.len > 0) {
        if (std.mem.eql(u8, args[0], "--help")) {
            u.out("Usage: dnsdomainname\n");
            return 0;
        }
        u.errf("dnsdomainname: invalid option -- '{s}'\n", .{args[0]});
        return 1;
    }
    const un = std.posix.uname();
    const name = std.mem.sliceTo(&un.nodename, 0);
    if (std.mem.indexOfScalar(u8, name, '.')) |d| {
        u.outf("{s}\n", .{name[d + 1 ..]});
        return 0;
    }
    const dn = std.mem.sliceTo(&un.domainname, 0);
    if (dn.len > 0 and !std.mem.eql(u8, dn, "(none)")) {
        u.outf("{s}\n", .{dn});
        return 0;
    }
    return 1;
}

pub fn killall5(args: []const []const u8) u8 {
    var sig: u32 = 15;
    var omit = u.Vec(i64).init(u.alloc);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i < args.len) omit.push(std.fmt.parseInt(i64, args[i], 10) catch -1);
        } else if (a.len > 1 and a[0] == '-') {
            sig = kill_mod.sigNum(a[1..]) orelse {
                u.errf("killall5: invalid signal {s}\n", .{a});
                return 1;
            };
        }
    }
    const my_sid = linux.syscall1(.getsid, 0);
    const me: i64 = c.getpid();
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir("/proc", &ents)) return 1;
    var any = false;
    for (ents.items) |e| {
        const pid = std.fmt.parseInt(i64, e.name, 10) catch continue;
        if (pid <= 1 or pid == me) continue;
        var skip = false;
        for (omit.items) |o| if (o == pid) {
            skip = true;
        };
        if (skip) continue;
        // kernel threads have no command line and a parent of 2
        var pb: [64]u8 = undefined;
        const st = readFile(std.fmt.bufPrint(&pb, "/proc/{d}/stat", .{pid}) catch continue) orelse continue;
        const rp = std.mem.lastIndexOfScalar(u8, st, ')') orelse continue;
        var it = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, st[rp + 1 ..], "\n"), ' ');
        var idx: usize = 3;
        var ppid: i64 = 0;
        var sid: i64 = 0;
        while (it.next()) |t| : (idx += 1) {
            if (idx == 4) ppid = std.fmt.parseInt(i64, t, 10) catch 0;
            if (idx == 6) sid = std.fmt.parseInt(i64, t, 10) catch 0;
        }
        if (ppid == 2 or pid == 2) continue;
        if (u.ok(my_sid) and sid == @as(i64, @intCast(my_sid))) continue;
        var cb: [64]u8 = undefined;
        const cl = readFile(std.fmt.bufPrint(&cb, "/proc/{d}/cmdline", .{pid}) catch continue) orelse continue;
        if (cl.len == 0) continue;
        _ = linux.syscall2(.kill, @bitCast(@as(isize, @intCast(pid))), sig);
        any = true;
    }
    return if (any) 0 else 2;
}

fn shellsEdit(args: []const []const u8, add: bool) u8 {
    const prog: []const u8 = if (add) "add-shell" else "remove-shell";
    if (args.len == 0) {
        u.errf("Usage: {s} shellname ...\n", .{prog});
        return 1;
    }
    const path = u.getEnv("CMDBOX_SHELLS_FILE") orelse "/etc/shells";
    var lines = u.Vec([]const u8).init(u.alloc);
    if (readFile(path)) |d| {
        var it = std.mem.splitScalar(u8, d, '\n');
        while (it.next()) |l| {
            if (it.peek() == null and l.len == 0) break;
            lines.push(l);
        }
    }
    var changed = false;
    for (args) |sh| {
        if (add) {
            if (!std.mem.startsWith(u8, sh, "/")) {
                u.errf("{s}: '{s}' is not an absolute path\n", .{ prog, sh });
                continue;
            }
            const st = u.stat(sh, true);
            if (st == null or !u.ok(linux.access(u.zstr(sh), 1))) {
                u.errf("{s}: shell '{s}' does not exist or is not executable\n", .{ prog, sh });
                continue;
            }
            var have = false;
            for (lines.items) |l| if (std.mem.eql(u8, l, sh)) {
                have = true;
            };
            if (!have) {
                lines.push(u.alloc.dupe(u8, sh) catch sh);
                changed = true;
            }
        } else {
            var k: usize = 0;
            while (k < lines.items.len) {
                if (std.mem.eql(u8, lines.items[k], sh)) {
                    std.mem.copyForwards([]const u8, lines.items[k .. lines.items.len - 1], lines.items[k + 1 ..]);
                    lines.items.len -= 1;
                    changed = true;
                } else k += 1;
            }
        }
    }
    if (changed) {
        var o = u.Vec(u8).init(u.alloc);
        for (lines.items) |l| {
            o.pushSlice(l);
            o.push('\n');
        }
        const fd = linux.open(u.zstr(path), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        if (!u.ok(fd)) {
            u.errf("{s}: cannot write {s}: {s}\n", .{ prog, path, u.strerr(u.errno(fd)) });
            return 1;
        }
        _ = (u.File{ .fd = @intCast(fd) }).write(o.items);
        _ = linux.close(@intCast(fd));
    }
    return 0;
}

pub fn add_shell(args: []const []const u8) u8 {
    return shellsEdit(args, true);
}

pub fn remove_shell(args: []const []const u8) u8 {
    return shellsEdit(args, false);
}
