// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// sh.zig - POSIX shell: variables, expansion, arithmetic, redirection, execution, builtins
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const P = @import("sh_parse.zig");
const c = @cImport({
    @cInclude("fnmatch.h");
    @cInclude("pwd.h");
    @cInclude("unistd.h");
    @cInclude("sys/resource.h");
});

const A = u.alloc;
const Node = P.Node;

const ShErr = error{ Abort, OutOfMemory };

// ===================== state =====================
const Var = struct { val: []const u8, exported: bool = false, readonly: bool = false };
var vars: std.StringHashMapUnmanaged(Var) = .{};
var funcs: std.StringHashMapUnmanaged(*Node) = .{};
var aliases: std.StringHashMapUnmanaged([]const u8) = .{};

var pos_args: u.Vec([]const u8) = undefined;
var arg0: []const u8 = "sh";
var last_status: u8 = 0;
var shell_pid: i32 = 0;
var last_bg: i32 = 0;
var cur_line: u32 = 0;
var interactive = false;
var in_subshell = false;
var func_depth: u32 = 0;
var loop_depth: u32 = 0;
var noerr: u32 = 0;
var rand_state: u32 = 12345;
var optind_pos: usize = 0;

// options
var opt_e = false;
var opt_u = false;
var opt_f = false;
var opt_x = false;
var opt_v = false;
var opt_n = false;
var opt_C = false;
var opt_a = false;
var opt_pipefail = false;

const Flow = enum { none, break_, continue_, return_, exit_ };
var flow: Flow = .none;
var flow_n: u32 = 0;

// traps
var trap_cmd: [65]?[]const u8 = @splat(null);
var trap_ign: [65]bool = @splat(false);
var trap_exit: ?[]const u8 = null;
var trap_err: ?[]const u8 = null;
var pending_sigs: u64 = 0;
var running_trap = false;

// background jobs
const Job = struct { pid: i32, status: ?u8 };
var jobs = u.Vec(Job).init(A);

fn sigHandler(sig: linux.SIG) callconv(.c) void {
    const n: u32 = @intFromEnum(sig);
    if (n > 0 and n < 64) pending_sigs |= (@as(u64, 1) << @intCast(n));
}

// ===================== variables =====================
fn validName(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}

fn copyVar(v: ?Var) ?Var {
    var c0 = v orelse return null;
    if (c0.val.len > 0) c0.val = A.dupe(u8, c0.val) catch c0.val;
    return c0;
}

fn getVar(name: []const u8) ?[]const u8 {
    if (vars.get(name)) |v| return v.val;
    return null;
}

fn setVar(name: []const u8, value: []const u8) bool {
    const val = A.dupe(u8, value) catch return false;
    if (vars.getPtr(name)) |p| {
        if (p.readonly) {
            u.errf("sh: {s}: is read only\n", .{name});
            return false;
        }
        const old = p.val;
        p.val = val;
        if (old.len > 0) A.free(old);
        if (p.exported or std.mem.eql(u8, name, "PATH")) syncEnv(name, val, p.exported);
        return true;
    }
    const key = A.dupe(u8, name) catch return false;
    vars.put(A, key, .{ .val = val, .exported = opt_a }) catch return false;
    if (std.mem.eql(u8, name, "PATH") or opt_a) syncEnv(name, val, opt_a);
    return true;
}

fn syncEnv(name: []const u8, val: []const u8, exported: bool) void {
    if (exported) u.setEnv(name, val) else u.setVar(name, val);
}

fn unsetVar(name: []const u8) bool {
    if (vars.getPtr(name)) |p| {
        if (p.readonly) {
            u.errf("sh: {s}: is read only\n", .{name});
            return false;
        }
        _ = vars.remove(name);
        u.unsetVar(name);
    }
    return true;
}

fn markExport(name: []const u8, value: ?[]const u8) bool {
    if (value) |v| if (!setVar(name, v)) return false;
    if (vars.getPtr(name)) |p| {
        p.exported = true;
        u.setEnv(name, p.val);
    } else {
        const key = A.dupe(u8, name) catch return false;
        vars.put(A, key, .{ .val = "", .exported = true }) catch return false;
    }
    return true;
}

fn fmtU(a: std.mem.Allocator, v: anytype) []const u8 {
    return std.fmt.allocPrint(a, "{d}", .{v}) catch "";
}

fn optString(a: std.mem.Allocator) []const u8 {
    var o = u.Vec(u8).init(a);
    if (opt_a) o.push('a');
    if (opt_e) o.push('e');
    if (opt_f) o.push('f');
    if (interactive) o.push('i');
    if (opt_n) o.push('n');
    if (opt_u) o.push('u');
    if (opt_v) o.push('v');
    if (opt_x) o.push('x');
    if (opt_C) o.push('C');
    return o.items;
}

/// value of a parameter by name (special parameters included); null if unset
fn lookup(a: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (name.len == 1) {
        switch (name[0]) {
            '?' => return fmtU(a, last_status),
            '$' => return fmtU(a, shell_pid),
            '!' => return if (last_bg != 0) fmtU(a, last_bg) else null,
            '#' => return fmtU(a, pos_args.items.len),
            '-' => return optString(a),
            '0' => return arg0,
            '1'...'9' => {
                const i = name[0] - '1';
                return if (i < pos_args.items.len) pos_args.items[i] else null;
            },
            else => {},
        }
    }
    if (name.len > 1 and std.ascii.isDigit(name[0])) {
        const i = std.fmt.parseInt(usize, name, 10) catch return null;
        if (i == 0) return arg0;
        return if (i - 1 < pos_args.items.len) pos_args.items[i - 1] else null;
    }
    if (std.mem.eql(u8, name, "LINENO")) return fmtU(a, cur_line);
    if (std.mem.eql(u8, name, "RANDOM")) {
        rand_state = rand_state *% 1103515245 +% 12345;
        return fmtU(a, (rand_state >> 16) & 0x7fff);
    }
    if (std.mem.eql(u8, name, "PPID")) return fmtU(a, c.getppid());
    return getVar(name);
}

fn ifsValue() []const u8 {
    return getVar("IFS") orelse " \t\n";
}

// ===================== expansion =====================
const Field = struct { buf: []u8, q: []bool };

const Exp = struct {
    a: std.mem.Allocator,
    fields: u.Vec(Field),
    cur: u.Vec(u8),
    curq: u.Vec(bool),
    have: bool = false,
    split: bool = true,
    ended_ws: bool = false,

    fn init(a: std.mem.Allocator, split: bool) Exp {
        return .{ .a = a, .fields = u.Vec(Field).init(a), .cur = u.Vec(u8).init(a), .curq = u.Vec(bool).init(a), .split = split };
    }

    fn finish(self: *Exp) void {
        if (!self.have) return;
        self.fields.push(.{ .buf = self.cur.items, .q = self.curq.items });
        self.cur = u.Vec(u8).init(self.a);
        self.curq = u.Vec(bool).init(self.a);
        self.have = false;
    }

    fn addQ(self: *Exp, text: []const u8, quoted: bool) void {
        self.cur.pushSlice(text);
        self.curq.pushN(quoted, text.len);
        self.have = true;
        self.ended_ws = false;
    }

    /// unquoted text subject to IFS splitting
    fn addSplit(self: *Exp, text: []const u8) void {
        if (!self.split) {
            self.addQ(text, false);
            return;
        }
        const ifs = ifsValue();
        if (ifs.len == 0) {
            if (text.len > 0) self.addQ(text, false);
            return;
        }
        for (text) |ch| {
            if (std.mem.indexOfScalar(u8, ifs, ch)) |_| {
                const is_ws = ch == ' ' or ch == '\t' or ch == '\n';
                if (is_ws) {
                    if (self.have) {
                        self.finish();
                        self.ended_ws = true;
                    }
                } else {
                    if (self.have) {
                        self.finish();
                    } else if (!self.ended_ws) {
                        self.fields.push(.{ .buf = &.{}, .q = &.{} });
                    }
                    self.ended_ws = false;
                }
            } else {
                self.cur.push(ch);
                self.curq.push(false);
                self.have = true;
                self.ended_ws = false;
            }
        }
    }
};

fn homeOf(user: []const u8) ?[]const u8 {
    if (user.len == 0) return getVar("HOME");
    if (std.mem.eql(u8, user, "+")) return getVar("PWD");
    if (std.mem.eql(u8, user, "-")) return getVar("OLDPWD");
    if (c.getpwnam(u.zstr(user))) |pw| return std.mem.sliceTo(pw.*.pw_dir, 0);
    return null;
}

var cmd_mode = false;
fn fatalCode() u8 {
    return if (cmd_mode and !opt_e) 127 else 1;
}

fn fatal(status0: u8, comptime fmt: []const u8, args: anytype) ShErr {
    u.errf("sh: " ++ fmt ++ "\n", args);
    const status: u8 = if (status0 == 127) fatalCode() else status0;
    last_status = status;
    if (!interactive) {
        flow = .exit_;
        flow_n = status;
    }
    return error.Abort;
}

fn quotedName(s: []const u8) bool {
    return s.len > 0;
}

fn expandInto(e: *Exp, raw: []const u8, dq_in: bool, assign: bool) ShErr!void {
    var i: usize = 0;
    var dq = dq_in;
    var dq_start_have = e.have;
    var dq_added = false;
    var saw_at_zero = false;
    if (!dq and raw.len > 0 and raw[0] == '~') {
        // tilde prefix
        var j: usize = 1;
        while (j < raw.len and raw[j] != '/' and (!assign or raw[j] != ':')) j += 1;
        const user = raw[1..j];
        var plain = true;
        for (user) |ch| if (ch == '\'' or ch == '"' or ch == '\\' or ch == '$' or ch == '`') {
            plain = false;
        };
        if (plain) {
            if (homeOf(user)) |h| {
                e.addQ(h, true);
                i = j;
            }
        }
    }
    while (i < raw.len) {
        const ch = raw[i];
        switch (ch) {
            '\\' => {
                if (i + 1 >= raw.len) {
                    e.addQ("\\", true);
                    i += 1;
                } else if (raw[i + 1] == '\n') {
                    i += 2;
                } else if (dq) {
                    const n = raw[i + 1];
                    if (n == '$' or n == '`' or n == '"' or n == '\\') {
                        e.addQ(raw[i + 1 .. i + 2], true);
                        dq_added = true;
                        i += 2;
                    } else {
                        e.addQ("\\", true);
                        dq_added = true;
                        i += 1;
                    }
                } else {
                    e.addQ(raw[i + 1 .. i + 2], true);
                    i += 2;
                }
            },
            '\'' => {
                if (dq) {
                    e.addQ("'", true);
                    dq_added = true;
                    i += 1;
                } else {
                    var j = i + 1;
                    while (j < raw.len and raw[j] != '\'') j += 1;
                    e.addQ(raw[i + 1 .. j], true);
                    i = @min(j + 1, raw.len);
                }
            },
            '"' => {
                if (dq == dq_in and !dq_in) {
                    // opening
                    dq = true;
                    dq_start_have = e.have;
                    dq_added = false;
                    saw_at_zero = false;
                    e.have = true;
                    i += 1;
                } else if (dq and !dq_in) {
                    dq = false;
                    if (!dq_added and saw_at_zero) e.have = dq_start_have;
                    i += 1;
                } else {
                    e.addQ("\"", true);
                    i += 1;
                }
            },
            '$' => {
                i = try expandDollar(e, raw, i, dq, &dq_added, &saw_at_zero);
            },
            '`' => {
                var j = i + 1;
                var body = u.Vec(u8).init(e.a);
                while (j < raw.len and raw[j] != '`') {
                    if (raw[j] == '\\' and j + 1 < raw.len and (raw[j + 1] == '$' or raw[j + 1] == '`' or raw[j + 1] == '\\')) {
                        j += 1;
                    }
                    body.push(raw[j]);
                    j += 1;
                }
                const out = try cmdSubst(e.a, body.items);
                if (dq) {
                    e.addQ(out, true);
                    dq_added = true;
                } else e.addSplit(out);
                i = @min(j + 1, raw.len);
            },
            ':' => {
                e.addQ(":", dq);
                if (dq) dq_added = true;
                i += 1;
                if (assign and !dq and i < raw.len and raw[i] == '~') {
                    var j: usize = i + 1;
                    while (j < raw.len and raw[j] != '/' and raw[j] != ':') j += 1;
                    if (homeOf(raw[i + 1 .. j])) |h| {
                        e.addQ(h, true);
                        i = j;
                    }
                }
            },
            else => {
                // plain literal: quoted flag false unless inside double quotes
                e.cur.push(ch);
                e.curq.push(dq);
                e.have = true;
                e.ended_ws = false;
                if (dq) dq_added = true;
                i += 1;
            },
        }
    }
}

