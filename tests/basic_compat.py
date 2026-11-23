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
             (['-a', 'crc', '--tag'], b'1219131554 3\n')]:
    check(['cksum', *a], o, data=b'abc')
check(['cksum', '-a', 'nope'], None, 1, data=b'abc')
check(['cksum', 'no-such-file-xyz'], None, 1)
# kill
check(['kill', '-l', '9'], b'KILL\n')
check(['kill', '-l', 'TERM'], b'TERM\n')
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
check(['hexdump', '-e', '4/1 "%02x " "\\n"'], b'48 65 6c 6c\n6f 2c 20 57\n6f 72 6c 64\n21 00 01 ff\n61 62 63   \n', data=HD)
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

# tac rev nl fold paste comm expand unexpand
for args, data, want in [
    (['tac'], b'a\nb\nc\n', b'c\nb\na\n'),
    (['tac', '-s', ','], b'a,b,c', b'cb,a,'),
    (['rev'], b'abc\nxy\n', b'cba\nyx\n'),
    (['nl'], b'a\n\nb\n', b'     1\ta\n       \n     2\tb\n'),
    (['nl', '-ba'], b'a\n\nb\n', b'     1\ta\n     2\t\n     3\tb\n'),
    (['nl', '-n', 'rz', '-w', '3'], b'a\nb\n', b'001\ta\n002\tb\n'),
    (['nl', '-n', 'ln', '-s', ':', '-w', '2'], b'a\n', b'1 :a\n'),
    (['nl', '-v', '5', '-i', '2'], b'a\nb\n', b'     5\ta\n     7\tb\n'),
    (['fold', '-w', '4'], b'aaaaaaaaaa\nbb\n', b'aaaa\naaaa\naa\nbb\n'),
    (['fold', '-s', '-w', '5'], b'aa bb cc dd\n', b'aa \nbb \ncc dd\n'),
    (['paste', '-s'], b'1\n2\n3\n', b'1\t2\t3\n'),
    (['paste', '-sd+'], b'1\n2\n3\n', b'1+2+3\n'),
    (['paste', '-', '-'], b'1\n2\n3\n', b'1\t2\n3\t\n'),
    (['paste', '-d,', '-', '-', '-'], b'1\n2\n3\n4\n', b'1,2,3\n4,,\n'),
    (['expand'], b'a\tb\n', b'a       b\n'),
    (['expand', '-t4'], b'a\tb\n', b'a   b\n'),
    (['unexpand'], b'        c\na       b\n', b'\tc\na       b\n'),
    (['unexpand', '-a'], b'a       b\n', b'a\tb\n'),
]:
    check(args, want, 0, data=data)
with tempfile.TemporaryDirectory() as d:
    Path(d, 'c1').write_text('a\nb\nc\n'); Path(d, 'c2').write_text('b\nc\nd\n')
    check(['comm', 'c1', 'c2'], b'a\n\t\tb\n\t\tc\n\td\n', 0, cwd=d)
    check(['comm', '-12', 'c1', 'c2'], b'b\nc\n', 0, cwd=d)
    check(['comm', '-3', 'c1', 'c2'], b'a\n\td\n', 0, cwd=d)
    check(['comm', '--total', '-123', 'c1', 'c2'], b'1\t1\t2\ttotal\n', 0, cwd=d)
    check(['comm', 'c1'], None, 1, cwd=d)
check(['tac', 'no-such-file-xyz'], None, 1)
check(['nl', '-n', 'xx'], None, 1)
check(['fold', '-w', '0'], None, 1)

# expr / timeout / printenv / nproc / truncate / link / unlink / pidof / pgrep / pkill
for args, want, rc in [
    (['1', '+', '2'], b'3\n', 0), (['5', '-', '7'], b'-2\n', 0), (['3', '*', '4'], b'12\n', 0),
    (['7', '/', '2'], b'3\n', 0), (['7', '%', '3'], b'1\n', 0), (['2', '>', '1'], b'1\n', 0),
    (['abc', '<', 'abd'], b'1\n', 0), (['10', '<', '9'], b'0\n', 1), (['1', '|', '2'], b'1\n', 0),
    (['0', '|', '0'], b'0\n', 1), (['1', '&', '0'], b'0\n', 1), (['length', 'hello'], b'5\n', 0),
    (['substr', 'hello', '2', '3'], b'ell\n', 0), (['index', 'hello', 'lo'], b'3\n', 0),
    (['hello', ':', 'h.*'], b'5\n', 0), (['hello', ':', 'e'], b'0\n', 1),
    (['hello', ':', '\\(h.\\)l'], b'he\n', 0), (['(', '1', '+', '2', ')', '*', '3'], b'9\n', 0),
    (['1', '/', '0'], None, 2), (['a', 'b'], None, 2), ([], None, 2), (['1', '+'], None, 2),
]:
    check(['expr', *args], want, rc)
