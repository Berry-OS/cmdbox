// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// net.zig - network applets (no libc, raw syscalls)
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");

const out = u.out;
const outf = u.outf;
const errf = u.errf;

const AF_INET: u32 = 2;
const SOCK_STREAM: u32 = 1;
const SOCK_DGRAM: u32 = 2;
const SOCK_RAW: u32 = 3;
const IPPROTO_ICMP: u32 = 1;
const SOL_SOCKET: i32 = 1;
const SO_RCVTIMEO: u32 = 20;
const SO_SNDTIMEO: u32 = 21;

const SIOCGIFCONF: u32 = 0x8912;
const SIOCGIFFLAGS: u32 = 0x8913;
const SIOCSIFFLAGS: u32 = 0x8914;
const SIOCGIFADDR: u32 = 0x8915;
const SIOCSIFADDR: u32 = 0x8916;
const SIOCGIFBRDADDR: u32 = 0x8919;
const SIOCGIFNETMASK: u32 = 0x891b;
const SIOCSIFNETMASK: u32 = 0x891c;
const SIOCGIFHWADDR: u32 = 0x8927;
const SIOCGIFMTU: u32 = 0x8921;

const IFF_UP: u16 = 0x1;
const IFF_BROADCAST: u16 = 0x2;
const IFF_LOOPBACK: u16 = 0x8;
const IFF_RUNNING: u16 = 0x40;
const IFF_MULTICAST: u16 = 0x1000;

const SockaddrIn = extern struct {
    family: u16 = AF_INET,
    port: u16 = 0, // big endian
    addr: u32 = 0, // big endian
    zero: [8]u8 = @splat(0),
};

const Sockaddr = extern struct {
    family: u16 = 0,
    data: [14]u8 = @splat(0),
};

const IFREQ = extern struct {
    name: [16]u8 = @splat(0),
    data: [16]u8 = @splat(0),
};

const IFCONF = extern struct {
    len: i32,
    buf: ?[*]u8,
};

// ---------- ip helpers ----------
pub fn parseIp(s: []const u8) ?u32 {
    var parts: [4]u16 = @splat(0);
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, s, '.');
    while (it.next()) |p| {
        if (n >= 4) return null;
        const v = u.toInt(p) orelse return null;
        if (v < 0 or v > 255) return null;
        parts[n] = @intCast(v);
        n += 1;
    }
    if (n != 4) return null;
    return (@as(u32, parts[0]) << 24) | (@as(u32, parts[1]) << 16) | (@as(u32, parts[2]) << 8) | parts[3];
}

pub fn ipStr(ip: u32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip >> 24 & 0xff, ip >> 16 & 0xff, ip >> 8 & 0xff, ip & 0xff }) catch "?";
}

fn htons(v: u16) u16 {
    return std.mem.nativeToBig(u16, v);
}

// ---------- DNS ----------
pub fn readResolver(buf: []u8) ?[]const u8 {
    var f = u.File.open("/etc/resolv.conf", .{ .ACCMODE = .RDONLY }, 0) orelse return null;
    defer f.close();
    var line: [256]u8 = undefined;
    while (u.readLine(&f, &line)) |l| {
        if (std.mem.startsWith(u8, l, "nameserver")) {
            var it = std.mem.tokenizeScalar(u8, l[10..], ' ');
            if (it.next()) |ns| {
                const n = @min(ns.len, buf.len);
                @memcpy(buf[0..n], ns[0..n]);
                return buf[0..n];
            }
        }
    }
    return null;
}

const DnsHeader = extern struct {
    id: u16,
    flags: u16,
    qd: u16,
    an: u16,
    ns: u16,
    ar: u16,
};

