// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// losetup - util-linux compatible: -a -l -f -j -d -D -c -r -o --sizelimit -P --show -n -O --raw
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");

const LOOP_SET_FD: u32 = 0x4C00;
const LOOP_CLR_FD: u32 = 0x4C01;
const LOOP_SET_STATUS64: u32 = 0x4C04;
const LOOP_GET_STATUS64: u32 = 0x4C05;
const LOOP_SET_CAPACITY: u32 = 0x4C07;
const LOOP_CONFIGURE: u32 = 0x4C0A;
const LOOP_CTL_GET_FREE: u32 = 0x4C82;

const LO_FLAGS_READ_ONLY: u32 = 1;
const LO_FLAGS_AUTOCLEAR: u32 = 4;
const LO_FLAGS_PARTSCAN: u32 = 8;
const LO_FLAGS_DIRECT_IO: u32 = 16;

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

const LoopConfig = extern struct {
    fd: u32,
    block_size: u32,
    info: LoopInfo64,
    reserved: [8]u64,
};

const HELP: u8 = 200;
const VERSION: u8 = 201;
const SHOW: u8 = 202;
const SIZELIMIT: u8 = 203;
const OUTPUT_ALL: u8 = 204;
const RAW: u8 = 205;
const DIRECT: u8 = 206;
const REF: u8 = 207;

const help_text =
    "\nUsage:\n losetup [options] [<loopdev>]\n losetup [options] -f | <loopdev> <file>\n\nSet up and control loop devices.\n\nOptions:\n" ++
    " -a, --all                     list all used devices\n -d, --detach <loopdev>...     detach one or more devices\n -D, --detach-all              detach all used devices\n" ++
    " -f, --find                    find first unused device\n -c, --set-capacity <loopdev>  resize the device\n -j, --associated <file>       list all devices associated with <file>\n" ++
    " -L, --nooverlap               avoid possible conflict between devices\n\n -o, --offset <num>            start at offset <num> into file\n" ++
    "     --sizelimit <num>         device is limited to <num> bytes of the file\n -b, --sector-size <num>       set the logical sector size to <num>\n" ++
    " -P, --partscan                create a partitioned loop device\n -r, --read-only               set up a read-only loop device\n" ++
    "     --direct-io[=<on|off>]    open backing file with O_DIRECT\n     --loop-ref <string>       loop device reference\n" ++
    "     --show                    print device name after setup (with -f)\n -v, --verbose                 verbose mode\n\n" ++
    " -J, --json                    use JSON --list output format\n -l, --list                    list info about all or specified (default)\n" ++
    " -n, --noheadings              don't print headings for --list output\n -O, --output <cols>           specify columns to output for --list\n" ++
    "     --output-all              output all columns\n     --raw                     use raw --list output format\n\n" ++
    " -h, --help                    display this help\n -V, --version                 display version\n";

const Col = struct { name: []const u8, right: bool };
const all_cols = [_]Col{
    .{ .name = "NAME", .right = false },
    .{ .name = "AUTOCLEAR", .right = true },
    .{ .name = "BACK-FILE", .right = false },
    .{ .name = "BACK-INO", .right = true },
    .{ .name = "BACK-MAJ:MIN", .right = true },
    .{ .name = "BACK-MAJ", .right = false },
    .{ .name = "BACK-MIN", .right = true },
    .{ .name = "MAJ:MIN", .right = false },
    .{ .name = "MAJ", .right = false },
    .{ .name = "MIN", .right = false },
    .{ .name = "OFFSET", .right = true },
    .{ .name = "PARTSCAN", .right = true },
    .{ .name = "REF", .right = false },
    .{ .name = "RO", .right = true },
    .{ .name = "SIZELIMIT", .right = true },
    .{ .name = "DIO", .right = true },
    .{ .name = "LOG-SEC", .right = true },
};
const default_cols = "NAME,SIZELIMIT,OFFSET,AUTOCLEAR,RO,BACK-FILE,DIO,LOG-SEC";

fn devMajor(d: u64) u64 {
    return ((d >> 8) & 0xfff) | ((d >> 32) & ~@as(u64, 0xfff));
}
fn devMinor(d: u64) u64 {
    return (d & 0xff) | ((d >> 12) & ~@as(u64, 0xff));
}

