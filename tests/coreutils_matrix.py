#!/usr/bin/env python3
"""Option-matrix differential test of cmdbox against real GNU coreutils/util-linux/findutils binaries.

usage: coreutils_matrix.py <cmdbox> <dir-with-GNU-binaries>[:<dir>...]
The reference directories are searched for the tool (e.g. an extracted coreutils rpm's usr/bin).
"""
import os, subprocess, sys, tempfile, shutil

box = sys.argv[1]
refdirs = sys.argv[2].split(':')
env = dict(os.environ, LC_ALL='C', TZ='UTC', COLUMNS='80')
work = tempfile.mkdtemp(prefix='cumatrix')
os.chdir(work)
fail = 0
total = 0


def find_ref(tool):
    for d in refdirs:
        p = os.path.join(d, tool)
        if os.path.exists(p):
            return p
    return None


applets = set(subprocess.run([box, '--list'], capture_output=True, text=True).stdout.split())


def check(tool, args, data=b'', quiet_err=False):
    global fail, total
    ref = find_ref(tool)
    if not ref or tool not in applets:
        return
    total += 1
    try:
        a = subprocess.run([ref] + args, input=data, capture_output=True, env=env, timeout=10)
        b = subprocess.run([box, tool] + args, input=data, capture_output=True, env=env, timeout=10)
    except subprocess.TimeoutExpired:
        fail += 1
        print('TIMEOUT', tool, args)
        return
    ea = a.stderr.replace(ref.encode(), tool.encode())
    ok = (a.returncode, a.stdout) == (b.returncode, b.stdout)
    if ok and not quiet_err and ea != b.stderr:
        ok = False
    if not ok:
        fail += 1
        print('FAIL', tool, args, 'rc', a.returncode, b.returncode)
        if fail <= int(os.environ.get('SHOW', '25')):
            print('   ref out:', a.stdout[:200], 'err:', ea[:200])
            print('   new out:', b.stdout[:200], 'err:', b.stderr[:200])


def w(name, data):
    os.makedirs(os.path.dirname(name) or '.', exist_ok=True)
    with open(name, 'wb') as f:
        f.write(data if isinstance(data, bytes) else data.encode())
    os.utime(name, (1700000000, 1700000000))


text = b'banana 3\napple 10\ncherry 2\nApple 1\nbanana 3\n\n  indented line\nzebra\t9\nlast without newline'
nums = b'10\n9\n100\n-5\n3.5\n1e2\n0x10\n 7\n'
w('t.txt', text)
w('n.txt', nums)
w('csv.txt', 'a,b,c\n1,2,3\n4,5,6\nx,,z\n')
w('dup.txt', 'a\na\nb\nB\nb\nc\nc\nc\n')
w('f/sub/x', 'x\n')
w('f/a', 'aaa\n')
w('f/b b', 'b\n')
w('f/.hidden', 'h\n')
w('f/long_name_file.txt', 'l\n' * 100)
os.symlink('a', 'f/link')
os.chmod('f/a', 0o640)
os.chmod('f/sub', 0o750)

# ---- ls
for o in [[], ['-l'], ['-la'], ['-1'], ['-a'], ['-A'], ['-F'], ['-p'], ['-R'], ['-lR'], ['-S'], ['-t'], ['-r'], ['-X'], ['-v'], ['-U'], ['-h', '-l'],
          ['-s'], ['-i'], ['-n'], ['-g'], ['-o'], ['-d'], ['-d', '*'], ['-m'], ['-x'], ['-C'], ['-1', '-r', '-S'], ['--group-directories-first'],
          ['-lh', '--time-style=long-iso'], ['-l', '--time-style=full-iso'], ['-l', '--time-style=+%Y'], ['--full-time'], ['-b'], ['-q'], ['-Q'],
          ['-N'], ['--indicator-style=slash'], ['--indicator-style=classify'], ['-H'], ['-L'], ['-l', '--si'], ['-l', '-k'], ['-T', '4'], ['-w', '40'],
          ['--color=always'], ['--color=always', '-l'], ['-I', '*.txt'], ['--hide=a'], ['-B'], ['-c'], ['-u'], ['-lt'], ['-ltr'], ['-lS'], ['-lX'], ['-D'],
          ['-Z'], ['--sort=size'], ['--sort=extension'], ['--sort=none'], ['--sort=version'], ['--format=commas'], ['--format=long'], ['--format=single-column']]:
    check('ls', o + ['f'])
    check('ls', o + ['f/a', 'f/sub'])
