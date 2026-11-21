// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// basic.zig - true false yes sync tee mkfifo mknod env which clear dirname pwd
// (GNU coreutils / debianutils semantics)
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const mode_mod = @import("mode.zig");

const HELP: u8 = 200;
const VERSION: u8 = 201;

fn common(prog: []const u8, key: u8, usage: []const u8) ?u8 {
    if (key == HELP) {
        u.out(usage);
        return 0;
    }
    if (key == VERSION) {
        u.outf("{s} (cmdbox)\n", .{prog});
        return 0;
    }
    return null;
}

const help_ver = [_]g.Opt{
    .{ .name = "help", .key = HELP },
    .{ .name = "version", .key = VERSION },
};

// ===================== true / false =====================
fn trivial(args: []const []const u8, prog: []const u8, code: u8) u8 {
    if (args.len == 1) {
        if (std.mem.eql(u8, args[0], "--help")) {
            u.outf("Usage: {s} [ignored command line arguments]\n  or:  {s} OPTION\nExit with a status code indicating {s}.\n", .{ prog, prog, if (code == 0) "success" else "failure" });
            return code;
        }
        if (std.mem.eql(u8, args[0], "--version")) {
            u.outf("{s} (cmdbox)\n", .{prog});
            return code;
        }
    }
    return code;
}
pub fn trueApp(args: []const []const u8) u8 {
    return trivial(args, "true", 0);
}
pub fn falseApp(args: []const []const u8) u8 {
    return trivial(args, "false", 1);
}

// ===================== yes =====================
pub fn yes(args: []const []const u8) u8 {
    var p = g.Parser.init("yes", args, &help_ver);
    while (p.next() catch return 1) |it| {
        if (common("yes", it.key, "Usage: yes [STRING]...\n  or:  yes OPTION\nRepeatedly output a line with all specified STRING(s), or 'y'.\n")) |r| return r;
    }
    var line = u.Vec(u8).init(u.alloc);
    if (p.operands.items.len == 0) {
        line.push('y');
    } else for (p.operands.items, 0..) |o, i| {
        if (i > 0) line.push(' ');
        for (o) |ch| line.push(ch);
    }
    line.push('\n');
    var buf = u.Vec(u8).init(u.alloc);
    while (buf.items.len + line.items.len <= 16384) {
        for (line.items) |ch| buf.push(ch);
    }
    if (buf.items.len == 0) buf = line;
    while (true) {
        var n: usize = 0;
        while (n < buf.items.len) {
            const rc = linux.write(1, buf.items.ptr + n, buf.items.len - n);
            switch (u.errno(rc)) {
                .SUCCESS => n += rc,
                .INTR => {},
                else => {
                    u.errf("yes: standard output: {s}\n", .{u.strerr(u.errno(rc))});
                    return 1;
                },
            }
        }
    }
}

// ===================== sync =====================
pub fn sync(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "data", .key = 'd' },
        .{ .name = "file-system", .key = 'f' },
        .{ .name = "help", .key = HELP },
        .{ .name = "version", .key = VERSION },
    };
    var p = g.Parser.init("sync", args, &opts);
    var data = false;
    var fs = false;
    while (p.next() catch return 1) |it| {
        if (common("sync", it.key, "Usage: sync [OPTION] [FILE]...\nSynchronize cached writes to persistent storage\n")) |r| return r;
        if (it.key == 'd') data = true else fs = true;
    }
    if (data and fs) {
        u.err("sync: cannot specify both --data and --file-system\n");
        return 1;
    }
    if (p.operands.items.len == 0) {
        if (data) {
            u.err("sync: --data needs at least one argument\n");
            return 1;
        }
        if (fs) {
            u.err("sync: --file-system needs at least one argument\n");
            return 1;
        }
        _ = linux.syscall0(.sync);
        return 0;
    }
    var rc: u8 = 0;
    for (p.operands.items) |path| {
        var fd = linux.open(u.zstr(path), .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOCTTY = true }, 0);
        if (!u.ok(fd)) fd = linux.open(u.zstr(path), .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .NOCTTY = true }, 0);
        if (!u.ok(fd)) {
            u.errf("sync: error opening '{s}': {s}\n", .{ path, u.strerr(u.errno(fd)) });
            rc = 1;
            continue;
        }
        const n: usize = fd;
        const r = if (fs) linux.syscall1(.syncfs, n) else if (data) linux.syscall1(.fdatasync, n) else linux.syscall1(.fsync, n);
        if (!u.ok(r)) {
            u.errf("sync: error syncing '{s}': {s}\n", .{ path, u.strerr(u.errno(r)) });
            rc = 1;
        }
        _ = linux.close(@intCast(n));
    }
    return rc;
}

