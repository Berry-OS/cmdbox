// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// mount / umount - util-linux compatible: listing from mountinfo, fstab lookup, -a, bind/move/remount/propagation,
// loop devices, label/uuid sources, filesystem detection, mount helpers, fsopen-based mounting
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");

// ---------------------------------------------------------------- constants
const MS_RDONLY: u64 = 1;
const MS_NOSUID: u64 = 2;
const MS_NODEV: u64 = 4;
const MS_NOEXEC: u64 = 8;
const MS_SYNCHRONOUS: u64 = 16;
const MS_REMOUNT: u64 = 32;
const MS_MANDLOCK: u64 = 64;
const MS_DIRSYNC: u64 = 128;
const MS_NOSYMFOLLOW: u64 = 256;
const MS_NOATIME: u64 = 1024;
const MS_NODIRATIME: u64 = 2048;
const MS_BIND: u64 = 4096;
const MS_MOVE: u64 = 8192;
const MS_REC: u64 = 16384;
const MS_SILENT: u64 = 32768;
const MS_UNBINDABLE: u64 = 1 << 17;
const MS_PRIVATE: u64 = 1 << 18;
const MS_SLAVE: u64 = 1 << 19;
const MS_SHARED: u64 = 1 << 20;
const MS_RELATIME: u64 = 1 << 21;
const MS_I_VERSION: u64 = 1 << 23;
const MS_STRICTATIME: u64 = 1 << 24;
const MS_LAZYTIME: u64 = 1 << 25;

const MOUNT_ATTR_RDONLY: u32 = 1;
const MOUNT_ATTR_NOSUID: u32 = 2;
const MOUNT_ATTR_NODEV: u32 = 4;
const MOUNT_ATTR_NOEXEC: u32 = 8;
const MOUNT_ATTR_NOATIME: u32 = 0x10;
const MOUNT_ATTR_STRICTATIME: u32 = 0x20;
const MOUNT_ATTR_NODIRATIME: u32 = 0x80;
const MOUNT_ATTR_NOSYMFOLLOW: u32 = 0x200000;

const EXIT_USAGE: u8 = 1;
const EXIT_FAIL: u8 = 32;
const EXIT_SOME: u8 = 64;

// stdout of mount is block buffered when it is a pipe, helpers write straight to the inherited descriptor
var ob: u.Vec(u8) = undefined;
var ob_ready = false;

fn bout(comptime fmt: []const u8, args: anytype) void {
    if (!ob_ready) {
        ob = u.Vec(u8).init(u.alloc);
        ob_ready = true;
    }
    ob.pushSlice(std.fmt.allocPrint(u.alloc, fmt, args) catch return);
}

fn flushOut() void {
    if (ob_ready and ob.items.len > 0) u.out(ob.items);
    if (ob_ready) ob.items.len = 0;
}

// ---------------------------------------------------------------- file helpers
pub fn readFile(path: []const u8) ?[]u8 {
    const rc = linux.open(u.zstr(path), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(rc)) return null;
    defer _ = linux.close(@intCast(rc));
    var data = u.Vec(u8).init(u.alloc);
    var buf: [1 << 15]u8 = undefined;
    while (true) {
        const r = linux.read(@intCast(rc), &buf, buf.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r)) return null;
        if (r == 0) break;
        data.pushSlice(buf[0..r]);
    }
    return data.items;
}

fn unescapeOct(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var o = u.Vec(u8).init(u.alloc);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 3 < s.len + 0 and i + 3 <= s.len - 1 + 1 and std.ascii.isDigit(s[i + 1])) {
            const v = std.fmt.parseInt(u8, s[i + 1 .. i + 4], 8) catch {
                o.push(s[i]);
                continue;
            };
            o.push(v);
            i += 3;
        } else o.push(s[i]);
    }
    return o.items;
}

pub fn realpath(path: []const u8) ?[]const u8 {
    const fd = linux.open(u.zstr(path), .{ .PATH = true }, 0);
    if (!u.ok(fd)) return null;
    defer _ = linux.close(@intCast(fd));
    var lp: [48]u8 = undefined;
    const link = std.fmt.bufPrint(&lp, "/proc/self/fd/{d}", .{fd}) catch return null;
    var buf: [u.PATH_MAX]u8 = undefined;
    const r = linux.readlink(u.zstr(link), &buf, buf.len);
    if (!u.ok(r)) return null;
    return u.alloc.dupe(u8, buf[0..r]) catch null;
}

fn canon(path: []const u8) []const u8 {
    if (path.len == 0) return path;
    if (realpath(path)) |p| return p;
    return path;
}

// ---------------------------------------------------------------- mountinfo / fstab
pub const MI = struct {
    maj: u32,
    min: u32,
    root: []const u8,
    target: []const u8,
    vfs: []const u8,
    fstype: []const u8,
    source: []const u8,
    sup: []const u8,
};

pub fn readMountinfo() []MI {
    var out = u.Vec(MI).init(u.alloc);
    const d = readFile("/proc/self/mountinfo") orelse return out.items;
    var lines = std.mem.splitScalar(u8, d, '\n');
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        var it = std.mem.tokenizeScalar(u8, l, ' ');
        _ = it.next(); // id
        _ = it.next(); // parent
        const mm = it.next() orelse continue;
        const root = it.next() orelse continue;
        const target = it.next() orelse continue;
        const vfs = it.next() orelse continue;
        while (it.next()) |t| if (std.mem.eql(u8, t, "-")) break;
        const fstype = it.next() orelse continue;
        const source = it.next() orelse continue;
        const sup = it.next() orelse "";
        const colon = std.mem.indexOfScalar(u8, mm, ':') orelse continue;
        out.push(.{
            .maj = std.fmt.parseInt(u32, mm[0..colon], 10) catch 0,
            .min = std.fmt.parseInt(u32, mm[colon + 1 ..], 10) catch 0,
            .root = unescapeOct(root),
            .target = unescapeOct(target),
            .vfs = vfs,
            .fstype = fstype,
            .source = unescapeOct(source),
            .sup = sup,
        });
    }
    return out.items;
}

pub fn deviceName(m: MI) []const u8 {
    if (!std.mem.eql(u8, m.source, "/dev/root")) return m.source;
    const p = std.fmt.allocPrint(u.alloc, "/sys/dev/block/{d}:{d}/uevent", .{ m.maj, m.min }) catch return m.source;
    const d = readFile(p) orelse return m.source;
    var lines = std.mem.splitScalar(u8, d, '\n');
    while (lines.next()) |l| if (std.mem.startsWith(u8, l, "DEVNAME=")) {
        return std.fmt.allocPrint(u.alloc, "/dev/{s}", .{l[8..]}) catch m.source;
    };
    return m.source;
}

var utab_cache: ?[]const [2][]const u8 = null;

/// user space options recorded by mount helpers (udisks and friends) in /run/mount/utab
fn utabOpts(target: []const u8) ?[]const u8 {
    if (utab_cache == null) {
        var out = u.Vec([2][]const u8).init(u.alloc);
        if (readFile("/run/mount/utab")) |d| {
            var lines = std.mem.splitScalar(u8, d, '\n');
            while (lines.next()) |l| {
                var tgt: []const u8 = "";
                var op: []const u8 = "";
                var it = std.mem.tokenizeScalar(u8, l, ' ');
                while (it.next()) |kv| {
                    if (std.mem.startsWith(u8, kv, "TARGET=")) tgt = unescapeOct(kv[7..]);
                    if (std.mem.startsWith(u8, kv, "OPTS=")) op = unescapeOct(kv[5..]);
                }
                if (tgt.len > 0 and op.len > 0) out.push(.{ tgt, op });
            }
        }
        utab_cache = out.items;
    }
    for (utab_cache.?) |e| if (std.mem.eql(u8, e[0], target)) return e[1];
    return null;
}

fn mergedOpts(m: MI) []const u8 {
    var o = u.Vec(u8).init(u.alloc);
    var sb_ro = false;
    var sit = std.mem.splitScalar(u8, m.sup, ',');
    while (sit.next()) |x| if (std.mem.eql(u8, x, "ro")) {
        sb_ro = true;
    };
    if (sb_ro and std.mem.startsWith(u8, m.vfs, "rw")) {
        o.pushSlice("ro");
        o.pushSlice(m.vfs[2..]);
    } else o.pushSlice(m.vfs);
    var it = std.mem.splitScalar(u8, m.sup, ',');
    while (it.next()) |s| {
        if (s.len == 0) continue;
        if (std.mem.eql(u8, s, "rw") or std.mem.eql(u8, s, "ro")) continue;
        o.push(',');
        o.pushSlice(s);
    }
    if (utabOpts(m.target)) |uo| {
        // util-linux does not list the udisks "uhelper=" bookkeeping option
        var uit = std.mem.splitScalar(u8, uo, ',');
        while (uit.next()) |x| {
            if (x.len == 0 or std.mem.startsWith(u8, x, "uhelper=")) continue;
            o.push(',');
            o.pushSlice(x);
        }
    }
    return o.items;
}

pub const Fstab = struct { source: []const u8, target: []const u8, fstype: []const u8, opts: []const u8 };

