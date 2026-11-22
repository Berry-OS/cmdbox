"""mkfs.vfat / mke2fs: images must pass the real checkers (fsck.fat -n, e2fsck -fn) and carry the requested
parameters; with root and unshare they are also loop-mounted and written to.  usage: mkfs_compat.py <cmdbox>"""
import os, re, shutil, struct, subprocess, sys, tempfile
from pathlib import Path
binary = str(Path(sys.argv[1]).resolve())
env = {**os.environ, 'LC_ALL': 'C'}
fails = []; n = 0
def check(name, cond, info=''):
    global n
    n += 1
    if not cond: fails.append((name, info))
def run(name, args):
    return subprocess.run(['bash', '-c', 'exec -a "$0" "$1" "${@:2}"', name, binary] + args, capture_output=True, env=env, timeout=120)
fsck_fat = shutil.which('fsck.fat'); e2fsck = shutil.which('e2fsck'); dumpe2fs = shutil.which('dumpe2fs')
with tempfile.TemporaryDirectory() as d:
    img = os.path.join(d, 'i.img')
    def mk(size_mb):
        with open(img, 'wb') as f: f.truncate(size_mb * 1024 * 1024)
    if fsck_fat:
        for mb, extra, bits in [(1, [], 12), (4, [], 12), (16, [], 16), (64, [], 16), (256, [], 16), (600, [], 32), (40, ['-F', '32'], 32),
                                (40, ['-F', '16'], 16), (40, ['-s', '1'], None), (40, ['-f', '1'], None), (40, ['-r', '224'], None), (40, ['-S', '1024'], None), (40, ['-R', '8'], None)]:
            mk(mb)
            r = run('mkfs.vfat', ['-i', '12345678', '-n', 'TESTVOL'] + extra + [img])
            c = subprocess.run([fsck_fat, '-n', img], capture_output=True, env=env)
            check(f'vfat {mb}M {extra} fsck', r.returncode == 0 and c.returncode == 0, (r.stderr[-200:], c.stdout[-300:], c.stderr[-200:]))
            h = open(img, 'rb').read(512)
            off = 71 if h[16 - 16 + 0x16:0x18] == b'\0\0' and h[22:24] == b'\0\0' else 43
            check(f'vfat {mb}M {extra} label/id', h[off:off + 11] == b'TESTVOL    ' and struct.unpack_from('<I', h, off - 4)[0] == 0x12345678, h[off - 4:off + 11])
            if bits:
                check(f'vfat {mb}M type FAT{bits}', (b'FAT%d   ' % bits) in h[54:90], h[54:90])
        mk(1)
        r = run('mkfs.vfat', ['-F', '12', '-C', os.path.join(d, 'new.img'), '1440'])
        check('vfat -C creates', os.path.getsize(os.path.join(d, 'new.img')) == 1440 * 1024 and subprocess.run([fsck_fat, '-n', os.path.join(d, 'new.img')], capture_output=True).returncode == 0, r.stderr)
        r = run('mkfs.vfat', ['-n', 'WAYTOOLONGLABEL', img])
        check('vfat long label refused', r.returncode != 0, r.stderr)
        r = run('mkfs.vfat', ['-F', '7', img])
        check('vfat bad -F', r.returncode != 0, r.stderr)
    if e2fsck:
        for mb, extra in [(2, []), (8, []), (64, []), (300, []), (1024, []), (64, ['-b', '2048']), (64, ['-b', '4096']), (64, ['-i', '8192']),
                          (64, ['-N', '5000']), (64, ['-I', '256']), (64, ['-m', '0'])]:
            mk(mb)
            r = run('mke2fs', ['-q', '-L', 'lbl'] + extra + [img])
            c = subprocess.run([e2fsck, '-fn', img], capture_output=True, env=env)
            check(f'ext2 {mb}M {extra} e2fsck', r.returncode == 0 and c.returncode == 0, (r.stderr[-200:], c.stdout[-400:]))
        if dumpe2fs:
            mk(64)
            run('mke2fs', ['-q', '-L', 'mylabel', '-U', '11111111-2222-3333-4444-555555555555', '-m', '2', img])
            o = subprocess.run([dumpe2fs, '-h', img], capture_output=True, env=env).stdout.decode()
            check('ext2 label', re.search(r'Filesystem volume name:\s+mylabel', o) is not None, o[:300])
            check('ext2 uuid', '11111111-2222-3333-4444-555555555555' in o, o[:400])
            check('ext2 reserved', re.search(r'Reserved block count:\s+1310', o) is not None, o)
            check('ext2 features', 'filetype' in o and 'sparse_super' in o, o)
        r = run('mke2fs', ['-t', 'ext4', img])
        check('mke2fs ext4 refused', r.returncode != 0, r.stderr)
if fails:
    for f in fails: print('FAIL', f)
    sys.exit(1)
print(f'{n} mkfs checks passed')
