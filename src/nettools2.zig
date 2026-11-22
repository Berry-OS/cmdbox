// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// ping (iputils layout) and nslookup (BIND layout) with a small DNS client
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");

fn readFile(path: []const u8) ?[]u8 {
    const rc = linux.open(u.zstr(path), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(rc)) return null;
    defer _ = linux.close(@intCast(rc));
    var data = u.Vec(u8).init(u.alloc);
    var buf: [1 << 14]u8 = undefined;
    while (true) {
        const r = linux.read(@intCast(rc), &buf, buf.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r) or r == 0) break;
        data.pushSlice(buf[0..r]);
    }
    return data.items;
}

pub fn parseIpv4(s: []const u8) ?[4]u8 {
    var parts: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    var n: usize = 0;
    while (it.next()) |p| {
        if (n >= 4 or p.len == 0) return null;
        parts[n] = std.fmt.parseInt(u8, p, 10) catch return null;
        n += 1;
    }
    return if (n == 4) parts else null;
}

pub fn fmtIp(a: [4]u8) []const u8 {
    return std.fmt.allocPrint(u.alloc, "{d}.{d}.{d}.{d}", .{ a[0], a[1], a[2], a[3] }) catch "";
}

pub fn nowUs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1000);
}

pub fn sleepUs(us: i64) void {
    if (us <= 0) return;
    var ts: linux.timespec = .{ .sec = @intCast(@divTrunc(us, 1_000_000)), .nsec = @intCast(@mod(us, 1_000_000) * 1000) };
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

// ---------------------------------------------------------------- DNS client
const SockAddrIn = extern struct { family: u16 = 2, port: u16 = 0, addr: [4]u8 = [_]u8{0} ** 4, zero: [8]u8 = [_]u8{0} ** 8 };

fn resolvers() [][4]u8 {
    var out = u.Vec([4]u8).init(u.alloc);
    if (readFile("/etc/resolv.conf")) |d| {
        var lines = std.mem.splitScalar(u8, d, '\n');
        while (lines.next()) |l| {
            var it = std.mem.tokenizeAny(u8, l, " \t");
            const k = it.next() orelse continue;
            if (!std.mem.eql(u8, k, "nameserver")) continue;
            if (it.next()) |v| if (parseIpv4(v)) |ip| out.push(ip);
        }
    }
    if (out.items.len == 0) out.push(.{ 127, 0, 0, 1 });
    return out.items;
}

const Rr = struct { name: []const u8, rtype: u16, ttl: u32, data: []const u8, msg: []const u8, rdoff: usize };

const Reply = struct { rcode: u8, aa: bool, tc: bool, answers: []Rr, authority: []Rr, ok: bool };

fn encodeName(o: *u.Vec(u8), name: []const u8) bool {
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, name, "."), '.');
    while (it.next()) |label| {
        if (label.len == 0 or label.len > 63) return false;
        o.push(@intCast(label.len));
        o.pushSlice(label);
    }
    o.push(0);
    return true;
}

fn readName(msg: []const u8, off_in: usize, out: *u.Vec(u8)) ?usize {
    var off = off_in;
    var end: ?usize = null;
    var hops: usize = 0;
    while (true) {
        if (off >= msg.len) return null;
        const l = msg[off];
        if (l == 0) {
            off += 1;
            break;
        }
        if (l & 0xC0 == 0xC0) {
            if (off + 1 >= msg.len) return null;
            if (end == null) end = off + 2;
            off = (@as(usize, l & 0x3F) << 8) | msg[off + 1];
            hops += 1;
            if (hops > 32) return null;
            continue;
        }
        if (off + 1 + l > msg.len) return null;
        out.pushSlice(msg[off + 1 .. off + 1 + l]);
        out.push('.');
        off += 1 + l;
    }
    if (out.items.len == 0) out.push('.');
    return end orelse off;
}

fn parseReply(msg: []const u8, id: u16) ?Reply {
    if (msg.len < 12 or std.mem.readInt(u16, msg[0..2], .big) != id) return null;
    const flags = std.mem.readInt(u16, msg[2..4], .big);
    const qd = std.mem.readInt(u16, msg[4..6], .big);
    const an = std.mem.readInt(u16, msg[6..8], .big);
    const ns = std.mem.readInt(u16, msg[8..10], .big);
    var off: usize = 12;
    var i: usize = 0;
    while (i < qd) : (i += 1) {
        var tmp = u.Vec(u8).init(u.alloc);
        off = readName(msg, off, &tmp) orelse return null;
        off += 4;
    }
    var ans = u.Vec(Rr).init(u.alloc);
    var auth = u.Vec(Rr).init(u.alloc);
    i = 0;
    while (i < @as(usize, an) + ns) : (i += 1) {
        var nm = u.Vec(u8).init(u.alloc);
        off = readName(msg, off, &nm) orelse return null;
        if (off + 10 > msg.len) return null;
        const t = std.mem.readInt(u16, msg[off..][0..2], .big);
        const ttl = std.mem.readInt(u32, msg[off + 4 ..][0..4], .big);
        const rdl = std.mem.readInt(u16, msg[off + 8 ..][0..2], .big);
        off += 10;
        if (off + rdl > msg.len) return null;
        const rr = Rr{ .name = nm.items, .rtype = t, .ttl = ttl, .data = msg[off .. off + rdl], .msg = msg, .rdoff = off };
        if (i < an) ans.push(rr) else auth.push(rr);
        off += rdl;
    }
    return .{ .rcode = @intCast(flags & 0xF), .aa = flags & 0x400 != 0, .tc = flags & 0x200 != 0, .answers = ans.items, .authority = auth.items, .ok = true };
}

