// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// head, tail - GNU coreutils: -n -c (+N / -N / suffixes) -q -v -z, tail -f -F --pid -s --retry
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");

const Mode = enum { first, all_but_last, from_start, last };

const Amount = struct { n: u64 = 10, plus: bool = false, minus: bool = false };

fn parseAmount(text: []const u8) ?Amount {
    if (text.len == 0) return null;
    var r = Amount{};
    var s = text;
    if (s[0] == '-' or s[0] == '+') {
        r.minus = s[0] == '-';
        r.plus = s[0] == '+';
        s = s[1..];
    }
    var end: usize = 0;
    while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
    if (end == 0) return null;
    var v = std.fmt.parseInt(u64, s[0..end], 10) catch return null;
    const sfx = s[end..];
    if (sfx.len > 0) {
        var mult: u64 = 1;
        const e = std.mem.eql;
        if (e(u8, sfx, "b")) mult = 512 else if (e(u8, sfx, "kB")) mult = 1000 else if (e(u8, sfx, "k") or e(u8, sfx, "K") or e(u8, sfx, "KiB")) mult = 1024 else if (e(u8, sfx, "MB")) mult = 1000 * 1000 else if (e(u8, sfx, "M") or e(u8, sfx, "MiB")) mult = 1 << 20 else if (e(u8, sfx, "GB")) mult = 1000 * 1000 * 1000 else if (e(u8, sfx, "G") or e(u8, sfx, "GiB")) mult = 1 << 30 else if (e(u8, sfx, "TB")) mult = 1000 * 1000 * 1000 * 1000 else if (e(u8, sfx, "T") or e(u8, sfx, "TiB")) mult = 1 << 40 else if (e(u8, sfx, "PB")) mult = 1000 * 1000 * 1000 * 1000 * 1000 else if (e(u8, sfx, "P") or e(u8, sfx, "PiB")) mult = 1 << 50 else return null;
        v = std.math.mul(u64, v, mult) catch std.math.maxInt(u64);
    }
    r.n = v;
    return r;
}

fn readAll(fd: i32) ?[]u8 {
    var data = u.Vec(u8).init(u.alloc);
    var buf: [65536]u8 = undefined;
    while (true) {
        const rc = linux.read(fd, &buf, buf.len);
        if (u.errno(rc) == .INTR) continue;
        if (!u.ok(rc)) return null;
        if (rc == 0) break;
        data.pushSlice(buf[0..rc]);
    }
    return data.items;
}

fn openFile(name: []const u8, prog: []const u8, silent: bool) ?i32 {
    if (std.mem.eql(u8, name, "-")) return 0;
    const rc = linux.open(u.zstr(name), .{ .ACCMODE = .RDONLY, .NOCTTY = true }, 0);
    if (!u.ok(rc)) {
        if (!silent) u.errf("{s}: cannot open '{s}' for reading: {s}\n", .{ prog, name, u.strerr(u.errno(rc)) });
        return null;
    }
    return @intCast(rc);
}

fn header(name: []const u8, first: *bool) void {
    if (!first.*) u.out("\n");
    first.* = false;
    u.outf("==> {s} <==\n", .{if (std.mem.eql(u8, name, "-")) "standard input" else name});
}

// ---------- head ----------
fn headOne(fd: i32, name: []const u8, amt: Amount, bytes: bool, delim: u8) bool {
    const drop_last = amt.minus;
    if (!drop_last) {
        // stream the first N units
        var remaining = amt.n;
        var buf: [65536]u8 = undefined;
        var out = u.Vec(u8).init(u.alloc);
        while (remaining > 0) {
            const rc = linux.read(fd, &buf, buf.len);
            if (u.errno(rc) == .INTR) continue;
            if (!u.ok(rc)) {
                u.errf("head: error reading '{s}': {s}\n", .{ name, u.strerr(u.errno(rc)) });
                return false;
            }
            if (rc == 0) break;
            if (bytes) {
                const take: usize = @intCast(@min(remaining, rc));
                out.pushSlice(buf[0..take]);
                remaining -= take;
            } else {
                var i: usize = 0;
                while (i < rc and remaining > 0) : (i += 1) {
                    out.push(buf[i]);
                    if (buf[i] == delim) remaining -= 1;
                }
            }
            u.out(out.items);
            out.items.len = 0;
        }
        return true;
    }
    // all but the last N units: needs the whole input
    const data = readAll(fd) orelse {
        u.errf("head: error reading '{s}'\n", .{name});
        return false;
    };
    if (bytes) {
        const keep: usize = if (amt.n >= data.len) 0 else data.len - @as(usize, @intCast(amt.n));
        u.out(data[0..keep]);
    } else {
        // count delimiters from the end
        var end = data.len;
        var need = amt.n;
        // a final unterminated line counts as a line
        if (end > 0 and data[end - 1] != delim) {
            if (need > 0) {
                need -= 1;
                while (end > 0 and data[end - 1] != delim) end -= 1;
            }
        }
        while (need > 0 and end > 0) {
            end -= 1; // the delimiter
            while (end > 0 and data[end - 1] != delim) end -= 1;
            need -= 1;
        }
        u.out(data[0..end]);
    }
    return true;
}

