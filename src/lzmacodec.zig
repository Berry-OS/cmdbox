// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// LZMA / LZMA2 encoder and decoder (self contained, used by xz/lzma applets)
const std = @import("std");
const u = @import("util.zig");

pub const Error = error{ Corrupt, Truncated, Unsupported, NoMem, Io };

// ---------------------------------------------------------------- shared model
const PROB_INIT: u16 = 1024;
const NUM_STATES = 12;
const POS_STATES_MAX = 16;
const LEN_LOW = 8;
const LEN_MID = 8;
const MATCH_MIN = 2;
const MATCH_MAX = 273;

const LenProbs = struct {
    choice: u16 = PROB_INIT,
    choice2: u16 = PROB_INIT,
    low: [POS_STATES_MAX][8]u16 = [_][8]u16{[_]u16{PROB_INIT} ** 8} ** POS_STATES_MAX,
    mid: [POS_STATES_MAX][8]u16 = [_][8]u16{[_]u16{PROB_INIT} ** 8} ** POS_STATES_MAX,
    high: [256]u16 = [_]u16{PROB_INIT} ** 256,
};

pub const Props = struct {
    lc: u8 = 3,
    lp: u8 = 0,
    pb: u8 = 2,

    pub fn byte(self: Props) u8 {
        return (self.pb * 5 + self.lp) * 9 + self.lc;
    }

    pub fn fromByte(b: u8) ?Props {
        if (b >= 225) return null;
        var v = b;
        const lc = v % 9;
        v /= 9;
        return .{ .lc = lc, .lp = v % 5, .pb = v / 5 };
    }
};

const Model = struct {
    props: Props,
    literal: []u16,
    is_match: [NUM_STATES][POS_STATES_MAX]u16,
    is_rep: [NUM_STATES]u16,
    is_rep_g0: [NUM_STATES]u16,
    is_rep_g1: [NUM_STATES]u16,
    is_rep_g2: [NUM_STATES]u16,
    is_rep0_long: [NUM_STATES][POS_STATES_MAX]u16,
    pos_slot: [4][64]u16,
    pos_special: [116]u16,
    align_: [16]u16,
    len: LenProbs,
    rep_len: LenProbs,
    state: u8,
    reps: [4]u32,

    fn init(props: Props) Error!*Model {
        const m = u.alloc.create(Model) catch return error.NoMem;
        m.literal = &.{};
        try m.setProps(props);
        return m;
    }

    fn setProps(m: *Model, props: Props) Error!void {
        if (m.literal.len > 0) u.alloc.free(m.literal);
        m.props = props;
        m.literal = u.alloc.alloc(u16, @as(usize, 0x300) << @intCast(props.lc + props.lp)) catch return error.NoMem;
        m.reset();
    }

    fn reset(m: *Model) void {
        @memset(m.literal, PROB_INIT);
        for (&m.is_match) |*r| @memset(r, PROB_INIT);
        @memset(&m.is_rep, PROB_INIT);
        @memset(&m.is_rep_g0, PROB_INIT);
        @memset(&m.is_rep_g1, PROB_INIT);
        @memset(&m.is_rep_g2, PROB_INIT);
        for (&m.is_rep0_long) |*r| @memset(r, PROB_INIT);
        for (&m.pos_slot) |*r| @memset(r, PROB_INIT);
        @memset(&m.pos_special, PROB_INIT);
        @memset(&m.align_, PROB_INIT);
        m.len = .{};
        m.rep_len = .{};
        m.state = 0;
        m.reps = .{ 0, 0, 0, 0 };
    }
};

fn lenState(len: usize) usize {
    return @min(len - MATCH_MIN, 3);
}

// ---------------------------------------------------------------- input source
pub const Source = struct {
    fd: i32,
    buf: [65536]u8 = undefined,
    pos: usize = 0,
    end: usize = 0,
    total: u64 = 0, // bytes consumed

    pub fn init(fd: i32) Source {
        return .{ .fd = fd };
    }

    fn fill(self: *Source) Error!bool {
        while (true) {
            const r = std.os.linux.read(self.fd, &self.buf, self.buf.len);
            if (u.errno(r) == .INTR) continue;
            if (!u.ok(r)) return error.Io;
            if (r == 0) return false;
            self.pos = 0;
            self.end = r;
            return true;
        }
    }

    pub fn byte(self: *Source) Error!u8 {
        if (self.pos >= self.end) {
            if (!try self.fill()) return error.Truncated;
        }
        const b = self.buf[self.pos];
        self.pos += 1;
        self.total += 1;
        return b;
    }

    pub fn peekByte(self: *Source) Error!?u8 {
        if (self.pos >= self.end) {
            if (!try self.fill()) return null;
        }
        return self.buf[self.pos];
    }

    pub fn read(self: *Source, dst: []u8) Error!void {
        var i: usize = 0;
        while (i < dst.len) {
            if (self.pos >= self.end) {
                if (!try self.fill()) return error.Truncated;
            }
            const n = @min(dst.len - i, self.end - self.pos);
            @memcpy(dst[i .. i + n], self.buf[self.pos .. self.pos + n]);
            self.pos += n;
            self.total += n;
            i += n;
        }
    }
};

