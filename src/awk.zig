// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// awk - POSIX awk with the commonly used GNU awk (gawk) extensions.
//
// A tree-walking interpreter.  Regular expressions use the statically linked
// musl POSIX ERE engine after translating awk's escape syntax.
//
// Memory model: temporaries live in an arena that is reset once per record
// cycle.  Values stored in variables, arrays and fields are duplicated into
// the persistent allocator; replaced storage is retired and freed at the end of
// the cycle so that values still referenced by an in-flight expression stay valid.
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const c = @cImport({
    @cInclude("regex.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("time.h");
    @cInclude("math.h");
    @cInclude("unistd.h");
});

const A = u.alloc;
const Err = error{ Exit, Next, NextFile, Fatal, Syntax };
const Flow = enum { normal, brk, cont, ret };

// ---------------------------------------------------------------- values
const Kind = enum { uninit, num, str, strnum };
const Val = struct {
    kind: Kind = .uninit,
    n: f64 = 0,
    s: []const u8 = "",
    cap: usize = 0, // spare capacity of a persistently owned string (append fast path)
    fn num(x: f64) Val {
        return .{ .kind = .num, .n = x };
    }
    fn str(x: []const u8) Val {
        return .{ .kind = .str, .s = x };
    }
};
const Array = struct { map: std.StringArrayHashMapUnmanaged(Val) = .empty };
const Cell = union(enum) { unset, val: Val, arr: *Array };

fn isBlank(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n';
}

const NumPrefix = struct { n: f64, len: usize, ok: bool };
/// Longest numeric prefix (after leading blanks); `len` is relative to `s`.
fn numPrefix(s: []const u8) NumPrefix {
    var i: usize = 0;
    while (i < s.len and (isBlank(s[i]) or s[i] == '\r' or s[i] == 0x0b or s[i] == 0x0c)) i += 1;
    const begin = i;
    var neg = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        neg = s[i] == '-';
        i += 1;
        // gawk accepts only signed inf/nan spellings
        if (i + 3 <= s.len) {
            const w = s[i .. i + 3];
            if (std.ascii.eqlIgnoreCase(w, "inf")) {
                var l: usize = 3;
                if (i + 8 <= s.len and std.ascii.eqlIgnoreCase(s[i .. i + 8], "infinity")) l = 8;
                return .{ .n = if (neg) -std.math.inf(f64) else std.math.inf(f64), .len = i + l, .ok = true };
            }
            if (std.ascii.eqlIgnoreCase(w, "nan")) return .{ .n = if (neg) std.math.copysign(std.math.nan(f64), -1.0) else std.math.nan(f64), .len = i + 3, .ok = true };
        }
    }
    const ds = i;
    var digits: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    }
    if (digits == 0) return .{ .n = 0, .len = 0, .ok = false };
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var j = i + 1;
        if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
        if (j < s.len and std.ascii.isDigit(s[j])) {
            while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
            i = j;
        }
    }
    _ = ds;
    var buf: [128]u8 = undefined;
    const text = s[begin..i];
    const slice = if (text.len < buf.len) blk: {
        @memcpy(buf[0..text.len], text);
        buf[text.len] = 0;
        break :blk buf[0..text.len :0];
    } else u.zstr(text);
    const value = c.strtod(slice.ptr, null);
    return .{ .n = value, .len = i, .ok = true };
}
fn strToNum(s: []const u8) f64 {
    return numPrefix(s).n;
}
fn looksNumeric(s: []const u8) ?f64 {
    const p = numPrefix(s);
    if (!p.ok) return null;
    var i = p.len;
    while (i < s.len and (isBlank(s[i]) or s[i] == '\r' or s[i] == 0x0b or s[i] == 0x0c)) i += 1;
    if (i != s.len) return null;
    return p.n;
}
fn mkStrnum(s: []const u8) Val {
    if (looksNumeric(s)) |n| return .{ .kind = .strnum, .n = n, .s = s };
    return Val.str(s);
}

// ---------------------------------------------------------------- regex
const Rx = struct { re: c.regex_t, empty: bool, nsub: usize };

fn isRegexMeta(ch: u8) bool {
    return std.mem.indexOfScalar(u8, ".[]()*+?{}|^$\\", ch) != null;
}
fn pushLit(out: *u.Vec(u8), ch: u8) void {
    if (isRegexMeta(ch)) out.push('\\');
    out.push(ch);
}
fn simpleEscape(ch: u8) ?u8 {
    return switch (ch) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        'f' => 0x0c,
        'v' => 0x0b,
        'a' => 0x07,
        'b' => 0x08,
        '/' => '/',
        '"' => '"',
        else => null,
    };
}
/// Parse \ddd or \xHH starting at s[i]==the char after backslash. Returns byte and length consumed.
fn numericEscape(s: []const u8, i: usize) ?struct { byte: u8, len: usize } {
    if (i >= s.len) return null;
    if (s[i] >= '0' and s[i] <= '7') {
        var v: u32 = 0;
        var k: usize = 0;
        while (k < 3 and i + k < s.len and s[i + k] >= '0' and s[i + k] <= '7') : (k += 1) v = v * 8 + (s[i + k] - '0');
        return .{ .byte = @truncate(v), .len = k };
    }
    if (s[i] == 'x' and i + 1 < s.len and std.ascii.isHex(s[i + 1])) {
        var v: u32 = 0;
        var k: usize = 1;
        while (k < 3 and i + k < s.len and std.ascii.isHex(s[i + k])) : (k += 1) v = v * 16 + (std.fmt.charToDigit(s[i + k], 16) catch 0);
        return .{ .byte = @truncate(v), .len = k };
    }
    return null;
}
fn validInterval(s: []const u8, i: usize) bool {
    // s[i] == '{'
    var j = i + 1;
    var d: usize = 0;
    while (j < s.len and std.ascii.isDigit(s[j])) : (j += 1) d += 1;
    if (d == 0) return false;
    if (j < s.len and s[j] == ',') {
        j += 1;
        while (j < s.len and std.ascii.isDigit(s[j])) : (j += 1) {}
    }
    return j < s.len and s[j] == '}';
}
fn translateBracket(src: []const u8, start: usize, out: *u.Vec(u8)) !usize {
    var j = start + 1;
    var negate = false;
    if (j < src.len and src[j] == '^') {
        negate = true;
        j += 1;
    }
    var body = u.Vec(u8).init(A);
    var rsb = false;
    var dash = false;
    var first = true;
    while (true) {
        if (j >= src.len) return error.Syntax;
        const ch = src[j];
        if (ch == ']' and !first) break;
        first = false;
        if (ch == '[' and j + 1 < src.len and (src[j + 1] == ':' or src[j + 1] == '.' or src[j + 1] == '=')) {
            const kind = src[j + 1];
            var k = j + 2;
            while (k + 1 < src.len and !(src[k] == kind and src[k + 1] == ']')) k += 1;
            if (k + 1 >= src.len) return error.Syntax;
            for (src[j .. k + 2]) |b| body.push(b);
            j = k + 2;
            continue;
        }
        if (ch == '\\' and j + 1 < src.len) {
            const e = src[j + 1];
            if (numericEscape(src, j + 1)) |ne| {
                if (ne.byte == ']') rsb = true else if (ne.byte == '-') dash = true else body.push(ne.byte);
                j += 1 + ne.len;
                continue;
            }
            if (simpleEscape(e)) |b| {
                body.push(b);
            } else if (e == ']') rsb = true else if (e == '-') dash = true else if (e == '\\') body.push('\\') else if (e == '^' and body.items.len == 0) {
                body.push('\\'); // keep literal ^ from becoming a negation (never first after '[')
                body.items.len -= 1;
                dash = dash; // no-op
                body.push('^');
                // a leading '^' would negate; move it after the first item by marking
            } else body.push(e);
            j += 2;
            continue;
        }
        body.push(ch);
        j += 1;
    }
    out.push('[');
    if (negate) out.push('^');
    if (rsb) out.push(']');
    // a literal '^' must not be first when not negated
    if (!negate and !rsb and body.items.len > 0 and body.items[0] == '^') {
        for (body.items[1..]) |b| out.push(b);
        out.push('^');
    } else for (body.items) |b| out.push(b);
    if (dash) out.push('-');
    out.push(']');
    return j + 1;
}
fn translateRegex(src: []const u8) ![]const u8 {
    var out = u.Vec(u8).init(A);
    var i: usize = 0;
    while (i < src.len) {
        const ch = src[i];
        switch (ch) {
            '\\' => {
                if (i + 1 >= src.len) {
                    out.push('\\');
                    out.push('\\');
                    i += 1;
                    continue;
                }
                const e = src[i + 1];
                if (numericEscape(src, i + 1)) |ne| {
                    pushLit(&out, ne.byte);
                    i += 1 + ne.len;
                    continue;
                }
                if (e == 'y') {
                    out.push('\\');
                    out.push('b');
                } else if (e == 'b') {
                    out.push(0x08);
                } else if (simpleEscape(e)) |b| {
                    pushLit(&out, b);
                } else if (e == 'B' or e == '<' or e == '>' or e == 'w' or e == 'W' or e == 's' or e == 'S') {
                    out.push('\\');
                    out.push(e);
                } else if (std.ascii.isAlphanumeric(e)) {
                    out.push(e);
                } else {
                    out.push('\\');
                    out.push(e);
                }
                i += 2;
            },
            '[' => i = try translateBracket(src, i, &out),
            '{' => {
                if (out.items.len > 0 and validInterval(src, i)) out.push('{') else {
                    out.push('\\');
                    out.push('{');
                }
                i += 1;
            },
            else => {
                out.push(ch);
                i += 1;
            },
        }
    }
    return out.items;
}

// ---------------------------------------------------------------- AST
const Tag = enum {
    num, str, regex, gvar, lvar, field, index, assign, cond, lor, land, in_, match, nmatch,
    cmp, concat, arith, neg, pos, not, preinc, predec, postinc, postdec, builtin, call,
    getline, group,
    s_expr, s_print, s_printf, s_if, s_while, s_do, s_for, s_forin, s_block, s_next,
    s_nextfile, s_exit, s_return, s_break, s_continue, s_delete,
};
const Node = struct {
    tag: Tag,
    op: u8 = 0,
    a: ?*Node = null,
    b: ?*Node = null,
    c: ?*Node = null,
    d: ?*Node = null,
    list: []*Node = &.{},
    n: f64 = 0,
    s: []const u8 = "",
    i: usize = 0,
    rx: ?*Rx = null,
};
const RuleKind = enum { begin, end, main, beginfile, endfile };
const Rule = struct { kind: RuleKind, p1: ?*Node, p2: ?*Node, action: ?*Node, in_range: bool = false };
const Func = struct { name: []const u8, nparams: usize = 0, body: ?*Node = null, defined: bool = false };

const B = enum {
    length, substr, index, split, sub, gsub, match, sprintf, sin, cos, atan2, exp, log, sqrt, int,
    rand, srand, tolower, toupper, system, close, fflush, gensub, strftime, systime, mktime,
    asort, asorti, patsplit, @"and", @"or", xor, lshift, rshift, compl, strtonum, isarray, typeof,
};

// ---------------------------------------------------------------- lexer
const T = enum {
    eof, nl, lbrace, rbrace, lparen, rparen, lbracket, rbracket, semi, comma, plus, minus, star,
    slash, percent, caret, not, gt, lt, pipe, question, colon, tilde, nomatch, dollar, assign,
    add_assign, sub_assign, mul_assign, div_assign, mod_assign, pow_assign, eq, ne, le, ge,
    and_, or_, incr, decr, append, number, string, ere, funcname, name, builtin,
    kw_begin, kw_end, kw_beginfile, kw_endfile, kw_function, kw_if, kw_else, kw_while, kw_for,
    kw_do, kw_break, kw_continue, kw_next, kw_nextfile, kw_exit, kw_return, kw_delete, kw_in,
    kw_getline, kw_print, kw_printf,
};
const Tok = struct { t: T = .eof, s: []const u8 = "", n: f64 = 0, start: usize = 0, b: B = .length };
const keywords = [_]struct { []const u8, T }{
    .{ "BEGIN", .kw_begin },       .{ "END", .kw_end },     .{ "BEGINFILE", .kw_beginfile },
    .{ "ENDFILE", .kw_endfile },   .{ "function", .kw_function }, .{ "func", .kw_function },
    .{ "if", .kw_if },             .{ "else", .kw_else },   .{ "while", .kw_while },
    .{ "for", .kw_for },           .{ "do", .kw_do },       .{ "break", .kw_break },
    .{ "continue", .kw_continue }, .{ "next", .kw_next },   .{ "nextfile", .kw_nextfile },
    .{ "exit", .kw_exit },         .{ "return", .kw_return }, .{ "delete", .kw_delete },
    .{ "in", .kw_in },             .{ "getline", .kw_getline }, .{ "print", .kw_print },
    .{ "printf", .kw_printf },
};

const SLOT_NF = 0;
const SLOT_NR = 1;
const SLOT_FNR = 2;
const SLOT_FS = 3;
const SLOT_OFS = 4;
const SLOT_ORS = 5;
const SLOT_RS = 6;
const SLOT_FILENAME = 7;
const SLOT_SUBSEP = 8;
const SLOT_RSTART = 9;
const SLOT_RLENGTH = 10;
const SLOT_CONVFMT = 11;
const SLOT_OFMT = 12;
const SLOT_ENVIRON = 13;
const SLOT_ARGC = 14;
const SLOT_ARGV = 15;
const SLOT_RT = 16;
const SLOT_IGNORECASE = 17;
const SLOT_FPAT = 18;
const special_names = [_][]const u8{ "NF", "NR", "FNR", "FS", "OFS", "ORS", "RS", "FILENAME", "SUBSEP", "RSTART", "RLENGTH", "CONVFMT", "OFMT", "ENVIRON", "ARGC", "ARGV", "RT", "IGNORECASE", "FPAT" };

