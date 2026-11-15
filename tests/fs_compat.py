"""Compare exit status and filesystem effects against GNU coreutils."""
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
env = dict(os.environ, LC_ALL='C', TZ='UTC')
checks = 0
failures = []

def setup(root):
    (root / 'src').mkdir()
    (root / 'src' / 'nested').mkdir()
    (root / 'src' / 'file').write_bytes(b'payload\n')
    (root / 'src' / 'nested' / 'file').write_bytes(b'nested\n')
    os.link(root / 'src' / 'file', root / 'src' / 'hard')
    (root / 'src' / 'link').symlink_to('file')
    (root / 'src' / 'dangling').symlink_to('missing')
    os.mkfifo(root / 'src' / 'fifo')
    (root / 'a').write_bytes(b'original\n')
    (root / 'b').write_bytes(b'existing\n')
    (root / 'dest').mkdir()
    (root / 'filelink').symlink_to('a')
    os.chmod(root / 'a', 0o751)
    os.chmod(root / 'src' / 'file', 0o640)
    os.chmod(root / 'src' / 'nested', 0o750)
    for p in [root, *root.rglob('*')]:
        os.utime(p, ns=(1700000000123456789, 1700000000987654321), follow_symlinks=False)

def snapshot(root, timestamps=False):
    result = {}
    links = {}
    def visit(directory):
        mode = stat.S_IMODE(directory.lstat().st_mode)
        os.chmod(directory, mode | stat.S_IRUSR | stat.S_IXUSR)
        try:
            paths = sorted(directory.iterdir())
            for p in paths:
                st = p.lstat()
                kind = stat.S_IFMT(st.st_mode)
                payload = None
                if stat.S_ISLNK(st.st_mode):
                    payload = os.readlink(p)
                elif stat.S_ISREG(st.st_mode):
                    file_mode = stat.S_IMODE(st.st_mode)
                    os.chmod(p, file_mode | stat.S_IRUSR)
                    try:
                        payload = p.read_bytes()
                    finally:
                        os.chmod(p, file_mode)
                name = str(p.relative_to(root))
                result[name] = (kind, stat.S_IMODE(st.st_mode), payload)
                if stat.S_ISREG(st.st_mode):
                    links.setdefault((st.st_dev, st.st_ino), []).append(name)
                if timestamps and name.startswith('out'):
                    result[name] += (st.st_mtime_ns,)
                if stat.S_ISDIR(st.st_mode):
                    visit(p)
        finally:
            os.chmod(directory, mode)
    visit(root)
    return result, sorted(sorted(group) for group in links.values() if len(group) > 1)

def compare(command, args, data=b'', timestamps=False):
    global checks
    with tempfile.TemporaryDirectory() as d:
        roots = [Path(d)/'ours', Path(d)/'gnu']
        results = []
        for root, prefix in zip(roots, [[binary, command], [command]]):
            root.mkdir()
            setup(root)
            process = subprocess.run([*prefix, *args], input=data, capture_output=True, cwd=root, env=env, timeout=5)
            results.append((process.returncode, process.stdout, snapshot(root, timestamps)))
        checks += 1
        if results[0] != results[1]:
            failures.append((command, args, results))

for args in [['a','out'], ['a','b'], ['a','a'], ['a','filelink'], ['-p','a','out'],
             ['-n','a','b'], ['-i','a','b'], ['-T','a','dest'], ['a','b','out'],
             ['-t','dest','a','b'], ['filelink','out'], ['-P','filelink','out'],
             ['-s','a','out'], ['-l','a','out'], ['-R','src','out'], ['-a','src','out'],
             ['-R','src','dest'], ['-r','src','src/sub'], ['--','a','out']]:
    compare('cp', args, timestamps='-p' in args or '-a' in args)
for args in [['a','out'], ['a','b'], ['-n','a','b'], ['-i','a','b'],
             ['-T','a','dest'], ['src','out'], ['a','a'], ['a','b','out']]:
    compare('mv', args)
for args in [['a','out'], ['-s','a','out'], ['a','b'], ['-s','a','b'],
             ['-sf','a','b'], ['-f','a','a'], ['-s','missing','out'],
             ['a','b','dest'], ['-s','a'], ['-T','a','dest']]:
    compare('ln', args)
for args in [['out'], ['-p','out/nested'], ['-p','a'], ['-m','700','out'],
             ['-m','u=rwx,g=rx,o=','out'], ['-p','-m','711','out/nested'],
             ['-m','bad','out'], ['--','-dash']]:
    compare('mkdir', args)
for expression in ['600', 'a+x', 'u=rw,go=r', 'g=u', 'a-x,u+x', 'u+x,g+X',
                   'u+s,g+s,o+t', 'a=', '-x', 'bad']:
    compare('chmod', [expression,'a'])
    compare('chmod', ['-R',expression,'src'])
for args in [['a'], ['-f','missing'], ['missing'], ['-r','src'], ['src'],
             ['-v','a'], ['-rf','src','missing'], ['-i','a'], ['--','a']]:
    compare('rm', args)
for args in [['dest'], ['src'], ['-v','dest'], ['--ignore-fail-on-non-empty','src']]:
    compare('rmdir', args)
for f in failures:
    command, args, (ours, gnu) = f
    print('FAIL', command, args, 'status/stdout:', ours[:2], gnu[:2])
    a, b = ours[2][0], gnu[2][0]
    for key in sorted(a.keys() | b.keys()):
        if a.get(key) != b.get(key): print(' ', key, a.get(key), b.get(key))
    if ours[2][1] != gnu[2][1]: print(' hardlinks', ours[2][1], gnu[2][1])
print(f'{checks-len(failures)}/{checks} GNU filesystem checks passed')
raise SystemExit(bool(failures))
