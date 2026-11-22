// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// lspci - pciutils compatible listing from sysfs (names from pci.ids)
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const g = @import("getopt.zig");
const mnt = @import("mount.zig");
const c = @cImport({
    @cInclude("fnmatch.h");
});

// ---------------------------------------------------------------- pci.ids
var ids_data: ?[]const u8 = null;
var ids_loaded = false;

fn loadIds(path: ?[]const u8) void {
    if (ids_loaded) return;
    ids_loaded = true;
    const cands = [_][]const u8{ "/usr/share/hwdata/pci.ids", "/usr/share/misc/pci.ids", "/usr/share/pci.ids", "/usr/share/pciutils/pci.ids" };
    if (path) |p| {
        ids_data = mnt.readFile(p);
        return;
    }
    for (cands) |p| {
        if (mnt.readFile(p)) |d| {
            ids_data = d;
            return;
        }
    }
}

fn hex4(s: []const u8) ?u16 {
    if (s.len < 4) return null;
    return std.fmt.parseInt(u16, s[0..4], 16) catch null;
}

/// find the line range of a vendor's block
fn vendorBlock(v: u16) ?[]const u8 {
    const d = ids_data orelse return null;
    var key: [8]u8 = undefined;
    const k = std.fmt.bufPrint(&key, "\n{x:0>4}  ", .{v}) catch return null;
    var start: usize = 0;
    if (std.mem.startsWith(u8, d, k[1..])) start = 0 else {
        const at = std.mem.indexOf(u8, d, k) orelse return null;
        start = at + 1;
    }
    var end = start;
    var first = true;
    while (end < d.len) {
        const nl = std.mem.indexOfScalarPos(u8, d, end, '\n') orelse d.len;
        const line = d[end..nl];
        if (!first and line.len > 0 and line[0] != '\t' and line[0] != '#') break;
        first = false;
        end = nl + 1;
    }
    return d[start..@min(end, d.len)];
}

fn nameAfter(line: []const u8, skip: usize) []const u8 {
    var i = skip;
    while (i < line.len and line[i] == ' ') i += 1;
    return line[i..];
}

fn vendorName(v: u16) ?[]const u8 {
    const b = vendorBlock(v) orelse return null;
    const nl = std.mem.indexOfScalar(u8, b, '\n') orelse b.len;
    return nameAfter(b[0..nl], 4);
}

fn deviceName(v: u16, dv: u16) ?[]const u8 {
    const b = vendorBlock(v) orelse return null;
    var key: [8]u8 = undefined;
    const k = std.fmt.bufPrint(&key, "\n\t{x:0>4}  ", .{dv}) catch return null;
    const at = std.mem.indexOf(u8, b, k) orelse return null;
    const ls = at + 1;
    const nl = std.mem.indexOfScalarPos(u8, b, ls, '\n') orelse b.len;
    return nameAfter(b[ls..nl], 5);
}

fn subsysName(v: u16, dv: u16, sv: u16, sd: u16) ?[]const u8 {
    const b = vendorBlock(v) orelse return null;
    var key: [8]u8 = undefined;
    const k = std.fmt.bufPrint(&key, "\n\t{x:0>4}  ", .{dv}) catch return null;
    const at = std.mem.indexOf(u8, b, k) orelse return null;
    var pos = std.mem.indexOfScalarPos(u8, b, at + 1, '\n') orelse return null;
    pos += 1;
    var skey: [16]u8 = undefined;
    const sk = std.fmt.bufPrint(&skey, "\t\t{x:0>4} {x:0>4}  ", .{ sv, sd }) catch return null;
    while (pos < b.len) {
        const nl = std.mem.indexOfScalarPos(u8, b, pos, '\n') orelse b.len;
        const line = b[pos..nl];
        if (line.len < 2 or line[1] != '\t') {
            if (line.len > 0 and line[0] == '\t' and (line.len < 2 or line[1] != '\t')) break;
            if (line.len == 0) break;
        }
        if (std.mem.startsWith(u8, line, sk)) return nameAfter(line, sk.len);
        pos = nl + 1;
    }
    return null;
}

fn classBlock(cls: u8) ?[]const u8 {
    const d = ids_data orelse return null;
    var key: [8]u8 = undefined;
    const k = std.fmt.bufPrint(&key, "\nC {x:0>2}  ", .{cls}) catch return null;
    const at = std.mem.indexOf(u8, d, k) orelse return null;
    const start = at + 1;
    var end = start;
    var first = true;
    while (end < d.len) {
        const nl = std.mem.indexOfScalarPos(u8, d, end, '\n') orelse d.len;
        const line = d[end..nl];
        if (!first and line.len > 0 and line[0] != '\t' and line[0] != '#') break;
        first = false;
        end = nl + 1;
    }
    return d[start..@min(end, d.len)];
}

fn className(cls: u8, sub: u8) ?[]const u8 {
    const b = classBlock(cls) orelse return null;
    var key: [8]u8 = undefined;
    const k = std.fmt.bufPrint(&key, "\n\t{x:0>2}  ", .{sub}) catch return null;
    if (std.mem.indexOf(u8, b, k)) |at| {
        const ls = at + 1;
        const nl = std.mem.indexOfScalarPos(u8, b, ls, '\n') orelse b.len;
        return nameAfter(b[ls..nl], 3);
    }
    const nl = std.mem.indexOfScalar(u8, b, '\n') orelse b.len;
    return nameAfter(b[0..nl], 4);
}

fn progifName(cls: u8, sub: u8, pi: u8) ?[]const u8 {
    const b = classBlock(cls) orelse return null;
    var key: [8]u8 = undefined;
    const k = std.fmt.bufPrint(&key, "\n\t{x:0>2}  ", .{sub}) catch return null;
    const at = std.mem.indexOf(u8, b, k) orelse return null;
    var pos = std.mem.indexOfScalarPos(u8, b, at + 1, '\n') orelse return null;
    pos += 1;
    var pk: [8]u8 = undefined;
    const pks = std.fmt.bufPrint(&pk, "\t\t{x:0>2}  ", .{pi}) catch return null;
    while (pos < b.len) {
        const nl = std.mem.indexOfScalarPos(u8, b, pos, '\n') orelse b.len;
        const line = b[pos..nl];
        if (line.len < 2 or !(line[0] == '\t' and line[1] == '\t')) break;
        if (std.mem.startsWith(u8, line, pks)) return nameAfter(line, pks.len);
        pos = nl + 1;
    }
    return null;
}

// ---------------------------------------------------------------- devices
const Dev = struct {
    domain: u16,
    bus: u8,
    dev: u8,
    func: u8,
    vendor: u16,
    device: u16,
    cls: u32,
    rev: u8,
    sv: u16,
    sd: u16,
    sysname: []const u8,
    config: []u8 = &.{},
    cfg_len: usize = 0,
};

fn readHexFile(path: []const u8) ?u32 {
    const d = mnt.readFile(path) orelse return null;
    const t = std.mem.trim(u8, d, " \n\t");
    const s = if (std.mem.startsWith(u8, t, "0x")) t[2..] else t;
    return std.fmt.parseInt(u32, s, 16) catch null;
}

fn scanDevices() []Dev {
    var out = u.Vec(Dev).init(u.alloc);
    var ents = u.Vec(u.DirEnt).init(u.alloc);
    if (!u.listDir("/sys/bus/pci/devices", &ents)) return out.items;
    for (ents.items) |e| {
        // dddd:bb:dd.f
        const n = e.name;
        if (n.len < 12 or n[4] != ':' or n[7] != ':' or n[10] != '.') continue;
        const dom = std.fmt.parseInt(u16, n[0..4], 16) catch continue;
        const bus = std.fmt.parseInt(u8, n[5..7], 16) catch continue;
        const dv = std.fmt.parseInt(u8, n[8..10], 16) catch continue;
        const fn_ = std.fmt.parseInt(u8, n[11..12], 16) catch continue;
        const base = std.fmt.allocPrint(u.alloc, "/sys/bus/pci/devices/{s}", .{n}) catch continue;
        var d = Dev{ .domain = dom, .bus = bus, .dev = dv, .func = fn_, .vendor = 0, .device = 0, .cls = 0, .rev = 0, .sv = 0, .sd = 0, .sysname = u.alloc.dupe(u8, n) catch n };
        const cfg = mnt.readFile(std.fmt.allocPrint(u.alloc, "{s}/config", .{base}) catch continue) orelse continue;
        d.config = u.alloc.alloc(u8, 4096) catch continue;
        @memset(d.config, 0);
        const m = @min(cfg.len, d.config.len);
        @memcpy(d.config[0..m], cfg[0..m]);
        d.cfg_len = m;
        if (m < 64) continue;
        d.vendor = std.mem.readInt(u16, d.config[0..2], .little);
        d.device = std.mem.readInt(u16, d.config[2..4], .little);
        d.rev = d.config[8];
        d.cls = (@as(u32, d.config[11]) << 16) | (@as(u32, d.config[10]) << 8) | d.config[9];
        const hdr = d.config[14] & 0x7f;
        if (hdr == 0) {
            d.sv = std.mem.readInt(u16, d.config[0x2c..][0..2], .little);
            d.sd = std.mem.readInt(u16, d.config[0x2e..][0..2], .little);
        } else if (hdr == 2) {
            d.sv = std.mem.readInt(u16, d.config[0x40..][0..2], .little);
            d.sd = std.mem.readInt(u16, d.config[0x42..][0..2], .little);
        } else if (hdr == 1 and (std.mem.readInt(u16, d.config[6..8], .little) & 0x10) != 0) {
            var ptr: usize = d.config[0x34] & 0xfc;
            var guard: usize = 0;
            while (ptr >= 0x40 and ptr + 8 <= d.config.len and guard < 48) : (guard += 1) {
                const id = d.config[ptr];
                if (id == 0x0d) {
                    d.sv = std.mem.readInt(u16, d.config[ptr + 4 ..][0..2], .little);
                    d.sd = std.mem.readInt(u16, d.config[ptr + 6 ..][0..2], .little);
                    break;
                }
                ptr = d.config[ptr + 1] & 0xfc;
            }
        }
        out.push(d);
    }
    std.mem.sort(Dev, out.items, {}, struct {
        fn lt(_: void, a: Dev, b: Dev) bool {
            if (a.domain != b.domain) return a.domain < b.domain;
            if (a.bus != b.bus) return a.bus < b.bus;
            if (a.dev != b.dev) return a.dev < b.dev;
            return a.func < b.func;
        }
    }.lt);
    return out.items;
}

