// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// udhcpc udhcpd dumpleases dhcprelay - busybox-style DHCP suite
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const mnt = @import("mount.zig");
const n2 = @import("nettools2.zig");

const VERSION = "v1.22.1";

fn htons(x: u16) u16 {
    return std.mem.nativeToBig(u16, x);
}

// ---------------------------------------------------------------- DHCP message
const Opt = struct { code: u8, data: []const u8 };

const Msg = struct {
    op: u8 = 1,
    htype: u8 = 1,
    hlen: u8 = 6,
    hops: u8 = 0,
    xid: u32 = 0,
    secs: u16 = 0,
    flags: u16 = 0,
    ciaddr: [4]u8 = @splat(0),
    yiaddr: [4]u8 = @splat(0),
    siaddr: [4]u8 = @splat(0),
    giaddr: [4]u8 = @splat(0),
    chaddr: [16]u8 = @splat(0),
    sname: [64]u8 = @splat(0),
    file: [128]u8 = @splat(0),
    opts: []Opt = &.{},

    fn get(self: *const Msg, code: u8) ?[]const u8 {
        for (self.opts) |o| if (o.code == code) return o.data;
        return null;
    }

    fn msgType(self: *const Msg) u8 {
        const d = self.get(53) orelse return 0;
        return if (d.len > 0) d[0] else 0;
    }
};

fn buildMsg(a: std.mem.Allocator, m: Msg) []u8 {
    var o = u.Vec(u8).init(a);
    o.pushSlice(&[_]u8{ m.op, m.htype, m.hlen, m.hops });
    var t: [4]u8 = undefined;
    std.mem.writeInt(u32, &t, m.xid, .big);
    o.pushSlice(&t);
    var t2: [2]u8 = undefined;
    std.mem.writeInt(u16, &t2, m.secs, .big);
    o.pushSlice(&t2);
    std.mem.writeInt(u16, &t2, m.flags, .big);
    o.pushSlice(&t2);
    o.pushSlice(&m.ciaddr);
    o.pushSlice(&m.yiaddr);
    o.pushSlice(&m.siaddr);
    o.pushSlice(&m.giaddr);
    o.pushSlice(&m.chaddr);
    o.pushSlice(&m.sname);
    o.pushSlice(&m.file);
    o.pushSlice(&[_]u8{ 0x63, 0x82, 0x53, 0x63 });
    for (m.opts) |op| {
        o.push(op.code);
        o.push(@intCast(op.data.len));
        o.pushSlice(op.data);
    }
    o.push(255);
    while (o.items.len < 300) o.push(0);
    return o.items;
}

fn parseMsg(a: std.mem.Allocator, d: []const u8) ?Msg {
    if (d.len < 240) return null;
    if (!std.mem.eql(u8, d[236..240], &[_]u8{ 0x63, 0x82, 0x53, 0x63 })) return null;
    var m = Msg{};
    m.op = d[0];
    m.htype = d[1];
    m.hlen = d[2];
    m.hops = d[3];
    m.xid = std.mem.readInt(u32, d[4..8], .big);
    m.secs = std.mem.readInt(u16, d[8..10], .big);
    m.flags = std.mem.readInt(u16, d[10..12], .big);
    m.ciaddr = d[12..16].*;
    m.yiaddr = d[16..20].*;
    m.siaddr = d[20..24].*;
    m.giaddr = d[24..28].*;
    m.chaddr = d[28..44].*;
    m.sname = d[44..108].*;
    m.file = d[108..236].*;
    var opts = u.Vec(Opt).init(a);
    var i: usize = 240;
    while (i < d.len) {
        const c0 = d[i];
        if (c0 == 255) break;
        if (c0 == 0) {
            i += 1;
            continue;
        }
        if (i + 1 >= d.len) break;
        const l = d[i + 1];
        if (i + 2 + l > d.len) break;
        opts.push(.{ .code = c0, .data = a.dupe(u8, d[i + 2 .. i + 2 + l]) catch return null });
        i += 2 + l;
    }
    m.opts = opts.items;
    return m;
}

fn ipCksum(d: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < d.len) : (i += 2) sum += @as(u32, d[i]) << 8 | d[i + 1];
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @intCast(~sum & 0xffff);
}

fn wrapUdp(a: std.mem.Allocator, src: [4]u8, sport: u16, dst: [4]u8, dport: u16, payload: []const u8) []u8 {
    const total = 20 + 8 + payload.len;
    const b = a.alloc(u8, total) catch return &.{};
    @memset(b, 0);
    b[0] = 0x45;
    std.mem.writeInt(u16, b[2..4], @intCast(total), .big);
    b[8] = 64;
    b[9] = 17;
    @memcpy(b[12..16], &src);
    @memcpy(b[16..20], &dst);
    std.mem.writeInt(u16, b[10..12], ipCksum(b[0..20]), .big);
    std.mem.writeInt(u16, b[20..22], sport, .big);
    std.mem.writeInt(u16, b[22..24], dport, .big);
    std.mem.writeInt(u16, b[24..26], @intCast(8 + payload.len), .big);
    @memcpy(b[28..], payload);
    return b;
}

const SockLl = extern struct {
    family: u16 = 17,
    protocol: u16 = 0,
    ifindex: i32 = 0,
    hatype: u16 = 0,
    pkttype: u8 = 0,
    halen: u8 = 0,
    addr: [8]u8 = @splat(0),
};

const IfReq = extern struct { name: [16]u8, data: [24]u8 };

fn ifIoctl(fd: i32, req: u32, name: []const u8, ifr: *IfReq) bool {
    ifr.* = .{ .name = @splat(0), .data = @splat(0) };
    @memcpy(ifr.name[0..@min(name.len, 15)], name[0..@min(name.len, 15)]);
    return u.ok(linux.ioctl(fd, req, @intFromPtr(ifr)));
}

fn ip4(s: []const u8) ?[4]u8 {
    return n2.parseIpv4(s);
}

fn fmt4(a: [4]u8) []const u8 {
    return n2.fmtIp(a);
}

fn rand32() u32 {
    var r: u32 = 0;
    _ = linux.getrandom(@ptrCast(&r), 4, 0);
    return r;
}

fn nowS() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @intCast(ts.sec);
}

fn wallS() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

// ---------------------------------------------------------------- udhcpc
const DISCOVER = 1;
const OFFER = 2;
const REQUEST = 3;
const DECLINE = 4;
const ACK = 5;
const NAK = 6;
const RELEASE = 7;

var quit_flag = false;
fn onSig(sig: linux.SIG) callconv(.c) void {
    _ = sig;
    quit_flag = true;
}

const Lease = struct {
    ip: [4]u8,
    server: [4]u8,
    secs: u32,
    msg: Msg,
};

