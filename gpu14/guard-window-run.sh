#!/usr/bin/env bash
# gpu-14 2026-10-14: run input-coord's tsp-ihne1.56.1 uinput-guard DUT window (native PR-B package, gen 9d89c114)
# end to end inside its 900 s window: stage -> boot-open -> fill-bundle -> seq0 bootstrap -> network-ready ->
# seq1 push-exec (run-guard-window.sh, 150 s) -> seq2 pull (always) -> close (always, once the window is open).
# Physical press: none available (owner away); the script reports physical_control_unavailable by itself.
# Every stage gates on its exact PASS line; output lines are CLOSE-reasoned and quoted in the final GUARD_DONE line.
set -uo pipefail
# RETIRED 2026-10-14T11:4xZ: this script submitted steps for the OwnerRun. pf-kit-step refuses a foreign OwnerRun, Lane or
# CapabilityID, and gpu-14 must never act as the owner run. It also passed a generation to --check, which refuses one,
# and that burned guard window b91918ae. Use window-chain.sh (native format): gpu-14 stages, boots, fills and closes; the owner submits.
echo "GUARD_DONE result=STOP reason=retired_use_window_chain_native"; exit 2
# usage: guard-window-run.sh <generation> <package-dir> <payload-dir>   (defaults: the original 9d89c114 package)
G=${1:-9d89c11498c07d244ceabbfbed00085d}
P=${2:-/home/matt/recovery/input-coord/tsp-ihne1.56.1/uinput-guard-window}
PL=${3:-/home/matt/recovery/input-coord/tsp-ihne1.56.1/dut-window-payload}
R=$(dirname "$P")
[[ $G =~ ^[0-9a-f]{32}$ ]] && [ -d "$P" ] && [ -d "$PL" ] || { echo "GUARD_DONE result=STOP reason=bad_args"; exit 2; }
WD=$HOME/.local/state/pocketforge/kit-windows/$G
OUT=$R/gpu14-run-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$OUT"
D=$(systemctl --user show pf-kit-window-runner.service -p Environment --value | tr ' ' '\n' | sed -n 's/^PF_KIT_AUTOMATION_REPO=//p')
ts() { date -u +%FT%TZ; }
log() { echo "$(ts) GUARD $*" | tee -a "$OUT/run.log"; }
opened=0; verdict=failure
close_window() {
  [ "$opened" = 1 ] || return 0
  log "close start reason=$verdict"
  systemctl --user stop pf-kit-window-runner.service; log "svc stop rc=$?"
  PF_KIT_AUTOMATION_REPO=$D timeout 900 pf-automation-tool pf-kit-window-runner close "$G" --reason "$verdict" > "$OUT/close.out" 2>&1
  log "close rc=$? $(grep -m1 'PF_KIT_WINDOW_RUNNER' "$OUT/close.out" | cut -c1-160)"
  systemctl --user start pf-kit-window-runner.service; log "svc start rc=$?"
  opened=0
}
die() { log "STOP $*"; close_window; echo "$(ts) GUARD_DONE result=STOP reason=$* out=$OUT"; exit 2; }
trap 'close_window' EXIT
[ -d "$D" ] || die runner_clone_unknown
for d in "$HOME"/.local/state/pocketforge/kit-windows/*/; do
  s=$(jq -r .State "$d/runner.json" 2>/dev/null); case "$s" in closed|"") ;; *) die "other_window_not_closed:$d:$s";; esac
done
(cd "$P" && sha256sum -c --strict --quiet ARTIFACT-SHA256SUMS) || die package_seal_invalid
OWNER=$(jq -r ".FelBootRequest.OwnerRun // .OwnerRun // empty" "$P/boot-open-request.template.json" 2>/dev/null); [ -n "$OWNER" ] || OWNER=$(sed -n "s/^OwnerRun=//p" "$P/CAPABILITY-BUNDLE.txt" | head -1)
[[ $OWNER =~ ^pft-[0-9a-f]{24}$ ]] || die owner_run_unreadable
# 2026-10-14: a package whose OwnerRun was RELEASED cannot receive receipts (window dies at seq 0, receipt_delivery_failed);
# input-coord's guard package sealed pft-8819 and released it before the window. Refuse before staging.
owner_state=$(PF_TASK_HOST_CONFIG=/home/matt/.config/pocketforge/pf-task-host.json timeout 100 /home/matt/.pf-task-v2/bin/pf-task --home /home/matt/.pf-task-v2 --role coordinator run.status "{\"run_id\":\"$OWNER\"}" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state") or "unknown")' 2>/dev/null || echo unknown)
case "$owner_state" in released|superseded|unknown|"") die "owner_run_not_live run=$OWNER state=$owner_state";; esac

(cd "$PL" && sha256sum -c --strict --quiet SHA256SUMS) || die payload_seal_invalid
# 1 stage
# 2026-10-14: the native PR-B tool prints `PF_KIT_WINDOW_STAGE state=staged` (STAGE.py prints state=pass); stage is
# create-once, so a rerun after a later-step stop sees stage_already_completed and resumes from the staged request.
pf-automation-tool pf-kit-window-prepare stage "$G" --package-dir "$P" > "$OUT/stage.out" 2>&1; rc=$?
if grep -qE '^PF_KIT_WINDOW_STAGE state=(pass|staged) generation='"$G"' ' "$OUT/stage.out" && [ $rc -eq 0 ]; then
  log "stage pass ($(grep -m1 -oE 'state=(pass|staged)' "$OUT/stage.out"))"
elif grep -q 'reason=stage_already_completed' "$OUT/stage.out" && [ -s "$P/stage/boot-open-request.json" ] && grep -q "^Generation=$G$" "$P/stage/SEED-RECEIPT.txt" 2>/dev/null; then
  log "stage resume: already staged (SEED-RECEIPT generation matches)"
else
  die "stage_failed rc=$rc"
fi
# 2 boot-open
PF_KIT_AUTOMATION_REPO=$D timeout 2700 pf-automation-tool pf-kit-window-runner boot-open --request "$P/stage/boot-open-request.json" > "$OUT/boot-open.out" 2> "$OUT/boot-open.err"; rc=$?
grep -q '^PF_KIT_WINDOW_RUNNER state=boot-open checkout=' "$OUT/boot-open.out" && [ $rc -eq 0 ] || die "boot_open_failed rc=$rc"
opened=1; log "boot-open pass"
# 3 fill
pf-automation-tool pf-kit-window-prepare fill-bundle "$G" --package-dir "$P" > "$OUT/fill.out" 2>&1; rc=$?
grep -q '^PF_KIT_WINDOW_FILL state=pass' "$OUT/fill.out" && [ $rc -eq 0 ] || die "fill_failed rc=$rc"
FB=$(sed -n 's/.* output=\([^ ]*\).*/\1/p' "$OUT/fill.out" | head -1); [ -s "$FB" ] || FB=$P/CAPABILITY-BUNDLE.filled.txt
A=$(sed -n 's/^AnchorSHA256=\([0-9a-f]\{64\}\)$/\1/p' "$FB" | head -1)
[[ $A =~ ^[0-9a-f]{64}$ ]] || die anchor_missing
log "fill pass anchor=$A"
submit() {  # submit <seq> <json-file>; waits for receipt; prints Outcome
  local n=$1 f=$2 t0 rcp
  pf-automation-tool pf-kit-step --check "$f" "$G" > "$OUT/seq$n.check" 2>&1 || { log "seq$n check refused: $(tail -1 "$OUT/seq$n.check" | cut -c1-200)"; return 3; }
  pf-automation-tool pf-kit-step --request "$f" "$G" > "$OUT/seq$n.submit" 2>&1 || { log "seq$n submit refused: $(tail -1 "$OUT/seq$n.submit" | cut -c1-200)"; return 3; }
  t0=$(date +%s)
  while :; do
    rcp=$(ls "$WD"/receipts/receipt-$(printf '%06d' "$n")-*.json 2>/dev/null | head -1)
    [ -n "$rcp" ] && break
    s=$(jq -r .State "$WD/runner.json" 2>/dev/null); case "$s" in failed|closed) log "seq$n window state=$s"; return 4;; esac
    [ $(( $(date +%s) - t0 )) -gt 400 ] && { log "seq$n receipt timeout"; return 5; }
    sleep 3
  done
  cp "$rcp" "$OUT/"; log "seq$n receipt=$(basename "$rcp") outcome=$(jq -r '.Outcome // empty' "$rcp") sha256=$(sha256sum < "$rcp" | cut -c1-64)"
  return 0
}
rid() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
# 4 seq0 bootstrap
jq --arg a "$A" --arg r "$(rid)" '.AnchorSHA256=$a | .RequestID=$r' "$P/bootstrap-step.template.json" > "$OUT/seq0.json" || die seq0_build
submit 0 "$OUT/seq0.json" || die "seq0_failed"
out0=$P/series/revision-000-step-000.stdout
pass=$(tr -d '\r' < "$out0" 2>/dev/null | grep -E '^PF_KIT_NETWORK_BOOTSTRAP state=PASS host=192\.168\.86\.[0-9]{1,3} ')
host=${pass#*host=}; host=${host%% *}
[[ $host =~ ^192\.168\.86\.[0-9]{1,3}$ ]] || die "bootstrap_host_missing"
log "bootstrap host=$host"
# 5 network-ready (PR-B prints the PASS line; verify by realpath + sha like window-netready-watch.sh)
pf-automation-tool pf-kit-window-prepare network-ready "$G" --package-dir "$P" --host-from-receipt "$P/series/revision-000.json" > "$OUT/netready.out" 2>&1; rc=$?
pl=$(grep -E "^PF_KIT_NETWORK_READY state=pass host=$host generation=$G " "$OUT/netready.out" | tail -1)
[ -n "$pl" ] || die "netready_failed rc=$rc"
log "network-ready pass rc=$rc"
# 6 seq1 push-exec
files=$(for n in pf-input-decode pf-input-broker pf-input-read pf-uinput-domain-probe run-guard-window.sh; do jq -n --arg n "$n" --arg s "$PL/$n" '{Name:$n, Source:$s}'; done | jq -s .)
jq --arg a "$A" --arg r "$(rid)" --argjson f "$files" '.AnchorSHA256=$a | .RequestID=$r | .Sequence=1 | .Step.Command="/bin/bash /run/pf-iter/1/run-guard-window.sh /run/pf-iter/1" | .Step.Files=$f | .Step.TargetPaths=["/run/pf-uinput-guard"] | .Step.TimeoutSeconds=150' "$P/push-exec-step.template.json" > "$OUT/seq1.json" || die seq1_build
submit 1 "$OUT/seq1.json"; s1=$?
log "seq1 rc=$s1 (physical press: none available -> physical_control_unavailable expected)"
# 7 seq2 pull (always)
pfiles=$(for n in receipt.tsv decode.stdout decode.stderr broker.stdout broker.stderr physical-event.stdout physical-event.stderr negative.stdout negative.stderr devices-before-negative.txt devices-after-negative.txt; do jq -n --arg n "$n" --arg p "/run/pf-uinput-guard/$n" '{Name:$n, RemotePath:$p}'; done | jq -s .)
jq --arg a "$A" --arg r "$(rid)" --argjson f "$pfiles" '.AnchorSHA256=$a | .RequestID=$r | .Sequence=2 | .Step.Files=$f' "$P/pull-step.template.json" > "$OUT/seq2.json" || die seq2_build
submit 2 "$OUT/seq2.json"; s2=$?
log "seq2 rc=$s2"
[ $s1 -eq 0 ] && [ $s2 -eq 0 ] && verdict=success
close_window
echo "$(ts) GUARD_DONE result=RAN seq1_rc=$s1 seq2_rc=$s2 close_reason=$verdict out=$OUT"