// ---------------------------------------------------------------- name formatting
const Cfg = struct {
    numeric: u8 = 0, // 0 names, 1 -n, 2 -nn
    domains: bool = false,
    verbose: u8 = 0,
    kernel: bool = false,
    machine: u8 = 0, // 1 -m, 2 -mm
    tree: bool = false,
    hexdump: u8 = 0,
    bus_centric: bool = false,
    path: u8 = 0,
};

fn fmtVendorDevice(a: std.mem.Allocator, cfg: *const Cfg, v: u16, d: u16) []const u8 {
    if (cfg.numeric == 1) return std.fmt.allocPrint(a, "{x:0>4}:{x:0>4}", .{ v, d }) catch "";
    var o = u.Vec(u8).init(a);
    const vn = vendorName(v);
    const dn = deviceName(v, d);
    if (vn) |x| {
        o.pushSlice(x);
        o.push(' ');
        if (dn) |y| o.pushSlice(y) else if (cfg.numeric == 2) o.pushSlice("Device") else o.pushSlice(std.fmt.allocPrint(a, "Device {x:0>4}", .{d}) catch "");
    } else {
        if (dn) |y| o.pushSlice(y) else if (cfg.numeric == 2) o.pushSlice("Device") else o.pushSlice(std.fmt.allocPrint(a, "Device {x:0>4}:{x:0>4}", .{ v, d }) catch "");
    }
    if (cfg.numeric == 2) o.pushSlice(std.fmt.allocPrint(a, " [{x:0>4}:{x:0>4}]", .{ v, d }) catch "");
    return o.items;
}

fn fmtClass(a: std.mem.Allocator, cfg: *const Cfg, cls: u32) []const u8 {
    const c16: u16 = @intCast(cls >> 8);
    if (cfg.numeric == 1) return std.fmt.allocPrint(a, "{x:0>4}", .{c16}) catch "";
    const nm = className(@intCast(cls >> 16), @intCast((cls >> 8) & 0xff));
    if (nm) |x| {
        if (cfg.numeric == 2) return std.fmt.allocPrint(a, "{s} [{x:0>4}]", .{ x, c16 }) catch "";
        return x;
    }
    return std.fmt.allocPrint(a, "Class {x:0>4}", .{c16}) catch "";
}

fn fmtSubsystem(a: std.mem.Allocator, cfg: *const Cfg, d: Dev) []const u8 {
    if (cfg.numeric == 1) return std.fmt.allocPrint(a, "{x:0>4}:{x:0>4}", .{ d.sv, d.sd }) catch "";
    var o = u.Vec(u8).init(a);
    const sname = subsysName(d.vendor, d.device, d.sv, d.sd) orelse deviceName(d.sv, d.sd);
    if (sname) |nm| {
        if (vendorName(d.sv)) |vn| {
            o.pushSlice(vn);
            o.push(' ');
        }
        o.pushSlice(nm);
    } else if (vendorName(d.sv)) |vn| {
        o.pushSlice(vn);
        if (cfg.numeric == 2) o.pushSlice(" Device") else o.pushSlice(std.fmt.allocPrint(a, " Device {x:0>4}", .{d.sd}) catch "");
    } else if (cfg.numeric == 2) o.pushSlice("Device") else o.pushSlice(std.fmt.allocPrint(a, "Device {x:0>4}:{x:0>4}", .{ d.sv, d.sd }) catch "");
    if (cfg.numeric == 2) o.pushSlice(std.fmt.allocPrint(a, " [{x:0>4}:{x:0>4}]", .{ d.sv, d.sd }) catch "");
    return o.items;
}

fn slot(a: std.mem.Allocator, cfg: *const Cfg, d: Dev, show_dom: bool) []const u8 {
    _ = cfg;
    if (show_dom) return std.fmt.allocPrint(a, "{x:0>4}:{x:0>2}:{x:0>2}.{x}", .{ d.domain, d.bus, d.dev, d.func }) catch "";
    return std.fmt.allocPrint(a, "{x:0>2}:{x:0>2}.{x}", .{ d.bus, d.dev, d.func }) catch "";
}

fn driverOf(a: std.mem.Allocator, d: Dev) ?[]const u8 {
    const p = std.fmt.allocPrint(a, "/sys/bus/pci/devices/{s}/driver", .{d.sysname}) catch return null;
    var buf: [256]u8 = undefined;
    const r = linux.readlink(u.zstr(p), &buf, buf.len);
    if (!u.ok(r)) return null;
    return a.dupe(u8, std.fs.path.basename(buf[0..r])) catch null;
}

fn iommuGroup(a: std.mem.Allocator, d: Dev) ?[]const u8 {
    const p = std.fmt.allocPrint(a, "/sys/bus/pci/devices/{s}/iommu_group", .{d.sysname}) catch return null;
    var buf: [256]u8 = undefined;
    const r = linux.readlink(u.zstr(p), &buf, buf.len);
    if (!u.ok(r)) return null;
    return a.dupe(u8, std.fs.path.basename(buf[0..r])) catch null;
}

fn modulesOf(a: std.mem.Allocator, d: Dev) []const u8 {
    var uts: linux.utsname = undefined;
    _ = linux.uname(&uts);
    const rel = std.mem.sliceTo(&uts.release, 0);
    const path = std.fmt.allocPrint(a, "/lib/modules/{s}/modules.alias", .{rel}) catch return "";
    const data = mnt.readFile(path) orelse return "";
    const modalias = blk: {
        const p = std.fmt.allocPrint(a, "/sys/bus/pci/devices/{s}/modalias", .{d.sysname}) catch return "";
        const m = mnt.readFile(p) orelse return "";
        break :blk std.mem.trim(u8, m, " \n");
    };
    var mods = u.Vec([]const u8).init(a);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |l| {
        if (!std.mem.startsWith(u8, l, "alias pci:")) continue;
        var it = std.mem.tokenizeScalar(u8, l, ' ');
        _ = it.next();
        const pat = it.next() orelse continue;
        const mod = it.next() orelse continue;
        if (c.fnmatch(u.zstr(pat).ptr, u.zstr(modalias).ptr, 0) == 0) {
            var dup = false;
            for (mods.items) |x| if (std.mem.eql(u8, x, mod)) {
                dup = true;
            };
            if (!dup) mods.push(mod);
        }
    }
    var o = u.Vec(u8).init(a);
    for (mods.items, 0..) |m, i| {
        if (i > 0) o.pushSlice(", ");
        o.pushSlice(m);
    }
    return o.items;
}

// ---------------------------------------------------------------- selection
const Sel = struct {
    domain: ?u16 = null,
    bus: ?u8 = null,
    dev: ?u8 = null,
    func: ?u8 = null,
    vendor: ?u16 = null,
    device: ?u16 = null,
    cls: ?u32 = null,
    cls_mask: u32 = 0,
};

