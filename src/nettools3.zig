// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// arping (iputils), rdate, whois, telnet, traceroute, ftpput
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const n2 = @import("nettools2.zig");
const ct = @cImport({
    @cInclude("time.h");
    @cInclude("sys/timex.h");
});

fn htons(x: u16) u16 {
    return std.mem.nativeToBig(u16, x);
}

fn ifreqName(name: []const u8) [16]u8 {
    var b: [16]u8 = @splat(0);
    const m = @min(name.len, 15);
    @memcpy(b[0..m], name[0..m]);
    return b;
}

const IfReq = extern struct { name: [16]u8, data: [24]u8 };

fn ioctlIf(fd: i32, req: u32, name: []const u8, ifr: *IfReq) bool {
    ifr.* = .{ .name = ifreqName(name), .data = @splat(0) };
    return u.ok(linux.ioctl(fd, req, @intFromPtr(ifr)));
}

// ===================== arping =====================
const SIOCGIFFLAGS = 0x8913;
const SIOCGIFADDR = 0x8915;
const SIOCGIFINDEX = 0x8933;
const SIOCGIFHWADDR = 0x8927;
const SIOCGIFCONF = 0x8912;

const SockLl = extern struct {
    family: u16 = 17,
    protocol: u16 = 0,
    ifindex: i32 = 0,
    hatype: u16 = 0,
    pkttype: u8 = 0,
    halen: u8 = 0,
    addr: [8]u8 = @splat(0),
};

var arp_quit = false;

fn arpSig(sig: linux.SIG) callconv(.c) void {
    _ = sig;
    arp_quit = true;
}

const IfAddr = struct { name: []const u8, ip: [4]u8 };

fn ifaceList(fd: i32) []IfAddr {
    var out = u.Vec(IfAddr).init(u.alloc);
    var buf: [4096]u8 = undefined;
    const Conf = extern struct { len: i32, ptr: usize };
    var conf = Conf{ .len = buf.len, .ptr = @intFromPtr(&buf) };
    if (!u.ok(linux.ioctl(fd, SIOCGIFCONF, @intFromPtr(&conf)))) return out.items;
    const n: usize = @intCast(@divTrunc(conf.len, 40));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e = buf[i * 40 ..][0..40];
        const nm = std.mem.sliceTo(e[0..16], 0);
        if (e[16] != 2 and e[16] != 0) continue; // AF_INET
        const ip = e[20..24].*;
        out.push(.{ .name = u.alloc.dupe(u8, nm) catch continue, .ip = ip });
    }
    return out.items;
}

