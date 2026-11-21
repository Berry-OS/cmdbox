// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// id, uname, hostname with GNU coreutils / net-tools semantics
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("grp.h");
    @cInclude("unistd.h");
    @cInclude("sys/types.h");
});

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn tryHelp(prog: []const u8) u8 {
    u.errf("Try '{s} --help' for more information.\n", .{prog});
    return 1;
}

// resolve a long option by unique prefix; returns index or null (sets ambiguous)
fn matchLong(names: []const []const u8, given: []const u8, ambiguous: *bool) ?usize {
    var found: ?usize = null;
    ambiguous.* = false;
    for (names, 0..) |n, i| {
        if (same(n, given)) return i;
        if (std.mem.startsWith(u8, n, given)) {
            if (found != null) ambiguous.* = true;
            found = i;
        }
    }
    if (ambiguous.*) return null;
    return found;
}

// ===================== id =====================
const IdOpts = struct {
    user: bool = false,
    group: bool = false,
    groups: bool = false,
    name: bool = false,
    real: bool = false,
    zero: bool = false,
};

fn userName(uid: c.uid_t) ?[]const u8 {
    const p = c.getpwuid(uid) orelse return null;
    return std.mem.sliceTo(p.*.pw_name, 0);
}

fn groupNameOf(gid: c.gid_t) ?[]const u8 {
    const g = c.getgrgid(gid) orelse return null;
    return std.mem.sliceTo(g.*.gr_name, 0);
}

fn printId(o: *u.Vec(u8), idn: u32, want_name: bool, is_user: bool) void {
    var tmp: [64]u8 = undefined;
    if (want_name) {
        const nm = if (is_user) userName(idn) else groupNameOf(idn);
        if (nm) |n| {
            for (n) |ch| o.push(ch);
            return;
        }
        u.errf("id: cannot find name for {s} ID {d}\n", .{ if (is_user) "user" else "group", idn });
        id_failed = true;
    }
    const s = std.fmt.bufPrint(&tmp, "{d}", .{idn}) catch return;
    for (s) |ch| o.push(ch);
}

var id_failed = false;

fn idFull(o: *u.Vec(u8), idn: u32, is_user: bool) void {
    var tmp: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{idn}) catch return;
    for (s) |ch| o.push(ch);
    const nm = if (is_user) userName(idn) else groupNameOf(idn);
    if (nm) |n| {
        o.push('(');
        for (n) |ch| o.push(ch);
        o.push(')');
    }
}