fn backFile(info: *const LoopInfo64, dev: []const u8) []const u8 {
    // prefer the kernel's view in sysfs (full path), fall back to the 64-byte field
    const n = std.fmt.allocPrint(u.alloc, "/sys/block/{s}/loop/backing_file", .{u.basename(dev)}) catch return "";
    const fd = linux.open(u.zstr(n), .{ .ACCMODE = .RDONLY }, 0);
    if (u.ok(fd)) {
        defer _ = linux.close(@intCast(fd));
        var buf: [4096]u8 = undefined;
        const r = linux.read(@intCast(fd), &buf, buf.len);
        if (u.ok(r) and r > 0) return u.alloc.dupe(u8, std.mem.trimEnd(u8, buf[0..r], "\n")) catch "";
    }
    return u.alloc.dupe(u8, std.mem.sliceTo(&info.file_name, 0)) catch "";
}

fn sysNum(dev: []const u8, attr: []const u8, default: u64) u64 {
    const n = std.fmt.allocPrint(u.alloc, "/sys/block/{s}/{s}", .{ u.basename(dev), attr }) catch return default;
    const fd = linux.open(u.zstr(n), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(fd)) return default;
    defer _ = linux.close(@intCast(fd));
    var buf: [64]u8 = undefined;
    const r = linux.read(@intCast(fd), &buf, buf.len);
    if (!u.ok(r)) return default;
    return std.fmt.parseInt(u64, std.mem.trim(u8, buf[0..r], " \n"), 10) catch default;
}

fn getInfo(dev: []const u8) ?LoopInfo64 {
    const fd = linux.open(u.zstr(dev), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(fd)) return null;
    defer _ = linux.close(@intCast(fd));
    var info: LoopInfo64 = undefined;
    @memset(std.mem.asBytes(&info), 0);
    if (!u.ok(linux.ioctl(@intCast(fd), LOOP_GET_STATUS64, @intFromPtr(&info)))) return null;
    return info;
}

fn cell(col: []const u8, dev: []const u8, info: *const LoopInfo64) []const u8 {
    const A = u.alloc;
    if (std.mem.eql(u8, col, "NAME")) return dev;
    if (std.mem.eql(u8, col, "AUTOCLEAR")) return if (info.flags & LO_FLAGS_AUTOCLEAR != 0) "1" else "0";
    if (std.mem.eql(u8, col, "BACK-FILE")) return backFile(info, dev);
    if (std.mem.eql(u8, col, "BACK-INO")) return std.fmt.allocPrint(A, "{d}", .{info.inode}) catch "";
    if (std.mem.eql(u8, col, "BACK-MAJ:MIN")) return std.fmt.allocPrint(A, "{d}:{d}", .{ devMajor(info.device), devMinor(info.device) }) catch "";
    if (std.mem.eql(u8, col, "BACK-MAJ")) return std.fmt.allocPrint(A, "{d}", .{devMajor(info.device)}) catch "";
    if (std.mem.eql(u8, col, "BACK-MIN")) return std.fmt.allocPrint(A, "{d}", .{devMinor(info.device)}) catch "";
    if (std.mem.eql(u8, col, "MAJ:MIN")) return std.fmt.allocPrint(A, "7:{d}", .{info.number}) catch "";
    if (std.mem.eql(u8, col, "MAJ")) return "7";
    if (std.mem.eql(u8, col, "MIN")) return std.fmt.allocPrint(A, "{d}", .{info.number}) catch "";
    if (std.mem.eql(u8, col, "REF")) return backFile(info, dev);
    if (std.mem.eql(u8, col, "OFFSET")) return std.fmt.allocPrint(A, "{d}", .{info.offset}) catch "";
    if (std.mem.eql(u8, col, "PARTSCAN")) return if (info.flags & LO_FLAGS_PARTSCAN != 0) "1" else "0";
    if (std.mem.eql(u8, col, "RO")) return if (info.flags & LO_FLAGS_READ_ONLY != 0) "1" else "0";
    if (std.mem.eql(u8, col, "SIZELIMIT")) return std.fmt.allocPrint(A, "{d}", .{info.sizelimit}) catch "";
    if (std.mem.eql(u8, col, "DIO")) return if (info.flags & LO_FLAGS_DIRECT_IO != 0) "1" else "0";
    if (std.mem.eql(u8, col, "LOG-SEC")) return std.fmt.allocPrint(A, "{d}", .{sysNum(dev, "queue/logical_block_size", 512)}) catch "";
    return "";
}