pub fn readFstab(path: []const u8) []Fstab {
    var out = u.Vec(Fstab).init(u.alloc);
    const d = readFile(path) orelse return out.items;
    var lines = std.mem.splitScalar(u8, d, '\n');
    while (lines.next()) |l0| {
        const l = std.mem.trim(u8, l0, " \t\r");
        if (l.len == 0 or l[0] == '#') continue;
        var it = std.mem.tokenizeAny(u8, l, " \t");
        const src = it.next() orelse continue;
        const tgt = it.next() orelse continue;
        const fst = it.next() orelse "auto";
        const opts = it.next() orelse "defaults";
        out.push(.{ .source = unescapeOct(src), .target = unescapeOct(tgt), .fstype = fst, .opts = opts });
    }
    return out.items;
}

// ---------------------------------------------------------------- labels / tags
pub fn byLink(dir: []const u8, name: []const u8) ?[]const u8 {
    // udev escapes unusual characters as \xNN
    var esc = u.Vec(u8).init(u.alloc);
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '#' or ch == '+' or ch == '-' or ch == '.' or ch == ':' or ch == '=' or ch == '@' or ch == '_') esc.push(ch) else esc.pushSlice(std.fmt.allocPrint(u.alloc, "\\x{x:0>2}", .{ch}) catch "");
    }
    const p = std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ dir, esc.items }) catch return null;
    return realpath(p);
}

pub fn resolveTag(src: []const u8) ?[]const u8 {
    const tags = [_]struct { k: []const u8, dir: []const u8 }{
        .{ .k = "LABEL=", .dir = "/dev/disk/by-label" },
        .{ .k = "UUID=", .dir = "/dev/disk/by-uuid" },
        .{ .k = "PARTLABEL=", .dir = "/dev/disk/by-partlabel" },
        .{ .k = "PARTUUID=", .dir = "/dev/disk/by-partuuid" },
        .{ .k = "ID=", .dir = "/dev/disk/by-id" },
    };
    for (tags) |t| if (std.mem.startsWith(u8, src, t.k)) {
        var v = src[t.k.len..];
        if (v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0]) v = v[1 .. v.len - 1];
        var val = v;
        if (std.mem.eql(u8, t.k, "UUID=") or std.mem.eql(u8, t.k, "PARTUUID=")) {
            const low = u.alloc.alloc(u8, v.len) catch return null;
            for (v, 0..) |ch, i| low[i] = std.ascii.toLower(ch);
            val = low;
        }
        return byLink(t.dir, val);
    };
    return null;
}

pub fn isTagPub(src: []const u8) bool {
    return isTag(src);
}

fn isTag(src: []const u8) bool {
    for ([_][]const u8{ "LABEL=", "UUID=", "PARTLABEL=", "PARTUUID=", "ID=" }) |k| if (std.mem.startsWith(u8, src, k)) return true;
    return false;
}

fn labelOf(dev: []const u8) ?[]const u8 {
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir("/dev/disk/by-label", &ents)) return null;
    const rp = realpath(dev) orelse return null;
    for (ents.items) |e| {
        const lp = std.fmt.allocPrint(u.alloc, "/dev/disk/by-label/{s}", .{e.name}) catch continue;
        const t = realpath(lp) orelse continue;
        if (std.mem.eql(u8, t, rp)) return unescapeX(e.name);
    }
    return null;
}

fn unescapeX(s: []const u8) []const u8 {
    if (std.mem.indexOf(u8, s, "\\x") == null) return s;
    var o = u.Vec(u8).init(u.alloc);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 3 < s.len + 1 and i + 3 <= s.len - 1 + 1 and s[i + 1] == 'x' and i + 3 < s.len + 0 + 1) {
            if (i + 4 <= s.len) {
                const v = std.fmt.parseInt(u8, s[i + 2 .. i + 4], 16) catch {
                    o.push(s[i]);
                    continue;
                };
                o.push(v);
                i += 3;
                continue;
            }
        }
        o.push(s[i]);
    }
    return o.items;
}

// ---------------------------------------------------------------- options
const Opts = struct {
    flags: u64 = 0,
    prop: u64 = 0,
    bind: bool = false,
    rec: bool = false,
    move: bool = false,
    remount: bool = false,
    fs: u.Vec(u8),
    user: u.Vec(u8),
    noauto: bool = false,
    nofail: bool = false,
    loop: bool = false,
    loop_offset: u64 = 0,
    loop_size: u64 = 0,
    user_mount: bool = false,
    ro_set: bool = false,
    rw_set: bool = false,
    explicit_atime: bool = false,
};

fn newOpts() Opts {
    return .{ .fs = u.Vec(u8).init(u.alloc), .user = u.Vec(u8).init(u.alloc) };
}

const VfsOpt = struct { name: []const u8, set: u64 = 0, clear: u64 = 0 };
const vfs_opts = [_]VfsOpt{
    .{ .name = "ro", .set = MS_RDONLY },
    .{ .name = "rw", .clear = MS_RDONLY },
    .{ .name = "suid", .clear = MS_NOSUID },
    .{ .name = "nosuid", .set = MS_NOSUID },
    .{ .name = "dev", .clear = MS_NODEV },
    .{ .name = "nodev", .set = MS_NODEV },
    .{ .name = "exec", .clear = MS_NOEXEC },
    .{ .name = "noexec", .set = MS_NOEXEC },
    .{ .name = "sync", .set = MS_SYNCHRONOUS },
    .{ .name = "async", .clear = MS_SYNCHRONOUS },
    .{ .name = "mand", .set = MS_MANDLOCK },
    .{ .name = "nomand", .clear = MS_MANDLOCK },
    .{ .name = "dirsync", .set = MS_DIRSYNC },
    .{ .name = "nosymfollow", .set = MS_NOSYMFOLLOW },
    .{ .name = "symfollow", .clear = MS_NOSYMFOLLOW },
    .{ .name = "noatime", .set = MS_NOATIME },
    .{ .name = "atime", .clear = MS_NOATIME },
    .{ .name = "nodiratime", .set = MS_NODIRATIME },
    .{ .name = "diratime", .clear = MS_NODIRATIME },
    .{ .name = "relatime", .set = MS_RELATIME },
    .{ .name = "norelatime", .clear = MS_RELATIME },
    .{ .name = "strictatime", .set = MS_STRICTATIME },
    .{ .name = "nostrictatime", .clear = MS_STRICTATIME },
    .{ .name = "lazytime", .set = MS_LAZYTIME },
    .{ .name = "nolazytime", .clear = MS_LAZYTIME },
    .{ .name = "iversion", .set = MS_I_VERSION },
    .{ .name = "noiversion", .clear = MS_I_VERSION },
    .{ .name = "silent", .set = MS_SILENT },
    .{ .name = "loud", .clear = MS_SILENT },
};

fn parseOpts(o: *Opts, s: []const u8) void {
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |raw| {
        const opt = std.mem.trim(u8, raw, " ");
        if (opt.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, opt, '=');
        const key = if (eq) |e| opt[0..e] else opt;
        var matched = false;
        for (vfs_opts) |v| if (std.mem.eql(u8, v.name, key) and eq == null) {
            const atime_mask: u64 = MS_NOATIME | MS_RELATIME | MS_STRICTATIME;
            if (v.set & atime_mask != 0) o.flags &= ~atime_mask;
            o.flags |= v.set;
            o.flags &= ~v.clear;
            if (std.mem.eql(u8, key, "ro")) {
                o.ro_set = true;
                o.rw_set = false;
            } else if (std.mem.eql(u8, key, "rw")) {
                o.rw_set = true;
                o.ro_set = false;
            }
            matched = true;
        };
        if (matched) continue;
        if (eq == null) {
            if (std.mem.eql(u8, key, "remount")) {
                o.remount = true;
                continue;
            }
            if (std.mem.eql(u8, key, "bind")) {
                o.bind = true;
                continue;
            }
            if (std.mem.eql(u8, key, "rbind")) {
                o.bind = true;
                o.rec = true;
                continue;
            }
            if (std.mem.eql(u8, key, "move")) {
                o.move = true;
                continue;
            }
            if (std.mem.eql(u8, key, "defaults")) {
                o.flags &= ~(MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC | MS_SYNCHRONOUS);
                continue;
            }
            const props = [_]struct { n: []const u8, v: u64 }{
                .{ .n = "shared", .v = MS_SHARED }, .{ .n = "rshared", .v = MS_SHARED | MS_REC },
                .{ .n = "slave", .v = MS_SLAVE },   .{ .n = "rslave", .v = MS_SLAVE | MS_REC },
                .{ .n = "private", .v = MS_PRIVATE }, .{ .n = "rprivate", .v = MS_PRIVATE | MS_REC },
                .{ .n = "unbindable", .v = MS_UNBINDABLE }, .{ .n = "runbindable", .v = MS_UNBINDABLE | MS_REC },
            };
            var pm = false;
            for (props) |pp| if (std.mem.eql(u8, pp.n, key)) {
                o.prop |= pp.v;
                pm = true;
            };
            if (pm) continue;
            if (std.mem.eql(u8, key, "noauto")) {
                o.noauto = true;
                o.user.pushSlice(if (o.user.items.len > 0) ",noauto" else "noauto");
                continue;
            }
            if (std.mem.eql(u8, key, "auto")) continue;
            if (std.mem.eql(u8, key, "nofail")) {
                o.nofail = true;
                o.user.pushSlice(if (o.user.items.len > 0) ",nofail" else "nofail");
                continue;
            }
            if (std.mem.eql(u8, key, "user") or std.mem.eql(u8, key, "users") or std.mem.eql(u8, key, "owner") or std.mem.eql(u8, key, "group")) {
                o.user_mount = true;
                o.flags |= MS_NOEXEC | MS_NOSUID | MS_NODEV;
                o.user.pushSlice(if (o.user.items.len > 0) "," else "");
                o.user.pushSlice(key);
                continue;
            }
            if (std.mem.eql(u8, key, "nouser") or std.mem.eql(u8, key, "_netdev") or std.mem.eql(u8, key, "nogroup")) continue;
            if (std.mem.eql(u8, key, "loop")) {
                o.loop = true;
                continue;
            }
        } else {
            if (std.mem.eql(u8, key, "loop")) {
                o.loop = true;
                continue;
            }
            if (std.mem.eql(u8, key, "offset")) {
                o.loop = true;
                o.loop_offset = std.fmt.parseInt(u64, opt[eq.? + 1 ..], 0) catch 0;
                continue;
            }
            if (std.mem.eql(u8, key, "sizelimit")) {
                o.loop = true;
                o.loop_size = std.fmt.parseInt(u64, opt[eq.? + 1 ..], 0) catch 0;
                continue;
            }
            if (std.mem.eql(u8, key, "comment") or std.mem.startsWith(u8, key, "x-")) {
                o.user.pushSlice(if (o.user.items.len > 0) "," else "");
                o.user.pushSlice(opt);
                continue;
            }
        }
        if (std.mem.startsWith(u8, key, "x-") or std.mem.startsWith(u8, key, "X-")) {
            o.user.pushSlice(if (o.user.items.len > 0) "," else "");
            o.user.pushSlice(opt);
            continue;
        }
        // everything else belongs to the filesystem
        if (o.fs.items.len > 0) o.fs.push(',');
        o.fs.pushSlice(opt);
    }
}

