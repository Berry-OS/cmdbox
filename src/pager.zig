// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// less / more - pager. Non-tty output behaves like cat (more prints file headers for several files).
// Interactive keys: space f ^F PgDn / b ^B PgUp / j Enter ^N Down / k ^K ^P Up / d ^D / u ^U /
//                   g < Home / G > End / /pat ?pat n N / = / q Q ZZ
const std = @import("std");
const u = @import("util.zig");
const linux = std.os.linux;
const input = @import("input.zig");

const TCGETS: u32 = 0x5401;
const TCSETS: u32 = 0x5402;
const TIOCGWINSZ: u32 = 0x5413;
const Winsize = extern struct { row: u16, col: u16, xpixel: u16, ypixel: u16 };

const Opts = struct {
    is_less: bool = true,
    numbers: bool = false, // -N
    chop: bool = false, // -S
    raw: bool = false, // -R
    quit_one: bool = false, // -F
    no_init: bool = false, // -X
    icase: bool = false, // -i / -I
    squeeze: bool = false, // -s
    start_line: usize = 0,
    start_pat: ?[]const u8 = null,
    page_lines: ?usize = null,
};

fn isTty(fd: i32) bool {
    var t: linux.termios = undefined;
    return u.ok(linux.ioctl(fd, TCGETS, @intFromPtr(&t)));
}

var saved: linux.termios = undefined;
var tty_fd: i32 = 0;

fn rawOn() bool {
    var t: linux.termios = undefined;
    if (!u.ok(linux.ioctl(tty_fd, TCGETS, @intFromPtr(&t)))) return false;
    saved = t;
    t.iflag.IXON = false;
    t.lflag.ICANON = false;
    t.lflag.ECHO = false;
    t.lflag.ISIG = false;
    t.cc[@intFromEnum(linux.V.MIN)] = 1;
    t.cc[@intFromEnum(linux.V.TIME)] = 0;
    return u.ok(linux.ioctl(tty_fd, TCSETS, @intFromPtr(&t)));
}

fn rawOff() void {
    _ = linux.ioctl(tty_fd, TCSETS, @intFromPtr(&saved));
}

fn readKey() ?[]const u8 {
    var b: [8]u8 = undefined;
    while (true) {
        const rc = linux.read(tty_fd, &b, 1);
        if (u.errno(rc) == .INTR) continue;
        if (!u.ok(rc) or rc == 0) return null;
        break;
    }
    if (b[0] != 0x1b) return u.alloc.dupe(u8, b[0..1]) catch null;
    // escape sequence: wait briefly for the rest
    var n: usize = 1;
    var pfd = [_]linux.pollfd{.{ .fd = tty_fd, .events = linux.POLL.IN, .revents = 0 }};
    while (n < b.len) {
        if (linux.poll(&pfd, 1, 30) <= 0) break;
        const rc = linux.read(tty_fd, b[n..].ptr, 1);
        if (!u.ok(rc) or rc == 0) break;
        n += 1;
        if (n >= 3 and ((b[n - 1] >= 'A' and b[n - 1] <= 'Z') or b[n - 1] == '~')) break;
    }
    return u.alloc.dupe(u8, b[0..n]) catch null;
}

const Row = struct { line: usize, text: []const u8, first: bool };

fn charWidth(cp_len: usize) usize {
    _ = cp_len;
    return 1;
}

// Length of an SGR colour sequence (ESC [ params m) at s[i], 0 if there is none.
// Colours are always passed through (like less -R) so `dmesg --color=always | less` works.
fn sgrLen(s: []const u8, i: usize) usize {
    if (i + 2 >= s.len or s[i] != 0x1b or s[i + 1] != '[') return 0;
    var j = i + 2;
    while (j < s.len and ((s[j] >= '0' and s[j] <= '9') or s[j] == ';' or s[j] == ':')) j += 1;
    if (j < s.len and s[j] == 'm') return j + 1 - i;
    return 0;
}

