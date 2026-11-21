// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// free - procps-ng compatible: -b -k -m -g -h -l -t -v -w -s -c --si --kibi... --kilo...
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");

const Info = struct {
    total: u64 = 0,
    free: u64 = 0,
    avail: u64 = 0,
    buffers: u64 = 0,
    cached: u64 = 0,
    sreclaim: u64 = 0,
    shmem: u64 = 0,
    swap_total: u64 = 0,
    swap_free: u64 = 0,
    commit_limit: u64 = 0,
    committed: u64 = 0,
    high_total: u64 = 0,
    high_free: u64 = 0,
    low_total: u64 = 0,
    low_free: u64 = 0,
    have_avail: bool = false,
};

fn readInfo() Info {
    var inf = Info{};
    var f = u.File.open("/proc/meminfo", .{ .ACCMODE = .RDONLY }, 0) orelse return inf;
    defer f.close();
    var lines = u.Vec([]const u8).init(u.alloc);
    u.readAllLines(&f, &lines);
    for (lines.items) |ln| {
        const c = std.mem.indexOfScalar(u8, ln, ':') orelse continue;
        const key = ln[0..c];
        var it = std.mem.tokenizeScalar(u8, ln[c + 1 ..], ' ');
        const vs = it.next() orelse continue;
        const kb = (std.fmt.parseInt(u64, vs, 10) catch continue) * 1024;
        if (std.mem.eql(u8, key, "MemTotal")) inf.total = kb else if (std.mem.eql(u8, key, "MemFree")) inf.free = kb else if (std.mem.eql(u8, key, "MemAvailable")) {
            inf.avail = kb;
            inf.have_avail = true;
        } else if (std.mem.eql(u8, key, "Buffers")) inf.buffers = kb else if (std.mem.eql(u8, key, "Cached")) inf.cached = kb else if (std.mem.eql(u8, key, "SReclaimable")) inf.sreclaim = kb else if (std.mem.eql(u8, key, "Shmem")) inf.shmem = kb else if (std.mem.eql(u8, key, "SwapTotal")) inf.swap_total = kb else if (std.mem.eql(u8, key, "SwapFree")) inf.swap_free = kb else if (std.mem.eql(u8, key, "CommitLimit")) inf.commit_limit = kb else if (std.mem.eql(u8, key, "Committed_AS")) inf.committed = kb else if (std.mem.eql(u8, key, "HighTotal")) inf.high_total = kb else if (std.mem.eql(u8, key, "HighFree")) inf.high_free = kb else if (std.mem.eql(u8, key, "LowTotal")) inf.low_total = kb else if (std.mem.eql(u8, key, "LowFree")) inf.low_free = kb;
    }
    if (!inf.have_avail) inf.avail = inf.free + inf.buffers + inf.cached + inf.sreclaim;
    return inf;
}

const Fmt = struct { human: bool = false, si: bool = false, div: u64 = 1024 };

fn cell(o: *u.Vec(u8), bytes: u64, f: Fmt) void {
    var tmp: [64]u8 = undefined;
    var s: []const u8 = "";
    if (f.human) {
        const base: f64 = if (f.si) 1000 else 1024;
        const units_bin = [_][]const u8{ "B", "Ki", "Mi", "Gi", "Ti", "Pi" };
        const units_si = [_][]const u8{ "B", "k", "M", "G", "T", "P" };
        var v: f64 = @floatFromInt(bytes);
        var e: usize = 0;
        while (v >= base and e < 5) : (e += 1) v /= base;
        const unit = if (f.si) units_si[e] else units_bin[e];
        if (e == 0) {
            s = std.fmt.bufPrint(&tmp, "{d}{s}", .{ bytes, unit }) catch "";
        } else if (v < 10) {
            s = std.fmt.bufPrint(&tmp, "{d:.1}{s}", .{ v, unit }) catch "";
        } else {
            s = std.fmt.bufPrint(&tmp, "{d:.0}{s}", .{ v, unit }) catch "";
        }
    } else {
        s = std.fmt.bufPrint(&tmp, "{d}", .{bytes / f.div}) catch "";
    }
    o.push(' ');
    var k: usize = s.len;
    while (k < 11) : (k += 1) o.push(' ');
    for (s) |ch| o.push(ch);
}

fn label(o: *u.Vec(u8), l: []const u8) void {
    for (l) |ch| o.push(ch);
    var k = l.len;
    while (k < 7) : (k += 1) o.push(' ');
}

fn hdrCell(o: *u.Vec(u8), l: []const u8) void {
    o.push(' ');
    var k = l.len;
    while (k < 11) : (k += 1) o.push(' ');
    for (l) |ch| o.push(ch);
}