fn runScript(script: []const u8, action: []const u8, iface: []const u8, lease: ?Lease) void {
    if (!u.ok(linux.access(u.zstr(script), 1))) return;
    const pid = linux.fork();
    if (!u.ok(pid) or pid != 0) {
        if (u.ok(pid)) {
            var st: u32 = 0;
            _ = linux.wait4(@intCast(pid), &st, 0, null);
        }
        return;
    }
    u.setEnv("interface", iface);
    if (lease) |l| {
        const m = l.msg;
        u.setEnv("ip", fmt4(l.ip));
        u.setEnv("siaddr", fmt4(m.siaddr));
        u.setEnv("serverid", fmt4(l.server));
        u.setEnv("lease", std.fmt.allocPrint(u.alloc, "{d}", .{l.secs}) catch "");
        u.setEnv("opt53", std.fmt.allocPrint(u.alloc, "{d}", .{m.msgType()}) catch "");
        if (m.get(1)) |sn| if (sn.len == 4) {
            u.setEnv("subnet", fmt4(sn[0..4].*));
            const mask = std.mem.readInt(u32, sn[0..4], .big);
            u.setEnv("mask", std.fmt.allocPrint(u.alloc, "{d}", .{@popCount(mask)}) catch "");
            const ipn = std.mem.readInt(u32, &l.ip, .big);
            var bc: [4]u8 = undefined;
            std.mem.writeInt(u32, &bc, (ipn & mask) | ~mask, .big);
            u.setEnv("broadcast", fmt4(bc));
        };
        if (m.get(28)) |b| if (b.len == 4) u.setEnv("broadcast", fmt4(b[0..4].*));
        const lists = [_]struct { code: u8, name: []const u8 }{ .{ .code = 3, .name = "router" }, .{ .code = 6, .name = "dns" }, .{ .code = 42, .name = "ntpsrv" }, .{ .code = 4, .name = "timesvr" }, .{ .code = 44, .name = "wins" } };
        for (lists) |li| if (m.get(li.code)) |d| {
            var o = u.Vec(u8).init(u.alloc);
            var k: usize = 0;
            while (k + 4 <= d.len) : (k += 4) {
                if (k > 0) o.push(' ');
                o.pushSlice(fmt4(d[k..][0..4].*));
            }
            u.setEnv(li.name, o.items);
        };
        const strs = [_]struct { code: u8, name: []const u8 }{ .{ .code = 12, .name = "hostname" }, .{ .code = 15, .name = "domain" }, .{ .code = 40, .name = "nisdomain" }, .{ .code = 56, .name = "message" } };
        for (strs) |si| if (m.get(si.code)) |d| u.setEnv(si.name, std.mem.trimEnd(u8, d, "\x00"));
        if (m.get(26)) |d| if (d.len == 2) u.setEnv("mtu", std.fmt.allocPrint(u.alloc, "{d}", .{std.mem.readInt(u16, d[0..2], .big)}) catch "");
        if (m.get(2)) |d| if (d.len == 4) u.setEnv("timezone", std.fmt.allocPrint(u.alloc, "{d}", .{std.mem.readInt(i32, d[0..4], .big)}) catch "");
    }
    var av = [_]?[*:0]const u8{ u.zstr(script).ptr, u.zstr(action).ptr, null };
    _ = linux.execve(u.zstr(script).ptr, @ptrCast(&av), u.envp(&.{}));
    linux.exit_group(127);
}

