#!/usr/bin/env python3
"""gpu-14 top-of-turn forcing function (2026-09-27): every managed run that only gpu-14 can
serve must have a live lane-supervisor process. Written after the 4th missing-wake-source slip
(CAP g3 supervisor not re-armed after a no_parseable wake), despite memory
coordinator-never-end-turn-without-a-wake-source.

Needs gpu-14's own supervisor:
  - every top-level lane (request.parent_run is null, role coordinator) not released;
  - every child whose parent lane cannot serve it: the parent is released, or the parent's
    message budget is exhausted (messages >= bounds.max_messages). Children in awaiting_release
    with no unacked receipts are idle and are listed as IDLE, not MISSING.
Prints one line per run and a final SUPERVISORS OK|MISSING=n. Exit 1 on any MISSING.
"""
import json
import sqlite3
import subprocess
import sys

db = sqlite3.connect("file:/home/matt/.pf-task/journal.sqlite3?mode=ro", uri=True, timeout=30)
runs = {}
for (b,) in db.execute("SELECT body FROM records WHERE kind='run'"):
    d = json.loads(b)
    runs[d["run_id"]] = d
db.close()

ps = subprocess.run(["pgrep", "-af", "lane-supervisor.py"], capture_output=True, text=True).stdout
supervised = {tok for line in ps.splitlines() for tok in line.split() if tok.startswith("pft-")}


SUPERSEDED = {}
try:
    for line in open("/home/matt/recovery/gpu14/superseded-lanes.txt"):
        f = line.split()
        if f and not f[0].startswith("#"):
            SUPERSEDED[f[0]] = f[1] if len(f) > 1 else "?"
except FileNotFoundError:
    pass


def exhausted(r):
    lim = (r["request"].get("bounds") or {}).get("max_messages")
    return lim is not None and len(r.get("messages", [])) >= lim


missing = 0
for rid, r in sorted(runs.items()):
    if r["state"] in ("released", "releasing"):
        continue
    parent = r["request"].get("parent_run")
    # 2026-09-28: gpu-14 also admits top-level WORKERS (no parent_run), e.g. the .984.10 continuation after
    # its parent lane was superseded; nobody but gpu-14 can serve those either.
    top = parent is None and (r["request"].get("role") == "coordinator"
                              or str(r["request"].get("key", "")).startswith("gpu14-"))
    # 2026-09-28: a parent that is `unavailable` (codex systemError) or `interruption_unknown`
    # cannot serve its children either; CONF g3 died that way with its W7 worker permission_blocked.
    orphan = parent is not None and (parent not in runs
                                     or parent in SUPERSEDED
                                     or runs[parent]["state"] in ("released", "releasing", "unavailable",
                                                                  "interruption_unknown")
                                     or exhausted(runs[parent]))
    if not (top or orphan):
        continue
    if top and rid in SUPERSEDED:
        # 2026-09-28: CONF g3 flickered to `queued` as W7 child-blocker notices queued to it -> false MISSING.
        print(f"SUPERSEDED {rid} state={r['state']} successor={SUPERSEDED[rid]} task={r['request'].get('task')}")
        continue
    if top and exhausted(r) and r["state"] == "awaiting_release":
        print(f"EXHAUSTED_LANE {rid} task={r['request'].get('task')} (successor should exist)")
        continue
    if top and r["state"] in ("unavailable", "interruption_unknown"):
        # 2026-09-28: `unavailable` with error FileNotFoundError has twice been a transient status-read glitch
        # while the native turn was running (CONF g4; the .984.10 continuation). Check the native session first.
        print(f"DEAD_LANE {rid} state={r['state']} task={r['request'].get('task')} (successor should exist; "
              f"FIRST confirm the native session is not still running a turn)")
        continue
    unacked = sum(1 for o in r.get("outbox", []) if not o.get("acknowledged"))
    idle = r["state"] in ("awaiting_release", "interruption_unknown", "unavailable") and unacked == 0
    if rid in supervised:
        print(f"OK {rid} state={r['state']} task={r['request'].get('task')}")
    elif idle:
        print(f"IDLE {rid} state={r['state']} task={r['request'].get('task')}")
    else:
        missing += 1
        print(f"MISSING {rid} state={r['state']} unacked={unacked} task={r['request'].get('task')} "
              f"{'top-lane' if top else 'orphan-child'}")
