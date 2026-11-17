// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// sed - stream editor with GNU sed 4.9 compatible syntax and extensions.
// Input is processed as a stream (so `yes | sed 3q` terminates); regular
// expressions use the static musl POSIX engine after translating GNU escapes.
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const c = @cImport({
    @cInclude("regex.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});
const A = u.alloc;
const Fail = error{ Fail, Label, Io };

fn die(comptime fmt: []const u8, args: anytype) Fail {
    u.errf("sed: " ++ fmt ++ "\n", args);
    return error.Fail;
}

// ---------------------------------------------------------------- buffers
const Buf = struct {
    data: []u8 = &.{},
    len: usize = 0,
    fn reserve(self: *Buf, extra: usize) void {
        if (self.len + extra <= self.data.len) return;
        var ncap: usize = if (self.data.len == 0) 256 else self.data.len * 2;
        while (ncap < self.len + extra) ncap *= 2;
        const nb = A.alloc(u8, ncap) catch @panic("oom");
        @memcpy(nb[0..self.len], self.data[0..self.len]);
        if (self.data.len > 0) A.free(self.data);
        self.data = nb;
    }
    fn append(self: *Buf, s: []const u8) void {
        self.reserve(s.len);
        @memcpy(self.data[self.len..][0..s.len], s);
        self.len += s.len;
    }
    fn push(self: *Buf, b: u8) void {
        self.reserve(1);
        self.data[self.len] = b;
        self.len += 1;
    }
    fn set(self: *Buf, s: []const u8) void {
        self.len = 0;
        self.append(s);
    }
    fn slice(self: *const Buf) []const u8 {
        return self.data[0..self.len];
    }
};

const Out = struct {
    fd: i32,
    buf: Buf = .{},
    missing_newline: bool = false,
    always_flush: bool = false,
    delim: u8 = '\n',
    failed: bool = false,
    parent: ?*Out = null,
    fn root(self: *Out) *Out {
        return self.parent orelse self;
    }
    fn write(self: *Out, s: []const u8) void {
        const r = self.root();
        r.buf.append(s);
        if (r.always_flush or r.buf.len >= 65536) r.flush();
    }
    fn flush(self: *Out) void {
        if (self.parent) |p| return p.flush();
        if (self.buf.len == 0) return;
        const f = u.File{ .fd = self.fd };
        if (!f.write(self.buf.slice())) self.failed = true;
        self.buf.len = 0;
    }
    fn fixNewline(self: *Out) void {
        if (self.missing_newline) {
            self.root().buf.push(self.delim);
            self.missing_newline = false;
        }
    }
    fn line(self: *Out, text: []const u8, terminated: bool) void {
        self.fixNewline();
        const r = self.root();
        r.buf.append(text);
        if (terminated) r.buf.push(self.delim) else self.missing_newline = true;
        if (r.always_flush or r.buf.len >= 65536) r.flush();
    }
    fn raw(self: *Out, text: []const u8) void {
        self.fixNewline();
        self.write(text);
    }
};

// ---------------------------------------------------------------- regex
const Rx = struct {
    re: c.regex_t = undefined,
    pref: c.regex_t = undefined,
    have_pref: bool = false,
    pref_failed: bool = false,
    orig: []const u8,
    ext: bool,
    flags: c_int,
    ctx: bool = false,
    nsub: usize = 0,
    bre: bool = false,
    single: u8 = 0, // pattern is exactly one word assertion: \b \B \< \>
};
const Match = [10]c.regmatch_t;

fn lit(out: *Buf, b: u8, ext: bool) void {
    const special = if (ext) ".[]()*+?{}|^$\\" else ".[]*^$\\";
    if (std.mem.indexOfScalar(u8, special, b) != null) out.push('\\');
    out.push(b);
}
fn hexv(ch: u8) ?u8 {
    return std.fmt.charToDigit(ch, 16) catch null;
}
/// Parse \dNNN \oNNN \xHH \cX at src[i] (the letter). Returns byte and number of chars consumed after the letter.
fn charEscape(src: []const u8, i: usize) ?struct { b: u8, n: usize } {
    const e = src[i];
    switch (e) {
        'd' => {
            var v: u32 = 0;
            var k: usize = 0;
            while (k < 3 and i + 1 + k < src.len and std.ascii.isDigit(src[i + 1 + k])) : (k += 1) v = v * 10 + (src[i + 1 + k] - '0');
            if (k == 0) return null;
            return .{ .b = @truncate(v), .n = k };
        },
        'o' => {
            var v: u32 = 0;
            var k: usize = 0;
            while (k < 3 and i + 1 + k < src.len and src[i + 1 + k] >= '0' and src[i + 1 + k] <= '7') : (k += 1) v = v * 8 + (src[i + 1 + k] - '0');
            if (k == 0) return null;
            return .{ .b = @truncate(v), .n = k };
        },
        'x' => {
            var v: u32 = 0;
            var k: usize = 0;
            while (k < 2 and i + 1 + k < src.len and hexv(src[i + 1 + k]) != null) : (k += 1) v = v * 16 + hexv(src[i + 1 + k]).?;
            if (k == 0) return null;
            return .{ .b = @truncate(v), .n = k };
        },
        'c' => {
            if (i + 1 >= src.len) return null;
            return .{ .b = std.ascii.toUpper(src[i + 1]) ^ 0x40, .n = 1 };
        },
        else => return null,
    }
}
fn simpleEsc(e: u8) ?u8 {
    return switch (e) {
        'n' => '\n',
        't' => '\t',
        'f' => 0x0c,
        'v' => 0x0b,
        'a' => 0x07,
        'r' => '\r',
        else => null,
    };
}
const TransError = error{ Unterminated, TooManyGroups, Trailing };
fn translate(src: []const u8, ext_in: bool, bre_out: bool, shift: u8, out: *Buf, ctx: *bool) TransError!void {
    const ext = ext_in and !bre_out; // syntax of the emitted pattern
    var i: usize = 0;
    while (i < src.len) {
        const ch = src[i];
        if (ch == '[') {
            out.push('[');
            var j = i + 1;
            if (j < src.len and src[j] == '^') {
                out.push('^');
                j += 1;
            }
            if (j < src.len and src[j] == ']') {
                out.push(']');
                j += 1;
            }
            while (true) {
                if (j >= src.len) return error.Unterminated;
                const d = src[j];
                if (d == ']') {
                    out.push(']');
                    j += 1;
                    break;
                }
                if (d == '[' and j + 1 < src.len and (src[j + 1] == ':' or src[j + 1] == '.' or src[j + 1] == '=')) {
                    const kind = src[j + 1];
                    var k = j + 2;
                    while (k + 1 < src.len and !(src[k] == kind and src[k + 1] == ']')) k += 1;
                    if (k + 1 >= src.len) return error.Unterminated;
                    out.append(src[j .. k + 2]);
                    j = k + 2;
                    continue;
                }
                if (d == '\\' and j + 1 < src.len) {
                    if (simpleEsc(src[j + 1])) |b| {
                        out.push(b);
                        j += 2;
                        continue;
                    }
                }
                out.push(d);
                j += 1;
            }
            i = j;
            continue;
        }
        if (ch != '\\') {
            if (ext_in and bre_out and std.mem.indexOfScalar(u8, "(){}|+?", ch) != null) out.push('\\');
            out.push(ch);
            i += 1;
            continue;
        }
        if (i + 1 >= src.len) return error.Trailing;
        const e = src[i + 1];
        if (simpleEsc(e)) |b| {
            out.push(b);
            i += 2;
            continue;
        }
        if (charEscape(src, i + 1)) |ce| {
            lit(out, ce.b, ext);
            i += 2 + ce.n;
            continue;
        }
        switch (e) {
            'w', 'W', 's', 'S' => {
                out.push('\\');
                out.push(e);
            },
            'b', 'B', '<', '>' => {
                ctx.* = true;
                out.push('\\');
                out.push(e);
            },
            '`' => out.push('^'),
            '\'' => out.push('$'),
            '1'...'9' => {
                const n = e - '0' + shift;
                if (n > 9) return error.TooManyGroups;
                out.push('\\');
                out.push('0' + n);
            },
            '\n' => out.push('\n'),
            '(', ')', '{', '}', '|', '+', '?' => {
                if (!(ext_in and bre_out)) out.push('\\');
                out.push(e);
            },
            '.', '*', '[', ']', '^', '$', '\\' => {
                out.push('\\');
                out.push(e);
            },
            '/' => out.push('/'),
            else => out.push(e),
        }
        i += 2;
    }
}

var g_last_rx: ?*Rx = null;
var g_zbuf: []u8 = &.{};

fn compileRx(src: []const u8, ext: bool, icase: bool, mline: bool) Fail!*Rx {
    const rx = A.create(Rx) catch @panic("oom");
    var flags: c_int = 0;
    var bre = false;
    if (ext) {
        var k: usize = 0;
        while (k + 1 < src.len) : (k += 1) {
            if (src[k] == '\\') {
                if (src[k + 1] >= '1' and src[k + 1] <= '9') bre = true;
                k += 1;
            }
        }
    }
    if (ext and !bre) flags |= c.REG_EXTENDED;
    if (icase) flags |= c.REG_ICASE;
    if (mline) flags |= c.REG_NEWLINE;
    rx.* = .{ .orig = A.dupe(u8, src) catch @panic("oom"), .ext = ext, .flags = flags, .ctx = mline, .bre = bre };
    var out = Buf{};
    translate(src, ext, bre, 0, &out, &rx.ctx) catch |e| return switch (e) {
        error.Unterminated => die("unterminated address regex", .{}),
        error.Trailing => die("Trailing backslash", .{}),
        error.TooManyGroups => die("invalid reference on regex", .{}),
    };
    out.push(0);
    const rc = c.regcomp(&rx.re, @ptrCast(out.data.ptr), flags);
    if (rc != 0) {
        var msg: [256]u8 = undefined;
        _ = c.regerror(rc, &rx.re, &msg, msg.len);
        return die("-e expression #1: {s}", .{std.mem.sliceTo(&msg, 0)});
    }
    rx.nsub = rx.re.re_nsub;
    if (src.len == 2 and src[0] == '\\' and std.mem.indexOfScalar(u8, "bB<>", src[1]) != null) rx.single = src[1];
    return rx;
}
fn compilePref(rx: *Rx) void {
    rx.pref_failed = true;
    var body = Buf{};
    var dummy = false;
    translate(rx.orig, rx.ext, rx.bre, 2, &body, &dummy) catch return;
    var out = Buf{};
    const e = rx.ext and !rx.bre;
    if (e) out.append("^(.|\n)(") else out.append("^\\(.\\|\n\\)\\(");
    out.append(body.slice());
    out.append(if (e) ")" else "\\)");
    out.push(0);
    if (c.regcomp(&rx.pref, @ptrCast(out.data.ptr), rx.flags) != 0) return;
    rx.have_pref = true;
    rx.pref_failed = false;
}
fn zcopy(s: []const u8) [*:0]const u8 {
    if (g_zbuf.len < s.len + 1) {
        if (g_zbuf.len > 0) A.free(g_zbuf);
        g_zbuf = A.alloc(u8, (s.len + 1) * 2) catch @panic("oom");
    }
    @memcpy(g_zbuf[0..s.len], s);
    g_zbuf[s.len] = 0;
    return @ptrCast(g_zbuf.ptr);
}
/// Search z[0..len] starting at `from`; offsets in pm are absolute.
fn rxSearch(rx: *Rx, z: [*:0]const u8, len: usize, from: usize, pm: *Match) bool {
    g_last_rx = rx;
    if (from > len) return false;
    for (pm) |*m| {
        m.rm_so = -1;
        m.rm_eo = -1;
    }
    if (rx.single != 0) {
        // musl treats every string edge as a word boundary; evaluate the assertion directly
        const t = z[0..len];
        var p = from;
        while (p <= len) : (p += 1) {
            const pw = p > 0 and (std.ascii.isAlphanumeric(t[p - 1]) or t[p - 1] == '_');
            const nw = p < len and (std.ascii.isAlphanumeric(t[p]) or t[p] == '_');
            const ok = switch (rx.single) {
                'b' => pw != nw,
                'B' => pw == nw,
                '<' => !pw and nw,
                else => pw and !nw,
            };
            if (ok) {
                pm[0].rm_so = @intCast(p);
                pm[0].rm_eo = @intCast(p);
                return true;
            }
        }
        return false;
    }
    if (from > 0 and rx.ctx and !rx.have_pref and !rx.pref_failed) compilePref(rx);
    if (from > 0 and rx.have_pref) {
        // The prefixed form is anchored one character before the candidate start so that
        // \b \< and ^ (in M mode) see the real preceding character; try each start in turn.
        var raw: [12]c.regmatch_t = undefined;
        const n = @min(12, rx.nsub + 3);
        var p = from;
        while (p <= len) : (p += 1) {
            if (c.regexec(&rx.pref, z + p - 1, n, &raw, 0) != 0) continue;
            var i: usize = 0;
            while (i + 2 < n and i < 10) : (i += 1) {
                const m = raw[i + 2];
                if (m.rm_so >= 0) {
                    pm[i].rm_so = m.rm_so + @as(c_int, @intCast(p - 1));
                    pm[i].rm_eo = m.rm_eo + @as(c_int, @intCast(p - 1));
                }
            }
            return true;
        }
        return false;
    }
    var raw: Match = undefined;
    const n = @min(10, rx.nsub + 1);
    if (c.regexec(&rx.re, z + from, n, &raw, if (from > 0) c.REG_NOTBOL else 0) != 0) return false;
    for (raw[0..n], 0..) |m, i| {
        if (m.rm_so >= 0) {
            pm[i].rm_so = m.rm_so + @as(c_int, @intCast(from));
            pm[i].rm_eo = m.rm_eo + @as(c_int, @intCast(from));
        }
    }
    return true;
}

// ---------------------------------------------------------------- script
const AddrKind = enum { none, line, last, regex, step, zero };
const Addr = struct { kind: AddrKind = .none, n: usize = 0, step: usize = 0, rx: ?*Rx = null };
const End = enum { none, line, last, regex, plus, mult };
const Addr2 = struct { kind: End = .none, n: usize = 0, rx: ?*Rx = null };
const Part = union(enum) { lit: []const u8, group: u8, case: u8 };
const Command = struct {
    a1: Addr = .{},
    a2: Addr2 = .{},
    negate: bool = false,
    kind: u8 = 0,
    text: []const u8 = "",
    parts: []Part = &.{},
    rx: ?*Rx = null,
    global: bool = false,
    print: bool = false,
    eval: bool = false,
    occurrence: usize = 0,
    int_arg: ?usize = null,
    write_file: ?[]const u8 = null,
    jump: usize = 0,
    active: bool = false,
    closed: bool = false,
    range_end: usize = 0,
};

const Parser = struct {
    text: []const u8,
    pos: usize = 0,
    ext: bool,
    sandbox: bool,
    delim: u8 = '\n',
    cmds: u.Vec(Command) = u.Vec(Command).init(A),

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.text.len) self.text[self.pos] else null;
    }
    fn space(self: *Parser) void {
        while (self.pos < self.text.len and (self.text[self.pos] == ' ' or self.text[self.pos] == '\t')) self.pos += 1;
    }
    fn spaceNl(self: *Parser) void {
        while (self.pos < self.text.len and std.ascii.isWhitespace(self.text[self.pos])) self.pos += 1;
    }
    fn number(self: *Parser) Fail!usize {
        const start = self.pos;
        while (self.pos < self.text.len and std.ascii.isDigit(self.text[self.pos])) self.pos += 1;
        if (start == self.pos) return die("expected number", .{});
        return std.fmt.parseInt(usize, self.text[start..self.pos], 10) catch die("number too large", .{});
    }
    /// Text up to an unescaped delimiter. `\delim` becomes delim; other escapes are kept for later processing.
    fn delimited(self: *Parser, delim: u8, is_regex: bool) Fail![]const u8 {
        var out = Buf{};
        while (self.pos < self.text.len) {
            const b = self.text[self.pos];
            self.pos += 1;
            if (b == delim) return out.slice();
            if (b == '\n' and is_regex) return die("unterminated address regex", .{});
            if (b == '\\' and self.pos < self.text.len) {
                const nx = self.text[self.pos];
                self.pos += 1;
                if (nx == delim) {
                    // \<delim> is a literal delimiter; keep specials escaped where the delimiter is regex-special
                    if (is_regex and delim != '/' and std.mem.indexOfScalar(u8, "$*.[]^", delim) != null) out.push('\\');
                    out.push(nx);
                } else if (nx == 'n' and !is_regex and false) {
                    out.push('\n');
                } else {
                    out.push('\\');
                    out.push(nx);
                }
                continue;
            }
            if (b == '[' and is_regex) {
                // keep bracket expressions intact (delimiter inside brackets is not special in GNU only for ']' handling)
            }
            out.push(b);
        }
        return die("unterminated `s' command", .{});
    }
    const RxFlags = struct { i: bool, m: bool };
    fn regexFlags(self: *Parser) RxFlags {
        var r = RxFlags{ .i = false, .m = false };
        while (self.peek()) |b| {
            if (b == 'I') r.i = true else if (b == 'M') r.m = true else break;
            self.pos += 1;
        }
        return r;
    }
    fn regexAddr(self: *Parser, delim: u8) Fail!?*Rx {
        const pat = try self.delimited(delim, true);
        const f = self.regexFlags();
        if (pat.len == 0) return null;
        return try compileRx(pat, self.ext, f.i, f.m);
    }
    fn address(self: *Parser) Fail!Addr {
        const b = self.peek() orelse return .{};
        if (std.ascii.isDigit(b)) {
            const n = try self.number();
            if (self.peek() == '~') {
                self.pos += 1;
                const step = if (self.peek()) |d| (if (std.ascii.isDigit(d)) try self.number() else 0) else 0;
                if (n == 0 and step == 0) return die("invalid usage of line address 0", .{});
                return .{ .kind = .step, .n = n, .step = step };
            }
            return .{ .kind = if (n == 0) .zero else .line, .n = n };
        }
        if (b == '$') {
            self.pos += 1;
            return .{ .kind = .last };
        }
        if (b == '/') {
            self.pos += 1;
            return .{ .kind = .regex, .rx = try self.regexAddr('/') };
        }
        if (b == '\\') {
            self.pos += 1;
            const d = self.peek() orelse return die("unexpected `,'", .{});
            self.pos += 1;
            return .{ .kind = .regex, .rx = try self.regexAddr(d) };
        }
        return .{};
    }
    fn endCmd(self: *Parser) Fail!void {
        self.space();
        const b = self.peek() orelse return;
        switch (b) {
            ';', '\n' => self.pos += 1,
            '}', '#' => {},
            else => return die("extra characters after command", .{}),
        }
    }
    fn restOfLine(self: *Parser) []const u8 {
        self.space();
        const start = self.pos;
        while (self.pos < self.text.len and self.text[self.pos] != '\n') self.pos += 1;
        const r = self.text[start..self.pos];
        return r;
    }
    fn label(self: *Parser, stop_brace: bool) []const u8 {
        self.space();
        const start = self.pos;
        while (self.pos < self.text.len and self.text[self.pos] != '\n' and self.text[self.pos] != ';' and self.text[self.pos] != ' ' and self.text[self.pos] != '\t' and !(stop_brace and self.text[self.pos] == '}')) self.pos += 1;
        return self.text[start..self.pos];
    }
    fn textArg(self: *Parser) Fail![]const u8 {
        self.space();
        if (self.pos >= self.text.len) return die("expected \\ after `a', `c' or `i'", .{});
        if (self.text[self.pos] == '\\') {
            self.pos += 1;
            // "a\" newline text, or GNU one-liner a\text
            var save = self.pos;
            self.space();
            if (self.pos < self.text.len and self.text[self.pos] == '\n') self.pos += 1 else self.pos = save;
            save = 0;
        } else if (self.text[self.pos] == '\n') return die("expected \\ after `a', `c' or `i'", .{});
        if (self.pos >= self.text.len) return "";
        var out = Buf{};
        while (self.pos < self.text.len) {
            const b = self.text[self.pos];
            self.pos += 1;
            if (b == '\n') break;
            if (b == '\\' and self.pos < self.text.len) {
                const nx = self.text[self.pos];
                self.pos += 1;
                if (nx == '\n') out.push('\n') else if (simpleEsc(nx)) |e| out.push(e) else out.push(nx);
            } else out.push(b);
        }
        out.push('\n');
        return out.slice();
    }
    fn replacement(self: *Parser, raw: []const u8, nsub: ?usize) Fail![]Part {
        var parts = u.Vec(Part).init(A);
        var cur = Buf{};
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            const ch = raw[i];
            if (ch == '&') {
                if (cur.len > 0) parts.push(.{ .lit = A.dupe(u8, cur.slice()) catch @panic("oom") });
                cur.len = 0;
                parts.push(.{ .group = 0 });
                continue;
            }
            if (ch != '\\' or i + 1 >= raw.len) {
                cur.push(ch);
                continue;
            }
            i += 1;
            const e = raw[i];
            if (std.ascii.isDigit(e) or e == 'U' or e == 'L' or e == 'u' or e == 'l' or e == 'E') {
                if (cur.len > 0) parts.push(.{ .lit = A.dupe(u8, cur.slice()) catch @panic("oom") });
                cur.len = 0;
                if (std.ascii.isDigit(e)) {
                    if (nsub) |n| if (e - '0' > n) return die("invalid reference \\{d} on `s' command's RHS", .{e - '0'});
                    parts.push(.{ .group = e - '0' });
                } else parts.push(.{ .case = e });
                continue;
            }
            if (simpleEsc(e)) |b| {
                cur.push(b);
            } else if (charEscape(raw, i)) |ce| {
                cur.push(ce.b);
                i += ce.n;
            } else cur.push(e);
        }
        if (cur.len > 0) parts.push(.{ .lit = A.dupe(u8, cur.slice()) catch @panic("oom") });
        _ = self;
        return parts.items;
    }
    fn yText(raw: []const u8) Fail![]const u8 {
        var out = Buf{};
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                i += 1;
                const e = raw[i];
                if (e == '\\') out.push('\\') else if (simpleEsc(e)) |b| out.push(b) else if (charEscape(raw, i)) |ce| {
                    out.push(ce.b);
                    i += ce.n;
                } else if (!std.ascii.isAlphanumeric(e)) out.push(e) else return die("unknown command: `\\{c}'", .{e});
            } else out.push(raw[i]);
        }
        return out.slice();
    }

    fn parse(self: *Parser) Fail!void {
        var braces = u.Vec(usize).init(A);
        while (true) {
            // skip separators
            while (self.pos < self.text.len and (std.ascii.isWhitespace(self.text[self.pos]) or self.text[self.pos] == ';')) self.pos += 1;
            if (self.pos >= self.text.len) break;
            if (self.text[self.pos] == '#') {
                while (self.pos < self.text.len and self.text[self.pos] != '\n') self.pos += 1;
                continue;
            }
            var cmd = Command{};
            cmd.a1 = try self.address();
            if (cmd.a1.kind != .none) {
                self.space();
                if (self.peek() == ',') {
                    self.pos += 1;
                    self.space();
                    const b = self.peek() orelse return die("unexpected `,'", .{});
                    if (b == '+') {
                        self.pos += 1;
                        cmd.a2 = .{ .kind = .plus, .n = try self.number() };
                    } else if (b == '~') {
                        self.pos += 1;
                        cmd.a2 = .{ .kind = .mult, .n = try self.number() };
                    } else {
                        const a = try self.address();
                        cmd.a2 = switch (a.kind) {
                            .line, .zero => .{ .kind = .line, .n = a.n },
                            .last => .{ .kind = .last },
                            .regex => .{ .kind = .regex, .rx = a.rx },
                            else => return die("unexpected `,'", .{}),
                        };
                    }
                }
                if (cmd.a1.kind == .zero and cmd.a2.kind != .regex) return die("invalid usage of line address 0", .{});
                if (cmd.a1.kind == .step and cmd.a2.kind == .line and false) {}
            }
            self.space();
            while (self.peek() == '!') {
                cmd.negate = true;
                self.pos += 1;
                self.space();
            }
            const k = self.peek() orelse return die("missing command", .{});
            self.pos += 1;
            cmd.kind = k;
            switch (k) {
                '{' => {
                    braces.push(self.cmds.items.len);
                },
                '}' => {
                    if (braces.items.len == 0) return die("unexpected `}}'", .{});
                    if (cmd.a1.kind != .none) return die("}} doesn't want any addresses", .{});
                    const idx = braces.items[braces.items.len - 1];
                    braces.pop();
                    self.cmds.items[idx].jump = self.cmds.items.len + 1;
                    try self.endCmd();
                },
                's' => try self.parseS(&cmd),
                'y' => {
                    const d = self.peek() orelse return die("unterminated `y' command", .{});
                    self.pos += 1;
                    const src = try yText(try self.delimited(d, false));
                    const dst = try yText(try self.delimited(d, false));
                    if (src.len != dst.len) return die("strings for `y' command are different lengths", .{});
                    cmd.text = src;
                    cmd.parts = A.alloc(Part, 1) catch @panic("oom");
                    cmd.parts[0] = .{ .lit = dst };
                    try self.endCmd();
                },
                'a', 'i', 'c' => cmd.text = try self.textArg(),
                ':' => {
                    if (cmd.a1.kind != .none) return die(": doesn't want any addresses", .{});
                    cmd.text = self.label(false);
                    if (cmd.text.len == 0) return die("\":\" lacks a label", .{});
                },
                'b', 't', 'T' => {
                    cmd.text = self.label(true);
                    try self.endCmd();
                },
                'r', 'R', 'w', 'W' => {
                    if (self.sandbox) return die("e/r/w commands disabled in sandbox mode", .{});
                    cmd.text = self.restOfLine();
                    if (cmd.text.len == 0) return die("missing filename in r/R/w/W commands", .{});
                },
                'e' => {
                    if (self.sandbox) return die("e/r/w commands disabled in sandbox mode", .{});
                    cmd.text = self.restOfLine();
                },
                'q', 'Q', 'l', 'L' => {
                    if ((k == 'q' or k == 'Q') and cmd.a2.kind != .none) return die("command only uses one address", .{});
                    self.space();
                    if (self.peek()) |d| if (std.ascii.isDigit(d)) {
                        cmd.int_arg = try self.number();
                    };
                    try self.endCmd();
                },
                'v' => {
                    _ = self.label(true);
                    try self.endCmd();
                },
                '=', 'd', 'D', 'g', 'G', 'h', 'H', 'n', 'N', 'p', 'P', 'x', 'z', 'F' => try self.endCmd(),
                else => return die("unknown command: `{c}'", .{k}),
            }
            if ((k == 'q' or k == 'Q' or k == '=') and cmd.a2.kind != .none and false) {}
            self.cmds.push(cmd);
        }
        if (braces.items.len > 0) return die("unmatched `{{'", .{});
        for (self.cmds.items) |*cm| if (cm.kind == 'b' or cm.kind == 't' or cm.kind == 'T') {
            cm.jump = self.cmds.items.len;
            if (cm.text.len > 0) {
                var found = false;
                for (self.cmds.items, 0..) |l, i| if (l.kind == ':' and std.mem.eql(u8, l.text, cm.text)) {
                    cm.jump = i;
                    found = true;
                    break;
                };
                if (!found) {
                    u.errf("sed: -e expression #1, char 0: can't find label for jump to `{s}'\n", .{cm.text});
                    return error.Label;
                }
            }
        };
    }
    fn parseS(self: *Parser, cmd: *Command) Fail!void {
        const d = self.peek() orelse return die("unterminated `s' command", .{});
        if (d == '\n' or d == '\\') return die("unterminated `s' command", .{});
        self.pos += 1;
        const pat = try self.delimited(d, true);
        const raw = try self.delimited(d, false);
        var icase = false;
        var mline = false;
        while (self.pos < self.text.len) {
            const f = self.text[self.pos];
            if (f == ';' or f == '\n' or f == '}' or f == '#') break;
            self.pos += 1;
            switch (f) {
                'g' => cmd.global = true,
                'p' => cmd.print = true,
                'i', 'I' => icase = true,
                'm', 'M' => mline = true,
                'e' => cmd.eval = true,
                ' ', '\t' => {},
                '0'...'9' => {
                    self.pos -= 1;
                    cmd.occurrence = try self.number();
                    if (cmd.occurrence == 0) return die("number option to `s' command may not be zero", .{});
                },
                'w' => {
                    if (self.sandbox) return die("e/r/w commands disabled in sandbox mode", .{});
                    cmd.write_file = self.restOfLine();
                    if (cmd.write_file.?.len == 0) return die("missing filename in r/R/w/W commands", .{});
                    break;
                },
                else => return die("unknown option to `s'", .{}),
            }
        }
        if (pat.len > 0) cmd.rx = try compileRx(pat, self.ext, icase, mline);
        cmd.parts = try self.replacement(raw, if (cmd.rx) |r| r.nsub else null);
    }
};

