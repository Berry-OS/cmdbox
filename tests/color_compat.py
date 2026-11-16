"""Compare ANSI bytes with GNU tools, including stdout connected to a PTY."""
import errno
import os
from pathlib import Path
import pty
import subprocess
import sys
import tempfile
import termios

binary = str(Path(sys.argv[1]).resolve())
env = dict(os.environ, LC_ALL='C', TZ='UTC', TERM='xterm-256color', COLORTERM='', LS_COLORS='', GREP_COLORS='')
checks = 0
failures = []

def invoke(command, args, data, environment, terminal=False):
    if not terminal:
        result = subprocess.run(command + args, input=data, capture_output=True, env=environment, timeout=5)
        return result.returncode, result.stdout
    master, slave = pty.openpty()
    try:
        attrs = termios.tcgetattr(slave)
        attrs[1] &= ~termios.OPOST
        termios.tcsetattr(slave, termios.TCSANOW, attrs)
        result = subprocess.run(command + args, input=data, stdout=slave, stderr=subprocess.PIPE, env=environment, timeout=5)
        os.close(slave)
        slave = -1
        output = bytearray()
        while True:
            try:
                chunk = os.read(master, 16384)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            output += chunk
        return result.returncode, bytes(output)
    finally:
        os.close(master)
        if slave >= 0:
            os.close(slave)

def compare(command, args, data=b'', extra=None, terminal=False):
    global checks
    environment = env | (extra or {})
    actual = invoke([binary, command], args, data, environment, terminal)
    expected = invoke([command], args, data, environment, terminal)
    checks += 1
    if actual != expected:
        failures.append((command, args, extra, terminal, actual, expected))

for args in [['-e', r'\e[31mred\e[0m'], ['-e', r'\033[1;34mbold blue\033[0m'],
             ['-ne', r'\x1b[38;5;196m256\x1b[0m'],
             ['-e', r'\e[38;2;12;34;56mRGB\e[0m'],
             ['-e', r'a\n\x'], ['-e', r'\a\b\f\n\r\t\v\\\0123'],
             ['-e', r'before\cafter', 'ignored'], ['-E', r'\e[31m']]:
    compare('echo', args)
for args in [[r'\033[31m%s\033[0m\n','red'], ['%b',r'\e[32mgreen\e[0m'],
             ['%5b',r'a\0b'], ['%.2b',r'a\0b'], ['%-5b',r'a\0b'],
             [r'\x1b[48;2;10;20;30mbackground\x1b[0m\n']]:
    compare('printf', args)
compare('sh',['-c',r"printf '%s\n' $'\e[31mred\e[0m'"])
compare('sh',['-c',r"printf '%s\n' $'\cA\t\x42'"])

sample = b'alpha beta\nno match\nbeta beta\nlast\n'
for flags in [[], ['-n'], ['-Hnb'], ['-o'], ['-c'], ['-Hc'], ['-l'], ['-L'], ['-C1'], ['-v'], ['-z']]:
    compare('grep', ['--color=always', *flags, 'beta'], sample)
for value in ['', 'ms=32:fn=33:ln=34:bn=35:se=36:ne', 'mt=01;35', 'sl=42:cx=44:ms=31:mc=33', 'ms=:fn=:ln=:se=']:
    compare('grep',['--color=always','-HnbC1','beta'],sample,{'GREP_COLORS':value})
for mode in ['never','auto','always']:
    compare('grep',[f'--color={mode}','-n','beta'],sample)
    compare('grep',[f'--color={mode}','-n','beta'],sample,terminal=True)
compare('grep',['--color=auto','beta'],sample,{'TERM':'dumb'},terminal=True)

with tempfile.TemporaryDirectory() as d:
    root=Path(d)
    (root/'dir').mkdir()
    (root/'file').write_bytes(b'old\n')
    (root/'new.txt').write_bytes(b'new\n')
    (root/'script').write_text('#!/bin/sh\n')
    os.chmod(root/'script',0o755)
    (root/'link').symlink_to('dir')
    (root/'orphan').symlink_to('missing')
    os.mkfifo(root/'fifo')
    for path in [root,*root.rglob('*')]:
        os.utime(path,ns=(1700000000000000000,1700000000000000000),follow_symlinks=False)
    for flags in [[], ['-F'], ['-l'], ['-R'], ['-d']]:
        compare('ls',['--color=always',*flags,str(root)])
    for value in ['', 'di=34:ln=36:ex=32:*.txt=31:or=01;31', 'di=38;2;10;20;30:fi=0:pi=33',
                  'ln=target:di=31', 'di=:ln=:ex=:pi=:or=']:
        compare('ls',['--color=always',str(root)],extra={'LS_COLORS':value})
    for mode in ['never','auto','always']:
        compare('ls',['-1',f'--color={mode}',str(root)])
        compare('ls',['-1',f'--color={mode}',str(root)],terminal=True)
    compare('ls',['-1','--color=auto',str(root)],extra={'TERM':'dumb'},terminal=True)
    for mode in ['never','auto','always']:
        for flags in [[], ['-u','-L','old','-L','new']]:
            compare('diff',[f'--color={mode}',*flags,str(root/'file'),str(root/'new.txt')])
    compare('diff',['--color=always','--palette=hd=35:ad=34:de=33:ln=32','-u','-L','a','-L','b',str(root/'file'),str(root/'new.txt')])

    compare('ls',['-1','--color=auto',str(root)],extra={'TERM':'dumb','COLORTERM':'truecolor'},terminal=True)
    compare('ls',['-1','--color=auto',str(root)],extra={'TERM':'foo','LS_COLORS':'di=31'},terminal=True)
    compare('diff',['--color=auto','-u','-L','a','-L','b',str(root/'file'),str(root/'new.txt')],terminal=True)
    compare('diff',['--color=auto','-u','-L','a','-L','b',str(root/'file'),str(root/'new.txt')],extra={'TERM':'dumb'},terminal=True)
for term in ['', 'unknown', 'foo']:
    compare('grep',['--color=auto','beta'],sample,{'TERM':term},terminal=True)

for failure in failures:
    print('FAIL',repr(failure))
print(f'{checks-len(failures)}/{checks} ANSI/color compatibility checks passed')
raise SystemExit(bool(failures))
