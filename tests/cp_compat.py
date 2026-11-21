"""Differential cp checks against GNU cp (skipped when the installed cp is not GNU).
usage: cp_compat.py <cmdbox>"""
import subprocess, sys, os, tempfile, shutil
from pathlib import Path
B = str(Path(sys.argv[1]).resolve())
try:
    ver = subprocess.run(['cp', '--version'], capture_output=True, timeout=5).stdout
except Exception:
    ver = b''
if b'GNU coreutils' not in ver:
    print('GNU cp not available: cp comparison skipped')
    sys.exit(0)
setup = """
mkdir -p src/sub src/empty dst; printf 'hello\\n' > src/f1; printf 'world\\n' > src/sub/f2; ln -s f1 src/sl; ln src/f1 src/hl; chmod 640 src/f1; touch -d @1000000000 src/f1 src/sub/f2; printf 'old\\n' > dst/f1; printf 'x\\n' > other
"""
cases = [
"cp src/f1 out; cat out",
"cp src/f1 dst; cat dst/f1; ls dst",
"cp src/f1 src/sub/f2 dst; ls dst",
"cp src/f1 src/sub/f2 other",
"cp -r src out; find out | sort",
"cp -R src out; find out | sort",
"cp -r src dst; find dst | sort",
"cp -a src out; ls -l --time-style=+%s out | tail -n +2 | awk '{print $1,$2,$6,$7,$8,$9}'",
"cp -p src/f1 out; stat -c '%a %Y' out",
"cp src/f1 out; stat -c '%a' out",
"cp -r src out; stat -c '%N' out/sl",
"cp -rL src out; stat -c '%F' out/sl",
"cp -rP src out; stat -c '%F' out/sl",
"cp -d src/sl out; stat -c '%F' out",
"cp -L src/sl out; stat -c '%F' out",
"cp -s src/f1 out; stat -c '%F %N' out",
"cp -l src/f1 out; stat -c '%h' out",
"cp -u src/f1 dst; cat dst/f1",
"cp -n src/f1 dst; cat dst/f1",
"cp -f src/f1 dst; cat dst/f1",
"cp -v src/f1 out",
"cp -v src/f1 dst",
"cp -rv src out | sort",
"cp -T src/f1 out; cat out",
"cp -T src dst; find dst | sort",
"cp -t dst src/f1 src/sub/f2; ls dst",
"cp --parents src/sub/f2 dst; find dst | sort",
"cp -b src/f1 dst; ls dst; cat dst/f1~",
"cp --backup=numbered src/f1 dst; cp --backup=numbered src/f1 dst; ls dst",
"cp -S .bak -b src/f1 dst; ls dst",
"cp --suffix=.x --backup src/f1 dst; ls dst",
"cp --remove-destination src/f1 dst; cat dst/f1",
"cp src/f1 nonexist/out; echo rc=$?",
"cp nonexist out; echo rc=$?",
"cp src out; echo rc=$?",
"cp src/f1 src/f1; echo rc=$?",
"cp src/f1 src/hl; echo rc=$?",
"cp; echo rc=$?",
"cp src/f1; echo rc=$?",
"cp -r src src/sub/x; echo rc=$?",
"cp --preserve=mode src/f1 out; stat -c '%a' out",
"cp --preserve=timestamps src/f1 out; stat -c '%Y' out",
"cp --preserve=links -r src out; stat -c '%h' out/f1",
"cp --no-preserve=mode -a src/f1 out; stat -c '%a' out",
"cp -x -r src out; ls out",
"cp --attributes-only src/f1 out; wc -c < out",
"cp --reflink=auto src/f1 out; cat out",
"cp --sparse=always src/f1 out; cat out",
"cp -i src/f1 dst < /dev/null; echo rc=$?; cat dst/f1",
"echo y | cp -i src/f1 dst; cat dst/f1",
"cp --update=none src/f1 dst; cat dst/f1",
"cp --update=older src/f1 dst; cat dst/f1",
"cp -- src/f1 out; cat out",
"cp -rT src out; find out | sort",
"cp src/sub/f2 src/f1 nonexistdir; echo rc=$?",
"cp -r src/empty out; ls -d out",
"cp -r src/. out; ls out",
"cp -r src/ out; ls out",
"cp src/f1 dst/; ls dst",
"cp -z src/f1 out; echo rc=$?",
"cp --bogus src/f1 out; echo rc=$?",
"cp -rl src out; stat -c '%h' out/f1",
"cp -a src/sl out; stat -c '%N' out",
"cp -a src/hl src/f1 out_dir 2>/dev/null; mkdir out_dir; cp -a src/hl src/f1 out_dir; stat -c '%h' out_dir/f1",
]
fails = 0
def run(cmdline, prog):
    d = tempfile.mkdtemp()
    env = dict(os.environ, LC_ALL='C', TZ='UTC')
    bd = tempfile.mkdtemp()
    if prog:
        os.symlink(prog, bd + '/cp')
        env['PATH'] = bd + ':' + env['PATH']
    subprocess.run(['bash', '-c', setup], cwd=d, env=env)
    p = subprocess.run(['bash', '-c', cmdline], cwd=d, env=env, capture_output=True, timeout=10)
    shutil.rmtree(d, ignore_errors=True); shutil.rmtree(bd, ignore_errors=True)
    return p.returncode, p.stdout
for c in cases:
    r = run(c, None); b = run(c, B)
    if r != b:
        fails += 1; print('DIFF:', c); print('  gnu:', r); print('  box:', b)
if fails:
    sys.exit(1)
print(f'{len(cases)} cp comparisons against GNU cp passed')
