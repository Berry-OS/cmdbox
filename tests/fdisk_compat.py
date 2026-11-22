"""fdisk -l against the real fdisk on generated disk images (sfdisk) and on this machine's disks.
usage: fdisk_compat.py <cmdbox>"""
import os, shutil, subprocess, sys, tempfile
from pathlib import Path
binary = str(Path(sys.argv[1]).resolve())
ref = shutil.which('fdisk')
sfdisk = shutil.which('sfdisk')
if not ref or os.path.realpath(ref) == os.path.realpath(binary):
    print('no reference fdisk: skipped'); sys.exit(0)
env = {**os.environ, 'LC_ALL': 'C'}
def run(cmd, args):
    if cmd == 'mine':
        return subprocess.run(['bash', '-c', 'exec -a fdisk "$0" "$@"', binary] + args, capture_output=True, env=env, timeout=60)
    return subprocess.run([ref] + args, capture_output=True, env=env, timeout=60)
fails = []; n = 0
def cmp(args):
    global n
    n += 1
    a, b = run('ref', args), run('mine', args)
    if (a.returncode, a.stdout, a.stderr) != (b.returncode, b.stdout, b.stderr):
        fails.append((args, a.stdout[:300], b.stdout[:300], a.stderr[:100], b.stderr[:100]))
with tempfile.TemporaryDirectory() as d:
    if sfdisk:
        imgs = {
            'dos.img': ('200M', 'label: dos\nlabel-id: 0x12345678\nstart=2048, size=20M, type=83, bootable\nstart=, size=30M, type=82\nstart=, size=60M, type=5\nstart=, size=10M, type=c\n,10M,83\n,20M,8e\n'),
            'gpt.img': ('300M', 'label: gpt\nlabel-id: 11111111-2222-3333-4444-555555555555\nsize=10M, type=U\nsize=20M, type=L\nsize=30M, type=S\nsize=40M, type=H\nsize=50M, type=V\n'),
            'dos2.img': ('64M', 'label: dos\nstart=2048, size=10M, type=7\nstart=, size=20M, type=ef, bootable\n'),
            'empty.img': ('10M', ''),
        }
        for name, (size, script) in imgs.items():
            p = os.path.join(d, name)
            with open(p, 'wb') as f:
                f.truncate({'200M': 200, '300M': 300, '64M': 64, '10M': 10}[size] * 1024 * 1024)
            if script:
                subprocess.run([sfdisk, p], input=script.encode(), capture_output=True)
            cmp(['-l', p])
        cmp(['-l', os.path.join(d, 'dos.img'), os.path.join(d, 'gpt.img')])
    cmp(['-l'])
    cmp(['-l', '/dev/nonexist'])
    cmp(['-V'])
    cmp(['--help'])
if fails:
    for f in fails: print('FAIL', f)
    sys.exit(1)
print(f'{n} fdisk comparisons passed')