const Parser = struct {
    it: *Interp,
    src: []const u8,
    pos: usize = 0,
    peeked: ?Tok = null,
    params: []const []const u8 = &.{},
    no_gt: bool = false,
    no_in: bool = false,
    line_of_error: usize = 0,

    const Saved = struct { pos: usize, peeked: ?Tok };
    fn save(self: *Parser) Saved {
        return .{ .pos = self.pos, .peeked = self.peeked };
    }
    fn restore(self: *Parser, s: Saved) void {
        self.pos = s.pos;
        self.peeked = s.peeked;
    }
    fn fail(self: *Parser, msg: []const u8) error{Syntax} {
        var line: usize = 1;
        for (self.src[0..@min(self.pos, self.src.len)]) |ch| if (ch == '\n') {
            line += 1;
        };
        u.errf("awk: line {d}: syntax error: {s}\n", .{ line, msg });
        return error.Syntax;
    }
    fn peek(self: *Parser) !Tok {
        if (self.peeked) |t| return t;
        const t = try self.lex();
        self.peeked = t;
        return t;
    }
    fn next(self: *Parser) !Tok {
        const t = try self.peek();
        self.peeked = null;
        return t;
    }
    fn accept(self: *Parser, t: T) !bool {
        if ((try self.peek()).t == t) {
            self.peeked = null;
            return true;
        }
        return false;
    }
    fn expect(self: *Parser, t: T, what: []const u8) !void {
        if (!try self.accept(t)) return self.fail(what);
    }
    fn skipNl(self: *Parser) !void {
        while ((try self.peek()).t == .nl) self.peeked = null;
    }
    fn skipTerms(self: *Parser) !void {
        while (true) {
            const t = (try self.peek()).t;
            if (t == .nl or t == .semi) self.peeked = null else break;
        }
    }

    fn lex(self: *Parser) !Tok {
        const s = self.src;
        while (self.pos < s.len) {
            const ch = s[self.pos];
            if (ch == ' ' or ch == '\t' or ch == '\r') {
                self.pos += 1;
            } else if (ch == '\\' and self.pos + 1 < s.len and s[self.pos + 1] == '\n') {
                self.pos += 2;
            } else if (ch == '\\' and self.pos + 2 < s.len and s[self.pos + 1] == '\r' and s[self.pos + 2] == '\n') {
                self.pos += 3;
            } else if (ch == '#') {
                while (self.pos < s.len and s[self.pos] != '\n') self.pos += 1;
            } else break;
        }
        const start = self.pos;
        if (self.pos >= s.len) return .{ .t = .eof, .start = start };
        const ch = s[self.pos];
        self.pos += 1;
        const nx: u8 = if (self.pos < s.len) s[self.pos] else 0;
        const simple = struct {
            fn tok(t: T, st: usize) Tok {
                return .{ .t = t, .start = st };
            }
        };
        switch (ch) {
            '\n' => return simple.tok(.nl, start),
            '{' => return simple.tok(.lbrace, start),
            '}' => return simple.tok(.rbrace, start),
            '(' => return simple.tok(.lparen, start),
            ')' => return simple.tok(.rparen, start),
            '[' => return simple.tok(.lbracket, start),
            ']' => return simple.tok(.rbracket, start),
            ';' => return simple.tok(.semi, start),
            ',' => return simple.tok(.comma, start),
            '?' => return simple.tok(.question, start),
            ':' => return simple.tok(.colon, start),
            '$' => return simple.tok(.dollar, start),
            '~' => return simple.tok(.tilde, start),
            '+' => {
                if (nx == '+') {
                    self.pos += 1;
                    return simple.tok(.incr, start);
                }
                if (nx == '=') {
                    self.pos += 1;
                    return simple.tok(.add_assign, start);
                }
                return simple.tok(.plus, start);
            },
            '-' => {
                if (nx == '-') {
                    self.pos += 1;
                    return simple.tok(.decr, start);
                }
                if (nx == '=') {
                    self.pos += 1;
                    return simple.tok(.sub_assign, start);
                }
                return simple.tok(.minus, start);
            },
            '*' => {
                if (nx == '*') {
                    self.pos += 1;
                    if (self.pos < s.len and s[self.pos] == '=') {
                        self.pos += 1;
                        return simple.tok(.pow_assign, start);
                    }
                    return simple.tok(.caret, start);
                }
                if (nx == '=') {
                    self.pos += 1;
                    return simple.tok(.mul_assign, start);
                }
                return simple.tok(.star, start);
            },
            '/' => {
                if (nx == '=') {
                    self.pos += 1;
                    return simple.tok(.div_assign, start);
                }
                return simple.tok(.slash, start);
            },
            '%' => {
                if (nx == '=') {
                    self.pos += 1;
                    return simple.tok(.mod_assign, start);
                }
                return simple.tok(.percent, start);
            },
            '^' => {
                if (nx == '=') {
                    self.pos += 1;
                    return simple.tok(.pow_assign, start);
                }
                return simple.tok(.caret, start);
            },
            '!' => {
                if (nx == '=') {
                    self.pos += 1;
                    return simple.tok(.ne, start);
                }
                if (nx == '~') {
                    self.pos += 1;
                    return simple.tok(.nomatch, start);
                }
                return simple.tok(.not, start);
            },
            '>' => {
                if (nx == '=') {
                    self.pos += 1;
                    return simple.tok(.ge, start);
                }
                if (nx == '>') {
                    self.pos += 1;
                    return simple.tok(.append, start);
                }
                return simple.tok(.gt, start);
            },
            '<' => {
                if (nx == '=') {
                    self.pos += 1;
                    return simple.tok(.le, start);
                }
                return simple.tok(.lt, start);
            },
            '=' => {
                if (nx == '=') {
                    self.pos += 1;
                    return simple.tok(.eq, start);
                }
                return simple.tok(.assign, start);
            },
            '&' => {
                if (nx == '&') {
                    self.pos += 1;
                    return simple.tok(.and_, start);
                }
                return self.fail("unexpected '&'");
            },
            '|' => {
                if (nx == '|') {
                    self.pos += 1;
                    return simple.tok(.or_, start);
                }
                return simple.tok(.pipe, start);
            },
            '"' => {
                var out = u.Vec(u8).init(A);
                while (true) {
                    if (self.pos >= s.len or s[self.pos] == '\n') return self.fail("unterminated string");
                    const d = s[self.pos];
                    self.pos += 1;
                    if (d == '"') break;
                    if (d != '\\') {
                        out.push(d);
                        continue;
                    }
                    if (self.pos >= s.len) return self.fail("unterminated string");
                    const e = s[self.pos];
                    if (e == '\n') {
                        self.pos += 1;
                        continue;
                    }
                    if (numericEscape(s, self.pos)) |ne| {
                        out.push(ne.byte);
                        self.pos += ne.len;
                        continue;
                    }
                    self.pos += 1;
                    if (simpleEscape(e)) |b| out.push(b) else if (e == '\\') out.push('\\') else if (std.ascii.isAlphanumeric(e) or e == '.' or e == '[' or e == ']' or e == '(' or e == ')' or e == '*' or e == '+' or e == '?' or e == '{' or e == '}' or e == '|' or e == '^' or e == '$') {
                        // gawk: unknown escapes drop the backslash (warning), except regex
                        // metacharacters which are kept so "\." works as a dynamic regexp.
                        if (std.ascii.isAlphanumeric(e)) out.push(e) else {
                            out.push(e);
                        }
                    } else out.push(e);
                }
                return .{ .t = .string, .s = out.items, .start = start };
            },
            else => {},
        }
        if (std.ascii.isDigit(ch) or (ch == '.' and std.ascii.isDigit(nx))) {
            self.pos = start;
            if (ch == '0' and (nx == 'x' or nx == 'X') and self.pos + 2 < s.len and std.ascii.isHex(s[self.pos + 2])) {
                var j = self.pos + 2;
                var v: f64 = 0;
                while (j < s.len and std.ascii.isHex(s[j])) : (j += 1) v = v * 16 + @as(f64, @floatFromInt(std.fmt.charToDigit(s[j], 16) catch 0));
                self.pos = j;
                return .{ .t = .number, .n = v, .start = start };
            }
            const p = numPrefix(s[start..]);
            self.pos = start + p.len;
            const text = s[start..self.pos];
            if (text.len > 1 and text[0] == '0' and std.mem.indexOfAny(u8, text, ".eE89") == null) {
                return .{ .t = .number, .n = @floatFromInt(std.fmt.parseInt(u64, text, 8) catch 0), .start = start };
            }
            return .{ .t = .number, .n = p.n, .start = start };
        }
        if (std.ascii.isAlphabetic(ch) or ch == '_') {
            var j = self.pos;
            while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '_')) j += 1;
            const word = s[start..j];
            self.pos = j;
            for (keywords) |kw| if (std.mem.eql(u8, kw[0], word)) return .{ .t = kw[1], .s = word, .start = start };
            if (std.meta.stringToEnum(B, word)) |b| return .{ .t = .builtin, .s = word, .b = b, .start = start };
            if (self.pos < s.len and s[self.pos] == '(') return .{ .t = .funcname, .s = word, .start = start };
            return .{ .t = .name, .s = word, .start = start };
        }
        return self.fail("unexpected character");
    }

    /// Re-scan from a '/' or '/=' token as a regular expression literal.
    fn scanRegex(self: *Parser, tok: Tok) ![]const u8 {
        self.pos = tok.start + 1;
        self.peeked = null;
        const s = self.src;
        var out = u.Vec(u8).init(A);
        var in_br = false;
        while (true) {
            if (self.pos >= s.len or s[self.pos] == '\n') return self.fail("unterminated regexp");
            const ch = s[self.pos];
            self.pos += 1;
            if (ch == '\\' and self.pos < s.len) {
                const e = s[self.pos];
                self.pos += 1;
                if (e == '/') out.push('/') else {
                    out.push('\\');
                    out.push(e);
                }
                continue;
            }
            if (in_br) {
                if (ch == ']') in_br = false;
                out.push(ch);
                continue;
            }
            if (ch == '[') {
                in_br = true;
                out.push(ch);
                // a leading ']' or '^]' is literal
                if (self.pos < s.len and s[self.pos] == '^') {
                    out.push('^');
                    self.pos += 1;
                }
                if (self.pos < s.len and s[self.pos] == ']') {
                    out.push(']');
                    self.pos += 1;
                }
                continue;
            }
            if (ch == '/') break;
            out.push(ch);
        }
        return out.items;
    }

    // ---- program
    fn parseProgram(self: *Parser) !void {
        const it = self.it;
        while (true) {
            try self.skipTerms();
            const t = try self.peek();
            if (t.t == .eof) break;
            if (t.t == .kw_function) {
                try self.parseFunction();
                continue;
            }
            var rule = Rule{ .kind = .main, .p1 = null, .p2 = null, .action = null };
            switch (t.t) {
                .kw_begin, .kw_end, .kw_beginfile, .kw_endfile => {
                    _ = try self.next();
                    rule.kind = switch (t.t) {
                        .kw_begin => .begin,
                        .kw_end => .end,
                        .kw_beginfile => .beginfile,
                        else => .endfile,
                    };
                    if ((try self.peek()).t != .lbrace) return self.fail("BEGIN/END require an action");
                },
                .lbrace => {},
                else => {
                    rule.p1 = try self.parseExpr();
                    if (try self.accept(.comma)) {
                        try self.skipNl();
                        rule.p2 = try self.parseExpr();
                    }
                },
            }
            if ((try self.peek()).t == .lbrace) rule.action = try self.parseBlock();
            it.rules.push(rule);
            const e = (try self.peek()).t;
            if (e != .eof and e != .nl and e != .semi and e != .rbrace and rule.action == null) return self.fail("unexpected token after pattern");
        }
    }
    fn parseFunction(self: *Parser) !void {
        _ = try self.next();
        const name_tok = try self.next();
        if (name_tok.t != .name and name_tok.t != .funcname) return self.fail("function name expected");
        try self.expect(.lparen, "'(' expected");
        var params = u.Vec([]const u8).init(A);
        try self.skipNl();
        while ((try self.peek()).t != .rparen) {
            const p = try self.next();
            if (p.t != .name) return self.fail("parameter name expected");
            params.push(p.s);
            try self.skipNl();
            if (!try self.accept(.comma)) break;
            try self.skipNl();
        }
        try self.expect(.rparen, "')' expected");
        try self.skipNl();
        const idx = self.it.funcIndex(name_tok.s);
        const f = &self.it.funcs.items[idx];
        if (f.defined) return self.fail("function redefined");
        f.defined = true;
        f.nparams = params.items.len;
        self.params = params.items;
        const body = try self.parseBlock();
        self.params = &.{};
        self.it.funcs.items[idx].body = body;
    }
    fn parseBlock(self: *Parser) !*Node {
        try self.expect(.lbrace, "'{' expected");
        var list = u.Vec(*Node).init(A);
        while (true) {
            try self.skipTerms();
            if ((try self.peek()).t == .rbrace) {
                self.peeked = null;
                break;
            }
            if ((try self.peek()).t == .eof) return self.fail("missing '}'");
            list.push(try self.parseStmt());
        }
        return self.mk(.{ .tag = .s_block, .list = list.items });
    }
    fn mk(self: *Parser, n: Node) !*Node {
        _ = self;
        const p = try A.create(Node);
        p.* = n;
        return p;
    }
    fn endSimple(self: *Parser) !void {
        const t = (try self.peek()).t;
        switch (t) {
            .semi, .nl => {
                self.peeked = null;
            },
            .rbrace, .eof => {},
            else => return self.fail("unexpected token"),
        }
    }
    fn parseSimpleOrBlockBody(self: *Parser) !*Node {
        try self.skipNl();
        if ((try self.peek()).t == .semi) {
            self.peeked = null;
            return self.mk(.{ .tag = .s_block });
        }
        return self.parseStmt();
    }
    fn parseStmt(self: *Parser) error{ Syntax, OutOfMemory }!*Node {
        const t = try self.peek();
        switch (t.t) {
            .lbrace => return self.parseBlock(),
            .semi => {
                self.peeked = null;
                return self.mk(.{ .tag = .s_block });
            },
            .kw_if => {
                _ = try self.next();
                try self.expect(.lparen, "'(' expected after if");
                const cond = try self.parseExpr();
                try self.expect(.rparen, "')' expected");
                const then = try self.parseSimpleOrBlockBody();
                const sv = self.save();
                try self.skipTerms();
                var els: ?*Node = null;
                if ((try self.peek()).t == .kw_else) {
                    _ = try self.next();
                    els = try self.parseSimpleOrBlockBody();
                } else self.restore(sv);
                return self.mk(.{ .tag = .s_if, .a = cond, .b = then, .c = els });
            },
            .kw_while => {
                _ = try self.next();
                try self.expect(.lparen, "'(' expected after while");
                const cond = try self.parseExpr();
                try self.expect(.rparen, "')' expected");
                if ((try self.peek()).t == .semi) {
                    self.peeked = null;
                    return self.mk(.{ .tag = .s_while, .a = cond, .b = try self.mk(.{ .tag = .s_block }) });
                }
                const body = try self.parseSimpleOrBlockBody();
                return self.mk(.{ .tag = .s_while, .a = cond, .b = body });
            },
            .kw_do => {
                _ = try self.next();
                const body = try self.parseSimpleOrBlockBody();
                try self.skipTerms();
                if (!try self.accept(.kw_while)) return self.fail("'while' expected after do body");
                try self.expect(.lparen, "'(' expected");
                const cond = try self.parseExpr();
                try self.expect(.rparen, "')' expected");
                try self.endSimple();
                return self.mk(.{ .tag = .s_do, .a = body, .b = cond });
            },
            .kw_for => {
                _ = try self.next();
                try self.expect(.lparen, "'(' expected after for");
                const sv = self.save();
                if ((try self.peek()).t == .name) {
                    const var_tok = try self.next();
                    if (try self.accept(.kw_in)) {
                        const arr_tok = try self.peek();
                        if (arr_tok.t == .name) {
                            _ = try self.next();
                            if (try self.accept(.rparen)) {
                                const v = try self.varNode(var_tok.s);
                                const arr = try self.varNode(arr_tok.s);
                                const body = try self.parseSimpleOrBlockBody();
                                return self.mk(.{ .tag = .s_forin, .a = v, .b = arr, .c = body });
                            }
                        }
                    }
                }
                self.restore(sv);
                var init_n: ?*Node = null;
                var cond_n: ?*Node = null;
                var incr_n: ?*Node = null;
                if ((try self.peek()).t != .semi) init_n = try self.parseSimpleStmtExpr();
                try self.expect(.semi, "';' expected in for");
                try self.skipNl();
                if ((try self.peek()).t != .semi) cond_n = try self.parseExpr();
                try self.expect(.semi, "';' expected in for");
                try self.skipNl();
                if ((try self.peek()).t != .rparen) incr_n = try self.parseSimpleStmtExpr();
                try self.expect(.rparen, "')' expected");
                if ((try self.peek()).t == .semi) {
                    self.peeked = null;
                    return self.mk(.{ .tag = .s_for, .a = init_n, .b = cond_n, .c = incr_n, .d = try self.mk(.{ .tag = .s_block }) });
                }
                const body = try self.parseSimpleOrBlockBody();
                return self.mk(.{ .tag = .s_for, .a = init_n, .b = cond_n, .c = incr_n, .d = body });
            },
            else => {},
        }
        const n = try self.parseSimpleStmt();
        try self.endSimple();
        return n;
    }
    fn parseSimpleStmtExpr(self: *Parser) !*Node {
        const e = try self.parseExpr();
        return self.mk(.{ .tag = .s_expr, .a = e });
    }
    fn parseSimpleStmt(self: *Parser) !*Node {
        const t = try self.peek();
        switch (t.t) {
            .kw_next => {
                _ = try self.next();
                return self.mk(.{ .tag = .s_next });
            },
            .kw_nextfile => {
                _ = try self.next();
                return self.mk(.{ .tag = .s_nextfile });
            },
            .kw_break => {
                _ = try self.next();
                return self.mk(.{ .tag = .s_break });
            },
            .kw_continue => {
                _ = try self.next();
                return self.mk(.{ .tag = .s_continue });
            },
            .kw_exit, .kw_return => {
                _ = try self.next();
                var e: ?*Node = null;
                const p = (try self.peek()).t;
                if (p != .semi and p != .nl and p != .rbrace and p != .eof) e = try self.parseExpr();
                return self.mk(.{ .tag = if (t.t == .kw_exit) .s_exit else .s_return, .a = e });
            },
            .kw_delete => {
                _ = try self.next();
                const nt = try self.next();
                if (nt.t != .name) return self.fail("array name expected after delete");
                const arr = try self.varNode(nt.s);
                var subs = u.Vec(*Node).init(A);
                if (try self.accept(.lbracket)) {
                    while (true) {
                        try self.skipNl();
                        subs.push(try self.parseExpr());
                        if (!try self.accept(.comma)) break;
                    }
                    try self.expect(.rbracket, "']' expected");
                }
                return self.mk(.{ .tag = .s_delete, .a = arr, .list = subs.items, .op = if (subs.items.len == 0) 1 else 0 });
            },
            .kw_print, .kw_printf => return self.parsePrint(),
            else => return self.parseSimpleStmtExpr(),
        }
    }
    fn parsePrint(self: *Parser) !*Node {
        const kw = try self.next();
        var args = u.Vec(*Node).init(A);
        const old_gt = self.no_gt;
        defer self.no_gt = old_gt;
        const p = (try self.peek()).t;
        var done = false;
        if (p == .lparen) {
            // try "(list)" followed by end of statement or a redirection
            const sv = self.save();
            _ = try self.next();
            self.no_gt = false;
            var tmp = u.Vec(*Node).init(A);
            var ok = true;
            while (true) {
                try self.skipNl();
                const e = self.parseExpr() catch {
                    ok = false;
                    break;
                };
                tmp.push(e);
                try self.skipNl();
                if (!try self.accept(.comma)) break;
            }
            if (ok and try self.accept(.rparen)) {
                const after = (try self.peek()).t;
                if (after == .semi or after == .nl or after == .rbrace or after == .eof or after == .gt or after == .append or after == .pipe) {
                    args = tmp;
                    done = true;
                }
            }
            if (!done) self.restore(sv);
        }
        if (!done and p != .semi and p != .nl and p != .rbrace and p != .eof and p != .gt and p != .append and p != .pipe) {
            self.no_gt = true;
            while (true) {
                args.push(try self.parseExpr());
                if (!try self.accept(.comma)) break;
                try self.skipNl();
            }
        }
        self.no_gt = old_gt;
        var redirect: u8 = 0;
        var target: ?*Node = null;
        const r = (try self.peek()).t;
        if (r == .gt or r == .append or r == .pipe) {
            _ = try self.next();
            redirect = switch (r) {
                .gt => '>',
                .append => 'a',
                else => '|',
            };
            self.no_gt = true;
            target = try self.parseConcat();
            self.no_gt = old_gt;
        }
        if (kw.t == .kw_printf and args.items.len == 0) return self.fail("printf: no format");
        return self.mk(.{ .tag = if (kw.t == .kw_print) .s_print else .s_printf, .list = args.items, .op = redirect, .a = target });
    }

    // ---- variables
    fn varNode(self: *Parser, name: []const u8) !*Node {
        for (self.params, 0..) |p, i| if (std.mem.eql(u8, p, name)) return self.mk(.{ .tag = .lvar, .i = i, .s = name });
        return self.mk(.{ .tag = .gvar, .i = self.it.globalSlot(name), .s = name });
    }
    fn isLvalue(n: *Node) bool {
        return switch (n.tag) {
            .gvar, .lvar, .field, .index => true,
            else => false,
        };
    }

    // ---- expressions
    fn parseExpr(self: *Parser) error{ Syntax, OutOfMemory }!*Node {
        const lhs = try self.parseTernary();
        const t = try self.peek();
        const op: ?u8 = switch (t.t) {
            .assign => 0,
            .add_assign => '+',
            .sub_assign => '-',
            .mul_assign => '*',
            .div_assign => '/',
            .mod_assign => '%',
            .pow_assign => '^',
            else => null,
        };
        if (op) |o| {
            if (!isLvalue(lhs)) return self.fail("assignment to non-lvalue");
            _ = try self.next();
            try self.skipNl();
            const rhs = try self.parseExpr();
            return self.mk(.{ .tag = .assign, .op = o, .a = lhs, .b = rhs });
        }
        return lhs;
    }
    fn parseTernary(self: *Parser) !*Node {
        const cond = try self.parseOr();
        if (try self.accept(.question)) {
            try self.skipNl();
            const a = try self.parseExpr();
            try self.skipNl();
            try self.expect(.colon, "':' expected");
            try self.skipNl();
            const b = try self.parseExpr();
            return self.mk(.{ .tag = .cond, .a = cond, .b = a, .c = b });
        }
        return cond;
    }
    fn parseOr(self: *Parser) !*Node {
        var lhs = try self.parseAnd();
        while (try self.accept(.or_)) {
            try self.skipNl();
            const rhs = try self.parseAnd();
            lhs = try self.mk(.{ .tag = .lor, .a = lhs, .b = rhs });
        }
        return lhs;
    }
    fn parseAnd(self: *Parser) !*Node {
        var lhs = try self.parseIn();
        while (try self.accept(.and_)) {
            try self.skipNl();
            const rhs = try self.parseIn();
            lhs = try self.mk(.{ .tag = .land, .a = lhs, .b = rhs });
        }
        return lhs;
    }
    fn parseIn(self: *Parser) !*Node {
        var lhs = try self.parseMatch();
        while (!self.no_in and (try self.peek()).t == .kw_in) {
            _ = try self.next();
            const nt = try self.next();
            if (nt.t != .name) return self.fail("array name expected after 'in'");
            const arr = try self.varNode(nt.s);
            var subs = u.Vec(*Node).init(A);
            subs.push(lhs);
            lhs = try self.mk(.{ .tag = .in_, .a = arr, .list = subs.items });
        }
        return lhs;
    }
    fn parseMatch(self: *Parser) !*Node {
        var lhs = try self.parseCmp();
        while (true) {
            const t = (try self.peek()).t;
            if (t != .tilde and t != .nomatch) break;
            _ = try self.next();
            const rhs = try self.parseCmp();
            lhs = try self.mk(.{ .tag = if (t == .tilde) .match else .nmatch, .a = lhs, .b = rhs });
        }
        return lhs;
    }
    fn pipeGetlineAhead(self: *Parser) !bool {
        if ((try self.peek()).t != .pipe) return false;
        const sv = self.save();
        _ = try self.next();
        const t = (try self.peek()).t;
        self.restore(sv);
        return t == .kw_getline;
    }
    fn parseCmp(self: *Parser) !*Node {
        var lhs = try self.parseConcat();
        while (try self.pipeGetlineAhead()) {
            _ = try self.next();
            _ = try self.next();
            const lv = try self.parseOptLvalue();
            lhs = try self.mk(.{ .tag = .getline, .op = '|', .a = lv, .b = lhs });
        }
        while (true) {
            const t = (try self.peek()).t;
            const op: u8 = switch (t) {
                .lt => '<',
                .le => 'l',
                .gt => if (self.no_gt) return lhs else '>',
                .ge => 'g',
                .eq => '=',
                .ne => '!',
                else => return lhs,
            };
            _ = try self.next();
            const rhs = try self.parseConcat();
            lhs = try self.mk(.{ .tag = .cmp, .op = op, .a = lhs, .b = rhs });
            while (try self.pipeGetlineAhead()) {
                _ = try self.next();
                _ = try self.next();
                const lv = try self.parseOptLvalue();
                lhs = try self.mk(.{ .tag = .getline, .op = '|', .a = lv, .b = lhs });
            }
        }
    }
    fn parseConcat(self: *Parser) !*Node {
        var lhs = try self.parseAdd();
        while (true) {
            const t = (try self.peek()).t;
            const ok = switch (t) {
                .number, .string, .name, .funcname, .builtin, .dollar, .lparen, .incr, .decr => true,
                else => false,
            };
            if (!ok) return lhs;
            const rhs = try self.parseAdd();
            lhs = try self.mk(.{ .tag = .concat, .a = lhs, .b = rhs });
        }
    }
    fn parseAdd(self: *Parser) !*Node {
        var lhs = try self.parseMul();
        while (true) {
            const t = (try self.peek()).t;
            if (t != .plus and t != .minus) return lhs;
            _ = try self.next();
            const rhs = try self.parseMul();
            lhs = try self.mk(.{ .tag = .arith, .op = if (t == .plus) '+' else '-', .a = lhs, .b = rhs });
        }
    }
    fn parseMul(self: *Parser) !*Node {
        var lhs = try self.parseUnary();
        while (true) {
            const t = (try self.peek()).t;
            const op: u8 = switch (t) {
                .star => '*',
                .slash => '/',
                .percent => '%',
                else => return lhs,
            };
            _ = try self.next();
            const rhs = try self.parseUnary();
            lhs = try self.mk(.{ .tag = .arith, .op = op, .a = lhs, .b = rhs });
        }
    }
    fn parseUnary(self: *Parser) !*Node {
        const t = (try self.peek()).t;
        switch (t) {
            .not => {
                _ = try self.next();
                return self.mk(.{ .tag = .not, .a = try self.parseUnary() });
            },
            .minus => {
                _ = try self.next();
                return self.mk(.{ .tag = .neg, .a = try self.parseUnary() });
            },
            .plus => {
                _ = try self.next();
                return self.mk(.{ .tag = .pos, .a = try self.parseUnary() });
            },
            else => return self.parsePow(),
        }
    }
    fn parsePow(self: *Parser) error{ Syntax, OutOfMemory }!*Node {
        const base = try self.parsePostfix();
        if (try self.accept(.caret)) {
            const rhs = try self.parsePowOperand();
            return self.mk(.{ .tag = .arith, .op = '^', .a = base, .b = rhs });
        }
        return base;
    }
    fn parsePowOperand(self: *Parser) error{ Syntax, OutOfMemory }!*Node {
        const t = (try self.peek()).t;
        switch (t) {
            .minus => {
                _ = try self.next();
                return self.mk(.{ .tag = .neg, .a = try self.parsePowOperand() });
            },
            .plus => {
                _ = try self.next();
                return self.mk(.{ .tag = .pos, .a = try self.parsePowOperand() });
            },
            .not => {
                _ = try self.next();
                return self.mk(.{ .tag = .not, .a = try self.parsePowOperand() });
            },
            else => return self.parsePow(),
        }
    }
    fn parsePostfix(self: *Parser) !*Node {
        const p = try self.parsePrimary();
        if (isLvalue(p)) {
            const t = (try self.peek()).t;
            if (t == .incr) {
                _ = try self.next();
                return self.mk(.{ .tag = .postinc, .a = p });
            }
            if (t == .decr) {
                _ = try self.next();
                return self.mk(.{ .tag = .postdec, .a = p });
            }
        }
        return p;
    }
    fn parseOptLvalue(self: *Parser) !?*Node {
        const t = (try self.peek()).t;
        if (t == .name or t == .dollar) return try self.parsePrimary();
        return null;
    }
    fn parseArgs(self: *Parser) ![]*Node {
        var args = u.Vec(*Node).init(A);
        try self.expect(.lparen, "'(' expected");
        const old_gt = self.no_gt;
        const old_in = self.no_in;
        self.no_gt = false;
        self.no_in = false;
        defer {
            self.no_gt = old_gt;
            self.no_in = old_in;
        }
        try self.skipNl();
        if (!try self.accept(.rparen)) {
            while (true) {
                try self.skipNl();
                args.push(try self.parseExpr());
                try self.skipNl();
                if (!try self.accept(.comma)) break;
            }
            try self.expect(.rparen, "')' expected");
        }
        return args.items;
    }
    fn parsePrimary(self: *Parser) error{ Syntax, OutOfMemory }!*Node {
        const t = try self.next();
        switch (t.t) {
            .number => return self.mk(.{ .tag = .num, .n = t.n }),
            .string => return self.mk(.{ .tag = .str, .s = t.s }),
            .slash, .div_assign => {
                const src = try self.scanRegex(t);
                const rx = self.it.compileRx(src, false) catch return self.fail("bad regular expression");
                return self.mk(.{ .tag = .regex, .rx = rx, .s = src });
            },
            .lparen => {
                const old_gt = self.no_gt;
                const old_in = self.no_in;
                self.no_gt = false;
                self.no_in = false;
                defer {
                    self.no_gt = old_gt;
                    self.no_in = old_in;
                }
                try self.skipNl();
                const first = try self.parseExpr();
                try self.skipNl();
                if ((try self.peek()).t == .comma) {
                    var subs = u.Vec(*Node).init(A);
                    subs.push(first);
                    while (try self.accept(.comma)) {
                        try self.skipNl();
                        subs.push(try self.parseExpr());
                        try self.skipNl();
                    }
                    try self.expect(.rparen, "')' expected");
                    if (!try self.accept(.kw_in)) return self.fail("'in' expected after (list)");
                    const nt = try self.next();
                    if (nt.t != .name) return self.fail("array name expected");
                    return self.mk(.{ .tag = .in_, .a = try self.varNode(nt.s), .list = subs.items });
                }
                try self.expect(.rparen, "')' expected");
                return self.mk(.{ .tag = .group, .a = first });
            },
            .dollar => {
                const nt = try self.peek();
                var operand: *Node = undefined;
                if (nt.t == .incr or nt.t == .decr) {
                    _ = try self.next();
                    const lv = try self.parsePrimary();
                    if (!isLvalue(lv)) return self.fail("++/-- needs an lvalue");
                    operand = try self.mk(.{ .tag = if (nt.t == .incr) .preinc else .predec, .a = lv });
                } else if (nt.t == .minus) {
                    _ = try self.next();
                    operand = try self.mk(.{ .tag = .neg, .a = try self.parsePrimary() });
                } else operand = try self.parsePrimary();
                return self.mk(.{ .tag = .field, .a = operand });
            },
            .incr, .decr => {
                const lv = try self.parsePrimary();
                if (!isLvalue(lv)) return self.fail("++/-- needs an lvalue");
                return self.mk(.{ .tag = if (t.t == .incr) .preinc else .predec, .a = lv });
            },
            .name => {
                if ((try self.peek()).t == .lbracket) {
                    _ = try self.next();
                    var subs = u.Vec(*Node).init(A);
                    const old_gt = self.no_gt;
                    const old_in = self.no_in;
                    self.no_gt = false;
                    self.no_in = false;
                    defer {
                        self.no_gt = old_gt;
                        self.no_in = old_in;
                    }
                    while (true) {
                        try self.skipNl();
                        subs.push(try self.parseExpr());
                        try self.skipNl();
                        if (!try self.accept(.comma)) break;
                    }
                    try self.expect(.rbracket, "']' expected");
                    return self.mk(.{ .tag = .index, .a = try self.varNode(t.s), .list = subs.items, .s = t.s });
                }
                return self.varNode(t.s);
            },
            .funcname => {
                const args = try self.parseArgs();
                return self.mk(.{ .tag = .call, .i = self.it.funcIndex(t.s), .list = args, .s = t.s });
            },
            .builtin => {
                var args: []*Node = &.{};
                if ((try self.peek()).t == .lparen) args = try self.parseArgs() else if (t.b != .length) return self.fail("'(' expected after function name");
                return self.mk(.{ .tag = .builtin, .i = @intFromEnum(t.b), .list = args });
            },
            .kw_getline => {
                const lv = try self.parseOptLvalue();
                if ((try self.peek()).t == .lt) {
                    _ = try self.next();
                    const file = try self.parseGetlineFile();
                    return self.mk(.{ .tag = .getline, .op = '<', .a = lv, .b = file });
                }
                return self.mk(.{ .tag = .getline, .op = 0, .a = lv });
            },
            else => return self.fail("unexpected token in expression"),
        }
    }
    fn parseGetlineFile(self: *Parser) !*Node {
        // a primary expression without concatenation
        return self.parsePostfix();
    }
};

