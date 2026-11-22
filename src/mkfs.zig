// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// mkfs.vfat / mkdosfs / mkfs.fat - FAT12/16/32 creation (dosfstools 4 style options)
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");

const boot16 = [_]u8{ 0x0e, 0x1f, 0xbe, 0x5b, 0x7c, 0xac, 0x22, 0xc0, 0x74, 0x0b, 0x56, 0xb4, 0x0e, 0xbb, 0x07, 0x00, 0xcd, 0x10, 0x5e, 0xeb, 0xf0, 0x32, 0xe4, 0xcd, 0x16, 0xcd, 0x19, 0xeb, 0xfe };
const boot32 = [_]u8{ 0x0e, 0x1f, 0xbe, 0x77, 0x7c, 0xac, 0x22, 0xc0, 0x74, 0x0b, 0x56, 0xb4, 0x0e, 0xbb, 0x07, 0x00, 0xcd, 0x10, 0x5e, 0xeb, 0xf0, 0x32, 0xe4, 0xcd, 0x16, 0xcd, 0x19, 0xeb, 0xfe };
const boot_msg = "This is not a bootable disk.  Please insert a bootable floppy and\r\npress any key to try again ... \r\n";

fn le16(b: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, b[off..][0..2], v, .little);
}
fn le32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}

fn pwriteAll(fd: i32, data: []const u8, off: u64) bool {
    var done: usize = 0;
    while (done < data.len) {
        const r = linux.pwrite(fd, data.ptr + done, data.len - done, @intCast(off + done));
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r) or r == 0) return false;
        done += r;
    }
    return true;
}

fn zeroRange(fd: i32, off: u64, len: u64) bool {
    var buf: [65536]u8 = @splat(0);
    var done: u64 = 0;
    while (done < len) {
        const n: usize = @intCast(@min(buf.len, len - done));
        if (!pwriteAll(fd, buf[0..n], off + done)) return false;
        done += n;
    }
    return true;
}

fn dosTime() struct { time: u16, date: u16 } {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const secs: i64 = @intCast(ts.sec);
    const days = @divFloor(secs, 86400);
    const sod = @mod(secs, 86400);
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    if (m <= 2) y += 1;
    const t: u16 = @intCast((@divFloor(sod, 3600) << 11) | (@divFloor(@mod(sod, 3600), 60) << 5) | @divFloor(@mod(sod, 60), 2));
    const dt: u16 = @intCast(((y - 1980) << 9) | (m << 5) | d);
    return .{ .time = t, .date = dt };
}

fn mkfsLabel(s: []const u8) ?[11]u8 {
    var out: [11]u8 = @splat(' ');
    if (s.len > 11) return null;
    for (s, 0..) |ch, i| out[i] = std.ascii.toUpper(ch);
    return out;
}

