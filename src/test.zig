// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const u = @import("util.zig");
const linux = std.os.linux;
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
var bad_int: []const u8 = "";
pub fn run(args: []const []const u8) u8 {
    const result = evaluate(args) catch |err| {
        if (err == error.Integer) u.errf("test: invalid integer '{s}'\n", .{bad_int}) else u.errf("test: invalid expression\n", .{});
        return 2;
    };
    return if (result) 0 else 1;
}
pub fn bracket(args: []const []const u8) u8 {
    if (args.len == 0 or !same(args[args.len - 1], "]")) {
        u.errf("[: missing ]\n", .{});
        return 2;
    }
    return run(args[0 .. args.len - 1]);
}
pub fn doubleBracket(args: []const []const u8) u8 {
    if (args.len == 0 or !same(args[args.len - 1], "]]")) return 2;
    return run(args[0 .. args.len - 1]);
}
fn evaluate(args: []const []const u8) anyerror!bool {
    // POSIX's argument-count rules resolve ambiguous operands such as "!".
    if (args.len == 0) return false;
    if (args.len == 1) return args[0].len > 0;
    if (args.len == 2 and same(args[0], "!")) return args[1].len == 0;
    if (args.len == 3) {
        if (isBinary(args[1])) return binary(args[0], args[1], args[2]);
        if (same(args[0], "!")) return !try evaluate(args[1..]);
        if (same(args[0], "(") and same(args[2], ")")) return args[1].len > 0;
    }
    if (args.len == 4 and same(args[0], "!")) return !try evaluate(args[1..]);
    var parser = Parser{ .args = args };
    const result = try parser.disjunction();
    if (parser.pos != args.len) return error.Syntax;
    return result;
}
const Parser = struct {
    args: []const []const u8,
    pos: usize = 0,
    fn take(self: *Parser) ![]const u8 {
        if (self.pos == self.args.len) return error.Syntax;
        const arg = self.args[self.pos];
        self.pos += 1;
        return arg;
    }
    fn is(self: *Parser, token: []const u8) bool {
        return self.pos < self.args.len and same(self.args[self.pos], token);
    }
    fn disjunction(self: *Parser) anyerror!bool {
        var result = try self.conjunction();
        while (self.is("-o")) {
            self.pos += 1;
            const rhs = try self.conjunction();
            result = result or rhs;
        }
        return result;
    }
    fn conjunction(self: *Parser) anyerror!bool {
        var result = try self.primary();
        while (self.is("-a")) {
            self.pos += 1;
            const rhs = try self.primary();
            result = result and rhs;
        }
        return result;
    }
    fn primary(self: *Parser) anyerror!bool {
        const first = try self.take();
        if (same(first, "!")) return !try self.primary();
        if (same(first, "(")) {
            const result = try self.disjunction();
            if (!same(try self.take(), ")")) return error.Syntax;
            return result;
        }
        if (self.pos < self.args.len and isBinary(self.args[self.pos])) {
            const op = try self.take();
            return binary(first, op, try self.take());
        }
        if (first.len == 2 and first[0] == '-') return unary(first, try self.take());
        return first.len > 0;
    }
};
fn unary(op: []const u8, value: []const u8) !bool {
    if (same(op, "-n")) return value.len > 0;
    if (same(op, "-z")) return value.len == 0;
    if (same(op, "-t")) {
        const fd = std.fmt.parseInt(i32, value, 10) catch return error.Integer;
        var buf: [64]u8 = undefined;
        return u.ok(linux.ioctl(fd, 0x5401, @intFromPtr(&buf)));
    }
    if (same(op, "-r")) return u.ok(linux.access(u.zstr(value), 4));
    if (same(op, "-w")) return u.ok(linux.access(u.zstr(value), 2));
    if (same(op, "-x")) return u.ok(linux.access(u.zstr(value), 1));
    if (std.mem.indexOf(u8, "abcdefghGkLOpSsu", op[1..]) == null) return error.Syntax;
    const st = u.stat(value, !same(op, "-L") and !same(op, "-h")) orelse return false;
    const typ = st.mode & linux.S.IFMT;
    return switch (op[1]) {
        'a', 'e' => true,
        'b' => typ == linux.S.IFBLK,
        'c', 'C' => typ == linux.S.IFCHR,
        'd' => typ == linux.S.IFDIR,
        'f' => typ == linux.S.IFREG,
        'p' => typ == linux.S.IFIFO,
        'S' => typ == linux.S.IFSOCK,
        'L', 'h' => typ == linux.S.IFLNK,
        'g' => st.mode & 0o2000 != 0,
        'u' => st.mode & 0o4000 != 0,
        'k' => st.mode & 0o1000 != 0,
        'O' => st.uid == linux.geteuid(),
        'G' => st.gid == linux.getegid(),
        's' => st.size > 0,
        else => error.Syntax,
    };
}
fn isBinary(op: []const u8) bool {
    for ([_][]const u8{ "=", "==", "!=", "<", ">", "-eq", "-ne", "-gt", "-ge", "-lt", "-le", "-ef", "-nt", "-ot" }) |candidate| if (same(op, candidate)) return true;
    return false;
}
const Integer = struct { negative: bool, digits: []const u8 };
fn integer(value: []const u8) !Integer {
    var digits = std.mem.trim(u8, value, " \t\n\r\x0b\x0c");
    var negative = false;
    if (digits.len > 0 and (digits[0] == '+' or digits[0] == '-')) {
        negative = digits[0] == '-';
        digits = digits[1..];
    }
    bad_int = value;
    if (digits.len == 0) return error.Integer;
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return error.Integer;
    while (digits.len > 1 and digits[0] == '0') digits = digits[1..];
    if (same(digits, "0")) negative = false;
    return .{ .negative = negative, .digits = digits };
}
fn binary(left: []const u8, op: []const u8, right: []const u8) !bool {
    if (same(op, "=") or same(op, "==")) return same(left, right);
    if (same(op, "!=")) return !same(left, right);
    if (same(op, "<")) return std.mem.lessThan(u8, left, right);
    if (same(op, ">")) return std.mem.lessThan(u8, right, left);
    if (same(op, "-ef") or same(op, "-nt") or same(op, "-ot")) {
        const a = u.stat(left, true);
        const b = u.stat(right, true);
        if (same(op, "-ef")) return a != null and b != null and a.?.ino == b.?.ino and a.?.dev == b.?.dev;
        if (same(op, "-nt")) return a != null and (b == null or a.?.mtime > b.?.mtime or a.?.mtime == b.?.mtime and a.?.mtime_nsec > b.?.mtime_nsec);
        return b != null and (a == null or a.?.mtime < b.?.mtime or a.?.mtime == b.?.mtime and a.?.mtime_nsec < b.?.mtime_nsec);
    }
    const a = try integer(left);
    const b = try integer(right);
    const order: std.math.Order = if (a.negative != b.negative) (if (a.negative) .lt else .gt) else blk: {
        var result = std.math.order(a.digits.len, b.digits.len);
        if (result == .eq) result = std.mem.order(u8, a.digits, b.digits);
        if (a.negative) result = result.invert();
        break :blk result;
    };
    if (same(op, "-eq")) return order == .eq;
    if (same(op, "-ne")) return order != .eq;
    if (same(op, "-gt")) return order == .gt;
    if (same(op, "-ge")) return order != .lt;
    if (same(op, "-lt")) return order == .lt;
    if (same(op, "-le")) return order != .gt;
    return error.Syntax;
}
