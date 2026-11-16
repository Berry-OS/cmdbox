"""Regression checks for record streaming and option validation.

Set GNU_COREUTILS_DIR to an extracted GNU coreutils bin directory to also
compare each case against a verified GNU executable (never a cmdbox symlink).
"""
import os
import fcntl
from pathlib import Path
import random
import resource
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
env = dict(os.environ, LC_ALL='C')
reference = os.environ.get('GNU_COREUTILS_DIR')
checks = 0
if reference:
    for command in ('uniq', 'cut'):
        version = subprocess.run([str(Path(reference) / command), '--version'],
                                 capture_output=True, env=env, timeout=5)
        assert version.returncode == 0 and b'GNU coreutils' in version.stdout, command


def check(command, args, data, expected=None, status=0):
    global checks
    actual = subprocess.run([binary, command, *args], input=data,
                            capture_output=True, env=env, timeout=10)
    if reference:
        gnu = subprocess.run([str(Path(reference) / command), *args], input=data,
                             capture_output=True, env=env, timeout=10)
        assert (actual.returncode, actual.stdout) == (gnu.returncode, gnu.stdout), (command, args, actual, gnu)
    if expected is not None:
        assert (actual.returncode, actual.stdout) == (status, expected), (command, args, actual)
    checks += 1


for data, expected in [(b'', b''), (b'a', b'a\n'), (b'\n\n', b'\n'),
                       (b'a\na\nb\na', b'a\nb\na\n'),
                       (b'x' * 40000 + b'\n' + b'x' * 40000, b'x' * 40000 + b'\n')]:
    check('uniq', [], data, expected)
check('uniq', ['-z'], b'a\0a\0b', b'a\0b\0')
check('uniq', ['-cd'], b'a\na\nb\n', b'      2 a\n')
check('uniq', ['-u'], b'a\na\nb\n', b'b\n')
check('uniq', ['-du'], b'a\na\nb\n', b'')
for args in (['--skip-fields', '1'], ['--skip-fields=1'], ['-f1']):
    check('uniq', args, b'one same\ntwo same\nthree other', b'one same\nthree other\n')
for args in (['--skip-chars', '1'], ['--skip-chars=1'], ['-s1']):
    check('uniq', args, b'xa\nya\nzb', b'xa\nzb\n')
for args in (['--check-chars', '1'], ['--check-chars=1'], ['-w1']):
    check('uniq', args, b'ax\nay\nbz', b'ax\nbz\n')
check('uniq', ['-i'], b'Ab\naB\nother', b'Ab\nother\n')
for args in (['--skip-fields'], ['--skip-chars', '-1'], ['--check-chars=bad']):
    check('uniq', args, b'a\n', b'', 1)
for selection in ('', ',1', '1,', '1,,2', '0', '-', '3-1', '+1', '1-+2', '1  2', ' 1', '1 ', '1, 2'):
    check('cut', ['-b', selection], b'abc\n', b'', 1)
for args in (['-b1', '-d:'], ['-c1', '--delimiter=:'], ['-b1', '-s']):
    check('cut', args, b'a:b\n', b'', 1)
check('cut', ['-f2', '-d:'], b'a:b\nplain', b'b\nplain\n')
check('cut', ['-b1,3', '--output-delimiter=:'], b'abcd', b'a:c\n')

# Randomized record boundaries, binary records, and comparisons after skips.
rng = random.Random(20261116)
for _ in range(40):
    delimiter = rng.choice([b'\n', b'\0'])
    records = [rng.choice([b'', b' a', b' A', b'b', b'b', b'x\ty']) for _ in range(50)]
    data = delimiter.join(records) + rng.choice([b'', delimiter])
    for flags in ([], ['-c'], ['-d'], ['-u'], ['-i'], ['-s1'], ['-f1'], ['-w0']):
        args = (['-z'] if delimiter == b'\0' else []) + flags
        if reference:
            check('uniq', args, data)

# A full nonblocking pipe must report EAGAIN as an error, not a byte count.
reader, writer = os.pipe2(os.O_NONBLOCK)
try:
    capacity = fcntl.fcntl(writer, fcntl.F_GETPIPE_SZ)
    os.write(writer, b'x' * capacity)
    result = subprocess.run([binary, 'uniq'], input=b'a\n', stdout=writer,
                            stderr=subprocess.PIPE, timeout=5)
    assert result.returncode == 1 and b'write error' in result.stderr, result
    checks += 1
finally:
    os.close(reader)
    os.close(writer)

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    source, output = root / 'input', root / 'output'
    source.write_bytes(b'a\na\nb')
    result = subprocess.run([binary, 'uniq', str(source), str(output)], capture_output=True, timeout=5)
    assert result.returncode == 0 and output.read_bytes() == b'a\nb\n', result
    if Path('/dev/full').exists():
        result = subprocess.run([binary, 'uniq', str(source), '/dev/full'], capture_output=True, timeout=5)
        assert result.returncode == 1 and b'write error' in result.stderr, result
    # Input exceeds the child address-space limit. Whole-input buffering fails.
    with source.open('wb') as stream:
        for _ in range(64):
            stream.write(b'a\n' * (512 * 1024))
    def memory_limit():
        resource.setrlimit(resource.RLIMIT_AS, (32 * 1024 * 1024,) * 2)
    result = subprocess.run([binary, 'uniq', '-c', str(source)], capture_output=True,
                            timeout=20, preexec_fn=memory_limit)
    assert result.returncode == 0 and result.stdout == b'33554432 a\n', result
    checks += 3
print(f'{checks} uniq/cut regression checks passed')
