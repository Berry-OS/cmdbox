#!/usr/bin/env python3
"""cmdbox diff must match GNU diffutils byte for byte.

usage: diff_compat.py <cmdbox> <gnu-diff> [fuzz-iterations]
(<gnu-diff> is a real GNU diff binary, e.g. extracted from the diffutils rpm; the host's /usr/bin/diff is cmdbox)
"""
import os, random, shutil, subprocess, sys, tempfile

box, ref = sys.argv[1], sys.argv[2]
iters = int(sys.argv[3]) if len(sys.argv) > 3 else 300
env = dict(os.environ, LC_ALL='C', TZ='UTC')
work = tempfile.mkdtemp(prefix='diffcmp')
os.chdir(work)
fail = 0
total = 0


def run(cmd, args):
    p = subprocess.run(cmd + args, capture_output=True, env=env, stdin=subprocess.DEVNULL, timeout=20)
    return p.returncode, p.stdout, p.stderr


def norm_err(b):
    return b.replace(ref.encode(), b'diff')


def check(args, label=None):
    global fail, total
    total += 1
    rr, ro, re = run([ref], args)
    rn, no, ne = run([box, 'diff'], args)
    if (rr, norm_err(ro)) != (rn, no) or norm_err(re) != ne:
        fail += 1
        print('FAIL', label or args, 'rc', rr, rn)
        if label and label[0] == 'fuzz' and os.environ.get('DIFF_KEEP'):
            os.makedirs(os.environ['DIFF_KEEP'], exist_ok=True)
            shutil.copy('fz1', '%s/fz%d_1' % (os.environ['DIFF_KEEP'], label[1]))
            shutil.copy('fz2', '%s/fz%d_2' % (os.environ['DIFF_KEEP'], label[1]))
        if fail <= 6:
            print('  ref:', ro[:300], norm_err(re)[:200])
            print('  new:', no[:300], ne[:200])


def w(name, text):
    os.makedirs(os.path.dirname(name) or '.', exist_ok=True)
    with open(name, 'wb') as f:
        f.write(text if isinstance(text, bytes) else text.encode())
    os.utime(name, (1700000000, 1700000000))


# ------------------------------------------------------------ fixed cases
w('f1', 'a\nb\nc\nd\ne\nf\ng\nh\n')
w('f2', 'a\nB\nc\nd\ne\nf\nx\ny\nh\n')
w('same', 'a\nb\n')
w('same2', 'a\nb\n')
w('nonl1', 'a\nb\nc')
w('nonl2', 'a\nb\nd')
w('empty', '')
w('ws1', 'a  b\n\tc\nd \n\n\ne\n')
w('ws2', 'a b\nc\nd\n\ne\n\n')
w('case1', 'Hello\nWORLD\n')
w('case2', 'hello\nworld\n')
w('bin1', b'abc\x00def\n')
w('bin2', b'abc\x00xyz\n')
w('crlf1', b'a\r\nb\r\n')
w('crlf2', b'a\nb\n')
w('fn1', 'int main() {\n a;\n b;\n c;\n d;\n e;\n f;\n g;\n}\n\nvoid foo()\n{\n x;\n y;\n z;\n}\n')
w('fn2', 'int main() {\n a;\n b;\n c;\n d;\n e;\n f;\n G;\n}\n\nvoid foo()\n{\n x;\n Y;\n z;\n}\n')
w('tab1', 'a\tb\tc\nline\n')
w('tab2', 'a\tb\tX\nlinE\n')
styles = [[], ['-u'], ['-c'], ['-e'], ['-n'], ['-y'], ['-U0'], ['-U1'], ['-C1'], ['-C0'], ['-1'], ['-u', '-U5'], ['--normal'],
          ['--unified=2'], ['--context=2'], ['-y', '-W', '60'], ['-y', '-W', '41'], ['-y', '-t', '-W', '60'], ['-y', '--left-column'],
          ['-y', '--suppress-common-lines'], ['-y', '-W', '20'], ['-y', '-W', '200'], ['-y', '-W', '131', '-t'], ['--rcs'], ['--ed']]