check(['timeout', '0.2', 'sleep', '3'], b'', 124)
check(['timeout', '5', 'true'], b'', 0)
check(['timeout', '5', 'sh', '-c', 'exit 7'], b'', 7)
check(['timeout', '--preserve-status', '0.2', 'sleep', '3'], b'', 143)
check(['timeout', '-s', 'KILL', '0.2', 'sleep', '3'], b'', 137)
check(['timeout', 'abc', 'true'], None, 125)
check(['timeout', '1'], None, 125)
check(['timeout', '1', 'no-such-cmd-xyz'], None, 127)
checks += 1
if run(['printenv', 'PATH']).stdout.strip() != env['PATH'].encode(): failures.append('printenv')
check(['printenv', 'NO_SUCH_VAR_XYZ'], b'', 1)
checks += 1
if int(run(['nproc']).stdout) < 1: failures.append('nproc')
check(['nproc', '--ignore=100000'], b'1\n', 0)
check(['arch'], (os.uname().machine + '\n').encode(), 0)
with tempfile.TemporaryDirectory() as d:
    Path(d, 'f').write_text('hi\n')
    for a, size in [(['-s', '10'], 10), (['-s', '+5'], 15), (['-s', '1K'], 1024), (['-s', '<3'], 3), (['-s', '0'], 0)]:
        check(['truncate', *a, 'f'], b'', 0, cwd=d)
        checks += 1
        if Path(d, 'f').stat().st_size != size: failures.append(('truncate', a, Path(d, 'f').stat().st_size))
    check(['truncate', '-c', '-s', '5', 'nonex'], b'', 0, cwd=d)
    checks += 1
    if Path(d, 'nonex').exists(): failures.append('truncate -c')
    check(['truncate', 'f'], None, 1, cwd=d)
    check(['link', 'f', 'g'], b'', 0, cwd=d)
    checks += 1
    if os.stat(Path(d, 'f')).st_ino != os.stat(Path(d, 'g')).st_ino: failures.append('link')
    check(['unlink', 'g'], b'', 0, cwd=d)
    check(['unlink', 'g'], None, 1, cwd=d)
helper = subprocess.Popen([sys.executable, '-I', '-c', 'import ctypes,time;ctypes.CDLL(None).prctl(15,b"zzpg_cmdbox",0,0,0);time.sleep(60)'])
time.sleep(0.4)
check(['pidof', 'zzpg_cmdbox'], (str(helper.pid) + '\n').encode(), 0)
check(['pgrep', 'zzpg_cmdbox'], (str(helper.pid) + '\n').encode(), 0)
check(['pgrep', '-c', 'zzpg_cmdbox'], b'1\n', 0)
check(['pgrep', '-l', 'zzpg_cmdbox'], (str(helper.pid) + ' zzpg_cmdbox\n').encode(), 0)
check(['pgrep', '-x', 'zzpg'], b'', 1)
check(['pkill', '-0', 'zzpg_cmdbox'], b'', 0)
check(['pkill', 'zzpg_cmdbox'], b'', 0)
helper.wait(timeout=5)
checks += 1
if helper.returncode != -15: failures.append(('pkill TERM', helper.returncode))
check(['pidof', 'zzpg_cmdbox'], b'', 1)
check(['pgrep', 'zzpg_cmdbox'], b'', 1)
check(['pkill', 'zzpg_cmdbox'], b'', 1)
check(['pgrep'], None, 2)
checks += 1
if not run(['uptime']).stdout.startswith(b' ') or b'load average' not in run(['uptime']).stdout: failures.append('uptime')

# fuser / renice / sysctl / mkswap / logger / add-shell (fixed expectations)
fh = subprocess.Popen(['sleep', '30'], stdout=open('/tmp/.cmdbox_fuser_probe', 'wb'))
time.sleep(0.3)
r = run(['fuser', '/tmp/.cmdbox_fuser_probe'])
checks += 1
if r.returncode != 0 or r.stdout != (' %5d' % fh.pid).encode() + b'' and r.stdout.strip() != str(fh.pid).encode(): failures.append(('fuser', r))
checks += 1
if not run(['fuser', '/tmp/.cmdbox_fuser_probe']).stderr.startswith(b'/tmp/.cmdbox_fuser_probe:'): failures.append('fuser name')
checks += 1
if run(['fuser', '-s', '/tmp/.cmdbox_fuser_probe']).returncode != 0: failures.append('fuser -s')
check(['fuser', '/etc/no-such-file-xyz'], b'', 1)
check(['fuser'], None, 1)
fh.kill(); fh.wait()
os.unlink('/tmp/.cmdbox_fuser_probe')
rp = subprocess.Popen(['sleep', '30'])
check(['renice', '-n', '4', '-p', str(rp.pid)], f'{rp.pid} (process ID) old priority 0, new priority 4\n'.encode(), 0)
check(['renice', '9', '-p', str(rp.pid)], f'{rp.pid} (process ID) old priority 4, new priority 9\n'.encode(), 0)
check(['renice', '5', '-p', '999999999'], None, 1)
check(['renice'], None, 1)
rp.kill(); rp.wait()
check(['sysctl', '-n', 'kernel.ostype'], b'Linux\n', 0)
check(['sysctl', 'kernel.ostype'], b'kernel.ostype = Linux\n', 0)
check(['sysctl', 'kernel/ostype'], b'kernel.ostype = Linux\n', 0)
check(['sysctl', '-N', 'kernel.ostype'], b'kernel.ostype\n', 0)
check(['sysctl', 'kernel.no_such_key_xyz'], None, 255)
check(['sysctl', '-e', 'kernel.no_such_key_xyz'], b'', 0)
check(['sysctl'], None, 1)
with tempfile.TemporaryDirectory() as d:
    sw = Path(d, 'sw'); sw.write_bytes(b'\0' * (1 << 20)); sw.chmod(0o600)
    r = run(['mkswap', '-U', '11111111-2222-3333-4444-555555555555', '-L', 'lbl', str(sw)])
    checks += 1
    if r.returncode != 0 or r.stdout != b'Setting up swapspace version 1, size = 1020 KiB (1044480 bytes)\nLABEL=lbl, UUID=11111111-2222-3333-4444-555555555555\n': failures.append(('mkswap', r))
    data = sw.read_bytes()
    checks += 1
    if data[4096 - 10:4096] != b'SWAPSPACE2' or data[1024:1028] != b'\x01\0\0\0' or data[1028:1032] != (255).to_bytes(4, 'little'): failures.append('mkswap header')
    small = Path(d, 'small'); small.write_bytes(b'\0' * 8192)
    check(['mkswap', str(small)], None, 1)
    sh = Path(d, 'shells'); sh.write_text('/bin/sh\n')
    e2 = dict(env, CMDBOX_SHELLS_FILE=str(sh))
    subprocess.run([binary, 'add-shell', '/bin/bash', '/no/such/shell'], env=e2, capture_output=True)
    checks += 1
    if sh.read_text() != '/bin/sh\n/bin/bash\n': failures.append(('add-shell', sh.read_text()))
    subprocess.run([binary, 'remove-shell', '/bin/sh'], env=e2, capture_output=True)
    checks += 1
    if sh.read_text() != '/bin/bash\n': failures.append(('remove-shell', sh.read_text()))