pub fn head(args_in: []const []const u8) u8 {
    return run(args_in, false);
}

pub fn tail(args_in: []const []const u8) u8 {
    return run(args_in, true);
}

const HELP: u8 = 200;
const VERSION: u8 = 201;

fn run(args_in: []const []const u8, is_tail: bool) u8 {
    const prog: []const u8 = if (is_tail) "tail" else "head";
    // legacy -NUM and +NUM (tail) forms
    var legacy: ?Amount = null;
    var legacy_text: []const u8 = "";
    var args = u.Vec([]const u8).init(u.alloc);
    var seen_dd = false;
    var prev: []const u8 = "";
    for (args_in) |a| {
        defer prev = a;
        const takes_val = std.mem.eql(u8, prev, "-n") or std.mem.eql(u8, prev, "-c") or std.mem.eql(u8, prev, "-s") or std.mem.eql(u8, prev, "--lines") or std.mem.eql(u8, prev, "--bytes") or std.mem.eql(u8, prev, "--pid");
        if (takes_val) {
            args.push(a);
            continue;
        }
        if (!seen_dd and a.len > 1 and a[0] == '-' and a[1] >= '0' and a[1] <= '9') {
            var all = true;
            for (a[1..]) |ch| if (!std.ascii.isDigit(ch)) {
                all = false;
            };
            if (all) {
                legacy = parseAmount(a[1..]);
                legacy_text = a[1..];
                continue;
            }
            // -5c style
            if (a.len > 2 and std.ascii.isDigit(a[1])) {
                var j: usize = 1;
                while (j < a.len and std.ascii.isDigit(a[j])) j += 1;
                if (j < a.len and std.mem.indexOfScalar(u8, "bcklmqvz", a[j]) != null and j == a.len - 1) {
                    legacy = parseAmount(a[1..j]);
                    legacy_text = a[1..j];
                    args.push(std.fmt.allocPrint(u.alloc, "-{c}", .{a[j]}) catch continue);
                    continue;
                }
            }
        }
        if (std.mem.eql(u8, a, "--")) seen_dd = true;
        args.push(a);
    }
    const opts = [_]g.Opt{
        .{ .name = "bytes", .key = 'c', .arg = .req },
        .{ .name = "lines", .key = 'n', .arg = .req },
        .{ .name = "quiet", .key = 'q' },
        .{ .name = "silent", .key = 'q' },
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "zero-terminated", .key = 'z' },
        .{ .name = "follow", .key = 'f', .arg = .opt },
        .{ .key = 'F' },
        .{ .name = "pid", .key = 130, .arg = .req },
        .{ .name = "sleep-interval", .key = 's', .arg = .req },
        .{ .name = "retry", .key = 131 },
        .{ .name = "max-unchanged-stats", .key = 132, .arg = .req },
        .{ .name = "help", .key = HELP },
        .{ .name = "version", .key = VERSION },
    };
    var p = g.Parser.init(prog, args.items, &opts);
    var amt = Amount{};
    var bytes = false;
    var delim: u8 = '\n';
    var hdr: ?bool = null;
    var follow = false;
    var follow_name = false;
    var retry = false;
    var pid: i32 = 0;
    var sleep_s: f64 = 1.0;
    if (legacy) |l| amt = l;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'c', 'n' => {
                amt = parseAmount(it.val.?) orelse {
                    u.errf("{s}: invalid number of {s}: '{s}'\n", .{ prog, if (it.key == 'c') "bytes" else "lines", it.val.? });
                    return 1;
                };
                bytes = it.key == 'c';
            },
            'q' => hdr = false,
            'v' => hdr = true,
            'z' => delim = 0,
            'f' => {
                if (!is_tail) {
                    u.errf("{s}: invalid option -- 'f'\nTry '{s} --help' for more information.\n", .{ prog, prog });
                    return 1;
                }
                follow = true;
                if (it.val) |v| {
                    if (std.mem.eql(u8, v, "name")) follow_name = true else if (std.mem.eql(u8, v, "descriptor")) follow_name = false else {
                        u.errf("tail: invalid argument '{s}' for '--follow'\nValid arguments are:\n  - 'descriptor'\n  - 'name'\nTry 'tail --help' for more information.\n", .{v});
                        return 1;
                    }
                }
            },
            'F' => {
                follow = true;
                follow_name = true;
                retry = true;
            },
            130 => pid = std.fmt.parseInt(i32, it.val.?, 10) catch {
                u.errf("tail: invalid PID: '{s}'\n", .{it.val.?});
                return 1;
            },
            's' => sleep_s = std.fmt.parseFloat(f64, it.val.?) catch {
                u.errf("tail: invalid number of seconds: '{s}'\n", .{it.val.?});
                return 1;
            },
            131 => retry = true,
            132 => {},
            HELP => {
                u.outf("Usage: {s} [OPTION]... [FILE]...\n", .{prog});
                return 0;
            },
            VERSION => {
                u.outf("{s} (cmdbox)\n", .{prog});
                return 0;
            },
            else => {},
        }
    }
    if (!is_tail and (follow or retry)) return 1;
    var files = p.operands;
    if (files.items.len == 0) files.push("-");
    if (is_tail and legacy != null and legacy_text.len > 0 and files.items.len > 1) {
        u.errf("tail: option used in invalid context -- {s}\n", .{legacy_text});
        return 1;
    }
    const show_header = hdr orelse (files.items.len > 1);
    var first = true;
    var rc: u8 = 0;
    // "tail -n 0" prints nothing at all (not even headers)
    const zero_tail = is_tail and !follow and !amt.plus and amt.n == 0;

    for (files.items) |name| {
        const fd = openFile(name, prog, false) orelse {
            rc = 1;
            continue;
        };
        if (zero_tail) {
            if (fd != 0) _ = linux.close(fd);
            continue;
        }
        if (show_header) header(name, &first);
        if (!is_tail) {
            if (!headOne(fd, name, amt, bytes, delim)) rc = 1;
        } else {
            if (!tailOne(fd, name, amt, bytes, delim)) rc = 1;
        }
        if (fd != 0 and !(is_tail and follow)) _ = linux.close(fd);
        if (is_tail and follow and fd != 0) _ = linux.close(fd);
    }
    if (is_tail and follow) return followFiles(files.items, show_header, follow_name, retry, pid, sleep_s, rc);
    return rc;
}

