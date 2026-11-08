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
Q=$R/fleet-board/lane-queue; HOLDS=$R/merge-ready-holds.tsv; MLOG=${MR_MLOG:-$R/merge-ready.log}
ts() { date -u +%FT%TZ; }
pr=$(printf '%s' "$stl" | grep -oiE 'pr=[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+' | head -n1 | cut -d= -f2)
[ -n "$pr" ] || pr=$(printf '%s' "$stl" | grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' | head -n1 | sed -E 's#^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)$#\1/\2\#\3#')
head=$(printf '%s' "$stl" | grep -oiE 'head=[0-9a-f]{40}' | head -n1 | cut -d= -f2)
hold() { echo "$(ts) HOLD run=$run pr=${pr:-?} head=${head:-?} reason=$1" >> "$MLOG"; echo "MERGE_READY_HOLD reason=$1 pr=${pr:-none} head=${head:-none}"; exit 10; }
receipt_for() {
  awk -v wanted_run="$run" -v wanted_pr="$1" '
    / RECEIPT / {
      rr=rp=rh=rm=""
      for (i=1; i<=NF; i++) {
        if ($i ~ /^run=/) { rr=$i; sub(/^run=/,"",rr) }
        if ($i ~ /^pr=/) { rp=$i; sub(/^pr=/,"",rp) }
        if ($i ~ /^head=/) { rh=$i; sub(/^head=/,"",rh) }
        if ($i ~ /^merge=/) { rm=$i; sub(/^merge=/,"",rm) }
      }
      if (rr == wanted_run && rp == wanted_pr) found=rh "\t" rm
    }
    END { if (found != "") print found }
  ' "$MLOG" 2>/dev/null
}
persist_receipt() {
  local rpr=$1 rhead=$2 rmerge=$3
  [[ $rhead =~ ^[0-9a-f]{40}$ && $rmerge =~ ^[0-9a-f]{40}$ ]] || hold "receipt_invalid member=$rpr"
  exec 9>>"$MLOG" || hold "receipt_write_failed member=$rpr"
  flock 9 || hold "receipt_lock_failed member=$rpr"
  printf '%s RECEIPT run=%s pr=%s head=%s merge=%s\n' "$(ts)" "$run" "$rpr" "$rhead" "$rmerge" >&9 \
    || hold "receipt_write_failed member=$rpr"
  sync -d "$MLOG" || hold "receipt_sync_failed member=$rpr"
  flock -u 9 || hold "receipt_unlock_failed member=$rpr"
  exec 9>&-
}
check_resume_receipt() {
  local rpr=$1 rhead=$2 rmerge=$3 required=$4 prior prior_head prior_merge
  prior=$(receipt_for "$rpr")
  if [ -z "$prior" ]; then
    [ "$required" -eq 0 ] || hold "resume_receipt_missing member=$rpr"
    persist_receipt "$rpr" "$rhead" "$rmerge"
    echo "MERGE_READY_PAIR_RECEIPT pr=$rpr head=$rhead merge=$rmerge baseline=yes"
    return
  fi
  IFS=$'\t' read -r prior_head prior_merge <<<"$prior"
  [[ $prior_head =~ ^[0-9a-f]{40}$ && $prior_merge =~ ^[0-9a-f]{40}$ ]] \
    || hold "resume_receipt_invalid member=$rpr"
  [ "$prior_head" = "$rhead" ] && [ "$prior_merge" = "$rmerge" ] \
    || hold "resume_receipt_mismatch member=$rpr receipt_head=$prior_head live_head=$rhead"
  echo "MERGE_READY_PAIR_RECEIPT pr=$rpr head=$rhead merge=$rmerge resumed=yes"
}
[ -n "$pr" ] && [ -n "$head" ] || hold unparsed_status_line
repo=${pr%#*}; n=${pr##*#}
case "${MERGE_READY_AUTO:-1}" in 1) ;; *) hold auto_disabled ;; esac
[ -f "$R/merge-ready.pause" ] && hold paused_by_file
# Lane-declared holds: the lane says the PR is part of a pair, an apply/migration, or changes an enforcing gate.
case "$stl" in *"paired="*|*"copin="*) hold lane_declared_paired ;; esac
case "$stl" in *"apply=yes"*|*"migration=yes"*) hold lane_declared_apply ;; esac
# The durable run record is the sole task identity used after merge.  A model-
# supplied bead token may corroborate it, but can never redirect close/release.
declared_bead=$(printf '%s' "$stl" | grep -oE 'bead=[A-Za-z0-9._-]+' | head -n1 | cut -d= -f2)
resolved_home=$("$R/pf-task-run-home" resolve "$run" --format shell 2>/dev/null) || hold run_home_unreadable
eval "$resolved_home"
run_status=$(timeout 120 "$PFT" --home "$H" --role coordinator run.status "{\"run_id\":\"$run\"}" 2>/dev/null) || hold run_status_unreadable
obead=$(printf '%s' "$run_status" | jq -er '.task | strings | select(length > 0)' 2>/dev/null) || hold run_task_unreadable
[[ $obead =~ ^[a-z0-9]+(-[a-z0-9]+)*(\.[0-9a-z]+)*$ ]] || hold run_task_invalid
[ -z "$declared_bead" ] || [ "$declared_bead" = "$obead" ] || hold "status_bead_mismatch declared=$declared_bead recorded=$obead"
pj=$(env -u GH_TOKEN -u GITHUB_TOKEN "$GH" pr view "$n" -R "$repo" --json headRefOid,state,isDraft,title,body,files,mergeCommit 2>/dev/null) || hold pr_unreadable
pstate=$(jq -r .state <<<"$pj")
case "$pstate" in OPEN|MERGED) ;; *) hold "pr_not_open_$pstate" ;; esac
[ "$pstate" = MERGED ] || [ "$(jq -r .isDraft <<<"$pj")" = false ] || hold pr_is_draft
live=$(jq -r .headRefOid <<<"$pj"); [ "$live" = "$head" ] || hold "head_moved live=$live"
files=$(jq -r '.files[].path' <<<"$pj")
# Open PRs listed in the body form one merge set.  Keep their exact heads so the
# whole set can pass a dry-run before the first member is merged.
declare -a pair_refs=() pair_heads=() pair_jsons=() completed_refs=()
msha=
resuming=0
if [ "$pstate" = OPEN ]; then
  pair_refs+=("$pr"); pair_heads+=("$head"); pair_jsons+=("$pj")
