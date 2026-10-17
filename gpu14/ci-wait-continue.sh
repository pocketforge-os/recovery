#!/usr/bin/env bash
# gpu-14 2026-10-10: CI_WAIT handling for lane-drive.sh (owner: fewer mechanical lane round trips).
# A lane that pushed and must wait for CI ends its turn with
#   <TOKEN> state=CI_WAIT pr=<owner/repo>#<n> head=<40-hex sha>
# This helper waits for that exact head's checks, then writes the lane's next prompt to <msg_out>:
#   GREEN -> author review on the exact head, then pf-pr-merge.sh --dry-run, then HANDBACK merge-ready
#   RED   -> the failing jobs with bounded log lines; diagnose from logs, fix test-first, push, CI_WAIT again
# A known flake (FLAKE_CHECKS, job conclusion "cancelled" at its runtime cap) is rerun ONCE per head
# through the dispatch App and waited on again, without waking the lane or gpu-14.
# Prints one line: CIW result=GREEN|RED|CONFLICT|HEAD_MOVED|TIMEOUT|BAD_ARGS ... ; exit 0 for GREEN/RED (message
# written), 3 for anything gpu-14 must look at (no message written).
# usage: ci-wait-continue.sh <owner/repo#n> <head_sha> <TOKEN> <msg_out> [max_minutes=240]
set -uo pipefail
prspec=${1:-} head=${2:-} TOK=${3:-} out=${4:-} max_min=${5:-240}
GH=${CIW_GH:-gh}
POLL_S=${CIW_POLL_S:-90}
FLAKE_CHECKS=${CIW_FLAKE_CHECKS:-pf-runner-pool}
RERUN_CMD=${CIW_RERUN_CMD:-/home/matt/recovery/gpu14/ci-dispatch-rerun.sh}
STATE_DIR=${CIW_STATE_DIR:-/home/matt/recovery/gpu14/.ciw}
mkdir -p "$STATE_DIR" 2>/dev/null && [ -w "$STATE_DIR" ] || { echo "CIW result=BAD_ARGS reason=state_dir_unwritable dir=$STATE_DIR"; exit 3; }

if ! [[ $prspec =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]] || ! [[ $head =~ ^[0-9a-f]{10,64}$ ]] \
   || ! [[ $TOK =~ ^[A-Z0-9_]+$ ]] || [ -z "$out" ]; then
  echo "CIW result=BAD_ARGS pr=$prspec head=$head"; exit 3
