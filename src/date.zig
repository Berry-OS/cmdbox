// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// date - GNU date(1): -d -f -r -u -R -I --rfc-3339 -s, +FORMAT, MMDDhhmm
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const dt = @import("datetime.zig");

const default_fmt = "%a %b %e %H:%M:%S %Z %Y";

const Long = struct { name: []const u8, arg: enum { no, req, opt }, short: u8 };
const longs = [_]Long{
    .{ .name = "date", .arg = .req, .short = 'd' },
    .{ .name = "file", .arg = .req, .short = 'f' },
    .{ .name = "reference", .arg = .req, .short = 'r' },
    .{ .name = "utc", .arg = .no, .short = 'u' },
    .{ .name = "universal", .arg = .no, .short = 'u' },
    .{ .name = "rfc-email", .arg = .no, .short = 'R' },
    .{ .name = "rfc-2822", .arg = .no, .short = 'R' },
    .{ .name = "iso-8601", .arg = .opt, .short = 'I' },
    .{ .name = "rfc-3339", .arg = .req, .short = '3' },
    .{ .name = "set", .arg = .req, .short = 's' },
    .{ .name = "debug", .arg = .no, .short = 'D' },
    .{ .name = "resolution", .arg = .no, .short = 'x' },
    .{ .name = "help", .arg = .no, .short = 'h' },
    .{ .name = "version", .arg = .no, .short = 'V' },
};

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    u.errf("date: " ++ fmt ++ "\n", args);
    return 1;
}

fn usageErr() u8 {
    u.err("Try 'date --help' for more information.\n");
    return 1;
}

fn isoFormat(kind: []const u8) ?[]const u8 {
    if (kind.len == 0 or std.mem.eql(u8, kind, "date")) return "%Y-%m-%d";
    if (std.mem.eql(u8, kind, "hours")) return "%Y-%m-%dT%H%:z";
    if (std.mem.eql(u8, kind, "minutes")) return "%Y-%m-%dT%H:%M%:z";
    if (std.mem.eql(u8, kind, "seconds")) return "%Y-%m-%dT%H:%M:%S%:z";
    if (std.mem.eql(u8, kind, "ns")) return "%Y-%m-%dT%H:%M:%S,%N%:z";
    return null;
}

fn show(fmt: []const u8, ts: dt.Ts) void {
    const tm = dt.localtime(ts.sec);
    var o = u.Vec(u8).init(u.alloc);
    dt.format(fmt, ts, &tm, &o);
    o.push('\n');
    u.out(o.items);
}

fn nowTs() dt.Ts {
    var ts: linux.timespec = undefined;
    if (!u.ok(linux.clock_gettime(.REALTIME, &ts))) return .{ .sec = 0 };
    return .{ .sec = ts.sec, .nsec = ts.nsec };
}

