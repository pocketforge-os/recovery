#!/usr/bin/env bash
set -euo pipefail

WT=${1:?worktree}
ROOT=${2:?fresh rehearsal root}
ATTEMPT=${3:?attempt json}
TEMPLATE=/home/matt/recovery/gpu14/gpucap-plan1-single-checkout-template.txt
PLAN_REL=plans/pf-bench/gpucap-storage-sync-v2.json
PLAN="$WT/$PLAN_REL"
BEAD=tsp-mc9m.41.997.14

[[ -e "$WT/.git" && -f "$PLAN" && -f "$ROOT/plan/digest.json" && -f "$ROOT/plan/canonical.json" && -f "$ROOT/SHA256SUMS" && -f "$ATTEMPT" && -f "$TEMPLATE" ]] || {
  echo 'GENERATION_REFUSED reason=missing_single_checkout_input' >&2
  exit 2
}
H=$(git -C "$WT" rev-parse HEAD)
ORIGIN_H=$(git -C "$WT" rev-parse origin/main)
[[ "$H" == "$ORIGIN_H" ]] || {
  echo "GENERATION_REFUSED reason=checkout_not_current_origin_main head=$H origin=$ORIGIN_H" >&2
  exit 2
}
[[ -z "$(git -C "$WT" status --porcelain)" ]] || {
  echo 'GENERATION_REFUSED reason=checkout_dirty' >&2
  exit 2
}

authority=$(jq -r '.sha256' "$ROOT/plan/digest.json")
canonical_authority=$(jq -r '.authority.plan_sha256' "$ROOT/plan/canonical.json")
plan_raw=$(sha256sum "$PLAN" | awk '{print $1}')
source=$(jq -r '.source.commit' "$ROOT/plan/canonical.json")
platform=$(jq -r '.image.platform_commit' "$ROOT/plan/canonical.json")
descriptor=$(jq -r '.image.descriptor_sha256' "$ROOT/plan/canonical.json")
compressed=$(jq -r '.image.descriptor.CompressedSHA256' "$ROOT/plan/canonical.json")
raw=$(jq -r '.image.descriptor.RawSHA256' "$ROOT/plan/canonical.json")
manifest=$(jq -r '.image.descriptor.BuildManifestSHA256' "$ROOT/plan/canonical.json")
publication=$(jq -r '.image.publication_receipt_sha256' "$ROOT/plan/canonical.json")
rehearsal_sums=$(sha256sum "$ROOT/SHA256SUMS" | awk '{print $1}')
rehearsal_head=$(jq -r '.observed_source_head // empty' "$ROOT/source/materialization.json")
matrix=$(jq -r '.identity.sha256' "$ROOT/admission/failure-matrix.json")
cases=$(jq -r '.case_count' "$ROOT/admission/failure-matrix.json")
verdict=$(jq -r '.verdict' "$ROOT/admission/failure-matrix.json")
endpoints=$(jq -r '.real_endpoint_attempts' "$ROOT/admission/failure-matrix.json")
physical=$(jq -r '.physical_actions' "$ROOT/admission/failure-matrix.json")
generation=$(jq -r '.generation' "$ATTEMPT")
candidate_gpu=$(bd show "$BEAD" --json | jq -r '.[0].description' | sed -n 's/.*candidate gpu-um-tsp pin `\([0-9a-f]\{40\}\)`.*/\1/p' | head -1)
receipt_root=$(jq -r '.receipt_root_base' "$ROOT/plan/canonical.json")/tsp-$(printf '%s' "$generation" | cut -c1-24)-gpucap-plan1-live
order=/home/matt/recovery/gpu14/gpucap-plan1-single-checkout-order-$generation.txt

for value in "$authority" "$canonical_authority" "$descriptor" "$compressed" "$raw" "$manifest" "$publication" "$rehearsal_sums" "$matrix"; do
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] || { echo "GENERATION_REFUSED reason=non_64_hex value=$value" >&2; exit 2; }
done
for value in "$H" "$source" "$platform" "$candidate_gpu" "$rehearsal_head"; do
  [[ "$value" =~ ^[0-9a-f]{40}$ ]] || { echo "GENERATION_REFUSED reason=non_40_hex value=$value" >&2; exit 2; }
