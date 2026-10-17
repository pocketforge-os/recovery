#!/usr/bin/env bash
# gpu-14 2026-10-16 (owner D2/D3): pop a lane's FFB queue head and send it as the lane's next assignment (same text as merge-ready.sh).
set -uo pipefail
R=${GPU14_ROOT:-/home/matt/recovery/gpu14}; SEND=${AN_SEND:-$R/lane-msg.sh}; lane=${1:?lane}; run=${2:?run}; TOK=${3:?token}
qf=$R/fleet-board/lane-queue/$lane.txt
exec 8>"$qf.lock"; flock 8
line=$(grep -m1 -vE '^[[:space:]]*(#|$)' "$qf" || true); [ -n "$line" ] || { echo "ASSIGN_EMPTY lane=$lane"; exit 11; }
next=$(awk '{print $1}' <<<"$line")
# proc-coord 2026-10-17 (recovery#13 review): the queue lock stays held through delivery; a failed send restores the
# item at the head under that lock, so a bead is never lost and no concurrent queue update is overwritten.
tmp=$(mktemp "$qf.XXXX"); awk -v l="$line" 'f || $0!=l {print; next} {f=1}' "$qf" > "$tmp" && mv "$tmp" "$qf"
mf=$(mktemp "$R/.assign-$lane-XXXX.txt")
cat > "$mf" <<MSG
gpu-14 (owner D3, FFB focus): your previous item is finished or parked. Leave its bead open: post a bd comment with its final state; gpu-14 closes beads at run release. Copy any git-ignored or untracked evidence from the old worktree to /home/matt/recovery/<old-bead>/ before switching.

NEXT ASSIGNMENT: ${line}
1. cd /home/matt/mission-control && bd show $next ; verify the Start Preconditions (if one is unmet, hand back BLOCKED with the exact precondition). If the bead's acceptance is ALREADY met (merged and pinned elsewhere), post a bd comment with the evidence and end with \`$TOK state=HANDBACK reason=ALREADY_COMPLETE bead=$next acceptance=met\`: the driver then sends your next item. Otherwise: bd update $next --claim
2. Fresh worktree from CURRENT main: pf-wt create $next --repos <repo(s)> (Mission Control: bd worktree create); in each: git fetch origin main && git merge --ff-only origin/main
3. Bring-up mode (owner D1): iterate live where you can; keep the PR under ~400 changed lines; no scope after approval; one review, then one same-reviewer --continue re-look that is VERIFY-ONLY on the final head (scoped to the fix commits) and is the exact-head approval pf-pr-merge needs; if it finds a defect in a fix commit, one fix plus one more verify-only pass; a finding not caused by this PR's own change gets "declined, routed to <new bead>" and its thread resolved.
4. Never wait or poll in-turn: start anything over ~2 min detached with output to a file. A LOCAL job (tests, author review): end \`$TOK state=CONTINUE\` and read its output file next turn. \`CI_WAIT pr= head=\` is only for a pushed PR head; \`BUILD_RUNNING run=\` is only for a numeric GitHub Actions run id.
5. When review is approved at the exact head and CI is green: $TOK state=HANDBACK reason=MERGE_READY pr=<owner/repo>#<n> head=<40-hex> bead=$next acceptance=met|device_proof (add producer_run=<head> for gate/workflow/harness changes; paired=<owner/repo#n> if one must merge with it). Device proof needed: hand back BOOT_READY with the plan dir.
MSG
so=$("$SEND" "$run" "$mf" "assign-$next" "$TOK" 2>&1); src=$?
printf '%s\n' "$so" | tail -1 | cut -c1-80
if [ "$src" -ne 0 ]; then
  { echo "$line"; cat "$qf"; } > "$qf.tmp" && mv "$qf.tmp" "$qf"
  echo "ASSIGN_SEND_FAILED lane=$lane run=$run next=$next rc=$src (restored at the queue head)"; exit 12
fi
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$run" "$line" >> "$R/fleet-board/lane-queue/$lane.done"
echo "ASSIGNED lane=$lane run=$run next=$next"