fn isNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn expandDollar(e: *Exp, raw: []const u8, start: usize, dq: bool, dq_added: *bool, saw_at_zero: *bool) ShErr!usize {
    var i = start + 1;
    if (i >= raw.len) {
        e.addQ("$", dq);
        return i;
    }
    const n = raw[i];
    if (n == '\'' and !dq) {
        var j = i + 1;
        var o = u.Vec(u8).init(e.a);
        while (j < raw.len and raw[j] != '\'') {
            if (raw[j] != '\\' or j + 1 >= raw.len) {
                o.push(raw[j]);
                j += 1;
                continue;
            }
            j += 1;
            const ec = raw[j];
            j += 1;
            switch (ec) {
                'a' => o.push(7),
                'b' => o.push(8),
                'e', 'E' => o.push(27),
                'f' => o.push(12),
                'n' => o.push('\n'),
                'r' => o.push('\r'),
                't' => o.push('\t'),
                'v' => o.push(11),
                '\\', '\'', '"', '?' => o.push(ec),
                'c' => {
                    if (j < raw.len) {
                        o.push(if (raw[j] == '?') 127 else raw[j] & 31);
                        j += 1;
                    }
                },
                'x' => {
                    var v: u32 = 0;
                    var cnt: usize = 0;
                    while (j < raw.len and cnt < 2) : (cnt += 1) {
                        const d = std.fmt.charToDigit(raw[j], 16) catch break;
                        v = v * 16 + d;
                        j += 1;
                    }
                    o.push(@intCast(v & 0xff));
                },
                'u', 'U' => {
                    var v: u32 = 0;
                    var cnt: usize = 0;
                    const lim: usize = if (ec == 'u') 4 else 8;
                    while (j < raw.len and cnt < lim) : (cnt += 1) {
                        const d = std.fmt.charToDigit(raw[j], 16) catch break;
                        v = v * 16 + d;
                        j += 1;
                    }
                    var ub: [4]u8 = undefined;
                    const l = std.unicode.utf8Encode(@intCast(v), &ub) catch 0;
                    for (ub[0..l]) |b| o.push(b);
                },
                '0'...'7' => {
                    var v: u32 = ec - '0';
                    var cnt: usize = 1;
                    while (j < raw.len and cnt < 3 and raw[j] >= '0' and raw[j] <= '7') : (cnt += 1) {
                        v = v * 8 + (raw[j] - '0');
                        j += 1;
                    }
                    o.push(@intCast(v & 0xff));
                },
                else => {
                    o.push('\\');
                    o.push(ec);
                },
            }
        }
        e.addQ(o.items, true);
        return @min(j + 1, raw.len);
    }
    if (n == '(') {
        if (i + 1 < raw.len and raw[i + 1] == '(') {
            // arithmetic $(( ... ))
            var depth: usize = 0;
            var j = i;
            while (j < raw.len) : (j += 1) {
                if (raw[j] == '(') depth += 1 else if (raw[j] == ')') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            // raw[i..=j] is "(( expr ))" possibly with an extra ')' pairing
            if (j >= raw.len or j < i + 3 or raw[j - 1] != ')') {
                // not arithmetic: treat as command substitution of a subshell
            } else {
                const expr = raw[i + 2 .. j - 1];
                var tmp = Exp.init(e.a, false);
                try expandInto(&tmp, expr, true, false);
                tmp.finish();
                const text = if (tmp.fields.items.len > 0) tmp.fields.items[0].buf else "";
                const v = evalArith(e.a, text) catch return fatal(127, "arithmetic expression error", .{});
                const s = fmtU(e.a, v);
                if (dq) {
                    e.addQ(s, true);
                    dq_added.* = true;
                } else e.addSplit(s);
                return j + 1;
            }
        }
        // command substitution
        var depth: usize = 0;
        var j = i;
        while (j < raw.len) : (j += 1) {
            const ch = raw[j];
            if (ch == '(') depth += 1 else if (ch == ')') {
                depth -= 1;
                if (depth == 0) break;
            } else if (ch == '\'') {
                j += 1;
                while (j < raw.len and raw[j] != '\'') j += 1;
            } else if (ch == '"') {
                j += 1;
                while (j < raw.len and raw[j] != '"') {
                    if (raw[j] == '\\') j += 1;
                    j += 1;
                }
            } else if (ch == '\\') j += 1;
        }
        const body = raw[i + 1 .. @min(j, raw.len)];
        const out = try cmdSubst(e.a, body);
        if (dq) {
            e.addQ(out, true);
            dq_added.* = true;
        } else e.addSplit(out);
        return @min(j + 1, raw.len);
    }
    if (n == '{') {
        var depth: usize = 0;
        var j = i;
        while (j < raw.len) : (j += 1) {
            const ch = raw[j];
            if (ch == '{') depth += 1 else if (ch == '}') {
                depth -= 1;
                if (depth == 0) break;
            } else if (ch == '\'' and !dq) {
                j += 1;
                while (j < raw.len and raw[j] != '\'') j += 1;
            } else if (ch == '\\') j += 1;
        }
        const body = raw[i + 1 .. @min(j, raw.len)];
        try expandBrace(e, body, dq, dq_added, saw_at_zero);
        return @min(j + 1, raw.len);
    }
    // $name, $1, $?, $@ ...
    var name: []const u8 = undefined;
    if (isNameChar(n) and !std.ascii.isDigit(n)) {
        var j = i;
        while (j < raw.len and isNameChar(raw[j])) j += 1;
        name = raw[i..j];
        i = j;
    } else if (std.ascii.isDigit(n)) {
        name = raw[i .. i + 1];
        i += 1;
    } else if (std.mem.indexOfScalar(u8, "@*#?$!-", n) != null) {
        name = raw[i .. i + 1];
        i += 1;
    } else {
        e.addQ("$", dq);
        return i;
    }
    try addParam(e, name, dq, dq_added, saw_at_zero);
    return i;
}

fn addParam(e: *Exp, name: []const u8, dq: bool, dq_added: *bool, saw_at_zero: *bool) ShErr!void {
    if (name.len == 1 and (name[0] == '@' or name[0] == '*')) {
        const params = pos_args.items;
        if (dq and name[0] == '@') {
            if (params.len == 0) {
                saw_at_zero.* = true;
                return;
            }
            for (params, 0..) |p, idx| {
                if (idx > 0) e.finish();
                e.addQ(p, true);
                e.have = true;
            }
            dq_added.* = true;
            return;
        }
        if (dq) {
            // "$*": joined with the first IFS character
            const ifs = ifsValue();
            var o = u.Vec(u8).init(e.a);
            for (params, 0..) |p, idx| {
                if (idx > 0 and ifs.len > 0) o.push(ifs[0]);
                for (p) |ch| o.push(ch);
            }
            e.addQ(o.items, true);
            dq_added.* = true;
            return;
        }
        for (params, 0..) |p, idx| {
            if (idx > 0) {
                if (name[0] == '@') e.finish() else e.addSplit(" ");
            }
            e.addSplit(p);
        }
        return;
    }
    const v = lookup(e.a, name);
    if (v == null and opt_u) {
        return fatal(127, "{s}: parameter not set", .{name});
    }
    const val = v orelse "";
    if (dq) {
        e.addQ(val, true);
        dq_added.* = true;
    } else e.addSplit(val);
}

fn patternFrom(a: std.mem.Allocator, word: []const u8, dq: bool) ShErr![]const u8 {
    var tmp = Exp.init(a, false);
    try expandInto(&tmp, word, dq, false);
    tmp.finish();
    var o = u.Vec(u8).init(a);
    for (tmp.fields.items) |f| {
        for (f.buf, 0..) |ch, k| {
            if (f.q[k] and std.mem.indexOfScalar(u8, "*?[]\\!", ch) != null) o.push('\\');
            o.push(ch);
        }
    }
    return o.items;
}

fn wordText(a: std.mem.Allocator, word: []const u8, dq: bool) ShErr![]const u8 {
    var tmp = Exp.init(a, false);
    try expandInto(&tmp, word, dq, false);
    tmp.finish();
    var o = u.Vec(u8).init(a);
    for (tmp.fields.items, 0..) |f, idx| {
        if (idx > 0) o.push(' ');
        o.pushSlice(f.buf);
    }
    return o.items;
}

fn fnm(pat: []const u8, text: []const u8) bool {
    return c.fnmatch(u.zstr(pat).ptr, u.zstr(text).ptr, 0) == 0;
}

fn removePrefix(val: []const u8, pat: []const u8, longest: bool) []const u8 {
    if (longest) {
        var k: usize = val.len + 1;
        while (k > 0) {
            k -= 1;
            if (fnm(pat, val[0..k])) return val[k..];
        }
    } else {
        var k: usize = 0;
        while (k <= val.len) : (k += 1) if (fnm(pat, val[0..k])) return val[k..];
    }
    return val;
}

fn removeSuffix(val: []const u8, pat: []const u8, longest: bool) []const u8 {
    if (longest) {
        var k: usize = 0;
        while (k <= val.len) : (k += 1) if (fnm(pat, val[k..])) return val[0..k];
    } else {
        var k: usize = val.len + 1;
        while (k > 0) {
            k -= 1;
            if (fnm(pat, val[k..])) return val[0..k];
        }
    }
    return val;
}

fn expandBrace(e: *Exp, body: []const u8, dq: bool, dq_added: *bool, saw_at_zero: *bool) ShErr!void {
    var b = body;
    // ${#name}
    if (b.len > 1 and b[0] == '#') {
        const nm = b[1..];
        if (std.mem.eql(u8, nm, "@") or std.mem.eql(u8, nm, "*")) {
            const s = fmtU(e.a, pos_args.items.len);
            if (dq) e.addQ(s, true) else e.addSplit(s);
            return;
        }
        const v = lookup(e.a, nm);
        if (v == null and opt_u) return fatal(127, "{s}: parameter not set", .{nm});
        // length in characters (UTF-8 aware)
        const val = v orelse "";
        const len = std.unicode.utf8CountCodepoints(val) catch val.len;
        const s = fmtU(e.a, len);
        if (dq) e.addQ(s, true) else e.addSplit(s);
        dq_added.* = true;
        return;
    }
    if (b.len == 0) return fatal(127, "bad substitution", .{});
    // name
    var k: usize = 0;
    if (isNameChar(b[0]) and !std.ascii.isDigit(b[0])) {
        while (k < b.len and isNameChar(b[k])) k += 1;
    } else if (std.ascii.isDigit(b[0])) {
        while (k < b.len and std.ascii.isDigit(b[k])) k += 1;
    } else if (std.mem.indexOfScalar(u8, "@*#?$!-", b[0]) != null) {
        k = 1;
    } else return fatal(127, "bad substitution", .{});
    const name = b[0..k];
    b = b[k..];
    if (b.len == 0) return addParam(e, name, dq, dq_added, saw_at_zero);

    var colon = false;
    var op = b[0];
    var word: []const u8 = "";
    if (op == ':') {
        colon = true;
        if (b.len < 2) return fatal(127, "bad substitution", .{});
        op = b[1];
        word = b[2..];
    } else word = b[1..];

    const v = lookup(e.a, name);
    const is_null = v == null or (colon and v.?.len == 0);

    switch (op) {
        '-', '+', '=', '?' => {
            switch (op) {
                '-' => {
                    if (is_null) return expandInto(e, word, dq, false);
                    return addParamVal(e, v.?, dq, dq_added);
                },
                '+' => {
                    if (!is_null) return expandInto(e, word, dq, false);
                    return;
                },
                '=' => {
                    if (is_null) {
                        const w = try wordText(e.a, word, dq);
                        if (!validName(name) or !setVar(name, w)) return fatal(127, "{s}: cannot assign", .{name});
                        return addParamVal(e, w, dq, dq_added);
                    }
                    return addParamVal(e, v.?, dq, dq_added);
                },
                else => {
                    if (is_null) {
                        const w = try wordText(e.a, word, dq);
                        if (w.len == 0) return fatal(127, "{s}: parameter {s}", .{ name, if (v == null) "not set" else "null or not set" });
                        return fatal(127, "{s}: {s}", .{ name, w });
                    }
                    return addParamVal(e, v.?, dq, dq_added);
                },
            }
        },
        '#', '%' => {
            if (colon) return fatal(127, "bad substitution", .{});
            var longest = false;
            var w = word;
            if (w.len > 0 and w[0] == op) {
                longest = true;
                w = w[1..];
            }
            if (v == null and opt_u) return fatal(127, "{s}: parameter not set", .{name});
            const val = v orelse "";
            const pat = try patternFrom(e.a, w, false);
            const r = if (op == '#') removePrefix(val, pat, longest) else removeSuffix(val, pat, longest);
            return addParamVal(e, r, dq, dq_added);
        },
        '/' => {
            // ${v/pat/rep} and ${v//pat/rep}
            var all = false;
            var w = word;
            if (w.len > 0 and w[0] == '/') {
                all = true;
                w = w[1..];
            }
            const slash = std.mem.indexOfScalar(u8, w, '/');
            const pat = try patternFrom(e.a, if (slash) |s| w[0..s] else w, false);
            const rep = try wordText(e.a, if (slash) |s| w[s + 1 ..] else "", dq);
            const val = v orelse "";
            var o = u.Vec(u8).init(e.a);
            var idx: usize = 0;
            while (idx <= val.len) {
                var matched: ?usize = null;
                if (pat.len > 0) {
                    var l: usize = val.len - idx + 1;
                    while (l > 0) {
                        l -= 1;
                        if (l > 0 and fnm(pat, val[idx .. idx + l])) {
                            matched = l;
                            break;
                        }
                    }
                }
                if (matched) |l| {
                    for (rep) |ch| o.push(ch);
                    idx += l;
                    if (!all) {
                        for (val[idx..]) |ch| o.push(ch);
                        break;
                    }
                } else {
                    if (idx < val.len) o.push(val[idx]);
                    idx += 1;
                }
            }
            return addParamVal(e, o.items, dq, dq_added);
        },
        else => {
            if (colon) {
                // ${v:offset[:length]}
                const val = v orelse "";
                const rest = b[1..];
                const sc = std.mem.indexOfScalar(u8, rest, ':');
                const off_s = std.mem.trim(u8, try wordText(e.a, if (sc) |s| rest[0..s] else rest, dq), " ");
                var off: i64 = evalArith(e.a, off_s) catch return fatal(127, "arithmetic expression error", .{});
                if (off < 0) off += @intCast(val.len);
                if (off < 0) off = 0;
                if (off > val.len) off = @intCast(val.len);
                var end: i64 = @intCast(val.len);
                if (sc) |s| {
                    const len_s = std.mem.trim(u8, try wordText(e.a, rest[s + 1 ..], dq), " ");
                    const l = evalArith(e.a, len_s) catch return fatal(127, "arithmetic expression error", .{});
                    end = if (l < 0) @as(i64, @intCast(val.len)) + l else off + l;
                    if (end > val.len) end = @intCast(val.len);
                    if (end < off) end = off;
                }
                return addParamVal(e, val[@intCast(off)..@intCast(end)], dq, dq_added);
            }
            return fatal(127, "bad substitution", .{});
        },
    }
}

fn addParamVal(e: *Exp, val: []const u8, dq: bool, dq_added: *bool) ShErr!void {
    if (dq) {
        e.addQ(val, true);
        dq_added.* = true;
    } else e.addSplit(val);
}

// ----- pathname expansion -----
fn hasGlob(f: Field) bool {
    for (f.buf, 0..) |ch, k| {
        if (f.q[k]) continue;
        if (ch == '*' or ch == '?') return true;
        if (ch == '[') {
            // a bracket expression needs a closing ']' after at least one character
            var j = k + 2;
            while (j < f.buf.len) : (j += 1) if (f.buf[j] == ']' and !f.q[j]) return true;
        }
    }
    return false;
}

fn globPattern(a: std.mem.Allocator, f: Field) []const u8 {
    var o = u.Vec(u8).init(a);
    for (f.buf, 0..) |ch, k| {
        if (f.q[k] and std.mem.indexOfScalar(u8, "*?[]\\", ch) != null) o.push('\\');
        o.push(ch);
    }
    return o.items;
}

fn segHasGlob(seg: []const u8) bool {
    var k: usize = 0;
    while (k < seg.len) : (k += 1) {
        if (seg[k] == '\\') {
            k += 1;
            continue;
        }
        if (seg[k] == '*' or seg[k] == '?' or seg[k] == '[') return true;
    }
    return false;
}

fn unescapeSeg(a: std.mem.Allocator, seg: []const u8) []const u8 {
    var o = u.Vec(u8).init(a);
    var k: usize = 0;
    while (k < seg.len) : (k += 1) {
        if (seg[k] == '\\' and k + 1 < seg.len) k += 1;
        o.push(seg[k]);
    }
    return o.items;
}

fn globWalk(a: std.mem.Allocator, base: []const u8, segs: []const []const u8, out: *u.Vec([]const u8)) void {
    if (segs.len == 0) {
        out.push(base);
        return;
    }
    const seg = segs[0];
    const dir = if (base.len == 0) "." else base;
    if (!segHasGlob(seg)) {
        const lit = unescapeSeg(a, seg);
        const next = if (base.len == 0) lit else if (std.mem.eql(u8, base, "/")) std.fmt.allocPrint(a, "/{s}", .{lit}) catch return else std.fmt.allocPrint(a, "{s}/{s}", .{ base, lit }) catch return;
        if (segs.len == 1) {
            if (u.stat(next, false) != null) out.push(next);
        } else if (u.isDir(next)) globWalk(a, next, segs[1..], out);
        return;
    }
    var ents = u.Vec(u.DirEnt).init(a);
    if (!u.listDir(dir, &ents)) return;
    for (ents.items) |en| {
        const name: []const u8 = en.name;
        if (name[0] == '.' and seg[0] != '.') continue;
        if (c.fnmatch(u.zstr(seg).ptr, en.name.ptr, 0) != 0) continue;
        const next = if (base.len == 0) std.fmt.allocPrint(a, "{s}", .{name}) catch continue else if (std.mem.eql(u8, base, "/")) std.fmt.allocPrint(a, "/{s}", .{name}) catch continue else std.fmt.allocPrint(a, "{s}/{s}", .{ base, name }) catch continue;
        if (segs.len > 1) {
            if (u.isDir(next)) globWalk(a, next, segs[1..], out);
        } else out.push(next);
    }
}

fn globExpand(a: std.mem.Allocator, f: Field, out: *u.Vec([]const u8)) void {
    const pat = globPattern(a, f);
    var segs = u.Vec([]const u8).init(a);
    var it = std.mem.splitScalar(u8, pat, '/');
    var base: []const u8 = "";
    var first = true;
    while (it.next()) |s| {
        if (first and s.len == 0 and pat.len > 0) {
            base = "/";
            first = false;
            continue;
        }
        first = false;
        if (s.len == 0) continue;
        segs.push(s);
    }
    var res = u.Vec([]const u8).init(a);
    globWalk(a, base, segs.items, &res);
    if (res.items.len == 0) {
        out.push(unquoteField(a, f));
        return;
    }
    std.mem.sort([]const u8, res.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    for (res.items) |r| out.push(r);
}

fn unquoteField(a: std.mem.Allocator, f: Field) []const u8 {
    _ = a;
    return f.buf;
}

/// full word-list expansion: split + pathname expansion
fn expandWords(a: std.mem.Allocator, words: []const []const u8) ShErr![][]const u8 {
    var out = u.Vec([]const u8).init(a);
    for (words) |w| {
        var e = Exp.init(a, true);
        try expandInto(&e, w, false, false);
        e.finish();
        for (e.fields.items) |f| {
            if (!opt_f and hasGlob(f)) globExpand(a, f, &out) else out.push(f.buf);
        }
    }
    return out.items;
}

fn expandOne(a: std.mem.Allocator, word: []const u8, assign: bool) ShErr![]const u8 {
    var e = Exp.init(a, false);
    try expandInto(&e, word, false, assign);
    e.finish();
    if (e.fields.items.len == 1) return e.fields.items[0].buf;
    var o = u.Vec(u8).init(a);
    for (e.fields.items) |f| o.pushSlice(f.buf);
    return o.items;
}

// ===================== arithmetic =====================
const ArithErr = error{ArithError};

const AP = struct {
    s: []const u8,
    i: usize = 0,
    a: std.mem.Allocator,

    fn skip(self: *AP) void {
        while (self.i < self.s.len and (self.s[self.i] == ' ' or self.s[self.i] == '\t' or self.s[self.i] == '\n')) self.i += 1;
    }

    fn peekOp(self: *AP, ops: []const []const u8) ?[]const u8 {
        self.skip();
        for (ops) |op| {
            if (std.mem.startsWith(u8, self.s[self.i..], op)) return op;
        }
        return null;
    }

    fn varValue(self: *AP, name: []const u8) ArithErr!i64 {
        const v = lookup(self.a, name) orelse {
            if (opt_u) {
                u.errf("sh: {s}: parameter not set\n", .{name});
                return error.ArithError;
            }
            return 0;
        };
        const t = std.mem.trim(u8, v, " \t");
        if (t.len == 0) return 0;
        return parseNum(t) orelse blk: {
            // value may itself be an expression
            break :blk evalArith(self.a, t) catch return error.ArithError;
        };
    }

    fn expr(self: *AP) ArithErr!i64 {
        var v = try self.assign();
        while (true) {
            self.skip();
            if (self.i < self.s.len and self.s[self.i] == ',') {
                self.i += 1;
                v = try self.assign();
            } else break;
        }
        return v;
    }

    fn assign(self: *AP) ArithErr!i64 {
        self.skip();
        const save = self.i;
        if (self.i < self.s.len and (std.ascii.isAlphabetic(self.s[self.i]) or self.s[self.i] == '_')) {
            var j = self.i;
            while (j < self.s.len and isNameChar(self.s[j])) j += 1;
            const name = self.s[self.i..j];
            self.i = j;
            self.skip();
            const aops = [_][]const u8{ "<<=", ">>=", "+=", "-=", "*=", "/=", "%=", "&=", "^=", "|=", "=" };
            for (aops) |op| {
                if (std.mem.startsWith(u8, self.s[self.i..], op)) {
                    if (std.mem.eql(u8, op, "=") and self.i + 1 < self.s.len and self.s[self.i + 1] == '=') break;
                    self.i += op.len;
                    const rhs = try self.assign();
                    var nv = rhs;
                    if (!std.mem.eql(u8, op, "=")) {
                        const cur = try self.varValue(name);
                        nv = try applyOp(op[0 .. op.len - 1], cur, rhs);
                    }
                    const txt = fmtU(self.a, nv);
                    _ = setVar(name, txt);
                    return nv;
                }
            }
            self.i = save;
        }
        return self.ternary();
    }

    fn ternary(self: *AP) ArithErr!i64 {
        const cond = try self.binary(0);
        self.skip();
        if (self.i < self.s.len and self.s[self.i] == '?') {
            self.i += 1;
            const a1 = try self.assign();
            self.skip();
            if (self.i >= self.s.len or self.s[self.i] != ':') return error.ArithError;
            self.i += 1;
            const b1 = try self.assign();
            return if (cond != 0) a1 else b1;
        }
        return cond;
    }

    const levels = [_][]const []const u8{
        &.{"||"},
        &.{"&&"},
        &.{"|"},
        &.{"^"},
        &.{"&"},
        &.{ "==", "!=" },
        &.{ "<=", ">=", "<", ">" },
        &.{ "<<", ">>" },
        &.{ "+", "-" },
        &.{ "*", "/", "%" },
    };

    fn binary(self: *AP, lvl: usize) ArithErr!i64 {
        if (lvl >= levels.len) return self.unary();
        var l = try self.binary(lvl + 1);
        while (true) {
            self.skip();
            var found: ?[]const u8 = null;
            for (levels[lvl]) |op| {
                if (std.mem.startsWith(u8, self.s[self.i..], op)) {
                    // don't confuse "|" with "||", "&" with "&&", "<" with "<<", "*" with "**" and assignment ops
                    const after = self.i + op.len;
                    if (after < self.s.len) {
                        const nx = self.s[after];
                        if (op.len == 1 and (op[0] == '|' or op[0] == '&') and nx == op[0]) continue;
                        if (op.len == 1 and (op[0] == '<' or op[0] == '>') and nx == op[0]) continue;
                        if (op.len == 1 and op[0] == '*' and nx == '*') continue;
                        if (nx == '=' and (op.len == 1 and std.mem.indexOfScalar(u8, "+-*/%&^|", op[0]) != null)) continue;
                        if (nx == '=' and (std.mem.eql(u8, op, "<<") or std.mem.eql(u8, op, ">>"))) continue;
                    }
                    found = op;
                    break;
                }
            }
            const op = found orelse return l;
            self.i += op.len;
            if (std.mem.eql(u8, op, "&&")) {
                const r = try self.binary(lvl + 1);
                l = @intFromBool(l != 0 and r != 0);
            } else if (std.mem.eql(u8, op, "||")) {
                const r = try self.binary(lvl + 1);
                l = @intFromBool(l != 0 or r != 0);
            } else {
                const r = try self.binary(lvl + 1);
                l = try applyOp(op, l, r);
            }
        }
    }

    fn unary(self: *AP) ArithErr!i64 {
        self.skip();
        if (self.i >= self.s.len) return error.ArithError;
        const ch = self.s[self.i];
        if (ch == '-' or ch == '+' or ch == '!' or ch == '~') {
            self.i += 1;
            const v = try self.unary();
            return switch (ch) {
                '-' => -%v,
                '+' => v,
                '!' => @intFromBool(v == 0),
                else => ~v,
            };
        }
        return self.power();
    }

    fn power(self: *AP) ArithErr!i64 {
        const base = try self.primary();
        self.skip();
        if (std.mem.startsWith(u8, self.s[self.i..], "**")) {
            self.i += 2;
            const ex = try self.unary();
            if (ex < 0) return error.ArithError;
            var r: i64 = 1;
            var k: i64 = 0;
            while (k < ex) : (k += 1) r *%= base;
            return r;
        }
        return base;
    }

    fn primary(self: *AP) ArithErr!i64 {
        self.skip();
        if (self.i >= self.s.len) return error.ArithError;
        const ch = self.s[self.i];
        if (ch == '(') {
            self.i += 1;
            const v = try self.expr();
            self.skip();
            if (self.i >= self.s.len or self.s[self.i] != ')') return error.ArithError;
            self.i += 1;
            return v;
        }
        if (std.ascii.isDigit(ch)) {
            var j = self.i;
            while (j < self.s.len and (std.ascii.isAlphanumeric(self.s[j]) or self.s[j] == '_')) j += 1;
            const v = parseNum(self.s[self.i..j]) orelse return error.ArithError;
            self.i = j;
            return v;
        }
        if (std.ascii.isAlphabetic(ch) or ch == '_') {
            var j = self.i;
            while (j < self.s.len and isNameChar(self.s[j])) j += 1;
            const name = self.s[self.i..j];
            self.i = j;
            return self.varValue(name);
        }
        return error.ArithError;
    }
};

fn parseNum(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) return std.fmt.parseInt(i64, s[2..], 16) catch null;
    if (s.len > 1 and s[0] == '0') return std.fmt.parseInt(i64, s[1..], 8) catch null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

fn applyOp(op: []const u8, l: i64, r: i64) ArithErr!i64 {
    if (std.mem.eql(u8, op, "+")) return l +% r;
    if (std.mem.eql(u8, op, "-")) return l -% r;
    if (std.mem.eql(u8, op, "*")) return l *% r;
    if (std.mem.eql(u8, op, "/")) {
        if (r == 0) {
            u.err("sh: arithmetic: division by 0\n");
            return error.ArithError;
        }
        return @divTrunc(l, r);
    }
    if (std.mem.eql(u8, op, "%")) {
        if (r == 0) {
            u.err("sh: arithmetic: division by 0\n");
            return error.ArithError;
        }
        return @rem(l, r);
    }
    if (std.mem.eql(u8, op, "<<")) return l << @intCast(@mod(r, 64));
    if (std.mem.eql(u8, op, ">>")) return l >> @intCast(@mod(r, 64));
    if (std.mem.eql(u8, op, "<")) return @intFromBool(l < r);
    if (std.mem.eql(u8, op, "<=")) return @intFromBool(l <= r);
    if (std.mem.eql(u8, op, ">")) return @intFromBool(l > r);
    if (std.mem.eql(u8, op, ">=")) return @intFromBool(l >= r);
    if (std.mem.eql(u8, op, "==")) return @intFromBool(l == r);
    if (std.mem.eql(u8, op, "!=")) return @intFromBool(l != r);
    if (std.mem.eql(u8, op, "&")) return l & r;
    if (std.mem.eql(u8, op, "^")) return l ^ r;
    if (std.mem.eql(u8, op, "|")) return l | r;
    return error.ArithError;
}

fn evalArith(a: std.mem.Allocator, text: []const u8) ArithErr!i64 {
    var p = AP{ .s = text, .a = a };
    p.skip();
    if (p.i >= p.s.len) return 0;
    const v = try p.expr();
    p.skip();
    if (p.i < p.s.len) {
        u.errf("sh: arithmetic: syntax error: \"{s}\"\n", .{text});
        return error.ArithError;
    }
    return v;
}

// ===================== processes, redirections =====================
fn waitStatus(status: u32) u8 {
    if (status & 0x7f != 0 and status & 0x7f != 0x7f) return @intCast(128 + (status & 0x7f));
    return @intCast((status >> 8) & 0xff);
}

fn checkTraps() void {
    if (pending_sigs == 0 or running_trap) return;
    var sig: u6 = 1;
    while (sig < 63) : (sig += 1) {
        const bit = @as(u64, 1) << sig;
        if (pending_sigs & bit == 0) continue;
        pending_sigs &= ~bit;
        if (trap_cmd[sig]) |cmd| {
            running_trap = true;
            const saved = last_status;
            const sf = flow;
            const sfn = flow_n;
            flow = .none;
            _ = evalString(cmd);
            if (flow == .none) {
                flow = sf;
                flow_n = sfn;
            }
            last_status = saved;
            running_trap = false;
        }
    }
}

fn waitFor(pid: i32) u8 {
    for (jobs.items, 0..) |j, k| if (j.pid == pid and j.status != null) {
        const st = j.status.?;
        std.mem.copyForwards(Job, jobs.items[k .. jobs.items.len - 1], jobs.items[k + 1 ..]);
        jobs.items.len -= 1;
        return st;
    };
    var status: u32 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, 0);
        if (u.ok(rc)) break;
        if (u.errno(rc) == .INTR) {
            checkTraps();
            continue;
        }
        return 127;
    }
    for (jobs.items, 0..) |j, k| if (j.pid == pid) {
        std.mem.copyForwards(Job, jobs.items[k .. jobs.items.len - 1], jobs.items[k + 1 ..]);
        jobs.items.len -= 1;
        break;
    };
    return waitStatus(status);
}

