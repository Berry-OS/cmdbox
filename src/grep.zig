// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const u = @import("util.zig");
const input = @import("input.zig");
const re = @import("regex.zig");
const color = @import("color.zig");
const Options = struct {
    color_mode: color.Mode = .never,
    colored: bool = false,
    extended: bool = false,
    fixed: bool = false,
    insensitive: bool = false,
    invert: bool = false,
    number: bool = false,
    bytes: bool = false,
    count: bool = false,
    quiet: bool = false,
    only: bool = false,
    list: bool = false,
    list_without: bool = false,
    silent: bool = false,
    word: bool = false,
    whole: bool = false,
    recursive: bool = false,
    follow: bool = false,
    text: bool = false,
    ignore_binary: bool = false,
    no_filename: bool = false,
    filename: bool = false,
    null_filename: bool = false,
    delimiter: u8 = '\n',
    before: usize = 0,
    after: usize = 0,
    max: usize = std.math.maxInt(usize),
};
const Pattern = struct { text: []const u8, regex: ?re.Regex = null };
const Hit = struct { start: usize, end: usize };
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn addPatterns(patterns: *u.Vec(Pattern), text: []const u8) void {
    var parts = std.mem.splitScalar(u8, text, '\n');
    while (parts.next()) |p| patterns.push(.{ .text = p });
}
pub fn run(args: []const []const u8) u8 {
    var opts = Options{};
    var patterns = u.Vec(Pattern).init(u.alloc);
    var files = u.Vec([]const u8).init(u.alloc);
    var explicit = false;
    var options = true;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and std.mem.startsWith(u8, arg, "--")) {
            if (same(arg, "--color") or same(arg, "--colour")) opts.color_mode = .auto else if (std.mem.startsWith(u8, arg, "--color=") or std.mem.startsWith(u8, arg, "--colour=")) opts.color_mode = color.parse(arg[(std.mem.indexOfScalar(u8, arg, '=').? + 1)..]) orelse return bad(arg) else if (same(arg, "--extended-regexp")) opts.extended = true else if (same(arg, "--basic-regexp")) opts.extended = false else if (same(arg, "--fixed-strings")) opts.fixed = true else if (same(arg, "--ignore-case")) opts.insensitive = true else if (same(arg, "--invert-match")) opts.invert = true else if (same(arg, "--line-number")) opts.number = true else if (same(arg, "--count")) opts.count = true else if (same(arg, "--quiet") or same(arg, "--silent")) opts.quiet = true else if (same(arg, "--only-matching")) opts.only = true else if (same(arg, "--word-regexp")) opts.word = true else if (same(arg, "--line-regexp")) opts.whole = true else if (same(arg, "--recursive")) opts.recursive = true else if (same(arg, "--no-filename")) opts.no_filename = true else if (same(arg, "--with-filename")) opts.filename = true else if (same(arg, "--files-with-matches")) opts.list = true else if (same(arg, "--files-without-match")) opts.list_without = true else if (same(arg, "--text")) opts.text = true else if (same(arg, "--no-messages")) opts.silent = true else if (same(arg, "--null-data")) opts.delimiter = 0 else {
                const eq = std.mem.indexOfScalar(u8, arg, '=');
                const name = arg[0 .. eq orelse arg.len];
                const value = if (eq) |at| arg[at + 1 ..] else blk: {
                    i += 1;
                    if (i >= args.len) return bad(arg);
                    break :blk args[i];
                };
                if (same(name, "--regexp")) {
                    addPatterns(&patterns, value);
                    explicit = true;
                } else if (same(name, "--file")) {
                    if (!patternFile(&patterns, value)) return 2;
                    explicit = true;
                } else if (same(name, "--max-count")) opts.max = std.fmt.parseInt(usize, value, 10) catch return bad(arg) else if (same(name, "--after-context")) opts.after = std.fmt.parseInt(usize, value, 10) catch return bad(arg) else if (same(name, "--before-context")) opts.before = std.fmt.parseInt(usize, value, 10) catch return bad(arg) else if (same(name, "--context")) {
                    opts.after = std.fmt.parseInt(usize, value, 10) catch return bad(arg);
                    opts.before = opts.after;
                } else return bad(arg);
            }
            continue;
        }
        if (options and arg.len > 1 and arg[0] == '-') {
            var k: usize = 1;
            while (k < arg.len) : (k += 1) switch (arg[k]) {
                'E' => opts.extended = true,
                'G' => opts.extended = false,
                'F' => opts.fixed = true,
                'i', 'y' => opts.insensitive = true,
                'v' => opts.invert = true,
                'n' => opts.number = true,
                'b' => opts.bytes = true,
                'c' => opts.count = true,
                'q' => opts.quiet = true,
                'o' => opts.only = true,
                'l' => opts.list = true,
                'L' => opts.list_without = true,
                's' => opts.silent = true,
                'w' => opts.word = true,
                'x' => opts.whole = true,
                'r' => opts.recursive = true,
                'R' => {
                    opts.recursive = true;
                    opts.follow = true;
                },
                'a' => opts.text = true,
                'I' => opts.ignore_binary = true,
                'h' => opts.no_filename = true,
                'H' => opts.filename = true,
                'z' => opts.delimiter = 0,
                'Z' => opts.null_filename = true,
                'e', 'f', 'm', 'A', 'B', 'C' => |flag| {
                    const value = if (k + 1 < arg.len) arg[k + 1 ..] else blk: {
                        i += 1;
                        if (i >= args.len) return bad(arg);
                        break :blk args[i];
                    };
                    if (flag == 'e') {
                        addPatterns(&patterns, value);
                        explicit = true;
                    } else if (flag == 'f') {
                        if (!patternFile(&patterns, value)) return 2;
                        explicit = true;
                    } else {
                        const n = std.fmt.parseInt(usize, value, 10) catch return bad(arg);
                        switch (flag) {
                            'm' => opts.max = n,
                            'A' => opts.after = n,
                            'B' => opts.before = n,
                            'C' => {
                                opts.before = n;
                                opts.after = n;
                            },
                            else => unreachable,
                        }
                    }
                    break;
                },
                else => return bad(arg),
            };
            continue;
        }
        files.push(arg);
    }
    if (!explicit) {
        if (files.items.len == 0) return bad("missing pattern");
        addPatterns(&patterns, files.items[0]);
        files.items = files.items[1..];
    }
    for (patterns.items) |*pattern| if (!opts.fixed) {
        pattern.regex = re.Regex.init(pattern.text, opts.extended, opts.insensitive) orelse return 2;
    };
    defer for (patterns.items) |*p| {
        if (p.regex) |*regex| regex.deinit();
    };
    if (files.items.len == 0) files.push(if (opts.recursive) "." else "-");
    opts.colored = color.grepEnabled(opts.color_mode);
    var expanded = u.Vec([]const u8).init(u.alloc);
    var failed = false;
    var ancestors = u.Vec(u.Stat).init(u.alloc);
    for (files.items) |name| expand(name, opts, &expanded, &failed, true, &ancestors);
    const show_name = !opts.no_filename and (opts.filename or files.items.len > 1 or opts.recursive);
    var any = false;
    var group_printed = false;
    for (expanded.items) |name| {
        const data = input.read(name, opts.silent) orelse {
            failed = true;
            continue;
        };
        defer u.alloc.free(data.ptr[0..data.len]);
        const binary = !opts.text and opts.delimiter != 0 and std.mem.indexOfScalar(u8, data, 0) != null;
        if (binary and opts.ignore_binary) {
            if (opts.list_without) printName(name, opts);
            continue;
        }
        const lines = input.records(data, opts.delimiter);
        defer if (lines.cap > 0) u.alloc.free(lines.items.ptr[0..lines.cap]);
        var matches: usize = 0;
        var printed_until: usize = 0;
        var after_until: usize = 0;
        var binary_reported = false;
        var file_printed = false;
        for (lines.items, 0..) |record, index| {
            const match = find(patterns.items, record.text, 0, opts);
            const hit = (match != null) != opts.invert and matches < opts.max;
            if (hit) {
                matches += 1;
                any = true;
                if (opts.quiet) return 0;
                if (opts.list or opts.list_without) break;
            }
            if (opts.count or opts.list or opts.list_without) continue;
            if (binary) {
                if (hit and !binary_reported) {
                    u.errf("grep: {s}: binary file matches\n", .{displayName(name)});
                    binary_reported = true;
                }
                continue;
            }
            if (hit) {
                if (opts.only) {
                    if (opts.invert) continue;
                    var offset: usize = 0;
                    while (find(patterns.items, record.text, offset, opts)) |found| {
                        if (found.end > found.start) {
                            prefix(name, index + 1, record.offset + found.start, ':', show_name, opts);
                            const active = opts.colored and color.grepStart("ms", color.setting("GREP_COLORS", "mt", "01;31"));
                            u.out(record.text[found.start..found.end]);
                            if (active) color.grepEnd();
                            delimiter(opts);
                        }
                        if (found.end == record.text.len) break;
                        offset = if (found.end > found.start) found.end else found.end + 1;
                    }
                } else {
                    const start = @max(printed_until, index -| opts.before);
                    if (group_printed and (!file_printed or start > printed_until) and (opts.before > 0 or opts.after > 0)) {
                        const active = opts.colored and color.grepStart("se", "36");
                        u.out("--");
                        if (active) color.grepEnd();
                        u.out("\n");
                    }
                    for (start..index) |j| emit(name, lines.items[j], j + 1, '-', show_name, opts, patterns.items);
                    emit(name, record, index + 1, ':', show_name, opts, patterns.items);
                    printed_until = index + 1;
                    after_until = index +| opts.after +| 1;
                    group_printed = true;
                    file_printed = true;
                }
            } else if (index < after_until and !opts.only) {
                emit(name, record, index + 1, '-', show_name, opts, patterns.items);
                printed_until = index + 1;
            }
        }
        if (opts.list and matches > 0 or opts.list_without and matches == 0) printName(name, opts);
        if (opts.count and !opts.list and !opts.list_without) {
            if (show_name) filenamePrefix(name, ':', opts);
            u.outf("{d}\n", .{matches});
        }
    }
    return if (failed) 2 else if (any) 0 else 1;
}
fn bad(arg: []const u8) u8 {
    u.errf("grep: invalid argument: {s}\n", .{arg});
    return 2;
}
fn patternFile(patterns: *u.Vec(Pattern), name: []const u8) bool {
    const data = input.read(name, false) orelse return false;
    const lines = input.records(data, '\n');
    for (lines.items) |line| patterns.push(.{ .text = line.text });
    return true;
}
fn expand(name: []const u8, opts: Options, files: *u.Vec([]const u8), failed: *bool, command_line: bool, ancestors: *u.Vec(u.Stat)) void {
    if (!command_line and !opts.follow) {
        const st = u.stat(name, false) orelse return;
        if (st.mode & std.os.linux.S.IFMT == std.os.linux.S.IFLNK) return;
    }
    if (opts.recursive and !same(name, "-") and u.isDir(name)) {
        if (!command_line and !opts.follow) {
            const st = u.stat(name, false) orelse return;
            if (st.mode & std.os.linux.S.IFMT == std.os.linux.S.IFLNK) return;
        }
        const directory = u.stat(name, true) orelse return;
        for (ancestors.items) |ancestor| if (ancestor.dev == directory.dev and ancestor.ino == directory.ino) {
            failed.* = true;
            if (!opts.silent) u.errf("grep: {s}: recursive directory loop\n", .{name});
            return;
        };
        ancestors.push(directory);
        defer ancestors.pop();
        var entries = u.Vec(u.DirEnt).init(u.alloc);
        if (!u.listDir(name, &entries)) {
            failed.* = true;
            return;
        }
        for (entries.items) |entry| {
            const child = std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ name, entry.name }) catch return;
            expand(child, opts, files, failed, false, ancestors);
        }
    } else files.push(name);
}
fn word(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}
fn find(patterns: []const Pattern, line: []const u8, offset: usize, opts: Options) ?Hit {
    var best: ?Hit = null;
    for (patterns) |*pattern| {
        var position = offset;
        while (position <= line.len) {
            const hit: Hit = if (opts.fixed) blk: {
                var found: ?usize = null;
                if (pattern.text.len <= line.len) while (position + pattern.text.len <= line.len) : (position += 1) {
                    const candidate = line[position .. position + pattern.text.len];
                    if (if (opts.insensitive) std.ascii.eqlIgnoreCase(candidate, pattern.text) else same(candidate, pattern.text)) {
                        found = position;
                        break;
                    }
                };
                const start = found orelse break;
                break :blk .{ .start = start, .end = start + pattern.text.len };
            } else blk: {
                const found = pattern.regex.?.find(line, position) orelse break;
                break :blk .{ .start = found.start, .end = found.end };
            };
            const boundary = (!opts.whole or hit.start == 0 and hit.end == line.len) and (!opts.word or (hit.start == 0 or !word(line[hit.start - 1])) and (hit.end == line.len or !word(line[hit.end])));
            if (boundary) {
                if (best == null or hit.start < best.?.start or hit.start == best.?.start and hit.end > best.?.end) best = hit;
                break;
            }
            position = hit.start + 1;
        }
    }
    return best;
}
fn displayName(name: []const u8) []const u8 {
    return if (same(name, "-")) "(standard input)" else name;
}
fn delimiter(opts: Options) void {
    const d = [_]u8{opts.delimiter};
    u.out(&d);
}
fn coloredText(text: []const u8, key: []const u8, fallback: []const u8, opts: Options) void {
    const active = opts.colored and color.grepStart(key, fallback);
    u.out(text);
    if (active) color.grepEnd();
}
fn printName(name: []const u8, opts: Options) void {
    coloredText(displayName(name), "fn", "35", opts);
    if (opts.null_filename) u.out(&.{0}) else u.out("\n");
}
fn filenamePrefix(name: []const u8, separator: u8, opts: Options) void {
    coloredText(displayName(name), "fn", "35", opts);
    if (opts.null_filename) u.out(&.{0}) else coloredText(&.{separator}, "se", "36", opts);
}
fn prefix(name: []const u8, number: usize, offset: usize, sep: u8, show_name: bool, opts: Options) void {
    if (show_name) filenamePrefix(name, sep, opts);
    var buffer: [32]u8 = undefined;
    if (opts.number) {
        const text = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch return;
        coloredText(text, "ln", "32", opts);
        coloredText(&.{sep}, "se", "36", opts);
    }
    if (opts.bytes) {
        const text = std.fmt.bufPrint(&buffer, "{d}", .{offset}) catch return;
        coloredText(text, "bn", "32", opts);
        coloredText(&.{sep}, "se", "36", opts);
    }
}
fn emit(name: []const u8, record: input.Record, number: usize, sep: u8, show_name: bool, opts: Options, patterns: []const Pattern) void {
    prefix(name, number, record.offset, sep, show_name, opts);
    if (!opts.colored) {
        u.out(record.text);
        delimiter(opts);
        return;
    }
    var selected = sep == ':';
    if (opts.invert and color.has("GREP_COLORS", "rv")) selected = !selected;
    const base = if (selected) "sl" else "cx";
    const base_active = color.grepStart(base, "");
    var position: usize = 0;
    var search: usize = 0;
    var base_current = base_active;
    while (find(patterns, record.text, search, opts)) |hit| {
        if (hit.end > hit.start) {
            u.out(record.text[position..hit.start]);
            const active = color.grepStart(if (sep == ':') "ms" else "mc", color.setting("GREP_COLORS", "mt", "01;31"));
            u.out(record.text[hit.start..hit.end]);
            position = hit.end;
            if (active) {
                color.grepEnd();
                base_current = false;
                if (base_active and hit.end < record.text.len) base_current = color.grepStart(base, "");
            }
        }
        if (hit.end == record.text.len) break;
        search = if (hit.end > hit.start) hit.end else hit.end + 1;
    }
    u.out(record.text[position..]);
    if (base_current) color.grepEnd();
    delimiter(opts);
}
