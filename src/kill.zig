// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// kill - util-linux 2.41 compatible: -s -q -p -a -l -L -d -r --verbose, -SIG/-NUM, process names
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");

const RTMIN: u32 = 34;
const RTMAX: u32 = 64;

const Sig = struct { name: []const u8, num: u32 };
// util-linux signames.c (Linux) in table order
const table = [_]Sig{
    .{ .name = "HUP", .num = 1 },     .{ .name = "INT", .num = 2 },     .{ .name = "QUIT", .num = 3 },    .{ .name = "ILL", .num = 4 },
    .{ .name = "TRAP", .num = 5 },    .{ .name = "ABRT", .num = 6 },    .{ .name = "IOT", .num = 6 },     .{ .name = "BUS", .num = 7 },
    .{ .name = "FPE", .num = 8 },     .{ .name = "KILL", .num = 9 },    .{ .name = "USR1", .num = 10 },   .{ .name = "SEGV", .num = 11 },
    .{ .name = "USR2", .num = 12 },   .{ .name = "PIPE", .num = 13 },   .{ .name = "ALRM", .num = 14 },   .{ .name = "TERM", .num = 15 },
    .{ .name = "STKFLT", .num = 16 }, .{ .name = "CHLD", .num = 17 },   .{ .name = "CLD", .num = 17 },    .{ .name = "CONT", .num = 18 },
    .{ .name = "STOP", .num = 19 },   .{ .name = "TSTP", .num = 20 },   .{ .name = "TTIN", .num = 21 },   .{ .name = "TTOU", .num = 22 },
    .{ .name = "URG", .num = 23 },    .{ .name = "XCPU", .num = 24 },   .{ .name = "XFSZ", .num = 25 },   .{ .name = "VTALRM", .num = 26 },
    .{ .name = "PROF", .num = 27 },   .{ .name = "WINCH", .num = 28 },  .{ .name = "IO", .num = 29 },     .{ .name = "POLL", .num = 29 },
    .{ .name = "PWR", .num = 30 },    .{ .name = "SYS", .num = 31 },    .{ .name = "RTMIN", .num = RTMIN }, .{ .name = "RTMAX", .num = RTMAX },
};

/// number -> name: table entry (first match, RTMIN/RTMAX excluded) or "RT<n>" for real-time signals
pub fn sigName(n: u32, buf: []u8) ?[]const u8 {
    for (table) |s| {
        if (s.num == n and s.num != RTMIN and s.num != RTMAX) return s.name;
    }
    if (n >= RTMIN and n <= RTMAX) return std.fmt.bufPrint(buf, "RT{d}", .{n - RTMIN}) catch null;
    return null;
}

/// name or number -> signal number (0 is valid)
pub fn sigNum(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    if (std.ascii.isDigit(s[0])) {
        const v = std.fmt.parseInt(u32, s, 10) catch return null;
        return if (v <= RTMAX) v else null;
    }
    var name = s;
    if (name.len > 3 and std.ascii.eqlIgnoreCase(name[0..3], "SIG")) name = name[3..];
    var up: [32]u8 = undefined;
    if (name.len > up.len) return null;
    for (name, 0..) |ch, i| up[i] = std.ascii.toUpper(ch);
    const n = up[0..name.len];
    for (table) |t| {
        if (t.num == RTMIN or t.num == RTMAX) continue;
        if (std.mem.eql(u8, t.name, n)) return t.num;
    }
    if (std.mem.startsWith(u8, n, "RTMIN+")) {
        const k = std.fmt.parseInt(u32, n[6..], 10) catch return null;
        return if (RTMIN + k <= RTMAX) RTMIN + k else null;
    }
    if (std.mem.startsWith(u8, n, "RTMAX-")) {
        const k = std.fmt.parseInt(u32, n[6..], 10) catch return null;
        return if (k <= RTMAX - RTMIN) RTMAX - k else null;
    }
    if (std.mem.startsWith(u8, n, "RT")) {
        const k = std.fmt.parseInt(u32, n[2..], 10) catch return null;
        return if (RTMIN + k <= RTMAX) RTMIN + k else null;
    }
    return null;
}

