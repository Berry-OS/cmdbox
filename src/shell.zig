// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
// shell.zig - minish: a POSIX-ish shell for cmdbox
// supports: | ; && || & < > >> 2>&1 quotes ' " $VAR ${VAR} $? $() `` $(( ))
//           glob * ?  for/while/until/if/elif/else  break/continue
//           builtins: cd pwd echo exit export wait read break continue shift :
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");

const out = u.out;
const outf = u.outf;
const errf = u.errf;

const Function = struct { name: []const u8, body: []const u8 };
var functions: [128]Function = undefined;
var function_count: usize = 0;
var function_depth: usize = 0;
var source_depth: usize = 0;
var returning = false;
fn functionBody(name: []const u8) ?[]const u8 {
    for (functions[0..function_count]) |function| if (std.mem.eql(u8, function.name, name)) return function.body;
    return null;
}
const Definition = struct { name: []const u8, body: []const u8, end: usize };
fn definitionAt(text: []const u8, start: usize) ?Definition {
    var i = start;
    if (i == text.len or !std.ascii.isAlphabetic(text[i]) and text[i] != '_') return null;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) i += 1;
    const name = text[start..i];
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    if (i == text.len or text[i] != '(') return null;
    i += 1;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    if (i == text.len or text[i] != ')') return null;
    i += 1;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    if (i == text.len or text[i] != '{') return null;
    i += 1;
    const body = i;
    var depth: usize = 1;
    var quote: u8 = 0;
    while (i < text.len) : (i += 1) {
        const byte = text[i];
        if (byte == '\\' and quote != '\'') {
            i += 1;
            continue;
        }
        if (quote != 0) {
            if (byte == quote) quote = 0;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        if (byte == '{') depth += 1;
        if (byte == '}') {
            depth -= 1;
            if (depth == 0) return .{ .name = name, .body = text[body..i], .end = i + 1 };
        }
    }
    return null;
}
fn defineFunction(definition: Definition) void {
    const body = u.alloc.dupe(u8, definition.body) catch return;
    for (functions[0..function_count]) |*function| if (std.mem.eql(u8, function.name, definition.name)) {
        function.body = body;
        return;
    };
    if (function_count == functions.len) return;
    functions[function_count] = .{ .name = u.alloc.dupe(u8, definition.name) catch return, .body = body };
    function_count += 1;
}
fn callFunction(body: []const u8, argv: []const []const u8) u8 {
    if (function_depth >= 128) return 2;
    const old_count = pos_argc;
    const old_zero = u.getEnv("0") orelse "sh";
    var saved = u.Vec([]const u8).init(u.alloc);
    for (0..old_count) |index| {
        var buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "{d}", .{index + 1}) catch return 1;
        saved.push(u.getEnv(name) orelse "");
    }
    setPositional(old_zero, argv[1..]);
    function_depth += 1;
    const code = execTop(body);
    function_depth -= 1;
    returning = false;
    setPositional(old_zero, saved.items);
    return code;
}

var last_status: u8 = 0;
var break_count: u32 = 0;
var continue_count: u32 = 0;
var pos_argc: usize = 0;
var in_child = false;

pub fn runApplet(args: []const []const u8) u8 {
    // ignore SIGINT in the shell; children restore SIG_DFL before exec
    var ign = linux.Sigaction{
        .handler = .{ .handler = @ptrFromInt(1) }, // SIG_IGN
        .mask = @splat(0),
        .flags = 0,
    };
    _ = linux.sigaction(.INT, &ign, null);
    _ = linux.sigaction(.QUIT, &ign, null);

    if (args.len >= 2 and std.mem.eql(u8, args[0], "-c")) {
        setPositional(if (args.len > 2) args[2] else "sh", if (args.len > 3) args[3..] else &.{});
        return runLine(args[1]);
    }
    if (args.len >= 1) {
        return runScript(args[0], args[1..]);
    }
    return runSession();
}

fn isTty(fd: i32) bool {
    var t: [64]u8 = undefined;
    return u.ok(linux.ioctl(fd, 0x5401, @intFromPtr(&t))); // TCGETS
}

// ---------------- input source ----------------
// one physical line at a time; shared by the script reader, stdin reader
// and interactive reader so `read`/compound-line assembly stay in sync
const Source = struct {
    kind: enum { file, stdin, tty },
    lr: u.LineReader = undefined, // file/stdin mode
    buf: [8192]u8 = undefined,

    fn initFile(f: u.File) Source {
        return .{ .kind = .file, .lr = u.LineReader.init(f) };
    }
    fn initStdin() Source {
        return .{ .kind = .stdin, .lr = u.LineReader.init(u.File{ .fd = 0 }) };
    }
    fn next(self: *Source) ?[]const u8 {
        switch (self.kind) {
            .file, .stdin => return self.lr.next(),
            .tty => {
                var n: usize = 0;
                while (n < self.buf.len) {
                    var c: [1]u8 = undefined;
                    const r = linux.read(0, &c, 1);
                    if (u.errno(r) != .SUCCESS or r == 0) {
                        if (n == 0) return null;
                        break;
                    }
                    if (c[0] == '\n') break;
                    self.buf[n] = c[0];
                    n += 1;
                }
                return self.buf[0..n];
            },
        }
    }
};

var cur_src: ?*Source = null;

fn runSession() u8 {
    var src: Source = if (isTty(0)) .{ .kind = .tty } else Source.initStdin();
    cur_src = &src;
    defer cur_src = null;
    while (src.next()) |line| {
        var lbuf: [8192]u8 = undefined;
        if (line.len >= lbuf.len) continue;
        @memcpy(lbuf[0..line.len], line);
        last_status = runLine(lbuf[0..line.len]);
    }
    return last_status;
}

fn setPositional(name: []const u8, args: []const []const u8) void {
    for (args.len..@max(pos_argc, args.len)) |index| {
        var buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{d}", .{index + 1}) catch break;
        u.unsetVar(key);
    }
    u.setVar("0", name);
    pos_argc = args.len;
    for (args, 0..) |value, index| {
        var buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{d}", .{index + 1}) catch return;
        u.setVar(key, value);
    }
}

fn runScript(path: []const u8, args: []const []const u8) u8 {
    var f = u.File.open(path, .{ .ACCMODE = .RDONLY }, 0) orelse {
        errf("sh: {s}: {s}\n", .{ path, "No such file or directory" });
        return 127;
    };
    defer f.close();
    setPositional(path, args);
    var src = Source.initFile(f);
    cur_src = &src;
    defer cur_src = null;
    while (src.next()) |line| {
        var lbuf: [16384]u8 = undefined;
        if (line.len >= lbuf.len) continue;
        @memcpy(lbuf[0..line.len], line);
        last_status = runLine(lbuf[0..line.len]);
    }
    return last_status;
}