else
  resuming=1
  completed_refs+=("$pr")
  msha=$(jq -r '.mergeCommit.oid // empty' <<<"$pj")
  [[ $msha =~ ^[0-9a-f]{40}$ ]] || hold primary_merge_receipt_unreadable
  check_resume_receipt "$pr" "$head" "$msha" 1
fi
for ref in $(jq -r .body <<<"$pj" | grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+|pocketforge-os/[A-Za-z0-9_.-]+#[0-9]+' | sort -u); do
  case "$ref" in https://*) ref=$(sed -E 's#^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)$#\1/\2\#\3#' <<<"$ref") ;; esac
  [ "$ref" = "$pr" ] && continue
  rj=$(env -u GH_TOKEN -u GITHUB_TOKEN "$GH" pr view "${ref##*#}" -R "${ref%#*}" --json state,headRefOid,isDraft,title,body,files,mergeCommit 2>/dev/null) || hold "related_pr_unreadable $ref"
  st=$(jq -r .state <<<"$rj")
  case "$st" in
    MERGED)
      completed_refs+=("$ref")
      rh=$(jq -r .headRefOid <<<"$rj"); rsha=$(jq -r '.mergeCommit.oid // empty' <<<"$rj")
      [[ $rh =~ ^[0-9a-f]{40}$ && $rsha =~ ^[0-9a-f]{40}$ ]] || hold "related_pr_receipt_unreadable $ref"
      check_resume_receipt "$ref" "$rh" "$rsha" "$resuming" ;;
    CLOSED) completed_refs+=("$ref") ;;
    OPEN)
      [ "$(jq -r .isDraft <<<"$rj")" = false ] || hold "pair_member_ineligible $ref reason=pr_is_draft"
      rh=$(jq -r .headRefOid <<<"$rj")
      [[ $rh =~ ^[0-9a-f]{40}$ ]] || hold "pair_member_ineligible $ref reason=head_unreadable"
      pair_refs+=("$ref"); pair_heads+=("$rh"); pair_jsons+=("$rj") ;;
    *) hold "related_pr_state_unknown $ref state=${st:-none}" ;;
  esac
