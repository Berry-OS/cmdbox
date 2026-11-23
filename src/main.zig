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
    a("expr", @import("misc.zig").expr),
    a("timeout", @import("misc.zig").timeout),
    a("printenv", @import("misc.zig").printenv),
    a("nproc", @import("misc.zig").nproc),
    a("tty", @import("misc.zig").tty),
    a("arch", @import("misc.zig").arch),
    a("truncate", @import("misc.zig").truncate),
    a("link", @import("misc.zig").link),
    a("unlink", @import("misc.zig").unlink),
    a("uptime", @import("misc.zig").uptime),
    a("pidof", @import("misc.zig").pidof),
    a("pgrep", @import("misc.zig").pgrep),
    a("pkill", @import("misc.zig").pkill),
    a("find", @import("find.zig").find),
    a("xargs", @import("find.zig").xargs),
    a("stat", @import("fileutil.zig").stat),
    a("du", @import("fileutil.zig").du),
    a("dd", @import("fileutil.zig").dd),
    a("split", @import("fileutil.zig").split),
    a("install", @import("fileutil.zig").install),
    a("od", @import("od.zig").run),
    a("renice", @import("sysutil.zig").renice),
    a("time", @import("sysutil.zig").time),
    a("dmesg", @import("dmesg.zig").dmesg),
    a("reset", @import("sysutil.zig").reset),
    a("logger", @import("sysutil.zig").logger),
    a("sysctl", @import("sysutil.zig").sysctl),
    a("chroot", @import("sysutil.zig").chroot),
    a("pivot_root", @import("sysutil.zig").pivot_root),
    a("lsmod", @import("sysutil.zig").lsmod),
    a("insmod", @import("sysutil.zig").insmod),
    a("rmmod", @import("sysutil.zig").rmmod),
    a("swapon", @import("sysutil.zig").swapon),
    a("chvt", @import("sysutil2.zig").chvt),
    a("fgconsole", @import("sysutil2.zig").fgconsole),
    a("fstrim", @import("sysutil2.zig").fstrim),
    a("eject", @import("sysutil2.zig").eject),
    a("findfs", @import("sysutil2.zig").findfs),
    a("fsck", @import("sysutil2.zig").fsck),
    a("lspci", @import("pci.zig").lspci),
    a("lsusb", @import("pci.zig").lsusb),
    a("passwd", @import("passwd.zig").passwd),
    a("chpasswd", @import("passwd.zig").chpasswd),
    a("arping", @import("nettools3.zig").arping),
    a("rdate", @import("nettools3.zig").rdate),
    a("whois", @import("nettools3.zig").whois),
    a("telnet", @import("nettools3.zig").telnet),
    a("traceroute", @import("nettools3.zig").traceroute),
    a("ftpput", @import("nettools3.zig").ftpput),
    a("ntpd", @import("nettools3.zig").ntpd),
    a("crond", @import("crond.zig").crond),
    a("fdisk", @import("fdisk.zig").fdisk),
    a("dpkg", @import("dpkg.zig").dpkg),
    a("hdparm", @import("hdparm.zig").hdparm),
    a("mkfs.vfat", @import("mkfs.zig").mkfsVfat),
    a("mkfs.fat", @import("mkfs.zig").mkfsVfat),
    a("mkfs.msdos", @import("mkfs.zig").mkfsVfat),
    a("mkdosfs", @import("mkfs.zig").mkfsVfat),
    a("mke2fs", @import("mkfs.zig").mke2fs),
    a("mkfs.ext2", @import("mkfs.zig").mke2fs),
    a("mkfs.reiser", @import("mkfs.zig").mkfsReiser),
    a("udhcpc", @import("dhcp.zig").udhcpc),
    a("udhcpd", @import("dhcp.zig").udhcpd),
    a("dumpleases", @import("dhcp.zig").dumpleases),
    a("dhcprelay", @import("dhcp.zig").dhcprelay),
    a("swapoff", @import("sysutil.zig").swapoff),
    a("mkswap", @import("sysutil.zig").mkswap),
    a("dnsdomainname", @import("sysutil.zig").dnsdomainname),
    a("killall5", @import("sysutil.zig").killall5),
    a("add-shell", @import("sysutil.zig").add_shell),
    a("remove-shell", @import("sysutil.zig").remove_shell),
    a("fuser", @import("fuser.zig").run),
    a("less", @import("pager.zig").less),
    a("more", @import("pager.zig").more),
    a("lsattr", @import("attr.zig").lsattr),
    a("chattr", @import("attr.zig").chattr),
    a("losetup", @import("losetup.zig").run),
    a("pstree", @import("pstree.zig").run),
    a("top", @import("top.zig").run),
    a("xz", @import("xz.zig").xz),
    a("unxz", @import("xz.zig").unxz),
    a("xzcat", @import("xz.zig").xzcat),
    a("lzma", @import("xz.zig").lzma),
    a("unlzma", @import("xz.zig").unlzma),
    a("lzcat", @import("xz.zig").lzcat),
    a("bzip2", @import("bzip2.zig").bzip2),
    a("bunzip2", @import("bzip2.zig").bunzip2),
    a("bzcat", @import("bzip2.zig").bzcat),
    a("cpio", @import("cpio.zig").run),
    a("rpm2cpio", @import("rpm2cpio.zig").run),
    a("modinfo", @import("modinfo.zig").run),
    a("switch_root", @import("switch_root.zig").run),
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
    a("mount", @import("mount.zig").mount),
    a("umount", @import("mount.zig").umount),
    a("reboot", @import("power.zig").reboot),
    a("poweroff", @import("power.zig").poweroff),
    a("halt", @import("power.zig").halt),
    a("test", core.testApp),
    a("[", @import("test.zig").bracket),
    a("[[", @import("test.zig").doubleBracket),
    // network
    a("ping", @import("nettools2.zig").ping),
    a("wget", net.wget),
    a("nslookup", @import("nettools2.zig").nslookup),
    a("ifconfig", @import("nettools.zig").ifconfig),
    a("netstat", @import("nettools.zig").netstat),
    a("route", @import("nettools.zig").route),
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
