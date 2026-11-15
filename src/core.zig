// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// core.zig - file/dir/process/syscall applets
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");

const out = u.out;
const outf = u.outf;
const errf = u.errf;

// ================= echo =================
pub fn echo(args: []const []const u8) u8 {
    var newline = true;
    var esc = false;
    var i: usize = 0;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        const flag = args[i][1..];
        for (flag) |c| {
            if (c != 'n' and c != 'e' and c != 'E') break;
        } else {
            for (flag) |c| switch (c) {
                'n' => newline = false,
                'e' => esc = true,
                'E' => esc = false,
                else => unreachable,
            };
            continue;
        }
        break;
    }
    const first = i;
    for (args[first..], first..) |arg, ai| {
        if (ai > first) out(" ");
        if (esc) {
            const value = @import("printf.zig").echoEscapes(arg) orelse {
                out(arg);
                continue;
            };
            out(value.bytes);
            if (value.stop) return 0;
        } else {
            out(arg);
        }
    }
    if (newline) out("\n");
    return 0;
}

// ================= trivial =================
pub fn trueApp(args: []const []const u8) u8 {
    _ = args;
    return 0;
}
pub fn falseApp(args: []const []const u8) u8 {
    _ = args;
    return 1;
}

pub fn clear(args: []const []const u8) u8 {
    _ = args;
    out("\x1b[H\x1b[2J\x1b[H");
    return 0;
}

pub fn pwd(args: []const []const u8) u8 {
    _ = args;
    var buf: [u.PATH_MAX]u8 = undefined;
    const rc = linux.getcwd(&buf, buf.len);
    if (!u.ok(rc)) {
        errf("pwd: {s}\n", .{u.strerr(u.errno(rc))});
        return 1;
    }
    const cwd = std.mem.sliceTo(&buf, 0);
    outf("{s}\n", .{u.cleanPath(cwd, &buf)});
    return 0;
}

pub fn basenameApp(args: []const []const u8) u8 {
    var multiple = false;
    var zero = false;
    var suffix: ?[]const u8 = null;
    var names = u.Vec([]const u8).init(u.alloc);
    var options = true;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (options and std.mem.eql(u8, arg, "--")) {
            options = false;
            continue;
        }
        if (options and std.mem.eql(u8, arg, "--multiple")) {
            multiple = true;
            continue;
        }
        if (options and std.mem.eql(u8, arg, "--zero")) {
            zero = true;
            continue;
        }
        if (options and std.mem.startsWith(u8, arg, "--suffix=")) {
            suffix = arg[9..];
            multiple = true;
            continue;
        }
        if (options and arg.len > 1 and arg[0] == '-') {
            var k: usize = 1;
            while (k < arg.len) : (k += 1) switch (arg[k]) {
                'a' => multiple = true,
                'z' => zero = true,
                's' => {
                    multiple = true;
                    if (k + 1 < arg.len) suffix = arg[k + 1 ..] else {
                        i += 1;
                        if (i == args.len) return 1;
                        suffix = args[i];
                    }
                    break;
                },
                else => return 1,
            };
        } else {
            options = false;
            names.push(arg);
        }
    }
    if (names.items.len == 0 or !multiple and names.items.len > 2) return 1;
    if (!multiple and names.items.len == 2) {
        suffix = names.items[1];
        names.items.len = 1;
    }
    for (names.items) |name| {
        var result = if (name.len == 0) name else u.basename(name);
        if (suffix) |ending| if (ending.len > 0 and result.len > ending.len and std.mem.endsWith(u8, result, ending)) {
            result = result[0 .. result.len - ending.len];
        };
        out(result);
        if (zero) out(&.{0}) else out("\n");
    }
    return 0;
}
pub fn dirnameApp(args: []const []const u8) u8 {
    var zero = false;
    var names = u.Vec([]const u8).init(u.alloc);
    var options = true;
    for (args) |arg| {
        if (options and std.mem.eql(u8, arg, "--")) {
            options = false;
            continue;
        }
        if (options and (std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "--zero"))) {
            zero = true;
            continue;
        }
        if (options and arg.len > 1 and arg[0] == '-') return 1;
        names.push(arg);
    }
    if (names.items.len == 0) return 1;
    for (names.items) |name| {
        out(u.dirname(name));
        if (zero) out(&.{0}) else out("\n");
    }
    return 0;
}

