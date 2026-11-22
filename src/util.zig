// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// util.zig - shared helpers for cmdbox applets (Linux syscalls and static musl allocator)
const std = @import("std");
const linux = std.os.linux;

pub const alloc = std.heap.c_allocator; // musl malloc packs small command allocations
pub const PATH_MAX = 4096;

/// name of the running applet (for diagnostics)
pub var applet_name: []const u8 = "cmdbox";

// ---------- output ----------
var pbuf: [8192]u8 = undefined;

pub fn out(s: []const u8) void {
    if (s.len == 0) return;
    var n: usize = 0;
    while (n < s.len) {
        const rc = linux.write(1, s.ptr + n, s.len - n);
        switch (errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return;
                n += rc;
            },
            .INTR => continue,
            else => return,
        }
    }
}

pub fn outf(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&pbuf, fmt, args) catch return;
    out(s);
}

// ---------- stderr ----------
pub fn err(s: []const u8) void {
    _ = linux.write(2, s.ptr, s.len);
}

// set /proc/self/comm so ps/killall see the applet name, not "cmdbox"
pub fn setProcName(name: []const u8) void {
    var buf: [16]u8 = @splat(0);
    const n = @min(name.len, 15);
    @memcpy(buf[0..n], name[0..n]);
    _ = linux.prctl(15, @intFromPtr(&buf), 0, 0, 0); // PR_SET_NAME
}

pub fn errf(comptime fmt: []const u8, args: anytype) void {
    var b: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    err(s);
}

// ---------- syscall errno ----------
pub fn errno(rc: usize) linux.E {
    return linux.errno(rc);
}

pub fn ok(rc: usize) bool {
    return linux.errno(rc) == .SUCCESS;
}

pub fn lastErrStr(name: []const u8, rc: usize) void {
    errf("{s}: {s}\n", .{ name, strerr(errno(rc)) });
}

pub fn strerr(e: linux.E) []const u8 {
    return switch (e) {
        .NXIO => "No such device or address",
        .OPNOTSUPP => "Operation not supported",
        .NOTTY => "Inappropriate ioctl for device",
        .PERM => "Operation not permitted",
        .NOENT => "No such file or directory",
        .SRCH => "No such process",
        .AGAIN => "Resource temporarily unavailable",
        .NOMEM => "Out of memory",
        .BADF => "Bad file descriptor",
        .CHILD => "No child processes",
        .ACCES => "Permission denied",
        .FAULT => "Bad address",
        .BUSY => "Device or resource busy",
        .EXIST => "File exists",
        .NODEV => "No such device",
        .NOTDIR => "Not a directory",
        .ISDIR => "Is a directory",
        .INVAL => "Invalid argument",
        .MFILE => "Too many open files",
        .NOSPC => "No space left on device",
        .ROFS => "Read-only file system",
        .NAMETOOLONG => "File name too long",
        .NOTEMPTY => "Directory not empty",
        .LOOP => "Too many symbolic links",
        .PIPE => "Broken pipe",
        .NOSYS => "Function not implemented",
        else => "Unknown error",
    };
}