fn reapBg() void {
    for (jobs.items) |*j| {
        if (j.status != null) continue;
        var st: u32 = 0;
        const rc = linux.waitpid(j.pid, &st, 1); // WNOHANG
        if (u.ok(rc) and rc != 0) j.status = waitStatus(st);
    }
}

fn setSignal(sig: usize, mode: enum { dfl, ign, catch_ }) void {
    var act = linux.Sigaction{
        .handler = .{ .handler = switch (mode) {
            .dfl => null,
            .ign => @ptrFromInt(1),
            .catch_ => sigHandler,
        } },
        .mask = @splat(0),
        .flags = 0,
    };
    _ = linux.sigaction(@enumFromInt(sig), &act, null);
}

var parent_trap_cmd: [65]?[]const u8 = @splat(null);
var parent_trap_ign: [65]bool = @splat(false);
var parent_exit: ?[]const u8 = null;
var parent_err: ?[]const u8 = null;
var trap_touched = false;

fn childInit() void {
    if (!in_subshell) {
        parent_trap_cmd = trap_cmd;
        parent_trap_ign = trap_ign;
        parent_exit = trap_exit;
        parent_err = trap_err;
        trap_touched = false;
    }
    in_subshell = true;
    jobs.items.len = 0;
    trap_exit = null;
    trap_err = null;
    var sig: usize = 1;
    while (sig < 64) : (sig += 1) {
        if (trap_cmd[sig] != null) {
            trap_cmd[sig] = null;
            setSignal(sig, .dfl);
        }
    }
    pending_sigs = 0;
    if (interactive) {
        // children of an interactive shell get default signal handling
        setSignal(2, .dfl);
        setSignal(3, .dfl);
        setSignal(15, .dfl);
    }
}