pub fn id(args: []const []const u8) u8 {
    var op = IdOpts{};
    var names = u.Vec([]const u8).init(u.alloc);
    var opts = true;
    const longs = [_][]const u8{ "context", "group", "groups", "help", "name", "real", "user", "version", "zero" };
    for (args) |a| {
        if (!opts or a.len < 2 or a[0] != '-') {
            names.push(a);
            continue;
        }
        if (same(a, "--")) {
            opts = false;
            continue;
        }
        if (a[1] == '-') {
            var amb = false;
            const idx = matchLong(&longs, a[2..], &amb);
            if (idx == null) {
                if (amb) u.errf("id: option '{s}' is ambiguous\n", .{a}) else u.errf("id: unrecognized option '{s}'\n", .{a});
                return tryHelp("id");
            }
            const l = longs[idx.?];
            if (same(l, "group")) op.group = true else if (same(l, "groups")) op.groups = true else if (same(l, "name")) op.name = true else if (same(l, "real")) op.real = true else if (same(l, "user")) op.user = true else if (same(l, "zero")) op.zero = true else if (same(l, "help")) {
                u.out("Usage: id [OPTION]... [USER]...\nPrint user and group information for each specified USER,\nor (when USER omitted) for the current process.\n");
                return 0;
            } else if (same(l, "version")) {
                u.out("id (cmdbox)\n");
                return 0;
            }
            continue;
        }
        for (a[1..]) |ch| {
            switch (ch) {
                'u' => op.user = true,
                'g' => op.group = true,
                'G' => op.groups = true,
                'n' => op.name = true,
                'r' => op.real = true,
                'z' => op.zero = true,
                'a' => {},
                'Z' => {
                    u.err("id: --context (-Z) works only on an SELinux-enabled kernel\n");
                    return 1;
                },
                else => {
                    u.errf("id: invalid option -- '{c}'\n", .{ch});
                    return tryHelp("id");
                },
            }
        }
    }
    const nsel = @as(u8, @intFromBool(op.user)) + @intFromBool(op.group) + @intFromBool(op.groups);
    if (nsel > 1) {
        u.err("id: cannot print \"only\" of more than one choice\n");
        return 1;
    }
    const only = nsel == 1;
    if (!only and (op.name or op.real)) {
        u.err("id: cannot print only names or real IDs in default format\n");
        return 1;
    }
    if (!only and op.zero) {
        u.err("id: option --zero not permitted in default format\n");
        return 1;
    }
    var rc: u8 = 0;
    const sep: u8 = if (op.zero) 0 else ' ';
    const term: u8 = if (op.zero) 0 else '\n';
    if (names.items.len == 0) names.push("");
    for (names.items) |nm| {
        var uid: u32 = undefined;
        var euid: u32 = undefined;
        var gid: u32 = undefined;
        var egid: u32 = undefined;
        var glist = u.Vec(u32).init(u.alloc);
        if (nm.len == 0) {
            uid = c.getuid();
            euid = c.geteuid();
            gid = c.getgid();
            egid = c.getegid();
            const n = c.getgroups(0, null);
            if (n > 0) {
                const buf = u.alloc.alloc(c.gid_t, @intCast(n)) catch return 1;
                const m = c.getgroups(n, buf.ptr);
                var k: usize = 0;
                while (k < @max(m, 0)) : (k += 1) glist.push(buf[k]);
            }
            // effective gid always appears (first) in the list
            var has = false;
            for (glist.items) |g| if (g == egid) {
                has = true;
            };
            if (!has) glist.push(egid);
        } else {
            const pw: ?*c.struct_passwd = c.getpwnam(u.zstr(nm));
            var pwp = pw;
            if (pwp == null) {
                if (u.toInt(nm)) |v| {
                    if (v >= 0) pwp = c.getpwuid(@intCast(v));
                    if (pwp == null and v >= 0 and std.mem.indexOfAny(u8, nm, "+-") == null) {
                        // numeric id without a passwd entry
                        uid = @intCast(v);
                        euid = uid;
                        gid = uid;
                        egid = uid;
                        glist.push(gid);
                        emit(op, only, uid, euid, gid, egid, &glist, sep, term, nm);
                        continue;
                    }
                }
            }
            const p = pwp orelse {
                u.errf("id: '{s}': no such user\n", .{nm});
                rc = 1;
                continue;
            };
            uid = p.*.pw_uid;
            euid = uid;
            gid = p.*.pw_gid;
            egid = gid;
            var cnt: c_int = 64;
            var gbuf = u.alloc.alloc(c.gid_t, 64) catch return 1;
            while (c.getgrouplist(p.*.pw_name, gid, gbuf.ptr, &cnt) < 0) {
                gbuf = u.alloc.alloc(c.gid_t, @intCast(cnt)) catch return 1;
            }
            var k: usize = 0;
            while (k < @as(usize, @intCast(cnt))) : (k += 1) glist.push(gbuf[k]);
        }
        id_failed = false;
        emit(op, only, uid, euid, gid, egid, &glist, sep, term, nm);
        if (id_failed) rc = 1;
    }
    return rc;
}