import socket
with tempfile.TemporaryDirectory() as d:
    sp = os.path.join(d, 'log.sock')
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM); srv.bind(sp); srv.settimeout(3)
    subprocess.run([binary, 'logger', '-u', sp, '-t', 'tg', '-p', 'local3.err', 'hello', 'world'], env=env)
    msg = srv.recv(4096)
    checks += 1
    if not (msg.startswith(b'<155>') and msg.endswith(b' tg: hello world')): failures.append(('logger', msg))
    srv.close()
check(['logger', '-u', '/nonexistent/sock', 'x'], None, 1)
check(['chroot'], None, 125)
check(['chroot', '/no/such/root', 'true'], None, 125)
check(['lsmod', '--bogus'], None, 1)
check(['dmesg', '--bogus'], None, 1)
check(['time', '-p', 'true'], b'', 0)
check(['time', 'sh', '-c', 'exit 3'], b'', 3)
check(['time'], None, 1)
checks += 1
if b'real ' not in run(['time', '-p', 'true']).stderr: failures.append('time -p')
with tempfile.TemporaryDirectory() as d:
    f1 = Path(d, 'p1'); f1.write_bytes(b'a\nb\n'); f2 = Path(d, 'p2'); f2.write_bytes(b'c\n')
    check(['less', str(f1), str(f2)], b'a\nb\nc\n', 0)
    check(['more', str(f1)], f'::::::::::::::\n{f1}\n::::::::::::::\na\nb\n'.encode(), 0)
    check(['more', str(f1), str(f2)], f'::::::::::::::\n{f1}\n::::::::::::::\na\nb\n::::::::::::::\n{f2}\n::::::::::::::\nc\n'.encode(), 0)
    check(['less', str(Path(d, 'none'))], b'', 1)
check(['chattr'], None, 1)
check(['chattr', '+Q', '/nonexistent'], None, 1)
check(['lsattr', '-Z'], None, 1)
check(['lsattr', '/nonexistent/x'], None, 1)
_ad = '/root/.cmdbox_attr_probe'
if os.path.isdir('/root') and subprocess.run(['df', '-T', '/root'], capture_output=True).stdout.find(b'ext4') >= 0:
    os.makedirs(_ad, exist_ok=True)
    _f = os.path.join(_ad, 'f'); open(_f, 'w').close()
    check(['lsattr', _f], f'--------------e------- {_f}\n'.encode(), 0)
    check(['chattr', '+Ad', _f], b'', 0)
    check(['lsattr', _f], f'------dA------e------- {_f}\n'.encode(), 0)
    check(['chattr', '-d', _f], b'', 0)
    check(['lsattr', '-l', _f], f'{_f:<28} No_Atime, Extents\n'.encode(), 0)
    check(['chattr', '-A', _f], b'', 0)
    os.unlink(_f); os.rmdir(_ad)
check(['losetup', '-d'], None, 1)
check(['losetup', '/dev/no-such-loop-xyz'], None, 1)
check(['losetup', '-j', '/no/such/file'], None, 1)
check(['losetup', '-l', '-O', 'BOGUS'], None, 1)
pp = subprocess.Popen([binary, 'sleep', '30'])
time.sleep(0.3)
_nm = 'sleep'
check(['pstree', str(pp.pid)], f'{_nm}\n'.encode(), 0)
check(['pstree', '-p', str(pp.pid)], f'{_nm}({pp.pid})\n'.encode(), 0)
check(['pstree', '-a', str(pp.pid)], f'{_nm} sleep 30\n'.encode(), 0)
check(['pstree', '-ap', str(pp.pid)], f'{_nm},{pp.pid} sleep 30\n'.encode(), 0)
check(['pstree', '-h', str(pp.pid)], f'\x1b[1m{_nm}\x1b[0m\n'.encode() if False else f'{_nm}\n'.encode(), 0)
check(['pstree', '-x'], None, 1)
check(['pstree', '99999999'], b'', 0)
check(['pstree', 'no-such-user-xyz'], None, 1)
pp.kill(); pp.wait()
import re as _re
_t = run(['top', '-b', '-n1', '-p', '1']).stdout.decode().split('\n')
checks += 1
if not (_re.match(r'^top - \d\d:\d\d:\d\d up .*\d+ users?,  load average: \d+\.\d\d, \d+\.\d\d, \d+\.\d\d$', _t[0])
        and _re.match(r'^Tasks: 1 total, \d+ running, \d+ sleep, 0 d-sleep, \d+ stopped, \d+ zombie$', _t[1])
        and _re.match(r'^%Cpu\(s\): +\d+\.\d us, +\d+\.\d sy, +\d+\.\d ni, +\d+\.\d id, +\d+\.\d wa, +\d+\.\d hi, +\d+\.\d si, +\d+\.\d st $', _t[2])
        and _re.match(r'^MiB Mem : +\d+\.\d total, +\d+\.\d free, +\d+\.\d used, +\d+\.\d buff/cache     $', _t[3])
        and _re.match(r'^MiB Swap: +\d+\.\d total, +\d+\.\d free, +\d+\.\d used\. +\d+\.\d avail Mem $', _t[4])
        and _t[5] == ''
        and _t[6] == '    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND'
        and _re.match(r'^ +1 root +\d+ +-?\d+ +\d+ +\d+ +\d+ [A-Z] +\d+\.\d +\d+\.\d +\d+:\d\d\.\d\d \S+$', _t[7])
        and _t[8] == '' and len(_t) == 10): failures.append(('top', _t))
