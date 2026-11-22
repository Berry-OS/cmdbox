// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// lsattr / chattr - e2fsprogs compatible (flag letters and 22-column layout taken from libe2p)
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");

const FlagDef = struct { bit: u32, pos: u8, ch: u8, name: []const u8 };
const flag_defs = [_]FlagDef{
    .{ .bit = 0x1, .pos = 0, .ch = 's', .name = "Secure_Deletion" },
    .{ .bit = 0x2, .pos = 1, .ch = 'u', .name = "Undelete" },
    .{ .bit = 0x8, .pos = 2, .ch = 'S', .name = "Synchronous_Updates" },
    .{ .bit = 0x10000, .pos = 3, .ch = 'D', .name = "Synchronous_Directory_Updates" },
    .{ .bit = 0x10, .pos = 4, .ch = 'i', .name = "Immutable" },
    .{ .bit = 0x20, .pos = 5, .ch = 'a', .name = "Append_Only" },
    .{ .bit = 0x40, .pos = 6, .ch = 'd', .name = "No_Dump" },
    .{ .bit = 0x80, .pos = 7, .ch = 'A', .name = "No_Atime" },
    .{ .bit = 0x4, .pos = 8, .ch = 'c', .name = "Compression_Requested" },
    .{ .bit = 0x800, .pos = 9, .ch = 'E', .name = "Encrypted" },
    .{ .bit = 0x4000, .pos = 10, .ch = 'j', .name = "Journaled_Data" },
    .{ .bit = 0x1000, .pos = 11, .ch = 'I', .name = "Indexed_directory" },
    .{ .bit = 0x8000, .pos = 12, .ch = 't', .name = "No_Tailmerging" },
    .{ .bit = 0x20000, .pos = 13, .ch = 'T', .name = "Top_of_Directory_Hierarchies" },
    .{ .bit = 0x80000, .pos = 14, .ch = 'e', .name = "Extents" },
    .{ .bit = 0x800000, .pos = 15, .ch = 'C', .name = "No_COW" },
    .{ .bit = 0x2000000, .pos = 16, .ch = 'x', .name = "DAX" },
    .{ .bit = 0x40000000, .pos = 17, .ch = 'F', .name = "Casefold" },
    .{ .bit = 0x10000000, .pos = 18, .ch = 'N', .name = "Inline_Data" },
    .{ .bit = 0x20000000, .pos = 19, .ch = 'P', .name = "Project_Hierarchy" },
    .{ .bit = 0x100000, .pos = 20, .ch = 'V', .name = "Verity" },
    .{ .bit = 0x400, .pos = 21, .ch = 'm', .name = "Dont_Compress" },
};

const lsz: u32 = @sizeOf(c_ulong);
fn ioc(dir: u32, nr: u32, size: u32) u32 {
    return (dir << 30) | (size << 16) | (@as(u32, 'f') << 8) | nr;
}
const GETFLAGS: u32 = (2 << 30) | (lsz << 16) | (@as(u32, 'f') << 8) | 1;
const SETFLAGS: u32 = (1 << 30) | (lsz << 16) | (@as(u32, 'f') << 8) | 2;
const GETVERSION: u32 = (2 << 30) | (lsz << 16) | (@as(u32, 'v') << 8) | 1;
const SETVERSION: u32 = (1 << 30) | (lsz << 16) | (@as(u32, 'v') << 8) | 2;

fn isDirOrReg(path: []const u8) ?bool {
    const st = u.stat(path, false) orelse return null;
    const t = st.mode & linux.S.IFMT;
    return t == linux.S.IFDIR or t == linux.S.IFREG;
}

const Err = struct { en: linux.E };

fn openFor(path: []const u8) union(enum) { fd: i32, err: linux.E } {
    const st = u.stat(path, false) orelse return .{ .err = .NOENT };
    const t = st.mode & linux.S.IFMT;
    if (t != linux.S.IFDIR and t != linux.S.IFREG) return .{ .err = .OPNOTSUPP };
    const rc = linux.open(u.zstr(path), .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOFOLLOW = true }, 0);
    if (!u.ok(rc)) return .{ .err = u.errno(rc) };
    return .{ .fd = @intCast(rc) };
}

fn getFlags(path: []const u8, version: ?*c_ulong) union(enum) { flags: u32, err: linux.E } {
    const o = openFor(path);
    switch (o) {
        .err => |e| return .{ .err = e },
        .fd => |fd| {
            defer _ = linux.close(fd);
            var f: c_ulong = 0;
            const r = linux.ioctl(fd, GETFLAGS, @intFromPtr(&f));
            if (!u.ok(r)) return .{ .err = u.errno(r) };
            if (version) |v| {
                v.* = 0;
                _ = linux.ioctl(fd, GETVERSION, @intFromPtr(v));
            }
            return .{ .flags = @truncate(f) };
        },
    }
}

