// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// ifconfig / route / netstat - net-tools 2.10 compatible output and options
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");

// ---------------------------------------------------------------- helpers
fn readFile(path: []const u8) ?[]u8 {
    const rc = linux.open(u.zstr(path), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(rc)) return null;
    defer _ = linux.close(@intCast(rc));
    var data = u.Vec(u8).init(u.alloc);
    var buf: [1 << 15]u8 = undefined;
    while (true) {
        const r = linux.read(@intCast(rc), &buf, buf.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r)) return null;
        if (r == 0) break;
        data.pushSlice(buf[0..r]);
    }
    return data.items;
}

fn readTrim(path: []const u8) []const u8 {
    const d = readFile(path) orelse return "";
    return std.mem.trim(u8, d, " \n\t");
}

fn readNum(path: []const u8) u64 {
    return std.fmt.parseInt(u64, readTrim(path), 10) catch 0;
}

fn ipv4(v: u32, buf: *[16]u8) []const u8 {
    // v is in network byte order as stored by the kernel on little-endian hosts
    const b: [4]u8 = @bitCast(v);
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }) catch "";
}

fn parseIpv4(s: []const u8) ?u32 {
    var parts: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    var n: usize = 0;
    while (it.next()) |p| {
        if (n >= 4) return null;
        parts[n] = std.fmt.parseInt(u8, p, 10) catch return null;
        n += 1;
    }
    if (n != 4) return null;
    return @bitCast(parts);
}

fn maskFromPrefix(p: u6) u32 {
    if (p == 0) return 0;
    const m: u32 = if (p >= 32) 0xFFFFFFFF else ~(@as(u32, 0xFFFFFFFF) >> @intCast(p));
    return @byteSwap(m);
}

const Hosts = struct { ip: u32, name: []const u8 };

fn loadHosts() []Hosts {
    var out = u.Vec(Hosts).init(u.alloc);
    const d = readFile("/etc/hosts") orelse return out.items;
    var lines = std.mem.splitScalar(u8, d, '\n');
    while (lines.next()) |l0| {
        const l = if (std.mem.indexOfScalar(u8, l0, '#')) |i| l0[0..i] else l0;
        var it = std.mem.tokenizeAny(u8, l, " \t");
        const a = it.next() orelse continue;
        const ip = parseIpv4(a) orelse continue;
        const nm = it.next() orelse continue;
        out.push(.{ .ip = ip, .name = nm });
    }
    return out.items;
}

fn serviceName(port: u16, proto: []const u8) ?[]const u8 {
    const d = readFile("/etc/services") orelse return null;
    var lines = std.mem.splitScalar(u8, d, '\n');
    while (lines.next()) |l0| {
        const l = if (std.mem.indexOfScalar(u8, l0, '#')) |i| l0[0..i] else l0;
        var it = std.mem.tokenizeAny(u8, l, " \t");
        const nm = it.next() orelse continue;
        const pp = it.next() orelse continue;
        const slash = std.mem.indexOfScalar(u8, pp, '/') orelse continue;
        if (!std.mem.eql(u8, pp[slash + 1 ..], proto)) continue;
        if ((std.fmt.parseInt(u16, pp[0..slash], 10) catch continue) == port) return nm;
    }
    return null;
}

// ---------------------------------------------------------------- interface data
const IfStat = struct {
    name: []const u8,
    rx_bytes: u64 = 0,
    rx_packets: u64 = 0,
    rx_errs: u64 = 0,
    rx_drop: u64 = 0,
    rx_fifo: u64 = 0,
    rx_frame: u64 = 0,
    tx_bytes: u64 = 0,
    tx_packets: u64 = 0,
    tx_errs: u64 = 0,
    tx_drop: u64 = 0,
    tx_fifo: u64 = 0,
    tx_colls: u64 = 0,
    tx_carrier: u64 = 0,
};

fn loadIfStats() []IfStat {
    var out = u.Vec(IfStat).init(u.alloc);
    const d = readFile("/proc/net/dev") orelse return out.items;
    var lines = std.mem.splitScalar(u8, d, '\n');
    _ = lines.next();
    _ = lines.next();
    while (lines.next()) |l| {
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        const name = std.mem.trim(u8, l[0..colon], " ");
        var it = std.mem.tokenizeScalar(u8, l[colon + 1 ..], ' ');
        var v: [16]u64 = [_]u64{0} ** 16;
        var i: usize = 0;
        while (it.next()) |t| : (i += 1) {
            if (i >= 16) break;
            v[i] = std.fmt.parseInt(u64, t, 10) catch 0;
        }
        out.push(.{ .name = name, .rx_bytes = v[0], .rx_packets = v[1], .rx_errs = v[2], .rx_drop = v[3], .rx_fifo = v[4], .rx_frame = v[5], .tx_bytes = v[8], .tx_packets = v[9], .tx_errs = v[10], .tx_drop = v[11], .tx_fifo = v[12], .tx_colls = v[13], .tx_carrier = v[14] });
    }
    return out.items;
}

const IFF_UP: u32 = 1;
const IFF_BROADCAST: u32 = 2;
const IFF_DEBUG: u32 = 4;
const IFF_LOOPBACK: u32 = 8;
const IFF_POINTOPOINT: u32 = 0x10;
const IFF_NOTRAILERS: u32 = 0x20;
const IFF_RUNNING: u32 = 0x40;
const IFF_NOARP: u32 = 0x80;
const IFF_PROMISC: u32 = 0x100;
const IFF_ALLMULTI: u32 = 0x200;
const IFF_MASTER: u32 = 0x400;
const IFF_SLAVE: u32 = 0x800;
const IFF_MULTICAST: u32 = 0x1000;

const flag_names = [_][]const u8{ "UP", "BROADCAST", "DEBUG", "LOOPBACK", "POINTOPOINT", "NOTRAILERS", "RUNNING", "NOARP", "PROMISC", "ALLMULTI", "MASTER", "SLAVE", "MULTICAST", "PORTSEL", "AUTOMEDIA", "DYNAMIC" };

const IFREQ = extern struct { name: [16]u8 = [_]u8{0} ** 16, data: [24]u8 = [_]u8{0} ** 24 };

fn sock() i32 {
    const fd = linux.socket(2, 2, 0);
    return if (u.ok(fd)) @intCast(fd) else -1;
}

fn ifr(name: []const u8) IFREQ {
    var r = IFREQ{};
    @memcpy(r.name[0..@min(name.len, 15)], name[0..@min(name.len, 15)]);
    return r;
}

fn ioc(fd: i32, req: u32, r: *IFREQ) bool {
    return u.ok(linux.ioctl(fd, req, @intFromPtr(r)));
}

fn humanBytes(n: u64) []const u8 {
    var short: u64 = n * 10;
    var ext: []const u8 = "B";
    if (n > 1125899906842624) {
        short = n * 10 / 1125899906842624;
        ext = "PiB";
    } else if (n > 1099511627776) {
        short = n * 10 / 1099511627776;
        ext = "TiB";
    } else if (n > 1073741824) {
        short = n * 10 / 1073741824;
        ext = "GiB";
    } else if (n > 1048576) {
        short = n * 10 / 1048576;
        ext = "MiB";
    } else if (n > 1024) {
        short = n * 10 / 1024;
        ext = "KiB";
    }
    return std.fmt.allocPrint(u.alloc, "{d}.{d} {s}", .{ short / 10, short % 10, ext }) catch "";
}

const HwType = struct { token: []const u8, text: []const u8 };

fn hwType(t: u32) HwType {
    return switch (t) {
        1 => .{ .token = "ether", .text = "Ethernet" },
        772 => .{ .token = "loop", .text = "Local Loopback" },
        512 => .{ .token = "ppp", .text = "Point-to-Point Protocol" },
        768 => .{ .token = "tunnel", .text = "IPIP Tunnel" },
        776 => .{ .token = "sit", .text = "IPv6-in-IPv4" },
        32 => .{ .token = "infiniband", .text = "InfiniBand" },
        6 => .{ .token = "ether", .text = "Ethernet" },
        24 => .{ .token = "irda", .text = "IrLAP" },
        else => .{ .token = "unspec", .text = "UNSPEC" },
    };
}

const AddrV6 = struct { addr: [16]u8, prefix: u32, scope: u32, name: []const u8 };

fn loadV6() []AddrV6 {
    var out = u.Vec(AddrV6).init(u.alloc);
    const d = readFile("/proc/net/if_inet6") orelse return out.items;
    var lines = std.mem.splitScalar(u8, d, '\n');
    while (lines.next()) |l| {
        var it = std.mem.tokenizeScalar(u8, l, ' ');
        const a = it.next() orelse continue;
        _ = it.next();
        const plen = it.next() orelse continue;
        const scope = it.next() orelse continue;
        _ = it.next();
        const nm = it.next() orelse continue;
        if (a.len != 32) continue;
        var addr: [16]u8 = undefined;
        for (0..16) |i| addr[i] = std.fmt.parseInt(u8, a[i * 2 .. i * 2 + 2], 16) catch 0;
        out.push(.{ .addr = addr, .prefix = std.fmt.parseInt(u32, plen, 16) catch 0, .scope = std.fmt.parseInt(u32, scope, 16) catch 0, .name = nm });
    }
    return out.items;
}

