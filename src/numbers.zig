// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const u = @import("util.zig");
const linux = std.os.linux;
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
});
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn sleep(args: []const []const u8) u8 {
    if (args.len == 0) return bad("sleep");
    var total: f64 = 0;
    var any = false;
    for (args) |arg| {
        if (same(arg, "--")) continue;
        const text = u.zstr(arg);
        var end: [*c]u8 = undefined;
        var value = c.strtod(text, &end);
        if (end == text.ptr or value < 0 or std.math.isNan(value)) return bad("sleep");
        const suffix = std.mem.sliceTo(end, 0);
        if (suffix.len > 0) {
            if (suffix.len != 1) return bad("sleep");
            value *= switch (suffix[0]) {
                's' => @as(f64, 1),
                'm' => 60,
                'h' => 3600,
                'd' => 86400,
                else => return bad("sleep"),
            };
        }
        total += value;
        any = true;
    }
    if (!any) return bad("sleep");
    while (total > 0) {
        const seconds: i32 = @intFromFloat(@min(@floor(total), 1 << 30));
        const nanos: i32 = if (total < 1 << 30) @intFromFloat(@min((total - @floor(total)) * 1000000000, 999999999)) else 0;
        var request = linux.timespec{ .sec = seconds, .nsec = nanos };
        var remainder: linux.timespec = undefined;
        while (true) {
            const rc = linux.nanosleep(&request, &remainder);
            if (u.ok(rc)) break;
            if (u.errno(rc) != .INTR) return 1;
            request = remainder;
        }
        total -= @as(f64, @floatFromInt(seconds)) + @as(f64, @floatFromInt(nanos)) / 1000000000;
        if (seconds == 0 and nanos == 0) break;
    }
    return 0;
}
fn precision(text: []const u8) usize {
    if (std.mem.indexOfAny(u8, text, "eEpP")) |_| return 0;
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return 0;
    return text.len - dot - 1;
}
fn decimal(text: []const u8) ?f64 {
    const value = u.zstr(text);
    var end: [*c]u8 = undefined;
    const number = c.strtod(value, &end);
    if (end == value.ptr or end[0] != 0 or !std.math.isFinite(number)) return null;
    return number;
}
pub fn seq(args: []const []const u8) u8 {
    var separator: []const u8 = "\n";
    var format: ?[]const u8 = null;
    var equal = false;
    var values = u.Vec([]const u8).init(u.alloc);
    var options = true;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and (same(arg, "-w") or same(arg, "--equal-width"))) {
            equal = true;
            continue;
        }
        if (options and (std.mem.startsWith(u8, arg, "--separator=") or std.mem.startsWith(u8, arg, "--format="))) {
            const at = std.mem.indexOfScalar(u8, arg, '=').?;
            if (same(arg[0..at], "--format")) format = arg[at + 1 ..] else separator = arg[at + 1 ..];
            continue;
        }
        if (options and arg.len > 1 and arg[0] == '-' and (arg[1] == 's' or arg[1] == 'f')) {
            const value = if (arg.len > 2) arg[2..] else blk: {
                i += 1;
                if (i == args.len) return bad("seq");
                break :blk args[i];
            };
            if (arg[1] == 's') separator = value else format = value;
            continue;
        }
        values.push(arg);
    }
    if (values.items.len == 0 or values.items.len > 3 or equal and format != null) return bad("seq");
    const first_text = if (values.items.len > 1) values.items[0] else "1";
    const step_text = if (values.items.len > 2) values.items[1] else "1";
    const first = decimal(first_text) orelse return bad("seq");
    const step = decimal(step_text) orelse return bad("seq");
    const last_text = values.items[values.items.len - 1];
    const last = decimal(last_text) orelse return bad("seq");
    if (step == 0) return bad("seq");
    const digits = @max(precision(first_text), precision(step_text));
    var spec_buffer: [64]u8 = undefined;
    var spec: []const u8 = format orelse "%g";
    if (format == null) {
        const fixed = std.mem.indexOfAny(u8, first_text, "eEpP") == null and std.mem.indexOfAny(u8, step_text, "eEpP") == null;
        if (equal) {
            const width = @max(first_text.len, last_text.len);
            spec = std.fmt.bufPrint(&spec_buffer, "%0{d}.{d}f", .{ width, digits }) catch return 1;
        } else if (fixed) spec = std.fmt.bufPrint(&spec_buffer, "%.{d}f", .{digits}) catch return 1;
    }
    if (format) |custom| {
        var conversions: usize = 0;
        var at: usize = 0;
        while (at < custom.len) : (at += 1) if (custom[at] == '%') {
            at += 1;
            if (at == custom.len) return bad("seq");
            if (custom[at] == '%') continue;
            conversions += 1;
            while (at < custom.len and std.mem.indexOfScalar(u8, "-+ #0.0123456789", custom[at]) != null) at += 1;
            if (at == custom.len or std.mem.indexOfScalar(u8, "aAeEfFgG", custom[at]) == null) return bad("seq");
        };
        if (conversions != 1) return bad("seq");
    }
    var n: u64 = 0;
    while (true) : (n += 1) {
        const number = first + @as(f64, @floatFromInt(n)) * step;
        if (step > 0 and number > last + @abs(step) * 1e-12 or step < 0 and number < last - @abs(step) * 1e-12) break;
        if (n > 0) u.out(separator);
        var text: [128]u8 = undefined;
        const size = c.snprintf(&text, text.len, "%.17g", number);
        if (size < 0 or size >= text.len) return 1;
        const code = @import("printf.zig").run(&.{ spec, text[0..@intCast(size)] });
        if (code != 0) return code;
        if (n == std.math.maxInt(u64)) break;
    }
    if (n > 0) u.out("\n");
    return 0;
}
fn bad(name: []const u8) u8 {
    u.errf("{s}: invalid numeric argument\n", .{name});
    return 1;
}
