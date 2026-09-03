#!/usr/bin/env python3
"""rm -rf that skips anything a process has flock'd -- files *and* directories.

`rm` has no --skip-in-use, and on Linux nothing gives it one for free: an open
file descriptor does not protect a file (unlink removes the directory entry and
the holder keeps reading a nameless inode), and BSD locks are advisory, so `rm`
deletes straight through a LOCK_EX it never asked about.

This is the same contract systemd-tmpfiles implements for /tmp aging, quoting
tmpfiles.d(5):

    an exclusive BSD file lock ... is taken on each directory/file the
    algorithm decides to remove. If the aging algorithm finds a lock (shared
    or exclusive) is already taken on some directory/file, it (and everything
    below it) is skipped.

Note "directory/file": both. A cooperating process holding a lock on a single
file deep in the tree keeps that file, and every directory above it, because a
directory containing a survivor cannot itself be removed.

Cooperating looks like this, in the process that wants to keep something:

    import fcntl, os
    fd = os.open(path, os.O_RDONLY)      # a file or a directory
    fcntl.flock(fd, fcntl.LOCK_SH)       # hold the fd for the life of the work

The lock dies with the process, so a crash cannot strand an exclusion.

Usage:
    rm-skip-locked.py [--dry-run] [--quiet] PATH [PATH...]

Exit status is 0 when everything unlocked was removed, 1 if anything was
skipped for a reason other than a lock (permissions, races), so a caller can
tell "held by someone" from "went wrong".
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import os
import stat
import sys
from pathlib import Path


class Outcome:
    """Counters for one run. `locked` is an expected outcome, not a failure."""

    def __init__(self) -> None:
        self.removed = 0
        self.locked = 0
        self.errors = 0


def _try_lock(path: Path, *, is_dir: bool) -> int | None:
    """Return an fd holding LOCK_EX on `path`, or None if someone else has it.

    Opened O_NOFOLLOW so a symlink cannot redirect the lock (or the later
    unlink) somewhere outside the tree. Directories need O_DIRECTORY; a
    regular file opened O_RDONLY is enough to flock it.
    """
    flags = os.O_RDONLY | os.O_NOFOLLOW
    if is_dir:
        flags |= os.O_DIRECTORY
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        # ELOOP: it is a symlink, which we unlink without locking (there is
        # nothing to hold open). Anything else is a real error.
        if exc.errno in (errno.ELOOP, errno.ENOENT):
            return None
        raise
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        os.close(fd)
        if exc.errno in (errno.EACCES, errno.EAGAIN):
            return None  # someone holds it -- the case this script exists for
        raise
    return fd


def _remove_entry(path: Path, *, is_dir: bool, dry_run: bool, out: Outcome) -> bool:
    """Remove one entry if we can take its lock. True when it is gone."""
    if path.is_symlink():
        # A symlink has no contents to be "in use"; the thing it points at is
        # protected on its own terms, if it is inside the tree at all.
        if not dry_run:
            path.unlink()
        out.removed += 1
        return True

    fd = None
    try:
        fd = _try_lock(path, is_dir=is_dir)
    except OSError:
        out.errors += 1
        return False
    if fd is None:
        out.locked += 1
        return False
    try:
        if dry_run:
            out.removed += 1
            return True
        if is_dir:
            os.rmdir(path)
        else:
            os.unlink(path)
        out.removed += 1
        return True
    except OSError as exc:
        # ENOTEMPTY on a directory means a descendant survived -- that is the
        # locked-file case propagating upward, not an error.
        if is_dir and exc.errno == errno.ENOTEMPTY:
            out.locked += 1
        else:
            out.errors += 1
        return False
    finally:
        # Closing releases our own lock. Done last so nothing can slip in
        # between the check and the unlink.
        os.close(fd)


def remove_tree(root: Path, *, dry_run: bool = False, verbose: bool = True) -> Outcome:
    """Remove `root`, skipping locked files and directories.

    A directory's lock is tested **before descending into it**, which is what
    makes "it and everything below it is skipped" true rather than merely
    "the directory itself survives". A bottom-up walk cannot do this: it
    reaches the children first and empties a locked directory before ever
    asking whether the directory was claimed.

    Locked *files* protect their ancestors by the complementary route -- the
    file refuses, its parent's rmdir then fails ENOTEMPTY, and so on upward.
    That half needs no bookkeeping; the filesystem enforces it.
    """
    out = Outcome()

    def report(kind: str, path: Path) -> None:
        if verbose:
            print(f"{kind}  {path}", file=sys.stderr)

    def visit(path: Path) -> None:
        try:
            st = os.lstat(path)
        except FileNotFoundError:
            return
        except OSError:
            out.errors += 1
            report("ERROR  ", path)
            return

        if stat.S_ISLNK(st.st_mode):
            # No contents to be in use, and following it could take us outside
            # the tree entirely.
            if not dry_run:
                try:
                    path.unlink()
                except OSError:
                    out.errors += 1
                    report("ERROR  ", path)
                    return
            out.removed += 1
            return

        is_dir = stat.S_ISDIR(st.st_mode)
        try:
            fd = _try_lock(path, is_dir=is_dir)
        except OSError:
            out.errors += 1
            report("ERROR  ", path)
            return
        if fd is None:
            # Claimed. Do not descend -- this is the whole contract.
            out.locked += 1
            report("LOCKED ", path)
            return

        try:
            if is_dir:
                try:
                    children = sorted(os.listdir(path))
                except OSError:
                    out.errors += 1
                    report("ERROR  ", path)
                    return
                for name in children:
                    visit(path / name)
                if dry_run:
                    out.removed += 1
                    return
                try:
                    os.rmdir(path)
                    out.removed += 1
                except OSError as exc:
                    # A descendant survived. Expected whenever something below
                    # was locked, so it is a skip, not an error.
                    if exc.errno == errno.ENOTEMPTY:
                        out.locked += 1
                        report("KEPT   ", path)
                    else:
                        out.errors += 1
                        report("ERROR  ", path)
            else:
                if dry_run:
                    out.removed += 1
                    return
                try:
                    os.unlink(path)
                    out.removed += 1
                except OSError:
                    out.errors += 1
                    report("ERROR  ", path)
        finally:
            # Releases our own lock. Held across the unlink so nothing can
            # claim the entry between the check and the removal.
            os.close(fd)

    visit(root)
    return out


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="rm-skip-locked",
        description="rm -rf that skips flock'd files and directories.",
    )
    p.add_argument("paths", nargs="+", type=Path)
    p.add_argument("--dry-run", action="store_true", help="report, remove nothing")
    p.add_argument("--quiet", action="store_true", help="suppress per-path lines")
    args = p.parse_args(argv)

    total = Outcome()
    for path in args.paths:
        out = remove_tree(path, dry_run=args.dry_run, verbose=not args.quiet)
        total.removed += out.removed
        total.locked += out.locked
        total.errors += out.errors

    verb = "would remove" if args.dry_run else "removed"
    print(
        f"{verb} {total.removed}, skipped {total.locked} locked, {total.errors} errors",
        file=sys.stderr,
    )
    return 1 if total.errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