fn printTable(devs: []const []const u8, infos: []const LoopInfo64, cols: []const []const u8, noheadings: bool, raw: bool) void {
    var rows = u.Vec([]const []const u8).init(u.alloc);
    for (devs, 0..) |d, i| {
        var cells = u.Vec([]const u8).init(u.alloc);
        for (cols) |c| cells.push(cell(c, d, &infos[i]));
        rows.push(cells.items);
    }
    var widths = u.alloc.alloc(usize, cols.len) catch return;
    var right = u.alloc.alloc(bool, cols.len) catch return;
    for (cols, 0..) |c, k| {
        widths[k] = c.len;
        right[k] = false;
        for (all_cols) |ac| if (std.mem.eql(u8, ac.name, c)) {
            right[k] = ac.right;
        };
        for (rows.items) |r| widths[k] = @max(widths[k], r[k].len);
    }
    var o = u.Vec(u8).init(u.alloc);
    const emit = struct {
        fn row(out: *u.Vec(u8), cells: []const []const u8, w: []const usize, rt: []const bool, is_raw: bool) void {
            for (cells, 0..) |c, k| {
                if (k > 0) out.push(' ');
                if (is_raw) {
                    out.pushSlice(c);
                    continue;
                }
                const last = k + 1 == cells.len;
                if (rt[k]) out.pushN(' ', w[k] - c.len);
                out.pushSlice(c);
                if (!rt[k] and !last) out.pushN(' ', w[k] - c.len);
            }
            out.push('\n');
        }
    }.row;
    if (!noheadings) emit(&o, cols, widths, right, raw);
    for (rows.items) |r| emit(&o, r, widths, right, raw);
    u.out(o.items);
}

fn allLoops(devs: *u.Vec([]const u8), infos: *u.Vec(LoopInfo64)) void {
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir("/dev", &ents)) return;
    var nums = u.Vec(u32).init(u.alloc);
    for (ents.items) |e| {
        const n: []const u8 = e.name;
        if (std.mem.startsWith(u8, n, "loop") and n.len > 4) {
            const num = std.fmt.parseInt(u32, n[4..], 10) catch continue;
            nums.push(num);
        }
    }
    std.mem.sort(u32, nums.items, {}, std.sort.asc(u32));
    for (nums.items) |num| {
        const path = std.fmt.allocPrint(u.alloc, "/dev/loop{d}", .{num}) catch continue;
        if (getInfo(path)) |info| {
            devs.push(path);
            infos.push(info);
        }
    }
}

fn parseSize(s: []const u8) ?u64 {
    var end: usize = 0;
    while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
    if (end == 0) return null;
    const base = std.fmt.parseInt(u64, s[0..end], 10) catch return null;
    const suf = s[end..];
    if (suf.len == 0) return base;
    const units = "KMGTPE";
    const idx = std.mem.indexOfScalar(u8, units, std.ascii.toUpper(suf[0])) orelse return null;
    const bin = suf.len == 1 or (suf.len == 3 and std.ascii.toLower(suf[1]) == 'i' and std.ascii.toLower(suf[2]) == 'b') or (suf.len == 2 and std.ascii.toLower(suf[1]) == 'b' and false);
    var mul: u64 = 1;
    var k: usize = 0;
    while (k <= idx) : (k += 1) mul *= if (bin) 1024 else 1000;
    if (suf.len == 2 and std.ascii.toLower(suf[1]) == 'b') {
        mul = 1;
        k = 0;
        while (k <= idx) : (k += 1) mul *= 1000;
    }
    return base * mul;
}

var want_json = false;