pub fn unescape(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var buf = alloc.alloc(u8, s.len + 4) catch return s;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            buf[n] = s[i];
            n += 1;
            i += 1;
            continue;
        }
        i += 1;
        switch (s[i]) {
            'a' => {
                buf[n] = 0x07;
                n += 1;
                i += 1;
            },
            'b' => {
                buf[n] = 0x08;
                n += 1;
                i += 1;
            },
            'f' => {
                buf[n] = 0x0c;
                n += 1;
                i += 1;
            },
            'n' => {
                buf[n] = '\n';
                n += 1;
                i += 1;
            },
            'r' => {
                buf[n] = '\r';
                n += 1;
                i += 1;
            },
            't' => {
                buf[n] = '\t';
                n += 1;
                i += 1;
            },
            'v' => {
                buf[n] = 0x0b;
                n += 1;
                i += 1;
            },
            '\\' => {
                buf[n] = '\\';
                n += 1;
                i += 1;
            },
            '0' => {
                var v: u8 = 0;
                var kk: usize = 0;
                i += 1;
                while (kk < 3 and i < s.len and s[i] >= '0' and s[i] <= '7') : (kk += 1) {
                    v = v * 8 + (s[i] - '0');
                    i += 1;
                }
                buf[n] = v;
                n += 1;
            },
            'x' => {
                var v: u8 = 0;
                var kk: usize = 0;
                i += 1;
                while (kk < 2 and i < s.len and ((s[i] >= '0' and s[i] <= '9') or (s[i] >= 'a' and s[i] <= 'f') or (s[i] >= 'A' and s[i] <= 'F'))) : (kk += 1) {
                    const c = s[i];
                    const d: u8 = if (c <= '9') c - '0' else (c | 32) - 'a' + 10;
                    v = v * 16 + d;
                    i += 1;
                }
                buf[n] = v;
                n += 1;
            },
            else => {
                buf[n] = '\\';
                n += 1;
            },
        }
    }
    return buf[0..n];
}

// ---------- memory / strings ----------
pub fn zstr(s: []const u8) [:0]u8 {
    const m = alloc.allocSentinel(u8, s.len, 0) catch @panic("oom");
    @memcpy(m[0..s.len], s);
    m[s.len] = 0;
    return m;
}

pub fn zbuf(buf: []u8) [:0]const u8 {
    if (buf.len >= PATH_MAX) return buf[0 .. buf.len - 1 :0];
    buf[buf.len] = 0;
    return buf[0..buf.len :0];
}

// tiny growable vector (leaks; fine for applets)
pub fn Vec(comptime T: type) type {
    return struct {
        const Self = @This();
        items: []T = &.{},
        cap: usize = 0,
        a: std.mem.Allocator,

        pub fn init(a: std.mem.Allocator) Self {
            return .{ .a = a };
        }
        pub fn push(self: *Self, x: T) void {
            if (self.items.len >= self.cap) {
                const nc = if (self.cap == 0) 16 else self.cap * 2;
                const nb = self.a.alloc(T, nc) catch @panic("oom");
                @memcpy(nb[0..self.items.len], self.items);
                self.items = nb[0..self.items.len];
                self.cap = nc;
            }
            const n = self.items.len + 1;
            self.items = self.items.ptr[0..n];
            self.items[n - 1] = x;
        }
        pub fn reserve(self: *Self, extra: usize) void {
            const need = self.items.len + extra;
            if (need <= self.cap) return;
            var nc = if (self.cap == 0) 16 else self.cap * 2;
            while (nc < need) nc *= 2;
            const nb = self.a.alloc(T, nc) catch @panic("oom");
            @memcpy(nb[0..self.items.len], self.items);
            self.items = nb[0..self.items.len];
            self.cap = nc;
        }
        pub fn pushSlice(self: *Self, src: []const T) void {
            self.reserve(src.len);
            const n = self.items.len;
            self.items = self.items.ptr[0 .. n + src.len];
            @memcpy(self.items[n..], src);
        }
        pub fn pushN(self: *Self, x: T, k: usize) void {
            self.reserve(k);
            const n = self.items.len;
            self.items = self.items.ptr[0 .. n + k];
            @memset(self.items[n..], x);
        }
        pub fn pop(self: *Self) void {
            if (self.items.len > 0) self.items = self.items.ptr[0 .. self.items.len - 1];
        }
        pub fn slice(self: *const Self) []T {
            return self.items;
        }
    };
}

// ---------- parsing ----------
pub fn toInt(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var i: usize = 0;
    var neg = false;
    if (s[0] == '-') {
        neg = true;
        i = 1;
    } else if (s[0] == '+') i = 1;
    if (i >= s.len) return null;
    var v: i64 = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] < '0' or s[i] > '9') return null;
        v = v * 10 + (s[i] - '0');
    }
    return if (neg) -v else v;
}