fn once(f: Fmt, wide: bool, lohi: bool, total: bool, committed: bool) void {
    const inf = readInfo();
    var o = u.Vec(u8).init(u.alloc);
    label(&o, "");
    hdrCell(&o, "total");
    hdrCell(&o, "used");
    hdrCell(&o, "free");
    hdrCell(&o, "shared");
    if (wide) {
        hdrCell(&o, "buffers");
        hdrCell(&o, "cache");
    } else hdrCell(&o, "buff/cache");
    hdrCell(&o, "available");
    o.push('\n');
    const cache = inf.cached + inf.sreclaim;
    const used = if (inf.total > inf.avail) inf.total - inf.avail else 0;
    label(&o, "Mem:");
    cell(&o, inf.total, f);
    cell(&o, used, f);
    cell(&o, inf.free, f);
    cell(&o, inf.shmem, f);
    if (wide) {
        cell(&o, inf.buffers, f);
        cell(&o, cache, f);
    } else cell(&o, inf.buffers + cache, f);
    cell(&o, inf.avail, f);
    o.push('\n');
    if (lohi and (inf.low_total > 0 or inf.high_total > 0)) {
        label(&o, "Low:");
        cell(&o, inf.low_total, f);
        cell(&o, inf.low_total -| inf.low_free, f);
        cell(&o, inf.low_free, f);
        o.push('\n');
        label(&o, "High:");
        cell(&o, inf.high_total, f);
        cell(&o, inf.high_total -| inf.high_free, f);
        cell(&o, inf.high_free, f);
        o.push('\n');
    }
    const swap_used = inf.swap_total -| inf.swap_free;
    label(&o, "Swap:");
    cell(&o, inf.swap_total, f);
    cell(&o, swap_used, f);
    cell(&o, inf.swap_free, f);
    o.push('\n');
    if (total) {
        label(&o, "Total:");
        cell(&o, inf.total + inf.swap_total, f);
        cell(&o, used + swap_used, f);
        cell(&o, inf.free + inf.swap_free, f);
        o.push('\n');
    }
    if (committed) {
        label(&o, "Comm:");
        cell(&o, inf.commit_limit, f);
        cell(&o, inf.committed, f);
        cell(&o, inf.commit_limit -| inf.committed, f);
        o.push('\n');
    }
    u.out(o.items);
}

pub fn run(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "bytes", .key = 'b' },
        .{ .name = "kilo", .key = 130 },
        .{ .name = "mega", .key = 131 },
        .{ .name = "giga", .key = 132 },
        .{ .name = "tera", .key = 133 },
        .{ .name = "peta", .key = 134 },
        .{ .name = "kibi", .key = 'k' },
        .{ .name = "mebi", .key = 'm' },
        .{ .name = "gibi", .key = 'g' },
        .{ .name = "tebi", .key = 135 },
        .{ .name = "pebi", .key = 136 },
        .{ .name = "human", .key = 'h' },
        .{ .name = "si", .key = 137 },
        .{ .name = "lohi", .key = 'l' },
        .{ .name = "total", .key = 't' },
        .{ .name = "committed", .key = 'v' },
        .{ .name = "wide", .key = 'w' },
        .{ .name = "seconds", .key = 's', .arg = .req },
        .{ .name = "count", .key = 'c', .arg = .req },
        .{ .name = "help", .key = 200 },
        .{ .name = "version", .key = 'V' },
    };
    var p = g.Parser.init("free", args, &opts);
    var f = Fmt{};
    var wide = false;
    var lohi = false;
    var total = false;
    var committed = false;
    var secs: ?f64 = null;
    var count: ?u64 = null;
    var si_mode = false;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'b' => f = .{ .div = 1 },
            'k' => f = .{ .div = 1024 },
            'm' => f = .{ .div = 1 << 20 },
            'g' => f = .{ .div = 1 << 30 },
            135 => f = .{ .div = 1 << 40 },
            136 => f = .{ .div = 1 << 50 },
            130 => f = .{ .div = 1000 },
            131 => f = .{ .div = 1000 * 1000 },
            132 => f = .{ .div = 1000 * 1000 * 1000 },
            133 => f = .{ .div = 1000 * 1000 * 1000 * 1000 },
            134 => f = .{ .div = 1000 * 1000 * 1000 * 1000 * 1000 },
            'h' => {
                f.human = true;
                f.si = si_mode;
            },
            137 => {
                si_mode = true;
                f.si = true;
            },
            'l' => lohi = true,
            't' => total = true,
            'v' => committed = true,
            'w' => wide = true,
            's' => {
                secs = std.fmt.parseFloat(f64, it.val.?) catch null;
                if (secs == null or secs.? <= 0) {
                    u.errf("free: seconds argument `{s}' failed\n", .{it.val.?});
                    return 1;
                }
            },
            'c' => {
                count = std.fmt.parseInt(u64, it.val.?, 10) catch {
                    u.errf("free: failed to parse count argument: '{s}'\n", .{it.val.?});
                    return 1;
                };
            },
            200 => {
                u.out("\nUsage:\n free [options]\n\nOptions:\n -b, --bytes         show output in bytes\n -k, --kibi          show output in kibibytes\n -m, --mebi          show output in mebibytes\n -g, --gibi          show output in gibibytes\n -h, --human         show human-readable output\n     --si            use powers of 1000 not 1024\n -l, --lohi          show detailed low and high memory statistics\n -t, --total         show total for RAM + swap\n -v, --committed     show committed memory and commit limit\n -s, --seconds <secs> repeat printing every N seconds\n -c, --count <count> repeat printing N times, then exit\n -w, --wide          wide output\n");
                return 0;
            },
            'V' => {
                u.out("free (cmdbox)\n");
                return 0;
            },
            else => {},
        }
    }
    if (p.operands.items.len > 0) {
        u.errf("free: unrecognized argument '{s}'\n", .{p.operands.items[0]});
        return 1;
    }
    if (secs != null and count == null) count = std.math.maxInt(u64);
    var n: u64 = 0;
    while (true) {
        once(f, wide, lohi, total, committed);
        n += 1;
        if (count == null or n >= count.?) break;
        u.out("\n");
        const s = secs.?;
        var ts = linux.timespec{ .sec = @intFromFloat(s), .nsec = @intFromFloat((s - @floor(s)) * 1e9) };
        _ = linux.nanosleep(&ts, null);
    }
    return 0;
}