fn exitChild(status: u8) noreturn {
    var code: u8 = if (flow == .exit_) @intCast(flow_n & 0xff) else status;
    if (trap_exit != null) {
        last_status = code;
        flow = .none;
        runExitTrap();
        if (flow == .exit_) code = @intCast(flow_n & 0xff);
    }
    linux.exit_group(code);
}

fn cmdSubst(a: std.mem.Allocator, text: []const u8) ShErr![]const u8 {
    var fds: [2]i32 = undefined;
    if (u.errno(linux.pipe(&fds)) != .SUCCESS) return fatal(1, "cannot create pipe", .{});
    const pid_raw = linux.fork();
    if (u.errno(pid_raw) != .SUCCESS) return fatal(1, "fork failed", .{});
    if (pid_raw == 0) {
        _ = linux.close(fds[0]);
        _ = linux.dup2(fds[1], 1);
        _ = linux.close(fds[1]);
        childInit();
        const st = evalString(text);
        exitChild(st);
    }
    _ = linux.close(fds[1]);
    var out = u.Vec(u8).init(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const r = linux.read(fds[0], &buf, buf.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r) or r == 0) break;
        out.pushSlice(buf[0..r]);
    }
    _ = linux.close(fds[0]);
    last_status = waitFor(@intCast(pid_raw));
    cmdsub_status = last_status;
    var s = out.items;
    while (s.len > 0 and s[s.len - 1] == '\n') s = s[0 .. s.len - 1];
    return s;
}

var cmdsub_status: u8 = 0;

const Saved = struct { fd: i32, saved: i32 };

fn saveFd(saves: ?*u.Vec(Saved), fd: i32) void {
    const sv = saves orelse return;
    for (sv.items) |e| if (e.fd == fd) return;
    const rc = linux.fcntl(fd, 1030, 10); // F_DUPFD_CLOEXEC >= 10
    sv.push(.{ .fd = fd, .saved = if (u.ok(rc)) @intCast(rc) else -1 });
}

fn restoreFds(saves: *u.Vec(Saved)) void {
    var i = saves.items.len;
    while (i > 0) {
        i -= 1;
        const e = saves.items[i];
        if (e.saved >= 0) {
            _ = linux.dup2(e.saved, e.fd);
            _ = linux.close(e.saved);
        } else _ = linux.close(e.fd);
    }
    saves.items.len = 0;
}

fn redirErr(comptime fmt: []const u8, args: anytype) bool {
    u.errf("sh: " ++ fmt ++ "\n", args);
    last_status = 1;
    return false;
}

fn moveFd(fd: i32, target: i32) bool {
    if (fd == target) return true;
    const rc = linux.dup2(fd, target);
    _ = linux.close(fd);
    return u.ok(rc);
}

fn applyRedirs(a: std.mem.Allocator, redirs: []const P.Redir, saves: ?*u.Vec(Saved)) bool {
    for (redirs) |r| {
        saveFd(saves, r.fd);
        switch (r.op) {
            .in, .out, .append, .rdwr, .clobber => {
                const path = expandOne(a, r.word, false) catch return false;
                var flags: std.posix.O = undefined;
                switch (r.op) {
                    .in => flags = .{ .ACCMODE = .RDONLY },
                    .out, .clobber => flags = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
                    .append => flags = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
                    else => flags = .{ .ACCMODE = .RDWR, .CREAT = true },
                }
                if (r.op == .out and opt_C) {
                    if (u.stat(path, true)) |st| {
                        if (st.mode & linux.S.IFMT == linux.S.IFREG) return redirErr("cannot create {s}: File exists", .{path});
                    }
                    flags.EXCL = false;
                }
                const rc = linux.open(u.zstr(path), flags, 0o666);
                if (!u.ok(rc)) {
                    const en = u.errno(rc);
                    if (r.op == .in or en == .NOENT and r.op == .rdwr) return redirErr("cannot open {s}: {s}", .{ path, u.strerr(en) });
                    return redirErr("cannot create {s}: {s}", .{ path, u.strerr(en) });
                }
                if (!moveFd(@intCast(rc), r.fd)) return redirErr("{d}: Bad file descriptor", .{r.fd});
            },
            .dup_in, .dup_out => {
                const w = expandOne(a, r.word, false) catch return false;
                if (std.mem.eql(u8, w, "-")) {
                    _ = linux.close(r.fd);
                    continue;
                }
                const src = std.fmt.parseInt(i32, w, 10) catch return redirErr("{s}: bad fd number", .{w});
                if (src == r.fd) continue;
                if (!u.ok(linux.dup2(src, r.fd))) return redirErr("{d}: Bad file descriptor", .{src});
            },
            .heredoc => {
                const hd = r.heredoc.?;
                var body: []const u8 = hd.body;
                if (!hd.quoted) {
                    var e = Exp.init(a, false);
                    expandInto(&e, hd.body, true, false) catch return false;
                    e.finish();
                    var o = u.Vec(u8).init(a);
                    for (e.fields.items) |f| for (f.buf) |ch| o.push(ch);
                    body = o.items;
                }
                const mfd = linux.memfd_create("sh-heredoc", 0);
                if (!u.ok(mfd)) return redirErr("cannot create here-document", .{});
                const fd: i32 = @intCast(mfd);
                var off: usize = 0;
                while (off < body.len) {
                    const w = linux.write(fd, body.ptr + off, body.len - off);
                    if (!u.ok(w)) break;
                    off += w;
                }
                _ = linux.syscall3(.lseek, @as(usize, @intCast(fd)), 0, 0);
                if (!moveFd(fd, r.fd)) return redirErr("here-document failed", .{});
            },
        }
    }
    return true;
}

// ===================== execution =====================
fn errCheck(status: u8) void {
    if (status == 0 or noerr > 0 or flow == .exit_) return;
    if (trap_err) |cmd| {
        if (!running_trap) {
            running_trap = true;
            const saved = last_status;
            _ = evalString(cmd);
            last_status = saved;
            running_trap = false;
        }
    }
    if (opt_e) {
        flow = .exit_;
        flow_n = status;
    }
}

fn execNode(n: *Node) u8 {
    const st: u8 = switch (n.kind) {
        .list => execList(n),
        .andor => execAndOr(n),
        .pipeline => execPipeline(n),
        .simple => execSimple(n, false),
        .subshell, .group, .if_, .while_, .until_, .for_, .case_ => execCompound(n),
        .funcdef => blk: {
            const key = A.dupe(u8, n.name) catch break :blk 1;
            funcs.put(A, key, n.children[0]) catch break :blk 1;
            break :blk 0;
        },
    };
    last_status = st;
    return st;
}

fn execList(n: *Node) u8 {
    var st: u8 = 0;
    for (n.children, 0..) |ch, i| {
        if (flow != .none) break;
        if (n.ops[i] == '&') {
            st = execBackground(ch);
        } else {
            st = execNode(ch);
        }
        checkTraps();
        reapBg();
    }
    return st;
}

fn execBackground(n: *Node) u8 {
    const pid_raw = linux.fork();
    if (u.errno(pid_raw) != .SUCCESS) {
        u.err("sh: fork failed\n");
        return 1;
    }
    if (pid_raw == 0) {
        childInit();
        if (!interactive) {
            const fd = linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
            if (u.ok(fd)) _ = moveFd(@intCast(fd), 0);
            // ignore INT/QUIT for async commands when job control is off
            setSignal(2, .ign);
            setSignal(3, .ign);
        }
        const st = if (n.kind == .simple) execSimple(n, true) else execNode(n);
        exitChild(st);
    }
    last_bg = @intCast(pid_raw);
    jobs.push(.{ .pid = last_bg, .status = null });
    return 0;
}

fn execAndOr(n: *Node) u8 {
    var st: u8 = 0;
    var i: usize = 0;
    const last = n.children.len - 1;
    while (i <= last) : (i += 1) {
        if (i > 0) {
            const op = n.ops[i - 1];
            // skip the operand if the short-circuit condition says so
            if ((op == '&' and st != 0) or (op == '|' and st == 0)) continue;
        }
        const guarded = i < last;
        if (guarded) noerr += 1;
        st = execNode(n.children[i]);
        if (guarded) noerr -= 1;
        if (flow != .none) return st;
        // the status decides whether the next operand runs; later operands see this status
    }
    return st;
}

fn execPipeline(n: *Node) u8 {
    if (n.children.len == 1) {
        if (n.negate) {
            noerr += 1;
            const st = execNode(n.children[0]);
            noerr -= 1;
            return if (flow != .none) st else if (st == 0) 1 else 0;
        }
        return execNode(n.children[0]);
    }
    const count = n.children.len;
    var pids = u.Vec(i32).init(A);
    var prev_read: i32 = -1;
    var i: usize = 0;
    if (n.negate) noerr += 1;
    while (i < count) : (i += 1) {
        var fds: [2]i32 = .{ -1, -1 };
        if (i + 1 < count) {
            if (u.errno(linux.pipe(&fds)) != .SUCCESS) {
                u.err("sh: pipe failed\n");
                break;
            }
        }
        const pid_raw = linux.fork();
        if (u.errno(pid_raw) != .SUCCESS) {
            u.err("sh: fork failed\n");
            break;
        }
        if (pid_raw == 0) {
            if (prev_read >= 0) {
                _ = linux.dup2(prev_read, 0);
                _ = linux.close(prev_read);
            }
            if (fds[1] >= 0) {
                _ = linux.dup2(fds[1], 1);
                _ = linux.close(fds[0]);
                _ = linux.close(fds[1]);
            }
            childInit();
            const ch = n.children[i];
            const st = if (ch.kind == .simple) execSimple(ch, true) else execNode(ch);
            exitChild(st);
        }
        pids.push(@intCast(pid_raw));
        if (prev_read >= 0) _ = linux.close(prev_read);
        if (fds[1] >= 0) _ = linux.close(fds[1]);
        prev_read = fds[0];
    }
    if (prev_read >= 0) _ = linux.close(prev_read);
    var st: u8 = 0;
    var any_fail: u8 = 0;
    for (pids.items) |pid| {
        st = waitFor(pid);
        if (st != 0) any_fail = st;
    }
    if (opt_pipefail and any_fail != 0) st = any_fail;
    if (n.negate) {
        noerr -= 1;
        st = if (st == 0) 1 else 0;
    } else errCheck(st);
    return st;
}

