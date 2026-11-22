// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// dpkg - status database, queries (-l -s -L -S -p --print-architecture --compare-versions) and
// .deb installation / removal (-i -r -P --unpack/--configure are folded into -i)
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const mnt = @import("mount.zig");

var admindir: []const u8 = "/var/lib/dpkg";
var instdir: []const u8 = "";
var rootdir: []const u8 = "";

// ---------------------------------------------------------------- version comparison
fn order(c: u8) i32 {
    if (std.ascii.isDigit(c)) return 0;
    if (std.ascii.isAlphabetic(c)) return c;
    if (c == '~') return -1;
    if (c != 0) return @as(i32, c) + 256;
    return 0;
}

fn verrevcmp(a0: []const u8, b0: []const u8) i32 {
    var a = a0;
    var b = b0;
    while (a.len > 0 or b.len > 0) {
        var first_diff: i32 = 0;
        while ((a.len > 0 and !std.ascii.isDigit(a[0])) or (b.len > 0 and !std.ascii.isDigit(b[0]))) {
            const ac: i32 = if (a.len > 0) order(a[0]) else 0;
            const bc: i32 = if (b.len > 0) order(b[0]) else 0;
            if (ac != bc) return ac - bc;
            if (a.len > 0) a = a[1..];
            if (b.len > 0) b = b[1..];
        }
        while (a.len > 0 and a[0] == '0') a = a[1..];
        while (b.len > 0 and b[0] == '0') b = b[1..];
        while (a.len > 0 and std.ascii.isDigit(a[0]) and b.len > 0 and std.ascii.isDigit(b[0])) {
            if (first_diff == 0) first_diff = @as(i32, a[0]) - @as(i32, b[0]);
            a = a[1..];
            b = b[1..];
        }
        if (a.len > 0 and std.ascii.isDigit(a[0])) return 1;
        if (b.len > 0 and std.ascii.isDigit(b[0])) return -1;
        if (first_diff != 0) return first_diff;
    }
    return 0;
}

const Ver = struct { epoch: u32, version: []const u8, revision: []const u8 };

fn parseVer(s: []const u8) Ver {
    var v = Ver{ .epoch = 0, .version = s, .revision = "" };
    if (std.mem.indexOfScalar(u8, s, ':')) |c| {
        v.epoch = std.fmt.parseInt(u32, s[0..c], 10) catch 0;
        v.version = s[c + 1 ..];
    }
    if (std.mem.lastIndexOfScalar(u8, v.version, '-')) |h| {
        v.revision = v.version[h + 1 ..];
        v.version = v.version[0..h];
    }
    return v;
}

pub fn versionCompare(a: []const u8, b: []const u8) i32 {
    const x = parseVer(a);
    const y = parseVer(b);
    if (x.epoch != y.epoch) return if (x.epoch > y.epoch) 1 else -1;
    const r = verrevcmp(x.version, y.version);
    if (r != 0) return r;
    return verrevcmp(x.revision, y.revision);
}

// ---------------------------------------------------------------- status database
const Pkg = struct { name: []const u8, fields: std.StringHashMapUnmanaged([]const u8) = .{}, order: u.Vec([]const u8), raw: []const u8 };

fn parseStanzas(data: []const u8) []Pkg {
    var out = u.Vec(Pkg).init(u.alloc);
    var it = std.mem.splitSequence(u8, data, "\n\n");
    while (it.next()) |st0| {
        const st = std.mem.trim(u8, st0, "\n");
        if (st.len == 0) continue;
        var p = Pkg{ .name = "", .order = u.Vec([]const u8).init(u.alloc), .raw = st };
        var cur_key: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, st, '\n');
        while (lines.next()) |l| {
            if (l.len == 0) continue;
            if (l[0] == ' ' or l[0] == '\t') {
                if (cur_key) |k| {
                    const prev = p.fields.get(k) orelse "";
                    p.fields.put(u.alloc, k, std.fmt.allocPrint(u.alloc, "{s}\n{s}", .{ prev, l }) catch prev) catch {};
                }
                continue;
            }
            const col = std.mem.indexOfScalar(u8, l, ':') orelse continue;
            const key = u.alloc.dupe(u8, l[0..col]) catch continue;
            const val = std.mem.trim(u8, l[col + 1 ..], " \t");
            p.fields.put(u.alloc, key, u.alloc.dupe(u8, val) catch val) catch {};
            p.order.push(key);
            cur_key = key;
        }
        p.name = p.fields.get("Package") orelse continue;
        out.push(p);
    }
    return out.items;
}

