#!/usr/bin/env bash
set -euo pipefail

repo=pocketforge-os/pocketforge-automation
run_id=37591372148
expected_workflow=owned-image-build
expected_path=.github/workflows/owned-image-build.yml
expected_head=0ce42f6608578824a68124e0befa9ee23027bd6d
expected_event=workflow_dispatch
expected_actor=Burke9077
last=

while :; do
  payload=$(gh api "repos/$repo/actions/runs/$run_id")
  line=$(jq -r '[.id,.name,.path,.head_sha,.event,.actor.login,.status,(.conclusion // "")] | @tsv' <<<"$payload")
  IFS=$'\t' read -r got_id got_name got_path got_head got_event got_actor status conclusion <<<"$line"
  [[ "$got_id" == "$run_id" ]] || { echo "WATCH INVALID reason=run_id got=$got_id"; exit 2; }
  [[ "$got_name" == "$expected_workflow" ]] || { echo "WATCH INVALID reason=workflow_name got=$got_name"; exit 2; }
  [[ "$got_path" == "$expected_path" ]] || { echo "WATCH INVALID reason=workflow_path got=$got_path"; exit 2; }
  [[ "$got_head" == "$expected_head" ]] || { echo "WATCH INVALID reason=head got=$got_head"; exit 2; }
  [[ "$got_event" == "$expected_event" ]] || { echo "WATCH INVALID reason=event got=$got_event"; exit 2; }
  [[ "$got_actor" == "$expected_actor" ]] || { echo "WATCH INVALID reason=actor got=$got_actor"; exit 2; }
  current="$status/$conclusion"
  if [[ "$current" != "$last" ]]; then
    printf 'WATCH run=%s state=%s at=%s\n' "$run_id" "$current" "$(date -u +%FT%TZ)"
    last=$current
  fi
  if [[ "$status" == completed ]]; then
    if [[ "$conclusion" == success ]]; then
      echo "WATCH PASS run=$run_id conclusion=$conclusion"
      exit 0
    fi
    echo "WATCH FAIL run=$run_id conclusion=$conclusion"
    exit 1
  fi
  sleep 30
done
