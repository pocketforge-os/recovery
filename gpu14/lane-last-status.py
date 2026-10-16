#!/usr/bin/env python3
"""gpu-14: print the last LANE status block of a run's newest (or given) result receipt, plus the
lane_routine verdict. It reads the full turn from the read-only pf-task journal (the outbox record's
`assistant` holds the whole native turn; run.result's final_text is truncated at about 2 KB). It lists
unacked receipts and does NOT ack.
usage: lane-last-status.py <run_id> [receipt]"""
import json, os, sys, sqlite3
sys.path.insert(0, "/home/matt/recovery/gpu14")
from lane_routine import verdict

run_id = sys.argv[1]
db = sqlite3.connect("file:" + ("/home/matt/.pf-task-v2" if os.environ.get("PF_V2") == "1" else "/home/matt/.pf-task") + "/journal.sqlite3?mode=ro", uri=True, timeout=30)
d = json.loads(db.execute("SELECT body FROM records WHERE kind='run' AND id=?", (run_id,)).fetchone()[0])
outbox = d.get("outbox", [])
print("UNACKED", [(i, o["receipt"]) for i, o in enumerate(outbox) if not o.get("acknowledged")])
want = sys.argv[2] if len(sys.argv) > 2 else None
rec = next((o for o in outbox if o["receipt"] == want), None) if want else (outbox[-1] if outbox else None)
texts = []


def walk(x):
    if isinstance(x, dict):
        for v in x.values():
            if isinstance(v, str) and "INTEGRATION REQUESTS" in v and "STATUS" in v:
                texts.append(v)
            else:
                walk(v)
    elif isinstance(x, list):
        for v in x:
            walk(v)


walk(rec.get("assistant") if rec else None)
t = texts[-1] if texts else ""
i = t.rfind("\nLANE ")
print(f"RECEIPT {rec and rec['receipt']} outcome={rec and rec.get('outcome')}")
print(t[i + 1:] if i >= 0 else t[-3000:])
ok, why, f = verdict(t, None)
print(f"VERDICT routine={ok} reason={why} fields={f}")