// ===================== tee =====================
pub fn tee(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "append", .key = 'a' },
        .{ .name = "ignore-interrupts", .key = 'i' },
        .{ .key = 'p' },
        .{ .name = "output-error", .key = 'P', .arg = .opt },
        .{ .name = "help", .key = HELP },
        .{ .name = "version", .key = VERSION },
    };
    var p = g.Parser.init("tee", args, &opts);
    var append = false;
    while (p.next() catch return 1) |it| {
        if (common("tee", it.key, "Usage: tee [OPTION]... [FILE]...\nCopy standard input to each FILE, and also to standard output.\n")) |r| return r;
        switch (it.key) {
            'a' => append = true,
            'i' => {
                const sa = linux.Sigaction{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
                _ = linux.sigaction(linux.SIG.INT, &sa, null);
            },
            'P' => if (it.val) |v| {
                const okv = std.mem.eql(u8, v, "warn") or std.mem.eql(u8, v, "warn-nopipe") or std.mem.eql(u8, v, "exit") or std.mem.eql(u8, v, "exit-nopipe");
                if (!okv) {
                    u.errf("tee: invalid argument '{s}' for '--output-error'\nValid arguments are:\n  - 'warn'\n  - 'warn-nopipe'\n  - 'exit'\n  - 'exit-nopipe'\nTry 'tee --help' for more information.\n", .{v});
                    return 1;
                }
            },
            else => {},
        }
    }
    var rc: u8 = 0;
    var files = u.Vec(u.File).init(u.alloc);
    var names = u.Vec([]const u8).init(u.alloc);
    for (p.operands.items) |name| {
        const flags: std.posix.O = if (append)
            .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }
        else
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        const f = u.File.open(name, flags, 0o666) orelse {
            const probe = linux.open(u.zstr(name), flags, 0o666);
            u.errf("tee: {s}: {s}\n", .{ name, u.strerr(u.errno(probe)) });
            rc = 1;
            continue;
        };
        files.push(f);
        names.push(name);
    }
    const stdout = u.File{ .fd = 1 };
    var buf: [65536]u8 = undefined;
    const stdin = u.File{ .fd = 0 };
    var out_ok = true;
    while (true) {
        const n = stdin.read(&buf);
        if (n == 0) break;
        if (out_ok and !stdout.write(buf[0..n])) {
            out_ok = false;
            rc = 1;
        }
        for (files.items) |f| _ = f.write(buf[0..n]);
    }
    for (files.items) |f| f.close();
    return rc;
}

// ===================== mkfifo / mknod =====================
fn parseModeOpt(prog: []const u8, expr: []const u8, base: u32) ?u32 {
    const um = u.umask(0);
    _ = u.umask(um);
    return mode_mod.apply(expr, base, false, um) orelse {
        u.errf("{s}: invalid mode\n", .{prog});
        return null;
    };
}

