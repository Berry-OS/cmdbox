// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const u = @import("util.zig");
const linux = std.os.linux;
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
const Missing = enum { none, last, all };
fn canonical(path: []const u8, missing: Missing, symbolic: bool) ?[]const u8 {
    if (path.len == 0) return null;
    var cwd: [u.PATH_MAX]u8 = undefined;
    if (!u.ok(linux.getcwd(&cwd, cwd.len))) return null;
    var pending = if (path[0] == '/') path else std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ std.mem.sliceTo(&cwd, 0), path }) catch return null;
    var resolved: []const u8 = "/";
    var links: usize = 0;
    while (pending.len > 0) {
        pending = std.mem.trimStart(u8, pending, "/");
        if (pending.len == 0) break;
        const end = std.mem.indexOfScalar(u8, pending, '/') orelse pending.len;
        const component = pending[0..end];
        pending = pending[end..];
        if (same(component, ".")) continue;
        if (same(component, "..")) {
            resolved = u.dirname(resolved);
            continue;
        }
        const candidate = std.fmt.allocPrint(u.alloc, "{s}{s}{s}", .{ resolved, if (same(resolved, "/")) "" else "/", component }) catch return null;
        const st = u.stat(candidate, false);
        if (st == null) {
            if (missing == .none or missing == .last and std.mem.trim(u8, pending, "/").len > 0) return null;
        } else if (!symbolic and st.?.mode & linux.S.IFMT == linux.S.IFLNK) {
            links += 1;
            if (links > 40) return null;
            var buf: [u.PATH_MAX]u8 = undefined;
            const rc = linux.readlink(u.zstr(candidate), &buf, buf.len);
            if (!u.ok(rc)) return null;
            const target = buf[0..rc];
            if (target.len > 0 and target[0] == '/') resolved = "/";
            pending = std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ target, pending }) catch return null;
            continue;
        } else if (missing != .all and std.mem.trim(u8, pending, "/").len > 0 and st.?.mode & linux.S.IFMT != linux.S.IFDIR) return null;
        resolved = candidate;
    }
    return resolved;
}
pub fn readlink(args: []const []const u8) u8 {
    return run(args, false);
}
pub fn realpath(args: []const []const u8) u8 {
    return run(args, true);
}
fn run(args: []const []const u8, real: bool) u8 {
    var missing: Missing = .last;
    var canonicalize = real;
    var symbolic = false;
    var quiet = !real;
    var newline = true;
    var zero = false;
    var options = true;
    var relative: ?[]const u8 = null;
    var files = u.Vec([]const u8).init(u.alloc);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and std.mem.startsWith(u8, arg, "--")) {
            if (same(arg, "--canonicalize")) {
                canonicalize = true;
                missing = .last;
            } else if (same(arg, "--canonicalize-existing")) {
                canonicalize = true;
                missing = .none;
            } else if (same(arg, "--canonicalize-missing")) {
                canonicalize = true;
                missing = .all;
            } else if (same(arg, "--canonicalize-all-but-last")) {
                canonicalize = true;
                missing = .last;
            } else if (same(arg, "--strip") or same(arg, "--no-symlinks")) symbolic = true else if (same(arg, "--quiet") or same(arg, "--silent")) quiet = true else if (same(arg, "--verbose")) quiet = false else if (same(arg, "--zero")) zero = true else if (same(arg, "--no-newline")) newline = false else if (std.mem.startsWith(u8, arg, "--relative-to=")) relative = arg[14..] else return bad(real);
            continue;
        }
        if (options and arg.len > 1 and arg[0] == '-') {
            for (arg[1..]) |flag| switch (flag) {
                'f' => {
                    if (real) return bad(real);
                    canonicalize = true;
                    missing = .last;
                },
                'E' => {
                    if (!real) return bad(real);
                    canonicalize = true;
                    missing = .last;
                },
                'e' => {
                    canonicalize = true;
                    missing = .none;
                },
                'm' => {
                    canonicalize = true;
                    missing = .all;
                },
                's' => {
                    if (real) symbolic = true else quiet = true;
                },
                'q' => quiet = true,
                'v' => quiet = false,
                'n' => newline = false,
                'z' => zero = true,
                else => return bad(real),
            };
        } else files.push(arg);
    }
    if (files.items.len == 0) return bad(real);
    const base = if (relative) |name| canonical(name, missing, symbolic) orelse return 1 else null;
    var failed = false;
    for (files.items) |name| {
        const resolved = if (canonicalize) canonical(name, missing, symbolic) else blk: {
            var buffer: [u.PATH_MAX]u8 = undefined;
            const rc = linux.readlink(u.zstr(name), &buffer, buffer.len);
            break :blk if (u.ok(rc)) (u.alloc.dupe(u8, buffer[0..rc]) catch null) else null;
        };
        if (resolved) |value| {
            const text = if (base) |from| std.fs.path.relativePosix(u.alloc, "/", from, value) catch return 1 else value;
            u.out(if (text.len == 0) "." else text);
            if (zero) u.out(&.{0}) else if (newline) u.out("\n");
        } else {
            failed = true;
            if (!quiet) u.errf("{s}: {s}: cannot resolve\n", .{ if (real) "realpath" else "readlink", name });
        }
    }
    return if (failed) 1 else 0;
}
fn bad(real: bool) u8 {
    u.errf("{s}: invalid option or operand\n", .{if (real) "realpath" else "readlink"});
    return 1;
}