// ---------------- keyword scanner ----------------
// quote-aware token scanner that also tracks shell-construct nesting.
// stack: 'L' = for/while/until (closed by done), 'C' = if (closed by fi)
const KwScan = struct {
    text: []const u8,
    pos: usize = 0,
    quote: u8 = 0,
    stack: [16]u8 = @splat(0),
    cmd_pos: bool = true,
    // set for the most recent token
    tok_start: usize = 0,
    tok_end: usize = 0,
    was_cmd_pos: bool = false,
    was_op: bool = false,

    fn depth(self: *const KwScan) usize {
        var d: usize = 0;
        for (self.stack) |c| {
            if (c != 0) d += 1;
        }
        return d;
    }

    fn next(self: *KwScan) ?[]const u8 {
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (self.quote != 0) {
                if (c == '\\' and self.pos + 1 < self.text.len) {
                    self.pos += 2;
                    continue;
                }
                if (c == self.quote) self.quote = 0;
                self.pos += 1;
                continue;
            }
            if (c == '\'' or c == '"') {
                self.quote = c;
                self.pos += 1;
                continue;
            }
            if (c == ' ' or c == '\t') {
                self.pos += 1;
                continue;
            }
            // operators / delimiters
            if (c == '\n' or c == ';' or c == '&' or c == '|' or c == '<' or c == '>' or c == '(' or c == ')') {
                self.tok_start = self.pos;
                self.pos += 1;
                if (c == '&' or c == '|') {
                    if (self.pos < self.text.len and self.text[self.pos] == c) self.pos += 1;
                }
                self.tok_end = self.pos;
                self.was_cmd_pos = self.cmd_pos;
                self.was_op = true;
                self.cmd_pos = true;
                if (c == '(' or c == ')') {
                    self.cmd_pos = c == ')';
                    self.was_op = false;
                }
                if (c == '<' or c == '>') {
                    self.cmd_pos = false;
                    self.was_op = false;
                }
                // newlines behave like ';' as separators
                if (c == '\n') return ";";
                return self.text[self.tok_start..self.tok_end];
            }
            // word
            self.tok_start = self.pos;
            while (self.pos < self.text.len) {
                const d = self.text[self.pos];
                if (self.quote != 0) {
                    if (d == self.quote) {
                        self.quote = 0;
                        self.pos += 1;
                        continue;
                    }
                    self.pos += 1;
                    continue;
                }
                if (d == '\'' or d == '"') {
                    self.quote = d;
                    self.pos += 1;
                    continue;
                }
                if (d == '\\' and self.pos + 1 < self.text.len) {
                    self.pos += 2;
                    continue;
                }
                if (d == ' ' or d == '\t' or d == '\n' or d == ';' or d == '&' or d == '|' or
                    d == '<' or d == '>' or d == '(' or d == ')') break;
                self.pos += 1;
            }
            self.tok_end = self.pos;
            self.was_cmd_pos = self.cmd_pos;
            self.was_op = false;
            self.cmd_pos = false;
            const tok = self.text[self.tok_start..self.tok_end];
            if (self.was_cmd_pos) {
                if (std.mem.eql(u8, tok, "{")) {
                    self.push('B');
                    self.cmd_pos = true;
                } else if (std.mem.eql(u8, tok, "}")) {
                    self.pop('B');
                } else if (std.mem.eql(u8, tok, "case")) {
                    self.push('K');
                } else if (std.mem.eql(u8, tok, "esac")) {
                    self.pop('K');
                } else if (eqAny(tok, &.{ "for", "while", "until" })) {
                    self.push('L');
                } else if (eqAny(tok, &.{"if"})) {
                    self.push('C');
                } else if (eqAny(tok, &.{"done"})) {
                    self.pop('L');
                } else if (eqAny(tok, &.{"fi"})) {
                    self.pop('C');
                } else if (eqAny(tok, &.{ "do", "then", "else", "elif" })) {
                    self.cmd_pos = true;
                }
            }
            return tok;
        }
        return null;
    }

    fn push(self: *KwScan, c: u8) void {
        for (&self.stack) |*s| {
            if (s.* == 0) {
                s.* = c;
                return;
            }
        }
    }
    fn pop(self: *KwScan, c: u8) void {
        var i = self.stack.len;
        while (i > 0) {
            i -= 1;
            if (self.stack[i] == c) {
                self.stack[i] = 0;
                return;
            }
            if (self.stack[i] != 0) return; // mismatch: ignore
        }
    }
};

fn eqAny(s: []const u8, list: []const []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, s, x)) return true;
    }
    return false;
}

// how much of `text` is an unfinished compound construct?
fn kwDepth(text: []const u8) usize {
    var scan = KwScan{ .text = text };
    while (scan.next()) |_| {}
    return scan.depth();
}

fn isOp(tok: []const u8) bool {
    return tok.len <= 2 and (std.mem.indexOfScalar(u8, ";&|<>()", tok[0]) != null);
}

// ---------------- compound execution ----------------
fn runLine(line: []const u8) u8 {
    if (cur_src == null) return execTop(line);
    // assemble multi-line compound constructs
    var acc = u.Vec(u8).init(u.alloc);
    for (line) |c| acc.push(c);
    while (kwDepth(acc.items) > 0) {
        const src = cur_src.?;
        if (src.kind == .tty) {
            out("> ");
            u.flush();
        }
        const nl = src.next() orelse break;
        acc.push('\n');
        for (nl) |c| acc.push(c);
    }
    return execTop(acc.items);
}

fn execTop(text0: []const u8) u8 {
    const text = std.mem.trim(u8, text0, " \t\n");
    if (text.len == 0) return 0;
    // execList handles compound keywords (as atomic statements) and
    // everything that may follow them (e.g. `if ...; fi; echo x`)
    return execList(text);
}

// find the matching "done" from scan's current position; returns its tok_start
fn findDone(scan: *KwScan) ?usize {
    var cnt: usize = 0;
    while (scan.next()) |t| {
        if (!scan.was_op) {
            if (scan.was_cmd_pos and eqAny(t, &.{ "for", "while", "until" })) {
                cnt += 1;
            } else if (std.mem.eql(u8, t, "done")) {
                if (cnt == 0) return scan.tok_start;
                cnt -= 1;
            }
        }
    }
    return null;
}

fn skipToDo(scan: *KwScan) bool {
    while (scan.next()) |t| {
        if (scan.was_op) continue;
        if (scan.depth() == 0 and std.mem.eql(u8, t, "do")) return true;
    }
    return false;
}

// optional "< file" redirect after the closing keyword
fn tailRedirect(scan: *KwScan) ?[]const u8 {
    var t = scan.next() orelse return null;
    if (std.mem.eql(u8, t, ";") or std.mem.eql(u8, t, "\n")) t = scan.next() orelse return null;
    if (!std.mem.eql(u8, t, "<")) return null;
    const f = scan.next() orelse return null;
    if (scan.was_op) return null;
    return f;
}

fn applyStdinFile(f: []const u8) i32 {
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, u.zstr(f), .{ .ACCMODE = .RDONLY }, 0) catch {
        errf("sh: {s}: cannot open\n", .{f});
        return -1;
    };
    const saved = linux.dup(0);
    _ = linux.dup2(fd, 0);
    _ = linux.close(fd);
    return @intCast(saved);
}

fn restoreStdin(saved: i32) void {
    if (saved >= 0) {
        _ = linux.dup2(saved, 0);
        _ = linux.close(saved);
    }
}

fn execFor(text: []const u8, kw_end: usize) u8 {
    var scan = KwScan{ .text = text, .pos = kw_end };
    const namet = scan.next() orelse return 1;
    if (scan.was_op or namet.len == 0) return 1;
    var words = u.Vec([]const u8).init(u.alloc);
    var t = scan.next();
    if (t != null and std.mem.eql(u8, t.?, "in")) {
        // raw word list between "in" and "do" — keep it as text so quotes,
        // variables and $( ) substitutions survive tokenization
        const in_start = scan.tok_end;
        var do_pos: ?usize = null;
        while (scan.next()) |tk| {
            if (!scan.was_op and std.mem.eql(u8, tk, "do") and scan.depth() == 0) {
                do_pos = scan.tok_start;
                break;
            }
            if (scan.was_op and std.mem.eql(u8, tk, "do")) {
                do_pos = scan.tok_start;
                break;
            }
        }
        const dpos = do_pos orelse return 0;
        var list_raw = text[in_start..dpos];
        // strip the trailing separator(s)
        while (list_raw.len > 0 and (list_raw[list_raw.len - 1] == ';' or list_raw[list_raw.len - 1] == '\n' or
            list_raw[list_raw.len - 1] == ' ' or list_raw[list_raw.len - 1] == '\t')) list_raw = list_raw[0 .. list_raw.len - 1];
        if (parseCmd(list_raw)) |c| {
            for (c.argv) |w| words.push(w);
        }
        t = "do";
    } else {
        var i: usize = 1;
        while (i <= pos_argc) : (i += 1) {
            var nb: [8]u8 = undefined;
            const name = std.fmt.bufPrint(&nb, "{d}", .{i}) catch break;
            if (u.getEnv(name)) |v| words.push(v);
        }
    }
    // find `do ... done`
    if (t == null or !std.mem.eql(u8, t.?, "do")) {
        if (!skipToDo(&scan)) return 0;
    }
    const body_start = scan.tok_end;
    const done_pos = findDone(&scan) orelse return 1;
    const body = std.mem.trim(u8, text[body_start..done_pos], " \t\n;");
    if (body.len == 0) return 0;

    // optional "done < file"
    var saved: i32 = -1;
    if (tailRedirect(&scan)) |f| {
        saved = applyStdinFile(f);
        if (saved < 0) return 1;
    }
    defer restoreStdin(saved);

    var code: u8 = 0;
    for (words.items) |w| {
        if (continue_count > 0 or break_count > 0) break;
        u.setVar(namet, w);
        code = execTop(body);
        if (continue_count > 0) {
            continue_count -= 1;
            if (continue_count > 0) break;
            continue;
        }
        if (break_count > 0) {
            break_count -= 1;
            break;
        }
    }
    return code;
}

fn execWhile(text: []const u8, kw_end: usize, until: bool) u8 {
    var scan = KwScan{ .text = text, .pos = kw_end };
    if (!skipToDo(&scan)) return 1;
    const cond = std.mem.trim(u8, text[kw_end..scan.tok_start], " \t\n;");
    const body_start = scan.tok_end;
    const done_pos = findDone(&scan) orelse return 1;
    const body = std.mem.trim(u8, text[body_start..done_pos], " \t\n;");
    if (cond.len == 0 or body.len == 0) return 0;

    var saved: i32 = -1;
    if (tailRedirect(&scan)) |f| {
        saved = applyStdinFile(f);
        if (saved < 0) return 1;
    }
    defer restoreStdin(saved);

    var code: u8 = 0;
    var body_code: u8 = 0;
    var iter: usize = 0;
    while (iter < 10_000_000) : (iter += 1) {
        code = execTop(cond);
        const go = if (until) code != 0 else code == 0;
        if (!go) break;
        if (break_count > 0) {
            break_count -= 1;
            break;
        }
        if (continue_count > 0) {
            continue_count -= 1;
            if (continue_count > 0) break;
            continue;
        }
        body_code = execTop(body);
        code = body_code;
        if (break_count > 0) {
            break_count -= 1;
            break;
        }
        if (continue_count > 0) {
            continue_count -= 1;
            if (continue_count > 0) break;
            continue;
        }
    }
    return body_code;
}

