# Native RPM architecture selects the Zig target. Use --target i686 for ELF32.
%global debug_package %{nil}
%global _binary_payload w9.bzdio
%global _source_payload w9.bzdio
%global __strip /bin/true
%global _build_id_links none
%global zig_cpu baseline
%ifarch i386
%global zig_cpu i386
%endif
%ifarch i486
%global zig_cpu i486
%endif
%ifarch i586
%global zig_cpu pentium
%endif
%ifarch i686
%global zig_cpu pentiumpro
%endif
%ifarch i386 i486 i586 i686
%global zig_target x86-linux-musl
%else
%ifarch x86_64
%global zig_target x86_64-linux-musl
%else
%ifarch aarch64
%global zig_target aarch64-linux-musl
%else
%ifarch armv7hl armv7hnl
%global zig_target arm-linux-musleabihf
%else
%{error:Unsupported RPM architecture; add an explicit Zig target mapping}
%endif
%endif
%endif
%endif

Name: cmdbox
Version: 0.3.0
Release: b3
Summary: Small static Zig multi-call Unix utilities
License: MPL-2.0 AND MIT
Source0: %{name}-%{version}.tar.bz2
BuildRequires: zig >= 0.16.0
BuildRequires: zig < 0.17.0
BuildRequires: python3
BuildRequires: binutils
BuildRequires: coreutils
BuildRequires: grep
BuildRequires: sed
BuildRequires: diffutils
BuildRequires: bash
BuildRequires: bzip2
BuildRequires: gzip
Requires: filesystem
Provides: busybox = %{version}-%{release}
Provides: wget
Obsoletes: busybox < 2.0
# No blanket Provides for utilities whose full interfaces are not implemented.

%description
A statically linked multi-call executable written in Zig, using musl for
POSIX regular expressions, locale handling and memory allocation.
Run cmdbox APPLET or busybox APPLET. Supported legacy applet paths are
installed in /bin, /sbin, /usr/bin and /usr/sbin, matching the replaced RPM.
All applets are also available in /usr/libexec/cmdbox.
Compatibility is tested against GNU coreutils, grep, sed, diffutils and sh.
See COMPATIBILITY.md for implemented interfaces and remaining differences.
This package replaces BusyBox. BUSYBOX-MIGRATION.md lists legacy commands
that are not yet implemented. HTTPS downloads use the system CA bundle.

%prep
%setup -q

%build
export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache"
zig build -Dtarget=%{zig_target} -Dcpu=%{zig_cpu} -Doptimize=ReleaseSmall -Dstrip=true --prefix "$PWD/rpm-out" -j%{_smp_build_ncpus}
# Generate layout from source rather than executing a cross-built binary.
python3 packaging/layout.py --applets > applets.list
python3 packaging/layout.py > applets.layout
python3 packaging/layout.py --report > BUSYBOX-MIGRATION.md

%install
install -Dpm755 rpm-out/bin/cmdbox %{buildroot}%{_bindir}/cmdbox
mkdir -p %{buildroot}/bin %{buildroot}/sbin %{buildroot}/usr/bin %{buildroot}/usr/sbin
# One executable. The legacy entry point dispatches applets too.
ln -s %{_bindir}/cmdbox %{buildroot}/bin/busybox
printf '/bin/busybox\n' > rpm-files.list
while read -r path applet; do
    case "$path" in
        /bin/*) target=busybox ;;
        /sbin/*) target=../bin/busybox ;;
        /usr/bin/*|/usr/sbin/*) target=../../bin/busybox ;;
        *) echo "Invalid applet path: $path" >&2; exit 1 ;;
    esac
    ln -s "$target" "%{buildroot}$path"
    printf '%%s\n' "$path" >> rpm-files.list
done < applets.layout
mkdir -p %{buildroot}%{_libexecdir}/cmdbox
while IFS= read -r applet; do
    ln -s ../../bin/cmdbox "%{buildroot}%{_libexecdir}/cmdbox/$applet"
done < applets.list

%check
# ELF structure checks work for every target, even without target emulation.
readelf -h rpm-out/bin/cmdbox
if readelf -l rpm-out/bin/cmdbox | grep -q INTERP; then
    echo 'Unexpected ELF interpreter' >&2
    exit 1
fi
if readelf -d rpm-out/bin/cmdbox | grep -q NEEDED; then
    echo 'Unexpected shared library dependency' >&2
    exit 1
fi
%ifarch i386 i486 i586 i686 x86_64
python3 tests/compat.py rpm-out/bin/cmdbox
python3 tests/gnu_compat.py rpm-out/bin/cmdbox
python3 tests/fs_compat.py rpm-out/bin/cmdbox
python3 tests/chmod_compat.py rpm-out/bin/cmdbox
python3 tests/color_compat.py rpm-out/bin/cmdbox
python3 tests/temp_compat.py rpm-out/bin/cmdbox
python3 tests/package_layout.py
python3 tests/extended_compat.py rpm-out/bin/cmdbox
python3 tests/compression_compat.py rpm-out/bin/cmdbox
python3 tests/wget_compat.py rpm-out/bin/cmdbox
%endif

%files -f rpm-files.list
%license LICENSE LICENSE.musl LICENSE.Zig
%doc README.md README-ja.md assets COMPATIBILITY.md BUSYBOX-MIGRATION.md
%{_bindir}/cmdbox
%{_libexecdir}/cmdbox/


%changelog
* Mon Nov 16 2026 Yuichiro Nakada <berry@berry-lab.net> - 0.3.0-b3
- Build for the host architecture by default; ELF32 on x86_64 is killed by
  SystemCallArchitectures=native in systemd units.

* Mon Nov 16 2026 Yuichiro Nakada <berry@berry-lab.net> - 0.3.0-b2
- Accept combined chmod -Rf options used by RPM setup and cleanup.

* Sun Nov 15 2026 Yuichiro Nakada <berry@berry-lab.net> - 0.3.0-b1
- Add make rpm, bzip2 archives/payloads and BusyBox migration layout.

* Sun Nov 15 2026 Yuichiro Nakada <berry@berry-lab.net> - 0.2.0-1
- Extend GNU command compatibility, shell execution, ANSI escapes and colors.
- Add differential and PTY-based tests to RPM checks.

* Sun Nov 15 2026 Yuichiro Nakada <berry@berry-lab.net> - 0.1.0-1
- Package static Zig utilities with optional root filesystem applet links.
- Create for Berry Linux