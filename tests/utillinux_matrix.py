#!/usr/bin/env python3
"""Differential test of cmdbox's util-linux applets against the real util-linux binaries (read-only / harmless cases).

usage: utillinux_matrix.py <cmdbox> <util-linux usr/bin dir> [LD_LIBRARY_PATH dir]
"""
import hashlib, os, re, subprocess, sys, tempfile, shutil

box, refdir = sys.argv[1], sys.argv[2]
env = dict(os.environ, LC_ALL='C', TZ='UTC', COLUMNS='80')
if len(sys.argv) > 3:
    env['LD_LIBRARY_PATH'] = sys.argv[3]
work = tempfile.mkdtemp(prefix='ulmatrix')
os.chdir(work)
fail = total = 0


def norm(b):
    b = re.sub(rb'UUID=[0-9a-f-]{36}', b'UUID=X', b)
    b = re.sub(rb'<(\d+)>[A-Z][a-z]{2} [ \d]\d \d\d:\d\d:\d\d', rb'<\1>TIME', b)
    b = re.sub(rb'\[\d+\]:', b'[PID]:', b)
    return b


def run(cmd, args, data):
    kw = {'input': data} if data else {'stdin': subprocess.DEVNULL}
    return subprocess.run(cmd + args, capture_output=True, env=env, timeout=20, **kw)


def check(tool, args, data=b'', files=()):
    """Run both tools; `files` are compared byte for byte afterwards (each tool gets a fresh copy)."""
    global fail, total
    ref = os.path.join(refdir, tool)
    if not os.path.exists(ref):
        return
    total += 1
    res = []
    for cmd in ([ref], [box, tool]):
        for f in files:
            if os.path.exists(f + '.orig'):
                shutil.copy(f + '.orig', f)
        p = run(cmd, args, data)
        digest = [hashlib.md5(open(f, 'rb').read()).hexdigest() if os.path.exists(f) else None for f in files]
        out = p.stdout
        if tool == 'dmesg':  # the ring buffer keeps growing between the two runs
            out = b'\n'.join(out.split(b'\n')[:1500])
        res.append((p.returncode, norm(out.replace(ref.encode(), tool.encode())), norm(p.stderr.replace(ref.encode(), tool.encode())), digest))
    a, b = res
    if a != b:
        fail += 1
        print('FAIL', tool, args, 'rc', a[0], b[0])
        if fail <= int(os.environ.get('SHOW', '40')):
            print('   ref:', a[1][:300], a[2][:300], a[3])
            print('   new:', b[1][:300], b[2][:300], b[3])


def w(name, data):
    with open(name, 'wb') as f:
        f.write(data)
    shutil.copy(name, name + '.orig')


# ---- kill
for a in [['-l'], ['-L'], ['-l', '9'], ['-l', 'TERM'], ['-l', '15', '2'], ['-l', 'SIGINT'], ['-l', '137'], ['-l', 'bogus'], ['-s', 'bogus', '1'], ['-0', '999999'], ['-9', '999999'],
          ['-TERM', '999999'], ['-s', 'KILL', '999999'], ['--signal', 'HUP', '999999'], ['-n', '9', '999999'], [], ['abc'], ['-l', '-l'], ['-q', '1', '999999'], ['-SIGUSR1', '999999'],
          ['-l', '0'], ['-l', '64'], ['-l', '65'], ['-RTMIN', '999999'], ['-l', 'RTMAX'], ['-V'], ['--version']]:
    check('kill', a)
# ---- mkswap on regular files
for size, args in [(1 << 20, []), (1 << 20, ['-L', 'lbl']), (1 << 20, ['-U', '12345678-1234-1234-1234-123456789abc']), (1 << 20, ['-p', '4096']), (1 << 20, ['-f']),
                   (1 << 20, ['-c']), (65536, []), (4096, []), (1 << 20, ['-L', 'x' * 20]), (1 << 20, ['-v1']), (1 << 20, ['-v0']), (2 << 20, ['-p', '65536']), (1 << 20, ['--verbose'])]:
    w('swap.img', b'\0' * size)
    check('mkswap', ['-U', '11111111-2222-3333-4444-555555555555'] + args + ['swap.img'], files=['swap.img']) if '-U' not in args else check('mkswap', args + ['swap.img'], files=['swap.img'])
