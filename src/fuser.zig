// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// fuser - psmisc compatible: -a -k -m -s -u -v -i -w -SIGNAL -l -V (file and mount name spaces)
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const kill_mod = @import("kill.zig");
const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("unistd.h");
});

const usage_text =
    "Usage: fuser [-fIMuvw] [-a|-s] [-4|-6] [-c|-m|-n SPACE]\n" ++
    "             [-k [-i] [-SIGNAL]] NAME...\n" ++
    "       fuser -l\n" ++
    "       fuser -V\n" ++
    "Show which processes use the named files, sockets, or filesystems.\n\n" ++
    "  -a,--all              display unused files too\n" ++
    "  -i,--interactive      ask before killing (ignored without -k)\n" ++
    "  -I,--inode            use always inodes to compare files\n" ++
    "  -k,--kill             kill processes accessing the named file\n" ++
    "  -l,--list-signals     list available signal names\n" ++
    "  -m,--mount            show all processes using the named filesystems or\n" ++
    "                        block device\n" ++
    "  -M,--ismountpoint     fulfill request only if NAME is a mount point\n" ++
    "  -n,--namespace SPACE  search in this name space (file, udp, or tcp)\n" ++
    "  -s,--silent           silent operation\n" ++
    "  -SIGNAL               send this signal instead of SIGKILL\n" ++
    "  -u,--user             display user IDs\n" ++
    "  -v,--verbose          verbose output\n" ++
    "  -w,--writeonly        kill only processes with write access\n" ++
    "  -V,--version          display version information\n" ++
    "  -4,--ipv4             search IPv4 sockets only\n" ++
    "  -6,--ipv6             search IPv6 sockets only\n" ++
    "  udp/tcp names: [local_port][,[rmt_host][,[rmt_port]]]\n\n";

const Hit = struct { pid: i64, access: [5]u8, comm: []const u8, uid: u32 };

fn userName(uid: u32) []const u8 {
    if (c.getpwuid(uid)) |p| return std.mem.sliceTo(p.*.pw_name, 0);
    return std.fmt.allocPrint(u.alloc, "{d}", .{uid}) catch "?";
}

fn readSmall(path: []const u8) ?[]u8 {
    const rc = linux.open(u.zstr(path), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(rc)) return null;
    defer _ = linux.close(@intCast(rc));
    var data = u.Vec(u8).init(u.alloc);
    var buf: [65536]u8 = undefined;
    while (true) {
        const r = linux.read(@intCast(rc), &buf, buf.len);
        if (u.errno(rc) == .INTR) continue;
        if (!u.ok(r) or r == 0) break;
        data.pushSlice(buf[0..r]);
    }
    return data.items;
}

fn matches(st: u.Stat, target: u.Stat, mount: bool) bool {
    if (mount) return st.dev == target.dev;
    return st.dev == target.dev and st.ino == target.ino;
}

