#!/usr/bin/env bash
# tsp-mc9m.41.1030.56.4: hermetic tests for window-chain.sh's ONE host-only fill retry. Incident (gen
# 2b59e3da039a574fdfba895fbf7e048d, 2026-10-20T15:08:06Z): fill died once on a transient mirror/worktree race
# (rc=1 reason=driver_pin_materialize_failed), the chain STOPped, and the DUT sat open 29.8 min until a manual
# WINDOW_CHAIN_FROM=fill retry passed. The chain log only kept tail -1 of the fill output, i.e. the wrapper's
# envelope, so the inner reason was lost. Every collaborator here is a stub in a private temp root: no device,
# no runner, no pf-comms, no live services (PF_WINDOW_RUNNER_REPO/GPU14_ROOT/HOME all point into the sandbox).
# Controls: ok (first-fill success never retries) is the positive control; refuse64 and fail-always are negative.
# usage: window-chain-fill-retry-test.sh            rc 0 all pass
set -uo pipefail
BIN=${WQ_BIN_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
WCH=$BIN/window-chain.sh
# A window-chain.sh without the FILL_RETRY seam has no retry to test; refuse before driving it (same convention
# as window-close-auto-test.sh, whose pre-seam run hit the LIVE pf-kit-window-runner.service).
for v in FILL_RETRY GPU14_ROOT PF_WINDOW_RUNNER_REPO WINDOW_CHAIN_FROM; do
  grep -q "$v" "$WCH" || { echo "WINDOW_CHAIN_FILL_RETRY_TEST refused reason=seam_missing seam=$v script=$WCH"; exit 2; }
done
T=$(mktemp -d "${TMPDIR:-/tmp}/wchain-fill-retry.XXXXXX")
cleanup() { [ -n "${KEEP:-}" ] || { find "$T" -mindepth 1 -delete; rmdir "$T"; }; }
trap cleanup EXIT
pass=0; fail=0; N=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
no() { fail=$((fail+1)); echo "FAIL $1 :: ${2:-}"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else no "$name" "$(tail -3 "$S/out" 2>/dev/null | tr '\n' '|')"; fi; }
G=2b59e3da039a574fdfba895fbf7e048d  # the incident generation
OWN=pft-0123456789abcdef01234567
SHA64=$(printf '0123456789abcdef%.0s' 1 2 3 4)

stub() { printf '#!/bin/bash\n%s\n' "$2" > "$1"; chmod +x "$1"; }
setup() {  # fresh sandbox in $S; FAKE_FILL steers the pf-automation-tool stub
  S=$T/s$((++N)); mkdir -p "$S"/{root,bin,clone/.git,clone/scripts/lib,home/.local/state/pocketforge/kit-windows/$G,pkg}
  chmod 700 "$S/pkg"
  printf 'BOOTSTRAP = "canonical"\n' > "$S/clone/scripts/lib/pf_kit_window_prepare.py"
  echo '{"State":"open"}' > "$S/home/.local/state/pocketforge/kit-windows/$G/runner.json"
  echo '{"FelBootRequest":"@STAGE_FROM_SEED_KIT@"}' > "$S/pkg/boot-open-request.template.json"
  printf 'Generation=%s\n' "$G" > "$S/pkg/CAPABILITY-BUNDLE.txt"
  echo '{"Step":{"Command":"canonical"}}' > "$S/pkg/bootstrap-step.template.json"
  stub "$S/root/pf-task-run-home" 'echo "$*" >> "$FAKE_S/runhome.calls"
printf "H=%s/home\nPFT=%s/bin/pft\n" "$FAKE_S" "$FAKE_S"'
  stub "$S/root/window-owner-budget-check.sh" 'echo "OWNER_BUDGET ok owner=$1 steps=$2"; exit 0'
  stub "$S/root/lane-msg.sh" 'echo "$*" >> "$FAKE_S/lanemsg.calls"; echo "LANE_MSG_SENT $3"; exit 0'
  stub "$S/root/window-netready-watch.sh" 'echo "NETREADY_WATCH_REACHED gen=$2"; exit 0'
  stub "$S/bin/pft" 'echo "{\"state\":\"running\"}"'
  # The fill tool. On failure it mimics the real pf-automation-tool merged stream: the INNER typed reason is
  # printed first (by pf_driver_pin__fail), the wrapper envelope reason=driver_pin_materialize_failed LAST --
  # which is exactly what the tail -1 chain log kept, losing the inner cause.
  stub "$S/bin/pf-automation-tool" 'echo "$*" >> "$FAKE_S/tool.calls"
n=$(grep -c . "$FAKE_S/tool.calls")
emit_fail() {
  echo "reason=driver_pin_worktree_add_failed"
  echo "hint=fake git: simulated mirror race"
  echo "reason=driver_pin_materialize_failed driver_sha=25d7c3ace83880748365a6b830e422aaefa727d3"
}
emit_bundle() { printf "AnchorSHA256=%s\nBundleState=filled\n" "$FAKE_SHA64" > "$FAKE_PKG/CAPABILITY-BUNDLE.filled.txt"; }
case "${FAKE_FILL:-ok}" in
  refuse64) echo "PF_KIT_WINDOW_PREPARE_REFUSED reason=filled_bundle_exists generation=$3"; exit 64 ;;
  fail-always) emit_fail; exit 1 ;;
  fail-once) [ "$n" -eq 1 ] && { emit_fail; exit 1; } ;;
  write-then-fail) [ "$n" -eq 1 ] && { emit_bundle; echo "reason=driver_pin_materialize_failed driver_sha=25d7c3ace83880748365a6b830e422aaefa727d3"; exit 1; } ;;
