// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// cksum - GNU coreutils: -a crc|bsd|sysv|crc32b|md5|sha1|sha224|sha256|sha384|sha512|blake2b,
// --tag --untagged -c -l -z --raw --base64
const std = @import("std");
const u = @import("util.zig");
const g = @import("getopt.zig");
const crypto = std.crypto;

const Algo = enum { crc, bsd, sysv, crc32b, md5, sha1, sha224, sha256, sha384, sha512, blake2b };

const crc_poly: u32 = 0x04C11DB7;

fn algoByName(s: []const u8) ?Algo {
    inline for (@typeInfo(Algo).@"enum".fields) |f| {
        if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

const Digest = struct { bytes: [64]u8 = undefined, len: usize = 0, num: u64 = 0, size: u64 = 0, blocks: u64 = 0 };

fn computeHash(comptime H: type, f: u.File, d: *Digest) void {
    var h = H.init(.{});
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = f.read(&buf);
        if (n == 0) break;
        d.size += n;
        h.update(buf[0..n]);
    }
    var out: [H.digest_length]u8 = undefined;
    h.final(&out);
    @memcpy(d.bytes[0..out.len], &out);
    d.len = out.len;
}

fn compute(algo: Algo, f: u.File, blen: usize) Digest {
    var d = Digest{};
    switch (algo) {
        .md5 => computeHash(crypto.hash.Md5, f, &d),
        .sha1 => computeHash(crypto.hash.Sha1, f, &d),
        .sha224 => computeHash(crypto.hash.sha2.Sha224, f, &d),
        .sha256 => computeHash(crypto.hash.sha2.Sha256, f, &d),
        .sha384 => computeHash(crypto.hash.sha2.Sha384, f, &d),
        .sha512 => computeHash(crypto.hash.sha2.Sha512, f, &d),
        .blake2b => switch (blen) {
            128 => computeHash(crypto.hash.blake2.Blake2b(128), f, &d),
            160 => computeHash(crypto.hash.blake2.Blake2b(160), f, &d),
            224 => computeHash(crypto.hash.blake2.Blake2b(224), f, &d),
            256 => computeHash(crypto.hash.blake2.Blake2b(256), f, &d),
            384 => computeHash(crypto.hash.blake2.Blake2b(384), f, &d),
            else => computeHash(crypto.hash.blake2.Blake2b512, f, &d),
        },
        .crc, .crc32b => {
            var crc: u32 = 0;
            var buf: [65536]u8 = undefined;
            if (algo == .crc) {
                while (true) {
                    const n = f.read(&buf);
                    if (n == 0) break;
                    d.size += n;
                    for (buf[0..n]) |b| crc = crcStep(crc, b);
                }
                var rem = d.size;
                while (rem != 0) : (rem >>= 8) crc = crcStep(crc, @truncate(rem));
                d.num = ~crc;
            } else {
                var c = std.hash.Crc32.init();
                while (true) {
                    const n = f.read(&buf);
                    if (n == 0) break;
                    d.size += n;
                    c.update(buf[0..n]);
                }
                d.num = c.final();
            }
        },
        .bsd => {
            var chk: u16 = 0;
            var buf: [65536]u8 = undefined;
            while (true) {
                const n = f.read(&buf);
                if (n == 0) break;
                d.size += n;
                for (buf[0..n]) |b| {
                    chk = (chk >> 1) | ((chk & 1) << 15);
                    chk +%= b;
                }
            }
            d.num = chk;
            d.blocks = (d.size + 1023) / 1024;
        },
        .sysv => {
            var s: u32 = 0;
            var buf: [65536]u8 = undefined;
            while (true) {
                const n = f.read(&buf);
                if (n == 0) break;
                d.size += n;
                for (buf[0..n]) |b| s +%= b;
            }
            const r = (s & 0xffff) + ((s & 0xffffffff) >> 16);
            d.num = (r & 0xffff) + (r >> 16);
            d.blocks = (d.size + 511) / 512;
        },
    }
    return d;
}

fn crcStep(crc_in: u32, b: u8) u32 {
    var crc = crc_in ^ (@as(u32, b) << 24);
    var k: usize = 0;
    while (k < 8) : (k += 1) crc = if (crc & 0x80000000 != 0) (crc << 1) ^ crc_poly else crc << 1;
    return crc;
}

fn tagName(a: Algo, blen: usize, buf: []u8) []const u8 {
    return switch (a) {
        .crc => "CRC",
        .bsd => "BSD",
        .sysv => "SYSV",
        .crc32b => "CRC32B",
        .md5 => "MD5",
        .sha1 => "SHA1",
        .sha224 => "SHA224",
        .sha256 => "SHA256",
        .sha384 => "SHA384",
        .sha512 => "SHA512",
        .blake2b => if (blen == 512) "BLAKE2b" else std.fmt.bufPrint(buf, "BLAKE2b-{d}", .{blen}) catch "BLAKE2b",
    };
}

fn isDigestAlgo(a: Algo) bool {
    return switch (a) {
        .crc, .bsd, .sysv, .crc32b => false,
        else => true,
    };
}

fn hexOf(o: *u.Vec(u8), b: []const u8) void {
    const hx = "0123456789abcdef";
    for (b) |x| {
        o.push(hx[x >> 4]);
        o.push(hx[x & 15]);
    }
}

pub fn run(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "algorithm", .key = 'a', .arg = .req },
        .{ .name = "length", .key = 'l', .arg = .req },
        .{ .name = "check", .key = 'c' },
        .{ .name = "tag", .key = 130 },
        .{ .name = "untagged", .key = 131 },
        .{ .name = "zero", .key = 'z' },
        .{ .name = "raw", .key = 132 },
        .{ .name = "base64", .key = 133 },
        .{ .name = "binary", .key = 'b' },
        .{ .name = "text", .key = 't' },
        .{ .name = "debug", .key = 134 },
        .{ .name = "ignore-missing", .key = 135 },
        .{ .name = "quiet", .key = 136 },
        .{ .name = "status", .key = 137 },
        .{ .name = "warn", .key = 'w' },
        .{ .name = "strict", .key = 138 },
        .{ .name = "help", .key = 200 },
        .{ .name = "version", .key = 201 },
    };
    var p = g.Parser.init("cksum", args, &opts);
    var algo: Algo = .crc;
    var blen: usize = 512;
    var check = false;
    var tag: ?bool = null;
    var zero = false;
    var raw = false;
    var b64 = false;
    var quiet = false;
    var status = false;
    var bin = false;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'a' => algo = algoByName(it.val.?) orelse {
                if (std.mem.eql(u8, it.val.?, "sm3")) {
                    u.err("cksum: sm3: algorithm not supported\n");
                    return 1;
                }
                u.errf("cksum: invalid argument '{s}' for '--algorithm'\nValid arguments are:\n  - 'bsd'\n  - 'sysv'\n  - 'crc'\n  - 'crc32b'\n  - 'md5'\n  - 'sha1'\n  - 'sha224'\n  - 'sha256'\n  - 'sha384'\n  - 'sha512'\n  - 'blake2b'\n  - 'sm3'\nTry 'cksum --help' for more information.\n", .{it.val.?});
                return 1;
            },
            'l' => {
                blen = std.fmt.parseInt(usize, it.val.?, 10) catch {
                    u.errf("cksum: invalid length: '{s}'\n", .{it.val.?});
                    return 1;
                };
                if (blen % 8 != 0 or blen > 512 or blen == 0 or (blen != 128 and blen != 160 and blen != 224 and blen != 256 and blen != 384 and blen != 512)) {
                    u.errf("cksum: invalid length: '{s}'\n", .{it.val.?});
                    return 1;
                }
            },
            'c' => check = true,
            130 => tag = true,
            131 => tag = false,
            'z' => zero = true,
            132 => raw = true,
            133 => b64 = true,
            'b' => bin = true,
            136 => quiet = true,
            137 => status = true,
            200 => {
                u.out("Usage: cksum [OPTION]... [FILE]...\nPrint or verify checksums.\n");
                return 0;
            },
            201 => {
                u.out("cksum (cmdbox)\n");
                return 0;
            },
            else => {},
        }
    }
    if (blen != 512 and algo != .blake2b) {
        u.err("cksum: --length is only supported with --algorithm=blake2b\n");
        return 1;
    }
    var files = p.operands;
    if (files.items.len == 0) files.push("-");
    if (check) return doCheck(files.items, quiet, status, algo);
    if (raw and files.items.len > 1) {
        u.err("cksum: the --raw option is not supported with multiple files\n");
        return 1;
    }
    var rc: u8 = 0;
    for (files.items) |name| {
        var f: u.File = undefined;
        const is_stdin = std.mem.eql(u8, name, "-");
        if (is_stdin) {
            f = .{ .fd = 0 };
        } else {
            if (u.stat(name, true)) |st| {
                if (st.mode & std.os.linux.S.IFMT == std.os.linux.S.IFDIR) {
                    u.errf("cksum: {s}: Is a directory\n", .{name});
                    rc = 1;
                    continue;
                }
            }
            f = u.File.open(name, .{ .ACCMODE = .RDONLY }, 0) orelse {
                const e = std.os.linux.open(u.zstr(name), .{ .ACCMODE = .RDONLY }, 0);
                u.errf("cksum: {s}: {s}\n", .{ name, u.strerr(u.errno(e)) });
                rc = 1;
                continue;
            };
        }
        const d = compute(algo, f, blen);
        if (!is_stdin) f.close();
        var o = u.Vec(u8).init(u.alloc);
        if (raw) {
            if (isDigestAlgo(algo)) {
                u.out(d.bytes[0..d.len]);
            } else {
                var rb: [4]u8 = undefined;
                std.mem.writeInt(u32, &rb, @truncate(d.num), .big);
                u.out(if (algo == .bsd or algo == .sysv) rb[2..4] else &rb);
            }
            continue;
        }
        var nb: [32]u8 = undefined;
        const tg = tagName(algo, blen, &nb);
        const use_tag = tag orelse isDigestAlgo(algo);
        var numbuf: [128]u8 = undefined;
        if (isDigestAlgo(algo)) {
            var hv = u.Vec(u8).init(u.alloc);
            if (b64) {
                const enc = std.base64.standard.Encoder;
                const out = u.alloc.alloc(u8, enc.calcSize(d.len)) catch return 1;
                _ = enc.encode(out, d.bytes[0..d.len]);
                for (out) |ch| hv.push(ch);
            } else hexOf(&hv, d.bytes[0..d.len]);
            if (use_tag) {
                for (tg) |ch| o.push(ch);
                for (" (") |ch| o.push(ch);
                for (name) |ch| o.push(ch);
                for (") = ") |ch| o.push(ch);
                for (hv.items) |ch| o.push(ch);
            } else {
                for (hv.items) |ch| o.push(ch);
                o.push(' ');
                o.push(if (bin) '*' else ' ');
                for (name) |ch| o.push(ch);
            }
        } else {
            const s: []const u8 = switch (algo) {
                .bsd => std.fmt.bufPrint(&numbuf, "{d:0>5} {d:>5}", .{ d.num, d.blocks }) catch "",
                .sysv => std.fmt.bufPrint(&numbuf, "{d} {d}", .{ d.num, d.blocks }) catch "",
                else => std.fmt.bufPrint(&numbuf, "{d} {d}", .{ d.num, d.size }) catch "",
            };
            if (false) { // GNU ignores --tag for the traditional (non-digest) algorithms
                for (tg) |ch| o.push(ch);
                for (" (") |ch| o.push(ch);
                for (name) |ch| o.push(ch);
                for (") = ") |ch| o.push(ch);
                var nb2: [32]u8 = undefined;
                const nstr = std.fmt.bufPrint(&nb2, "{d}", .{d.num}) catch "";
                for (nstr) |ch| o.push(ch);
            } else {
                for (s) |ch| o.push(ch);
                if (!is_stdin) {
                    o.push(' ');
                    for (name) |ch| o.push(ch);
                }
            }
        }
        o.push(if (zero) 0 else '\n');
        u.out(o.items);
    }
    return rc;
}