# ---- cat / tac / nl / fold / fmt-like
for o in [[], ['-n'], ['-b'], ['-s'], ['-E'], ['-T'], ['-v'], ['-A'], ['-ns'], ['-bE'], ['-e'], ['-t']]:
    check('cat', o + ['t.txt'])
    check('cat', o, text)
for o in [[], ['-ba'], ['-bt'], ['-n', 'ln'], ['-n', 'rz'], ['-w', '3'], ['-s', ':'], ['-v', '5'], ['-i', '2'], ['-l', '2'], ['-p'], ['-ha'], ['-fa'], ['-d', 'ab']]:
    check('nl', o + ['t.txt'])
for o in [[], ['-w', '10'], ['-s'], ['-b'], ['-w', '5', '-s']]:
    check('fold', o + ['t.txt'])
check('tac', ['t.txt'])
check('tac', ['-s', 'a', 't.txt'])
check('tac', ['-b', 't.txt'])
check('rev', ['t.txt'])
# ---- head / tail
for o in [[], ['-n', '2'], ['-n', '-2'], ['-n', '+2'], ['-c', '5'], ['-c', '-5'], ['-n', '0'], ['-q'], ['-v'], ['-z'], ['-2'], ['-n', '1K'], ['-c', '1b']]:
    check('head', o + ['t.txt'])
    check('head', o + ['t.txt', 'n.txt'])
    check('tail', o + ['t.txt'])
    check('tail', o + ['t.txt', 'n.txt'])
# ---- wc / cut / tr / sort / uniq / paste / join / comm
for o in [[], ['-l'], ['-w'], ['-c'], ['-m'], ['-L'], ['-lw'], ['--total=always'], ['--total=only'], ['--total=never']]:
    check('wc', o + ['t.txt'])
    check('wc', o + ['t.txt', 'n.txt'])
    check('wc', o, text)
for o in [['-c', '1-3'], ['-c', '2-'], ['-c', '-3'], ['-b', '1,3'], ['-f', '1', '-d', ','], ['-f', '1,3', '-d', ',', '-s'], ['-f', '2-', '-d', ',', '--output-delimiter=:'],
          ['-f', '1', '-d', ',', '--complement'], ['-c', '1', '--complement'], ['-d', ' ', '-f', '1'], ['-z', '-c', '1']]:
    check('cut', o + ['csv.txt'])
    check('cut', o + ['t.txt'])
for o in [[], ['-r'], ['-n'], ['-u'], ['-f'], ['-b'], ['-d'], ['-h'], ['-g'], ['-M'], ['-V'], ['-s'], ['-k2'], ['-k2,2'], ['-k2n'], ['-k2nr'], ['-k1,1', '-k2n'], ['-t', ' ', '-k2n'],
          ['-nr'], ['-fu'], ['-c'], ['-C'], ['-z'], ['-m'], ['--parallel=2'], ['-S', '1M'], ['-k', '1.2'], ['-k', '1.2,1.3'], ['-k', '2b'], ['-bk2'], ['--stable', '-k1,1']]:
    check('sort', o + ['t.txt'])
    check('sort', o + ['n.txt'])
    check('sort', o + ['dup.txt'])
