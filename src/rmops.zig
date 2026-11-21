// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// rm, mkdir, rmdir - GNU coreutils semantics and diagnostics
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const mode_mod = @import("mode.zig");

const HELP: u8 = 200;
const VERSION: u8 = 201;

fn isTty(fd: i32) bool {
    var t: [64]u8 = undefined;
    return u.ok(linux.ioctl(fd, 0x5401, @intFromPtr(&t)));
}

fn joinPath(dir: []const u8, name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, dir, "/")) return std.fmt.allocPrint(u.alloc, "{s}{s}", .{ dir, name }) catch name;
    return std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ dir, name }) catch name;
}

fn readAnswer() bool {
    var first: u8 = 0;
    var n: usize = 0;
    while (true) {
        var b: [1]u8 = undefined;
        const r = linux.read(0, &b, 1);
        if (!u.ok(r) or r == 0) break;
        if (n == 0) first = b[0];
        n += 1;
        if (b[0] == '\n') break;
    }
    return first == 'y' or first == 'Y';
}

// ===================== rm =====================
const Interactive = enum { never, once, always };

const RmCtx = struct {
    force: bool = false,
    interactive: Interactive = .never,
    recursive: bool = false,
    dir: bool = false,
    verbose: bool = false,
    one_fs: bool = false,
    preserve_root: bool = true,
    failed: bool = false,
    stdin_tty: bool = false,
};

fn typeName(st: u.Stat) []const u8 {
    return switch (st.mode & linux.S.IFMT) {
        linux.S.IFREG => if (st.size == 0) "regular empty file" else "regular file",
        linux.S.IFDIR => "directory",
        linux.S.IFLNK => "symbolic link",
        linux.S.IFBLK => "block special file",
        linux.S.IFCHR => "character special file",
        linux.S.IFIFO => "fifo",
        linux.S.IFSOCK => "socket",
        else => "weird file",
    };
}

fn rmErr(ctx: *RmCtx, comptime fmt: []const u8, args: anytype) void {
    u.errf("rm: " ++ fmt ++ "\n", args);
    ctx.failed = true;
}

fn writable(path: []const u8) bool {
    return u.ok(linux.access(u.zstr(path), 2));
}

fn removeDir(ctx: *RmCtx, path: []const u8, st: u.Stat) void {
    // descend / remove directory
    const prompt_each = ctx.interactive == .always;
    if (prompt_each) {
        u.errf("rm: descend into directory '{s}'? ", .{path});
        if (!readAnswer()) return;
    } else if (!ctx.force and ctx.stdin_tty and !writable(path)) {
        u.errf("rm: descend into write-protected directory '{s}'? ", .{path});
        if (!readAnswer()) return;
    }
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir(path, &ents)) {
        const en = u.errno(linux.open(u.zstr(path), .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0));
        rmErr(ctx, "cannot remove '{s}': {s}", .{ path, u.strerr(if (en == .SUCCESS) .ACCES else en) });
        return;
    }
    var all_removed = true;
    const before = ctx.failed;
    for (ents.items) |e| {
        const child = joinPath(path, e.name);
        if (!removeOne(ctx, child, false, st.dev)) all_removed = false;
    }
    _ = before;
    if (!all_removed) {
        // children that were skipped or failed keep the directory non-empty
    }
    // remove the (hopefully empty) directory
    if (prompt_each) {
        u.errf("rm: remove directory '{s}'? ", .{path});
        if (!readAnswer()) return;
    } else if (!ctx.force and ctx.stdin_tty and !writable(path) and false) {}
    const rc = linux.rmdir(u.zstr(path));
    if (!u.ok(rc)) {
        const en = u.errno(rc);
        if (!all_removed and en == .NOTEMPTY) return; // an earlier error already explained it
        rmErr(ctx, "cannot remove '{s}': {s}", .{ path, u.strerr(en) });
        return;
    }
    if (ctx.verbose) u.outf("removed directory '{s}'\n", .{path});
}

