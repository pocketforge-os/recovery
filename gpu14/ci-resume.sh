#!/usr/bin/env bash
# 2026-09-30: group by (check_suite, name), not name: two workflows each had a job named `test`
# (#1121); name-only grouping kept the green one and hid the other, queued since 07:04Z.
# gpu-14: wait for a PR head's CI to finish, then resume the Codex run with the per-check outcome, then supervise it.
# usage: ci-resume.sh <run_id> <generation> <approvals.jsonl> <owner/repo> <pr> [max_minutes=120] [stale_head]
# If the PR head moves while waiting, it re-reads the head (the run may have pushed) and keeps waiting.
# stale_head (2026-09-30): a head whose checks are ALREADY complete (the result the run is fixing).
# Without it, arming a relay while the worker is mid-fix fires at once with the stale result.
set -uo pipefail
run=$1 gen=$2 appr=$3 R=$4 N=$5 M=${6:-120} STALE=${7:-}
cd /home/matt/mission-control || exit 9
deadline=$(( $(date +%s) + M*60 ))
# Latest check run per name across ALL pages (superseded re-triggered runs and >100 runs made the old single-page read wrong).
checks() { gh api --paginate "repos/$R/commits/$H/check-runs?per_page=100" --jq '.check_runs[]' | jq -s 'group_by((.check_suite.id|tostring) + "/" + .name) | map(max_by(.id))'; }
while :; do
  H=$(gh pr view "$N" --repo "$R" --json headRefOid --jq .headRefOid 2>/dev/null) && [ -n "$H" ] || { sleep 45; continue; }
  if [ -n "$STALE" ] && [ "${H:0:${#STALE}}" = "$STALE" ]; then
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 45; continue
  fi
  # 2026-09-30: never trust a failed/partial fetch; score from the snapshot that ended the wait.
  C=$(checks) || { sleep 45; continue; }
  jq -e 'type=="array"' >/dev/null 2>&1 <<<"$C" || { sleep 45; continue; }
  n=$(jq '[.[] | select(.status!="completed")] | length' <<<"$C")
  tot=$(jq 'length' <<<"$C")
  [ "$n" = 0 ] && [ "$tot" -gt 0 ] && break
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 45
done
sum=$(jq -r '[.[] | "\(.name) id=\(.id) \(.status):\(.conclusion // "-") started=\(.started_at // "-") completed=\(.completed_at // "-")"] | join("\n")' <<<"$C")
ann=$(for id in $(jq -r '.[] | select(.conclusion=="failure") | .id' <<<"$C"); do gh api "repos/$R/check-runs/$id/annotations" --jq '.[] | "annotation(\(.path):\(.start_line)): \(.message[0:400])"' 2>/dev/null; done | head -20)
txt=$(printf 'gpu-14 (coordinator, automated CI relay %s): CI on %s#%s exact head %s has %s.\n%s\n%s\nContinue your work order from here: if this was your red receipt, record it on the bead and implement; if this was your green run, record it and finish the handoff. If checks are still pending, record their ids and end your turn; gpu-14 relays again when they finish. Standing owner rule: NEVER raise timeout-minutes or any CI time budget; if a job nears its limit, report it as a BLOCKER with per-step timings. End with your status block.' "$(date -u +%FT%TZ)" "$R" "$N" "$H" "$([ "$n" = 0 ] && echo 'finished' || echo "NOT finished within ${M} min ($n pending)")" "$sum" "$ann")
key="ci-relay-$(date -u +%s)-${H:0:8}"
python3 -c 'import json,sys; print(json.dumps({"run_id":sys.argv[1],"key":sys.argv[2],"text":sys.argv[3]}))' "$run" "$key" "$txt" > /tmp/claude-1000/-home-matt-mission-control/b4ca9c12-a87b-4eff-b1c9-8b84d370f0a3/scratchpad/gpu14/ci-resume-$run.json
pf-task --home /home/matt/.pf-task --role coordinator run.send "$(cat /tmp/claude-1000/-home-matt-mission-control/b4ca9c12-a87b-4eff-b1c9-8b84d370f0a3/scratchpad/gpu14/ci-resume-$run.json)" | head -c 120; echo
rm -f /tmp/claude-1000/-home-matt-mission-control/b4ca9c12-a87b-4eff-b1c9-8b84d370f0a3/scratchpad/gpu14/ci-resume-$run.json
sleep 5
python3 /home/matt/recovery/gpu14/lane-supervisor.py "$run" "$gen" "$appr" 8 400; echo "sup $run rc=$?"