pub fn mkfifo(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "mode", .key = 'm', .arg = .req },
        .{ .name = "context", .key = 'Z', .arg = .opt },
        .{ .name = "help", .key = HELP },
        .{ .name = "version", .key = VERSION },
    };
    var p = g.Parser.init("mkfifo", args, &opts);
    var mode: ?u32 = null;
    while (p.next() catch return 1) |it| {
        if (common("mkfifo", it.key, "Usage: mkfifo [OPTION]... NAME...\nCreate named pipes (FIFOs) with the given NAMEs.\n")) |r| return r;
        if (it.key == 'm') mode = parseModeOpt("mkfifo", it.val.?, 0o666) orelse return 1;
    }
    if (p.operands.items.len == 0) return g.missingOperand("mkfifo");
    var rc: u8 = 0;
    for (p.operands.items) |path| {
        const um = u.umask(0);
        _ = u.umask(um);
        const r = linux.mknod(u.zstr(path), linux.S.IFIFO | (0o666 & ~um), 0);
        if (!u.ok(r)) {
            u.errf("mkfifo: cannot create fifo '{s}': {s}\n", .{ path, u.strerr(u.errno(r)) });
            rc = 1;
            continue;
        }
        if (mode) |m| {
            if (!u.ok(linux.chmod(u.zstr(path), m))) {
                u.errf("mkfifo: cannot set permissions of '{s}': {s}\n", .{ path, u.strerr(u.errno(linux.chmod(u.zstr(path), m))) });
                rc = 1;
            }
        }
    }
    return rc;
}

fn devNum(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 0) catch null;
}

pub fn mknod(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "mode", .key = 'm', .arg = .req },
        .{ .name = "context", .key = 'Z', .arg = .opt },
        .{ .name = "help", .key = HELP },
        .{ .name = "version", .key = VERSION },
    };
    var p = g.Parser.init("mknod", args, &opts);
    var mode: ?u32 = null;
    while (p.next() catch return 1) |it| {
        if (common("mknod", it.key, "Usage: mknod [OPTION]... NAME TYPE [MAJOR MINOR]\nCreate the special file NAME of the given TYPE.\n")) |r| return r;
        if (it.key == 'm') mode = parseModeOpt("mknod", it.val.?, 0o666) orelse return 1;
    }
    const ops = p.operands.items;
    if (ops.len == 0) return g.missingOperand("mknod");
    if (ops.len == 1) {
        u.errf("mknod: missing operand after '{s}'\nSpecial files require major and minor device numbers.\nTry 'mknod --help' for more information.\n", .{ops[0]});
        return 1;
    }
    const t = ops[1];
    if (t.len != 1 or std.mem.indexOfScalar(u8, "bcup", t[0]) == null) {
        u.errf("mknod: invalid device type '{s}'\nTry 'mknod --help' for more information.\n", .{t});
        return 1;
    }
    var dev: u64 = 0;
    var typ: u32 = linux.S.IFIFO;
    if (t[0] == 'p') {
        if (ops.len > 2) {
            u.errf("mknod: extra operand '{s}'\nFifos do not have major and minor device numbers.\nTry 'mknod --help' for more information.\n", .{ops[2]});
            return 1;
        }
    } else {
        if (ops.len < 4) {
            if (ops.len == 2) u.errf("mknod: missing operand after '{s}'\n", .{t}) else u.errf("mknod: missing operand after '{s}'\n", .{ops[2]});
            u.err("Special files require major and minor device numbers.\nTry 'mknod --help' for more information.\n");
            return 1;
        }
        if (ops.len > 4) {
            u.errf("mknod: extra operand '{s}'\nTry 'mknod --help' for more information.\n", .{ops[4]});
            return 1;
        }
        const major = devNum(ops[2]) orelse {
            u.errf("mknod: invalid major device number '{s}'\nTry 'mknod --help' for more information.\n", .{ops[2]});
            return 1;
        };
        const minor = devNum(ops[3]) orelse {
            u.errf("mknod: invalid minor device number '{s}'\nTry 'mknod --help' for more information.\n", .{ops[3]});
            return 1;
        };
        dev = (@as(u64, major & 0xfff) << 8) | (minor & 0xff) | (@as(u64, minor & 0xffffff00) << 12) | (@as(u64, major & 0xfffff000) << 32);
        typ = if (t[0] == 'b') linux.S.IFBLK else linux.S.IFCHR;
    }
    const um = u.umask(0);
    _ = u.umask(um);
    const r = linux.mknod(u.zstr(ops[0]), typ | (0o666 & ~um), @truncate(dev));
    if (!u.ok(r)) {
        u.errf("mknod: {s}: {s}\n", .{ ops[0], u.strerr(u.errno(r)) });
        return 1;
    }
    if (mode) |m| {
        if (!u.ok(linux.chmod(u.zstr(ops[0]), m))) {
            u.errf("mknod: cannot set permissions of '{s}'\n", .{ops[0]});
            return 1;
        }
    }
    return 0;
}

