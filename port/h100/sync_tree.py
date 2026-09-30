#!/usr/bin/env python3
"""Copy a source tree into a build tree, touching only files whose content
changed (like rsync -rl --checksum without preserving times): a copied file
gets the current time, so make rebuilds it and what depends on it, and an
unchanged file keeps its old time.  Files that exist only in the build tree
(objects, generated files) are left alone.

Usage: sync_tree.py <src dir> <dst dir>      prints the number of copied files
"""
import filecmp
import os
import shutil
import sys


def main(src, dst):
    n = 0
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d != ".git"]
        rel = os.path.relpath(root, src)
        droot = os.path.join(dst, rel) if rel != "." else dst
        os.makedirs(droot, exist_ok=True)
        for f in files:
            s, d = os.path.join(root, f), os.path.join(droot, f)
            if os.path.islink(s):
                t = os.readlink(s)
                if not (os.path.islink(d) and os.readlink(d) == t):
                    if os.path.lexists(d):
                        os.remove(d)
                    os.symlink(t, d)
                    n += 1
                continue
            if os.path.exists(d) and not os.path.islink(d) and filecmp.cmp(s, d, shallow=False):
                continue
            if os.path.lexists(d):
                os.remove(d)
            shutil.copyfile(s, d)
            shutil.copymode(s, d)
            n += 1
    print(n)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
