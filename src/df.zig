// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// df - GNU coreutils: -a -B -h -H -i -k -l -m -P -t -T -x --total
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");

const Mnt = struct { dev: u64, source: []const u8, target: []const u8, fstype: []const u8 };

const Row = struct {
    source: []const u8,
    fstype: []const u8,
    target: []const u8,
    size: u128 = 0,
    used: u128 = 0,
    avail: u128 = 0,
    // inode mode reuses size/used/avail
    has_data: bool = true,
};

fn unescapeMnt(s: []const u8) []const u8 {
    var o = u.Vec(u8).init(u.alloc);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == 0x5c and i + 4 <= s.len) {
            const d = s[i + 1 .. i + 4];
            if (std.fmt.parseInt(u8, d, 8)) |v| {
                o.push(v);
                i += 3;
                continue;
            } else |_| {}
        }
        o.push(s[i]);
    }
    return o.items;
}

fn readMounts() []Mnt {
    var list = u.Vec(Mnt).init(u.alloc);
    var f = u.File.open("/proc/self/mountinfo", .{ .ACCMODE = .RDONLY }, 0) orelse return list.items;
    defer f.close();
    var lines = u.Vec([]const u8).init(u.alloc);
    u.readAllLines(&f, &lines);
    for (lines.items) |ln| {
        var it = std.mem.tokenizeScalar(u8, ln, ' ');
        _ = it.next(); // id
        _ = it.next(); // parent
        const mm = it.next() orelse continue;
        _ = it.next(); // root
        const mp = it.next() orelse continue;
        _ = it.next(); // options
        while (it.next()) |t| if (std.mem.eql(u8, t, "-")) break;
        const fst = it.next() orelse continue;
        const src = it.next() orelse continue;
        const colon = std.mem.indexOfScalar(u8, mm, ':') orelse continue;
        const maj = std.fmt.parseInt(u32, mm[0..colon], 10) catch continue;
        const min = std.fmt.parseInt(u32, mm[colon + 1 ..], 10) catch continue;
        list.push(.{
            .dev = (@as(u64, maj) << 32) | min,
            .source = unescapeMnt(src),
            .target = unescapeMnt(mp),
            .fstype = fst,
        });
    }
    return list.items;
}

const dummy_types = [_][]const u8{ "autofs", "proc", "subfs", "debugfs", "devpts", "fusectl", "mqueue", "rpc_pipefs", "sysfs", "devfs", "kernfs", "ignore", "cgroup", "cgroup2", "securityfs", "pstore", "bpf", "tracefs", "configfs", "binfmt_misc", "hugetlbfs", "selinuxfs", "efivarfs" };

fn isDummy(t: []const u8) bool {
    for (dummy_types) |d| if (std.mem.eql(u8, d, t)) return true;
    return false;
}

fn isRemote(t: []const u8, src: []const u8) bool {
    if (std.mem.startsWith(u8, t, "nfs") or std.mem.eql(u8, t, "cifs") or std.mem.eql(u8, t, "smbfs") or std.mem.eql(u8, t, "9p") or std.mem.eql(u8, t, "fuse.sshfs") or std.mem.eql(u8, t, "afs") or std.mem.eql(u8, t, "ncpfs")) return true;
    return std.mem.indexOfScalar(u8, src, ':') != null and !std.mem.startsWith(u8, src, "/");
}

const Statfs = extern struct {
    type: i64, bsize: i64, blocks: u64, bfree: u64, bavail: u64, files: u64, ffree: u64,
    fsid: [2]i32, namelen: i64, frsize: i64, flags: i64, spare: [4]i64,
};

fn doStatfs(path: []const u8) ?Statfs {
    var s: Statfs = undefined;
    const rc = linux.syscall2(if (@sizeOf(usize) == 4) .statfs64 else .statfs, @intFromPtr(u.zstr(path).ptr), @intFromPtr(&s));
    if (@sizeOf(usize) == 4) {
        // statfs64 takes (path, size, buf)
        const rc2 = linux.syscall3(.statfs64, @intFromPtr(u.zstr(path).ptr), @sizeOf(Statfs), @intFromPtr(&s));
        if (!u.ok(rc2)) return null;
        return s;
    }
    if (!u.ok(rc)) return null;
    return s;
}

