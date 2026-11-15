// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
const Options = struct {
    recursive: bool = false,
    preserve: bool = false,
    links: bool = false,
    force: bool = false,
    interactive: bool = false,
    no_clobber: bool = false,
    verbose: bool = false,
    update: bool = false,
    symbolic: bool = false,
    hard: bool = false,
    no_target: bool = false,
    no_deref_dest: bool = false,
    deref: enum { default, always, never, command_line } = .default,
    target: ?[]const u8 = null,
};
const Link = struct { dev: u64, ino: u64, destination: []const u8 };
const Context = struct { opts: Options, links: u.Vec(Link), ancestors: u.Vec(u.Stat), destinations: u.Vec(u.Stat) };
pub fn cp(args: []const []const u8) u8 {
    return run(args, 'c');
}
pub fn mv(args: []const []const u8) u8 {
    return run(args, 'm');
}
pub fn ln(args: []const []const u8) u8 {
    return run(args, 'l');
}
fn run(args: []const []const u8, kind: u8) u8 {
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
            if (same(arg, "--archive") and kind == 'c') {
                opts.recursive = true;
                opts.preserve = true;
                opts.links = true;
                opts.deref = .never;
            } else if (same(arg, "--recursive") and kind == 'c') opts.recursive = true else if (same(arg, "--force")) {
                opts.force = true;
                opts.interactive = false;
                opts.no_clobber = false;
            } else if (same(arg, "--interactive")) {
                opts.interactive = true;
                opts.no_clobber = false;
            } else if (same(arg, "--no-clobber")) {
                opts.no_clobber = true;
                opts.interactive = false;
            } else if (same(arg, "--verbose")) opts.verbose = true else if (same(arg, "--update")) opts.update = true else if (same(arg, "--no-target-directory")) opts.no_target = true else if (same(arg, "--no-dereference")) {
                opts.deref = .never;
                opts.no_deref_dest = true;
            } else if (same(arg, "--dereference")) opts.deref = .always else if (same(arg, "--symbolic-link") or same(arg, "--symbolic")) opts.symbolic = true else if (same(arg, "--link")) opts.hard = true else if (same(arg, "--preserve") or same(arg, "--preserve=all") or same(arg, "--preserve=mode,ownership,timestamps")) opts.preserve = true else if (same(arg, "--preserve=links")) opts.links = true else if (std.mem.startsWith(u8, arg, "--target-directory=")) opts.target = arg[19..] else if (same(arg, "--target-directory")) {
                i += 1;
                if (i == args.len) return bad(kind, arg);
                opts.target = args[i];
            } else if (same(arg, "--reflink=auto") or same(arg, "--sparse=auto")) {} // Ordinary copy is the specified fallback.
            else return bad(kind, arg);
            continue;
        }
        if (options and arg.len > 1 and arg[0] == '-') {
            var k: usize = 1;
            while (k < arg.len) : (k += 1) switch (arg[k]) {
                'a' => {
                    if (kind != 'c') return bad(kind, arg);
                    opts.recursive = true;
                    opts.preserve = true;
                    opts.links = true;
                    opts.deref = .never;
                },
                'r', 'R' => {
                    if (kind != 'c') return bad(kind, arg);
                    opts.recursive = true;
                },
                'p' => {
                    if (kind != 'c') return bad(kind, arg);
                    opts.preserve = true;
                },
                'd' => {
                    opts.links = true;
                    opts.deref = .never;
                },
                'P' => opts.deref = .never,
                'L' => opts.deref = .always,
                'H' => opts.deref = .command_line,
                'f' => {
                    opts.force = true;
                    opts.interactive = false;
                    opts.no_clobber = false;
                },
                'i' => {
                    opts.interactive = true;
                    opts.no_clobber = false;
                },
                'n' => {
                    if (kind == 'l') opts.no_deref_dest = true else {
                        opts.no_clobber = true;
                        opts.interactive = false;
                    }
                },
                'v' => opts.verbose = true,
                'u' => opts.update = true,
                's' => opts.symbolic = true,
                'l' => opts.hard = true,
                'T' => opts.no_target = true,
                't' => {
                    if (k + 1 < arg.len) opts.target = arg[k + 1 ..] else {
                        i += 1;
                        if (i == args.len) return bad(kind, arg);
                        opts.target = args[i];
                    }
                    break;
                },
                else => return bad(kind, arg),
            };
            continue;
        }
        files.push(arg);
    }
    if (kind == 'l' and opts.target == null and files.items.len == 1) {
        opts.target = ".";
    }
    if (opts.target == null and files.items.len < 2 or opts.target != null and files.items.len < 1 or opts.no_target and opts.target != null) return bad(kind, "missing operands");
    const destination = opts.target orelse files.items[files.items.len - 1];
    const sources = if (opts.target != null) files.items else files.items[0 .. files.items.len - 1];
    const dest_link = u.stat(destination, false);
    const is_directory = !opts.no_target and !(opts.no_deref_dest and dest_link != null and dest_link.?.mode & linux.S.IFMT == linux.S.IFLNK) and u.isDir(destination);
    if ((opts.target != null or sources.len > 1) and !is_directory) return bad(kind, "target is not a directory");
    var context = Context{ .opts = opts, .links = u.Vec(Link).init(u.alloc), .ancestors = u.Vec(u.Stat).init(u.alloc), .destinations = u.Vec(u.Stat).init(u.alloc) };
    var failed = false;
    for (sources) |source| {
        const target = if (is_directory) std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ destination, u.basename(source) }) catch return 1 else destination;
        const success = switch (kind) {
            'c' => copy(&context, source, target, true),
            'm' => move(&context, source, target),
            'l' => link(source, target, opts),
            else => unreachable,
        };
        if (!success) {
            u.errf("{s}: '{s}' -> '{s}': operation failed\n", .{ command(kind), source, target });
            failed = true;
        } else if (opts.verbose) u.outf("'{s}' -> '{s}'\n", .{ source, target });
    }
    return if (failed) 1 else 0;
}
fn sameFile(a: u.Stat, b: u.Stat) bool {
    return a.ino == b.ino and a.dev == b.dev;
}
fn confirm(path: []const u8) bool {
    u.errf("overwrite '{s}'? ", .{path});
    var byte: [1]u8 = undefined;
    var answer: u8 = 0;
    while (true) {
        const rc = linux.read(0, &byte, 1);
        if (!u.ok(rc) or rc == 0 or byte[0] == '\n') break;
        if (answer == 0) answer = byte[0];
    }
    return answer == 'y' or answer == 'Y';
}
fn skip(target: []const u8, opts: Options, exists: bool) bool {
    return exists and (opts.no_clobber or opts.interactive and !confirm(target));
}
fn link(source: []const u8, target: []const u8, opts: Options) bool {
    const source_st = u.stat(source, opts.deref == .always);
    const target_st = u.stat(target, false);
    if (source_st != null and target_st != null and sameFile(source_st.?, target_st.?)) return false;
    if (opts.interactive and target_st != null and !confirm(target)) return true;
    const flags: u32 = if (opts.deref == .always) 0x400 else 0;
    var rc = if (opts.symbolic) linux.symlink(u.zstr(source), u.zstr(target)) else linux.linkat(std.posix.AT.FDCWD, u.zstr(source), std.posix.AT.FDCWD, u.zstr(target), flags);
    if (!u.ok(rc) and u.errno(rc) == .EXIST and (opts.force or opts.interactive)) {
        if (!u.ok(linux.unlink(u.zstr(target)))) return false;
        rc = if (opts.symbolic) linux.symlink(u.zstr(source), u.zstr(target)) else linux.linkat(std.posix.AT.FDCWD, u.zstr(source), std.posix.AT.FDCWD, u.zstr(target), flags);
    }
    return u.ok(rc);
}
fn preserve(source: []const u8, target: []const u8, st: u.Stat, symlink: bool) bool {
    var success = true;
    const rc = if (symlink) linux.lchown(u.zstr(target), st.uid, st.gid) else linux.chown(u.zstr(target), st.uid, st.gid);
    // Unprivileged users can preserve their own files even without chown permission.
    if (!u.ok(rc) and u.errno(rc) != .PERM) success = false;
    if (!symlink and !u.ok(linux.chmod(u.zstr(target), st.mode & 0o7777))) success = false;
    _ = source;
    if (!u.setTimes(target, st, !symlink)) success = false;
    return success;
}
fn copy(context: *Context, source: []const u8, target: []const u8, top: bool) bool {
    const opts = context.opts;
    const dereference = opts.deref == .always or opts.deref == .command_line and top or opts.deref == .default and !opts.recursive;
    const st = u.stat(source, dereference) orelse return false;
    const dest_link = u.stat(target, false);
    const dest = u.stat(target, true);
    if (dest != null and sameFile(st, dest.?)) return false;
    const directory = st.mode & linux.S.IFMT == linux.S.IFDIR;
    if (!directory and skip(target, opts, dest_link != null)) return opts.no_clobber;
    if (!directory and opts.update and dest != null and (dest.?.mtime > st.mtime or dest.?.mtime == st.mtime and dest.?.mtime_nsec >= st.mtime_nsec)) return true;
    if (directory) {
        if (!opts.recursive) return false;
        for (context.destinations.items) |destination| if (sameFile(st, destination)) return false;
        for (context.ancestors.items) |ancestor| if (sameFile(st, ancestor)) return false;
        context.ancestors.push(st);
        defer context.ancestors.pop();
        if (dest != null and dest.?.mode & linux.S.IFMT != linux.S.IFDIR) return false;
        const created = dest == null;
        if (created and !u.ok(linux.mkdir(u.zstr(target), (st.mode & 0o777) | 0o700))) return false;
        context.destinations.push(u.stat(target, true) orelse return false);
        defer context.destinations.pop();
        var entries = u.Vec(u.DirEnt).init(u.alloc);
        if (!u.listDir(source, &entries)) return false;
        var success = true;
        for (entries.items) |entry| {
            const src = std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ source, entry.name }) catch return false;
            const dst = std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ target, entry.name }) catch return false;
            if (!copy(context, src, dst, false)) success = false;
        }
        if (opts.preserve) {
            if (!preserve(source, target, st, false)) success = false;
        } else if (created) {
            const umask = u.umask(0);
            _ = u.umask(@intCast(umask));
            if (!u.ok(linux.chmod(u.zstr(target), st.mode & 0o777 & ~@as(u32, @intCast(umask))))) success = false;
        }
        return success;
    }
    if (opts.symbolic or opts.hard) return link(source, target, .{ .symbolic = opts.symbolic, .force = opts.force, .deref = .always });
    if (st.mode & linux.S.IFMT == linux.S.IFLNK) {
        var buffer: [u.PATH_MAX]u8 = undefined;
        const rc = linux.readlink(u.zstr(source), &buffer, buffer.len);
        if (!u.ok(rc)) return false;
        if (dest_link != null and !u.ok(linux.unlink(u.zstr(target)))) return false;
        if (!u.ok(linux.symlink(u.zstr(buffer[0..rc]), u.zstr(target)))) return false;
        return !opts.preserve or preserve(source, target, st, true);
    }
    if (opts.links and st.nlink > 1) {
        for (context.links.items) |entry| if (entry.dev == st.dev and entry.ino == st.ino) {
            if (dest_link != null and !u.ok(linux.unlink(u.zstr(target)))) return false;
            return u.ok(linux.linkat(std.posix.AT.FDCWD, u.zstr(entry.destination), std.posix.AT.FDCWD, u.zstr(target), 0));
        };
    }
    if (opts.recursive and st.mode & linux.S.IFMT != linux.S.IFREG) {
        if (dest_link != null and !u.ok(linux.unlink(u.zstr(target)))) return false;
        if (c.mknod(u.zstr(target), st.mode, st.rdev) != 0) return false;
        return !opts.preserve or preserve(source, target, st, false);
    }
    if (dest_link != null and dest == null) return false; // Refuse dangling destination symlinks.
    const src = u.File.open(source, .{ .ACCMODE = .RDONLY }, 0) orelse return false;
    defer src.close();
    var dst = u.File.open(target, .{ .ACCMODE = .WRONLY, .CREAT = true }, st.mode & 0o777);
    if (dst == null and opts.force) {
        _ = linux.unlink(u.zstr(target));
        dst = u.File.open(target, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, st.mode & 0o777);
    }
    const output = dst orelse return false;
    defer output.close();
    const stat_src = u.statFd(src.fd) orelse return false;
    const stat_dst = u.statFd(output.fd) orelse return false;
    if (sameFile(stat_src, stat_dst)) return false;
    if (stat_dst.mode & linux.S.IFMT == linux.S.IFREG and c.ftruncate(output.fd, 0) != 0) return false;
    var buffer: [65536]u8 = undefined;
    if (!u.copyFd(src, output, &buffer)) return false;
    if (opts.links and st.nlink > 1) context.links.push(.{ .dev = st.dev, .ino = st.ino, .destination = u.alloc.dupe(u8, target) catch return false });
    return !opts.preserve or preserve(source, target, st, false);
}
fn removeTree(path: []const u8) bool {
    const st = u.stat(path, false) orelse return false;
    if (st.mode & linux.S.IFMT == linux.S.IFDIR) {
        var entries = u.Vec(u.DirEnt).init(u.alloc);
        if (!u.listDir(path, &entries)) return false;
        for (entries.items) |entry| {
            const child = std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ path, entry.name }) catch return false;
            if (!removeTree(child)) return false;
        }
        return u.ok(linux.rmdir(u.zstr(path)));
    }
    return u.ok(linux.unlink(u.zstr(path)));
}
fn move(context: *Context, source: []const u8, target: []const u8) bool {
    const st = u.stat(source, false) orelse return false;
    const dest = u.stat(target, false);
    if (skip(target, context.opts, dest != null)) return context.opts.no_clobber;
    if (dest != null and sameFile(st, dest.?)) return false;
    if (context.opts.update and dest != null and (dest.?.mtime > st.mtime or dest.?.mtime == st.mtime and dest.?.mtime_nsec >= st.mtime_nsec)) return true;
    const rc = linux.rename(u.zstr(source), u.zstr(target));
    if (u.ok(rc)) return true;
    if (u.errno(rc) != .XDEV) return false;
    var copy_context = Context{ .opts = .{ .recursive = true, .preserve = true, .links = true, .deref = .never }, .links = u.Vec(Link).init(u.alloc), .ancestors = u.Vec(u.Stat).init(u.alloc), .destinations = u.Vec(u.Stat).init(u.alloc) };
    if (!copy(&copy_context, source, target, true)) return false;
    return removeTree(source);
}
fn command(kind: u8) []const u8 {
    return if (kind == 'c') "cp" else if (kind == 'm') "mv" else "ln";
}
fn bad(kind: u8, arg: []const u8) u8 {
    u.errf("{s}: invalid argument: {s}\n", .{ command(kind), arg });
    return 1;
}