// ---------------------------------------------------------------- input
const Input = struct {
    names: []const []const u8,
    idx: usize = 0,
    fd: i32 = -1,
    buf: []u8 = &.{},
    start: usize = 0,
    end: usize = 0,
    eof: bool = true,
    delim: u8,
    cur_name: []const u8 = "-",
    reader_name: []const u8 = "-",
    lineno: usize = 0,
    failed: bool = false,
    dir_ok: bool = false,

    fn closeCur(self: *Input) void {
        if (self.fd > 0) _ = linux.close(self.fd);
        self.fd = -1;
        self.eof = true;
        self.start = 0;
        self.end = 0;
    }
    fn openNext(self: *Input) bool {
        while (self.idx < self.names.len) {
            const name = self.names[self.idx];
            self.idx += 1;
            if (std.mem.eql(u8, name, "-")) {
                self.fd = 0;
            } else {
                const f = u.File.open(name, .{ .ACCMODE = .RDONLY }, 0) orelse {
                    u.errf("sed: can't read {s}: No such file or directory\n", .{name});
                    self.failed = true;
                    continue;
                };
                if (u.statFd(f.fd)) |st| if (st.mode & linux.S.IFMT == linux.S.IFDIR) {
                    u.errf("sed: couldn't edit {s}: not a regular file\n", .{name});
                    f.close();
                    self.failed = true;
                    continue;
                };
                self.fd = f.fd;
            }
            self.reader_name = name;
            self.eof = false;
            self.start = 0;
            self.end = 0;
            return true;
        }
        return false;
    }
    fn fill(self: *Input) bool {
        if (self.eof) return false;
        if (self.start == self.end) {
            self.start = 0;
            self.end = 0;
        }
        if (self.end == self.buf.len) {
            if (self.start > 0) {
                std.mem.copyForwards(u8, self.buf[0 .. self.end - self.start], self.buf[self.start..self.end]);
                self.end -= self.start;
                self.start = 0;
            } else {
                const nb = A.alloc(u8, if (self.buf.len == 0) 65536 else self.buf.len * 2) catch @panic("oom");
                @memcpy(nb[0..self.end], self.buf[0..self.end]);
                if (self.buf.len > 0) A.free(self.buf);
                self.buf = nb;
            }
        }
        while (true) {
            const rc = linux.read(self.fd, self.buf.ptr + self.end, self.buf.len - self.end);
            switch (u.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) {
                        self.eof = true;
                        return false;
                    }
                    self.end += rc;
                    return true;
                },
                .INTR => continue,
                else => {
                    u.errf("sed: read error on {s}: {s}\n", .{ self.reader_name, u.strerr(u.errno(rc)) });
                    self.failed = true;
                    self.eof = true;
                    return false;
                },
            }
        }
    }
    /// Is there another line? `cross` lets the search continue into later files.
    fn hasMore(self: *Input, cross: bool) bool {
        while (true) {
            if (self.start < self.end) return true;
            if (!self.eof and self.fill()) return true;
            if (!cross) return false;
            self.closeCur();
            if (!self.openNext()) return false;
        }
    }
    fn readLine(self: *Input, ps: *Buf, terminated: *bool, cross: bool) bool {
        if (!self.hasMore(cross)) return false;
        self.cur_name = self.reader_name;
        var scanned: usize = 0;
        while (true) {
            const hay = self.buf[self.start..self.end];
            if (std.mem.indexOfScalarPos(u8, hay, scanned, self.delim)) |at| {
                ps.set(hay[0..at]);
                self.start += at + 1;
                terminated.* = true;
                self.lineno += 1;
                return true;
            }
            scanned = hay.len;
            const had = self.end - self.start;
            if (!self.fill()) {
                ps.set(self.buf[self.start..self.end]);
                self.start = self.end;
                terminated.* = false;
                self.lineno += 1;
                return true;
            }
            _ = had;
            scanned = 0;
        }
    }
};