// ---------------------------------------------------------------- I/O
const Reader = struct {
    fd: i32,
    buf: []u8 = &.{},
    start: usize = 0,
    end: usize = 0,
    eof: bool = false,
    fp: ?*c.FILE = null,
    fn fill(self: *Reader) bool {
        if (self.eof) return false;
        if (self.start > 0 and self.start == self.end) {
            self.start = 0;
            self.end = 0;
        }
        if (self.end == self.buf.len) {
            if (self.start > 0 and self.start >= self.buf.len / 2) {
                std.mem.copyForwards(u8, self.buf[0 .. self.end - self.start], self.buf[self.start..self.end]);
                self.end -= self.start;
                self.start = 0;
            } else {
                const ncap = if (self.buf.len == 0) 65536 else self.buf.len * 2;
                const nb = A.alloc(u8, ncap) catch return false;
                @memcpy(nb[0 .. self.end - self.start], self.buf[self.start..self.end]);
                if (self.buf.len > 0) A.free(self.buf);
                self.end -= self.start;
                self.start = 0;
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
                    self.eof = true;
                    return false;
                },
            }
        }
    }
};
const Out = struct { name: []const u8, fp: *c.FILE, pipe: bool };
const In = struct { name: []const u8, reader: *Reader, pipe: bool };

