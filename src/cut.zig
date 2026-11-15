// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const u = @import("util.zig");
const input = @import("input.zig");
const Range = struct { first: usize, last: usize };
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn selected(ranges: []const Range, number: usize, complement: bool) bool {
    var hit = false;
    for (ranges) |range| if (number >= range.first and number <= range.last) {
        hit = true;
        break;
    };
    return hit != complement;
}
pub fn run(args: []const []const u8) u8 {
    var ranges = u.Vec(Range).init(u.alloc);
    var files = u.Vec([]const u8).init(u.alloc);
    var fields = false;
    var mode_set = false;
    var complement = false;
    var suppress = false;
    var delimiter: u8 = '\t';
    var record_delimiter: u8 = '\n';
    var output_delimiter: ?[]const u8 = null;
    var options = true;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and std.mem.startsWith(u8, arg, "--")) {
            if (same(arg, "--complement")) {
                complement = true;
                continue;
            }
            if (same(arg, "--only-delimited")) {
                suppress = true;
                continue;
            }
            if (same(arg, "--zero-terminated")) {
                record_delimiter = 0;
                continue;
            }
            const eq = std.mem.indexOfScalar(u8, arg, '=');
            const name = arg[0 .. eq orelse arg.len];
            const value = if (eq) |at| arg[at + 1 ..] else blk: {
                i += 1;
                if (i == args.len) return bad();
                break :blk args[i];
            };
            if (same(name, "--fields") or same(name, "--bytes") or same(name, "--characters")) {
                if (mode_set) return bad();
                mode_set = true;
                fields = same(name, "--fields");
                if (!parseRanges(value, &ranges)) return bad();
            } else if (same(name, "--delimiter")) {
                if (value.len > 1) return bad();
                delimiter = if (value.len == 0) 0 else value[0];
            } else if (same(name, "--output-delimiter")) output_delimiter = if (value.len == 0) &.{0} else value else return bad();
            continue;
        }
        if (options and arg.len > 1 and arg[0] == '-') {
            var k: usize = 1;
            while (k < arg.len) : (k += 1) switch (arg[k]) {
                's' => suppress = true,
                'z' => record_delimiter = 0,
                'n' => {},
                'b', 'c', 'f', 'd' => |flag| {
                    const value = if (k + 1 < arg.len) arg[k + 1 ..] else blk: {
                        i += 1;
                        if (i == args.len) return bad();
                        break :blk args[i];
                    };
                    if (flag == 'd') {
                        if (value.len > 1) return bad();
                        delimiter = if (value.len == 0) 0 else value[0];
                    } else {
                        if (mode_set) return bad();
                        mode_set = true;
                        fields = flag == 'f';
                        if (!parseRanges(value, &ranges)) return bad();
                    }
                    break;
                },
                else => return bad(),
            };
            continue;
        }
        files.push(arg);
    }
    if (!mode_set or !fields and suppress) return bad();
    if (files.items.len == 0) files.push("-");
    const separator = [_]u8{delimiter};
    const ending = [_]u8{record_delimiter};
    var failed = false;
    for (files.items) |name| {
        const data = input.read(name, false) orelse {
            failed = true;
            continue;
        };
        const records = input.records(data, record_delimiter);
        for (records.items) |record| {
            if (fields) {
                if (std.mem.indexOfScalar(u8, record.text, delimiter) == null) {
                    if (!suppress) {
                        u.out(record.text);
                        u.out(&ending);
                    }
                    continue;
                }
                var parts = std.mem.splitScalar(u8, record.text, delimiter);
                var number: usize = 1;
                var emitted = false;
                while (parts.next()) |part| : (number += 1) {
                    if (selected(ranges.items, number, complement)) {
                        if (emitted) u.out(output_delimiter orelse &separator);
                        emitted = true;
                        u.out(part);
                    }
                }
            } else {
                var previous = false;
                var emitted = false;
                for (record.text, 1..) |byte, number| {
                    const hit = selected(ranges.items, number, complement);
                    if (hit) {
                        if (!previous and emitted and output_delimiter != null) u.out(output_delimiter.?);
                        u.out(&.{byte});
                        emitted = true;
                    }
                    previous = hit;
                }
            }
            u.out(&ending);
        }
    }
    return if (failed) 1 else 0;
}
fn parseRanges(list: []const u8, ranges: *u.Vec(Range)) bool {
    var parts = std.mem.tokenizeAny(u8, list, ", \t");
    const before = ranges.items.len;
    while (parts.next()) |part| {
        var first: usize = 1;
        var last: usize = std.math.maxInt(usize);
        if (std.mem.indexOfScalar(u8, part, '-')) |at| {
            if (at == 0 and part.len == 1) return false;
            if (at > 0) first = std.fmt.parseInt(usize, part[0..at], 10) catch return false;
            if (at + 1 < part.len) last = std.fmt.parseInt(usize, part[at + 1 ..], 10) catch return false;
        } else {
            first = std.fmt.parseInt(usize, part, 10) catch return false;
            last = first;
        }
        if (first == 0 or last < first) return false;
        ranges.push(.{ .first = first, .last = last });
    }
    return before != ranges.items.len;
}
fn bad() u8 {
    u.errf("cut: invalid option or range\n", .{});
    return 1;
}
