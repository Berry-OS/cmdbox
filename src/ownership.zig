// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// chown / chgrp with GNU coreutils semantics
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("grp.h");
});

const HELP: u8 = 200;
const VERSION: u8 = 201;
const O_DEREF: u8 = 140;
const O_NOPRES: u8 = 141;
const O_PRES: u8 = 142;
const O_REF: u8 = 143;
const O_FROM: u8 = 144;

const NONE: u32 = 0xffffffff;

const Cfg = struct {
    prog: []const u8,
    is_chgrp: bool,
    uid: u32 = NONE,
    gid: u32 = NONE,
    from_uid: u32 = NONE,
    from_gid: u32 = NONE,
    user_name: ?[]const u8 = null,
    group_name: ?[]const u8 = null,
    verbose: bool = false,
    changes: bool = false,
    quiet: bool = false,
    recurse: bool = false,
    deref: i8 = -1, // -1 default, 0 = -h, 1 = --dereference
    traverse: u8 = 'P', // H, L or P
    rc: u8 = 0,
};

fn userId(s: []const u8) ?u32 {
    if (c.getpwnam(u.zstr(s))) |p| return p.*.pw_uid;
    return numId(s);
}
fn groupId(s: []const u8) ?u32 {
    if (c.getgrnam(u.zstr(s))) |p| return p.*.gr_gid;
    return numId(s);
}
fn numId(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    for (s) |ch| if (ch < '0' or ch > '9') return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn nameOfUser(id: u32) []const u8 {
    if (c.getpwuid(id)) |p| return std.mem.sliceTo(p.*.pw_name, 0);
    return std.fmt.allocPrint(u.alloc, "{d}", .{id}) catch "?";
}
fn nameOfGroup(id: u32) []const u8 {
    if (c.getgrgid(id)) |p| return std.mem.sliceTo(p.*.gr_name, 0);
    return std.fmt.allocPrint(u.alloc, "{d}", .{id}) catch "?";
}

/// parse [OWNER][:[GROUP]] (also OWNER.GROUP). Returns false on error (message printed).
fn parseSpec(cfg: *Cfg, spec: []const u8, uid: *u32, gid: *u32, uname: *?[]const u8, gname: *?[]const u8) bool {
    uid.* = NONE;
    gid.* = NONE;
    var user: []const u8 = spec;
    var group: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, spec, ':')) |ci| {
        user = spec[0..ci];
        group = spec[ci + 1 ..];
    } else if (std.mem.indexOfScalar(u8, spec, '.')) |di| {
        // "user.group" only if the whole string is not itself a user name
        if (userId(spec) == null) {
            user = spec[0..di];
            group = spec[di + 1 ..];
        }
    }
    if (user.len > 0) {
        uid.* = userId(user) orelse {
            u.errf("{s}: invalid user: '{s}'\n", .{ cfg.prog, spec });
            return false;
        };
        uname.* = user;
    }
    if (group) |gs| {
        if (gs.len > 0) {
            gid.* = groupId(gs) orelse {
                u.errf("{s}: invalid group: '{s}'\n", .{ cfg.prog, spec });
                return false;
            };
            gname.* = gs;
        } else if (user.len > 0) {
            // "user:" => the user's login group
            const p = c.getpwnam(u.zstr(user)) orelse {
                u.errf("{s}: invalid spec: '{s}'\n", .{ cfg.prog, spec });
                return false;
            };
            gid.* = p.*.pw_gid;
            gname.* = nameOfGroup(p.*.pw_gid);
        }
    }
    return true;
}

fn describe(cfg: *Cfg, buf: *u.Vec(u8), uid: u32, gid: u32, have_u: bool, have_g: bool) void {
    if (cfg.is_chgrp) {
        for (nameOfGroup(gid)) |ch| buf.push(ch);
        return;
    }
    if (have_u) for (nameOfUser(uid)) |ch| buf.push(ch);
    if (have_g) {
        buf.push(':');
        for (nameOfGroup(gid)) |ch| buf.push(ch);
    }
}