pub fn which(args: []const []const u8) u8 {
    if (args.len == 0) return 1;
    var found_all = true;
    var pathbuf: [u.PATH_MAX]u8 = undefined;
    for (args) |name| {
        if (std.mem.indexOfScalar(u8, name, '/') != null) {
            const st = u.stat(name, true);
            if (st != null and st.?.mode & linux.S.IFMT != linux.S.IFDIR) {
                outf("{s}\n", .{name});
            } else found_all = false;
            continue;
        }
        var found = false;
        const path_env = u.getEnv("PATH") orelse "/bin:/usr/bin";
        var it = std.mem.tokenizeScalar(u8, path_env, ':');
        while (it.next()) |dir| {
            const cand = std.fmt.bufPrint(&pathbuf, "{s}/{s}", .{ dir, name }) catch continue;
            const rc = linux.access(u.zstr(cand), 1); // X_OK
            if (u.ok(rc)) {
                outf("{s}\n", .{cand});
                found = true;
                break;
            }
        }
        if (!found) found_all = false;
    }
    return if (found_all) 0 else 1;
}

pub fn env(args: []const []const u8) u8 {
    var entries = u.Vec([]const u8).init(u.alloc);
    var i: usize = 0;
    const empty = args.len > 0 and (std.mem.eql(u8, args[0], "-i") or std.mem.eql(u8, args[0], "--ignore-environment") or std.mem.eql(u8, args[0], "-"));
    if (empty) i = 1 else {
        for (u.raw_env) |kv| if (kv) |value| {
            envPut(&entries, std.mem.sliceTo(value, 0));
        };
        for (u.extra_env[0..u.extra_env_n], 0..) |kv, index| {
            if (u.extra_exported[index]) envPut(&entries, kv);
        }
    }
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, args[i], "-u")) {
            i += 1;
            if (i == args.len) {
                errf("env: -u requires a name\n", .{});
                return 125;
            }
            var k: usize = 0;
            while (k < entries.items.len) {
                if (envNameEqual(entries.items[k], args[i])) {
                    entries.items = removeEnvEntry(entries.items, k);
                } else k += 1;
            }
            i += 1;
            continue;
        }
        break;
    }
    while (i < args.len) : (i += 1) {
        const eq = std.mem.indexOfScalar(u8, args[i], '=') orelse break;
        if (eq == 0) break;
        envPut(&entries, args[i]);
    }
    if (i == args.len) {
        for (entries.items) |kv| outf("{s}\n", .{kv});
        return 0;
    }
    var av = u.Vec(?[*:0]const u8).init(u.alloc);
    for (args[i..]) |arg| av.push(u.zstr(arg).ptr);
    av.push(null);
    var ev = u.Vec(?[*:0]const u8).init(u.alloc);
    var path: []const u8 = "/bin:/usr/bin";
    for (entries.items) |kv| {
        ev.push(u.zstr(kv).ptr);
        if (envNameEqual(kv, "PATH")) path = kv[5..];
    }
    ev.push(null);
    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(av.items.ptr);
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(ev.items.ptr);
    var code: u8 = 127;
    if (std.mem.indexOfScalar(u8, args[i], '/') != null) {
        const rc = linux.execve(u.zstr(args[i]), argv, envp);
        if (u.errno(rc) != .NOENT) code = 126;
    } else {
        var dirs = std.mem.splitScalar(u8, path, ':');
        while (dirs.next()) |dir| {
            var buf: [u.PATH_MAX]u8 = undefined;
            const candidate = std.fmt.bufPrint(&buf, "{s}/{s}", .{ if (dir.len == 0) "." else dir, args[i] }) catch continue;
            const rc = linux.execve(u.zstr(candidate), argv, envp);
            if (u.errno(rc) != .NOENT and u.errno(rc) != .NOTDIR) code = 126;
        }
    }
    errf("env: {s}: cannot execute\n", .{args[i]});
    return code;
}

fn removeEnvEntry(items: [][]const u8, index: usize) [][]const u8 {
    std.mem.copyForwards([]const u8, items[index .. items.len - 1], items[index + 1 ..]);
    return items[0 .. items.len - 1];
}

fn envNameEqual(entry: []const u8, name: []const u8) bool {
    return entry.len > name.len and entry[name.len] == '=' and std.mem.eql(u8, entry[0..name.len], name);
}

fn envPut(entries: *u.Vec([]const u8), value: []const u8) void {
    const eq = std.mem.indexOfScalar(u8, value, '=') orelse return;
    for (entries.items) |*entry| {
        if (envNameEqual(entry.*, value[0..eq])) {
            entry.* = value;
            return;
        }
    }
    entries.push(value);
}

// ================= sleep / seq / yes / sync =================
pub const sleep = @import("numbers.zig").sleep;
pub const seq = @import("numbers.zig").seq;

pub fn yes(args: []const []const u8) u8 {
    const s = if (args.len > 0) args[0] else "y";
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}\n", .{s}) catch return 0;
    while (true) {
        const rc = linux.write(1, line.ptr, line.len);
        if (u.errno(rc) == .PIPE) return 0;
        if (u.errno(rc) != .SUCCESS) return 0;
    }
}

