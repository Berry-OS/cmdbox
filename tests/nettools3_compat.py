"""rdate / whois / telnet / ftpput against local fake servers, traceroute to loopback.
usage: nettools3_compat.py <cmdbox>"""
import os, re, socket, struct, subprocess, sys, threading, time
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
fails = []
n = 0
env = {**os.environ, 'LC_ALL': 'C', 'TZ': 'UTC'}

def run(name, args, inp=b'', timeout=30):
    return subprocess.run(['bash', '-c', 'exec -a "$0" "$1" "${@:2}"', name, binary] + args,
                          input=inp, capture_output=True, timeout=timeout, env=env)

def check(name, cond, info=''):
    global n
    n += 1
    if not cond:
        fails.append((name, info))

def serve(handler, count=1):
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('127.0.0.1', 0))
    srv.listen(4)
    res = {}
    def loop():
        for _ in range(count):
            c, _a = srv.accept()
            try:
                handler(c, res)
            finally:
                c.close()
        srv.close()
    t = threading.Thread(target=loop, daemon=True)
    t.start()
    return srv.getsockname()[1], res, t

# ---- rdate
def h_time(c, res):
    c.sendall(struct.pack('>I', 1700000000 + 2208988800))
port, res, t = serve(h_time)
r = run('rdate', ['-p', '-P', str(port), '127.0.0.1'])
check('rdate -p', r.stdout == b'Tue Nov 14 22:13:20 2023\n', r.stdout + r.stderr)
r = run('rdate', ['-s'])
check('rdate usage', r.returncode == 1 and b'Usage: rdate' in r.stderr, r.stderr)
r = run('rdate', ['-p', '-P', '1', '127.0.0.1'])
check('rdate refused', r.returncode == 1 and b'could not connect' in r.stderr, r.stderr)

# ---- whois
def h_whois(c, res):
    res['q'] = c.recv(1024)
    c.sendall(b'Domain Name: EXAMPLE.TEST\r\nRegistrar: Test\r\n')
port, res, t = serve(h_whois)
r = run('whois', ['-h', '127.0.0.1', '-p', str(port), 'example.test'])
t.join(5)
check('whois output', r.stdout == b'Domain Name: EXAMPLE.TEST\r\nRegistrar: Test\r\n', r.stdout + r.stderr)
check('whois query', res.get('q') == b'example.test\r\n', res)
r = run('whois', [])
check('whois usage', r.returncode == 2, r.stderr)

# ---- ftpput
store = {}
def h_ftp(c, res):
    c.sendall(b'220 fake ftp\r\n')
    f = c.makefile('rwb')
    data_srv = None
    while True:
        line = f.readline()
        if not line:
            break
        cmd = line.decode().strip()
        res.setdefault('cmds', []).append(cmd)
        verb = cmd.split(' ')[0].upper()
        if verb == 'USER':
            c.sendall(b'331 password please\r\n')
        elif verb == 'PASS':
            c.sendall(b'230 logged in\r\n')
        elif verb == 'TYPE':
            c.sendall(b'200 binary\r\n')
        elif verb == 'PASV':
            data_srv = socket.socket()
            data_srv.bind(('127.0.0.1', 0))
            data_srv.listen(1)
            p = data_srv.getsockname()[1]
            c.sendall(('227 Entering Passive Mode (127,0,0,1,%d,%d)\r\n' % (p >> 8, p & 255)).encode())
        elif verb == 'STOR':
            c.sendall(b'150 go ahead\r\n')
            dc, _ = data_srv.accept()
            buf = b''
            while True:
                d = dc.recv(65536)
                if not d:
                    break
                buf += d
            dc.close()
            store[cmd.split(' ', 1)[1]] = buf
            c.sendall(b'226 done\r\n')
        elif verb == 'QUIT':
            c.sendall(b'221 bye\r\n')
            break
        else:
            c.sendall(b'502 no\r\n')