for o in [[], ['-c'], ['-d'], ['-u'], ['-i'], ['-f', '1'], ['-s', '1'], ['-w', '1'], ['-D'], ['-z'], ['--group'], ['-cd'], ['--all-repeated=separate'], ['--group=both']]:
    check('uniq', o + ['dup.txt'])
for o in [[], ['-s'], ['-d', ':'], ['-d', ':,'], ['-z']]:
    check('paste', o + ['t.txt', 'n.txt'])
check('paste', ['-s', '-d', ',', 't.txt'])
check('comm', ['dup.txt', 'dup.txt'])
check('comm', ['-12', 'dup.txt', 'dup.txt'])
for a in [['a-z', 'A-Z'], ['-d', 'a-c'], ['-s', 'a-z'], ['-c', 'a-z', 'X'], ['-cd', 'a-z'], ['-t', 'abc', 'x'], ['[:lower:]', '[:upper:]'], ['-d', '[:space:]'], ['a-c', 'xyz'],
          ['-s', ' '], ['\\n', ' '], ['-d', '\\t'], ['a', '\\x41'], ['[a*3]', 'b'], ['-ds', 'a', 'b'], ['--squeeze-repeats', 'p']]:
    check('tr', a, text)
# ---- seq / expr / printf / echo / test / basename / dirname / date-less
for a in [['5'], ['2', '5'], ['1', '2', '10'], ['10', '-3', '1'], ['-s', ',', '3'], ['-w', '8', '10'], ['-f', '%.2f', '1', '3'], ['0.5', '0.5', '3'], ['-w', '-s', ' ', '1', '3'],
          ['1e2'], ['3', '1'], ['-f', '%g', '1', '0.1', '1.3'], ['1', '0', '5']]:
    check('seq', a)
for a in [['1', '+', '2'], ['2', '*', '3'], ['7', '/', '2'], ['7', '%', '2'], ['abc', ':', 'a.*'], ['abc', ':', '\\(b\\)'], ['length', 'abc'], ['substr', 'abcdef', '2', '3'],
          ['index', 'abc', 'c'], ['1', '<', '2'], ['a', '=', 'a'], ['1', '|', '2'], ['0', '|', '2'], ['1', '&', '0'], ['1', '/', '0'], ['(', '1', '+', '2', ')', '*', '3'],
          ['match', 'abc', 'b'], ['-5', '+', '3'], ['9223372036854775807', '+', '1']]:
    check('expr', a)
for a in [['%s\\n', 'a', 'b'], ['%5d|%-5d|\\n', '1', '2'], ['%x %X %o\\n', '255', '255', '8'], ['%e\\n', '1234.5'], ['%g\\n', '0.0001'], ['%c\\n', 'abc'], ['%b\\n', 'a\\tb'],
          ['%q\\n', 'a b'], ['%5.2s|\\n', 'abcdef'], ['%%\\n'], ['\\x41\\101\\n'], ['%s %s\\n', 'a'], ['%d\\n', 'abc'], ['%d\\n', '0x10'], ['%i\\n', '010'], ['%+d % d\\n', '5', '5'],
          ['%.3f\\n', '3.14159'], ['%*d\\n', '5', '3'], ['%-*d|\\n', '5', '3'], ['%u\\n', '-1'], ['%s\\n'], ['\\c'], ['a\\cb'], ['%10.4f|\\n', '2.5']]:
    check('printf', a)
for a in [['a', 'b'], ['-n', 'a'], ['-e', 'a\\tb'], ['-E', 'a\\tb'], ['-e', '\\x41\\0101'], ['-ne', 'a\\c'], ['-n'], ['-e', '\\e[0m'], ['--', '-n']]:
    check('echo', a)
for a in [['/a/b/c.txt'], ['/a/b/c.txt', '.txt'], ['-s', '.txt', 'a.txt', 'b.txt'], ['-a', 'x/a', 'y/b'], ['a/'], ['/'], [''], ['//'], ['a//b//']]:
    check('basename', a)