fn fmtV6(a: [16]u8) []const u8 {
    var groups: [8]u16 = undefined;
    for (0..8) |i| groups[i] = (@as(u16, a[i * 2]) << 8) | a[i * 2 + 1];
    // longest run of zero groups (length >= 2) is compressed
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

fn scopeName(s: u32) []const u8 {
    return switch (s) {
        0x00 => "global",
        0x10 => "host",
        0x20 => "link",
        0x40 => "site",
        0x80 => "compat",
        else => "unknown",
    };
}

// ---------------------------------------------------------------- ifconfig
fn showOne(fd: i32, name: []const u8, st: ?IfStat, v6: []const AddrV6, out: *u.Vec(u8)) bool {
    var r = ifr(name);
    if (!ioc(fd, 0x8913, &r)) return false; // SIOCGIFFLAGS
    const flags: u32 = std.mem.readInt(u16, r.data[0..2], .little);
    var mtu: u32 = 0;
    var r2 = ifr(name);
    if (ioc(fd, 0x8921, &r2)) mtu = std.mem.readInt(u32, r2.data[0..4], .little);
    out.pushSlice(std.fmt.allocPrint(u.alloc, "{s}: flags={d}<", .{ name, flags }) catch "");
    var first = true;
    for (flag_names, 0..) |fnm, bit| if (flags & (@as(u32, 1) << @intCast(bit)) != 0) {
        if (!first) out.push(',');
        out.pushSlice(fnm);
        first = false;
    };
    out.pushSlice(">  ");
    out.pushSlice(std.fmt.allocPrint(u.alloc, "mtu {d}", .{mtu}) catch "");
    var rm = ifr(name);
    if (ioc(fd, 0x8943, &rm)) { // SIOCGIFMETRIC
        const metric = std.mem.readInt(u32, rm.data[0..4], .little);
        if (metric > 1) out.pushSlice(std.fmt.allocPrint(u.alloc, "  metric {d}", .{metric}) catch "");
    }
    out.push('\n');
    // IPv4
    var ra = ifr(name);
    if (ioc(fd, 0x8915, &ra)) {
        var b1: [16]u8 = undefined;
        const addr = std.mem.readInt(u32, ra.data[4..8], .little);
        out.pushSlice(std.fmt.allocPrint(u.alloc, "        inet {s}", .{ipv4(addr, &b1)}) catch "");
        var rn = ifr(name);
        if (ioc(fd, 0x891b, &rn)) {
            var b2: [16]u8 = undefined;
            out.pushSlice(std.fmt.allocPrint(u.alloc, "  netmask {s}", .{ipv4(std.mem.readInt(u32, rn.data[4..8], .little), &b2)}) catch "");
        }
        if (flags & IFF_POINTOPOINT != 0) {
            var rd = ifr(name);
            if (ioc(fd, 0x8917, &rd)) {
                var b3: [16]u8 = undefined;
                out.pushSlice(std.fmt.allocPrint(u.alloc, "  destination {s}", .{ipv4(std.mem.readInt(u32, rd.data[4..8], .little), &b3)}) catch "");
            }
        }
        if (flags & IFF_BROADCAST != 0) {
            var rb = ifr(name);
            if (ioc(fd, 0x8919, &rb)) {
                const bc = std.mem.readInt(u32, rb.data[4..8], .little);
                if (bc != 0) {
                    var b4: [16]u8 = undefined;
                    out.pushSlice(std.fmt.allocPrint(u.alloc, "  broadcast {s}", .{ipv4(bc, &b4)}) catch "");
                }
            }
        }
        out.push('\n');
    }
    // aliases do not show anything else
    if (std.mem.indexOfScalar(u8, name, ':') != null) {
        out.push('\n');
        return true;
    }
    for (v6) |a| if (std.mem.eql(u8, a.name, name)) {
        out.pushSlice(std.fmt.allocPrint(u.alloc, "        inet6 {s}  prefixlen {d}  scopeid 0x{x}<{s}>\n", .{ fmtV6(a.addr), a.prefix, a.scope, scopeName(a.scope) }) catch "");
    };
    // link layer
    const sysbase = std.fmt.allocPrint(u.alloc, "/sys/class/net/{s}", .{name}) catch "";
    const arphrd: u32 = @intCast(readNum(std.fmt.allocPrint(u.alloc, "{s}/type", .{sysbase}) catch ""));
    const ht = hwType(arphrd);
    const mac = readTrim(std.fmt.allocPrint(u.alloc, "{s}/address", .{sysbase}) catch "");
    const qlen = readNum(std.fmt.allocPrint(u.alloc, "{s}/tx_queue_len", .{sysbase}) catch "");
    if (arphrd == 772) {
        out.pushSlice(std.fmt.allocPrint(u.alloc, "        loop  txqueuelen {d}  ({s})\n", .{ qlen, ht.text }) catch "");
    } else if (std.mem.eql(u8, ht.token, "ether") and mac.len > 0) {
        out.pushSlice(std.fmt.allocPrint(u.alloc, "        ether {s}  txqueuelen {d}  ({s})\n", .{ mac, qlen, ht.text }) catch "");
    } else if (mac.len > 0 and !std.mem.eql(u8, ht.token, "ppp")) {
        var up = u.Vec(u8).init(u.alloc);
        for (mac) |ch| up.push(if (ch == ':') '-' else std.ascii.toUpper(ch));
        out.pushSlice(std.fmt.allocPrint(u.alloc, "        {s} {s}  txqueuelen {d}  ({s})\n", .{ ht.token, up.items, qlen, ht.text }) catch "");
    } else {
        out.pushSlice(std.fmt.allocPrint(u.alloc, "        {s}  txqueuelen {d}  ({s})\n", .{ ht.token, qlen, ht.text }) catch "");
    }
    if (st) |s| {
        out.pushSlice(std.fmt.allocPrint(u.alloc, "        RX packets {d}  bytes {d} ({s})\n", .{ s.rx_packets, s.rx_bytes, humanBytes(s.rx_bytes) }) catch "");
        out.pushSlice(std.fmt.allocPrint(u.alloc, "        RX errors {d}  dropped {d}  overruns {d}  frame {d}\n", .{ s.rx_errs, s.rx_drop, s.rx_fifo, s.rx_frame }) catch "");
        out.pushSlice(std.fmt.allocPrint(u.alloc, "        TX packets {d}  bytes {d} ({s})\n", .{ s.tx_packets, s.tx_bytes, humanBytes(s.tx_bytes) }) catch "");
        out.pushSlice(std.fmt.allocPrint(u.alloc, "        TX errors {d}  dropped {d} overruns {d}  carrier {d}  collisions {d}\n", .{ s.tx_errs, s.tx_drop, s.tx_fifo, s.tx_carrier, s.tx_colls }) catch "");
    }
    out.push('\n');
    return true;
}

fn ifaceNames() [][]const u8 {
    // /proc/net/dev order, with labelled aliases (eth0:1) inserted after their device
    var names = u.Vec([]const u8).init(u.alloc);
    for (loadIfStats()) |s| names.push(s.name);
    const fd = sock();
    if (fd < 0) return names.items;
    defer _ = linux.close(fd);
    var buf: [40 * 64]u8 = undefined;
    const IfConf = extern struct { len: i32, pad: i32 = 0, ptr: usize };
    var conf = IfConf{ .len = buf.len, .ptr = @intFromPtr(&buf) };
    if (!u.ok(linux.ioctl(fd, 0x8912, @intFromPtr(&conf)))) return names.items;
    const n: usize = @intCast(@divTrunc(conf.len, 40));
    var aliases = u.Vec([]const u8).init(u.alloc);
    for (0..n) |i| {
        const nm = std.mem.sliceTo(buf[i * 40 .. i * 40 + 16], 0);
        if (std.mem.indexOfScalar(u8, nm, ':') != null) {
            var dup = false;
            for (aliases.items) |a| if (std.mem.eql(u8, a, nm)) {
                dup = true;
            };
            if (!dup) aliases.push(u.alloc.dupe(u8, nm) catch continue);
        }
    }
    var out = u.Vec([]const u8).init(u.alloc);
    for (names.items) |nm| {
        out.push(nm);
        for (aliases.items) |a| if (std.mem.startsWith(u8, a, nm) and a.len > nm.len and a[nm.len] == ':') out.push(a);
    }
    return out.items;
}

fn shortTable(stats: []const IfStat, only_up: bool, fd: i32) void {
    var o = u.Vec(u8).init(u.alloc);
    o.pushSlice("Iface      MTU    RX-OK RX-ERR RX-DRP RX-OVR    TX-OK TX-ERR TX-DRP TX-OVR Flg\n");
    for (stats) |s| {
        var r = ifr(s.name);
        var flags: u32 = 0;
        var mtu: u32 = 0;
        if (ioc(fd, 0x8913, &r)) flags = std.mem.readInt(u16, r.data[0..2], .little);
        if (only_up and flags & IFF_UP == 0) continue;
        var r2 = ifr(s.name);
        if (ioc(fd, 0x8921, &r2)) mtu = std.mem.readInt(u32, r2.data[0..4], .little);
        o.pushSlice(std.fmt.allocPrint(u.alloc, "{s: <5} {d: >8} {d: >8} {d: >6} {d: >6} {d: <6} {d: >8} {d: >6} {d: >6} {d: >6} {s}\n", .{ s.name, mtu, s.rx_packets, s.rx_errs, s.rx_drop, s.rx_fifo, s.tx_packets, s.tx_errs, s.tx_drop, s.tx_fifo, ifFlagLetters(flags) }) catch "");
    }
    u.out(o.items);
}

fn ifFlagLetters(f: u32) []const u8 {
    var o = u.Vec(u8).init(u.alloc);
    if (f & IFF_ALLMULTI != 0) o.push('A');
    if (f & IFF_BROADCAST != 0) o.push('B');
    if (f & IFF_DEBUG != 0) o.push('D');
    if (f & IFF_LOOPBACK != 0) o.push('L');
    if (f & IFF_MULTICAST != 0) o.push('M');
    if (f & IFF_NOTRAILERS != 0) o.push('N');
    if (f & IFF_NOARP != 0) o.push('O');
    if (f & IFF_POINTOPOINT != 0) o.push('P');
    if (f & IFF_PROMISC != 0) o.push('p');
    if (f & IFF_SLAVE != 0) o.push('s');
    if (f & IFF_MASTER != 0) o.push('m');
    if (f & IFF_RUNNING != 0) o.push('R');
    if (f & IFF_UP != 0) o.push('U');
    return o.items;
}

const SockAddrIn = extern struct { family: u16 = 2, port: u16 = 0, addr: u32 = 0, zero: [8]u8 = [_]u8{0} ** 8 };

fn setAddr(fd: i32, name: []const u8, req: u32, ip: u32) bool {
    var r = ifr(name);
    const sa = SockAddrIn{ .addr = ip };
    @memcpy(r.data[0..16], std.mem.asBytes(&sa)[0..16]);
    return ioc(fd, req, &r);
}

fn ifconfigErr(what: []const u8) u8 {
    u.errf("SIOC{s}: {s}\n", .{ what, "Operation failed" });
    return 255;
}

fn errnoText(what: []const u8) void {
    u.errf("{s}\n", .{what});
}

const help_text = "Usage:\n  ifconfig [-a] [-v] [-s] <interface> [[<AF>] <address>]\n  [add <address>[/<prefixlen>]]\n  [del <address>[/<prefixlen>]]\n  [[-]broadcast [<address>]]  [[-]pointopoint [<address>]]\n  [netmask <address>]  [dstaddr <address>]  [tunnel <address>]\n  [outfill <NN>] [keepalive <NN>]\n  [hw <HW> <address>]  [metric <NN>]  [mtu <NN>]\n  [[-]trailers]  [[-]arp]  [[-]allmulti]\n  [multicast]  [[-]promisc]\n  [mem_start <NN>]  [io_addr <NN>]  [irq <NN>]  [media <type>]\n  [txqueuelen <NN>]\n  [[-]dynamic]\n  [up|down] ...\n\n  <HW>=Hardware Type.\n  List of possible hardware types:\n    loop (Local Loopback) slip (Serial Line IP) cslip (VJ Serial Line IP)\n    slip6 (6-bit Serial Line IP) cslip6 (VJ 6-bit Serial Line IP) adaptive (Adaptive Serial Line IP)\n    ash (Ash) ether (Ethernet) ax25 (AMPR AX.25)\n    netrom (AMPR NET/ROM) rose (AMPR ROSE) tunnel (IPIP Tunnel)\n    ppp (Point-to-Point Protocol) hdlc ((Cisco)-HDLC) lapb (LAPB)\n    arcnet (ARCnet) dlci (Frame Relay DLCI) frad (Frame Relay Access Device)\n    sit (IPv6-in-IPv4) fddi (Fiber Distributed Data Interface) hippi (HIPPI)\n    irda (IrLAP) ec (Econet) x25 (generic X.25)\n    infiniband (InfiniBand) eui64 (Generic EUI-64)\n  <AF>=Address family. Default: inet\n  List of possible address families:\n    unix (UNIX Domain) inet (DARPA Internet) inet6 (IPv6)\n    ax25 (AMPR AX.25) netrom (AMPR NET/ROM) rose (AMPR ROSE)\n    ipx (Novell IPX) ddp (Appletalk DDP) ec (Econet)\n    ash (Ash) x25 (CCITT X.25)\n";

pub fn ifconfig(args: []const []const u8) u8 {
    var all = false;
    var short = false;
    var rest = u.Vec([]const u8).init(u.alloc);
    for (args) |a| {
        if (a.len > 1 and a[0] == '-' and rest.items.len == 0) {
            if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
                u.err(help_text);
                return 0;
            }
            if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) {
                u.out("net-tools 2.10\n");
                return 0;
            }
            var ok = true;
            for (a[1..]) |ch| switch (ch) {
                'a' => all = true,
                's' => short = true,
                'v' => {},
                else => ok = false,
            };
            if (ok) continue;
        }
        rest.push(a);
    }
    const fd = sock();
    if (fd < 0) {
        u.err("ifconfig: socket: cannot create socket\n");
        return 255;
    }
    defer _ = linux.close(fd);
    if (short) {
        shortTable(loadIfStats(), !all, fd);
        return 0;
    }
    var out = u.Vec(u8).init(u.alloc);
    const stats = loadIfStats();
    const v6 = loadV6();
    if (rest.items.len == 0) {
        for (ifaceNames()) |nm| {
            var r = ifr(nm);
            if (!ioc(fd, 0x8913, &r)) continue;
            const flags: u32 = std.mem.readInt(u16, r.data[0..2], .little);
            if (!all and flags & IFF_UP == 0) continue;
            var st: ?IfStat = null;
            for (stats) |s| if (std.mem.eql(u8, s.name, nm)) {
                st = s;
            };
            _ = showOne(fd, nm, st, v6, &out);
        }
        u.out(out.items);
        return 0;
    }
    const name = rest.items[0];
    if (rest.items.len == 1) {
        var st: ?IfStat = null;
        const base = if (std.mem.indexOfScalar(u8, name, ':')) |i| name[0..i] else name;
        for (stats) |s| if (std.mem.eql(u8, s.name, base)) {
            st = s;
        };
        if (!showOne(fd, name, st, v6, &out)) {
            u.errf("{s}: error fetching interface information: Device not found\n", .{name});
            return 255;
        }
        u.out(out.items);
        return 0;
    }
    // configuration
    var i: usize = 1;
    var rc: u8 = 0;
    // an address family keyword may precede the address
    if (i < rest.items.len and (std.mem.eql(u8, rest.items[i], "inet") or std.mem.eql(u8, rest.items[i], "inet6"))) i += 1;
    {
        var r = ifr(name);
        if (!ioc(fd, 0x8913, &r)) {
            u.errf("{s}: ERROR while getting interface flags: No such device\n", .{name});
            return 255;
        }
    }
    while (i < rest.items.len) : (i += 1) {
        const a = rest.items[i];
        const need = struct {
            fn f(items: []const []const u8, idx: usize) ?[]const u8 {
                return if (idx + 1 < items.len) items[idx + 1] else null;
            }
        }.f;
        var r = ifr(name);
        if (std.mem.eql(u8, a, "up") or std.mem.eql(u8, a, "down")) {
            _ = ioc(fd, 0x8913, &r);
            var fl: u16 = std.mem.readInt(u16, r.data[0..2], .little);
            if (std.mem.eql(u8, a, "up")) fl |= @intCast(IFF_UP | IFF_RUNNING) else fl &= ~@as(u16, @intCast(IFF_UP));
            std.mem.writeInt(u16, r.data[0..2], fl, .little);
            if (!ioc(fd, 0x8914, &r)) {
                u.errf("SIOCSIFFLAGS: {s}\n", .{"Cannot assign requested address"});
                rc = 255;
            }
            continue;
        }
        const flagop = [_]struct { n: []const u8, f: u32 }{ .{ .n = "arp", .f = IFF_NOARP }, .{ .n = "trailers", .f = IFF_NOTRAILERS }, .{ .n = "promisc", .f = IFF_PROMISC }, .{ .n = "allmulti", .f = IFF_ALLMULTI }, .{ .n = "multicast", .f = IFF_MULTICAST }, .{ .n = "dynamic", .f = 0x8000 }, .{ .n = "broadcast", .f = IFF_BROADCAST }, .{ .n = "pointopoint", .f = IFF_POINTOPOINT } };
        var handled = false;
        for (flagop) |fo| {
            const neg = a.len > 1 and a[0] == '-' and std.mem.eql(u8, a[1..], fo.n);
            if (std.mem.eql(u8, a, fo.n) or neg) {
                if (std.mem.eql(u8, fo.n, "broadcast") or std.mem.eql(u8, fo.n, "pointopoint")) {
                    if (!neg) if (need(rest.items, i)) |v| if (parseIpv4(v)) |ip| {
                        i += 1;
                        const req: u32 = if (std.mem.eql(u8, fo.n, "broadcast")) 0x891a else 0x8918;
                        if (!setAddr(fd, name, req, ip)) rc = ifconfigErr("SIFBRDADDR");
                    };
                    var rr = ifr(name);
                    _ = ioc(fd, 0x8913, &rr);
                    var fl: u16 = std.mem.readInt(u16, rr.data[0..2], .little);
                    if (neg) fl &= ~@as(u16, @intCast(fo.f)) else fl |= @intCast(fo.f);
                    std.mem.writeInt(u16, rr.data[0..2], fl, .little);
                    _ = ioc(fd, 0x8914, &rr);
                } else {
                    _ = ioc(fd, 0x8913, &r);
                    var fl: u16 = std.mem.readInt(u16, r.data[0..2], .little);
                    // "arp" clears NOARP, "-arp" sets it; the others set when positive
                    const set = if (std.mem.eql(u8, fo.n, "arp") or std.mem.eql(u8, fo.n, "trailers")) neg else !neg;
                    if (set) fl |= @intCast(fo.f) else fl &= ~@as(u16, @intCast(fo.f));
                    std.mem.writeInt(u16, r.data[0..2], fl, .little);
                    if (!ioc(fd, 0x8914, &r)) rc = ifconfigErr("SIFFLAGS");
                }
                handled = true;
                break;
            }
        }
        if (handled) continue;
        if (std.mem.eql(u8, a, "netmask") or std.mem.eql(u8, a, "dstaddr")) {
            const v = need(rest.items, i) orelse {
                u.err("ifconfig: need an argument\n");
                return 255;
            };
            i += 1;
            const ip = parseIpv4(v) orelse {
                u.errf("ifconfig: unknown host {s}\n", .{v});
                return 255;
            };
            if (!setAddr(fd, name, if (std.mem.eql(u8, a, "netmask")) 0x891c else 0x8918, ip)) {
                u.errf("SIOCSIF{s}: Cannot assign requested address\n", .{if (std.mem.eql(u8, a, "netmask")) "NETMASK" else "DSTADDR"});
                rc = 255;
            }
        } else if (std.mem.eql(u8, a, "mtu") or std.mem.eql(u8, a, "metric") or std.mem.eql(u8, a, "txqueuelen")) {
            const v = need(rest.items, i) orelse {
                u.err("ifconfig: need an argument\n");
                return 255;
            };
            i += 1;
            const n = std.fmt.parseInt(u32, v, 0) catch {
                u.errf("ifconfig: invalid value {s}\n", .{v});
                return 255;
            };
            std.mem.writeInt(u32, r.data[0..4], n, .little);
            const req: u32 = if (std.mem.eql(u8, a, "mtu")) 0x8922 else if (std.mem.eql(u8, a, "metric")) 0x891e else 0x8943 + 0; // SIOCSIFMTU, SIOCSIFMETRIC, SIOCSIFTXQLEN
            const real_req: u32 = if (std.mem.eql(u8, a, "txqueuelen")) 0x8943 else req;
            if (!ioc(fd, real_req, &r)) {
                u.errf("SIOCSIF{s}: {s}\n", .{ if (std.mem.eql(u8, a, "mtu")) "MTU" else if (std.mem.eql(u8, a, "metric")) "METRIC" else "TXQLEN", "Invalid argument" });
                rc = 255;
            }
        } else if (std.mem.eql(u8, a, "hw")) {
            const cls = need(rest.items, i) orelse return 255;
            const mac = if (i + 2 < rest.items.len) rest.items[i + 2] else return 255;
            i += 2;
            _ = cls;
            var hr = ifr(name);
            var mb: [6]u8 = undefined;
            var it = std.mem.splitScalar(u8, mac, ':');
            var n: usize = 0;
            while (it.next()) |p| : (n += 1) {
                if (n >= 6) break;
                mb[n] = std.fmt.parseInt(u8, p, 16) catch 0;
            }
            std.mem.writeInt(u16, hr.data[0..2], 1, .little);
            @memcpy(hr.data[2..8], &mb);
            if (!ioc(fd, 0x8924, &hr)) {
                u.errf("SIOCSIFHWADDR: {s}\n", .{"Cannot assign requested address"});
                rc = 255;
            }
        } else if (std.mem.eql(u8, a, "add") or std.mem.eql(u8, a, "del")) {
            // IPv6 address management through an AF_INET6 socket
            const v = need(rest.items, i) orelse return 255;
            i += 1;
            const rc6 = ipv6Change(name, v, std.mem.eql(u8, a, "add"));
            if (rc6 != 0) rc = rc6;
        } else if (parseIpv4(a)) |ip| {
            if (!setAddr(fd, name, 0x8916, ip)) {
                u.errf("SIOCSIFADDR: {s}\n", .{"Cannot assign requested address"});
                rc = 255;
            } else {
                // an address brings the interface up
                var r3 = ifr(name);
                _ = ioc(fd, 0x8913, &r3);
                var fl: u16 = std.mem.readInt(u16, r3.data[0..2], .little);
                fl |= @intCast(IFF_UP | IFF_RUNNING);
                std.mem.writeInt(u16, r3.data[0..2], fl, .little);
                _ = ioc(fd, 0x8914, &r3);
            }
        } else if (std.mem.indexOfScalar(u8, a, ':') != null) {
            const rc6 = ipv6Change(name, a, true);
            if (rc6 != 0) rc = rc6;
        } else {
            u.errf("ifconfig: `--help' gives usage information.\n", .{});
            return 255;
        }
    }
    return rc;
}