// ---------------------------------------------------------------- execution
const Writer = struct { name: []const u8, out: *Out };
const Rfile = struct { name: []const u8, input: ?*Input };
const Queued = union(enum) { text: []const u8, file: []const u8, line: []const u8 };

const Sed = struct {
    cmds: []Command,
    quiet: bool,
    separate: bool,
    delim: u8,
    line_len: usize,
    posix: bool = false,
    ps: Buf = .{},
    ps_term: bool = true,
    hold: Buf = .{},
    hold_term: bool = true,
    tmp: Buf = .{},
    out: *Out,
    real_out: *Out,
    stdout_view: *Out,
    err_out: *Out,
    writers: u.Vec(Writer) = u.Vec(Writer).init(A),
    rfiles: u.Vec(Rfile) = u.Vec(Rfile).init(A),
    queue: u.Vec(Queued) = u.Vec(Queued).init(A),
    input: *Input,
    status: u8 = 0,
    replaced: bool = false,
    quit: bool = false,
    cross: bool = true,

    fn resolve(self: *Sed, rx: ?*Rx) ?*Rx {
        _ = self;
        if (rx) |r| return r;
        if (g_last_rx) |r| return r;
        u.err("sed: no previous regular expression\n");
        return null;
    }
    fn matchAddr(self: *Sed, a: Addr) bool {
        return switch (a.kind) {
            .none => true,
            .line => self.input.lineno == a.n,
            .zero => false,
            .last => self.isLast(),
            .step => blk: {
                const l = self.input.lineno;
                if (a.step == 0) break :blk l == a.n;
                break :blk l >= a.n and (l - a.n) % a.step == 0;
            },
            .regex => blk: {
                const rx = self.resolve(a.rx) orelse break :blk false;
                const z = zcopy(self.ps.slice());
                var pm: Match = undefined;
                break :blk rxSearch(rx, z, self.ps.len, 0, &pm);
            },
        };
    }
    fn isLast(self: *Sed) bool {
        return !self.input.hasMore(self.cross);
    }
    fn selected(self: *Sed, cmd: *Command) bool {
        if (cmd.a1.kind == .none) return !cmd.negate;
        const hit = self.rangeHit(cmd);
        return hit != cmd.negate;
    }
    fn rangeHit(self: *Sed, cmd: *Command) bool {
        const l = self.input.lineno;
        if (cmd.a2.kind == .none) return self.matchAddr(cmd.a1);
        if (cmd.active) {
            switch (cmd.a2.kind) {
                .plus, .mult => {
                    // GNU quirk: a missed numeric end still matches once, then closes
                    if (l >= cmd.range_end) {
                        cmd.active = false;
                        cmd.closed = true;
                    }
                    return true;
                },
                .line => {
                    if (l > cmd.range_end) {
                        cmd.active = false;
                        cmd.closed = true;
                        return self.rangeStart(cmd);
                    }
                    if (l == cmd.range_end) {
                        cmd.active = false;
                        cmd.closed = true;
                    }
                    return true;
                },
                .last => {
                    if (self.isLast()) {
                        cmd.active = false;
                        cmd.closed = true;
                    }
                    return true;
                },
                .regex => {
                    const rx = self.resolve(cmd.a2.rx);
                    if (rx) |r| {
                        const z = zcopy(self.ps.slice());
                        var pm: Match = undefined;
                        if (rxSearch(r, z, self.ps.len, 0, &pm)) {
                            cmd.active = false;
                            cmd.closed = true;
                        }
                    }
                    return true;
                },
                .none => return true,
            }
        }
        return self.rangeStart(cmd);
    }
    fn rangeStart(self: *Sed, cmd: *Command) bool {
        const l = self.input.lineno;
        if (cmd.a1.kind == .zero) {
            return false;
        }
        if (cmd.a1.kind == .line) {
            // GNU: a numeric first address starts the range once the line number is reached
            if (cmd.closed or l < cmd.a1.n) return false;
        } else if (!self.matchAddr(cmd.a1)) return false;
        switch (cmd.a2.kind) {
            .line => {
                if (cmd.a2.n <= l) {
                    cmd.closed = true;
                    return cmd.a1.kind != .line or l == cmd.a1.n;
                }
                cmd.range_end = cmd.a2.n;
            },
            .plus => {
                if (cmd.a2.n == 0) {
                    cmd.closed = true;
                    return true;
                }
                cmd.range_end = l + cmd.a2.n;
            },
            .mult => {
                if (cmd.a2.n == 0) {
                    cmd.closed = true;
                    return true;
                }
                cmd.range_end = (l / cmd.a2.n + 1) * cmd.a2.n;
            },
            .last => if (self.isLast()) {
                cmd.closed = true;
                return true;
            },
            else => {},
        }
        cmd.active = true;
        return true;
    }

    fn writerFor(self: *Sed, name: []const u8) ?*Out {
        if (std.mem.eql(u8, name, "/dev/stdout")) return self.stdout_view;
        if (std.mem.eql(u8, name, "/dev/stderr")) return self.err_out;
        for (self.writers.items) |w| if (std.mem.eql(u8, w.name, name)) return w.out;
        return null;
    }
    fn openWriters(self: *Sed) Fail!void {
        for (self.cmds) |cm| {
            const name = cm.write_file orelse if (cm.kind == 'w' or cm.kind == 'W') cm.text else continue;
            if (self.writerFor(name) != null) continue;
            const f = u.File.open(name, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666) orelse return die("couldn't open file {s}: {s}", .{ name, u.strerr(u.errno(@bitCast(@as(isize, -@as(isize, @intFromEnum(linux.E.NOENT)))))) });
            const o = A.create(Out) catch @panic("oom");
            o.* = .{ .fd = f.fd, .delim = self.delim };
            self.writers.push(.{ .name = name, .out = o });
        }
    }
    fn flushQueue(self: *Sed) void {
        for (self.queue.items) |q| switch (q) {
            .text => |t| self.out.raw(t),
            .line => |t| {
                self.out.fixNewline();
                self.out.write(t);
                self.out.write(&[_]u8{self.delim});
            },
            .file => |name| {
                self.out.fixNewline();
                if (std.mem.eql(u8, name, "/dev/stdin")) {
                    if (@import("input.zig").read("-", true)) |d| self.out.write(d);
                } else if (@import("input.zig").read(name, true)) |d| self.out.write(d);
            },
        };
        self.queue.items.len = 0;
    }
    fn rfileLine(self: *Sed, name: []const u8) ?[]const u8 {
        var rf: ?*Rfile = null;
        for (self.rfiles.items) |*r| if (std.mem.eql(u8, r.name, name)) {
            rf = r;
            break;
        };
        if (rf == null) {
            self.rfiles.push(.{ .name = name, .input = null });
            rf = &self.rfiles.items[self.rfiles.items.len - 1];
            const names = A.alloc([]const u8, 1) catch @panic("oom");
            names[0] = if (std.mem.eql(u8, name, "/dev/stdin")) "-" else name;
            const inp = A.create(Input) catch @panic("oom");
            inp.* = .{ .names = names, .delim = self.delim };
            if (inp.openNext()) rf.?.input = inp;
        }
        const inp = rf.?.input orelse return null;
        var b = Buf{};
        var t: bool = true;
        if (!inp.readLine(&b, &t, false)) return null;
        return b.slice();
    }

    fn caseAppend(out: *Buf, text: []const u8, mode: *u8, once: *u8) void {
        for (text) |b| {
            var x = b;
            if (once.* != 0) {
                x = if (once.* == 'u') std.ascii.toUpper(b) else std.ascii.toLower(b);
                once.* = 0;
            } else if (mode.* == 'U') x = std.ascii.toUpper(b) else if (mode.* == 'L') x = std.ascii.toLower(b);
            out.push(x);
        }
    }
    fn expand(self: *Sed, out: *Buf, parts: []Part, z: []const u8, pm: *Match) void {
        _ = self;
        var mode: u8 = 0;
        var once: u8 = 0;
        for (parts) |p| switch (p) {
            .lit => |t| caseAppend(out, t, &mode, &once),
            .group => |gi| if (pm[gi].rm_so >= 0) caseAppend(out, z[@intCast(pm[gi].rm_so)..@intCast(pm[gi].rm_eo)], &mode, &once),
            .case => |ch| switch (ch) {
                'U', 'L' => {
                    mode = ch;
                    once = 0;
                },
                'E' => {
                    mode = 0;
                    once = 0;
                },
                else => once = ch,
            },
        };
    }
    fn subst(self: *Sed, cmd: *Command) bool {
        const rx = self.resolve(cmd.rx) orelse return false;
        const text = self.ps.slice();
        const z = zcopy(text);
        self.tmp.len = 0;
        var pm: Match = undefined;
        var pos: usize = 0;
        var copied: usize = 0;
        var count: usize = 0;
        var did = false;
        var prev_end: ?usize = null;
        while (pos <= text.len) {
            if (!rxSearch(rx, z, text.len, pos, &pm)) break;
            const ms: usize = @intCast(pm[0].rm_so);
            const me: usize = @intCast(pm[0].rm_eo);
            if (ms == me and prev_end != null and prev_end.? == ms) {
                pos = ms + 1;
                prev_end = null;
                continue;
            }
            count += 1;
            if (cmd.occurrence == 0 or count >= cmd.occurrence) {
                self.tmp.append(text[copied..ms]);
                self.expand(&self.tmp, cmd.parts, text, &pm);
                copied = me;
                did = true;
                if (!cmd.global) break;
            }
            if (ms == me) {
                pos = ms + 1;
                prev_end = null;
            } else {
                pos = me;
                prev_end = me;
            }
        }
        if (!did) return false;
        self.tmp.append(text[copied..]);
        std.mem.swap(Buf, &self.ps, &self.tmp);
        return true;
    }
    fn runCommand(self: *Sed, cmdline: []const u8) ?[]u8 {
        self.out.flush();
        self.real_out.flush();
        const z = u.zstr(cmdline);
        defer A.free(z);
        const fp = c.popen(z.ptr, "r") orelse return null;
        var res = Buf{};
        var tmpb: [4096]u8 = undefined;
        while (true) {
            const n = c.fread(&tmpb, 1, tmpb.len, fp);
            if (n == 0) break;
            res.append(tmpb[0..n]);
        }
        _ = c.pclose(fp);
        return res.data[0..res.len];
    }
    fn listLine(self: *Sed, width: usize) void {
        var o = Buf{};
        var cur: usize = 0;
        for (self.ps.slice()) |b| {
            var rep: [4]u8 = undefined;
            var n: usize = 0;
            switch (b) {
                '\\' => {
                    rep[0] = '\\';
                    rep[1] = '\\';
                    n = 2;
                },
                0x07, 0x08, 0x0c, '\n', '\r', '\t', 0x0b => {
                    rep[0] = '\\';
                    rep[1] = switch (b) {
                        0x07 => 'a',
                        0x08 => 'b',
                        0x0c => 'f',
                        '\n' => 'n',
                        '\r' => 'r',
                        '\t' => 't',
                        else => 'v',
                    };
                    n = 2;
                },
                else => {
                    if (b >= 32 and b < 127) {
                        rep[0] = b;
                        n = 1;
                    } else {
                        rep[0] = '\\';
                        rep[1] = '0' + (b >> 6);
                        rep[2] = '0' + ((b >> 3) & 7);
                        rep[3] = '0' + (b & 7);
                        n = 4;
                    }
                },
            }
            if (width > 0 and cur + n > width - 1) {
                o.push('\\');
                o.push(self.delim);
                cur = 0;
            }
            o.append(rep[0..n]);
            cur += n;
        }
        o.push('$');
        o.push(self.delim);
        self.out.raw(o.slice());
    }

    const Cycle = enum { next_cycle, quit_now };
    /// Process the pattern space already loaded. Returns .quit_now when sed must stop.
    fn cycle(self: *Sed) Fail!Cycle {
        var pc: usize = 0;
        var autoprint = !self.quiet;
        while (pc < self.cmds.len) {
            const cmd = &self.cmds[pc];
            pc += 1;
            if (!self.selected(cmd)) {
                if (cmd.kind == '{') pc = cmd.jump;
                continue;
            }
            switch (cmd.kind) {
                '{', '}', ':', 'v' => {},
                's' => {
                    if (self.subst(cmd)) {
                        self.replaced = true;
                        if (cmd.eval) {
                            if (self.runCommand(self.ps.slice())) |res| {
                                var r = res;
                                if (r.len > 0 and r[r.len - 1] == '\n') r = r[0 .. r.len - 1];
                                self.ps.set(r);
                            }
                        }
                        if (cmd.print) self.out.line(self.ps.slice(), self.ps_term);
                        if (cmd.write_file) |name| if (self.writerFor(name)) |w| w.line(self.ps.slice(), self.ps_term);
                    }
                },
                'y' => {
                    const dst = cmd.parts[0].lit;
                    for (self.ps.data[0..self.ps.len]) |*b| if (std.mem.indexOfScalar(u8, cmd.text, b.*)) |at| {
                        b.* = dst[at];
                    };
                },
                'p' => self.out.line(self.ps.slice(), self.ps_term),
                'P' => {
                    const t = self.ps.slice();
                    if (std.mem.indexOfScalar(u8, t, self.delim)) |at| self.out.line(t[0..at], true) else self.out.line(t, self.ps_term);
                },
                '=' => {
                    var b: [32]u8 = undefined;
                    self.out.raw(std.fmt.bufPrint(&b, "{d}", .{self.input.lineno}) catch "");
                    self.out.raw(&[_]u8{self.delim});
                },
                'F' => {
                    self.out.raw(self.input.cur_name);
                    self.out.raw(&[_]u8{self.delim});
                },
                'd' => {
                    autoprint = false;
                    break;
                },
                'D' => {
                    if (std.mem.indexOfScalar(u8, self.ps.slice(), self.delim)) |at| {
                        const rest = A.dupe(u8, self.ps.data[at + 1 .. self.ps.len]) catch @panic("oom");
                        self.ps.set(rest);
                        A.free(rest);
                        self.flushQueue();
                        pc = 0;
                        for (self.cmds) |*cm| if (cm.a2.kind != .none and false) {
                            cm.active = false;
                        };
                        continue;
                    }
                    autoprint = false;
                    break;
                },
                'z' => self.ps.len = 0,
                'h' => {
                    self.hold.set(self.ps.slice());
                    self.hold_term = self.ps_term;
                },
                'H' => {
                    self.hold.push(self.delim);
                    self.hold.append(self.ps.slice());
                    self.hold_term = self.ps_term;
                },
                'g' => {
                    self.ps.set(self.hold.slice());
                    self.ps_term = self.hold_term;
                },
                'G' => {
                    self.ps.push(self.delim);
                    self.ps.append(self.hold.slice());
                    self.ps_term = self.hold_term;
                },
                'x' => {
                    std.mem.swap(Buf, &self.ps, &self.hold);
                    std.mem.swap(bool, &self.ps_term, &self.hold_term);
                },
                'n' => {
                    if (!self.input.hasMore(self.cross)) {
                        if (self.posix) autoprint = false;
                        self.quit = true;
                        break;
                    }
                    if (!self.quiet) self.out.line(self.ps.slice(), self.ps_term);
                    self.flushQueue();
                    _ = self.input.readLine(&self.ps, &self.ps_term, self.cross);
                },
                'N' => {
                    if (!self.input.hasMore(self.cross)) {
                        if (self.posix) autoprint = false;
                        self.quit = true;
                        break;
                    }
                    self.flushQueue();
                    self.ps.push(self.delim);
                    var t = Buf{};
                    _ = self.input.readLine(&t, &self.ps_term, self.cross);
                    self.ps.append(t.slice());
                    if (t.data.len > 0) A.free(t.data);
                },
                'a' => self.queue.push(.{ .text = cmd.text }),
                'i' => {
                    self.out.raw(cmd.text[0..@max(cmd.text.len, 1) - 1]);
                    if (cmd.text.len > 0) self.out.raw(&[_]u8{self.delim});
                },
                'c' => {
                    if (!cmd.active or cmd.a2.kind == .none) {
                        self.out.raw(cmd.text[0..@max(cmd.text.len, 1) - 1]);
                        self.out.raw(&[_]u8{self.delim});
                    }
                    autoprint = false;
                    break;
                },
                'r' => self.queue.push(.{ .file = cmd.text }),
                'R' => if (self.rfileLine(cmd.text)) |l| self.queue.push(.{ .line = l }),
                'w' => if (self.writerFor(cmd.text)) |w| w.line(self.ps.slice(), self.ps_term),
                'W' => if (self.writerFor(cmd.text)) |w| {
                    const t = self.ps.slice();
                    if (std.mem.indexOfScalar(u8, t, self.delim)) |at| w.line(t[0..at], true) else w.line(t, self.ps_term);
                },
                'b' => pc = cmd.jump,
                't' => if (self.replaced) {
                    self.replaced = false;
                    pc = cmd.jump;
                },
                'T' => {
                    if (!self.replaced) pc = cmd.jump else self.replaced = false;
                },
                'e' => {
                    if (cmd.text.len > 0) {
                        if (self.runCommand(cmd.text)) |res| self.out.raw(res);
                    } else if (self.runCommand(self.ps.slice())) |res| {
                        var r = res;
                        if (r.len > 0 and r[r.len - 1] == '\n') r = r[0 .. r.len - 1];
                        self.ps.set(r);
                    }
                },
                'l' => self.listLine(if (cmd.int_arg) |n| n else self.line_len),
                'L' => {},
                'q' => {
                    if (autoprint) self.out.line(self.ps.slice(), true);
                    self.flushQueue();
                    self.status = @intCast(@min(cmd.int_arg orelse 0, 255));
                    return .quit_now;
                },
                'Q' => {
                    self.status = @intCast(@min(cmd.int_arg orelse 0, 255));
                    return .quit_now;
                },
                else => {},
            }
        }
        if (autoprint) self.out.line(self.ps.slice(), self.ps_term);
        self.flushQueue();
        return if (self.quit) .quit_now else .next_cycle;
    }
    fn resetRanges(self: *Sed) void {
        for (self.cmds) |*cm| {
            cm.active = cm.a1.kind == .zero;
            cm.closed = false;
        }
    }
    /// Run the program over `input`. Returns true if a quit command ended processing.
    fn process(self: *Sed) Fail!bool {
        self.resetRanges();
        while (self.input.readLine(&self.ps, &self.ps_term, self.cross)) {
            self.replaced = false;
            if (try self.cycle() == .quit_now) return true;
            if (self.out.always_flush) self.out.flush();
        }
        return false;
    }
};

