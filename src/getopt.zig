// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// getopt.zig - GNU getopt_long style parser (permutation, unique-prefix
// long options, clustered short options, attached/detached arguments).
const std = @import("std");
const u = @import("util.zig");

pub const Arg = enum { no, req, opt };
/// `name` empty => short-only. `key` is the short char, or a code >= 128 for long-only options.
pub const Opt = struct { name: []const u8 = "", key: u8, arg: Arg = .no };
pub const Item = struct { key: u8, val: ?[]const u8 };

pub const Parser = struct {
    prog: []const u8,
    args: []const []const u8,
    opts: []const Opt,
    i: usize = 0,
    k: usize = 0, // position inside a short cluster (0 = not in one)
    done: bool = false,
    operands: u.Vec([]const u8),
    /// stop at the first operand (env, nice style)
    stop_at_operand: bool = false,
    /// print "prog: Try ..." (xz style) instead of "Try ..."
    hint_prefix: bool = false,
    /// no "Try --help" line after an option error
    no_hint: bool = false,

    pub fn init(prog: []const u8, args: []const []const u8, opts: []const Opt) Parser {
        return .{ .prog = prog, .args = args, .opts = opts, .operands = u.Vec([]const u8).init(u.alloc) };
    }

    fn usage(self: *Parser) error{Usage} {
        if (self.no_hint) return error.Usage;
        if (self.hint_prefix) u.errf("{s}: Try '{s} --help' for more information.\n", .{ self.prog, self.prog }) else u.errf("Try '{s} --help' for more information.\n", .{self.prog});
        return error.Usage;
    }

    fn findShort(self: *Parser, ch: u8) ?Opt {
        for (self.opts) |o| if (o.key == ch and (o.name.len == 0 or ch < 128)) return o;
        return null;
    }

    /// Remaining arguments after parsing stopped (only meaningful with stop_at_operand).
    pub fn rest(self: *Parser) []const []const u8 {
        return self.args[@min(self.i, self.args.len)..];
    }

    pub fn next(self: *Parser) error{Usage}!?Item {
        if (self.k > 0) {
            const a = self.args[self.i];
            const ch = a[self.k];
            const o = self.findShort(ch) orelse {
                u.errf("{s}: invalid option -- '{c}'\n", .{ self.prog, ch });
                return self.usage();
            };
            self.k += 1;
            const at_end = self.k >= a.len;
            if (o.arg == .no) {
                if (at_end) {
                    self.k = 0;
                    self.i += 1;
                }
                return .{ .key = o.key, .val = null };
            }
            if (!at_end) {
                const v = a[self.k..];
                self.k = 0;
                self.i += 1;
                return .{ .key = o.key, .val = v };
            }
            self.k = 0;
            self.i += 1;
            if (o.arg == .opt) return .{ .key = o.key, .val = null };
            if (self.i >= self.args.len) {
                u.errf("{s}: option requires an argument -- '{c}'\n", .{ self.prog, ch });
                return self.usage();
            }
            const v = self.args[self.i];
            self.i += 1;
            return .{ .key = o.key, .val = v };
        }
        while (self.i < self.args.len) {
            const a = self.args[self.i];
            if (self.done or a.len < 2 or a[0] != '-') {
                if (self.stop_at_operand) return null;
                self.operands.push(a);
                self.i += 1;
                continue;
            }
            if (std.mem.eql(u8, a, "--")) {
                self.i += 1;
                self.done = true;
                if (self.stop_at_operand) return null;
                continue;
            }
            if (a[1] != '-') {
                self.k = 1;
                return self.next();
            }
            // long option
            var name = a[2..];
            var inl: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, name, '=')) |e| {
                inl = name[e + 1 ..];
                name = name[0..e];
            }
            var found: ?Opt = null;
            var count: usize = 0;
            for (self.opts) |o| {
                if (o.name.len == 0) continue;
                if (std.mem.eql(u8, o.name, name)) {
                    found = o;
                    count = 1;
                    break;
                }
                if (std.mem.startsWith(u8, o.name, name)) {
                    if (found == null or found.?.key != o.key) count += 1;
                    found = o;
                }
            }
            if (found == null) {
                u.errf("{s}: unrecognized option '--{s}'\n", .{ self.prog, name });
                return self.usage();
            }
            if (count > 1) {
                u.errf("{s}: option '--{s}' is ambiguous\n", .{ self.prog, name });
                return self.usage();
            }
            const o = found.?;
            self.i += 1;
            switch (o.arg) {
                .no => if (inl != null) {
                    u.errf("{s}: option '--{s}' doesn't allow an argument\n", .{ self.prog, o.name });
                    return self.usage();
                },
                .req => {
                    if (inl) |v| return .{ .key = o.key, .val = v };
                    if (self.i >= self.args.len) {
                        u.errf("{s}: option '--{s}' requires an argument\n", .{ self.prog, o.name });
                        return self.usage();
                    }
                    const v = self.args[self.i];
                    self.i += 1;
                    return .{ .key = o.key, .val = v };
                },
                .opt => {},
            }
            return .{ .key = o.key, .val = inl };
        }
        return null;
    }
};