fn ipv6Change(name: []const u8, spec: []const u8, add: bool) u8 {
    var addr_s = spec;
    var plen: u32 = 64;
    if (std.mem.indexOfScalar(u8, spec, '/')) |i| {
        addr_s = spec[0..i];
        plen = std.fmt.parseInt(u32, spec[i + 1 ..], 10) catch 64;
    }
    var a: [16]u8 = [_]u8{0} ** 16;
    // parse "a:b::c" style addresses
    var groups = u.Vec(u16).init(u.alloc);
    var tail = u.Vec(u16).init(u.alloc);
    var dbl = false;
    var it = std.mem.splitScalar(u8, addr_s, ':');
    var empty_run: usize = 0;
    while (it.next()) |p| {
        if (p.len == 0) {
            empty_run += 1;
            if (empty_run == 1 or empty_run == 2) dbl = true;
            continue;
        }
        const v = std.fmt.parseInt(u16, p, 16) catch return 255;
        if (dbl) tail.push(v) else groups.push(v);
    }
    if (groups.items.len + tail.items.len > 8) return 255;
    var gi: usize = 0;
    for (groups.items) |gv| {
        a[gi * 2] = @intCast(gv >> 8);
        a[gi * 2 + 1] = @intCast(gv & 0xff);
        gi += 1;
    }
    var ti: usize = 8 - tail.items.len;
    for (tail.items) |tv| {
        a[ti * 2] = @intCast(tv >> 8);
        a[ti * 2 + 1] = @intCast(tv & 0xff);
        ti += 1;
    }
    const fd = linux.socket(10, 2, 0);
    if (!u.ok(fd)) return 255;
    defer _ = linux.close(@intCast(fd));
    // index
    var idx: u32 = 0;
    {
        const f4 = sock();
        defer _ = linux.close(f4);
        var r = ifr(name);
        if (ioc(f4, 0x8933, &r)) idx = std.mem.readInt(u32, r.data[0..4], .little);
    }
    const In6Ifreq = extern struct { addr: [16]u8, prefix: u32, ifindex: u32 };
    var req = In6Ifreq{ .addr = a, .prefix = plen, .ifindex = idx };
    const rc = linux.ioctl(@intCast(fd), if (add) 0x8916 else 0x8936, @intFromPtr(&req));
    if (!u.ok(rc)) {
        u.errf("SIOC{s}IFADDR: {s}\n", .{ if (add) "S" else "D", u.strerr(u.errno(rc)) });
        return 255;
    }
    return 0;
}