/// send A query, collect A record addresses (up to max)
pub fn dnsQuery(name: []const u8, server: u32, out_addrs: []u32) usize {
    var pkt: [512]u8 = undefined;
    var n: usize = 0;
    const hdr: *DnsHeader = @ptrCast(@alignCast(&pkt));
    hdr.id = htons(@intCast(linux.getpid() & 0xffff));
    hdr.flags = htons(0x0100); // recursion desired
    hdr.qd = htons(1);
    hdr.an = 0;
    hdr.ns = 0;
    hdr.ar = 0;
    n = @sizeOf(DnsHeader);
    // qname labels
    var it = std.mem.tokenizeScalar(u8, name, '.');
    while (it.next()) |label| {
        if (label.len == 0 or label.len > 63) return 0;
        pkt[n] = @intCast(label.len);
        n += 1;
        @memcpy(pkt[n .. n + label.len], label);
        n += label.len;
    }
    pkt[n] = 0;
    n += 1;
    // qtype A, qclass IN
    pkt[n] = 0;
    pkt[n + 1] = 1;
    pkt[n + 2] = 0;
    pkt[n + 3] = 1;
    n += 4;

    const fd_raw = linux.socket(AF_INET, SOCK_DGRAM, 17); // UDP
    if (!u.ok(fd_raw)) return 0;
    const fd: i32 = @intCast(fd_raw);
    defer _ = linux.close(fd);
    // timeout 3s
    const tv = linux.timeval{ .sec = 3, .usec = 0 };
    _ = linux.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval));

    var sa = SockaddrIn{ .port = htons(53), .addr = @byteSwap(server) };
    // addr stored host-byte-order-value; we need network order: byteSwap of the
    // "0xAABBCCDD as dotted" representation gives correct memory layout
    const sent = linux.sendto(fd, &pkt, n, 0, @ptrCast(&sa), @sizeOf(SockaddrIn));
    if (!u.ok(sent)) return 0;

    var resp: [1024]u8 = undefined;
    var alen: u32 = @sizeOf(SockaddrIn);
    var sa2 = SockaddrIn{};
    const got = linux.recvfrom(fd, &resp, resp.len, 0, @ptrCast(&sa2), &alen);
    if (!u.ok(got)) return 0;
    const rlen: usize = @intCast(got);
    if (rlen < @sizeOf(DnsHeader)) return 0;

    const rhdr: *const DnsHeader = @ptrCast(@alignCast(&resp));
    const ancount = std.mem.bigToNative(u16, rhdr.an);
    if (ancount == 0) return 0;

    // skip question
    var p: usize = @sizeOf(DnsHeader);
    while (p < rlen and resp[p] != 0) p += resp[p] + 1;
    p += 5; // null + qtype + qclass

    var count: usize = 0;
    var ai: usize = 0;
    while (ai < ancount and p + 12 <= rlen) : (ai += 1) {
        // name (may be pointer)
        if (resp[p] & 0xc0 == 0xc0) {
            p += 2;
        } else {
            while (p < rlen and resp[p] != 0) p += resp[p] + 1;
            p += 1;
        }
        if (p + 10 > rlen) break;
        const atype = std.mem.bigToNative(u16, @as(u16, @as(u16, resp[p]) << 8 | resp[p + 1]));
        const rdlen = @as(u16, resp[p + 8]) << 8 | resp[p + 9];
        p += 10;
        if (atype == 1 and rdlen == 4 and p + 4 <= rlen and count < out_addrs.len) {
            out_addrs[count] = @as(u32, resp[p]) << 24 | @as(u32, resp[p + 1]) << 16 | @as(u32, resp[p + 2]) << 8 | resp[p + 3];
            count += 1;
        }
        p += rdlen;
    }
    return count;
}

pub fn resolveHost(name: []const u8) ?u32 {
    if (parseIp(name)) |ip| return ip;
    var nsbuf: [64]u8 = undefined;
    const ns = readResolver(&nsbuf) orelse return null;
    const server = parseIp(ns) orelse return null;
    var addrs: [8]u32 = undefined;
    const n = dnsQuery(name, server, &addrs);
    if (n == 0) return null;
    return addrs[0];
}