fn emit(op: IdOpts, only: bool, uid: u32, euid: u32, gid: u32, egid: u32, glist: *u.Vec(u32), sep: u8, term: u8, nm: []const u8) void {
    _ = nm;
    var o = u.Vec(u8).init(u.alloc);
    if (only) {
        if (op.user) {
            printId(&o, if (op.real) uid else euid, op.name, true);
        } else if (op.group) {
            printId(&o, if (op.real) gid else egid, op.name, false);
        } else {
            // primary group first, then the rest without duplicates
            const first = if (op.real) gid else egid;
            printId(&o, first, op.name, false);
            for (glist.items, 0..) |g, gi| {
                if (g == first) continue;
                var dup = false;
                for (glist.items[0..gi]) |h| if (h == g) {
                    dup = true;
                };
                if (dup) continue;
                o.push(sep);
                printId(&o, g, op.name, false);
            }
        }
        o.push(term);
        u.out(o.items);
        return;
    }
    for ("uid=") |ch| o.push(ch);
    idFull(&o, uid, true);
    for (" gid=") |ch| o.push(ch);
    idFull(&o, gid, false);
    if (euid != uid) {
        for (" euid=") |ch| o.push(ch);
        idFull(&o, euid, true);
    }
    if (egid != gid) {
        for (" egid=") |ch| o.push(ch);
        idFull(&o, egid, false);
    }
    for (" groups=") |ch| o.push(ch);
    var firstg = true;
    for (glist.items, 0..) |g, i| {
        var dup = false;
        for (glist.items[0..i]) |h| if (h == g) {
            dup = true;
        };
        if (dup) continue;
        if (!firstg) o.push(',');
        firstg = false;
        idFull(&o, g, false);
    }
    o.push('\n');
    u.out(o.items);
}

// ===================== uname =====================
pub fn uname(args: []const []const u8) u8 {
    var want = [_]bool{false} ** 8; // s n r v m p i o
    var all = false;
    var extra: ?[]const u8 = null;
    var opts = true;
    const longs = [_][]const u8{ "all", "kernel-name", "nodename", "kernel-release", "kernel-version", "machine", "processor", "hardware-platform", "operating-system", "help", "version" };
    for (args) |a| {
        if (!opts or a.len < 2 or a[0] != '-') {
            if (extra == null) extra = a;
            continue;
        }
        if (same(a, "--")) {
            opts = false;
            continue;
        }
        if (a[1] == '-') {
            var amb = false;
            const idx = matchLong(&longs, a[2..], &amb);
            if (idx == null) {
                if (amb) u.errf("uname: option '{s}' is ambiguous\n", .{a}) else u.errf("uname: unrecognized option '{s}'\n", .{a});
                return tryHelp("uname");
            }
            switch (idx.?) {
                0 => all = true,
                1...8 => want[idx.? - 1] = true,
                9 => {
                    u.out("Usage: uname [OPTION]...\nPrint certain system information.  With no OPTION, same as -s.\n");
                    return 0;
                },
                else => {
                    u.out("uname (cmdbox)\n");
                    return 0;
                },
            }
            continue;
        }
        for (a[1..]) |ch| {
            switch (ch) {
                'a' => all = true,
                's' => want[0] = true,
                'n' => want[1] = true,
                'r' => want[2] = true,
                'v' => want[3] = true,
                'm' => want[4] = true,
                'p' => want[5] = true,
                'i' => want[6] = true,
                'o' => want[7] = true,
                else => {
                    u.errf("uname: invalid option -- '{c}'\n", .{ch});
                    return tryHelp("uname");
                },
            }
        }
    }
    if (extra) |e| {
        u.errf("uname: extra operand '{s}'\n", .{e});
        return tryHelp("uname");
    }
    if (all) {
        for (&want, 0..) |*w, i| w.* = i != 5 and i != 6 or w.*;
    }
    var any = false;
    for (want) |w| any = any or w;
    if (!any) want[0] = true;
    const un = std.posix.uname();
    var o = u.Vec(u8).init(u.alloc);
    var first = true;
    for (want, 0..) |w, i| {
        if (!w) continue;
        const v: []const u8 = switch (i) {
            0 => std.mem.sliceTo(&un.sysname, 0),
            1 => std.mem.sliceTo(&un.nodename, 0),
            2 => std.mem.sliceTo(&un.release, 0),
            3 => std.mem.sliceTo(&un.version, 0),
            4 => std.mem.sliceTo(&un.machine, 0),
            5, 6 => "unknown",
            else => "GNU/Linux",
        };
        if (!first) o.push(' ');
        first = false;
        for (v) |ch| o.push(ch);
    }
    o.push('\n');
    u.out(o.items);
    return 0;
}

