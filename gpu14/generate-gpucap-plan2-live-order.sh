#!/usr/bin/env bash
set -euo pipefail

TEMPLATE=/home/matt/recovery/gpu14/gpucap-plan2-live-order-20261005T1021Z.txt
REPO=/home/matt/wt/tsp-mc9m.41.984.69/pocketforge-automation
PLAN_REL=plans/pf-bench/gpucap-memory-budget-v2.json
REHEARSAL=/home/matt/recovery/tsp-mc9m.41.997.21-rehearsal-g3-04767e82
PLAN_BEAD=tsp-mc9m.41.997.21

git -C "$REPO" fetch origin main --quiet
plan_jq() { git -C "$REPO" show "origin/main:$PLAN_REL" | jq -r "$1"; }
plan_sha=$(git -C "$REPO" show "origin/main:$PLAN_REL" | sha256sum | awk '{print $1}')
authority_sha=$(plan_jq '.authority.plan_sha256')
source_commit=$(plan_jq '.source.commit')
platform_commit=$(plan_jq '.image.platform_commit')
descriptor_sha=$(plan_jq '.image.descriptor_sha256')
compressed_sha=$(plan_jq '.image.descriptor.CompressedSHA256')
raw_sha=$(plan_jq '.image.descriptor.RawSHA256')
manifest_sha=$(plan_jq '.image.descriptor.BuildManifestSHA256')
publication_receipt_sha=$(plan_jq '.image.publication_receipt_sha256')
candidate_gpu=$(bd show "$PLAN_BEAD" --json | jq -r '.[0].description' | sed -n 's/.*gpu-um-tsp `\([0-9a-f]\{40\}\)`.*/\1/p' | head -1)
gate_commit=$(gh pr view 1255 --repo pocketforge-os/pocketforge-automation --json mergeCommit --jq '.mergeCommit.oid')
rehearsal_sha=$(jq -r '.sha256' "$REHEARSAL/plan/digest.json")
rehearsal_sums_sha=$(sha256sum "$REHEARSAL/SHA256SUMS" | awk '{print $1}')
matrix_sha=$(jq -r '.identity.sha256' "$REHEARSAL/admission/failure-matrix.json")
matrix_cases=$(jq -r '.case_count' "$REHEARSAL/admission/failure-matrix.json")
matrix_verdict=$(jq -r '.verdict' "$REHEARSAL/admission/failure-matrix.json")
matrix_endpoints=$(jq -r '.real_endpoint_attempts' "$REHEARSAL/admission/failure-matrix.json")
matrix_physical=$(jq -r '.physical_actions' "$REHEARSAL/admission/failure-matrix.json")

for value in "$plan_sha" "$authority_sha" "$descriptor_sha" "$compressed_sha" "$raw_sha" "$manifest_sha" "$publication_receipt_sha" "$rehearsal_sha" "$rehearsal_sums_sha" "$matrix_sha"; do
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] || { echo "GENERATION_REFUSED reason=non_64_hex value=$value"; exit 2; }
done
for value in "$source_commit" "$candidate_gpu" "$gate_commit" "$platform_commit"; do
  [[ "$value" =~ ^[0-9a-f]{40}$ ]] || { echo "GENERATION_REFUSED reason=non_40_hex value=$value"; exit 2; }
done
[[ "$authority_sha" = "$rehearsal_sha" ]] || { echo "GENERATION_REFUSED reason=plan_rehearsal_digest_mismatch"; exit 2; }
[[ "$matrix_verdict" = PASS && "$matrix_cases" = 88 && "$matrix_endpoints" = 0 && "$matrix_physical" = 0 ]] || {
  echo "GENERATION_REFUSED reason=rehearsal_matrix_not_pass"
  exit 2
}
(cd "$REHEARSAL" && sha256sum -c SHA256SUMS >/dev/null)

