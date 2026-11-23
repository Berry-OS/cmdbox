// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// chvt fgconsole fstrim eject findfs fsck - console-tools / util-linux compatible
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const mnt = @import("mount.zig");

const HELP: u8 = 200;
const VERSION: u8 = 201;

const hv = [_]g.Opt{
    .{ .name = "help", .key = 'h' },
    .{ .name = "version", .key = 'V' },
};

const CHVT_USAGE = "Usage: chvt [option...] N\n\nOptions:\n  -C, --console=DEV   the console device to be used.\n  -h, --help          print this usage message.\n  -V, --version       print version number.\n\nReport bugs to authors.\n\n";
const FGC_USAGE = "Usage: fgconsole [option...]\n\nOptions:\n  -C, --console=DEV      the console device to be used.\n  -n, --next-available   print number of next unallocated VT.\n  -V, --version          print version number.\n  -h, --help             print this usage message.\n\nReport bugs to authors.\n\n";

fn verLine(prog: []const u8) void {
    u.outf("{s} from util-linux 2.41.5\n", .{prog});
}

// ===================== chvt / fgconsole =====================
const VT_GETSTATE = 0x5603;
const VT_ACTIVATE = 0x5606;
const VT_WAITACTIVE = 0x5607;
const VT_OPENQRY = 0x5600;

fn openConsole(dev: ?[]const u8) ?i32 {
    if (dev) |d| {
        const rc = linux.open(u.zstr(d), .{ .ACCMODE = .RDWR }, 0);
        if (u.ok(rc)) return @intCast(rc);
        const rc2 = linux.open(u.zstr(d), .{ .ACCMODE = .RDONLY }, 0);
        if (u.ok(rc2)) return @intCast(rc2);
        return null;
    }
    const names = [_][]const u8{ "/dev/tty", "/dev/tty0", "/dev/vc/0", "/dev/console" };
    for (names) |nm| {
        const rc = linux.open(u.zstr(nm), .{ .ACCMODE = .RDWR }, 0);
        if (u.ok(rc)) return @intCast(rc);
    }
    for (names) |nm| {
        const rc = linux.open(u.zstr(nm), .{ .ACCMODE = .RDONLY }, 0);
        if (u.ok(rc)) return @intCast(rc);
    }
    for ([_]i32{ 0, 1, 2 }) |fd| {
        var st: [3]u16 = undefined;
        if (u.ok(linux.ioctl(fd, VT_GETSTATE, @intFromPtr(&st)))) return fd;
    }
    return null;
}

pub fn chvt(args: []const []const u8) u8 {
    const opts = [_]g.Opt{.{ .name = "console", .key = 'C', .arg = .req }} ++ hv;
    var p = g.Parser.init("chvt", args, &opts);
    var dev: ?[]const u8 = null;
    while (p.next() catch return 64) |it| {
        switch (it.key) {
            'h' => {
                u.out(CHVT_USAGE);
                return 0;
            },
            'V' => {
                u.out("chvt from kbd 2.9.0\n");
                return 0;
            },
            'C' => dev = it.val,
            else => {},
        }
    }
    const ops = p.operands.items;
    if (ops.len == 0) {
        u.err("chvt: Not enough arguments.\n");
        u.err(CHVT_USAGE);
        return 64;
    }
    var n: usize = 0;
    for (ops[0]) |ch| {
        if (!std.ascii.isDigit(ch)) break;
        n = n * 10 + (ch - '0');
    }
    const fd = openConsole(dev) orelse {
        u.err("chvt: Couldn't get a file descriptor referring to the console.\n");
        return 1;
    };
    const rc = linux.ioctl(fd, VT_ACTIVATE, n);
    if (!u.ok(rc)) {
        u.errf("chvt: Couldn't activate vt {d}: {s}\n", .{ n, u.strerr(u.errno(rc)) });
        return 1;
    }
    const rc2 = linux.ioctl(fd, VT_WAITACTIVE, n);
    if (!u.ok(rc2)) {
        u.errf("chvt: Couldn't wait for vt {d}: {s}\n", .{ n, u.strerr(u.errno(rc2)) });
        return 1;
    }
    return 0;
}

pub fn fgconsole(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "console", .key = 'C', .arg = .req },
        .{ .name = "next-available", .key = 'n' },
    } ++ hv;
    var p = g.Parser.init("fgconsole", args, &opts);
    var dev: ?[]const u8 = null;
    var next_avail = false;
    while (p.next() catch return 64) |it| {
        switch (it.key) {
            'h' => {
                u.out(FGC_USAGE);
                return 0;
            },
            'V' => {
                u.out("fgconsole from kbd 2.9.0\n");
                return 0;
            },
            'C' => dev = it.val,
            'n' => next_avail = true,
            else => {},
        }
    }
    const fd = openConsole(dev) orelse {
        u.err("fgconsole: Couldn't get a file descriptor referring to the console.\n");
        return 1;
    };
    if (next_avail) {
        var nr: i32 = 0;
        if (!u.ok(linux.ioctl(fd, VT_OPENQRY, @intFromPtr(&nr))) or nr <= 0) {
            u.err("fgconsole: Couldn't find an available VT\n");
            return 1;
        }
        u.outf("{d}\n", .{nr});
        return 0;
    }
    var st: [3]u16 = undefined; // v_active, v_signal, v_state
    const rc = linux.ioctl(fd, VT_GETSTATE, @intFromPtr(&st));
    if (!u.ok(rc)) {
        u.errf("fgconsole: VT_GETSTATE: {s}\n", .{u.strerr(u.errno(rc))});
        return 1;
    }
    u.outf("{d}\n", .{st[0]});
    return 0;
}

