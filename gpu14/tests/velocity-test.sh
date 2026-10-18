#!/usr/bin/env bash
# tsp-mc9m.41.1030.18: hermetic tests for fleet-board velocity.py + the render.py
# Velocity section + the refresh.sh velocity step. Laptop tools only (bash, python3,
# coreutils). Deterministic: every run pins --asof 2026-06-30 against a fixture bd
# list with hand-computed expectations (gpu14/tests/velocity-test.sh, fixture below).
# Negative controls (acceptance 1): the SAME checker must FAIL against a velocity.py
# whose 7-day mean window is sed-mangled to 3 and whose descendant BFS is sed-mangled
# to direct children only.
set -uo pipefail
BIN=${FB_BIN_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
FB=$BIN/fleet-board
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
no() { fail=$((fail+1)); echo "FAIL $1 :: ${2:-}"; }
has() { printf '%s' "$1" | grep -Eq "$2"; }
T=$(mktemp -d "${TMPDIR:-/tmp}/velocity-tests.XXXXXX")
cleanup() { find "$T" -mindepth 1 -delete; rmdir "$T"; }
trap cleanup EXIT

ASOF=2026-06-30

# --- fixture bd list (dates relative to ASOF) + exact-expectation checker -------
python3 - "$T" "$ASOF" <<'PYFIX' || { echo "FAIL fixture_generation"; exit 1; }
import json, sys
from datetime import date, timedelta
t, asof = sys.argv[1], date.fromisoformat(sys.argv[2])
def d(off): return (asof - timedelta(days=off)).isoformat()
def ts(off, h="09"): return f"{d(off)}T{h}:00:00Z"
def row(i, typ, created, closed=None, parent=None):
    return {"id": i, "issue_type": typ, "parent": parent, "title": i,
            "status": "closed" if closed else "open",
            "created_at": created, "closed_at": closed}
rows = [
    row("e1", "epic", ts(10)),                                   # excluded from 'all'
    row("tsp-mc9m.60.29", "task", ts(30), parent="tsp-mc9m.60"),  # ffb root, not a descendant
    row("a1", "task", ts(0, "12")),
    row("a2", "task", ts(3), ts(1)),
    row("a3", "task", ts(8), ts(2)),
    row("a4", "task", ts(70), ts(9)),                             # created before window
    row("a5", "task", ts(100)),                                   # backlog-only
    row("f1", "task", ts(5), ts(4), parent="tsp-mc9m.60.29"),     # ffb child
    row("g1", "task", ts(2), parent="f1"),                        # ffb GRANDCHILD
    row("f2", "task", ts(20), ts(6), parent="tsp-mc9m.60.29"),
    row("f3", "task", ts(30), ts(8), parent="tsp-mc9m.60.29"),
    row("f4", "task", ts(40), ts(12), parent="tsp-mc9m.60.29"),
]
json.dump(rows, open(f"{t}/rows.json", "w"))
PYFIX

cat > "$T/check.py" <<'PYCHK'
import json, sys
v = json.load(open(sys.argv[1]))
def die(m):
    print("CHECK_FAIL " + m); sys.exit(1)
if v["window"]["end"] != "2026-06-30": die(f'window end {v["window"]["end"]}')
if v["window"]["start"] != "2026-05-02": die(f'window start {v["window"]["start"]}')
exp = {
    "all": {  # date: (opened, closed, net, opened_ma7, closed_ma7, backlog)
        "2026-06-30": (1, 0, 1, 0.57, 0.57, 4),
        "2026-06-29": (0, 1, -1, 0.43, 0.57, 3),
        "2026-06-27": (1, 0, 1, 0.43, 0.57, 4),
        "2026-06-25": (1, 0, 1, 0.29, 0.43, 4),
        "2026-06-20": (0, 0, 0, 0.0, 0.14, 5),   # epic e1 created here: must NOT count; f4 closed 06-18
    },
    "ffb": {
        "2026-06-30": (0, 0, 0, 0.29, 0.29, 1),
        "2026-06-28": (1, 0, 1, 0.29, 0.43, 1),  # grandchild g1 opened
        "2026-06-26": (0, 1, -1, 0.14, 0.43, 0),  # f1 closed
        "2026-06-25": (1, 0, 1, 0.14, 0.29, 1),   # f1 opened
        "2026-06-24": (0, 1, -1, 0.0, 0.43, 0),   # f2 closed
        "2026-05-31": (1, 0, 1, 0.14, 0.0, 2),    # f3 opened; root created same day: NOT a descendant
    },
}
tot = {"all": (9, 7), "ffb": (5, 4)}
wow = {"all": (4, 3, 33.3), "ffb": (2, 2, 0.0)}
for name in ("all", "ffb"):
    s = v["series"][name]
    if len(s["days"]) != 60: die(f"{name} days {len(s['days'])}")
    by = {x["date"]: x for x in s["days"]}
    for date_, (o, c, n, om, cm, b) in exp[name].items():
        x = by.get(date_)
        if x is None: die(f"{name} missing {date_}")
        got = (x["opened"], x["closed"], x["net"], x["opened_ma7"], x["closed_ma7"], x["backlog"])
        want = (o, c, n, om, cm, b)
        for g, w, k in zip(got, want, ("opened", "closed", "net", "opened_ma7", "closed_ma7", "backlog")):
            if isinstance(w, float):
                if abs(g - w) > 0.005: die(f"{name} {date_} {k} got={g} want={w}")
            elif g != w:
                die(f"{name} {date_} {k} got={g} want={w}")
    so = sum(x["opened"] for x in s["days"]); sc = sum(x["closed"] for x in s["days"])
    if (so, sc) != tot[name]: die(f"{name} window totals opened/closed {(so, sc)} want {tot[name]}")
    w = s["wow"]
    l, p, pct = wow[name]
    if (w["last7_closed"], w["prev7_closed"]) != (l, p): die(f'{name} wow 7d closes {(w["last7_closed"], w["prev7_closed"])} want {(l, p)}')
    if abs(w["pct"] - pct) > 0.05: die(f'{name} wow pct {w["pct"]} want {pct}')
print("CHECK_OK")
PYCHK

# minimal data.json fixture for render.py / refresh.sh tail: the live collect.py shape, empty
cat > "$T/data-fixture.json" <<'PYDATA'
{
  "generated_at": "2026-06-30T09:00:00Z", "generated_epoch": 1782982800.0,
  "host": "test", "runtime_s": 0.0, "errors": [], "campaign_roots": [],
  "needs": [], "waits": [], "lanes": [], "released_runs": [], "prs": {}, "stale": [],
  "beads_index": {},
  "dispatchable": {"parallel": [], "parallel_total": 0, "parallel_shown": 0, "parallel_recent_total": 0,
                   "parallel_rest_ids": [], "newly_unblocked": [], "chains": [], "chains_total": 0,
                   "excluded_container_types": 0},
  "device": {"runner_alive": false, "kit_running": false, "kit_proc": null, "halted": false,
             "halt_line": null, "running": null, "next": [], "pending_count": 0, "held_count": 0,
             "done_count": 0, "results": [], "events": [], "last_line": "", "log_mtime": ""},
  "long_idle": {"count": 0, "ids": []},
  "owner_asks": {"count": 0, "items": [], "error": null},
  "summary": {"needs": 0, "needs_by_kind": {}, "lanes_total": 0, "lanes_running": 0, "lanes_waiting": 0,
              "lanes_needs": 0, "lanes_unknown": 0, "lanes_released_hidden": 0, "lanes_unchecked": 0,
              "dispatchable": 0, "dispatchable_recent": 0, "stale_individual": 0, "newly_unblocked": 0,
              "stale": 0, "owner_asks": 0,
              "device": {"running": null, "halted": false, "pending": 0, "runner_alive": false}},
  "thresholds": {"STALE_BEAD_H": 6, "LANE_LOG_WINDOW_H": 72, "NEWLY_UNBLOCKED_H": 72, "RESULTS_SHOW": 10,
                 "RESULTS_WINDOW_H": 24, "STALE_LOOKBACK_H": 168, "RECENT_DAYS": 14}
}
PYDATA

# --- S1: velocity.py from a file path, exact values ------------------------------
o=$(python3 "$FB/velocity.py" "$T/rows.json" --asof "$ASOF" --out "$T/v.json" 2>&1); rc=$?
[ $rc = 0 ] && ok velocity_runs_file_input || no velocity_runs_file_input "rc=$rc $o"
o=$(python3 "$T/check.py" "$T/v.json" 2>&1); rc=$?
[ $rc = 0 ] && has "$o" CHECK_OK && ok exact_values_both_series || no exact_values_both_series "rc=$rc $o"

# --- S2: stdin input matches file input ------------------------------------------
o=$(python3 "$FB/velocity.py" - --asof "$ASOF" --out "$T/v2.json" < "$T/rows.json" 2>&1); rc=$?
if [ $rc = 0 ]; then
  o=$(python3 -c "
import json
a = json.load(open('$T/v.json')); b = json.load(open('$T/v2.json'))
for k in ('generated_at',):
    a.pop(k, None); b.pop(k, None)
print('SAME' if a == b else 'DIFF')" 2>&1)
  has "$o" SAME && ok stdin_matches_file || no stdin_matches_file "$o"
else
  no stdin_matches_file "rc=$rc $o"
fi

# --- S3: fail closed on bad input -------------------------------------------------
printf 'not json at all' > "$T/bad.json"
o=$(python3 "$FB/velocity.py" "$T/bad.json" --asof "$ASOF" --out "$T/vbad.json" 2>&1); rc=$?
[ $rc != 0 ] && has "$o" VELOCITY_FAIL && ! [ -f "$T/vbad.json" ] && ok bad_input_fails_closed || no bad_input_fails_closed "rc=$rc $o"
: > "$T/empty.json"
o=$(python3 "$FB/velocity.py" "$T/empty.json" --asof "$ASOF" --out "$T/vempty.json" 2>&1); rc=$?
[ $rc != 0 ] && has "$o" VELOCITY_FAIL && ok empty_input_fails_closed || no empty_input_fails_closed "rc=$rc $o"
o=$(python3 "$FB/velocity.py" "$T/does-not-exist.json" --asof "$ASOF" --out "$T/vno.json" 2>&1); rc=$?
[ $rc != 0 ] && has "$o" VELOCITY_FAIL && ok missing_input_fails_closed || no missing_input_fails_closed "rc=$rc $o"

# --- S4: negative control - broken 7-day mean must FAIL the same checker ----------
n=$(grep -c '^MA_WINDOW = 7$' "$FB/velocity.py" 2>/dev/null || echo 0)
if [ "$n" = 1 ]; then
  sed 's/^MA_WINDOW = 7$/MA_WINDOW = 3/' "$FB/velocity.py" > "$T/broken-ma7.py"
  python3 "$T/broken-ma7.py" "$T/rows.json" --asof "$ASOF" --out "$T/v-ma7.json" >/dev/null 2>&1
  o=$(python3 "$T/check.py" "$T/v-ma7.json" 2>&1); rc=$?
  [ $rc != 0 ] && ok negctl_broken_mean_fails || no negctl_broken_mean_fails "checker passed on broken mean: $o"
else
  no negctl_broken_mean_fails "sed target 'MA_WINDOW = 7' count=$n in $FB/velocity.py"
fi

# --- S5: negative control - broken ffb chain (no grandchildren) must FAIL ---------
n=$(grep -c '^                stack\.append(c)$' "$FB/velocity.py" 2>/dev/null || echo 0)
if [ "$n" = 1 ]; then
  sed 's/^                stack\.append(c)$/                pass/' "$FB/velocity.py" > "$T/broken-ffb.py"
  python3 "$T/broken-ffb.py" "$T/rows.json" --asof "$ASOF" --out "$T/v-ffb.json" >/dev/null 2>&1
  o=$(python3 "$T/check.py" "$T/v-ffb.json" 2>&1); rc=$?
  [ $rc != 0 ] && has "$o" '^CHECK_FAIL ffb' && ok negctl_broken_ffb_chain_fails || no negctl_broken_ffb_chain_fails "rc=$rc $o"
else
  no negctl_broken_ffb_chain_fails "sed target 'stack.append(c)' count=$n in $FB/velocity.py"
fi

# --- S6: render.py Velocity section from a fixture velocity.json ------------------
S=$T/render; mkdir -p "$S"
cp "$FB/render.py" "$S/render.py"
cp "$T/data-fixture.json" "$S/data.json"
cp "$T/v.json" "$S/velocity.json"
o=$(FB_BOARD_DIR="$S" python3 "$S/render.py" 2>&1); rc=$?
if [ $rc = 0 ] && has "$o" 'RENDER ok'; then
  H=$S/fleet-board.html
  nsvg=$(grep -o '<svg' "$H" | wc -l)
  grep -q 'id="velocity"' "$H" && [ "$nsvg" -ge 2 ] && ok render_velocity_section_two_svg || no render_velocity_section_two_svg "svgs=$nsvg $(grep -c 'id="velocity"' "$H" || true)"
  o2=$(python3 - "$H" <<'PYPOS' 2>&1
import sys
h = open(sys.argv[1]).read()
iv = h.find('id="velocity"'); il = h.find('id="lanes"')
isvg = h.find('<svg')
print("POS_OK" if 0 <= iv < isvg < il else f"POS_BAD velocity={iv} svg={isvg} lanes={il}")
PYPOS
)
  has "$o2" POS_OK && ok render_velocity_near_top || no render_velocity_near_top "$o2"
  grep -q '33.3% faster than the week before' "$H" && grep -Eq 'unchanged week over week' "$H" && ok render_wow_text_both_series || no render_wow_text_both_series "$(grep -o 'week before[^<]*' "$H" | head -2)"
else
  no render_velocity_section_two_svg "render rc=$rc $o"
fi

# --- S7: render.py tolerates a missing velocity.json (board must still render) ----
S2=$T/render-novel; mkdir -p "$S2"
cp "$FB/render.py" "$S2/render.py"
cp "$T/data-fixture.json" "$S2/data.json"
o=$(FB_BOARD_DIR="$S2" python3 "$S2/render.py" 2>&1); rc=$?
[ $rc = 0 ] && has "$o" 'RENDER ok' && ! grep -q 'id="velocity"' "$S2/fleet-board.html" && ok render_without_velocity_json || no render_without_velocity_json "rc=$rc $o"

# --- S8: refresh.sh runs velocity after collect; board renders --------------------
S3=$T/refresh; mkdir -p "$S3"
cp "$FB/refresh.sh" "$FB/velocity.py" "$FB/render.py" "$S3/"
cat > "$S3/collect.py" <<'PYCOL'
import os, shutil
b = os.environ["FB_BOARD_DIR"]
shutil.copy(os.environ["FB_DATA_FIXTURE"], os.path.join(b, "data.json"))
print("COLLECT ok stub")
PYCOL
printf '#!/bin/sh\ncat "$FB_ROWS_FIXTURE"\n' > "$S3/bdstub"
chmod +x "$S3/bdstub"
o=$(FB_BOARD_DIR="$S3" FB_BD_BIN="$S3/bdstub" FB_DATA_FIXTURE="$T/data-fixture.json" FB_ROWS_FIXTURE="$T/rows.json" bash "$S3/refresh.sh" 2>&1); rc=$?
if [ $rc = 0 ]; then
  [ -f "$S3/data.json" ] && [ -f "$S3/velocity.json" ] && ok refresh_writes_velocity_json || no refresh_writes_velocity_json "data=$([ -f "$S3/data.json" ] && echo y) velocity=$([ -f "$S3/velocity.json" ] && echo y)"
  grep -q 'id="velocity"' "$S3/fleet-board.html" 2>/dev/null && [ "$(grep -o '<svg' "$S3/fleet-board.html" | wc -l)" -ge 2 ] && ok refresh_board_has_velocity || no refresh_board_has_velocity "$(tail -3 <<<"$o")"
else
  no refresh_writes_velocity_json "rc=$rc $o"
fi

# --- S9: refresh.sh velocity failure = SOURCE_ERROR, board still renders ----------
S4=$T/refresh-bad; mkdir -p "$S4"
cp "$FB/refresh.sh" "$FB/velocity.py" "$FB/render.py" "$S4/"
cp "$S3/collect.py" "$S4/"
printf '#!/bin/sh\necho "not json at all"\n' > "$S4/bdstub"
chmod +x "$S4/bdstub"
o=$(FB_BOARD_DIR="$S4" FB_BD_BIN="$S4/bdstub" FB_DATA_FIXTURE="$T/data-fixture.json" FB_ROWS_FIXTURE="$T/rows.json" bash "$S4/refresh.sh" 2>&1); rc=$?
[ $rc = 0 ] && has "$o" "SOURCE_ERROR source='velocity'" && ok refresh_velocity_failure_nonfatal || no refresh_velocity_failure_nonfatal "rc=$rc $o"
[ $rc = 0 ] && [ -f "$S4/fleet-board.html" ] && has "$o" 'RENDER ok|BOARD' && ok refresh_board_still_renders || no refresh_board_still_renders "rc=$rc $(tail -3 <<<"$o")"

echo "TESTS pass=$pass fail=$fail"; [ "$fail" = 0 ]