fn aliasLookup(name: []const u8) ?[]const u8 {
    return aliases.get(name);
}

fn execCompound(n: *Node) u8 {
    var arena = std.heap.ArenaAllocator.init(A);
    defer arena.deinit();
    const a = arena.allocator();
    var saves = u.Vec(Saved).init(A);
    if (n.redirs.len > 0 and n.kind != .subshell) {
        if (!applyRedirs(a, n.redirs, &saves)) {
            restoreFds(&saves);
            return 1;
        }
    }
    const st: u8 = switch (n.kind) {
        .subshell => execSubshell(n, a),
        .group => execNode(n.children[0]),
        .if_ => execIf(n),
        .while_, .until_ => execWhile(n),
        .for_ => execFor(n, a),
        .case_ => execCase(n, a),
        else => 0,
    };
    if (saves.items.len > 0) restoreFds(&saves);
    return st;
}

fn execSubshell(n: *Node, a: std.mem.Allocator) u8 {
    const pid_raw = linux.fork();
    if (u.errno(pid_raw) != .SUCCESS) {
        u.err("sh: fork failed\n");
        return 1;
    }
    if (pid_raw == 0) {
        childInit();
        if (n.redirs.len > 0 and !applyRedirs(a, n.redirs, null)) linux.exit_group(1);
        const st = execNode(n.children[0]);
        exitChild(st);
    }
    const st = waitFor(@intCast(pid_raw));
    errCheck(st);
    return st;
}

fn execIf(n: *Node) u8 {
    const pairs = if (n.has_else) (n.children.len - 1) / 2 else n.children.len / 2;
    var k: usize = 0;
    while (k < pairs) : (k += 1) {
        noerr += 1;
        const cs = execNode(n.children[2 * k]);
        noerr -= 1;
        if (flow != .none) return cs;
        if (cs == 0) return execNode(n.children[2 * k + 1]);
    }
    if (n.has_else) return execNode(n.children[n.children.len - 1]);
    return 0;
}

fn loopFlow() enum { next, stop } {
    switch (flow) {
        .break_ => {
            if (flow_n > 1) {
                flow_n -= 1;
            } else flow = .none;
            return .stop;
        },
        .continue_ => {
            if (flow_n > 1) {
                flow_n -= 1;
                return .stop;
            }
            flow = .none;
            return .next;
        },
        .none => return .next,
        else => return .stop,
    }
}

fn execWhile(n: *Node) u8 {
    var st: u8 = 0;
    const until = n.kind == .until_;
    loop_depth += 1;
    defer loop_depth -= 1;
    while (true) {
        noerr += 1;
        const cs = execNode(n.children[0]);
        noerr -= 1;
        if (flow != .none) break;
        if ((cs == 0) == until) break;
        st = execNode(n.children[1]);
        checkTraps();
        if (loopFlow() == .stop) break;
    }
    return st;
}

fn execFor(n: *Node, a: std.mem.Allocator) u8 {
    var st: u8 = 0;
    var items: []const []const u8 = undefined;
    if (n.has_in) {
        items = expandWords(a, n.words) catch return last_status;
    } else {
        items = a.dupe([]const u8, pos_args.items) catch return 1;
    }
    loop_depth += 1;
    defer loop_depth -= 1;
    for (items) |it| {
        if (!setVar(n.name, it)) return 1;
        st = execNode(n.children[0]);
        checkTraps();
        if (loopFlow() == .stop) break;
    }
    return st;
}

fn execCase(n: *Node, a: std.mem.Allocator) u8 {
    const word = expandOne(a, n.words[0], false) catch return last_status;
    for (n.cases) |item| {
        for (item.patterns) |p| {
            const pat = patternFrom(a, p, false) catch return last_status;
            if (fnm(pat, word)) {
                if (item.body) |b| return execNode(b);
                return 0;
            }
        }
    }
    return 0;
}

// ----- simple commands -----
const inproc_applets = [_][]const u8{ "echo", "printf", "test", "[", "[[", "true", "false", "kill", "pwd", "basename", "dirname" };

fn isInproc(name: []const u8) bool {
    for (inproc_applets) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

const builtin_names = [_][]const u8{ ":", ".", "source", "break", "continue", "eval", "exec", "exit", "export", "readonly", "return", "set", "shift", "times", "trap", "unset", "alias", "unalias", "cd", "read", "command", "type", "hash", "wait", "umask", "getopts", "local", "ulimit", "jobs", "fg", "bg", "let" };

fn isBuiltin(name: []const u8) bool {
    for (builtin_names) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

fn isSpecial(name: []const u8) bool {
    const sp = [_][]const u8{ ":", ".", "break", "continue", "eval", "exec", "exit", "export", "readonly", "return", "set", "shift", "times", "trap", "unset" };
    for (sp) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

fn findCmd(a: std.mem.Allocator, name: []const u8, path: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return name;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const cand = std.fmt.allocPrint(a, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name }) catch return null;
        const st = u.stat(cand, true) orelse continue;
        if (st.mode & linux.S.IFMT == linux.S.IFREG and u.ok(linux.access(u.zstr(cand), 1))) return cand;
    }
    return null;
}

fn appletFn(name: []const u8) ?*const fn ([]const []const u8) u8 {
    return @import("main.zig").findApplet(name);
}

/// exec an external command (never returns on success); returns exit status on failure
fn execExternal(a: std.mem.Allocator, argv: []const []const u8, assigns: []const []const u8) u8 {
    var path: []const u8 = getVar("PATH") orelse "/bin:/usr/bin";
    for (assigns) |as| if (std.mem.startsWith(u8, as, "PATH=")) {
        path = as[5..];
    };
    const name = argv[0];
    var resolved = findCmd(a, name, path);
    var use_applet = false;
    if (resolved == null) {
        if (std.mem.indexOfScalar(u8, name, '/') == null and appletFn(name) != null) {
            use_applet = true;
            resolved = std.mem.span(@as([*:0]const u8, @ptrCast(u.selfExe().ptr)));
        } else {
            u.errf("sh: {s}: not found\n", .{name});
            return 127;
        }
    }
    var argv_z = u.Vec([:0]const u8).init(a);
    for (argv) |x| argv_z.push(u.zstr(x));
    const envp = u.envp(assigns);
    const exe = u.zstr(resolved.?);
    const rc = linux.execve(exe.ptr, u.argvp(argv_z.items), envp);
    const en = u.errno(rc);
    if (en == .NOEXEC and !use_applet) {
        // script without a shebang: run it with this shell
        var sv = u.Vec([:0]const u8).init(a);
        sv.push(u.zstr("sh"));
        sv.push(exe);
        for (argv[1..]) |x| sv.push(u.zstr(x));
        _ = linux.execve(u.selfExe().ptr, u.argvp(sv.items), envp);
    }
    if (en == .NOENT) {
        u.errf("sh: {s}: not found\n", .{name});
        return 127;
    }
    u.errf("sh: {s}: {s}\n", .{ name, u.strerr(en) });
    return 126;
}

fn xtrace(argv: []const []const u8) void {
    if (!opt_x) return;
    var o = u.Vec(u8).init(A);
    const ps4 = getVar("PS4") orelse "+ ";
    for (ps4) |ch| o.push(ch);
    for (argv, 0..) |x, i| {
        if (i > 0) o.push(' ');
        for (x) |ch| o.push(ch);
    }
    o.push('\n');
    u.err(o.items);
}

const LocalSave = struct { name: []const u8, old: ?Var };
var locals = u.Vec(LocalSave).init(A);

fn callFunction(body: *Node, argv: []const []const u8) u8 {
    if (func_depth > 1000) {
        u.err("sh: function nesting too deep\n");
        return 1;
    }
    const saved_args = pos_args;
    var np = u.Vec([]const u8).init(A);
    for (argv[1..]) |x| np.push(A.dupe(u8, x) catch x);
    pos_args = np;
    func_depth += 1;
    const base = locals.items.len;
    const st = execNode(body);
    var rs = st;
    if (flow == .return_) {
        rs = @intCast(flow_n & 0xff);
        flow = .none;
    }
    func_depth -= 1;
    // restore locals
    while (locals.items.len > base) {
        const l = locals.items[locals.items.len - 1];
        locals.pop();
        if (l.old) |o| {
            vars.put(A, l.name, o) catch {};
            if (o.exported) u.setEnv(l.name, o.val);
        } else {
            _ = vars.remove(l.name);
            u.unsetVar(l.name);
        }
    }
    pos_args = saved_args;
    return rs;
}

fn execSimple(n: *Node, in_place: bool) u8 {
    cur_line = n.line;
    cmdsub_status = 0;
    var arena = std.heap.ArenaAllocator.init(A);
    defer arena.deinit();
    const a = arena.allocator();

    const argv = expandWords(a, n.words) catch return if (last_status == 0) 1 else last_status;

    // assignments
    var assign_strs = u.Vec([]const u8).init(a);
    for (n.assigns) |as| {
        const v = expandOne(a, as.value, true) catch return if (last_status == 0) 1 else last_status;
        assign_strs.push(std.fmt.allocPrint(a, "{s}={s}", .{ as.name, v }) catch return 1);
    }

    if (argv.len == 0) {
        var st: u8 = cmdsub_status;
        for (n.assigns, 0..) |as, i| {
            const eq = assign_strs.items[i];
            if (!setVar(as.name, eq[as.name.len + 1 ..])) {
                st = 1;
                if (!interactive) {
                    flow = .exit_;
                    flow_n = fatalCode();
                }
            }
        }
        if (n.redirs.len > 0) {
            var saves = u.Vec(Saved).init(A);
            if (!applyRedirs(a, n.redirs, &saves)) st = 1;
            restoreFds(&saves);
        }
        errCheck(st);
        return st;
    }

    xtrace(argv);
    const name = argv[0];

    const func = funcs.get(name);
    const builtin = func == null and isBuiltin(name);
    const inproc = func == null and !builtin and isInproc(name);

    if (func != null or builtin or inproc) {
        var saves = u.Vec(Saved).init(A);
        const permanent_exec = builtin and std.mem.eql(u8, name, "exec") and argv.len == 1;
        if (!applyRedirs(a, n.redirs, if (permanent_exec) null else &saves)) {
            restoreFds(&saves);
            last_status = 1;
            errCheck(1);
            return 1;
        }
        // temporary assignments (persistent for special builtins)
        var olds = u.Vec(struct { name: []const u8, old: ?Var }).init(a);
        const persist = builtin and isSpecial(name);
        for (n.assigns, 0..) |as, i| {
            const eq = assign_strs.items[i];
            if (!persist) olds.push(.{ .name = as.name, .old = copyVar(vars.get(as.name)) });
            _ = setVar(as.name, eq[as.name.len + 1 ..]);
            if (!persist) {
                if (vars.getPtr(as.name)) |p| {
                    p.exported = true;
                    u.setEnv(as.name, p.val);
                }
            }
        }
        var st: u8 = 0;
        if (func) |body| {
            st = callFunction(body, argv);
        } else if (builtin) {
            st = runBuiltin(a, argv);
        } else {
            st = appletFn(name).?(argv[1..]);
        }
        for (olds.items) |o| {
            if (o.old) |ov| {
                vars.put(A, o.name, ov) catch {};
                if (ov.exported) u.setEnv(o.name, ov.val) else u.setVar(o.name, ov.val);
            } else {
                _ = vars.remove(o.name);
                u.unsetVar(o.name);
            }
        }
        if (saves.items.len > 0) restoreFds(&saves);
        checkTraps();
        errCheck(st);
        return st;
    }

    // external command
    if (in_place) {
        if (!applyRedirs(a, n.redirs, null)) linux.exit_group(1);
        childRestoreSignals();
        const code = execExternal(a, argv, assign_strs.items);
        linux.exit_group(code);
    }
    const pid_raw = linux.fork();
    if (u.errno(pid_raw) != .SUCCESS) {
        u.err("sh: fork failed\n");
        return 1;
    }
    if (pid_raw == 0) {
        childInit();
        if (!applyRedirs(a, n.redirs, null)) linux.exit_group(1);
        childRestoreSignals();
        const code = execExternal(a, argv, assign_strs.items);
        linux.exit_group(code);
    }
    const st = waitFor(@intCast(pid_raw));
    checkTraps();
    errCheck(st);
    return st;
}

fn childRestoreSignals() void {
    // caught signals go back to default in exec'd programs; ignored stay ignored
    var sig: usize = 1;
    while (sig < 64) : (sig += 1) {
        if (sig == 9 or sig == 19) continue;
        if (trap_cmd[sig] != null) setSignal(sig, .dfl);
    }
    if (interactive) {
        setSignal(2, .dfl);
        setSignal(3, .dfl);
        setSignal(15, .dfl);
    }
}

// ===================== builtins =====================
fn parseInt(s: []const u8) ?i64 {
    return std.fmt.parseInt(i64, s, 10) catch null;
}

fn quoteSingle(a: std.mem.Allocator, s: []const u8) []const u8 {
    var o = u.Vec(u8).init(a);
    o.push('\'');
    for (s) |ch| {
        if (ch == '\'') {
            for ("'\\''") |x| o.push(x);
        } else o.push(ch);
    }
    o.push('\'');
    return o.items;
}

fn builtinErr(comptime name: []const u8, comptime fmt: []const u8, args: anytype, status: u8) u8 {
    u.errf("sh: " ++ name ++ ": " ++ fmt ++ "\n", args);
    return status;
}

fn sigByName(s: []const u8) ?usize {
    if (std.mem.eql(u8, s, "EXIT") or std.mem.eql(u8, s, "0")) return 0;
    if (std.mem.eql(u8, s, "ERR")) return 65;
    return if (@import("kill.zig").sigNum(s)) |n| n else null;
}

fn runBuiltin(a: std.mem.Allocator, argv: []const []const u8) u8 {
    const name = argv[0];
    const args = argv[1..];
    const eq = std.mem.eql;
    if (eq(u8, name, ":")) return 0;
    if (eq(u8, name, "exit")) {
        var code: u8 = last_status;
        if (args.len > 0) {
            const v = parseInt(args[0]) orelse {
                u.errf("sh: exit: Illegal number: {s}\n", .{args[0]});
                flow = .exit_;
                flow_n = 2;
                return 2;
            };
            code = @intCast(v & 0xff);
        }
        flow = .exit_;
        flow_n = code;
        return code;
    }
    if (eq(u8, name, "return")) {
        var code: u8 = last_status;
        if (args.len > 0) code = @intCast((parseInt(args[0]) orelse 0) & 0xff);
        flow = .return_;
        flow_n = code;
        return code;
    }
    if (eq(u8, name, "break") or eq(u8, name, "continue")) {
        var n: u32 = 1;
        if (args.len > 0) {
            const v = parseInt(args[0]) orelse return builtinErr("break", "Illegal number: {s}", .{args[0]}, 2);
            if (v < 1) return builtinErr("break", "Illegal number: {s}", .{args[0]}, 1);
            n = @intCast(v);
        }
        if (loop_depth == 0) return 0;
        flow = if (name[0] == 'b') .break_ else .continue_;
        flow_n = @min(n, loop_depth);
        return 0;
    }
    if (eq(u8, name, "eval")) {
        if (args.len == 0) return 0;
        var o = u.Vec(u8).init(a);
        for (args, 0..) |x, i| {
            if (i > 0) o.push(' ');
            for (x) |ch| o.push(ch);
        }
        return evalString(o.items);
    }
    if (eq(u8, name, ".") or eq(u8, name, "source")) {
        if (args.len == 0) return builtinErr(".", "filename argument required", .{}, 2);
        var path: []const u8 = args[0];
        if (std.mem.indexOfScalar(u8, path, '/') == null) {
            if (findCmdAny(a, path, getVar("PATH") orelse "/bin:/usr/bin")) |p| path = p;
        }
        const text = readWhole(path) orelse return builtinErr(".", "{s}: No such file or directory", .{path}, 1);
        const saved = pos_args;
        if (args.len > 1) {
            var np = u.Vec([]const u8).init(A);
            for (args[1..]) |x| np.push(A.dupe(u8, x) catch x);
            pos_args = np;
        }
        const st = runText(text, null);
        if (args.len > 1) pos_args = saved;
        var rs = st;
        if (flow == .return_) {
            rs = @intCast(flow_n & 0xff);
            flow = .none;
        }
        return rs;
    }
    if (eq(u8, name, "exec")) {
        if (args.len == 0) return 0;
        childRestoreSignals();
        const code = execExternal(a, args, &.{});
        if (!interactive) {
            flow = .exit_;
            flow_n = code;
        }
        return code;
    }
    if (eq(u8, name, "export") or eq(u8, name, "readonly")) return builtinExport(a, name[0] == 'r', args);
    if (eq(u8, name, "set")) return builtinSet(a, args);
    if (eq(u8, name, "shift")) {
        var n: usize = 1;
        if (args.len > 0) n = @intCast(@max(parseInt(args[0]) orelse return builtinErr("shift", "Illegal number: {s}", .{args[0]}, 2), 0));
        if (n > pos_args.items.len) return builtinErr("shift", "can't shift that many", .{}, 1);
        var np = u.Vec([]const u8).init(A);
        for (pos_args.items[n..]) |x| np.push(x);
        pos_args = np;
        return 0;
    }
    if (eq(u8, name, "times")) {
        u.out("0m0.000s 0m0.000s\n0m0.000s 0m0.000s\n");
        return 0;
    }
    if (eq(u8, name, "trap")) return builtinTrap(a, args);
    if (eq(u8, name, "unset")) {
        var funcs_mode = false;
        var st: u8 = 0;
        for (args) |x| {
            if (eq(u8, x, "-f")) {
                funcs_mode = true;
                continue;
            }
            if (eq(u8, x, "-v")) {
                funcs_mode = false;
                continue;
            }
            if (funcs_mode) _ = funcs.remove(x) else if (!unsetVar(x)) st = 1;
        }
        return st;
    }
    if (eq(u8, name, "alias")) {
        if (args.len == 0) {
            var it = aliases.iterator();
            var names = u.Vec([]const u8).init(a);
            while (it.next()) |en| names.push(en.key_ptr.*);
            std.mem.sort([]const u8, names.items, {}, struct {
                fn lt(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.lt);
            for (names.items) |k| u.outf("alias {s}={s}\n", .{ k, quoteSingle(a, aliases.get(k).?) });
            return 0;
        }
        var st: u8 = 0;
        for (args) |x| {
            if (std.mem.indexOfScalar(u8, x, '=')) |e| {
                aliases.put(A, A.dupe(u8, x[0..e]) catch continue, A.dupe(u8, x[e + 1 ..]) catch continue) catch {};
            } else if (aliases.get(x)) |v| {
                u.outf("alias {s}={s}\n", .{ x, quoteSingle(a, v) });
            } else {
                u.errf("sh: alias: {s}: not found\n", .{x});
                st = 1;
            }
        }
        return st;
    }
    if (eq(u8, name, "unalias")) {
        var st: u8 = 0;
        for (args) |x| {
            if (eq(u8, x, "-a")) {
                aliases = .{};
                continue;
            }
            if (!aliases.remove(x)) {
                u.errf("sh: unalias: {s}: not found\n", .{x});
                st = 1;
            }
        }
        return st;
    }
    if (eq(u8, name, "cd")) return builtinCd(a, args);
    if (eq(u8, name, "read")) return builtinRead(a, args);
    if (eq(u8, name, "command")) return builtinCommand(a, args);
    if (eq(u8, name, "type")) {
        var st: u8 = 0;
        for (args) |x| {
            if (!describeCmd(a, x, true)) st = 1;
        }
        return st;
    }
    if (eq(u8, name, "hash")) return 0;
    if (eq(u8, name, "wait")) return builtinWait(args);
    if (eq(u8, name, "umask")) return builtinUmask(args);
    if (eq(u8, name, "getopts")) return builtinGetopts(a, args);
    if (eq(u8, name, "local")) {
        if (func_depth == 0) return builtinErr("local", "not in a function", .{}, 1);
        for (args) |x| {
            const e = std.mem.indexOfScalar(u8, x, '=');
            const nm = if (e) |i| x[0..i] else x;
            if (!validName(nm)) return builtinErr("local", "{s}: bad variable name", .{x}, 1);
            locals.push(.{ .name = A.dupe(u8, nm) catch nm, .old = copyVar(vars.get(nm)) });
            if (e) |i| _ = setVar(nm, x[i + 1 ..]) else {
                _ = vars.remove(nm);
                u.unsetVar(nm);
            }
        }
        return 0;
    }
    if (eq(u8, name, "ulimit")) return builtinUlimit(args);
    if (eq(u8, name, "jobs")) return 0;
    if (eq(u8, name, "fg") or eq(u8, name, "bg")) return builtinErr("fg", "no job control", .{}, 1);
    if (eq(u8, name, "let")) {
        var v: i64 = 0;
        for (args) |x| v = evalArith(a, x) catch return 1;
        return if (v == 0) 1 else 0;
    }
    return 127;
}

fn readWhole(path: []const u8) ?[]const u8 {
    var f = u.File.open(path, .{ .ACCMODE = .RDONLY }, 0) orelse return null;
    defer f.close();
    var all = u.Vec(u8).init(A);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = f.read(&buf);
        if (n == 0) break;
        for (buf[0..n]) |b| all.push(b);
    }
    return all.items;
}

fn findCmdAny(a: std.mem.Allocator, name: []const u8, path: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const cand = std.fmt.allocPrint(a, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name }) catch return null;
        const st = u.stat(cand, true) orelse continue;
        if (st.mode & linux.S.IFMT == linux.S.IFREG) return cand;
    }
    return null;
}