// ---------------------------------------------------------------- output window
pub const Sink = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, data: []const u8) Error!void,
};

pub const Window = struct {
    data: []u8,
    len: usize = 0,
    written: usize = 0,
    dict_size: usize,
    total: u64 = 0, // bytes produced since creation
    dict_start: u64 = 0, // total at the last dictionary reset
    sink: Sink,

    pub fn init(dict_size: usize, sink: Sink) Error!Window {
        const ds = @max(dict_size, 4096);
        const cap = ds + @max(@min(ds, 4 << 20), 1 << 20);
        const data = u.alloc.alloc(u8, cap) catch return error.NoMem;
        return .{ .data = data, .dict_size = ds, .sink = sink };
    }

    pub fn deinit(self: *Window) void {
        u.alloc.free(self.data);
    }

    pub fn resetDict(self: *Window) void {
        self.dict_start = self.total;
    }

    pub fn flush(self: *Window) Error!void {
        if (self.written < self.len) try self.sink.write(self.sink.ctx, self.data[self.written..self.len]);
        self.written = self.len;
    }

    fn makeRoom(self: *Window) Error!void {
        try self.flush();
        const keep = @min(self.len, self.dict_size);
        std.mem.copyForwards(u8, self.data[0..keep], self.data[self.len - keep .. self.len]);
        self.len = keep;
        self.written = keep;
    }

    pub fn put(self: *Window, b: u8) Error!void {
        if (self.len == self.data.len) try self.makeRoom();
        self.data[self.len] = b;
        self.len += 1;
        self.total += 1;
    }

    pub fn inDict(self: *const Window) u64 {
        return self.total - self.dict_start;
    }

    pub fn back(self: *const Window, dist: usize) u8 {
        // dist is 1-based
        return self.data[self.len - dist];
    }

    pub fn prevByte(self: *const Window) u8 {
        if (self.inDict() == 0) return 0;
        return self.data[self.len - 1];
    }

    pub fn copyMatch(self: *Window, dist: usize, length: usize) Error!void {
        var i: usize = 0;
        while (i < length) : (i += 1) {
            if (self.len == self.data.len) try self.makeRoom();
            self.data[self.len] = self.data[self.len - dist];
            self.len += 1;
            self.total += 1;
        }
    }
};

// ---------------------------------------------------------------- range decoder
const RangeDec = struct {
    src: *Source,
    range: u32 = 0xFFFFFFFF,
    code: u32 = 0,

    fn init(src: *Source) Error!RangeDec {
        var rd = RangeDec{ .src = src };
        if (try src.byte() != 0) return error.Corrupt;
        var i: usize = 0;
        while (i < 4) : (i += 1) rd.code = (rd.code << 8) | try src.byte();
        if (rd.code == rd.range) return error.Corrupt;
        return rd;
    }

    inline fn norm(self: *RangeDec) Error!void {
        if (self.range < (1 << 24)) {
            self.range <<= 8;
            self.code = (self.code << 8) | try self.src.byte();
        }
    }

    fn bit(self: *RangeDec, prob: *u16) Error!u1 {
        try self.norm();
        const bound = (self.range >> 11) * prob.*;
        if (self.code < bound) {
            self.range = bound;
            prob.* += (2048 - prob.*) >> 5;
            return 0;
        }
        self.range -= bound;
        self.code -= bound;
        prob.* -= prob.* >> 5;
        return 1;
    }

    fn direct(self: *RangeDec, n: u32) Error!u32 {
        var r: u32 = 0;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            try self.norm();
            self.range >>= 1;
            self.code -%= self.range;
            const t = 0 -% (self.code >> 31);
            self.code +%= self.range & t;
            r = (r << 1) +% (t +% 1);
        }
        return r;
    }

    fn tree(self: *RangeDec, probs: []u16, bits: u5) Error!u32 {
        var m: u32 = 1;
        var i: u5 = 0;
        while (i < bits) : (i += 1) m = (m << 1) | try self.bit(&probs[m]);
        return m - (@as(u32, 1) << bits);
    }

    fn revTree(self: *RangeDec, probs: []u16, base: usize, bits: u5) Error!u32 {
        var m: u32 = 1;
        var sym: u32 = 0;
        var i: u5 = 0;
        while (i < bits) : (i += 1) {
            const b = try self.bit(&probs[base + m]);
            m = (m << 1) | b;
            sym |= @as(u32, b) << i;
        }
        return sym;
    }

    fn len(self: *RangeDec, lp: *LenProbs, pos_state: usize) Error!usize {
        if (try self.bit(&lp.choice) == 0) return MATCH_MIN + try self.tree(&lp.low[pos_state], 3);
        if (try self.bit(&lp.choice2) == 0) return MATCH_MIN + 8 + try self.tree(&lp.mid[pos_state], 3);
        return MATCH_MIN + 16 + try self.tree(&lp.high, 8);
    }
};

