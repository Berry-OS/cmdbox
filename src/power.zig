// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
// SPDX-License-Identifier: MPL-2.0

// halt / poweroff / reboot - systemd-style command line. Without --force the request goes to the init system
// (systemctl when systemd runs, otherwise a signal to PID 1); --force syncs and calls reboot(2) directly.
const std = @import("std");
const linux = std.os.linux;
const u = @import("util.zig");

const Action = enum { halt, poweroff, reboot };

const usage_fmt = "{s} [OPTIONS...]\n\n{s} the system.\n\nOptions:\n     --help      Show this help\n     --halt      Halt the machine\n  -p --poweroff  Switch off the machine\n     --reboot    Reboot the machine\n  -f --force     Force immediate halt/power-off/reboot\n  -w --wtmp-only Don't halt/power-off/reboot, just write wtmp record\n  -d --no-wtmp   Don't write wtmp record\n  -n --no-sync   Don't sync before halt/power-off/reboot\n     --no-wall   Don't send wall message before halt/power-off/reboot\n\nSee the {s}(8) man page for details.\n";

fn run(args: []const []const u8, default: Action, prog: []const u8) u8 {
    var action = default;
    var force: u32 = 0;
    var wtmp_only = false;
    var no_sync = false;
    var no_wall = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            const verb: []const u8 = switch (default) {
                .halt => "Halt",
                .poweroff => "Power off",
                .reboot => "Reboot",
            };
            u.outf(usage_fmt, .{ prog, verb, prog });
            return 0;
        }
        if (std.mem.eql(u8, a, "--halt")) action = .halt else if (std.mem.eql(u8, a, "--poweroff")) action = .poweroff else if (std.mem.eql(u8, a, "--reboot")) action = .reboot else if (std.mem.eql(u8, a, "--force")) force += 1 else if (std.mem.eql(u8, a, "--wtmp-only")) wtmp_only = true else if (std.mem.eql(u8, a, "--no-wtmp")) {} else if (std.mem.eql(u8, a, "--no-sync")) no_sync = true else if (std.mem.eql(u8, a, "--no-wall")) no_wall = true else if (a.len > 1 and a[0] == '-' and a[1] != '-') {
            for (a[1..]) |ch| switch (ch) {
                'p' => action = .poweroff,
                'f' => force += 1,
                'w' => wtmp_only = true,
                'd' => {},
                'n' => no_sync = true,
                'i', 'h' => {},
                else => {
                    u.errf("{s}: invalid option -- '{c}'\n", .{ prog, ch });
                    return 1;
                },
            };
        } else {
            u.errf("{s}: unrecognized option '{s}'\n", .{ prog, a });
            return 1;
        }
    }
    if (wtmp_only) return 0;
    const verb: []const u8 = switch (action) {
        .halt => "halt",
        .poweroff => "poweroff",
        .reboot => "reboot",
    };
    if (force == 0) {
        if (u.stat("/run/systemd/system", true) != null) {
            var pb: [u.PATH_MAX]u8 = undefined;
            if (u.findInPath("systemctl", &pb)) |path| {
                var av = u.Vec(?[*:0]const u8).init(u.alloc);
                av.push("systemctl");
                av.push(u.zstr(verb).ptr);
                if (no_wall) av.push("--no-wall");
                av.push(null);
                _ = linux.execve(path.ptr, @ptrCast(av.items.ptr), u.envp(&.{}));
            }
        }
        // classic init: SIGUSR1 halt, SIGUSR2 power off, SIGTERM reboot (busybox init)
        const sig: u32 = switch (action) {
            .halt => 10,
            .poweroff => 12,
            .reboot => 15,
        };
        const rc = linux.kill(1, @enumFromInt(sig));
        if (!u.ok(rc)) {
            u.errf("{s}: {s}\n", .{ prog, u.strerr(u.errno(rc)) });
            return 1;
        }
        return 0;
    }
    if (!no_sync) _ = linux.syscall0(.sync);
    const cmd: usize = switch (action) {
        .halt => 0xcdef0123,
        .poweroff => 0x4321fedc,
        .reboot => 0x01234567,
    };
    const rc = linux.syscall4(.reboot, 0xfee1dead, 0x28121969, cmd, 0);
    if (!u.ok(rc)) {
        u.errf("{s}: Failed to {s}: {s}\n", .{ prog, verb, u.strerr(u.errno(rc)) });
        return 1;
    }
    return 0;
}

pub fn halt(args: []const []const u8) u8 {
    return run(args, .halt, "halt");
}
pub fn poweroff(args: []const []const u8) u8 {
    return run(args, .poweroff, "poweroff");
}
pub fn reboot(args: []const []const u8) u8 {
    return run(args, .reboot, "reboot");
}
