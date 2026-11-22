// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// crond - busybox-style cron daemon: per-user files in /var/spool/cron/crontabs
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const mnt = @import("mount.zig");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("pwd.h");
    @cInclude("grp.h");
    @cInclude("time.h");
});

const Entry = struct {
    min: u64,
    hour: u32,
    dom: u32,
    mon: u16,
    dow: u8,
    dom_star: bool,
    dow_star: bool,
    reboot: bool,
    user: []const u8,
    cmd: []const u8,
    env: []const []const u8,
};

const mon_names = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
const dow_names = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };

fn parseNum(s: []const u8, names: []const []const u8, base: u32) ?u32 {
    if (std.fmt.parseInt(u32, s, 10)) |v| return v else |_| {}
    if (s.len >= 3) for (names, 0..) |n, i| if (std.ascii.eqlIgnoreCase(s[0..3], n) and s.len == 3) return @as(u32, @intCast(i)) + base;
    return null;
}

/// bit set for one field, bits indexed by value
fn parseField(f: []const u8, lo: u32, hi: u32, names: []const []const u8, base: u32, star: *bool) ?u64 {
    var set: u64 = 0;
    star.* = f.len > 0 and f[0] == '*';
    var parts = std.mem.splitScalar(u8, f, ',');
    while (parts.next()) |part| {
        var range = part;
        var step: u32 = 1;
        if (std.mem.indexOfScalar(u8, part, '/')) |sl| {
            range = part[0..sl];
            step = std.fmt.parseInt(u32, part[sl + 1 ..], 10) catch return null;
            if (step == 0) return null;
        }
        var a: u32 = lo;
        var b: u32 = hi;
        if (!std.mem.eql(u8, range, "*")) {
            if (std.mem.indexOfScalar(u8, range, '-')) |dash| {
                a = parseNum(range[0..dash], names, base) orelse return null;
                b = parseNum(range[dash + 1 ..], names, base) orelse return null;
            } else {
                a = parseNum(range, names, base) orelse return null;
                b = if (step > 1) hi else a;
            }
        }
        if (a < lo or b > hi or a > b) return null;
        var v = a;
        while (v <= b) : (v += step) set |= @as(u64, 1) << @intCast(v);
    }
    return set;
}