fn dnsQuery(server: [4]u8, port: u16, name: []const u8, qtype: u16, timeout_s: i64, tcp_ok: bool) ?Reply {
    var q = u.Vec(u8).init(u.alloc);
    var idb: [2]u8 = undefined;
    _ = linux.getrandom(&idb, 2, 0);
    const id = std.mem.readInt(u16, &idb, .big);
    q.pushSlice(&idb);
    q.pushSlice(&[_]u8{ 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0 });
    if (!encodeName(&q, name)) return null;
    var tb: [4]u8 = undefined;
    std.mem.writeInt(u16, tb[0..2], qtype, .big);
    std.mem.writeInt(u16, tb[2..4], 1, .big);
    q.pushSlice(&tb);
    var sa = SockAddrIn{ .port = std.mem.nativeToBig(u16, port), .addr = server };
    var attempt: usize = 0;
    while (attempt < 2) : (attempt += 1) {
        const fd = linux.socket(2, 2, 0);
        if (!u.ok(fd)) return null;
        defer _ = linux.close(@intCast(fd));
        const tv = linux.timeval{ .sec = @intCast(timeout_s), .usec = 0 };
        _ = linux.setsockopt(@intCast(fd), 1, 20, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
        if (!u.ok(linux.sendto(@intCast(fd), q.items.ptr, q.items.len, 0, @ptrCast(&sa), @sizeOf(SockAddrIn)))) return null;
        var buf: [4096]u8 = undefined;
        const r = linux.recvfrom(@intCast(fd), &buf, buf.len, 0, null, null);
        if (!u.ok(r)) continue;
        const copy = u.alloc.dupe(u8, buf[0..r]) catch return null;
        const rep = parseReply(copy, id) orelse continue;
        if (rep.tc and tcp_ok) return dnsTcp(server, port, q.items, id, timeout_s) orelse rep;
        return rep;
    }
    return null;
}

fn dnsTcp(server: [4]u8, port: u16, query: []const u8, id: u16, timeout_s: i64) ?Reply {
    const fd = linux.socket(2, 1, 0);
    if (!u.ok(fd)) return null;
    defer _ = linux.close(@intCast(fd));
    const tv = linux.timeval{ .sec = @intCast(timeout_s), .usec = 0 };
    _ = linux.setsockopt(@intCast(fd), 1, 20, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
    _ = linux.setsockopt(@intCast(fd), 1, 21, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
    var sa = SockAddrIn{ .port = std.mem.nativeToBig(u16, port), .addr = server };
    if (!u.ok(linux.connect(@intCast(fd), @ptrCast(&sa), @sizeOf(SockAddrIn)))) return null;
    var framed = u.Vec(u8).init(u.alloc);
    var lb: [2]u8 = undefined;
    std.mem.writeInt(u16, &lb, @intCast(query.len), .big);
    framed.pushSlice(&lb);
    framed.pushSlice(query);
    if (!u.ok(linux.write(@intCast(fd), framed.items.ptr, framed.items.len))) return null;
    var hdr: [2]u8 = undefined;
    if (!readFull(@intCast(fd), &hdr)) return null;
    const n = std.mem.readInt(u16, &hdr, .big);
    const body = u.alloc.alloc(u8, n) catch return null;
    if (!readFull(@intCast(fd), body)) return null;
    return parseReply(body, id);
}

fn readFull(fd: i32, buf: []u8) bool {
    var got: usize = 0;
    while (got < buf.len) {
        const r = linux.read(fd, buf[got..].ptr, buf.len - got);
        if (!u.ok(r) or r == 0) return false;
        got += r;
    }
    return true;
}

fn hostsLookup(name: []const u8) ?[4]u8 {
    const d = readFile("/etc/hosts") orelse return null;
    var lines = std.mem.splitScalar(u8, d, '\n');
    while (lines.next()) |l0| {
        const l = if (std.mem.indexOfScalar(u8, l0, '#')) |i| l0[0..i] else l0;
        var it = std.mem.tokenizeAny(u8, l, " \t");
        const a = it.next() orelse continue;
        const ip = parseIpv4(a) orelse continue;
        while (it.next()) |n| if (std.ascii.eqlIgnoreCase(n, name)) return ip;
    }
    return null;
}

fn hostsReverse(ip: [4]u8) ?[]const u8 {
    const d = readFile("/etc/hosts") orelse return null;
    var lines = std.mem.splitScalar(u8, d, '\n');
    while (lines.next()) |l0| {
        const l = if (std.mem.indexOfScalar(u8, l0, '#')) |i| l0[0..i] else l0;
        var it = std.mem.tokenizeAny(u8, l, " \t");
        const a = it.next() orelse continue;
        const hip = parseIpv4(a) orelse continue;
        if (!std.mem.eql(u8, &hip, &ip)) continue;
        return it.next();
    }
    return null;
}

pub fn resolveA(name: []const u8) ?[4]u8 {
    if (parseIpv4(name)) |ip| return ip;
    if (hostsLookup(name)) |ip| return ip;
    for (resolvers()) |srv| {
        const rep = dnsQuery(srv, 53, name, 1, 3, true) orelse continue;
        if (rep.rcode != 0) return null;
        for (rep.answers) |rr| if (rr.rtype == 1 and rr.data.len == 4) return rr.data[0..4].*;
        return null;
    }
    return null;
}

pub fn reverseName(ip: [4]u8) ?[]const u8 {
    if (hostsReverse(ip)) |n| return n;
    const q = std.fmt.allocPrint(u.alloc, "{d}.{d}.{d}.{d}.in-addr.arpa", .{ ip[3], ip[2], ip[1], ip[0] }) catch return null;
    for (resolvers()) |srv| {
        const rep = dnsQuery(srv, 53, q, 12, 1, false) orelse continue;
        for (rep.answers) |rr| if (rr.rtype == 12) {
            var nm = u.Vec(u8).init(u.alloc);
            _ = readName(rr.msg, rr.rdoff, &nm) orelse continue;
            return std.mem.trimEnd(u8, nm.items, ".");
        };
        return null;
    }
    return null;
}

// ---------------------------------------------------------------- ping
fn checksum(d: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < d.len) : (i += 2) sum += (@as(u32, d[i]) << 8) | d[i + 1];
    if (d.len % 2 == 1) sum += @as(u32, d[d.len - 1]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}

const ping_usage = "\nUsage\n  ping [options] <destination>\n\nOptions:\n  <destination>      dns name or ip address\n  -a                 use audible ping\n  -A                 use adaptive ping\n  -B                 sticky source address\n  -c <count>         stop after <count> replies\n  -D                 print timestamps\n  -d                 use SO_DEBUG socket option\n  -f                 flood ping\n  -h                 print help and exit\n  -I <interface>     either interface name or address\n  -i <interval>      seconds between sending each packet\n  -L                 suppress loopback of multicast packets\n  -l <preload>       send <preload> number of packages while waiting replies\n  -m <mark>          tag the packets going out\n  -M <pmtud opt>     define path MTU discovery, can be one of <do|dont|want|probe>\n  -n                 no dns name resolution\n  -O                 report outstanding replies\n  -p <pattern>       contents of padding byte\n  -q                 quiet output\n  -Q <tclass>        use quality of service <tclass> bits\n  -s <size>          use <size> as number of data bytes to be sent\n  -S <size>          use <size> as SO_SNDBUF socket option value\n  -t <ttl>           define time to live\n  -U                 print user-to-user latency\n  -v                 verbose output\n  -V                 print version and exit\n  -w <deadline>      reply wait <deadline> in seconds\n  -W <timeout>       time to wait for response\n\nIPv4 options:\n  -4                 use IPv4\n  -b                 allow pinging broadcast\n  -R                 record route\n  -T <timestamp>     define timestamp, can be one of <tsonly|tsandaddr|tsprio|tsprio=<cnt>>\n\nIPv6 options:\n  -6                 use IPv6\n  -F <flowlabel>     define flow label, default is random\n  -N <nodeinfo opt>  use IPv6 node info query, try <help> as argument\n\nFor more details see ping(8).\n";

pub fn ping(args: []const []const u8) u8 {
    var count: i64 = -1;
    var interval_us: i64 = 1_000_000;
    var wait_s: f64 = 10;
    var deadline: i64 = 0;
    var size: usize = 56;
    var ttl: i32 = 0;
    var quiet = false;
    var numeric = false;
    var timestamps = false;
    var host: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len > 1 and a[0] == '-' and a[1] != '-') {
            var k: usize = 1;
            while (k < a.len) : (k += 1) {
                const ch = a[k];
                switch (ch) {
                    'c', 'i', 'W', 'w', 's', 't', 'I', 'l', 'm', 'M', 'p', 'Q', 'S', 'T', 'F', 'N' => {
                        var val: []const u8 = a[k + 1 ..];
                        if (val.len == 0) {
                            i += 1;
                            if (i >= args.len) {
                                u.errf("ping: option requires an argument -- '{c}'\n", .{ch});
                                u.err(ping_usage);
                                return 2;
                            }
                            val = args[i];
                        }
                        switch (ch) {
                            'c' => count = std.fmt.parseInt(i64, val, 10) catch {
                                u.errf("ping: invalid argument: '{s}'\n", .{val});
                                return 2;
                            },
                            'i' => {
                                const f = std.fmt.parseFloat(f64, val) catch {
                                    u.errf("ping: invalid argument: '{s}'\n", .{val});
                                    return 2;
                                };
                                interval_us = @intFromFloat(f * 1e6);
                            },
                            'W' => wait_s = std.fmt.parseFloat(f64, val) catch 10,
                            'w' => deadline = std.fmt.parseInt(i64, val, 10) catch 0,
                            's' => size = std.fmt.parseInt(usize, val, 10) catch {
                                u.errf("ping: invalid argument: '{s}'\n", .{val});
                                return 2;
                            },
                            't' => ttl = std.fmt.parseInt(i32, val, 10) catch 0,
                            else => {},
                        }
                        k = a.len;
                    },
                    'q' => quiet = true,
                    'n' => numeric = true,
                    'D' => timestamps = true,
                    'a', 'A', 'B', 'd', 'f', 'L', 'O', 'U', 'v', 'b', 'R', '4' => {},
                    '6' => {
                        u.err("ping: IPv6 is not supported\n");
                        return 2;
                    },
                    'V' => {
                        u.out("ping from iputils 20240905 (cmdbox)\n");
                        return 0;
                    },
                    'h' => {
                        u.err(ping_usage);
                        return 2;
                    },
                    else => {
                        u.errf("ping: invalid option -- '{c}'\n", .{ch});
                        u.err(ping_usage);
                        return 2;
                    },
                }
            }
            continue;
        }
        if (host != null) {
            u.err("ping: only one destination allowed\n");
            return 2;
        }
        host = a;
    }
    const h = host orelse {
        u.err("ping: usage error: Destination address required\n");
        return 2;
    };
    const ip = resolveA(h) orelse {
        u.errf("ping: {s}: Name or service not known\n", .{h});
        return 2;
    };
    // ICMP socket: unprivileged datagram sockets first, raw as a fallback
    var is_raw = false;
    var sfd = linux.socket(2, 2 | 0x80000, 1);
    if (!u.ok(sfd)) {
        sfd = linux.socket(2, 3 | 0x80000, 1);
        is_raw = true;
        if (!u.ok(sfd)) {
            u.err("ping: socket: Operation not permitted\n");
            return 2;
        }
    }
    const fd: i32 = @intCast(sfd);
    defer _ = linux.close(fd);
    if (ttl > 0) _ = linux.setsockopt(fd, 0, 2, std.mem.asBytes(&ttl), 4);
    const one: i32 = 1;
    _ = linux.setsockopt(fd, 0, 12, std.mem.asBytes(&one), 4); // IP_RECVTTL
    _ = linux.setsockopt(fd, 0, 11, std.mem.asBytes(&one), 4); // IP_RECVERR
    var dest = SockAddrIn{ .addr = ip };
    // identifier: the kernel assigns it for datagram sockets
    var ident: u16 = 0;
    {
        var sa: SockAddrIn = .{};
        var sl: u32 = @sizeOf(SockAddrIn);
        if (!is_raw and u.ok(linux.connect(fd, @ptrCast(&dest), @sizeOf(SockAddrIn)))) {
            if (u.ok(linux.getsockname(fd, @ptrCast(&sa), &sl))) ident = std.mem.bigToNative(u16, sa.port);
        } else {
            var rb: [2]u8 = undefined;
            _ = linux.getrandom(&rb, 2, 0);
            ident = std.mem.readInt(u16, &rb, .little);
        }
    }
    const shown = fmtIp(ip);
    var hdr_name: []const u8 = shown;
    if (parseIpv4(h) == null) hdr_name = h;
    if (parseIpv4(h) != null) {
        u.outf("PING {s} ({s}) {d}({d}) bytes of data.\n", .{ h, shown, size, size + 28 });
    } else u.outf("PING {s} ({s}) {d}({d}) bytes of data.\n", .{ hdr_name, shown, size, size + 28 });
    var sent: i64 = 0;
    var recvd: i64 = 0;
    var errors: i64 = 0;
    var tmin: i64 = std.math.maxInt(i64);
    var tmax: i64 = 0;
    var tsum: f64 = 0;
    var tsum2: f64 = 0;
    const start = nowUs();
    var seq: u16 = 0;
    var next_send: i64 = start;
    const pkt_len = 8 + size;
    var pkt = u.alloc.alloc(u8, pkt_len) catch return 2;
    const wait_us: i64 = @intFromFloat(wait_s * 1e6);
    var last_send: i64 = start;
    var stop = false;
    while (!stop) {
        const now = nowUs();
        if (now >= next_send and (count < 0 or sent < count)) {
            seq +%= 1;
            @memset(pkt, 0);
            pkt[0] = 8;
            std.mem.writeInt(u16, pkt[4..6], ident, .big);
            std.mem.writeInt(u16, pkt[6..8], seq, .big);
            const ts = nowUs();
            std.mem.writeInt(i64, pkt[8..16][0..8], ts, .little);
            for (pkt[16..], 0..) |*b, ix| b.* = @intCast((ix + 16) & 0xff);
            std.mem.writeInt(u16, pkt[2..4], 0, .big);
            std.mem.writeInt(u16, pkt[2..4], checksum(pkt), .big);
            const sr = linux.sendto(fd, pkt.ptr, pkt.len, 0, @ptrCast(&dest), @sizeOf(SockAddrIn));
            last_send = now;
            sent += 1;
            if (!u.ok(sr)) {
                errors += 1;
                u.errf("ping: sendmsg: {s}\n", .{u.strerr(u.errno(sr))});
            }
            next_send = now + interval_us;
        }
        // finished sending and the last reply window has passed
        const all_sent = count >= 0 and sent >= count;
        var poll_to: i64 = if (all_sent) last_send + wait_us - now else next_send - now;
        if (deadline > 0) {
            const left = start + deadline * 1_000_000 - now;
            if (left <= 0) break;
            poll_to = @min(poll_to, left);
        }
        if (all_sent and recvd + errors >= sent) break;
        if (all_sent and poll_to <= 0) break;
        if (poll_to < 0) poll_to = 0;
        var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN | linux.POLL.ERR, .revents = 0 }};
        const pr = linux.poll(&pfd, 1, @intCast(@divTrunc(poll_to + 999, 1000)));
        if (!u.ok(pr) or pr == 0) continue;
        if (pfd[0].revents & linux.POLL.ERR != 0) {
            // error queue: unreachable and friends
            var ebuf: [256]u8 = undefined;
            var cbuf: [256]u8 = undefined;
            var iov = [_]std.posix.iovec{.{ .base = &ebuf, .len = ebuf.len }};
            var mh = linux.msghdr{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &cbuf, .controllen = cbuf.len, .flags = 0 };
            const er = linux.recvmsg(fd, &mh, 0x2000); // MSG_ERRQUEUE
            if (u.ok(er)) {
                errors += 1;
                // cmsg: sock_extended_err { errno u32, origin u8, type u8, code u8, ... } then the offender address
                var off: usize = 0;
                var from_ip: [4]u8 = ip;
                var msg_txt: []const u8 = "Destination Host Unreachable";
                while (off + 16 <= mh.controllen) {
                    const clen = std.mem.readInt(usize, cbuf[off .. off + @sizeOf(usize)][0..@sizeOf(usize)], .little);
                    if (clen < 16) break;
                    const hs = @sizeOf(usize) + 8;
                    if (clen >= hs + 16 + 8) {
                        const ee_type = cbuf[off + hs + 5];
                        const ee_code = cbuf[off + hs + 6];
                        if (ee_type == 3) msg_txt = switch (ee_code) {
                            0 => "Destination Net Unreachable",
                            1 => "Destination Host Unreachable",
                            3 => "Destination Port Unreachable",
                            4 => "Frag needed and DF set",
                            else => "Destination Unreachable",
                        } else if (ee_type == 11) msg_txt = "Time to live exceeded";
                        from_ip = cbuf[off + hs + 16 + 4 ..][0..4].*;
                    }
                    off += (clen + 7) & ~@as(usize, 7);
                }
                u.outf("From {s} icmp_seq={d} {s}\n", .{ fmtIp(from_ip), seq, msg_txt });
            }
            continue;
        }
        var rbuf: [2048]u8 = undefined;
        var cbuf: [128]u8 = undefined;
        var from = SockAddrIn{};
        var iov = [_]std.posix.iovec{.{ .base = &rbuf, .len = rbuf.len }};
        var mh = linux.msghdr{ .name = @ptrCast(&from), .namelen = @sizeOf(SockAddrIn), .iov = &iov, .iovlen = 1, .control = &cbuf, .controllen = cbuf.len, .flags = 0 };
        const rr = linux.recvmsg(fd, &mh, 0);
        if (!u.ok(rr)) continue;
        var data: []const u8 = rbuf[0..rr];
        if (is_raw) {
            if (data.len < 20) continue;
            const ihl: usize = (data[0] & 0xf) * 4;
            if (data.len < ihl + 8) continue;
            data = data[ihl..];
        }
        if (data.len < 8 or data[0] != 0) continue;
        const rid = std.mem.readInt(u16, data[4..6], .big);
        const rseq = std.mem.readInt(u16, data[6..8], .big);
        if (is_raw and rid != ident) continue;
        if (data.len < 16) continue;
        const sent_ts = std.mem.readInt(i64, data[8..16][0..8], .little);
        const trip = nowUs() - sent_ts;
        var rttl: i32 = 0;
        var coff: usize = 0;
        while (coff + @sizeOf(usize) + 8 <= mh.controllen) {
            const clen = std.mem.readInt(usize, cbuf[coff .. coff + @sizeOf(usize)][0..@sizeOf(usize)], .little);
            if (clen < @sizeOf(usize) + 8) break;
            const lvl = std.mem.readInt(i32, cbuf[coff + @sizeOf(usize) ..][0..4], .little);
            const typ = std.mem.readInt(i32, cbuf[coff + @sizeOf(usize) + 4 ..][0..4], .little);
            if (lvl == 0 and typ == 2) rttl = std.mem.readInt(i32, cbuf[coff + @sizeOf(usize) + 8 ..][0..4], .little);
            coff += (clen + 7) & ~@as(usize, 7);
        }
        recvd += 1;
        tmin = @min(tmin, trip);
        tmax = @max(tmax, trip);
        const tf: f64 = @floatFromInt(trip);
        tsum += tf;
        tsum2 += tf * tf;
        if (!quiet) {
            var srcname: []const u8 = fmtIp(from.addr);
            if (!numeric) {
                if (reverseName(from.addr)) |rn| srcname = std.fmt.allocPrint(u.alloc, "{s} ({s})", .{ rn, srcname }) catch srcname;
            }
            var prefix: []const u8 = "";
            if (timestamps) {
                var rts: linux.timespec = undefined;
                _ = linux.clock_gettime(.REALTIME, &rts);
                prefix = std.fmt.allocPrint(u.alloc, "[{d}.{d:0>6}] ", .{ rts.sec, @divTrunc(rts.nsec, 1000) }) catch "";
            }
            const ts_txt = rttText(trip);
            u.outf("{s}{d} bytes from {s}: icmp_seq={d} ttl={d} time={s} ms\n", .{ prefix, data.len, srcname, rseq, rttl, ts_txt });
        }
        if (count >= 0 and recvd >= count) stop = true;
    }
    const total_ms = @divTrunc(@max(last_send, start) - start, 1000);
    u.outf("\n--- {s} ping statistics ---\n", .{hdr_name});
    const loss: i64 = if (sent == 0) 0 else @divTrunc((sent - recvd) * 100, sent);
    u.outf("{d} packets transmitted, {d} received, ", .{ sent, recvd });
    if (errors > 0) u.outf("+{d} errors, ", .{errors});
    u.outf("{d}% packet loss, time {d}ms\n", .{ loss, @as(u64, @intCast(@max(total_ms, 0))) });
    if (recvd > 0) {
        const n: f64 = @floatFromInt(recvd);
        const avg = tsum / n;
        const mdev = std.math.sqrt(@max(tsum2 / n - avg * avg, 0));
        const avg_i: u64 = @intFromFloat(avg);
        const mdev_i: u64 = @intFromFloat(mdev);
        const tmin_u: u64 = @intCast(tmin);
        const tmax_u: u64 = @intCast(tmax);
        u.outf("rtt min/avg/max/mdev = {d}.{d:0>3}/{d}.{d:0>3}/{d}.{d:0>3}/{d}.{d:0>3} ms\n", .{ tmin_u / 1000, tmin_u % 1000, avg_i / 1000, avg_i % 1000, tmax_u / 1000, tmax_u % 1000, mdev_i / 1000, mdev_i % 1000 });
    }
    return if (recvd > 0) 0 else 1;
}