// ===================== hostname =====================
pub fn hostname(args: []const []const u8) u8 {
    var short = false;
    var fqdn: bool = false;
    _ = &fqdn;
    var domain = false;
    var file: ?[]const u8 = null;
    var newname: ?[]const u8 = null;
    var i: usize = 0;
    var opts = true;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!opts or a.len < 2 or a[0] != '-') {
            if (newname != null) {
                u.err("hostname: you can't change the hostname and domain name at the same time\n");
                return 1;
            }
            newname = a;
            continue;
        }
        if (same(a, "--")) {
            opts = false;
            continue;
        }
        if (a[1] == '-') {
            const n = a[2..];
            if (same(n, "short")) short = true else if (same(n, "fqdn") or same(n, "long")) fqdn = true else if (same(n, "domain")) domain = true else if (same(n, "file")) {
                i += 1;
                if (i >= args.len) return 1;
                file = args[i];
            } else if (std.mem.startsWith(u8, n, "file=")) file = n[5..] else if (same(n, "help")) {
                u.out("Usage: hostname [-v] [-b] [-a] [-s|-f|-d|-i|-I|-y|-A] [-F file] [name]\n");
                return 0;
            } else {
                u.errf("hostname: unrecognized option '{s}'\n", .{a});
                return 1;
            }
            continue;
        }
        var k: usize = 1;
        while (k < a.len) : (k += 1) {
            switch (a[k]) {
                's' => short = true,
                'f' => fqdn = true, // nodename is already the FQDN here
                'd' => domain = true,
                'v', 'b', 'a', 'y', 'A', 'i', 'I' => {},
                'F' => {
                    if (k + 1 < a.len) {
                        file = a[k + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) return 1;
                        file = args[i];
                    }
                    k = a.len;
                },
                else => {
                    u.errf("hostname: invalid option -- '{c}'\n", .{a[k]});
                    return 1;
                },
            }
        }
    }
    if (file) |fp| {
        var f = u.File.open(fp, .{ .ACCMODE = .RDONLY }, 0) orelse {
            u.errf("hostname: can't open `{s}': No such file or directory\n", .{fp});
            return 1;
        };
        defer f.close();
        var buf: [256]u8 = undefined;
        while (u.readLine(&f, &buf)) |l| {
            const t = std.mem.trim(u8, l, " \t\r");
            if (t.len == 0 or t[0] == '#') continue;
            newname = u.alloc.dupe(u8, t) catch return 1;
            break;
        }
    }
    if (newname) |nm| {
        if (domain) {
            const rc = linux.syscall2(.setdomainname, @intFromPtr(u.zstr(nm).ptr), nm.len);
            if (!u.ok(rc)) {
                u.errf("hostname: you must be root to change the host name\n", .{});
                return 1;
            }
            return 0;
        }
        if (nm.len > 64) {
            u.err("hostname: name too long\n");
            return 1;
        }
        const rc = linux.syscall2(.sethostname, @intFromPtr(u.zstr(nm).ptr), nm.len);
        if (!u.ok(rc)) {
            u.err("hostname: you must be root to change the host name\n");
            return 1;
        }
        return 0;
    }
    const un = std.posix.uname();
    const name = std.mem.sliceTo(&un.nodename, 0);
    if (domain) {
        const dn = std.mem.sliceTo(&un.domainname, 0);
        if (dn.len == 0 or same(dn, "(none)")) {
            if (std.mem.indexOfScalar(u8, name, '.')) |d| {
                u.outf("{s}\n", .{name[d + 1 ..]});
                return 0;
            }
            u.out("\n");
            return 0;
        }
        u.outf("{s}\n", .{dn});
        return 0;
    }
    if (short) {
        const e = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
        u.outf("{s}\n", .{name[0..e]});
        return 0;
    }
    u.outf("{s}\n", .{name});
    return 0;
}
