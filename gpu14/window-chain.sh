#!/usr/bin/env bash
# gpu-14 2026-10-14: one generic live-window opener for STAGE.py-format packages (window-2/3b/a67 shape), replacing
# per-window copies (gsw1/gsw2/gsw3b/a67w-chain.sh). Order: OwnerRun message-budget check (window-3b died at seq 2
# with receipt_delivery_failed after gsloc hit 40/40) -> no other open window -> STAGE.py -> boot-open (runner deploy
# clone) -> fill-bundle.sh -> bundle to the OwnerRun -> netready watcher (sends PF_KIT_NETWORK_READY).
# resume: WINDOW_CHAIN_FROM=fill window-chain.sh ... (window already open after boot-open; skips budget-irrelevant stage/boot).
# usage: window-chain.sh <package-dir> <generation> <owner-run> <TOKEN> <step-count> <label> [extra-note]
#   extra-note: one line appended to the bundle message (camera checkpoints, shard rules, ...).
set -uo pipefail
P=${1:?package dir}; G=${2:?generation}; OWNER=${3:?owner run}; TOKEN=${4:?status token}; STEPS=${5:?step count}; LABEL=${6:?label}; NOTE=${7:-}
R=${GPU14_ROOT:-/home/matt/recovery/gpu14}
# The runner deploy clone is whatever the live service runs (a runner redeploy moves it), never a hardcoded path.
D=${PF_WINDOW_RUNNER_REPO:-$(systemctl --user show pf-kit-window-runner.service -p Environment --value | tr ' ' '\n' | sed -n 's/^PF_KIT_AUTOMATION_REPO=//p')}
[ -d "$D/.git" ] || [ -f "$D/.git" ] || { echo "$(date -u +%FT%TZ) CHAIN_STOP runner_clone_unknown D='$D'"; exit 2; }
ts() { date -u +%FT%TZ; }
owner_route() {
  local resolved_home sender_resolver_backed deployed_home expected_home
  resolved_home=$("$R/pf-task-run-home" resolve "$OWNER" --format shell) \
    || { echo "$(ts) CHAIN_STOP owner_run_home_unresolved run=$OWNER"; return 2; }
  eval "$resolved_home"
  # Before redeploy, the v2-only sender may serve v2 owners. Once the deployed
  # sender is resolver-backed, its account registry must agree for every owner.
  sender_resolver_backed=0
  [ -x "$D/scripts/pf-task-run-home" ] && grep -q 'PF_TASK_RUN_HOME_RESOLVER' "$D/scripts/pf-task-send.sh" 2>/dev/null \
    && sender_resolver_backed=1
  if [ "$sender_resolver_backed" = 1 ]; then
    deployed_home=$("$D/scripts/pf-task-run-home" lookup "$OWNER" --format shell 2>/dev/null) \
      || { echo "$(ts) CHAIN_STOP owner_sender_registry_unready run=$OWNER runner=$D"; return 2; }
    expected_home=$H
    eval "$deployed_home"
    [ "$H" = "$expected_home" ] \
      || { echo "$(ts) CHAIN_STOP owner_sender_registry_mismatch run=$OWNER runner=$D expected=$expected_home got=$H"; return 2; }
  elif [ "$H" = /home/matt/.pf-task-v3 ]; then
    echo "$(ts) CHAIN_STOP v3_owner_sender_not_resolver_backed run=$OWNER runner=$D"; return 2
  fi
}
if [ "${PF_WINDOW_CHAIN_OWNER_ROUTE_CHECK_ONLY:-0}" = 1 ]; then
  owner_route || exit $?
  printf 'WINDOW_CHAIN_OWNER_ROUTE result=PASS run=%s home=%s\n' "$OWNER" "$H"
  exit 0