/// returns true when the entry is gone
fn removeOne(ctx: *RmCtx, path: []const u8, top: bool, parent_dev: u64) bool {
    const st = u.stat(path, false) orelse {
        if (!ctx.force) rmErr(ctx, "cannot remove '{s}': No such file or directory", .{path});
        return ctx.force;
    };
    const is_dir = st.mode & linux.S.IFMT == linux.S.IFDIR;
    if (is_dir) {
        if (!ctx.recursive and !ctx.dir) {
            rmErr(ctx, "cannot remove '{s}': Is a directory", .{path});
            return false;
        }
        if (ctx.one_fs and !top and st.dev != parent_dev) {
            u.errf("rm: skipping '{s}', since it's on a different device\n", .{path});
            ctx.failed = true;
            return false;
        }
        if (!ctx.recursive) {
            // -d: only empty directories
            if (ctx.interactive == .always) {
                u.errf("rm: remove directory '{s}'? ", .{path});
                if (!readAnswer()) return false;
            }
            const rc = linux.rmdir(u.zstr(path));
            if (!u.ok(rc)) {
                rmErr(ctx, "cannot remove '{s}': {s}", .{ path, u.strerr(u.errno(rc)) });
                return false;
            }
            if (ctx.verbose) u.outf("removed directory '{s}'\n", .{path});
            return true;
        }
        const before = ctx.failed;
        removeDir(ctx, path, st);
        return u.stat(path, false) == null and (ctx.failed == before or true) and u.stat(path, false) == null;
    }
    // non-directory
    if (ctx.interactive == .always) {
        u.errf("rm: remove {s} '{s}'? ", .{ typeName(st), path });
        if (!readAnswer()) return false;
    } else if (!ctx.force and ctx.stdin_tty and st.mode & linux.S.IFMT != linux.S.IFLNK and !writable(path)) {
        u.errf("rm: remove write-protected {s} '{s}'? ", .{ typeName(st), path });
        if (!readAnswer()) return false;
    }
    const rc = linux.unlink(u.zstr(path));
    if (!u.ok(rc)) {
        const en = u.errno(rc);
        if (en == .NOENT and ctx.force) return true;
        rmErr(ctx, "cannot remove '{s}': {s}", .{ path, u.strerr(en) });
        return false;
    }
    if (ctx.verbose) u.outf("removed '{s}'\n", .{path});
    return true;
}

fn isDotOrDotDot(path: []const u8) bool {
    var s = path;
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    const base = if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| s[i + 1 ..] else s;
    return std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..");
}