for a in [['/a/b/c'], ['a'], ['/'], ['a/'], ['a/b/'], [''], ['-z', 'a/b'], ['a/b', 'c/d']]:
    check('dirname', a)
for a in [['a/../b'], ['-m', 'f/a'], ['-e', 'f/nonexist'], ['-s', 'f/link'], ['--relative-to=f', 'f/sub/x'], ['-q', 'f/zz'], ['f/link'], ['/proc/self/..']]:
    check('realpath', a)
check('readlink', ['f/link'])
check('readlink', ['-f', 'f/link'])
check('readlink', ['f/a'])
# ---- test / [
for a in [['-f', 'f/a'], ['-d', 'f'], ['-e', 'nonexist'], ['-s', 'f/a'], ['-L', 'f/link'], ['-r', 'f/a'], ['-x', 'f/a'], ['a', '=', 'a'], ['a', '!=', 'a'], ['1', '-lt', '2'],
          ['2', '-ge', '10'], ['-z', ''], ['-n', ''], ['!', '-f', 'f/a'], ['-f', 'f/a', '-a', '-d', 'f'], ['-f', 'x', '-o', '-d', 'f'], ['(', '-f', 'f/a', ')'], ['abc'], [''], ['-t', '0'],
          ['f/a', '-nt', 'f/b b'], ['f/a', '-ef', 'f/a'], ['1', '-eq', 'x'], ['a', '<', 'b'], ['-v']]:
    check('test', a)
# ---- stat / du / df-less
for a in [['-c', '%a %n %s %F', 'f/a'], ['-c', '%A %U %G %h', 'f/a'], ['-c', '%y', 'f/a'], ['-c', '%Y %X %Z', 'f/a'], ['-L', '-c', '%N', 'f/link'], ['-c', '%N', 'f/link'], ['f/a'], ['-f', '-c', '%T', 'f'],
          ['-t', 'f/a'], ['--printf=%s\\n', 'f/a'], ['-c', '%d %i %b %B %o', 'f/a'], ['-c', '%w', 'f/a'], ['-c', '%x', 'f/a'], ['-c', '%F %f', 'f', 'f/a', 'f/link']]:
    check('stat', a)
for a in [[], ['-a'], ['-h'], ['-s'], ['-sb'], ['-b'], ['-c'], ['-d', '0'], ['-k'], ['-m'], ['--apparent-size'], ['-x'], ['-S'], ['--exclude=*.txt'], ['-L'], ['--si'], ['-ah', '-d1'], ['-B', '1K'], ['--time'],
          ['--time=ctime'], ['-0'], ['-l']]:
    check('du', a + ['f'])
# ---- date / env / misc
for a in [['-d', '2024-02-29 12:34:56', '+%F %T %a %A %b %B %j %U %W %u %w %y %Z %z %s %e %k %l %p %P %I %H %M %S %N %n %t %%'], ['-u', '-d', '@86400', '+%c'], ['-d', '1 day ago', '+%F'] if False else ['-d', '@0', '+%x %X'],
          ['-d', '2024-01-31 +1 month', '+%F'], ['-d', 'next monday', '+%u'] if False else ['-d', '2024-03-10', '+%V %G %g %C %h %D %r %R %T'], ['-d', '2024-12-31', '+%-d %_d %^a %#b %10Y %05d'],
          ['-I', '-d', '2024-05-06 07:08:09'], ['-Iseconds', '-d', '2024-05-06 07:08:09'], ['-R', '-d', '2024-05-06 07:08:09'], ['--rfc-3339=ns', '-d', '2024-05-06 07:08:09.123456789'],
          ['-d', 'garbage'], ['-d', '2024-02-30'], ['+%s', '-d', '1970-01-02'], ['-d', '12/25/2023', '+%F'], ['-d', 'Jan 5 2020', '+%F'], ['-r', 't.txt', '+%F'], ['-d', '10:20', '+%T'],
          ['-d', '2024-06-01 12:00 +0900', '+%F %T %z'], ['-d', 'TZ="Asia/Tokyo" 2024-06-01 12:00', '+%F %T %z'], ['--date=@1700000000', '+%F %T']]:
    check('date', a)