fn scan(target: u.Stat, mount: bool, me: i64) []Hit {
    var hits = u.Vec(Hit).init(u.alloc);
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir("/proc", &ents)) return hits.items;
    for (ents.items) |e| {
        const pid = std.fmt.parseInt(i64, e.name, 10) catch continue;
        if (pid == me) continue;
        var acc = [5]u8{ '.', '.', '.', '.', '.' };
        var any = false;
        var pb: [96]u8 = undefined;
        // cwd / root / exe
        const specials = [_]struct { n: []const u8, idx: usize, ch: u8 }{ .{ .n = "root", .idx = 1, .ch = 'r' }, .{ .n = "cwd", .idx = 2, .ch = 'c' }, .{ .n = "exe", .idx = 3, .ch = 'e' } };
        for (specials) |sp| {
            const path = std.fmt.bufPrint(&pb, "/proc/{d}/{s}", .{ pid, sp.n }) catch continue;
            if (u.stat(path, true)) |st| if (matches(st, target, mount)) {
                acc[sp.idx] = sp.ch;
                any = true;
            };
        }
        // open files
        const fdd = std.fmt.bufPrint(&pb, "/proc/{d}/fd", .{pid}) catch continue;
        var fds = u.Vec(u.DirEnt).init(u.alloc);
        if (u.listDir(fdd, &fds)) for (fds.items) |fe| {
            const fp = std.fmt.allocPrint(u.alloc, "/proc/{d}/fd/{s}", .{ pid, fe.name }) catch continue;
            const st = u.stat(fp, true) orelse continue;
            if (!matches(st, target, mount)) continue;
            any = true;
            var write = false;
            if (readSmall(std.fmt.allocPrint(u.alloc, "/proc/{d}/fdinfo/{s}", .{ pid, fe.name }) catch "")) |info| {
                var ls = std.mem.splitScalar(u8, info, '\n');
                while (ls.next()) |l| if (std.mem.startsWith(u8, l, "flags:")) {
                    const fl = std.fmt.parseInt(u32, std.mem.trim(u8, l[6..], " \t"), 8) catch 0;
                    write = (fl & 3) != 0;
                };
            }
            if (write) acc[0] = 'F' else if (acc[0] != 'F') acc[0] = 'f';
        };
        // memory maps
        if (readSmall(std.fmt.bufPrint(&pb, "/proc/{d}/maps", .{pid}) catch "")) |maps| {
            var ls = std.mem.splitScalar(u8, maps, '\n');
            while (ls.next()) |l| {
                var it = std.mem.tokenizeScalar(u8, l, ' ');
                _ = it.next();
                _ = it.next();
                _ = it.next();
                const dev = it.next() orelse continue;
                const ino = it.next() orelse continue;
                const colon = std.mem.indexOfScalar(u8, dev, ':') orelse continue;
                const maj = std.fmt.parseInt(u64, dev[0..colon], 16) catch continue;
                const min = std.fmt.parseInt(u64, dev[colon + 1 ..], 16) catch continue;
                const inode = std.fmt.parseInt(u64, ino, 10) catch continue;
                if (inode == 0) continue;
                const d = (maj << 32) | min;
                if (d == target.dev and (mount or inode == target.ino)) {
                    acc[4] = 'm';
                    any = true;
                    break;
                }
            }
        }
        if (!any) continue;
        var comm: []const u8 = "";
        if (readSmall(std.fmt.bufPrint(&pb, "/proc/{d}/comm", .{pid}) catch "")) |cm| comm = std.mem.trimEnd(u8, cm, "\n");
        var uid: u32 = 0;
        if (u.stat(std.fmt.bufPrint(&pb, "/proc/{d}", .{pid}) catch "", true)) |ps| uid = ps.uid;
        hits.push(.{ .pid = pid, .access = acc, .comm = comm, .uid = uid });
    }
    return hits.items;
}