fn parseSlot(s: []const u8) ?Sel {
    var sel = Sel{};
    // [[[[<domain>]:]<bus>]:][<slot>][.[<func>]]
    var rest = s;
    var dotpart: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, rest, '.')) |dp| {
        dotpart = rest[dp + 1 ..];
        rest = rest[0..dp];
    }
    var fields = u.Vec([]const u8).init(u.alloc);
    var it = std.mem.splitScalar(u8, rest, ':');
    while (it.next()) |f| fields.push(f);
    var slotf: []const u8 = "";
    if (fields.items.len > 0) {
        slotf = fields.items[fields.items.len - 1];
        fields.items.len -= 1;
    }
    if (fields.items.len > 2) return null;
    // fields: [domain], [bus]
    if (fields.items.len >= 1) {
        const busf = fields.items[fields.items.len - 1];
        if (busf.len > 0) sel.bus = std.fmt.parseInt(u8, busf, 16) catch return null;
        if (fields.items.len == 2 and fields.items[0].len > 0) sel.domain = std.fmt.parseInt(u16, fields.items[0], 16) catch return null;
    }
    // a lone field with no dot is the slot unless it came before the colon
    if (slotf.len > 0) sel.dev = std.fmt.parseInt(u8, slotf, 16) catch return null;
    if (dotpart) |dpf| {
        if (dpf.len > 0) sel.func = std.fmt.parseInt(u8, dpf, 16) catch return null;
    }
    return sel;
}

fn parseIds(s: []const u8) ?Sel {
    var sel = Sel{};
    var it = std.mem.splitScalar(u8, s, ':');
    const v = it.next() orelse return null;
    const dd = it.next() orelse return null;
    const cl = it.next();
    if (it.next() != null) return null;
    if (v.len > 0) sel.vendor = std.fmt.parseInt(u16, v, 16) catch return null;
    if (dd.len > 0) sel.device = std.fmt.parseInt(u16, dd, 16) catch return null;
    if (cl) |cs| if (cs.len > 0) {
        sel.cls = std.fmt.parseInt(u32, cs, 16) catch return null;
        sel.cls_mask = if (cs.len <= 2) 0xff0000 else 0xffff00;
        if (cs.len <= 2) sel.cls = sel.cls.? << 16 else sel.cls = sel.cls.? << 8;
    };
    return sel;
}

fn matches(d: Dev, slots: []const Sel, idsel: []const Sel) bool {
    if (slots.len > 0) {
        var ok = false;
        for (slots) |s| {
            if (s.domain != null and s.domain.? != d.domain) continue;
            if (s.bus != null and s.bus.? != d.bus) continue;
            if (s.dev != null and s.dev.? != d.dev) continue;
            if (s.func != null and s.func.? != d.func) continue;
            ok = true;
        }
        if (!ok) return false;
    }
    if (idsel.len > 0) {
        var ok = false;
        for (idsel) |s| {
            if (s.vendor != null and s.vendor.? != d.vendor) continue;
            if (s.device != null and s.device.? != d.device) continue;
            if (s.cls != null and (d.cls & s.cls_mask) != s.cls.?) continue;
            ok = true;
        }
        if (!ok) return false;
    }
    return true;
}

// ---------------------------------------------------------------- output
fn showDefault(a: std.mem.Allocator, cfg: *const Cfg, d: Dev, show_dom: bool) void {
    var o = u.Vec(u8).init(a);
    o.pushSlice(slot(a, cfg, d, show_dom));
    o.push(' ');
    o.pushSlice(fmtClass(a, cfg, d.cls));
    o.pushSlice(": ");
    o.pushSlice(fmtVendorDevice(a, cfg, d.vendor, d.device));
    if (d.rev != 0) o.pushSlice(std.fmt.allocPrint(a, " (rev {x:0>2})", .{d.rev}) catch "");
    if (cfg.verbose > 0) {
        const pi: u8 = @intCast(d.cls & 0xff);
        if (pi != 0) {
            if (progifName(@intCast(d.cls >> 16), @intCast((d.cls >> 8) & 0xff), pi)) |nm| {
                o.pushSlice(std.fmt.allocPrint(a, " (prog-if {x:0>2} [{s}])", .{ pi, nm }) catch "");
            } else o.pushSlice(std.fmt.allocPrint(a, " (prog-if {x:0>2})", .{pi}) catch "");
        } else if (progifName(@intCast(d.cls >> 16), @intCast((d.cls >> 8) & 0xff), 0)) |nm| {
            o.pushSlice(std.fmt.allocPrint(a, " (prog-if 00 [{s}])", .{nm}) catch "");
        }
    }
    o.push('\n');
    u.out(o.items);
}

fn hexLine(a: std.mem.Allocator, off: usize, bytes: []const u8) []const u8 {
    var o = u.Vec(u8).init(a);
    o.pushSlice(std.fmt.allocPrint(a, "{x:0>2}:", .{off}) catch "");
    for (bytes) |b| o.pushSlice(std.fmt.allocPrint(a, " {x:0>2}", .{b}) catch "");
    o.push('\n');
    return o.items;
}

fn quoted(a: std.mem.Allocator, s: []const u8) []const u8 {
    var o = u.Vec(u8).init(a);
    o.push('"');
    for (s) |ch| {
        if (ch == '"' or ch == '\\') o.push('\\');
        o.push(ch);
    }
    o.push('"');
    return o.items;
}

fn showMachine(a: std.mem.Allocator, cfg: *const Cfg, d: Dev, show_dom: bool) void {
    const sl = slot(a, cfg, d, show_dom);
    const cls_s = blk: {
        if (cfg.numeric == 1) break :blk std.fmt.allocPrint(a, "{x:0>4}", .{d.cls >> 8}) catch "";
        break :blk fmtClass(a, cfg, d.cls);
    };
    const vend = blk: {
        if (cfg.numeric == 1) break :blk std.fmt.allocPrint(a, "{x:0>4}", .{d.vendor}) catch "";
        const nm = vendorName(d.vendor) orelse (if (cfg.numeric == 2) "Unknown vendor" else std.fmt.allocPrint(a, "Unknown vendor {x:0>4}", .{d.vendor}) catch "");
        if (cfg.numeric == 2) break :blk std.fmt.allocPrint(a, "{s} [{x:0>4}]", .{ nm, d.vendor }) catch "";
        break :blk nm;
    };
    const dev = blk: {
        if (cfg.numeric == 1) break :blk std.fmt.allocPrint(a, "{x:0>4}", .{d.device}) catch "";
        const nm = deviceName(d.vendor, d.device) orelse (if (cfg.numeric == 2) "Device" else std.fmt.allocPrint(a, "Device {x:0>4}", .{d.device}) catch "");
        if (cfg.numeric == 2) break :blk std.fmt.allocPrint(a, "{s} [{x:0>4}]", .{ nm, d.device }) catch "";
        break :blk nm;
    };
    const no_sub = d.sv == 0 and d.sd == 0;
    const svend = blk: {
        if (no_sub) break :blk "";
        if (cfg.numeric == 1) break :blk std.fmt.allocPrint(a, "{x:0>4}", .{d.sv}) catch "";
        const nm = vendorName(d.sv) orelse (if (cfg.numeric == 2) "Unknown vendor" else std.fmt.allocPrint(a, "Unknown vendor {x:0>4}", .{d.sv}) catch "");
        if (cfg.numeric == 2) break :blk std.fmt.allocPrint(a, "{s} [{x:0>4}]", .{ nm, d.sv }) catch "";
        break :blk nm;
    };
    const sdev = blk: {
        if (no_sub) break :blk "";
        if (cfg.numeric == 1) break :blk std.fmt.allocPrint(a, "{x:0>4}", .{d.sd}) catch "";
        const nm = subsysName(d.vendor, d.device, d.sv, d.sd) orelse deviceName(d.sv, d.sd) orelse (if (cfg.numeric == 2) "Device" else std.fmt.allocPrint(a, "Device {x:0>4}", .{d.sd}) catch "");
        if (cfg.numeric == 2) break :blk std.fmt.allocPrint(a, "{s} [{x:0>4}]", .{ nm, d.sd }) catch "";
        break :blk nm;
    };
    if (cfg.verbose > 0 and cfg.machine == 2) {
        // -vmm: key/value blocks
        u.outf("Slot:\t{s}\nClass:\t{s}\nVendor:\t{s}\nDevice:\t{s}\n", .{ sl, cls_s, vend, dev });
        if (d.sv != 0 or d.sd != 0) u.outf("SVendor:\t{s}\nSDevice:\t{s}\n", .{ svend, sdev });
        if (cfg.kernel) {
            if (driverOf(a, d)) |dr| u.outf("Driver:\t{s}\n", .{dr});
            const mods = modulesOf(a, d);
            _ = mods;
        }
        if (d.rev != 0) u.outf("Rev:\t{x:0>2}\n", .{d.rev});
        u.outf("ProgIf:\t{x:0>2}\n", .{d.cls & 0xff});
        if (iommuGroup(a, d)) |ig| u.outf("IOMMUGroup:\t{s}\n", .{ig});
        u.out("\n");
        return;
    }
    var o = u.Vec(u8).init(a);
    o.pushSlice(sl);
    o.push(' ');
    o.pushSlice(quoted(a, cls_s));
    o.push(' ');
    o.pushSlice(quoted(a, vend));
    o.push(' ');
    o.pushSlice(quoted(a, dev));
    if (d.rev != 0) o.pushSlice(std.fmt.allocPrint(a, " -r{x:0>2}", .{d.rev}) catch "");
    o.pushSlice(std.fmt.allocPrint(a, " -p{x:0>2}", .{d.cls & 0xff}) catch "");
    o.push(' ');
    o.pushSlice(quoted(a, svend));
    o.push(' ');
    o.pushSlice(quoted(a, sdev));
    o.push('\n');
    u.out(o.items);
}

