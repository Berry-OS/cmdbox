// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// dmesg - util-linux 2.41 compatible: /dev/kmsg, syslog(2) and file sources; facility/level/time filters;
// raw, decode, delta, reltime, ctime, iso and json output; colours; follow mode.
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const dt = @import("datetime.zig");
const color = @import("color.zig");

const help_text = @embedFile("dmesg_help.txt");

const Rec = struct { pri: u32, ts_us: u64, msg: []const u8, hexenc: bool = true };

const fac_names = [_][]const u8{ "kern", "user", "mail", "daemon", "auth", "syslog", "lpr", "news", "uucp", "cron", "authpriv", "ftp", "res0", "res1", "res2", "res3", "local0", "local1", "local2", "local3", "local4", "local5", "local6", "local7" };
const level_names = [_][]const u8{ "emerg", "alert", "crit", "err", "warn", "notice", "info", "debug" };

const K_NOESCAPE: u8 = 140;
const K_TIMEFMT: u8 = 141;
const K_SINCE: u8 = 142;
const K_UNTIL: u8 = 143;
const K_COLOR: u8 = 144;

const Ctl = struct {
    raw: bool = false,
    notime: bool = false,
    ctime: bool = false,
    reltime: bool = false,
    delta: bool = false,
    delta_only: bool = false,
    iso: bool = false,
    decode: bool = false,
    json: bool = false,
    force_prefix: bool = false,
    escape: bool = true,
    use_color: bool = false,
    boot_us: i64 = 0,
    boot_sub_ns: i64 = 0, // nanoseconds below the microsecond of boot_us
};

fn readText(path: []const u8) ?[]u8 {
    const rc = linux.open(u.zstr(path), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(rc)) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var out = u.Vec(u8).init(u.alloc);
    var buf: [65536]u8 = undefined;
    while (true) {
        const r = linux.read(fd, &buf, buf.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r) or r == 0) break;
        out.pushSlice(buf[0..r]);
    }
    return out.items;
}

fn parseList(list: []const u8, names: []const []const u8, what: []const u8, mask_out: *u32) bool {
    var mask: u32 = 0;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |tok| {
        var found = false;
        for (names, 0..) |nm, k| if (std.mem.eql(u8, nm, tok)) {
            mask |= @as(u32, 1) << @intCast(k);
            found = true;
        };
        if (!found) {
            if (std.fmt.parseInt(u32, tok, 10)) |v| {
                if (v < names.len) {
                    mask |= @as(u32, 1) << @intCast(v);
                    continue;
                }
            } else |_| {}
            u.errf("dmesg: unknown {s} '{s}'\n", .{ what, tok });
            return false;
        }
    }
    mask_out.* = mask;
    return true;
}

fn parseLevel(s: []const u8) ?u32 {
    for (level_names, 0..) |nm, k| if (std.mem.eql(u8, nm, s)) return @intCast(k + 1);
    const v = std.fmt.parseInt(u32, s, 10) catch return null;
    return if (v >= 1 and v <= 8) v else null;
}

fn isUtf8Locale() bool {
    const l = u.getEnv("LC_ALL") orelse u.getEnv("LC_CTYPE") orelse u.getEnv("LANG") orelse "";
    var buf: [64]u8 = undefined;
    const n = @min(l.len, buf.len);
    for (l[0..n], 0..) |ch, k| buf[k] = std.ascii.toLower(ch);
    return std.mem.indexOf(u8, buf[0..n], "utf-8") != null or std.mem.indexOf(u8, buf[0..n], "utf8") != null;
}

