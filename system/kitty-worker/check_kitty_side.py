"""Fail if code that runs inside kitty can block kitty's main thread.

That thread draws every terminal; a /proc read or file write on it froze
them all (2026-10-25). Such work belongs in kitty-worker. This flags calls
that touch the filesystem, /proc or other processes, unless the line (or the
comment line just above it) says `# io-ok: <why>` -- e.g. once at module load.

    python check_kitty_side.py FILE...
"""

import ast
import sys

OS = {"stat", "lstat", "listdir", "scandir", "walk", "replace", "rename", "unlink",
      "remove", "mkdir", "makedirs", "readlink", "access", "system", "popen", "fsync",
      "chmod", "open", "truncate", "utime"}
OS_PATH = {"exists", "lexists", "isfile", "isdir", "islink", "realpath", "getmtime",
           "getsize", "getctime", "getatime", "samefile"}
# Path methods; distinctive enough to flag on any receiver.
PATH = {"read_text", "read_bytes", "write_text", "write_bytes", "is_file", "is_dir",
        "iterdir", "glob", "rglob", "touch", "resolve", "is_symlink", "unlink"}
MODULES = {"subprocess", "tempfile", "shutil", "glob"}


def dotted(node):
    parts = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if isinstance(node, ast.Name):
        parts.append(node.id)
    return ".".join(reversed(parts))


def problems(path):
    src = open(path, encoding="utf-8").read()
    lines = src.splitlines()

    def allowed(n):
        here = lines[n - 1] if n <= len(lines) else ""
        above = lines[n - 2].strip() if n >= 2 else ""
        return "io-ok" in here or (above.startswith("#") and "io-ok" in above)

    for node in ast.walk(ast.parse(src, path)):
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            names = [a.name for a in node.names] if isinstance(node, ast.Import) else [node.module or ""]
            for name in names:
                if name.split(".")[0] in MODULES and not allowed(node.lineno):
                    yield node.lineno, f"imports {name}"
            continue
        if not isinstance(node, ast.Call):
            continue
        name = dotted(node.func)
        head, _, last = name.rpartition(".")
        bad = (name == "open" or (head == "os" and last in OS)
               or (head == "os.path" and last in OS_PATH)
               or (isinstance(node.func, ast.Attribute) and last in PATH)
               or head.split(".")[0] in MODULES)
        if bad and not allowed(node.lineno):
            yield node.lineno, f"calls {name or last}()"


def main(paths):
    failed = False
    for path in paths:
        for line, what in problems(path):
            print(f"{path}:{line}: {what} -- blocking I/O on kitty's main thread; "
                  "send it to kitty-worker, or mark '# io-ok: <why>'", file=sys.stderr)
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