fi
# STAGE.py's sealer (seed-kit/seal-request.py) reseals seed-kit/SHA256SUMS with felboot-request.json, so a package
# ARTIFACT-SHA256SUMS written before staging no longer verifies and PR-B fill-bundle refuses package_manifest_invalid
# (2026-10-14 gamescope-window-4: window open, fill refused). Re-record ONLY that line, and only when the old hash
# equals the new file minus its felboot-request.json line (proof the reseal added nothing else).
reseal_manifest() {
  local A="$P/ARTIFACT-SHA256SUMS" S="$P/seed-kit/SHA256SUMS" old new strip
  [ -f "$A" ] && [ -f "$S" ] && grep -q '  seed-kit/SHA256SUMS$' "$A" || return 0
  (cd "$P" && sha256sum -c --strict --quiet ARTIFACT-SHA256SUMS >/dev/null 2>&1) && return 0
  (cd "$P/seed-kit" && sha256sum -c --strict --quiet SHA256SUMS) || { echo "$(ts) CHAIN_STOP seedkit_inner_manifest_invalid"; return 1; }
  old=$(awk '$2=="seed-kit/SHA256SUMS"{print $1}' "$A"); new=$(sha256sum < "$S" | cut -c1-64)
  strip=$(grep -v '  felboot-request.json$' "$S" | sha256sum | cut -c1-64)
  # 2026-10-15 (gwin batch2 368a2365): seal-request.py's reseal() also DROPS its SEAL_EXCLUDES (HANDOFF.md, queue.tsv),
  # which a packager's own `sha256sum` manifest had listed. Accept that too: old must equal (new minus felboot line) plus
  # the excluded files' CURRENT hashes, C-sorted by name, i.e. those files are unchanged and nothing else moved.
  if [ "$old" != "$strip" ]; then
    local excl
    excl=$( { grep -v '  felboot-request.json$' "$S"; for x in HANDOFF.md queue.tsv; do [ -f "$P/seed-kit/$x" ] && (cd "$P/seed-kit" && sha256sum "$x"); done; } | LC_ALL=C sort -k2 | sha256sum | cut -c1-64)
    if [ "$old" = "$excl" ]; then
      echo "$(ts) CHAIN reseal proven: felboot-request.json added; SEAL_EXCLUDES dropped (unchanged)"
    # 2026-10-15 (batch3a-r c3a95d50): the packager's recorded seed manifest matched neither form, but the kit minus the
    # sealer's felboot-request.json was byte-identical to a template an earlier window already proved and ran on. Accept
    # ONLY that: inner files verified above + strip listed in the proven-template ledger. The felboot request still has to
    # name this window's image (checked by boot-open itself against the request).
    elif cut -f1 /home/matt/recovery/gpu14/proven-seed-manifests.tsv 2>/dev/null | grep -qx "$strip"; then
      echo "$(ts) CHAIN reseal proven via template ledger: strip=$strip ($(awk -F'\t' -v h="$strip" '$1==h{print $2}' /home/matt/recovery/gpu14/proven-seed-manifests.tsv | cut -c1-80)); recorded old=$old not reproducible"
    else
      echo "$(ts) CHAIN_STOP reseal_not_provable old=$old strip=$strip strip_plus_excludes=$excl"; return 1
    fi
  fi
  python3 -c 'import os,sys; a,o,n=sys.argv[1:]; t=open(a).read(); l=o+"  seed-kit/SHA256SUMS\n"; assert t.count(l)==1; m=os.stat(a).st_mode&0o777; open(a+".tmp","w").write(t.replace(l,n+"  seed-kit/SHA256SUMS\n")); os.chmod(a+".tmp",m); os.replace(a+".tmp",a)' "$A" "$old" "$new" || return 1
  (cd "$P" && sha256sum -c --strict --quiet ARTIFACT-SHA256SUMS) || { echo "$(ts) CHAIN_STOP artifact_manifest_invalid_after_reseal"; return 1; }
  echo "$(ts) CHAIN artifact_manifest reseal_recorded seed-kit/SHA256SUMS $old -> $new"
}
T=$(date -u +%Y%m%dT%H%M%SZ)
[[ $G =~ ^[0-9a-f]{32}$ ]] || { echo "$(ts) CHAIN_STOP bad_generation"; exit 2; }
# 2026-10-14: two package formats. STAGE.py (kwin2's lane-SSH packages) and native PR-B (pf-kit-window-prepare: a
# boot-open-request.template.json with FelBootRequest=@STAGE_FROM_SEED_KIT@, e.g. input-coord's guard). For native
# packages the OwnerRun submits every step itself (pf-kit-step refuses a foreign OwnerRun/Lane/CapabilityID); gpu-14
# only stages, boots, fills, runs network-ready and closes. guard-window-run.sh tried to submit for the owner and is retired.
if [ -f "$P/STAGE.py" ]; then FORMAT=stagepy; BOOTREQ=$P/boot-open-request.json
elif jq -e '.FelBootRequest=="@STAGE_FROM_SEED_KIT@"' "$P/boot-open-request.template.json" >/dev/null 2>&1; then FORMAT=native; BOOTREQ=$P/stage/boot-open-request.json
else echo "$(ts) CHAIN_STOP unknown_package_format pkg=$P"; exit 2; fi
echo "$(ts) CHAIN format=$FORMAT"
# 2026-10-15 (panel A2 8776c285): gpu-14 packaged a lane "plan" directory that held only PLAN.md, no executor; the
# window opened (18 min flash) and the lane could only hand back BLOCKED. Before staging, the plan the package references
# must contain a lane-side entry point (run-window.sh / execute-lane-ssh.sh / another run-*.sh that is not a test).
# 2026-10-16 (E1a fix boot 2f94c29c): the first backticked path after the trigger was the IMAGE FILE
# (images/e1a-fix-Image.img), listed before the plan dir, so the chain refused plan_has_no_executor on a valid plan.
# Take the first backticked path after the trigger that is a DIRECTORY; files (images, receipts) are skipped.
PLAN_REF=""
while IFS= read -r _pr; do [ -d "$_pr" ] && { PLAN_REF=$_pr; break; }; done < <(awk '/plan/ && (/referenced/ || /external/ || /never sealed/ || /never-sealed/) {f=1} f {s=$0; while (match(s, /`\/home\/matt\/recovery\/[^`]+`/)) {print substr(s, RSTART+1, RLENGTH-2); s=substr(s, RSTART+RLENGTH)}}' "$P/OPERATOR.md" 2>/dev/null)
# 2026-10-16 (bootpart live proof 977c7946): a Python executor (execute-live-proof.py) was refused as "no executor"; accept
# execute-*.sh / execute-*.py too, never anything named *test*.
# 2026-10-16 (kleaf1 boot-hang 4058796c): a plan whose entry is executor.py (with test_executor.py) was refused; accept executor.py.
if [ -n "$PLAN_REF" ]; then
  ENTRY=$(find "$PLAN_REF" -maxdepth 1 -type f \( -name run-window.sh -o -name execute-lane-ssh.sh -o -name 'run-*.sh' -o -name 'execute-*.sh' -o -name 'execute-*.py' -o -name 'executor.py' \) ! -name '*test*' ! -name 'run-dry-test.sh' ! -name 'run-red-test.sh' ! -name 'run-*test*.sh' 2>/dev/null | head -1)
  [ -n "$ENTRY" ] || { echo "$(ts) CHAIN_STOP plan_has_no_executor plan=$PLAN_REF (only: $(ls "$PLAN_REF" 2>/dev/null | tr '\n' ' '))"; exit 2; }
  echo "$(ts) CHAIN plan_executor ok plan=$PLAN_REF entry=$(basename "$ENTRY")"