// Render one logical line to display bytes (tabs expanded, control chars as ^X unless raw).
fn expand(line: []const u8, o: *const Opts, out: *u.Vec(u8)) void {
    var col: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const ch = line[i];
        if (ch == '\t') {
            const n = 8 - col % 8;
            out.pushN(' ', n);
            col += n;
            i += 1;
        } else if (ch == 0x1b and (o.raw or sgrLen(line, i) > 0)) {
            // pass an ANSI sequence through untouched (zero width)
            var j = i + 1;
            if (j < line.len and line[j] == '[') {
                j += 1;
                while (j < line.len and !(line[j] >= 0x40 and line[j] <= 0x7e)) j += 1;
                if (j < line.len) j += 1;
            }
            out.pushSlice(line[i..j]);
            i = j;
        } else if (ch == '\r' and i + 1 == line.len) {
            i += 1;
        } else if (ch < 0x20 or ch == 0x7f) {
            out.push('^');
            out.push(if (ch == 0x7f) '?' else ch + 0x40);
            col += 2;
            i += 1;
        } else if (ch >= 0x80) {
            const l = std.unicode.utf8ByteSequenceLength(ch) catch 1;
            const e = @min(i + l, line.len);
            out.pushSlice(line[i..e]);
            col += charWidth(l);
            i += e - i;
        } else {
            out.push(ch);
            col += 1;
            i += 1;
        }
    }
}

// number of display cells of an expanded segment starting at i (ANSI sequences count zero)
fn cellsUntil(s: []const u8, i: usize, max_cells: usize) usize {
    var cells: usize = 0;
    var j = i;
    while (j < s.len and cells < max_cells) {
        if (s[j] == 0x1b and j + 1 < s.len and s[j + 1] == '[') {
            j += 2;
            while (j < s.len and !(s[j] >= 0x40 and s[j] <= 0x7e)) j += 1;
            if (j < s.len) j += 1;
            continue;
        }
        const l = if (s[j] >= 0x80) (std.unicode.utf8ByteSequenceLength(s[j]) catch 1) else 1;
        j = @min(j + l, s.len);
        cells += 1;
    }
    // swallow trailing zero-width sequences
    while (j + 1 < s.len and s[j] == 0x1b and s[j + 1] == '[') {
        j += 2;
        while (j < s.len and !(s[j] >= 0x40 and s[j] <= 0x7e)) j += 1;
        if (j < s.len) j += 1;
    }
    return j;
}

fn buildRows(lines: []const []const u8, o: *const Opts, width: usize, rows: *u.Vec(Row)) void {
    rows.items.len = 0;
    const nw: usize = if (o.numbers) 8 else 0;
    const w = if (width > nw + 1) width - nw else 1;
    var prev_blank = false;
    for (lines, 0..) |ln, idx| {
        if (o.squeeze) {
            const blank = ln.len == 0;
            if (blank and prev_blank) continue;
            prev_blank = blank;
        }
        var buf = u.Vec(u8).init(u.alloc);
        expand(ln, o, &buf);
        if (o.chop or buf.items.len == 0) {
            rows.push(.{ .line = idx, .text = buf.items, .first = true });
            continue;
        }
        var pos: usize = 0;
        var first = true;
        while (pos < buf.items.len) {
            const end = cellsUntil(buf.items, pos, w);
            rows.push(.{ .line = idx, .text = buf.items[pos..end], .first = first });
            first = false;
            pos = end;
        }
    }
}

fn containsAt(hay: []const u8, pat: []const u8, icase: bool) bool {
    if (!icase) return std.mem.indexOf(u8, hay, pat) != null;
    return std.ascii.indexOfIgnoreCase(hay, pat) != null;
}

