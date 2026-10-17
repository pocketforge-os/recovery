#!/usr/bin/env bash
# proc-coord 2026-10-16 (tsp-mc9m.41.1030; owner D2 22:39Z: lanes run their own loop). Handles a lane's
# `HANDBACK reason=MERGE_READY pr=<o/r#n> head=<sha>` without a gpu-14 turn: merge via gpu14-merge.sh, then send the lane
# its next bead from fleet-board/lane-queue/<lane>.txt (warm reuse). Encodes gpu-14's hand checklist
# (recovery/tsp-mc9m.41.1030/gpu14-merge-ready-checklist.md); every case it cannot decide is a HOLD for gpu-14.
# Report D: lanes idled ~2 h after MERGE_READY although 76/89 merges took <5 min (182 lane-h in 72 h).
# usage: merge-ready.sh <run_id> <TOKEN> <lane-family> <status-line>
# out (last line) and exit:
#   MERGE_READY_MERGED pr= head= merge= next=<bead>          0   merged, next item sent; the driver keeps watching
#   MERGE_READY_MERGED_NO_NEXT pr= head= merge=               11  merged, queue empty; wake gpu-14 to assign
#   MERGE_READY_HOLD reason=<...> pr= head=                   10  not merged; gpu-14 decides (today's behaviour)
# Test seams: MR_GH (gh), MR_MERGE (gpu14-merge.sh), MR_SEND (lane-msg.sh), MR_WINDOWS (kit-windows dir), GPU14_ROOT.
set -uo pipefail
run=${1:?run}; TOK=${2:?token}; fam=${3:?lane family}; stl=${4:?status line}
R=${GPU14_ROOT:-/home/matt/recovery/gpu14}
GH=${MR_GH:-gh}; MERGE=${MR_MERGE:-$R/gpu14-merge.sh}; SEND=${MR_SEND:-$R/lane-msg.sh}
WIN=${MR_WINDOWS:-$HOME/.local/state/pocketforge/kit-windows}
Q=$R/fleet-board/lane-queue; HOLDS=$R/merge-ready-holds.tsv; MLOG=$R/merge-ready.log
ts() { date -u +%FT%TZ; }
pr=$(printf '%s' "$stl" | grep -oiE 'pr=[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+' | head -n1 | cut -d= -f2)
[ -n "$pr" ] || pr=$(printf '%s' "$stl" | grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' | head -n1 | sed -E 's#^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)$#\1/\2\#\3#')
head=$(printf '%s' "$stl" | grep -oiE 'head=[0-9a-f]{40}' | head -n1 | cut -d= -f2)
hold() { echo "$(ts) HOLD run=$run pr=${pr:-?} head=${head:-?} reason=$1" >> "$MLOG"; echo "MERGE_READY_HOLD reason=$1 pr=${pr:-none} head=${head:-none}"; exit 10; }
[ -n "$pr" ] && [ -n "$head" ] || hold unparsed_status_line
repo=${pr%#*}; n=${pr##*#}
case "${MERGE_READY_AUTO:-1}" in 1) ;; *) hold auto_disabled ;; esac
[ -f "$R/merge-ready.pause" ] && hold paused_by_file
# Lane-declared holds: the lane says the PR is part of a pair, an apply/migration, or changes an enforcing gate.
case "$stl" in *"paired="*|*"copin="*) hold lane_declared_paired ;; esac
case "$stl" in *"apply=yes"*|*"migration=yes"*) hold lane_declared_apply ;; esac
pj=$(env -u GH_TOKEN -u GITHUB_TOKEN "$GH" pr view "$n" -R "$repo" --json headRefOid,state,isDraft,title,body,files 2>/dev/null) || hold pr_unreadable
[ "$(jq -r .state <<<"$pj")" = OPEN ] || hold "pr_not_open_$(jq -r .state <<<"$pj")"
[ "$(jq -r .isDraft <<<"$pj")" = false ] || hold pr_is_draft
live=$(jq -r .headRefOid <<<"$pj"); [ "$live" = "$head" ] || hold "head_moved live=$live"
files=$(jq -r '.files[].path' <<<"$pj")
# Path/title holds from merge-ready-holds.tsv: <ERE on "repo:path" or "title:<title>"> TAB <reason>. gpu-14 tunes it.
if [ -s "$HOLDS" ]; then
  while IFS=$'\t' read -r re why; do
    case "$re" in ''|'#'*) continue ;; esac
    { printf 'title:%s\n' "$(jq -r .title <<<"$pj")"; printf '%s\n' "$files" | sed "s#^#$repo:#"; } | grep -qE -- "$re" && hold "rule_${why:-match}"
  done < "$HOLDS"