pub fn parseMode(s: []const u8) ?u32 {
    if (s.len == 0 or s.len > 4) return null;
    var m: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '7') return null;
        m = m * 8 + (c - '0');
    }
    return m;
}

pub fn basename(path: []const u8) []const u8 {
    if (path.len == 0) return ".";
    var s = path;
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (std.mem.eql(u8, s, "/")) return s;
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}

pub fn dirname(path: []const u8) []const u8 {
    var s = path;
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| {
        if (i == 0) return "/";
        const parent = std.mem.trimEnd(u8, s[0..i], "/");
        return if (parent.len == 0) "/" else parent;
    }
    return ".";
}

// lexical cleanup of ./ and ../ (no symlink resolution)
pub fn cleanPath(path: []const u8, buf: []u8) []const u8 {
    var pos: usize = 1;
    buf[0] = '/';
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (pos > 1) {
                pos -= 1;
                while (pos > 1 and buf[pos - 1] != '/') pos -= 1;
            }
            continue;
        }
        if (pos > 1 and buf[pos - 1] != '/') {
            buf[pos] = '/';
            pos += 1;
        }
        const n = @min(p.len, buf.len - pos);
        @memcpy(buf[pos .. pos + n], p[0..n]);
        pos += n;
    }
    if (pos > 1 and buf[pos - 1] == '/') pos -= 1;
    return buf[0..pos];
}

// ---------- file io ----------
pub const File = struct {
    fd: std.posix.fd_t,

    pub fn open(path: []const u8, flags: std.posix.O, mode: u32) ?File {
        const fd = std.posix.openatZ(std.posix.AT.FDCWD, zstr(path), flags, @intCast(mode)) catch return null;
        return .{ .fd = fd };
    }
    pub fn close(self: File) void {
        _ = linux.close(self.fd);
    }
    pub fn read(self: File, buf: []u8) usize {
        const rc = linux.read(self.fd, buf.ptr, buf.len);
        if (errno(rc) != .SUCCESS) return 0;
        return rc;
    }
    pub fn write(self: File, data: []const u8) bool {
        var n: usize = 0;
        while (n < data.len) {
            const rc = linux.write(self.fd, data.ptr + n, data.len - n);
            switch (errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return false;
                    n += rc;
                },
                .INTR => continue,
                else => return false,
            }
        }
        return true;
    }
    pub fn size(self: File) usize {
        const cur = linux.lseek(self.fd, 0, std.posix.SEEK.CUR);
        const end = linux.lseek(self.fd, 0, std.posix.SEEK.END);
        _ = linux.lseek(self.fd, cur, std.posix.SEEK.SET);
        if (errno(end) != .SUCCESS) return 0;
        return end;
    }
};

pub fn copyFd(src: File, dst: File, buf: []u8) bool {
    while (true) {
        const n = linux.read(src.fd, buf.ptr, buf.len);
        if (errno(n) == .INTR) continue;
        if (!ok(n)) return false;
        if (n == 0) return true;
        if (!dst.write(buf[0..n])) return false;
    }
}

pub fn copyFile(src: []const u8, dst: []const u8, mode: u32) bool {
    var in = File.open(src, .{ .ACCMODE = .RDONLY }, 0) orelse {
        errf("cp: {s}: {s}\n", .{ src, "cannot open" });
        return false;
    };
    defer in.close();
    var out_f = File.open(dst, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, mode) orelse {
        errf("cp: {s}: {s}\n", .{ dst, "cannot create" });
        return false;
    };
    var buf: [65536]u8 = undefined;
    const r = copyFd(in, out_f, &buf);
    out_f.close();
    return r;
}

// ---------- stat ----------
pub const Stat = struct {
    mode: u32,
    uid: u32,
    gid: u32,
    size: u64,
    blocks: u64,
    mtime: i64, // seconds since epoch
    mtime_nsec: u32,
    atime: i64,
    atime_nsec: u32,
    ctime: i64 = 0,
    ctime_nsec: u32 = 0,
    btime: i64 = -1,
    btime_nsec: u32 = 0,
    blksize: u32 = 4096,
    dev: u64,
    nlink: u32,
    rdev: u64,
    ino: u64,
};

