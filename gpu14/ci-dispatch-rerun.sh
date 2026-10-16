#!/usr/bin/env bash
# gpu-14: rerun the failed jobs of one Actions run through the pocketforge-dispatch App (the sanctioned
# rerun path; agents' own tokens lack actions:write). 2026-10-15: uses the REST rerun endpoints, not `gh run rerun` (misleading refusal on run 38742047917). usage: ci-dispatch-rerun.sh <owner/repo> <run_id> [--all]
# 2026-10-13 (#1449 run 38410228637): rerunning only a failed orphan-guard AGGREGATE job makes it read the new attempt's
# shard checks, which do not exist ("missing_checks names=orphan-shards (0)"). An aggregate needs the whole run: --all, or
# automatically when a failed job is named orphan-guard.
set -euo pipefail
repo=$1 run=$2 mode=${3:-}
[[ $repo =~ ^pocketforge-os/[A-Za-z0-9_.-]+$ && $run =~ ^[0-9]+$ ]] || { echo "RERUN refused reason=bad_args"; exit 2; }
[ -z "$mode" ] || [ "$mode" = --all ] || { echo "RERUN refused reason=bad_mode mode=$mode"; exit 2; }
tok=$(PF_GH_APP_KEY_NAME=github/dispatch-app-key PF_GH_APP_META_NAME=github/dispatch-app-meta \
      /home/matt/pocketforge-automation/scripts/pf-github-bot-token.sh)
if [ -z "$mode" ] && GH_TOKEN="$tok" gh api "repos/$repo/actions/runs/$run/jobs?filter=latest&per_page=100" \
     --jq '.jobs[]|select(.conclusion=="failure")|.name' 2>/dev/null | grep -qx 'orphan-guard'; then mode=--all; fi
if [ "$mode" = --all ]; then
  GH_TOKEN="$tok" gh api -X POST "repos/$repo/actions/runs/$run/rerun" >/dev/null && echo "RERUN ok repo=$repo run=$run scope=all"
else
  GH_TOKEN="$tok" gh api -X POST "repos/$repo/actions/runs/$run/rerun-failed-jobs" >/dev/null && echo "RERUN ok repo=$repo run=$run scope=failed"
fi