const Unit = struct { human: u8 = 0, base: u128 = 1024, bs: u128 = 1024, header: []const u8 = "1K-blocks" }; // human: 0 none, 'h' 1024, 'H' 1000

fn human(n: u128, base: u128, out: *u.Vec(u8), si: bool) void {
    const suff_k = [_][]const u8{ "", "K", "M", "G", "T", "P", "E", "Z", "Y" };
    const suff_s = [_][]const u8{ "", "k", "M", "G", "T", "P", "E", "Z", "Y" };
    var e: usize = 0;
    var pw: u128 = 1;
    while (e < 8 and n >= pw * base) : (e += 1) pw *= base;
    var tmp: [64]u8 = undefined;
    if (e == 0) {
        const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return;
        for (s) |c| out.push(c);
        return;
    }
    var tenths = (n * 10 + pw - 1) / pw;
    if (tenths >= base * 10 and e < 8) {
        e += 1;
        pw *= base;
        tenths = (n * 10 + pw - 1) / pw;
    }
    const sfx = if (si) suff_s[e] else suff_k[e];
    if (tenths < 100) {
        const s = std.fmt.bufPrint(&tmp, "{d}.{d}{s}", .{ tenths / 10, tenths % 10, sfx }) catch return;
        for (s) |c| out.push(c);
    } else {
        const s = std.fmt.bufPrint(&tmp, "{d}{s}", .{ (n + pw - 1) / pw, sfx }) catch return;
        for (s) |c| out.push(c);
    }
}

fn fmtNum(n: u128, unit: Unit, inodes: bool) []const u8 {
    var o = u.Vec(u8).init(u.alloc);
    if (unit.human != 0) {
        human(n, if (unit.human == 'H') 1000 else 1024, &o, unit.human == 'H');
    } else {
        var tmp: [64]u8 = undefined;
        const v = if (inodes) n else (n + unit.bs - 1) / unit.bs;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch "";
        for (s) |c| o.push(c);
    }
    return o.items;
}

fn parseSizeSpec(s: []const u8) ?Unit {
    // [N]{K,M,G,T,P,E,Z,Y}[B|iB]  (K = 1024, KB = 1000)
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    var mult: u128 = if (i > 0) (std.fmt.parseInt(u128, s[0..i], 10) catch return null) else 1;
    if (mult == 0) return null;
    const sfx = s[i..];
    var unit_base: u128 = 1;
    if (sfx.len > 0) {
        const idx = std.mem.indexOfScalar(u8, "KMGTPEZY", std.ascii.toUpper(sfx[0])) orelse return null;
        var b: u128 = 1024;
        if (sfx.len == 2 and (sfx[1] == 'B')) b = 1000 else if (sfx.len == 3 and std.mem.eql(u8, sfx[1..], "iB")) b = 1024 else if (sfx.len != 1) return null;
        var k: usize = 0;
        unit_base = 1;
        while (k <= idx) : (k += 1) unit_base *= b;
        mult *= unit_base;
    }
    var hb = u.Vec(u8).init(u.alloc);
    var tmp: [64]u8 = undefined;
    if (sfx.len > 0 and i == 0) {
        // header: 1K-blocks, 1M-blocks ...
        const pre = std.fmt.bufPrint(&tmp, "1{s}-blocks", .{sfx}) catch return null;
        for (pre) |c| hb.push(c);
    } else {
        const pre = std.fmt.bufPrint(&tmp, "{s}-blocks", .{s}) catch return null;
        for (pre) |c| hb.push(c);
    }
    return .{ .human = 0, .bs = mult, .header = hb.items };
}

