#!/usr/bin/env bash
# v3 dispatch: lifetime message counts are absent by owner ruling. Per-turn/context/child bounds remain.
# gpu-14: admit one managed Codex worker run for a bead. Prints run_id and generation.
# usage: dispatch-codex.sh <bead> <repo> <default-branch> <model> <effort> <approval> <scope> <task-prompt-file> [sandbox=danger-full-access (default, owner full-access 2026-09-29/30; canary PASS pft-6c1816e3)|workspace-write]
set -euo pipefail
bead=$1 repo=$2 base=$3 model=$4 effort=$5 approval=$6 scope=$7 pfile=$8 sandbox=${9:-danger-full-access}
# 2026-10-12 (poolslow pft-aac73dd2): the prompt named no status token, so the worker could not end with the
# `<TOKEN>_STATUS` line its driver parses, and it cost a nudge turn. Refuse such a prompt before any worktree exists.
grep -qE 'Use the token [A-Z0-9_]+_STATUS' "$pfile" || { echo "DISPATCH_REFUSED reason=prompt_without_status_token hint=add 'Use the token <LANE>_STATUS. End every turn with exactly one <LANE>_STATUS line.' to $pfile"; exit 2; }
# 2026-10-19 gpu-14: v4 home (#1586), precheck before run.start
# gpu-14 2026-10-24: v9 home (release 0a567a32, WAL/NORMAL, journal-growth fix tsp-mc9m.41.984.49.1); old homes retire by attrition
# gpu-14 2026-10-24: v10 home (release fd278158, heartbeat out of transitions tsp-mc9m.41.984.49.1.4); v9 retires by attrition
H=/home/matt/.pf-task-v10; export PF_TASK_BIN=/home/matt/.local/libexec/pf-task-v10/pf-task PF_TASK_HOST_CONFIG=/home/matt/.config/pocketforge/pf-task-v10/pf-task-host.json PF_TASK_MIN_FREE_BYTES=5368709120; MC=/home/matt/mission-control; R=/home/matt/recovery/gpu14
parent=$(cd $MC && bd show "$bead" --json | jq -r '.[0].parent // empty')
[ -n "$parent" ] || { echo "REFUSE no_parent $bead"; exit 2; }
(cd $MC && timeout 120 python3 scripts/pf-managed.py --home $H --role coordinator doctor "$bead" | jq -e '.overall=="ready"' >/dev/null) || { echo "REFUSE doctor_not_ready $bead"; exit 3; }
# 2026-10-10: a rotated lane's bead stays claimed by our own bot identity; accept that claim, refuse any other.
if ! cout=$(cd $MC && bd update "$bead" --claim 2>&1 >/dev/null); then
  case "$cout" in *"already claimed by pocketforge-agent[bot]"*) echo "claim: already held by pocketforge-agent[bot] (rotation), continuing" ;; *) echo "REFUSE claim_failed $cout"; exit 6 ;; esac