fn showDevice(a: std.mem.Allocator, cfg: *const Cfg, d: Dev, show_dom: bool) void {
    if (cfg.machine > 0) {
        showMachine(a, cfg, d, show_dom);
        return;
    }
    showDefault(a, cfg, d, show_dom);
    if (cfg.verbose > 0 or cfg.kernel) {
        if (d.sv != 0 or d.sd != 0) u.outf("\tSubsystem: {s}\n", .{fmtSubsystem(a, cfg, d)});
    }
    if (cfg.verbose > 0) {
        verboseBody(a, cfg, d);
    }
    if (false) {
        var fl = u.Vec(u8).init(a);
        const cmd = std.mem.readInt(u16, d.config[4..6], .little);
        const status = std.mem.readInt(u16, d.config[6..8], .little);
        if (cmd & 0x4 != 0) fl.pushSlice("bus master, ");
        if (cmd & 0x20 != 0) fl.pushSlice("VGA palette snoop, ");
        if (cmd & 0x80 != 0) fl.pushSlice("stepping, ");
        if (cmd & 0x100 != 0) fl.pushSlice("SERR, ");
        if (cmd & 0x200 != 0) fl.pushSlice("fast Back2Back, ");
        if (status & 0x20 != 0) fl.pushSlice("66MHz, ");
        if (status & 0x40 != 0) fl.pushSlice("user-definable features, ");
        const devsel = (status >> 9) & 3;
        fl.pushSlice(if (devsel == 2) "slow devsel" else if (devsel == 1) "medium devsel" else "fast devsel");
        if (cmd & 0x4 != 0) fl.pushSlice(std.fmt.allocPrint(a, ", latency {d}", .{d.config[0x0d]}) catch "");
        const irq = readHexIrq(a, d);
        if (irq != 0) fl.pushSlice(std.fmt.allocPrint(a, ", IRQ {d}", .{irq}) catch "");
        if (iommuGroup(a, d)) |ig| fl.pushSlice(std.fmt.allocPrint(a, ", IOMMU group {s}", .{ig}) catch "");
        u.outf("\tFlags: {s}\n", .{fl.items});
    }
    if (cfg.kernel or cfg.verbose > 0) {
        if (driverOf(a, d)) |dr| u.outf("\tKernel driver in use: {s}\n", .{dr});
        if (cfg.kernel) {
            const mods = modulesOf(a, d);
            if (mods.len > 0) u.outf("\tKernel modules: {s}\n", .{mods});
        }
    }
    if (cfg.hexdump > 0) {
        const n: usize = if (cfg.hexdump == 1) 64 else if (cfg.hexdump == 2 or cfg.hexdump == 3) @min(d.cfg_len, 256) else d.cfg_len;
        var off: usize = 0;
        while (off < n) : (off += 16) u.out(hexLine(a, off, d.config[off..@min(off + 16, n)]));
    }
    if (cfg.verbose > 0 or cfg.hexdump > 0) u.out("\n");
}

fn rd16(d: Dev, off: usize) u16 {
    return std.mem.readInt(u16, d.config[off..][0..2], .little);
}

fn rd32(d: Dev, off: usize) u32 {
    return std.mem.readInt(u32, d.config[off..][0..4], .little);
}

fn fmtSizeK(a: std.mem.Allocator, size: u64) []const u8 {
    var v = size;
    const units = [_][]const u8{ "", "K", "M", "G", "T" };
    var i: usize = 0;
    while (v >= 1024 and v % 1024 == 0 and i + 1 < units.len) {
        v /= 1024;
        i += 1;
    }
    return std.fmt.allocPrint(a, "{d}{s}", .{ v, units[i] }) catch "";
}

const Res = struct { start: u64, end: u64, flags: u64 };

fn hexVal(t: []const u8) u64 {
    const x = if (std.mem.startsWith(u8, t, "0x")) t[2..] else t;
    return std.fmt.parseInt(u64, x, 16) catch 0;
}

fn readResources(a: std.mem.Allocator, d: Dev) []Res {
    var out = u.Vec(Res).init(a);
    const path = std.fmt.allocPrint(a, "/sys/bus/pci/devices/{s}/resource", .{d.sysname}) catch return out.items;
    const data = mnt.readFile(path) orelse return out.items;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        var it = std.mem.tokenizeScalar(u8, l, ' ');
        const x = it.next() orelse continue;
        const y = it.next() orelse continue;
        const z = it.next() orelse continue;
        out.push(.{
            .start = hexVal(x),
            .end = hexVal(y),
            .flags = hexVal(z),
        });
    }
    return out.items;
}

fn showRegions(a: std.mem.Allocator, d: Dev, nbars: usize) void {
    const res = readResources(a, d);
    const cmd = rd16(d, 4);
    var i: usize = 0;
    while (i < nbars) : (i += 1) {
        const bar = rd32(d, 0x10 + 4 * i);
        if (bar == 0 and (i >= res.len or res[i].flags == 0)) continue;
        const r: Res = if (i < res.len) res[i] else .{ .start = 0, .end = 0, .flags = 0 };
        const size: u64 = if (r.end >= r.start and (r.flags != 0)) r.end - r.start + 1 else 0;
        if (bar & 1 != 0) {
            const disabled = cmd & 1 == 0;
            if (r.start == 0 and size == 0) {
                u.outf("\tI/O ports at <ignored>{s}\n", .{if (disabled) " [disabled]" else ""});
            } else {
                u.outf("\tI/O ports at {x:0>4}{s} [size={s}]\n", .{ r.start, if (disabled) " [disabled]" else "", fmtSizeK(a, size) });
            }
            continue;
        }
        const is64 = (bar >> 1) & 3 == 2;
        const pref = bar & 8 != 0;
        const disabled = cmd & 2 == 0;
        if (r.start == 0) {
            u.outf("\tMemory at <unassigned> ({s}-bit, {s}prefetchable){s} [size={s}]\n", .{ if (is64) "64" else "32", if (pref) "" else "non-", if (disabled) " [disabled]" else "", fmtSizeK(a, size) });
        } else {
            u.outf("\tMemory at {x:0>8} ({s}-bit, {s}prefetchable){s} [size={s}]\n", .{ r.start, if (is64) "64" else "32", if (pref) "" else "non-", if (disabled) " [disabled]" else "", fmtSizeK(a, size) });
        }
        if (is64) i += 1;
    }
    const rom_off: usize = if (nbars == 6) 0x30 else 0x38;
    const rom = rd32(d, rom_off);
    if (rom != 0 and res.len > 6) {
        const rr = res[6];
        const size: u64 = if (rr.end >= rr.start and rr.flags != 0) rr.end - rr.start + 1 else 0;
        const en = rom & 1 != 0;
        u.outf("\tExpansion ROM at {x:0>8}{s} [size={s}]\n", .{ rr.start, if (!en) " [disabled]" else "", fmtSizeK(a, size) });
    }
}

fn showBridgeInfo(a: std.mem.Allocator, d: Dev) void {
    u.outf("\tBus: primary={x:0>2}, secondary={x:0>2}, subordinate={x:0>2}, sec-latency={d}\n", .{ d.config[0x18], d.config[0x19], d.config[0x1a], d.config[0x1b] });
    // I/O window
    const io_base_lo: u32 = d.config[0x1c];
    const io_lim_lo: u32 = d.config[0x1d];
    const io32 = io_base_lo & 0xf == 1;
    var io_base: u64 = (io_base_lo & 0xf0) << 8;
    var io_lim: u64 = ((io_lim_lo & 0xf0) << 8) | 0xfff;
    if (io32) {
        io_base |= @as(u64, rd16(d, 0x30)) << 16;
        io_lim |= @as(u64, rd16(d, 0x32)) << 16;
    }
    if (io_base > io_lim) {
        u.outf("\tI/O behind bridge: [disabled] [{s}-bit]\n", .{if (io32) "32" else "16"});
    } else if (io32 and (io_lim >> 16) != 0) {
        u.outf("\tI/O behind bridge: {x:0>8}-{x:0>8} [size={s}] [32-bit]\n", .{ io_base, io_lim, fmtSizeK(a, io_lim - io_base + 1) });
    } else u.outf("\tI/O behind bridge: {x:0>4}-{x:0>4} [size={s}] [16-bit]\n", .{ io_base, io_lim, fmtSizeK(a, io_lim - io_base + 1) });
    // memory window
    const mb: u64 = @as(u64, rd16(d, 0x20) & 0xfff0) << 16;
    const ml: u64 = (@as(u64, rd16(d, 0x22) & 0xfff0) << 16) | 0xfffff;
    if (mb > ml) u.out("\tMemory behind bridge: [disabled] [32-bit]\n") else u.outf("\tMemory behind bridge: {x:0>8}-{x:0>8} [size={s}] [32-bit]\n", .{ mb, ml, fmtSizeK(a, ml - mb + 1) });
    // prefetchable window
    const pb_lo = rd16(d, 0x24);
    const pl_lo = rd16(d, 0x26);
    const p64 = pb_lo & 0xf == 1;
    var pb: u64 = @as(u64, pb_lo & 0xfff0) << 16;
    var pl: u64 = (@as(u64, pl_lo & 0xfff0) << 16) | 0xfffff;
    if (p64) {
        pb |= @as(u64, rd32(d, 0x28)) << 32;
        pl |= @as(u64, rd32(d, 0x2c)) << 32;
    }
    if (pb > pl) {
        u.outf("\tPrefetchable memory behind bridge: [disabled] [{s}-bit]\n", .{if (p64) "64" else "32"});
    } else if (p64 and (pl >> 32) != 0) {
        u.outf("\tPrefetchable memory behind bridge: {x:0>16}-{x:0>16} [size={s}] [64-bit]\n", .{ pb, pl, fmtSizeK(a, pl - pb + 1) });
    } else u.outf("\tPrefetchable memory behind bridge: {x:0>8}-{x:0>8} [size={s}] [32-bit]\n", .{ pb, pl, fmtSizeK(a, pl - pb + 1) });
}

