// Copyright © 2026 Yuichiro Nakada / Project Berry Linux
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// main.zig - cmdbox: multi-call binary (busybox replacement)
const std = @import("std");
const locale = @cImport({
    @cInclude("locale.h");
});
const util = @import("util.zig");
const core = @import("core.zig");
const text = @import("text.zig");
const net = @import("net.zig");
const shell = @import("sh.zig");

const Applet = struct {
    name: []const u8,
    run: *const fn (args: []const []const u8) u8,
};

fn a(name: []const u8, run: *const fn (args: []const []const u8) u8) Applet {
    return .{ .name = name, .run = run };
}

pub const applets = [_]Applet{
    // core file / dir
    a("cat", core.cat),
    a("base64", @import("base64.zig").run),
    a("gzip", @import("gzip.zig").gzip),
    a("gunzip", @import("gzip.zig").gunzip),
    a("zcat", @import("gzip.zig").zcat),
    a("ls", core.ls),
    a("cp", @import("cpmv.zig").cp),
    a("mv", @import("cpmv.zig").mv),
    a("rm", @import("rmops.zig").rm),
    a("mkdir", @import("rmops.zig").mkdir),
    a("rmdir", @import("rmops.zig").rmdir),
    a("touch", @import("touch.zig").run),
    a("ln", @import("cpmv.zig").ln),
    a("chmod", core.chmod),
    a("chown", @import("ownership.zig").chown),
    a("chgrp", @import("ownership.zig").chgrp),
    a("mkfifo", @import("basic.zig").mkfifo),
    a("mktemp", @import("mktemp.zig").run),
    a("mknod", @import("basic.zig").mknod),
    a("basename", core.basenameApp),
    a("dirname", @import("basic.zig").dirname),
    a("readlink", @import("paths.zig").readlink),
    a("realpath", @import("paths.zig").realpath),
    a("pwd", @import("basic.zig").pwd),
    a("which", @import("basic.zig").which),
    a("clear", @import("basic.zig").clear),
    // text
    a("wc", text.wc),
    a("cut", @import("cut.zig").run),
    a("head", text.head),
    a("tail", text.tail),
    a("grep", text.grep),
    a("sed", text.sed),
    a("awk", @import("awk.zig").run),
    a("tr", text.tr),
    a("sort", text.sort),
    a("uniq", text.uniq),
    a("tac", @import("textmisc.zig").tac),
    a("rev", @import("textmisc.zig").rev),
    a("nl", @import("textmisc.zig").nl),
    a("fold", @import("textmisc.zig").fold),
    a("paste", @import("textmisc.zig").paste),
    a("comm", @import("textmisc.zig").comm),
    a("expand", @import("textmisc.zig").expand),
    a("unexpand", @import("textmisc.zig").unexpand),
    a("hexdump", @import("hexdump.zig").run),
    a("tee", @import("basic.zig").tee),
    a("cmp", text.cmp),
    a("diff", text.diff),
    a("cksum", @import("cksum.zig").run),
    a("md5sum", @import("checksum.zig").md5),
    a("sha1sum", @import("checksum.zig").sha1),
    a("sha256sum", @import("checksum.zig").sha256),
    // process / sys
    a("echo", core.echo),
    a("printf", @import("printf.zig").run),
    a("true", @import("basic.zig").trueApp),
    a("false", @import("basic.zig").falseApp),
    a("env", @import("basic.zig").env),
    a("sleep", core.sleep),
    a("seq", core.seq),
    a("yes", @import("basic.zig").yes),
    a("sync", @import("basic.zig").sync),
    a("hostname", @import("sysinfo.zig").hostname),
    a("uname", @import("sysinfo.zig").uname),
    a("date", @import("date.zig").run),
    a("id", @import("sysinfo.zig").id),
    a("whoami", @import("process.zig").whoami),
    a("groups", @import("process.zig").groups),
    a("pwdx", @import("process.zig").pwdx),
    a("nice", @import("basic.zig").nice),
    a("usleep", @import("process.zig").usleep),
    a("kill", @import("kill.zig").run),
    a("killall", @import("killall.zig").run),
    a("ps", @import("ps.zig").run),
    a("free", @import("free.zig").run),
    a("df", @import("df.zig").run),
    a("mount", core.mount),
    a("umount", core.umount),
    a("reboot", core.reboot),
    a("poweroff", core.poweroff),
    a("halt", core.halt),
    a("test", core.testApp),
    a("[", @import("test.zig").bracket),
    a("[[", @import("test.zig").doubleBracket),
    // network
    a("ping", net.ping),
    a("wget", net.wget),
    a("nslookup", net.nslookup),
    a("ifconfig", net.ifconfig),
    a("netstat", net.netstat),
    a("route", net.route),
    // shell
    a("sh", shell.runApplet),
    a("ash", shell.runApplet),
    a("vi", @import("vi.zig").run),
    a("help", core.help),
};

