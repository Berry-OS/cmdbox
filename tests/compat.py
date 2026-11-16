"""Behavioral checks against host utilities; never touches the host installation."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
checks = 0

def compare(command, args=(), data=b''):
    global checks
    env = dict(os.environ, LC_ALL='C')
    actual = subprocess.run([binary, command, *args], input=data, capture_output=True, env=env)
    expected = subprocess.run([command, *args], input=data, capture_output=True, env=env)
    assert (actual.returncode, actual.stdout) == (expected.returncode, expected.stdout), (
        command, args, actual.returncode, actual.stdout, actual.stderr,
        expected.returncode, expected.stdout)
    checks += 1

for args in [[], ['hello', 'world'], ['-unknown', 'text'], ['-n', 'hello'], ['-ne', r'a\tb']]:
    compare('echo', args)
for data in [b'', b'hello\n', bytes(range(256)) * 31]:
    compare('cksum', data=data)
for command, args in [('true', []), ('false', []), ('basename', ['/']),
                      ('basename', ['/a/b/', 'b']), ('seq', ['3']),
                      ('test', ['3', '-gt', '2'])]:
    compare(command, args)
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / 'input'
    path.write_bytes(b'beta\nalpha\nalpha\n')
    compare('cksum', [str(path)])
    compare('wc', ['-l', str(path)])
    compare('cat', [str(path)])
    compare('sort', [str(path)])
    # Verify dispatch by argv[0], independent of cmdbox APPLET dispatch.
    link = Path(directory) / 'echo'
    link.symlink_to(binary)
    assert subprocess.check_output([str(link), 'symlink']) == b'symlink\n'
    checks += 1
for args in [['-i', 'A=one'], ['-i', 'A=one', 'A=two'],
             ['-i', 'A=one', '/usr/bin/printenv', 'A'],
             ['-i', 'PATH=/usr/bin:/bin', 'printenv', 'PATH']]:
    compare('env', args)
with tempfile.TemporaryDirectory() as directory:
    a, b = [Path(directory) / name for name in ('a', 'b')]
    for left, right in [(b'hello\n', b'hello\n'), (b'a\n', b'b\n'),
                        (b'', b'new\n'), (b'old\n', b''),
                        (b'a', b'b'), (b'prefix\na\nend\n', b'prefix\nb\nend\n')]:
        a.write_bytes(left)
        b.write_bytes(right)
        compare('diff', [str(a), str(b)])
        compare('cmp', ['-s', str(a), str(b)])
compare('sh', ['-c', 'echo hello | cat; false || echo recovered'])
print(f'{checks} compatibility checks passed')
