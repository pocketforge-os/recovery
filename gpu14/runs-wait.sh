#!/usr/bin/env bash
# gpu-14 2026-10-14: wait for N GitHub Actions runs to complete (owner-rights read). Prints one RUNS_DONE line with
# each run's status/conclusion. Replaces an inline bash -c watcher whose nested-quoted jq filter failed to parse
# (`unexpected token "\\"`), so it could never see completion.
# usage: runs-wait.sh <owner/repo> <limit_s> <run_id>...
set -uo pipefail
R=${1:?repo}; LIM=${2:?limit}; shift 2
ts() { date -u +%FT%TZ; }
t0=$(date +%s)
while :; do
  all=1; line=""
  for id in "$@"; do
    s=$(env -u GH_TOKEN -u GITHUB_TOKEN gh api "repos/$R/actions/runs/$id" --jq '.status + " " + (.conclusion // "none")' 2>&1) || s="unreadable"
    line="$line run=$id:${s// /:}"
    case "$s" in completed*) ;; *) all=0;; esac
  done
  [ "$all" = 1 ] && { echo "$(ts) RUNS_DONE$line"; exit 0; }
  [ $(( $(date +%s) - t0 )) -ge "$LIM" ] && { echo "$(ts) RUNS_TIMEOUT$line"; exit 3; }
  sleep 60
done
