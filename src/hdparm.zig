// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// hdparm - block device parameters through ioctls (subset of hdparm 9.x)
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const mnt = @import("mount.zig");

const BLKROSET = 0x125d;
const BLKROGET = 0x125e;
const BLKRRPART = 0x125f;
const BLKFLSBUF = 0x1261;
const BLKRASET = 0x1262;
const BLKRAGET = 0x1263;
const BLKGETSIZE64 = 0x80081272;
const HDIO_GETGEO = 0x0301;
const HDIO_GET_MULTCOUNT = 0x0304;
const HDIO_GET_32BIT = 0x0309;
const HDIO_GET_IDENTITY = 0x030d;

fn nowUs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1000);
}

fn onOff(v: anytype) []const u8 {
    return if (v != 0) "on" else "off";
}

fn trimIdent(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \x00");
}

pub fn hdparm(args: []const []const u8) u8 {
    var devs = u.Vec([]const u8).init(u.alloc);
    const Act = struct { kind: u8, val: ?i64 };
    var acts = u.Vec(Act).init(u.alloc);
    for (args) |a| {
        if (a.len > 1 and a[0] == '-' and a[1] != '-') {
            var i: usize = 1;
            while (i < a.len) : (i += 1) {
                const ch = a[i];
                switch (ch) {
                    'a', 'r', 'm', 'c', 'd', 'k', 'n', 'u', 'W', 'A', 'S', 'B', 'M' => {
                        var j = i + 1;
                        while (j < a.len and std.ascii.isDigit(a[j])) j += 1;
                        const v: ?i64 = if (j > i + 1) (std.fmt.parseInt(i64, a[i + 1 .. j], 10) catch null) else null;
                        acts.push(.{ .kind = ch, .val = v });
                        i = j - 1;
                    },
                    'g', 'f', 'z', 't', 'T', 'i', 'I', 'y', 'Y', 'Z', 'C', 'H', 'v', 'V' => acts.push(.{ .kind = ch, .val = null }),
                    else => {
                        u.errf("hdparm: invalid option -- '{c}'\n", .{ch});
                        return 1;
                    },
                }
            }
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            u.out("\nhdparm - get/set hard disk parameters - version v9.65 (cmdbox)\n\nUsage:  hdparm  [options] [device ...]\n\nOptions:\n -a   get/set fs readahead\n -f   flush buffer cache for device on exit\n -g   display drive geometry\n -i   display drive identification\n -r   get/set device readonly flag\n -t   perform device read timings\n -T   perform cache read timings\n -z   reread partition table\n");
            return 0;
        } else devs.push(a);
    }
    if (devs.items.len == 0) {
        u.err("hdparm: no device specified\n");
        return 1;
    }
    var status: u8 = 0;
    for (devs.items) |dev| {
        const frc = linux.open(u.zstr(dev), .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
        if (!u.ok(frc)) {
            u.errf("{s}: No such file or directory\n", .{dev});
            status = 1;
            continue;
        }
        const fd: i32 = @intCast(frc);
        defer _ = linux.close(fd);
        u.outf("\n{s}:\n", .{dev});
        var list = acts;
        if (acts.items.len == 0) {
            list = u.Vec(Act).init(u.alloc);
            for ("cdrag") |k| _ = k;
            for ([_]u8{ 'm', 'c', 'r', 'a', 'g' }) |k| list.push(.{ .kind = k, .val = null });
        }
        for (list.items) |act| {
            switch (act.kind) {
                'a' => {
                    if (act.val) |v| {
                        u.outf(" setting fs readahead to {d}\n", .{v});
                        if (!u.ok(linux.ioctl(fd, BLKRASET, @intCast(v)))) {
                            u.errf(" BLKRASET failed: {s}\n", .{u.strerr(u.errno(linux.ioctl(fd, BLKRASET, @intCast(v))))});
                            status = 1;
                        }
                    }
                    var ra: c_ulong = 0;
                    if (u.ok(linux.ioctl(fd, BLKRAGET, @intFromPtr(&ra)))) u.outf(" readahead     = {d: >3} ({s})\n", .{ ra, onOff(ra) }) else {
                        u.errf(" HDIO_GET_READAHEAD failed: {s}\n", .{u.strerr(u.errno(linux.ioctl(fd, BLKRAGET, @intFromPtr(&ra))))});
                        status = 1;
                    }
                },
                'r' => {
                    if (act.val) |v| {
                        u.outf(" setting readonly to {d} ({s})\n", .{ @as(u32, @intCast(v)), onOff(v) });
                        var flag: c_int = @intCast(v);
                        if (!u.ok(linux.ioctl(fd, BLKROSET, @intFromPtr(&flag)))) {
                            u.errf(" BLKROSET failed: {s}\n", .{u.strerr(.PERM)});
                            status = 1;
                        }
                    }
                    var ro: c_int = 0;
                    if (u.ok(linux.ioctl(fd, BLKROGET, @intFromPtr(&ro)))) u.outf(" readonly      = {d: >2} ({s})\n", .{ @as(u32, @intCast(ro)), onOff(ro) });
                },
                'm' => {
                    var mc: c_ulong = 0;
                    if (u.ok(linux.ioctl(fd, HDIO_GET_MULTCOUNT, @intFromPtr(&mc)))) u.outf(" multcount     = {d: >2} ({s})\n", .{ mc, onOff(mc) });
                },
                'c' => {
                    var io: c_ulong = 0;
                    if (u.ok(linux.ioctl(fd, HDIO_GET_32BIT, @intFromPtr(&io)))) {
                        const txt: []const u8 = switch (io) {
                            0 => "default 16-bit",
                            2 => "16-bit w/sync",
                            1 => "32-bit",
                            3 => "32-bit w/sync",
                            else => "unknown",
                        };
                        u.outf(" IO_support    = {d: >2} ({s})\n", .{ io, txt });
                    }
                },
                'g' => {
                    var geo: [16]u8 = @splat(0); // heads, sectors, cylinders(u16), start(ulong)
                    var size: u64 = 0;
                    _ = linux.ioctl(fd, BLKGETSIZE64, @intFromPtr(&size));
                    if (u.ok(linux.ioctl(fd, HDIO_GETGEO, @intFromPtr(&geo)))) {
                        const heads = geo[0];
                        const secs = geo[1];
                        const cyls = std.mem.readInt(u16, geo[2..4], .little);
                        const start = std.mem.readInt(u64, geo[8..16], .little);
                        u.outf(" geometry      = {d}/{d}/{d}, sectors = {d}, start = {d}\n", .{ cyls, heads, secs, size / 512, start });
                    }
                },
                'f' => {
                    u.out(" flushing buffer cache\n");
                    _ = linux.ioctl(fd, BLKFLSBUF, 0);
                    _ = linux.fsync(fd);
                },
                'z' => {
                    u.out(" re-reading partition table\n");
                    if (!u.ok(linux.ioctl(fd, BLKRRPART, 0))) {
                        u.errf("BLKRRPART failed: {s}\n", .{u.strerr(u.errno(linux.ioctl(fd, BLKRRPART, 0)))});
                        status = 1;
                    }
                },
                't' => {
                    const dfd = linux.open(u.zstr(dev), .{ .ACCMODE = .RDONLY, .DIRECT = true }, 0);
                    const rfd: i32 = if (u.ok(dfd)) @intCast(dfd) else fd;
                    const buf = u.alloc.alignedAlloc(u8, .fromByteUnits(4096), 2 * 1024 * 1024) catch continue;
                    defer u.alloc.free(buf);
                    var total: u64 = 0;
                    var off: u64 = 0;
                    const t0 = nowUs();
                    while (nowUs() - t0 < 3_000_000) {
                        const r = linux.pread(rfd, buf.ptr, buf.len, @intCast(off));
                        if (!u.ok(r) or r == 0) break;
                        total += r;
                        off += r;
                    }
                    if (rfd != fd) _ = linux.close(rfd);
                    const el = @as(f64, @floatFromInt(nowUs() - t0)) / 1e6;
                    const mb = @as(f64, @floatFromInt(total)) / (1024 * 1024);
                    u.outf(" Timing buffered disk reads: {d:.0} MB in {d: >5.2} seconds = {d:.2} MB/sec\n", .{ mb, el, mb / el });
                },
                'T' => {
                    const buf = u.alloc.alloc(u8, 2 * 1024 * 1024) catch continue;
                    defer u.alloc.free(buf);
                    _ = linux.pread(fd, buf.ptr, buf.len, 0);
                    var total: u64 = 0;
                    const t0 = nowUs();
                    while (nowUs() - t0 < 2_000_000) {
                        const r = linux.pread(fd, buf.ptr, buf.len, 0);
                        if (!u.ok(r) or r == 0) break;
                        total += r;
                    }
                    const el = @as(f64, @floatFromInt(nowUs() - t0)) / 1e6;
                    const mb = @as(f64, @floatFromInt(total)) / (1024 * 1024);
                    u.outf(" Timing cached reads:   {d:.0} MB in {d: >5.2} seconds = {d:.2} MB/sec\n", .{ mb, el, mb / el });
                },
                'i', 'I' => {
                    var id: [512]u8 = @splat(0);
                    if (u.ok(linux.ioctl(fd, HDIO_GET_IDENTITY, @intFromPtr(&id)))) {
                        u.outf("\n Model={s}, FwRev={s}, SerialNo={s}\n", .{ trimIdent(id[54..94]), trimIdent(id[46..54]), trimIdent(id[20..40]) });
                    } else {
                        const nm = std.fs.path.basename(dev);
                        const mp = std.fmt.allocPrint(u.alloc, "/sys/block/{s}/device/model", .{nm}) catch "";
                        const rp = std.fmt.allocPrint(u.alloc, "/sys/block/{s}/device/rev", .{nm}) catch "";
                        const model = mnt.readFile(mp) orelse "";
                        const rev = mnt.readFile(rp) orelse "";
                        u.outf("\n Model={s}, FwRev={s}, SerialNo=\n", .{ std.mem.trim(u8, model, " \n"), std.mem.trim(u8, rev, " \n") });
                    }
                },
                else => {
                    u.errf(" -{c}: not supported by this hdparm\n", .{act.kind});
                    status = 1;
                },
            }
        }
    }
    return status;
}
