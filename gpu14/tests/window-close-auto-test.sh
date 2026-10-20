#!/usr/bin/env bash
# tsp-mc9m.41.1030.56.2: hermetic tests for the queue's one automatic first step after a failed close
# (window-close.sh --auto-first-step and window-queue.sh's AUTO_RECOVERED branch). Every collaborator is a stub in a
# private temp root that returns canned output and never execs a real tool: systemctl, pf-automation-tool, the
# deployed runner, window-disposition.sh, pf-comms, preflight, window-chain. No device, labgrid, runner or pf-comms.
# usage: window-close-auto-test.sh            rc 0 all pass
set -uo pipefail
BIN=${WQ_BIN_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
WC=$BIN/window-close.sh; WQ=$BIN/window-queue.sh
# A window-close.sh without the WC_* seams runs the REAL systemctl and runner against the live service (2026-10-20:
# running this test against the pre-seam script restarted the live pf-kit-window-runner.service). Refuse it.
for v in WC_SYSTEMCTL WC_TOOL WC_RUNNER_ENV WC_AUTO_RUNNER GPU14_ROOT PF_KIT_WINDOWS_DIR; do
  grep -q "$v" "$WC" || { echo "WINDOW_CLOSE_AUTO_TEST refused reason=seam_missing seam=$v script=$WC"; exit 2; }
done
T=$(mktemp -d "${TMPDIR:-/tmp}/wc-auto-tests.XXXXXX")
DRIVER_PID=""
cleanup() { [ -n "$DRIVER_PID" ] && kill "$DRIVER_PID" 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf -- "$T"; }
trap cleanup EXIT
pass=0; fail=0; N=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
no() { fail=$((fail+1)); echo "FAIL $1 :: ${2:-}"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else no "$name" "$(tail -3 "$S/out" 2>/dev/null | tr '\n' '|')"; fi; }
G=7584ec944fa9d748ba8da8efbc13e1af; OWN=pft-0123456789abcdef01234567
REFUSAL='PF_KIT_WINDOW_RUNNER_REFUSED reason=auto_first_step_not_eligible Detail="close_failures_not_staging_only"'

stub() { printf '#!/bin/bash\n%s\n' "$2" > "$1"; chmod +x "$1"; }
setup() {  # fresh sandbox in $S; FAKE_* env steers the stubs
  S=$T/s$((++N)); mkdir -p "$S"/{root/fleet-board,kw/$G,clone/scripts,pkg}
  export GPU14_ROOT=$S/root WQ_BOARD=$S/root/fleet-board PF_KIT_WINDOWS_DIR=$S/kw FAKE_S=$S \
    WC_SYSTEMCTL=$S/systemctl WC_TOOL=$S/tool WC_RUNNER_ENV=$S/runner.env WC_AUTO_RUNNER=$S/auto \
    WQ_PREFLIGHT=$S/preflight WQ_CHAIN=$S/chain WQ_CLOSE=$WC WQ_DISPOSITION=$S/disposition WQ_COMMS=$S/comms \
    WQ_PROBE=$S/probe WQ_OWNER_MODEL=$S/owner-model WQ_POLL_S=0.1 WQ_WINDOW_MAX_S=30
  unset FAKE_CLOSE FAKE_AUTO FAKE_DISP FAKE_COMMS
  echo '{"State":"open"}' > "$S/kw/$G/runner.json"
  printf 'PF_BENCH_DUT_HOST=bench\n' > "$S/runner.env"; printf '%s\n' "$REFUSAL" > "$S/refusal"
  stub "$S/systemctl" 'echo "$*" >> "$FAKE_S/systemctl.calls"
case "$*" in *" show "*) echo "PF_KIT_AUTOMATION_REPO=$FAKE_S/clone PF_KIT_TRUSTED_AUTOMATION_REPOS=$FAKE_S/clone:$FAKE_S/old" ;;
  *is-active*) echo active ;; esac'
  stub "$S/tool" 'echo "$*" >> "$FAKE_S/tool.calls"
case "${FAKE_CLOSE:-teardown_failed}" in
  slow) sleep 2; exit 2 ;;
  ok) echo "{\"State\":\"closed\"}" > "$PF_KIT_WINDOWS_DIR/$3/runner.json"; echo "PF_KIT_WINDOW_RUNNER state=closed generation=$3"; exit 0 ;;
  foreign) echo "PF_KIT_WINDOW_RUNNER_REFUSED reason=foreign_generation" >&2; exit 2 ;;
esac
echo "{\"State\":\"failed\"}" > "$PF_KIT_WINDOWS_DIR/$3/runner.json"
echo "PF_KIT_WINDOW_RUNNER_REFUSED reason=window_close_failed" >&2; exit 2'
  stub "$S/auto" 'printf "%s|repo=%s|trust=%s|key=%s|host=%s\n" "$*" "$PF_KIT_AUTOMATION_REPO" "$PF_KIT_TRUSTED_AUTOMATION_REPOS" "$PF_KIT_DUT_KEY_SECRET" "${PF_BENCH_DUT_HOST:-}" >> "$FAKE_S/auto.calls"