fn statusPath() []const u8 {
    return std.fmt.allocPrint(u.alloc, "{s}{s}/status", .{ rootdir, admindir }) catch "";
}

fn loadStatus() []Pkg {
    return parseStanzas(mnt.readFile(statusPath()) orelse "");
}

fn fld(p: Pkg, k: []const u8) []const u8 {
    return p.fields.get(k) orelse "";
}

fn pkgStatusWord(p: Pkg) []const u8 {
    return p.fields.get("Status") orelse @as([]const u8, "unknown ok not-installed");
}

fn isInstalled(p: Pkg) bool {
    const s = pkgStatusWord(p);
    return std.mem.endsWith(u8, s, " installed");
}

fn saveStatus(pkgs: []const Pkg) bool {
    var o = u.Vec(u8).init(u.alloc);
    for (pkgs) |p| {
        o.pushSlice(p.raw);
        o.pushSlice("\n\n");
    }
    const path = statusPath();
    const tmp = std.fmt.allocPrint(u.alloc, "{s}-new", .{path}) catch return false;
    const rc = linux.open(u.zstr(tmp), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (!u.ok(rc)) return false;
    var off: usize = 0;
    while (off < o.items.len) {
        const w = linux.write(@intCast(rc), o.items.ptr + off, o.items.len - off);
        if (!u.ok(w)) {
            _ = linux.close(@intCast(rc));
            return false;
        }
        off += w;
    }
    _ = linux.close(@intCast(rc));
    return u.ok(linux.rename(u.zstr(tmp).ptr, u.zstr(path).ptr));
}

fn findPkg(pkgs: []const Pkg, name: []const u8) ?usize {
    for (pkgs, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) return i;
    return null;
}

// ---------------------------------------------------------------- queries
fn globMatch(pat: []const u8, s: []const u8) bool {
    const c = @cImport({
        @cInclude("fnmatch.h");
    });
    return c.fnmatch(u.zstr(pat).ptr, u.zstr(s).ptr, 0) == 0;
}

fn firstLine(s: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
    return s[0..nl];
}

fn listPackages(patterns: []const []const u8) u8 {
    const pkgs = loadStatus();
    var rows = u.Vec(Pkg).init(u.alloc);
    for (pkgs) |p| {
        if (patterns.len > 0) {
            var hit = false;
            for (patterns) |pt| if (globMatch(pt, p.name)) {
                hit = true;
            };
            if (!hit) continue;
        } else if (std.mem.endsWith(u8, pkgStatusWord(p), "not-installed") or std.mem.endsWith(u8, pkgStatusWord(p), " config-files") and false) continue;
        rows.push(p);
    }
    std.mem.sort(Pkg, rows.items, {}, struct {
        fn lt(_: void, a: Pkg, b: Pkg) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    if (rows.items.len == 0 and patterns.len > 0) {
        for (patterns) |pt| u.errf("dpkg-query: no packages found matching {s}\n", .{pt});
        return 1;
    }
    var wname: usize = 4;
    var wver: usize = 7;
    var warch: usize = 12;
    for (rows.items) |p| {
        wname = @max(wname, p.name.len);
        wver = @max(wver, fld(p, "Version").len);
        warch = @max(warch, fld(p, "Architecture").len);
    }
    u.out("Desired=Unknown/Install/Remove/Purge/Hold\n| Status=Not/Inst/Conf-files/Unpacked/halF-conf/Half-inst/trig-aWait/Trig-pend\n|/ Err?=(none)/Reinst-required (Status,Err: uppercase=bad)\n");
    var hdr = u.Vec(u8).init(u.alloc);
    hdr.pushSlice("||/ ");
    hdr.pushSlice(padR("Name", wname));
    hdr.push(' ');
    hdr.pushSlice(padR("Version", wver));
    hdr.push(' ');
    hdr.pushSlice(padR("Architecture", warch));
    hdr.pushSlice(" Description\n");
    u.out(hdr.items);
    var sep = u.Vec(u8).init(u.alloc);
    sep.pushSlice("+++-");
    sep.pushN('=', wname);
    sep.push('-');
    sep.pushN('=', wver);
    sep.push('-');
    sep.pushN('=', warch);
    sep.pushSlice("-===========\n");
    u.out(sep.items);
    for (rows.items) |p| {
        const st = pkgStatusWord(p);
        var it = std.mem.tokenizeScalar(u8, st, ' ');
        const want = it.next() orelse "unknown";
        const flag = it.next() orelse "ok";
        const cur = it.next() orelse "not-installed";
        const c1: u8 = if (std.mem.eql(u8, want, "install")) 'i' else if (std.mem.eql(u8, want, "deinstall")) 'r' else if (std.mem.eql(u8, want, "purge")) 'p' else if (std.mem.eql(u8, want, "hold")) 'h' else 'u';
        const c2: u8 = if (std.mem.eql(u8, cur, "installed")) 'i' else if (std.mem.eql(u8, cur, "config-files")) 'c' else if (std.mem.eql(u8, cur, "unpacked")) 'U' else if (std.mem.eql(u8, cur, "half-configured")) 'F' else if (std.mem.eql(u8, cur, "half-installed")) 'H' else 'n';
        const c3: u8 = if (std.mem.eql(u8, flag, "reinstreq")) 'R' else ' ';
        var line = u.Vec(u8).init(u.alloc);
        line.push(c1);
        line.push(c2);
        line.push(c3);
        line.push(' ');
        line.pushSlice(padR(p.name, wname));
        line.push(' ');
        line.pushSlice(padR(fld(p, "Version"), wver));
        line.push(' ');
        line.pushSlice(padR(fld(p, "Architecture"), warch));
        line.push(' ');
        line.pushSlice(firstLine(fld(p, "Description")));
        line.push('\n');
        u.out(line.items);
    }
    return 0;
}

fn padR(s: []const u8, w: usize) []const u8 {
    if (s.len >= w) return s;
    const b = u.alloc.alloc(u8, w) catch return s;
    @memcpy(b[0..s.len], s);
    @memset(b[s.len..], ' ');
    return b;
}

fn showStatus(names: []const []const u8) u8 {
    const pkgs = loadStatus();
    var rc: u8 = 0;
    for (names) |n| {
        if (findPkg(pkgs, n)) |i| {
            u.outf("{s}\n", .{pkgs[i].raw});
            u.out("\n");
        } else {
            u.errf("dpkg-query: package '{s}' is not installed and no information is available\nUse dpkg --info (= dpkg-deb --info) to examine archive files.\n", .{n});
            rc = 1;
        }
    }
    return rc;
}

fn infoList(name: []const u8) ?[]const u8 {
    const p = std.fmt.allocPrint(u.alloc, "{s}{s}/info/{s}.list", .{ rootdir, admindir, name }) catch return null;
    return mnt.readFile(p);
}

fn listFiles(names: []const []const u8) u8 {
    var rc: u8 = 0;
    for (names) |n| {
        const l = infoList(n) orelse {
            u.errf("dpkg-query: package '{s}' is not installed\nUse dpkg --info (= dpkg-deb --info) to examine archive files.\n", .{n});
            rc = 1;
            continue;
        };
        u.out(l);
    }
    return rc;
}

fn searchOwner(pats: []const []const u8) u8 {
    var rc: u8 = 0;
    const pkgs = loadStatus();
    for (pats) |pat| {
        var found = false;
        for (pkgs) |p| {
            const l = infoList(p.name) orelse continue;
            var lines = std.mem.splitScalar(u8, l, '\n');
            while (lines.next()) |f| {
                if (f.len == 0) continue;
                const hit = if (std.mem.indexOfAny(u8, pat, "*?[") != null) globMatch(pat, f) else std.mem.eql(u8, f, pat) or (pat.len > 1 and std.mem.endsWith(u8, f, pat) and false);
                if (hit) {
                    u.outf("{s}: {s}\n", .{ p.name, f });
                    found = true;
                }
            }
        }
        if (!found) {
            u.errf("dpkg-query: no path found matching pattern {s}\n", .{pat});
            rc = 1;
        }
    }
    return rc;
}

// ---------------------------------------------------------------- .deb handling
const ArMember = struct { name: []const u8, data: []const u8 };

fn parseAr(data: []const u8) ?[]ArMember {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], "!<arch>\n")) return null;
    var out = u.Vec(ArMember).init(u.alloc);
    var off: usize = 8;
    while (off + 60 <= data.len) {
        const hdr = data[off .. off + 60];
        const name = std.mem.trim(u8, hdr[0..16], " /");
        const size = std.fmt.parseInt(usize, std.mem.trim(u8, hdr[48..58], " "), 10) catch return null;
        off += 60;
        if (off + size > data.len) return null;
        out.push(.{ .name = u.alloc.dupe(u8, name) catch name, .data = data[off .. off + size] });
        off += size + (size & 1);
    }
    return out.items;
}