const IfPart = struct {
    cond: []const u8 = "",
    body: []const u8 = "",
};

fn execIf(text: []const u8, kw_end: usize) u8 {
    var parts = u.Vec(IfPart).init(u.alloc);
    var scan = KwScan{ .text = text, .pos = kw_end };
    // first cond: until `then` at depth 0
    var cond_start: usize = kw_end;
    var then_end: usize = 0;
    var found_then = false;
    while (scan.next()) |t| {
        if (!scan.was_op and scan.depth() == 0 and std.mem.eql(u8, t, "then")) {
            then_end = scan.tok_end;
            found_then = true;
            break;
        }
    }
    if (!found_then) return 1;
    var part = IfPart{ .cond = std.mem.trim(u8, text[cond_start..scan.tok_start], " \t\n;") };
    // body: until elif/else/fi at depth 0
    var body_start = then_end;
    while (scan.next()) |t| {
        if (scan.depth() == 0 and (std.mem.eql(u8, t, "elif") or std.mem.eql(u8, t, "else") or std.mem.eql(u8, t, "fi"))) {
            part.body = std.mem.trim(u8, text[body_start..scan.tok_start], " \t\n;");
            parts.push(part);
            if (std.mem.eql(u8, t, "fi")) break;
            if (std.mem.eql(u8, t, "else")) {
                // final body: until fi
                const ebody_start = scan.tok_end;
                var ebody: []const u8 = "";
                while (scan.next()) |t2| {
                    if (scan.depth() == 0 and std.mem.eql(u8, t2, "fi")) {
                        ebody = std.mem.trim(u8, text[ebody_start..scan.tok_start], " \t\n;");
                        break;
                    }
                }
                parts.push(.{ .cond = "", .body = ebody });
                break;
            }
            // elif: new cond until then
            cond_start = scan.tok_end;
            found_then = false;
            while (scan.next()) |t2| {
                if (!scan.was_op and scan.depth() == 0 and std.mem.eql(u8, t2, "then")) {
                    then_end = scan.tok_end;
                    found_then = true;
                    break;
                }
            }
            if (!found_then) return 1;
            part = .{ .cond = std.mem.trim(u8, text[cond_start..scan.tok_start], " \t\n;") };
            body_start = then_end;
        }
    }
    // execute: first matching cond, else the else-branch; no match -> 0
    var code: u8 = 0;
    var taken = false;
    for (parts.items) |p| {
        if (p.cond.len == 0) {
            code = execTop(p.body);
            taken = true;
            break;
        }
        code = execTop(p.cond);
        if (code == 0) {
            // break/continue inside an if-body propagate to the enclosing loop
            code = execTop(p.body);
            taken = true;
            break;
        }
    }
    return if (taken) code else 0;
}

fn casePattern(text: []const u8) []const u8 {
    var result = u.Vec(u8).init(u.alloc);
    var quote: u8 = 0;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (quote != 0 and byte == quote) {
            quote = 0;
            index += 1;
            continue;
        }
        if (quote == 0 and (byte == '\'' or byte == '"')) {
            quote = byte;
            index += 1;
            continue;
        }
        if (byte == '\\' and quote != '\'' and index + 1 < text.len) {
            result.push('\\');
            index += 1;
            result.push(text[index]);
            index += 1;
            continue;
        }
        if (byte == '$' and quote != '\'') {
            const value = expandVar(text, &index);
            for (value) |ch| {
                if (quote != 0 and std.mem.indexOfScalar(u8, "*?[]\\", ch) != null) result.push('\\');
                result.push(ch);
            }
            continue;
        }
        if (quote != 0 and std.mem.indexOfScalar(u8, "*?[]\\", byte) != null) result.push('\\');
        result.push(byte);
        index += 1;
    }
    return result.items;
}
fn caseMatches(patterns: []const u8, subject: []const u8) bool {
    var start: usize = 0;
    var quote: u8 = 0;
    var index: usize = 0;
    while (index <= patterns.len) : (index += 1) {
        if (index == patterns.len or quote == 0 and patterns[index] == '|') {
            if (u.matchPat(casePattern(std.mem.trim(u8, patterns[start..index], " \t\n")), subject)) return true;
            start = index + 1;
            continue;
        }
        const byte = patterns[index];
        if (byte == '\\' and quote != '\'') {
            index += 1;
            continue;
        }
        if (quote != 0) {
            if (byte == quote) quote = 0;
        } else if (byte == '\'' or byte == '"') quote = byte;
    }
    return false;
}
fn execCase(text: []const u8, keyword_end: usize) u8 {
    var scan = KwScan{ .text = text, .pos = keyword_end };
    var subject_end: ?usize = null;
    while (scan.next()) |token| if (std.mem.eql(u8, token, "in")) {
        subject_end = scan.tok_start;
        break;
    };
    const subject = redirectWord(std.mem.trim(u8, text[keyword_end .. subject_end orelse return 2], " \t\n"));
    var pos = scan.pos;
    while (pos < text.len) {
        while (pos < text.len and (std.ascii.isWhitespace(text[pos]) or text[pos] == ';')) pos += 1;
        if (std.mem.startsWith(u8, text[pos..], "esac")) return 0;
        if (pos < text.len and text[pos] == '(') pos += 1;
        const pattern_start = pos;
        var quote: u8 = 0;
        var bracket = false;
        while (pos < text.len) : (pos += 1) {
            const byte = text[pos];
            if (byte == '\\' and quote != '\'' and pos + 1 < text.len) {
                pos += 1;
                continue;
            }
            if (quote != 0) {
                if (byte == quote) quote = 0;
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quote = byte;
                continue;
            }
            if (byte == '[') bracket = true;
            if (byte == ']') bracket = false;
            if (byte == ')' and !bracket) break;
        }
        if (pos == text.len) return 2;
        const patterns = text[pattern_start..pos];
        pos += 1;
        const body_start = pos;
        var body_end: ?usize = null;
        var next_clause: ?usize = null;
        var nested: usize = 0;
        scan = KwScan{ .text = text, .pos = pos };
        while (scan.next()) |token| {
            if (scan.was_cmd_pos and std.mem.eql(u8, token, "case")) nested += 1 else if (std.mem.eql(u8, token, "esac")) {
                if (nested == 0) {
                    body_end = scan.tok_start;
                    break;
                }
                nested -= 1;
            } else if (nested == 0 and scan.depth() == 0 and std.mem.eql(u8, token, ";") and scan.pos < text.len and text[scan.pos] == ';') {
                body_end = scan.tok_start;
                next_clause = scan.pos + 1;
                break;
            }
        }
        if (caseMatches(patterns, subject)) return execTop(text[body_start .. body_end orelse return 2]);
        pos = next_clause orelse return 0;
    }
    return 0;
}

const Sep = enum { seq, and_then, or_else };

// ---------------- top-level statement list ----------------
// compound constructs (for/while/until/if ... done/fi) are treated as atomic
// statements so their bodies may contain ';', '&&', '|' etc.
const StmtInfo = struct {
    end: usize, // index after the statement (and its separator)
    bg: bool = false,
    sep: Sep = .seq,
};

const CompKind = enum { for_, while_, until_, if_, case_ };
const Compound = struct {
    kind: CompKind,
    kw_end: usize, // end of the leading keyword
    end: usize, // index after the whole construct and its separator
    sep: Sep = .seq,
};

