#!/usr/bin/env bash
set -euo pipefail

K=$(cd -- "$(dirname -- "$0")" && pwd)
die() { printf 'BUILD9_CLOSE_GUARD_TEST state=FAIL reason=%s\n' "$1"; exit 1; }

guard=$K/runbook-close-guard.sh
closer=$K/runbook-close.sh
[[ -x "$guard" ]] || die close_guard_missing
[[ -x "$closer" ]] || die close_helper_missing

python3 - "$K/RUNBOOK.md.in" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
need = {
    "source": 'source "$kit/runbook-close-guard.sh"',
    "anchor": 'test -f "$anchor"',
    "arm": "build9_arm_close",
    "flash": '.TaskState=="Completed"',
    "explicit": "build9_queue_close auto",
    "disarm": "build9_disarm_close",
    "terminal": '.Schema=="pocketforge.kit-resume-terminal/v1"',
}
for name, token in need.items():
    if token not in text:
        raise SystemExit(f"BUILD9_CLOSE_GUARD_TEST state=FAIL reason=runbook_{name}_missing")
if not (text.index(need["source"]) < text.index(need["anchor"]) <
        text.index(need["arm"]) < text.index(need["flash"])):
    raise SystemExit("BUILD9_CLOSE_GUARD_TEST state=FAIL reason=runbook_arm_order")
if not (text.index(need["explicit"]) < text.index(need["disarm"]) <
        text.index(need["terminal"])):
    raise SystemExit("BUILD9_CLOSE_GUARD_TEST state=FAIL reason=runbook_disarm_order")
PY

T=$(mktemp -d "${RUNNER_TEMP:-/tmp}/build9-close-guard.XXXXXX")
cleanup() { find "$T" -mindepth 1 -delete; rmdir "$T"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$T/kit" "$T/run/series" "$T/sq" "$T/live"

cat >"$T/kit/runbook-close.sh" <<'SH'
#!/bin/sh
count=0
[ ! -f "$BUILD9_TEST_COUNT" ] || count=$(cat "$BUILD9_TEST_COUNT")
count=$((count + 1))
printf '%s\n' "$count" >"$BUILD9_TEST_COUNT"
if [ "${BUILD9_TEST_FAIL_FIRST:-0}" = 1 ] && [ "$count" = 1 ]; then exit 1; fi
printf '%s\n' "$1" >>"$BUILD9_TEST_LOG"
SH
chmod +x "$T/kit/runbook-close.sh"

run_guard_case() {
    name=$1 action=$2
    log=$T/$name.log count=$T/$name.count
    : >"$log"
    set +e
    BUILD9_TEST_LOG=$log BUILD9_TEST_COUNT=$count \
      kit=$T/kit run=$T/run anchor=$T/run/series/anchor.json \
      live_repo=$T/live SQ_DIR=$T/sq SQ_QUEUE=$T/sq/queue.tsv generation=0123456789abcdef0123456789abcdef \
      bash -c 'set -euo pipefail; source "$1"; build9_arm_close; case "$2" in false) false ;; exit) exit 64 ;; term) kill -TERM $$ ;; success) build9_queue_close auto; build9_disarm_close ;; retry) BUILD9_TEST_FAIL_FIRST=1; export BUILD9_TEST_FAIL_FIRST; build9_queue_close auto; build9_disarm_close ;; esac' \
      _ "$guard" "$action"
    rc=$?
    set -e
    case $action in
      false|exit|term) [ "$rc" -ne 0 ] || die "${name}_lost_failure"; expected=failure ;;
      success) [ "$rc" -eq 0 ] || die "${name}_failed"; expected=auto ;;
      retry) [ "$rc" -ne 0 ] || die "${name}_lost_first_failure"; expected=failure ;;
    esac
    [ "$(wc -l <"$log" | tr -d ' ')" = 1 ] || die "${name}_close_count"
    grep -Fx "$expected" "$log" >/dev/null || die "${name}_close_reason"
}

for stage in anchor initial_flash bootstrap_request bootstrap_queue bootstrap_receipt \
  bootstrap_stdout bootstrap_identity known_hosts network_request network_queue \
  network_receipt network_stdout network_result g2d_request g2d_queue g2d_receipt \
  g2d_stdout g2d_result; do
    run_guard_case "$stage" false
done
run_guard_case explicit_exit exit
run_guard_case signal_term term
run_guard_case explicit_success success
run_guard_case explicit_retry retry

# A pre-open shell that sources but never arms the guard must not queue teardown.
pre_log=$T/pre-open.log
: >"$pre_log"
BUILD9_TEST_LOG=$pre_log BUILD9_TEST_COUNT=$T/pre-open.count \
  kit=$T/kit run=$T/run anchor=$T/run/series/anchor.json \
  live_repo=$T/live SQ_DIR=$T/sq SQ_QUEUE=$T/sq/queue.tsv generation=0123456789abcdef0123456789abcdef \
  bash -c 'set -euo pipefail; source "$1"' _ "$guard"
[ ! -s "$pre_log" ] || die pre_open_close_queued

printf 'BUILD9_CLOSE_GUARD_TEST state=PASS post_open_failures=18 signals=1 explicit_success=1 explicit_retry=1 pre_open=inactive\n'