// ---------------------------------------------------------------- route
const Route = struct { iface: []const u8, dest: u32, gw: u32, flags: u32, ref: u32, use: u32, metric: u32, mask: u32, mtu: u32, window: u32, irtt: u32 };

fn loadRoutes() []Route {
    var out = u.Vec(Route).init(u.alloc);
    const d = readFile("/proc/net/route") orelse return out.items;
    var lines = std.mem.splitScalar(u8, d, '\n');
    _ = lines.next();
    while (lines.next()) |l| {
        var it = std.mem.tokenizeAny(u8, l, " \t");
        const ifc = it.next() orelse continue;
        var v: [10]u32 = undefined;
        var n: usize = 0;
        while (n < 10) : (n += 1) {
            const t = it.next() orelse break;
            v[n] = std.fmt.parseInt(u32, t, 16) catch 0;
            if (n == 3 or n == 4 or n == 5) v[n] = std.fmt.parseInt(u32, t, 10) catch v[n];
        }
        if (n < 10) continue;
        // columns: dest gw flags refcnt use metric mask mtu window irtt (flags are hex, the rest decimal except addresses)
        const flags = std.fmt.parseInt(u32, std.mem.tokenizeAny(u8, l, " \t").rest(), 16) catch 0;
        _ = flags;
        var it2 = std.mem.tokenizeAny(u8, l, " \t");
        _ = it2.next();
        const dest = std.fmt.parseInt(u32, it2.next().?, 16) catch 0;
        const gw = std.fmt.parseInt(u32, it2.next().?, 16) catch 0;
        const fl = std.fmt.parseInt(u32, it2.next().?, 16) catch 0;
        const refc = std.fmt.parseInt(u32, it2.next().?, 10) catch 0;
        const use = std.fmt.parseInt(u32, it2.next().?, 10) catch 0;
        const metric = std.fmt.parseInt(u32, it2.next().?, 10) catch 0;
        const mask = std.fmt.parseInt(u32, it2.next().?, 16) catch 0;
        const mtu = std.fmt.parseInt(u32, it2.next().?, 10) catch 0;
        const win = std.fmt.parseInt(u32, it2.next().?, 10) catch 0;
        const irtt = std.fmt.parseInt(u32, it2.next().?, 10) catch 0;
        out.push(.{ .iface = u.alloc.dupe(u8, ifc) catch ifc, .dest = dest, .gw = gw, .flags = fl, .ref = refc, .use = use, .metric = metric, .mask = mask, .mtu = mtu, .window = win, .irtt = irtt });
    }
    return out.items;
}

