#!/usr/bin/env bash
# 2026-10-15 owner: the lifetime message cap is to be removed (.984.85); until pf-task ships that, admit every run at the
# schema maximum (100) so healthy runs are not killed mid-PR or mid-window. Runaway protection stays in lane-drive.
# gpu-14: admit one managed OpenCode worker run (Qwen/DeepSeek via bailian-token-plan-personal, or local vllm) for a bead. Prints run_id and generation.
# usage: dispatch-opencode.sh <bead> <repo> <default-branch> <providerID> <modelID> <context_tokens> <scope> <task-prompt-file>
set -euo pipefail
bead=$1 repo=$2 base=$3 provider=$4 model=$5 ctx=$6 scope=$7 pfile=$8
if [ "${PF_V2:-0}" = 1 ]; then H=/home/matt/.pf-task-v2; export PF_TASK_BIN=$H/bin/pf-task PF_TASK_HOST_CONFIG=/home/matt/.config/pocketforge/pf-task-host.json; else H=/home/matt/.pf-task; fi; MC=/home/matt/mission-control; R=/home/matt/recovery/gpu14
# Other coordinators (browser-eval 2026-10-10): COORD=<id> uses /home/matt/recovery/<id> for the rules file
# (worker-rules.txt there, else RULES_FILE) and the run/admission JSON, and prefixes the idempotency key.
COORD=${COORD:-gpu-14}
[ "$COORD" != gpu-14 ] || { echo "REFUSE preserved_v2_gpu14_forbidden reason=gpu14_dispatches_require_v3_registry"; exit 6; }
if [ "$COORD" != gpu-14 ]; then [[ $COORD =~ ^[a-z0-9-]+$ ]] || { echo "REFUSE bad_coord $COORD"; exit 2; }; R=/home/matt/recovery/$COORD; [ -d "$R" ] || { echo "REFUSE coord_dir_missing $R"; exit 2; }; fi
RULES_FILE=${RULES_FILE:-$( [ "$COORD" = gpu-14 ] && echo $R/codex-worker-rules.txt || echo $R/worker-rules.txt )}
[ -f "$RULES_FILE" ] || { echo "REFUSE rules_file_missing $RULES_FILE"; exit 2; }
# Billing guard (owner 2026-09-30): OpenAI models only via the SUBSCRIPTION route. In OpenCode that
# is provider `openai` with an OAuth credential (ChatGPT login). Never github-copilot (retired
# 2026-09-13, per-request billing), never an API-key OpenAI route.
case "$provider" in
  github-copilot) echo "REFUSE billing_guard provider=github-copilot (retired; metered)"; exit 5;;
  openai)
    [ -z "${OPENAI_API_KEY:-}" ] || { echo "REFUSE billing_guard OPENAI_API_KEY is set (API billing would apply)"; exit 5; }
    timeout 60 opencode auth list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | /usr/bin/grep -qE 'OpenAI[[:space:]]+oauth' \
      || { echo "REFUSE billing_guard OpenCode OpenAI credential is not oauth (subscription)"; exit 5; } ;;
  bailian-token-plan-personal|vllm) ;;
  *) echo "REFUSE billing_guard provider=$provider not on the approved list (bailian-token-plan-personal, vllm, openai[oauth])"; exit 5;;
esac
parent=$(cd $MC && bd show "$bead" --json | jq -r '.[0].parent // empty')
[ -n "$parent" ] || { echo "REFUSE no_parent $bead"; exit 2; }
(cd $MC && timeout 120 python3 scripts/pf-managed.py --home $H --role coordinator doctor "$bead" | jq -e '.overall=="ready"' >/dev/null) || { echo "REFUSE doctor_not_ready $bead"; exit 3; }
(cd $MC && bd update "$bead" --claim >/dev/null)
W=/home/matt/wt/${WT_ID:-$bead}/$repo
fresh=0; [ -d "$W" ] || { (cd $MC && pf-wt create "${WT_ID:-$bead}" --repos "$repo" >/dev/null) && fresh=1; }
# PR_BRANCH=1: continue an existing PR branch in place (no ff to base), same as dispatch-codex.sh.
if [ "${PR_BRANCH:-0}" = 1 ]; then git -C "$W" fetch -q origin "$base"; else git -C "$W" fetch -q origin "$base" || { echo "REFUSE base_fetch_failed $base"; exit 4; }
  # 2026-10-10: pf-wt branches from the DEFAULT branch; a non-descendant base (gamescope pin branch) failed the
  # ff silently and the worker started at the wrong commit. A fresh worktree is reset to the base; an existing
  # one must fast-forward or we refuse.
  if [ "$fresh" = 1 ]; then git -C "$W" reset -q --hard "origin/$base"; else git -C "$W" merge --ff-only -q "origin/$base" || { echo "REFUSE base_not_fast_forward $W origin/$base"; exit 4; }; fi; fi
