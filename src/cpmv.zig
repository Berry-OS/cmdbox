// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// cp, mv, ln - GNU coreutils semantics (backups, preserve, parents, sparse, update, verbose, ...)
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");

const HELP: u8 = 200;
const VERSION: u8 = 201;

const Backup = enum { none, numbered, existing, simple };
const Update = enum { all, older, none, none_fail };
const Sparse = enum { auto, always, never };
const Reflink = enum { never, auto, always };
const Deref = enum { undef, never, cmd, always };

const Ctx = struct {
    prog: []const u8 = "cp",
    recursive: bool = false,
    deref: Deref = .undef,
    p_mode: bool = false,
    p_own: bool = false,
    p_time: bool = false,
    p_links: bool = false,
    force: bool = false,
    interactive: bool = false,
    noclobber: bool = false,
    update: Update = .all,
    verbose: bool = false,
    hardlink: bool = false,
    symlink: bool = false,
    backup: Backup = .none,
    suffix: []const u8 = "~",
    one_fs: bool = false,
    remove_dest: bool = false,
    sparse: Sparse = .auto,
    reflink: Reflink = .never,
    attrs_only: bool = false,
    parents: bool = false,
    copy_contents: bool = false,
    strip_slashes: bool = false,
    moving: bool = false,
    failed: bool = false,
    links: u.Vec(LinkRec) = undefined,
    dirs: u.Vec(u.Stat) = undefined,
    dst_dirs: u.Vec(u.Stat) = undefined,
    cmd_dev: u64 = 0,
    umask_v: u32 = 0,
    mv_prefix: bool = false,
};

const LinkRec = struct { dev: u64, ino: u64, dst: []const u8 };

fn err(ctx: *Ctx, comptime fmt: []const u8, args: anytype) void {
    u.errf("{s}: " ++ fmt ++ "\n", .{ctx.prog} ++ args);
    ctx.failed = true;
}

fn esc(en: linux.E) []const u8 {
    return u.strerr(en);
}

fn isTty(fd: i32) bool {
    var t: [64]u8 = undefined;
    return u.ok(linux.ioctl(fd, 0x5401, @intFromPtr(&t)));
}

fn confirm(ctx: *Ctx, comptime what: []const u8, path: []const u8) bool {
    u.errf("{s}: " ++ what ++ " '{s}'? ", .{ ctx.prog, path });
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        var b: [1]u8 = undefined;
        const r = linux.read(0, &b, 1);
        if (!u.ok(r) or r == 0) break;
        if (n == 0) buf[0] = b[0];
        n += 1;
        if (b[0] == '\n') break;
    }
    return n > 0 and (buf[0] == 'y' or buf[0] == 'Y');
}

fn joinPath(dir: []const u8, name: []const u8) []const u8 {
    if (dir.len == 0) return name;
    if (std.mem.endsWith(u8, dir, "/")) return std.fmt.allocPrint(u.alloc, "{s}{s}", .{ dir, name }) catch name;
    return std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ dir, name }) catch name;
}

fn baseName(p: []const u8) []const u8 {
    var s = p;
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| {
        if (s.len == 1) return s;
        return s[i + 1 ..];
    }
    return s;
}

fn stripSlashes(p: []const u8) []const u8 {
    var s = p;
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    return s;
}

fn sameFile(a: u.Stat, b: u.Stat) bool {
    return a.dev == b.dev and a.ino == b.ino;
}

fn isDirSt(st: u.Stat) bool {
    return st.mode & linux.S.IFMT == linux.S.IFDIR;
}

// ---------- backups ----------
fn parseBackup(v: []const u8) ?Backup {
    const e = std.mem.eql;
    if (e(u8, v, "none") or e(u8, v, "off")) return .none;
    if (e(u8, v, "numbered") or e(u8, v, "t")) return .numbered;
    if (e(u8, v, "existing") or e(u8, v, "nil")) return .existing;
    if (e(u8, v, "simple") or e(u8, v, "never")) return .simple;
    return null;
}

fn numberedName(path: []const u8, n: u64) []const u8 {
    return std.fmt.allocPrint(u.alloc, "{s}.~{d}~", .{ path, n }) catch path;
}

fn backupPath(ctx: *Ctx, path: []const u8) ?[]const u8 {
    var kind = ctx.backup;
    if (kind == .none) return null;
    const dir = std.fs.path.dirname(path) orelse ".";
    const base = baseName(path);
    var maxn: u64 = 0;
    var have_numbered = false;
    if (kind == .numbered or kind == .existing) {
        var ents = u.Vec(u.DirEnt).init(u.alloc);
        if (u.listDir(dir, &ents)) {
            const prefix = std.fmt.allocPrint(u.alloc, "{s}.~", .{base}) catch return null;
            for (ents.items) |e| {
                const nm: []const u8 = e.name;
                if (std.mem.startsWith(u8, nm, prefix) and std.mem.endsWith(u8, nm, "~") and nm.len > prefix.len + 1) {
                    const num = nm[prefix.len .. nm.len - 1];
                    if (std.fmt.parseInt(u64, num, 10)) |v| {
                        have_numbered = true;
                        maxn = @max(maxn, v);
                    } else |_| {}
                }
            }
        }
        if (kind == .existing) kind = if (have_numbered) .numbered else .simple;
    }
    if (kind == .numbered) return numberedName(path, maxn + 1);
    return std.fmt.allocPrint(u.alloc, "{s}{s}", .{ path, ctx.suffix }) catch null;
}

// ---------- file data ----------
fn copyData(ctx: *Ctx, src_fd: i32, dst_fd: i32, st: u.Stat, dst_regular: bool) bool {
    if (ctx.attrs_only) return true;
    if (ctx.reflink != .never and dst_regular) {
        const rc = linux.ioctl(dst_fd, 0x40049409, @intCast(src_fd)); // FICLONE
        if (u.ok(rc)) return true;
        if (ctx.reflink == .always) return false;
    }
    const sparse = dst_regular and (ctx.sparse == .always or (ctx.sparse == .auto and st.blocks * 512 < st.size and st.size > 0));
    var buf: [65536]u8 = undefined;
    var total: u64 = 0;
    var pending_hole: u64 = 0;
    while (true) {
        const r = linux.read(src_fd, &buf, buf.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r)) return false;
        if (r == 0) break;
        var off: usize = 0;
        if (sparse) {
            // skip all-zero 4K blocks
            while (off < r) {
                const n = @min(4096, r - off);
                const blk = buf[off .. off + n];
                var zero = true;
                for (blk) |b| if (b != 0) {
                    zero = false;
                    break;
                };
                if (zero) {
                    pending_hole += n;
                } else {
                    if (pending_hole > 0) {
                        _ = linux.syscall3(.lseek, @as(usize, @intCast(dst_fd)), @intCast(pending_hole), 1);
                        pending_hole = 0;
                    }
                    if (!writeAll(dst_fd, blk)) return false;
                }
                off += n;
            }
        } else if (!writeAll(dst_fd, buf[0..r])) return false;
        total += r;
    }
    if (sparse and pending_hole > 0) {
        _ = linux.syscall3(.lseek, @as(usize, @intCast(dst_fd)), @intCast(pending_hole), 1);
        _ = linux.syscall2(.ftruncate, @as(usize, @intCast(dst_fd)), @intCast(total));
    }
    return true;
}

