"""Gzip cross-decoding and GNU option/file-effect comparisons."""
import gzip
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

binary=str(Path(sys.argv[1]).resolve())
env=dict(os.environ,LC_ALL='C')
checks=0
failures=[]
def run(prefix,args,data=None,cwd=None):
    return subprocess.run([*prefix,*args],input=data,capture_output=True,cwd=cwd,env=env,timeout=10)
def compare(name,args,data):
    global checks
    a=run([binary,name],args,data);b=run([name],args,data)
    checks+=1
    if(a.returncode,a.stdout)!=(b.returncode,b.stdout):
        failures.append((name,args,(a.returncode,a.stdout[:100],a.stderr),(b.returncode,b.stdout[:100],b.stderr)))
for data in [b'',b'a',b'hello\n'*1000,bytes(range(256))*128]:
    for level in ['-1','-6','-9']:
        result=run([binary,'gzip'],[level,'-nc'],data)
        assert result.returncode==0,result.stderr
        assert gzip.decompress(result.stdout)==data
        external=run(['gzip'],['-dc'],result.stdout)
        assert external.returncode==0 and external.stdout==data,external.stderr
        checks+=1
    compressed=gzip.compress(data,mtime=0)
    compare('gunzip',['-c'],compressed)
    compare('gzip',['-dc'],compressed)
    compare('zcat',[],compressed)
    compare('gzip',['-t'],compressed)
    bad=bytearray(compressed);bad[-8]^=1
    # Error diagnostics differ, but both must fail without discarding source files.
    a=run([binary,'gzip'],['-t'],bad);b=run(['gzip'],['-t'],bad)
    assert a.returncode!=0 and b.returncode!=0,(a.returncode,b.returncode)
    checks+=1
compare('zcat',[],gzip.compress(b'a')+gzip.compress(b'b'))
compare('gzip',['-dcf'],b'plain text\n')
for data in [b'',b'x',b'bad',b'\x1f\x8b']:
    compare('gzip',['-t'],data)
with tempfile.TemporaryDirectory() as d:
    base=Path(d)
    for args in [['file'],['-k','file'],['-f','file'],['-n','file'],['-c','file'],['-d','file.gz'],['-dk','file.gz'],['-t','file.gz'],['-dN','file.gz'],['-S','.data','file']]:
        results=[]
        for name,prefix in [('ours',[binary,'gzip']),('gnu',['gzip'])]:
            root=base/(name+str(checks));root.mkdir()
            path=root/'file';path.write_bytes(b'payload\n'*100)
            os.chmod(path,0o640);os.utime(path,ns=(1700000000000000000,1700000000000000000))
            if '-f' in args:(root/'file.gz').write_bytes(b'existing')
            if any(arg.startswith('-d') for arg in args) or '-t' in args:
                path.unlink();(root/'file.gz').write_bytes(gzip.compress(b'payload\n'*100,mtime=1700000000))
            process=run(prefix,args,cwd=root)
            values={}
            for p in root.iterdir():
                content=p.read_bytes()
                if content.startswith(b'\x1f\x8b'):
                    content=gzip.decompress(content)
                values[p.name]=(content,stat.S_IMODE(p.stat().st_mode))
            output=process.stdout
            if output.startswith(b'\x1f\x8b'):output=gzip.decompress(output)
            results.append((process.returncode,output,values))
        checks+=1
        if results[0]!=results[1]:failures.append(('file options',args,results))
for failure in failures:print('FAIL',repr(failure))
print(f'{checks-len(failures)}/{checks} gzip interoperability/option checks passed')
raise SystemExit(bool(failures))
