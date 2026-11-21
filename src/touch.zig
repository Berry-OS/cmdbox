// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// touch - GNU touch(1): -a -m -c -d -f -h -r -t --time
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const dt = @import("datetime.zig");

const UTIME_NOW: i64 = (1 << 30) - 1;
const UTIME_OMIT: i64 = (1 << 30) - 2;
const Time64 = extern struct { sec: i64, nsec: i64 };

fn usageErr() u8 {
    u.err("Try 'touch --help' for more information.\n");
    return 1;
}

const LongOpt = struct { name: []const u8, arg: bool, short: u8 };
const longs = [_]LongOpt{
    .{ .name = "no-create", .arg = false, .short = 'c' },
    .{ .name = "date", .arg = true, .short = 'd' },
    .{ .name = "no-dereference", .arg = false, .short = 'h' },
    .{ .name = "reference", .arg = true, .short = 'r' },
    .{ .name = "time", .arg = true, .short = 'T' },
    .{ .name = "help", .arg = false, .short = 'H' },
    .{ .name = "version", .arg = false, .short = 'V' },
};

pub fn run(args: []const []const u8) u8 {
    var set_a = false;
    var set_m = false;
    var no_create = false;
    var no_deref = false;
    var date_str: ?[]const u8 = null;
    var stamp: ?[]const u8 = null;
    var ref: ?[]const u8 = null;
    var files = u.Vec([]const u8).init(u.alloc);
    var opts = true;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!opts or a.len < 2 or a[0] != '-') {
            files.push(a);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            opts = false;
            continue;
        }
        if (a[1] == '-') {
            var name = a[2..];
            var inl: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, name, '=')) |e| {
                inl = name[e + 1 ..];
                name = name[0..e];
            }
            var found: ?LongOpt = null;
            var cnt: usize = 0;
            for (longs) |l| {
                if (std.mem.eql(u8, l.name, name)) {
                    found = l;
                    cnt = 1;
                    break;
                }
                if (std.mem.startsWith(u8, l.name, name)) {
                    found = l;
                    cnt += 1;
                }
            }
            if (found == null) {
                u.errf("touch: unrecognized option '{s}'\n", .{a});
                return usageErr();
            }
            if (cnt > 1) {
                u.errf("touch: option '{s}' is ambiguous\n", .{a});
                return usageErr();
            }
            const l = found.?;
            var v: ?[]const u8 = null;
            if (l.arg) {
                if (inl) |x| {
                    v = x;
                } else if (i + 1 < args.len) {
                    i += 1;
                    v = args[i];
                } else {
                    u.errf("touch: option '--{s}' requires an argument\n", .{l.name});
                    return usageErr();
                }
            } else if (inl != null) {
                u.errf("touch: option '--{s}' doesn't allow an argument\n", .{l.name});
                return usageErr();
            }
            switch (l.short) {
                'c' => no_create = true,
                'h' => no_deref = true,
                'd' => date_str = v,
                'r' => ref = v,
                'T' => {
                    const w = v.?;
                    if (isWord(w, "atime", "access", "use")) {
                        set_a = true;
                    } else if (isWord(w, "mtime", "modify", "")) {
                        set_m = true;
                    } else {
                        u.errf("touch: invalid argument '{s}' for '--time'\n", .{w});
                        u.err("Valid arguments are:\n  - 'atime', 'access', 'use'\n  - 'mtime', 'modify'\nTry 'touch --help' for more information.\n");
                        return 1;
                    }
                },
                'H' => {
                    u.out("Usage: touch [OPTION]... FILE...\nUpdate the access and modification times of each FILE to the current time.\n");
                    return 0;
                },
                'V' => {
                    u.out("touch (cmdbox)\n");
                    return 0;
                },
                else => {},
            }
            continue;
        }
        var k: usize = 1;
        while (k < a.len) : (k += 1) {
            const ch = a[k];
            switch (ch) {
                'a' => set_a = true,
                'm' => set_m = true,
                'c' => no_create = true,
                'f' => {},
                'h' => no_deref = true,
                'd', 'r', 't' => {
                    var v: []const u8 = undefined;
                    if (k + 1 < a.len) {
                        v = a[k + 1 ..];
                    } else if (i + 1 < args.len) {
                        i += 1;
                        v = args[i];
                    } else {
                        u.errf("touch: option requires an argument -- '{c}'\n", .{ch});
                        return usageErr();
                    }
                    if (ch == 'd') date_str = v else if (ch == 'r') ref = v else stamp = v;
                    k = a.len;
                },
                else => {
                    u.errf("touch: invalid option -- '{c}'\n", .{ch});
                    return usageErr();
                },
            }
        }
    }
    if (files.items.len == 0) {
        u.err("touch: missing file operand\nTry 'touch --help' for more information.\n");
        return 1;
    }
    if (!set_a and !set_m) {
        set_a = true;
        set_m = true;
    }

    // resolve the timestamp to apply
    var use_now = true;
    var when: dt.Ts = .{ .sec = 0 };
    var ref_at: dt.Ts = .{ .sec = 0 };
    var ref_mt: dt.Ts = .{ .sec = 0 };
    var have_ref = false;
    if (ref) |rp| {
        const st = u.stat(rp, !no_deref) orelse {
            u.errf("touch: failed to get attributes of '{s}': No such file or directory\n", .{rp});
            return 1;
        };
        ref_at = .{ .sec = st.atime, .nsec = st.atime_nsec };
        ref_mt = .{ .sec = st.mtime, .nsec = st.mtime_nsec };
        have_ref = true;
        use_now = false;
    }
    if (stamp != null and (date_str != null or ref != null)) {
        u.err("touch: cannot specify times from more than one source\nTry 'touch --help' for more information.\n");
        return 1;
    }
    if (stamp) |sp| {
        when = dt.parseStamp(sp) orelse {
            u.errf("touch: invalid date format '{s}'\n", .{sp});
            return 1;
        };
        use_now = false;
        have_ref = false;
    }
    if (date_str) |ds| {
        var now: dt.Ts = .{ .sec = u.nowSecs() };
        if (have_ref) now = ref_mt;
        when = dt.parse(ds, now) orelse {
            u.errf("touch: invalid date format '{s}'\n", .{ds});
            return 1;
        };
        use_now = false;
        if (have_ref) {
            // GNU: -d relative to the reference time, applied to both stamps
            have_ref = false;
        }
    }

    var rc: u8 = 0;
    for (files.items) |path| {
        if (!touchOne(path, set_a, set_m, no_create, no_deref, use_now, have_ref, when, ref_at, ref_mt)) rc = 1;
    }
    return rc;
}