fn routeFlags(f: u32) []const u8 {
    var o = u.Vec(u8).init(u.alloc);
    if (f & 1 != 0) o.push('U');
    if (f & 2 != 0) o.push('G');
    if (f & 4 != 0) o.push('H');
    if (f & 8 != 0) o.push('R');
    if (f & 0x10 != 0) o.push('D');
    if (f & 0x20 != 0) o.push('M');
    if (f & 0x40000 != 0) o.push('A');
    if (f & 0x200000 != 0) o.push('C');
    if (f & 0x200 != 0) o.push('!');
    return o.items;
}

fn netName(ip: u32) ?[]const u8 {
    const d = readFile("/etc/networks") orelse return null;
    var lines = std.mem.splitScalar(u8, d, '\n');
    while (lines.next()) |l0| {
        const l = if (std.mem.indexOfScalar(u8, l0, '#')) |i| l0[0..i] else l0;
        var it = std.mem.tokenizeAny(u8, l, " \t");
        const nm = it.next() orelse continue;
        const a = it.next() orelse continue;
        if (parseIpv4(a)) |v| if (v == ip) return nm;
    }
    return null;
}

fn showRoutes(numeric: bool, ext: u32, header: bool) void {
    var o = u.Vec(u8).init(u.alloc);
    if (header) o.pushSlice("Kernel IP routing table\n");
    if (ext >= 1) o.pushSlice("Destination     Gateway         Genmask         Flags   MSS Window  irtt Iface\n") else o.pushSlice("Destination     Gateway         Genmask         Flags Metric Ref    Use Iface\n");
    const hosts = if (numeric) &[_]Hosts{} else loadHosts();
    for (loadRoutes()) |r| {
        var b1: [16]u8 = undefined;
        var b2: [16]u8 = undefined;
        var b3: [16]u8 = undefined;
        var dest: []const u8 = ipv4(r.dest, &b1);
        var gw: []const u8 = ipv4(r.gw, &b2);
        const mask = ipv4(r.mask, &b3);
        if (!numeric) {
            if (r.dest == 0 and r.mask == 0) dest = "default" else if (r.flags & 4 != 0) {
                for (hosts) |h| if (h.ip == r.dest) {
                    dest = h.name;
                    break;
                };
            } else if (netName(r.dest)) |nm| dest = nm;
            if (r.gw == 0) gw = "*" else for (hosts) |h| if (h.ip == r.gw) {
                gw = h.name;
                break;
            };
        }
        if (ext >= 1) {
            o.pushSlice(std.fmt.allocPrint(u.alloc, "{s: <15} {s: <15} {s: <15} {s: <5} {d: >5} {d: <5} {d: >5} {s}\n", .{ dest, gw, mask, routeFlags(r.flags), r.mtu, r.window, r.irtt, r.iface }) catch "");
        } else {
            o.pushSlice(std.fmt.allocPrint(u.alloc, "{s: <15} {s: <15} {s: <15} {s: <5} {d: <6} {d: <2} {d: >7} {s}\n", .{ dest, gw, mask, routeFlags(r.flags), r.metric, r.ref, r.use, r.iface }) catch "");
        }
    }
    u.out(o.items);
}

const RtEntry = extern struct {
    pad1: c_ulong = 0,
    dst: SockAddrIn = .{},
    gateway: SockAddrIn = .{},
    genmask: SockAddrIn = .{},
    flags: u16 = 0,
    pad2: i16 = 0,
    pad3: c_ulong = 0,
    tos: u8 = 0,
    class: u8 = 0,
    pad4: [3]i16 = [_]i16{0} ** 3,
    metric: i16 = 0,
    dev: usize = 0,
    mtu: c_ulong = 0,
    window: c_ulong = 0,
    irtt: u16 = 0,
};

fn routeChange(add: bool, args: []const []const u8) u8 {
    var rt = RtEntry{};
    var target: ?[]const u8 = null;
    var netmask: ?u32 = null;
    var gw: ?u32 = null;
    var is_net = false;
    var is_host = false;
    var dev: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const nextv = struct {
            fn f(items: []const []const u8, idx: *usize) ?[]const u8 {
                if (idx.* + 1 >= items.len) return null;
                idx.* += 1;
                return items[idx.*];
            }
        }.f;
        if (std.mem.eql(u8, a, "-net")) {
            is_net = true;
        } else if (std.mem.eql(u8, a, "-host")) {
            is_host = true;
        } else if (std.mem.eql(u8, a, "-A") or std.mem.eql(u8, a, "-4")) {
            if (std.mem.eql(u8, a, "-A")) _ = nextv(args, &i);
        } else if (std.mem.eql(u8, a, "netmask")) {
            const v = nextv(args, &i) orelse return usageErr();
            netmask = parseIpv4(v) orelse {
                u.errf("route: bad netmask {s}\n", .{v});
                return 255;
            };
        } else if (std.mem.eql(u8, a, "gw")) {
            const v = nextv(args, &i) orelse return usageErr();
            gw = parseIpv4(v) orelse {
                u.errf("route: resolving {s} failed\n", .{v});
                return 255;
            };
        } else if (std.mem.eql(u8, a, "metric")) {
            const v = nextv(args, &i) orelse return usageErr();
            rt.metric = @intCast(@as(i32, std.fmt.parseInt(i32, v, 10) catch 0) + 1);
        } else if (std.mem.eql(u8, a, "mss")) {
            const v = nextv(args, &i) orelse return usageErr();
            rt.mtu = std.fmt.parseInt(c_ulong, v, 10) catch 0;
            rt.flags |= 0x40;
        } else if (std.mem.eql(u8, a, "window")) {
            const v = nextv(args, &i) orelse return usageErr();
            rt.window = std.fmt.parseInt(c_ulong, v, 10) catch 0;
            rt.flags |= 0x80;
        } else if (std.mem.eql(u8, a, "irtt")) {
            const v = nextv(args, &i) orelse return usageErr();
            rt.irtt = std.fmt.parseInt(u16, v, 10) catch 0;
            rt.flags |= 0x100;
        } else if (std.mem.eql(u8, a, "reject")) {
            rt.flags |= 0x200;
        } else if (std.mem.eql(u8, a, "mod")) {
            rt.flags |= 0x20;
        } else if (std.mem.eql(u8, a, "dyn")) {
            rt.flags |= 0x10;
        } else if (std.mem.eql(u8, a, "reinstate")) {
            rt.flags |= 8;
        } else if (std.mem.eql(u8, a, "dev")) {
            dev = nextv(args, &i) orelse return usageErr();
        } else if (target == null) {
            target = a;
        } else if (dev == null) {
            dev = a;
        } else return usageErr();
    }
    const tgt = target orelse return usageErr();
    var dst: u32 = 0;
    var mask: u32 = 0;
    if (!std.mem.eql(u8, tgt, "default")) {
        var t = tgt;
        if (std.mem.indexOfScalar(u8, tgt, '/')) |sl| {
            t = tgt[0..sl];
            const p = std.fmt.parseInt(u6, tgt[sl + 1 ..], 10) catch {
                u.errf("route: bad prefix length {s}\n", .{tgt[sl + 1 ..]});
                return 255;
            };
            mask = maskFromPrefix(p);
            is_net = p != 32;
            if (p == 32) is_host = true;
        }
        dst = parseIpv4(t) orelse {
            u.errf("{s}: Unknown host\n", .{t});
            return 255;
        };
    }
    if (netmask) |m| mask = m;
    if (!is_host and !is_net and netmask == null and mask == 0 and !std.mem.eql(u8, tgt, "default")) {
        // a bare address without netmask is a host route unless it has no host bits in its class
        is_host = true;
    }
    if (is_host and mask == 0) mask = 0xFFFFFFFF;
    if (!std.mem.eql(u8, tgt, "default") and (dst & ~mask) != 0 and mask != 0xFFFFFFFF) {
        u.err("route: netmask doesn't match route address\n");
        return 255;
    }
    rt.dst = .{ .addr = dst };
    rt.genmask = .{ .addr = mask };
    rt.flags |= 1;
    if (mask == 0xFFFFFFFF) rt.flags |= 4;
    if (gw) |gwv| {
        rt.gateway = .{ .addr = gwv };
        rt.flags |= 2;
    }
    if (dev) |dv| rt.dev = @intFromPtr(u.zstr(dv).ptr);
    const fd = sock();
    if (fd < 0) return 255;
    defer _ = linux.close(fd);
    const rc = linux.ioctl(fd, if (add) 0x890B else 0x890C, @intFromPtr(&rt));
    if (!u.ok(rc)) {
        const e = u.errno(rc);
        const msg: []const u8 = switch (e) {
            .EXIST => "File exists",
            .SRCH => "No such process",
            .NETUNREACH => "Network is unreachable",
            .PERM => "Operation not permitted",
            .NODEV => "No such device",
            .INVAL => "Invalid argument",
            else => u.strerr(e),
        };
        u.errf("SIOC{s}RT: {s}\n", .{ if (add) "ADD" else "DEL", msg });
        return 7;
    }
    return 0;
}