else
  echo "$(ts) CHAIN plan_executor unchecked (OPERATOR.md names no referenced plan dir)"
fi
# 2026-10-15 (batch10 15c76b27): 4 GPU arms calling /opt/pocketforge/cts/bin/{glcts,deqp-gles3} were packaged on Build 13,
# a DEFAULT-profile image with no CTS tree; all INSTRUMENT_INVALID after a 20 min flash. Before staging, every
# /opt/pocketforge/... path named by an executable file in the package, its plan, or a lane package the plan references
# must exist in the rootfs of the image the package boots (offline, debugfs). Override only with a stated reason:
# PF_WINDOW_IMAGE_PATHS_OK="<why the missing paths will not be executed>".
# Test harnesses (smoke/test/negative/fixture files, tests/ dirs) are skipped: batch11's smoke.sh names
# /opt/pocketforge/cts/bin/not-present as a deliberate negative control (2026-10-15 false positive).
RAW=$(grep -ohE '"RawSHA256": *"[0-9a-f]{64}"' "$P"/seed-kit/felboot-request*.json 2>/dev/null | head -n1 | grep -oE '[0-9a-f]{64}')
IMG=""
if [ -n "$RAW" ]; then
  for js in /home/matt/recovery/gpu14/build*-publish/ImageSource.json; do
    if grep -q "$RAW" "$js" 2>/dev/null && [ -f "$(dirname "$js")/Image.img" ] && \
       [ "$(stat -c %s "$(dirname "$js")/Image.img")" = "$(jq -r .RawBytes "$js" 2>/dev/null)" ]; then IMG="$(dirname "$js")/Image.img"; break; fi
  done