// ===================== fstrim =====================
fn parseSize(s: []const u8) ?u64 {
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == 0) return null;
    const base = std.fmt.parseInt(u64, s[0..i], 10) catch return null;
    const suf = s[i..];
    if (suf.len == 0) return base;
    const letters = "KMGTPEZY";
    const up = std.ascii.toUpper(suf[0]);
    const idx = std.mem.indexOfScalar(u8, letters, up) orelse return null;
    var mult: u64 = 1;
    const dec = suf.len == 2 and std.ascii.toUpper(suf[1]) == 'B' and suf[1] != 'b' and !(suf.len == 3);
    const rest = suf[1..];
    var k: usize = 0;
    var thousand = false;
    if (rest.len == 0) {} else if (rest.len == 2 and std.ascii.toLower(rest[0]) == 'i' and std.ascii.toLower(rest[1]) == 'b') {} else if (rest.len == 1 and std.ascii.toLower(rest[0]) == 'b') {
        thousand = true;
    } else return null;
    _ = dec;
    while (k <= idx) : (k += 1) mult = std.math.mul(u64, mult, if (thousand) 1000 else 1024) catch return null;
    return std.math.mul(u64, base, mult) catch null;
}

fn humanSize(a: std.mem.Allocator, bytes: u64) []const u8 {
    const suffix = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" };
    var idx: usize = 0;
    var v = bytes;
    var rem: u64 = 0;
    while (v >= 1024 and idx + 1 < suffix.len) {
        rem = v % 1024;
        v /= 1024;
        idx += 1;
    }
    if (idx == 0 or rem == 0) return std.fmt.allocPrint(a, "{d} {s}", .{ v, suffix[idx] }) catch "";
    const dec = rem * 10 / 1024;
    if (dec == 0) return std.fmt.allocPrint(a, "{d} {s}", .{ v, suffix[idx] }) catch "";
    return std.fmt.allocPrint(a, "{d}.{d} {s}", .{ v, dec, suffix[idx] }) catch "";
}

const FITRIM: u32 = 0xC0185879;
const FstrimRange = extern struct { start: u64, len: u64, minlen: u64 };