fn tailOne(fd: i32, name: []const u8, amt: Amount, bytes: bool, delim: u8) bool {
    if (amt.plus) {
        // from unit N (1-based) to the end, streaming
        var skip: u64 = if (amt.n == 0) 0 else amt.n - 1;
        var buf: [65536]u8 = undefined;
        while (true) {
            const rc = linux.read(fd, &buf, buf.len);
            if (u.errno(rc) == .INTR) continue;
            if (!u.ok(rc)) {
                u.errf("tail: error reading '{s}': {s}\n", .{ name, u.strerr(u.errno(rc)) });
                return false;
            }
            if (rc == 0) break;
            var start: usize = 0;
            if (skip > 0) {
                if (bytes) {
                    const t: usize = @intCast(@min(skip, rc));
                    start = t;
                    skip -= t;
                } else {
                    var i: usize = 0;
                    while (i < rc and skip > 0) : (i += 1) {
                        if (buf[i] == delim) skip -= 1;
                    }
                    start = i;
                }
            }
            if (start < rc) u.out(buf[start..rc]);
        }
        return true;
    }
    const data = readAll(fd) orelse {
        u.errf("tail: error reading '{s}'\n", .{name});
        return false;
    };
    if (amt.n == 0) return true;
    if (bytes) {
        const keep: usize = @intCast(@min(amt.n, data.len));
        u.out(data[data.len - keep ..]);
        return true;
    }
    var start = data.len;
    var need = amt.n;
    var end = data.len;
    if (end > 0 and data[end - 1] == delim) end -= 1;
    // find the start of the last N lines
    while (need > 0 and start > 0) {
        if (end == 0) {
            start = 0;
            break;
        }
        var i = end;
        while (i > 0 and data[i - 1] != delim) i -= 1;
        start = i;
        need -= 1;
        if (i == 0) break;
        end = i - 1;
    }
    u.out(data[start..]);
    return true;
}