// ===================== which =====================
pub fn which(args: []const []const u8) u8 {
    var all = false;
    var silent = false;
    var names = u.Vec([]const u8).init(u.alloc);
    var optsOn = true;
    for (args) |a| {
        if (optsOn and a.len > 1 and a[0] == '-') {
            if (std.mem.eql(u8, a, "--")) {
                optsOn = false;
                continue;
            }
            if (std.mem.eql(u8, a, "--all")) {
                all = true;
                continue;
            }
            if (std.mem.eql(u8, a, "--version")) {
                u.out("which (cmdbox)\n");
                return 0;
            }
            var okc = a[1] != '-';
            for (a[1..]) |ch| switch (ch) {
                'a' => all = true,
                's' => silent = true,
                else => okc = false,
            };
            if (!okc) {
                u.errf("Illegal option {s}\nUsage: which [-as] programname ...\n", .{a});
                return 2;
            }
            continue;
        }
        names.push(a);
    }
    if (names.items.len == 0) return 1;
    var allfound = true;
    var pathbuf: [u.PATH_MAX]u8 = undefined;
    const path_env = u.getEnv("PATH") orelse "";
    for (names.items) |name| {
        var found = false;
        if (std.mem.indexOfScalar(u8, name, '/') != null) {
            if (isExec(name)) {
                found = true;
                if (!silent) u.outf("{s}\n", .{name});
            }
        } else {
            var it = std.mem.splitScalar(u8, path_env, ':');
            while (it.next()) |dir| {
                const cand = std.fmt.bufPrint(&pathbuf, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name }) catch continue;
                if (isExec(cand)) {
                    found = true;
                    if (!silent) u.outf("{s}\n", .{cand});
                    if (!all) break;
                }
            }
        }
        if (!found) allfound = false;
    }
    return if (allfound) 0 else 1;
}

fn isExec(path: []const u8) bool {
    const st = u.stat(path, true) orelse return false;
    if (st.mode & linux.S.IFMT != linux.S.IFREG) return false;
    return u.ok(linux.access(u.zstr(path), 1));
}

// ===================== clear =====================
pub fn clear(args: []const []const u8) u8 {
    var scrollback = true;
    for (args) |a| {
        if (std.mem.eql(u8, a, "-x")) scrollback = false else if (std.mem.eql(u8, a, "-V")) {
            u.out("clear (cmdbox)\n");
            return 0;
        } else if (std.mem.eql(u8, a, "-T")) {} else if (a.len > 0 and a[0] == '-' and a.len > 1 and a[1] != 'T' and a[1] != 'x') {
            u.errf("clear: invalid option -- '{s}'\nusage: clear [-Tterminal] [-V] [-x]\n", .{a[1..]});
            return 1;
        }
    }
    u.out(if (scrollback) "\x1b[H\x1b[2J\x1b[3J" else "\x1b[H\x1b[2J");
    return 0;
}

// ===================== dirname =====================
fn dirLen(p: []const u8) usize {
    // coreutils dir_len() on Linux: a leading run of slashes is one root
    const prefix: usize = if (p.len > 0 and p[0] == '/') 1 else 0;
    // last component start
    var base: usize = prefix;
    var i: usize = prefix;
    var in_slash = true;
    while (i < p.len) : (i += 1) {
        if (p[i] == '/') {
            in_slash = true;
        } else if (in_slash) {
            base = i;
            in_slash = false;
        }
    }
    var len = base;
    while (len > prefix and p[len - 1] == '/') len -= 1;
    return len;
}

