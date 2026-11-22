// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// top - procps-ng compatible: batch mode (-b -n -d -p -u -U -o -w -c -H -i -S -E -1) and a basic interactive display
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const dt = @import("datetime.zig");
const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("unistd.h");
});

const TCGETS: u32 = 0x5401;
const TCSETS: u32 = 0x5402;
const TIOCGWINSZ: u32 = 0x5413;
const Winsize = extern struct { row: u16, col: u16, xpixel: u16, ypixel: u16 };

const Field = enum { pid, user, pr, ni, virt, res, shr, s, cpu, mem, time, command };
const field_names = [_][]const u8{ "PID", "USER", "PR", "NI", "VIRT", "RES", "SHR", "S", "%CPU", "%MEM", "TIME+", "COMMAND" };

const Proc = struct {
    pid: i64,
    uid: u32,
    comm: []const u8,
    cmdline: []const u8,
    state: u8,
    prio: i64,
    nice: i64,
    virt_kb: u64,
    res_kb: u64,
    shr_kb: u64,
    ticks: u64, // utime+stime (+children with -S)
    cpu: f64 = 0,
    mem: f64 = 0,
};

const CpuTimes = struct { us: u64 = 0, ni: u64 = 0, sy: u64 = 0, id: u64 = 0, wa: u64 = 0, hi: u64 = 0, si: u64 = 0, st: u64 = 0 };

fn readSmall(path: []const u8) ?[]u8 {
    const rc = linux.open(u.zstr(path), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(rc)) return null;
    defer _ = linux.close(@intCast(rc));
    var data = u.Vec(u8).init(u.alloc);
    var buf: [16384]u8 = undefined;
    while (true) {
        const r = linux.read(@intCast(rc), &buf, buf.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r) or r == 0) break;
        data.pushSlice(buf[0..r]);
    }
    return data.items;
}

const Opts = struct {
    batch: bool = false,
    iterations: u64 = 0,
    delay: f64 = 3.0,
    pids: ?[]const i64 = null,
    uid_filter: ?u32 = null,
    sort: Field = .cpu,
    sort_rev: bool = false,
    width: usize = 0,
    row_cut: usize = 1,
    cmdline: bool = false,
    threads: bool = false,
    idle_off: bool = false,
    cumulative: bool = false,
    unit: u8 = 'm',
    per_cpu: bool = false,
    hertz: f64 = 100,
    page_kb: u64 = 4,
    mem_total_kb: u64 = 1,
};

fn userName(uid: u32, buf: *[16]u8) []const u8 {
    var name: []const u8 = "";
    if (c.getpwuid(uid)) |p| name = std.mem.sliceTo(p.*.pw_name, 0) else name = std.fmt.bufPrint(buf, "{d}", .{uid}) catch "?";
    if (name.len > 8) {
        const out = u.alloc.alloc(u8, 8) catch return name;
        @memcpy(out[0..7], name[0..7]);
        out[7] = '+';
        return out;
    }
    return name;
}

fn scaleMem(kb: u64, width: usize) []const u8 {
    const plain = std.fmt.allocPrint(u.alloc, "{d}", .{kb}) catch return "";
    if (plain.len <= width) return plain;
    const units = "mgtpe";
    var v: f64 = @floatFromInt(kb);
    var k: usize = 0;
    while (k < units.len) : (k += 1) {
        v /= 1024.0;
        const a = std.fmt.allocPrint(u.alloc, "{d:.1}{c}", .{ v, units[k] }) catch return plain;
        if (a.len <= width) return a;
        const b = std.fmt.allocPrint(u.alloc, "{d:.0}{c}", .{ v, units[k] }) catch return plain;
        if (b.len <= width) return b;
    }
    return plain;
}

