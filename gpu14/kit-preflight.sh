#!/usr/bin/env bash
# proc-coord 2026-10-16 (tsp-mc9m.41.1030; owner decision D4a "always-on window queue"): one static gate a sealed kit
# package must pass before window-queue.sh hands it to window-chain.sh. Report F (F-device-windows.md) counted 27 wasted
# windows (15.3 bench-h) in the kit-window era; about a third were package faults that a static look at the staged
# package would have caught BEFORE the 18-20 min flash (906a2b22 stale bootstrap, 15c76b27 wrong profile, 8776c285 plan
# without executor, 1e8b34d5 dir 0755, 6c30f32b/80401167 owner budget, pft-8819 released owner). This is v1 of the F
# proposal: C1 seal, C2 image (+ C2deny), C3 entrypoints, C7 owner. C4 rootfs rehearsal, C5 ABI, C6 arm order, C8 bench
# contract and C9 prediction are NOT here yet (gpu-14 keeps the lockup-last/Build-16/prediction judgement by hand).
#
# Everything here is read-only: no stage, no seed handle, no node, no device, no runner state. Network/pf-task reads are
# the same read-only probes window-chain.sh already makes (pf-task-run-home resolve, run.status, the chain's own
# PF_WINDOW_CHAIN_OWNER_ROUTE_CHECK_ONLY mode). It never edits the package (python runs with -B: no __pycache__).
#
# usage: kit-preflight.sh <package-dir> <generation> <owner-run> [step-count]
#   step-count: when given, window-owner-budget-check.sh runs too (v2 homes; v3 prints NOT_APPLICABLE).
# out: one line per check `KIT_PREFLIGHT check=<id> result=PASS|FAIL|SKIP reason=...`, optionally
#      `KIT_PREFLIGHT chain_paths_ok=<text>` (window-queue passes it to window-chain as PF_WINDOW_IMAGE_PATHS_OK), then
#      `KIT_PREFLIGHT result=PASS|FAIL failed=<ids|-> gen=<gen> image=<raw8> overrides=<ids|-> paths_exempt=<n>`.
# rc: 0 PASS, 1 FAIL, 2 usage.
#
# Overrides: per check only, KIT_PREFLIGHT_OVERRIDE_<id>="<reason, >=10 chars>" (ids C1 C2 C3 C7 C8). The reason is echoed
# into that check's line and the summary. C2deny (the image denylist, e.g. Build 16) is never overridable. There is no
# global override.
#
# Package declarations (optional file <pkg>/PREFLIGHT, KEY=value lines, '#' comments; it must be listed in the package's
# ARTIFACT-SHA256SUMS so it cannot change after sealing):
#   ENTRYPOINT=<path>      the lane-side executor (absolute, or relative to the package). Replaces window-chain's
#                          OPERATOR.md/run-*.sh guessing, which refused 3 valid plans (e1afix, bootpart, kleaf1).
#   CREATES=<abs path>     a /opt/pocketforge path the package's prepare step creates on the DUT; it and everything
#                          below it are exempt from the image-path check (sessfix7 needed PF_WINDOW_IMAGE_PATHS_OK twice).
#   IMAGE_PATHS=none       the window executes no /opt/pocketforge path, so checked=0 is a real PASS (7 of 9 image
#                          PASS lines on 10-16 were a vacuous checked=0).
#   IMAGE=<path>           a local raw image to verify against RawSHA256 when it is not package-local or in build*-publish.
#   STEP=<path>            a pre-built step request (relative to the package) to run through the deployed
#                          `pf-kit-step --check` (pure static: no generation argument, no window state; read 2026-10-16).
#
# Test seams: GPU14_ROOT, PF_KIT_WINDOWS_DIR, PF_WINDOW_RUNNER_REPO, KP_RUN_HOME, KP_IMAGE_PATH_CHECK, KP_CHAIN, KP_BUDGET,
# KP_DENYLIST, KP_PUBLISH_ROOT, KP_PLAN_PREFIX (default /home/matt/recovery/, the chain's plan-path prefix).
set -uo pipefail
unset -f grep 2>/dev/null || true
P=${1:-}; G=${2:-}; OWNER=${3:-}; STEPS=${4:-}
[ -n "$P" ] && [ -n "$G" ] && [ -n "$OWNER" ] || { echo "KIT_PREFLIGHT result=ERROR reason=usage hint=kit-preflight.sh <package-dir> <generation> <owner-run> [step-count]"; exit 2; }
P=${P%/}
R=${GPU14_ROOT:-/home/matt/recovery/gpu14}
WIN=${PF_KIT_WINDOWS_DIR:-$HOME/.local/state/pocketforge/kit-windows}
RUN_HOME=${KP_RUN_HOME:-$R/pf-task-run-home}
IPC=${KP_IMAGE_PATH_CHECK:-$R/image-path-check.sh}
CHAIN=${KP_CHAIN:-$R/window-chain.sh}
BUDGET=${KP_BUDGET:-$R/window-owner-budget-check.sh}
DENY=${KP_DENYLIST:-$R/image-denylist.txt}
PUB=${KP_PUBLISH_ROOT:-$R}
FAILED=(); OVERRIDES=(); RAW=""; PATHS_EXEMPT=0; CHAIN_PATHS_OK=""
clean() { printf '%s' "$1" | tr -d '\r\n"' | tr '\t' ' ' | cut -c1-300; }
emit() {  # emit <id> <PASS|FAIL|SKIP> <reason>
  local id=$1 res=$2 why=$3 var="KIT_PREFLIGHT_OVERRIDE_$1" ov
  ov=${!var:-}
  if [ "$res" = FAIL ] && [ -n "$ov" ]; then
    if [ "$id" = C2deny ]; then why="$why override_refused=not_overridable"
    elif [ "${#ov}" -lt 10 ]; then why="$why override_refused=reason_too_short"
    else
      echo "KIT_PREFLIGHT check=$id result=PASS reason=override:$why override=\"$(clean "$ov")\""
      OVERRIDES+=("$id"); return 0
    fi
  fi
  echo "KIT_PREFLIGHT check=$id result=$res reason=$why"
  [ "$res" = FAIL ] && FAILED+=("$id")
  return 0
}
join() { local IFS=,; echo "${*:-}"; }
decl() { [ -f "$P/PREFLIGHT" ] && sed -n "s/^$1=//p" "$P/PREFLIGHT" | tr -d '\r'; }
# The runner deploy clone the live service runs (same resolution as window-chain.sh; read-only `systemctl show`).
D=${PF_WINDOW_RUNNER_REPO:-$(systemctl --user show pf-kit-window-runner.service -p Environment --value 2>/dev/null | tr ' ' '\n' | sed -n 's/^PF_KIT_AUTOMATION_REPO=//p')}