fi
if [ -z "$IMG" ]; then
  echo "$(ts) CHAIN image_paths unchecked (no local Image.img for raw ${RAW:-unknown}; add its build*-publish dir)"
else
  scan=("$P"); [ -n "${PLAN_REF:-}" ] && scan+=("$PLAN_REF")
  if [ -n "${PLAN_REF:-}" ]; then
    while read -r d; do [ -d "$d" ] && scan+=("$d"); done < <(/usr/bin/grep -rhoE '/home/matt/recovery/tsp-[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' "$PLAN_REF" 2>/dev/null | sort -u)
  fi
  mapfile -t IPATHS < <(find "${scan[@]}" -maxdepth 2 -type f \( -name '*.sh' -o -name '*.py' -o -name 'PACKAGE-ENTRYPOINTS' -o -name 'run-arm*' \) -size -2M \
    ! -iname '*test*' ! -iname '*smoke*' ! -iname '*negative*' ! -iname '*fixture*' ! -path '*/tests/*' -print0 2>/dev/null \
    | xargs -0 /usr/bin/grep -hoE '/opt/pocketforge/[A-Za-z0-9_./+-]+' 2>/dev/null | sed -E 's/[.,/]+$//' | sort -u)
  ipc=$(/home/matt/recovery/gpu14/image-path-check.sh "$IMG" "${IPATHS[@]}"); iprc=$?
  echo "$(ts) CHAIN $ipc"
  if [ $iprc -ne 0 ]; then
    if [ -n "${PF_WINDOW_IMAGE_PATHS_OK:-}" ]; then echo "$(ts) CHAIN image_paths OVERRIDE reason=\"$PF_WINDOW_IMAGE_PATHS_OK\""
    else echo "$(ts) CHAIN_STOP image_paths_missing (the image ${RAW:0:8} lacks paths the window executes; use an image profile that carries them, drop those arms, or set PF_WINDOW_IMAGE_PATHS_OK=<reason>)"; exit 2; fi
  fi
