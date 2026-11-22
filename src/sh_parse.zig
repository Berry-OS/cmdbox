// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// sh_parse.zig - POSIX shell lexer and parser producing an AST
const std = @import("std");
const u = @import("util.zig");

const A = u.alloc;

pub const Op = enum { in, out, append, dup_in, dup_out, rdwr, clobber, heredoc, herestr, both_out, both_append };

pub const HereDoc = struct {
    delim: []const u8,
    quoted: bool,
    strip: bool,
    body: []const u8 = "",
};

pub const Redir = struct {
    fd: i32,
    op: Op,
    word: []const u8 = "",
    fdvar: []const u8 = "",
    heredoc: ?*HereDoc = null,
};

pub const Assign = struct { name: []const u8, value: []const u8, append: bool = false };

pub const CaseItem = struct { patterns: [][]const u8, body: ?*Node, term: u8 = 0 }; // term: 0 ";;", 1 ";&" (fall through), 2 ";;&" (test next)

pub const Kind = enum { simple, pipeline, andor, list, subshell, group, if_, while_, until_, for_, case_, funcdef, dbracket, arith, for_arith, select_, time_ };

pub const Node = struct {
    kind: Kind,
    line: u32 = 0,
    assigns: []Assign = &.{},
    words: [][]const u8 = &.{},
    redirs: []Redir = &.{},
    children: []*Node = &.{},
    ops: []u8 = &.{}, // list: ';' or '&' per item; andor: '&' (&&) or '|' (||) per link
    negate: bool = false,
    name: []const u8 = "",
    cases: []CaseItem = &.{},
    has_in: bool = false, // for: explicit word list
    has_else: bool = false,
};

pub const ParseError = error{ Syntax, Incomplete };

const TokKind = enum { eof, newline, word, op, io_number };
const Tok = struct { kind: TokKind, text: []const u8 = "", line: u32 = 0 };

pub var err_msg: []const u8 = "";