/// permissive lookup used by sh (trap), timeout, pkill, fuser: also EXIT, RTMIN and RTMAX
pub fn sigNumLoose(s: []const u8) ?u32 {
    if (sigNum(s)) |n| return n;
    var name = s;
    if (name.len > 3 and std.ascii.eqlIgnoreCase(name[0..3], "SIG")) name = name[3..];
    if (std.ascii.eqlIgnoreCase(name, "EXIT")) return 0;
    if (std.ascii.eqlIgnoreCase(name, "RTMIN")) return RTMIN;
    if (std.ascii.eqlIgnoreCase(name, "RTMAX")) return RTMAX;
    return null;
}

fn printAll(to_err: bool, pretty: bool) void {
    var o = u.Vec(u8).init(u.alloc);
    if (pretty) {
        var width: usize = 80;
        if (u.getEnv("COLUMNS")) |cv| {
            if (std.fmt.parseInt(usize, cv, 10)) |w| {
                if (w > 0) width = w;
            } else |_| {}
        } else {
            var ws: extern struct { row: u16, col: u16, x: u16, y: u16 } = undefined;
            if (u.ok(linux.ioctl(1, 0x5413, @intFromPtr(&ws))) and ws.col > 0) width = ws.col;
        }
        const per_row = @max(1, width / 11);
        var n: usize = 0;
        for (table) |s| {
            o.pushSlice(std.fmt.allocPrint(u.alloc, "{d: >2} {s: <8}", .{ s.num, s.name }) catch "");
            n += 1;
            if (n % per_row == 0) o.push('\n');
        }
        if (n % per_row != 0) o.push('\n');
    } else {
        var lpos: usize = 0;
        const extra = [_][]const u8{ "RT<N>", "RTMIN+<N>", "RTMAX-<N>" };
        var names = u.Vec([]const u8).init(u.alloc);
        for (table) |s| {
            if (s.num == RTMIN or s.num == RTMAX) continue;
            names.push(s.name);
        }
        for (extra) |e| names.push(e);
        for (names.items) |nm| {
            const lth = 1 + nm.len;
            if (lpos + lth > 72) {
                o.push('\n');
                lpos = 0;
            }
            if (lpos > 0) o.push(' ');
            o.pushSlice(nm);
            lpos += lth;
        }
        o.push('\n');
    }
    if (to_err) u.err(o.items) else u.out(o.items);
}

fn usageText() []const u8 {
    return "\nUsage:\n kill [options] <pid>|<name>...\n\nForcibly terminate a process.\n\nOptions:\n -a, --all              do not restrict the name-to-pid conversion to processes\n                          with the same uid as the present process\n -s, --signal <signal>  send this <signal> instead of SIGTERM\n -q, --queue <value>    use sigqueue(2), not kill(2), and pass <value> as data\n     --timeout <milliseconds> <follow-up signal>\n                        wait up to timeout and send follow-up signal\n -p, --pid              print pids without signaling them\n -l, --list[=<signal>|=0x<sigmask>]\n                        list signal names, convert a signal number to a name,\n                         or convert a signal mask to names\n -L, --table            list signal names and numbers\n -r, --require-handler  do not send signal if signal handler is not present\n -d, --show-process-state <pid>\n                        show signal related fields in /proc/<pid>/status\n     --verbose          print pids that will be signaled\n\n -h, --help             display this help\n -V, --version          display version\n\nFor more details see kill(1).\n";
}

fn maskNames(mask: u64, o: *u.Vec(u8)) void {
    var buf: [16]u8 = undefined;
    var i: u32 = 1;
    while (i <= 64) : (i += 1) {
        if (mask & (@as(u64, 1) << @intCast(i - 1)) == 0) continue;
        const nm = sigName(i, &buf) orelse continue;
        o.pushSlice(nm);
        o.push(' ');
    }
}

fn list(args: []const []const u8) u8 {
    if (args.len > 1) {
        u.err("kill: too many arguments\n");
        return 1;
    }
    if (args.len == 0) {
        printAll(false, false);
        return 0;
    }
    const a = args[0];
    var buf: [16]u8 = undefined;
    if (std.mem.startsWith(u8, a, "0x") or std.mem.startsWith(u8, a, "0X")) {
        const m = std.fmt.parseInt(u64, a[2..], 16) catch {
            u.errf("kill: unknown signal: {s}\n", .{a});
            return 1;
        };
        var o = u.Vec(u8).init(u.alloc);
        maskNames(m, &o);
        if (o.items.len > 0) o.items.len -= 1;
        o.push('\n');
        u.out(o.items);
        return 0;
    }
    if (a.len > 0 and std.ascii.isDigit(a[0])) {
        var v = std.fmt.parseInt(u32, a, 10) catch {
            u.errf("kill: unknown signal: {s}\n", .{a});
            return 1;
        };
        if (v == 0) {
            u.out("0\n");
            return 0;
        }
        if (v > 128) v -= 128;
        if (sigName(v, &buf)) |nm| {
            u.outf("{s}\n", .{nm});
            return 0;
        }
        u.errf("kill: unknown signal: {s}\n", .{a});
        return 1;
    }
    if (sigNum(a)) |n| {
        if (n == 0) u.out("0\n") else u.outf("{s}\n", .{sigName(n, &buf) orelse ""});
        return 0;
    }
    u.errf("kill: unknown signal: {s}\n", .{a});
    return 1;
}