fn writeAll(fd: i32, data: []const u8) bool {
    var n: usize = 0;
    while (n < data.len) {
        const r = linux.write(fd, data.ptr + n, data.len - n);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r) or r == 0) return false;
        n += r;
    }
    return true;
}

const Time64 = extern struct { sec: i64, nsec: i64 };

fn setTimesFd(fd: i32, st: u.Stat) void {
    const times = [_]Time64{ .{ .sec = st.atime, .nsec = st.atime_nsec }, .{ .sec = st.mtime, .nsec = st.mtime_nsec } };
    const sys: linux.SYS = if (@sizeOf(usize) == 4) .utimensat_time64 else .utimensat;
    _ = linux.syscall4(sys, @as(usize, @intCast(fd)), 0, @intFromPtr(&times), 0);
}

fn setTimesPath(path: []const u8, st: u.Stat, follow: bool) void {
    const times = [_]Time64{ .{ .sec = st.atime, .nsec = st.atime_nsec }, .{ .sec = st.mtime, .nsec = st.mtime_nsec } };
    const sys: linux.SYS = if (@sizeOf(usize) == 4) .utimensat_time64 else .utimensat;
    _ = linux.syscall4(sys, @bitCast(@as(isize, std.posix.AT.FDCWD)), @intFromPtr(u.zstr(path).ptr), @intFromPtr(&times), if (follow) 0 else 0x100);
}

fn applyAttrsFd(ctx: *Ctx, fd: i32, st: u.Stat, created: bool) void {
    if (ctx.p_own) {
        const rc = linux.fchown(fd, st.uid, st.gid);
        if (!u.ok(rc) and !u.ok(linux.fchown(fd, std.math.maxInt(u32), st.gid))) {}
    }
    if (ctx.p_mode) {
        _ = linux.fchmod(fd, st.mode & 0o7777);
    } else if (created) {
        // new file: setuid/setgid are never copied implicitly
    }
    if (ctx.p_time) setTimesFd(fd, st);
}

// ---------- the copy itself ----------
fn verboseMsg(ctx: *Ctx, src: []const u8, dst: []const u8, backup: ?[]const u8) void {
    if (!ctx.verbose) return;
    if (ctx.moving) {
        if (backup) |b| u.outf("renamed '{s}' -> '{s}' (backup: '{s}')\n", .{ src, dst, b }) else u.outf("renamed '{s}' -> '{s}'\n", .{ src, dst });
        return;
    }
    if (backup) |b| u.outf("'{s}' -> '{s}' (backup: '{s}')\n", .{ src, dst, b }) else u.outf("'{s}' -> '{s}'\n", .{ src, dst });
}

fn removeDestFile(ctx: *Ctx, dst: []const u8) bool {
    const rc = linux.unlink(u.zstr(dst));
    if (!u.ok(rc)) {
        err(ctx, "cannot remove '{s}': {s}", .{ dst, esc(u.errno(rc)) });
        return false;
    }
    return true;
}