fn builtinExport(a: std.mem.Allocator, readonly: bool, args: []const []const u8) u8 {
    var print = false;
    var any = false;
    var st: u8 = 0;
    for (args) |x| {
        if (std.mem.eql(u8, x, "-p")) {
            print = true;
            continue;
        }
        if (x.len > 0 and x[0] == '-' and x.len > 1) continue;
        any = true;
        const e = std.mem.indexOfScalar(u8, x, '=');
        const nm = if (e) |i| x[0..i] else x;
        if (!validName(nm)) {
            u.errf("sh: {s}: {s}: bad variable name\n", .{ if (readonly) "readonly" else "export", x });
            st = 1;
            continue;
        }
        if (readonly) {
            if (e) |i| if (!setVar(nm, x[i + 1 ..])) {
                st = 1;
                continue;
            };
            if (vars.getPtr(nm)) |p| p.readonly = true else {
                vars.put(A, A.dupe(u8, nm) catch continue, .{ .val = "", .readonly = true }) catch {};
            }
        } else {
            if (!markExport(nm, if (e) |i| x[i + 1 ..] else null)) st = 1;
        }
    }
    if (!any or print) {
        var names = u.Vec([]const u8).init(a);
        var it = vars.iterator();
        while (it.next()) |en| {
            if (readonly and en.value_ptr.readonly or !readonly and en.value_ptr.exported) names.push(en.key_ptr.*);
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (names.items) |k| u.outf("{s} {s}={s}\n", .{ if (readonly) "readonly" else "export", k, quoteSingle(a, vars.get(k).?.val) });
    }
    return st;
}

fn setOpt(ch: u8, on: bool) bool {
    switch (ch) {
        'e' => opt_e = on,
        'u' => opt_u = on,
        'f' => opt_f = on,
        'x' => opt_x = on,
        'v' => opt_v = on,
        'n' => opt_n = on,
        'C' => opt_C = on,
        'a' => opt_a = on,
        'm', 'b', 'h', 'i', 'l', 's', 'B', 'H', 'P', 'T', 'E', 'p', 'k', 't' => {},
        else => return false,
    }
    return true;
}

fn setNamedOpt(name: []const u8, on: bool) bool {
    const map = [_]struct { n: []const u8, c: u8 }{
        .{ .n = "errexit", .c = 'e' }, .{ .n = "nounset", .c = 'u' }, .{ .n = "noglob", .c = 'f' }, .{ .n = "xtrace", .c = 'x' },
        .{ .n = "verbose", .c = 'v' }, .{ .n = "noexec", .c = 'n' }, .{ .n = "noclobber", .c = 'C' }, .{ .n = "allexport", .c = 'a' },
    };
    if (std.mem.eql(u8, name, "pipefail")) {
        opt_pipefail = on;
        return true;
    }
    for (map) |m| if (std.mem.eql(u8, m.n, name)) return setOpt(m.c, on);
    const ign = [_][]const u8{ "monitor", "notify", "ignoreeof", "vi", "emacs", "posix", "nolog", "physical", "hashall", "braceexpand" };
    for (ign) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

fn builtinSet(a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len == 0) {
        var names = u.Vec([]const u8).init(a);
        var it = vars.iterator();
        while (it.next()) |en| names.push(en.key_ptr.*);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (names.items) |k| u.outf("{s}={s}\n", .{ k, quoteSingle(a, vars.get(k).?.val) });
        return 0;
    }
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        if (std.mem.eql(u8, x, "--")) {
            i += 1;
            break;
        }
        if (x.len < 2 or (x[0] != '-' and x[0] != '+')) break;
        const on = x[0] == '-';
        if (x.len == 2 and x[1] == 'o') {
            if (i + 1 >= args.len) {
                const lst = [_]struct { n: []const u8, v: bool }{
                    .{ .n = "allexport", .v = opt_a },  .{ .n = "errexit", .v = opt_e },   .{ .n = "noclobber", .v = opt_C },
                    .{ .n = "noexec", .v = opt_n },     .{ .n = "noglob", .v = opt_f },    .{ .n = "nounset", .v = opt_u },
                    .{ .n = "pipefail", .v = opt_pipefail }, .{ .n = "verbose", .v = opt_v }, .{ .n = "xtrace", .v = opt_x },
                };
                for (lst) |l| u.outf("{s: <15}{s}\n", .{ l.n, if (l.v) "on" else "off" });
                return 0;
            }
            i += 1;
            if (!setNamedOpt(args[i], on)) return builtinErr("set", "Illegal option -o {s}", .{args[i]}, 2);
            continue;
        }
        for (x[1..]) |ch| if (!setOpt(ch, on)) return builtinErr("set", "Illegal option {c}{c}", .{ x[0], ch }, 2);
    }
    if (i <= args.len and (i > 0 and std.mem.eql(u8, args[i - 1], "--") or i < args.len)) {
        var np = u.Vec([]const u8).init(A);
        for (args[i..]) |x| np.push(A.dupe(u8, x) catch x);
        pos_args = np;
    }
    return 0;
}