// ---------------------------------------------------------------- filesystem detection
pub fn detectFs(dev: []const u8) ?[]const u8 {
    const fd = linux.open(u.zstr(dev), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(fd)) return null;
    defer _ = linux.close(@intCast(fd));
    var buf: [0x11000]u8 = undefined;
    var got: usize = 0;
    while (got < buf.len) {
        const r = linux.pread(@intCast(fd), buf[got..].ptr, buf.len - got, @intCast(got));
        if (!u.ok(r) or r == 0) break;
        got += r;
    }
    const b = buf[0..got];
    const at = struct {
        fn f(d: []const u8, off: usize, s: []const u8) bool {
            return d.len >= off + s.len and std.mem.eql(u8, d[off .. off + s.len], s);
        }
    }.f;
    if (at(b, 0x400 + 56, "\x53\xEF")) {
        // ext2/3/4: distinguish by feature flags
        if (b.len > 0x400 + 0x64) {
            const incompat = std.mem.readInt(u32, b[0x400 + 0x60 ..][0..4], .little);
            const compat = std.mem.readInt(u32, b[0x400 + 0x5c ..][0..4], .little);
            const ro_compat = std.mem.readInt(u32, b[0x400 + 0x64 ..][0..4], .little);
            if (incompat & 0x0040 != 0 or incompat & 0x0200 != 0 or ro_compat & 0x0008 != 0 or ro_compat & 0x0010 != 0) return "ext4";
            if (compat & 0x0004 != 0) return "ext3";
        }
        return "ext2";
    }
    if (at(b, 0, "XFSB")) return "xfs";
    if (at(b, 0x10040, "_BHRfS_M")) return "btrfs";
    if (at(b, 3, "NTFS    ")) return "ntfs";
    if (at(b, 3, "EXFAT   ")) return "exfat";
    if (at(b, 0, "hsqs") or at(b, 0, "sqsh")) return "squashfs";
    if (at(b, 0x8001, "CD001")) return "iso9660";
    if (at(b, 0x400, "\x10\x20\xF5\xF2")) return "f2fs";
    if (at(b, 0x400, "\xE2\xE1\xF5\xE0")) return "erofs";
    if (at(b, 0x36, "FAT12") or at(b, 0x36, "FAT16") or at(b, 0x52, "FAT32")) return "vfat";
    if (at(b, 0x1fe, "\x55\xAA") and at(b, 3, "MSDOS") or at(b, 3, "mkfs.fat") or at(b, 3, "MSWIN")) return "vfat";
    if (at(b, 0xff6, "SWAPSPACE2") or at(b, 0xff6, "SWAP-SPACE")) return "swap";
    return null;
}

fn kernelFilesystems() []const []const u8 {
    var out = u.Vec([]const u8).init(u.alloc);
    const d = readFile("/proc/filesystems") orelse return out.items;
    var lines = std.mem.splitScalar(u8, d, '\n');
    while (lines.next()) |l| {
        if (l.len == 0 or l[0] == 'n') continue; // "nodev ..." entries are pseudo filesystems
        const nm = std.mem.trim(u8, l, " \t");
        if (nm.len > 0) out.push(nm);
    }
    return out.items;
}

// ---------------------------------------------------------------- loop devices
const LoopInfo64 = extern struct {
    device: u64,
    inode: u64,
    rdevice: u64,
    offset: u64,
    sizelimit: u64,
    number: u32,
    encrypt_type: u32,
    encrypt_key_size: u32,
    flags: u32,
    file_name: [64]u8,
    crypt_name: [64]u8,
    encrypt_key: [32]u8,
    init: [2]u64,
};

const LoopConfig = extern struct { fd: u32, block_size: u32, info: LoopInfo64, reserved: [8]u64 };

var loop_fd: i32 = -1;

fn setupLoop(file: []const u8, ro: bool, offset: u64, sizelimit: u64) ?[]const u8 {
    const cfd = linux.open("/dev/loop-control", .{ .ACCMODE = .RDWR }, 0);
    if (!u.ok(cfd)) return null;
    const nr = linux.ioctl(@intCast(cfd), 0x4C82, 0);
    _ = linux.close(@intCast(cfd));
    if (@as(isize, @bitCast(nr)) < 0) return null;
    const dev = std.fmt.allocPrint(u.alloc, "/dev/loop{d}", .{@as(u32, @intCast(nr))}) catch return null;
    var rdonly = ro;
    var bfd = linux.open(u.zstr(file), .{ .ACCMODE = if (ro) .RDONLY else .RDWR }, 0);
    if (!u.ok(bfd)) {
        bfd = linux.open(u.zstr(file), .{ .ACCMODE = .RDONLY }, 0);
        if (!u.ok(bfd)) return null;
        rdonly = true;
    }
    defer _ = linux.close(@intCast(bfd));
    const lfd = linux.open(u.zstr(dev), .{ .ACCMODE = if (rdonly) .RDONLY else .RDWR }, 0);
    if (!u.ok(lfd)) return null;
    // autoclear detaches the device when the last descriptor goes away: keep this one until the mount is done
    loop_fd = @intCast(lfd);
    var cfg: LoopConfig = undefined;
    @memset(std.mem.asBytes(&cfg), 0);
    cfg.fd = @intCast(bfd);
    cfg.info.offset = offset;
    cfg.info.sizelimit = sizelimit;
    cfg.info.flags = (if (rdonly) @as(u32, 1) else 0) | 4; // read-only, autoclear
    const n = @min(file.len, 63);
    @memcpy(cfg.info.file_name[0..n], file[0..n]);
    if (!u.ok(linux.ioctl(@intCast(lfd), 0x4C0A, @intFromPtr(&cfg)))) {
        _ = linux.close(@intCast(lfd));
        loop_fd = -1;
        return null;
    }
    return dev;
}

// ---------------------------------------------------------------- listing
const Cfg = struct {
    verbose: u32 = 0,
    fake: bool = false,
    nomtab: bool = false,
    all: bool = false,
    labels: bool = false,
    types: ?[]const u8 = null,
    opt_filter: ?[]const u8 = null,
    options: u.Vec(u8),
    fstab_path: []const u8 = "/etc/fstab",
    readonly_flag: bool = false,
    readwrite_flag: bool = false,
    bind: bool = false,
    rbind: bool = false,
    move: bool = false,
    props: u64 = 0,
    label: ?[]const u8 = null,
    uuid: ?[]const u8 = null,
    no_canon: bool = false,
    internal_only: bool = false,
    source_flag: ?[]const u8 = null,
    target_flag: ?[]const u8 = null,
};

fn typeMatches(types: []const u8, fst: []const u8) bool {
    var t = types;
    var neg = false;
    if (std.mem.startsWith(u8, t, "no")) {
        neg = true;
        t = t[2..];
    }
    var it = std.mem.splitScalar(u8, t, ',');
    var any = false;
    while (it.next()) |x0| {
        var x = x0;
        if (neg and std.mem.startsWith(u8, x, "no")) x = x[2..];
        if (std.mem.eql(u8, x, fst)) any = true;
    }
    return any != neg;
}

fn optsMatch(filter: []const u8, opts: []const u8) bool {
    // -O: every listed option must be present; "no" prefixed entries must be absent
    var it = std.mem.splitScalar(u8, filter, ',');
    while (it.next()) |f| {
        if (f.len == 0) continue;
        var present = false;
        var oit = std.mem.splitScalar(u8, opts, ',');
        while (oit.next()) |o| if (std.mem.eql(u8, o, f)) {
            present = true;
        };
        if (std.mem.startsWith(u8, f, "no")) {
            // "noauto" style: absent unless the option literally exists
            var lit = false;
            var oit2 = std.mem.splitScalar(u8, opts, ',');
            while (oit2.next()) |o| if (std.mem.eql(u8, o, f)) {
                lit = true;
            };
            if (!lit) {
                var pos = false;
                var oit3 = std.mem.splitScalar(u8, opts, ',');
                while (oit3.next()) |o| if (std.mem.eql(u8, o, f[2..])) {
                    pos = true;
                };
                if (pos) return false;
            }
        } else if (!present) return false;
    }
    return true;
}