# ---------------------------------------------------------------- C1 seal
C1_MANIFEST_OK=0
c1() {
  local why=() mode pkg_g fmt bs listed
  if [ ! -d "$P" ] || [ -L "$P" ]; then emit C1 FAIL "package_dir_missing_or_symlink pkg=$P"; return; fi
  [[ $G =~ ^[0-9a-f]{32}$ ]] || why+=("bad_generation")
  # 2026-10-16 (sessrt 1e8b34d5): a 0755 package flashed a whole boot before fill refused package_invalid.
  mode=$(stat -c '%a %u' "$P" 2>/dev/null)
  [ "$mode" = "700 $(id -u)" ] || why+=("package_dir_mode:${mode// /_}")
  # 2026-10-14 (a1-window-5): a generation that was never read against the package (906a2b22 prefix only).
  pkg_g=$(sed -n 's/^Generation=\([0-9a-f]\{32\}\)$/\1/p' "$P/CAPABILITY-BUNDLE.txt" 2>/dev/null | head -1)
  [ "$pkg_g" = "$G" ] || why+=("generation_mismatch:package=${pkg_g:-unreadable}")
  # Write-once per generation (gpu-14 2026-10-16 D4a answer 1): a retry is a NEW package and generation, so any runner
  # record for this generation means it was already consumed.
  if [ -e "$WIN/$G" ] || [ -e "$WIN/boot-open-$G.json" ] || [ -e "$WIN/boot-open-$G.failed.json" ]; then
    why+=("generation_consumed")
  fi
  if [ -f "$P/STAGE.py" ]; then fmt=stagepy
  elif jq -e '.FelBootRequest=="@STAGE_FROM_SEED_KIT@"' "$P/boot-open-request.template.json" >/dev/null 2>&1; then fmt=native
  else fmt=unknown; why+=("unknown_package_format"); fi
  if [ ! -f "$P/ARTIFACT-SHA256SUMS" ]; then why+=("artifact_manifest_missing")
  elif (cd "$P" && sha256sum -c --strict --quiet ARTIFACT-SHA256SUMS >/dev/null 2>&1); then C1_MANIFEST_OK=1
  else why+=("artifact_manifest_invalid:$(cd "$P" && sha256sum -c --strict ARTIFACT-SHA256SUMS 2>&1 | sed -n 's/: FAILED.*$//p; s/^sha256sum: \(.*\): No such file.*/\1(missing)/p' | head -3 | tr '\n' ',' | sed 's/,$//')")
  fi
  if [ -f "$P/seed-kit/SHA256SUMS" ]; then
    (cd "$P/seed-kit" && sha256sum -c --strict --quiet SHA256SUMS >/dev/null 2>&1) || why+=("seedkit_manifest_invalid")
  fi
  if [ -f "$P/PREFLIGHT" ]; then
    listed=$(awk '$2=="PREFLIGHT" || $2=="*PREFLIGHT" {print "y"; exit}' "$P/ARTIFACT-SHA256SUMS" 2>/dev/null)
    [ "$listed" = y ] || why+=("preflight_declarations_unsealed")
  fi
  # 2026-10-14 (a1-window-5 906a2b22): the bootstrap must be byte-identical to the deployed runner's canonical
  # pf_kit_window_prepare.BOOTSTRAP (the comparison window-chain.sh makes; -B so the deploy clone stays clean).
  if [ -z "$D" ] || { [ ! -d "$D/.git" ] && [ ! -f "$D/.git" ]; }; then why+=("runner_clone_unknown")
  else
    bs=$(cd "$D/scripts/lib" 2>/dev/null && PYTHONDONTWRITEBYTECODE=1 python3 -B -c 'import json,sys; sys.path.insert(0,"."); import pf_kit_window_prepare as p; c=json.load(open(sys.argv[1]))["Step"]["Command"]; print("match" if c==p.BOOTSTRAP else "stale")' "$P/bootstrap-step.template.json" 2>/dev/null || echo unreadable)
    [ "$bs" = match ] || why+=("bootstrap_not_canonical:$bs")
  fi
  if [ ${#why[@]} -eq 0 ]; then emit C1 PASS "sealed format=$fmt manifest=verified mode=700 generation=$G"
  else emit C1 FAIL "$(join "${why[@]}") format=$fmt"; fi
}

# ---------------------------------------------------------------- shared: plan reference + scan set (window-chain.sh)
# Copied from window-chain.sh @ 2026-10-16 so the preflight's image-path set is exactly the set the chain checks: the
# first backticked /home/matt/recovery DIRECTORY after an OPERATOR.md "plan ... referenced/external/never sealed" line.
PLAN_REF=""
while IFS= read -r _pr; do [ -d "$_pr" ] && { PLAN_REF=$_pr; break; }; done < <(awk -v pre="${KP_PLAN_PREFIX:-/home/matt/recovery/}" '/plan/ && (/referenced/ || /external/ || /never sealed/ || /never-sealed/) {f=1} f {s=$0; while (match(s, /`[^`]+`/)) {t=substr(s, RSTART+1, RLENGTH-2); if (index(t, pre)==1) print t; s=substr(s, RSTART+RLENGTH)}}' "$P/OPERATOR.md" 2>/dev/null)
image_scan_paths() {
  local scan=("$P") d
  [ -n "$PLAN_REF" ] && scan+=("$PLAN_REF")
  if [ -n "$PLAN_REF" ]; then
    while read -r d; do [ -d "$d" ] && scan+=("$d"); done < <(grep -rhoE '/home/matt/recovery/tsp-[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' "$PLAN_REF" 2>/dev/null | sort -u)
  fi
  find "${scan[@]}" -maxdepth 2 -type f \( -name '*.sh' -o -name '*.py' -o -name 'PACKAGE-ENTRYPOINTS' -o -name 'run-arm*' \) -size -2M \
    ! -iname '*test*' ! -iname '*smoke*' ! -iname '*negative*' ! -iname '*fixture*' ! -path '*/tests/*' -print0 2>/dev/null \
    | xargs -0 grep -hoE '/opt/pocketforge/[A-Za-z0-9_./+-]+' 2>/dev/null | sed -E 's/[.,/]+$//' | sort -u
}

# ---------------------------------------------------------------- C2 image (+ C2deny)
c2() {
  local raws rawbytes cand img="" how="" got listed rc out checked missing m left=() exempt=() c ok receipt="none" creates=()
  raws=$(cat "$P"/seed-kit/felboot-request*.json 2>/dev/null | grep -oE '"RawSHA256": *"[0-9a-f]{64}"' | grep -oE '[0-9a-f]{64}' | sort -u)
  if [ -z "$raws" ]; then emit C2deny SKIP "raw_unknown"; emit C2 FAIL "raw_unknown (no RawSHA256 in seed-kit/felboot-request*.json)"; return; fi
  if [ "$(printf '%s\n' "$raws" | grep -c .)" -ne 1 ]; then emit C2deny SKIP "raw_ambiguous"; emit C2 FAIL "raw_ambiguous:$(printf '%s' "$raws" | cut -c1-8 | tr '\n' ',')"; return; fi
  RAW=$raws
  rawbytes=$(cat "$P"/seed-kit/felboot-request*.json 2>/dev/null | grep -oE '"RawBytes": *[0-9]+' | grep -oE '[0-9]+$' | sort -u | head -1)
  # gpu-14 2026-10-16 D4a answer 2b: Build 16 never runs (battery regression). The denylist is gpu-14's file; one
  # sha256 per line, first field. Not overridable.
  if [ ! -f "$DENY" ] || [ ! -r "$DENY" ]; then emit C2deny FAIL "denylist_unreadable path=$DENY"
  elif awk -v r="$RAW" '!/^[[:space:]]*#/ && tolower($1)==r {f=1} END {exit !f}' "$DENY"; then
    emit C2deny FAIL "image_denylisted raw=$RAW note=\"$(clean "$(awk -v r="$RAW" 'tolower($1)==r {$1=""; print; exit}' "$DENY")")\""
  else emit C2deny PASS "raw=${RAW:0:12} not_in=$(basename "$DENY")"; fi
  # Local raw candidates, in order: declared IMAGE=, the package-local hardlink, gpu-14's build*-publish dirs.
  local cands=()
  while IFS= read -r c; do [ -n "$c" ] && { case "$c" in /*) cands+=("$c") ;; *) cands+=("$P/$c") ;; esac; }; done < <(decl IMAGE)
  cands+=("$P/image/Image.img")
  for c in "$PUB"/build*-publish/ImageSource.json; do
    [ -f "$c" ] && grep -q "$RAW" "$c" 2>/dev/null && cands+=("$(dirname "$c")/Image.img")
  done
  for cand in "${cands[@]}"; do
    [ -f "$cand" ] || continue
    if [ -n "$rawbytes" ] && [ "$(stat -c %s "$cand")" != "$rawbytes" ]; then continue; fi
    listed=$(awk '$2=="image/Image.img" || $2=="*image/Image.img" {print $1; exit}' "$P/ARTIFACT-SHA256SUMS" 2>/dev/null)
    if [ "$cand" = "$P/image/Image.img" ] && [ "$C1_MANIFEST_OK" = 1 ] && [ "$listed" = "$RAW" ]; then
      img=$cand; how="artifact_manifest"; break
    fi
    got=$(sha256sum < "$cand" | cut -c1-64)
    if [ "$got" = "$RAW" ]; then img=$cand; how="sha256"; break; fi
    emit C2 FAIL "image_sha256_mismatch path=$cand want=${RAW:0:12} got=${got:0:12}"; return
  done
  if [ -z "$img" ]; then emit C2 FAIL "no_local_image raw=${RAW:0:12} hint=add_its_build*-publish_dir_or_declare_IMAGE="; return; fi
  for c in "$(dirname "$img")"/receipt-*.json "$PUB"/build*-publish/receipt-*.json; do
    [ -f "$c" ] && grep -q "$RAW" "$c" 2>/dev/null && { receipt=$c; break; }
  done
  # Image paths: the same set window-chain.sh checks, minus prepare-created CREATES paths.
  mapfile -t IPATHS < <(image_scan_paths)
  if [ ${#IPATHS[@]} -eq 0 ]; then
    if [ "$(decl IMAGE_PATHS | tail -1)" = none ]; then
      emit C2 PASS "image=$img verified_by=$how receipt=$(basename "$receipt") paths_checked=0 declared=IMAGE_PATHS=none"
    else
      # gpu-14 2026-10-16 first live run: kernel and runner-step kits (SD UHS v5, bootpart) run no /opt/pocketforge
      # path, so there is nothing to check; FAIL forced an override on every non-app kit. Report SKIP (the image sha
      # itself is still verified above); FAIL stays for paths that exist but were not checked.
      emit C2 SKIP "no_image_paths_in_plan image=$img verified_by=$how (nothing under /opt/pocketforge to check)"
    fi
    return
  fi
  out=$("$IPC" "$img" "${IPATHS[@]}" 2>&1); rc=$?
  checked=$(printf '%s' "$out" | sed -n 's/.* checked=\([0-9]*\).*/\1/p' | tail -1)
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then emit C2 FAIL "image_path_check_error rc=$rc out=\"$(clean "$out")\""; return; fi
  if [ "${checked:-0}" = 0 ]; then emit C2 FAIL "image_paths_vacuous checked=0 scanned=${#IPATHS[@]}"; return; fi
  missing=$(printf '%s' "$out" | sed -n 's/.* missing=\([^ ]*\).*/\1/p' | tail -1)
  mapfile -t creates < <(decl CREATES)
  IFS=, read -r -a m <<< "$missing"
  for c in "${m[@]}"; do
    [ -n "$c" ] || continue
    ok=0; local cr
    for cr in "${creates[@]}"; do cr=${cr%/}; [ -n "$cr" ] || continue; case "$c" in "$cr"|"$cr"/*) ok=1 ;; esac; done
    if [ "$ok" = 1 ]; then exempt+=("$c"); else left+=("$c"); fi
  done
  PATHS_EXEMPT=${#exempt[@]}
  if [ ${#left[@]} -gt 0 ] && [ -n "${PF_WINDOW_IMAGE_PATHS_OK:-}" ]; then
    # The legacy per-window override gpu-14 already passes to window-chain.sh; echoed, and forwarded unchanged.
    CHAIN_PATHS_OK=$(clean "$PF_WINDOW_IMAGE_PATHS_OK")
    emit C2 PASS "image=$img verified_by=$how checked=$checked missing=$(join "${left[@]}") accepted_by=PF_WINDOW_IMAGE_PATHS_OK reason=\"$CHAIN_PATHS_OK\""
    return
  fi
  if [ ${#left[@]} -gt 0 ]; then
    emit C2 FAIL "image_paths_missing image=$img checked=$checked missing=$(join "${left[@]}") exempt_by_CREATES=$PATHS_EXEMPT"
    case " ${OVERRIDES[*]:-} " in *" C2 "*) CHAIN_PATHS_OK="kit-preflight C2 override for $G: $(clean "${KIT_PREFLIGHT_OVERRIDE_C2:-}")" ;; esac
    return
  fi
  if [ "$PATHS_EXEMPT" -gt 0 ]; then
    CHAIN_PATHS_OK="kit-preflight $G: missing $(join "${exempt[@]}") are created by the package's prepare step (sealed PREFLIGHT CREATES=)"
  fi
  emit C2 PASS "image=$img verified_by=$how receipt=$(basename "$receipt") checked=$checked exempt_by_CREATES=$PATHS_EXEMPT"
}

# ---------------------------------------------------------------- C3 entrypoints
c3() {
  local why=() notes=() entry="" e f tmp out n=0 decl_entry
  decl_entry=$(decl ENTRYPOINT | tail -1)
  if [ -n "$decl_entry" ]; then
    case "$decl_entry" in /*) e=$decl_entry ;; *) e=$P/$decl_entry ;; esac
    if [ ! -f "$e" ]; then why+=("entrypoint_missing:$decl_entry")
    elif [[ $(basename "$e") == *test* ]]; then why+=("entrypoint_is_a_test:$(basename "$e")")
    elif [ ! -x "$e" ] && [[ $e != *.py ]]; then why+=("entrypoint_not_executable:$(basename "$e")")
    else entry=$e; notes+=("entry=$(basename "$e") source=declared"); n=$((n+1)); fi
  elif [ -n "$PLAN_REF" ]; then
    # window-chain.sh's accepted names (2026-10-15 panel 8776c285; 10-16 bootpart execute-*.py, kleaf1 executor.py).
    entry=$(find "$PLAN_REF" -maxdepth 1 -type f \( -name run-window.sh -o -name execute-lane-ssh.sh -o -name 'run-*.sh' -o -name 'execute-*.sh' -o -name 'execute-*.py' -o -name 'executor.py' \) ! -name '*test*' ! -name 'run-dry-test.sh' ! -name 'run-red-test.sh' ! -name 'run-*test*.sh' 2>/dev/null | sort | head -1)
    if [ -n "$entry" ]; then notes+=("entry=$(basename "$entry") source=plan_heuristic"); n=$((n+1))
    else why+=("plan_has_no_executor:plan=$PLAN_REF"); fi
  else
    # Step-driven kit (the lane drives pf-kit-step requests): acceptable only because every step is checked below.
    notes+=("entry=none(step-driven; no ENTRYPOINT and no referenced plan)")
  fi
  # A plan that ships a strict manifest must still match it (plans are referenced in place, never sealed).
  if [ -n "$PLAN_REF" ] && [ -f "$PLAN_REF/SHA256SUMS" ]; then
    if (cd "$PLAN_REF" && sha256sum -c --strict --quiet SHA256SUMS >/dev/null 2>&1); then notes+=("plan_manifest=verified"); n=$((n+1))
    else why+=("plan_manifest_invalid:plan=$PLAN_REF"); fi
  fi
  # Deployed `pf-kit-step --check` on the sequence-0 template and each declared STEP=: pure static (no generation
  # argument, no window root; pf_kit_step.check_request + pf_kit_root_lint). Placeholder identity fields are filled
  # with format-valid dummies in a private temp copy; Generation must already equal this generation.
  if [ -n "$D" ] && [ -f "$D/scripts/pf-kit-step" ]; then
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/kit-preflight.XXXXXX") || { emit C3 FAIL "tempdir_failed"; return; }
    local files=("$P/bootstrap-step.template.json") s
    while IFS= read -r s; do [ -n "$s" ] && { case "$s" in /*) files+=("$s") ;; *) files+=("$P/$s") ;; esac; }; done < <(decl STEP)
    for f in "${files[@]}"; do
      if [ ! -f "$f" ]; then why+=("step_missing:$(basename "$f")"); continue; fi
      if ! python3 -B - "$f" "$G" "$tmp/req.json" <<'PY' 2>"$tmp/err"; then why+=("step_unreadable:$(basename "$f"):$(head -c 80 "$tmp/err" | tr -d '\n ')"); continue; fi
import json, sys
src, gen, dst = sys.argv[1:]
v = json.load(open(src))
if v.get("Generation") != gen:
    sys.stderr.write("generation_mismatch"); sys.exit(1)
for k, dummy in (("AnchorSHA256", "0" * 64), ("CapabilityID", "0" * 64), ("RequestID", "kitpreflight0")):
    x = v.get(k)
    if isinstance(x, str) and x.startswith("@") and x.endswith("@"):
        v[k] = dummy
json.dump(v, open(dst, "w"))
PY
      out=$(cd "$tmp" && PYTHONDONTWRITEBYTECODE=1 python3 -B "$D/scripts/pf-kit-step" --check "$tmp/req.json" 2>&1)
      if printf '%s' "$out" | grep -q '^PF_KIT_STEP_CHECK result=PASS'; then n=$((n+1))
      else why+=("step_check_refused:$(basename "$f"):$(printf '%s' "$out" | grep -oE 'reason=[A-Za-z0-9_]+' | head -1)"); fi
    done
    rm -rf -- "$tmp"
    notes+=("step_checks=${#files[@]}")
  else
    why+=("deployed_pf_kit_step_missing:runner=${D:-unknown}")
  fi
  if [ ${#why[@]} -gt 0 ]; then emit C3 FAIL "$(join "${why[@]}") ${notes[*]}"
  elif [ "$n" -eq 0 ]; then emit C3 FAIL "nothing_checked ${notes[*]}"
  else emit C3 PASS "${notes[*]}"; fi
}

# ---------------------------------------------------------------- C7 owner
c7() {
  local why=() notes=() bo resolved st route b brc
  # shellcheck disable=SC2034  # set by the resolver eval
  local H="" PFT="" PF_TASK_HOST_CONFIG="" RUN_GENERATION="" RUN_HOME_REVISION=""
  [[ $OWNER =~ ^pft-[0-9a-f]{24}$ ]] || { emit C7 FAIL "owner_run_invalid run=$OWNER"; return; }
  bo=$(sed -n 's/^OwnerRun=//p' "$P/CAPABILITY-BUNDLE.txt" 2>/dev/null | head -1)
  [ "$bo" = "$OWNER" ] || why+=("owner_mismatch:package=${bo:-unreadable}")
  if resolved=$("$RUN_HOME" resolve "$OWNER" --format shell 2>/dev/null) && [ -n "$resolved" ]; then
    eval "$resolved"
    notes+=("home=$H")
    # 2026-10-14: a RELEASED owner cannot receive receipts (input-coord guard pft-8819); same probe as window-chain.sh.
    st=$(timeout 100 "$PFT" --home "$H" --role coordinator run.status "{\"run_id\":\"$OWNER\"}" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state") or "unknown")' 2>/dev/null || echo unknown)
    case "$st" in released|superseded|unknown|"") why+=("owner_run_not_live:state=${st:-unknown}") ;; *) notes+=("state=$st") ;; esac
  else
    why+=("owner_run_home_unresolved")
  fi
  # The chain's own route check (v3 owners need a resolver-backed deployed sender): read-only check-only mode.
  route=$(PF_WINDOW_CHAIN_OWNER_ROUTE_CHECK_ONLY=1 "$CHAIN" "$P" "$G" "$OWNER" KITPREFLIGHT_STATUS 1 kit-preflight 2>&1)
  if printf '%s' "$route" | grep -q '^WINDOW_CHAIN_OWNER_ROUTE result=PASS'; then notes+=("route=PASS")
  else why+=("owner_route:$(printf '%s' "$route" | grep -oE 'CHAIN_STOP [a-z0-9_]+' | tail -1 | cut -d' ' -f2)"); fi
  if [ -n "$STEPS" ]; then
    b=$("$BUDGET" "$OWNER" "$STEPS" 2>&1); brc=$?
    if [ "$brc" -eq 0 ]; then notes+=("budget=$(printf '%s' "$b" | grep -oE 'result=[A-Z_]+' | head -1 | cut -d= -f2)")
    else why+=("owner_budget:$(printf '%s' "$b" | grep -oE 'result=[A-Z_]+' | head -1 | cut -d= -f2)"); fi
  fi
  if [ ${#why[@]} -eq 0 ]; then emit C7 PASS "run=$OWNER ${notes[*]}"
  else emit C7 FAIL "$(join "${why[@]}") run=$OWNER ${notes[*]}"; fi
}

# ---------------------------------------------------------------- C8 resume seal (deployed runner's own check)
# 2026-10-16 gpu-14/kwin4 (bootpart f90d45db): boot-open refused RESUME_KIT_SEAL_INVALID in 1 s on "./name" manifest
# entries. Run the DEPLOYED runner's sealed_inventory on the template's BaseKitDirectory, so preflight and boot-open
# can never disagree (canonical names, matching hashes, exact closed inventory).
c8() {
  local t bkd out
  t=""; for f in "$P/boot-open-request.template.json" "$P/boot-open-request.json"; do [ -f "$f" ] && { t=$f; break; }; done
  if [ -z "$t" ]; then
    # STAGE.py kits write boot-open-request.json at staging, after preflight; the runner's boot-open runs the same
    # sealed_inventory before any power action (kwin4: refused in 1 s), so that is the enforcing gate for them.
    if [ -f "$P/STAGE.py" ]; then emit C8 SKIP "stagepy_request_not_staged_yet (runner enforces sealed_inventory at boot-open)"
    else emit C8 FAIL "no_boot_open_request"; fi
    return
  fi
  if ! jq -e 'type == "object"' "$t" >/dev/null 2>&1; then emit C8 FAIL "boot_open_request_unreadable template=$(basename "$t")"; return; fi
  if ! jq -e 'has("BaseKitDirectory")' "$t" >/dev/null; then emit C8 SKIP "no_resume_base template=$(basename "$t") (fresh boot; nothing to seal)"; return; fi
  bkd=$(jq -r '.BaseKitDirectory | strings' "$t")
  [ -n "$bkd" ] || { emit C8 FAIL "BaseKitDirectory_invalid template=$(basename "$t")"; return; }
  [ -f "$D/scripts/lib/pf_kit_session_resume.py" ] || { emit C8 FAIL "deployed_resume_lib_missing runner=${D:-unknown}"; return; }
  out=$(cd "$D/scripts/lib" && python3 -I -c '
import sys; sys.path.insert(0, ".")
from pathlib import Path
import pf_kit_session_resume as r
try:
    inv = r.sealed_inventory(Path(sys.argv[1])); print("OK", len(inv))
except Exception as e:
    print("ERR", type(e).__name__, str(e)[:160]); sys.exit(1)' "$bkd" 2>&1); local rc=$?
  if [ "$rc" -eq 0 ]; then emit C8 PASS "base_kit=$bkd entries=$(clean "${out#OK }") runner=$(basename "$D")"
  else emit C8 FAIL "resume_seal_invalid base_kit=$bkd $(clean "$out")"; fi
}

c1; c2; c3; c7; c8
[ -n "$CHAIN_PATHS_OK" ] && echo "KIT_PREFLIGHT chain_paths_ok=$CHAIN_PATHS_OK"
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "KIT_PREFLIGHT result=PASS failed=- gen=$G image=${RAW:0:8} overrides=$(join "${OVERRIDES[@]}" | sed 's/^$/-/') paths_exempt=$PATHS_EXEMPT"; exit 0
fi
echo "KIT_PREFLIGHT result=FAIL failed=$(join "${FAILED[@]}") gen=$G image=${RAW:0:8} overrides=$(join "${OVERRIDES[@]}" | sed 's/^$/-/') paths_exempt=$PATHS_EXEMPT"; exit 1