pub fn run(args: []const []const u8) u8 {
    var fmt: ?[]const u8 = null;
    var date_str: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    var ref: ?[]const u8 = null;
    var set_str: ?[]const u8 = null;
    var utc = false;
    var preset: ?[]const u8 = null;
    var operands = u.Vec([]const u8).init(u.alloc);
    var i: usize = 0;
    var opts = true;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!opts or a.len < 2 or a[0] != '-') {
            operands.push(a);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            opts = false;
            continue;
        }
        var key: u8 = 0;
        var val: ?[]const u8 = null;
        if (a[1] == '-') {
            var name = a[2..];
            var inline_val: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, name, '=')) |e| {
                inline_val = name[e + 1 ..];
                name = name[0..e];
            }
            var found: ?Long = null;
            var count: usize = 0;
            for (longs) |l| {
                if (std.mem.eql(u8, l.name, name)) {
                    found = l;
                    count = 1;
                    break;
                }
                if (std.mem.startsWith(u8, l.name, name)) {
                    if (found == null or found.?.short != l.short) count += 1;
                    found = l;
                }
            }
            if (found == null) {
                u.errf("date: unrecognized option '{s}'\n", .{a});
                return usageErr();
            }
            if (count > 1) {
                u.errf("date: option '{s}' is ambiguous\n", .{a});
                return usageErr();
            }
            const l = found.?;
            key = l.short;
            switch (l.arg) {
                .no => if (inline_val != null) {
                    u.errf("date: option '--{s}' doesn't allow an argument\n", .{l.name});
                    return usageErr();
                },
                .req => {
                    if (inline_val) |v| {
                        val = v;
                    } else if (i + 1 < args.len) {
                        i += 1;
                        val = args[i];
                    } else {
                        u.errf("date: option '--{s}' requires an argument\n", .{l.name});
                        return usageErr();
                    }
                },
                .opt => val = inline_val,
            }
            if (!applyOpt(key, val, &fmt, &date_str, &file, &ref, &set_str, &utc, &preset)) return 1;
            continue;
        }
        // short cluster
        var k: usize = 1;
        while (k < a.len) : (k += 1) {
            const ch = a[k];
            switch (ch) {
                'd', 'f', 'r', 's' => {
                    var v: []const u8 = undefined;
                    if (k + 1 < a.len) {
                        v = a[k + 1 ..];
                    } else if (i + 1 < args.len) {
                        i += 1;
                        v = args[i];
                    } else {
                        u.errf("date: option requires an argument -- '{c}'\n", .{ch});
                        return usageErr();
                    }
                    if (!applyOpt(ch, v, &fmt, &date_str, &file, &ref, &set_str, &utc, &preset)) return 1;
                    k = a.len;
                },
                'I' => {
                    const v: ?[]const u8 = if (k + 1 < a.len) a[k + 1 ..] else null;
                    if (!applyOpt('I', v, &fmt, &date_str, &file, &ref, &set_str, &utc, &preset)) return 1;
                    k = a.len;
                },
                'u', 'R' => if (!applyOpt(ch, null, &fmt, &date_str, &file, &ref, &set_str, &utc, &preset)) return 1,
                else => {
                    u.errf("date: invalid option -- '{c}'\n", .{ch});
                    return usageErr();
                },
            }
        }
    }
    if (utc) dt.setUtc();

    // operands: +FORMAT and/or MMDDhhmm[[CC]YY][.ss]
    var posix_set: ?[]const u8 = null;
    for (operands.items) |op| {
        if (op.len > 0 and op[0] == '+') {
            if (fmt != null and !std.mem.eql(u8, fmt.?, "")) {
                // a second format, or format together with -I/-R
                if (fmt_from_operand) return fail("extra operand '{s}'", .{op});
                return fail("multiple output formats specified", .{});
            }
            fmt = op[1..];
            fmt_from_operand = true;
        } else if (posix_set == null) {
            posix_set = op;
        } else return fail("extra operand '{s}'", .{op});
    }
    if (posix_set != null and (date_str != null or file != null or ref != null)) {
        return fail("the options to specify dates for printing are mutually exclusive", .{});
    }
    if (set_str != null and (file != null or ref != null)) {
        return fail("the options to print and set the time may not be used together", .{});
    }
    if (date_str != null and ref != null or date_str != null and file != null or ref != null and file != null) {
        return fail("the options to specify dates for printing are mutually exclusive", .{});
    }
    const f = fmt orelse default_fmt;

    if (posix_set) |ps| {
        const ts = parsePosixSet(ps) orelse return fail("invalid date '{s}'", .{ps});
        return doSet(ts, f);
    }
    if (set_str) |ss| {
        const ts = dt.parse(ss, nowTs()) orelse return fail("invalid date '{s}'", .{ss});
        return doSet(ts, f);
    }
    if (file) |fp| {
        var h: u.File = undefined;
        if (std.mem.eql(u8, fp, "-")) {
            h = .{ .fd = 0 };
        } else {
            h = u.File.open(fp, .{ .ACCMODE = .RDONLY }, 0) orelse {
                u.errf("date: {s}: No such file or directory\n", .{fp});
                return 1;
            };
        }
        var lines = u.Vec([]const u8).init(u.alloc);
        u.readAllLines(&h, &lines);
        var rc: u8 = 0;
        for (lines.items) |ln| {
            const t = std.mem.trimEnd(u8, ln, "\r\n");
            if (dt.parse(t, nowTs())) |ts| {
                show(f, ts);
            } else {
                u.errf("date: invalid date '{s}'\n", .{t});
                rc = 1;
            }
        }
        return rc;
    }
    var ts: dt.Ts = nowTs();
    if (ref) |rp| {
        const st = u.stat(rp, true) orelse {
            u.errf("date: {s}: No such file or directory\n", .{rp});
            return 1;
        };
        ts = .{ .sec = st.mtime, .nsec = st.mtime_nsec };
    } else if (date_str) |ds| {
        ts = dt.parse(ds, nowTs()) orelse return fail("invalid date '{s}'", .{ds});
    }
    show(f, ts);
    return 0;
}

var fmt_from_operand = false;