pub fn run(args: []const []const u8) u8 {
    var all = false;
    var kill = false;
    var mount = false;
    var silent = false;
    var show_user = false;
    var verbose = false;
    var writeonly = false;
    var sig: u32 = 9;
    var names = u.Vec([]const u8).init(u.alloc);
    var i: usize = 0;
    var opts_done = false;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (opts_done or a.len < 2 or a[0] != '-') {
            names.push(a);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            opts_done = true;
            continue;
        }
        if (a[1] == '-') {
            const n = a[2..];
            if (std.mem.eql(u8, n, "all")) all = true else if (std.mem.eql(u8, n, "kill")) kill = true else if (std.mem.eql(u8, n, "mount")) mount = true else if (std.mem.eql(u8, n, "silent")) silent = true else if (std.mem.eql(u8, n, "user")) show_user = true else if (std.mem.eql(u8, n, "verbose")) verbose = true else if (std.mem.eql(u8, n, "writeonly")) writeonly = true else if (std.mem.eql(u8, n, "interactive") or std.mem.eql(u8, n, "inode") or std.mem.eql(u8, n, "ismountpoint") or std.mem.eql(u8, n, "ipv4") or std.mem.eql(u8, n, "ipv6")) {} else if (std.mem.eql(u8, n, "list-signals")) {
                a_list();
                return 0;
            } else if (std.mem.eql(u8, n, "version")) {
                u.out("fuser (cmdbox)\n");
                return 0;
            } else if (std.mem.eql(u8, n, "help")) {
                u.out(usage_text);
                return 0;
            } else {
                u.err(usage_text);
                return 1;
            }
            continue;
        }
        // cluster of short options, or -SIGNAL
        if (kill_mod.sigNumLoose(a[1..])) |sn| {
            if (a.len > 2 or !std.ascii.isDigit(a[1]) and std.mem.indexOfScalar(u8, "aikmMnsuvwVlIc46", a[1]) == null) {
                sig = sn;
                continue;
            }
        }
        for (a[1..]) |ch| switch (ch) {
            'a' => all = true,
            'k' => kill = true,
            'm', 'c' => mount = true,
            's' => silent = true,
            'u' => show_user = true,
            'v' => verbose = true,
            'w' => writeonly = true,
            'i', 'I', 'M', '4', '6', 'f' => {},
            'l' => {
                a_list();
                return 0;
            },
            'V' => {
                u.out("fuser (cmdbox)\n");
                return 0;
            },
            'n' => {
                i += 1; // name space argument
            },
            else => {
                u.err(usage_text);
                return 1;
            },
        };
    }
    if (names.items.len == 0) {
        u.err("No process specification given\n");
        u.err(usage_text);
        return 1;
    }
    const me: i64 = c.getpid();
    var rc: u8 = 1;
    var header_done = false;
    for (names.items) |name| {
        const st = u.stat(name, true) orelse {
            u.errf("Specified filename {s} does not exist.\n", .{name});
            continue;
        };
        const hits = scan(st, mount, me);
        if (hits.len == 0 and !all) {
            if (verbose and !silent) u.err("\n");
            continue;
        }
        if (verbose and !silent and !header_done) {
            u.err("                     USER        PID ACCESS COMMAND\n");
            header_done = true;
        }
        if (hits.len > 0) rc = 0;
        if (silent and !kill) continue;
        if (!silent) {
            var head = u.Vec(u8).init(u.alloc);
            head.pushSlice(absName(name));
            head.push(':');
            const pad: usize = if (verbose) 21 else 20;
            if (head.items.len < pad and (hits.len > 0 or verbose)) head.pushN(' ', pad - head.items.len);
            if (verbose) {
                u.err(head.items);
                // when the name column is full the first row starts on a fresh line
                if (head.items.len > pad) u.err("\n");
                var first = true;
                for (hits) |h| {
                    var row = u.Vec(u8).init(u.alloc);
                    if (!first or head.items.len <= pad) {
                        if (!first) row.pushN(' ', pad);
                    } else row.pushN(' ', pad);
                    first = false;
                    row.pushSlice(std.fmt.allocPrint(u.alloc, "{s: <8}{s} {s} {s}\n", .{ userName(h.uid), padNum(h.pid, 7), &h.access, h.comm }) catch "");
                    u.err(row.items);
                }
                if (hits.len == 0) u.err("\n");
            } else {
                u.err(head.items);
                for (hits) |h| {
                    var piece = u.Vec(u8).init(u.alloc);
                    piece.pushSlice(padNum(h.pid, 6));
                    u.out(piece.items);
                    var letters = u.Vec(u8).init(u.alloc);
                    for (h.access[1..]) |ch| if (ch != '.') letters.push(ch);
                    if (show_user) letters.pushSlice(std.fmt.allocPrint(u.alloc, "({s})", .{userName(h.uid)}) catch "");
                    if (letters.items.len > 0) u.err(letters.items);
                }
                u.err("\n");
            }
        }
        if (kill) {
            for (hits) |h| {
                if (writeonly and h.access[0] != 'F') continue;
                _ = linux.syscall2(.kill, @bitCast(@as(isize, @intCast(h.pid))), sig);
            }
        }
    }
    return rc;
}

fn padNum(n: i64, w: usize) []const u8 {
    const t = std.fmt.allocPrint(u.alloc, "{d}", .{@as(u64, @intCast(@max(n, 0)))}) catch return "";
    if (t.len >= w) return t;
    var o = u.Vec(u8).init(u.alloc);
    o.pushN(' ', w - t.len);
    o.pushSlice(t);
    return o.items;
}

fn absName(name: []const u8) []const u8 {
    var buf: [u.PATH_MAX]u8 = undefined;
    var full: []const u8 = name;
    if (name.len == 0 or name[0] != '/') {
        const r = linux.getcwd(&buf, buf.len);
        const cwd = if (u.ok(r)) std.mem.sliceTo(&buf, 0) else "/";
        full = std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ cwd, name }) catch name;
    }
    var parts = u.Vec([]const u8).init(u.alloc);
    var it = std.mem.splitScalar(u8, full, '/');
    while (it.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.items.len > 0) parts.pop();
            continue;
        }
        parts.push(p);
    }
    var o = u.Vec(u8).init(u.alloc);
    for (parts.items) |p| {
        o.push('/');
        o.pushSlice(p);
    }
    if (o.items.len == 0) o.push('/');
    return o.items;
}

fn a_list() void {
    var o = u.Vec(u8).init(u.alloc);
    var line_len: usize = 0;
    var n: usize = 1;
    while (n < u.signals.len) : (n += 1) {
        const nm = if (n == 29) "POLL" else u.signals[n];
        if (line_len + nm.len + 1 > 79) {
            o.push('\n');
            line_len = 0;
        } else if (line_len > 0) {
            o.push(' ');
            line_len += 1;
        }
        o.pushSlice(nm);
        line_len += nm.len;
    }
    o.push('\n');
    u.out(o.items);
}