pub fn arping(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "", .key = 'f' }, .{ .name = "", .key = 'q' }, .{ .name = "", .key = 'b' },
        .{ .name = "", .key = 'D' }, .{ .name = "", .key = 'U' }, .{ .name = "", .key = 'A' },
        .{ .name = "", .key = 'V' }, .{ .name = "", .key = 'h' }, .{ .name = "", .key = 'c', .arg = .req },
        .{ .name = "", .key = 'w', .arg = .req }, .{ .name = "", .key = 'i', .arg = .req },
        .{ .name = "", .key = 'I', .arg = .req }, .{ .name = "", .key = 's', .arg = .req },
        .{ .name = "", .key = 'a' },
    };
    const usage = "\nUsage:\n  arping [options] <destination>\n\nOptions:\n  -f            quit on first reply\n  -q            be quiet\n  -b            keep on broadcasting, do not unicast\n  -D            duplicate address detection mode\n  -U            unsolicited ARP mode, update your neighbours\n  -A            ARP answer mode, update your neighbours\n  -V            print version and exit\n  -c <count>    how many packets to send\n  -w <timeout>  how long to wait for a reply\n  -i <interval> set interval between packets (default: 1 second)\n  -I <device>   which ethernet device to use\n  -s <source>   source IP address\n  <destination> DNS name or IP address\n\nFor more details see arping(8).\n";
    var p = g.Parser.init("arping", args, &opts);
    p.no_hint = true;
    var quit_first = false;
    var quiet = false;
    var bcast_only = false;
    var dad = false;
    var unsol = false;
    var answer = false;
    var count: i64 = -1;
    var timeout_s: i64 = -1;
    var interval_ms: i64 = 1000;
    var dev: ?[]const u8 = null;
    var src_arg: ?[]const u8 = null;
    while (p.next() catch {
        u.err(usage);
        return 2;
    }) |it| {
        switch (it.key) {
            'f' => quit_first = true,
            'q' => quiet = true,
            'b' => bcast_only = true,
            'D' => dad = true,
            'U' => unsol = true,
            'A' => answer = true,
            'V' => {
                u.out("arping from iputils 20250605\nlibcap: yes, IDN: yes, NLS: yes, error.h: yes, getrandom(): yes, __fpending(): yes\n");
                return 0;
            },
            'h' => {
                u.out(usage);
                return 2;
            },
            'c' => count = std.fmt.parseInt(i64, it.val.?, 10) catch {
                u.errf("arping: invalid argument: '{s}'\n", .{it.val.?});
                return 1;
            },
            'w' => timeout_s = std.fmt.parseInt(i64, it.val.?, 10) catch {
                u.errf("arping: invalid argument: '{s}'\n", .{it.val.?});
                return 1;
            },
            'i' => {
                const f = std.fmt.parseInt(i64, it.val.?, 10) catch {
                    u.errf("arping: invalid argument: '{s}'\n", .{it.val.?});
                    return 1;
                };
                interval_ms = f * 1000;
            },
            'I' => dev = it.val,
            's' => src_arg = it.val,
            else => {},
        }
    }
    if (p.operands.items.len != 1) {
        u.err(usage);
        return 2;
    }
    const target = p.operands.items[0];
    const dst = n2.resolveA(target) orelse {
        u.errf("arping: {s}: Name or service not known\n", .{target});
        return 2;
    };
    const ctl = linux.socket(2, 2, 0); // AF_INET dgram for ioctls
    if (!u.ok(ctl)) return 2;
    const cfd: i32 = @intCast(ctl);
    defer _ = linux.close(cfd);
    var src: [4]u8 = .{ 0, 0, 0, 0 };
    var have_src = false;
    if (src_arg) |sa| {
        src = n2.resolveA(sa) orelse {
            u.errf("arping: invalid source {s}\n", .{sa});
            return 2;
        };
        have_src = true;
    }
    // device selection
    const ifs = ifaceList(cfd);
    var devname: []const u8 = "";
    if (dev) |d| {
        devname = d;
        var ifr: IfReq = undefined;
        if (!ioctlIf(cfd, SIOCGIFINDEX, d, &ifr)) {
            u.errf("arping: Device {s} not available.\n", .{d});
            return 2;
        }
    } else {
        // route lookup through a connected UDP socket
        const us = linux.socket(2, 2, 0);
        if (u.ok(us)) {
            const usf: i32 = @intCast(us);
            defer _ = linux.close(usf);
            var sa: linux.sockaddr.in = .{ .port = htons(1025), .addr = @bitCast(dst) };
            if (u.ok(linux.connect(usf, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)))) {
                var loc: linux.sockaddr.in = undefined;
                var ll: linux.socklen_t = @sizeOf(linux.sockaddr.in);
                if (u.ok(linux.getsockname(usf, @ptrCast(&loc), &ll))) {
                    const lip: [4]u8 = @bitCast(loc.addr);
                    var dst_local = false;
                    for (ifs) |ifc| if (std.mem.eql(u8, &ifc.ip, &dst)) {
                        dst_local = true;
                    };
                    if (dst_local) devname = "lo";
                    if (!dst_local) for (ifs) |ifc| if (std.mem.eql(u8, &ifc.ip, &lip)) {
                        devname = ifc.name;
                        if (!have_src and !dad and !unsol and !answer) {
                            src = lip;
                            have_src = true;
                        }
                        break;
                    };
                }
            }
        }
        if (devname.len == 0) {
            for (ifs) |ifc| if (!std.mem.eql(u8, ifc.name, "lo")) {
                devname = ifc.name;
                break;
            };
        }
        if (devname.len == 0) {
            u.err("arping: Device (null) not available.\n");
            return 2;
        }
    }
    var ifr: IfReq = undefined;
    if (!ioctlIf(cfd, SIOCGIFFLAGS, devname, &ifr)) {
        u.errf("arping: Device {s} not available.\n", .{devname});
        return 2;
    }
    const flags = std.mem.readInt(u16, ifr.data[0..2], .little);
    if (flags & 0x8 != 0 or flags & 0x80 != 0) { // LOOPBACK | NOARP
        u.errf("Interface \"{s}\" is not ARPable\n", .{devname});
        return if (dad) 0 else 2;
    }
    if (flags & 1 == 0) {
        u.errf("Interface \"{s}\" is down\n", .{devname});
        return if (dad) 0 else 2;
    }
    if (!ioctlIf(cfd, SIOCGIFINDEX, devname, &ifr)) return 2;
    const ifindex = std.mem.readInt(i32, ifr.data[0..4], .little);
    if (!ioctlIf(cfd, SIOCGIFHWADDR, devname, &ifr)) return 2;
    const my_mac: [6]u8 = ifr.data[2..8].*;
    if (dad) {
        src = .{ 0, 0, 0, 0 };
        have_src = true;
    } else if (unsol or answer) {
        src = dst;
        have_src = true;
    } else if (!have_src) {
        // address of the device
        for (ifs) |ifc| if (std.mem.eql(u8, ifc.name, devname)) {
            src = ifc.ip;
            have_src = true;
        };
        if (!have_src) {
            u.err("arping: no source address in not-DAD mode\n");
            return 2;
        }
    }
    const sk = linux.socket(17, 2, htons(0x0806));
    if (!u.ok(sk)) {
        u.errf("arping: socket: {s}\n", .{u.strerr(u.errno(sk))});
        return 2;
    }
    const sfd: i32 = @intCast(sk);
    defer _ = linux.close(sfd);
    var me = SockLl{ .protocol = htons(0x0806), .ifindex = ifindex };
    if (!u.ok(linux.bind(sfd, @ptrCast(&me), @sizeOf(SockLl)))) {
        u.errf("arping: bind: {s}\n", .{u.strerr(u.errno(linux.bind(sfd, @ptrCast(&me), @sizeOf(SockLl))))});
        return 2;
    }
    if (!quiet) u.outf("ARPING {s} from {s} {s}\n", .{ n2.fmtIp(dst), n2.fmtIp(src), devname });
    var act = linux.Sigaction{ .handler = .{ .handler = arpSig }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(linux.SIG.INT, &act, null);
    _ = linux.sigaction(linux.SIG.TERM, &act, null);

    var sent: u32 = 0;
    var bcast_sent: u32 = 0;
    var received: u32 = 0;
    var uni_mac: ?[6]u8 = null;
    var last_send_us: i64 = 0;
    const start_us = n2.nowUs();
    var next_send_us: i64 = start_us;
    var dup_found = false;
    while (!arp_quit) {
        const now = n2.nowUs();
        if (timeout_s >= 0 and now - start_us >= timeout_s * 1_000_000 and sent > 0) break;
        if (now >= next_send_us) {
            if (count >= 0 and sent >= @as(u32, @intCast(count))) {
                // everything sent: wait out the last interval
                if (now >= next_send_us) break;
            }
            // build the ARP packet
            var pkt: [28]u8 = @splat(0);
            std.mem.writeInt(u16, pkt[0..2], 1, .big);
            std.mem.writeInt(u16, pkt[2..4], 0x0800, .big);
            pkt[4] = 6;
            pkt[5] = 4;
            std.mem.writeInt(u16, pkt[6..8], if (answer) 2 else 1, .big);
            @memcpy(pkt[8..14], &my_mac);
            @memcpy(pkt[14..18], &src);
            if (answer) @memcpy(pkt[18..24], &my_mac);
            @memcpy(pkt[24..28], &dst);
            var to = SockLl{ .protocol = htons(0x0806), .ifindex = ifindex, .halen = 6 };
            var unicast = false;
            if (uni_mac != null and !bcast_only and !dad) {
                @memcpy(to.addr[0..6], &uni_mac.?);
                unicast = true;
            } else @memset(to.addr[0..6], 0xff);
            const w = linux.sendto(sfd, &pkt, pkt.len, 0, @ptrCast(&to), @sizeOf(SockLl));
            if (!u.ok(w)) {
                u.errf("arping: sendto: {s}\n", .{u.strerr(u.errno(w))});
                return 2;
            }
            last_send_us = n2.nowUs();
            sent += 1;
            if (!unicast) bcast_sent += 1;
            next_send_us = last_send_us + interval_ms * 1000;
        }
        // wait for packets until the next send time
        var wait_ms: i64 = @divTrunc(next_send_us - n2.nowUs(), 1000);
        if (wait_ms < 0) wait_ms = 0;
        if (timeout_s >= 0) {
            const left = @divTrunc(start_us + timeout_s * 1_000_000 - n2.nowUs(), 1000);
            if (left < wait_ms) wait_ms = @max(left, 0);
        }
        var pfd = [1]linux.pollfd{.{ .fd = sfd, .events = linux.POLL.IN, .revents = 0 }};
        const pr = linux.poll(&pfd, 1, @intCast(wait_ms));
        if (!u.ok(pr)) {
            if (u.errno(pr) == .INTR) continue;
            break;
        }
        if (pr == 0) {
            if (count >= 0 and sent >= @as(u32, @intCast(count)) and n2.nowUs() >= next_send_us) break;
            if (timeout_s >= 0 and n2.nowUs() - start_us >= timeout_s * 1_000_000) break;
            continue;
        }
        var buf: [256]u8 = undefined;
        var from = SockLl{};
        var fl: linux.socklen_t = @sizeOf(SockLl);
        const r = linux.recvfrom(sfd, &buf, buf.len, 0, @ptrCast(&from), &fl);
        if (!u.ok(r) or r < 28) continue;
        const op = std.mem.readInt(u16, buf[6..8], .big);
        const sha = buf[8..14];
        const spa = buf[14..18];
        const tpa = buf[24..28];
        if (std.mem.eql(u8, sha, &my_mac)) continue;
        var match = false;
        if (op == 2 and std.mem.eql(u8, spa, &dst)) {
            if (dad) match = true else if (std.mem.eql(u8, tpa, &src)) match = true;
        } else if (dad and op == 1 and std.mem.eql(u8, spa, &[4]u8{ 0, 0, 0, 0 }) and std.mem.eql(u8, tpa, &dst)) {
            match = true;
        }
        if (!match) continue;
        received += 1;
        if (dad) dup_found = true;
        const rtt = n2.nowUs() - last_send_us;
        if (!quiet) {
            const kind: []const u8 = if (from.pkttype == 0) "Unicast" else "Broadcast";
            u.outf("{s} {s} from {s} [{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}]  {d}.{d:0>3}ms\n", .{
                kind,
                if (op == 2) "reply" else "request",
                n2.fmtIp(spa[0..4].*),
                sha[0], sha[1], sha[2], sha[3], sha[4], sha[5],
                @as(u64, @intCast(@divTrunc(rtt, 1000))),
                @as(u64, @intCast(@mod(rtt, 1000))),
            });
        }
        if (!dad) uni_mac = sha[0..6].*;
        if (quit_first or dad) break;
        if (count >= 0 and sent >= @as(u32, @intCast(count)) and received >= sent) break;
    }
    if (!quiet) {
        u.outf("Sent {d} probes ({d} broadcast(s))\n", .{ sent, bcast_sent });
        u.outf("Received {d} response(s)\n", .{received});
    }
    if (dad) return if (dup_found) 1 else 0;
    if (unsol or answer) return 0;
    return if (received > 0) 0 else 1;
}