fn readStatus(pid: i32, key: []const u8) ?u64 {
    var path: [64]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/proc/{d}/status", .{pid}) catch return null;
    var f = u.File.open(p, .{ .ACCMODE = .RDONLY }, 0) orelse return null;
    defer f.close();
    var lines = u.Vec([]const u8).init(u.alloc);
    u.readAllLines(&f, &lines);
    for (lines.items) |ln| {
        if (std.mem.startsWith(u8, ln, key) and ln.len > key.len and ln[key.len] == ':') {
            const v = std.mem.trim(u8, ln[key.len + 1 ..], " \t");
            return std.fmt.parseInt(u64, v, 16) catch null;
        }
    }
    return null;
}

fn showState(arg: []const u8) u8 {
    const pid = std.fmt.parseInt(i32, arg, 10) catch {
        u.errf("kill: failed to parse argument: '{s}'\n", .{arg});
        return 1;
    };
    var any = false;
    const keys = [_]struct { k: []const u8, label: []const u8 }{
        .{ .k = "SigPnd", .label = "Pending" },
        .{ .k = "ShdPnd", .label = "Shared pending" },
        .{ .k = "SigBlk", .label = "Blocked" },
        .{ .k = "SigIgn", .label = "Ignored" },
        .{ .k = "SigCgt", .label = "Caught" },
    };
    for (keys) |kv| {
        const m = readStatus(pid, kv.k) orelse continue;
        any = true;
        if (m == 0) continue;
        var o = u.Vec(u8).init(u.alloc);
        maskNames(m, &o);
        u.outf("{s}: {s}\n", .{ kv.label, o.items });
    }
    if (!any) {
        u.errf("kill: cannot open /proc/{d}/status\n", .{pid});
        return 1;
    }
    return 0;
}

/// pids of processes whose name matches (comm or argv[0] basename); like util-linux, only own-uid unless -a
fn findByName(name: []const u8, all: bool, out: *u.Vec(i32)) void {
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDirRaw("/proc", &ents)) return;
    const me: i32 = @intCast(linux.getpid());
    const uid = linux.getuid();
    for (ents.items) |en| {
        const nm: []const u8 = en.name;
        const pid = std.fmt.parseInt(i32, nm, 10) catch continue;
        if (pid == me) continue;
        var path: [64]u8 = undefined;
        if (!all) {
            const st = u.stat(std.fmt.bufPrint(&path, "/proc/{d}", .{pid}) catch continue, true) orelse continue;
            if (st.uid != uid) continue;
        }
        var buf: [4096]u8 = undefined;
        const cp = std.fmt.bufPrint(&path, "/proc/{d}/comm", .{pid}) catch continue;
        var matched = false;
        if (u.File.open(cp, .{ .ACCMODE = .RDONLY }, 0)) |f0| {
            var f = f0;
            const n = f.read(&buf);
            f.close();
            const comm = std.mem.trimEnd(u8, buf[0..n], "\n");
            if (std.mem.eql(u8, comm, name)) matched = true;
        }
        if (!matched) {
            const lp = std.fmt.bufPrint(&path, "/proc/{d}/cmdline", .{pid}) catch continue;
            if (u.File.open(lp, .{ .ACCMODE = .RDONLY }, 0)) |f0| {
                var f = f0;
                const n = f.read(&buf);
                f.close();
                const arg0 = std.mem.sliceTo(buf[0..n], 0);
                if (std.mem.eql(u8, u.basename(arg0), name)) matched = true;
            }
        }
        if (matched) out.push(pid);
    }
}