fn rttText(us: i64) []const u8 {
    const t: u64 = if (us < 0) 0 else @intCast(us);
    if (t >= 100000 - 50) return std.fmt.allocPrint(u.alloc, "{d}", .{(t + 500) / 1000}) catch "";
    if (t >= 10000 - 5) return std.fmt.allocPrint(u.alloc, "{d}.{d}", .{ (t + 50) / 1000, ((t + 50) % 1000) / 100 }) catch "";
    if (t >= 1000) return std.fmt.allocPrint(u.alloc, "{d}.{d:0>2}", .{ (t + 5) / 1000, ((t + 5) % 1000) / 10 }) catch "";
    return std.fmt.allocPrint(u.alloc, "{d}.{d:0>3}", .{ t / 1000, t % 1000 }) catch "";
}

// ---------------------------------------------------------------- nslookup
const type_names = [_]struct { n: []const u8, t: u16 }{
    .{ .n = "A", .t = 1 }, .{ .n = "NS", .t = 2 }, .{ .n = "CNAME", .t = 5 }, .{ .n = "SOA", .t = 6 }, .{ .n = "PTR", .t = 12 },
    .{ .n = "MX", .t = 15 }, .{ .n = "TXT", .t = 16 }, .{ .n = "AAAA", .t = 28 }, .{ .n = "SRV", .t = 33 }, .{ .n = "ANY", .t = 255 },
};

