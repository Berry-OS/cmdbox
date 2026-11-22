// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// passwd chpasswd - shadow-utils compatible account password tools
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const mnt = @import("mount.zig");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("pwd.h");
    @cInclude("termios.h");
    @cInclude("time.h");
});

extern fn crypt(key: [*:0]const u8, salt: [*:0]const u8) ?[*:0]u8;

// ---------------------------------------------------------------- files
const Entry = struct { name: []const u8, line: []const u8 };

fn rootPath(root: []const u8, p: []const u8) []const u8 {
    if (root.len == 0) return p;
    return std.fmt.allocPrint(u.alloc, "{s}{s}", .{ root, p }) catch p;
}

fn splitFields(line: []const u8) [][]const u8 {
    var out = u.Vec([]const u8).init(u.alloc);
    var it = std.mem.splitScalar(u8, line, ':');
    while (it.next()) |f| out.push(f);
    return out.items;
}

fn joinFields(f: []const []const u8) []const u8 {
    var o = u.Vec(u8).init(u.alloc);
    for (f, 0..) |x, i| {
        if (i > 0) o.push(':');
        o.pushSlice(x);
    }
    return o.items;
}

fn writeAtomic(path: []const u8, data: []const u8) bool {
    const tmp = std.fmt.allocPrint(u.alloc, "{s}+", .{path}) catch return false;
    const st = u.stat(path, true);
    const fd_rc = linux.open(u.zstr(tmp), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, if (st) |s0| @intCast(s0.mode & 0o7777) else 0o600);
    if (!u.ok(fd_rc)) return false;
    const fd: i32 = @intCast(fd_rc);
    var off: usize = 0;
    while (off < data.len) {
        const w = linux.write(fd, data.ptr + off, data.len - off);
        if (!u.ok(w)) {
            _ = linux.close(fd);
            return false;
        }
        off += w;
    }
    if (st) |s0| {
        _ = linux.fchmod(fd, @intCast(s0.mode & 0o7777));
        _ = linux.fchown(fd, s0.uid, s0.gid);
    }
    _ = linux.fsync(fd);
    _ = linux.close(fd);
    if (!u.ok(linux.rename(u.zstr(tmp).ptr, u.zstr(path).ptr))) return false;
    return true;
}

const Acct = struct {
    root: []const u8 = "",
    passwd_data: []const u8 = "",
    shadow_data: []const u8 = "",
    shadow_exists: bool = false,
};

fn loadAcct(root: []const u8) Acct {
    var a = Acct{ .root = root };
    a.passwd_data = mnt.readFile(rootPath(root, "/etc/passwd")) orelse "";
    if (mnt.readFile(rootPath(root, "/etc/shadow"))) |d| {
        a.shadow_data = d;
        a.shadow_exists = true;
    }
    return a;
}

fn findLine(data: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |l| {
        if (l.len == 0 or l[0] == '#') continue;
        const col = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        if (std.mem.eql(u8, l[0..col], name)) return l;
    }
    return null;
}

fn replaceLine(data: []const u8, name: []const u8, new_line: []const u8) []const u8 {
    var o = u.Vec(u8).init(u.alloc);
    var found = false;
    var it = std.mem.splitScalar(u8, data, '\n');
    var first = true;
    while (it.next()) |l| {
        if (it.peek() == null and l.len == 0) break;
        const col = std.mem.indexOfScalar(u8, l, ':');
        if (!first) o.push('\n');
        first = false;
        if (col != null and l.len > 0 and l[0] != '#' and std.mem.eql(u8, l[0..col.?], name)) {
            o.pushSlice(new_line);
            found = true;
        } else o.pushSlice(l);
    }
    if (!found) {
        if (!first) o.push('\n');
        o.pushSlice(new_line);
    }
    o.push('\n');
    return o.items;
}

fn today() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @divTrunc(@as(i64, @intCast(ts.sec)), 86400);
}

// ---------------------------------------------------------------- hashing
const salt_chars = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

fn randomSalt(n: usize) []const u8 {
    const buf = u.alloc.alloc(u8, n) catch return "saltsaltsaltsalt";
    const rnd = u.alloc.alloc(u8, n) catch return "saltsaltsaltsalt";
    _ = linux.getrandom(rnd.ptr, rnd.len, 0);
    for (rnd, 0..) |b, i| buf[i] = salt_chars[b & 63];
    return buf;
}