// ===================== TCP helpers =====================
fn tcpConnect(host: []const u8, port: u16, timeout_ms: i32) ?i32 {
    const ip = n2.resolveA(host) orelse return null;
    const s = linux.socket(2, 1, 0);
    if (!u.ok(s)) return null;
    const fd: i32 = @intCast(s);
    var sa: linux.sockaddr.in = .{ .port = htons(port), .addr = @bitCast(ip) };
    // non-blocking connect with timeout
    const fl = linux.fcntl(fd, 3, 0);
    _ = linux.fcntl(fd, 4, fl | 0o4000);
    const rc = linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
    if (!u.ok(rc) and u.errno(rc) != .INPROGRESS) {
        _ = linux.close(fd);
        return null;
    }
    if (!u.ok(rc)) {
        var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
        const pr = linux.poll(&pfd, 1, timeout_ms);
        if (!u.ok(pr) or pr == 0) {
            _ = linux.close(fd);
            return null;
        }
        var err: i32 = 0;
        var el: linux.socklen_t = 4;
        _ = linux.getsockopt(fd, 1, 4, @ptrCast(&err), &el);
        if (err != 0) {
            _ = linux.close(fd);
            return null;
        }
    }
    _ = linux.fcntl(fd, 4, fl);
    return fd;
}

fn readAll(fd: i32, out: *u.Vec(u8), timeout_ms: i32) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        const pr = linux.poll(&pfd, 1, timeout_ms);
        if (!u.ok(pr) or pr == 0) break;
        const r = linux.read(fd, &buf, buf.len);
        if (!u.ok(r) or r == 0) break;
        out.pushSlice(buf[0..r]);
    }
}

fn writeAllFd(fd: i32, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const w = linux.write(fd, data.ptr + off, data.len - off);
        if (u.errno(w) == .INTR) continue;
        if (!u.ok(w)) return false;
        off += w;
    }
    return true;
}

// ===================== rdate =====================
const TIME_OFFSET: i64 = 2208988800;

fn ctimeLine(secs: i64) []const u8 {
    var t: ct.time_t = @intCast(secs);
    var tmv: ct.struct_tm = undefined;
    _ = ct.localtime_r(&t, &tmv);
    var buf: [64]u8 = undefined;
    const n = ct.strftime(&buf, buf.len, "%a %b %e %H:%M:%S %Y", &tmv);
    return u.alloc.dupe(u8, buf[0..n]) catch "";
}

pub fn rdate(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "set", .key = 's' },
        .{ .name = "print", .key = 'p' },
        .{ .name = "udp", .key = 'u' },
        .{ .name = "port", .key = 'P', .arg = .req },
        .{ .name = "timeout", .key = 't', .arg = .req },
        .{ .name = "help", .key = 'h' },
    };
    var p = g.Parser.init("rdate", args, &opts);
    var set = false;
    var print = false;
    var udp = false;
    var port: u16 = 37;
    var timeout_s: i32 = 30;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            's' => set = true,
            'p' => print = true,
            'u' => udp = true,
            'P' => port = std.fmt.parseInt(u16, it.val.?, 10) catch 37,
            't' => timeout_s = std.fmt.parseInt(i32, it.val.?, 10) catch 30,
            'h' => {
                u.out("Usage: rdate [-sp] HOST\n\nConnect to an RFC868 time server over TCP and print the time\n\n\t-s\tSet system time\n\t-p\tPrint time\n");
                return 0;
            },
            else => {},
        }
    }
    if (p.operands.items.len != 1) {
        u.err("Usage: rdate [-sp] HOST\n");
        return 1;
    }
    if (!set) print = true;
    const host = p.operands.items[0];
    var raw: [4]u8 = undefined;
    if (udp) {
        const ip = n2.resolveA(host) orelse {
            u.errf("rdate: {s}: Name or service not known\n", .{host});
            return 1;
        };
        const s = linux.socket(2, 2, 0);
        if (!u.ok(s)) return 1;
        const fd: i32 = @intCast(s);
        defer _ = linux.close(fd);
        var sa: linux.sockaddr.in = .{ .port = htons(port), .addr = @bitCast(ip) };
        _ = linux.sendto(fd, "", 0, 0, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
        var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        const pr = linux.poll(&pfd, 1, timeout_s * 1000);
        if (!u.ok(pr) or pr == 0) {
            u.errf("rdate: timed out waiting for {s}\n", .{host});
            return 1;
        }
        const r = linux.recvfrom(fd, &raw, 4, 0, null, null);
        if (!u.ok(r) or r < 4) return 1;
    } else {
        const fd = tcpConnect(host, port, timeout_s * 1000) orelse {
            u.errf("rdate: could not connect to {s}\n", .{host});
            return 1;
        };
        defer _ = linux.close(fd);
        var got: usize = 0;
        while (got < 4) {
            var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
            const pr = linux.poll(&pfd, 1, timeout_s * 1000);
            if (!u.ok(pr) or pr == 0) {
                u.errf("rdate: timed out waiting for {s}\n", .{host});
                return 1;
            }
            const r = linux.read(fd, raw[got..].ptr, 4 - got);
            if (!u.ok(r) or r == 0) break;
            got += r;
        }
        if (got < 4) {
            u.errf("rdate: {s}: short read\n", .{host});
            return 1;
        }
    }
    const t: i64 = @as(i64, std.mem.readInt(u32, &raw, .big)) - TIME_OFFSET;
    if (set) {
        var ts: linux.timespec = .{ .sec = @intCast(t), .nsec = 0 };
        const rc = linux.clock_settime(.REALTIME, &ts);
        if (!u.ok(rc)) {
            u.errf("rdate: could not set system time: {s}\n", .{u.strerr(u.errno(rc))});
            return 1;
        }
    }
    if (print) u.outf("{s}\n", .{ctimeLine(t)});
    return 0;
}

// ===================== whois =====================
fn whoisQuery(server: []const u8, port: u16, query: []const u8) ?[]const u8 {
    const fd = tcpConnect(server, port, 10000) orelse return null;
    defer _ = linux.close(fd);
    const q = std.fmt.allocPrint(u.alloc, "{s}\r\n", .{query}) catch return null;
    if (!writeAllFd(fd, q)) return null;
    var out = u.Vec(u8).init(u.alloc);
    readAll(fd, &out, 15000);
    return out.items;
}

