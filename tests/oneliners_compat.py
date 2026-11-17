"""Famous awk/sed one-liners compared with GNU awk / GNU sed.  Usage: oneliners_compat.py cmdbox gawk gnu-sed"""
import os, subprocess, sys
from pathlib import Path
binary = str(Path(sys.argv[1]).resolve())
gawk, gsed = sys.argv[2], sys.argv[3]
env = dict(os.environ, LC_ALL='C', LANG='C', TZ='UTC')
D = b'''The quick brown fox
jumps over the lazy dog   
  indented line with   gaps

12 apples and 7 pears
3.5 4.25 -1e2 0x10
a:b:c:d
repeat repeat
repeat
UPPER lower MiXed
last line here'''
checks = 0
fails = []
def cmp(kind, args, data=D):
    global checks
    checks += 1
    try:
        ours = subprocess.run([binary, kind, *args], input=data, capture_output=True, env=env, timeout=10)
    except subprocess.TimeoutExpired:
        fails.append((kind, args, 'TIMEOUT(ours)')); return
    ref = subprocess.run([gawk if kind == 'awk' else gsed, *args], input=data, capture_output=True, env=env, timeout=10)
    if (ours.returncode, ours.stdout) != (ref.returncode, ref.stdout):
        fails.append((kind, args, ours.returncode, ours.stdout[:200], ours.stderr[:150], ref.returncode, ref.stdout[:200]))
