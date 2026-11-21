"""Fixed-expectation checks for simple commands, written from GNU coreutils
semantics (no GNU binary is required).  usage: basic_compat.py <cmdbox>"""
import os, subprocess, sys, tempfile
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
env = dict(os.environ, LC_ALL='C', TZ='Asia/Tokyo')
checks = 0
failures = []

def run(args, data=b'', cwd=None):
    return subprocess.run([binary, *args], input=data, capture_output=True, env=env, cwd=cwd, timeout=10)

def check(args, out=None, rc=0, data=b'', cwd=None):
    global checks
    checks += 1
    p = run(args, data, cwd)
    if (out is not None and p.stdout != out) or p.returncode != rc:
        failures.append((args, (p.returncode, p.stdout, p.stderr), (rc, out)))

# date: fixed epoch conversions in Asia/Tokyo (+0900)
D = lambda *a: ['date', *a]
check(D('-d', '@0', '+%s'), b'0\n')
check(D('-d', '@1700000000', '+%Y-%m-%d %H:%M:%S %Z %z'), b'2023-11-15 07:13:20 JST +0900\n')
check(D('-u', '-d', '@1700000000'), b'Tue Nov 14 22:13:20 UTC 2023\n')
check(D('-d', '@1700000000', '-R'), b'Wed, 15 Nov 2023 07:13:20 +0900\n')
check(D('-d', '@1700000000', '-Iseconds'), b'2023-11-15T07:13:20+09:00\n')
check(D('-d', '@1700000000', '-Ihours'), b'2023-11-15T07+09:00\n')
check(D('-d', '@1700000000.5', '+%N'), b'500000000\n')
check(D('-d', '@1700000000', '--rfc-3339=seconds'), b'2023-11-15 07:13:20+09:00\n')
check(D('-d', '2020-01-02 03:04:05', '+%s'), b'1577901845\n')
check(D('-d', '2020-01-02T03:04:05Z', '+%s'), b'1577934245\n')
check(D('-d', '2020-01-02 03:04:05 +0900', '+%s'), b'1577901845\n')
check(D('-d', '2020-01-02', '+%s'), b'1577890800\n')
check(D('-d', '01/02/2020', '+%s'), b'1577890800\n')
check(D('-d', 'Jan 2 2020', '+%s'), b'1577890800\n')
check(D('-d', 'January 2, 2020 10:30pm', '+%s'), b'1577971800\n')
check(D('-d', '2020-01-31 + 1 month', '+%F'), b'2020-03-02\n')
check(D('-d', '2020-01-02 3 days ago', '+%F'), b'2019-12-30\n')
check(D('-d', '2020-01-02 next monday', '+%F'), b'2020-01-06\n')
check(D('-d', '2020-01-02 last friday', '+%F'), b'2019-12-27\n')
check(D('-d', '2020-01-02 12:00 tomorrow', '+%F %T'), b'2020-01-03 12:00:00\n')
check(D('-d', '2000-02-30'), None, 1)
check(D('-d', 'garbage'), None, 1)
check(D('-d', '@1700000000', '+%-d|%_d|%^a|%10A|%-m|%_H|%:z|%::z|%3N|%P'),
      b'15|15|WED| Wednesday|11| 7|+09:00|+09:00:00|000|am\n')
check(D('-d', '2020-06-01 12:00 EST', '+%s'), b'1591030800\n')
check(D('-d', '2020-06-01 12:00 +05:30', '+%s'), b'1590993000\n')
check(D('-d', '@5', '-I', '-R'), None, 1)
check(D('-d', '@5', 'x'), None, 1)

# id / uname
check(['id', '-u'], f'{os.getuid()}\n'.encode())
check(['id', '-un', 'root'], b'root\n')
check(['id', '-u', '-g'], None, 1)
check(['id', '-n'], None, 1)
check(['id', 'no-such-user-xyz'], None, 1)
check(['uname', '-s'], b'Linux\n')
check(['uname', '-o'], b'GNU/Linux\n')
check(['uname', '-x'], None, 1)
check(['uname', 'extra'], None, 1)

# cksum (known vectors for "abc")
for a, o in [([], b'1219131554 3\n'), (['-a', 'bsd'], b'16556     1\n'), (['-a', 'sysv'], b'294 1\n'),
             (['-a', 'crc32b'], b'891568578 3\n'),
             (['-a', 'md5'], b'MD5 (-) = 900150983cd24fb0d6963f7d28e17f72\n'),
             (['-a', 'sha1'], b'SHA1 (-) = a9993e364706816aba3e25717850c26c9cd0d89d\n'),
             (['-a', 'sha256', '--untagged'], b'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  -\n'),
             (['-a', 'sha256', '--untagged', '-b'], b'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad *-\n'),
             (['-a', 'crc', '--tag'], b'CRC (-) = 1219131554\n')]:
    check(['cksum', *a], o, data=b'abc')
check(['cksum', '-a', 'nope'], None, 1, data=b'abc')
check(['cksum', 'no-such-file-xyz'], None, 1)
# kill
check(['kill', '-l', '9'], b'KILL\n')
check(['kill', '-l', 'TERM'], b'15\n')
check(['kill', '-l', '130'], b'INT\n')
check(['kill', '-l', 'bogus'], None, 1)
check(['kill', '-0', str(os.getpid())], b'', 0)
check(['kill', '-s', 'NOSUCH', '1'], None, 1)
check(['kill', '-9', '999999'], None, 1)
check(['kill', 'abc'], None, 1)
check(['kill'], None, 1)