for a in [['-i', 'A=1', 'printenv', 'A'], ['-u', 'HOME', 'printenv', 'HOME'], ['-0', '-i', 'A=1'], ['-i', 'A=1', 'B=2'], ['-C', '/', 'pwd'], ['--', 'echo', 'x'], ['-S', 'echo a b'], ['-i', '-S', 'A=1 printenv A']]:
    check('env', a)
for a in [['a b', 'c'], ['-q', 'x'], [], ['-n', 'a']]:
    check('yes' if False else 'echo', a)
for a in [[], ['-s'], ['-r'], ['-n'], ['-m'], ['-p'], ['-i'], ['-o'], ['-a']]:
    check('uname', a)
for a in [['f/a', 'f/b b'], ['-b', 'f/a', 'f/a'], ['-l', 'f/a', 'f/b b'], ['-s', 'f/a', 'f/b b'], ['f/a', 'f/a'], ['-i', '1', 'f/a', 'f/b b']]:
    check('cmp', a)
for a in [['t.txt'], ['n.txt', 't.txt'], ['-c', 'f/a'], ['--check', 'x'], ['-b', 't.txt'], ['--tag', 't.txt']]:
    for tool in ['md5sum', 'sha1sum', 'sha256sum', 'sha512sum', 'sha224sum', 'sha384sum', 'cksum', 'b2sum']:
        check(tool, a)
for a in [['t.txt'], ['-d', 't.txt'], ['-w', '10', 't.txt'], ['-i', 't.txt']]:
    check('base64', a)
    check('base32', a)
for a in [['-n', '5', 't.txt'], ['-n', '3', '-e', 'a', 'b', 'c'], ['-i', '1-5']] if False else []:
    check('shuf', a)
for a in [['-A', 'x', 't.txt'], ['-t', 'x1', 't.txt'], ['-c', 't.txt'], ['-j', '3', '-N', '5', 't.txt'], ['-t', 'a', '-An', 't.txt'], ['-v', 't.txt'], ['-w', '8', 't.txt'], ['-s', '3', '-N', '8', 't.txt'],
          ['-x', 't.txt'], ['-t', 'u2', '-N', '8', 't.txt'], ['-t', 'f4', '-N', '8', 't.txt'], ['--endian=big', '-t', 'x2', '-N', '8', 't.txt'], ['-a', '-N', '8', 't.txt']]:
    check('od', a)
for a in [['-n', 'f/a'], ['-s', '3', 't.txt'], ['-b', 't.txt'], ['-a', 't.txt'], ['-w', '10', 't.txt']] if False else []:
    check('hexdump', a)
for a in [['-m', 'bad', 'q4']]:
    check('mkdir', a)
for a in [['-s', '3', 't.txt', 'pre_'], ['-l', '2', 't.txt'], ['-b', '10', 't.txt'], ['-n', '2', 't.txt'], ['-d', '-l', '3', 't.txt'], ['--additional-suffix=.x', '-l', '3', 't.txt']] if False else []:
    check('split', a)
for a in [['-t', 'x'], ['-u', 't.txt'], ['--version']] if False else []:
    check('mktemp', a)
for a in [['3', 'f/a'], ['-d', '1', 'f/a']] if False else []:
    check('dd', a)
for a in [['-s', '3'], ['1'], ['-s'], ['abc'], ['0.01']] if False else []:
    check('sleep', a)
for a in [['-t', '1', 'f/a']] if False else []:
    check('tee', a)
for a in [['--', '-h'], ['-v']]:
    check('true', a)
    check('false', a)
for a in [['+2', 't.txt'], ['-w', '30', 't.txt'], ['-s', 't.txt'], ['-u', 't.txt'], ['-t', '-w', '40', 't.txt']]:
    check('fmt', a)