fn pushFlags(o: *u.Vec(u8), flags: u32, long: bool) void {
    if (!long) {
        var s = [_]u8{'-'} ** 22;
        for (flag_defs) |d| if (flags & d.bit != 0) {
            s[d.pos] = d.ch;
        };
        o.pushSlice(&s);
        return;
    }
    var any = false;
    for (flag_defs) |d| if (flags & d.bit != 0) {
        if (any) o.pushSlice(", ");
        o.pushSlice(d.name);
        any = true;
    };
    if (!any) o.pushSlice("---");
}

const LsOpts = struct { all: bool = false, dir_only: bool = false, long: bool = false, ver: bool = false, rec: bool = false, proj: bool = false };

fn lsOne(path: []const u8, shown: []const u8, o: LsOpts) u8 {
    var version: c_ulong = 0;
    switch (getFlags(path, &version)) {
        .err => |e| {
            u.errf("lsattr: {s} While reading flags on {s}\n", .{ u.strerr(e), shown });
            return 1;
        },
        .flags => |f| {
            var out = u.Vec(u8).init(u.alloc);
            if (o.ver) out.pushSlice(std.fmt.allocPrint(u.alloc, "{d: >5} ", .{version}) catch "");
            if (o.proj) {
                out.pushSlice("    0 ");
            }
            if (o.long) {
                out.pushSlice(std.fmt.allocPrint(u.alloc, "{s: <28} ", .{shown}) catch "");
                pushFlags(&out, f, true);
            } else {
                pushFlags(&out, f, false);
                out.push(' ');
                out.pushSlice(shown);
            }
            out.push('\n');
            u.out(out.items);
            return 0;
        },
    }
}

fn lsDir(path: []const u8, o: LsOpts, header: bool, rc: *u8) void {
    if (header) u.outf("{s}:\n", .{path});
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir(path, &ents)) {
        u.errf("lsattr: {s} While reading directory {s}\n", .{ "Permission denied", path });
        rc.* = 1;
        return;
    }
    var subdirs = u.Vec([]const u8).init(u.alloc);
    if (o.all) {
        for ([_][]const u8{ ".", ".." }) |n| {
            const full = joinPath(path, n);
            if (lsOne(full, full, o) != 0) rc.* = 1;
        }
    }
    for (ents.items) |e| {
        const name: []const u8 = e.name;
        if (!o.all and name[0] == '.') continue;
        const full = joinPath(path, name);
        if (o.rec) {
            if (u.stat(full, false)) |st| if (st.mode & linux.S.IFMT == linux.S.IFDIR) subdirs.push(full);
        }
        if (lsOne(full, full, o) != 0) rc.* = 1;
    }
    if (o.rec) for (subdirs.items) |sd| {
        u.out("\n");
        lsDir(sd, o, true, rc);
    };
}

fn joinPath(dir: []const u8, name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, dir, "/")) return std.fmt.allocPrint(u.alloc, "{s}{s}", .{ dir, name }) catch name;
    return std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ dir, name }) catch name;
}

pub fn lsattr(args: []const []const u8) u8 {
    var o = LsOpts{};
    var files = u.Vec([]const u8).init(u.alloc);
    var done = false;
    for (args) |a| {
        if (done or a.len < 2 or a[0] != '-') {
            files.push(a);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            done = true;
            continue;
        }
        for (a[1..]) |ch| switch (ch) {
            'R' => o.rec = true,
            'a' => o.all = true,
            'd' => o.dir_only = true,
            'l' => o.long = true,
            'v' => o.ver = true,
            'p' => o.proj = true,
            'V' => {
                u.err("lsattr 1.47.0 (cmdbox)\n");
                return 0;
            },
            else => {
                u.err("Usage: lsattr [-RVadlpv] [files...]\n");
                return 1;
            },
        };
    }
    if (files.items.len == 0) files.push(".");
    var rc: u8 = 0;
    for (files.items) |f| {
        const st = u.stat(f, false);
        const is_dir = if (st) |s| s.mode & linux.S.IFMT == linux.S.IFDIR else false;
        if (is_dir and !o.dir_only) {
            lsDir(f, o, files.items.len > 1 or o.rec, &rc);
            if (files.items.len > 1 and !o.rec) {}
        } else if (lsOne(f, f, o) != 0) rc = 1;
    }
    return rc;
}

// ---------------- chattr ----------------
const Mode = enum { add, remove, set };

const ChOpts = struct { rec: bool = false, force: bool = false, verbose: bool = false, add: u32 = 0, rem: u32 = 0, set: ?u32 = null, version: ?c_ulong = null };

const settable: u32 = 0x1 | 0x2 | 0x8 | 0x10000 | 0x10 | 0x20 | 0x40 | 0x80 | 0x4 | 0x4000 | 0x8000 | 0x20000 | 0x800000 | 0x2000000 | 0x40000000 | 0x20000000 | 0x400 | 0x100000;

