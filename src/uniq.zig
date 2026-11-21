// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// uniq - GNU coreutils: -c -d -D --all-repeated[=M] --group[=M] -f -i -s -u -w -z, streaming
const std = @import("std");
const u = @import("util.zig");
const g = @import("getopt.zig");
const linux = std.os.linux;

const Delim = enum { none, prepend, separate, append, both };

const Options = struct {
    count: bool = false,
    duplicates: bool = false,
    all_dups: bool = false,
    unique: bool = false,
    group: bool = false,
    delim: Delim = .separate,
    insensitive: bool = false,
    fields: usize = 0,
    skip: usize = 0,
    width: usize = std.math.maxInt(usize),
    terminator: u8 = '\n',
};

fn key(text: []const u8, opts: Options) []const u8 {
    var pos: usize = 0;
    var field: usize = 0;
    while (field < opts.fields and pos < text.len) : (field += 1) {
        while (pos < text.len and (text[pos] == ' ' or text[pos] == '\t')) pos += 1;
        while (pos < text.len and text[pos] != ' ' and text[pos] != '\t') pos += 1;
    }
    pos = @min(text.len, pos +| opts.skip);
    return text[pos..@min(text.len, pos +| opts.width)];
}

fn parseCount(prog_opt: []const u8, v: []const u8) ?usize {
    return std.fmt.parseInt(usize, v, 10) catch {
        u.errf("uniq: {s}: invalid number of {s}: '{s}'\n", .{ prog_opt, prog_opt, v });
        return null;
    };
}

const State = struct {
    opts: Options,
    file: u.File,
    prev: std.ArrayList(u8) = .empty,
    have: bool = false,
    count: usize = 0,
    printed_groups: usize = 0, // groups that produced output
    group_started: bool = false,
    failed: bool = false,

    fn write(self: *State, data: []const u8) void {
        if (!self.file.write(data)) {
            if (!self.failed) u.err("uniq: write error\n");
            self.failed = true;
        }
    }

    fn line(self: *State, text: []const u8) void {
        self.write(text);
        self.write(&.{self.opts.terminator});
    }

    fn delimiter(self: *State) void {
        self.write(&.{self.opts.terminator});
    }

    fn sameGroup(self: *State, text: []const u8) bool {
        const a = key(self.prev.items, self.opts);
        const b = key(text, self.opts);
        return if (self.opts.insensitive) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
    }

    fn startGroup(self: *State, text: []const u8) void {
        self.prev.clearRetainingCapacity();
        self.prev.appendSlice(u.alloc, text) catch {};
        self.have = true;
        self.count = 1;
        self.group_started = false;
        if (self.opts.group) {
            // delimiters: separate = between groups, prepend/both = before each group
            if (self.opts.delim == .prepend or (self.opts.delim == .both and self.printed_groups == 0) or (self.opts.delim == .separate and self.printed_groups > 0)) self.delimiter();
            self.printed_groups += 1;
            self.line(text);
            self.group_started = true;
        }
    }

    fn endGroup(self: *State) void {
        if (!self.have) return;
        const o = self.opts;
        if (o.group) {
            if (o.delim == .append or o.delim == .both) self.delimiter();
            return;
        }
        if (o.all_dups) return; // lines were written as they arrived
        if ((o.duplicates and self.count == 1) or (o.unique and self.count != 1)) return;
        if (o.count) {
            var buf: [32]u8 = undefined;
            const prefix = std.fmt.bufPrint(&buf, "{d: >7} ", .{@as(u64, self.count)}) catch return;
            self.write(prefix);
        }
        self.line(self.prev.items);
    }

    fn feed(self: *State, text: []const u8) void {
        if (!self.have) {
            self.startGroup(text);
            return;
        }
        if (self.sameGroup(text)) {
            self.count += 1;
            if (self.opts.group) {
                self.line(text);
            } else if (self.opts.all_dups) {
                if (self.count == 2) {
                    // first duplicate seen: open the group
                    if (self.opts.delim == .prepend or (self.opts.delim == .separate and self.printed_groups > 0)) self.delimiter();
                    self.printed_groups += 1;
                    self.line(self.prev.items);
                    self.group_started = true;
                }
                self.line(text);
            }
            return;
        }
        self.endGroup();
        self.startGroup(text);
    }
};