// ---------------------------------------------------------------- interpreter
const Interp = struct {
    globals: []Cell = &.{},
    gnames: std.StringHashMapUnmanaged(usize) = .empty,
    nglobals: usize = 0,
    funcs: u.Vec(Func) = u.Vec(Func).init(A),
    fnames: std.StringHashMapUnmanaged(usize) = .empty,
    rules: u.Vec(Rule) = u.Vec(Rule).init(A),
    frame: []Cell = &.{},
    rxcache: std.StringHashMapUnmanaged(*Rx) = .empty,
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(A),
    retired: u.Vec([]const u8) = u.Vec([]const u8).init(A),
    zscratch: []u8 = &.{},
    utf8: bool = false,

    // special variables (native copies)
    nf: usize = 0,
    nr: f64 = 0,
    fnr: f64 = 0,
    fs: []const u8 = " ",
    ofs: []const u8 = " ",
    ors: []const u8 = "\n",
    rs: []const u8 = "\n",
    subsep: []const u8 = "\x1c",
    convfmt: []const u8 = "%.6g",
    ofmt: []const u8 = "%.6g",
    ignorecase: bool = false,
    // record state
    rec: []const u8 = "",
    rec_valid: bool = true,
    rec_fs: []const u8 = " ",
    fpat: []const u8 = "",
    use_fpat: bool = false,
    rec_fpat: ?[]const u8 = null,
    fields_owned: bool = false,
    depth: usize = 0,
    fields: u.Vec([]const u8) = u.Vec([]const u8).init(A),
    fields_valid: bool = true,
    retval: Val = .{},
    exit_code: u8 = 0,
    in_end: bool = false,
    // io
    stdout_fp: *c.FILE = undefined,
    stderr_fp: *c.FILE = undefined,
    outs: u.Vec(Out) = u.Vec(Out).init(A),
    ins: u.Vec(In) = u.Vec(In).init(A),
    main_reader: ?*Reader = null,
    argi: usize = 1,
    used_file: bool = false,
    interactive: bool = false,
    rng_state: [64]u32 = undefined,
    rng_f: usize = 1,
    rng_r: usize = 0,
    seed: f64 = 1,
    prev_seed: f64 = 0,
    rng_init: bool = false,

    fn tmp(self: *Interp) std.mem.Allocator {
        return self.arena.allocator();
    }
    fn fatal(self: *Interp, comptime fmt: []const u8, args: anytype) Err {
        _ = self;
        _ = c.fflush(null);
        u.errf("awk: fatal: " ++ fmt ++ "\n", args);
        return error.Fatal;
    }
    fn globalSlot(self: *Interp, name: []const u8) usize {
        if (self.gnames.get(name)) |i| return i;
        const i = self.nglobals;
        self.nglobals += 1;
        self.gnames.put(A, A.dupe(u8, name) catch @panic("oom"), i) catch @panic("oom");
        return i;
    }
    fn funcIndex(self: *Interp, name: []const u8) usize {
        if (self.fnames.get(name)) |i| return i;
        const i = self.funcs.items.len;
        self.funcs.push(.{ .name = A.dupe(u8, name) catch @panic("oom") });
        self.fnames.put(A, self.funcs.items[i].name, i) catch @panic("oom");
        return i;
    }
    fn retire(self: *Interp, s: []const u8) void {
        if (s.len > 0) self.retired.push(s);
    }
    fn endCycle(self: *Interp) void {
        for (self.retired.items) |s| A.free(s);
        self.retired.items.len = 0;
        _ = self.arena.reset(.retain_capacity);
    }
    fn persist(self: *Interp, v: Val) Val {
        _ = self;
        if (v.kind == .num or v.kind == .uninit or v.s.len == 0) return v;
        var r = v;
        r.s = A.dupe(u8, v.s) catch @panic("oom");
        r.cap = 0;
        return r;
    }
    fn dupeP(self: *Interp, s: []const u8) []const u8 {
        _ = self;
        if (s.len == 0) return "";
        return A.dupe(u8, s) catch @panic("oom");
    }

    // ---- conversions
    fn numStr(self: *Interp, n: f64, fmt: []const u8) []const u8 {
        if (std.math.isNan(n)) return if (std.math.signbit(n)) "-nan" else "+nan";
        if (std.math.isInf(n)) return if (n < 0) "-inf" else "+inf";
        if (n == @trunc(n)) {
            if (@abs(n) < 1e18) {
                const i: i64 = @intFromFloat(n);
                return std.fmt.allocPrint(self.tmp(), "{d}", .{i}) catch @panic("oom");
            }
            return self.cformat("%.0f", n);
        }
        if (!std.mem.eql(u8, fmt, "%.6g")) {
            const args = [_]Val{ Val.str(fmt), Val.num(n) };
            if (self.sprintf(&args)) |r| return r else |_| {}
        }
        return self.cformat(fmt, n);
    }
    fn cformat(self: *Interp, fmt: []const u8, n: f64) []const u8 {
        const z = u.zstr(fmt);
        defer A.free(z);
        var buf: [512]u8 = undefined;
        const len = c.snprintf(&buf, buf.len, z.ptr, n);
        if (len < 0) return "";
        const l: usize = @intCast(len);
        if (l < buf.len) return self.tmp().dupe(u8, buf[0..l]) catch @panic("oom");
        const big = self.tmp().alloc(u8, l + 1) catch @panic("oom");
        _ = c.snprintf(big.ptr, big.len, z.ptr, n);
        return big[0..l];
    }
    fn toStr(self: *Interp, v: Val) []const u8 {
        return switch (v.kind) {
            .uninit => "",
            .str, .strnum => v.s,
            .num => self.numStr(v.n, self.convfmt),
        };
    }
    fn toOut(self: *Interp, v: Val) []const u8 {
        return switch (v.kind) {
            .uninit => "",
            .str, .strnum => v.s,
            .num => self.numStr(v.n, self.ofmt),
        };
    }
    fn toNum(self: *Interp, v: Val) f64 {
        _ = self;
        return switch (v.kind) {
            .uninit => 0,
            .num, .strnum => v.n,
            .str => strToNum(v.s),
        };
    }
    fn toBool(self: *Interp, v: Val) bool {
        _ = self;
        return switch (v.kind) {
            .uninit => false,
            .num, .strnum => v.n != 0,
            .str => v.s.len > 0,
        };
    }
    fn compare(self: *Interp, a: Val, b: Val) i32 {
        const an = a.kind != .str;
        const bn = b.kind != .str;
        if (an and bn) {
            const x = a.n;
            const y = b.n;
            if (std.math.isNan(x) or std.math.isNan(y)) {
                if (std.math.isNan(x) and std.math.isNan(y)) return 0;
                return if (std.math.isNan(x)) 1 else -1;
            }
            return if (x < y) -1 else if (x > y) 1 else 0;
        }
        const x = self.toStr(a);
        const y = self.toStr(b);
        if (self.ignorecase) {
            const n = @min(x.len, y.len);
            for (0..n) |i| {
                const p = std.ascii.toLower(x[i]);
                const q = std.ascii.toLower(y[i]);
                if (p != q) return if (p < q) -1 else 1;
            }
            return if (x.len < y.len) -1 else if (x.len > y.len) 1 else 0;
        }
        return switch (std.mem.order(u8, x, y)) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        };
    }

    // ---- utf-8 helpers
    fn charCount(self: *Interp, s: []const u8) usize {
        if (!self.utf8) return s.len;
        var n: usize = 0;
        for (s) |b| {
            if (b & 0xc0 != 0x80) n += 1;
        }
        return n;
    }
    /// byte offset of character index `ci` (0-based); clamps to len.
    fn byteOff(self: *Interp, s: []const u8, ci: usize) usize {
        if (!self.utf8) return @min(ci, s.len);
        var n: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] & 0xc0 != 0x80) {
                if (n == ci) return i;
                n += 1;
            }
            i += 1;
        }
        return s.len;
    }

    // ---- regex
    fn compileRx(self: *Interp, src: []const u8, icase: bool) !*Rx {
        var key = u.Vec(u8).init(self.tmp());
        key.push(if (icase) 'i' else 'c');
        for (src) |b| key.push(b);
        if (self.rxcache.get(key.items)) |rx| return rx;
        const rx = try A.create(Rx);
        const text = try translateRegex(src);
        rx.empty = text.len == 0;
        rx.nsub = 0;
        if (!rx.empty) {
            const z = u.zstr(text);
            defer A.free(z);
            const flags: c_int = @as(c_int, c.REG_EXTENDED) | (if (icase) @as(c_int, c.REG_ICASE) else 0);
            const rc = c.regcomp(&rx.re, z.ptr, flags);
            if (rc != 0) {
                var msg: [256]u8 = undefined;
                _ = c.regerror(rc, &rx.re, &msg, msg.len);
                u.errf("awk: regular expression /{s}/: {s}\n", .{ src, std.mem.sliceTo(&msg, 0) });
                return error.Syntax;
            }
            rx.nsub = rx.re.re_nsub;
        }
        try self.rxcache.put(A, try A.dupe(u8, key.items), rx);
        return rx;
    }
    fn zcopy(self: *Interp, s: []const u8) [*:0]const u8 {
        if (self.zscratch.len < s.len + 1) {
            if (self.zscratch.len > 0) A.free(self.zscratch);
            self.zscratch = A.alloc(u8, @max(s.len + 1, 4096) * 2) catch @panic("oom");
        }
        @memcpy(self.zscratch[0..s.len], s);
        self.zscratch[s.len] = 0;
        return @ptrCast(self.zscratch.ptr);
    }
    /// Search `z` (NUL terminated, total length `len`) from byte `from`. Offsets in `pm` are absolute.
    fn rxFindZ(self: *Interp, rx: *Rx, z: [*:0]const u8, len: usize, from: usize, pm: []c.regmatch_t) bool {
        _ = self;
        if (from > len) return false;
        if (rx.empty) {
            pm[0].rm_so = @intCast(from);
            pm[0].rm_eo = @intCast(from);
            for (pm[1..]) |*m| {
                m.rm_so = -1;
                m.rm_eo = -1;
            }
            return true;
        }
        const n = @min(pm.len, rx.nsub + 1);
        const flags: c_int = if (from > 0) c.REG_NOTBOL else 0;
        if (c.regexec(&rx.re, z + from, n, pm.ptr, flags) != 0) return false;
        for (pm[0..n]) |*m| {
            if (m.rm_so >= 0) {
                m.rm_so += @intCast(from);
                m.rm_eo += @intCast(from);
            }
        }
        for (pm[n..]) |*m| {
            m.rm_so = -1;
            m.rm_eo = -1;
        }
        return true;
    }
    fn rxMatches(self: *Interp, rx: *Rx, s: []const u8) bool {
        if (rx.empty) return true;
        const z = self.zcopy(s);
        var pm: [1]c.regmatch_t = undefined;
        return self.rxFindZ(rx, z, s.len, 0, &pm);
    }
    fn rxLit(self: *Interp, n: *Node) *Rx {
        if (self.ignorecase) return self.compileRx(n.s, true) catch return n.rx.?;
        return n.rx.?;
    }
    fn rxFromNode(self: *Interp, n: *Node) Err!*Rx {
        if (n.tag == .regex) return self.rxLit(n);
        const v = try self.eval(n);
        return self.compileRx(self.toStr(v), self.ignorecase) catch error.Fatal;
    }

    // ---- fields and records
    fn setRecord(self: *Interp, s: []const u8) void {
        self.retire(self.rec);
        self.rec = s;
        self.rec_valid = true;
        self.fields_valid = false;
        self.rec_fs = self.fs;
        self.rec_fpat = if (self.use_fpat) self.fpat else null;
    }
    fn getRecord(self: *Interp) []const u8 {
        if (!self.rec_valid) self.rebuildRecord();
        return self.rec;
    }
    fn rebuildRecord(self: *Interp) void {
        var out = u.Vec(u8).init(A);
        for (self.fields.items, 0..) |f, i| {
            if (i > 0) for (self.ofs) |b| out.push(b);
            for (f) |b| out.push(b);
        }
        self.retire(self.rec);
        self.rec = out.items;
        self.rec_valid = true;
    }
    fn dropFields(self: *Interp) void {
        if (self.fields_owned) for (self.fields.items) |f| self.retire(f);
        self.fields_owned = false;
        self.fields.items.len = 0;
    }
    fn ownFields(self: *Interp) void {
        if (self.fields_owned) return;
        for (self.fields.items) |*f| f.* = self.dupeP(f.*);
        self.fields_owned = true;
    }
    fn ensureSplit(self: *Interp) void {
        if (self.fields_valid) return;
        self.dropFields();
        const rec = self.rec;
        if (self.rec_fpat) |fp| self.splitFpat(rec, fp, &self.fields, null) else self.splitInto(rec, self.rec_fs, true, &self.fields, null);
        self.nf = self.fields.items.len;
        self.fields_valid = true;
    }
    /// Split `s` according to field separator `fs`. Pieces are slices of `s`.
    fn splitInto(self: *Interp, s: []const u8, fs: []const u8, is_record: bool, out: *u.Vec([]const u8), seps: ?*u.Vec([]const u8)) void {
        const para = is_record and std.mem.eql(u8, self.rs, "");
        if (s.len == 0) return;
        if (std.mem.eql(u8, fs, " ")) {
            var i: usize = 0;
            while (true) {
                while (i < s.len and isBlank(s[i])) i += 1;
                if (seps) |sp| if (out.items.len > 0 or i > 0) {
                    _ = sp;
                };
                if (i >= s.len) break;
                const st = i;
                while (i < s.len and !isBlank(s[i])) i += 1;
                out.push(s[st..i]);
            }
            return;
        }
        if (fs.len == 0) {
            var i: usize = 0;
            while (i < s.len) {
                var l: usize = 1;
                if (self.utf8) {
                    while (i + l < s.len and s[i + l] & 0xc0 == 0x80) l += 1;
                }
                out.push(s[i .. i + l]);
                i += l;
            }
            return;
        }
        if (fs.len == 1 and fs[0] != '\\' or std.mem.eql(u8, fs, "\\")) {
            const sep = fs[0];
            var st: usize = 0;
            var i: usize = 0;
            while (i < s.len) : (i += 1) {
                if (s[i] == sep or (para and s[i] == '\n')) {
                    out.push(s[st..i]);
                    if (seps) |sp| sp.push(s[i .. i + 1]);
                    st = i + 1;
                }
            }
            out.push(s[st..]);
            return;
        }
        // regular expression separator
        var pat: []const u8 = fs;
        if (para) pat = std.fmt.allocPrint(self.tmp(), "({s})|\n", .{fs}) catch @panic("oom");
        const rx = self.compileRx(pat, self.ignorecase) catch {
            out.push(s);
            return;
        };
        const z = self.zcopy(s);
        var pm: [1]c.regmatch_t = undefined;
        var st: usize = 0;
        var pos: usize = 0;
        while (pos <= s.len and self.rxFindZ(rx, z, s.len, pos, &pm)) {
            const ms: usize = @intCast(pm[0].rm_so);
            const me: usize = @intCast(pm[0].rm_eo);
            if (me == ms) {
                // empty match never separates
                pos = ms + 1;
                continue;
            }
            out.push(s[st..ms]);
            if (seps) |sp| sp.push(s[ms..me]);
            st = me;
            pos = me;
        }
        out.push(s[st..]);
    }
    /// gawk FPAT splitting: fields are the matches; the text between them is the separator.
    fn splitFpat(self: *Interp, s: []const u8, pat: []const u8, out: *u.Vec([]const u8), seps: ?*u.Vec([]const u8)) void {
        if (s.len == 0) return;
        const rx = self.compileRx(pat, self.ignorecase) catch return;
        const z = self.zcopy(s);
        var pm: [1]c.regmatch_t = undefined;
        var pos: usize = 0;
        var last_end: usize = 0;
        while (pos <= s.len and self.rxFindZ(rx, z, s.len, pos, &pm)) {
            const ms: usize = @intCast(pm[0].rm_so);
            const me: usize = @intCast(pm[0].rm_eo);
            if (seps) |sp| sp.push(s[last_end..ms]);
            out.push(s[ms..me]);
            last_end = me;
            pos = me + 1;
        }
        if (seps) |sp| sp.push(s[@min(last_end, s.len)..]);
    }
    fn getField(self: *Interp, i: i64) Err!Val {
        if (i < 0) return self.fatal("attempt to access field {d}", .{i});
        if (i == 0) return mkStrnum(self.getRecord());
        self.ensureSplit();
        const idx: usize = @intCast(i);
        if (idx > self.nf) return Val.str("");
        return mkStrnum(self.fields.items[idx - 1]);
    }
    fn setField(self: *Interp, i: i64, s: []const u8) Err!void {
        if (i < 0) return self.fatal("attempt to access field {d}", .{i});
        if (i == 0) {
            self.setRecord(self.dupeP(s));
            return;
        }
        self.ensureSplit();
        self.ownFields();
        const idx: usize = @intCast(i);
        while (self.fields.items.len < idx) self.fields.push("");
        self.nf = self.fields.items.len;
        self.retire(self.fields.items[idx - 1]);
        self.fields.items[idx - 1] = self.dupeP(s);
        self.rec_valid = false;
    }
    fn setNF(self: *Interp, n: i64) Err!void {
        if (n < 0) return self.fatal("NF set to negative value", .{});
        self.ensureSplit();
        self.ownFields();
        const want: usize = @intCast(n);
        while (self.fields.items.len < want) self.fields.push("");
        if (want < self.fields.items.len) {
            for (self.fields.items[want..]) |f| self.retire(f);
            self.fields.items.len = want;
        }
        self.nf = want;
        self.rec_valid = false;
    }

    // ---- variables
    fn syncSpecial(self: *Interp, slot: usize, v: Val) void {
        const s = self.dupeP(self.toStr(v));
        switch (slot) {
            SLOT_FS => {
                self.fs = s;
                self.use_fpat = false;
            },
            SLOT_FPAT => {
                self.fpat = s;
                self.use_fpat = true;
            },
            SLOT_OFS => self.ofs = s,
            SLOT_ORS => self.ors = s,
            SLOT_RS => self.rs = s,
            SLOT_SUBSEP => self.subsep = s,
            SLOT_CONVFMT => self.convfmt = s,
            SLOT_OFMT => self.ofmt = s,
            SLOT_IGNORECASE => self.ignorecase = self.toBool(v),
            else => {},
        }
    }
    fn loadG(self: *Interp, i: usize) Err!Val {
        switch (i) {
            SLOT_NF => {
                self.ensureSplit();
                return Val.num(@floatFromInt(self.nf));
            },
            SLOT_NR => return Val.num(self.nr),
            SLOT_FNR => return Val.num(self.fnr),
            else => {},
        }
        return switch (self.globals[i]) {
            .unset => .{},
            .val => |v| v,
            .arr => self.fatal("attempt to use array `{s}' in a scalar context", .{self.nameOf(i)}),
        };
    }
    fn nameOf(self: *Interp, slot: usize) []const u8 {
        var it = self.gnames.iterator();
        while (it.next()) |e| if (e.value_ptr.* == slot) return e.key_ptr.*;
        return "?";
    }
    fn storeG(self: *Interp, i: usize, v: Val) Err!void {
        switch (i) {
            SLOT_NF => return self.setNF(@intFromFloat(self.toNum(v))),
            SLOT_NR => {
                self.nr = self.toNum(v);
                return;
            },
            SLOT_FNR => {
                self.fnr = self.toNum(v);
                return;
            },
            else => {},
        }
        switch (self.globals[i]) {
            .arr => return self.fatal("attempt to use array `{s}' in a scalar context", .{self.nameOf(i)}),
            .val => |old| self.retire(old.s),
            .unset => {},
        }
        const pv = self.persist(v);
        self.globals[i] = .{ .val = pv };
        if (i <= SLOT_FPAT) self.syncSpecial(i, pv);
    }
    fn cellOf(self: *Interp, n: *Node) *Cell {
        return switch (n.tag) {
            .gvar => &self.globals[n.i],
            .lvar => &self.frame[n.i],
            else => unreachable,
        };
    }
    fn arrayOf(self: *Interp, n: *Node) Err!*Array {
        const cell = self.cellOf(n);
        switch (cell.*) {
            .arr => |a| return a,
            .unset => {
                const a = A.create(Array) catch @panic("oom");
                a.* = .{};
                cell.* = .{ .arr = a };
                return a;
            },
            .val => return self.fatal("attempt to use scalar `{s}' as an array", .{n.s}),
        }
    }
    fn subKey(self: *Interp, subs: []*Node) Err![]const u8 {
        if (subs.len == 1) return self.toStr(try self.eval(subs[0]));
        var out = u.Vec(u8).init(self.tmp());
        for (subs, 0..) |s, i| {
            if (i > 0) for (self.subsep) |b| out.push(b);
            for (self.toStr(try self.eval(s))) |b| out.push(b);
        }
        return out.items;
    }
    fn elemPtr(self: *Interp, arr: *Array, key: []const u8) *Val {
        _ = self;
        const gop = arr.map.getOrPut(A, key) catch @panic("oom");
        if (!gop.found_existing) {
            gop.key_ptr.* = A.dupe(u8, key) catch @panic("oom");
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }

    const LRef = union(enum) { g: usize, l: usize, fld: i64, elem: struct { arr: *Array, key: []const u8 } };
    fn lref(self: *Interp, n: *Node) Err!LRef {
        return switch (n.tag) {
            .gvar => .{ .g = n.i },
            .lvar => .{ .l = n.i },
            .field => blk: {
                const idx = self.toNum(try self.eval(n.a.?));
                break :blk .{ .fld = @intFromFloat(idx) };
            },
            .index => blk: {
                const arr = try self.arrayOf(n.a.?);
                const key = try self.subKey(n.list);
                break :blk .{ .elem = .{ .arr = arr, .key = key } };
            },
            .group => try self.lref(n.a.?),
            else => self.fatal("invalid lvalue", .{}),
        };
    }
    fn lload(self: *Interp, r: LRef) Err!Val {
        return switch (r) {
            .g => |i| try self.loadG(i),
            .l => |i| switch (self.frame[i]) {
                .unset => Val{},
                .val => |v| v,
                .arr => self.fatal("attempt to use array in a scalar context", .{}),
            },
            .fld => |i| try self.getField(i),
            .elem => |e| self.elemPtr(e.arr, e.key).*,
        };
    }
    fn lstore(self: *Interp, r: LRef, v: Val) Err!void {
        switch (r) {
            .g => |i| try self.storeG(i, v),
            .l => |i| {
                if (self.frame[i] == .arr) return self.fatal("attempt to use array in a scalar context", .{});
                self.frame[i] = .{ .val = Val{ .kind = v.kind, .n = v.n, .s = if (v.s.len > 0) self.tmp().dupe(u8, v.s) catch @panic("oom") else "" } };
            },
            .fld => |i| try self.setField(i, self.toStr(v)),
            .elem => |e| {
                const p = self.elemPtr(e.arr, e.key);
                self.retire(p.s);
                p.* = self.persist(v);
            },
        }
    }

    // ---- evaluation
    fn evalBool(self: *Interp, n: *Node) Err!bool {
        if (n.tag == .regex) return self.rxMatches(self.rxLit(n), self.getRecord());
        return self.toBool(try self.eval(n));
    }
    fn eval(self: *Interp, n: *Node) Err!Val {
        switch (n.tag) {
            .num => return Val.num(n.n),
            .str => return Val.str(n.s),
            .regex => return Val.num(if (self.rxMatches(self.rxLit(n), self.getRecord())) 1 else 0),
            .group => return self.eval(n.a.?),
            .gvar => return self.loadG(n.i),
            .lvar => return switch (self.frame[n.i]) {
                .unset => Val{},
                .val => |v| v,
                .arr => self.fatal("attempt to use array `{s}' in a scalar context", .{n.s}),
            },
            .field => {
                const v = try self.eval(n.a.?);
                return self.getField(@intFromFloat(self.toNum(v)));
            },
            .index => {
                const arr = try self.arrayOf(n.a.?);
                const key = try self.subKey(n.list);
                return self.elemPtr(arr, key).*;
            },
            .assign => {
                if (n.op == 0 and n.a.?.tag == .gvar and n.a.?.i > SLOT_IGNORECASE) {
                    const rhs = n.b.?;
                    if (rhs.tag == .concat and rhs.a.?.tag == .gvar and rhs.a.?.i == n.a.?.i) return self.appendVar(n.a.?.i, rhs.b.?);
                }
                const r = try self.lref(n.a.?);
                var v: Val = undefined;
                if (n.op == 0) {
                    v = try self.eval(n.b.?);
                    if (v.kind == .uninit) v = .{};
                } else {
                    const rhs = self.toNum(try self.eval(n.b.?));
                    const lhs = self.toNum(try self.lload(r));
                    v = Val.num(try self.arith(n.op, lhs, rhs));
                }
                try self.lstore(r, v);
                return v;
            },
            .cond => return if (try self.evalBool(n.a.?)) self.eval(n.b.?) else self.eval(n.c.?),
            .lor => return Val.num(if (try self.evalBool(n.a.?) or try self.evalBool(n.b.?)) 1 else 0),
            .land => return Val.num(if (try self.evalBool(n.a.?) and try self.evalBool(n.b.?)) 1 else 0),
            .in_ => {
                const arr = try self.arrayOf(n.a.?);
                const key = try self.subKey(n.list);
                return Val.num(if (arr.map.contains(key)) 1 else 0);
            },
            .match, .nmatch => {
                const s = self.toStr(try self.eval(n.a.?));
                const rx = try self.rxFromNode(n.b.?);
                const m = self.rxMatches(rx, s);
                return Val.num(if (m == (n.tag == .match)) 1 else 0);
            },
            .cmp => {
                const a = try self.eval(n.a.?);
                const b = try self.eval(n.b.?);
                const r = self.compare(a, b);
                const t = switch (n.op) {
                    '<' => r < 0,
                    'l' => r <= 0,
                    '>' => r > 0,
                    'g' => r >= 0,
                    '=' => r == 0,
                    else => r != 0,
                };
                return Val.num(if (t) 1 else 0);
            },
            .concat => {
                const a = self.toStr(try self.eval(n.a.?));
                const b = self.toStr(try self.eval(n.b.?));
                const buf = self.tmp().alloc(u8, a.len + b.len) catch @panic("oom");
                @memcpy(buf[0..a.len], a);
                @memcpy(buf[a.len..], b);
                return Val.str(buf);
            },
            .arith => {
                const a = self.toNum(try self.eval(n.a.?));
                const b = self.toNum(try self.eval(n.b.?));
                return Val.num(try self.arith(n.op, a, b));
            },
            .neg => return Val.num(-self.toNum(try self.eval(n.a.?))),
            .pos => return Val.num(self.toNum(try self.eval(n.a.?))),
            .not => return Val.num(if (try self.evalBool(n.a.?)) 0 else 1),
            .preinc, .predec, .postinc, .postdec => {
                const r = try self.lref(n.a.?);
                const old = self.toNum(try self.lload(r));
                const delta: f64 = if (n.tag == .preinc or n.tag == .postinc) 1 else -1;
                try self.lstore(r, Val.num(old + delta));
                return Val.num(if (n.tag == .preinc or n.tag == .predec) old + delta else old);
            },
            .builtin => return self.builtin(n),
            .call => return self.callUser(n),
            .getline => return self.getline(n),
            else => unreachable,
        }
    }
    /// `x = x expr` appends in place with amortised growth.
    fn appendVar(self: *Interp, slot: usize, rhs: *Node) Err!Val {
        const add = self.toStr(try self.eval(rhs));
        const cell = &self.globals[slot];
        var cur: Val = switch (cell.*) {
            .val => |v| v,
            .unset => Val{},
            .arr => return self.fatal("attempt to use array `{s}' in a scalar context", .{self.nameOf(slot)}),
        };
        if (cur.kind == .num or cur.kind == .uninit) {
            cur = self.persist(Val.str(self.dupeP(self.toStr(cur))));
        } else if (cur.kind == .strnum) cur.kind = .str;
        const need = cur.s.len + add.len;
        if (cur.cap >= need and cur.cap > 0) {
            const buf: [*]u8 = @constCast(cur.s.ptr);
            @memcpy(buf[cur.s.len..need], add);
            cur.s = buf[0..need];
        } else {
            const ncap = @max(need * 2, 32);
            const nb = A.alloc(u8, ncap) catch @panic("oom");
            @memcpy(nb[0..cur.s.len], cur.s);
            @memcpy(nb[cur.s.len..need], add);
            self.retire(cur.s);
            cur.s = nb[0..need];
            cur.cap = ncap;
        }
        cur.n = 0;
        cell.* = .{ .val = cur };
        return cur;
    }
    fn arith(self: *Interp, op: u8, a: f64, b: f64) Err!f64 {
        return switch (op) {
            '+' => a + b,
            '-' => a - b,
            '*' => a * b,
            '/' => if (b == 0) self.fatal("division by zero attempted", .{}) else a / b,
            '%' => if (b == 0) self.fatal("division by zero attempted in `%'", .{}) else @rem(a, b),
            '^' => std.math.pow(f64, a, b),
            else => unreachable,
        };
    }

    // ---- user functions
    fn callUser(self: *Interp, n: *Node) Err!Val {
        const f = &self.funcs.items[n.i];
        if (!f.defined) return self.fatal("function `{s}' not defined", .{f.name});
        if (n.list.len > f.nparams) return self.fatal("function `{s}' called with more arguments than declared", .{f.name});
        const locals = self.tmp().alloc(Cell, f.nparams) catch @panic("oom");
        for (locals) |*l| l.* = .unset;
        var writeback: [32]?*Cell = @splat(null);
        for (n.list, 0..) |arg, i| {
            if (arg.tag == .gvar or arg.tag == .lvar) {
                if (arg.tag == .gvar and arg.i <= SLOT_NF + 2) {
                    locals[i] = .{ .val = try self.eval(arg) };
                    continue;
                }
                const cell = self.cellOf(arg);
                switch (cell.*) {
                    .arr => |a| locals[i] = .{ .arr = a },
                    .unset => {
                        locals[i] = .unset;
                        if (i < writeback.len) writeback[i] = cell;
                    },
                    .val => |v| locals[i] = .{ .val = v },
                }
            } else locals[i] = .{ .val = try self.eval(arg) };
        }
        const saved = self.frame;
        self.frame = locals;
        self.retval = .{};
        self.depth += 1;
        const flow = self.exec(f.body.?);
        self.depth -= 1;
        self.frame = saved;
        _ = flow catch |e| return e;
        for (0..@min(n.list.len, writeback.len)) |i| {
            if (writeback[i]) |cell| if (locals[i] == .arr and cell.* == .unset) {
                cell.* = locals[i];
            };
        }
        const rv = self.retval;
        self.retval = .{};
        return rv;
    }

    // ---- statements
    fn exec(self: *Interp, n: *Node) Err!Flow {
        const f = try self.execInner(n);
        if (self.depth == 0) switch (n.tag) {
            .s_expr, .s_print, .s_printf, .s_delete => self.endCycle(),
            else => {},
        };
        return f;
    }
    fn execInner(self: *Interp, n: *Node) Err!Flow {
        switch (n.tag) {
            .s_block => {
                for (n.list) |s| {
                    const f = try self.exec(s);
                    if (f != .normal) return f;
                }
                return .normal;
            },
            .s_expr => {
                _ = try self.eval(n.a.?);
                return .normal;
            },
            .s_if => {
                if (try self.evalBool(n.a.?)) return self.exec(n.b.?);
                if (n.c) |e| return self.exec(e);
                return .normal;
            },
            .s_while => {
                while (try self.evalBool(n.a.?)) {
                    const f = try self.exec(n.b.?);
                    if (f == .brk) break;
                    if (f == .ret) return f;
                }
                return .normal;
            },
            .s_do => {
                while (true) {
                    const f = try self.exec(n.a.?);
                    if (f == .brk) break;
                    if (f == .ret) return f;
                    if (!try self.evalBool(n.b.?)) break;
                }
                return .normal;
            },
            .s_for => {
                if (n.a) |i| _ = try self.exec(i);
                while (true) {
                    if (n.b) |cnd| if (!try self.evalBool(cnd)) break;
                    const f = try self.exec(n.d.?);
                    if (f == .brk) break;
                    if (f == .ret) return f;
                    if (n.c) |inc| _ = try self.exec(inc);
                }
                return .normal;
            },
            .s_forin => {
                const arr = try self.arrayOf(n.b.?);
                const keys = A.alloc([]const u8, arr.map.count()) catch @panic("oom");
                for (arr.map.keys(), 0..) |k, i| keys[i] = A.dupe(u8, k) catch @panic("oom");
                defer {
                    for (keys) |k| A.free(k);
                    A.free(keys);
                }
                for (keys) |k| {
                    if (!arr.map.contains(k)) continue;
                    const r = try self.lref(n.a.?);
                    try self.lstore(r, Val.str(k));
                    const f = try self.exec(n.c.?);
                    if (f == .brk) break;
                    if (f == .ret) return f;
                }
                return .normal;
            },
            .s_print => {
                try self.doPrint(n);
                return .normal;
            },
            .s_printf => {
                try self.doPrintf(n);
                return .normal;
            },
            .s_next => return error.Next,
            .s_nextfile => return error.NextFile,
            .s_exit => {
                if (n.a) |e| self.exit_code = @intCast(@as(i64, @intFromFloat(self.toNum(try self.eval(e)))) & 0xff);
                return error.Exit;
            },
            .s_return => {
                self.retval = if (n.a) |e| try self.eval(e) else .{};
                return .ret;
            },
            .s_break => return .brk,
            .s_continue => return .cont,
            .s_delete => {
                const arr = try self.arrayOf(n.a.?);
                if (n.op == 1) {
                    for (arr.map.keys()) |k| self.retire(k);
                    for (arr.map.values()) |v| self.retire(v.s);
                    arr.map.clearRetainingCapacity();
                } else {
                    const key = try self.subKey(n.list);
                    if (arr.map.fetchOrderedRemove(key)) |kv| {
                        self.retire(kv.key);
                        self.retire(kv.value.s);
                    }
                }
                return .normal;
            },
            else => unreachable,
        }
    }

    // ---- output
    fn outFor(self: *Interp, kind: u8, name: []const u8) Err!*c.FILE {
        if (std.mem.eql(u8, name, "/dev/stdout") or (kind != '|' and std.mem.eql(u8, name, "-"))) return self.stdout_fp;
        if (std.mem.eql(u8, name, "/dev/stderr")) return self.stderr_fp;
        for (self.outs.items) |o| if (std.mem.eql(u8, o.name, name)) return o.fp;
        const z = u.zstr(name);
        defer A.free(z);
        var fp: ?*c.FILE = null;
        if (kind == '|') {
            _ = c.fflush(null);
            fp = c.popen(z.ptr, "w");
        } else fp = c.fopen(z.ptr, if (kind == 'a') "a" else "w");
        if (fp == null) return self.fatal("can't redirect to `{s}'", .{name});
        self.outs.push(.{ .name = self.dupeP(name), .fp = fp.?, .pipe = kind == '|' });
        return fp.?;
    }
    fn write(self: *Interp, fp: *c.FILE, data: []const u8) void {
        if (data.len > 0) _ = c.fwrite(data.ptr, 1, data.len, fp);
        if (fp == self.stderr_fp or (self.interactive and fp == self.stdout_fp)) _ = c.fflush(fp);
    }
    fn doPrint(self: *Interp, n: *Node) Err!void {
        var out = u.Vec(u8).init(self.tmp());
        if (n.list.len == 0) {
            for (self.getRecord()) |b| out.push(b);
        } else for (n.list, 0..) |arg, i| {
            if (i > 0) for (self.ofs) |b| out.push(b);
            for (self.toOut(try self.eval(arg))) |b| out.push(b);
        }
        for (self.ors) |b| out.push(b);
        const fp = if (n.op == 0) self.stdout_fp else try self.outFor(n.op, self.toStr(try self.eval(n.a.?)));
        self.write(fp, out.items);
    }
    fn doPrintf(self: *Interp, n: *Node) Err!void {
        const args = self.tmp().alloc(Val, n.list.len) catch @panic("oom");
        for (n.list, 0..) |arg, i| args[i] = try self.eval(arg);
        const s = try self.sprintf(args);
        const fp = if (n.op == 0) self.stdout_fp else try self.outFor(n.op, self.toStr(try self.eval(n.a.?)));
        self.write(fp, s);
    }

    fn sprintf(self: *Interp, args: []const Val) Err![]const u8 {
        if (args.len == 0) return "";
        const fmt = self.toStr(args[0]);
        var out = u.Vec(u8).init(self.tmp());
        var ai: usize = 1;
        var i: usize = 0;
        while (i < fmt.len) {
            const ch = fmt[i];
            if (ch != '%') {
                out.push(ch);
                i += 1;
                continue;
            }
            i += 1;
            if (i >= fmt.len) {
                out.push('%');
                break;
            }
            if (fmt[i] == '%') {
                out.push('%');
                i += 1;
                continue;
            }
            var flags = u.Vec(u8).init(self.tmp());
            while (i < fmt.len and std.mem.indexOfScalar(u8, "-+ #0'", fmt[i]) != null) : (i += 1) if (fmt[i] != '\'') flags.push(fmt[i]);
            var width: ?i64 = null;
            if (i < fmt.len and fmt[i] == '*') {
                if (ai >= args.len) return self.fatal("not enough arguments to satisfy format string", .{});
                width = @intFromFloat(self.toNum(args[ai]));
                ai += 1;
                i += 1;
            } else {
                var w: i64 = 0;
                var have = false;
                while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) {
                    w = w * 10 + (fmt[i] - '0');
                    have = true;
                }
                if (have) width = w;
            }
            var prec: ?i64 = null;
            if (i < fmt.len and fmt[i] == '.') {
                i += 1;
                if (i < fmt.len and fmt[i] == '*') {
                    if (ai >= args.len) return self.fatal("not enough arguments to satisfy format string", .{});
                    prec = @intFromFloat(self.toNum(args[ai]));
                    ai += 1;
                    i += 1;
                } else {
                    var p: i64 = 0;
                    while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) p = p * 10 + (fmt[i] - '0');
                    prec = p;
                }
            }
            while (i < fmt.len and std.mem.indexOfScalar(u8, "hlLqjzt", fmt[i]) != null) i += 1;
            if (i >= fmt.len) {
                // incomplete spec: emitted literally
                out.push('%');
                break;
            }
            const conv = fmt[i];
            i += 1;
            var left = false;
            for (flags.items) |f| if (f == '-') {
                left = true;
            };
            if (width) |w| if (w < 0) {
                left = true;
                width = -w;
            };
            if (conv == '%') {
                out.push('%');
                continue;
            }
            switch (conv) {
                'd', 'i', 'o', 'x', 'X', 'u', 'e', 'E', 'f', 'F', 'g', 'G', 'a', 'A', 'c', 's' => {},
                else => {
                    out.push('%');
                    for (flags.items) |f| out.push(f);
                    i -= 0;
                    out.push(conv);
                    continue;
                },
            }
            if (ai >= args.len) return self.fatal("not enough arguments to satisfy format string", .{});
            const arg = args[ai];
            ai += 1;
            if (conv == 's' or conv == 'c') {
                var text: []const u8 = undefined;
                if (conv == 's') {
                    text = self.toOutConv(arg);
                    if (prec) |p| if (p >= 0) {
                        text = text[0..self.byteOff(text, @intCast(p))];
                    };
                } else {
                    if (arg.kind == .num or (arg.kind == .strnum)) {
                        const code: i64 = @intFromFloat(self.toNum(arg));
                        var b = u.Vec(u8).init(self.tmp());
                        if (code >= 0x80 and self.utf8) {
                            var enc: [4]u8 = undefined;
                            const l = std.unicode.utf8Encode(@intCast(@min(code, 0x10ffff)), &enc) catch 0;
                            for (enc[0..l]) |x| b.push(x);
                        } else b.push(@truncate(@as(u64, @bitCast(code))));
                        text = b.items;
                    } else {
                        const s = self.toStr(arg);
                        if (s.len == 0) text = "\x00" else text = s[0..self.byteOff(s, 1)];
                    }
                }
                const len = self.charCount(text);
                const pad: usize = if (width) |w| (if (@as(usize, @intCast(w)) > len) @as(usize, @intCast(w)) - len else 0) else 0;
                if (!left) for (0..pad) |_| out.push(' ');
                for (text) |b| out.push(b);
                if (left) for (0..pad) |_| out.push(' ');
                continue;
            }
            // numeric conversions through snprintf
            var spec = u.Vec(u8).init(self.tmp());
            spec.push('%');
            for (flags.items) |f| spec.push(f);
            if (width) |w| for (std.fmt.allocPrint(self.tmp(), "{d}", .{w}) catch "") |b| spec.push(b);
            if (prec) |p| if (p >= 0) {
                spec.push('.');
                for (std.fmt.allocPrint(self.tmp(), "{d}", .{p}) catch "") |b| spec.push(b);
            };
            const nv = self.toNum(arg);
            var buf: [512]u8 = undefined;
            var text: []const u8 = undefined;
            switch (conv) {
                'd', 'i' => {
                    if (std.math.isNan(nv) or std.math.isInf(nv) or @abs(nv) >= 9.2e18) {
                        spec.items.len = 0;
                        spec.push('%');
                        for (flags.items) |f| spec.push(f);
                        if (width) |w| for (std.fmt.allocPrint(self.tmp(), "{d}", .{w}) catch "") |b| spec.push(b);
                        spec.push('.');
                        spec.push('0');
                        spec.push('f');
                        text = self.snp(&buf, spec.items, nv);
                    } else {
                        for ("lld") |b| spec.push(b);
                        text = self.snpInt(&buf, spec.items, @intFromFloat(nv));
                    }
                },
                'o', 'x', 'X', 'u' => {
                    var uv: u64 = undefined;
                    if (nv < 0) uv = @bitCast(@as(i64, @intFromFloat(@max(nv, -9.2e18)))) else uv = if (nv >= 1.8e19) std.math.maxInt(u64) else @intFromFloat(nv);
                    for ("ll") |b| spec.push(b);
                    spec.push(conv);
                    text = self.snpUint(&buf, spec.items, uv);
                },
                else => {
                    spec.push(conv);
                    text = self.snp(&buf, spec.items, nv);
                },
            }
            for (text) |b| out.push(b);
        }
        return out.items;
    }
    fn toOutConv(self: *Interp, v: Val) []const u8 {
        return switch (v.kind) {
            .num => self.numStr(v.n, self.ofmt),
            else => self.toStr(v),
        };
    }
    fn snp(self: *Interp, buf: []u8, spec: []const u8, v: f64) []const u8 {
        const z = u.zstr(spec);
        defer A.free(z);
        const len = c.snprintf(buf.ptr, buf.len, z.ptr, v);
        if (len < 0) return "";
        const l: usize = @intCast(len);
        if (l < buf.len) return self.tmp().dupe(u8, buf[0..l]) catch @panic("oom");
        const big = self.tmp().alloc(u8, l + 1) catch @panic("oom");
        _ = c.snprintf(big.ptr, big.len, z.ptr, v);
        return big[0..l];
    }
    fn snpInt(self: *Interp, buf: []u8, spec: []const u8, v: i64) []const u8 {
        const z = u.zstr(spec);
        defer A.free(z);
        const len = c.snprintf(buf.ptr, buf.len, z.ptr, @as(c_longlong, v));
        if (len < 0) return "";
        const l: usize = @intCast(len);
        if (l < buf.len) return self.tmp().dupe(u8, buf[0..l]) catch @panic("oom");
        const big = self.tmp().alloc(u8, l + 1) catch @panic("oom");
        _ = c.snprintf(big.ptr, big.len, z.ptr, @as(c_longlong, v));
        return big[0..l];
    }
    fn snpUint(self: *Interp, buf: []u8, spec: []const u8, v: u64) []const u8 {
        const z = u.zstr(spec);
        defer A.free(z);
        const len = c.snprintf(buf.ptr, buf.len, z.ptr, @as(c_ulonglong, v));
        if (len < 0) return "";
        const l: usize = @intCast(len);
        if (l < buf.len) return self.tmp().dupe(u8, buf[0..l]) catch @panic("oom");
        const big = self.tmp().alloc(u8, l + 1) catch @panic("oom");
        _ = c.snprintf(big.ptr, big.len, z.ptr, @as(c_ulonglong, v));
        return big[0..l];
    }

    // ---- input
    /// Read the next record from `r` according to RS. Returns a slice valid until the next read.
    fn readRecord(self: *Interp, r: *Reader) ?[]const u8 {
        const rs = self.rs;
        self.setRT("");
        if (rs.len == 1 or (rs.len == 0 and false)) {
            const sep = rs[0];
            var scanned: usize = 0;
            while (true) {
                const hay = r.buf[r.start..r.end];
                if (std.mem.indexOfScalarPos(u8, hay, scanned, sep)) |at| {
                    const rec = hay[0..at];
                    r.start += at + 1;
                    self.setRT(rs);
                    return rec;
                }
                scanned = hay.len;
                const before = r.start;
                if (!r.fill()) {
                    if (r.start == r.end) return null;
                    const rec = r.buf[r.start..r.end];
                    r.start = r.end;
                    return rec;
                }
                if (r.start != before) scanned = r.end - r.start - 0;
                // fill may have moved data; rescan conservatively
                scanned = 0;
            }
        }
        if (rs.len == 0) {
            // paragraph mode
            while (true) {
                while (r.start < r.end and r.buf[r.start] == '\n') r.start += 1;
                if (r.start < r.end) break;
                if (!r.fill()) return null;
            }
            var scanned: usize = 0;
            while (true) {
                const hay = r.buf[r.start..r.end];
                if (std.mem.indexOfPos(u8, hay, scanned, "\n\n")) |at| {
                    const rec = hay[0..at];
                    var e = r.start + at;
                    // consume the run of newlines
                    while (true) {
                        while (e < r.end and r.buf[e] == '\n') e += 1;
                        if (e < r.end or r.eof) break;
                        const consumed = e - r.start;
                        if (!r.fill()) break;
                        e = r.start + consumed;
                    }
                    const recl = at;
                    const base = r.start;
                    _ = base;
                    const out = r.buf[r.start .. r.start + recl];
                    _ = rec;
                    self.setRT(self.tmp().dupe(u8, r.buf[r.start + recl .. e]) catch "");
                    r.start = e;
                    return out;
                }
                scanned = if (hay.len > 0) hay.len - 1 else 0;
                if (!r.fill()) {
                    var rec = r.buf[r.start..r.end];
                    r.start = r.end;
                    if (rec.len > 0 and rec[rec.len - 1] == '\n') {
                        rec = rec[0 .. rec.len - 1];
                        self.setRT("\n");
                    }
                    return rec;
                }
            }
        }
        // regular expression RS: load everything
        while (r.fill()) {}
        const data = r.buf[r.start..r.end];
        if (data.len == 0) return null;
        const rx = self.compileRx(rs, self.ignorecase) catch return null;
        const z = self.zcopy(data);
        var pm: [1]c.regmatch_t = undefined;
        var pos: usize = 0;
        while (self.rxFindZ(rx, z, data.len, pos, &pm)) {
            const ms: usize = @intCast(pm[0].rm_so);
            const me: usize = @intCast(pm[0].rm_eo);
            if (me == ms) {
                pos = ms + 1;
                if (pos > data.len) break;
                continue;
            }
            self.setRT(self.tmp().dupe(u8, data[ms..me]) catch "");
            r.start += me;
            return data[0..ms];
        }
        r.start = r.end;
        var rec = data;
        if (rec.len > 0 and rec[rec.len - 1] == '\n' and false) rec = rec[0 .. rec.len - 1];
        return rec;
    }
    fn setRT(self: *Interp, s: []const u8) void {
        const old = self.globals[SLOT_RT];
        if (old == .val) self.retire(old.val.s);
        self.globals[SLOT_RT] = .{ .val = Val.str(self.dupeP(s)) };
    }
    fn assignCmdline(self: *Interp, arg: []const u8) bool {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return false;
        if (eq == 0) return false;
        if (!(std.ascii.isAlphabetic(arg[0]) or arg[0] == '_')) return false;
        for (arg[0..eq]) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
        const slot = self.globalSlot(arg[0..eq]);
        self.growGlobals();
        const value = processEscapes(arg[eq + 1 ..]);
        self.storeG(slot, mkStrnum(value)) catch {};
        return true;
    }
    fn growGlobals(self: *Interp) void {
        if (self.globals.len >= self.nglobals) return;
        const g = A.alloc(Cell, self.nglobals + 64) catch @panic("oom");
        for (g) |*x| x.* = .unset;
        @memcpy(g[0..self.globals.len], self.globals);
        if (self.globals.len > 0) A.free(self.globals);
        self.globals = g;
    }
    fn openMain(self: *Interp) Err!bool {
        while (true) {
            const argc: usize = @intFromFloat(@max(0, self.toNum(self.globals[SLOT_ARGC].val)));
            if (self.argi >= argc) {
                if (self.used_file) return false;
                self.used_file = true;
                const r = A.create(Reader) catch @panic("oom");
                r.* = .{ .fd = 0 };
                self.main_reader = r;
                self.fnr = 0;
                try self.runRules(.beginfile);
                return true;
            }
            const argv = self.globals[SLOT_ARGV].arr;
            var kbuf: [32]u8 = undefined;
            const key = std.fmt.bufPrint(&kbuf, "{d}", .{self.argi}) catch "";
            self.argi += 1;
            const entry = argv.map.get(key) orelse continue;
            const arg = self.toStr(entry);
            if (arg.len == 0) continue;
            if (self.assignCmdline(arg)) continue;
            self.used_file = true;
            const r = A.create(Reader) catch @panic("oom");
            if (std.mem.eql(u8, arg, "-") or std.mem.eql(u8, arg, "/dev/stdin")) r.* = .{ .fd = 0 } else {
                const f = u.File.open(arg, .{ .ACCMODE = .RDONLY }, 0) orelse {
                    A.destroy(r);
                    return self.fatal("cannot open file `{s}' for reading: {s}", .{ arg, std.mem.sliceTo(c.strerror(std.c._errno().*), 0) });
                };
                r.* = .{ .fd = f.fd };
            }
            self.main_reader = r;
            self.fnr = 0;
            self.storeG(SLOT_FILENAME, Val.str(arg)) catch {};
            try self.runRules(.beginfile);
            return true;
        }
    }
    fn closeMain(self: *Interp) void {
        if (self.main_reader) |r| {
            if (r.fd != 0) _ = linux.close(r.fd);
            if (r.buf.len > 0) A.free(r.buf);
            A.destroy(r);
            self.main_reader = null;
        }
    }
    fn nextMain(self: *Interp) Err!bool {
        while (true) {
            if (self.main_reader == null) if (!try self.openMain()) return false;
            if (self.readRecord(self.main_reader.?)) |rec| {
                self.setRecord(self.dupeP(rec));
                self.nr += 1;
                self.fnr += 1;
                return true;
            }
            try self.runRules(.endfile);
            self.closeMain();
        }
    }
    fn skipFile(self: *Interp) Err!void {
        if (self.main_reader != null) try self.runRules(.endfile);
        self.closeMain();
    }

    fn getline(self: *Interp, n: *Node) Err!Val {
        switch (n.op) {
            0 => {
                if (!try self.nextMain()) return Val.num(0);
                if (n.a) |lv| {
                    const r = try self.lref(lv);
                    const rec = self.rec;
                    try self.lstore(r, mkStrnum(rec));
                }
                return Val.num(1);
            },
            else => {
                const name = self.toStr(try self.eval(n.b.?));
                const is_cmd = n.op == '|';
                var found: ?*In = null;
                for (self.ins.items) |*i| if (std.mem.eql(u8, i.name, name) and i.pipe == is_cmd) {
                    found = i;
                    break;
                };
                if (found == null) {
                    const r = A.create(Reader) catch @panic("oom");
                    if (is_cmd) {
                        _ = c.fflush(null);
                        const z = u.zstr(name);
                        defer A.free(z);
                        const fp = c.popen(z.ptr, "r") orelse return Val.num(-1);
                        r.* = .{ .fd = c.fileno(fp), .fp = fp };
                    } else if (std.mem.eql(u8, name, "-") or std.mem.eql(u8, name, "/dev/stdin")) {
                        r.* = .{ .fd = 0 };
                    } else {
                        const f = u.File.open(name, .{ .ACCMODE = .RDONLY }, 0) orelse {
                            A.destroy(r);
                            return Val.num(-1);
                        };
                        r.* = .{ .fd = f.fd };
                    }
                    self.ins.push(.{ .name = self.dupeP(name), .reader = r, .pipe = is_cmd });
                    found = &self.ins.items[self.ins.items.len - 1];
                }
                const rec = self.readRecord(found.?.reader) orelse return Val.num(0);
                const copy = self.dupeP(rec);
                if (n.a) |lv| {
                    const r = try self.lref(lv);
                    try self.lstore(r, mkStrnum(copy));
                    self.retire(copy);
                } else {
                    self.setRecord(copy);
                }
                return Val.num(1);
            },
        }
    }

    // ---- builtins
    fn argStr(self: *Interp, n: *Node, i: usize) Err![]const u8 {
        return self.toStr(try self.eval(n.list[i]));
    }
    fn argNum(self: *Interp, n: *Node, i: usize) Err!f64 {
        return self.toNum(try self.eval(n.list[i]));
    }
    fn needArgs(self: *Interp, n: *Node, name: []const u8, min: usize, max: usize) Err!void {
        if (n.list.len < min or n.list.len > max) return self.fatal("function `{s}' called with wrong number of arguments", .{name});
    }
    fn builtin(self: *Interp, n: *Node) Err!Val {
        const id: B = @enumFromInt(n.i);
        const nargs = n.list.len;
        switch (id) {
            .length => {
                if (nargs == 0) return Val.num(@floatFromInt(self.charCount(self.getRecord())));
                const a = n.list[0];
                if (a.tag == .gvar or a.tag == .lvar) {
                    switch (self.cellOf(a).*) {
                        .arr => |arr| return Val.num(@floatFromInt(arr.map.count())),
                        else => {},
                    }
                }
                return Val.num(@floatFromInt(self.charCount(self.toStr(try self.eval(a)))));
            },
            .substr => {
                try self.needArgs(n, "substr", 2, 3);
                const s = try self.argStr(n, 0);
                const total = self.charCount(s);
                var start = try self.argNum(n, 1);
                if (std.math.isNan(start)) return Val.str("");
                start = @trunc(start);
                var len: f64 = if (nargs == 3) @trunc(try self.argNum(n, 2)) else @as(f64, @floatFromInt(total));
                if (std.math.isNan(len)) return Val.str("");
                if (start < 1) start = 1;
                if (len <= 0) return Val.str("");
                const ts: f64 = @floatFromInt(total);
                if (start > ts) return Val.str("");
                if (start - 1 + len > ts) len = ts - (start - 1);
                const b0 = self.byteOff(s, @intFromFloat(start - 1));
                const b1 = self.byteOff(s, @intFromFloat(start - 1 + len));
                return Val.str(s[b0..b1]);
            },
            .index => {
                try self.needArgs(n, "index", 2, 2);
                const s = try self.argStr(n, 0);
                const t = try self.argStr(n, 1);
                const at = std.mem.indexOf(u8, s, t) orelse return Val.num(0);
                return Val.num(@floatFromInt(self.charCount(s[0..at]) + 1));
            },
            .split => return self.biSplit(n),
            .patsplit => {
                try self.needArgs(n, "patsplit", 2, 4);
                const str = try self.argStr(n, 0);
                var pieces = u.Vec([]const u8).init(self.tmp());
                var seps = u.Vec([]const u8).init(self.tmp());
                const pat = if (n.list.len >= 3) try self.argStr(n, 2) else self.fpat;
                if (n.list.len >= 3 and n.list[2].tag == .regex) self.splitFpat(str, n.list[2].s, &pieces, &seps) else self.splitFpat(str, pat, &pieces, &seps);
                const r = try self.finishSplit(n, &pieces, &seps);
                if (n.list.len == 4) {
                    const sarr = try self.arrayOf(n.list[3]);
                    self.clearArray(sarr);
                    var kb: [24]u8 = undefined;
                    for (seps.items, 0..) |sp, k| self.elemPtr(sarr, std.fmt.bufPrint(&kb, "{d}", .{k}) catch "").* = self.persist(Val.str(sp));
                }
                return r;
            },
            .sub, .gsub => return self.biSub(n, id == .gsub),
            .gensub => return self.biGensub(n),
            .match => return self.biMatch(n),
            .sprintf => {
                if (nargs == 0) return self.fatal("sprintf: no format", .{});
                const args = self.tmp().alloc(Val, nargs) catch @panic("oom");
                for (n.list, 0..) |a, i| args[i] = try self.eval(a);
                return Val.str(try self.sprintf(args));
            },
            .sin => return Val.num(@sin(try self.argNum(n, 0))),
            .cos => return Val.num(@cos(try self.argNum(n, 0))),
            .atan2 => return Val.num(std.math.atan2(try self.argNum(n, 0), try self.argNum(n, 1))),
            .exp => return Val.num(@exp(try self.argNum(n, 0))),
            .log => return Val.num(@log(try self.argNum(n, 0))),
            .sqrt => return Val.num(@sqrt(try self.argNum(n, 0))),
            .int => return Val.num(@trunc(try self.argNum(n, 0))),
            .rand => return Val.num(self.random()),
            .srand => {
                const prev = self.seed;
                const seed: f64 = if (nargs > 0) try self.argNum(n, 0) else @floatFromInt(u.nowSecs());
                self.srandom(@as(u32, @truncate(@as(u64, @bitCast(@as(i64, @intFromFloat(@trunc(@max(@min(seed, 9e18), -9e18)))))))));
                self.seed = seed;
                return Val.num(prev);
            },
            .tolower, .toupper => {
                const s = try self.argStr(n, 0);
                const out = self.tmp().dupe(u8, s) catch @panic("oom");
                for (out) |*b| b.* = if (id == .tolower) std.ascii.toLower(b.*) else std.ascii.toUpper(b.*);
                if (self.utf8) return Val.str(self.utf8Case(out, id == .toupper));
                return Val.str(out);
            },
            .system => {
                _ = c.fflush(null);
                const z = u.zstr(try self.argStr(n, 0));
                defer A.free(z);
                const rc = c.system(z.ptr);
                if (rc < 0) return Val.num(-1);
                const st: u32 = @intCast(rc);
                if (st & 0x7f == 0) return Val.num(@floatFromInt((st >> 8) & 0xff));
                return Val.num(@floatFromInt(256 + (st & 0x7f)));
            },
            .close => return self.biClose(try self.argStr(n, 0)),
            .fflush => {
                _ = c.fflush(null);
                return Val.num(0);
            },
            .systime => return Val.num(@floatFromInt(u.nowSecs())),
            .strftime => return self.biStrftime(n),
            .mktime => {
                const s = try self.argStr(n, 0);
                var tm: c.struct_tm = std.mem.zeroes(c.struct_tm);
                var vals: [7]i32 = .{ 0, 0, 0, 0, 0, 0, -1 };
                var it = std.mem.tokenizeAny(u8, s, " \t\n");
                var k: usize = 0;
                while (it.next()) |tok| : (k += 1) {
                    if (k >= 7) break;
                    vals[k] = std.fmt.parseInt(i32, tok, 10) catch return Val.num(-1);
                }
                if (k < 6) return Val.num(-1);
                tm.tm_year = vals[0] - 1900;
                tm.tm_mon = vals[1] - 1;
                tm.tm_mday = vals[2];
                tm.tm_hour = vals[3];
                tm.tm_min = vals[4];
                tm.tm_sec = vals[5];
                tm.tm_isdst = vals[6];
                const t = c.mktime(&tm);
                return Val.num(@floatFromInt(t));
            },
            .asort, .asorti => return self.biAsort(n, id == .asorti),
            .@"and", .@"or", .xor => {
                if (nargs < 2) return self.fatal("function called with too few arguments", .{});
                var acc: u64 = @intFromFloat(@max(0, try self.argNum(n, 0)));
                for (1..nargs) |i| {
                    const v: u64 = @intFromFloat(@max(0, try self.argNum(n, i)));
                    acc = switch (id) {
                        .@"and" => acc & v,
                        .@"or" => acc | v,
                        else => acc ^ v,
                    };
                }
                return Val.num(@floatFromInt(acc));
            },
            .lshift, .rshift => {
                const a: u64 = @intFromFloat(@max(0, try self.argNum(n, 0)));
                const b: u6 = @intCast(@min(63, @as(u64, @intFromFloat(@max(0, try self.argNum(n, 1))))));
                return Val.num(@floatFromInt(if (id == .lshift) a << b else a >> b));
            },
            .compl => {
                const a: u64 = @intFromFloat(@max(0, try self.argNum(n, 0)));
                return Val.num(@floatFromInt(~a & ((@as(u64, 1) << 53) - 1)));
            },
            .strtonum => {
                const v = try self.eval(n.list[0]);
                if (v.kind == .num or v.kind == .strnum) return Val.num(v.n);
                const s = std.mem.trim(u8, v.s, " \t\n");
                if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
                    return Val.num(@floatFromInt(std.fmt.parseInt(u64, s[2..], 16) catch 0));
                }
                if (s.len > 1 and s[0] == '0' and std.ascii.isDigit(s[1])) {
                    return Val.num(@floatFromInt(std.fmt.parseInt(u64, s[1..], 8) catch return Val.num(strToNum(s))));
                }
                return Val.num(strToNum(s));
            },
            .isarray => {
                const a = n.list[0];
                if (a.tag == .gvar or a.tag == .lvar) return Val.num(if (self.cellOf(a).* == .arr) 1 else 0);
                return Val.num(0);
            },
            .typeof => {
                const a = n.list[0];
                if (a.tag == .gvar or a.tag == .lvar) switch (self.cellOf(a).*) {
                    .arr => return Val.str("array"),
                    .unset => return Val.str("untyped"),
                    .val => |v| return Val.str(switch (v.kind) {
                        .uninit => "untyped",
                        .num => "number",
                        .str => "string",
                        .strnum => "strnum",
                    }),
                };
                const v = try self.eval(a);
                return Val.str(switch (v.kind) {
                    .uninit => "untyped",
                    .num => "number",
                    .str => "string",
                    .strnum => "strnum",
                });
            },
        }
    }
    fn utf8Case(self: *Interp, s: []const u8, upper: bool) []const u8 {
        // Map the common Latin-1 supplement / Greek / Cyrillic ranges; leave the rest unchanged.
        var out = u.Vec(u8).init(self.tmp());
        var i: usize = 0;
        while (i < s.len) {
            const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            if (l == 1 or i + l > s.len) {
                out.push(s[i]);
                i += 1;
                continue;
            }
            const cp = std.unicode.utf8Decode(s[i .. i + l]) catch {
                out.push(s[i]);
                i += 1;
                continue;
            };
            var m: u21 = cp;
            if (upper) {
                if ((cp >= 0xe0 and cp <= 0xfe and cp != 0xf7) or (cp >= 0x3b1 and cp <= 0x3c9 and cp != 0x3c2) or (cp >= 0x430 and cp <= 0x44f)) m = cp - 32 else if (cp >= 0x450 and cp <= 0x45f) m = cp - 80;
            } else {
                if ((cp >= 0xc0 and cp <= 0xde and cp != 0xd7) or (cp >= 0x391 and cp <= 0x3a9) or (cp >= 0x410 and cp <= 0x42f)) m = cp + 32 else if (cp >= 0x400 and cp <= 0x40f) m = cp + 80;
            }
            var enc: [4]u8 = undefined;
            const el = std.unicode.utf8Encode(m, &enc) catch 0;
            for (enc[0..el]) |b| out.push(b);
            i += l;
        }
        return out.items;
    }
    fn biClose(self: *Interp, name: []const u8) Val {
        var result: f64 = -1;
        var idx: usize = 0;
        while (idx < self.outs.items.len) {
            const o = self.outs.items[idx];
            if (std.mem.eql(u8, o.name, name)) {
                _ = c.fflush(null);
                if (o.pipe) {
                    const st = c.pclose(o.fp);
                    result = statusOf(st);
                } else result = @floatFromInt(c.fclose(o.fp));
                std.mem.copyForwards(Out, self.outs.items[idx .. self.outs.items.len - 1], self.outs.items[idx + 1 ..]);
                self.outs.items.len -= 1;
                continue;
            }
            idx += 1;
        }
        idx = 0;
        while (idx < self.ins.items.len) {
            const i = self.ins.items[idx];
            if (std.mem.eql(u8, i.name, name)) {
                if (i.reader.fp) |fp| result = statusOf(c.pclose(fp)) else {
                    _ = linux.close(i.reader.fd);
                    result = 0;
                }
                if (i.reader.buf.len > 0) A.free(i.reader.buf);
                A.destroy(i.reader);
                std.mem.copyForwards(In, self.ins.items[idx .. self.ins.items.len - 1], self.ins.items[idx + 1 ..]);
                self.ins.items.len -= 1;
                continue;
            }
            idx += 1;
        }
        return Val.num(result);
    }
    fn statusOf(st: c_int) f64 {
        if (st < 0) return -1;
        const s: u32 = @intCast(st);
        if (s & 0x7f == 0) return @floatFromInt((s >> 8) & 0xff);
        return @floatFromInt(256 + (s & 0x7f));
    }
    fn clearArray(self: *Interp, arr: *Array) void {
        for (arr.map.keys()) |k| self.retire(k);
        for (arr.map.values()) |v| self.retire(v.s);
        arr.map.clearRetainingCapacity();
    }
    fn biSplit(self: *Interp, n: *Node) Err!Val {
        try self.needArgs(n, "split", 2, 4);
        const s = try self.argStr(n, 0);
        const arrn = n.list[1];
        if (arrn.tag != .gvar and arrn.tag != .lvar) return self.fatal("split: second argument must be an array", .{});
        var fs = self.fs;
        var pieces = u.Vec([]const u8).init(self.tmp());
        var seps = u.Vec([]const u8).init(self.tmp());
        // evaluate the string and separator before touching the array (it may alias)
        if (nargs3(n)) {
            const fnode = n.list[2];
            if (fnode.tag == .regex) {
                const rx = self.rxLit(fnode);
                self.splitRx(s, rx, &pieces, &seps);
                return self.finishSplit(n, &pieces, &seps);
            }
            fs = self.toStr(try self.eval(fnode));
        }
        self.splitInto(s, fs, false, &pieces, &seps);
        return self.finishSplit(n, &pieces, &seps);
    }
    fn nargs3(n: *Node) bool {
        return n.list.len >= 3;
    }
    fn splitRx(self: *Interp, s: []const u8, rx: *Rx, out: *u.Vec([]const u8), seps: *u.Vec([]const u8)) void {
        if (s.len == 0) return;
        const z = self.zcopy(s);
        var pm: [1]c.regmatch_t = undefined;
        var st: usize = 0;
        var pos: usize = 0;
        while (pos <= s.len and self.rxFindZ(rx, z, s.len, pos, &pm)) {
            const ms: usize = @intCast(pm[0].rm_so);
            const me: usize = @intCast(pm[0].rm_eo);
            if (me == ms) {
                pos = ms + 1;
                continue;
            }
            out.push(s[st..ms]);
            seps.push(s[ms..me]);
            st = me;
            pos = me;
        }
        out.push(s[st..]);
    }
    fn finishSplit(self: *Interp, n: *Node, pieces: *u.Vec([]const u8), seps: *u.Vec([]const u8)) Err!Val {
        const arr = try self.arrayOf(n.list[1]);
        self.clearArray(arr);
        var kbuf: [24]u8 = undefined;
        for (pieces.items, 0..) |p, i| {
            const key = std.fmt.bufPrint(&kbuf, "{d}", .{i + 1}) catch "";
            const e = self.elemPtr(arr, key);
            e.* = self.persist(mkStrnum(p));
        }
        if (n.list.len == 4 and n.i == @intFromEnum(B.split)) {
            const sarr = try self.arrayOf(n.list[3]);
            self.clearArray(sarr);
            for (seps.items, 0..) |p, i| {
                const key = std.fmt.bufPrint(&kbuf, "{d}", .{i + 1}) catch "";
                self.elemPtr(sarr, key).* = self.persist(Val.str(p));
            }
        }
        return Val.num(@floatFromInt(pieces.items.len));
    }
    /// Append the replacement template with & and \\ handling.
    fn expandRepl(self: *Interp, out: *u.Vec(u8), tmpl: []const u8, s: []const u8, pm: []const c.regmatch_t, gensub_mode: bool) void {
        _ = self;
        var i: usize = 0;
        while (i < tmpl.len) : (i += 1) {
            const ch = tmpl[i];
            if (ch == '\\' and i + 1 < tmpl.len) {
                const e = tmpl[i + 1];
                if (gensub_mode) {
                    if (e >= '0' and e <= '9') {
                        const g = e - '0';
                        if (g < pm.len and pm[g].rm_so >= 0) for (s[@intCast(pm[g].rm_so)..@intCast(pm[g].rm_eo)]) |b| out.push(b);
                        i += 1;
                        continue;
                    }
                    if (e == '&') {
                        out.push('&');
                        i += 1;
                        continue;
                    }
                    if (e == '\\') {
                        out.push('\\');
                        i += 1;
                        continue;
                    }
                } else {
                    if (e == '&') {
                        out.push('&');
                        i += 1;
                        continue;
                    }
                    if (e == '\\') {
                        out.push('\\');
                        i += 1;
                        continue;
                    }
                }
                out.push('\\');
                continue;
            }
            if (ch == '&') {
                for (s[@intCast(pm[0].rm_so)..@intCast(pm[0].rm_eo)]) |b| out.push(b);
                continue;
            }
            out.push(ch);
        }
    }
    fn biSub(self: *Interp, n: *Node, global: bool) Err!Val {
        try self.needArgs(n, if (global) "gsub" else "sub", 2, 3);
        const rx = try self.rxFromNode(n.list[0]);
        const repl = self.tmp().dupe(u8, try self.argStr(n, 1)) catch @panic("oom");
        var target_ref: ?LRef = null;
        var s: []const u8 = undefined;
        if (n.list.len == 3) {
            var t = n.list[2];
            while (t.tag == .group) t = t.a.?;
            if (Parser.isLvalue(t)) {
                target_ref = try self.lref(t);
                s = self.toStr(try self.lload(target_ref.?));
            } else s = self.toStr(try self.eval(t));
        } else {
            target_ref = .{ .fld = 0 };
            s = self.getRecord();
        }
        s = self.tmp().dupe(u8, s) catch @panic("oom");
        const z = self.zcopy(s);
        var out = u.Vec(u8).init(self.tmp());
        var pm: [10]c.regmatch_t = undefined;
        var pos: usize = 0;
        var copied: usize = 0;
        var count: usize = 0;
        var prev_end: ?usize = null;
        while (pos <= s.len) {
            // zcopy's buffer is clobbered by nested regex calls only via expandRepl (which does none)
            if (!self.rxFindZ(rx, z, s.len, pos, &pm)) break;
            const ms: usize = @intCast(pm[0].rm_so);
            const me: usize = @intCast(pm[0].rm_eo);
            if (me == ms and prev_end != null and prev_end.? == ms) {
                pos = ms + 1;
                prev_end = null;
                continue;
            }
            for (s[copied..ms]) |b| out.push(b);
            self.expandRepl(&out, repl, s, &pm, false);
            copied = me;
            count += 1;
            if (!global) break;
            if (me == ms) {
                pos = ms + 1;
                prev_end = null;
            } else {
                pos = me;
                prev_end = me;
            }
        }
        if (count > 0) {
            for (s[copied..]) |b| out.push(b);
            if (target_ref) |r| try self.lstore(r, Val.str(out.items));
        }
        return Val.num(@floatFromInt(count));
    }
    fn biGensub(self: *Interp, n: *Node) Err!Val {
        try self.needArgs(n, "gensub", 3, 4);
        const rx = try self.rxFromNode(n.list[0]);
        const repl = self.tmp().dupe(u8, try self.argStr(n, 1)) catch @panic("oom");
        const how = try self.argStr(n, 2);
        var global = false;
        var which: usize = 1;
        if (how.len > 0 and (how[0] == 'g' or how[0] == 'G')) global = true else {
            const hv = strToNum(how);
            which = if (hv >= 1) @intFromFloat(hv) else 1;
        }
        const s = self.tmp().dupe(u8, if (n.list.len == 4) try self.argStr(n, 3) else self.getRecord()) catch @panic("oom");
        const z = self.zcopy(s);
        var out = u.Vec(u8).init(self.tmp());
        var pm: [10]c.regmatch_t = undefined;
        var pos: usize = 0;
        var copied: usize = 0;
        var seen: usize = 0;
        var prev_end: ?usize = null;
        while (pos <= s.len) {
            if (!self.rxFindZ(rx, z, s.len, pos, &pm)) break;
            const ms: usize = @intCast(pm[0].rm_so);
            const me: usize = @intCast(pm[0].rm_eo);
            if (me == ms and prev_end != null and prev_end.? == ms) {
                pos = ms + 1;
                prev_end = null;
                continue;
            }
            seen += 1;
            if (global or seen == which) {
                for (s[copied..ms]) |b| out.push(b);
                self.expandRepl(&out, repl, s, &pm, true);
                copied = me;
                if (!global) break;
            }
            if (me == ms) {
                pos = ms + 1;
                prev_end = null;
            } else {
                pos = me;
                prev_end = me;
            }
        }
        for (s[copied..]) |b| out.push(b);
        return Val.str(out.items);
    }
    fn biMatch(self: *Interp, n: *Node) Err!Val {
        try self.needArgs(n, "match", 2, 3);
        const s = self.tmp().dupe(u8, try self.argStr(n, 0)) catch @panic("oom");
        const rx = try self.rxFromNode(n.list[1]);
        const z = self.zcopy(s);
        var pm: [10]c.regmatch_t = undefined;
        var start: f64 = 0;
        var length: f64 = -1;
        const found = self.rxFindZ(rx, z, s.len, 0, &pm);
        if (found) {
            const ms: usize = @intCast(pm[0].rm_so);
            const me: usize = @intCast(pm[0].rm_eo);
            start = @floatFromInt(self.charCount(s[0..ms]) + 1);
            length = @floatFromInt(self.charCount(s[ms..me]));
        }
        try self.storeG(SLOT_RSTART, Val.num(start));
        try self.storeG(SLOT_RLENGTH, Val.num(length));
        if (n.list.len == 3) {
            const arr = try self.arrayOf(n.list[2]);
            self.clearArray(arr);
            if (found) {
                var kb: [48]u8 = undefined;
                for (pm[0..@min(10, rx.nsub + 1)], 0..) |m, i| {
                    if (m.rm_so < 0) continue;
                    const text = s[@intCast(m.rm_so)..@intCast(m.rm_eo)];
                    const key = std.fmt.bufPrint(&kb, "{d}", .{i}) catch "";
                    self.elemPtr(arr, key).* = self.persist(mkStrnum(text));
                    const ks = std.fmt.bufPrint(&kb, "{d}{s}start", .{ i, self.subsep }) catch "";
                    self.elemPtr(arr, ks).* = Val.num(@floatFromInt(self.charCount(s[0..@intCast(m.rm_so)]) + 1));
                    const kl = std.fmt.bufPrint(&kb, "{d}{s}length", .{ i, self.subsep }) catch "";
                    self.elemPtr(arr, kl).* = Val.num(@floatFromInt(self.charCount(text)));
                }
            }
        }
        return Val.num(start);
    }
    fn biStrftime(self: *Interp, n: *Node) Err!Val {
        const fmt = if (n.list.len >= 1) try self.argStr(n, 0) else "%a %b %e %H:%M:%S %Z %Y";
        const ts: c.time_t = if (n.list.len >= 2) @intFromFloat(try self.argNum(n, 1)) else @intCast(u.nowSecs());
        const utc = n.list.len >= 3 and self.toBool(try self.eval(n.list[2]));
        var tm: c.struct_tm = undefined;
        if (utc) _ = c.gmtime_r(&ts, &tm) else _ = c.localtime_r(&ts, &tm);
        const z = u.zstr(fmt);
        defer A.free(z);
        var buf: [4096]u8 = undefined;
        const l = c.strftime(&buf, buf.len, z.ptr, &tm);
        return Val.str(self.tmp().dupe(u8, buf[0..l]) catch @panic("oom"));
    }
    fn biAsort(self: *Interp, n: *Node, by_index: bool) Err!Val {
        try self.needArgs(n, "asort", 1, 3);
        const src = try self.arrayOf(n.list[0]);
        const dst = if (n.list.len >= 2) try self.arrayOf(n.list[1]) else src;
        const count = src.map.count();
        const items = self.tmp().alloc(Val, count) catch @panic("oom");
        for (src.map.keys(), src.map.values(), 0..) |k, v, i| {
            items[i] = if (by_index) Val.str(self.tmp().dupe(u8, k) catch @panic("oom")) else .{ .kind = v.kind, .n = v.n, .s = self.tmp().dupe(u8, v.s) catch @panic("oom") };
        }
        const Ctx = struct {
            it: *Interp,
            fn less(ctx: @This(), a: Val, b: Val) bool {
                // numbers sort before strings
                const an = a.kind == .num or a.kind == .strnum;
                const bn = b.kind == .num or b.kind == .strnum;
                if (an and !bn) return true;
                if (!an and bn) return false;
                return ctx.it.compare(a, b) < 0;
            }
        };
        std.mem.sort(Val, items, Ctx{ .it = self }, Ctx.less);
        self.clearArray(dst);
        var kb: [24]u8 = undefined;
        for (items, 0..) |v, i| {
            const key = std.fmt.bufPrint(&kb, "{d}", .{i + 1}) catch "";
            self.elemPtr(dst, key).* = self.persist(v);
        }
        return Val.num(@floatFromInt(count));
    }

    // ---- random numbers: BSD/glibc random() TYPE_4 as used by gawk, for identical sequences
    fn srandom(self: *Interp, seed_in: u32) void {
        const deg = 63;
        var seed = seed_in;
        if (seed == 0) seed = 1;
        self.rng_state[0] = seed;
        var word: i64 = @intCast(@as(i32, @bitCast(seed)));
        for (1..deg) |i| {
            const hi = @divTrunc(word, 127773);
            const lo = @rem(word, 127773);
            word = 16807 * lo - 2836 * hi;
            if (word < 0) word += 2147483647;
            self.rng_state[i] = @bitCast(@as(i32, @intCast(word)));
        }
        self.rng_f = 1;
        self.rng_r = 0;
        self.rng_init = true;
        for (0..deg * 10) |_| _ = self.randomRaw();
    }
    fn randomRaw(self: *Interp) u32 {
        const deg = 63;
        self.rng_state[self.rng_f] +%= self.rng_state[self.rng_r];
        const result = (self.rng_state[self.rng_f] >> 1) & 0x7fffffff;
        self.rng_f += 1;
        if (self.rng_f >= deg) {
            self.rng_f = 0;
            self.rng_r += 1;
        } else {
            self.rng_r += 1;
            if (self.rng_r >= deg) self.rng_r = 0;
        }
        return result;
    }
    fn random(self: *Interp) f64 {
        if (!self.rng_init) self.srandom(1);
        const div: f64 = 2147483648.0;
        while (true) {
            const d1: f64 = @floatFromInt(self.randomRaw());
            const d2: f64 = @floatFromInt(self.randomRaw());
            var t = 0.5 + ((d1 / div + d2) / div);
            t -= 0.5;
            if (t != 1.0) return t;
        }
    }

    // ---- program execution
    fn runRules(self: *Interp, kind: RuleKind) Err!void {
        for (self.rules.items) |*r| if (r.kind == kind) {
            _ = self.exec(r.action.?) catch |e| switch (e) {
                error.Next, error.NextFile => return self.fatal("`next' used in {s} action", .{if (kind == .begin) "BEGIN" else "END"}),
                else => return e,
            };
        };
    }
    fn runMain(self: *Interp, has_main: bool) Err!void {
        _ = has_main;
        while (try self.nextMain()) {
            for (self.rules.items) |*r| {
                if (r.kind != .main) continue;
                var go = false;
                if (r.p1 == null) go = true else if (r.p2 == null) go = try self.evalBool(r.p1.?) else {
                    if (!r.in_range) {
                        if (try self.evalBool(r.p1.?)) {
                            r.in_range = true;
                            go = true;
                            if (try self.evalBool(r.p2.?)) r.in_range = false;
                        }
                    } else {
                        go = true;
                        if (try self.evalBool(r.p2.?)) r.in_range = false;
                    }
                }
                if (!go) continue;
                if (r.action) |act| {
                    _ = self.exec(act) catch |e| switch (e) {
                        error.Next => break,
                        error.NextFile => {
                            try self.skipFile();
                            break;
                        },
                        else => return e,
                    };
                } else {
                    const rec = self.getRecord();
                    var out = u.Vec(u8).init(self.tmp());
                    for (rec) |b| out.push(b);
                    for (self.ors) |b| out.push(b);
                    self.write(self.stdout_fp, out.items);
                }
            }
            self.endCycle();
        }
    }
    fn closeAll(self: *Interp) void {
        for (self.outs.items) |o| {
            if (o.pipe) _ = c.pclose(o.fp) else _ = c.fclose(o.fp);
        }
        self.outs.items.len = 0;
        for (self.ins.items) |i| if (i.reader.fp) |fp| {
            _ = c.pclose(fp);
        };
        self.ins.items.len = 0;
        _ = c.fflush(null);
    }
};