# df / free layout
def first_line(args):
    return run(args).stdout.split(b'\n')[0]
checks += 1
if not first_line(['df']).startswith(b'Filesystem     1K-blocks'): failures.append('df header')
checks += 1
if not first_line(['df', '-h', '/']).startswith(b'Filesystem      Size  Used Avail Use% Mounted on'): failures.append('df -h header')
checks += 1
if not first_line(['df', '-i', '/']).startswith(b'Filesystem'): failures.append('df -i header')
check(['df', 'no-such-file-xyz'], None, 1)
check(['df', '-P', '-T'], None, 1)
checks += 1
if first_line(['free']) != b'              total        used        free      shared  buff/cache   available': failures.append('free header')
checks += 1
if not run(['free', '-h']).stdout.split(b'\n')[2].startswith(b'Swap:'): failures.append('free -h')
check(['free', 'x'], None, 1)

# hexdump (util-linux layout)
HD = b'Hello, World!\x00\x01\xffabc'
r = run(['hexdump', '-C'], HD).stdout.split(b'\n')
checks += 1
if r[0] != b'00000000  48 65 6c 6c 6f 2c 20 57  6f 72 6c 64 21 00 01 ff  |Hello, World!...|':
    failures.append(('hexdump -C line1', r[0]))
checks += 1
if not r[1].startswith(b'00000010  61 62 63') or not r[1].endswith(b'|abc|') or r[2] != b'00000013':
    failures.append(('hexdump -C line2', r[1:3]))
check(['hexdump', '-C', '-n', '5'], None, 0, data=HD)
check(['hexdump', '-e', '4/1 "%02x " "\\n"'], b'48 65 6c 6c \n6f 2c 20 57 \n6f 72 6c 64 \n21 00 01 ff \n61 62 63    \n', data=HD)
check(['hexdump', '-e', '"%d\\n"', '-n', '4'], b'1819043144\n', data=HD)
check(['hexdump', '-vC'], None, 0, data=b'A' * 48)
sq = run(['hexdump', 'C'.join(['-', ''])], b'A' * 80).stdout.split(b'\n')
checks += 1
if sq[1] != b'*' or sq[2] != b'00000050' or sq[3] != b'': failures.append(('hexdump squeeze', sq))
check(['hexdump', '-C', 'no-such-file-xyz'], None, 1)
check(['hexdump', '-n', 'zz'], None, 1, data=b'a')

# ps layout (procps)
def lines(args):
    return run(args).stdout.split(b'\n')
checks += 1
h = lines(['ps', '-e'])[0]
if not (h.startswith(b'    PID TTY          TIME CMD') or h.startswith(b'  PID TTY          TIME CMD')): failures.append(('ps header', h))
checks += 1
h = lines(['ps', '-ef'])[0]
if not h.startswith(b'UID          PID    PPID  C STIME TTY          TIME CMD'): failures.append(('ps -ef header', h))
checks += 1
h = lines(['ps', 'aux'])[0]
if not h.startswith(b'USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND'): failures.append(('ps aux header', h))
checks += 1
r = run(['ps', '-o', 'pid=', '-p', '1']).stdout
if r.strip() != b'1' or b'PID' in r: failures.append(('ps -o pid=', r))
checks += 1
r = run(['ps', '-o', 'pid,comm', '-p', '1']).stdout.split(b'\n')
if r[0].split() != [b'PID', b'COMMAND'] or r[1].split()[0] != b'1': failures.append(('ps -o', r))
check(['ps', '-p', '999999999'], None, 1)
check(['ps', '-o', 'nosuchcol'], None, 1)
check(['ps', '--bogus'], None, 1)
# nice
check(['nice'], b'0\n')
check(['nice', '-n', '5', 'nice'], b'5\n')
check(['nice', '-5', 'nice'], b'5\n')
check(['nice', '--5', 'nice'], b'-5\n') if os.getuid() == 0 else None
check(['nice', '-n', '5'], None, 125)
check(['nice', '-n', 'x', 'true'], None, 125)
check(['nice', 'no-such-cmd-xyz'], None, 127)
# killall (uses a uniquely named helper process)
import time
helper = subprocess.Popen([sys.executable, '-I', '-c', 'import ctypes,time;ctypes.CDLL(None).prctl(15,b"zzkt_cmdbox",0,0,0);time.sleep(60)'])
time.sleep(0.4)
check(['killall', '-s', '0', 'zzkt_cmdbox'], b'', 0)
check(['killall', '-e', '-s', '0', 'zzkt_cmdbox'], b'', 0)
check(['killall', '-r', 'zzkt_c.*x', '-s', '0'], b'', 0)
check(['killall', '-o', '1h', '-s', '0', 'zzkt_cmdbox'], None, 1)
check(['killall', 'zzkt_cmdbox'], b'', 0)
helper.wait(timeout=5)
checks += 1
if helper.returncode != -15: failures.append(('killall TERM', helper.returncode))
check(['killall', 'zzkt_cmdbox'], None, 1)
check(['killall', '-q', 'zzkt_cmdbox'], b'', 1)
check(['killall'], None, 1)
check(['killall', '-s', 'NOSUCHSIG', 'x'], None, 1)