pub fn dirname(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "zero", .key = 'z' },
        .{ .name = "help", .key = HELP },
        .{ .name = "version", .key = VERSION },
    };
    var p = g.Parser.init("dirname", args, &opts);
    var zero = false;
    while (p.next() catch return 1) |it| {
        if (common("dirname", it.key, "Usage: dirname [OPTION] NAME...\nOutput each NAME with its last non-slash component and trailing slashes removed.\n")) |r| return r;
        zero = true;
    }
    if (p.operands.items.len == 0) return g.missingOperand("dirname");
    for (p.operands.items) |name| {
        const n = dirLen(name);
        if (n == 0) u.out(".") else u.out(name[0..n]);
        u.out(if (zero) &[_]u8{0} else "\n");
    }
    return 0;
}

// ===================== pwd =====================
pub fn pwd(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .key = 'L' },
        .{ .key = 'P' },
        .{ .name = "help", .key = HELP },
        .{ .name = "version", .key = VERSION },
    };
    var p = g.Parser.init("pwd", args, &opts);
    var logical = u.getEnv("POSIXLY_CORRECT") != null;
    while (p.next() catch return 1) |it| {
        if (common("pwd", it.key, "Usage: pwd [OPTION]...\nPrint the full filename of the current working directory.\n")) |r| return r;
        logical = it.key == 'L';
    }
    if (p.operands.items.len > 0) u.err("pwd: ignoring non-option arguments\n");
    var buf: [u.PATH_MAX]u8 = undefined;
    if (logical) {
        if (u.getEnv("PWD")) |w| {
            if (w.len > 0 and w[0] == '/' and !hasDots(w)) {
                const a = u.stat(w, true);
                const b = u.stat(".", true);
                if (a != null and b != null and a.?.ino == b.?.ino and a.?.dev == b.?.dev) {
                    u.outf("{s}\n", .{w});
                    return 0;
                }
            }
        }
    }
    const rc = linux.getcwd(&buf, buf.len);
    if (!u.ok(rc)) {
        u.errf("pwd: {s}\n", .{u.strerr(u.errno(rc))});
        return 1;
    }
    u.outf("{s}\n", .{std.mem.sliceTo(&buf, 0)});
    return 0;
}

fn hasDots(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |c| if (std.mem.eql(u8, c, ".") or std.mem.eql(u8, c, "..")) return true;
    return false;
}

// ===================== env =====================
fn entName(e: []const u8) []const u8 {
    return e[0 .. std.mem.indexOfScalar(u8, e, '=') orelse e.len];
}

fn put(entries: *u.Vec([]const u8), value: []const u8) void {
    const nm = entName(value);
    for (entries.items) |*e| {
        if (std.mem.eql(u8, entName(e.*), nm) and e.*.len > nm.len) {
            e.* = value;
            return;
        }
    }
    entries.push(value);
}

fn unset(entries: *u.Vec([]const u8), name: []const u8) void {
    var k: usize = 0;
    while (k < entries.items.len) {
        const e = entries.items[k];
        if (e.len > name.len and e[name.len] == '=' and std.mem.eql(u8, e[0..name.len], name)) {
            std.mem.copyForwards([]const u8, entries.items[k .. entries.items.len - 1], entries.items[k + 1 ..]);
            entries.items.len -= 1;
        } else k += 1;
    }
}

