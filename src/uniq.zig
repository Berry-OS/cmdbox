// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const u = @import("util.zig");
const input = @import("input.zig");
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
const Options = struct { count: bool = false, duplicates: bool = false, unique: bool = false, insensitive: bool = false, fields: usize = 0, skip: usize = 0, width: usize = std.math.maxInt(usize), delimiter: u8 = '\n' };
fn key(text: []const u8, opts: Options) []const u8 {
    var pos: usize = 0;
    var field: usize = 0;
    while (field < opts.fields and pos < text.len) : (field += 1) {
        while (pos < text.len and (text[pos] == ' ' or text[pos] == '\t')) pos += 1;
        while (pos < text.len and text[pos] != ' ' and text[pos] != '\t') pos += 1;
    }
    pos = @min(text.len, pos +| opts.skip);
    return text[pos..@min(text.len, pos +| opts.width)];
}
pub fn run(args: []const []const u8) u8 {
    var opts = Options{};
    var files = u.Vec([]const u8).init(u.alloc);
    var options = true;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and std.mem.startsWith(u8, arg, "--")) {
            if (same(arg, "--count")) opts.count = true else if (same(arg, "--repeated")) opts.duplicates = true else if (same(arg, "--unique")) opts.unique = true else if (same(arg, "--ignore-case")) opts.insensitive = true else if (same(arg, "--zero-terminated")) opts.delimiter = 0 else {
                const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return bad();
                const n = std.fmt.parseInt(usize, arg[eq + 1 ..], 10) catch return bad();
                if (same(arg[0..eq], "--skip-fields")) opts.fields = n else if (same(arg[0..eq], "--skip-chars")) opts.skip = n else if (same(arg[0..eq], "--check-chars")) opts.width = n else return bad();
            }
        } else if (options and arg.len > 1 and arg[0] == '-') {
            var k: usize = 1;
            while (k < arg.len) : (k += 1) switch (arg[k]) {
                'c' => opts.count = true,
                'd' => opts.duplicates = true,
                'u' => opts.unique = true,
                'i' => opts.insensitive = true,
                'z' => opts.delimiter = 0,
                'f', 's', 'w' => |flag| {
                    const value = if (k + 1 < arg.len) arg[k + 1 ..] else blk: {
                        i += 1;
                        if (i == args.len) return bad();
                        break :blk args[i];
                    };
                    const n = std.fmt.parseInt(usize, value, 10) catch return bad();
                    switch (flag) {
                        'f' => opts.fields = n,
                        's' => opts.skip = n,
                        'w' => opts.width = n,
                        else => unreachable,
                    }
                    break;
                },
                else => return bad(),
            };
        } else files.push(arg);
    }
    if (files.items.len > 2) return bad();
    const data = input.read(if (files.items.len > 0) files.items[0] else "-", false) orelse return 1;
    const records = input.records(data, opts.delimiter);
    const file = if (files.items.len == 2 and !same(files.items[1], "-")) u.File.open(files.items[1], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666) orelse return 1 else u.File{ .fd = 1 };
    defer if (file.fd != 1) file.close();
    var start: usize = 0;
    while (start < records.items.len) {
        var end = start + 1;
        const previous = key(records.items[start].text, opts);
        while (end < records.items.len) : (end += 1) {
            const current = key(records.items[end].text, opts);
            if (!(if (opts.insensitive) std.ascii.eqlIgnoreCase(previous, current) else same(previous, current))) break;
        }
        const count = end - start;
        if ((!opts.duplicates or count > 1) and (!opts.unique or count == 1)) {
            if (opts.count) {
                var buffer: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "{d: >7} ", .{@as(u64, count)}) catch return 1;
                if (!file.write(text)) return 1;
            }
            if (!file.write(records.items[start].text) or !file.write(&.{opts.delimiter})) return 1;
        }
        start = end;
    }
    return 0;
}
fn bad() u8 {
    u.errf("uniq: invalid option or operands\n", .{});
    return 1;
}