done
[[ "$authority" == "$canonical_authority" ]] || { echo 'GENERATION_REFUSED reason=rehearsal_canonical_digest_mismatch' >&2; exit 2; }
[[ "$rehearsal_head" == "$H" ]] || { echo "GENERATION_REFUSED reason=rehearsal_checkout_head_mismatch rehearsal=$rehearsal_head checkout=$H" >&2; exit 2; }
git -C "$WT" merge-base --is-ancestor "$source" "$H" || { echo 'GENERATION_REFUSED reason=plan_source_not_ancestor_of_checkout' >&2; exit 2; }
[[ "$verdict" == PASS && "$cases" == 88 && "$endpoints" == 0 && "$physical" == 0 ]] || { echo 'GENERATION_REFUSED reason=rehearsal_matrix_not_pass' >&2; exit 2; }
! grep -Fqx "$(basename "$ROOT/SHA256SUMS")" "$ROOT/SHA256SUMS" || { echo 'GENERATION_REFUSED reason=manifest_self_listed' >&2; exit 2; }
(cd "$ROOT" && sha256sum -c SHA256SUMS >/dev/null)
[[ ! -e "$order" ]] || { echo 'GENERATION_REFUSED reason=order_exists' >&2; exit 2; }

awk \
  -v head="$H" -v authority="$authority" -v plan_raw="$plan_raw" \
  -v source="$source" -v gpu="$candidate_gpu" -v platform="$platform" \
  -v descriptor="$descriptor" -v compressed="$compressed" -v raw="$raw" \
  -v manifest="$manifest" -v publication="$publication" -v worktree="$WT" \
  -v rehearsal="$ROOT" -v rehearsal_sums="$rehearsal_sums" -v rehearsal_head="$rehearsal_head" \
  -v matrix="$matrix" -v cases="$cases" -v endpoints="$endpoints" \
  -v physical="$physical" -v generation="$generation" -v attempt="$ATTEMPT" \
  -v receipt_root="$receipt_root" \
  'BEGIN { OFS="" }
   /^cx-deputy,/ { print "cx-deputy, acting for gpu-14 under contract tsp-mc9m.41.995, authorizes exactly one serialized GPUCAP plan-1 live attempt on DUT tsp from one current-origin checkout. All identity fields below are derived mechanically from this checkout and its fresh rehearsal."; next }
   /^- Worktree must be clean/ { print "- Worktree must be clean at exact current origin/main checkout commit ", head, "; refuse before mutation otherwise."; next }
   /^- Plan:/ { print "- Plan: plans/pf-bench/gpucap-storage-sync-v2.json; raw file SHA256 ", plan_raw, "; canonical authority digest ", authority, "; source commit ", source, "."; next }
   /^- Candidate GPU/ { print "- Candidate GPU ", gpu, "; platform ", platform, "."; next }
   /^- Image descriptor/ { print "- Image descriptor ", descriptor, "; compressed SHA256 ", compressed, "; raw SHA256 ", raw, "; build manifest ", manifest, "; publication receipt SHA256 ", publication, "."; next }
   /^- Single-checkout class-gate rehearsal:/ { print "- Single-checkout class-gate rehearsal: ", rehearsal, "/SHA256SUMS; receipt SHA256 ", rehearsal_sums, "; source checkout head ", rehearsal_head, "; its plan/digest.json is ", authority, "; PF_BENCH_REHEARSE=PASS; PF_BENCH_VERIFY=PASS; nested-failure matrix ", cases, "/", cases, " PASS; matrix identity ", matrix, "; real_endpoint_attempts=", endpoints, "; physical_actions=", physical, "; no self-list."; next }
   /^- Fresh null-recovery attempt:/ { print "- Fresh null-recovery attempt: ", attempt, "; generation ", generation, "; recovery fields null. Live receipt root: ", receipt_root, "."; next }
   /^`PLACEHOLDER_WORKTREE\/scripts\/pf-bench run/ { print "`", worktree, "/scripts/pf-bench run plans/pf-bench/gpucap-storage-sync-v2.json --attempt ", attempt, " --receipt-root ", receipt_root, "`"; next }
   /^Before any remote readiness probe/ { print "Before any remote readiness probe, place acquisition, SSH, power, boot, or runner action, run exactly `", worktree, "/scripts/pf-bench verify ", rehearsal, "` as the sole local preflight identity check; do not hand-assemble digest or SHA256SUMS checks. If this command fails solely because of a read-only local operator cwd/path slip, correct it and rerun this local preflight once; never retry remote readiness, place acquisition, SSH, power, boot, or runner. Require the standard node-local preflight, allowed facade GET, and authoritative tsp-base FREE check from the appended bench-worker rules. Any identity or readiness mismatch/refusal is terminal before mutation. Never hold the place yourself; never call FelBoot, power, serial, or facade mutation directly; never retry."; next }
   { print }' "$TEMPLATE" > "$order"

echo "order=$order"
echo "attempt=$ATTEMPT"
echo "rehearsal_root=$ROOT"
echo "head=$H"
echo "authority_sha=$authority"
