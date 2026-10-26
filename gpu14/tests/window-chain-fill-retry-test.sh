#!/usr/bin/env bash
# tsp-mc9m.41.1030.56.4: hermetic tests for window-chain.sh's ONE host-only fill retry. Incident (gen
# 2b59e3da039a574fdfba895fbf7e048d, 2026-10-20T15:08:06Z): fill died once on a transient mirror/worktree race
# (rc=1 reason=driver_pin_materialize_failed), the chain STOPped, and the DUT sat open 29.8 min until a manual
# WINDOW_CHAIN_FROM=fill retry passed. The chain log only kept tail -1 of the fill output, i.e. the wrapper's
# envelope, so the inner reason was lost. Every collaborator here is a stub in a private temp root: no device,
# no runner, no pf-comms, no live services (PF_WINDOW_RUNNER_REPO/GPU14_ROOT/HOME all point into the sandbox).
# Controls: ok (first-fill success never retries) and write-then-fail (a contract-valid bundle is reused) are
# positive; refuse64, fail-always, truncate-then-fail and wronggen-then-fail are negative. Review r4374271677:
# a reused bundle must be PROVEN complete and bound to this generation; a truncated or foreign-generation
# leftover is refused (FILL_REUSE_REFUSED), the create-once rerun refuses filled_bundle_exists, and the chain
# stops fail-closed instead of sending it.
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
  # Sealed v1 capability template in the exact shape pf_kit_window_prepare.py seals: header, key=value identity
  # lines, the four @READ_FROM marker lines that fill substitutes in place, then the authority prose (21 lines;
  # emit_truncated below drops the last one, which only a length/tail check can see).
  { echo 'PF_KIT_WINDOW_CAPABILITY v1'
    echo 'Bead=tsp-mc9m.41.1030.56.4'
    echo "OwnerRun=$OWN"
    echo 'Lane=wct'
    echo "Generation=$G"
    echo 'Holder=gpu-14'
    echo "CapabilityID=cap-$G"
    echo "AutomationSHA=$SHA64"
    echo 'WindowSeconds=5400'
    echo 'IdleSeconds=3600'
    echo 'KitPurpose=hermetic-test'
    echo 'MaxRenewals=0'
    echo 'MaxTotalSeconds=5400'
    echo "Anchor=$S/home/anchor.json"
    echo 'OpenedAt=@READ_FROM_ANCHOR_OPENED_AT@'
    echo 'Deadline=@READ_FROM_ANCHOR_DEADLINE@'
    echo 'AnchorSHA256=@READ_FROM_ACTIVE_RECORD_AFTER_BOOT_OPEN@'
    echo 'Sequence=@READ_FROM_ACTIVE_RECORD_AFTER_BOOT_OPEN_EXPECT_0@'
    echo ''
    echo 'Authority: submit every step through pf-kit-step with the bundle AnchorSHA256.'
    echo 'Deliver results only to the OwnerRun named above; never reuse another window identity.'
  } > "$S/pkg/CAPABILITY-BUNDLE.txt"
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
fill_from_template() { sed -e "s|^OpenedAt=.*|OpenedAt=2026-10-20T15:00:00Z|" -e "s|^Deadline=.*|Deadline=2026-10-20T16:30:00Z|" -e "s|^AnchorSHA256=.*|AnchorSHA256=$FAKE_SHA64|" -e "s|^Sequence=.*|Sequence=0|" "$FAKE_PKG/CAPABILITY-BUNDLE.txt"; }
emit_bundle() { fill_from_template > "$FAKE_PKG/CAPABILITY-BUNDLE.filled.txt"; }
emit_truncated() { fill_from_template | head -n 20 > "$FAKE_PKG/CAPABILITY-BUNDLE.filled.txt"; }
emit_wronggen() { fill_from_template | sed "s/^Generation=.*/Generation=ffffffffffffffffffffffffffffffff/" > "$FAKE_PKG/CAPABILITY-BUNDLE.filled.txt"; }
refuse_exists() { echo "PF_KIT_WINDOW_PREPARE_REFUSED reason=filled_bundle_exists generation=$1"; exit 64; }
case "${FAKE_FILL:-ok}" in
  refuse64) echo "PF_KIT_WINDOW_PREPARE_REFUSED reason=filled_bundle_exists generation=$3"; exit 64 ;;
  fail-always) emit_fail; exit 1 ;;
  fail-once) [ "$n" -eq 1 ] && { emit_fail; exit 1; } ;;
  truncate-then-fail) [ "$n" -eq 1 ] && { emit_truncated; emit_fail; exit 1; }; refuse_exists "$3" ;;
  wronggen-then-fail) [ "$n" -eq 1 ] && { emit_wronggen; emit_fail; exit 1; }; refuse_exists "$3" ;;
  write-then-fail) [ "$n" -eq 1 ] && { emit_bundle; echo "reason=driver_pin_materialize_failed driver_sha=25d7c3ace83880748365a6b830e422aaefa727d3"; exit 1; } ;;