// ---------- ping ----------
fn icmpChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += @as(u32, data[i]) << 8 | data[i + 1];
    }
    if (data.len % 2 == 1) sum += @as(u32, data[data.len - 1]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @intCast(~sum & 0xffff);
}

pub fn ping(args: []const []const u8) u8 {
    var count: i64 = 4;
    var host: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-c") and i + 1 < args.len) {
            count = u.toInt(args[i + 1]) orelse 4;
            i += 1;
        } else if (arg.len > 2 and arg[0] == '-' and arg[1] == 'c') {
            count = u.toInt(arg[2..]) orelse 4;
        } else if (arg.len > 1 and arg[0] == '-') {
            // ignored
        } else if (host == null) {
            host = arg;
        }
    }
    const h = host orelse {
        errf("ping: missing host\n", .{});
        return 1;
    };
    const ip = resolveHost(h) orelse {
        errf("ping: bad address '{s}'\n", .{h});
        return 2;
    };
    var ipbuf: [16]u8 = undefined;
    const ipstr = ipStr(ip, &ipbuf);
    outf("PING {s} ({s}): 56 data bytes\n", .{ h, ipstr });

    const fd_raw = linux.socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
    if (!u.ok(fd_raw)) {
        errf("ping: cannot open raw socket (need root)\n", .{});
        return 2;
    }
    const fd: i32 = @intCast(fd_raw);
    defer _ = linux.close(fd);
    const tv = linux.timeval{ .sec = 2, .usec = 0 };
    _ = linux.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval));

    var sa = SockaddrIn{ .port = 0, .addr = @byteSwap(ip) };
    const ident: u16 = @intCast(linux.getpid() & 0xffff);
    var sent: i64 = 0;
    var received: i64 = 0;
    var rtt_min: f64 = 1e9;
    var rtt_max: f64 = 0;
    var rtt_sum: f64 = 0;

    var seq: u16 = 0;
    while (seq < count) : (seq += 1) {
        var pkt: [64]u8 = undefined;
        pkt[0] = 8; // echo request
        pkt[1] = 0;
        pkt[2] = 0;
        pkt[3] = 0;
        pkt[4] = @intCast(ident >> 8);
        pkt[5] = @intCast(ident & 0xff);
        pkt[6] = @intCast(seq >> 8);
        pkt[7] = @intCast(seq & 0xff);
        for (8..64) |k| pkt[k] = 'a' + @as(u8, @intCast(k % 26));
        const csum = icmpChecksum(&pkt);
        pkt[2] = @intCast(csum >> 8);
        pkt[3] = @intCast(csum & 0xff);
        const rc = linux.sendto(fd, &pkt, pkt.len, 0, @ptrCast(&sa), @sizeOf(SockaddrIn));
        if (!u.ok(rc)) {
            errf("ping: sendto: {s}\n", .{u.strerr(u.errno(rc))});
            continue;
        }
        sent += 1;
        const t0 = u.nowMonoNanos();
        var got_reply = false;
        while (!got_reply) {
            var rbuf: [512]u8 = undefined;
            var alen: u32 = @sizeOf(SockaddrIn);
            var from = SockaddrIn{};
            const rr = linux.recvfrom(fd, &rbuf, rbuf.len, 0, @ptrCast(&from), &alen);
            const e = u.errno(rr);
            if (e != .SUCCESS) {
                if (e == .INTR) continue;
                break; // timeout
            }
            const rlen: usize = @intCast(rr);
            if (rlen < 20 + 8) break;
            const ihl: usize = @as(usize, rbuf[0] & 0xf) * 4;
            if (rlen < ihl + 8) continue;
            if (rbuf[ihl] != 0) continue; // not echo reply
            const rid = @as(u16, rbuf[ihl + 4]) << 8 | rbuf[ihl + 5];
            const rseq = @as(u16, rbuf[ihl + 6]) << 8 | rbuf[ihl + 7];
            if (rid != ident or rseq != seq) continue;
            const dt: f64 = @as(f64, @floatFromInt(u.nowMonoNanos() - t0)) / 1_000_000.0;
            const fromip = std.mem.bigToNative(u32, from.addr);
            var fb: [16]u8 = undefined;
            outf("64 bytes from {s}: icmp_seq={d} ttl={d} time={d:.1} ms\n", .{ ipStr(fromip, &fb), seq, rbuf[8], dt });
            received += 1;
            rtt_sum += dt;
            if (dt < rtt_min) rtt_min = dt;
            if (dt > rtt_max) rtt_max = dt;
            got_reply = true;
        }
        if (!got_reply) {
            errf("Request timeout for icmp_seq {d}\n", .{seq});
        }
        if (seq + 1 < count) {
            sleepOne();
        }
    }
    const loss = if (sent > 0) @divFloor((sent - received) * 100, sent) else 0;
    outf("\n--- {s} ping statistics ---\n", .{h});
    outf("{d} packets transmitted, {d} packets received, {d}% packet loss\n", .{ sent, received, loss });
    if (received > 0) {
        const avg = rtt_sum / @as(f64, @floatFromInt(received));
        outf("round-trip min/avg/max = {d:.1}/{d:.1}/{d:.1} ms\n", .{ rtt_min, avg, rtt_max });
    }
    return if (received > 0) 0 else 1;
}

