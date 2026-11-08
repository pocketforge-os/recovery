#!/usr/bin/env bash
# refresh.sh -- collect live fleet state, render fleet-board.html, print a machine-readable summary.
# Exit 0 even when items need attention (a non-zero exit means the collector or renderer itself failed).
# usage: refresh.sh   (pf-fleet-board.timer runs it every 15 min; the published copy is ~/pf-reports/board.html)
# 2026-11-02 (tsp-mc9m.60.29.84.14): lanes = gpu-16 runs/active.tsv, device = BENCH + pf-kit-window-runner,
# owner asks = the owner intake. NEEDS_GPU14 keeps its name for existing parsers.
set -uo pipefail
# FB_BOARD_DIR / FB_BD_BIN point the run at another board dir and bd binary (hermetic tests).
B=${FB_BOARD_DIR:-/home/matt/recovery/gpu14/fleet-board}; export FB_BOARD_DIR=$B
BD=${FB_BD_BIN:-bd}
mkdir -p "$B/cache"
t0=$(date +%s)
python3 "$B/collect.py" >"$B/cache/collect.out" 2>"$B/cache/collect.err" || { echo "REFRESH_FAIL step=collect rc=$? $(tail -n 3 "$B/cache/collect.err" | tr '\n' ' ')"; exit 1; }
SLA_PUSH=${FB_SLA_PUSH:-$(dirname "$B")/sla-push.py}
python3 "$SLA_PUSH" --data "$B/data.json" --state "$B/cache/sla-sent.json" \
  >"$B/cache/sla-push.out" 2>"$B/cache/sla-push.err"
sla_rc=$?
if [ "$sla_rc" -ne 0 ]; then
  echo "REFRESH_WARN step=sla_push rc=$sla_rc $(tail -n 3 "$B/cache/sla-push.err" | tr '\n' ' ')"
fi
# velocity.json (open/close rates): a failure is a SOURCE_ERROR line, never a failed board; render skips the section.
if ! (cd /home/matt/mission-control 2>/dev/null || cd "$B"; timeout 120 "$BD" list --all --json --limit 0) 2>"$B/cache/velocity.err" \
    | python3 "$B/velocity.py" - --out "$B/velocity.json" >"$B/cache/velocity.out" 2>>"$B/cache/velocity.err"; then
  find "$B" -maxdepth 1 -name velocity.json -delete 2>/dev/null  # render.py also refuses one older than data.json
  vel_err="$(tail -n 2 "$B/cache/velocity.err" | tr '\n' ' ' | cut -c1-200)"
fi
python3 "$B/render.py" >"$B/cache/render.out" 2>"$B/cache/render.err" || { echo "REFRESH_FAIL step=render rc=$? $(tail -n 3 "$B/cache/render.err" | tr '\n' ' ')"; exit 1; }
[ -n "${vel_err:-}" ] && echo "SOURCE_ERROR source='velocity' error=${vel_err@Q}"
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
      f"bench={dev.get('bench_state') or '-'} results_24h={dev.get('results_24h', 0)} stale_quota={s.get('lanes_stale_quota', 0)} "
      f"owner_asks={s['owner_asks']} errors={len(d.get('errors') or [])} refresh_s={secs}")
PY
exit 0