fi
# An enforcing gate or harness change needs a real-producer run at the exact head (the #90/#91 lesson).
if printf '%s\n' "$files" | grep -qE '^\.github/workflows/|(^|/)[^/]*(gate|guard|lint|preflight|harness)[^/]*$'; then
  prun=$(printf '%s' "$stl" | grep -oE 'producer_run=[0-9a-f]{40}' | head -n1 | cut -d= -f2)
  [ "$prun" = "$head" ] || hold "gate_change_needs_producer_run_at_head have=${prun:-none}"
fi
# Paired PRs listed in the body that are still open merge together: gpu-14 sequences them.
for ref in $(jq -r .body <<<"$pj" | grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+|pocketforge-os/[A-Za-z0-9_.-]+#[0-9]+' | sort -u); do
  case "$ref" in https://*) ref=$(sed -E 's#^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)$#\1/\2\#\3#' <<<"$ref") ;; esac
  [ "$ref" = "$pr" ] && continue
  st=$(env -u GH_TOKEN -u GITHUB_TOKEN "$GH" pr view "${ref##*#}" -R "${ref%#*}" --json state --jq .state 2>/dev/null) || hold "related_pr_unreadable $ref"
  case "$st" in MERGED|CLOSED) ;; OPEN) hold "related_pr_open $ref" ;; *) hold "related_pr_state_unknown $ref state=${st:-none}" ;; esac