fn decompress(name: []const u8, data: []const u8) ?[]const u8 {
    var prog: []const u8 = "";
    if (std.mem.endsWith(u8, name, ".gz")) prog = "zcat" else if (std.mem.endsWith(u8, name, ".xz")) prog = "xzcat" else if (std.mem.endsWith(u8, name, ".bz2")) prog = "bzcat" else if (std.mem.endsWith(u8, name, ".tar")) return data else return null;
    var in_p: [2]i32 = undefined;
    var out_p: [2]i32 = undefined;
    if (!u.ok(linux.pipe(&in_p)) or !u.ok(linux.pipe(&out_p))) return null;
    const pid = linux.fork();
    if (!u.ok(pid)) return null;
    if (pid == 0) {
        _ = linux.dup2(in_p[0], 0);
        _ = linux.dup2(out_p[1], 1);
        _ = linux.close(in_p[0]);
        _ = linux.close(in_p[1]);
        _ = linux.close(out_p[0]);
        _ = linux.close(out_p[1]);
        const exe = std.fmt.allocPrint(u.alloc, "/proc/self/exe", .{}) catch "";
        var av = [_]?[*:0]const u8{ u.zstr(prog).ptr, null };
        _ = linux.execve(u.zstr(exe).ptr, @ptrCast(&av), u.envp(&.{}));
        linux.exit_group(127);
    }
    _ = linux.close(in_p[0]);
    _ = linux.close(out_p[1]);
    // feed the compressed data from a helper child so neither pipe can block the other
    const fpid = linux.fork();
    if (u.ok(fpid) and fpid == 0) {
        _ = linux.close(out_p[0]);
        var off: usize = 0;
        while (off < data.len) {
            const w = linux.write(in_p[1], data.ptr + off, data.len - off);
            if (!u.ok(w)) break;
            off += w;
        }
        linux.exit_group(0);
    }
    _ = linux.close(in_p[1]);
    var out = u.Vec(u8).init(u.alloc);
    var buf: [65536]u8 = undefined;
    while (true) {
        const r = linux.read(out_p[0], &buf, buf.len);
        if (u.errno(r) == .INTR) continue;
        if (!u.ok(r) or r == 0) break;
        out.pushSlice(buf[0..r]);
    }
    _ = linux.close(out_p[0]);
    var st: u32 = 0;
    _ = linux.wait4(@intCast(pid), &st, 0, null);
    if (u.ok(fpid)) _ = linux.wait4(@intCast(fpid), &st, 0, null);
    return out.items;
}

