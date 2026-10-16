#!/usr/bin/env bash
# gpu-14: wait until a PR's checks are all finished, then print one result line and exit.
# usage: pr-ci-wait.sh <owner/repo> <number> [merge_if_head=<40-hex sha>] [max_minutes=240]
# This gh build has no `pr checks --json`, and `gh pr checks` exits 8 while checks are pending
# and 1 when any failed (2026-10-10: every JSON watcher failed silently for 2 h). So parse the
# plain TSV (name, state, duration, link) and never treat a non-zero exit as "no data".
# merge_if_head: when every check passed and the PR head still equals this sha, merge through
# pf-pr-merge.sh (the gate re-checks CI, review and head itself) and print its merge_status.
set -uo pipefail
repo=$1 num=$2 merge_head=${3:-} max_min=${4:-240}
deadline=$(( $(date +%s) + max_min * 60 ))
while :; do
  out=$(gh pr checks "$num" -R "$repo" 2>/dev/null)
  if [ -n "$out" ]; then
    counts=$(printf '%s\n' "$out" | awk -F'\t' 'NF>=2{c[$2]++} END{for(k in c) printf "%s=%d ", k, c[k]}')
    pending=$(printf '%s\n' "$out" | awk -F'\t' 'NF>=2 && ($2=="pending" || $2=="queued" || $2=="in_progress"){n++} END{print n+0}')
    if [ "$pending" = 0 ]; then
      bad=$(printf '%s\n' "$out" | awk -F'\t' 'NF>=2 && ($2=="fail" || $2=="cancel"){printf "%s ", $1}')
      if [ -n "$bad" ]; then echo "CI_DONE $repo#$num RED: $bad| $counts"; exit 0; fi
      if [ -n "$merge_head" ]; then
        head=$(gh pr view "$num" -R "$repo" --json headRefOid -q .headRefOid 2>/dev/null)
        if [ "$head" != "$merge_head" ]; then echo "CI_DONE $repo#$num GREEN but HEAD_MOVED $head | $counts"; exit 0; fi
        res=$(cd /home/matt/mission-control && pf-automation-tool pf-pr-merge.sh "$repo#$num" 2>&1 | grep -E 'merge_status|refus|reason=' | head -3 | tr '\n' ' ')
        echo "CI_DONE $repo#$num GREEN merge: $res| $counts"; exit 0
      fi
      echo "CI_DONE $repo#$num GREEN | $counts"; exit 0
    fi
  fi
  [ "$(date +%s)" -lt "$deadline" ] || { echo "CI_TIMEOUT $repo#$num after ${max_min} min | ${counts:-no data}"; exit 0; }
  sleep 90
done
