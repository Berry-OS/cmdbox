"""Differential checks of find and xargs against the installed GNU findutils (skipped when absent).
usage: findutils_compat.py <cmdbox>"""
import os, shutil, subprocess, sys, tempfile
from pathlib import Path

B = str(Path(sys.argv[1]).resolve())

def has(cmd, marker):
    try:
        r = subprocess.run([cmd, '--version'], capture_output=True, timeout=5)
        return marker in (r.stdout + r.stderr)
    except Exception:
        return False

fails = 0
checks = 0
env = dict(os.environ, LC_ALL='C')

if shutil.which('find') and (has('find', b'findutils') or has('find', b'bfs')):
    with tempfile.TemporaryDirectory() as d:
        os.chdir(d)
        os.system("mkdir -p t/a/b t/c t/.h && printf x > t/f1 && : > t/a/e && printf hello > t/a/b/f2 && ln -s f1 t/sl && chmod 755 t/a"
                  " && touch -d @1700000000 t/f1 t/a/e && touch -d @1000000000 t/a/b/f2")
        find_cases = [
"t","t -name f1","t -name '*.x' -o -name 'f*'","t -type f","t -type d","t -type l","t -type f -o -type d",
"t -empty","t -size 0","t -size -2c","t -size +3c","t -size 5c","t -mtime +100","t -mtime -1","t -mmin +5","t -newer t/f1",
"t -perm 755","t -perm -644","t -perm /111","t -maxdepth 1","t -mindepth 2","t -mindepth 1 -maxdepth 2","t -path 't/a/*'","t -ipath 'T/A/*'","t -iname 'F*'",
"t -name a -prune -o -print","t ! -name a","t -not -type d","t \\( -name f1 -o -name e \\) -a -type f","t -depth","t -depth -type d",
"t -name f1 -print","t -name f1 -print0 | tr '\\0' '|'","t -type f -exec echo {} \\;","t -type f -exec echo {} +","t -name f1 -exec test -f {} \\; -print",
"t -user root","t -uid 0","t -links 1","t -type f -printf '%p %s %m %y\\n'","t -type f -printf '%f|%h|%d\\n'","t -regex '.*f[12]'","t -true","t -false",
"t -name f1 -o -name e -print","t -name f1 -quit","t -type f -a -name e","t -xdev -type d","t t/a -name e","t t/a t/c","t -name '' ",

        ]
        for c in find_cases:
            checks += 1
            outs = []
            for prog in ('find', B + ' find'):
                r = subprocess.run(['bash', '-c', f"cd {d}; {prog} {c} 2>&1 | sort"], capture_output=True, env=env)
                outs.append(r.stdout.replace(b'bfs: ', b'find: '))
            if outs[0] != outs[1]:
                fails += 1
                print('FIND DIFF:', c, outs[0][:120], outs[1][:120])
else:
    print('GNU find not available: find comparison skipped')

if has('xargs', b'GNU findutils'):
    xcases = [
("a b c\n","echo"),("a b c\n","-n1 echo"),("a b c d e\n","-n2 echo"),("a\nb\nc\n","-L1 echo"),("a b\nc d\ne\n","-L2 echo"),("a b c\n","-I{} echo x{}y"),("a\nb\n","-I% echo [%]"),
("a\0b\0","-0 echo"),("a b\0c\0","-0 -n1 echo"),("a,b,c","-d, echo"),("","echo none"),("","-r echo none"),("a b\n","-t echo"),("'a b' c\n","echo"),('"x y" z\n',"echo"),("a\\ b c\n","echo"),
("a b EOF c\n","-E EOF echo"),("a b c\n","-s 10 echo"),("a b c d e f\n","-s 12 echo"),("x\n","false"),("x\n","sh -c 'exit 255'"),("x\n","nonexistcmd_zz"),("a\nb\n","-n1 sh -c 'echo $0'"),
("1 2 3\n","-n2 printf [%s]\\n"),("a b\n","-i echo {}!"),("a  b\n","-n1 echo"),("a\n\n\nb\n","echo"),(" a \n","echo"),
    ]
    for data, args in xcases:
        checks += 1
        outs = []
        for prog in ('xargs', B + ' xargs'):
            r = subprocess.run(['bash', '-c', f"{prog} {args} 2>&1"], input=data.encode(), capture_output=True, env=env)
            outs.append((r.stdout, r.returncode))
        if outs[0] != outs[1]:
            fails += 1
            print('XARGS DIFF:', repr(data), args, outs)
else:
    print('GNU xargs not available: xargs comparison skipped')

if fails:
    sys.exit(1)
print(f'{checks} find/xargs comparisons against GNU findutils passed')
