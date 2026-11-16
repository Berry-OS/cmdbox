// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// POSIX BRE/ERE engine supplied by statically linked musl.
const std = @import("std");
const u = @import("util.zig");
const c = @cImport({
    @cInclude("regex.h");
});
pub const Match = struct { start: usize, end: usize, groups: [10]?struct { start: usize, end: usize } };
pub const Regex = struct {
    compiled: c.regex_t,
    pub fn init(pattern: []const u8, extended: bool, insensitive: bool) ?Regex {
        var result: Regex = undefined;
        const flags: c_int = (if (extended) @as(c_int, c.REG_EXTENDED) else 0) | (if (insensitive) @as(c_int, c.REG_ICASE) else 0);
        const rc = c.regcomp(&result.compiled, u.zstr(pattern), flags);
        if (rc != 0) {
            var message: [256]u8 = undefined;
            _ = c.regerror(rc, &result.compiled, &message, message.len);
            u.errf("regular expression: {s}\n", .{std.mem.sliceTo(&message, 0)});
            return null;
        }
        return result;
    }
    pub fn deinit(self: *Regex) void {
        c.regfree(&self.compiled);
    }
    pub fn find(self: *const Regex, input: []const u8, offset: usize) ?Match {
        if (offset > input.len) return null;
        const text = u.zstr(input[offset..]);
        defer u.alloc.free(text);
        var matches: [10]c.regmatch_t = undefined;
        if (c.regexec(&self.compiled, text, matches.len, &matches, if (offset == 0) 0 else c.REG_NOTBOL) != 0) return null;
        var result = Match{ .start = offset + @as(usize, @intCast(matches[0].rm_so)), .end = offset + @as(usize, @intCast(matches[0].rm_eo)), .groups = @splat(null) };
        for (matches, 0..) |m, i| if (m.rm_so >= 0) {
            result.groups[i] = .{ .start = offset + @as(usize, @intCast(m.rm_so)), .end = offset + @as(usize, @intCast(m.rm_eo)) };
        };
        return result;
    }
};