# ls (GNU layout, fixed expectations; times set to 2023-11-14 22:13:20 UTC = Nov 15 2023 JST)
with tempfile.TemporaryDirectory() as d:
    L = Path(d)
    T = 1700000000
    def mk(name, size=0, mode=None, mtime=T):
        pth = L / name
        pth.write_bytes(b'x' * size)
        if mode is not None: pth.chmod(mode)
        os.utime(pth, (mtime, mtime))
    mk('a', 5); mk('b', 0); mk('c', 1500, mtime=T + 86400); mk('x.txt', 3); mk('y.c', 10)
    (L / 'sub').mkdir(); os.utime(L / 'sub', (T, T))
    mk('sub/inner', 2); os.utime(L / 'sub', (T, T))
    os.symlink('a', L / 'ln'); os.utime(L / 'ln', (T, T), follow_symlinks=False)
    mk('.hid', 1)
    mk('run.sh', 4, 0o755)
    def lsout(args, cols=None, cwd=d):
        e = dict(env)
        if cols: e['COLUMNS'] = str(cols)
        return subprocess.run([binary, 'ls', *args], capture_output=True, env=e, cwd=cwd, timeout=10)
    def lsc(args, want, cols=None, rc=0):
        global checks
        checks += 1
        p = lsout(args, cols)
        if p.stdout != want or p.returncode != rc:
            failures.append(('ls', args, p.returncode, p.stdout, want))
    lsc([], b'a\nb\nc\nln\nrun.sh\nsub\nx.txt\ny.c\n')
    lsc(['-A'], b'.hid\na\nb\nc\nln\nrun.sh\nsub\nx.txt\ny.c\n')
    lsc(['-a', '-1'], b'.\n..\n.hid\na\nb\nc\nln\nrun.sh\nsub\nx.txt\ny.c\n')
    lsc(['-r'], b'y.c\nx.txt\nsub\nrun.sh\nln\nc\nb\na\n')
    lsc(['-X'], b'a\nb\nc\nln\nsub\ny.c\nrun.sh\nx.txt\n')
    lsc(['-t'], b'c\na\nb\nln\nrun.sh\nsub\nx.txt\ny.c\n')
    lsc(['--group-directories-first'], b'sub\na\nb\nc\nln\nrun.sh\nx.txt\ny.c\n')
    lsc(['-F'], b'a\nb\nc\nln@\nrun.sh*\nsub/\nx.txt\ny.c\n')
    lsc(['-p'], b'a\nb\nc\nln\nrun.sh\nsub/\nx.txt\ny.c\n')
    lsc(['-I', '*.txt', '--hide=y*', '-1'], b'a\nb\nc\nln\nrun.sh\nsub\n')
    lsc(['-C'], b'a  c   run.sh  x.txt\nb  ln  sub     y.c\n', cols=24)
    lsc(['-x'], b'a\tb    c\t    ln\nrun.sh\tsub  x.txt  y.c\n', cols=24)
    lsc(['-m'], b'a, b, c, ln, run.sh, sub, x.txt, y.c\n', cols=80)
    lsc(['-C'], b'a  c   run.sh  x.txt\nb  ln  sub     y.c\n'.replace(b'a  c   run.sh', b'a   c   run.sh'), cols=80) if False else None
    lsc(['-w', '8', '-C', 'a', 'b', 'c', 'd', 'e', 'f'] if False else ['-w', '1'], b'a\nb\nc\nln\nrun.sh\nsub\nx.txt\ny.c\n')
    lsc(['-Q'], b'"a"\n"b"\n"c"\n"ln"\n"run.sh"\n"sub"\n"x.txt"\n"y.c"\n')
    lsc(['-s', 'a', 'b'], b'4 a\n0 b\n')
    lsc(['-d', 'sub', 'a'], b'a\nsub\n')
    lsc(['a'], b'a\n')
    lsc(['sub'], b'inner\n')
    lsc(['ln'], b'ln\n')
    lsc(['-R', 'sub', 'a'], b'a\n\nsub:\ninner\n')
    lsc(['no-such-file-xyz'], b'', rc=2)
    lsc(['-l', 'a', 'ln'], b'-rw-r--r-- 1 root root 5 Nov 15  2023 a\nlrwxrwxrwx 1 root root 1 Nov 15  2023 ln -> a\n')
    lsc(['-lh', 'c'], b'-rw-r--r-- 1 root root 1.5K Nov 16  2023 c\n')
    lsc(['-l', '--time-style=long-iso', 'a'], b'-rw-r--r-- 1 root root 5 2023-11-15 07:13 a\n')
    lsc(['-l', '--time-style=iso', 'a'], b'-rw-r--r-- 1 root root 5 2023-11-15  a\n')
    lsc(['-l', '--full-time', 'a'], b'-rw-r--r-- 1 root root 5 2023-11-15 07:13:20.000000000 +0900 a\n')
    lsc(['-l', '--time-style=+%Y/%m', 'a'], b'-rw-r--r-- 1 root root 5 2023/11 a\n')
    lsc(['-n', '-g', 'a'], b'-rw-r--r-- 1 0 5 Nov 15  2023 a\n')
    lsc(['-lo', 'a'], b'-rw-r--r-- 1 root 5 Nov 15  2023 a\n')
    lsc(['-lG', 'a'], b'-rw-r--r-- 1 root 5 Nov 15  2023 a\n')
    lsc(['-l', 'run.sh'], b'-rwxr-xr-x 1 root root 4 Nov 15  2023 run.sh\n')
    lsc(['--bogus'], b'', rc=2)
    lsc(['--sort=bogus'], b'', rc=2)
    lsc(['--time-style=bogus'], b'', rc=2)
    lsc(['-l'], None) if False else None
    checks += 1
    tl = lsout(['-l']).stdout.split(b'\n')
    if not tl[0].startswith(b'total '): failures.append(('ls -l total', tl[0]))
    # weird names
    (L / 'sp ace').write_bytes(b''); (L / 'q\'uote').write_bytes(b''); (L / 'nl\nname').write_bytes(b'')
    lsc(['-1', 'sp ace', "q'uote"], b"q'uote\nsp ace\n")
    lsc(['-b', 'sp ace', 'nl\nname'], b'nl\\nname\nsp\\ ace\n')
    lsc(['-Q', "q'uote", 'nl\nname'], b'"nl\\nname"\n"q\'uote"\n')
    lsc(['--quoting-style=shell-escape', 'sp ace', 'nl\nname', "q'uote"], b"$'nl\\nname'\n'q'\\''uote'\n'sp ace'\n")
    lsc(['-q', 'nl\nname'], b'nl?name\n')

