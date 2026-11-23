// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// stat, du, dd, split, install - GNU coreutils semantics
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const dt = @import("datetime.zig");
const mode_mod = @import("mode.zig");
const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("grp.h");
});

const HELP: u8 = 200;
const VERSION: u8 = 201;

fn common(prog: []const u8, key: u8, usage: []const u8) ?u8 {
    if (key == HELP) {
        u.out(usage);
        return 0;
    }
    if (key == VERSION) {
        u.outf("{s} (cmdbox)\n", .{prog});
        return 0;
    }
    return null;
}

const hv = [_]g.Opt{
    .{ .name = "help", .key = HELP },
    .{ .name = "version", .key = VERSION },
};

fn userName(uid: u32) []const u8 {
    if (c.getpwuid(uid)) |p| return std.mem.sliceTo(p.*.pw_name, 0);
    return "UNKNOWN";
}
fn groupName(gid: u32) []const u8 {
    if (c.getgrgid(gid)) |p| return std.mem.sliceTo(p.*.gr_name, 0);
    return "UNKNOWN";
}

fn joinPath(dir: []const u8, name: []const u8) []const u8 {
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

// ===================== stat =====================
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

fn modeStr(mode: u32) [10]u8 {
    var r: [10]u8 = .{ '-', '-', '-', '-', '-', '-', '-', '-', '-', '-' };
    r[0] = switch (mode & linux.S.IFMT) {
        linux.S.IFDIR => 'd',
        linux.S.IFLNK => 'l',
        linux.S.IFIFO => 'p',
        linux.S.IFSOCK => 's',
        linux.S.IFCHR => 'c',
        linux.S.IFBLK => 'b',
        else => '-',
    };
    const l = "rwxrwxrwx";
    for (l, 0..) |ch, i| if (mode & (@as(u32, 0o400) >> @as(u5, @intCast(i))) != 0) {
        r[i + 1] = ch;
    };
    if (mode & 0o4000 != 0) r[3] = if (mode & 0o100 != 0) 's' else 'S';
    if (mode & 0o2000 != 0) r[6] = if (mode & 0o010 != 0) 's' else 'S';
    if (mode & 0o1000 != 0) r[9] = if (mode & 0o001 != 0) 't' else 'T';
    return r;
}

fn devMajor(d: u64) u64 {
    return ((d >> 8) & 0xfff) | ((d >> 32) & ~@as(u64, 0xfff));
}
fn devMinor(d: u64) u64 {
    return (d & 0xff) | ((d >> 12) & ~@as(u64, 0xff));
}

fn timeStr(sec: i64, nsec: u32, o: *u.Vec(u8)) void {
    const tm = dt.localtime(sec);
    dt.format("%Y-%m-%d %H:%M:%S.%N %z", .{ .sec = sec, .nsec = nsec }, &tm, o);
}

fn quoteName(name: []const u8, o: *u.Vec(u8)) void {
    // shell-quoted like GNU's %N (quotes always)
    o.push('\'');
    for (name) |ch| {
        if (ch == '\'') o.pushSlice("'\\''") else o.push(ch);
    }
    o.push('\'');
}

const Statfs = extern struct {
    type: i64, bsize: i64, blocks: u64, bfree: u64, bavail: u64, files: u64, ffree: u64,
    fsid: [2]i32, namelen: i64, frsize: i64, flags: i64, spare: [4]i64,
};

fn fsTypeName(t: i64) []const u8 {
    const m = [_]struct { t: i64, n: []const u8 }{
        .{ .t = 0xEF53, .n = "ext2/ext3" }, .{ .t = 0x01021994, .n = "tmpfs" }, .{ .t = 0x9fa0, .n = "proc" }, .{ .t = 0x62656572, .n = "sysfs" },
        .{ .t = 0x858458f6, .n = "ramfs" }, .{ .t = 0x58465342, .n = "xfs" }, .{ .t = 0x9123683E, .n = "btrfs" }, .{ .t = 0x4d44, .n = "msdos" },
        .{ .t = 0x65735546, .n = "fuseblk" }, .{ .t = 0x65735543, .n = "fuse" }, .{ .t = 0x6969, .n = "nfs" }, .{ .t = 0x794c7630, .n = "overlayfs" },
        .{ .t = 0x1cd1, .n = "devpts" }, .{ .t = 0x64626720, .n = "debugfs" }, .{ .t = 0x27e0eb, .n = "cgroup" }, .{ .t = 0x63677270, .n = "cgroup2" },
        .{ .t = 0x2fc12fc1, .n = "zfs" }, .{ .t = 0x73717368, .n = "squashfs" }, .{ .t = 0x5346544e, .n = "ntfs" }, .{ .t = 0x2011bab0, .n = "exfat" },
        .{ .t = 0xff534d42, .n = "cifs" }, .{ .t = 0x4244, .n = "hfs" }, .{ .t = 0x15013346, .n = "udf" }, .{ .t = 0x9660, .n = "iso9660" },
    };
    for (m) |e| if (e.t == t) return e.n;
    return std.fmt.allocPrint(u.alloc, "UNKNOWN (0x{x})", .{t}) catch "UNKNOWN";
}

fn doStatfs(path: []const u8) ?Statfs {
    var s: Statfs = undefined;
    if (@sizeOf(usize) == 4) {
        const rc = linux.syscall3(.statfs64, @intFromPtr(u.zstr(path).ptr), @sizeOf(Statfs), @intFromPtr(&s));
        if (!u.ok(rc)) return null;
        return s;
    }
    const rc = linux.syscall2(.statfs, @intFromPtr(u.zstr(path).ptr), @intFromPtr(&s));
    if (!u.ok(rc)) return null;
    return s;
}

fn applyWidth(out: *u.Vec(u8), piece: []const u8, left: bool, zero: bool, width: usize) void {
    if (piece.len >= width) {
        out.pushSlice(piece);
        return;
    }
    const pad = width - piece.len;
    if (left) {
        out.pushSlice(piece);
        out.pushN(' ', pad);
    } else {
        out.pushN(if (zero) '0' else ' ', pad);
        out.pushSlice(piece);
    }
}

fn formatOne(fmt: []const u8, name: []const u8, st: u.Stat, target: ?[]const u8, out: *u.Vec(u8), escapes: bool) void {
    var i: usize = 0;
    while (i < fmt.len) {
        const ch = fmt[i];
        if (escapes and ch == '\\' and i + 1 < fmt.len) {
            i += 1;
            switch (fmt[i]) {
                'n' => out.push('\n'),
                't' => out.push('\t'),
                'a' => out.push(7),
                'b' => out.push(8),
                'f' => out.push(12),
                'r' => out.push('\r'),
                'v' => out.push(11),
                '0'...'7' => {
                    var v: u32 = 0;
                    var k: usize = 0;
                    while (i < fmt.len and k < 3 and fmt[i] >= '0' and fmt[i] <= '7') : (k += 1) {
                        v = v * 8 + (fmt[i] - '0');
                        i += 1;
                    }
                    i -= 1;
                    out.push(@intCast(v & 0xff));
                },
                else => out.push(fmt[i]),
            }
            i += 1;
            continue;
        }
        if (ch != '%' or i + 1 >= fmt.len) {
            out.push(ch);
            i += 1;
            continue;
        }
        i += 1;
        var left = false;
        var zero = false;
        while (i < fmt.len and std.mem.indexOfScalar(u8, "-0+ #", fmt[i]) != null) : (i += 1) {
            if (fmt[i] == '-') left = true;
            if (fmt[i] == '0') zero = true;
        }
        var width: usize = 0;
        while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) width = width * 10 + (fmt[i] - '0');
        if (i >= fmt.len) break;
        var tmp: [64]u8 = undefined;
        var piece = u.Vec(u8).init(u.alloc);
        const sp = fmt[i];
        i += 1;
        switch (sp) {
            '%' => piece.push('%'),
            'a' => piece.pushSlice(std.fmt.bufPrint(&tmp, "{o}", .{st.mode & 0o7777}) catch ""),
            'A' => piece.pushSlice(&modeStr(st.mode)),
            'b' => piece.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{st.blocks}) catch ""),
            'B' => piece.pushSlice("512"),
            'd' => piece.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{st.dev}) catch ""),
            'D' => piece.pushSlice(std.fmt.bufPrint(&tmp, "{x}", .{st.dev}) catch ""),
            'f' => piece.pushSlice(std.fmt.bufPrint(&tmp, "{x}", .{st.mode}) catch ""),
            'F' => piece.pushSlice(typeName(st)),
            'g' => piece.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{st.gid}) catch ""),
            'G' => piece.pushSlice(groupName(st.gid)),
            'h' => piece.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{st.nlink}) catch ""),
            'i' => piece.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{st.ino}) catch ""),
            'm' => piece.pushSlice("/"),
            'n' => piece.pushSlice(name),
            'N' => {
                quoteName(name, &piece);
                if (target) |t| {
                    piece.pushSlice(" -> ");
                    quoteName(t, &piece);
                }
            },
            'o' => piece.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{st.blksize}) catch ""),
            's' => piece.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{st.size}) catch ""),
            't' => piece.pushSlice(std.fmt.bufPrint(&tmp, "{x}", .{devMajor(st.rdev)}) catch ""),
            'T' => piece.pushSlice(std.fmt.bufPrint(&tmp, "{x}", .{devMinor(st.rdev)}) catch ""),
            'r' => piece.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{devMajor(st.rdev)}) catch ""),
            'R' => piece.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{devMinor(st.rdev)}) catch ""),
            'u' => piece.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{st.uid}) catch ""),
            'U' => piece.pushSlice(userName(st.uid)),
            'w' => if (st.btime < 0) piece.push('-') else timeStr(st.btime, st.btime_nsec, &piece),
            'W' => piece.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{if (st.btime < 0) 0 else st.btime}) catch ""),
            'x' => timeStr(st.atime, st.atime_nsec, &piece),
            'X' => piece.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{st.atime}) catch ""),
            'y' => timeStr(st.mtime, st.mtime_nsec, &piece),
            'Y' => piece.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{st.mtime}) catch ""),
            'z' => timeStr(st.ctime, st.ctime_nsec, &piece),
            'Z' => piece.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{st.ctime}) catch ""),
            'C' => piece.push('?'),
            else => {
                piece.push('?');
            },
        }
        applyWidth(out, piece.items, left, zero, width);
    }
}