pub fn stat(path: []const u8, follow: bool) ?Stat {
    return statAt(std.posix.AT.FDCWD, path, if (follow) 0 else 0x100);
}
pub fn statFd(fd: i32) ?Stat {
    return statAt(fd, "", 0x1000);
}
fn statAt(fd: i32, path: []const u8, flags: u32) ?Stat {
    var sx: linux.Statx = undefined;
    @memset(std.mem.asBytes(&sx), 0);
    const mask: linux.STATX = .{
        .TYPE = true,
        .MODE = true,
        .NLINK = true,
        .UID = true,
        .GID = true,
        .MTIME = true,
        .ATIME = true,
        .CTIME = true,
        .BTIME = true,
        .INO = true,
        .SIZE = true,
        .BLOCKS = true,
    };
    if (!ok(linux.statx(fd, zstr(path), flags, mask, &sx))) return null;
    return .{
        .mode = @as(u32, sx.mode),
        .uid = sx.uid,
        .gid = sx.gid,
        .size = sx.size,
        .blocks = sx.blocks,
        .mtime = sx.mtime.sec,
        .mtime_nsec = sx.mtime.nsec,
        .atime = sx.atime.sec,
        .atime_nsec = sx.atime.nsec,
        .ctime = sx.ctime.sec,
        .ctime_nsec = sx.ctime.nsec,
        .btime = if (sx.mask.BTIME) sx.btime.sec else -1,
        .btime_nsec = if (sx.mask.BTIME) sx.btime.nsec else 0,
        .blksize = sx.blksize,
        .dev = @as(u64, sx.dev_major) << 32 | sx.dev_minor,
        .nlink = sx.nlink,
        .rdev = (@as(u64, sx.rdev_major & 0xfff) << 8) | @as(u64, sx.rdev_minor & 0xff) | (@as(u64, sx.rdev_minor & 0xffffff00) << 12) | (@as(u64, sx.rdev_major & 0xfffff000) << 32),
        .ino = sx.ino,
    };
}

pub fn isDir(path: []const u8) bool {
    const s = stat(path, true) orelse return false;
    return s.mode & linux.S.IFMT == linux.S.IFDIR;
}

// ---------- dir listing ----------
pub const DirEnt = struct {
    name: [:0]u8,
    typ: u8,
};