AWK = r'''1;{print ""}
BEGIN{ORS="\n\n"};1
NF{$0=++a " :" $0};1
{print (NF? ++a " :" :"") $0}
END{print NR}
{s=0; for (i=1; i<=NF; i++) s=s+$i; print s}
{for (i=1; i<=NF; i++) if ($i<0) $i=-$i; print}
{total=total+NF}; END {print total}
/Beth/{n++}; END {print n+0}
$1 > max {max=$1; maxline=$0}; END{ print max, maxline}
{ print NF ":" $0 }
{ print $NF }
NF > 4
$NF > 4
{ sub(/^[ \t]+/, ""); print }
{ sub(/[ \t]+$/, ""); print }
{ gsub(/^[ \t]+|[ \t]+$/, ""); print }
{ $1=$1; print }
{ printf "%79s\n", $0 }
{ l=length(); s=int((79-l)/2); printf "%"(s+l)"s\n", $0 }
{ gsub(/foo/,"bar"); print }
{ $0=gensub(/repeat/,"R","g"); print }
/baz/{gsub(/foo/, "bar")}; { print }
{ a[i++]=$0 } END { for (j=i-1; j>=0;) print a[j--] }
/\\$/ { sub(/\\$/,""); getline t; print $0 t; next }; 1
{ $2 = ""; print }
{ for (i=NF; i>0; i--) printf("%s ",$i); printf("\n") }
a != $0; { a = $0 }
!a[$0]++
!($0 in a) { a[$0]; print }
ORS=NR%5?",":"\n"
NR < 3
NR==2 { print; exit }
{ y=x "\n" $0; x=$0 }; END { print y }
/repeat/ { print NR }
NR==2,NR==4
/the/,/dog/
/^$/ { print NR; exit }
length > 20
length < 5
{ print length($0) }
{ n=split($0, w, /[^a-zA-Z]+/); print n }
BEGIN { while (i++ < 5) s = s i; print s }
{ $1 = toupper(substr($1,1,1)) substr($1,2); print }
{ printf "%-20s|%5.1f|\n", $1, $2 }
{ print substr($0, index($0, " ")+1) }
{ print match($0, /[0-9]+/), RSTART, RLENGTH }
NF { print $1 > "/dev/stderr" }
{ $3 = "X"; print NF, $0 }
{ NF = 2; print }
BEGIN { FS=":"; OFS="-" } { $1=$1; print }
BEGIN { RS="" } { print NR ": " $1 }
BEGIN { RS=" " } END { print NR }
{ n = gsub(/[aeiou]/, "&"); t += n } END { print t }
{ words += NF; chars += length($0) + 1 } END { print NR, words, chars }
{ for (i = 1; i <= NF; i++) freq[tolower($i)]++ } END { for (w in freq) if (freq[w] > 1) print w, freq[w] | "sort" }
{ print $1, $1+0, $1*2 }
{ x[NR] = $0 } END { for (i = NR; i; i--) print x[i] }
BEGIN { printf "%c%c%c\n", 72, 105, 33 }
BEGIN { printf "%5.3d|%-5d|%05d|%+.2e\n", 7, 7, 7, 12345.678 }
BEGIN { x = 17; printf "%o %x %X %#o %#x\n", x, x, x, x, x }
BEGIN { print index("abc", "c"), length("héllo"), toupper("é") }
BEGIN { print substr("hello", 2, 3), substr("hello", -1), substr("hello", 4, 100) }
BEGIN { print 1e300*1e300, -1e300*1e300, log(0) }
BEGIN { print 010 + 0, "010" + 0, 1e3, 0x1F + 0 }
BEGIN { print length() }
BEGIN { $0 = "a b c"; $5 = "e"; print; print NF }
BEGIN { a["x"]; delete a["x"]; print length(a) }
BEGIN { print substr("abc", 0), substr("abc", 1.5), substr("abc", 2, 1.5) }
BEGIN { print -3 % 2, 3 % -2, 2 ** 3 ** 2, 2 ^ 0.5 }
BEGIN { print 1 == 1.0, "1" == 1, "a" > "B", "10" < "9" }
BEGIN { print (1 2) + 3, 1 " " 2 + 3 }
BEGIN { n = split("a b c", arr); for (i = n; i; i--) printf "%s ", arr[i]; print "" }
BEGIN { s = "aaa"; print gsub(/a/, "b", s), s }
BEGIN { s = "hello world"; sub(/o/, "[&]", s); print s; gsub(/o/, "\\&", s); print s }
BEGIN { print toupper(substr("word", 1, 1)) tolower(substr("WORD", 2)) }
BEGIN { OFMT = "%.2f"; print 3.14159, 3.14159 "" }
BEGIN { CONVFMT = "%d"; a[12.7] = 1; for (k in a) print k }
BEGIN{FPAT="([^,]*)|(\"[^\"]+\")"; $0="a,\"b,c\",d,"; print NF; for(i=1;i<=NF;i++) printf "[%s]", $i; print ""}
BEGIN{FPAT="[^,]+"; $0=",a,,b,"; print NF}
BEGIN{n=patsplit("a1b22c3",p,/[0-9]+/,s); print n; for(i=0;i<=n;i++) printf "[%s|%s]", p[i], s[i]; print ""}
BEGIN{FPAT="[a-z]+"; FS=","; $0="ab,cd"; print NF}
BEGIN { print length(12.50), length(1e3) }
BEGIN { "date +%Y" | getline y; print (y > 2000) }
BEGIN { while (("echo a b; echo c" | getline l) > 0) print "got", l }
BEGIN { print > "/dev/stdout" }
BEGIN { print substr("x", 2) "|" }
BEGIN { printf "%s %s %s\n", 1, "a" }
BEGIN { printf "%*.*f|\n", 8, 3, 3.14159 }
BEGIN { x["a"] = 1; x["b"] = 2; n = 0; for (k in x) n += x[k]; print n }
BEGIN { if (!(3 in a)) print "no"; if (a[3] == "") print "empty"; if (3 in a) print "now yes" }
function f(a, b) { a[1] = b; return b * 2 } BEGIN { print f(x, 4), x[1] }
function g(n) { return n < 2 ? 1 : n * g(n - 1) } BEGIN { print g(15) }
BEGIN { FPAT = "[^,]+"; $0 = "a,b,,c"; print NF, $2 }
BEGIN { n = patsplit("a1b22c", p, /[0-9]+/); print n, p[1], p[2] }
BEGIN { print (PROCINFO["version"] != ""), PROCINFO["platform"] }
BEGIN { print systime() > 0 }
BEGIN { printf "%s\n", strftime("%Y", 0, 1) }
BEGIN { print and(5, 3), or(5, 3), xor(5, 3), lshift(1, 3), rshift(8, 2) }
BEGIN { print substr("hello", 2); print index("hello", "") }
BEGIN { x = "abc"; print x ~ /b/, x ~ "^a", x !~ /z/ }
BEGIN { print "A" < "a", "a" < "B", 2 < 10, "2" < "10" }
BEGIN { $0 = "1 2 3"; $2 = ""; print; print NF }
BEGIN { $0 = "a:b"; FS = ":"; print $1; $0 = "a:b"; print $1 }
BEGIN { RS = ";" } { print NR ": [" $0 "]" }
BEGIN { RS = "\n\n+" } { print NR }
BEGIN { FS = "" } { print NF }
BEGIN { FS = "\t" } { print NF }
BEGIN { FS = "[ ]" } { print NF }
{ $0 = tolower($0); print $1 }
{ print > ("/tmp/_cmdbox_t_" NR % 2) } END { close("/tmp/_cmdbox_t_0"); while ((getline l < "/tmp/_cmdbox_t_0") > 0) n++; print n }
'''
for line in AWK.strip().split('\n'):
    cmp('awk', [line])