fn formatFs(fmt: []const u8, name: []const u8, sf: Statfs, out: *u.Vec(u8), escapes: bool) void {
    var i: usize = 0;
    while (i < fmt.len) {
        const ch = fmt[i];
        if (escapes and ch == '\\' and i + 1 < fmt.len) {
            i += 1;
            out.push(switch (fmt[i]) {
                'n' => '\n',
                't' => '\t',
                else => fmt[i],
            });
            i += 1;
            continue;
        }
        if (ch != '%' or i + 1 >= fmt.len) {
            out.push(ch);
            i += 1;
            continue;
        }
        i += 1;
        var left = false;
        var zero = false;
        while (i < fmt.len and std.mem.indexOfScalar(u8, "-0+ #", fmt[i]) != null) : (i += 1) {
            if (fmt[i] == '-') left = true;
            if (fmt[i] == '0') zero = true;
        }
        var width: usize = 0;
        while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) width = width * 10 + (fmt[i] - '0');
        if (i >= fmt.len) break;
        var tmp: [64]u8 = undefined;
        const sp = fmt[i];
        i += 1;
        const fr: u64 = if (sf.frsize > 0) @intCast(sf.frsize) else @intCast(sf.bsize);
        const piece: []const u8 = switch (sp) {
            '%' => "%",
            'a' => std.fmt.bufPrint(&tmp, "{d}", .{sf.bavail}) catch "",
            'b' => std.fmt.bufPrint(&tmp, "{d}", .{sf.blocks}) catch "",
            'c' => std.fmt.bufPrint(&tmp, "{d}", .{sf.files}) catch "",
            'd' => std.fmt.bufPrint(&tmp, "{d}", .{sf.ffree}) catch "",
            'f' => std.fmt.bufPrint(&tmp, "{d}", .{sf.bfree}) catch "",
            'i' => std.fmt.bufPrint(&tmp, "{x:0>8}{x:0>8}", .{ @as(u32, @bitCast(sf.fsid[0])), @as(u32, @bitCast(sf.fsid[1])) }) catch "",
            'l' => std.fmt.bufPrint(&tmp, "{d}", .{sf.namelen}) catch "",
            'n' => name,
            's' => std.fmt.bufPrint(&tmp, "{d}", .{sf.bsize}) catch "",
            'S' => std.fmt.bufPrint(&tmp, "{d}", .{fr}) catch "",
            't' => std.fmt.bufPrint(&tmp, "{x}", .{sf.type}) catch "",
            'T' => fsTypeName(sf.type),
            else => "?",
        };
        applyWidth(out, piece, left, zero, width);
    }
}

pub fn stat(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "dereference", .key = 'L' },
        .{ .name = "file-system", .key = 'f' },
        .{ .name = "format", .key = 'c', .arg = .req },
        .{ .name = "printf", .key = 130, .arg = .req },
        .{ .name = "terse", .key = 't' },
        .{ .name = "cached", .key = 131, .arg = .req },
    } ++ hv;
    var p = g.Parser.init("stat", args, &opts);
    var deref = false;
    var fsmode = false;
    var fmt: ?[]const u8 = null;
    var printf_mode = false;
    var terse = false;
    while (p.next() catch return 1) |it| {
        if (common("stat", it.key, "Usage: stat [OPTION]... FILE...\nDisplay file or file system status.\n")) |r| return r;
        switch (it.key) {
            'L' => deref = true,
            'f' => fsmode = true,
            'c' => fmt = it.val,
            130 => {
                fmt = it.val;
                printf_mode = true;
            },
            't' => terse = true,
            else => {},
        }
    }
    if (p.operands.items.len == 0) {
        u.err("stat: missing operand\nTry 'stat --help' for more information.\n");
        return 1;
    }
    var rc: u8 = 0;
    for (p.operands.items) |path| {
        var o = u.Vec(u8).init(u.alloc);
        if (fsmode) {
            const sf = doStatfs(path) orelse {
                u.errf("stat: cannot read file system information for '{s}': {s}\n", .{ path, u.strerr(u.errno(linux.statx(std.posix.AT.FDCWD, u.zstr(path), 0, .{}, undefined))) });
                rc = 1;
                continue;
            };
            if (fmt) |f| {
                formatFs(f, path, sf, &o, printf_mode);
                if (!printf_mode) o.push('\n');
            } else if (terse) {
                formatFs("%n %i %l %t %s %S %b %f %a %c %d\n", path, sf, &o, false);
            } else {
                formatFs("  File: \"%n\"\n    ID: %i Namelen: %-7l Type: %T\nBlock size: %-10s Fundamental block size: %S\nBlocks: Total: %-10b Free: %-10f Available: %a\nInodes: Total: %-10c Free: %d\n", path, sf, &o, false);
            }
            u.out(o.items);
            continue;
        }
        const st = u.stat(path, deref) orelse {
            const en = u.errno(linux.statx(std.posix.AT.FDCWD, u.zstr(path), if (deref) 0 else 0x100, .{ .MODE = true }, undefined));
            u.errf("stat: cannot statx '{s}': {s}\n", .{ path, u.strerr(en) });
            rc = 1;
            continue;
        };
        var target: ?[]const u8 = null;
        if (st.mode & linux.S.IFMT == linux.S.IFLNK) {
            var buf: [u.PATH_MAX]u8 = undefined;
            const rl = linux.readlink(u.zstr(path), &buf, buf.len);
            if (u.ok(rl)) target = u.alloc.dupe(u8, buf[0..rl]) catch null;
        }
        if (fmt) |f| {
            formatOne(f, path, st, target, &o, printf_mode);
            if (!printf_mode) o.push('\n');
        } else if (terse) {
            formatOne("%n %s %b %f %u %g %D %i %h %t %T %X %Y %Z %W %o\n", path, st, target, &o, false);
        } else {
            var line = u.Vec(u8).init(u.alloc);
            // File line (symlinks show the target)
            o.pushSlice("  File: ");
            quoteIfNeeded(path, &o);
            if (target) |t| {
                o.pushSlice(" -> ");
                quoteIfNeeded(t, &o);
            }
            o.push('\n');
            const dev_s = std.fmt.allocPrint(u.alloc, "{d},{d}", .{ devMajor(st.dev), devMinor(st.dev) }) catch "";
            const sizeline = std.fmt.allocPrint(u.alloc, "  Size: {d: <10}\tBlocks: {d: <10} IO Block: {d: <6} {s}\n", .{ st.size, st.blocks, st.blksize, typeName(st) }) catch "";
            o.pushSlice(sizeline);
            if (st.mode & linux.S.IFMT == linux.S.IFCHR or st.mode & linux.S.IFMT == linux.S.IFBLK) {
                o.pushSlice(std.fmt.allocPrint(u.alloc, "Device: {s}\tInode: {d: <11} Links: {d: <5} Device type: {d},{d}\n", .{ dev_s, st.ino, st.nlink, devMajor(st.rdev), devMinor(st.rdev) }) catch "");
            } else {
                o.pushSlice(std.fmt.allocPrint(u.alloc, "Device: {s}\tInode: {d: <11} Links: {d}\n", .{ dev_s, st.ino, st.nlink }) catch "");
            }
            line = u.Vec(u8).init(u.alloc);
            const ms = modeStr(st.mode);
            o.pushSlice(std.fmt.allocPrint(u.alloc, "Access: ({o:0>4}/{s})  Uid: ({d: >5}/{s: >8})   Gid: ({d: >5}/{s: >8})\n", .{ st.mode & 0o7777, &ms, st.uid, userName(st.uid), st.gid, groupName(st.gid) }) catch "");
            o.pushSlice("Access: ");
            timeStr(st.atime, st.atime_nsec, &o);
            o.pushSlice("\nModify: ");
            timeStr(st.mtime, st.mtime_nsec, &o);
            o.pushSlice("\nChange: ");
            timeStr(st.ctime, st.ctime_nsec, &o);
            o.pushSlice("\n Birth: ");
            if (st.btime < 0) o.push('-') else timeStr(st.btime, st.btime_nsec, &o);
            o.push('\n');
        }
        u.out(o.items);
    }
    return rc;
}

