#!/usr/bin/env bash
# gpu-14 2026-10-14 (A1/A3 window 80401167): camera checkpoints inside a live window used to need gpu-14 awake at
# the exact receipt. This waits for sequence <seq>'s receipt AND a stdout line matching <pattern>, then runs
# capture-screen.sh --cam <cam> <count> times, <gap> s apart, and prints each frame path. Bounded by the window's
# active.json Deadline; exits as soon as the window is no longer open. Always run_in_background with exec.
# usage: cam-watch.sh <generation> <seq> <pattern> <out-file> [cam=tsp] [count=2] [gap=10]
set -uo pipefail
G=$1 SEQ=$2 PAT=$3 OUT=$4 CAM=${5:-tsp} N=${6:-2} GAP=${7:-10}
W=$HOME/.local/state/pocketforge/kit-windows/$G
[[ $G =~ ^[0-9a-f]{32}$ ]] || { echo "CAM_WATCH refused reason=bad_generation"; exit 2; }
S=$(printf '%06d' "$SEQ")
ts() { date -u +%FT%TZ; }
# 2026-10-14: wait (up to OPEN_WAIT_S, default 3600) for boot-open, so it can be armed before the window opens. A shell
# grep for '"State": "open"' never matched: runner.json is compact JSON. Parse it.
state() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("State",""))' "$W/runner.json" 2>/dev/null; }
until_open=$(( $(date +%s) + ${OPEN_WAIT_S:-3600} ))
until [ "$(state)" = open ] && [ -f "$W/active.json" ]; do
  [ "$(date +%s)" -lt "$until_open" ] || { echo "$(ts) CAM_WATCH refused reason=window_never_opened gen=$G" | tee -a "$OUT"; exit 2; }
  case "$(state)" in closed|failed) echo "$(ts) CAM_WATCH refused reason=window_$(state) gen=$G" | tee -a "$OUT"; exit 2 ;; esac
  sleep 10
done
deadline=$(python3 -c 'import json,sys,datetime; d=json.load(open(sys.argv[1]))["Deadline"]; print(int(datetime.datetime.fromisoformat(d.replace("Z","+00:00")).timestamp()))' "$W/active.json" 2>/dev/null) \
  || { echo "$(ts) CAM_WATCH refused reason=no_active_window gen=$G"; exit 2; }
echo "$(ts) CAM_WATCH start gen=$G seq=$SEQ pattern='$PAT' deadline=$deadline" | tee -a "$OUT"
while :; do
  [ "$(date +%s)" -lt "$deadline" ] || { echo "$(ts) CAM_WATCH stop reason=deadline" | tee -a "$OUT"; exit 3; }
  st=$(state)
  [ "$st" = open ] || { echo "$(ts) CAM_WATCH stop reason=window_$st" | tee -a "$OUT"; exit 3; }
  if ls "$W"/receipts/receipt-$S-*.json >/dev/null 2>&1; then
    if grep -qsF -- "$PAT" "$W"/revision-input-$S/*.stdout; then break; fi
    echo "$(ts) CAM_WATCH stop reason=seq_receipt_without_pattern seq=$SEQ" | tee -a "$OUT"; exit 4
  fi
  sleep 3
done
echo "$(ts) CAM_WATCH trigger seq=$SEQ" | tee -a "$OUT"
for i in $(seq 1 "$N"); do
  [ "$i" -gt 1 ] && sleep "$GAP"
  o=$(pf-automation-tool capture-screen.sh --cam "$CAM" 2>&1); rc=$?
  echo "$(ts) CAM_WATCH frame=$i rc=$rc $(printf '%s\n' "$o" | grep -E '\.(png|jpg|jpeg)' | tail -1)" | tee -a "$OUT"
done
echo "$(ts) CAM_WATCH done" | tee -a "$OUT"