fn parseStat(st: []const u8, p: *Proc, o: *const Opts) bool {
    const lp = std.mem.indexOfScalar(u8, st, '(') orelse return false;
    const rp = std.mem.lastIndexOfScalar(u8, st, ')') orelse return false;
    p.comm = u.alloc.dupe(u8, st[lp + 1 .. rp]) catch return false;
    var it = std.mem.tokenizeScalar(u8, st[rp + 1 ..], ' ');
    var idx: usize = 3;
    var utime: u64 = 0;
    var stime: u64 = 0;
    var cutime: u64 = 0;
    var cstime: u64 = 0;
    var rss: u64 = 0;
    var vsize: u64 = 0;
    while (it.next()) |t| : (idx += 1) {
        switch (idx) {
            3 => p.state = t[0],
            14 => utime = std.fmt.parseInt(u64, t, 10) catch 0,
            15 => stime = std.fmt.parseInt(u64, t, 10) catch 0,
            16 => cutime = std.fmt.parseInt(u64, t, 10) catch 0,
            17 => cstime = std.fmt.parseInt(u64, t, 10) catch 0,
            18 => p.prio = std.fmt.parseInt(i64, t, 10) catch 0,
            19 => p.nice = std.fmt.parseInt(i64, t, 10) catch 0,
            23 => vsize = std.fmt.parseInt(u64, t, 10) catch 0,
            24 => rss = std.fmt.parseInt(u64, t, 10) catch 0,
            else => {},
        }
    }
    p.ticks = utime + stime + (if (o.cumulative) cutime + cstime else 0);
    p.virt_kb = vsize / 1024;
    p.res_kb = rss * o.page_kb;
    return true;
}

fn loadProcs(o: *const Opts) []Proc {
    var out = u.Vec(Proc).init(u.alloc);
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir("/proc", &ents)) return out.items;
    // numeric order, like readdir order of /proc
    for (ents.items) |e| {
        const pid = std.fmt.parseInt(i64, e.name, 10) catch continue;
        var pb: [96]u8 = undefined;
        var tids = u.Vec(i64).init(u.alloc);
        if (o.threads) {
            var te = u.Vec(u.DirEnt).init(u.alloc);
            if (u.listDir(std.fmt.bufPrint(&pb, "/proc/{d}/task", .{pid}) catch continue, &te)) for (te.items) |t| {
                tids.push(std.fmt.parseInt(i64, t.name, 10) catch continue);
            };
        } else tids.push(pid);
        for (tids.items) |tid| {
            const path = if (o.threads) std.fmt.bufPrint(&pb, "/proc/{d}/task/{d}/stat", .{ pid, tid }) catch continue else std.fmt.bufPrint(&pb, "/proc/{d}/stat", .{pid}) catch continue;
            const st = readSmall(path) orelse continue;
            var p = Proc{ .pid = tid, .uid = 0, .comm = "", .cmdline = "", .state = '?', .prio = 0, .nice = 0, .virt_kb = 0, .res_kb = 0, .shr_kb = 0, .ticks = 0 };
            if (!parseStat(st, &p, o)) continue;
            if (u.stat(std.fmt.bufPrint(&pb, "/proc/{d}", .{pid}) catch "", true)) |ps| p.uid = ps.uid;
            if (readSmall(std.fmt.bufPrint(&pb, "/proc/{d}/statm", .{pid}) catch "")) |sm| {
                var it = std.mem.tokenizeScalar(u8, sm, ' ');
                _ = it.next();
                _ = it.next();
                if (it.next()) |sh| p.shr_kb = (std.fmt.parseInt(u64, std.mem.trim(u8, sh, "\n"), 10) catch 0) * o.page_kb;
            }
            if (o.cmdline) {
                if (readSmall(std.fmt.bufPrint(&pb, "/proc/{d}/cmdline", .{pid}) catch "")) |cl| {
                    var b = u.Vec(u8).init(u.alloc);
                    for (std.mem.trimEnd(u8, cl, "\x00")) |ch| b.push(if (ch == 0) ' ' else ch);
                    p.cmdline = b.items;
                }
            }
            if (o.pids) |pl| {
                var found = false;
                for (pl) |x| if (x == tid or x == pid) {
                    found = true;
                };
                if (!found) continue;
            }
            if (o.uid_filter) |uf| if (p.uid != uf) continue;
            out.push(p);
        }
    }
    return out.items;
}