fn sleepOne() void {
    const req = linux.timespec{ .sec = 1, .nsec = 0 };
    var rem: linux.timespec = undefined;
    _ = linux.nanosleep(&req, &rem);
}

// ---------- wget ----------
pub const wget = @import("wget.zig").run;

// ---------- nslookup ----------
pub fn nslookup(args: []const []const u8) u8 {
    var rest = u.Vec([]const u8).init(u.alloc);
    for (args) |arg| {
        if (arg.len > 1 and arg[0] == '-') continue;
        rest.push(arg);
    }
    if (rest.items.len == 0) {
        errf("usage: nslookup NAME [SERVER]\n", .{});
        return 1;
    }
    var server: u32 = 0;
    if (rest.items.len > 1) {
        server = parseIp(rest.items[1]) orelse (resolveHost(rest.items[1]) orelse {
            errf("nslookup: cannot resolve server\n", .{});
            return 1;
        });
    } else {
        var nsbuf: [64]u8 = undefined;
        const ns = readResolver(&nsbuf) orelse {
            errf("nslookup: no nameserver in /etc/resolv.conf\n", .{});
            return 1;
        };
        server = parseIp(ns) orelse {
            errf("nslookup: bad nameserver\n", .{});
            return 1;
        };
    }
    var sbuf: [16]u8 = undefined;
    outf("Server:\t{s}\n", .{ipStr(server, &sbuf)});
    var addrs: [8]u32 = undefined;
    const n = dnsQuery(rest.items[0], server, &addrs);
    if (n == 0) {
        outf("Name:      {s}\n** can't find {s}: No answer\n", .{ rest.items[0], rest.items[0] });
        return 1;
    }
    outf("Name:      {s}\n", .{rest.items[0]});
    for (addrs[0..n], 1..) |a, k| {
        var ab: [16]u8 = undefined;
        outf("Address {d}: {s}\n", .{ k, ipStr(a, &ab) });
    }
    return 0;
}

// ---------- ifconfig ----------
pub fn ifconfig(args: []const []const u8) u8 {
    var all = false;
    var rest = u.Vec([]const u8).init(u.alloc);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-a")) {
            all = true;
            continue;
        }
        if (arg.len > 1 and arg[0] == '-') continue;
        rest.push(arg);
    }
    if (rest.items.len == 0) {
        return showIfaces(all);
    }
    const iface = rest.items[0];
    if (rest.items.len == 1) return showIface(iface);
    return setIface(iface, rest.items[1..]);
}

fn sockIoctl(req: u32, ifr: *IFREQ) bool {
    const fd_raw = linux.socket(AF_INET, SOCK_DGRAM, 0);
    if (!u.ok(fd_raw)) return false;
    const fd: i32 = @intCast(fd_raw);
    defer _ = linux.close(fd);
    return u.ok(linux.ioctl(fd, req, @intFromPtr(ifr)));
}