pub fn listDir(path: []const u8, ents: *Vec(DirEnt)) bool {
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, zstr(path), .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch {
        return false;
    };
    defer _ = linux.close(fd);
    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const rc = linux.getdents64(fd, &buf, buf.len);
        if (errno(rc) != .SUCCESS) return rc == 0;
        if (rc == 0) break;
        var off: usize = 0;
        while (off < rc) {
            const de: *linux.dirent64 = @ptrCast(@alignCast(&buf[off]));
            const name_ptr: [*:0]const u8 = @ptrCast(&de.name);
            const name = std.mem.sliceTo(name_ptr, 0);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                const m = alloc.allocSentinel(u8, name.len, 0) catch break;
                @memcpy(m[0..name.len], name);
                ents.push(.{ .name = m, .typ = de.type });
            }
            off += de.reclen;
        }
    }
    // sort by name
    std.mem.sort(DirEnt, ents.items, {}, struct {
        fn lt(_: void, a: DirEnt, b: DirEnt) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return true;
}

// ---------- glob ----------
// fnmatch-lite: '*' = any run, '?' = any char
pub fn matchPat(pattern: []const u8, name: []const u8) bool {
    const fnmatch = @cImport({
        @cInclude("fnmatch.h");
    });
    const p = zstr(pattern);
    defer alloc.free(p);
    const n = zstr(name);
    defer alloc.free(n);
    return fnmatch.fnmatch(p, n, 0) == 0;
}

fn single(w: []const u8) []const []const u8 {
    const m = alloc.alloc([]const u8, 1) catch @panic("oom");
    m[0] = w;
    return m;
}

pub fn globWord(w: []const u8) []const []const u8 {
    var has_meta = false;
    for (w) |c| {
        if (c == '*' or c == '?') has_meta = true;
    }
    if (!has_meta) return single(w);
    // split dir / pattern at the last '/'
    var dir: []const u8 = ".";
    var pat: []const u8 = w;
    if (std.mem.lastIndexOfScalar(u8, w, '/')) |slash| {
        dir = if (slash == 0) "/" else w[0..slash];
        pat = w[slash + 1 ..];
    }
    var ents = Vec(DirEnt).init(alloc);
    if (!listDir(dir, &ents)) return single(w);
    var res = Vec([]const u8).init(alloc);
    for (ents.items) |e| {
        if (pat.len > 0 and pat[0] != '.' and e.name[0] == '.') continue; // hidden
        if (!matchPat(pat, e.name)) continue;
        const m = alloc.alloc(u8, dir.len + 1 + e.name.len) catch break;
        if (std.mem.eql(u8, dir, "/")) {
            @memcpy(m[0..1], "/");
            @memcpy(m[1 .. 1 + e.name.len], e.name);
            res.push(m[0 .. 1 + e.name.len]);
        } else {
            @memcpy(m[0..dir.len], dir);
            m[dir.len] = '/';
            @memcpy(m[dir.len + 1 ..], e.name);
            res.push(m[0 .. dir.len + 1 + e.name.len]);
        }
    }
    if (res.items.len == 0) return single(w);
    return res.items;
}

// ---------- passwd/group ----------
pub fn lookupUser(id: u32, buf: []u8) ?[]const u8 {
    return lookupIdFile("/etc/passwd", id, buf);
}
pub fn lookupGroup(id: u32, buf: []u8) ?[]const u8 {
    return lookupIdFile("/etc/group", id, buf);
}

fn lookupIdFile(file: []const u8, id: u32, buf: []u8) ?[]const u8 {
    var f = File.open(file, .{ .ACCMODE = .RDONLY }, 0) orelse return null;
    defer f.close();
    var line: [512]u8 = undefined;
    while (readLine(&f, &line)) |l| {
        // name:passwd:id:...
        const colon1 = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        const colon2 = std.mem.indexOfScalarPos(u8, l, colon1 + 1, ':') orelse continue;
        const colon3 = std.mem.indexOfScalarPos(u8, l, colon2 + 1, ':') orelse continue;
        const v = toInt(l[colon2 + 1 .. colon3]) orelse continue;
        if (v >= 0 and @as(u32, @intCast(v)) == id) {
            const n = @min(colon1, buf.len);
            @memcpy(buf[0..n], l[0..colon1]);
            return buf[0..n];
        }
    }
    return null;
}

// simple unbuffered line reader (small config files)
pub fn readLine(f: *File, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    while (n < buf.len) {
        var c: [1]u8 = undefined;
        const r = f.read(&c);
        if (r == 0) break;
        if (c[0] == '\n') break;
        buf[n] = c[0];
        n += 1;
    }
    if (n == 0) return null;
    return buf[0..n];
}

// buffered line reader for bulk text processing
pub const LineReader = struct {
    f: File,
    chunk: [16384]u8 = undefined,
    pos: usize = 0,
    end: usize = 0,
    line: [8192]u8 = undefined,
    llen: usize = 0,

    pub fn init(f: File) LineReader {
        return .{ .f = f };
    }

    /// next line without trailing \n; caller must copy if retaining
    pub fn next(self: *LineReader) ?[]const u8 {
        self.llen = 0;
        while (true) {
            // find newline in chunk
            var p = self.pos;
            while (p < self.end) : (p += 1) {
                if (self.chunk[p] == '\n') {
                    const avail = p - self.pos;
                    if (avail > 0 and self.llen + avail <= self.line.len) {
                        @memcpy(self.line[self.llen .. self.llen + avail], self.chunk[self.pos..p]);
                        self.llen += avail;
                    }
                    self.pos = p + 1;
                    return self.line[0..self.llen];
                }
            }
            // flush remainder
            const avail = self.end - self.pos;
            if (avail > 0) {
                if (avail <= self.line.len - self.llen) {
                    @memcpy(self.line[self.llen .. self.llen + avail], self.chunk[self.pos..self.end]);
                    self.llen += avail;
                }
            }
            self.pos = 0;
            self.end = 0;
            // EOF?
            if (avail == 0) {
                const r = self.f.read(&self.chunk);
                if (r == 0) {
                    if (self.llen > 0) {
                        const ret = self.line[0..self.llen];
                        self.llen = 0;
                        return ret;
                    }
                    return null;
                }
                self.end = r;
                continue;
            }
            const r = self.f.read(&self.chunk);
            if (r == 0) {
                const ret = self.line[0..self.llen];
                self.llen = 0;
                return ret;
            }
            self.end = r;
        }
    }
};

pub fn readAllLines(f: *File, lines: *Vec([]const u8)) void {
    var lr = LineReader.init(f.*);
    while (lr.next()) |l| {
        const m = alloc.alloc(u8, l.len) catch return;
        @memcpy(m, l);
        lines.push(m);
    }
}

// user name -> uid lookup for chown
pub fn findUser(name: []const u8) ?u32 {
    var f = File.open("/etc/passwd", .{ .ACCMODE = .RDONLY }, 0) orelse return null;
    defer f.close();
    var line: [512]u8 = undefined;
    while (readLine(&f, &line)) |l| {
        const colon1 = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        if (std.mem.eql(u8, l[0..colon1], name)) {
            const colon2 = std.mem.indexOfScalarPos(u8, l, colon1 + 1, ':') orelse continue;
            const colon3 = std.mem.indexOfScalarPos(u8, l, colon2 + 1, ':') orelse continue;
            const v = toInt(l[colon2 + 1 .. colon3]) orelse return null;
            return if (v >= 0) @intCast(v) else null;
        }
    }
    return null;
}

pub fn findGroup(name: []const u8) ?u32 {
    var f = File.open("/etc/group", .{ .ACCMODE = .RDONLY }, 0) orelse return null;
    defer f.close();
    var line: [512]u8 = undefined;
    while (readLine(&f, &line)) |l| {
        const colon1 = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        if (std.mem.eql(u8, l[0..colon1], name)) {
            const colon2 = std.mem.indexOfScalarPos(u8, l, colon1 + 1, ':') orelse continue;
            const colon3 = std.mem.indexOfScalarPos(u8, l, colon2 + 1, ':') orelse continue;
            const v = toInt(l[colon2 + 1 .. colon3]) orelse return null;
            return if (v >= 0) @intCast(v) else null;
        }
    }
    return null;
}

// ---------- time ----------
pub fn nowSecs() i64 {
    var ts: linux.timespec = undefined;
    if (!ok(linux.clock_gettime(.REALTIME, &ts))) return 0;
    return ts.sec;
}

pub fn nowMonoNanos() i64 {
    var ts: linux.timespec = undefined;
    if (!ok(linux.clock_gettime(.MONOTONIC, &ts))) return 0;
    return ts.sec * 1_000_000_000 + ts.nsec;
}

pub const DateTime = struct {
    year: i64,
    mon: u8, // 1-12
    day: u8, // 1-31
    hour: u8,
    min: u8,
    sec: u8,
    wday: u8, // 0=Sunday
};

pub fn civilFromEpoch(secs: i64) DateTime {
    const days = @divFloor(secs, 86400);
    var rem = secs - days * 86400;
    if (rem < 0) rem += 86400;
    const wday: u8 = @intCast(@mod(days + 4, 7));
    var z = days;
    z += 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = if (m <= 2) y + 1 else y,
        .mon = @intCast(m),
        .day = @intCast(d),
        .hour = @intCast(@divFloor(rem, 3600)),
        .min = @intCast(@divFloor(@mod(rem, 3600), 60)),
        .sec = @intCast(@mod(rem, 60)),
        .wday = wday,
    };
}

const wdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const mons = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

pub fn fmtDate(secs: i64, buf: []u8) []const u8 {
    const dt = civilFromEpoch(secs);
    return std.fmt.bufPrint(buf, "{s} {s} {d: >2} {d:0>2}:{d:0>2}:{d:0>2} {d}", .{
        wdays[dt.wday], mons[dt.mon - 1], dt.day, dt.hour, dt.min, dt.sec, dt.year,
    }) catch "?";
}

// ---------- env ----------
pub var raw_argv: []const [*:0]const u8 = &.{};
pub var raw_env: []const ?[*:0]const u8 = &.{};
pub var extra_env: [256][]const u8 = undefined;
pub var extra_exported: [256]bool = @splat(false);
pub var extra_env_n: usize = 0;
fn envName(entry: []const u8) []const u8 {
    return entry[0 .. std.mem.indexOfScalar(u8, entry, '=') orelse entry.len];
}
pub fn setEnv(name: []const u8, value: []const u8) void {
    putVar(name, value, true);
}
pub fn setVar(name: []const u8, value: []const u8) void {
    putVar(name, value, false);
}
fn putVar(name: []const u8, value: []const u8, exported: bool) void {
    const text = std.fmt.allocPrintSentinel(alloc, "{s}={s}", .{ name, value }, 0) catch return;
    for (extra_env[0..extra_env_n], 0..) |entry, i| if (std.mem.eql(u8, envName(entry), name)) {
        extra_env[i] = text;
        extra_exported[i] = extra_exported[i] or exported;
        return;
    };
    if (extra_env_n == extra_env.len) return;
    var inherited = false;
    for (raw_env) |entry| if (entry) |kv| {
        if (std.mem.eql(u8, envName(std.mem.sliceTo(kv, 0)), name)) inherited = true;
    };
    extra_env[extra_env_n] = text;
    extra_exported[extra_env_n] = inherited or exported;
    extra_env_n += 1;
}
pub fn unsetVar(name: []const u8) void {
    for (extra_env[0..extra_env_n], 0..) |entry, i| if (std.mem.eql(u8, envName(entry), name)) {
        extra_env[i] = alloc.dupe(u8, name) catch return;
        extra_exported[i] = false;
        return;
    };
    if (extra_env_n == extra_env.len) return;
    extra_env[extra_env_n] = alloc.dupe(u8, name) catch return;
    extra_exported[extra_env_n] = false;
    extra_env_n += 1;
}

