"""Atomic text/YAML/JSON writers: tempfile in the same dir -> flush -> fsync -> os.replace.

If anything raises while writing, the temp file is removed and the original
file is left untouched (never truncated). Rationale: 2026-10-13 ledger loss,
where open(path,'w') truncated queue/shogun_to_karo.yaml before the dump failed.

CLI: python3 scripts/lib/atomic_write.py <path>   (reads stdin, writes atomically)
"""
import os
import sys
import tempfile


def atomic_write_text(path, writer, encoding="utf-8"):
    """Call writer(f) against a temp file, then atomically replace path.

    writer: callable taking a text file object. Any exception propagates after
    the temp file is cleaned up; path is left unchanged.
    """
    path = os.fspath(path)
    dirname = os.path.dirname(path) or "."
    fd, tmp_path = tempfile.mkstemp(prefix=".atomic_tmp_", dir=dirname)
    try:
        with os.fdopen(fd, "w", encoding=encoding) as f:
            writer(f)
            f.flush()
            os.fsync(f.fileno())
        try:
            os.chmod(tmp_path, os.stat(path).st_mode & 0o7777)
        except FileNotFoundError:
            os.chmod(tmp_path, 0o644)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.remove(tmp_path)
        except FileNotFoundError:
            pass
        raise


def atomic_write_string(path, text, encoding="utf-8"):
    atomic_write_text(path, lambda f: f.write(text), encoding)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: atomic_write.py <path>  (content on stdin)", file=sys.stderr)
        sys.exit(2)
    data = sys.stdin.read()
    atomic_write_string(sys.argv[1], data)
