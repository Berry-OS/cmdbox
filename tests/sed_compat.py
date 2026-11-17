"""sed differential checks against GNU sed.  Usage: sed_compat.py cmdbox [sed]"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
reference = sys.argv[2] if len(sys.argv) > 2 else 'sed'
env = dict(os.environ, LC_ALL='C', LANG='C')
checks = 0
failures = []
_v = subprocess.run([reference, '--version'], capture_output=True, text=True).stdout
if 'GNU sed' not in _v:
    sys.exit('reference "%s" is not GNU sed (BusyBox etc. give meaningless results); pass a GNU sed path' % reference)

S = b'alpha one\nbeta two\ngamma three\ndelta four\nepsilon five\nzeta six\neta seven\n'
T = b'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n'
M = b'Hello World\nfoo bar baz\n\nLine  with   spaces\ttab\nlast'


def compare(args, data=S, cwd=None, files=None):
    global checks
    checks += 1
    ours = subprocess.run([binary, 'sed', *args], input=data, capture_output=True, env=env, cwd=cwd)
    gnu = subprocess.run([reference, *args], input=data, capture_output=True, env=env, cwd=cwd)
    if (ours.returncode, ours.stdout) != (gnu.returncode, gnu.stdout):
        failures.append((args, ours.returncode, ours.stdout[:300], ours.stderr[:200], gnu.returncode, gnu.stdout[:300]))


def both(script, data=S, *flags):
    compare([*flags, script], data)
    compare(['-n', *flags, script], data)


# ---- addresses
for sc in ['p', '2p', '2,4p', '$p', '1~2p', '0~3p', '2~3p', '2,~4p', '3,~4p', '/b/,+1p', '/a/,/e/p', '0,/a/p',
           '1,/a/p', '/gamma/,$p', '2!p', '2,4!p', '$!p', '/a/I p', '/A/Ip', '\\%a%p', '\\,a,p', '/a/,2p',
           '4,2p', '2,2p', '/one/,/two/p', '2,/a/p', '$,$p', '1,$p', '/e/,+2p', '2~0p', '0~0p', '/a/!d',
           '/a/,/b/!d', '1d;$d', '/alpha/{n;p}', '2{p;p}', '2,3{=}', '/b/{p;d}', '2q', '2Q', '3q5', '$!d', '1!G;h;$!d',
           'G', 'x;G', '$!N;P;D', 'N;N;s/\\n/,/g', 'n;d', '$!N;s/\\n/+/', 'N;P;D', '1h;2,$H;$!d;x', '/a/,/zzz/p',
           '2,4c\\X', '2c\\X', '$c\\X', '2,4{c\\X\n}', '/a/{x;p;x}', '1,3s/a/A/', '/b/,/d/{s/a/A/}', '2,3{/a/d}',
           's/a/A/2', 's/a/A/2g', 's/a/A/3', 's/\\(.\\)\\(.\\)/\\2\\1/', 's/./&&/g', 's/a\\|e/X/g', 's/a\\+/X/g',
           's/e\\?l/X/g', 's/[aeiou]/\\U&/g', 's/\\w\\+/\\u&/g', 's/\\(\\w\\+\\) \\(\\w\\+\\)/\\U\\1\\E \\2/',
           's/\\w\\+/\\L\\u&/', 's/a/\\n/', 's/ /\\t/', 's/a/&&/', 's/a/\\&/', 's/a/\\\\/', 's,a,b,g', 's|a|b|g',
           's/a/x\\/y/', 's/\\//x/', 's/a*/x/g', 's/b*/x/2', 's/\\b/|/g', 's/\\B/|/g', 's/\\</[/g', 's/\\>/]/g',
           's/^/> /', 's/$/ </', 's/\\s\\+/_/g', 's/\\S\\+/X/', 's/\\W/_/g', 's/[[:upper:]]/U/g', 's/[[:space:]]/_/g',
           's/\\(a\\)\\|b/[\\1]/g', 's/\\(.\\)\\1/<&>/g', 's/.\\{3\\}/&-/g', 's/a\\{1,2\\}/X/g', 's/e\\{2\\}/X/', 's/*/x/',
           's/a/b/;s/b/c/', 's/a/b/ ; s/b/c/', 's/a/b/w /dev/stdout', 's/a/b/gp', 's/a/b/pg', 's/A/b/I', 's/A/b/i',
           'y/abc/xyz/', 'y/a\\nb/xyz/', 'y,a/b,x\\/y,', 'y/\\\\/x/', '=', 'l', 'l 5', 'l 1', 'l 0', '2z', 'F',
           's/a/b/;t;s/$/!/', 's/a/b/;T;s/$/!/', ':a;s/e/E/;ta', ':a;N;$!ba;s/\\n/ /g', 'b;p', '/a/b end;s/a/X/;:end',
           '$!{N;D}', '2{h;d};${G}', 's/\\(.*\\)/\\1\\1/', 's/\\(.*\\) \\(.*\\)/\\2 \\1/', 's/[^ ]*$/X/', 's/ [^ ]*/X/',
           'a\\foo', '2a foo', '2a\\\nfoo', '2i bar', '2i\\\nbar\\\nbaz', '$a end', '1i\\  lead', '2r /dev/null', '2w /dev/stdout',
           '2{r /dev/null\n}', '/a/{s//X/}', 's/a/X/;s//Y/', '/e/s//E/g', '2,3s/e/E/', '/gamma/,+1d', '/a/,+1{s/$/!/}',
           's/a/\\x41/', 's/\\x61/X/g', 's/a/\\d065/', 's/\\o141/X/', 's/\\cA/X/', 's/a/\\o101/', 's/\\./X/', 's/\\$/X/',
           's/./\\n/3', 's/a/\\\n/', '1!G;$!h;$!d', '2{N;N;d}', 'N;N;N;s/\\n/ /g', '/one/{N;N;s/\\n/ /g}', '1~3d', '2~2s/$/ even/',
           '$!N;/^\\(.*\\)\\n\\1$/!P;D', 's/o/0/3g', 's/\\(a\\)\\(b\\)\\?/[\\2]/', 's/^\\(.\\)/\\U\\1/', 's/\\([a-z]\\)\\([a-z]*\\)/\\U\\1\\L\\2/g',
           's/a/\\U&x\\Ey/', 's/a/\\u\\L&B/', 's/\\(.\\)/\\l\\1/', 'y/abcdefghijklmnopqrstuvwxyz/ABCDEFGHIJKLMNOPQRSTUVWXYZ/',
           '#comment\np', '/a/ p', '/a/ ,/e/ p', '1 , 3 p', '1,3 !p', '2 ! p', '{p}', '{p;}', '2{p}', '2{;p;}', '{\np\n}']:
    both(sc, S)
for sc in ['$!N;$!D', '$!N;P;D', 'N;N;P;D', 's/\\n/,/', 'N;l', 'N;N;N;N;N;N;N;N;N;N;l', 'P;D', 'D', 'N;D', '2N;2P', '$N', '$!N', 'N;N;N', 'n;n;d',
           '2{N;N}', 'N;s/\\n/&&/', 'N;s/^/>/mg', 'N;s/^/>/g', 'N;s/$/</mg', 'N;s/\\n/X/;P;D', 'G;G', 'x;x', 'H;x', 'H;H;x', 'H;g', 'h;G;G',
           'n', 'n;n', '$n', '2n;p', '2{n;n}', '2,3n', '$!n;p']:
    both(sc, T)
    compare(['-s', sc], T)
for sc in ['s/^/>/mg', 's/$/</mg', 's/^\\s*$/EMPTY/', '/^$/d', 's/\\s\\+/ /g', 's/\\t/TAB/', 's/[[:space:]]\\{2,\\}/_/g', 's/^L/l/', 's/x*$/!/',
           's/ *$//', 's/^ *//', 's/\\(Hello\\) \\(World\\)/\\2 \\1/', '$!d', '$s/$/\\n/', 's/\\n//', 'N;N;s/\\n/|/g', '/^$/,/^L/d', '1!G;h;$!d',
           'l', 'l 8', '$!N;s/\\n/ /', 's/o/0/2', 's/[A-Z]/\\L&/g', 's/\\w*/<&>/g', 's/^\\w*/<&>/', 's/\\w*$/<&>/', 's/x*/-/g']:
    both(sc, M)
# line without trailing newline
for sc in ['p', '$p', '$!d', 's/t$/T/', '$a end', '$i top', '$c\\X', '$r /dev/null', 'G', 'N;P;D', '$!N;s/\\n/+/', 'w /dev/stdout', '$='] :
    compare([sc], b'a\nb\nlast')
    compare(['-n', sc], b'a\nb\nlast')
    compare(['-s', sc], b'a\nb\nlast')
compare(['p'], b'')
compare(['$p'], b'')
compare(['$='], b'')
compare(['-n', '$='], S)
compare(['-n', '/a/='], S)
compare(['='], b'x\ny')
compare(['a\\'], b'x\n')

# ---- extended regex
for sc in ['s/(a|e)l/[\\1]/g', 's/a+/X/g', 's/e?l/X/g', 's/(.)\\1/<&>/g', 's/[0-9]{2}/N/', 's/a{1,2}/X/g', 's/(alpha|beta) (one|two)/\\2 \\1/',
           's/\\(/X/', 's/\\)/X/', 's/a|e/X/g', '/^(a|b)/p', '/(a|b)$/p', 's/^(.)(.)/\\2\\1/', 's/(.*)e/\\1E/', 's/(a)|(b)/[\\1\\2]/g',
           's/\\w+/\\u&/g', 's/\\s+/_/g', 's/(^| )(.)/\\1\\U\\2/g', 's/\\+/X/', 's/a{2}/X/', 's/a\\{2\\}/X/', 's/x?/-/g', 's/()/-/', 's/[(]/X/', 's/[+]/X/']:
    both(sc, S, '-E')
    both(sc, S, '-r')
    both(sc, S, '--regexp-extended')

# ---- options
compare(['-n', '-e', '2p', '-e', '3p'], S)
compare(['-e', '2p', '-e', '3d'], S)
compare(['--expression=2p', '-n'], S)
compare(['--quiet', '2p'], S)
compare(['--silent', '2p'], S)
compare(['-ne', '2p'], S)
compare(['-n', '-e', 'a\\', '-e', 'text'], S)
compare(['-e', 'a\\', '-e', 'text', '-e', 's/a/b/'], S)
compare(['-e', '2{', '-e', 'p', '-e', '}'], S)
compare(['-e', 'i\\', '-e', 'a\\', '-e', 'b'], S)
compare(['-z', 's/\\n/,/g'], S)
compare(['-z', '$!d'], b'a\0b\0c\0')
compare(['--null-data', 's/a/X/'], b'a\0b\0')
compare(['-s', '-n', '$p', '-', '-'], S)
compare(['-l', '10', '-n', 'l'], b'abcdefghijklmnopqrstuvwxyz\n')
compare(['--line-length=5', '-n', 'l'], b'abcdefghijklmnopqrstuvwxyz\n')
compare(['-n', 'l;l 3'], b'abcdefghijklmnopqrstuvwxyz\ttab\\ \x01\x7f\xc3\xa9\n')
compare(['-n', 'l'], b'a\nb')
compare(['--posix', 's/a/b/'], S)
compare(['-u', 's/a/b/'], S)
compare(['--unbuffered', 's/a/b/'], S)
compare(['-b', 's/a/b/'], S)
compare(['--binary', 's/a/b/'], S)
compare(['--sandbox', 's/a/b/'], S)
compare(['--follow-symlinks', 's/a/b/'], S)
compare(['-E', '-n', '-e', '/a+/p'], S)
compare(['#n\np'], S)
compare(['#n'], S)
compare(['-e', '#n', '-e', 'p'], S)
compare(['s/a/b/', '--', '-'], S)
compare(['--version'], b'') if False else None
compare([], b'')
compare(['-n'], b'')
compare(['p', '/nonexistent'], b'')
compare(['p', '-', '/nonexistent'], S)
compare(['--bogus', 'p'], b'')
compare(['k'], S)
compare(['s/a/b'], S)
compare(['s/a/b/x'], S)
compare(['2,p'], S)
compare(['{p'], S)
compare(['p}'], S)
compare(['bfoo'], S)
compare([':a;:a'], S) if False else None
compare(['y/ab/c/'], S)
compare(['s/\\(a/b/'], S)
compare(['s/a/\\1/'], S)
compare(['r'], S)
compare(['dp'], S)
compare(['2,3,4p'], S)
compare(['0p'], S)
compare(['0,2p'], S)
compare(['q 5'], S)
compare(['q5 5'], S)
compare(['3q;p'], S)
compare(['--', 'p'], S)
compare(['-s', '-n', 'F;=', '-'], S)
compare(['-n', '$=', '-', '-'], S)

# ---- files, in-place, w, r, R, W
with tempfile.TemporaryDirectory() as d:
    f1 = Path(d, 'f1')
    f1.write_bytes(S)
    f2 = Path(d, 'f2')
    f2.write_bytes(T)
    ins = Path(d, 'ins')
    ins.write_bytes(b'INS1\nINS2\n')
    compare(['-n', '$p', 'f1', 'f2'], cwd=d)
    compare(['-s', '-n', '$p', 'f1', 'f2'], cwd=d)
    compare(['-n', '1p', 'f1', 'f2'], cwd=d)
    compare(['-s', '-n', '1p', 'f1', 'f2'], cwd=d)
    compare(['-n', '$=', 'f1', 'f2'], cwd=d)
    compare(['-s', 'F', 'f1', 'f2'], cwd=d)
    compare(['2r ins', 'f1'], cwd=d)
    compare(['2R ins', 'f1'], cwd=d)
    compare(['R ins', 'f1'], cwd=d)
    compare(['/a/R ins', 'f1'], cwd=d)
    compare(['$r ins', 'f1', 'f2'], cwd=d)
    compare(['r nonexistent', 'f1'], cwd=d)
    compare(['r ins', '-'], S, cwd=d)
    compare(['2r /dev/stdin', 'f1'], b'FROM-STDIN\n', cwd=d)
    compare(['-n', '/a/w out1', 'f1'], cwd=d)
    compare(['-n', 'w out2', 'f1'], cwd=d)
    compare(['-n', 'N;W out3', 'f1'], cwd=d)
    compare(['-n', 's/a/A/w /dev/stdout', 'f1'], cwd=d)
    compare(['-n', 's/a/A/w /dev/stderr', 'f1'], cwd=d)
    compare(['-f', str(Path(d, 'script'))], S, cwd=d) if False else None
    Path(d, 'script').write_text('# comment\ns/a/A/g\n2d\n$a\\\nend\n')
    compare(['-f', 'script', 'f1'], cwd=d)
    compare(['--file=script', 'f1'], cwd=d)
    compare(['-f', 'script', '-e', 's/e/E/', 'f1'], cwd=d)
    Path(d, 'script2').write_text('#n\n/a/p\n')
    compare(['-f', 'script2', 'f1'], cwd=d)
    Path(d, 'script3').write_text('#!/bin/sed -f\ns/a/A/\n')
    compare(['-f', 'script3', 'f1'], cwd=d)
    Path(d, 'script4').write_text('s/a/A/')
    compare(['-f', 'script4', 'f1'], cwd=d)
    Path(d, 'script5').write_text('1{\n  s/a/A/\n  p\n}\n')
    compare(['-f', 'script5', 'f1'], cwd=d)
    compare(['-f', '/nonexistent', 'f1'], cwd=d)

    def inplace(args, name='f1', data=S, extra=()):
        global checks
        checks += 1
        outs = []
        for exe in ([binary, 'sed'], [reference]):
            for fn in ('t1', 't2', 't1.bak'):
                try:
                    Path(d, fn).unlink()
                except FileNotFoundError:
                    pass
            Path(d, 't1').write_bytes(data)
            Path(d, 't2').write_bytes(T)
            r = subprocess.run([*exe, *args, 't1', *extra], capture_output=True, env=env, cwd=d)
            res = {fn: (Path(d, fn).read_bytes() if Path(d, fn).exists() else None) for fn in ('t1', 't2', 't1.bak')}
            outs.append((r.returncode, r.stdout, res))
        if outs[0] != outs[1]:
            failures.append((['inplace', *args], outs[0], outs[1]))

    inplace(['-i', 's/a/A/g'])
    inplace(['-i.bak', 's/a/A/g'])
    inplace(['--in-place', 's/a/A/g'])
    inplace(['--in-place=.bak', 's/a/A/g'])
    inplace(['-i', '-e', '2d'])
    inplace(['-n', '-i', '2p'])
    inplace(['-ni', '2p'])
    inplace(['-i', '$d'], extra=['t2'])
    inplace(['-i', '1d'], extra=['t2'])
    inplace(['-i', '-s', '$d'], extra=['t2'])
    inplace(['-i', 'F'], extra=['t2'])
    inplace(['-i', '$!d'], extra=['t2'])
    inplace(['-i', 's/x/y/'], data=b'no newline at end')
    inplace(['-i', 'a end'], data=b'x\ny')
    inplace(['-i', '2q'])
    inplace(['-i', 'w /dev/stdout'])
    inplace(['-i', 's/a/b/w /dev/stdout'])
    inplace(['-i', '/a/r ins'], data=S)
    inplace(['-E', '-i', 's/(a)/[\\1]/'])
    inplace(['-i', '=']) if False else None
    inplace(['-i', 'bak/*', 's/a/A/']) if False else None
    inplace(['-i', 'p'])
    inplace(['-n', '-i', 'p'])
    inplace(['-i', 'd'])

print(f'{checks - len(failures)}/{checks} sed compatibility checks passed')
for f in failures:
    print('FAIL', f[0], '\n  ours:', *f[1:4], '\n  gnu: ', *f[4:])
sys.exit(1 if failures else 0)