done
# A live deploy surface (runner, broker, pf-task, window tooling) is never merged while a device window is open.
if [ "$repo" = pocketforge-os/pocketforge-automation ] && printf '%s\n' "$files" | grep -qE 'pf-kit-window|kit-window|pf-task|broker|pf-kit-step|install-pf-kit'; then
  for rj in "$WIN"/*/runner.json; do
    [ -e "$rj" ] || continue
    wst=$(jq -er '.State | strings' "$rj" 2>/dev/null) || hold "window_state_unreadable gen=$(basename "$(dirname "$rj")")"
    # Only a positively terminal window is safe (recovery#13 re-look); open, opening, closing, failed or any unknown state HOLDs.
    [ "$wst" = closed ] || hold "deploy_surface_while_window_not_closed gen=$(basename "$(dirname "$rj")") state=$wst"
  done
fi
# Re-read the head right before merging, then merge with --expect-head: pf-pr-merge refuses unless the head it reads is
# the lane's head=, and its CI/review gates and --match-head-commit merge all bind to that read (recovery#13 re-look).
live=$(env -u GH_TOKEN -u GITHUB_TOKEN "$GH" pr view "$n" -R "$repo" --json headRefOid --jq .headRefOid 2>/dev/null) || hold pr_unreadable_pre_merge
[ "$live" = "$head" ] || hold "head_moved_pre_merge live=$live"
mo=$("$MERGE" "$pr" --expect-head "$head" 2>&1); mrc=$?
echo "$(ts) MERGE run=$run pr=$pr head=$head rc=$mrc $(printf '%s' "$mo" | tail -n 2 | tr '\n' ' ' | cut -c1-300)" >> "$MLOG"
[ "$mrc" -eq 0 ] || hold "merge_refused rc=$mrc $(printf '%s' "$mo" | grep -oE '(REFUSED|reason=)[^ ]*' | head -n2 | tr '\n' ' ')"
mj=$(env -u GH_TOKEN -u GITHUB_TOKEN "$GH" pr view "$n" -R "$repo" --json state,mergeCommit,headRefOid 2>/dev/null)
[ "$(jq -r .state <<<"$mj")" = MERGED ] || hold merge_not_observed
mh=$(jq -r '.headRefOid // empty' <<<"$mj"); [ "$mh" = "$head" ] || hold "merged_head_differs merged=${mh:-unknown} (gate-checked, but not the head= the lane handed back)"
msha=$(jq -r '.mergeCommit.oid // "?"' <<<"$mj")
# Close-out is never the lane's: bd close's close_gate removes the bead's worktree set under the live run (10-13 rdp
# pft-7637b9a7). Record it for gpu-14 to close at run release (release-run.sh, then bd-close-safe.sh).
obead=$(printf '%s' "$stl" | grep -oE 'bead=[A-Za-z0-9._-]+' | head -n1 | cut -d= -f2)
if [ -z "$obead" ] && [ -z "${MR_GH:-}" ]; then
  obead=$(eval "$("$R/pf-task-run-home" resolve "$run" --format shell 2>/dev/null)"; timeout 120 "$PFT" --home "$H" --role coordinator run.status "{\"run_id\":\"$run\"}" 2>/dev/null | jq -r '.task // empty' 2>/dev/null)
fi
acc=$(printf '%s' "$stl" | grep -oE 'acceptance=[a-z_]+' | head -n1 | cut -d= -f2)
# gpu-14 2026-10-17 (tfar tfa-tsp-a133#9, PR 1 of 4 for .60.29.33.6): a multi-PR bead must not be abandoned. Only an
# explicit bead_complete=yes ends the bead (close-pending row + next queue item); otherwise the lane continues its bead.
case "$stl" in *"bead_complete=yes"*) ;; *)
  cf=$(mktemp "$R/.mr-cont-$run-XXXX.txt")
  printf 'gpu-14 driver (merge-ready.sh): your PR %s merged at %s (head %s). Continue your CURRENT bead%s: its remaining PRs or device proof. When the whole bead is done, end the final MERGE_READY with bead_complete=yes (or, if nothing is left to merge, `%s state=HANDBACK reason=ALREADY_COMPLETE bead=<id> acceptance=met`).\n' "$pr" "$msha" "$head" "${obead:+ ($obead)}" "$TOK" > "$cf"
  so=$("$SEND" "$run" "$cf" "mr-cont-$(printf '%s' "$pr" | tr -c 'A-Za-z0-9' -)" "$TOK" 2>&1); src=$?
  echo "$(ts) CONT run=$run pr=$pr bead=${obead:-?} send_rc=$src" >> "$MLOG"
  [ "$src" -eq 0 ] || { echo "MERGE_READY_MERGED_NO_NEXT pr=$pr head=$head merge=$msha continue_send_failed"; exit 11; }
  echo "MERGE_READY_MERGED pr=$pr head=$head merge=$msha next=continue_current_bead"; exit 0 ;;
esac
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${obead:-unknown}" "$run" "$pr" "$msha" "${acc:-unknown}" "$(ts)" >> "$R/fleet-board/close-pending.tsv"
# Next item: first non-comment line of the lane's queue is "<bead-id> [note]". Pop it before sending (never send twice).
qf=$Q/$fam.txt; next=""
if [ -s "$qf" ]; then
  exec 8>"$qf.lock"; flock 8
  line=$(grep -m1 -vE '^[[:space:]]*(#|$)' "$qf" || true)
  if [ -n "$line" ]; then
    next=$(awk '{print $1}' <<<"$line")
    # gpu-14 2026-10-16: a tab or junk must never become a bead id.
    if ! [[ $next =~ ^[a-z0-9]+(-[a-z0-9]+)*(\.[0-9a-z]+)*$ ]]; then
      # Already merged: report merged with no next (rc 11), leave the queue untouched for gpu-14 to fix.
      flock -u 8; echo "$(ts) BADQ run=$run line=${line:0:80}" >> "$MLOG"
      echo "MERGE_READY_MERGED_NO_NEXT pr=$pr head=$head merge=$msha bad_queue_line=${next:0:40}"; exit 11
    fi
    tmp=$(mktemp "$qf.XXXX"); awk -v l="$line" 'f || $0!=l {print; next} {f=1}' "$qf" > "$tmp" && mv "$tmp" "$qf"
  fi
  # The lock stays held through delivery (fd 8 closes at exit), so a failed send restores without racing other writers.
fi
if [ -z "$next" ]; then echo "MERGE_READY_MERGED_NO_NEXT pr=$pr head=$head merge=$msha"; exit 11; fi
note=$(awk '{$1=""; sub(/^[[:space:]]+/,""); print}' <<<"$line")
mf=$(mktemp "$R/.mr-next-$run-XXXX.txt")
cat > "$mf" <<EOF
gpu-14 driver (merge-ready.sh): your PR $pr merged at $msha (head $head).
Close-out of the previous bead${obead:+ ($obead)}: post a bd comment with the merge sha and acceptance=met or acceptance=device_proof. Do NOT run bd close (it removes the worktree under your live run); gpu-14 closes it at run release. Before switching, copy any git-ignored or untracked evidence from the old worktree (git status --porcelain --ignored) to /home/matt/recovery/<old-bead>/, because that worktree is removed at release.

NEXT ASSIGNMENT: bead $next${note:+ ($note)}
1. cd /home/matt/mission-control && bd show $next ; verify Start Preconditions; bd update $next --claim
   If its acceptance is ALREADY met (merged or done elsewhere), post a bd comment with the evidence and end: $TOK state=HANDBACK reason=ALREADY_COMPLETE bead=$next acceptance=met
2. Fresh worktree from CURRENT main (never reuse the previous bead's branch): pf-wt create $next --repos <repo(s)> ; in each: git fetch origin main && git merge --ff-only origin/main
3. Bring-up mode (owner D1): keep the PR under ~400 changed lines; add no scope after approval; one review, then one same-reviewer --continue re-look that is VERIFY-ONLY on the final head (scoped to the fix commits) and is the exact-head approval pf-pr-merge needs; if it finds a defect in a fix commit, one fix plus one more verify-only pass; a finding not caused by this PR's own change gets the reply "declined, routed to <new bead>" and its thread resolved. Resolve all your threads before MERGE_READY.
4. When review is approved at the exact head and CI is green, end with: $TOK state=HANDBACK reason=MERGE_READY pr=<owner/repo>#<n> head=<40-hex> bead=<id> acceptance=met|device_proof bead_complete=yes|no (no = more PRs or device proof remain; add producer_run=<head> if the PR changes a gate, workflow or harness; add paired=<owner/repo#n> if another PR must merge with it).
EOF
so=$("$SEND" "$run" "$mf" "mr-next-$next" "$TOK" 2>&1); src=$?
echo "$(ts) NEXT run=$run next=$next send_rc=$src $(printf '%s' "$so" | tail -n1 | cut -c1-160)" >> "$MLOG"
if [ "$src" -ne 0 ]; then
  # Put the item back at the head of the queue so it is not lost; gpu-14 decides.
  { echo "$line"; cat "$qf" 2>/dev/null; } > "$qf.tmp" && mv "$qf.tmp" "$qf"
  echo "MERGE_READY_MERGED_NO_NEXT pr=$pr head=$head merge=$msha send_failed_for=$next"; exit 11
fi
printf '%s\t%s\t%s\t%s\n' "$(ts)" "$run" "$pr" "$line" >> "$Q/$fam.done"
echo "MERGE_READY_MERGED pr=$pr head=$head merge=$msha next=$next"