pub fn sync(args: []const []const u8) u8 {
    _ = args;
    _ = linux.syscall0(.sync);
    return 0;
}

// ================= hostname / uname / date =================
pub fn hostname(args: []const []const u8) u8 {
    if (args.len == 0) {
        const un = std.posix.uname();
        const name = std.mem.sliceTo(&un.nodename, 0);
        outf("{s}\n", .{name});
        return 0;
    }
    var name = args[0];
    if (name.len > 0 and name[0] == '-' and name.len > 1) name = name[1..];
    if (name.len > 0 and name[0] == '-') name = name[1..];
    const rc = linux.syscall2(.sethostname, @intFromPtr(u.zstr(name).ptr), name.len);
    if (!u.ok(rc)) {
        u.lastErrStr("hostname", rc);
        return 1;
    }
    return 0;
}

pub fn uname(args: []const []const u8) u8 {
    var s = false;
    var n = false;
    var r = false;
    var v = false;
    var m = false;
    var all = false;
    for (args) |arg| {
        if (arg.len < 2 or arg[0] != '-') continue;
        for (arg[1..]) |c| {
            switch (c) {
                's' => s = true,
                'n' => n = true,
                'r' => r = true,
                'v' => v = true,
                'm' => m = true,
                'a' => all = true,
                else => {},
            }
        }
    }
    if (all) {
        s = true;
        n = true;
        r = true;
        v = true;
        m = true;
    }
    if (!s and !n and !r and !v and !m) s = true; // busybox default: -s
    const un = std.posix.uname();
    var first = true;
    if (s) {
        outP(&un.sysname, &first);
    }
    if (n) {
        outP(&un.nodename, &first);
    }
    if (r) {
        outP(&un.release, &first);
    }
    if (v) {
        outP(&un.version, &first);
    }
    if (m) {
        outP(&un.machine, &first);
    }
    out("\n");
    return 0;
}

fn outP(f: *const [64:0]u8, first: *bool) void {
    if (!first.*) out(" ");
    first.* = false;
    out(std.mem.sliceTo(f, 0));
}

pub fn date(args: []const []const u8) u8 {
    var fmt: ?[]const u8 = null;
    for (args) |arg| {
        if (arg.len > 0 and arg[0] == '+') {
            fmt = arg[1..];
        } else if (std.mem.eql(u8, arg, "-u")) {
            // UTC only
        } else if (std.mem.eql(u8, arg, "-R") or std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "-d")) {
            // ignore extra flag chars
        }
    }
    const secs = u.nowSecs();
    if (fmt) |f| {
        out(fmtCustom(f, secs));
        out("\n");
    } else {
        var buf: [64]u8 = undefined;
        const d = u.fmtDate(secs, &buf);
        outf("{s} UTC\n", .{d});
    }
    return 0;
}

fn fmtCustom(f: []const u8, secs: i64) []const u8 {
    const dt = u.civilFromEpoch(secs);
    var buf = u.alloc.alloc(u8, f.len * 12 + 16) catch return f;
    var n: usize = 0;
    var i: usize = 0;
    while (i < f.len) {
        if (f[i] == '%' and i + 1 < f.len) {
            i += 1;
            var tmp: [32]u8 = undefined;
            const w: []const u8 = switch (f[i]) {
                'Y' => std.fmt.bufPrint(&tmp, "{d}", .{dt.year}) catch "",
                'm' => std.fmt.bufPrint(&tmp, "{d:0>2}", .{dt.mon}) catch "",
                'd' => std.fmt.bufPrint(&tmp, "{d:0>2}", .{dt.day}) catch "",
                'H' => std.fmt.bufPrint(&tmp, "{d:0>2}", .{dt.hour}) catch "",
                'M' => std.fmt.bufPrint(&tmp, "{d:0>2}", .{dt.min}) catch "",
                'S' => std.fmt.bufPrint(&tmp, "{d:0>2}", .{dt.sec}) catch "",
                's' => std.fmt.bufPrint(&tmp, "{d}", .{secs}) catch "",
                'j' => std.fmt.bufPrint(&tmp, "{d}", .{dayOfYear(dt)}) catch "",
                '%' => "%",
                else => blk: {
                    tmp[0] = f[i];
                    break :blk tmp[0..1];
                },
            };
            if (n + w.len <= buf.len) {
                @memcpy(buf[n .. n + w.len], w);
                n += w.len;
            }
            i += 1;
            continue;
        }
        if (n < buf.len) {
            buf[n] = f[i];
            n += 1;
        }
        i += 1;
    }
    return buf[0..n];
}