r=$PF_KIT_WINDOWS_DIR/$2/auto-first-step-result.json
case "${FAKE_AUTO:-recovered}" in
  slow) sleep 2; exit 2 ;;
  recovered) echo "{\"State\":\"closed\"}" > "$PF_KIT_WINDOWS_DIR/$2/runner.json"
             echo "PF_KIT_WINDOW_RUNNER state=auto-recovered generation=$2 class=deenergized_staging_unverified receipt=$r existing=0" ;;
  othergen) echo "PF_KIT_WINDOW_RUNNER state=auto-recovered generation=0000 class=x receipt=$r existing=0" ;;
  *) cat "$FAKE_S/refusal" >&2; exit 2 ;;
esac'
  stub "$S/disposition" 'echo "${FAKE_DISP:-RUN}"'
  stub "$S/comms" 'printf "%s\n" "$*" >> "$FAKE_S/comms.calls"; cat >> "$FAKE_S/comms.body"; [ "${FAKE_COMMS:-ok}" = ok ]'
  stub "$S/probe" 'exit 0'
  stub "$S/owner-model" 'echo none'
  stub "$S/preflight" 'echo "KIT_PREFLIGHT result=PASS failed=- gen=$2"'
  stub "$S/chain" 'echo "{\"State\":\"open\"}" > "$PF_KIT_WINDOWS_DIR/$2/runner.json"
echo "CHAIN boot-open start"; echo "CHAIN boot-open rc=0"; echo "NETREADY_WATCH_SENT gen=$2"
printf "failure\tnow\tlane\n" > "$GPU14_ROOT/fleet-board/window-done/$2"'
}
calls() { grep -c . "$S/$1.calls" 2>/dev/null || echo 0; }

# --- window-close.sh -------------------------------------------------------------------------------------------
setup; "$WC" "$G" failure --auto-first-step > "$S/out" 2>&1; rc=$?
check wc_auto_recovered_rc0 [ "$rc" = 0 ]
check wc_auto_recovered_line grep -q "^AUTO_RECOVERED gen=$G class=deenergized_staging_unverified receipt=$S/kw/$G/auto-first-step-result.json existing=0 log=$S/root/close-7584ec94.auto.log$" "$S/out"
check wc_auto_called_once [ "$(calls auto)" = 1 ]
check wc_auto_args_and_env grep -qx "auto-first-step $G --actor window-queue|repo=$S/clone|trust=$S/clone:$S/old|key=kit-window/$G/dut-key|host=bench" "$S/auto.calls"
check wc_auto_inside_stopped_service [ "$(grep -oE 'stop|start' "$S/systemctl.calls" | tr '\n' ' ')" = "stop start " ]

setup; FAKE_AUTO=refused "$WC" "$G" failure --auto-first-step > "$S/out" 2>&1; rc=$?
check wc_auto_refused_rc1 [ "$rc" = 1 ]
check wc_auto_refused_named grep -q 'rc=2 state=unknown service=active clone=clone log=.* auto=reason=auto_first_step_not_eligible:Detail=close_failures_not_staging_only auto_log=' "$S/out"
check wc_auto_refused_no_line eval '! grep -q "^AUTO_RECOVERED" "$S/out"'

setup; FAKE_AUTO=othergen "$WC" "$G" failure --auto-first-step > "$S/out" 2>&1; rc=$?
check wc_auto_foreign_line_not_trusted [ "$rc" = 1 ]

setup; "$WC" "$G" failure > "$S/out" 2>&1; rc=$?
check wc_hand_close_never_auto eval '[ "$rc" = 1 ] && [ "$(calls auto)" = 0 ]'
check wc_hand_close_line_unchanged grep -qE "^WINDOW_CLOSE gen=$G reason=failure rc=2 state=unknown service=active clone=clone log=[^ ]+$" "$S/out"

setup; FAKE_CLOSE=ok "$WC" "$G" success --auto-first-step > "$S/out" 2>&1; rc=$?
check wc_good_close_never_auto eval '[ "$rc" = 0 ] && [ "$(calls auto)" = 0 ]'

setup; echo '{}' > "$S/kw/boot-open-$G.failed.json"; FAKE_CLOSE=foreign "$WC" "$G" failure --auto-first-step > "$S/out" 2>&1
check wc_not_open_never_auto eval 'grep -q result=not_open "$S/out" && [ "$(calls auto)" = 0 ]'

setup; "$WC" "$G" failure --bogus > "$S/out" 2>&1; rc=$?
check wc_bad_flag_refused eval '[ "$rc" = 2 ] && grep -q reason=bad_flag "$S/out" && [ "$(calls tool)" = 0 ]'