/// kmsg escapes unprintable bytes as \xHH; decode them (and optionally escape them again like util-linux does)
fn decodeMsg(raw: []const u8, hexenc: bool, escape: bool, utf8: bool, out: *u.Vec(u8)) void {
    var tmp = u.Vec(u8).init(u.alloc);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (hexenc and raw[i] == '\\' and i + 3 < raw.len + 0 and raw[i + 1] == 'x') {
            if (std.fmt.parseInt(u8, raw[i + 2 .. i + 4], 16)) |b| {
                tmp.push(b);
                i += 3;
                continue;
            } else |_| {}
        }
        tmp.push(raw[i]);
    }
    if (!escape) {
        out.pushSlice(tmp.items);
        return;
    }
    var k: usize = 0;
    const d = tmp.items;
    while (k < d.len) {
        const b = d[k];
        if (b == '\n' or b == '\t') {
            out.push(b);
            k += 1;
        } else if (b >= 0x20 and b < 0x7f) {
            out.push(b);
            k += 1;
        } else if (b >= 0x80 and utf8) {
            const l = std.unicode.utf8ByteSequenceLength(b) catch 1;
            if (l > 1 and k + l <= d.len and std.unicode.utf8ValidateSlice(d[k .. k + l])) {
                out.pushSlice(d[k .. k + l]);
                k += l;
            } else {
                out.pushSlice(std.fmt.allocPrint(u.alloc, "\\x{x:0>2}", .{b}) catch "");
                k += 1;
            }
        } else {
            out.pushSlice(std.fmt.allocPrint(u.alloc, "\\x{x:0>2}", .{b}) catch "");
            k += 1;
        }
    }
}

fn nowRealUs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1_000_000_000 + @as(i64, ts.nsec);
}
fn nowBootUs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.BOOTTIME, &ts);
    return @as(i64, ts.sec) * 1_000_000_000 + @as(i64, ts.nsec);
}

fn parseSyslogLines(data: []const u8, recs: *u.Vec(Rec)) void {
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |ln0| {
        var ln = ln0;
        if (ln.len == 0) continue;
        var pri: u32 = 6;
        if (ln[0] == '<') {
            if (std.mem.indexOfScalar(u8, ln, '>')) |e| {
                pri = std.fmt.parseInt(u32, ln[1..e], 10) catch 6;
                ln = ln[e + 1 ..];
            }
        }
        var ts: u64 = 0;
        if (ln.len > 0 and ln[0] == '[') {
            if (std.mem.indexOfScalar(u8, ln, ']')) |e| {
                const t = std.mem.trim(u8, ln[1..e], " ");
                if (std.fmt.parseFloat(f64, t)) |f| {
                    ts = @intFromFloat(f * 1e6 + 0.5);
                    ln = ln[e + 1 ..];
                    if (ln.len > 0 and ln[0] == ' ') ln = ln[1..];
                } else |_| {}
            }
        }
        recs.push(.{ .pri = pri, .ts_us = ts, .msg = ln, .hexenc = false });
    }
}

fn jsonEscape(s: []const u8, o: *u.Vec(u8)) void {
    for (s) |b| switch (b) {
        '"' => o.pushSlice("\\\""),
        '\\' => o.pushSlice("\\\\"),
        '\n' => o.pushSlice("\\n"),
        '\t' => o.pushSlice("\\t"),
        '\r' => o.pushSlice("\\r"),
        8 => o.pushSlice("\\b"),
        12 => o.pushSlice("\\f"),
        else => if (b < 0x20) o.pushSlice(std.fmt.allocPrint(u.alloc, "\\u{x:0>4}", .{b}) catch "") else o.push(b),
    };
}

const State = struct {
    last_us: u64 = 0,
    last_min: i64 = -1,
    first_json: bool = true,
};

fn formatCtime(secs: i64, o: *u.Vec(u8)) void {
    const tm = dt.localtime(secs);
    dt.format("%a %b %e %H:%M:%S %Y", .{ .sec = secs }, &tm, o);
}