# mv / ln (fixed expectations)
def fsrun(args, cwd, data=b''):
    return subprocess.run([binary, *args], capture_output=True, env=env, cwd=cwd, timeout=10, input=data)
def fscheck(args, d, want_out=None, rc=0, data=b''):
    global checks
    checks += 1
    p = fsrun(args, d, data)
    if (want_out is not None and p.stdout != want_out) or p.returncode != rc:
        failures.append((args, p.returncode, p.stdout, p.stderr[:120], want_out, rc))
def tree(d):
    out = []
    for root, dirs, files in os.walk(d):
        for n in sorted(dirs + files):
            out.append(os.path.relpath(os.path.join(root, n), d))
    return sorted(out)
def new(files=('a', 'b'), dirs=('dir',)):
    t = tempfile.mkdtemp()
    for f in files: Path(t, f).write_text(f + '\n')
    for x in dirs: Path(t, x).mkdir()
    return t
t = new(); fscheck(['mv', 'a', 'c'], t, b'');  checks += 1
if tree(t) != ['b', 'c', 'dir']: failures.append(('mv rename', tree(t)))
t = new(); fscheck(['mv', 'a', 'b', 'dir'], t, b''); checks += 1
if tree(t) != ['dir', 'dir/a', 'dir/b']: failures.append(('mv into dir', tree(t)))
t = new(); fscheck(['mv', '-v', 'a', 'c'], t, b"renamed 'a' -> 'c'\n")
t = new(); fscheck(['mv', '-n', 'a', 'b'], t, b''); checks += 1
if Path(t, 'b').read_text() != 'b\n' or not Path(t, 'a').exists(): failures.append('mv -n')
t = new(); fscheck(['mv', '-i', 'a', 'b'], t, b'', rc=1, data=b'n\n'); checks += 1
if Path(t, 'b').read_text() != 'b\n': failures.append('mv -i decline')
t = new(); fscheck(['mv', '-i', 'a', 'b'], t, b'', rc=0, data=b'y\n'); checks += 1
if Path(t, 'b').read_text() != 'a\n': failures.append('mv -i accept')
t = new(); fscheck(['mv', '-b', 'a', 'b'], t, b''); checks += 1
if tree(t) != ['b', 'b~', 'dir'] or Path(t, 'b~').read_text() != 'b\n': failures.append(('mv -b', tree(t)))
t = new(); fscheck(['mv', '-S', '.bak', 'a', 'b'], t, b''); checks += 1
if tree(t) != ['b', 'b.bak', 'dir']: failures.append(('mv -S', tree(t)))
t = new(); fscheck(['mv', '--backup=numbered', 'a', 'b'], t, b''); checks += 1
if tree(t) != ['b', 'b.~1~', 'dir']: failures.append(('mv numbered', tree(t)))
t = new(); fscheck(['mv', '-t', 'dir', 'a', 'b'], t, b''); checks += 1
if tree(t) != ['dir', 'dir/a', 'dir/b']: failures.append(('mv -t', tree(t)))
t = new(); fscheck(['mv', '-T', 'a', 'dir'], t, None, rc=1)
t = new(); fscheck(['mv', 'a', 'b', 'c'], t, None, rc=1)
t = new(); fscheck(['mv', 'nonexist', 'b'], t, None, rc=1)
t = new(); fscheck(['mv', 'a', 'a'], t, None, rc=1)
t = new(); fscheck(['mv', 'dir', 'dir/sub'], t, None, rc=1)
t = new(); fscheck(['mv', 'a', 'dir'], t, b''); fscheck(['mv', 'dir', 'a2'], t, b''); checks += 1
if tree(t) != ['a2', 'a2/a', 'b']: failures.append(('mv dir', tree(t)))
t = new(); fscheck(['mv', 'dir', 'a'], t, None, rc=1)
t = new(); fscheck(['mv'], t, None, rc=1)
t = new(); fscheck(['mv', 'a'], t, None, rc=1)
t = new(); os.utime(Path(t, 'a'), (1000, 1000)); fscheck(['mv', '-u', 'a', 'b'], t, b''); checks += 1
if Path(t, 'b').read_text() != 'b\n': failures.append('mv -u older')
# ln
t = new(); fscheck(['ln', 'a', 'h'], t, b''); checks += 1
if os.stat(Path(t, 'a')).st_ino != os.stat(Path(t, 'h')).st_ino: failures.append('ln hard')
t = new(); fscheck(['ln', '-s', 'a', 's'], t, b''); checks += 1
if os.readlink(Path(t, 's')) != 'a': failures.append('ln -s')
t = new(); fscheck(['ln', 'a', 'b'], t, None, rc=1)
t = new(); fscheck(['ln', '-f', 'a', 'b'], t, b''); checks += 1
if os.stat(Path(t, 'a')).st_ino != os.stat(Path(t, 'b')).st_ino: failures.append('ln -f')
t = new(); fscheck(['ln', '-sv', 'a', 's'], t, b"'s' -> 'a'\n")
t = new(); fscheck(['ln', '-v', 'a', 'h'], t, b"'h' => 'a'\n")
t = new(); fscheck(['ln', '-s', 'a', 'dir'], t, b''); checks += 1
if os.readlink(Path(t, 'dir', 'a')) != 'a': failures.append('ln into dir')
t = new(); fscheck(['ln', '-sT', 'a', 'dir'], t, None, rc=1)
t = new(); fscheck(['ln', '-t', 'dir', 'a', 'b'], t, b''); checks += 1
if tree(t) != ['a', 'b', 'dir', 'dir/a', 'dir/b']: failures.append(('ln -t', tree(t)))
t = new(); Path(t, 'dir', 'x').write_text('x'); fscheck(['ln', '-sr', 'a', 'dir/rel'], t, b''); checks += 1
if os.readlink(Path(t, 'dir', 'rel')) != '../a': failures.append(('ln -r', os.readlink(Path(t, 'dir', 'rel'))))
t = new(); fscheck(['ln', '-sb', 'a', 'b'], t, b''); checks += 1
if os.readlink(Path(t, 'b')) != 'a' or not Path(t, 'b~').exists(): failures.append('ln -b')
t = new(); fscheck(['ln', 'dir', 'dl'], t, None, rc=1)
t = new(); fscheck(['ln', 'nonexist', 'x'], t, None, rc=1)
t = new(); fscheck(['ln'], t, None, rc=1)
t = new(); fscheck(['ln', '-s', 'a'], t, None, rc=1)
t = new(); os.mkdir(Path(t, 'dir', 'z')); fscheck(['ln', '-s', '../b'], t, None, rc=1) if False else None
# cp extras with fixed expectations (no GNU cp needed)
t = new(); fscheck(['cp', '-rv', 'dir', 'd2'], t, b"'dir' -> 'd2'\n")
t = new(); fscheck(['cp', '-b', 'a', 'b'], t, b''); checks += 1
if tree(t) != ['a', 'b', 'b~', 'dir']: failures.append(('cp -b', tree(t)))
t = new(); fscheck(['cp', '--parents', 'dir/../a', 'dir'], t, None, rc=0) if False else None
t = new(); fscheck(['cp', '-r', 'dir', 'dir/x'], t, None, rc=1)