fn showIfaces(all: bool) u8 {
    var f = u.File.open("/proc/net/dev", .{ .ACCMODE = .RDONLY }, 0) orelse return 1;
    defer f.close();
    var line: [512]u8 = undefined;
    var skip2 = true;
    var fail = false;
    while (u.readLine(&f, &line)) |l| {
        if (skip2) {
            skip2 = false;
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        const name = std.mem.trim(u8, l[0..colon], " ");
        // check flags
        var ifr = IFREQ{};
        @memcpy(ifr.name[0..@min(name.len, 16)], name[0..@min(name.len, 16)]);
        if (!sockIoctl(SIOCGIFFLAGS, &ifr)) {
            fail = true;
            continue;
        }
        const flags = std.mem.readInt(u16, ifr.data[0..2], .little);
        if (!all and flags & IFF_UP == 0) continue;
        showIfaceFull(name, flags, l[colon + 1 ..]);
    }
    return if (fail) 1 else 0;
}

fn showIface(name: []const u8) u8 {
    var ifr = IFREQ{};
    @memcpy(ifr.name[0..@min(name.len, 16)], name[0..@min(name.len, 16)]);
    if (!sockIoctl(SIOCGIFFLAGS, &ifr)) {
        errf("ifconfig: {s}: {s}\n", .{ name, "No such device" });
        return 1;
    }
    const flags = std.mem.readInt(u16, ifr.data[0..2], .little);
    var stats: []const u8 = "";
    var f = u.File.open("/proc/net/dev", .{ .ACCMODE = .RDONLY }, 0) orelse return 1;
    defer f.close();
    var line: [512]u8 = undefined;
    while (u.readLine(&f, &line)) |l| {
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        const nm = std.mem.trim(u8, l[0..colon], " ");
        if (std.mem.eql(u8, nm, name)) {
            stats = l[colon + 1 ..];
            break;
        }
    }
    showIfaceFull(name, flags, stats);
    return 0;
}

fn showIfaceFull(name: []const u8, flags: u16, stats: []const u8) void {
    outf("{s: <10}", .{name});
    if (flags & IFF_LOOPBACK != 0) {
        out("Link encap:Local Loopback\n");
    } else {
        out("Link encap:Ethernet  ");
        var ifr = IFREQ{};
        @memcpy(ifr.name[0..@min(name.len, 16)], name[0..@min(name.len, 16)]);
        if (sockIoctl(SIOCGIFHWADDR, &ifr)) {
            outf("HWaddr {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}\n", .{ ifr.data[0], ifr.data[1], ifr.data[2], ifr.data[3], ifr.data[4], ifr.data[5] });
        } else {
            out("\n");
        }
    }
    // inet addr
    var ifr = IFREQ{};
    @memcpy(ifr.name[0..@min(name.len, 16)], name[0..@min(name.len, 16)]);
    if (sockIoctl(SIOCGIFADDR, &ifr)) {
        var ipb: [16]u8 = undefined;
        var nb: [16]u8 = undefined;
        var bb: [16]u8 = undefined;
        var ifr2 = IFREQ{};
        @memcpy(ifr2.name[0..@min(name.len, 16)], name[0..@min(name.len, 16)]);
        const netmask = if (sockIoctl(SIOCGIFNETMASK, &ifr2)) ipFromSock(&ifr2) else 0;
        var ifr3 = IFREQ{};
        @memcpy(ifr3.name[0..@min(name.len, 16)], name[0..@min(name.len, 16)]);
        const bcast = if (sockIoctl(SIOCGIFBRDADDR, &ifr3)) ipFromSock(&ifr3) else 0;
        const ip = ipFromSock(&ifr);
        outf("          inet addr:{s}  Bcast:{s}  Mask:{s}\n", .{ ipStr(ip, &ipb), ipStr(bcast, &bb), ipStr(netmask, &nb) });
        out("          ");
        printFlags(flags);
        var ifr5 = IFREQ{};
        @memcpy(ifr5.name[0..@min(name.len, 16)], name[0..@min(name.len, 16)]);
        if (sockIoctl(SIOCGIFMTU, &ifr5)) {
            const mt = std.mem.readInt(i32, ifr5.data[0..4], .little);
            outf("  MTU:{d}  Metric:1\n", .{mt});
        } else {
            out("\n");
        }
    } else {
        out("          ");
        printFlags(flags);
        out("\n");
    }
    // stats from /proc/net/dev
    var st = std.mem.tokenizeScalar(u8, stats, ' ');
    var vals: [16]i64 = @splat(0);
    var k: usize = 0;
    while (st.next()) |tok| {
        if (k >= 16) break;
        vals[k] = u.toInt(tok) orelse 0;
        k += 1;
    }
    if (k >= 16) {
        outf("          RX packets:{d} errors:{d} dropped:{d} overruns:{d} frame:{d}\n", .{ vals[0], vals[2], vals[3], vals[4], vals[5] });
        outf("          TX packets:{d} errors:{d} dropped:{d} overruns:{d} carrier:{d}\n", .{ vals[8], vals[10], vals[11], vals[12], vals[13] });
        outf("          RX bytes:{d} ({d} KiB)  TX bytes:{d} ({d} KiB)\n", .{ vals[1], @divFloor(vals[1], 1024), vals[9], @divFloor(vals[9], 1024) });
    }
    out("\n");
}

fn ipFromSock(ifr: *IFREQ) u32 {
    // sockaddr: family u16 LE, addr at +4 BE
    return std.mem.readInt(u32, ifr.data[4..8], .big);
}

fn printFlags(flags: u16) void {
    var first = true;
    const fl = [_]struct { m: u16, s: []const u8 }{
        .{ .m = IFF_UP, .s = "UP" },
        .{ .m = IFF_BROADCAST, .s = "BROADCAST" },
        .{ .m = 0x10, .s = "DEBUG" },
        .{ .m = IFF_LOOPBACK, .s = "LOOPBACK" },
        .{ .m = 0x20, .s = "POINTOPOINT" },
        .{ .m = 0x40, .s = "RUNNING" },
        .{ .m = 0x80, .s = "NOARP" },
        .{ .m = 0x100, .s = "PROMISC" },
        .{ .m = 0x200, .s = "NOTRAILERS" },
        .{ .m = 0x400, .s = "ALLMULTI" },
        .{ .m = 0x800, .s = "MASTER" },
        .{ .m = 0x1000, .s = "SLAVE" },
        .{ .m = IFF_MULTICAST, .s = "MULTICAST" },
    };
    for (fl) |f| {
        if (flags & f.m != 0) {
            if (!first) out(" ");
            first = false;
            out(f.s);
        }
    }
}

fn setIface(iface: []const u8, ops: []const []const u8) u8 {
    var fail = false;
    var k: usize = 0;
    while (k < ops.len) : (k += 1) {
        const op = ops[k];
        if (std.mem.eql(u8, op, "up") or std.mem.eql(u8, op, "down")) {
            var ifr = IFREQ{};
            @memcpy(ifr.name[0..@min(iface.len, 16)], iface[0..@min(iface.len, 16)]);
            if (!sockIoctl(SIOCGIFFLAGS, &ifr)) {
                fail = true;
                continue;
            }
            var flags = std.mem.readInt(u16, ifr.data[0..2], .little);
            if (std.mem.eql(u8, op, "up")) {
                flags |= IFF_UP;
            } else {
                flags &= ~IFF_UP;
            }
            std.mem.writeInt(u16, ifr.data[0..2], flags, .little);
            if (!sockIoctl(SIOCSIFFLAGS, &ifr)) fail = true;
            continue;
        }
        if (std.mem.eql(u8, op, "netmask") and k + 1 < ops.len) {
            k += 1;
            var ifr = IFREQ{};
            @memcpy(ifr.name[0..@min(iface.len, 16)], iface[0..@min(iface.len, 16)]);
            const nm = parseIp(ops[k]) orelse {
                fail = true;
                continue;
            };
            writeIpSock(&ifr, nm);
            if (!sockIoctl(SIOCSIFNETMASK, &ifr)) fail = true;
            continue;
        }
        // assume IP address
        const ip = parseIp(op) orelse {
            errf("ifconfig: bad address: {s}\n", .{op});
            fail = true;
            continue;
        };
        var ifr = IFREQ{};
        @memcpy(ifr.name[0..@min(iface.len, 16)], iface[0..@min(iface.len, 16)]);
        writeIpSock(&ifr, ip);
        if (!sockIoctl(SIOCSIFADDR, &ifr)) {
            fail = true;
            continue;
        }
        // bring up
        var ifr2 = IFREQ{};
        @memcpy(ifr2.name[0..@min(iface.len, 16)], iface[0..@min(iface.len, 16)]);
        if (sockIoctl(SIOCGIFFLAGS, &ifr2)) {
            var flags = std.mem.readInt(u16, ifr2.data[0..2], .little);
            flags |= IFF_UP;
            std.mem.writeInt(u16, ifr2.data[0..2], flags, .little);
            _ = sockIoctl(SIOCSIFFLAGS, &ifr2);
        }
    }
    return if (fail) 1 else 0;
}

fn writeIpSock(ifr: *IFREQ, ip: u32) void {
    // sockaddr_in: family AF_INET, port 0, addr BE
    ifr.data[0] = 2;
    ifr.data[1] = 0;
    ifr.data[2] = 0;
    ifr.data[3] = 0;
    std.mem.writeInt(u32, ifr.data[4..8], ip, .big);
    for (8..16) |i| ifr.data[i] = 0;
}

// ---------- netstat ----------
pub fn netstat(args: []const []const u8) u8 {
    var show_all = false;
    for (args) |arg| {
        if (arg.len > 1 and arg[0] == '-') {
            for (arg[1..]) |c| {
                if (c == 'a') show_all = true;
            }
        }
    }
    out("Active Internet connections\n");
    outf("{s: <6}{s: >7} {s: >7} {s: <24} {s: <24} {s}\n", .{ "Proto", "Recv-Q", "Send-Q", "Local Address", "Foreign Address", "State" });
    netstatFile("/proc/net/tcp", "tcp", show_all);
    netstatFile("/proc/net/udp", "udp", show_all);
    return 0;
}

fn netstatFile(path: []const u8, proto: []const u8, show_all: bool) void {
    var f = u.File.open(path, .{ .ACCMODE = .RDONLY }, 0) orelse return;
    defer f.close();
    var lr = u.LineReader.init(f);
    var skip = true;
    while (lr.next()) |l| {
        if (skip) {
            skip = false;
            continue;
        }
        var it = std.mem.tokenizeScalar(u8, l, ' ');
        _ = it.next(); // sl
        const local = it.next() orelse continue;
        const remote = it.next() orelse continue;
        const st_hex = std.mem.trim(u8, it.next() orelse continue, " \t");
        const txrx = it.next() orelse "00000000:00000000";
        // txrx is "tx:rx" hex combined
        var txq: []const u8 = "0";
        var rxq: []const u8 = "0";
        if (std.mem.indexOfScalar(u8, txrx, ':')) |c| {
            txq = std.mem.trimStart(u8, txrx[0..c], "0");
            rxq = std.mem.trimStart(u8, txrx[c + 1 ..], "0");
            if (txq.len == 0) txq = "0";
            if (rxq.len == 0) rxq = "0";
        }
        var is_listen = false;
        var state: []const u8 = "";
        if (std.mem.eql(u8, proto, "tcp")) {
            state = tcpStateName(st_hex);
            is_listen = std.mem.eql(u8, state, "LISTEN");
        } else {
            state = "";
        }
        if (std.mem.eql(u8, proto, "tcp") and !show_all and is_listen) continue;
        outf("{s: <6}{s: >7} {s: >7} {s: <24} {s: <24} {s}\n", .{ proto, rxq, txq, fmtAddr(local), fmtAddr(remote), state });
    }
}

fn tcpStateName(hex: []const u8) []const u8 {
    const v = std.fmt.parseInt(u16, hex, 16) catch 0;
    return switch (v) {
        1 => "ESTABLISHED",
        2 => "SYN_SENT",
        3 => "SYN_RECV",
        4 => "FIN_WAIT1",
        5 => "FIN_WAIT2",
        6 => "TIME_WAIT",
        7 => "CLOSE",
        8 => "CLOSE_WAIT",
        9 => "LAST_ACK",
        10 => "LISTEN",
        11 => "CLOSING",
        else => "UNKNOWN",
    };
}

fn fmtAddr(hex_addr: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, hex_addr, ':') orelse return hex_addr;
    // /proc stores little-endian hex: octets are low to high
    const v = std.fmt.parseInt(u32, hex_addr[0..colon], 16) catch 0;
    const port = std.fmt.parseInt(u16, hex_addr[colon + 1 ..], 16) catch 0;
    var b: [32]u8 = undefined;
    return std.fmt.bufPrint(&b, "{d}.{d}.{d}.{d}:{d}", .{ v & 0xff, v >> 8 & 0xff, v >> 16 & 0xff, v >> 24 & 0xff, port }) catch "?";
}