fn copyTop(ctx: *Ctx, src: []const u8, dst: []const u8, top: bool, from_dir_dev: u64) bool {
    const follow = switch (ctx.deref) {
        .always => true,
        .cmd => top,
        .never => false,
        .undef => !ctx.recursive,
    };
    var st = u.stat(src, follow) orelse {
        // dangling symlink with deref: report like GNU
        err(ctx, "cannot stat '{s}': {s}", .{ src, esc(u.errno(linux.statx(std.posix.AT.FDCWD, u.zstr(src), if (follow) 0 else 0x100, .{ .MODE = true }, undefined))) });
        return false;
    };
    if (ctx.one_fs and !top and st.dev != from_dir_dev and isDirSt(st)) return true;
    const typ = st.mode & linux.S.IFMT;
    const dst_lst = u.stat(dst, false);

    // same file?
    if (dst_lst) |d| {
        const dfollow = u.stat(dst, true);
        if (dfollow != null and sameFile(st, dfollow.?) and !isDirSt(st)) {
            if (!(ctx.backup != .none and !ctx.moving) or true) {
                if (ctx.backup == .none or ctx.remove_dest or ctx.moving) {
                    err(ctx, "'{s}' and '{s}' are the same file", .{ src, dst });
                    return false;
                }
            }
        }
        _ = d;
    }

    if (typ == linux.S.IFDIR) return copyDir(ctx, src, dst, st, dst_lst, top);

    // destination exists
    var backup_name: ?[]const u8 = null;
    if (dst_lst) |d| {
        if (isDirSt(d)) {
            err(ctx, "cannot overwrite directory '{s}' with non-directory", .{dst});
            return false;
        }
        if (ctx.update == .none) return true;
        if (ctx.update == .none_fail) {
            err(ctx, "not replacing '{s}'", .{dst});
            return false;
        }
        if (ctx.noclobber) return true;
        if (ctx.update == .older) {
            const newer = st.mtime > d.mtime or (st.mtime == d.mtime and st.mtime_nsec > d.mtime_nsec);
            if (!newer) return true;
        }
        if (ctx.interactive and !confirm(ctx, "overwrite", dst)) {
            ctx.failed = true;
            return true;
        }
        if (ctx.backup != .none) {
            backup_name = backupPath(ctx, dst);
            if (backup_name) |b| {
                const rc = linux.rename(u.zstr(dst), u.zstr(b));
                if (!u.ok(rc)) {
                    err(ctx, "cannot backup '{s}': {s}", .{ dst, esc(u.errno(rc)) });
                    return false;
                }
            }
        } else if (ctx.remove_dest) {
            if (!removeDestFile(ctx, dst)) return false;
        }
    }

    // hard link tracking (--preserve=links)
    if (ctx.p_links and st.nlink > 1 and typ != linux.S.IFDIR) {
        for (ctx.links.items) |l| if (l.dev == st.dev and l.ino == st.ino) {
            if (u.stat(dst, false) != null) _ = linux.unlink(u.zstr(dst));
            const rc = linux.link(u.zstr(l.dst), u.zstr(dst));
            if (!u.ok(rc)) {
                err(ctx, "cannot create hard link '{s}' to '{s}': {s}", .{ dst, l.dst, esc(u.errno(rc)) });
                return false;
            }
            verboseMsg(ctx, src, dst, backup_name);
            return true;
        };
    }

    if (ctx.symlink and typ != linux.S.IFLNK) return makeSymlinkCopy(ctx, src, dst, backup_name);
    if (ctx.hardlink) {
        if (u.stat(dst, false) != null) _ = linux.unlink(u.zstr(dst));
        const lflags: usize = if (ctx.deref == .never) 0 else 0x400; // AT_SYMLINK_FOLLOW
        const rc = linux.syscall5(.linkat, @bitCast(@as(isize, std.posix.AT.FDCWD)), @intFromPtr(u.zstr(src).ptr), @bitCast(@as(isize, std.posix.AT.FDCWD)), @intFromPtr(u.zstr(dst).ptr), lflags);
        if (!u.ok(rc)) {
            err(ctx, "cannot create hard link '{s}' to '{s}': {s}", .{ dst, src, esc(u.errno(rc)) });
            return false;
        }
        trackLink(ctx, st, dst);
        verboseMsg(ctx, src, dst, backup_name);
        return true;
    }

    switch (typ) {
        linux.S.IFLNK => {
            var buf: [u.PATH_MAX]u8 = undefined;
            const rl = linux.readlink(u.zstr(src), &buf, buf.len);
            if (!u.ok(rl)) {
                err(ctx, "cannot read symbolic link '{s}': {s}", .{ src, esc(u.errno(rl)) });
                return false;
            }
            if (dst_lst != null and backup_name == null) {
                if (!ctx.force and !ctx.remove_dest and !ctx.moving and !ctx.interactive) {
                    // GNU replaces an existing destination with the link
                }
                _ = linux.unlink(u.zstr(dst));
            }
            const rc = linux.symlink(u.zstr(buf[0..rl]), u.zstr(dst));
            if (!u.ok(rc)) {
                err(ctx, "cannot create symbolic link '{s}': {s}", .{ dst, esc(u.errno(rc)) });
                return false;
            }
            if (ctx.p_own) _ = linux.syscall5(.fchownat, @bitCast(@as(isize, std.posix.AT.FDCWD)), @intFromPtr(u.zstr(dst).ptr), st.uid, st.gid, 0x100);
            if (ctx.p_time) setTimesPath(dst, st, false);
            verboseMsg(ctx, src, dst, backup_name);
            return true;
        },
        linux.S.IFIFO => {
            if (ctx.recursive and !ctx.copy_contents) {
                if (dst_lst != null and backup_name == null) _ = linux.unlink(u.zstr(dst));
                const rc = linux.mknod(u.zstr(dst), linux.S.IFIFO | (st.mode & 0o777 & ~ctx.umask_v), 0);
                if (!u.ok(rc)) {
                    err(ctx, "cannot create fifo '{s}': {s}", .{ dst, esc(u.errno(rc)) });
                    return false;
                }
                finishSpecial(ctx, dst, st);
                verboseMsg(ctx, src, dst, backup_name);
                return true;
            }
        },
        linux.S.IFCHR, linux.S.IFBLK => {
            if (ctx.recursive and !ctx.copy_contents) {
                if (dst_lst != null and backup_name == null) _ = linux.unlink(u.zstr(dst));
                const rc = linux.mknod(u.zstr(dst), (st.mode & linux.S.IFMT) | (st.mode & 0o777 & ~ctx.umask_v), @truncate(st.rdev));
                if (!u.ok(rc)) {
                    err(ctx, "cannot create special file '{s}': {s}", .{ dst, esc(u.errno(rc)) });
                    return false;
                }
                finishSpecial(ctx, dst, st);
                verboseMsg(ctx, src, dst, backup_name);
                return true;
            }
        },
        linux.S.IFSOCK => {
            if (ctx.recursive) {
                err(ctx, "cannot create socket '{s}': Operation not supported", .{dst});
                return false;
            }
        },
        else => {},
    }

    // regular file (or special file copied by contents)
    const sfd_rc = linux.open(u.zstr(src), .{ .ACCMODE = .RDONLY, .NOCTTY = true }, 0);
    if (!u.ok(sfd_rc)) {
        err(ctx, "cannot open '{s}' for reading: {s}", .{ src, esc(u.errno(sfd_rc)) });
        return false;
    }
    const sfd: i32 = @intCast(sfd_rc);
    defer _ = linux.close(sfd);
    // fstat to guard against races
    st = u.statFd(sfd) orelse st;

    const mode_bits: u32 = (st.mode & 0o777) & ~ctx.umask_v;
    var created = false;
    var dfd_rc = linux.open(u.zstr(dst), .{ .ACCMODE = .WRONLY, .TRUNC = true, .NOCTTY = true }, 0);
    if (!u.ok(dfd_rc)) {
        const en = u.errno(dfd_rc);
        if (en == .NOENT) {
            const cmode: u32 = if (ctx.p_mode) (st.mode & 0o777) & ~@as(u32, 0) else mode_bits;
            dfd_rc = linux.open(u.zstr(dst), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOCTTY = true }, cmode);
            created = true;
        } else if (ctx.force and (en == .ACCES or en == .PERM or en == .TXTBSY or en == .ISDIR)) {
            if (!removeDestFile(ctx, dst)) return false;
            dfd_rc = linux.open(u.zstr(dst), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOCTTY = true }, mode_bits);
            created = true;
        }
    }
    if (!u.ok(dfd_rc)) {
        err(ctx, "cannot create regular file '{s}': {s}", .{ dst, esc(u.errno(dfd_rc)) });
        return false;
    }
    const dfd: i32 = @intCast(dfd_rc);
    defer _ = linux.close(dfd);
    const dst_st = u.statFd(dfd);
    const dst_regular = dst_st != null and dst_st.?.mode & linux.S.IFMT == linux.S.IFREG;
    if (ctx.attrs_only and !created) {
        // keep existing contents untouched
    }
    if (!copyData(ctx, sfd, dfd, st, dst_regular)) {
        if (ctx.reflink == .always) err(ctx, "failed to clone '{s}' from '{s}': Operation not supported", .{ dst, src }) else err(ctx, "error reading or writing '{s}'", .{src});
        return false;
    }
    if (ctx.p_mode and created) {} else if (created and !ctx.p_mode) {}
    applyAttrsFd(ctx, dfd, st, created);
    if (created and !ctx.p_mode) {
        // honour the umask exactly (open() already applied it)
    }
    trackLink(ctx, st, dst);
    verboseMsg(ctx, src, dst, backup_name);
    return true;
}

fn finishSpecial(ctx: *Ctx, dst: []const u8, st: u.Stat) void {
    if (ctx.p_own) _ = linux.syscall5(.fchownat, @bitCast(@as(isize, std.posix.AT.FDCWD)), @intFromPtr(u.zstr(dst).ptr), st.uid, st.gid, 0x100);
    if (ctx.p_mode) _ = linux.chmod(u.zstr(dst), st.mode & 0o7777);
    if (ctx.p_time) setTimesPath(dst, st, true);
}

