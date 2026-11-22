// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// rpm2cpio - write the cpio payload of an rpm package to stdout (gzip, xz, bzip2, lzma and zstd payloads)
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");

fn readAll(fd: i32) ?[]u8 {
    var data = u.Vec(u8).init(u.alloc);
    var buf: [1 << 16]u8 = undefined;
    while (true) {
        const r = linux.read(fd, &buf, buf.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r)) return null;
        if (r == 0) break;
        data.pushSlice(buf[0..r]);
    }
    return data.items;
}

fn writeAll(fd: i32, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const r = linux.write(fd, data.ptr + off, data.len - off);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r)) return false;
        off += r;
    }
    return true;
}

fn headerEnd(d: []const u8, off: usize) ?usize {
    if (off + 16 > d.len) return null;
    if (d[off] != 0x8e or d[off + 1] != 0xad or d[off + 2] != 0xe8) return null;
    const n: usize = std.mem.readInt(u32, d[off + 8 ..][0..4], .big);
    const hs: usize = std.mem.readInt(u32, d[off + 12 ..][0..4], .big);
    const end = off + 16 + n * 16 + hs;
    if (end > d.len) return null;
    return end;
}

fn execDecoder(applet: []const u8, payload: []const u8) u8 {
    var fds: [2]i32 = undefined;
    if (!u.ok(linux.pipe(&fds))) return 1;
    const pid = linux.fork();
    if (!u.ok(pid)) return 1;
    if (pid == 0) {
        _ = linux.close(fds[0]);
        _ = writeAll(fds[1], payload);
        linux.exit_group(0);
    }
    _ = linux.close(fds[1]);
    _ = linux.dup2(fds[0], 0);
    _ = linux.close(fds[0]);
    var av = [_:null]?[*:0]const u8{ u.zstr(applet).ptr, null };
    _ = linux.execve("/proc/self/exe", &av, u.envp(&.{}));
    u.errf("rpm2cpio: cannot run {s}\n", .{applet});
    return 1;
}

fn zstdPayload(payload: []const u8) u8 {
    const window: u32 = 1 << 26;
    const buf = u.alloc.alloc(u8, window + std.compress.zstd.block_size_max) catch {
        u.err("rpm2cpio: out of memory\n");
        return 1;
    };
    var in = std.Io.Reader.fixed(payload);
    var d = std.compress.zstd.Decompress.init(&in, buf, .{ .window_len = window });
    var out: [1 << 16]u8 = undefined;
    while (true) {
        const n = d.reader.readSliceShort(&out) catch {
            u.err("rpm2cpio: skipping bad zstd payload\n");
            return 1;
        };
        if (n == 0) break;
        if (!writeAll(1, out[0..n])) return 1;
        if (n < out.len) {
            // a short read means the end of the stream
            const more = d.reader.readSliceShort(out[0..1]) catch return 1;
            if (more == 0) break;
            if (!writeAll(1, out[0..more])) return 1;
        }
    }
    return 0;
}

pub fn run(args: []const []const u8) u8 {
    var name: []const u8 = "-";
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            u.out("Usage: rpm2cpio [file.rpm]\n");
            return 0;
        }
        name = a;
    }
    var fd: i32 = 0;
    if (!std.mem.eql(u8, name, "-")) {
        const rc = linux.open(u.zstr(name), .{ .ACCMODE = .RDONLY }, 0);
        if (!u.ok(rc)) {
            u.errf("rpm2cpio: {s}: {s}\n", .{ name, u.strerr(u.errno(rc)) });
            return 1;
        }
        fd = @intCast(rc);
    } else {
        var t: linux.termios = undefined;
        if (u.ok(linux.ioctl(0, 0x5401, @intFromPtr(&t)))) {
            u.err("Usage: rpm2cpio [file.rpm]\n");
            return 1;
        }
    }
    const d = readAll(fd) orelse {
        u.err("rpm2cpio: read error\n");
        return 1;
    };
    if (d.len < 96 or !std.mem.eql(u8, d[0..4], "\xed\xab\xee\xdb")) {
        u.errf("rpm2cpio: {s}: not an rpm package (or package manifest)\n", .{if (std.mem.eql(u8, name, "-")) "(stdin)" else name});
        return 1;
    }
    var off = headerEnd(d, 96) orelse {
        u.errf("rpm2cpio: {s}: bad signature header\n", .{name});
        return 1;
    };
    off = (off + 7) & ~@as(usize, 7);
    off = headerEnd(d, off) orelse {
        u.errf("rpm2cpio: {s}: bad header\n", .{name});
        return 1;
    };
    const p = d[off..];
    if (p.len >= 2 and p[0] == 0x1f and p[1] == 0x8b) return execDecoder("zcat", p);
    if (p.len >= 6 and std.mem.eql(u8, p[0..6], "\xFD7zXZ\x00")) return execDecoder("xzcat", p);
    if (p.len >= 3 and std.mem.eql(u8, p[0..3], "BZh")) return execDecoder("bzcat", p);
    if (p.len >= 4 and std.mem.eql(u8, p[0..4], "\x28\xb5\x2f\xfd")) return zstdPayload(p);
    if (p.len >= 3 and p[0] == 0x5d and p[1] == 0 and p[2] == 0) return execDecoder("lzcat", p);
    if (!writeAll(1, p)) return 1;
    return 0;
}