pub fn udhcpc(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "interface", .key = 'i', .arg = .req }, .{ .name = "script", .key = 's', .arg = .req },
        .{ .name = "foreground", .key = 'f' }, .{ .name = "background", .key = 'b' },
        .{ .name = "now", .key = 'n' }, .{ .name = "quit", .key = 'q' }, .{ .name = "release", .key = 'R' },
        .{ .name = "retries", .key = 't', .arg = .req }, .{ .name = "timeout", .key = 'T', .arg = .req },
        .{ .name = "tryagain", .key = 'A', .arg = .req }, .{ .name = "pidfile", .key = 'p', .arg = .req },
        .{ .name = "request", .key = 'r', .arg = .req }, .{ .name = "hostname", .key = 'H', .arg = .req },
        .{ .name = "fqdn", .key = 'F', .arg = .req }, .{ .name = "vendorclass", .key = 'V', .arg = .req },
        .{ .name = "clientid", .key = 'c', .arg = .req }, .{ .name = "clientid-none", .key = 'C' },
        .{ .name = "request-option", .key = 'O', .arg = .req }, .{ .name = "no-default-options", .key = 'o' },
        .{ .name = "syslog", .key = 'S' }, .{ .name = "broadcast", .key = 'B' }, .{ .name = "", .key = 'a', .arg = .opt },
        .{ .name = "", .key = 'x', .arg = .req }, .{ .name = "", .key = 'v' },
    };
    var p = g.Parser.init("udhcpc", args, &opts);
    var iface: []const u8 = "eth0";
    var script: []const u8 = "/usr/share/udhcpc/default.script";
    var foreground = false;
    defer _ = &foreground;
    var now_mode = false;
    var quit_after = false;
    var release = false;
    var tries: u32 = 3;
    var timeout_s: i64 = 3;
    var tryagain_s: i64 = 20;
    var req_ip: ?[4]u8 = null;
    var hostname: ?[]const u8 = null;
    var vendor: []const u8 = "udhcp " ++ VERSION[1..];
    var pidfile: ?[]const u8 = null;
    var bcast_flag = false;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'i' => iface = it.val.?,
            's' => script = it.val.?,
            'f' => foreground = !foreground,
            'n' => now_mode = true,
            'q' => quit_after = true,
            'R' => release = true,
            't' => tries = std.fmt.parseInt(u32, it.val.?, 10) catch 3,
            'T' => timeout_s = std.fmt.parseInt(i64, it.val.?, 10) catch 3,
            'A' => tryagain_s = std.fmt.parseInt(i64, it.val.?, 10) catch 20,
            'r' => req_ip = ip4(it.val.?),
            'H', 'F' => hostname = it.val,
            'V' => vendor = it.val.?,
            'p' => pidfile = it.val,
            'B' => bcast_flag = true,
            else => {},
        }
    }
    if (c_getuid() != 0) {
        u.err("udhcpc: socket(AF_PACKET): Operation not permitted\n");
        return 1;
    }
    const ctl = linux.socket(2, 2, 0);
    if (!u.ok(ctl)) return 1;
    const cfd: i32 = @intCast(ctl);
    defer _ = linux.close(cfd);
    var ifr: IfReq = undefined;
    if (!ifIoctl(cfd, 0x8933, iface, &ifr)) {
        u.errf("udhcpc: SIOCGIFINDEX: No such device\n", .{});
        return 1;
    }
    const ifindex = std.mem.readInt(i32, ifr.data[0..4], .little);
    if (!ifIoctl(cfd, 0x8927, iface, &ifr)) return 1;
    const mac: [6]u8 = ifr.data[2..8].*;
    if (pidfile) |pf| {
        const body = std.fmt.allocPrint(u.alloc, "{d}\n", .{linux.getpid()}) catch "";
        const rc = linux.open(u.zstr(pf), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        if (u.ok(rc)) {
            _ = linux.write(@intCast(rc), body.ptr, body.len);
            _ = linux.close(@intCast(rc));
        }
    }
    var act = linux.Sigaction{ .handler = .{ .handler = onSig }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(linux.SIG.TERM, &act, null);
    _ = linux.sigaction(linux.SIG.INT, &act, null);
    const rs = linux.socket(17, 2, htons(0x0800));
    if (!u.ok(rs)) {
        u.errf("udhcpc: socket(AF_PACKET): {s}\n", .{u.strerr(u.errno(rs))});
        return 1;
    }
    const rfd: i32 = @intCast(rs);
    defer _ = linux.close(rfd);
    var me = SockLl{ .protocol = htons(0x0800), .ifindex = ifindex };
    _ = linux.bind(rfd, @ptrCast(&me), @sizeOf(SockLl));
    u.errf("udhcpc: started, {s}\n", .{VERSION});
    var arena = std.heap.ArenaAllocator.init(u.alloc);
    defer arena.deinit();
    runScript(script, "deconfig", iface, null);
    var cur: ?Lease = null;
    var bound_at: i64 = 0;
    var exit_code: u8 = 0;

    outer: while (!quit_flag) {
        // ---- discover / select
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const xid = rand32();
        var base = Msg{ .xid = xid };
        @memcpy(base.chaddr[0..6], &mac);
        if (bcast_flag) base.flags = 0x8000;
        var common = u.Vec(Opt).init(a);
        var cid = [_]u8{1} ++ mac;
        common.push(.{ .code = 61, .data = a.dupe(u8, &cid) catch &.{} });
        if (hostname) |h| common.push(.{ .code = 12, .data = h });
        common.push(.{ .code = 60, .data = vendor });
        common.push(.{ .code = 55, .data = &[_]u8{ 1, 3, 6, 12, 15, 26, 28, 42 } });
        var tried: u32 = 0;
        var offer: ?Msg = null;
        while (!quit_flag and offer == null) {
            if (tried >= tries) {
                runScript(script, "leasefail", iface, null);
                if (now_mode) {
                    u.err("udhcpc: no lease, failing\n");
                    exit_code = 1;
                    break :outer;
                }
                u.err("udhcpc: no lease, forking to background\n");
                var k: i64 = 0;
                while (k < tryagain_s and !quit_flag) : (k += 1) sleepS(1);
                tried = 0;
                continue :outer;
            }
            var ol = u.Vec(Opt).init(a);
            ol.push(.{ .code = 53, .data = &[_]u8{DISCOVER} });
            ol.pushSlice(common.items);
            if (req_ip) |r| ol.push(.{ .code = 50, .data = a.dupe(u8, &r) catch &.{} });
            var m = base;
            m.opts = ol.items;
            sendRaw(a, rfd, ifindex, mac, m);
            u.err("udhcpc: broadcasting discover\n");
            tried += 1;
            offer = waitFor(a, rfd, xid, OFFER, timeout_s);
        }
        if (quit_flag) break;
        const offered = offer.?;
        const server: [4]u8 = if (offered.get(54)) |s| (if (s.len == 4) s[0..4].* else .{ 0, 0, 0, 0 }) else .{ 0, 0, 0, 0 };
        // ---- request
        var got: ?Msg = null;
        var rtries: u32 = 0;
        while (!quit_flag and got == null and rtries < 3) : (rtries += 1) {
            var ol = u.Vec(Opt).init(a);
            ol.push(.{ .code = 53, .data = &[_]u8{REQUEST} });
            ol.pushSlice(common.items);
            ol.push(.{ .code = 50, .data = a.dupe(u8, &offered.yiaddr) catch &.{} });
            ol.push(.{ .code = 54, .data = a.dupe(u8, &server) catch &.{} });
            var m = base;
            m.opts = ol.items;
            sendRaw(a, rfd, ifindex, mac, m);
            u.errf("udhcpc: broadcasting select for {s}, server {s}\n", .{ fmt4(offered.yiaddr), fmt4(server) });
            const r = waitFor(a, rfd, xid, 0, timeout_s);
            if (r) |rm| {
                if (rm.msgType() == NAK) {
                    u.err("udhcpc: received DHCP NAK\n");
                    runScript(script, "nak", iface, null);
                    sleepS(3);
                    continue :outer;
                }
                if (rm.msgType() == ACK) got = rm;
            }
        }
        if (got == null) continue :outer;
        // ---- bound
        const ack = got.?;
        var secs: u32 = 3600;
        if (ack.get(51)) |lt| if (lt.len == 4) {
            secs = std.mem.readInt(u32, lt[0..4], .big);
        };
        const sid: [4]u8 = if (ack.get(54)) |s| (if (s.len == 4) s[0..4].* else server) else server;
        cur = .{ .ip = ack.yiaddr, .server = sid, .secs = secs, .msg = ack };
        // keep option data alive past the arena reset
        var keep = u.Vec(Opt).init(u.alloc);
        for (ack.opts) |o| keep.push(.{ .code = o.code, .data = u.alloc.dupe(u8, o.data) catch &.{} });
        cur.?.msg.opts = keep.items;
        u.errf("udhcpc: lease of {s} obtained from {s}, lease time {d}\n", .{ fmt4(ack.yiaddr), fmt4(sid), secs });
        runScript(script, "bound", iface, cur);
        bound_at = nowS();
        if (quit_after) break;
        // ---- renew loop
        const t1 = if (ack.get(58)) |t| (if (t.len == 4) std.mem.readInt(u32, t[0..4], .big) else secs / 2) else secs / 2;
        const t2 = if (ack.get(59)) |t| (if (t.len == 4) std.mem.readInt(u32, t[0..4], .big) else secs / 8 * 7) else secs / 8 * 7;
        var renewed = false;
        while (!quit_flag) {
            const el = nowS() - bound_at;
            if (el >= secs) {
                u.err("udhcpc: lease lost, entering init state\n");
                runScript(script, "deconfig", iface, null);
                cur = null;
                continue :outer;
            }
            if (el >= t1) {
                var ol = u.Vec(Opt).init(a);
                ol.push(.{ .code = 53, .data = &[_]u8{REQUEST} });
                ol.pushSlice(common.items);
                var m = base;
                m.xid = rand32();
                m.ciaddr = cur.?.ip;
                m.opts = ol.items;
                const unicast = el < t2;
                if (unicast) sendUdp(a, cur.?.ip, cur.?.server, iface, m) else sendRaw(a, rfd, ifindex, mac, m);
                u.errf("udhcpc: sending renew to {s}\n", .{fmt4(cur.?.server)});
                const r = if (unicast) waitUdp(a, cur.?.ip, iface, m.xid, 3) else waitFor(a, rfd, m.xid, 0, 3);
                if (r) |rm| if (rm.msgType() == ACK) {
                    secs = if (rm.get(51)) |lt| (if (lt.len == 4) std.mem.readInt(u32, lt[0..4], .big) else secs) else secs;
                    cur.?.secs = secs;
                    bound_at = nowS();
                    renewed = true;
                    u.errf("udhcpc: lease of {s} obtained from {s}, lease time {d}\n", .{ fmt4(rm.yiaddr), fmt4(cur.?.server), secs });
                    runScript(script, "renew", iface, cur);
                    continue :outer;
                } else if (rm.msgType() == NAK) {
                    runScript(script, "deconfig", iface, null);
                    cur = null;
                    continue :outer;
                };
                sleepS(@intCast(@min(@divTrunc(@as(i64, @intCast(@max(secs, 8))), 8), 60)));
                continue;
            }
            sleepS(1);
        }
    }
    _ = renewedDummy;
    if (release) if (cur) |l| {
        var a2 = std.heap.ArenaAllocator.init(u.alloc);
        defer a2.deinit();
        const a = a2.allocator();
        var m = Msg{ .xid = rand32() };
        @memcpy(m.chaddr[0..6], &mac);
        m.ciaddr = l.ip;
        var ol = u.Vec(Opt).init(a);
        ol.push(.{ .code = 53, .data = &[_]u8{RELEASE} });
        ol.push(.{ .code = 54, .data = a.dupe(u8, &l.server) catch &.{} });
        m.opts = ol.items;
        sendUdp(a, l.ip, l.server, iface, m);
        u.errf("udhcpc: unicasting a release of {s} to {s}\n", .{ fmt4(l.ip), fmt4(l.server) });
        runScript(script, "deconfig", iface, null);
    };
    if (pidfile) |pf| _ = linux.unlink(u.zstr(pf).ptr);
    return exit_code;
}

const renewedDummy: u8 = 0;

fn c_getuid() u32 {
    return linux.getuid();
}

fn sleepS(s: i64) void {
    var ts: linux.timespec = .{ .sec = @intCast(s), .nsec = 0 };
    _ = linux.nanosleep(&ts, null);
}

fn sendRaw(a: std.mem.Allocator, fd: i32, ifindex: i32, mac: [6]u8, m: Msg) void {
    _ = mac;
    const payload = buildMsg(a, m);
    const pkt = wrapUdp(a, .{ 0, 0, 0, 0 }, 68, .{ 255, 255, 255, 255 }, 67, payload);
    var to = SockLl{ .protocol = htons(0x0800), .ifindex = ifindex, .halen = 6 };
    @memset(to.addr[0..6], 0xff);
    _ = linux.sendto(fd, pkt.ptr, pkt.len, 0, @ptrCast(&to), @sizeOf(SockLl));
}

fn sendUdp(a: std.mem.Allocator, src: [4]u8, dst: [4]u8, iface: []const u8, m: Msg) void {
    const s = linux.socket(2, 2, 0);
    if (!u.ok(s)) return;
    const fd: i32 = @intCast(s);
    defer _ = linux.close(fd);
    const one: c_int = 1;
    _ = linux.setsockopt(fd, 1, 2, @ptrCast(&one), 4);
    _ = linux.setsockopt(fd, 1, 25, iface.ptr, @intCast(iface.len)); // SO_BINDTODEVICE
    var ba: linux.sockaddr.in = .{ .port = htons(68), .addr = @bitCast(src) };
    if (!u.ok(linux.bind(fd, @ptrCast(&ba), @sizeOf(linux.sockaddr.in)))) {
        // the address is not configured (yet): fall back to the wildcard address
        ba.addr = 0;
        _ = linux.bind(fd, @ptrCast(&ba), @sizeOf(linux.sockaddr.in));
    }
    var da: linux.sockaddr.in = .{ .port = htons(67), .addr = @bitCast(dst) };
    const payload = buildMsg(a, m);
    _ = linux.sendto(fd, payload.ptr, payload.len, 0, @ptrCast(&da), @sizeOf(linux.sockaddr.in));
}

fn waitUdp(a: std.mem.Allocator, src: [4]u8, iface: []const u8, xid: u32, timeout: i64) ?Msg {
    const s = linux.socket(2, 2, 0);
    if (!u.ok(s)) return null;
    const fd: i32 = @intCast(s);
    defer _ = linux.close(fd);
    const one: c_int = 1;
    _ = linux.setsockopt(fd, 1, 2, @ptrCast(&one), 4);
    _ = linux.setsockopt(fd, 1, 25, iface.ptr, @intCast(iface.len));
    var ba: linux.sockaddr.in = .{ .port = htons(68), .addr = @bitCast(src) };
    _ = linux.bind(fd, @ptrCast(&ba), @sizeOf(linux.sockaddr.in));
    const deadline = nowS() + timeout;
    while (nowS() < deadline) {
        var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        const pr = linux.poll(&pfd, 1, 500);
        if (!u.ok(pr) or pr == 0) continue;
        var buf: [1500]u8 = undefined;
        const r = linux.recvfrom(fd, &buf, buf.len, 0, null, null);
        if (!u.ok(r)) continue;
        const m = parseMsg(a, buf[0..r]) orelse continue;
        if (m.xid == xid and m.op == 2) return m;
    }
    return null;
}

/// wait for a reply with this xid; `want` 0 accepts ACK or NAK
fn waitFor(a: std.mem.Allocator, fd: i32, xid: u32, want: u8, timeout: i64) ?Msg {
    const deadline = nowS() + timeout;
    while (nowS() < deadline and !quit_flag) {
        var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        const pr = linux.poll(&pfd, 1, 500);
        if (!u.ok(pr) or pr == 0) continue;
        var buf: [2048]u8 = undefined;
        const r = linux.recvfrom(fd, &buf, buf.len, 0, null, null);
        if (!u.ok(r) or r < 28) continue;
        const ihl: usize = (buf[0] & 0xf) * 4;
        if (buf[9] != 17 or r < ihl + 8) continue;
        if (std.mem.readInt(u16, buf[ihl + 2 ..][0..2], .big) != 68) continue;
        const m = parseMsg(a, buf[ihl + 8 .. r]) orelse continue;
        if (m.xid != xid or m.op != 2) continue;
        const t = m.msgType();
        if (want == 0) {
            if (t == ACK or t == NAK) return m;
        } else if (t == want) return m;
    }
    return null;
}

// ---------------------------------------------------------------- udhcpd
const LeaseRec = struct { expires: i64, ip: [4]u8, mac: [6]u8, host: [20]u8 };

const Static = struct { mac: [6]u8, ip: [4]u8 };

const DCfg = struct {
    start: [4]u8 = .{ 192, 168, 0, 20 },
    end: [4]u8 = .{ 192, 168, 0, 254 },
    iface: []const u8 = "eth0",
    max_leases: usize = 254,
    lease_file: []const u8 = "/var/lib/misc/udhcpd.leases",
    pidfile: []const u8 = "/var/run/udhcpd.pid",
    opt_lease: u32 = 864000,
    offer_time: i64 = 60,
    decline_time: i64 = 3600,
    min_lease: u32 = 60,
    auto_time: i64 = 7200,
    siaddr: [4]u8 = .{ 0, 0, 0, 0 },
    boot_file: []const u8 = "",
    sname: []const u8 = "",
    opts: u.Vec(Opt),
    statics: u.Vec(Static),
};

fn parseMac(s: []const u8) ?[6]u8 {
    var m: [6]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, ':');
    var i: usize = 0;
    while (it.next()) |x| {
        if (i >= 6) return null;
        m[i] = std.fmt.parseInt(u8, x, 16) catch return null;
        i += 1;
    }
    return if (i == 6) m else null;
}