for mode in FAKE_CLOSE FAKE_AUTO; do  # a TERM during either operation still restarts the service
  setup; env "$mode=slow" "$WC" "$G" failure --auto-first-step > "$S/out" 2>&1 & wpid=$!
  sleep 0.7; kill -TERM "$wpid"; wait "$wpid"; rc=$?
  check "wc_term_during_${mode}_restarts_service" eval '[ "$rc" = 143 ] && [ "$(grep -oE "stop|start" "$S/systemctl.calls" | tr "\n" " ")" = "stop start " ]'
done

# --- window-queue.sh ---------------------------------------------------------------------------------------------
# refresh_held holds an owner with no live lane-drive.sh; a sleep named like one keeps the test owner unheld.
bash -c "exec -a 'lane-drive.sh $OWN' sleep 600" & DRIVER_PID=$!
# shellcheck disable=SC2034  # qrc and LOG are read inside the eval'd checks
queue_once() {  # one row through the real loop; output in $S/out, rc in $qrc
  printf '%s\tlane\t%s\tTOK\t%s\t%s\t3\tlabel\t\n' "$(date -u +%FT%TZ)" "$OWN" "$S/pkg" "$G" > "$S/root/fleet-board/window-queue.tsv"
  rm -f "$S/kw/$G/runner.json"
  timeout 60 "$WQ" --once > "$S/out" 2>&1; qrc=$?; LOG=$S/root/fleet-board/window-queue.log; }

setup; queue_once
check wq_auto_continues eval '[ "$qrc" = 0 ] && grep -q "WINDOW_QUEUE_EXIT reason=once" "$S/out"'
check wq_auto_logged grep -q "AUTO_RECOVERED gen=$G class=deenergized_staging_unverified receipt=$S/kw/$G/auto-first-step-result.json existing=0$" "$LOG"
check wq_auto_done_outcome_unchanged grep -q "DONE gen=$G outcome=closed:failure$" "$LOG"
check wq_auto_no_pause [ ! -e "$S/root/fleet-board/window-queue.pause" ]
check wq_auto_tsv_row grep -q "$G	lane	label	AUTO_RECOVERED gen=$G class=deenergized_staging_unverified" "$S/root/fleet-board/window-queue.auto-recovered.tsv"
check wq_auto_note_to_proc_coord grep -qx -- "send --from gpu-14 --to proc-coord --topic coord --stdin" "$S/comms.calls"
check wq_auto_note_body grep -q "AUTO_RECOVERED gen=$G class=deenergized_staging_unverified .* lane=lane label=label: the close failed" "$S/comms.body"
check wq_close_gets_flag grep -q "auto-first-step $G --actor window-queue" "$S/auto.calls"

setup; FAKE_DISP=HALT queue_once
check wq_auto_disposition_halt_stops eval '[ "$qrc" = 10 ] && grep -q "STOP reason=close_failed gen=$G .*disposition=HALT after AUTO_RECOVERED" "$LOG"'
check wq_auto_disposition_halt_no_note eval '[ "$(calls comms)" = 0 ] && [ -e "$S/root/fleet-board/window-queue.pause" ]'

setup; FAKE_AUTO=refused queue_once
check wq_refused_stops_unchanged eval '[ "$qrc" = 10 ] && grep -q "STOP reason=close_failed gen=$G window-close rc=1 state=failed: WINDOW_CLOSE .* auto=reason=auto_first_step_not_eligible" "$LOG"'
check wq_refused_no_note eval '[ "$(calls comms)" = 0 ] && ! grep -q AUTO_RECOVERED "$LOG"'

setup; FAKE_COMMS=fail queue_once
check wq_note_failure_does_not_stop eval '[ "$qrc" = 0 ] && grep -q "AUTO_RECOVERED_NOTE_FAILED gen=$G to=proc-coord" "$LOG" && [ ! -e "$S/root/fleet-board/window-queue.pause" ]'

setup; mkdir "$S/root/fleet-board/window-queue.auto-recovered.tsv"; queue_once
check wq_audit_write_failure_stops eval '[ "$qrc" = 10 ] && grep -q "STOP reason=close_failed gen=$G AUTO_RECOVERED .* but its audit write failed" "$LOG" && [ "$(calls comms)" = 0 ]'

O=99999999999999999999999999999999
setup; mkdir -p "$S/kw/$O"; echo '{"State":"failed"}' > "$S/kw/$O/runner.json"; echo '{}' > "$S/kw/$O/safe-acknowledgement.json"
FAKE_DISP=HALT queue_once
check wq_other_window_uses_disposition_seam_halt eval '[ "$qrc" = 5 ] && grep -q "other_window_open window=$O:failed" "$S/out"'
setup; mkdir -p "$S/kw/$O"; echo '{"State":"failed"}' > "$S/kw/$O/runner.json"; echo '{}' > "$S/kw/$O/safe-acknowledgement.json"
queue_once
check wq_other_window_uses_disposition_seam_run eval '[ "$qrc" = 0 ] && grep -q "AUTO_RECOVERED gen=$G" "$LOG"'

echo "WINDOW_CLOSE_AUTO_TEST pass=$pass fail=$fail"
[ "$fail" = 0 ]