fn listMounts(cfg: *const Cfg) u8 {
    var out = u.Vec(u8).init(u.alloc);
    for (readMountinfo()) |m| {
        if (cfg.types) |t| if (!typeMatches(t, m.fstype)) continue;
        const opts = mergedOpts(m);
        const src = deviceName(m);
        out.pushSlice(std.fmt.allocPrint(u.alloc, "{s} on {s} type {s} ({s})", .{ src, m.target, m.fstype, opts }) catch "");
        if (cfg.labels) if (labelOf(src)) |lb| out.pushSlice(std.fmt.allocPrint(u.alloc, " [{s}]", .{lb}) catch "");
        out.push('\n');
    }
    bout("{s}", .{out.items});
    return 0;
}

// ---------------------------------------------------------------- mounting
fn errText(e: linux.E, remount: bool, src: []const u8, target: []const u8, fstype: ?[]const u8, src_exists: bool, tgt_exists: bool) []const u8 {
    _ = target;
    return switch (e) {
        .NOENT => if (!src_exists and src.len > 0 and src[0] == '/') std.fmt.allocPrint(u.alloc, "special device {s} does not exist.", .{src}) catch "" else if (!tgt_exists) "mount point does not exist." else std.fmt.allocPrint(u.alloc, "special device {s} does not exist.", .{src}) catch "",
        .NOTDIR => if (tgt_exists) "mount point is not a directory." else "mount point does not exist.",
        .BUSY => std.fmt.allocPrint(u.alloc, "{s} already mounted or mount point busy.", .{src}) catch "",
        .PERM => "must be superuser to use mount.",
        .ACCES => std.fmt.allocPrint(u.alloc, "{s}: permission denied.", .{src}) catch "",
        .NODEV => if (fstype) |t| std.fmt.allocPrint(u.alloc, "unknown filesystem type '{s}'.", .{t}) catch "" else "wrong fs type, bad option, bad superblock on x, missing codepage or helper program, or other error.",
        .NOTBLK => std.fmt.allocPrint(u.alloc, "{s} is not a block device.", .{src}) catch "",
        .ROFS => std.fmt.allocPrint(u.alloc, "{s} is write-protected but explicit -w flag given.", .{src}) catch "",
        .INVAL => if (remount) "mount point not mounted or bad option." else std.fmt.allocPrint(u.alloc, "wrong fs type, bad option, bad superblock on {s}, missing codepage or helper program, or other error.", .{src}) catch "",
        else => std.fmt.allocPrint(u.alloc, "{s}.", .{u.strerr(e)}) catch "",
    };
}

const dmesg_hint = "       dmesg(1) may have more information after failed mount system call.\n";

fn fail(target: []const u8, msg: []const u8) u8 {
    u.errf("mount: {s}: {s}\n", .{ target, msg });
    u.err(dmesg_hint);
    return EXIT_FAIL;
}

fn kernelLog(fd: i32) ?[]const u8 {
    var buf: [1024]u8 = undefined;
    var last: ?[]const u8 = null;
    while (true) {
        const r = linux.read(fd, &buf, buf.len);
        if (!u.ok(r) or r == 0) break;
        const line = std.mem.trimEnd(u8, buf[0..r], "\n");
        if (line.len > 2 and line[0] == 'e' and line[1] == ' ') last = u.alloc.dupe(u8, line[2..]) catch null;
    }
    return last;
}

fn attrFlags(flags: u64) u32 {
    var a: u32 = 0;
    if (flags & MS_RDONLY != 0) a |= MOUNT_ATTR_RDONLY;
    if (flags & MS_NOSUID != 0) a |= MOUNT_ATTR_NOSUID;
    if (flags & MS_NODEV != 0) a |= MOUNT_ATTR_NODEV;
    if (flags & MS_NOEXEC != 0) a |= MOUNT_ATTR_NOEXEC;
    if (flags & MS_NOATIME != 0) a |= MOUNT_ATTR_NOATIME;
    if (flags & MS_STRICTATIME != 0) a |= MOUNT_ATTR_STRICTATIME;
    if (flags & MS_NODIRATIME != 0) a |= MOUNT_ATTR_NODIRATIME;
    if (flags & MS_NOSYMFOLLOW != 0) a |= MOUNT_ATTR_NOSYMFOLLOW;
    return a;
}

const MountResult = union(enum) { ok, err: u8, retry_other_type };

/// mount using the fd based API; falls back to mount(2) when the kernel lacks it
fn mountOnce(o: *const Opts, src: []const u8, target: []const u8, fstype: []const u8, tgt_exists: bool, src_exists: bool, silent_enodev: bool) MountResult {
    const fsfd = linux.syscall2(.fsopen, @intFromPtr(u.zstr(fstype).ptr), 1);
    if (!u.ok(fsfd)) {
        const e = u.errno(fsfd);
        if (e == .NOSYS) return classicMount(o, src, target, fstype, tgt_exists, src_exists);
        if (silent_enodev and e == .NODEV) return .retry_other_type;
        const msg = errText(e, false, src, target, fstype, src_exists, tgt_exists);
        return .{ .err = fail(target, msg) };
    }
    const fd: i32 = @intCast(fsfd);
    defer _ = linux.close(fd);
    const cfg = struct {
        fn str(f: i32, k: []const u8, v: []const u8) usize {
            return linux.syscall5(.fsconfig, @intCast(f), 1, @intFromPtr(u.zstr(k).ptr), @intFromPtr(u.zstr(v).ptr), 0);
        }
        fn flag(f: i32, k: []const u8) usize {
            return linux.syscall5(.fsconfig, @intCast(f), 0, @intFromPtr(u.zstr(k).ptr), 0, 0);
        }
    };
    _ = cfg.str(fd, "source", src);
    if (o.flags & MS_RDONLY != 0) _ = cfg.flag(fd, "ro");
    if (o.flags & MS_SYNCHRONOUS != 0) _ = cfg.flag(fd, "sync");
    if (o.flags & MS_DIRSYNC != 0) _ = cfg.flag(fd, "dirsync");
    if (o.flags & MS_MANDLOCK != 0) _ = cfg.flag(fd, "mand");
    if (o.flags & MS_LAZYTIME != 0) _ = cfg.flag(fd, "lazytime");
    if (o.flags & MS_I_VERSION != 0) _ = cfg.flag(fd, "iversion");
    var it = std.mem.splitScalar(u8, o.fs.items, ',');
    while (it.next()) |opt| {
        if (opt.len == 0) continue;
        var rc: usize = 0;
        if (std.mem.indexOfScalar(u8, opt, '=')) |eq| rc = cfg.str(fd, opt[0..eq], opt[eq + 1 ..]) else rc = cfg.flag(fd, opt);
        if (!u.ok(rc)) {
            const klog = kernelLog(fd);
            const msg = if (klog) |k| std.fmt.allocPrint(u.alloc, "fsconfig() failed: {s}.", .{k}) catch "" else errText(u.errno(rc), false, src, target, fstype, src_exists, tgt_exists);
            return .{ .err = fail(target, msg) };
        }
    }
    const cr = linux.syscall5(.fsconfig, @intCast(fd), 6, 0, 0, 0);
    if (!u.ok(cr)) {
        const e = u.errno(cr);
        if (silent_enodev and (e == .INVAL or e == .NODEV)) return .retry_other_type;
        const klog = kernelLog(fd);
        const msg = if (klog) |k| std.fmt.allocPrint(u.alloc, "fsconfig() failed: {s}.", .{k}) catch "" else errText(e, false, src, target, fstype, src_exists, tgt_exists);
        return .{ .err = fail(target, msg) };
    }
    const mfd = linux.syscall3(.fsmount, @intCast(fd), 1, attrFlags(o.flags));
    if (!u.ok(mfd)) {
        const klog = kernelLog(fd);
        const msg = if (klog) |k| std.fmt.allocPrint(u.alloc, "fsmount() failed: {s}.", .{k}) catch "" else errText(u.errno(mfd), false, src, target, fstype, src_exists, tgt_exists);
        return .{ .err = fail(target, msg) };
    }
    defer _ = linux.close(@intCast(mfd));
    const mv = linux.syscall5(.move_mount, @intCast(mfd), @intFromPtr(""), @as(usize, @bitCast(@as(isize, linux.AT.FDCWD))), @intFromPtr(u.zstr(target).ptr), 4);
    if (!u.ok(mv)) {
        const e = u.errno(mv);
        return .{ .err = fail(target, errText(if (e == .NOTDIR and tgt_exists) .INVAL else e, false, src, target, fstype, src_exists, tgt_exists)) };
    }
    return .ok;
}

const MountAttr = extern struct { attr_set: u64, attr_clr: u64, propagation: u64, userns_fd: u64 };