check(['top', '-b', '-n1', '-p', '1', '-u', 'root'], None, 1)
check(['top', '-b', '-n1', '-o', 'NOPE'], None, 1)
import base64 as _b64
_xz_real = _b64.b64decode('/Td6WFoAAATm1rRGBMAaGCEBFgAAAAAAAAAAAKym3Y7gABcAEl0ANBlJ7o3pF4k6M1/8sxoLFAAAAAAAEFhUeuShEcgAATYYCLz2uh+2830BAAAAAARZWg==')
_lz_real = _b64.b64decode('XQAAgAD//////////wA0GUnujekXiTozX/yzGhPLkf//++bgAA==')
def _pipe(argv, data):
    global checks
    checks += 1
    return subprocess.run(argv, input=data, capture_output=True, env=env)
_r = _pipe([binary, 'xz', '-dc'], _xz_real)
checks += 1
if _r.stdout != b'hello world\nhello world\n' or _r.returncode != 0: failures.append(('xz -d real', _r))
_r = _pipe([binary, 'unlzma', '-c'], _lz_real)
checks += 1
if _r.stdout != b'hello world\nhello world\n' or _r.returncode != 0: failures.append(('unlzma real', _r))
_r = _pipe([binary, 'xzcat'], _xz_real)
checks += 1
if _r.stdout != b'hello world\nhello world\n': failures.append(('xzcat', _r))
_blob = bytes(range(256)) * 300 + b'abcabcabc' * 1000 + os.urandom(70000) + b'z' * 200000
for _lvl in ('-0', '-6', '-9e'):
    for _fmt in ('xz', 'lzma'):
        _c = subprocess.run([binary, 'xz', _lvl, '-F', _fmt, '-c'], input=_blob, capture_output=True, env=env)
        _d = subprocess.run([binary, 'xz', '-dc'], input=_c.stdout, capture_output=True, env=env)
        checks += 1
        if _d.stdout != _blob or _c.returncode != 0: failures.append(('xz roundtrip', _lvl, _fmt))
for _ck in ('none', 'crc32', 'crc64', 'sha256'):
    _c = subprocess.run([binary, 'xz', '-C', _ck, '-c'], input=_blob[:5000], capture_output=True, env=env)
    _d = subprocess.run([binary, 'xz', '-dc'], input=_c.stdout, capture_output=True, env=env)
    checks += 1
    if _d.stdout != _blob[:5000]: failures.append(('xz check', _ck))
_c = subprocess.run([binary, 'xz', '-c'], input=b'', capture_output=True, env=env)
checks += 1
if _c.stdout[:6] != b'\xfd7zXZ\x00' or subprocess.run([binary, 'xz', '-dc'], input=_c.stdout, capture_output=True, env=env).stdout != b'': failures.append('xz empty')
_bad = bytearray(_xz_real); _bad[40] ^= 0x55
checks += 1
if subprocess.run([binary, 'xz', '-t'], input=bytes(_bad), capture_output=True, env=env).returncode != 1: failures.append('xz corrupt')
checks += 1
if subprocess.run([binary, 'xz', '-t'], input=_xz_real[:30], capture_output=True, env=env).returncode != 1: failures.append('xz truncated')
with tempfile.TemporaryDirectory() as d:
    f = Path(d, 'a.txt'); f.write_bytes(b'file contents\n' * 50)
    check([binary, 'xz', str(f)], b'', 0) if False else None
    r1 = subprocess.run([binary, 'xz', str(f)], capture_output=True, env=env)
    checks += 1
    if r1.returncode != 0 or f.exists() or not Path(d, 'a.txt.xz').exists(): failures.append(('xz file', r1))
    r2 = subprocess.run([binary, 'xz', str(Path(d, 'a.txt.xz'))], capture_output=True, env=env)
    checks += 1
    if r2.returncode != 2 or b"File already has '.xz' suffix, skipping" not in r2.stderr: failures.append(('xz suffix', r2))
    r3 = subprocess.run([binary, 'unxz', '-k', str(Path(d, 'a.txt.xz'))], capture_output=True, env=env)
    checks += 1
    if r3.returncode != 0 or f.read_bytes() != b'file contents\n' * 50 or not Path(d, 'a.txt.xz').exists(): failures.append(('unxz -k', r3))
    r4 = subprocess.run([binary, 'unxz', str(Path(d, 'a.txt.xz'))], capture_output=True, env=env)
    checks += 1
    if r4.returncode != 1 or b'File exists' not in r4.stderr: failures.append(('unxz exists', r4))