fn dayOfYear(dt: u.DateTime) i64 {
    const mdays = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var d: i64 = dt.day;
    var m: usize = 0;
    while (m + 1 < dt.mon) : (m += 1) d += mdays[m];
    if (dt.mon > 2 and (@rem(dt.year, 4) == 0 and (@rem(dt.year, 100) != 0 or @rem(dt.year, 400) == 0))) d += 1;
    return d;
}

// ================= id =================
pub fn id(args: []const []const u8) u8 {
    _ = args;
    const uid = linux.getuid();
    const gid = linux.getgid();
    var ub: [64]u8 = undefined;
    var gb: [64]u8 = undefined;
    const uname_s = u.lookupUser(uid, &ub) orelse "?";
    const gname = u.lookupGroup(gid, &gb) orelse "?";
    outf("uid={d}({s}) gid={d}({s})", .{ uid, uname_s, gid, gname });
    // groups from /proc/self/status
    var f = u.File.open("/proc/self/status", .{ .ACCMODE = .RDONLY }, 0) orelse {
        out("\n");
        return 0;
    };
    defer f.close();
    var line: [512]u8 = undefined;
    while (u.readLine(&f, &line)) |l| {
        if (std.mem.startsWith(u8, l, "Groups:")) {
            var it = std.mem.tokenizeAny(u8, l[7..], " \t");
            out(" groups=");
            var first = true;
            while (it.next()) |tok| {
                const g = u.toInt(tok) orelse continue;
                if (!first) out(",");
                first = false;
                const gn = u.lookupGroup(@intCast(g), &gb) orelse "?";
                outf("{d}({s})", .{ g, gn });
            }
            break;
        }
    }
    out("\n");
    return 0;
}

// ================= kill / killall =================
pub fn kill(args: []const []const u8) u8 {
    var sig: i64 = 15; // TERM
    var i: usize = 0;
    if (args.len > 0 and args[0].len > 1 and args[0][0] == '-') {
        const sname = args[0][1..];
        if (std.mem.eql(u8, sname, "l")) {
            for (u.signals, 0..) |sname2, si| {
                if (si > 0) out(" ");
                outf("{d}) {s}", .{ si, sname2 });
            }
            out("\n");
            return 0;
        }
        if (std.mem.eql(u8, sname, "s") and args.len > 1) {
            sig = sigFromArg(args[1]) orelse return 1;
            i = 2;
        } else {
            sig = sigFromArg(sname) orelse return 1;
            i = 1;
        }
    }
    if (i == args.len) {
        errf("kill: missing pid\n", .{});
        return 1;
    }
    var fail = false;
    for (args[i..]) |p| {
        const pid = u.toInt(p) orelse {
            errf("kill: invalid pid: {s}\n", .{p});
            fail = true;
            continue;
        };
        const rc = linux.syscall2(.kill, @bitCast(@as(isize, @intCast(pid))), @as(usize, @intCast(sig)));
        if (!u.ok(rc)) {
            u.lastErrStr(p, rc);
            fail = true;
        }
    }
    return if (fail) 1 else 0;
}

fn sigFromArg(sname: []const u8) ?i64 {
    if (u.sigFromName(sname)) |n| return @intCast(n);
    if (u.toInt(sname)) |n| return n;
    errf("kill: unknown signal: {s}\n", .{sname});
    return null;
}

pub fn killall(args: []const []const u8) u8 {
    var sig: i64 = 15;
    var i: usize = 0;
    if (args.len > 0 and args[0].len > 1 and args[0][0] == '-') {
        if (std.mem.eql(u8, args[0][1..], "q")) {
            i = 1;
        } else {
            sig = sigFromArg(args[0][1..]) orelse return 1;
            i = 1;
        }
    }
    if (i == args.len) {
        errf("killall: missing name\n", .{});
        return 1;
    }
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir("/proc", &ents)) return 1;
    var found = false;
    var fail = false;
    for (ents.items) |e| {
        const pid = u.toInt(e.name) orelse continue;
        const comm = readComm(pid);
        // killall matches by comm (what the kernel sets via exec / PR_SET_NAME)
        var matched = false;
        for (args[i..]) |target| {
            if (std.mem.eql(u8, comm, target)) matched = true;
        }
        if (!matched) continue;
        found = true;
        const rc = linux.syscall2(.kill, @bitCast(@as(isize, @intCast(pid))), @as(usize, @intCast(sig)));
        if (!u.ok(rc)) fail = true;
    }
    if (!found) {
        for (args[i..]) |target| errf("killall: {s}: no process killed\n", .{target});
        return 1;
    }
    return if (fail) 1 else 0;
}

