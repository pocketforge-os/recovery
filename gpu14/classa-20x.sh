#!/usr/bin/env bash
# gpu-14 2026-10-14: rpin .995.98 pre-merge acceptance. 20 SEQUENTIAL owner-rights reruns of one class-a shard job,
# each waited to completion. Per attempt: conclusion, plus counts of the two flake signatures in the job log.
# usage (run_in_background): classa-20x.sh <run_id> <job_name> <count> <out.tsv>
set -uo pipefail
RUN=${1:?run}; NAME=${2:?job name}; N=${3:-20}; OUT=${4:?out tsv}
R=pocketforge-os/pocketforge-automation
G() { env -u GH_TOKEN -u GITHUB_TOKEN gh "$@"; }
ts() { date -u +%FT%TZ; }
latest_job() {  # id and conclusion of NAME in the run's latest attempt
  local a; a=$(G api repos/$R/actions/runs/$RUN -q .run_attempt) || return 1
  G api "repos/$R/actions/runs/$RUN/attempts/$a/jobs?per_page=100" \
    -q ".jobs[] | select(.name==\"$NAME\") | \"\(.id) \(.status) \(.conclusion) \(.run_attempt)\"" | head -1
}
[ -s "$OUT" ] || printf 'i\tattempt\tjob\tconclusion\tptw_timeouts\tboot_readiness_failed\tfinished\n' > "$OUT"
done_n=$(( $(wc -l < "$OUT") - 1 ))
for i in $(seq $((done_n + 1)) "$N"); do
  read -r job st concl att <<<"$(latest_job)"
  [[ $job =~ ^[0-9]+$ ]] || { echo "$(ts) CLASSA_STOP reason=job_not_found i=$i"; exit 2; }
  # never start a rerun while the run is still in progress
  until [ "$(G api repos/$R/actions/runs/$RUN -q .status)" = completed ]; do sleep 20; done
  read -r job st concl att <<<"$(latest_job)"
  G run rerun --job "$job" -R $R >/dev/null 2>&1 || { echo "$(ts) CLASSA_STOP reason=rerun_refused i=$i job=$job"; exit 3; }
  sleep 15
  t0=$(date +%s)
  while :; do
    s=$(G api repos/$R/actions/runs/$RUN -q .status)
    [ "$s" = completed ] && break
    [ $(( $(date +%s) - t0 )) -gt 5400 ] && { echo "$(ts) CLASSA_STOP reason=attempt_timeout i=$i"; exit 4; }
    sleep 20
  done
  read -r job st concl att <<<"$(latest_job)"
  log=$(G api repos/$R/actions/jobs/$job/logs 2>/dev/null)
  ptw=$(printf '%s' "$log" | grep -c 'PTW cache invalidation timed out')
  brf=$(printf '%s' "$log" | grep -c 'boot_readiness_failed')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$att" "$job" "$concl" "$ptw" "$brf" "$(ts)" >> "$OUT"
  echo "$(ts) CLASSA_ROW i=$i attempt=$att job=$job conclusion=$concl ptw=$ptw boot_readiness_failed=$brf"
done
pass=$(awk -F'\t' 'NR>1 && $4=="success"' "$OUT" | wc -l); total=$(( $(wc -l < "$OUT") - 1 ))
echo "$(ts) CLASSA_DONE pass=$pass total=$total out=$OUT"
