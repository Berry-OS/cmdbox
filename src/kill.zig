// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// kill - util-linux / bash compatible: -s -n -SIG -NUM -l -L --, negative pids
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");

const RTMIN: u32 = 34;
const RTMAX: u32 = 64;

fn sigName(n: u32, buf: []u8) []const u8 {
    if (n > 0 and n < u.signals.len) return u.signals[n];
    if (n == RTMIN) return "RTMIN";
    if (n == RTMAX) return "RTMAX";
    if (n > RTMIN and n < RTMAX) {
        if (n - RTMIN <= RTMAX - n) return std.fmt.bufPrint(buf, "RTMIN+{d}", .{n - RTMIN}) catch "";
        return std.fmt.bufPrint(buf, "RTMAX-{d}", .{RTMAX - n}) catch "";
    }
    return "";
}

pub fn sigNum(s: []const u8) ?u32 {
    if (s.len > 0 and s[0] >= '0' and s[0] <= '9') {
        const v = std.fmt.parseInt(u32, s, 10) catch return null;
        return if (v <= RTMAX) v else null;
    }
    var name = s;
    if (name.len > 3 and std.ascii.eqlIgnoreCase(name[0..3], "SIG")) name = name[3..];
    var up: [32]u8 = undefined;
    if (name.len > up.len) return null;
    for (name, 0..) |ch, i| up[i] = std.ascii.toUpper(ch);
    const n = up[0..name.len];
    if (std.mem.eql(u8, n, "POLL")) return 29;
    if (std.mem.eql(u8, n, "IOT")) return 6;
    if (std.mem.eql(u8, n, "CLD")) return 17;
    if (std.mem.eql(u8, n, "EXIT")) return 0;
    for (u.signals, 0..) |sn, i| if (i > 0 and std.mem.eql(u8, sn, n)) return @intCast(i);
    if (std.mem.eql(u8, n, "RTMIN")) return RTMIN;
    if (std.mem.eql(u8, n, "RTMAX")) return RTMAX;
    if (std.mem.startsWith(u8, n, "RTMIN+")) {
        const k = std.fmt.parseInt(u32, n[6..], 10) catch return null;
        return if (RTMIN + k <= RTMAX) RTMIN + k else null;
    }
    if (std.mem.startsWith(u8, n, "RTMAX-")) {
        const k = std.fmt.parseInt(u32, n[6..], 10) catch return null;
        return if (k <= RTMAX - RTMIN) RTMAX - k else null;
    }
    return null;
}

fn usage() u8 {
    u.err("\nUsage:\n kill [options] <pid> [...]\n\nOptions:\n <pid> [...]            send signal to every <pid> listed\n -<signal>, -s, --signal <signal>\n                        specify the <signal> to be sent\n -l, --list=[<signal>]  list all signal names, or convert one to a name\n -L, --table            list all signal names in a nice table\n\n -h, --help     display this help and exit\n -V, --version  output version information and exit\n");
    return 1;
}

fn list(args: []const []const u8, table: bool) u8 {
    var o = u.Vec(u8).init(u.alloc);
    var buf: [32]u8 = undefined;
    if (args.len == 0) {
        var i: u32 = 1;
        while (i <= RTMAX) : (i += 1) {
            if (i > 31 and i < RTMIN) continue;
            const nm = sigName(i, &buf);
            if (nm.len == 0) continue;
            if (table) {
                var tb: [64]u8 = undefined;
                const line = std.fmt.bufPrint(&tb, "{d:>2} {s}\n", .{ i, nm }) catch continue;
                for (line) |ch| o.push(ch);
            } else {
                if (o.items.len > 0) o.push(' ');
                for (nm) |ch| o.push(ch);
            }
        }
        if (!table) o.push('\n');
        u.out(o.items);
        return 0;
    }
    var rc: u8 = 0;
    for (args) |a| {
        if (a.len > 0 and a[0] >= '0' and a[0] <= '9') {
            var v = std.fmt.parseInt(u32, a, 10) catch {
                u.errf("kill: unknown signal: {s}\n", .{a});
                rc = 1;
                continue;
            };
            if (v > 128) v -= 128;
            const nm = sigName(v, &buf);
            if (nm.len == 0) {
                u.errf("kill: unknown signal: {s}\n", .{a});
                rc = 1;
                continue;
            }
            u.outf("{s}\n", .{nm});
        } else if (sigNum(a)) |n| {
            u.outf("{d}\n", .{n});
        } else {
            u.errf("kill: unknown signal: {s}\n", .{a});
            rc = 1;
        }
    }
    return rc;
}

pub fn run(args: []const []const u8) u8 {
    if (args.len == 0) return usage();
    var sig: u32 = 15;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--list") or std.mem.eql(u8, a, "-L") or std.mem.eql(u8, a, "--table")) {
            return list(args[i + 1 ..], a[1] == 'L' or a[2] == 't');
        }
        if (std.mem.startsWith(u8, a, "--list=")) return list(&.{a[7..]}, false);
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            _ = usage();
            return 0;
        }
        if (std.mem.eql(u8, a, "-V") or std.mem.eql(u8, a, "--version")) {
            u.out("kill (cmdbox)\n");
            return 0;
        }
        if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "--all") or std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--pid")) continue;
        var sv: ?[]const u8 = null;
        if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--signal") or std.mem.eql(u8, a, "-n")) {
            if (i + 1 >= args.len) {
                u.errf("kill: option requires an argument -- '{s}'\n", .{a[1..]});
                return usage();
            }
            i += 1;
            sv = args[i];
        } else if (std.mem.startsWith(u8, a, "--signal=")) {
            sv = a[9..];
        } else if (a.len > 2 and (a[1] == 's' or a[1] == 'n') and sigNum(a[2..]) != null and !std.ascii.isDigit(a[1])) {
            sv = a[2..];
        } else {
            sv = a[1..];
        }
        sig = sigNum(sv.?) orelse {
            u.errf("kill: unknown signal: {s}\n", .{sv.?});
            return 1;
        };
    }
    if (i >= args.len) return usage();
    var rc: u8 = 0;
    for (args[i..]) |a| {
        const pid = std.fmt.parseInt(i32, a, 10) catch {
            u.errf("kill: failed to parse argument: '{s}'\n", .{a});
            rc = 1;
            continue;
        };
        const r = linux.syscall2(.kill, @bitCast(@as(isize, pid)), sig);
        if (!u.ok(r)) {
            u.errf("kill: sending signal to {d} failed: {s}\n", .{ pid, u.strerr(u.errno(r)) });
            rc = 1;
        }
    }
    return rc;
}
