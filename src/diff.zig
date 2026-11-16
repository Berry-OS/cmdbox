// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const u = @import("util.zig");
const input = @import("input.zig");
const color = @import("color.zig");
var colored = false;
var palette: []const u8 = "";
fn begin(key: []const u8, default_code: []const u8) bool {
    if (!colored) return false;
    var code = default_code;
    var entries = std.mem.splitScalar(u8, palette, ':');
    while (entries.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (same(entry[0..eq], key)) code = entry[eq + 1 ..];
    }
    if (code.len == 0) return false;
    u.outf("\x1b[{s}m", .{code});
    return true;
}
fn endColor(active: bool) void {
    if (active) u.out("\x1b[0m");
}
const c = @cImport({
    @cInclude("time.h");
});
const Flags = struct { insensitive: bool = false, whitespace: bool = false, space_change: bool = false, trailing: bool = false, strip_cr: bool = false };
const Line = struct { raw: []const u8, key: []const u8 };
const Edit = struct { kind: enum { equal, delete, insert }, left: usize, right: usize };
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn lines(data: []const u8, flags: Flags) u.Vec(Line) {
    var result = u.Vec(Line).init(u.alloc);
    var start: usize = 0;
    var pos: usize = 0;
    while (pos < data.len) {
        while (pos < data.len and data[pos] != '\n') pos += 1;
        if (pos < data.len) pos += 1;
        const raw = data[start..pos];
        start = pos;
        var key = u.Vec(u8).init(u.alloc);
        var text = raw;
        const terminated = raw.len > 0 and raw[raw.len - 1] == '\n';
        if (terminated) text = text[0 .. text.len - 1];
        if (flags.strip_cr and std.mem.endsWith(u8, text, "\r")) text = text[0 .. text.len - 1];
        if (flags.trailing or flags.space_change or flags.whitespace) text = std.mem.trimEnd(u8, text, " \t\r\x0b\x0c");
        var previous_space = false;
        for (text) |byte| {
            const space = std.ascii.isWhitespace(byte);
            if (flags.whitespace and space) continue;
            if (flags.space_change and space) {
                if (!previous_space) key.push(' ');
            } else key.push(if (flags.insensitive) std.ascii.toLower(byte) else byte);
            previous_space = space;
        }
        if (terminated) key.push('\n');
        result.push(.{ .raw = raw, .key = key.items });
    }
    return result;
}
fn edits(left: []const Line, right: []const Line) u.Vec(Edit) {
    var prefix: usize = 0;
    while (prefix < @min(left.len, right.len) and same(left[prefix].key, right[prefix].key)) prefix += 1;
    var end1 = left.len;
    var end2 = right.len;
    while (end1 > prefix and end2 > prefix and same(left[end1 - 1].key, right[end2 - 1].key)) {
        end1 -= 1;
        end2 -= 1;
    }
    var result = u.Vec(Edit).init(u.alloc);
    for (0..prefix) |index| result.push(.{ .kind = .equal, .left = index, .right = index });
    const middle = myers(left[prefix..end1], right[prefix..end2]);
    for (middle.items) |edit| result.push(.{ .kind = edit.kind, .left = edit.left + prefix, .right = edit.right + prefix });
    for (end1..left.len) |index| result.push(.{ .kind = .equal, .left = index, .right = end2 + index - end1 });
    return result;
}
fn myers(left: []const Line, right: []const Line) u.Vec(Edit) {
    const max = left.len + right.len;
    const offset: isize = @intCast(max + 1);
    const vector = u.alloc.alloc(isize, max * 2 + 3) catch @panic("oom");
    defer u.alloc.free(vector);
    @memset(vector, 0);
    var trace = u.Vec([]isize).init(u.alloc);
    defer {
        for (trace.items) |snapshot| u.alloc.free(snapshot);
        if (trace.cap > 0) u.alloc.free(trace.items.ptr[0..trace.cap]);
    }
    var found: usize = 0;
    search: for (0..max + 1) |distance| {
        // Bound trace memory; a single valid replacement is a fallback for
        // unrelated huge inputs, like diff's non-minimal heuristic mode.
        if (distance > 0 and vector.len > 10000000 / distance) return fallback(left, right);
        const d: isize = @intCast(distance);
        var k = -d;
        while (k <= d) : (k += 2) {
            const at: usize = @intCast(offset + k);
            var x = if (k == -d or k != d and vector[at - 1] < vector[at + 1]) vector[at + 1] else vector[at - 1] + 1;
            var y = x - k;
            while (x < left.len and y < right.len and same(left[@intCast(x)].key, right[@intCast(y)].key)) {
                x += 1;
                y += 1;
            }
            vector[at] = x;
            if (x >= left.len and y >= right.len) {
                found = distance;
                break :search;
            }
        }
        trace.push(u.alloc.dupe(isize, vector) catch @panic("oom"));
    }
    var result = u.Vec(Edit).init(u.alloc);
    var x: usize = left.len;
    var y: usize = right.len;
    var distance = found;
    while (distance > 0) : (distance -= 1) {
        const previous = trace.items[distance - 1];
        const k = @as(isize, @intCast(x)) - @as(isize, @intCast(y));
        const d: isize = @intCast(distance);
        const at: usize = @intCast(offset + k);
        const previous_k = if (k == -d or k != d and previous[at - 1] < previous[at + 1]) k + 1 else k - 1;
        const previous_x: usize = @intCast(previous[@intCast(offset + previous_k)]);
        const previous_y: usize = @intCast(@as(isize, @intCast(previous_x)) - previous_k);
        while (x > previous_x and y > previous_y) {
            x -= 1;
            y -= 1;
            result.push(.{ .kind = .equal, .left = x, .right = y });
        }
        if (x == previous_x) {
            y -= 1;
            result.push(.{ .kind = .insert, .left = x, .right = y });
        } else {
            x -= 1;
            result.push(.{ .kind = .delete, .left = x, .right = y });
        }
    }
    while (x > 0 and y > 0) {
        x -= 1;
        y -= 1;
        result.push(.{ .kind = .equal, .left = x, .right = y });
    }
    std.mem.reverse(Edit, result.items);
    return result;
}
fn fallback(left: []const Line, right: []const Line) u.Vec(Edit) {
    var result = u.Vec(Edit).init(u.alloc);
    var first: usize = 0;
    while (first < @min(left.len, right.len) and same(left[first].key, right[first].key)) : (first += 1) result.push(.{ .kind = .equal, .left = first, .right = first });
    var end1 = left.len;
    var end2 = right.len;
    while (end1 > first and end2 > first and same(left[end1 - 1].key, right[end2 - 1].key)) {
        end1 -= 1;
        end2 -= 1;
    }
    for (first..end1) |index| result.push(.{ .kind = .delete, .left = index, .right = first });
    for (first..end2) |index| result.push(.{ .kind = .insert, .left = end1, .right = index });
    for (end1..left.len) |index| result.push(.{ .kind = .equal, .left = index, .right = end2 + index - end1 });
    return result;
}
fn emit(prefix: []const u8, line: []const u8) void {
    const active = if (prefix.len > 0 and (prefix[0] == '-' or prefix[0] == '<')) begin("de", "31") else if (prefix.len > 0 and (prefix[0] == '+' or prefix[0] == '>')) begin("ad", "32") else false;
    const terminated = line.len > 0 and line[line.len - 1] == '\n';
    u.out(prefix);
    u.out(if (terminated) line[0 .. line.len - 1] else line);
    endColor(active);
    u.out("\n");
    if (!terminated) u.out("\\ No newline at end of file\n");
}
fn range(start: usize, count: usize, unified: bool) void {
    u.outf("{d}", .{if (count == 0) start else start + 1});
    if (unified and count != 1) u.outf(",{d}", .{count}) else if (!unified and count > 1) u.outf(",{d}", .{start + count});
}
fn header(prefix: []const u8, name: []const u8, label: ?[]const u8) void {
    const active = begin("hd", "1");
    if (label) |value| {
        u.outf("{s} {s}", .{ prefix, value });
        endColor(active);
        u.out("\n");
        return;
    }
    u.outf("{s} {s}", .{ prefix, name });
    if (u.stat(name, true)) |st| {
        var timestamp: c.time_t = @intCast(st.mtime);
        var local: c.struct_tm = undefined;
        if (c.localtime_r(&timestamp, &local) != null) {
            var date: [64]u8 = undefined;
            var zone: [16]u8 = undefined;
            const n = c.strftime(&date, date.len, "%Y-%m-%d %H:%M:%S", &local);
            const z = c.strftime(&zone, zone.len, "%z", &local);
            u.outf("\t{s}.{d:0>9} {s}", .{ date[0..n], @as(u64, st.mtime_nsec), zone[0..z] });
        }
    }
    endColor(active);
    u.out("\n");
}
pub fn run(args: []const []const u8) u8 {
    colored = false;
    palette = "";
    var color_mode: color.Mode = .never;
    var flags = Flags{};
    var unified = false;
    var context: usize = 3;
    var quiet = false;
    var identical = false;
    var text = false;
    var files = u.Vec([]const u8).init(u.alloc);
    var labels = u.Vec([]const u8).init(u.alloc);
    var options = true;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and std.mem.startsWith(u8, arg, "--")) {
            if (same(arg, "--color")) color_mode = .auto else if (std.mem.startsWith(u8, arg, "--color=")) color_mode = color.parse(arg[8..]) orelse return bad() else if (std.mem.startsWith(u8, arg, "--palette=")) palette = arg[10..] else if (same(arg, "--palette")) {
                i += 1;
                if (i == args.len) return bad();
                palette = args[i];
            } else if (same(arg, "--unified")) unified = true else if (std.mem.startsWith(u8, arg, "--unified=")) {
                unified = true;
                context = std.fmt.parseInt(usize, arg[10..], 10) catch return bad();
            } else if (same(arg, "--brief")) quiet = true else if (same(arg, "--report-identical-files")) identical = true else if (same(arg, "--ignore-case")) flags.insensitive = true else if (same(arg, "--ignore-all-space")) flags.whitespace = true else if (same(arg, "--ignore-space-change")) flags.space_change = true else if (same(arg, "--ignore-trailing-space")) flags.trailing = true else if (same(arg, "--strip-trailing-cr")) flags.strip_cr = true else if (same(arg, "--text")) text = true else if (std.mem.startsWith(u8, arg, "--label=")) labels.push(arg[8..]) else return bad();
        } else if (options and arg.len > 1 and arg[0] == '-') {
            var k: usize = 1;
            while (k < arg.len) : (k += 1) switch (arg[k]) {
                'u' => unified = true,
                'q' => quiet = true,
                's' => identical = true,
                'a' => text = true,
                'i' => flags.insensitive = true,
                'w' => flags.whitespace = true,
                'b' => flags.space_change = true,
                'Z' => flags.trailing = true,
                'U', 'L' => |flag| {
                    const value = if (k + 1 < arg.len) arg[k + 1 ..] else blk: {
                        i += 1;
                        if (i == args.len) return bad();
                        break :blk args[i];
                    };
                    if (flag == 'U') {
                        unified = true;
                        context = std.fmt.parseInt(usize, value, 10) catch return bad();
                    } else labels.push(value);
                    break;
                },
                else => return bad(),
            };
        } else files.push(arg);
    }
    if (files.items.len != 2 or labels.items.len > 2) return bad();
    colored = color.grepEnabled(color_mode);
    const a = input.read(files.items[0], false) orelse return 2;
    const b = input.read(files.items[1], false) orelse return 2;
    if (!text and (std.mem.indexOfScalar(u8, a, 0) != null or std.mem.indexOfScalar(u8, b, 0) != null)) {
        if (same(a, b)) {
            if (identical) u.outf("Files {s} and {s} are identical\n", .{ files.items[0], files.items[1] });
            return 0;
        }
        u.outf("{s} {s} and {s} differ\n", .{ if (quiet) "Files" else "Binary files", files.items[0], files.items[1] });
        return 1;
    }
    const left = lines(a, flags);
    const right = lines(b, flags);
    const changes = edits(left.items, right.items);
    var different = false;
    for (changes.items) |edit| if (edit.kind != .equal) {
        different = true;
        break;
    };
    if (!different) {
        if (identical) u.outf("Files {s} and {s} are identical\n", .{ files.items[0], files.items[1] });
        return 0;
    }
    if (quiet) {
        u.outf("Files {s} and {s} differ\n", .{ files.items[0], files.items[1] });
        return 1;
    }
    if (unified) {
        header("---", files.items[0], if (labels.items.len > 0) labels.items[0] else null);
        header("+++", files.items[1], if (labels.items.len > 1) labels.items[1] else null);
    }
    var pos: usize = 0;
    while (pos < changes.items.len) {
        if (changes.items[pos].kind == .equal) {
            pos += 1;
            continue;
        }
        var start = pos;
        var end = pos;
        while (end < changes.items.len and changes.items[end].kind != .equal) end += 1;
        if (unified) {
            start = start -| context;
            while (true) {
                var next = end;
                while (next < changes.items.len and changes.items[next].kind == .equal) next += 1;
                if (next < changes.items.len and next - end <= context *| 2) {
                    end = next;
                    while (end < changes.items.len and changes.items[end].kind != .equal) end += 1;
                } else {
                    end = @min(changes.items.len, end +| context);
                    break;
                }
            }
        }
        var a_count: usize = 0;
        var b_count: usize = 0;
        for (changes.items[start..end]) |edit| {
            if (edit.kind != .insert) a_count += 1;
            if (edit.kind != .delete) b_count += 1;
        }
        const first = changes.items[start];
        if (unified) {
            const active = begin("ln", "36");
            u.out("@@ -");
            range(first.left, a_count, true);
            u.out(" +");
            range(first.right, b_count, true);
            u.out(" @@");
            endColor(active);
            u.out("\n");
            for (changes.items[start..end]) |edit| switch (edit.kind) {
                .equal => emit(" ", left.items[edit.left].raw),
                .delete => emit("-", left.items[edit.left].raw),
                .insert => emit("+", right.items[edit.right].raw),
            };
        } else {
            const active = begin("ln", "36");
            range(first.left, a_count, false);
            u.out(if (a_count == 0) "a" else if (b_count == 0) "d" else "c");
            range(first.right, b_count, false);
            endColor(active);
            u.out("\n");
            for (changes.items[start..end]) |edit| if (edit.kind == .delete) emit("< ", left.items[edit.left].raw);
            if (a_count > 0 and b_count > 0) u.out("---\n");
            for (changes.items[start..end]) |edit| if (edit.kind == .insert) emit("> ", right.items[edit.right].raw);
        }
        pos = end;
    }
    return 1;
}
fn bad() u8 {
    u.errf("diff: invalid option or operands\n", .{});
    return 2;
}