fn quoteIfNeeded(name: []const u8, o: *u.Vec(u8)) void {
    var need = false;
    for (name) |ch| if (ch == ' ' or ch == '\'' or ch == '"' or ch == '\\' or ch < 0x20 or ch == '$' or ch == '`') {
        need = true;
    };
    if (!need) {
        o.pushSlice(name);
        return;
    }
    quoteName(name, o);
}

// ===================== du =====================
const DuCtx = struct {
    all: bool = false,
    apparent: bool = false,
    block: u64 = 1024,
    human: u8 = 0,
    block_sfx: []const u8 = "",
    total: bool = false,
    max_depth: usize = std.math.maxInt(usize),
    summarize: bool = false,
    separate: bool = false,
    one_fs: bool = false,
    deref: enum { never, cmd, always } = .never,
    count_links: bool = false,
    show_time: bool = false,
    zero: bool = false,
    inodes: bool = false,
    threshold: i64 = 0,
    excludes: u.Vec([]const u8) = undefined,
    seen: std.AutoHashMapUnmanaged(u128, void) = .{},
    failed: bool = false,
    grand: u64 = 0,
};

fn duSize(ctx: *DuCtx, st: u.Stat) u64 {
    if (ctx.inodes) return 1;
    if (ctx.apparent) {
        const t = st.mode & linux.S.IFMT;
        return if (t == linux.S.IFREG or t == linux.S.IFLNK) st.size else 0;
    }
    return st.blocks * 512;
}

fn humanDu(n: u64, o: *u.Vec(u8), base: u64) void {
    const sfx = if (base == 1000) [_][]const u8{ "", "k", "M", "G", "T", "P", "E", "Z", "Y" } else [_][]const u8{ "", "K", "M", "G", "T", "P", "E", "Z", "Y" };
    var e: usize = 0;
    var pw: u128 = 1;
    while (e < 8 and n >= pw * base) : (e += 1) pw *= base;
    var tmp: [64]u8 = undefined;
    if (e == 0) {
        o.pushSlice(std.fmt.bufPrint(&tmp, "{d}", .{n}) catch "");
        return;
    }
    var tenths = (@as(u128, n) * 10 + pw - 1) / pw;
    if (tenths >= base * 10 and e < 8) {
        e += 1;
        pw *= base;
        tenths = (@as(u128, n) * 10 + pw - 1) / pw;
    }
    if (tenths < 100) o.pushSlice(std.fmt.bufPrint(&tmp, "{d}.{d}{s}", .{ tenths / 10, tenths % 10, sfx[e] }) catch "") else o.pushSlice(std.fmt.bufPrint(&tmp, "{d}{s}", .{ (@as(u128, n) + pw - 1) / pw, sfx[e] }) catch "");
}

fn duPrint(ctx: *DuCtx, bytes: u64, path: []const u8, st: u.Stat) void {
    if (ctx.threshold != 0) {
        const sz: i64 = @intCast(bytes);
        if (ctx.threshold > 0 and sz < ctx.threshold) return;
        if (ctx.threshold < 0 and sz > -ctx.threshold) return;
    }
    var o = u.Vec(u8).init(u.alloc);
    if (ctx.human != 0) {
        humanDu(bytes, &o, if (ctx.human == 'H') 1000 else 1024);
    } else if (ctx.inodes) {
        o.pushSlice(std.fmt.allocPrint(u.alloc, "{d}", .{bytes}) catch "");
    } else {
        o.pushSlice(std.fmt.allocPrint(u.alloc, "{d}{s}", .{ (bytes + ctx.block - 1) / ctx.block, ctx.block_sfx }) catch "");
    }
    o.push('\t');
    if (ctx.show_time) {
        const tm = dt.localtime(st.mtime);
        dt.format("%Y-%m-%d %H:%M", .{ .sec = st.mtime }, &tm, &o);
        o.push('\t');
    }
    o.pushSlice(path);
    o.push(if (ctx.zero) 0 else '\n');
    u.out(o.items);
}

fn excluded(ctx: *DuCtx, name: []const u8) bool {
    for (ctx.excludes.items) |pat| {
        const z = u.zstr(pat);
        const n = u.zstr(name);
        const fnm = @cImport(@cInclude("fnmatch.h"));
        if (fnm.fnmatch(z.ptr, n.ptr, 0) == 0) return true;
    }
    return false;
}

/// returns the accumulated size of `path` (and prints entries as required)
fn duWalk(ctx: *DuCtx, path: []const u8, depth: usize, dev0: u64, top: bool) u64 {
    const follow = ctx.deref == .always or (ctx.deref == .cmd and top);
    const st = u.stat(path, follow) orelse {
        const en = u.errno(linux.statx(std.posix.AT.FDCWD, u.zstr(path), if (follow) 0 else 0x100, .{ .MODE = true }, undefined));
        u.errf("du: cannot access '{s}': {s}\n", .{ path, u.strerr(en) });
        ctx.failed = true;
        return 0;
    };
    const is_dir = st.mode & linux.S.IFMT == linux.S.IFDIR;
    if (((!is_dir and st.nlink > 1) or ctx.deref != .never) and !ctx.count_links) {
        const key: u128 = (@as(u128, st.dev) << 64) | st.ino;
        if (ctx.seen.contains(key)) return 0;
        ctx.seen.put(u.alloc, key, {}) catch {};
    }
    var total: u64 = duSize(ctx, st);
    if (is_dir) {
        if (ctx.one_fs and !top and st.dev != dev0) return 0;
        var ents = u.Vec(u.DirEnt).init(u.alloc);
        if (!u.listDirRaw(path, &ents)) {
            u.errf("du: cannot read directory '{s}': Permission denied\n", .{path});
            ctx.failed = true;
        } else for (ents.items) |en| {
            const nm: []const u8 = en.name;
            if (excluded(ctx, nm)) continue;
            const child = joinPath(path, nm);
            const sub = duWalk(ctx, child, depth + 1, if (top) st.dev else dev0, false);
            if (!ctx.separate) total += sub else {
                const cst = u.stat(child, false);
                if (cst != null and cst.?.mode & linux.S.IFMT != linux.S.IFDIR) total += sub;
            }
        }
        if (!ctx.summarize or top) {
            if (depth <= ctx.max_depth and (!ctx.summarize or top)) duPrint(ctx, total, path, st);
        }
        return total;
    }
    if ((ctx.all or top) and depth <= ctx.max_depth and (!ctx.summarize or top)) duPrint(ctx, total, path, st);
    return total;
}

