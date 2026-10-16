#!/usr/bin/env python3
"""Run lane-supervisor.py for several runs; exit as soon as ANY one exits (a wake event),
printing which run and its output, and terminate the others so none runs untracked.
usage: group-supervise.py <label> <run_id>... (generation read from the journal)"""
import sqlite3, subprocess, sys, time, json, signal
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))  # run the finally: never orphan children
label, runs = sys.argv[1], sys.argv[2:]
db = sqlite3.connect("file:/home/matt/.pf-task/journal.sqlite3?mode=ro", uri=True, timeout=30)
procs = {}
for rid in runs:
    gen = db.execute("SELECT json_extract(body,'$.generation') FROM records WHERE kind='run' AND id=?", (rid,)).fetchone()[0]
    log = f"/home/matt/recovery/gpu14/{label}-{rid[4:12]}-approvals.jsonl"
    procs[rid] = subprocess.Popen(["python3", "/home/matt/recovery/gpu14/lane-supervisor.py", rid, gen, log, "10", "200"],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
db.close()
try:
    while True:
        for rid, p in procs.items():
            if p.poll() is not None:
                out = p.stdout.read()
                print(f"GROUP_WAKE label={label} run={rid} rc={p.returncode}\n{out.strip()}")
                raise SystemExit(0)
        time.sleep(5)
finally:
    for p in procs.values():
        if p.poll() is None:
            p.terminate()