const Pager = struct {
    o: Opts,
    lines: [][]const u8,
    rows: u.Vec(Row),
    top: usize = 0,
    height: usize = 24,
    width: usize = 80,
    name: []const u8,
    pat: []const u8 = "",
    pat_fwd: bool = true,
    msg: []const u8 = "",
    eof_seen: bool = false,

    fn bodyRows(self: *Pager) usize {
        return if (self.height > 1) self.height - 1 else 1;
    }

    fn maxTop(self: *Pager) usize {
        const b = self.bodyRows();
        return if (self.rows.items.len > b) self.rows.items.len - b else 0;
    }

    fn draw(self: *Pager) void {
        var out = u.Vec(u8).init(u.alloc);
        out.pushSlice("\x1b[H");
        const b = self.bodyRows();
        var r: usize = 0;
        while (r < b) : (r += 1) {
            const i = self.top + r;
            if (i < self.rows.items.len) {
                const row = self.rows.items[i];
                if (self.o.numbers) {
                    if (row.first) out.pushSlice(std.fmt.allocPrint(u.alloc, "{d: >7} ", .{row.line + 1}) catch "") else out.pushSlice("        ");
                }
                out.pushSlice(row.text);
                if (self.o.chop and row.text.len > 0) {} // chopped rows are cut by the terminal's no-wrap mode
            } else if (self.o.is_less) out.push('~');
            out.pushSlice("\x1b[K\r\n");
        }
        // status line
        out.pushSlice("\x1b[7m");
        var st = u.Vec(u8).init(u.alloc);
        const at_end = self.top >= self.maxTop();
        if (self.msg.len > 0) st.pushSlice(self.msg) else if (self.o.is_less) {
            if (at_end) st.pushSlice(if (self.name.len > 0) std.fmt.allocPrint(u.alloc, "{s} (END)", .{self.name}) catch "(END)" else "(END)") else if (self.name.len > 0) st.pushSlice(std.fmt.allocPrint(u.alloc, "{s} lines {d}-{d}/{d} {d}%", .{ self.name, self.top + 1, @min(self.top + b, self.rows.items.len), self.rows.items.len, @min(100, (self.top + b) * 100 / @max(self.rows.items.len, 1)) }) catch "") else st.push(':');
        } else {
            const pct = @min(100, (self.top + b) * 100 / @max(self.rows.items.len, 1));
            st.pushSlice(std.fmt.allocPrint(u.alloc, "--More--({d}%)", .{pct}) catch "--More--");
        }
        const sl = @min(st.items.len, self.width);
        out.pushSlice(st.items[0..sl]);
        out.pushSlice("\x1b[0m\x1b[K");
        u.out(out.items);
        self.msg = "";
    }

    fn scrollTo(self: *Pager, t: usize) void {
        self.top = @min(t, self.maxTop());
    }

    fn prompt(self: *Pager, ch: u8) ?[]const u8 {
        _ = self;
        var line = u.Vec(u8).init(u.alloc);
        while (true) {
            u.out(std.fmt.allocPrint(u.alloc, "\r\x1b[K{c}{s}", .{ ch, line.items }) catch "");
            const k = readKey() orelse return null;
            if (k.len == 1) switch (k[0]) {
                '\r', '\n' => return line.items,
                0x1b, 0x03 => return null,
                0x7f, 0x08 => {
                    if (line.items.len == 0) return null;
                    line.items.len -= 1;
                },
                else => if (k[0] >= 0x20) line.push(k[0]),
            };
        }
    }

    fn rowHas(self: *Pager, i: usize) bool {
        return containsAt(self.lines[self.rows.items[i].line], self.pat, self.o.icase or self.smartIcase());
    }

    fn smartIcase(self: *Pager) bool {
        _ = self;
        return false;
    }

    fn search(self: *Pager, fwd: bool, from_next: bool) void {
        if (self.pat.len == 0) {
            self.msg = "No previous regular expression";
            return;
        }
        const n = self.rows.items.len;
        if (n == 0) return;
        var i: usize = self.top;
        var steps: usize = 0;
        while (steps < n) : (steps += 1) {
            if (fwd) {
                i += 1;
                if (i >= n) break;
            } else {
                if (i == 0) break;
                i -= 1;
            }
            // skip continuation rows of the line we start from
            if (self.rowHas(i) and self.rows.items[i].first) {
                self.scrollTo(i);
                if (!self.o.is_less or true) self.top = @min(i, self.maxTop());
                return;
            }
        }
        _ = from_next;
        self.msg = "Pattern not found";
    }

    fn run(self: *Pager) void {
        self.draw();
        while (true) {
            const k = readKey() orelse return;
            const b = self.bodyRows();
            const s = k;
            if (s.len == 1) {
                switch (s[0]) {
                    'q', 'Q', 0x03 => return,
                    ' ', 'f', 0x06, 'z' => {
                        if (!self.o.is_less and self.top >= self.maxTop()) return;
                        self.scrollTo(self.top + b);
                    },
                    'b', 0x02, 'w' => self.scrollTo(self.top -| b),
                    '\r', '\n', 'j', 0x0e, 'e', 0x05 => {
                        if (!self.o.is_less and self.top >= self.maxTop()) return;
                        self.scrollTo(self.top + 1);
                    },
                    'k', 0x0b, 0x10, 'y', 0x19 => self.scrollTo(self.top -| 1),
                    'd', 0x04 => self.scrollTo(self.top + b / 2),
                    'u', 0x15 => self.scrollTo(self.top -| (b / 2)),
                    'g', '<' => self.top = 0,
                    'G', '>' => self.top = self.maxTop(),
                    'n' => self.search(self.pat_fwd, true),
                    'N' => self.search(!self.pat_fwd, true),
                    '/', '?' => {
                        if (self.prompt(s[0])) |p| {
                            if (p.len > 0) self.pat = p;
                            self.pat_fwd = s[0] == '/';
                            self.search(self.pat_fwd, false);
                        }
                    },
                    '=' => self.msg = std.fmt.allocPrint(u.alloc, "{s} lines {d}-{d}/{d}", .{ self.name, self.top + 1, @min(self.top + b, self.rows.items.len), self.rows.items.len }) catch "",
                    'Z' => {
                        const k2 = readKey() orelse return;
                        if (k2.len == 1 and k2[0] == 'Z') return;
                    },
                    'h', 'H' => self.msg = "SPACE/b page  j/k line  g/G ends  /? search  n/N repeat  q quit",
                    else => {},
                }
            } else if (std.mem.eql(u8, s, "\x1b[A") or std.mem.eql(u8, s, "\x1bOA")) {
                self.scrollTo(self.top -| 1);
            } else if (std.mem.eql(u8, s, "\x1b[B") or std.mem.eql(u8, s, "\x1bOB")) {
                self.scrollTo(self.top + 1);
            } else if (std.mem.eql(u8, s, "\x1b[6~")) {
                self.scrollTo(self.top + b);
            } else if (std.mem.eql(u8, s, "\x1b[5~")) {
                self.scrollTo(self.top -| b);
            } else if (std.mem.eql(u8, s, "\x1b[H") or std.mem.eql(u8, s, "\x1b[1~") or std.mem.eql(u8, s, "\x1bOH")) {
                self.top = 0;
            } else if (std.mem.eql(u8, s, "\x1b[F") or std.mem.eql(u8, s, "\x1b[4~") or std.mem.eql(u8, s, "\x1bOF")) {
                self.top = self.maxTop();
            }
            self.draw();
        }
    }
};

