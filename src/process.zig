// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0
const std = @import("std");
const u = @import("util.zig");
const linux = std.os.linux;
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("unistd.h");
    @cInclude("pwd.h");
    @cInclude("grp.h");
    @cInclude("errno.h");
});
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn whoami(args: []const []const u8) u8 {
    if (args.len != 0) return bad("whoami");
    const user = c.getpwuid(c.geteuid()) orelse return 1;
    u.outf("{s}\n", .{std.mem.sliceTo(user.*.pw_name, 0)});
    return 0;
}
fn groupName(id: c.gid_t) void {
    if (c.getgrgid(id)) |group| u.out(std.mem.sliceTo(group.*.gr_name, 0)) else u.outf("{d}", .{id});
}
pub fn groups(args: []const []const u8) u8 {
    if (args.len == 0) {
        const count = c.getgroups(0, null);
        if (count < 0) return 1;
        const ids = u.alloc.alloc(c.gid_t, @intCast(count)) catch return 1;
        if (c.getgroups(count, ids.ptr) < 0) return 1;
        const primary = c.getgid();
        groupName(primary);
        for (ids, 0..) |id, index| {
            if (id == primary) continue;
            var duplicate = false;
            for (ids[0..index]) |previous| if (previous == id) {
                duplicate = true;
                break;
            };
            if (!duplicate) {
                u.out(" ");
                groupName(id);
            }
        }
        u.out("\n");
        return 0;
    }
    var failed = false;
    var options = true;
    for (args) |name| {
        if (options and same(name, "--")) {
            options = false;
            continue;
        }
        if (options and name.len > 1 and name[0] == '-') return bad("groups");
        const user = c.getpwnam(u.zstr(name)) orelse {
            u.errf("groups: {s}: no such user\n", .{name});
            failed = true;
            continue;
        };
        const primary = user.*.pw_gid;
        var count: c_int = 0;
        _ = c.getgrouplist(u.zstr(name), primary, null, &count);
        if (count < 0) return 1;
        const ids = u.alloc.alloc(c.gid_t, @intCast(count)) catch return 1;
        if (c.getgrouplist(u.zstr(name), primary, ids.ptr, &count) < 0) return 1;
        u.outf("{s} :", .{name});
        for (ids[0..@intCast(count)]) |id| {
            u.out(" ");
            groupName(id);
        }
        u.out("\n");
    }
    return if (failed) 1 else 0;
}
pub fn pwdx(args: []const []const u8) u8 {
    if (args.len == 0) return bad("pwdx");
    var failed = false;
    for (args) |arg| {
        const pid = std.fmt.parseInt(u32, arg, 10) catch {
            failed = true;
            continue;
        };
        const path = std.fmt.allocPrintSentinel(u.alloc, "/proc/{d}/cwd", .{pid}, 0) catch return 1;
        var buffer: [u.PATH_MAX]u8 = undefined;
        const rc = linux.readlink(path, &buffer, buffer.len);
        if (!u.ok(rc)) {
            u.errf("{d}: {s}\n", .{ pid, if (u.errno(rc) == .NOENT) "No such process" else u.strerr(u.errno(rc)) });
            failed = true;
        } else u.outf("{d}: {s}\n", .{ pid, buffer[0..rc] });
    }
    return if (failed) 1 else 0;
}
pub fn nice(args: []const []const u8) u8 {
    if (args.len == 0) {
        c.__errno_location().* = 0;
        const value = c.nice(0);
        if (value == -1 and c.__errno_location().* != 0) return 1;
        u.outf("{d}\n", .{value});
        return 0;
    }
    var adjustment: c_int = 10;
    var i: usize = 0;
    if (same(args[0], "--")) i = 1 else if (same(args[0], "-n") or same(args[0], "--adjustment")) {
        if (args.len < 3) return bad("nice");
        adjustment = std.fmt.parseInt(c_int, args[1], 10) catch return bad("nice");
        i = 2;
    } else if (std.mem.startsWith(u8, args[0], "-n") and args[0].len > 2) {
        adjustment = std.fmt.parseInt(c_int, args[0][2..], 10) catch return bad("nice");
        i = 1;
    } else if (std.mem.startsWith(u8, args[0], "--adjustment=")) {
        adjustment = std.fmt.parseInt(c_int, args[0][13..], 10) catch return bad("nice");
        i = 1;
    } else if (args[0].len > 1 and args[0][0] == '-') {
        adjustment = std.fmt.parseInt(c_int, args[0][1..], 10) catch return bad("nice");
        i = 1;
    }
    if (i >= args.len) return bad("nice");
    c.__errno_location().* = 0;
    const value = c.nice(adjustment);
    if (value == -1 and c.__errno_location().* != 0) {
        u.errf("nice: cannot change niceness\n", .{});
    }
    const command = args[i..];
    const av = u.alloc.allocSentinel([*c]u8, command.len, null) catch return 1;
    for (command, 0..) |arg, index| av[index] = @constCast(u.zstr(arg).ptr);
    _ = c.execvp(av[0], av.ptr);
    return if (c.__errno_location().* == c.ENOENT) 127 else 126;
}
pub fn usleep(args: []const []const u8) u8 {
    if (args.len != 1) return bad("usleep");
    const micros = std.fmt.parseInt(u64, args[0], 10) catch return bad("usleep");
    const value = std.fmt.allocPrint(u.alloc, "{d}.{d:0>6}", .{ micros / 1000000, micros % 1000000 }) catch return 1;
    return @import("numbers.zig").sleep(&.{value});
}
fn bad(name: []const u8) u8 {
    u.errf("{s}: invalid option or operand\n", .{name});
    return if (same(name, "nice")) 125 else 1;
}