done
# Owner rule (10-16): runner heads deploy first, merge after. A deploy=ready automation handback merges only once the active
# runner clone contains the head (10-18: #1493 merged undeployed); otherwise gpu-14 deploys it (integration-ref + runner-redeploy).
# 2026-10-19 (#1572 budget replay merged undeployed: its handback said MERGE_READY with no deploy=): also hold any automation
# PR whose CHANGED files are code the live kit-window runner executes from its clone, whatever the handback says.
# 2026-10-19 (#1573 pf_boot_partition.py merged undeployed): a hand list missed modules the runner imports. Use the live
# clone's transitive scripts/lib import closure (26 modules at e2268150); the fallback is that list, frozen.
rclone=$(systemctl --user show -p ExecStart --value pf-kit-window-runner.service 2>/dev/null | grep -oE 'path=[^ ;]+' | head -n1 | sed -E 's#^path=##; s#/scripts/pf-kit-window-runner$##')
mods=$([ -n "$rclone" ] && python3 -I "$R/runner-import-closure.py" "$rclone/scripts/lib" 2>/dev/null) || mods=''
[ -n "$mods" ] || mods='full_image|pf_bench|pf_bench_helpers|pf_bench_lifecycle|pf_bench_live|pf_bench_package|pf_bench_plan|pf_bench_receipts|pf_bench_recovery|pf_bench_source|pf_boot_partition|pf_dutexec_contract|pf_kit_flash_image|pf_kit_network_bootstrap|pf_kit_power_cycle|pf_kit_root_lint|pf_kit_session|pf_kit_session_bounds|pf_kit_session_resume|pf_kit_smoke|pf_kit_step|pf_kit_window_prepare|pf_kit_window_runner|pf_nested_failure|pf_nested_failure_matrix|pf_self_flash_v2'
RUNNER_SURFACE="scripts/lib/($mods)\.py|scripts/pf-kit-window-runner|scripts/install-pf-kit-window-runner|systemd/pf-kit-window-runner\.service"
check_member_policies() {
  local vref=$1 vhead=$2 vj=$3 vrepo=${1%#*} vfiles re why wrj wst live_rclone
  vfiles=$(jq -r '.files[].path' <<<"$vj")
  if [ -s "$HOLDS" ]; then
    while IFS=$'\t' read -r re why; do
      case "$re" in ''|'#'*) continue ;; esac
      { printf 'title:%s\n' "$(jq -r .title <<<"$vj")"; printf '%s\n' "$vfiles" | sed "s#^#$vrepo:#"; } | grep -qE -- "$re" && hold "pair_member_ineligible $vref reason=rule_${why:-match}"
    done < "$HOLDS"
  fi
  if printf '%s\n' "$vfiles" | grep -qE '^\.github/workflows/|(^|/)[^/]*(gate|guard|lint|preflight|harness)[^/]*$'; then
    printf '%s' "$stl" | grep -oE 'producer_run=([0-9]+@)?[0-9a-f]{40}' | sed -E 's/^producer_run=([0-9]+@)?//' | grep -Fxq "$vhead" \
      || hold "pair_member_ineligible $vref reason=gate_change_needs_producer_run_at_head head=$vhead"
  fi
  if [ "$vrepo" = pocketforge-os/pocketforge-automation ] && printf '%s\n' "$vfiles" | grep -qE 'pf-kit-window|kit-window|pf-task|broker|pf-kit-step|install-pf-kit'; then
    for wrj in "$WIN"/*/runner.json; do
      [ -e "$wrj" ] || continue
      wst=$(jq -er '.State | strings' "$wrj" 2>/dev/null) || hold "pair_member_ineligible $vref reason=window_state_unreadable gen=$(basename "$(dirname "$wrj")")"
      [ "$wst" = closed ] || hold "pair_member_ineligible $vref reason=deploy_surface_while_window_not_closed gen=$(basename "$(dirname "$wrj")") state=$wst"
    done
  fi
  if [ "$vrepo" = pocketforge-os/pocketforge-automation ] && { printf '%s\n' "$stl" | grep -qiE '(^| )deploy=(deploy_)?ready( |$)' || printf '%s\n' "$vfiles" | grep -qE "^($RUNNER_SURFACE)"; }; then
    live_rclone=$(systemctl --user show -p ExecStart --value pf-kit-window-runner.service 2>/dev/null | grep -oE 'path=[^ ;]+' | head -n1 | sed -E 's#^path=##; s#/scripts/pf-kit-window-runner$##')
    { [ -n "$live_rclone" ] && git -C "$live_rclone" merge-base --is-ancestor "$vhead" HEAD 2>/dev/null; } \
      || hold "pair_member_ineligible $vref reason=deploy_first head_not_in_active_runner clone=${live_rclone:-unknown}"
  fi
}
# Apply every pre-merge policy to every still-open member.  A mixed-repository
# set must not let a safe primary mask an unsafe related PR.
for i in "${!pair_refs[@]}"; do
  check_member_policies "${pair_refs[$i]}" "${pair_heads[$i]}" "${pair_jsons[$i]}"
done
# An optional `Merge order:` line must name every open member exactly once.  In
# its absence, producer/node repositories go first, followed by lexical PR ref.
order_line=$(jq -r .body <<<"$pj" | grep -im1 -E '^[[:space:]>*-]*(merge order|merge-order)[[:space:]]*:' || true)
declare -a merge_refs=() merge_heads=()
if [ -n "$order_line" ]; then
  while read -r oref; do
    [ -n "$oref" ] || continue
    case "$oref" in https://*) oref=$(sed -E 's#^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)$#\1/\2\#\3#' <<<"$oref") ;; esac
    found=-1
    for i in "${!pair_refs[@]}"; do [ "${pair_refs[$i]}" = "$oref" ] && found=$i; done
    if [ "$found" -lt 0 ]; then
      already_done=0
      for done_ref in "${completed_refs[@]}"; do [ "$done_ref" = "$oref" ] && already_done=1; done
      [ "$already_done" -eq 1 ] && continue
      hold "pair_order_unknown_member $oref"
    fi
    for seen in "${merge_refs[@]}"; do [ "$seen" != "$oref" ] || hold "pair_order_duplicate_member $oref"; done
    merge_refs+=("$oref"); merge_heads+=("${pair_heads[$found]}")
  done < <(printf '%s\n' "$order_line" | grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+|pocketforge-os/[A-Za-z0-9_.-]+#[0-9]+')
  [ "${#merge_refs[@]}" -eq "${#pair_refs[@]}" ] || hold "pair_order_incomplete have=${#merge_refs[@]} want=${#pair_refs[@]}"
else
  while IFS=$'\t' read -r _ oref ohead; do merge_refs+=("$oref"); merge_heads+=("$ohead"); done < <(
    for i in "${!pair_refs[@]}"; do
      pri=1; [[ ${pair_refs[$i]%#*} =~ (producer|node) ]] && pri=0
      printf '%s\t%s\t%s\n' "$pri" "${pair_refs[$i]}" "${pair_heads[$i]}"
    done | sort -t $'\t' -k1,1n -k2,2
  )
fi

# Preflight every member before merging anything.  The dry run preserves all of
# pf-pr-merge's exact-head CI, review, conversation and mergeability gates.
for i in "${!merge_refs[@]}"; do
  pref=${merge_refs[$i]}; phead=${merge_heads[$i]}
  po=$("$MERGE" "$pref" --expect-head "$phead" --dry-run 2>&1); prc=$?
  echo "$(ts) PREFLIGHT run=$run pr=$pref head=$phead rc=$prc $(printf '%s' "$po" | tail -n 2 | tr '\n' ' ' | cut -c1-300)" >> "$MLOG"
  [ "$prc" -eq 0 ] || hold "pair_member_ineligible $pref rc=$prc $(printf '%s' "$po" | grep -oE '(REFUSED|reason=)[^ ]*' | head -n2 | tr '\n' ' ')"
done

# Re-read each exact head before its real merge.  pf-pr-merge checks every gate
# again and pins the merge request to that head.
for i in "${!merge_refs[@]}"; do
  mpr=${merge_refs[$i]}; mhead=${merge_heads[$i]}; mrepo=${mpr%#*}; mn=${mpr##*#}
  for j in "${!pair_refs[@]}"; do
    [ "${pair_refs[$j]}" != "$mpr" ] || check_member_policies "$mpr" "$mhead" "${pair_jsons[$j]}"
  done
  live=$(env -u GH_TOKEN -u GITHUB_TOKEN "$GH" pr view "$mn" -R "$mrepo" --json headRefOid --jq .headRefOid 2>/dev/null) || hold "pair_member_ineligible $mpr reason=pr_unreadable_pre_merge"
  [ "$live" = "$mhead" ] || hold "pair_member_ineligible $mpr reason=head_moved_pre_merge live=$live"
  mo=$("$MERGE" "$mpr" --expect-head "$mhead" 2>&1); mrc=$?
  echo "$(ts) MERGE run=$run pr=$mpr head=$mhead rc=$mrc $(printf '%s' "$mo" | tail -n 2 | tr '\n' ' ' | cut -c1-300)" >> "$MLOG"
  # A pinned-driver setup refusal is transient and occurs before any gate.
  if [ "$mrc" -ne 0 ] && printf '%s' "$mo" | grep -q 'reason=driver_pin_'; then
    sleep "${MR_PIN_RETRY_S:-60}"
    mo=$("$MERGE" "$mpr" --expect-head "$mhead" 2>&1); mrc=$?
    echo "$(ts) MERGE_RETRY driver_pin run=$run pr=$mpr head=$mhead rc=$mrc $(printf '%s' "$mo" | tail -n 2 | tr '\n' ' ' | cut -c1-300)" >> "$MLOG"
  fi
  [ "$mrc" -eq 0 ] || hold "merge_refused member=$mpr rc=$mrc $(printf '%s' "$mo" | grep -oE '(REFUSED|reason=)[^ ]*' | head -n2 | tr '\n' ' ')"
  mj=$(env -u GH_TOKEN -u GITHUB_TOKEN "$GH" pr view "$mn" -R "$mrepo" --json state,mergeCommit,headRefOid 2>/dev/null)
  [ "$(jq -r .state <<<"$mj")" = MERGED ] || hold "merge_not_observed member=$mpr"
  mh=$(jq -r '.headRefOid // empty' <<<"$mj"); [ "$mh" = "$mhead" ] || hold "merged_head_differs member=$mpr merged=${mh:-unknown}"
  member_sha=$(jq -r '.mergeCommit.oid // empty' <<<"$mj")
  persist_receipt "$mpr" "$mhead" "$member_sha"
  echo "MERGE_READY_PAIR_RECEIPT pr=$mpr head=$mhead merge=$member_sha"
  [ "$mpr" != "$pr" ] || msha=$member_sha
done
[ -n "$msha" ] || hold primary_merge_receipt_missing
# Close-out is never the lane's: bd close's close_gate removes the bead's worktree set under the live run (10-13 rdp
# pft-7637b9a7). Record it for gpu-14 to close at run release (release-run.sh, then bd-close-safe.sh).
acc=$(printf '%s' "$stl" | grep -oE 'acceptance=[a-z_]+' | head -n1 | cut -d= -f2)
# gpu-14 2026-10-17 (tfar tfa-tsp-a133#9, PR 1 of 4 for .60.29.33.6): a multi-PR bead must not be abandoned. Only an
# explicit bead_complete=yes ends the bead (close-pending row + next queue item); otherwise the lane continues its bead.
case "$stl" in *"bead_complete=yes"*) ;; *)
  cf=$(mktemp "$R/.mr-cont-$run-XXXX.txt")
  printf 'gpu-14 driver (merge-ready.sh): your PR %s merged at %s (head %s). Continue your CURRENT bead%s: its remaining PRs or device proof. When the whole bead is done, end the final MERGE_READY with bead_complete=yes (or, if nothing is left to merge, `%s state=HANDBACK reason=ALREADY_COMPLETE bead=<id> acceptance=met`). Never run bd close, bd worktree remove, or git worktree unlock/remove: your worktree is pf-wt-locked to your live run, and gpu-14 closes the bead and removes the worktree at run release.\n' "$pr" "$msha" "$head" "${obead:+ ($obead)}" "$TOK" > "$cf"
  so=$("$SEND" "$run" "$cf" "mr-cont-$(printf '%s' "$pr" | tr -c 'A-Za-z0-9' -)" "$TOK" 2>&1); src=$?
  echo "$(ts) CONT run=$run pr=$pr bead=${obead:-?} send_rc=$src" >> "$MLOG"
  [ "$src" -eq 0 ] || { echo "MERGE_READY_MERGED_NO_NEXT pr=$pr head=$head merge=$msha continue_send_failed"; exit 11; }
  echo "MERGE_READY_MERGED pr=$pr head=$head merge=$msha next=continue_current_bead"; exit 0 ;;
esac
# The lane driver owns the release -> close sequence. Return before close-pending
# or queue mutation so a released run is never assigned another bead.
if [ "${MR_DRIVER_CLOSE:-0}" = 1 ]; then
  [ -n "$obead" ] || hold complete_bead_missing_id
  echo "MERGE_READY_MERGED_CLOSE pr=$pr head=$head merge=$msha bead=$obead acceptance=${acc:-unknown}"
  exit 0
fi
done_file=$Q/$fam.done
if [ "$resuming" -eq 1 ] && awk -F '\t' -v r="$run" -v p="$pr" \
  '$2 == r && $3 == p { found=1 } END { exit !found }' "$done_file" 2>/dev/null; then
  echo "MERGE_READY_MERGED pr=$pr head=$head merge=$msha next=already_delivered"
  exit 0
fi
close_pending=$R/fleet-board/close-pending.tsv
if ! awk -F '\t' -v b="${obead:-unknown}" -v r="$run" -v p="$pr" -v m="$msha" \
  '$1 == b && $2 == r && $3 == p && $4 == m { found=1 } END { exit !found }' "$close_pending" 2>/dev/null; then
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${obead:-unknown}" "$run" "$pr" "$msha" "${acc:-unknown}" "$(ts)" >> "$close_pending" \
    || { echo "MERGE_READY_MERGED_NO_NEXT pr=$pr head=$head merge=$msha close_pending_write_failed"; exit 12; }
fi
# Next item: first non-comment line of the lane's queue is "<bead-id> [note]". Pop it before sending (never send twice).
qf=$Q/$fam.txt; recovery="$qf.requeue-$run"; next=""; line=""
if [ -s "$qf" ] || [ -s "$recovery" ]; then
  exec 8>"$qf.lock"; flock 8
  [ ! -s "$recovery" ] || line=$(cat "$recovery")
  [ -n "$line" ] || line=$(grep -m1 -vE '^[[:space:]]*(#|$)' "$qf" || true)
  if [ -n "$line" ]; then
    next=$(awk '{print $1}' <<<"$line")
    # gpu-14 2026-10-16: a tab or junk must never become a bead id.
    if ! [[ $next =~ ^[a-z0-9]+(-[a-z0-9]+)*(\.[0-9a-z]+)*$ ]]; then
      # Already merged: report merged with no next (rc 11), leave the queue untouched for gpu-14 to fix.
      flock -u 8; echo "$(ts) BADQ run=$run line=${line:0:80}" >> "$MLOG"
      echo "MERGE_READY_MERGED_NO_NEXT pr=$pr head=$head merge=$msha bad_queue_line=${next:0:40}"; exit 11
    fi
    if [ ! -s "$recovery" ]; then
      printf '%s\n' "$line" > "$recovery.tmp" && mv "$recovery.tmp" "$recovery" \
        || { flock -u 8; echo "MERGE_READY_MERGED_NO_NEXT pr=$pr head=$head merge=$msha requeue_receipt_failed_for=$next"; exit 12; }
    fi
    # If the recovery receipt's row is still queued, the prior attempt stopped
    # before the pop. Otherwise it stopped after the pop and delivery resumes.
    queued_line=$(grep -m1 -vE '^[[:space:]]*(#|$)' "$qf" || true)
    if [ "$queued_line" = "$line" ]; then
      tmp=$(mktemp "$qf.XXXX") || { flock -u 8; echo "MERGE_READY_MERGED_NO_NEXT pr=$pr head=$head merge=$msha queue_temp_failed_for=$next recovery=$recovery"; exit 12; }
      if ! awk -v l="$line" 'f || $0!=l {print; next} {f=1}' "$qf" > "$tmp" || ! mv "$tmp" "$qf"; then
        flock -u 8; echo "MERGE_READY_MERGED_NO_NEXT pr=$pr head=$head merge=$msha queue_pop_failed_for=$next recovery=$recovery"; exit 12
      fi
    fi
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
  if { echo "$line"; cat "$qf" 2>/dev/null; } > "$qf.tmp" && mv "$qf.tmp" "$qf"; then
    rm -f "$recovery"
    echo "MERGE_READY_MERGED_NO_NEXT pr=$pr head=$head merge=$msha send_failed_for=$next"; exit 11
  fi
  echo "MERGE_READY_MERGED_NO_NEXT pr=$pr head=$head merge=$msha requeue_failed_for=$next recovery=$recovery"; exit 12
fi
printf '%s\t%s\t%s\t%s\n' "$(ts)" "$run" "$pr" "$line" >> "$done_file" \
  || { echo "MERGE_READY_MERGED_NO_NEXT pr=$pr head=$head merge=$msha delivery_receipt_failed recovery=$recovery"; exit 12; }
rm -f "$recovery"
echo "MERGE_READY_MERGED pr=$pr head=$head merge=$msha next=$next"