fn listAll(cols: []const []const u8, noheadings: bool, raw: bool, only: ?[]const u8, assoc: ?[]const u8) u8 {
    var devs = u.Vec([]const u8).init(u.alloc);
    var infos = u.Vec(LoopInfo64).init(u.alloc);
    if (only) |d| {
        const info = getInfo(d) orelse {
            const st = u.stat(d, true);
            if (st == null) u.errf("losetup: {s}: No such file or directory\n", .{d}) else u.errf("losetup: {s}: failed to use device: No such device or address\n", .{d});
            return 1;
        };
        devs.push(d);
        infos.push(info);
    } else allLoops(&devs, &infos);
    if (assoc) |f| {
        const st = u.stat(f, true) orelse {
            u.errf("losetup: {s}: failed to find backing file: No such file or directory\n", .{f});
            return 1;
        };
        var k: usize = 0;
        var i: usize = 0;
        while (i < devs.items.len) : (i += 1) {
            if (infos.items[i].inode == st.ino) {
                devs.items[k] = devs.items[i];
                infos.items[k] = infos.items[i];
                k += 1;
            }
        }
        devs.items.len = k;
        infos.items.len = k;
    }
    if (devs.items.len == 0) {
        if (want_json) u.out("{\n   \"loopdevices\": [\n\n   ]\n}\n");
        return 0;
    }
    printTable(devs.items, infos.items, cols, noheadings, raw);
    return 0;
}

fn listOldStyle(devs: []const []const u8, infos: []const LoopInfo64) void {
    var o = u.Vec(u8).init(u.alloc);
    for (devs, 0..) |d, i| {
        const info = infos[i];
        o.pushSlice(std.fmt.allocPrint(u.alloc, "{s}: [{d:0>4}]:{d} ({s})", .{ d, info.device, info.inode, backFile(&info, d) }) catch "");
        if (info.offset != 0) o.pushSlice(std.fmt.allocPrint(u.alloc, ", offset {d}", .{info.offset}) catch "");
        if (info.sizelimit != 0) o.pushSlice(std.fmt.allocPrint(u.alloc, ", sizelimit {d}", .{info.sizelimit}) catch "");
        o.push('\n');
    }
    u.out(o.items);
}

fn findFree() ?[]const u8 {
    const cfd = linux.open("/dev/loop-control", .{ .ACCMODE = .RDWR }, 0);
    if (!u.ok(cfd)) return null;
    defer _ = linux.close(@intCast(cfd));
    const r = linux.ioctl(@intCast(cfd), LOOP_CTL_GET_FREE, 0);
    if (!u.ok(r) and @as(isize, @bitCast(r)) < 0) return null;
    return std.fmt.allocPrint(u.alloc, "/dev/loop{d}", .{@as(u32, @intCast(r))}) catch null;
}

fn detach(dev: []const u8) bool {
    const fd = linux.open(u.zstr(dev), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(fd)) {
        u.errf("losetup: {s}: detach failed: {s}\n", .{ dev, u.strerr(u.errno(fd)) });
        return false;
    }
    defer _ = linux.close(@intCast(fd));
    const r = linux.ioctl(@intCast(fd), LOOP_CLR_FD, 0);
    if (!u.ok(r)) {
        u.errf("losetup: {s}: detach failed: {s}\n", .{ dev, u.strerr(u.errno(r)) });
        return false;
    }
    return true;
}