pub fn du(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "all", .key = 'a' },
        .{ .name = "apparent-size", .key = 130 },
        .{ .name = "bytes", .key = 'b' },
        .{ .name = "block-size", .key = 'B', .arg = .req },
        .{ .name = "total", .key = 'c' },
        .{ .name = "dereference-args", .key = 'D' },
        .{ .key = 'H' },
        .{ .name = "max-depth", .key = 'd', .arg = .req },
        .{ .name = "human-readable", .key = 'h' },
        .{ .name = "si", .key = 131 },
        .{ .key = 'k' },
        .{ .name = "count-links", .key = 'l' },
        .{ .key = 'm' },
        .{ .name = "dereference", .key = 'L' },
        .{ .name = "no-dereference", .key = 'P' },
        .{ .name = "separate-dirs", .key = 'S' },
        .{ .name = "summarize", .key = 's' },
        .{ .name = "one-file-system", .key = 'x' },
        .{ .name = "exclude", .key = 132, .arg = .req },
        .{ .name = "exclude-from", .key = 'X', .arg = .req },
        .{ .name = "time", .key = 133, .arg = .opt },
        .{ .name = "null", .key = '0' },
        .{ .name = "inodes", .key = 134 },
        .{ .name = "threshold", .key = 't', .arg = .req },
        .{ .name = "files0-from", .key = 135, .arg = .req },
    } ++ hv;
    var ctx = DuCtx{ .excludes = u.Vec([]const u8).init(u.alloc) };
    var p = g.Parser.init("du", args, &opts);
    var files0: ?[]const u8 = null;
    while (p.next() catch return 1) |it| {
        if (common("du", it.key, "Usage: du [OPTION]... [FILE]...\nSummarize device usage of the set of FILEs, recursively for directories.\n")) |r| return r;
        switch (it.key) {
            'a' => ctx.all = true,
            130 => ctx.apparent = true,
            'b' => {
                ctx.apparent = true;
                ctx.block = 1;
                ctx.human = 0;
            },
            'B' => {
                const v = it.val.?;
                var i: usize = 0;
                while (i < v.len and std.ascii.isDigit(v[i])) i += 1;
                var mult: u64 = if (i > 0) (std.fmt.parseInt(u64, v[0..i], 10) catch 1) else 1;
                if (i < v.len) {
                    const idx = std.mem.indexOfScalar(u8, "KMGTPEZY", std.ascii.toUpper(v[i])) orelse {
                        u.errf("du: invalid --block-size argument '{s}'\n", .{v});
                        return 1;
                    };
                    var b: u64 = 1024;
                    if (v.len - i == 2 and v[i + 1] == 'B') b = 1000;
                    var k: usize = 0;
                    while (k <= idx) : (k += 1) mult *%= b;
                }
                ctx.block = @max(mult, 1);
                ctx.human = 0;
                ctx.block_sfx = "";
                if (i < v.len and i == 0) {
                    const sx = v[i..];
                    ctx.block_sfx = if (std.mem.eql(u8, sx, "KB")) "kB" else sx;
                }
            },
            'c' => ctx.total = true,
            'D', 'H' => ctx.deref = .cmd,
            'd' => ctx.max_depth = std.fmt.parseInt(usize, it.val.?, 10) catch {
                u.errf("du: invalid maximum depth '{s}'\n", .{it.val.?});
                return 1;
            },
            'h' => ctx.human = 'h',
            131 => ctx.human = 'H',
            'k' => {
                ctx.block = 1024;
                ctx.human = 0;
            },
            'm' => {
                ctx.block = 1 << 20;
                ctx.human = 0;
            },
            'l' => ctx.count_links = true,
            'L' => ctx.deref = .always,
            'P' => ctx.deref = .never,
            'S' => ctx.separate = true,
            's' => {
                ctx.summarize = true;
            },
            'x' => ctx.one_fs = true,
            132 => ctx.excludes.push(it.val.?),
            'X' => {
                const d = readWhole(it.val.?) orelse {
                    u.errf("du: cannot access '{s}'\n", .{it.val.?});
                    return 1;
                };
                var ln = std.mem.splitScalar(u8, d, '\n');
                while (ln.next()) |l| if (l.len > 0) ctx.excludes.push(l);
            },
            133 => ctx.show_time = true,
            '0' => ctx.zero = true,
            134 => ctx.inodes = true,
            't' => ctx.threshold = std.fmt.parseInt(i64, it.val.?, 10) catch 0,
            135 => files0 = it.val,
            else => {},
        }
    }
    if (ctx.summarize and ctx.all) {
        u.err("du: cannot both summarize and show all entries\nTry 'du --help' for more information.\n");
        return 1;
    }
    if (ctx.summarize and ctx.max_depth != std.math.maxInt(usize)) {
        if (ctx.max_depth == 0) {
            u.err("du: warning: summarizing is the same as using --max-depth=0\n");
        } else {
            u.errf("du: warning: summarizing conflicts with --max-depth={d}\nTry 'du --help' for more information.\n", .{ctx.max_depth});
            return 1;
        }
    }
    var paths = p.operands;
    if (files0) |f0| {
        const d = (if (std.mem.eql(u8, f0, "-")) readFdAll(0) else readWhole(f0)) orelse return 1;
        var it = std.mem.splitScalar(u8, d, 0);
        while (it.next()) |nm| if (nm.len > 0) paths.push(nm);
    }
    if (paths.items.len == 0) paths.push(".");
    for (paths.items) |path| {
        const sz = duWalk(&ctx, path, 0, 0, true);
        ctx.grand += sz;
    }
    if (ctx.total) {
        var o = u.Vec(u8).init(u.alloc);
        if (ctx.human != 0) humanDu(ctx.grand, &o, if (ctx.human == 'H') 1000 else 1024) else if (ctx.inodes) o.pushSlice(std.fmt.allocPrint(u.alloc, "{d}", .{ctx.grand}) catch "") else o.pushSlice(std.fmt.allocPrint(u.alloc, "{d}{s}", .{ (ctx.grand + ctx.block - 1) / ctx.block, ctx.block_sfx }) catch "");
        o.pushSlice("\ttotal");
        o.push(if (ctx.zero) 0 else '\n');
        u.out(o.items);
    }
    return if (ctx.failed) 1 else 0;
}

fn readFdAll(fd: i32) ?[]u8 {
    var data = u.Vec(u8).init(u.alloc);
    var buf: [65536]u8 = undefined;
    while (true) {
        const rc = linux.read(fd, &buf, buf.len);
        if (u.errno(rc) == .INTR) continue;
        if (!u.ok(rc)) return null;
        if (rc == 0) break;
        data.pushSlice(buf[0..rc]);
    }
    return data.items;
}

fn readWhole(path: []const u8) ?[]u8 {
    const rc = linux.open(u.zstr(path), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(rc)) return null;
    defer _ = linux.close(@intCast(rc));
    return readFdAll(@intCast(rc));
}

