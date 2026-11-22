"""lspci / findfs / fsck / fstrim / chvt / fgconsole / eject against the reference tools.
usage: sysutil2_compat.py <cmdbox>   (each case is skipped when the reference tool is missing)"""
import os, shutil, subprocess, sys
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
env = {**os.environ, 'LC_ALL': 'C'}

def run_ref(name, args):
    p = subprocess.run([name] + args, capture_output=True, env=env, timeout=60, input=b'')
    return p.returncode, p.stdout + p.stderr

def run_mine(name, args):
    p = subprocess.run(['bash', '-c', 'exec -a "$0" "$1" "${@:2}"', name, binary] + args,
                       capture_output=True, env=env, timeout=60, input=b'')
    return p.returncode, p.stdout + p.stderr

def clean(out):
    # libkmod noise from the reference and the module list (needs libkmod) are environment dependent
    lines = [l for l in out.decode(errors='replace').split('\n')
             if 'libkmod' not in l and not l.strip().startswith('Kernel modules:')]
    return '\n'.join(lines)

cases = {
    'lspci': [[], ['-n'], ['-nn'], ['-D'], ['-mm'], ['-m'], ['-mm', '-n'], ['-mm', '-nn'], ['-vmm'], ['-vmm', '-nn'],
              ['-x'], ['-t'], ['-tn'], ['-tnn'], ['-tv'], ['-tD'], ['-k'], ['-kn'], ['-v'], ['-vn'], ['-vnn'], ['-vD'],
              ['-s', '00:01'], ['-s', '.0'], ['-d', '8086:'], ['-d', '::0604'], ['--help'], ['-V']],
    'findfs': [[], ['foo'], ['LABEL=nonexist'], ['UUID=zzz'], ['-V'], ['--help']],
    'fsck': [['-N', '/dev/nonexist'], ['-N', '-t', 'ext4', '/dev/loop99'], ['-A', '-N'], ['-V'], ['-N', '-T', '-t', 'ext4', '/dev/x'],
             ['-N', '-a', '-f', '/dev/x'], ['-N', '-t', 'ext4', '-t', 'xfs', '/dev/x'], ['-N', '-t', 'ext4', '--', '-p', '/dev/x'],
             ['-N', '-t', 'xfs', '/dev/x'], ['-N', '/dev/sda1']],
    'fstrim': [[], ['-V'], ['/nonexistent'], ['-o', '1x', '/'], ['-l', '5'], ['--help'], ['-v', '/']],
    'chvt': [[], ['1', '2'], ['--help'], ['-V']],
    'fgconsole': [[], ['-n'], ['--help'], ['-V']],
    'eject': [['-d'], ['-n'], ['nosuchdev'], ['-V'], ['-n', '/dev/null']],
}

fails = []
checks = 0
for name, arglists in cases.items():
    ref = shutil.which(name)
    if not ref or os.path.realpath(ref) == os.path.realpath(binary):
        continue
    for args in arglists:
        checks += 1
        r = run_ref(name, args)
        m = run_mine(name, args)
        if r[0] != m[0] or clean(r[1]) != clean(m[1]):
            fails.append((name, args, r[0], m[0], clean(r[1])[:150], clean(m[1])[:150]))
if fails:
    for f in fails[:20]:
        print('FAIL', f)
    sys.exit(1)
print(f'{checks} sysutil2 comparisons passed')