fn compoundAt(text: []const u8, pos: usize) ?Compound {
    var scan = KwScan{ .text = text, .pos = pos };
    const t = scan.next() orelse return null;
    if (scan.was_op or !scan.was_cmd_pos) return null;
    const kind: CompKind = if (std.mem.eql(u8, t, "for")) .for_ else if (std.mem.eql(u8, t, "while"))
        .while_
    else if (std.mem.eql(u8, t, "until")) .until_ else if (std.mem.eql(u8, t, "if"))
        .if_
    else if (std.mem.eql(u8, t, "case")) .case_ else return null;
    const kw_end = scan.tok_end;

    // find matching closer
    var end: usize = 0;
    var found = false;
    if (kind == .case_) {
        var nested: usize = 0;
        while (scan.next()) |tk| {
            if (scan.was_cmd_pos and std.mem.eql(u8, tk, "case")) nested += 1 else if (std.mem.eql(u8, tk, "esac")) {
                if (nested == 0) {
                    end = scan.tok_end;
                    found = true;
                    break;
                }
                nested -= 1;
            }
        }
    } else if (kind == .if_) {
        var n: usize = 0;
        while (scan.next()) |tk| {
            if (scan.was_op) continue;
            if (scan.was_cmd_pos and std.mem.eql(u8, tk, "if")) {
                n += 1;
            } else if (std.mem.eql(u8, tk, "fi")) {
                if (n == 0) {
                    end = scan.tok_end;
                    found = true;
                    break;
                }
                n -= 1;
            }
        }
    } else {
        var cnt: usize = 0;
        while (scan.next()) |tk| {
            if (scan.was_op) continue;
            if (scan.was_cmd_pos and eqAny(tk, &.{ "for", "while", "until" })) {
                cnt += 1;
            } else if (std.mem.eql(u8, tk, "done")) {
                if (cnt == 0) {
                    end = scan.tok_end;
                    found = true;
                    break;
                }
                cnt -= 1;
            }
        }
    }
    if (!found) return null;

    // trailer: optional "< file", then separator
    var sep: Sep = .seq;
    var t2 = scan.next();
    if (t2 != null and std.mem.eql(u8, t2.?, "<")) {
        _ = scan.next(); // filename
        t2 = scan.next();
    }
    if (t2) |tk| {
        if (std.mem.eql(u8, tk, "&&")) {
            sep = .and_then;
        } else if (std.mem.eql(u8, tk, "||")) {
            sep = .or_else;
        }
        // "&" (background) and ";" both behave as plain sequence here
    }
    return .{ .kind = kind, .kw_end = kw_end, .end = scan.pos, .sep = sep };
}

fn simpleStmt(text: []const u8, pos0: usize) StmtInfo {
    var pos = pos0;
    var depth: usize = 0;
    var quote: u8 = 0;
    const start = pos;
    while (pos < text.len) : (pos += 1) {
        const c = text[pos];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            '&' => {
                if (depth > 0) continue;
                if (pos + 1 < text.len and text[pos + 1] == '&')
                    return .{ .end = pos + 2, .sep = .and_then };
                // "&" right after ">" is an fd dup (2>&1), not background
                if (pos > start and text[pos - 1] == '>') continue;
                return .{ .end = pos + 1, .bg = true, .sep = .seq };
            },
            '|' => {
                if (depth > 0) continue;
                if (pos + 1 < text.len and text[pos + 1] == '|')
                    return .{ .end = pos + 2, .sep = .or_else };
            },
            ';', '\n' => {
                if (depth == 0) return .{ .end = pos, .sep = .seq };
            },
            else => {},
        }
    }
    return .{ .end = text.len, .sep = .seq };
}

fn execList(text: []const u8) u8 {
    var pos: usize = 0;
    var last: u8 = 0;
    var pending: Sep = .seq;
    list_depth += 1;
    defer list_depth -= 1;
    while (pos < text.len) {
        // skip separators / whitespace
        while (pos < text.len and (text[pos] == ';' or text[pos] == '\n' or text[pos] == ' ' or text[pos] == '\t')) pos += 1;
        if (pos >= text.len) break;
        var run = true;
        if (pending == .and_then) run = last == 0;
        if (pending == .or_else) run = last != 0;
        pending = .seq;
        if (definitionAt(text, pos)) |definition| {
            if (run) {
                defineFunction(definition);
                last = 0;
                last_status = 0;
            }
            pos = definition.end;
            continue;
        }
        if (compoundAt(text, pos)) |comp| {
            if (run) {
                last = switch (comp.kind) {
                    .for_ => execFor(text, comp.kw_end),
                    .while_ => execWhile(text, comp.kw_end, false),
                    .until_ => execWhile(text, comp.kw_end, true),
                    .if_ => execIf(text, comp.kw_end),
                    .case_ => execCase(text, comp.kw_end),
                };
            }
            pos = comp.end;
            pending = comp.sep;
        } else {
            const st = simpleStmt(text, pos);
            const seg = std.mem.trim(u8, text[pos..st.end], " \t\n");
            if (run and seg.len > 0) {
                last = runJob(seg, st.bg);
                if (st.bg) {
                    last_background_pid = last_pid;
                    bg_count += 1;
                    if (cur_src != null and cur_src.?.kind == .tty) errf("[{d}] {d}\n", .{ bg_count, last_pid });
                }
            }
            pos = st.end;
            pending = st.sep;
        }
        last_status = last;
        reapBg();
        if (returning or break_count > 0 or continue_count > 0) break;
    }
    // only the outermost list clears pending loop-control signals
    if (list_depth <= 1) {
        break_count = 0;
        continue_count = 0;
    }
    last_status = last;
    return last;
}

var list_depth: usize = 0;

var bg_count: u32 = 0;
var last_pid: i32 = 0;
var last_background_pid: i32 = 0;
const Completed = struct { pid: i32, status: u8 };
var completed = u.Vec(Completed).init(u.alloc);

const Redirect = struct {
    fd: i32,
    kind: enum { input, output, append, readwrite, duplicate, close },
    path: []const u8 = "",
    source: i32 = 0,
};
const Cmd = struct {
    argv: []const []const u8 = &.{},
    env_extra: []const []const u8 = &.{},
    redirects: []const Redirect = &.{},
    bg: bool = false,
};

fn runJob(job: []const u8, bg: bool) u8 {
    // split into pipeline commands by unquoted '|'
    var cmds = u.Vec([]const u8).init(u.alloc);
    var quote: u8 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < job.len) : (i += 1) {
        const c = job[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (c == '|' and (i + 1 >= job.len or job[i + 1] != '|')) {
            cmds.push(std.mem.trim(u8, job[start..i], " \t\n"));
            start = i + 1;
        }
    }
    cmds.push(std.mem.trim(u8, job[start..], " \t\n"));
    // filter empty segments
    var pipeline = u.Vec([]const u8).init(u.alloc);
    for (cmds.items) |c| {
        if (c.len > 0) pipeline.push(c);
    }
    if (pipeline.items.len == 0) return 0;

    if (pipeline.items.len == 1) {
        var cmd = parseCmd(pipeline.items[0]) orelse return if (parse_failed) 1 else 0;
        cmd.bg = bg;
        return execCmd(cmd, null, null);
    }
    return execPipeline(pipeline.items, bg);
}

// set when parseCmd hit a syntax error (vs. a bare assignment / empty command)
var parse_failed = false;