// ---------------------------------------------------------------- decoder
pub const Decoder = struct {
    model: *Model,
    win: *Window,

    pub fn init(props: Props, win: *Window) Error!Decoder {
        return .{ .model = try Model.init(props), .win = win };
    }

    pub fn setProps(self: *Decoder, props: Props) Error!void {
        try self.model.setProps(props);
    }

    pub fn resetState(self: *Decoder) void {
        self.model.reset();
    }

    /// Decode symbols until `limit` bytes were produced (limit == null: until end marker).
    /// Returns the number of bytes produced; `ended` tells whether an end marker was seen.
    pub fn run(self: *Decoder, rd: *RangeDec, limit: ?u64, ended: *bool) Error!u64 {
        const m = self.model;
        const w = self.win;
        const lc: u5 = @intCast(m.props.lc);
        const pb_mask: u64 = (@as(u64, 1) << @intCast(m.props.pb)) - 1;
        const lp_mask: u64 = (@as(u64, 1) << @intCast(m.props.lp)) - 1;
        var produced: u64 = 0;
        ended.* = false;
        while (limit == null or produced < limit.?) {
            const pos = w.inDict();
            const pos_state: usize = @intCast(pos & pb_mask);
            const st: usize = m.state;
            if (try rd.bit(&m.is_match[st][pos_state]) == 0) {
                // literal
                const prev: u32 = w.prevByte();
                const lit_base: usize = 0x300 * ((@as(usize, @intCast(pos & lp_mask)) << lc) + (prev >> @intCast(8 - @as(u5, lc))));
                const probs = m.literal[lit_base .. lit_base + 0x300];
                var sym: u32 = 1;
                if (st >= 7) {
                    if (w.inDict() <= m.reps[0]) return error.Corrupt;
                    var match_byte: u32 = w.back(m.reps[0] + 1);
                    var offs: u32 = 0x100;
                    while (sym < 0x100) {
                        match_byte <<= 1;
                        const mbit = match_byte & offs;
                        const b = try rd.bit(&probs[offs + mbit + sym]);
                        sym = (sym << 1) | b;
                        if (b == 0) offs &= ~mbit else offs &= mbit;
                    }
                } else {
                    while (sym < 0x100) sym = (sym << 1) | try rd.bit(&probs[sym]);
                }
                try w.put(@truncate(sym));
                produced += 1;
                m.state = if (st < 4) 0 else if (st < 10) @intCast(st - 3) else @intCast(st - 6);
                continue;
            }
            var length: usize = 0;
            if (try rd.bit(&m.is_rep[st]) == 0) {
                // simple match
                m.reps[3] = m.reps[2];
                m.reps[2] = m.reps[1];
                m.reps[1] = m.reps[0];
                length = try rd.len(&m.len, pos_state);
                m.state = if (st < 7) 7 else 10;
                const slot: u32 = try rd.tree(&m.pos_slot[lenState(length)], 6);
                var dist: u32 = slot;
                if (slot >= 4) {
                    const nd: u5 = @intCast((slot >> 1) - 1);
                    dist = (2 | (slot & 1)) << nd;
                    if (slot < 14) {
                        dist += try rd.revTree(&m.pos_special, dist - slot, nd);
                    } else {
                        dist +%= (try rd.direct(nd - 4)) << 4;
                        dist +%= try rd.revTree(&m.align_, 0, 4);
                    }
                }
                if (dist == 0xFFFFFFFF) {
                    ended.* = true;
                    return produced;
                }
                m.reps[0] = dist;
            } else {
                if (w.inDict() == 0) return error.Corrupt;
                if (try rd.bit(&m.is_rep_g0[st]) == 0) {
                    if (try rd.bit(&m.is_rep0_long[st][pos_state]) == 0) {
                        // short rep
                        m.state = if (st < 7) 9 else 11;
                        if (w.inDict() <= m.reps[0]) return error.Corrupt;
                        try w.put(w.back(m.reps[0] + 1));
                        produced += 1;
                        continue;
                    }
                } else {
                    var dist: u32 = 0;
                    if (try rd.bit(&m.is_rep_g1[st]) == 0) {
                        dist = m.reps[1];
                    } else {
                        if (try rd.bit(&m.is_rep_g2[st]) == 0) {
                            dist = m.reps[2];
                        } else {
                            dist = m.reps[3];
                            m.reps[3] = m.reps[2];
                        }
                        m.reps[2] = m.reps[1];
                    }
                    m.reps[1] = m.reps[0];
                    m.reps[0] = dist;
                }
                length = try rd.len(&m.rep_len, pos_state);
                m.state = if (st < 7) 8 else 11;
            }
            const dist1: usize = @as(usize, m.reps[0]) + 1;
            if (w.inDict() < dist1 or dist1 > w.dict_size) return error.Corrupt;
            if (limit) |lm| if (produced + length > lm) return error.Corrupt;
            try w.copyMatch(dist1, length);
            produced += length;
        }
        return produced;
    }
};