fn usageErr() u8 {
    u.err("Usage: route [-nNvee] [-FC] [<AF>]           List kernel routing tables\n       route [-v] [-FC] {add|del|flush} ...        Modify routing table for AF.\n\n       route {-h|--help} [<AF>]                    Detailed usage syntax for specified AF.\n       route {-V|--version}                        Display version/author and exit.\n\n        -net            Net-style destination\n");
    return 255;
}

pub fn route(args: []const []const u8) u8 {
    var numeric = false;
    var ext: u32 = 0;
    var i: usize = 0;
    var cmd: ?[]const u8 = null;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "add") or std.mem.eql(u8, a, "del") or std.mem.eql(u8, a, "delete")) {
            cmd = a;
            i += 1;
            break;
        }
        if (std.mem.eql(u8, a, "-V") or std.mem.eql(u8, a, "--version")) {
            u.out("net-tools 2.10\n");
            return 0;
        }
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) return usageErr();
        if (a.len > 1 and a[0] == '-' and a[1] != '-') {
            var is_opt = true;
            for (a[1..]) |ch| switch (ch) {
                'n' => numeric = true,
                'e' => ext += 1,
                'C', 'F', 'N', 'v' => {},
                else => is_opt = false,
            };
            if (is_opt) continue;
        }
        if (std.mem.eql(u8, a, "-A")) {
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "inet") or std.mem.eql(u8, a, "inet6")) continue;
        return usageErr();
    }
    if (cmd) |c| return routeChange(!std.mem.startsWith(u8, c, "del"), args[i..]);
    showRoutes(numeric, ext, true);
    return 0;
}

// ---------------------------------------------------------------- netstat
const Proto = enum { tcp, udp, raw, udplite };

const InetSock = struct {
    proto: []const u8,
    v6: bool,
    laddr: []const u8,
    lport: u16,
    raddr: []const u8,
    rport: u16,
    state: u8,
    txq: u64,
    rxq: u64,
    uid: u32,
    inode: u64,
    timer: u8,
    tm_when: u64,
    retrans: u64,
};

fn hexAddr4(s: []const u8) []const u8 {
    const v = std.fmt.parseInt(u32, s, 16) catch 0;
    var b: [16]u8 = undefined;
    // the kernel prints the address as a host order word of a network order value
    return u.alloc.dupe(u8, ipv4(v, &b)) catch "";
}

fn hexAddr6(s: []const u8) []const u8 {
    if (s.len != 32) return "";
    var a: [16]u8 = undefined;
    for (0..4) |w| {
        const word = std.fmt.parseInt(u32, s[w * 8 .. w * 8 + 8], 16) catch 0;
        const b: [4]u8 = @bitCast(word);
        @memcpy(a[w * 4 .. w * 4 + 4], &b);
    }
    // IPv4-mapped addresses print as ::ffff:a.b.c.d
    var mapped = true;
    for (a[0..10]) |x| if (x != 0) {
        mapped = false;
    };
    if (mapped and a[10] == 0xff and a[11] == 0xff) return std.fmt.allocPrint(u.alloc, "::ffff:{d}.{d}.{d}.{d}", .{ a[12], a[13], a[14], a[15] }) catch "";
    return fmtV6(a);
}

fn loadInet(path: []const u8, proto: []const u8, v6: bool, out: *u.Vec(InetSock)) void {
    const d = readFile(path) orelse return;
    var lines = std.mem.splitScalar(u8, d, '\n');
    _ = lines.next();
    while (lines.next()) |l| {
        var it = std.mem.tokenizeAny(u8, l, " \t");
        _ = it.next() orelse continue;
        const la = it.next() orelse continue;
        const ra = it.next() orelse continue;
        const st = it.next() orelse continue;
        const q = it.next() orelse continue;
        const tr = it.next() orelse continue;
        const retr = it.next() orelse continue;
        const uid = it.next() orelse continue;
        _ = it.next();
        const ino = it.next() orelse continue;
        const lc = std.mem.indexOfScalar(u8, la, ':') orelse continue;
        const rcn = std.mem.indexOfScalar(u8, ra, ':') orelse continue;
        const qc = std.mem.indexOfScalar(u8, q, ':') orelse continue;
        const trc = std.mem.indexOfScalar(u8, tr, ':') orelse continue;
        out.push(.{
            .proto = proto,
            .v6 = v6,
            .laddr = if (v6) hexAddr6(la[0..lc]) else hexAddr4(la[0..lc]),
            .lport = std.fmt.parseInt(u16, la[lc + 1 ..], 16) catch 0,
            .raddr = if (v6) hexAddr6(ra[0..rcn]) else hexAddr4(ra[0..rcn]),
            .rport = std.fmt.parseInt(u16, ra[rcn + 1 ..], 16) catch 0,
            .state = std.fmt.parseInt(u8, st, 16) catch 0,
            .txq = std.fmt.parseInt(u64, q[0..qc], 16) catch 0,
            .rxq = std.fmt.parseInt(u64, q[qc + 1 ..], 16) catch 0,
            .uid = std.fmt.parseInt(u32, uid, 10) catch 0,
            .inode = std.fmt.parseInt(u64, ino, 10) catch 0,
            .timer = std.fmt.parseInt(u8, tr[0..trc], 16) catch 0,
            .tm_when = std.fmt.parseInt(u64, tr[trc + 1 ..], 16) catch 0,
            .retrans = std.fmt.parseInt(u64, retr, 16) catch 0,
        });
    }
}

fn tcpState(s: u8) []const u8 {
    return switch (s) {
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

const Owner = struct { inode: u64, pid: u32, name: []const u8 };

fn loadOwners() []Owner {
    var out = u.Vec(Owner).init(u.alloc);
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir("/proc", &ents)) return out.items;
    for (ents.items) |e| {
        const pid = std.fmt.parseInt(u32, e.name, 10) catch continue;
        var fds = u.Vec(u.DirEnt).init(u.alloc);
        const fdp = std.fmt.allocPrint(u.alloc, "/proc/{d}/fd", .{pid}) catch continue;
        if (!u.listDir(fdp, &fds)) continue;
        var name: ?[]const u8 = null;
        for (fds.items) |fe| {
            var lb: [64]u8 = undefined;
            const lp = std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ fdp, fe.name }) catch continue;
            const r = linux.readlink(u.zstr(lp), &lb, lb.len);
            if (!u.ok(r)) continue;
            const t = lb[0..r];
            if (!std.mem.startsWith(u8, t, "socket:[")) continue;
            const ino = std.fmt.parseInt(u64, t[8 .. t.len - 1], 10) catch continue;
            if (name == null) {
                const cl = readFile(std.fmt.allocPrint(u.alloc, "/proc/{d}/cmdline", .{pid}) catch "") orelse "";
                var arg0 = std.mem.sliceTo(cl, 0);
                if (std.mem.indexOfScalar(u8, arg0, ' ')) |sp| arg0 = arg0[0..sp];
                var base = arg0;
                if (std.mem.lastIndexOfScalar(u8, arg0, '/')) |sl| base = arg0[sl + 1 ..];
                if (base.len == 0) base = readTrim(std.fmt.allocPrint(u.alloc, "/proc/{d}/comm", .{pid}) catch "");
                name = u.alloc.dupe(u8, base) catch "";
            }
            out.push(.{ .inode = ino, .pid = pid, .name = name.? });
        }
    }
    return out.items;
}

