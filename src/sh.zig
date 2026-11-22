// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// sh.zig - POSIX shell: variables, expansion, arithmetic, redirection, execution, builtins
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const P = @import("sh_parse.zig");
const regex = @import("regex.zig");
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
const Arr = struct {
    assoc: bool = false,
    keys: u.Vec([]const u8),
    vals: u.Vec([]const u8),
};
const Var = struct {
    val: []const u8,
    exported: bool = false,
    readonly: bool = false,
    arr: ?*Arr = null,
    integer: bool = false,
    upper: bool = false,
    lower: bool = false,
    nameref: bool = false,
};

fn resolveRef(name: []const u8) []const u8 {
    var cur = name;
    var n: usize = 0;
    while (n < 8) : (n += 1) {
        const v = vars.get(cur) orelse return cur;
        if (!v.nameref or v.val.len == 0) return cur;
        cur = v.val;
    }
    return cur;
}
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
var opt_B = true; // brace expansion
var pipestatus: [64]u8 = @splat(0);
var pipestatus_n: usize = 1;
var start_time: i64 = 0;

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
const JobState = enum { running, stopped, done };
const Job = struct {
    pid: i32,
    status: ?u8,
    num: u32 = 0,
    state: JobState = .running,
    cmd: []const u8 = "",
    pids: []i32 = &.{},
    stopsig: u8 = 20,
    notified: bool = false,
};
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

fn newArr(assoc: bool) *Arr {
    const p = A.create(Arr) catch @panic("oom");
    p.* = .{ .assoc = assoc, .keys = u.Vec([]const u8).init(A), .vals = u.Vec([]const u8).init(A) };
    return p;
}

fn arrFind(ar: *const Arr, key: []const u8) ?usize {
    for (ar.keys.items, 0..) |k, i| if (std.mem.eql(u8, k, key)) return i;
    return null;
}

fn arrPut(ar: *Arr, key: []const u8, val: []const u8) void {
    const v = A.dupe(u8, val) catch return;
    if (arrFind(ar, key)) |i| {
        ar.vals.items[i] = v;
        return;
    }
    const k = A.dupe(u8, key) catch return;
    ar.keys.push(k);
    ar.vals.push(v);
    if (ar.assoc) return;
    // keep indexed arrays in numeric order
    const kn = std.fmt.parseInt(i64, key, 10) catch 0;
    var j = ar.keys.items.len - 1;
    while (j > 0) : (j -= 1) {
        const prev = std.fmt.parseInt(i64, ar.keys.items[j - 1], 10) catch 0;
        if (prev <= kn) break;
        std.mem.swap([]const u8, &ar.keys.items[j], &ar.keys.items[j - 1]);
        std.mem.swap([]const u8, &ar.vals.items[j], &ar.vals.items[j - 1]);
    }
}

fn arrDel(ar: *Arr, key: []const u8) void {
    const i = arrFind(ar, key) orelse return;
    var j = i;
    while (j + 1 < ar.keys.items.len) : (j += 1) {
        ar.keys.items[j] = ar.keys.items[j + 1];
        ar.vals.items[j] = ar.vals.items[j + 1];
    }
    ar.keys.pop();
    ar.vals.pop();
}

fn arrNext(ar: *const Arr) i64 {
    var m: i64 = -1;
    for (ar.keys.items) |k| {
        const n = std.fmt.parseInt(i64, k, 10) catch 0;
        if (n > m) m = n;
    }
    return m + 1;
}

fn arrSync(v: *Var) void {
    if (v.arr) |ar| v.val = if (arrFind(ar, "0")) |i| ar.vals.items[i] else "";
}

fn caseAttr(a: std.mem.Allocator, v: Var, val: []const u8) []const u8 {
    var out = val;
    if (v.integer) out = fmtU(a, arithText(a, val) orelse 0);
    if (v.upper or v.lower) {
        const b = a.dupe(u8, out) catch return out;
        for (b) |*ch| ch.* = if (v.upper) std.ascii.toUpper(ch.*) else std.ascii.toLower(ch.*);
        out = b;
    }
    return out;
}

fn getOrCreateVar(name: []const u8) ?*Var {
    if (vars.getPtr(name)) |p| return p;
    const key = A.dupe(u8, name) catch return null;
    vars.put(A, key, .{ .val = "" }) catch return null;
    return vars.getPtr(name);
}

fn subKey(a: std.mem.Allocator, ar: ?*const Arr, sub: []const u8) ?[]const u8 {
    if (ar != null and ar.?.assoc) return wordText(a, sub, false) catch null;
    var n = arithText(a, sub) orelse return null;
    if (n < 0) {
        n += if (ar) |x| arrNext(x) else 1;
        if (n < 0) {
            u.errf("sh: {s}: bad array subscript\n", .{sub});
            return null;
        }
    }
    return fmtU(a, n);
}

fn lookupElem(a: std.mem.Allocator, name0: []const u8, sub: []const u8) ?[]const u8 {
    const name = resolveRef(name0);
    if (std.mem.eql(u8, name, "FUNCNAME")) {
        const n = arithText(a, sub) orelse return null;
        if (n < 0 or @as(usize, @intCast(n)) >= func_names.items.len) return null;
        return func_names.items[func_names.items.len - 1 - @as(usize, @intCast(n))];
    }
    if (std.mem.eql(u8, name, "PIPESTATUS")) {
        const n = arithText(a, sub) orelse return null;
        return if (n >= 0 and @as(usize, @intCast(n)) < pipestatus_n) fmtU(a, pipestatus[@intCast(n)]) else null;
    }
    const v = vars.get(name) orelse return null;
    if (v.arr) |ar| {
        const k = subKey(a, ar, sub) orelse return null;
        return if (arrFind(ar, k)) |i| ar.vals.items[i] else null;
    }
    const n = arithText(a, sub) orelse return null;
    return if (n == 0) v.val else null;
}

fn setElem(a: std.mem.Allocator, name0: []const u8, sub: []const u8, val: []const u8, append: bool) bool {
    const name = resolveRef(name0);
    if (!validName(name)) {
        u.errf("sh: `{s}': not a valid identifier\n", .{name});
        return false;
    }
    const existed = vars.contains(name);
    const v = getOrCreateVar(name) orelse return false;
    if (v.readonly) {
        u.errf("sh: {s}: is read only\n", .{name});
        return false;
    }
    if (v.arr == null) {
        const ar0 = newArr(false);
        if (existed) arrPut(ar0, "0", v.val);
        v.arr = ar0;
    }
    const ar = v.arr.?;
    const k = subKey(a, ar, sub) orelse return false;
    var nv = val;
    if (append) {
        const cur: []const u8 = if (arrFind(ar, k)) |i| ar.vals.items[i] else "";
        if (v.integer) {
            nv = fmtU(a, (arithText(a, cur) orelse 0) +% (arithText(a, val) orelse 0));
        } else nv = std.fmt.allocPrint(a, "{s}{s}", .{ cur, val }) catch return false;
    }
    arrPut(ar, k, caseAttr(a, v.*, nv));
    arrSync(v);
    return true;
}

/// split the inside of `( ... )` into raw words
fn splitArrayWords(a: std.mem.Allocator, body: []const u8) []const []const u8 {
    var out = u.Vec([]const u8).init(a);
    var i: usize = 0;
    while (i < body.len) {
        const ch = body[i];
        if (ch == ' ' or ch == '\t' or ch == '\n') {
            i += 1;
            continue;
        }
        if (ch == '#') {
            while (i < body.len and body[i] != '\n') i += 1;
            continue;
        }
        const st = i;
        while (i < body.len and !(body[i] == ' ' or body[i] == '\t' or body[i] == '\n')) {
            const k = body[i];
            if (k == '\\' or k == '\'' or k == '"' or k == '`' or k == '$') i = skipQuotedRaw(body, i) else i += 1;
        }
        out.push(body[st..i]);
    }
    return out.items;
}

fn assignArray(a: std.mem.Allocator, name0: []const u8, body: []const u8, append: bool) bool {
    const name = resolveRef(name0);
    if (!validName(name)) {
        u.errf("sh: `{s}': not a valid identifier\n", .{name});
        return false;
    }
    const v = getOrCreateVar(name) orelse return false;
    if (v.readonly) {
        u.errf("sh: {s}: is read only\n", .{name});
        return false;
    }
    const assoc = if (v.arr) |x| x.assoc else false;
    var ar: *Arr = undefined;
    if (append and v.arr != null) ar = v.arr.? else {
        ar = newArr(assoc);
        if (append and v.val.len > 0) arrPut(ar, "0", v.val);
        v.arr = ar;
    }
    var cursor: i64 = arrNext(ar);
    for (splitArrayWords(a, body)) |w| {
        if (w.len > 1 and w[0] == '[') {
            var depth: usize = 0;
            var rb: ?usize = null;
            for (w, 0..) |ch, ix| {
                if (ch == '[') depth += 1 else if (ch == ']') {
                    depth -= 1;
                    if (depth == 0) {
                        rb = ix;
                        break;
                    }
                }
            }
            if (rb) |r| if (r + 1 < w.len and (w[r + 1] == '=' or (w[r + 1] == '+' and r + 2 < w.len and w[r + 2] == '='))) {
                const app = w[r + 1] == '+';
                const valraw = w[r + 2 + @as(usize, @intFromBool(app)) ..];
                const val = expandOne(a, valraw, true) catch return false;
                const k = subKey(a, ar, w[1..r]) orelse return false;
                if (app) {
                    const cur: []const u8 = if (arrFind(ar, k)) |ix| ar.vals.items[ix] else "";
                    arrPut(ar, k, std.fmt.allocPrint(a, "{s}{s}", .{ cur, val }) catch return false);
                } else arrPut(ar, k, caseAttr(a, v.*, val));
                if (!assoc) cursor = (std.fmt.parseInt(i64, k, 10) catch 0) + 1;
                continue;
            };
        }
        const items = expandWords(a, &.{w}) catch return false;
        for (items) |it| {
            if (assoc) continue;
            arrPut(ar, fmtU(a, cursor), caseAttr(a, v.*, it));
            cursor += 1;
        }
    }
    arrSync(v);
    return true;
}

fn isPlainAssign(as: P.Assign) bool {
    if (as.append) return false;
    if (std.mem.indexOfScalar(u8, as.name, '[') != null) return false;
    if (as.value.len >= 2 and as.value[0] == '(' and as.value[as.value.len - 1] == ')') return false;
    return true;
}

fn applyAssign(a: std.mem.Allocator, as: P.Assign) bool {
    const br = std.mem.indexOfScalar(u8, as.name, '[');
    if (br == null and as.value.len >= 2 and as.value[0] == '(' and as.value[as.value.len - 1] == ')')
        return assignArray(a, as.name, as.value[1 .. as.value.len - 1], as.append);
    const val = expandOne(a, as.value, true) catch return false;
    if (br) |b| {
        if (as.name[as.name.len - 1] != ']') return false;
        return setElem(a, as.name[0..b], as.name[b + 1 .. as.name.len - 1], val, as.append);
    }
    if (as.append) {
        const cur = getVar(as.name) orelse "";
        const isint = if (vars.get(as.name)) |x| x.integer else false;
        const nv = if (isint) fmtU(a, (arithText(a, cur) orelse 0) +% (arithText(a, val) orelse 0)) else std.fmt.allocPrint(a, "{s}{s}", .{ cur, val }) catch return false;
        return setVar(as.name, nv);
    }
    return setVar(as.name, val);
}

fn getVar(name0: []const u8) ?[]const u8 {
    const name = resolveRef(name0);
    if (vars.get(name)) |v| return v.val;
    return null;
}