generation=$(uuidgen | tr -d '-')
attempt=/home/matt/recovery/gpucap-plan2-attempt-$generation.json
receipt_root=/home/matt/recovery/tsp-fa6c308549e119bc9254-gpucap-plan2-live-$generation
stamp=$(date -u +%Y%m%dT%H%M%SZ)
order=/home/matt/recovery/gpu14/gpucap-plan2-live-order-$stamp.txt
[[ ! -e "$attempt" && ! -e "$receipt_root" && ! -e "$order" ]] || { echo "GENERATION_REFUSED reason=output_exists"; exit 2; }

jq -n --arg generation "$generation" --arg plan_sha "$authority_sha" \
  '{schema:"pocketforge.bench-attempt/v1",generation:$generation,plan_sha256:$plan_sha,recover_generation:null,recover_plan_sha256:null}' > "$attempt"

awk \
  -v authority="$authority_sha" -v gate="$gate_commit" -v plan_sha="$plan_sha" \
  -v source="$source_commit" -v gpu="$candidate_gpu" -v platform="$platform_commit" \
  -v descriptor="$descriptor_sha" -v compressed="$compressed_sha" -v raw="$raw_sha" \
  -v manifest="$manifest_sha" -v publication="$publication_receipt_sha" \
  -v rehearsal="$REHEARSAL" -v rehearsal_sums="$rehearsal_sums_sha" \
  -v matrix="$matrix_sha" -v cases="$matrix_cases" -v endpoints="$matrix_endpoints" \
  -v physical="$matrix_physical" -v generation="$generation" -v attempt="$attempt" \
  -v receipt_root="$receipt_root" \
  'BEGIN { OFS="" }
   /^cx-deputy,/ { print "cx-deputy, acting for gpu-14 under contract tsp-mc9m.41.995, authorizes exactly one serialized GPUCAP plan-2 live attempt on DUT tsp. The prior attempt was terminally refused before mutation because its identity block was mechanically truncated. The merged-head rehearsal proves the plan authority digest is ", authority, ". This is a mechanically regenerated identity order, not an unchanged device retry."; next }
   /^- Worktree must be clean/ { print "- Worktree must be clean at exact merged automation commit ", gate, " (PR #1255); refuse before mutation otherwise."; next }
   /^- Plan:/ { print "- Plan: plans/pf-bench/gpucap-memory-budget-v2.json; raw file SHA256 ", plan_sha, "; canonical authority digest ", authority, "; source commit ", source, "."; next }
   /^- Candidate GPU/ { print "- Candidate GPU ", gpu, "; platform ", platform, "."; next }
   /^- Image descriptor/ { print "- Image descriptor ", descriptor, "; compressed SHA256 ", compressed, "; raw SHA256 ", raw, "; build manifest ", manifest, "; publication receipt SHA256 ", publication, "."; next }
   /^- Merged-head class-gate rehearsal:/ { print "- Merged-head class-gate rehearsal: ", rehearsal, "/SHA256SUMS; receipt SHA256 ", rehearsal_sums, "; its plan/digest.json is ", authority, "; PF_BENCH_REHEARSE=PASS; PF_BENCH_VERIFY=PASS; nested-failure matrix ", cases, "/", cases, " PASS; matrix identity ", matrix, "; real_endpoint_attempts=", endpoints, "; physical_actions=", physical, "; no self-list."; next }
   /^- Fresh null-recovery attempt:/ { print "- Fresh null-recovery attempt: ", attempt, "; generation ", generation, "; recovery fields null. Live receipt root: ", receipt_root, "."; next }
   /^`scripts\/pf-bench run / { print "`scripts/pf-bench run plans/pf-bench/gpucap-memory-budget-v2.json --attempt ", attempt, " --receipt-root ", receipt_root, "`"; next }
   { print }' "$TEMPLATE" > "$order"

echo "order=$order"
echo "attempt=$attempt"
echo "receipt_root=$receipt_root"
echo "authority_sha=$authority_sha"
