// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
pub fn apply(expression: []const u8, initial: u32, directory: bool, umask: u32) ?u32 {
    if (expression.len == 0) return null;
    if (expression[0] >= '0' and expression[0] <= '7') {
        const number = std.fmt.parseInt(u32, expression, 8) catch return null;
        if (number > 0o7777) return null;
        return number | (if (directory and expression.len <= 4) initial & 0o6000 else @as(u32, 0));
    }
    var result = initial & 0o7777;
    var clauses = std.mem.splitScalar(u8, expression, ',');
    while (clauses.next()) |clause| {
        var i: usize = 0;
        var who: u32 = 0;
        while (i < clause.len) : (i += 1) switch (clause[i]) {
            'u' => who |= 0o4700,
            'g' => who |= 0o2070,
            'o' => who |= 0o1007,
            'a' => who |= 0o7777,
            else => break,
        };
        const implicit = who == 0;
        if (implicit) who = 0o7777 & ~(umask & 0o777);
        if (i == clause.len) return null;
        while (i < clause.len) {
            const op = clause[i];
            i += 1;
            if (op != '+' and op != '-' and op != '=') return null;
            var bits: u32 = 0;
            while (i < clause.len and clause[i] != '+' and clause[i] != '-' and clause[i] != '=') : (i += 1) {
                switch (clause[i]) {
                    'r' => bits |= 0o444,
                    'w' => bits |= 0o222,
                    'x' => bits |= 0o111,
                    'X' => {
                        if (directory or result & 0o111 != 0) bits |= 0o111;
                    },
                    's' => bits |= 0o6000,
                    't' => bits |= 0o1000,
                    'u', 'g', 'o' => |source| {
                        const shift: u5 = if (source == 'u') 6 else if (source == 'g') 3 else 0;
                        const value = (result >> shift) & 7;
                        bits |= value | value << 3 | value << 6;
                    },
                    else => return null,
                }
            }
            bits &= who;
            const retain = if (directory and op == '=') initial & 0o6000 & ~bits else @as(u32, 0);
            result = switch (op) {
                '+' => result | bits,
                '-' => result & ~bits,
                '=' => (result & ~who) | bits | retain,
                else => unreachable,
            };
        }
    }
    return result;
}
