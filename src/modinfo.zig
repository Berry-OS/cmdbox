// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// modinfo - kmod compatible: show .modinfo of kernel modules (plain, .xz, .gz, .bz2 and .zst), lookup by name or alias
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");

fn readFile(path: []const u8) ?[]u8 {
    const rc = linux.open(u.zstr(path), .{ .ACCMODE = .RDONLY }, 0);
    if (!u.ok(rc)) return null;
    defer _ = linux.close(@intCast(rc));
    var data = u.Vec(u8).init(u.alloc);
    var buf: [1 << 16]u8 = undefined;
    while (true) {
        const r = linux.read(@intCast(rc), &buf, buf.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r)) return null;
        if (r == 0) break;
        data.pushSlice(buf[0..r]);
    }
    return data.items;
}

fn runApplet(applet: []const u8, path: []const u8) ?[]u8 {
    var fds: [2]i32 = undefined;
    if (!u.ok(linux.pipe(&fds))) return null;
    const pid = linux.fork();
    if (!u.ok(pid)) return null;
    if (pid == 0) {
        _ = linux.close(fds[0]);
        _ = linux.dup2(fds[1], 1);
        _ = linux.close(fds[1]);
        var av = [_:null]?[*:0]const u8{ u.zstr(applet).ptr, u.zstr(path).ptr, null };
        _ = linux.execve("/proc/self/exe", &av, u.envp(&.{}));
        linux.exit_group(127);
    }
    _ = linux.close(fds[1]);
    var data = u.Vec(u8).init(u.alloc);
    var buf: [1 << 16]u8 = undefined;
    while (true) {
        const r = linux.read(fds[0], &buf, buf.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r) or r == 0) break;
        data.pushSlice(buf[0..r]);
    }
    _ = linux.close(fds[0]);
    var status: u32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
    if (status != 0) return null;
    return data.items;
}

fn zstdDecode(d: []const u8) ?[]u8 {
    const window: u32 = 1 << 26;
    const buf = u.alloc.alloc(u8, window + std.compress.zstd.block_size_max) catch return null;
    var in = std.Io.Reader.fixed(d);
    var dec = std.compress.zstd.Decompress.init(&in, buf, .{ .window_len = window });
    var out = u.Vec(u8).init(u.alloc);
    var tmp: [1 << 16]u8 = undefined;
    while (true) {
        const n = dec.reader.readSliceShort(&tmp) catch return null;
        if (n == 0) break;
        out.pushSlice(tmp[0..n]);
    }
    return out.items;
}

fn loadModule(path: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, path, ".xz")) return runApplet("xzcat", path);
    if (std.mem.endsWith(u8, path, ".gz")) return runApplet("zcat", path);
    if (std.mem.endsWith(u8, path, ".bz2")) return runApplet("bzcat", path);
    if (std.mem.endsWith(u8, path, ".zst")) {
        const d = readFile(path) orelse return null;
        return zstdDecode(d);
    }
    return readFile(path);
}

fn rd(d: []const u8, off: usize, n: usize, le: bool) ?u64 {
    if (off + n > d.len) return null;
    return if (le) std.mem.readVarInt(u64, d[off .. off + n], .little) else std.mem.readVarInt(u64, d[off .. off + n], .big);
}