fn printRec(ctl: *const Ctl, st: *State, r: Rec, o: *u.Vec(u8)) void {
    if (r.msg.len == 0 and !ctl.json) {
        o.push('\n');
        return;
    }
    const utf8 = isUtf8Locale();
    var text = u.Vec(u8).init(u.alloc);
    decodeMsg(r.msg, r.hexenc, ctl.escape, utf8, &text);
    const fac: usize = (r.pri >> 3) % fac_names.len;
    const lvl: u32 = r.pri & 7;
    const abs_us: i64 = ctl.boot_us + @as(i64, @intCast(r.ts_us)) + @divFloor(ctl.boot_sub_ns + 500, 1000);
    const secs_f = @as(f64, @floatFromInt(r.ts_us)) / 1e6;
    defer {
        st.last_us = r.ts_us;
        st.last_min = @divFloor(@divFloor(abs_us, 1_000_000), 60);
    }
    if (ctl.json) {
        o.pushSlice(if (st.first_json) "\n      {\n" else ",{\n");
        st.first_json = false;
        if (ctl.decode) {
            o.pushSlice(std.fmt.allocPrint(u.alloc, "         \"fac\": \"{s}\",\n         \"pri\": \"{s}\",\n", .{ fac_names[fac], level_names[lvl] }) catch "");
        } else o.pushSlice(std.fmt.allocPrint(u.alloc, "         \"pri\": {d},\n", .{r.pri}) catch "");
        o.pushSlice(std.fmt.allocPrint(u.alloc, "         \"time\": {d: >12.6},\n", .{secs_f}) catch "");
        o.pushSlice("         \"msg\": \"");
        jsonEscape(text.items, o);
        o.pushSlice("\"\n      }");
        return;
    }
    var lines = std.mem.splitScalar(u8, text.items, '\n');
    var first = true;
    while (lines.next()) |ln| {
        if (!first and !ctl.force_prefix) {
            o.pushSlice(ln);
            o.push('\n');
            continue;
        }
        first = false;
        if (ctl.raw) o.pushSlice(std.fmt.allocPrint(u.alloc, "<{d}>", .{r.pri}) catch "");
        if (ctl.decode and !ctl.raw) o.pushSlice(std.fmt.allocPrint(u.alloc, "{s: <6}:{s: <6}: ", .{ fac_names[fac], level_names[lvl] }) catch "");
        if (!ctl.notime) {
            const delta_us: u64 = if (st.last_us == 0) 0 else r.ts_us -| st.last_us;
            if (ctl.use_color) o.pushSlice("\x1b[32m");
            if (ctl.delta_only) {
                o.pushSlice(std.fmt.allocPrint(u.alloc, "[<{d: >5}.{d:0>6}>] ", .{ delta_us / 1_000_000, delta_us % 1_000_000 }) catch "");
            } else {
                if (ctl.reltime) {
                    const secs = @divFloor(abs_us, 1_000_000);
                    const minute = @divFloor(secs, 60);
                    if (st.last_min != minute) {
                        const tm = dt.localtime(secs);
                        var tb = u.Vec(u8).init(u.alloc);
                        dt.format("%b%d %H:%M", .{ .sec = secs }, &tm, &tb);
                        if (ctl.use_color) o.pushSlice("\x1b[1m");
                        o.pushSlice(std.fmt.allocPrint(u.alloc, "[{s}] ", .{tb.items}) catch "");
                    } else {
                        const dd: f64 = @as(f64, @floatFromInt(delta_us)) / 1e6;
                        o.pushSlice(std.fmt.allocPrint(u.alloc, "[{s}] ", .{fmtPlus(dd)}) catch "");
                    }
                }
                if (ctl.ctime) {
                    var tb = u.Vec(u8).init(u.alloc);
                    formatCtime(@divFloor(abs_us, 1_000_000), &tb);
                    if (ctl.delta) {
                        o.pushSlice(std.fmt.allocPrint(u.alloc, "[{s} <{d: >5}.{d:0>6}>] ", .{ tb.items, delta_us / 1_000_000, delta_us % 1_000_000 }) catch "");
                    } else o.pushSlice(std.fmt.allocPrint(u.alloc, "[{s}] ", .{tb.items}) catch "");
                } else if (ctl.iso) {
                    const secs = @divFloor(abs_us, 1_000_000);
                    const usec: u64 = @intCast(@mod(abs_us, 1_000_000));
                    const tm = dt.localtime(secs);
                    var tb = u.Vec(u8).init(u.alloc);
                    dt.format("%Y-%m-%dT%H:%M:%S", .{ .sec = secs }, &tm, &tb);
                    const off: i64 = tm.tm_gmtoff;
                    const a: u64 = @intCast(if (off < 0) -off else off);
                    o.pushSlice(std.fmt.allocPrint(u.alloc, "{s},{d:0>6}{c}{d:0>2}:{d:0>2} ", .{ tb.items, usec, @as(u8, if (off < 0) '-' else '+'), a / 3600, (a % 3600) / 60 }) catch "");
                } else if (!ctl.reltime) {
                    if (ctl.delta) {
                        o.pushSlice(std.fmt.allocPrint(u.alloc, "[{d: >5}.{d:0>6} <{d: >5}.{d:0>6}>] ", .{ r.ts_us / 1_000_000, r.ts_us % 1_000_000, delta_us / 1_000_000, delta_us % 1_000_000 }) catch "");
                    } else o.pushSlice(std.fmt.allocPrint(u.alloc, "[{d: >5}.{d:0>6}] ", .{ r.ts_us / 1_000_000, r.ts_us % 1_000_000 }) catch "");
                }
            }
            if (ctl.use_color) {
                if (o.items.len > 0 and o.items[o.items.len - 1] == ' ') {
                    o.items.len -= 1;
                    o.pushSlice(" \x1b[0m");
                } else o.pushSlice("\x1b[0m");
            }
        }
        printText(ctl, ln, lvl, o);
        o.push('\n');
    }
}