// ===================== dd =====================
fn parseNumberDd(s: []const u8) ?u64 {
    // N[bcEGKkMPTwYZ][B|iB] possibly joined with 'x' products
    var total: u64 = 1;
    var it = std.mem.splitScalar(u8, s, 'x');
    var first = true;
    while (it.next()) |part| {
        if (part.len == 0) return null;
        var i: usize = 0;
        while (i < part.len and std.ascii.isDigit(part[i])) i += 1;
        var v: u64 = if (i > 0) (std.fmt.parseInt(u64, part[0..i], 10) catch return null) else 1;
        if (i == 0) return null;
        const sfx = part[i..];
        if (sfx.len > 0) {
            var mult: u64 = 1;
            const e = std.mem.eql;
            if (e(u8, sfx, "c")) mult = 1 else if (e(u8, sfx, "w")) mult = 2 else if (e(u8, sfx, "b")) mult = 512 else if (e(u8, sfx, "k") or e(u8, sfx, "K") or e(u8, sfx, "KiB")) mult = 1024 else if (e(u8, sfx, "kB")) mult = 1000 else if (e(u8, sfx, "M") or e(u8, sfx, "MiB")) mult = 1 << 20 else if (e(u8, sfx, "MB")) mult = 1000 * 1000 else if (e(u8, sfx, "G") or e(u8, sfx, "GiB")) mult = 1 << 30 else if (e(u8, sfx, "GB")) mult = 1000 * 1000 * 1000 else if (e(u8, sfx, "T") or e(u8, sfx, "TiB")) mult = 1 << 40 else if (e(u8, sfx, "TB")) mult = 1000 * 1000 * 1000 * 1000 else return null;
            v = std.math.mul(u64, v, mult) catch return null;
        }
        total = if (first) v else (std.math.mul(u64, total, v) catch return null);
        first = false;
    }
    return total;
}

fn humanSi(v: f64, base: f64, iec: bool, o: *u.Vec(u8)) void {
    const si = [_][]const u8{ "B", "kB", "MB", "GB", "TB", "PB", "EB" };
    const ie = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" };
    var x = v;
    var e: usize = 0;
    while (x >= base and e < 6) : (e += 1) x /= base;
    var tmp: [48]u8 = undefined;
    const unit = if (iec) ie[e] else si[e];
    if (e == 0) o.pushSlice(std.fmt.bufPrint(&tmp, "{d:.0} {s}", .{ x, unit }) catch "") else if (x < 10) o.pushSlice(std.fmt.bufPrint(&tmp, "{d:.1} {s}", .{ x, unit }) catch "") else o.pushSlice(std.fmt.bufPrint(&tmp, "{d:.0} {s}", .{ x, unit }) catch "");
}