const Algo = enum { des, md5, sha256, sha512, blowfish };

fn parseAlgo(s: []const u8) ?Algo {
    var up: [16]u8 = undefined;
    if (s.len > up.len) return null;
    for (s, 0..) |ch, i| up[i] = std.ascii.toUpper(ch);
    const t = up[0..s.len];
    if (std.mem.eql(u8, t, "DES")) return .des;
    if (std.mem.eql(u8, t, "MD5")) return .md5;
    if (std.mem.eql(u8, t, "SHA256")) return .sha256;
    if (std.mem.eql(u8, t, "SHA512")) return .sha512;
    if (std.mem.eql(u8, t, "BLOWFISH")) return .blowfish;
    return null;
}

fn hashPassword(pw: []const u8, algo: Algo, rounds: ?u32) ?[]const u8 {
    var salt: []const u8 = undefined;
    switch (algo) {
        .des => salt = randomSalt(2),
        .md5 => salt = std.fmt.allocPrint(u.alloc, "$1${s}", .{randomSalt(8)}) catch return null,
        .sha256 => salt = if (rounds) |r| std.fmt.allocPrint(u.alloc, "$5$rounds={d}${s}", .{ r, randomSalt(16) }) catch return null else std.fmt.allocPrint(u.alloc, "$5${s}", .{randomSalt(16)}) catch return null,
        .sha512 => salt = if (rounds) |r| std.fmt.allocPrint(u.alloc, "$6$rounds={d}${s}", .{ r, randomSalt(16) }) catch return null else std.fmt.allocPrint(u.alloc, "$6${s}", .{randomSalt(16)}) catch return null,
        .blowfish => salt = std.fmt.allocPrint(u.alloc, "$2b${d:0>2}${s}", .{ rounds orelse 5, randomSalt(22) }) catch return null,
    }
    const r = crypt(u.zstr(pw).ptr, u.zstr(salt).ptr) orelse return null;
    const out = std.mem.span(r);
    if (out.len < 2 or out[0] == '*') return null;
    return u.alloc.dupe(u8, out) catch null;
}

// ---------------------------------------------------------------- terminal input
fn readPassword(prompt: []const u8) ?[]const u8 {
    var fd: i32 = 0;
    var tty_open = false;
    if (c.isatty(0) != 0) {
        fd = 0;
    } else {
        const rc = linux.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0);
        if (u.ok(rc)) {
            fd = @intCast(rc);
            tty_open = true;
        }
    }
    u.err(prompt);
    var old: c.struct_termios = undefined;
    var have_tio = false;
    if (c.isatty(fd) != 0 and c.tcgetattr(fd, &old) == 0) {
        var nt = old;
        nt.c_lflag &= ~@as(c_uint, c.ECHO);
        _ = c.tcsetattr(fd, c.TCSAFLUSH, &nt);
        have_tio = true;
    }
    var line = u.Vec(u8).init(u.alloc);
    var got = false;
    var b: [1]u8 = undefined;
    while (true) {
        const r = linux.read(fd, &b, 1);
        if (!u.ok(r) or r == 0) break;
        got = true;
        if (b[0] == '\n') break;
        line.push(b[0]);
    }
    if (have_tio) {
        _ = c.tcsetattr(fd, c.TCSAFLUSH, &old);
        u.err("\n");
    }
    if (tty_open) _ = linux.close(fd);
    if (!got) return null;
    return line.items;
}

// ---------------------------------------------------------------- passwd
const HELP: u8 = 200;

fn daysToDate(d: i64) [10]u8 {
    var buf: [10]u8 = undefined;
    // civil from days (Howard Hinnant)
    const z = d + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const dd = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    if (m <= 2) y += 1;
    _ = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(@mod(y, 10000))), @as(u32, @intCast(m)), @as(u32, @intCast(dd)) }) catch {};
    return buf;
}