# 2026-10-11 (browser-eval, tsp-da9vs pft-cf10cc65): on the 13 GB / ~300k-file WebKit worktree, OpenCode's per-instance
# bootstrap (git snapshot/indexing) died before any model call: three turns of assistant_error with 0 tokens.
# pf-task passes no `snapshot:false` through yet, so refuse with a named reason and route to Codex instead.
nfiles=$(git -C "$W" ls-files 2>/dev/null | wc -l)
if [ "${nfiles:-0}" -gt "${OC_MAX_TRACKED_FILES:-120000}" ]; then echo "REFUSE repo_too_large_for_opencode_snapshot files=$nfiles max=${OC_MAX_TRACKED_FILES:-120000} worktree=$W hint=dispatch_to_codex_or_raise_OC_MAX_TRACKED_FILES_after_proving_bootstrap"; exit 5; fi
[ -z "$(git -C "$W" status --porcelain)" ] || { echo "REFUSE dirty_worktree $W"; exit 4; }
# 2026-10-14 (ovl, tsp-mc9m.41.995.100.4): EXTRA_REPOS was silently ignored here (only dispatch-codex.sh had it), so
# the worker started without the image/platform worktrees its prompt named. Same contract as dispatch-codex.sh.
for xr in $(printf '%s' "${EXTRA_REPOS:-}" | tr ',' ' '); do
  XW=/home/matt/wt/${WT_ID:-$bead}/$xr; [ -d "$XW" ] || (cd $MC && pf-wt create "${WT_ID:-$bead}" --repos "$xr" >/dev/null)
  xb=$(git -C "$XW" ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/{sub("refs/heads/","",$2);print $2;exit}')
  [ -n "$xb" ] && git -C "$XW" fetch -q origin "$xb" && git -C "$XW" merge --ff-only -q "origin/$xb" || { echo "REFUSE extra_repo_setup $xr"; exit 5; }
  extra_note="${extra_note:-}
Also in your set: $XW (branch $(git -C "$XW" rev-parse --abbrev-ref HEAD), at origin/$xb $(git -C "$XW" rev-parse --short HEAD))."
done
prompt="$(cat "$pfile")

Your worktree: $W (branch $(git -C "$W" rev-parse --abbrev-ref HEAD), at ${PR_BRANCH:+existing PR branch }$(git -C "$W" rev-parse --short HEAD)). Your model: $provider/$model (OpenCode runtime).${extra_note:-}

$(sed "s/<bead>/$bead/g" "$RULES_FILE")"
# Session permission rules (owner 2026-09-29/30: workers are full team members with machine access,
# like Codex danger-full-access). Explicit allow so the host config never stalls a managed run on prompts.
# 2026-10-10 dsk hang: session rules do not reach `task` subagent sessions. A subagent falls back to the
# pf-task revision opencode.json (bash "*": ask), its bash call waits for an answer that never comes, and the
# parent turn hangs on the task call (DeepSeek, 1 h). bounds.max_children is 0, so deny `task` (last match wins).
PERM='[{"permission":"*","pattern":"*","action":"allow"},{"permission":"bash","pattern":"*","action":"allow"},{"permission":"edit","pattern":"*","action":"allow"},{"permission":"read","pattern":"*","action":"allow"},{"permission":"external_directory","pattern":"*","action":"allow"},{"permission":"webfetch","pattern":"*","action":"allow"},{"permission":"task","pattern":"*","action":"deny"}]'
key="${COORD//-/}-oc-$bead-$(date -u +%Y%m%dT%H%M%SZ)"
jq -n --arg tts "${TURN_TIMEOUT:-3600}" --arg maxm "${MAX_MESSAGES:-100}" --arg key "$key" --arg parent "$parent" --arg task "$bead" --arg scope "$scope" --arg wt "$W" --arg model "$model" --arg provider "$provider" --argjson ctx "$ctx" --argjson perm "$PERM" --arg p "$prompt" \
  '{key:$key, parent:$parent, task:$task, scope:$scope, runtime:"opencode", execution_host:"matt-laptop", model:{modelID:$model, providerID:$provider}, worktree:$wt, permission:$perm, role:"worker", bounds:{context_tokens:$ctx, max_children:0, max_depth:0, max_messages:($maxm|tonumber), turn_timeout_seconds:($tts|tonumber)}, prompt:$p}' > $R/run-oc-$bead.json
if ! (cd $MC && timeout 180 python3 scripts/pf-managed.py --home $H --role coordinator run.start - < $R/run-oc-$bead.json) > $R/admission-oc-$bead.json; then echo "DISPATCH_REFUSED admission=$(head -c 400 $R/admission-oc-$bead.json)"; exit 7; fi
jq -r '"run_id=\(.run_id) generation=\(.generation) state=\(.state)"' $R/admission-oc-$bead.json
# 2026-10-11: lane-drive rotates a run 4 messages before ITS budget (workers are bounded at 40, not 100);
# record run_id -> max_messages here because run.status does not expose the bound.
printf '%s\t%s\n' "$(jq -r .run_id $R/admission-oc-$bead.json)" "$(jq -r '.bounds.max_messages // empty' $R/run-oc-$bead.json)" >> $R/run-bounds.tsv