fn parseDCfg(path: []const u8) ?DCfg {
    var cfg = DCfg{ .opts = u.Vec(Opt).init(u.alloc), .statics = u.Vec(Static).init(u.alloc) };
    const data = mnt.readFile(path) orelse return null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |l0| {
        var l = l0;
        if (std.mem.indexOfScalar(u8, l, '#')) |h| l = l[0..h];
        l = std.mem.trim(u8, l, " \t\r");
        if (l.len == 0) continue;
        var it = std.mem.tokenizeAny(u8, l, " \t");
        const key = it.next() orelse continue;
        const val = std.mem.trim(u8, it.rest(), " \t");
        if (std.mem.eql(u8, key, "start")) cfg.start = ip4(val) orelse cfg.start else if (std.mem.eql(u8, key, "end")) cfg.end = ip4(val) orelse cfg.end else if (std.mem.eql(u8, key, "interface")) cfg.iface = u.alloc.dupe(u8, val) catch val else if (std.mem.eql(u8, key, "max_leases")) cfg.max_leases = std.fmt.parseInt(usize, val, 10) catch cfg.max_leases else if (std.mem.eql(u8, key, "lease_file") or std.mem.eql(u8, key, "lease_file")) cfg.lease_file = u.alloc.dupe(u8, val) catch val else if (std.mem.eql(u8, key, "pidfile")) cfg.pidfile = u.alloc.dupe(u8, val) catch val else if (std.mem.eql(u8, key, "opt_lease") or std.mem.eql(u8, key, "lease")) cfg.opt_lease = std.fmt.parseInt(u32, val, 10) catch cfg.opt_lease else if (std.mem.eql(u8, key, "offer_time")) cfg.offer_time = std.fmt.parseInt(i64, val, 10) catch cfg.offer_time else if (std.mem.eql(u8, key, "decline_time")) cfg.decline_time = std.fmt.parseInt(i64, val, 10) catch cfg.decline_time else if (std.mem.eql(u8, key, "min_lease")) cfg.min_lease = std.fmt.parseInt(u32, val, 10) catch cfg.min_lease else if (std.mem.eql(u8, key, "auto_time")) cfg.auto_time = std.fmt.parseInt(i64, val, 10) catch cfg.auto_time else if (std.mem.eql(u8, key, "siaddr")) cfg.siaddr = ip4(val) orelse cfg.siaddr else if (std.mem.eql(u8, key, "boot_file")) cfg.boot_file = u.alloc.dupe(u8, val) catch val else if (std.mem.eql(u8, key, "sname")) cfg.sname = u.alloc.dupe(u8, val) catch val else if (std.mem.eql(u8, key, "static_lease")) {
            var t2 = std.mem.tokenizeAny(u8, val, " \t");
            const mm = t2.next() orelse continue;
            const ii = t2.next() orelse continue;
            if (parseMac(mm)) |mac| if (ip4(ii)) |ip| cfg.statics.push(.{ .mac = mac, .ip = ip });
        } else if (std.mem.eql(u8, key, "option") or std.mem.eql(u8, key, "opt")) {
            var t2 = std.mem.tokenizeAny(u8, val, " \t");
            const name = t2.next() orelse continue;
            const rest = std.mem.trim(u8, t2.rest(), " \t");
            const OptDef = struct { n: []const u8, code: u8, kind: u8 }; // kind: 0 ip, 1 iplist, 2 string, 3 u32, 4 u16
            const defs = [_]OptDef{
                .{ .n = "subnet", .code = 1, .kind = 0 }, .{ .n = "timezone", .code = 2, .kind = 3 }, .{ .n = "router", .code = 3, .kind = 1 },
                .{ .n = "timesvr", .code = 4, .kind = 1 }, .{ .n = "namesvr", .code = 5, .kind = 1 }, .{ .n = "dns", .code = 6, .kind = 1 },
                .{ .n = "logsvr", .code = 7, .kind = 1 }, .{ .n = "hostname", .code = 12, .kind = 2 }, .{ .n = "domain", .code = 15, .kind = 2 },
                .{ .n = "mtu", .code = 26, .kind = 4 }, .{ .n = "broadcast", .code = 28, .kind = 0 }, .{ .n = "nisdomain", .code = 40, .kind = 2 },
                .{ .n = "ntpsrv", .code = 42, .kind = 1 }, .{ .n = "wins", .code = 44, .kind = 1 }, .{ .n = "lease", .code = 51, .kind = 3 },
                .{ .n = "tftp", .code = 66, .kind = 2 }, .{ .n = "bootfile", .code = 67, .kind = 2 }, .{ .n = "message", .code = 56, .kind = 2 },
            };
            for (defs) |d| if (std.mem.eql(u8, d.n, name)) {
                var buf = u.Vec(u8).init(u.alloc);
                switch (d.kind) {
                    0, 1 => {
                        var ti = std.mem.tokenizeAny(u8, rest, " \t,");
                        while (ti.next()) |x| if (ip4(x)) |ip| buf.pushSlice(&ip);
                    },
                    2 => buf.pushSlice(rest),
                    3 => {
                        var t4: [4]u8 = undefined;
                        std.mem.writeInt(u32, &t4, std.fmt.parseInt(u32, rest, 10) catch 0, .big);
                        buf.pushSlice(&t4);
                    },
                    else => {
                        var t2b: [2]u8 = undefined;
                        std.mem.writeInt(u16, &t2b, std.fmt.parseInt(u16, rest, 10) catch 0, .big);
                        buf.pushSlice(&t2b);
                    },
                }
                if (d.code == 51) {
                    cfg.opt_lease = if (buf.items.len == 4) std.mem.readInt(u32, buf.items[0..4], .big) else cfg.opt_lease;
                } else cfg.opts.push(.{ .code = d.code, .data = buf.items });
            };
        }
    }
    return cfg;
}

