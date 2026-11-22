"""Job control through a pseudo terminal: &, jobs, fg, bg, kill %n, Ctrl-Z, wait %n, disown.
usage: jobctl_compat.py <cmdbox>   (fixed expectations modelled on bash output)"""
import os, pty, re, select, sys, time
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
PROMPT = 'PROMPT> '
fails = []


class Sh:
    def __init__(self):
        pid, fd = pty.fork()
        if pid == 0:
            os.environ['PS1'] = PROMPT
            os.environ['TERM'] = 'dumb'
            os.execv(binary, [binary, 'sh', '-i'])
        self.pid, self.fd = pid, fd
        self.buf = ''
        self.expect(PROMPT)

    def expect(self, text, timeout=8):
        end = time.time() + timeout
        while time.time() < end:
            if text in self.buf:
                i = self.buf.index(text) + len(text)
                out, self.buf = self.buf[:i], self.buf[i:]
                return out
            r, _, _ = select.select([self.fd], [], [], 0.2)
            if r:
                try:
                    d = os.read(self.fd, 4096)
                except OSError:
                    break
                if not d:
                    break
                self.buf += d.decode(errors='replace')
        raise TimeoutError('expected %r, got %r' % (text, self.buf))

    def run(self, line, timeout=8):
        os.write(self.fd, (line + '\n').encode())
        return self.expect(PROMPT, timeout).replace('\r', '')

    def send(self, data):
        os.write(self.fd, data)

    def close(self):
        try:
            os.write(self.fd, b'exit\n')
        except OSError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass


def check(name, cond, info=''):
    if not cond:
        fails.append((name, info))


sh = Sh()
try:
    out = sh.run('sleep 30 &')
    check('bg start prints [1] pid', re.search(r'\[1\] \d+', out), out)
    out = sh.run('jobs')
    check('jobs running', re.search(r'\[1\]\+  Running {20}sleep 30 &', out), out)
    out = sh.run('jobs -p')
    check('jobs -p', re.search(r'\n\d+\n', out), out)
    sh.run('kill %1')
    out = sh.run('wait %1; echo st=$?')
    check('wait killed job', 'st=143' in out, out)

    # stop with Ctrl-Z, list, resume in background, kill
    sh.send(b'sleep 40\n')
    time.sleep(0.5)
    sh.send(b'\x1a')
    out = sh.expect(PROMPT).replace('\r', '')
    check('ctrl-z stopped', re.search(r'\[\d\]\+  Stopped {20}sleep 40', out), out)
    out = sh.run('jobs')
    check('jobs stopped', re.search(r'\[\d\]\+  Stopped {20}sleep 40', out), out)
    out = sh.run('bg')
    check('bg resumes', re.search(r'\[\d\]\+ sleep 40 &', out), out)
    out = sh.run('jobs')
    check('jobs running after bg', 'Running' in out and 'sleep 40 &' in out, out)
    sh.run('kill %%')
    sh.run('wait; echo reaped')

    # foreground job interrupted by Ctrl-C
    sh.send(b'sleep 41\n')
    time.sleep(0.5)
    sh.send(b'\x03')
    sh.expect(PROMPT)
    out = sh.run('echo after=$?')
    check('ctrl-c ends foreground job', 'after=130' in out, out)

    # fg brings a stopped job back
    sh.send(b'sleep 1\n')
    time.sleep(0.3)
    sh.send(b'\x1a')
    sh.expect(PROMPT)
    out = sh.run('fg; echo fgst=$?', timeout=10)
    check('fg completes', 'sleep 1' in out and 'fgst=0' in out, out)

    # pipeline stop and resume
    sh.send(b'sleep 42 | cat\n')
    time.sleep(0.5)
    sh.send(b'\x1a')
    out = sh.expect(PROMPT).replace('\r', '')
    check('pipeline stopped', 'Stopped' in out and 'sleep 42 | cat' in out, out)
    sh.run('kill -CONT %1')
    sh.run('kill %1')
    sh.run('wait; echo reaped2')

    # several jobs: markers
    sh.run('sleep 50 &')
    sh.run('sleep 51 &')
    out = sh.run('jobs')
    check('job markers', re.search(r'\[\d\]-  Running {20}sleep 50 &', out) and re.search(r'\[\d\]\+  Running {20}sleep 51 &', out), out)
    out = sh.run('jobs -l')
    check('jobs -l has pid', re.search(r'\[\d\][+-] \d+ Running', out), out)
    sh.run('kill %2')
    sh.run('disown %1')
    out = sh.run('jobs')
    check('disown removes', 'sleep 50' not in out, out)
    out = sh.run('fg %9')
    check('fg unknown job', 'no such job' in out, out)
finally:
    sh.close()

if fails:
    for f in fails:
        print('FAIL', f)
    sys.exit(1)
print('job control checks passed')