/// returns the .modinfo section contents
fn modinfoSection(d: []const u8) ?[]const u8 {
    if (d.len < 64 or !std.mem.eql(u8, d[0..4], "\x7fELF")) return null;
    const is64 = d[4] == 2;
    const le = d[5] == 1;
    var shoff: u64 = 0;
    var shentsize: u64 = 0;
    var shnum: u64 = 0;
    var shstrndx: u64 = 0;
    if (is64) {
        shoff = rd(d, 0x28, 8, le) orelse return null;
        shentsize = rd(d, 0x3a, 2, le) orelse return null;
        shnum = rd(d, 0x3c, 2, le) orelse return null;
        shstrndx = rd(d, 0x3e, 2, le) orelse return null;
    } else {
        shoff = rd(d, 0x20, 4, le) orelse return null;
        shentsize = rd(d, 0x2e, 2, le) orelse return null;
        shnum = rd(d, 0x30, 2, le) orelse return null;
        shstrndx = rd(d, 0x32, 2, le) orelse return null;
    }
    const secHdr = struct {
        fn f(dd: []const u8, i: u64, so: u64, es: u64, big: bool, lel: bool) ?struct { name: u64, off: u64, size: u64 } {
            const b: usize = @intCast(so + i * es);
            if (big) return .{ .name = rd(dd, b, 4, lel) orelse return null, .off = rd(dd, b + 0x18, 8, lel) orelse return null, .size = rd(dd, b + 0x20, 8, lel) orelse return null };
            return .{ .name = rd(dd, b, 4, lel) orelse return null, .off = rd(dd, b + 0x10, 4, lel) orelse return null, .size = rd(dd, b + 0x14, 4, lel) orelse return null };
        }
    }.f;
    const strsec = secHdr(d, shstrndx, shoff, shentsize, is64, le) orelse return null;
    var i: u64 = 0;
    while (i < shnum) : (i += 1) {
        const sh = secHdr(d, i, shoff, shentsize, is64, le) orelse return null;
        const nstart: usize = @intCast(strsec.off + sh.name);
        if (nstart >= d.len) continue;
        const nm = std.mem.sliceTo(d[nstart..], 0);
        if (std.mem.eql(u8, nm, ".modinfo")) {
            const o: usize = @intCast(sh.off);
            const sz: usize = @intCast(sh.size);
            if (o + sz > d.len) return null;
            return d[o .. o + sz];
        }
    }
    return null;
}

const Entry = struct { key: []const u8, val: []const u8 };

fn parseEntries(sec: []const u8) []Entry {
    var out = u.Vec(Entry).init(u.alloc);
    var it = std.mem.splitScalar(u8, sec, 0);
    while (it.next()) |s| {
        if (s.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse continue;
        out.push(.{ .key = s[0..eq], .val = s[eq + 1 ..] });
    }
    return out.items;
}

fn normName(n: []const u8) []const u8 {
    const o = u.alloc.alloc(u8, n.len) catch return n;
    for (n, 0..) |ch, i| o[i] = if (ch == '-') '_' else ch;
    return o;
}

fn modNameOf(path: []const u8) []const u8 {
    var b = u.basename(path);
    if (std.mem.indexOf(u8, b, ".ko")) |i| b = b[0..i];
    return normName(b);
}

fn fnmatch(pat: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star_p: ?usize = null;
    var star_i: usize = 0;
    while (i < s.len) {
        if (p < pat.len and pat[p] == '*') {
            star_p = p;
            star_i = i;
            p += 1;
            continue;
        }
        if (p < pat.len and (pat[p] == '?' or pat[p] == s[i])) {
            p += 1;
            i += 1;
            continue;
        }
        if (star_p) |sp| {
            p = sp + 1;
            star_i += 1;
            i = star_i;
            continue;
        }
        return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

const Mod = struct { path: []const u8, name: []const u8 };

fn lookup(base: []const u8, kver: []const u8, arg: []const u8, use_alias: bool) []Mod {
    var out = u.Vec(Mod).init(u.alloc);
    const dir = std.fmt.allocPrint(u.alloc, "{s}/lib/modules/{s}", .{ if (base.len > 0) std.mem.trimEnd(u8, base, "/") else "", kver }) catch return out.items;
    if (readFile(std.fmt.allocPrint(u.alloc, "{s}/modules.dep", .{dir}) catch "")) |dep| {
        const want = normName(arg);
        var lines = std.mem.splitScalar(u8, dep, '\n');
        while (lines.next()) |l| {
            const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
            const rel = l[0..colon];
            if (std.mem.eql(u8, modNameOf(rel), want)) {
                const full = if (rel.len > 0 and rel[0] == '/') rel else (std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ dir, rel }) catch rel);
                out.push(.{ .path = full, .name = modNameOf(rel) });
            }
        }
    }
    if (out.items.len == 0 and use_alias) {
        // aliases: "alias <pattern> <module>"
        if (readFile(std.fmt.allocPrint(u.alloc, "{s}/modules.alias", .{dir}) catch "")) |al| {
            var seen = u.Vec([]const u8).init(u.alloc);
            var lines = std.mem.splitScalar(u8, al, '\n');
            while (lines.next()) |l| {
                if (!std.mem.startsWith(u8, l, "alias ")) continue;
                var it = std.mem.tokenizeScalar(u8, l[6..], ' ');
                const pat = it.next() orelse continue;
                const mod = it.next() orelse continue;
                if (!fnmatch(pat, arg)) continue;
                const nm = normName(mod);
                var dup = false;
                for (seen.items) |x| if (std.mem.eql(u8, x, nm)) {
                    dup = true;
                };
                if (dup) continue;
                seen.push(nm);
                // resolve through modules.dep
                for (lookup(base, kver, nm, false)) |m| out.push(m);
            }
        }
    }
    return out.items;
}

fn absPath(p: []const u8) []const u8 {
    if (p.len > 0 and p[0] == '/') return p;
    var buf: [u.PATH_MAX]u8 = undefined;
    const r = linux.getcwd(&buf, buf.len);
    if (!u.ok(r)) return p;
    const cwd = std.mem.sliceTo(&buf, 0);
    var rel = p;
    while (std.mem.startsWith(u8, rel, "./")) rel = rel[2..];
    return std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ cwd, rel }) catch p;
}

