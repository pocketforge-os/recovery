#!/usr/bin/env bash
# gpu-14 2026-10-13: two lanes (pfvdc "PFVDCACHE_STATUS: CI_WAIT", themepath "THEMEPATH_STATUS: PR_OPEN 121 <sha>")
# ended with a CI wait their driver could not parse, so lane-drive exited and the PR sat with nobody waiting on CI.
# This runs the CI wait for an explicit PR/head, sends the lane its CIW continue message, then execs lane-drive.
# Always run_in_background.  usage: ciw-then-drive.sh <run> <TOKEN> <owner/repo#n> <head40> <lane-name>
set -uo pipefail
R=/home/matt/recovery/gpu14
run=${1:?run}; tok=${2:?TOKEN}; pr=${3:?owner/repo#n}; head=${4:?head}; lane=${5:?lane}
[[ $head =~ ^[0-9a-f]{40}$ ]] || { echo "CIWD_REFUSED reason=bad_head"; exit 2; }
msg=$R/.ciwd-$lane-$(date -u +%H%M%S).txt
cd "$R" || exit 2
"$R/ci-wait-continue.sh" "$pr" "$head" "$tok" "$msg" 240; rc=$?
[ "$rc" -eq 0 ] || { echo "CIWD_STOP ci_wait_rc=$rc (gpu-14 must look)"; exit 3; }
printf '\nEnd this turn with exactly one line in this format: %s state=<STATE> pr=%s head=<40-hex> (STATE = CI_WAIT after a push, or HANDBACK reason=MERGE_READY|BLOCKED ...).\n' "$tok" "$pr" >> "$msg"
"$R/lane-msg.sh" "$run" "$msg" "ciwd-$lane-${head:0:12}" "$tok" | tail -1 | cut -c1-120 || { echo "CIWD_STOP send_failed"; exit 4; }
sleep 5
PF_V2=1 exec "$R/lane-drive.sh" "$run" "$tok" "$R/$lane-continue.txt" "$lane" "$lane-drive.log" 8 24
