// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const u = @import("util.zig");
const linux = std.os.linux;
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn runInner(args: []const []const u8) u8 {
    var number = false;
    var nonblank = false;
    var squeeze = false;
    var ends = false;
    var tabs = false;
    var visible = false;
    var files = u.Vec([]const u8).init(u.alloc);
    var options = true;
    for (args) |arg| {
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and arg.len > 1 and arg[0] == '-') {
            if (same(arg, "--number")) number = true else if (same(arg, "--number-nonblank")) nonblank = true else if (same(arg, "--squeeze-blank")) squeeze = true else if (same(arg, "--show-ends")) ends = true else if (same(arg, "--show-tabs")) tabs = true else if (same(arg, "--show-nonprinting")) visible = true else if (same(arg, "--show-all")) {
                visible = true;
                tabs = true;
                ends = true;
            } else for (arg[1..]) |flag| switch (flag) {
                'n' => number = true,
                'b' => nonblank = true,
                's' => squeeze = true,
                'E' => ends = true,
                'T' => tabs = true,
                'v' => visible = true,
                'e' => {
                    visible = true;
                    ends = true;
                },
                't' => {
                    visible = true;
                    tabs = true;
                },
                'A' => {
                    visible = true;
                    tabs = true;
                    ends = true;
                },
                'u' => {},
                else => {
                    u.errf("cat: invalid option\n", .{});
                    return 1;
                },
            };
        } else files.push(arg);
    }
    if (files.items.len == 0) files.push("-");
    var first = true;
    var previous_blank = false;
    var line: u64 = 1;
    var failed = false;
    var buffer: [16384]u8 = undefined;
    const stdout = u.File{ .fd = 1 };
    for (files.items) |name| {
        const file = if (same(name, "-")) u.File{ .fd = 0 } else u.File.open(name, .{ .ACCMODE = .RDONLY }, 0) orelse {
            u.errf("cat: {s}: {s}\n", .{ name, u.strerr(u.errno(linux.open(u.zstr(name), .{ .ACCMODE = .RDONLY }, 0))) });
            failed = true;
            continue;
        };
        defer if (file.fd != 0) file.close();
        while (true) {
            const rc = linux.read(file.fd, &buffer, buffer.len);
            if (u.errno(rc) == .INTR) continue;
            if (!u.ok(rc)) {
                failed = true;
                break;
            }
            if (rc == 0) break;
            if (!number and !nonblank and !squeeze and !ends and !tabs and !visible) {
                if (!stdout.write(buffer[0..rc])) return 1;
                continue;
            }
            var output = u.Vec(u8).init(u.alloc);
            for (buffer[0..rc]) |byte| {
                if (first) {
                    const blank = byte == '\n';
                    if (squeeze and blank and previous_blank) continue;
                    if (nonblank and !blank or number and !nonblank) {
                        var buf: [32]u8 = undefined;
                        const text = std.fmt.bufPrint(&buf, "{d: >6}\t", .{line}) catch return 1;
                        for (text) |b| output.push(b);
                        line += 1;
                    }
                    previous_blank = blank;
                }
                first = byte == '\n';
                if (byte == '\n') {
                    if (ends) output.push('$');
                    output.push('\n');
                    continue;
                }
                if (byte == '\t' and tabs) {
                    output.push('^');
                    output.push('I');
                    continue;
                }
                var b = byte;
                if (visible) {
                    if (b >= 128) {
                        output.push('M');
                        output.push('-');
                        b -= 128;
                    }
                    if (b < 32 and (byte != '\t' or byte >= 128)) {
                        output.push('^');
                        output.push(b + 64);
                        continue;
                    }
                    if (b == 127) {
                        output.push('^');
                        output.push('?');
                        continue;
                    }
                }
                output.push(b);
            }
            const success = stdout.write(output.items);
            if (output.cap > 0) u.alloc.free(output.items.ptr[0..output.cap]);
            if (!success) return 1;
        }
    }
    return if (failed) 1 else 0;
}

pub fn run(args: []const []const u8) u8 {
    const g = @import("getopt.zig");
    const spec = g.Spec{
        .prog = "cat",
        .short = "AbeEnstTuv",
        .long = &.{ "show-all", "number-nonblank", "show-ends", "number", "squeeze-blank", "show-tabs", "show-nonprinting" },
        .help = "Usage: cat [OPTION]... [FILE]...\nConcatenate FILE(s) to standard output.\n",
    };
    switch (g.normalize(spec, args)) {
        .exit => |code| return code,
        .args => |a| return runInner(a),
    }
}