pub fn missingOperand(prog: []const u8) u8 {
    u.errf("{s}: missing operand\nTry '{s} --help' for more information.\n", .{ prog, prog });
    return 1;
}

/// Light-weight GNU-style validation in front of hand-written option parsers:
/// expands unique-prefix long options, rejects unknown ones with GNU diagnostics,
/// answers --help / --version.  Short option clusters are checked too.
pub const Spec = struct {
    prog: []const u8,
    short: []const u8, // all valid short option letters
    short_arg: []const u8 = "", // short letters that take an argument
    long: []const []const u8, // long option names (without --)
    long_arg: []const []const u8 = &.{}, // long options that take a required argument
    long_opt_arg: []const []const u8 = &.{}, // long options with an optional argument
    help: []const u8 = "",
};

pub const Normalized = union(enum) { args: []const []const u8, exit: u8 };

fn inList(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

pub fn normalize(spec: Spec, args: []const []const u8) Normalized {
    var out = u.Vec([]const u8).init(u.alloc);
    var i: usize = 0;
    var done = false;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (done or a.len < 2 or a[0] != '-') {
            out.push(a);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            done = true;
            out.push(a);
            continue;
        }
        if (a[1] == '-') {
            var name = a[2..];
            var val: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, name, '=')) |e| {
                val = name[e + 1 ..];
                name = name[0..e];
            }
            if (std.mem.eql(u8, name, "help") or (name.len >= 1 and std.mem.startsWith(u8, "help", name) and !prefixOfLong(spec, name))) {
                u.out(spec.help);
                return .{ .exit = 0 };
            }
            if (std.mem.eql(u8, name, "version") or (name.len >= 1 and std.mem.startsWith(u8, "version", name) and !prefixOfLong(spec, name))) {
                u.outf("{s} (cmdbox)\n", .{spec.prog});
                return .{ .exit = 0 };
            }
            var found: ?[]const u8 = null;
            var count: usize = 0;
            for (spec.long) |l| {
                if (std.mem.eql(u8, l, name)) {
                    found = l;
                    count = 1;
                    break;
                }
                if (std.mem.startsWith(u8, l, name)) {
                    found = l;
                    count += 1;
                }
            }
            if (found == null) {
                u.errf("{s}: unrecognized option '--{s}'\nTry '{s} --help' for more information.\n", .{ spec.prog, name, spec.prog });
                return .{ .exit = 1 };
            }
            if (count > 1) {
                u.errf("{s}: option '--{s}' is ambiguous\nTry '{s} --help' for more information.\n", .{ spec.prog, name, spec.prog });
                return .{ .exit = 1 };
            }
            const full = found.?;
            const takes = inList(spec.long_arg, full);
            const opt = inList(spec.long_opt_arg, full);
            if (takes) {
                if (val == null) {
                    if (i + 1 >= args.len) {
                        u.errf("{s}: option '--{s}' requires an argument\nTry '{s} --help' for more information.\n", .{ spec.prog, full, spec.prog });
                        return .{ .exit = 1 };
                    }
                    i += 1;
                    val = args[i];
                }
            } else if (!opt and val != null) {
                u.errf("{s}: option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.\n", .{ spec.prog, full, spec.prog });
                return .{ .exit = 1 };
            }
            if (val) |v| out.push(std.fmt.allocPrint(u.alloc, "--{s}={s}", .{ full, v }) catch a) else out.push(std.fmt.allocPrint(u.alloc, "--{s}", .{full}) catch a);
            continue;
        }
        // short cluster
        var consumed_next = false;
        var k: usize = 1;
        while (k < a.len) : (k += 1) {
            const ch = a[k];
            if (std.mem.indexOfScalar(u8, spec.short, ch) == null) {
                u.errf("{s}: invalid option -- '{c}'\nTry '{s} --help' for more information.\n", .{ spec.prog, ch, spec.prog });
                return .{ .exit = 1 };
            }
            if (std.mem.indexOfScalar(u8, spec.short_arg, ch) != null) {
                if (k + 1 >= a.len) {
                    if (i + 1 >= args.len) {
                        u.errf("{s}: option requires an argument -- '{c}'\nTry '{s} --help' for more information.\n", .{ spec.prog, ch, spec.prog });
                        return .{ .exit = 1 };
                    }
                    out.push(a);
                    i += 1;
                    out.push(args[i]);
                    consumed_next = true;
                }
                break;
            }
        }
        if (!consumed_next) out.push(a);
    }
    return .{ .args = out.items };
}

fn prefixOfLong(spec: Spec, name: []const u8) bool {
    for (spec.long) |l| if (std.mem.startsWith(u8, l, name)) return true;
    return false;
}