// split a -S string into arguments (whitespace, quotes, backslash escapes, #-comments)
fn splitString(s: []const u8, out_args: *u.Vec([]const u8)) bool {
    var i: usize = 0;
    var cur = u.Vec(u8).init(u.alloc);
    var have = false;
    while (i < s.len) {
        const ch = s[i];
        if (ch == ' ' or ch == '\t' or ch == '\n') {
            if (have) {
                out_args.push(cur.items);
                cur = u.Vec(u8).init(u.alloc);
                have = false;
            }
            i += 1;
        } else if (ch == '#' and !have) {
            break;
        } else if (ch == '\'') {
            i += 1;
            have = true;
            while (i < s.len and s[i] != '\'') : (i += 1) cur.push(s[i]);
            if (i >= s.len) {
                u.err("env: no terminating quote in -S string\n");
                return false;
            }
            i += 1;
        } else if (ch == '"') {
            i += 1;
            have = true;
            while (i < s.len and s[i] != '"') : (i += 1) {
                if (s[i] == '\\' and i + 1 < s.len) {
                    i += 1;
                    cur.push(escChar(s[i]));
                } else cur.push(s[i]);
            }
            if (i >= s.len) {
                u.err("env: no terminating quote in -S string\n");
                return false;
            }
            i += 1;
        } else if (ch == '\\' and i + 1 < s.len) {
            i += 1;
            if (s[i] == '_') {
                if (have) {
                    out_args.push(cur.items);
                    cur = u.Vec(u8).init(u.alloc);
                    have = false;
                }
            } else if (s[i] == 'c') {
                break;
            } else {
                cur.push(escChar(s[i]));
                have = true;
            }
            i += 1;
        } else {
            cur.push(ch);
            have = true;
            i += 1;
        }
    }
    if (have) out_args.push(cur.items);
    return true;
}

fn escChar(c: u8) u8 {
    return switch (c) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        'f' => 12,
        'v' => 11,
        'a' => 7,
        else => c,
    };
}