fn pcieTypeName(t: u8) []const u8 {
    return switch (t) {
        0 => "Endpoint",
        1 => "Legacy Endpoint",
        4 => "Root Port",
        5 => "Upstream Port",
        6 => "Downstream Port",
        7 => "PCI-Express to PCI/PCI-X Bridge",
        8 => "PCI/PCI-X to PCI-Express Bridge",
        9 => "Root Complex Integrated Endpoint",
        10 => "Root Complex Event Collector",
        else => "Unknown Express Type",
    };
}

fn showCapabilities(a: std.mem.Allocator, cfg: *const Cfg, d: Dev) void {
    const status = rd16(d, 6);
    if (status & 0x10 == 0) return;
    var ptr: usize = d.config[0x34] & 0xfc;
    var guard: usize = 0;
    var has_express = false;
    while (ptr >= 0x40 and ptr + 2 <= 256 and guard < 48) : (guard += 1) {
        const id = d.config[ptr];
        const nxt = d.config[ptr + 1] & 0xfc;
        var o = u.Vec(u8).init(a);
        o.pushSlice(std.fmt.allocPrint(a, "\tCapabilities: [{x:0>2}] ", .{ptr}) catch "");
        switch (id) {
            0x01 => o.pushSlice(std.fmt.allocPrint(a, "Power Management version {d}", .{rd16(d, ptr + 2) & 7}) catch ""),
            0x02 => o.pushSlice("AGP"),
            0x03 => o.pushSlice("Vital Product Data"),
            0x04 => o.pushSlice("Slot Identification"),
            0x05 => {
                const ctl = rd16(d, ptr + 2);
                const en: u8 = if (ctl & 1 != 0) '+' else '-';
                const cnt_en = @as(u32, 1) << @intCast((ctl >> 4) & 7);
                const cnt_av = @as(u32, 1) << @intCast((ctl >> 1) & 7);
                const mask: u8 = if (ctl & 0x100 != 0) '+' else '-';
                const b64: u8 = if (ctl & 0x80 != 0) '+' else '-';
                o.pushSlice(std.fmt.allocPrint(a, "MSI: Enable{c} Count={d}/{d} Maskable{c} 64bit{c}", .{ en, cnt_en, cnt_av, mask, b64 }) catch "");
            },
            0x07 => o.pushSlice("PCI-X"),
            0x08 => o.pushSlice("HyperTransport"),
            0x09 => {
                const len = d.config[ptr + 2];
                if (d.vendor == 0x8086 and len == 0x0c and d.config[ptr + 3] == 0x10) {
                    o.pushSlice("Vendor Specific Information: Intel Feature Detection");
                } else o.pushSlice(std.fmt.allocPrint(a, "Vendor Specific Information: Len={x:0>2} <?>", .{len}) catch "");
            },
            0x0a => o.pushSlice(std.fmt.allocPrint(a, "Debug port: BAR={d} offset={x:0>4}", .{ rd16(d, ptr + 2) >> 13, rd16(d, ptr + 2) & 0x1fff }) catch ""),
            0x0d => {
                const sv = rd16(d, ptr + 4);
                const sd = rd16(d, ptr + 6);
                var dd = d;
                dd.sv = sv;
                dd.sd = sd;
                o.pushSlice("Subsystem: ");
                o.pushSlice(fmtSubsystem(a, cfg, dd));
            },
            0x10 => {
                has_express = true;
                const fl = rd16(d, ptr + 2);
                const typ: u8 = @intCast((fl >> 4) & 0xf);
                o.pushSlice("Express ");
                o.pushSlice(pcieTypeName(typ));
                if (typ == 4 or typ == 6) o.pushSlice(if (fl & 0x100 != 0) " (Slot+)" else " (Slot-)");
                o.pushSlice(std.fmt.allocPrint(a, ", IntMsgNum {d}", .{(fl >> 9) & 0x1f}) catch "");
            },
            0x11 => {
                const ctl = rd16(d, ptr + 2);
                o.pushSlice(std.fmt.allocPrint(a, "MSI-X: Enable{c} Count={d} Masked{c}", .{ @as(u8, if (ctl & 0x8000 != 0) '+' else '-'), (ctl & 0x7ff) + 1, @as(u8, if (ctl & 0x4000 != 0) '+' else '-') }) catch "");
            },
            0x12 => o.pushSlice("SATA HBA"),
            0x13 => o.pushSlice("PCI Advanced Features"),
            else => o.pushSlice(std.fmt.allocPrint(a, "#{x:0>2} [{x:0>4}]", .{ id, rd16(d, ptr + 2) }) catch ""),
        }
        o.push('\n');
        u.out(o.items);
        if (nxt == ptr or nxt == 0) break;
        ptr = nxt;
    }
    if (!has_express or d.cfg_len < 0x200) return;
    // extended capabilities
    var eptr: usize = 0x100;
    guard = 0;
    while (eptr >= 0x100 and eptr + 4 <= d.cfg_len and guard < 64) : (guard += 1) {
        const hdr = rd32(d, eptr);
        if (hdr == 0 or hdr == 0xffffffff) break;
        const id: u16 = @intCast(hdr & 0xffff);
        const ver: u8 = @intCast((hdr >> 16) & 0xf);
        const nxt: usize = (hdr >> 20) & 0xffc;
        var o = u.Vec(u8).init(a);
        o.pushSlice(std.fmt.allocPrint(a, "\tCapabilities: [{x:0>3}", .{eptr}) catch "");
        if (ver != 1 and false) o.pushSlice(std.fmt.allocPrint(a, " v{d}", .{ver}) catch "");
        o.pushSlice("] ");
        switch (id) {
            0x01 => o.pushSlice("Advanced Error Reporting"),
            0x02, 0x09 => o.pushSlice("Virtual Channel"),
            0x03 => {
                if (eptr + 12 <= d.cfg_len) {
                    const lo = rd32(d, eptr + 4);
                    const hi = rd32(d, eptr + 8);
                    o.pushSlice(std.fmt.allocPrint(a, "Device Serial Number {x:0>2}-{x:0>2}-{x:0>2}-{x:0>2}-{x:0>2}-{x:0>2}-{x:0>2}-{x:0>2}", .{ hi >> 24, (hi >> 16) & 0xff, (hi >> 8) & 0xff, hi & 0xff, lo >> 24, (lo >> 16) & 0xff, (lo >> 8) & 0xff, lo & 0xff }) catch "");
                }
            },
            0x04 => o.pushSlice("Power Budgeting <?>"),
            0x05 => o.pushSlice("Root Complex Link"),
            0x0b => {
                const vh = rd32(d, eptr + 4);
                o.pushSlice(std.fmt.allocPrint(a, "Vendor Specific Information: ID={x:0>4} Rev={d} Len={x:0>3} <?>", .{ vh & 0xffff, (vh >> 16) & 0xf, vh >> 20 }) catch "");
            },
            0x0d => o.pushSlice("Access Control Services"),
            0x0f => o.pushSlice("Address Translation Service (ATS)"),
            0x10 => o.pushSlice("Single Root I/O Virtualization (SR-IOV)"),
            0x12 => o.pushSlice("Multicast"),
            0x13 => o.pushSlice("Page Request Interface (PRI)"),
            0x15 => o.pushSlice("Physical Resizable BAR"),
            0x18 => o.pushSlice("Latency Tolerance Reporting"),
            0x19 => o.pushSlice("Secondary PCI Express"),
            0x1b => o.pushSlice("Process Address Space ID (PASID)"),
            else => o.pushSlice(std.fmt.allocPrint(a, "Extended Capability ID {x:0>2} <?>", .{id}) catch ""),
        }
        o.push('\n');
        u.out(o.items);
        if (nxt == 0 or nxt == eptr) break;
        eptr = nxt;
    }
}