pairs = [('f1', 'f2'), ('f2', 'f1'), ('same', 'same2'), ('nonl1', 'nonl2'), ('empty', 'f1'), ('f1', 'empty'), ('ws1', 'ws2'),
         ('case1', 'case2'), ('bin1', 'bin2'), ('crlf1', 'crlf2'), ('fn1', 'fn2'), ('tab1', 'tab2'), ('nonl1', 'f1'), ('f1', 'f1')]
for st in styles:
    for a, b in pairs:
        check(st + [a, b])
extra = [['-i'], ['-w'], ['-b'], ['-Z'], ['-B'], ['-E'], ['-q'], ['-s'], ['-a'], ['--strip-trailing-cr'], ['-i', '-u'], ['-b', '-u'], ['-w', '-c'],
         ['-B', '-u'], ['-Z', '-u'], ['-p', '-u'], ['-p', '-c'], ['-F', '^void', '-u'], ['-p', '-U1'], ['-T', '-u'], ['-T', '-c'], ['-t', '-u'],
         ['-t', '-c'], ['--tabsize=4', '-t', '-u'], ['-I', '^b', '-u'], ['-I', 'a', '-u'], ['-L', 'x', '-L', 'y', '-u'], ['-L', 'x', '-c'],
         ['-L', 'x', '-L', 'y', '-c'], ['--label=A', '--label=B'], ['-qs'], ['-sq'], ['-rs'], ['--brief'], ['-i', '-y'], ['-bw', '-y'],
         ['-p', '-y'], ['-e', '-i'], ['-n', '-w'], ['-ya'], ['-uw'], ['-Ncu'], ['-3'], ['-12'], ['-C', '4'], ['-U', '4']]
for st in extra:
    for a, b in pairs:
        check(st + [a, b])
# colour
for st in [['--color=always'], ['--color=always', '-u'], ['--color=always', '-c'], ['--color=always', '-y'], ['--color=always', '-e'],
           ['--color=always', '-n'], ['--color=always', '-p', '-u'], ['--color=always', '-p', '-c'], ['--color=always', '-y', '-W', '40'],
           ['--color=never', '-u'], ['--color=always', '--palette=ad=1;32:de=1;31:ln=33:hd=4', '-u']]:
    for a, b in pairs:
        check(st + [a, b])
# usage / errors
for a in [[], ['f1'], ['f1', 'f2', 'same'], ['--bogus', 'f1', 'f2'], ['-k', 'f1', 'f2'], ['nonexist', 'f1'], ['f1', 'nonexist'], ['-C', 'x', 'f1', 'f2'],
          ['-U', '-3', 'f1', 'f2'], ['--version'], ['--help'], ['-v'], ['--unified=x', 'f1', 'f2'], ['-W', 'x', 'f1', 'f2'], ['--color=bad', 'f1', 'f2'],
          ['--from-file=f1', 'f2', 'same'], ['--to-file=f1', 'f2', 'same'], ['-N', 'nonexist', 'f1'], ['-N', 'f1', 'nonexist'], ['-N', '-u', 'nonexist', 'f1'],
          ['-P', 'nonexist', 'f1'], ['-P', 'f1', 'nonexist']]:
    check(a)