pub fn getEnv(name: []const u8) ?[]const u8 {
    // exports take precedence
    var i: usize = extra_env_n;
    while (i > 0) {
        i -= 1;
        const kv = extra_env[i];
        if (std.mem.eql(u8, kv, name)) return null;
        if (kv.len > name.len and kv[name.len] == '=' and std.mem.eql(u8, kv[0..name.len], name))
            return kv[name.len + 1 ..];
    }
    for (raw_env) |kv| {
        const p = kv orelse continue;
        const s = std.mem.sliceTo(p, 0);
        if (s.len > name.len and s[name.len] == '=' and std.mem.eql(u8, s[0..name.len], name))
            return s[name.len + 1 ..];
    }
    return null;
}

// ---------- exec helpers ----------
/// Null-terminated exec vectors sized to the actual input, without truncation.
pub fn argvp(items: []const [:0]const u8) [*:null]const ?[*:0]const u8 {
    const values = alloc.allocSentinel(?[*:0]const u8, items.len, null) catch @panic("oom");
    for (items, 0..) |value, i| values[i] = value;
    return values.ptr;
}
pub fn envp(extra: []const []const u8) [*:null]const ?[*:0]const u8 {
    var entries = Vec([]const u8).init(alloc);
    for (raw_env) |entry| if (entry) |value| {
        mergeEnv(&entries, std.mem.sliceTo(value, 0));
    };
    for (extra_env[0..extra_env_n], 0..) |value, i| {
        if (extra_exported[i]) mergeEnv(&entries, value) else {
            var index: usize = 0;
            while (index < entries.items.len) {
                if (std.mem.eql(u8, envName(entries.items[index]), envName(value))) {
                    std.mem.copyForwards([]const u8, entries.items[index .. entries.items.len - 1], entries.items[index + 1 ..]);
                    entries.items.len -= 1;
                } else index += 1;
            }
        }
    }
    for (extra) |value| mergeEnv(&entries, value);
    const values = alloc.allocSentinel(?[*:0]const u8, entries.items.len, null) catch @panic("oom");
    for (entries.items, 0..) |value, i| values[i] = zstr(value);
    return values.ptr;
}
fn mergeEnv(entries: *Vec([]const u8), value: []const u8) void {
    for (entries.items) |*entry| if (std.mem.eql(u8, envName(entry.*), envName(value))) {
        entry.* = value;
        return;
    };
    entries.push(value);
}