fn readCmdline(pid: i64) []const []const u8 {
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/proc/{d}/cmdline", .{pid}) catch return &.{};
    var f = u.File.open(path, .{ .ACCMODE = .RDONLY }, 0) orelse return &.{};
    defer f.close();
    var raw: [2048]u8 = undefined;
    const n = f.read(&raw);
    var args = u.Vec([]const u8).init(u.alloc);
    var start: usize = 0;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        if (raw[k] == 0) {
            if (k > start) args.push(raw[start..k]);
            start = k + 1;
        }
    }
    if (start < n) args.push(raw[start..n]);
    return args.items;
}

// ================= ps =================
pub fn ps(args: []const []const u8) u8 {
    _ = args;
    outf("{s: >6} {s: <8} {s}\n", .{ "PID", "USER", "COMMAND" });
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir("/proc", &ents)) return 1;
    var ub: [64]u8 = undefined;
    var cmdbuf: [256]u8 = undefined;
    var joined: [1024]u8 = undefined;
    for (ents.items) |e| {
        const pid = u.toInt(e.name) orelse continue;
        var pbuf: [64]u8 = undefined;
        const ppath = std.fmt.bufPrint(&pbuf, "/proc/{s}", .{e.name}) catch continue;
        const st = u.stat(ppath, true) orelse continue;
        const user = u.lookupUser(st.uid, &ub) orelse "?";
        const argsv = readCmdline(pid);
        var cmd: []const u8 = undefined;
        if (argsv.len > 0) {
            var n: usize = 0;
            for (argsv, 0..) |arg, ai| {
                if (n + arg.len + 1 >= joined.len) break;
                if (ai > 0) {
                    joined[n] = ' ';
                    n += 1;
                }
                @memcpy(joined[n .. n + arg.len], arg);
                n += arg.len;
            }
            cmd = joined[0..n];
        } else {
            const comm = readComm(pid);
            cmd = std.fmt.bufPrint(&cmdbuf, "[{s}]", .{comm}) catch "?";
        }
        outf("{d: >6} {s: <8} {s}\n", .{ @as(u64, @intCast(pid)), user, cmd });
    }
    return 0;
}

var comm_buf: [256]u8 = undefined;

fn readComm(pid: i64) []const u8 {
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/proc/{d}/comm", .{pid}) catch return "?";
    var f = u.File.open(path, .{ .ACCMODE = .RDONLY }, 0) orelse return "?";
    defer f.close();
    const n = f.read(&comm_buf);
    if (n == 0) return "?";
    var len: usize = n;
    while (len > 0 and (comm_buf[len - 1] == '\n' or comm_buf[len - 1] == 0)) len -= 1;
    return comm_buf[0..len];
}

// ================= free / df =================
pub fn free(args: []const []const u8) u8 {
    _ = args;
    var f = u.File.open("/proc/meminfo", .{ .ACCMODE = .RDONLY }, 0) orelse return 1;
    defer f.close();
    var total: i64 = 0;
    var freev: i64 = 0;
    var buffers: i64 = 0;
    var cached: i64 = 0;
    var available: i64 = -1;
    var swaptotal: i64 = 0;
    var swapfree: i64 = 0;
    var line: [256]u8 = undefined;
    while (u.readLine(&f, &line)) |l| {
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        const key = l[0..colon];
        const rest = std.mem.trimStart(u8, l[colon + 1 ..], " ");
        const sp = std.mem.indexOfScalar(u8, rest, ' ');
        const val = u.toInt(rest[0..(sp orelse rest.len)]) orelse 0;
        if (std.mem.eql(u8, key, "MemTotal")) total = val;
        if (std.mem.eql(u8, key, "MemFree")) freev = val;
        if (std.mem.eql(u8, key, "Buffers")) buffers = val;
        if (std.mem.eql(u8, key, "Cached")) cached = val;
        if (std.mem.eql(u8, key, "MemAvailable")) available = val;
        if (std.mem.eql(u8, key, "SwapTotal")) swaptotal = val;
        if (std.mem.eql(u8, key, "SwapFree")) swapfree = val;
    }
    if (available < 0) available = freev;
    const used = total - freev - buffers - cached;
    const kb: i64 = 1024;
    outf("{s: >14} {s: >10} {s: >10} {s: >10} {s: >12} {s: >10}\n", .{ "", "total", "used", "free", "buff/cache", "available" });
    outf("Mem:{d: >10} {d: >10} {d: >10} {d: >12} {d: >10}\n", .{ @as(u64, @intCast(@divFloor(total, kb))), @as(u64, @intCast(@divFloor(used, kb))), @as(u64, @intCast(@divFloor(freev, kb))), @as(u64, @intCast(@divFloor(buffers + cached, kb))), @as(u64, @intCast(@divFloor(available, kb))) });
    outf("Swap:{d: >9} {d: >10} {d: >10}\n", .{ @as(u64, @intCast(@divFloor(swaptotal, kb))), @as(u64, @intCast(@divFloor(swaptotal - swapfree, kb))), @as(u64, @intCast(@divFloor(swapfree, kb))) });
    return 0;
}