fn referral(text: []const u8, keys: []const []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l0| {
        const l = std.mem.trim(u8, l0, " \t\r");
        for (keys) |k| {
            if (l.len > k.len and std.ascii.eqlIgnoreCase(l[0..k.len], k)) {
                var v = std.mem.trim(u8, l[k.len..], " \t");
                if (std.mem.startsWith(u8, v, "whois://")) v = v[8..];
                if (std.mem.startsWith(u8, v, "rwhois://")) v = v[9..];
                if (std.mem.indexOfScalar(u8, v, '/')) |sl| v = v[0..sl];
                if (v.len > 0) return v;
            }
        }
    }
    return null;
}

pub fn whois(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "host", .key = 'h', .arg = .req },
        .{ .name = "port", .key = 'p', .arg = .req },
        .{ .name = "no-recursion", .key = 'r' },
        .{ .name = "no-disclaimer", .key = 'H' },
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "help", .key = 200 },
        .{ .name = "version", .key = 201 },
    };
    var p = g.Parser.init("whois", args, &opts);
    var host: ?[]const u8 = null;
    var port: u16 = 43;
    var recurse = true;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'h' => host = it.val,
            'p' => port = std.fmt.parseInt(u16, it.val.?, 10) catch {
                u.errf("whois: invalid port number: {s}\n", .{it.val.?});
                return 1;
            },
            'r' => recurse = false,
            200 => {
                u.out("Usage: whois [OPTION]... OBJECT...\n\n-h HOST, --host HOST   connect to server HOST\n-p PORT, --port PORT   connect to PORT\n-H                     hide legal disclaimers\n-r                     do not follow referrals\n      --help           display this help and exit\n      --version        output version information and exit\n");
                return 0;
            },
            201 => {
                u.out("Version 5.5.0 (cmdbox)\n");
                return 0;
            },
            else => {},
        }
    }
    if (p.operands.items.len == 0) {
        u.err("Usage: whois [OPTION]... OBJECT...\n");
        return 2;
    }
    var query = u.Vec(u8).init(u.alloc);
    for (p.operands.items, 0..) |o, i| {
        if (i > 0) query.push(' ');
        query.pushSlice(o);
    }
    var server: []const u8 = host orelse "whois.iana.org";
    var text = whoisQuery(server, port, query.items) orelse {
        u.errf("whois: connect: {s}\n", .{server});
        return 1;
    };
    u.out(text);
    if (host == null and recurse) {
        var hops: usize = 0;
        while (hops < 3) : (hops += 1) {
            const nxt = referral(text, &.{ "refer:", "whois:", "ReferralServer:", "Registrar WHOIS Server:" }) orelse break;
            if (std.ascii.eqlIgnoreCase(nxt, server)) break;
            server = u.alloc.dupe(u8, nxt) catch break;
            u.outf("\n# whois referral to {s}\n\n", .{server});
            text = whoisQuery(server, port, query.items) orelse break;
            u.out(text);
        }
    }
    return 0;
}

// ===================== telnet =====================
const IAC = 255;
const DONT = 254;
const DO = 253;
const WONT = 252;
const WILL = 251;
const SB = 250;
const SE = 240;

pub fn telnet(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "", .key = 'a' }, .{ .name = "", .key = 'd' }, .{ .name = "", .key = 'E' },
        .{ .name = "", .key = 'e', .arg = .req }, .{ .name = "", .key = 'l', .arg = .req },
        .{ .name = "", .key = 'n', .arg = .req }, .{ .name = "", .key = 'r' }, .{ .name = "", .key = '8' },
        .{ .name = "", .key = 'L' }, .{ .name = "", .key = 'K' }, .{ .name = "", .key = 'x' },
    };
    var p = g.Parser.init("telnet", args, &opts);
    while (p.next() catch return 1) |_| {}
    const ops = p.operands.items;
    if (ops.len == 0 or ops.len > 2) {
        u.err("Usage: telnet [-8ELadr] [-e escape] [-l user] [-n tracefile] [host [port]]\n");
        return 1;
    }
    const host = ops[0];
    var port: u16 = 23;
    if (ops.len == 2) port = std.fmt.parseInt(u16, ops[1], 10) catch blk: {
        u.errf("telnet: {s}: bad port\n", .{ops[1]});
        break :blk 23;
    };
    const ip = n2.resolveA(host) orelse {
        u.errf("{s}: Name or service not known\n", .{host});
        return 1;
    };
    u.outf("Trying {s}...\n", .{n2.fmtIp(ip)});
    const fd = tcpConnect(host, port, 15000) orelse {
        u.errf("telnet: Unable to connect to remote host: Connection refused\n", .{});
        return 1;
    };
    defer _ = linux.close(fd);
    u.outf("Connected to {s}.\nEscape character is '^]'.\n", .{host});
    // terminal into raw mode when stdin is a tty
    const Termios = std.posix.termios;
    var saved: Termios = undefined;
    var have_tty = false;
    if (std.posix.tcgetattr(0)) |t| {
        saved = t;
        have_tty = true;
        var raw = t;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        std.posix.tcsetattr(0, .NOW, raw) catch {};
    } else |_| {}
    defer if (have_tty) std.posix.tcsetattr(0, .NOW, saved) catch {};
    var stdin_open = true;
    var buf: [4096]u8 = undefined;
    var ign = linux.Sigaction{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(linux.SIG.PIPE, &ign, null);
    var state: u8 = 0; // 0 data, 1 IAC, 2 option verb, 3 SB, 4 SB-IAC
    var verb: u8 = 0;
    var sb_data = u.Vec(u8).init(u.alloc);
    while (true) {
        var pfds = [2]linux.pollfd{
            .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = if (stdin_open) 0 else -1, .events = linux.POLL.IN, .revents = 0 },
        };
        // after the end of the input the server gets a short grace period to answer
        const pr = linux.poll(&pfds, 2, if (stdin_open) -1 else 2000);
        if (!u.ok(pr)) {
            if (u.errno(pr) == .INTR) continue;
            break;
        }
        if (pr == 0 and !stdin_open) break;
        if (pfds[0].revents & (linux.POLL.IN | linux.POLL.HUP) != 0) {
            const r = linux.read(fd, &buf, buf.len);
            if (!u.ok(r) or r == 0) {
                if (have_tty) std.posix.tcsetattr(0, .NOW, saved) catch {};
                u.out("Connection closed by foreign host.\n");
                return 0;
            }
            var outb = u.Vec(u8).init(u.alloc);
            var reply = u.Vec(u8).init(u.alloc);
            for (buf[0..r]) |b| {
                switch (state) {
                    0 => if (b == IAC) {
                        state = 1;
                    } else outb.push(b),
                    1 => switch (b) {
                        IAC => {
                            outb.push(IAC);
                            state = 0;
                        },
                        DO, DONT, WILL, WONT => {
                            verb = b;
                            state = 2;
                        },
                        SB => {
                            sb_data.items.len = 0;
                            state = 3;
                        },
                        else => state = 0,
                    },
                    2 => {
                        state = 0;
                        // accept ECHO/SGA from the server, TTYPE/NAWS from us; refuse the rest
                        const accept_remote = b == 1 or b == 3;
                        const accept_local = b == 24 or b == 31 or b == 3;
                        if (verb == WILL) reply.pushSlice(&[_]u8{ IAC, if (accept_remote) DO else DONT, b });
                        if (verb == DO) {
                            reply.pushSlice(&[_]u8{ IAC, if (accept_local) WILL else WONT, b });
                            if (b == 31 and accept_local) {
                                var ws: [8]u8 = @splat(0);
                                _ = linux.ioctl(0, 0x5413, @intFromPtr(&ws));
                                const rows = std.mem.readInt(u16, ws[0..2], .little);
                                const cols = std.mem.readInt(u16, ws[2..4], .little);
                                reply.pushSlice(&[_]u8{ IAC, SB, 31, @intCast(cols >> 8), @intCast(cols & 0xff), @intCast(rows >> 8), @intCast(rows & 0xff), IAC, SE });
                            }
                        }
                    },
                    3 => if (b == IAC) {
                        state = 4;
                    } else sb_data.push(b),
                    else => {
                        if (b == SE) {
                            state = 0;
                            if (sb_data.items.len >= 2 and sb_data.items[0] == 24 and sb_data.items[1] == 1) {
                                reply.pushSlice(&[_]u8{ IAC, SB, 24, 0 });
                                reply.pushSlice(if (std.c.getenv("TERM")) |tv| std.mem.span(tv) else "dumb");
                                reply.pushSlice(&[_]u8{ IAC, SE });
                            }
                        } else state = 3;
                    },
                }
            }
            if (outb.items.len > 0) u.out(outb.items);
            if (reply.items.len > 0) _ = writeAllFd(fd, reply.items);
        }
        if (stdin_open and pfds[1].revents & (linux.POLL.IN | linux.POLL.HUP) != 0) {
            const r = linux.read(0, &buf, buf.len);
            if (!u.ok(r) or r == 0) {
                stdin_open = false;
                continue;
            }
            var send = u.Vec(u8).init(u.alloc);
            for (buf[0..r]) |b| {
                if (b == 0x1d and have_tty) {
                    // escape character: prompt
                    if (have_tty) std.posix.tcsetattr(0, .NOW, saved) catch {};
                    u.out("\ntelnet> ");
                    var cmd = u.Vec(u8).init(u.alloc);
                    var cb: [1]u8 = undefined;
                    while (true) {
                        const cr = linux.read(0, &cb, 1);
                        if (!u.ok(cr) or cr == 0 or cb[0] == '\n') break;
                        cmd.push(cb[0]);
                    }
                    const c0 = std.mem.trim(u8, cmd.items, " \t");
                    if (c0.len == 0) {
                        u.out("\r");
                        break;
                    }
                    if (std.mem.startsWith(u8, "quit", c0) or std.mem.startsWith(u8, "close", c0) or std.mem.startsWith(u8, "exit", c0)) {
                        u.out("Connection closed.\n");
                        return 0;
                    }
                    u.out("?Invalid command\n");
                    continue;
                }
                if (b == IAC) send.pushSlice(&[_]u8{ IAC, IAC }) else if (b == '\n' and have_tty) send.pushSlice("\r\n") else if (b == '\r' and have_tty) send.pushSlice(&[_]u8{ '\r', 0 }) else send.push(b);
            }
            if (send.items.len > 0 and !writeAllFd(fd, send.items)) break;
        }
    }
    return 0;
}

