#!/usr/bin/env bash
# proc-coord 2026-10-16 (tsp-mc9m.41.1030, D4a): hermetic tests for gpu14/kit-preflight.sh and gpu14/window-queue.sh.
# Everything is faked in a private temp root: window-chain, window-close, pf-task-run-home, pf-task, image-path-check,
# runner deploy clone, kit-windows state, build*-publish image. Nothing touches the device, labgrid, runner or pf-task.
# usage: window-queue-test.sh            rc 0 all pass
set -uo pipefail
BIN=${WQ_BIN_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
KP=$BIN/kit-preflight.sh; WQ=$BIN/window-queue.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/wq-tests.XXXXXX"); trap '[ -n "${KEEP:-}" ] || rm -rf -- "$T"' EXIT
pass=0; fail=0; N=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
no() { fail=$((fail+1)); echo "FAIL $1 :: ${2:-}"; }
G1=11111111111111111111111111111111; G2=22222222222222222222222222222222; OWN=pft-aaaaaaaaaaaaaaaaaaaaaaaa
BOOT='echo bootstrap-canonical'

setup() {  # fresh sandbox in $S
  S=$T/s$((++N)); mkdir -p "$S"/{root/fleet-board,kw,clone/scripts/lib,clone/.git,pt,plans}
  export GPU14_ROOT=$S/root PF_KIT_WINDOWS_DIR=$S/kw PF_WINDOW_RUNNER_REPO=$S/clone KP_PUBLISH_ROOT=$S/root \
    KP_RUN_HOME=$S/fake-run-home KP_IMAGE_PATH_CHECK=$S/fake-ipc KP_CHAIN=$S/fake-chain KP_BUDGET=$S/fake-budget \
    KP_PLAN_PREFIX=$S/plans/ KP_DENYLIST=$S/root/image-denylist.txt WQ_PREFLIGHT=$KP WQ_CHAIN=$S/fake-chain WQ_CLOSE=$S/fake-close WQ_POLL_S=0.1 \
    FAKE_S=$S
  unset FAKE_MISSING FAKE_CHAIN_MODE FAKE_FINAL FAKE_STATE PF_WINDOW_IMAGE_PATHS_OK KIT_PREFLIGHT_OVERRIDE_C2 KIT_PREFLIGHT_OVERRIDE_C2deny WQ_WINDOW_MAX_S
  echo '# deny' > "$S/root/image-denylist.txt"
  printf 'BOOTSTRAP = %s\n' "'$BOOT'" > "$S/clone/scripts/lib/pf_kit_window_prepare.py"
  cat > "$S/clone/scripts/pf-kit-step" <<'PY'
import json,sys,re
v=json.load(open(sys.argv[2]))
if not re.fullmatch(r"[0-9a-f]{64}", v.get("AnchorSHA256","")) or v["Step"].get("Type") not in ("dutexec","push-exec","pull","push"):
    print("PF_KIT_STEP_REFUSED reason=request_invalid", file=sys.stderr); sys.exit(2)
print("PF_KIT_STEP_CHECK result=PASS {}")
PY
  head -c 4096 /dev/urandom > "$S/img.raw"; RAWSHA=$(sha256sum < "$S/img.raw" | cut -c1-64)
  mkdir -p "$S/root/build99-publish"; cp "$S/img.raw" "$S/root/build99-publish/Image.img"
  printf '{"RawSHA256":"%s","RawBytes":4096}\n' "$RAWSHA" > "$S/root/build99-publish/ImageSource.json"
  cat > "$S/fake-run-home" <<EOF
#!/bin/sh
[ -f "$S/resolve-refuse" ] && exit 2
echo "H=$S/pt; PFT=$S/fake-pft; PF_TASK_HOST_CONFIG=x; RUN_GENERATION=1; RUN_HOME_REVISION=r; export PF_TASK_HOST_CONFIG"
EOF
  cat > "$S/fake-pft" <<EOF
#!/bin/sh
echo "{\"state\":\"\$(cat $S/owner-state 2>/dev/null || echo awaiting_release)\"}"
EOF
  printf '#!/bin/sh\necho "WINDOW_OWNER_BUDGET result=OK"\n' > "$S/fake-budget"
  cat > "$S/fake-ipc" <<'EOF'
#!/bin/bash
img=$1; shift; miss=()
for p in "$@"; do case ",${FAKE_MISSING:-}," in *",$p,"*) miss+=("$p");; esac; done
m=$(IFS=,; echo "${miss[*]:-}")
[ ${#miss[@]} -eq 0 ] && { echo "IMAGE_PATHS result=PASS image=$img part=x checked=$# missing="; exit 0; }
echo "IMAGE_PATHS result=FAIL image=$img part=x checked=$# missing=$m"; exit 1
EOF
  # Fake window-chain: route check-only mode, else records argv and simulates FAKE_CHAIN_MODE.
  cat > "$S/fake-chain" <<'EOF'
#!/bin/bash
if [ "${PF_WINDOW_CHAIN_OWNER_ROUTE_CHECK_ONLY:-0}" = 1 ]; then
  [ -f "$FAKE_S/route-fail" ] && { echo "CHAIN_STOP owner_sender_registry_unready"; exit 2; }
  echo "WINDOW_CHAIN_OWNER_ROUTE result=PASS run=$3 home=x"; exit 0; fi
printf '%s\n' "$*" >> "$FAKE_S/chain-calls"; echo "paths_ok=${PF_WINDOW_IMAGE_PATHS_OK:-}" >> "$FAKE_S/chain-calls"
G=$2; W=$PF_KIT_WINDOWS_DIR
case "${FAKE_CHAIN_MODE:-ok}" in
  prestop) echo "CHAIN_STOP generation_mismatch"; exit 2 ;;
  bootfail) echo "CHAIN boot-open start"; echo "CHAIN boot-open rc=2"; echo "CHAIN_STOP boot_open_failed"
            echo 'PF_KIT_WINDOW_RUNNER_REFUSED reason=boot_open_failed Detail="PF_KIT_RESUME_REFUSED reason=BASE_BOOT_FAILED"'; exit 2 ;;
  fillfail) mkdir -p "$W/$G"; echo '{"State":"open"}' > "$W/$G/runner.json"; echo "CHAIN boot-open start"; echo "CHAIN boot-open rc=0 x"; echo "CHAIN_STOP fill_failed"; exit 3 ;;
