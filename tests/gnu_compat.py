"""Differential checks against installed GNU tools, in the C locale."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
checks = 0
failures = []
env = dict(os.environ, LC_ALL='C', TZ='UTC')
def compare(command, args=(), data=b'', stderr=False):
    global checks
    a = subprocess.run([binary, command, *args], input=data, capture_output=True, env=env, timeout=5)
    b = subprocess.run([command, *args], input=data, capture_output=True, env=env, timeout=5)
    checks += 1
    if (a.returncode, a.stdout) != (b.returncode, b.stdout) or (stderr and a.stderr != b.stderr):
        failures.append((command, args, data[:100], (a.returncode, a.stdout, a.stderr), (b.returncode, b.stdout, b.stderr)))

sample = b'alpha\nBeta\nabc 123\nabab\naaa\nword words sword\nlast'
for pattern in ['', '^$', '^a.*a$', r'[[:digit:]]\{2,3\}', r'\(ab\)\1', r'a\|Beta', '[', r'\<word\>']:
    compare('grep', [pattern], sample)
for flags, pattern in [('-E', '^(alpha|Beta)$'), ('-Eo', '[[:alpha:]]+'),
                        ('-Fo', 'ab'), ('-Fin', 'BETA'), ('-w', 'word'),
                        ('-x', 'alpha'), ('-v', 'a'), ('-c', 'a'), ('-q', 'a'),
                        ('-n', 'a'), ('-b', 'a'), ('-m1', 'a'), ('-C1', '123'),
                        ('-A1', 'alpha'), ('-B2', 'last'), ('-z', 'a'),
                        ('-o', 'a*'), ('-o', '^'), ('-F', '^a')]:
    compare('grep', [flags, pattern], sample)
compare('grep', ['-e', 'Beta', '-e', 'last'], sample)
compare('grep', ['--regexp=Beta', '--line-number'], sample)
compare('grep', ['-n', '--', '-foo'], b'-foo\nbar\n')
compare('grep', ['-a', 'a'], b'a\x00b\n')
compare('grep', ['-I', 'a'], b'a\x00b\n')
with tempfile.TemporaryDirectory() as d:
    root = Path(d)
    a, b, patterns = (root / name for name in ['a', 'b', 'patterns'])
    a.write_bytes(sample)
    b.write_bytes(b'Beta\nnomatch\n')
    patterns.write_bytes(b'^Beta$\nlast\n')
    for flags in [[], ['-n'], ['-h'], ['-H'], ['-l'], ['-L'], ['-c'], ['-Zl'], ['-C1']]:
        compare('grep', [*flags, 'Beta', str(a), str(b)])
    compare('grep', ['-f', str(patterns), str(a)])
    patterns.write_bytes(b'')
    compare('grep', ['-f', str(patterns), str(a)])
    (root / 'sub').mkdir()
    (root / 'sub' / 'c').write_bytes(b'Beta\n')
    compare('grep', ['-rn', 'Beta', str(root)])
    compare('grep', ['-q', 'Beta', str(root / 'missing'), str(a)])

for script in ['', 's/a/A/', 's/a/A/g', r's/\(ab\)/[\1]/g', 's/[[:digit:]]/X/g',
               's/^/prefix /', 's/$/ END/', 's/a*/X/g', 's/ab*/X/g',
               's/a/X/2', 's/a/X/2g', 's/alpha/[&]/', 's|alpha|a/b|',
               '1d', '2,4d', '/Beta/,/abab/d', '2,$p', '$d', '2!d',
               '/Beta/p', '1,3{ s/a/A/g; p; }', 'h;g', '1h;2g',
               '1h;2H;3g', '1h;2x', r'N;s/\n/ /', 'N;P;D', 'n;p',
               '1i before', '2a after', '2c changed', '2,4c changed',
               ':again;s/aa/a/;t again', '/Beta/b done;s/a/A/g;:done',
               '=', 'y/ab/AB/', '2q', 'z']:
    compare('sed', ['-e', script], sample)
    compare('sed', ['-n', '-e', script], sample)
compare('sed', ['-E', 's/(alpha|Beta)/[\\1]/g'], sample)
compare('sed', ['-e', 's/alpha/A/', '-e', 's/Beta/B/'], sample)
compare('sed', ['-z', 's/a/A/g'], b'a\x00b\x00')
compare('sed', ['-n', '/[/p'], sample)
with tempfile.TemporaryDirectory() as d:
    root = Path(d)
    for program, filename in [(binary, 'ours'), ('sed', 'gnu')]:
        path = root / filename
        path.write_bytes(sample)
        command = [program, 'sed'] if program == binary else [program]
        result = subprocess.run([*command, '-i.bak', 's/a/A/g', str(path)], capture_output=True, env=env)
        assert result.returncode == 0, result.stderr
    checks += 1
    assert (root / 'ours').read_bytes() == (root / 'gnu').read_bytes()
    assert (root / 'ours.bak').read_bytes() == sample

for command in ['head', 'tail']:
    for data in [b'', b'a', b'a\nb\nc', b'a\nb\nc\n', b'a\x00b\x00c']:
        for args in [[], ['-n', '0'], ['-n', '1'], ['-n', '2'], ['-n', '-1'], ['-n', '+2'],
                     ['-c', '0'], ['-c', '2'], ['-c', '-2'], ['-c', '+2'], ['-z', '-n', '2'],
                     ['--bytes=1K'], ['--lines=bad'], ['--bad']]:
            compare(command, args, data)
for args in [['a-z', 'A-Z'], ['[:lower:]', '[:upper:]'], ['-d', 'a'], ['-s', 'a'],
             ['-s', '[:space:]'], ['-cd', 'a-z'], ['-ds', 'a', 'b'], ['-cs', 'a-z', '_'],
             ['-t', 'abc', 'X'], ['abc', '[x*]'], [r'\000', 'X'], ['-d', 'a'],
             ['-d', r'\000'], ['z-a', 'x'], ['-d'], ['abc', ''], ['-s', 'a', 'b']]:
    compare('tr', args, b'aabbbcc ddd\n\taa\x00bb\n')
for data in [b'', b'a\nb\n\nc', bytes(range(256)), b'\n\n\nhello\tworld\n\n']:
    for flags in [[], ['-n'], ['-b'], ['-s'], ['-E'], ['-T'], ['-v'], ['-A'], ['-bns']]:
        compare('cat', flags, data)
    for flags in [[], ['-l'], ['-w'], ['-c'], ['-m'], ['-L'], ['-lwmcL']]:
        compare('wc', flags, data)
for args in [[], ['!'], ['!',''], ['!','!'], ['-n','x'], ['-z',''],
             ['a','=','b'], ['2','-gt','1'], ['bad','-eq','0'], ['-Q','x'],
             ['999999999999999999999999999999','-gt','2'],
             ['(','a','=','a',')','-a','!',''], ['a','-o','','-a',''],
             ['!','a','=','b'], ['a','bogus','b'], ['-e','/'], ['-d','/'],
             ['-c','/dev/null'], ['-t','-1']]:
    compare('test', args)
for args in [[], [']'], ['x',']'], ['x'], ['1','-eq','1',']']]:
    compare('[', args)
for args in [['%s\\n', 'a', 'b'], ['%05d %x %o\\n', '12', '255', '8'],
             ['%s %d %c', 'hello'], ['%10.3s', 'abcdef'], ['%*.*f', '10', '2', '1.25'],
             ['%b', r'a\000b\n'], ['%brest', r'a\cignored'], [r'\u65e5\n'],
             ['%d', "'A"], ['%u', '-1'], ['%d', '08'], ['%f', 'bad'], ['%'],
             ['%c', ''], ['%.3g', '1234.5'], [r'\x41\101'], ['abc', 'ignored']]:
    compare('printf', args)
for command in ['basename', 'dirname']:
    for value in ['', '/', '//', '///', '//a', 'a//b', 'a///b//', '///a//b']:
        compare(command, [value])
compare('basename', ['-a', '-s', '.txt', 'a.txt', 'b.txt'])
compare('dirname', ['-z', '/a/b', 'a', '/'])
for args in [['-b','1,3-4'], ['-c','2-'], ['-f','1,3'], ['-d',':','-f','2'],
             ['-sd:', '-f','2-'], ['-b','1,3','--output-delimiter=:'],
             ['-f','2','--complement'], ['-b','0'], ['-b','3-1'], ['-z','-f','1']]:
    compare('cut', args, b'a:b:c\nx\ta\tb\nlast')
for loc in ['C', 'C.UTF-8']:
    env['LC_ALL'] = loc
    for flags in [[], ['-m'], ['-w'], ['-L'], ['-clmL']]:
        compare('wc', flags, '日本 語\n'.encode())
    compare('wc', ['-m'], b'\xffa')
env['LC_ALL'] = 'C'
with tempfile.TemporaryDirectory() as d:
    root = Path(d)
    (root/'dir').mkdir()
    (root/'dir'/'file').write_bytes(b'x')
    (root/'link').symlink_to('dir')
    (root/'dangling').symlink_to('absent')
    for command in ['readlink', 'realpath']:
        for name in ['dir/file', 'link/file', 'dangling', 'missing', 'missing/a', 'dir/../link/file', 'dir/file/a']:
            for flags in [[], ['-f'], ['-e'], ['-m'], ['-z']]:
                compare(command, [*flags, str(root/name)])
numbers = b' 2x\n-10.5\n1.25 foo\n1.2 bar\n-0\n+3\n2\n0002\n0.1\n0.01\n'
for flags in [[], ['-n'], ['-nr'], ['-nu'], ['-g'], ['-r'], ['-f'], ['-b'], ['-d'],
              ['-s'], ['-z'], ['-k1,1n'], ['-k2,2'], ['-k1.2,1.3'],
              ['-c'], ['-C'], ['-c','-u'], ['-t',':','-k2,2n']]:
    compare('sort', flags, numbers)
for flags in [[], ['-c'], ['-d'], ['-u'], ['-du'], ['-i'], ['-f1'], ['-s1'], ['-w1'], ['-z']]:
    compare('uniq', flags, b'a\na\nA\nb\nb\n1 x\n2 x\nlast')
for flags in [[], ['-e'], ['-n'], ['-ne']]:
    for value in [r'a\cb', r'\033\x41', r'\123', r'\u65e5', r'\x']:
        compare('echo', [*flags, value, 'next'])
with tempfile.TemporaryDirectory() as d:
    root = Path(d)
    a, b = root/'a', root/'b'
    for left, right in [(b'', b''), (b'a\nb\nc\nd\ne\n', b'a\nB\nc\nd\nE\n'),
                        (b'a\nb\n', b'x\na\nb\ny\n'), (b'a', b'b'),
                        (b'a\na\nb\n', b'a\nb\nb\n'), (b'A  B\r\n', b'a b\n')]:
        a.write_bytes(left); b.write_bytes(right)
        for flags in [[], ['-q'], ['-s'], ['-u','-L','a','-L','b'],
                      ['-U0','-L','a','-L','b'], ['-U1','-L','a','-L','b'], ['-iw'], ['-ib']]:
            compare('diff', [*flags, str(a), str(b)])
for script in [
    'x=hello; printf "%s\\n" "$x"',
    'x="a b"; printf "<%s>\\n" $x',
    'x="a b"; printf "<%s>\\n" "$x"',
    'unset CMDBOX_TEST_LOCAL; CMDBOX_TEST_LOCAL=x; printenv CMDBOX_TEST_LOCAL; echo done',
    'CMDBOX_TEST_LOCAL=x; export CMDBOX_TEST_LOCAL; printenv CMDBOX_TEST_LOCAL',
    'export CMDBOX_TEST_LOCAL=x; unset CMDBOX_TEST_LOCAL; printenv CMDBOX_TEST_LOCAL; echo done',
    'unset x; echo "${x:-default}"; x=; echo "${x-default}"; echo "${x:-default}"',
    'unset x; echo "${x:=set}"; echo "$x"; echo "${x:+yes}"',
    'x=/a/b.txt; echo "${x##*/} ${x%.txt} ${#x}"',
    'echo "$0 $# $1 $2"; shift; echo "$# $1"',
    'printf "<%s>\\n" "$@"',
    'echo "$((1 + 2 * 3))"',
    'printf "%s\\n" "a\\b"',
    'for x in a b; do echo "$x"; done',
    'if test 2 -gt 1; then echo yes; else echo no; fi',
    'exec printf "done\\n"; echo unreachable',
]:
    compare('sh', ['-c', script, 'name', 'a b', 'c'])
for args in [['3'], ['1','0.5','2'], ['-s',',','1','3'], ['-w','8','11'],
             ['-f','%.2f','1','0.5','2'], ['3','-1','1'], ['1','0','2'], ['nan'],
             ['-w','1','0.2','2'], ['-s','x','0'], ['--','-2','2']]:
    compare('seq', args)
for args in [['0'], ['0s'], ['0m','0h','0d'], ['0.000001'], ['-1'], ['bad'], ['0bad'], ['-0.1'], ['0.2bad']]:
    compare('sleep', args)
for script in [
    'f() { echo "$# $1"; return 7; echo bad; }; f hello; echo "status=$?"',
    'f() { printf "<%s>\\n" "$@"; }; f "a b" c; echo "$# $1"',
    'for x in a b; do echo "$x"; break; echo bad; done; echo done',
    'set -- a "b c"; echo "$#"; printf "<%s>\\n" "$@"',
    'umask 027; umask',
]:
    compare('sh', ['-c', script, 'name', 'original'])
with tempfile.TemporaryDirectory() as d:
    root = Path(d)
    for program, name in [(binary, 'ours'), ('sh', 'gnu')]:
        path = root/name
        command = [program,'sh'] if program == binary else [program]
        result = subprocess.run([*command,'-c','echo first > "$1"; echo second >> "$1"; echo stdout','name',str(path)], capture_output=True,env=env)
        assert result.returncode == 0 and result.stdout == b'stdout\n', result
    checks += 1
    assert (root/'ours').read_bytes() == (root/'gnu').read_bytes() == b'first\nsecond\n'
with tempfile.TemporaryDirectory() as d:
    root = Path(d)
    (root/'z').write_bytes(b'last')
    (root/'a').write_bytes(b'first')
    (root/'.hidden').write_bytes(b'hidden')
    (root/'dir').mkdir()
    (root/'dir'/'file').write_bytes(b'nested')
    (root/'link').symlink_to('a')
    (root/'dirlink').symlink_to('dir')
    for path in [root, *root.rglob('*')]:
        os.utime(path, ns=(1700000000000000000,1700000000000000000), follow_symlinks=False)
    for flags in [[], ['-1'], ['-a'], ['-A'], ['-r'], ['-S'], ['-F'], ['-p'], ['-R'], ['-d'],
                  ['-l'], ['-ln'], ['-la'], ['-lg'], ['-lo'], ['-li'],
                  ['-l','--time-style=long-iso'], ['-l','--time-style=full-iso']]:
        compare('ls', [*flags, str(root)])
    for flags in [[], ['-l'], ['-d'], ['-L']]:
        compare('ls', [*flags, str(root/'dirlink')])
for script in [
    'case "$1" in a*) echo a;; b|c) echo bc;; *) echo other;; esac; echo done',
    'case x in a) echo bad;; x) case y in y) echo nested;; esac;; esac',
    'case "a*" in "a*") echo literal;; *) echo bad;; esac',
    'f() {\n echo function\n}\nf',
    'echo error >&2; echo normal',
    'exec 3>&1; echo third >&3; exec 3>&-; echo normal',
]:
    compare('sh', ['-c', script, 'name', 'abc'], stderr=True)
with tempfile.TemporaryDirectory() as d:
    root=Path(d)
    for program, name in [(binary,'ours'),('sh','gnu')]:
        path=root/name
        command=[program,'sh'] if program == binary else [program]
        result=subprocess.run([*command,'-c','echo first 2>&1 > "$1"; echo second > "$1" 2>&1; : > "$2"; echo normal','name',str(path),str(path)+'.empty'],capture_output=True,env=env)
        assert result.returncode == 0 and result.stdout == b'normal\n', result
        assert path.read_bytes() == b'second\n'
        assert Path(str(path)+'.empty').read_bytes() == b''
    checks += 1
for script in [
    'false & p=$!; sleep 0.01; wait "$p"; echo "status=$?"',
    'sh -c "exit 7" & p=$!; true; wait "$p"; echo "status=$?"',
    'true | false & p=$!; wait "$p"; echo "status=$?"',
    'wait 999999; echo "status=$?"',
]:
    compare('sh', ['-c',script])
with tempfile.TemporaryDirectory() as d:
    root=Path(d)
    script=root/'source'
    script.write_text('export CMDBOX_SOURCED=yes\necho "$0 $# $1"\nreturn 3\necho bad\n')
    compare('sh', ['-c','. "$1" hello; echo "status=$?"; printenv CMDBOX_SOURCED','name',str(script)])
for failure in failures:
    print('FAIL:', repr(failure))
print(f'{checks-len(failures)}/{checks} GNU compatibility checks passed')
raise SystemExit(bool(failures))