const Statfs = if (@sizeOf(usize) == 8) extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: i64,
    f_bfree: i64,
    f_bavail: i64,
    f_files: i64,
    f_ffree: i64,
    f_fsid: [2]i32,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64,
} else extern struct {
    f_type: i32,
    f_bsize: i32,
    f_blocks: i32,
    f_bfree: i32,
    f_bavail: i32,
    f_files: i32,
    f_ffree: i32,
    f_fsid: [2]i32,
    f_namelen: i32,
    f_frsize: i32,
    f_flags: i32,
    f_spare: [4]i32,
};

fn statfs(path: []const u8) ?Statfs {
    var sfs: Statfs = undefined;
    const rc = linux.syscall2(.statfs, @intFromPtr(u.zstr(path).ptr), @intFromPtr(&sfs));
    if (!u.ok(rc)) return null;
    return sfs;
}

pub fn df(args: []const []const u8) u8 {
    outf("{s: <20}{s: >10}{s: >10}{s: >10} {s: <4} {s}\n", .{ "Filesystem", "1K-blocks", "Used", "Available", "Use%", "Mounted on" });
    var targets = u.Vec([]const u8).init(u.alloc);
    if (args.len == 0) {
        targets.push("/");
    } else {
        for (args) |arg| {
            if (arg.len > 0 and arg[0] == '-') continue;
            targets.push(arg);
        }
    }
    for (targets.items) |t| {
        const sfs = statfs(t) orelse {
            u.lastErrStr(t, 2); // NOENT-ish
            return 1;
        };
        const bs: i64 = @intCast(sfs.f_bsize);
        const total: i64 = @divFloor(@as(i64, @intCast(sfs.f_blocks)) * bs, 1024);
        const avail: i64 = @divFloor(@as(i64, @intCast(sfs.f_bavail)) * bs, 1024);
        const used: i64 = total - @divFloor(@as(i64, @intCast(sfs.f_bfree)) * bs, 1024);
        const usepct: i64 = if (used + avail > 0) @divFloor(used * 100, used + avail) else 0;
        outf("{s: <20}{d: >10}{d: >10}{d: >10} {d}% {s}\n", .{ t, @as(u64, @intCast(total)), @as(u64, @intCast(used)), @as(u64, @intCast(avail)), @as(u64, @intCast(usepct)), t });
    }
    return 0;
}

// ================= mount / umount =================
pub fn mount(args: []const []const u8) u8 {
    var fstype: ?[]const u8 = null;
    var opts: ?[]const u8 = null;
    var rest = u.Vec([]const u8).init(u.alloc);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--types")) {
            if (i + 1 >= args.len) return mntUsage();
            fstype = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "-o")) {
            if (i + 1 >= args.len) return mntUsage();
            opts = args[i + 1];
            i += 1;
        } else if (arg.len > 1 and arg[0] == '-' and !std.mem.eql(u8, arg, "-a")) {
            // unknown flag; check it's not a device
            continue;
        } else {
            rest.push(arg);
        }
    }
    if (rest.items.len == 0) return listMounts();
    if (rest.items.len < 2) return mntUsage();
    var flags: u32 = 0;
    if (opts) |o| {
        var it = std.mem.tokenizeScalar(u8, o, ',');
        while (it.next()) |opt| {
            if (std.mem.eql(u8, opt, "ro")) flags |= 1;
            if (std.mem.eql(u8, opt, "nosuid")) flags |= 2;
            if (std.mem.eql(u8, opt, "nodev")) flags |= 4;
            if (std.mem.eql(u8, opt, "noexec")) flags |= 8;
            if (std.mem.eql(u8, opt, "remount")) flags |= 32;
            if (std.mem.eql(u8, opt, "bind")) flags |= 4096;
        }
    }
    const devz = u.zstr(rest.items[0]);
    const dirz = u.zstr(rest.items[1]);
    const fsz: ?[*:0]const u8 = if (fstype) |f| u.zstr(f) else null;
    const dataz: usize = if (opts) |o| @intFromPtr(u.zstr(o).ptr) else 0;
    const rc = linux.mount(devz, dirz, fsz, flags, dataz);
    if (!u.ok(rc)) {
        u.lastErrStr("mount", rc);
        return 1;
    }
    return 0;
}