fn loadLeases(path: []const u8, out: *u.Vec(LeaseRec)) void {
    const d = mnt.readFile(path) orelse return;
    if (d.len < 8) return;
    const written: i64 = @intCast(std.mem.readInt(u64, d[0..8], .big));
    const elapsed = wallS() - written;
    var off: usize = 8;
    while (off + 36 <= d.len) : (off += 36) {
        const rem: i64 = std.mem.readInt(u32, d[off..][0..4], .big);
        const left = rem - elapsed;
        out.push(.{ .expires = wallS() + left, .ip = d[off + 4 ..][0..4].*, .mac = d[off + 8 ..][0..6].*, .host = d[off + 14 ..][0..20].* });
    }
}

fn saveLeases(path: []const u8, leases: []const LeaseRec) void {
    var o = u.Vec(u8).init(u.alloc);
    var t8: [8]u8 = undefined;
    std.mem.writeInt(u64, &t8, @intCast(wallS()), .big);
    o.pushSlice(&t8);
    for (leases) |l| {
        const left = l.expires - wallS();
        if (left <= 0) continue;
        var t4: [4]u8 = undefined;
        std.mem.writeInt(u32, &t4, @intCast(left), .big);
        o.pushSlice(&t4);
        o.pushSlice(&l.ip);
        o.pushSlice(&l.mac);
        o.pushSlice(&l.host);
        o.pushSlice(&[_]u8{ 0, 0 });
    }
    const rc = linux.open(u.zstr(path), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (!u.ok(rc)) return;
    _ = linux.write(@intCast(rc), o.items.ptr, o.items.len);
    _ = linux.close(@intCast(rc));
}

fn ipNum(a: [4]u8) u32 {
    return std.mem.readInt(u32, &a, .big);
}

fn numIp(n: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, n, .big);
    return b;
}