const TarEntry = struct { path: []const u8, kind: u8, mode: u32, link: []const u8, data: []const u8, uid: u32, gid: u32 };

fn octal(b: []const u8) u64 {
    var v: u64 = 0;
    for (b) |ch| {
        if (ch == 0 or ch == ' ') {
            if (v != 0) break;
            continue;
        }
        if (ch < '0' or ch > '7') break;
        v = v * 8 + (ch - '0');
    }
    return v;
}

fn parseTar(a: []const u8) []TarEntry {
    var out = u.Vec(TarEntry).init(u.alloc);
    var off: usize = 0;
    var long_name: ?[]const u8 = null;
    var long_link: ?[]const u8 = null;
    while (off + 512 <= a.len) {
        const h = a[off .. off + 512];
        if (h[0] == 0) break;
        const size: usize = @intCast(octal(h[124..136]));
        const kind = h[156];
        var name: []const u8 = std.mem.sliceTo(h[0..100], 0);
        if (std.mem.eql(u8, h[257..262], "ustar") and h[345] != 0) {
            name = std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ std.mem.sliceTo(h[345..500], 0), name }) catch name;
        }
        const body = if (off + 512 + size <= a.len) a[off + 512 .. off + 512 + size] else a[off + 512 ..];
        off += 512 + (size + 511) / 512 * 512;
        if (kind == 'L') {
            long_name = std.mem.sliceTo(body, 0);
            continue;
        }
        if (kind == 'K') {
            long_link = std.mem.sliceTo(body, 0);
            continue;
        }
        if (kind == 'x' or kind == 'g') {
            // pax extended header: path= / linkpath=
            var it = std.mem.splitScalar(u8, body, '\n');
            while (it.next()) |rec| {
                const sp = std.mem.indexOfScalar(u8, rec, ' ') orelse continue;
                const kv = rec[sp + 1 ..];
                if (std.mem.startsWith(u8, kv, "path=")) long_name = kv[5..];
                if (std.mem.startsWith(u8, kv, "linkpath=")) long_link = kv[9..];
            }
            continue;
        }
        if (long_name) |ln| {
            name = ln;
            long_name = null;
        }
        var link: []const u8 = std.mem.sliceTo(h[157..257], 0);
        if (long_link) |ll| {
            link = ll;
            long_link = null;
        }
        out.push(.{ .path = u.alloc.dupe(u8, name) catch name, .kind = kind, .mode = @intCast(octal(h[100..108]) & 0o7777), .link = u.alloc.dupe(u8, link) catch link, .data = body, .uid = @intCast(octal(h[108..116])), .gid = @intCast(octal(h[116..124])) });
    }
    return out.items;
}

