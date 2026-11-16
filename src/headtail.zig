// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const u = @import("util.zig");
const input = @import("input.zig");
const linux = std.os.linux;
const c = @cImport({
    @cInclude("unistd.h");
});
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
const Count = struct { value: usize = 10, minus: bool = false, plus: bool = false };
fn count(text: []const u8) ?Count {
    if (text.len == 0) return null;
    var result = Count{};
    var s = text;
    if (s[0] == '-' or s[0] == '+') {
        result.minus = s[0] == '-';
        result.plus = s[0] == '+';
        s = s[1..];
    }
    var end: usize = 0;
    while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
    if (end == 0) return null;
    result.value = std.fmt.parseInt(usize, s[0..end], 10) catch return null;
    const suffix = s[end..];
    var multiplier: usize = 1;
    if (suffix.len > 0) {
        if (same(suffix, "b")) multiplier = 512 else if (same(suffix, "kB")) multiplier = 1000 else if (same(suffix, "MB")) multiplier = 1000000 else if (same(suffix, "GB")) multiplier = 1000000000 else if (same(suffix, "K") or same(suffix, "KiB")) multiplier = 1024 else if (same(suffix, "M") or same(suffix, "MiB")) multiplier = 1024 * 1024 else if (same(suffix, "G") or same(suffix, "GiB")) multiplier = 1024 * 1024 * 1024 else return null;
    }
    result.value = std.math.mul(usize, result.value, multiplier) catch return null;
    return result;
}
pub fn head(args: []const []const u8) u8 {
    return run(args, false);
}
pub fn tail(args: []const []const u8) u8 {
    return run(args, true);
}
fn run(args: []const []const u8, is_tail: bool) u8 {
    var amount = Count{};
    var bytes = false;
    var delimiter: u8 = '\n';
    var header: ?bool = null;
    var follow = false;
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
            if (same(arg, "--quiet") or same(arg, "--silent")) header = false else if (same(arg, "--verbose")) header = true else if (same(arg, "--zero-terminated")) delimiter = 0 else if (is_tail and same(arg, "--follow")) follow = true else {
                const eq = std.mem.indexOfScalar(u8, arg, '=');
                const name = arg[0 .. eq orelse arg.len];
                if (!same(name, "--lines") and !same(name, "--bytes")) return bad(arg, is_tail);
                const value = if (eq) |at| arg[at + 1 ..] else blk: {
                    i += 1;
                    if (i == args.len) return bad(arg, is_tail);
                    break :blk args[i];
                };
                bytes = same(name, "--bytes");
                amount = count(value) orelse return bad(value, is_tail);
            }
            continue;
        }
        if (options and arg.len > 1 and arg[0] == '-') {
            if (std.ascii.isDigit(arg[1])) {
                amount = count(arg[1..]) orelse return bad(arg, is_tail);
                continue;
            }
            var k: usize = 1;
            while (k < arg.len) : (k += 1) switch (arg[k]) {
                'q' => header = false,
                'v' => header = true,
                'z' => delimiter = 0,
                'f' => {
                    if (!is_tail) return bad(arg, is_tail);
                    follow = true;
                },
                'n', 'c' => |flag| {
                    const value = if (k + 1 < arg.len) arg[k + 1 ..] else blk: {
                        i += 1;
                        if (i == args.len) return bad(arg, is_tail);
                        break :blk args[i];
                    };
                    bytes = flag == 'c';
                    amount = count(value) orelse return bad(value, is_tail);
                    break;
                },
                else => return bad(arg, is_tail),
            };
            continue;
        }
        files.push(arg);
    }
    if (files.items.len == 0) files.push("-");
    var failed = false;
    var first = true;
    var streams = u.Vec(u.File).init(u.alloc);
    defer for (streams.items) |file| if (file.fd != 0) {
        file.close();
    };
    for (files.items) |name| {
        const file = if (same(name, "-")) u.File{ .fd = 0 } else u.File.open(name, .{ .ACCMODE = .RDONLY }, 0) orelse {
            u.errf("{s}: {s}: cannot open\n", .{ if (is_tail) "tail" else "head", name });
            failed = true;
            continue;
        };
        defer if (!follow and file.fd != 0) file.close();
        if (header orelse (files.items.len > 1)) {
            if (!first) u.out("\n");
            first = false;
            u.outf("==> {s} <==\n", .{if (same(name, "-")) "standard input" else name});
        }
        if (!is_tail and !amount.minus) {
            if (!streamHead(file, amount.value, bytes, delimiter)) failed = true;
        } else {
            var data = u.Vec(u8).init(u.alloc);
            var buffer: [16384]u8 = undefined;
            while (true) {
                const rc = linux.read(file.fd, &buffer, buffer.len);
                if (u.errno(rc) == .INTR) continue;
                if (!u.ok(rc)) {
                    failed = true;
                    break;
                }
                if (rc == 0) break;
                for (buffer[0..rc]) |byte| data.push(byte);
            }
            var position: usize = 0;
            if (bytes) {
                position = if (!is_tail) data.items.len -| amount.value else if (amount.plus) @min(data.items.len, amount.value -| 1) else data.items.len -| amount.value;
            } else {
                const records = input.records(data.items, delimiter);
                const line_index = if (!is_tail) records.items.len -| amount.value else if (amount.plus) @min(records.items.len, amount.value -| 1) else records.items.len -| amount.value;
                position = if (line_index < records.items.len) records.items[line_index].offset else data.items.len;
                if (records.cap > 0) u.alloc.free(records.items.ptr[0..records.cap]);
            }
            u.out(if (is_tail) data.items[position..] else data.items[0..position]);
            if (data.cap > 0) u.alloc.free(data.items.ptr[0..data.cap]);
        }
        if (follow) streams.push(file);
    }
    if (follow) {
        var buffer: [16384]u8 = undefined;
        while (streams.items.len > 0) {
            for (streams.items) |file| {
                while (true) {
                    const rc = linux.read(file.fd, &buffer, buffer.len);
                    if (!u.ok(rc) or rc == 0) break;
                    u.out(buffer[0..rc]);
                }
            }
            var duration = linux.timespec{ .sec = 1, .nsec = 0 };
            _ = linux.nanosleep(&duration, null);
        }
    }
    return if (failed) 1 else 0;
}
fn streamHead(file: u.File, initial: usize, bytes: bool, delimiter: u8) bool {
    var remaining = initial;
    var buffer: [16384]u8 = undefined;
    while (remaining > 0) {
        const rc = linux.read(file.fd, &buffer, if (bytes) @min(buffer.len, remaining) else buffer.len);
        if (u.errno(rc) == .INTR) continue;
        if (!u.ok(rc)) return false;
        if (rc == 0) return true;
        if (bytes) {
            u.out(buffer[0..rc]);
            remaining -= rc;
        } else {
            var used: usize = 0;
            for (buffer[0..rc]) |byte| {
                used += 1;
                if (byte == delimiter) {
                    remaining -= 1;
                    if (remaining == 0) break;
                }
            }
            u.out(buffer[0..used]);
            // Keep regular-file stdin positioned immediately after the output.
            if (used < rc) _ = c.lseek(file.fd, -@as(c.off_t, @intCast(rc - used)), c.SEEK_CUR);
        }
    }
    return true;
}
fn bad(arg: []const u8, is_tail: bool) u8 {
    u.errf("{s}: invalid argument: {s}\n", .{ if (is_tail) "tail" else "head", arg });
    return 1;
}