fn readCpu(per: *u.Vec(CpuTimes)) CpuTimes {
    var tot = CpuTimes{};
    const d = readSmall("/proc/stat") orelse return tot;
    var lines = std.mem.splitScalar(u8, d, '\n');
    while (lines.next()) |l| {
        if (!std.mem.startsWith(u8, l, "cpu")) continue;
        var it = std.mem.tokenizeScalar(u8, l, ' ');
        const name = it.next() orelse continue;
        var v: [10]u64 = [_]u64{0} ** 10;
        var k: usize = 0;
        while (it.next()) |t| : (k += 1) {
            if (k >= 10) break;
            v[k] = std.fmt.parseInt(u64, t, 10) catch 0;
        }
        const ct = CpuTimes{ .us = v[0] -| v[8], .ni = v[1] -| v[9], .sy = v[2], .id = v[3], .wa = v[4], .hi = v[5], .si = v[6], .st = v[7] };
        if (std.mem.eql(u8, name, "cpu")) tot = ct else per.push(ct);
    }
    return tot;
}

fn cpuLine(label: []const u8, a: CpuTimes, b: CpuTimes, o: *u.Vec(u8)) void {
    const d = CpuTimes{ .us = b.us -| a.us, .ni = b.ni -| a.ni, .sy = b.sy -| a.sy, .id = b.id -| a.id, .wa = b.wa -| a.wa, .hi = b.hi -| a.hi, .si = b.si -| a.si, .st = b.st -| a.st };
    const total: f64 = @floatFromInt(d.us + d.ni + d.sy + d.id + d.wa + d.hi + d.si + d.st);
    const f = struct {
        fn p(x: u64, t: f64) f64 {
            if (t <= 0) return 0;
            return @as(f64, @floatFromInt(x)) * 100.0 / t;
        }
    }.p;
    o.pushSlice(std.fmt.allocPrint(u.alloc, "{s}{d: >5.1} us,{d: >5.1} sy,{d: >5.1} ni,{d: >5.1} id,{d: >5.1} wa,{d: >5.1} hi,{d: >5.1} si,{d: >5.1} st \n", .{ label, f(d.us, total), f(d.sy, total), f(d.ni, total), f(d.id, total), f(d.wa, total), f(d.hi, total), f(d.si, total), f(d.st, total) }) catch "");
}

fn meminfoKb(d: []const u8, key: []const u8) u64 {
    var lines = std.mem.splitScalar(u8, d, '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, key) and l.len > key.len and l[key.len] == ':') {
            var it = std.mem.tokenizeAny(u8, l[key.len + 1 ..], " \tkB");
            return std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
        }
    }
    return 0;
}

fn unitScale(unit: u8) struct { div: f64, name: []const u8 } {
    return switch (unit) {
        'k' => .{ .div = 1, .name = "KiB" },
        'g' => .{ .div = 1024.0 * 1024.0, .name = "GiB" },
        't' => .{ .div = 1024.0 * 1024.0 * 1024.0, .name = "TiB" },
        'p' => .{ .div = 1024.0 * 1024.0 * 1024.0 * 1024.0, .name = "PiB" },
        'e' => .{ .div = 1024.0 * 1024.0 * 1024.0 * 1024.0 * 1024.0, .name = "EiB" },
        else => .{ .div = 1024.0, .name = "MiB" },
    };
}

fn userCount() u32 {
    const d = readSmall("/var/run/utmp") orelse readSmall("/run/utmp") orelse return logindUsers();
    var n: u32 = 0;
    var off: usize = 0;
    while (off + 384 <= d.len) : (off += 384) {
        const t = std.mem.readInt(i16, d[off .. off + 2][0..2], .little);
        if (t == 7) n += 1;
    }
    if (n == 0) return logindUsers();
    return n;
}

fn logindUsers() u32 {
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir("/run/systemd/sessions", &ents)) return 0;
    var seen = u.Vec([]const u8).init(u.alloc);
    for (ents.items) |e| {
        const name: []const u8 = e.name;
        const d = readSmall(std.fmt.allocPrint(u.alloc, "/run/systemd/sessions/{s}", .{name}) catch continue) orelse continue;
        var ls = std.mem.splitScalar(u8, d, '\n');
        while (ls.next()) |l| if (std.mem.startsWith(u8, l, "UID=")) {
            var dup = false;
            for (seen.items) |x| if (std.mem.eql(u8, x, l[4..])) {
                dup = true;
            };
            if (!dup) seen.push(l[4..]);
        };
    }
    return @intCast(seen.items.len);
}