fn fmtPlus(v: f64) []const u8 {
    // C's %+11.6f
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "+{d:.6}", .{v}) catch return "";
    return std.fmt.allocPrint(u.alloc, "{s: >11}", .{s}) catch s;
}

fn printText(ctl: *const Ctl, ln: []const u8, lvl: u32, o: *u.Vec(u8)) void {
    if (!ctl.use_color) {
        o.pushSlice(ln);
        return;
    }
    var body = ln;
    var off: usize = 0;
    while (std.mem.indexOfScalarPos(u8, body, off, ':')) |ci| {
        if (ci + 1 < body.len and (body[ci + 1] == ' ' or body[ci + 1] == '\t')) {
            o.pushSlice("\x1b[33m");
            o.pushSlice(body[0 .. ci + 2]);
            o.pushSlice("\x1b[0m");
            body = body[ci + 2 ..];
            break;
        }
        off = ci + 1;
    }
    const lc: []const u8 = switch (lvl) {
        1 => "\x1b[7m\x1b[31m",
        2 => "\x1b[1m\x1b[31m",
        3 => "\x1b[31m",
        4 => "\x1b[1m",
        else => if (std.mem.indexOf(u8, body, "segfault at") != null) "\x1b[2m\x1b[31m" else "",
    };
    if (lc.len > 0 and body.len > 0) {
        o.pushSlice(lc);
        o.pushSlice(body);
        o.pushSlice("\x1b[0m");
    } else o.pushSlice(body);
}

fn mutex(a: bool, b: bool, an: []const u8, bn: []const u8) bool {
    if (a and b) {
        u.errf("dmesg: mutually exclusive arguments: {s} {s}\n", .{ an, bn });
        return true;
    }
    return false;
}

