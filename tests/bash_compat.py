"""Bash-extension conformance: runs each script through `cmdbox sh` and `bash` and compares
stdout and exit status (stderr wording differs by design).  Skipped when bash is missing.
usage: bash_compat.py <cmdbox>"""
import os, shutil, subprocess, sys, tempfile
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
if not shutil.which('bash'):
    print('bash not available: bash comparison skipped')
    sys.exit(0)

cases = [
# brace expansion
'echo {a,b,c}', 'echo {1..5}', 'echo a{x,y}b', 'echo {a,b}{1,2}', 'echo {01..05}', 'echo {a..e}',
'echo {10..1..3}', 'echo {a,{b,c},d}', 'echo "{a,b}"', 'echo {a}', 'echo \\{a,b\\}', 'x=1; echo {$x,2}',
'echo {,a}', 'echo a{b,c}d{e,f}', 'echo {-3..3}',
# [[ ]]
'[[ abc == a* ]] && echo yes', '[[ -n x && -z "" ]] && echo yes', '[[ abc =~ b ]] && echo re',
'[[ abc =~ ^a.c$ ]] && echo re2', '[[ a < b ]] && echo lt', '[[ 3 -gt 2 ]] && echo gt',
'[[ ! -e /nonexistent ]] && echo ne', '[[ -d /tmp && ( -w /tmp || -r /tmp ) ]] && echo ok',
'x=a; [[ $x == "a" ]] && echo q', '[[ "a b" == a\\ b ]] && echo sp', '[[ x != y ]]; echo $?',
'[[ foo ]]; echo $?', '[[ "" ]]; echo $?', '[[ a == a || b == c ]] && echo or',
'[[ ab =~ (a)(b) ]] && echo m', '[[ foo123 =~ ([a-z]+)([0-9]+) ]]; echo ${BASH_REMATCH[0]} ${BASH_REMATCH[1]} ${BASH_REMATCH[2]}',
# arithmetic
'(( 3 > 2 )) && echo yes', '(( 0 )); echo $?', 'x=3; (( x += 2 )); echo $x',
'for ((i=0;i<3;i++)); do echo $i; done', 'for ((;;)); do echo once; break; done',
'for ((i=0,j=5;i<j;i+=2)); do echo $i; done', 'i=0; echo $((i++)) $i', 'i=5; echo $((++i)) $i',
'i=5; echo $((i--)) $i', 'echo $((0x1f)) $((017)) $((2#101))', 'echo $(( 64#a ))',
'x=3; echo $((x++ + ++x))', 'echo $((1?2:3)) $((0?2:3))', 'echo $((2**3**2))',
# redirections / pipes / keywords
'cat <<< hi', 'x=v; cat <<< "$x and more"', 'echo out &>/dev/null; echo done',
'ls /nonexistent_dir_xyz 2>&1 | wc -l', 'ls /nonexistent_dir_xyz |& wc -l',
'function f { echo in f; }; f', 'function g() { echo g; }; g',
'case a in a) echo 1;& b) echo 2;;& c) echo 3;; *) echo 4;; esac',
# parameter expansion
'x=hello; echo ${x^^} ${x^} ${x,,}', 'x=HELLO; echo ${x,,} ${x,}', 'a=foo; b=a; echo ${!b}',
'x=foo.bar.baz; echo ${x//./-} ${x/#foo/X} ${x/%baz/Z}', 'x=abc; x+=def; echo $x', 'n=1; n+=2; echo $n',
'f(){ echo "${@:2}"; }; f a b c', 'set -- a b c d; echo "${@:2:2}" ${*:3}',
# arrays
'a=(1 2 3); echo ${a[1]} ${a[@]} ${#a[@]}', 'a=(x "y z" w); for i in "${a[@]}"; do echo "[$i]"; done',
'a=(x "y z" w); echo "${a[*]}"', 'a=(1 2); a+=(3 4); echo ${a[@]}', 'a[5]=x; a[2]=y; echo ${!a[@]} ${a[@]}',
'a=(a b c d); echo ${a[@]:1:2}', 'a=(a b c d); echo ${a[-1]}', 'a=(a b c); unset a[1]; echo ${a[@]} ${#a[@]}',
'a=(p q); b="a[1]"; echo ${!b}', 'a=(1 2 3); echo $a ${#a}', 'a=(1 2 3); i=1; echo ${a[i]} ${a[$i+1]}',
'a=(1 2 3); echo $((a[1]+a[2]))', 'a=(1 2 3); ((a[0]+=5)); echo ${a[0]}', 'a=(one two); echo "${a[@]/o/0}"',
'a=("1 2" 3); b=("${a[@]}"); echo ${#b[@]}', 'a=([2]=x [5]=y z); echo ${!a[@]}', 'x=(); echo ${#x[@]}',
'a=(1 2 3); a[1+1]=x; echo ${a[@]}', 'x=(a b); x[1]+=z; echo ${x[@]}', 'echo a[1 2]',
'declare -A m; m[k]=v; m[j]=w; echo ${m[k]} ${#m[@]}', 'declare -A a; a[x y]=1; for k in "${!a[@]}"; do echo "[$k]"; done',
# declare family
'declare -A m=([k]=v [j]="w x"); declare -p m', 'declare -a a=(1 2 "3 4"); declare -p a',
'declare -irx n=1; declare -p n', 'declare -i n=3+4; echo $n; n+=2; echo $n',
'declare -u x=abc; echo $x; declare -l y=ABC; echo $y',
'f(){ local a=1 b; declare c=3; echo $a $c; }; f; echo ${a-unset}',
'f(){ local -a arr=(1 2); echo ${arr[@]}; }; f; echo ${#arr[@]}',
's="a\\"b"; declare -p s', 'x=1; declare -p x', 'a=(1 2 3); declare -p a',
# builtins
'mapfile -t L <<< $\'a\\nb\\nc\'; echo ${#L[@]} ${L[1]}', 'printf "x\\ny\\n" | { mapfile -t A; echo ${A[@]}; }',
'read -a arr <<< "a b c"; echo ${#arr[@]} ${arr[2]}', 'IFS=: read -r a b <<< "x:y"; echo $a $b',
'printf -v v "%05d" 42; echo $v', 'printf -v "arr[2]" "%s" hi; echo ${arr[2]}',
'read -d "," x <<< "ab,cd"; echo $x', 'read -n 2 x <<< "abcd"; echo $x',
'false | true | false; echo ${PIPESTATUS[@]}', 'true; false; echo ${PIPESTATUS[0]}',
'type -t ls cd if nonex; echo $?', 'f(){ :; }; type -t f',
'shopt -s nullglob; echo /nonexistent_xx*; shopt -u nullglob; echo /nonexistent_xx*',
'shopt -q nullglob; echo $?; shopt nullglob', 'shopt -p nullglob dotglob',
'cd /tmp; pushd /usr >/dev/null; pushd /etc >/dev/null; dirs; popd >/dev/null; dirs -p; pwd',
'cd /tmp; pushd /usr; popd', 'echo $UID $EUID; echo $((SECONDS<2))',
# process substitution, extglob, select, time, misc
'diff <(echo a) <(echo a) && echo same', 'cat <(echo x) <(echo y)',
'while read l; do echo "got $l"; done < <(printf "1\\n2\\n")', 'echo hi > >(cat); sleep 0.1',
'for f in <(echo z); do cat $f; done',
'shopt -s extglob\n[[ abc == @(abc|x) ]] && echo m1; [[ abd == !(abc) ]] && echo m2; [[ aaa == +(a) ]] && echo m3; [[ "" == *(a) ]] && echo m4; [[ b == ?(a)b ]] && echo m5',
'[[ abc == @(abc|x) ]] && echo m1; [[ abc == !(abc) ]] || echo m2',
'shopt -s extglob\ncase foo.txt in *.@(txt|md)) echo doc;; esac',
'shopt -s extglob\nx=foobar; echo ${x#@(foo|x)}; echo ${x/@(oo|ar)/_}',
'cd /tmp; rm -rf eg_t; mkdir eg_t; cd eg_t; touch a.c b.c c.h d.txt\nshopt -s extglob\necho *.@(c|h); echo !(*.c); echo +(a|b).c; echo ?(a).c; cd ..; rm -rf eg_t',
'PS3="pick: "; select x in a b c; do echo "got $x ($REPLY)"; break; done <<< "2"',
'time true; echo $?', 'x=$(</etc/hostname); echo ${#x} | grep -c "^[0-9]*$"',
'f(){ echo ${FUNCNAME[0]} ${#FUNCNAME[@]}; }; f', 'g(){ f; }; f(){ echo "${FUNCNAME[@]}"; }; g',
'declare -n r=v; v=5; echo $r; r=7; echo $v', 'f(){ local -n p=$1; p=changed; }; z=1; f z; echo $z',
'a=(1 2 3); declare -n r=a; echo ${r[1]} ${#r[@]}; r[1]=9; echo ${a[@]}',
'exec {fd}>"$TMPDIR_T/o.txt"; echo hi >&$fd; exec {fd}>&-; cat "$TMPDIR_T/o.txt"',
'sleep 0.1 & sleep 0.05 & wait -n; echo done', 'f(){ trap "echo ret" RETURN; echo in; }; f',
'trap "echo x" EXIT; trap -p EXIT', 'printf "%q\\n" "a b" "" "x\\ty" "a\\\'b"', 'printf "%(%Y)T\\n" 0',
'builtin echo hi; builtin cd /; pwd', 'shopt -s lastpipe; echo a | read v; echo $v', 'echo a | read v; echo "[$v]"',
'shopt -s lastpipe; printf "1\\n2\\n" | while read l; do n=$l; done; echo $n',
'echo "${arr[@]:-none}"', 'arr=(); echo "${arr[@]:-none}"; arr=(x); echo "${arr[@]:-none}" "${arr[@]:+yes}"',
'a=(1 2 3); echo ${a[@]: -1} ${a[@]:1}',
]

failures = []
for c in cases:
    c = c.replace('\\n', '\n') if False else c
    outs = []
    for argv in (['bash'], [binary, 'sh']):
        with tempfile.TemporaryDirectory() as d:
            try:
                r = subprocess.run(argv + ['-c', c], capture_output=True, timeout=10, input=b'', cwd=d,
                                   env={**os.environ, 'LC_ALL': 'C', 'TMPDIR_T': d})
            except subprocess.TimeoutExpired:
                outs.append(('TIMEOUT',))
                continue
            outs.append((r.stdout, r.returncode))
    if outs[0] != outs[1]:
        failures.append((c, outs[0], outs[1]))
if failures:
    for f in failures[:20]:
        print('FAIL', f)
    sys.exit(1)
print(f'{len(cases)} bash extension checks passed')