fi
# 2026-10-16 (sessrt 1e8b34d5): kwin4 sealed the package dir 0755; boot-open flashed and booted Build 15, then
# fill refused package_invalid (pf_kit_window_prepare requires the package dir owned by us, mode 0700, no symlink).
# Check it BEFORE any create-once step so a boot is never spent on it.
pmode=$(stat -c '%a %u' "$P" 2>/dev/null); { [ ! -L "$P" ] && [ "$pmode" = "700 $(id -u)" ]; } || { echo "$(ts) CHAIN_STOP package_dir_mode state=\"${pmode:-unreadable}\" (prepare needs 0700, owner $(id -u), not a symlink)"; exit 2; }
# 2026-10-14 (a1-window-5): gpu-14 passed a generation it had never read (only the 906a2b22 prefix was known). The
# create-once STAGE.py staged with the package's own generation, then the chain stopped on the mismatch, so stage
# ran but boot-open never did. Check the argument against the package's declared Generation BEFORE any create-once step.
PKG_G=$(sed -n 's/^Generation=\([0-9a-f]\{32\}\)$/\1/p' "$P/CAPABILITY-BUNDLE.txt" 2>/dev/null | head -1)
[ "$PKG_G" = "$G" ] || { echo "$(ts) CHAIN_STOP generation_mismatch arg=$G package=${PKG_G:-unreadable}"; exit 2; }
# 2026-10-14 (a1-window-5 906a2b22): the package's bootstrap step predated the runner's host-key line, so seq 0 PASSed
# with a one-line marker and the first credentialed step failed credential_host_mismatch (a whole boot spent). The
# bootstrap must be byte-identical to the deployed runner's canonical pf_kit_window_prepare.BOOTSTRAP.
BS=$(cd "$D/scripts/lib" 2>/dev/null && python3 -c 'import json,sys; sys.path.insert(0,"."); import pf_kit_window_prepare as p; c=json.load(open(sys.argv[1]))["Step"]["Command"]; print("match" if c==p.BOOTSTRAP else "stale")' "$P/bootstrap-step.template.json" 2>/dev/null || echo unreadable)
[ "$BS" = match ] || { echo "$(ts) CHAIN_STOP bootstrap_not_canonical state=$BS runner=$D (rebuild the package from the deployed runner's template)"; exit 2; }
# 2026-10-14: a package whose OwnerRun was RELEASED cannot receive receipts (window dies at seq 0, receipt_delivery_failed);
# input-coord's guard package sealed pft-8819 and released it before the window. Refuse before staging.
owner_route || exit $?
owner_state=$(timeout 100 "$PFT" --home "$H" --role coordinator run.status "{\"run_id\":\"$OWNER\"}" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state") or "unknown")' 2>/dev/null || echo unknown)
case "$owner_state" in released|superseded|unknown|"") echo "$(date -u +%FT%TZ) CHAIN_STOP owner_run_not_live run=$OWNER state=$owner_state"; exit 2;; esac
b=$($R/window-owner-budget-check.sh "$OWNER" "$STEPS"); brc=$?; echo "$(ts) CHAIN $b"
[ $brc -eq 0 ] || { echo "$(ts) CHAIN_STOP owner_budget"; exit 2; }
for d in "$HOME"/.local/state/pocketforge/kit-windows/*/; do
  [ "${WINDOW_CHAIN_FROM:-}" = fill ] && [ "$(basename "$d")" = "$G" ] && continue
  s=$(jq -r .State "$d/runner.json" 2>/dev/null); case "$s" in closed|"") ;; *) echo "$(ts) CHAIN_STOP other_window_not_closed $d $s"; exit 2;; esac
done
if [ "${WINDOW_CHAIN_FROM:-}" != fill ]; then
if [ $FORMAT = stagepy ]; then
st=$(cd "$P" && env PATH=/usr/bin:/bin PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 "$P/STAGE.py" 2>&1); src=$?
echo "$(ts) CHAIN stage rc=$src $(printf '%s' "$st" | grep -m1 'PF_KIT_WINDOW_STAGE' | cut -c1-220)"
if [ $src -eq 0 ] && printf '%s' "$st" | grep -q "^PF_KIT_WINDOW_STAGE state=pass generation=$G " && [ -s "$P/SEED-RECEIPT.txt" ] && [ -s "$P/boot-open-request.json" ]; then :
# Resume a STAGE.py package staged by an earlier chain that stopped before boot-open (create-once refuses a re-stage).
elif printf '%s' "$st" | grep -q 'create_once_exists' && grep -q "^Generation=$G$" "$P/SEED-RECEIPT.txt" 2>/dev/null && [ -s "$P/boot-open-request.json" ]; then echo "$(ts) CHAIN stage resume (STAGE.py already staged; SEED-RECEIPT generation matches)"
else echo "$(ts) CHAIN_STOP stage_failed"; printf '%s\n' "$st" | tail -5; exit 2; fi
reseal_manifest || exit 2
else
(cd "$P" && sha256sum -c --strict --quiet ARTIFACT-SHA256SUMS) || { echo "$(ts) CHAIN_STOP package_seal_invalid"; exit 2; }
st=$(pf-automation-tool pf-kit-window-prepare stage "$G" --package-dir "$P" 2>&1); src=$?
echo "$(ts) CHAIN stage rc=$src $(printf '%s' "$st" | grep -m1 -E 'PF_KIT_WINDOW_(STAGE|PREPARE_REFUSED)' | cut -c1-220)"
if [ $src -eq 0 ] && printf '%s' "$st" | grep -qE "^PF_KIT_WINDOW_STAGE state=(pass|staged) generation=$G "; then :
elif printf '%s' "$st" | grep -q 'reason=stage_already_completed' && grep -q "^Generation=$G$" "$P/stage/SEED-RECEIPT.txt" 2>/dev/null; then echo "$(ts) CHAIN stage resume (already staged)"
else echo "$(ts) CHAIN_STOP stage_failed"; printf '%s\n' "$st" | tail -5; exit 2; fi
[ -s "$BOOTREQ" ] || { echo "$(ts) CHAIN_STOP staged_request_missing"; exit 2; }
fi
echo "$(ts) CHAIN boot-open start"
PF_KIT_AUTOMATION_REPO=$D timeout 2700 pf-automation-tool pf-kit-window-runner boot-open --request "$BOOTREQ" > "$P/boot-open-invoke-$T.stdout" 2> "$P/boot-open-invoke-$T.stderr"
rc=$?; echo "$(ts) CHAIN boot-open rc=$rc $(grep -m1 'PF_KIT_WINDOW_RUNNER' "$P/boot-open-invoke-$T.stdout" | cut -c1-200)"
[ $rc -eq 0 ] && grep -q '^PF_KIT_WINDOW_RUNNER state=boot-open checkout=' "$P/boot-open-invoke-$T.stdout" || { echo "$(ts) CHAIN_STOP boot_open_failed"; tail -5 "$P/boot-open-invoke-$T.stderr"; exit 2; }
else
  s=$(jq -r .State "$HOME/.local/state/pocketforge/kit-windows/$G/runner.json" 2>/dev/null)
  [ "$s" = open ] || { echo "$(ts) CHAIN_STOP resume_window_not_open state=$s"; exit 2; }
  reseal_manifest || exit 2
  echo "$(ts) CHAIN resume from fill (window $G open)"
fi
# 2026-10-26 (tsp-mc9m.41.1030.56.4, incident gen 2b59e3da 2026-10-20T15:08:06Z): fill died ONCE on a transient
# mirror/worktree race (rc=1 reason=driver_pin_materialize_failed), this chain STOPped, and the DUT sat open
# 29.8 min until a manual WINDOW_CHAIN_FROM=fill retry passed 59 s later. So: retry the fill step exactly once,
# host-only, with the existing-bundle reuse semantics of WINDOW_CHAIN_FROM=fill (fill is create-once, the bundle
# step is idempotent and touches no DUT). rc 64 is a REFUSAL (e.g. filled_bundle_exists) and is final -- a retry
# cannot help. A second failure stops as before. The FILL_RETRY line records the FIRST reason= token of the
# captured output: the wrapper prints its envelope (reason=driver_pin_materialize_failed) LAST, and the CHAIN
# fill log line keeps only tail -1, which is why the inner cause was lost on 2026-10-20.
FILL_RETRYING=0
fill_once() {  # sets f/frc; reuse beats re-running the create-once fill
  if { [ "${WINDOW_CHAIN_FROM:-}" = fill ] || [ "$FILL_RETRYING" = 1 ]; } && [ -s "$P/CAPABILITY-BUNDLE.filled.txt" ]; then
    f="PF_KIT_WINDOW_FILL state=pass reused_existing=1"; frc=0   # fill is create-once (filled_bundle_exists)
  elif [ $FORMAT = native ]; then f=$(pf-automation-tool pf-kit-window-prepare fill-bundle "$G" --package-dir "$P" 2>&1); frc=$?
  else f=$(cd "$P" && env PATH=/usr/bin:/bin ./fill-bundle.sh 2>&1); frc=$?; fi
  echo "$(ts) CHAIN fill rc=$frc $(printf '%s' "$f" | tail -1 | cut -c1-250)"
}
fill_ok() {
  [ $frc -eq 0 ] && printf '%s' "$f" | grep -qE '^(FILL_OK|PF_KIT_WINDOW_FILL state=pass)' && [ "$(grep -c '@READ_FROM' "$P/CAPABILITY-BUNDLE.filled.txt")" = 0 ]
}
fill_once
if ! fill_ok; then
  if [ $frc -eq 64 ]; then echo "$(ts) CHAIN_STOP fill_failed"; exit 3; fi
  freason=$(printf '%s\n' "$f" | grep -oE 'reason=[A-Za-z0-9_]+' | head -1 | cut -d= -f2)
  echo "$(ts) FILL_RETRY gen=$G first_rc=$frc reason=${freason:-none}"
  FILL_RETRYING=1
  fill_once
  fill_ok || { echo "$(ts) CHAIN_STOP fill_failed"; exit 3; }
fi
M=$R/$LABEL-bundle-msg.txt
{ printf 'gpu-14 -> %s: LIVE WINDOW OPEN, gen %s (%s). Idle limit 3600 s from LastActivity, window 5400 s. Submit the sequence-0 network bootstrap NOW from the template below with the filled bundle values, then END THE TURN (%s state=WINDOW_STEP seq=0).\n- Submit steps through the step inbox only; never run pf-kit-window-prepare. gpu-14 sends PF_KIT_NETWORK_READY after your seq-0 receipt; then submit step 1, and each next step as soon as its receipt arrives (one step per turn, ending WINDOW_STEP seq=<n>).\n' "$LABEL" "$G" "$LABEL" "$TOKEN"
  [ -n "$NOTE" ] && printf -- '- %s\n' "$NOTE"
  printf -- '- A step or shard FAIL never ends the window: pull its evidence, diagnose on the same boot, then continue with the next independent step. Never hand back WINDOW_DONE while steps remain or the window has time; only gpu-14 closes (2026-10-14: a67 ended window b480a035 after one shard FAIL with two shards unrun).\n'
  printf -- '- Every request carries the SAME AnchorSHA256: the bundle AnchorSHA256 line (the window anchor), never a receipt or revision SHA. If pf-kit-step refuses a request (request_invalid, stale_sequence, ...), nothing entered the inbox and the window is fine: fix the request into a NEW file with a fresh RequestID and resubmit the same sequence. Hand back BLOCKED only on a RUNNER refusal (ledger_invalid, window_revoked, window_expired). (2026-10-14: gsloc declared window 7e91c7c8 dead after its own seq-1 AnchorSHA256 error.)\n'
  printf -- '- Never read /sys/kernel/debug/regmap/6100000.mixer-*/registers in full: it resets the A133 (2026-10-14, tsp-98733d6399be82e4f00c.5.4). Read single registers only if a bead asks for them.\n'
  printf -- '- Close is gpu-14s.\n\n===== CAPABILITY-BUNDLE.filled.txt =====\n'; cat "$P/CAPABILITY-BUNDLE.filled.txt"; printf '\n===== bootstrap-step.template.json =====\n'; cat "$P/bootstrap-step.template.json"
  if [ $FORMAT = native ]; then printf '\n(native package: after PF_KIT_NETWORK_READY, submit your later steps yourself from your own templates in %s with `pf-kit-step --request <req> %s`; check each one offline first with `pf-kit-step --check <req>` and NO generation argument)\n' "$P" "$G"; fi; } > "$M"
$R/lane-msg.sh "$OWNER" "$M" "$LABEL-bundle-$G" "$TOKEN" > "$M.out" 2>&1; src=$?; echo "$(ts) CHAIN bundle sent rc=$src $(tail -1 "$M.out" | cut -c1-120)"
[ $src -eq 0 ] || { echo "$(ts) CHAIN_STOP bundle_send_failed"; exit 4; }
echo "$(ts) CHAIN netready watcher"
exec $R/window-netready-watch.sh "$P" "$G" "$OWNER" "$TOKEN"