pub fn run(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "all", .key = 'a' },
        .{ .name = "block-size", .key = 'B', .arg = .req },
        .{ .name = "human-readable", .key = 'h' },
        .{ .name = "si", .key = 'H' },
        .{ .name = "inodes", .key = 'i' },
        .{ .key = 'k' },
        .{ .name = "local", .key = 'l' },
        .{ .key = 'm' },
        .{ .name = "portability", .key = 'P' },
        .{ .name = "type", .key = 't', .arg = .req },
        .{ .name = "print-type", .key = 'T' },
        .{ .name = "exclude-type", .key = 'x', .arg = .req },
        .{ .name = "total", .key = 130 },
        .{ .name = "sync", .key = 131 },
        .{ .name = "no-sync", .key = 132 },
        .{ .key = 'v' },
        .{ .name = "help", .key = 200 },
        .{ .name = "version", .key = 201 },
    };
    var p = g.Parser.init("df", args, &opts);
    var all = false;
    var inodes = false;
    var local = false;
    var posix = false;
    var show_type = false;
    var total = false;
    var unit = Unit{};
    var incl = u.Vec([]const u8).init(u.alloc);
    var excl = u.Vec([]const u8).init(u.alloc);
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'a' => all = true,
            'B' => unit = parseSizeSpec(it.val.?) orelse {
                u.errf("df: invalid --block-size argument '{s}'\n", .{it.val.?});
                return 1;
            },
            'h' => unit = .{ .human = 'h' },
            'H' => unit = .{ .human = 'H' },
            'i' => inodes = true,
            'k' => unit = .{},
            'l' => local = true,
            'm' => unit = .{ .bs = 1 << 20, .header = "1M-blocks" },
            'P' => posix = true,
            't' => incl.push(it.val.?),
            'T' => show_type = true,
            'x' => excl.push(it.val.?),
            130 => total = true,
            200 => {
                u.out("Usage: df [OPTION]... [FILE]...\nShow information about the file system on which each FILE resides,\nor all file systems by default.\n");
                return 0;
            },
            201 => {
                u.out("df (cmdbox)\n");
                return 0;
            },
            else => {},
        }
    }
    if (posix and unit.human == 0 and std.mem.eql(u8, unit.header, "1K-blocks")) unit.header = "1024-blocks";
    if (posix and show_type) {
        u.err("df: option --portability (-P) is incompatible with --print-type (-T)\n");
        return 1;
    }
    const mounts = readMounts();
    var rows = u.Vec(Row).init(u.alloc);
    var rc: u8 = 0;

    if (p.operands.items.len == 0) {
        var seen = u.Vec(usize).init(u.alloc); // index into rows by mount dev
        var seen_dev = u.Vec(u64).init(u.alloc);
        for (mounts) |m| {
            if (local and isRemote(m.fstype, m.source)) continue;
            if (!all and isDummy(m.fstype)) continue;
            if (!matchTypes(m.fstype, incl.items, excl.items)) continue;
            const sf = doStatfs(m.target) orelse continue;
            if (!all and sf.blocks == 0 and !inodes) continue;
            if (!all and inodes and sf.files == 0) continue;
            const row = makeRow(m, sf, inodes);
            var dup: ?usize = null;
            for (seen_dev.items, 0..) |d, k| if (d == m.dev) {
                dup = seen.items[k];
            };
            if (dup != null and !all) {
                // keep the entry with a real device source, otherwise the later one
                const old = rows.items[dup.?];
                if (std.mem.startsWith(u8, old.source, "/dev/") and !std.mem.startsWith(u8, m.source, "/dev/")) continue;
                rows.items[dup.?] = row;
                continue;
            }
            seen.push(rows.items.len);
            seen_dev.push(m.dev);
            rows.push(row);
        }
    } else {
        for (p.operands.items) |path| {
            const st = u.stat(path, true) orelse {
                u.errf("df: {s}: No such file or directory\n", .{path});
                rc = 1;
                continue;
            };
            const dev = (@as(u64, st.dev >> 32) << 32) | (st.dev & 0xffffffff);
            var best: ?Mnt = null;
            for (mounts) |m| {
                if (m.dev != dev) continue;
                if (best == null or m.target.len >= best.?.target.len) best = m;
            }
            const m = best orelse {
                u.errf("df: {s}: can't find mount point\n", .{path});
                rc = 1;
                continue;
            };
            if (!matchTypes(m.fstype, incl.items, excl.items)) continue;
            const sf = doStatfs(path) orelse {
                u.errf("df: {s}: No such file or directory\n", .{path});
                rc = 1;
                continue;
            };
            var row = makeRow(m, sf, inodes);
            // when a file (not the mountpoint) is named, GNU shows the device source
            row.target = m.target;
            rows.push(row);
        }
        if (rows.items.len == 0 and rc != 0) return rc;
    }

    if (total) {
        var t = Row{ .source = "total", .fstype = "-", .target = "-" };
        for (rows.items) |r| {
            t.size += r.size;
            t.used += r.used;
            t.avail += r.avail;
        }
        rows.push(t);
    }

    // build table
    var cols: usize = 6;
    var hdr = u.Vec([]const u8).init(u.alloc);
    hdr.push("Filesystem");
    if (show_type) hdr.push("Type");
    if (inodes) {
        hdr.push("Inodes");
        hdr.push("IUsed");
        hdr.push("IFree");
        hdr.push(if (posix) "Capacity" else "IUse%");
    } else if (unit.human != 0) {
        hdr.push("Size");
        hdr.push("Used");
        hdr.push("Avail");
        hdr.push(if (posix) "Capacity" else "Use%");
    } else {
        hdr.push(unit.header);
        hdr.push("Used");
        hdr.push(if (posix) "Available" else "Available");
        hdr.push(if (posix) "Capacity" else "Use%");
    }
    hdr.push("Mounted on");
    cols = hdr.items.len;
    var cells = u.Vec([]const u8).init(u.alloc);
    for (hdr.items) |h| cells.push(h);
    for (rows.items) |r| {
        cells.push(r.source);
        if (show_type) cells.push(r.fstype);
        cells.push(fmtNum(r.size, unit, inodes));
        cells.push(fmtNum(r.used, unit, inodes));
        cells.push(fmtNum(r.avail, unit, inodes));
        cells.push(pct(r, inodes));
        cells.push(r.target);
    }
    var widths = u.Vec(usize).init(u.alloc);
    var c: usize = 0;
    while (c < cols) : (c += 1) widths.push(0);
    const nrows = cells.items.len / cols;
    var ri: usize = 0;
    while (ri < nrows) : (ri += 1) {
        c = 0;
        while (c < cols) : (c += 1) widths.items[c] = @max(widths.items[c], cells.items[ri * cols + c].len);
    }
    // GNU minimum widths
    widths.items[0] = @max(widths.items[0], 14);
    {
        const first_num: usize = if (show_type) 2 else 1;
        var k: usize = first_num;
        while (k < first_num + 3) : (k += 1) widths.items[k] = @max(widths.items[k], 5);
        widths.items[first_num + 3] = @max(widths.items[first_num + 3], 4);
        if (show_type) widths.items[1] = @max(widths.items[1], 4);
    }
    var o = u.Vec(u8).init(u.alloc);
    ri = 0;
    while (ri < nrows) : (ri += 1) {
        c = 0;
        while (c < cols) : (c += 1) {
            const s = cells.items[ri * cols + c];
            const last = c == cols - 1;
            const left = c == 0 or (show_type and c == 1) or last;
            if (c > 0) o.push(' ');
            if (left) {
                for (s) |ch| o.push(ch);
                if (!last) {
                    var k = s.len;
                    while (k < widths.items[c]) : (k += 1) o.push(' ');
                }
            } else {
                var k = s.len;
                while (k < widths.items[c]) : (k += 1) o.push(' ');
                for (s) |ch| o.push(ch);
            }
        }
        o.push('\n');
    }
    u.out(o.items);
    return rc;
}

