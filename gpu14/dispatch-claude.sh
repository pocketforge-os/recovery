#!/usr/bin/env bash
# gpu-14 2026-10-15: managed pf-task CLAUDE worker, derived mechanically from dispatch-codex.sh (same worktree, claim,
# refusal and admission logic). Owner 2026-10-15 pinned Opus 5.5 for the Kubernetes/Argo build ("I bet you Opus 5.5 can
# just knock this out"). Recipe (memory history owner-claude-budget-low-codex-deputy-coordinates, 2026-10-04 r4):
# runtime "claude", model named explicitly (models.get runtime=claude refuses), and allowed_tools listing every tool
# INCLUDING the injected pf_task MCP server; without allowed_tools each call becomes a permission block.
# The <effort>/<approval>/<sandbox> arguments are accepted for interface parity and ignored.
# Trap: Claude Code's Bash run_in_background re-wakes the model OUTSIDE pf-task's turn, so prompts must forbid it.
# v3 dispatch: lifetime message counts are absent by owner ruling. Per-turn/context/child bounds remain.
# gpu-14: admit one managed Codex worker run for a bead. Prints run_id and generation.
# usage: dispatch-codex.sh <bead> <repo> <default-branch> <model> <effort> <approval> <scope> <task-prompt-file> [sandbox=danger-full-access (default, owner full-access 2026-09-29/30; canary PASS pft-6c1816e3)|workspace-write]
set -euo pipefail
bead=$1 repo=$2 base=$3 model=$4 effort=$5 approval=$6 scope=$7 pfile=$8 sandbox=${9:-danger-full-access}
# 2026-10-12 (poolslow pft-aac73dd2): the prompt named no status token, so the worker could not end with the
# `<TOKEN>_STATUS` line its driver parses, and it cost a nudge turn. Refuse such a prompt before any worktree exists.
grep -qE 'Use the token [A-Z0-9_]+_STATUS' "$pfile" || { echo "DISPATCH_REFUSED reason=prompt_without_status_token hint=add 'Use the token <LANE>_STATUS. End every turn with exactly one <LANE>_STATUS line.' to $pfile"; exit 2; }
H=/home/matt/.pf-task-v3; export PF_TASK_BIN=/home/matt/.local/libexec/pf-task-v3/pf-task PF_TASK_HOST_CONFIG=/home/matt/.config/pocketforge/pf-task-v3/pf-task-host.json; MC=/home/matt/mission-control; R=/home/matt/recovery/gpu14
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
# PR_BRANCH=1: continue an existing PR branch in place (no ff to base; the worker rebases per its prompt).
if [ "${PR_BRANCH:-0}" = 1 ]; then git -C "$W" fetch -q origin "$base"; at="existing PR branch"; else git -C "$W" fetch -q origin "$base" || { echo "REFUSE base_fetch_failed $base"; exit 4; }
  # 2026-10-10: pf-wt branches from the DEFAULT branch; reset a fresh worktree to a non-default base, refuse a failed ff.
  if [ "$fresh" = 1 ]; then git -C "$W" reset -q --hard "origin/$base"; else git -C "$W" merge --ff-only -q "origin/$base" || { echo "REFUSE base_not_fast_forward $W origin/$base"; exit 4; }; fi; at="origin/$base"; fi
[ -z "$(git -C "$W" status --porcelain)" ] || { echo "REFUSE dirty_worktree $W"; exit 4; }
prompt="$(cat "$pfile")

Your worktree: $W (branch $(git -C "$W" rev-parse --abbrev-ref HEAD), at $at $(git -C "$W" rev-parse --short HEAD)). Your model: $model.${extra_note:-}

$(cat $R/codex-worker-rules.txt | sed "s/<bead>/$bead/g")"
key="gpu14-$bead-$(date -u +%Y%m%dT%H%M%SZ)"
jq -n --arg key "$key" --arg parent "$parent" --arg task "$bead" --arg scope "$scope" --arg wt "$W" --arg model "$model" --arg effort "$effort" --arg approval "$approval" --arg sandbox "$sandbox" --arg p "$prompt" --arg tts "${TURN_TIMEOUT:-3600}" \
  '{key:$key, parent:$parent, task:$task, scope:$scope, runtime:"claude", execution_host:"matt-laptop", model:{modelID:$model, providerID:"anthropic"}, claude:{tools:["Read","Edit","Write","Bash","Grep","Glob"], allowed_tools:["Read","Edit","Write","Bash","Grep","Glob","mcp__pf_task"]}, worktree:$wt, role:"worker", bounds:{context_tokens:163840, max_children:0, max_depth:0, turn_timeout_seconds:($tts|tonumber), timeout_continuations:6}, prompt:$p}' > $R/run-$wid.json
# 2026-10-13: a refused admission used to exit silently under set -e; print the refusal body.
if ! (cd $MC && timeout 180 python3 scripts/pf-managed.py --home $H --role coordinator run.start - < $R/run-$wid.json) > $R/admission-$wid.json; then
  echo "DISPATCH_REFUSED admission=$(head -c 400 $R/admission-$wid.json)"; exit 7; fi
run_id=$(jq -r .run_id $R/admission-$wid.json); generation=$(jq -r .generation $R/admission-$wid.json)
recovery=("$R/pf-task-run-home" register --run-id "$run_id" --generation "$generation" --control-home "$H" --pf-task "$PF_TASK_BIN" --host-config "$PF_TASK_HOST_CONFIG" --revision b58007901fa2ad4fbafe3ab938db63ce89447725)
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