fi
# Not BASH_REMATCH: the later =~ tests above overwrite it (caught by test-ci-wait-continue.sh).
repo=${prspec%#*}; num=${prspec##*#}
deadline=$(( $(date +%s) + max_min * 60 ))
rerun_mark="$STATE_DIR/rerun-${repo//\//_}-$num-$head"
# 2026-10-11 (gswl, wlroots#2): a repo with NO workflows reports "no checks" forever and the lane sat in CI_WAIT
# until the deadline. Detect it once up front and tell the lane to add CI (the merge gate needs exact-head CI).
# 2026-10-13 (input-coord, design#10): NO_CI fired for a PR that ADDS the repo's first workflow; its push run was
# already in progress on the exact head. Read workflows at the HEAD commit (not the default branch), and before any
# NO_CI/NO_PR_TRIGGER verdict ask GitHub whether the head already has runs or check-runs, with a short grace period.
head_has_ci() { local n
  n=$($GH api "repos/$repo/actions/runs?head_sha=$head&per_page=1" --jq '.total_count' 2>/dev/null)
  [[ ${n:-0} =~ ^[0-9]+$ ]] && [ "${n:-0}" -gt 0 ] && return 0
  n=$($GH api "repos/$repo/commits/$head/check-runs?per_page=1" --jq '.total_count' 2>/dev/null)
  [[ ${n:-0} =~ ^[0-9]+$ ]] && [ "${n:-0}" -gt 0 ]; }
head_ci_after_grace() { local i
  for i in 1 2 3 4 5 6; do head_has_ci && return 0; [ "$i" = 6 ] || sleep "${CIW_GRACE_STEP:-15}"; done; return 1; }
wf=$($GH api "repos/$repo/contents/.github/workflows?ref=$head" 2>&1); wf_rc=$?
if [ "$wf_rc" -ne 0 ] && printf '%s' "$wf" | grep -q 'Not Found' && ! head_ci_after_grace; then
  printf '%s\n' "gpu-14 driver: $repo has NO .github/workflows, so $prspec can never get the exact-head CI the merge gate requires. Add CI first in a SEPARATE small PR: one workflow that builds and runs the repo's tests: a PRIVATE repo uses a digest-pinned image from 10.0.32.86:5555 on [self-hosted, pf-ci-container]; a PUBLIC repo mirrors pocketforge-os/gamescope (runs-on [self-hosted, pf-public-ci], container pinned by digest, repo in runner group 7 pf-public, which gpu-14 adds). Actions pinned by SHA, no docker build in the job. Merge it through the gate, merge main into $prspec (merge commit, no rebase), then end with \`$TOK state=CI_WAIT pr=<the CI PR> head=<40-hex>\`." > "$out"
  echo "CIW result=NO_CI pr=$prspec head=$head"; exit 0
fi

# 2026-10-11 (rcw, shared-workflows#9): the repo HAS workflows, but all are workflow_call-only, so a PR never gets a
# check and the lane sat 240 min to TIMEOUT. If no workflow file names a pull_request/pull_request_target/push trigger,
# say so at once and let the lane go to review + merge-gate dry-run (the gate decides whether checks are required).
if [ "$wf_rc" -eq 0 ]; then
  trig=0
  for wpath in $(printf '%s' "$wf" | jq -r '.[]?.path' 2>/dev/null); do
    # 2026-10-12: capture, then grep a here-string. `base64 -d | grep -q` under pipefail SIGPIPEd and read as "no trigger".
    wbody=$($GH api "repos/$repo/contents/$wpath?ref=$head" --jq .content 2>/dev/null | base64 -d 2>/dev/null)
    /usr/bin/grep -qE '^[[:space:]]*(pull_request|pull_request_target|push)[[:space:]]*:|^on:[[:space:]]*\[?[^#]*(pull_request|push)|^[[:space:]]*-[[:space:]]*(pull_request|push)[[:space:]]*$' <<<"$wbody" && { trig=1; break; }
  done
  # 2026-10-12 (lin gamescope#12): NO_PR_TRIGGER fired for a PR whose pull_request run was already in progress (likely a
  # transient contents-API failure read as "no trigger"). A PR that already has checks plainly has a trigger: wait for them.
  if [ "$trig" = 0 ] && [ -n "$($GH pr checks "$num" -R "$repo" 2>/dev/null)" ]; then trig=1; fi
  if [ "$trig" = 0 ] && [ -n "$(printf '%s' "$wf" | jq -r '.[]?.path' 2>/dev/null)" ] && ! head_ci_after_grace; then
    printf '%s\n' "gpu-14 driver: $repo has workflows, but none triggers on pull_request/push (e.g. workflow_call-only), so $prspec will never get checks; do not wait for CI. Run the author review loop on the exact head (same reviewer --continue for later rounds), then \`pf-pr-merge.sh --dry-run\`. If the gate refuses for missing checks, quote its line and HANDBACK (adding PR-triggered CI is then a separate small PR). End with exactly one \`$TOK state=...\` line." > "$out"
    echo "CIW result=NO_PR_TRIGGER pr=$prspec head=$head"; exit 0
  fi
fi

pr_head() { $GH pr view "$num" -R "$repo" --json headRefOid -q .headRefOid 2>/dev/null; }
# 2026-10-13 (input-coord, image#245): a PR that CONFLICTS with its base gets no pull_request runs at all, so `gh pr
# checks` stayed empty and the tool waited its full 240 min to TIMEOUT instead of naming the cause. mergeable reads
# UNKNOWN briefly after a push, so require CONFLICTING on two reads.
pr_conflicting() { local m i; for i in 1 2; do m=$($GH pr view "$num" -R "$repo" --json mergeable -q .mergeable 2>/dev/null)
  [ "$m" = CONFLICTING ] || return 1; [ "$i" = 2 ] || sleep "${CIW_CONFLICT_STEP:-20}"; done; return 0; }
conflict_exit() { local base; base=$($GH pr view "$num" -R "$repo" --json baseRefName -q .baseRefName 2>/dev/null)
  printf '%s\n' "gpu-14 driver: $prspec is CONFLICTING with its base ${base:-<base>}. GitHub starts no pull_request CI for a conflicting PR, so exact head $head can never get the CI the merge gate requires. Resolve it against origin/${base:-<base>}: merge origin/${base:-<base>} into the branch with a merge commit (never rebase or force-push a reviewed head). On a LINEAR-history repo that refuses merge commits, rebase only if no review has started; otherwise end with \`$TOK state=HANDBACK reason=BLOCKED detail=linear_conflict_after_review\`. After the push, end with \`$TOK state=CI_WAIT pr=$prspec head=<new 40-hex sha>\`." >"$out"
  echo "CIW result=CONFLICT pr=$prspec head=$head base=${base:-unknown}"; exit 0; }
# 2026-10-13 (homelan infra#79): GitHub refuses to start a workflow it cannot admit (org sha_pinning_required with
# `actions/checkout@v4`, a disallowed action, invalid YAML). That run ends conclusion=startup_failure with NO check, so
# `gh pr checks` stayed empty and the lane sat in CI_WAIT 30 min toward TIMEOUT. Such a run at the exact head is final.
startup_failures() { $GH api "repos/$repo/actions/runs?head_sha=$head&per_page=50" --jq '.workflow_runs[] | select(.conclusion=="startup_failure") | "\(.id)\t\(.path)"' 2>/dev/null; }
startup_failure_exit() { # $1 = startup_failures output
  {
    echo "gpu-14 driver: CI on $prspec exact head $head did not start: GitHub refused these workflow runs at startup (conclusion=startup_failure; no checks, no logs):"
    printf '%s\n' "$1" | while IFS=$'\t' read -r rid rpath; do echo "- $rpath (run $rid)"; done
    echo "Usual causes, in this order: (1) an action not pinned to a full 40-hex commit SHA (pocketforge-os enforces sha_pinning_required; e.g. \`actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2\`); (2) an action outside the org's allowed list; (3) invalid workflow syntax, or a runs-on label/runner group this repo cannot use. Copy the pattern of a passing workflow in the same repo."
    echo "Fix it in a NEW commit, push, and end with \`$TOK state=CI_WAIT pr=$prspec head=<new 40-hex sha>\`. End with exactly one \`$TOK state=...\` line."
  } >"$out"
  echo "CIW result=STARTUP_FAILURE pr=$prspec head=$head runs=$(printf '%s\n' "$1" | cut -f1 | paste -sd, -)"; exit 0
}
checks() { $GH pr checks "$num" -R "$repo" 2>/dev/null; }
job_conclusion() { $GH api "repos/$repo/actions/jobs/$1" --jq .conclusion 2>/dev/null; }
# 2026-10-11 (input-coord, runtime#118/#119): the Rust CI admission guard refuses a job before any test runs with
# {"rust_ci": "refused", "reason": "memory_capacity"} (exit 75, tsp-hqm1p.39.7) when the review VM's slots are full.
# That is a tempfail, not a code result, so it shares the once-per-head rerun with the known-flake rule.
# Here-string, not a pipe: `producer | grep -q` under pipefail is a SIGPIPE race.
job_capacity_refused() {
  local l; l=$($GH api "repos/$repo/actions/jobs/$1/logs" 2>/dev/null)
  /usr/bin/grep -aqE '"rust_ci":[[:space:]]*"refused",[[:space:]]*"reason":[[:space:]]*"memory_capacity"' <<<"$l"
}
# 2026-10-11: a registered flake (pattern<TAB>bead in known-flakes.tsv, e.g. trusted-artifact-read-contract's transient
# intake 503, tsp-mc9m.41.995.82) shares the once-per-head rerun instead of costing the lane a diagnosis turn.
KNOWN_FLAKES=${CIW_KNOWN_FLAKES:-/home/matt/recovery/gpu14/known-flakes.tsv}
job_known_flake() {
  [ -s "$KNOWN_FLAKES" ] || return 1
  local log pat bead
  log=$($GH api "repos/$repo/actions/jobs/$1/logs" 2>/dev/null) || return 1
  while IFS=$'\t' read -r pat bead; do
    case "$pat" in ''|'#'*) continue ;; esac
    /usr/bin/grep -aqE -- "$pat" <<<"$log" || continue
    # 2026-10-12 (lost #1403): the .995.82 row matched a DIFFERENT failure in the same suite (a pf-runner-pool
    # timeout) after .995.82 was fixed and closed, and the lane handed back CI_KNOWN_FLAKE. A closed flake bead
    # means fixed: a match now is a real failure. Only an open (or unreadable) bead counts as known.
    bst=$(cd /home/matt/mission-control && timeout 30 bd show "$bead" --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); d=d[0] if isinstance(d,list) else d; print(d.get("status",""))' 2>/dev/null)
    if [ "$bst" = closed ]; then echo "$(date -u +%FT%TZ) CIW known_flake_bead_closed job=$1 bead=$bead (treated as a real failure)" >&2; continue; fi
    echo "$(date -u +%FT%TZ) CIW known_flake job=$1 bead=$bead" >&2; return 0
  done <"$KNOWN_FLAKES"
  return 1
}