SED = r'''G
n;d
/^$/d
$!N;$!D
1!G;h;$!d
/\n/!G;s/\(.\)\(.*\n\)/&\2\1/;//D;s/.//
$!N;s/\n/ /
:a;/\\$/N;s/\\\n//;ta
s/^[ \t]*//
s/[ \t]*$//
s/^[ \t]*//;s/[ \t]*$//
s/foo/bar/4
s/\(.*\)foo\(.*foo\)/\1bar\2/
s/\(.*\)foo/\1bar/
/baz/!s/foo/bar/g
s/scarlet\|ruby\|puce/red/g
$!N;s/\n/ /;P;D
2q
10q
$!d
$!{h;d;}
x;$G
/e/!d
/e/d
n;n;s/./x/
/lazy/,/apples/d
/^$/,$d
/^repeat$/!d
/[0-9]/!d
s/[0-9]\+/<&>/g
s/\b./\u&/g
s/\w\+/\U&/2
s/\(\w\+\) \(\w\+\)/\2 \1/
y/abcdef/ABCDEF/
s/a/\n/g
=
-n '$='
-n '/fox/{=;p}'
-n '/fox/{p;q}'
-n '2,4p'
-n '4,${p;n;n;}'
-n 'l'
-n '/the/,/dog/{/dog/!p}'
-e :a -e '$q;N;3,$D;ba'
-e :a -e 's/^.\{1,30\}$/ &/;ta'
-e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'
-e '/./,/^$/!d'
-e '/./{H;$!d;}' -e 'x;/fox/!d;'
-e '$!N' -e '/^\(.*\)\n\1$/!P' -e 'D'
-e 'N;P;D'
-e '1~3d'
-e '0~2s/$/ EVEN/'
-e 's/^/    /'
-e 's/./&&/3'
-E s/(a|e)+/<&>/g
-E s/([a-z]+) ([a-z]+)/\2-\1/
-E 's/^(.)(.*)$/\2\1/'
-E 's/(.)\1/[\1\1]/g'
-n -E '/^[A-Z]+ /p'
-s -n '$p'
-z s/\n/,/g
-z 's/^/>/'
s/$/\r/
s/\t/ /g
s/  */ /g
/fox/a\
inserted
/fox/i\
before
/fox/c\
changed
/fox/r /etc/hostname
/fox/w /dev/stdout
2{h;d};4{G}
/dog/{x;p;x}
$a\
END
1i\
START
s/[aeiou]//gI
s/the/THE/Ig
/THE/Id
-n '/the/Ip'
s/.\{5\}/&\n/g
s/^\(.\{10\}\).*/\1/
-n '$!{h;d};H;x;p'
-e 'y/ /\n/'
s/\(^\|[^0-9.]\)\([0-9]\+\)\([0-9]\{3\}\)/\1\2,\3/g
-n 'x;p'
-n 'H;${x;s/\n/,/g;p}'
s/x*/-/g
s/\s\+$//
/^\s*$/d
s/[^[:alnum:] ]//g
s/\(.\)/\1\1/2
-n '/[[:digit:]]\{2\}/p'
-n '/\(.\)\1/p'
s/\//|/g
s,/,|,g
s|a\|b|X|g
'''
SL=[]
for l in SED.strip().split('\n'):
    if SL and SL[-1].endswith('\\') and not SL[-1].endswith('\\\\'): SL[-1]+='\n'+l
    else: SL.append(l)
for line in SL:
    import shlex
    args = shlex.split(line) if line.startswith('-') else [line]
    if line.startswith('-') and line.count("'")==0 and ' ' in line and not line.startswith('-E s'):
        pass
    # pre-split lines that were written with shell quoting; multiline a\ cases handled by joining
    cmp('sed', args)
print(f'{checks-len(fails)}/{checks} one-liner checks passed')
for f in fails: print('FAIL', f)
sys.exit(1 if fails else 0)