fn header(o: *const Opts, procs: []const Proc, a: CpuTimes, b: CpuTimes, per_a: []const CpuTimes, per_b: []const CpuTimes, out: *u.Vec(u8)) void {
    // line 1
    const now = u.nowSecs();
    const tm = dt.localtime(now);
    var tb = u.Vec(u8).init(u.alloc);
    dt.format("%H:%M:%S", .{ .sec = now }, &tm, &tb);
    var up_secs: u64 = 0;
    if (readSmall("/proc/uptime")) |ud| {
        const f = std.fmt.parseFloat(f64, std.mem.sliceTo(ud, ' ')) catch 0;
        up_secs = @intFromFloat(f);
    }
    const days = up_secs / 86400;
    const hours = (up_secs / 3600) % 24;
    const mins = (up_secs / 60) % 60;
    var up = u.Vec(u8).init(u.alloc);
    if (days > 0) up.pushSlice(std.fmt.allocPrint(u.alloc, "{d} day{s}, {d: >2}:{d:0>2}", .{ days, if (days > 1) "s" else "", hours, mins }) catch "") else if (hours > 0) up.pushSlice(std.fmt.allocPrint(u.alloc, "{d: >2}:{d:0>2}", .{ hours, mins }) catch "") else up.pushSlice(std.fmt.allocPrint(u.alloc, "{d} min", .{mins}) catch "");
    var l1: f64 = 0;
    var l5: f64 = 0;
    var l15: f64 = 0;
    if (readSmall("/proc/loadavg")) |ld| {
        var it = std.mem.tokenizeScalar(u8, ld, ' ');
        l1 = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
        l5 = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
        l15 = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
    }
    const nu = userCount();
    out.pushSlice(std.fmt.allocPrint(u.alloc, "top - {s} up {s}, {d: >2} user{s},  load average: {d:.2}, {d:.2}, {d:.2}\n", .{ tb.items, up.items, nu, if (nu == 1) "" else "s", l1, l5, l15 }) catch "");
    // tasks
    var nrun: usize = 0;
    var sleep: usize = 0;
    var dsleep: usize = 0;
    var stopped: usize = 0;
    var zombie: usize = 0;
    for (procs) |p| switch (p.state) {
        'R' => nrun += 1,
        'S', 'I' => sleep += 1,
        'D' => dsleep += 1,
        'T', 't' => stopped += 1,
        'Z' => zombie += 1,
        else => {},
    };
    out.pushSlice(std.fmt.allocPrint(u.alloc, "{s}: {d} total, {d} running, {d} sleep, {d} d-sleep, {d} stopped, {d} zombie\n", .{ if (o.threads) "Threads" else "Tasks", procs.len, nrun, sleep, dsleep, stopped, zombie }) catch "");
    // cpu
    if (o.per_cpu) {
        for (per_b, 0..) |pb, i| {
            const pa = if (i < per_a.len) per_a[i] else CpuTimes{};
            const lab = std.fmt.allocPrint(u.alloc, "%Cpu{d: <3}:", .{i}) catch "";
            cpuLine(lab, pa, pb, out);
        }
    } else cpuLine("%Cpu(s):", a, b, out);
    // memory
    const md = readSmall("/proc/meminfo") orelse "";
    const total = meminfoKb(md, "MemTotal");
    const free = meminfoKb(md, "MemFree");
    const avail = meminfoKb(md, "MemAvailable");
    const buffcache = meminfoKb(md, "Buffers") + meminfoKb(md, "Cached") + meminfoKb(md, "SReclaimable");
    const swt = meminfoKb(md, "SwapTotal");
    const swf = meminfoKb(md, "SwapFree");
    const sc = unitScale(o.unit);
    const kb = struct {
        fn f(x: u64, div: f64) f64 {
            return @as(f64, @floatFromInt(x)) / div;
        }
    }.f;
    out.pushSlice(std.fmt.allocPrint(u.alloc, "{s} Mem : {d: >8.1} total,{d: >9.1} free,{d: >9.1} used,{d: >9.1} buff/cache     \n", .{ sc.name, kb(total, sc.div), kb(free, sc.div), kb(total -| avail, sc.div), kb(buffcache, sc.div) }) catch "");
    out.pushSlice(std.fmt.allocPrint(u.alloc, "{s} Swap: {d: >8.1} total,{d: >9.1} free,{d: >9.1} used.{d: >9.1} avail Mem \n", .{ sc.name, kb(swt, sc.div), kb(swf, sc.div), kb(swt -| swf, sc.div), kb(avail, sc.div) }) catch "");
    out.push('\n');
}