// ---------------------------------------------------------------- driver
fn usage(code: u8) u8 {
    const text =
        "Usage: sed [OPTION]... {script-only-if-no-other-script} [input-file]...\n\n" ++
        "  -n, --quiet, --silent\n                 suppress automatic printing of pattern space\n" ++
        "  -e script, --expression=script\n                 add the script to the commands to be executed\n" ++
        "  -f script-file, --file=script-file\n                 add the contents of script-file to the commands to be executed\n" ++
        "  -E, -r, --regexp-extended\n                 use extended regular expressions in the script\n" ++
        "  -i[SUFFIX], --in-place[=SUFFIX]\n                 edit files in place (makes backup if SUFFIX supplied)\n" ++
        "  -l N, --line-length=N\n                 specify the desired line-wrap length for the `l' command\n" ++
        "  -s, --separate\n                 consider files as separate rather than as a single\n                 continuous long stream.\n" ++
        "  -u, --unbuffered\n                 load minimal amounts of data from the input files and flush\n                 the output buffers more often\n" ++
        "  -z, --null-data\n                 separate lines by NUL characters\n" ++
        "      --help     display this help and exit\n      --version  output version information and exit\n";
    if (code == 0) u.out(text) else u.err(text);
    return code;
}

const long_opts = [_][]const u8{ "quiet", "silent", "expression", "file", "regexp-extended", "in-place", "line-length", "separate", "unbuffered", "null-data", "zero-terminated", "binary", "posix", "debug", "sandbox", "follow-symlinks", "help", "version" };

