// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");
const input = @import("input.zig");
const re = @import("regex.zig");
const Address = union(enum) { none, line: usize, last, regex: *re.Regex, relative: usize };
const Command = struct {
    first: Address = .none,
    second: Address = .none,
    negate: bool = false,
    kind: u8,
    text: []const u8 = "",
    replacement: []const u8 = "",
    regex: ?*re.Regex = null,
    global: bool = false,
    print: bool = false,
    occurrence: usize = 0,
    active: bool = false,
    range_end: bool = false,
    range_start: usize = 0,
    jump: usize = 0,
    write_file: ?[]const u8 = null,
};
const Parser = struct {
    text: []const u8,
    pos: usize = 0,
    extended: bool,
    previous: ?*re.Regex = null,
    fn space(self: *Parser) void {
        while (self.pos < self.text.len and (self.text[self.pos] == ' ' or self.text[self.pos] == '\t')) self.pos += 1;
    }
    fn regex(self: *Parser, pattern: []const u8, insensitive: bool) !*re.Regex {
        if (pattern.len == 0) return self.previous orelse error.Syntax;
        const result = try u.alloc.create(re.Regex);
        result.* = re.Regex.init(pattern, self.extended, insensitive) orelse return error.Syntax;
        self.previous = result;
        return result;
    }
    fn number(self: *Parser) !usize {
        const start = self.pos;
        while (self.pos < self.text.len and std.ascii.isDigit(self.text[self.pos])) self.pos += 1;
        if (start == self.pos) return error.Syntax;
        return std.fmt.parseInt(usize, self.text[start..self.pos], 10);
    }
    fn delimited(self: *Parser, delimiter: u8, is_replacement: bool) ![]const u8 {
        var result = u.Vec(u8).init(u.alloc);
        while (self.pos < self.text.len) {
            const byte = self.text[self.pos];
            self.pos += 1;
            if (byte == delimiter) return result.items;
            if (byte == '\n') return error.Syntax;
            if (byte == '\\' and self.pos < self.text.len) {
                const next = self.text[self.pos];
                self.pos += 1;
                if (next == delimiter and (!is_replacement or next != '&')) result.push(next) else if (next == 'n') result.push('\n') else if (next == 't') result.push('\t') else {
                    result.push('\\');
                    result.push(next);
                }
            } else result.push(byte);
        }
        return error.Syntax;
    }
    fn address(self: *Parser) !Address {
        self.space();
        if (self.pos == self.text.len) return .none;
        const byte = self.text[self.pos];
        if (std.ascii.isDigit(byte)) return .{ .line = try self.number() };
        if (byte == '$') {
            self.pos += 1;
            return .last;
        }
        if (byte == '+') {
            self.pos += 1;
            return .{ .relative = try self.number() };
        }
        if (byte == '/') {
            self.pos += 1;
            return .{ .regex = try self.regex(try self.delimited('/', false), false) };
        }
        return .none;
    }
    fn rest(self: *Parser) []const u8 {
        self.space();
        const start = self.pos;
        while (self.pos < self.text.len and self.text[self.pos] != '\n' and self.text[self.pos] != ';' and self.text[self.pos] != '}') self.pos += 1;
        return std.mem.trimEnd(u8, self.text[start..self.pos], " \t");
    }
    fn textLine(self: *Parser) []const u8 {
        self.space();
        if (self.pos < self.text.len and self.text[self.pos] == '\\') self.pos += 1;
        if (self.pos < self.text.len and self.text[self.pos] == '\n') self.pos += 1;
        var result = u.Vec(u8).init(u.alloc);
        while (self.pos < self.text.len) {
            const byte = self.text[self.pos];
            self.pos += 1;
            if (byte == '\n') break;
            if (byte == '\\' and self.pos < self.text.len) {
                const next = self.text[self.pos];
                self.pos += 1;
                result.push(if (next == 'n' or next == '\n') '\n' else if (next == 't') '\t' else next);
            } else result.push(byte);
        }
        return result.items;
    }
    fn parse(self: *Parser) !u.Vec(Command) {
        var commands = u.Vec(Command).init(u.alloc);
        var braces = u.Vec(usize).init(u.alloc);
        while (self.pos < self.text.len) {
            self.space();
            if (self.pos == self.text.len) break;
            if (self.text[self.pos] == ';' or self.text[self.pos] == '\n') {
                self.pos += 1;
                continue;
            }
            if (self.text[self.pos] == '#') {
                while (self.pos < self.text.len and self.text[self.pos] != '\n') self.pos += 1;
                continue;
            }
            const first = try self.address();
            self.space();
            var second: Address = .none;
            if (self.pos < self.text.len and self.text[self.pos] == ',') {
                self.pos += 1;
                second = try self.address();
                if (second == .none) return error.Syntax;
            }
            self.space();
            var negate = false;
            if (self.pos < self.text.len and self.text[self.pos] == '!') {
                negate = true;
                self.pos += 1;
                self.space();
            }
            if (self.pos == self.text.len) return error.Syntax;
            const kind = self.text[self.pos];
            self.pos += 1;
            var command = Command{ .kind = kind, .first = first, .second = second, .negate = negate };
            switch (kind) {
                's' => {
                    if (self.pos == self.text.len) return error.Syntax;
                    const delimiter = self.text[self.pos];
                    self.pos += 1;
                    const pattern = try self.delimited(delimiter, false);
                    command.replacement = try self.delimited(delimiter, true);
                    var insensitive = false;
                    while (self.pos < self.text.len) {
                        const flag = self.text[self.pos];
                        if (flag == ';' or flag == '\n' or flag == '}') break;
                        if (std.ascii.isDigit(flag)) {
                            command.occurrence = try self.number();
                            continue;
                        }
                        self.pos += 1;
                        switch (flag) {
                            'g' => command.global = true,
                            'p' => command.print = true,
                            'i', 'I' => insensitive = true,
                            ' ', '\t' => {},
                            'w' => {
                                command.write_file = self.rest();
                                break;
                            },
                            else => return error.Syntax,
                        }
                    }
                    command.regex = try self.regex(pattern, insensitive);
                },
                'y' => {
                    if (self.pos == self.text.len) return error.Syntax;
                    const delimiter = self.text[self.pos];
                    self.pos += 1;
                    command.text = try self.delimited(delimiter, false);
                    command.replacement = try self.delimited(delimiter, false);
                    if (command.text.len != command.replacement.len) return error.Syntax;
                },
                'a', 'i', 'c' => command.text = self.textLine(),
                ':', 'b', 't', 'T', 'r', 'w' => command.text = self.rest(),
                'q', 'Q' => {
                    self.space();
                    if (self.pos < self.text.len and std.ascii.isDigit(self.text[self.pos])) command.occurrence = try self.number();
                },
                '{' => braces.push(commands.items.len),
                '}' => {
                    if (braces.items.len == 0) return error.Syntax;
                    const index = braces.items[braces.items.len - 1];
                    braces.pop();
                    commands.items[index].jump = commands.items.len + 1;
                },
                'd', 'D', 'p', 'P', 'n', 'N', 'h', 'H', 'g', 'G', 'x', '=', 'z', 'l' => {},
                else => return error.Syntax,
            }
            commands.push(command);
        }
        if (braces.items.len > 0) return error.Syntax;
        for (commands.items) |*command| if (command.kind == 'b' or command.kind == 't' or command.kind == 'T') {
            command.jump = commands.items.len;
            if (command.text.len > 0) {
                var found = false;
                for (commands.items, 0..) |label, index| if (label.kind == ':' and same(label.text, command.text)) {
                    command.jump = index + 1;
                    found = true;
                    break;
                };
                if (!found) return error.Syntax;
            }
        };
        return commands;
    }
};
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn append(buffer: *u.Vec(u8), text: []const u8) void {
    for (text) |byte| buffer.push(byte);
}
fn combine(a: []const u8, middle: []const u8, b: []const u8) []const u8 {
    var result = u.Vec(u8).init(u.alloc);
    append(&result, a);
    append(&result, middle);
    append(&result, b);
    return result.items;
}
fn addrMatch(address: Address, line: usize, last: bool, pattern: []const u8, start: usize) bool {
    return switch (address) {
        .none => true,
        .line => |n| line == n,
        .last => last,
        .regex => |regex| regex.find(pattern, 0) != null,
        .relative => |n| line >= start +| n,
    };
}
fn selected(command: *Command, line: usize, last: bool, pattern: []const u8) bool {
    command.range_end = false;
    var hit = false;
    if (command.second == .none) hit = addrMatch(command.first, line, last, pattern, 0) else {
        const was_active = command.active;
        if (!command.active and addrMatch(command.first, line, last, pattern, 0)) {
            command.active = true;
            command.range_start = line;
        }
        if (command.first == .line and command.first.line == 0 and line == 1) {
            command.active = true;
            command.range_start = 0;
        }
        hit = command.active;
        if (command.active and (was_active or command.second != .regex or command.range_start == 0)) {
            const end = switch (command.second) {
                .line => |n| line >= n,
                else => addrMatch(command.second, line, last, pattern, command.range_start),
            };
            if (end) {
                command.active = false;
                command.range_end = true;
            }
        }
        if (last) command.range_end = true;
    }
    return hit != command.negate;
}
fn replacement(buffer: *u.Vec(u8), template: []const u8, pattern: []const u8, match: re.Match) void {
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        if (template[i] == '&') append(buffer, pattern[match.start..match.end]) else if (template[i] == '\\' and i + 1 < template.len) {
            i += 1;
            const byte = template[i];
            if (byte >= '0' and byte <= '9') {
                if (match.groups[byte - '0']) |group| append(buffer, pattern[group.start..group.end]);
            } else buffer.push(byte);
        } else buffer.push(template[i]);
    }
}
fn substitute(command: Command, pattern: *[]const u8) bool {
    var result = u.Vec(u8).init(u.alloc);
    var offset: usize = 0;
    var copied: usize = 0;
    var number: usize = 0;
    var changed = false;
    var previous_end: ?usize = null;
    while (command.regex.?.find(pattern.*, offset)) |match| {
        // A zero-length match immediately after a nonempty match is ignored.
        if (!(match.start == match.end and previous_end != null and previous_end.? == match.start)) {
            number += 1;
            if (command.occurrence == 0 or number == command.occurrence or command.global and number >= command.occurrence) {
                append(&result, pattern.*[copied..match.start]);
                replacement(&result, command.replacement, pattern.*, match);
                copied = match.end;
                changed = true;
                if (!command.global) break;
            }
        }
        previous_end = match.end;
        if (match.end == pattern.len) break;
        offset = if (match.end > match.start) match.end else match.end + 1;
    }
    if (changed) {
        append(&result, pattern.*[copied..]);
        pattern.* = result.items;
    }
    return changed;
}
const Output = struct {
    bytes: u.Vec(u8),
    delimiter: u8,
    pending: bool = false,
    fn print(self: *Output, text: []const u8, terminated: bool) void {
        if (self.pending) self.bytes.push(self.delimiter);
        append(&self.bytes, text);
        if (terminated) self.bytes.push(self.delimiter);
        self.pending = !terminated;
    }
};
const WriteFile = struct { name: []const u8, file: u.File };
fn writeTo(files: *u.Vec(WriteFile), name: []const u8, text: []const u8, terminated: bool, delimiter: u8) bool {
    for (files.items) |entry| if (same(entry.name, name)) {
        if (!entry.file.write(text)) return false;
        if (terminated) {
            const d = [_]u8{delimiter};
            return entry.file.write(&d);
        }
        return true;
    };
    return false;
}
fn execute(commands: []Command, records: []const input.Record, quiet: bool, delimiter: u8, writers: *u.Vec(WriteFile), result: *Output) u8 {
    var hold: []const u8 = "";
    var index: usize = 0;
    for (commands) |*command| command.active = false;
    while (index < records.len) : (index += 1) {
        var pattern = records[index].text;
        var terminated = records[index].terminated;
        var pc: usize = 0;
        var deleted = false;
        var changed = false;
        var append_later = u.Vec(u8).init(u.alloc);
        while (pc < commands.len) {
            const command = &commands[pc];
            pc += 1;
            const hit = selected(command, index + 1, index + 1 == records.len, pattern);
            if (!hit) {
                if (command.kind == '{') pc = command.jump;
                continue;
            }
            switch (command.kind) {
                '{', '}', ':' => {},
                's' => {
                    if (substitute(command.*, &pattern)) {
                        changed = true;
                        if (command.print) result.print(pattern, terminated);
                        if (command.write_file) |name| if (!writeTo(writers, name, pattern, terminated, delimiter)) return 4;
                    }
                },
                'y' => {
                    const copy = u.alloc.dupe(u8, pattern) catch return 4;
                    for (copy) |*byte| {
                        if (std.mem.indexOfScalar(u8, command.text, byte.*)) |at| byte.* = command.replacement[at];
                    }
                    pattern = copy;
                },
                'p' => result.print(pattern, terminated),
                'P' => {
                    const at = std.mem.indexOfScalar(u8, pattern, delimiter);
                    result.print(pattern[0 .. at orelse pattern.len], at != null or terminated);
                },
                '=' => {
                    var buf: [32]u8 = undefined;
                    result.print(std.fmt.bufPrint(&buf, "{d}", .{index + 1}) catch return 4, true);
                },
                'd' => {
                    deleted = true;
                    break;
                },
                'D' => {
                    if (std.mem.indexOfScalar(u8, pattern, delimiter)) |at| {
                        pattern = pattern[at + 1 ..];
                        pc = 0;
                    } else {
                        deleted = true;
                        break;
                    }
                },
                'z' => pattern = "",
                'h' => hold = u.alloc.dupe(u8, pattern) catch return 4,
                'H' => {
                    const d = [_]u8{delimiter};
                    hold = combine(hold, &d, pattern);
                },
                'g' => pattern = hold,
                'G' => {
                    const d = [_]u8{delimiter};
                    pattern = combine(pattern, &d, hold);
                },
                'x' => {
                    const saved = hold;
                    hold = pattern;
                    pattern = saved;
                },
                'n' => {
                    if (!quiet) result.print(pattern, terminated);
                    append(&result.bytes, append_later.items);
                    append_later.items.len = 0;
                    index += 1;
                    if (index == records.len) return 0;
                    pattern = records[index].text;
                    terminated = records[index].terminated;
                    changed = false;
                },
                'N' => {
                    if (index + 1 == records.len) break;
                    index += 1;
                    const d = [_]u8{delimiter};
                    pattern = combine(pattern, &d, records[index].text);
                    terminated = records[index].terminated;
                    changed = false;
                },
                'a' => {
                    append(&append_later, command.text);
                    append_later.push(delimiter);
                },
                'i' => result.print(command.text, true),
                'c' => {
                    if (command.second == .none or command.range_end or command.negate) result.print(command.text, true);
                    deleted = true;
                    break;
                },
                'b' => pc = command.jump,
                't', 'T' => {
                    const jump = if (command.kind == 't') changed else !changed;
                    changed = false;
                    if (jump) pc = command.jump;
                },
                'r' => {
                    if (input.read(command.text, true)) |data| append(&append_later, data);
                },
                'w' => if (!writeTo(writers, command.text, pattern, terminated, delimiter)) return 4,
                'q', 'Q' => {
                    if (command.kind == 'q' and !quiet) result.print(pattern, terminated);
                    if (command.kind == 'q') append(&result.bytes, append_later.items);
                    return @intCast(@min(command.occurrence, 255));
                },
                'l' => {
                    for (pattern) |byte| {
                        switch (byte) {
                            '\t' => append(&result.bytes, "\\t"),
                            '\n' => append(&result.bytes, "\\n"),
                            '\r' => append(&result.bytes, "\\r"),
                            '\\' => append(&result.bytes, "\\\\"),
                            else => {
                                if (byte >= 32 and byte < 127) result.bytes.push(byte) else {
                                    var buf: [8]u8 = undefined;
                                    append(&result.bytes, std.fmt.bufPrint(&buf, "\\{o:0>3}", .{byte}) catch return 4);
                                }
                            },
                        }
                    }
                    result.print("$", true);
                },
                else => unreachable,
            }
        }
        if (!quiet and !deleted) result.print(pattern, terminated);
        append(&result.bytes, append_later.items);
    }
    return 0;
}
pub fn run(args: []const []const u8) u8 {
    var quiet = false;
    var extended = false;
    var separate = false;
    var delimiter: u8 = '\n';
    var inplace: ?[]const u8 = null;
    var script = u.Vec(u8).init(u.alloc);
    var explicit = false;
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
            if (same(arg, "--quiet") or same(arg, "--silent")) quiet = true else if (same(arg, "--regexp-extended")) extended = true else if (same(arg, "--separate")) separate = true else if (same(arg, "--null-data")) delimiter = 0 else if (same(arg, "--in-place")) inplace = "" else if (std.mem.startsWith(u8, arg, "--in-place=")) inplace = arg[11..] else return invalid(arg);
            continue;
        }
        if (options and arg.len > 1 and arg[0] == '-') {
            var k: usize = 1;
            while (k < arg.len) : (k += 1) switch (arg[k]) {
                'n' => quiet = true,
                'E', 'r' => extended = true,
                's' => separate = true,
                'z' => delimiter = 0,
                'u' => {},
                'i' => {
                    inplace = arg[k + 1 ..];
                    break;
                },
                'e', 'f' => |flag| {
                    const value = if (k + 1 < arg.len) arg[k + 1 ..] else blk: {
                        i += 1;
                        if (i == args.len) return invalid(arg);
                        break :blk args[i];
                    };
                    if (explicit) script.push('\n');
                    if (flag == 'e') append(&script, value) else append(&script, input.read(value, false) orelse return 2);
                    explicit = true;
                    break;
                },
                else => return invalid(arg),
            };
        } else if (!explicit) {
            append(&script, arg);
            explicit = true;
        } else files.push(arg);
    }
    if (!explicit) return invalid("missing script");
    if (std.mem.startsWith(u8, script.items, "#n")) quiet = true;
    var parser = Parser{ .text = script.items, .extended = extended };
    const commands = parser.parse() catch return invalid("invalid script");
    var writers = u.Vec(WriteFile).init(u.alloc);
    defer for (writers.items) |entry| entry.file.close();
    for (commands.items) |command| {
        const name = command.write_file orelse if (command.kind == 'w') command.text else continue;
        var exists = false;
        for (writers.items) |entry| if (same(entry.name, name)) {
            exists = true;
            break;
        };
        if (!exists) {
            const file = u.File.open(name, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666) orelse return 4;
            writers.push(.{ .name = name, .file = file });
        }
    }
    if (files.items.len == 0) {
        if (inplace != null) return invalid("in-place editing requires files");
        files.push("-");
    }
    var all = u.Vec(input.Record).init(u.alloc);
    var output = Output{ .bytes = u.Vec(u8).init(u.alloc), .delimiter = delimiter };
    var failed = false;
    var status: u8 = 0;
    for (files.items) |name| {
        const data = input.read(name, false) orelse {
            failed = true;
            continue;
        };
        const records = input.records(data, delimiter);
        if (inplace != null or separate) {
            output.bytes.items.len = 0;
            output.pending = false;
            status = execute(commands.items, records.items, quiet, delimiter, &writers, &output);
            if (inplace) |suffix| {
                if (!editFile(name, suffix, output.bytes.items)) return 4;
            } else u.out(output.bytes.items);
            if (status != 0) break;
        } else for (records.items) |record| all.push(record);
    }
    if (inplace == null and !separate) {
        status = execute(commands.items, all.items, quiet, delimiter, &writers, &output);
        u.out(output.bytes.items);
    }
    return if (failed) 2 else status;
}
fn invalid(arg: []const u8) u8 {
    u.errf("sed: {s}\n", .{arg});
    return 1;
}
fn editFile(name: []const u8, suffix: []const u8, bytes: []const u8) bool {
    if (same(name, "-")) return false;
    const st = u.stat(name, true) orelse return false;
    if (st.mode & linux.S.IFMT != linux.S.IFREG) return false;
    const temp = std.fmt.allocPrint(u.alloc, "{s}.cmdbox-{d}", .{ name, linux.getpid() }) catch return false;
    const file = u.File.open(temp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600) orelse return false;
    defer file.close();
    defer _ = linux.unlink(u.zstr(temp));
    if (!file.write(bytes)) return false;
    _ = linux.fchown(file.fd, st.uid, st.gid);
    _ = linux.fchmod(file.fd, st.mode & 0o7777);
    if (suffix.len > 0) {
        const backup = std.fmt.allocPrint(u.alloc, "{s}{s}", .{ name, suffix }) catch return false;
        if (!u.ok(linux.rename(u.zstr(name), u.zstr(backup)))) return false;
    }
    return u.ok(linux.rename(u.zstr(temp), u.zstr(name)));
}