pub fn run(args: []const []const u8) u8 {
    var sig: ?u32 = null;
    var sig_given = false;
    var pid_only = false;
    var all = false;
    var verbose = false;
    var require_handler = false;
    var queue: ?i32 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--list")) {
            return list(args[i + 1 ..]);
        }
        if (std.mem.startsWith(u8, a, "--list=")) return list(&.{a[7..]});
        if (std.mem.eql(u8, a, "-L") or std.mem.eql(u8, a, "--table")) {
            printAll(false, true);
            return 0;
        }
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            u.out(usageText());
            return 0;
        }
        if (std.mem.eql(u8, a, "-V") or std.mem.eql(u8, a, "--version")) {
            u.out("kill from util-linux 2.41.5 (with: sigqueue, pidfd)\n");
            return 0;
        }
        if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "--all")) {
            all = true;
            continue;
        }
        if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--pid")) {
            pid_only = true;
            continue;
        }
        if (std.mem.eql(u8, a, "-r") or std.mem.eql(u8, a, "--require-handler")) {
            require_handler = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
            continue;
        }
        if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--show-process-state")) {
            if (i + 1 >= args.len) {
                u.errf("kill: option requires an argument -- 'd'\n", .{});
                return 1;
            }
            return showState(args[i + 1]);
        }
        if (std.mem.eql(u8, a, "--timeout")) {
            u.err("kill: --timeout is not supported\n");
            return 1;
        }
        if (std.mem.eql(u8, a, "-q") or std.mem.eql(u8, a, "--queue")) {
            if (i + 1 >= args.len) {
                u.err("kill: option requires an argument -- 'q'\n");
                return 1;
            }
            i += 1;
            queue = std.fmt.parseInt(i32, args[i], 0) catch {
                u.errf("kill: invalid value: {s}\n", .{args[i]});
                return 1;
            };
            continue;
        }
        if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--signal")) {
            if (i + 1 >= args.len) {
                u.err("kill: option requires an argument -- 's'\n");
                return 1;
            }
            i += 1;
            sig = sigNum(args[i]) orelse {
                u.errf("kill: unknown signal {s}; valid signals:\n", .{args[i]});
                printAll(true, true);
                return 1;
            };
            sig_given = true;
            continue;
        }
        // -<signal>
        sig = sigNum(a[1..]) orelse {
            u.errf("kill: invalid signal name or number: {s}\n", .{a[1..]});
            return 1;
        };
        sig_given = true;
    }
    if (pid_only and sig_given) {
        u.err("kill: --pid and --signal are mutually exclusive\n");
        return 1;
    }
    if (i >= args.len) {
        u.err("kill: not enough arguments\n");
        return 1;
    }
    const signum = sig orelse 15;
    var rc: u8 = 0;
    for (args[i..]) |a| {
        var pids = u.Vec(i32).init(u.alloc);
        if (std.fmt.parseInt(i32, a, 10)) |p| pids.push(p) else |_| {
            findByName(a, all, &pids);
            if (pids.items.len == 0) {
                u.errf("kill: cannot find process \"{s}\"\n", .{a});
                rc = 1;
                continue;
            }
        }
        for (pids.items) |pid| {
            if (pid_only) {
                u.outf("{d}\n", .{pid});
                continue;
            }
            if (require_handler and pid > 0) {
                const cgt = readStatus(pid, "SigCgt") orelse 0;
                if (signum > 0 and cgt & (@as(u64, 1) << @intCast(signum - 1)) == 0) continue;
            }
            if (verbose) u.outf("sending signal {d} to pid {d}\n", .{ signum, pid });
            var r: usize = undefined;
            if (queue) |qv| {
                var info = [_]u8{0} ** 128;
                const si_code: i32 = -1; // SI_QUEUE
                std.mem.writeInt(i32, info[0..4], @intCast(signum), .little);
                std.mem.writeInt(i32, info[8..12], si_code, .little);
                const ptr_size = @sizeOf(usize);
                const off: usize = if (ptr_size == 8) 16 else 12;
                std.mem.writeInt(i32, info[off..][0..4], @intCast(linux.getpid()), .little);
                std.mem.writeInt(u32, info[off + 4 ..][0..4], linux.getuid(), .little);
                std.mem.writeInt(i32, info[off + 8 ..][0..4], qv, .little);
                r = linux.syscall3(.rt_sigqueueinfo, @intCast(pid), signum, @intFromPtr(&info));
            } else r = linux.syscall2(.kill, @bitCast(@as(isize, pid)), signum);
            if (!u.ok(r)) {
                u.errf("kill: sending signal to {d} failed: {s}\n", .{ pid, u.strerr(u.errno(r)) });
                rc = 1;
            }
        }
    }
    return rc;
}