fn verboseBody(a: std.mem.Allocator, cfg: *const Cfg, d: Dev) void {
    var fl = u.Vec(u8).init(a);
    const cmd = rd16(d, 4);
    const status = rd16(d, 6);
    if (cmd & 0x4 != 0) fl.pushSlice("bus master, ");
    if (cmd & 0x20 != 0) fl.pushSlice("VGA palette snoop, ");
    if (cmd & 0x80 != 0) fl.pushSlice("stepping, ");
    if (cmd & 0x200 != 0) fl.pushSlice("fast Back2Back, ");
    if (status & 0x20 != 0) fl.pushSlice("66MHz, ");
    if (status & 0x40 != 0) fl.pushSlice("user-definable features, ");
    const devsel = (status >> 9) & 3;
    fl.pushSlice(if (devsel == 2) "slow devsel" else if (devsel == 1) "medium devsel" else "fast devsel");
    if (cmd & 0x4 != 0) fl.pushSlice(std.fmt.allocPrint(a, ", latency {d}", .{d.config[0x0d]}) catch "");
    const irq = readHexIrq(a, d);
    if (irq != 0) fl.pushSlice(std.fmt.allocPrint(a, ", IRQ {d}", .{irq}) catch "");
    {
        const np = std.fmt.allocPrint(a, "/sys/bus/pci/devices/{s}/numa_node", .{d.sysname}) catch "";
        if (mnt.readFile(np)) |nd| {
            const nn = std.fmt.parseInt(i32, std.mem.trim(u8, nd, " \n"), 10) catch -1;
            if (nn >= 0) fl.pushSlice(std.fmt.allocPrint(a, ", NUMA node {d}", .{nn}) catch "");
        }
    }
    if (iommuGroup(a, d)) |ig| fl.pushSlice(std.fmt.allocPrint(a, ", IOMMU group {s}", .{ig}) catch "");
    u.outf("\tFlags: {s}\n", .{fl.items});
    const hdr = d.config[14] & 0x7f;
    if (hdr == 0) showRegions(a, d, 6) else if (hdr == 1) {
        showRegions(a, d, 2);
        showBridgeInfo(a, d);
    }
    showCapabilities(a, cfg, d);
}

fn readHexIrq(a: std.mem.Allocator, d: Dev) u32 {
    const p = std.fmt.allocPrint(a, "/sys/bus/pci/devices/{s}/irq", .{d.sysname}) catch return 0;
    const data = mnt.readFile(p) orelse return 0;
    return std.fmt.parseInt(u32, std.mem.trim(u8, data, " \n"), 10) catch 0;
}

// ---------------------------------------------------------------- tree
const TreeDev = struct { d: Dev, sec: i32 = -1, sub: i32 = -1 };

const TreeCtx = struct {
    a: std.mem.Allocator,
    cfg: *const Cfg,
    devs: []TreeDev,
    any_dom: bool,
};

fn buildTree(devs: []const Dev, a: std.mem.Allocator) []TreeDev {
    var out = u.Vec(TreeDev).init(a);
    for (devs) |d| {
        var td = TreeDev{ .d = d };
        if ((d.config[14] & 0x7f) == 1) {
            td.sec = d.config[0x19];
            td.sub = d.config[0x1a];
        }
        out.push(td);
    }
    return out.items;
}

fn spaces(a: std.mem.Allocator, n: usize) []const u8 {
    const b = a.alloc(u8, n) catch return "";
    @memset(b, ' ');
    return b;
}

fn cat(a: std.mem.Allocator, x: []const u8, y: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}{s}", .{ x, y }) catch x;
}

fn kidsOf(ctx: *TreeCtx, dom: u16, bus: u8) []usize {
    var kids = u.Vec(usize).init(ctx.a);
    for (ctx.devs, 0..) |t, i| if (t.d.domain == dom and t.d.bus == bus) kids.push(i);
    return kids.items;
}

fn busLabel(ctx: *TreeCtx, t: TreeDev) []const u8 {
    const sec: u8 = @intCast(t.sec);
    const sub: u8 = @intCast(@max(t.sub, 0));
    const dom = "";
    if (sec != sub and sub != 0) return std.fmt.allocPrint(ctx.a, "-[{s}{x:0>2}-{x:0>2}]", .{ dom, sec, sub }) catch "";
    return std.fmt.allocPrint(ctx.a, "-[{s}{x:0>2}]", .{ dom, sec }) catch "";
}

fn printKids(ctx: *TreeCtx, dom: u16, bus: u8, cur: []const u8, cont: []const u8) void {
    const kids = kidsOf(ctx, dom, bus);
    if (kids.len == 0) {
        u.out(cur);
        u.out("\n");
        return;
    }
    if (kids.len == 1) {
        printDev(ctx, kids[0], cat(ctx.a, cur, "--"), cat(ctx.a, cont, "  "));
        return;
    }
    for (kids, 0..) |ki, n| {
        const last = n + 1 == kids.len;
        const start = if (n == 0) cur else cont;
        printDev(ctx, ki, cat(ctx.a, start, if (last) "\\-" else "+-"), cat(ctx.a, cont, if (last) "  " else "| "));
    }
}

fn printDev(ctx: *TreeCtx, idx: usize, cur: []const u8, cont: []const u8) void {
    const t = ctx.devs[idx];
    const a = ctx.a;
    const name = std.fmt.allocPrint(a, "{x:0>2}.{x}", .{ t.d.dev, t.d.func }) catch "";
    var cur2 = cat(a, cur, name);
    var cont2 = cat(a, cont, spaces(a, name.len));
    if (t.sec >= 0) {
        const lbl = busLabel(ctx, t);
        cur2 = cat(a, cur2, lbl);
        cont2 = cat(a, cont2, spaces(a, lbl.len));
        // the link between bridge and its bus, then the children
        cur2 = cat(a, cur2, "-");
        cont2 = cat(a, cont2, " ");
        // empty buses end with one more dash
        const kids = kidsOf(ctx, t.d.domain, @intCast(t.sec));
        if (kids.len == 0) {
            u.out(cur2);
            u.out("-\n");
            return;
        }
        if (kids.len > 1) {
            cur2 = cat(a, cur2, "-");
            cont2 = cat(a, cont2, " ");
        } else {
            cur2 = cat(a, cur2, "-");
            cont2 = cat(a, cont2, " ");
        }
        printKids(ctx, t.d.domain, @intCast(t.sec), cur2, cont2);
        return;
    }
    // leaf
    u.out(cur2);
    if (ctx.cfg.verbose > 0) {
        u.out("  ");
        u.out(fmtVendorDevice(a, ctx.cfg, t.d.vendor, t.d.device));
    }
    u.out("\n");
}

fn showTree(ctx: *TreeCtx) void {
    var doms = u.Vec(u16).init(ctx.a);
    for (ctx.devs) |t| {
        var have = false;
        for (doms.items) |x| if (x == t.d.domain) {
            have = true;
        };
        if (!have) doms.push(t.d.domain);
    }
    for (doms.items) |dom| {
        var roots = u.Vec(u8).init(ctx.a);
        for (ctx.devs) |t| {
            if (t.d.domain != dom) continue;
            var is_sec = false;
            for (ctx.devs) |b| if (b.d.domain == dom and b.sec >= 0 and b.sec == t.d.bus) {
                is_sec = true;
            };
            if (is_sec) continue;
            var dup = false;
            for (roots.items) |r| if (r == t.d.bus) {
                dup = true;
            };
            if (!dup) roots.push(t.d.bus);
        }
        std.mem.sort(u8, roots.items, {}, std.sort.asc(u8));
        for (roots.items, 0..) |rb, n| {
            const multi = roots.items.len > 1;
            const last = n + 1 == roots.items.len;
            const lead: []const u8 = if (!multi) "-" else if (n == 0) "-+-" else if (last) " \\-" else " +-";
            const contlead: []const u8 = if (!multi) " " else if (last) "   " else " | ";
            const lbl = std.fmt.allocPrint(ctx.a, "[{x:0>4}:{x:0>2}]", .{ dom, rb }) catch "";
            const cur = cat(ctx.a, cat(ctx.a, lead, lbl), "-");
            const cont = cat(ctx.a, contlead, spaces(ctx.a, lbl.len + 1));
            const kids = kidsOf(ctx, dom, rb);
            if (kids.len == 1) {
                printDev(ctx, kids[0], cat(ctx.a, cur, "--"), cat(ctx.a, cont, "  "));
            } else printKids(ctx, dom, rb, cur, cont);
        }
    }
}

