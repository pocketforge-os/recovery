#!/usr/bin/env bash
# gpu-14 2026-10-10 (memory new-runners-canary-before-shared-pool, bead tsp-mc9m.41.995.64):
# watch a freshly started self-hosted runner's FIRST job(s) and stop the runner on any non-success, so
# containment never waits for a coordinator turn. Reports job id, name, conclusion and runner.
# usage: runner-canary-watch.sh <runner-name> <since-iso8601Z> [jobs-to-pass=1] [max-minutes=90]
set -uo pipefail
runner=$1 since=$2 need=${3:-1} max=${4:-90}
[[ $runner =~ ^pf-synology-ci-[0-9]+$ ]] || { echo "CANARY refused reason=runner_name_not_allowed runner=$runner"; exit 2; }
[[ $since =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { echo "CANARY refused reason=bad_since"; exit 2; }
repo=pocketforge-os/pocketforge-automation
unit=actions.runner.pocketforge-os.$runner.service
stop_runner() {
  { secret-tool lookup service pf-synology.lan user pf-synology state current; echo; } | \
    ssh -4 -o BatchMode=yes -o ConnectTimeout=10 pf-synology@pf-synology.lan \
    "IFS= read -r p; printf '%s\n' \"\$p\" | sudo -S -p '' systemctl stop $unit; printf '%s\n' \"\$p\" | sudo -S -p '' systemctl is-active $unit" 2>&1 | tail -1
}
passed=0 seen=""
deadline=$(( $(date +%s) + max * 60 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  runs=$(gh api "repos/$repo/actions/runs?per_page=100&created=>=${since%T*}" --jq '.workflow_runs[].id' 2>/dev/null) || { sleep 30; continue; }
  for r in $runs; do
    rows=$(gh api "repos/$repo/actions/runs/$r/jobs?per_page=100" \
      --jq ".jobs[] | select(.runner_name==\"$runner\" and .started_at>=\"$since\") | [.id,.status,(.conclusion//\"-\"),.name,.html_url] | @tsv" 2>/dev/null) || continue
    while IFS=$'\t' read -r id st concl name url; do
      [ -n "$id" ] || continue
      case " $seen " in *" $id "*) continue ;; esac
      [ "$st" = completed ] || { echo "$(date -u +%TZ) running job=$id name=$name"; continue; }
      seen="$seen $id"
      echo "$(date -u +%TZ) CANARY_JOB runner=$runner job=$id conclusion=$concl name=$name url=$url"
      if [ "$concl" != success ]; then
        echo "CANARY_FAIL runner=$runner job=$id conclusion=$concl stopped=$(stop_runner)"
        exit 1
      fi
      passed=$((passed + 1))
      [ "$passed" -ge "$need" ] && { echo "CANARY_PASS runner=$runner jobs_passed=$passed"; exit 0; }
    done <<<"$rows"
  done
  sleep 30
done
echo "CANARY_TIMEOUT runner=$runner jobs_passed=$passed minutes=$max (runner left running; decide)"
exit 3