fn processEscapes(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out = u.Vec(u8).init(A);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            out.push(s[i]);
            i += 1;
            continue;
        }
        const e = s[i + 1];
        if (numericEscape(s, i + 1)) |ne| {
            out.push(ne.byte);
            i += 1 + ne.len;
            continue;
        }
        if (simpleEscape(e)) |b| out.push(b) else if (e == '\\') out.push('\\') else {
            out.push(e);
        }
        i += 2;
    }
    return out.items;
}

fn usage() u8 {
    u.err("usage: awk [-F fs][-v var=value][prog | -f progfile][file ...]\n");
    return 1;
}

/// Deeply recursive awk functions need far more than the default 8 MiB stack:
/// raise the limit and re-exec once so the new limit shapes the stack mapping.
fn ensureBigStack() void {
    const want: u64 = 1 << 30;
    var lim: linux.rlimit = undefined;
    if (!u.ok(linux.getrlimit(.STACK, &lim))) return;
    if (lim.cur >= want or lim.cur == std.math.maxInt(@TypeOf(lim.cur))) return;
    const target = @min(want, lim.max);
    if (target <= lim.cur) return;
    lim.cur = target;
    if (!u.ok(linux.setrlimit(.STACK, &lim))) return;
    var argv = u.Vec([:0]const u8).init(A);
    for (u.raw_argv) |p| argv.push(std.mem.sliceTo(p, 0));
    _ = linux.execve("/proc/self/exe", u.argvp(argv.items), u.envp(&.{}));
}