fn trackLink(ctx: *Ctx, st: u.Stat, dst: []const u8) void {
    if (ctx.p_links and st.nlink > 1) ctx.links.push(.{ .dev = st.dev, .ino = st.ino, .dst = u.alloc.dupe(u8, dst) catch dst });
}

fn makeSymlinkCopy(ctx: *Ctx, src: []const u8, dst: []const u8, backup_name: ?[]const u8) bool {
    if (src.len == 0 or (src[0] != '/' and std.mem.indexOfScalar(u8, dst, '/') != null and std.fs.path.dirname(dst) != null and !std.mem.eql(u8, std.fs.path.dirname(dst).?, "."))) {
        err(ctx, "'{s}': can make relative symbolic links only in current directory", .{src});
        return false;
    }
    if (u.stat(dst, false) != null) _ = linux.unlink(u.zstr(dst));
    const rc = linux.symlink(u.zstr(src), u.zstr(dst));
    if (!u.ok(rc)) {
        err(ctx, "cannot create symbolic link '{s}' to '{s}': {s}", .{ dst, src, esc(u.errno(rc)) });
        return false;
    }
    verboseMsg(ctx, src, dst, backup_name);
    return true;
}

/// is `dst` (or, when it does not exist yet, its parent chain) the directory `st` or inside it?
fn destInside(dst: []const u8, dst_lst: ?u.Stat, st: u.Stat) bool {
    var cur: []const u8 = dst;
    if (dst_lst == null) cur = std.fs.path.dirname(dst) orelse ".";
    if (cur.len == 0) cur = ".";
    var n: usize = 0;
    while (n < 256) : (n += 1) {
        const s = u.stat(cur, true) orelse return false;
        if (sameFile(s, st)) return true;
        const up = std.fmt.allocPrint(u.alloc, "{s}/..", .{cur}) catch return false;
        const ps = u.stat(up, true) orelse return false;
        if (sameFile(ps, s)) return false;
        cur = up;
    }
    return false;
}

fn copyDir(ctx: *Ctx, src: []const u8, dst: []const u8, st: u.Stat, dst_lst: ?u.Stat, top: bool) bool {
    if (!ctx.recursive) {
        err(ctx, "-r not specified; omitting directory '{s}'", .{src});
        return false;
    }
    // copying a directory into itself
    for (ctx.dirs.items) |a| if (sameFile(a, st)) {
        err(ctx, "cannot copy a directory, '{s}', into itself, '{s}'", .{ src, dst });
        return false;
    };
    for (ctx.dst_dirs.items) |a| if (sameFile(a, st)) {
        err(ctx, "cannot copy a directory, '{s}', into itself, '{s}'", .{ src, dst });
        return false;
    };
    if (dst_lst) |d| {
        if (sameFile(d, st) and top) {
            err(ctx, "cannot copy a directory, '{s}', into itself, '{s}'", .{ src, dst });
            return false;
        }
        if (!isDirSt(d)) {
            err(ctx, "cannot overwrite non-directory '{s}' with directory '{s}'", .{ dst, src });
            return false;
        }
    } else {
        // create with owner-write so we can fill it, final mode applied afterwards
        const cmode: u32 = ((st.mode & 0o777) & ~ctx.umask_v) | 0o700;
        const rc = linux.mkdir(u.zstr(dst), cmode);
        if (!u.ok(rc)) {
            err(ctx, "cannot create directory '{s}': {s}", .{ dst, esc(u.errno(rc)) });
            return false;
        }
        verboseMsg(ctx, src, dst, null);
    }
    ctx.dirs.push(st);
    defer ctx.dirs.pop();
    if (u.stat(dst, true)) |ds| ctx.dst_dirs.push(ds) else ctx.dst_dirs.push(st);
    defer ctx.dst_dirs.pop();
    var ok = true;
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir(src, &ents)) {
        err(ctx, "cannot access '{s}': Permission denied", .{src});
        ok = false;
    } else for (ents.items) |e| {
        const nm: []const u8 = e.name;
        if (!copyTop(ctx, joinPath(src, nm), joinPath(dst, nm), false, st.dev)) ok = false;
    }
    // final attributes
    if (dst_lst == null or ctx.p_mode or ctx.p_own or ctx.p_time) {
        if (ctx.p_own) _ = linux.syscall5(.fchownat, @bitCast(@as(isize, std.posix.AT.FDCWD)), @intFromPtr(u.zstr(dst).ptr), st.uid, st.gid, 0);
        if (ctx.p_mode) {
            _ = linux.chmod(u.zstr(dst), st.mode & 0o7777);
        } else if (dst_lst == null) {
            _ = linux.chmod(u.zstr(dst), (st.mode & 0o777) & ~ctx.umask_v);
        }
        if (ctx.p_time) setTimesPath(dst, st, true);
    }
    return ok;
}

fn parsePreserve(ctx: *Ctx, list: []const u8, on: bool) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "mode")) ctx.p_mode = on else if (std.mem.eql(u8, a, "ownership")) ctx.p_own = on else if (std.mem.eql(u8, a, "timestamps")) ctx.p_time = on else if (std.mem.eql(u8, a, "links")) ctx.p_links = on else if (std.mem.eql(u8, a, "context") or std.mem.eql(u8, a, "xattr")) {} else if (std.mem.eql(u8, a, "all")) {
            ctx.p_mode = on;
            ctx.p_own = on;
            ctx.p_time = on;
            ctx.p_links = on;
        } else {
            u.errf("{s}: invalid argument '{s}' for '--preserve'\nValid arguments are:\n  - 'mode'\n  - 'ownership'\n  - 'timestamps'\n  - 'links'\n  - 'context'\n  - 'xattr'\n  - 'all'\nTry '{s} --help' for more information.\n", .{ ctx.prog, a, ctx.prog });
            return false;
        }
    }
    return true;
}

fn newCtx(prog: []const u8) Ctx {
    var c = Ctx{ .prog = prog };
    c.links = u.Vec(LinkRec).init(u.alloc);
    c.dirs = u.Vec(u.Stat).init(u.alloc);
    c.dst_dirs = u.Vec(u.Stat).init(u.alloc);
    const um = u.umask(0);
    _ = u.umask(um);
    c.umask_v = um;
    if (u.getEnv("VERSION_CONTROL")) |_| {}
    if (u.getEnv("SIMPLE_BACKUP_SUFFIX")) |sx| c.suffix = sx;
    return c;
}

fn parseUpdate(ctx: *Ctx, v: []const u8) bool {
    if (std.mem.eql(u8, v, "all")) ctx.update = .all else if (std.mem.eql(u8, v, "older")) ctx.update = .older else if (std.mem.eql(u8, v, "none")) ctx.update = .none else if (std.mem.eql(u8, v, "none-fail")) ctx.update = .none_fail else {
        u.errf("{s}: invalid argument '{s}' for '--update'\nValid arguments are:\n  - 'all'\n  - 'none'\n  - 'none-fail'\n  - 'older'\nTry '{s} --help' for more information.\n", .{ ctx.prog, v, ctx.prog });
        return false;
    }
    return true;
}