const LSPCI_USAGE = "Usage: lspci [<switches>]\n\nBasic display modes:\n-mm\t\tProduce machine-readable output (single -m for an obsolete format)\n-t\t\tShow bus tree\n\nDisplay options:\n-v\t\tBe verbose (-vv or -vvv for higher verbosity)\n-k\t\tShow kernel drivers handling each device\n-x\t\tShow hex-dump of the standard part of the config space\n-xxx\t\tShow hex-dump of the whole config space (dangerous; root only)\n-xxxx\t\tShow hex-dump of the 4096-byte extended config space (root only)\n-b\t\tBus-centric view (addresses and IRQ's as seen by the bus)\n-D\t\tAlways show domain numbers\n-P\t\tDisplay bridge path in addition to bus and device number\n-PP\t\tDisplay bus path in addition to bus and device number\n\nResolving of device IDs to names:\n-n\t\tShow numeric IDs\n-nn\t\tShow both textual and numeric IDs (names & numbers)\n-q\t\tQuery the PCI ID database for unknown IDs via DNS\n-qq\t\tAs above, but re-query locally cached entries\n-Q\t\tQuery the PCI ID database for all IDs via DNS\n\nSelection of devices:\n-s [[[[<domain>]:]<bus>]:][<slot>][.[<func>]]\tShow only devices in selected slots\n-d [<vendor>]:[<device>][:<class>]\t\tShow only devices with specified IDs\n\nOther options:\n-i <file>\tUse specified ID database instead of /usr/share/hwdata/pci.ids\n-p <file>\tLook up kernel modules in a given file instead of default modules.pcimap\n-M\t\tEnable `bus mapping' mode (dangerous; root only)\n\nPCI access options:\n-A <method>\tUse the specified PCI access method (see `-A help' for a list)\n-O <par>=<val>\tSet PCI access parameter (see `-O help' for a list)\n-G\t\tEnable PCI access debugging\n-H <mode>\tUse direct hardware access (<mode> = 1 or 2)\n-F <file>\tRead PCI configuration dump from a given file\n";

pub fn lspci(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "", .key = 'n' },
        .{ .name = "", .key = 'm' },
        .{ .name = "", .key = 't' },
        .{ .name = "", .key = 'v' },
        .{ .name = "", .key = 'k' },
        .{ .name = "", .key = 'x' },
        .{ .name = "", .key = 'b' },
        .{ .name = "", .key = 'D' },
        .{ .name = "", .key = 'P' },
        .{ .name = "", .key = 'q' },
        .{ .name = "", .key = 'Q' },
        .{ .name = "", .key = 'M' },
        .{ .name = "", .key = 'G' },
        .{ .name = "", .key = 's', .arg = .req },
        .{ .name = "", .key = 'd', .arg = .req },
        .{ .name = "", .key = 'i', .arg = .req },
        .{ .name = "", .key = 'p', .arg = .req },
        .{ .name = "", .key = 'A', .arg = .req },
        .{ .name = "", .key = 'O', .arg = .req },
        .{ .name = "", .key = 'H', .arg = .req },
        .{ .name = "", .key = 'F', .arg = .req },
    };
    for (args) |x| {
        if (std.mem.eql(u8, x, "--")) break;
        if (std.mem.startsWith(u8, x, "--")) {
            u.err("lspci: invalid option -- '-'\n");
            u.err(LSPCI_USAGE);
            return 1;
        }
    }
    var p = g.Parser.init("lspci", args, &opts);
    p.no_hint = true;
    var cfg = Cfg{};
    var slots = u.Vec(Sel).init(u.alloc);
    var idsel = u.Vec(Sel).init(u.alloc);
    var idfile: ?[]const u8 = null;
    while (p.next() catch {
        u.err(LSPCI_USAGE);
        return 1;
    }) |it| {
        switch (it.key) {
            'n' => cfg.numeric += 1,
            'm' => cfg.machine += 1,
            't' => cfg.tree = true,
            'v' => cfg.verbose += 1,
            'k' => cfg.kernel = true,
            'x' => cfg.hexdump += 1,
            'b' => cfg.bus_centric = true,
            'D' => cfg.domains = true,
            'P' => cfg.path += 1,
            's' => slots.push(parseSlot(it.val.?) orelse {
                u.err("lspci: -s: Invalid slot number\n");
                return 1;
            }),
            'd' => idsel.push(parseIds(it.val.?) orelse {
                u.err(if (std.mem.indexOfScalar(u8, it.val.?, ':') == null) "lspci: -d: At least two fields must be given\n" else "lspci: -d: Invalid ID\n");
                return 1;
            }),
            'i' => idfile = it.val,
            else => {},
        }
    }
    if (cfg.numeric > 2) cfg.numeric = 2;
    if (cfg.numeric == 0 or true) loadIds(idfile);
    const devs = scanDevices();
    var any_dom = cfg.domains;
    for (devs) |d| if (d.domain != 0) {
        any_dom = true;
    };
    var arena = std.heap.ArenaAllocator.init(u.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    if (cfg.tree) {
        var ctx = TreeCtx{ .a = a, .cfg = &cfg, .devs = buildTree(devs, a), .any_dom = any_dom };
        showTree(&ctx);
        return 0;
    }
    for (devs) |d| {
        if (!matches(d, slots.items, idsel.items)) continue;
        showDevice(a, &cfg, d, any_dom);
    }
    return 0;
}


// ===================== lsusb =====================
const UsbDev = struct {
    sysname: []const u8,
    bus: u32,
    num: u32,
    vendor: u16,
    product: u16,
    parent: []const u8, // sysfs name of the parent device ("" for root hubs)
    port: u32,
    cls: u8,
    speed: []const u8,
    maxchild: u32,
};

fn readStr(a: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const d = mnt.readFile(path) orelse return null;
    return a.dupe(u8, std.mem.trim(u8, d, " \n\t")) catch null;
}

fn readNum(a: std.mem.Allocator, path: []const u8, base: u8) ?u32 {
    const t = readStr(a, path) orelse return null;
    return std.fmt.parseInt(u32, t, base) catch null;
}

fn scanUsb(a: std.mem.Allocator) []UsbDev {
    var out = u.Vec(UsbDev).init(a);
    var ents = u.Vec(u.DirEnt).init(a);
    if (!u.listDir("/sys/bus/usb/devices", &ents)) return out.items;
    for (ents.items) |e| {
        if (std.mem.indexOfScalar(u8, e.name, ':') != null) continue;
        const base = std.fmt.allocPrint(a, "/sys/bus/usb/devices/{s}", .{e.name}) catch continue;
        const vid = readNum(a, std.fmt.allocPrint(a, "{s}/idVendor", .{base}) catch continue, 16) orelse continue;
        const pid = readNum(a, std.fmt.allocPrint(a, "{s}/idProduct", .{base}) catch continue, 16) orelse continue;
        const bus = readNum(a, std.fmt.allocPrint(a, "{s}/busnum", .{base}) catch continue, 10) orelse continue;
        const num = readNum(a, std.fmt.allocPrint(a, "{s}/devnum", .{base}) catch continue, 10) orelse continue;
        var parent: []const u8 = "";
        var port: u32 = 1;
        if (std.mem.startsWith(u8, e.name, "usb")) {
            parent = "";
        } else {
            // "B-P.Q.R": the parent is "B-P.Q" (or the root hub usbB)
            const dash = std.mem.indexOfScalar(u8, e.name, '-') orelse continue;
            if (std.mem.lastIndexOfScalar(u8, e.name, '.')) |dot| {
                parent = a.dupe(u8, e.name[0..dot]) catch "";
                port = std.fmt.parseInt(u32, e.name[dot + 1 ..], 10) catch 0;
            } else {
                parent = std.fmt.allocPrint(a, "usb{s}", .{e.name[0..dash]}) catch "";
                port = std.fmt.parseInt(u32, e.name[dash + 1 ..], 10) catch 0;
            }
        }
        out.push(.{
            .sysname = a.dupe(u8, e.name) catch e.name,
            .bus = bus,
            .num = num,
            .vendor = @intCast(vid),
            .product = @intCast(pid),
            .parent = parent,
            .port = port,
            .cls = @intCast(readNum(a, std.fmt.allocPrint(a, "{s}/bDeviceClass", .{base}) catch continue, 16) orelse 0),
            .speed = readStr(a, std.fmt.allocPrint(a, "{s}/speed", .{base}) catch continue) orelse "",
            .maxchild = readNum(a, std.fmt.allocPrint(a, "{s}/maxchild", .{base}) catch continue, 10) orelse 0,
        });
    }
    std.mem.sort(UsbDev, out.items, {}, struct {
        fn lt(_: void, x: UsbDev, y: UsbDev) bool {
            if (x.bus != y.bus) return x.bus < y.bus;
            return x.num < y.num;
        }
    }.lt);
    return out.items;
}

fn usbClassName(cls: u8) []const u8 {
    const b = classBlock(cls) orelse return "Unknown";
    const nl = std.mem.indexOfScalar(u8, b, '\n') orelse b.len;
    return nameAfter(b[0..nl], 4);
}

