"""passwd / chpasswd on a scratch root (-R): file edits, aging fields, status output and
hashes verified with perl's crypt().  usage: passwd_compat.py <cmdbox>"""
import os, shutil, subprocess, sys, tempfile
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
have_perl = shutil.which('perl') is not None
fails = []
n = 0

def run(name, args, inp=b''):
    return subprocess.run(['bash', '-c', 'exec -a "$0" "$1" "${@:2}"', name, binary] + args,
                          input=inp, capture_output=True, timeout=30)

def check(name, cond, info=''):
    global n
    n += 1
    if not cond:
        fails.append((name, info))

def verify(pw, h):
    if not have_perl:
        return True
    r = subprocess.run(['perl', '-e', 'print crypt($ARGV[0], $ARGV[1]) eq $ARGV[1] ? "ok" : "bad"', pw, h], capture_output=True)
    return r.stdout == b'ok'

with tempfile.TemporaryDirectory() as d:
    os.makedirs(d + '/etc')
    open(d + '/etc/passwd', 'w').write('root:x:0:0:root:/root:/bin/sh\nalice:x:1000:1000::/home/alice:/bin/sh\nbob:old:1001:1001::/home/bob:/bin/sh\n')
    open(d + '/etc/shadow', 'w').write('root:!:19000:0:99999:7:::\nalice:!:19000:0:99999:7:::\n')
    os.chmod(d + '/etc/shadow', 0o600)
    sh = lambda: {l.split(':')[0]: l.split(':') for l in open(d + '/etc/shadow').read().split('\n') if l}
    pw = lambda: {l.split(':')[0]: l.split(':') for l in open(d + '/etc/passwd').read().split('\n') if l}

    r = run('chpasswd', ['-R', d], b'alice:secret123\n')
    check('chpasswd rc', r.returncode == 0, r.stderr)
    h = sh()['alice'][1]
    check('chpasswd sha512', h.startswith('$6$') and verify('secret123', h), h)
    check('chpasswd lastchg', sh()['alice'][2] != '19000' and len(sh()['alice']) == 9, sh()['alice'])
    check('shadow mode kept', oct(os.stat(d + '/etc/shadow').st_mode & 0o777) == '0o600')
    check('root untouched', sh()['root'][1] == '!')

    r = run('chpasswd', ['-R', d, '-m'], b'alice:pw2\nbob:pw3\n')
    check('md5 shadow', sh()['alice'][1].startswith('$1$') and verify('pw2', sh()['alice'][1]))
    check('password lives in passwd for bob', pw()['bob'][1].startswith('$1$') and verify('pw3', pw()['bob'][1]), pw()['bob'])
    for algo, pre in (('SHA256', '$5$'), ('SHA512', '$6$'), ('MD5', '$1$'), ('DES', '')):
        r = run('chpasswd', ['-R', d, '-c', algo], b'alice:x' + algo.encode() + b'\n')
        hh = sh()['alice'][1]
        check('algo ' + algo, hh.startswith(pre) and verify('x' + algo, hh), hh)
    r = run('chpasswd', ['-R', d, '-c', 'SHA512', '-s', '7000'], b'alice:rounds\n')
    check('sha rounds', sh()['alice'][1].startswith('$6$rounds=7000$') and verify('rounds', sh()['alice'][1]))
    r = run('chpasswd', ['-R', d, '-e'], b'alice:$6$fixed$hashvalue\n')
    check('chpasswd -e keeps the hash', sh()['alice'][1] == '$6$fixed$hashvalue')
    before = open(d + '/etc/shadow').read()
    r = run('chpasswd', ['-R', d], b'nouser:x\nalice:y\n')
    check('unknown user aborts', r.returncode == 1 and b"user 'nouser' does not exist" in r.stderr and open(d + '/etc/shadow').read() == before, r.stderr)
    r = run('chpasswd', ['-R', d], b'badline\n')
    check('missing password', r.returncode == 1 and b'missing new password' in r.stderr, r.stderr)

    r = run('passwd', ['-R', d, '-S', 'alice'])
    check('status format', r.stdout.split()[:2] == [b'alice', b'P'] and r.stdout.split()[3:] == [b'0', b'99999', b'7', b'-1'] and b'-' in r.stdout.split()[2], r.stdout)
    r = run('passwd', ['-R', d, '-S', '-a'])
    check('status all', b'root L' in r.stdout and b'bob P' in r.stdout, r.stdout)
    r = run('passwd', ['-R', d, '-l', 'alice'])
    check('lock', sh()['alice'][1].startswith('!$') and b'expiry information changed' in r.stderr, sh()['alice'])
    r = run('passwd', ['-R', d, '-S', 'alice'])
    check('status locked', r.stdout.split()[1] == b'L', r.stdout)
    r = run('passwd', ['-R', d, '-u', 'alice'])
    check('unlock', not sh()['alice'][1].startswith('!'), sh()['alice'])
    r = run('passwd', ['-R', d, '-d', 'alice'])
    check('delete', sh()['alice'][1] == '' and run('passwd', ['-R', d, '-S', 'alice']).stdout.split()[1] == b'NP')
    r = run('passwd', ['-R', d, '-n', '1', '-x', '90', '-w', '5', '-i', '10', 'alice'])
    check('aging', sh()['alice'][3:7] == ['1', '90', '5', '10'], sh()['alice'])
    r = run('passwd', ['-R', d, '-e', 'alice'])
    check('expire', sh()['alice'][2] == '0', sh()['alice'])
    r = run('passwd', ['-R', d, '-S', 'nosuch'])
    check('unknown user', r.returncode == 1 and b"user 'nosuch' does not exist" in r.stderr, r.stderr)
    r = run('passwd', ['-R', d, 'alice'], b'newpw\nnewpw\n')
    check('interactive change', r.returncode == 0 and b'password updated successfully' in r.stderr and verify('newpw', sh()['alice'][1]), r.stderr)
    r = run('passwd', ['-R', d, 'alice'], b'a\nb\n')
    check('mismatch', r.returncode == 10 and b'passwords do not match' in r.stderr, r.stderr)
    r = run('passwd', ['-R', d, '-a'])
    check('-a needs -S', r.returncode == 2, r.stderr)

if fails:
    for f in fails:
        print('FAIL', f)
    sys.exit(1)
print(f'{n} passwd/chpasswd checks passed')