fn isPathLike(arg: []const u8) bool {
    if (std.mem.indexOfScalar(u8, arg, '/') != null) return true;
    if (std.mem.indexOf(u8, arg, ".ko") != null) return true;
    return false;
}

const usage_text =
    "Usage:\n" ++
    "\tmodinfo [options] <modulename|filename> [args]\n" ++
    "Options:\n" ++
    "\t-a, --author                Print only 'author'\n" ++
    "\t-d, --description           Print only 'description'\n" ++
    "\t-l, --license               Print only 'license'\n" ++
    "\t-p, --parameters            Print only 'parm'\n" ++
    "\t-n, --filename              Print only 'filename'\n" ++
    "\t-0, --null                  Use \\0 instead of \\n\n" ++
    "\t-m, --modname               Handle argument as module name instead of alias or filename\n" ++
    "\t-F, --field=FIELD           Print only provided FIELD\n" ++
    "\t-k, --set-version=VERSION   Use VERSION instead of `uname -r`\n" ++
    "\t-b, --basedir=DIR           Use DIR as filesystem root for /lib/modules\n" ++
    "\t-V, --version               Show version\n" ++
    "\t-h, --help                  Show this help\n";

pub fn run(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "author", .key = 'a' },
        .{ .name = "description", .key = 'd' },
        .{ .name = "license", .key = 'l' },
        .{ .name = "parameters", .key = 'p' },
        .{ .name = "filename", .key = 'n' },
        .{ .name = "null", .key = '0' },
        .{ .name = "field", .key = 'F', .arg = .req },
        .{ .name = "set-version", .key = 'k', .arg = .req },
        .{ .name = "basedir", .key = 'b', .arg = .req },
        .{ .name = "modname", .key = 'm' },
        .{ .name = "version", .key = 'V' },
        .{ .name = "help", .key = 'h' },
    };
    var p = g.Parser.init("modinfo", args, &opts);
    p.no_hint = true;
    var field: ?[]const u8 = null;
    var nul = false;
    var modname_only = false;
    var base: []const u8 = "";
    var kver: ?[]const u8 = null;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'a' => field = "author",
            'd' => field = "description",
            'l' => field = "license",
            'p' => field = "parm",
            'n' => field = "filename",
            '0' => nul = true,
            'F' => field = it.val,
            'k' => kver = it.val,
            'b' => base = it.val.?,
            'm' => modname_only = true,
            'V' => {
                u.out("kmod version 34.2\n+ZSTD +XZ +ZLIB +LIBCRYPTO\n");
                return 0;
            },
            'h' => {
                u.out(usage_text);
                return 0;
            },
            else => {},
        }
    }
    const ops = p.operands.items;
    if (ops.len == 0) {
        u.err("modinfo: ERROR: missing module or filename.\n");
        return 1;
    }
    var release: []const u8 = "";
    if (kver) |k| release = k else {
        const un = std.posix.uname();
        release = u.alloc.dupe(u8, std.mem.sliceTo(&un.release, 0)) catch "";
    }
    var rc: u8 = 0;
    const term: u8 = if (nul) 0 else '\n';
    for (ops) |arg| {
        var mods = u.Vec(Mod).init(u.alloc);
        if (!modname_only and isPathLike(arg) and u.stat(arg, true) != null) {
            mods.push(.{ .path = absPath(arg), .name = modNameOf(arg) });
        } else {
            for (lookup(base, release, arg, !modname_only)) |m| mods.push(m);
        }
        if (mods.items.len == 0) {
            if (modname_only) u.errf("modinfo: ERROR: Module name {s} not found.\n", .{arg}) else u.errf("modinfo: ERROR: Module {s} not found.\n", .{arg});
            rc = 1;
            continue;
        }
        for (mods.items) |m| {
            var out = u.Vec(u8).init(u.alloc);
            const emitKV = struct {
                fn f(o: *u.Vec(u8), key: []const u8, val: []const u8, t: u8) void {
                    o.pushSlice(key);
                    o.push(':');
                    var pad: usize = if (key.len < 15) 15 - key.len else 0;
                    while (pad > 0) : (pad -= 1) o.push(' ');
                    o.pushSlice(val);
                    o.push(t);
                }
            }.f;
            const data = loadModule(m.path);
            const sec = if (data) |dd| modinfoSection(dd) else null;
            if (field == null) emitKV(&out, "filename", m.path, term);
            if (sec == null) {
                u.errf("modinfo: ERROR: could not get modinfo from '{s}': Exec format error\n", .{m.name});
                u.out(out.items);
                rc = 1;
                continue;
            }
            const entries = parseEntries(sec.?);
            if (field) |f| {
                if (std.mem.eql(u8, f, "filename")) {
                    out.pushSlice(m.path);
                    out.push(term);
                } else if (std.mem.eql(u8, f, "parm")) {
                    for (parmLines(entries, true)) |l| {
                        out.pushSlice(l);
                        out.push(term);
                    }
                } else for (entries) |e| if (std.mem.eql(u8, e.key, f)) {
                    out.pushSlice(e.val);
                    out.push(term);
                };
            } else {
                for (entries) |e| {
                    if (std.mem.eql(u8, e.key, "parmtype") or std.mem.eql(u8, e.key, "parm")) continue;
                    emitKV(&out, e.key, e.val, term);
                }
                for (parmLines(entries, false)) |l| emitKV(&out, "parm", l, term);
            }
            u.out(out.items);
        }
    }
    return rc;
}