fn normPath(p: []const u8) []const u8 {
    var s = p;
    while (std.mem.startsWith(u8, s, "./")) s = s[2..];
    if (std.mem.eql(u8, s, ".")) return "/";
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (s.len > 0 and s[0] == '/') return s;
    return std.fmt.allocPrint(u.alloc, "/{s}", .{s}) catch s;
}

fn mkdirAll(path: []const u8) void {
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            _ = linux.mkdir(u.zstr(path[0..i]).ptr, 0o755);
        }
    }
}

fn runScript(path: []const u8, args: []const []const u8) bool {
    if (!u.ok(linux.access(u.zstr(path), 1))) return true;
    const pid = linux.fork();
    if (!u.ok(pid)) return false;
    if (pid == 0) {
        var av = u.Vec(?[*:0]const u8).init(u.alloc);
        av.push(u.zstr(path).ptr);
        for (args) |a| av.push(u.zstr(a).ptr);
        av.push(null);
        u.setEnv("DPKG_MAINTSCRIPT_PACKAGE", "");
        _ = linux.execve(u.zstr(path).ptr, @ptrCast(av.items.ptr), u.envp(&.{}));
        linux.exit_group(127);
    }
    var st: u32 = 0;
    _ = linux.wait4(@intCast(pid), &st, 0, null);
    return (st & 0x7f) == 0 and ((st >> 8) & 0xff) == 0;
}

fn archOf() []const u8 {
    var uts: linux.utsname = undefined;
    _ = linux.uname(&uts);
    const m = std.mem.sliceTo(&uts.machine, 0);
    if (std.mem.eql(u8, m, "x86_64")) return "amd64";
    if (std.mem.eql(u8, m, "aarch64")) return "arm64";
    if (std.mem.eql(u8, m, "i686") or std.mem.eql(u8, m, "i586") or std.mem.eql(u8, m, "i386")) return "i386";
    if (std.mem.startsWith(u8, m, "armv7") or std.mem.startsWith(u8, m, "armv6")) return "armhf";
    if (std.mem.eql(u8, m, "riscv64")) return "riscv64";
    return m;
}

