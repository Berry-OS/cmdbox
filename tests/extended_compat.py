"""Differential checks for the newly added GNU/procps utilities."""
import base64
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary=str(Path(sys.argv[1]).resolve())
env=dict(os.environ,LC_ALL='C')
checks=0
failures=[]
def compare(name,args=(),data=b'',cwd=None):
    global checks
    a=subprocess.run([binary,name,*args],input=data,capture_output=True,env=env,cwd=cwd,timeout=5)
    b=subprocess.run([name,*args],input=data,capture_output=True,env=env,cwd=cwd,timeout=5)
    checks+=1
    if (a.returncode,a.stdout)!=(b.returncode,b.stdout):
        failures.append((name,args,(a.returncode,a.stdout,a.stderr),(b.returncode,b.stdout,b.stderr)))

for data in [b'',b'a',b'ab',b'abc',bytes(range(256))*3]:
    for args in [[],['-w0'],['--wrap=5'],['-w','1']]:
        compare('base64',args,data)
    compare('base64',['-d'],base64.encodebytes(data))
for data in [b'YQ==\n',b'YQ==Yg==',b'YQ',b'Y!',b'YWFh!',b'Y Q==',b'YQ==\r\n',b'YQ=Z',b'====']:
    compare('base64',['-d'],data)
    compare('base64',['-di'],data)
for name in ['md5sum','sha1sum','sha256sum']:
    for data in [b'',b'abc',bytes(range(256))*3]:
        compare(name,[],data)
        compare(name,['-b'],data)
    with tempfile.TemporaryDirectory() as d:
        root=Path(d)
        for filename in ['a','b','back\\slash','new\nline']:
            (root/filename).write_bytes(filename.encode())
        compare(name,['a','b','back\\slash','new\nline'],cwd=root)
        compare(name,['--tag','a'],cwd=root)
        compare(name,['-z','back\\slash','new\nline'],cwd=root)
        for extra in [[],['--tag']]:
            records=subprocess.check_output([name,*extra,'a','b','back\\slash','new\nline'],cwd=root,env=env)
            compare(name,['-c'],records,cwd=root)
        manifest=subprocess.check_output([name,'a','b'],cwd=root,env=env)
        (root/'checks').write_bytes(manifest)
        for args in [['-c','checks'],['-c','--quiet','checks'],['-c','--status','checks']]:
            compare(name,args,cwd=root)
        (root/'a').write_bytes(b'changed')
        compare(name,['-c','checks'],cwd=root)
        (root/'checks').write_bytes(b'not a valid checksum\n'+manifest)
        compare(name,['-c','checks'],cwd=root)
        compare(name,['-c','--strict','checks'],cwd=root)
compare('whoami')
compare('groups')
compare('groups',['root'])
compare('groups',['cmdbox-user-does-not-exist'])
compare('nice')
compare('nice',['-n','1','sh','-c','printf "ok\\n"'])
compare('nice',['--adjustment=1','sh','-c','printf "ok\\n"'])
compare('nice',['cmdbox-command-does-not-exist'])
compare('nice',['-n1','true'])
compare('nice',['-n','bad','true'])
compare('pwdx',[str(os.getpid())])
compare('pwdx',['99999999'])
with tempfile.TemporaryDirectory() as d:
    alias=Path(d)/'busybox';alias.symlink_to(binary)
    assert subprocess.check_output([str(alias),'echo','alias'])==b'alias\n'
    assert subprocess.check_output([str(alias),'--list'])==subprocess.check_output([binary,'--list'])
    checks+=2
for failure in failures:
    print('FAIL',repr(failure))
print(f'{checks-len(failures)}/{checks} extended command compatibility checks passed')
raise SystemExit(bool(failures))