check('mkswap', ['nonexistent'])
check('mkswap', [])
check('mkswap', ['-V'])
# ---- swapon / swapoff (read-only queries)
for a in [['--show'], ['--show', '--noheadings'], ['--show=NAME,SIZE'], ['-s'], ['--summary'], ['--show', '--raw'], ['--show', '--bytes']]:
    check('swapon', a)
check('swapoff', ['/nonexistent'])
check('swapon', ['/nonexistent'])
# ---- findfs / fsck dry runs
for a in [['LABEL=nonexist'], ['UUID=00000000-0000-0000-0000-000000000000'], ['foo'], [], ['PARTUUID=0'], ['-V']]:
    check('findfs', a)
for a in [['-N', '/dev/nonexist'], ['-N', '-t', 'ext4', '/dev/x'], ['-N', '-A'], ['-N', '-AR'], ['-V', '-N', '/dev/x'], ['-N', '-C', '/dev/x'], ['-N', '-C6', '-t', 'vfat', '/dev/x'],
          ['-N', '-a', '-T', '-l', '-M', '-C6', '-t', 'vfat', '/dev/x'], ['-N', '-s', '-t', 'ext4', '/dev/a', '/dev/b'], ['-N', '--', '-p', '/dev/x'], ['-t', 'nonexist', '-N', '/dev/x']]:
    check('fsck', a)
# ---- fdisk -l on image files
img = bytearray(1 << 20)
w('plain.img', bytes(img))
for a in [['-l', 'plain.img'], ['-l', '-u=cylinders', 'plain.img'], ['-s', 'plain.img'], ['-l', 'nonexistent'], ['-V'], ['-x', 'plain.img'], ['-l', '-b', '4096', 'plain.img']]:
    check('fdisk', a)
# MBR image
mbr = bytearray(1 << 20)
mbr[446:462] = bytes([0x80, 0x00, 0x21, 0x00, 0x83, 0xfe, 0xff, 0xff, 0x00, 0x08, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00])
mbr[462:478] = bytes([0x00, 0xfe, 0xff, 0xff, 0x82, 0xfe, 0xff, 0xff, 0x00, 0x10, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00])
mbr[510:512] = b'\x55\xaa'
w('mbr.img', bytes(mbr))
for a in [['-l', 'mbr.img'], ['-l', '-u=cylinders', 'mbr.img'], ['-l', '-u=sectors', 'mbr.img'], ['-x', 'mbr.img'], ['-l', '-o', 'Device,Start,End', 'mbr.img'], ['-s', 'mbr.img'],
          ['--list', '--output', 'Device,Boot,Type', 'mbr.img']]:
    check('fdisk', a)
# ---- losetup queries
for a in [['-a'], ['-l'], ['-f'], ['-j', 'plain.img'], ['-l', '-a'], ['-O', 'NAME'], ['--list', '--noheadings'], ['-J'], ['/dev/loop-nonexistent'], ['-V'], ['-l', '-O', 'NAME,SIZELIMIT']]:
    check('losetup', a)
# NEVER give umount a real mount point here: for umount -f means --force (unlike mount -f = fake)
# ---- mount / umount / pivot_root / switch_root / eject / fstrim (harmless)
for a in [[], ['-l'], ['-t', 'proc'], ['-t', 'nonexistent'], ['-V'], ['--show-labels'], ['-f', '-v', '-t', 'tmpfs', 'x', 'mnt-no'], ['-fv', '-t', 'tmpfs', 'none', '/tmp'], ['-n', '-f', '/dev/null', '/nonexistent'],
          ['-fv', '--bind', '/tmp', '/tmp'], ['-fvr', '-t', 'tmpfs', 'none', '/tmp'], ['-fv', '-o', 'ro,noexec', '-t', 'tmpfs', 'none', '/tmp'], ['-c', '-f', '-v', '-t', 'tmpfs', 'none', '/tmp'],
          ['-fv', '-L', 'nolabel', '/tmp'], ['-fv', '-U', '0000', '/tmp']]:
    check('mount', a)