fn installDeb(path: []const u8) u8 {
    const data = mnt.readFile(path) orelse {
        u.errf("dpkg: error: cannot access archive '{s}': No such file or directory\n", .{path});
        return 2;
    };
    const members = parseAr(data) orelse {
        u.errf("dpkg-deb: error: '{s}' is not a Debian format archive\ndpkg: error processing archive {s} (--install):\n subprocess dpkg-deb --control returned error exit status 2\n", .{ path, path });
        return 2;
    };
    var control_tar: ?[]const u8 = null;
    var data_tar: ?[]const u8 = null;
    for (members) |m| {
        if (std.mem.startsWith(u8, m.name, "control.tar")) control_tar = decompress(m.name, m.data);
        if (std.mem.startsWith(u8, m.name, "data.tar")) data_tar = decompress(m.name, m.data);
    }
    if (control_tar == null or data_tar == null) {
        u.errf("dpkg-deb: error: archive '{s}' contains no control/data member\n", .{path});
        return 2;
    }
    const ctrl = parseTar(control_tar.?);
    var control_text: []const u8 = "";
    for (ctrl) |e| if (std.mem.eql(u8, normPath(e.path), "/control")) {
        control_text = e.data;
    };
    const stanza = parseStanzas(control_text);
    if (stanza.len == 0) {
        u.err("dpkg-deb: error: control file missing\n");
        return 2;
    }
    const cp = stanza[0];
    const name = cp.name;
    const version = fld(cp, "Version");
    u.outf("Selecting previously unselected package {s}.\n", .{name});
    // run preinst
    const tmpdir = std.fmt.allocPrint(u.alloc, "{s}{s}/tmp.ci", .{ rootdir, admindir }) catch return 1;
    mkdirAll(tmpdir);
    for (ctrl) |e| {
        const nm = normPath(e.path);
        if (e.kind == '0' or e.kind == 0) {
            if (std.mem.eql(u8, nm, "/preinst") or std.mem.eql(u8, nm, "/postinst") or std.mem.eql(u8, nm, "/prerm") or std.mem.eql(u8, nm, "/postrm")) {
                const sp = std.fmt.allocPrint(u.alloc, "{s}{s}", .{ tmpdir, nm }) catch continue;
                writeFile(sp, e.data, 0o755);
            }
        }
    }
    u.outf("Preparing to unpack {s} ...\nUnpacking {s} ({s}) ...\n", .{ path, name, version });
    const pre = std.fmt.allocPrint(u.alloc, "{s}/preinst", .{tmpdir}) catch "";
    if (instdir.len == 0 and !runScript(pre, &.{ "install" })) {
        u.errf("dpkg: error processing archive {s} (--install):\n new {s} package pre-installation script subprocess returned error exit status 1\n", .{ path, name });
        return 1;
    }
    // unpack
    const files = parseTar(data_tar.?);
    var list = u.Vec(u8).init(u.alloc);
    for (files) |e| {
        const nm = normPath(e.path);
        const dst = std.fmt.allocPrint(u.alloc, "{s}{s}", .{ instdir, nm }) catch continue;
        list.pushSlice(nm);
        list.push('\n');
        switch (e.kind) {
            '5' => {
                mkdirAll(dst);
                _ = linux.chmod(u.zstr(dst).ptr, @intCast(e.mode));
            },
            '2' => {
                _ = linux.unlink(u.zstr(dst).ptr);
                if (std.fs.path.dirname(dst)) |dn| mkdirAll(dn);
                _ = linux.symlink(u.zstr(e.link).ptr, u.zstr(dst).ptr);
            },
            '1' => {
                const tgt = std.fmt.allocPrint(u.alloc, "{s}{s}", .{ instdir, normPath(e.link) }) catch continue;
                _ = linux.unlink(u.zstr(dst).ptr);
                _ = linux.link(u.zstr(tgt).ptr, u.zstr(dst).ptr);
            },
            '0', 0, '7' => {
                if (std.fs.path.dirname(dst)) |dn| mkdirAll(dn);
                const tmp = std.fmt.allocPrint(u.alloc, "{s}.dpkg-new", .{dst}) catch continue;
                writeFile(tmp, e.data, e.mode);
                if (!u.ok(linux.rename(u.zstr(tmp).ptr, u.zstr(dst).ptr))) {
                    u.errf("dpkg: error: unable to install '{s}'\n", .{dst});
                    return 1;
                }
            },
            else => {},
        }
        if (e.kind != '2') {} else {}
    }
    // database: list file, control files, status
    const info = std.fmt.allocPrint(u.alloc, "{s}{s}/info", .{ rootdir, admindir }) catch return 1;
    mkdirAll(info);
    writeFile(std.fmt.allocPrint(u.alloc, "{s}/{s}.list", .{ info, name }) catch return 1, list.items, 0o644);
    for (ctrl) |e| {
        const nm = normPath(e.path);
        if ((e.kind == '0' or e.kind == 0) and nm.len > 1 and !std.mem.eql(u8, nm, "/control")) {
            const fn_ = std.fmt.allocPrint(u.alloc, "{s}/{s}.{s}", .{ info, name, nm[1..] }) catch continue;
            writeFile(fn_, e.data, e.mode);
        }
    }
    var pkgs_list = u.Vec(Pkg).init(u.alloc);
    for (loadStatus()) |pk| if (!std.mem.eql(u8, pk.name, name)) pkgs_list.push(pk);
    var raw = u.Vec(u8).init(u.alloc);
    raw.pushSlice(std.mem.trim(u8, control_text, "\n"));
    raw.pushSlice("\nStatus: install ok installed");
    var np = cp;
    np.raw = raw.items;
    np.fields.put(u.alloc, "Status", "install ok installed") catch {};
    pkgs_list.push(np);
    if (!saveStatus(pkgs_list.items)) {
        u.err("dpkg: error: cannot write the status database\n");
        return 1;
    }
    u.outf("Setting up {s} ({s}) ...\n", .{ name, version });
    const post = std.fmt.allocPrint(u.alloc, "{s}/postinst", .{tmpdir}) catch "";
    if (instdir.len == 0 and !runScript(post, &.{ "configure" })) {
        u.errf("dpkg: error processing package {s} (--install):\n installed {s} package post-installation script subprocess returned error exit status 1\n", .{ name, name });
        return 1;
    }
    return 0;
}