fn unhex(s: []const u8, out: []u8) ?usize {
    if (s.len % 2 != 0 or s.len / 2 > out.len) return null;
    var i: usize = 0;
    while (i < s.len) : (i += 2) {
        out[i / 2] = (std.fmt.charToDigit(s[i], 16) catch return null) << 4 | (std.fmt.charToDigit(s[i + 1], 16) catch return null);
    }
    return s.len / 2;
}

fn doCheck(files: []const []const u8, quiet: bool, status: bool, default_algo: Algo) u8 {
    _ = default_algo;
    var bad: usize = 0;
    var improper: usize = 0;
    var unreadable: usize = 0;
    var total_ok: usize = 0;
    var rc: u8 = 0;
    for (files) |cf| {
        var h: u.File = undefined;
        if (std.mem.eql(u8, cf, "-")) {
            h = .{ .fd = 0 };
        } else {
            h = u.File.open(cf, .{ .ACCMODE = .RDONLY }, 0) orelse {
                u.errf("cksum: {s}: No such file or directory\n", .{cf});
                rc = 1;
                continue;
            };
        }
        var lines = u.Vec([]const u8).init(u.alloc);
        u.readAllLines(&h, &lines);
        for (lines.items) |line| {
            // "ALGO (name) = hash" or "ALGO-n (name) = hash"
            const sp = std.mem.indexOf(u8, line, " (") orelse {
                improper += 1;
                continue;
            };
            const close = std.mem.lastIndexOf(u8, line, ") = ") orelse {
                improper += 1;
                continue;
            };
            if (close < sp + 2) {
                improper += 1;
                continue;
            }
            var an = line[0..sp];
            var bl: usize = 512;
            if (std.mem.startsWith(u8, an, "BLAKE2b")) {
                if (an.len > 8 and an[7] == '-') bl = std.fmt.parseInt(usize, an[8..], 10) catch 512;
                an = "blake2b";
            } else {
                var lower: [16]u8 = undefined;
                if (an.len > lower.len) {
                    improper += 1;
                    continue;
                }
                for (an, 0..) |ch, k| lower[k] = std.ascii.toLower(ch);
                an = lower[0..an.len];
            }
            const algo = algoByName(an) orelse {
                improper += 1;
                continue;
            };
            const name = line[sp + 2 .. close];
            const want = line[close + 4 ..];
            const f = u.File.open(name, .{ .ACCMODE = .RDONLY }, 0) orelse {
                if (!status) u.outf("{s}: FAILED open or read\n", .{name});
                unreadable += 1;
                continue;
            };
            const d = compute(algo, f, bl);
            f.close();
            var wantb: [64]u8 = undefined;
            const wn = unhex(want, &wantb);
            const okm = if (isDigestAlgo(algo)) (wn != null and wn.? == d.len and std.mem.eql(u8, wantb[0..wn.?], d.bytes[0..d.len])) else (std.fmt.parseInt(u64, want, 10) catch 0) == d.num;
            if (okm) {
                total_ok += 1;
                if (!quiet and !status) u.outf("{s}: OK\n", .{name});
            } else {
                bad += 1;
                if (!status) u.outf("{s}: FAILED\n", .{name});
            }
        }
    }
    const none_valid = total_ok == 0 and bad == 0 and unreadable == 0 and improper > 0;
    if (!status and !none_valid) {
        if (improper > 0) u.errf("cksum: WARNING: {d} line{s} {s} improperly formatted\n", .{ improper, if (improper == 1) "" else "s", if (improper == 1) "is" else "are" });
        if (unreadable > 0) u.errf("cksum: WARNING: {d} listed file{s} could not be read\n", .{ unreadable, if (unreadable == 1) "" else "s" });
        if (bad > 0) u.errf("cksum: WARNING: {d} computed checksum{s} did NOT match\n", .{ bad, if (bad == 1) "" else "s" });
    }
    if (total_ok == 0 and bad == 0 and unreadable == 0 and improper > 0) {
        if (!status) u.errf("cksum: {s}: no properly formatted checksum lines found\n", .{files[files.len - 1]});
        return 1;
    }
    if (bad > 0 or unreadable > 0 or rc != 0) return 1;
    return 0;
}
