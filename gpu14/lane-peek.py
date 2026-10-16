#!/usr/bin/env python3
"""gpu-14 lane peek: compact tail of a managed Codex run's native rollout (read-only).

usage: lane-peek.py <run_id> [n_items=15]
Resolves session_id with ONE run.status (a primary-key lookup), finds the rollout by that
exact id in ~/.codex/sessions/<date>/ for today and the previous 2 days (named directories,
no tree search), and prints the last n tool calls and agent messages, truncated.
"""
import datetime
import json
import os
import subprocess
import sys

run = sys.argv[1]
n = int(sys.argv[2]) if len(sys.argv) > 2 else 15
H = "/home/matt/.pf-task-v2"
env = dict(os.environ, PF_TASK_HOST_CONFIG="/home/matt/.config/pocketforge/pf-task-host.json")
st = json.loads(subprocess.run([f"{H}/bin/pf-task", "--home", H, "--role", "coordinator", "run.status",
                                json.dumps({"run_id": run})], capture_output=True, text=True, timeout=120, env=env).stdout)
sid = st.get("session_id")
if isinstance(sid, dict):
    sid = sid.get("text")
print(f"run={run} state={st.get('state')} alive={st.get('controller_alive')} "
      f"native_age={round(st.get('native_activity_age_seconds') or -1)}s session={sid}")
age = st.get("native_activity_age_seconds") or 0
total = (st.get("messages") or {}).get("total") or 0
if total >= 85:
    # Forcing function (2026-10-04: CX-DEPUTY g1 hit max_messages=100; every run.send then refused).
    print(f"ROTATION_DUE messages={total} (schema cap is 100 per run): "
          "checkpoint and launch the next generation before sends are refused")
parked = {}
try:
    for line in open("/home/matt/recovery/gpu14/parked-lanes.txt"):
        if line.strip() and not line.startswith("#"):
            rid, _, why = line.strip().partition(" ")
            parked[rid] = why
except FileNotFoundError:
    pass
if run in parked:
    print(f"PARKED_BY_GPU14 idle={round(age / 60)}m wake_when={parked[run]}")
elif st.get("state") == "awaiting_release" and age > 1200:
    # Forcing function (2026-10-04: GPUCAP sat 46 min WAITING on a build that had finished).
    print(f"STALL_CHECK idle={round(age / 60)}m: name this lane's live wake source "
          "(busy child, gate watch, owner ask) or wake it now")
path = None
today = datetime.datetime.now(datetime.timezone.utc).date()
for back in range(3):
    d = today - datetime.timedelta(days=back)
    base = os.path.expanduser(f"~/.codex/sessions/{d:%Y/%m/%d}")
    try:
        for f in os.listdir(base):
            if sid and sid in f:
                path = os.path.join(base, f)
    except FileNotFoundError:
        pass
    if path:
        break
if not path:
    print("rollout=NOT_FOUND")
    sys.exit(0)
items = []
with open(path, errors="replace") as fh:
    for line in fh:
        try:
            d = json.loads(line)
        except ValueError:
            continue
        p = d.get("payload") or {}
        t = p.get("type")
        ts = (d.get("timestamp") or "")[11:19]
        if t == "function_call":
            a = p.get("arguments") or ""
            try:
                aj = json.loads(a)
                a = aj.get("cmd") or aj.get("command") or a
                if isinstance(a, list):
                    a = " ".join(map(str, a))
            except (ValueError, AttributeError):
                pass
            items.append(f"{ts} CALL {p.get('name')}: {' '.join(str(a).split())[:220]}")
        elif t == "agent_message":
            items.append(f"{ts} SAY: {' '.join(str(p.get('message', '')).split())[:500]}")
print(f"rollout={path} items={len(items)}")
for it in items[-n:]:
    print(it)