fn numStr(n: i64) []const u8 {
    return std.fmt.allocPrint(u.alloc, "{d}", .{n}) catch "";
}

fn timeStr(ticks: u64, hertz: f64) []const u8 {
    const cs: u64 = @intFromFloat(@as(f64, @floatFromInt(ticks)) * 100.0 / hertz);
    const mins = cs / 6000;
    const secs = (cs / 100) % 60;
    const hund = cs % 100;
    if (mins >= 6000) return std.fmt.allocPrint(u.alloc, "{d},{d:0>2}", .{ mins / 60, mins % 60 }) catch "";
    return std.fmt.allocPrint(u.alloc, "{d}:{d:0>2}.{d:0>2}", .{ mins, secs, hund }) catch "";
}

const SortCtx = struct { f: Field, rev: bool };

fn procLess(ctx: SortCtx, a: Proc, b: Proc) bool {
    // returns true when a should come before b
    const cmp: std.math.Order = switch (ctx.f) {
        .pid => std.math.order(a.pid, b.pid),
        .user => std.mem.order(u8, std.mem.sliceTo(&uname8(a.uid), 0), std.mem.sliceTo(&uname8(b.uid), 0)),
        .pr => std.math.order(a.prio, b.prio),
        .ni => std.math.order(a.nice, b.nice),
        .virt => std.math.order(a.virt_kb, b.virt_kb),
        .res => std.math.order(a.res_kb, b.res_kb),
        .shr => std.math.order(a.shr_kb, b.shr_kb),
        .s => std.math.order(a.state, b.state),
        .cpu => std.math.order(a.cpu, b.cpu),
        .mem => std.math.order(a.res_kb, b.res_kb),
        .time => std.math.order(a.ticks, b.ticks),
        .command => std.mem.order(u8, a.comm, b.comm),
    };
    // numeric fields default to descending, text fields ascending
    const desc = switch (ctx.f) {
        .user, .s => false,
        else => true,
    };
    const eff = if (desc != ctx.rev) cmp == .gt else cmp == .lt;
    if (cmp == .eq) return a.pid < b.pid;
    return eff;
}

fn uname8(uid: u32) [17]u8 {
    var out = [_]u8{0} ** 17;
    var nb: [16]u8 = undefined;
    const n = userName(uid, &nb);
    @memcpy(out[0..@min(n.len, 16)], n[0..@min(n.len, 16)]);
    return out;
}

fn emitLine(out: *u.Vec(u8), line: []const u8, width: usize, cut: usize) void {
    var l = line;
    if (width > 0 and width > cut and l.len > width - cut) l = l[0 .. width - cut];
    out.pushSlice(l);
    out.push('\n');
}