job_lines() {
  # Bounded failure evidence for one job: the last lines that look like a verdict, never the whole log.
  # The jobs-logs API, not `gh run view --job --log-failed`: the latter printed NOTHING for a re-attempted
  # run's job on 2026-10-10 (#1350 job 114215379225) while the API returned the verdict line.
  # Lines echoing the step's own script (ANSI 36;1m) are dropped so the lane sees outcomes, not source.
  local l; l=$($GH api "repos/$repo/actions/jobs/$1/logs" 2>/dev/null)
  # 2026-10-12 (lvc #1398 job 114660964222): the verdict lines were docker's `ERROR: process "/bin/sh -c ..."` echo of the
  # whole RUN script; the originating `check: ... without a GNU build-id` lines came just before it, so the lane handed
  # back for a log it cannot read (403). Quote up to 12 non-blank lines preceding the first such marker, then the verdicts.
  /usr/bin/awk '/ERROR: process "|##\[error\]/ { for (i = NR - 12; i < NR; i++) if (i > 0 && (i % 12) in b && b[i % 12] !~ /^[^ ]+ *$/) print b[i % 12]; exit } { b[NR % 12] = $0 }' <<<"$l" \
    | /usr/bin/grep -avE '\[36;1m' | cut -c1-260
  /usr/bin/grep -aE 'FAIL|ERROR|Error:|AssertionError|refus|reason=|No such file|exit code|timed out|canceled' <<<"$l" \
    | /usr/bin/grep -avE '##\[group\]|\[36;1m|Z ok [0-9]+ - ' | tail -n 6 | cut -c1-260
}