pub fn rangeDecoderInit(src: *Source) Error!RangeDec {
    return RangeDec.init(src);
}

pub fn finishChunk(rd: *RangeDec) Error!void {
    try rd.norm();
    if (rd.code != 0) return error.Corrupt;
}

// ---------------------------------------------------------------- LZMA2 decode
pub fn lzma2Decode(src: *Source, win: *Window) Error!u64 {
    var dec: ?Decoder = null;
    var need_dict_reset = true;
    var need_props = true;
    var total: u64 = 0;
    while (true) {
        const control = try src.byte();
        if (control == 0) break;
        if (control == 1 or control == 2) {
            if (control == 1) {
                win.resetDict();
                need_dict_reset = false;
            } else if (need_dict_reset) return error.Corrupt;
            const hi = try src.byte();
            const lo = try src.byte();
            var n: usize = ((@as(usize, hi) << 8) | lo) + 1;
            var tmp: [4096]u8 = undefined;
            while (n > 0) {
                const k = @min(n, tmp.len);
                try src.read(tmp[0..k]);
                for (tmp[0..k]) |b| try win.put(b);
                n -= k;
                total += k;
            }
            if (dec) |*d| d.resetState();
            continue;
        }
        if (control < 0x80) return error.Corrupt;
        const b1 = try src.byte();
        const b2 = try src.byte();
        const unc: u64 = ((@as(u64, control & 0x1f) << 16) | (@as(u64, b1) << 8) | b2) + 1;
        const c1 = try src.byte();
        const c2 = try src.byte();
        const comp: u64 = ((@as(u64, c1) << 8) | c2) + 1;
        const mode = (control >> 5) & 3;
        if (mode == 3) {
            win.resetDict();
            need_dict_reset = false;
        } else if (need_dict_reset) return error.Corrupt;
        if (mode >= 2) {
            const pbyte = try src.byte();
            const props = Props.fromByte(pbyte) orelse return error.Corrupt;
            if (props.lc + props.lp > 4) return error.Corrupt;
            if (dec) |*d| try d.setProps(props) else dec = try Decoder.init(props, win);
            need_props = false;
        } else if (need_props) return error.Corrupt;
        if (mode == 1 or mode == 2) dec.?.resetState();
        if (mode == 3 and dec != null) dec.?.resetState();
        const start = src.total;
        var rd = try rangeDecoderInit(src);
        var ended = false;
        const got = try dec.?.run(&rd, unc, &ended);
        if (got != unc or ended) return error.Corrupt;
        try finishChunk(&rd);
        if (src.total - start != comp) return error.Corrupt;
        total += unc;
    }
    return total;
}

