// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0
const std = @import("std");
const u = @import("util.zig");
const linux = std.os.linux;
const input = @import("input.zig");
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn md5(args: []const []const u8) u8 {
    return run(std.crypto.hash.Md5, "MD5", args);
}
pub fn sha1(args: []const []const u8) u8 {
    return run(std.crypto.hash.Sha1, "SHA1", args);
}
pub fn sha256(args: []const []const u8) u8 {
    return run(std.crypto.hash.sha2.Sha256, "SHA256", args);
}
fn digest(comptime Hash: type, name: []const u8, silent: bool) ?[Hash.digest_length * 2]u8 {
    const file = if (same(name, "-")) u.File{ .fd = 0 } else u.File.open(name, .{ .ACCMODE = .RDONLY }, 0) orelse {
        if (!silent) u.errf("{s}: {s}: {s}\n", .{ u.applet_name, name, u.strerr(u.errno(linux.open(u.zstr(name), .{ .ACCMODE = .RDONLY }, 0))) });
        return null;
    };
    defer if (file.fd != 0) file.close();
    var state = Hash.init(.{});
    var buffer: [32768]u8 = undefined;
    while (true) {
        const rc = linux.read(file.fd, &buffer, buffer.len);
        if (u.errno(rc) == .INTR) continue;
        if (!u.ok(rc)) return null;
        if (rc == 0) break;
        state.update(buffer[0..rc]);
    }
    var bytes: [Hash.digest_length]u8 = undefined;
    state.final(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}
fn escaped(name: []const u8) bool {
    return std.mem.indexOfAny(u8, name, "\\\n\r") != null;
}
fn printName(name: []const u8) void {
    for (name) |byte| switch (byte) {
        '\\' => u.out("\\\\"),
        '\n' => u.out("\\n"),
        '\r' => u.out("\\r"),
        else => u.out(&.{byte}),
    };
}
fn unescape(text: []const u8) ?[]const u8 {
    var result = u.Vec(u8).init(u.alloc);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') {
            i += 1;
            if (i == text.len) return null;
            result.push(switch (text[i]) {
                '\\' => '\\',
                'n' => '\n',
                'r' => '\r',
                else => return null,
            });
        } else result.push(text[i]);
    }
    return result.items;
}
fn run(comptime Hash: type, comptime label: []const u8, args: []const []const u8) u8 {
    var zero = false;
    var check = false;
    var binary = false;
    var tag = false;
    var quiet = false;
    var status = false;
    var strict = false;
    var ignore_missing = false;
    var files = u.Vec([]const u8).init(u.alloc);
    var options = true;
    for (args) |arg| {
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and same(arg, "--zero")) {
            zero = true;
            continue;
        }
        if (options and same(arg, "--check")) {
            check = true;
            continue;
        }
        if (options and same(arg, "--binary")) {
            binary = true;
            continue;
        }
        if (options and same(arg, "--text")) {
            binary = false;
            continue;
        }
        if (options and same(arg, "--tag")) {
            tag = true;
            continue;
        }
        if (options and same(arg, "--quiet")) {
            quiet = true;
            continue;
        }
        if (options and same(arg, "--status")) {
            status = true;
            continue;
        }
        if (options and same(arg, "--strict")) {
            strict = true;
            continue;
        }
        if (options and same(arg, "--warn")) continue;
        if (options and same(arg, "--ignore-missing")) {
            ignore_missing = true;
            continue;
        }
        if (options and arg.len > 1 and arg[0] == '-') {
            for (arg[1..]) |flag| switch (flag) {
                'c' => check = true,
                'z' => zero = true,
                'b' => binary = true,
                't' => binary = false,
                'w' => {},
                else => return bad(),
            };
        } else files.push(arg);
    }
    if ((quiet or status or strict or ignore_missing) and !check or tag and check or zero and check) return bad();
    if (files.items.len == 0) files.push("-");
    var failed = false;
    const prog = u.applet_name;
    for (files.items) |file| {
        if (!check) {
            const value = digest(Hash, file, false) orelse {
                failed = true;
                continue;
            };
            const escape = !zero and escaped(file);
            if (escape) u.out("\\");
            if (tag) {
                u.out(label ++ " (");
                if (zero) u.out(file) else printName(file);
                u.outf(") = {s}", .{value});
                u.out(if (zero) &.{0} else "\n");
            } else {
                u.out(&value);
                u.out(if (binary) " *" else "  ");
                if (zero) u.out(file) else printName(file);
                u.out(if (zero) &.{0} else "\n");
            }
            continue;
        }
        const data = input.read(file, status) orelse {
            failed = true;
            continue;
        };
        const records = input.records(data, '\n');
        var valid: usize = 0;
        var checked: usize = 0;
        var improper: usize = 0;
        var mismatched: usize = 0;
        var unreadable: usize = 0;
        for (records.items) |record| {
            var line = record.text;
            if (line.len == 0 or line[0] == '#') continue;
            const escape = line[0] == '\\';
            if (escape) line = line[1..];
            const len = Hash.digest_length * 2;
            var hex: []const u8 = undefined;
            var raw_name: []const u8 = undefined;
            if (std.mem.startsWith(u8, line, label ++ " (")) {
                const end = std.mem.lastIndexOf(u8, line, ") = ") orelse {
                    {
                    improper += 1;
                    if (strict) failed = true;
                }
                    continue;
                };
                raw_name = line[label.len + 2 .. end];
                hex = line[end + 4 ..];
            } else {
                if (line.len < len + 2 or line[len] != ' ' or line[len + 1] != ' ' and line[len + 1] != '*') {
                    {
                    improper += 1;
                    if (strict) failed = true;
                }
                    continue;
                }
                hex = line[0..len];
                raw_name = line[len + 2 ..];
            }
            if (hex.len != len) {
                {
                    improper += 1;
                    if (strict) failed = true;
                }
                continue;
            }
            var expected: [Hash.digest_length]u8 = undefined;
            _ = std.fmt.hexToBytes(&expected, hex) catch {
                {
                    improper += 1;
                    if (strict) failed = true;
                }
                continue;
            };
            const filename = if (escape) unescape(raw_name) orelse {
                {
                    improper += 1;
                    if (strict) failed = true;
                }
                continue;
            } else raw_name;
            valid += 1;
            if (ignore_missing and u.stat(filename, true) == null) continue;
            const actual = digest(Hash, filename, status) orelse {
                failed = true;
                unreadable += 1;
                if (!status) printStatus(filename, "FAILED open or read");
                continue;
            };
            checked += 1;
            if (!std.ascii.eqlIgnoreCase(&actual, hex)) {
                failed = true;
                mismatched += 1;
                if (!status) printStatus(filename, "FAILED");
            } else if (!quiet and !status) printStatus(filename, "OK");
        }
        if (valid == 0) {
            if (!status) u.errf("{s}: {s}: no properly formatted checksum lines found\n", .{ prog, file });
        } else if (!status) {
            if (improper > 0) u.errf("{s}: WARNING: {d} line{s} {s} improperly formatted\n", .{ prog, improper, if (improper == 1) "" else "s", if (improper == 1) "is" else "are" });
            if (unreadable > 0) u.errf("{s}: WARNING: {d} listed file{s} could not be read\n", .{ prog, unreadable, if (unreadable == 1) "" else "s" });
            if (mismatched > 0) u.errf("{s}: WARNING: {d} computed checksum{s} did NOT match\n", .{ prog, mismatched, if (mismatched == 1) "" else "s" });
        }
        if (valid == 0 or checked == 0) failed = true;
    }
    return if (failed) 1 else 0;
}
fn printStatus(name: []const u8, result: []const u8) void {
    if (escaped(name)) u.out("\\");
    printName(name);
    u.outf(": {s}\n", .{result});
}
fn bad() u8 {
    u.errf("checksum: invalid option\n", .{});
    return 1;
}
