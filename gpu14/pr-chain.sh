#!/usr/bin/env bash
# 2026-09-30: group by (check_suite, name), not name: two workflows each had a job named `test`
# (#1121); name-only grouping kept the green one and hid the other, queued since 07:04Z.
# gpu-14 PR chain: exact-head CI wait -> Codex review -> thread check -> merge dry-run -> merge.
# Usage: pr-chain.sh <owner/repo> <pr> [ci_wait_minutes=60] [--no-merge]
# Exits 0 only when merged (or approved with --no-merge). Never retries a red check itself.
set -uo pipefail
R=$1; N=$2; WAIT=${3:-60}; NOMERGE=${4:-}
cd /home/matt/mission-control || exit 9
H=$(gh pr view "$N" --repo "$R" --json headRefOid --jq .headRefOid) || exit 9
echo "chain $R#$N head=$H"
# Latest check run per name across ALL pages. Re-triggered workflow runs on the same head leave
# superseded (often cancelled) runs behind, and >100 runs silently truncated the old single-page read.
# 2026-10-01: score like GitHub branch protection does -- the LATEST check run per app+name for this head
# wins. Superseded cancelled duplicates (gpu-um#164), never-finishing ghosts (automation#1120 lifecycle,
# 5.5 h, cancel/force-cancel 409) and stale re-trigger failures (#1120 orphan-guard merge-ref race) are
# all older runs of a name with a newer run; a latest run that is cancelled/failed/pending still counts.
checks() { gh api --paginate "repos/$R/commits/$H/check-runs?per_page=100" --jq '.check_runs[]' | jq -s '
  group_by((.app.id|tostring) + "/" + .name) | map(max_by(.id))'; }
start=$(date +%s); deadline=$(( start + WAIT*60 ))
while :; do
  # 2026-09-30: a failed/partial fetch ("error connecting to api.github.com") made #1126 look finished
  # then red; never trust a failed fetch, and score from the SAME snapshot that ended the wait.
  C=$(checks) || { sleep 30; continue; }
  jq -e 'type=="array"' >/dev/null 2>&1 <<<"$C" || { sleep 30; continue; }
  n=$(jq '[.[] | select(.status!="completed")] | length' <<<"$C")
  tot=$(jq 'length' <<<"$C")
  # total=0 right after a push means CI has not registered yet; wait up to 6 min for checks to appear
  # (repos with genuinely no PR checks proceed after that grace, reported as ci total=0).
  if [ "$tot" = 0 ]; then [ $(( $(date +%s) - start )) -ge 360 ] && break; sleep 30; continue; fi
  [ "$n" = 0 ] && break
  # 2026-09-30 (owner audit): fail FAST. A check that already COMPLETED red makes the head red no matter
  # what is still queued; waiting for the rest cost #1133 ~50 min of idle chain. Report it with the pending
  # count so the relay can go out immediately (same snapshot, same scoring rule as the final verdict).
  early=$(jq -r '[.[] | select(.status=="completed" and (.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="action_required")) | .name+"="+.conclusion] | join(" ")' <<<"$C")
  [ -n "$early" ] && { echo "ci total=$tot bad=[$early] pending=$n"; echo "CI_RED_EARLY $early"; exit 5; }
  [ "$(date +%s)" -ge "$deadline" ] && { echo "CI_TIMEOUT pending=$n"; exit 4; }
  sleep 30
done
bad=$(jq -r '[.[] | select(.conclusion!="success" and .conclusion!="skipped" and .conclusion!="neutral") | .name+"="+(.conclusion//"null")] | join(" ")' <<<"$C")
total=$(jq 'length' <<<"$C")
echo "ci total=$total bad=[$bad]"
[ -n "$bad" ] && { echo "CI_RED $bad"; exit 5; }
now=""; for _ in 1 2 3 4 5; do now=$(gh pr view "$N" --repo "$R" --json headRefOid --jq .headRefOid 2>/dev/null) && [ -n "$now" ] && break; sleep 20; done
[ "$now" = "$H" ] || { echo "HEAD_MOVED $H -> $now"; exit 6; }
# 2026-10-02 (owner review flow, automation#1171): a re-look resumes the SAME reviewer session
# (--continue). The adapter fails closed with a named reason when this PR has no stored session
# (first review, or reviewed before #1171) or on a force-push; only then run a fresh review.
cont=$(pf-automation-tool pf-codex-worker.sh --review-only --continue --pr "$R#$N" 2>&1); crc=$?
if [ "$crc" -eq 0 ]; then
  echo "review_mode=continue"; tail -n 4 <<<"$cont"
else
  echo "review_mode=fresh continue_rc=$crc $(/usr/bin/grep -o -E 'reason=[A-Za-z0-9_:.-]+' <<<"$cont" | tail -1)"
  pf-automation-tool pf-codex-worker.sh --review-only --pr "$R#$N" 2>&1 | tail -n 4
fi
verdict=$(gh api "repos/$R/pulls/$N/reviews?per_page=100" --jq "[.[] | select(.body | contains(\"pf-codex-review head=$H\")) | .body | capture(\"verdict=(?<v>[a-z_]+)\").v] | last")
echo "verdict=$verdict head=${H:0:8}"
[ "$verdict" = approve ] || { echo "NOT_APPROVED $verdict"; exit 7; }
owner=${R%/*}; repo=${R#*/}
unres=$(gh api graphql -f query="query{repository(owner:\"$owner\",name:\"$repo\"){pullRequest(number:$N){reviewThreads(first:100){nodes{isResolved id}}}}}" --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved|not) | .id] | join(" ")')
[ -n "$unres" ] && { echo "UNRESOLVED_THREADS $unres"; exit 8; }
[ "$NOMERGE" = --no-merge ] && { echo "APPROVED_NO_MERGE"; exit 0; }
pf-automation-tool pf-pr-merge.sh --dry-run "$R#$N" 2>&1 | /usr/bin/grep -E 'merge_status|reason' || { echo DRYRUN_FAIL; exit 10; }
pf-automation-tool pf-pr-merge.sh "$R#$N" 2>&1 | /usr/bin/grep -E 'merge_status|reason'
gh pr view "$N" --repo "$R" --json state,mergeCommit --jq '"final \(.state) merge=\(.mergeCommit.oid // "none")"'