pub fn findApplet(name: []const u8) ?*const fn (args: []const []const u8) u8 {
    for (&applets) |*ap| {
        if (std.mem.eql(u8, ap.name, name)) return ap.run;
    }
    return null;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    util.raw_argv = init.args.vector;
    util.raw_env = init.environ.block.slice;
    _ = locale.setlocale(locale.LC_ALL, "");
    const argv = util.raw_argv;
    const self_name = util.basename(std.mem.sliceTo(argv[0], 0));

    if (std.mem.startsWith(u8, self_name, "cmdbox") or std.mem.eql(u8, self_name, "busybox")) {
        if (argv.len < 2) return usage();
        const a1 = std.mem.sliceTo(argv[1], 0);
        if (std.mem.eql(u8, a1, "--version")) {
            util.out("cmdbox 0.3.0\n");
            return 0;
        }
        if (std.mem.eql(u8, a1, "--list") or std.mem.eql(u8, a1, "-l")) {
            listApplets();
            return 0;
        }
        if (std.mem.eql(u8, a1, "--help") or std.mem.eql(u8, a1, "-h") or std.mem.eql(u8, a1, "help")) {
            return usage();
        }
        const run = findApplet(a1) orelse {
            // invoked as a script interpreter (argv[0] is the binary itself):
            // "#!/path/to/cmdbox" gives us argv = [cmdbox, script, args...]
            if (isScript(a1)) return shell.runApplet(sliceArgs(argv[1..]));
            util.errf("cmdbox: applet not found: {s}\n", .{a1});
            return 127;
        };
        util.setProcName(a1);
        util.applet_name = a1;
        return run(sliceArgs(argv[2..]));
    }

    // invoked via symlink / argv[0]
    if (std.mem.eql(u8, self_name, "sh") or std.mem.eql(u8, self_name, "ash")) {
        return shell.runApplet(sliceArgs(argv[1..]));
    }
    if (findApplet(self_name)) |run| {
        util.applet_name = self_name;
        return run(sliceArgs(argv[1..]));
    }
    util.errf("{s}: applet not found\n", .{self_name});
    return 127;
}

fn sliceArgs(argv: []const [*:0]const u8) []const []const u8 {
    var args = util.Vec([]const u8).init(util.alloc);
    for (argv) |p| args.push(std.mem.sliceTo(p, 0));
    return args.items;
}

// does the file exist and start with "#!"?
fn isScript(path: []const u8) bool {
    var f = util.File.open(path, .{ .ACCMODE = .RDONLY }, 0) orelse return false;
    defer f.close();
    var hdr: [2]u8 = undefined;
    return f.read(&hdr) == 2 and std.mem.eql(u8, &hdr, "#!");
}

fn listApplets() void {
    for (&applets, 0..) |*ap, i| {
        if (i > 0) util.out(" ");
        util.out(ap.name);
    }
    util.out("\n");
}


pub fn usage() u8 {
    util.out(
        "\n" ++
        "  \x1b[1;35mcmdbox\x1b[0m  \x1b[2m/ BERRY LINUX\x1b[0m\n" ++
        "  \x1b[2mOne binary. Essential Unix commands.\x1b[0m\n" ++
        "  \x1b[35m──────────────────────────────────────────────\x1b[0m\n" ++
        "\n" ++
        "  \x1b[1;36mUSAGE\x1b[0m\n" ++
        "    cmdbox \x1b[1m<applet>\x1b[0m [arguments...]\n" ++
        "    cmdbox \x1b[1m--list\x1b[0m\n" ++
        "    \x1b[1m<applet>\x1b[0m [arguments...]\n" ++
        "\n" ++
        "  \x1b[1;36mAVAILABLE APPLETS\x1b[0m\n" ++
        "\n"
    );

    listApplets();

    util.out(
        "\n" ++
        "  \x1b[35m──────────────────────────────────────────────\x1b[0m\n" ++
        "  \x1b[2mCopyright © 2026 Yuichiro Nakada / Project Berry Linux\x1b[0m\n" ++
        "\n"
    );

    return 0;
}