pub fn run(args: []const []const u8) u8 {
    ensureBigStack();
    var it = Interp{};
    it.stdout_fp = c.fdopen(1, "w") orelse return 2;
    it.stderr_fp = c.fdopen(2, "w") orelse return 2;
    _ = c.setvbuf(it.stderr_fp, null, c._IONBF, 0);
    it.interactive = c.isatty(1) != 0;
    const loc = u.getEnv("LC_ALL") orelse u.getEnv("LC_CTYPE") orelse u.getEnv("LANG") orelse "";
    it.utf8 = std.ascii.indexOfIgnoreCase(loc, "utf-8") != null or std.ascii.indexOfIgnoreCase(loc, "utf8") != null;
    if (u.getEnv("LC_ALL")) |l| if (l.len == 0) {
        it.utf8 = false;
    };

    // predefine special variables
    for (special_names) |name| _ = it.globalSlot(name);
    var program = u.Vec(u8).init(A);
    var have_prog = false;
    var assigns = u.Vec([]const u8).init(A);
    var fs_opt: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.startsWith(u8, a, "--")) {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const name = if (eq) |e| a[0..e] else a;
            const val: ?[]const u8 = if (eq) |e| a[e + 1 ..] else null;
            if (std.mem.eql(u8, name, "--version")) {
                u.out("GNU Awk 5.3.2 compatible (cmdbox awk)\n");
                return 0;
            } else if (std.mem.eql(u8, name, "--field-separator")) {
                if (val) |v| fs_opt = v else {
                    i += 1;
                    if (i >= args.len) return usage();
                    fs_opt = args[i];
                }
            } else if (std.mem.eql(u8, name, "--assign")) {
                if (val) |v| assigns.push(v) else {
                    i += 1;
                    if (i >= args.len) return usage();
                    assigns.push(args[i]);
                }
            } else if (std.mem.eql(u8, name, "--file")) {
                const f = if (val) |v| v else blk: {
                    i += 1;
                    if (i >= args.len) return usage();
                    break :blk args[i];
                };
                const data = readFile(f) orelse return 2;
                if (have_prog) program.push('\n');
                for (data) |b| program.push(b);
                have_prog = true;
            } else if (std.mem.eql(u8, name, "--source")) {
                const v = if (val) |v| v else blk: {
                    i += 1;
                    if (i >= args.len) return usage();
                    break :blk args[i];
                };
                if (have_prog) program.push('\n');
                for (v) |b| program.push(b);
                have_prog = true;
            } else if (std.mem.eql(u8, name, "--posix") or std.mem.eql(u8, name, "--traditional") or std.mem.eql(u8, name, "--lint") or std.mem.eql(u8, name, "--re-interval") or std.mem.eql(u8, name, "--characters-as-bytes") or std.mem.eql(u8, name, "--no-optimize") or std.mem.eql(u8, name, "--optimize") or std.mem.eql(u8, name, "--sandbox") or std.mem.eql(u8, name, "--use-lc-numeric")) {
                if (std.mem.eql(u8, name, "--characters-as-bytes")) it.utf8 = false;
            } else if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "--usage")) {
                _ = usage();
                return 0;
            } else {
                u.errf("awk: unknown option {s} ignored\n", .{a});
            }
            continue;
        }
        var k: usize = 1;
        while (k < a.len) : (k += 1) {
            const o = a[k];
            switch (o) {
                'F', 'v', 'f', 'e', 'i', 'E' => {
                    const v = if (k + 1 < a.len) a[k + 1 ..] else blk: {
                        i += 1;
                        if (i >= args.len) return usage();
                        break :blk args[i];
                    };
                    switch (o) {
                        'F' => fs_opt = v,
                        'v' => assigns.push(v),
                        'f', 'E' => {
                            const data = readFile(v) orelse return 2;
                            if (have_prog) program.push('\n');
                            for (data) |b| program.push(b);
                            have_prog = true;
                        },
                        'e' => {
                            if (have_prog) program.push('\n');
                            for (v) |b| program.push(b);
                            have_prog = true;
                        },
                        else => {},
                    }
                    k = a.len;
                },
                'V' => {
                    u.out("GNU Awk 5.3.2 compatible (cmdbox awk)\n");
                    return 0;
                },
                'b' => it.utf8 = false,
                'P', 'c', 'n', 'N', 'O', 'r', 's', 'S', 't', 'g', 'h', 'l', 'p', 'M', 'o', 'd', 'D' => {},
                else => {
                    u.errf("awk: unknown option -{c} ignored\n", .{o});
                },
            }
        }
    }
    if (!have_prog) {
        if (i >= args.len) return usage();
        for (args[i]) |b| program.push(b);
        i += 1;
    }
    const files = args[i..];

    it.globals = A.alloc(Cell, 64) catch return 2;
    for (it.globals) |*g| g.* = .unset;
    var parser = Parser{ .it = &it, .src = program.items };
    parser.parseProgram() catch return 1;
    it.growGlobals();
    // function references must all be defined
    for (it.funcs.items) |f| if (!f.defined) {
        u.errf("awk: fatal: function `{s}' not defined\n", .{f.name});
        return 2;
    };

    // ARGV / ENVIRON
    const argv = A.create(Array) catch return 2;
    argv.* = .{};
    it.globals[SLOT_ARGV] = .{ .arr = argv };
    it.elemPtr(argv, "0").* = it.persist(Val.str("awk"));
    for (files, 0..) |f, k| {
        var kb: [24]u8 = undefined;
        it.elemPtr(argv, std.fmt.bufPrint(&kb, "{d}", .{k + 1}) catch "").* = it.persist(mkStrnum(f));
    }
    it.globals[SLOT_ARGC] = .{ .val = Val.num(@floatFromInt(files.len + 1)) };
    const env = A.create(Array) catch return 2;
    env.* = .{};
    it.globals[SLOT_ENVIRON] = .{ .arr = env };
    for (u.raw_env) |kv| {
        const e = kv orelse continue;
        const s = std.mem.sliceTo(e, 0);
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse continue;
        it.elemPtr(env, s[0..eq]).* = it.persist(mkStrnum(s[eq + 1 ..]));
    }
    const init_strs = [_]struct { usize, []const u8 }{
        .{ SLOT_FS, " " },    .{ SLOT_OFS, " " },      .{ SLOT_ORS, "\n" },       .{ SLOT_RS, "\n" },
        .{ SLOT_SUBSEP, "\x1c" }, .{ SLOT_CONVFMT, "%.6g" }, .{ SLOT_OFMT, "%.6g" }, .{ SLOT_FILENAME, "" },
        .{ SLOT_RT, "" },
    };
    for (init_strs) |e| it.globals[e[0]] = .{ .val = it.persist(Val.str(e[1])) };
    it.globals[SLOT_RSTART] = .{ .val = Val.num(0) };
    it.globals[SLOT_RLENGTH] = .{ .val = Val.num(-1) };
    it.globals[SLOT_IGNORECASE] = .{ .val = Val.num(0) };
    {
        const slot = it.globalSlot("PROCINFO");
        it.growGlobals();
        const pi = A.create(Array) catch return 2;
        pi.* = .{};
        it.globals[slot] = .{ .arr = pi };
        const strs = [_]struct { []const u8, []const u8 }{ .{ "version", "5.3.2" }, .{ "platform", "posix" }, .{ "FS", "FS" }, .{ "strftime", "%a %b %e %H:%M:%S %Z %Y" } };
        for (strs) |e| it.elemPtr(pi, e[0]).* = it.persist(Val.str(e[1]));
        const nums = [_]struct { []const u8, f64 }{
            .{ "pid", @floatFromInt(linux.getpid()) },   .{ "ppid", @floatFromInt(linux.getppid()) },
            .{ "uid", @floatFromInt(linux.getuid()) },   .{ "euid", @floatFromInt(linux.geteuid()) },
            .{ "gid", @floatFromInt(linux.getgid()) },   .{ "egid", @floatFromInt(linux.getegid()) },
        };
        for (nums) |e| it.elemPtr(pi, e[0]).* = Val.num(e[1]);
    }
    if (fs_opt) |f| {
        const v = processEscapes(f);
        it.storeG(SLOT_FS, Val.str(v)) catch {};
    }
    for (assigns.items) |a| if (!it.assignCmdline(a)) {
        u.errf("awk: invalid -v argument `{s}'\n", .{a});
        return 2;
    };

    var has_main = false;
    var has_end = false;
    for (it.rules.items) |r| {
        if (r.kind == .main) has_main = true;
        if (r.kind == .end) has_end = true;
    }

    var fatal = false;
    var exited = false;
    it.runRules(.begin) catch |e| switch (e) {
        error.Exit => exited = true,
        else => fatal = true,
    };
    if (!fatal and !exited and (has_main or has_end)) {
        it.runMain(has_main) catch |e| switch (e) {
            error.Exit => exited = true,
            else => fatal = true,
        };
    }
    if (!fatal and (has_end or true)) {
        it.in_end = true;
        it.runRules(.end) catch |e| switch (e) {
            error.Exit => {},
            else => fatal = true,
        };
    }
    it.closeAll();
    if (fatal) return 2;
    return it.exit_code;
}

fn readFile(path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "-") or std.mem.eql(u8, path, "/dev/stdin")) {
        return @import("input.zig").read("-", false);
    }
    return @import("input.zig").read(path, false) orelse {
        return null;
    };
}
