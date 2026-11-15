# Default RPM is the small, 32-bit static BusyBox replacement package.
ZIG ?= zig
RPM_ARCH ?= i686
RPM_TOPDIR ?= $(CURDIR)/rpmbuild
RPMBUILD_FLAGS ?=
TARGET ?= x86-linux-musl
CPU ?= pentiumpro

.PHONY: all build check rpm srpm source clean
all: build

build:
	$(ZIG) build -Dtarget=$(TARGET) -Dcpu=$(CPU)

check: build
	python3 tests/compat.py zig-out/bin/cmdbox
	python3 tests/gnu_compat.py zig-out/bin/cmdbox
	python3 tests/fs_compat.py zig-out/bin/cmdbox
	python3 tests/color_compat.py zig-out/bin/cmdbox
	python3 tests/temp_compat.py zig-out/bin/cmdbox
	python3 tests/package_layout.py
	python3 tests/extended_compat.py zig-out/bin/cmdbox
	python3 tests/compression_compat.py zig-out/bin/cmdbox

rpm:
	RPM_TOPDIR="$(RPM_TOPDIR)" ./package.sh --target "$(RPM_ARCH)" $(RPMBUILD_FLAGS)

srpm:
	RPM_TOPDIR="$(RPM_TOPDIR)" ./package.sh --srpm --target "$(RPM_ARCH)" $(RPMBUILD_FLAGS)

source:
	RPM_TOPDIR="$(RPM_TOPDIR)" ./package.sh --source-only

clean:
	$(RM) -r .zig-cache zig-out