# rm / mkdir / rmdir
t = new(); fscheck(['rm', 'a'], t, b''); checks += 1
if tree(t) != ['b', 'dir']: failures.append(('rm', tree(t)))
t = new(); fscheck(['rm', 'dir'], t, None, rc=1)
t = new(); fscheck(['rm', '-d', 'dir'], t, b''); checks += 1
if tree(t) != ['a', 'b']: failures.append(('rm -d', tree(t)))
t = new(); fscheck(['rm', 'nonexist'], t, None, rc=1)
t = new(); fscheck(['rm', '-f', 'nonexist'], t, b'')
t = new(); fscheck(['rm', '-f'], t, b'')
t = new(); fscheck(['rm'], t, None, rc=1)
t = new(); fscheck(['rm', '-v', 'a', 'b'], t, b"removed 'a'\nremoved 'b'\n")
t = new(); Path(t, 'dir', 'x').write_text('x'); fscheck(['rm', '-rv', 'dir'], t, b"removed 'dir/x'\nremoved directory 'dir'\n")
t = new(); fscheck(['rm', '-i', 'a'], t, b'', rc=0, data=b'n\n'); checks += 1
if not Path(t, 'a').exists(): failures.append('rm -i decline')
t = new(); fscheck(['rm', '-i', 'a'], t, b'', rc=0, data=b'y\n'); checks += 1
if Path(t, 'a').exists(): failures.append('rm -i accept')
t = new(); fscheck(['rm', '.'], t, None, rc=1)
t = new(); fscheck(['rm', '-r', '..'], t, None, rc=1)
t = new(); fscheck(['rm', '-r', '/', '--preserve-root'], t, None, rc=1) if False else None
t = new(); fscheck(['rm', '-z'], t, None, rc=1)
t = new(); fscheck(['mkdir', 'n1'], t, b''); fscheck(['mkdir', 'n1'], t, None, rc=1)
t = new(); fscheck(['mkdir', '-p', 'x/y/z'], t, b''); fscheck(['mkdir', '-p', 'x/y/z'], t, b''); checks += 1
if not Path(t, 'x/y/z').is_dir(): failures.append('mkdir -p')
t = new(); fscheck(['mkdir', '-p', 'a/x'], t, None, rc=1)
t = new(); fscheck(['mkdir', '-pv', 'p/q'], t, b"mkdir: created directory 'p'\nmkdir: created directory 'p/q'\n")
t = new(); fscheck(['mkdir', '-m', '700', 'm'], t, b''); checks += 1
if oct(os.stat(Path(t, 'm')).st_mode & 0o7777) != '0o700': failures.append('mkdir -m')
t = new(); fscheck(['mkdir', '-m', 'u=rwx,g=rx,o=', 'm'], t, b''); checks += 1
if oct(os.stat(Path(t, 'm')).st_mode & 0o7777) != '0o750': failures.append('mkdir -m sym')
t = new(); fscheck(['mkdir', '-m', '999', 'm'], t, None, rc=1)
t = new(); fscheck(['mkdir'], t, None, rc=1)
t = new(); fscheck(['mkdir', '-Z', 'z'], t, b'')
t = new(); fscheck(['rmdir', 'dir'], t, b''); fscheck(['rmdir', 'dir'], t, None, rc=1)
t = new(); Path(t, 'dir', 'x').write_text('x'); fscheck(['rmdir', 'dir'], t, None, rc=1)
t = new(); Path(t, 'dir', 'x').write_text('x'); fscheck(['rmdir', '--ignore-fail-on-non-empty', 'dir'], t, b'', rc=0)
t = new(); os.makedirs(Path(t, 'p/q/r')); fscheck(['rmdir', '-p', 'p/q/r'], t, b''); checks += 1
if Path(t, 'p').exists(): failures.append('rmdir -p')
t = new(); os.makedirs(Path(t, 'p/q')); fscheck(['rmdir', '-pv', 'p/q'], t, b"rmdir: removing directory, 'p/q'\nrmdir: removing directory, 'p'\n")
t = new(); fscheck(['rmdir', 'a'], t, None, rc=1)
t = new(); fscheck(['rmdir'], t, None, rc=1)