// ---------------- command parsing ----------------
fn parseCmd(seg: []const u8) ?Cmd {
    parse_failed = false;
    var argv = u.Vec([]const u8).init(u.alloc);
    var env_extra = u.Vec([]const u8).init(u.alloc);
    var cmd = Cmd{};
    var redirects = u.Vec(Redirect).init(u.alloc);
    var i: usize = 0;
    while (i < seg.len) {
        while (i < seg.len and (seg[i] == ' ' or seg[i] == '\t' or seg[i] == '\n')) i += 1;
        if (i >= seg.len) break;
        if (seg[i] == '#' and (i == 0 or seg[i - 1] == ' ' or seg[i - 1] == '\t' or seg[i - 1] == '\n')) break; // comment
        // redirection?
        if (seg[i] == '<' or seg[i] == '>') {
            const rc_char = seg[i];
            var fd: i32 = if (rc_char == '<') 0 else 1;
            var digit_start = i;
            while (digit_start > 0 and std.ascii.isDigit(seg[digit_start - 1])) digit_start -= 1;
            if (digit_start < i and (digit_start == 0 or std.ascii.isWhitespace(seg[digit_start - 1])) and argv.items.len > 0) {
                const literal = seg[digit_start..i];
                if (std.mem.eql(u8, argv.items[argv.items.len - 1], literal)) {
                    fd = std.fmt.parseInt(i32, literal, 10) catch {
                        parse_failed = true;
                        return null;
                    };
                    argv.pop();
                }
            }
            var kind: Redirect = .{ .fd = fd, .kind = if (rc_char == '<') .input else .output };
            i += 1;
            if (i < seg.len and seg[i] == '>') {
                kind.kind = if (rc_char == '<') .readwrite else .append;
                i += 1;
            } else if (i < seg.len and seg[i] == '<') {
                parse_failed = true;
                errf("sh: here-document syntax is not implemented\n", .{});
                return null;
            }
            while (i < seg.len and (seg[i] == ' ' or seg[i] == '\t' or seg[i] == '\n')) i += 1;
            const ws = i;
            var redirect_quote: u8 = 0;
            while (i < seg.len) : (i += 1) {
                const byte = seg[i];
                if (byte == '\\' and redirect_quote != '\'' and i + 1 < seg.len) {
                    i += 1;
                    continue;
                }
                if (redirect_quote != 0) {
                    if (byte == redirect_quote) redirect_quote = 0;
                    continue;
                }
                if (byte == '\'' or byte == '"') {
                    redirect_quote = byte;
                    continue;
                }
                if (std.ascii.isWhitespace(byte) or byte == '<' or byte == '>') break;
            }
            const fname = redirectWord(seg[ws..i]);
            if (fname.len == 0) {
                errf("sh: syntax error near redirect\n", .{});
                parse_failed = true;
                return null;
            }
            if (seg[ws] == '&' and fname.len > 1) {
                if (std.mem.eql(u8, fname[1..], "-")) kind.kind = .close else {
                    kind.source = std.fmt.parseInt(i32, fname[1..], 10) catch {
                        parse_failed = true;
                        return null;
                    };
                    kind.kind = .duplicate;
                }
            } else kind.path = fname;
            redirects.push(kind);
            continue;
        }
        // word
        var word = u.Vec(u8).init(u.alloc);
        var quote: u8 = 0;
        var had_word = false;
        var globbable = false;
        while (i < seg.len) {
            const c = seg[i];
            if (quote == 0 and (c == ' ' or c == '\t' or c == '\n')) break;
            if (quote == 0 and (c == '<' or c == '>')) break;
            if (quote != 0 and c == quote) {
                quote = 0;
                i += 1;
                continue;
            }
            if (quote == 0 and (c == '\'' or c == '"')) {
                quote = c;
                had_word = true;
                i += 1;
                continue;
            }
            if (c == '\\' and i + 1 < seg.len and (quote == 0 or quote == '"')) {
                had_word = true;
                if (seg[i + 1] != '\n') {
                    if (quote == '"' and std.mem.indexOfScalar(u8, "$`\\\"", seg[i + 1]) == null) word.push('\\');
                    word.push(seg[i + 1]);
                }
                i += 2;
                continue;
            }
            if (c == '`' and quote != '\'') {
                // `cmd` backtick substitution
                had_word = true;
                var j = i + 1;
                while (j < seg.len and seg[j] != '`') j += 1;
                const inner = seg[i + 1 .. j];
                const res = captureCmd(inner);
                for (res) |ch| word.push(ch);
                i = if (j < seg.len) j + 1 else j;
                continue;
            }
            if (quote == 0 and (c == '*' or c == '?' or c == '[')) globbable = true;
            if (quote == 0 and c == '$' and i + 1 < seg.len and seg[i + 1] == '\'') {
                i += 2;
                const start = i;
                while (i < seg.len) : (i += 1) {
                    if (seg[i] == '\\' and i + 1 < seg.len) {
                        i += 1;
                        continue;
                    }
                    if (seg[i] == '\'') break;
                }
                const decoded = @import("printf.zig").ansiEscapes(seg[start..i]) orelse {
                    parse_failed = true;
                    return null;
                };
                for (decoded.bytes) |byte| word.push(byte);
                if (i < seg.len) i += 1;
                had_word = true;
                continue;
            }
            if (c == '$' and quote != '\'') {
                if (quote == '"' and i + 1 < seg.len and seg[i + 1] == '@') {
                    if (pos_argc == 0 and word.items.len == 0) had_word = false;
                    for (0..pos_argc) |index| {
                        if (index > 0) {
                            emitWord(&argv, word.items, false);
                            word = u.Vec(u8).init(u.alloc);
                        }
                        var buffer: [32]u8 = undefined;
                        const key = std.fmt.bufPrint(&buffer, "{d}", .{index + 1}) catch break;
                        for (u.getEnv(key) orelse "") |byte| word.push(byte);
                        had_word = true;
                    }
                    i += 2;
                    continue;
                }
                const ex = expandVar(seg, &i);
                const assignment = isAssign(word.items) and (argv.items.len == 0 or std.mem.eql(u8, argv.items[0], "export"));
                if (quote == 0 and !assignment) {
                    const ifs = u.getEnv("IFS") orelse " \t\n";
                    for (ex) |ch| {
                        if (std.mem.indexOfScalar(u8, ifs, ch) != null) {
                            if (had_word or word.items.len > 0) {
                                emitWord(&argv, word.items, globbable);
                                word = u.Vec(u8).init(u.alloc);
                                had_word = false;
                                globbable = false;
                            }
                        } else {
                            word.push(ch);
                            had_word = true;
                            if (ch == '*' or ch == '?' or ch == '[') globbable = true;
                        }
                    }
                } else {
                    had_word = true;
                    for (ex) |ch| word.push(ch);
                }
                continue;
            }
            had_word = true;
            word.push(c);
            i += 1;
        }
        if (had_word or word.items.len > 0) {
            const w = word.items;
            if (argv.items.len == 0 and isAssign(w)) {
                env_extra.push(w);
            } else if (globbable) {
                const matches = u.globWord(w);
                for (matches) |m| argv.push(m);
            } else {
                argv.push(w);
            }
        }
    }
    if (argv.items.len == 0) {
        if (env_extra.items.len > 0) {
            // bare assignment(s): make persistent in shell env
            for (env_extra.items) |kv| {
                const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
                u.setVar(kv[0..eq], kv[eq + 1 ..]);
            }
            if (redirects.items.len == 0) return null;
        }
        if (redirects.items.len == 0) return null;
        cmd.argv = &.{":"};
        cmd.redirects = redirects.items;
        return cmd;
    }
    cmd.redirects = redirects.items;
    cmd.env_extra = env_extra.items;
    cmd.argv = argv.items;
    return cmd;
}

fn redirectWord(text: []const u8) []const u8 {
    var result = u.Vec(u8).init(u.alloc);
    var quote: u8 = 0;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == quote and quote != 0) {
            quote = 0;
            index += 1;
            continue;
        }
        if (quote == 0 and (byte == '\'' or byte == '"')) {
            quote = byte;
            index += 1;
            continue;
        }
        if (byte == '\\' and quote != '\'' and index + 1 < text.len) {
            index += 1;
            result.push(text[index]);
            index += 1;
            continue;
        }
        if (byte == '$' and quote != '\'') {
            const value = expandVar(text, &index);
            for (value) |ch| result.push(ch);
            continue;
        }
        result.push(byte);
        index += 1;
    }
    return result.items;
}

fn emitWord(argv: *u.Vec([]const u8), word: []const u8, globbable: bool) void {
    if (globbable) {
        const matches = u.globWord(word);
        for (matches) |match| argv.push(match);
    } else argv.push(word);
}

fn isAssign(w: []const u8) bool {
    if (w.len == 0) return false;
    if (!(std.ascii.isAlphabetic(w[0]) or w[0] == '_')) return false;
    var i: usize = 1;
    while (i < w.len and w[i] != '=') : (i += 1) {
        if (!(std.ascii.isAlphanumeric(w[i]) or w[i] == '_')) return false;
    }
    return i < w.len;
}

// expand $VAR / $? / $(cmd) / $((expr)) at position; advances i past the reference
fn expandVar(seg: []const u8, i: *usize) []const u8 {
    const start = i.*;
    var j = start + 1;
    if (j >= seg.len) {
        i.* = start + 1;
        return "$";
    }
    if (seg[j] == '#' or seg[j] == '$' or seg[j] == '!') {
        const value: usize = if (seg[j] == '#') pos_argc else if (seg[j] == '$') @intCast(linux.getpid()) else @intCast(@max(last_background_pid, 0));
        i.* = j + 1;
        return std.fmt.allocPrint(u.alloc, "{d}", .{value}) catch "";
    }
    if (seg[j] == '@' or seg[j] == '*') {
        i.* = j + 1;
        var result = u.Vec(u8).init(u.alloc);
        const ifs = u.getEnv("IFS") orelse " ";
        for (0..pos_argc) |index| {
            if (index > 0 and ifs.len > 0) result.push(ifs[0]);
            var buffer: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&buffer, "{d}", .{index + 1}) catch break;
            for (u.getEnv(name) orelse "") |byte| result.push(byte);
        }
        return result.items;
    }
    if (seg[j] == '?') {
        i.* = j + 1;
        const m = u.alloc.alloc(u8, 12) catch return "";
        return std.fmt.bufPrint(m, "{d}", .{last_status}) catch "";
    }
    if (seg[j] == '(') {
        // command substitution $(cmd) or arithmetic $((expr))
        var k = j + 1;
        while (k < seg.len and (seg[k] == ' ' or seg[k] == '\t')) k += 1;
        if (k < seg.len and seg[k] == '(') {
            // arithmetic
            var d: usize = 2;
            var e = k + 1;
            while (e < seg.len and d > 0) : (e += 1) {
                if (seg[e] == '(') d += 1;
                if (seg[e] == ')') d -= 1;
            }
            // e is one past the final ')' that closed both
            const content = seg[k + 1 .. e - 1];
            i.* = e;
            const val = evalArith(content);
            const m = u.alloc.alloc(u8, 24) catch return "";
            return std.fmt.bufPrint(m, "{d}", .{val}) catch "";
        }
        // command substitution: find matching ')'
        var d: usize = 1;
        var e = j + 1;
        while (e < seg.len and d > 0) : (e += 1) {
            if (seg[e] == '(') d += 1;
            if (seg[e] == ')') d -= 1;
        }
        const inner = seg[j + 1 .. e - 1];
        i.* = e;
        return captureCmd(inner);
    }
    if (seg[j] == '{') {
        j += 1;
        const name_start = j;
        while (j < seg.len and seg[j] != '}') j += 1;
        const expression = seg[name_start..j];
        if (j < seg.len) j += 1;
        i.* = j;
        return parameter(expression);
    }
    const name_start = j;
    while (j < seg.len and (std.ascii.isAlphanumeric(seg[j]) or seg[j] == '_')) j += 1;
    if (name_start < seg.len and std.ascii.isDigit(seg[name_start])) j = name_start + 1;
    const name = seg[name_start..j];
    i.* = j;
    if (name.len == 0) return "$";
    return u.getEnv(name) orelse "";
}