pub fn udhcpd(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "", .key = 'f' }, .{ .name = "", .key = 'S' }, .{ .name = "", .key = 'I', .arg = .req }, .{ .name = "", .key = 'a' },
    };
    var p = g.Parser.init("udhcpd", args, &opts);
    var foreground = false;
    var server_ip_arg: ?[4]u8 = null;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'f' => foreground = true,
            'I' => server_ip_arg = ip4(it.val.?),
            else => {},
        }
    }
    const conf = if (p.operands.items.len > 0) p.operands.items[0] else "/etc/udhcpd.conf";
    var cfg = parseDCfg(conf) orelse {
        u.errf("udhcpd: can't open '{s}': No such file or directory\n", .{conf});
        return 1;
    };
    const ctl = linux.socket(2, 2, 0);
    if (!u.ok(ctl)) return 1;
    const cfd: i32 = @intCast(ctl);
    var ifr: IfReq = undefined;
    if (!ifIoctl(cfd, 0x8915, cfg.iface, &ifr)) {
        u.errf("udhcpd: bad interface {s}\n", .{cfg.iface});
        return 1;
    }
    const server_ip: [4]u8 = server_ip_arg orelse ifr.data[4..8].*;
    var mask_ip: [4]u8 = .{ 255, 255, 255, 0 };
    if (ifIoctl(cfd, 0x891b, cfg.iface, &ifr)) mask_ip = ifr.data[4..8].*;
    _ = linux.close(cfd);
    if (!foreground) {
        const pid = linux.fork();
        if (!u.ok(pid)) return 1;
        if (pid != 0) return 0;
        _ = linux.setsid();
    }
    {
        const body = std.fmt.allocPrint(u.alloc, "{d}\n", .{linux.getpid()}) catch "";
        const rc = linux.open(u.zstr(cfg.pidfile), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        if (u.ok(rc)) {
            _ = linux.write(@intCast(rc), body.ptr, body.len);
            _ = linux.close(@intCast(rc));
        }
    }
    var leases = u.Vec(LeaseRec).init(u.alloc);
    loadLeases(cfg.lease_file, &leases);
    const s = linux.socket(2, 2, 0);
    if (!u.ok(s)) return 1;
    const fd: i32 = @intCast(s);
    const one: c_int = 1;
    _ = linux.setsockopt(fd, 1, 2, @ptrCast(&one), 4);
    _ = linux.setsockopt(fd, 1, 6, @ptrCast(&one), 4);
    _ = linux.setsockopt(fd, 1, 25, cfg.iface.ptr, @intCast(cfg.iface.len));
    var ba: linux.sockaddr.in = .{ .port = htons(67), .addr = 0 };
    if (!u.ok(linux.bind(fd, @ptrCast(&ba), @sizeOf(linux.sockaddr.in)))) {
        u.errf("udhcpd: bind: {s}\n", .{u.strerr(u.errno(linux.bind(fd, @ptrCast(&ba), @sizeOf(linux.sockaddr.in))))});
        return 1;
    }
    var act = linux.Sigaction{ .handler = .{ .handler = onSig }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(linux.SIG.TERM, &act, null);
    _ = linux.sigaction(linux.SIG.INT, &act, null);
    var last_save = wallS();
    var offers = u.Vec(struct { mac: [6]u8, ip: [4]u8, until: i64 }).init(u.alloc);
    if (cfg.max_leases == 0) cfg.max_leases = 1;
    while (!quit_flag) {
        var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        const pr = linux.poll(&pfd, 1, 1000);
        if (wallS() - last_save >= cfg.auto_time) {
            saveLeases(cfg.lease_file, leases.items);
            last_save = wallS();
        }
        if (!u.ok(pr) or pr == 0) continue;
        var buf: [2048]u8 = undefined;
        var from: linux.sockaddr.in = undefined;
        var fl: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        const r = linux.recvfrom(fd, &buf, buf.len, 0, @ptrCast(&from), &fl);
        if (!u.ok(r)) continue;
        var arena = std.heap.ArenaAllocator.init(u.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const m = parseMsg(a, buf[0..r]) orelse continue;
        if (m.op != 1 or m.hlen != 6) continue;
        const cmac: [6]u8 = m.chaddr[0..6].*;
        const mt = m.msgType();
        const now = wallS();
        // expire old leases/offers
        var k: usize = 0;
        while (k < leases.items.len) {
            if (leases.items[k].expires <= now) {
                leaseRemove(&leases, k);
                continue;
            }
            k += 1;
        }
        if (mt == DISCOVER or mt == REQUEST) {
            // choose an address
            var ip: ?[4]u8 = null;
            for (cfg.statics.items) |st| if (std.mem.eql(u8, &st.mac, &cmac)) {
                ip = st.ip;
            };
            if (ip == null) for (leases.items) |l| if (std.mem.eql(u8, &l.mac, &cmac)) {
                ip = l.ip;
            };
            if (mt == REQUEST) {
                if (m.get(54)) |sid| if (sid.len == 4 and !std.mem.eql(u8, sid[0..4], &server_ip)) continue;
                var want: ?[4]u8 = null;
                if (m.get(50)) |ri| if (ri.len == 4) {
                    want = ri[0..4].*;
                };
                if (!std.mem.eql(u8, &m.ciaddr, &[4]u8{ 0, 0, 0, 0 })) want = m.ciaddr;
                if (want != null and ip != null and !std.mem.eql(u8, &want.?, &ip.?)) {
                    sendReply(fd, a, NAK, m, .{ 0, 0, 0, 0 }, server_ip, mask_ip, &cfg, 0, null);
                    continue;
                }
                if (ip == null and want != null) {
                    const n = ipNum(want.?);
                    if (n >= ipNum(cfg.start) and n <= ipNum(cfg.end) and !leasedTo(&leases, want.?, cmac)) ip = want;
                }
                if (ip == null) {
                    sendReply(fd, a, NAK, m, .{ 0, 0, 0, 0 }, server_ip, mask_ip, &cfg, 0, null);
                    continue;
                }
            } else if (ip == null) {
                // first free address, honouring a requested one
                if (m.get(50)) |ri| if (ri.len == 4) {
                    const n = ipNum(ri[0..4].*);
                    if (n >= ipNum(cfg.start) and n <= ipNum(cfg.end) and !leasedTo(&leases, ri[0..4].*, cmac) and !offeredTo(&offers, ri[0..4].*, cmac, now)) ip = ri[0..4].*;
                };
                var n = ipNum(cfg.start);
                while (ip == null and n <= ipNum(cfg.end) and (n - ipNum(cfg.start)) < cfg.max_leases) : (n += 1) {
                    const cand = numIp(n);
                    if (std.mem.eql(u8, &cand, &server_ip)) continue;
                    if (!leasedTo(&leases, cand, cmac) and !offeredTo(&offers, cand, cmac, now)) ip = cand;
                }
            }
            const yi = ip orelse continue;
            var lease_secs = cfg.opt_lease;
            if (m.get(51)) |rl| if (rl.len == 4) {
                const rv = std.mem.readInt(u32, rl[0..4], .big);
                if (rv < lease_secs) lease_secs = rv;
            };
            if (lease_secs < cfg.min_lease) lease_secs = cfg.min_lease;
            if (mt == DISCOVER) {
                offers.push(.{ .mac = cmac, .ip = yi, .until = now + cfg.offer_time });
                sendReply(fd, a, OFFER, m, yi, server_ip, mask_ip, &cfg, lease_secs, null);
            } else {
                var host: [20]u8 = @splat(0);
                if (m.get(12)) |hn| @memcpy(host[0..@min(hn.len, 19)], hn[0..@min(hn.len, 19)]);
                var found = false;
                for (leases.items) |*l| if (std.mem.eql(u8, &l.mac, &cmac)) {
                    l.ip = yi;
                    l.expires = now + lease_secs;
                    l.host = host;
                    found = true;
                };
                if (!found) leases.push(.{ .expires = now + lease_secs, .ip = yi, .mac = cmac, .host = host });
                sendReply(fd, a, ACK, m, yi, server_ip, mask_ip, &cfg, lease_secs, null);
                saveLeases(cfg.lease_file, leases.items);
            }
        } else if (mt == RELEASE) {
            var j: usize = 0;
            while (j < leases.items.len) {
                if (std.mem.eql(u8, &leases.items[j].mac, &cmac)) {
                    leaseRemove(&leases, j);
                    continue;
                }
                j += 1;
            }
            saveLeases(cfg.lease_file, leases.items);
        } else if (mt == 4) {
            // DECLINE: keep the address out of circulation
            if (m.get(50)) |ri| if (ri.len == 4) leases.push(.{ .expires = now + cfg.decline_time, .ip = ri[0..4].*, .mac = @splat(0), .host = @splat(0) });
        }
    }
    saveLeases(cfg.lease_file, leases.items);
    _ = linux.unlink(u.zstr(cfg.pidfile).ptr);
    return 0;
}

fn leaseRemove(v: *u.Vec(LeaseRec), i: usize) void {
    std.mem.copyForwards(LeaseRec, v.items[i .. v.items.len - 1], v.items[i + 1 ..]);
    v.items.len -= 1;
}

fn leasedTo(leases: *u.Vec(LeaseRec), ip: [4]u8, mac: [6]u8) bool {
    for (leases.items) |l| if (std.mem.eql(u8, &l.ip, &ip) and !std.mem.eql(u8, &l.mac, &mac)) return true;
    return false;
}

fn offeredTo(offers: anytype, ip: [4]u8, mac: [6]u8, now: i64) bool {
    for (offers.items) |o| if (o.until > now and std.mem.eql(u8, &o.ip, &ip) and !std.mem.eql(u8, &o.mac, &mac)) return true;
    return false;
}

fn sendReply(fd: i32, a: std.mem.Allocator, typ: u8, req: Msg, yi: [4]u8, server: [4]u8, mask: [4]u8, cfg: *const DCfg, lease: u32, _: ?u8) void {
    var m = Msg{ .op = 2, .xid = req.xid, .flags = req.flags, .giaddr = req.giaddr, .chaddr = req.chaddr, .yiaddr = yi, .siaddr = cfg.siaddr };
    m.ciaddr = if (typ == ACK) req.ciaddr else .{ 0, 0, 0, 0 };
    if (cfg.sname.len > 0) @memcpy(m.sname[0..@min(cfg.sname.len, 63)], cfg.sname[0..@min(cfg.sname.len, 63)]);
    if (cfg.boot_file.len > 0) @memcpy(m.file[0..@min(cfg.boot_file.len, 127)], cfg.boot_file[0..@min(cfg.boot_file.len, 127)]);
    var ol = u.Vec(Opt).init(a);
    ol.push(.{ .code = 53, .data = a.dupe(u8, &[_]u8{typ}) catch &.{} });
    ol.push(.{ .code = 54, .data = a.dupe(u8, &server) catch &.{} });
    if (typ != NAK) {
        var lt: [4]u8 = undefined;
        std.mem.writeInt(u32, &lt, lease, .big);
        ol.push(.{ .code = 51, .data = a.dupe(u8, &lt) catch &.{} });
        var have_subnet = false;
        for (cfg.opts.items) |o| if (o.code == 1) {
            have_subnet = true;
        };
        if (!have_subnet) ol.push(.{ .code = 1, .data = a.dupe(u8, &mask) catch &.{} });
        for (cfg.opts.items) |o| ol.push(o);
        var t1: [4]u8 = undefined;
        std.mem.writeInt(u32, &t1, lease / 2, .big);
        ol.push(.{ .code = 58, .data = a.dupe(u8, &t1) catch &.{} });
        std.mem.writeInt(u32, &t1, lease / 8 * 7, .big);
        ol.push(.{ .code = 59, .data = a.dupe(u8, &t1) catch &.{} });
    }
    m.opts = ol.items;
    const payload = buildMsg(a, m);
    var da: linux.sockaddr.in = .{ .port = htons(if (!std.mem.eql(u8, &req.giaddr, &[4]u8{ 0, 0, 0, 0 })) 67 else 68), .addr = @bitCast([4]u8{ 255, 255, 255, 255 }) };
    if (!std.mem.eql(u8, &req.giaddr, &[4]u8{ 0, 0, 0, 0 })) da.addr = @bitCast(req.giaddr);
    _ = linux.sendto(fd, payload.ptr, payload.len, 0, @ptrCast(&da), @sizeOf(linux.sockaddr.in));
}

// ---------------------------------------------------------------- dumpleases
pub fn dumpleases(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "file", .key = 'f', .arg = .req }, .{ .name = "absolute", .key = 'a' }, .{ .name = "remaining", .key = 'r' },
    };
    var p = g.Parser.init("dumpleases", args, &opts);
    var file: []const u8 = "/var/lib/misc/udhcpd.leases";
    var absolute = false;
    while (p.next() catch {
        u.err("Usage: dumpleases [-r|-a] [-f LEASEFILE]\n\nDisplay DHCP leases granted by udhcpd\n\n\t-f,--file=FILE\tLeases file\n\t-r,--remaining\tInterpret lease times as time remaining\n\t-a,--absolute\tInterpret lease times as expire time\n");
        return 1;
    }) |it| {
        switch (it.key) {
            'f' => file = it.val.?,
            'a' => absolute = true,
            'r' => absolute = false,
            else => {},
        }
    }
    const d = mnt.readFile(file) orelse {
        u.errf("dumpleases: can't open '{s}': No such file or directory\n", .{file});
        return 1;
    };
    if (d.len < 8) return 0;
    const written: i64 = @intCast(std.mem.readInt(u64, d[0..8], .big));
    u.outf("Mac Address       IP Address      Host Name           Expires {s}\n", .{if (absolute) "at" else "in"});
    var off: usize = 8;
    while (off + 36 <= d.len) : (off += 36) {
        const rem: i64 = std.mem.readInt(u32, d[off..][0..4], .big);
        const mac = d[off + 8 ..][0..6];
        const ip = d[off + 4 ..][0..4].*;
        const host = std.mem.sliceTo(d[off + 14 ..][0..20], 0);
        var line = u.Vec(u8).init(u.alloc);
        line.pushSlice(std.fmt.allocPrint(u.alloc, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} {s: <15} {s: <20} ", .{ mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], fmt4(ip), host }) catch "");
        if (absolute) {
            const when = written + rem;
            line.pushSlice(ctimeStr(when));
        } else {
            const left = rem - (wallS() - written);
            if (left <= 0) line.pushSlice("expired") else {
                const dd = @divTrunc(left, 86400);
                if (dd > 0) line.pushSlice(std.fmt.allocPrint(u.alloc, "{d} days ", .{dd}) catch "");
                line.pushSlice(std.fmt.allocPrint(u.alloc, "{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(@divTrunc(@mod(left, 86400), 3600))), @as(u64, @intCast(@divTrunc(@mod(left, 3600), 60))), @as(u64, @intCast(@mod(left, 60))) }) catch "");
            }
        }
        line.push('\n');
        u.out(line.items);
    }
    return 0;
}

const ct = @cImport({
    @cInclude("time.h");
});

fn ctimeStr(t: i64) []const u8 {
    var tt: ct.time_t = @intCast(t);
    var tmv: ct.struct_tm = undefined;
    _ = ct.localtime_r(&tt, &tmv);
    var buf: [64]u8 = undefined;
    const n = ct.strftime(&buf, buf.len, "%a %b %e %H:%M:%S %Y", &tmv);
    return u.alloc.dupe(u8, buf[0..n]) catch "";
}

// ---------------------------------------------------------------- dhcprelay
pub fn dhcprelay(args: []const []const u8) u8 {
    if (args.len < 2 or args.len > 3) {
        u.err("Usage: dhcprelay CLIENT_IFACE[,CLIENT_IFACE2]... SERVER_IFACE [SERVER_IP]\n");
        return 1;
    }
    var clients = u.Vec([]const u8).init(u.alloc);
    var it = std.mem.splitScalar(u8, args[0], ',');
    while (it.next()) |c0| clients.push(c0);
    const srv_if = args[1];
    var srv_ip: [4]u8 = .{ 255, 255, 255, 255 };
    if (args.len == 3) srv_ip = ip4(args[2]) orelse {
        u.errf("dhcprelay: bad server address {s}\n", .{args[2]});
        return 1;
    };
    const cfd0 = linux.socket(2, 2, 0);
    if (!u.ok(cfd0)) return 1;
    const cfd: i32 = @intCast(cfd0);
    var ifr: IfReq = undefined;
    // giaddr is the address of the first client interface
    if (!ifIoctl(cfd, 0x8915, clients.items[0], &ifr)) {
        u.errf("dhcprelay: bad interface {s}\n", .{clients.items[0]});
        return 1;
    }
    const giaddr: [4]u8 = ifr.data[4..8].*;
    _ = linux.close(cfd);
    const s = linux.socket(2, 2, 0);
    if (!u.ok(s)) return 1;
    const fd: i32 = @intCast(s);
    const one: c_int = 1;
    _ = linux.setsockopt(fd, 1, 2, @ptrCast(&one), 4);
    _ = linux.setsockopt(fd, 1, 6, @ptrCast(&one), 4);
    var ba: linux.sockaddr.in = .{ .port = htons(67), .addr = 0 };
    if (!u.ok(linux.bind(fd, @ptrCast(&ba), @sizeOf(linux.sockaddr.in)))) {
        u.err("dhcprelay: bind failed\n");
        return 1;
    }
    _ = srv_if;
    var act = linux.Sigaction{ .handler = .{ .handler = onSig }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(linux.SIG.TERM, &act, null);
    _ = linux.sigaction(linux.SIG.INT, &act, null);
    while (!quit_flag) {
        var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        const pr = linux.poll(&pfd, 1, 1000);
        if (!u.ok(pr) or pr == 0) continue;
        var buf: [2048]u8 = undefined;
        var from: linux.sockaddr.in = undefined;
        var fl: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        const r = linux.recvfrom(fd, &buf, buf.len, 0, @ptrCast(&from), &fl);
        if (!u.ok(r) or r < 240) continue;
        if (buf[0] == 1) {
            // client -> server: stamp giaddr and forward
            if (std.mem.eql(u8, buf[24..28], &[4]u8{ 0, 0, 0, 0 })) @memcpy(buf[24..28], &giaddr);
            buf[3] +%= 1;
            var da: linux.sockaddr.in = .{ .port = htons(67), .addr = @bitCast(srv_ip) };
            _ = linux.sendto(fd, &buf, r, 0, @ptrCast(&da), @sizeOf(linux.sockaddr.in));
        } else if (buf[0] == 2) {
            // server -> client: hand the reply to the client network
            var da: linux.sockaddr.in = .{ .port = htons(68), .addr = @bitCast([4]u8{ 255, 255, 255, 255 }) };
            _ = linux.sendto(fd, &buf, r, 0, @ptrCast(&da), @sizeOf(linux.sockaddr.in));
        }
    }
    return 0;
}
