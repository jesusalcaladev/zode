#!/usr/bin/env python3
"""Split a unified diff into per-concern patches by hunk.

  python3 tools/split_diff.py <diff> <out_dir> <spec>...

<spec> is `file:anchor` where anchor is a substring of the hunk's @@ header
(usually the enclosing function name). A hunk goes into the FIRST spec whose
file and anchor both match.

The input diff may use any prefix (`a/` `b/`, or this repo's `i/` `w/`); the
output is always normalised to `a/` `b/` so `git apply` accepts it.
"""
import os
import re
import sys

diff_path, out_dir = sys.argv[1], sys.argv[2]
specs = sys.argv[3:]
if not specs:
    sys.exit("no specs")

text = open(diff_path).read()
sections = re.split(r'(?m)^(?=diff --git )', text)

files = {}
for sec in sections:
    if not sec.strip():
        continue
    m = re.match(r'diff --git \S*?i?/?(\S+) \S*?w?/?(\S+)', sec)
    if not m:
        continue
    path = m.group(2)
    # Normalise the header to a/ b/ so git apply takes it.
    sec = re.sub(r'(?m)^diff --git \S+ \S+$', f'diff --git a/{path} b/{path}', sec, count=1)
    sec = re.sub(r'(?m)^--- \S+$', f'--- a/{path}', sec, count=1)
    sec = re.sub(r'(?m)^\+\+\+ \S+$', f'+++ b/{path}', sec, count=1)
    files[path] = sec

def hunks_of(sec):
    out, cur = [], None
    for line in sec.split('\n'):
        if line.startswith('@@'):
            if cur:
                out.append(cur)
            cur = [line]
        elif cur is not None:
            cur.append(line)
    if cur:
        out.append(cur)
    return out

buckets = {s: [] for s in specs}
for path, sec in files.items():
    for h in hunks_of(sec):
        header = h[0]
        for spec in specs:
            f, _, anchor = spec.partition(':')
            if f == path and anchor in header:
                buckets[spec].append((path, h))
                break

os.makedirs(out_dir, exist_ok=True)
for spec in specs:
    parts = []
    for path, h in buckets[spec]:
        head = files[path].split('@@')[0]
        parts.append(head + '\n'.join(h).rstrip('\n') + '\n')
    out = os.path.join(out_dir, spec.replace('/', '_').replace(':', '_') + '.patch')
    with open(out, 'w') as f:
        f.write(''.join(parts))
    print(f"{out}: {len(buckets[spec])} hunk(s)")