fn remountApi(o: *const Opts, src: []const u8, target: []const u8, src_exists: bool, tgt_exists: bool) u8 {
    const tree = linux.syscall3(.open_tree, @as(usize, @bitCast(@as(isize, linux.AT.FDCWD))), @intFromPtr(u.zstr(target).ptr), 0x80000); // OPEN_TREE_CLOEXEC
    if (!u.ok(tree)) {
        const e = u.errno(tree);
        if (e == .NOSYS) return classicRemount(o, src, target, src_exists, tgt_exists);
        return fail(target, errText(if (e == .NOENT and tgt_exists) .INVAL else e, true, src, target, null, src_exists, tgt_exists));
    }
    defer _ = linux.close(@intCast(tree));
    const set: u64 = attrFlags(o.flags);
    const all_attrs: u64 = MOUNT_ATTR_RDONLY | MOUNT_ATTR_NOSUID | MOUNT_ATTR_NODEV | MOUNT_ATTR_NOEXEC | 0x70 | MOUNT_ATTR_NOSYMFOLLOW;
    var clr: u64 = (all_attrs & ~set) | 0x70;
    if (o.bind) {
        // bind remount only touches the vfs flags that were named
        clr = 0x70 | (if (o.rw_set) @as(u64, MOUNT_ATTR_RDONLY) else 0);
    } else {
        const pick = linux.syscall3(.fspick, @intCast(tree), @intFromPtr(""), 4 | 8);
        if (!u.ok(pick)) return fail(target, errText(u.errno(pick), true, src, target, null, src_exists, tgt_exists));
        const fd: i32 = @intCast(pick);
        defer _ = linux.close(fd);
        const flag = struct {
            fn f(fdd: i32, k: []const u8) usize {
                return linux.syscall5(.fsconfig, @intCast(fdd), 0, @intFromPtr(u.zstr(k).ptr), 0, 0);
            }
        }.f;
        _ = flag(fd, if (o.flags & MS_RDONLY != 0) "ro" else "rw");
        if (o.flags & MS_SYNCHRONOUS != 0) _ = flag(fd, "sync");
        if (o.flags & MS_DIRSYNC != 0) _ = flag(fd, "dirsync");
        if (o.flags & MS_MANDLOCK != 0) _ = flag(fd, "mand");
        if (o.flags & MS_LAZYTIME != 0) _ = flag(fd, "lazytime");
        if (o.flags & MS_I_VERSION != 0) _ = flag(fd, "iversion");
        var it = std.mem.splitScalar(u8, o.fs.items, ',');
        while (it.next()) |opt| {
            if (opt.len == 0) continue;
            var rc: usize = 0;
            if (std.mem.indexOfScalar(u8, opt, '=')) |eq| {
                rc = linux.syscall5(.fsconfig, @intCast(fd), 1, @intFromPtr(u.zstr(opt[0..eq]).ptr), @intFromPtr(u.zstr(opt[eq + 1 ..]).ptr), 0);
            } else rc = flag(fd, opt);
            if (!u.ok(rc)) {
                const klog = kernelLog(fd);
                const msg = if (klog) |k| std.fmt.allocPrint(u.alloc, "fsconfig() failed: {s}.", .{k}) catch "" else errText(u.errno(rc), true, src, target, null, src_exists, tgt_exists);
                return fail(target, msg);
            }
        }
        const rr = linux.syscall5(.fsconfig, @intCast(fd), 7, 0, 0, 0);
        if (!u.ok(rr)) {
            const klog = kernelLog(fd);
            const msg = if (klog) |k| std.fmt.allocPrint(u.alloc, "fsconfig() failed: {s}.", .{k}) catch "" else errText(u.errno(rr), true, src, target, null, src_exists, tgt_exists);
            return fail(target, msg);
        }
    }
    var attr = MountAttr{ .attr_set = set, .attr_clr = clr, .propagation = 0, .userns_fd = 0 };
    const ms = linux.syscall5(.mount_setattr, @intCast(tree), @intFromPtr(""), 0x1000, @intFromPtr(&attr), @sizeOf(MountAttr));
    if (!u.ok(ms)) return fail(target, errText(u.errno(ms), true, src, target, null, src_exists, tgt_exists));
    return 0;
}

fn classicRemount(o: *const Opts, src: []const u8, target: []const u8, src_exists: bool, tgt_exists: bool) u8 {
    var data = u.Vec(u8).init(u.alloc);
    data.pushSlice(o.fs.items);
    const rc = linux.mount(if (src.len > 0) u.zstr(src) else null, u.zstr(target), null, @intCast(MS_REMOUNT | o.flags), if (data.items.len > 0) @intFromPtr(u.zstr(data.items).ptr) else 0);
    if (!u.ok(rc)) return fail(target, errText(u.errno(rc), true, src, target, null, src_exists, tgt_exists));
    return 0;
}

fn classicMount(o: *const Opts, src: []const u8, target: []const u8, fstype: []const u8, tgt_exists: bool, src_exists: bool) MountResult {
    var data = u.Vec(u8).init(u.alloc);
    data.pushSlice(o.fs.items);
    const rc = linux.mount(u.zstr(src), u.zstr(target), u.zstr(fstype), @intCast(o.flags & 0xffffffff), if (data.items.len > 0) @intFromPtr(u.zstr(data.items).ptr) else 0);
    if (!u.ok(rc)) return .{ .err = fail(target, errText(u.errno(rc), false, src, target, fstype, src_exists, tgt_exists)) };
    return .ok;
}

fn runHelper(helper: []const u8, src: []const u8, target: []const u8, fstype: []const u8, opts_s: []const u8, cfg: *const Cfg) u8 {
    const pid = linux.fork();
    if (!u.ok(pid)) return EXIT_FAIL;
    if (pid == 0) {
        var av = u.Vec(?[*:0]const u8).init(u.alloc);
        av.push(u.zstr(std.fs.path.basename(helper)).ptr);
        av.push(u.zstr(src).ptr);
        av.push(u.zstr(target).ptr);
        if (cfg.fake) av.push("-f");
        if (cfg.nomtab) av.push("-n");
        if (cfg.verbose > 0) av.push("-v");
        if (opts_s.len > 0) {
            av.push("-o");
            av.push(u.zstr(opts_s).ptr);
        }
        if (std.mem.indexOfScalar(u8, fstype, '.') != null) {
            av.push("-t");
            av.push(u.zstr(fstype).ptr);
        }
        av.push(null);
        _ = linux.execve(u.zstr(helper).ptr, @ptrCast(av.items.ptr), u.envp(&.{}));
        linux.exit_group(127);
    }
    var status: u32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
    if (status & 0x7f != 0) return EXIT_FAIL;
    const code: u8 = @intCast((status >> 8) & 0xff);
    return if (code == 0) 0 else EXIT_FAIL;
}

fn findHelper(fstype: []const u8) ?[]const u8 {
    var base = fstype;
    if (std.mem.indexOfScalar(u8, fstype, '.')) |i| base = fstype[0..i];
    for ([_][]const u8{ "/sbin", "/usr/sbin", "/bin", "/usr/bin" }) |d| {
        const p = std.fmt.allocPrint(u.alloc, "{s}/mount.{s}", .{ d, base }) catch continue;
        if (u.ok(linux.access(u.zstr(p), 1))) return p;
    }
    return null;
}

var all_mode = false;

const Request = struct {
    source: ?[]const u8,
    target: []const u8,
    fstype: ?[]const u8,
    opts: []const u8,
};