// ===================== cp =====================
pub fn cp(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "archive", .key = 'a' },
        .{ .name = "attributes-only", .key = 130 },
        .{ .name = "backup", .key = 131, .arg = .opt },
        .{ .key = 'b' },
        .{ .name = "copy-contents", .key = 132 },
        .{ .key = 'd' },
        .{ .name = "force", .key = 'f' },
        .{ .name = "interactive", .key = 'i' },
        .{ .name = "dereference-command-line", .key = 'H' },
        .{ .name = "link", .key = 'l' },
        .{ .name = "dereference", .key = 'L' },
        .{ .name = "no-clobber", .key = 'n' },
        .{ .name = "no-dereference", .key = 'P' },
        .{ .key = 'p' },
        .{ .name = "preserve", .key = 133, .arg = .opt },
        .{ .name = "no-preserve", .key = 134, .arg = .req },
        .{ .name = "parents", .key = 135 },
        .{ .name = "recursive", .key = 'R' },
        .{ .key = 'r' },
        .{ .name = "reflink", .key = 136, .arg = .opt },
        .{ .name = "remove-destination", .key = 137 },
        .{ .name = "sparse", .key = 138, .arg = .req },
        .{ .name = "strip-trailing-slashes", .key = 139 },
        .{ .name = "symbolic-link", .key = 's' },
        .{ .name = "suffix", .key = 'S', .arg = .req },
        .{ .name = "target-directory", .key = 't', .arg = .req },
        .{ .name = "no-target-directory", .key = 'T' },
        .{ .name = "update", .key = 140, .arg = .opt },
        .{ .key = 'u' },
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "one-file-system", .key = 'x' },
        .{ .name = "context", .key = 'Z', .arg = .opt },
        .{ .name = "help", .key = HELP },
        .{ .name = "version", .key = VERSION },
    };
    var ctx = newCtx("cp");
    var p = g.Parser.init("cp", args, &opts);
    var target_dir: ?[]const u8 = null;
    var no_target = false;
    var backup_set = false;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'a' => {
                ctx.recursive = true;
                ctx.deref = .never;
                _ = parsePreserve(&ctx, "all", true);
            },
            130 => ctx.attrs_only = true,
            131 => {
                backup_set = true;
                ctx.backup = if (it.val) |v| (parseBackup(v) orelse {
                    u.errf("cp: invalid argument '{s}' for 'backup type'\nTry 'cp --help' for more information.\n", .{v});
                    return 1;
                }) else .existing;
            },
            'b' => {
                if (!backup_set) ctx.backup = .existing;
                backup_set = true;
            },
            132 => ctx.copy_contents = true,
            'd' => {
                ctx.deref = .never;
                ctx.p_links = true;
            },
            'f' => ctx.force = true,
            'i' => {
                ctx.interactive = true;
                ctx.noclobber = false;
            },
            'H' => ctx.deref = .cmd,
            'l' => ctx.hardlink = true,
            'L' => ctx.deref = .always,
            'n' => {
                ctx.noclobber = true;
                ctx.interactive = false;
            },
            'P' => ctx.deref = .never,
            'p' => {
                ctx.p_mode = true;
                ctx.p_own = true;
                ctx.p_time = true;
            },
            133 => {
                if (it.val) |v| {
                    if (!parsePreserve(&ctx, v, true)) return 1;
                } else {
                    ctx.p_mode = true;
                    ctx.p_own = true;
                    ctx.p_time = true;
                }
            },
            134 => if (!parsePreserve(&ctx, it.val.?, false)) return 1,
            135 => ctx.parents = true,
            'R', 'r' => ctx.recursive = true,
            136 => {
                const v = it.val orelse "always";
                if (std.mem.eql(u8, v, "always")) ctx.reflink = .always else if (std.mem.eql(u8, v, "auto")) ctx.reflink = .auto else if (std.mem.eql(u8, v, "never")) ctx.reflink = .never else {
                    u.errf("cp: invalid argument '{s}' for '--reflink'\nTry 'cp --help' for more information.\n", .{v});
                    return 1;
                }
            },
            137 => {
                ctx.remove_dest = true;
                ctx.force = true;
            },
            138 => {
                const v = it.val.?;
                if (std.mem.eql(u8, v, "auto")) ctx.sparse = .auto else if (std.mem.eql(u8, v, "always")) ctx.sparse = .always else if (std.mem.eql(u8, v, "never")) ctx.sparse = .never else {
                    u.errf("cp: invalid argument '{s}' for '--sparse'\nTry 'cp --help' for more information.\n", .{v});
                    return 1;
                }
            },
            139 => ctx.strip_slashes = true,
            's' => ctx.symlink = true,
            'S' => {
                ctx.suffix = it.val.?;
                if (!backup_set) {
                    ctx.backup = .existing;
                    backup_set = true;
                }
            },
            't' => target_dir = it.val,
            'T' => no_target = true,
            140 => if (!parseUpdate(&ctx, it.val orelse "older")) return 1,
            'u' => ctx.update = .older,
            'v' => ctx.verbose = true,
            'x' => ctx.one_fs = true,
            'Z' => {},
            HELP => {
                u.out("Usage: cp [OPTION]... [-T] SOURCE DEST\n  or:  cp [OPTION]... SOURCE... DIRECTORY\n  or:  cp [OPTION]... -t DIRECTORY SOURCE...\nCopy SOURCE to DEST, or multiple SOURCE(s) to DIRECTORY.\n");
                return 0;
            },
            VERSION => {
                u.out("cp (cmdbox)\n");
                return 0;
            },
            else => {},
        }
    }
    if (backup_set and ctx.backup == .none and false) {}
    if (u.getEnv("VERSION_CONTROL")) |vc| {
        if (ctx.backup == .existing and !backup_set) _ = vc;
    }
    var ops = p.operands.items;
    if (target_dir != null and no_target) {
        u.err("cp: cannot combine --target-directory (-t) and --no-target-directory (-T)\n");
        return 1;
    }
    if (ops.len == 0) {
        u.err("cp: missing file operand\nTry 'cp --help' for more information.\n");
        return 1;
    }
    var dest: []const u8 = undefined;
    var into_dir = false;
    if (target_dir) |t| {
        dest = t;
        into_dir = true;
        if (!u.isDir(t)) {
            u.errf("cp: target '{s}' is not a directory\n", .{t});
            return 1;
        }
    } else {
        if (ops.len == 1) {
            u.errf("cp: missing destination file operand after '{s}'\nTry 'cp --help' for more information.\n", .{ops[0]});
            return 1;
        }
        dest = ops[ops.len - 1];
        ops = ops[0 .. ops.len - 1];
        if (!no_target and (u.isDir(dest) or ctx.parents)) into_dir = true;
        if (ctx.parents and !u.isDir(dest)) {
            u.errf("cp: target '{s}' is not a directory\n", .{dest});
            return 1;
        }
        if (!into_dir and ops.len > 1) {
            u.errf("cp: target '{s}' is not a directory\n", .{dest});
            return 1;
        }
    }
    for (ops) |src0| {
        const src = if (ctx.strip_slashes) stripSlashes(src0) else src0;
        var dst: []const u8 = dest;
        if (into_dir) {
            if (ctx.parents) {
                // dest/<full source path>
                var rel = src;
                while (rel.len > 0 and rel[0] == '/') rel = rel[1..];
                dst = joinPath(dest, rel);
                if (std.fs.path.dirname(rel)) |dirpart| {
                    if (!makeParents(&ctx, src, dest, dirpart)) continue;
                }
            } else dst = joinPath(dest, baseName(src));
        }
        _ = copyTop(&ctx, src, dst, true, 0);
    }
    return if (ctx.failed) 1 else 0;
}

