#!/usr/bin/env bash
# gpu-14 2026-10-13: print a pf-task v2 run's NEWEST result text. run.result returns oldest-first, so
# {"limit":1} alone shows result #1; page with "offset": total-1.
# usage: run-last.sh <run-id> [tail_chars=4000]
set -uo pipefail
export PF_TASK_HOST_CONFIG=/home/matt/.config/pocketforge/pf-task-host.json
P=(timeout 200 /home/matt/.pf-task-v2/bin/pf-task --home /home/matt/.pf-task-v2 --role coordinator run.result)
run=${1:?run id}; n=${2:-4000}
total=$("${P[@]}" "{\"run_id\":\"$run\",\"limit\":1}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])') || exit 2
[ "$total" -ge 1 ] 2>/dev/null || { echo "RUN_LAST none total=$total"; exit 3; }
"${P[@]}" "{\"run_id\":\"$run\",\"limit\":1,\"offset\":$((total-1))}" | python3 -c '
import json,sys
d=json.load(sys.stdin); r=d["results"][0]; n=int(sys.argv[1])
h=((r.get("git") or {}).get("head") or {}).get("text","")[:12]
print("RUN_LAST index=%s receipt=%s outcome=%s head=%s" % (d["total"], r.get("receipt"), r.get("outcome"), h))
print((r.get("final_text") or {}).get("text","")[-n:])' "$n"