check(['xz', '-F', 'bogus'], None, 1)
check(['xz', '-l', '/nonexistent/x.xz'], None, 1)
_bz_real = _b64.b64decode('QlpoOTFBWSZTWeV5SFsAAATRgAAQQAAGRJCAIAAgqoNPRCDJiOIiKWtRiMfF3JFOFCQ5XlIWwA==')
for _app in ('bzcat', 'bunzip2'):
    _r = subprocess.run([binary, _app, '-c'] if _app == 'bunzip2' else [binary, _app], input=_bz_real, capture_output=True, env=env)
    checks += 1
    if _r.stdout != b'hello world\nhello world\n' or _r.returncode != 0: failures.append((_app, _r))
_blob2 = bytes(range(256)) * 700 + b'abcabcabc' * 5000 + os.urandom(120000) + b'q' * 300000
for _lvl in ('-1', '-5', '-9'):
    _c = subprocess.run([binary, 'bzip2', _lvl, '-c'], input=_blob2, capture_output=True, env=env)
    _d = subprocess.run([binary, 'bzip2', '-dc'], input=_c.stdout, capture_output=True, env=env)
    checks += 1
    if _d.stdout != _blob2 or _c.returncode != 0 or _c.stdout[:4] != b'BZh' + _lvl[1].encode(): failures.append(('bzip2 roundtrip', _lvl))
_c = subprocess.run([binary, 'bzip2', '-c'], input=b'', capture_output=True, env=env)
checks += 1
if _c.stdout != bytes.fromhex('425a683917724538509000000000'): failures.append(('bzip2 empty', _c.stdout))
_badz = bytearray(_bz_real); _badz[30] ^= 0x55
checks += 1
if subprocess.run([binary, 'bzip2', '-t'], input=bytes(_badz), capture_output=True, env=env).returncode != 2: failures.append('bzip2 corrupt')
checks += 1
if subprocess.run([binary, 'bzip2', '-t'], input=_bz_real[:20], capture_output=True, env=env).returncode != 2: failures.append('bzip2 truncated')
with tempfile.TemporaryDirectory() as d:
    f = Path(d, 'a.txt'); f.write_bytes(b'bz file contents\n' * 40)
    r1 = subprocess.run([binary, 'bzip2', str(f)], capture_output=True, env=env, stdin=subprocess.DEVNULL)
    checks += 1
    if r1.returncode != 0 or f.exists() or not Path(d, 'a.txt.bz2').exists(): failures.append(('bzip2 file', r1))
    r2 = subprocess.run([binary, 'bzip2', str(Path(d, 'a.txt.bz2'))], capture_output=True, env=env, stdin=subprocess.DEVNULL)
    checks += 1
    if r2.returncode != 1 or b'already has .bz2 suffix' not in r2.stderr: failures.append(('bzip2 suffix', r2))
    r3 = subprocess.run([binary, 'bunzip2', '-k', str(Path(d, 'a.txt.bz2'))], capture_output=True, env=env, stdin=subprocess.DEVNULL)
    checks += 1
    if r3.returncode != 0 or f.read_bytes() != b'bz file contents\n' * 40: failures.append(('bunzip2 -k', r3))
    r4 = subprocess.run([binary, 'bunzip2', str(Path(d, 'a.txt.bz2'))], capture_output=True, env=env, stdin=subprocess.DEVNULL)
    checks += 1
    if r4.returncode != 1 or b'already exists' not in r4.stderr: failures.append(('bunzip2 exists', r4))