fn renderFrame(o: *const Opts, procs_in: []Proc, a: CpuTimes, b: CpuTimes, per_a: []const CpuTimes, per_b: []const CpuTimes, max_rows: ?usize) []const u8 {
    var out = u.Vec(u8).init(u.alloc);
    var hdr = u.Vec(u8).init(u.alloc);
    header(o, procs_in, a, b, per_a, per_b, &hdr);
    // header lines with width truncation
    var hl = std.mem.splitScalar(u8, hdr.items, '\n');
    while (hl.next()) |l| {
        if (hl.peek() == null and l.len == 0) break;
        emitLine(&out, l, o.width, 0);
    }
    std.mem.sort(Proc, procs_in, SortCtx{ .f = o.sort, .rev = o.sort_rev }, procLess);
    const colhead = "    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND";
    emitLine(&out, colhead, o.width, o.row_cut);
    var rows: usize = 0;
    for (procs_in) |p| {
        if (o.idle_off and p.cpu <= 0 and (p.state == 'S' or p.state == 'I')) continue;
        if (max_rows) |m| if (rows >= m) break;
        rows += 1;
        var nb: [16]u8 = undefined;
        var pr_buf: [16]u8 = undefined;
        const pr: []const u8 = if (p.prio < -99) "rt" else std.fmt.bufPrint(&pr_buf, "{d}", .{p.prio}) catch "?";
        const row = std.fmt.allocPrint(u.alloc, "{s: >7} {s: <8} {s: >3} {s: >3} {s: >7} {s: >6} {s: >6} {c} {d: >5.1} {d: >5.1} {s: >9} ", .{ numStr(p.pid), userName(p.uid, &nb), pr, numStr(p.nice), scaleMem(p.virt_kb, 7), scaleMem(p.res_kb, 6), scaleMem(p.shr_kb, 6), p.state, p.cpu, p.mem, timeStr(p.ticks, o.hertz) }) catch continue;
        var line = u.Vec(u8).init(u.alloc);
        line.pushSlice(row);
        const cmd = if (o.cmdline and p.cmdline.len > 0) p.cmdline else if (o.cmdline) (std.fmt.allocPrint(u.alloc, "[{s}]", .{p.comm}) catch p.comm) else p.comm;
        const room: usize = if (o.width > 0) (if (o.width - o.row_cut > row.len) o.width - o.row_cut - row.len else 0) else cmd.len;
        if (cmd.len > room and room > 0) {
            line.pushSlice(cmd[0 .. room - 1]);
            line.push('+');
        } else if (cmd.len <= room) line.pushSlice(cmd);
        emitLine(&out, line.items, o.width, o.row_cut);
    }
    return out.items;
}

fn sleepSecs(s: f64) void {
    var ts: linux.timespec = .{ .sec = @intFromFloat(s), .nsec = @intFromFloat((s - @floor(s)) * 1e9) };
    while (true) {
        var rem: linux.timespec = undefined;
        const r = linux.nanosleep(&ts, &rem);
        if (u.errno(r) == .INTR) {
            ts = rem;
            continue;
        }
        break;
    }
}

fn sample(o: *const Opts, tot: *CpuTimes, per: *u.Vec(CpuTimes)) []Proc {
    per.items.len = 0;
    tot.* = readCpu(per);
    return loadProcs(o);
}

fn setCpuPercent(procs: []Proc, prev: []const Proc, elapsed_ticks: f64, o: *const Opts) void {
    var map = std.AutoHashMap(i64, u64).init(u.alloc);
    for (prev) |p| map.put(p.pid, p.ticks) catch {};
    for (procs) |*p| {
        const before = map.get(p.pid) orelse 0;
        const d: f64 = @floatFromInt(p.ticks -| before);
        p.cpu = if (elapsed_ticks > 0) d * 100.0 / elapsed_ticks else 0;
        p.mem = @as(f64, @floatFromInt(p.res_kb)) * 100.0 / @as(f64, @floatFromInt(@max(o.mem_total_kb, 1)));
    }
}

fn fieldFrom(name: []const u8) ?Field {
    var up = u.Vec(u8).init(u.alloc);
    for (name) |ch| up.push(std.ascii.toUpper(ch));
    for (field_names, 0..) |n, i| if (std.mem.eql(u8, n, up.items)) return @enumFromInt(i);
    if (std.mem.eql(u8, up.items, "TIME")) return .time;
    return null;
}