// ===================== traceroute =====================
fn icmpCksum(d: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < d.len) : (i += 2) sum += @as(u32, d[i]) << 8 | d[i + 1];
    if (d.len % 2 == 1) sum += @as(u32, d[d.len - 1]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @intCast(~sum & 0xffff);
}

pub fn traceroute(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "", .key = 'n' }, .{ .name = "", .key = 'I' }, .{ .name = "", .key = 'T' },
        .{ .name = "", .key = 'U' }, .{ .name = "", .key = 'r' }, .{ .name = "", .key = 'v' },
        .{ .name = "", .key = '4' }, .{ .name = "", .key = '6' }, .{ .name = "", .key = 'F' },
        .{ .name = "", .key = 'm', .arg = .req }, .{ .name = "", .key = 'q', .arg = .req },
        .{ .name = "", .key = 'w', .arg = .req }, .{ .name = "", .key = 'f', .arg = .req },
        .{ .name = "", .key = 'p', .arg = .req }, .{ .name = "", .key = 's', .arg = .req },
        .{ .name = "", .key = 'i', .arg = .req }, .{ .name = "", .key = 'z', .arg = .req },
        .{ .name = "", .key = 't', .arg = .req }, .{ .name = "", .key = 'g', .arg = .req },
        .{ .name = "help", .key = 200 }, .{ .name = "version", .key = 201 },
    };
    var p = g.Parser.init("traceroute", args, &opts);
    var numeric = false;
    var icmp_mode = false;
    var max_ttl: u32 = 30;
    var first_ttl: u32 = 1;
    var nq: u32 = 3;
    var wait_s: f64 = 5;
    var port: u16 = 33434;
    var src_arg: ?[]const u8 = null;
    while (p.next() catch return 2) |it| {
        switch (it.key) {
            'n' => numeric = true,
            'I' => icmp_mode = true,
            'm' => max_ttl = std.fmt.parseInt(u32, it.val.?, 10) catch {
                u.errf("traceroute: invalid hops value `{s}' specified\n", .{it.val.?});
                return 2;
            },
            'f' => first_ttl = std.fmt.parseInt(u32, it.val.?, 10) catch 1,
            'q' => nq = std.fmt.parseInt(u32, it.val.?, 10) catch 3,
            'w' => wait_s = std.fmt.parseFloat(f64, it.val.?) catch 5,
            'p' => port = std.fmt.parseInt(u16, it.val.?, 10) catch 33434,
            's' => src_arg = it.val,
            200 => {
                u.out("Usage:\n  traceroute [ -46dFITnreAUDV ] [ -f first_ttl ] [ -g gate,... ] [ -i device ] [ -m max_ttl ] [ -p port ] [ -s src_addr ] [ -q nqueries ] [ -N squeries ] [ -t tos ] [ -l flow_label ] [ -w MAX,HERE,NEAR ] [ -z sendwait ] [ --fwmark=num ] host [ packetlen ]\n");
                return 0;
            },
            201 => {
                u.out("Modern traceroute for Linux, version 2.1.6 (cmdbox)\n");
                return 0;
            },
            else => {},
        }
    }
    if (p.operands.items.len == 0) {
        u.err("Specify \"host\" missing argument.\n");
        return 2;
    }
    const target = p.operands.items[0];
    var plen: usize = 60;
    if (p.operands.items.len > 1) plen = std.fmt.parseInt(usize, p.operands.items[1], 10) catch 60;
    const dst = n2.resolveA(target) orelse {
        u.errf("{s}: Name or service not known\nCannot handle \"host\" cmdline arg `{s}' on position 1 (argc 1)\n", .{ target, target });
        return 2;
    };
    const rs = linux.socket(2, 3, 1); // raw ICMP
    if (!u.ok(rs)) {
        u.errf("traceroute: socket: {s}\n", .{u.strerr(u.errno(rs))});
        return 1;
    }
    const rfd: i32 = @intCast(rs);
    defer _ = linux.close(rfd);
    const us = linux.socket(2, 2, 0);
    if (!u.ok(us)) return 1;
    const ufd: i32 = @intCast(us);
    defer _ = linux.close(ufd);
    if (src_arg) |sa| {
        const sip = n2.resolveA(sa) orelse {
            u.errf("traceroute: bad source address {s}\n", .{sa});
            return 2;
        };
        var bsa: linux.sockaddr.in = .{ .port = 0, .addr = @bitCast(sip) };
        _ = linux.bind(ufd, @ptrCast(&bsa), @sizeOf(linux.sockaddr.in));
    }
    var dsa: linux.sockaddr.in = .{ .port = htons(port), .addr = @bitCast(dst) };
    u.outf("traceroute to {s} ({s}), {d} hops max, {d} byte packets\n", .{ target, n2.fmtIp(dst), max_ttl, plen });
    const payload_len: usize = if (plen > 28) plen - 28 else 0;
    var payload: [1500]u8 = @splat(0x40);
    var seq: u16 = 0;
    const ident: u16 = @intCast(@as(u32, @intCast(linux.getpid())) & 0xffff);
    var ttl = first_ttl;
    var reached = false;
    while (ttl <= max_ttl and !reached) : (ttl += 1) {
        var line = u.Vec(u8).init(u.alloc);
        line.pushSlice(std.fmt.allocPrint(u.alloc, "{d: >2} ", .{ttl}) catch "");
        var last_ip: ?[4]u8 = null;
        var q: u32 = 0;
        while (q < nq) : (q += 1) {
            const tv: c_int = @intCast(ttl);
            _ = linux.setsockopt(ufd, 0, 2, @ptrCast(&tv), 4); // IP_TTL
            seq +%= 1;
            const send_port = port +% seq;
            dsa.port = htons(send_port);
            const t0 = n2.nowUs();
            if (icmp_mode) {
                var pk: [1500]u8 = @splat(0);
                pk[0] = 8;
                std.mem.writeInt(u16, pk[4..6], ident, .big);
                std.mem.writeInt(u16, pk[6..8], seq, .big);
                const tl = 8 + payload_len;
                const ck = icmpCksum(pk[0..tl]);
                std.mem.writeInt(u16, pk[2..4], ck, .big);
                var isa: linux.sockaddr.in = .{ .port = 0, .addr = @bitCast(dst) };
                _ = linux.setsockopt(rfd, 0, 2, @ptrCast(&tv), 4);
                _ = linux.sendto(rfd, &pk, tl, 0, @ptrCast(&isa), @sizeOf(linux.sockaddr.in));
            } else {
                _ = linux.sendto(ufd, &payload, payload_len, 0, @ptrCast(&dsa), @sizeOf(linux.sockaddr.in));
            }
            // wait for the matching ICMP message
            const deadline = t0 + @as(i64, @intFromFloat(wait_s * 1_000_000));
            var got = false;
            while (true) {
                const left = @divTrunc(deadline - n2.nowUs(), 1000);
                if (left <= 0) break;
                var pfd = [1]linux.pollfd{.{ .fd = rfd, .events = linux.POLL.IN, .revents = 0 }};
                const pr = linux.poll(&pfd, 1, @intCast(left));
                if (!u.ok(pr) or pr == 0) break;
                var rb: [1500]u8 = undefined;
                var from: linux.sockaddr.in = undefined;
                var fl: linux.socklen_t = @sizeOf(linux.sockaddr.in);
                const r = linux.recvfrom(rfd, &rb, rb.len, 0, @ptrCast(&from), &fl);
                if (!u.ok(r) or r < 28) continue;
                const ihl: usize = (rb[0] & 0xf) * 4;
                if (r < ihl + 8) continue;
                const itype = rb[ihl];
                const icode = rb[ihl + 1];
                const fip: [4]u8 = @bitCast(from.addr);
                var is_mine = false;
                var is_dest = false;
                if (itype == 11 or itype == 3) {
                    // embedded original datagram
                    const o = ihl + 8;
                    if (r < o + 20) continue;
                    const oihl: usize = (rb[o] & 0xf) * 4;
                    if (r < o + oihl + 8) continue;
                    if (!std.mem.eql(u8, rb[o + 16 .. o + 20], &dst)) continue;
                    if (icmp_mode) {
                        if (rb[o + 9] != 1) continue;
                        const oid = std.mem.readInt(u16, rb[o + oihl + 4 ..][0..2], .big);
                        const oseq = std.mem.readInt(u16, rb[o + oihl + 6 ..][0..2], .big);
                        is_mine = oid == ident and oseq == seq;
                    } else {
                        if (rb[o + 9] != 17) continue;
                        const dport = std.mem.readInt(u16, rb[o + oihl + 2 ..][0..2], .big);
                        is_mine = dport == send_port;
                    }
                    if (itype == 3) is_dest = true;
                } else if (itype == 0 and icmp_mode) {
                    const rid = std.mem.readInt(u16, rb[ihl + 4 ..][0..2], .big);
                    const rseq = std.mem.readInt(u16, rb[ihl + 6 ..][0..2], .big);
                    is_mine = rid == ident and rseq == seq;
                    is_dest = true;
                }
                if (!is_mine) continue;
                const rtt = n2.nowUs() - t0;
                if (last_ip == null or !std.mem.eql(u8, &last_ip.?, &fip)) {
                    if (numeric) line.pushSlice(std.fmt.allocPrint(u.alloc, " {s}", .{n2.fmtIp(fip)}) catch "") else {
                        const nm = n2.reverseName(fip);
                        line.pushSlice(std.fmt.allocPrint(u.alloc, " {s} ({s})", .{ nm orelse n2.fmtIp(fip), n2.fmtIp(fip) }) catch "");
                    }
                    last_ip = fip;
                }
                line.pushSlice(std.fmt.allocPrint(u.alloc, "  {d}.{d:0>3} ms", .{ @as(u64, @intCast(@divTrunc(rtt, 1000))), @as(u64, @intCast(@mod(rtt, 1000))) }) catch "");
                if (itype == 3) {
                    const flag: []const u8 = switch (icode) {
                        0 => " !N",
                        1 => " !H",
                        2 => " !P",
                        3 => "",
                        4 => " !F",
                        5 => " !S",
                        13 => " !X",
                        else => "",
                    };
                    line.pushSlice(flag);
                }
                if (is_dest) reached = true;
                got = true;
                break;
            }
            if (!got) line.pushSlice(" *");
        }
        line.push('\n');
        u.out(line.items);
    }
    return 0;
}