fi
# WT_ID: alternate worktree set id, for when a stuck run still owns /home/matt/wt/<bead> (see pf-task unreleasable-run bug).
wid=${WT_ID:-$bead}
# 2026-10-14: run-/admission- records are named by $wid, so a WT_ID dispatch no longer overwrites the live run's pair (bd-close-safe pairs them by name).
W=/home/matt/wt/$wid/$repo
fresh=0; [ -d "$W" ] || { (cd $MC && pf-wt create "$wid" --repos "$repo" >/dev/null) && fresh=1; }
# EXTRA_REPOS=r2,r3 (2026-10-07): multi-repo beads get every worktree up front. The cedrus cma= worker spent a
# QUESTION round trip asking for u-boot-tsp-a133. Each extra repo is fast-forwarded to its remote default branch.
for xr in $(printf '%s' "${EXTRA_REPOS:-}" | tr ',' ' '); do
  XW=/home/matt/wt/$wid/$xr; [ -d "$XW" ] || (cd $MC && pf-wt create "$wid" --repos "$xr" >/dev/null)
  xb=$(git -C "$XW" ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/{sub("refs/heads/","",$2);print $2;exit}')
  [ -n "$xb" ] && git -C "$XW" fetch -q origin "$xb" && git -C "$XW" merge --ff-only -q "origin/$xb" || { echo "REFUSE extra_repo_setup $xr"; exit 5; }
  extra_note="${extra_note:-}
Also in your set: $XW (branch $(git -C "$XW" rev-parse --abbrev-ref HEAD), at origin/$xb $(git -C "$XW" rev-parse --short HEAD))."
done
# 2026-10-19 (panel g3 pft-89b8f1a9): base "main" on kernel-sunxi-7.x, whose default is device/a133, put a lane on
# upstream Linux 7.2. A non-PR base other than the remote default now needs BASE_NONDEFAULT=1.
if [ "${PR_BRANCH:-0}" != 1 ] && [ "${BASE_NONDEFAULT:-0}" != 1 ]; then
  db=$(git -C "$W" ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/{sub("refs/heads/","",$2);print $2;exit}')
  [ -z "$db" ] || [ "$db" = "$base" ] || { echo "REFUSE base_not_default base=$base default=$db hint=use $db, or BASE_NONDEFAULT=1 for a deliberate non-default base"; exit 4; }
fi
# PR_BRANCH=1: continue an existing PR branch in place (no ff to base; the worker rebases per its prompt).
# 2026-10-17: a FRESH worktree (WT_ID rotation) for PR_BRANCH=1 was left on a new pf-wt branch at main; tfar g2 and
# velocity both started on the wrong commit. Reset it to the PR branch; the worker pushes HEAD:<base> fast-forward.
if [ "${PR_BRANCH:-0}" = 1 ]; then git -C "$W" fetch -q origin "$base" || { echo "REFUSE base_fetch_failed $base"; exit 4; }
  [ "$fresh" = 1 ] && git -C "$W" reset -q --hard "origin/$base"; at="existing PR branch (push HEAD:$base)"; else git -C "$W" fetch -q origin "$base" || { echo "REFUSE base_fetch_failed $base"; exit 4; }
  # 2026-10-10: pf-wt branches from the DEFAULT branch; reset a fresh worktree to a non-default base, refuse a failed ff.
  if [ "$fresh" = 1 ]; then git -C "$W" reset -q --hard "origin/$base"; else git -C "$W" merge --ff-only -q "origin/$base" || { echo "REFUSE base_not_fast_forward $W origin/$base"; exit 4; }; fi; at="origin/$base"; fi
[ -z "$(git -C "$W" status --porcelain)" ] || { echo "REFUSE dirty_worktree $W"; exit 4; }
prompt="$(cat "$pfile")

Your worktree: $W (branch $(git -C "$W" rev-parse --abbrev-ref HEAD), at $at $(git -C "$W" rev-parse --short HEAD)). Your model: $model.${extra_note:-}

$(cat $R/codex-worker-rules.txt | sed "s/<bead>/$bead/g")"
# 2026-10-20 gpu-14: CODEX_UNIFIED_EXEC=false opts one lane into the classic shell tool (proc-coord .50 pilot, v5 home).
key="gpu14-$bead-$(date -u +%Y%m%dT%H%M%SZ)"
jq -n --arg key "$key" --arg parent "$parent" --arg task "$bead" --arg scope "$scope" --arg wt "$W" --arg model "$model" --arg effort "$effort" --arg approval "$approval" --arg sandbox "$sandbox" --arg p "$prompt" --arg tts "${TURN_TIMEOUT:-3600}" --arg uexec "${CODEX_UNIFIED_EXEC:-}" \
  '{key:$key, parent:$parent, task:$task, scope:$scope, runtime:"codex", execution_host:"matt-laptop", model:{modelID:$model, providerID:"openai"}, codex:({approval:$approval, effort:$effort, sandbox:$sandbox} + (if $uexec == "false" then {unified_exec:false} elif $uexec == "true" then {unified_exec:true} else {} end)), worktree:$wt, role:"worker", bounds:{context_tokens:163840, max_children:0, max_depth:0, turn_timeout_seconds:($tts|tonumber), timeout_continuations:6}, prompt:$p}' > $R/run-$wid.json
if ! precheck=$("$R/pf-task-run-home" precheck --parent "$parent" --key "$key" --control-home "$H" 2>&1); then
  echo "DISPATCH_REFUSED reason=precheck_refused key=$key detail=${precheck:0:400}"; exit 9; fi
# 2026-10-13: a refused admission used to exit silently under set -e; print the refusal body.
if ! (cd $MC && timeout 180 python3 scripts/pf-managed.py --home $H --role coordinator run.start - < $R/run-$wid.json) > $R/admission-$wid.json; then
  echo "DISPATCH_REFUSED admission=$(head -c 400 $R/admission-$wid.json)"; exit 7; fi
run_id=$(jq -r .run_id $R/admission-$wid.json); generation=$(jq -r .generation $R/admission-$wid.json)
recovery=("$R/pf-task-run-home" register --run-id "$run_id" --generation "$generation" --control-home "$H" --pf-task "$PF_TASK_BIN" --host-config "$PF_TASK_HOST_CONFIG" --revision fd278158ec72b98a109a63caeacf254c6ed8130e)
set +e; registry_error=$("${recovery[@]}" 2>&1); registry_rc=$?; set -e
if [ "$registry_rc" -ne 0 ]; then
  printf 'DISPATCH_REGISTRY_FAILED run=%s rc=%s recovery=' "$run_id" "$registry_rc" >&2
  printf '%q ' "${recovery[@]}" >&2; printf ' detail=%q\n' "$registry_error" >&2
  exit 8
fi
account_registry=/home/matt/.local/state/pocketforge/pf-task/run-homes.jsonl
account_recovery=(env PF_TASK_RUN_HOME_REGISTRY="$account_registry" "${recovery[@]}")
set +e; registry_error=$("${account_recovery[@]}" 2>&1); registry_rc=$?; set -e
if [ "$registry_rc" -ne 0 ]; then
  printf 'DISPATCH_REGISTRY_FAILED run=%s target=account rc=%s recovery=' "$run_id" "$registry_rc" >&2
  printf '%q ' "${account_recovery[@]}" >&2; printf ' detail=%q\n' "$registry_error" >&2
  exit 8
fi
jq -r '"run_id=\(.run_id) generation=\(.generation) state=\(.state)"' $R/admission-$wid.json
