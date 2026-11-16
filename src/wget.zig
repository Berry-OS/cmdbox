// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0
const std = @import("std");
const u = @import("util.zig");
const linux = std.os.linux;
const Connection = @import("http_connection.zig").Connection;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Options = struct {
    output: ?[]const u8 = null,
    directory: ?[]const u8 = null,
    ca_file: ?[]const u8 = null,
    verify: bool = true,
    quiet: bool = false,
    verbose: bool = true,
    server_response: bool = false,
    offset: bool = false,
    no_clobber: bool = false,
    spider: bool = false,
    no_proxy: bool = false,
    save_headers: bool = false,
    content_disposition: bool = false,
    trust_names: bool = false,
    user_agent: []const u8 = "cmdbox/0.3.0",
    referer: ?[]const u8 = null,
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    body: ?[]const u8 = null,
    method: []const u8 = "GET",
    headers: []const []const u8 = &.{},
    connect_timeout: c_int = 900000,
    read_timeout: c_int = 900000,
    tries: usize = 20,
    redirects: usize = 20,
    logfile: ?[]const u8 = null,
    append_log: bool = false,
};
const Url = struct {
    https: bool,
    host: []const u8,
    port: u16,
    path: []const u8,
    authority: []const u8,
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    fn parse(value: []const u8) !Url {
        for (value) |byte| if (byte < 32 or byte == 127) return error.InvalidUrl;
        const https = std.mem.startsWith(u8, value, "https://");
        const start: usize = if (https) 8 else if (std.mem.startsWith(u8, value, "http://")) 7 else return error.UnsupportedScheme;
        const end = std.mem.indexOfAnyPos(u8, value, start, "/?#") orelse value.len;
        var authority = value[start..end];
        if (authority.len == 0) return error.InvalidUrl;
        var user: ?[]const u8 = null;
        var password: ?[]const u8 = null;
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
            const info = authority[0..at];
            const colon = std.mem.indexOfScalar(u8, info, ':');
            user = try percent(info[0 .. colon orelse info.len]);
            password = if (colon) |pos| try percent(info[pos + 1 ..]) else "";
            authority = authority[at + 1 ..];
        }
        var host = authority;
        var port: u16 = if (https) 443 else 80;
        if (host.len > 0 and host[0] == '[') {
            const close = std.mem.indexOfScalar(u8, host, ']') orelse return error.InvalidUrl;
            const tail = host[close + 1 ..];
            host = host[1..close];
            if (tail.len > 0) {
                if (tail[0] != ':') return error.InvalidUrl;
                port = try std.fmt.parseInt(u16, tail[1..], 10);
            }
        } else if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
            port = try std.fmt.parseInt(u16, host[colon + 1 ..], 10);
            host = host[0..colon];
        }
        if (host.len == 0 or port == 0) return error.InvalidUrl;
        const fragment = std.mem.indexOfScalarPos(u8, value, end, '#') orelse value.len;
        const raw = value[end..fragment];
        const path = if (raw.len == 0) "/" else if (raw[0] == '?') try std.fmt.allocPrint(u.alloc, "/{s}", .{raw}) else raw;
        var escaped = std.ArrayList(u8).empty;
        for (path) |byte| {
            if (byte == ' ') try escaped.appendSlice(u.alloc, "%20") else try escaped.append(u.alloc, byte);
        }
        return .{ .https = https, .host = host, .port = port, .path = escaped.items, .authority = authority, .user = user, .password = password };
    }
    fn resolve(self: Url, location: []const u8) ![]const u8 {
        const scheme = if (self.https) "https" else "http";
        if (std.mem.startsWith(u8, location, "http://") or std.mem.startsWith(u8, location, "https://")) return u.alloc.dupe(u8, location);
        if (std.mem.startsWith(u8, location, "//")) return std.fmt.allocPrint(u.alloc, "{s}:{s}", .{ scheme, location });
        if (location.len == 0) return error.InvalidRedirect;
        if (location[0] == '/') return std.fmt.allocPrint(u.alloc, "{s}://{s}{s}", .{ scheme, self.authority, location });
        const query = std.mem.indexOfScalar(u8, self.path, '?') orelse self.path.len;
        if (location[0] == '?') return std.fmt.allocPrint(u.alloc, "{s}://{s}{s}{s}", .{ scheme, self.authority, self.path[0..query], location });
        const target = try std.fs.path.resolve(u.alloc, &.{ u.dirname(self.path[0..query]), location });
        return std.fmt.allocPrint(u.alloc, "{s}://{s}{s}{s}", .{ scheme, self.authority, target, if (std.mem.endsWith(u8, location, "/") and !std.mem.endsWith(u8, target, "/")) "/" else "" });
    }
};
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn percent(text: []const u8) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            const high = try std.fmt.charToDigit(text[i + 1], 16);
            const low = try std.fmt.charToDigit(text[i + 2], 16);
            const byte = high * 16 + low;
            if (byte == 0 or byte == '\r' or byte == '\n') return error.InvalidUrl;
            try output.append(u.alloc, byte);
            i += 2;
        } else try output.append(u.alloc, text[i]);
    }
    return output.items;
}
fn auth(user: []const u8, password: []const u8) ![]const u8 {
    const text = try std.fmt.allocPrint(u.alloc, "{s}:{s}", .{ user, password });
    const output = try u.alloc.alloc(u8, std.base64.standard.Encoder.calcSize(text.len));
    return std.base64.standard.Encoder.encode(output, text);
}
fn timeout(value: []const u8) !c_int {
    const seconds = try std.fmt.parseFloat(f64, value);
    if (!std.math.isFinite(seconds) or seconds < 0) return error.InvalidTimeout;
    if (seconds == 0) return -1;
    return @intFromFloat(@min(@max(@ceil(seconds * 1000), 1), 2147483647));
}
fn noProxy(host: []const u8, opts: Options) bool {
    if (opts.no_proxy) return true;
    var tokens = std.mem.splitScalar(u8, u.getEnv("no_proxy") orelse u.getEnv("NO_PROXY") orelse "", ',');
    while (tokens.next()) |raw| {
        const token = std.mem.trim(u8, raw, " \t");
        if (same(token, "*")) return true;
        if (token.len == 0) continue;
        const domain = std.mem.trimStart(u8, token, ".");
        if (std.ascii.eqlIgnoreCase(host, domain) or host.len > domain.len and host[host.len - domain.len - 1] == '.' and std.ascii.endsWithIgnoreCase(host, domain)) return true;
    }
    return false;
}
fn proxyFor(url: Url, opts: Options) !?Url {
    if (noProxy(url.host, opts)) return null;
    const value = if (url.https) u.getEnv("https_proxy") orelse u.getEnv("HTTPS_PROXY") else u.getEnv("http_proxy");
    if (value) |text| {
        if (text.len == 0) return null;
        const proxy = try Url.parse(text);
        if (proxy.https) return error.UnsupportedProxy;
        return proxy;
    }
    return null;
}
const Response = struct { status: u16, length: ?u64 = null, chunked: bool = false, location: ?[]const u8 = null, range: ?[]const u8 = null, filename: ?[]const u8 = null, raw: []const u8 = "" };
fn line(reader: *Reader) ![]const u8 {
    const text = try reader.takeDelimiterInclusive('\n');
    return std.mem.trimEnd(u8, text[0 .. text.len - 1], "\r");
}
fn headers(reader: *Reader, opts: Options) !Response {
    while (true) {
        var raw = std.ArrayList(u8).empty;
        const first = try line(reader);
        if (!std.mem.startsWith(u8, first, "HTTP/")) return error.BadResponse;
        const space = std.mem.indexOfScalar(u8, first, ' ') orelse return error.BadResponse;
        if (space + 4 > first.len) return error.BadResponse;
        var result = Response{ .status = try std.fmt.parseInt(u16, first[space + 1 .. space + 4], 10) };
        try raw.appendSlice(u.alloc, first);
        try raw.appendSlice(u.alloc, "\r\n");
        if (opts.server_response and !opts.quiet) u.errf("  {s}\n", .{first});
        while (true) {
            const text = try line(reader);
            try raw.appendSlice(u.alloc, text);
            try raw.appendSlice(u.alloc, "\r\n");
            if (raw.items.len > 1048576) return error.BadResponse;
            if (text.len == 0) break;
            if (opts.server_response and !opts.quiet) u.errf("  {s}\n", .{text});
            const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.BadResponse;
            const name = text[0..colon];
            const value = std.mem.trim(u8, text[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
                const n = try std.fmt.parseInt(u64, value, 10);
                if (result.length != null and result.length.? != n) return error.BadResponse;
                result.length = n;
            } else if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) {
                if (!std.ascii.eqlIgnoreCase(value, "chunked")) return error.BadResponse;
                result.chunked = true;
            } else if (std.ascii.eqlIgnoreCase(name, "Location")) result.location = try u.alloc.dupe(u8, value) else if (std.ascii.eqlIgnoreCase(name, "Content-Range")) result.range = try u.alloc.dupe(u8, value) else if (std.ascii.eqlIgnoreCase(name, "Content-Disposition")) {
                if (std.mem.indexOf(u8, value, "filename=")) |at| {
                    var filename = std.mem.trim(u8, value[at + 9 ..], " \t\"");
                    if (std.mem.indexOfScalar(u8, filename, ';')) |end| filename = filename[0..end];
                    result.filename = try u.alloc.dupe(u8, u.basename(std.mem.trim(u8, filename, "\"")));
                }
            }
        }
        result.raw = raw.items;
        if (result.status >= 100 and result.status < 200 and result.status != 101) continue;
        return result;
    }
}
fn writeBody(reader: *Reader, file: u.File, count: ?u64) !void {
    var remaining = count;
    var buffer: [16384]u8 = undefined;
    while (remaining == null or remaining.? > 0) {
        const maximum = if (remaining) |n| @min(n, buffer.len) else buffer.len;
        const got = reader.readSliceShort(buffer[0..@intCast(maximum)]) catch return error.NetworkFailure;
        if (got == 0) {
            if (remaining != null and remaining.? > 0) return error.NetworkFailure;
            break;
        }
        if (!file.write(buffer[0..got])) return error.FileFailure;
        if (remaining) |*n| n.* -= got;
    }
}
fn body(reader: *Reader, file: u.File, response: Response) !void {
    if (response.chunked) {
        while (true) {
            const header = try line(reader);
            const end = std.mem.indexOfScalar(u8, header, ';') orelse header.len;
            const size = try std.fmt.parseInt(u64, std.mem.trim(u8, header[0..end], " \t"), 16);
            if (size == 0) {
                while (true) {
                    if ((try line(reader)).len == 0) break;
                }
                return;
            }
            try writeBody(reader, file, size);
            if (!same(try reader.take(2), "\r\n")) return error.BadResponse;
        }
    } else try writeBody(reader, file, response.length);
}
fn makeDirectories(path: []const u8) !void {
    var pos: usize = 1;
    while (pos <= path.len) : (pos += 1) {
        if (pos != path.len and path[pos] != '/') continue;
        const part = path[0..pos];
        const rc = linux.mkdir(u.zstr(part), 0o777);
        if (!u.ok(rc) and (u.errno(rc) != .EXIST or !u.isDir(part))) return error.FileFailure;
    }
}
fn targetName(url: Url, opts: Options) ![]const u8 {
    if (opts.output) |name| return name;
    const basename = u.basename(url.path);
    const name = if (basename.len == 0 or same(url.path, "/") or std.mem.endsWith(u8, url.path, "/")) "index.html" else try percent(basename);
    if (same(name, ".") or same(name, "..") or std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidFilename;
    return if (opts.directory) |directory| try std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ directory, name }) else name;
}
fn request(conn: *Connection, url: Url, proxy: ?Url, opts: Options, method: []const u8, offset: u64, send_auth: bool) !void {
    const writer = conn.writer;
    const path = if (proxy != null and !url.https) try std.fmt.allocPrint(u.alloc, "http://{s}{s}", .{ url.authority, url.path }) else url.path;
    try writer.print("{s} {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: {s}\r\nAccept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n", .{ method, path, url.authority, opts.user_agent });
    if (opts.referer) |value| try writer.print("Referer: {s}\r\n", .{value});
    if (offset > 0) try writer.print("Range: bytes={d}-\r\n", .{offset});
    if (send_auth) {
        if (opts.user orelse url.user) |user| {
            const value = try auth(user, opts.password orelse url.password orelse "");
            try writer.print("Authorization: Basic {s}\r\n", .{value});
        }
    }
    if (proxy) |server| if (!url.https) {
        if (server.user) |user| try writer.print("Proxy-Authorization: Basic {s}\r\n", .{try auth(user, server.password orelse "")});
    };
    for (opts.headers) |value| try writer.print("{s}\r\n", .{value});
    if (opts.body != null and !same(method, "GET") and !same(method, "HEAD")) {
        const data = opts.body.?;
        try writer.print("Content-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n", .{data.len});
        try writer.writeAll(data);
    } else try writer.writeAll("\r\n");
    try writer.flush();
    try conn.output.writer.flush();
}
fn once(original: []const u8, opts: Options) u8 {
    const initial = Url.parse(original) catch return 2;
    var url = initial;
    var method = if (opts.spider) "HEAD" else opts.method;
    var name = targetName(initial, opts) catch return 3;
    var offset: u64 = if (opts.offset and !same(name, "-")) if (u.stat(name, true)) |st| st.size else 0 else 0;
    if (opts.no_clobber and !opts.offset and opts.output == null and u.stat(name, false) != null) return 0;
    var redirects: usize = 0;
    while (true) {
        const proxy = proxyFor(url, opts) catch return 4;
        const remote = proxy orelse url;
        const connection = Connection.open(remote.host, remote.port, opts.connect_timeout, opts.read_timeout) catch |err| {
            if (!opts.quiet) u.errf("wget: {s}: {s}\n", .{ remote.host, @errorName(err) });
            return 4;
        };
        defer connection.close();
        if (proxy != null and url.https) {
            const tunnel = std.fmt.allocPrint(u.alloc, "{s}{s}{s}:{d}", .{ if (std.mem.indexOfScalar(u8, url.host, ':') != null) "[" else "", url.host, if (std.mem.indexOfScalar(u8, url.host, ':') != null) "]" else "", url.port }) catch return 1;
            connection.writer.print("CONNECT {s} HTTP/1.1\r\nHost: {s}\r\n", .{ tunnel, tunnel }) catch return 4;
            if (proxy.?.user) |user| connection.writer.print("Proxy-Authorization: Basic {s}\r\n", .{auth(user, proxy.?.password orelse "") catch return 1}) catch return 4;
            connection.writer.writeAll("\r\n") catch return 4;
            connection.writer.flush() catch return 4;
            const reply = headers(connection.reader, opts) catch return 7;
            if (reply.status != 200) return 4;
        }
        if (url.https) {
            connection.startTls(url.host, opts.ca_file, opts.verify) catch |err| {
                if (!opts.quiet) u.errf("wget: TLS: {s}\n", .{@errorName(err)});
                return 5;
            };
        }
        request(connection, url, proxy, opts, method, offset, std.ascii.eqlIgnoreCase(initial.host, url.host) and initial.port == url.port and initial.https == url.https) catch |err| {
            if (!opts.quiet) u.errf("wget: request: {s}\n", .{@errorName(err)});
            return 4;
        };
        const response = headers(connection.reader, opts) catch |err| {
            if (!opts.quiet) u.errf("wget: response: {s} ({s})\n", .{ @errorName(err), if (connection.tls) |client| if (client.read_err) |cause| @errorName(cause) else "no TLS error" else "plain HTTP" });
            return 4;
        };
        if (response.status == 301 or response.status == 302 or response.status == 303 or response.status == 307 or response.status == 308) {
            if (redirects >= opts.redirects) return 8;
            const location = response.location orelse return 8;
            const next = url.resolve(location) catch return 8;
            url = Url.parse(next) catch return 8;
            redirects += 1;
            if (response.status == 303 or (response.status == 301 or response.status == 302) and same(method, "POST")) method = "GET";
            if (opts.trust_names and opts.output == null) name = targetName(url, opts) catch return 3;
            continue;
        }
        if (response.status == 416 and offset > 0) return 0;
        if (response.status < 200 or response.status >= 300) {
            if (!opts.quiet) u.errf("wget: server returned {d}\n", .{response.status});
            return if (response.status == 401 or response.status == 407) 6 else 8;
        }
        if (opts.spider or same(method, "HEAD") or response.status == 204 or response.status == 205) return 0;
        var append = false;
        if (offset > 0 and response.status == 206) {
            const range = response.range orelse return 7;
            const prefix = std.fmt.allocPrint(u.alloc, "bytes {d}-", .{offset}) catch return 1;
            if (!std.mem.startsWith(u8, range, prefix)) return 7;
            append = true;
        } else offset = 0;
        if (opts.content_disposition and opts.output == null) {
            if (response.filename) |filename| {
                if (filename.len > 0 and !same(filename, ".") and !same(filename, "..")) name = if (opts.directory) |directory| std.fmt.allocPrint(u.alloc, "{s}/{s}", .{ directory, filename }) catch return 3 else filename;
            }
        }
        if (opts.directory) |directory| makeDirectories(directory) catch return 3;
        var file = u.File{ .fd = 1 };
        if (!same(name, "-")) {
            if (opts.no_clobber and !append and u.stat(name, false) != null) return 0;
            if (opts.output == null and !opts.offset and !opts.no_clobber) {
                var suffix: usize = 0;
                const base = name;
                while (u.stat(name, false) != null) {
                    suffix += 1;
                    name = std.fmt.allocPrint(u.alloc, "{s}.{d}", .{ base, suffix }) catch return 3;
                }
            }
            file = u.File.open(name, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = append, .TRUNC = !append }, 0o666) orelse return 3;
        }
        defer if (file.fd != 1) file.close();
        if (opts.save_headers and !file.write(response.raw)) return 3;
        body(connection.reader, file, response) catch |err| {
            if (!opts.quiet) u.errf("wget: body: {s}\n", .{@errorName(err)});
            return if (err == error.FileFailure) 3 else 4;
        };
        if (opts.verbose and !opts.quiet and !same(name, "-")) u.errf("wget: saved {s}\n", .{name});
        return 0;
    }
}
pub fn run(args: []const []const u8) u8 {
    var opts = Options{};
    var urls = u.Vec([]const u8).init(u.alloc);
    var headers_list = u.Vec([]const u8).init(u.alloc);
    var options = true;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (options and same(arg, "--")) {
            options = false;
            continue;
        }
        if (options and std.mem.startsWith(u8, arg, "--")) {
            if (same(arg, "--quiet")) {
                opts.quiet = true;
                continue;
            }
            if (same(arg, "--verbose")) {
                opts.verbose = true;
                continue;
            }
            if (same(arg, "--no-verbose")) {
                opts.verbose = false;
                continue;
            }
            if (same(arg, "--continue")) {
                opts.offset = true;
                continue;
            }
            if (same(arg, "--no-clobber")) {
                opts.no_clobber = true;
                continue;
            }
            if (same(arg, "--spider")) {
                opts.spider = true;
                continue;
            }
            if (same(arg, "--no-proxy")) {
                opts.no_proxy = true;
                continue;
            }
            if (same(arg, "--no-check-certificate")) {
                opts.verify = false;
                continue;
            }
            if (same(arg, "--check-certificate")) {
                opts.verify = true;
                continue;
            }
            if (same(arg, "--server-response")) {
                opts.server_response = true;
                continue;
            }
            if (same(arg, "--save-headers")) {
                opts.save_headers = true;
                continue;
            }
            if (same(arg, "--content-disposition")) {
                opts.content_disposition = true;
                continue;
            }
            if (same(arg, "--trust-server-names")) {
                opts.trust_names = true;
                continue;
            }
            const equal = std.mem.indexOfScalar(u8, arg, '=');
            const name = arg[0 .. equal orelse arg.len];
            const value = if (equal) |at| arg[at + 1 ..] else blk: {
                i += 1;
                if (i == args.len) return bad(arg);
                break :blk args[i];
            };
            if (same(name, "--output-document")) opts.output = value else if (same(name, "--directory-prefix")) opts.directory = value else if (same(name, "--ca-certificate")) opts.ca_file = value else if (same(name, "--user-agent")) opts.user_agent = value else if (same(name, "--referer")) opts.referer = value else if (same(name, "--user") or same(name, "--http-user")) opts.user = value else if (same(name, "--password") or same(name, "--http-password")) opts.password = value else if (same(name, "--timeout")) {
                const n = timeout(value) catch return bad(arg);
                opts.read_timeout = n;
                opts.connect_timeout = n;
            } else if (same(name, "--read-timeout")) opts.read_timeout = timeout(value) catch return bad(arg) else if (same(name, "--connect-timeout")) opts.connect_timeout = timeout(value) catch return bad(arg) else if (same(name, "--tries")) opts.tries = std.fmt.parseInt(usize, value, 10) catch return bad(arg) else if (same(name, "--max-redirect")) opts.redirects = std.fmt.parseInt(usize, value, 10) catch return bad(arg) else if (same(name, "--header")) {
                if (std.mem.indexOfAny(u8, value, "\r\n") != null or std.mem.indexOfScalar(u8, value, ':') == null) return bad(arg);
                headers_list.push(value);
            } else if (same(name, "--method")) opts.method = value else if (same(name, "--post-data") or same(name, "--body-data")) {
                opts.body = value;
                if (same(name, "--post-data")) opts.method = "POST";
            } else if (same(name, "--post-file") or same(name, "--body-file")) {
                opts.body = @import("input.zig").read(value, false) orelse return 3;
                if (same(name, "--post-file")) opts.method = "POST";
            } else if (same(name, "--output-file")) {
                opts.logfile = value;
                opts.append_log = false;
            } else if (same(name, "--append-output")) {
                opts.logfile = value;
                opts.append_log = true;
            } else if (same(name, "--input-file")) {
                if (!inputUrls(&urls, value)) return 3;
            } else return bad(arg);
            continue;
        }
        if (options and arg.len > 1 and arg[0] == '-') {
            var k: usize = 1;
            while (k < arg.len) : (k += 1) switch (arg[k]) {
                'q' => opts.quiet = true,
                'v' => opts.verbose = true,
                'c' => opts.offset = true,
                'S' => opts.server_response = true,
                'n' => {
                    if (k + 1 == arg.len) return bad(arg);
                    k += 1;
                    if (arg[k] == 'v') opts.verbose = false else if (arg[k] == 'c') opts.no_clobber = true else return bad(arg);
                },
                'O', 'P', 'U', 'T', 't', 'o', 'a', 'i' => |flag| {
                    const value = if (k + 1 < arg.len) arg[k + 1 ..] else blk: {
                        i += 1;
                        if (i == args.len) return bad(arg);
                        break :blk args[i];
                    };
                    switch (flag) {
                        'O' => opts.output = value,
                        'P' => opts.directory = value,
                        'U' => opts.user_agent = value,
                        'T' => {
                            const n = timeout(value) catch return bad(arg);
                            opts.read_timeout = n;
                            opts.connect_timeout = n;
                        },
                        't' => opts.tries = std.fmt.parseInt(usize, value, 10) catch return bad(arg),
                        'o' => {
                            opts.logfile = value;
                            opts.append_log = false;
                        },
                        'a' => {
                            opts.logfile = value;
                            opts.append_log = true;
                        },
                        'i' => if (!inputUrls(&urls, value)) return 3,
                        else => unreachable,
                    }
                    break;
                },
                else => return bad(arg),
            };
        } else urls.push(arg);
    }
    if (urls.items.len == 0) return bad("missing URL");
    for ([_]?[]const u8{ opts.user_agent, opts.referer, opts.user }) |text| if (text) |value| {
        if (std.mem.indexOfAny(u8, value, "\r\n") != null) return bad("header contains newline");
    };
    if (opts.method.len == 0) return bad("empty method");
    for (opts.method) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null or byte == ' ') return bad("invalid method");
    opts.headers = headers_list.items;
    if (opts.logfile) |path| {
        const file = u.File.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = opts.append_log, .TRUNC = !opts.append_log }, 0o666) orelse return 3;
        if (!u.ok(linux.dup2(file.fd, 2))) {
            file.close();
            return 3;
        }
        if (file.fd != 2) file.close();
    }
    var result: u8 = 0;
    for (urls.items) |url| {
        var attempt: usize = 0;
        var code: u8 = 1;
        while (opts.tries == 0 or attempt < opts.tries) {
            code = once(url, opts);
            attempt += 1;
            if (code != 4 or opts.tries != 0 and attempt >= opts.tries) break;
            var delay = linux.timespec{ .sec = @intCast(@min(attempt, 10)), .nsec = 0 };
            _ = linux.nanosleep(&delay, null);
        }
        if (code != 0 and (result == 0 or code < result)) result = code;
    }
    return result;
}
fn inputUrls(urls: *u.Vec([]const u8), name: []const u8) bool {
    const data = @import("input.zig").read(name, false) orelse return false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r");
        if (value.len > 0 and value[0] != '#') urls.push(value);
    }
    return true;
}
fn bad(value: []const u8) u8 {
    u.errf("wget: invalid option or URL: {s}\n", .{value});
    return 2;
}