fn fmtV6(a: []const u8) []const u8 {
    var groups: [8]u16 = undefined;
    for (0..8) |i| groups[i] = (@as(u16, a[i * 2]) << 8) | a[i * 2 + 1];
    var best_start: usize = 8;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < 8) {
        if (groups[i] == 0) {
            var j = i;
            while (j < 8 and groups[j] == 0) j += 1;
            if (j - i > best_len) {
                best_len = j - i;
                best_start = i;
            }
            i = j;
        } else i += 1;
    }
    var o = u.Vec(u8).init(u.alloc);
    i = 0;
    while (i < 8) {
        if (best_len >= 2 and i == best_start) {
            o.pushSlice("::");
            i += best_len;
            continue;
        }
        if (o.items.len > 0 and o.items[o.items.len - 1] != ':') o.push(':');
        o.pushSlice(std.fmt.allocPrint(u.alloc, "{x}", .{groups[i]}) catch "");
        i += 1;
    }
    return o.items;
}

fn nameAt(rr: Rr, off: usize) []const u8 {
    var nm = u.Vec(u8).init(u.alloc);
    _ = readName(rr.msg, off, &nm) orelse return "";
    return nm.items;
}

fn printRr(o: *u.Vec(u8), rr: Rr, a_name_only: bool) void {
    _ = a_name_only;
    const nm = rr.name;
    switch (rr.rtype) {
        1 => if (rr.data.len == 4) o.pushSlice(std.fmt.allocPrint(u.alloc, "Name:\t{s}\nAddress: {s}\n", .{ std.mem.trimEnd(u8, nm, "."), fmtIp(rr.data[0..4].*) }) catch ""),
        28 => if (rr.data.len == 16) o.pushSlice(std.fmt.allocPrint(u.alloc, "Name:\t{s}\nAddress: {s}\n", .{ std.mem.trimEnd(u8, nm, "."), fmtV6(rr.data) }) catch ""),
        2 => o.pushSlice(std.fmt.allocPrint(u.alloc, "{s}\tnameserver = {s}\n", .{ std.mem.trimEnd(u8, nm, "."), nameAt(rr, rr.rdoff) }) catch ""),
        5 => o.pushSlice(std.fmt.allocPrint(u.alloc, "{s}\tcanonical name = {s}\n", .{ std.mem.trimEnd(u8, nm, "."), nameAt(rr, rr.rdoff) }) catch ""),
        12 => o.pushSlice(std.fmt.allocPrint(u.alloc, "{s}\tname = {s}\n", .{ std.mem.trimEnd(u8, nm, "."), nameAt(rr, rr.rdoff) }) catch ""),
        15 => if (rr.data.len > 2) o.pushSlice(std.fmt.allocPrint(u.alloc, "{s}\tmail exchanger = {d} {s}\n", .{ std.mem.trimEnd(u8, nm, "."), std.mem.readInt(u16, rr.data[0..2], .big), nameAt(rr, rr.rdoff + 2) }) catch ""),
        16 => {
            var txt = u.Vec(u8).init(u.alloc);
            var p: usize = 0;
            while (p < rr.data.len) {
                const l = rr.data[p];
                if (p + 1 + l > rr.data.len) break;
                if (txt.items.len > 0) txt.pushSlice("\" \"");
                txt.pushSlice(rr.data[p + 1 .. p + 1 + l]);
                p += 1 + l;
            }
            o.pushSlice(std.fmt.allocPrint(u.alloc, "{s}\ttext = \"{s}\"\n", .{ std.mem.trimEnd(u8, nm, "."), txt.items }) catch "");
        },
        6 => {
            var mn = u.Vec(u8).init(u.alloc);
            const e1 = readName(rr.msg, rr.rdoff, &mn) orelse return;
            var rn = u.Vec(u8).init(u.alloc);
            const e2 = readName(rr.msg, e1, &rn) orelse return;
            if (e2 + 20 > rr.msg.len) return;
            const m = rr.msg;
            o.pushSlice(std.fmt.allocPrint(u.alloc, "{s}\n\torigin = {s}\n\tmail addr = {s}\n\tserial = {d}\n\trefresh = {d}\n\tretry = {d}\n\texpire = {d}\n\tminimum = {d}\n", .{ std.mem.trimEnd(u8, nm, "."), mn.items, rn.items, std.mem.readInt(u32, m[e2..][0..4], .big), std.mem.readInt(u32, m[e2 + 4 ..][0..4], .big), std.mem.readInt(u32, m[e2 + 8 ..][0..4], .big), std.mem.readInt(u32, m[e2 + 12 ..][0..4], .big), std.mem.readInt(u32, m[e2 + 16 ..][0..4], .big) }) catch "");
        },
        33 => if (rr.data.len > 6) o.pushSlice(std.fmt.allocPrint(u.alloc, "{s}\tservice = {d} {d} {d} {s}\n", .{ std.mem.trimEnd(u8, nm, "."), std.mem.readInt(u16, rr.data[0..2], .big), std.mem.readInt(u16, rr.data[2..4], .big), std.mem.readInt(u16, rr.data[4..6], .big), nameAt(rr, rr.rdoff + 6) }) catch ""),
        else => {},
    }
}