esac
emit_bundle
echo "PF_KIT_WINDOW_FILL state=pass generation=$3 reused_existing=0"
exit 0'
}
setup_stagepy() {  # same sandbox, STAGE.py format: fill runs ./fill-bundle.sh from the package (no args, PATH=/usr/bin:/bin)
  setup; touch "$S/pkg/STAGE.py"
  stub "$S/pkg/fill-bundle.sh" 'echo "fill-bundle $*" >> "$FAKE_S/fbs.calls"
n=$(grep -c . "$FAKE_S/fbs.calls")
fill_from_template() { sed -e "s|^OpenedAt=.*|OpenedAt=2026-10-20T15:00:00Z|" -e "s|^Deadline=.*|Deadline=2026-10-20T16:30:00Z|" -e "s|^AnchorSHA256=.*|AnchorSHA256=$FAKE_SHA64|" -e "s|^Sequence=.*|Sequence=0|" "$FAKE_PKG/CAPABILITY-BUNDLE.txt"; }
emit_truncated() { fill_from_template | head -n 20 > "$FAKE_PKG/CAPABILITY-BUNDLE.filled.txt"; }
[ "$n" -eq 1 ] && { emit_truncated; echo "reason=fill_bundle_stage_write_failed"; exit 1; }
echo "FILL_REFUSED reason=filled_bundle_exists generation=$FAKE_GEN"; exit 64'
}
# grep -c prints its own 0 on no-match (exit 1); a `|| echo 0` fallback would double it into "0 0".
count_lines() { local c; c=$(grep -c "$@" 2>/dev/null) || c=${c:-0}; printf '%s' "$c"; }
calls() { count_lines . "$S/$1.calls"; }
retries() { count_lines ' FILL_RETRY ' "$S/out"; }
run_chain() {  # $1 = FAKE_FILL mode; always the resume path (window already open, host-only from here on)
  ( export GPU14_ROOT=$S/root PF_WINDOW_RUNNER_REPO=$S/clone HOME=$S/home FAKE_S=$S FAKE_PKG=$S/pkg \
      FAKE_SHA64=$SHA64 FAKE_GEN=$G FAKE_FILL=$1 WINDOW_CHAIN_FROM=fill PATH="$S/bin:$PATH"
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

# --- review r4374271677: a TRUNCATED bundle left by the failed attempt must never be reused or sent ---------------
setup; run_chain truncate-then-fail; rc=$?
check wcf_trunc_rc3 [ "$rc" = 3 ]
check wcf_trunc_one_retry [ "$(retries)" = 1 ]
check wcf_trunc_reuse_refused grep -qE "^[-0-9T:]+Z FILL_REUSE_REFUSED gen=$G reason=bundle_contract_invalid$" "$S/out"
check wcf_trunc_never_reused eval '! grep -q "reused_existing=1" "$S/out"'
check wcf_trunc_rerun_refused64 [ "$(calls tool)" = 2 ]
check wcf_trunc_stop_token grep -q "CHAIN_STOP fill_failed" "$S/out"
check wcf_trunc_no_bundle_sent [ "$(calls lanemsg)" = 0 ]

# --- review r4374271677: a bundle bound to the WRONG generation must never be reused or sent ----------------------
setup; run_chain wronggen-then-fail; rc=$?
check wcf_wronggen_rc3 [ "$rc" = 3 ]
check wcf_wronggen_one_retry [ "$(retries)" = 1 ]
check wcf_wronggen_reuse_refused grep -qE "^[-0-9T:]+Z FILL_REUSE_REFUSED gen=$G reason=bundle_contract_invalid$" "$S/out"
check wcf_wronggen_never_reused eval '! grep -q "reused_existing=1" "$S/out"'
check wcf_wronggen_rerun_refused64 [ "$(calls tool)" = 2 ]
check wcf_wronggen_no_bundle_sent [ "$(calls lanemsg)" = 0 ]

# --- review r4374271677: the unchecked reuse was reachable after STAGE.py fill-bundle.sh failures too -------------
setup_stagepy; run_chain truncate-then-fail; rc=$?
check wcf_stagepy_rc3 [ "$rc" = 3 ]
check wcf_stagepy_one_retry [ "$(retries)" = 1 ]
check wcf_stagepy_reuse_refused grep -qE "^[-0-9T:]+Z FILL_REUSE_REFUSED gen=$G reason=bundle_contract_invalid$" "$S/out"
check wcf_stagepy_never_reused eval '! grep -q "reused_existing=1" "$S/out"'
check wcf_stagepy_rerun_refused64 [ "$(calls fbs)" = 2 ]
check wcf_stagepy_stop_token grep -q "CHAIN_STOP fill_failed" "$S/out"
check wcf_stagepy_no_bundle_sent [ "$(calls lanemsg)" = 0 ]

echo "WINDOW_CHAIN_FILL_RETRY_TEST pass=$pass fail=$fail"
[ "$fail" = 0 ] || exit 1