fn statusLine(name: []const u8, shadow: ?[]const u8) []const u8 {
    if (shadow == null) return std.fmt.allocPrint(u.alloc, "{s} NP\n", .{name}) catch "";
    const f = splitFields(shadow.?);
    const hash: []const u8 = if (f.len > 1) f[1] else "";
    const st: []const u8 = if (hash.len == 0) "NP" else if (hash[0] == '!' or hash[0] == '*') "L" else "P";
    const lastchg: i64 = if (f.len > 2) (std.fmt.parseInt(i64, f[2], 10) catch -1) else -1;
    const dt = if (lastchg >= 0) daysToDate(lastchg) else "never     ".*;
    const g2 = struct {
        fn fld(fs: []const []const u8, i: usize) []const u8 {
            return if (i < fs.len and fs[i].len > 0) fs[i] else "-1";
        }
    }.fld;
    return std.fmt.allocPrint(u.alloc, "{s} {s} {s} {s} {s} {s} {s}\n", .{ name, st, std.mem.trim(u8, &dt, " "), g2(f, 3), g2(f, 4), g2(f, 5), g2(f, 6) }) catch "";
}

pub fn passwd(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "all", .key = 'a' },
        .{ .name = "delete", .key = 'd' },
        .{ .name = "expire", .key = 'e' },
        .{ .name = "help", .key = 'h' },
        .{ .name = "inactive", .key = 'i', .arg = .req },
        .{ .name = "keep-tokens", .key = 'k' },
        .{ .name = "lock", .key = 'l' },
        .{ .name = "mindays", .key = 'n', .arg = .req },
        .{ .name = "quiet", .key = 'q' },
        .{ .name = "repository", .key = 'r', .arg = .req },
        .{ .name = "root", .key = 'R', .arg = .req },
        .{ .name = "status", .key = 'S' },
        .{ .name = "unlock", .key = 'u' },
        .{ .name = "warndays", .key = 'w', .arg = .req },
        .{ .name = "maxdays", .key = 'x', .arg = .req },
        .{ .name = "stdin", .key = 's' },
    };
    var p = g.Parser.init("passwd", args, &opts);
    var all = false;
    var del = false;
    var expire = false;
    var lock = false;
    var unlock = false;
    var status = false;
    var quiet = false;
    var root: []const u8 = "";
    var inactive: ?[]const u8 = null;
    var mindays: ?[]const u8 = null;
    var warndays: ?[]const u8 = null;
    var maxdays: ?[]const u8 = null;
    while (p.next() catch return 2) |it| {
        switch (it.key) {
            'h' => {
                u.out("Usage: passwd [options] [LOGIN]\n\nOptions:\n  -a, --all                     report password status on all accounts\n  -d, --delete                  delete the password for the named account\n  -e, --expire                  force expire the password for the named account\n  -h, --help                    display this help message and exit\n  -k, --keep-tokens             change password only if expired\n  -i, --inactive INACTIVE       set password inactive after expiration\n                                to INACTIVE\n  -l, --lock                    lock the password of the named account\n  -n, --mindays MIN_DAYS        set minimum number of days before password\n                                change to MIN_DAYS\n  -q, --quiet                   quiet mode\n  -r, --repository REPOSITORY   change password in REPOSITORY repository\n  -R, --root CHROOT_DIR         directory to chroot into\n  -S, --status                  report password status on the named account\n  -u, --unlock                  unlock the password of the named account\n  -w, --warndays WARN_DAYS      set expiration warning days to WARN_DAYS\n  -x, --maxdays MAX_DAYS        set maximum number of days before password\n                                change to MAX_DAYS\n  --stdin                       read new token from stdin\n\n");
                return 0;
            },
            'a' => all = true,
            'd' => del = true,
            'e' => expire = true,
            'l' => lock = true,
            'u' => unlock = true,
            'S' => status = true,
            'q' => quiet = true,
            'R' => root = it.val.?,
            'i' => inactive = it.val,
            'n' => mindays = it.val,
            'w' => warndays = it.val,
            'x' => maxdays = it.val,
            else => {},
        }
    }
    const acct = loadAcct(root);
    const me_uid = c.getuid();
    if (all) {
        if (!status) {
            u.err("passwd: Option -a can only be used with -S\n");
            return 2;
        }
        if (me_uid != 0) {
            u.err("passwd: Permission denied.\n");
            return 1;
        }
        var lines = std.mem.splitScalar(u8, acct.passwd_data, '\n');
        while (lines.next()) |l| {
            if (l.len == 0 or l[0] == '#') continue;
            const col = std.mem.indexOfScalar(u8, l, ':') orelse continue;
            const nm = l[0..col];
            const shl = findLine(acct.shadow_data, nm);
            const pff = splitFields(l);
            if (shl == null and pff.len > 1 and !std.mem.eql(u8, pff[1], "x")) {
                const st: []const u8 = if (pff[1].len == 0) "NP" else if (pff[1][0] == '!' or pff[1][0] == '*') "L" else "P";
                u.outf("{s} {s} never -1 -1 -1 -1\n", .{ nm, st });
            } else u.out(statusLine(nm, shl));
        }
        return 0;
    }
    var user: []const u8 = undefined;
    if (p.operands.items.len > 1) {
        u.err("passwd: Too many arguments.\n");
        return 2;
    }
    if (p.operands.items.len == 1) user = p.operands.items[0] else {
        const pw = c.getpwuid(me_uid);
        if (pw == null) {
            u.errf("passwd: Cannot determine your user name.\n", .{});
            return 1;
        }
        user = u.alloc.dupe(u8, std.mem.span(pw.*.pw_name)) catch return 1;
    }
    const pline = findLine(acct.passwd_data, user) orelse {
        u.errf("passwd: user '{s}' does not exist\n", .{user});
        return 1;
    };
    const pf = splitFields(pline);
    const target_uid: u32 = if (pf.len > 2) (std.fmt.parseInt(u32, pf[2], 10) catch 0) else 0;
    if (me_uid != 0 and me_uid != target_uid) {
        u.errf("passwd: You may not view or modify password information for {s}.\n", .{user});
        return 1;
    }
    if (status) {
        const sh = findLine(acct.shadow_data, user);
        if (sh == null and pf.len > 1 and !std.mem.eql(u8, pf[1], "x")) {
            // password lives in /etc/passwd
            const st: []const u8 = if (pf[1].len == 0) "NP" else if (pf[1][0] == '!' or pf[1][0] == '*') "L" else "P";
            u.outf("{s} {s} never -1 -1 -1 -1\n", .{ user, st });
            return 0;
        }
        u.out(statusLine(user, sh));
        return 0;
    }
    const changing_aging = expire or lock or unlock or del or inactive != null or mindays != null or warndays != null or maxdays != null;
    if (changing_aging and me_uid != 0) {
        u.err("passwd: Permission denied.\n");
        return 1;
    }
    // work on the shadow entry (create one when only /etc/passwd knows the user)
    var sf: [][]const u8 = undefined;
    const old_sh = findLine(acct.shadow_data, user);
    const use_shadow = acct.shadow_exists and (old_sh != null or std.mem.eql(u8, pf[1], "x"));
    if (use_shadow) {
        if (old_sh) |l| sf = splitFields(l) else {
            var tmp = u.Vec([]const u8).init(u.alloc);
            for ([_][]const u8{ user, "!", "", "0", "99999", "7", "", "", "" }) |x| tmp.push(x);
            sf = tmp.items;
        }
    } else {
        var tmp = u.Vec([]const u8).init(u.alloc);
        for (pf) |x| tmp.push(x);
        sf = tmp.items;
    }
    // layout differences: passwd keeps the hash in field 1 as well
    while (sf.len < 9 and use_shadow) {
        var tmp = u.Vec([]const u8).init(u.alloc);
        for (sf) |x| tmp.push(x);
        tmp.push("");
        sf = tmp.items;
    }
    const hash_idx: usize = 1;
    var msg: []const u8 = "";
    if (lock) {
        if (sf[hash_idx].len == 0 or sf[hash_idx][0] != '!') sf[hash_idx] = std.fmt.allocPrint(u.alloc, "!{s}", .{sf[hash_idx]}) catch return 1;
        msg = "passwd: password expiry information changed.\n";
    } else if (unlock) {
        if (sf[hash_idx].len > 0 and sf[hash_idx][0] == '!') {
            if (sf[hash_idx].len == 1) {
                u.err("passwd: unlocking the password would result in a passwordless account.\nYou should set a password with usermod -p to unlock this user's password.\n");
                return 1;
            }
            sf[hash_idx] = sf[hash_idx][1..];
        }
        msg = "passwd: password expiry information changed.\n";
    } else if (del) {
        sf[hash_idx] = "";
        msg = "passwd: password expiry information changed.\n";
    }
    if (expire and use_shadow) {
        sf[2] = "0";
        msg = "passwd: password expiry information changed.\n";
    }
    if (use_shadow) {
        if (mindays) |v| {
            sf[3] = v;
            msg = "passwd: password expiry information changed.\n";
        }
        if (maxdays) |v| {
            sf[4] = v;
            msg = "passwd: password expiry information changed.\n";
        }
        if (warndays) |v| {
            sf[5] = v;
            msg = "passwd: password expiry information changed.\n";
        }
        if (inactive) |v| {
            sf[6] = v;
            msg = "passwd: password expiry information changed.\n";
        }
    }
    if (!changing_aging) {
        // interactive (or piped) password change
        if (me_uid != 0) {
            u.errf("Changing password for {s}.\n", .{user});
            const cur = readPassword("Current password: ") orelse return 1;
            const stored = sf[hash_idx];
            if (stored.len > 0 and stored[0] != '!' and stored[0] != '*') {
                const chk = crypt(u.zstr(cur).ptr, u.zstr(stored).ptr);
                if (chk == null or !std.mem.eql(u8, std.mem.span(chk.?), stored)) {
                    u.err("passwd: Authentication token manipulation error\npasswd: password unchanged\n");
                    return 10;
                }
            }
        }
        const pw1 = readPassword("New password: ") orelse return 10;
        const pw2 = readPassword("Retype new password: ") orelse return 10;
        if (!std.mem.eql(u8, pw1, pw2)) {
            u.err("Sorry, passwords do not match.\npasswd: Authentication token manipulation error\npasswd: password unchanged\n");
            return 10;
        }
        const h = hashPassword(pw1, .sha512, null) orelse {
            u.err("passwd: Authentication token manipulation error\npasswd: password unchanged\n");
            return 10;
        };
        sf[hash_idx] = h;
        if (use_shadow) sf[2] = std.fmt.allocPrint(u.alloc, "{d}", .{today()}) catch "0";
        msg = "passwd: password updated successfully\n";
    }
    const new_line = joinFields(sf);
    if (use_shadow) {
        if (!writeAtomic(rootPath(root, "/etc/shadow"), replaceLine(acct.shadow_data, user, new_line))) {
            u.err("passwd: cannot lock /etc/shadow; try again later.\n");
            return 1;
        }
    } else {
        if (!writeAtomic(rootPath(root, "/etc/passwd"), replaceLine(acct.passwd_data, user, new_line))) {
            u.err("passwd: cannot lock /etc/passwd; try again later.\n");
            return 1;
        }
    }
    if (!quiet) u.err(msg);
    return 0;
}

