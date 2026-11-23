// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// switch_root - util-linux style: move the mounted new root to /, remove the initramfs contents, exec init.
// Everything destructive is guarded: it only runs as PID 1 on a ramfs/tmpfs root.
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const c = @cImport({
    @cInclude("sys/statfs.h");
});

const RAMFS_MAGIC: u64 = 0x858458f6;
const TMPFS_MAGIC: u64 = 0x01021994;

fn deleteContents(dirfd: i32, root_dev: u64) void {
    // work on a duplicate so the caller's descriptor stays usable
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(dirfd, &buf, buf.len);
        if (!u.ok(n) or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const de: *linux.dirent64 = @ptrCast(@alignCast(&buf[off]));
            off += de.reclen;
            const name_ptr: [*:0]const u8 = @ptrCast(&de.name);
            const name = std.mem.sliceTo(name_ptr, 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var sx: linux.Statx = undefined;
            if (!u.ok(linux.statx(dirfd, name_ptr, 0x100, .{ .TYPE = true }, &sx))) continue;
            const dev = @as(u64, sx.dev_major) << 32 | sx.dev_minor;
            if (dev != root_dev) continue; // another filesystem (a mount point): leave it alone
            if (sx.mode & linux.S.IFMT == linux.S.IFDIR) {
                const sub = linux.openat(dirfd, name_ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
                if (u.ok(sub)) {
                    deleteContents(@intCast(sub), root_dev);
                    _ = linux.close(@intCast(sub));
                }
                _ = linux.unlinkat(dirfd, name_ptr, linux.AT.REMOVEDIR);
            } else {
                _ = linux.unlinkat(dirfd, name_ptr, 0);
            }
        }
    }
}

pub fn run(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "help", .key = 'h' },
        .{ .name = "version", .key = 'V' },
        .{ .key = 'c', .arg = .req },
    };
    var p = g.Parser.init("switch_root", args, &opts);
    p.stop_at_operand = true;
    var console: ?[]const u8 = null;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'c' => console = it.val,
            'h' => {
                u.out("\nUsage:\n switch_root [options] <newrootdir> <init> <args to init>\n\nSwitch to another filesystem as the root of the mount tree.\n\nOptions:\n -h, --help     display this help\n -V, --version  display version\n");
                return 0;
            },
            'V' => {
                u.out("switch_root from util-linux 2.41.5\n");
                return 0;
            },
            else => {},
        }
    }
    const rest = p.rest();
    if (rest.len < 2 or rest[0].len == 0 or rest[1].len == 0) {
        u.err("switch_root: not enough arguments\nTry 'switch_root --help' for more information.\n");
        return 1;
    }
    const newroot = rest[0];
    const init = rest[1];
    if (!u.ok(linux.chdir(u.zstr(newroot)))) {
        u.errf("switch_root: stat of {s} failed: {s}\nswitch_root: failed. Sorry.\n", .{ newroot, u.strerr(u.errno(linux.chdir(u.zstr(newroot)))) });
        return 1;
    }
    const nst = u.stat(".", true) orelse {
        u.errf("switch_root: failed to stat directory {s}\n", .{newroot});
        return 1;
    };
    const rst = u.stat("/", true) orelse {
        u.err("switch_root: failed to stat directory /\n");
        return 1;
    };
    if (nst.dev == rst.dev) {
        u.err("switch_root: old root and new root are on the same filesystem\n");
        return 1;
    }
    if (std.os.linux.getpid() != 1) {
        u.err("switch_root: not running as PID 1\n");
        return 1;
    }
    var sfs: c.struct_statfs = undefined;
    if (c.statfs("/", &sfs) != 0 or (@as(u64, @intCast(sfs.f_type)) != RAMFS_MAGIC and @as(u64, @intCast(sfs.f_type)) != TMPFS_MAGIC)) {
        u.err("switch_root: old root filesystem is not an initramfs\n");
        return 1;
    }
    const ist = u.stat(init, true) orelse {
        u.errf("switch_root: cannot access {s}\n", .{init});
        return 1;
    };
    if (ist.mode & linux.S.IFMT != linux.S.IFREG or ist.mode & 0o111 == 0) {
        u.errf("switch_root: cannot access {s}\n", .{init});
        return 1;
    }
    const rootfd = linux.open("/", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (!u.ok(rootfd)) {
        u.err("switch_root: failed to open /\n");
        return 1;
    }
    if (!u.ok(linux.mount(".", "/", null, linux.MS.MOVE, 0))) {
        u.err("switch_root: failed to mount moving /\n");
        return 1;
    }
    if (!u.ok(linux.chroot("."))) {
        u.err("switch_root: failed to change root\n");
        return 1;
    }
    _ = linux.chdir("/");
    if (console) |cn| {
        const cfd = linux.open(u.zstr(cn), .{ .ACCMODE = .RDWR }, 0);
        if (u.ok(cfd)) {
            _ = linux.dup2(@intCast(cfd), 0);
            _ = linux.dup2(@intCast(cfd), 1);
            _ = linux.dup2(@intCast(cfd), 2);
            if (cfd > 2) _ = linux.close(@intCast(cfd));
        }
    }
    deleteContents(@intCast(rootfd), rst.dev);
    _ = linux.close(@intCast(rootfd));
    var av = u.Vec(?[*:0]const u8).init(u.alloc);
    for (rest[1..]) |a| av.push(u.zstr(a).ptr);
    av.push(null);
    var pb: [u.PATH_MAX]u8 = undefined;
    const path = u.findInPath(init, &pb) orelse u.zstr(init);
    _ = linux.execve(path.ptr, @ptrCast(av.items.ptr), u.envp(&.{}));
    u.errf("switch_root: failed to execute {s}\n", .{init});
    return 1;
}