pub fn env(args_in: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "ignore-environment", .key = 'i' },
        .{ .name = "null", .key = '0' },
        .{ .name = "unset", .key = 'u', .arg = .req },
        .{ .name = "chdir", .key = 'C', .arg = .req },
        .{ .name = "split-string", .key = 'S', .arg = .req },
        .{ .name = "debug", .key = 'v' },
        .{ .name = "default-signal", .key = 130, .arg = .opt },
        .{ .name = "ignore-signal", .key = 131, .arg = .opt },
        .{ .name = "block-signal", .key = 132, .arg = .opt },
        .{ .name = "list-signal-handling", .key = 133 },
        .{ .name = "help", .key = HELP },
        .{ .name = "version", .key = VERSION },
    };
    // a lone "-" means -i
    var norm = u.Vec([]const u8).init(u.alloc);
    var dashdash = false;
    for (args_in) |a| {
        if (!dashdash and std.mem.eql(u8, a, "--")) dashdash = true;
        if (!dashdash and std.mem.eql(u8, a, "-")) norm.push("-i") else norm.push(a);
        if (!dashdash and a.len > 0 and a[0] != '-') {
            // first operand: copy the rest untouched
            dashdash = true;
        }
    }
    var args = norm.items;
    // -S expansion: replace the -S argument by its split words
    var expanded = u.Vec([]const u8).init(u.alloc);
    {
        var k: usize = 0;
        var seen_operand = false;
        while (k < args.len) : (k += 1) {
            const a = args[k];
            if (seen_operand or std.mem.eql(u8, a, "--")) {
                expanded.push(a);
                seen_operand = true;
                continue;
            }
            var sval: ?[]const u8 = null;
            if (std.mem.eql(u8, a, "-S") or std.mem.eql(u8, a, "--split-string")) {
                if (k + 1 >= args.len) {
                    u.err("env: option requires an argument -- 'S'\nTry 'env --help' for more information.\n");
                    return 125;
                }
                k += 1;
                sval = args[k];
            } else if (std.mem.startsWith(u8, a, "--split-string=")) {
                sval = a["--split-string=".len..];
            } else if (a.len > 2 and a[0] == '-' and a[1] == 'S') {
                sval = a[2..];
            }
            if (sval) |sv| {
                if (!splitString(sv, &expanded)) return 125;
                continue;
            }
            if (a.len == 0 or a[0] != '-') seen_operand = true;
            expanded.push(a);
        }
        args = expanded.items;
    }
    var p = g.Parser.init("env", args, &opts);
    p.stop_at_operand = true;
    var entries = u.Vec([]const u8).init(u.alloc);
    var ignore = false;
    var null_term = false;
    var chdir_to: ?[]const u8 = null;
    var unsets = u.Vec([]const u8).init(u.alloc);
    var debug = false;
    while (p.next() catch return 125) |it| {
        if (common("env", it.key, "Usage: env [OPTION]... [-] [NAME=VALUE]... [COMMAND [ARG]...]\nSet each NAME to VALUE in the environment and run COMMAND.\n")) |r| return r;
        switch (it.key) {
            'i' => ignore = true,
            '0' => null_term = true,
            'u' => unsets.push(it.val.?),
            'C' => chdir_to = it.val.?,
            'v' => debug = true,
            else => {},
        }
    }
    if (!ignore) {
        for (u.raw_env) |kv| if (kv) |value| put(&entries, std.mem.sliceTo(value, 0));
        for (u.extra_env[0..u.extra_env_n], 0..) |kv, index| {
            if (u.extra_exported[index]) put(&entries, kv);
        }
    }
    for (unsets.items) |nm| {
        if (nm.len == 0 or std.mem.indexOfScalar(u8, nm, '=') != null) {
            u.errf("env: cannot unset '{s}': Invalid argument\n", .{nm});
            return 125;
        }
        unset(&entries, nm);
    }
    var rest = p.rest();
    while (rest.len > 0) {
        const eq = std.mem.indexOfScalar(u8, rest[0], '=') orelse break;
        if (eq == 0) break;
        put(&entries, rest[0]);
        if (debug) u.errf("setenv:   {s}\n", .{rest[0]});
        rest = rest[1..];
    }
    if (rest.len == 0) {
        if (chdir_to != null) {
            u.err("env: must specify command with --chdir (-C)\nTry 'env --help' for more information.\n");
            return 125;
        }
        var o = u.Vec(u8).init(u.alloc);
        for (entries.items) |kv| {
            for (kv) |ch| o.push(ch);
            o.push(if (null_term) 0 else '\n');
        }
        u.out(o.items);
        return 0;
    }
    if (null_term) {
        u.err("env: cannot specify --null (-0) with command\nTry 'env --help' for more information.\n");
        return 125;
    }
    if (chdir_to) |d| {
        if (!u.ok(linux.chdir(u.zstr(d)))) {
            u.errf("env: cannot change directory to '{s}': {s}\n", .{ d, u.strerr(u.errno(linux.chdir(u.zstr(d)))) });
            return 125;
        }
    }
    var av = u.Vec(?[*:0]const u8).init(u.alloc);
    for (rest) |arg| av.push(u.zstr(arg).ptr);
    av.push(null);
    var ev = u.Vec(?[*:0]const u8).init(u.alloc);
    var path: []const u8 = "/bin:/usr/bin";
    for (entries.items) |kv| {
        ev.push(u.zstr(kv).ptr);
        if (kv.len >= 5 and std.mem.eql(u8, kv[0..5], "PATH=")) path = kv[5..];
    }
    ev.push(null);
    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(av.items.ptr);
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(ev.items.ptr);
    var code: u8 = 127;
    var last_err: linux.E = .NOENT;
    if (std.mem.indexOfScalar(u8, rest[0], '/') != null) {
        const rc = linux.execve(u.zstr(rest[0]), argv, envp);
        last_err = u.errno(rc);
    } else {
        var dirs = std.mem.splitScalar(u8, path, ':');
        var tried = false;
        while (dirs.next()) |dir| {
            var buf: [u.PATH_MAX]u8 = undefined;
            const cand = std.fmt.bufPrint(&buf, "{s}/{s}", .{ if (dir.len == 0) "." else dir, rest[0] }) catch continue;
            const rc = linux.execve(u.zstr(cand), argv, envp);
            const e = u.errno(rc);
            if (e != .NOENT and e != .NOTDIR) {
                last_err = e;
                tried = true;
                if (e == .ACCES) continue;
                break;
            }
        }
        if (!tried) last_err = .NOENT;
    }
    if (last_err != .NOENT) code = 126;
    u.errf("env: '{s}': {s}\n", .{ rest[0], u.strerr(last_err) });
    return code;
}