esac
mkdir -p "$W/$G"; echo "CHAIN boot-open start"; echo "CHAIN boot-open rc=0 PF_KIT_WINDOW_RUNNER state=boot-open"; echo "NETREADY_WATCH_SENT host=x gen=$G"
case "${FAKE_FINAL:-}" in
  timeout) echo '{"State":"closed"}' > "$W/$G/runner.json"; echo '{"Reason":"timeout","State":"closed"}' > "$W/$G/terminal.json" ;;
  selfsuccess) echo '{"State":"closed"}' > "$W/$G/runner.json"; echo '{"Reason":"success","State":"closed"}' > "$W/$G/terminal.json" ;;
  noterminal) echo '{"State":"closed"}' > "$W/$G/runner.json" ;;
  failed) echo '{"State":"failed"}' > "$W/$G/runner.json"; echo '{"Reason":"session_result_invalid"}' > "$W/$G/failure.json" ;;
  *) echo '{"State":"open"}' > "$W/$G/runner.json" ;;
esac
case "${FAKE_DONE:-}" in success|failure) printf '%s\t%s\tlane\n' "$FAKE_DONE" now > "$GPU14_ROOT/fleet-board/window-done/$G" ;; bogus) printf 'maybe\n' > "$GPU14_ROOT/fleet-board/window-done/$G" ;; esac
[ -n "${FAKE_PAUSE_DURING:-}" ] && echo "paused by test" > "$GPU14_ROOT/fleet-board/window-queue.pause"
exit 0
EOF
  cat > "$S/fake-close" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_S/close-calls"; W=$PF_KIT_WINDOWS_DIR
