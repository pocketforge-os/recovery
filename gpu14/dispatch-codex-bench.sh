#!/usr/bin/env bash
# gpu-14: admit one managed Codex run for a bead (RULES=<file> is REQUIRED and selects the appended rules; bench runs use bench-worker-rules.txt). Prints run_id and generation.
# usage: dispatch-codex.sh <bead> <repo> <default-branch> <model> <effort> <approval> <scope> <task-prompt-file> [sandbox=danger-full-access (default, owner full-access 2026-09-29/30; canary PASS pft-6c1816e3)|workspace-write]
set -euo pipefail
bead=$1 repo=$2 base=$3 model=$4 effort=$5 approval=$6 scope=$7 pfile=$8 sandbox=${9:-danger-full-access}
if [ "${PF_V2:-0}" = 1 ]; then H=/home/matt/.pf-task-v2; export PF_TASK_BIN=$H/bin/pf-task PF_TASK_HOST_CONFIG=/home/matt/.config/pocketforge/pf-task-host.json; else H=/home/matt/.pf-task; fi; MC=/home/matt/mission-control; R=/home/matt/recovery/gpu14
# 2026-10-06: RULES is REQUIRED. A silent default to codex-worker-rules.txt admitted a bench
# experimenter (pft-89501854, .997.21.8) under implementation-worker rules, and it refused all device actions.
[ -n "${RULES:-}" ] && [ -f "$RULES" ] || { echo "REFUSE rules_required RULES=${RULES:-unset} hint=RULES=$R/bench-worker-rules.txt (bench experimenter) or RULES=$R/codex-worker-rules.txt (implementation worker)"; exit 2; }
parent=$(cd $MC && bd show "$bead" --json | jq -r '.[0].parent // empty')
[ -n "$parent" ] || { echo "REFUSE no_parent $bead"; exit 2; }
(cd $MC && timeout 120 python3 scripts/pf-managed.py --home $H --role coordinator doctor "$bead" | jq -e '.overall=="ready"' >/dev/null) || { echo "REFUSE doctor_not_ready $bead"; exit 3; }
(cd $MC && bd update "$bead" --claim >/dev/null)
# WT_ID: alternate worktree set id, for when a stuck run still owns /home/matt/wt/<bead> (see pf-task unreleasable-run bug).
wid=${WT_ID:-$bead}
W=/home/matt/wt/$wid/$repo
[ -d "$W" ] || (cd $MC && pf-wt create "$wid" --repos "$repo" >/dev/null)
# PR_BRANCH=1: continue an existing PR branch in place (no ff to base; the worker rebases per its prompt).
if [ "${PR_BRANCH:-0}" = 1 ]; then git -C "$W" fetch -q origin "$base"; at="existing PR branch"; else git -C "$W" fetch -q origin "$base" && git -C "$W" merge --ff-only -q "origin/$base"; at="origin/$base"; fi
[ -z "$(git -C "$W" status --porcelain)" ] || { echo "REFUSE dirty_worktree $W"; exit 4; }
prompt="$(cat "$pfile")

Your worktree: $W (branch $(git -C "$W" rev-parse --abbrev-ref HEAD), at $at $(git -C "$W" rev-parse --short HEAD)). Your model: $model.

$(cat "$RULES" | sed "s/<bead>/$bead/g")"
key="gpu14-$bead-$(date -u +%Y%m%dT%H%M%SZ)"
jq -n --arg key "$key" --arg parent "$parent" --arg task "$bead" --arg scope "$scope" --arg wt "$W" --arg model "$model" --arg effort "$effort" --arg approval "$approval" --arg sandbox "$sandbox" --arg p "$prompt" --arg tts "${TURN_TIMEOUT:-3600}" \
  '{key:$key, parent:$parent, task:$task, scope:$scope, runtime:"codex", execution_host:"matt-laptop", model:{modelID:$model, providerID:"openai"}, codex:{approval:$approval, effort:$effort, sandbox:$sandbox}, worktree:$wt, role:"worker", bounds:{context_tokens:262144, max_children:0, max_depth:0, max_messages:40, turn_timeout_seconds:($tts|tonumber)}, prompt:$p}' > $R/run-$bead.json
(cd $MC && timeout 180 python3 scripts/pf-managed.py --home $H --role coordinator run.start - < $R/run-$bead.json) > $R/admission-$bead.json
jq -r '"run_id=\(.run_id) generation=\(.generation) state=\(.state)"' $R/admission-$bead.json