fn builtinTrap(a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len == 0 or (args.len == 1 and std.mem.eql(u8, args[0], "-p"))) {
        var sig: usize = 0;
        const use_parent = in_subshell and !trap_touched;
        while (sig <= 65) : (sig += 1) {
            const cmd: ?[]const u8 = if (sig == 0) (if (use_parent) parent_exit else trap_exit) else if (sig == 65) (if (use_parent) parent_err else trap_err) else (if (use_parent) parent_trap_cmd[sig] else trap_cmd[sig]);
            const ign = sig > 0 and sig < 65 and (if (use_parent) parent_trap_ign[sig] else trap_ign[sig]);
            if (cmd == null and !ign) continue;
            var nb: [16]u8 = undefined;
            const nm: []const u8 = if (sig == 0) "EXIT" else if (sig == 65) "ERR" else (if (sig < @import("util.zig").signals.len) u.signals[sig] else std.fmt.bufPrint(&nb, "{d}", .{sig}) catch "?");
            u.outf("trap -- {s} {s}\n", .{ quoteSingle(a, cmd orelse ""), nm });
        }
        return 0;
    }
    var i: usize = 0;
    var cmd: ?[]const u8 = args[0];
    // `trap SIG...` / `trap - SIG...` reset
    if (sigByName(args[0]) != null and args.len == 1 or std.mem.eql(u8, args[0], "-")) {
        cmd = null;
        i = if (std.mem.eql(u8, args[0], "-")) 1 else 0;
    } else {
        i = 1;
    }
    if (i >= args.len) return 0;
    var st: u8 = 0;
    trap_touched = true;
    for (args[i..]) |s| {
        const sig = sigByName(s) orelse {
            u.errf("sh: trap: {s}: bad trap\n", .{s});
            st = 1;
            continue;
        };
        const stored: ?[]const u8 = if (cmd) |c0| (A.dupe(u8, c0) catch c0) else null;
        if (sig == 0) {
            trap_exit = if (stored != null and stored.?.len == 0) null else stored;
        } else if (sig == 65) {
            trap_err = if (stored != null and stored.?.len == 0) null else stored;
        } else {
            if (sig == 9 or sig == 19) {
                u.errf("sh: trap: {s}: cannot trap\n", .{s});
                st = 1;
                continue;
            }
            if (stored) |c1| {
                if (c1.len == 0) {
                    trap_cmd[sig] = null;
                    trap_ign[sig] = true;
                    setSignal(sig, .ign);
                } else {
                    trap_cmd[sig] = c1;
                    trap_ign[sig] = false;
                    setSignal(sig, .catch_);
                }
            } else {
                trap_cmd[sig] = null;
                trap_ign[sig] = false;
                setSignal(sig, if (interactive and (sig == 2 or sig == 3 or sig == 15)) .ign else .dfl);
            }
        }
    }
    return st;
}

fn normalizePath(a: std.mem.Allocator, path: []const u8) []const u8 {
    var parts = u.Vec([]const u8).init(a);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.items.len > 0) parts.pop();
            continue;
        }
        parts.push(p);
    }
    var o = u.Vec(u8).init(a);
    for (parts.items) |p| {
        o.push('/');
        for (p) |ch| o.push(ch);
    }
    if (o.items.len == 0) o.push('/');
    return o.items;
}

fn builtinCd(a: std.mem.Allocator, args: []const []const u8) u8 {
    var physical = false;
    var i: usize = 0;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-' and !std.mem.eql(u8, args[i], "-")) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        for (args[i][1..]) |ch| {
            if (ch == 'P') physical = true else if (ch == 'L') physical = false else return builtinErr("cd", "Illegal option -{c}", .{ch}, 2);
        }
    }
    var dir: []const u8 = undefined;
    var print = false;
    if (i >= args.len) {
        dir = getVar("HOME") orelse return builtinErr("cd", "HOME not set", .{}, 1);
    } else if (std.mem.eql(u8, args[i], "-")) {
        dir = getVar("OLDPWD") orelse return builtinErr("cd", "OLDPWD not set", .{}, 1);
        print = true;
    } else dir = args[i];
    if (dir.len == 0) return 0;
    var target = dir;
    if (dir[0] != '/' and !std.mem.startsWith(u8, dir, "./") and !std.mem.startsWith(u8, dir, "../") and !std.mem.eql(u8, dir, ".") and !std.mem.eql(u8, dir, "..")) {
        if (getVar("CDPATH")) |cp| {
            var it = std.mem.splitScalar(u8, cp, ':');
            while (it.next()) |d| {
                const cand = if (d.len == 0) dir else std.fmt.allocPrint(a, "{s}/{s}", .{ d, dir }) catch continue;
                if (u.isDir(cand)) {
                    target = cand;
                    if (d.len > 0) print = true;
                    break;
                }
            }
        }
    }
    const old = getVar("PWD") orelse "";
    var logical: []const u8 = target;
    if (target[0] != '/') logical = std.fmt.allocPrint(a, "{s}/{s}", .{ old, target }) catch target;
    const rc = linux.chdir(u.zstr(if (physical) target else target));
    if (!u.ok(rc)) {
        u.errf("sh: cd: {s}: {s}\n", .{ dir, u.strerr(u.errno(rc)) });
        return 1;
    }
    var newpwd: []const u8 = undefined;
    if (physical) {
        var buf: [u.PATH_MAX]u8 = undefined;
        const g = linux.getcwd(&buf, buf.len);
        newpwd = if (u.ok(g)) a.dupe(u8, std.mem.sliceTo(&buf, 0)) catch logical else logical;
    } else newpwd = normalizePath(a, logical);
    _ = setVar("OLDPWD", old);
    if (vars.getPtr("OLDPWD")) |p| {
        p.exported = true;
        u.setEnv("OLDPWD", p.val);
    }
    _ = setVar("PWD", newpwd);
    if (vars.getPtr("PWD")) |p| {
        p.exported = true;
        u.setEnv("PWD", p.val);
    }
    if (print) u.outf("{s}\n", .{newpwd});
    return 0;
}

fn readByte(fd: i32) ?u8 {
    var b: [1]u8 = undefined;
    while (true) {
        const r = linux.read(fd, &b, 1);
        if (u.errno(r) == .INTR) {
            checkTraps();
            continue;
        }
        if (!u.ok(r) or r == 0) return null;
        return b[0];
    }
}

fn builtinRead(a: std.mem.Allocator, args: []const []const u8) u8 {
    var raw = false;
    var prompt: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        var k: usize = 1;
        while (k < args[i].len) : (k += 1) {
            switch (args[i][k]) {
                'r' => raw = true,
                'p' => {
                    if (k + 1 < args[i].len) {
                        prompt = args[i][k + 1 ..];
                        k = args[i].len;
                    } else if (i + 1 < args.len) {
                        i += 1;
                        prompt = args[i];
                        k = args[i].len;
                    }
                },
                else => {},
            }
        }
    }
    if (prompt) |p| if (interactive or true) u.err(p);
    var vnames = u.Vec([]const u8).init(a);
    for (args[i..]) |x| vnames.push(x);
    if (vnames.items.len == 0) vnames.push("REPLY");
    var line = u.Vec(u8).init(a);
    var eof = false;
    var escaped_mask = u.Vec(bool).init(a);
    while (true) {
        const b = readByte(0) orelse {
            eof = true;
            break;
        };
        if (b == '\n') break;
        if (b == '\\' and !raw) {
            const n = readByte(0) orelse {
                eof = true;
                break;
            };
            if (n == '\n') continue;
            line.push(n);
            escaped_mask.push(true);
            continue;
        }
        line.push(b);
        escaped_mask.push(false);
    }
    const ifs = ifsValue();
    const text = line.items;
    var pos: usize = 0;
    const isIfs = struct {
        fn f(ifs_: []const u8, ch: u8) bool {
            return std.mem.indexOfScalar(u8, ifs_, ch) != null;
        }
    }.f;
    const isWs = struct {
        fn f(ch: u8) bool {
            return ch == ' ' or ch == '\t' or ch == '\n';
        }
    }.f;
    for (vnames.items, 0..) |vn, vi| {
        // skip leading IFS whitespace
        while (pos < text.len and isIfs(ifs, text[pos]) and isWs(text[pos]) and !escaped_mask.items[pos]) pos += 1;
        if (vi == vnames.items.len - 1) {
            var end = text.len;
            while (end > pos and isIfs(ifs, text[end - 1]) and isWs(text[end - 1]) and !escaped_mask.items[end - 1]) end -= 1;
            _ = setVar(vn, text[pos..end]);
            pos = text.len;
        } else {
            var end = pos;
            while (end < text.len and !(isIfs(ifs, text[end]) and !escaped_mask.items[end])) end += 1;
            _ = setVar(vn, text[pos..end]);
            pos = end;
            // consume the delimiter (and adjacent IFS whitespace)
            while (pos < text.len and isIfs(ifs, text[pos]) and isWs(text[pos]) and !escaped_mask.items[pos]) pos += 1;
            if (pos < text.len and isIfs(ifs, text[pos]) and !isWs(text[pos]) and !escaped_mask.items[pos]) {
                pos += 1;
                while (pos < text.len and isIfs(ifs, text[pos]) and isWs(text[pos]) and !escaped_mask.items[pos]) pos += 1;
            }
        }
    }
    return if (eof) 1 else 0;
}

fn describeCmd(a: std.mem.Allocator, name: []const u8, verbose: bool) bool {
    if (aliases.get(name)) |v| {
        if (verbose) u.outf("{s} is aliased to `{s}'\n", .{ name, v }) else u.outf("alias {s}={s}\n", .{ name, quoteSingle(a, v) });
        return true;
    }
    if (funcs.get(name) != null) {
        if (verbose) u.outf("{s} is a function\n", .{name}) else u.outf("{s}\n", .{name});
        return true;
    }
    if (isBuiltin(name) or isInproc(name)) {
        if (verbose) u.outf("{s} is a shell builtin\n", .{name}) else u.outf("{s}\n", .{name});
        return true;
    }
    if (findCmd(a, name, getVar("PATH") orelse "/bin:/usr/bin")) |p| {
        if (std.mem.indexOfScalar(u8, name, '/') != null and u.stat(p, true) == null) {
            if (verbose) u.errf("sh: type: {s}: not found\n", .{name});
            return false;
        }
        if (verbose) u.outf("{s} is {s}\n", .{ name, p }) else u.outf("{s}\n", .{p});
        return true;
    }
    if (appletFn(name) != null) {
        if (verbose) u.outf("{s} is a shell builtin\n", .{name}) else u.outf("{s}\n", .{name});
        return true;
    }
    if (verbose) u.errf("sh: type: {s}: not found\n", .{name});
    return false;
}

fn builtinCommand(a: std.mem.Allocator, args: []const []const u8) u8 {
    var mode: u8 = 0; // 'v' or 'V'
    var i: usize = 0;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        for (args[i][1..]) |ch| {
            if (ch == 'v' or ch == 'V') mode = ch;
        }
    }
    if (i >= args.len) return 0;
    if (mode != 0) {
        var st: u8 = 0;
        for (args[i..]) |x| if (!describeCmd(a, x, mode == 'V')) {
            st = 1;
        };
        return st;
    }
    const argv = args[i..];
    const name = argv[0];
    if (isBuiltin(name)) return runBuiltin(a, argv);
    if (isInproc(name)) return appletFn(name).?(argv[1..]);
    const pid_raw = linux.fork();
    if (u.errno(pid_raw) != .SUCCESS) return 1;
    if (pid_raw == 0) {
        childInit();
        childRestoreSignals();
        linux.exit_group(execExternal(a, argv, &.{}));
    }
    return waitFor(@intCast(pid_raw));
}

fn builtinWait(args: []const []const u8) u8 {
    if (args.len == 0) {
        var st: u8 = 0;
        while (jobs.items.len > 0) {
            const pid = jobs.items[0].pid;
            st = waitFor(pid);
        }
        return 0;
    }
    var st: u8 = 0;
    for (args) |x| {
        const pid = parseInt(x) orelse return builtinErr("wait", "{s}: invalid pid", .{x}, 2);
        var known = false;
        for (jobs.items) |j| if (j.pid == pid) {
            known = true;
        };
        if (!known) {
            st = 127;
            continue;
        }
        st = waitFor(@intCast(pid));
    }
    return st;
}

fn builtinUmask(args: []const []const u8) u8 {
    var symbolic = false;
    var i: usize = 0;
    if (i < args.len and std.mem.eql(u8, args[i], "-S")) {
        symbolic = true;
        i += 1;
    }
    const cur = u.umask(0);
    _ = u.umask(cur);
    if (i >= args.len) {
        if (symbolic) {
            const perms = 0o777 & ~cur;
            var o: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&o, "u={s}{s}{s},g={s}{s}{s},o={s}{s}{s}\n", .{
                if (perms & 0o400 != 0) "r" else "", if (perms & 0o200 != 0) "w" else "", if (perms & 0o100 != 0) "x" else "",
                if (perms & 0o040 != 0) "r" else "", if (perms & 0o020 != 0) "w" else "", if (perms & 0o010 != 0) "x" else "",
                if (perms & 0o004 != 0) "r" else "", if (perms & 0o002 != 0) "w" else "", if (perms & 0o001 != 0) "x" else "",
            }) catch return 1;
            u.out(s);
        } else u.outf("{o:0>4}\n", .{cur});
        return 0;
    }
    if (std.fmt.parseInt(u32, args[i], 8)) |m| {
        _ = u.umask(m & 0o777);
        return 0;
    } else |_| {}
    const perms = 0o777 & ~cur;
    const np = @import("mode.zig").apply(args[i], perms, false, 0) orelse return builtinErr("umask", "Illegal mode: {s}", .{args[i]}, 1);
    _ = u.umask(0o777 & ~np);
    return 0;
}

var last_optind: i64 = 1;

