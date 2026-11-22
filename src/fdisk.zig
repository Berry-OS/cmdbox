// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// fdisk -l - partition table listing (DOS/MBR with logical partitions, GPT), util-linux layout
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const mnt = @import("mount.zig");

const mbr_types = [_]struct { id: u8, name: []const u8 }{
    .{ .id = 0x00, .name = "Empty" }, .{ .id = 0x01, .name = "FAT12" }, .{ .id = 0x02, .name = "XENIX root" },
    .{ .id = 0x03, .name = "XENIX usr" }, .{ .id = 0x04, .name = "FAT16 <32M" }, .{ .id = 0x05, .name = "Extended" },
    .{ .id = 0x06, .name = "FAT16" }, .{ .id = 0x07, .name = "HPFS/NTFS/exFAT" }, .{ .id = 0x08, .name = "AIX" },
    .{ .id = 0x09, .name = "AIX bootable" }, .{ .id = 0x0a, .name = "OS/2 Boot Manager" }, .{ .id = 0x0b, .name = "W95 FAT32" },
    .{ .id = 0x0c, .name = "W95 FAT32 (LBA)" }, .{ .id = 0x0e, .name = "W95 FAT16 (LBA)" }, .{ .id = 0x0f, .name = "W95 Ext'd (LBA)" },
    .{ .id = 0x10, .name = "OPUS" }, .{ .id = 0x11, .name = "Hidden FAT12" }, .{ .id = 0x12, .name = "Compaq diagnostics" },
    .{ .id = 0x14, .name = "Hidden FAT16 <32M" }, .{ .id = 0x16, .name = "Hidden FAT16" }, .{ .id = 0x17, .name = "Hidden HPFS/NTFS" },
    .{ .id = 0x1b, .name = "Hidden W95 FAT32" }, .{ .id = 0x1c, .name = "Hidden W95 FAT32 (LBA)" }, .{ .id = 0x1e, .name = "Hidden W95 FAT16 (LBA)" },
    .{ .id = 0x24, .name = "NEC DOS" }, .{ .id = 0x27, .name = "Hidden NTFS WinRE" }, .{ .id = 0x39, .name = "Plan 9" },
    .{ .id = 0x3c, .name = "PartitionMagic recovery" }, .{ .id = 0x40, .name = "Venix 80286" }, .{ .id = 0x41, .name = "PPC PReP Boot" },
    .{ .id = 0x42, .name = "SFS" }, .{ .id = 0x4d, .name = "QNX4.x" }, .{ .id = 0x4e, .name = "QNX4.x 2nd part" },
    .{ .id = 0x4f, .name = "QNX4.x 3rd part" }, .{ .id = 0x50, .name = "OnTrack DM" }, .{ .id = 0x51, .name = "OnTrack DM6 Aux1" },
    .{ .id = 0x52, .name = "CP/M" }, .{ .id = 0x53, .name = "OnTrack DM6 Aux3" }, .{ .id = 0x54, .name = "OnTrackDM6" },
    .{ .id = 0x55, .name = "EZ-Drive" }, .{ .id = 0x56, .name = "Golden Bow" }, .{ .id = 0x5c, .name = "Priam Edisk" },
    .{ .id = 0x61, .name = "SpeedStor" }, .{ .id = 0x63, .name = "GNU HURD or SysV" }, .{ .id = 0x64, .name = "Novell Netware 286" },
    .{ .id = 0x65, .name = "Novell Netware 386" }, .{ .id = 0x70, .name = "DiskSecure Multi-Boot" }, .{ .id = 0x75, .name = "PC/IX" },
    .{ .id = 0x80, .name = "Old Minix" }, .{ .id = 0x81, .name = "Minix / old Linux" }, .{ .id = 0x82, .name = "Linux swap / Solaris" },
    .{ .id = 0x83, .name = "Linux" }, .{ .id = 0x84, .name = "OS/2 hidden or Intel hibernation" }, .{ .id = 0x85, .name = "Linux extended" },
    .{ .id = 0x86, .name = "NTFS volume set" }, .{ .id = 0x87, .name = "NTFS volume set" }, .{ .id = 0x88, .name = "Linux plaintext" },
    .{ .id = 0x8e, .name = "Linux LVM" }, .{ .id = 0x93, .name = "Amoeba" }, .{ .id = 0x94, .name = "Amoeba BBT" },
    .{ .id = 0x9f, .name = "BSD/OS" }, .{ .id = 0xa0, .name = "IBM Thinkpad hibernation" }, .{ .id = 0xa5, .name = "FreeBSD" },
    .{ .id = 0xa6, .name = "OpenBSD" }, .{ .id = 0xa7, .name = "NeXTSTEP" }, .{ .id = 0xa8, .name = "Darwin UFS" },
    .{ .id = 0xa9, .name = "NetBSD" }, .{ .id = 0xab, .name = "Darwin boot" }, .{ .id = 0xaf, .name = "HFS / HFS+" },
    .{ .id = 0xb7, .name = "BSDI fs" }, .{ .id = 0xb8, .name = "BSDI swap" }, .{ .id = 0xbb, .name = "Boot Wizard hidden" },
    .{ .id = 0xbc, .name = "Acronis FAT32 LBA" }, .{ .id = 0xbe, .name = "Solaris boot" }, .{ .id = 0xbf, .name = "Solaris" },
    .{ .id = 0xc1, .name = "DRDOS/sec (FAT-12)" }, .{ .id = 0xc4, .name = "DRDOS/sec (FAT-16 < 32M)" }, .{ .id = 0xc6, .name = "DRDOS/sec (FAT-16)" },
    .{ .id = 0xc7, .name = "Syrinx" }, .{ .id = 0xda, .name = "Non-FS data" }, .{ .id = 0xdb, .name = "CP/M / CTOS / ..." },
    .{ .id = 0xde, .name = "Dell Utility" }, .{ .id = 0xdf, .name = "BootIt" }, .{ .id = 0xe1, .name = "DOS access" },
    .{ .id = 0xe3, .name = "DOS R/O" }, .{ .id = 0xe4, .name = "SpeedStor" }, .{ .id = 0xea, .name = "Linux extended boot" },
    .{ .id = 0xeb, .name = "BeOS fs" }, .{ .id = 0xee, .name = "GPT" }, .{ .id = 0xef, .name = "EFI (FAT-12/16/32)" },
    .{ .id = 0xf0, .name = "Linux/PA-RISC boot" }, .{ .id = 0xf1, .name = "SpeedStor" }, .{ .id = 0xf4, .name = "SpeedStor" },
    .{ .id = 0xf2, .name = "DOS secondary" }, .{ .id = 0xf8, .name = "EBBR protective" }, .{ .id = 0xfb, .name = "VMware VMFS" },
    .{ .id = 0xfc, .name = "VMware VMKCORE" }, .{ .id = 0xfd, .name = "Linux raid autodetect" }, .{ .id = 0xfe, .name = "LANstep" },
    .{ .id = 0xff, .name = "BBT" },
};

