#!/usr/bin/env bash
# gpu-14 2026-10-13: wait for owned-image-build run $1 to complete, then print its conclusion and failed jobs. Exits on completion.
set -uo pipefail
run=${1:?run id}
for i in $(seq 1 240); do
  st=$(gh run view "$run" -R pocketforge-os/pocketforge-automation --json status,conclusion -q '"\(.status) \(.conclusion)"' 2>/dev/null) || st="unknown ?"
  case "$st" in completed*) break ;; esac
  sleep 60
done
echo "BUILD_RUN run=$run state=$st at=$(date -u +%FT%TZ)"
gh run view "$run" -R pocketforge-os/pocketforge-automation --json jobs -q '.jobs[] | "\(.name)\t\(.conclusion)\t\(.completedAt)"' 2>&1 | head -30