const NetCfg = struct {
    numeric_hosts: bool = false,
    numeric_ports: bool = false,
    all: bool = false,
    listen: bool = false,
    wide: bool = false,
    programs: bool = false,
    extend: bool = false,
    timers: bool = false,
    tcp: bool = false,
    udp: bool = false,
    raw: bool = false,
    unix: bool = false,
    v4: bool = true,
    v6: bool = true,
    owners: []Owner = &.{},
    hosts: []Hosts = &.{},
};

fn fmtEndpoint(cfg: *const NetCfg, addr: []const u8, port: u16, proto: []const u8, v6: bool) []const u8 {
    var host: []const u8 = addr;
    if (!cfg.numeric_hosts) {
        if (!v6) {
            if (parseIpv4(addr)) |ip| for (cfg.hosts) |h| if (h.ip == ip) {
                host = h.name;
                break;
            };
        } else if (std.mem.eql(u8, addr, "::1")) host = "localhost6" else if (std.mem.eql(u8, addr, "::")) host = "[::]";
        if (std.mem.eql(u8, addr, "0.0.0.0") or std.mem.eql(u8, addr, "::")) host = if (v6) "[::]" else "0.0.0.0";
    }
    if (std.mem.eql(u8, addr, "::")) host = if (cfg.numeric_hosts) "::" else "[::]";
    var pbuf: [32]u8 = undefined;
    var pstr: []const u8 = std.fmt.bufPrint(&pbuf, "{d}", .{port}) catch "";
    if (port == 0) pstr = "*" else if (!cfg.numeric_ports) {
        const base_proto: []const u8 = if (std.mem.startsWith(u8, proto, "tcp")) "tcp" else if (std.mem.startsWith(u8, proto, "udp")) "udp" else proto;
        if (serviceName(port, base_proto)) |sn| pstr = sn;
    }
    var h = host;
    if (!cfg.wide) {
        const limit: usize = 22;
        if (h.len + pstr.len > limit) {
            const keep = if (limit > pstr.len) limit - pstr.len else 0;
            h = h[0..@min(keep, h.len)];
        }
    }
    return std.fmt.allocPrint(u.alloc, "{s}:{s}", .{ h, pstr }) catch "";
}

fn showInet(cfg: *const NetCfg, o: *u.Vec(u8)) void {
    var socks = u.Vec(InetSock).init(u.alloc);
    if (cfg.tcp) {
        if (cfg.v4) loadInet("/proc/net/tcp", "tcp", false, &socks);
        if (cfg.v6) loadInet("/proc/net/tcp6", "tcp6", true, &socks);
    }
    if (cfg.udp) {
        if (cfg.v4) loadInet("/proc/net/udp", "udp", false, &socks);
        if (cfg.v6) loadInet("/proc/net/udp6", "udp6", true, &socks);
    }
    if (cfg.raw) {
        if (cfg.v4) loadInet("/proc/net/raw", "raw", false, &socks);
        if (cfg.v6) loadInet("/proc/net/raw6", "raw6", true, &socks);
    }
    var rows = u.Vec(InetSock).init(u.alloc);
    for (socks.items) |s| {
        const is_tcp = std.mem.startsWith(u8, s.proto, "tcp");
        const listening = if (is_tcp) s.state == 10 else s.state == 7;
        if (cfg.listen and !cfg.all) {
            if (!listening) continue;
        } else if (!cfg.all) {
            if (listening) continue;
        }
        rows.push(s);
    }
    const title: []const u8 = if (cfg.all) "Active Internet connections (servers and established)" else if (cfg.listen) "Active Internet connections (only servers)" else "Active Internet connections (w/o servers)";
    if (rows.items.len == 0 and !(cfg.all or cfg.listen)) {
        // net-tools still prints the header
    }
    o.pushSlice(title);
    o.push('\n');
    const la_w: usize = if (cfg.wide) 0 else 23;
    _ = la_w;
    o.pushSlice("Proto Recv-Q Send-Q Local Address           Foreign Address         State      ");
    if (cfg.extend) o.pushSlice(" User       Inode      ");
    if (cfg.programs) o.pushSlice(" PID/Program name    ");
    if (cfg.timers) o.pushSlice(" Timer");
    o.push('\n');
    for (rows.items) |s| {
        const le = fmtEndpoint(cfg, s.laddr, s.lport, s.proto, s.v6);
        const re = fmtEndpoint(cfg, s.raddr, s.rport, s.proto, s.v6);
        const is_tcp = std.mem.startsWith(u8, s.proto, "tcp");
        const st: []const u8 = if (is_tcp) tcpState(s.state) else if (s.state == 1) "ESTABLISHED" else "";
        if (cfg.wide) {
            o.pushSlice(std.fmt.allocPrint(u.alloc, "{s: <5} {d: >6} {d: >6} {s: <23} {s: <23} {s: <11}", .{ s.proto, s.rxq, s.txq, le, re, st }) catch "");
        } else {
            o.pushSlice(std.fmt.allocPrint(u.alloc, "{s: <5} {d: >6} {d: >6} {s: <23} {s: <23} {s: <11}", .{ s.proto, s.rxq, s.txq, le, re, st }) catch "");
        }
        if (cfg.extend) {
            var un: []const u8 = std.fmt.allocPrint(u.alloc, "{d}", .{s.uid}) catch "";
            if (!cfg.numeric_hosts) un = userNameOf(s.uid);
            o.pushSlice(std.fmt.allocPrint(u.alloc, " {s: <10} {d: <10}", .{ un, s.inode }) catch "");
        }
        if (cfg.programs) {
            var prog: []const u8 = "-";
            for (cfg.owners) |ow| if (ow.inode == s.inode) {
                prog = std.fmt.allocPrint(u.alloc, "{d}/{s}", .{ ow.pid, ow.name }) catch "-";
                break;
            };
            o.pushSlice(std.fmt.allocPrint(u.alloc, " {s: <20}", .{prog}) catch "");
        }
        if (cfg.timers) o.pushSlice(timerText(s));
        o.push('\n');
    }
}

fn timerText(s: InetSock) []const u8 {
    const secs = @as(f64, @floatFromInt(s.tm_when)) / 100.0;
    return switch (s.timer) {
        1 => std.fmt.allocPrint(u.alloc, " on ({d:.2}/{d}/{d})", .{ secs, s.retrans, 0 }) catch "",
        2 => std.fmt.allocPrint(u.alloc, " keepalive ({d:.2}/{d}/{d})", .{ secs, s.retrans, 0 }) catch "",
        4 => std.fmt.allocPrint(u.alloc, " probe ({d:.2}/{d}/{d})", .{ secs, s.retrans, 0 }) catch "",
        else => " off (0.00/0/0)",
    };
}

fn userNameOf(uid: u32) []const u8 {
    const d = readFile("/etc/passwd") orelse return std.fmt.allocPrint(u.alloc, "{d}", .{uid}) catch "";
    var lines = std.mem.splitScalar(u8, d, '\n');
    while (lines.next()) |l| {
        var it = std.mem.splitScalar(u8, l, ':');
        const nm = it.next() orelse continue;
        _ = it.next();
        const id = it.next() orelse continue;
        if ((std.fmt.parseInt(u32, id, 10) catch continue) == uid) return nm;
    }
    return std.fmt.allocPrint(u.alloc, "{d}", .{uid}) catch "";
}

