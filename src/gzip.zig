// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0
const std = @import("std");
const u = @import("util.zig");
const linux = std.os.linux;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
const flate = std.compress.flate;
var warned = false;
const Options = struct { decode: bool = false, stdout: bool = false, keep: bool = false, force: bool = false, quiet: bool = false, verbose: bool = false, recursive: bool = false, test_only: bool = false, save_name: bool = true, restore_name: bool = false, suffix: []const u8 = ".gz", level: usize = 6 };
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
const Sink = struct {
    writer: Writer,
    file: u.File,
    fn init(file: u.File, buffer: []u8) Sink {
        return .{ .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer }, .file = file };
    }
    fn drain(writer: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *Sink = @fieldParentPtr("writer", writer);
        if (self.file.fd >= 0 and !self.file.write(writer.buffer[0..writer.end])) return error.WriteFailed;
        writer.end = 0;
        var used: usize = 0;
        for (data[0 .. data.len - 1]) |part| {
            if (self.file.fd >= 0 and !self.file.write(part)) return error.WriteFailed;
            used += part.len;
        }
        for (0..splat) |_| {
            const part = data[data.len - 1];
            if (self.file.fd >= 0 and !self.file.write(part)) return error.WriteFailed;
            used += part.len;
        }
        return used;
    }
};
const Source = struct {
    reader: Reader,
    file: u.File,
    fn init(file: u.File, buffer: []u8) Source {
        return .{ .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 }, .file = file };
    }
    fn stream(reader: *Reader, writer: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        const self: *Source = @fieldParentPtr("reader", reader);
        var buffer: [16384]u8 = undefined;
        const max = limit.minInt(buffer.len);
        if (max == 0) return 0;
        while (true) {
            const rc = linux.read(self.file.fd, &buffer, max);
            if (u.errno(rc) == .INTR) continue;
            if (!u.ok(rc)) return error.ReadFailed;
            if (rc == 0) return error.EndOfStream;
            try writer.writeAll(buffer[0..rc]);
            return rc;
        }
    }
};
const Header = struct { name: ?[]const u8 = null, mtime: u32 = 0 };
fn header(reader: *Reader) !Header {
    const first = try reader.peek(10);
    if (first[0] != 31 or first[1] != 139 or first[2] != 8) return error.BadGzipHeader;
    const flags = first[3];
    var result = Header{ .mtime = std.mem.readInt(u32, first[4..8], .little) };
    var pos: usize = 10;
    if (flags & 4 != 0) {
        const data = try reader.peek(12);
        pos = 12 + std.mem.readInt(u16, data[10..12], .little);
    }
    if (flags & 8 != 0) {
        const start = pos;
        while (true) : (pos += 1) {
            if (pos >= reader.buffer.len) return error.BadGzipHeader;
            const bytes = try reader.peek(pos + 1);
            if (bytes[pos] == 0) {
                result.name = try u.alloc.dupe(u8, u.basename(bytes[start..pos]));
                break;
            }
        }
    }
    return result;
}
fn compress(file: u.File, out: *Writer, name: ?[]const u8, st: ?u.Stat, opts: Options) !void {
    var hdr = [_]u8{ 31, 139, 8, 0, 0, 0, 0, 0, 0, 3 };
    if (name != null and opts.save_name) hdr[3] = 8;
    if (st != null and opts.save_name) {
        const seconds: u32 = if (st.?.mtime < 0) 0 else @truncate(@as(u64, @intCast(st.?.mtime)));
        std.mem.writeInt(u32, hdr[4..8], seconds, .little);
    }
    hdr[8] = if (opts.level == 9) 2 else if (opts.level == 1) 4 else 0;
    try out.writeAll(&hdr);
    if (hdr[3] & 8 != 0) {
        try out.writeAll(u.basename(name.?));
        try out.writeByte(0);
    }
    const levels = [_]flate.Compress.Options{ .level_1, .level_2, .level_3, .level_4, .level_5, .level_6, .level_7, .level_8, .level_9 };
    const window = try u.alloc.alloc(u8, flate.max_window_len);
    defer u.alloc.free(window);
    const engine = try u.alloc.create(flate.Compress);
    defer u.alloc.destroy(engine);
    engine.* = try flate.Compress.init(out, window, .raw, levels[opts.level - 1]);
    var crc = std.hash.Crc32.init();
    var size: u32 = 0;
    var buffer: [32768]u8 = undefined;
    while (true) {
        const rc = linux.read(file.fd, &buffer, buffer.len);
        if (u.errno(rc) == .INTR) continue;
        if (!u.ok(rc)) return error.ReadFailed;
        if (rc == 0) break;
        crc.update(buffer[0..rc]);
        size +%= @truncate(rc);
        try engine.writer.writeAll(buffer[0..rc]);
    }
    try engine.finish();
    var trailer: [8]u8 = undefined;
    std.mem.writeInt(u32, trailer[0..4], crc.final(), .little);
    std.mem.writeInt(u32, trailer[4..8], size, .little);
    try out.writeAll(&trailer);
}
fn decompress(reader: *Reader, out: *Writer, force: bool) !void {
    const window = try u.alloc.alloc(u8, flate.max_window_len);
    defer u.alloc.free(window);
    var members: usize = 0;
    while (true) {
        const magic = reader.peek(2) catch |err| {
            if (err == error.EndOfStream and members > 0) return;
            if (err == error.EndOfStream and force and members == 0) {
                _ = try reader.streamRemaining(out);
                return;
            }
            return err;
        };
        if (magic[0] != 31 or magic[1] != 139) {
            if (force and members == 0) {
                _ = try reader.streamRemaining(out);
                return;
            }
            return error.BadGzipHeader;
        }
        var engine = flate.Decompress.init(reader, .gzip, window);
        var checksum = std.hash.Crc32.init();
        var count: u32 = 0;
        var bytes: [32768]u8 = undefined;
        while (true) {
            const n = try engine.reader.readSliceShort(&bytes);
            if (n == 0) break;
            checksum.update(bytes[0..n]);
            count +%= @truncate(n);
            try out.writeAll(bytes[0..n]);
        }
        const trailer = engine.container_metadata.gzip;
        if (trailer.crc != checksum.final() or trailer.count != count) return error.WrongGzipChecksum;
        members += 1;
    }
}
fn process(name: []const u8, opts: Options) bool {
    const standard = same(name, "-");
    if (!opts.force) {
        var tty: [64]u8 = undefined;
        if ((!opts.decode and (opts.stdout or standard) and u.ok(linux.ioctl(1, 0x5401, @intFromPtr(&tty)))) or (opts.decode and standard and u.ok(linux.ioctl(0, 0x5401, @intFromPtr(&tty))))) return false;
    }
    if (!opts.decode and !opts.stdout and !opts.force and std.mem.endsWith(u8, name, opts.suffix)) {
        warned = true;
        return true;
    }
    const st = if (standard) null else u.stat(name, false) orelse {
        u.errf("gzip: {s}: cannot stat\n", .{name});
        return false;
    };
    if (st != null and st.?.mode & linux.S.IFMT == linux.S.IFDIR) {
        if (!opts.recursive) {
            warned = true;
            return true;
        }
        var entries = u.Vec(u.DirEnt).init(u.alloc);
        if (!u.listDir(name, &entries)) return false;
        var success = true;
        for (entries.items) |entry| {
            const path = std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ name, entry.name }) catch return false;
            if (!process(path, opts)) success = false;
        }
        return success;
    }
    if (st != null and st.?.mode & linux.S.IFMT != linux.S.IFREG) {
        warned = true;
        return true;
    }
    if (st != null and st.?.nlink > 1 and !opts.keep and !opts.stdout and !opts.force) {
        warned = true;
        return true;
    }
    const file = if (standard) u.File{ .fd = 0 } else u.File.open(name, .{ .ACCMODE = .RDONLY }, 0) orelse return false;
    defer if (!standard) file.close();
    var source_buffer: [65536]u8 = undefined;
    var source = Source.init(file, &source_buffer);
    const metadata = if (opts.decode) header(&source.reader) catch if (opts.force and (opts.stdout or standard)) Header{} else return false else Header{};
    const to_stdout = opts.stdout or standard;
    var target: ?[]const u8 = null;
    var output = u.File{ .fd = if (opts.test_only) -1 else 1 };
    if (!to_stdout and !opts.test_only) {
        target = if (!opts.decode) std.fmt.allocPrint(u.alloc, "{s}{s}", .{ name, opts.suffix }) catch return false else blk: {
            if (opts.restore_name and metadata.name != null) break :blk std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ u.dirname(name), metadata.name.? }) catch return false;
            if (std.mem.endsWith(u8, name, opts.suffix)) break :blk name[0 .. name.len - opts.suffix.len];
            if (std.mem.endsWith(u8, name, ".tgz")) break :blk std.fmt.allocPrint(u.alloc, "{s}.tar", .{name[0 .. name.len - 4]}) catch return false;
            return false;
        };
        if (same(target.?, name)) return false;
        if (!opts.force and u.stat(target.?, false) != null) {
            warned = true;
            return true;
        }
        output = u.File.open(target.?, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = !opts.force, .TRUNC = opts.force }, if (st) |value| value.mode & 0o777 else 0o666) orelse return false;
    }
    defer if (target != null) output.close();
    var output_buffer: [16384]u8 = undefined;
    var sink = Sink.init(output, &output_buffer);
    const success: bool = blk: {
        if (opts.decode) {
            decompress(&source.reader, &sink.writer, opts.force) catch break :blk false;
        } else {
            compress(file, &sink.writer, if (standard) null else name, st, opts) catch break :blk false;
        }
        sink.writer.flush() catch break :blk false;
        break :blk true;
    };
    if (!success) {
        if (target) |path| _ = linux.unlink(u.zstr(path));
        return false;
    }
    if (target) |path| {
        if (st) |original| {
            var attributes = original;
            if (opts.decode and opts.restore_name and metadata.mtime > 0) {
                attributes.mtime = metadata.mtime;
                attributes.mtime_nsec = 0;
            }
            _ = linux.fchmod(output.fd, original.mode & 0o777);
            _ = u.setTimes(path, attributes, true);
        }
        if (!opts.keep and !u.ok(linux.unlink(u.zstr(name)))) return false;
    }
    if (opts.verbose and !opts.quiet) u.errf("{s}: OK\n", .{name});
    return true;
}
pub fn gzip(args: []const []const u8) u8 {
    return run(args, false, false);
}
pub fn gunzip(args: []const []const u8) u8 {
    return run(args, true, false);
}
pub fn zcat(args: []const []const u8) u8 {
    return run(args, true, true);
}
fn run(args: []const []const u8, decode: bool, stdout: bool) u8 {
    warned = false;
    var opts = Options{ .decode = decode, .stdout = stdout };
    var files = u.Vec([]const u8).init(u.alloc);
    var options = true;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and std.mem.startsWith(u8, arg, "--")) {
            if (same(arg, "--decompress") or same(arg, "--uncompress")) opts.decode = true else if (same(arg, "--stdout") or same(arg, "--to-stdout")) opts.stdout = true else if (same(arg, "--keep")) opts.keep = true else if (same(arg, "--force")) opts.force = true else if (same(arg, "--quiet")) opts.quiet = true else if (same(arg, "--verbose")) opts.verbose = true else if (same(arg, "--recursive")) opts.recursive = true else if (same(arg, "--no-name")) {
                opts.save_name = false;
                opts.restore_name = false;
            } else if (same(arg, "--name")) {
                opts.save_name = true;
                opts.restore_name = true;
            } else if (same(arg, "--test")) {
                opts.decode = true;
                opts.test_only = true;
            } else if (same(arg, "--fast")) opts.level = 1 else if (same(arg, "--best")) opts.level = 9 else if (std.mem.startsWith(u8, arg, "--suffix=")) opts.suffix = arg[9..] else return bad();
            continue;
        }
        if (options and arg.len > 1 and arg[0] == '-') {
            var k: usize = 1;
            while (k < arg.len) : (k += 1) switch (arg[k]) {
                'd' => opts.decode = true,
                'c' => opts.stdout = true,
                'k' => opts.keep = true,
                'f' => opts.force = true,
                'q' => opts.quiet = true,
                'v' => opts.verbose = true,
                'r' => opts.recursive = true,
                'n' => {
                    opts.save_name = false;
                    opts.restore_name = false;
                },
                'N' => {
                    opts.save_name = true;
                    opts.restore_name = true;
                },
                't' => {
                    opts.decode = true;
                    opts.test_only = true;
                },
                '1'...'9' => opts.level = arg[k] - '0',
                'S' => {
                    opts.suffix = if (k + 1 < arg.len) arg[k + 1 ..] else blk: {
                        i += 1;
                        if (i == args.len) return bad();
                        break :blk args[i];
                    };
                    break;
                },
                else => return bad(),
            };
        } else files.push(arg);
    }
    if (opts.suffix.len == 0) return bad();
    if (files.items.len == 0) files.push("-");
    var failed = false;
    for (files.items) |name| if (!process(name, opts)) {
        if (!opts.quiet) u.errf("gzip: {s}: operation failed\n", .{name});
        failed = true;
    };
    return if (failed) 1 else if (warned) 2 else 0;
}
fn bad() u8 {
    u.errf("gzip: invalid option or operand\n", .{});
    return 1;
}