// ---------- follow ----------
const FollowFile = struct { name: []const u8, fd: i32, dev: u64, ino: u64, size: u64, ok: bool };

fn followFiles(names: []const []const u8, show_header: bool, by_name: bool, retry: bool, pid: i32, sleep_s: f64, rc0: u8) u8 {
    var fs = u.Vec(FollowFile).init(u.alloc);
    for (names) |nm| {
        if (std.mem.eql(u8, nm, "-")) {
            fs.push(.{ .name = nm, .fd = 0, .dev = 0, .ino = 0, .size = 0, .ok = true });
            continue;
        }
        const fdv = openFile(nm, "tail", true);
        if (fdv) |fd| {
            const st = u.statFd(fd) orelse u.Stat{ .mode = 0, .uid = 0, .gid = 0, .size = 0, .blocks = 0, .mtime = 0, .mtime_nsec = 0, .atime = 0, .atime_nsec = 0, .dev = 0, .nlink = 0, .rdev = 0, .ino = 0 };
            // position at the end (the initial output has been written already)
            _ = linux.syscall3(.lseek, @as(usize, @intCast(fd)), 0, 2);
            fs.push(.{ .name = nm, .fd = fd, .dev = st.dev, .ino = st.ino, .size = st.size, .ok = true });
        } else fs.push(.{ .name = nm, .fd = -1, .dev = 0, .ino = 0, .size = 0, .ok = false });
    }
    var any_open = false;
    for (fs.items) |f| if (f.ok) {
        any_open = true;
    };
    if (!any_open and !retry) {
        u.err("tail: no files remaining\n");
        return 1;
    }
    var last_shown: i32 = -2;
    var idle: u64 = 0;
    _ = &idle;
    while (true) {
        var progressed = false;
        for (fs.items, 0..) |*f, idx| {
            if (by_name and !std.mem.eql(u8, f.name, "-")) {
                // detect replacement / appearance / truncation by name
                if (u.stat(f.name, true)) |st| {
                    if (!f.ok or st.ino != f.ino or st.dev != f.dev) {
                        if (f.fd > 0) _ = linux.close(f.fd);
                        if (openFile(f.name, "tail", true)) |nfd| {
                            if (f.ok) u.errf("tail: '{s}' has been replaced;  following new file\n", .{f.name}) else u.errf("tail: '{s}' has appeared;  following new file\n", .{f.name});
                            f.fd = nfd;
                            f.dev = st.dev;
                            f.ino = st.ino;
                            f.size = 0;
                            f.ok = true;
                            if (show_header and last_shown != @as(i32, @intCast(idx))) {
                                u.outf("\n==> {s} <==\n", .{f.name});
                                last_shown = @intCast(idx);
                            }
                        }
                    }
                } else if (f.ok) {
                    u.errf("tail: '{s}' has become inaccessible: No such file or directory\n", .{f.name});
                    if (f.fd > 0) _ = linux.close(f.fd);
                    f.fd = -1;
                    f.ok = false;
                    if (!retry) {
                        // GNU keeps going only with --retry
                    }
                }
            }
            if (!f.ok) continue;
            const st = u.statFd(f.fd) orelse continue;
            if (st.size < f.size) {
                u.errf("tail: {s}: file truncated\n", .{f.name});
                _ = linux.syscall3(.lseek, @as(usize, @intCast(f.fd)), 0, 0);
                f.size = 0;
            }
            var buf: [65536]u8 = undefined;
            while (true) {
                const r = linux.read(f.fd, &buf, buf.len);
                if (u.errno(r) == .INTR) continue;
                if (!u.ok(r) or r == 0) break;
                if (show_header and last_shown != @as(i32, @intCast(idx))) {
                    u.outf("\n==> {s} <==\n", .{if (std.mem.eql(u8, f.name, "-")) "standard input" else f.name});
                    last_shown = @intCast(idx);
                }
                u.out(buf[0..r]);
                f.size += r;
                progressed = true;
            }
        }
        if (pid > 0) {
            const k = linux.syscall2(.kill, @bitCast(@as(isize, pid)), 0);
            if (!u.ok(k) and u.errno(k) == .SRCH) break;
        }
        if (!progressed) {
            var ts = linux.timespec{ .sec = @intFromFloat(sleep_s), .nsec = @intFromFloat((sleep_s - @floor(sleep_s)) * 1e9) };
            _ = linux.nanosleep(&ts, null);
        }
    }
    return rc0;
}