pub fn fstrim(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "all", .key = 'a' },
        .{ .name = "fstab", .key = 'A' },
        .{ .name = "listed-in", .key = 'I', .arg = .req },
        .{ .name = "offset", .key = 'o', .arg = .req },
        .{ .name = "length", .key = 'l', .arg = .req },
        .{ .name = "minimum", .key = 'm', .arg = .req },
        .{ .name = "types", .key = 't', .arg = .req },
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "quiet-unsupported", .key = 202 },
        .{ .name = "dry-run", .key = 'n' },
    } ++ hv;
    var p = g.Parser.init("fstrim", args, &opts);
    var all = false;
    var from_fstab = false;
    var verbose = false;
    var dry = false;
    var quiet_unsup = false;
    var types: ?[]const u8 = null;
    var range = FstrimRange{ .start = 0, .len = std.math.maxInt(u64), .minlen = 0 };
    var listed: u.Vec([]const u8) = u.Vec([]const u8).init(u.alloc);
    while (p.next() catch return 64) |it| {
        switch (it.key) {
            'h' => {
                u.out("\nUsage:\n fstrim [options] <-A|-a|mount point>\n\nDiscard unused blocks on a mounted filesystem.\n\nOptions:\n -a, --all                trim mounted filesystems\n -A, --fstab              trim filesystems from /etc/fstab\n -I, --listed-in <list>   trim filesystems listed in specified files\n -o, --offset <num>       the offset in bytes to start discarding from\n -l, --length <num>       the number of bytes to discard\n -m, --minimum <num>      the minimum extent length to discard\n -t, --types <list>       limit the set of filesystem types\n -v, --verbose            print number of discarded bytes\n     --quiet-unsupported  suppress error messages if trim unsupported\n -n, --dry-run            does everything, but trim\n\n -h, --help          display this help\n -V, --version       display version\n\nArguments:\n Values for <num> may be followed by a suffix: KiB, MiB,\n GiB, TiB, PiB, EiB, ZiB, or YiB (where the \"iB\" is optional).\n\nFor more details see fstrim(8).\n");
                return 0;
            },
            'V' => {
                verLine("fstrim");
                return 0;
            },
            'a' => all = true,
            'A' => from_fstab = true,
            'I' => listed.push(it.val.?),
            'o' => range.start = parseSize(it.val.?) orelse {
                u.errf("fstrim: failed to parse offset: '{s}': Invalid argument\n", .{it.val.?});
                return 1;
            },
            'l' => range.len = parseSize(it.val.?) orelse {
                u.errf("fstrim: failed to parse length: '{s}': Invalid argument\n", .{it.val.?});
                return 1;
            },
            'm' => range.minlen = parseSize(it.val.?) orelse {
                u.errf("fstrim: failed to parse minimum extent length: '{s}': Invalid argument\n", .{it.val.?});
                return 1;
            },
            't' => types = it.val,
            'v' => verbose = true,
            'n' => dry = true,
            202 => quiet_unsup = true,
            else => {},
        }
    }
    const ops = p.operands.items;
    if (!all and !from_fstab and listed.items.len == 0 and ops.len == 0) {
        u.err("fstrim: no mountpoint specified\n");
        return 1;
    }
    if (ops.len > 1) {
        u.err("fstrim: unexpected number of arguments\n");
        return 1;
    }
    var targets = u.Vec(struct { path: []const u8, dev: ?[]const u8 }).init(u.alloc);
    if (ops.len == 1) targets.push(.{ .path = ops[0], .dev = null });
    if (all or from_fstab or listed.items.len > 0) {
        var seen = u.Vec([]const u8).init(u.alloc);
        if (all) {
            const mis = mnt.readMountinfo();
            var mi_idx = mis.len;
            while (mi_idx > 0) {
                mi_idx -= 1;
                const m = mis[mi_idx];
                if (!std.mem.startsWith(u8, m.source, "/dev/")) continue;
                if (types) |t| if (!typeFilter(t, m.fstype)) continue;
                var dup = false;
                const key = std.fmt.allocPrint(u.alloc, "{d}:{d}", .{ m.maj, m.min }) catch "";
                for (seen.items) |sk| if (std.mem.eql(u8, sk, key)) {
                    dup = true;
                };
                if (dup) continue;
                if (std.mem.indexOf(u8, m.vfs, "ro") != null and std.mem.startsWith(u8, m.vfs, "ro")) continue;
                seen.push(key);
                var devname: []const u8 = m.source;
                if (std.mem.eql(u8, m.source, "/dev/root")) {
                    var lb: [256]u8 = undefined;
                    const lp = std.fmt.allocPrint(u.alloc, "/sys/dev/block/{d}:{d}", .{ m.maj, m.min }) catch "";
                    const rl = linux.readlink(u.zstr(lp), &lb, lb.len);
                    if (u.ok(rl)) devname = std.fmt.allocPrint(u.alloc, "/dev/{s}", .{u.basename(lb[0..rl])}) catch m.source;
                }
                targets.push(.{ .path = m.target, .dev = devname });
            }
        }
        if (from_fstab) {
            for (mnt.readFstab("/etc/fstab")) |f| {
                if (std.mem.eql(u8, f.fstype, "swap") or std.mem.eql(u8, f.target, "none")) continue;
                if (types) |t| if (!typeFilter(t, f.fstype)) continue;
                targets.push(.{ .path = f.target, .dev = f.source });
            }
        }
    }
    var failed: usize = 0;
    var ok_n: usize = 0;
    for (targets.items) |t| {
        if (u.stat(t.path, true) == null) {
            if (all or from_fstab) {
                failed += 1;
                continue;
            }
            u.errf("fstrim: stat of {s} failed: {s}\n", .{ t.path, u.strerr(.NOENT) });
            return 1;
        }
        const fd_rc = linux.open(u.zstr(t.path), .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
        if (!u.ok(fd_rc)) {
            if (all or from_fstab) {
                failed += 1;
                continue;
            }
            u.errf("fstrim: cannot open {s}: {s}\n", .{ t.path, u.strerr(u.errno(fd_rc)) });
            return 1;
        }
        const fd: i32 = @intCast(fd_rc);
        defer _ = linux.close(fd);
        var r = range;
        if (dry) {
            r.len = 0;
        } else {
            const rc = linux.ioctl(fd, FITRIM, @intFromPtr(&r));
            if (!u.ok(rc)) {
                const en = u.errno(rc);
                if (en == .OPNOTSUPP or en == .NOTTY) {
                    if (!quiet_unsup) u.errf("fstrim: {s}: the discard operation is not supported\n", .{t.path});
                    if (!(all or from_fstab)) failed += 1;
                    continue;
                }
                u.errf("fstrim: {s}: FITRIM ioctl failed: {s}\n", .{ t.path, u.strerr(en) });
                failed += 1;
                continue;
            }
        }
        ok_n += 1;
        if (dry) {
            if (t.dev != null and (all or from_fstab)) u.outf("{s}: 0 B (dry run) trimmed on {s}\n", .{ t.path, t.dev.? }) else u.outf("{s}: 0 B (dry run) trimmed\n", .{t.path});
        } else if (verbose) {
            const hs = humanSize(u.alloc, r.len);
            if (t.dev != null and (all or from_fstab)) u.outf("{s}: {s} ({d} bytes) trimmed on {s}\n", .{ t.path, hs, r.len, t.dev.? }) else u.outf("{s}: {s} ({d} bytes) trimmed\n", .{ t.path, hs, r.len });
        }
    }
    if (failed == 0) return 0;
    if (ok_n > 0) return 32;
    return 1;
}

