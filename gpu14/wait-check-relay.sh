#!/usr/bin/env bash
# gpu-14: wait for ONE named check at a PR's exact head, then relay its conclusion plus the log lines matching
# a pattern to the run, then supervise. usage: wait-check-relay.sh <run> <gen> <appr> <owner/repo> <pr> <head> <check_name> <log_regex> [max_min=300]
set -uo pipefail
run=$1 gen=$2 appr=$3 R=$4 N=$5 H=$6 NAME=$7 RX=$8 M=${9:-300}
S=/tmp/claude-1000/-home-matt-mission-control/b4ca9c12-a87b-4eff-b1c9-8b84d370f0a3/scratchpad/gpu14
cd /home/matt/mission-control || exit 9
dl=$(( $(date +%s) + M*60 ))
while :; do
  now=$(gh pr view "$N" --repo "$R" --json headRefOid --jq .headRefOid)
  [ "$now" = "$H" ] || { echo "HEAD_MOVED $H -> $now"; exit 6; }
  c=$(gh api --paginate "repos/$R/commits/$H/check-runs?per_page=100" --jq '.check_runs[]' | jq -s --arg n "$NAME" '[.[]|select(.name==$n)]|max_by(.id)')
  st=$(jq -r '.status // "absent"' <<<"$c")
  [ "$st" = completed ] && break
  [ "$(date +%s)" -ge "$dl" ] && { echo "TIMEOUT $NAME status=$st"; exit 7; }
  sleep 60
done
id=$(jq -r .id <<<"$c"); concl=$(jq -r .conclusion <<<"$c")
log=$(gh api "repos/$R/actions/jobs/$id/logs" 2>/dev/null | sed 's/^[0-9T:.Z-]* //' | /usr/bin/grep -v '^\[36;1m')
lines=$(/usr/bin/grep -E "$RX" <<<"$log" | head -20)
# 2026-09-30: a regex filter hid #1126's real terminal line ("--chmod option requires BuildKit");
# always append the 12 lines preceding the first ##[error].
term=$(/usr/bin/grep -B12 -m1 '##\[error\]' <<<"$log")
lines=$(printf '%s\n-- terminal lines before the first ##[error] --\n%s' "$lines" "${term:-<no ##[error] line>}")
txt=$(printf 'gpu-14 (coordinator, automated check relay %s): on %s#%s exact head %s, check `%s` (job %s) finished: %s.\nLog lines matching /%s/:\n%s\nContinue your work order from here. Other checks may still be queued; do not wait for them. Record this on the bead. End with your status block.' "$(date -u +%FT%TZ)" "$R" "$N" "$H" "$NAME" "$id" "$concl" "$RX" "$lines")
python3 -c 'import json,sys; print(json.dumps({"run_id":sys.argv[1],"key":sys.argv[2],"text":sys.argv[3]}))' "$run" "check-relay-$NAME-${H:0:8}" "$txt" > "$S/wcr-$run.json"
echo "relay: $NAME=$concl job=$id"; echo "$lines" | head -5
pf-task --home /home/matt/.pf-task --role coordinator run.send "$(cat "$S/wcr-$run.json")" | head -c 120; echo
rm -f "$S/wcr-$run.json"; sleep 5
python3 /home/matt/recovery/gpu14/lane-supervisor.py "$run" "$gen" "$appr" 8 400; echo "sup $run rc=$?"