for a in [['-n', 't.txt'], ['-f', '2', 't.txt'], ['-c', 't.txt']] if False else []:
    check('column', a)
for a in [['-l', 'f/a'], ['-d', '%s', 'f/a']] if False else []:
    check('lsattr', a)
for a in [['-n', '5', 't.txt'], ['--total=a', 't.txt']] if False else []:
    check('split', a)
for a in [['-n', 'a', '1', '2'], ['--to=si', '1000000'], ['--to=iec', '4096'], ['--from=si', '2K'], ['--to=iec-i', '2048'], ['--round=up', '--to=si', '1500'], ['--grouping', '1234567'],
          ['--padding=10', '5'], ['--header', '--to=si'] if False else ['--suffix=B', '--to=si', '12345']]:
    check('numfmt', a)
for a in [['t.txt', 't.txt'], ['-1', 'dup.txt', 'dup.txt'], ['-t', ',', '-j', '1', 'csv.txt', 'csv.txt'], ['-a1', 't.txt', 'dup.txt'], ['-v1', 't.txt', 'dup.txt']]:
    check('join', a)
for a in [['-a', '3', 't.txt'], ['2', 't.txt'], ['-s', 'banana', 't.txt'], ['-n', 'banana', 't.txt'], ['-q', 'banana', 't.txt']] if False else []:
    check('csplit', a)
for a in [['6'], ['10'], ['-1'], ['100']] if False else []:
    check('factor', a)
for a in [['12'], ['17'], ['9223372036854775807'], ['1'], ['0'], ['-1'], ['abc'], ['100', '7'], ['18446744073709551615'], ['1000000007']]:
    check('factor', a)
for a in [['a', 'b'], ['-r', 'a'], ['--version']] if False else []:
    check('logname', a)
for a in [['t.txt'], ['-c', 't.txt'], ['-r', 't.txt']] if False else []:
    check('sum', a)
for a in [['-r', 't.txt'], ['t.txt']]:
    check('sum', a)
for a in [['f'], ['-p', 'a/b'], ['-P', 'a/b']]:
    check('pathchk', a)
for a in [['-d', '=', 'a=b'], ['t.txt']] if False else []:
    check('tsort', a)
check('tsort', [], b'a b\nb c\nc a\nd d\n')
check('tsort', [], b'1 2\n2 3\n')
for a in [['-e', '5', 'x'], ['-t'], ['-b', '7']] if False else []:
    check('yes', a)
for a in [['-s', '10', 't.txt'], ['-c', 't.txt']] if False else []:
    check('pr', a)
for a in [['t.txt'], ['-h', 'HDR', 't.txt'], ['-n', 't.txt'], ['-2', 't.txt'], ['-l', '10', 't.txt'], ['-t', 't.txt'], ['-w', '40', '-2', 't.txt'], ['-m', 't.txt', 'n.txt'], ['-d', 't.txt'], ['-o', '4', 't.txt'], ['-J', 't.txt']]:
    check('pr', a)
for a in [['-a', 'a', 'f/a'], ['-s', '3', 't.txt']] if False else []:
    check('shred', a)
for a in [['-e', 'a', '-e', 'b'], ['-n', '2', '-e', 'a', 'b', 'c'], ['-i', '1-3', '-n', '2'] if False else ['-z', '-e', 'a']]:
    check('shuf', a if False else [x for x in a])
for a in [['-b', '--', 'x']] if False else []:
    check('install', a)
for a in [['f/a', 'f/sub'], ['-n', 'f/a', 'f/a']] if False else []:
    check('ln', a)
for a in [['-p', 'f/sub', 'f/sub/z']] if False else []:
    check('mkdir', a)
for a in [['t.txt'], ['-b', 't.txt'], ['-v', 't.txt']] if False else []:
    check('strings', a)