fn typeFilter(list: []const u8, fstype: []const u8) bool {
    var neg = false;
    var l = list;
    if (std.mem.startsWith(u8, l, "no")) {
        neg = true;
        l = l[2..];
    }
    var it = std.mem.splitScalar(u8, l, ',');
    var hit = false;
    while (it.next()) |t| {
        if (std.mem.eql(u8, t, fstype)) hit = true;
    }
    return if (neg) !hit else hit;
}

// ===================== eject =====================
const CDROMEJECT = 0x5309;
const CDROMCLOSETRAY = 0x5319;
const CDROM_LOCKDOOR = 0x5329;
const CDROM_DRIVE_STATUS = 0x5326;
const CDROM_SELECT_SPEED = 0x5322;
const CDROM_SELECT_DISC = 0x5323;
const CDROM_SET_OPTIONS = 0x5320;
const CDROM_CLEAR_OPTIONS = 0x5321;
const FDEJECT = 0x025A;

fn onOff(s: []const u8) ?bool {
    if (std.mem.eql(u8, s, "on") or std.mem.eql(u8, s, "1")) return true;
    if (std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "0")) return false;
    return null;
}

fn ejectDevice(name: []const u8) ?[]const u8 {
    // device name, /dev/ name, mount point or default
    var cand = u.Vec([]const u8).init(u.alloc);
    cand.push(name);
    if (!std.mem.startsWith(u8, name, "/")) {
        cand.push(std.fmt.allocPrint(u.alloc, "/dev/{s}", .{name}) catch name);
        cand.push(std.fmt.allocPrint(u.alloc, "/media/{s}", .{name}) catch name);
        cand.push(std.fmt.allocPrint(u.alloc, "/mnt/{s}", .{name}) catch name);
    }
    for (cand.items) |c0| {
        const rp = mnt.realpath(c0) orelse continue;
        for (mnt.readMountinfo()) |m| {
            if (std.mem.eql(u8, m.target, rp) and std.mem.startsWith(u8, m.source, "/dev/")) return mnt.realpath(m.source) orelse m.source;
        }
        if (u.stat(rp, true)) |st| {
            if (st.mode & linux.S.IFMT == linux.S.IFBLK) return rp;
        }
    }
    return null;
}

