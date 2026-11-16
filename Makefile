# Default RPM matches the host architecture. A 32-bit binary on a 64-bit host
# is killed with SIGSYS inside systemd units that set
# SystemCallArchitectures=native (udev, logind, ...), so i686 must be opt-in:
#   make rpm RPM_ARCH=i686
# rpmbuild's %install creates symlinks, which exFAT/FAT mounts cannot store.
# Keep the build area on a POSIX filesystem (/tmp) by default; override with
#   make rpm RPM_TOPDIR=...
ZIG ?= zig
HOST_ARCH := $(shell rpm --eval '%{_target_cpu}' 2>/dev/null || uname -m)
RPM_ARCH ?= $(HOST_ARCH)
RPM_TOPDIR ?= /tmp/cmdbox-rpmbuild
RPMBUILD_FLAGS ?=
ZIG_TARGET_i386 := x86-linux-musl
ZIG_TARGET_i486 := x86-linux-musl
ZIG_TARGET_i586 := x86-linux-musl
ZIG_TARGET_i686 := x86-linux-musl
ZIG_TARGET_x86_64 := x86_64-linux-musl
ZIG_TARGET_aarch64 := aarch64-linux-musl
ZIG_TARGET_armv7hl := arm-linux-musleabihf
ZIG_TARGET_armv7hnl := arm-linux-musleabihf
ZIG_CPU_i386 := i386
ZIG_CPU_i486 := i486
ZIG_CPU_i586 := pentium
ZIG_CPU_i686 := pentiumpro
TARGET ?= $(or $(ZIG_TARGET_$(RPM_ARCH)),$(error No Zig target for RPM_ARCH=$(RPM_ARCH); set TARGET))
CPU ?= $(or $(ZIG_CPU_$(RPM_ARCH)),baseline)

.PHONY: all build check rpm srpm source clean
all: build

build:
	$(ZIG) build -Dtarget=$(TARGET) -Dcpu=$(CPU)

check: build
	python3 tests/compat.py zig-out/bin/cmdbox
	python3 tests/uniq_cut_compat.py zig-out/bin/cmdbox
	python3 tests/gnu_compat.py zig-out/bin/cmdbox
	python3 tests/fs_compat.py zig-out/bin/cmdbox
	python3 tests/chmod_compat.py zig-out/bin/cmdbox
	python3 tests/color_compat.py zig-out/bin/cmdbox
	python3 tests/temp_compat.py zig-out/bin/cmdbox
	python3 tests/package_layout.py
	python3 tests/extended_compat.py zig-out/bin/cmdbox
	python3 tests/compression_compat.py zig-out/bin/cmdbox
	python3 tests/wget_compat.py zig-out/bin/cmdbox

rpm:
	RPM_TOPDIR="$(RPM_TOPDIR)" ./package.sh --target "$(RPM_ARCH)" $(RPMBUILD_FLAGS)

srpm:
	RPM_TOPDIR="$(RPM_TOPDIR)" ./package.sh --srpm --target "$(RPM_ARCH)" $(RPMBUILD_FLAGS)

source:
	RPM_TOPDIR="$(RPM_TOPDIR)" ./package.sh --source-only

clean:
	$(RM) -r .zig-cache zig-out
