"""crond: crontab parsing and the matching rules, run once for a given minute (-Z epoch).
usage: crond_compat.py <cmdbox>"""
import os, subprocess, sys, tempfile, time, calendar
from pathlib import Path
binary = str(Path(sys.argv[1]).resolve())
env = {**os.environ, 'TZ': 'UTC'}
fails = []; n = 0

def minute(y, mo, d, h, mi):
    return calendar.timegm((y, mo, d, h, mi, 0))

def fired(tab, when, user='root'):
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(d + '/ct')
        open(d + '/ct/' + user, 'w').write(tab)
        out = d + '/out'
        tab2 = tab.replace('OUT', out)
        open(d + '/ct/' + user, 'w').write(tab2)
        subprocess.run(['bash', '-c', 'exec -a crond "$1" -c "$2" -Z "$3"', 'x', binary, d + '/ct', str(when)], env=env, timeout=20, capture_output=True)
        return open(out).read() if os.path.exists(out) else ''

def check(name, cond, info=''):
    global n
    n += 1
    if not cond:
        fails.append((name, info))

t = minute(2026, 11, 22, 16, 30)  # Sunday
check('every minute', fired('* * * * * echo a >> OUT\n', t) == 'a\n')
check('exact minute hit', fired('30 16 * * * echo a >> OUT\n', t) == 'a\n')
check('minute miss', fired('31 16 * * * echo a >> OUT\n', t) == '')
check('list/range/step', fired('0,15,30 10-17/2 * * * echo a >> OUT\n', t) == 'a\n')
check('range miss', fired('0,15,30 10-15/2 * * * echo a >> OUT\n', t) == '')
check('step hit', fired('*/10 */8 * * * echo a >> OUT\n', t) == 'a\n')
check('month name', fired('30 16 22 nov * echo a >> OUT\n', t) == 'a\n')
check('dow name sun', fired('30 16 * * sun echo a >> OUT\n', t) == 'a\n')
check('dow 7 is sunday', fired('30 16 * * 7 echo a >> OUT\n', t) == 'a\n')
check('dow miss', fired('30 16 * * mon echo a >> OUT\n', t) == '')
check('dom or dow when both restricted', fired('30 16 1 * sun echo a >> OUT\n', t) == 'a\n')
check('dom and star dow', fired('30 16 1 * * echo a >> OUT\n', t) == '')
check('env line', fired('FOO=bar\n30 16 * * * echo $FOO >> OUT\n', t) == 'bar\n')
check('comment and blank', fired('# c\n\n30 16 * * * echo a >> OUT\n', t) == 'a\n')
check('bad line skipped', fired('99 16 * * * echo no >> OUT\n30 16 * * * echo a >> OUT\n', t) == 'a\n')
check('two jobs', fired('30 16 * * * echo a >> OUT\n30 16 * * * echo b >> OUT\n', t) == 'a\nb\n')
check('@daily at 00:00', fired('@daily echo d >> OUT\n', minute(2026, 11, 22, 0, 0)) == 'd\n')
check('@daily not now', fired('@daily echo d >> OUT\n', t) == '')
check('@hourly', fired('@hourly echo h >> OUT\n', minute(2026, 11, 22, 5, 0)) == 'h\n')
check('unknown user skipped', fired('30 16 * * * echo a >> OUT\n', t, 'nosuchuser_x') == '')
if fails:
    for f in fails: print('FAIL', f)
    sys.exit(1)
print(f'{n} crond checks passed')