// ===================== ftpput =====================
const FtpRep = struct { code: u32, text: []const u8 };

fn ftpReply(fd: i32, verbose: bool) ?FtpRep {
    var acc = u.Vec(u8).init(u.alloc);
    var buf: [1024]u8 = undefined;
    while (true) {
        // a reply ends with a line "NNN text" (not "NNN-")
        var lines = std.mem.splitScalar(u8, acc.items, '\n');
        var last: []const u8 = "";
        var complete = false;
        while (lines.next()) |l| {
            const lt = std.mem.trimEnd(u8, l, "\r");
            if (lt.len >= 4 and std.ascii.isDigit(lt[0]) and std.ascii.isDigit(lt[1]) and std.ascii.isDigit(lt[2]) and lt[3] == ' ' and lines.peek() != null) {
                last = lt;
                complete = true;
            }
        }
        if (complete) {
            if (verbose) u.err(acc.items);
            return .{ .code = std.fmt.parseInt(u32, last[0..3], 10) catch 0, .text = last[4..] };
        }
        var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        const pr = linux.poll(&pfd, 1, 15000);
        if (!u.ok(pr) or pr == 0) return null;
        const r = linux.read(fd, &buf, buf.len);
        if (!u.ok(r) or r == 0) return null;
        acc.pushSlice(buf[0..r]);
    }
}