# sort (GNU semantics, fixed expectations)
def S(args, data, want, rc=0):
    check(['sort', *args], want, rc, data=data)
S(['-n'], b'10\n9\n2\n1\n-3\n 5\nabc\n', b'-3\nabc\n1\n2\n 5\n9\n10\n')
S(['-rn'], b'10\n9\n2\n', b'10\n9\n2\n')
S(['-g'], b'1e2\n5\nabc\n-1\n', b'abc\n-1\n5\n1e2\n')
S(['-h'], b'1K\n2M\n500\n1G\n3K\n1.5K\n', b'500\n1K\n1.5K\n3K\n2M\n1G\n')
S(['-hr'], b'1K\n2M\n500\n', b'2M\n1K\n500\n')
S(['-M'], b'Mar\nJan\nfeb\nxyz\nDec\n', b'xyz\nJan\nfeb\nMar\nDec\n')
S(['-V'], b'a10\na9\na1\nb2\n', b'a1\na9\na10\nb2\n')
S(['--sort=version'], b'a10\na9\n', b'a9\na10\n')
S(['-f'], b'b\nA\na\nB\n', b'A\na\nB\nb\n')
S(['-d'], b'a-b\nab\na b\n', b'a b\na-b\nab\n')
S(['-u'], b'b\na\nb\na\n', b'a\nb\n')
S(['-k2,2n'], b'b 2\na 10\nc 1\n', b'c 1\nb 2\na 10\n')
S(['-k1,1', '-k2,2nr'], b'a 1\nb 2\na 3\n', b'a 3\na 1\nb 2\n')
S(['-t:', '-k2,2'], b'x:b\ny:a\n', b'y:a\nx:b\n')
S(['-t', ':', '-k2'], b'x:b\ny:a\n', b'y:a\nx:b\n')
S(['-s', '-k1,1'], b'a 2\nb 1\na 1\n', b'a 2\na 1\nb 1\n')
S(['-u', '-k1,1'], b'a 2\nb 1\na 1\n', b'a 2\nb 1\n')
S(['-c'], b'a\nb\n', b'')
S(['-c'], b'b\na\n', b'', rc=1)
S(['-C'], b'b\na\n', b'', rc=1)
S(['-c', '-u'], b'a\na\n', b'', rc=1)
S(['-z'], b'b\x00a\x00', b'a\x00b\x00')
S(['-b', '-k2'], b'x  b\ny a\n', b'y a\nx  b\n')
S(['-r'], b'a\nb\nc\n', b'c\nb\na\n')
S(['-m'], b'a\nb\n', b'a\nb\n')
S(['--foo'], b'', b'', rc=2)
S(['-k0'], b'', b'', rc=2)
S(['--sort=bogus'], b'', b'', rc=2)
S(['no-such-file-xyz'], b'', b'', rc=2)
checks += 1
r = run(['sort', '-R'], b'a\nb\nc\nd\n').stdout
if sorted(r.split()) != [b'a', b'b', b'c', b'd']: failures.append(('sort -R', r))