pub fn mkfsVfat(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "", .key = 'a' }, .{ .name = "", .key = 'A' }, .{ .name = "", .key = 'b', .arg = .req },
        .{ .name = "", .key = 'c' }, .{ .name = "", .key = 'C' }, .{ .name = "", .key = 'D', .arg = .req },
        .{ .name = "", .key = 'f', .arg = .req }, .{ .name = "", .key = 'F', .arg = .req }, .{ .name = "", .key = 'g', .arg = .req },
        .{ .name = "", .key = 'h', .arg = .req }, .{ .name = "", .key = 'i', .arg = .req }, .{ .name = "", .key = 'I' },
        .{ .name = "", .key = 'l', .arg = .req }, .{ .name = "", .key = 'm', .arg = .req }, .{ .name = "", .key = 'M', .arg = .req },
        .{ .name = "", .key = 'n', .arg = .req }, .{ .name = "", .key = 'r', .arg = .req }, .{ .name = "", .key = 'R', .arg = .req },
        .{ .name = "", .key = 's', .arg = .req }, .{ .name = "", .key = 'S', .arg = .req }, .{ .name = "", .key = 'v' },
        .{ .name = "mbr", .key = 200, .arg = .opt }, .{ .name = "codepage", .key = 201, .arg = .req }, .{ .name = "variant", .key = 202, .arg = .req },
        .{ .name = "invariant", .key = 203 }, .{ .name = "help", .key = 204 },
    };
    var p = g.Parser.init("mkfs.fat", args, &opts);
    var label: []const u8 = "";
    var nfats: u32 = 2;
    var fat_bits: u32 = 0;
    var vol_id: ?u32 = null;
    var spc_user: u32 = 0;
    var sector_size: u32 = 0;
    var root_entries_user: u32 = 0;
    var res_user: u32 = 0;
    var media: u8 = 0xf8;
    var create = false;
    var verbose = false;
    var drive: u8 = 0x80;
    var hidden: u32 = 0;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'n' => label = it.val.?,
            'f' => nfats = std.fmt.parseInt(u32, it.val.?, 10) catch 2,
            'F' => {
                fat_bits = std.fmt.parseInt(u32, it.val.?, 10) catch 0;
                if (fat_bits != 12 and fat_bits != 16 and fat_bits != 32) {
                    u.errf("mkfs.fat: FAT size must be 12, 16 or 32, not {s}\n", .{it.val.?});
                    return 1;
                }
            },
            'i' => vol_id = std.fmt.parseInt(u32, it.val.?, 16) catch {
                u.errf("mkfs.fat: Volume ID must be a hexadecimal number\n", .{});
                return 1;
            },
            's' => {
                spc_user = std.fmt.parseInt(u32, it.val.?, 10) catch 0;
                if (spc_user == 0 or spc_user > 128 or (spc_user & (spc_user - 1)) != 0) {
                    u.errf("mkfs.fat: sectors per cluster must be a power of 2 (1..128), not {s}\n", .{it.val.?});
                    return 1;
                }
            },
            'S' => {
                sector_size = std.fmt.parseInt(u32, it.val.?, 10) catch 0;
                if (sector_size < 512 or (sector_size & (sector_size - 1)) != 0) {
                    u.errf("mkfs.fat: sector size must be a power of 2 and at least 512, not {s}\n", .{it.val.?});
                    return 1;
                }
            },
            'r' => root_entries_user = std.fmt.parseInt(u32, it.val.?, 10) catch 0,
            'R' => res_user = std.fmt.parseInt(u32, it.val.?, 10) catch 0,
            'M' => media = @intCast(std.fmt.parseInt(u32, it.val.?, 0) catch 0xf8),
            'D' => drive = @intCast(std.fmt.parseInt(u32, it.val.?, 0) catch 0x80),
            'h' => hidden = std.fmt.parseInt(u32, it.val.?, 0) catch 0,
            'C' => create = true,
            'v' => verbose = true,
            204 => {
                u.out("Usage: mkfs.fat [OPTIONS] TARGET [BLOCKS]\nCreate FAT filesystem in TARGET, which can be a block device or file. Use only\nup to BLOCKS 1024 byte blocks if specified. With the -C option, file TARGET will be\ncreated with a size of 1024 bytes times BLOCKS, which must be specified.\n");
                return 0;
            },
            else => {},
        }
    }
    const ops = p.operands.items;
    if (ops.len == 0) {
        u.err("Usage: mkfs.fat [OPTIONS] TARGET [BLOCKS]\n");
        return 1;
    }
    u.err("mkfs.fat 4.2 (2021-01-31)\n");
    const target = ops[0];
    var blocks_arg: ?u64 = null;
    if (ops.len > 1) blocks_arg = std.fmt.parseInt(u64, ops[1], 10) catch {
        u.errf("mkfs.fat: Bad block count {s}\n", .{ops[1]});
        return 1;
    };
    const ss: u32 = if (sector_size != 0) sector_size else 512;
    if (create) {
        const b = blocks_arg orelse {
            u.err("mkfs.fat: For -C, the block count must be given\n");
            return 1;
        };
        const rc = linux.open(u.zstr(target), .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o666);
        if (!u.ok(rc)) {
            u.errf("mkfs.fat: unable to create {s}\n", .{target});
            return 1;
        }
        _ = linux.ftruncate(@intCast(rc), @intCast(b * 1024));
        _ = linux.close(@intCast(rc));
    }
    const frc = linux.open(u.zstr(target), .{ .ACCMODE = .RDWR }, 0);
    if (!u.ok(frc)) {
        u.errf("mkfs.fat: unable to open {s}: {s}\n", .{ target, u.strerr(u.errno(frc)) });
        return 1;
    }
    const fd: i32 = @intCast(frc);
    defer _ = linux.close(fd);
    var size_bytes: u64 = 0;
    if (u.statFd(fd)) |st| {
        if (st.mode & linux.S.IFMT == linux.S.IFBLK) {
            var sz: u64 = 0;
            _ = linux.ioctl(fd, 0x80081272, @intFromPtr(&sz));
            size_bytes = sz;
        } else size_bytes = st.size;
    }
    if (blocks_arg) |b| if (b * 1024 < size_bytes or size_bytes == 0) {
        size_bytes = b * 1024;
    };
    const total_sectors: u64 = size_bytes / ss;
    if (total_sectors < 16) {
        u.errf("mkfs.fat: Block count too small\n", .{});
        return 1;
    }
    // --- geometry
    var res: u32 = if (res_user != 0) res_user else 1;
    var root_entries: u32 = if (root_entries_user != 0) root_entries_user else 512;
    var spc: u32 = spc_user;
    var bits = fat_bits;
    var fatsz: u32 = 0;
    var clusters: u64 = 0;
    const candidates = [_]u32{ 12, 16, 32 };
    for (candidates) |cb| {
        if (bits != 0 and cb != bits) continue;
        const c32 = cb == 32;
        const rs: u32 = if (c32) (if (res_user != 0) res_user else 32) else res;
        const re: u32 = if (c32) 0 else root_entries;
        const root_secs: u32 = (re * 32 + ss - 1) / ss;
        var s_try: u32 = spc_user;
        if (s_try == 0) {
            if (c32) {
                const gib = size_bytes >> 30;
                s_try = if (gib < 8) 8 else if (gib < 16) 16 else if (gib < 32) 32 else 64;
            } else s_try = 4;
            if (ss > 512) s_try = @max(1, s_try * 512 / ss);
        }
        var cl: u64 = 0;
        var fs: u32 = 1;
        while (true) {
            var it: u32 = 0;
            while (it < 64) : (it += 1) {
                if (total_sectors < rs + root_secs + @as(u64, nfats) * fs) break;
                const data = total_sectors - rs - root_secs - @as(u64, nfats) * fs;
                cl = data / s_try;
                const need_bytes: u64 = switch (cb) {
                    12 => ((cl + 2) * 3 + 1) / 2,
                    16 => (cl + 2) * 2,
                    else => (cl + 2) * 4,
                };
                const need: u32 = @intCast((need_bytes + ss - 1) / ss);
                if (need <= fs) break;
                fs = need;
            }
            const limit: u64 = if (cb == 12) 4084 else if (cb == 16) 65524 else std.math.maxInt(u32);
            if (cl > limit and spc_user == 0 and cb == 16 and s_try < 8 * 512 / ss) {
                s_try *= 2;
                fs = 1;
                continue;
            }
            break;
        }
        const fits = switch (cb) {
            12 => cl <= 4084,
            16 => cl >= 4085 and cl <= 65524 and (spc_user != 0 or s_try <= 8 * 512 / ss),
            else => cl >= 65525,
        };
        if (bits == 0 and !fits and cb != 32) continue;
        bits = cb;
        spc = s_try;
        fatsz = fs;
        clusters = cl;
        res = rs;
        root_entries = re;
        break;
    }
    if (bits == 0) {
        u.err("mkfs.fat: unable to select a FAT type for this size\n");
        return 1;
    }
    if (bits == 12 and clusters > 4084) {
        u.err("mkfs.fat: Too many clusters for the requested FAT12 size\n");
        return 1;
    }
    if (bits == 16 and (clusters > 65524 or clusters < 4085)) {
        if (fat_bits == 16) u.errf("mkfs.fat: WARNING: Number of clusters for 16 bit FAT is {s} ({d})\n", .{ if (clusters < 4085) "too small" else "too big", clusters });
    }
    if (bits == 32 and clusters < 65525 and fat_bits == 32) {
        u.errf("mkfs.fat: WARNING: Not enough clusters for a 32 bit FAT!\n", .{});
    }
    const is32 = bits == 32;
    const root_secs: u32 = if (is32) 0 else (root_entries * 32 + ss - 1) / ss;
    if (is32) root_entries = 0;
    const id: u32 = vol_id orelse blk: {
        var r: u32 = 0;
        _ = linux.getrandom(@ptrCast(&r), 4, 0);
        break :blk r;
    };
    // --- boot sector
    var bs: [4096]u8 = @splat(0);
    const boot = bs[0..ss];
    boot[0] = 0xeb;
    boot[1] = if (is32) 0x58 else 0x3c;
    boot[2] = 0x90;
    @memcpy(boot[3..11], "mkfs.fat");
    le16(boot, 11, @intCast(ss));
    boot[13] = @intCast(spc);
    le16(boot, 14, @intCast(res));
    boot[16] = @intCast(nfats);
    le16(boot, 17, @intCast(root_entries));
    if (total_sectors < 65536 and !is32) le16(boot, 19, @intCast(total_sectors));
    boot[21] = media;
    if (!is32) le16(boot, 22, @intCast(fatsz));
    // fake CHS geometry
    var spt: u32 = if (total_sectors <= 4096) 16 else if (total_sectors <= 524288) 32 else 63;
    var heads: u32 = 2;
    while (heads < 255 and total_sectors / (heads * spt) > 1024) heads *= 2;
    if (heads > 255) heads = 255;
    if (spt == 0) spt = 1;
    le16(boot, 24, @intCast(spt));
    le16(boot, 26, @intCast(heads));
    le32(boot, 28, hidden);
    if (total_sectors >= 65536 or is32) le32(boot, 32, @intCast(total_sectors));
    const lab = mkfsLabel(label) orelse {
        u.err("mkfs.fat: Label can be no longer than 11 characters\n");
        return 1;
    };
    const lab_arr: [11]u8 = if (label.len == 0) "NO NAME    ".* else lab;
    const fs_name: *const [8]u8 = switch (bits) {
        12 => "FAT12   ",
        16 => "FAT16   ",
        else => "FAT32   ",
    };
    if (is32) {
        le32(boot, 36, fatsz);
        le16(boot, 40, 0);
        le16(boot, 42, 0);
        le32(boot, 44, 2);
        le16(boot, 48, 1);
        le16(boot, 50, 6);
        boot[64] = drive;
        boot[66] = 0x29;
        le32(boot, 67, id);
        @memcpy(boot[71..82], &lab_arr);
        @memcpy(boot[82..90], fs_name);
        @memcpy(boot[90 .. 90 + boot32.len], &boot32);
        @memcpy(boot[0x77 .. 0x77 + boot_msg.len], boot_msg);
    } else {
        boot[36] = drive;
        boot[38] = 0x29;
        le32(boot, 39, id);
        @memcpy(boot[43..54], &lab_arr);
        @memcpy(boot[54..62], fs_name);
        @memcpy(boot[62 .. 62 + boot16.len], &boot16);
        @memcpy(boot[0x5b .. 0x5b + boot_msg.len], boot_msg);
    }
    boot[510] = 0x55;
    boot[511] = 0xaa;
    if (ss > 512) {
        boot[ss - 2] = 0x55;
        boot[ss - 1] = 0xaa;
    }
    const total_bytes = total_sectors * ss;
    _ = total_bytes;
    if (verbose) {
        u.errf("{s} has {d} head{s} and {d} sector{s} per track,\nhidden sectors 0x{x:0>4};\nlogical sector size is {d},\nusing 0x{x:0>2} media descriptor, with {d} sectors;\nfile system has {d} {d}-bit FAT{s} and {d} sector{s} per cluster.\nFAT size is {d} sector{s}, and provides {d} cluster{s}.\nThere {s} {d} reserved sector{s}.\n", .{
            target, heads, if (heads == 1) "" else "s", spt, if (spt == 1) "" else "s", hidden, ss, media, total_sectors, nfats, bits, if (nfats == 1) "" else "s", spc, if (spc == 1) "" else "s", fatsz, if (fatsz == 1) "" else "s", clusters, if (clusters == 1) "" else "s", if (res == 1) "is" else "are", res, if (res == 1) "" else "s",
        });
        if (!is32) u.errf("Root directory contains {d} slots and uses {d} sectors.\n", .{ root_entries, root_secs });
        u.errf("Volume ID is {x:0>8}, volume label {s}.\n", .{ id, lab_arr });
    }
    // --- write everything
    const fat_start: u64 = @as(u64, res) * ss;
    if (!zeroRange(fd, 0, fat_start + @as(u64, nfats) * fatsz * ss + @as(u64, root_secs) * ss + (if (is32) @as(u64, spc) * ss else 0))) {
        u.errf("mkfs.fat: write error: {s}\n", .{u.strerr(.IO)});
        return 1;
    }
    if (!pwriteAll(fd, boot, 0)) return 1;
    if (is32) {
        var fi: [4096]u8 = @splat(0);
        const f = fi[0..ss];
        le32(f, 0, 0x41615252);
        le32(f, 484, 0x61417272);
        le32(f, 488, @intCast(clusters - 1));
        le32(f, 492, 2);
        f[510] = 0x55;
        f[511] = 0xaa;
        _ = pwriteAll(fd, f, ss);
        _ = pwriteAll(fd, boot, 6 * @as(u64, ss));
        _ = pwriteAll(fd, f, 7 * @as(u64, ss));
    }
    // FATs
    var first: [16]u8 = @splat(0);
    var flen: usize = 0;
    switch (bits) {
        12 => {
            first[0] = media;
            first[1] = 0xff;
            first[2] = 0xff;
            flen = 3;
        },
        16 => {
            first[0] = media;
            first[1] = 0xff;
            first[2] = 0xff;
            first[3] = 0xff;
            flen = 4;
        },
        else => {
            first[0] = media;
            first[1] = 0xff;
            first[2] = 0xff;
            first[3] = 0x0f;
            @memset(first[4..8], 0xff);
            first[8] = 0xff;
            first[9] = 0xff;
            first[10] = 0xff;
            first[11] = 0x0f;
            flen = 12;
        },
    }
    var k: u32 = 0;
    while (k < nfats) : (k += 1) _ = pwriteAll(fd, first[0..flen], fat_start + @as(u64, k) * fatsz * ss);
    // volume label entry in the root directory
    const root_off: u64 = if (is32) fat_start + @as(u64, nfats) * fatsz * ss else fat_start + @as(u64, nfats) * fatsz * ss;
    if (label.len > 0) {
        var de: [32]u8 = @splat(0);
        @memcpy(de[0..11], &lab_arr);
        de[11] = 0x08;
        const dt = dosTime();
        le16(&de, 22, dt.time);
        le16(&de, 24, dt.date);
        _ = pwriteAll(fd, &de, root_off);
    }
    _ = linux.fsync(fd);
    return 0;
}