fn report(cfg: *Cfg, path: []const u8, st: u.Stat, changed: bool, ok: bool) void {
    if (!cfg.verbose and !(cfg.changes and changed)) return;
    if (!ok and !changed) return;
    var o = u.Vec(u8).init(u.alloc);
    const what: []const u8 = if (cfg.is_chgrp) "group" else "ownership";
    const have_u = cfg.uid != NONE;
    const have_g = cfg.gid != NONE;
    const new_u = if (have_u) cfg.uid else st.uid;
    const new_g = if (have_g) cfg.gid else st.gid;
    var line: []const u8 = undefined;
    if (!ok) {
        // failure messages are printed by the caller
        return;
    }
    if (changed) {
        var from = u.Vec(u8).init(u.alloc);
        if (cfg.is_chgrp) {
            for (nameOfGroup(st.gid)) |ch| from.push(ch);
        } else {
            for (nameOfUser(st.uid)) |ch| from.push(ch);
            from.push(':');
            for (nameOfGroup(st.gid)) |ch| from.push(ch);
        }
        describe(cfg, &o, new_u, new_g, have_u, have_g);
        line = std.fmt.allocPrint(u.alloc, "changed {s} of '{s}' from {s} to {s}\n", .{ what, path, from.items, o.items }) catch return;
    } else {
        describe(cfg, &o, new_u, new_g, have_u, have_g);
        line = std.fmt.allocPrint(u.alloc, "{s} of '{s}' retained as {s}\n", .{ what, path, o.items }) catch return;
    }
    u.out(line);
}

fn visit(cfg: *Cfg, path: []const u8, cmdline: bool) void {
    var follow: bool = undefined;
    if (cfg.recurse) {
        follow = (cfg.traverse == 'L') or (cmdline and cfg.traverse == 'H');
        if (cfg.deref == 0) follow = false;
    } else {
        follow = cfg.deref != 0;
    }
    const st = u.stat(path, follow) orelse {
        if (!cfg.quiet) {
            u.errf("{s}: cannot access '{s}': {s}\n", .{ cfg.prog, path, u.strerr(lastStatErr(path, follow)) });
        }
        cfg.rc = 1;
        return;
    };
    var apply = true;
    if (cfg.from_uid != NONE and st.uid != cfg.from_uid) apply = false;
    if (cfg.from_gid != NONE and st.gid != cfg.from_gid) apply = false;
    if (apply) {
        const changed = (cfg.uid != NONE and st.uid != cfg.uid) or (cfg.gid != NONE and st.gid != cfg.gid);
        const rc = linux.fchownat(std.posix.AT.FDCWD, u.zstr(path), cfg.uid, cfg.gid, if (follow) 0 else 0x100);
        if (!u.ok(rc)) {
            if (!cfg.quiet) {
                const what: []const u8 = if (cfg.is_chgrp) "group" else "ownership";
                u.errf("{s}: changing {s} of '{s}': {s}\n", .{ cfg.prog, what, path, u.strerr(u.errno(rc)) });
            }
            cfg.rc = 1;
        } else {
            report(cfg, path, st, changed, true);
        }
    }
    if (cfg.recurse and st.mode & linux.S.IFMT == linux.S.IFDIR) {
        var ents = u.Vec(u.DirEnt).init(u.alloc);
        if (!u.listDir(path, &ents)) {
            if (!cfg.quiet) u.errf("{s}: cannot read directory '{s}': Permission denied\n", .{ cfg.prog, path });
            cfg.rc = 1;
            return;
        }
        for (ents.items) |e| {
            const child = if (std.mem.endsWith(u8, path, "/")) std.fmt.allocPrint(u.alloc, "{s}{s}", .{ path, e.name }) else std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ path, e.name });
            visit(cfg, child catch continue, false);
        }
    }
}

fn lastStatErr(path: []const u8, follow: bool) linux.E {
    var sx: linux.Statx = undefined;
    const rc = linux.statx(std.posix.AT.FDCWD, u.zstr(path), if (follow) 0 else 0x100, .{ .MODE = true }, &sx);
    return u.errno(rc);
}

