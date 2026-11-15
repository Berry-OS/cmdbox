// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0
const std = @import("std");
const u = @import("util.zig");
const input = @import("input.zig");
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn run(args: []const []const u8) u8 {
    var decode = false;
    var ignore = false;
    var wrap: usize = 76;
    var name: ?[]const u8 = null;
    var options = true;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and same(arg, "--decode")) {
            decode = true;
            continue;
        }
        if (options and same(arg, "--ignore-garbage")) {
            ignore = true;
            continue;
        }
        if (options and std.mem.startsWith(u8, arg, "--wrap=")) {
            wrap = std.fmt.parseInt(usize, arg[7..], 10) catch return bad();
            continue;
        }
        if (options and arg.len > 1 and arg[0] == '-') {
            var k: usize = 1;
            while (k < arg.len) : (k += 1) switch (arg[k]) {
                'd' => decode = true,
                'i' => ignore = true,
                'w' => {
                    const value = if (k + 1 < arg.len) arg[k + 1 ..] else blk: {
                        i += 1;
                        if (i == args.len) return bad();
                        break :blk args[i];
                    };
                    wrap = std.fmt.parseInt(usize, value, 10) catch return bad();
                    break;
                },
                else => return bad(),
            };
        } else {
            if (name != null) return bad();
            name = arg;
        }
    }
    const data = input.read(name orelse "-", false) orelse return 1;
    if (!decode) {
        const size = std.base64.standard.Encoder.calcSize(data.len);
        const buffer = u.alloc.alloc(u8, size) catch return 1;
        const encoded = std.base64.standard.Encoder.encode(buffer, data);
        if (wrap == 0) u.out(encoded) else {
            var pos: usize = 0;
            while (pos < encoded.len) {
                const end = @min(encoded.len, pos +| wrap);
                u.out(encoded[pos..end]);
                u.out("\n");
                pos = end;
            }
        }
        return 0;
    }
    var quartet: [4]u8 = undefined;
    var count: usize = 0;
    for (data) |byte| {
        if (byte == '\n') continue;
        const value: u8 = if (byte >= 'A' and byte <= 'Z') byte - 'A' else if (byte >= 'a' and byte <= 'z') byte - 'a' + 26 else if (byte >= '0' and byte <= '9') byte - '0' + 52 else if (byte == '+') 62 else if (byte == '/') 63 else if (byte == '=') 64 else {
            if (ignore) continue;
            return bad();
        };
        if (value == 64 and count < 2) return bad();
        quartet[count] = value;
        count += 1;
        // Emit valid prefixes even if a subsequent byte is malformed.
        if (count == 2 and quartet[1] != 64) u.out(&.{(quartet[0] << 2) | (quartet[1] >> 4)});
        if (count == 3 and value != 64) u.out(&.{(quartet[1] << 4) | (value >> 2)});
        if (count == 4) {
            if (quartet[2] == 64 and value != 64) return bad();
            if (value != 64) u.out(&.{(quartet[2] << 6) | value});
            count = 0;
        }
    }
    return if (count == 0 or count == 2 or count == 3 and quartet[2] != 64) 0 else bad();
}
fn bad() u8 {
    u.errf("base64: invalid input or option\n", .{});
    return 1;
}