fn applyOpt(key: u8, val: ?[]const u8, fmt: *?[]const u8, date_str: *?[]const u8, file: *?[]const u8, ref: *?[]const u8, set_str: *?[]const u8, utc: *bool, preset: *?[]const u8) bool {
    _ = preset;
    switch (key) {
        'd' => date_str.* = val,
        'f' => file.* = val,
        'r' => ref.* = val,
        's' => set_str.* = val,
        'u' => utc.* = true,
        'R' => {
            if (fmt.* != null) return multi();
            fmt.* = "%a, %d %b %Y %H:%M:%S %z";
        },
        'I' => {
            if (fmt.* != null) return multi();
            const kind = val orelse "date";
            fmt.* = isoFormat(kind) orelse {
                u.errf("date: invalid argument '{s}' for '--iso-8601'\n", .{kind});
                u.err("Valid arguments are:\n  - 'hours'\n  - 'minutes'\n  - 'date'\n  - 'seconds'\n  - 'ns'\nTry 'date --help' for more information.\n");
                return false;
            };
        },
        '3' => {
            if (fmt.* != null) return multi();
            const v = val.?;
            if (std.mem.eql(u8, v, "date")) {
                fmt.* = "%Y-%m-%d";
            } else if (std.mem.eql(u8, v, "seconds")) {
                fmt.* = "%Y-%m-%d %H:%M:%S%:z";
            } else if (std.mem.eql(u8, v, "ns")) {
                fmt.* = "%Y-%m-%d %H:%M:%S.%N%:z";
            } else {
                u.errf("date: invalid argument '{s}' for '--rfc-3339'\n", .{v});
                u.err("Valid arguments are:\n  - 'date'\n  - 'seconds'\n  - 'ns'\nTry 'date --help' for more information.\n");
                return false;
            }
        },
        'D', 'x' => {
            if (key == 'x') {
                u.out("0.000000001\n");
                std.process.exit(0);
            }
        },
        'h' => {
            u.out("Usage: date [OPTION]... [+FORMAT]\n  or:  date [-u|--utc|--universal] [MMDDhhmm[[CC]YY][.ss]]\nDisplay date and time in the given FORMAT.\nWith -s, or with [MMDDhhmm[[CC]YY][.ss]], set the date and time.\n");
            std.process.exit(0);
        },
        'V' => {
            u.out("date (cmdbox)\n");
            std.process.exit(0);
        },
        else => {},
    }
    return true;
}

fn multi() bool {
    u.err("date: multiple output formats specified\n");
    return false;
}

fn parsePosixSet(s: []const u8) ?dt.Ts {
    // MMDDhhmm[[CC]YY][.ss]
    var body = s;
    var sec: i64 = 0;
    if (std.mem.indexOfScalar(u8, s, '.')) |d| {
        body = s[0..d];
        sec = std.fmt.parseInt(i64, s[d + 1 ..], 10) catch return null;
    }
    for (body) |ch| if (ch < '0' or ch > '9') return null;
    if (body.len < 8 or body.len > 12 or body.len % 2 != 0) return null;
    const now = dt.localtime(u.nowSecs());
    var tm = std.mem.zeroes(dt.c.struct_tm);
    tm.tm_mon = (std.fmt.parseInt(c_int, body[0..2], 10) catch return null) - 1;
    tm.tm_mday = std.fmt.parseInt(c_int, body[2..4], 10) catch return null;
    tm.tm_hour = std.fmt.parseInt(c_int, body[4..6], 10) catch return null;
    tm.tm_min = std.fmt.parseInt(c_int, body[6..8], 10) catch return null;
    tm.tm_sec = @intCast(sec);
    tm.tm_year = now.tm_year;
    if (body.len == 10) {
        const y = std.fmt.parseInt(c_int, body[8..10], 10) catch return null;
        tm.tm_year = if (y < 69) y + 100 else y;
    } else if (body.len == 12) {
        tm.tm_year = (std.fmt.parseInt(c_int, body[8..12], 10) catch return null) - 1900;
    }
    if (tm.tm_mon < 0 or tm.tm_mon > 11 or tm.tm_mday < 1 or tm.tm_mday > 31 or tm.tm_hour > 23 or tm.tm_min > 59) return null;
    tm.tm_isdst = -1;
    return .{ .sec = @intCast(dt.c.mktime(&tm)) };
}

fn doSet(ts: dt.Ts, f: []const u8) u8 {
    const spec = linux.timespec{ .sec = @intCast(ts.sec), .nsec = @intCast(ts.nsec) };
    if (!u.ok(linux.clock_settime(.REALTIME, &spec))) {
        u.err("date: cannot set date: Operation not permitted\n");
        show(f, ts);
        return 1;
    }
    show(f, ts);
    return 0;
}