fn parameter(expression: []const u8) []const u8 {
    if (expression.len > 1 and expression[0] == '#') {
        const value = u.getEnv(expression[1..]) orelse @as([]const u8, "");
        return std.fmt.allocPrint(u.alloc, "{d}", .{value.len}) catch "";
    }
    var end: usize = 0;
    while (end < expression.len and (std.ascii.isAlphanumeric(expression[end]) or expression[end] == '_')) end += 1;
    const name = expression[0..end];
    const value = u.getEnv(name);
    if (end == expression.len) return value orelse "";
    var op = expression[end..];
    var null_is_unset = false;
    if (op.len > 0 and op[0] == ':') {
        null_is_unset = true;
        op = op[1..];
    }
    if (op.len == 0) return "";
    const unset = value == null or null_is_unset and value.?.len == 0;
    if (op[0] == '-') return if (unset) expand(op[1..]) else value.?;
    if (op[0] == '+') return if (unset) "" else expand(op[1..]);
    if (op[0] == '=') {
        if (unset) {
            const result = expand(op[1..]);
            u.setVar(name, result);
            return result;
        }
        return value.?;
    }
    if (op[0] == '%' or op[0] == '#') {
        const text = value orelse "";
        const prefix = op[0] == '#';
        const longest = op.len > 1 and op[1] == op[0];
        const pattern = expand(op[(if (longest) @as(usize, 2) else 1)..]);
        var amount: usize = 0;
        while (amount <= text.len) : (amount += 1) {
            const size = if (longest) text.len - amount else amount;
            const candidate = if (prefix) text[0..size] else text[text.len - size ..];
            if (u.matchPat(pattern, candidate)) return if (prefix) text[size..] else text[0 .. text.len - size];
        }
        return text;
    }
    return "";
}

fn expand(s: []const u8) []const u8 {
    var i: usize = 0;
    var result = u.Vec(u8).init(u.alloc);
    while (i < s.len) {
        const c = s[i];
        if (c == '`') {
            var j = i + 1;
            while (j < s.len and s[j] != '`') j += 1;
            const res = captureCmd(s[i + 1 .. j]);
            for (res) |ch| result.push(ch);
            i = if (j < s.len) j + 1 else j;
            continue;
        }
        if (c == '$') {
            const ex = expandVar(s, &i);
            for (ex) |ch| result.push(ch);
            continue;
        }
        result.push(c);
        i += 1;
    }
    return result.items;
}

// run a command and capture its stdout
fn captureCmd(cmdtext: []const u8) []const u8 {
    const cmd = std.mem.trim(u8, cmdtext, " \t\n");
    if (cmd.len == 0) return "";
    var fds: [2]i32 = undefined;
    if (u.errno(linux.pipe(&fds)) != .SUCCESS) return "";
    const rc = linux.fork();
    if (u.errno(rc) != .SUCCESS) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return "";
    }
    if (rc == 0) {
        in_child = true;
        restoreSignals();
        _ = linux.dup2(fds[1], 1);
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        _ = execTop(cmd);
        linux.exit_group(0);
    }
    _ = linux.close(fds[1]);
    var res = u.Vec(u8).init(u.alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n0 = linux.read(fds[0], &buf, buf.len);
        if (u.errno(n0) != .SUCCESS or n0 == 0) break;
        for (buf[0..n0]) |c| res.push(c);
    }
    _ = linux.close(fds[0]);
    var st: u32 = 0;
    _ = linux.waitpid(@intCast(rc), &st, 0);
    // strip one trailing newline
    if (res.items.len > 0 and res.items[res.items.len - 1] == '\n') {
        res.items = res.items[0 .. res.items.len - 1];
    }
    return res.items;
}

// ---------------- arithmetic $(( ... )) ----------------
const Arith = struct {
    s: []const u8,
    i: usize = 0,
    err: bool = false,

    fn ws(self: *Arith) void {
        while (self.i < self.s.len and (self.s[self.i] == ' ' or self.s[self.i] == '\t' or self.s[self.i] == '\n')) self.i += 1;
    }

    fn primary(self: *Arith) i64 {
        self.ws();
        if (self.i >= self.s.len) return 0;
        const c = self.s[self.i];
        if (c == '(') {
            self.i += 1;
            const v = self.orExpr();
            self.ws();
            if (self.i < self.s.len and self.s[self.i] == ')') self.i += 1;
            return v;
        }
        if (c == '-') {
            self.i += 1;
            return -self.primary();
        }
        if (c == '+') {
            self.i += 1;
            return self.primary();
        }
        if (c == '~') {
            self.i += 1;
            return ~self.primary();
        }
        if (c == '!') {
            self.i += 1;
            return if (self.primary() == 0) 1 else 0;
        }
        if (std.ascii.isDigit(c)) {
            var v: i64 = 0;
            while (self.i < self.s.len and std.ascii.isDigit(self.s[self.i])) : (self.i += 1) {
                v = v * 10 + (self.s[self.i] - '0');
            }
            return v;
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const st = self.i;
            while (self.i < self.s.len and (std.ascii.isAlphanumeric(self.s[self.i]) or self.s[self.i] == '_')) self.i += 1;
            const name = self.s[st..self.i];
            const v = u.getEnv(name) orelse "0";
            return u.toInt(v) orelse 0;
        }
        self.i += 1;
        return 0;
    }

    fn mul(self: *Arith) i64 {
        var v = self.primary();
        while (true) {
            self.ws();
            if (self.i >= self.s.len) break;
            const op = self.s[self.i];
            if (op == '*') {
                self.i += 1;
                v = v *% self.primary();
            } else if (op == '/') {
                self.i += 1;
                const d = self.primary();
                v = if (d != 0) @divTrunc(v, d) else 0;
            } else if (op == '%') {
                self.i += 1;
                const d = self.primary();
                v = if (d != 0) @rem(v, d) else 0;
            } else break;
        }
        return v;
    }

    fn add(self: *Arith) i64 {
        var v = self.mul();
        while (true) {
            self.ws();
            if (self.i >= self.s.len) break;
            const op = self.s[self.i];
            if (op == '+') {
                self.i += 1;
                v = v +% self.mul();
            } else if (op == '-') {
                self.i += 1;
                v = v -% self.mul();
            } else break;
        }
        return v;
    }

    fn peek2(self: *Arith) []const u8 {
        self.ws();
        if (self.i >= self.s.len) return "";
        if (self.i + 1 < self.s.len) return self.s[self.i .. self.i + 2];
        return self.s[self.i .. self.i + 1];
    }

    fn cmp(self: *Arith) i64 {
        var v = self.add();
        while (true) {
            const op = self.peek2();
            if (std.mem.eql(u8, op, "<=") or std.mem.eql(u8, op, ">=") or
                std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!="))
            {
                self.i += 2;
                const r = self.add();
                v = if (std.mem.eql(u8, op, "<=")) @intFromBool(v <= r) else if (std.mem.eql(u8, op, ">=")) @intFromBool(v >= r) else if (std.mem.eql(u8, op, "==")) @intFromBool(v == r) else @intFromBool(v != r);
            } else {
                self.ws();
                if (self.i >= self.s.len) break;
                const c = self.s[self.i];
                if (c == '<') {
                    self.i += 1;
                    const r = self.add();
                    v = @intFromBool(v < r);
                } else if (c == '>') {
                    self.i += 1;
                    const r = self.add();
                    v = @intFromBool(v > r);
                } else break;
            }
        }
        return v;
    }

    fn andE(self: *Arith) i64 {
        var v = self.cmp();
        while (true) {
            const op = self.peek2();
            if (std.mem.eql(u8, op, "&&")) {
                self.i += 2;
                const r = self.cmp();
                v = @intFromBool(v != 0 and r != 0);
            } else break;
        }
        return v;
    }

    fn orExpr(self: *Arith) i64 {
        var v = self.andE();
        while (true) {
            const op = self.peek2();
            if (std.mem.eql(u8, op, "||")) {
                self.i += 2;
                const r = self.andE();
                v = @intFromBool(v != 0 or r != 0);
            } else break;
        }
        return v;
    }
};

fn evalArith(s: []const u8) i64 {
    var a = Arith{ .s = s };
    return a.orExpr();
}

// ---------------- execution ----------------
fn restoreSignals() void {
    var dfl = linux.Sigaction{
        .handler = .{ .handler = null },
        .mask = @splat(0),
        .flags = 0,
    };
    _ = linux.sigaction(.INT, &dfl, null);
    _ = linux.sigaction(.QUIT, &dfl, null);
}

fn waitStatus(status: u32) u8 {
    if (status & 0x7f != 0 and status & 0x7f != 0x7f) return @intCast(128 + (status & 0x7f));
    return @intCast((status >> 8) & 0xff);
}
fn waitPid(pid: i32) u8 {
    for (completed.items, 0..) |entry, index| if (entry.pid == pid) {
        std.mem.copyForwards(Completed, completed.items[index .. completed.items.len - 1], completed.items[index + 1 ..]);
        completed.items.len -= 1;
        return entry.status;
    };
    var status: u32 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, 0);
        if (u.ok(rc)) return waitStatus(status);
        if (u.errno(rc) != .INTR) return 127;
    }
}

