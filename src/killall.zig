// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// killall - psmisc compatible: -e -I -g -i -l -q -r -s -u -v -w -y -o -V, -SIG
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const kill = @import("kill.zig");
const c = @cImport({
    @cInclude("regex.h");
    @cInclude("pwd.h");
    @cInclude("unistd.h");
});

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

fn parseAge(s: []const u8) ?i64 {
    var total: i64 = 0;
    var i: usize = 0;
    while (i < s.len) {
        var j = i;
        while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
        if (j == i or j >= s.len) return null;
        const n = std.fmt.parseInt(i64, s[i..j], 10) catch return null;
        const mult: i64 = switch (s[j]) {
            's' => 1,
            'm' => 60,
            'h' => 3600,
            'd' => 86400,
            'w' => 604800,
            'M' => 2592000,
            'y' => 31536000,
            else => return null,
        };
        total += n * mult;
        i = j + 1;
    }
    return total;
}

pub fn run(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "exact", .key = 'e' },
        .{ .name = "ignore-case", .key = 'I' },
        .{ .name = "process-group", .key = 'g' },
        .{ .name = "interactive", .key = 'i' },
        .{ .name = "list", .key = 'l' },
        .{ .name = "quiet", .key = 'q' },
        .{ .name = "regexp", .key = 'r' },
        .{ .name = "signal", .key = 's', .arg = .req },
        .{ .name = "user", .key = 'u', .arg = .req },
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "wait", .key = 'w' },
        .{ .name = "younger-than", .key = 'y', .arg = .req },
        .{ .name = "older-than", .key = 'o', .arg = .req },
        .{ .name = "context", .key = 'Z', .arg = .req },
        .{ .name = "version", .key = 'V' },
        .{ .name = "help", .key = 'h' },
    };
    // -SIGNAME / -NUM shorthand before getopt
    var sig: u32 = 15;
    var rest_args = u.Vec([]const u8).init(u.alloc);
    var seen_dd = false;
    for (args) |a| {
        if (!seen_dd and a.len > 1 and a[0] == '-' and a[1] != '-' and !std.mem.eql(u8, a, "--")) {
            // not a getopt option letter combo? treat as signal if it names one
            if (kill.sigNum(a[1..])) |sn| {
                if (!(a.len == 2 and std.mem.indexOfScalar(u8, "eIgilqrsuvwyoZVh", a[1]) != null)) {
                    sig = sn;
                    continue;
                }
            }
        }
        if (std.mem.eql(u8, a, "--")) seen_dd = true;
        rest_args.push(a);
    }
    var p = g.Parser.init("killall", rest_args.items, &opts);
    var exact = false;
    var icase = false;
    var pgrp = false;
    var interactive = false;
    var quiet = false;
    var regexp = false;
    var verbose = false;
    var wait = false;
    var user: ?[]const u8 = null;
    var younger: ?i64 = null;
    var older: ?i64 = null;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'e' => exact = true,
            'I' => icase = true,
            'g' => pgrp = true,
            'i' => interactive = true,
            'l' => {
                var o = u.Vec(u8).init(u.alloc);
                var n: usize = 1;
                while (n < u.signals.len) : (n += 1) {
                    if (o.items.len > 0) o.push(' ');
                    for (u.signals[n]) |ch| o.push(ch);
                }
                o.push('\n');
                u.out(o.items);
                return 0;
            },
            'q' => quiet = true,
            'r' => regexp = true,
            's' => sig = kill.sigNum(it.val.?) orelse {
                u.errf("killall: Unknown signal {s}\n", .{it.val.?});
                return 1;
            },
            'u' => user = it.val,
            'v' => verbose = true,
            'w' => wait = true,
            'y' => younger = parseAge(it.val.?) orelse {
                u.errf("killall: Bad time spec {s}\n", .{it.val.?});
                return 1;
            },
            'o' => older = parseAge(it.val.?) orelse {
                u.errf("killall: Bad time spec {s}\n", .{it.val.?});
                return 1;
            },
            'V' => {
                u.out("killall (cmdbox)\n");
                return 0;
            },
            'h' => {
                u.out("Usage: killall [OPTION]... [--] NAME...\n");
                return 0;
            },
            else => {},
        }
    }
    if (p.operands.items.len == 0) {
        u.err("Usage: killall [OPTION]... [--] NAME...\n       killall -l, --list\n       killall -V, --version\n");
        return 1;
    }
    var uid_filter: ?u32 = null;
    if (user) |un| {
        if (c.getpwnam(u.zstr(un))) |pw| {
            uid_filter = pw.*.pw_uid;
        } else if (std.fmt.parseInt(u32, un, 10)) |v| uid_filter = v else |_| {
            u.errf("killall: User {s} does not exist\n", .{un});
            return 1;
        }
    }
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir("/proc", &ents)) {
        u.err("killall: /proc: cannot read\n");
        return 1;
    }
    const self: i64 = c.getpid();
    var boot: i64 = 0;
    if (readFile("/proc/stat")) |st| {
        var lines = std.mem.splitScalar(u8, st, '\n');
        while (lines.next()) |l| if (std.mem.startsWith(u8, l, "btime ")) {
            boot = std.fmt.parseInt(i64, std.mem.trim(u8, l[6..], " "), 10) catch 0;
        };
    }
    const hz: i64 = @max(c.sysconf(c._SC_CLK_TCK), 1);
    const now = u.nowSecs();
    var rc: u8 = 0;
    var killed_pids = u.Vec(i64).init(u.alloc);
    for (p.operands.items) |name| {
        var re: c.regex_t = undefined;
        if (regexp) {
            if (c.regcomp(&re, u.zstr(name).ptr, c.REG_EXTENDED | c.REG_NOSUB | (if (icase) c.REG_ICASE else 0)) != 0) {
                u.errf("killall: Bad regular expression: {s}\n", .{name});
                return 1;
            }
        }
        var found = false;
        var killed_any = false;
        for (ents.items) |e| {
            const pid = std.fmt.parseInt(i64, e.name, 10) catch continue;
            if (pid == self) continue;
            var pb: [64]u8 = undefined;
            const stat_text = readFile(std.fmt.bufPrint(&pb, "/proc/{d}/stat", .{pid}) catch continue) orelse continue;
            const lp = std.mem.indexOfScalar(u8, stat_text, '(') orelse continue;
            const rp = std.mem.lastIndexOfScalar(u8, stat_text, ')') orelse continue;
            const comm = stat_text[lp + 1 .. rp];
            var matched = false;
            var cand: []const u8 = comm;
            if (name.len > 15 and !regexp) {
                // comm is truncated; use the executable's basename
                var eb: [64]u8 = undefined;
                var lb: [u.PATH_MAX]u8 = undefined;
                const ep = std.fmt.bufPrint(&eb, "/proc/{d}/exe", .{pid}) catch continue;
                const rl = linux.readlink(u.zstr(ep), &lb, lb.len);
                if (u.ok(rl)) cand = u.basename(lb[0..rl]);
            }
            if (regexp) {
                const m = c.regexec(&re, u.zstr(cand).ptr, 0, null, 0);
                matched = m == 0;
            } else if (exact or name.len > 15) {
                matched = if (icase) std.ascii.eqlIgnoreCase(cand, name) else std.mem.eql(u8, cand, name);
            } else {
                const short = if (name.len > 15) name[0..15] else name;
                matched = if (icase) std.ascii.eqlIgnoreCase(cand, short) else std.mem.eql(u8, cand, short);
            }
            if (!matched) continue;
            var dp: [64]u8 = undefined;
            const st = u.stat(std.fmt.bufPrint(&dp, "/proc/{d}", .{pid}) catch continue, true) orelse continue;
            if (uid_filter) |uf| if (st.uid != uf) continue;
            if (younger != null or older != null) {
                var it = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, stat_text[rp + 1 ..], "\n"), ' ');
                var idx: usize = 3;
                var start: i64 = 0;
                while (it.next()) |t| : (idx += 1) if (idx == 22) {
                    start = std.fmt.parseInt(i64, t, 10) catch 0;
                };
                const age = now - (boot + @divTrunc(start, hz));
                if (younger) |y| if (age >= y) continue;
                if (older) |o| if (age <= o) continue;
            }
            found = true;
            var target = pid;
            if (pgrp) {
                var it = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, stat_text[rp + 1 ..], "\n"), ' ');
                var idx: usize = 3;
                while (it.next()) |t| : (idx += 1) if (idx == 5) {
                    target = -(std.fmt.parseInt(i64, t, 10) catch pid);
                };
            }
            if (interactive) {
                u.errf("Kill {s}({d}) ? (y/N) ", .{ comm, pid });
                var ans: [8]u8 = undefined;
                const nread = linux.read(0, &ans, ans.len);
                if (!u.ok(nread) or nread == 0 or (ans[0] != 'y' and ans[0] != 'Y')) continue;
            }
            const r = linux.syscall2(.kill, @bitCast(@as(isize, @intCast(target))), sig);
            if (!u.ok(r)) {
                if (u.errno(r) == .SRCH) {
                    found = false;
                    continue;
                }
                u.errf("{s}({d}): {s}\n", .{ comm, pid, u.strerr(u.errno(r)) });
                rc = 1;
                continue;
            }
            killed_any = true;
            killed_pids.push(pid);
            if (verbose) u.errf("Killed {s}({d}) with signal {d}\n", .{ comm, pid, sig });
        }
        if (regexp) c.regfree(&re);
        if (!found and !killed_any) {
            if (!quiet) u.errf("{s}: no process found\n", .{name});
            rc = 1;
        }
    }
    if (wait) {
        var left = true;
        while (left) {
            left = false;
            for (killed_pids.items) |pid| {
                const r = linux.syscall2(.kill, @bitCast(@as(isize, @intCast(pid))), 0);
                if (u.ok(r)) left = true;
            }
            if (left) {
                var ts = linux.timespec{ .sec = 0, .nsec = 100_000_000 };
                _ = linux.nanosleep(&ts, null);
            }
        }
    }
    return rc;
}