const gpt_types = [_]struct { guid: []const u8, name: []const u8 }{
    .{ .guid = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", .name = "EFI System" },
    .{ .guid = "024DEE41-33E7-11D3-9D69-0008C781F39F", .name = "MBR partition scheme" },
    .{ .guid = "21686148-6449-6E6F-744E-656564454649", .name = "BIOS boot" },
    .{ .guid = "D3BFE2DE-3DAF-11DF-BA40-E3A556D89593", .name = "Intel Fast Flash" },
    .{ .guid = "F4019732-066E-4E12-8273-346C5641494F", .name = "Sony boot partition" },
    .{ .guid = "BFBFAFE7-A34F-448A-9A5B-6213EB736C22", .name = "Lenovo boot partition" },
    .{ .guid = "E3C9E316-0B5C-4DB8-817D-F92DF00215AE", .name = "Microsoft reserved" },
    .{ .guid = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", .name = "Microsoft basic data" },
    .{ .guid = "5808C8AA-7E8F-42E0-85D2-E1E90434CFB3", .name = "Microsoft LDM metadata" },
    .{ .guid = "AF9B60A0-1431-4F62-BC68-3311714A69AD", .name = "Microsoft LDM data" },
    .{ .guid = "DE94BBA4-06D1-4D40-A16A-BFD50179D6AC", .name = "Windows recovery environment" },
    .{ .guid = "37AFFC90-EF7D-4E96-91C3-2D7AE055B174", .name = "IBM General Parallel Fs" },
    .{ .guid = "E75CAF8F-F680-4CEE-AFA3-B001E56EFC2D", .name = "Microsoft Storage Spaces" },
    .{ .guid = "75894C1E-3AEB-11D3-B7C1-7B03A0000000", .name = "HP-UX data" },
    .{ .guid = "E2A1E728-32E3-11D6-A682-7B03A0000000", .name = "HP-UX service" },
    .{ .guid = "0FC63DAF-8483-4772-8E79-3D69D8477DE4", .name = "Linux filesystem" },
    .{ .guid = "A19D880F-05FC-4D3B-A006-743F0F84911E", .name = "Linux RAID" },
    .{ .guid = "6A898CC3-1DD2-11B2-99A6-080020736631", .name = "Linux filesystem" },
    .{ .guid = "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F", .name = "Linux swap" },
    .{ .guid = "E6D6D379-F507-44C2-A23C-238F2A3DF928", .name = "Linux LVM" },
    .{ .guid = "933AC7E1-2EB4-4F13-B844-0E14E2AEF915", .name = "Linux home" },
    .{ .guid = "3B8F8425-20E0-4F3B-907F-1A25A76F98E8", .name = "Linux server data" },
    .{ .guid = "4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709", .name = "Linux root (x86-64)" },
    .{ .guid = "B921B045-1DF0-41C3-AF44-4C6F280D3FAE", .name = "Linux root (ARM-64)" },
    .{ .guid = "69DAD710-2CE4-4E3C-B16C-21A1D49ABED3", .name = "Linux root (ARM)" },
    .{ .guid = "44479540-F297-41B2-9AF7-D131D5F0458A", .name = "Linux root (x86)" },
    .{ .guid = "8DA63339-0007-60C0-C436-083AC8230908", .name = "Linux reserved" },
    .{ .guid = "BC13C2FF-59E6-4262-A352-B275FD6F7172", .name = "Linux extended boot" },
    .{ .guid = "773F91EF-66D4-49B5-BD83-D683BF40AD16", .name = "Linux /usr (x86-64)" },
    .{ .guid = "7FFEC5C9-2D00-49B7-8941-3EA10A5586B7", .name = "Linux dm-crypt" },
    .{ .guid = "CA7D7CCB-63ED-4C53-861C-1742536059CC", .name = "Linux LUKS" },
    .{ .guid = "516E7CB4-6ECF-11D6-8FF8-00022D09712B", .name = "FreeBSD data" },
    .{ .guid = "83BD6B9D-7F41-11DC-BE0B-001560B84F0F", .name = "FreeBSD boot" },
    .{ .guid = "516E7CB5-6ECF-11D6-8FF8-00022D09712B", .name = "FreeBSD swap" },
    .{ .guid = "516E7CB6-6ECF-11D6-8FF8-00022D09712B", .name = "FreeBSD UFS" },
    .{ .guid = "516E7CBA-6ECF-11D6-8FF8-00022D09712B", .name = "FreeBSD ZFS" },
    .{ .guid = "48465300-0000-11AA-AA11-00306543ECAC", .name = "Apple HFS/HFS+" },
    .{ .guid = "55465300-0000-11AA-AA11-00306543ECAC", .name = "Apple UFS" },
    .{ .guid = "52414944-0000-11AA-AA11-00306543ECAC", .name = "Apple RAID" },
    .{ .guid = "52414944-5F4F-11AA-AA11-00306543ECAC", .name = "Apple RAID offline" },
    .{ .guid = "426F6F74-0000-11AA-AA11-00306543ECAC", .name = "Apple boot" },
    .{ .guid = "4C616265-6C00-11AA-AA11-00306543ECAC", .name = "Apple label" },
    .{ .guid = "5265636F-7665-11AA-AA11-00306543ECAC", .name = "Apple TV recovery" },
    .{ .guid = "53746F72-6167-11AA-AA11-00306543ECAC", .name = "Apple Core storage" },
    .{ .guid = "7C3457EF-0000-11AA-AA11-00306543ECAC", .name = "Apple APFS" },
    .{ .guid = "6A82CB45-1DD2-11B2-99A6-080020736631", .name = "Solaris boot" },
    .{ .guid = "6A85CF4D-1DD2-11B2-99A6-080020736631", .name = "Solaris root" },
    .{ .guid = "6A898CC3-1DD2-11B2-99A6-080020736631", .name = "Solaris /usr & Apple ZFS" },
    .{ .guid = "49F48D32-B10E-11DC-B99B-0019D1879648", .name = "NetBSD swap" },
    .{ .guid = "49F48D5A-B10E-11DC-B99B-0019D1879648", .name = "NetBSD FFS" },
    .{ .guid = "2DB519C4-B10F-11DC-B99B-0019D1879648", .name = "NetBSD concatenated" },
    .{ .guid = "FE3A2A5D-4F32-41A7-B725-ACCC3285A309", .name = "ChromeOS kernel" },
    .{ .guid = "3CB8E202-3B7E-47DD-8A3C-7FF2A13CFCEC", .name = "ChromeOS root fs" },
    .{ .guid = "2E0A753D-9E48-43B0-8337-B15192CB1B5E", .name = "ChromeOS reserved" },
    .{ .guid = "CAB6E88E-ABF3-4102-A07A-D4BB9BE3C1D3", .name = "ChromeOS firmware" },
    .{ .guid = "09845860-705F-4BB5-B16C-8A8A099CAF52", .name = "ChromeOS miniOS" },
    .{ .guid = "5DFBF5F4-2848-4BAC-AA5E-0D9A20B745A6", .name = "CoreOS /usr" },
    .{ .guid = "C95DC21A-DF0E-4340-8D7B-26CBFA9A03E0", .name = "CoreOS resizable rootfs" },
    .{ .guid = "BE9067B9-EA49-4F15-B4F6-F36F8C9E1818", .name = "CoreOS root on RAID" },
    .{ .guid = "9E1A2D38-C612-4316-AA26-8B49521E5A8B", .name = "PowerPC PReP boot" },
    .{ .guid = "AA31E02A-400F-11DB-9590-000C2911D1B8", .name = "VMware VMFS" },
    .{ .guid = "9D275380-40AD-11DB-BF97-000C2911D1B8", .name = "VMware vmkcore (coredump)" },
    .{ .guid = "9198EFFC-31C0-11DB-8F78-000C2911D1B8", .name = "VMware reserved" },
    .{ .guid = "21686148-6449-6E6F-744E-656564454649", .name = "BIOS boot" },
};

fn mbrTypeName(id: u8) []const u8 {
    for (mbr_types) |t| if (t.id == id) return t.name;
    return "unknown";
}

fn gptTypeName(guid: []const u8) []const u8 {
    for (gpt_types) |t| if (std.ascii.eqlIgnoreCase(t.guid, guid)) return t.name;
    return "unknown";
}

fn guidStr(a: std.mem.Allocator, b: []const u8) []const u8 {
    const d1 = std.mem.readInt(u32, b[0..4], .little);
    const d2 = std.mem.readInt(u16, b[4..6], .little);
    const d3 = std.mem.readInt(u16, b[6..8], .little);
    return std.fmt.allocPrint(a, "{X:0>8}-{X:0>4}-{X:0>4}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ d1, d2, d3, b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15] }) catch "";
}

fn humanBytes(a: std.mem.Allocator, bytes: u64, decimals: u32, space: bool, long_suffix: bool) []const u8 {
    const units_s = [_][]const u8{ "B", "K", "M", "G", "T", "P", "E" };
    const units_l = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" };
    var idx: usize = 0;
    var div: f64 = 1;
    const fb: f64 = @floatFromInt(bytes);
    while (idx + 1 < units_s.len and fb / div >= 1024) {
        div *= 1024;
        idx += 1;
    }
    const sp: []const u8 = if (space) " " else "";
    const unit = if (long_suffix) units_l[idx] else units_s[idx];
    if (idx == 0) return std.fmt.allocPrint(a, "{d}{s}{s}", .{ bytes, sp, unit }) catch "";
    var txt: []const u8 = undefined;
    const v = fb / div;
    if (decimals == 2) txt = std.fmt.allocPrint(a, "{d:.2}", .{v}) catch "" else txt = std.fmt.allocPrint(a, "{d:.1}", .{v}) catch "";
    // strip trailing zeros
    if (std.mem.indexOfScalar(u8, txt, '.') != null) {
        var e = txt.len;
        while (e > 0 and txt[e - 1] == '0') e -= 1;
        if (e > 0 and txt[e - 1] == '.') e -= 1;
        txt = txt[0..e];
    }
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ txt, sp, unit }) catch "";
}

fn readSysNum(a: std.mem.Allocator, path: []const u8) ?u64 {
    const d = mnt.readFile(path) orelse return null;
    _ = a;
    return std.fmt.parseInt(u64, std.mem.trim(u8, d, " \n"), 10) catch null;
}

const Row = struct { dev: []const u8, boot: bool, start: u64, end: u64, sectors: u64, size: []const u8, id: u8, type_name: []const u8 };

fn partDevName(a: std.mem.Allocator, disk: []const u8, n: usize) []const u8 {
    const last = disk[disk.len - 1];
    if (std.ascii.isDigit(last)) return std.fmt.allocPrint(a, "{s}p{d}", .{ disk, n }) catch "";
    return std.fmt.allocPrint(a, "{s}{d}", .{ disk, n }) catch "";
}

fn readAt(fd: i32, off: u64, buf: []u8) bool {
    const r = linux.pread(fd, buf.ptr, buf.len, @intCast(off));
    return u.ok(r) and r == buf.len;
}

var disks_shown: usize = 0;

fn listDisk(a: std.mem.Allocator, path: []const u8, explicit: bool) bool {
    const fd_rc = linux.open(u.zstr(path), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(fd_rc)) {
        if (explicit) u.errf("fdisk: cannot open {s}: {s}\n", .{ path, if (u.errno(fd_rc) == .NOMEDIUM) "No medium found" else u.strerr(u.errno(fd_rc)) });
        return false;
    }
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var size: u64 = 0;
    if (!u.ok(linux.ioctl(fd, 0x80081272, @intFromPtr(&size)))) {
        if (u.statFd(fd)) |st| size = st.size;
    }
    var lss: c_int = 512;
    _ = linux.ioctl(fd, 0x1268, @intFromPtr(&lss));
    var pss: c_uint = @intCast(lss);
    _ = linux.ioctl(fd, 0x127b, @intFromPtr(&pss));
    var iomin: c_uint = pss;
    _ = linux.ioctl(fd, 0x1278, @intFromPtr(&iomin));
    var ioopt: c_uint = 0;
    _ = linux.ioctl(fd, 0x1279, @intFromPtr(&ioopt));
    if (ioopt == 0) ioopt = iomin;
    const ls: u64 = @intCast(lss);
    const sectors = size / ls;
    const name = std.fs.path.basename(path);
    if (disks_shown > 0) u.out("\n\n");
    disks_shown += 1;
    u.outf("Disk {s}: {s}, {d} bytes, {d} sectors\n", .{ path, humanBytes(a, size, 2, true, true), size, sectors });
    const model_path = std.fmt.allocPrint(a, "/sys/block/{s}/device/model", .{name}) catch "";
    if (mnt.readFile(model_path)) |m| {
        const mm = std.mem.trimEnd(u8, m, "\n");
        if (mm.len > 0) u.outf("Disk model: {s}\n", .{mm});
    }
    u.outf("Units: sectors of 1 * {d} = {d} bytes\n", .{ ls, ls });
    u.outf("Sector size (logical/physical): {d} bytes / {d} bytes\n", .{ ls, pss });
    u.outf("I/O size (minimum/optimal): {d} bytes / {d} bytes\n", .{ iomin, ioopt });
    var sec0: [512]u8 = undefined;
    if (!readAt(fd, 0, &sec0)) {
        return true;
    }
    const has_dos = sec0[510] == 0x55 and sec0[511] == 0xaa;
    var gpt_hdr: [512]u8 = undefined;
    const have_hdr = readAt(fd, ls, &gpt_hdr);
    const is_gpt = have_hdr and std.mem.eql(u8, gpt_hdr[0..8], "EFI PART");
    var rows = u.Vec(Row).init(a);
    if (is_gpt) {
        u.out("Disklabel type: gpt\n");
        u.outf("Disk identifier: {s}\n", .{guidStr(a, gpt_hdr[56..72])});
        const table_lba = std.mem.readInt(u64, gpt_hdr[72..80], .little);
        const n = std.mem.readInt(u32, gpt_hdr[80..84], .little);
        const esz = std.mem.readInt(u32, gpt_hdr[84..88], .little);
        if (esz >= 128 and n <= 1024) {
            const tbl = a.alloc(u8, @as(usize, n) * esz) catch return true;
            if (readAt(fd, table_lba * ls, tbl)) {
                var i: usize = 0;
                var shown: usize = 0;
                while (i < n) : (i += 1) {
                    const e = tbl[i * esz ..][0..esz];
                    var zero = true;
                    for (e[0..16]) |b| if (b != 0) {
                        zero = false;
                    };
                    if (zero) continue;
                    shown += 1;
                    const first = std.mem.readInt(u64, e[32..40], .little);
                    const last = std.mem.readInt(u64, e[40..48], .little);
                    rows.push(.{ .dev = partDevName(a, path, i + 1), .boot = false, .start = first, .end = last, .sectors = last - first + 1, .size = humanBytes(a, (last - first + 1) * ls, 1, false, false), .id = 0, .type_name = gptTypeName(guidStr(a, e[0..16])) });
                }
            }
        }
    } else if (has_dos) {
        u.out("Disklabel type: dos\n");
        u.outf("Disk identifier: 0x{x:0>8}\n", .{std.mem.readInt(u32, sec0[440..444], .little)});
        var ext_start: u64 = 0;
        var k: usize = 0;
        while (k < 4) : (k += 1) {
            const e = sec0[446 + 16 * k ..][0..16];
            const typ = e[4];
            const start = std.mem.readInt(u32, e[8..12], .little);
            const cnt = std.mem.readInt(u32, e[12..16], .little);
            if (typ == 0 and cnt == 0) continue;
            rows.push(.{ .dev = partDevName(a, path, k + 1), .boot = e[0] == 0x80, .start = start, .end = @as(u64, start) + cnt - 1, .sectors = cnt, .size = humanBytes(a, @as(u64, cnt) * ls, 1, false, false), .id = typ, .type_name = mbrTypeName(typ) });
            if ((typ == 5 or typ == 0xf or typ == 0x85) and ext_start == 0) ext_start = start;
        }
        if (ext_start != 0) {
            var ebr = ext_start;
            var part_no: usize = 5;
            var guard: usize = 0;
            while (guard < 128) : (guard += 1) {
                var eb: [512]u8 = undefined;
                if (!readAt(fd, ebr * ls, &eb) or eb[510] != 0x55 or eb[511] != 0xaa) break;
                const e0 = eb[446..462];
                const typ = e0[4];
                const rel = std.mem.readInt(u32, e0[8..12], .little);
                const cnt = std.mem.readInt(u32, e0[12..16], .little);
                if (typ != 0 and cnt != 0) {
                    const start = ebr + rel;
                    rows.push(.{ .dev = partDevName(a, path, part_no), .boot = e0[0] == 0x80, .start = start, .end = start + cnt - 1, .sectors = cnt, .size = humanBytes(a, @as(u64, cnt) * ls, 1, false, false), .id = typ, .type_name = mbrTypeName(typ) });
                    part_no += 1;
                }
                const e1 = eb[462..478];
                const nrel = std.mem.readInt(u32, e1[8..12], .little);
                if (e1[4] == 0 or nrel == 0) break;
                ebr = ext_start + nrel;
            }
        }
    } else {
        return true;
    }
    if (rows.items.len == 0) {
        return true;
    }
    u.out("\n");
    // column widths
    var wdev: usize = 6;
    var wstart: usize = 5;
    var wend: usize = 3;
    var wsec: usize = 7;
    var wsize: usize = 4;
    for (rows.items) |r| {
        wdev = @max(wdev, r.dev.len);
        wstart = @max(wstart, numLen(r.start));
        wend = @max(wend, numLen(r.end));
        wsec = @max(wsec, numLen(r.sectors));
        wsize = @max(wsize, r.size.len);
    }
    var o = u.Vec(u8).init(a);
    wdev = @max(wdev, 10);
    if (is_gpt) {
        o.pushSlice(padR(a, "Device", wdev));
        o.push(' ');
        o.pushSlice(padL(a, "Start", wstart));
        o.push(' ');
        o.pushSlice(padL(a, "End", wend));
        o.push(' ');
        o.pushSlice(padL(a, "Sectors", wsec));
        o.push(' ');
        o.pushSlice(padL(a, "Size", wsize));
        o.pushSlice(" Type\n");
        for (rows.items) |r| {
            o.pushSlice(padR(a, r.dev, wdev));
            o.push(' ');
            o.pushSlice(padL(a, num(a, r.start), wstart));
            o.push(' ');
            o.pushSlice(padL(a, num(a, r.end), wend));
            o.push(' ');
            o.pushSlice(padL(a, num(a, r.sectors), wsec));
            o.push(' ');
            o.pushSlice(padL(a, r.size, wsize));
            o.push(' ');
            o.pushSlice(r.type_name);
            o.push('\n');
        }
    } else {
        o.pushSlice(padR(a, "Device", wdev));
        o.pushSlice(" Boot ");
        o.pushSlice(padL(a, "Start", wstart));
        o.push(' ');
        o.pushSlice(padL(a, "End", wend));
        o.push(' ');
        o.pushSlice(padL(a, "Sectors", wsec));
        o.push(' ');
        o.pushSlice(padL(a, "Size", wsize));
        o.pushSlice(" Id Type\n");
        for (rows.items) |r| {
            o.pushSlice(padR(a, r.dev, wdev));
            o.push(' ');
            o.pushSlice(padR(a, if (r.boot) "*" else "", 4));
            o.push(' ');
            o.pushSlice(padL(a, num(a, r.start), wstart));
            o.push(' ');
            o.pushSlice(padL(a, num(a, r.end), wend));
            o.push(' ');
            o.pushSlice(padL(a, num(a, r.sectors), wsec));
            o.push(' ');
            o.pushSlice(padL(a, r.size, wsize));
            o.push(' ');
            o.pushSlice(padL(a, std.fmt.allocPrint(a, "{x}", .{r.id}) catch "", 2));
            o.push(' ');
            o.pushSlice(r.type_name);
            o.push('\n');
        }
    }
    // warnings printed after the table
    var in_order = true;
    var prev_end: u64 = 0;
    for (rows.items, 0..) |r, ix| {
        if (ix > 0 and r.start < prev_end) in_order = false;
        prev_end = r.end + 1;
    }
    if (!in_order) o.pushSlice("\nPartition table entries are not in disk order.\n");
    if (pss > ls) {
        for (rows.items, 0..) |r, ix| {
            if (r.start * ls % pss != 0) o.pushSlice(std.fmt.allocPrint(a, "\nPartition {d} does not start on physical sector boundary.\n", .{ix + 1}) catch "");
        }
    }
    u.out(o.items);
    return true;
}

fn num(a: std.mem.Allocator, n: u64) []const u8 {
    return std.fmt.allocPrint(a, "{d}", .{n}) catch "";
}

fn padL(a: std.mem.Allocator, s: []const u8, w: usize) []const u8 {
    if (s.len >= w) return s;
    const b = a.alloc(u8, w) catch return s;
    @memset(b[0 .. w - s.len], ' ');
    @memcpy(b[w - s.len ..], s);
    return b;
}

fn padR(a: std.mem.Allocator, s: []const u8, w: usize) []const u8 {
    if (s.len >= w) return s;
    const b = a.alloc(u8, w) catch return s;
    @memcpy(b[0..s.len], s);
    @memset(b[s.len..], ' ');
    return b;
}

fn numLen(n: u64) usize {
    var l: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) l += 1;
    return l;
}