fn writeFile(path: []const u8, data: []const u8, mode: u32) void {
    const rc = linux.open(u.zstr(path), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @intCast(mode & 0o7777));
    if (!u.ok(rc)) return;
    var off: usize = 0;
    while (off < data.len) {
        const w = linux.write(@intCast(rc), data.ptr + off, data.len - off);
        if (!u.ok(w)) break;
        off += w;
    }
    _ = linux.fchmod(@intCast(rc), @intCast(mode & 0o7777));
    _ = linux.close(@intCast(rc));
}

fn removePkg(name: []const u8, purge: bool) u8 {
    var pkgs = u.Vec(Pkg).init(u.alloc);
    var idx: ?usize = null;
    for (loadStatus()) |pk| {
        if (std.mem.eql(u8, pk.name, name)) idx = pkgs.items.len;
        pkgs.push(pk);
    }
    const i = idx orelse {
        u.errf("dpkg: warning: ignoring request to remove {s} which isn't installed\n", .{name});
        return 1;
    };
    u.outf("Removing {s} ({s}) ...\n", .{ name, fld(pkgs.items[i], "Version") });
    const info = std.fmt.allocPrint(u.alloc, "{s}{s}/info", .{ rootdir, admindir }) catch return 1;
    if (instdir.len == 0) _ = runScript(std.fmt.allocPrint(u.alloc, "{s}/{s}.prerm", .{ info, name }) catch "", &.{"remove"});
    if (infoList(name)) |l| {
        // files first, directories afterwards (deepest first)
        var dirs = u.Vec([]const u8).init(u.alloc);
        var lines = std.mem.splitScalar(u8, l, '\n');
        while (lines.next()) |f| {
            if (f.len == 0 or std.mem.eql(u8, f, "/")) continue;
            const full = std.fmt.allocPrint(u.alloc, "{s}{s}", .{ instdir, f }) catch continue;
            const st = u.stat(full, false) orelse continue;
            if (st.mode & linux.S.IFMT == linux.S.IFDIR) dirs.push(full) else {
                // conffiles stay unless purging
                _ = linux.unlink(u.zstr(full).ptr);
            }
        }
        var k = dirs.items.len;
        while (k > 0) {
            k -= 1;
            _ = linux.rmdir(u.zstr(dirs.items[k]).ptr);
        }
    }
    if (instdir.len == 0) _ = runScript(std.fmt.allocPrint(u.alloc, "{s}/{s}.postrm", .{ info, name }) catch "", &.{"remove"});
    if (purge) {
        for ([_][]const u8{ "list", "preinst", "postinst", "prerm", "postrm", "md5sums", "conffiles" }) |ext| {
            _ = linux.unlink(u.zstr(std.fmt.allocPrint(u.alloc, "{s}/{s}.{s}", .{ info, name, ext }) catch "").ptr);
        }
        var out = u.Vec(Pkg).init(u.alloc);
        for (pkgs.items, 0..) |pk, j| if (j != i) out.push(pk);
        pkgs = out;
        if (purge) u.outf("Purging configuration files for {s} ...\n", .{name});
    } else {
        var p = pkgs.items[i];
        var raw = u.Vec(u8).init(u.alloc);
        var lines = std.mem.splitScalar(u8, p.raw, '\n');
        var first = true;
        while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, "Status:")) continue;
            if (!first) raw.push('\n');
            first = false;
            raw.pushSlice(l);
        }
        raw.pushSlice("\nStatus: deinstall ok config-files");
        p.raw = raw.items;
        pkgs.items[i] = p;
        _ = linux.unlink(u.zstr(std.fmt.allocPrint(u.alloc, "{s}/{s}.list", .{ info, name }) catch "").ptr);
    }
    if (!saveStatus(pkgs.items)) return 1;
    return 0;
}

