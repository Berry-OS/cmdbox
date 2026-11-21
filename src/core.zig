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
// ================= sleep / seq / yes / sync =================
pub const sleep = @import("numbers.zig").sleep;
pub const seq = @import("numbers.zig").seq;

// ================= hostname / uname / date =================
// ================= id =================
// ================= kill / killall =================
// ================= ps =================
var comm_buf: [256]u8 = undefined;

// ================= free / df =================
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

// ================= mkdir / rmdir / rm / touch / ln / chmod / chown =================


pub const chmod = @import("permissions.zig").chmod;

// ================= ls / cp / mv =================
pub const ls = @import("ls.zig").run;


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