// ===================== mke2fs (ext2) =====================
fn nowSecs() u32 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

fn isPow(n: u32, b: u32) bool {
    var v: u32 = b;
    while (v < n) v *= b;
    return v == n;
}

fn hasBackup(group: u32) bool {
    if (group <= 1) return true;
    return isPow(group, 3) or isPow(group, 5) or isPow(group, 7);
}

fn setBit(buf: []u8, bit: usize) void {
    buf[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
}

pub fn mke2fs(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "", .key = 'b', .arg = .req }, .{ .name = "", .key = 'i', .arg = .req }, .{ .name = "", .key = 'N', .arg = .req },
        .{ .name = "", .key = 'm', .arg = .req }, .{ .name = "", .key = 'L', .arg = .req }, .{ .name = "", .key = 'U', .arg = .req },
        .{ .name = "", .key = 'O', .arg = .req }, .{ .name = "", .key = 't', .arg = .req }, .{ .name = "", .key = 'q' },
        .{ .name = "", .key = 'v' }, .{ .name = "", .key = 'F' }, .{ .name = "", .key = 'c' }, .{ .name = "", .key = 'E', .arg = .req },
        .{ .name = "", .key = 'I', .arg = .req }, .{ .name = "", .key = 'T', .arg = .req }, .{ .name = "", .key = 'r', .arg = .req },
        .{ .name = "", .key = 'j' }, .{ .name = "", .key = 'n' }, .{ .name = "", .key = 'M', .arg = .req }, .{ .name = "", .key = 'g', .arg = .req },
        .{ .name = "", .key = 'e', .arg = .req }, .{ .name = "", .key = 'l', .arg = .req }, .{ .name = "", .key = 'C', .arg = .req },
        .{ .name = "", .key = 'o', .arg = .req }, .{ .name = "", .key = 'S' }, .{ .name = "", .key = 'V' },
    };
    var p = g.Parser.init("mke2fs", args, &opts);
    var bsize: u32 = 0;
    var ratio: u32 = 0;
    var ninodes_user: u32 = 0;
    var resv_pct: f64 = 5;
    var label: []const u8 = "";
    var uuid: [16]u8 = undefined;
    _ = linux.getrandom(&uuid, 16, 0);
    uuid[6] = (uuid[6] & 0x0f) | 0x40;
    uuid[8] = (uuid[8] & 0x3f) | 0x80;
    var isize_: u32 = 128;
    var quiet = false;
    var dry = false;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'b' => {
                bsize = std.fmt.parseInt(u32, it.val.?, 10) catch 0;
                if (bsize != 1024 and bsize != 2048 and bsize != 4096 and bsize != 8192 and bsize != 16384 and bsize != 32768 and bsize != 65536) {
                    u.errf("mke2fs: invalid block size - {s}\n", .{it.val.?});
                    return 1;
                }
            },
            'i' => ratio = std.fmt.parseInt(u32, it.val.?, 10) catch 0,
            'N' => ninodes_user = std.fmt.parseInt(u32, it.val.?, 10) catch 0,
            'm' => resv_pct = std.fmt.parseFloat(f64, it.val.?) catch 5,
            'L' => label = it.val.?,
            'U' => {
                var k: usize = 0;
                var j: usize = 0;
                const t = it.val.?;
                while (k < t.len and j < 16) {
                    if (t[k] == '-') {
                        k += 1;
                        continue;
                    }
                    if (k + 1 >= t.len) break;
                    uuid[j] = std.fmt.parseInt(u8, t[k .. k + 2], 16) catch {
                        u.errf("mke2fs: could not parse UUID: {s}\n", .{t});
                        return 1;
                    };
                    j += 1;
                    k += 2;
                }
            },
            'I' => isize_ = std.fmt.parseInt(u32, it.val.?, 10) catch 128,
            'q' => quiet = true,
            'n' => dry = true,
            't' => {
                if (!std.mem.eql(u8, it.val.?, "ext2")) {
                    u.errf("mke2fs: only ext2 is supported ({s} requested)\n", .{it.val.?});
                    return 1;
                }
            },
            else => {},
        }
    }
    const ops = p.operands.items;
    if (ops.len == 0) {
        u.err("Usage: mke2fs [-c|-l filename] [-b block-size] [-C cluster-size]\n\t[-i bytes-per-inode] [-I inode-size] [-J journal-options]\n\t[-G flex-group-size] [-N number-of-inodes] [-d root-directory]\n\t[-m reserved-blocks-percentage] [-o creator-os]\n\t[-g blocks-per-group] [-L volume-label] [-M last-mounted-directory]\n\t[-O feature[,...]] [-r fs-revision] [-E extended-option[,...]]\n\t[-t fs-type] [-T usage-type ] [-U UUID] [-e errors_behavior][-z undo_file]\n\t[-jnqvDFSV] device [blocks-count]\n");
        return 1;
    }
    if (isize_ != 128 and isize_ != 256 and isize_ != 512 and isize_ != 1024) {
        u.errf("mke2fs: invalid inode size {d} (min 128/max 1024)\n", .{isize_});
        return 1;
    }
    const target = ops[0];
    const frc = linux.open(u.zstr(target), .{ .ACCMODE = .RDWR }, 0);
    if (!u.ok(frc)) {
        u.errf("mke2fs: {s} while trying to determine filesystem size\n", .{u.strerr(u.errno(frc))});
        return 1;
    }
    const fd: i32 = @intCast(frc);
    defer _ = linux.close(fd);
    var dev_bytes: u64 = 0;
    if (u.statFd(fd)) |st| {
        if (st.mode & linux.S.IFMT == linux.S.IFBLK) {
            var sz: u64 = 0;
            _ = linux.ioctl(fd, 0x80081272, @intFromPtr(&sz));
            dev_bytes = sz;
        } else dev_bytes = st.size;
    }
    if (bsize == 0) bsize = if (dev_bytes < 512 * 1024 * 1024) 1024 else 4096;
    var blocks: u64 = dev_bytes / bsize;
    if (ops.len > 1) {
        const n = std.fmt.parseInt(u64, ops[1], 10) catch {
            u.errf("mke2fs: invalid blocks '{s}' on device '{s}'\n", .{ ops[1], target });
            return 1;
        };
        blocks = n * 1024 / bsize;
    }
    if (blocks < 64) {
        u.err("mke2fs: Device size reported to be zero or too small. Invalid partition specified, or\n\tpartition table wasn't reread after running fdisk, due to\n\ta modified partition being busy and in use.\n");
        return 1;
    }
    if (ratio == 0) ratio = if (dev_bytes < 3 * 1024 * 1024) 8192 else if (dev_bytes < 512 * 1024 * 1024) 4096 else 16384;
    if (ratio < bsize) ratio = bsize;
    const first_data: u32 = if (bsize == 1024) 1 else 0;
    const bpg: u32 = bsize * 8;
    var groups: u32 = @intCast((blocks - first_data + bpg - 1) / bpg);
    var ipg: u32 = 0;
    var itable_blocks: u32 = 0;
    var gdt_blocks: u32 = 0;
    while (true) {
        gdt_blocks = (groups * 32 + bsize - 1) / bsize;
        const total_inodes: u64 = if (ninodes_user != 0) ninodes_user else blocks * bsize / ratio;
        var per: u64 = (total_inodes + groups - 1) / groups;
        const per_block: u32 = bsize / isize_;
        per = @max(per, 16);
        per = (per + per_block - 1) / per_block * per_block;
        if (per > bpg) per = bpg;
        per = (per + 7) / 8 * 8;
        ipg = @intCast(per);
        itable_blocks = ipg * isize_ / bsize;
        // drop a runt last group
        const last_blocks: u64 = blocks - first_data - @as(u64, groups - 1) * bpg;
        const overhead: u64 = (if (hasBackup(groups - 1)) 1 + gdt_blocks else 0) + 2 + itable_blocks;
        if (groups > 1 and last_blocks < overhead + 50) {
            blocks -= last_blocks;
            groups -= 1;
            continue;
        }
        break;
    }
    const total_inodes: u32 = ipg * groups;
    const resv_blocks: u64 = @intFromFloat(@as(f64, @floatFromInt(blocks)) * resv_pct / 100.0);
    if (!quiet) u.err("mke2fs 1.47.3 (8-Jul-2025)\n");
    if (dry) return 0;
    // ---- build group layout
    const gd = u.alloc.alloc(u8, @as(usize, gdt_blocks) * bsize) catch return 1;
    @memset(gd, 0);
    const GroupInfo = struct { bb: u32, ib: u32, it: u32, free_blocks: u32, free_inodes: u32, dirs: u32, nblocks: u32, start: u32 };
    var gi = u.Vec(GroupInfo).init(u.alloc);
    var total_free: u64 = 0;
    var gidx: u32 = 0;
    while (gidx < groups) : (gidx += 1) {
        const start: u32 = first_data + gidx * bpg;
        const gblocks: u32 = @intCast(@min(@as(u64, bpg), blocks - start));
        var off: u32 = start;
        if (hasBackup(gidx)) off += 1 + gdt_blocks;
        const bb = off;
        const ib = off + 1;
        const it = off + 2;
        const used_end = it + itable_blocks;
        const free: u32 = gblocks - (used_end - start);
        gi.push(.{ .bb = bb, .ib = ib, .it = it, .free_blocks = free, .free_inodes = ipg, .dirs = 0, .nblocks = gblocks, .start = start });
    }
    // data blocks for the root directory and lost+found come from group 0
    const lpf_blocks: u32 = @min(@max(@as(u32, 16 * 1024 / bsize), 4), 12);
    const g0 = &gi.items[0];
    const root_block: u32 = g0.it + itable_blocks;
    const lpf_first: u32 = root_block + 1;
    const used_data: u32 = 1 + lpf_blocks;
    g0.free_blocks -= used_data;
    g0.free_inodes -= 11;
    g0.dirs = 2;
    for (gi.items) |gr| total_free += gr.free_blocks;
    const now = nowSecs();
    // ---- superblock
    var sb: [1024]u8 = @splat(0);
    le32(&sb, 0, total_inodes);
    le32(&sb, 4, @intCast(blocks));
    le32(&sb, 8, @intCast(resv_blocks));
    le32(&sb, 12, @intCast(total_free));
    le32(&sb, 16, total_inodes - 11);
    le32(&sb, 20, first_data);
    le32(&sb, 24, std.math.log2_int(u32, bsize / 1024));
    le32(&sb, 28, std.math.log2_int(u32, bsize / 1024));
    le32(&sb, 32, bpg);
    le32(&sb, 36, bpg);
    le32(&sb, 40, ipg);
    le32(&sb, 48, now);
    le16(&sb, 52, 0);
    le16(&sb, 54, 0xffff);
    le16(&sb, 56, 0xef53);
    le16(&sb, 58, 1);
    le16(&sb, 60, 1);
    le32(&sb, 64, now);
    le32(&sb, 76, 1);
    le32(&sb, 84, 11);
    le16(&sb, 88, @intCast(isize_));
    le32(&sb, 92, 0); // compat
    le32(&sb, 96, 0x2); // incompat: filetype
    le32(&sb, 100, 0x1); // ro_compat: sparse_super
    @memcpy(sb[104..120], &uuid);
    if (label.len > 0) {
        const ll: usize = @min(label.len, 16);
        @memcpy(sb[120..][0..ll], label[0..ll]);
    }
    le32(&sb, 264, 0);
    var hs: [16]u8 = undefined;
    _ = linux.getrandom(&hs, 16, 0);
    @memcpy(sb[236..252], &hs);
    sb[252] = 1;
    le16(&sb, 254, 0);
    // ---- group descriptors
    for (gi.items, 0..) |gr, k| {
        const d = gd[k * 32 ..][0..32];
        le32(d, 0, gr.bb);
        le32(d, 4, gr.ib);
        le32(d, 8, gr.it);
        le16(d, 12, @intCast(gr.free_blocks));
        le16(d, 14, @intCast(gr.free_inodes));
        le16(d, 16, @intCast(gr.dirs));
    }
    // ---- write metadata
    var k2: u32 = 0;
    while (k2 < groups) : (k2 += 1) {
        const gr = gi.items[k2];
        if (hasBackup(k2)) {
            var sbc = sb;
            le16(&sbc, 90, @intCast(k2));
            _ = pwriteAll(fd, &sbc, @as(u64, gr.start) * bsize + @as(u64, if (k2 == 0 and bsize > 1024) 1024 else 0));
            _ = pwriteAll(fd, gd, @as(u64, gr.start + 1) * bsize);
        }
        // bitmaps
        const bm = u.alloc.alloc(u8, bsize) catch return 1;
        defer u.alloc.free(bm);
        @memset(bm, 0);
        var b: u32 = 0;
        while (b < gr.it + itable_blocks - gr.start) : (b += 1) setBit(bm, b);
        if (k2 == 0) {
            var d0: u32 = 0;
            while (d0 < used_data) : (d0 += 1) setBit(bm, root_block - gr.start + d0);
        }
        var pad: u32 = gr.nblocks;
        while (pad < bsize * 8) : (pad += 1) setBit(bm, pad);
        _ = pwriteAll(fd, bm, @as(u64, gr.bb) * bsize);
        @memset(bm, 0);
        if (k2 == 0) {
            var iu: u32 = 0;
            while (iu < 11) : (iu += 1) setBit(bm, iu);
        }
        var ipad: u32 = ipg;
        while (ipad < bsize * 8) : (ipad += 1) setBit(bm, ipad);
        _ = pwriteAll(fd, bm, @as(u64, gr.ib) * bsize);
        // inode table
        _ = zeroRange(fd, @as(u64, gr.it) * bsize, @as(u64, itable_blocks) * bsize);
    }
    // ---- root directory and lost+found
    const itbl0: u64 = @as(u64, gi.items[0].it) * bsize;
    const mkdirInode = struct {
        fn write(fdx: i32, base: u64, ino: u32, isz: u32, bs: u32, links: u16, first: u32, count: u32, t: u32) void {
            var inode: [1024]u8 = @splat(0);
            le16(&inode, 0, 0x41ed);
            le32(&inode, 4, count * bs);
            le32(&inode, 8, t);
            le32(&inode, 12, t);
            le32(&inode, 16, t);
            le16(&inode, 26, links);
            le32(&inode, 28, count * (bs / 512));
            var q: u32 = 0;
            while (q < count and q < 12) : (q += 1) le32(&inode, 40 + q * 4, first + q);
            _ = pwriteAll(fdx, inode[0..128], base + @as(u64, ino - 1) * isz);
        }
    };
    mkdirInode.write(fd, itbl0, 2, isize_, bsize, 3, root_block, 1, now);
    mkdirInode.write(fd, itbl0, 11, isize_, bsize, 2, lpf_first, lpf_blocks, now);
    {
        const blk = u.alloc.alloc(u8, bsize) catch return 1;
        defer u.alloc.free(blk);
        @memset(blk, 0);
        // root: ".", "..", "lost+found"
        le32(blk, 0, 2);
        le16(blk, 4, 12);
        blk[6] = 1;
        blk[7] = 2;
        blk[8] = '.';
        le32(blk, 12, 2);
        le16(blk, 16, 12);
        blk[18] = 2;
        blk[19] = 2;
        blk[20] = '.';
        blk[21] = '.';
        le32(blk, 24, 11);
        le16(blk, 28, @intCast(bsize - 24));
        blk[30] = 10;
        blk[31] = 2;
        @memcpy(blk[32..42], "lost+found");
        _ = pwriteAll(fd, blk, @as(u64, root_block) * bsize);
        // lost+found
        @memset(blk, 0);
        le32(blk, 0, 11);
        le16(blk, 4, 12);
        blk[6] = 1;
        blk[7] = 2;
        blk[8] = '.';
        le32(blk, 12, 2);
        le16(blk, 16, @intCast(bsize - 12));
        blk[18] = 2;
        blk[19] = 2;
        blk[20] = '.';
        blk[21] = '.';
        _ = pwriteAll(fd, blk, @as(u64, lpf_first) * bsize);
        var l: u32 = 1;
        while (l < lpf_blocks) : (l += 1) {
            @memset(blk, 0);
            le16(blk, 4, @intCast(bsize));
            _ = pwriteAll(fd, blk, @as(u64, lpf_first + l) * bsize);
        }
    }
    _ = linux.fsync(fd);
    if (!quiet) {
        u.outf("Creating filesystem with {d} {d}k blocks and {d} inodes\n", .{ blocks, bsize / 1024, total_inodes });
        u.outf("Filesystem UUID: {x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{ uuid[0], uuid[1], uuid[2], uuid[3], uuid[4], uuid[5], uuid[6], uuid[7], uuid[8], uuid[9], uuid[10], uuid[11], uuid[12], uuid[13], uuid[14], uuid[15] });
        u.out("Superblock backups stored on blocks: ");
        var first_b = true;
        var gg: u32 = 1;
        while (gg < groups) : (gg += 1) if (hasBackup(gg)) {
            if (!first_b) u.out(", ");
            first_b = false;
            u.outf("{d}", .{gi.items[gg].start});
        };
        u.out("\n\nAllocating group tables: done\nWriting inode tables: done\nWriting superblocks and filesystem accounting information: done\n\n");
    }
    return 0;
}

pub fn mkfsReiser(args: []const []const u8) u8 {
    _ = args;
    u.err("mkfs.reiser: creating ReiserFS file systems is not supported by cmdbox (ReiserFS is deprecated in Linux and removed from 6.13)\n");
    return 1;
}
