#!/usr/bin/env python3
"""Local GNU wget behavior and adversarial TLS certificate tests (no Internet)."""
import http.server
import os
from pathlib import Path
import ssl
import select
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading

BINARY = str(Path(sys.argv[1]).resolve())
FIXTURES = Path(__file__).resolve().parent / "tls"
def context(name):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(FIXTURES/(name+".pem"), FIXTURES/(name+".key"))
    return ctx
COUNT = 0
GNU_WGET = os.environ.get("GNU_WGET")
REFERENCES = (False, True) if GNU_WGET else (False,)
DATA = b'hello wget\n' * 120

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_HEAD(self): self.do_GET()
    def do_POST(self): self.do_GET()
    def do_GET(self):
        path = self.path
        if path == '/redirect':
            self.send_response(302); self.send_header('Location', '/data'); self.send_header('Content-Length','0'); self.end_headers(); return
        if path == '/loop':
            self.send_response(302); self.send_header('Location', '/loop'); self.send_header('Content-Length','0'); self.end_headers(); return
        if path == '/chunked':
            self.send_response(200); self.send_header('Transfer-Encoding','chunked'); self.end_headers()
            self.wfile.write(b'3\r\nabc\r\n2\r\nde\r\n0\r\nX-Trailer: ok\r\n\r\n'); return
        data = DATA
        status = 200
        if path == '/missing': status, data = 404, b'missing'
        if path == '/auth':
            if self.headers.get('Authorization') != 'Basic dXNlcjpwYXNz': status, data = 401, b'auth'
        if path == '/headers': data = (self.headers.get('X-Test','') + '|' + self.headers.get('User-Agent','')).encode()
        if path == '/post': data = self.rfile.read(int(self.headers.get('Content-Length','0')))
        offset = 0
        if self.headers.get('Range'):
            offset = int(self.headers['Range'][6:-1]); data = data[offset:]; status = 206
        self.send_response(status)
        self.send_header('Content-Length', str(len(data) + (10 if path == '/truncated' else 0)))
        if status == 206: self.send_header('Content-Range', f'bytes {offset}-{len(DATA)-1}/{len(DATA)}')
        if path == '/disposition': self.send_header('Content-Disposition', 'attachment; filename="chosen.txt"')
        if path == '/truncated': self.send_header('Connection','close'); self.close_connection = True
        self.end_headers()
        if self.command != 'HEAD': self.wfile.write(data)

class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def handle_error(self, *args): pass

def serve(context=None):
    server = Server(('127.0.0.1',0), Handler)
    if context: server.socket = context.wrap_socket(server.socket,server_side=True)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    return server


class Tunnel(socketserver.StreamRequestHandler):
    def handle(self):
        request=self.rfile.readline().decode().strip().split()
        if not request: return
        headers={}
        while True:
            line=self.rfile.readline()
            if line==b'\r\n' or not line: break
            name,value=line.decode().split(':',1); headers[name.lower()]=value.strip()
        assert request[0]=='CONNECT',request
        assert headers.get('proxy-authorization')=='Basic cHJveHk6cGFzcw==',headers
        host,port=request[1].rsplit(':',1)
        with socket.create_connection((host,int(port)),timeout=3) as upstream:
            self.wfile.write(b'HTTP/1.1 200 Connection established\r\n\r\n'); self.wfile.flush()
            while True:
                readable,_,_=select.select([self.connection,upstream],[],[],3)
                if not readable: return
                for source in readable:
                    data=source.recv(65536)
                    if not data: return
                    (upstream if source is self.connection else self.connection).sendall(data)

def run(url, *args, expected=0, data=None, gnu=False, proxy=None):
    global COUNT
    cmd = ([GNU_WGET] if gnu else [BINARY,'wget']) + ([] if proxy else ['--no-proxy']) + ['-t1','-T2',*args,url]
    env = os.environ.copy()
    if proxy:
        env.update(http_proxy=proxy, https_proxy=proxy, no_proxy="", NO_PROXY="")
    p = subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=8,env=env)
    assert p.returncode == expected, (cmd,p.returncode,expected,p.stderr)
    if data is not None: assert p.stdout == data, (cmd,p.stdout[:100],data[:100],p.stderr)
    COUNT += 1
    return p