pub fn run(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "all", .key = 'a' },
        .{ .name = "detach", .key = 'd' },
        .{ .name = "detach-all", .key = 'D' },
        .{ .name = "find", .key = 'f' },
        .{ .name = "set-capacity", .key = 'c' },
        .{ .name = "associated", .key = 'j', .arg = .req },
        .{ .name = "nooverlap", .key = 'L' },
        .{ .name = "offset", .key = 'o', .arg = .req },
        .{ .name = "sizelimit", .key = SIZELIMIT, .arg = .req },
        .{ .name = "sector-size", .key = 'b', .arg = .req },
        .{ .name = "partscan", .key = 'P' },
        .{ .name = "read-only", .key = 'r' },
        .{ .name = "direct-io", .key = DIRECT, .arg = .opt },
        .{ .name = "loop-ref", .key = REF, .arg = .req },
        .{ .name = "show", .key = SHOW },
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "json", .key = 'J' },
        .{ .name = "list", .key = 'l' },
        .{ .name = "noheadings", .key = 'n' },
        .{ .name = "output", .key = 'O', .arg = .req },
        .{ .name = "output-all", .key = OUTPUT_ALL },
        .{ .name = "raw", .key = RAW },
        .{ .name = "help", .key = 'h' },
        .{ .name = "version", .key = 'V' },
    };
    var p = g.Parser.init("losetup", args, &opts);
    var all = false;
    var do_detach = false;
    var detach_all = false;
    var find = false;
    var capacity = false;
    var assoc: ?[]const u8 = null;
    var offset: u64 = 0;
    var sizelimit: u64 = 0;
    var partscan = false;
    var ro = false;
    var show = false;
    var list = false;
    var noheadings = false;
    var raw = false;
    var out_cols: []const u8 = default_cols;
    var sector: u32 = 0;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'h' => {
                u.out(help_text);
                return 0;
            },
            'V' => {
                u.out("losetup from util-linux 2.41.5\n");
                return 0;
            },
            'a' => all = true,
            'd' => do_detach = true,
            'D' => detach_all = true,
            'f' => find = true,
            'c' => capacity = true,
            'j' => assoc = it.val,
            'o' => offset = parseSize(it.val.?) orelse {
                u.errf("losetup: failed to parse offset\n", .{});
                return 1;
            },
            SIZELIMIT => sizelimit = parseSize(it.val.?) orelse {
                u.errf("losetup: failed to parse size\n", .{});
                return 1;
            },
            'b' => sector = @intCast(parseSize(it.val.?) orelse 0),
            'P' => partscan = true,
            'r' => ro = true,
            SHOW => show = true,
            'l' => list = true,
            'J' => {
                want_json = true;
                list = true;
            },
            'n' => noheadings = true,
            'O' => out_cols = it.val.?,
            OUTPUT_ALL => {
                var o = u.Vec(u8).init(u.alloc);
                for (all_cols, 0..) |c, k| {
                    if (k > 0) o.push(',');
                    o.pushSlice(c.name);
                }
                out_cols = o.items;
            },
            RAW => raw = true,
            else => {},
        }
    }
    const ops = p.operands.items;
    var cols = u.Vec([]const u8).init(u.alloc);
    {
        var ci = std.mem.splitScalar(u8, out_cols, ',');
        while (ci.next()) |c| {
            var found = false;
            for (all_cols) |ac| if (std.mem.eql(u8, ac.name, c)) {
                found = true;
            };
            if (!found) {
                u.errf("losetup: unknown column: {s}\n", .{c});
                return 1;
            }
            cols.push(c);
        }
    }

    if (do_detach) {
        if (ops.len == 0) {
            u.err("losetup: no loop device specified\n");
            return 1;
        }
        var rc: u8 = 0;
        for (ops) |d| if (!detach(d)) {
            rc = 1;
        };
        return rc;
    }
    if (detach_all) {
        var devs = u.Vec([]const u8).init(u.alloc);
        var infos = u.Vec(LoopInfo64).init(u.alloc);
        allLoops(&devs, &infos);
        var rc: u8 = 0;
        for (devs.items) |d| if (!detach(d)) {
            rc = 1;
        };
        return rc;
    }
    if (capacity) {
        if (ops.len != 1) {
            u.err("losetup: no loop device specified\n");
            return 1;
        }
        const fd = linux.open(u.zstr(ops[0]), .{ .ACCMODE = .RDONLY }, 0);
        if (!u.ok(fd)) {
            u.errf("losetup: {s}: failed to use device: {s}\n", .{ ops[0], u.strerr(u.errno(fd)) });
            return 1;
        }
        defer _ = linux.close(@intCast(fd));
        const r = linux.ioctl(@intCast(fd), LOOP_SET_CAPACITY, 0);
        if (!u.ok(r)) {
            u.errf("losetup: {s}: set capacity failed: {s}\n", .{ ops[0], u.strerr(u.errno(r)) });
            return 1;
        }
        return 0;
    }
    // listing modes
    if (assoc != null) {
        if (list) return listAll(cols.items, noheadings, raw, null, assoc);
        var devs = u.Vec([]const u8).init(u.alloc);
        var infos = u.Vec(LoopInfo64).init(u.alloc);
        allLoops(&devs, &infos);
        const st = u.stat(assoc.?, true) orelse {
            u.errf("losetup: {s}: failed to find backing file: No such file or directory\n", .{assoc.?});
            return 1;
        };
        var k: usize = 0;
        for (devs.items, 0..) |d, i| if (infos.items[i].inode == st.ino) {
            devs.items[k] = d;
            infos.items[k] = infos.items[i];
            k += 1;
        };
        listOldStyle(devs.items[0..k], infos.items[0..k]);
        return 0;
    }
    if (find and ops.len == 0) {
        const d = findFree() orelse {
            u.err("losetup: cannot find an unused loop device\n");
            return 1;
        };
        u.outf("{s}\n", .{d});
        return 0;
    }
    if (all or (ops.len == 0 and !find)) {
        if (list) return listAll(cols.items, noheadings, raw, null, null);
        if (ops.len == 0) {
            var devs = u.Vec([]const u8).init(u.alloc);
            var infos = u.Vec(LoopInfo64).init(u.alloc);
            allLoops(&devs, &infos);
            listOldStyle(devs.items, infos.items);
            return 0;
        }
    }
    if (ops.len == 1 and !find) {
        // single device: show it
        if (list) return listAll(cols.items, noheadings, raw, ops[0], null);
        const info = getInfo(ops[0]) orelse {
            if (u.stat(ops[0], true) == null) u.errf("losetup: {s}: No such file or directory\n", .{ops[0]}) else u.errf("losetup: {s}: failed to use device: No such device or address\n", .{ops[0]});
            return 1;
        };
        listOldStyle(&.{ops[0]}, &.{info});
        return 0;
    }
    // setup: [-f | loopdev] file
    var dev: []const u8 = "";
    var file: []const u8 = "";
    if (find) {
        if (ops.len != 1) {
            u.err("Usage: losetup -f [options] <file>\n");
            return 1;
        }
        file = ops[0];
        dev = findFree() orelse {
            u.err("losetup: cannot find an unused loop device\n");
            return 1;
        };
    } else {
        if (ops.len != 2) {
            u.err("losetup: unexpected number of arguments\n");
            return 1;
        }
        dev = ops[0];
        file = ops[1];
    }
    const ffd = linux.open(u.zstr(file), .{ .ACCMODE = if (ro) .RDONLY else .RDWR }, 0);
    var read_only = ro;
    var back_fd: i32 = undefined;
    if (!u.ok(ffd)) {
        const fd2 = linux.open(u.zstr(file), .{ .ACCMODE = .RDONLY }, 0);
        if (!u.ok(fd2)) {
            u.errf("losetup: {s}: failed to set up loop device: {s}\n", .{ file, u.strerr(u.errno(fd2)) });
            return 1;
        }
        back_fd = @intCast(fd2);
        read_only = true;
    } else back_fd = @intCast(ffd);
    defer _ = linux.close(back_fd);
    const lfd_rc = linux.open(u.zstr(dev), .{ .ACCMODE = if (read_only) .RDONLY else .RDWR }, 0);
    if (!u.ok(lfd_rc)) {
        u.errf("losetup: {s}: failed to set up loop device: {s}\n", .{ dev, u.strerr(u.errno(lfd_rc)) });
        return 1;
    }
    const lfd: i32 = @intCast(lfd_rc);
    defer _ = linux.close(lfd);
    var cfg: LoopConfig = undefined;
    @memset(std.mem.asBytes(&cfg), 0);
    cfg.fd = @intCast(back_fd);
    cfg.block_size = sector;
    cfg.info.offset = offset;
    cfg.info.sizelimit = sizelimit;
    cfg.info.flags = (if (read_only) LO_FLAGS_READ_ONLY else 0) | (if (partscan) LO_FLAGS_PARTSCAN else 0);
    const fn_len = @min(file.len, 63);
    @memcpy(cfg.info.file_name[0..fn_len], file[0..fn_len]);
    var r = linux.ioctl(lfd, LOOP_CONFIGURE, @intFromPtr(&cfg));
    if (!u.ok(r) and u.errno(r) == .INVAL) {
        // kernels before 5.8: SET_FD then SET_STATUS64
        r = linux.ioctl(lfd, LOOP_SET_FD, @intCast(back_fd));
        if (u.ok(r)) {
            r = linux.ioctl(lfd, LOOP_SET_STATUS64, @intFromPtr(&cfg.info));
            if (!u.ok(r)) _ = linux.ioctl(lfd, LOOP_CLR_FD, 0);
        }
    }
    if (!u.ok(r)) {
        u.errf("losetup: {s}: failed to set up loop device: {s}\n", .{ dev, u.strerr(u.errno(r)) });
        return 1;
    }
    if (show) u.outf("{s}\n", .{dev});
    return 0;
}
