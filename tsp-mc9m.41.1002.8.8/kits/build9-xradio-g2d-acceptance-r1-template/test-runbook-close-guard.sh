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
    "arm": "build9_arm_close",
    "boot_open": '"build9-accept-boot-open-$generation"',
    "wait": "build9_wait_for_anchor",
    "flash": '.TaskState=="Completed"',
    "explicit": "build9_queue_close auto",
    "disarm": "build9_disarm_close",
    "terminal": '.Schema=="pocketforge.kit-resume-terminal/v1"',
}
for name, token in need.items():
    if token not in text:
        raise SystemExit(f"BUILD9_CLOSE_GUARD_TEST state=FAIL reason=runbook_{name}_missing")
if not (text.index(need["source"]) < text.index(need["arm"]) <
        text.index(need["boot_open"]) < text.index(need["wait"]) <
        text.index(need["flash"])):
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
    printf '%s\n' '{}' >"$T/run/series/anchor.json"
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

# Enqueue is ambiguous once the boot-open command starts: cleanup must remain
# armed while an asynchronously-produced anchor is still absent.
run_delayed_anchor_case() {
    name=$1 action=$2 expected_rc=$3
    case_dir=$T/$name
    mkdir "$case_dir"
    log=$case_dir/close.log count=$case_dir/close.count
    anchor_path=$case_dir/anchor.json
    : >"$log"
    set +e
    BUILD9_TEST_LOG=$log BUILD9_TEST_COUNT=$count BUILD9_ANCHOR_WAIT_SECONDS=3 \
      kit=$T/kit run=$T/run anchor=$anchor_path \
      live_repo=$T/live SQ_DIR=$T/sq SQ_QUEUE=$T/sq/queue.tsv generation=0123456789abcdef0123456789abcdef \
      bash -c 'set -euo pipefail
        source "$1"
        build9_arm_close
        (sleep 1; printf "%s\n" "{}" >"$anchor") &
        producer=$!
        case "$2" in
          enqueue_nonzero) false ;;
          exit) exit 64 ;;
          term) kill -TERM $$ ;;
          wait) build9_wait_for_anchor; build9_queue_close auto; build9_disarm_close ;;
        esac
        wait "$producer"' _ "$guard" "$action"
    rc=$?
    set -e
    [ "$rc" -eq "$expected_rc" ] || die "${name}_rc_${rc}"
    [ "$(wc -l <"$log" | tr -d ' ')" = 1 ] || die "${name}_close_count"
    if [ "$action" = wait ]; then expected=auto; else expected=failure; fi
    grep -Fx "$expected" "$log" >/dev/null || die "${name}_close_reason"
}

run_delayed_anchor_case enqueue_then_nonzero enqueue_nonzero 1
run_delayed_anchor_case clean_exit_before_anchor exit 64
run_delayed_anchor_case signal_during_anchor_wait term 143
run_delayed_anchor_case normal_delayed_anchor wait 0

# A genuinely absent anchor is bounded and must not fabricate a close row.
timeout_log=$T/anchor-timeout.log
: >"$timeout_log"
set +e
BUILD9_TEST_LOG=$timeout_log BUILD9_TEST_COUNT=$T/anchor-timeout.count BUILD9_ANCHOR_WAIT_SECONDS=1 \
  kit=$T/kit run=$T/run anchor=$T/missing-anchor.json \
  live_repo=$T/live SQ_DIR=$T/sq SQ_QUEUE=$T/sq/queue.tsv generation=0123456789abcdef0123456789abcdef \
  bash -c 'set -euo pipefail; source "$1"; build9_arm_close; build9_wait_for_anchor' \
  _ "$guard" >"$T/anchor-timeout.out" 2>"$T/anchor-timeout.err"
timeout_rc=$?
set -e
[ "$timeout_rc" -ne 0 ] || die anchor_timeout_accepted
[ ! -s "$timeout_log" ] || die anchor_timeout_queued
grep -F 'BUILD9_CLOSE state=FAIL reason=anchor_wait_timeout' "$T/anchor-timeout.err" >/dev/null || \
  die anchor_timeout_not_typed