with tempfile.TemporaryDirectory(prefix='cmdbox-wget-') as temp:
    directory=Path(temp); os.chdir(directory)
    http=serve(); base=f'http://127.0.0.1:{http.server_port}'
    for path, data in [('/data',DATA),('/redirect',DATA),('/chunked',b'abcde')]:
        for gnu in REFERENCES: run(base+path,'-O-',data=data,gnu=gnu)
    run(base+'/missing','-O-',expected=8)
    run(base+'/auth','-O-',expected=6)
    run(base+'/auth','-O-','--user=user','--password=pass',data=DATA)
    run(base+'/headers','-O-','--header=X-Test: present','-Uagent',data=b'present|agent')
    run(base+'/post','-O-','--post-data=a=1&b=two',data=b'a=1&b=two')
    run(base+'/data','--spider',data=b'')
    run(base+'/loop','-O-','--max-redirect=2',expected=8)
    run(base+'/truncated','-O-',expected=4)
    run(base+'/data'); assert Path('data').read_bytes()==DATA
    run(base+'/data'); assert Path('data.1').read_bytes()==DATA
    Path('data').write_bytes(DATA[:111]); run(base+'/data','-c'); assert Path('data').read_bytes()==DATA
    Path('data').write_bytes(b'keep'); run(base+'/data','-nc'); assert Path('data').read_bytes()==b'keep'
    run(base+'/disposition','--content-disposition'); assert Path('chosen.txt').read_bytes()==DATA
    run(base+'/data','-P','deep/sub'); assert Path('deep/sub/data').read_bytes()==DATA
    ca=FIXTURES/'ca.pem'
    servers=[]
    def tls(name, ctx=None):
        server=serve(ctx or context(name)); servers.append(server)
        return f'https://localhost:{server.server_port}/data'
    url=tls('good')
    proxyserver=socketserver.ThreadingTCPServer(('127.0.0.1',0),Tunnel)
    proxyserver.daemon_threads=True
    threading.Thread(target=proxyserver.serve_forever,daemon=True).start()
    run(url,'-O-','--ca-certificate='+str(ca),data=DATA,proxy=f'http://proxy:pass@127.0.0.1:{proxyserver.server_address[1]}')
    proxyserver.shutdown(); proxyserver.server_close()
    for gnu in REFERENCES: run(url,'-O-','--ca-certificate='+str(ca),data=DATA,gnu=gnu)
    run(url.replace('localhost','127.0.0.1'),'-O-','--ca-certificate='+str(ca),data=DATA)
    run(url,'-O-',expected=5)
    run(url,'-O-','--no-check-certificate',data=DATA)
    for version in (ssl.TLSVersion.TLSv1_2,ssl.TLSVersion.TLSv1_3):
        for name in ('good','rsa'):
            ctx=context(name); ctx.minimum_version=ctx.maximum_version=version
            run(tls(name,ctx=ctx),'-O-','--ca-certificate='+str(ca),data=DATA)
    for name in ('hostname','expired','client-only','critical','constraints','dns-ip','middleFalse'):
        url=tls(name)
        if name=='dns-ip': url=url.replace('localhost','127.0.0.1')
        run(url,'-O-','--ca-certificate='+str(ca),expected=5)
    run(tls('middleTrue'),'-O-','--ca-certificate='+str(ca),data=DATA)
    run(tls('pathlen'),'-O-','--ca-certificate='+str(FIXTURES/'limited-ca.pem'),expected=5)
    for server in servers+[http]: server.shutdown(); server.server_close()
print(f'wget compatibility: {COUNT} checks passed')
