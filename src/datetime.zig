// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// datetime.zig - GNU-style date string parsing and strftime formatting
// shared by date(1) and touch(1). Time zone handling is delegated to musl.

const std = @import("std");
const u = @import("util.zig");
pub const c = @cImport({
    @cInclude("time.h");
    @cInclude("stdlib.h");
});

pub const Ts = struct { sec: i64, nsec: i64 = 0 };

pub fn setUtc() void {
    _ = c.setenv("TZ", "UTC0", 1);
    c.tzset();
}

pub fn localtime(sec: i64) c.struct_tm {
    var t: c.time_t = @intCast(sec);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&t, &tm);
    return tm;
}

fn eqi(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

const Unit = enum { sec, min, hour, day, week, fortnight, month, year };

fn unitOf(w: []const u8) ?Unit {
    var s = w;
    if (s.len > 1 and (s[s.len - 1] == 's' or s[s.len - 1] == 'S')) s = s[0 .. s.len - 1];
    if (eqi(s, "sec") or eqi(s, "second")) return .sec;
    if (eqi(s, "min") or eqi(s, "minute")) return .min;
    if (eqi(s, "hour")) return .hour;
    if (eqi(s, "day")) return .day;
    if (eqi(s, "week")) return .week;
    if (eqi(s, "fortnight")) return .fortnight;
    if (eqi(s, "month")) return .month;
    if (eqi(s, "year")) return .year;
    return null;
}

const month_names = [_][]const u8{ "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december" };
const day_names = [_][]const u8{ "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" };

fn abbrevMatch(w: []const u8, full: []const u8) bool {
    if (w.len < 3) return false;
    if (w.len > full.len) return false;
    if (std.ascii.eqlIgnoreCase(w, full[0..w.len])) return true;
    // "sept", "tues", "wednes", "thur(s)"
    return false;
}

fn monthOf(w: []const u8) ?i32 {
    for (month_names, 0..) |m, i| {
        if (abbrevMatch(w, m)) return @intCast(i);
    }
    if (eqi(w, "sept")) return 8;
    return null;
}

fn weekdayOf(w: []const u8) ?i32 {
    for (day_names, 0..) |d, i| {
        if (abbrevMatch(w, d) and (w.len == 3 or w.len >= 3)) return @intCast(i);
    }
    if (eqi(w, "tues")) return 2;
    if (eqi(w, "wednes")) return 3;
    if (eqi(w, "thur") or eqi(w, "thurs")) return 4;
    return null;
}

fn tzOf(w: []const u8) ?i32 {
    const T = struct { n: []const u8, off: i32 };
    const tab = [_]T{
        .{ .n = "z", .off = 0 },     .{ .n = "utc", .off = 0 },    .{ .n = "gmt", .off = 0 },
        .{ .n = "ut", .off = 0 },    .{ .n = "est", .off = -5 },   .{ .n = "edt", .off = -4 },
        .{ .n = "cst", .off = -6 },  .{ .n = "cdt", .off = -5 },   .{ .n = "mst", .off = -7 },
        .{ .n = "mdt", .off = -6 },  .{ .n = "pst", .off = -8 },   .{ .n = "pdt", .off = -7 },
        .{ .n = "jst", .off = 9 },   .{ .n = "cet", .off = 1 },    .{ .n = "cest", .off = 2 },
        .{ .n = "eet", .off = 2 },   .{ .n = "bst", .off = 1 },    .{ .n = "hst", .off = -10 },
        .{ .n = "akst", .off = -9 }, .{ .n = "akdt", .off = -8 },
    };
    for (tab) |t| if (eqi(w, t.n)) return t.off * 3600;
    return null;
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (!isDigit(ch)) return false;
    return true;
}

fn num(s: []const u8) ?i64 {
    if (!allDigits(s) or s.len > 18) return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

fn fullYear(y: i64, digits: usize) i64 {
    if (digits <= 2) return if (y < 69) 2000 + y else 1900 + y;
    return y;
}

// "SS[.frac]" -> seconds and nanoseconds
fn parseSec(s: []const u8, nsec: *i64) ?i64 {
    var i: usize = 0;
    while (i < s.len and isDigit(s[i])) i += 1;
    const sec = num(s[0..i]) orelse return null;
    nsec.* = 0;
    if (i < s.len) {
        if ((s[i] != '.' and s[i] != ',') or i + 1 >= s.len) return null;
        var d: usize = 0;
        var scale: i64 = 100_000_000;
        var k = i + 1;
        while (k < s.len and isDigit(s[k])) : (k += 1) {
            if (d < 9) nsec.* += @as(i64, s[k] - '0') * scale;
            scale = @divTrunc(scale, 10);
            d += 1;
        }
        if (k != s.len) return null;
    }
    return sec;
}

const State = struct {
    have_date: bool = false,
    have_time: bool = false,
    have_zone: bool = false,
    zone: i32 = 0,
    year: ?i64 = null,
    mon: ?i32 = null,
    day: ?i32 = null,
    hour: i32 = 0,
    min: i32 = 0,
    sec: i64 = 0,
    nsec: i64 = 0,
    ry: i64 = 0,
    rmon: i64 = 0,
    rday: i64 = 0,
    rhour: i64 = 0,
    rmin: i64 = 0,
    rsec: i64 = 0,
    rnsec: i64 = 0,
    weekday: ?i32 = null,
    weekday_n: i64 = 0,
    have_rel: bool = false,
    epoch: ?Ts = null,
};

fn addRel(st: *State, n: i64, unit: Unit) void {
    st.have_rel = true;
    switch (unit) {
        .sec => st.rsec += n,
        .min => st.rmin += n,
        .hour => st.rhour += n,
        .day => st.rday += n,
        .week => st.rday += 7 * n,
        .fortnight => st.rday += 14 * n,
        .month => st.rmon += n,
        .year => st.ry += n,
    }
}

fn parseTimeTok(st: *State, tok: []const u8) bool {
    // H:M[:S[.f]][am|pm][Z|+hh:mm]
    var s = tok;
    var pm: ?bool = null;
    var zone: ?i32 = null;
    // zone suffix
    var zi: ?usize = null;
    for (s, 0..) |ch, i| {
        if (i > 0 and (ch == '+' or ch == '-' or ch == 'Z' or ch == 'z')) {
            zi = i;
            break;
        }
    }
    if (zi) |i| {
        zone = parseZoneOff(s[i..]) orelse return false;
        s = s[0..i];
    }
    if (s.len > 2) {
        const tail = s[s.len - 2 ..];
        if (eqi(tail, "am") or eqi(tail, "pm")) {
            pm = eqi(tail, "pm");
            s = s[0 .. s.len - 2];
        }
    }
    var parts: [3][]const u8 = undefined;
    var np: usize = 0;
    var it = std.mem.splitScalar(u8, s, ':');
    while (it.next()) |p| {
        if (np >= 3) return false;
        parts[np] = p;
        np += 1;
    }
    if (np < 2) return false;
    const h = num(parts[0]) orelse return false;
    const m = num(parts[1]) orelse return false;
    var sec: i64 = 0;
    var ns: i64 = 0;
    if (np == 3) sec = parseSec(parts[2], &ns) orelse return false;
    var hh = h;
    if (pm) |is_pm| {
        if (hh < 1 or hh > 12) return false;
        if (hh == 12) hh = 0;
        if (is_pm) hh += 12;
    }
    if (hh > 24 or m > 59 or sec > 60) return false;
    st.hour = @intCast(hh);
    st.min = @intCast(m);
    st.sec = sec;
    st.nsec = ns;
    st.have_time = true;
    if (zone) |z| {
        st.zone = z;
        st.have_zone = true;
    }
    return true;
}

fn parseZoneOff(s: []const u8) ?i32 {
    if (s.len == 0) return null;
    if (tzOf(s)) |z| return z;
    if (s[0] != '+' and s[0] != '-') return null;
    const sign: i32 = if (s[0] == '-') -1 else 1;
    const body = s[1..];
    var h: i64 = 0;
    var m: i64 = 0;
    if (std.mem.indexOfScalar(u8, body, ':')) |ci| {
        h = num(body[0..ci]) orelse return null;
        m = num(body[ci + 1 ..]) orelse return null;
    } else if (body.len <= 2) {
        h = num(body) orelse return null;
    } else if (body.len == 4 or body.len == 3) {
        h = num(body[0 .. body.len - 2]) orelse return null;
        m = num(body[body.len - 2 ..]) orelse return null;
    } else return null;
    if (h > 23 or m > 59) return null;
    return sign * @as(i32, @intCast(h * 3600 + m * 60));
}

fn parseDateTok(st: *State, tok: []const u8) bool {
    // YYYY-MM-DD, YYYY/MM/DD, MM/DD[/YYYY], D-Mon-YYYY
    const sep: u8 = if (std.mem.indexOfScalar(u8, tok, '-') != null) '-' else '/';
    var parts: [3][]const u8 = undefined;
    var np: usize = 0;
    var it = std.mem.splitScalar(u8, tok, sep);
    while (it.next()) |p| {
        if (np >= 3) return false;
        parts[np] = p;
        np += 1;
    }
    if (np < 2) return false;
    if (np == 3 and monthOf(parts[1]) != null and allDigits(parts[0]) and allDigits(parts[2])) {
        st.day = @intCast(num(parts[0]).?);
        st.mon = monthOf(parts[1]).?;
        st.year = fullYear(num(parts[2]).?, parts[2].len);
        st.have_date = true;
        return true;
    }
    const a = num(parts[0]) orelse return false;
    const b = num(parts[1]) orelse return false;
    if (parts[0].len >= 3 or (sep == '-' and np == 3)) {
        // year first
        if (b < 1 or b > 12) return false;
        st.year = fullYear(a, parts[0].len);
        st.mon = @intCast(b - 1);
        if (np == 3) {
            const d = num(parts[2]) orelse return false;
            if (d < 1 or d > 31) return false;
            st.day = @intCast(d);
        } else st.day = 1;
    } else {
        if (a < 1 or a > 12 or b < 1 or b > 31) return false;
        st.mon = @intCast(a - 1);
        st.day = @intCast(b);
        if (np == 3) st.year = fullYear(num(parts[2]) orelse return false, parts[2].len);
    }
    st.have_date = true;
    return true;
}

fn isTimeTok(tok: []const u8) bool {
    return std.mem.indexOfScalar(u8, tok, ':') != null and isDigit(tok[0]);
}

fn isDateTok(tok: []const u8) bool {
    if (tok.len == 0 or !isDigit(tok[0])) return false;
    if (std.mem.indexOfScalar(u8, tok, '/') != null) return true;
    if (std.mem.indexOfScalar(u8, tok, '-') != null) return true;
    return false;
}

fn lowerEq(w: []const u8, s: []const u8) bool {
    return eqi(w, s);
}

/// Parse a GNU `date -d` style string. `now` is the reference time.
pub fn parse(input: []const u8, now: Ts) ?Ts {
    var st = State{};
    // tokenize
    var toks = u.Vec([]const u8).init(u.alloc);
    {
        var it = std.mem.tokenizeAny(u8, input, " \t\n\r,");
        while (it.next()) |t| {
            // split ISO "DATEThh:mm"
            if (t.len > 11 and isDateTok(t)) {
                if (std.mem.indexOfScalar(u8, t, 'T')) |ti| {
                    if (ti > 0 and ti + 1 < t.len and isDigit(t[ti + 1])) {
                        toks.push(t[0..ti]);
                        toks.push(t[ti + 1 ..]);
                        continue;
                    }
                }
            }
            toks.push(t);
        }
    }
    const tk = toks.items;
    var ago = false;
    var i: usize = 0;
    while (i < tk.len) : (i += 1) {
        const t = tk[i];
        const nextTok: ?[]const u8 = if (i + 1 < tk.len) tk[i + 1] else null;
        if (t[0] == '@') {
            var ns: i64 = 0;
            var neg = false;
            var body = t[1..];
            if (body.len > 0 and body[0] == '-') {
                neg = true;
                body = body[1..];
            }
            const s = parseSec(body, &ns) orelse return null;
            st.epoch = if (neg) .{ .sec = -s - (if (ns > 0) @as(i64, 1) else 0), .nsec = if (ns > 0) 1_000_000_000 - ns else 0 } else .{ .sec = s, .nsec = ns };
            continue;
        }
        if (isTimeTok(t)) {
            if (st.have_time) return null;
            if (!parseTimeTok(&st, t)) return null;
            // separate am/pm token
            if (nextTok) |nt| {
                if ((eqi(nt, "am") or eqi(nt, "pm")) and st.hour >= 1 and st.hour <= 12) {
                    if (st.hour == 12) st.hour = 0;
                    if (eqi(nt, "pm")) st.hour += 12;
                    i += 1;
                }
            }
            continue;
        }
        if (isDateTok(t)) {
            if (st.have_date) return null;
            if (!parseDateTok(&st, t)) return null;
            continue;
        }
        if ((t[0] == '+' or t[0] == '-') and t.len == 1 and nextTok != null and allDigits(nextTok.?) and i + 2 < tk.len and unitOf(tk[i + 2]) != null) {
            const n = (num(nextTok.?) orelse return null) * (if (t[0] == '-') @as(i64, -1) else 1);
            addRel(&st, n, unitOf(tk[i + 2]).?);
            i += 2;
            continue;
        }
        if ((t[0] == '+' or t[0] == '-') and t.len > 1) {
            const isnum = allDigits(t[1..]);
            if (isnum and nextTok != null and unitOf(nextTok.?) != null) {
                const n = (num(t[1..]) orelse return null) * (if (t[0] == '-') @as(i64, -1) else 1);
                addRel(&st, n, unitOf(nextTok.?).?);
                i += 1;
                continue;
            }
            if (st.have_time and !st.have_zone) {
                if (parseZoneOff(t)) |z| {
                    st.zone = z;
                    st.have_zone = true;
                    continue;
                }
            }
            if (isnum) {
                // "+N" without unit: seconds? GNU rejects
                return null;
            }
            return null;
        }
        if (isDigit(t[0])) {
            // 10am / 10pm
            if (t.len > 2 and (eqi(t[t.len - 2 ..], "am") or eqi(t[t.len - 2 ..], "pm")) and allDigits(t[0 .. t.len - 2])) {
                if (st.have_time) return null;
                var h = num(t[0 .. t.len - 2]).?;
                if (h < 1 or h > 12) return null;
                if (h == 12) h = 0;
                if (eqi(t[t.len - 2 ..], "pm")) h += 12;
                st.hour = @intCast(h);
                st.min = 0;
                st.sec = 0;
                st.nsec = 0;
                st.have_time = true;
                continue;
            }
            // ordinal "1st", "2nd"
            var body = t;
            if (t.len > 2) {
                const suf = t[t.len - 2 ..];
                if (eqi(suf, "st") or eqi(suf, "nd") or eqi(suf, "rd") or eqi(suf, "th")) {
                    if (allDigits(t[0 .. t.len - 2])) body = t[0 .. t.len - 2];
                }
            }
            if (!allDigits(body)) return null;
            const n = num(body) orelse return null;
            if (nextTok) |nt| {
                if (unitOf(nt)) |un| {
                    addRel(&st, n, un);
                    i += 1;
                    continue;
                }
                if (eqi(nt, "am") or eqi(nt, "pm")) {
                    if (st.have_time or n < 1 or n > 12) return null;
                    var h = n;
                    if (h == 12) h = 0;
                    if (eqi(nt, "pm")) h += 12;
                    st.hour = @intCast(h);
                    st.min = 0;
                    st.sec = 0;
                    st.nsec = 0;
                    st.have_time = true;
                    i += 1;
                    continue;
                }
                if (monthOf(nt) != null and st.day == null and n >= 1 and n <= 31) {
                    st.day = @intCast(n);
                    continue;
                }
            }
            if (body.len == 8 and !st.have_date) {
                st.year = @divTrunc(n, 10000);
                st.mon = @intCast(@divTrunc(@mod(n, 10000), 100) - 1);
                st.day = @intCast(@mod(n, 100));
                st.have_date = true;
                continue;
            }
            if (st.mon != null and st.day == null and n >= 1 and n <= 31 and body.len <= 2) {
                st.day = @intCast(n);
                st.have_date = true;
                continue;
            }
            if (st.mon != null and st.year == null) {
                st.year = fullYear(n, body.len);
                st.have_date = true;
                continue;
            }
            if (body.len == 4 and !st.have_time and st.have_date and st.year != null) {
                // hhmm after date
                st.hour = @intCast(@divTrunc(n, 100));
                st.min = @intCast(@mod(n, 100));
                st.sec = 0;
                st.have_time = true;
                continue;
            }
            return null;
        }
        // words
        if (lowerEq(t, "now") or lowerEq(t, "today")) continue;
        if (lowerEq(t, "yesterday")) {
            addRel(&st, -1, .day);
            continue;
        }
        if (lowerEq(t, "tomorrow")) {
            addRel(&st, 1, .day);
            continue;
        }
        if (lowerEq(t, "midnight")) {
            st.hour = 0;
            st.min = 0;
            st.sec = 0;
            st.nsec = 0;
            st.have_time = true;
            continue;
        }
        if (lowerEq(t, "noon")) {
            st.hour = 12;
            st.min = 0;
            st.sec = 0;
            st.nsec = 0;
            st.have_time = true;
            continue;
        }
        if (lowerEq(t, "ago")) {
            ago = true;
            continue;
        }
        if (lowerEq(t, "next") or lowerEq(t, "last") or lowerEq(t, "this") or lowerEq(t, "previous")) {
            const n: i64 = if (lowerEq(t, "next")) 1 else if (lowerEq(t, "this")) 0 else -1;
            const nt = nextTok orelse return null;
            if (unitOf(nt)) |un| {
                addRel(&st, n, un);
            } else if (weekdayOf(nt)) |wd| {
                st.weekday = wd;
                st.weekday_n = if (n > 0) 1 else if (n == 0) 0 else -1;
            } else return null;
            i += 1;
            continue;
        }
        if (monthOf(t)) |m| {
            var tt = t;
            if (tt.len > 0 and tt[tt.len - 1] == '.') tt = tt[0 .. tt.len - 1];
            st.mon = m;
            st.have_date = true;
            continue;
        }
        if (weekdayOf(t)) |wd| {
            st.weekday = wd;
            st.weekday_n = 0;
            continue;
        }
        var wt = t;
        if (wt.len > 1 and wt[wt.len - 1] == '.') wt = wt[0 .. wt.len - 1];
        if (monthOf(wt)) |m| {
            st.mon = m;
            st.have_date = true;
            continue;
        }
        if (weekdayOf(wt)) |wd| {
            st.weekday = wd;
            st.weekday_n = 0;
            continue;
        }
        if (tzOf(t)) |z| {
            st.zone = z;
            st.have_zone = true;
            continue;
        }
        return null;
    }

    if (ago) {
        st.ry = -st.ry;
        st.rmon = -st.rmon;
        st.rday = -st.rday;
        st.rhour = -st.rhour;
        st.rmin = -st.rmin;
        st.rsec = -st.rsec;
    }
    if (st.epoch) |e| {
        return .{ .sec = e.sec + st.rday * 86400 + st.rhour * 3600 + st.rmin * 60 + st.rsec, .nsec = e.nsec };
    }

    var tm = localtime(now.sec);
    if (st.have_zone) {
        // interpret fields in the explicit zone: start from UTC fields shifted by the zone
        var t: c.time_t = @intCast(now.sec + st.zone);
        _ = c.gmtime_r(&t, &tm);
    }
    var nsec: i64 = now.nsec;
    if (st.have_date or st.have_time or input.len == 0 or st.weekday != null) {
        // date/time given: unspecified time-of-day parts reset to zero
        if (st.have_time) {
            tm.tm_hour = st.hour;
            tm.tm_min = st.min;
            tm.tm_sec = @intCast(st.sec);
            nsec = st.nsec;
        } else if (st.have_date or input.len == 0 or st.weekday != null) {
            tm.tm_hour = 0;
            tm.tm_min = 0;
            tm.tm_sec = 0;
            nsec = 0;
        }
    }
    if (st.year) |y| tm.tm_year = @intCast(y - 1900);
    if (st.mon) |m| {
        tm.tm_mon = m;
        if (st.day == null) tm.tm_mday = 1;
        if (st.year == null and st.day == null) {}
    }
    if (st.day) |d| tm.tm_mday = d;
    const want_day: ?c_int = if (st.have_date and !st.have_rel and st.day != null) st.day.? else null;
    const want_mon: ?c_int = if (st.have_date and !st.have_rel and st.mon != null) st.mon.? else null;
    tm.tm_year += @intCast(st.ry);
    tm.tm_mon += @intCast(st.rmon);
    tm.tm_mday += @intCast(st.rday);
    tm.tm_hour += @intCast(st.rhour);
    tm.tm_min += @intCast(st.rmin);
    tm.tm_sec += @intCast(st.rsec);
    tm.tm_isdst = -1;
    var res: i64 = undefined;
    if (st.have_zone) {
        res = @intCast(c.timegm(&tm));
        res -= st.zone;
    } else {
        res = @intCast(c.mktime(&tm));
    }
    if (want_day != null or want_mon != null) {
        var chk: c.struct_tm = undefined;
        var ct: c.time_t = @intCast(if (st.have_zone) res + st.zone else res);
        if (st.have_zone) _ = c.gmtime_r(&ct, &chk) else _ = c.localtime_r(&ct, &chk);
        if (want_day != null and chk.tm_mday != want_day.?) return null;
        if (want_mon != null and chk.tm_mon != want_mon.?) return null;
    }
    if (st.weekday) |wd| {
        // move to the requested weekday relative to the computed date
        var t: c.time_t = @intCast(res);
        var t2: c.struct_tm = undefined;
        if (st.have_zone) {
            t = @intCast(res + st.zone);
            _ = c.gmtime_r(&t, &t2);
        } else _ = c.localtime_r(&t, &t2);
        var delta: i64 = @mod(@as(i64, wd) - t2.tm_wday, 7);
        if (st.weekday_n > 0) {
            if (delta == 0) delta = 7;
        } else if (st.weekday_n < 0) {
            delta = delta - 7;
            if (delta == 0) delta = -7;
        }
        t2.tm_mday += @intCast(delta);
        t2.tm_isdst = -1;
        res = if (st.have_zone) @as(i64, @intCast(c.timegm(&t2))) - st.zone else @intCast(c.mktime(&t2));
    }
    return .{ .sec = res + 0, .nsec = nsec + st.rnsec };
}

/// touch -t [[CC]YY]MMDDhhmm[.ss]
pub fn parseStamp(s: []const u8) ?Ts {
    var body = s;
    var sec: i64 = 0;
    if (std.mem.indexOfScalar(u8, s, '.')) |di| {
        body = s[0..di];
        const sp = s[di + 1 ..];
        if (sp.len != 2) return null;
        sec = num(sp) orelse return null;
        if (sec > 61) return null;
    }
    if (!allDigits(body)) return null;
    var year: i64 = undefined;
    var rest: []const u8 = undefined;
    const now = localtime(u.nowSecs());
    switch (body.len) {
        8 => {
            year = now.tm_year + 1900;
            rest = body;
        },
        10 => {
            year = fullYear(num(body[0..2]).?, 2);
            rest = body[2..];
        },
        12 => {
            year = num(body[0..4]).?;
            rest = body[4..];
        },
        else => return null,
    }
    const mo = num(rest[0..2]).?;
    const d = num(rest[2..4]).?;
    const h = num(rest[4..6]).?;
    const mi = num(rest[6..8]).?;
    if (mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59) return null;
    var tm = std.mem.zeroes(c.struct_tm);
    tm.tm_year = @intCast(year - 1900);
    tm.tm_mon = @intCast(mo - 1);
    tm.tm_mday = @intCast(d);
    tm.tm_hour = @intCast(h);
    tm.tm_min = @intCast(mi);
    tm.tm_sec = @intCast(sec);
    tm.tm_isdst = -1;
    const r = c.mktime(&tm);
    // reject day overflow like "0231"
    if (tm.tm_mday != d) return null;
    return .{ .sec = @intCast(r) };
}

// ---------- formatting ----------
fn numericConv(ch: u8) bool {
    return switch (ch) {
        'C', 'd', 'e', 'g', 'G', 'H', 'I', 'j', 'k', 'l', 'm', 'M', 'S', 'u', 'U', 'V', 'w', 'W', 'y', 'Y', 's', 'N' => true,
        else => false,
    };
}

fn defaultPad(ch: u8) u8 {
    return switch (ch) {
        'e', 'k', 'l' => ' ',
        else => '0',
    };
}

/// GNU date's strftime: flags `- _ 0 ^ #`, width, `%N`, `%s`, `%:z`, `%::z`.
pub fn format(fmt: []const u8, ts: Ts, tm_in: *const c.struct_tm, out: *u.Vec(u8)) void {
    var tm = tm_in.*;
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%' or i + 1 >= fmt.len) {
            out.push(fmt[i]);
            i += 1;
            continue;
        }
        const start = i;
        i += 1;
        var pad: ?u8 = null; // explicit padding flag: '-', '_', '0'
        var upper = false;
        var swap = false;
        while (i < fmt.len) : (i += 1) {
            switch (fmt[i]) {
                '-', '_', '0' => pad = fmt[i],
                '^' => upper = true,
                '#' => swap = true,
                else => break,
            }
        }
        var width: usize = 0;
        var have_width = false;
        while (i < fmt.len and isDigit(fmt[i])) : (i += 1) {
            width = width * 10 + (fmt[i] - '0');
            have_width = true;
        }
        var colons: usize = 0;
        while (i < fmt.len and fmt[i] == ':') : (i += 1) colons += 1;
        if (i < fmt.len and (fmt[i] == 'E' or fmt[i] == 'O')) i += 1;
        if (i >= fmt.len) {
            for (fmt[start..]) |ch| out.push(ch);
            return;
        }
        const conv = fmt[i];
        i += 1;
        var tmp: [256]u8 = undefined;
        var piece: []const u8 = "";
        var numeric = numericConv(conv);
        switch (conv) {
            '%' => piece = "%",
            'n' => piece = "\n",
            't' => piece = "\t",
            's' => piece = std.fmt.bufPrint(&tmp, "{d}", .{ts.sec}) catch "",
            'P' => {
                const n = c.strftime(&tmp, tmp.len, "%p", &tm);
                for (tmp[0..n]) |*ch| ch.* = std.ascii.toLower(ch.*);
                piece = tmp[0..n];
            },
            'N' => {
                var tb: [64]u8 = undefined;
                const base = std.fmt.bufPrint(&tb, "{d:0>9}", .{@as(u64, @intCast(ts.nsec))}) catch "000000000";
                const w = if (have_width) width else 9;
                var k: usize = 0;
                while (k < w) : (k += 1) out.push(if (k < 9) base[k] else '0');
                continue;
            },
            'z' => {
                const off: i64 = tm.tm_gmtoff;
                const a: u64 = @intCast(if (off < 0) -off else off);
                const sign: u8 = if (off < 0) '-' else '+';
                const hh = a / 3600;
                const mm = (a % 3600) / 60;
                const ss = a % 60;
                piece = switch (colons) {
                    0 => std.fmt.bufPrint(&tmp, "{c}{d:0>2}{d:0>2}", .{ sign, hh, mm }) catch "",
                    1 => std.fmt.bufPrint(&tmp, "{c}{d:0>2}:{d:0>2}", .{ sign, hh, mm }) catch "",
                    2 => std.fmt.bufPrint(&tmp, "{c}{d:0>2}:{d:0>2}:{d:0>2}", .{ sign, hh, mm, ss }) catch "",
                    else => blk: {
                        if (ss != 0) break :blk std.fmt.bufPrint(&tmp, "{c}{d:0>2}:{d:0>2}:{d:0>2}", .{ sign, hh, mm, ss }) catch "";
                        if (mm != 0) break :blk std.fmt.bufPrint(&tmp, "{c}{d:0>2}:{d:0>2}", .{ sign, hh, mm }) catch "";
                        break :blk std.fmt.bufPrint(&tmp, "{c}{d:0>2}", .{ sign, hh }) catch "";
                    },
                };
                numeric = false;
            },
            else => {
                var spec: [3]u8 = .{ '%', conv, 0 };
                const n = c.strftime(&tmp, tmp.len, @ptrCast(&spec), &tm);
                piece = tmp[0..n];
                // %e/%k/%l are space padded by default, others zero padded
            },
        }
        // apply flags
        var buf2: [512]u8 = undefined;
        var s: []const u8 = piece;
        if (numeric and pad != null) {
            // strip default padding, then re-pad per flag
            var k: usize = 0;
            while (k + 1 < s.len and (s[k] == '0' or s[k] == ' ')) k += 1;
            const core = s[k..];
            switch (pad.?) {
                '-' => s = core,
                '_' => {
                    const w = s.len;
                    var m: usize = 0;
                    while (m + core.len < w) : (m += 1) buf2[m] = ' ';
                    @memcpy(buf2[m .. m + core.len], core);
                    s = buf2[0 .. m + core.len];
                },
                else => {
                    const w = s.len;
                    var m: usize = 0;
                    while (m + core.len < w) : (m += 1) buf2[m] = '0';
                    @memcpy(buf2[m .. m + core.len], core);
                    s = buf2[0 .. m + core.len];
                },
            }
        } else if (!numeric and pad != null and pad.? == '0') {
            // zero pad text conversions via width below
        }
        var buf3: [512]u8 = undefined;
        if (upper or swap) {
            const n = @min(s.len, buf3.len);
            for (s[0..n], 0..) |ch, k| buf3[k] = if (upper or (swap and conv != 'p')) std.ascii.toUpper(ch) else std.ascii.toLower(ch);
            s = buf3[0..n];
        }
        if (have_width and s.len < width and pad != null and pad.? == '-') {
            // '-' suppresses padding including explicit width
        } else if (have_width and s.len < width) {
            const padc: u8 = blk: {
                if (pad) |p| {
                    if (p == '_') break :blk ' ';
                    if (p == '0') break :blk '0';
                }
                if (numeric) break :blk defaultPad(conv);
                break :blk ' ';
            };
            var k: usize = s.len;
            while (k < width) : (k += 1) out.push(padc);
        }
        for (s) |ch| out.push(ch);
    }
}