# 2026-10-10: DeepSeek workers twice reported a fabricated sha (first ~11 chars real, rest invented, once 41 chars).
# 2026-10-14: qreb (DeepSeek) twice kept only 7 real chars (f85f17235/f85f17293, daacf7748/daacf77a): threshold 7.
# If the declared sha is malformed or unknown to the repo, and the PR head shares its first 7 chars, wait on the
# real head instead of exiting HEAD_MOVED; a genuinely different push still exits HEAD_MOVED.
_cur0=$(pr_head)
if [ -n "$_cur0" ] && [ "$_cur0" != "$head" ] && [ "${#head}" -ge 7 ] && [ "${_cur0:0:7}" = "${head:0:7}" ]; then
  if ! [[ $head =~ ^[0-9a-f]{40}$ ]] || ! $GH api "repos/$repo/commits/$head" --jq .sha >/dev/null 2>&1; then
    echo "CIW note=sha_corrected pr=$prspec declared=$head actual=$_cur0 reason=declared_sha_malformed_or_unknown" >&2
    head=$_cur0
  fi
fi
[[ $head =~ ^[0-9a-f]{40}$ ]] || { echo "CIW result=BAD_ARGS pr=$prspec head=$head reason=sha_not_40_hex"; exit 3; }
rerun_mark="$STATE_DIR/rerun-${repo//\//_}-$num-$head"
while :; do
  cur=$(pr_head)
  if [ -n "$cur" ] && [ "$cur" != "$head" ]; then
    # 2026-10-12 xfer2: pushed its fix to refs/heads/tsp-mc9m.41.1018 while PR #606 tracks tsp-mc9m.41.1018-g2,
    # then read the unchanged PR head as an "unauthorized branch move". Name where the declared sha actually is.
    pr_ref=$($GH pr view "$num" -R "$repo" --json headRefName -q .headRefName 2>/dev/null)
    # 2026-10-13 (kwin2 #1446): the branch ref was at the pushed head 2f11249c, but GitHub had not synced the PR head
    # (still 977a32e7, no CI started), and the lane handed back FOREIGN_PR_HEAD_MOVE. When the PR branch ref already
    # equals the declared head, that is PR-sync lag: wait (bounded) instead of HEAD_MOVED.
    if [ -n "$pr_ref" ] && [ "$($GH api "repos/$repo/git/ref/heads/$pr_ref" --jq .object.sha 2>/dev/null)" = "$head" ]; then
      sync_lag_n=$(( ${sync_lag_n:-0} + 1 ))
      if [ "$sync_lag_n" -le 40 ]; then echo "$(date -u +%FT%TZ) CIW note=pr_head_sync_lag pr=$prspec ref=$head pr_head=$cur n=$sync_lag_n" >&2; sleep 30; continue; fi
      echo "CIW result=PR_HEAD_SYNC_STALLED pr=$prspec ref=$head pr_head=$cur waited_s=$((40*30)) hint=gpu-14_nudges_the_PR_(close+reopen)_or_contacts_GitHub_status"; exit 3
    fi
    on=$($GH api "repos/$repo/commits/$head/branches-where-head" --jq '.[].name' 2>/dev/null | paste -sd, -)
    hint=""; [ -n "$on" ] && [ -n "$pr_ref" ] && ! grep -qxF "$pr_ref" <<<"${on//,/$'\n'}" && hint=" hint=declared_sha_is_on_${on}_not_the_PR_branch_${pr_ref}:push_it_to_refs/heads/${pr_ref}_as_a_fast-forward"
    echo "CIW result=HEAD_MOVED pr=$prspec expected=$head now=$cur pr_branch=${pr_ref:-unknown} declared_on=${on:-none}$hint"; exit 3; fi
  tsv=$(checks)
  if [ -n "$tsv" ]; then
    pending=$(printf '%s\n' "$tsv" | awk -F'\t' 'NF>=2 && ($2=="pending"||$2=="queued"||$2=="in_progress"){n++} END{print n+0}')
    if [ "$pending" = 0 ]; then
      counts=$(printf '%s\n' "$tsv" | awk -F'\t' 'NF>=2{c[$2]++} END{for(k in c) printf "%s=%d ", k, c[k]}')
      bad=$(printf '%s\n' "$tsv" | awk -F'\t' 'NF>=4 && ($2=="fail"||$2=="cancel"){print $1"\t"$4}')
      if [ -z "$bad" ]; then
        # A refused workflow is not green even when the other workflows passed.
        sf=$(startup_failures); [ -z "$sf" ] || startup_failure_exit "$sf"
        cat >"$out" <<EOF