fn parseCrontab(data: []const u8, user: []const u8, out: *u.Vec(Entry)) void {
    var env = u.Vec([]const u8).init(u.alloc);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |l0| {
        const l = std.mem.trim(u8, l0, " \t\r");
        if (l.len == 0 or l[0] == '#') continue;
        // VAR=value
        if (std.mem.indexOfScalar(u8, l, '=')) |eq| {
            var ok = eq > 0;
            for (l[0..eq]) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) {
                ok = false;
            };
            if (ok and !std.ascii.isDigit(l[0])) {
                var v = std.mem.trim(u8, l[eq + 1 ..], " \t");
                if (v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0]) v = v[1 .. v.len - 1];
                env.push(std.fmt.allocPrint(u.alloc, "{s}={s}", .{ l[0..eq], v }) catch continue);
                continue;
            }
        }
        var it = std.mem.tokenizeAny(u8, l, " \t");
        const first = it.next() orelse continue;
        var e = Entry{ .min = 0, .hour = 0, .dom = 0, .mon = 0, .dow = 0, .dom_star = false, .dow_star = false, .reboot = false, .user = user, .cmd = "", .env = u.alloc.dupe([]const u8, env.items) catch &.{} };
        if (first[0] == '@') {
            const spec = first[1..];
            if (std.mem.eql(u8, spec, "reboot")) {
                e.reboot = true;
            } else if (std.mem.eql(u8, spec, "hourly")) {
                e.min = 1;
                e.hour = 0xffffff;
                e.dom = 0xfffffffe;
                e.mon = 0x1ffe;
                e.dow = 0x7f;
                e.dom_star = true;
                e.dow_star = true;
            } else if (std.mem.eql(u8, spec, "daily") or std.mem.eql(u8, spec, "midnight")) {
                e.min = 1;
                e.hour = 1;
                e.dom = 0xfffffffe;
                e.mon = 0x1ffe;
                e.dow = 0x7f;
                e.dom_star = true;
                e.dow_star = true;
            } else if (std.mem.eql(u8, spec, "weekly")) {
                e.min = 1;
                e.hour = 1;
                e.dom = 0xfffffffe;
                e.mon = 0x1ffe;
                e.dow = 1;
                e.dom_star = true;
            } else if (std.mem.eql(u8, spec, "monthly")) {
                e.min = 1;
                e.hour = 1;
                e.dom = 2;
                e.mon = 0x1ffe;
                e.dow = 0x7f;
                e.dow_star = true;
            } else if (std.mem.eql(u8, spec, "yearly") or std.mem.eql(u8, spec, "annually")) {
                e.min = 1;
                e.hour = 1;
                e.dom = 2;
                e.mon = 2;
                e.dow = 0x7f;
                e.dow_star = true;
            } else continue;
        } else {
            var fields: [5][]const u8 = undefined;
            fields[0] = first;
            var ok = true;
            var k: usize = 1;
            while (k < 5) : (k += 1) fields[k] = it.next() orelse {
                ok = false;
                break;
            };
            if (!ok) continue;
            var st: bool = false;
            const m = parseField(fields[0], 0, 59, &.{}, 0, &st) orelse continue;
            const h = parseField(fields[1], 0, 23, &.{}, 0, &st) orelse continue;
            const d = parseField(fields[2], 1, 31, &.{}, 0, &e.dom_star) orelse continue;
            const mo = parseField(fields[3], 1, 12, &mon_names, 1, &st) orelse continue;
            var w = parseField(fields[4], 0, 7, &dow_names, 0, &e.dow_star) orelse continue;
            if (w & 0x80 != 0) w |= 1;
            e.min = m;
            e.hour = @intCast(h);
            e.dom = @intCast(d);
            e.mon = @intCast(mo);
            e.dow = @intCast(w & 0x7f);
        }
        // the rest of the line is the command
        const rest_start = blk: {
            var pos: usize = 0;
            var fieldsSeen: usize = 0;
            const need: usize = if (first[0] == '@') 1 else 5;
            while (fieldsSeen < need) {
                while (pos < l.len and (l[pos] == ' ' or l[pos] == '\t')) pos += 1;
                while (pos < l.len and l[pos] != ' ' and l[pos] != '\t') pos += 1;
                fieldsSeen += 1;
            }
            while (pos < l.len and (l[pos] == ' ' or l[pos] == '\t')) pos += 1;
            break :blk pos;
        };
        if (rest_start >= l.len) continue;
        e.cmd = u.alloc.dupe(u8, l[rest_start..]) catch continue;
        out.push(e);
    }
}

fn due(e: Entry, tm: *const c.struct_tm) bool {
    if (e.reboot) return false;
    if (e.min & (@as(u64, 1) << @intCast(tm.tm_min)) == 0) return false;
    if (e.hour & (@as(u32, 1) << @intCast(tm.tm_hour)) == 0) return false;
    if (e.mon & (@as(u16, 1) << @intCast(tm.tm_mon + 1)) == 0) return false;
    const dom_ok = e.dom & (@as(u32, 1) << @intCast(tm.tm_mday)) != 0;
    const dow_ok = e.dow & (@as(u8, 1) << @intCast(tm.tm_wday)) != 0;
    if (e.dom_star or e.dow_star) return dom_ok and dow_ok;
    return dom_ok or dow_ok;
}

fn loadAll(dir: []const u8) []Entry {
    var out = u.Vec(Entry).init(u.alloc);
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir(dir, &ents)) return out.items;
    for (ents.items) |e| {
        if (e.name.len == 0 or e.name[0] == '.') continue;
        const path = std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ dir, e.name }) catch continue;
        const data = mnt.readFile(path) orelse continue;
        parseCrontab(data, u.alloc.dupe(u8, e.name) catch continue, &out);
    }
    return out.items;
}

fn runJob(e: Entry, log_fd: i32) void {
    const pid = linux.fork();
    if (!u.ok(pid)) return;
    if (pid != 0) return;
    _ = linux.setsid();
    var pw: ?*c.struct_passwd = c.getpwnam(u.zstr(e.user).ptr);
    if (pw == null and c.getuid() == 0) linux.exit_group(0);
    var home: []const u8 = "/";
    if (pw) |p| {
        home = std.mem.span(p.pw_dir);
        if (c.getuid() == 0) {
            _ = c.initgroups(p.pw_name, p.pw_gid);
            _ = c.setgid(p.pw_gid);
            _ = c.setuid(p.pw_uid);
        }
    }
    pw = null;
    if (log_fd >= 0) {
        _ = linux.dup2(log_fd, 1);
        _ = linux.dup2(log_fd, 2);
    }
    const devnull = linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    if (u.ok(devnull)) _ = linux.dup2(@intCast(devnull), 0);
    _ = c.chdir(u.zstr(home).ptr);
    u.setEnv("SHELL", "/bin/sh");
    u.setEnv("HOME", home);
    u.setEnv("LOGNAME", e.user);
    u.setEnv("USER", e.user);
    for (e.env) |kv| {
        if (std.mem.indexOfScalar(u8, kv, '=')) |eq| u.setEnv(kv[0..eq], kv[eq + 1 ..]);
    }
    var av = [_]?[*:0]const u8{ "sh", "-c", u.zstr(e.cmd).ptr, null };
    _ = linux.execve("/bin/sh", @ptrCast(&av), u.envp(&.{}));
    linux.exit_group(127);
}