echo '{"State":"closed"}' > "$W/$1/runner.json"; echo "{\"Reason\":\"$2\",\"State\":\"closed\"}" > "$W/$1/terminal.json"
echo "WINDOW_CLOSE gen=$1 reason=$2 rc=0 state=closed service=active"
EOF
  chmod +x "$S"/fake-* ; mkdir -p "$S/root/fleet-board/window-done"
}
mkpkg() {  # mkpkg <gen> [plan-entry=run-window.sh]
  local g=$1 entry=${2:-run-window.sh} p=$S/pkg-$1 pl=$S/plans/plan-$1
  mkdir -p "$p/seed-kit" "$pl"; echo '#!/bin/sh' > "$p/STAGE.py"
  printf 'PF_KIT_WINDOW_CAPABILITY v1\nOwnerRun=%s\nGeneration=%s\n' "$OWN" "$g" > "$p/CAPABILITY-BUNDLE.txt"
  printf '{"AnchorSHA256":"@POST_OPEN_ANCHOR_SHA256@","Generation":"%s","Step":{"Command":"%s","Type":"dutexec"}}\n' "$g" "$BOOT" > "$p/bootstrap-step.template.json"
  printf '{"ImageSource":{"RawBytes":4096,"RawSHA256":"%s"},"SeedHandle":"@SEED_HANDLE@"}\n' "$RAWSHA" > "$p/seed-kit/felboot-request.template.json"
  (cd "$p/seed-kit" && sha256sum felboot-request.template.json > SHA256SUMS)
  printf '# op\n\n## referenced plan\n\n`%s`\n' "$pl" > "$p/OPERATOR.md"
  [ "$entry" = none ] || { printf '#!/bin/sh\n/opt/pocketforge/bin/tool --x\n' > "$pl/$entry"; chmod +x "$pl/$entry"; }
  echo "PLAN" > "$pl/PLAN.md"
  [ -n "${PREFLIGHT_DECL:-}" ] && printf '%s\n' "$PREFLIGHT_DECL" > "$p/PREFLIGHT"
  seal "$p"; PKG=$p
}
seal() { (cd "$1" && find . -type f ! -name ARTIFACT-SHA256SUMS -printf '%P\n' | sort | xargs sha256sum > ARTIFACT-SHA256SUMS); chmod 700 "$1"; }
kp() { "$KP" "$PKG" "$1" "$OWN" 2>&1; }
has() { printf '%s\n' "$1" | grep -qE -- "$2"; }
row() { printf '2026-10-16T00:00:00Z\tlane%s\t%s\tLANE_STATUS\t%s\t%s\t3\tlbl%s\tnote %s\n' "$2" "$OWN" "$1" "$2" "$2" "$2"; }

# ---------------- preflight
setup; mkpkg $G1; o=$(kp $G1); rc=$?
[ $rc = 0 ] && has "$o" 'check=C1 result=PASS' && has "$o" 'check=C2 result=PASS' && has "$o" 'check=C3 result=PASS' && has "$o" 'check=C7 result=PASS' && has "$o" 'check=C2deny result=PASS' && has "$o" '^KIT_PREFLIGHT result=PASS failed=-' && ok preflight_all_pass || no preflight_all_pass "$o"
chmod 755 "$PKG"; o=$(kp $G1); has "$o" 'check=C1 result=FAIL.*package_dir_mode' && ok C1_dir_mode || no C1_dir_mode "$o"; chmod 700 "$PKG"
echo tamper >> "$PKG/OPERATOR.md"; o=$(kp $G1); has "$o" 'check=C1 result=FAIL.*artifact_manifest_invalid:OPERATOR.md' && ok C1_manifest || no C1_manifest "$o"
setup; mkpkg $G1; echo '{}' > "$S/kw/boot-open-$G1.json"; o=$(kp $G1); has "$o" 'C1 result=FAIL.*generation_consumed' && ok C1_consumed || no C1_consumed "$o"
setup; mkpkg $G1; printf 'BOOTSTRAP = "other"\n' > "$S/clone/scripts/lib/pf_kit_window_prepare.py"; o=$(kp $G1); has "$o" 'C1 result=FAIL.*bootstrap_not_canonical:stale' && ok C1_bootstrap || no C1_bootstrap "$o"
setup; mkpkg $G1; echo 'IMAGE_PATHS=none' > "$PKG/PREFLIGHT"; o=$(kp $G1); has "$o" 'C1 result=FAIL.*preflight_declarations_unsealed' && ok C1_decl_unsealed || no C1_decl_unsealed "$o"
setup; mkpkg $G1; echo "$RAWSHA build16 battery regression" >> "$S/root/image-denylist.txt"; o=$(KIT_PREFLIGHT_OVERRIDE_C2deny="owner said fine really" kp $G1)
has "$o" 'C2deny result=FAIL.*override_refused=not_overridable' && has "$o" 'result=FAIL failed=C2deny' && ok C2deny_not_overridable || no C2deny_not_overridable "$o"
setup; mkpkg $G1; rm "$S/root/image-denylist.txt"; o=$(kp $G1); has "$o" 'C2deny result=FAIL reason=denylist_unreadable' && ok C2deny_missing_fails_closed || no C2deny_missing_fails_closed "$o"
setup; mkpkg $G1; rm "$S/clone/scripts/pf-kit-step"; o=$(kp $G1); has "$o" 'C3 result=FAIL.*deployed_pf_kit_step_missing' && ok C3_checker_missing_fails_closed || no C3_checker_missing_fails_closed "$o"
# Step-driven kits (no ENTRYPOINT, no referenced plan) need a sealed, complete STEP_DRIVEN=<n> (recovery#14 re-look).
sdpkg() {  # sdpkg <PREFLIGHT lines> <n step files>
  PREFLIGHT_DECL=$1 mkpkg $G1 none; sed -i '/referenced plan/,$d' "$PKG/OPERATOR.md"
  for i in $(seq 1 "$2"); do printf '{"AnchorSHA256":"@A@","Generation":"%s","Step":{"Type":"dutexec","Command":"x"}}\n' $G1 > "$PKG/step$i.json"; done; seal "$PKG"; }
