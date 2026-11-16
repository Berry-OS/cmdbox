#!/bin/sh
# Build a bzip2 source archive and bzip2-compressed RPM/SRPM, without downloads.
set -eu
cd "$(dirname "$0")"
mode=-ba
case "${1-}" in
    --source-only) mode=source; shift ;;
    --srpm) mode=-bs; shift ;;
esac
version=$(sed -n 's/^Version:[[:space:]]*//p' cmdbox.spec)
topdir="${RPM_TOPDIR:-/tmp/cmdbox-rpmbuild}"
mkdir -p "$topdir"
topdir=$(cd "$topdir" && pwd)
# The RPM layout relies on symlinks; exFAT/FAT mounts cannot store them and
# rpmbuild would fail deep inside %install with a bare "operation failed".
if ! ln -s / "$topdir/.cmdbox-symlink-test" 2>/dev/null; then
    echo "package.sh: $topdir does not support symbolic links (exFAT/FAT mount?)" >&2
    echo "  Point RPM_TOPDIR at a POSIX filesystem, e.g.:" >&2
    echo "    make rpm RPM_TOPDIR=/tmp/cmdbox-rpmbuild" >&2
    exit 1
fi
rm -f "$topdir/.cmdbox-symlink-test"
mkdir -p "$topdir/SOURCES" "$topdir/SPECS"
python3 packaging/layout.py --report > BUSYBOX-MIGRATION.md
tar -cjf "$topdir/SOURCES/cmdbox-$version.tar.bz2" \
    --exclude=__pycache__ --exclude='*.pyc' \
    --transform="s,^,cmdbox-$version/," \
    Makefile build.zig src tests packaging README.md README-ja.md assets COMPATIBILITY.md BUSYBOX-MIGRATION.md \
    LICENSE LICENSE.musl LICENSE.Zig cmdbox.spec package.sh
cp cmdbox.spec "$topdir/SPECS/"
if [ "$mode" = source ]; then
    printf '%s\n' "$topdir/SOURCES/cmdbox-$version.tar.bz2"
    exit 0
fi
exec rpmbuild "$mode" --define "_topdir $topdir" "$@" "$topdir/SPECS/cmdbox.spec"