pub fn eject(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "auto", .key = 'a', .arg = .req },
        .{ .name = "changerslot", .key = 'c', .arg = .req },
        .{ .name = "default", .key = 'd' },
        .{ .name = "floppy", .key = 'f' },
        .{ .name = "force", .key = 'F' },
        .{ .name = "manualeject", .key = 'i', .arg = .req },
        .{ .name = "no-unmount", .key = 'm' },
        .{ .name = "no-partitions-unmount", .key = 'M' },
        .{ .name = "noop", .key = 'n' },
        .{ .name = "proc", .key = 'p' },
        .{ .name = "tape", .key = 'q' },
        .{ .name = "cdrom", .key = 'r' },
        .{ .name = "scsi", .key = 's' },
        .{ .name = "trayclose", .key = 't' },
        .{ .name = "traytoggle", .key = 'T' },
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "cdspeed", .key = 'x', .arg = .req },
        .{ .name = "listspeed", .key = 'X' },
    } ++ hv;
    var p = g.Parser.init("eject", args, &opts);
    var verbose = false;
    var noop = false;
    var no_unmount = false;
    var default_dev = false;
    var close_tray = false;
    var toggle = false;
    var auto: ?bool = null;
    var lockdoor: ?bool = null;
    var speed: ?usize = null;
    var slot: ?usize = null;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'h' => {
                u.out("\nUsage:\n eject [options] [<device>|<mountpoint>]\n\nEject removable media.\n\nOptions:\n -a, --auto <on|off>         turn auto-eject feature on or off\n -c, --changerslot <slot>    switch discs on a CD-ROM changer\n -d, --default               display default device\n -f, --floppy                eject floppy\n -F, --force                 don't care about device type\n -i, --manualeject <on|off>  toggle manual eject protection on/off\n -m, --no-unmount            do not unmount device even if it is mounted\n -M, --no-partitions-unmount do not unmount another partitions\n -n, --noop                  don't eject, just show device found\n -p, --proc                  use /proc/mounts instead of /etc/mtab\n -q, --tape                  eject tape\n -r, --cdrom                 eject CD-ROM\n -s, --scsi                  eject SCSI device\n -t, --trayclose             close tray\n -T, --traytoggle            toggle tray\n -v, --verbose               enable verbose output\n -x, --cdspeed <speed>       set CD-ROM max speed\n -X, --listspeed             list CD-ROM available speeds\n\n -h, --help                  display this help\n -V, --version               display version\n\nBy default tries -r, -s, -f, and -q in order until success.\n\nFor more details see eject(1).\n");
                return 0;
            },
            'V' => {
                verLine("eject");
                return 0;
            },
            'v' => verbose = true,
            'n' => noop = true,
            'm', 'M' => no_unmount = true,
            'd' => default_dev = true,
            't' => close_tray = true,
            'T' => toggle = true,
            'a' => auto = onOff(it.val.?) orelse {
                u.err("eject: invalid argument to --auto/-a option\n");
                return 1;
            },
            'i' => lockdoor = onOff(it.val.?) orelse {
                u.err("eject: invalid argument to --manualeject/-i option\n");
                return 1;
            },
            'x' => speed = std.fmt.parseInt(usize, it.val.?, 10) catch {
                u.err("eject: invalid argument to --cdspeed/-x option\n");
                return 1;
            },
            'c' => slot = std.fmt.parseInt(usize, it.val.?, 10) catch {
                u.err("eject: invalid argument to --changerslot/-c option\n");
                return 1;
            },
            else => {},
        }
    }
    if (default_dev) {
        u.out("eject: default device: `/dev/cdrom'\n");
        return 0;
    }
    const name: []const u8 = if (p.operands.items.len > 0) p.operands.items[0] else "/dev/cdrom";
    const dev = ejectDevice(name) orelse {
        u.errf("eject: {s}: not found mountpoint or device with the given name\n", .{name});
        return 1;
    };
    if (verbose or noop) u.outf("eject: device is `{s}'\n", .{dev});
    if (noop) return 0;
    if (!no_unmount) {
        for (mnt.readMountinfo()) |m| {
            if (std.mem.eql(u8, mnt.realpath(m.source) orelse m.source, dev)) {
                if (verbose) u.outf("eject: unmounting `{s}'\n", .{m.target});
                _ = linux.umount2(u.zstr(m.target), 0);
            }
        }
    }
    const fd_rc = linux.open(u.zstr(dev), .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
    if (!u.ok(fd_rc)) {
        u.errf("eject: unable to open `{s}'\n", .{dev});
        return 1;
    }
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    if (auto) |a| {
        const rc = linux.ioctl(fd, if (a) CDROM_SET_OPTIONS else CDROM_CLEAR_OPTIONS, 2);
        if (!u.ok(rc)) {
            u.err("eject: CD-ROM auto-eject command failed: Inappropriate ioctl for device\n");
            return 1;
        }
        return 0;
    }
    if (lockdoor) |l| {
        if (!u.ok(linux.ioctl(fd, CDROM_LOCKDOOR, @intFromBool(!l)))) {
            u.err("eject: CD-ROM door lock command failed\n");
            return 1;
        }
        return 0;
    }
    if (speed) |sp| {
        if (!u.ok(linux.ioctl(fd, CDROM_SELECT_SPEED, sp))) {
            u.err("eject: CD-ROM select speed command failed: Inappropriate ioctl for device\n");
            return 1;
        }
        return 0;
    }
    if (slot) |sl| {
        if (!u.ok(linux.ioctl(fd, CDROM_SELECT_DISC, sl))) {
            u.err("eject: CD-ROM select disc command failed: Inappropriate ioctl for device\n");
            return 1;
        }
        return 0;
    }
    if (toggle) {
        const stt = linux.ioctl(fd, CDROM_DRIVE_STATUS, 0);
        close_tray = u.ok(stt) and stt == 2;
    }
    if (close_tray) {
        if (!u.ok(linux.ioctl(fd, CDROMCLOSETRAY, 0))) {
            u.err("eject: CD-ROM tray close command failed: Inappropriate ioctl for device\n");
            return 1;
        }
        return 0;
    }
    if (u.ok(linux.ioctl(fd, CDROMEJECT, 0))) return 0;
    if (u.ok(linux.ioctl(fd, FDEJECT, 0))) return 0;
    u.errf("eject: unable to eject, last error: {s}\n", .{u.strerr(u.errno(linux.ioctl(fd, CDROMEJECT, 0)))});
    return 1;
}

// ===================== findfs =====================
const Probe = struct { label: ?[]const u8 = null, uuid: ?[]const u8 = null };

fn trimNul(s: []const u8) []const u8 {
    var e = s.len;
    while (e > 0 and (s[e - 1] == 0 or s[e - 1] == ' ')) e -= 1;
    return s[0..e];
}

fn fmtUuid(a: std.mem.Allocator, b: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15] }) catch "";
}

