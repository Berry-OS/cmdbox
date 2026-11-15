// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0
const std = @import("std");
const u = @import("util.zig");
const linux = std.os.linux;
const Options = struct { recursive: bool = false, force: bool = false, interactive: bool = false, once: bool = false, directory: bool = false, verbose: bool = false, preserve_root: bool = true, one_filesystem: bool = false };
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn confirm(path: []const u8) bool {
    u.errf("rm: remove '{s}'? ", .{path});
    var result: u8 = 0;
    var byte: [1]u8 = undefined;
    while (true) {
        const rc = linux.read(0, &byte, 1);
        if (!u.ok(rc) or rc == 0 or byte[0] == '\n') break;
        if (result == 0) result = byte[0];
    }
    return result == 'y' or result == 'Y';
}
pub fn rm(args: []const []const u8) u8 {
    var opts = Options{};
    var paths = u.Vec([]const u8).init(u.alloc);
    var options = true;
    for (args) |arg| {
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and std.mem.startsWith(u8, arg, "--")) {
            if (same(arg, "--recursive")) opts.recursive = true else if (same(arg, "--force")) {
                opts.force = true;
                opts.interactive = false;
                opts.once = false;
            } else if (same(arg, "--interactive") or same(arg, "--interactive=always")) {
                opts.interactive = true;
                opts.force = false;
            } else if (same(arg, "--interactive=once")) {
                opts.once = true;
                opts.force = false;
            } else if (same(arg, "--interactive=never")) {
                opts.interactive = false;
                opts.once = false;
            } else if (same(arg, "--dir")) opts.directory = true else if (same(arg, "--verbose")) opts.verbose = true else if (same(arg, "--preserve-root")) opts.preserve_root = true else if (same(arg, "--no-preserve-root")) opts.preserve_root = false else if (same(arg, "--one-file-system")) opts.one_filesystem = true else return bad("rm");
        } else if (options and arg.len > 1 and arg[0] == '-') {
            for (arg[1..]) |flag| switch (flag) {
                'r', 'R' => opts.recursive = true,
                'f' => {
                    opts.force = true;
                    opts.interactive = false;
                    opts.once = false;
                },
                'i' => {
                    opts.interactive = true;
                    opts.force = false;
                },
                'I' => {
                    opts.once = true;
                    opts.force = false;
                },
                'd' => opts.directory = true,
                'v' => opts.verbose = true,
                else => return bad("rm"),
            };
        } else paths.push(arg);
    }
    if (paths.items.len == 0) return if (opts.force) 0 else bad("rm");
    if (opts.once and (opts.recursive or paths.items.len > 3) and !confirm("all operands")) return 0;
    var failed = false;
    const root = u.stat("/", false) orelse return 1;
    for (paths.items) |path| {
        if (same(u.basename(path), ".") or same(u.basename(path), "..")) {
            failed = true;
            continue;
        }
        const st = u.stat(path, false);
        if (st != null and opts.recursive and opts.preserve_root and st.?.dev == root.dev and st.?.ino == root.ino) {
            failed = true;
            u.errf("rm: refusing to remove root\n", .{});
            continue;
        }
        if (!remove(path, opts, if (st) |s| s.dev else 0)) failed = true;
    }
    return if (failed) 1 else 0;
}
fn remove(path: []const u8, opts: Options, device: u64) bool {
    const st = u.stat(path, false) orelse {
        const rc = linux.unlink(u.zstr(path));
        if (u.ok(rc)) return true;
        if (opts.force and (u.errno(rc) == .NOENT or u.errno(rc) == .NOTDIR)) return true;
        u.lastErrStr(path, rc);
        return false;
    };
    const directory = st.mode & linux.S.IFMT == linux.S.IFDIR;
    if (directory) {
        if (!opts.recursive and !opts.directory) {
            u.errf("rm: {s}: is a directory\n", .{path});
            return false;
        }
        if (opts.one_filesystem and st.dev != device) return false;
        if (opts.recursive) {
            if (opts.interactive and !confirm(path)) return true;
            var entries = u.Vec(u.DirEnt).init(u.alloc);
            if (!u.listDir(path, &entries)) return false;
            var success = true;
            for (entries.items) |entry| {
                const child = std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ path, entry.name }) catch return false;
                if (!remove(child, opts, device)) success = false;
            }
            if (!success) return false;
        }
    }
    if (opts.interactive and !confirm(path)) return true;
    const rc = if (directory) linux.rmdir(u.zstr(path)) else linux.unlink(u.zstr(path));
    if (!u.ok(rc)) {
        if (opts.force and u.errno(rc) == .NOENT) return true;
        u.lastErrStr(path, rc);
        return false;
    }
    if (opts.verbose) u.outf("removed {s}'{s}'\n", .{ if (directory) "directory " else "", path });
    return true;
}
pub fn rmdir(args: []const []const u8) u8 {
    var parents = false;
    var ignore = false;
    var verbose = false;
    var paths = u.Vec([]const u8).init(u.alloc);
    var options = true;
    for (args) |arg| {
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and same(arg, "--ignore-fail-on-non-empty")) {
            ignore = true;
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
            for (arg[1..]) |flag| switch (flag) {
                'p' => parents = true,
                'v' => verbose = true,
                else => return bad("rmdir"),
            };
        } else paths.push(arg);
    }
    if (paths.items.len == 0) return bad("rmdir");
    var failed = false;
    for (paths.items) |path| {
        var current = path;
        while (true) {
            if (verbose) u.outf("rmdir: removing directory, '{s}'\n", .{current});
            const rc = linux.rmdir(u.zstr(current));
            if (!u.ok(rc)) {
                if (!(ignore and (u.errno(rc) == .NOTEMPTY or u.errno(rc) == .EXIST))) {
                    u.lastErrStr(current, rc);
                    failed = true;
                }
                break;
            }
            if (!parents) break;
            current = u.dirname(current);
            if (same(current, ".")) break;
        }
    }
    return if (failed) 1 else 0;
}
fn bad(name: []const u8) u8 {
    u.errf("{s}: invalid option or missing operand\n", .{name});
    return 1;
}