# A pre-open shell that sources but never arms the guard must not queue teardown.
pre_log=$T/pre-open.log
: >"$pre_log"
BUILD9_TEST_LOG=$pre_log BUILD9_TEST_COUNT=$T/pre-open.count \
  kit=$T/kit run=$T/run anchor=$T/run/series/anchor.json \
  live_repo=$T/live SQ_DIR=$T/sq SQ_QUEUE=$T/sq/queue.tsv generation=0123456789abcdef0123456789abcdef \
  bash -c 'set -euo pipefail; source "$1"' _ "$guard"
[ ! -s "$pre_log" ] || die pre_open_close_queued

# Exercise the real close helper with hermetic transport and queue adapters.
real_kit=$T/real-kit
real_sq=$T/real-sq
mkdir -p "$real_kit" "$real_sq"
cp "$closer" "$K/receipt-tools.sh" "$real_kit/"
cat >"$real_kit/pf-kit-transport.py" <<'PY'
#!/usr/bin/env python3
import os, sys
with open(os.environ["BUILD9_TEST_TEARDOWN_LOG"], "a", encoding="utf-8") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
raise SystemExit(int(os.environ.get("BUILD9_TEST_TEARDOWN_RC", "0")))
PY
cat >"$real_sq/seal-resume-row.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$BUILD9_TEST_SEAL_LOG"
SH
chmod +x "$real_kit/"* "$real_sq/seal-resume-row.sh"
printf '%s\n' '{}' >"$T/anchor.json"

make_close_run() {
    close_run=$1
    mkdir -p "$close_run/series" "$close_run/seed-transport"
    for revision in 000 001 002; do
        printf '%s\n' '{"Outcome":"pass","StepResults":[{"RC":0}]}' >"$close_run/series/revision-$revision.json"
    done
}

seal_log=$T/seal.log teardown_log=$T/teardown.log
: >"$seal_log"; : >"$teardown_log"
success_run=$T/close-success; make_close_run "$success_run"
BUILD9_TEST_SEAL_LOG=$seal_log BUILD9_TEST_TEARDOWN_LOG=$teardown_log \
  "$closer" auto "$real_kit" "$success_run" "$T/anchor.json" "$T/live" \
  "$real_sq" "$T/queue.tsv" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null
jq -e '.Reason=="success"' "$success_run/requests/close.json" >/dev/null || die close_success_reason
[ "$(wc -l <"$seal_log" | tr -d ' ')" = 1 ] || die close_success_queue_count

failure_run=$T/close-failure; make_close_run "$failure_run"
find "$failure_run/series/revision-001.json" -maxdepth 0 -type f -delete
BUILD9_TEST_SEAL_LOG=$seal_log BUILD9_TEST_TEARDOWN_LOG=$teardown_log BUILD9_TEST_TEARDOWN_RC=7 \
  "$closer" auto "$real_kit" "$failure_run" "$T/anchor.json" "$T/live" \
  "$real_sq" "$T/queue.tsv" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb >"$T/failure.out" 2>"$T/failure.err"
jq -e '.Reason=="failure"' "$failure_run/requests/close.json" >/dev/null || die close_missing_receipt_not_failure
grep -F 'reason=teardown_key_failed rc=7 action=continue_to_close' "$T/failure.err" >/dev/null || die teardown_failure_not_typed
[ "$(wc -l <"$seal_log" | tr -d ' ')" = 2 ] || die close_failure_queue_count
[ "$(wc -l <"$teardown_log" | tr -d ' ')" = 2 ] || die teardown_attempt_count

if BUILD9_TEST_SEAL_LOG=$seal_log BUILD9_TEST_TEARDOWN_LOG=$teardown_log \
  "$closer" invalid "$real_kit" "$failure_run" "$T/anchor.json" "$T/live" \
  "$real_sq" "$T/queue.tsv" cccccccccccccccccccccccccccccccc >/dev/null 2>&1; then
    die invalid_close_mode_accepted
fi
[ "$(wc -l <"$seal_log" | tr -d ' ')" = 2 ] || die invalid_mode_queued

printf 'BUILD9_CLOSE_GUARD_TEST state=PASS post_open_failures=18 signals=2 explicit_success=1 explicit_retry=1 pre_open=inactive delayed_anchor=4 anchor_timeout=bounded close_success=1 close_failure=1 teardown_refusal=continued invalid_mode=refused\n'