fn probeDev(dev: []const u8) ?Probe {
    const fstype = mnt.detectFs(dev) orelse return null;
    const fd_rc = linux.open(u.zstr(dev), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(fd_rc)) return null;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var buf: [0x11000]u8 = undefined;
    var got: usize = 0;
    while (got < buf.len) {
        const r = linux.pread(fd, buf[got..].ptr, buf.len - got, @intCast(got));
        if (!u.ok(r) or r == 0) break;
        got += r;
    }
    const b = buf[0..got];
    var pr = Probe{};
    if (std.mem.startsWith(u8, fstype, "ext") and got >= 0x400 + 0x138) {
        pr.uuid = fmtUuid(u.alloc, b[0x400 + 104 ..][0..16]);
        const l = trimNul(b[0x400 + 120 ..][0..16]);
        if (l.len > 0) pr.label = u.alloc.dupe(u8, l) catch null;
    } else if (std.mem.eql(u8, fstype, "xfs") and got >= 120) {
        pr.uuid = fmtUuid(u.alloc, b[32..][0..16]);
        const l = trimNul(b[108..][0..12]);
        if (l.len > 0) pr.label = u.alloc.dupe(u8, l) catch null;
    } else if (std.mem.eql(u8, fstype, "btrfs") and got >= 0x10000 + 0x12b + 256) {
        pr.uuid = fmtUuid(u.alloc, b[0x10020..][0..16]);
        const l = trimNul(b[0x1012b..][0..256]);
        if (l.len > 0) pr.label = u.alloc.dupe(u8, l) catch null;
    } else if (std.mem.eql(u8, fstype, "swap") and got >= 1052 + 16) {
        pr.uuid = fmtUuid(u.alloc, b[1036..][0..16]);
        const l = trimNul(b[1052..][0..16]);
        if (l.len > 0) pr.label = u.alloc.dupe(u8, l) catch null;
    } else if (std.mem.eql(u8, fstype, "vfat") and got >= 90) {
        const fat32 = std.mem.eql(u8, b[0x52..][0..5], "FAT32");
        const serial = std.mem.readInt(u32, b[if (fat32) 67 else 39 ..][0..4], .little);
        pr.uuid = std.fmt.allocPrint(u.alloc, "{X:0>4}-{X:0>4}", .{ serial >> 16, serial & 0xffff }) catch null;
        const l = trimNul(b[if (fat32) 71 else 43 ..][0..11]);
        if (l.len > 0 and !std.mem.eql(u8, l, "NO NAME")) pr.label = u.alloc.dupe(u8, l) catch null;
    } else if (std.mem.eql(u8, fstype, "iso9660") and got >= 0x8028 + 32) {
        const l = trimNul(b[0x8028..][0..32]);
        if (l.len > 0) pr.label = u.alloc.dupe(u8, l) catch null;
    }
    return pr;
}

fn probeAll(key: []const u8, val: []const u8) ?[]const u8 {
    const pt = mnt.readFile("/proc/partitions") orelse return null;
    var lines = std.mem.splitScalar(u8, pt, '\n');
    _ = lines.next();
    while (lines.next()) |l| {
        var it = std.mem.tokenizeAny(u8, l, " \t");
        _ = it.next() orelse continue;
        _ = it.next() orelse continue;
        _ = it.next() orelse continue;
        const nm = it.next() orelse continue;
        const dev = std.fmt.allocPrint(u.alloc, "/dev/{s}", .{nm}) catch continue;
        const pr = probeDev(dev) orelse continue;
        if (std.mem.eql(u8, key, "LABEL")) {
            if (pr.label) |lb| if (std.mem.eql(u8, lb, val)) return dev;
        } else if (std.mem.eql(u8, key, "UUID")) {
            if (pr.uuid) |uu| if (std.ascii.eqlIgnoreCase(uu, val)) return dev;
        }
    }
    return null;
}

pub fn findfs(args: []const []const u8) u8 {
    var p = g.Parser.init("findfs", args, &hv);
    p.hint_prefix = false;
    while (p.next() catch return 2) |it| {
        switch (it.key) {
            'h' => {
                u.out("\nUsage:\n findfs [options] {LABEL,UUID,PARTUUID,PARTLABEL}=<value>\n\nFind a filesystem by label or UUID.\n\nOptions:\n -h, --help     display this help\n -V, --version  display version\n\nFor more details see findfs(8).\n");
                return 0;
            },
            'V' => {
                verLine("findfs");
                return 0;
            },
            else => {},
        }
    }
    const ops = p.operands.items;
    if (ops.len != 1) {
        u.err("findfs: bad usage\nTry 'findfs --help' for more information.\n");
        return 2;
    }
    const spec = ops[0];
    const eq = std.mem.indexOfScalar(u8, spec, '=') orelse {
        u.outf("{s}\n", .{spec});
        return 0;
    };
    const key = spec[0..eq];
    var val = spec[eq + 1 ..];
    if (val.len >= 2 and (val[0] == '"' or val[0] == '\'') and val[val.len - 1] == val[0]) val = val[1 .. val.len - 1];
    const known = [_][]const u8{ "LABEL", "UUID", "PARTUUID", "PARTLABEL" };
    var ok_key = false;
    for (known) |k| if (std.mem.eql(u8, k, key)) {
        ok_key = true;
    };
    if (!ok_key) {
        u.outf("{s}\n", .{spec});
        return 0;
    }
    var tag_src: []const u8 = undefined;
    tag_src = std.fmt.allocPrint(u.alloc, "{s}={s}", .{ key, val }) catch spec;
    if (mnt.resolveTag(tag_src)) |d| {
        u.outf("{s}\n", .{d});
        return 0;
    }
    if (probeAll(key, val)) |d| {
        u.outf("{s}\n", .{d});
        return 0;
    }
    u.errf("findfs: unable to resolve '{s}'\n", .{spec});
    return 1;
}