// ---------------------------------------------------------------- range encoder
const RangeEnc = struct {
    low: u64 = 0,
    range: u32 = 0xFFFFFFFF,
    cache: u8 = 0,
    cache_size: u64 = 1,
    out: u.Vec(u8),

    fn init() RangeEnc {
        return .{ .out = u.Vec(u8).init(u.alloc) };
    }

    fn reset(self: *RangeEnc) void {
        self.low = 0;
        self.range = 0xFFFFFFFF;
        self.cache = 0;
        self.cache_size = 1;
        self.out.items.len = 0;
    }

    fn shiftLow(self: *RangeEnc) void {
        if (@as(u32, @truncate(self.low)) < 0xFF000000 or (self.low >> 32) != 0) {
            const carry: u8 = @truncate(self.low >> 32);
            var tmp = self.cache;
            while (true) {
                self.out.push(tmp +% carry);
                tmp = 0xFF;
                self.cache_size -= 1;
                if (self.cache_size == 0) break;
            }
            self.cache = @truncate(self.low >> 24);
        }
        self.cache_size += 1;
        self.low = (self.low & 0x00FFFFFF) << 8;
    }

    fn bit(self: *RangeEnc, prob: *u16, b: u1) void {
        const bound = (self.range >> 11) * prob.*;
        if (b == 0) {
            self.range = bound;
            prob.* += (2048 - prob.*) >> 5;
        } else {
            self.low += bound;
            self.range -= bound;
            prob.* -= prob.* >> 5;
        }
        while (self.range < (1 << 24)) {
            self.range <<= 8;
            self.shiftLow();
        }
    }

    fn direct(self: *RangeEnc, value: u32, n: u32) void {
        var i: u32 = n;
        while (i > 0) {
            i -= 1;
            self.range >>= 1;
            if ((value >> @intCast(i)) & 1 != 0) self.low += self.range;
            while (self.range < (1 << 24)) {
                self.range <<= 8;
                self.shiftLow();
            }
        }
    }

    fn tree(self: *RangeEnc, probs: []u16, bits: u5, sym: u32) void {
        var m: u32 = 1;
        var i: u5 = bits;
        while (i > 0) {
            i -= 1;
            const b: u1 = @intCast((sym >> i) & 1);
            self.bit(&probs[m], b);
            m = (m << 1) | b;
        }
    }

    fn revTree(self: *RangeEnc, probs: []u16, base: usize, bits: u5, sym: u32) void {
        var m: u32 = 1;
        var i: u5 = 0;
        while (i < bits) : (i += 1) {
            const b: u1 = @intCast((sym >> i) & 1);
            self.bit(&probs[base + m], b);
            m = (m << 1) | b;
        }
    }

    fn flush(self: *RangeEnc) void {
        var i: usize = 0;
        while (i < 5) : (i += 1) self.shiftLow();
    }

    fn len(self: *RangeEnc, lp: *LenProbs, l: usize, pos_state: usize) void {
        const v = l - MATCH_MIN;
        if (v < 8) {
            self.bit(&lp.choice, 0);
            self.tree(&lp.low[pos_state], 3, @intCast(v));
        } else if (v < 16) {
            self.bit(&lp.choice, 1);
            self.bit(&lp.choice2, 0);
            self.tree(&lp.mid[pos_state], 3, @intCast(v - 8));
        } else {
            self.bit(&lp.choice, 1);
            self.bit(&lp.choice2, 1);
            self.tree(&lp.high, 8, @intCast(v - 16));
        }
    }
};

fn distSlot(dist: u32) u32 {
    if (dist < 4) return dist;
    const hb: u32 = 31 - @clz(dist);
    return (hb << 1) | ((dist >> @intCast(hb - 1)) & 1);
}

// ---------------------------------------------------------------- encoder
pub const EncOptions = struct {
    dict_size: u32 = 8 << 20,
    nice_len: usize = 64,
    depth: usize = 32,
    lazy: bool = true,
    props: Props = .{},
};