# 2026-09-28 ~01:00Z: about 17 pf-task `-control` tmux sessions died at once (the -server sessions lived).
# Approvals sent meanwhile were accepted as submitted_unconfirmed and silently lost, while every supervisor
# process looked healthy. So check the CONTROLLER of every unreleased run in gpu-14's tree: runs gpu-14
# admitted (request key `gpu14-*`) and all their descendants.
tm = subprocess.run(["tmux", "ls", "-F", "#{session_name}"], capture_output=True, text=True).stdout.split()
mine = {rid for rid, r in runs.items() if str(r["request"].get("key", "")).startswith("gpu14-")}
grew = True
while grew:
    grew = False
    for rid, r in runs.items():
        if rid not in mine and r["request"].get("parent_run") in mine:
            mine.add(rid)
            grew = True
for rid in sorted(mine):
    r = runs[rid]
    if r["state"] in ("released", "releasing") or rid in SUPERSEDED:
        continue
    ctl = f"{rid}-{r.get('generation', '')}-control"
    if ctl not in tm:
        missing += 1
        print(f"DEAD_CONTROLLER {rid} state={r['state']} task={r['request'].get('task')} (run `pf-task recover`, "
              f"then re-submit any approval sent while it was dead)")
# 2026-09-28 ~04:50Z: the GPU lane sat in awaiting_release for 13.5 h. It had dispatched its #1044 review as
# an in-turn exec cell that died with the turn, so the approve verdict (15:24Z) never woke it, while this
# check printed `OK` because a supervisor PROCESS existed. A supervisor only wakes on lane activity; a lane
# that is idle with no active descendant has NOTHING that will wake it. Either gpu-14 owes it something
# (record that in waiting-on-gpu14.txt: `<run_id> <reason>`) or it is stalled. Stalled fails the verdict.
import time
WAITING = {}
try:
    for line in open("/home/matt/recovery/gpu14/waiting-on-gpu14.txt"):
        f = line.split(None, 1)
        if f and not f[0].startswith("#"):
            WAITING[f[0]] = f[1].strip() if len(f) > 1 else "?"
except FileNotFoundError:
    pass
ACTIVE = {"busy", "permission_blocked", "queued", "starting", "admitted", "running"}
def active_descendant(rid):
    for cid, c in runs.items():
        if c["request"].get("parent_run") == rid:
            if c["state"] in ACTIVE or active_descendant(cid):
                return True
    return False
STALL_S = 2 * 3600
for rid, r in sorted(runs.items()):
    if r["request"].get("parent_run") is not None or r["request"].get("role") != "coordinator":
        continue
    if r["state"] != "awaiting_release" or rid in SUPERSEDED or exhausted(r):
        continue
    if active_descendant(rid):
        continue
    last = max((float(o.get("created_at") or 0) for o in r.get("outbox", [])), default=0.0)
    age = time.time() - last if last else float("inf")
    if age < STALL_S:
        continue
    if rid in WAITING:
        print(f"WAITING_ON_GPU14 {rid} idle={age/3600:.1f}h task={r['request'].get('task')} reason={WAITING[rid]}")
    else:
        missing += 1
        print(f"STALLED_LANE {rid} idle={age/3600:.1f}h task={r['request'].get('task')} (no active descendant; "
              f"wake it, or record why gpu-14 owes it in waiting-on-gpu14.txt)")
print(f"SUPERVISORS {'OK' if missing == 0 else 'MISSING=' + str(missing)}")
sys.exit(1 if missing else 0)