// ---------------------------------------------------------------- chpasswd
pub fn chpasswd(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "crypt-method", .key = 'c', .arg = .req },
        .{ .name = "encrypted", .key = 'e' },
        .{ .name = "help", .key = 'h' },
        .{ .name = "md5", .key = 'm' },
        .{ .name = "root", .key = 'R', .arg = .req },
        .{ .name = "sha-rounds", .key = 's', .arg = .req },
        .{ .name = "prefix", .key = 'P', .arg = .req },
    };
    var p = g.Parser.init("chpasswd", args, &opts);
    var algo: Algo = .sha512;
    var encrypted = false;
    var root: []const u8 = "";
    var rounds: ?u32 = null;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'h' => {
                u.out("Usage: chpasswd [options]\n\nOptions:\n  -c, --crypt-method METHOD     the crypt method (one of NONE DES MD5 SHA256 SHA512)\n  -e, --encrypted               supplied passwords are encrypted\n  -h, --help                    display this help message and exit\n  -m, --md5                     encrypt the clear text password using\n                                the MD5 algorithm\n  -R, --root CHROOT_DIR         directory to chroot into\n  -P, --prefix PREFIX_DIR       directory prefix\n  -s, --sha-rounds              number of SHA rounds for the SHA*\n                                crypt algorithms\n\n");
                return 0;
            },
            'c' => {
                if (std.ascii.eqlIgnoreCase(it.val.?, "NONE")) {
                    encrypted = true;
                } else algo = parseAlgo(it.val.?) orelse {
                    u.errf("chpasswd: unsupported crypt method: {s}\n", .{it.val.?});
                    return 1;
                };
            },
            'e' => encrypted = true,
            'm' => algo = .md5,
            'R', 'P' => root = it.val.?,
            's' => rounds = std.fmt.parseInt(u32, it.val.?, 10) catch {
                u.errf("chpasswd: invalid numeric argument '{s}'\n", .{it.val.?});
                return 1;
            },
            else => {},
        }
    }
    if (c.getuid() != 0) {
        u.err("chpasswd: Permission denied.\n");
        return 1;
    }
    const acct = loadAcct(root);
    var shadow = acct.shadow_data;
    var passwd_data = acct.passwd_data;
    var shadow_changed = false;
    var passwd_changed = false;
    // read all of stdin
    var input = u.Vec(u8).init(u.alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const r = linux.read(0, &buf, buf.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r) or r == 0) break;
        input.pushSlice(buf[0..r]);
    }
    var lineno: usize = 0;
    var errors = false;
    var lines = std.mem.splitScalar(u8, input.items, '\n');
    while (lines.next()) |l0| {
        const l = std.mem.trimEnd(u8, l0, "\r");
        if (l.len == 0 and lines.peek() == null) break;
        lineno += 1;
        const col = std.mem.indexOfScalar(u8, l, ':') orelse {
            u.errf("chpasswd: line {d}: missing new password\n", .{lineno});
            u.errf("chpasswd: error detected, changing password aborted\n", .{});
            u.errf("chpasswd: error detected, changes ignored\n", .{});
            return 1;
        };
        const user = l[0..col];
        const pw = l[col + 1 ..];
        const pline = findLine(passwd_data, user);
        if (pline == null) {
            u.errf("chpasswd: line {d}: user '{s}' does not exist\n", .{ lineno, user });
            errors = true;
            continue;
        }
        const hash = if (encrypted) pw else hashPassword(pw, algo, rounds) orelse {
            u.errf("chpasswd: line {d}: failed to crypt password with salt\n", .{lineno});
            errors = true;
            continue;
        };
        const pf = splitFields(pline.?);
        const sh = findLine(shadow, user);
        if (acct.shadow_exists and (sh != null or std.mem.eql(u8, pf[1], "x"))) {
            var sf: [][]const u8 = undefined;
            if (sh) |sl| sf = splitFields(sl) else {
                var tmp = u.Vec([]const u8).init(u.alloc);
                for ([_][]const u8{ user, "!", "", "", "99999", "7", "", "", "" }) |x| tmp.push(x);
                sf = tmp.items;
            }
            while (sf.len < 9) {
                var tmp = u.Vec([]const u8).init(u.alloc);
                for (sf) |x| tmp.push(x);
                tmp.push("");
                sf = tmp.items;
            }
            sf[1] = hash;
            sf[2] = std.fmt.allocPrint(u.alloc, "{d}", .{today()}) catch "0";
            shadow = replaceLine(shadow, user, joinFields(sf));
            shadow_changed = true;
        } else {
            var tmp = u.Vec([]const u8).init(u.alloc);
            for (pf) |x| tmp.push(x);
            tmp.items[1] = hash;
            passwd_data = replaceLine(passwd_data, user, joinFields(tmp.items));
            passwd_changed = true;
        }
    }
    if (errors) {
        u.err("chpasswd: error detected, changes ignored\n");
        return 1;
    }
    if (shadow_changed and !writeAtomic(rootPath(root, "/etc/shadow"), shadow)) {
        u.err("chpasswd: cannot lock /etc/shadow; try again later.\n");
        return 1;
    }
    if (passwd_changed and !writeAtomic(rootPath(root, "/etc/passwd"), passwd_data)) {
        u.err("chpasswd: cannot lock /etc/passwd; try again later.\n");
        return 1;
    }
    return 0;
}
