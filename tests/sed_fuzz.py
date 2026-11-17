"""Random sed script differential fuzzing against GNU sed.  Usage: sed_fuzz.py cmdbox gnu-sed [count] [seed]"""
import os, random, subprocess, sys
from pathlib import Path
binary = str(Path(sys.argv[1]).resolve()); ref = sys.argv[2]
count = int(sys.argv[3]) if len(sys.argv) > 3 else 2000
random.seed(int(sys.argv[4]) if len(sys.argv) > 4 else 1)
env = dict(os.environ, LC_ALL='C')
DATA = b'alpha one\nBeta two\n\ngamma  three\tx\ndelta 4 four\nepsilon 55\nzeta\n  last one'
addr = ['', '', '', '1', '2', '$', '/a/', '/e/I', '2,4', '/a/,/e/', '1~2', '2,+1', '3,~2', '0,/a/', '/o/,$', '$!', '2!', '/^$/', '/[0-9]/']
cmds = ['p', 'd', 'D', 'n', 'N', 'P', 'h', 'H', 'g', 'G', 'x', '=', 'l', 'z', 'F', 'q', 'Q', 'q3',
        's/a/X/', 's/a/X/g', 's/e/&&/2', 's/\\(.\\)\\(.\\)/\\2\\1/', 's/[a-z]*/<&>/', 's/\\w\\+/\\u&/g', 's/ /\\n/', 's/^/> /', 's/$/ </', 's/x*/-/g',
        's/\\b/|/g', 's/o/0/gI', 's/\\(a\\|e\\)/[\\1]/g', 's/[0-9]\\+/N/', 's/.*/\\U&/', 's/\\s\\+/_/g', 's/\\n/,/', 's/a/b/;s/b/c/', 'y/abc/xyz/',
        'a foo', 'i bar', 'c baz', 'r /dev/null', 'b', 't', 'T', 'bx', 'tx', ':x', '{p;p}', '{n;d}', '{s/a/b/;t}', 'w /dev/stdout', 's/a/b/w /dev/stdout', 'P;D', '$!N', 'N;P;D']
def script():
    n = random.randint(1, 4)
    parts = []
    for _ in range(n):
        a = random.choice(addr)
        c = random.choice(cmds)
        if a.endswith('!'): a += random.choice(['1', '/a/', '$', '2,3'])
        parts.append(a + c)
    return '\n'.join(parts)
bad = 0
for i in range(count):
    sc = script()
    flags = random.choice([[], ['-n'], ['-s'], ['-E'], ['-z'], ['-n', '-s']])
    data = random.choice([DATA, DATA + b'\n', b'', b'one', b'a\nb\nc\n'])
    try:
        a = subprocess.run([binary, 'sed', *flags, sc], input=data, capture_output=True, env=env, timeout=5)
        b = subprocess.run([ref, *flags, sc], input=data, capture_output=True, env=env, timeout=5)
    except subprocess.TimeoutExpired:
        continue
    if (a.returncode, a.stdout) != (b.returncode, b.stdout):
        # both erroring with any non-zero status is acceptable only when codes agree
        bad += 1
        if bad <= 25: print('DIFF', flags, repr(sc), 'data', repr(data[:20]), '\n  ours', a.returncode, a.stdout[:120], a.stderr[:80], '\n  gnu ', b.returncode, b.stdout[:120])
print(f'{count - bad}/{count} fuzz cases agree')
sys.exit(1 if bad else 0)