esac
emit_bundle
echo "PF_KIT_WINDOW_FILL state=pass generation=$3 reused_existing=0"
exit 0'
}
# grep -c prints its own 0 on no-match (exit 1); a `|| echo 0` fallback would double it into "0 0".
count_lines() { local c; c=$(grep -c "$@" 2>/dev/null) || c=${c:-0}; printf '%s' "$c"; }
calls() { count_lines . "$S/$1.calls"; }
retries() { count_lines ' FILL_RETRY ' "$S/out"; }
run_chain() {  # $1 = FAKE_FILL mode; always the resume path (window already open, host-only from here on)
  ( export GPU14_ROOT=$S/root PF_WINDOW_RUNNER_REPO=$S/clone HOME=$S/home FAKE_S=$S FAKE_PKG=$S/pkg \
      FAKE_SHA64=$SHA64 FAKE_FILL=$1 WINDOW_CHAIN_FROM=fill PATH="$S/bin:$PATH"
    "$WCH" "$S/pkg" "$G" "$OWN" WCHAIN_STATUS 8 wct ) > "$S/out" 2>&1
}

# --- positive control: a first-attempt fill success changes nothing ------------------------------------------------
setup; run_chain ok; rc=$?
check wcf_ok_rc0 [ "$rc" = 0 ]
check wcf_ok_no_retry [ "$(retries)" = 0 ]
check wcf_ok_fill_called_once [ "$(calls tool)" = 1 ]
check wcf_ok_bundle_sent [ "$(calls lanemsg)" = 1 ]
check wcf_ok_reaches_netready grep -qx "NETREADY_WATCH_REACHED gen=$G" "$S/out"

# --- the incident: one transient failure, then exactly ONE host-only retry that passes ------------------------------
setup; run_chain fail-once; rc=$?
check wcf_retry_rc0 [ "$rc" = 0 ]
check wcf_retry_exactly_once [ "$(retries)" = 1 ]
check wcf_retry_line_inner_reason grep -qE "^[-0-9T:]+Z FILL_RETRY gen=$G first_rc=1 reason=driver_pin_worktree_add_failed$" "$S/out"
check wcf_retry_first_log_keeps_envelope grep -q "CHAIN fill rc=1 reason=driver_pin_materialize_failed" "$S/out"
check wcf_retry_fill_called_twice [ "$(calls tool)" = 2 ]
check wcf_retry_second_fill_passed grep -q "CHAIN fill rc=0 PF_KIT_WINDOW_FILL state=pass generation=$G reused_existing=0" "$S/out"
check wcf_retry_no_stop eval '! grep -q CHAIN_STOP "$S/out"'
check wcf_retry_reaches_netready grep -qx "NETREADY_WATCH_REACHED gen=$G" "$S/out"

# --- negative control: rc 64 is a refusal (e.g. filled_bundle_exists); retrying cannot help -------------------------
setup; run_chain refuse64; rc=$?
check wcf_rc64_rc3 [ "$rc" = 3 ]
check wcf_rc64_no_retry [ "$(retries)" = 0 ]
check wcf_rc64_fill_called_once [ "$(calls tool)" = 1 ]
check wcf_rc64_stop_token grep -q "CHAIN_STOP fill_failed" "$S/out"
check wcf_rc64_no_bundle_sent [ "$(calls lanemsg)" = 0 ]

# --- negative control: a second failure STOPs as today ---------------------------------------------------------------
setup; run_chain fail-always; rc=$?
check wcf_twofail_rc3 [ "$rc" = 3 ]
check wcf_twofail_one_retry_then_stop [ "$(retries)" = 1 ]
check wcf_twofail_fill_called_twice [ "$(calls tool)" = 2 ]
check wcf_twofail_stop_token grep -q "CHAIN_STOP fill_failed" "$S/out"
check wcf_twofail_no_bundle_sent [ "$(calls lanemsg)" = 0 ]

# --- retry reuse semantics: a valid bundle written by the failed attempt is reused, never re-filled ------------------
setup; run_chain write-then-fail; rc=$?
check wcf_reuse_rc0 [ "$rc" = 0 ]
check wcf_reuse_retry_logged [ "$(retries)" = 1 ]
check wcf_reuse_fill_called_once [ "$(calls tool)" = 1 ]
check wcf_reuse_line grep -q "CHAIN fill rc=0 PF_KIT_WINDOW_FILL state=pass reused_existing=1" "$S/out"
check wcf_reuse_reaches_netready grep -qx "NETREADY_WATCH_REACHED gen=$G" "$S/out"

echo "WINDOW_CHAIN_FILL_RETRY_TEST pass=$pass fail=$fail"
[ "$fail" = 0 ] || exit 1
