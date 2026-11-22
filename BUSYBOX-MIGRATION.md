# BusyBox package migration

Reference: busybox-1.22.1-b2.i686.
116 legacy command paths are supplied by cmdbox; 30 legacy commands are not implemented.

Obsoleting BusyBox removes the following commands unless another package supplies them.
This package does not advertise unimplemented DHCP capabilities.

- `/sbin/fdisk`
- `/sbin/findfs`
- `/sbin/fsck`
- `/sbin/fstrim`
- `/sbin/hdparm`
- `/sbin/mkdosfs`
- `/sbin/mke2fs`
- `/sbin/mkfs.ext2`
- `/sbin/mkfs.reiser`
- `/sbin/mkfs.vfat`
- `/sbin/udhcpc`
- `/usr/bin/chvt`
- `/usr/bin/dpkg`
- `/usr/bin/dumpleases`
- `/usr/bin/eject`
- `/usr/bin/fgconsole`
- `/usr/bin/ftpput`
- `/usr/bin/lspci`
- `/usr/bin/lsusb`
- `/usr/bin/passwd`
- `/usr/bin/telnet`
- `/usr/bin/traceroute`
- `/usr/bin/whois`
- `/usr/sbin/arping`
- `/usr/sbin/chpasswd`
- `/usr/sbin/crond`
- `/usr/sbin/dhcprelay`
- `/usr/sbin/ntpd`
- `/usr/sbin/rdate`
- `/usr/sbin/udhcpd`
