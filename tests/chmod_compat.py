"""RPM chmod regression tests with independent expected permission bits."""
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
checks = 0
for flags in [["-Rf"], ["-fR"], ["-RRff"], ["-R", "-f"], ["--recursive", "--quiet"]]:
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        tree = root / "tree"
        (tree / "nested").mkdir(parents=True)
        expected = {}
        for name, mode, result in [("plain", 0o600, 0o644), ("exec", 0o711, 0o755), ("write", 0o666, 0o644)]:
            path = tree / "nested" / name
            path.write_bytes(b"unchanged")
            os.chmod(path, mode)
            expected[path] = result
        outside = root / "outside"
        outside.write_bytes(b"outside")
        os.chmod(outside, 0o600)
        (tree / "link").symlink_to(outside)
        (tree / "dangling").symlink_to("missing")
        for path in [tree, tree / "nested"]:
            os.chmod(path, 0o700)
            expected[path] = 0o755
        process = subprocess.run([binary, "chmod", *flags, "a+rX,u+w,g-w,o-w", "."], cwd=tree, capture_output=True)
        assert (process.returncode, process.stdout, process.stderr) == (0, b"", b""), (flags, process)
        for path, mode in expected.items():
            assert stat.S_IMODE(path.stat().st_mode) == mode, (flags, path, oct(path.stat().st_mode), oct(mode))
        assert stat.S_IMODE(outside.stat().st_mode) == 0o600
        checks += 1
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    for args, initial, expected in [(["-x"], 0o751, 0o640), (["--", "-x"], 0o751, 0o640), (["u+x", "-Rf"], 0o640, 0o740)]:
        path = root / "file"
        path.write_bytes(b"data")
        os.chmod(path, initial)
        process = subprocess.run([binary, "chmod", *args, str(path)], capture_output=True)
        assert process.returncode == 0, (args, process.stderr)
        assert stat.S_IMODE(path.stat().st_mode) == expected
        checks += 1
    process = subprocess.run([binary, "chmod", "-Rf", "a+rX,u+w,g-w,o-w", str(root / "missing")], capture_output=True)
    assert process.returncode == 1 and process.stderr == b"", process
    checks += 1
print(f"{checks} chmod/RPM regression checks passed")