pub fn dd(args: []const []const u8) u8 {
    var ifile: ?[]const u8 = null;
    var ofile: ?[]const u8 = null;
    var ibs: u64 = 512;
    var obs: u64 = 512;
    var bs: ?u64 = null;
    var cbs: u64 = 0;
    var count: ?u64 = null;
    var skip: u64 = 0;
    var seek: u64 = 0;
    var notrunc = false;
    var sync = false;
    var noerror = false;
    var fsync = false;
    var fdatasync = false;
    var ucase = false;
    var lcase = false;
    var swab = false;
    var excl = false;
    var nocreat = false;
    var fullblock = false;
    var status: enum { default, none, noxfer, progress } = .default;
    var skip_bytes = false;
    var count_bytes = false;
    var seek_bytes = false;
    _ = &cbs;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            u.out("Usage: dd [OPERAND]...\n  or:  dd OPTION\nCopy a file, converting and formatting according to the operands.\n");
            return 0;
        }
        if (std.mem.eql(u8, a, "--version")) {
            u.out("dd (cmdbox)\n");
            return 0;
        }
        const eq = std.mem.indexOfScalar(u8, a, '=') orelse {
            u.errf("dd: unrecognized operand '{s}'\nTry 'dd --help' for more information.\n", .{a});
            return 1;
        };
        const k = a[0..eq];
        const v = a[eq + 1 ..];
        const numErr = struct {
            fn f(val: []const u8) u8 {
                u.errf("dd: invalid number: '{s}'\n", .{val});
                return 1;
            }
        }.f;
        if (std.mem.eql(u8, k, "if")) ifile = v else if (std.mem.eql(u8, k, "of")) ofile = v else if (std.mem.eql(u8, k, "ibs")) {
            ibs = parseNumberDd(v) orelse return numErr(v);
        } else if (std.mem.eql(u8, k, "obs")) {
            obs = parseNumberDd(v) orelse return numErr(v);
        } else if (std.mem.eql(u8, k, "bs")) {
            bs = parseNumberDd(v) orelse return numErr(v);
        } else if (std.mem.eql(u8, k, "cbs")) {
            cbs = parseNumberDd(v) orelse return numErr(v);
        } else if (std.mem.eql(u8, k, "count")) {
            count = parseNumberDd(v) orelse return numErr(v);
        } else if (std.mem.eql(u8, k, "skip") or std.mem.eql(u8, k, "iseek")) {
            skip = parseNumberDd(v) orelse return numErr(v);
        } else if (std.mem.eql(u8, k, "seek") or std.mem.eql(u8, k, "oseek")) {
            seek = parseNumberDd(v) orelse return numErr(v);
        } else if (std.mem.eql(u8, k, "status")) {
            if (std.mem.eql(u8, v, "none")) status = .none else if (std.mem.eql(u8, v, "noxfer")) status = .noxfer else if (std.mem.eql(u8, v, "progress")) status = .progress else if (std.mem.eql(u8, v, "default")) status = .default else {
                u.errf("dd: invalid status level: '{s}'\n", .{v});
                return 1;
            }
        } else if (std.mem.eql(u8, k, "conv")) {
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |cv| {
                const e = std.mem.eql;
                if (e(u8, cv, "notrunc")) notrunc = true else if (e(u8, cv, "sync")) sync = true else if (e(u8, cv, "noerror")) noerror = true else if (e(u8, cv, "fsync")) fsync = true else if (e(u8, cv, "fdatasync")) fdatasync = true else if (e(u8, cv, "ucase")) ucase = true else if (e(u8, cv, "lcase")) lcase = true else if (e(u8, cv, "swab")) swab = true else if (e(u8, cv, "excl")) excl = true else if (e(u8, cv, "nocreat")) nocreat = true else if (e(u8, cv, "block") or e(u8, cv, "unblock") or e(u8, cv, "ascii") or e(u8, cv, "ebcdic") or e(u8, cv, "ibm") or e(u8, cv, "sparse")) {} else {
                    u.errf("dd: invalid conversion: '{s}'\nTry 'dd --help' for more information.\n", .{cv});
                    return 1;
                }
            }
        } else if (std.mem.eql(u8, k, "iflag") or std.mem.eql(u8, k, "oflag")) {
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |fl| {
                if (std.mem.eql(u8, fl, "fullblock")) fullblock = true else if (std.mem.eql(u8, fl, "skip_bytes")) skip_bytes = true else if (std.mem.eql(u8, fl, "count_bytes")) count_bytes = true else if (std.mem.eql(u8, fl, "seek_bytes")) seek_bytes = true;
            }
        } else {
            u.errf("dd: unrecognized operand '{s}'\nTry 'dd --help' for more information.\n", .{a});
            return 1;
        }
    }
    if (bs) |b| {
        ibs = b;
        obs = b;
    }
    if (ibs == 0 or obs == 0) {
        u.err("dd: invalid number: '0'\n");
        return 1;
    }
    var in_fd: i32 = 0;
    if (ifile) |f| {
        const rc = linux.open(u.zstr(f), .{ .ACCMODE = .RDONLY, .NOCTTY = true }, 0);
        if (!u.ok(rc)) {
            u.errf("dd: failed to open '{s}': {s}\n", .{ f, u.strerr(u.errno(rc)) });
            return 1;
        }
        in_fd = @intCast(rc);
    }
    var out_fd: i32 = 1;
    var out_regular = false;
    if (ofile) |f| {
        var flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = !nocreat, .NOCTTY = true };
        if (excl) flags.EXCL = true;
        if (seek == 0 and !notrunc) flags.TRUNC = true;
        const rc = linux.open(u.zstr(f), flags, 0o666);
        if (!u.ok(rc)) {
            u.errf("dd: failed to open '{s}': {s}\n", .{ f, u.strerr(u.errno(rc)) });
            return 1;
        }
        out_fd = @intCast(rc);
        if (u.statFd(out_fd)) |st| out_regular = st.mode & linux.S.IFMT == linux.S.IFREG;
        if (seek > 0) {
            const off: u64 = if (seek_bytes) seek else seek * obs;
            if (out_regular and !notrunc) _ = linux.syscall2(.ftruncate, @as(usize, @intCast(out_fd)), @intCast(off));
            const r = linux.syscall3(.lseek, @as(usize, @intCast(out_fd)), @intCast(off), 0);
            if (!u.ok(r)) {
                u.errf("dd: cannot seek in '{s}': {s}\n", .{ f, u.strerr(u.errno(r)) });
                return 1;
            }
        }
    } else if (seek > 0) {
        _ = linux.syscall3(.lseek, 1, @intCast(seek * obs), 0);
    }
    // skip input
    if (skip > 0) {
        const off: u64 = if (skip_bytes) skip else skip * ibs;
        const r = linux.syscall3(.lseek, @as(usize, @intCast(in_fd)), @intCast(off), 1);
        if (!u.ok(r)) {
            // not seekable: read and discard
            var left = off;
            var junk: [65536]u8 = undefined;
            while (left > 0) {
                const n = linux.read(in_fd, &junk, @min(junk.len, left));
                if (!u.ok(n) or n == 0) break;
                left -= n;
            }
        }
    }
    const ibuf = u.alloc.alloc(u8, @intCast(ibs)) catch return 1;
    var obuf = u.Vec(u8).init(u.alloc);
    var in_full: u64 = 0;
    var in_part: u64 = 0;
    var out_full: u64 = 0;
    var out_part: u64 = 0;
    var bytes_out: u64 = 0;
    var blocks_read: u64 = 0;
    var trunc_in: u64 = 0;
    _ = &trunc_in;
    var err_rc: u8 = 0;
    var ts0: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts0);
    const flushOut = struct {
        fn go(fd: i32, ob: *u.Vec(u8), obs_: u64, full: *u64, part: *u64, bytes: *u64, final: bool, rc: *u8) void {
            var off: usize = 0;
            while (ob.items.len - off >= obs_) {
                if (!writeAll(fd, ob.items[off .. off + @as(usize, @intCast(obs_))])) {
                    rc.* = 1;
                    return;
                }
                full.* += 1;
                bytes.* += obs_;
                off += @as(usize, @intCast(obs_));
            }
            const rest = ob.items.len - off;
            if (final and rest > 0) {
                if (!writeAll(fd, ob.items[off..])) rc.* = 1;
                part.* += 1;
                bytes.* += rest;
                off = ob.items.len;
            }
            if (off > 0) {
                const remain = u.alloc.dupe(u8, ob.items[off..]) catch "";
                ob.items.len = 0;
                ob.pushSlice(remain);
            }
        }
    }.go;
    var remaining_bytes: ?u64 = if (count_bytes and count != null) count else null;
    while (true) {
        if (!count_bytes) {
            if (count) |cnt| if (blocks_read >= cnt) break;
        } else if (remaining_bytes != null and remaining_bytes.? == 0) break;
        var want: usize = @intCast(ibs);
        if (remaining_bytes) |rb| want = @intCast(@min(@as(u64, want), rb));
        var got: usize = 0;
        var eof = false;
        while (got < want) {
            const r = linux.read(in_fd, ibuf.ptr + got, want - got);
            if (u.errno(r) == .INTR) continue;
            if (!u.ok(r)) {
                u.errf("dd: error reading '{s}': {s}\n", .{ ifile orelse "standard input", u.strerr(u.errno(r)) });
                if (noerror) {
                    err_rc = 1;
                    got = want;
                    @memset(ibuf[0..want], 0);
                    break;
                }
                err_rc = 1;
                eof = true;
                break;
            }
            if (r == 0) {
                eof = true;
                break;
            }
            got += r;
            if (!fullblock and !sync) break;
        }
        if (got == 0 and eof) break;
        blocks_read += 1;
        if (remaining_bytes) |*rb| rb.* -= got;
        if (got == @as(usize, @intCast(ibs))) in_full += 1 else in_part += 1;
        var chunk: []u8 = ibuf[0..got];
        if (sync and got < @as(usize, @intCast(ibs))) {
            @memset(ibuf[got..@as(usize, @intCast(ibs))], 0);
            chunk = ibuf[0..@as(usize, @intCast(ibs))];
        }
        if (swab) {
            var i: usize = 0;
            while (i + 1 < chunk.len) : (i += 2) std.mem.swap(u8, &chunk[i], &chunk[i + 1]);
        }
        if (ucase) for (chunk) |*ch| {
            ch.* = std.ascii.toUpper(ch.*);
        };
        if (lcase) for (chunk) |*ch| {
            ch.* = std.ascii.toLower(ch.*);
        };
        obuf.pushSlice(chunk);
        flushOut(out_fd, &obuf, obs, &out_full, &out_part, &bytes_out, false, &err_rc);
        if (err_rc != 0 and !noerror) break;
        if (eof) break;
    }
    flushOut(out_fd, &obuf, obs, &out_full, &out_part, &bytes_out, true, &err_rc);
    if (fsync) _ = linux.syscall1(.fsync, @as(usize, @intCast(out_fd)));
    if (fdatasync) _ = linux.syscall1(.fdatasync, @as(usize, @intCast(out_fd)));
    if (ofile != null) _ = linux.close(out_fd);
    if (ifile != null) _ = linux.close(in_fd);
    if (status != .none) {
        var ts1: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &ts1);
        const secs = @as(f64, @floatFromInt(ts1.sec - ts0.sec)) + @as(f64, @floatFromInt(ts1.nsec - ts0.nsec)) / 1e9;
        var o = u.Vec(u8).init(u.alloc);
        o.pushSlice(std.fmt.allocPrint(u.alloc, "{d}+{d} records in\n{d}+{d} records out\n", .{ in_full, in_part, out_full, out_part }) catch "");
        if (status != .noxfer) {
            o.pushSlice(std.fmt.allocPrint(u.alloc, "{d} bytes", .{bytes_out}) catch "");
            if (bytes_out >= 1000) {
                o.pushSlice(" (");
                humanSi(@floatFromInt(bytes_out), 1000, false, &o);
                var iec = u.Vec(u8).init(u.alloc);
                humanSi(@floatFromInt(bytes_out), 1024, true, &iec);
                if (!std.mem.endsWith(u8, iec.items, " B")) {
                    o.pushSlice(", ");
                    o.pushSlice(iec.items);
                }
                o.push(')');
            }
            o.pushSlice(" copied, ");
            var tmp: [64]u8 = undefined;
            o.pushSlice(std.fmt.bufPrint(&tmp, "{d:.6} s", .{secs}) catch "");
            if (secs > 0) {
                o.pushSlice(", ");
                humanSi(@as(f64, @floatFromInt(bytes_out)) / secs, 1000, false, &o);
                o.pushSlice("/s");
            }
            o.push('\n');
        }
        u.err(o.items);
    }
    return err_rc;
}

fn writeAll(fd: i32, data: []const u8) bool {
    var n: usize = 0;
    while (n < data.len) {
        const r = linux.write(fd, data.ptr + n, data.len - n);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r)) {
            u.errf("dd: error writing: {s}\n", .{u.strerr(u.errno(r))});
            return false;
        }
        n += r;
    }
    return true;
}

