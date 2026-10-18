#!/usr/bin/env python3
"""velocity.py -- bd list JSON -> velocity.json (open/close velocity for the fleet board).

Reads `bd list --all --json --limit 0` output from a file path argument or stdin
("-") so tests are hermetic; writes velocity.json (--out, default beside this
script). --asof YYYY-MM-DD pins "today" (UTC) for deterministic fixtures.
Deterministic, stdlib only: zero LLM tokens per refresh (tsp-mc9m.41.1030.18).

velocity.json: {"generated_at", "asof", "window": {start, end}, "rows_total",
 "ffb_root", "ffb_members", "series": {"all"|"ffb": {"days": [{date, opened,
 closed, net, opened_ma7, closed_ma7, backlog} x WINDOW_DAYS],
 "wow": {last7_closed, prev7_closed, pct}}}}. "all" excludes issue_type=epic;
 "ffb" is the descendants of FFB_ROOT via the parent chain (root excluded).
"""
import argparse
import bisect
import json
import os
import sys
from datetime import date, datetime, timezone

FFB_ROOT = "tsp-mc9m.60.29"
WINDOW_DAYS = 60
MA_WINDOW = 7


def fail(msg):
    print(f"VELOCITY_FAIL error={msg}", file=sys.stderr)
    sys.exit(1)


def day_ord(ts, what, rid):
    if not ts:
        return None
    try:
        return date.fromisoformat(str(ts)[:10]).toordinal()
    except ValueError:
        fail(f"bad_{what}_timestamp id={rid!r} value={ts!r}")


def series_stats(members, asof):
    opened_hist, closed_hist = {}, {}
    created_ords, closed_ords = [], []
    for r in members:
        co = day_ord(r.get("created_at"), "created", r.get("id"))
        xo = day_ord(r.get("closed_at"), "closed", r.get("id"))
        if co is not None:
            opened_hist[co] = opened_hist.get(co, 0) + 1
            created_ords.append(co)
        if xo is not None:
            closed_hist[xo] = closed_hist.get(xo, 0) + 1
            closed_ords.append(xo)
    created_ords.sort()
    closed_ords.sort()
    end = asof.toordinal()
    days = []
    for o in range(end - WINDOW_DAYS + 1, end + 1):
        op = opened_hist.get(o, 0)
        cl = closed_hist.get(o, 0)
        om = sum(opened_hist.get(x, 0) for x in range(o - MA_WINDOW + 1, o + 1)) / MA_WINDOW
        cm = sum(closed_hist.get(x, 0) for x in range(o - MA_WINDOW + 1, o + 1)) / MA_WINDOW
        bl = bisect.bisect_right(created_ords, o) - bisect.bisect_right(closed_ords, o)
        days.append({"date": date.fromordinal(o).isoformat(), "opened": op, "closed": cl,
                     "net": op - cl, "opened_ma7": round(om, 2), "closed_ma7": round(cm, 2),
                     "backlog": bl})
    last7 = sum(d["closed"] for d in days[-MA_WINDOW:])
    prev7 = sum(d["closed"] for d in days[-2 * MA_WINDOW:-MA_WINDOW])
    if prev7 > 0:
        pct = round((last7 - prev7) / prev7 * 100, 1)
    else:
        pct = 0.0 if last7 == 0 else None
    return {"days": days, "wow": {"last7_closed": last7, "prev7_closed": prev7, "pct": pct}}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("input", nargs="?", default="-", help="bd list JSON file, or '-' for stdin")
    ap.add_argument("--asof", default=None, help="pin 'today' (UTC) as YYYY-MM-DD")
    ap.add_argument("--out", default=None, help="output path (default: velocity.json beside this script)")
    a = ap.parse_args(argv)
    try:
        raw = sys.stdin.read() if a.input == "-" else open(a.input, encoding="utf-8").read()
    except OSError as exc:
        fail(f"input_unreadable {exc}")
    if not raw.strip():
        fail("input_empty")
    try:
        rows = json.loads(raw)
    except ValueError as exc:
        fail(f"input_not_json {exc}")
    if not isinstance(rows, list) or any(not isinstance(r, dict) or not r.get("id") for r in rows):
        fail("input_rows_malformed")
    try:
        asof = date.fromisoformat(a.asof) if a.asof else datetime.now(timezone.utc).date()
    except ValueError:
        fail(f"bad_asof {a.asof!r}")
    out = a.out or os.path.join(os.path.dirname(os.path.abspath(__file__)), "velocity.json")

    kids = {}
    for r in rows:
        if r.get("parent"):
            kids.setdefault(r["parent"], []).append(r["id"])
    desc = set()
    stack = [FFB_ROOT]
    while stack:
        cur = stack.pop()
        for c in kids.get(cur, []):
            if c not in desc:
                desc.add(c)
                stack.append(c)

    alls, ffbs = [], []
    for r in rows:
        if r.get("issue_type") != "epic":
            alls.append(r)
        if r["id"] in desc:
            ffbs.append(r)
    doc = {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "asof": asof.isoformat(),
        "window": {"start": date.fromordinal(asof.toordinal() - WINDOW_DAYS + 1).isoformat(),
                   "end": asof.isoformat()},
        "rows_total": len(rows),
        "ffb_root": FFB_ROOT,
        "ffb_members": len(desc),
        "series": {"all": series_stats(alls, asof), "ffb": series_stats(ffbs, asof)},
    }
    try:
        tmp = out + ".new"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(doc, f, separators=(",", ":"))
            f.write("\n")
        os.replace(tmp, out)
    except OSError as exc:
        fail(f"out_unwritable {exc}")
    w = doc["window"]
    print(f"VELOCITY ok path={out} rows={len(rows)} window={w['start']}..{w['end']} ffb_members={len(desc)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