// ===================== fsck =====================
fn findFsck(fstype: []const u8) ?[]const u8 {
    const dirs = [_][]const u8{ "/sbin", "/sbin/fs.d", "/sbin/fs", "/etc/fs", "/etc" };
    var buf: [128]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "fsck.{s}", .{fstype}) catch return null;
    for (dirs) |d| {
        const pth = std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ d, name }) catch continue;
        if (u.ok(linux.access(u.zstr(pth), 1))) return std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ mnt.realpath(d) orelse d, name }) catch pth;
    }
    if (std.c.getenv("PATH")) |pe| {
        var it = std.mem.splitScalar(u8, std.mem.span(pe), ':');
        while (it.next()) |d| {
            const pth = std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ if (d.len == 0) "." else d, name }) catch continue;
            if (u.ok(linux.access(u.zstr(pth), 1))) return std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ mnt.realpath(d) orelse d, name }) catch pth;
        }
    }
    return null;
}

pub fn fsck(args: []const []const u8) u8 {
    var all = false;
    var root_skip = false;
    var noexec = false;
    var verbose = false;
    var no_title = false;
    var fstype_arg: ?[]const u8 = null;
    var passthru = u.Vec([]const u8).init(u.alloc);
    var progress: ?[]const u8 = null;
    var devs = u.Vec([]const u8).init(u.alloc);
    var i: usize = 0;
    var past_dd = false;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (past_dd) {
            passthru.push(a);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            past_dd = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            u.out("\nUsage:\n fsck [options] -- [fs-options] [<filesystem> ...]\n\nCheck and repair a Linux filesystem.\n\nOptions:\n -a         same as -p, do not use in new scripts\n -A         check all filesystems\n -C [<fd>]  display progress bars\n -l         lock the device to guarantee exclusive access\n -M         do not check mounted filesystems\n -N         do not execute, just show what would be done\n -P         check filesystems in parallel, including root\n -R         skip root filesystem; useful only with '-A'\n -r [<fd>]  report statistics for each device checked\n -s         serialize the checking operations\n -t <type>  specify filesystem types to be checked;\n            <type> is allowed to be a comma-separated list\n -T         do not show the title on startup\n -V         explain what is being done\n -?         display this help\n -V, --version  display version\n\nFor more details see fsck(8).\n");
            return 0;
        }
        if (std.mem.eql(u8, a, "--version")) {
            u.out("fsck from util-linux 2.41.5\n");
            return 0;
        }
        if (a.len > 1 and a[0] == '-' and a[1] != '-') {
            var k: usize = 1;
            while (k < a.len) : (k += 1) {
                switch (a[k]) {
                    'A' => all = true,
                    'R' => root_skip = true,
                    'N' => noexec = true,
                    'T' => no_title = true,
                    'V' => verbose = true,
                    'P', 's', 'M', 'l' => {},
                    // -C [<fd>] / -r [<fd>]: optional argument is attached (-C6); swallow it
                    // so it is not forwarded to fsck.<type> as bogus options (-6).
                    'C' => {
                        progress = a[k..];
                        k = a.len;
                    },
                    'r' => k = a.len,
                    't' => {
                        if (fstype_arg != null) {
                            u.err("fsck: option '-t' may be specified only once\n");
                            return 16;
                        }
                        if (k + 1 < a.len) {
                            fstype_arg = a[k + 1 ..];
                        } else if (i + 1 < args.len) {
                            i += 1;
                            fstype_arg = args[i];
                        }
                        k = a.len;
                    },
                    else => {
                        // everything else is passed to the checker (-a -p -n -y -f -v ...)
                        passthru.push(std.fmt.allocPrint(u.alloc, "-{c}", .{a[k]}) catch a);
                    },
                }
            }
            continue;
        }
        if (std.mem.startsWith(u8, a, "--")) {
            passthru.push(a);
            continue;
        }
        devs.push(a);
    }
    if (!no_title) verLine("fsck");
    const fstab = mnt.readFstab("/etc/fstab");
    var targets = u.Vec(struct { dev: []const u8, fstype: []const u8 }).init(u.alloc);
    var single_type: ?[]const u8 = null;
    if (fstype_arg) |ft| {
        if (std.mem.indexOfScalar(u8, ft, ',') == null and !std.mem.startsWith(u8, ft, "no") and !std.mem.startsWith(u8, ft, "opts=")) single_type = ft;
    }
    if (devs.items.len == 0 or all) {
        if (verbose) u.out("Checking all file systems.\n");
        for (fstab) |f| {
            if (std.mem.eql(u8, f.fstype, "swap") or std.mem.eql(u8, f.fstype, "none") or std.mem.eql(u8, f.fstype, "auto") and false) continue;
            if (std.mem.indexOf(u8, f.opts, "noauto") != null) continue;
            if (root_skip and std.mem.eql(u8, f.target, "/")) continue;
            // the sixth fstab field (pass number) decides: 0 means "do not check"
            const raw = mnt.readFile("/etc/fstab") orelse "";
            var pass: u8 = 0;
            var lines = std.mem.splitScalar(u8, raw, '\n');
            while (lines.next()) |l0| {
                const l = std.mem.trim(u8, l0, " \t\r");
                if (l.len == 0 or l[0] == '#') continue;
                var it = std.mem.tokenizeAny(u8, l, " \t");
                const s0 = it.next() orelse continue;
                if (!std.mem.eql(u8, s0, f.source)) continue;
                _ = it.next();
                _ = it.next();
                _ = it.next();
                _ = it.next();
                if (it.next()) |ps| pass = std.fmt.parseInt(u8, ps, 10) catch 0;
                break;
            }
            if (pass == 0) continue;
            if (fstype_arg) |ft| if (!typeFilter(ft, f.fstype)) continue;
            targets.push(.{ .dev = f.source, .fstype = f.fstype });
        }
        if (all) {
            // explicit devices are ignored with -A
        } else if (devs.items.len == 0) {}
    } else {
        for (devs.items) |d| {
            var ty: ?[]const u8 = null;
            const rp = mnt.realpath(d) orelse d;
            for (fstab) |f| {
                const fs_src = if (mnt.isTagPub(f.source)) (mnt.resolveTag(f.source) orelse f.source) else f.source;
                if (std.mem.eql(u8, f.source, d) or std.mem.eql(u8, f.target, d) or std.mem.eql(u8, mnt.realpath(fs_src) orelse fs_src, rp)) {
                    if (!std.mem.eql(u8, f.fstype, "auto")) ty = f.fstype;
                    break;
                }
            }
            if (ty == null) ty = mnt.detectFs(rp);
            if (ty == null) ty = single_type;
            targets.push(.{ .dev = d, .fstype = ty orelse "ext2" });
        }
    }
    var status: u8 = 0;
    for (targets.items) |t| {
        const helper = findFsck(t.fstype) orelse {
            u.errf("fsck: fsck.{s} not found; ignore {s}\n", .{ t.fstype, t.dev });
            continue;
        };
        const hname = std.fs.path.basename(helper);
        if (noexec or verbose) {
            var line = u.Vec(u8).init(u.alloc);
            line.pushSlice(std.fmt.allocPrint(u.alloc, "[{s} (1) -- {s}] ", .{ helper, t.dev }) catch "");
            line.pushSlice(std.fmt.allocPrint(u.alloc, "fsck.{s} ", .{t.fstype}) catch "");
            if (progress != null and std.mem.startsWith(u8, t.fstype, "ext")) {
                line.pushSlice(if (progress.?.len > 2) progress.? else "-C0");
                line.push(' ');
            }
            for (passthru.items) |pa| {
                line.pushSlice(pa);
                line.push(' ');
            }
            line.pushSlice(t.dev);
            line.push(' ');
            line.push('\n');
            u.out(line.items);
            if (noexec) continue;
        }
        const pid = linux.fork();
        if (!u.ok(pid)) {
            status |= 8;
            continue;
        }
        if (pid == 0) {
            var av = u.Vec(?[*:0]const u8).init(u.alloc);
            av.push(u.zstr(hname).ptr);
            if (progress != null and std.mem.startsWith(u8, t.fstype, "ext")) av.push(u.zstr(if (progress.?.len > 2) progress.? else "-C0").ptr);
            for (passthru.items) |pa| av.push(u.zstr(pa).ptr);
            av.push(u.zstr(t.dev).ptr);
            av.push(null);
            _ = linux.execve(u.zstr(helper).ptr, @ptrCast(av.items.ptr), u.envp(&.{}));
            linux.exit_group(8);
        }
        var st: u32 = 0;
        _ = linux.wait4(@intCast(pid), &st, 0, null);
        if (st & 0x7f != 0) {
            u.errf("fsck: {s} terminated by signal {d}\n", .{ hname, st & 0x7f });
            status |= 4;
        } else status |= @intCast((st >> 8) & 0xff);
    }
    return status;
}
