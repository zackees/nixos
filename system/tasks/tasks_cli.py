"""Backend for the Tasks panel widget: a Markdown checklist in a git repo.

The list is TASKS.md in a clone of github.com/zackees/tasks, one task per
``- [ ] text`` / ``- [x] text`` line. Every edit is committed and pushed at
once; ``list`` pulls first (rate-limited) so edits made elsewhere show up.
Network failures never lose an edit: the commit stays local and the next
successful push carries it.

    tasks_cli.py list            JSON for the widget
    tasks_cli.py add TEXT
    tasks_cli.py toggle INDEX
    tasks_cli.py remove INDEX
    tasks_cli.py sync            pull and push now
"""

import base64
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(os.environ.get("TASKS_REPO", Path.home() / "dev" / "tasks"))
FILE = REPO / "TASKS.md"
REMOTE = "https://github.com/zackees/tasks.git"
PULL_EVERY = 60
TASK = re.compile(r"^\s*[-*] \[( |x|X)\] (.*)$")


def git(*args: str, timeout: float = 20) -> bool:
    try:
        r = subprocess.run(
            ["git", "-C", str(REPO), *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return False
    return r.returncode == 0


def ensure_repo() -> None:
    if (REPO / ".git").exists():
        return
    REPO.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "clone", "-q", REMOTE, str(REPO)], check=False, timeout=60)


def pull(force: bool = False) -> bool:
    stamp = REPO / ".git" / "tasks-last-pull"
    if not force and stamp.exists() and time.time() - stamp.stat().st_mtime < PULL_EVERY:
        return True
    ok = git("pull", "-q", "--rebase", "--autostash")
    if ok:
        stamp.touch()
    else:
        git("rebase", "--abort")
    return ok


def push() -> bool:
    return git("push", "-q", "origin", "HEAD")


def read() -> tuple[list[str], list[tuple[int, bool, str]]]:
    lines = FILE.read_text().splitlines() if FILE.exists() else ["# Tasks", ""]
    tasks = []
    for i, line in enumerate(lines):
        m = TASK.match(line)
        if m:
            tasks.append((i, m.group(1) != " ", m.group(2)))
    return lines, tasks


def write(lines: list[str], message: str) -> None:
    FILE.write_text("\n".join(lines) + "\n")
    git("add", "TASKS.md")
    git("commit", "-q", "-m", message)
    push()


def unpushed() -> int:
    try:
        r = subprocess.run(
            ["git", "-C", str(REPO), "rev-list", "--count", "@{u}..HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        return int(r.stdout.strip() or 0)
    except (ValueError, subprocess.TimeoutExpired):
        return 0


def main(argv: list[str]) -> int:
    ensure_repo()
    cmd = argv[1] if len(argv) > 1 else "list"
    if cmd in ("list", "sync"):
        online = pull(force=cmd == "sync")
        if unpushed():
            online = push() and online
        _, tasks = read()
        print(
            json.dumps(
                {
                    "tasks": [{"index": n, "done": d, "text": t} for n, (_, d, t) in enumerate(tasks)],
                    "open": sum(1 for _, d, _ in tasks if not d),
                    "synced": online and unpushed() == 0,
                }
            )
        )
        return 0
    pull(force=True)
    lines, tasks = read()
    if cmd in ("add", "add64"):
        # add64: the widget passes text base64-encoded, so no shell quoting.
        raw = " ".join(argv[2:])
        if cmd == "add64":
            raw = base64.b64decode(raw).decode()
        text = raw.strip().replace("\n", " ")
        if not text:
            return 1
        # New tasks go after the last task line, or at the end.
        at = tasks[-1][0] + 1 if tasks else len(lines)
        lines.insert(at, f"- [ ] {text}")
        write(lines, f"Add: {text}")
        return 0
    if cmd in ("toggle", "remove"):
        n = int(argv[2])
        if not 0 <= n < len(tasks):
            return 1
        i, done, text = tasks[n]
        if cmd == "toggle":
            lines[i] = f"- [{' ' if done else 'x'}] {text}"
            write(lines, f"{'Reopen' if done else 'Done'}: {text}")
        else:
            del lines[i]
            write(lines, f"Remove: {text}")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