fn splitLines(data: []const u8) [][]const u8 {
    var ls = u.Vec([]const u8).init(u.alloc);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |l| {
        if (it.peek() == null and l.len == 0) break;
        ls.push(l);
    }
    return ls.items;
}

fn view(o: *const Opts, name: []const u8, data: []const u8) bool {
    var ws: Winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    _ = linux.ioctl(1, TIOCGWINSZ, @intFromPtr(&ws));
    const lines = splitLines(data);
    var p = Pager{ .o = o.*, .lines = lines, .rows = u.Vec(Row).init(u.alloc), .name = name };
    p.height = if (ws.row > 2) ws.row else 24;
    if (o.page_lines) |pl| p.height = pl + 1;
    p.width = if (ws.col > 4) ws.col else 80;
    buildRows(lines, o, p.width, &p.rows);
    if (o.quit_one and p.rows.items.len <= p.bodyRows()) {
        for (p.rows.items) |r| {
            u.out(r.text);
            u.out("\n");
        }
        return true;
    }
    if (o.start_line > 1) p.scrollTo(o.start_line - 1);
    if (o.start_pat) |sp| {
        p.pat = sp;
        p.top = 0;
        // first match at or after the top
        var i: usize = 0;
        while (i < p.rows.items.len) : (i += 1) if (p.rowHas(i)) {
            p.scrollTo(i);
            break;
        };
    }
    const alt = o.is_less and !o.no_init;
    if (alt) u.out("\x1b[?1049h");
    if (o.chop) u.out("\x1b[?7l");
    if (!alt) u.out("\x1b[2J");
    p.run();
    if (o.chop) u.out("\x1b[?7h");
    if (alt) u.out("\x1b[?1049l") else u.out("\r\x1b[K");
    return false;
}

