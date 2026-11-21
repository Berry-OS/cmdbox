// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const u = @import("util.zig");
const linux = std.os.linux;
pub fn read(name: []const u8, silent: bool) ?[]u8 {
    const file = if (std.mem.eql(u8, name, "-")) u.File{ .fd = 0 } else u.File.open(name, .{ .ACCMODE = .RDONLY }, 0) orelse {
        if (!silent) {
            const e = u.errno(linux.open(u.zstr(name), .{ .ACCMODE = .RDONLY }, 0));
            u.errf("{s}: {s}: {s}\n", .{ u.applet_name, name, u.strerr(e) });
        }
        return null;
    };
    defer if (file.fd != 0) file.close();
    var data = u.Vec(u8).init(u.alloc);
    var buffer: [16384]u8 = undefined;
    while (true) {
        const rc = linux.read(file.fd, &buffer, buffer.len);
        if (u.errno(rc) == .INTR) continue;
        if (!u.ok(rc)) {
            if (!silent) u.errf("{s}: {s}: {s}\n", .{ u.applet_name, name, u.strerr(u.errno(rc)) });
            return null;
        }
        if (rc == 0) break;
        for (buffer[0..rc]) |byte| data.push(byte);
    }
    return data.items;
}
pub const Record = struct { text: []const u8, offset: usize, terminated: bool };
pub fn records(data: []const u8, delimiter: u8) u.Vec(Record) {
    var result = u.Vec(Record).init(u.alloc);
    var start: usize = 0;
    for (data, 0..) |byte, index| if (byte == delimiter) {
        result.push(.{ .text = data[start..index], .offset = start, .terminated = true });
        start = index + 1;
    };
    if (start < data.len) result.push(.{ .text = data[start..], .offset = start, .terminated = false });
    return result;
}