pub fn dpkg(args: []const []const u8) u8 {
    var rest = u.Vec([]const u8).init(u.alloc);
    var cmd: []const u8 = "";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.startsWith(u8, a, "--admindir=")) {
            admindir = a["--admindir=".len..];
        } else if (std.mem.eql(u8, a, "--admindir") and i + 1 < args.len) {
            i += 1;
            admindir = args[i];
        } else if (std.mem.startsWith(u8, a, "--instdir=")) {
            instdir = a["--instdir=".len..];
        } else if (std.mem.startsWith(u8, a, "--root=")) {
            rootdir = a["--root=".len..];
            instdir = rootdir;
        } else if (std.mem.eql(u8, a, "--force-all") or std.mem.startsWith(u8, a, "--force-") or std.mem.startsWith(u8, a, "--no-") or std.mem.eql(u8, a, "-E") or std.mem.eql(u8, a, "-G") or std.mem.eql(u8, a, "-B")) {
            // accepted and ignored
        } else if (cmd.len == 0 and a.len > 0 and a[0] == '-') {
            cmd = a;
        } else rest.push(a);
    }
    if (cmd.len == 0) {
        u.err("Type dpkg --help for help about installing and deinstalling packages [*];\nUse 'apt' or 'aptitude' for user-friendly package management;\nType dpkg -Dhelp for a list of dpkg debug flag values;\nType dpkg --force-help for a list of forcing options;\nType dpkg-deb --help for help about manipulating *.deb files;\n\nOptions marked [*] produce a lot of output - pipe it through 'less' or 'more' !\n");
        return 2;
    }
    if (std.mem.eql(u8, cmd, "--version")) {
        u.out("Debian 'dpkg' package management program version 1.22.6 (cmdbox).\n");
        return 0;
    }
    if (std.mem.eql(u8, cmd, "--print-architecture")) {
        u.outf("{s}\n", .{archOf()});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "--compare-versions")) {
        if (rest.items.len != 3) {
            u.err("dpkg: error: --compare-versions takes three arguments: <version> <relation> <version>\n\nType dpkg --help for help about installing and deinstalling packages [*];\n");
            return 2;
        }
        const r = versionCompare(rest.items[0], rest.items[2]);
        const op = rest.items[1];
        const ok = if (std.mem.eql(u8, op, "lt") or std.mem.eql(u8, op, "<<")) r < 0 else if (std.mem.eql(u8, op, "le") or std.mem.eql(u8, op, "<=") or std.mem.eql(u8, op, "<")) r <= 0 else if (std.mem.eql(u8, op, "eq") or std.mem.eql(u8, op, "=")) r == 0 else if (std.mem.eql(u8, op, "ne")) r != 0 else if (std.mem.eql(u8, op, "ge") or std.mem.eql(u8, op, ">=") or std.mem.eql(u8, op, ">")) r >= 0 else if (std.mem.eql(u8, op, "gt") or std.mem.eql(u8, op, ">>")) r > 0 else {
            u.errf("dpkg: error: unknown relation '{s}'\n", .{op});
            return 2;
        };
        return if (ok) 0 else 1;
    }
    if (std.mem.eql(u8, cmd, "-l") or std.mem.eql(u8, cmd, "--list")) return listPackages(rest.items);
    if (std.mem.eql(u8, cmd, "-s") or std.mem.eql(u8, cmd, "--status")) return showStatus(rest.items);
    if (std.mem.eql(u8, cmd, "-L") or std.mem.eql(u8, cmd, "--listfiles")) return listFiles(rest.items);
    if (std.mem.eql(u8, cmd, "-S") or std.mem.eql(u8, cmd, "--search")) return searchOwner(rest.items);
    if (std.mem.eql(u8, cmd, "-i") or std.mem.eql(u8, cmd, "--install") or std.mem.eql(u8, cmd, "--unpack")) {
        if (rest.items.len == 0) {
            u.errf("dpkg: error: --install needs at least one package archive file argument\n", .{});
            return 2;
        }
        var rc: u8 = 0;
        for (rest.items) |f| {
            const r = installDeb(f);
            if (r != 0) rc = r;
        }
        return rc;
    }
    if (std.mem.eql(u8, cmd, "-r") or std.mem.eql(u8, cmd, "--remove") or std.mem.eql(u8, cmd, "-P") or std.mem.eql(u8, cmd, "--purge")) {
        var rc: u8 = 0;
        for (rest.items) |n| {
            if (removePkg(n, cmd[1] == 'P' or std.mem.eql(u8, cmd, "--purge")) != 0) rc = 1;
        }
        return rc;
    }
    if (std.mem.eql(u8, cmd, "--configure") or std.mem.eql(u8, cmd, "--audit") or std.mem.eql(u8, cmd, "-C")) return 0;
    u.errf("dpkg: error: unknown option or action {s}\n\nType dpkg --help for help about installing and deinstalling packages [*];\n", .{cmd});
    return 2;
}