fn listMounts() u8 {
    // no args: print mounted filesystems like busybox mount
    var f = u.File.open("/proc/mounts", .{ .ACCMODE = .RDONLY }, 0) orelse {
        errf("mount: cannot read /proc/mounts\n", .{});
        return 1;
    };
    defer f.close();
    var line: [512]u8 = undefined;
    while (u.readLine(&f, &line)) |l| {
        if (l.len == 0) continue;
        // /proc/mounts: dev dir fstype opts...
        var parts = std.mem.tokenizeScalar(u8, l, ' ');
        const dev = parts.next() orelse continue;
        const dir = parts.next() orelse continue;
        const fs = parts.next() orelse continue;
        const opts = std.mem.trimEnd(u8, parts.rest(), " \t\r");
        outf("{s: <18} on {s: <28} type {s: <10} ({s})\n", .{ dev, dir, fs, opts });
    }
    return 0;
}

fn mntUsage() u8 {
    errf("usage: mount [-t fstype] [-o opts] dev dir\n", .{});
    return 1;
}

pub fn umount(args: []const []const u8) u8 {
    var fail = false;
    var any = false;
    for (args) |arg| {
        if (arg.len > 1 and arg[0] == '-') continue;
        any = true;
        const rc = linux.umount(u.zstr(arg));
        if (!u.ok(rc)) {
            u.lastErrStr(arg, rc);
            fail = true;
        }
    }
    if (!any) {
        errf("usage: umount dir\n", .{});
        return 1;
    }
    return if (fail) 1 else 0;
}

// ================= reboot / poweroff / halt =================
fn doReboot(cmd: usize) u8 {
    _ = linux.syscall0(.sync);
    const rc = linux.syscall4(.reboot, 0xfee1dead, 0x28121969, cmd, 0);
    if (!u.ok(rc)) {
        u.lastErrStr("reboot", rc);
        return 1;
    }
    return 0;
}

pub fn reboot(args: []const []const u8) u8 {
    _ = args;
    return doReboot(0x01234567);
}
pub fn poweroff(args: []const []const u8) u8 {
    _ = args;
    return doReboot(0x4321fedc);
}
pub fn halt(args: []const []const u8) u8 {
    _ = args;
    return doReboot(0xcdef0123);
}

// ================= cat / tee / hexdump =================
pub const cat = @import("cat.zig").run;

pub fn tee(args: []const []const u8) u8 {
    var i: usize = 0;
    var append = false;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        for (args[i][1..]) |c| {
            if (c == 'a') append = true;
        }
    }
    var files = u.Vec(u.File).init(u.alloc);
    for (args[i..]) |name| {
        const flags: std.posix.O = if (append)
            .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }
        else
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        const f = u.File.open(name, flags, 0o644) orelse {
            errf("tee: {s}: cannot open\n", .{name});
            continue;
        };
        files.push(f);
    }
    const stdout = u.File{ .fd = 1 };
    var buf: [65536]u8 = undefined;
    const stdin = u.File{ .fd = 0 };
    while (true) {
        const n = stdin.read(&buf);
        if (n == 0) break;
        _ = stdout.write(buf[0..n]);
        for (files.items) |f| _ = f.write(buf[0..n]);
    }
    for (files.items) |f| f.close();
    return 0;
}

pub fn hexdump(args: []const []const u8) u8 {
    var f = if (args.len > 0)
        (u.File.open(args[0], .{ .ACCMODE = .RDONLY }, 0) orelse {
            errf("hexdump: {s}: cannot open\n", .{args[0]});
            return 1;
        })
    else
        u.File{ .fd = 0 };
    defer if (args.len > 0) f.close();
    var buf: [16]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = f.read(&buf);
        if (n == 0) break;
        outf("{x:0>8} ", .{off});
        var kx: usize = 0;
        while (kx < 16) : (kx += 1) {
            if (kx % 8 == 0) out(" ");
            if (kx < n) {
                outf(" {x:0>2}", .{buf[kx]});
            } else {
                out("   ");
            }
        }
        out("  |");
        var ascii: [16]u8 = undefined;
        for (0..n) |k| {
            ascii[k] = if (buf[k] >= 0x20 and buf[k] < 0x7f) buf[k] else '.';
        }
        out(ascii[0..n]);
        out("|\n");
        off += n;
    }
    outf("{x:0>8}\n", .{off});
    return 0;
}

// ================= mkdir / rmdir / rm / touch / ln / chmod / chown =================
pub const mkdir = @import("permissions.zig").mkdir;

pub const rmdir = @import("remove.zig").rmdir;
pub const rm = @import("remove.zig").rm;

pub fn touch(args: []const []const u8) u8 {
    var fail = false;
    var any = false;
    for (args) |arg| {
        if (arg.len > 1 and arg[0] == '-') continue;
        any = true;
        const f = u.File.open(arg, .{ .ACCMODE = .WRONLY, .CREAT = true, .NOCTTY = true }, 0o644);
        if (f) |ff| ff.close();
        const rc = linux.utimensat(std.posix.AT.FDCWD, u.zstr(arg), null, 0);
        if (!u.ok(rc)) {
            u.lastErrStr(arg, rc);
            fail = true;
        }
    }
    if (!any) {
        errf("touch: missing operand\n", .{});
        return 1;
    }
    return if (fail) 1 else 0;
}

