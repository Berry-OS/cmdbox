// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const u = @import("util.zig");
const linux = std.os.linux;
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
                const eq = std.mem.indexOfScalar(u8, arg, '=');
                const name = arg[0 .. eq orelse arg.len];
                if (!same(name, "--skip-fields") and !same(name, "--skip-chars") and !same(name, "--check-chars")) return bad();
                const value = if (eq) |at| arg[at + 1 ..] else blk: {
                    i += 1;
                    if (i == args.len) return bad();
                    break :blk args[i];
                };
                const n = std.fmt.parseInt(usize, value, 10) catch return bad();
                if (same(name, "--skip-fields")) opts.fields = n else if (same(name, "--skip-chars")) opts.skip = n else opts.width = n;
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
    const name = if (files.items.len > 0) files.items[0] else "-";
    const source = if (same(name, "-")) u.File{ .fd = 0 } else u.File.open(name, .{ .ACCMODE = .RDONLY }, 0) orelse {
        u.errf("uniq: {s}: cannot open\n", .{name});
        return 1;
    };
    defer if (source.fd != 0) source.close();
    const file = if (files.items.len == 2 and !same(files.items[1], "-")) u.File.open(files.items[1], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666) orelse {
        u.errf("uniq: {s}: cannot open\n", .{files.items[1]});
        return 1;
    } else u.File{ .fd = 1 };
    defer if (file.fd != 1) file.close();
    // Retain only the current record and the first record of the current group.
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(u.alloc);
    var previous: std.ArrayList(u8) = .empty;
    defer previous.deinit(u.alloc);
    var count: usize = 0;
    var buffer: [16384]u8 = undefined;
    while (true) {
        const rc = linux.read(source.fd, &buffer, buffer.len);
        if (u.errno(rc) == .INTR) continue;
        if (!u.ok(rc)) {
            u.errf("uniq: {s}: {s}\n", .{ name, u.strerr(u.errno(rc)) });
            return 1;
        }
        if (rc == 0) break;
        for (buffer[0..rc]) |byte| {
            if (byte == opts.delimiter) {
                if (!accept(&previous, &current, &count, file, opts)) return 1;
            } else current.append(u.alloc, byte) catch return 1;
        }
    }
    if (current.items.len > 0 and !accept(&previous, &current, &count, file, opts)) return 1;
    if (count > 0 and !emit(file, previous.items, count, opts)) return 1;
    return 0;
}
fn bad() u8 {
    u.errf("uniq: invalid option or operands\n", .{});
    return 1;
}

fn accept(previous: *std.ArrayList(u8), current: *std.ArrayList(u8), count: *usize, file: u.File, opts: Options) bool {
    if (count.* > 0) {
        const a = key(previous.items, opts);
        const b = key(current.items, opts);
        if (if (opts.insensitive) std.ascii.eqlIgnoreCase(a, b) else same(a, b)) {
            count.* += 1;
            current.clearRetainingCapacity();
            return true;
        }
        if (!emit(file, previous.items, count.*, opts)) return false;
    }
    std.mem.swap(std.ArrayList(u8), previous, current);
    current.clearRetainingCapacity();
    count.* = 1;
    return true;
}
fn emit(file: u.File, text: []const u8, count: usize, opts: Options) bool {
    if ((opts.duplicates and count == 1) or (opts.unique and count != 1)) return true;
    if (opts.count) {
        var buffer: [32]u8 = undefined;
        const prefix = std.fmt.bufPrint(&buffer, "{d: >7} ", .{@as(u64, count)}) catch return false;
        if (!file.write(prefix)) return writeError();
    }
    if (!file.write(text) or !file.write(&.{opts.delimiter})) return writeError();
    return true;
}
fn writeError() bool {
    u.err("uniq: write error\n");
    return false;
}