gpu-14 driver: CI on $prspec exact head $head is GREEN ($counts).
Proceed (owner D1 bring-up mode, 2026-10-16T22:39Z): author review on that exact head, ONE pass plus at most ONE same-reviewer --continue re-look. Fix only findings CAUSED by this PR's own change, in NEW commits (never amend/rebase/force-push). Any finding not caused by this PR's change (pre-existing code, merged-in main, hardening ideas, scope growth) gets a thread reply "declined, routed to <bead-id>": file that follow-up bead (bd create, worker_tier, parent = this bead), resolve the thread, and do NOT fix it here. No scope added after approval; keep PRs under ~400 changed lines. After the re-look, merge-ready on green CI: no third round. Then \`pf-pr-merge.sh --dry-run $prspec\`, then HANDBACK merge-ready with the head sha.
If you push a new commit instead, end with \`$TOK state=CI_WAIT pr=$prspec head=<new 40-hex sha>\` and the driver waits for its CI.
End with exactly one \`$TOK state=...\` line.
EOF
        echo "CIW result=GREEN pr=$prspec head=$head $counts"; exit 0
      fi
      # Known-flake rule: every failing check is in FLAKE_CHECKS and its job concluded "cancelled".
      all_flake=1; jobs=(); rr_kind=""; primary=0
      while IFS=$'\t' read -r name link; do
        [ -n "$name" ] || continue
        jid=${link##*/}; jobs+=("$name"$'\t'"$jid")
        kind=""
        # 2026-10-12 (kitres #1424): class-a-aggregate failed only because class-a-shard (0) hit known flake .995.98, and
        # the aggregate's own failure made the run "not all flake", so the once-per-head rerun never fired. An aggregate
        # job is derived from its shards: it neither blocks nor earns the rerun. Alone, it is a real failure.
        case "$name" in *aggregate*) kind=derived ;; *) primary=$((primary+1)) ;; esac
        [ -n "$kind" ] || case " $FLAKE_CHECKS " in *" $name "*) [ "$(job_conclusion "$jid")" = cancelled ] && kind=flake ;; esac
        [ -n "$kind" ] || { job_capacity_refused "$jid" && kind=capacity; }
        [ -n "$kind" ] || { job_known_flake "$jid" && kind=known_flake; }
        [ -n "$kind" ] || all_flake=0
        [ "$kind" = derived ] || rr_kind=${kind:-$rr_kind}
      done <<<"$bad"
      [ "$primary" -gt 0 ] || all_flake=0
      if [ "$all_flake" = 1 ] && [ ! -e "$rerun_mark" ]; then
        run_id=$(printf '%s\n' "$bad" | head -n1 | cut -f2 | sed -E 's#.*/runs/([0-9]+)/.*#\1#')
        : >"$rerun_mark"
        rr=$("$RERUN_CMD" "$repo" "$run_id" 2>&1 | tail -n1)
        echo "$(date -u +%FT%TZ) CIW ${rr_kind:-flake}_rerun pr=$prspec head=$head run=$run_id -> ${rr:0:120}" >&2
        sleep "$POLL_S"; continue
      fi
      {
        echo "gpu-14 driver: CI on $prspec exact head $head is RED ($counts)."
        for j in "${jobs[@]}"; do
          name=${j%%$'\t'*}; jid=${j##*$'\t'}
          echo "- $name (job $jid, conclusion $(job_conclusion "$jid")):"
          job_lines "$jid" | sed 's/^/    /'
        done
        # 2026-10-11 (gpu-um-tsp#207): the failing check `structural-smoke` only republished a verdict
        # ("structural initialization failed (rc=1)"); the job that logged it (execute_smoke) concluded SUCCESS, so the
        # lane saw no detail and spent a 1 h turn. Quote ##[error]/FAIL lines from the other jobs of the same runs too.
        bad_ids=" $(for j in "${jobs[@]}"; do printf '%s ' "${j##*$'\t'}"; done)"
        for rid in $(printf '%s\n' "$bad" | cut -f2 | sed -nE 's#.*/runs/([0-9]+)/.*#\1#p' | sort -u); do
          $GH api "repos/$repo/actions/runs/$rid/jobs" --jq '.jobs[] | "\(.id)\t\(.name)\t\(.conclusion)"' 2>/dev/null | while IFS=$'\t' read -r sjid sname sconc; do
            case "$bad_ids" in *" $sjid "*) continue ;; esac
            sl=$($GH api "repos/$repo/actions/jobs/$sjid/logs" 2>/dev/null | /usr/bin/grep -aE '##\[error\]|^[^ ]+ FAIL[: ]' | /usr/bin/grep -av '\[36;1m' | tail -n 3 | cut -c1-260)
            [ -n "$sl" ] && { echo "- related errors in sibling job $sname (job $sjid, conclusion $sconc):"; printf '%s\n' "$sl" | sed 's/^/    /'; }
          done
        done
        if [ -e "$rerun_mark" ]; then echo "(A known-flake or capacity-refusal rerun was already spent on this head; do not request another.)"; fi
        echo "Reproduce only the failing step (not a full rebuild; laptop CPU is scarce) and keep the turn under 45 min: commit evidence and end CONTINUE rather than run into the 1 h turn timeout."
        echo "Diagnose from these log lines and the full job logs, not by rerunning. A check that names a file or test your branch lacks usually means the branch is behind main: merge origin/main with a merge commit. Fix real failures test-first in NEW commits, push, and end with \`$TOK state=CI_WAIT pr=$prspec head=<new 40-hex sha>\`. If a failure is not yours, classify it with the quoted line and HANDBACK instead."
        echo "End with exactly one \`$TOK state=...\` line."
      } >"$out"
      echo "CIW result=RED pr=$prspec head=$head $counts"; exit 0
    fi
  else
    sf=$(startup_failures); [ -z "$sf" ] || startup_failure_exit "$sf"
    pr_conflicting && conflict_exit
  fi
  [ "$(date +%s)" -lt "$deadline" ] || { echo "CIW result=TIMEOUT pr=$prspec head=$head after=${max_min}m"; exit 3; }
  sleep "$POLL_S"
done