/// PATH search; returns null-terminated candidate on success
pub fn findInPath(name: []const u8, buf: []u8) ?[:0]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        if (ok(linux.access(zstr(name), 1))) {
            const m = alloc.allocSentinel(u8, name.len, 0) catch return null;
            @memcpy(m[0..name.len], name);
            return m;
        }
        return null;
    }
    const path_env = getEnv("PATH") orelse "/bin:/usr/bin";
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const cand = std.fmt.bufPrint(buf, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name }) catch continue;
        if (ok(linux.access(zstr(cand), 1))) {
            const m = alloc.allocSentinel(u8, cand.len, 0) catch return null;
            @memcpy(m[0..cand.len], cand);
            return m;
        }
    }
    return null;
}

/// path of this executable via /proc/self/exe
pub fn selfExe() [:0]u8 {
    var buf: [PATH_MAX]u8 = undefined;
    const rc = linux.readlink("/proc/self/exe", &buf, buf.len);
    if (ok(rc)) {
        const len: usize = @intCast(rc);
        const m = alloc.allocSentinel(u8, len, 0) catch @panic("oom");
        @memcpy(m[0..len], buf[0..len]);
        return m;
    }
    return zstr("/proc/self/exe");
}

// ---------- signals ----------
pub const signals = [_][]const u8{ "EXIT", "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "BUS", "FPE", "KILL", "USR1", "SEGV", "USR2", "PIPE", "ALRM", "TERM", "STKFLT", "CHLD", "CONT", "STOP", "TSTP", "TTIN", "TTOU", "URG", "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "IO", "PWR", "SYS" };

pub fn sigFromName(s: []const u8) ?u8 {
    var name = s;
    if (name.len > 3 and std.mem.eql(u8, name[0..3], "SIG")) name = name[3..];
    for (signals, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return @intCast(i);
    }
    return null;
}

pub fn waitAll() u8 {
    var code: u8 = 0;
    while (true) {
        var st: u32 = 0;
        const rc = linux.waitpid(-1, &st, 0);
        if (errno(rc) != .SUCCESS) break;
        code = @intCast((st >> 8) & 0xff);
        if (st & 0x7f > 0 and st & 0x7f < 0x7f) code = @intCast(128 + (st & 0x7f));
    }
    return code;
}
pub fn flush() void {}
// Kernel time64 layout is independent of libc's time_t padding on 32-bit.
pub fn setTimes(path: []const u8, value: Stat, follow: bool) bool {
    const Time64 = extern struct { sec: i64, nsec: i64 };
    const times = [_]Time64{ .{ .sec = value.atime, .nsec = value.atime_nsec }, .{ .sec = value.mtime, .nsec = value.mtime_nsec } };
    const rc = linux.syscall4(if (@sizeOf(usize) == 4) .utimensat_time64 else .utimensat, @bitCast(@as(isize, std.posix.AT.FDCWD)), @intFromPtr(zstr(path).ptr), @intFromPtr(&times), if (follow) 0 else 0x100);
    return ok(rc);
}
pub fn umask(value: u32) u32 {
    return @intCast(linux.syscall1(.umask, value));
}
