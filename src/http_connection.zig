// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0
const std = @import("std");
const u = @import("util.zig");
const linux = std.os.linux;
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/socket.h");
    @cInclude("netdb.h");
    @cInclude("poll.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("time.h");
});
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Tls = @import("tls_client.zig");
const Bundle = std.crypto.Certificate.Bundle;

pub const Connection = struct {
    fd: c_int,
    timeout: c_int,
    input: Input,
    output: Output,
    reader: *Reader,
    writer: *Writer,
    tls: ?*Tls = null,
    ca: Bundle = .empty,
    ca_lock: std.Io.RwLock = .init,
    encrypted_read: [65536]u8 = undefined,
    encrypted_write: [65536]u8 = undefined,
    plain_read: [65536]u8 = undefined,
    plain_write: [65536]u8 = undefined,

    pub fn open(host: []const u8, port: u16, connect_timeout: c_int, read_timeout: c_int) !*Connection {
        const result = try u.alloc.create(Connection);
        errdefer u.alloc.destroy(result);
        var port_buffer: [8]u8 = undefined;
        const service = try std.fmt.bufPrintZ(&port_buffer, "{d}", .{port});
        var addresses: [*c]c.struct_addrinfo = null;
        const hints = std.mem.zeroInit(c.struct_addrinfo, .{ .ai_family = c.AF_UNSPEC, .ai_socktype = c.SOCK_STREAM });
        if (c.getaddrinfo(u.zstr(host), service, &hints, &addresses) != 0) return error.DnsFailure;
        defer c.freeaddrinfo(addresses);
        var address = addresses;
        while (address != null) : (address = address.*.ai_next) {
            const fd = c.socket(address.*.ai_family, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
            if (fd < 0) continue;
            var connected = c.connect(fd, address.*.ai_addr, address.*.ai_addrlen) == 0;
            if (!connected and c.__errno_location().* == c.EINPROGRESS) {
                wait(fd, c.POLLOUT, connect_timeout) catch {
                    _ = c.close(fd);
                    continue;
                };
                var code: c_int = 0;
                var size: c.socklen_t = @sizeOf(c_int);
                connected = c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &code, &size) == 0 and code == 0;
            }
            if (!connected) {
                _ = c.close(fd);
                continue;
            }
            result.* = .{ .fd = fd, .timeout = read_timeout, .input = undefined, .output = undefined, .reader = undefined, .writer = undefined };
            result.input = Input.init(fd, read_timeout, &result.encrypted_read);
            result.output = Output.init(fd, read_timeout, &result.encrypted_write);
            result.reader = &result.input.reader;
            result.writer = &result.output.writer;
            return result;
        }
        return error.ConnectionFailed;
    }
    pub fn startTls(self: *Connection, host: []const u8, ca_file: ?[]const u8, verify: bool) !void {
        const now: i64 = @intCast(c.time(null));
        if (verify) {
            if (ca_file) |path| {
                try self.loadPem(path, now);
            } else if (u.getEnv("SSL_CERT_FILE")) |path| {
                try self.loadPem(path, now);
            } else {
                for ([_][]const u8{ "/etc/pki/tls/certs/ca-bundle.crt", "/etc/ssl/certs/ca-certificates.crt", "/etc/ssl/cert.pem", "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem" }) |path| {
                    self.loadPem(path, now) catch continue;
                    if (self.ca.map.count() > 0) break;
                }
            }
            if (self.ca.map.count() == 0) return error.NoTrustedCertificates;
        }
        var entropy: [Tls.Options.entropy_len]u8 = undefined;
        var used: usize = 0;
        while (used < entropy.len) {
            const rc = linux.getrandom(entropy[used..].ptr, entropy.len - used, 0);
            if (u.errno(rc) == .INTR) continue;
            if (!u.ok(rc) or rc == 0) return error.InsufficientEntropy;
            used += rc;
        }
        const client = try u.alloc.create(Tls);
        errdefer u.alloc.destroy(client);
        // This bundle is private to one connection in a single-threaded binary.
        // Its RwLock is never contended and does not invoke an I/O backend.
        var policy = @import("x509_policy.zig").Policy{ .host = host, .now = now };
        client.* = try Tls.init(self.reader, self.writer, .{
            .certificate_policy = if (verify) &policy else null,
            .host = if (verify) .{ .explicit = host } else .no_verification,
            .ca = if (verify) .{ .bundle = .{ .gpa = u.alloc, .io = .failing, .lock = &self.ca_lock, .bundle = &self.ca } } else .no_verification,
            .write_buffer = &self.plain_write,
            .read_buffer = &self.plain_read,
            .entropy = &entropy,
            .realtime_now = .fromNanoseconds(@as(i96, now) * 1000000000),
        });
        self.tls = client;
        self.reader = &client.reader;
        self.writer = &client.writer;
    }
    fn loadPem(self: *Connection, path: []const u8, now: i64) !void {
        const data = @import("input.zig").read(path, true) orelse return error.CannotReadCaFile;
        defer u.alloc.free(data);
        const begin = "-----BEGIN CERTIFICATE-----";
        const end = "-----END CERTIFICATE-----";
        var position: usize = 0;
        var found = false;
        while (std.mem.indexOfPos(u8, data, position, begin)) |start| {
            const stop = std.mem.indexOfPos(u8, data, start + begin.len, end) orelse return error.InvalidCaFile;
            var text = std.ArrayList(u8).empty;
            defer text.deinit(u.alloc);
            for (data[start + begin.len .. stop]) |byte| if (!std.ascii.isWhitespace(byte)) {
                try text.append(u.alloc, byte);
            };
            const length = try std.base64.standard.Decoder.calcSizeForSlice(text.items);
            const offset = self.ca.bytes.items.len;
            if (offset + length > std.math.maxInt(u32)) return error.InvalidCaFile;
            try self.ca.bytes.resize(u.alloc, offset + length);
            try std.base64.standard.Decoder.decode(self.ca.bytes.items[offset..], text.items);
            try self.ca.parseCert(u.alloc, @intCast(offset), now);
            found = true;
            position = stop + end.len;
        }
        if (!found) return error.InvalidCaFile;
    }
    pub fn close(self: *Connection) void {
        if (self.tls) |client| {
            client.end() catch {};
            self.output.writer.flush() catch {};
            u.alloc.destroy(client);
        }
        _ = c.close(self.fd);
        self.ca.deinit(u.alloc);
        u.alloc.destroy(self);
    }
};
fn wait(fd: c_int, events: c_short, timeout: c_int) !void {
    var pollfd = c.struct_pollfd{ .fd = fd, .events = events, .revents = 0 };
    while (true) {
        const result = c.poll(&pollfd, 1, timeout);
        if (result > 0) return;
        if (result < 0 and c.__errno_location().* == c.EINTR) continue;
        return if (result == 0) error.Timeout else error.NetworkFailure;
    }
}
const Input = struct {
    fd: c_int,
    timeout: c_int,
    reader: Reader,
    fn init(fd: c_int, timeout: c_int, buffer: []u8) Input {
        return .{ .fd = fd, .timeout = timeout, .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 } };
    }
    fn stream(reader: *Reader, writer: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        const self: *Input = @fieldParentPtr("reader", reader);
        var buffer: [16384]u8 = undefined;
        const max = limit.minInt(buffer.len);
        if (max == 0) return 0;
        while (true) {
            wait(self.fd, c.POLLIN, self.timeout) catch return error.ReadFailed;
            const n = c.recv(self.fd, &buffer, max, 0);
            if (n < 0) {
                const code = c.__errno_location().*;
                if (code == c.EINTR or code == c.EAGAIN) continue;
                return error.ReadFailed;
            }
            if (n == 0) return error.EndOfStream;
            try writer.writeAll(buffer[0..@intCast(n)]);
            return @intCast(n);
        }
    }
};
const Output = struct {
    fd: c_int,
    timeout: c_int,
    writer: Writer,
    fn init(fd: c_int, timeout: c_int, buffer: []u8) Output {
        return .{ .fd = fd, .timeout = timeout, .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }
    fn write(self: *Output, bytes: []const u8) Writer.Error!void {
        var used: usize = 0;
        while (used < bytes.len) {
            wait(self.fd, c.POLLOUT, self.timeout) catch return error.WriteFailed;
            const n = c.send(self.fd, bytes[used..].ptr, bytes.len - used, c.MSG_NOSIGNAL);
            if (n < 0) {
                const code = c.__errno_location().*;
                if (code == c.EINTR or code == c.EAGAIN) continue;
                return error.WriteFailed;
            }
            if (n == 0) return error.WriteFailed;
            used += @intCast(n);
        }
    }
    fn drain(writer: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *Output = @fieldParentPtr("writer", writer);
        try self.write(writer.buffer[0..writer.end]);
        writer.end = 0;
        var used: usize = 0;
        for (data[0 .. data.len - 1]) |part| {
            try self.write(part);
            used += part.len;
        }
        for (0..splat) |_| {
            const part = data[data.len - 1];
            try self.write(part);
            used += part.len;
        }
        return used;
    }
};