fn ftpCmd(fd: i32, verbose: bool, cmd: []const u8) ?FtpRep {
    if (verbose) u.errf("---> {s}\n", .{cmd});
    const m = std.fmt.allocPrint(u.alloc, "{s}\r\n", .{cmd}) catch return null;
    if (!writeAllFd(fd, m)) return null;
    return ftpReply(fd, verbose);
}

pub fn ftpput(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "username", .key = 'u', .arg = .req },
        .{ .name = "password", .key = 'p', .arg = .req },
        .{ .name = "port", .key = 'P', .arg = .req },
        .{ .name = "continue", .key = 'c' },
    };
    var p = g.Parser.init("ftpput", args, &opts);
    var verbose = false;
    var user: []const u8 = "anonymous";
    var pass: []const u8 = "busybox@";
    var port: u16 = 21;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'v' => verbose = true,
            'u' => user = it.val.?,
            'p' => pass = it.val.?,
            'P' => port = std.fmt.parseInt(u16, it.val.?, 10) catch 21,
            else => {},
        }
    }
    const ops = p.operands.items;
    if (ops.len < 2 or ops.len > 3) {
        u.err("Usage: ftpput [OPTIONS] HOST [REMOTE_FILE] LOCAL_FILE\n\nStore a local file on a remote machine via FTP\n\n\t-v,--verbose\t\tVerbose\n\t-u,--username USER\tUsername\n\t-p,--password PASS\tPassword\n\t-P,--port NUM\t\tPort\n");
        return 1;
    }
    const host = ops[0];
    const local = ops[ops.len - 1];
    const remote = if (ops.len == 3) ops[1] else std.fs.path.basename(local);
    const fd = tcpConnect(host, port, 15000) orelse {
        u.errf("ftpput: can't connect to remote host ({s}:{d}): Connection refused\n", .{ host, port });
        return 1;
    };
    defer _ = linux.close(fd);
    const greet = ftpReply(fd, verbose) orelse return 1;
    if (greet.code != 220) {
        u.errf("ftpput: unexpected server response to (null): {d} {s}\n", .{ greet.code, greet.text });
        return 1;
    }
    var rep = ftpCmd(fd, verbose, std.fmt.allocPrint(u.alloc, "USER {s}", .{user}) catch return 1) orelse return 1;
    if (rep.code == 331) {
        rep = ftpCmd(fd, verbose, std.fmt.allocPrint(u.alloc, "PASS {s}", .{pass}) catch return 1) orelse return 1;
    }
    if (rep.code != 230) {
        u.errf("ftpput: unexpected server response to PASS: {d} {s}\n", .{ rep.code, rep.text });
        return 1;
    }
    rep = ftpCmd(fd, verbose, "TYPE I") orelse return 1;
    rep = ftpCmd(fd, verbose, "PASV") orelse return 1;
    if (rep.code != 227) {
        u.errf("ftpput: unexpected server response to PASV: {d} {s}\n", .{ rep.code, rep.text });
        return 1;
    }
    const lp = std.mem.indexOfScalar(u8, rep.text, '(') orelse return 1;
    const rp = std.mem.indexOfScalarPos(u8, rep.text, lp, ')') orelse return 1;
    var nums: [6]u16 = undefined;
    var it2 = std.mem.splitScalar(u8, rep.text[lp + 1 .. rp], ',');
    var ni: usize = 0;
    while (it2.next()) |x| {
        if (ni >= 6) break;
        nums[ni] = std.fmt.parseInt(u16, std.mem.trim(u8, x, " "), 10) catch 0;
        ni += 1;
    }
    if (ni != 6) return 1;
    const dport: u16 = nums[4] * 256 + nums[5];
    const dhost = std.fmt.allocPrint(u.alloc, "{d}.{d}.{d}.{d}", .{ nums[0], nums[1], nums[2], nums[3] }) catch return 1;
    const dfd = tcpConnect(dhost, dport, 15000) orelse {
        u.err("ftpput: can't connect to data port\n");
        return 1;
    };
    rep = ftpCmd(fd, verbose, std.fmt.allocPrint(u.alloc, "STOR {s}", .{remote}) catch return 1) orelse return 1;
    if (rep.code != 150 and rep.code != 125) {
        u.errf("ftpput: unexpected server response to STOR: {d} {s}\n", .{ rep.code, rep.text });
        _ = linux.close(dfd);
        return 1;
    }
    var src_fd: i32 = 0;
    if (!std.mem.eql(u8, local, "-")) {
        const frc = linux.open(u.zstr(local), .{ .ACCMODE = .RDONLY }, 0);
        if (!u.ok(frc)) {
            u.errf("ftpput: can't open '{s}': {s}\n", .{ local, u.strerr(u.errno(frc)) });
            _ = linux.close(dfd);
            return 1;
        }
        src_fd = @intCast(frc);
    }
    var fb: [8192]u8 = undefined;
    while (true) {
        const r = linux.read(src_fd, &fb, fb.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r) or r == 0) break;
        if (!writeAllFd(dfd, fb[0..r])) break;
    }
    if (src_fd != 0) _ = linux.close(src_fd);
    _ = linux.close(dfd);
    rep = ftpReply(fd, verbose) orelse return 1;
    if (rep.code != 226) {
        u.errf("ftpput: unexpected server response after transfer: {d} {s}\n", .{ rep.code, rep.text });
        return 1;
    }
    _ = ftpCmd(fd, verbose, "QUIT");
    return 0;
}

// ===================== ntpd (SNTP) =====================
const NTP_UNIX_OFFSET: i64 = 2208988800;

fn ntpNowNs() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

fn ntpToNs(sec: u32, frac: u32) i128 {
    const s: i128 = @as(i128, sec) - NTP_UNIX_OFFSET;
    const f: i128 = (@as(i128, frac) * 1_000_000_000) >> 32;
    return s * 1_000_000_000 + f;
}

fn nsToNtp(ns: i128, sec: *u32, frac: *u32) void {
    const s = @divFloor(ns, 1_000_000_000) + NTP_UNIX_OFFSET;
    const f = @mod(ns, 1_000_000_000);
    sec.* = @intCast(s & 0xffffffff);
    frac.* = @intCast(@divTrunc(f << 32, 1_000_000_000));
}

const NtpSample = struct { offset_ns: i128, delay_ns: i128, stratum: u8 };