fn backupName(name: []const u8, suffix: []const u8) []const u8 {
    const base = u.basename(name);
    const dir = u.dirname(name);
    var b = Buf{};
    var rel: []const u8 = undefined;
    if (std.mem.indexOfScalar(u8, suffix, '*') != null) {
        var t = Buf{};
        for (suffix) |ch| if (ch == '*') t.append(base) else t.push(ch);
        rel = t.slice();
    } else {
        var t = Buf{};
        t.append(base);
        t.append(suffix);
        rel = t.slice();
    }
    if (std.mem.indexOfScalar(u8, rel, '/') != null) {
        b.append(rel);
    } else if (std.mem.indexOfScalar(u8, name, '/') != null) {
        b.append(dir);
        b.push('/');
        b.append(rel);
    } else b.append(rel);
    return b.slice();
}

pub fn run(args: []const []const u8) u8 {
    return runInner(args) catch |e| switch (e) {
        error.Label, error.Io => 4,
        else => 1,
    };
}
fn runInner(args: []const []const u8) Fail!u8 {
    g_last_rx = null;
    var quiet = false;
    var extended = false;
    var separate = false;
    var delim: u8 = '\n';
    var inplace: ?[]const u8 = null;
    var line_len: usize = 70;
    var unbuffered = false;
    var posix = false;
    var sandbox = false;
    var script = Buf{};
    var have_script = false;
    var files = u.Vec([]const u8).init(A);
    var no_more_opts = false;
    var i: usize = 0;
    var first_chunk_checked = false;
    var force_quiet = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!no_more_opts and std.mem.eql(u8, arg, "--")) {
            no_more_opts = true;
            continue;
        }
        if (!no_more_opts and std.mem.startsWith(u8, arg, "--")) {
            const eq = std.mem.indexOfScalar(u8, arg, '=');
            const given = if (eq) |e| arg[2..e] else arg[2..];
            var match: ?[]const u8 = null;
            var count: usize = 0;
            for (long_opts) |o| {
                if (std.mem.eql(u8, o, given)) {
                    match = o;
                    count = 1;
                    break;
                }
                if (std.mem.startsWith(u8, o, given)) {
                    match = o;
                    count += 1;
                }
            }
            if (count != 1 or match == null) {
                u.errf("sed: unrecognized option '{s}'\n", .{arg});
                return usage(1);
            }
            const name = match.?;
            const val: ?[]const u8 = if (eq) |e| arg[e + 1 ..] else null;
            if (std.mem.eql(u8, name, "quiet") or std.mem.eql(u8, name, "silent")) quiet = true else if (std.mem.eql(u8, name, "regexp-extended")) extended = true else if (std.mem.eql(u8, name, "separate")) separate = true else if (std.mem.eql(u8, name, "null-data") or std.mem.eql(u8, name, "zero-terminated")) delim = 0 else if (std.mem.eql(u8, name, "unbuffered")) unbuffered = true else if (std.mem.eql(u8, name, "posix")) posix = true else if (std.mem.eql(u8, name, "sandbox")) sandbox = true else if (std.mem.eql(u8, name, "in-place")) inplace = val orelse "" else if (std.mem.eql(u8, name, "help")) return usage(0) else if (std.mem.eql(u8, name, "version")) {
                u.out("sed (GNU sed) 4.9\n");
                return 0;
            } else if (std.mem.eql(u8, name, "line-length")) {
                const v = val orelse blk: {
                    i += 1;
                    if (i >= args.len) return usage(1);
                    break :blk args[i];
                };
                line_len = std.fmt.parseInt(usize, v, 10) catch return die("invalid line length", .{});
            } else if (std.mem.eql(u8, name, "expression") or std.mem.eql(u8, name, "file")) {
                const v = val orelse blk: {
                    i += 1;
                    if (i >= args.len) return usage(1);
                    break :blk args[i];
                };
                try addScript(&script, &have_script, &first_chunk_checked, &force_quiet, v, std.mem.eql(u8, name, "file"));
            }
            continue;
        }
        if (!no_more_opts and arg.len > 1 and arg[0] == '-') {
            var k: usize = 1;
            while (k < arg.len) : (k += 1) switch (arg[k]) {
                'n' => quiet = true,
                'E', 'r' => extended = true,
                's' => separate = true,
                'z' => delim = 0,
                'u' => unbuffered = true,
                'b' => {},
                'i' => {
                    inplace = arg[k + 1 ..];
                    break;
                },
                'l' => {
                    const v = if (k + 1 < arg.len) arg[k + 1 ..] else blk: {
                        i += 1;
                        if (i >= args.len) return usage(1);
                        break :blk args[i];
                    };
                    line_len = std.fmt.parseInt(usize, v, 10) catch return die("invalid line length", .{});
                    break;
                },
                'e', 'f' => |flag| {
                    const v = if (k + 1 < arg.len) arg[k + 1 ..] else blk: {
                        i += 1;
                        if (i >= args.len) return usage(1);
                        break :blk args[i];
                    };
                    try addScript(&script, &have_script, &first_chunk_checked, &force_quiet, v, flag == 'f');
                    break;
                },
                else => {
                    u.errf("sed: invalid option -- '{c}'\n", .{arg[k]});
                    return usage(1);
                },
            };
            continue;
        }
        if (!have_script) {
            try addScript(&script, &have_script, &first_chunk_checked, &force_quiet, arg, false);
        } else files.push(arg);
    }
    if (!have_script) return usage(1);
    if (force_quiet) quiet = true;

    var parser = Parser{ .text = script.slice(), .ext = extended, .sandbox = sandbox, .delim = delim };
    try parser.parse();
    if (inplace != null) separate = true;

    var stdout_o = Out{ .fd = 1, .delim = delim, .always_flush = unbuffered };
    var stdout_view = Out{ .fd = 1, .delim = delim, .parent = &stdout_o };
    var stderr_o = Out{ .fd = 2, .delim = delim, .always_flush = true };
    var s = Sed{
        .cmds = parser.cmds.items,
        .quiet = quiet,
        .separate = separate,
        .delim = delim,
        .line_len = line_len,
        .posix = posix,
        .out = &stdout_o,
        .real_out = &stdout_o,
        .stdout_view = &stdout_view,
        .err_out = &stderr_o,
        .input = undefined,
    };
    try s.openWriters();
    defer for (s.writers.items) |w| w.out.flush();

    if (files.items.len == 0) {
        if (inplace != null) return die("no input files", .{});
        files.push("-");
    }
    var status: u8 = 0;
    var failed = false;
    if (!separate) {
        var inp = Input{ .names = files.items, .delim = delim };
        s.input = &inp;
        s.cross = true;
        _ = try s.process();
        failed = inp.failed;
        status = s.status;
    } else {
        var quit = false;
        for (files.items) |name| {
            if (quit) break;
            const one = A.alloc([]const u8, 1) catch @panic("oom");
            one[0] = name;
            var inp = Input{ .names = one, .delim = delim };
            s.input = &inp;
            s.cross = false;
            if (inplace == null and !inp.openNext()) {
                failed = true;
                continue;
            }
            if (inplace) |suffix| {
                if (std.mem.eql(u8, name, "-")) {
                    u.err("sed: couldn't edit -: not a regular file\n");
                    status = 4;
                    continue;
                }
                const st = u.stat(name, true) orelse {
                    u.errf("sed: can't read {s}: No such file or directory\n", .{name});
                    failed = true;
                    continue;
                };
                if (st.mode & linux.S.IFMT != linux.S.IFREG) {
                    u.errf("sed: couldn't edit {s}: not a regular file\n", .{name});
                    status = 4;
                    continue;
                }
                const dir = if (std.mem.indexOfScalar(u8, name, '/') != null) u.dirname(name) else ".";
                const temp = std.fmt.allocPrint(A, "{s}/sed{d:0>6}", .{ dir, @as(u32, @intCast(linux.getpid())) }) catch @panic("oom");
                const tf = u.File.open(temp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600) orelse {
                    u.errf("sed: couldn't open temporary file {s}: Permission denied\n", .{temp});
                    return 4;
                };
                var fo = Out{ .fd = tf.fd, .delim = delim };
                s.out = &fo;
                _ = inp.openNext();
                quit = try s.process();
                fo.flush();
                _ = linux.fchown(tf.fd, st.uid, st.gid);
                _ = linux.fchmod(tf.fd, st.mode & 0o7777);
                tf.close();
                if (inp.failed) failed = true;
                if (suffix.len > 0) {
                    const bk = backupName(name, suffix);
                    _ = linux.rename(u.zstr(name), u.zstr(bk));
                }
                _ = linux.rename(u.zstr(temp), u.zstr(name));
                s.out = &stdout_o;
            } else {
                quit = try s.process();
                if (inp.failed) failed = true;
            }
            status = s.status;
        }
    }
    stdout_o.flush();
    if (stdout_o.failed) return 4;
    if (status != 0) return status;
    return if (failed) 2 else 0;
}

fn addScript(script: *Buf, have: *bool, checked: *bool, force_quiet: *bool, v: []const u8, is_file: bool) Fail!void {
    var chunk: []const u8 = v;
    if (is_file) {
        chunk = @import("input.zig").read(v, true) orelse {
            u.errf("sed: couldn't open file {s}: No such file or directory\n", .{v});
            return error.Io;
        };
        if (chunk.len > 0 and chunk[chunk.len - 1] == '\n') chunk = chunk[0 .. chunk.len - 1];
    }
    if (!checked.*) {
        checked.* = true;
        if (chunk.len >= 2 and chunk[0] == '#' and chunk[1] == 'n' and (chunk.len == 2 or chunk[2] == '\n')) force_quiet.* = true;
    }
    if (have.*) script.push('\n');
    script.append(chunk);
    have.* = true;
}
