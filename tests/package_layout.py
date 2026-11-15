"""Verify legacy path selection and link resolution for both filesystem layouts."""
import importlib.util
from pathlib import Path
import posixpath

root=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('layout',root/'packaging/layout.py')
layout=importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)
names=layout.applets()
assert len(names)==len(set(names))
selected=layout.layout()
assert len(selected)==len({path for path,_ in selected})
assert all(path in layout.reference_paths() and name in names for path,name in selected)
assert set(path for path,_ in selected)=={path for path in layout.reference_paths() if path.rsplit('/',1)[1] in names}

def resolve(path,links):
    for _ in range(64):
        parts=posixpath.normpath(path).split('/')
        for i in range(2,len(parts)+1):
            prefix='/'.join(parts[:i])
            if prefix in links:
                target=links[prefix]
                if not target.startswith('/'):
                    target=posixpath.join(posixpath.dirname(prefix),target)
                path=posixpath.join(target,*parts[i:])
                break
        else:
            return posixpath.normpath(path)
    raise AssertionError(('symlink loop',path))

for merged in [False,True]:
    links={'/bin':'usr/bin','/sbin':'usr/sbin','/usr/sbin':'bin'} if merged else {}
    planned=[('/bin/busybox','/usr/bin/cmdbox')]
    for path,_ in selected:
        target='busybox' if path.startswith('/bin/') else '../bin/busybox' if path.startswith('/sbin/') else '../../bin/busybox'
        planned.append((path,target))
    for name in names:
        planned.append(('/usr/libexec/cmdbox/'+name,'../../bin/cmdbox'))
    for path,target in planned:
        parent=resolve(posixpath.dirname(path),links)
        actual=posixpath.join(parent,posixpath.basename(path))
        assert actual!='/usr/bin/cmdbox'
        assert actual not in links,(actual,'duplicate file')
        links[actual]=target
    for path,_ in planned:
        assert resolve(path,links)=='/usr/bin/cmdbox',(path,merged,resolve(path,links))
print(f'{len(selected)} BusyBox paths and {len(names)} private applet links verified (merged/unmerged /usr)')