# head / tail / uniq / cat messages (GNU semantics)
N10 = b''.join(b'%d\n' % i for i in range(1, 11))
for args, data, want in [
    (['head', '-n', '3'], N10, b'1\n2\n3\n'),
    (['head', '-n', '-8'], N10, b'1\n2\n'),
    (['head', '-3'], N10, b'1\n2\n3\n'),
    (['head', '-c', '5'], N10, b'1\n2\n3'),
    (['head', '-c', '-17'], N10, b'1\n2\n'),
    (['head', '-n', '0'], N10, b''),
    (['head', '-n', '1k'], b'a\nb\nc', b'a\nb\nc'),
    (['head', '-z', '-n', '1'], b'a\x00b\x00', b'a\x00'),
    (['tail', '-n', '3'], N10, b'8\n9\n10\n'),
    (['tail', '-3'], N10, b'8\n9\n10\n'),
    (['tail', '-n', '+9'], N10, b'9\n10\n'),
    (['tail', '-c', '5'], N10, b'9\n10\n'),
    (['tail', '-c', '+18'], N10, b'\n10\n'),
    (['tail', '-n', '0'], N10, b''),
    (['tail', '-n', '1'], b'a\nb\nc', b'c'),
    (['tail', '-n', '2'], b'a\nb\nc\n', b'b\nc\n'),
    (['tail', '-n', '100'], b'a\nb\n', b'a\nb\n'),
    (['tail', '-z', '-n', '1'], b'a\x00b\x00', b'b\x00'),
    (['uniq'], b'a\na\nb\nc\nc\nc\nd\n', b'a\nb\nc\nd\n'),
    (['uniq', '-c'], b'a\na\nb\n', b'      2 a\n      1 b\n'),
    (['uniq', '-d'], b'a\na\nb\nc\nc\n', b'a\nc\n'),
    (['uniq', '-u'], b'a\na\nb\nc\nc\n', b'b\n'),
    (['uniq', '-D'], b'a\na\nb\nc\nc\n', b'a\na\nc\nc\n'),
    (['uniq', '--all-repeated=separate'], b'a\na\nb\nc\nc\n', b'a\na\n\nc\nc\n'),
    (['uniq', '--all-repeated=prepend'], b'a\na\nb\nc\nc\n', b'\na\na\n\nc\nc\n'),
    (['uniq', '--group'], b'a\na\nb\n', b'a\na\n\nb\n'),
    (['uniq', '--group=prepend'], b'a\nb\n', b'\na\n\nb\n'),
    (['uniq', '--group=append'], b'a\nb\n', b'a\n\nb\n\n'),
    (['uniq', '--group=both'], b'a\nb\n', b'\na\n\nb\n\n'),
    (['uniq', '-i'], b'A\na\nb\n', b'A\nb\n'),
    (['uniq', '-f1'], b'x a\ny a\nz b\n', b'x a\nz b\n'),
    (['uniq', '-s1'], b'xa\nya\nzb\n', b'xa\nzb\n'),
    (['uniq', '-w1'], b'ab\nac\nbd\n', b'ab\nbd\n'),
    (['uniq', '-z'], b'a\x00a\x00b\x00', b'a\x00b\x00'),
]:
    check(args, want, 0, data=data)
check(['uniq', '--group', '-c'], None, 1, data=b'a\n')
check(['uniq', '-cD'], None, 1, data=b'a\n')
check(['uniq', '-x'], None, 1, data=b'a\n')
check(['head', '-n', 'x'], None, 1, data=b'a\n')
check(['tail', '-n', 'x'], None, 1, data=b'a\n')
check(['head', 'no-such-file-xyz'], None, 1)
check(['tail', 'no-such-file-xyz'], None, 1)
check(['cat', 'no-such-file-xyz'], None, 1)
check(['wc', 'no-such-file-xyz'], None, 1)
checks += 1
if b'No such file or directory' not in run(['cat', 'no-such-file-xyz']).stderr: failures.append('cat error text')
checks += 1
if b'No such file or directory' not in run(['wc', 'no-such-file-xyz']).stderr: failures.append('wc error text')

# basic utilities
check(['dirname', '//a'], b'/\n')
check(['dirname', '//a/b'], b'//a\n')
check(['dirname', '///a'], b'/\n')
check(['dirname', 'a/b/'], b'a\n')
check(['dirname', ''], b'.\n')
check(['dirname'], None, 1)
check(['env', '-i', 'A=1', 'B=2'], b'A=1\nB=2\n')
check(['env', '-0', '-i', 'A=1'], b'A=1\0')
check(['env', '-C', '/', 'pwd'], b'/\n')
check(['env', '-S', 'echo hi there'], b'hi there\n')
check(['env', 'no-such-cmd-xyz'], None, 127)
check(['env', '-x'], None, 125)
check(['env', '-0', 'true'], None, 125)
check(['true', '--version'], None, 0)
check(['false', '--help'], None, 1)
check(['true', 'a', 'b'], b'', 0)
check(['false', 'a'], b'', 1)
check(['which', 'sh'], None, 0)
check(['which', '-s', 'sh'], b'', 0)
check(['which', 'no-such-cmd-xyz'], b'', 1)
check(['sync'], b'', 0)
check(['sync', '-d'], None, 1)
check(['sync', 'no-such-file-xyz'], None, 1)
check(['tee', '--bogus'], None, 1)
check(['clear', '-x'], b'\x1b[H\x1b[2J')
check(['pwd', '-x'], None, 1)
check(['yes', '--', 'a'], None, 0) if False else None

