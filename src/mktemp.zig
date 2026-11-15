// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const u = @import("util.zig");
const linux = std.os.linux;
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn run(args: []const []const u8) u8 {
    var directory = false;
    var dry = false;
    var quiet = false;
    var tmpdir: ?[]const u8 = null;
    var use_tmpdir = false;
    var suffix: []const u8 = "";
    var template: ?[]const u8 = null;
    var options = true;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and same(arg, "--directory")) {
            directory = true;
            continue;
        }
        if (options and same(arg, "--dry-run")) {
            dry = true;
            continue;
        }
        if (options and same(arg, "--quiet")) {
            quiet = true;
            continue;
        }
        if (options and same(arg, "--tmpdir")) {
            use_tmpdir = true;
            continue;
        }
        if (options and std.mem.startsWith(u8, arg, "--tmpdir=")) {
            tmpdir = arg[9..];
            use_tmpdir = true;
            continue;
        }
        if (options and std.mem.startsWith(u8, arg, "--suffix=")) {
            suffix = arg[9..];
            continue;
        }
        if (options and arg.len > 1 and arg[0] == '-') {
            var k: usize = 1;
            while (k < arg.len) : (k += 1) switch (arg[k]) {
                'd' => directory = true,
                'u' => dry = true,
                'q' => quiet = true,
                't' => use_tmpdir = true,
                'p' => {
                    use_tmpdir = true;
                    if (k + 1 < arg.len) tmpdir = arg[k + 1 ..] else {
                        i += 1;
                        if (i == args.len) return bad(quiet);
                        tmpdir = args[i];
                    }
                    break;
                },
                else => return bad(quiet),
            };
        } else {
            if (template != null) return bad(quiet);
            template = arg;
        }
    }
    if (template == null) use_tmpdir = true;
    const pattern = template orelse "tmp.XXXXXXXXXX";
    if (suffix.len > 0 and std.mem.indexOfScalar(u8, suffix, '/') != null) return bad(quiet);
    var last_x: ?usize = null;
    var n = pattern.len;
    while (n > 0) {
        n -= 1;
        if (pattern[n] == 'X') {
            last_x = n;
            break;
        }
    }
    const end = (last_x orelse return bad(quiet)) + 1;
    var start = end;
    while (start > 0 and pattern[start - 1] == 'X') start -= 1;
    if (end - start < 3 or suffix.len > 0 and end != pattern.len) return bad(quiet);
    const base = if (use_tmpdir) blk: {
        if (pattern.len > 0 and pattern[0] == '/') return bad(quiet);
        const dir = tmpdir orelse u.getEnv("TMPDIR") orelse "/tmp";
        break :blk std.fmt.allocPrint(u.alloc, "{s}/{s}{s}", .{ dir, pattern, suffix }) catch return 1;
    } else std.fmt.allocPrint(u.alloc, "{s}{s}", .{ pattern, suffix }) catch return 1;
    const offset = base.len - suffix.len - pattern.len;
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    var attempts: usize = 0;
    while (attempts < 256) : (attempts += 1) {
        for (start..end) |index| {
            var random: [1]u8 = undefined;
            var rc: usize = undefined;
            while (true) {
                rc = linux.getrandom(&random, 1, 0);
                if (u.errno(rc) != .INTR) break;
            }
            if (!u.ok(rc) or rc != 1) return bad(quiet);
            base[offset + index] = alphabet[random[0] % alphabet.len];
        }
        if (dry) {
            if (u.stat(base, false) != null) continue;
        } else if (directory) {
            const rc = linux.mkdir(u.zstr(base), 0o700);
            if (u.errno(rc) == .EXIST) continue;
            if (!u.ok(rc)) return bad(quiet);
        } else {
            const file = u.File.open(base, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, 0o600) orelse {
                if (u.stat(base, false) != null) continue;
                return bad(quiet);
            };
            file.close();
        }
        u.outf("{s}\n", .{base});
        return 0;
    }
    return bad(quiet);
}
fn bad(quiet: bool) u8 {
    if (!quiet) u.errf("mktemp: invalid template or cannot create temporary file\n", .{});
    return 1;
}