fn doMount(cfg: *const Cfg, req0: Request) u8 {
    const req = req0;
    var o = newOpts();
    if (cfg.readonly_flag) {
        o.flags |= MS_RDONLY;
        o.ro_set = true;
    }
    if (cfg.readwrite_flag) {
        o.flags &= ~MS_RDONLY;
        o.rw_set = true;
    }
    parseOpts(&o, req.opts);
    if (cfg.bind or cfg.rbind) o.bind = true;
    if (cfg.rbind) o.rec = true;
    if (cfg.move) o.move = true;
    o.prop |= cfg.props;
    const target = if (cfg.no_canon) req.target else canon(req.target);
    var source: []const u8 = req.source orelse "";
    var tgt_exists = u.stat(target, true) != null;
    // propagation changes act on the target only
    if (o.prop != 0 and !o.bind and !o.move and !o.remount and (req.source == null or std.mem.eql(u8, source, "none") or std.mem.eql(u8, source, target)) and req.fstype == null) {
        if (!cfg.fake) {
            const rc = linux.mount(null, u.zstr(target), null, @intCast(o.prop), 0);
            if (!u.ok(rc)) return fail(target, errText(u.errno(rc), false, source, target, null, true, tgt_exists));
        }
        if (cfg.verbose > 0) bout("mount: {s} propagation flags changed.\n", .{target});
        return 0;
    }
    // source tags
    if (isTag(source)) {
        source = resolveTag(source) orelse {
            u.errf("mount: {s}: can't find {s}.\n", .{ target, quoteTag(source) });
            return EXIT_USAGE;
        };
    } else if (source.len > 0 and !cfg.no_canon and source[0] == '/') source = canon(source);
    var src_exists = source.len == 0 or u.stat(source, true) != null;
    // remount: libmount starts from the vfs flags of the existing mount
    if (o.remount) {
        for (readMountinfo()) |m| if (std.mem.eql(u8, m.target, target)) {
            if (req.source == null) source = deviceName(m);
            var base = newOpts();
            parseOpts(&base, m.vfs);
            var tmp = newOpts();
            tmp.flags = base.flags;
            // no atime keyword in mountinfo means strictatime
            if (tmp.flags & (MS_NOATIME | MS_RELATIME) == 0) tmp.flags |= MS_STRICTATIME;
            if (cfg.readonly_flag) tmp.flags |= MS_RDONLY;
            if (cfg.readwrite_flag) tmp.flags &= ~MS_RDONLY;
            parseOpts(&tmp, req.opts);
            o.flags = tmp.flags;
        };
    }
    if (o.bind and !o.remount) {
        if (!src_exists) {
            u.errf("mount: {s}: special device {s} does not exist.\n{s}", .{ target, source, dmesg_hint });
            return EXIT_FAIL;
        }
        if (!cfg.fake) {
            const bf: u64 = MS_BIND | (if (o.rec) MS_REC else 0);
            const rc = linux.mount(u.zstr(source), u.zstr(target), null, @intCast(bf), 0);
            if (!u.ok(rc)) return fail(target, errText(u.errno(rc), false, source, target, null, src_exists, tgt_exists));
            const extra = o.flags & (MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC | MS_NOATIME | MS_NODIRATIME | MS_RELATIME | MS_STRICTATIME | MS_NOSYMFOLLOW);
            if (extra != 0) {
                const rc2 = linux.mount(null, u.zstr(target), null, @intCast(MS_BIND | MS_REMOUNT | extra | (if (o.rec) MS_REC else 0)), 0);
                if (!u.ok(rc2)) return fail(target, errText(u.errno(rc2), true, source, target, null, src_exists, tgt_exists));
            }
            if (o.prop != 0) _ = linux.mount(null, u.zstr(target), null, @intCast(o.prop), 0);
        }
        if (cfg.verbose > 0) bout("mount: {s} bound on {s}.\n", .{ source, target });
        return 0;
    }
    if (o.move) {
        if (!cfg.fake) {
            const rc = linux.mount(u.zstr(source), u.zstr(target), null, @intCast(MS_MOVE), 0);
            if (!u.ok(rc)) return fail(target, errText(u.errno(rc), false, source, target, null, src_exists, tgt_exists));
        }
        if (cfg.verbose > 0) bout("mount: {s} moved to {s}.\n", .{ source, target });
        return 0;
    }
    if (o.remount) {
        if (!cfg.fake) {
            const rc = remountApi(&o, source, target, src_exists, tgt_exists);
            if (rc != 0) return rc;
        }
        mountedMsg(if (source.len > 0) source else "(null)", target);
        return 0;
    }
    // ----- ordinary mount
    var fstype: ?[]const u8 = req.fstype;
    var excluded: []const u8 = "";
    if (fstype) |t| {
        if (std.mem.eql(u8, t, "auto")) {
            fstype = null;
        } else if (std.mem.startsWith(u8, t, "no")) {
            // "-t nofoo,nobar": everything except the listed types
            excluded = t[2..];
            fstype = null;
        }
    }
    var helper_done: ?u8 = null;
    if (fstype) |t| if (!cfg.internal_only) if (findHelper(t)) |h| {
        helper_done = runHelper(h, req.source orelse source, target, t, req.opts, cfg);
    };
    if (helper_done) |r| {
        if (r == 0 and cfg.verbose > 0) mountedMsg(if (source.len > 0) source else "none", target);
        return r;
    }
    if (!tgt_exists and !cfg.fake) {
        return fail(target, "mount point does not exist.");
    }
    _ = &tgt_exists;
    // loop device for regular files
    var is_file = false;
    if (source.len > 0) if (u.stat(source, true)) |st| {
        is_file = st.mode & linux.S.IFMT == linux.S.IFREG;
    };
    // a regular file only becomes a loop device when asked for, or when it holds a recognizable filesystem
    const want_loop = o.loop or (is_file and (fstype != null or detectFs(source) != null));
    if (want_loop and source.len > 0 and !cfg.fake) {
        const dev = setupLoop(source, o.flags & MS_RDONLY != 0, o.loop_offset, o.loop_size) orelse {
            u.errf("mount: {s}: failed to setup loop device for {s}.\n", .{ target, source });
            return EXIT_FAIL;
        };
        source = dev;
        src_exists = true;
    }
    if (cfg.fake) {
        if (cfg.verbose > 0) mountedMsg(if (source.len > 0) source else "none", target);
        return 0;
    }
    if (fstype != null and std.mem.indexOfScalar(u8, fstype.?, ',') != null) {
        var done = false;
        var tl = std.mem.splitScalar(u8, fstype.?, ',');
        while (tl.next()) |t| {
            switch (mountOnce(&o, source, target, t, true, src_exists, true)) {
                .ok => done = true,
                .err => |e| return e,
                .retry_other_type => {},
            }
            if (done) break;
        }
        if (!done) return fail(target, std.fmt.allocPrint(u.alloc, "wrong fs type, bad option, bad superblock on {s}, missing codepage or helper program, or other error.", .{source}) catch "");
    } else if (fstype != null) {
        switch (mountOnce(&o, source, target, fstype.?, true, src_exists, false)) {
            .ok => {},
            .err => |e| return e,
            .retry_other_type => unreachable,
        }
    } else {
        if (source.len > 0 and source[0] == '/') {
            if (detectFs(source)) |t| {
                if (std.mem.eql(u8, t, "swap")) return fail(target, std.fmt.allocPrint(u.alloc, "unknown filesystem type 'swap'.", .{}) catch "");
                switch (mountOnce(&o, source, target, t, true, src_exists, false)) {
                    .ok => {},
                    .err => |e| return e,
                    .retry_other_type => unreachable,
                }
                if (cfg.verbose > 0) mountedMsg(source, target);
                return 0;
            }
        }
        var done = false;
        for (kernelFilesystems()) |t| {
            if (excluded.len > 0 and typeMatches(std.fmt.allocPrint(u.alloc, "no{s}", .{excluded}) catch "", t) == false) continue;
            switch (mountOnce(&o, source, target, t, true, src_exists, true)) {
                .ok => {
                    done = true;
                },
                .err => |e| return e,
                .retry_other_type => {},
            }
            if (done) break;
        }
        if (!done) return fail(target, std.fmt.allocPrint(u.alloc, "wrong fs type, bad option, bad superblock on {s}, missing codepage or helper program, or other error.", .{source}) catch "");
    }
    if (o.prop != 0) _ = linux.mount(null, u.zstr(target), null, @intCast(o.prop), 0);
    if (cfg.verbose > 0) mountedMsg(if (source.len > 0) source else "none", target);
    return 0;
}

var verbosity: u32 = 0;

fn mountedMsg(source: []const u8, target: []const u8) void {
    if (verbosity == 0) return;
    if (all_mode) bout("{s: <25}: successfully mounted\n", .{target}) else bout("mount: {s} mounted on {s}.\n", .{ source, target });
}

fn quoteTag(tag: []const u8) []const u8 {
    const eq = std.mem.indexOfScalar(u8, tag, '=') orelse return tag;
    var v = tag[eq + 1 ..];
    if (v.len >= 2 and (v[0] == '"' or v[0] == '\'')) v = v[1 .. v.len - 1];
    return std.fmt.allocPrint(u.alloc, "{s}=\"{s}\"", .{ tag[0..eq], v }) catch tag;
}

fn alreadyMounted(f: Fstab) bool {
    const t = canon(f.target);
    var src = f.source;
    if (isTag(src)) src = resolveTag(src) orelse src else src = canon(src);
    for (readMountinfo()) |m| {
        if (!std.mem.eql(u8, m.target, t)) continue;
        if (std.mem.eql(u8, deviceName(m), src) or std.mem.eql(u8, m.source, src)) return true;
        if (!std.mem.startsWith(u8, src, "/")) return true;
    }
    return false;
}

fn combineOpts(a: []const u8, b: []const u8) []const u8 {
    if (a.len == 0) return b;
    if (b.len == 0) return a;
    return std.fmt.allocPrint(u.alloc, "{s},{s}", .{ a, b }) catch a;
}

const mount_usage =
    "\nUsage:\n mount [-lhV]\n mount -a [options]\n mount [options] [--source] <source> | [--target] <directory>\n mount [options] <source> <directory>\n mount <operation> <mountpoint> [<target>]\n\n" ++
    "Mount a filesystem.\n\nOptions:\n -a, --all               mount all filesystems mentioned in fstab\n -c, --no-canonicalize   don't canonicalize paths\n -f, --fake              dry run; skip the mount(2) syscall\n" ++
    " -F, --fork              fork off for each device (use with -a)\n -T, --fstab <path>      alternative file to /etc/fstab\n -i, --internal-only     don't call the mount.<type> helpers\n" ++
    " -l, --show-labels       show also filesystem labels\n -m, --mkdir[=<mode>]    alias to '-o X-mount.mkdir[=<mode>]'\n -n, --no-mtab           don't write to /etc/mtab\n" ++
    "     --options-mode <mode>\n                         what to do with options loaded from fstab\n     --options-source <source>\n                         mount options source\n     --options-source-force\n                         force use of options from fstab/mtab\n" ++
    " -o, --options <list>    comma-separated list of mount options\n -O, --test-opts <list>  limit the set of filesystems (use with -a)\n -r, --read-only         mount the filesystem read-only (same as -o ro)\n" ++
    " -t, --types <list>      limit the set of filesystem types\n     --source <src>      explicitly specifies source (path, label, uuid)\n     --target <target>   explicitly specifies mountpoint\n" ++
    "     --target-prefix <path>\n                         specifies path used for all mountpoints\n -v, --verbose           say what is being done\n -w, --rw, --read-write  mount the filesystem read-write (default)\n" ++
    " -N, --namespace <ns>    perform mount in another namespace\n\n -h, --help              display this help\n -V, --version           display version\n\nSource:\n -L, --label <label>     synonym for LABEL=<label>\n -U, --uuid <uuid>       synonym for UUID=<uuid>\n" ++
    "  LABEL=<label>          specifies device by filesystem label\n  UUID=<uuid>            specifies device by filesystem UUID\n  PARTLABEL=<label>      specifies device by partition label\n  PARTUUID=<uuid>        specifies device by partition UUID\n" ++
    "  ID=<id>                specifies device by udev hardware ID\n  <device>               specifies device by path\n  <directory>            mountpoint for bind mounts (see --bind/rbind)\n  <file>                 regular file for loopdev setup\n\n" ++
    "Operations:\n -B, --bind              mount a subtree somewhere else (same as -o bind)\n -M, --move              move a subtree to some other place\n -R, --rbind             mount a subtree and all submounts somewhere else\n" ++
    " --make-shared           mark a subtree as shared\n --make-slave            mark a subtree as slave\n --make-private          mark a subtree as private\n --make-unbindable       mark a subtree as unbindable\n" ++
    " --make-rshared          recursively mark a whole subtree as shared\n --make-rslave           recursively mark a whole subtree as slave\n --make-rprivate         recursively mark a whole subtree as private\n --make-runbindable      recursively mark a whole subtree as unbindable\n" ++
    "\nFor more details see mount(8).\n";

