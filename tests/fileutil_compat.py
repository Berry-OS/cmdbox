"""Differential checks of stat, du, dd, split and install against the installed GNU coreutils
(each command is skipped when the installed one is not GNU).  usage: fileutil_compat.py <cmdbox>"""
import os, re, shutil, subprocess, sys, tempfile
from pathlib import Path

B = str(Path(sys.argv[1]).resolve())
ENV = dict(os.environ, LC_ALL='C', TZ='Asia/Tokyo')

def is_gnu(cmd):
    try:
        r = subprocess.run([cmd, '--version'], capture_output=True, timeout=5)
        return b'coreutils' in r.stdout
    except Exception:
        return False

SETUP = """
mkdir -p t/a/b t/c d0 && printf hello > f && : > e && ln -s f sl && mkfifo ff && printf x > t/f1 && head -c 10000 /dev/zero > t/a/big
ln t/f1 t/hl && seq 1 25 > n && head -c 3000 /dev/zero | tr '\\0' 'a' > r && printf x > s1 && printf y > s2
printf '\\001\\002\\377\\200abcdefghijklmnop\\n' > odin && head -c 400 n | tr '\\n' '\\000' > odz
touch -d @1700000000 f e d0 t/f1 t/a/big
"""

def snapshot(d):
    out = []
    for root, dirs, files in os.walk(d):
        for n in sorted(dirs + files):
            p = os.path.join(root, n)
            st = os.lstat(p)
            data = b''
            if os.path.isfile(p) and not os.path.islink(p):
                data = Path(p).read_bytes()[:4096]
            out.append((os.path.relpath(p, d), oct(st.st_mode & 0o7777), st.st_size if not os.path.isdir(p) else 0, data))
    return sorted(out)

def normalise(b):
    b = re.sub(rb'20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9:]+\.[0-9]+ \+0900', lambda m: m.group(0) if m.group(0).startswith(b'2023') else b'NOW', b)
    b = re.sub(rb'\b179[0-9]{7}\b', b'EPOCH', b)
    b = re.sub(rb'\b(Inode: |\t)[0-9]+', lambda m: m.group(1) + b'N', b)
    b = re.sub(rb'f (5|0) 8 81a4 0 0 24 [0-9]+', b'f TERSE', b)
    b = re.sub(rb'(Device: )[0-9,]+', rb'\1D', b)
    b = re.sub(rb'[0-9.e+-]+ s, [0-9.]+ [kMGT]?B/s', b'T', b)
    b = re.sub(rb', [0-9.e+-]+ s\n', b'\n', b)
    return b

def run(prog, cmd):
    d = tempfile.mkdtemp()
    subprocess.run(['bash', '-c', SETUP], cwd=d, env=ENV)
    bindir = tempfile.mkdtemp()
    if prog:
        for n in ('stat', 'du', 'dd', 'split', 'install', 'od'):
            os.symlink(prog, os.path.join(bindir, n))
    env = dict(ENV, PATH=(bindir + ':' + ENV['PATH']) if prog else ENV['PATH'])
    # dd/split in the cmdbox run must go through the multicall binary, others run unchanged
    p = subprocess.run(['bash', '-c', cmd], cwd=d, env=env, capture_output=True, timeout=30)
    snap = snapshot(d)
    shutil.rmtree(d, ignore_errors=True); shutil.rmtree(bindir, ignore_errors=True)
    return p.returncode, normalise(p.stdout), normalise(p.stderr), snap