fn makeParents(ctx: *Ctx, src: []const u8, dest: []const u8, dirpart: []const u8) bool {
    // create dest/a/b for source a/b/file, copying the directory modes
    var it = std.mem.tokenizeScalar(u8, dirpart, '/');
    var cur = u.Vec(u8).init(u.alloc);
    var srcpath = u.Vec(u8).init(u.alloc);
    if (src.len > 0 and src[0] == '/') srcpath.push('/');
    while (it.next()) |comp| {
        if (cur.items.len > 0) cur.push('/');
        cur.pushSlice(comp);
        if (srcpath.items.len > 0 and srcpath.items[srcpath.items.len - 1] != '/') srcpath.push('/');
        srcpath.pushSlice(comp);
        const target = joinPath(dest, cur.items);
        if (u.stat(target, true) == null) {
            const sst = u.stat(srcpath.items, true);
            const mode: u32 = if (sst) |s| (s.mode & 0o777) & ~ctx.umask_v else 0o777 & ~ctx.umask_v;
            const rc = linux.mkdir(u.zstr(target), mode | 0o300);
            if (!u.ok(rc)) {
                err(ctx, "cannot make directory '{s}': {s}", .{ target, esc(u.errno(rc)) });
                return false;
            }
            if (ctx.verbose) u.outf("{s} -> {s}\n", .{ srcpath.items, target });
        }
    }
    return true;
}

// ===================== mv =====================
fn removeTree(path: []const u8) bool {
    const st = u.stat(path, false) orelse return true;
    if (st.mode & linux.S.IFMT == linux.S.IFDIR) {
        var ents = u.Vec(u.DirEnt).init(u.alloc);
        if (u.listDir(path, &ents)) for (ents.items) |e| {
            if (!removeTree(joinPath(path, e.name))) return false;
        };
        return u.ok(linux.rmdir(u.zstr(path)));
    }
    return u.ok(linux.unlink(u.zstr(path)));
}

pub fn mv(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "backup", .key = 131, .arg = .opt },
        .{ .key = 'b' },
        .{ .name = "force", .key = 'f' },
        .{ .name = "interactive", .key = 'i' },
        .{ .name = "no-clobber", .key = 'n' },
        .{ .name = "strip-trailing-slashes", .key = 139 },
        .{ .name = "suffix", .key = 'S', .arg = .req },
        .{ .name = "target-directory", .key = 't', .arg = .req },
        .{ .name = "no-target-directory", .key = 'T' },
        .{ .name = "update", .key = 140, .arg = .opt },
        .{ .key = 'u' },
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "context", .key = 'Z' },
        .{ .name = "help", .key = HELP },
        .{ .name = "version", .key = VERSION },
    };
    var ctx = newCtx("mv");
    ctx.moving = true;
    var p = g.Parser.init("mv", args, &opts);
    var target_dir: ?[]const u8 = null;
    var no_target = false;
    var backup_set = false;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            131 => {
                backup_set = true;
                ctx.backup = if (it.val) |v| (parseBackup(v) orelse {
                    u.errf("mv: invalid argument '{s}' for 'backup type'\nTry 'mv --help' for more information.\n", .{v});
                    return 1;
                }) else .existing;
            },
            'b' => {
                if (!backup_set) ctx.backup = .existing;
                backup_set = true;
            },
            'f' => {
                ctx.force = true;
                ctx.interactive = false;
                ctx.noclobber = false;
            },
            'i' => {
                ctx.interactive = true;
                ctx.force = false;
                ctx.noclobber = false;
            },
            'n' => {
                ctx.noclobber = true;
                ctx.interactive = false;
                ctx.force = false;
            },
            139 => ctx.strip_slashes = true,
            'S' => {
                ctx.suffix = it.val.?;
                if (!backup_set) {
                    ctx.backup = .existing;
                    backup_set = true;
                }
            },
            't' => target_dir = it.val,
            'T' => no_target = true,
            140 => if (!parseUpdate(&ctx, it.val orelse "older")) return 1,
            'u' => ctx.update = .older,
            'v' => ctx.verbose = true,
            'Z' => {},
            HELP => {
                u.out("Usage: mv [OPTION]... [-T] SOURCE DEST\n  or:  mv [OPTION]... SOURCE... DIRECTORY\n  or:  mv [OPTION]... -t DIRECTORY SOURCE...\nRename SOURCE to DEST, or move SOURCE(s) to DIRECTORY.\n");
                return 0;
            },
            VERSION => {
                u.out("mv (cmdbox)\n");
                return 0;
            },
            else => {},
        }
    }
    var ops = p.operands.items;
    if (target_dir != null and no_target) {
        u.err("mv: cannot combine --target-directory (-t) and --no-target-directory (-T)\n");
        return 1;
    }
    if (ops.len == 0) {
        u.err("mv: missing file operand\nTry 'mv --help' for more information.\n");
        return 1;
    }
    var dest: []const u8 = undefined;
    var into_dir = false;
    if (target_dir) |t| {
        dest = t;
        into_dir = true;
        if (!u.isDir(t)) {
            u.errf("mv: target directory '{s}' is not a directory\n", .{t});
            return 1;
        }
    } else {
        if (ops.len == 1) {
            u.errf("mv: missing destination file operand after '{s}'\nTry 'mv --help' for more information.\n", .{ops[0]});
            return 1;
        }
        dest = ops[ops.len - 1];
        ops = ops[0 .. ops.len - 1];
        if (!no_target and u.isDir(dest)) into_dir = true;
        if (!into_dir and ops.len > 1) {
            u.errf("mv: target '{s}' is not a directory\n", .{dest});
            return 1;
        }
    }
    for (ops) |src0| {
        const src = if (ctx.strip_slashes) stripSlashes(src0) else src0;
        const dst = if (into_dir) joinPath(dest, baseName(src)) else dest;
        moveOne(&ctx, src, dst);
    }
    return if (ctx.failed) 1 else 0;
}