pub const ln = @import("fsops.zig").ln;

pub const chmod = @import("permissions.zig").chmod;

pub fn chown(args: []const []const u8) u8 {
    if (args.len < 2) {
        errf("usage: chown user[:group] file...\n", .{});
        return 1;
    }
    var owner = args[0];
    if (owner.len > 0 and owner[0] == '-') owner = owner[1..]; // tolerate flags
    var rest = u.Vec([]const u8).init(u.alloc);
    for (args[1..]) |arg| {
        if (arg.len > 1 and arg[0] == '-') continue;
        rest.push(arg);
    }
    if (rest.items.len == 0) {
        errf("usage: chown user[:group] file...\n", .{});
        return 1;
    }
    var uid: i64 = -1;
    var gid: i64 = -1;
    if (std.mem.indexOfScalar(u8, owner, ':')) |colon| {
        if (colon > 0) uid = idOf(owner[0..colon], true);
        if (colon + 1 < owner.len) gid = idOf(owner[colon + 1 ..], false);
    } else {
        uid = idOf(owner, true);
    }
    if (uid < 0 and gid < 0) {
        errf("chown: unknown user: {s}\n", .{owner});
        return 1;
    }
    var fail = false;
    for (rest.items) |path| {
        const rc = linux.chown(u.zstr(path), @truncate(@as(u64, @bitCast(uid))), @truncate(@as(u64, @bitCast(gid))));
        if (!u.ok(rc)) {
            u.lastErrStr(path, rc);
            fail = true;
        }
    }
    return if (fail) 1 else 0;
}

fn idOf(name: []const u8, user: bool) i64 {
    if (u.toInt(name)) |v| return v;
    return if (user) (u.findUser(name) orelse -1) else (u.findGroup(name) orelse -1);
}

// ================= ls / cp / mv =================
pub const ls = @import("ls.zig").run;

pub const cp = @import("fsops.zig").cp;
pub const mv = @import("fsops.zig").mv;

// ================= test / [ =================
pub const testApp = @import("test.zig").run;

// ================= help =================
pub fn help(args: []const []const u8) u8 {
    _ = args;
    const main = @import("main.zig");
    _ = main.usage();
    return 0;
}

comptime {
    // silence unused warnings for Vect helper mentioned earlier
}

pub fn mkfifo(args: []const []const u8) u8 {
    var rest = u.Vec([]const u8).init(u.alloc);
    var mode: u32 = 0o644;
    for (args) |arg| {
        if (arg.len > 1 and arg[0] == '-' and mode == 0o644 and u.parseMode(arg[1..]) != null) {
            mode = u.parseMode(arg[1..]).?;
            continue;
        }
        if (arg.len > 1 and arg[0] == '-') continue;
        rest.push(arg);
    }
    if (rest.items.len == 0) {
        errf("usage: mkfifo [-m mode] name\n", .{});
        return 1;
    }
    var fail = false;
    for (rest.items) |path| {
        const rc = linux.mknod(u.zstr(path), linux.S.IFIFO | mode, 0);
        if (!u.ok(rc) and u.errno(rc) != .EXIST) {
            u.lastErrStr(path, rc);
            fail = true;
        }
    }
    return if (fail) 1 else 0;
}

pub fn mknod(args: []const []const u8) u8 {
    var rest = u.Vec([]const u8).init(u.alloc);
    for (args) |arg| {
        if (arg.len > 1 and arg[0] == '-') continue;
        rest.push(arg);
    }
    if (rest.items.len < 2) {
        errf("usage: mknod name [c|b] [major minor]\n", .{});
        return 1;
    }
    const path = rest.items[0];
    var mode: u32 = 0o644;
    var dev: u32 = 0;
    if (rest.items.len >= 4) {
        const t = rest.items[1];
        const major = u.toInt(rest.items[2]) orelse return 1;
        const minor = u.toInt(rest.items[3]) orelse return 1;
        dev = @intCast(@as(u64, @intCast(major)) << 8 | @as(u64, @intCast(minor)));
        mode |= if (t.len > 0 and t[0] == 'c') linux.S.IFCHR else if (t[0] == 'b') linux.S.IFBLK else return 1;
    } else {
        mode |= linux.S.IFCHR; // default char device
    }
    const rc = linux.mknod(u.zstr(path), mode, @intCast(dev));
    if (!u.ok(rc)) {
        u.lastErrStr(path, rc);
        return 1;
    }
    return 0;
}