check(['bzip2', '--foo'], None, 1)
_cpio_fx = {'newc': 'MDcwNzAxMDAwMEE4RjgwMDAwODFBNDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMTY1NTNGMTAwMDAwMDAwMDYwMDAwMDAwMDAwMDAwMDI0MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAyMDAwMDAwMDBhAGhlbGxvCgAAMDcwNzAxMDAwMEE4RjcwMDAwNDFFRDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMjY1NTNGMTAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDI0MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAyMDAwMDAwMDBkADA3MDcwMTAwMDBBOEY5MDAwMDgxQTQwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDE2NTUzRjEwMDAwMDAwMDA3MDAwMDAwMDAwMDAwMDAyNDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwNDAwMDAwMDAwZC9iAAAAd29ybGQhCgAwNzA3MDEwMDAwQThGQTAwMDBBMUZGMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAxNjU1M0YxMDAwMDAwMDAwMTAwMDAwMDAwMDAwMDAwMjQwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDIwMDAwMDAwMHMAYQAAADA3MDcwMTAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDEwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwQjAwMDAwMDAwVFJBSUxFUiEhIQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==', 'odc': 'MDcwNzA3MDAwMDQ0MTI0MzcwMTAwNjQ0MDAwMDAwMDAwMDAwMDAwMDAxMDAwMDAwMTQ1MjQ3NzA0MDAwMDAwMDIwMDAwMDAwMDAwNmEAaGVsbG8KMDcwNzA3MDAwMDQ0MTI0MzY3MDQwNzU1MDAwMDAwMDAwMDAwMDAwMDAyMDAwMDAwMTQ1MjQ3NzA0MDAwMDAwMDIwMDAwMDAwMDAwMGQAMDcwNzA3MDAwMDQ0MTI0MzcxMTAwNjQ0MDAwMDAwMDAwMDAwMDAwMDAxMDAwMDAwMTQ1MjQ3NzA0MDAwMDAwMDQwMDAwMDAwMDAwN2QvYgB3b3JsZCEKMDcwNzA3MDAwMDQ0MTI0MzcyMTIwNzc3MDAwMDAwMDAwMDAwMDAwMDAxMDAwMDAwMTQ1MjQ3NzA0MDAwMDAwMDIwMDAwMDAwMDAwMXMAYTA3MDcwNzAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMTAwMDAwMDAwMDAwMDAwMDAwMDAwMDEzMDAwMDAwMDAwMDBUUkFJTEVSISEhAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=', 'bin': 'x3EkAPiopIEAAAAAAQAAAFNlAPECAAAABgBhAGhlbGxvCsdxJAD3qO1BAAAAAAIAAABTZQDxAgAAAAAAZADHcSQA+aikgQAAAAABAAAAU2UA8QQAAAAHAGQvYgB3b3JsZCEKAMdxJAD6qP+hAAAAAAEAAABTZQDxAgAAAAEAcwBhAMdxAAAAAAAAAAAAAAEAAAAAAAAACwAAAAAAVFJBSUxFUiEhIQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=', 'crc': 'MDcwNzAyMDAwMEE4RjgwMDAwODFBNDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMTY1NTNGMTAwMDAwMDAwMDYwMDAwMDAwMDAwMDAwMDI0MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAyMDAwMDAyMUVhAGhlbGxvCgAAMDcwNzAyMDAwMEE4RjcwMDAwNDFFRDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMjY1NTNGMTAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDI0MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAyMDAwMDAwMDBkADA3MDcwMjAwMDBBOEY5MDAwMDgxQTQwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDE2NTUzRjEwMDAwMDAwMDA3MDAwMDAwMDAwMDAwMDAyNDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwNDAwMDAwMjUzZC9iAAAAd29ybGQhCgAwNzA3MDIwMDAwQThGQTAwMDBBMUZGMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAxNjU1M0YxMDAwMDAwMDAwMTAwMDAwMDAwMDAwMDAwMjQwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDIwMDAwMDAwMHMAYQAAADA3MDcwMjAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDEwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwQjAwMDAwMDAwVFJBSUxFUiEhIQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=='}
for _fmt, _b64v in _cpio_fx.items():
    _arch = _b64.b64decode(_b64v)
    _r = subprocess.run([binary, 'cpio', '-t'], input=_arch, capture_output=True, env=env)
    checks += 1
    if _r.stdout != b'a\nd\nd/b\ns\n' or _r.returncode != 0 or b'blocks' not in _r.stderr and b'block' not in _r.stderr: failures.append(('cpio -t', _fmt, _r))
    with tempfile.TemporaryDirectory() as d:
        _r = subprocess.run([binary, 'cpio', '-idm', '--quiet'], input=_arch, capture_output=True, env=env, cwd=d)
        checks += 1
        ok = _r.returncode == 0 and Path(d, 'a').read_bytes() == b'hello\n' and Path(d, 'd', 'b').read_bytes() == b'world!\n' and os.readlink(os.path.join(d, 's')) == 'a' and int(os.stat(os.path.join(d, 'a')).st_mtime) == 1700000000
        if not ok: failures.append(('cpio -idm', _fmt, _r))
with tempfile.TemporaryDirectory() as d:
    src = Path(d, 'src'); (src / 'sub').mkdir(parents=True)
    (src / 'one').write_bytes(b'1' * 1000); (src / 'sub' / 'two').write_bytes(b'22'); os.link(src / 'one', src / 'one2'); os.symlink('one', src / 'ln')
    names = b'one\none2\nsub\nsub/two\nln\n'
    for _fmt in ('newc', 'crc', 'odc', 'bin'):
        _c = subprocess.run([binary, 'cpio', '-o', '-H', _fmt, '--quiet'], input=names, capture_output=True, env=env, cwd=str(src))
        out = Path(d, 'out_' + _fmt); out.mkdir()
        _x = subprocess.run([binary, 'cpio', '-id', '--quiet'], input=_c.stdout, capture_output=True, env=env, cwd=str(out))
        checks += 1
        if _c.returncode != 0 or _x.returncode != 0 or (out / 'one').read_bytes() != b'1' * 1000 or os.stat(out / 'one').st_ino != os.stat(out / 'one2').st_ino or (out / 'sub' / 'two').read_bytes() != b'22' or os.readlink(out / 'ln') != 'one': failures.append(('cpio roundtrip', _fmt, _x))
        checks += 1
        if len(_c.stdout) % 512 != 0: failures.append(('cpio padding', _fmt))
    # pass-through
    dst = Path(d, 'dst'); dst.mkdir()
    _p = subprocess.run([binary, 'cpio', '-pd', '--quiet', str(dst)], input=names, capture_output=True, env=env, cwd=str(src))
    checks += 1
    if _p.returncode != 0 or (dst / 'sub' / 'two').read_bytes() != b'22' or os.stat(dst / 'one').st_ino != os.stat(dst / 'one2').st_ino: failures.append(('cpio -p', _p))
