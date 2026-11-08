#!/usr/bin/env bash
# gpu-14 2026-10-13: print a pf-task v2 run's NEWEST result text. run.result returns oldest-first, so
# {"limit":1} alone shows result #1; page with "offset": total-1.
# usage: run-last.sh <run-id> [tail_chars=4000]
set -uo pipefail
# 2026-10-20: resolve the run's own home (v2/v3/v4) the same way lane-drive.sh does; the v2-only path read
# KeyError 'total' for every v3/v4 run (glesproof pft-29c0a72b).
R=/home/matt/recovery/gpu14
run=${1:?run id}; n=${2:-4000}
resolved_home=$("$R/pf-task-run-home" resolve "$run" --format shell) || { echo "RUN_LAST_REFUSED reason=run_home_unresolved run=$run"; exit 2; }
eval "$resolved_home"
P=(timeout 200 "$PFT" --home "$H" --role coordinator run.result)
total=$("${P[@]}" "{\"run_id\":\"$run\",\"limit\":1}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])') || exit 2
[ "$total" -ge 1 ] 2>/dev/null || { echo "RUN_LAST none total=$total"; exit 3; }
"${P[@]}" "{\"run_id\":\"$run\",\"limit\":1,\"offset\":$((total-1))}" | python3 -c '
import json,sys
d=json.load(sys.stdin); r=d["results"][0]; n=int(sys.argv[1])
h=((r.get("git") or {}).get("head") or {}).get("text","")[:12]
print("RUN_LAST index=%s receipt=%s outcome=%s head=%s" % (d["total"], r.get("receipt"), r.get("outcome"), h))
print((r.get("final_text") or {}).get("text","")[-n:])' "$n"