setup; sdpkg '' 0; o=$(kp $G1); has "$o" 'C3 result=FAIL.*entry_unchecked' && ok C3_undeclared_step_driven_fails || no C3_undeclared_step_driven_fails "$o"
setup; sdpkg $'STEP_DRIVEN=2\nSTEP=step1.json' 1; o=$(kp $G1); has "$o" 'C3 result=FAIL.*step_driven_incomplete:STEP_DRIVEN=2 declared_STEP=1' && ok C3_step_driven_partial_fails || no C3_step_driven_partial_fails "$o"
setup; sdpkg $'STEP_DRIVEN=2\nSTEP=step1.json\nSTEP=step2.json' 2; o=$("$KP" "$PKG" $G1 "$OWN" 3 2>&1); has "$o" 'C3 result=FAIL.*step_driven_count_mismatch:STEP_DRIVEN=2 window_steps=3' && ok C3_step_driven_count_mismatch_fails || no C3_step_driven_count_mismatch_fails "$o"
setup; sdpkg $'STEP_DRIVEN=2\nSTEP=step1.json\nSTEP=step2.json' 2; o=$(kp $G1); has "$o" 'C3 result=PASS.*entry=none\(step-driven STEP_DRIVEN=2\).*step_checks=3' && ok C3_step_driven_complete_passes || no C3_step_driven_complete_passes "$o"
setup; mkpkg $G1; o=$(kp $G1); has "$o" 'C8 result=SKIP reason=stagepy_request_not_staged_yet' && ok C8_stagepy_skip_named || no C8_stagepy_skip_named "$o"
setup; mkpkg $G1; rm "$PKG/STAGE.py"; seal "$PKG"; o=$(kp $G1); has "$o" 'C8 result=FAIL reason=no_boot_open_request' && ok C8_native_missing_request_fails || no C8_native_missing_request_fails "$o"
setup; mkpkg $G1; echo 'not json' > "$PKG/boot-open-request.template.json"; seal "$PKG"; o=$(kp $G1); has "$o" 'C8 result=FAIL reason=boot_open_request_unreadable' && ok C8_unreadable_fails || no C8_unreadable_fails "$o"
setup; mkpkg $G1; echo '{"FelBootRequest":"x"}' > "$PKG/boot-open-request.template.json"; seal "$PKG"; o=$(kp $G1); has "$o" 'C8 result=SKIP reason=no_resume_base' && ok C8_no_resume_base_skip || no C8_no_resume_base_skip "$o"
setup; mkpkg $G1; echo '{"BaseKitDirectory":7}' > "$PKG/boot-open-request.template.json"; seal "$PKG"; o=$(kp $G1); has "$o" 'C8 result=FAIL reason=BaseKitDirectory_invalid' && ok C8_bad_base_fails || no C8_bad_base_fails "$o"
setup; mkpkg $G1; rm -rf "$S/root/build99-publish"; o=$(kp $G1); has "$o" 'C2 result=FAIL reason=no_local_image' && ok C2_no_image || no C2_no_image "$o"
o=$(KIT_PREFLIGHT_OVERRIDE_C2="image verified by hand on pf-node" kp $G1); has "$o" 'C2 result=PASS reason=override:no_local_image.*override="image verified by hand on pf-node"' && has "$o" 'result=PASS.*overrides=C2' && ok C2_override_echoed || no C2_override_echoed "$o"
o=$(KIT_PREFLIGHT_OVERRIDE_C2="short" kp $G1); has "$o" 'override_refused=reason_too_short' && ok override_too_short || no override_too_short "$o"
setup; mkpkg $G1; head -c 4096 /dev/zero > "$S/root/build99-publish/Image.img"; o=$(kp $G1); has "$o" 'C2 result=FAIL reason=image_sha256_mismatch' && ok C2_sha_mismatch || no C2_sha_mismatch "$o"
setup; mkpkg $G1 none; printf '#!/bin/sh\necho hi\n' > "$S/plans/plan-$G1/run-x.sh"; chmod +x "$S/plans/plan-$G1/run-x.sh"; o=$(kp $G1); has "$o" 'C2 result=SKIP reason=no_image_paths_in_plan' && has "$o" 'KIT_PREFLIGHT result=PASS' && ok C2_no_paths_skips || no C2_no_paths_skips "$o"
setup; PREFLIGHT_DECL='IMAGE_PATHS=none' mkpkg $G1 none; printf '#!/bin/sh\necho hi\n' > "$S/plans/plan-$G1/run-x.sh"; chmod +x "$S/plans/plan-$G1/run-x.sh"; o=$(kp $G1); has "$o" 'C2 result=PASS.*declared=IMAGE_PATHS=none' && ok C2_checked0_declared || no C2_checked0_declared "$o"
setup; mkpkg $G1; o=$(FAKE_MISSING=/opt/pocketforge/bin/tool kp $G1); has "$o" 'C2 result=FAIL reason=image_paths_missing.*missing=/opt/pocketforge/bin/tool' && ok C2_path_missing || no C2_path_missing "$o"
o=$(FAKE_MISSING=/opt/pocketforge/bin/tool PF_WINDOW_IMAGE_PATHS_OK="prepare creates tool" kp $G1); has "$o" 'C2 result=PASS.*accepted_by=PF_WINDOW_IMAGE_PATHS_OK' && has "$o" 'chain_paths_ok=prepare creates tool' && ok C2_legacy_env || no C2_legacy_env "$o"
setup; PREFLIGHT_DECL='CREATES=/opt/pocketforge/bin/' mkpkg $G1; o=$(FAKE_MISSING=/opt/pocketforge/bin/tool kp $G1); has "$o" 'C2 result=PASS.*exempt_by_CREATES=1' && has "$o" 'chain_paths_ok=kit-preflight' && ok C2_creates_exempt || no C2_creates_exempt "$o"
setup; mkpkg $G1 none; o=$(kp $G1); has "$o" 'C3 result=FAIL reason=plan_has_no_executor' && ok C3_no_executor || no C3_no_executor "$o"
setup; PREFLIGHT_DECL='ENTRYPOINT=bin/missing.sh' mkpkg $G1; o=$(kp $G1); has "$o" 'C3 result=FAIL reason=entrypoint_missing' && ok C3_declared_missing || no C3_declared_missing "$o"
setup; mkpkg $G1; (cd "$S/plans/plan-$G1" && sha256sum PLAN.md > SHA256SUMS); echo x >> "$S/plans/plan-$G1/PLAN.md"; o=$(kp $G1); has "$o" 'C3 result=FAIL.*plan_manifest_invalid' && ok C3_plan_manifest || no C3_plan_manifest "$o"
setup; PREFLIGHT_DECL='STEP=step1.json' mkpkg $G1; printf '{"AnchorSHA256":"@A@","Generation":"%s","Step":{"Type":"bogus"}}\n' $G1 > "$PKG/step1.json"; seal "$PKG"; o=$(kp $G1); has "$o" 'C3 result=FAIL.*step_check_refused:step1.json:reason=request_invalid' && ok C3_step_check || no C3_step_check "$o"
setup; mkpkg $G1; echo released > "$S/owner-state"; o=$(kp $G1); has "$o" 'C7 result=FAIL.*owner_run_not_live:state=released' && ok C7_released || no C7_released "$o"
setup; mkpkg $G1; touch "$S/resolve-refuse" "$S/route-fail"; o=$(kp $G1); has "$o" 'C7 result=FAIL.*owner_run_home_unresolved.*owner_route:owner_sender_registry_unready' && ok C7_unresolved_route || no C7_unresolved_route "$o"
setup; mkpkg $G1; sed -i "s/^OwnerRun=.*/OwnerRun=pft-bbbbbbbbbbbbbbbbbbbbbbbb/" "$PKG/CAPABILITY-BUNDLE.txt"; seal "$PKG"; o=$(kp $G1); has "$o" 'C7 result=FAIL.*owner_mismatch' && ok C7_owner_mismatch || no C7_owner_mismatch "$o"
# Real deployed runner clone (read-only, static): canonical bootstrap + pf-kit-step --check on a copy of a real template.
# Host-only: skipped when either path is absent (e.g. in CI).
RC=${WQ_REAL_CLONE:-/home/matt/recovery/gpu14/deploy-clones/pa-512b2e09}; RP=${WQ_REAL_PKG:-/home/matt/recovery/tsp-op5a.440.9.1/sess-g3-build15-steamlink-fix7-window-ssh}
if { [ -d "$RC/.git" ] || [ -f "$RC/.git" ]; } && [ -f "$RP/bootstrap-step.template.json" ]; then
  setup; mkpkg $G1; jq --arg g $G1 '.Generation=$g' "$RP/bootstrap-step.template.json" > "$PKG/bootstrap-step.template.json"; seal "$PKG"
  before=$(git -C "$RC" status --porcelain --untracked-files=all | wc -l)
  o=$(PF_WINDOW_RUNNER_REPO=$RC kp $G1); after=$(git -C "$RC" status --porcelain --untracked-files=all | wc -l)
  has "$o" 'C1 result=PASS' && has "$o" 'C3 result=PASS.*step_checks=1' && [ "$before" = "$after" ] && ok real_clone_bootstrap_and_step_check || no real_clone_bootstrap_and_step_check "$o dirty $before->$after"