// ===================== nice =====================
const cn = @cImport({
    @cInclude("unistd.h");
    @cInclude("errno.h");
});

pub fn nice(args_in: []const []const u8) u8 {
    var adj: c_int = 10;
    var have_adj = false;
    var args = args_in;
    // legacy "-N" / "--N" forms
    if (args.len > 0 and args[0].len > 1 and args[0][0] == '-') {
        const a = args[0];
        const body = if (a.len > 2 and a[1] == '-') a[2..] else a[1..];
        const neg = a.len > 2 and a[1] == '-';
        var digits = body.len > 0;
        for (body) |ch| if (ch < '0' or ch > '9') {
            digits = false;
        };
        if (digits) {
            const v = std.fmt.parseInt(c_int, body, 10) catch 0;
            adj = if (neg) -v else v;
            have_adj = true;
            args = args[1..];
        }
    }
    const opts = [_]g.Opt{
        .{ .name = "adjustment", .key = 'n', .arg = .req },
        .{ .name = "help", .key = HELP },
        .{ .name = "version", .key = VERSION },
    };
    var p = g.Parser.init("nice", args, &opts);
    p.stop_at_operand = true;
    while (p.next() catch return 125) |it| {
        if (common("nice", it.key, "Usage: nice [OPTION] [COMMAND [ARG]...]\nRun COMMAND with an adjusted niceness.\n")) |r| return r;
        const v = it.val.?;
        adj = std.fmt.parseInt(c_int, std.mem.trimStart(u8, v, "+"), 10) catch {
            u.errf("nice: invalid adjustment '{s}'\nTry 'nice --help' for more information.\n", .{v});
            return 125;
        };
        have_adj = true;
    }
    const rest = p.rest();
    if (rest.len == 0) {
        if (have_adj) {
            u.err("nice: a command must be given with an adjustment\nTry 'nice --help' for more information.\n");
            return 125;
        }
        cn.__errno_location().* = 0;
        const cur = cn.nice(0);
        if (cur == -1 and cn.__errno_location().* != 0) {
            u.errf("nice: cannot get niceness: {s}\n", .{u.strerr(@enumFromInt(cn.__errno_location().*))});
            return 125;
        }
        u.outf("{d}\n", .{cur});
        return 0;
    }
    cn.__errno_location().* = 0;
    _ = cn.nice(adj);
    const err = cn.__errno_location().*;
    if (err != 0) {
        u.errf("nice: cannot set niceness: {s}\n", .{u.strerr(@enumFromInt(err))});
        if (err != cn.EPERM and err != cn.EACCES) return 125;
    }
    const av = u.alloc.allocSentinel(?[*:0]const u8, rest.len, null) catch return 125;
    for (rest, 0..) |arg, k| av[k] = u.zstr(arg).ptr;
    const envp = u.envp(&.{});
    var code: u8 = 127;
    var last: linux.E = .NOENT;
    if (std.mem.indexOfScalar(u8, rest[0], '/') != null) {
        last = u.errno(linux.execve(u.zstr(rest[0]), @ptrCast(av.ptr), envp));
    } else {
        const path_env = u.getEnv("PATH") orelse "/bin:/usr/bin";
        var dirs = std.mem.splitScalar(u8, path_env, ':');
        while (dirs.next()) |dir| {
            var buf: [u.PATH_MAX]u8 = undefined;
            const cand = std.fmt.bufPrint(&buf, "{s}/{s}", .{ if (dir.len == 0) "." else dir, rest[0] }) catch continue;
            const e = u.errno(linux.execve(u.zstr(cand), @ptrCast(av.ptr), envp));
            if (e != .NOENT and e != .NOTDIR) {
                last = e;
                break;
            }
        }
    }
    if (last != .NOENT) code = 126;
    u.errf("nice: '{s}': {s}\n", .{ rest[0], u.strerr(last) });
    return code;
}
