// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const u = @import("util.zig");
const input = @import("input.zig");
const c = @cImport({
    @cInclude("wchar.h");
    @cInclude("wctype.h");
    @cInclude("stdlib.h");
    @cInclude("locale.h");
});
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
const Counts = struct { lines: u64 = 0, words: u64 = 0, chars: u64 = 0, bytes: u64 = 0, longest: u64 = 0 };
const Flags = struct { lines: bool = false, words: bool = false, chars: bool = false, bytes: bool = false, longest: bool = false };
const Result = struct { name: []const u8, counts: Counts };
fn measure(data: []const u8) Counts {
    var result = Counts{ .bytes = data.len };
    const locale = std.mem.sliceTo(c.setlocale(c.LC_CTYPE, null), 0);
    const multibyte = !same(locale, "C") and !same(locale, "POSIX");
    var word = false;
    var column: u64 = 0;
    var pos: usize = 0;
    var state: c.mbstate_t = std.mem.zeroes(c.mbstate_t);
    while (pos < data.len) {
        var wide: c.wchar_t = undefined;
        const size = if (multibyte) c.mbrtowc(&wide, data[pos..].ptr, data.len - pos, &state) else blk: {
            wide = data[pos];
            break :blk @as(usize, 1);
        };
        const valid = size != std.math.maxInt(usize) and size != std.math.maxInt(usize) - 1;
        if (!valid) {
            state = std.mem.zeroes(c.mbstate_t);
            wide = 0;
            pos += 1;
        } else {
            result.chars += 1;
            pos += if (size == 0) @as(usize, 1) else size;
        }
        const extra_space = wide == 0xa0 or wide == 0x2007 or wide == 0x202f or wide == 0x2060;
        const space = valid and (c.iswspace(@intCast(wide)) != 0 or multibyte and extra_space and u.getEnv("POSIXLY_CORRECT") == null);
        if (space) word = false else if (!word) {
            word = true;
            result.words += 1;
        }
        if (wide == '\n') {
            result.lines += 1;
            result.longest = @max(result.longest, column);
            column = 0;
        } else if (wide == '\r' or wide == '\x0c') {
            result.longest = @max(result.longest, column);
            column = 0;
        } else if (wide == '\t') column += 8 - column % 8 else if (valid) {
            const width = if (multibyte) c.wcwidth(wide) else if (wide >= 32 and wide <= 126) @as(c_int, 1) else @as(c_int, 0);
            if (width > 0) column += @intCast(width);
        }
    }
    result.longest = @max(result.longest, column);
    return result;
}
fn runInner(args: []const []const u8) u8 {
    var flags = Flags{};
    var names = u.Vec([]const u8).init(u.alloc);
    var options = true;
    var files0: ?[]const u8 = null;
    var total_mode: []const u8 = "auto";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and std.mem.startsWith(u8, arg, "--")) {
            if (same(arg, "--lines")) flags.lines = true else if (same(arg, "--words")) flags.words = true else if (same(arg, "--chars")) flags.chars = true else if (same(arg, "--bytes")) flags.bytes = true else if (same(arg, "--max-line-length")) flags.longest = true else if (std.mem.startsWith(u8, arg, "--total=")) total_mode = arg[8..] else if (std.mem.startsWith(u8, arg, "--files0-from=")) files0 = arg[14..] else if (same(arg, "--files0-from")) {
                i += 1;
                if (i == args.len) return bad();
                files0 = args[i];
            } else return bad();
        } else if (options and arg.len > 1 and arg[0] == '-') {
            for (arg[1..]) |flag| switch (flag) {
                'l' => flags.lines = true,
                'w' => flags.words = true,
                'm' => flags.chars = true,
                'c' => flags.bytes = true,
                'L' => flags.longest = true,
                else => return bad(),
            };
        } else names.push(arg);
    }
    if (!same(total_mode, "auto") and !same(total_mode, "always") and !same(total_mode, "only") and !same(total_mode, "never")) return bad();
    if (!flags.lines and !flags.words and !flags.chars and !flags.bytes and !flags.longest) {
        flags.lines = true;
        flags.words = true;
        flags.bytes = true;
    }
    const selected = @as(u8, @intFromBool(flags.lines)) + @as(u8, @intFromBool(flags.words)) + @as(u8, @intFromBool(flags.chars)) + @as(u8, @intFromBool(flags.bytes)) + @as(u8, @intFromBool(flags.longest));
    const implicit = names.items.len == 0 and files0 == null;
    if (files0) |name| {
        if (names.items.len != 0) return bad();
        const data = input.read(name, false) orelse return 1;
        var it = std.mem.splitScalar(u8, data, 0);
        while (it.next()) |entry| {
            if (entry.len == 0 and it.index == null) break;
            if (entry.len == 0 or same(entry, "-") and same(name, "-")) return bad();
            names.push(entry);
        }
    } else if (implicit) names.push("-");
    var width: usize = 1;
    var known = true;
    var estimate: u64 = 0;
    for (names.items) |name| {
        if (same(name, "-")) {
            known = false;
            continue;
        }
        if (u.stat(name, true)) |st| {
            if (st.mode & std.os.linux.S.IFMT == std.os.linux.S.IFREG) estimate +|= st.size else known = false;
        }
    }
    if (selected > 1 or names.items.len > 1) {
        if (!known) width = 7 else {
            while (estimate >= 10) : (estimate /= 10) width += 1;
        }
    }
    var total = Counts{};
    var failed = false;
    for (names.items) |name| {
        const data = input.read(name, false) orelse {
            failed = true;
            continue;
        };
        const value = measure(data);
        total.lines += value.lines;
        total.words += value.words;
        total.chars += value.chars;
        total.bytes += value.bytes;
        total.longest = @max(total.longest, value.longest);
        if (!same(total_mode, "only")) print(value, flags, width, if (implicit) null else name);
    }
    if (same(total_mode, "always") or same(total_mode, "only") or same(total_mode, "auto") and names.items.len > 1) print(total, flags, if (same(total_mode, "only")) 1 else width, if (same(total_mode, "only")) null else "total");
    return if (failed) 1 else 0;
}
fn print(value: Counts, flags: Flags, width: usize, name: ?[]const u8) void {
    var first = true;
    const values = [_]u64{ value.lines, value.words, value.chars, value.bytes, value.longest };
    const enabled = [_]bool{ flags.lines, flags.words, flags.chars, flags.bytes, flags.longest };
    for (values, enabled) |number, yes| if (yes) {
        if (!first) u.out(" ");
        first = false;
        var buffer: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch return;
        if (width > text.len) for (0..width - text.len) |_| u.out(" ");
        u.out(text);
    };
    if (name) |filename| u.outf(" {s}", .{filename});
    u.out("\n");
}
fn bad() u8 {
    u.errf("wc: invalid argument\n", .{});
    return 1;
}

pub fn run(args: []const []const u8) u8 {
    const g = @import("getopt.zig");
    const spec = g.Spec{
        .prog = "wc",
        .short = "clLmw",
        .long = &.{ "bytes", "chars", "files0-from", "lines", "max-line-length", "total", "words" },
        .long_arg = &.{ "files0-from", "total" },
        .help = "Usage: wc [OPTION]... [FILE]...\nPrint newline, word, and byte counts for each FILE.\n",
    };
    switch (g.normalize(spec, args)) {
        .exit => |code| return code,
        .args => |a| return runInner(a),
    }
}