import tempfile
with tempfile.TemporaryDirectory() as d:
    open(d + '/up.bin', 'wb').write(bytes(range(256)) * 100)
    port, res, t = serve(h_ftp)
    r = run('ftpput', ['-P', str(port), '-u', 'bob', '-p', 'pw', '127.0.0.1', 'remote.bin', d + '/up.bin'])
    t.join(5)
    check('ftpput rc', r.returncode == 0, r.stderr)
    check('ftpput data', store.get('remote.bin') == bytes(range(256)) * 100)
    check('ftpput login', 'USER bob' in res.get('cmds', []) and 'PASS pw' in res.get('cmds', []), res)
    port, res, t = serve(h_ftp)
    r = run('ftpput', ['-P', str(port), '127.0.0.1', d + '/up.bin'])
    t.join(5)
    check('ftpput default name', 'up.bin' in store and 'USER anonymous' in res.get('cmds', []), (list(store), res))
r = run('ftpput', ['127.0.0.1'])
check('ftpput usage', r.returncode == 1 and b'Usage: ftpput' in r.stderr, r.stderr)

# ---- telnet (stdin is a pipe: no raw mode)
def h_telnet(c, res):
    c.sendall(bytes([255, 253, 24, 255, 251, 1, 255, 253, 99]) + b'login: ')
    time.sleep(0.2)
    res['got'] = c.recv(1024)
    c.sendall(b'Welcome\r\n')
    time.sleep(0.2)
port, res, t = serve(h_telnet)
r = run('telnet', ['127.0.0.1', str(port)], inp=b'root\n', timeout=10)
t.join(5)
check('telnet banner', b'Trying 127.0.0.1...' in r.stdout and b'Connected to 127.0.0.1.' in r.stdout and b'login: ' in r.stdout and b'Welcome' in r.stdout, r.stdout)
got = res.get('got', b'')
check('telnet negotiation', bytes([255, 251, 24]) in got and bytes([255, 253, 1]) in got and bytes([255, 252, 99]) in got and b'root\n' in got, got)
check('telnet closed', b'Connection closed by foreign host.' in r.stdout, r.stdout)
r = run('telnet', [])
check('telnet usage', r.returncode == 1, r.stderr)


# ---- ntpd -w (query only, never touches the clock)
def ntp_server(offset):
    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.bind(('127.0.0.1', 0))
    def loop():
        srv.settimeout(10)
        for _ in range(3):
            try:
                data, addr = srv.recvfrom(256)
            except Exception:
                return
            now = time.time() + offset + 2208988800
            sec, frac = int(now), int((now % 1) * (1 << 32))
            reply = bytearray(48)
            reply[0] = (0 << 6) | (4 << 3) | 4
            reply[1] = 2
            reply[24:32] = data[40:48]
            struct.pack_into('>II', reply, 32, sec, frac)
            struct.pack_into('>II', reply, 40, sec, frac)
            srv.sendto(bytes(reply), addr)
    threading.Thread(target=loop, daemon=True).start()
    return srv.getsockname()[1]
port = ntp_server(5.0)
r = run('ntpd', ['-w', '-p', '127.0.0.1:%d' % port])
m = re.match(rb'\+(\d+)\.(\d{6})\n$', r.stdout)
check('ntpd offset query', m is not None and abs(float(r.stdout[1:]) - 5.0) < 0.5, r.stdout + r.stderr)
r = run('ntpd', ['-w', '-p', '127.0.0.1:9'])
check('ntpd no reply', r.returncode == 1 and b'no reply' in r.stderr, r.stderr)
r = run('ntpd', [])
check('ntpd needs a peer', r.returncode == 1, r.stderr)

# ---- traceroute on loopback
r = run('traceroute', ['-n', '127.0.0.1'], timeout=30)
check('traceroute header', r.stdout.startswith(b'traceroute to 127.0.0.1 (127.0.0.1), 30 hops max, 60 byte packets\n'), r.stdout + r.stderr)
check('traceroute hop', re.search(rb'\n 1  127\.0\.0\.1  \d+\.\d{3} ms  \d+\.\d{3} ms  \d+\.\d{3} ms\n$', r.stdout) is not None, r.stdout)
r = run('traceroute', ['-n', '-I', '-q', '1', '127.0.0.1'], timeout=30)
check('traceroute -I', re.search(rb'\n 1  127\.0\.0\.1  \d+\.\d{3} ms\n$', r.stdout) is not None, r.stdout + r.stderr)
r = run('traceroute', [])
check('traceroute usage', r.returncode == 2, r.stderr)

if fails:
    for f in fails:
        print('FAIL', f)
    sys.exit(1)
print(f'{n} nettools3 checks passed')
