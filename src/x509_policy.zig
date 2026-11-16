// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0
//! Additional RFC 5280 policy for the Zig TLS client's signature/chain checks.
//! Unsupported constraints fail closed, including name and policy constraints.
const std = @import("std");
const Certificate = std.crypto.Certificate;
const c = @cImport({
    @cInclude("arpa/inet.h");
});
const u = @import("util.zig");
const Element = struct {
    tag: u8,
    value: []const u8,
    fn take(bytes: *[]const u8) !Element {
        if (bytes.len < 2) return error.InvalidDer;
        const tag = bytes.*[0];
        var len: usize = bytes.*[1];
        var start: usize = 2;
        if (len >= 128) {
            const count = len & 127;
            if (count == 0 or count > @sizeOf(usize) or bytes.len < 2 + count or bytes.*[2] == 0) return error.InvalidDer;
            len = 0;
            for (bytes.*[2..][0..count]) |b| len = (std.math.mul(usize, len, 256) catch return error.InvalidDer) + @as(usize, b);
            start += count;
            if (len < 128) return error.InvalidDer;
        }
        if (len > bytes.len - start) return error.InvalidDer;
        const value = bytes.*[start..][0..len];
        bytes.* = bytes.*[start + len ..];
        return .{ .tag = tag, .value = value };
    }
};
fn single(bytes: []const u8, tag: u8) ![]const u8 {
    var rest = bytes;
    const e = try Element.take(&rest);
    if (e.tag != tag or rest.len != 0) return error.InvalidDer;
    return e.value;
}
fn number(bytes: []const u8) !usize {
    if (bytes.len == 0 or bytes[0] >= 128 or bytes.len > @sizeOf(usize)) return error.InvalidDer;
    var n: usize = 0;
    for (bytes) |b| n = (std.math.mul(usize, n, 256) catch return error.InvalidDer) + b;
    return n;
}
pub const Policy = struct {
    host: []const u8,
    now: i64,
    ca_depth: usize = 0,
    pub fn peer(self: *Policy, cert: Certificate.Parsed, index: usize) bool {
        self.check(cert, index != 0) catch return false;
        if (index == 0) self.hostname(cert) catch return false;
        if (index != 0 and !std.mem.eql(u8, cert.subject(), cert.issuer())) self.ca_depth += 1;
        return true;
    }
    pub fn anchor(self: *Policy, subject: Certificate.Parsed, issuer: Certificate.Parsed) bool {
        const identical = std.mem.eql(u8, subject.message(), issuer.message()) and std.mem.eql(u8, subject.signature(), issuer.signature());
        // An explicitly trusted end-entity certificate may be its own anchor.
        if (identical) return true;
        self.check(issuer, true) catch return false;
        return true;
    }
    fn hostname(self: *Policy, cert: Certificate.Parsed) !void {
        var ip: [16]u8 = undefined;
        const n: usize = if (c.inet_pton(c.AF_INET, u.zstr(self.host), &ip) == 1) 4 else if (c.inet_pton(c.AF_INET6, u.zstr(self.host), &ip) == 1) 16 else 0;
        if (n == 0) return cert.verifyHostName(self.host);
        var names = try single(cert.subjectAltName(), 0x30);
        while (names.len > 0) {
            const name = try Element.take(&names);
            if (name.tag == 0x87 and std.mem.eql(u8, name.value, ip[0..n])) return;
        }
        return error.HostMismatch;
    }
    fn check(self: *Policy, cert: Certificate.Parsed, is_ca: bool) !void {
        if (self.now < cert.validity.not_before or self.now > cert.validity.not_after) return error.Expired;
        var fields = try single(cert.message(), 0x30);
        var extensions: ?[]const u8 = null;
        while (fields.len > 0) {
            const field = try Element.take(&fields);
            if (field.tag == 0xa3) {
                if (extensions != null) return error.InvalidDer;
                extensions = try single(field.value, 0x30);
            }
        }
        var ca = false;
        var seen: [64][]const u8 = undefined;
        var count: usize = 0;
        var rest = extensions orelse "";
        while (rest.len > 0) {
            const ext = try Element.take(&rest);
            if (ext.tag != 0x30) return error.InvalidDer;
            var parts = ext.value;
            const oid = try Element.take(&parts);
            if (oid.tag != 6) return error.InvalidDer;
            for (seen[0..count]) |previous| if (std.mem.eql(u8, oid.value, previous)) return error.InvalidDer;
            if (count == seen.len) return error.InvalidDer;
            seen[count] = oid.value;
            count += 1;
            var value = try Element.take(&parts);
            var critical = false;
            if (value.tag == 1) {
                if (value.value.len != 1 or value.value[0] != 0xff) return error.InvalidDer;
                critical = true;
                value = try Element.take(&parts);
            }
            if (value.tag != 4 or parts.len != 0) return error.InvalidDer;
            const id: u8 = if (oid.value.len == 3 and oid.value[0] == 0x55 and oid.value[1] == 0x1d) oid.value[2] else 0;
            switch (id) {
                19 => { // BasicConstraints
                    var constraints = try single(value.value, 0x30);
                    if (constraints.len > 0) {
                        var first = try Element.take(&constraints);
                        if (first.tag == 1) {
                            if (first.value.len != 1 or first.value[0] != 0xff) return error.InvalidDer;
                            ca = true;
                            if (constraints.len == 0) continue;
                            first = try Element.take(&constraints);
                        }
                        if (!ca or first.tag != 2 or constraints.len != 0) return error.InvalidDer;
                        const depth = try number(first.value);
                        if (is_ca and self.ca_depth > depth) return error.PathLength;
                    }
                },
                15 => { // KeyUsage: ECDHE authentication / certificate signing
                    const bits = try single(value.value, 3);
                    if (bits.len < 2 or bits[0] > 7) return error.InvalidDer;
                    if (bits[1] & @as(u8, if (is_ca) 4 else 128) == 0) return error.KeyUsage;
                },
                37 => { // ExtendedKeyUsage
                    var usages = try single(value.value, 0x30);
                    var server = false;
                    while (usages.len > 0) {
                        const usage = try Element.take(&usages);
                        if (usage.tag != 6) return error.InvalidDer;
                        if (std.mem.eql(u8, usage.value, "\x2b\x06\x01\x05\x05\x07\x03\x01") or std.mem.eql(u8, usage.value, "\x55\x1d\x25\x00")) server = true;
                    }
                    if (!server) return error.ExtendedKeyUsage;
                },
                // Reject constraints we cannot enforce, even when noncritical.
                30, 36, 54 => return error.UnsupportedConstraint,
                17 => {
                    _ = try single(value.value, 0x30);
                }, // SAN checked on leaf
                14, 35 => if (critical) return error.UnsupportedCriticalExtension,
                else => if (critical) return error.UnsupportedCriticalExtension,
            }
        }
        if (is_ca and !ca) return error.NotCa;
    }
};