// ---------- route ----------
pub fn route(args: []const []const u8) u8 {
    _ = args;
    out("Kernel IP routing table\n");
    outf("{s: <18}{s: <18}{s: <18}{s: <7}{s: >6} {s: >4} {s: >4}  {s}\n", .{ "Destination", "Gateway", "Genmask", "Flags", "Metric", "Ref", "Use", "Iface" });
    var f = u.File.open("/proc/net/route", .{ .ACCMODE = .RDONLY }, 0) orelse return 1;
    defer f.close();
    var lr = u.LineReader.init(f);
    var skip = true;
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    var b3: [16]u8 = undefined;
    while (lr.next()) |l| {
        if (skip) {
            skip = false;
            continue;
        }
        var it = std.mem.tokenizeScalar(u8, l, '\t');
        const iface = it.next() orelse continue;
        const dest_hex = it.next() orelse continue;
        const gw_hex = it.next() orelse continue;
        const flags_hex = std.mem.trim(u8, it.next() orelse "0", " \t");
        _ = it.next(); // refcnt
        _ = it.next(); // use
        const metric_hex = it.next() orelse "0";
        const mask_hex = it.next() orelse "0";
        // hex values are little-endian dumps of network-order bytes
        const dest = @byteSwap(std.fmt.parseInt(u32, dest_hex, 16) catch 0);
        const gw = @byteSwap(std.fmt.parseInt(u32, gw_hex, 16) catch 0);
        const mask = @byteSwap(std.fmt.parseInt(u32, mask_hex, 16) catch 0);
        const metric = std.fmt.parseInt(u32, metric_hex, 10) catch 0;
        const fv = std.fmt.parseInt(u32, flags_hex, 16) catch 0;
        var flags_s: [4]u8 = undefined;
        var fn2: usize = 0;
        if (fv & 1 != 0) {
            flags_s[fn2] = 'U';
            fn2 += 1;
        }
        if (fv & 2 != 0) {
            flags_s[fn2] = 'G';
            fn2 += 1;
        }
        if (fv & 4 != 0) {
            flags_s[fn2] = 'H';
            fn2 += 1;
        }
        outf("{s: <18}{s: <18}{s: <18}{s: <7}{d: >6} {d: >4} {d: >4}  {s}\n", .{ ipStr(dest, &b1), ipStr(gw, &b2), ipStr(mask, &b3), flags_s[0..fn2], metric, 0, 0, iface });
    }
    return 0;
}