fi

# ---------------- queue
qsetup() { setup; mkpkg $G1; P1=$PKG; mkpkg $G2; P2=$PKG; FB=$S/root/fleet-board; { echo '# header'; row "$P1" 1 | sed "s/\t11*\t3/\t$G1\t3/"; } > /dev/null
  printf '# hdr\n' > "$FB/window-queue.tsv"; printf '2026-10-16T00:00:00Z\tlaneA\t%s\tLANE_STATUS\t%s\t%s\t3\tlblA\tnoteA\n' "$OWN" "$P1" $G1 >> "$FB/window-queue.tsv"
  printf '2026-10-16T00:00:00Z\tlaneB\t%s\tLANE_STATUS\t%s\t%s\t3\tlblB\tnoteB\n' "$OWN" "$P2" $G2 >> "$FB/window-queue.tsv"; }
qsetup; o=$(FAKE_DONE=success "$WQ" --once 2>&1); rc=$?
[ $rc = 0 ] && head -1 "$S/chain-calls" | grep -q "^$P1 $G1 $OWN LANE_STATUS 3 lblA noteA | window-queue:" && grep -q "^$G1 success" "$S/close-calls" && grep -q "$G1.*closed:success" "$FB/window-queue.done.tsv" && grep -q "$G2" "$FB/window-queue.tsv" && ! grep -q "$G1" "$FB/window-queue.tsv" && [ ! -f "$FB/window-queue.active" ] && ok queue_pop_order_chain_args_close_success || no queue_pop_order "$o $(cat "$S/chain-calls")"
qsetup; o=$("$WQ" --dry-run 2>&1); rc=$?
[ $rc = 0 ] && has "$o" 'KIT_PREFLIGHT result=PASS' && has "$o" "WINDOW_QUEUE_DRY chain_cmd=env .*fake-chain $P1 $G1 $OWN LANE_STATUS 3 lblA" && [ ! -f "$S/chain-calls" ] && grep -q "$G1" "$FB/window-queue.tsv" && [ ! -f "$FB/window-queue.active" ] && [ ! -d "$FB/window-queue-logs/$G1-preflight.txt" ] && ok dry_run_no_mutation || no dry_run "$o"
qsetup; touch "$FB/window-queue.pause"; o=$("$WQ" --drain 2>&1); rc=$?; [ $rc = 5 ] && has "$o" paused_at_start && [ ! -f "$S/chain-calls" ] && ok pause_at_start_refused || no pause_at_start "$o"
qsetup; o=$(FAKE_DONE=success FAKE_PAUSE_DURING=1 "$WQ" --drain 2>&1); rc=$?; [ $rc = 0 ] && has "$o" 'reason=paused' && [ "$(grep -c LANE_STATUS "$S/chain-calls")" = 1 ] && grep -q "$G2" "$FB/window-queue.tsv" && ok pause_drains_after_current || no pause_drain "$o"
qsetup; mkdir -p "$S/kw/ffffffffffffffffffffffffffffffff"; echo '{"State":"open"}' > "$S/kw/ffffffffffffffffffffffffffffffff/runner.json"; o=$("$WQ" --drain 2>&1); rc=$?
[ $rc = 5 ] && has "$o" other_window_open && [ ! -f "$S/chain-calls" ] && grep -q "$G1" "$FB/window-queue.tsv" && ok other_window_open_refused || no other_window "$o"
qsetup; o=$(FAKE_FINAL=timeout "$WQ" --once 2>&1); rc=$?; [ $rc = 10 ] && has "$o" 'stop:runner_closed_non_success' && [ ! -f "$S/close-calls" ] && grep -q "runner_closed:timeout" "$FB/window-queue.done.tsv" && [ -f "$FB/window-queue.pause" ] && ok self_closed_timeout_stops || no self_closed_timeout_stops "$o"
qsetup; o=$(FAKE_FINAL=noterminal "$WQ" --once 2>&1); rc=$?; [ $rc = 10 ] && has "$o" 'stop:runner_closed_non_success' && grep -q "runner_closed:unreadable" "$FB/window-queue.done.tsv" && ok self_closed_no_terminal_stops || no self_closed_no_terminal_stops "$o"
qsetup; o=$(FAKE_FINAL=selfsuccess "$WQ" --once 2>&1); rc=$?; [ $rc = 0 ] && grep -q "runner_closed:success" "$FB/window-queue.done.tsv" && [ ! -f "$FB/window-queue.pause" ] && ok self_closed_success_advances || no self_closed_success_advances "$o"
qsetup; o=$(FAKE_FINAL=failed "$WQ" --drain 2>&1); rc=$?; grep -q "^$G1 failure" "$S/close-calls" && grep -q "closed:failure" "$FB/window-queue.done.tsv" && [ $rc = 10 ] && grep -q 'reason=runner_failed' "$FB/window-queue.pause" && [ "$(grep -c LANE_STATUS "$S/chain-calls")" = 1 ] && ok terminal_runner_failed_closes_then_stops || no terminal_failed "$o"
qsetup; o=$("$WQ" --done-from-status "X_STATUS state=WINDOW_DONE gen=$G1 plan=incomplete" 2>&1); [ "$(cut -f1 "$FB/window-done/$G1")" = failure ] && o2=$("$WQ" --done "$G2" complete 2>&1) && [ "$(cut -f1 "$FB/window-done/$G2")" = success ] && ok done_plan_maps_to_close || no done_plan_map "$o $o2"
qsetup; o=$(FAKE_FINAL=failed "$WQ" --drain 2>&1); o2=$("$WQ" --resume 2>&1); r2=$?; o3=$("$WQ" --resume incomplete 2>&1); r3=$?; [ $r2 = 2 ] && [ $r3 = 0 ] && [ ! -f "$FB/window-queue.pause" ] && ls "$FB"/window-queue.pause.resolved-* >/dev/null 2>&1 && has "$("$WQ" --status 2>&1)" 'paused=0' && ok resume_after_stop || no resume_after_stop "$o2 | $o3"
qsetup; o=$("$WQ" --resume complete 2>&1); [ $? = 2 ] && has "$o" not_paused && ok resume_refused_when_not_paused || no resume_not_paused "$o"
qsetup; o=$(FAKE_DONE=bogus "$WQ" --once 2>&1); rc=$?; [ $rc = 10 ] && has "$o" 'stop:marker_invalid' && [ ! -f "$S/close-calls" ] && ok marker_invalid_stops || no marker_invalid "$o"
qsetup; o=$(WQ_WINDOW_MAX_S=1 "$WQ" --once 2>&1); rc=$?; [ $rc = 10 ] && has "$o" 'stop:window_wait_timeout' && ok window_wait_timeout_stops || no wait_timeout "$o"
qsetup; o=$(FAKE_CHAIN_MODE=bootfail "$WQ" --drain 2>&1); rc=$?
[ $rc = 10 ] && has "$o" 'stop:boot_open_failed' && [ -f "$FB/window-queue.pause" ] && grep -q 'BASE_BOOT_FAILED' "$FB/needs/window-queue-stop-$G1.txt" && grep -q "boot_open_failed.BASE_BOOT_FAILED.*$G1" "$FB/window-queue.failed.tsv" && [ ! -f "$S/close-calls" ] && grep -q "$G2" "$FB/window-queue.tsv" && [ "$(grep -c LANE_STATUS "$S/chain-calls")" = 1 ] && ok fel_failure_stops_queue || no fel_failure "$o"
o=$("$WQ" --drain 2>&1); [ $? = 5 ] && ok restart_after_stop_refused || no restart_after_stop "$o"
qsetup; o=$(FAKE_CHAIN_MODE=fillfail "$WQ" --once 2>&1); [ $? = 10 ] && has "$o" 'stop:handoff_failed' && [ ! -f "$S/close-calls" ] && ok handoff_failed_stops_no_close || no handoff_failed "$o"
qsetup; chmod 755 "$P1"; o=$(FAKE_DONE=success "$WQ" --drain 2>&1); rc=$?
[ $rc = 0 ] && [ -f "$FB/needs/window-preflight-$G1.txt" ] && grep -q "preflight.*$G1" "$FB/window-queue.failed.tsv" && ! grep -q "$G1" "$S/chain-calls" && grep -q "$G2" "$S/chain-calls" && ok preflight_fail_skips_row_continues || no preflight_fail "$o"
"$WQ" --has $G1 >/dev/null; [ $? = 3 ] && ok has_reports_needs || no has_needs
qsetup; chmod 755 "$P1"; printf '%s\tC1\tgpu-14 accepts 0755 for this test\n' $G1 > "$FB/window-queue.overrides.tsv"; o=$(FAKE_DONE=success "$WQ" --once 2>&1)
grep -q "check=C1 result=PASS reason=override" "$FB/window-queue-logs/$G1-preflight.txt" && grep -q "$G1" "$S/chain-calls" && ok overrides_tsv_per_gen || no overrides_tsv "$o"
qsetup; o=$(FAKE_CHAIN_MODE=prestop "$WQ" --drain 2>&1); [ $? = 0 ] && grep -q "chain_refused.generation_mismatch" "$FB/window-queue.failed.tsv" && [ -f "$FB/needs/window-chain-$G1.txt" ] && ok chain_prestop_fails_row_continues || no chain_prestop "$o"
qsetup; PREFLIGHT_DECL='CREATES=/opt/pocketforge/bin' mkpkg 33333333333333333333333333333333; printf '# hdr\n' > "$FB/window-queue.tsv"
"$WQ" --add-from-status laneC $OWN LANE_STATUS "\`LANE_STATUS state=HANDBACK reason=BOOT_READY pkg=$PKG gen=33333333333333333333333333333333 steps=4 label=c1 note=first arm only\`" >/dev/null; rc=$?
[ $rc = 11 ] && grep -qP "\tlaneC\t$OWN\tLANE_STATUS\t$PKG\t3{32}\t4\tc1\tfirst arm only$" "$FB/window-queue.tsv" && ok add_from_status_parses || no add_from_status "$rc $(cat "$FB/window-queue.tsv")"
o=$("$WQ" --add laneC $OWN LANE_STATUS "$PKG" 33333333333333333333333333333333 4 c1); [ $? = 2 ] && has "$o" duplicate_generation && ok add_dup_refused || no add_dup "$o"
o=$("$WQ" --add-from-status laneC $OWN LANE_STATUS "LANE_STATUS state=HANDBACK reason=BOOT_READY pkg=$PKG steps=4"); [ $? = 2 ] && has "$o" missing_fields && ok add_missing_fields || no add_missing "$o"
"$WQ" --has 33333333333333333333333333333333; [ $? = 0 ] && ok has_queued || no has_queued
o=$(FAKE_MISSING=/opt/pocketforge/bin/tool FAKE_DONE=success "$WQ" --once 2>&1); grep -q 'paths_ok=kit-preflight 3' "$S/chain-calls" && ok creates_forwarded_to_chain || no creates_forward "$o $(cat "$S/chain-calls")"
setup; FB=$S/root/fleet-board; ( exec 8>>"$FB/.window-queue.run.lock"; flock 8; sleep 3 ) & sleep 0.3; o=$("$WQ" --once 2>&1); [ $? = 5 ] && has "$o" already_running && ok single_instance || no single_instance "$o"; wait

echo "TESTS pass=$pass fail=$fail"; [ "$fail" = 0 ]
