#!/usr/bin/env bash
# usage: send.sh <run_id> <text-file> <key-prefix>
# Prints the service reply (first 200 bytes). Exits 3 and prints SEND_REFUSED to stderr when the
# reply is not a queued/delivered acknowledgement (2026-10-08: a session_message_budget_exhausted
# refusal was lost behind a `tail -1` and the order was never delivered).
run=$1; f=$2; k=${3:-relay}; R=${GPU14_ROOT:-/home/matt/recovery/gpu14}
resolved_home=$("$R/pf-task-run-home" resolve "$run" --format shell) || { echo "SEND_REFUSED reason=run_home_unresolved run=$run" >&2; exit 2; }
eval "$resolved_home"
key="$k-$(date -u +%s)"
j=$(python3 -c 'import json,sys; print(json.dumps({"run_id":sys.argv[1],"key":sys.argv[2],"text":open(sys.argv[3]).read()}))' "$run" "$key" "$f")
# v2 still has a lifetime message cap.  Preserve its early rotation warning, but
# never inspect or count messages for v3 runs (owner ruling 2026-10-16).
if [ "$H" = /home/matt/.pf-task-v2 ]; then
  used=$(timeout 60 "$PFT" --home "$H" --role coordinator run.status "{\"run_id\":\"$run\"}" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("messages",{}).get("total",""))' 2>/dev/null)
  bound=$(awk -F'\t' -v r="$run" '$1==r{b=$2} END{print b}' "$R/run-bounds.tsv" 2>/dev/null)
  [[ $bound =~ ^[0-9]+$ ]] || bound=40
  if [ -n "$used" ] && [ "$used" -ge $((bound - 6)) ]; then
    printf 'ROTATION_DUE run=%s msgs=%s/%s\n' "$run" "$used" "$bound" >&2
  fi
fi
# 2026-10-15: a run.send while the run is busy is QUEUED (messages.pending) and starts the next turn after the current one
# ends (kwin3 23:17Z witness). It is not lost. A driver started meanwhile may exit on the OLD terminal status, so print
# a note: restart the driver after the turn, and never re-send (that duplicates the order). The lost case seen with gwin
# 22:04Z was a RUNNER receipt delivered during a running turn; lane-drive's receipt-exists nudge covers that.
rstate=$(timeout 60 "$PFT" --home "$H" --role coordinator run.status "{\"run_id\":\"$run\"}" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' 2>/dev/null)
if [ "$rstate" = busy ]; then
  printf 'MIDTURN_QUEUED run=%s key=%s: delivered when the current turn ends; do not re-send; keep or restart its driver\n' "$run" "$key" >&2
fi
out=$(timeout 180 "$PFT" --home "$H" --role coordinator run.send "$j" 2>&1)
printf '%s\n' "$out" | head -c 200; echo
if ! printf '%s' "$out" | /usr/bin/grep -q -E '"delivery": *"(queued|delivered)"'; then
  printf 'SEND_REFUSED run=%s key=%s reply=%s\n' "$run" "$key" "$(printf '%s' "$out" | head -c 300)" >&2
  exit 3
fi