fn moveOne(ctx: *Ctx, src: []const u8, dst: []const u8) void {
    const sst = u.stat(src, false) orelse {
        err(ctx, "cannot stat '{s}': No such file or directory", .{src});
        return;
    };
    const dst_lst = u.stat(dst, false);
    if (dst_lst) |d| {
        const dfollow = u.stat(dst, true) orelse d;
        const same = sameFile(sst, d) or (sst.mode & linux.S.IFMT != linux.S.IFLNK and sameFile(sst, dfollow));
        if (same) {
            // moving a hard link onto itself is a no-op error; same name too
            if (!(ctx.backup != .none and !std.mem.eql(u8, src, dst))) {
                err(ctx, "'{s}' and '{s}' are the same file", .{ src, dst });
                return;
            }
        }
        if (isDirSt(d) and !isDirSt(sst)) {
            err(ctx, "cannot overwrite directory '{s}' with non-directory", .{dst});
            return;
        }
        if (!isDirSt(d) and isDirSt(sst)) {
            err(ctx, "cannot overwrite non-directory '{s}' with directory '{s}'", .{ dst, src });
            return;
        }
        if (ctx.noclobber) return;
        if (ctx.update == .none) return;
        if (ctx.update == .none_fail) {
            err(ctx, "not replacing '{s}'", .{dst});
            return;
        }
        if (ctx.update == .older) {
            const newer = sst.mtime > d.mtime or (sst.mtime == d.mtime and sst.mtime_nsec > d.mtime_nsec);
            if (!newer) return;
        }
        if (ctx.interactive or (!ctx.force and false)) {
            if (!confirm(ctx, "overwrite", dst)) {
                ctx.failed = true;
                return;
            }
        } else if (!ctx.force and isTty(0) and d.mode & 0o200 == 0 and !isDirSt(d)) {
            u.errf("mv: replace '{s}', overriding mode {o:0>4} ({s})? ", .{ dst, d.mode & 0o7777, "-r--r--r--" });
            var b: [8]u8 = undefined;
            const n = linux.read(0, &b, 1);
            if (!u.ok(n) or n == 0 or (b[0] != 'y' and b[0] != 'Y')) return;
        }
    }
    // moving a directory into itself
    if (isDirSt(sst)) {
        const s = stripSlashes(src);
        if (std.mem.startsWith(u8, dst, s) and dst.len > s.len and dst[s.len] == '/') {
            err(ctx, "cannot move '{s}' to a subdirectory of itself, '{s}'", .{ src, dst });
            return;
        }
    }
    var backup_name: ?[]const u8 = null;
    if (dst_lst != null and ctx.backup != .none) {
        backup_name = backupPath(ctx, dst);
        if (backup_name) |b| {
            const rc = linux.rename(u.zstr(dst), u.zstr(b));
            if (!u.ok(rc)) {
                err(ctx, "cannot backup '{s}': {s}", .{ dst, esc(u.errno(rc)) });
                return;
            }
        }
    }
    const rc = linux.rename(u.zstr(src), u.zstr(dst));
    if (u.ok(rc)) {
        verboseMsg(ctx, src, dst, backup_name);
        return;
    }
    const en = u.errno(rc);
    if (en != .XDEV) {
        err(ctx, "cannot move '{s}' to '{s}': {s}", .{ src, dst, esc(en) });
        return;
    }
    // different file system: copy then remove
    var cc = newCtx("mv");
    cc.moving = false;
    cc.recursive = true;
    cc.deref = .never;
    cc.p_mode = true;
    cc.p_own = true;
    cc.p_time = true;
    cc.p_links = true;
    cc.verbose = false;
    cc.force = true;
    cc.remove_dest = dst_lst != null and !isDirSt(dst_lst.?);
    if (!copyTop(&cc, src, dst, true, 0)) {
        ctx.failed = true;
        return;
    }
    if (!removeTree(src)) {
        err(ctx, "cannot remove '{s}': Permission denied", .{src});
        return;
    }
    verboseMsg(ctx, src, dst, backup_name);
}

// ===================== ln =====================
fn relativePath(a: std.mem.Allocator, target: []const u8, linkdir: []const u8) []const u8 {
    // target and linkdir are absolute, normalised
    var t = std.mem.tokenizeScalar(u8, target, '/');
    var l = std.mem.tokenizeScalar(u8, linkdir, '/');
    var tparts = u.Vec([]const u8).init(a);
    var lparts = u.Vec([]const u8).init(a);
    while (t.next()) |x| tparts.push(x);
    while (l.next()) |x| lparts.push(x);
    var i: usize = 0;
    while (i < tparts.items.len and i < lparts.items.len and std.mem.eql(u8, tparts.items[i], lparts.items[i])) i += 1;
    var o = u.Vec(u8).init(a);
    var k = i;
    while (k < lparts.items.len) : (k += 1) o.pushSlice("../");
    var first = true;
    for (tparts.items[i..]) |x| {
        if (!first) o.push('/');
        first = false;
        o.pushSlice(x);
    }
    if (o.items.len == 0) return ".";
    if (std.mem.endsWith(u8, o.items, "/")) o.items.len -= 1;
    return o.items;
}

fn absPath(a: std.mem.Allocator, p: []const u8) []const u8 {
    var buf: [u.PATH_MAX]u8 = undefined;
    var full: []const u8 = p;
    if (p.len == 0 or p[0] != '/') {
        const rc = linux.getcwd(&buf, buf.len);
        const cwd = if (u.ok(rc)) std.mem.sliceTo(&buf, 0) else "/";
        full = std.fmt.allocPrint(a, "{s}/{s}", .{ cwd, p }) catch p;
    }
    var parts = u.Vec([]const u8).init(a);
    var it = std.mem.splitScalar(u8, full, '/');
    while (it.next()) |x| {
        if (x.len == 0 or std.mem.eql(u8, x, ".")) continue;
        if (std.mem.eql(u8, x, "..")) {
            if (parts.items.len > 0) parts.pop();
            continue;
        }
        parts.push(x);
    }
    var o = u.Vec(u8).init(a);
    for (parts.items) |x| {
        o.push('/');
        o.pushSlice(x);
    }
    if (o.items.len == 0) o.push('/');
    return o.items;
}