fn catAll(files: []const []const u8, o: *const Opts) u8 {
    var rc: u8 = 0;
    const header = !o.is_less;
    if (files.len == 0) {
        var buf: [65536]u8 = undefined;
        while (true) {
            const r = linux.read(0, &buf, buf.len);
            if (u.errno(r) == .INTR) continue;
            if (!u.ok(r) or r == 0) break;
            u.out(buf[0..r]);
        }
        return 0;
    }
    for (files) |f| {
        const data = readOne(f, o) orelse {
            rc = if (o.is_less) 1 else 0; // util-linux more does not fail on unreadable files
            continue;
        };
        if (header and !std.mem.eql(u8, f, "-")) u.outf("::::::::::::::\n{s}\n::::::::::::::\n", .{f});
        u.out(data);
    }
    return rc;
}

fn readOne(f: []const u8, o: *const Opts) ?[]u8 {
    const prog: []const u8 = if (o.is_less) "less" else "more";
    if (std.mem.eql(u8, f, "-")) return input.read("-", true) orelse u.alloc.alloc(u8, 0) catch null;
    const st = u.stat(f, true) orelse {
        if (o.is_less) u.errf("{s}: No such file or directory\n", .{f}) else u.errf("{s}: cannot open {s}: No such file or directory\n", .{ prog, f });
        return null;
    };
    if (st.mode & linux.S.IFMT == linux.S.IFDIR) {
        if (o.is_less) u.errf("{s} is a directory\n", .{f}) else u.errf("\n*** {s}: directory ***\n\n", .{f});
        return null;
    }
    return input.read(f, true) orelse {
        if (o.is_less) u.errf("{s}: Permission denied\n", .{f}) else u.errf("{s}: cannot open {s}: Permission denied\n", .{ prog, f });
        return null;
    };
}

