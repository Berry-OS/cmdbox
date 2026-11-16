#!/usr/bin/env python3
"""Deterministic migration layout; never depend on the build host's RPM DB."""
import argparse
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent

def applets():
    return re.findall(r'^\s*a\("([^"]+)"', (ROOT/'src/main.zig').read_text(), re.M)

def reference_paths():
    return [line for line in (ROOT/'packaging/busybox-paths.list').read_text().splitlines()
            if line and not line.startswith('#')]

def layout():
    names = set(applets())
    return [(path, path.rsplit('/',1)[1]) for path in reference_paths()
            if path.rsplit('/',1)[1] in names]

def report():
    names=set(applets())
    unsupported=[path for path in reference_paths() if path.rsplit('/',1)[1] not in names]
    return ('# BusyBox package migration\n\n'
            'Reference: busybox-1.22.1-b2.i686.\n'
            f'{len(layout())} legacy command paths are supplied by cmdbox; '
            f'{len(unsupported)} legacy commands are not implemented.\n\n'
            'Obsoleting BusyBox removes the following commands unless another package supplies them.\n'
            'This package does not advertise unimplemented awk/vi/DHCP capabilities.\n\n'
            + ''.join(f'- `{path}`\n' for path in unsupported))

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--applets',action='store_true')
    parser.add_argument('--report',action='store_true')
    args=parser.parse_args()
    if args.applets:
        print('\n'.join(applets()))
    elif args.report:
        print(report(),end='')
    else:
        for path,name in layout():
            print(f'{path}\t{name}')

if __name__=='__main__':
    main()
