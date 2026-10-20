#!/usr/bin/env bash
# proc-coord 2026-10-16 (tsp-mc9m.41.1030; owner decision D4a "always-on window queue"): one static gate a sealed kit
# package must pass before window-queue.sh hands it to window-chain.sh. Report F (F-device-windows.md) counted 27 wasted
# windows (15.3 bench-h) in the kit-window era; about a third were package faults that a static look at the staged
# package would have caught BEFORE the 18-20 min flash (906a2b22 stale bootstrap, 15c76b27 wrong profile, 8776c285 plan
# without executor, 1e8b34d5 dir 0755, 6c30f32b/80401167 owner budget, pft-8819 released owner). This is v1 of the F
# proposal: C1 seal, C2 image (+ C2deny, C2store), C3 entrypoints, C7 owner. C4 rootfs rehearsal, C5 ABI, C6 arm order, C8 bench
# contract and C9 prediction are NOT here yet (gpu-14 keeps the lockup-last/Build-16/prediction judgement by hand).
#
# Everything here is read-only: no stage, no seed handle, no node, no device, no runner state. Network/pf-task reads are
# the same read-only probes window-chain.sh already makes (pf-task-run-home resolve, run.status, the chain's own
# PF_WINDOW_CHAIN_OWNER_ROUTE_CHECK_ONLY mode), plus C2store's bounded GETs on the read-only artifact store. It never
# edits the package (python runs with -B: no __pycache__); scratch files live only in a mktemp dir it removes.
#
# usage: kit-preflight.sh <package-dir> <generation> <owner-run> [step-count]
#   step-count: when given, window-owner-budget-check.sh runs too (v2 homes; v3 prints NOT_APPLICABLE).
# out: one line per check `KIT_PREFLIGHT check=<id> result=PASS|FAIL|SKIP reason=...`, optionally
#      `KIT_PREFLIGHT chain_paths_ok=<text>` (window-queue passes it to window-chain as PF_WINDOW_IMAGE_PATHS_OK), then
#      `KIT_PREFLIGHT result=PASS|FAIL failed=<ids|-> gen=<gen> image=<raw8> overrides=<ids|-> paths_exempt=<n>`.
# rc: 0 PASS, 1 FAIL, 2 usage.
#
# Overrides: per check only, KIT_PREFLIGHT_OVERRIDE_<id>="<reason, >=10 chars>" (ids C1 C2 C2store C3 C7 C8). The reason
# is echoed into that check's line and the summary. C2deny (the image denylist, e.g. Build 16) is never overridable. There
# is no global override. (window-queue.sh forwards only ^C[0-9]$ ids from gpu-14's override file, so a C2store override is
# env-only until that pattern is widened.)
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
#   STEP_DRIVEN=<n>        no entrypoint: the lane drives exactly n step requests, all declared with STEP= (C3)
#   STEP=<path>            a pre-built step request (relative to the package) to run through the deployed
#                          `pf-kit-step --check` (pure static: no generation argument, no window state; read 2026-10-16).
#
# Test seams: GPU14_ROOT, PF_KIT_WINDOWS_DIR, PF_WINDOW_RUNNER_REPO, KP_RUN_HOME, KP_IMAGE_PATH_CHECK, KP_CHAIN, KP_BUDGET,
# KP_DENYLIST, KP_PUBLISH_ROOT, KP_PLAN_PREFIX (default /home/matt/recovery/, the chain's plan-path prefix), KP_ARTIFACT_BASE
# (default http://10.0.40.90:8790/artifacts/sha256, the node's PF_RECOVER_ARTIFACT_BASE).
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
STORE=${KP_ARTIFACT_BASE:-http://10.0.40.90:8790/artifacts/sha256}; STORE=${STORE%/}
FAILED=(); OVERRIDES=(); RAW=""; PATHS_EXEMPT=0; CHAIN_PATHS_OK=""
clean() { printf '%s' "$1" | tr -d '\r\n"' | tr '\t' ' ' | cut -c1-300; }
emit() {  # emit <id> <PASS|FAIL|SKIP> <reason>
  local id=$1 res=$2 why=$3 var="KIT_PREFLIGHT_OVERRIDE_$1" ov
  ov=${!var:-}
  if [ "$res" = FAIL ] && [ -n "$ov" ]; then
    if [ "$id" = C2deny ] || [ "$id" = C9 ] || [ "$id" = C10 ] || [ "$id" = C11 ] || [ "$id" = C13 ]; then why="$why override_refused=not_overridable"
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
  local why=() mode pkg_g fmt bs listed anc
  if [ ! -d "$P" ] || [ -L "$P" ]; then emit C1 FAIL "package_dir_missing_or_symlink pkg=$P"; return; fi
  [[ $G =~ ^[0-9a-f]{32}$ ]] || why+=("bad_generation")
  # 2026-10-16 (sessrt 1e8b34d5): a 0755 package flashed a whole boot before fill refused package_invalid.
  mode=$(stat -c '%a %u' "$P" 2>/dev/null)
  [ "$mode" = "700 $(id -u)" ] || why+=("package_dir_mode:${mode// /_}")
  # 2026-10-14 (a1-window-5): a generation that was never read against the package (906a2b22 prefix only).
  pkg_g=$(sed -n 's/^Generation=\([0-9a-f]\{32\}\)$/\1/p' "$P/CAPABILITY-BUNDLE.txt" 2>/dev/null | head -1)
  [ "$pkg_g" = "$G" ] || why+=("generation_mismatch:package=${pkg_g:-unreadable}")
  # 2026-10-18 (felentry 130db840): boot-open refused RESUME_OPERATION_LOCK_FAILED in 2 s because the package had no
  # series/ dir, so the anchor's .operation.lock could not be created. The anchor's directory must exist and be writable.
  anc=$(sed -n 's/^Anchor=//p' "$P/CAPABILITY-BUNDLE.txt" 2>/dev/null | head -1)
  if [ -z "$anc" ] || [ "${anc#/}" = "$anc" ]; then why+=("anchor_unreadable")
  elif [ ! -d "${anc%/*}" ] || [ -L "${anc%/*}" ] || [ ! -w "${anc%/*}" ]; then why+=("anchor_dir_missing:${anc%/*}"); fi
  # Write-once per generation (gpu-14 2026-10-16 D4a answer 1): a retry is a NEW package and generation, so any runner
  # record for this generation means it was already consumed.
  if [ -e "$WIN/$G" ] || [ -e "$WIN/boot-open-$G.json" ] || [ -e "$WIN/boot-open-$G.failed.json" ]; then
    why+=("generation_consumed")
  fi
  # 2026-10-20 (glesproof 174e1dbd): a package assembled from a used one carried lane-ssh/ and sealed it in
  # ARTIFACT-SHA256SUMS; network-ready refused lane_ssh_bundle_exists only after a full FEL boot (window lost).
  # lane-ssh/ is runtime output of network-ready: it must not exist before the window, on disk or in the manifest.
  if [ -e "$P/lane-ssh" ] || [ -L "$P/lane-ssh" ] || compgen -G "$P/.lane-ssh-new-*" >/dev/null; then why+=("lane_ssh_preexists"); fi
  grep -qE '^[0-9a-f]{64} [ *]?(\./)?(lane-ssh/|\.lane-ssh-new)' "$P/ARTIFACT-SHA256SUMS" 2>/dev/null && why+=("lane_ssh_sealed_in_manifest")
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

# ---------------------------------------------------------------- C2store image source published in the artifact store
# gpu-14 2026-10-19 (tfar 1d77d76a): C2 verified only the local image's sha256; the node's FEL recovery then refused the
# kit with image_source_failed / reason=image_source_provenance_failed (HTTP 404), because its ImageSource named a
# derived-iteration-image/v1 ITERATION-RECEIPT.json as BuildManifestSHA256 and an Image.img.xz, neither published.
# Mirror of the node's checks on the same content-addressed URLs (test-node-farm @22f6f9f8 node/redfish/image_source.py:
# validate_source, _read_hashed_json, bootchain_selector = node-recover.sh --phase Provenance; stream_image's HTTP status
# and Content-Length pins). base = the node's PF_RECOVER_ARTIFACT_BASE (node/docs/network-full-image.md):
#   <base>/<BuildManifestSHA256>/BuildManifest.json  Schema pocketforge.full-image-publication/v1; Image == descriptor
#                                                    minus BuildManifestSHA256; ExpectedCompressedSHA256 ==
#                                                    CompressedSHA256; BuildMetadataSHA256 lowercase sha256
#   <base>/<BuildMetadataSHA256>/BuildMetadata.json  no `schema` (buildx metadata) or pocketforge.owned-image-receipt/v1
#   <base>/<CompressedSHA256>/<Name>                 HTTP 200; Content-Length, when sent, exactly CompressedBytes
# Both JSON bodies must be 1 B..1 MiB, hash to their digest, and be one UTF-8 object without duplicate keys. Not mirrored:
# the buildx/receipt bootchain field rules and the image's full stream hash (the node's own prehash). The store answers
# HEAD with 405, so the image probe is a GET that curl drops at the headers (--max-filesize 1). No HTTP answer at all is
# store_unreachable: a hard FAIL with its own reason. Overridable like C2; never part of C2deny.
c2store_get() {  # c2store_get <url> <body-out> <max-bytes> [headers-out] -> "<http_code> <curl_rc>"
  local code rc hdr=()
  [ -n "${4:-}" ] && hdr=(-D "$4")
  code=$(curl -sS -o "$2" "${hdr[@]}" -w '%{http_code}' --max-time 10 --max-filesize "$3" --noproxy '*' --proto '=http,https' \
    -H 'Accept-Encoding: identity' "$1" 2>/dev/null); rc=$?
  echo "${code:-000} $rc"
}
c2store_run() {  # c2store_run <tmpdir> <declaration files...>; sets C2S_RES/C2S_WHY
  local tmp=$1 py line i msha csha cbytes name code rc res mdsha cl why=() notes=() n=0
  shift; py=$tmp/c2store.py
  cat > "$py" <<'PY'
import hashlib, json, os, re, sys
SCHEMA = "pocketforge.full-image/v1"
PUBLICATION_SCHEMA = "pocketforge.full-image-publication/v1"
RECEIPT_SCHEMA = "pocketforge.owned-image-receipt/v1"
FIELDS = {"Schema", "Name", "Compression", "CompressedBytes", "CompressedSHA256", "RawBytes", "RawSHA256",
          "BuildManifestSHA256"}
NAMES = {"none": "Image.img", "xz": "Image.img.xz", "gzip": "Image.img.gz"}
HEX = re.compile(r"[0-9a-f]{64}")
MAX_JSON = 1024 * 1024
def out(s):
    print(s); sys.exit(0)
def word(x):
    return re.sub(r"[^A-Za-z0-9._/:-]", "_", str(x))[:80]
def descriptor_error(d):  # image_source.validate_source
    if type(d) is not dict or set(d) != FIELDS: return "fields"
    if d["Schema"] != SCHEMA or d["Compression"] not in NAMES: return "schema_or_compression"
    if d["Name"] != NAMES[d["Compression"]]: return "name_compression"
    for k in ("CompressedSHA256", "RawSHA256", "BuildManifestSHA256"):
        if not isinstance(d[k], str) or not HEX.fullmatch(d[k]): return "sha:" + k
    for k in ("CompressedBytes", "RawBytes"):
        if type(d[k]) is not int or not 0 < d[k] <= 64 * 1024**3: return "size:" + k
    if d["RawBytes"] % 512: return "raw_unaligned"
    if d["Compression"] == "none" and (d["CompressedBytes"] != d["RawBytes"] or d["CompressedSHA256"] != d["RawSHA256"]):
        return "raw_pins"
    return None
def unique(pairs):  # image_source._unique_object
    v = {}
    for k, x in pairs:
        if k in v: raise ValueError("duplicate key")
        v[k] = x
    return v
def hashed_json(path, digest):  # image_source._read_hashed_json, after its HTTP 200
    with open(path, "rb") as fh: body = fh.read(MAX_JSON + 1)
    if not 0 < len(body) <= MAX_JSON: out("ERR json_length bytes=%d" % len(body))
    if hashlib.sha256(body).hexdigest() != digest: out("ERR json_sha256_mismatch")
    try: v = json.loads(body.decode("utf-8"), object_pairs_hook=unique)
    except ValueError: out("ERR json_invalid_or_duplicate_key")
    if type(v) is not dict: out("ERR json_not_object")
    return v
def main(mode):
    if mode == "desc":
        tmp, seen = sys.argv[2], {}
        for path in sys.argv[3:]:
            base = os.path.basename(path)
            try:
                with open(path, "rb") as fh: v = json.loads(fh.read(MAX_JSON).decode("utf-8"))
            except (OSError, ValueError):
                print("ERR image_source_unreadable file=%s" % word(base)); continue
            d = v if base == "ImageSource.json" else (v.get("ImageSource") if type(v) is dict else None)
            if d is None: continue
            key = json.dumps(d, sort_keys=True)
            if key in seen: continue
            i = seen[key] = len(seen)
            err = descriptor_error(d)
            if err: print("ERR image_source_invalid file=%s detail=%s" % (word(base), err)); continue
            with open(os.path.join(tmp, "desc-%d.json" % i), "w") as fh: json.dump(d, fh)
            print("D %d %s %s %d %s" % (i, d["BuildManifestSHA256"], d["CompressedSHA256"], d["CompressedBytes"], d["Name"]))
    elif mode == "manifest":  # image_source.bootchain_selector, manifest part
        v = hashed_json(sys.argv[2], sys.argv[3])
        with open(sys.argv[4]) as fh: d = json.load(fh)
        if v.get("Schema") != PUBLICATION_SCHEMA: out("ERR manifest_schema_unsupported schema=%s" % word(v.get("Schema")))
        if v.get("Image") != {k: d[k] for k in FIELDS if k != "BuildManifestSHA256"}: out("ERR manifest_image_mismatch")
        if v.get("ExpectedCompressedSHA256") != d["CompressedSHA256"]: out("ERR manifest_expected_compressed_mismatch")
        md = v.get("BuildMetadataSHA256")
        if not isinstance(md, str) or not HEX.fullmatch(md): out("ERR manifest_metadata_sha256_invalid")
        out("OK " + md)
    elif mode == "metadata":  # image_source.bootchain_selector, metadata schema rule
        v = hashed_json(sys.argv[2], sys.argv[3])
        if "schema" not in v: out("OK " + ("buildx" if "buildx.build.provenance" in v else "unspecified"))
        if v["schema"] != RECEIPT_SCHEMA: out("ERR metadata_schema_unsupported schema=%s" % word(v["schema"]))
        out("OK owned-image-receipt")
try:
    main(sys.argv[1])
except Exception as e:  # SystemExit (out) is not an Exception
    print("ERR helper_exception:%s" % type(e).__name__)
PY
  while IFS= read -r line; do
    case "$line" in "ERR "*) why+=("${line#ERR }"); continue ;; "D "*) ;; *) why+=("helper:$(clean "$line")"); continue ;; esac
    read -r _ i msha csha cbytes name <<< "$line"
    n=$((n+1))
    read -r code rc < <(c2store_get "$STORE/$msha/BuildManifest.json" "$tmp/manifest-$i.json" 1048576)
    if [ "$code" = 000 ]; then why+=("store_unreachable kind=manifest sha=${msha:0:12} curl_rc=$rc"); break; fi
    if [ "$code" != 200 ]; then why+=("store_missing kind=manifest sha=${msha:0:12} http=$code")
    elif [ "$rc" != 0 ]; then why+=("manifest_rejected sha=${msha:0:12} detail=incomplete_or_over_1MiB curl_rc=$rc")
    else
      res=$(python3 -I "$py" manifest "$tmp/manifest-$i.json" "$msha" "$tmp/desc-$i.json" 2>&1 | tail -1)
      if [ "${res#OK }" = "$res" ]; then why+=("manifest_rejected sha=${msha:0:12} detail=$(clean "${res#ERR }")")
      else
        mdsha=${res#OK }
        read -r code rc < <(c2store_get "$STORE/$mdsha/BuildMetadata.json" "$tmp/metadata-$i.json" 1048576)
        if [ "$code" = 000 ]; then why+=("store_unreachable kind=metadata sha=${mdsha:0:12} curl_rc=$rc"); break; fi
        if [ "$code" != 200 ]; then why+=("store_missing kind=metadata sha=${mdsha:0:12} http=$code")
        elif [ "$rc" != 0 ]; then why+=("metadata_rejected sha=${mdsha:0:12} detail=incomplete_or_over_1MiB curl_rc=$rc")
        else
          res=$(python3 -I "$py" metadata "$tmp/metadata-$i.json" "$mdsha" 2>&1 | tail -1)
          if [ "${res#OK }" = "$res" ]; then why+=("metadata_rejected sha=${mdsha:0:12} detail=$(clean "${res#ERR }")")
          else notes+=("manifest=${msha:0:12}:full-image-publication/v1 metadata=${mdsha:0:12}:${res#OK }"); fi
        fi
      fi
    fi
    read -r code rc < <(c2store_get "$STORE/$csha/$name" /dev/null 1 "$tmp/image-$i.headers")
    if [ "$code" = 000 ]; then why+=("store_unreachable kind=image sha=${csha:0:12} curl_rc=$rc"); break; fi
    if [ "$code" != 200 ]; then why+=("store_missing kind=image sha=${csha:0:12} http=$code"); continue; fi
    cl=$(tr -d '\r' < "$tmp/image-$i.headers" | sed -n 's/^[Cc][Oo][Nn][Tt][Ee][Nn][Tt]-[Ll][Ee][Nn][Gg][Tt][Hh]:[[:space:]]*//p' | tr '\n' ' ')
    cl=${cl% }
    if [ -n "$cl" ] && [ "$cl" != "$cbytes" ]; then why+=("store_image_length_mismatch sha=${csha:0:12} want=$cbytes got=${cl// /,}")
    else notes+=("image=${csha:0:12}:http=200:bytes=${cl:-unsent}"); fi
  done < <(python3 -I "$py" desc "$tmp" "$@" 2>&1)
  [ "$n" -gt 0 ] || [ ${#why[@]} -gt 0 ] || why+=("image_source_unknown (no ImageSource in seed-kit/felboot-request*.json or boot-open-request*.json)")
  if [ ${#why[@]} -gt 0 ]; then C2S_RES=FAIL; C2S_WHY="$(join "${why[@]}") base=$STORE"
  else C2S_RES=PASS; C2S_WHY="descriptors=$n ${notes[*]} base=$STORE"; fi
}
C2S_TMP=""
c2store_cleanup() { [ -z "$C2S_TMP" ] || rm -rf -- "$C2S_TMP"; C2S_TMP=""; }
c2store() {
  local f srcs=()
  for f in "$P"/seed-kit/felboot-request*.json "$P/seed-kit/ImageSource.json" "$P/boot-open-request.template.json" "$P/boot-open-request.json"; do
    [ -f "$f" ] && srcs+=("$f")
  done
  if [ ${#srcs[@]} -eq 0 ]; then emit C2store FAIL "image_source_unknown (no seed-kit/felboot-request*.json)"; return; fi
  trap c2store_cleanup EXIT; trap 'c2store_cleanup; exit 130' INT; trap 'c2store_cleanup; exit 143' TERM HUP
  C2S_TMP=$(mktemp -d "${TMPDIR:-/tmp}/kit-preflight.XXXXXX") || { C2S_TMP=""; trap - EXIT INT TERM HUP; emit C2store FAIL "tempdir_failed"; return; }
  C2S_RES=FAIL; C2S_WHY="internal_error"
  c2store_run "$C2S_TMP" "${srcs[@]}"
  c2store_cleanup; trap - EXIT INT TERM HUP
  emit C2store "$C2S_RES" "$C2S_WHY"
}

# ---------------------------------------------------------------- C3 entrypoints
c3() {
  local why=() notes=() entry="" e f tmp out n=0 decl_entry sd nstep
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
    # Step-driven kit (the lane drives pf-kit-step requests). recovery#14 re-look: only with a sealed STEP_DRIVEN=<n>
    # that names the complete step set: exactly n STEP= requests, n equal to the window's step count, each checked below.
    sd=$(decl STEP_DRIVEN | tail -1); nstep=$(decl STEP | grep -c . || true)
    if ! [[ $sd =~ ^[1-9][0-9]*$ ]]; then why+=("entry_unchecked:declare_ENTRYPOINT=_or_STEP_DRIVEN=<n>_with_n_STEP=_requests")
    elif [ "$nstep" -ne "$sd" ]; then why+=("step_driven_incomplete:STEP_DRIVEN=$sd declared_STEP=$nstep")
    elif [ -n "$STEPS" ] && [ "$STEPS" != "$sd" ]; then why+=("step_driven_count_mismatch:STEP_DRIVEN=$sd window_steps=$STEPS")
    else notes+=("entry=none(step-driven STEP_DRIVEN=$sd)"); fi
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
      # Mirror of the deployed runner's _copy_source (pf_kit_window_runner.py): each Step.Files[].Source must be absolute,
      # not a symlink, a regular file owned by the runner's uid. pf-kit-step --check does not test this.
      # gpu-14 2026-10-19: d24 a6750f23 lost a boot to a 95 MiB libgallium_dri.so under the old 64 MiB cap; automation#1560
      # (tsp-mc9m.41.1032) removed that cap from _copy_source, so the size check and its source drift guard are gone.
      local src_bad
      src_bad=$(python3 -I - "$f" <<'PY' 2>&1
import json, os, stat, sys
v = json.load(open(sys.argv[1])); bad = []
for item in ((v.get("Step") or {}).get("Files") or []):
    s = item.get("Source") if isinstance(item, dict) else None
    if not isinstance(s, str):
        continue
    if not os.path.isabs(s):
        why = "not_absolute"
    else:
        try:
            st = os.lstat(s)
        except OSError:
            why = "missing"
        else:
            if stat.S_ISLNK(st.st_mode): why = "symlink"
            elif not stat.S_ISREG(st.st_mode): why = "not_regular"
            elif st.st_uid != os.geteuid(): why = "foreign_owner"
            else: continue
    bad.append("%s=%s" % (os.path.basename(s), why))
print(",".join(bad))
PY
)
      [ -n "$src_bad" ] && why+=("step_source_runner_refuses:$(basename "$f"):$(clean "$src_bad")")
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
    # gpu-14 2026-10-19: a BLOCKED owner (second Codex overload, .995.130) refuses every run.send, so the bundle send
    # fails after a whole boot (h2-stagefix a39b22b4). Refuse it here so the queue fails the row and moves on.
    case "$st" in released|superseded|blocked|unknown|"") why+=("owner_run_not_live:state=${st:-unknown}") ;; *) notes+=("state=$st") ;; esac
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

# Bounded metadata reads for C9-C11 (recovery#19 review): real packages carry <=83 series entries, <=73 sealed
# requests of <=4 KiB and a BOOT_READY of ~2 KiB, so these limits only ever refuse a corrupt or hostile package.
KP_MAX_ENTRIES=${KP_MAX_ENTRIES:-1024}; KP_MAX_INPUT_BYTES=${KP_MAX_INPUT_BYTES:-1048576}
KP_MAX_TOTAL_BYTES=${KP_MAX_TOTAL_BYTES:-16777216}; KP_MAX_FLOOR_BYTES=${KP_MAX_FLOOR_BYTES:-65536}
# list_entries <dir>: print at most KP_MAX_ENTRIES+1 entry names (hidden and dangling included), then "rc=<find rc>".
# find killed by SIGPIPE (141) means the listing was cut at the limit, not a read error.
list_entries() {
  find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | head -n "$((KP_MAX_ENTRIES + 1))"
  echo "rc=${PIPESTATUS[0]}"
}
# entries_ok <listing>: the find status was clean (or cut at the limit); sets ENTRY_NAMES and ENTRY_COUNT.
entries_ok() {
  local rc=${1##*rc=}
  ENTRY_NAMES=${1%rc=*}; ENTRY_COUNT=$(printf '%s' "$ENTRY_NAMES" | grep -c .)
  [ "$rc" = 0 ] || [ "$rc" = 141 ]
}

# ---------------------------------------------------------------- C9 automation floor (window checkout compatibility)
# 2026-10-19 gpu-14 (drc 2dccce87, tsp-mc9m.41.1018.12.42.1): the runner checks a window out at the package's
# AutomationSHA and runs every step/close session from it. A pin older than the runner's request schema refused step 1
# (RESUME_STEP_INVALID) and then the close (RESUME_ADAPTER_INVALID): no teardown, place left HELD, DUT left on.
# The pin must contain every commit in kit-automation-floor.txt. Not overridable.
c9() {
  local a fl="$R/kit-automation-floor.txt" sha why missing=""
  a=$(jq -r '.AutomationSHA // empty' "$P/boot-open-request.json" 2>/dev/null)
  [ -z "$a" ] && a=$(jq -r '.AutomationSHA // empty' "$P/boot-open-request.template.json" 2>/dev/null)
  [ -z "$a" ] && a=$(grep -rhoE 'AutomationSHA[^0-9a-f]{1,6}[0-9a-f]{40}' "$P"/*.json 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
  [[ $a =~ ^[0-9a-f]{40}$ ]] || { emit C9 FAIL "automation_sha_unknown"; return; }
  [ -f "$fl" ] || { emit C9 FAIL "floor_file_missing $fl"; return; }
  # Fail closed (tsp-mc9m.41.1030.47.1): an unreadable floor, a malformed entry or a floor with no entries never passes.
  local floor line n=0 bad=""
  [ -r "$fl" ] || { emit C9 FAIL "floor_file_unreadable $fl"; return; }
  [ "$(stat -c %s -- "$fl" 2>/dev/null || echo -1)" -ge 0 ] && [ "$(stat -c %s -- "$fl")" -le "$KP_MAX_FLOOR_BYTES" ] \
    || { emit C9 FAIL "floor_file_too_large_or_unstatable $fl limit=$KP_MAX_FLOOR_BYTES"; return; }
  floor=$(cat -- "$fl" 2>/dev/null) || { emit C9 FAIL "floor_file_unreadable $fl"; return; }
  git -C "$D" cat-file -e "$a^{commit}" 2>/dev/null || { emit C9 FAIL "automation_sha_unreachable_in_runner sha=${a:0:12} runner=$(basename "$D")"; return; }
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    read -r sha why <<<"$line"
    if ! [[ $sha =~ ^[0-9a-f]{40}$ ]] || [ -z "$why" ]; then bad="$bad $(clean "${line:0:24}" | tr " " _)"; continue; fi
    n=$((n+1))
    git -C "$D" merge-base --is-ancestor "$sha" "$a" 2>/dev/null || missing="$missing ${sha:0:12}:${why%% *}"
  done <<<"$floor"
  if [ -n "$bad" ]; then emit C9 FAIL "floor_entry_malformed entries=$(echo $bad | tr ' ' ',') (each line: <40-hex sha> <reason>)"
  elif [ "$n" -eq 0 ]; then emit C9 FAIL "floor_empty $fl"
  elif [ -z "$missing" ]; then emit C9 PASS "automation=${a:0:12} contains_floor=$n"
  else emit C9 FAIL "checkout_predates_floor automation=${a:0:12} missing=${missing# } (re-seal at the deployed runner head)"; fi
}

# C10 (2026-10-19 22:13Z, slaudio 3abddadb RESUME_RECEIPT_EXISTS; drc d3b779ec copied 2dccce87's series/): a sealed package
# must carry no window receipts. A generation opens once; any series/ file other than a lock means it is spent or copied.
# Every entry counts, hidden and dangling ones included, and an unreadable series/ fails (tsp-mc9m.41.1030.47.1).
c10() {
  local f found="" entries
  if [ -L "$P/series" ] || { [ -e "$P/series" ] && [ ! -d "$P/series" ]; }; then
    emit C10 FAIL "series_not_directory (reseal a NEW package dir and generation)"; return
  fi
  if [ -d "$P/series" ]; then
    entries=$(list_entries "$P/series")
    entries_ok "$entries" && [ -r "$P/series" ] && [ -x "$P/series" ] \
      || { emit C10 FAIL "series_unreadable (reseal a NEW package dir and generation)"; return; }
    [ "$ENTRY_COUNT" -le "$KP_MAX_ENTRIES" ] \
      || { emit C10 FAIL "series_not_empty files=over_${KP_MAX_ENTRIES}_entries (generation spent or copied; reseal a NEW package dir and generation)"; return; }
    entries=$ENTRY_NAMES
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [[ $f == *.lock ]] && [ -f "$P/series/$f" ] && [ ! -L "$P/series/$f" ]; then continue; fi
      found="$found $(clean "$f" | tr " " _)"
    done <<<"$entries"
  fi
  if [ -z "$found" ]; then emit C10 PASS "series_clean"
  else emit C10 FAIL "series_not_empty files=$(echo $found | tr ' ' ',') (generation spent or copied; reseal a NEW package dir and generation)"; fi
}

# C11 (2026-10-20 01:14Z, rtx11 52cb492d window 01:08-01:12Z wasted): a hand-typed 65-hex expected_payload in
# requests-sealed/sequence-01.json passed every check and failed on the DUT. Every hex token longer than a git sha (40)
# in requests-sealed/* and BOOT_READY must be a full sha256 (exactly 64), and every expected_payload=<h> and
# KitPayloadSHA256=<h> must equal sha256 of the package's pf-kit-payload.tar.gz. Not overridable: a malformed or wrong
# hash can never verify on the device.
c11() {
  local f bad="" want got="" mism="" n=0 entries text unread=""
  local -a files=()
  # Fail closed (tsp-mc9m.41.1030.47.1): every requests-sealed entry, hidden ones included, must be a readable regular
  # file, and an unreadable directory, entry or BOOT_READY is a FAIL, never an empty token set.
  if [ -L "$P/requests-sealed" ] || { [ -e "$P/requests-sealed" ] && [ ! -d "$P/requests-sealed" ]; }; then
    unread="$unread requests-sealed:not_directory"
  elif [ -d "$P/requests-sealed" ]; then
    entries=$(list_entries "$P/requests-sealed")
    if ! { entries_ok "$entries" && [ -r "$P/requests-sealed" ] && [ -x "$P/requests-sealed" ]; }; then
      unread="$unread requests-sealed:unreadable"
    elif [ "$ENTRY_COUNT" -gt "$KP_MAX_ENTRIES" ]; then
      unread="$unread requests-sealed:over_${KP_MAX_ENTRIES}_entries"
    else
      entries=$ENTRY_NAMES
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -f "$P/requests-sealed/$f" ] && [ ! -L "$P/requests-sealed/$f" ]; then files+=("$P/requests-sealed/$f")
        else unread="$unread $(clean "$f" | tr " " _):not_regular_file"; fi
      done <<<"$entries"
    fi
  fi
  if [ -L "$P/BOOT_READY" ] || [ -e "$P/BOOT_READY" ]; then
    if [ -f "$P/BOOT_READY" ] && [ ! -L "$P/BOOT_READY" ]; then files+=("$P/BOOT_READY")
    else unread="$unread BOOT_READY:not_regular_file"; fi
  fi
  if [ ${#files[@]} -eq 0 ] && [ -z "$unread" ]; then emit C11 SKIP "no_sealed_requests_or_boot_ready"; return; fi
  # One input in memory at a time, each and all of them size-capped before reading.
  [ -f "$P/pf-kit-payload.tar.gz" ] && got=$(sha256sum < "$P/pf-kit-payload.tar.gz" | cut -c1-64)
  local size total=0
  for f in "${files[@]}"; do
    size=$(stat -c %s -- "$f" 2>/dev/null) || { unread="$unread ${f##*/}:unreadable"; continue; }
    if [ "$size" -gt "$KP_MAX_INPUT_BYTES" ]; then unread="$unread ${f##*/}:over_${KP_MAX_INPUT_BYTES}_bytes"; continue; fi
    total=$((total + size))
    if [ "$total" -gt "$KP_MAX_TOTAL_BYTES" ]; then unread="$unread inputs:over_${KP_MAX_TOTAL_BYTES}_bytes_total"; break; fi
    text=$(cat -- "$f" 2>/dev/null) || { unread="$unread ${f##*/}:unreadable"; continue; }
    while read -r tok; do
      [ -n "$tok" ] || continue
      n=$((n+1)); [ ${#tok} -eq 64 ] || bad="$bad ${f##*/}:${tok:0:12}(len=${#tok})"
    done < <(printf '%s\n' "$text" | grep -oE '(^|[^0-9A-Za-z])[0-9a-fA-F]{41,}([^0-9A-Za-z]|$)' | grep -oE '[0-9a-fA-F]{41,}')
    while read -r want; do
      [ -n "$want" ] || continue
      if [ -z "$got" ]; then mism="$mism ${f##*/}:payload_missing"
      elif [ "${want,,}" != "$got" ]; then mism="$mism ${f##*/}:want=${want:0:12}(len=${#want})"; fi
    done < <(printf '%s\n' "$text" | grep -oE '(expected_payload|KitPayloadSHA256)[=:" ]+[0-9a-fA-F]+' | grep -oE '[0-9a-fA-F]+$')
  done
  local why=()
  [ -n "$unread" ] && why+=("sealed_input_unreadable inputs=$(echo $unread | tr ' ' ',')")
  [ -n "$bad" ] && why+=("sealed_hash_malformed tokens=$(echo $bad | tr ' ' ',')")
  [ -n "$mism" ] && why+=("payload_hash_mismatch payload=${got:0:12} refs=$(echo $mism | tr ' ' ',')")
  if [ ${#why[@]} -eq 0 ]; then emit C11 PASS "hashes_ok tokens=$n payload=${got:0:12}"
  else emit C11 FAIL "$(join "${why[@]}") (fix the sealed request from sha256sum output and reseal a NEW generation)"; fi
}

# C12 (2026-10-20 07:10Z, rtx11 ec7f94da: booted 18 min, then fill refused filled_bundle_exists): the runner writes
# CAPABILITY-BUNDLE.filled.txt after boot-open (create-once). A package that already has one, or lists it in its
# manifest, carries values from another window and can never be handed off. Not overridable.
c12() {
  local why=()
  [ -e "$P/CAPABILITY-BUNDLE.filled.txt" ] && why+=("filled_bundle_present")
  [ -f "$P/ARTIFACT-SHA256SUMS" ] && grep -qE '  (\./)?CAPABILITY-BUNDLE\.filled\.txt$' "$P/ARTIFACT-SHA256SUMS" && why+=("filled_bundle_in_manifest")
  if [ ${#why[@]} -eq 0 ]; then emit C12 PASS "no_prefilled_bundle"
  else emit C12 FAIL "$(join "${why[@]}") (the runner fills the bundle after boot-open; remove it, drop it from the manifest, reseal a NEW generation)"; fi
}

# C13 (2026-10-20 14:22Z, budget replay 946aed02: staged, full FelBoot, then boot-open RESUME_RECEIPT_WRITE_FAILED):
# the template carried "OriginalBootReceipt": "@ORIGINAL_BOOT_RECEIPT@" unrendered and nothing validated it before FEL
# (tsp-mc9m.41.1030.47). Every boot-open request in the package must have no @NAME@ token except the two the runtime
# renders, and an OriginalBootReceipt that is absolute, realpath-inside <package>/series/, not yet written and
# writable (nearest existing ancestor a writable directory). The
# automation stage and session-resume make the same refusal (ORIGINAL_BOOT_RECEIPT_PATH_INVALID /
# UNRENDERED_TEMPLATE_TOKEN). Not overridable: a FAIL here always costs a boot.
c13() {
  local why=() files=() f toks bad receipt series resolved parent
  for f in boot-open-request.template.json boot-open-request.json stage/boot-open-request.json; do
    [ -f "$P/$f" ] && files+=("$f")
  done
  if [ ${#files[@]} -eq 0 ]; then emit C13 SKIP "no_boot_open_request"; return; fi
  series=$(realpath -m -- "$P/series")
  for f in "${files[@]}"; do
    toks=$(grep -oE '@[A-Za-z0-9_]+@' "$P/$f" 2>/dev/null | sort -u)
    bad=$(printf '%s\n' "$toks" | grep -vxE '@POST_OPEN_ANCHOR_SHA256@|@STAGE_FROM_SEED_KIT@|' | tr '\n' ',' | sed 's/,$//')
    [ -n "$bad" ] && why+=("UNRENDERED_TEMPLATE_TOKEN file=$f tokens=$bad")
    if ! receipt=$(jq -er '.OriginalBootReceipt | strings' "$P/$f" 2>/dev/null); then
      why+=("ORIGINAL_BOOT_RECEIPT_PATH_INVALID file=$f receipt=unreadable"); continue
    fi
    if [ "${receipt#/}" = "$receipt" ]; then
      why+=("ORIGINAL_BOOT_RECEIPT_PATH_INVALID file=$f receipt=not_absolute:$(clean "$receipt")"); continue
    fi
    resolved=$(realpath -m -- "$receipt")
    case "$resolved" in
      "$series"/?*) ;;
      *) why+=("ORIGINAL_BOOT_RECEIPT_PATH_INVALID file=$f receipt=outside_series:$(clean "$resolved")"); continue ;;
    esac
    if [ -e "$receipt" ] || [ -L "$receipt" ] || [ -e "$resolved" ]; then
      why+=("ORIGINAL_BOOT_RECEIPT_PATH_INVALID file=$f receipt=exists:$(clean "$resolved")"); continue
    fi
    # boot-open writes the receipt with mkdir -p of its parent, then an exclusive create. A missing intermediate
    # directory is created; an existing non-directory component or a non-writable nearest existing ancestor fails
    # only after FEL, so refuse it here.
    parent=$(dirname -- "$resolved")
    while [ ! -e "$parent" ] && [ ! -L "$parent" ]; do parent=$(dirname -- "$parent"); done
    if [ ! -d "$parent" ] || [ ! -w "$parent" ] || [ ! -x "$parent" ]; then
      why+=("ORIGINAL_BOOT_RECEIPT_PATH_INVALID file=$f receipt=parent_unwritable:$(clean "$parent")")
    fi
  done
  if [ ${#why[@]} -eq 0 ]; then emit C13 PASS "boot_open_requests_rendered files=$(join "${files[@]}")"
  else emit C13 FAIL "$(join "${why[@]}") (render the template field and reseal a NEW generation)"; fi
}

c1; c2; c2store; c3; c7; c8; c9; c10; c11; c12; c13
[ -n "$CHAIN_PATHS_OK" ] && echo "KIT_PREFLIGHT chain_paths_ok=$CHAIN_PATHS_OK"
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "KIT_PREFLIGHT result=PASS failed=- gen=$G image=${RAW:0:8} overrides=$(join "${OVERRIDES[@]}" | sed 's/^$/-/') paths_exempt=$PATHS_EXEMPT"; exit 0
fi
echo "KIT_PREFLIGHT result=FAIL failed=$(join "${FAILED[@]}") gen=$G image=${RAW:0:8} overrides=$(join "${OVERRIDES[@]}" | sed 's/^$/-/') paths_exempt=$PATHS_EXEMPT"; exit 1
