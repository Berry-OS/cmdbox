"""dpkg: version ordering, queries and install/remove cycle on a scratch root built from a generated .deb.
usage: dpkg_compat.py <cmdbox>"""
import io, os, subprocess, sys, tarfile, tempfile, gzip
from pathlib import Path
binary = str(Path(sys.argv[1]).resolve())
fails = []; n = 0
def check(name, cond, info=''):
    global n
    n += 1
    if not cond: fails.append((name, info))
def dpkg(args, cwd=None):
    return subprocess.run(['bash', '-c', 'exec -a dpkg "$0" "$@"', binary] + args, capture_output=True, cwd=cwd, timeout=60)

# --- --compare-versions truth table
vectors = [
    ('1.0', 'lt', '1.1', True), ('1.0~rc1', 'lt', '1.0', True), ('1:0.5', 'gt', '2.0', True), ('1.0-1', 'lt', '1.0-2', True),
    ('1.0a', 'gt', '1.0', True), ('1.0+b1', 'gt', '1.0', True), ('2.0', 'eq', '2.00', True), ('1.0~', 'lt', '1.0', True),
    ('1.0-0', 'eq', '1.0', True), ('10', 'gt', '9', True), ('a', 'lt', 'b', True), ('1.0', 'gt', '1.0', False), ('1.0', 'ge', '1.0', True),
    ('1.0', 'le', '1.0', True), ('1.0', 'ne', '1.0', False), ('1.0', '<<', '1.0.1', True), ('1.0.1', '>>', '1.0', True), ('1.0', '<=', '1.0', True),
    ('0:1.0', 'eq', '1.0', True), ('1.0~~', 'lt', '1.0~', True), ('1.0-1ubuntu2', 'gt', '1.0-1ubuntu1', True), ('2.30-0ubuntu2.1', 'gt', '2.30-0ubuntu2', True),
    ('1.2.3', 'lt', '1.10.0', True), ('1.0~beta', 'lt', '1.0~rc', True), ('1:1.0', 'gt', '99.0', True),
]
for a, op, b, want in vectors:
    r = dpkg(['--compare-versions', a, op, b])
    check(f'cmp {a} {op} {b}', (r.returncode == 0) == want, r.returncode)
check('arch', dpkg(['--print-architecture']).stdout.strip() in (b'amd64', b'arm64', b'i386', b'armhf', b'riscv64'))
check('cmp usage', dpkg(['--compare-versions', '1']).returncode == 2)

# --- build a .deb
def tar_gz(entries):
    bio = io.BytesIO()
    with tarfile.open(fileobj=bio, mode='w:gz', format=tarfile.GNU_FORMAT) as t:
        for name, kind, data, mode in entries:
            ti = tarfile.TarInfo(name)
            ti.mode = mode
            if kind == 'dir':
                ti.type = tarfile.DIRTYPE
                t.addfile(ti)
            elif kind == 'sym':
                ti.type = tarfile.SYMTYPE; ti.linkname = data
                t.addfile(ti)
            else:
                ti.size = len(data)
                t.addfile(ti, io.BytesIO(data))
    return bio.getvalue()

def ar(members):
    out = b'!<arch>\n'
    for name, data in members:
        out += (name + '/').ljust(16).encode() + b'0'.ljust(12) + b'0'.ljust(6) + b'0'.ljust(6) + b'100644'.ljust(8) + str(len(data)).ljust(10).encode() + b'`\n'
        out += data + (b'\n' if len(data) % 2 else b'')
    return out

control = b'Package: hello-test\nVersion: 1.0-1\nArchitecture: all\nMaintainer: Test <t@example.com>\nDescription: test package\n long description line\n'
ctl = tar_gz([('./control', 'file', control, 0o644), ('./postinst', 'file', b'#!/bin/sh\necho configured > "$POSTINST_MARK"\n', 0o755)])
dat = tar_gz([('./usr/', 'dir', b'', 0o755), ('./usr/share/', 'dir', b'', 0o755), ('./usr/share/hello/', 'dir', b'', 0o755),
              ('./usr/share/hello/hello.txt', 'file', b'hello world\n', 0o644), ('./usr/share/hello/link', 'sym', 'hello.txt', 0o777)])