pub fn mount(args: []const []const u8) u8 {
    const rc = mountMain(args);
    flushOut();
    if (loop_fd >= 0) _ = linux.close(loop_fd);
    return rc;
}

fn mountMain(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "all", .key = 'a' },
        .{ .name = "no-canonicalize", .key = 'c' },
        .{ .name = "fake", .key = 'f' },
        .{ .name = "fork", .key = 'F' },
        .{ .name = "fstab", .key = 'T', .arg = .req },
        .{ .name = "internal-only", .key = 'i' },
        .{ .name = "show-labels", .key = 'l' },
        .{ .name = "mkdir", .key = 'm', .arg = .opt },
        .{ .name = "no-mtab", .key = 'n' },
        .{ .name = "options", .key = 'o', .arg = .req },
        .{ .name = "test-opts", .key = 'O', .arg = .req },
        .{ .name = "read-only", .key = 'r' },
        .{ .name = "ro", .key = 'r' },
        .{ .name = "types", .key = 't', .arg = .req },
        .{ .name = "source", .key = 200, .arg = .req },
        .{ .name = "target", .key = 201, .arg = .req },
        .{ .name = "target-prefix", .key = 202, .arg = .req },
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "rw", .key = 'w' },
        .{ .name = "read-write", .key = 'w' },
        .{ .name = "namespace", .key = 'N', .arg = .req },
        .{ .name = "help", .key = 'h' },
        .{ .name = "version", .key = 'V' },
        .{ .name = "label", .key = 'L', .arg = .req },
        .{ .name = "uuid", .key = 'U', .arg = .req },
        .{ .name = "bind", .key = 'B' },
        .{ .name = "move", .key = 'M' },
        .{ .name = "rbind", .key = 'R' },
        .{ .name = "make-shared", .key = 210 },
        .{ .name = "make-slave", .key = 211 },
        .{ .name = "make-private", .key = 212 },
        .{ .name = "make-unbindable", .key = 213 },
        .{ .name = "make-rshared", .key = 214 },
        .{ .name = "make-rslave", .key = 215 },
        .{ .name = "make-rprivate", .key = 216 },
        .{ .name = "make-runbindable", .key = 217 },
        .{ .name = "options-mode", .key = 220, .arg = .req },
        .{ .name = "options-source", .key = 221, .arg = .req },
        .{ .name = "options-source-force", .key = 222 },
        .{ .name = "show-labels", .key = 'l' },
    };
    var p = g.Parser.init("mount", args, &opts);
    p.no_hint = true;
    var cfg = Cfg{ .options = u.Vec(u8).init(u.alloc) };
    defer verbosity = 0;
    while (p.next() catch return EXIT_USAGE) |it| {
        switch (it.key) {
            'a' => cfg.all = true,
            'c' => cfg.no_canon = true,
            'f' => cfg.fake = true,
            'F' => {},
            'T' => cfg.fstab_path = it.val.?,
            'i' => cfg.internal_only = true,
            'l' => {
                cfg.labels = true;
            },
            'm' => {},
            'n' => cfg.nomtab = true,
            'o' => {
                if (cfg.options.items.len > 0) cfg.options.push(',');
                cfg.options.pushSlice(it.val.?);
            },
            'O' => cfg.opt_filter = it.val,
            'r' => cfg.readonly_flag = true,
            't' => cfg.types = it.val,
            200 => cfg.source_flag = it.val,
            201 => cfg.target_flag = it.val,
            'v' => {
                cfg.verbose += 1;
                verbosity = cfg.verbose;
            },
            'w' => cfg.readwrite_flag = true,
            'N', 202, 220, 221, 222 => {},
            'h' => {
                u.out(mount_usage);
                return 0;
            },
            'V' => {
                u.out("mount from util-linux 2.41.5 (libmount 2.41.5: selinux, btrfs, namespaces, idmapping, fd-based-mount, statmount, statx, assert, debug)\n");
                return 0;
            },
            'L' => cfg.label = it.val,
            'U' => cfg.uuid = it.val,
            'B' => cfg.bind = true,
            'M' => cfg.move = true,
            'R' => cfg.rbind = true,
            210 => cfg.props |= MS_SHARED,
            211 => cfg.props |= MS_SLAVE,
            212 => cfg.props |= MS_PRIVATE,
            213 => cfg.props |= MS_UNBINDABLE,
            214 => cfg.props |= MS_SHARED | MS_REC,
            215 => cfg.props |= MS_SLAVE | MS_REC,
            216 => cfg.props |= MS_PRIVATE | MS_REC,
            217 => cfg.props |= MS_UNBINDABLE | MS_REC,
            else => {},
        }
    }
    const ops = p.operands.items;
    var src_arg: ?[]const u8 = cfg.source_flag;
    var tgt_arg: ?[]const u8 = cfg.target_flag;
    if (cfg.label) |l| src_arg = std.fmt.allocPrint(u.alloc, "LABEL={s}", .{l}) catch null;
    if (cfg.uuid) |l| src_arg = std.fmt.allocPrint(u.alloc, "UUID={s}", .{l}) catch null;
    var n_pos = ops.len;
    // -L/-U plus one operand: the operand is the mount point
    if ((cfg.label != null or cfg.uuid != null) and n_pos == 1 and tgt_arg == null) {
        tgt_arg = ops[0];
        n_pos = 0;
    }
    if (cfg.all) {
        if (n_pos > 0) {
            u.err("mount: bad usage\nTry 'mount --help' for more information.\n");
            return EXIT_USAGE;
        }
        return mountAll(&cfg);
    }
    if (n_pos == 0 and src_arg == null and tgt_arg == null and cfg.props == 0) return listMounts(&cfg);
    if (n_pos > 2) {
        u.err("mount: bad usage\nTry 'mount --help' for more information.\n");
        return EXIT_USAGE;
    }
    var one: ?[]const u8 = null;
    if (src_arg != null and tgt_arg != null and n_pos == 0 and (cfg.label != null or cfg.uuid != null)) {
        // fall through to the two-argument mount below
    } else if (n_pos == 2) {
        src_arg = ops[0];
        tgt_arg = ops[1];
        n_pos = 0;
    } else if (n_pos == 1) {
        one = ops[0];
    }
    // single operand: look it up in fstab (as target first, then as source)
    if (one != null or ((src_arg != null) != (tgt_arg != null)) or (cfg.props != 0 and tgt_arg == null)) {
        const key = one orelse (tgt_arg orelse src_arg.?);
        var needle_is_target = false;
        if (one == null and tgt_arg != null) needle_is_target = true;
        if (cfg.props != 0 and one != null) {
            // propagation changes only need the mount point
            return doMount(&cfg, .{ .source = null, .target = one.?, .fstype = cfg.types, .opts = cfg.options.items });
        }
        if (cfg.props != 0 and tgt_arg != null) return doMount(&cfg, .{ .source = null, .target = tgt_arg.?, .fstype = cfg.types, .opts = cfg.options.items });
        // an existing mount point plus -o remount / bind has no need for fstab
        const tab = readFstab(cfg.fstab_path);
        var found: ?Fstab = null;
        const ck = if (isTag(key)) (resolveTag(key) orelse key) else canon(key);
        for (tab) |f| {
            if (!needle_is_target and std.mem.eql(u8, canon(f.target), ck)) found = f;
            if (found == null and std.mem.eql(u8, f.target, key)) found = f;
        }
        if (found == null) for (tab) |f| {
            const fs_src = if (isTag(f.source)) (resolveTag(f.source) orelse f.source) else canon(f.source);
            if (std.mem.eql(u8, f.source, key) or std.mem.eql(u8, fs_src, ck)) found = f;
        };
        if (found) |f| {
            const mopts = combineOpts(f.opts, cfg.options.items);
            // a user option check for non-root
            return doMount(&cfg, .{ .source = f.source, .target = f.target, .fstype = cfg.types orelse f.fstype, .opts = mopts });
        }
        // remount of something that is mounted but not in fstab
        if (std.mem.indexOf(u8, cfg.options.items, "remount") != null) {
            return doMount(&cfg, .{ .source = null, .target = key, .fstype = cfg.types, .opts = cfg.options.items });
        }
        if (cfg.label != null or cfg.uuid != null) {
            u.errf("mount: {s}: can't find {s}.\n", .{ key, quoteTag(src_arg orelse key) });
            return EXIT_USAGE;
        }
        u.errf("mount: {s}: can't find in {s}.\n", .{ key, cfg.fstab_path });
        return EXIT_USAGE;
    }
    if (src_arg == null or tgt_arg == null) {
        u.err("mount: bad usage\nTry 'mount --help' for more information.\n");
        return EXIT_USAGE;
    }
    // explicit source and target; --bind with a lone directory also lands here
    return doMount(&cfg, .{ .source = src_arg, .target = tgt_arg.?, .fstype = cfg.types, .opts = cfg.options.items });
}