pub const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    peeked: ?Tok = null,
    pending: u.Vec(*HereDoc),
    aliases: ?*const fn ([]const u8) ?[]const u8 = null,
    alias_depth: u32 = 0,
    alias_ok: bool = true, // next word is in command position
    eof_hit: bool = false,
    ended_by_eof: bool = false,
    delta: isize = 0, // growth of src caused by alias splicing (to map pos back to the original text)

    pub fn init(src: []const u8) Parser {
        return .{ .src = src, .pending = u.Vec(*HereDoc).init(A) };
    }

    fn fail(self: *Parser, msg: []const u8) ParseError {
        err_msg = msg;
        _ = self;
        return error.Syntax;
    }

    // ---------- lexer ----------
    fn isBlank(c: u8) bool {
        return c == ' ' or c == '\t';
    }

    fn isOpChar(c: u8) bool {
        return c == '|' or c == '&' or c == ';' or c == '<' or c == '>' or c == '(' or c == ')';
    }

    fn skipBlanks(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (isBlank(c)) {
                self.pos += 1;
            } else if (c == '\\' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\n') {
                self.pos += 2;
                self.line += 1;
            } else break;
        }
    }

    fn readHeredocBodies(self: *Parser) ParseError!void {
        for (self.pending.items) |hd| {
            var body = u.Vec(u8).init(A);
            var found = false;
            while (self.pos < self.src.len) {
                const eol = std.mem.indexOfScalarPos(u8, self.src, self.pos, '\n') orelse self.src.len;
                var ln = self.src[self.pos..eol];
                const had_nl = eol < self.src.len;
                self.pos = if (had_nl) eol + 1 else eol;
                self.line += 1;
                var cmp = ln;
                if (hd.strip) {
                    var k: usize = 0;
                    while (k < cmp.len and cmp[k] == '\t') k += 1;
                    cmp = cmp[k..];
                    ln = cmp;
                }
                if (std.mem.eql(u8, cmp, hd.delim)) {
                    found = true;
                    break;
                }
                for (ln) |ch| body.push(ch);
                body.push('\n');
            }
            if (!found) {
                self.eof_hit = true;
                return error.Incomplete;
            }
            hd.body = body.items;
        }
        self.pending.items.len = 0;
    }

    fn scanQuotedDq(self: *Parser, start: usize) ParseError!usize {
        // src[start] is the char after the opening quote; returns index after closing quote
        var i = start;
        while (i < self.src.len) {
            const c = self.src[i];
            if (c == '"') return i + 1;
            if (c == '\\' and i + 1 < self.src.len) {
                i += 2;
                continue;
            }
            if (c == '$' and i + 1 < self.src.len) {
                const n = self.src[i + 1];
                if (n == '(') {
                    i = try self.scanParen(i + 1);
                    continue;
                }
                if (n == '{') {
                    i = try self.scanBrace(i + 1);
                    continue;
                }
            }
            if (c == '`') {
                i = try self.scanBacktick(i + 1);
                continue;
            }
            i += 1;
        }
        self.eof_hit = true;
        return error.Incomplete;
    }

    // src[at] == '(' ; returns index after matching ')'
    fn scanParen(self: *Parser, at: usize) ParseError!usize {
        var depth: usize = 0;
        var i = at;
        while (i < self.src.len) {
            const c = self.src[i];
            switch (c) {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) return i + 1;
                },
                '\'' => {
                    i += 1;
                    while (i < self.src.len and self.src[i] != '\'') i += 1;
                },
                '"' => {
                    i = (try self.scanQuotedDq(i + 1)) - 1;
                },
                '\\' => i += 1,
                '`' => {
                    i = (try self.scanBacktick(i + 1)) - 1;
                },
                else => {},
            }
            i += 1;
        }
        self.eof_hit = true;
        return error.Incomplete;
    }

    fn scanBrace(self: *Parser, at: usize) ParseError!usize {
        var depth: usize = 0;
        var i = at;
        while (i < self.src.len) {
            const c = self.src[i];
            switch (c) {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) return i + 1;
                },
                '\'' => {
                    i += 1;
                    while (i < self.src.len and self.src[i] != '\'') i += 1;
                },
                '"' => {
                    i = (try self.scanQuotedDq(i + 1)) - 1;
                },
                '\\' => i += 1,
                '$' => {
                    if (i + 1 < self.src.len and self.src[i + 1] == '(') {
                        i = (try self.scanParen(i + 1)) - 1;
                    }
                },
                else => {},
            }
            i += 1;
        }
        self.eof_hit = true;
        return error.Incomplete;
    }

    fn scanBacktick(self: *Parser, start: usize) ParseError!usize {
        var i = start;
        while (i < self.src.len) {
            if (self.src[i] == '\\') {
                i += 2;
                continue;
            }
            if (self.src[i] == '`') return i + 1;
            i += 1;
        }
        self.eof_hit = true;
        return error.Incomplete;
    }

    fn scanWord(self: *Parser) ParseError!Tok {
        const start = self.pos;
        const line = self.line;
        var i = self.pos;
        while (i < self.src.len) {
            const c = self.src[i];
            if (c == '(' and i > start and std.mem.indexOfScalar(u8, "?*+@!", self.src[i - 1]) != null) {
                // extglob group: ?(a|b) *(a) +(a) @(a) !(a)
                i = try self.scanParen(i);
                continue;
            }
            if ((c == '<' or c == '>') and i + 1 < self.src.len and self.src[i + 1] == '(') {
                // process substitution <(cmd) >(cmd)
                i = try self.scanParen(i + 1);
                continue;
            }
            if (c == '[' and i > start and words_all_name(self.src[start..i])) {
                // name[subscript]= may contain blanks
                var depth: usize = 0;
                var k = i;
                while (k < self.src.len) : (k += 1) {
                    const d = self.src[k];
                    if (d == '\\') {
                        k += 1;
                    } else if (d == '\'') {
                        k += 1;
                        while (k < self.src.len and self.src[k] != '\'') k += 1;
                    } else if (d == '"') {
                        k += 1;
                        while (k < self.src.len and self.src[k] != '"') {
                            if (self.src[k] == '\\') k += 1;
                            k += 1;
                        }
                    } else if (d == '\n') {
                        break;
                    } else if (d == '[') depth += 1 else if (d == ']') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                if (k < self.src.len and self.src[k] == ']' and k + 1 < self.src.len and (self.src[k + 1] == '=' or (self.src[k + 1] == '+' and k + 2 < self.src.len and self.src[k + 2] == '='))) {
                    i = k + 1;
                    continue;
                }
            }
            if (c == '(' and i > start and self.src[i - 1] == '=' and isAssignWord(self.src[start..i]) != null) {
                // array literal: name=( ... )
                var depth: usize = 0;
                var k = i;
                while (k < self.src.len) : (k += 1) {
                    const d = self.src[k];
                    if (d == '\\') {
                        k += 1;
                    } else if (d == '\'') {
                        k += 1;
                        while (k < self.src.len and self.src[k] != '\'') k += 1;
                    } else if (d == '"') {
                        k = try self.scanQuotedDq(k + 1) - 1;
                    } else if (d == '\n') {
                        self.line += 1;
                    } else if (d == '(') depth += 1 else if (d == ')') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                if (k >= self.src.len) {
                    self.eof_hit = true;
                    return error.Incomplete;
                }
                i = k + 1;
                continue;
            }
            if (isBlank(c) or c == '\n' or isOpChar(c)) break;
            switch (c) {
                '\\' => {
                    if (i + 1 >= self.src.len) {
                        i += 1;
                    } else if (self.src[i + 1] == '\n') {
                        i += 2; // line continuation inside word: keep raw, expansion removes it
                        self.line += 1;
                    } else i += 2;
                },
                '\'' => {
                    i += 1;
                    while (i < self.src.len and self.src[i] != '\'') {
                        if (self.src[i] == '\n') self.line += 1;
                        i += 1;
                    }
                    if (i >= self.src.len) {
                        self.eof_hit = true;
                        return error.Incomplete;
                    }
                    i += 1;
                },
                '"' => {
                    const e = try self.scanQuotedDq(i + 1);
                    for (self.src[i..e]) |ch| if (ch == '\n') {
                        self.line += 1;
                    };
                    i = e;
                },
                '`' => {
                    const e = try self.scanBacktick(i + 1);
                    i = e;
                },
                '$' => {
                    if (i + 1 < self.src.len and self.src[i + 1] == '\'') {
                        // $'...' ANSI-C quoting: backslash escapes the next character
                        var k = i + 2;
                        while (k < self.src.len and self.src[k] != '\'') {
                            if (self.src[k] == '\\') k += 1;
                            k += 1;
                        }
                        if (k >= self.src.len) {
                            self.eof_hit = true;
                            return error.Incomplete;
                        }
                        i = k + 1;
                    } else if (i + 1 < self.src.len and self.src[i + 1] == '(') {
                        const e = try self.scanParen(i + 1);
                        for (self.src[i..e]) |ch| if (ch == '\n') {
                            self.line += 1;
                        };
                        i = e;
                    } else if (i + 1 < self.src.len and self.src[i + 1] == '{') {
                        i = try self.scanBrace(i + 1);
                    } else i += 1;
                },
                else => i += 1,
            }
        }
        self.pos = i;
        return .{ .kind = .word, .text = self.src[start..i], .line = line };
    }

    fn lex(self: *Parser) ParseError!Tok {
        self.skipBlanks();
        if (self.pos >= self.src.len) return .{ .kind = .eof, .line = self.line };
        const c = self.src[self.pos];
        if (c == '#') {
            while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            return self.lex();
        }
        if (c == '\n') {
            self.pos += 1;
            const ln = self.line;
            self.line += 1;
            if (self.pending.items.len > 0) try self.readHeredocBodies();
            return .{ .kind = .newline, .line = ln };
        }
        if ((c == '<' or c == '>') and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '(') {
            return self.scanWord();
        }
        if (isOpChar(c)) {
            const ops = [_][]const u8{ "<<<", "<<-", "&>>", ";;&", "&&", "||", "|&", "&>", ";;", ";&", "<<", ">>", "<&", ">&", "<>", ">|", "|", "&", ";", "<", ">", "(", ")" };
            for (ops) |op| {
                if (std.mem.startsWith(u8, self.src[self.pos..], op)) {
                    self.pos += op.len;
                    return .{ .kind = .op, .text = op, .line = self.line };
                }
            }
        }
        const w = try self.scanWord();
        // IO_NUMBER
        if (self.pos < self.src.len and (self.src[self.pos] == '<' or self.src[self.pos] == '>')) {
            var all = w.text.len > 0;
            for (w.text) |ch| if (ch < '0' or ch > '9') {
                all = false;
            };
            if (!all and w.text.len > 2 and w.text[0] == '{' and w.text[w.text.len - 1] == '}' and validName(w.text[1 .. w.text.len - 1])) all = true;
            if (all) return .{ .kind = .io_number, .text = w.text, .line = w.line };
        }
        return w;
    }

    fn peek(self: *Parser) ParseError!Tok {
        if (self.peeked == null) self.peeked = try self.lex();
        return self.peeked.?;
    }

    fn take(self: *Parser) ParseError!Tok {
        const t = try self.peek();
        self.peeked = null;
        return t;
    }

    fn isOp(t: Tok, op: []const u8) bool {
        return t.kind == .op and std.mem.eql(u8, t.text, op);
    }

    fn isWordEq(t: Tok, w: []const u8) bool {
        return t.kind == .word and std.mem.eql(u8, t.text, w);
    }

    fn isReserved(t: Tok) bool {
        if (t.kind != .word) return false;
        const rw = [_][]const u8{ "if", "then", "else", "elif", "fi", "do", "done", "case", "esac", "while", "until", "for", "in", "{", "}", "!" };
        for (rw) |r| if (std.mem.eql(u8, t.text, r)) return true;
        return false;
    }

    fn skipNewlines(self: *Parser) ParseError!void {
        while ((try self.peek()).kind == .newline) _ = try self.take();
    }

    // ---------- grammar ----------
    /// Parse one complete command (a list ended by newline/EOF). Returns null at EOF.
    pub fn parseComplete(self: *Parser) ParseError!?*Node {
        // skip leading newlines
        while (true) {
            const t = try self.peek();
            if (t.kind == .newline) {
                _ = try self.take();
                continue;
            }
            if (t.kind == .eof) return null;
            break;
        }
        const list = try self.parseList(false);
        const t = try self.peek();
        self.ended_by_eof = t.kind == .eof;
        if (t.kind == .newline) {
            _ = try self.take();
        } else if (t.kind != .eof) {
            return self.fail(if (t.kind == .op and std.mem.eql(u8, t.text, ")")) "Syntax error: \")\" unexpected" else if (t.kind == .op) "Syntax error: unexpected token" else "Syntax error: unexpected word");
        }
        if (self.pending.items.len > 0) {
            self.eof_hit = true;
            return error.Incomplete;
        }
        return list;
    }

    fn atListEnd(self: *Parser) ParseError!bool {
        const t = try self.peek();
        if (t.kind == .eof) return true;
        if (t.kind == .op and (std.mem.eql(u8, t.text, ")") or std.mem.eql(u8, t.text, ";;"))) return true;
        if (t.kind == .word) {
            const stops = [_][]const u8{ "then", "else", "elif", "fi", "do", "done", "esac", "}" };
            for (stops) |s| if (std.mem.eql(u8, t.text, s)) return true;
        }
        return false;
    }

    fn newNode(kind: Kind, line: u32) *Node {
        const n = A.create(Node) catch @panic("oom");
        n.* = .{ .kind = kind, .line = line };
        return n;
    }

    // list: and_or { (;|&|newline) and_or }
    pub fn parseList(self: *Parser, nested: bool) ParseError!*Node {
        var items = u.Vec(*Node).init(A);
        var ops = u.Vec(u8).init(A);
        const line = self.line;
        while (true) {
            if (nested) {
                try self.skipNewlines();
            } else if (items.items.len > 0 and (try self.peek()).kind == .newline) break;
            if (try self.atListEnd()) break;
            const ao = try self.parseAndOr();
            items.push(ao);
            const t = try self.peek();
            if (isOp(t, ";")) {
                _ = try self.take();
                ops.push(';');
            } else if (isOp(t, "&")) {
                _ = try self.take();
                ops.push('&');
            } else if (t.kind == .newline) {
                ops.push(';');
                if (!nested) break; // leave the newline for parseComplete
                _ = try self.take();
                continue;
            } else {
                ops.push(';');
                break;
            }
        }
        const n = newNode(.list, line);
        n.children = items.items;
        n.ops = ops.items;
        return n;
    }

    fn parseAndOr(self: *Parser) ParseError!*Node {
        const first = try self.parsePipeline();
        var t = try self.peek();
        if (!(isOp(t, "&&") or isOp(t, "||"))) return first;
        var kids = u.Vec(*Node).init(A);
        var ops = u.Vec(u8).init(A);
        kids.push(first);
        while (isOp(t, "&&") or isOp(t, "||")) {
            _ = try self.take();
            ops.push(if (t.text[0] == '&') '&' else '|');
            try self.skipNewlines();
            if ((try self.peek()).kind == .eof) {
                self.eof_hit = true;
                return error.Incomplete;
            }
            kids.push(try self.parsePipeline());
            t = try self.peek();
        }
        const n = newNode(.andor, first.line);
        n.children = kids.items;
        n.ops = ops.items;
        return n;
    }

    fn parsePipeline(self: *Parser) ParseError!*Node {
        var negate = false;
        var t = try self.peek();
        while (isWordEq(t, "!")) {
            _ = try self.take();
            negate = !negate;
            t = try self.peek();
        }
        if (isWordEq(t, "time")) {
            _ = try self.take();
            var posix = false;
            var t2 = try self.peek();
            if (t2.kind == .word and std.mem.eql(u8, t2.text, "-p")) {
                _ = try self.take();
                posix = true;
                t2 = try self.peek();
            }
            const tn = newNode(.time_, self.line);
            tn.has_in = posix;
            const inner = if (t2.kind == .eof or t2.kind == .newline or isOp(t2, ";")) newNode(.list, self.line) else try self.parsePipeline();
            tn.children = A.dupe(*Node, &.{inner}) catch @panic("oom");
            return tn;
        }
        const first = try self.parseCommand();
        t = try self.peek();
        if (!isOp(t, "|") and !isOp(t, "|&") and !negate) return first;
        var kids = u.Vec(*Node).init(A);
        kids.push(first);
        while (isOp(t, "|") or isOp(t, "|&")) {
            const both = isOp(t, "|&");
            _ = try self.take();
            if (both) {
                const prev = kids.items[kids.items.len - 1];
                var rl = u.Vec(Redir).init(A);
                for (prev.redirs) |rr| rl.push(rr);
                rl.push(.{ .fd = 2, .op = .dup_out, .word = "1" });
                prev.redirs = rl.items;
            }
            try self.skipNewlines();
            if ((try self.peek()).kind == .eof) {
                self.eof_hit = true;
                return error.Incomplete;
            }
            kids.push(try self.parseCommand());
            t = try self.peek();
        }
        const n = newNode(.pipeline, first.line);
        n.children = kids.items;
        n.negate = negate;
        return n;
    }

    fn parseCommand(self: *Parser) ParseError!*Node {
        const t = try self.peek();
        if (t.kind == .eof) {
            self.eof_hit = true;
            return error.Incomplete;
        }
        if (t.kind == .op) {
            if (isOp(t, "(")) {
                if (self.pos < self.src.len and self.src[self.pos] == '(') {
                    if (try self.tryArithCommand()) |n| return n;
                }
                return self.parseSubshell();
            }
            if (isRedirOp(t.text)) return self.parseSimple();
            return self.fail("Syntax error: unexpected operator");
        }
        if (t.kind == .word) {
            if (isWordEq(t, "if")) return self.parseIf();
            if (isWordEq(t, "while") or isWordEq(t, "until")) return self.parseWhile();
            if (isWordEq(t, "for")) return self.parseFor();
            if (isWordEq(t, "case")) return self.parseCase();
            if (isWordEq(t, "{")) return self.parseGroup();
            if (isWordEq(t, "[[")) return self.parseDbracket();
            if (isWordEq(t, "select")) return self.parseFor();
            if (isWordEq(t, "function")) return self.parseFunctionKw();
            if (isReserved(t) and !isWordEq(t, "!")) {
                return self.fail("Syntax error: unexpected keyword");
            }
        }
        return self.parseSimple();
    }

    fn expectWord(self: *Parser, w: []const u8) ParseError!void {
        try self.skipNewlinesIfKw(w);
        const t = try self.take();
        if (t.kind == .eof) {
            self.eof_hit = true;
            return error.Incomplete;
        }
        if (!isWordEq(t, w)) return self.fail("Syntax error: unexpected token");
    }

    fn skipNewlinesIfKw(self: *Parser, w: []const u8) ParseError!void {
        _ = w;
        try self.skipNewlines();
    }

    fn parseRedirsAfter(self: *Parser, node: *Node) ParseError!void {
        var reds = u.Vec(Redir).init(A);
        while (true) {
            const t = try self.peek();
            if (t.kind == .io_number or (t.kind == .op and isRedirOp(t.text))) {
                try self.parseRedir(&reds);
            } else break;
        }
        node.redirs = reds.items;
    }

    fn isRedirOp(s: []const u8) bool {
        const ro = [_][]const u8{ "<", ">", ">>", "<<", "<<-", "<<<", "<&", ">&", "<>", ">|", "&>", "&>>" };
        for (ro) |r| if (std.mem.eql(u8, s, r)) return true;
        return false;
    }

    fn parseRedir(self: *Parser, reds: *u.Vec(Redir)) ParseError!void {
        var fd: i32 = -1;
        var t = try self.take();
        var fdvar: []const u8 = "";
        if (t.kind == .io_number) {
            if (t.text.len > 2 and t.text[0] == '{') {
                fdvar = t.text[1 .. t.text.len - 1];
            } else fd = std.fmt.parseInt(i32, t.text, 10) catch return self.fail("Syntax error: bad fd");
            t = try self.take();
        }
        const op_text = t.text;
        const w = try self.take();
        if (w.kind != .word) {
            if (w.kind == .eof) {
                self.eof_hit = true;
                return error.Incomplete;
            }
            return self.fail("Syntax error: redirection needs a word");
        }
        var r = Redir{ .fd = fd, .op = .in, .word = w.text, .fdvar = fdvar };
        if (std.mem.eql(u8, op_text, "<")) {
            r.op = .in;
            if (fd < 0) r.fd = 0;
        } else if (std.mem.eql(u8, op_text, ">")) {
            r.op = .out;
            if (fd < 0) r.fd = 1;
        } else if (std.mem.eql(u8, op_text, ">|")) {
            r.op = .clobber;
            if (fd < 0) r.fd = 1;
        } else if (std.mem.eql(u8, op_text, ">>")) {
            r.op = .append;
            if (fd < 0) r.fd = 1;
        } else if (std.mem.eql(u8, op_text, "<&")) {
            r.op = .dup_in;
            if (fd < 0) r.fd = 0;
        } else if (std.mem.eql(u8, op_text, ">&")) {
            r.op = .dup_out;
            if (fd < 0) r.fd = 1;
        } else if (std.mem.eql(u8, op_text, "<>")) {
            r.op = .rdwr;
            if (fd < 0) r.fd = 0;
        } else if (std.mem.eql(u8, op_text, "<<<")) {
            r.op = .herestr;
            if (fd < 0) r.fd = 0;
        } else if (std.mem.eql(u8, op_text, "&>")) {
            r.op = .both_out;
            r.fd = 1;
        } else if (std.mem.eql(u8, op_text, "&>>")) {
            r.op = .both_append;
            r.fd = 1;
        } else {
            // here-document
            r.op = .heredoc;
            if (fd < 0) r.fd = 0;
            const hd = A.create(HereDoc) catch @panic("oom");
            var quoted = false;
            var dl = u.Vec(u8).init(A);
            var k: usize = 0;
            const raw = w.text;
            while (k < raw.len) : (k += 1) {
                const ch = raw[k];
                if (ch == '\'') {
                    quoted = true;
                    k += 1;
                    while (k < raw.len and raw[k] != '\'') : (k += 1) dl.push(raw[k]);
                } else if (ch == '"') {
                    quoted = true;
                    k += 1;
                    while (k < raw.len and raw[k] != '"') : (k += 1) {
                        if (raw[k] == '\\' and k + 1 < raw.len) k += 1;
                        dl.push(raw[k]);
                    }
                } else if (ch == '\\' and k + 1 < raw.len) {
                    quoted = true;
                    k += 1;
                    dl.push(raw[k]);
                } else dl.push(ch);
            }
            hd.* = .{ .delim = dl.items, .quoted = quoted, .strip = std.mem.eql(u8, op_text, "<<-") };
            r.heredoc = hd;
            self.pending.push(hd);
        }
        reds.push(r);
    }

    fn parseSubshell(self: *Parser) ParseError!*Node {
        const line = self.line;
        _ = try self.take(); // (
        const body = try self.parseList(true);
        const t = try self.take();
        if (t.kind == .eof) {
            self.eof_hit = true;
            return error.Incomplete;
        }
        if (!isOp(t, ")")) return self.fail("Syntax error: \")\" expected");
        const n = newNode(.subshell, line);
        n.children = A.dupe(*Node, &.{body}) catch @panic("oom");
        try self.parseRedirsAfter(n);
        return n;
    }

    fn parseGroup(self: *Parser) ParseError!*Node {
        const line = self.line;
        _ = try self.take(); // {
        const body = try self.parseList(true);
        try self.expectWord("}");
        const n = newNode(.group, line);
        n.children = A.dupe(*Node, &.{body}) catch @panic("oom");
        try self.parseRedirsAfter(n);
        return n;
    }

    fn parseIf(self: *Parser) ParseError!*Node {
        const line = self.line;
        _ = try self.take(); // if
        var kids = u.Vec(*Node).init(A);
        kids.push(try self.parseList(true));
        try self.expectWord("then");
        kids.push(try self.parseList(true));
        var has_else = false;
        while (true) {
            try self.skipNewlines();
            const t = try self.peek();
            if (isWordEq(t, "elif")) {
                _ = try self.take();
                kids.push(try self.parseList(true));
                try self.expectWord("then");
                kids.push(try self.parseList(true));
            } else if (isWordEq(t, "else")) {
                _ = try self.take();
                kids.push(try self.parseList(true));
                has_else = true;
                try self.expectWord("fi");
                break;
            } else {
                try self.expectWord("fi");
                break;
            }
        }
        const n = newNode(.if_, line);
        n.children = kids.items;
        n.has_else = has_else;
        try self.parseRedirsAfter(n);
        return n;
    }

    fn parseWhile(self: *Parser) ParseError!*Node {
        const line = self.line;
        const kw = try self.take();
        const cond = try self.parseList(true);
        try self.expectWord("do");
        const body = try self.parseList(true);
        try self.expectWord("done");
        const n = newNode(if (std.mem.eql(u8, kw.text, "until")) .until_ else .while_, line);
        n.children = A.dupe(*Node, &.{ cond, body }) catch @panic("oom");
        try self.parseRedirsAfter(n);
        return n;
    }

    fn validName(s: []const u8) bool {
        if (s.len == 0) return false;
        if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
        for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
        return true;
    }

    fn parseFor(self: *Parser) ParseError!*Node {
        const line = self.line;
        const is_select = std.mem.eql(u8, (try self.peek()).text, "select");
        _ = try self.take(); // for
        {
            // for (( init; cond; step )) ...
            var k = self.pos;
            while (k < self.src.len and (self.src[k] == ' ' or self.src[k] == '\t')) k += 1;
            if (self.peeked == null and k + 1 < self.src.len and self.src[k] == '(' and self.src[k + 1] == '(') {
                const close = self.scanArithClose(k + 2) orelse return self.fail("Syntax error: bad arithmetic for");
                const expr = self.src[k + 2 .. close];
                self.pos = close + 2;
                var parts = u.Vec([]const u8).init(A);
                var depth: usize = 0;
                var st: usize = 0;
                for (expr, 0..) |ch, ix| {
                    if (ch == '(') depth += 1 else if (ch == ')') {
                        if (depth > 0) depth -= 1;
                    } else if (ch == ';' and depth == 0) {
                        parts.push(std.mem.trim(u8, expr[st..ix], " \t\n"));
                        st = ix + 1;
                    }
                }
                parts.push(std.mem.trim(u8, expr[st..], " \t\n"));
                if (parts.items.len != 3) return self.fail("Syntax error: arithmetic for needs three expressions");
                var t0 = try self.peek();
                if (isOp(t0, ";") or t0.kind == .newline) _ = try self.take();
                try self.skipNewlines();
                t0 = try self.peek();
                var body: *Node = undefined;
                if (isWordEq(t0, "do")) {
                    _ = try self.take();
                    body = try self.parseList(true);
                    try self.expectWord("done");
                } else if (isWordEq(t0, "{")) {
                    _ = try self.take();
                    body = try self.parseList(true);
                    try self.expectWord("}");
                } else return self.fail("Syntax error: \"do\" expected");
                const n = newNode(.for_arith, line);
                n.words = parts.items;
                n.children = A.dupe(*Node, &.{body}) catch @panic("oom");
                try self.parseRedirsAfter(n);
                return n;
            }
        }
        const nm = try self.take();
        if (nm.kind != .word or !validName(nm.text)) {
            if (nm.kind == .eof) {
                self.eof_hit = true;
                return error.Incomplete;
            }
            return self.fail("Syntax error: bad for loop variable");
        }
        var words = u.Vec([]const u8).init(A);
        var has_in = false;
        try self.skipNewlines();
        var t = try self.peek();
        if (isWordEq(t, "in")) {
            has_in = true;
            _ = try self.take();
            while (true) {
                t = try self.peek();
                if (t.kind == .word) {
                    words.push(t.text);
                    _ = try self.take();
                } else break;
            }
            t = try self.peek();
            if (isOp(t, ";") or t.kind == .newline) _ = try self.take() else if (t.kind == .eof) {
                self.eof_hit = true;
                return error.Incomplete;
            }
        } else if (isOp(t, ";")) {
            _ = try self.take();
        }
        try self.expectWord("do");
        const body = try self.parseList(true);
        try self.expectWord("done");
        const n = newNode(if (is_select) .select_ else .for_, line);
        n.name = nm.text;
        n.words = words.items;
        n.has_in = has_in;
        n.children = A.dupe(*Node, &.{body}) catch @panic("oom");
        try self.parseRedirsAfter(n);
        return n;
    }

    fn parseCase(self: *Parser) ParseError!*Node {
        const line = self.line;
        _ = try self.take(); // case
        const w = try self.take();
        if (w.kind != .word) {
            if (w.kind == .eof) {
                self.eof_hit = true;
                return error.Incomplete;
            }
            return self.fail("Syntax error: case word expected");
        }
        try self.skipNewlines();
        const inn = try self.take();
        if (inn.kind == .eof) {
            self.eof_hit = true;
            return error.Incomplete;
        }
        if (!isWordEq(inn, "in")) return self.fail("Syntax error: \"in\" expected");
        var items = u.Vec(CaseItem).init(A);
        while (true) {
            try self.skipNewlines();
            var t = try self.peek();
            if (t.kind == .eof) {
                self.eof_hit = true;
                return error.Incomplete;
            }
            if (isWordEq(t, "esac")) {
                _ = try self.take();
                break;
            }
            if (isOp(t, "(")) {
                _ = try self.take();
            }
            var pats = u.Vec([]const u8).init(A);
            while (true) {
                t = try self.take();
                if (t.kind != .word) {
                    if (t.kind == .eof) {
                        self.eof_hit = true;
                        return error.Incomplete;
                    }
                    return self.fail("Syntax error: case pattern expected");
                }
                pats.push(t.text);
                t = try self.take();
                if (isOp(t, "|")) continue;
                if (isOp(t, ")")) break;
                if (t.kind == .eof) {
                    self.eof_hit = true;
                    return error.Incomplete;
                }
                return self.fail("Syntax error: \")\" expected in case");
            }
            const body = try self.parseList(true);
            t = try self.peek();
            var term: u8 = 0;
            if (isOp(t, ";;")) _ = try self.take() else if (isOp(t, ";&")) {
                term = 1;
                _ = try self.take();
            } else if (isOp(t, ";;&")) {
                term = 2;
                _ = try self.take();
            }
            items.push(.{ .patterns = pats.items, .body = if (body.children.len == 0) null else body, .term = term });
        }
        const n = newNode(.case_, line);
        n.words = A.dupe([]const u8, &.{w.text}) catch @panic("oom");
        n.cases = items.items;
        try self.parseRedirsAfter(n);
        return n;
    }

    /// find the "))" that closes an arithmetic command starting at `from` (just after "((")
    fn scanArithClose(self: *Parser, from: usize) ?usize {
        var depth: usize = 0;
        var i = from;
        while (i + 1 < self.src.len) : (i += 1) {
            const ch = self.src[i];
            if (ch == '(') depth += 1 else if (ch == ')') {
                if (depth == 0) return if (self.src[i + 1] == ')') i else null;
                depth -= 1;
            } else if (ch == '\'') {
                i += 1;
                while (i < self.src.len and self.src[i] != '\'') i += 1;
            } else if (ch == '"') {
                i += 1;
                while (i < self.src.len and self.src[i] != '"') {
                    if (self.src[i] == '\\') i += 1;
                    i += 1;
                }
            }
        }
        return null;
    }

    fn tryArithCommand(self: *Parser) ParseError!?*Node {
        // self.peeked holds "(" and src[pos] is the second "("
        const close = self.scanArithClose(self.pos + 1) orelse return null;
        const line = self.line;
        const expr = self.src[self.pos + 1 .. close];
        for (expr) |ch| if (ch == '\n') {
            self.line += 1;
        };
        self.pos = close + 2;
        self.peeked = null;
        const n = newNode(.arith, line);
        n.words = A.dupe([]const u8, &.{expr}) catch @panic("oom");
        try self.parseRedirsAfter(n);
        return n;
    }

    fn isDbDelim(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == ';' or c == '&' or c == '|' or c == ')' or c == '(';
    }

    fn parseDbracket(self: *Parser) ParseError!*Node {
        const line = self.line;
        _ = try self.take(); // [[
        var toks = u.Vec([]const u8).init(A);
        var after_re = false;
        var i = self.pos;
        const src = self.src;
        while (true) {
            while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\n')) {
                if (src[i] == '\n') self.line += 1;
                i += 1;
            }
            if (i >= src.len) {
                self.eof_hit = true;
                self.pos = i;
                return error.Incomplete;
            }
            if (src[i] == '\\' and i + 1 < src.len and src[i + 1] == '\n') {
                i += 2;
                self.line += 1;
                continue;
            }
            if (src[i] == ']' and i + 1 < src.len and src[i + 1] == ']' and (i + 2 >= src.len or isDbDelim(src[i + 2]))) {
                i += 2;
                break;
            }
            if (!after_re and (src[i] == '(' or src[i] == ')')) {
                toks.push(src[i .. i + 1]);
                i += 1;
                continue;
            }
            if (!after_re and ((src[i] == '&' and i + 1 < src.len and src[i + 1] == '&') or (src[i] == '|' and i + 1 < src.len and src[i + 1] == '|'))) {
                toks.push(src[i .. i + 2]);
                i += 2;
                continue;
            }
            // a word
            const st = i;
            var depth: usize = 0;
            while (i < src.len) {
                const ch = src[i];
                if (ch == ' ' or ch == '\t' or ch == '\n') break;
                if (!after_re) {
                    if (ch == '(' and i > st and std.mem.indexOfScalar(u8, "?*+@!", src[i - 1]) != null) {
                        i = try self.scanParen(i);
                        continue;
                    }
                    if (ch == '(' or ch == ')' or ch == '&' or ch == '|' or ch == ';') break;
                    if ((ch == '<' or ch == '>') and i > st) break;
                } else {
                    if (ch == '(') depth += 1 else if (ch == ')') {
                        if (depth == 0) break;
                        depth -= 1;
                    } else if (ch == '&' or ch == ';') break;
                }
                switch (ch) {
                    '\\' => i += 2,
                    '\'' => {
                        i += 1;
                        while (i < src.len and src[i] != '\'') i += 1;
                        i += 1;
                    },
                    '"' => {
                        i = self.scanQuotedDq(i + 1) catch {
                            self.eof_hit = true;
                            return error.Incomplete;
                        };
                    },
                    '$' => {
                        if (i + 1 < src.len and src[i + 1] == '(') {
                            i = try self.scanParen(i + 1);
                        } else if (i + 1 < src.len and src[i + 1] == '{') {
                            i = try self.scanBrace(i + 1);
                        } else i += 1;
                    },
                    '`' => i = try self.scanBacktick(i + 1),
                    else => i += 1,
                }
            }
            if (i == st) {
                // a lone "<" / ">" operator word
                i += 1;
            }
            const tk = src[st..@min(i, src.len)];
            toks.push(tk);
            after_re = std.mem.eql(u8, tk, "=~");
        }
        self.pos = i;
        self.peeked = null;
        const n = newNode(.dbracket, line);
        n.words = toks.items;
        try self.parseRedirsAfter(n);
        return n;
    }

    fn parseFunctionKw(self: *Parser) ParseError!*Node {
        const line = self.line;
        _ = try self.take(); // function
        const nm = try self.take();
        if (nm.kind != .word) return self.fail("Syntax error: function name expected");
        var t = try self.peek();
        if (isOp(t, "(")) {
            _ = try self.take();
            const cl = try self.take();
            if (!isOp(cl, ")")) return self.fail("Syntax error: \")\" expected");
        }
        try self.skipNewlines();
        t = try self.peek();
        const body = try self.parseCommand();
        const fnode = newNode(.funcdef, line);
        fnode.name = nm.text;
        fnode.children = A.dupe(*Node, &.{body}) catch @panic("oom");
        return fnode;
    }

    fn words_all_name(w: []const u8) bool {
        if (w.len == 0 or !(std.ascii.isAlphabetic(w[0]) or w[0] == '_')) return false;
        for (w) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
        return true;
    }

    /// position of the "=" of an assignment word (name=, name+=, name[sub]=, name[sub]+=)
    fn isAssignWord(w: []const u8) ?usize {
        var i: usize = 0;
        if (w.len == 0 or !(std.ascii.isAlphabetic(w[0]) or w[0] == '_')) return null;
        while (i < w.len and (std.ascii.isAlphanumeric(w[i]) or w[i] == '_')) i += 1;
        if (i < w.len and w[i] == '[') {
            var depth: usize = 0;
            while (i < w.len) : (i += 1) {
                if (w[i] == '[') depth += 1 else if (w[i] == ']') {
                    depth -= 1;
                    if (depth == 0) {
                        i += 1;
                        break;
                    }
                }
            } else return null;
        }
        if (i < w.len and w[i] == '+') i += 1;
        if (i < w.len and w[i] == '=') return i;
        return null;
    }

    fn parseSimple(self: *Parser) ParseError!*Node {
        const line = self.line;
        var assigns = u.Vec(Assign).init(A);
        var words = u.Vec([]const u8).init(A);
        var reds = u.Vec(Redir).init(A);
        var first = true;
        while (true) {
            var t = try self.peek();
            if (t.kind == .io_number or (t.kind == .op and isRedirOp(t.text))) {
                try self.parseRedir(&reds);
                continue;
            }
            if (t.kind != .word) break;
            // alias expansion on the first word
            if (words.items.len == 0 and first and self.aliases != null and self.alias_depth < 16) {
                if (self.aliases.?(t.text)) |val| {
                    // splice the alias text into the source in place of the word
                    const word_start = self.pos - t.text.len;
                    var ns = u.Vec(u8).init(A);
                    for (self.src[0..word_start]) |ch| ns.push(ch);
                    for (val) |ch| ns.push(ch);
                    for (self.src[self.pos..]) |ch| ns.push(ch);
                    self.delta += @as(isize, @intCast(val.len)) - @as(isize, @intCast(t.text.len));
                    self.src = ns.items;
                    self.pos = word_start;
                    self.peeked = null;
                    self.alias_depth += 1;
                    t = try self.peek();
                    if (t.kind != .word) {
                        // alias expanded to operators/redirections: restart classification
                        if (t.kind == .io_number or (t.kind == .op and isRedirOp(t.text))) {
                            try self.parseRedir(&reds);
                            continue;
                        }
                        break;
                    }
                    if (isReserved(t) and words.items.len == 0 and assigns.items.len == 0 and reds.items.len == 0) {
                        self.alias_depth = 0;
                        return self.parseCommand();
                    }
                    self.alias_depth += 0;
                }
            }
            first = false;
            _ = try self.take();
            if (words.items.len == 0) {
                if (isAssignWord(t.text)) |eq| {
                    const app = eq > 0 and t.text[eq - 1] == '+';
                    assigns.push(.{ .name = t.text[0 .. if (app) eq - 1 else eq], .value = t.text[eq + 1 ..], .append = app });
                    first = true;
                    continue;
                }
            }
            // function definition: name ( )
            if (words.items.len == 0 and assigns.items.len == 0 and reds.items.len == 0 and validName(t.text)) {
                const nx = try self.peek();
                if (isOp(nx, "(")) {
                    _ = try self.take();
                    const cl = try self.take();
                    if (!isOp(cl, ")")) return self.fail("Syntax error: \")\" expected");
                    try self.skipNewlines();
                    const body = try self.parseCommand();
                    const fnode = newNode(.funcdef, line);
                    fnode.name = t.text;
                    fnode.children = A.dupe(*Node, &.{body}) catch @panic("oom");
                    self.alias_depth = 0;
                    return fnode;
                }
            }
            words.push(t.text);
        }
        self.alias_depth = 0;
        if (words.items.len == 0 and assigns.items.len == 0 and reds.items.len == 0) {
            const t = try self.peek();
            if (t.kind == .eof) {
                self.eof_hit = true;
                return error.Incomplete;
            }
            return self.fail("Syntax error: unexpected token");
        }
        const n = newNode(.simple, line);
        n.assigns = assigns.items;
        n.words = words.items;
        n.redirs = reds.items;
        return n;
    }
};
