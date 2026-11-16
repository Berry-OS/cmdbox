// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const u = @import("util.zig");
const linux = std.os.linux;
pub const Mode = enum { never, auto, always };
pub fn parse(value: []const u8) ?Mode {
    if (same(value, "always") or same(value, "yes") or same(value, "force")) return .always;
    if (same(value, "never") or same(value, "no") or same(value, "none")) return .never;
    if (same(value, "auto") or same(value, "tty") or same(value, "if-tty")) return .auto;
    return null;
}
pub fn enabled(mode: Mode) bool {
    if (mode == .always) return true;
    if (mode == .never) return false;
    var attributes: [64]u8 = undefined;
    if (!u.ok(linux.ioctl(1, 0x5401, @intFromPtr(&attributes)))) return false;
    return true;
}
pub fn grepEnabled(mode: Mode) bool {
    if (!enabled(mode)) return false;
    if (mode == .always) return true;
    const term = u.getEnv("TERM") orelse return false;
    return !same(term, "dumb");
}
pub fn lsEnabled(mode: Mode) bool {
    if (!enabled(mode)) return false;
    if (mode == .always) return true;
    if (u.getEnv("LS_COLORS")) |value| {
        if (value.len > 0) return true;
    }
    if (u.getEnv("COLORTERM")) |value| {
        if (value.len > 0) return true;
    }
    const term = u.getEnv("TERM") orelse return false;
    for ([_][]const u8{ "Eterm", "ansi", "*color*", "con[0-9]*x[0-9]*", "cons25", "console", "cygwin", "*direct*", "dtterm", "gnome", "hurd", "jfbterm", "konsole", "kterm", "linux", "linux-c", "mlterm", "putty", "rxvt*", "screen*", "st", "terminator", "tmux*", "vt100", "vt220", "xterm*" }) |pattern| if (u.matchPat(pattern, term)) return true;
    return false;
}
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn setting(environment: []const u8, name: []const u8, fallback: []const u8) []const u8 {
    var result = fallback;
    var entries = std.mem.splitScalar(u8, u.getEnv(environment) orelse return result, ':');
    while (entries.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (same(entry[0..eq], name)) result = entry[eq + 1 ..];
    }
    return result;
}
pub fn has(environment: []const u8, name: []const u8) bool {
    var entries = std.mem.splitScalar(u8, u.getEnv(environment) orelse return false, ':');
    while (entries.next()) |entry| if (same(entry, name) or entry.len > name.len and entry[name.len] == '=' and same(entry[0..name.len], name)) return true;
    return false;
}
pub fn grepStart(name: []const u8, fallback: []const u8) bool {
    const code = setting("GREP_COLORS", name, fallback);
    if (code.len == 0) return false;
    u.outf("\x1b[{s}m", .{code});
    if (!has("GREP_COLORS", "ne")) u.out("\x1b[K");
    return true;
}
pub fn grepEnd() void {
    u.out("\x1b[m");
    if (!has("GREP_COLORS", "ne")) u.out("\x1b[K");
}
fn lsControl(name: []const u8, fallback: []const u8) void {
    const raw = setting("LS_COLORS", name, fallback);
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) {
        u.out(raw);
        return;
    }
    const decoded = @import("printf.zig").escapes(raw, false);
    u.out(if (decoded) |value| value.bytes else raw);
}
pub fn lsStart(code: []const u8) bool {
    lsControl("lc", "\x1b[");
    u.out(code);
    lsControl("rc", "m");
    return true;
}
pub fn lsEnd() void {
    if (has("LS_COLORS", "ec")) lsControl("ec", "") else {
        lsControl("lc", "\x1b[");
        lsControl("rs", "0");
        lsControl("rc", "m");
    }
}
pub fn lsCode(path: []const u8, name: []const u8, value: u.Stat) ?[]const u8 {
    var st = value;
    const link_color = setting("LS_COLORS", "ln", "01;36");
    if (st.mode & linux.S.IFMT == linux.S.IFLNK) {
        const target = u.stat(path, true);
        if (same(link_color, "target")) {
            st = target orelse {
                const code = setting("LS_COLORS", "or", "");
                return if (code.len > 0) code else null;
            };
        } else if (target == null) return setting("LS_COLORS", "or", link_color) else return link_color;
    }
    const kind = st.mode & linux.S.IFMT;
    if (kind == linux.S.IFDIR) {
        if (st.mode & 0o1002 == 0o1002) return setting("LS_COLORS", "tw", "30;42");
        if (st.mode & 0o002 != 0) return setting("LS_COLORS", "ow", "34;42");
        if (st.mode & 0o1000 != 0) return setting("LS_COLORS", "st", "37;44");
        return setting("LS_COLORS", "di", "01;34");
    }
    if (kind == linux.S.IFCHR) return setting("LS_COLORS", "cd", "40;33;01");
    if (kind == linux.S.IFBLK) return setting("LS_COLORS", "bd", "40;33;01");
    if (kind == linux.S.IFIFO) return setting("LS_COLORS", "pi", "33");
    if (kind == linux.S.IFSOCK) return setting("LS_COLORS", "so", "01;35");
    if (st.mode & 0o4000 != 0) return setting("LS_COLORS", "su", "37;41");
    if (st.mode & 0o2000 != 0) return setting("LS_COLORS", "sg", "30;43");
    if (st.mode & 0o111 != 0) {
        const code = setting("LS_COLORS", "ex", "01;32");
        if (code.len > 0 and !same(code, "0") and !same(code, "00")) return code;
    }
    if (st.nlink > 1 and has("LS_COLORS", "mh")) return setting("LS_COLORS", "mh", "");
    var result = setting("LS_COLORS", "fi", "");
    var entries = std.mem.splitScalar(u8, u.getEnv("LS_COLORS") orelse return (if (result.len == 0) null else result), ':');
    while (entries.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (eq > 0 and entry[0] == '*' and u.matchPat(entry[0..eq], name)) result = entry[eq + 1 ..];
    }
    return if (result.len == 0) null else result;
}
