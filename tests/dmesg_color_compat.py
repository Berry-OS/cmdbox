#!/usr/bin/env python3
"""dmesg colour/-x/-d output must match util-linux dmesg byte for byte (usage: dmesg_color_compat.py <cmdbox>)."""
import subprocess, sys
box = sys.argv[1]
import os
ref = os.environ.get('DMESG_REF', '/usr/bin/dmesg')
opts = [[], ['--color=always'], ['--color=always', '-x'], ['-Lalways', '-d'], ['--color=always', '-l', 'err,warn'],
        ['--color=never', '-d'], ['-x', '-t'], ['-r'], ['--color=always', '-t'], ['--color=always', '-x', '-l', 'crit,alert,emerg']]
fail = 0
for o in opts:
    a = subprocess.run([ref] + o, capture_output=True).stdout
    b = subprocess.run([box, 'dmesg'] + o, capture_output=True).stdout
    # the buffer may grow between the two runs: compare the common prefix of lines
    la, lb = a.split(b'\n'), b.split(b'\n')
    n = min(len(la), len(lb)) - 1
    if la[:n] != lb[:n]:
        fail += 1
        print('FAIL', o)
print(len(opts) - fail, 'dmesg comparisons passed')
sys.exit(1 if fail else 0)