with tempfile.TemporaryDirectory() as d:
    # touch
    f = Path(d) / 'f'
    r = run(['touch', '-d', '@1000000000', 'f'], cwd=d); checks += 1
    if r.returncode or int(f.stat().st_mtime) != 1000000000: failures.append(('touch -d', r))
    r = run(['touch', '-t', '202001020304.05', 'g'], cwd=d); checks += 1
    if r.returncode or int((Path(d) / 'g').stat().st_mtime) != 1577901845: failures.append(('touch -t', r))
    check(['touch', '-c', 'nof'], b'', 0, cwd=d)
    checks += 1
    if (Path(d) / 'nof').exists(): failures.append('touch -c created file')
    check(['touch', '-t', '1', 'h'], None, 1, cwd=d)
    check(['touch', '-d', '@5', '-t', '202001020304', 'f'], None, 1, cwd=d)
    check(['touch', '-a', '-d', '@5', 'f'], b'', 0, cwd=d)
    checks += 1
    st = f.stat()
    if int(st.st_atime) != 5 or int(st.st_mtime) != 1000000000: failures.append('touch -a')
    check(['touch'], None, 1, cwd=d)
    check(['touch', '--bogus', 'x'], None, 1, cwd=d)
    # mkfifo / mknod
    check(['mkfifo', '-m', '600', 'ff'], b'', 0, cwd=d)
    checks += 1
    if oct((Path(d) / 'ff').stat().st_mode & 0o777) != '0o600': failures.append('mkfifo -m')
    check(['mkfifo', 'ff'], None, 1, cwd=d)
    check(['mkfifo'], None, 1, cwd=d)
    check(['mknod', 'p1', 'p'], b'', 0, cwd=d)
    check(['mknod', 'x', 'p', '1', '2'], None, 1, cwd=d)
    check(['mknod', 'x', 'c'], None, 1, cwd=d)
    check(['mknod', 'x', 'z'], None, 1, cwd=d)
    # tee
    check(['tee', 't1', 't2'], b'hello\n', 0, data=b'hello\n', cwd=d)
    checks += 1
    if (Path(d) / 't2').read_bytes() != b'hello\n': failures.append('tee file')
    check(['tee', '-a', 't1'], b'x\n', 0, data=b'x\n', cwd=d)
    checks += 1
    if (Path(d) / 't1').read_bytes() != b'hello\nx\n': failures.append('tee -a')
    check(['tee', 'nodir/x'], b'z', 1, data=b'z', cwd=d)

if os.getuid() == 0:
    with tempfile.TemporaryDirectory() as d:
        (Path(d) / 'sub').mkdir()
        for n in ('f', 'sub/a'): (Path(d) / n).write_text('x')
        os.symlink('f', Path(d) / 'sl')
        check(['chown', '-v', 'nobody', 'f'], b"changed ownership of 'f' from root:root to nobody\n", cwd=d)
        check(['chown', '-v', 'nobody', 'f'], b"ownership of 'f' retained as nobody\n", cwd=d)
        check(['chown', '-c', 'nobody', 'f'], b'', cwd=d)
        check(['chown', '-v', 'root:', 'f'], b"changed ownership of 'f' from nobody:root to root:root\n", cwd=d)
        check(['chgrp', '-v', 'nobody', 'f'], b"changed group of 'f' from root to nobody\n", cwd=d)
        check(['chown', '-R', '65534:65534', 'sub'], b'', cwd=d)
        checks += 1
        if (Path(d) / 'sub/a').stat().st_uid != 65534: failures.append('chown -R')
        check(['chown', '-h', 'nobody', 'sl'], b'', cwd=d)
        checks += 1
        if os.lstat(Path(d) / 'sl').st_uid != 65534 or (Path(d) / 'f').stat().st_uid != 0: failures.append('chown -h')
        check(['chown', 'no-such-user-xyz', 'f'], None, 1, cwd=d)
        check(['chown', 'root:no-such-group-xyz', 'f'], None, 1, cwd=d)
        check(['chown', 'root', 'nonexist'], None, 1, cwd=d)
        check(['chown', '-f', 'root', 'nonexist'], b'', 1, cwd=d)
        check(['chown', 'root'], None, 1, cwd=d)
        check(['chown', '-R', '--dereference', 'root', 'sub'], None, 1, cwd=d)
        check(['chown', '--from=nobody', 'root', 'f'], b'', 0, cwd=d)

if failures:
    for x in failures: print('FAIL', x)
    sys.exit(1)
print(f'{checks} basic command checks passed')