pub fn run(args: []const []const u8) u8 {
    const opts_t = [_]g.Opt{
        .{ .name = "count", .key = 'c' },
        .{ .name = "repeated", .key = 'd' },
        .{ .key = 'D' },
        .{ .name = "all-repeated", .key = 130, .arg = .opt },
        .{ .name = "group", .key = 131, .arg = .opt },
        .{ .name = "skip-fields", .key = 'f', .arg = .req },
        .{ .name = "ignore-case", .key = 'i' },
        .{ .name = "skip-chars", .key = 's', .arg = .req },
        .{ .name = "unique", .key = 'u' },
        .{ .name = "check-chars", .key = 'w', .arg = .req },
        .{ .name = "zero-terminated", .key = 'z' },
        .{ .name = "help", .key = 200 },
        .{ .name = "version", .key = 201 },
    };
    var opts = Options{};
    var p = g.Parser.init("uniq", args, &opts_t);
    var all_set = false;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'c' => opts.count = true,
            'd' => opts.duplicates = true,
            'D', 130 => {
                opts.all_dups = true;
                all_set = true;
                if (it.val) |v| {
                    if (std.mem.eql(u8, v, "none")) opts.delim = .none else if (std.mem.eql(u8, v, "prepend")) opts.delim = .prepend else if (std.mem.eql(u8, v, "separate")) opts.delim = .separate else {
                        u.errf("uniq: invalid argument '{s}' for '--all-repeated'\nValid arguments are:\n  - 'none'\n  - 'prepend'\n  - 'separate'\nTry 'uniq --help' for more information.\n", .{v});
                        return 1;
                    }
                } else opts.delim = .none;
            },
            131 => {
                opts.group = true;
                opts.delim = .separate;
                if (it.val) |v| {
                    if (std.mem.eql(u8, v, "separate")) opts.delim = .separate else if (std.mem.eql(u8, v, "prepend")) opts.delim = .prepend else if (std.mem.eql(u8, v, "append")) opts.delim = .append else if (std.mem.eql(u8, v, "both")) opts.delim = .both else {
                        u.errf("uniq: invalid argument '{s}' for '--group'\nValid arguments are:\n  - 'prepend'\n  - 'append'\n  - 'separate'\n  - 'both'\nTry 'uniq --help' for more information.\n", .{v});
                        return 1;
                    }
                }
            },
            'f' => opts.fields = parseCount("fields to skip", it.val.?) orelse return 1,
            'i' => opts.insensitive = true,
            's' => opts.skip = parseCount("bytes to skip", it.val.?) orelse return 1,
            'u' => opts.unique = true,
            'w' => opts.width = parseCount("bytes to compare", it.val.?) orelse return 1,
            'z' => opts.terminator = 0,
            200 => {
                u.out("Usage: uniq [OPTION]... [INPUT [OUTPUT]]\nFilter adjacent matching lines from INPUT (or standard input),\nwriting to OUTPUT (or standard output).\n");
                return 0;
            },
            201 => {
                u.out("uniq (cmdbox)\n");
                return 0;
            },
            else => {},
        }
    }
    if (opts.group and (opts.count or opts.duplicates or opts.all_dups or opts.unique)) {
        u.err("uniq: --group is mutually exclusive with -c/-d/-D/-u\nTry 'uniq --help' for more information.\n");
        return 1;
    }
    if (opts.count and opts.all_dups) {
        u.err("uniq: printing all duplicated lines and repeat counts is meaningless\nTry 'uniq --help' for more information.\n");
        return 1;
    }
    const files = p.operands.items;
    if (files.len > 2) {
        u.errf("uniq: extra operand '{s}'\nTry 'uniq --help' for more information.\n", .{files[2]});
        return 1;
    }
    const name = if (files.len > 0) files[0] else "-";
    const source = if (std.mem.eql(u8, name, "-")) u.File{ .fd = 0 } else u.File.open(name, .{ .ACCMODE = .RDONLY }, 0) orelse {
        u.errf("uniq: {s}: {s}\n", .{ name, u.strerr(u.errno(linux.open(u.zstr(name), .{ .ACCMODE = .RDONLY }, 0))) });
        return 1;
    };
    defer if (source.fd != 0) source.close();
    const file = if (files.len == 2 and !std.mem.eql(u8, files[1], "-")) u.File.open(files[1], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666) orelse {
        u.errf("uniq: {s}: {s}\n", .{ files[1], u.strerr(u.errno(linux.open(u.zstr(files[1]), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666))) });
        return 1;
    } else u.File{ .fd = 1 };
    defer if (file.fd != 1) file.close();

    var st = State{ .opts = opts, .file = file };
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(u.alloc);
    var buffer: [16384]u8 = undefined;
    while (true) {
        const rc = linux.read(source.fd, &buffer, buffer.len);
        if (u.errno(rc) == .INTR) continue;
        if (!u.ok(rc)) {
            u.errf("uniq: {s}: {s}\n", .{ name, u.strerr(u.errno(rc)) });
            return 1;
        }
        if (rc == 0) break;
        for (buffer[0..rc]) |byte| {
            if (byte == opts.terminator) {
                st.feed(current.items);
                current.clearRetainingCapacity();
            } else current.append(u.alloc, byte) catch return 1;
        }
        if (st.failed) return 1;
    }
    if (current.items.len > 0) st.feed(current.items);
    st.endGroup();
    return if (st.failed) 1 else 0;
}
