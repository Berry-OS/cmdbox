// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// text.zig - text processing applets
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");

const out = u.out;
const outf = u.outf;
const errf = u.errf;

pub const wc = @import("wc.zig").run;

// ================= head / tail =================
pub const head = @import("headtail.zig").head;
pub const tail = @import("headtail.zig").tail;

// ================= grep =================
pub const grep = @import("grep.zig").run;

pub const sed = @import("sed.zig").run;

// ================= tr =================
pub const tr = @import("tr.zig").run;

// ================= sort / uniq =================
pub const sort = @import("sort.zig").run;
pub const uniq = @import("uniq.zig").run;

// ================= cmp / diff =================
pub fn cmp(args: []const []const u8) u8 {
    var files = u.Vec([]const u8).init(u.alloc);
    var silent = false;
    var options = true;
    for (args) |arg| {
        if (options and std.mem.eql(u8, arg, "--")) {
            options = false;
            continue;
        }
        if (options and (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--silent") or std.mem.eql(u8, arg, "--quiet"))) {
            silent = true;
            continue;
        }
        if (options and arg.len > 1 and arg[0] == '-') {
            errf("cmp: unsupported option: {s}\n", .{arg});
            return 2;
        }
        files.push(arg);
    }
    if (files.items.len < 1 or files.items.len > 2) {
        errf("cmp: file1 [file2] required\n", .{});
        return 2;
    }
    if (files.items.len == 1) files.push("-");
    const n1 = files.items[0];
    const n2 = files.items[1];
    const f1 = compareFile(n1) orelse return 2;
    defer if (f1.fd != 0) f1.close();
    const f2 = compareFile(n2) orelse return 2;
    defer if (f2.fd != 0) f2.close();
    var b1: [4096]u8 = undefined;
    var b2: [4096]u8 = undefined;
    var byte_no: u64 = 0;
    var line_no: u64 = 1;
    while (true) {
        const size1 = compareRead(f1, &b1) orelse return 2;
        const size2 = compareRead(f2, &b2) orelse return 2;
        for (0..@min(size1, size2)) |k| {
            byte_no += 1;
            if (b1[k] != b2[k]) {
                if (!silent) outf("{s} {s} differ: byte {d}, line {d}\n", .{ n1, n2, byte_no, line_no });
                return 1;
            }
            if (b1[k] == '\n') line_no += 1;
        }
        if (size1 != size2) {
            if (!silent) errf("cmp: EOF on {s} after byte {d}, line {d}\n", .{ if (size1 < size2) n1 else n2, byte_no, line_no });
            return 1;
        }
        if (size1 == 0) return 0;
    }
}

fn compareFile(name: []const u8) ?u.File {
    if (std.mem.eql(u8, name, "-")) return u.File{ .fd = 0 };
    return u.File.open(name, .{ .ACCMODE = .RDONLY }, 0) orelse {
        errf("cmp: {s}: {s}\n", .{ name, u.strerr(u.errno(linux.open(u.zstr(name), .{ .ACCMODE = .RDONLY }, 0))) });
        return null;
    };
}

fn compareRead(file: u.File, buffer: []u8) ?usize {
    var used: usize = 0;
    while (used < buffer.len) {
        const rc = linux.read(file.fd, buffer.ptr + used, buffer.len - used);
        if (u.errno(rc) == .INTR) continue;
        if (!u.ok(rc)) {
            errf("compare: read error\n", .{});
            return null;
        }
        if (rc == 0) break;
        used += rc;
    }
    return used;
}

pub const diff = @import("diff.zig").run;

// ================= cksum =================
pub fn cksum(args: []const []const u8) u8 {
    var files = u.Vec([]const u8).init(u.alloc);
    for (args) |arg| {
        if (arg.len > 1 and arg[0] == '-') continue;
        files.push(arg);
    }
    if (files.items.len == 0) files.push("-");
    var fail = false;
    for (files.items) |fname| {
        const f = if (std.mem.eql(u8, fname, "-"))
            u.File{ .fd = 0 }
        else
            (u.File.open(fname, .{ .ACCMODE = .RDONLY }, 0) orelse {
                errf("cksum: {s}: cannot open\n", .{fname});
                fail = true;
                continue;
            });
        var crc: u32 = 0;
        var len: u64 = 0;
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = f.read(&buf);
            if (n == 0) break;
            len += n;
            for (buf[0..n]) |b| {
                crc ^= @as(u32, b) << 24;
                var k: usize = 0;
                while (k < 8) : (k += 1) {
                    if (crc & 0x80000000 != 0) {
                        crc = (crc << 1) ^ 0x04C11DB7;
                    } else {
                        crc <<= 1;
                    }
                }
            }
        }
        if (!std.mem.eql(u8, fname, "-")) f.close();
        // POSIX cksum appends the length, least significant byte first,
        // then complements the CRC (not the raw Ethernet CRC).
        var remaining = len;
        while (remaining != 0) : (remaining >>= 8) {
            crc ^= @as(u32, @intCast(remaining & 255)) << 24;
            for (0..8) |_| crc = if (crc & 0x80000000 != 0)
                (crc << 1) ^ 0x04C11DB7
            else
                crc << 1;
        }
        outf("{d} {d}", .{ ~crc, len });
        if (args.len > 0) outf(" {s}", .{fname});
        out("\n");
    }
    return if (fail) 1 else 0;
}