deb = ar([('debian-binary', b'2.0\n'), ('control.tar.gz', ctl), ('data.tar.gz', dat)])

with tempfile.TemporaryDirectory() as d:
    root = os.path.join(d, 'root')
    adm = os.path.join(root, 'var/lib/dpkg')
    os.makedirs(adm)
    open(os.path.join(adm, 'status'), 'w').write('Package: existing\nStatus: install ok installed\nVersion: 2.1\nArchitecture: amd64\nDescription: pre-existing package\n more text\n\n')
    open(os.path.join(adm, 'info/existing.list') if os.path.isdir(os.path.join(adm, 'info')) else os.path.join(adm, 'x'), 'w').close() if False else None
    os.makedirs(os.path.join(adm, 'info'))
    open(os.path.join(adm, 'info', 'existing.list'), 'w').write('/usr/bin/existing\n/etc/existing.conf\n')
    open(os.path.join(d, 'hello.deb'), 'wb').write(deb)
    base = ['--admindir=' + adm, '--instdir=' + root]
    r = dpkg(base + ['-l'])
    check('list header', b'||/ Name' in r.stdout and b'ii  existing' in r.stdout and b'pre-existing package' in r.stdout, r.stdout)
    r = dpkg(base + ['-s', 'existing'])
    check('status', r.stdout.startswith(b'Package: existing\n') and b'Version: 2.1' in r.stdout, r.stdout)
    r = dpkg(base + ['-s', 'nonesuch'])
    check('status missing', r.returncode == 1 and b'is not installed' in r.stderr, r.stderr)
    r = dpkg(base + ['-L', 'existing'])
    check('listfiles', r.stdout == b'/usr/bin/existing\n/etc/existing.conf\n', r.stdout)
    r = dpkg(base + ['-S', '/usr/bin/existing'])
    check('search', r.stdout == b'existing: /usr/bin/existing\n', r.stdout)
    r = dpkg(base + ['-i', os.path.join(d, 'hello.deb')])
    check('install rc', r.returncode == 0, r.stdout + r.stderr)
    check('install messages', b'Unpacking hello-test (1.0-1)' in r.stdout and b'Setting up hello-test (1.0-1)' in r.stdout, r.stdout)
    f = os.path.join(root, 'usr/share/hello/hello.txt')
    check('file installed', os.path.exists(f) and open(f).read() == 'hello world\n')
    check('symlink installed', os.path.islink(os.path.join(root, 'usr/share/hello/link')) and os.readlink(os.path.join(root, 'usr/share/hello/link')) == 'hello.txt')
    st = open(os.path.join(adm, 'status')).read()
    check('status updated', 'Package: hello-test' in st and 'Status: install ok installed' in st and 'Package: existing' in st, st)
    r = dpkg(base + ['-L', 'hello-test'])
    check('file list recorded', b'/usr/share/hello/hello.txt' in r.stdout, r.stdout)
    r = dpkg(base + ['-S', '/usr/share/hello/hello.txt'])
    check('owner lookup', r.stdout == b'hello-test: /usr/share/hello/hello.txt\n', r.stdout)
    r = dpkg(base + ['-l', 'hello*'])
    check('list pattern', b'ii  hello-test' in r.stdout and b'existing' not in r.stdout, r.stdout)
    r = dpkg(base + ['-r', 'hello-test'])
    check('remove', r.returncode == 0 and not os.path.exists(f) and b'Removing hello-test (1.0-1)' in r.stdout, r.stdout + r.stderr)
    r = dpkg(base + ['-l', 'hello-test'])
    check('config-files state', b'rc  hello-test' in r.stdout, r.stdout)
    r = dpkg(base + ['-P', 'hello-test'])
    st = open(os.path.join(adm, 'status')).read()
    check('purge', r.returncode == 0 and 'hello-test' not in st and 'existing' in st, st)
    r = dpkg(base + ['-i', os.path.join(d, 'nonexist.deb')])
    check('missing archive', r.returncode == 2 and b'cannot access archive' in r.stderr, r.stderr)
if fails:
    for f in fails: print('FAIL', f)
    sys.exit(1)
print(f'{n} dpkg checks passed')