fn ntpQuery(host: []const u8, port: u16, timeout_ms: i32) ?NtpSample {
    const ip = n2.resolveA(host) orelse return null;
    const s = linux.socket(2, 2, 0);
    if (!u.ok(s)) return null;
    const fd: i32 = @intCast(s);
    defer _ = linux.close(fd);
    var pkt: [48]u8 = @splat(0);
    pkt[0] = (0 << 6) | (4 << 3) | 3; // LI 0, VN 4, mode client
    const t1 = ntpNowNs();
    var sec: u32 = 0;
    var frac: u32 = 0;
    nsToNtp(t1, &sec, &frac);
    std.mem.writeInt(u32, pkt[40..44], sec, .big);
    std.mem.writeInt(u32, pkt[44..48], frac, .big);
    var sa: linux.sockaddr.in = .{ .port = htons(port), .addr = @bitCast(ip) };
    const w = linux.sendto(fd, &pkt, pkt.len, 0, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
    if (!u.ok(w)) return null;
    var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    const pr = linux.poll(&pfd, 1, timeout_ms);
    if (!u.ok(pr) or pr == 0) return null;
    var rb: [128]u8 = undefined;
    const r = linux.recvfrom(fd, &rb, rb.len, 0, null, null);
    const t4 = ntpNowNs();
    if (!u.ok(r) or r < 48) return null;
    const mode = rb[0] & 7;
    if (mode != 4 and mode != 5) return null;
    if (rb[0] >> 6 == 3) return null; // unsynchronised
    if (rb[1] == 0) return null; // kiss-o'-death
    // originate timestamp must echo our transmit time
    if (!std.mem.eql(u8, rb[24..32], pkt[40..48])) return null;
    const t2 = ntpToNs(std.mem.readInt(u32, rb[32..36], .big), std.mem.readInt(u32, rb[36..40], .big));
    const t3 = ntpToNs(std.mem.readInt(u32, rb[40..44], .big), std.mem.readInt(u32, rb[44..48], .big));
    const offset = @divFloor((t2 - t1) + (t3 - t4), 2);
    const delay = (t4 - t1) - (t3 - t2);
    return .{ .offset_ns = offset, .delay_ns = delay, .stratum = rb[1] };
}

pub fn ntpd(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "", .key = 'n' }, .{ .name = "", .key = 'N' }, .{ .name = "", .key = 'd' }, .{ .name = "", .key = 'q' },
        .{ .name = "", .key = 'w' }, .{ .name = "", .key = 'l' }, .{ .name = "", .key = 'S', .arg = .req },
        .{ .name = "", .key = 'p', .arg = .req }, .{ .name = "", .key = 'P', .arg = .req }, .{ .name = "", .key = 'I', .arg = .req },
        .{ .name = "", .key = 'x' },
    };
    var p = g.Parser.init("ntpd", args, &opts);
    var foreground = false;
    var once = false;
    var verbose = false;
    var peers = u.Vec([]const u8).init(u.alloc);
    var port: u16 = 123;
    var script: ?[]const u8 = null;
    while (p.next() catch {
        u.err("Usage: ntpd [-dnqNwl] [-S PROG] [-p PEER]...\n\nNTP client/server\n\n\t-d\tVerbose\n\t-n\tDo not daemonize\n\t-q\tQuit after clock is set\n\t-N\tRun at high priority\n\t-w\tDo not set time (only query peers), implies -n\n\t-S PROG\tRun PROG after stepping time, stratum change, and every 11 mins\n\t-p PEER\tObtain time from PEER (may be repeated)\n\t-l\tAlso run as server on port 123\n\t-I IFACE\tBind server to IFACE\n\t-x\tSlew only\n");
        return 1;
    }) |it| {
        switch (it.key) {
            'n' => foreground = true,
            'q' => once = true,
            'd' => verbose = true,
            'w' => {
                foreground = true;
                once = true;
            },
            'p' => {
                const v = it.val.?;
                if (std.mem.lastIndexOfScalar(u8, v, ':')) |c0| {
                    peers.push(v[0..c0]);
                    port = std.fmt.parseInt(u16, v[c0 + 1 ..], 10) catch 123;
                } else peers.push(v);
            },
            'S' => script = it.val,
            else => {},
        }
    }
    for (p.operands.items) |o| peers.push(o);
    if (peers.items.len == 0) {
        u.err("ntpd: no peers specified\n");
        return 1;
    }
    var no_set = false;
    for (args) |a| if (std.mem.eql(u8, a, "-w")) {
        no_set = true;
    };
    if (!foreground and !once) {
        const pid = linux.fork();
        if (!u.ok(pid)) return 1;
        if (pid != 0) return 0;
        _ = linux.setsid();
    }
    var synced = false;
    var attempt: u32 = 0;
    while (true) {
        var best: ?NtpSample = null;
        for (peers.items) |peer| {
            var k: u32 = 0;
            while (k < 3 and best == null or k < 1) : (k += 1) {
                if (ntpQuery(peer, port, 2000)) |smp| {
                    if (verbose) u.errf("ntpd: response from {s}: offset {d}.{d:0>6}s delay {d}us stratum {d}\n", .{ peer, @as(i64, @intCast(@divTrunc(smp.offset_ns, 1_000_000_000))), @as(u64, @intCast(@divTrunc(@abs(@mod(smp.offset_ns, 1_000_000_000)), 1000))), @as(i64, @intCast(@divTrunc(smp.delay_ns, 1000))), smp.stratum });
                    if (best == null or smp.delay_ns < best.?.delay_ns) best = smp;
                    break;
                }
            }
        }
        if (best) |smp| {
            const off = smp.offset_ns;
            const abs_off = if (off < 0) -off else off;
            if (!no_set) {
                if (abs_off > 128_000_000 or !synced) {
                    // step
                    const now = ntpNowNs() + off;
                    var ts: linux.timespec = .{ .sec = @intCast(@divFloor(now, 1_000_000_000)), .nsec = @intCast(@mod(now, 1_000_000_000)) };
                    const rc = linux.clock_settime(.REALTIME, &ts);
                    if (u.ok(rc)) {
                        u.errf("ntpd: setting clock to offset {d}.{d:0>6}s\n", .{ @as(i64, @intCast(@divTrunc(off, 1_000_000_000))), @as(u64, @intCast(@divTrunc(@abs(@mod(off, 1_000_000_000)), 1000))) });
                        if (script) |sc| runNtpScript(sc, smp.stratum);
                    } else u.errf("ntpd: can't set time: {s}\n", .{u.strerr(u.errno(rc))});
                } else {
                    // small offset: slew with adjtime
                    var tx = std.mem.zeroes(ct.struct_timex);
                    tx.modes = 0x0001; // ADJ_OFFSET
                    tx.offset = @intCast(@divTrunc(off, 1000));
                    _ = ct.adjtimex(&tx);
                }
            } else {
                u.outf("{s}{d}.{d:0>6}\n", .{ if (off < 0) "-" else "+", @as(u64, @intCast(@divTrunc(abs_off, 1_000_000_000))), @as(u64, @intCast(@divTrunc(@mod(abs_off, 1_000_000_000), 1000))) });
            }
            synced = true;
            if (once) return 0;
        } else {
            attempt += 1;
            if (once) {
                u.err("ntpd: no reply from any peer\n");
                return 1;
            }
        }
        var sl: linux.timespec = .{ .sec = if (synced) 64 else 8, .nsec = 0 };
        _ = linux.nanosleep(&sl, null);
    }
}

fn runNtpScript(script: []const u8, stratum: u8) void {
    const pid = linux.fork();
    if (!u.ok(pid) or pid != 0) {
        if (u.ok(pid)) {
            var st: u32 = 0;
            _ = linux.wait4(@intCast(pid), &st, 0, null);
        }
        return;
    }
    u.setEnv("stratum", std.fmt.allocPrint(u.alloc, "{d}", .{stratum}) catch "");
    u.setEnv("freq_drift_ppm", "0");
    u.setEnv("poll_interval", "64");
    var av = [_]?[*:0]const u8{ u.zstr(script).ptr, "step", null };
    _ = linux.execve(u.zstr(script).ptr, @ptrCast(&av), u.envp(&.{}));
    linux.exit_group(127);
}