pub fn nslookup(args: []const []const u8) u8 {
    var qtype: u16 = 0;
    var port: u16 = 53;
    var timeout: i64 = 5;
    var pos = u.Vec([]const u8).init(u.alloc);
    for (args) |a| {
        if (a.len > 1 and a[0] == '-' and a[1] != '-' or std.mem.startsWith(u8, a, "-")) {
            if (std.mem.startsWith(u8, a, "-type=") or std.mem.startsWith(u8, a, "-querytype=") or std.mem.startsWith(u8, a, "-q=")) {
                const v = a[std.mem.indexOfScalar(u8, a, '=').? + 1 ..];
                var found = false;
                for (type_names) |tn| if (std.ascii.eqlIgnoreCase(tn.n, v)) {
                    qtype = tn.t;
                    found = true;
                };
                if (!found) {
                    u.errf("nslookup: unknown query type: {s}\n", .{v});
                    return 1;
                }
            } else if (std.mem.startsWith(u8, a, "-port=")) {
                port = std.fmt.parseInt(u16, a[6..], 10) catch 53;
            } else if (std.mem.startsWith(u8, a, "-timeout=")) {
                timeout = std.fmt.parseInt(i64, a[9..], 10) catch 5;
            } else if (std.mem.eql(u8, a, "-version") or std.mem.eql(u8, a, "-V")) {
                u.out("nslookup 9.20.0 (cmdbox)\n");
                return 0;
            } else if (std.mem.startsWith(u8, a, "-debug") or std.mem.startsWith(u8, a, "-d2") or std.mem.startsWith(u8, a, "-nodebug") or std.mem.startsWith(u8, a, "-recurse") or std.mem.startsWith(u8, a, "-norecurse") or std.mem.startsWith(u8, a, "-retry=") or std.mem.startsWith(u8, a, "-vc") or std.mem.startsWith(u8, a, "-novc") or std.mem.startsWith(u8, a, "-class=") or std.mem.startsWith(u8, a, "-domain=") or std.mem.startsWith(u8, a, "-search") or std.mem.startsWith(u8, a, "-nosearch") or std.mem.startsWith(u8, a, "-ndots=")) {} else {
                u.errf("nslookup: invalid option: {s}\n", .{a});
                return 1;
            }
            continue;
        }
        pos.push(a);
    }
    if (pos.items.len == 0) {
        u.err("nslookup: interactive mode is not supported\n");
        return 1;
    }
    const name = pos.items[0];
    var servers = u.Vec([4]u8).init(u.alloc);
    if (pos.items.len > 1) {
        const sip = parseIpv4(pos.items[1]) orelse resolveA(pos.items[1]) orelse {
            u.errf(";; couldn't get address for '{s}': not found\n", .{pos.items[1]});
            return 1;
        };
        servers.push(sip);
    } else for (resolvers()) |s| servers.push(s);
    // reverse lookups for address arguments
    var qname: []const u8 = name;
    var types = u.Vec(u16).init(u.alloc);
    if (parseIpv4(name)) |ip| {
        qname = std.fmt.allocPrint(u.alloc, "{d}.{d}.{d}.{d}.in-addr.arpa", .{ ip[3], ip[2], ip[1], ip[0] }) catch name;
        if (qtype == 0) qtype = 12;
    }
    if (qtype == 0) {
        types.push(1);
        types.push(28);
    } else types.push(qtype);
    var out = u.Vec(u8).init(u.alloc);
    var rc: u8 = 0;
    var header_done = false;
    var used_server: [4]u8 = servers.items[0];
    var answered = false;
    var results = u.Vec(Reply).init(u.alloc);
    var nx = false;
    for (types.items) |t| {
        var rep: ?Reply = null;
        for (servers.items) |s| {
            rep = dnsQuery(s, port, qname, t, timeout, true);
            if (rep != null) {
                used_server = s;
                break;
            }
        }
        if (rep) |r| {
            results.push(r);
            if (r.rcode == 3) nx = true;
        } else if (!answered) {
            if (!header_done) {
                out.pushSlice(std.fmt.allocPrint(u.alloc, ";; communications error to {s}#{d}: timed out\n", .{ fmtIp(servers.items[0]), port }) catch "");
            }
            out.pushSlice(";; no servers could be reached\n\n");
            u.out(out.items);
            return 1;
        }
    }
    out.pushSlice(std.fmt.allocPrint(u.alloc, "Server:\t\t{s}\nAddress:\t{s}#{d}\n\n", .{ fmtIp(used_server), fmtIp(used_server), port }) catch "");
    header_done = true;
    var all_aa = true;
    for (results.items) |r| {
        if (!r.aa) all_aa = false;
        if (r.answers.len > 0) answered = true;
    }
    if (answered) {
        if (!all_aa) out.pushSlice("Non-authoritative answer:\n");
        for (results.items) |r| for (r.answers) |rr| printRr(&out, rr, false);
        out.push('\n');
    } else if (nx) {
        out.pushSlice(std.fmt.allocPrint(u.alloc, "** server can't find {s}: NXDOMAIN\n\n", .{qname}) catch "");
        rc = 1;
    } else {
        // no data: BIND still prints the authority section for SOA
        var shown = false;
        for (results.items) |r| for (r.authority) |rr| if (rr.rtype == 6) {
            if (!shown) out.pushSlice("*** Can't find ");
            shown = true;
        };
        out.pushSlice(std.fmt.allocPrint(u.alloc, "*** Can't find {s}: No answer\n\n", .{name}) catch "");
        if (shown) {}
        rc = 1;
    }
    u.out(out.items);
    return rc;
}