pub const Encoder = struct {
    opt: EncOptions,
    m: *Model,
    rc: RangeEnc,
    data: []const u8,
    head: []i32,
    prev: []i32,
    hash_mask: usize,
    prev_mask: usize,
    inserted: usize = 0,

    pub fn init(data: []const u8, opt: EncOptions) Error!Encoder {
        var hbits: u5 = 16;
        while (hbits < 24 and (@as(usize, 1) << hbits) < data.len) hbits += 1;
        const head = u.alloc.alloc(i32, @as(usize, 1) << hbits) catch return error.NoMem;
        @memset(head, -1);
        var psz: usize = 1 << 12;
        while (psz < opt.dict_size and psz < data.len) psz <<= 1;
        const prev = u.alloc.alloc(i32, psz) catch return error.NoMem;
        return .{ .opt = opt, .m = try Model.init(opt.props), .rc = RangeEnc.init(), .data = data, .head = head, .prev = prev, .hash_mask = head.len - 1, .prev_mask = psz - 1 };
    }

    pub fn deinit(self: *Encoder) void {
        u.alloc.free(self.head);
        u.alloc.free(self.prev);
    }

    fn hash(self: *const Encoder, pos: usize) usize {
        const d = self.data;
        const v: u32 = @as(u32, d[pos]) | (@as(u32, d[pos + 1]) << 8) | (@as(u32, d[pos + 2]) << 16) | (@as(u32, d[pos + 3]) << 24);
        return @intCast((v *% 2654435761) >> @intCast(32 - @as(u6, @intCast(std.math.log2_int(usize, self.head.len)))));
    }

    fn insertUpTo(self: *Encoder, pos: usize) void {
        // insert all positions < pos that have 4 bytes available
        while (self.inserted < pos) : (self.inserted += 1) {
            const p = self.inserted;
            if (p + 4 > self.data.len) continue;
            const h = self.hash(p);
            self.prev[p & self.prev_mask] = self.head[h];
            self.head[h] = @intCast(p);
        }
    }

    const Match = struct { len: usize = 0, dist: usize = 0 }; // dist is 0-based

    fn matchLen(self: *const Encoder, a: usize, b: usize, max: usize) usize {
        var n: usize = 0;
        const d = self.data;
        while (n < max and d[a + n] == d[b + n]) n += 1;
        return n;
    }

    fn findMatch(self: *Encoder, pos: usize, win_start: usize) Match {
        var best = Match{};
        const remaining = self.data.len - pos;
        if (remaining < 4) {
            // short tail: only check the previous bytes with a linear probe
            return best;
        }
        const max = @min(MATCH_MAX, remaining);
        self.insertUpTo(pos);
        var cand = self.head[self.hash(pos)];
        var depth = self.opt.depth;
        const lowest: isize = @as(isize, @intCast(pos)) - @as(isize, @intCast(@min(@as(usize, self.opt.dict_size), self.prev.len))) + 1;
        while (cand >= 0 and depth > 0) : (depth -= 1) {
            const c: usize = @intCast(cand);
            if (c >= pos or @as(isize, cand) < lowest or c < win_start) break;
            if (self.data[c + best.len] == self.data[pos + best.len] or best.len == 0) {
                const l = self.matchLen(c, pos, max);
                if (l > best.len) {
                    best = .{ .len = l, .dist = pos - c - 1 };
                    if (l >= self.opt.nice_len or l == max) break;
                }
            }
            const nxt = self.prev[c & self.prev_mask];
            if (nxt >= cand) break;
            cand = nxt;
        }
        return best;
    }

    fn encLiteral(self: *Encoder, pos: usize, pos_in_dict: u64) void {
        const m = self.m;
        const lc: u5 = @intCast(m.props.lc);
        const lp_mask: u64 = (@as(u64, 1) << @intCast(m.props.lp)) - 1;
        const pb_mask: u64 = (@as(u64, 1) << @intCast(m.props.pb)) - 1;
        const pos_state: usize = @intCast(pos_in_dict & pb_mask);
        const st: usize = m.state;
        self.rc.bit(&m.is_match[st][pos_state], 0);
        const prev: u32 = if (pos_in_dict == 0) 0 else self.data[pos - 1];
        const base: usize = 0x300 * ((@as(usize, @intCast(pos_in_dict & lp_mask)) << lc) + (prev >> @intCast(8 - @as(u5, lc))));
        const probs = m.literal[base .. base + 0x300];
        const byte: u32 = self.data[pos];
        var sym: u32 = 1;
        if (st >= 7) {
            var match_byte: u32 = self.data[pos - m.reps[0] - 1];
            var offs: u32 = 0x100;
            var i: u5 = 8;
            while (i > 0) {
                i -= 1;
                match_byte <<= 1;
                const mbit = match_byte & offs;
                const b: u1 = @intCast((byte >> i) & 1);
                self.rc.bit(&probs[offs + mbit + sym], b);
                sym = (sym << 1) | b;
                if (b == 0) offs &= ~mbit else offs &= mbit;
            }
        } else {
            var i: u5 = 8;
            while (i > 0) {
                i -= 1;
                const b: u1 = @intCast((byte >> i) & 1);
                self.rc.bit(&probs[sym], b);
                sym = (sym << 1) | b;
            }
        }
        m.state = if (st < 4) 0 else if (st < 10) @intCast(st - 3) else @intCast(st - 6);
    }

    fn encMatch(self: *Encoder, dist: u32, length: usize, pos_in_dict: u64) void {
        const m = self.m;
        const pb_mask: u64 = (@as(u64, 1) << @intCast(m.props.pb)) - 1;
        const pos_state: usize = @intCast(pos_in_dict & pb_mask);
        const st: usize = m.state;
        self.rc.bit(&m.is_match[st][pos_state], 1);
        self.rc.bit(&m.is_rep[st], 0);
        self.rc.len(&m.len, length, pos_state);
        const slot = distSlot(dist);
        self.rc.tree(&m.pos_slot[lenState(length)], 6, slot);
        if (slot >= 4) {
            const nd: u5 = @intCast((slot >> 1) - 1);
            const base: u32 = (2 | (slot & 1)) << nd;
            const rem = dist -% base;
            if (slot < 14) {
                self.rc.revTree(&m.pos_special, base - slot, nd, rem);
            } else {
                self.rc.direct(rem >> 4, nd - 4);
                self.rc.revTree(&m.align_, 0, 4, rem & 15);
            }
        }
        m.reps[3] = m.reps[2];
        m.reps[2] = m.reps[1];
        m.reps[1] = m.reps[0];
        m.reps[0] = dist;
        m.state = if (st < 7) 7 else 10;
    }

    fn encRep(self: *Encoder, idx: usize, length: usize, pos_in_dict: u64) void {
        const m = self.m;
        const pb_mask: u64 = (@as(u64, 1) << @intCast(m.props.pb)) - 1;
        const pos_state: usize = @intCast(pos_in_dict & pb_mask);
        const st: usize = m.state;
        self.rc.bit(&m.is_match[st][pos_state], 1);
        self.rc.bit(&m.is_rep[st], 1);
        if (idx == 0) {
            self.rc.bit(&m.is_rep_g0[st], 0);
            self.rc.bit(&m.is_rep0_long[st][pos_state], 1);
        } else {
            self.rc.bit(&m.is_rep_g0[st], 1);
            const dist = m.reps[idx];
            if (idx == 1) {
                self.rc.bit(&m.is_rep_g1[st], 0);
            } else {
                self.rc.bit(&m.is_rep_g1[st], 1);
                self.rc.bit(&m.is_rep_g2[st], if (idx == 2) 0 else 1);
                if (idx == 3) m.reps[3] = m.reps[2];
                m.reps[2] = m.reps[1];
            }
            m.reps[1] = m.reps[0];
            m.reps[0] = dist;
        }
        self.rc.len(&m.rep_len, length, pos_state);
        m.state = if (st < 7) 8 else 11;
    }

    /// Encode one symbol at `pos`; returns bytes consumed.
    fn encodeStep(self: *Encoder, pos: usize, win_start: usize, limit: usize) usize {
        const m = self.m;
        const pid: u64 = pos - win_start;
        const remaining = limit - pos;
        const max = @min(MATCH_MAX, remaining);
        // rep candidates
        var best_rep_len: usize = 0;
        var best_rep_idx: usize = 0;
        if (pid > 0) {
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                const d = @as(usize, m.reps[i]) + 1;
                if (d > pos - win_start or d > self.opt.dict_size) continue;
                if (max < 2) continue;
                const l = self.matchLen(pos - d, pos, max);
                if (l > best_rep_len) {
                    best_rep_len = l;
                    best_rep_idx = i;
                }
            }
        }
        var mm = Match{};
        if (max >= 4) mm = self.findMatch(pos, win_start);
        if (mm.len > max) mm.len = max;
        var use_rep = false;
        if (best_rep_len >= 2 and (best_rep_len + 2 >= mm.len or best_rep_len >= self.opt.nice_len)) use_rep = true;
        if (!use_rep) {
            // discard weak matches
            if (mm.len < 3 or (mm.len == 3 and mm.dist >= 1 << 14)) mm.len = 0;
            // lazy evaluation: a clearly longer match at the next byte wins
            if (self.opt.lazy and mm.len > 0 and mm.len < self.opt.nice_len and pos + 1 < limit) {
                const nxt = self.findMatch(pos + 1, win_start);
                if (nxt.len > mm.len + 1 or (nxt.len == mm.len + 1 and nxt.dist < mm.dist)) mm.len = 0;
            }
        }
        if (use_rep) {
            self.encRep(best_rep_idx, best_rep_len, pid);
            return best_rep_len;
        }
        if (mm.len >= 3) {
            self.encMatch(@intCast(mm.dist), mm.len, pid);
            return mm.len;
        }
        // short rep (one byte at rep0) is cheaper than a literal when it matches
        if (pid > 0 and m.state >= 7) {
            const d = @as(usize, m.reps[0]) + 1;
            if (d <= pos - win_start and self.data[pos - d] == self.data[pos]) {
                const pb_mask: u64 = (@as(u64, 1) << @intCast(m.props.pb)) - 1;
                const pos_state: usize = @intCast(pid & pb_mask);
                const st: usize = m.state;
                self.rc.bit(&m.is_match[st][pos_state], 1);
                self.rc.bit(&m.is_rep[st], 1);
                self.rc.bit(&m.is_rep_g0[st], 0);
                self.rc.bit(&m.is_rep0_long[st][pos_state], 0);
                m.state = if (st < 7) 9 else 11;
                return 1;
            }
        }
        self.encLiteral(pos, pid);
        return 1;
    }
};