fn mountAll(cfg: *const Cfg) u8 {
    const tab = readFstab(cfg.fstab_path);
    var ok_n: usize = 0;
    var bad_n: usize = 0;
    for (tab) |f| {
        if (std.mem.eql(u8, f.fstype, "swap") or std.mem.eql(u8, f.fstype, "ignore")) continue;
        if (cfg.types) |t| if (!typeMatches(t, f.fstype)) {
            if (cfg.verbose > 0) bout("{s: <25}: ignored\n", .{f.target});
            continue;
        };
        var o = newOpts();
        parseOpts(&o, f.opts);
        if (o.noauto) continue;
        if (cfg.opt_filter) |flt| if (!optsMatch(flt, f.opts)) {
            if (cfg.verbose > 0) bout("{s: <25}: ignored\n", .{f.target});
            continue;
        };
        if (alreadyMounted(f)) {
            if (cfg.verbose > 0) bout("{s: <25}: already mounted\n", .{f.target});
            continue;
        }
        all_mode = true;
        const rc = doMount(cfg, .{ .source = f.source, .target = f.target, .fstype = f.fstype, .opts = combineOpts(f.opts, cfg.options.items) });
        all_mode = false;
        if (rc == 0) ok_n += 1 else if (!o.nofail) bad_n += 1;
    }
    if (bad_n == 0) return 0;
    return if (ok_n > 0) EXIT_SOME else EXIT_FAIL;
}

// ---------------------------------------------------------------- umount
const umount_usage =
    "\nUsage:\n umount [-hV]\n umount -a [options]\n umount [options] <source> | <directory>\n\nUnmount filesystems.\n\nOptions:\n -a, --all               unmount all filesystems\n -A, --all-targets       unmount all mountpoints for the given device in the\n                           current namespace\n" ++
    " -c, --no-canonicalize   don't canonicalize paths\n -d, --detach-loop       if mounted loop device, also free this loop device\n     --fake              dry run; skip the umount(2) syscall\n -f, --force             force unmount (in case of an unreachable NFS system)\n" ++
    " -i, --internal-only     don't call the umount.<type> helpers\n -n, --no-mtab           don't write to /etc/mtab\n -l, --lazy              detach the filesystem now, clean up things later\n -O, --test-opts <list>  limit the set of filesystems (use with -a)\n" ++
    " -R, --recursive         recursively unmount a target with all its children\n -r, --read-only         in case unmounting fails, try to remount read-only\n -t, --types <list>      limit the set of filesystem types\n -v, --verbose           say what is being done\n -q, --quiet             suppress 'not mounted' error messages\n -N, --namespace <ns>    perform umount in another namespace\n\n -h, --help              display this help\n -V, --version           display version\n\nFor more details see umount(8).\n";

pub fn umount(args: []const []const u8) u8 {
    const rc = umountMain(args);
    flushOut();
    return rc;
}

fn umountMain(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "all", .key = 'a' },
        .{ .name = "all-targets", .key = 'A' },
        .{ .name = "no-canonicalize", .key = 'c' },
        .{ .name = "detach-loop", .key = 'd' },
        .{ .name = "fake", .key = 200 },
        .{ .name = "force", .key = 'f' },
        .{ .name = "internal-only", .key = 'i' },
        .{ .name = "no-mtab", .key = 'n' },
        .{ .name = "lazy", .key = 'l' },
        .{ .name = "test-opts", .key = 'O', .arg = .req },
        .{ .name = "recursive", .key = 'R' },
        .{ .name = "read-only", .key = 'r' },
        .{ .name = "types", .key = 't', .arg = .req },
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "quiet", .key = 'q' },
        .{ .name = "namespace", .key = 'N', .arg = .req },
        .{ .name = "help", .key = 'h' },
        .{ .name = "version", .key = 'V' },
    };
    var p = g.Parser.init("umount", args, &opts);
    p.no_hint = true;
    var all = false;
    var fake = false;
    var verbose = false;
    var quiet = false;
    var flags: u32 = 0;
    var rdonly_fallback = false;
    var recursive = false;
    var types: ?[]const u8 = null;
    var opt_filter: ?[]const u8 = null;
    var detach_loop = false;
    var no_canon = false;
    while (p.next() catch return EXIT_USAGE) |it| {
        switch (it.key) {
            'a' => all = true,
            'A' => {},
            'c' => no_canon = true,
            'd' => detach_loop = true,
            200 => fake = true,
            'f' => flags |= 1,
            'i', 'n', 'N' => {},
            'l' => flags |= 2,
            'O' => opt_filter = it.val,
            'R' => recursive = true,
            'r' => rdonly_fallback = true,
            't' => types = it.val,
            'v' => verbose = true,
            'q' => quiet = true,
            'h' => {
                u.out(umount_usage);
                return 0;
            },
            'V' => {
                u.out("umount from util-linux 2.41.5 (libmount 2.41.5: selinux, btrfs, namespaces, idmapping, fd-based-mount, statmount, statx, assert, debug)\n");
                return 0;
            },
            else => {},
        }
    }
    const ops = p.operands.items;
    const mis = readMountinfo();
    var targets = u.Vec(MI).init(u.alloc);
    var ignored = u.Vec(bool).init(u.alloc);
    if (all) {
        if (ops.len > 0) {
            u.err("umount: bad usage\nTry 'umount --help' for more information.\n");
            return EXIT_USAGE;
        }
        var i = mis.len;
        while (i > 0) {
            i -= 1;
            const m = mis[i];
            var ign = false;
            if (types) |t| if (!typeMatches(t, m.fstype)) {
                ign = true;
            };
            if (opt_filter) |f| if (!optsMatch(f, mergedOpts(m))) {
                ign = true;
            };
            if (std.mem.eql(u8, m.fstype, "proc") or std.mem.eql(u8, m.fstype, "sysfs") or std.mem.eql(u8, m.fstype, "devpts")) ign = true;
            ignored.push(ign);
            targets.push(m);
        }
        all_mode = true;
    } else {
        if (ops.len == 0) {
            u.err("umount: bad usage\nTry 'umount --help' for more information.\n");
            return EXIT_USAGE;
        }
        for (ops) |arg| {
            const ck = if (no_canon) arg else (if (isTag(arg)) (resolveTag(arg) orelse arg) else canon(arg));
            var hit: ?MI = null;
            var i = mis.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, mis[i].target, ck)) {
                    hit = mis[i];
                    break;
                }
            }
            if (hit == null) {
                i = mis.len;
                while (i > 0) {
                    i -= 1;
                    if (std.mem.eql(u8, deviceName(mis[i]), ck) or std.mem.eql(u8, mis[i].source, ck)) {
                        hit = mis[i];
                        break;
                    }
                }
            }
            if (hit) |m| targets.push(m) else {
                const exists = u.stat(ck, true) != null;
                if (!quiet) u.errf("umount: {s}: {s}\n", .{ arg, if (exists) "not mounted." else "no mount point specified." });
                return 32;
            }
        }
    }
    var rc: u8 = 0;
    for (targets.items, 0..) |m, ti| {
        if (all and ignored.items[ti]) {
            if (verbose) bout("{s: <25}: ignored\n", .{m.target});
            continue;
        }
        if (recursive) {
            // children first (deepest targets before their parents)
            var i = mis.len;
            while (i > 0) {
                i -= 1;
                const c = mis[i];
                if (std.mem.startsWith(u8, c.target, m.target) and c.target.len > m.target.len and c.target[m.target.len] == '/') {
                    if (!doUmount(c, fake, flags, verbose, rdonly_fallback, detach_loop)) rc = 32;
                }
            }
        }
        if (!doUmount(m, fake, flags, verbose, rdonly_fallback, detach_loop)) rc = 32;
    }
    return rc;
}

fn doUmount(m: MI, fake: bool, flags: u32, verbose: bool, rdonly_fallback: bool, detach_loop: bool) bool {
    if (!fake) {
        const rc = linux.syscall2(.umount2, @intFromPtr(u.zstr(m.target).ptr), flags);
        if (!u.ok(rc)) {
            const e = u.errno(rc);
            if (e == .BUSY and rdonly_fallback) {
                const r2 = linux.mount(null, u.zstr(m.target), null, @intCast(MS_REMOUNT | MS_RDONLY), 0);
                if (u.ok(r2)) return true;
            }
            const msg: []const u8 = switch (e) {
                .BUSY => "target is busy.",
                .PERM => "must be superuser to unmount.",
                .INVAL => "not mounted.",
                else => u.strerr(e),
            };
            u.errf("umount: {s}: {s}\n", .{ m.target, msg });
            return false;
        }
        if (detach_loop and std.mem.startsWith(u8, m.source, "/dev/loop")) {
            const fd = linux.open(u.zstr(m.source), .{ .ACCMODE = .RDONLY }, 0);
            if (u.ok(fd)) {
                _ = linux.ioctl(@intCast(fd), 0x4C01, 0);
                _ = linux.close(@intCast(fd));
            }
        }
    }
    if (verbose) {
        if (all_mode) bout("{s: <25}: successfully unmounted\n", .{m.target}) else bout("umount: {s} unmounted\n", .{m.target});
    }
    return true;
}