fn matchTypes(t: []const u8, incl: []const []const u8, excl: []const []const u8) bool {
    if (incl.len > 0) {
        var ok = false;
        for (incl) |i| if (std.mem.eql(u8, i, t)) {
            ok = true;
        };
        if (!ok) return false;
    }
    for (excl) |x| if (std.mem.eql(u8, x, t)) return false;
    return true;
}

fn makeRow(m: Mnt, sf: Statfs, inodes: bool) Row {
    const fr: u128 = if (sf.frsize > 0) @intCast(sf.frsize) else @intCast(sf.bsize);
    if (inodes) {
        return .{ .source = m.source, .fstype = m.fstype, .target = m.target, .size = sf.files, .used = sf.files -| sf.ffree, .avail = sf.ffree };
    }
    return .{
        .source = m.source,
        .fstype = m.fstype,
        .target = m.target,
        .size = @as(u128, sf.blocks) * fr,
        .used = @as(u128, sf.blocks -| sf.bfree) * fr,
        .avail = @as(u128, sf.bavail) * fr,
    };
}

fn pct(r: Row, inodes: bool) []const u8 {
    _ = inodes;
    const nonroot = r.used + r.avail;
    if (r.size == 0 or nonroot == 0) return "-";
    const hundred = r.used * 100;
    const p = hundred / nonroot + @as(u128, @intFromBool(hundred % nonroot != 0));
    return std.fmt.allocPrint(u.alloc, "{d}%", .{p}) catch "-";
}
