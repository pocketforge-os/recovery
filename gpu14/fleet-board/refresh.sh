#!/usr/bin/env bash
# refresh.sh -- collect live fleet state, render fleet-board.html, print a machine-readable summary for gpu-14.
# Exit 0 even when items need attention (a non-zero exit means the collector or renderer itself failed).
# usage: refresh.sh            (default pf-task budget, ~2.5 min)
#        FB_PFTASK_BUDGET_S=400 refresh.sh   (one-off: warm cache/run-state.json for every lane)
set -uo pipefail
B=/home/matt/recovery/gpu14/fleet-board
t0=$(date +%s)
python3 "$B/collect.py" >"$B/cache/collect.out" 2>"$B/cache/collect.err" || { echo "REFRESH_FAIL step=collect rc=$? $(tail -n 3 "$B/cache/collect.err" | tr '\n' ' ')"; exit 1; }
python3 "$B/render.py" >"$B/cache/render.out" 2>"$B/cache/render.err" || { echo "REFRESH_FAIL step=render rc=$? $(tail -n 3 "$B/cache/render.err" | tr '\n' ' ')"; exit 1; }
python3 - "$B" "$(( $(date +%s) - t0 ))" <<'PY'
import json, sys
b, secs = sys.argv[1], sys.argv[2]
d = json.load(open(f"{b}/data.json"))
for n in d["needs"]:
    ids = " ".join(f"{k}={v}" for k, v in (("lane", n.get("lane")), ("bead", n.get("bead")), ("run", n.get("run")), ("pr", n.get("pr"))) if v)
    age = n.get("age_s")
    age = f"{int(age // 60)}m" if age is not None and age < 3600 else (f"{age / 3600:.1f}h" if age is not None else "?")
    print(f"NEEDS_GPU14 kind={n['kind']} id={n['id']} age={age} {ids} detail={n['reason'][:200]!r} next={n['next'][:120]!r}")
for x in d.get("errors") or []:
    print(f"SOURCE_ERROR source={x['source']!r} error={x['error'][:200]!r}")
s = d["summary"]; dev = s["device"]
print(f"BOARD path={b}/fleet-board.html generated_at={d['generated_at']} lanes={s['lanes_total']} needs={s['needs']} "
      f"running={s['lanes_running']} waiting={s['lanes_waiting']} unchecked={s.get('lanes_unchecked', 0)} "
      f"dispatchable_recent={s.get('dispatchable_recent', 0)} newly_unblocked={s['newly_unblocked']} stale={s['stale']} "
      f"device_running={dev['running'] or '-'} device_pending={dev['pending']} device_halted={str(dev['halted']).lower()} "
      f"owner_asks={s['owner_asks']} errors={len(d.get('errors') or [])} refresh_s={secs}")
PY
exit 0