pub fn dmesg(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "clear", .key = 'C' },
        .{ .name = "read-clear", .key = 'c' },
        .{ .name = "console-off", .key = 'D' },
        .{ .name = "console-on", .key = 'E' },
        .{ .name = "file", .key = 'F', .arg = .req },
        .{ .name = "kmsg-file", .key = 'K', .arg = .req },
        .{ .name = "facility", .key = 'f', .arg = .req },
        .{ .name = "human", .key = 'H' },
        .{ .name = "json", .key = 'J' },
        .{ .name = "kernel", .key = 'k' },
        .{ .name = "color", .key = K_COLOR, .arg = .opt },
        .{ .name = "", .key = 'L', .arg = .opt },
        .{ .name = "level", .key = 'l', .arg = .req },
        .{ .name = "console-level", .key = 'n', .arg = .req },
        .{ .name = "nopager", .key = 'P' },
        .{ .name = "force-prefix", .key = 'p' },
        .{ .name = "raw", .key = 'r' },
        .{ .name = "noescape", .key = K_NOESCAPE },
        .{ .name = "syslog", .key = 'S' },
        .{ .name = "buffer-size", .key = 's', .arg = .req },
        .{ .name = "userspace", .key = 'u' },
        .{ .name = "follow", .key = 'w' },
        .{ .name = "follow-new", .key = 'W' },
        .{ .name = "decode", .key = 'x' },
        .{ .name = "show-delta", .key = 'd' },
        .{ .name = "reltime", .key = 'e' },
        .{ .name = "ctime", .key = 'T' },
        .{ .name = "notime", .key = 't' },
        .{ .name = "time-format", .key = K_TIMEFMT, .arg = .req },
        .{ .name = "since", .key = K_SINCE, .arg = .req },
        .{ .name = "until", .key = K_UNTIL, .arg = .req },
        .{ .name = "help", .key = 'h' },
        .{ .name = "version", .key = 'V' },
    };
    var p = g.Parser.init("dmesg", args, &opts);
    p.hint_prefix = false;
    var ctl = Ctl{};
    var clear_after = false;
    var clear_only = false;
    var console_off = false;
    var console_on = false;
    var set_level: ?u32 = null;
    var fac_mask: u32 = 0xffffff;
    var lvl_mask: u32 = 0xff;
    var color_mode: color.Mode = .auto;
    var file_arg: ?[]const u8 = null;
    var use_syslog = false;
    var follow = false;
    var follow_new = false;
    var human = false;
    var since: ?i64 = null;
    var until: ?i64 = null;
    var kmsg_file = false;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'h' => {
                u.out(help_text);
                return 0;
            },
            'V' => {
                u.out("dmesg from util-linux 2.41.5\n");
                return 0;
            },
            'C' => clear_only = true,
            'c' => clear_after = true,
            'D' => console_off = true,
            'E' => console_on = true,
            'F' => file_arg = it.val,
            'K' => {
                file_arg = it.val;
                kmsg_file = true;
            },
            'f' => if (!parseList(it.val.?, &fac_names, "facility", &fac_mask)) return 1,
            'H' => human = true,
            'J' => ctl.json = true,
            'k' => fac_mask = 1,
            'u' => fac_mask = 0xffffff & ~@as(u32, 1),
            K_COLOR, 'L' => {
                if (it.val) |v0| {
                    const v = if (v0.len > 0 and v0[0] == '=') v0[1..] else v0;
                    color_mode = color.parse(v) orelse {
                        u.errf("dmesg: unknown --color argument: {s}\n", .{v});
                        return 1;
                    };
                } else color_mode = .auto;
            },
            'l' => if (!parseList(it.val.?, &level_names, "level", &lvl_mask)) return 1,
            'n' => {
                set_level = parseLevel(it.val.?) orelse {
                    u.errf("dmesg: unknown level '{s}'\n", .{it.val.?});
                    return 1;
                };
            },
            'P' => {},
            'p' => ctl.force_prefix = true,
            'r' => ctl.raw = true,
            K_NOESCAPE => ctl.escape = false,
            'S' => use_syslog = true,
            's' => {},
            'w' => follow = true,
            'W' => {
                follow = true;
                follow_new = true;
            },
            'x' => ctl.decode = true,
            'd' => ctl.delta = true,
            'e' => ctl.reltime = true,
            'T' => ctl.ctime = true,
            't' => ctl.notime = true,
            K_TIMEFMT => {
                const v = it.val.?;
                if (std.mem.eql(u8, v, "delta")) {
                    ctl.delta_only = true;
                } else if (std.mem.eql(u8, v, "reltime")) {
                    ctl.reltime = true;
                } else if (std.mem.eql(u8, v, "ctime")) {
                    ctl.ctime = true;
                } else if (std.mem.eql(u8, v, "notime")) {
                    ctl.notime = true;
                } else if (std.mem.eql(u8, v, "iso")) {
                    ctl.iso = true;
                } else if (std.mem.eql(u8, v, "raw")) {
                    ctl.delta_only = false;
                } else {
                    u.errf("dmesg: unknown time format: {s}\n", .{v});
                    return 1;
                }
            },
            K_SINCE, K_UNTIL => {
                const v = it.val.?;
                var ok_time = false;
                var secs: i64 = 0;
                if (v.len > 0 and !allDigits(v)) {
                    if (dt.parse(v, .{ .sec = u.nowSecs() })) |ts| {
                        secs = ts.sec;
                        ok_time = true;
                    }
                }
                if (!ok_time) {
                    u.errf("dmesg: invalid time value \"{s}\"\n", .{v});
                    return 1;
                }
                if (it.key == K_SINCE) since = secs else until = secs;
            },
            else => {},
        }
    }
    if (human) {
        ctl.reltime = true;
        if (color_mode == .auto) color_mode = .auto;
    }
    if (mutex(ctl.raw, ctl.notime, "--raw", "--notime")) return 1;
    if (mutex(ctl.ctime, ctl.raw, "--ctime", "--raw")) return 1;
    if (mutex(ctl.reltime, ctl.raw, "--reltime", "--raw")) return 1;
    if (mutex(ctl.notime, ctl.ctime, "--notime", "--ctime")) return 1;
    if (mutex(ctl.notime, ctl.reltime, "--notime", "--reltime")) return 1;
    if (mutex(ctl.notime, ctl.iso, "--notime", "--time-format=iso")) return 1;
    if (mutex(ctl.iso, ctl.raw, "--time-format=iso", "--raw")) return 1;
    if (mutex(ctl.delta_only, ctl.raw, "--time-format=delta", "--raw")) return 1;
    ctl.use_color = color.enabled(color_mode) and (color_mode == .always or !std.mem.eql(u8, u.getEnv("TERM") orelse "dumb", "dumb"));

    if (console_off or console_on) {
        const r = linux.syscall3(.syslog, if (console_off) 6 else 7, 0, 0);
        if (!u.ok(r)) {
            u.errf("dmesg: klogctl failed: {s}\n", .{u.strerr(u.errno(r))});
            return 1;
        }
        return 0;
    }
    if (set_level) |lv| {
        const r = linux.syscall3(.syslog, 8, 0, lv);
        if (!u.ok(r)) {
            u.errf("dmesg: klogctl failed: {s}\n", .{u.strerr(u.errno(r))});
            return 1;
        }
        return 0;
    }
    if (clear_only) {
        const r = linux.syscall3(.syslog, 5, 0, 0);
        if (!u.ok(r)) {
            u.errf("dmesg: klogctl failed: {s}\n", .{u.strerr(u.errno(r))});
            return 1;
        }
        return 0;
    }

    const boot_ns = nowRealUs() - nowBootUs();
    ctl.boot_us = @divFloor(boot_ns, 1000);
    ctl.boot_sub_ns = @mod(boot_ns, 1000);
    var recs = u.Vec(Rec).init(u.alloc);
    var kfd: i32 = -1;
    if (file_arg) |fname| {
        const st = u.stat(fname, true) orelse {
            const rc = linux.open(u.zstr(fname), .{ .ACCMODE = .RDONLY }, 0);
            u.errf("dmesg: cannot open {s}: {s}\n", .{ fname, u.strerr(u.errno(rc)) });
            return 1;
        };
        if (st.mode & linux.S.IFMT == linux.S.IFREG and st.size == 0 or st.mode & linux.S.IFMT == linux.S.IFCHR) {
            u.errf("dmesg: cannot mmap: {s}: Invalid argument\n", .{fname});
            return 1;
        }
        const data = readText(fname) orelse {
            u.errf("dmesg: cannot open {s}: {s}\n", .{ fname, "Permission denied" });
            return 1;
        };
        if (kmsg_file) {
            var it = std.mem.splitScalar(u8, data, '\n');
            while (it.next()) |ln| {
                const semi = std.mem.indexOfScalar(u8, ln, ';') orelse continue;
                var hdr = std.mem.splitScalar(u8, ln[0..semi], ',');
                const pri = std.fmt.parseInt(u32, hdr.next() orelse "6", 10) catch 6;
                _ = hdr.next();
                const ts = std.fmt.parseInt(u64, hdr.next() orelse "0", 10) catch 0;
                recs.push(.{ .pri = pri, .ts_us = ts, .msg = ln[semi + 1 ..] });
            }
        } else parseSyslogLines(data, &recs);
    } else if (use_syslog) {
        const sz = linux.syscall3(.syslog, 10, 0, 0);
        const size: usize = if (u.ok(sz) and sz > 0) sz else 1 << 20;
        const buf = u.alloc.alloc(u8, size) catch return 1;
        const r = linux.syscall3(.syslog, if (clear_after) 4 else 3, @intFromPtr(buf.ptr), size);
        if (!u.ok(r)) {
            u.errf("dmesg: klogctl failed: {s}\n", .{u.strerr(u.errno(r))});
            return 1;
        }
        parseSyslogLines(buf[0..r], &recs);
        clear_after = false;
    } else {
        const fd_rc = linux.open("/dev/kmsg", .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
        if (!u.ok(fd_rc)) {
            u.errf("dmesg: read kernel buffer failed: {s}\n", .{u.strerr(u.errno(fd_rc))});
            return 1;
        }
        kfd = @intCast(fd_rc);
        if (follow_new) _ = linux.lseek(kfd, 0, linux.SEEK.END);
        var buf: [8192]u8 = undefined;
        while (!follow_new) {
            const r = linux.read(kfd, &buf, buf.len);
            if (u.errno(r) == .INTR) continue;
            if (u.errno(r) == .PIPE) continue; // overwritten record
            if (!u.ok(r) or r == 0) break;
            const rec = buf[0..r];
            const semi = std.mem.indexOfScalar(u8, rec, ';') orelse continue;
            var hdr = std.mem.splitScalar(u8, rec[0..semi], ',');
            const pri = std.fmt.parseInt(u32, hdr.next() orelse "0", 10) catch 0;
            _ = hdr.next();
            const ts = std.fmt.parseInt(u64, hdr.next() orelse "0", 10) catch 0;
            var msg = rec[semi + 1 ..];
            if (std.mem.indexOfScalar(u8, msg, '\n')) |nl| msg = msg[0..nl];
            recs.push(.{ .pri = pri, .ts_us = ts, .msg = u.alloc.dupe(u8, msg) catch msg });
        }
    }
    var o = u.Vec(u8).init(u.alloc);
    var st = State{};
    if (ctl.json) o.pushSlice("{\n   \"dmesg\": [");
    for (recs.items) |r| {
        if (!emit(&ctl, &st, r, fac_mask, lvl_mask, since, until, &o)) continue;
        if (o.items.len > 1 << 16) {
            u.out(o.items);
            o.items.len = 0;
        }
    }
    if (ctl.json) o.pushSlice("\n   ]\n}\n");
    u.out(o.items);
    if (clear_after) _ = linux.syscall3(.syslog, 5, 0, 0);
    if (follow and kfd >= 0) {
        // wait for new messages
        const flags = linux.fcntl(kfd, linux.F.GETFL, 0);
        _ = linux.fcntl(kfd, linux.F.SETFL, flags & ~@as(usize, 0o4000));
        var buf: [8192]u8 = undefined;
        while (true) {
            const r = linux.read(kfd, &buf, buf.len);
            if (u.errno(r) == .INTR or u.errno(r) == .PIPE) continue;
            if (!u.ok(r) or r == 0) break;
            const rec = buf[0..r];
            const semi = std.mem.indexOfScalar(u8, rec, ';') orelse continue;
            var hdr = std.mem.splitScalar(u8, rec[0..semi], ',');
            const pri = std.fmt.parseInt(u32, hdr.next() orelse "0", 10) catch 0;
            _ = hdr.next();
            const ts = std.fmt.parseInt(u64, hdr.next() orelse "0", 10) catch 0;
            var msg = rec[semi + 1 ..];
            if (std.mem.indexOfScalar(u8, msg, '\n')) |nl| msg = msg[0..nl];
            var oo = u.Vec(u8).init(u.alloc);
            if (emit(&ctl, &st, .{ .pri = pri, .ts_us = ts, .msg = msg }, fac_mask, lvl_mask, since, until, &oo)) u.out(oo.items);
        }
    }
    return 0;
}

fn allDigits(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return s.len > 0;
}

fn emit(ctl: *const Ctl, st: *State, r: Rec, fac_mask: u32, lvl_mask: u32, since: ?i64, until: ?i64, o: *u.Vec(u8)) bool {
    const fac: u5 = @intCast((r.pri >> 3) % 24);
    if (fac_mask & (@as(u32, 1) << fac) == 0) return false;
    if (lvl_mask & (@as(u32, 1) << @intCast(r.pri & 7)) == 0) return false;
    const secs = @divFloor(ctl.boot_us + @as(i64, @intCast(r.ts_us)), 1_000_000);
    if (since) |s| if (secs < s) return false;
    if (until) |un| if (secs > un) return false;
    printRec(ctl, st, r, o);
    return true;
}