fn showUnix(cfg: *const NetCfg, o: *u.Vec(u8)) void {
    const d = readFile("/proc/net/unix") orelse return;
    var rows = u.Vec(u8).init(u.alloc);
    var lines = std.mem.splitScalar(u8, d, '\n');
    _ = lines.next();
    while (lines.next()) |l| {
        var it = std.mem.tokenizeAny(u8, l, " \t");
        _ = it.next() orelse continue;
        const refc = std.fmt.parseInt(u32, it.next() orelse continue, 16) catch 0;
        _ = it.next();
        const flags = std.fmt.parseInt(u32, it.next() orelse continue, 16) catch 0;
        const ty = std.fmt.parseInt(u32, it.next() orelse continue, 16) catch 0;
        const st = std.fmt.parseInt(u32, it.next() orelse continue, 16) catch 0;
        const ino = std.fmt.parseInt(u64, it.next() orelse continue, 10) catch 0;
        const path = it.next() orelse "";
        const acc = flags & 0x10000 != 0;
        if (cfg.listen and !cfg.all) {
            if (!acc) continue;
        } else if (!cfg.all) {
            if (acc) continue;
        }
        const ftxt: []const u8 = if (acc) "[ ACC ]" else if (flags & 0x2 != 0) "[ W ]" else if (flags & 0x4 != 0) "[ N ]" else "[ ]";
        const tt: []const u8 = switch (ty) {
            1 => "STREAM",
            2 => "DGRAM",
            3 => "RAW",
            4 => "RDM",
            5 => "SEQPACKET",
            else => "UNKNOWN",
        };
        const stt: []const u8 = if (acc and st == 1) "LISTENING" else switch (st) {
            1 => "",
            2 => "CONNECTING",
            3 => "CONNECTED",
            4 => "DISCONNECTING",
            else => "UNKNOWN",
        };
        var pstr: []const u8 = "";
        if (cfg.programs) {
            pstr = "-";
            for (cfg.owners) |ow| if (ow.inode == ino) {
                pstr = std.fmt.allocPrint(u.alloc, "{d}/{s}", .{ ow.pid, ow.name }) catch "-";
                break;
            };
        }
        if (cfg.programs) {
            rows.pushSlice(std.fmt.allocPrint(u.alloc, "{s: <5} {d: <6} {s: <11} {s: <10} {s: <13} {d: <8} {s: <19} {s}\n", .{ "unix", refc, ftxt, tt, stt, ino, pstr, path }) catch "");
        } else {
            rows.pushSlice(std.fmt.allocPrint(u.alloc, "{s: <5} {d: <6} {s: <11} {s: <10} {s: <13} {d: <8} {s}\n", .{ "unix", refc, ftxt, tt, stt, ino, path }) catch "");
        }
    }
    const title: []const u8 = if (cfg.all) "Active UNIX domain sockets (servers and established)" else if (cfg.listen) "Active UNIX domain sockets (only servers)" else "Active UNIX domain sockets (w/o servers)";
    o.pushSlice(title);
    o.push('\n');
    if (cfg.programs) o.pushSlice("Proto RefCnt Flags       Type       State         I-Node   PID/Program name    Path\n") else o.pushSlice("Proto RefCnt Flags       Type       State         I-Node   Path\n");
    o.pushSlice(rows.items);
}

const netstat_usage = "usage: netstat [-vWeenNcCF] [<Af>] -r         netstat {-V|--version|-h|--help}\n       netstat [-vWnNcaeol] [<Socket> ...]\n       netstat { [-vWeenNac] -I[<Iface>] | [-veenNac] -i | [-cnNe] -M | -s [-6tuw] } [delay]\n\n        -r, --route              display routing table\n        -I, --interfaces=<Iface> display interface table for <Iface>\n        -i, --interfaces         display interface table\n        -g, --groups             display multicast group memberships\n        -s, --statistics         display networking statistics (like SNMP)\n        -M, --masquerade         display masqueraded connections\n\n        -v, --verbose            be verbose\n        -W, --wide               don't truncate IP addresses\n        -n, --numeric            don't resolve names\n        --numeric-hosts          don't resolve host names\n        --numeric-ports          don't resolve port names\n        --numeric-users          don't resolve user names\n        -N, --symbolic           resolve hardware names\n        -e, --extend             display other/more information\n        -p, --programs           display PID/Program name for sockets\n        -o, --timers             display timers\n        -c, --continuous         continuous listing\n\n        -l, --listening          display listening server sockets\n        -a, --all                display all sockets (default: connected)\n        -F, --fib                display Forwarding Information Base (default)\n        -C, --cache              display routing cache instead of FIB\n        -Z, --context            display SELinux security context for sockets\n\n  <Socket>={-t|--tcp} {-u|--udp} {-U|--udplite} {-S|--sctp} {-w|--raw}\n           {-x|--unix} --ax25 --ipx --netrom\n  <AF>=Use '-6|-4' or '-A <af>' or '--<af>'; default: inet\n  List of possible address families (which support routing):\n    inet (DARPA Internet) inet6 (IPv6) ax25 (AMPR AX.25) \n    netrom (AMPR NET/ROM) ipx (Novell IPX) ddp (Appletalk DDP) \n    x25 (CCITT X.25) \n";

pub fn netstat(args: []const []const u8) u8 {
    var cfg = NetCfg{};
    var do_route = false;
    var do_if = false;
    var iface_only: ?[]const u8 = null;
    var any_proto = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len > 2 and a[0] == '-' and a[1] == '-') {
            const n = a[2..];
            if (std.mem.eql(u8, n, "numeric")) {
                cfg.numeric_hosts = true;
                cfg.numeric_ports = true;
            } else if (std.mem.eql(u8, n, "numeric-hosts")) cfg.numeric_hosts = true else if (std.mem.eql(u8, n, "numeric-ports")) cfg.numeric_ports = true else if (std.mem.eql(u8, n, "numeric-users")) {} else if (std.mem.eql(u8, n, "all")) cfg.all = true else if (std.mem.eql(u8, n, "listening")) cfg.listen = true else if (std.mem.eql(u8, n, "wide")) cfg.wide = true else if (std.mem.eql(u8, n, "programs")) cfg.programs = true else if (std.mem.eql(u8, n, "extend")) cfg.extend = true else if (std.mem.eql(u8, n, "timers")) cfg.timers = true else if (std.mem.eql(u8, n, "tcp")) {
                cfg.tcp = true;
                any_proto = true;
            } else if (std.mem.eql(u8, n, "udp")) {
                cfg.udp = true;
                any_proto = true;
            } else if (std.mem.eql(u8, n, "raw")) {
                cfg.raw = true;
                any_proto = true;
            } else if (std.mem.eql(u8, n, "unix")) {
                cfg.unix = true;
                any_proto = true;
            } else if (std.mem.eql(u8, n, "route")) do_route = true else if (std.mem.eql(u8, n, "interfaces")) do_if = true else if (std.mem.eql(u8, n, "verbose") or std.mem.eql(u8, n, "symbolic") or std.mem.eql(u8, n, "continuous") or std.mem.eql(u8, n, "fib")) {} else if (std.mem.eql(u8, n, "help")) {
                u.err(netstat_usage);
                return 0;
            } else if (std.mem.eql(u8, n, "version")) {
                u.out("net-tools 2.10\n");
                return 0;
            } else {
                u.errf("netstat: unrecognized option '{s}'\n", .{a});
                u.err(netstat_usage);
                return 1;
            }
            continue;
        }
        if (a.len > 1 and a[0] == '-') {
            var k: usize = 1;
            while (k < a.len) : (k += 1) switch (a[k]) {
                'n' => {
                    cfg.numeric_hosts = true;
                    cfg.numeric_ports = true;
                },
                'a' => cfg.all = true,
                'l' => cfg.listen = true,
                'W' => cfg.wide = true,
                'p' => cfg.programs = true,
                'e' => cfg.extend = true,
                'o' => cfg.timers = true,
                't' => {
                    cfg.tcp = true;
                    any_proto = true;
                },
                'u' => {
                    cfg.udp = true;
                    any_proto = true;
                },
                'w' => {
                    cfg.raw = true;
                    any_proto = true;
                },
                'x' => {
                    cfg.unix = true;
                    any_proto = true;
                },
                '4' => cfg.v6 = false,
                '6' => cfg.v4 = false,
                'r' => do_route = true,
                'i' => do_if = true,
                'I' => {
                    do_if = true;
                    if (k + 1 < a.len) iface_only = a[k + 1 ..];
                    k = a.len;
                },
                'v', 'N', 'c', 'F', 'C', 'Z' => {},
                'h' => {
                    u.err(netstat_usage);
                    return 0;
                },
                'V' => {
                    u.out("net-tools 2.10\n");
                    return 0;
                },
                's', 'g', 'M' => {
                    u.errf("netstat: option -{c} is not supported\n", .{a[k]});
                    return 1;
                },
                else => {
                    u.errf("netstat: invalid option -- '{c}'\n", .{a[k]});
                    u.err(netstat_usage);
                    return 1;
                },
            };
            continue;
        }
    }
    if (do_route) {
        showRoutes(cfg.numeric_hosts, if (cfg.extend) 1 else 0, true);
        return 0;
    }
    if (do_if) {
        const fd = sock();
        defer _ = linux.close(fd);
        var stats = u.Vec(IfStat).init(u.alloc);
        for (loadIfStats()) |s| {
            if (iface_only) |io| if (!std.mem.eql(u8, s.name, io)) continue;
            stats.push(s);
        }
        u.out("Kernel Interface table\n");
        shortTable(stats.items, false, fd);
        return 0;
    }
    if (!any_proto) {
        cfg.tcp = true;
        cfg.udp = true;
        cfg.raw = true;
        cfg.unix = true;
    }
    if (cfg.programs) cfg.owners = loadOwners();
    if (!cfg.numeric_hosts) cfg.hosts = loadHosts();
    var o = u.Vec(u8).init(u.alloc);
    if (cfg.tcp or cfg.udp or cfg.raw) showInet(&cfg, &o);
    if (cfg.unix) showUnix(&cfg, &o);
    u.out(o.items);
    return 0;
}
