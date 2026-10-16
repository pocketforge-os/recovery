#!/usr/bin/env bash
# gpu-14 2026-10-15: memory hygiene check (owner: keep memory light, pointers to detail, never grow back to the limit).
# Claude Code loads only the first 200 lines / 25 KB of MEMORY.md; topic files load on demand.
# Budgets: MEMORY.md <= 170 lines and <= 20 KB; each topic file <= 4 KB (move witness logs to history/<name>.md).
# Also checks: every memory file is referenced from MEMORY.md or an idx-*.md, every link resolves,
# every history/ file is linked from its head file. Read-only; prints MEMORY_CHECK verdict=PASS|WARN|FAIL.
# usage: memory-check.sh [memory-dir]
set -uo pipefail
M=${1:-/home/matt/.claude/projects/-home-matt-mission-control/memory}
python3 - "$M" <<'EOF'
import re, sys
from pathlib import Path
M = Path(sys.argv[1])
link = re.compile(r"\]\(([^)\s]+\.md)\)")
fail, warn = [], []
idx = M / "MEMORY.md"
text = idx.read_text()
lines, size = len(text.splitlines()), len(text.encode())
if lines > 200 or size > 25000:
    fail.append(f"MEMORY.md over the load limit ({lines} lines, {size} B): entries past it are never loaded")
elif lines > 170 or size > 20000:
    warn.append(f"MEMORY.md {lines} lines / {size} B: fold older lines into the matching idx-*.md")
long = [i + 1 for i, l in enumerate(text.splitlines()) if len(l) > 200]
if long:
    warn.append(f"MEMORY.md lines over 200 chars: {long[:10]}")
refs = set()
for f in [idx] + sorted(M.glob("idx-*.md")) + sorted(M.glob("*.md")):
    for t in link.findall(f.read_text()):
        target = (f.parent / t)
        if f.parent == M:
            refs.add(t)
        if not target.exists():
            fail.append(f"broken link in {f.name}: {t}")
indexed = set()
for f in [idx] + sorted(M.glob("idx-*.md")):
    indexed |= set(link.findall(f.read_text()))
topics = sorted(p for p in M.glob("*.md") if p.name != "MEMORY.md" and not p.name.startswith("idx-"))
for p in topics:
    if p.name not in indexed:
        fail.append(f"unindexed memory file: {p.name} (add a line to MEMORY.md or an idx-*.md)")
    n = len(p.read_bytes())
    if n > 4096:
        warn.append(f"{p.name} {n} B > 4 KB: keep rule/why/how + one line per witness; move detail to history/{p.name}")
hist = M / "history"
if hist.is_dir():
    for h in sorted(hist.glob("*.md")):
        head = M / h.name
        if not head.exists() or f"history/{h.name}" not in head.read_text():
            fail.append(f"history/{h.name} is not linked from {h.name}")
for m in fail: print("FAIL", m)
for m in warn[:40]: print("WARN", m)
if len(warn) > 40: print(f"WARN ... {len(warn) - 40} more")
v = "FAIL" if fail else ("WARN" if warn else "PASS")
print(f"MEMORY_CHECK verdict={v} index_lines={lines} index_bytes={size} topics={len(topics)} "
      f"over_4k={sum(1 for p in topics if len(p.read_bytes()) > 4096)} fail={len(fail)} warn={len(warn)}")
sys.exit(1 if fail else 0)
EOF