fn isWord(w: []const u8, a: []const u8, b: []const u8, c: []const u8) bool {
    return std.mem.eql(u8, w, a) or std.mem.eql(u8, w, b) or (c.len > 0 and std.mem.eql(u8, w, c));
}

fn touchOne(path: []const u8, set_a: bool, set_m: bool, no_create: bool, no_deref: bool, use_now: bool, have_ref: bool, when: dt.Ts, ref_at: dt.Ts, ref_mt: dt.Ts) bool {
    var a_t: Time64 = .{ .sec = 0, .nsec = UTIME_OMIT };
    var m_t: Time64 = .{ .sec = 0, .nsec = UTIME_OMIT };
    if (set_a) a_t = if (use_now) .{ .sec = 0, .nsec = UTIME_NOW } else if (have_ref) .{ .sec = ref_at.sec, .nsec = ref_at.nsec } else .{ .sec = when.sec, .nsec = when.nsec };
    if (set_m) m_t = if (use_now) .{ .sec = 0, .nsec = UTIME_NOW } else if (have_ref) .{ .sec = ref_mt.sec, .nsec = ref_mt.nsec } else .{ .sec = when.sec, .nsec = when.nsec };
    const times = [_]Time64{ a_t, m_t };
    const sys: linux.SYS = if (@sizeOf(usize) == 4) .utimensat_time64 else .utimensat;

    if (std.mem.eql(u8, path, "-")) {
        const rc = linux.syscall4(sys, @bitCast(@as(isize, 1)), 0, @intFromPtr(&times), 0);
        if (!u.ok(rc)) {
            u.errf("touch: setting times of standard output: {s}\n", .{u.strerr(u.errno(rc))});
            return false;
        }
        return true;
    }
    const flags: usize = if (no_deref) 0x100 else 0;
    var rc = linux.syscall4(sys, @bitCast(@as(isize, std.posix.AT.FDCWD)), @intFromPtr(u.zstr(path).ptr), @intFromPtr(&times), flags);
    if (u.errno(rc) == .NOENT) {
        if (no_create) return true;
        const f = u.File.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .NOCTTY = true }, 0o666) orelse {
            u.errf("touch: cannot touch '{s}': No such file or directory\n", .{path});
            return false;
        };
        f.close();
        rc = linux.syscall4(sys, @bitCast(@as(isize, std.posix.AT.FDCWD)), @intFromPtr(u.zstr(path).ptr), @intFromPtr(&times), flags);
    }
    if (!u.ok(rc)) {
        u.errf("touch: cannot touch '{s}': {s}\n", .{ path, u.strerr(u.errno(rc)) });
        return false;
    }
    return true;
}