# directories
shutil.rmtree('d1', ignore_errors=True)
shutil.rmtree('d2', ignore_errors=True)
w('d1/only1', 'x\n'); w('d2/only2', 'y\n'); w('d1/same', 's\n'); w('d2/same', 's\n')
w('d1/ch', 'l1\nl2\n'); w('d2/ch', 'l1\nL2\n')
w('d1/sub/a', '1\n2\n'); w('d2/sub/a', '1\n3\n'); w('d1/sub/o1', 'o\n'); w('d2/sub/o2', 'o\n')
w('d1/onlydir/z', 'z\n'); w('d1/typ', 'file\n'); os.makedirs('d2/typ', exist_ok=True)
w('d1/b.bin', b'\x00\x01\x02'); w('d2/b.bin', b'\x00\x01\x03')
for st in [[], ['-r'], ['-q'], ['-rq'], ['-s'], ['-rs'], ['-ru'], ['-rc'], ['-rN'], ['-rNu'], ['-rNq'], ['-rn'], ['-re'], ['-ry'], ['-r', '-x', 'ch'],
           ['-r', '-x', '*o*'], ['-r', '--exclude=sub'], ['-r', '-S', 'ch'], ['-r', '-S', 'sub'], ['-rP'], ['-r', '-U1'], ['-r', '--color=always', '-u'],
           ['-rNa'], ['-r', '-i'], ['-r', '-L', 'x', '-u'], ['-r', '-I', 'l', '-u']]:
    check(st + ['d1', 'd2'], ['dirs'] + st)
    check(st + ['d2', 'd1'], ['dirs-rev'] + st)
check(['f1', 'd1'])
check(['d1', 'f1'])
check(['-u', 'd1/ch', 'd2'])
check(['-u', 'd1', 'd2/ch'])
check(['-', 'f1'])
check(['d1/', 'd2/'])
check(['-r', 'd1/', 'd2/'])
check(['-r', 'd1//', 'd2'])
w('xfile', 'sub\nch\n')
check(['-r', '-X', 'xfile', 'd1', 'd2'])
check(['-r', '-X', 'nonexist', 'd1', 'd2'])
# ------------------------------------------------------------ fuzz
random.seed(12345)
alphabet = ['a', 'b', 'c', 'd', 'e', 'f', '', ' x', 'int f() {', '{', '}', '\tt', 'A', 'B', 'foo bar', 'foo  bar', 'long line ' * 5]
for it in range(iters):
    n = random.randint(0, 25)
    base = [random.choice(alphabet) for _ in range(n)]
    new = list(base)
    for _ in range(random.randint(0, 6)):
        op = random.random()
        if op < 0.4 and new:
            del new[random.randrange(len(new))]
        elif op < 0.8:
            new.insert(random.randint(0, len(new)), random.choice(alphabet))
        elif new:
            new[random.randrange(len(new))] = random.choice(alphabet)
    nl1 = '\n' if random.random() > 0.1 else ''
    nl2 = '\n' if random.random() > 0.1 else ''
    w('fz1', '\n'.join(base) + (nl1 if base else ''))
    w('fz2', '\n'.join(new) + (nl2 if new else ''))
    for st in random.sample([[], ['-u'], ['-c'], ['-e'], ['-n'], ['-y'], ['-U1'], ['-C5'], ['-u', '-i'], ['-u', '-b'], ['-u', '-w'], ['-p', '-u'],
                             ['-y', '-W', '50'], ['-u', '-B'], ['-uZ']], 4):
        check(st + ['fz1', 'fz2'], ['fuzz', it, st])
# larger inputs exercise the same heuristics as GNU diff (too_expensive / big snakes)
for it in range(8):
    n = random.choice([800, 3000, 9000])
    pool = [f'l{random.randint(0, n // random.choice([1, 3, 20]))}' for _ in range(n)]
    base = list(pool)
    new = list(pool)
    for _ in range(random.choice([5, 200, n // 3])):
        k = random.randrange(len(new))
        r = random.random()
        if r < 0.4:
            del new[k]
        elif r < 0.8:
            new.insert(k, f'n{random.randint(0, 40)}')
        else:
            new[k] = f'm{random.randint(0, 40)}'
    if it % 3 == 2:
        random.shuffle(new)
    w('big1', '\n'.join(base) + '\n')
    w('big2', '\n'.join(new) + '\n')
    for st in (['-u'], [], ['-e'], ['-y'], ['-d', '-u']):
        check(st + ['big1', 'big2'], ['big', it, st])
print(f'{total - fail}/{total} diff comparisons passed')
shutil.rmtree(work, ignore_errors=True)
sys.exit(1 if fail else 0)