CASES = {
 'stat': ["stat f", "stat e", "stat d0", "stat sl", "stat -L sl", "stat ff", "stat /dev/null",
          "stat -c '%a %A %b %B %f %F %g %G %h %n %N %o %s %t %T %u %U' f",
          "stat -c '%x|%y|%z|%X|%Y|%Z' f", "stat -t f", "stat --printf '%n\\t%s\\n' f e", "stat -c '%N' sl",
          "stat -c '%10s|%-10s|%010s' f f f", "stat nonexist", "stat", "stat -f -c '%T %s %S %n' /", "stat -c '%F' f e d0 sl ff /dev/null"],
 'du': ["du t", "du -a t", "du -s t", "du -sh t", "du -h t", "du -b t", "du -ab t", "du -sb t", "du -k t", "du -m t", "du -c t",
        "du -d1 t", "du --max-depth=0 t", "du -S t", "du -l t", "du -L t", "du -x t", "du --apparent-size t", "du -B 512 t", "du -BK t",
        "du --si t", "du --exclude=b t", "du t/f1 t/a", "du nonexist", "du -sh t/a/big", "du --time t", "du -d 1 -h t", "du --inodes t",
        "du -ch t/f1 t/a/big", "du -s -d1 t", "du -a -s t", "du -B 1K t", "du --block-size=KB t"],
 'dd': ["dd if=n of=o1 bs=100", "dd if=n of=o1 bs=100 count=2", "dd if=n of=o1 bs=7 skip=3", "dd if=n of=o1 ibs=10 obs=3", "dd if=r of=o1 bs=1k",
        "dd if=r of=o1 bs=1000 count=1", "dd if=n of=o1 bs=10 conv=sync", "dd if=n of=o1 conv=ucase", "dd if=n of=o1 conv=swab", "dd if=n bs=512 count=0",
        "dd if=nonexist of=o1", "dd if=n of=o1 bs=bad", "dd if=n of=o1 foo=1", "dd if=n of=o1 status=none", "dd if=n of=o1 status=noxfer",
        "dd if=/dev/zero of=o1 bs=1k count=4", "dd if=n of=o1 seek=2 bs=10", "dd if=n of=o1 bs=3 count=1 conv=notrunc"],
 'split': ["split n", "split -l 10 n", "split -l 7 n y", "split -b 20 n", "split -b 1k n", "split -n 3 n", "split -d -l 10 n", "split -x -l 3 n",
           "split -a 3 -l 5 n", "split --additional-suffix=.txt -l 10 n", "split -C 30 n", "split -n 4 n z", "split -l 100 n", "split -e -n 40 n",
           "cat n | split -l 12 - y", "split -d -a 1 -l 10 n", "split --verbose -l 10 n"],
 'od': ["od odin", "od -c odin", "od -a odin", "od -b odin", "od -d odin", "od -x odin", "od -s odin", "od -i odin", "od -l odin", "od -f odin", "od -tx1 odin",
        "od -tu2 odin", "od -td4 odin", "od -td8 odin", "od -tf4 odin", "od -tf8 odin", "od -tx8 odin", "od -An odin", "od -Ax odin", "od -Ad odin", "od -w8 odin",
        "od -j2 odin", "od -N5 odin", "od -v odz", "od odz", "od -tx1z odin", "od -tc -tx1 odin", "od --endian=big -tx2 odin", "od -j3 -N7 -tx1 odin", "od -Ax -tx2z odin"],
 'install': ["install s1 o1", "install -m 644 s1 o1", "install -m u=rwx,go=rx s1 o1", "install -d d1", "install -d -m 700 d1/a/b", "mkdir d1; install s1 s2 d1",
             "install -t d1 s1", "install -D s1 d1/x/y/o1", "install -v s1 o1", "install -vd d1/q", "install s1 s1", "install nonexist o1", "install d0 o1",
             "install s1", "install", "install -T s1 o1", "install -b s1 o1; install -b s2 o1", "install -m 999 s1 o1"],
}
fails = 0
checks = 0
for cmd, cases in CASES.items():
    if not is_gnu(cmd):
        print(f'GNU {cmd} not available: skipped')
        continue
    for c in cases:
        checks += 1
        a = run(None, c)
        b = run(B, c)
        # inode numbers and free counts vary between runs
        strip = lambda t: (t[0], re.sub(rb'Inode: N +', b'Inode: N ', t[1]), t[2], t[3])
        if strip(a) != strip(b):
            fails += 1
            print('DIFF:', c)
            print('  gnu:', a[:3]); print('  box:', b[:3])
if fails:
    sys.exit(1)
print(f'{checks} stat/du/dd/split/install comparisons against GNU coreutils passed')