fn isBuiltin(name: []const u8) bool {
    return eqAny(name, &.{ "cd", "pwd", "exit", "export", "echo", "wait", "read", "break", "continue", "shift", "unset", "exec", "return", "umask", "set", ".", "source", ":" });
}

fn execCmd(cmd: Cmd, in_pipe: ?[2]i32, out_pipe: ?[2]i32) u8 {
    const name = cmd.argv[0];

    if (!cmd.bg and in_pipe == null and out_pipe == null and (isBuiltin(name) or functionBody(name) != null)) {
        const Saved = struct { fd: i32, old: i32 };
        var saved = u.Vec(Saved).init(u.alloc);
        const permanent = std.mem.eql(u8, name, "exec") and cmd.argv.len == 1;
        defer for (saved.items) |entry| {
            if (!permanent) {
                if (entry.old >= 0) {
                    _ = linux.dup2(entry.old, entry.fd);
                } else {
                    _ = linux.close(entry.fd);
                }
            }
            if (entry.old >= 0) _ = linux.close(entry.old);
        };
        var minimum: usize = 10;
        for (cmd.redirects) |redirect| {
            minimum = @max(minimum, @as(usize, @intCast(@max(redirect.fd, redirect.source))) + 1);
        }
        for (cmd.redirects) |redirect| {
            var found = false;
            for (saved.items) |entry| if (entry.fd == redirect.fd) {
                found = true;
                break;
            };
            if (!found) {
                const rc = linux.fcntl(redirect.fd, 1030, minimum); // F_DUPFD_CLOEXEC
                if (!u.ok(rc) and u.errno(rc) != .BADF) return 1;
                saved.push(.{ .fd = redirect.fd, .old = if (u.ok(rc)) @intCast(rc) else -1 });
            }
        }
        if (!redirectAll(cmd)) return 1;
        if (functionBody(name)) |body| return callFunction(body, cmd.argv);
        return runBuiltin(cmd);
    }

    const pid_raw = linux.fork();
    if (u.errno(pid_raw) != .SUCCESS) {
        errf("sh: fork: {s}\n", .{u.strerr(u.errno(pid_raw))});
        return 1;
    }
    if (pid_raw == 0) {
        // child
        restoreSignals();
        u.setProcName(name);
        if (in_pipe) |p| {
            _ = linux.dup2(p[0], 0);
            _ = linux.close(p[0]);
            _ = linux.close(p[1]);
        }
        if (out_pipe) |p| {
            _ = linux.dup2(p[1], 1);
            _ = linux.close(p[0]);
            _ = linux.close(p[1]);
        }
        applyRedirects(cmd);
        const code = runChild(cmd.argv, cmd.env_extra);
        linux.exit_group(code);
    }
    last_pid = @intCast(pid_raw);
    if (cmd.bg) return 0;
    var code: u8 = 0;
    if (in_pipe == null and out_pipe == null) {
        code = waitPid(last_pid);
    }
    return code;
}

fn runChild(argv: []const []const u8, extra_env: []const []const u8) u8 {
    in_child = true;
    const name = argv[0];
    for (extra_env) |entry| if (std.mem.startsWith(u8, entry, "PATH=")) {
        u.setVar("PATH", entry[5..]);
    };
    if (functionBody(name)) |body| return callFunction(body, argv);
    // builtin in pipeline context
    if (isBuiltin(name)) {
        const cmd = Cmd{ .argv = argv };
        return runBuiltin(cmd);
    }
    // external
    var pbuf: [u.PATH_MAX]u8 = undefined;
    const path = u.findInPath(name, &pbuf) orelse {
        errf("sh: {s}: not found\n", .{name});
        return 127;
    };
    var argv_z = u.Vec([:0]const u8).init(u.alloc);
    for (argv) |a| argv_z.push(u.zstr(a));
    _ = linux.execve(path.ptr, u.argvp(argv_z.items), u.envp(extra_env));
    errf("sh: {s}: exec failed\n", .{name});
    return 127;
}

fn execPipeline(segs: []const []const u8, bg: bool) u8 {
    var prev_pipe: ?[2]i32 = null;
    var last: u8 = 0;
    var pids = u.Vec(i32).init(u.alloc);
    for (segs, 0..) |seg, idx| {
        const cmd0 = parseCmd(seg) orelse {
            if (prev_pipe) |p| {
                _ = linux.close(p[0]);
                _ = linux.close(p[1]);
            }
            return 1;
        };
        var cmd = cmd0;
        cmd.bg = bg;
        var cur_pipe: ?[2]i32 = null;
        if (idx + 1 < segs.len) {
            var fds: [2]i32 = undefined;
            if (u.errno(linux.pipe(&fds)) != .SUCCESS) {
                errf("sh: pipe failed\n", .{});
                return 1;
            }
            cur_pipe = fds;
        }
        const rc = linux.fork();
        if (u.errno(rc) != .SUCCESS) {
            errf("sh: fork failed\n", .{});
            return 1;
        }
        if (rc == 0) {
            // child: redo pipes without forking again
            restoreSignals();
            u.setProcName(cmd.argv[0]);
            if (prev_pipe) |p| {
                _ = linux.dup2(p[0], 0);
                _ = linux.close(p[0]);
                _ = linux.close(p[1]);
            }
            if (cur_pipe) |p| {
                _ = linux.dup2(p[1], 1);
                _ = linux.close(p[0]);
                _ = linux.close(p[1]);
            }
            applyRedirects(cmd);
            const code = runChild(cmd.argv, cmd.env_extra);
            linux.exit_group(code);
        }
        pids.push(@intCast(rc));
        if (prev_pipe) |p| {
            _ = linux.close(p[0]);
            _ = linux.close(p[1]);
        }
        prev_pipe = cur_pipe;
    }
    if (prev_pipe) |p| {
        _ = linux.close(p[0]);
        _ = linux.close(p[1]);
    }
    if (!bg) {
        // wait only this pipeline's children (background jobs are reaped by reapBg)
        for (pids.items) |pid| last = waitPid(pid);
    }
    last_pid = if (pids.items.len > 0) pids.items[pids.items.len - 1] else 0;
    return last;
}

// non-blocking reap of finished background jobs
fn reapBg() void {
    while (true) {
        var st: u32 = 0;
        const rc = linux.waitpid(-1, &st, 1); // WNOHANG
        if (u.errno(rc) != .SUCCESS or rc <= 0) break;
        completed.push(.{ .pid = @intCast(rc), .status = waitStatus(st) });
    }
}

fn redirectAll(cmd: Cmd) bool {
    for (cmd.redirects) |redirect| {
        if (redirect.kind == .close) {
            _ = linux.close(redirect.fd);
            continue;
        }
        if (redirect.kind == .duplicate) {
            if (!u.ok(linux.dup2(redirect.source, redirect.fd))) return false;
            continue;
        }
        const flags: std.posix.O = switch (redirect.kind) {
            .input => .{ .ACCMODE = .RDONLY },
            .output => .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            .append => .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
            .readwrite => .{ .ACCMODE = .RDWR, .CREAT = true },
            else => unreachable,
        };
        const file = u.File.open(redirect.path, flags, 0o666) orelse {
            errf("sh: {s}: cannot open\n", .{redirect.path});
            return false;
        };
        if (file.fd != redirect.fd) {
            const rc = linux.dup2(file.fd, redirect.fd);
            file.close();
            if (!u.ok(rc)) return false;
        }
    }
    return true;
}
fn applyRedirects(cmd: Cmd) void {
    if (!redirectAll(cmd)) linux.exit_group(1);
}