var stop = false;
fn onTerm(sig: linux.SIG) callconv(.c) void {
    _ = sig;
    stop = true;
}

pub fn crond(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "", .key = 'f' }, .{ .name = "", .key = 'b' }, .{ .name = "", .key = 'S' },
        .{ .name = "", .key = 'l', .arg = .req }, .{ .name = "", .key = 'L', .arg = .req },
        .{ .name = "", .key = 'd', .arg = .req }, .{ .name = "", .key = 'c', .arg = .req },
        .{ .name = "", .key = 'Z', .arg = .req },
    };
    var p = g.Parser.init("crond", args, &opts);
    var foreground = false;
    var dir: []const u8 = "/var/spool/cron/crontabs";
    var logfile: ?[]const u8 = null;
    var once: ?i64 = null;
    while (p.next() catch {
        u.err("Usage: crond -fbS -l N -d N -L LOGFILE -c DIR\n\n\t-f\tForeground\n\t-b\tBackground (default)\n\t-S\tLog to syslog (default)\n\t-l N\tSet log level. Most verbose 0, default 8\n\t-d N\tSet log level, log to stderr\n\t-L FILE\tLog to FILE\n\t-c DIR\tWorking dir\n");
        return 1;
    }) |it| {
        switch (it.key) {
            'f' => foreground = true,
            'c' => dir = it.val.?,
            'L' => logfile = it.val,
            'd' => foreground = true,
            'Z' => once = std.fmt.parseInt(i64, it.val.?, 10) catch null,
            else => {},
        }
    }
    var log_fd: i32 = -1;
    if (logfile) |lf| {
        const rc = linux.open(u.zstr(lf), .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o600);
        if (u.ok(rc)) log_fd = @intCast(rc);
    }
    if (once) |t| {
        // run everything due in the minute containing `t`, then wait for the jobs
        var tt: c.time_t = @intCast(t);
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&tt, &tm);
        for (loadAll(dir)) |e| if (due(e, &tm)) runJob(e, log_fd);
        while (true) {
            var st: u32 = 0;
            const r = linux.wait4(-1, &st, 0, null);
            if (!u.ok(r)) break;
        }
        return 0;
    }
    if (c.getuid() != 0 and false) return 1;
    if (!foreground) {
        const pid = linux.fork();
        if (!u.ok(pid)) return 1;
        if (pid != 0) return 0;
        _ = linux.setsid();
        const dn = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
        if (u.ok(dn)) {
            _ = linux.dup2(@intCast(dn), 0);
            _ = linux.dup2(@intCast(dn), 1);
            _ = linux.dup2(@intCast(dn), 2);
        }
    }
    var act = linux.Sigaction{ .handler = .{ .handler = onTerm }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(linux.SIG.TERM, &act, null);
    _ = linux.sigaction(linux.SIG.INT, &act, null);
    var entries = loadAll(dir);
    for (entries) |e| if (e.reboot) runJob(e, log_fd);
    var last_min: i64 = -1;
    while (!stop) {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.REALTIME, &ts);
        const now: i64 = @intCast(ts.sec);
        const minute = @divFloor(now, 60);
        if (minute != last_min) {
            last_min = minute;
            entries = loadAll(dir);
            var tt: c.time_t = @intCast(now);
            var tm: c.struct_tm = undefined;
            _ = c.localtime_r(&tt, &tm);
            for (entries) |e| if (due(e, &tm)) runJob(e, log_fd);
        }
        // reap finished jobs
        while (true) {
            var st: u32 = 0;
            const r = linux.wait4(-1, &st, 1, null);
            if (!u.ok(r) or r == 0) break;
        }
        const wait_s = 60 - @mod(now, 60);
        var sl: linux.timespec = .{ .sec = @intCast(@min(wait_s, 5)), .nsec = 0 };
        _ = linux.nanosleep(&sl, null);
    }
    return 0;
}