fn chOne(path: []const u8, o: *const ChOpts, rc: *u8) void {
    const cur = switch (getFlags(path, null)) {
        .err => |e| {
            if (!o.force) u.errf("chattr: {s} while reading flags on {s}\n", .{ u.strerr(e), path });
            rc.* = 1;
            return;
        },
        .flags => |f| f,
    };
    var nf: u32 = if (o.set) |s| s else cur;
    nf |= o.add;
    nf &= ~o.rem;
    if (o.set == null) nf = (nf & settable) | (cur & ~settable);
    if (o.verbose) u.outf("Flags of {s} set as ", .{path});
    if (o.verbose) {
        var b = u.Vec(u8).init(u.alloc);
        pushFlags(&b, nf, false);
        u.outf("{s}\n", .{b.items});
    }
    const rc_open = linux.open(u.zstr(path), .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOFOLLOW = true }, 0);
    if (!u.ok(rc_open)) {
        if (!o.force) u.errf("chattr: {s} while setting flags on {s}\n", .{ u.strerr(u.errno(rc_open)), path });
        rc.* = 1;
        return;
    }
    const fd: i32 = @intCast(rc_open);
    defer _ = linux.close(fd);
    if (nf != cur or o.set != null) {
        var f: c_ulong = nf;
        const r = linux.ioctl(fd, SETFLAGS, @intFromPtr(&f));
        if (!u.ok(r)) {
            if (!o.force) u.errf("chattr: {s} while setting flags on {s}\n", .{ u.strerr(u.errno(r)), path });
            rc.* = 1;
            return;
        }
    }
    if (o.version) |v| {
        var vv = v;
        const r = linux.ioctl(fd, SETVERSION, @intFromPtr(&vv));
        if (!u.ok(r)) {
            if (!o.force) u.errf("chattr: {s} while setting version on {s}\n", .{ u.strerr(u.errno(r)), path });
            rc.* = 1;
        }
    }
}

fn chRec(path: []const u8, o: *const ChOpts, rc: *u8) void {
    chOne(path, o, rc);
    const st = u.stat(path, false) orelse return;
    if (st.mode & linux.S.IFMT != linux.S.IFDIR) return;
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir(path, &ents)) return;
    for (ents.items) |e| {
        const full = joinPath(path, e.name);
        const s2 = u.stat(full, false) orelse continue;
        const t = s2.mode & linux.S.IFMT;
        if (t == linux.S.IFDIR) chRec(full, o, rc) else if (t == linux.S.IFREG) chOne(full, o, rc);
    }
}

const ch_usage = "Usage: chattr [-pRVf] [-+=aAcCdDeijPsStTuFx] [-v version] files...\n";

pub fn chattr(args: []const []const u8) u8 {
    var o = ChOpts{};
    var files = u.Vec([]const u8).init(u.alloc);
    var have_mode = false;
    var i: usize = 0;
    var opts_done = false;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (opts_done) {
            files.push(a);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            opts_done = true;
            continue;
        }
        if (a.len >= 2 and (a[0] == '+' or a[0] == '=' or (a[0] == '-' and std.mem.indexOfScalar(u8, "RVfvp", a[1]) == null))) {
            // mode argument
            var set_accum: u32 = 0;
            for (a[1..]) |ch| {
                var bit: u32 = 0;
                for (flag_defs) |d| if (d.ch == ch) {
                    bit = d.bit;
                };
                if (bit == 0 or (settable & bit == 0 and ch != 'e')) {
                    u.err(ch_usage);
                    return 1;
                }
                set_accum |= bit;
            }
            switch (a[0]) {
                '+' => o.add |= set_accum,
                '-' => o.rem |= set_accum,
                else => o.set = (o.set orelse 0) | set_accum,
            }
            have_mode = true;
            continue;
        }
        if (a.len >= 2 and a[0] == '-') {
            var k: usize = 1;
            while (k < a.len) : (k += 1) switch (a[k]) {
                'R' => o.rec = true,
                'f' => o.force = true,
                'p' => {
                    i += 1;
                },
                'V' => o.verbose = true,
                'v' => {
                    var val: []const u8 = a[k + 1 ..];
                    if (val.len == 0) {
                        i += 1;
                        if (i >= args.len) {
                            u.err(ch_usage);
                            return 1;
                        }
                        val = args[i];
                    }
                    o.version = std.fmt.parseInt(c_ulong, val, 0) catch {
                        u.errf("chattr: Invalid version {s}\n", .{val});
                        return 1;
                    };
                    k = a.len;
                },
                else => {
                    u.err(ch_usage);
                    return 1;
                },
            };
            continue;
        }
        files.push(a);
    }
    if ((!have_mode and o.version == null) or files.items.len == 0) {
        u.err(ch_usage);
        return 1;
    }
    var rc: u8 = 0;
    for (files.items) |f| {
        if (o.rec) chRec(f, &o, &rc) else chOne(f, &o, &rc);
    }
    return rc;
}