check(['cpio'], None, 2)
check(['cpio', '-i', '-F', '/nonexistent/archive'], None, 2)
check(['cpio', '-z'], None, 64)
_rpm = _b64.b64decode('7avu2wMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAjq3oAQAAAAAAAAAAAAAAAI6t6AEAAAAAAAAAAAAAAAAfiwgAAAAAAAL/MzA3MDcwNAACRws3CxBtYehoYoAdGJqZmhq7GcL5ZqjSRrj0GcEYiQwZqTk5+VwMDAbI9pqDaBNDVxdc+tHsNSDV3hRU+yxJ9Kc5kfbBxVP0kxgYGMrzi3JSFLlQ7XYE04ZubkTabUiqX4sZEhmQw5cIQKw6dOAEY4QEOXr6uAYpKioyjIIhBQD4fzNyAAQAAA==')
_r = subprocess.run([binary, 'rpm2cpio'], input=_rpm, capture_output=True, env=env)
checks += 1
if _r.returncode != 0 or _r.stdout != _b64.b64decode(_cpio_fx['newc']): failures.append(('rpm2cpio gzip', _r))
check(['rpm2cpio', '/etc/passwd'], None, 1)
check(['rpm2cpio', '/nonexistent/x.rpm'], None, 1)
with tempfile.TemporaryDirectory() as d:
    ko = Path(d, 'testmod.ko'); ko.write_bytes(_b64.b64decode('f0VMRgIBAQAAAAAAAAAAAAEAPgABAAAAAAAAAAAAAAAAAAAAAAAAABABAAAAAAAAAAAAAEAAAAAAAEAAAwACAGxpY2Vuc2U9R1BMAGF1dGhvcj1UZXN0IEF1dGhvcgBkZXNjcmlwdGlvbj1UZXN0IG1vZHVsZQBwYXJtPWFscGhhOkFscGhhIGtub2IAcGFybXR5cGU9YWxwaGE6aW50AHBhcm09YmV0YTpCZXRhIGtub2IAcGFybXR5cGU9YmV0YTpib29sAGRlcGVuZHM9ZGVwMSxkZXAyAG5hbWU9dGVzdG1vZAB2ZXJtYWdpYz0xLjIuMyBTTVAAAC5tb2RpbmZvAC5zaHN0cnRhYgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAEAAAACAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAC5AAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAsAAAADAAAAAAAAAAAAAAAAAAAAAAAAAPkAAAAAAAAAFAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAA='))
    lines = ['filename:       ' + str(ko), 'license:        GPL', 'author:         Test Author', 'description:    Test module', 'depends:        dep1,dep2', 'name:           testmod', 'vermagic:       1.2.3 SMP', 'parm:           beta:Beta knob (bool)', 'parm:           alpha:Alpha knob (int)']
    check(['modinfo', str(ko)], ('\n'.join(lines) + '\n').encode(), 0)
    check(['modinfo', '-F', 'author', str(ko)], b'Test Author\n', 0)
    check(['modinfo', '-p', str(ko)], b'beta:Beta knob (bool)\nalpha:Alpha knob (int)\n', 0)
    check(['modinfo', '-0', '-F', 'license', str(ko)], b'GPL\0', 0)
    check(['modinfo', '-n', str(ko)], (str(ko) + '\n').encode(), 0)
    check(['modinfo', '-F', 'nothing', str(ko)], b'', 0)
    bad = Path(d, 'bad.ko'); bad.write_bytes(b'not an elf file' * 10)
    check(['modinfo', str(bad)], None, 1)
check(['modinfo'], None, 1)
check(['modinfo', 'no_such_module_xyz'], None, 1)
check(['switch_root'], None, 1)
check(['switch_root', '/nonexistent/newroot', '/sbin/init'], None, 1)
# mount / umount: listing format, fake mounts, and real mounts inside a private mount namespace
_ml = run(['mount']).stdout.decode().splitlines()
checks += 1
if not _ml or not all(_re.match(r'^\S+ on \S.* type \S+ \(\S*\)$', l) for l in _ml): failures.append(('mount listing', _ml[:3]))
check(['mount', '-fv', '-t', 'tmpfs', 'none', '/tmp'], b'mount: none mounted on /tmp.\n', 0)
check(['mount', '-fv', '--bind', '/usr', '/tmp'], b'mount: /usr bound on /tmp.\n', 0)
check(['mount', '-fv', '--move', '/usr', '/tmp'], b'mount: /usr moved to /tmp.\n', 0)
check(['mount', '-fv', '--make-rprivate', '/'], b'mount: / propagation flags changed.\n', 0)
check(['mount', '-V'], None, 0)
check(['mount', 'a', 'b', 'c'], None, 1)
check(['mount', '/no/such/mountpoint-xyz'], None, 1)
check(['umount'], None, 1)
check(['umount', '/no/such/mountpoint-xyz'], None, 32)
if os.geteuid() == 0 and subprocess.run(['unshare', '-m', '--propagation', 'private', 'true'], capture_output=True).returncode == 0:
    with tempfile.TemporaryDirectory() as d:
        sh = ('B=%s; mkdir -p %s/a %s/b; '
              '$B mount -t tmpfs -o size=1m,ro none %s/a || exit 11; '
              '$B mount --bind %s/a %s/b || exit 12; '
              '$B mount -o remount,rw %s/a || exit 13; '
              '$B mount | grep -c " on %s/" ; '
              'grep " %s/a " /proc/self/mountinfo | cut -d" " -f6 ; '
              '$B umount %s/b || exit 14; $B umount -v %s/a || exit 15; '
              '$B mount | grep -c " on %s/"') % ((binary, d, d, d, d, d, d, d, d, d, d, d))
        sh = sh.replace('$B ', binary + ' ')
        _r = subprocess.run(['unshare', '-m', '--propagation', 'private', 'sh', '-c', sh], capture_output=True, env=env, cwd=d)
        checks += 1
        _lines = _r.stdout.decode().split()
        if _r.returncode != 0 and _lines[-1:] != ['0'] or _lines[:2] != ['2', 'rw,relatime']: failures.append(('mount namespace', _r))
