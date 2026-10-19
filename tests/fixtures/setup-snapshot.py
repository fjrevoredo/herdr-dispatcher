#!/usr/bin/python3
"""Read-only tree snapshot: bytes, modes, times, and links (never follow links)."""
import hashlib
import json
import os
import stat
import sys

rows = []
for root in sys.argv[1:]:
    for parent, directories, files in os.walk(root, followlinks=False):
        for path in [parent] + [os.path.join(parent, name) for name in directories + files]:
            info = os.lstat(path)
            data = None
            if stat.S_ISLNK(info.st_mode):
                data = os.readlink(path)
            elif stat.S_ISREG(info.st_mode):
                with open(path, "rb") as source:
                    data = hashlib.sha256(source.read()).hexdigest()
            rows.append((path, info.st_mode, info.st_mtime_ns, data))
print(json.dumps(sorted(set(rows))))