// ===================== split =====================
pub fn split(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "suffix-length", .key = 'a', .arg = .req },
        .{ .name = "bytes", .key = 'b', .arg = .req },
        .{ .name = "line-bytes", .key = 'C', .arg = .req },
        .{ .key = 'd', .arg = .opt },
        .{ .name = "numeric-suffixes", .key = 130, .arg = .opt },
        .{ .name = "hex-suffixes", .key = 131, .arg = .opt },
        .{ .key = 'x' },
        .{ .name = "elide-empty-files", .key = 'e' },
        .{ .name = "lines", .key = 'l', .arg = .req },
        .{ .name = "number", .key = 'n', .arg = .req },
        .{ .name = "additional-suffix", .key = 132, .arg = .req },
        .{ .name = "unbuffered", .key = 'u' },
        .{ .name = "verbose", .key = 133 },
        .{ .name = "separator", .key = 't', .arg = .req },
    } ++ hv;
    var p = g.Parser.init("split", args, &opts);
    var suffix_len: usize = 2;
    var suffix_set = false;
    var bytes: ?u64 = null;
    var line_bytes: ?u64 = null;
    var lines: ?u64 = 1000;
    var chunks: ?u64 = null;
    var numeric = false;
    var hex = false;
    var elide = false;
    var extra: []const u8 = "";
    var verbose = false;
    var sep: u8 = '\n';
    while (p.next() catch return 1) |it| {
        if (common("split", it.key, "Usage: split [OPTION]... [FILE [PREFIX]]\nOutput pieces of FILE to PREFIXaa, PREFIXab, ...; default size is 1000 lines, and default PREFIX is 'x'.\n")) |r| return r;
        switch (it.key) {
            'a' => {
                suffix_len = std.fmt.parseInt(usize, it.val.?, 10) catch {
                    u.errf("split: invalid suffix length: '{s}'\n", .{it.val.?});
                    return 1;
                };
                suffix_set = true;
            },
            'b' => {
                bytes = parseNumberDd(it.val.?) orelse {
                    u.errf("split: invalid number of bytes: '{s}'\n", .{it.val.?});
                    return 1;
                };
                lines = null;
            },
            'C' => {
                line_bytes = parseNumberDd(it.val.?) orelse {
                    u.errf("split: invalid number of bytes: '{s}'\n", .{it.val.?});
                    return 1;
                };
                lines = null;
            },
            'd', 130 => numeric = true,
            'x', 131 => hex = true,
            'e' => elide = true,
            'l' => {
                lines = std.fmt.parseInt(u64, it.val.?, 10) catch {
                    u.errf("split: invalid number of lines: '{s}'\n", .{it.val.?});
                    return 1;
                };
                if (lines.? == 0) {
                    u.errf("split: invalid number of lines: '0'\n", .{});
                    return 1;
                }
            },
            'n' => {
                chunks = std.fmt.parseInt(u64, it.val.?, 10) catch {
                    u.errf("split: invalid number of chunks: '{s}'\n", .{it.val.?});
                    return 1;
                };
                if (chunks.? == 0) {
                    u.errf("split: invalid number of chunks: '0'\n", .{});
                    return 1;
                }
                lines = null;
            },
            132 => extra = it.val.?,
            133 => verbose = true,
            't' => sep = if (it.val.?.len > 0) it.val.?[0] else '\n',
            else => {},
        }
    }
    const ops = p.operands.items;
    if (ops.len > 2) {
        u.errf("split: extra operand '{s}'\nTry 'split --help' for more information.\n", .{ops[2]});
        return 1;
    }
    const infile = if (ops.len > 0) ops[0] else "-";
    const prefix = if (ops.len > 1) ops[1] else "x";
    const data = (if (std.mem.eql(u8, infile, "-")) readFdAll(0) else readWhole(infile)) orelse {
        u.errf("split: cannot open '{s}' for reading: No such file or directory\n", .{infile});
        return 1;
    };
    // pieces
    var pieces = u.Vec([]const u8).init(u.alloc);
    if (chunks) |n| {
        const total: u64 = data.len;
        const sz = total / n;
        const rem = total % n;
        var off: usize = 0;
        var k: u64 = 0;
        while (k < n) : (k += 1) {
            const l: usize = @intCast(sz + (if (k < rem) @as(u64, 1) else 0));
            pieces.push(data[off .. off + l]);
            off += l;
        }
    } else if (bytes) |b| {
        var off: usize = 0;
        while (off < data.len) {
            const e = @min(data.len, off + @as(usize, @intCast(b)));
            pieces.push(data[off..e]);
            off = e;
        }
    } else if (line_bytes) |b| {
        var start: usize = 0;
        var cur: usize = 0;
        var last_nl: ?usize = null;
        while (cur < data.len) : (cur += 1) {
            if (data[cur] == sep) last_nl = cur;
            if (cur + 1 - start >= b) {
                const cut = if (last_nl != null and last_nl.? >= start) last_nl.? + 1 else cur + 1;
                pieces.push(data[start..cut]);
                start = cut;
                cur = cut - 1;
                last_nl = null;
            }
        }
        if (start < data.len) pieces.push(data[start..]);
    } else {
        const n = lines orelse 1000;
        var start: usize = 0;
        var count: u64 = 0;
        var i: usize = 0;
        while (i < data.len) : (i += 1) {
            if (data[i] == sep) {
                count += 1;
                if (count == n) {
                    pieces.push(data[start .. i + 1]);
                    start = i + 1;
                    count = 0;
                }
            }
        }
        if (start < data.len) pieces.push(data[start..]);
    }
    if (chunks != null and !suffix_set) {
        // enough digits for the chunk count
        var need: usize = 1;
        var cap: u64 = if (numeric) 10 else if (hex) 16 else 26;
        while (cap < chunks.?) : (need += 1) cap *= if (numeric) 10 else if (hex) 16 else 26;
        suffix_len = @max(2, need);
    }
    var idx: u64 = 0;
    var rc: u8 = 0;
    for (pieces.items) |piece| {
        if (elide and piece.len == 0) {
            idx += 1;
            continue;
        }
        // suffix
        var sfx = u.Vec(u8).init(u.alloc);
        if (numeric or hex) {
            const base: u64 = if (hex) 16 else 10;
            var digits = u.Vec(u8).init(u.alloc);
            var v = idx;
            var k: usize = 0;
            while (k < suffix_len) : (k += 1) {
                const d: u8 = @intCast(v % base);
                digits.push(if (d < 10) '0' + d else 'a' + d - 10);
                v /= base;
            }
            if (v > 0) {
                u.err("split: output file suffixes exhausted\n");
                return 1;
            }
            var j = digits.items.len;
            while (j > 0) {
                j -= 1;
                sfx.push(digits.items[j]);
            }
        } else {
            var v = idx;
            var letters = u.Vec(u8).init(u.alloc);
            var k: usize = 0;
            while (k < suffix_len) : (k += 1) {
                letters.push(@intCast('a' + v % 26));
                v /= 26;
            }
            if (v > 0) {
                u.err("split: output file suffixes exhausted\n");
                return 1;
            }
            var j = letters.items.len;
            while (j > 0) {
                j -= 1;
                sfx.push(letters.items[j]);
            }
        }
        const name = std.fmt.allocPrint(u.alloc, "{s}{s}{s}", .{ prefix, sfx.items, extra }) catch return 1;
        if (verbose) u.outf("creating file '{s}'\n", .{name});
        const fd_rc = linux.open(u.zstr(name), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666);
        if (!u.ok(fd_rc)) {
            u.errf("split: {s}: {s}\n", .{ name, u.strerr(u.errno(fd_rc)) });
            rc = 1;
            idx += 1;
            continue;
        }
        _ = writeAll(@intCast(fd_rc), piece);
        _ = linux.close(@intCast(fd_rc));
        idx += 1;
    }
    return rc;
}