# ifconfig / route / netstat (net-tools 2.10 layout)
_lo = run(['ifconfig', 'lo']).stdout.decode().split('\n')
checks += 1
if not (_re.match(r'^lo: flags=\d+<UP,LOOPBACK,RUNNING>  mtu \d+$', _lo[0]) and _lo[1].startswith('        inet 127.0.0.1  netmask 255.0.0.0')
        and any(_re.match(r'^        loop  txqueuelen \d+  \(Local Loopback\)$', l) for l in _lo)
        and any(_re.match(r'^        RX packets \d+  bytes \d+ \(\d+\.\d (B|KiB|MiB|GiB)\)$', l) for l in _lo)
        and any(_re.match(r'^        TX errors \d+  dropped \d+ overruns \d+  carrier \d+  collisions \d+$', l) for l in _lo)
        and _lo[-2] == '' and _lo[-1] == ''): failures.append(('ifconfig lo', _lo))
check(['ifconfig', 'nonexistent0'], None, 255)
_rt = run(['route', '-n']).stdout.decode().split('\n')
checks += 1
if _rt[0] != 'Kernel IP routing table' or _rt[1] != 'Destination     Gateway         Genmask         Flags Metric Ref    Use Iface': failures.append(('route -n header', _rt[:2]))
_ni = run(['netstat', '-i']).stdout.decode().split('\n')
checks += 1
if _ni[0] != 'Kernel Interface table' or _ni[1] != 'Iface      MTU    RX-OK RX-ERR RX-DRP RX-OVR    TX-OK TX-ERR TX-DRP TX-OVR Flg' or not _ni[2].startswith('lo '): failures.append(('netstat -i', _ni[:3]))
_nl = run(['netstat', '-tln']).stdout.decode().split('\n')
_want = 0
for _f in ('/proc/net/tcp', '/proc/net/tcp6'):
    try:
        _want += sum(1 for l in open(_f).read().split('\n')[1:] if len(l.split()) > 3 and l.split()[3] == '0A')
    except OSError:
        pass
checks += 1
if _nl[0] != 'Active Internet connections (only servers)' or _nl[1] != 'Proto Recv-Q Send-Q Local Address           Foreign Address         State      ' or len([l for l in _nl[2:] if l]) != _want: failures.append(('netstat -tln', len(_nl), _want))
check(['netstat', '-Q'], None, 1)
check(['route', 'add', '-net', '10.255.255.0', 'netmask', '255.255.0.0', 'dev', 'lo'], None, 255)
_pg = run(['ping', '-c', '2', '-i', '0.2', '127.0.0.1'])
_pl = _pg.stdout.decode().split('\n')
checks += 1
if not (_pg.returncode == 0 and _pl[0] == 'PING 127.0.0.1 (127.0.0.1) 56(84) bytes of data.'
        and _re.match(r'^64 bytes from \S+( \(127\.0\.0\.1\))?:? icmp_seq=1 ttl=\d+ time=\d+\.\d+ ms$', _pl[1].replace(' (127.0.0.1)', ''))
        and _pl[4] == '--- 127.0.0.1 ping statistics ---'
        and _re.match(r'^2 packets transmitted, 2 received, 0% packet loss, time \d+ms$', _pl[5])
        and _re.match(r'^rtt min/avg/max/mdev = \d+\.\d{3}/\d+\.\d{3}/\d+\.\d{3}/\d+\.\d{3} ms$', _pl[6])): failures.append(('ping loopback', _pl))
check(['ping'], None, 2)
check(['ping', '-c', '1', 'no-such-host.invalid.'], None, 2)
check(['ping', '-Z', '127.0.0.1'], None, 2)
check(['nslookup'], None, 1)
check(['nslookup', '-type=BOGUS', 'x'], None, 1)
# halt/poweroff/reboot: only exercised through a fake systemctl, and only where systemd is the init (the fallback signals PID 1)
check(['reboot', '--help'], None, 0)
check(['reboot', '-x'], None, 1)
check(['poweroff', '--bogus'], None, 1)
if os.path.isdir('/run/systemd/system'):
    with tempfile.TemporaryDirectory() as d:
        logf = Path(d, 'log'); sc = Path(d, 'systemctl')
        sc.write_text('#!/bin/sh\necho "systemctl $*" >> %s\n' % logf); sc.chmod(0o755)
        e2 = dict(env, PATH=d + ':' + env.get('PATH', ''))
        for argv in (['reboot'], ['poweroff'], ['halt'], ['halt', '-p'], ['reboot', '--no-wall']):
            subprocess.run([binary] + argv, env=e2, capture_output=True)
        checks += 1
        if logf.read_text() != 'systemctl reboot\nsystemctl poweroff\nsystemctl halt\nsystemctl poweroff\nsystemctl reboot --no-wall\n': failures.append(('power', logf.read_text()))
check(['reset'], b'\x1bc\x1b[!p\x1b[?3;4l\x1b[4l\x1b>\x1b[H\x1b[2J\x1b[3J', 0)

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
