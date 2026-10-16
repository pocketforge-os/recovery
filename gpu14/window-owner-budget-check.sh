#!/usr/bin/env bash
# gpu-14 2026-10-14: gamescope-window-3b (gen 6c30f32b) failed at seq 2 with receipt_delivery_failed because its
# OwnerRun (gsloc pft-8e0a7432, max_messages 40) had used 40/40: every delivered receipt costs one run message
# (.1018.12.10). Run this BEFORE any boot-open: it refuses unless the OwnerRun has room for every step's receipt plus
# the bundle/netready/close messages.
# 2026-10-14 16:16Z (A1/A3 window 80401167 lost): run-bounds.tsv held two rows for a1w pft-2818 (40 from dispatch, a
# later false 100); the awk took the LAST row, passed OK left=60, and the bundle send was refused 40/40. The bound now
# comes from the request actually sent to run.start (run-*.json paired with the admission-*.json naming this run);
# run-bounds.tsv is only a fallback, and disagreeing rows are UNKNOWN (refuse), never "last wins".
# usage: window-owner-budget-check.sh <owner-run> <step-count>     rc 0 ok, 3 too small, 2 unknown
set -uo pipefail
run=${1:?owner run}; steps=${2:?step count}
R=/home/matt/recovery/gpu14
resolved_home=$("$R/pf-task-run-home" resolve "$run" --format shell) || { echo "WINDOW_OWNER_BUDGET result=UNKNOWN run=$run reason=run_home_unresolved"; exit 2; }
eval "$resolved_home"
if [ "$H" = /home/matt/.pf-task-v3 ]; then
  echo "WINDOW_OWNER_BUDGET result=NOT_APPLICABLE run=$run home=v3 reason=no_lifetime_message_count"
  exit 0
fi
need=$(( steps * 2 + 6 ))
used=$(timeout 100 "$PFT" --home "$H" --role coordinator run.status "{\"run_id\":\"$run\"}" 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("messages",{}).get("total",""))' 2>/dev/null)
src=request
max=$(python3 - "$R" "$run" <<'PY'
import json, pathlib, sys
r, run = pathlib.Path(sys.argv[1]), sys.argv[2]
vals = set()
# 2026-10-14: wc8ow (pft-858cd2cd) was admitted by browser-eval, so its request lives under
# /home/matt/recovery/browser-eval/<bead>/; search every coordinator's records, pairing each admission with its run file.
rec = pathlib.Path("/home/matt/recovery")
adms = list(r.glob("admission-*.json")) + list(rec.glob("*/admission-*.json")) + list(rec.glob("*/*/admission-*.json"))
for adm in dict.fromkeys(adms):
    try:
        if json.loads(adm.read_text()).get("run_id") != run: continue
        spec = json.loads((adm.parent / ("run-" + adm.name[len("admission-"):])).read_text())
        m = (spec.get("bounds") or {}).get("max_messages")
        if isinstance(m, int): vals.add(m)
    except Exception:
        pass
print(vals.pop() if len(vals) == 1 else ("conflict:" + ",".join(map(str, sorted(vals))) if vals else ""))
PY
)
if [ -z "$max" ]; then
  src=run-bounds.tsv
  rows=$(awk -F'\t' -v r="$run" '$1==r{print $2}' "$R/run-bounds.tsv" 2>/dev/null | sort -u)
  if [ "$(printf '%s\n' "$rows" | grep -c .)" -gt 1 ]; then max="conflict:$(printf '%s' "$rows" | tr '\n' ',')"; else max=$rows; fi
fi
case "$max" in conflict:*)
  echo "WINDOW_OWNER_BUDGET result=UNKNOWN run=$run used=${used:-?} max=$max source=$src need=$need hint=bounds disagree; read the admitted request and fix the records"; exit 2 ;;
esac
[[ $used =~ ^[0-9]+$ && $max =~ ^[0-9]+$ ]] || { echo "WINDOW_OWNER_BUDGET result=UNKNOWN run=$run used=${used:-?} max=${max:-?} source=$src need=$need hint=no admitted request bound found"; exit 2; }
left=$(( max - used ))
if [ "$left" -lt "$need" ]; then
  echo "WINDOW_OWNER_BUDGET result=REFUSED run=$run used=$used max=$max source=$src left=$left need=$need hint=start a fresh MAX_MESSAGES=100 run and repackage the window for it"; exit 3
fi
echo "WINDOW_OWNER_BUDGET result=OK run=$run used=$used max=$max source=$src left=$left need=$need"
