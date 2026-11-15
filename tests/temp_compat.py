"""Check mktemp effects without depending on the generated random characters."""
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
checks = 0
cases = [[], ['file.XXXXXX'], ['-d','dir.XXXXXX'], ['-u','dry.XXXXXX'],
         ['--suffix=.txt','file.XXXXXX'], ['-p','dest','file.XXXXXX'],
         ['--tmpdir=dest','file.XXXXXX'], ['-d','--tmpdir=dest','dir.XXXXXX'],
         ['bad'], ['X'], ['XX'], ['-q','bad']]
with tempfile.TemporaryDirectory() as d:
    base=Path(d)
    for args in cases:
        results=[]
        for name, command in [('ours',[binary,'mktemp']),('gnu',['mktemp'])]:
            root=base/name
            root.mkdir(exist_ok=True)
            (root/'dest').mkdir(exist_ok=True)
            environment=dict(os.environ,LC_ALL='C',TMPDIR=str(root))
            process=subprocess.run([*command,*args],cwd=root,env=environment,capture_output=True,timeout=5)
            if process.returncode:
                results.append((process.returncode,process.stdout))
                continue
            output=process.stdout.decode().rstrip('\n')
            path=Path(output)
            if not path.is_absolute():
                path=root/path
            dry='-u' in args
            assert path.exists() != dry, (args,output)
            directory='-d' in args
            if not dry:
                value=path.stat()
                assert stat.S_ISDIR(value.st_mode) == directory
                assert stat.S_IMODE(value.st_mode) == (0o700 if directory else 0o600)
            results.append((0,str(path.relative_to(root).parent),len(path.name),path.suffix if '--suffix=.txt' in args else '',dry,directory))
        assert results[0] == results[1], (args,results)
        checks += 1
print(f'{checks} temporary-file compatibility checks passed')