pub const OutFn = *const fn (ctx: *anyopaque, data: []const u8) Error!void;

/// Compress `data` into an LZMA2 stream (dictionary reset at the start, end marker byte 0x00 included).
pub fn lzma2Encode(data: []const u8, opt: EncOptions, ctx: *anyopaque, out: OutFn) Error!void {
    var enc = try Encoder.init(data, opt);
    defer enc.deinit();
    var pos: usize = 0;
    var first = true;
    var props_sent = false;
    var need_state_reset = false;
    while (pos < data.len) {
        const chunk_start = pos;
        enc.rc.reset();
        const unc_limit = @min(data.len, chunk_start + (1 << 21) - MATCH_MAX);
        while (pos < unc_limit) {
            if (enc.rc.out.items.len + enc.rc.cache_size > 62000) break;
            pos += enc.encodeStep(pos, 0, unc_limit);
        }
        enc.rc.flush();
        const unc = pos - chunk_start;
        const comp = enc.rc.out.items.len;
        if (comp < unc and comp <= 65536 and unc <= (1 << 21)) {
            var control: u8 = 0x80;
            if (first) {
                control = 0xE0;
            } else if (!props_sent) {
                control = 0xC0;
            } else if (need_state_reset) control = 0xA0;
            var hdr: [6]u8 = undefined;
            hdr[0] = control | @as(u8, @intCast((unc - 1) >> 16));
            hdr[1] = @intCast(((unc - 1) >> 8) & 0xff);
            hdr[2] = @intCast((unc - 1) & 0xff);
            hdr[3] = @intCast(((comp - 1) >> 8) & 0xff);
            hdr[4] = @intCast((comp - 1) & 0xff);
            var hl: usize = 5;
            if (control >= 0xC0) {
                hdr[5] = enc.m.props.byte();
                hl = 6;
            }
            try out(ctx, hdr[0..hl]);
            try out(ctx, enc.rc.out.items);
            props_sent = true;
            first = false;
            need_state_reset = false;
        } else {
            // incompressible: store as uncompressed chunks and restart the LZMA state
            var p = chunk_start;
            while (p < pos) {
                const n = @min(pos - p, 65536);
                var hdr: [3]u8 = undefined;
                hdr[0] = if (first) 1 else 2;
                hdr[1] = @intCast(((n - 1) >> 8) & 0xff);
                hdr[2] = @intCast((n - 1) & 0xff);
                try out(ctx, &hdr);
                try out(ctx, data[p .. p + n]);
                p += n;
                first = false;
            }
            enc.m.reset();
            need_state_reset = true;
        }
    }
    try out(ctx, &[_]u8{0});
}