pub fn fdisk(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "list", .key = 'l' }, .{ .name = "version", .key = 'V' }, .{ .name = "help", .key = 'h' },
        .{ .name = "getsz", .key = 's' }, .{ .name = "list-details", .key = 'x' }, .{ .name = "sector-size", .key = 'b', .arg = .req },
        .{ .name = "units", .key = 'u', .arg = .opt }, .{ .name = "color", .key = 202, .arg = .opt }, .{ .name = "type", .key = 't', .arg = .req },
        .{ .name = "compatibility", .key = 'c', .arg = .opt }, .{ .name = "output", .key = 'o', .arg = .req }, .{ .name = "wipe", .key = 'w', .arg = .req },
        .{ .name = "wipe-partitions", .key = 'W', .arg = .req }, .{ .name = "noauto-pt", .key = 'n' }, .{ .name = "lock", .key = 203, .arg = .opt },
    };
    var p = g.Parser.init("fdisk", args, &opts);
    var list = false;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'V' => {
                u.out("fdisk from util-linux 2.41.5\n");
                return 0;
            },
            'h' => {
                u.out("\nUsage:\n fdisk [options] <disk>         change partition table\n fdisk [options] -l [<disk>...] list partition table(s)\n\nDisplay or manipulate a disk partition table.\n\nOptions:\n -b, --sector-size <size>      physical and logical sector size\n -B, --protect-boot            don't erase bootbits when creating a new label\n -c, --compatibility[=<mode>]  mode is 'dos' or 'nondos' (default)\n -L, --color[=<when>]          colorize output (auto, always or never)\n                                 colors are enabled by default\n -l, --list                    display partitions and exit\n -x, --list-details            like --list but with more details\n -n, --noauto-pt               don't create default partition table on empty devices\n -o, --output <list>           output columns\n -t, --type <type>             recognize specified partition table type only\n -u, --units[=<unit>]          display units: 'cylinders' or 'sectors' (default)\n -s, --getsz                   display device size in 512-byte sectors [DEPRECATED]\n     --bytes                   print SIZE in bytes rather than in human readable format\n     --lock[=<mode>]           use exclusive device lock (yes, no or nonblock)\n -w, --wipe <mode>             wipe signatures (auto, always or never)\n -W, --wipe-partitions <mode>  wipe signatures from new partitions (auto, always or never)\n\n -C, --cylinders <number>      specify the number of cylinders\n -H, --heads <number>          specify the number of heads\n -S, --sectors <number>        specify the number of sectors per track\n\n -h, --help                    display this help\n -V, --version                 display version\n\nAvailable output columns:\n gpt: Device Start End Sectors Size Type Type-UUID Attrs Name UUID\n dos: Device Start End Sectors Cylinders Size Type Id Attrs Boot End-C/H/S\n      Start-C/H/S\n bsd: Slice Start End Sectors Cylinders Size Type Bsize Cpg Fsize\n sgi: Device Start End Sectors Cylinders Size Type Id Attrs\n sun: Device Start End Sectors Cylinders Size Type Id Flags\n\nFor more details see fdisk(8).\n");
                return 0;
            },
            'l' => list = true,
            else => {},
        }
    }
    var arena = std.heap.ArenaAllocator.init(u.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    if (!list) {
        if (p.operands.items.len == 0) {
            u.err("Usage:\n fdisk [options] <disk>      change partition table\n fdisk [options] -l [<disk>]  list partition table(s)\n\nFor more details see fdisk(8).\n");
            return 1;
        }
        u.err("fdisk: interactive partition editing is not supported by cmdbox; use -l to list\n");
        return 1;
    }
    if (p.operands.items.len > 0) {
        var rc: u8 = 0;
        for (p.operands.items) |d| if (!listDisk(a, d, true)) {
            rc = 1;
        };
        return rc;
    }
    const pt = mnt.readFile("/proc/partitions") orelse return 1;
    var lines = std.mem.splitScalar(u8, pt, '\n');
    _ = lines.next();
    _ = lines.next();
    while (lines.next()) |l| {
        var it = std.mem.tokenizeAny(u8, l, " \t");
        _ = it.next() orelse continue;
        _ = it.next() orelse continue;
        const blocks = it.next() orelse continue;
        const nm = it.next() orelse continue;
        if (blocks.len == 0 or std.mem.eql(u8, blocks, "0")) continue;
        const sp = std.fmt.allocPrint(a, "/sys/block/{s}", .{nm}) catch continue;
        if (u.stat(sp, true) == null) continue; // a partition, not a disk
        _ = listDisk(a, std.fmt.allocPrint(a, "/dev/{s}", .{nm}) catch continue, false);
    }
    return 0;
}