pub fn ln(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "backup", .key = 131, .arg = .opt },
        .{ .key = 'b' },
        .{ .name = "directory", .key = 'd' },
        .{ .name = "force", .key = 'f' },
        .{ .key = 'F' },
        .{ .name = "interactive", .key = 'i' },
        .{ .name = "logical", .key = 'L' },
        .{ .name = "no-dereference", .key = 'n' },
        .{ .name = "physical", .key = 'P' },
        .{ .name = "relative", .key = 'r' },
        .{ .name = "symbolic", .key = 's' },
        .{ .name = "suffix", .key = 'S', .arg = .req },
        .{ .name = "target-directory", .key = 't', .arg = .req },
        .{ .name = "no-target-directory", .key = 'T' },
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "help", .key = HELP },
        .{ .name = "version", .key = VERSION },
    };
    var ctx = newCtx("ln");
    var p = g.Parser.init("ln", args, &opts);
    var target_dir: ?[]const u8 = null;
    var no_target = false;
    var backup_set = false;
    var symbolic = false;
    var relative = false;
    var no_deref = false;
    var logical = false;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            131 => {
                backup_set = true;
                ctx.backup = if (it.val) |v| (parseBackup(v) orelse {
                    u.errf("ln: invalid argument '{s}' for 'backup type'\nTry 'ln --help' for more information.\n", .{v});
                    return 1;
                }) else .existing;
            },
            'b' => {
                if (!backup_set) ctx.backup = .existing;
                backup_set = true;
            },
            'd', 'F' => {},
            'f' => {
                ctx.force = true;
                ctx.interactive = false;
            },
            'i' => {
                ctx.interactive = true;
                ctx.force = false;
            },
            'L' => logical = true,
            'n' => no_deref = true,
            'P' => logical = false,
            'r' => relative = true,
            's' => symbolic = true,
            'S' => {
                ctx.suffix = it.val.?;
                if (!backup_set) {
                    ctx.backup = .existing;
                    backup_set = true;
                }
            },
            't' => target_dir = it.val,
            'T' => no_target = true,
            'v' => ctx.verbose = true,
            HELP => {
                u.out("Usage: ln [OPTION]... [-T] TARGET LINK_NAME\n  or:  ln [OPTION]... TARGET\n  or:  ln [OPTION]... TARGET... DIRECTORY\n  or:  ln [OPTION]... -t DIRECTORY TARGET...\nCreate links between files.\n");
                return 0;
            },
            VERSION => {
                u.out("ln (cmdbox)\n");
                return 0;
            },
            else => {},
        }
    }
    if (relative and !symbolic) {
        // -r only makes sense with -s (GNU ignores it otherwise)
    }
    var ops = p.operands.items;
    if (target_dir != null and no_target) {
        u.err("ln: cannot combine --target-directory (-t) and --no-target-directory (-T)\n");
        return 1;
    }
    if (ops.len == 0) {
        u.err("ln: missing file operand\nTry 'ln --help' for more information.\n");
        return 1;
    }
    var dest: []const u8 = undefined;
    var into_dir = false;
    if (target_dir) |t| {
        dest = t;
        into_dir = true;
        if (!u.isDir(t)) {
            u.errf("ln: target '{s}' is not a directory\n", .{t});
            return 1;
        }
    } else if (ops.len == 1) {
        dest = "";
        into_dir = true;
    } else {
        dest = ops[ops.len - 1];
        ops = ops[0 .. ops.len - 1];
        if (!no_target) {
            const dd = u.stat(dest, !no_deref);
            if (dd != null and isDirSt(dd.?)) into_dir = true;
        }
        if (!into_dir and ops.len > 1) {
            u.errf("ln: target '{s}' is not a directory\n", .{dest});
            return 1;
        }
    }
    for (ops) |target| {
        const lname = if (into_dir) joinPath(dest, baseName(target)) else dest;
        // existing destination?
        const lst = u.stat(lname, false);
        var backup_name: ?[]const u8 = null;
        if (lst != null) {
            if (ctx.interactive) {
                if (!confirm(&ctx, "replace", lname)) continue;
            } else if (!ctx.force and ctx.backup == .none) {
                if (symbolic) u.errf("ln: failed to create symbolic link '{s}': File exists\n", .{lname}) else u.errf("ln: failed to create hard link '{s}': File exists\n", .{lname});
                ctx.failed = true;
                continue;
            }
            if (!symbolic) {
                // same file: hard link to itself
                const ts = u.stat(target, !logical and false);
                if (ts != null and sameFile(ts.?, lst.?) and ctx.backup == .none) {
                    u.errf("ln: '{s}' and '{s}' are the same file\n", .{ target, lname });
                    ctx.failed = true;
                    continue;
                }
            }
            if (ctx.backup != .none) {
                backup_name = backupPath(&ctx, lname);
                if (backup_name) |b| {
                    const rc = linux.rename(u.zstr(lname), u.zstr(b));
                    if (!u.ok(rc)) {
                        u.errf("ln: cannot backup '{s}': {s}\n", .{ lname, esc(u.errno(rc)) });
                        ctx.failed = true;
                        continue;
                    }
                }
            } else {
                const rc = linux.unlink(u.zstr(lname));
                if (!u.ok(rc)) {
                    u.errf("ln: cannot remove '{s}': {s}\n", .{ lname, esc(u.errno(rc)) });
                    ctx.failed = true;
                    continue;
                }
            }
        }
        if (symbolic) {
            var content: []const u8 = target;
            if (relative) {
                const abs_t = absPath(u.alloc, target);
                const ldir = std.fs.path.dirname(absPath(u.alloc, lname)) orelse "/";
                content = relativePath(u.alloc, abs_t, ldir);
            }
            const rc = linux.symlink(u.zstr(content), u.zstr(lname));
            if (!u.ok(rc)) {
                u.errf("ln: failed to create symbolic link '{s}': {s}\n", .{ lname, esc(u.errno(rc)) });
                ctx.failed = true;
                continue;
            }
            if (ctx.verbose) {
                if (backup_name) |b| u.outf("'{s}' -> '{s}' (backup: '{s}')\n", .{ lname, content, b }) else u.outf("'{s}' -> '{s}'\n", .{ lname, content });
            }
        } else {
            // hard link: -L follows symlinks in TARGET, default (-P) links the symlink itself
            const tgt = target;
            const ts = u.stat(target, false);
            if (ts == null) {
                u.errf("ln: failed to access '{s}': No such file or directory\n", .{target});
                ctx.failed = true;
                continue;
            }
            if (isDirSt(ts.?)) {
                u.errf("ln: '{s}': hard link not allowed for directory\n", .{target});
                ctx.failed = true;
                continue;
            }
            const rc = linux.syscall5(.linkat, @bitCast(@as(isize, std.posix.AT.FDCWD)), @intFromPtr(u.zstr(tgt).ptr), @bitCast(@as(isize, std.posix.AT.FDCWD)), @intFromPtr(u.zstr(lname).ptr), if (logical) 0x400 else 0);
            if (!u.ok(rc)) {
                u.errf("ln: failed to create hard link '{s}' => '{s}': {s}\n", .{ lname, target, esc(u.errno(rc)) });
                ctx.failed = true;
                continue;
            }
            if (ctx.verbose) {
                if (backup_name) |b| u.outf("'{s}' => '{s}' (backup: '{s}')\n", .{ lname, target, b }) else u.outf("'{s}' => '{s}'\n", .{ lname, target });
            }
        }
    }
    return if (ctx.failed) 1 else 0;
}
