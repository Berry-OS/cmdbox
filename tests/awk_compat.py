"""awk differential checks against GNU awk (gawk).  Usage: awk_compat.py cmdbox [gawk]"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
reference = sys.argv[2] if len(sys.argv) > 2 else 'gawk'
env = dict(os.environ, LC_ALL='C', LANG='C', TZ='UTC')
checks = 0
failures = []
_v = subprocess.run([reference, '--version'], capture_output=True, text=True).stdout
if 'GNU Awk' not in _v:
    sys.exit('reference "%s" is not GNU awk' % reference)

SAMPLE = b'''alpha 1 10
beta 22 5
gamma 3 7.5
delta 4 x
  leading   spaces  here
a,b,,d
last line no newline'''
PARA = b'one\ntwo\n\n\nthree\nfour\n\nfive\n'
CSV = b'id,name,score\n1,Ann,90\n2,Bob,85\n3,"Cy",70\n'


def compare(args, data=b'', cwd=None, label=None):
    global checks
    checks += 1
    ours = subprocess.run([binary, 'awk', *args], input=data, capture_output=True, env=env, cwd=cwd)
    gnu = subprocess.run([reference, *args], input=data, capture_output=True, env=env, cwd=cwd)
    if (ours.returncode, ours.stdout) != (gnu.returncode, gnu.stdout):
        failures.append((label or args, ours.returncode, ours.stdout[:300], ours.stderr[:200],
                         gnu.returncode, gnu.stdout[:300]))


def prog(text, data=SAMPLE, *flags):
    compare([*flags, text], data)


# ---- basics
for p in [
    '{print}', '{print $1}', '{print $NF}', '{print NF}', '{print NR, $0}', '{print $2+$3}',
    '{print $(NF-1)}', '{$2="X"; print}', '{$7="Z"; print; print NF}', '{NF=2; print}',
    '{NF=5; print; print NF}', '{$0="a b c"; print $2, NF}', '{print length($0), length}',
    'NR==2', 'NR%2', '/a/', '!/a/', '$2>3', '$2>3 && $3<8', '$1 ~ /^[ab]/', '$1 !~ /a$/',
    'NR==2,NR==4', '/beta/,/delta/{print NR": "$0}', 'END{print NR}', 'END{print $0, NF}',
    'BEGIN{print "start"} {n++} END{print n}', '{s+=$2} END{print s, s/NR}',
    '{a[$1]=$2} END{for(k in a) n++; print n}', '$2==""{print "empty", NR}',
    '{print > "/dev/stderr"}', '{print $1, $2 > "/dev/stdout"}', 'BEGIN{printf "%s\\n", "x"}',
    '{ print NR ": " $0 }', 'length > 8', 'length($1) == 4', '{$1=$1; print}',
    'BEGIN{OFS="-"} {$1=$1; print}', 'BEGIN{OFS="-"} {print $1, $2}', 'BEGIN{ORS="|"} {print $1}',
    '{print toupper($1), tolower("ABC")}', '{print substr($0, 2, 3)}', '{print index($0, "a")}',
    'NR==1{next} {print}', 'NR==2{exit} {print}', 'END{print NR}',
    '{print ($2 > 5) ? "big" : "small"}', '{x = x $1} END{print x}',
    '{if ($2 > 5) print "gt"; else print "le"}', '{ while (i < 3) { i++; s = s i } } END { print s }',
    'BEGIN{for(i=0;i<5;i++) s=s i; print s}', 'BEGIN{do { i++ } while (i<5); print i}',
    'BEGIN{while(1){if(++i>3)break; if(i==2)continue; print i}}',
]:
    prog(p)

# ---- fields and separators
for fs, data in [(',', SAMPLE), (' ', SAMPLE), ('[ ,]+', SAMPLE), ('a', SAMPLE), ('|', b'a|b|c\n'),
                 ('\t', b'a\tb c\td\n'), ('', b'abc\n'), ('\\|', b'a|b|c\n'), ('[0-9]', b'a1b22c\n'),
                 (',', b',a,\n'), (' +', b' a  b \n'), ('.', b'a.b\n')]:
    compare(['-F', fs, '{print NF; for(i=1;i<=NF;i++) printf "[%s]", $i; print ""}'], data)
    compare(['-F' + fs, '{print $1 "|" $NF}'], data)
compare(['-Ft', '{print $2}'], b'a\tb\n')
compare(['BEGIN{FS=","} {print $2}'], SAMPLE)
compare(['{FS=","; print $1}'], SAMPLE)
compare(['-v', 'FS=:', '{print $2}'], b'a:b:c\n')
compare(['-v', 'OFS=:', '{$1=$1}1'], SAMPLE)
compare(['-v', 'n=5', '-v', 's=a\\tb', 'BEGIN{print n+1, s}'])
compare(['{print x}', 'x=1', '-', 'x=2', '-'], b'q\n')
compare(['BEGIN{RS=""} {print NR": "$1"|"$2"|"NF}'], PARA)
compare(['BEGIN{RS="";FS=":"} {print NF}'], b'a:b\nc:d\n\ne\n')
compare(['BEGIN{RS=";"} {print NR": "$0}'], b'a;b;c\n')
compare(['BEGIN{RS="[0-9]+"} {print NR": "$0}'], b'a12b3c\n')
compare(['BEGIN{RS="\\n\\n"} {print NR": "$0}'], b'a\nb\n\nc\n')
compare(['BEGIN{RS=""} {print RT "|"}'], PARA)
compare(['BEGIN{RS="x"} {print RT}'], b'axbxc')
compare(['END{print $0}'], SAMPLE)
compare(['{print FILENAME, FNR, NR}', '/dev/null'], SAMPLE)

# ---- numbers & strings
for p in [
    'BEGIN{print 1e6, 1e-5, 0.1+0.2, 100/3, 2^10, 2**3, -2^2, 7%3, -7%3, 7.5%2}',
    'BEGIN{print 1/3; OFMT="%.2f"; print 1/3; x = 1/3 ""; print x}',
    'BEGIN{CONVFMT="%.2g"; a = 3.14159; b = a ""; print b}',
    'BEGIN{print 2^53, 2^53+1, 1e30, 123456789012, 0.000001, 1e300*1e300, -1e300*1e300}',
    'BEGIN{print int(3.9), int(-3.9), int("12abc"), "3x"+4, "0x10"+0, ".5"+0, "+5"+0, "1e2"+0}',
    'BEGIN{print 1==1.0, "a"<"b", "10"<"9", 10<9, "abc"<1, 2<10, "2"<"10"}',
    'BEGIN{x["a"]; print length(x), ("a" in x), ("b" in x)}',
    'BEGIN{print length("héllo"), length(12345), length()}',
    'BEGIN{print substr("hello",2), substr("hello",0), substr("hello",-1,3), substr("hello",2,100), substr("hello",1.5,2.3), substr("hello",6), substr("hello", 5, 1)}',
    'BEGIN{print index("hello","ll"), index("hello","z"), index("","")}',
    'BEGIN{print toupper("abcXYZ"), tolower("ABCxyz"), toupper(123)}',
    'BEGIN{print sprintf("%d|%5d|%-5d|%05d|%+d|% d", 42, 42, 42, 42, 42, 42)}',
    'BEGIN{print sprintf("%x|%X|%o|%#x|%#o|%u", 255, 255, 8, 255, 8, 7)}',
    'BEGIN{print sprintf("%e|%E|%f|%g|%G|%.3f|%10.2e|%-10.1f|", 1234.5678, 1234.5678, 1234.5678, 1234.5678, 0.00001234, 3.14159, 31415.9, 2.55)}',
    'BEGIN{print sprintf("%s|%10s|%-10s|%.2s|%5.1s|", "abc", "abc", "abc", "abc", "abc")}',
    'BEGIN{print sprintf("%c%c%c", 72, "ello", 33), sprintf("%c", ""), sprintf("%5c|%-5c|", "x", "y")}',
    'BEGIN{print sprintf("%*d|%-*d|%.*f", 5, 42, 5, 42, 2, 3.14159)}',
    'BEGIN{print sprintf("%%|%5%|%d%%", 50)}',
    'BEGIN{print sprintf("%d", "abc"), sprintf("%d", 3.99), sprintf("%d", -3.99), sprintf("%d", 2^31), sprintf("%d", 2^53)}',
    'BEGIN{printf "%s %s %s\\n", "a", "b"}',
    'BEGIN{printf "no newline"}',
    'BEGIN{printf "%i\\n", 42}',
    'BEGIN{x = "A"; y = x x x; print y; print x+0, -x, !x, !"", !0, !"0"}',
    'BEGIN{a = "10"; b = 9; print (a < b), (a+0 < b)}',
    'BEGIN{print 1 " " 2, 1+1 "x", "a" > "/dev/stdout"}',
    'BEGIN{print -12 " " -24}',
    'BEGIN{print 1,2 > "/dev/stdout"; print(1,2)}',
    'BEGIN{print (1)(2)}', 'BEGIN{print (1+2)*3}', 'BEGIN{print 2 ^ 3 ^ 2, -2 ^ 2, 2 ^ -1}',
    'BEGIN{x = 5; x += 2; x -= 1; x *= 3; x /= 2; x %= 5; x ^= 2; print x}',
    'BEGIN{i = 5; print i++, i, ++i, i--, --i}', 'BEGIN{print 1 + 2 " " 3 + 4}',
    'BEGIN{print 1 == 1, 1 != 1, 2 >= 2, 3 <= 2}',
    'BEGIN{x; print (x == 0), (x == ""), length(x)}',
    'BEGIN{print substr("abc", 2, 0) "|" substr("abc", 4) "|" substr("", 1)}',
    'BEGIN{print 0.1*3, 1e15+0.5, 17/4, 1e-10, 123456.789, 1234567.89}',
    'BEGIN{print 3 " " 4 + 5; print 3 (4 + 5)}',
    'BEGIN{$0 = "a b c"; print NF; $5 = "e"; print; print NF}',
    'BEGIN{print 5 " items" + 0}', 'BEGIN{print "x" > "/dev/stderr"}',
    'BEGIN { print substr("hello", 2, 3) ; print substr("hello", 0, 2) }',
    'BEGIN { x = 010; print x, 0x10, 1e3 }',
    'BEGIN { print (1 > 2) ? "a" : "b" }', 'BEGIN { a["x"]=1; delete a["x"]; print length(a) }',
    'BEGIN { print length() }', 'BEGIN { print log(exp(2)), sqrt(16), sin(0), cos(0), atan2(0, -1) }',
    'BEGIN { print int(-0.5), -0, 0 * -1 }', 'BEGIN { print "a" "b" == "ab" }',
    'BEGIN { print index("foobar", "bar") substr("xyz", 2) }',
    'BEGIN { print 1e3 "", 1e-3 "", 12345678901234567890 "" }',
    'BEGIN { print 3.0, 3.10, "3.10", "3.10"+0, 1e0 }',
    'BEGIN{printf "%s\\n"}',
    'BEGIN{print and(12, 10), or(12, 10), xor(12, 10), lshift(1, 4), rshift(256, 4), (compl(0) > 0)}',
    'BEGIN{print strtonum("0x1f"), strtonum("017"), strtonum("12abc"), strtonum(" 5 ")}',
]:
    prog(p, b'')

# ---- regex dialect
for p in [
    '/\\//', '/[[:alpha:]]+ [0-9]+/', '/^[a-z]+ [0-9]{2} /', '/a{2}/', '/\\./', '/[.]/', '/a|b/',
    '/(al|be)pha?/', '/\\<a/', '/[^a-z ]/', '/[a\\]b]/', '/\\$/', '/ {2,}/', '/\\w+ \\w+/',
    '/^$/', '/ $/', '/,,/', '/\\y(alpha)\\y/', '$0 ~ "^a"', '$0 ~ "a" "l"', '$1 ~ /^(a|b)/ {print $1}',
    '{ r = "^" $1; if ("alpha beta" ~ r) c++ } END { print c }',
    '/{/', '/a{/', '/\\{/', '/[{]/',
]:
    prog(p)
compare(['/x\\/y/'], b'x/y\nxy\n')
compare(['$0 ~ "\\\\."'], b'a.b\nab\n')
compare(['$0 ~ "\\."'], b'a.b\nab\n')
compare(['/[/]/'], b'a/b\nab\n')
compare(['{print gsub(/a/, "A"); print}'], SAMPLE)
compare(['{print gsub(/[aeiou]/, "<&>"); print}'], SAMPLE)
compare(['{print sub(/a/, "[&]"); print}'], SAMPLE)
compare(['{gsub(/a/, "\\\\&"); print}'], SAMPLE)
compare(['{gsub(/a/, "\\\\\\\\&"); print}'], SAMPLE)
compare(['{gsub(/a/, "\\\\\\\\\\\\&"); print}'], SAMPLE)
compare(['{gsub(/x*/, "-"); print}'], b'abc\n\nxax\n')
compare(['{gsub(/b*/, "-"); print}'], b'abc\nbbb\n')
compare(['{gsub(/^/, ">"); print}'], b'abc\n')
compare(['{gsub(/$/, "<"); print}'], b'abc\n')
compare(['{gsub(/a|b/, "X", $1); print}'], b'abc bca\n')
compare(['{n = gsub(/ /, "_"); print n, $0, NF}'], b'a b c\n')
compare(['{sub(/$/, "!"); print}'], b'a\n')
compare(['{gsub("[.]", "-"); print}'], b'a.b.c\n')
compare(['{gsub(".", "-"); print}'], b'a.b\n')
compare(['BEGIN{s = "hello"; gsub(/l/, "L", s); print s}'])
compare(['BEGIN{s = "aaa"; print gsub(/a/, "b", s), s}'])
compare(['BEGIN{s = "a.b"; gsub(/\\./, "\\\\.", s); print s}'])
compare(['BEGIN{print match("foobar", /o+/), RSTART, RLENGTH}'])
compare(['BEGIN{print match("foobar", /z/), RSTART, RLENGTH}'])
compare(['BEGIN{print match("abc", //), RSTART, RLENGTH}'])
compare(['BEGIN{match("foo123bar", /[0-9]+/, m); print m[0], length(m)}'])
compare(['BEGIN{match("foo123bar", /([a-z]+)([0-9]+)/, m); print m[1], m[2], m[1, "start"], m[2, "length"]}'])
compare(['BEGIN{print gensub(/(a)(b)/, "\\\\2\\\\1", "g", "abab")}'])
compare(['BEGIN{print gensub(/a/, "X", 2, "aaaa")}'])
compare(['BEGIN{print gensub(/a/, "[&]", "g", "banana")}'])
compare(['BEGIN{print gensub(/a/, "[\\\\0]", "g", "banana")}'])
compare(['{print gensub(/o/, "0", "g")}'], b'foo boo\n')
compare(['BEGIN{n = split("a:b:c", p, ":"); print n, p[1], p[3]}'])
compare(['BEGIN{n = split("a b  c", p); print n, p[1], p[3]}'])
compare(['BEGIN{n = split("a1b22c", p, /[0-9]+/); print n, p[1], p[2], p[3]}'])
compare(['BEGIN{n = split("", p); print n, length(p)}'])
compare(['BEGIN{n = split("abc", p, ""); print n, p[1], p[3]}'])
compare(['BEGIN{n = split("a,b", p, ","); n = split("x", p, ","); print n, length(p), p[1]}'])
compare(['BEGIN{n = split("a:b;c", p, /[:;]/, seps); print n, seps[1], seps[2]}'])
compare(['BEGIN{n = split(" a b ", p, " "); print n, p[1]}'])
compare(['BEGIN{n = split("a.b.c", p, "."); print n, p[2]}'])
compare(['BEGIN{n = split("a|b|c", p, "|"); print n, p[2]}'])
compare(['BEGIN{n = split("2 10 3", p); print (p[1] < p[2]), (p[1] < p[3])}'])

# ---- arrays and functions
compare(['BEGIN{a[1,2]=3; for(k in a){split(k,p,SUBSEP); print p[1], p[2]}; if((1,2) in a) print "yes"}'])
compare(['BEGIN{a["x"]=1; a["y"]=2; delete a; print length(a)}'])
compare(['BEGIN{a[1]; if (1 in a) print "in"; if (!(2 in a)) print "notin"; print length(a)}'])
compare(['BEGIN{for(i=1;i<=5;i++) a[i]=i*i; n=0; for(k in a) n+=a[k]; print n}'])
compare(['function f(x) { return x*2 } BEGIN { print f(4) }'])
compare(['function fact(n) { return n<=1 ? 1 : n*fact(n-1) } BEGIN { print fact(10), fact(20) }'])
compare(['function fib(n) { return n<2 ? n : fib(n-1)+fib(n-2) } BEGIN { print fib(20) }'])
compare(['function g(a) { a[1]=5 } BEGIN { g(x); print x[1] }'])
compare(['function g(a, i) { i = 5; a["k"] = i } BEGIN { g(x); print x["k"], i }'])
compare(['function h(s) { s = "changed"; return s } BEGIN { v = "orig"; print h(v), v }'])
compare(['function noret(x) { x = 1 } BEGIN { v = noret(2); print "[" v "]" }'])
compare(['function a(n) { if (n > 0) { print n; a(n-1) } } BEGIN { a(3) }'])
compare(['function swap(arr, i, j,   t) { t = arr[i]; arr[i] = arr[j]; arr[j] = t } BEGIN { x[1]="a"; x[2]="b"; swap(x,1,2); print x[1], x[2] }'])
compare(['function f(a) { return length(a) } BEGIN { z[1]; z[2]; print f(z) }'])
compare(['func f() { return 1 } BEGIN { print f() }'])
compare(['BEGIN{n=asort(a); b[3]=1; b[1]=9; b[2]=5; n=asort(b); print n, b[1], b[2], b[3]}'])
compare(['BEGIN{b["z"]=1; b["a"]=2; n=asorti(b, c); print n, c[1], c[2]}'])
compare(['BEGIN{a[1]=3; a[2]=1; n=asort(a, d); print d[1], d[2], a[1]}'])
compare(['{c[$1]++} END{n=0; for(k in c) n++; print n}'])
compare(['{w[length($1)]++} END{for(i=1;i<=10;i++) if(i in w) print i, w[i]}'])
compare(['{ lines[NR] = $0 } END { for (i = NR; i >= 1; i--) print lines[i] }'])
compare(['BEGIN{x["a"]=1; f(x)} function f(arr, k) { for (k in arr) print k, arr[k] }'])
compare(['BEGIN{print ARGC, ARGV[0] != "", ARGV[1], ARGV[2]}', 'x', 'y'])
compare(['BEGIN{ARGV[1]=""} {print}', 'nonexistent'], b'')
compare(['BEGIN{ARGC=1} {print}', 'nonexistent'], b'from stdin\n')
compare(['BEGIN{while(("echo a; echo b" | getline line) > 0) print "got", line}'])
compare(['BEGIN{"echo hi" | getline; print $0; print NR}'])
compare(['BEGIN{"echo x y" | getline v; print v; close("echo x y")}'])
compare(['BEGIN{cmd = "echo 5"; cmd | getline n; print n + 1}'])
compare(['BEGIN{print getline < "/nonexistent"}'])
compare(['BEGIN{while ((getline l < "-") > 0) n++; print n}'], SAMPLE)
compare(['NR==1{getline; print "after getline:", $0, NR}'])
compare(['NR==1{getline x; print "x=" x, $0, NR}'])
compare(['{while ((getline line) > 0) n++} END{print n, NR}'])
compare(['BEGIN{print "b\\na" | "sort"; close("sort"); print "done"}'])
compare(['BEGIN{print "x" | "cat"; print "y"}'])
compare(['BEGIN{r = system("exit 3"); print r; r = system("true"); print r}'])
compare(['BEGIN{system("echo from-system"); print "after"}'])
compare(['BEGIN{print "to-file" > "OUT.txt"; close("OUT.txt"); while ((getline l < "OUT.txt") > 0) print "read:", l}'], cwd=tempfile.gettempdir())
compare(['BEGIN{print "a" > "OUT2.txt"; print "b" >> "OUT2.txt"; close("OUT2.txt"); while ((getline l < "OUT2.txt") > 0) print l}'], cwd=tempfile.gettempdir())
compare(['BEGIN{exit 3} END{print "end"}'])
compare(['BEGIN{exit} END{print "end"}'])
compare(['{exit 4} END{print "end", NR}'])
compare(['{exit 4} END{exit}'])
compare(['END{exit 5}'], b'')
compare(['BEGIN{printf "%s", "a" ; exit 1}'])
compare(['BEGIN { print length(x = "abc"), x }'])
compare(['BEGIN { $3 = "c"; print NF, $0 }'])
compare(['BEGIN { print substr("x", 1) > "/dev/stdout" }'])
compare(['BEGIN{print 1; print 2 > "/dev/stderr"; print 3}'])
compare(['BEGIN{print toupper(substr("abc", 1, 1)) substr("abc", 2)}'])
compare(['BEGIN{print srand(), srand()}'])
compare(['BEGIN{srand(1); a = rand(); srand(1); b = rand(); print (a == b), (a < 1), (a >= 0)}'])
compare(['BEGIN{print strftime("%Y-%m-%d %H:%M:%S", 86400*365, 1)}'])
compare(['BEGIN{print (mktime("2020 01 01 00 00 00") > 0), (systime() > 0)}'])
compare(['BEGIN{print mktime("2020 01 01 00 00 00"), mktime("1999 12 31 23 59 59")}'])
compare(['BEGIN{print typeof(x), typeof(1), typeof("a"), typeof(a[1])}'])
compare(['BEGIN{print isarray(a), isarray(1)}'])
compare(['BEGIN { if (!("x" in a)) print "no"; a["x"]; if ("x" in a) print "yes" }'])
compare(['BEGIN { IGNORECASE = 1; print ("ABC" ~ /abc/), ("a" == "A") }'])
compare(['BEGINFILE{print "bf", FILENAME} ENDFILE{print "ef"} {n++} END{print n}', '/dev/null'], b'')
compare(['{ print; next; print "unreached" }'])
compare(['{ if (NR == 2) nextfile; print }'])
compare(['/a/ { print "A:" $0; next } { print "other:" $0 }'])
compare(['BEGIN { printf("%s-%s\\n", "a", "b") }'])
compare(['BEGIN { print("a", "b") > "/dev/stdout" }'])
compare(['BEGIN { a = "x"; b = a++; print a, b }'])
compare(['BEGIN { print length "x" }'], b'')
compare(['{ print length }'])
compare(['BEGIN { getline; print "got:" $0 }'], b'first\nsecond\n')
compare(['BEGIN { while (getline > 0) n++; print n }'], SAMPLE)
compare(['BEGIN { while (getline line > 0) n++; print n }'], SAMPLE)
compare(['BEGIN { x = 1; x = x++ + ++x; print x }'])
compare(['BEGIN { $0 = "3 4"; print $1 * $2, $1 $2, $1 < $2, ($1 "") < ($2 "") }'])
compare(['{ print ($1 < $2) }'], b'10 9\nabc abd\n10 9x\n 5 5.0\n')
compare(['{ print ($1 == $2) }'], b'1 1.0\n0x10 16\n1e2 100\n+5 5\nabc abc\n')
compare(['{ print $1 + 0 }'], b'0x1A\n1e3\n.5\n+.5e1\n-3\ninf\nnan\n+inf\n-nan\n')
compare(['{ print ($1 == 0) }'], b'0\n0.0\n\n-0\nabc\n')
compare(['BEGIN { printf "%d %d\\n", "0x11", 011 }'])
compare(['BEGIN { print length(sprintf("%c", 256)) }'])
compare(['BEGIN { print substr("hello", 2, -1) "|" }'])
compare(['BEGIN { print "a\\tb\\\\c\\"d\\/e\\101\\x41" }'])
compare(['BEGIN { print "multi" \\\n "line" }'])
compare(['BEGIN { if (1) print "a"; else print "b" }'])
compare(['BEGIN { if (0) print "a"\n else print "b" }'])
compare(['BEGIN { if (0)\n print "a"\n else\n print "b" }'])
compare(['BEGIN { for (;;) { if (++i > 3) break }; print i }'])
compare(['BEGIN { for (i = 0; i < 3; i++) ; print i }'])
compare(['BEGIN { x = 3; while (x --> 0) printf "%d ", x; print "" }'])
compare(['BEGIN { a = 1; b = 2; print a " " b; print a, b; print a b }'])
compare(['BEGIN { print 1 }; BEGIN { print 2 }'])
compare(['BEGIN { print 1 }\n\n# comment\nBEGIN { print 2 } # trailing'])
compare(['# only comment'], b'x\n')
compare(['BEGIN { a = "A"; printf a "\\n" }'])
compare(['BEGIN { print substr("hello", length("hello")) }'])
compare(['BEGIN { print -"3" + 1, +"4x", - -5 }'])
compare(['BEGIN { print !x + 1, !!5 }'])
compare(['BEGIN { print 1 in a, length(a) }'])
compare(['BEGIN { print 10 % 3 * 2, 2 * 3 % 4 }'])
compare(['BEGIN { print 1 - 1 - 1, 2 / 2 / 2, 2 ^ 2 ^ 3 }'])
compare(['BEGIN { print "a" < "b" ? "lt" : "ge" }'])
compare(['BEGIN { print (1,2) in a }'])
compare(['BEGIN { OFS = "-"; $0 = "a b c"; $1 = $1; print; print $0 }'])
compare(['BEGIN { $0 = "a b c"; NF = 2; print; print NF }'])
compare(['BEGIN { $0 = "a b c"; $2 = ""; print; print NF }'])
compare(['BEGIN { $0 = " a  b "; print NF; $1 = $1; print "[" $0 "]" }'])
compare(['{ $3 = $1 + $2 } 1'], b'1 2\n3 4\n')
compare(['{ $(NF+2) = "x"; print NF ": " $0 }'], b'a b\n')
compare(['{ print $NF; NF--; print $0 }'], b'a b c\n')
compare(['{ $0 = toupper($0); print $1 }'], b'ab cd\n')
compare(['1; 1'], b'x\n')
compare(['{ print > "/dev/null" } END { print NR }'], SAMPLE)
compare(['BEGIN { FS = "," } { print NF }'], CSV)
compare(['-F,', 'NR>1 { sum += $3 } END { print sum / (NR - 1) }'], CSV)
compare(['-F,', '{ $1 = $1 } 1', ], CSV)
compare(['-F,', '-v', 'OFS=\\t', '{ $1 = $1 } 1', ], CSV)
compare(['BEGIN{printf "%s %s\\n", "only"}'])
compare(['BEGIN{print substr("abc", 2^31)}'])
compare(['BEGIN{x=0; print 1/x}'])
compare(['BEGIN{x=0; print 1%x}'])
compare(['BEGIN{print undefined_fn()}'])
compare(['BEGIN{print'])
compare(['BEGIN{x = }'])
compare(['{print $-1}'], b'a\n')
compare(['-f', '/nonexistent.awk'])
compare([])
compare(['BEGIN{printf "%d\\n", 1e18; printf "%d\\n", -1e18; printf "%.0f\\n", 1e19; printf "%d\\n", 1e19}'])
compare(['BEGIN{printf "%5.1f|%-8.3e|%G\\n", 3.14159, 31415.9, 1e-10}'])
compare(['BEGIN{printf "%s\\n", 1e6; printf "%s\\n", 1234567.5; printf "%s\\n", 0.1}'])
compare(['BEGIN{printf "%d %s\\n", "12abc", 12 "abc"}'])
compare(['BEGIN{x[1]=1; x[2]=2; x[3]=3; for (k in x) delete x[k]; print length(x)}'])
compare(['BEGIN{while (i < 100000) { s = s "x"; i++ }; print length(s)}'])
compare(['BEGIN{for (i = 0; i < 20000; i++) a[i] = i; n = 0; for (k in a) n += a[k]; print n}'])

# ---- larger programs
WORDS = b'the quick brown fox jumps over the lazy dog\nthe dog barks\nfox runs\n'
compare(['{for(i=1;i<=NF;i++) c[$i]++} END{for(w in c) print c[w], w | "sort -k1,1nr -k2"}'], WORDS)
compare(['{for(i=1;i<=NF;i++) c[$i]++} END{n = 0; for (w in c) { l[++n] = w }; for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (l[j] < l[i]) { t = l[i]; l[i] = l[j]; l[j] = t }; for (i = 1; i <= n; i++) print l[i], c[l[i]]}'], WORDS)
compare(['function max(a, b) { return a > b ? a : b } { m = max(m, length($0)) } END { print m }'], WORDS)
compare(['{ for (i = NF; i > 0; i--) printf "%s%s", $i, (i > 1 ? OFS : ORS) }'], WORDS)
compare(['NR == FNR { a[$1] = $2; next } $1 in a { print $1, a[$1], $2 }', '-', '-'], b'k 1\n')
compare(['BEGIN { while ((getline line < ARGV[1]) > 0) n++; print n }', '/etc/hostname'])
compare(['!seen[$0]++'], b'a\nb\na\nc\nb\n')
compare(['{ a[NR] = $0 } END { for (i = 1; i <= NR; i++) print a[i] }'], SAMPLE)
compare(['{ $1 = ""; print substr($0, 2) }'], SAMPLE)
compare(['{ n = split($0, ch, ""); for (i = n; i > 0; i--) printf "%s", ch[i]; print "" }'], b'hello\nabc\n')
compare(['BEGIN { s = "The Quick"; while (match(s, /[A-Z]/)) { printf "%s@%d ", substr(s, RSTART, 1), RSTART; s = substr(s, RSTART + 1) }; print "" }'])
compare(['BEGIN { printf "%-10s|%10s|\\n", "left", "right" }'])
compare(['BEGIN { x = sprintf("%c", 65); print x; print sprintf("%c", 256 + 65) }'])

# ---- script files, multiple -f, -e style
with tempfile.TemporaryDirectory() as d:
    a = Path(d, 'a.awk')
    a.write_text('function double(x) { return x * 2 }\n')
    b = Path(d, 'b.awk')
    b.write_text('{ print double($2) }\n')
    compare(['-f', str(a), '-f', str(b)], SAMPLE)
    compare(['-f', str(b), '-f', str(a)], SAMPLE)
    s = Path(d, 'c.awk')
    s.write_text('#!/usr/bin/awk -f\nBEGIN { print "script", ARGV[1] }\n')
    compare(['-f', str(s), 'arg'])
    f1 = Path(d, 'f1')
    f1.write_bytes(b'x 1\ny 2\n')
    f2 = Path(d, 'f2')
    f2.write_bytes(b'z 3\n')
    compare(['{print FILENAME, FNR, NR, $0}', str(f1), str(f2)], cwd=d)
    compare(['FNR==1{print "new", FILENAME}', 'f1', 'f2'], cwd=d)
    compare(['END{print NR}', 'f1', 'missing', 'f2'], cwd=d)
    compare(['{print}', 'missing'], cwd=d)
    compare(['{print v, $0}', 'v=1', 'f1', 'v=2', 'f2'], cwd=d)
    compare(['BEGIN{print v}', 'v=1'], cwd=d)
    compare(['END{print v}', 'f1', 'v=9'], cwd=d)
    compare(['{print > ("out_" $1)} END{close("out_x"); getline l < "out_x"; print l}', 'f1'], cwd=d)
    compare(['{ print $1 | "sort -r" }', 'f1'], cwd=d)
    compare(['{ print $1 | "cat 1>&2" }', 'f1'], cwd=d)
    compare(['-v', 'x=1', '--', '{print x}', 'f2'], cwd=d)
    compare(['--assign=x=7', '--field-separator= ', '{print x, $2}', 'f2'], cwd=d)
    compare(['--source', 'BEGIN{print "src"}'])
    compare(['-e', 'BEGIN{print "e1"}', '-e', 'BEGIN{print "e2"}'])
    compare(['-F:', '-f', str(b), 'f1'], cwd=d)

print(f'{checks - len(failures)}/{checks} awk compatibility checks passed')
for f in failures:
    print('FAIL', f[0], '\n  ours:', f[1], f[2], f[3], '\n  gawk:', f[4], f[5])
sys.exit(1 if failures else 0)