/// Raw LZMA stream (for the .lzma "alone" format): symbols followed by an end marker.
pub fn lzmaEncode(data: []const u8, opt: EncOptions, ctx: *anyopaque, out: OutFn) Error!void {
    var enc = try Encoder.init(data, opt);
    defer enc.deinit();
    enc.rc.reset();
    var pos: usize = 0;
    while (pos < data.len) {
        pos += enc.encodeStep(pos, 0, data.len);
        if (enc.rc.out.items.len > 1 << 16) {
            try out(ctx, enc.rc.out.items);
            enc.rc.out.items.len = 0;
        }
    }
    // end of payload marker: match with distance 0xFFFFFFFF
    const m = enc.m;
    const pb_mask: u64 = (@as(u64, 1) << @intCast(m.props.pb)) - 1;
    const pos_state: usize = @intCast(@as(u64, data.len) & pb_mask);
    const st: usize = m.state;
    enc.rc.bit(&m.is_match[st][pos_state], 1);
    enc.rc.bit(&m.is_rep[st], 0);
    enc.rc.len(&m.len, MATCH_MIN, pos_state);
    enc.rc.tree(&m.pos_slot[0], 6, 63);
    enc.rc.direct(0x3FFFFFF, 26);
    enc.rc.revTree(&m.align_, 0, 4, 15);
    enc.rc.flush();
    try out(ctx, enc.rc.out.items);
}
