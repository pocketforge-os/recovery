#!/usr/bin/env bash
# gpu-14 2026-10-11 (rlab pft-757b818f): a lane waiting on a NON-PR Actions run (a runner canary dispatched with
# workflow_dispatch) ended `CI_WAIT reason=canary_..._run_<id>_queued` with no pr=, and lane-drive exited
# ci_wait_needs_gpu14. This watches one named run and writes the lane's continue message with every job's
# conclusion, so the lane resumes without gpu-14.
# usage: ghrun-wait.sh <owner/repo> <run_id> <TOK> <msg_file>
#   exit 0  completed; msg_file written
#   exit 3  timeout (GHRUN_POLLS x GHRUN_SLEEP); prints result=TIMEOUT
#   exit 4  run unreadable GHRUN_BAD_MAX times in a row; prints result=UNREADABLE
#   exit 2  bad arguments
set -uo pipefail
repo=${1:-}; rid=${2:-}; tok=${3:-}; msg=${4:-}
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && $rid =~ ^[0-9]+$ && $tok =~ ^[A-Z0-9_]+$ && -n $msg ]] \
  || { echo "GHRUN result=BAD_ARGS repo=$repo run=$rid"; exit 2; }
GH=${GHRUN_GH:-gh}; polls=${GHRUN_POLLS:-120}; nap=${GHRUN_SLEEP:-60}; badmax=${GHRUN_BAD_MAX:-5}; bad=0
for ((i = 1; i <= polls; i++)); do
  out=$("$GH" run view "$rid" -R "$repo" --json status,conclusion,name,jobs 2>/dev/null) || out=""
  st=$(jq -r '.status // empty' <<<"$out" 2>/dev/null)
  if [ -z "$st" ]; then
    bad=$((bad + 1)); [ "$bad" -ge "$badmax" ] && { echo "GHRUN result=UNREADABLE repo=$repo run=$rid"; exit 4; }
  else
    bad=0
    if [ "$st" = completed ]; then
      concl=$(jq -r '.conclusion // "?"' <<<"$out"); name=$(jq -r '.name // "?"' <<<"$out")
      jobs=$(jq -r '[.jobs[]? | "\(.name)=\(.conclusion // .status)"] | join("; ")' <<<"$out")
      printf 'gpu-14 driver: Actions run %s/%s (%s) completed, conclusion=%s. Jobs: %s. Continue your work from here, and end with exactly one `%s state=...` line.\n' \
        "$repo" "$rid" "$name" "$concl" "$jobs" "$tok" > "$msg"
      echo "GHRUN result=COMPLETED repo=$repo run=$rid conclusion=$concl"; exit 0
    fi
  fi
  [ "$i" -lt "$polls" ] && sleep "$nap"
done
echo "GHRUN result=TIMEOUT repo=$repo run=$rid last_status=${st:-unreadable}"; exit 3