for a in [['/nonexistent'], [], ['-V'], ['-f', '-v', '/nonexistent'], ['-r', '-f', '/nonexistent'], ['-l', '-f', '/nonexistent']]:
    check('umount', a)
for a in [[], ['x'], ['/nonexistent', '/nonexistent2'], ['-V']]:
    check('pivot_root', a)
for a in [[], ['x'], ['/nonexistent', '/sbin/init'], ['-V']]:
    check('switch_root', a)
for a in [['-V'], ['-n', '/dev/nonexist'], ['-n'], ['-n', '-t'], ['-n', '-T'], ['--help'] if False else ['-n', '-d'], ['nonexist'], ['-n', '-c', '1', '/dev/nonexist'], ['-n', '-a', 'on', '/dev/nonexist']]:
    check('eject', a)
for a in [['-V'], ['/nonexistent'], [], ['-v', '/nonexistent'], ['-o', 'x', '/'], ['-l', 'x', '/'], ['-m', '1', '/nonexistent'], ['-a', '-n']]:
    check('fstrim', a)
# ---- renice
for a in [[], ['5'], ['-n', '5', '-p', '999999'], ['+5', '-p', '999999'], ['-n', 'x', '-p', '1'], ['-V'], ['5', '-g', '999999'], ['5', '-u', 'nosuchuser'], ['-n', '5', '999999'], ['--priority', '5', '-p', '999999'], ['-n', '5', '-u', '999999']]:
    check('renice', a)
# ---- logger (to stdout via -s / --stderr only; skip syslog sockets)
for a in [['-s', '-t', 'tag', 'hello'], ['--stderr', '-p', 'user.notice', 'msg'], ['-s', '-i', '-t', 'x', 'm'], ['-s', '-p', 'bogus.bad', 'm'], ['-s', '--id=5', '-t', 'q', 'm'], ['-V'],
          ['-s', '--', '-dash'], ['-s', '-t', 'a b', 'x y z'], ['-s', '-n', '/nonexistent-sock', 'm'], ['--rfc3164', '-s', 'm'] if False else ['-s', '-S', '5', 'long message'], ['-s', '-e', 'x'] if False else ['-s', '']]:
    check('logger', a)
check('logger', ['-s', '-t', 'stdin'], b'from stdin\nsecond line\n')
# ---- dmesg (read-only)
for a in [[], ['-r'], ['-x'], ['-t'], ['-l', 'err,warn'], ['-k'], ['-u'], ['-f', 'kern'], ['-f', 'user'], ['--time-format=iso'], ['--time-format=ctime'], ['--time-format=reltime'], ['--time-format=notime'],
          ['-H', '-P'], ['-L=never'], ['-d'], ['-e'], ['-T'], ['-S'], ['-F', '/dev/null'], ['--since', '0'], ['--until', '1'], ['-J'], ['-w', '-n'] if False else ['-q'], ['-V'], ['-l', 'bogus'], ['-s', '1000'], ['-n', 'bogus']]:
    check('dmesg', a)
# ---- more (non-tty path) and rev
w('t.txt', b'one\ntwo\nthree\n' * 3)
for a in [['t.txt'], ['t.txt', 't.txt'], ['-d', 't.txt'], ['-n', '2', 't.txt'], ['+2', 't.txt'], ['-s', 't.txt'], ['-c', 't.txt'], ['nonexist'], ['-V'], ['-f', 't.txt'], ['-p', 't.txt'], ['-l', 't.txt'], ['-u', 't.txt'],
          ['--lines', '1', 't.txt'], ['-5', 't.txt']]:
    check('more', a)
check('more', [], b'stdin data\nline2\n')
for a in [['t.txt'], ['-V'], [], ['nonexist'], ['--zero', 't.txt'], ['-0', 't.txt']]:
    check('rev', a)
check('rev', [], b'abc\n\xe3\x81\x82\xe3\x81\x84\nlast')
print(f'{total - fail}/{total} util-linux comparisons passed')
shutil.rmtree(work, ignore_errors=True)
sys.exit(1 if fail else 0)