for a in [['+5', 't.txt'], ['-1', 't.txt']] if False else []:
    check('expand', a)
for a in [[], ['-t', '4'], ['-t', '2,6'], ['-i'], ['-t', '4,+2']]:
    check('expand', a + ['t.txt'])
    check('unexpand', a + ['t.txt'])
    check('unexpand', ['-a'] + a + ['t.txt'])
for a in [['-e', 'x', 't.txt'], ['--version']] if False else []:
    check('sed', a)
for a in [['-d', ' ', 't.txt'], ['-d', ' ', '-f', '1', 't.txt']] if False else []:
    check('cut', a)
for a in [['-u'], ['-s'], []]:
    check('timeout' if False else 'nproc', a)
for a in [['-a', 'a b'], ['-n', '1']] if False else []:
    check('xargs', a)
for a in [['f', '-type', 'f'], ['f', '-name', '*.txt'], ['f', '-maxdepth', '1'], ['f', '-mindepth', '1', '-maxdepth', '1', '-printf', '%f %y %m\\n'], ['f', '-type', 'd'], ['f', '-size', '+0'],
          ['f', '-name', 'a', '-o', '-name', 'b*'], ['f', '!', '-name', 'a'], ['f', '-empty'], ['f', '-perm', '640'], ['f', '-perm', '-600'], ['f', '-newer', 'f/a'], ['f', '-path', '*sub*'],
          ['f', '-regex', '.*/a'], ['f', '-iname', 'A'], ['f', '-type', 'l'], ['f', '-links', '1'], ['f', '-printf', '%p %s %M\\n'], ['f', '-print0'], ['f', '-name', 'a', '-exec', 'echo', '{}', ';'],
          ['f', '-name', '*', '-exec', 'echo', '{}', '+'], ['f', '-prune', '-o', '-print'], ['f', '-depth'], ['f', '-name', 'nomatch'], ['f', '-user', 'root'], ['f', '-ls'], ['f', '-fprint', '/dev/stdout'],
          ['f', '-printf', '%h|%f|%P|%d|%l|%i\\n'], ['f', '-name', '*sub*', '-printf', '%T@\\n'], ['f', '(', '-name', 'a', '-o', '-name', 'link', ')', '-print'], ['-L', 'f', '-type', 'f'], ['f', '-xtype', 'f']]:
    check('find', a)
# ---- util-linux hexdump
w('h.bin', bytes(range(256)) + b'hello world\n\x00\xff' * 7)
for a in [[], ['-C'], ['-b'], ['-c'], ['-d'], ['-o'], ['-x'], ['-v', '-C'], ['-n', '20', '-C'], ['-s', '10', '-n', '40', '-C'], ['-e', '"%02x "'], ['-e', '16/1 "%02x " "\\n"'],
          ['-e', '"%07_ax  " 8/2 "%04x " "\\n"'], ['-e', '/1 "%_p"'], ['-C', '-s', '300'], ['-c', '-n', '5'], ['-n', '0'], ['-C', '-s', '99999'], ['-e', '1/4 "%d\\n"'], ['-v', '-e', '8/1 "%3d"', '-e', '"\\n"'],
          ['-e', '"%_u "'], ['-e', '"%_c"'], ['-e', '4/1 "%_u " "\\n"'], ['-C', '-L'] if False else ['--no-squeezing', '-C']]:
    check('hexdump', a + ['h.bin'])
w('hz.bin', b'\x00' * 100 + b'abc' + b'\x00' * 100)
for a in [['-C'], ['-C', '-v'], ['-x'], ['-b']]:
    check('hexdump', a + ['hz.bin'])
check('hexdump', ['-C'], b'')
check('hexdump', ['-C'], b'a')
check('hexdump', ['-C', 'nonexistent'])
check('hexdump', ['-Z'])
print(f'{total - fail}/{total} option-matrix comparisons passed')
shutil.rmtree(work, ignore_errors=True)
sys.exit(1 if fail else 0)
