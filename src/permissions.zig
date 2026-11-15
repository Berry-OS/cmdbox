// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const u = @import("util.zig");
const linux = std.os.linux;
const mode = @import("mode.zig");
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn mask() u32 {
    const value = u.umask(0);
    _ = u.umask(@intCast(value));
    return @intCast(value);
}
pub fn chmod(args: []const []const u8) u8 {
    var expression: ?[]const u8 = null;
    var reference: ?u32 = null;
    var recursive = false;
    var silent = false;
    var paths = u.Vec([]const u8).init(u.alloc);
    var options = true;
    for (args) |arg| {
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and (same(arg, "-R") or same(arg, "--recursive"))) {
            recursive = true;
            continue;
        }
        if (options and (same(arg, "-f") or same(arg, "--silent") or same(arg, "--quiet"))) {
            silent = true;
            continue;
        }
        if (options and std.mem.startsWith(u8, arg, "--reference=")) {
            reference = (u.stat(arg[12..], true) orelse return 1).mode & 0o7777;
            continue;
        }
        if (expression == null and reference == null) expression = arg else paths.push(arg);
    }
    if (paths.items.len == 0 or expression == null and reference == null) return invalid("chmod");
    const umask = mask();
    if (expression) |expr| if (mode.apply(expr, 0o644, false, umask) == null) return invalid("chmod");
    var failed = false;
    for (paths.items) |path| if (!change(path, expression, reference, recursive, silent, umask, true)) {
        failed = true;
    };
    return if (failed) 1 else 0;
}
fn change(path: []const u8, expression: ?[]const u8, reference: ?u32, recursive: bool, silent: bool, umask: u32, top: bool) bool {
    const link = u.stat(path, false) orelse {
        if (!silent) u.errf("chmod: {s}: cannot stat\n", .{path});
        return false;
    };
    if (!top and link.mode & linux.S.IFMT == linux.S.IFLNK) return true;
    const st = u.stat(path, true) orelse return false;
    const directory = st.mode & linux.S.IFMT == linux.S.IFDIR;
    const value = reference orelse mode.apply(expression.?, st.mode, directory, umask) orelse return false;
    var success = u.ok(linux.chmod(u.zstr(path), value));
    if (!success and !silent) u.errf("chmod: {s}: cannot change mode\n", .{path});
    if (recursive and directory and link.mode & linux.S.IFMT != linux.S.IFLNK) {
        var entries = u.Vec(u.DirEnt).init(u.alloc);
        if (!u.listDir(path, &entries)) return false;
        for (entries.items) |entry| {
            const child = std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ path, entry.name }) catch return false;
            if (!change(child, expression, reference, true, silent, umask, false)) success = false;
        }
    }
    return success;
}
pub fn mkdir(args: []const []const u8) u8 {
    var parents = false;
    var verbose = false;
    var expression: ?[]const u8 = null;
    var paths = u.Vec([]const u8).init(u.alloc);
    var options = true;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and std.mem.startsWith(u8, arg, "--mode=")) {
            expression = arg[7..];
            continue;
        }
        if (options and same(arg, "--parents")) {
            parents = true;
            continue;
        }
        if (options and same(arg, "--verbose")) {
            verbose = true;
            continue;
        }
        if (options and arg.len > 1 and arg[0] == '-') {
            var k: usize = 1;
            while (k < arg.len) : (k += 1) switch (arg[k]) {
                'p' => parents = true,
                'v' => verbose = true,
                'm' => {
                    if (k + 1 < arg.len) expression = arg[k + 1 ..] else {
                        i += 1;
                        if (i == args.len) return invalid("mkdir");
                        expression = args[i];
                    }
                    break;
                },
                else => return invalid("mkdir"),
            };
        } else paths.push(arg);
    }
    if (paths.items.len == 0) return invalid("mkdir");
    const umask = mask();
    const final_mode = if (expression) |expr| mode.apply(expr, 0o777 & ~umask, true, 0) orelse return invalid("mkdir") else 0o777 & ~umask;
    var failed = false;
    for (paths.items) |path| {
        if (parents) {
            var at: usize = 1;
            while (at < path.len) : (at += 1) if (path[at] == '/') {
                const parent = path[0..at];
                const rc = linux.mkdir(u.zstr(parent), (0o777 & ~umask) | 0o300);
                if (!u.ok(rc) and (u.errno(rc) != .EXIST or !u.isDir(parent))) {
                    failed = true;
                    break;
                }
            };
        }
        const rc = linux.mkdir(u.zstr(path), final_mode);
        if (!u.ok(rc)) {
            if (!(parents and u.errno(rc) == .EXIST and u.isDir(path))) {
                u.errf("mkdir: {s}: {s}\n", .{ path, u.strerr(u.errno(rc)) });
                failed = true;
            }
        } else {
            if (expression != null and !u.ok(linux.chmod(u.zstr(path), final_mode))) failed = true;
            if (verbose) u.outf("mkdir: created directory '{s}'\n", .{path});
        }
    }
    return if (failed) 1 else 0;
}
fn invalid(command: []const u8) u8 {
    u.errf("{s}: invalid mode or operands\n", .{command});
    return 1;
}