pub fn rm(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "force", .key = 'f' },
        .{ .key = 'i' },
        .{ .key = 'I' },
        .{ .name = "interactive", .key = 130, .arg = .opt },
        .{ .name = "one-file-system", .key = 131 },
        .{ .name = "no-preserve-root", .key = 132 },
        .{ .name = "preserve-root", .key = 133, .arg = .opt },
        .{ .name = "recursive", .key = 'r' },
        .{ .key = 'R' },
        .{ .name = "dir", .key = 'd' },
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "help", .key = HELP },
        .{ .name = "version", .key = VERSION },
    };
    var ctx = RmCtx{};
    ctx.stdin_tty = isTty(0);
    var p = g.Parser.init("rm", args, &opts);
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'f' => {
                ctx.force = true;
                ctx.interactive = .never;
            },
            'i' => {
                ctx.interactive = .always;
                ctx.force = false;
            },
            'I' => {
                ctx.interactive = .once;
                ctx.force = false;
            },
            130 => {
                const v = it.val orelse "always";
                if (std.mem.eql(u8, v, "never") or std.mem.eql(u8, v, "no") or std.mem.eql(u8, v, "none")) {
                    ctx.interactive = .never;
                } else if (std.mem.eql(u8, v, "once")) {
                    ctx.interactive = .once;
                } else if (std.mem.eql(u8, v, "always") or std.mem.eql(u8, v, "yes")) {
                    ctx.interactive = .always;
                } else {
                    u.errf("rm: invalid argument '{s}' for '--interactive'\nValid arguments are:\n  - 'never', 'no', 'none'\n  - 'once'\n  - 'always', 'yes'\nTry 'rm --help' for more information.\n", .{v});
                    return 1;
                }
            },
            131 => ctx.one_fs = true,
            132 => ctx.preserve_root = false,
            133 => {
                if (it.val) |v| {
                    if (!std.mem.eql(u8, v, "all")) {
                        u.errf("rm: unrecognized --preserve-root argument: {s}\n", .{v});
                        return 1;
                    }
                }
                ctx.preserve_root = true;
            },
            'r', 'R' => ctx.recursive = true,
            'd' => ctx.dir = true,
            'v' => ctx.verbose = true,
            HELP => {
                u.out("Usage: rm [OPTION]... [FILE]...\nRemove (unlink) the FILE(s).\n");
                return 0;
            },
            VERSION => {
                u.out("rm (cmdbox)\n");
                return 0;
            },
            else => {},
        }
    }
    const ops = p.operands.items;
    if (ops.len == 0) {
        if (ctx.force) return 0;
        u.err("rm: missing operand\nTry 'rm --help' for more information.\n");
        return 1;
    }
    // -I: one prompt for many files or recursive removal
    if (ctx.interactive == .once and (ops.len > 3 or ctx.recursive)) {
        if (ops.len > 3) {
            u.errf("rm: remove {d} arguments{s}? ", .{ ops.len, if (ctx.recursive) " recursively" else "" });
        } else {
            u.errf("rm: remove {d} argument{s} recursively? ", .{ ops.len, if (ops.len == 1) "" else "s" });
        }
        if (!readAnswer()) return 0;
    }
    const root = u.stat("/", true);
    for (ops) |path| {
        if (isDotOrDotDot(path)) {
            u.errf("rm: refusing to remove '.' or '..' directory: skipping '{s}'\n", .{path});
            ctx.failed = true;
            continue;
        }
        if (ctx.recursive and ctx.preserve_root) {
            if (u.stat(path, true)) |s| {
                if (root != null and s.dev == root.?.dev and s.ino == root.?.ino) {
                    u.errf("rm: it is dangerous to operate recursively on '{s}'\nrm: use --no-preserve-root to override this failsafe\n", .{path});
                    ctx.failed = true;
                    continue;
                }
            }
        }
        _ = removeOne(&ctx, path, true, 0);
    }
    return if (ctx.failed) 1 else 0;
}