fn runCommon(args: []const []const u8, is_chgrp: bool) u8 {
    const prog: []const u8 = if (is_chgrp) "chgrp" else "chown";
    const opts = [_]g.Opt{
        .{ .name = "changes", .key = 'c' },
        .{ .name = "silent", .key = 'f' },
        .{ .name = "quiet", .key = 'f' },
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "no-dereference", .key = 'h' },
        .{ .name = "dereference", .key = O_DEREF },
        .{ .name = "recursive", .key = 'R' },
        .{ .key = 'H' },
        .{ .key = 'L' },
        .{ .key = 'P' },
        .{ .name = "preserve-root", .key = O_PRES },
        .{ .name = "no-preserve-root", .key = O_NOPRES },
        .{ .name = "reference", .key = O_REF, .arg = .req },
        .{ .name = "from", .key = O_FROM, .arg = .req },
        .{ .name = "help", .key = HELP },
        .{ .name = "version", .key = VERSION },
    };
    var cfg = Cfg{ .prog = prog, .is_chgrp = is_chgrp };
    var p = g.Parser.init(prog, args, &opts);
    var ref: ?[]const u8 = null;
    var from: ?[]const u8 = null;
    var preserve_root = false;
    var trav_set = false;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'c' => cfg.changes = true,
            'f' => cfg.quiet = true,
            'v' => cfg.verbose = true,
            'h' => cfg.deref = 0,
            O_DEREF => cfg.deref = 1,
            'R' => cfg.recurse = true,
            'H', 'L', 'P' => {
                cfg.traverse = it.key;
                trav_set = true;
            },
            O_PRES => preserve_root = true,
            O_NOPRES => preserve_root = false,
            O_REF => ref = it.val,
            O_FROM => {
                if (is_chgrp) {
                    u.err("chgrp: unrecognized option '--from'\nTry 'chgrp --help' for more information.\n");
                    return 1;
                }
                from = it.val;
            },
            HELP => {
                u.outf("Usage: {s} [OPTION]... {s} FILE...\n  or:  {s} [OPTION]... --reference=RFILE FILE...\n", .{ prog, if (is_chgrp) "GROUP" else "[OWNER][:[GROUP]]", prog });
                return 0;
            },
            VERSION => {
                u.outf("{s} (cmdbox)\n", .{prog});
                return 0;
            },
            else => {},
        }
    }
    var ops = p.operands.items;
    if (ops.len == 0) return g.missingOperand(prog);
    if (cfg.recurse) {
        if (cfg.traverse == 'P' and cfg.deref == 1) {
            u.errf("{s}: -R --dereference requires either -H or -L\n", .{prog});
            return 1;
        }
    } else if (trav_set) {
        cfg.traverse = 'P'; // -H/-L/-P have no effect without -R
    }
    if (ref) |rp| {
        const st = u.stat(rp, true) orelse {
            u.errf("{s}: failed to get attributes of '{s}': No such file or directory\n", .{ prog, rp });
            return 1;
        };
        if (is_chgrp) {
            cfg.gid = st.gid;
        } else {
            cfg.uid = st.uid;
            cfg.gid = st.gid;
        }
        cfg.user_name = null;
    } else {
        if (ops.len < 2) {
            u.errf("{s}: missing operand after '{s}'\nTry '{s} --help' for more information.\n", .{ prog, ops[0], prog });
            return 1;
        }
        var un: ?[]const u8 = null;
        var gn: ?[]const u8 = null;
        if (is_chgrp) {
            if (ops[0].len > 0) {
                cfg.gid = groupId(ops[0]) orelse {
                    u.errf("chgrp: invalid group: '{s}'\n", .{ops[0]});
                    return 1;
                };
            }
        } else if (!parseSpec(&cfg, ops[0], &cfg.uid, &cfg.gid, &un, &gn)) return 1;
        ops = ops[1..];
    }
    if (from) |fs| {
        var un: ?[]const u8 = null;
        var gn: ?[]const u8 = null;
        var tu: u32 = NONE;
        var tg: u32 = NONE;
        if (!parseSpec(&cfg, fs, &tu, &tg, &un, &gn)) return 1;
        cfg.from_uid = tu;
        cfg.from_gid = tg;
    }
    for (ops) |path| {
        if (preserve_root and cfg.recurse and std.mem.eql(u8, std.mem.trimEnd(u8, path, "/"), "") and path.len > 0) {
            u.errf("{s}: it is dangerous to operate recursively on '/'\n{s}: use --no-preserve-root to override this failsafe\n", .{ prog, prog });
            return 1;
        }
        visit(&cfg, path, true);
    }
    return cfg.rc;
}

pub fn chown(args: []const []const u8) u8 {
    return runCommon(args, false);
}
pub fn chgrp(args: []const []const u8) u8 {
    return runCommon(args, true);
}