fn setVar(name0: []const u8, value0: []const u8) bool {
    const name = resolveRef(name0);
    var value = value0;
    if (vars.get(name)) |ev| if (ev.integer or ev.upper or ev.lower) {
        value = caseAttr(A, ev, value0);
    };
    const val = A.dupe(u8, value) catch return false;
    if (vars.getPtr(name)) |p| {
        if (p.readonly) {
            u.errf("sh: {s}: is read only\n", .{name});
            return false;
        }
        if (p.arr) |ar| {
            arrPut(ar, "0", val);
            arrSync(p);
            return true;
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
    if (getVar(name)) |gv| return gv;
    if (name.len >= 3) {
        if (std.mem.eql(u8, name, "UID")) return fmtU(a, c.getuid());
        if (std.mem.eql(u8, name, "EUID")) return fmtU(a, c.geteuid());
        if (std.mem.eql(u8, name, "BASHPID")) return fmtU(a, c.getpid());
        if (std.mem.eql(u8, name, "PIPESTATUS")) return fmtU(a, pipestatus[0]);
        if (std.mem.eql(u8, name, "FUNCNAME")) return if (func_names.items.len > 0) func_names.items[func_names.items.len - 1] else null;
        if (std.mem.eql(u8, name, "SECONDS")) return fmtU(a, nowSecs() - start_time);
        if (std.mem.eql(u8, name, "EPOCHSECONDS")) return fmtU(a, nowSecs());
        if (std.mem.eql(u8, name, "OSTYPE")) return "linux-gnu";
    }
    return null;
}

fn nowSecs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
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
        if ((ch == '<' or ch == '>') and !dq and i + 1 < raw.len and raw[i + 1] == '(') {
            var depth: usize = 0;
            var j = i + 1;
            while (j < raw.len) : (j += 1) {
                const k = raw[j];
                if (k == '\\') {
                    j += 1;
                } else if (k == '\'' or k == '"') {
                    j = skipQuotedRaw(raw, j) - 1;
                } else if (k == '(') depth += 1 else if (k == ')') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            if (j < raw.len) {
                const path = try procSubst(e.a, raw[i + 2 .. j], ch == '<');
                e.addQ(path, true);
                i = j + 1;
                continue;
            }
        }
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

var sh_extglob = false;

fn hasExt(pat: []const u8) bool {
    var i: usize = 1;
    while (i < pat.len) : (i += 1) {
        if (pat[i] == '(' and std.mem.indexOfScalar(u8, "?*+@!", pat[i - 1]) != null and (i < 2 or pat[i - 2] != '\\')) return true;
    }
    return false;
}

fn fnmAlwaysExt(pat: []const u8, text: []const u8) bool {
    if (hasExt(pat)) return extMatch(pat, text);
    return c.fnmatch(u.zstr(pat).ptr, u.zstr(text).ptr, 0) == 0;
}

fn fnm(pat: []const u8, text: []const u8) bool {
    if (sh_extglob and hasExt(pat)) return extMatch(pat, text);
    return c.fnmatch(u.zstr(pat).ptr, u.zstr(text).ptr, 0) == 0;
}

fn extClose(pat: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < pat.len) : (i += 1) {
        switch (pat[i]) {
            '\\' => i += 1,
            '[' => {
                var j = i + 1;
                if (j < pat.len and (pat[j] == '!' or pat[j] == '^')) j += 1;
                if (j < pat.len and pat[j] == ']') j += 1;
                while (j < pat.len and pat[j] != ']') j += 1;
                if (j < pat.len) i = j;
            },
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// next top-level alternative of an extglob group body
fn extNextAlt(inner: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* > inner.len) return null;
    const st = pos.*;
    var depth: usize = 0;
    var i = st;
    while (i < inner.len) : (i += 1) {
        switch (inner[i]) {
            '\\' => i += 1,
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            '|' => if (depth == 0) {
                pos.* = i + 1;
                return inner[st..i];
            },
            else => {},
        }
    }
    pos.* = inner.len + 1;
    return inner[st..];
}

fn extAnyAlt(inner: []const u8, text: []const u8) bool {
    var pos: usize = 0;
    while (extNextAlt(inner, &pos)) |alt| if (extMatch(alt, text)) return true;
    return false;
}

fn extBracket(pat: []const u8, pi: usize, ch: u8) ?struct { hit: bool, next: usize } {
    var j = pi + 1;
    var neg = false;
    if (j < pat.len and (pat[j] == '!' or pat[j] == '^')) {
        neg = true;
        j += 1;
    }
    var hit = false;
    var first = true;
    while (j < pat.len) {
        if (pat[j] == ']' and !first) return .{ .hit = hit != neg, .next = j + 1 };
        first = false;
        if (pat[j] == '[' and j + 1 < pat.len and pat[j + 1] == ':') {
            if (std.mem.indexOf(u8, pat[j + 2 ..], ":]")) |e| {
                const cls = pat[j + 2 .. j + 2 + e];
                const m = if (std.mem.eql(u8, cls, "alpha")) std.ascii.isAlphabetic(ch) else if (std.mem.eql(u8, cls, "digit")) std.ascii.isDigit(ch) else if (std.mem.eql(u8, cls, "alnum")) std.ascii.isAlphanumeric(ch) else if (std.mem.eql(u8, cls, "upper")) std.ascii.isUpper(ch) else if (std.mem.eql(u8, cls, "lower")) std.ascii.isLower(ch) else if (std.mem.eql(u8, cls, "space")) std.ascii.isWhitespace(ch) else if (std.mem.eql(u8, cls, "punct")) (std.ascii.isPrint(ch) and !std.ascii.isAlphanumeric(ch) and ch != ' ') else if (std.mem.eql(u8, cls, "xdigit")) std.ascii.isHex(ch) else false;
                if (m) hit = true;
                j += 2 + e + 2;
                continue;
            }
        }
        var lo = pat[j];
        if (lo == '\\' and j + 1 < pat.len) {
            j += 1;
            lo = pat[j];
        }
        if (j + 2 < pat.len and pat[j + 1] == '-' and pat[j + 2] != ']') {
            const hi = pat[j + 2];
            if (ch >= lo and ch <= hi) hit = true;
            j += 3;
        } else {
            if (ch == lo) hit = true;
            j += 1;
        }
    }
    return null;
}

fn extRepeat(pat: []const u8, inner: []const u8, rest: usize, text: []const u8, ti: usize, must_one: bool) bool {
    if (!must_one and emRec(pat, rest, text, ti)) return true;
    var k = ti + 1;
    while (k <= text.len) : (k += 1) {
        if (extAnyAlt(inner, text[ti..k]) and extRepeat(pat, inner, rest, text, k, false)) return true;
    }
    return false;
}

fn emRec(pat: []const u8, pi0: usize, text: []const u8, ti0: usize) bool {
    var pi = pi0;
    var ti = ti0;
    while (pi < pat.len) {
        const ch = pat[pi];
        if (std.mem.indexOfScalar(u8, "?*+@!", ch) != null and pi + 1 < pat.len and pat[pi + 1] == '(') {
            if (extClose(pat, pi + 1)) |cl| {
                const inner = pat[pi + 2 .. cl];
                const rest = cl + 1;
                switch (ch) {
                    '@', '?' => {
                        if (ch == '?' and emRec(pat, rest, text, ti)) return true;
                        var k = ti;
                        while (k <= text.len) : (k += 1) {
                            if (extAnyAlt(inner, text[ti..k]) and emRec(pat, rest, text, k)) return true;
                        }
                        return false;
                    },
                    '*' => return extRepeat(pat, inner, rest, text, ti, false),
                    '+' => return extRepeat(pat, inner, rest, text, ti, true),
                    else => {
                        var k = ti;
                        while (k <= text.len) : (k += 1) {
                            if (!extAnyAlt(inner, text[ti..k]) and emRec(pat, rest, text, k)) return true;
                        }
                        return false;
                    },
                }
            }
        }
        switch (ch) {
            '*' => {
                var k = ti;
                while (k <= text.len) : (k += 1) {
                    if (emRec(pat, pi + 1, text, k)) return true;
                }
                return false;
            },
            '?' => {
                if (ti >= text.len) return false;
                ti += 1;
                pi += 1;
            },
            '[' => {
                if (ti >= text.len) return false;
                if (extBracket(pat, pi, text[ti])) |b| {
                    if (!b.hit) return false;
                    ti += 1;
                    pi = b.next;
                } else {
                    if (text[ti] != '[') return false;
                    ti += 1;
                    pi += 1;
                }
            },
            '\\' => {
                if (pi + 1 >= pat.len) return false;
                if (ti >= text.len or text[ti] != pat[pi + 1]) return false;
                ti += 1;
                pi += 2;
            },
            else => {
                if (ti >= text.len or text[ti] != ch) return false;
                ti += 1;
                pi += 1;
            },
        }
    }
    return ti == text.len;
}

fn extMatch(pat: []const u8, text: []const u8) bool {
    return emRec(pat, 0, text, 0);
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

fn caseChange(a: std.mem.Allocator, val: []const u8, upper: bool, all: bool, pat: []const u8) []const u8 {
    const b = a.dupe(u8, val) catch return val;
    for (b, 0..) |*ch, i| {
        if (!all and i > 0) break;
        if (pat.len > 0 and !fnm(pat, b[i .. i + 1])) continue;
        ch.* = if (upper) std.ascii.toUpper(ch.*) else std.ascii.toLower(ch.*);
    }
    return b;
}

/// value transformations that work on one string: # % / ^ , @
fn modVal(a: std.mem.Allocator, val: []const u8, op: u8, word: []const u8, dq: bool) ShErr![]const u8 {
    switch (op) {
        '#', '%' => {
            var longest = false;
            var w = word;
            if (w.len > 0 and w[0] == op) {
                longest = true;
                w = w[1..];
            }
            const pat = try patternFrom(a, w, false);
            return if (op == '#') removePrefix(val, pat, longest) else removeSuffix(val, pat, longest);
        },
        '/' => {
            var all = false;
            var anchor: u8 = 0;
            var w = word;
            if (w.len > 0 and w[0] == '/') {
                all = true;
                w = w[1..];
            } else if (w.len > 0 and (w[0] == '#' or w[0] == '%')) {
                anchor = w[0];
                w = w[1..];
            }
            const slash = std.mem.indexOfScalar(u8, w, '/');
            const pat = try patternFrom(a, if (slash) |sl| w[0..sl] else w, false);
            const rep_s = try wordText(a, if (slash) |sl| w[sl + 1 ..] else "", dq);
            if (pat.len == 0) return val;
            var o = u.Vec(u8).init(a);
            if (anchor == '#') {
                var l: usize = val.len + 1;
                while (l > 0) {
                    l -= 1;
                    if (l > 0 and fnm(pat, val[0..l])) {
                        o.pushSlice(rep_s);
                        o.pushSlice(val[l..]);
                        return o.items;
                    }
                }
                return val;
            }
            if (anchor == '%') {
                var st: usize = 0;
                while (st < val.len) : (st += 1) {
                    if (fnm(pat, val[st..])) {
                        o.pushSlice(val[0..st]);
                        o.pushSlice(rep_s);
                        return o.items;
                    }
                }
                return val;
            }
            var idx: usize = 0;
            while (idx <= val.len) {
                var matched: ?usize = null;
                var l: usize = val.len - idx + 1;
                while (l > 0) {
                    l -= 1;
                    if (l > 0 and fnm(pat, val[idx .. idx + l])) {
                        matched = l;
                        break;
                    }
                }
                if (matched) |ml| {
                    o.pushSlice(rep_s);
                    idx += ml;
                    if (!all) {
                        o.pushSlice(val[idx..]);
                        break;
                    }
                } else {
                    if (idx < val.len) o.push(val[idx]);
                    idx += 1;
                }
            }
            return o.items;
        },
        '^', ',' => {
            var all = false;
            var w = word;
            if (w.len > 0 and w[0] == op) {
                all = true;
                w = w[1..];
            }
            const pat = try patternFrom(a, w, false);
            return caseChange(a, val, op == '^', all, pat);
        },
        '@' => {
            if (word.len == 0) return fatal(127, "bad substitution", .{});
            switch (word[0]) {
                'Q' => return quoteSingle(a, val),
                'U' => return caseChange(a, val, true, true, ""),
                'L' => return caseChange(a, val, false, true, ""),
                'u' => return caseChange(a, val, true, false, ""),
                'l' => return caseChange(a, val, false, false, ""),
                else => return val,
            }
        },
        else => return val,
    }
}

fn emitList(e: *Exp, vals: []const []const u8, star: bool, dq: bool, dq_added: *bool, saw_at_zero: *bool) void {
    if (dq and !star) {
        if (vals.len == 0) {
            saw_at_zero.* = true;
            return;
        }
        for (vals, 0..) |p, idx| {
            if (idx > 0) e.finish();
            e.addQ(p, true);
            e.have = true;
        }
        dq_added.* = true;
        return;
    }
    if (dq) {
        const ifs = ifsValue();
        var o = u.Vec(u8).init(e.a);
        for (vals, 0..) |p, idx| {
            if (idx > 0 and ifs.len > 0) o.push(ifs[0]);
            o.pushSlice(p);
        }
        e.addQ(o.items, true);
        dq_added.* = true;
        return;
    }
    for (vals, 0..) |p, idx| {
        if (idx > 0) {
            if (!star) e.finish() else e.addSplit(" ");
        }
        e.addSplit(p);
    }
}

fn arrayValues(a: std.mem.Allocator, name0: []const u8) []const []const u8 {
    const name = resolveRef(name0);
    var vals = u.Vec([]const u8).init(a);
    if (std.mem.eql(u8, name, "PIPESTATUS")) {
        for (pipestatus[0..pipestatus_n]) |x| vals.push(fmtU(a, x));
        return vals.items;
    }
    if (std.mem.eql(u8, name, "FUNCNAME")) {
        var k = func_names.items.len;
        while (k > 0) {
            k -= 1;
            vals.push(func_names.items[k]);
        }
        return vals.items;
    }
    if (name.len == 1 and (name[0] == '@' or name[0] == '*')) {
        for (pos_args.items) |x| vals.push(x);
        return vals.items;
    }
    if (vars.get(name)) |v| {
        if (v.arr) |ar| {
            for (ar.vals.items) |x| vals.push(x);
        } else vals.push(v.val);
    }
    return vals.items;
}

fn expandArrayAll(e: *Exp, name: []const u8, star: bool, b: []const u8, dq: bool, dq_added: *bool, saw_at_zero: *bool) ShErr!void {
    const vals = arrayValues(e.a, name);
    if (b.len == 0) {
        emitList(e, vals, star, dq, dq_added, saw_at_zero);
        return;
    }
    if (b[0] == ':' and !(b.len > 1 and std.mem.indexOfScalar(u8, "-+=?", b[1]) != null)) {
        const positional = name.len == 1 and (name[0] == '@' or name[0] == '*');
        const rest = b[1..];
        const sc = std.mem.indexOfScalar(u8, rest, ':');
        const off_s = std.mem.trim(u8, try wordText(e.a, if (sc) |x| rest[0..x] else rest, dq), " ");
        var off: i64 = evalArith(e.a, off_s) catch return fatal(127, "arithmetic expression error", .{});
        var list = u.Vec([]const u8).init(e.a);
        if (positional and off == 0) list.push(arg0);
        for (vals) |x| list.push(x);
        const n: i64 = @intCast(list.items.len);
        if (positional and off > 0) off -= 1 else if (positional and off == 0) off = 0;
        if (off < 0) off += n;
        if (off < 0 or off > n) {
            emitList(e, &.{}, star, dq, dq_added, saw_at_zero);
            return;
        }
        var end = n;
        if (sc) |x| {
            const len_s = std.mem.trim(u8, try wordText(e.a, rest[x + 1 ..], dq), " ");
            const l = evalArith(e.a, len_s) catch return fatal(127, "arithmetic expression error", .{});
            if (l < 0) {
                end = n + l;
                if (end < off) return fatal(127, "{s}: substring expression < 0", .{len_s});
            } else end = @min(n, off + l);
        }
        emitList(e, list.items[@intCast(off)..@intCast(end)], star, dq, dq_added, saw_at_zero);
        return;
    }
    {
        var colon = false;
        var bb = b;
        if (bb[0] == ':' and bb.len > 1 and std.mem.indexOfScalar(u8, "-+=?", bb[1]) != null) {
            colon = true;
            bb = bb[1..];
        }
        if (std.mem.indexOfScalar(u8, "-+=?", bb[0]) != null) {
            var all_empty = true;
            for (vals) |x| if (x.len > 0) {
                all_empty = false;
            };
            const is_null = vals.len == 0 or (colon and all_empty);
            const word = bb[1..];
            switch (bb[0]) {
                '-', '=' => {
                    if (is_null) return expandInto(e, word, dq, false);
                    emitList(e, vals, star, dq, dq_added, saw_at_zero);
                    return;
                },
                '+' => {
                    if (!is_null) return expandInto(e, word, dq, false);
                    return;
                },
                else => {
                    if (is_null) {
                        const w = try wordText(e.a, word, dq);
                        return fatal(127, "{s}: {s}", .{ name, if (w.len == 0) "parameter null or not set" else w });
                    }
                    emitList(e, vals, star, dq, dq_added, saw_at_zero);
                    return;
                },
            }
        }
    }
    if (std.mem.indexOfScalar(u8, "#%/^,@", b[0]) != null) {
        var out = u.Vec([]const u8).init(e.a);
        for (vals) |x| out.push(try modVal(e.a, x, b[0], b[1..], dq));
        emitList(e, out.items, star, dq, dq_added, saw_at_zero);
        return;
    }
    return fatal(127, "bad substitution", .{});
}

fn splitSubscript(nm: []const u8) ?struct { name: []const u8, sub: []const u8, rest: []const u8 } {
    const br = std.mem.indexOfScalar(u8, nm, '[') orelse return null;
    var depth: usize = 0;
    var i = br;
    while (i < nm.len) : (i += 1) {
        if (nm[i] == '[') depth += 1 else if (nm[i] == ']') {
            depth -= 1;
            if (depth == 0) return .{ .name = nm[0..br], .sub = nm[br + 1 .. i], .rest = nm[i + 1 ..] };
        }
    }
    return null;
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
        if (splitSubscript(nm)) |ss| {
            if (ss.sub.len == 1 and (ss.sub[0] == '@' or ss.sub[0] == '*')) {
                const cnt = arrayValues(e.a, ss.name).len;
                const s2 = fmtU(e.a, cnt);
                if (dq) e.addQ(s2, true) else e.addSplit(s2);
                dq_added.* = true;
                return;
            }
            const ev = lookupElem(e.a, ss.name, ss.sub) orelse "";
            const s2 = fmtU(e.a, std.unicode.utf8CountCodepoints(ev) catch ev.len);
            if (dq) e.addQ(s2, true) else e.addSplit(s2);
            dq_added.* = true;
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
    if (b.len > 1 and b[0] == '!') {
        const nm = b[1..];
        if (splitSubscript(nm)) |ss| {
            if (ss.rest.len == 0 and ss.sub.len == 1 and (ss.sub[0] == '@' or ss.sub[0] == '*')) {
                var keys = u.Vec([]const u8).init(e.a);
                if (vars.get(ss.name)) |v| {
                    if (v.arr) |ar| {
                        for (ar.keys.items) |x| keys.push(x);
                    } else keys.push("0");
                }
                emitList(e, keys.items, ss.sub[0] == '*', dq, dq_added, saw_at_zero);
                return;
            }
        }
        if (nm.len > 1 and (nm[nm.len - 1] == '*' or nm[nm.len - 1] == '@') and validName(nm[0 .. nm.len - 1])) {
            var names = u.Vec([]const u8).init(e.a);
            var it = vars.iterator();
            while (it.next()) |en| if (std.mem.startsWith(u8, en.key_ptr.*, nm[0 .. nm.len - 1])) names.push(en.key_ptr.*);
            std.mem.sort([]const u8, names.items, {}, struct {
                fn lt(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.lt);
            emitList(e, names.items, nm[nm.len - 1] == '*', dq, dq_added, saw_at_zero);
            return;
        }
        // ${!name}: indirect expansion
        var ie: usize = 0;
        while (ie < nm.len and (isNameChar(nm[ie]))) ie += 1;
        if (ie == nm.len) {
            const target = lookup(e.a, nm);
            if (target == null and opt_u) return fatal(127, "{s}: parameter not set", .{nm});
            const tn = target orelse "";
            const tv = if (splitSubscript(tn)) |ts| lookupElem(e.a, ts.name, ts.sub) else lookup(e.a, tn);
            return addParamVal(e, tv orelse "", dq, dq_added);
        }
    }
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
    var sub: ?[]const u8 = null;
    if (b.len > 0 and b[0] == '[') {
        const ss = splitSubscript(b) orelse return fatal(127, "bad substitution", .{});
        sub = ss.sub;
        b = ss.rest;
        if (ss.sub.len == 1 and (ss.sub[0] == '@' or ss.sub[0] == '*')) return expandArrayAll(e, name, ss.sub[0] == '*', b, dq, dq_added, saw_at_zero);
    } else if (name.len == 1 and (name[0] == '@' or name[0] == '*') and b.len > 0 and b[0] == ':') {
        return expandArrayAll(e, name, name[0] == '*', b, dq, dq_added, saw_at_zero);
    }
    if (b.len == 0) {
        if (sub) |sv| {
            const ev = lookupElem(e.a, name, sv);
            if (ev == null and opt_u) return fatal(127, "{s}[{s}]: unbound variable", .{ name, sv });
            return addParamVal(e, ev orelse "", dq, dq_added);
        }
        return addParam(e, name, dq, dq_added, saw_at_zero);
    }

    var colon = false;
    var op = b[0];
    var word: []const u8 = "";
    if (op == ':') {
        colon = true;
        if (b.len < 2) return fatal(127, "bad substitution", .{});
        op = b[1];
        word = b[2..];
    } else word = b[1..];

    const v = if (sub) |sv| lookupElem(e.a, name, sv) else lookup(e.a, name);
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
        '#', '%', '/', '^', ',', '@' => {
            if (colon) return fatal(127, "bad substitution", .{});
            if (v == null and opt_u) return fatal(127, "{s}: parameter not set", .{name});
            return addParamVal(e, try modVal(e.a, v orelse "", op, word, dq), dq, dq_added);
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
        if (sh_extglob and ch == '(' and k > 0 and (f.buf[k - 1] == '@' or f.buf[k - 1] == '+' or f.buf[k - 1] == '!') and !f.q[k - 1]) return true;
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
        if (sh_extglob and seg[k] == '(' and k > 0 and std.mem.indexOfScalar(u8, "@+!", seg[k - 1]) != null) return true;
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
        if (name[0] == '.' and seg[0] != '.' and !sh_dotglob) continue;
        if (!fnm(seg, std.mem.sliceTo(en.name, 0))) continue;
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
        if (sh_nullglob) return;
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

// ----- brace expansion -----
fn skipQuotedRaw(raw: []const u8, start: usize) usize {
    // returns the index just past a quoted / substitution construct that starts at i0 (or i0 + 1 when none)
    const ch = raw[start];
    var i = start;
    switch (ch) {
        '\\' => return @min(i + 2, raw.len),
        '\'' => {
            i += 1;
            while (i < raw.len and raw[i] != '\'') i += 1;
            return @min(i + 1, raw.len);
        },
        '"' => {
            i += 1;
            while (i < raw.len and raw[i] != '"') {
                if (raw[i] == '\\') i += 1;
                i += 1;
            }
            return @min(i + 1, raw.len);
        },
        '`' => {
            i += 1;
            while (i < raw.len and raw[i] != '`') {
                if (raw[i] == '\\') i += 1;
                i += 1;
            }
            return @min(i + 1, raw.len);
        },
        '$' => {
            if (i + 1 < raw.len and (raw[i + 1] == '(' or raw[i + 1] == '{')) {
                const open = raw[i + 1];
                const close: u8 = if (open == '(') ')' else '}';
                var depth: usize = 0;
                i += 1;
                while (i < raw.len) {
                    const k = raw[i];
                    if (k == '\\') {
                        i += 2;
                        continue;
                    }
                    if (k == '\'' or k == '"') {
                        i = skipQuotedRaw(raw, i);
                        continue;
                    }
                    if (k == open) depth += 1 else if (k == close) {
                        depth -= 1;
                        if (depth == 0) return i + 1;
                    }
                    i += 1;
                }
                return raw.len;
            }
            return i + 1;
        },
        else => return i + 1,
    }
}

const BraceHit = struct { open: usize, close: usize, parts: [][]const u8, seq: ?[]const []const u8 };

fn seqItems(a: std.mem.Allocator, body: []const u8) ?[]const []const u8 {
    // {x..y} or {x..y..step} with integers or single letters
    var it = std.mem.splitSequence(u8, body, "..");
    const f = it.next() orelse return null;
    const t = it.next() orelse return null;
    const st = it.next();
    if (it.next() != null) return null;
    var out = u.Vec([]const u8).init(a);
    const fi = std.fmt.parseInt(i64, f, 10) catch null;
    const ti = std.fmt.parseInt(i64, t, 10) catch null;
    if (fi != null and ti != null) {
        var step: i64 = 1;
        if (st) |sv| step = std.fmt.parseInt(i64, sv, 10) catch return null;
        if (step == 0) step = 1;
        if (step < 0) step = -step;
        const pad = blk: {
            const lead = struct {
                fn f2(x: []const u8) bool {
                    var y = x;
                    if (y.len > 0 and (y[0] == '-' or y[0] == '+')) y = y[1..];
                    return y.len > 1 and y[0] == '0';
                }
            }.f2;
            if (lead(f) or lead(t)) break :blk @max(f.len, t.len);
            break :blk 0;
        };
        var v = fi.?;
        const asc = fi.? <= ti.?;
        var guard: usize = 0;
        while (guard < 100000) : (guard += 1) {
            if (asc and v > ti.?) break;
            if (!asc and v < ti.?) break;
            const mag: u64 = @intCast(if (v < 0) -v else v);
            const digits = std.fmt.allocPrint(a, "{d}", .{mag}) catch return null;
            var tb = u.Vec(u8).init(a);
            if (v < 0) tb.push('-');
            const used: usize = digits.len + (if (v < 0) @as(usize, 1) else 0);
            if (pad > used) tb.pushN('0', pad - used);
            tb.pushSlice(digits);
            const txt = tb.items;
            out.push(txt);
            if (asc) v += step else v -= step;
        }
        return out.items;
    }
    if (f.len == 1 and t.len == 1 and std.ascii.isAlphabetic(f[0]) and std.ascii.isAlphabetic(t[0])) {
        var step: i64 = 1;
        if (st) |sv| step = std.fmt.parseInt(i64, sv, 10) catch return null;
        if (step == 0) step = 1;
        if (step < 0) step = -step;
        var v: i64 = f[0];
        const e: i64 = t[0];
        const asc = v <= e;
        while (if (asc) v <= e else v >= e) {
            out.push(a.dupe(u8, &[_]u8{@intCast(v)}) catch return null);
            if (asc) v += step else v -= step;
        }
        return out.items;
    }
    return null;
}

fn braceFind(a: std.mem.Allocator, raw: []const u8) ?BraceHit {
    var i: usize = 0;
    while (i < raw.len) {
        const ch = raw[i];
        if (ch == '\\' or ch == '\'' or ch == '"' or ch == '`' or ch == '$') {
            i = skipQuotedRaw(raw, i);
            continue;
        }
        if (ch != '{') {
            i += 1;
            continue;
        }
        // look for the matching close brace
        var j = i + 1;
        var depth: usize = 1;
        var parts = u.Vec([]const u8).init(a);
        var seg_start = i + 1;
        var have_comma = false;
        var close: ?usize = null;
        while (j < raw.len) {
            const k = raw[j];
            if (k == '\\' or k == '\'' or k == '"' or k == '`' or k == '$') {
                j = skipQuotedRaw(raw, j);
                continue;
            }
            if (k == '{') depth += 1 else if (k == '}') {
                depth -= 1;
                if (depth == 0) {
                    close = j;
                    break;
                }
            } else if (k == ',' and depth == 1) {
                parts.push(raw[seg_start..j]);
                seg_start = j + 1;
                have_comma = true;
            }
            j += 1;
        }
        if (close) |cl| {
            if (have_comma) {
                parts.push(raw[seg_start..cl]);
                return .{ .open = i, .close = cl, .parts = parts.items, .seq = null };
            }
            if (seqItems(a, raw[i + 1 .. cl])) |items| return .{ .open = i, .close = cl, .parts = &.{}, .seq = items };
        }
        i += 1;
    }
    return null;
}

fn braceExpand(a: std.mem.Allocator, raw: []const u8, out: *u.Vec([]const u8)) void {
    if (out.items.len > 100000) {
        out.push(raw);
        return;
    }
    const hit = braceFind(a, raw) orelse {
        out.push(raw);
        return;
    };
    const prefix = raw[0..hit.open];
    const suffix = raw[hit.close + 1 ..];
    if (hit.seq) |items| {
        for (items) |it| {
            const w = std.fmt.allocPrint(a, "{s}{s}{s}", .{ prefix, it, suffix }) catch return;
            braceExpand(a, w, out);
        }
    } else {
        for (hit.parts) |part| {
            const w = std.fmt.allocPrint(a, "{s}{s}{s}", .{ prefix, part, suffix }) catch return;
            braceExpand(a, w, out);
        }
    }
}

/// full word-list expansion: split + pathname expansion
fn expandWords(a: std.mem.Allocator, words: []const []const u8) ShErr![][]const u8 {
    var out = u.Vec([]const u8).init(a);
    for (words) |w0| {
        var bw = u.Vec([]const u8).init(a);
        if (opt_B and std.mem.indexOfScalar(u8, w0, '{') != null) braceExpand(a, w0, &bw) else bw.push(w0);
        for (bw.items) |w| {
            var e = Exp.init(a, true);
            try expandInto(&e, w, false, false);
            e.finish();
            for (e.fields.items) |f| {
                if (!opt_f and hasGlob(f)) globExpand(a, f, &out) else out.push(f.buf);
            }
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
            var subtxt: ?[]const u8 = null;
            if (self.i < self.s.len and self.s[self.i] == '[') {
                var depth: usize = 0;
                var q = self.i;
                while (q < self.s.len) : (q += 1) {
                    if (self.s[q] == '[') depth += 1 else if (self.s[q] == ']') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                if (q >= self.s.len) return error.ArithError;
                subtxt = self.s[self.i + 1 .. q];
                self.i = q + 1;
            }
            self.skip();
            const aops = [_][]const u8{ "<<=", ">>=", "+=", "-=", "*=", "/=", "%=", "&=", "^=", "|=", "=" };
            for (aops) |op| {
                if (std.mem.startsWith(u8, self.s[self.i..], op)) {
                    if (std.mem.eql(u8, op, "=") and self.i + 1 < self.s.len and self.s[self.i + 1] == '=') break;
                    self.i += op.len;
                    const rhs = try self.assign();
                    var nv = rhs;
                    if (!std.mem.eql(u8, op, "=")) {
                        var cur: i64 = 0;
                        if (subtxt) |st| {
                            const ev = lookupElem(self.a, name, st) orelse "";
                            cur = if (ev.len == 0) 0 else (parseNum(std.mem.trim(u8, ev, " \t")) orelse 0);
                        } else cur = try self.varValue(name);
                        nv = try applyOp(op[0 .. op.len - 1], cur, rhs);
                    }
                    const txt = fmtU(self.a, nv);
                    if (subtxt) |st| _ = setElem(self.a, name, st, txt, false) else _ = setVar(name, txt);
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
        if ((ch == '+' or ch == '-') and self.i + 2 < self.s.len and self.s[self.i + 1] == ch) {
            var j = self.i + 2;
            while (j < self.s.len and (self.s[j] == ' ' or self.s[j] == '\t')) j += 1;
            if (j < self.s.len and (std.ascii.isAlphabetic(self.s[j]) or self.s[j] == '_')) {
                var k = j;
                while (k < self.s.len and isNameChar(self.s[k])) k += 1;
                const name = self.s[j..k];
                const cur = try self.varValue(name);
                const nv = if (ch == '+') cur +% 1 else cur -% 1;
                _ = setVar(name, fmtU(self.a, nv));
                self.i = k;
                return nv;
            }
        }
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
            while (j < self.s.len and (std.ascii.isAlphanumeric(self.s[j]) or self.s[j] == '_' or self.s[j] == '#' or self.s[j] == '@')) j += 1;
            const v = parseNum(self.s[self.i..j]) orelse return error.ArithError;
            self.i = j;
            return v;
        }
        if (std.ascii.isAlphabetic(ch) or ch == '_') {
            var j = self.i;
            while (j < self.s.len and isNameChar(self.s[j])) j += 1;
            const name = self.s[self.i..j];
            self.i = j;
            if (self.i < self.s.len and self.s[self.i] == '[') {
                var depth: usize = 0;
                var q = self.i;
                while (q < self.s.len) : (q += 1) {
                    if (self.s[q] == '[') depth += 1 else if (self.s[q] == ']') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                if (q >= self.s.len) return error.ArithError;
                const subtxt = self.s[self.i + 1 .. q];
                self.i = q + 1;
                const ev = lookupElem(self.a, name, subtxt) orelse return 0;
                const t = std.mem.trim(u8, ev, " \t");
                if (t.len == 0) return 0;
                return parseNum(t) orelse evalArith(self.a, t) catch return error.ArithError;
            }
            var k = j;
            while (k < self.s.len and (self.s[k] == ' ' or self.s[k] == '\t')) k += 1;
            if (k + 1 < self.s.len and (self.s[k] == '+' or self.s[k] == '-') and self.s[k + 1] == self.s[k]) {
                const cur = try self.varValue(name);
                const nv = if (self.s[k] == '+') cur +% 1 else cur -% 1;
                _ = setVar(name, fmtU(self.a, nv));
                self.i = k + 2;
                return cur;
            }
            return self.varValue(name);
        }
        return error.ArithError;
    }
};

fn parseNum(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    if (std.mem.indexOfScalar(u8, s, '#')) |h| {
        const base = std.fmt.parseInt(u8, s[0..h], 10) catch return null;
        if (base < 2 or base > 64) return null;
        var v: i64 = 0;
        if (h + 1 >= s.len) return null;
        for (s[h + 1 ..]) |ch| {
            var d: u8 = undefined;
            if (ch >= '0' and ch <= '9') d = ch - '0' else if (ch >= 'a' and ch <= 'z') d = ch - 'a' + 10 else if (ch >= 'A' and ch <= 'Z') d = if (base <= 36) ch - 'A' + 10 else ch - 'A' + 36 else if (ch == '@') d = 62 else if (ch == '_') d = 63 else return null;
            if (d >= base) return null;
            v = v *% base +% d;
        }
        return v;
    }
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

// ===================== job control =====================
var jc = false;
var jc_tty: i32 = -1;
var shell_pgid: i32 = 0;
var tio_saved: [64]u8 = undefined;
var tio_ok = false;
var job_cur: u32 = 0;
var job_prev: u32 = 0;
var fg_stopped = false;

fn tcSetPgrp(pg: i32) void {
    if (!jc or jc_tty < 0) return;
    var pgv: i32 = pg;
    _ = linux.syscall3(.ioctl, @as(usize, @intCast(jc_tty)), 0x5410, @intFromPtr(&pgv));
}

fn tcRestore() void {
    if (!jc or !tio_ok) return;
    _ = linux.syscall3(.ioctl, @as(usize, @intCast(jc_tty)), 0x5403, @intFromPtr(&tio_saved));
}

fn jcInit() void {
    if (!interactive or !isTty(0)) return;
    const rc = linux.fcntl(0, 1030, 10);
    if (!u.ok(rc)) return;
    jc_tty = @intCast(rc);
    setSignal(20, .ign);
    setSignal(21, .ign);
    setSignal(22, .ign);
    _ = linux.setpgid(0, 0);
    shell_pgid = @intCast(c.getpgrp());
    jc = true;
    tcSetPgrp(shell_pgid);
    tio_ok = u.ok(linux.syscall3(.ioctl, @as(usize, @intCast(jc_tty)), 0x5401, @intFromPtr(&tio_saved)));
}

/// child side right after fork: join (or create) the process group
fn jcChild(pgid: i32, fg: bool) void {
    if (!jc) return;
    _ = linux.setpgid(0, pgid);
    if (fg) tcSetPgrp(if (pgid == 0) @as(i32, @intCast(c.getpid())) else pgid);
}

fn jcParent(pid: i32, pgid: i32, fg: bool) void {
    if (!jc) return;
    const pg = if (pgid == 0) pid else pgid;
    _ = linux.setpgid(pid, pg);
    if (fg) tcSetPgrp(pg);
}

fn redirText(o: *u.Vec(u8), r: P.Redir) void {
    const sym: []const u8 = switch (r.op) {
        .in => "<",
        .out => ">",
        .append => ">>",
        .dup_in => "<&",
        .dup_out => ">&",
        .rdwr => "<>",
        .clobber => ">|",
        .heredoc => "<<",
        .herestr => "<<<",
        .both_out => "&>",
        .both_append => "&>>",
    };
    const def: i32 = switch (r.op) {
        .in, .dup_in, .rdwr, .heredoc, .herestr => 0,
        else => 1,
    };
    if (r.fdvar.len > 0) {
        o.push('{');
        o.pushSlice(r.fdvar);
        o.push('}');
    } else if (r.fd != def and r.op != .both_out and r.op != .both_append) {
        var b: [16]u8 = undefined;
        o.pushSlice(std.fmt.bufPrint(&b, "{d}", .{r.fd}) catch "");
    }
    o.pushSlice(sym);
    if (r.op == .heredoc) {
        o.pushSlice("EOF");
        return;
    }
    o.pushSlice(r.word);
}

fn nodeTextInto(o: *u.Vec(u8), n: *Node) void {
    switch (n.kind) {
        .simple => {
            var first = true;
            for (n.assigns) |as| {
                if (!first) o.push(' ');
                first = false;
                o.pushSlice(as.name);
                o.pushSlice(if (as.append) "+=" else "=");
                o.pushSlice(as.value);
            }
            for (n.words) |w| {
                if (!first) o.push(' ');
                first = false;
                o.pushSlice(w);
            }
            for (n.redirs) |r| {
                if (!first) o.push(' ');
                first = false;
                redirText(o, r);
            }
        },
        .pipeline => {
            if (n.negate) o.pushSlice("! ");
            for (n.children, 0..) |ch, i| {
                if (i > 0) o.pushSlice(" | ");
                nodeTextInto(o, ch);
            }
        },
        .andor => {
            for (n.children, 0..) |ch, i| {
                if (i > 0) o.pushSlice(if (n.ops[i - 1] == '&') " && " else " || ");
                nodeTextInto(o, ch);
            }
        },
        .list => {
            for (n.children, 0..) |ch, i| {
                nodeTextInto(o, ch);
                if (n.ops[i] == '&') o.pushSlice(" &") else if (i + 1 < n.children.len) o.push(';');
                if (i + 1 < n.children.len) o.push(' ');
            }
        },
        .subshell => {
            o.pushSlice("( ");
            if (n.children.len > 0) nodeTextInto(o, n.children[0]);
            o.pushSlice(" )");
        },
        .group => {
            o.pushSlice("{ ");
            if (n.children.len > 0) nodeTextInto(o, n.children[0]);
            o.pushSlice("; }");
        },
        .if_ => {
            o.pushSlice("if ");
            if (n.children.len > 0) nodeTextInto(o, n.children[0]);
            o.pushSlice("; then ");
            if (n.children.len > 1) nodeTextInto(o, n.children[1]);
            o.pushSlice("; fi");
        },
        .while_, .until_ => {
            o.pushSlice(if (n.kind == .while_) "while " else "until ");
            if (n.children.len > 0) nodeTextInto(o, n.children[0]);
            o.pushSlice("; do ");
            if (n.children.len > 1) nodeTextInto(o, n.children[1]);
            o.pushSlice("; done");
        },
        .for_, .select_ => {
            o.pushSlice(if (n.kind == .for_) "for " else "select ");
            o.pushSlice(n.name);
            if (n.has_in) {
                o.pushSlice(" in");
                for (n.words) |w| {
                    o.push(' ');
                    o.pushSlice(w);
                }
            }
            o.pushSlice("; do ");
            if (n.children.len > 0) nodeTextInto(o, n.children[0]);
            o.pushSlice("; done");
        },
        .for_arith => {
            o.pushSlice("for ((");
            if (n.words.len == 3) {
                o.pushSlice(n.words[0]);
                o.pushSlice("; ");
                o.pushSlice(n.words[1]);
                o.pushSlice("; ");
                o.pushSlice(n.words[2]);
            }
            o.pushSlice(")); do ");
            if (n.children.len > 0) nodeTextInto(o, n.children[0]);
            o.pushSlice("; done");
        },
        .case_ => {
            o.pushSlice("case ");
            if (n.words.len > 0) o.pushSlice(n.words[0]);
            o.pushSlice(" in ... esac");
        },
        .dbracket => {
            o.pushSlice("[[");
            for (n.words) |w| {
                o.push(' ');
                o.pushSlice(w);
            }
            o.pushSlice(" ]]");
        },
        .arith => {
            o.pushSlice("((");
            if (n.words.len > 0) o.pushSlice(n.words[0]);
            o.pushSlice("))");
        },
        .time_ => {
            o.pushSlice("time ");
            if (n.children.len > 0) nodeTextInto(o, n.children[0]);
        },
        .funcdef => {
            o.pushSlice(n.name);
            o.pushSlice(" ()");
        },
    }
}

fn nodeText(a: std.mem.Allocator, n: *Node) []const u8 {
    var o = u.Vec(u8).init(a);
    nodeTextInto(&o, n);
    return o.items;
}

fn jobNumExists(num: u32) bool {
    for (jobs.items) |j| if (j.num == num and j.num != 0) return true;
    return false;
}

fn highestJob(skip: u32) u32 {
    var m: u32 = 0;
    for (jobs.items) |j| if (j.num != skip and j.num > m) {
        m = j.num;
    };
    return m;
}

fn curJobNum() u32 {
    if (job_cur != 0 and jobNumExists(job_cur)) return job_cur;
    return highestJob(0);
}

fn prevJobNum() u32 {
    const cur = curJobNum();
    if (job_prev != 0 and job_prev != cur and jobNumExists(job_prev)) return job_prev;
    return highestJob(cur);
}

fn makeCurrent(num: u32) void {
    if (job_cur != num) {
        job_prev = job_cur;
        job_cur = num;
    }
}

fn nextJobNum() u32 {
    return highestJob(0) + 1;
}

fn findJobIdx(pid: i32) ?usize {
    for (jobs.items, 0..) |j, k| if (j.pid == pid) return k;
    return null;
}

fn removeJobAt(k: usize) void {
    std.mem.copyForwards(Job, jobs.items[k .. jobs.items.len - 1], jobs.items[k + 1 ..]);
    jobs.items.len -= 1;
}

fn sigText(sig: u8) []const u8 {
    return switch (sig) {
        1 => "Hangup",
        2 => "Interrupt",
        3 => "Quit",
        4 => "Illegal instruction",
        6 => "Aborted",
        8 => "Floating point exception",
        9 => "Killed",
        11 => "Segmentation fault",
        13 => "Broken pipe",
        14 => "Alarm clock",
        15 => "Terminated",
        else => "Signaled",
    };
}

fn jobStateText(a: std.mem.Allocator, j: Job) []const u8 {
    switch (j.state) {
        .running => return "Running",
        .stopped => return if (j.stopsig == 20) "Stopped" else std.fmt.allocPrint(a, "Stopped (SIG{s})", .{if (j.stopsig == 21) "TTIN" else if (j.stopsig == 22) "TTOU" else "STOP"}) catch "Stopped",
        .done => {
            const st = j.status orelse 0;
            if (st == 0) return "Done";
            if (st > 128) return sigText(st - 128);
            return std.fmt.allocPrint(a, "Exit {d}", .{st}) catch "Exit";
        },
    }
}

fn printJobLine(a: std.mem.Allocator, j: Job, long: bool, to_err: bool) void {
    const cur = curJobNum();
    const prev = prevJobNum();
    const mark: u8 = if (j.num == cur) '+' else if (j.num == prev) '-' else ' ';
    const state = jobStateText(a, j);
    const amp: []const u8 = if (j.state == .running) " &" else "";
    var line: []const u8 = undefined;
    if (long) {
        line = std.fmt.allocPrint(a, "[{d}]{c} {d} {s: <27}{s}{s}\n", .{ j.num, mark, j.pid, state, j.cmd, amp }) catch return;
    } else {
        line = std.fmt.allocPrint(a, "[{d}]{c}  {s: <27}{s}{s}\n", .{ j.num, mark, state, j.cmd, amp }) catch return;
    }
    if (to_err) u.err(line) else u.out(line);
}

/// poll every job member without blocking and update the table
fn jcUpdate() void {
    for (jobs.items) |*j| {
        if (j.state == .done) continue;
        var alive: usize = 0;
        var stopped_n: usize = 0;
        for (j.pids) |*pp| {
            if (pp.* <= 0) continue;
            var st: u32 = 0;
            const rc = linux.waitpid(pp.*, &st, 1 | 2 | 8); // WNOHANG | WUNTRACED | WCONTINUED
            if (!u.ok(rc)) {
                pp.* = 0;
                continue;
            }
            if (rc == 0) {
                alive += 1;
                continue;
            }
            if ((st & 0xff) == 0x7f) {
                stopped_n += 1;
                alive += 1;
                j.stopsig = @intCast((st >> 8) & 0xff);
                if (j.state == .running) {
                    j.state = .stopped;
                    j.notified = false;
                }
                continue;
            }
            if (st == 0xffff) {
                alive += 1;
                if (j.state == .stopped) j.state = .running;
                continue;
            }
            const was_last = pp.* == j.pids[j.pids.len - 1];
            pp.* = 0;
            if (was_last or j.pids.len == 1) j.status = waitStatus(st);
        }
        if (alive == 0) {
            j.state = .done;
            if (j.status == null) j.status = 0;
            j.notified = false;
        }
    }
}

/// print state changes of background jobs before the next prompt
fn jcNotify(a: std.mem.Allocator) void {
    if (!jc) return;
    jcUpdate();
    var k: usize = 0;
    while (k < jobs.items.len) {
        const j = jobs.items[k];
        if (j.num != 0 and !j.notified and j.state != .running) {
            printJobLine(a, j, false, true);
            jobs.items[k].notified = true;
            if (j.state == .done) {
                removeJobAt(k);
                continue;
            }
        }
        k += 1;
    }
}

fn dupPids(pids: []const i32) []i32 {
    return A.dupe(i32, pids) catch &.{};
}

fn jcStopped(pids: []const i32, pgid: i32, node: ?*Node, cmd: []const u8, sig: u8) void {
    var text = cmd;
    if (text.len == 0) {
        if (node) |nd| text = nodeText(A, nd);
    }
    if (findJobIdx(pgid)) |k| {
        jobs.items[k].state = .stopped;
        jobs.items[k].stopsig = sig;
        jobs.items[k].pids = dupPids(pids);
        jobs.items[k].notified = true;
        makeCurrent(jobs.items[k].num);
        printJobLine(A, jobs.items[k], false, true);
        return;
    }
    const num = nextJobNum();
    jobs.push(.{ .pid = pgid, .status = null, .num = num, .state = .stopped, .cmd = text, .pids = dupPids(pids), .stopsig = sig, .notified = true });
    makeCurrent(num);
    u.err("\n");
    printJobLine(A, jobs.items[jobs.items.len - 1], false, true);
}

fn waitForFg(pid: i32) u8 {
    if (!jc) return waitFor(pid);
    var status: u32 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, 2); // WUNTRACED
        if (u.ok(rc)) break;
        if (u.errno(rc) == .INTR) {
            checkTraps();
            continue;
        }
        return 127;
    }
    if ((status & 0xff) == 0x7f) {
        fg_stopped = true;
        return @intCast(128 + ((status >> 8) & 0xff));
    }
    return waitStatus(status);
}

/// wait for a foreground job; records PIPESTATUS when asked
fn waitJob(pids: []const i32, pgid: i32, node: ?*Node, cmd: []const u8, record: bool) u8 {
    var st: u8 = 0;
    fg_stopped = false;
    if (record) pipestatus_n = 0;
    var idx: usize = 0;
    while (idx < pids.len) : (idx += 1) {
        st = waitForFg(pids[idx]);
        if (fg_stopped) break;
        if (record and pipestatus_n < pipestatus.len) {
            pipestatus[pipestatus_n] = st;
            pipestatus_n += 1;
        }
    }
    if (jc) {
        tcSetPgrp(shell_pgid);
        if (fg_stopped) {
            jcStopped(pids[idx..], pgid, node, cmd, st - 128);
            tcRestore();
        } else if (st > 128) tcRestore();
        if (!fg_stopped) if (findJobIdx(pgid)) |k| removeJobAt(k);
    }
    return st;
}

fn jobBySpec(spec0: []const u8) ?usize {
    var spec = spec0;
    if (spec.len > 0 and spec[0] == '%') spec = spec[1..];
    if (spec.len == 0 or std.mem.eql(u8, spec, "+") or std.mem.eql(u8, spec, "%")) {
        const n = curJobNum();
        for (jobs.items, 0..) |j, k| if (j.num == n and n != 0) return k;
        return null;
    }
    if (std.mem.eql(u8, spec, "-")) {
        const n = prevJobNum();
        for (jobs.items, 0..) |j, k| if (j.num == n and n != 0) return k;
        return null;
    }
    if (std.fmt.parseInt(u32, spec, 10)) |n| {
        for (jobs.items, 0..) |j, k| if (j.num == n and n != 0) return k;
        return null;
    } else |_| {}
    var sub = false;
    var pat = spec;
    if (pat.len > 0 and pat[0] == '?') {
        sub = true;
        pat = pat[1..];
    }
    var k = jobs.items.len;
    while (k > 0) {
        k -= 1;
        const j = jobs.items[k];
        if (j.num == 0) continue;
        if (if (sub) std.mem.indexOf(u8, j.cmd, pat) != null else std.mem.startsWith(u8, j.cmd, pat)) return k;
    }
    return null;
}

fn builtinJobs(a: std.mem.Allocator, args: []const []const u8) u8 {
    var long = false;
    var pids_only = false;
    var only_running = false;
    var only_stopped = false;
    var i: usize = 0;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        for (args[i][1..]) |ch| switch (ch) {
            'l' => long = true,
            'p' => pids_only = true,
            'r' => only_running = true,
            's' => only_stopped = true,
            'n' => {},
            else => return builtinErr("jobs", "-{c}: invalid option", .{ch}, 2),
        };
    }
    jcUpdate();
    var st: u8 = 0;
    var want = u.Vec(usize).init(a);
    for (args[i..]) |sp| {
        if (jobBySpec(sp)) |k| want.push(k) else {
            u.errf("sh: jobs: {s}: no such job\n", .{sp});
            st = 1;
        }
    }
    var k: usize = 0;
    while (k < jobs.items.len) {
        const j = jobs.items[k];
        var show = j.num != 0;
        if (args[i..].len > 0) {
            show = false;
            for (want.items) |w| if (w == k) {
                show = true;
            };
        }
        if (only_running and j.state != .running) show = false;
        if (only_stopped and j.state != .stopped) show = false;
        if (show) {
            if (pids_only) u.outf("{d}\n", .{j.pid}) else printJobLine(a, j, long, false);
            jobs.items[k].notified = true;
        }
        if (show and j.state == .done) {
            removeJobAt(k);
            continue;
        }
        k += 1;
    }
    return st;
}

fn builtinFg(a: std.mem.Allocator, args: []const []const u8, is_bg: bool) u8 {
    const nm = if (is_bg) "bg" else "fg";
    if (!jc) return builtinErr("fg", "no job control", .{}, 1);
    var st: u8 = 0;
    var specs = u.Vec([]const u8).init(a);
    for (args) |x| specs.push(x);
    if (specs.items.len == 0) specs.push("%+");
    for (specs.items) |sp| {
        const k = jobBySpec(sp) orelse {
            u.errf("sh: {s}: {s}: no such job\n", .{ nm, if (args.len == 0) "current" else sp });
            st = 1;
            continue;
        };
        const j = jobs.items[k];
        if (is_bg) {
            if (j.state == .running) {
                u.errf("sh: bg: job {d} already in background\n", .{j.num});
                st = 1;
                continue;
            }
            _ = linux.kill(-j.pid, @enumFromInt(18)); // SIGCONT
            jobs.items[k].state = .running;
            jobs.items[k].notified = true;
            makeCurrent(j.num);
            u.outf("[{d}]{c} {s} &\n", .{ j.num, @as(u8, if (j.num == curJobNum()) '+' else if (j.num == prevJobNum()) '-' else ' '), j.cmd });
            continue;
        }
        u.outf("{s}\n", .{j.cmd});
        jobs.items[k].state = .running;
        makeCurrent(j.num);
        tcSetPgrp(j.pid);
        if (j.state == .stopped) _ = linux.kill(-j.pid, @enumFromInt(18));
        st = waitJob(j.pids, j.pid, null, j.cmd, false);
    }
    return st;
}

fn builtinDisown(a: std.mem.Allocator, args: []const []const u8) u8 {
    _ = a;
    var st: u8 = 0;
    var all = false;
    var any = false;
    for (args) |x| {
        if (x.len > 1 and x[0] == '-') {
            for (x[1..]) |ch| if (ch == 'a') {
                all = true;
            };
            continue;
        }
        any = true;
        const k = jobBySpec(x) orelse {
            u.errf("sh: disown: {s}: no such job\n", .{x});
            st = 1;
            continue;
        };
        removeJobAt(k);
    }
    if (all) jobs.items.len = 0;
    if (!any and !all) {
        if (jobBySpec("%+")) |k| removeJobAt(k) else st = 1;
    }
    return st;
}

/// rewrite %n arguments of kill into process-group targets
fn killArgs(a: std.mem.Allocator, argv: []const []const u8) []const []const u8 {
    var has = false;
    for (argv[1..]) |x| if (x.len > 0 and x[0] == '%') {
        has = true;
    };
    if (!has) return argv;
    var out = u.Vec([]const u8).init(a);
    out.push(argv[0]);
    var dashed = false;
    for (argv[1..]) |x| {
        if (x.len > 0 and x[0] == '%') {
            if (jobBySpec(x)) |k| {
                if (!dashed) {
                    out.push("--");
                    dashed = true;
                }
                out.push(std.fmt.allocPrint(a, "-{d}", .{jobs.items[k].pid}) catch x);
            } else {
                u.errf("sh: kill: {s}: no such job\n", .{x});
                out.push("0");
            }
        } else out.push(x);
    }
    return out.items;
}

fn reapBg() void {
    if (jc) {
        jcNotify(A);
        return;
    }
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
        setSignal(20, .dfl);
        setSignal(21, .dfl);
        setSignal(22, .dfl);
    }
    jc = false;
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
    const tt = std.mem.trim(u8, text, " \t\n");
    if (tt.len > 1 and tt[0] == '<' and tt[1] != '<' and tt[1] != '(' and tt[1] != '&') {
        const wd = std.mem.trim(u8, tt[1..], " \t");
        if (wd.len > 0 and std.mem.indexOfAny(u8, wd, " \t\n;&|<>()") == null) {
            const path = try expandOne(a, wd, false);
            if (readWhole(path)) |data| {
                var d = data;
                while (d.len > 0 and d[d.len - 1] == '\n') d = d[0 .. d.len - 1];
                last_status = 0;
                cmdsub_status = 0;
                return a.dupe(u8, d) catch return error.OutOfMemory;
            }
            u.errf("sh: {s}: No such file or directory\n", .{path});
            last_status = 1;
            cmdsub_status = 1;
            return "";
        }
    }
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

const PsEntry = struct { fd: i32, pid: i32 };
var ps_list = u.Vec(PsEntry).init(A);

fn procSubst(a: std.mem.Allocator, text: []const u8, is_input: bool) ShErr![]const u8 {
    var fds: [2]i32 = undefined;
    if (u.errno(linux.pipe(&fds)) != .SUCCESS) return fatal(1, "cannot create pipe", .{});
    const pid_raw = linux.fork();
    if (u.errno(pid_raw) != .SUCCESS) return fatal(1, "fork failed", .{});
    if (pid_raw == 0) {
        for (ps_list.items) |pe| _ = linux.close(pe.fd);
        if (is_input) {
            _ = linux.close(fds[0]);
            _ = linux.dup2(fds[1], 1);
            _ = linux.close(fds[1]);
        } else {
            _ = linux.close(fds[1]);
            _ = linux.dup2(fds[0], 0);
            _ = linux.close(fds[0]);
        }
        childInit();
        const st = evalString(text);
        exitChild(st);
    }
    const mine = if (is_input) fds[0] else fds[1];
    _ = linux.close(if (is_input) fds[1] else fds[0]);
    ps_list.push(.{ .fd = mine, .pid = @intCast(pid_raw) });
    return std.fmt.allocPrint(a, "/dev/fd/{d}", .{mine}) catch return error.OutOfMemory;
}

fn psCleanup(mark: usize) void {
    while (ps_list.items.len > mark) {
        const pe = ps_list.items[ps_list.items.len - 1];
        ps_list.pop();
        _ = linux.close(pe.fd);
        var status: u32 = 0;
        _ = linux.wait4(pe.pid, &status, 0, null);
    }
}

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
    for (redirs) |r0| {
        var r = r0;
        if (r.fdvar.len > 0) {
            if ((r.op == .dup_out or r.op == .dup_in) and std.mem.eql(u8, r.word, "-")) {
                const fv = getVar(r.fdvar) orelse return redirErr("{s}: ambiguous redirect", .{r.fdvar});
                const nfd = std.fmt.parseInt(i32, fv, 10) catch return redirErr("{s}: bad fd number", .{fv});
                _ = linux.close(nfd);
                continue;
            }
            const nf = linux.fcntl(2, 0, 10);
            if (!u.ok(nf)) return redirErr("cannot allocate a file descriptor", .{});
            r.fd = @intCast(nf);
            if (!setVar(r.fdvar, fmtU(a, nf))) return false;
        }
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
            .herestr => {
                var e = Exp.init(a, false);
                expandInto(&e, r.word, false, false) catch return false;
                e.finish();
                var o = u.Vec(u8).init(a);
                for (e.fields.items) |f| o.pushSlice(f.buf);
                o.push('\n');
                const mfd = linux.memfd_create("sh-herestring", 0);
                if (!u.ok(mfd)) return redirErr("cannot create here-string", .{});
                const fd: i32 = @intCast(mfd);
                var off: usize = 0;
                while (off < o.items.len) {
                    const w = linux.write(fd, o.items.ptr + off, o.items.len - off);
                    if (!u.ok(w)) break;
                    off += w;
                }
                _ = linux.syscall3(.lseek, @as(usize, @intCast(fd)), 0, 0);
                if (!moveFd(fd, r.fd)) return redirErr("here-string failed", .{});
            },
            .both_out, .both_append => {
                const path = expandOne(a, r.word, false) catch return false;
                var flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = r.op == .both_out, .APPEND = r.op == .both_append };
                if (r.op == .both_out and opt_C) {
                    if (u.stat(path, true)) |st| {
                        if (st.mode & linux.S.IFMT == linux.S.IFREG) return redirErr("cannot create {s}: File exists", .{path});
                    }
                }
                flags.EXCL = false;
                const rc = linux.open(u.zstr(path), flags, 0o666);
                if (!u.ok(rc)) return redirErr("cannot create {s}: {s}", .{ path, u.strerr(u.errno(rc)) });
                saveFd(saves, 2);
                if (!u.ok(linux.dup2(@intCast(rc), 2))) return redirErr("2: Bad file descriptor", .{});
                if (!moveFd(@intCast(rc), 1)) return redirErr("1: Bad file descriptor", .{});
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
        .subshell, .group, .if_, .while_, .until_, .for_, .case_, .for_arith, .dbracket, .arith, .select_ => execCompound(n),
        .time_ => execTime(n),
        .funcdef => blk: {
            const key = A.dupe(u8, n.name) catch break :blk 1;
            funcs.put(A, key, n.children[0]) catch break :blk 1;
            break :blk 0;
        },
    };
    last_status = st;
    switch (n.kind) {
        .simple, .subshell, .group, .if_, .while_, .until_, .for_, .case_, .for_arith, .dbracket, .arith => {
            pipestatus[0] = st;
            pipestatus_n = 1;
        },
        else => {},
    }
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
        jcChild(0, false);
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
    jcParent(last_bg, 0, false);
    if (jc) {
        const num = nextJobNum();
        jobs.push(.{ .pid = last_bg, .status = null, .num = num, .cmd = nodeText(A, n), .pids = dupPids(&.{last_bg}), .notified = true });
        makeCurrent(num);
        u.errf("[{d}] {d}\n", .{ num, last_bg });
    } else jobs.push(.{ .pid = last_bg, .status = null });
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
        if (i + 1 == count and sh_lastpipe and !interactive and prev_read >= 0) {
            // last element runs in the current shell
            const saved0 = linux.dup(0);
            _ = linux.dup2(prev_read, 0);
            _ = linux.close(prev_read);
            prev_read = -1;
            const lst = execNode(n.children[i]);
            if (u.ok(saved0)) {
                _ = linux.dup2(@intCast(saved0), 0);
                _ = linux.close(@intCast(saved0));
            }
            lastpipe_status = lst;
            lastpipe_ran = true;
            break;
        }
        const pid_raw = linux.fork();
        if (u.errno(pid_raw) != .SUCCESS) {
            u.err("sh: fork failed\n");
            break;
        }
        if (pid_raw == 0) {
            jcChild(if (pids.items.len > 0) pids.items[0] else 0, true);
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
        jcParent(@intCast(pid_raw), if (pids.items.len > 0) pids.items[0] else 0, true);
        pids.push(@intCast(pid_raw));
        if (prev_read >= 0) _ = linux.close(prev_read);
        if (fds[1] >= 0) _ = linux.close(fds[1]);
        prev_read = fds[0];
    }
    if (prev_read >= 0) _ = linux.close(prev_read);
    var st: u8 = 0;
    var any_fail: u8 = 0;
    if (pids.items.len > 0) {
        st = waitJob(pids.items, pids.items[0], n, "", true);
        for (pipestatus[0..pipestatus_n]) |ps| if (ps != 0) {
            any_fail = ps;
        };
        if (fg_stopped) any_fail = st;
    } else pipestatus_n = 0;
    if (lastpipe_ran) {
        lastpipe_ran = false;
        st = lastpipe_status;
        if (st != 0) any_fail = st;
        if (pipestatus_n < pipestatus.len) {
            pipestatus[pipestatus_n] = st;
            pipestatus_n += 1;
        }
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
    const ps_mark = ps_list.items.len;
    defer psCleanup(ps_mark);
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
        .for_arith => execForArith(n, a),
        .select_ => execSelect(n, a),
        .case_ => execCase(n, a),
        .dbracket => execDbracket(n, a),
        .arith => execArithCmd(n, a),
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
        jcChild(0, true);
        childInit();
        if (n.redirs.len > 0 and !applyRedirs(a, n.redirs, null)) linux.exit_group(1);
        const st = execNode(n.children[0]);
        exitChild(st);
    }
    jcParent(@intCast(pid_raw), 0, true);
    const one = [1]i32{@intCast(pid_raw)};
    const st = waitJob(&one, @intCast(pid_raw), n, "", false);
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
    var st: u8 = 0;
    var i: usize = 0;
    var forced = false; // ";&" runs the next body without testing
    while (i < n.cases.len) : (i += 1) {
        const item = n.cases[i];
        var hit = forced;
        forced = false;
        if (!hit) for (item.patterns) |p| {
            const pat = patternFrom(a, p, false) catch return last_status;
            if (fnm(pat, word)) {
                hit = true;
                break;
            }
        };
        if (!hit) continue;
        st = if (item.body) |b| execNode(b) else 0;
        if (item.term == 1) {
            forced = true;
            continue;
        }
        if (item.term == 2) continue;
        return st;
    }
    return st;
}

fn arithText(a: std.mem.Allocator, expr: []const u8) ?i64 {
    var e = Exp.init(a, false);
    expandInto(&e, expr, true, false) catch return null;
    e.finish();
    var o = u.Vec(u8).init(a);
    for (e.fields.items) |f| o.pushSlice(f.buf);
    return evalArith(a, o.items) catch null;
}

fn execArithCmd(n: *Node, a: std.mem.Allocator) u8 {
    const v = arithText(a, n.words[0]) orelse {
        last_status = 1;
        return 1;
    };
    return if (v != 0) 0 else 1;
}

fn execForArith(n: *Node, a: std.mem.Allocator) u8 {
    var st: u8 = 0;
    if (n.words[0].len > 0) _ = arithText(a, n.words[0]) orelse return 1;
    loop_depth += 1;
    defer loop_depth -= 1;
    while (true) {
        if (n.words[1].len > 0) {
            const c0 = arithText(a, n.words[1]) orelse return 1;
            if (c0 == 0) break;
        }
        st = execNode(n.children[0]);
        checkTraps();
        if (loopFlow() == .stop) break;
        if (n.words[2].len > 0) _ = arithText(a, n.words[2]) orelse return 1;
    }
    return st;
}

fn execSelect(n: *Node, a: std.mem.Allocator) u8 {
    var items = u.Vec([]const u8).init(a);
    if (n.has_in) {
        const w = expandWords(a, n.words) catch return last_status;
        for (w) |x| items.push(x);
    } else for (pos_args.items) |x| items.push(x);
    if (items.items.len == 0) return 0;
    var st: u8 = 0;
    loop_depth += 1;
    defer loop_depth -= 1;
    var show = true;
    while (true) {
        if (show) {
            for (items.items, 0..) |it, k| u.errf("{d}) {s}\n", .{ k + 1, it });
        }
        show = false;
        u.err(getVar("PS3") orelse "#? ");
        var line = u.Vec(u8).init(a);
        var got = false;
        while (true) {
            const b = readByte(0) orelse break;
            got = true;
            if (b == '\n') break;
            line.push(b);
        }
        if (!got) {
            u.err("\n");
            break;
        }
        _ = setVar("REPLY", line.items);
        const num = std.fmt.parseInt(usize, std.mem.trim(u8, line.items, " \t"), 10) catch 0;
        if (line.items.len == 0) {
            show = true;
            continue;
        }
        _ = setVar(n.name, if (num >= 1 and num <= items.items.len) items.items[num - 1] else "");
        st = execNode(n.children[0]);
        checkTraps();
        if (loopFlow() == .stop) break;
    }
    return st;
}

fn execTime(n: *Node) u8 {
    var t0: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &t0);
    var ru0: c.struct_rusage = undefined;
    _ = c.getrusage(c.RUSAGE_CHILDREN, &ru0);
    var self0: c.struct_rusage = undefined;
    _ = c.getrusage(c.RUSAGE_SELF, &self0);
    const st = execNode(n.children[0]);
    var t1: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &t1);
    var ru1: c.struct_rusage = undefined;
    _ = c.getrusage(c.RUSAGE_CHILDREN, &ru1);
    var self1: c.struct_rusage = undefined;
    _ = c.getrusage(c.RUSAGE_SELF, &self1);
    const real_ms: i64 = (@as(i64, @intCast(t1.sec)) - @as(i64, @intCast(t0.sec))) * 1000 + @divTrunc(@as(i64, @intCast(t1.nsec)) - @as(i64, @intCast(t0.nsec)), 1000000);
    const user_ms: i64 = (@as(i64, @intCast(ru1.ru_utime.tv_sec)) - @as(i64, @intCast(ru0.ru_utime.tv_sec)) + @as(i64, @intCast(self1.ru_utime.tv_sec)) - @as(i64, @intCast(self0.ru_utime.tv_sec))) * 1000 + @divTrunc(@as(i64, @intCast(ru1.ru_utime.tv_usec)) - @as(i64, @intCast(ru0.ru_utime.tv_usec)) + @as(i64, @intCast(self1.ru_utime.tv_usec)) - @as(i64, @intCast(self0.ru_utime.tv_usec)), 1000);
    const sys_ms: i64 = (@as(i64, @intCast(ru1.ru_stime.tv_sec)) - @as(i64, @intCast(ru0.ru_stime.tv_sec)) + @as(i64, @intCast(self1.ru_stime.tv_sec)) - @as(i64, @intCast(self0.ru_stime.tv_sec))) * 1000 + @divTrunc(@as(i64, @intCast(ru1.ru_stime.tv_usec)) - @as(i64, @intCast(ru0.ru_stime.tv_usec)) + @as(i64, @intCast(self1.ru_stime.tv_usec)) - @as(i64, @intCast(self0.ru_stime.tv_usec)), 1000);
    const rs = @max(real_ms, 0);
    const us = @max(user_ms, 0);
    const ss = @max(sys_ms, 0);
    if (n.has_in) {
        u.errf("real {d}.{d:0>2}\nuser {d}.{d:0>2}\nsys {d}.{d:0>2}\n", .{ @divTrunc(rs, 1000), @divTrunc(@mod(rs, 1000), 10), @divTrunc(us, 1000), @divTrunc(@mod(us, 1000), 10), @divTrunc(ss, 1000), @divTrunc(@mod(ss, 1000), 10) });
    } else {
        u.errf("\nreal\t{d}m{d}.{d:0>3}s\nuser\t{d}m{d}.{d:0>3}s\nsys\t{d}m{d}.{d:0>3}s\n", .{ @divTrunc(rs, 60000), @divTrunc(@mod(rs, 60000), 1000), @mod(rs, 1000), @divTrunc(us, 60000), @divTrunc(@mod(us, 60000), 1000), @mod(us, 1000), @divTrunc(ss, 60000), @divTrunc(@mod(ss, 60000), 1000), @mod(ss, 1000) });
    }
    return st;
}

// ----- [[ ... ]] -----
const DB = struct {
    a: std.mem.Allocator,
    t: []const []const u8,
    i: usize = 0,
    bad: bool = false,

    fn peek(self: *DB) ?[]const u8 {
        return if (self.i < self.t.len) self.t[self.i] else null;
    }

    fn isOp(tok: []const u8) bool {
        return std.mem.eql(u8, tok, "&&") or std.mem.eql(u8, tok, "||") or std.mem.eql(u8, tok, "(") or std.mem.eql(u8, tok, ")");
    }

    fn isBinary(tok: []const u8) bool {
        const ops = [_][]const u8{ "==", "=", "!=", "=~", "<", ">", "-eq", "-ne", "-lt", "-le", "-gt", "-ge", "-nt", "-ot", "-ef" };
        for (ops) |o| if (std.mem.eql(u8, o, tok)) return true;
        return false;
    }

    fn isUnary(tok: []const u8) bool {
        if (tok.len != 2 or tok[0] != '-') return false;
        return std.mem.indexOfScalar(u8, "abcdefghkprstuwxzGLNOSnovR", tok[1]) != null;
    }

    fn orExpr(self: *DB, live: bool) bool {
        var r = self.andExpr(live);
        while (self.peek()) |t| {
            if (!std.mem.eql(u8, t, "||")) break;
            self.i += 1;
            const r2 = self.andExpr(live and !r);
            r = r or r2;
        }
        return r;
    }

    fn andExpr(self: *DB, live: bool) bool {
        var r = self.notExpr(live);
        while (self.peek()) |t| {
            if (!std.mem.eql(u8, t, "&&")) break;
            self.i += 1;
            const r2 = self.notExpr(live and r);
            r = r and r2;
        }
        return r;
    }

    fn notExpr(self: *DB, live: bool) bool {
        if (self.peek()) |t| if (std.mem.eql(u8, t, "!")) {
            self.i += 1;
            return !self.notExpr(live);
        };
        return self.primary(live);
    }

    fn word(self: *DB, raw: []const u8) []const u8 {
        return expandOne(self.a, raw, false) catch {
            self.bad = true;
            return "";
        };
    }

    fn primary(self: *DB, live: bool) bool {
        const t = self.peek() orelse {
            self.bad = true;
            return false;
        };
        if (std.mem.eql(u8, t, "(")) {
            self.i += 1;
            const r = self.orExpr(live);
            if (self.peek()) |c1| if (std.mem.eql(u8, c1, ")")) {
                self.i += 1;
                return r;
            };
            self.bad = true;
            return false;
        }
        if (isUnary(t) and self.i + 1 < self.t.len and !isOp(self.t[self.i + 1]) and !(self.i + 2 < self.t.len and isBinary(self.t[self.i + 1]))) {
            self.i += 1;
            const arg_raw = self.t[self.i];
            self.i += 1;
            if (!live) return false;
            return self.unary(t[1], self.word(arg_raw));
        }
        self.i += 1;
        if (self.peek()) |op| if (isBinary(op) and self.i + 1 < self.t.len) {
            self.i += 1;
            const rhs_raw = self.t[self.i];
            self.i += 1;
            if (!live) return false;
            return self.binary(t, op, rhs_raw);
        };
        if (!live) return false;
        return self.word(t).len > 0;
    }

    fn unary(self: *DB, op: u8, arg: []const u8) bool {
        switch (op) {
            'z' => return arg.len == 0,
            'n' => return arg.len > 0,
            'o' => return optEnabled(arg),
            'v' => return getVar(arg) != null or std.mem.indexOfScalar(u8, arg, '[') != null and lookup(self.a, arg) != null,
            't' => return isTty(std.fmt.parseInt(i32, arg, 10) catch return false),
            'R' => return false,
            else => {},
        }
        const z = u.zstr(arg);
        switch (op) {
            'r' => return u.ok(linux.access(z, 4)),
            'w' => return u.ok(linux.access(z, 2)),
            'x' => return u.ok(linux.access(z, 1)),
            else => {},
        }
        const follow = op != 'h' and op != 'L';
        const st = u.stat(arg, follow) orelse return false;
        const ty = st.mode & linux.S.IFMT;
        return switch (op) {
            'a', 'e' => true,
            'b' => ty == linux.S.IFBLK,
            'c' => ty == linux.S.IFCHR,
            'd' => ty == linux.S.IFDIR,
            'f' => ty == linux.S.IFREG,
            'g' => st.mode & 0o2000 != 0,
            'h', 'L' => ty == linux.S.IFLNK,
            'k' => st.mode & 0o1000 != 0,
            'p' => ty == linux.S.IFIFO,
            's' => st.size > 0,
            'u' => st.mode & 0o4000 != 0,
            'G' => st.gid == c.getegid(),
            'O' => st.uid == c.geteuid(),
            'S' => ty == linux.S.IFSOCK,
            'N' => st.mtime > st.atime,
            else => false,
        };
    }

    fn binary(self: *DB, lhs_raw: []const u8, op: []const u8, rhs_raw: []const u8) bool {
        const lhs = self.word(lhs_raw);
        if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "!=")) {
            const pat = patternFrom(self.a, rhs_raw, false) catch {
                self.bad = true;
                return false;
            };
            const m = fnmAlwaysExt(pat, lhs);
            return if (op[0] == '!') !m else m;
        }
        if (std.mem.eql(u8, op, "=~")) return self.regexMatch(lhs, rhs_raw);
        if (std.mem.eql(u8, op, "<")) return std.mem.order(u8, lhs, self.word(rhs_raw)) == .lt;
        if (std.mem.eql(u8, op, ">")) return std.mem.order(u8, lhs, self.word(rhs_raw)) == .gt;
        const rhs = self.word(rhs_raw);
        if (op[1] == 'n' and op[2] == 't' or op[1] == 'o' and op[2] == 't' or op[1] == 'e' and op[2] == 'f') {
            const l = u.stat(lhs, true);
            const r = u.stat(rhs, true);
            if (std.mem.eql(u8, op, "-nt")) return l != null and (r == null or l.?.mtime > r.?.mtime or (l.?.mtime == r.?.mtime and l.?.mtime_nsec > r.?.mtime_nsec));
            if (std.mem.eql(u8, op, "-ot")) return r != null and (l == null or l.?.mtime < r.?.mtime or (l.?.mtime == r.?.mtime and l.?.mtime_nsec < r.?.mtime_nsec));
            return l != null and r != null and l.?.dev == r.?.dev and l.?.ino == r.?.ino;
        }
        const li = arithText(self.a, lhs) orelse {
            self.bad = true;
            return false;
        };
        const ri = arithText(self.a, rhs) orelse {
            self.bad = true;
            return false;
        };
        if (std.mem.eql(u8, op, "-eq")) return li == ri;
        if (std.mem.eql(u8, op, "-ne")) return li != ri;
        if (std.mem.eql(u8, op, "-lt")) return li < ri;
        if (std.mem.eql(u8, op, "-le")) return li <= ri;
        if (std.mem.eql(u8, op, "-gt")) return li > ri;
        return li >= ri;
    }

    fn regexMatch(self: *DB, text: []const u8, rhs_raw: []const u8) bool {
        var e = Exp.init(self.a, false);
        expandInto(&e, rhs_raw, false, false) catch {
            self.bad = true;
            return false;
        };
        e.finish();
        var pat = u.Vec(u8).init(self.a);
        for (e.fields.items) |f| for (f.buf, 0..) |ch, k| {
            if (f.q[k] and std.mem.indexOfScalar(u8, "\\.[]{}()*+?^$|", ch) != null) pat.push('\\');
            pat.push(ch);
        };
        var re = regex.Regex.init(pat.items, true, nocasematch) orelse {
            self.bad = true;
            return false;
        };
        defer re.deinit();
        const m = re.find(text, 0) orelse {
            setRematch(self.a, null, text);
            return false;
        };
        setRematch(self.a, m, text);
        return true;
    }
};

fn execDbracket(n: *Node, a: std.mem.Allocator) u8 {
    var db = DB{ .a = a, .t = n.words };
    const r = db.orExpr(true);
    if (db.bad or db.i < db.t.len) {
        if (last_status == 0 or !db.bad) u.err("sh: conditional expression: syntax error\n");
        last_status = 2;
        return 2;
    }
    return if (r) 0 else 1;
}

var nocasematch = false;

fn optEnabled(name: []const u8) bool {
    if (std.mem.eql(u8, name, "errexit")) return opt_e;
    if (std.mem.eql(u8, name, "nounset")) return opt_u;
    if (std.mem.eql(u8, name, "noglob")) return opt_f;
    if (std.mem.eql(u8, name, "xtrace")) return opt_x;
    if (std.mem.eql(u8, name, "verbose")) return opt_v;
    if (std.mem.eql(u8, name, "noexec")) return opt_n;
    if (std.mem.eql(u8, name, "noclobber")) return opt_C;
    if (std.mem.eql(u8, name, "allexport")) return opt_a;
    if (std.mem.eql(u8, name, "pipefail")) return opt_pipefail;
    if (std.mem.eql(u8, name, "braceexpand")) return opt_B;
    return false;
}

fn setRematch(a: std.mem.Allocator, m: ?regex.Match, text: []const u8) void {
    const v = getOrCreateVar("BASH_REMATCH") orelse return;
    const ar = newArr(false);
    if (m) |mm| {
        var last: usize = 0;
        for (mm.groups, 0..) |g, ix| if (g != null) {
            last = ix;
        };
        for (mm.groups[0 .. last + 1], 0..) |g, ix| {
            arrPut(ar, fmtU(a, ix), if (g) |gg| text[gg.start..gg.end] else "");
        }
    }
    v.arr = ar;
    arrSync(v);
}

// ----- simple commands -----
const inproc_applets = [_][]const u8{ "echo", "printf", "test", "[", "[[", "true", "false", "kill", "pwd", "basename", "dirname" };

fn isInproc(name: []const u8) bool {
    for (inproc_applets) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

const builtin_names = [_][]const u8{ ":", ".", "source", "break", "continue", "eval", "exec", "exit", "export", "readonly", "return", "set", "shift", "times", "trap", "unset", "alias", "unalias", "cd", "read", "command", "type", "hash", "wait", "umask", "getopts", "local", "ulimit", "jobs", "fg", "bg", "let", "declare", "typeset", "mapfile", "readarray", "shopt", "pushd", "popd", "dirs", "disown", "builtin", "complete", "compopt", "bind", "history" };

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

var func_names = u.Vec([]const u8).init(A);
var trap_return: ?[]const u8 = null;
var trap_return_depth: u32 = 0;

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
    func_names.push(argv[0]);
    const base = locals.items.len;
    const st = execNode(body);
    var rs = st;
    if (flow == .return_) {
        rs = @intCast(flow_n & 0xff);
        flow = .none;
    }
    if (trap_return) |tr| {
        if (trap_return_depth == func_depth and func_depth > 0) {
            const sv = last_status;
            _ = evalString(tr);
            last_status = sv;
        }
    }
    func_names.pop();
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
    const ps_mark = ps_list.items.len;
    defer psCleanup(ps_mark);
    cur_line = n.line;
    cmdsub_status = 0;
    var arena = std.heap.ArenaAllocator.init(A);
    defer arena.deinit();
    const a = arena.allocator();

    var pend = u.Vec(Pend).init(a);
    var words_use = n.words;
    if (n.words.len > 1 and isDeclCmd(n.words[0])) {
        var fw = u.Vec([]const u8).init(a);
        for (n.words, 0..) |w, wi| {
            if (wi > 0) if (arrayLitWord(w)) |al| {
                pend.push(al);
                fw.push(al.name);
                continue;
            };
            fw.push(w);
        }
        words_use = fw.items;
    }
    const argv = expandWords(a, words_use) catch return if (last_status == 0) 1 else last_status;

    // assignments
    var assign_strs = u.Vec([]const u8).init(a);
    for (n.assigns) |as| {
        if (!isPlainAssign(as)) {
            assign_strs.push("");
            continue;
        }
        const v = expandOne(a, as.value, true) catch return if (last_status == 0) 1 else last_status;
        assign_strs.push(std.fmt.allocPrint(a, "{s}={s}", .{ as.name, v }) catch return 1);
    }

    if (argv.len == 0) {
        var st: u8 = cmdsub_status;
        for (n.assigns, 0..) |as, i| {
            const eq = assign_strs.items[i];
            const okay = if (isPlainAssign(as)) setVar(as.name, eq[as.name.len + 1 ..]) else applyAssign(a, as);
            if (!okay) {
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
            const base = if (std.mem.indexOfScalar(u8, as.name, '[')) |b| as.name[0..b] else as.name;
            if (!persist) olds.push(.{ .name = base, .old = copyVar(vars.get(base)) });
            if (isPlainAssign(as)) _ = setVar(as.name, eq[as.name.len + 1 ..]) else _ = applyAssign(a, as);
            if (!persist) {
                if (vars.getPtr(base)) |p| {
                    p.exported = true;
                    u.setEnv(base, p.val);
                }
            }
        }
        var st: u8 = 0;
        if (func) |body| {
            st = callFunction(body, argv);
        } else if (builtin) {
            st = runBuiltin(a, argv);
            if (pend.items.len > 0) {
                const ps = applyPending(a, pend.items);
                if (st == 0) st = ps;
            }
        } else if (std.mem.eql(u8, name, "kill") and argv.len > 1) {
            const kargs = killArgs(a, argv);
            st = appletFn("kill").?(kargs[1..]);
        } else if (std.mem.eql(u8, name, "printf") and argv.len >= 3 and std.mem.eql(u8, argv[1], "-v")) {
            st = printfToVar(a, argv);
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
        jcChild(0, true);
        childInit();
        if (!applyRedirs(a, n.redirs, null)) linux.exit_group(1);
        childRestoreSignals();
        const code = execExternal(a, argv, assign_strs.items);
        linux.exit_group(code);
    }
    jcParent(@intCast(pid_raw), 0, true);
    const one = [1]i32{@intCast(pid_raw)};
    const st = waitJob(&one, @intCast(pid_raw), n, "", false);
    checkTraps();
    errCheck(st);
    return st;
}

fn printfToVar(a: std.mem.Allocator, argv: []const []const u8) u8 {
    const target = argv[2];
    const mfd = linux.memfd_create("sh-printf", 0);
    if (!u.ok(mfd)) return 1;
    const fd: i32 = @intCast(mfd);
    const saved = linux.dup(1);
    if (!u.ok(saved)) return 1;
    _ = linux.dup2(fd, 1);
    u.flush();
    const st = appletFn("printf").?(argv[3..]);
    u.flush();
    _ = linux.dup2(@intCast(saved), 1);
    _ = linux.close(@intCast(saved));
    _ = linux.syscall3(.lseek, @as(usize, @intCast(fd)), 0, 0);
    var all = u.Vec(u8).init(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const r = linux.read(fd, &buf, buf.len);
        if (!u.ok(r) or r == 0) break;
        all.pushSlice(buf[0..r]);
    }
    _ = linux.close(fd);
    if (splitSubscript(target)) |ss| {
        if (!setElem(a, ss.name, ss.sub, all.items, false)) return 1;
    } else if (!validName(target)) {
        u.errf("sh: printf: `{s}': not a valid identifier\n", .{target});
        return 2;
    } else if (!setVar(target, all.items)) return 1;
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
        setSignal(20, .dfl);
        setSignal(21, .dfl);
        setSignal(22, .dfl);
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
    if (std.mem.eql(u8, s, "RETURN")) return 66;
    if (std.mem.eql(u8, s, "DEBUG")) return 67;
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
            if (funcs_mode) {
                _ = funcs.remove(x);
            } else if (splitSubscript(x)) |ss| {
                if (vars.getPtr(ss.name)) |vp| {
                    if (ss.sub.len == 1 and (ss.sub[0] == '@' or ss.sub[0] == '*')) {
                        _ = unsetVar(ss.name);
                    } else if (vp.arr) |ar| {
                        if (subKey(a, ar, ss.sub)) |kk| arrDel(ar, kk);
                        arrSync(vp);
                    } else if ((arithText(a, ss.sub) orelse 1) == 0) _ = unsetVar(ss.name);
                }
            } else if (!unsetVar(x)) st = 1;
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
    if (eq(u8, name, "type")) return builtinType(a, args);
    if (eq(u8, name, "hash")) return 0;
    if (eq(u8, name, "wait")) return builtinWait(args);
    if (eq(u8, name, "umask")) return builtinUmask(args);
    if (eq(u8, name, "getopts")) return builtinGetopts(a, args);
    if (eq(u8, name, "local")) return builtinDeclare(a, args, true);
    if (eq(u8, name, "declare") or eq(u8, name, "typeset")) return builtinDeclare(a, args, false);
    if (eq(u8, name, "mapfile") or eq(u8, name, "readarray")) return builtinMapfile(a, args);
    if (eq(u8, name, "shopt")) return builtinShopt(a, args);
    if (eq(u8, name, "pushd")) return builtinPushd(a, args);
    if (eq(u8, name, "popd")) return builtinPopd(a, args);
    if (eq(u8, name, "dirs")) return builtinDirs(a, args);
    if (eq(u8, name, "disown")) return builtinDisown(a, args);
    if (eq(u8, name, "complete") or eq(u8, name, "compopt") or eq(u8, name, "bind") or eq(u8, name, "history")) return 0;
    if (eq(u8, name, "builtin")) {
        if (args.len == 0) return 0;
        if (isBuiltin(args[0])) return runBuiltin(a, args);
        if (isInproc(args[0])) return appletFn(args[0]).?(args[1..]);
        return builtinErr("builtin", "{s}: not a shell builtin", .{args[0]}, 1);
    }
    if (eq(u8, name, "ulimit")) return builtinUlimit(args);
    if (eq(u8, name, "jobs")) return builtinJobs(a, args);
    if (eq(u8, name, "fg")) return builtinFg(a, args, false);
    if (eq(u8, name, "bg")) return builtinFg(a, args, true);
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
                for (lst) |l| u.outf("{s: <20}{s}\n", .{ l.n, if (l.v) "on" else "off" });
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
    if (args.len >= 1 and std.mem.eql(u8, args[0], "-p") and args.len > 1) {
        for (args[1..]) |nm| {
            const sg = sigByName(nm) orelse continue;
            const cmd2: ?[]const u8 = if (sg == 0) trap_exit else if (sg == 65) trap_err else if (sg == 66) trap_return else if (sg < 65) trap_cmd[sg] else null;
            if (cmd2) |cc| u.outf("trap -- {s} {s}\n", .{ quoteSingle(a, cc), nm });
        }
        return 0;
    }
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
        } else if (sig == 66) {
            trap_return = if (stored != null and stored.?.len == 0) null else stored;
            trap_return_depth = func_depth;
        } else if (sig == 67) {
            // DEBUG traps are accepted but never fire
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
    var delim: ?u8 = '\n';
    var nchars: ?usize = null;
    var exact = false;
    var arr_name: ?[]const u8 = null;
    var fd: i32 = 0;
    var timeout_ms: ?i32 = null;
    var i: usize = 0;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        var k: usize = 1;
        while (k < args[i].len) : (k += 1) {
            const ch = args[i][k];
            switch (ch) {
                'r' => raw = true,
                's', 'e' => {},
                'p', 'd', 'n', 'N', 'a', 't', 'u', 'i' => {
                    var optarg: []const u8 = "";
                    if (k + 1 < args[i].len) {
                        optarg = args[i][k + 1 ..];
                    } else if (i + 1 < args.len) {
                        i += 1;
                        optarg = args[i];
                    } else return builtinErr("read", "-{c}: option requires an argument", .{ch}, 2);
                    k = args[i].len;
                    switch (ch) {
                        'p' => prompt = optarg,
                        'd' => delim = if (optarg.len == 0) 0 else optarg[0],
                        'n', 'N' => {
                            nchars = std.fmt.parseInt(usize, optarg, 10) catch return builtinErr("read", "{s}: invalid number", .{optarg}, 2);
                            if (ch == 'N') exact = true;
                        },
                        'a' => arr_name = optarg,
                        't' => {
                            const f = std.fmt.parseFloat(f64, optarg) catch return builtinErr("read", "{s}: invalid timeout specification", .{optarg}, 2);
                            timeout_ms = @intFromFloat(f * 1000);
                        },
                        'u' => fd = std.fmt.parseInt(i32, optarg, 10) catch return builtinErr("read", "{s}: invalid file descriptor specification", .{optarg}, 2),
                        else => {},
                    }
                },
                else => return builtinErr("read", "-{c}: invalid option", .{ch}, 2),
            }
        }
    }
    if (prompt) |pr| if (isTty(fd)) u.err(pr);
    var vnames = u.Vec([]const u8).init(a);
    for (args[i..]) |x| vnames.push(x);
    if (vnames.items.len == 0 and arr_name == null) vnames.push("REPLY");
    var line = u.Vec(u8).init(a);
    var eof = false;
    var timed_out = false;
    var escaped_mask = u.Vec(bool).init(a);
    while (true) {
        if (nchars) |nc| if (line.items.len >= nc) break;
        if (timeout_ms) |tm| {
            var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
            const pr = linux.poll(&pfd, 1, tm);
            if (u.errno(pr) == .SUCCESS and pr == 0) {
                timed_out = true;
                break;
            }
        }
        const b = readByte(fd) orelse {
            eof = true;
            break;
        };
        if (!exact and delim != null and b == delim.?) break;
        if (b == '\\' and !raw and !exact) {
            const nb = readByte(fd) orelse {
                eof = true;
                break;
            };
            if (nb == '\n') continue;
            line.push(nb);
            escaped_mask.push(true);
            continue;
        }
        line.push(b);
        escaped_mask.push(false);
    }
    const ifs = if (exact) "" else ifsValue();
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
    if (arr_name) |an| {
        if (!validName(an)) return builtinErr("read", "`{s}': not a valid identifier", .{an}, 1);
        const v = getOrCreateVar(an) orelse return 1;
        if (v.readonly) return builtinErr("read", "{s}: readonly variable", .{an}, 1);
        const ar = newArr(false);
        var idx: i64 = 0;
        while (pos < text.len) {
            while (pos < text.len and isIfs(ifs, text[pos]) and isWs(text[pos]) and !escaped_mask.items[pos]) pos += 1;
            if (pos >= text.len) break;
            var end = pos;
            while (end < text.len and !(isIfs(ifs, text[end]) and !escaped_mask.items[end])) end += 1;
            arrPut(ar, fmtU(a, idx), text[pos..end]);
            idx += 1;
            pos = end;
            while (pos < text.len and isIfs(ifs, text[pos]) and isWs(text[pos]) and !escaped_mask.items[pos]) pos += 1;
            if (pos < text.len and isIfs(ifs, text[pos]) and !isWs(text[pos]) and !escaped_mask.items[pos]) pos += 1;
        }
        v.arr = ar;
        arrSync(v);
        return if (timed_out) 142 else if (eof) 1 else 0;
    }
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
    return if (timed_out) 142 else if (eof) 1 else 0;
}

// ----- declare / typeset / local -----
fn declQuote(a: std.mem.Allocator, sv: []const u8) []const u8 {
    var o = u.Vec(u8).init(a);
    o.push('"');
    for (sv) |ch| {
        if (ch == '"' or ch == '\\' or ch == '$' or ch == '`') o.push('\\');
        o.push(ch);
    }
    o.push('"');
    return o.items;
}

fn declFlagString(a: std.mem.Allocator, v: Var) []const u8 {
    var o = u.Vec(u8).init(a);
    if (v.arr) |ar| o.push(if (ar.assoc) 'A' else 'a');
    if (v.integer) o.push('i');
    if (v.lower) o.push('l');
    if (v.readonly) o.push('r');
    if (v.upper) o.push('u');
    if (v.exported) o.push('x');
    if (o.items.len == 0) return "--";
    return std.fmt.allocPrint(a, "-{s}", .{o.items}) catch "--";
}

fn declPrintVar(a: std.mem.Allocator, name: []const u8, v: Var) void {
    if (v.arr) |ar| {
        var o = u.Vec(u8).init(a);
        for (ar.keys.items, 0..) |k, i| {
            if (i > 0) o.push(' ');
            var plain = true;
            for (k) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) {
                plain = false;
            };
            if (plain) o.pushSlice(std.fmt.allocPrint(a, "[{s}]={s}", .{ k, declQuote(a, ar.vals.items[i]) }) catch "") else o.pushSlice(std.fmt.allocPrint(a, "[{s}]={s}", .{ declQuote(a, k), declQuote(a, ar.vals.items[i]) }) catch "");
        }
        u.outf("declare {s} {s}=({s}{s})\n", .{ declFlagString(a, v), name, o.items, if (ar.assoc and o.items.len > 0) " " else "" });
        return;
    }
    u.outf("declare {s} {s}={s}\n", .{ declFlagString(a, v), name, declQuote(a, v.val) });
}

const DFlags = struct { nameref: i8 = 0, arr: i8 = 0, assoc: i8 = 0, int: i8 = 0, ro: i8 = 0, exp: i8 = 0, low: i8 = 0, up: i8 = 0, print: bool = false, func: bool = false, funcnames: bool = false, global: bool = false };

fn sortedVarNames(a: std.mem.Allocator) []const []const u8 {
    var names = u.Vec([]const u8).init(a);
    var it = vars.iterator();
    while (it.next()) |en| names.push(en.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return names.items;
}

fn builtinDeclare(a: std.mem.Allocator, args: []const []const u8, is_local: bool) u8 {
    const cmd = if (is_local) "local" else "declare";
    if (is_local and func_depth == 0) {
        u.errf("sh: local: can only be used in a function\n", .{});
        return 1;
    }
    var fl = DFlags{};
    var i: usize = 0;
    while (i < args.len and args[i].len > 1 and (args[i][0] == '-' or args[i][0] == '+')) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        const on: i8 = if (args[i][0] == '-') 1 else -1;
        for (args[i][1..]) |ch| {
            switch (ch) {
                'a' => fl.arr = on,
                'A' => fl.assoc = on,
                'i' => fl.int = on,
                'r' => fl.ro = on,
                'x' => fl.exp = on,
                'l' => fl.low = on,
                'u' => fl.up = on,
                'p' => fl.print = true,
                'f' => fl.func = true,
                'F' => fl.funcnames = true,
                'g' => fl.global = true,
                'n' => fl.nameref = on,
                't' => {},
                else => {
                    u.errf("sh: {s}: -{c}: invalid option\n", .{ cmd, ch });
                    return 2;
                },
            }
        }
    }
    const names = args[i..];
    if (fl.func or fl.funcnames) {
        var fnames = u.Vec([]const u8).init(a);
        if (names.len == 0) {
            var it = funcs.iterator();
            while (it.next()) |en| fnames.push(en.key_ptr.*);
            std.mem.sort([]const u8, fnames.items, {}, struct {
                fn lt(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.lt);
            if (fl.funcnames) for (fnames.items) |fnm_| u.outf("declare -f {s}\n", .{fnm_});
            return 0;
        }
        var st: u8 = 0;
        for (names) |nm| {
            if (funcs.contains(nm)) {
                if (fl.funcnames) u.outf("{s}\n", .{nm});
            } else st = 1;
        }
        return st;
    }
    if (names.len == 0) {
        if (fl.print) {
            for (sortedVarNames(a)) |k| {
                const v = vars.get(k).?;
                if (fl.arr == 1 and (v.arr == null or v.arr.?.assoc)) continue;
                if (fl.assoc == 1 and (v.arr == null or !v.arr.?.assoc)) continue;
                if (fl.exp == 1 and !v.exported) continue;
                if (fl.ro == 1 and !v.readonly) continue;
                if (fl.int == 1 and !v.integer) continue;
                declPrintVar(a, k, v);
            }
            return 0;
        }
        if (is_local) return 0;
        return builtinSet(a, &.{});
    }
    var st: u8 = 0;
    for (names) |x| {
        var nm = x;
        var value: ?[]const u8 = null;
        var append = false;
        if (std.mem.indexOfScalar(u8, x, '=')) |eq| {
            nm = x[0..eq];
            value = x[eq + 1 ..];
            if (nm.len > 0 and nm[nm.len - 1] == '+') {
                append = true;
                nm = nm[0 .. nm.len - 1];
            }
        }
        if (!validName(nm)) {
            u.errf("sh: {s}: `{s}': not a valid identifier\n", .{ cmd, x });
            st = 1;
            continue;
        }
        if (fl.print) {
            const v = vars.get(nm) orelse {
                u.errf("sh: {s}: {s}: not found\n", .{ cmd, nm });
                st = 1;
                continue;
            };
            declPrintVar(a, nm, v);
            continue;
        }
        const local = is_local or (func_depth > 0 and !fl.global);
        if (local) {
            locals.push(.{ .name = A.dupe(u8, nm) catch nm, .old = copyVar(vars.get(nm)) });
            if (value == null) {
                _ = vars.remove(nm);
                u.unsetVar(nm);
            }
        }
        if (fl.nameref != 0) {
            const nr = getOrCreateVar(nm) orelse {
                st = 1;
                continue;
            };
            nr.nameref = fl.nameref > 0;
            if (value) |val| nr.val = A.dupe(u8, val) catch val;
            continue;
        }
        const any_flag = fl.arr != 0 or fl.assoc != 0 or fl.int != 0 or fl.ro != 0 or fl.exp != 0 or fl.low != 0 or fl.up != 0;
        if (value == null and !any_flag) continue;
        const existed = vars.contains(nm);
        const v0 = getOrCreateVar(nm) orelse {
            st = 1;
            continue;
        };
        if (v0.readonly and (value != null or any_flag)) {
            u.errf("sh: {s}: {s}: readonly variable\n", .{ cmd, nm });
            st = 1;
            continue;
        }
        if (fl.assoc == 1 and (v0.arr == null or !v0.arr.?.assoc)) {
            const ar = newArr(true);
            if (existed and v0.arr == null and v0.val.len > 0) arrPut(ar, "0", v0.val);
            v0.arr = ar;
        }
        if (fl.arr == 1 and v0.arr == null) {
            const ar = newArr(false);
            if (existed and v0.val.len > 0) arrPut(ar, "0", v0.val);
            v0.arr = ar;
        }
        if (fl.int != 0) v0.integer = fl.int > 0;
        if (fl.low != 0) {
            v0.lower = fl.low > 0;
            if (v0.lower) v0.upper = false;
        }
        if (fl.up != 0) {
            v0.upper = fl.up > 0;
            if (v0.upper) v0.lower = false;
        }
        if (fl.exp != 0) {
            v0.exported = fl.exp > 0;
            if (v0.exported) u.setEnv(nm, v0.val) else u.setVar(nm, v0.val);
        }
        if (value) |val| {
            const nv = if (append) std.fmt.allocPrint(a, "{s}{s}", .{ getVar(nm) orelse "", val }) catch val else val;
            if (!setVar(nm, nv)) st = 1;
        } else if (v0.integer or v0.upper or v0.lower) {
            if (v0.arr == null) _ = setVar(nm, v0.val);
        }
        if (vars.getPtr(nm)) |vp| {
            if (fl.ro != 0) vp.readonly = fl.ro > 0;
            if (vp.exported) u.setEnv(nm, vp.val);
        }
    }
    return st;
}

const Pend = struct { name: []const u8, body: []const u8, append: bool };

fn arrayLitWord(w: []const u8) ?Pend {
    const eq = std.mem.indexOfScalar(u8, w, '=') orelse return null;
    if (eq + 2 >= w.len + 0 and w.len < eq + 3) return null;
    if (w[eq + 1] != '(' or w[w.len - 1] != ')') return null;
    var nm = w[0..eq];
    var app = false;
    if (nm.len > 0 and nm[nm.len - 1] == '+') {
        app = true;
        nm = nm[0 .. nm.len - 1];
    }
    if (!validName(nm)) return null;
    return .{ .name = nm, .body = w[eq + 2 .. w.len - 1], .append = app };
}

fn isDeclCmd(w: []const u8) bool {
    const names = [_][]const u8{ "declare", "typeset", "local", "readonly", "export" };
    for (names) |x| if (std.mem.eql(u8, x, w)) return true;
    return false;
}

fn applyPending(a: std.mem.Allocator, pend: []const Pend) u8 {
    var st: u8 = 0;
    for (pend) |pe| {
        var ro = false;
        if (vars.getPtr(pe.name)) |vp| {
            ro = vp.readonly;
            vp.readonly = false;
        }
        if (!assignArray(a, pe.name, pe.body, pe.append)) st = 1;
        if (vars.getPtr(pe.name)) |vp| vp.readonly = ro;
    }
    return st;
}

// ----- mapfile / readarray -----
fn builtinMapfile(a: std.mem.Allocator, args: []const []const u8) u8 {
    var delim: u8 = '\n';
    var strip = false;
    var count: usize = 0;
    var origin: ?i64 = null;
    var skip: usize = 0;
    var fd: i32 = 0;
    var i: usize = 0;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        var k: usize = 1;
        while (k < args[i].len) : (k += 1) {
            const ch = args[i][k];
            switch (ch) {
                't' => strip = true,
                'd', 'n', 'O', 's', 'u', 'C', 'c' => {
                    var optarg: []const u8 = "";
                    if (k + 1 < args[i].len) {
                        optarg = args[i][k + 1 ..];
                    } else if (i + 1 < args.len) {
                        i += 1;
                        optarg = args[i];
                    } else return builtinErr("mapfile", "-{c}: option requires an argument", .{ch}, 2);
                    k = args[i].len;
                    switch (ch) {
                        'd' => delim = if (optarg.len == 0) 0 else optarg[0],
                        'n' => count = std.fmt.parseInt(usize, optarg, 10) catch return builtinErr("mapfile", "{s}: invalid line count", .{optarg}, 2),
                        'O' => origin = std.fmt.parseInt(i64, optarg, 10) catch return builtinErr("mapfile", "{s}: invalid array origin", .{optarg}, 2),
                        's' => skip = std.fmt.parseInt(usize, optarg, 10) catch return builtinErr("mapfile", "{s}: invalid line count", .{optarg}, 2),
                        'u' => fd = std.fmt.parseInt(i32, optarg, 10) catch return builtinErr("mapfile", "{s}: invalid file descriptor specification", .{optarg}, 2),
                        else => {},
                    }
                },
                else => return builtinErr("mapfile", "-{c}: invalid option", .{ch}, 2),
            }
        }
    }
    const name = if (i < args.len) args[i] else "MAPFILE";
    if (!validName(name)) return builtinErr("mapfile", "`{s}': not a valid identifier", .{name}, 1);
    const v = getOrCreateVar(name) orelse return 1;
    if (v.readonly) return builtinErr("mapfile", "{s}: readonly variable", .{name}, 1);
    var ar: *Arr = undefined;
    if (origin != null and v.arr != null and !v.arr.?.assoc) ar = v.arr.? else {
        ar = newArr(false);
        v.arr = ar;
    }
    var idx: i64 = origin orelse 0;
    var line = u.Vec(u8).init(a);
    var nread: usize = 0;
    var skipped: usize = 0;
    var eof = false;
    while (!eof) {
        line.items.len = 0;
        var got_delim = false;
        while (true) {
            const b = readByte(fd) orelse {
                eof = true;
                break;
            };
            if (b == delim) {
                got_delim = true;
                break;
            }
            line.push(b);
        }
        if (eof and line.items.len == 0) break;
        if (skipped < skip) {
            skipped += 1;
            continue;
        }
        if (got_delim and !strip) line.push(delim);
        arrPut(ar, fmtU(a, idx), line.items);
        idx += 1;
        nread += 1;
        if (count > 0 and nread >= count) break;
    }
    arrSync(v);
    return 0;
}

// ----- shopt -----
const shopt_names = [_][]const u8{ "assoc_expand_once", "autocd", "cdable_vars", "cdspell", "checkhash", "checkjobs", "checkwinsize", "cmdhist", "compat31", "compat32", "compat40", "compat41", "compat42", "compat43", "compat44", "complete_fullquote", "direxpand", "dirspell", "dotglob", "execfail", "expand_aliases", "extdebug", "extglob", "extquote", "failglob", "force_fignore", "globasciiranges", "globskipdots", "globstar", "gnu_errfmt", "histappend", "histreedit", "histverify", "hostcomplete", "huponexit", "inherit_errexit", "interactive_comments", "lastpipe", "lithist", "localvar_inherit", "localvar_unset", "login_shell", "mailwarn", "no_empty_cmd_completion", "nocaseglob", "nocasematch", "noexpand_translation", "nullglob", "patsub_replacement", "progcomp", "progcomp_alias", "promptvars", "restricted_shell", "shift_verbose", "sourcepath", "varredir_close", "xpg_echo" };
var shopt_on: [shopt_names.len]bool = blk: {
    @setEvalBranchQuota(100000);
    var arr: [shopt_names.len]bool = @splat(false);
    const defaults = [_][]const u8{ "checkwinsize", "cmdhist", "complete_fullquote", "extquote", "force_fignore", "globasciiranges", "globskipdots", "hostcomplete", "interactive_comments", "patsub_replacement", "progcomp", "promptvars", "sourcepath" };
    for (shopt_names, 0..) |nm, idx| for (defaults) |d| if (std.mem.eql(u8, nm, d)) {
        arr[idx] = true;
    };
    break :blk arr;
};
var sh_nullglob = false;
var sh_lastpipe = false;
var lastpipe_ran = false;
var lastpipe_status: u8 = 0;
var sh_dotglob = false;

fn shoptIndex(name: []const u8) ?usize {
    for (shopt_names, 0..) |nm, idx| if (std.mem.eql(u8, nm, name)) return idx;
    return null;
}

fn shoptSync(idx: usize) void {
    const nm = shopt_names[idx];
    if (std.mem.eql(u8, nm, "nullglob")) sh_nullglob = shopt_on[idx];
    if (std.mem.eql(u8, nm, "extglob")) sh_extglob = shopt_on[idx];
    if (std.mem.eql(u8, nm, "lastpipe")) sh_lastpipe = shopt_on[idx];
    if (std.mem.eql(u8, nm, "dotglob")) sh_dotglob = shopt_on[idx];
    if (std.mem.eql(u8, nm, "nocasematch")) nocasematch = shopt_on[idx];
}

fn builtinShopt(a: std.mem.Allocator, args: []const []const u8) u8 {
    var mode: u8 = 0; // 's', 'u'
    var quiet = false;
    var print = false;
    var oopt = false;
    var i: usize = 0;
    while (i < args.len and args[i].len > 1 and (args[i][0] == '-' or args[i][0] == '+')) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        for (args[i][1..]) |ch| switch (ch) {
            's' => mode = 's',
            'u' => mode = 'u',
            'q' => quiet = true,
            'p' => print = true,
            'o' => oopt = true,
            else => return builtinErr("shopt", "-{c}: invalid option", .{ch}, 2),
        };
    }
    const names = args[i..];
    if (oopt) {
        if (mode == 0) return builtinSet(a, &.{ "-o" });
        var st: u8 = 0;
        for (names) |nm| {
            const sa = [_][]const u8{ if (mode == 's') "-o" else "+o", nm };
            if (builtinSet(a, &sa) != 0) st = 1;
        }
        return st;
    }
    if (names.len == 0) {
        for (shopt_names, 0..) |nm, idx| {
            if (mode == 's' and !shopt_on[idx]) continue;
            if (mode == 'u' and shopt_on[idx]) continue;
            if (print) u.outf("shopt {s} {s}\n", .{ if (shopt_on[idx]) "-s" else "-u", nm }) else u.outf("{s: <20}\t{s}\n", .{ nm, if (shopt_on[idx]) "on" else "off" });
        }
        return 0;
    }
    var st: u8 = 0;
    for (names) |nm| {
        const idx = shoptIndex(nm) orelse {
            u.errf("sh: shopt: {s}: invalid shell option name\n", .{nm});
            st = 1;
            continue;
        };
        if (mode == 's' or mode == 'u') {
            shopt_on[idx] = mode == 's';
            shoptSync(idx);
            continue;
        }
        if (!shopt_on[idx]) st = 1;
        if (quiet) continue;
        if (print) u.outf("shopt {s} {s}\n", .{ if (shopt_on[idx]) "-s" else "-u", nm }) else u.outf("{s: <20}\t{s}\n", .{ nm, if (shopt_on[idx]) "on" else "off" });
    }
    return st;
}

// ----- directory stack -----
var dstack = u.Vec([]const u8).init(A);

fn curDir(a: std.mem.Allocator) []const u8 {
    if (getVar("PWD")) |p| return p;
    var buf: [4096]u8 = undefined;
    const r = linux.getcwd(&buf, buf.len);
    if (u.ok(r)) return a.dupe(u8, std.mem.sliceTo(&buf, 0)) catch "/";
    return "/";
}

fn tildeAbbrev(a: std.mem.Allocator, path: []const u8, long: bool) []const u8 {
    if (long) return path;
    const home = getVar("HOME") orelse return path;
    if (home.len == 0 or std.mem.eql(u8, home, "/")) return path;
    if (std.mem.eql(u8, path, home)) return "~";
    if (std.mem.startsWith(u8, path, home) and path.len > home.len and path[home.len] == '/') return std.fmt.allocPrint(a, "~{s}", .{path[home.len..]}) catch path;
    return path;
}

fn printDirs(a: std.mem.Allocator, long: bool, per_line: bool, verbose: bool) void {
    var idx: usize = 0;
    var first = true;
    var all = u.Vec([]const u8).init(a);
    all.push(curDir(a));
    for (dstack.items) |d| all.push(d);
    for (all.items) |d| {
        const shown = tildeAbbrev(a, d, long);
        if (verbose) {
            u.outf("{d: >2}  {s}\n", .{ idx, shown });
        } else if (per_line) {
            u.outf("{s}\n", .{shown});
        } else {
            u.outf("{s}{s}", .{ if (first) "" else " ", shown });
        }
        first = false;
        idx += 1;
    }
    if (!verbose and !per_line) u.out("\n");
}

fn builtinDirs(a: std.mem.Allocator, args: []const []const u8) u8 {
    var long = false;
    var per_line = false;
    var verbose = false;
    for (args) |x| {
        if (x.len > 1 and x[0] == '-') {
            for (x[1..]) |ch| switch (ch) {
                'c' => {
                    dstack = u.Vec([]const u8).init(A);
                    return 0;
                },
                'l' => long = true,
                'p' => per_line = true,
                'v' => verbose = true,
                else => return builtinErr("dirs", "{s}: invalid option", .{x}, 2),
            };
        }
    }
    printDirs(a, long, per_line, verbose);
    return 0;
}

fn rotateTo(a: std.mem.Allocator, n: usize) u8 {
    var all = u.Vec([]const u8).init(a);
    all.push(curDir(a));
    for (dstack.items) |d| all.push(d);
    if (n >= all.items.len) return builtinErr("pushd", "directory stack index out of range", .{}, 1);
    var rot = u.Vec([]const u8).init(a);
    for (all.items[n..]) |d| rot.push(d);
    for (all.items[0..n]) |d| rot.push(d);
    const st = builtinCd(a, &.{rot.items[0]});
    if (st != 0) return st;
    dstack = u.Vec([]const u8).init(A);
    for (rot.items[1..]) |d| dstack.push(A.dupe(u8, d) catch d);
    return 0;
}

fn builtinPushd(a: std.mem.Allocator, args: []const []const u8) u8 {
    var noswitch = false;
    var target: ?[]const u8 = null;
    for (args) |x| {
        if (std.mem.eql(u8, x, "-n")) noswitch = true else target = x;
    }
    if (target == null) {
        if (dstack.items.len == 0) return builtinErr("pushd", "no other directory", .{}, 1);
        const st = rotateTo(a, 1);
        if (st != 0) return st;
        printDirs(a, false, false, false);
        return 0;
    }
    const t = target.?;
    if (t.len > 1 and (t[0] == '+' or t[0] == '-') and std.ascii.isDigit(t[1])) {
        const n = std.fmt.parseInt(usize, t[1..], 10) catch return builtinErr("pushd", "{s}: invalid number", .{t}, 2);
        const total = dstack.items.len + 1;
        const idx = if (t[0] == '+') n else if (n < total) total - 1 - n else return builtinErr("pushd", "{s}: directory stack index out of range", .{t}, 1);
        const st = rotateTo(a, idx);
        if (st != 0) return st;
        printDirs(a, false, false, false);
        return 0;
    }
    const old = A.dupe(u8, curDir(a)) catch return 1;
    if (noswitch) {
        var nd = u.Vec([]const u8).init(A);
        nd.push(A.dupe(u8, t) catch t);
        for (dstack.items) |d| nd.push(d);
        dstack = nd;
    } else {
        const st = builtinCd(a, &.{t});
        if (st != 0) return st;
        var nd = u.Vec([]const u8).init(A);
        nd.push(old);
        for (dstack.items) |d| nd.push(d);
        dstack = nd;
    }
    printDirs(a, false, false, false);
    return 0;
}

fn builtinPopd(a: std.mem.Allocator, args: []const []const u8) u8 {
    var noswitch = false;
    var idx: usize = 0;
    var from_right = false;
    for (args) |x| {
        if (std.mem.eql(u8, x, "-n")) {
            noswitch = true;
        } else if (x.len > 1 and (x[0] == '+' or x[0] == '-') and std.ascii.isDigit(x[1])) {
            idx = std.fmt.parseInt(usize, x[1..], 10) catch return builtinErr("popd", "{s}: invalid number", .{x}, 2);
            from_right = x[0] == '-';
        } else return builtinErr("popd", "{s}: invalid argument", .{x}, 2);
    }
    if (dstack.items.len == 0) return builtinErr("popd", "directory stack empty", .{}, 1);
    const total = dstack.items.len + 1;
    if (idx >= total) return builtinErr("popd", "{s}: directory stack index out of range", .{if (args.len > 0) args[args.len - 1] else "0"}, 1);
    if (from_right) idx = total - 1 - idx;
    if (idx == 0 and !noswitch) {
        const dest = dstack.items[0];
        const st = builtinCd(a, &.{dest});
        if (st != 0) return st;
    }
    var nd = u.Vec([]const u8).init(A);
    const rm = if (idx == 0) 0 else idx - 1;
    for (dstack.items, 0..) |d, k| if (k != rm) nd.push(d);
    dstack = nd;
    printDirs(a, false, false, false);
    return 0;
}

// ----- type -----
const reserved_words = [_][]const u8{ "if", "then", "else", "elif", "fi", "case", "esac", "for", "select", "while", "until", "do", "done", "in", "function", "time", "{", "}", "!", "[[", "]]", "coproc" };

fn isKeyword(w: []const u8) bool {
    for (reserved_words) |x| if (std.mem.eql(u8, x, w)) return true;
    return false;
}

fn builtinType(a: std.mem.Allocator, args: []const []const u8) u8 {
    var t_mode = false;
    var p_mode = false;
    var big_p = false;
    var all = false;
    var i: usize = 0;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        for (args[i][1..]) |ch| switch (ch) {
            't' => t_mode = true,
            'p' => p_mode = true,
            'P' => big_p = true,
            'a' => all = true,
            'f' => {},
            else => return builtinErr("type", "-{c}: invalid option", .{ch}, 2),
        };
    }
    var st: u8 = 0;
    for (args[i..]) |x| {
        if (!t_mode and !p_mode and !big_p and !all) {
            if (isKeyword(x)) {
                u.outf("{s} is a shell keyword\n", .{x});
                continue;
            }
            if (!describeCmd(a, x, true)) st = 1;
            continue;
        }
        var found = false;
        const path = getVar("PATH") orelse "/bin:/usr/bin";
        if (!big_p) {
            if (aliases.get(x) != null) {
                found = true;
                if (t_mode) u.out("alias\n") else if (!p_mode) u.outf("{s} is aliased to `{s}'\n", .{ x, aliases.get(x).? });
                if (!all) continue;
            }
            if (isKeyword(x)) {
                found = true;
                if (t_mode) u.out("keyword\n") else if (!p_mode) u.outf("{s} is a shell keyword\n", .{x});
                if (!all) continue;
            }
            if (funcs.contains(x)) {
                found = true;
                if (t_mode) u.out("function\n") else if (!p_mode) u.outf("{s} is a function\n", .{x});
                if (!all) continue;
            }
            if (isBuiltin(x) or isInproc(x)) {
                found = true;
                if (t_mode) u.out("builtin\n") else if (!p_mode) u.outf("{s} is a shell builtin\n", .{x});
                if (!all) continue;
            }
        }
        if (findCmd(a, x, path)) |fp| {
            if (std.mem.indexOfScalar(u8, x, '/') == null or u.stat(fp, true) != null) {
                found = true;
                if (t_mode) u.out("file\n") else if (p_mode or big_p) u.outf("{s}\n", .{fp}) else u.outf("{s} is {s}\n", .{ x, fp });
            }
        }
        if (!found) {
            st = 1;
            if (!t_mode and !p_mode and !big_p) u.errf("sh: type: {s}: not found\n", .{x});
        }
    }
    return st;
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
    if (args.len > 0 and std.mem.eql(u8, args[0], "-n")) {
        if (jobs.items.len == 0) return 127;
        for (jobs.items, 0..) |j, k| if (j.status != null) {
            const st0 = j.status.?;
            std.mem.copyForwards(Job, jobs.items[k .. jobs.items.len - 1], jobs.items[k + 1 ..]);
            jobs.items.len -= 1;
            return st0;
        };
        while (true) {
            var status: u32 = 0;
            const rc = linux.wait4(-1, &status, 0, null);
            if (!u.ok(rc)) {
                if (u.errno(rc) == .INTR) {
                    checkTraps();
                    continue;
                }
                return 127;
            }
            const pid: i32 = @intCast(rc);
            for (jobs.items, 0..) |j, k| if (j.pid == pid) {
                std.mem.copyForwards(Job, jobs.items[k .. jobs.items.len - 1], jobs.items[k + 1 ..]);
                jobs.items.len -= 1;
                return waitStatus(status);
            };
        }
    }
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
        if (x.len > 0 and x[0] == '%') {
            const k = jobBySpec(x) orelse {
                u.errf("sh: wait: {s}: no such job\n", .{x});
                st = 127;
                continue;
            };
            const jp = jobs.items[k].pid;
            st = waitFor(jp);
            continue;
        }
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
    start_time = nowSecs();
    @import("printf.zig").bash_mode = true;
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
        jcInit();
    }
}