// ---------------- builtins ----------------
fn runBuiltin(cmd: Cmd) u8 {
    const argv = cmd.argv;
    const name = argv[0];
    if (std.mem.eql(u8, name, ":")) return 0;
    if (std.mem.eql(u8, name, "return")) {
        if (function_depth == 0 and source_depth == 0) return 1;
        returning = true;
        return if (argv.len > 1) @truncate(@as(u64, @bitCast(u.toInt(argv[1]) orelse return 2))) else last_status;
    }
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "source")) {
        if (argv.len < 2) return 2;
        var path = argv[1];
        if (std.mem.indexOfScalar(u8, path, '/') == null) {
            var found: ?[]const u8 = null;
            var dirs = std.mem.splitScalar(u8, u.getEnv("PATH") orelse "/bin:/usr/bin", ':');
            while (dirs.next()) |directory| {
                const candidate = std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ if (directory.len == 0) "." else directory, path }) catch return 1;
                if (u.ok(linux.access(u.zstr(candidate), 4))) {
                    found = candidate;
                    break;
                }
            }
            path = found orelse return 1;
        }
        const data = @import("input.zig").read(path, false) orelse return 1;
        const zero = u.getEnv("0") orelse "sh";
        const old_count = pos_argc;
        var saved = u.Vec([]const u8).init(u.alloc);
        if (argv.len > 2) {
            for (0..old_count) |index| {
                var buf: [32]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "{d}", .{index + 1}) catch return 1;
                saved.push(u.getEnv(key) orelse "");
            }
            setPositional(zero, argv[2..]);
        }
        source_depth += 1;
        const code = execTop(data);
        source_depth -= 1;
        returning = false;
        if (argv.len > 2) setPositional(zero, saved.items);
        return code;
    }
    if (std.mem.eql(u8, name, "set")) {
        if (argv.len > 1 and std.mem.eql(u8, argv[1], "--")) {
            setPositional(u.getEnv("0") orelse "sh", argv[2..]);
            return 0;
        }
        return 2;
    }
    if (std.mem.eql(u8, name, "umask")) {
        const value = u.umask(0);
        _ = u.umask(value);
        if (argv.len == 1) {
            outf("{o:0>4}\n", .{@as(u64, value)});
            return 0;
        }
        if (argv.len != 2) return 1;
        const parsed = std.fmt.parseInt(u32, argv[1], 8) catch return 1;
        if (parsed > 0o777) return 1;
        _ = u.umask(parsed);
        return 0;
    }
    if (std.mem.eql(u8, name, "unset")) {
        for (argv[1..]) |variable| u.unsetVar(variable);
        return 0;
    }
    if (std.mem.eql(u8, name, "exec")) {
        if (argv.len == 1) return 0;
        return runChild(argv[1..], cmd.env_extra);
    }
    if (std.mem.eql(u8, name, "cd")) {
        var target: []const u8 = "/";
        if (argv.len > 1) {
            target = argv[1];
        } else if (u.getEnv("HOME")) |h| {
            target = h;
        }
        const rc = linux.chdir(u.zstr(target));
        if (!u.ok(rc)) {
            errf("cd: {s}: {s}\n", .{ target, u.strerr(u.errno(rc)) });
            return 1;
        }
        return 0;
    }
    if (std.mem.eql(u8, name, "pwd")) {
        var buf: [u.PATH_MAX]u8 = undefined;
        const rc = linux.getcwd(&buf, buf.len);
        if (u.ok(rc)) {
            outf("{s}\n", .{std.mem.sliceTo(&buf, 0)});
            return 0;
        }
        return 1;
    }
    if (std.mem.eql(u8, name, "exit")) {
        var code: u8 = last_status;
        if (argv.len > 1) {
            if (u.toInt(argv[1])) |v| code = @intCast(@as(u64, @bitCast(v)) & 0xff);
        }
        linux.exit_group(code);
    }
    if (std.mem.eql(u8, name, "export")) {
        for (argv[1..]) |a| {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            if (eq == null) {
                u.setEnv(a, u.getEnv(a) orelse "");
                continue;
            }
            u.setEnv(a[0..eq.?], a[eq.? + 1 ..]);
        }
        return 0;
    }
    if (std.mem.eql(u8, name, "wait")) {
        if (argv.len > 1) {
            var last: u8 = 0;
            for (argv[1..]) |a| {
                if (u.toInt(a)) |pid| last = waitPid(@intCast(@as(u64, @bitCast(pid)) & 0x7fffffff));
            }
            return last;
        }
        while (true) {
            var st: u32 = 0;
            const rc = linux.waitpid(-1, &st, 0);
            if (u.errno(rc) != .SUCCESS) break;
        }
        return 0;
    }
    if (std.mem.eql(u8, name, "break")) {
        var n: u32 = 1;
        if (argv.len > 1) {
            if (u.toInt(argv[1])) |v| {
                if (v > 0) n = @intCast(@min(v, 100));
            }
        }
        break_count = n;
        return 0;
    }
    if (std.mem.eql(u8, name, "continue")) {
        var n: u32 = 1;
        if (argv.len > 1) {
            if (u.toInt(argv[1])) |v| {
                if (v > 0) n = @intCast(@min(v, 100));
            }
        }
        continue_count = n;
        return 0;
    }
    if (std.mem.eql(u8, name, "shift")) {
        var n: usize = 1;
        if (argv.len > 1) {
            if (u.toInt(argv[1])) |v| {
                if (v >= 0) n = @intCast(v) else return 1;
            }
        }
        const count = pos_argc;
        if (n > count) return 1;
        var i: usize = 1;
        while (i <= count - n) : (i += 1) {
            var nb: [8]u8 = undefined;
            const dst = std.fmt.bufPrint(&nb, "{d}", .{i}) catch break;
            var nb2: [8]u8 = undefined;
            const srcn = std.fmt.bufPrint(&nb2, "{d}", .{i + n}) catch break;
            u.setVar(dst, u.getEnv(srcn) orelse "");
        }
        i = count - n + 1;
        while (i <= count) : (i += 1) {
            var nb: [8]u8 = undefined;
            const dst = std.fmt.bufPrint(&nb, "{d}", .{i}) catch break;
            u.unsetVar(dst);
        }
        pos_argc = count - n;
        return 0;
    }
    if (std.mem.eql(u8, name, "read")) {
        var vars = argv[1..];
        var linebuf: [8192]u8 = undefined;
        var line: ?[]const u8 = null;
        if (in_child) {
            // pipeline child: read raw from fd 0
            var n: usize = 0;
            var eof = false;
            while (n < linebuf.len) {
                var c: [1]u8 = undefined;
                const r = linux.read(0, &c, 1);
                if (u.errno(r) != .SUCCESS) {
                    eof = n == 0;
                    break;
                }
                if (r == 0) {
                    eof = n == 0;
                    break;
                }
                if (c[0] == '\n') break;
                linebuf[n] = c[0];
                n += 1;
            }
            if (eof) return 1;
            line = linebuf[0..n];
        } else if (cur_src) |src| {
            const l = src.next() orelse return 1;
            if (l.len > linebuf.len) return 1;
            @memcpy(linebuf[0..l.len], l);
            line = linebuf[0..l.len];
        } else {
            var n: usize = 0;
            var eof = false;
            while (n < linebuf.len) {
                var c: [1]u8 = undefined;
                const r = linux.read(0, &c, 1);
                if (u.errno(r) != .SUCCESS) {
                    eof = n == 0;
                    break;
                }
                if (r == 0) {
                    eof = n == 0;
                    break;
                }
                if (c[0] == '\n') break;
                linebuf[n] = c[0];
                n += 1;
            }
            if (eof) return 1;
            line = linebuf[0..n];
        }
        const l = line orelse return 1;
        if (vars.len == 0) vars = &.{"REPLY"};
        var vi: usize = 0;
        var pos: usize = 0;
        while (vi < vars.len) : (vi += 1) {
            while (pos < l.len and (l[pos] == ' ' or l[pos] == '\t')) pos += 1;
            if (vi == vars.len - 1) {
                // last var gets the rest of the line
                var end = l.len;
                while (end > pos and (l[end - 1] == ' ' or l[end - 1] == '\t' or l[end - 1] == '\r')) end -= 1;
                u.setVar(vars[vi], l[pos..end]);
                pos = end;
            } else {
                const s = pos;
                while (pos < l.len and l[pos] != ' ' and l[pos] != '\t') pos += 1;
                u.setVar(vars[vi], l[s..pos]);
            }
        }
        return 0;
    }
    if (std.mem.eql(u8, name, "echo")) {
        // reuse core echo
        const core = @import("core.zig");
        // apply redirections if in pipeline context
        applyRedirects(cmd);
        return core.echo(argv[1..]);
    }
    return 1;
}
