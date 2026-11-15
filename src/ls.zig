// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const u = @import("util.zig");
const linux = std.os.linux;
const color = @import("color.zig");
var color_initialized = false;
const c = @cImport({
    @cInclude("time.h");
});
const Options = struct {
    all: bool = false,
    almost: bool = false,
    long: bool = false,
    numeric: bool = false,
    directory: bool = false,
    recursive: bool = false,
    reverse: bool = false,
    unsorted: bool = false,
    size_sort: bool = false,
    time_sort: bool = false,
    classify: bool = false,
    slash: bool = false,
    inode: bool = false,
    human: bool = false,
    follow: bool = false,
    follow_command: bool = false,
    color_mode: color.Mode = .never,
    colored: bool = false,
    no_owner: bool = false,
    no_group: bool = false,
    time_style: []const u8 = "locale",
};
const Entry = struct { name: []const u8, path: []const u8, st: u.Stat };
const Widths = struct { links: usize = 1, owner: usize = 1, group: usize = 1, size: usize = 1, inode: usize = 1 };
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn digits(initial: u64) usize {
    var value = initial;
    var size: usize = 1;
    while (value >= 10) : (value /= 10) size += 1;
    return size;
}
fn pad(width: usize, text: []const u8, right: bool) void {
    if (!right) u.out(text);
    if (width > text.len) for (0..width - text.len) |_| u.out(" ");
    if (right) u.out(text);
}
fn number(value: u64, width: usize) void {
    var buf: [32]u8 = undefined;
    pad(width, std.fmt.bufPrint(&buf, "{d}", .{value}) catch "?", true);
}
fn sizeText(size: u64, human: bool, buf: []u8) []const u8 {
    if (!human or size < 1024) return std.fmt.bufPrint(buf, "{d}", .{size}) catch "?";
    const units = "KMGTPE";
    var value: f64 = @floatFromInt(size);
    var unit: usize = 0;
    value /= 1024;
    while (value >= 1024 and unit + 1 < units.len) : (unit += 1) value /= 1024;
    return if (value < 10) std.fmt.bufPrint(buf, "{d:.1}{c}", .{ value, units[unit] }) catch "?" else std.fmt.bufPrint(buf, "{d}{c}", .{ @as(u64, @intFromFloat(@ceil(value))), units[unit] }) catch "?";
}
fn user(st: u.Stat, numeric: bool, buf: []u8) []const u8 {
    return if (numeric) std.fmt.bufPrint(buf, "{d}", .{st.uid}) catch "?" else u.lookupUser(st.uid, buf) orelse std.fmt.bufPrint(buf, "{d}", .{st.uid}) catch "?";
}
fn group(st: u.Stat, numeric: bool, buf: []u8) []const u8 {
    return if (numeric) std.fmt.bufPrint(buf, "{d}", .{st.gid}) catch "?" else u.lookupGroup(st.gid, buf) orelse std.fmt.bufPrint(buf, "{d}", .{st.gid}) catch "?";
}
fn sorted(entries: []Entry, opts: Options) void {
    if (opts.unsorted) return;
    std.mem.sort(Entry, entries, opts, struct {
        fn less(options: Options, a: Entry, b: Entry) bool {
            var order: std.math.Order = .eq;
            if (options.size_sort) order = std.math.order(b.st.size, a.st.size) else if (options.time_sort) {
                order = std.math.order(b.st.mtime, a.st.mtime);
                if (order == .eq) order = std.math.order(b.st.mtime_nsec, a.st.mtime_nsec);
            }
            if (order == .eq) order = std.mem.order(u8, a.name, b.name);
            return if (options.reverse) order == .gt else order == .lt;
        }
    }.less);
}
fn perms(mode: u32) [10]u8 {
    var result: [10]u8 = .{ '-', '-', '-', '-', '-', '-', '-', '-', '-', '-' };
    result[0] = switch (mode & linux.S.IFMT) {
        linux.S.IFDIR => 'd',
        linux.S.IFLNK => 'l',
        linux.S.IFIFO => 'p',
        linux.S.IFSOCK => 's',
        linux.S.IFCHR => 'c',
        linux.S.IFBLK => 'b',
        else => '-',
    };
    const letters = "rwxrwxrwx";
    for (letters, 0..) |letter, index| if (mode & (@as(u32, 0o400) >> @as(u5, @intCast(index))) != 0) {
        result[index + 1] = letter;
    };
    if (mode & 0o4000 != 0) result[3] = if (mode & 0o100 != 0) 's' else 'S';
    if (mode & 0o2000 != 0) result[6] = if (mode & 0o010 != 0) 's' else 'S';
    if (mode & 0o1000 != 0) result[9] = if (mode & 0o001 != 0) 't' else 'T';
    return result;
}
fn date(st: u.Stat, style: []const u8) void {
    var timestamp: c.time_t = @intCast(st.mtime);
    var local: c.struct_tm = undefined;
    if (c.localtime_r(&timestamp, &local) == null) {
        u.out("?");
        return;
    }
    var format: []const u8 = "%b %e %H:%M";
    if (same(style, "long-iso")) format = "%Y-%m-%d %H:%M" else if (same(style, "iso")) format = "%m-%d %H:%M" else if (same(style, "full-iso")) format = "%Y-%m-%d %H:%M:%S" else if (style.len > 0 and style[0] == '+') format = style[1..] else {
        const now = c.time(null);
        if (timestamp < now - 15778476 or timestamp > now) format = "%b %e  %Y";
    }
    var buf: [128]u8 = undefined;
    const size = c.strftime(&buf, buf.len, u.zstr(format), &local);
    u.out(buf[0..size]);
    if (same(style, "full-iso")) {
        u.outf(".{d:0>9} ", .{@as(u64, st.mtime_nsec)});
        const n = c.strftime(&buf, buf.len, "%z", &local);
        u.out(buf[0..n]);
    }
}
fn printEntries(entries: []Entry, opts: Options, total: bool) void {
    var widths = Widths{};
    var blocks: u64 = 0;
    for (entries) |entry| {
        const st = entry.st;
        var buf: [256]u8 = undefined;
        widths.links = @max(widths.links, digits(st.nlink));
        widths.inode = @max(widths.inode, digits(st.ino));
        widths.owner = @max(widths.owner, user(st, opts.numeric, &buf).len);
        widths.group = @max(widths.group, group(st, opts.numeric, &buf).len);
        widths.size = @max(widths.size, sizeText(st.size, opts.human, &buf).len);
        blocks += st.blocks;
    }
    if (total and opts.long) {
        var buf: [64]u8 = undefined;
        u.outf("total {s}\n", .{sizeText(if (opts.human) blocks * 512 else (blocks + 1) / 2, opts.human, &buf)});
    }
    for (entries) |entry| {
        const st = entry.st;
        if (opts.inode) {
            number(st.ino, widths.inode);
            u.out(" ");
        }
        if (opts.long) {
            const mode = perms(st.mode);
            u.out(&mode);
            u.out(" ");
            number(st.nlink, widths.links);
            u.out(" ");
            var buf: [256]u8 = undefined;
            if (!opts.no_owner) {
                pad(widths.owner, user(st, opts.numeric, &buf), false);
                u.out(" ");
            }
            if (!opts.no_group) {
                pad(widths.group, group(st, opts.numeric, &buf), false);
                u.out(" ");
            }
            pad(widths.size, sizeText(st.size, opts.human, &buf), true);
            u.out(" ");
            date(st, opts.time_style);
            u.out(" ");
        }
        const code = if (opts.colored) color.lsCode(entry.path, entry.name, st) else null;
        if (code) |sequence| {
            if (!color_initialized) {
                color.lsEnd();
                color_initialized = true;
            }
            _ = color.lsStart(sequence);
            u.out(entry.name);
            color.lsEnd();
        } else u.out(entry.name);
        const typ = st.mode & linux.S.IFMT;
        if ((opts.slash or opts.classify) and typ == linux.S.IFDIR) u.out("/") else if (opts.classify) {
            if (typ == linux.S.IFLNK and !opts.long) u.out("@") else if (typ == linux.S.IFREG and st.mode & 0o111 != 0) u.out("*") else if (typ == linux.S.IFIFO) u.out("|") else if (typ == linux.S.IFSOCK) u.out("=");
        }
        if (opts.long and typ == linux.S.IFLNK) {
            var buf: [u.PATH_MAX]u8 = undefined;
            const rc = linux.readlink(u.zstr(entry.path), &buf, buf.len);
            if (u.ok(rc)) u.outf(" -> {s}", .{buf[0..rc]});
        }
        u.out("\n");
    }
}
fn list(path: []const u8, opts: Options, heading: bool, separated: *bool, ancestors: *u.Vec(u.Stat)) bool {
    const st = u.stat(path, true) orelse return false;
    for (ancestors.items) |ancestor| if (ancestor.dev == st.dev and ancestor.ino == st.ino) return false;
    ancestors.push(st);
    defer ancestors.pop();
    if (heading) {
        if (separated.*) u.out("\n");
        u.outf("{s}:\n", .{path});
    }
    separated.* = true;
    var names = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir(path, &names)) return false;
    if (opts.all) {
        names.push(.{ .name = u.zstr("."), .typ = 4 });
        names.push(.{ .name = u.zstr(".."), .typ = 4 });
    }
    var entries = u.Vec(Entry).init(u.alloc);
    var success = true;
    for (names.items) |name| {
        if (!opts.all and !opts.almost and name.name[0] == '.') continue;
        const full = std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ path, name.name }) catch return false;
        const value = u.stat(full, opts.follow) orelse {
            success = false;
            continue;
        };
        entries.push(.{ .name = name.name, .path = full, .st = value });
    }
    sorted(entries.items, opts);
    printEntries(entries.items, opts, true);
    if (opts.recursive) for (entries.items) |entry| {
        if (same(entry.name, ".") or same(entry.name, "..") or entry.st.mode & linux.S.IFMT != linux.S.IFDIR) continue;
        if (!list(entry.path, opts, true, separated, ancestors)) success = false;
    };
    return success;
}
pub fn run(args: []const []const u8) u8 {
    color_initialized = false;
    var opts = Options{};
    var paths = u.Vec([]const u8).init(u.alloc);
    var options = true;
    for (args) |arg| {
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and std.mem.startsWith(u8, arg, "--")) {
            if (same(arg, "--all")) opts.all = true else if (same(arg, "--almost-all")) opts.almost = true else if (same(arg, "--directory")) opts.directory = true else if (same(arg, "--recursive")) opts.recursive = true else if (same(arg, "--reverse")) opts.reverse = true else if (same(arg, "--human-readable")) opts.human = true else if (same(arg, "--classify")) opts.classify = true else if (same(arg, "--numeric-uid-gid")) {
                opts.numeric = true;
                opts.long = true;
            } else if (std.mem.startsWith(u8, arg, "--time-style=")) opts.time_style = arg[13..] else if (same(arg, "--color")) opts.color_mode = .always else if (std.mem.startsWith(u8, arg, "--color=")) opts.color_mode = color.parse(arg[8..]) orelse return bad() else if (same(arg, "--quoting-style=literal")) {} else return bad();
        } else if (options and arg.len > 1 and arg[0] == '-') {
            for (arg[1..]) |flag| switch (flag) {
                'a' => opts.all = true,
                'A' => opts.almost = true,
                'l' => opts.long = true,
                'n' => {
                    opts.numeric = true;
                    opts.long = true;
                },
                'g' => {
                    opts.long = true;
                    opts.no_owner = true;
                },
                'o' => {
                    opts.long = true;
                    opts.no_group = true;
                },
                'd' => opts.directory = true,
                'R' => opts.recursive = true,
                'r' => opts.reverse = true,
                'S' => {
                    opts.size_sort = true;
                    opts.time_sort = false;
                },
                't' => {
                    opts.time_sort = true;
                    opts.size_sort = false;
                },
                'U' => opts.unsorted = true,
                'f' => {
                    opts.unsorted = true;
                    opts.all = true;
                    opts.long = false;
                },
                'F' => opts.classify = true,
                'p' => opts.slash = true,
                'i' => opts.inode = true,
                'h' => opts.human = true,
                'L' => opts.follow = true,
                'H' => opts.follow_command = true,
                '1' => {},
                else => return bad(),
            };
        } else paths.push(arg);
    }
    opts.colored = color.lsEnabled(opts.color_mode);
    if (paths.items.len == 0) paths.push(".");
    var files = u.Vec(Entry).init(u.alloc);
    var dirs = u.Vec(Entry).init(u.alloc);
    var failed = false;
    for (paths.items) |path| {
        const st = u.stat(path, opts.follow or opts.follow_command or !opts.directory and !opts.long) orelse {
            u.errf("ls: {s}: cannot access\n", .{path});
            failed = true;
            continue;
        };
        const entry = Entry{ .name = path, .path = path, .st = st };
        if (!opts.directory and st.mode & linux.S.IFMT == linux.S.IFDIR) dirs.push(entry) else files.push(entry);
    }
    sorted(files.items, opts);
    sorted(dirs.items, opts);
    printEntries(files.items, opts, false);
    var separated = files.items.len > 0;
    var ancestors = u.Vec(u.Stat).init(u.alloc);
    for (dirs.items) |dir| if (!list(dir.path, opts, paths.items.len > 1 or opts.recursive, &separated, &ancestors)) {
        failed = true;
    };
    return if (failed) 2 else 0;
}
fn bad() u8 {
    u.errf("ls: invalid option\n", .{});
    return 2;
}