/// kmod keeps one record per parameter name (first seen in either "parm" or "parmtype"),
/// printed in reverse order of first appearance.
fn parmLines(entries: []const Entry, field_mode: bool) [][]const u8 {
    const Item = struct { name: []const u8, desc: ?[]const u8, ty: ?[]const u8 };
    var items = u.Vec(Item).init(u.alloc);
    for (entries) |e| {
        const is_parm = std.mem.eql(u8, e.key, "parm");
        if (!is_parm and !std.mem.eql(u8, e.key, "parmtype")) continue;
        const colon = std.mem.indexOfScalar(u8, e.val, ':') orelse continue;
        const name = e.val[0..colon];
        const rest = e.val[colon + 1 ..];
        var found: ?*Item = null;
        for (items.items) |*it| if (std.mem.eql(u8, it.name, name)) {
            found = it;
        };
        if (found == null) {
            items.push(.{ .name = name, .desc = null, .ty = null });
            found = &items.items[items.items.len - 1];
        }
        if (is_parm) found.?.desc = rest else found.?.ty = rest;
    }
    var out = u.Vec([]const u8).init(u.alloc);
    var i = items.items.len;
    while (i > 0) {
        i -= 1;
        const it = items.items[i];
        const line = if (it.desc) |d|
            (if (it.ty) |t| std.fmt.allocPrint(u.alloc, "{s}:{s} ({s})", .{ it.name, d, t }) else std.fmt.allocPrint(u.alloc, "{s}:{s}", .{ it.name, d }))
        else if (field_mode)
            std.fmt.allocPrint(u.alloc, "{s}: ({s})", .{ it.name, it.ty orelse "" })
        else
            std.fmt.allocPrint(u.alloc, "{s}:{s}", .{ it.name, it.ty orelse "" });
        out.push(line catch continue);
    }
    return out.items;
}