// ===================== mkdir =====================
pub fn mkdir(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "mode", .key = 'm', .arg = .req },
        .{ .name = "parents", .key = 'p' },
        .{ .name = "verbose", .key = 'v' },
        .{ .key = 'Z' },
        .{ .name = "context", .key = 130, .arg = .req },
        .{ .name = "help", .key = HELP },
        .{ .name = "version", .key = VERSION },
    };
    var p = g.Parser.init("mkdir", args, &opts);
    var mode_expr: ?[]const u8 = null;
    var parents = false;
    var verbose = false;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'm' => mode_expr = it.val,
            'p' => parents = true,
            'v' => verbose = true,
            'Z', 130 => {},
            HELP => {
                u.out("Usage: mkdir [OPTION]... DIRECTORY...\nCreate the DIRECTORY(ies), if they do not already exist.\n");
                return 0;
            },
            VERSION => {
                u.out("mkdir (cmdbox)\n");
                return 0;
            },
            else => {},
        }
    }
    const um = u.umask(0);
    _ = u.umask(um);
    var final_mode: ?u32 = null;
    if (mode_expr) |e| {
        final_mode = mode_mod.apply(e, 0o777, true, um) orelse {
            u.errf("mkdir: invalid mode '{s}'\n", .{e});
            return 1;
        };
    }
    const ops = p.operands.items;
    if (ops.len == 0) {
        u.err("mkdir: missing operand\nTry 'mkdir --help' for more information.\n");
        return 1;
    }
    var rc: u8 = 0;
    for (ops) |path0| {
        var path = path0;
        while (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
        if (parents) {
            // create each missing component (u+wx added so that children can be created)
            var i: usize = 0;
            var failed = false;
            while (i < path.len) {
                const next = std.mem.indexOfScalarPos(u8, path, i, '/') orelse path.len;
                if (next > 0) {
                    const prefix = path[0..next];
                    const is_last = next >= path.len;
                    if (!(prefix.len == 1 and prefix[0] == '/')) {
                        if (u.stat(prefix, true)) |s| {
                            if (s.mode & linux.S.IFMT != linux.S.IFDIR) {
                                if (is_last) u.errf("mkdir: cannot create directory '{s}': File exists\n", .{prefix}) else u.errf("mkdir: cannot create directory '{s}': Not a directory\n", .{prefix});
                                failed = true;
                                break;
                            }
                        } else {
                            const cmode: u32 = if (is_last) (final_mode orelse (0o777 & ~um)) else ((0o777 & ~um) | 0o300);
                            const r = linux.mkdir(u.zstr(prefix), if (is_last and final_mode != null) (cmode & 0o777) else cmode);
                            if (!u.ok(r)) {
                                const en = u.errno(r);
                                if (en != .EXIST) {
                                    u.errf("mkdir: cannot create directory '{s}': {s}\n", .{ prefix, u.strerr(en) });
                                    failed = true;
                                    break;
                                }
                            } else {
                                if (verbose) u.outf("mkdir: created directory '{s}'\n", .{prefix});
                                if (is_last and final_mode != null) _ = linux.chmod(u.zstr(prefix), final_mode.?);
                            }
                        }
                    }
                }
                i = next + 1;
            }
            if (failed) rc = 1;
            continue;
        }
        const cm: u32 = final_mode orelse (0o777 & ~um);
        const r = linux.mkdir(u.zstr(path), cm & 0o777);
        if (!u.ok(r)) {
            u.errf("mkdir: cannot create directory '{s}': {s}\n", .{ path, u.strerr(u.errno(r)) });
            rc = 1;
            continue;
        }
        if (final_mode) |fm| _ = linux.chmod(u.zstr(path), fm);
        if (verbose) u.outf("mkdir: created directory '{s}'\n", .{path});
    }
    return rc;
}

// ===================== rmdir =====================
pub fn rmdir(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "ignore-fail-on-non-empty", .key = 130 },
        .{ .name = "parents", .key = 'p' },
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "help", .key = HELP },
        .{ .name = "version", .key = VERSION },
    };
    var p = g.Parser.init("rmdir", args, &opts);
    var ignore_ne = false;
    var parents = false;
    var verbose = false;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            130 => ignore_ne = true,
            'p' => parents = true,
            'v' => verbose = true,
            HELP => {
                u.out("Usage: rmdir [OPTION]... DIRECTORY...\nRemove the DIRECTORY(ies), if they are empty.\n");
                return 0;
            },
            VERSION => {
                u.out("rmdir (cmdbox)\n");
                return 0;
            },
            else => {},
        }
    }
    const ops = p.operands.items;
    if (ops.len == 0) {
        u.err("rmdir: missing operand\nTry 'rmdir --help' for more information.\n");
        return 1;
    }
    var rc: u8 = 0;
    for (ops) |path0| {
        var path: []const u8 = path0;
        while (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
        var first = true;
        while (true) {
            if (verbose) u.outf("rmdir: removing directory, '{s}'\n", .{path});
            const r = linux.rmdir(u.zstr(path));
            if (!u.ok(r)) {
                const en = u.errno(r);
                const ignorable = ignore_ne and (en == .NOTEMPTY or en == .EXIST);
                if (!ignorable) {
                    if (first) u.errf("rmdir: failed to remove '{s}': {s}\n", .{ path, u.strerr(en) }) else u.errf("rmdir: failed to remove directory '{s}': {s}\n", .{ path, u.strerr(en) });
                    rc = 1;
                }
                break;
            }
            first = false;
            if (!parents) break;
            // remove the parent
            var s = path;
            while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
            const slash = std.mem.lastIndexOfScalar(u8, s, '/') orelse break;
            var parent = s[0..slash];
            while (parent.len > 1 and parent[parent.len - 1] == '/') parent = parent[0 .. parent.len - 1];
            if (parent.len == 0) break;
            path = parent;
        }
    }
    return rc;
}