fn builtinGetopts(a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len < 2) return builtinErr("getopts", "usage: getopts optstring name [arg ...]", .{}, 2);
    const optstring = args[0];
    const vname = args[1];
    const list: []const []const u8 = if (args.len > 2) args[2..] else pos_args.items;
    var optind: i64 = parseInt(getVar("OPTIND") orelse "1") orelse 1;
    if (optind != last_optind) optind_pos = 0;
    const silent = optstring.len > 0 and optstring[0] == ':';
    const fin = struct {
        fn done(vn: []const u8, ind: i64) u8 {
            _ = setVar(vn, "?");
            _ = setVar("OPTIND", std.fmt.allocPrint(A, "{d}", .{ind}) catch "1");
            last_optind = ind;
            return 1;
        }
    }.done;
    if (optind < 1 or optind > list.len) return fin(vname, optind);
    const arg = list[@intCast(optind - 1)];
    if (optind_pos == 0) {
        if (std.mem.eql(u8, arg, "--")) return fin(vname, optind + 1);
        if (arg.len < 2 or arg[0] != '-') return fin(vname, optind);
        optind_pos = 1;
    }
    const ch = arg[optind_pos];
    const at = std.mem.indexOfScalar(u8, optstring, ch);
    const valid = at != null and ch != ':';
    var advance = true;
    optind_pos += 1;
    const finish_arg = optind_pos >= arg.len;
    if (!valid) {
        if (silent) _ = setVar("OPTARG", &[_]u8{ch}) else {
            _ = unsetVar("OPTARG");
            u.errf("sh: Illegal option -{c}\n", .{ch});
        }
        _ = setVar(vname, "?");
    } else if (at.? + 1 < optstring.len and optstring[at.? + 1] == ':') {
        if (!finish_arg) {
            _ = setVar("OPTARG", arg[optind_pos..]);
            optind += 1;
            optind_pos = 0;
            advance = false;
        } else if (optind < list.len) {
            _ = setVar("OPTARG", list[@intCast(optind)]);
            optind += 2;
            optind_pos = 0;
            advance = false;
        } else {
            optind += 1;
            optind_pos = 0;
            advance = false;
            if (silent) {
                _ = setVar("OPTARG", &[_]u8{ch});
                _ = setVar(vname, ":");
            } else {
                _ = unsetVar("OPTARG");
                u.errf("sh: Missing argument for -{c}\n", .{ch});
                _ = setVar(vname, "?");
            }
            _ = setVar("OPTIND", fmtU(a, optind));
            last_optind = optind;
            return 0;
        }
        _ = setVar(vname, &[_]u8{ch});
    } else {
        _ = unsetVar("OPTARG");
        _ = setVar(vname, &[_]u8{ch});
    }
    if (advance and finish_arg) {
        optind += 1;
        optind_pos = 0;
    }
    _ = setVar("OPTIND", fmtU(a, optind));
    last_optind = optind;
    return 0;
}

fn builtinUlimit(args: []const []const u8) u8 {
    var resource: c_int = c.RLIMIT_FSIZE;
    var scale: u64 = 1024;
    var hard = false;
    var all = false;
    var value: ?[]const u8 = null;
    for (args) |x| {
        if (x.len > 1 and x[0] == '-') {
            for (x[1..]) |ch| switch (ch) {
                'c' => resource = c.RLIMIT_CORE,
                'd' => resource = c.RLIMIT_DATA,
                'f' => resource = c.RLIMIT_FSIZE,
                'l' => resource = c.RLIMIT_MEMLOCK,
                'm' => resource = c.RLIMIT_RSS,
                'n' => {
                    resource = c.RLIMIT_NOFILE;
                    scale = 1;
                },
                's' => resource = c.RLIMIT_STACK,
                't' => {
                    resource = c.RLIMIT_CPU;
                    scale = 1;
                },
                'u' => {
                    resource = c.RLIMIT_NPROC;
                    scale = 1;
                },
                'v' => resource = c.RLIMIT_AS,
                'H' => hard = true,
                'S' => hard = false,
                'a' => all = true,
                else => return builtinErr("ulimit", "Illegal option {s}", .{x}, 2),
            };
            if (x.len > 1 and std.mem.indexOfAny(u8, x[1..], "nstu") != null) {}
        } else value = x;
    }
    if (all) {
        const items = [_]struct { n: []const u8, r: c_int, s: u64 }{
            .{ .n = "core file size          (blocks, -c)", .r = c.RLIMIT_CORE, .s = 1024 },
            .{ .n = "data seg size           (kbytes, -d)", .r = c.RLIMIT_DATA, .s = 1024 },
            .{ .n = "file size               (blocks, -f)", .r = c.RLIMIT_FSIZE, .s = 1024 },
            .{ .n = "max locked memory       (kbytes, -l)", .r = c.RLIMIT_MEMLOCK, .s = 1024 },
            .{ .n = "open files                      (-n)", .r = c.RLIMIT_NOFILE, .s = 1 },
            .{ .n = "stack size              (kbytes, -s)", .r = c.RLIMIT_STACK, .s = 1024 },
            .{ .n = "cpu time               (seconds, -t)", .r = c.RLIMIT_CPU, .s = 1 },
            .{ .n = "max user processes              (-u)", .r = c.RLIMIT_NPROC, .s = 1 },
            .{ .n = "virtual memory          (kbytes, -v)", .r = c.RLIMIT_AS, .s = 1024 },
        };
        for (items) |it| {
            var rl: c.struct_rlimit = undefined;
            _ = c.getrlimit(@intCast(it.r), &rl);
            const v = if (hard) rl.rlim_max else rl.rlim_cur;
            if (v == c.RLIM_INFINITY) u.outf("{s} unlimited\n", .{it.n}) else u.outf("{s} {d}\n", .{ it.n, v / it.s });
        }
        return 0;
    }
    var rl: c.struct_rlimit = undefined;
    if (c.getrlimit(@intCast(resource), &rl) != 0) return 1;
    if (value) |v| {
        const nv: c.rlim_t = if (std.mem.eql(u8, v, "unlimited")) c.RLIM_INFINITY else (std.fmt.parseInt(c.rlim_t, v, 10) catch return builtinErr("ulimit", "bad number: {s}", .{v}, 2)) * scale;
        if (hard) rl.rlim_max = nv else rl.rlim_cur = nv;
        if (!hard) {} else if (rl.rlim_cur > rl.rlim_max) rl.rlim_cur = rl.rlim_max;
        if (c.setrlimit(@intCast(resource), &rl) != 0) return builtinErr("ulimit", "cannot modify limit: Operation not permitted", .{}, 1);
        return 0;
    }
    const cur = if (hard) rl.rlim_max else rl.rlim_cur;
    if (cur == c.RLIM_INFINITY) u.out("unlimited\n") else u.outf("{d}\n", .{cur / scale});
    return 0;
}

// ===================== script execution =====================
const Feeder = struct {
    /// append the next input line to buf; false at EOF
    fn fill(self: *Feeder, buf: *u.Vec(u8), first: bool) bool {
        _ = self;
        if (interactive) {
            const ps = if (first) (getVar("PS1") orelse (if (c.geteuid() == 0) "# " else "$ ")) else (getVar("PS2") orelse "> ");
            u.err(ps);
        }
        var got = false;
        while (true) {
            const b = readByte(0) orelse break;
            got = true;
            buf.push(b);
            if (b == '\n') break;
        }
        if (got and (buf.items.len == 0 or buf.items[buf.items.len - 1] != '\n')) buf.push('\n');
        return got;
    }
};

fn evalString(text: []const u8) u8 {
    return runText(text, null);
}

fn runText(text0: []const u8, feeder: ?*Feeder) u8 {
    var buf = u.Vec(u8).init(A);
    for (text0) |ch| buf.push(ch);
    var start: usize = 0;
    var st: u8 = last_status;
    var base_line: u32 = 1;
    var fresh = true;
    if (feeder != null and buf.items.len == 0) {
        // nothing buffered yet: the first prompt is shown by fill()
    }
    while (true) {
        if (flow == .exit_ or flow == .return_) break;
        var p = P.Parser.init(buf.items[start..]);
        p.aliases = aliasLookup;
        p.line = base_line;
        const parsed = p.parseComplete() catch |e| {
            if (e == error.Incomplete) {
                if (feeder) |f| {
                    if (f.fill(&buf, false)) continue;
                }
                u.errf("sh: {d}: Syntax error: end of file unexpected\n", .{p.line});
                st = 2;
                last_status = 2;
                if (interactive) break;
                flow = .exit_;
                flow_n = 2;
                return 2;
            }
            u.errf("sh: {d}: {s}\n", .{ p.line, P.err_msg });
            st = 2;
            last_status = 2;
            if (!interactive) {
                flow = .exit_;
                flow_n = 2;
                return 2;
            }
            // interactive: drop the rest of the line and go on
            const eol = std.mem.indexOfScalarPos(u8, buf.items, start, '\n') orelse buf.items.len;
            start = @min(eol + 1, buf.items.len);
            fresh = true;
            continue;
        };
        if (parsed == null) {
            if (feeder) |f| {
                if (f.fill(&buf, fresh)) {
                    fresh = false;
                    continue;
                }
            }
            break;
        }
        if (feeder != null and p.ended_by_eof) {
            // the command ended only because the buffer did; more input may continue it
            if (f2Fill(feeder.?, &buf)) continue;
        }
        fresh = true;
        const consumed: usize = @intCast(@as(isize, @intCast(p.pos)) - p.delta);
        if (opt_v) u.err(buf.items[start .. start + @min(consumed, buf.items.len - start)]);
        start += consumed;
        base_line = p.line;
        if (!opt_n) st = execNode(parsed.?);
        checkTraps();
        reapBg();
        if (flow != .none) break;
        if (feeder != null and start >= buf.items.len) {
            // everything consumed: next command needs a fresh prompt
            buf.items.len = 0;
            start = 0;
            if (!interactive) continue;
            if (!feederPrompt(feeder.?, &buf)) break;
            fresh = false;
        }
    }
    return st;
}

fn f2Fill(f: *Feeder, buf: *u.Vec(u8)) bool {
    // continuation read: no prompt for non-interactive input, PS2 when interactive
    return f.fill(buf, false);
}

fn feederPrompt(f: *Feeder, buf: *u.Vec(u8)) bool {
    return f.fill(buf, true);
}

fn runExitTrap() void {
    if (trap_exit) |cmd| {
        trap_exit = null;
        const saved = last_status;
        const sf = flow;
        const sfn = flow_n;
        flow = .none;
        _ = evalString(cmd);
        flow = sf;
        flow_n = sfn;
        last_status = saved;
    }
}

fn initShell() void {
    pos_args = u.Vec([]const u8).init(A);
    shell_pid = @intCast(c.getpid());
    for (u.raw_env) |kv| {
        const p = kv orelse continue;
        const s = std.mem.sliceTo(p, 0);
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse continue;
        if (!validName(s[0..eq])) continue;
        vars.put(A, A.dupe(u8, s[0..eq]) catch continue, .{ .val = A.dupe(u8, s[eq + 1 ..]) catch continue, .exported = true }) catch {};
    }
    // PWD must name the current directory
    var buf: [u.PATH_MAX]u8 = undefined;
    const g = linux.getcwd(&buf, buf.len);
    if (u.ok(g)) {
        const cwd = std.mem.sliceTo(&buf, 0);
        var ok = false;
        if (getVar("PWD")) |w| {
            if (w.len > 0 and w[0] == '/') {
                const s1 = u.stat(w, true);
                const s2 = u.stat(".", true);
                if (s1 != null and s2 != null and s1.?.ino == s2.?.ino and s1.?.dev == s2.?.dev) ok = true;
            }
        }
        if (!ok) {
            _ = setVar("PWD", cwd);
            if (vars.getPtr("PWD")) |p| {
                p.exported = true;
                u.setEnv("PWD", p.val);
            }
        }
    }
    _ = setVar("OPTIND", "1");
    if (!vars.contains("PATH")) _ = setVar("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
}

fn isTty(fd: i32) bool {
    var t: [64]u8 = undefined;
    return u.ok(linux.ioctl(fd, 0x5401, @intFromPtr(&t)));
}

pub fn runApplet(args: []const []const u8) u8 {
    initShell();
    var cmd_string: ?[]const u8 = null;
    var read_stdin = false;
    var force_interactive = false;
    var i: usize = 0;
    while (i < args.len) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (a.len < 2 or (a[0] != '-' and a[0] != '+')) break;
        const on = a[0] == '-';
        if (a.len == 2 and a[1] == 'o') {
            if (i + 1 >= args.len) break;
            if (!setNamedOpt(args[i + 1], on)) {
                u.errf("sh: Illegal option -o {s}\n", .{args[i + 1]});
                return 2;
            }
            i += 2;
            continue;
        }
        var ok = true;
        for (a[1..]) |ch| {
            switch (ch) {
                'c' => cmd_string = "",
                's' => read_stdin = true,
                'i' => force_interactive = true,
                'l' => {},
                else => if (!setOpt(ch, on)) {
                    u.errf("sh: Illegal option {c}{c}\n", .{ a[0], ch });
                    ok = false;
                },
            }
        }
        if (!ok) return 2;
        i += 1;
    }
    var st: u8 = 0;
    if (cmd_string != null) {
        if (i >= args.len) {
            u.err("sh: -c requires an argument\n");
            return 2;
        }
        const text = args[i];
        cmd_mode = true;
        i += 1;
        if (i < args.len) {
            arg0 = args[i];
            i += 1;
        }
        for (args[i..]) |x| pos_args.push(x);
        interactive = force_interactive;
        setupSignals();
        st = runText(text, null);
    } else if (i < args.len and !read_stdin) {
        const path = args[i];
        arg0 = path;
        for (args[i + 1 ..]) |x| pos_args.push(x);
        const text = readWhole(path) orelse {
            u.errf("sh: {s}: {s}\n", .{ path, "No such file or directory" });
            return 127;
        };
        interactive = force_interactive;
        setupSignals();
        st = runText(text, null);
    } else {
        for (args[i..]) |x| pos_args.push(x);
        interactive = force_interactive or (isTty(0) and isTty(2));
        setupSignals();
        var f = Feeder{};
        if (interactive) {
            st = runText("", &f);
        } else st = runScriptStdin(&f);
    }
    if (flow == .exit_) st = @intCast(flow_n & 0xff);
    flow = .none;
    runExitTrap();
    if (flow == .exit_) st = @intCast(flow_n & 0xff);
    return st;
}

fn runScriptStdin(f: *Feeder) u8 {
    // read lazily line by line so that commands sharing stdin see the rest of the input
    const saved_interactive = interactive;
    interactive = false;
    defer interactive = saved_interactive;
    return runText("", f);
}

fn setupSignals() void {
    if (interactive) {
        setSignal(2, .ign);
        setSignal(3, .ign);
        setSignal(15, .ign);
    }
}