pub fn run(args: []const []const u8) u8 {
    const opts_def = [_]g.Opt{
        .{ .name = "batch", .key = 'b' },
        .{ .name = "cmdline-toggle", .key = 'c' },
        .{ .name = "delay", .key = 'd', .arg = .req },
        .{ .name = "scale-summary-mem", .key = 'E', .arg = .req },
        .{ .name = "scale-task-mem", .key = 'e', .arg = .req },
        .{ .name = "threads-show", .key = 'H' },
        .{ .name = "help", .key = 'h' },
        .{ .name = "idle-toggle", .key = 'i' },
        .{ .name = "iterations", .key = 'n', .arg = .req },
        .{ .name = "sort-override", .key = 'o', .arg = .req },
        .{ .name = "pid", .key = 'p', .arg = .req },
        .{ .name = "secure-mode", .key = 's' },
        .{ .name = "accum-time-toggle", .key = 'S' },
        .{ .name = "filter-any-user", .key = 'u', .arg = .req },
        .{ .name = "filter-only-euser", .key = 'U', .arg = .req },
        .{ .name = "version", .key = 'V' },
        .{ .name = "width", .key = 'w', .arg = .req },
        .{ .key = '1' },
        .{ .key = 'a' },
        .{ .key = 'm' },
        .{ .key = 'z' },
        .{ .key = 'O' },
        .{ .key = 'v' },
    };
    var p = g.Parser.init("top", args, &opts_def);
    var o = Opts{};
    o.hertz = @floatFromInt(@max(c.sysconf(c._SC_CLK_TCK), 1));
    o.page_kb = @intCast(@max(@divTrunc(c.sysconf(c._SC_PAGESIZE), 1024), 1));
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'b' => o.batch = true,
            'c' => o.cmdline = true,
            'd' => {
                o.delay = std.fmt.parseFloat(f64, it.val.?) catch {
                    u.errf("top: bad delay interval '{s}'\n", .{it.val.?});
                    return 1;
                };
            },
            'E', 'e' => if (it.val.?.len == 1 and std.mem.indexOfScalar(u8, "kmgtpe", it.val.?[0]) != null) {
                if (it.key == 'E') o.unit = it.val.?[0];
            } else {
                u.errf("top: bad memory scaling '{s}'\n", .{it.val.?});
                return 1;
            },
            'H' => o.threads = true,
            'h', 'V', 'v' => {
                if (it.key == 'h') {
                    u.out("\nUsage:\n top [options]\n");
                } else u.out("top from procps-ng (cmdbox)\n");
                return 0;
            },
            'i' => o.idle_off = true,
            'n' => o.iterations = std.fmt.parseInt(u64, it.val.?, 10) catch {
                u.errf("top: bad iterations argument '{s}'\n", .{it.val.?});
                return 1;
            },
            'o' => {
                var nm = it.val.?;
                if (nm.len > 0 and (nm[0] == '+' or nm[0] == '-')) {
                    o.sort_rev = nm[0] == '-';
                    nm = nm[1..];
                }
                o.sort = fieldFrom(nm) orelse {
                    u.errf("top: unrecognized field name '{s}'\n", .{nm});
                    return 1;
                };
            },
            'p' => {
                var pl = u.Vec(i64).init(u.alloc);
                var sp = std.mem.splitScalar(u8, it.val.?, ',');
                while (sp.next()) |x| {
                    if (x.len == 0) continue;
                    const v = std.fmt.parseInt(i64, x, 10) catch {
                        u.errf("top: bad pid '{s}'\n", .{x});
                        return 1;
                    };
                    pl.push(if (v == 0) c.getpid() else v);
                }
                o.pids = pl.items;
            },
            'S' => o.cumulative = true,
            'u', 'U' => {
                const v = it.val.?;
                o.uid_filter = std.fmt.parseInt(u32, v, 10) catch u.findUser(v) orelse {
                    u.errf("top: invalid user '{s}'\n", .{v});
                    return 1;
                };
            },
            'w' => o.width = std.fmt.parseInt(usize, it.val.?, 10) catch 0,
            '1' => o.per_cpu = true,
            else => {},
        }
    }
    if (o.pids != null and o.uid_filter != null) {
        u.err("top: conflicting process selections (U/p/u)\n");
        return 1;
    }
    if (o.width == 0) {
        if (u.getEnv("COLUMNS")) |cs| {
            o.width = std.fmt.parseInt(usize, cs, 10) catch 0;
            if (o.width > 0) o.row_cut = 2;
        }
    }
    var ws: Winsize = undefined;
    const have_tty = u.ok(linux.ioctl(1, TIOCGWINSZ, @intFromPtr(&ws))) and ws.col > 0;
    if (o.width == 0) o.width = if (have_tty and !o.batch) ws.col else 80;
    var md_total: u64 = 1;
    if (readSmall("/proc/meminfo")) |md| md_total = meminfoKb(md, "MemTotal");
    o.mem_total_kb = md_total;

    // first sample, then a short pause so the first frame has real CPU percentages
    var cpu_a = CpuTimes{};
    var per_a = u.Vec(CpuTimes).init(u.alloc);
    var prev = sample(&o, &cpu_a, &per_a);
    var t_prev: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &t_prev);
    sleepSecs(0.2);

    var interactive_raw = false;
    var saved: linux.termios = undefined;
    if (!o.batch) {
        if (u.ok(linux.ioctl(0, TCGETS, @intFromPtr(&saved)))) {
            var t = saved;
            t.lflag.ICANON = false;
            t.lflag.ECHO = false;
            t.cc[@intFromEnum(linux.V.MIN)] = 0;
            t.cc[@intFromEnum(linux.V.TIME)] = 0;
            interactive_raw = u.ok(linux.ioctl(0, TCSETS, @intFromPtr(&t)));
            if (interactive_raw) u.out("\x1b[?1049h");
        }
    }
    defer if (interactive_raw) {
        _ = linux.ioctl(0, TCSETS, @intFromPtr(&saved));
        u.out("\x1b[?1049l");
    };

    var frame: u64 = 0;
    while (true) {
        var cpu_b = CpuTimes{};
        var per_b = u.Vec(CpuTimes).init(u.alloc);
        var cur = sample(&o, &cpu_b, &per_b);
        var t_now: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &t_now);
        const el = @as(f64, @floatFromInt(t_now.sec - t_prev.sec)) + @as(f64, @floatFromInt(t_now.nsec - t_prev.nsec)) / 1e9;
        setCpuPercent(cur, prev, el * o.hertz, &o);
        if (!o.batch and have_tty) {
            if (readSmall("/proc/self/stat") == null) {}
            var ws2: Winsize = undefined;
            if (u.ok(linux.ioctl(1, TIOCGWINSZ, @intFromPtr(&ws2))) and ws2.col > 0) {
                o.width = ws2.col;
                ws = ws2;
            }
        }
        const rows_avail: ?usize = if (!o.batch and have_tty) (if (ws.row > 7) @as(usize, ws.row) - 8 else 0) else null;
        const text = renderFrame(&o, cur, cpu_a, cpu_b, per_a.items, per_b.items, rows_avail);
        if (o.batch) {
            u.out(text);
            u.out("\n");
        } else {
            var scr = u.Vec(u8).init(u.alloc);
            scr.pushSlice("\x1b[H");
            var ls = std.mem.splitScalar(u8, text, '\n');
            while (ls.next()) |l| {
                if (ls.peek() == null and l.len == 0) break;
                scr.pushSlice(l);
                scr.pushSlice("\x1b[K\n");
            }
            scr.pushSlice("\x1b[J");
            u.out(scr.items);
        }
        frame += 1;
        if (o.iterations > 0 and frame >= o.iterations) break;
        cpu_a = cpu_b;
        per_a = per_b;
        prev = cur;
        t_prev = t_now;
        if (o.batch or !interactive_raw) {
            sleepSecs(o.delay);
        } else {
            // wait for the delay or a key press
            var pfd = [_]linux.pollfd{.{ .fd = 0, .events = linux.POLL.IN, .revents = 0 }};
            const r = linux.poll(&pfd, 1, @intFromFloat(o.delay * 1000));
            if (u.ok(r) and r > 0) {
                var kb: [8]u8 = undefined;
                const n = linux.read(0, &kb, kb.len);
                if (u.ok(n)) for (kb[0..n]) |ch| switch (ch) {
                    'q', 'Q' => return 0,
                    'P' => {
                        o.sort = .cpu;
                        o.sort_rev = false;
                    },
                    'M' => {
                        o.sort = .mem;
                        o.sort_rev = false;
                    },
                    'T' => {
                        o.sort = .time;
                        o.sort_rev = false;
                    },
                    'N' => {
                        o.sort = .pid;
                        o.sort_rev = true;
                    },
                    'R' => o.sort_rev = !o.sort_rev,
                    'c' => o.cmdline = !o.cmdline,
                    '1' => o.per_cpu = !o.per_cpu,
                    'i' => o.idle_off = !o.idle_off,
                    'H' => o.threads = !o.threads,
                    else => {},
                };
            }
        }
        _ = &cur;
    }
    return 0;
}