fn usbNames(a: std.mem.Allocator, d: UsbDev) []const u8 {
    const base = std.fmt.allocPrint(a, "/sys/bus/usb/devices/{s}", .{d.sysname}) catch return "";
    const vn = vendorName(d.vendor) orelse readStr(a, std.fmt.allocPrint(a, "{s}/manufacturer", .{base}) catch return "");
    const pn = deviceName(d.vendor, d.product) orelse readStr(a, std.fmt.allocPrint(a, "{s}/product", .{base}) catch return "");
    if (vn != null and pn != null) return std.fmt.allocPrint(a, "{s} {s}", .{ vn.?, pn.? }) catch "";
    if (vn) |x| return std.fmt.allocPrint(a, "{s}", .{x}) catch "";
    if (pn) |x| return std.fmt.allocPrint(a, "{s}", .{x}) catch "";
    return "";
}

fn speedText(a: std.mem.Allocator, s: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}M", .{s}) catch "";
}

fn usbDriver(a: std.mem.Allocator, path: []const u8) []const u8 {
    const p = std.fmt.allocPrint(a, "{s}/driver", .{path}) catch return "[none]";
    var buf: [256]u8 = undefined;
    const r = linux.readlink(u.zstr(p), &buf, buf.len);
    if (!u.ok(r)) return "[none]";
    return a.dupe(u8, std.fs.path.basename(buf[0..r])) catch "[none]";
}

fn usbTreeDev(a: std.mem.Allocator, devs: []const UsbDev, d: UsbDev, depth: usize) void {
    const base = std.fmt.allocPrint(a, "/sys/bus/usb/devices/{s}", .{d.sysname}) catch return;
    // interfaces of the active configuration
    var ents = u.Vec(u.DirEnt).init(a);
    _ = u.listDir("/sys/bus/usb/devices", &ents);
    var ifaces = u.Vec([]const u8).init(a);
    const prefix = std.fmt.allocPrint(a, "{s}:", .{d.sysname}) catch return;
    for (ents.items) |e| if (std.mem.startsWith(u8, e.name, prefix)) ifaces.push(a.dupe(u8, e.name) catch e.name);
    std.mem.sort([]const u8, ifaces.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    const indent = spaces(a, 4 * depth);
    if (ifaces.items.len == 0) {
        u.outf("{s}|__ Port {d:0>3}: Dev {d:0>3}, If 0, Class={s}, Driver=[none], {s}\n", .{ indent, d.port, d.num, usbClassName(d.cls), speedText(a, d.speed) });
    }
    for (ifaces.items) |iname| {
        const ip = std.fmt.allocPrint(a, "/sys/bus/usb/devices/{s}", .{iname}) catch continue;
        const icls: u8 = @intCast(readNum(a, std.fmt.allocPrint(a, "{s}/bInterfaceClass", .{ip}) catch continue, 16) orelse 0);
        const inum = readNum(a, std.fmt.allocPrint(a, "{s}/bInterfaceNumber", .{ip}) catch continue, 16) orelse 0;
        var drv = usbDriver(a, ip);
        if (icls == 9 and d.maxchild > 0 and std.mem.eql(u8, drv, "hub")) drv = std.fmt.allocPrint(a, "hub/{d}p", .{d.maxchild}) catch drv;
        u.outf("{s}|__ Port {d:0>3}: Dev {d:0>3}, If {d}, Class={s}, Driver={s}, {s}\n", .{ indent, d.port, d.num, inum, usbClassName(icls), drv, speedText(a, d.speed) });
    }
    _ = base;
    // children sorted by port
    var kids = u.Vec(UsbDev).init(a);
    for (devs) |cd| if (std.mem.eql(u8, cd.parent, d.sysname)) kids.push(cd);
    std.mem.sort(UsbDev, kids.items, {}, struct {
        fn lt(_: void, x: UsbDev, y: UsbDev) bool {
            return x.port < y.port;
        }
    }.lt);
    for (kids.items) |kd| usbTreeDev(a, devs, kd, depth + 1);
}

pub fn lsusb(args: []const []const u8) u8 {
    const opts = [_]g.Opt{
        .{ .name = "verbose", .key = 'v' },
        .{ .name = "tree", .key = 't' },
        .{ .name = "version", .key = 'V' },
        .{ .name = "help", .key = 'h' },
        .{ .name = "", .key = 's', .arg = .req },
        .{ .name = "", .key = 'd', .arg = .req },
        .{ .name = "", .key = 'D', .arg = .req },
    };
    var p = g.Parser.init("lsusb", args, &opts);
    var tree = false;
    var sbus: ?u32 = null;
    var sdev: ?u32 = null;
    var svid: ?u16 = null;
    var spid: ?u16 = null;
    while (p.next() catch return 1) |it| {
        switch (it.key) {
            'h' => {
                u.out("Usage: lsusb [options]...\nList USB devices\n  -v, --verbose\n      Increase verbosity (show descriptors)\n  -s [[bus]:][devnum]\n      Show only devices with specified device and/or\n      bus numbers (in decimal)\n  -d vendor:[product]\n      Show only devices with the specified vendor and\n      product ID numbers (in hexadecimal)\n  -D device\n      Selects which device lsusb will examine\n  -t, --tree\n      Dump the physical USB device hierarchy as a tree\n  -V, --version\n      Show version of program\n  -h, --help\n      Show usage and help\n");
                return 0;
            },
            'V' => {
                u.out("lsusb (usbutils) 019\n");
                return 0;
            },
            't' => tree = true,
            's' => {
                const v = it.val.?;
                if (std.mem.indexOfScalar(u8, v, ':')) |c0| {
                    if (c0 > 0) sbus = std.fmt.parseInt(u32, v[0..c0], 10) catch {
                        u.errf("lsusb: Invalid bus number {s}\n", .{v});
                        return 1;
                    };
                    if (c0 + 1 < v.len) sdev = std.fmt.parseInt(u32, v[c0 + 1 ..], 10) catch {
                        u.errf("lsusb: Invalid device number {s}\n", .{v});
                        return 1;
                    };
                } else sdev = std.fmt.parseInt(u32, v, 10) catch {
                    u.errf("lsusb: Invalid device number {s}\n", .{v});
                    return 1;
                };
            },
            'd' => {
                const v = it.val.?;
                const c0 = std.mem.indexOfScalar(u8, v, ':') orelse {
                    u.errf("lsusb: Invalid vendor:product {s}\n", .{v});
                    return 1;
                };
                if (c0 > 0) svid = std.fmt.parseInt(u16, v[0..c0], 16) catch {
                    u.errf("lsusb: Invalid vendor:product {s}\n", .{v});
                    return 1;
                };
                if (c0 + 1 < v.len) spid = std.fmt.parseInt(u16, v[c0 + 1 ..], 16) catch {
                    u.errf("lsusb: Invalid vendor:product {s}\n", .{v});
                    return 1;
                };
            },
            else => {},
        }
    }
    var arena = std.heap.ArenaAllocator.init(u.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const cands = [_][]const u8{ "/usr/share/hwdata/usb.ids", "/usr/share/usb.ids", "/var/lib/usbutils/usb.ids", "/usr/share/misc/usb.ids" };
    for (cands) |cp| {
        if (mnt.readFile(cp)) |dd| {
            ids_data = dd;
            ids_loaded = true;
            break;
        }
    }
    const devs = scanUsb(a);
    if (tree) {
        var last_bus: u32 = 0;
        for (devs) |d| {
            if (d.parent.len != 0) continue;
            if (d.bus == last_bus) continue;
            last_bus = d.bus;
            const drv = usbDriver(a, std.fmt.allocPrint(a, "/sys/bus/usb/devices/{s}/..", .{d.sysname}) catch "");
            u.outf("/:  Bus {d:0>3}.Port 001: Dev {d:0>3}, Class=root_hub, Driver={s}/{d}p, {s}\n", .{ d.bus, d.num, drv, d.maxchild, speedText(a, d.speed) });
            var kids = u.Vec(UsbDev).init(a);
            for (devs) |cd| if (std.mem.eql(u8, cd.parent, d.sysname)) kids.push(cd);
            std.mem.sort(UsbDev, kids.items, {}, struct {
                fn lt(_: void, x: UsbDev, y: UsbDev) bool {
                    return x.port < y.port;
                }
            }.lt);
            for (kids.items) |kd| usbTreeDev(a, devs, kd, 1);
        }
        return 0;
    }
    var shown: usize = 0;
    for (devs) |d| {
        if (sbus != null and sbus.? != d.bus) continue;
        if (sdev != null and sdev.? != d.num) continue;
        if (svid != null and svid.? != d.vendor) continue;
        if (spid != null and spid.? != d.product) continue;
        u.outf("Bus {d:0>3} Device {d:0>3}: ID {x:0>4}:{x:0>4} {s}\n", .{ d.bus, d.num, d.vendor, d.product, usbNames(a, d) });
        shown += 1;
    }
    if (shown == 0 and (sbus != null or sdev != null or svid != null or spid != null)) return 1;
    return 0;
}