// ===================== install =====================
pub fn install(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .key = 'c' },
        .{ .name = "backup", .key = 130, .arg = .opt },
        .{ .key = 'b' },
        .{ .name = "compare", .key = 'C' },
        .{ .name = "directory", .key = 'd' },
        .{ .key = 'D' },
        .{ .name = "group", .key = 'g', .arg = .req },
        .{ .name = "mode", .key = 'm', .arg = .req },
        .{ .name = "owner", .key = 'o', .arg = .req },
        .{ .name = "preserve-timestamps", .key = 'p' },
        .{ .name = "strip", .key = 's' },
        .{ .name = "suffix", .key = 'S', .arg = .req },
        .{ .name = "target-directory", .key = 't', .arg = .req },
        .{ .name = "no-target-directory", .key = 'T' },
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "context", .key = 'Z', .arg = .opt },
    } ++ hv;
    var p = g.Parser.init("install", args, &opts);
    var dirs = false;
    var mkparents = false;
    var mode_expr: []const u8 = "755";
    var owner: ?[]const u8 = null;
    var group: ?[]const u8 = null;
    var preserve_ts = false;
    var verbose = false;
    var target_dir: ?[]const u8 = null;
    var no_target = false;
    var backup = false;
    var suffix: []const u8 = "~";
    var compare = false;
    while (p.next() catch return 1) |it| {
        if (common("install", it.key, "Usage: install [OPTION]... SOURCE DEST\n  or:  install [OPTION]... SOURCE... DIRECTORY\n  or:  install [OPTION]... -d DIRECTORY...\nCopy files and set attributes.\n")) |r| return r;
        switch (it.key) {
            'd' => dirs = true,
            'D' => mkparents = true,
            'm' => mode_expr = it.val.?,
            'o' => owner = it.val,
            'g' => group = it.val,
            'p' => preserve_ts = true,
            'v' => verbose = true,
            't' => target_dir = it.val,
            'T' => no_target = true,
            'b', 130 => backup = true,
            'S' => {
                suffix = it.val.?;
                backup = true;
            },
            'C' => compare = true,
            else => {},
        }
    }
    const um = u.umask(0);
    _ = u.umask(um);
    const mode = mode_mod.apply(mode_expr, 0, false, 0) orelse {
        u.errf("install: invalid mode '{s}'\n", .{mode_expr});
        return 1;
    };
    var uid: u32 = 0xffffffff;
    var gid: u32 = 0xffffffff;
    if (owner) |o| uid = (if (std.fmt.parseInt(u32, o, 10)) |v| v else |_| u.findUser(o)) orelse {
        u.errf("install: invalid user '{s}'\n", .{o});
        return 1;
    };
    if (group) |gname| gid = (if (std.fmt.parseInt(u32, gname, 10)) |v| v else |_| u.findGroup(gname)) orelse {
        u.errf("install: invalid group '{s}'\n", .{gname});
        return 1;
    };
    var rc: u8 = 0;
    const mkdirP = struct {
        fn go(path: []const u8, m: u32, verb: bool) bool {
            var i: usize = 0;
            while (i <= path.len) {
                const next = std.mem.indexOfScalarPos(u8, path, i, '/') orelse path.len;
                if (next > 0) {
                    const prefix = path[0..next];
                    if (!std.mem.eql(u8, prefix, "/") and u.stat(prefix, true) == null) {
                        const r = linux.mkdir(u.zstr(prefix), if (next >= path.len) m else 0o755);
                        if (!u.ok(r)) {
                            u.errf("install: cannot create directory '{s}': {s}\n", .{ prefix, u.strerr(u.errno(r)) });
                            return false;
                        }
                        if (verb) u.outf("install: creating directory '{s}'\n", .{prefix});
                    }
                }
                i = next + 1;
            }
            return true;
        }
    }.go;
    if (dirs) {
        if (p.operands.items.len == 0) {
            u.err("install: missing file operand\nTry 'install --help' for more information.\n");
            return 1;
        }
        for (p.operands.items) |d| {
            if (!mkdirP(d, mode, verbose)) {
                rc = 1;
                continue;
            }
            _ = linux.chmod(u.zstr(d), mode);
            if (uid != 0xffffffff or gid != 0xffffffff) _ = linux.chown(u.zstr(d), uid, gid);
        }
        return rc;
    }
    var ops = p.operands.items;
    if (ops.len == 0) {
        u.err("install: missing file operand\nTry 'install --help' for more information.\n");
        return 1;
    }
    var dest: []const u8 = undefined;
    var into_dir = false;
    if (target_dir) |t| {
        dest = t;
        into_dir = true;
        if (u.stat(t, true) == null and !mkparents) {
            u.errf("install: failed to access '{s}': No such file or directory\n", .{t});
            return 1;
        }
    } else {
        if (ops.len == 1) {
            u.errf("install: missing destination file operand after '{s}'\nTry 'install --help' for more information.\n", .{ops[0]});
            return 1;
        }
        dest = ops[ops.len - 1];
        ops = ops[0 .. ops.len - 1];
        if (!no_target and u.isDir(dest)) into_dir = true;
        if (!into_dir and ops.len > 1) {
            if (u.stat(dest, true) == null) u.errf("install: target '{s}': No such file or directory\n", .{dest}) else u.errf("install: target '{s}' is not a directory\n", .{dest});
            return 1;
        }
    }
    if (into_dir and mkparents and !u.isDir(dest)) _ = mkdirP(dest, 0o755, verbose);
    if (into_dir and !u.isDir(dest)) {
        u.errf("install: target '{s}' is not a directory\n", .{dest});
        return 1;
    }
    for (ops) |src| {
        const dst = if (into_dir) joinPath(dest, baseName(src)) else dest;
        const sst = u.stat(src, true) orelse {
            u.errf("install: cannot stat '{s}': No such file or directory\n", .{src});
            rc = 1;
            continue;
        };
        if (sst.mode & linux.S.IFMT == linux.S.IFDIR) {
            u.errf("install: omitting directory '{s}'\n", .{src});
            rc = 1;
            continue;
        }
        if (mkparents and !into_dir) {
            if (std.fs.path.dirname(dst)) |dd_| {
                if (dd_.len > 0 and !u.isDir(dd_)) _ = mkdirP(dd_, 0o755, verbose);
            }
        }
        if (u.stat(dst, true)) |d| {
            if (d.dev == sst.dev and d.ino == sst.ino) {
                u.errf("install: '{s}' and '{s}' are the same file\n", .{ src, dst });
                rc = 1;
                continue;
            }
            if (compare) {
                // skip when contents, mode and owner already match
                const a = readWhole(src);
                const b = readWhole(dst);
                if (a != null and b != null and std.mem.eql(u8, a.?, b.?) and (d.mode & 0o7777) == mode) continue;
            }
        }
        var backup_name: ?[]const u8 = null;
        if (backup and u.stat(dst, false) != null) {
            backup_name = std.fmt.allocPrint(u.alloc, "{s}{s}", .{ dst, suffix }) catch null;
            if (backup_name) |b| _ = linux.rename(u.zstr(dst), u.zstr(b));
        } else if (u.stat(dst, false) != null) {
            _ = linux.unlink(u.zstr(dst));
        }
        const sfd = linux.open(u.zstr(src), .{ .ACCMODE = .RDONLY }, 0);
        if (!u.ok(sfd)) {
            u.errf("install: cannot open '{s}' for reading: {s}\n", .{ src, u.strerr(u.errno(sfd)) });
            rc = 1;
            continue;
        }
        const dfd = linux.open(u.zstr(dst), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
        if (!u.ok(dfd)) {
            u.errf("install: cannot create regular file '{s}': {s}\n", .{ dst, u.strerr(u.errno(dfd)) });
            _ = linux.close(@intCast(sfd));
            rc = 1;
            continue;
        }
        var buf: [65536]u8 = undefined;
        while (true) {
            const r = linux.read(@intCast(sfd), &buf, buf.len);
            if (!u.ok(r) or r == 0) break;
            if (!writeAll(@intCast(dfd), buf[0..r])) {
                rc = 1;
                break;
            }
        }
        _ = linux.fchmod(@intCast(dfd), mode);
        if (uid != 0xffffffff or gid != 0xffffffff) _ = linux.fchown(@intCast(dfd), uid, gid);
        _ = linux.close(@intCast(sfd));
        _ = linux.close(@intCast(dfd));
        if (preserve_ts) {
            const Time64 = extern struct { sec: i64, nsec: i64 };
            const times = [_]Time64{ .{ .sec = sst.atime, .nsec = sst.atime_nsec }, .{ .sec = sst.mtime, .nsec = sst.mtime_nsec } };
            const sys: linux.SYS = if (@sizeOf(usize) == 4) .utimensat_time64 else .utimensat;
            _ = linux.syscall4(sys, @bitCast(@as(isize, std.posix.AT.FDCWD)), @intFromPtr(u.zstr(dst).ptr), @intFromPtr(&times), 0);
        }
        if (verbose) {
            if (backup_name) |b| u.outf("'{s}' -> '{s}' (backup: '{s}')\n", .{ src, dst, b }) else u.outf("'{s}' -> '{s}'\n", .{ src, dst });
        }
    }
    return rc;
}