fn pagerMain(args_in: []const []const u8, is_less: bool) u8 {
    var o = Opts{ .is_less = is_less };
    // $LESS / $MORE hold default options, processed before the command line
    var merged = u.Vec([]const u8).init(u.alloc);
    if (u.getEnv(if (is_less) "LESS" else "MORE")) |env| {
        var tok = std.mem.tokenizeAny(u8, env, " \t");
        while (tok.next()) |t| if (t.len > 1 and (t[0] == '-' or t[0] == '+')) merged.push(t);
    }
    for (args_in) |a| merged.push(a);
    const args: []const []const u8 = merged.items;
    var files = u.Vec([]const u8).init(u.alloc);
    var i: usize = 0;
    var opts_done = false;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (opts_done or a.len < 2 or (a[0] != '-' and a[0] != '+')) {
            files.push(a);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            opts_done = true;
            continue;
        }
        if (a[0] == '+') {
            if (a.len > 1 and a[1] == '/') o.start_pat = a[2..] else o.start_line = std.fmt.parseInt(usize, a[1..], 10) catch 0;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--")) {
            const n = a[2..];
            if (std.mem.eql(u8, n, "help")) {
                if (!is_less) u.out(@embedFile("more_help.txt")) else u.outf("Usage: {s} [options] file...\n", .{"less"});
                return 0;
            } else if (std.mem.eql(u8, n, "version")) {
                if (!is_less) u.out("more from util-linux 2.41.5\n") else u.outf("{s} (cmdbox)\n", .{"less"});
                return 0;
            } else if (!is_less and std.mem.startsWith(u8, n, "lines")) {
                // --lines N / --lines=N
                if (std.mem.indexOfScalar(u8, n, '=') == null and i + 1 < args.len) i += 1;
                continue;
            } else if (std.mem.eql(u8, n, "LINE-NUMBERS")) o.numbers = true else if (std.mem.eql(u8, n, "chop-long-lines")) o.chop = true else if (std.mem.eql(u8, n, "RAW-CONTROL-CHARS")) o.raw = true else if (std.mem.eql(u8, n, "quit-if-one-screen")) o.quit_one = true else if (std.mem.eql(u8, n, "no-init")) o.no_init = true else if (std.mem.eql(u8, n, "ignore-case") or std.mem.eql(u8, n, "IGNORE-CASE")) o.icase = true else if (std.mem.eql(u8, n, "squeeze-blank-lines")) o.squeeze = true;
            continue;
        }
        var k: usize = 1;
        while (k < a.len) : (k += 1) {
            switch (a[k]) {
                'N' => o.numbers = true,
                'S' => o.chop = true,
                'R', 'r' => o.raw = true,
                'F' => o.quit_one = true,
                'X' => o.no_init = true,
                'i', 'I' => o.icase = true,
                's' => o.squeeze = true,
                'V' => {
                    if (!is_less) u.out("more from util-linux 2.41.5\n") else u.outf("{s} (cmdbox)\n", .{"less"});
                    return 0;
                },
                'h' => {
                    if (!is_less) u.out(@embedFile("more_help.txt")) else u.outf("Usage: {s} [options] file...\n", .{"less"});
                    return 0;
                },
                'n' => if (!is_less) {
                    // more -n <number>: lines per screenful
                    const val: []const u8 = if (k + 1 < a.len) a[k + 1 ..] else if (i + 1 < args.len) blk: {
                        i += 1;
                        break :blk args[i];
                    } else "";
                    o.page_lines = std.fmt.parseInt(usize, val, 10) catch null;
                    k = a.len;
                },
                'd', 'f', 'l', 'c', 'e', 'u' => {},
                'p', 'P', 't', 'T', 'o', 'O', 'y', 'z', 'x', 'j', 'b', 'h' + 128 => if (!is_less) {
                    // more: -p (clean-print) takes no argument
                } else {
                    // options taking an argument (rest of word or next arg)
                    var val: []const u8 = a[k + 1 ..];
                    if (val.len == 0 and i + 1 < args.len) {
                        i += 1;
                        val = args[i];
                    }
                    if (a[k] == 'p') {
                        if (is_less) o.start_pat = val else o.start_pat = val;
                    }
                    k = a.len;
                },
                '0'...'9' => {
                    if (!is_less) {
                        o.page_lines = std.fmt.parseInt(usize, a[k..], 10) catch null;
                        k = a.len;
                    }
                },
                else => {},
            }
        }
    }
    const out_tty = isTty(1);
    if (!out_tty) return catAll(files.items, &o);
    // interactive: key input from stdin, or /dev/tty when stdin is the data pipe
    var data_files = files;
    var from_stdin = false;
    if (files.items.len == 0) {
        if (isTty(0)) {
            u.errf("{s}: missing filename (\"{s} --help\" for help)\n", .{ if (is_less) "Missing filename (\"less --help\" for help)" else "Usage", if (is_less) "less" else "more" });
            return 1;
        }
        data_files.push("-");
        from_stdin = true;
    }
    tty_fd = 0;
    if (from_stdin or !isTty(0)) {
        const t = linux.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0);
        if (!u.ok(t)) return catAll(files.items, &o);
        tty_fd = @intCast(t);
    }
    var rc: u8 = 0;
    // read stdin first (before touching the terminal) so the pipe is drained
    var idx: usize = 0;
    while (idx < data_files.items.len) : (idx += 1) {
        const f = data_files.items[idx];
        const data = readOne(f, &o) orelse {
            rc = 1;
            continue;
        };
        if (!rawOn()) {
            u.out(data);
            continue;
        }
        const label: []const u8 = if (std.mem.eql(u8, f, "-")) "" else f;
        const quit = view(&o, label, data);
        rawOff();
        _ = quit;
        if (!o.is_less and idx + 1 < data_files.items.len) {}
    }
    return rc;
}

pub fn less(args: []const []const u8) u8 {
    return pagerMain(args, true);
}

pub fn more(args: []const []const u8) u8 {
    return pagerMain(args, false);
}
